/*
	Tora - Neko Application Server
	Copyright (C) 2008-2016 Haxe Foundation

	This library is free software; you can redistribute it and/or
	modify it under the terms of the GNU Lesser General Public
	License as published by the Free Software Foundation; either
	version 2.1 of the License, or (at your option) any later version.

	This library is distributed in the hope that it will be useful,
	but WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
	Lesser General Public License for more details.

	You should have received a copy of the GNU Lesser General Public
	License along with this library; if not, write to the Free Software
	Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA
*/
import neko.NativeString;
import tora.Code;

class ModNekoApi {

	static inline var STREAM_CHUNK_SIZE = 1 << 17; // 128KB is the typical TCP send buffer size
	
	public var client : Client;
	public var main : Void -> Void;

	public function new(client) {
		this.client = client;
	}

	// mod_neko API

	function cgi_set_main( f : Void -> Void ) {
		main = f;
	}

	function get_host_name() {
		return NativeString.ofString(client.hostName);
	}

	function get_client_ip() {
		return NativeString.ofString(client.ip);
	}

	function get_uri() {
		return NativeString.ofString(client.uri);
	}

	function redirect( url : NativeString ) {
		addHeader("Redirection",CRedirect,NativeString.toString(url));
	}

	function set_return_code( code : Int ) {
		addHeader("Return code",CReturnCode,Std.string(code));
	}

	function get_client_header( header : NativeString ) {
		var c;
		var hl = NativeString.toString(header).toLowerCase();
		for( h in client.headers )
			if( h.k.toLowerCase() == hl )
				return NativeString.ofString(h.v);
		return null;
	}

	function get_params_string() {
		var p = client.getParams;
		if( p == null ) return null;
		return NativeString.ofString(p);
	}

	function get_post_data() {
		var p = client.postData;
		if( p == null ) return null;
		return NativeString.ofString(p);
	}

	function get_params() {
		return makeTable(client.params);
	}

	function cgi_get_cwd() {
		var path = client.file.split("/");
		if( path.length > 0 )
			path.pop();
		return NativeString.ofString(path.join("/")+"/");
	}

	function get_http_method() {
		return NativeString.ofString(client.httpMethod);
	}

	function set_header( header : NativeString, value : NativeString ) {
		var h = NativeString.toString(header);
		addHeader(h,CHeaderKey,NativeString.toString(header));
		addHeader(h,CHeaderValue,NativeString.toString(value));
	}
  
	function add_header( header : NativeString, value : NativeString ) {
		var h = NativeString.toString(header);
		addHeader(h,CHeaderKey,NativeString.toString(header));
		addHeader(h,CHeaderAddValue,NativeString.toString(value));
	}

	function get_cookies() {
		var v : Dynamic = null;
		var c = get_client_header(NativeString.ofString("Cookie"));
		if( c == null ) return v;
		var c = NativeString.toString(c);
		var start = 0;
		var tmp = neko.Lib.bytesReference(c);
		while( true ) {
			var begin = c.indexOf("=",start);
			if( begin < 0 ) break;
			var end = begin + 1;
			while( true ) {
				var c = tmp.get(end);
				if( c == null || c == 10 || c == 13 || c == 59 )
					break;
				end++;
			}
			v = untyped __dollar__array(
				NativeString.ofString(c.substr(start,begin-start)),
				NativeString.ofString(c.substr(begin+1,end-begin-1)),
				v
			);
			if( tmp.get(end) != 59 || tmp.get(end+1) != 32 )
				break;
			start = end + 2;
		}
		return v;
	}

	function set_cookie( name : NativeString, value : NativeString ) {
		var buf = new StringBuf();
		buf.add(name);
		buf.add("=");
		buf.add(value);
		buf.add(";");
		addHeader("Cookie",CHeaderKey,"Set-Cookie");
		addHeader("Cookie",CHeaderAddValue,buf.toString());
	}

	function parse_multipart_data( onPart : NativeString -> NativeString -> Void, onData : NativeString -> Int -> Int -> Void ) {
		var bufsize = 1 << 16;
		client.sock.setTimeout(3000); // higher timeout
		client.sendMessage(CQueryMultipart,Std.string(bufsize));
		var filename = null;
		var buffer = haxe.io.Bytes.alloc(bufsize);
		var error = null;
		while( true ) {
			var msg = client.readMessageBuffer(buffer);
			switch( msg ) {
			case CExecute:
				break;
			case CPartFilename:
				filename = buffer.sub(0,client.bytes).getData();
			case CPartKey:
				if( error == null )
					try {
						onPart( buffer.sub(0,client.bytes).getData(), filename );
					} catch( e : Dynamic ) {
						error = { r : e };
					}
				filename = null;
			case CPartData:
				if( error == null )
					try {
						onData( buffer.getData(), 0, client.bytes );
					} catch( e : Dynamic ) {
						error = { r : e };
					}
			case CPartDone:
			case CError:
				throw buffer.getString(0,client.bytes);
			default:
				throw "Unexpected "+msg;
			}
		}
		client.sock.setTimeout(3); // return
		if( error != null )
			neko.Lib.rethrow(error.r);
	}

	function cgi_flush() {
		client.sendHeaders();
		client.sendMessage(CFlush,"");
	}

	function get_client_headers() {
		return makeTable(client.headers);
	}

	function log_message( msg : NativeString ) {
		var str = NativeString.toString(msg);
		Tora.log(str);
		if( client.secure ) client.sendMessage(CLog,str);
	}

	// internal APIS

	public function print( value : Dynamic ) {
		var str = NativeString.toString(untyped if( $typeof(value) == $tstring ) value else if( $typeof(value) == $tobject && $typeof(value.__class__) == $tobject && value.__class__.__is_String ) value.__s else $string(value));
		try {
			client.sendHeaders();
			if( str.length >= STREAM_CHUNK_SIZE ) {
				// we are sending a large amount of data, let's wait until it's properly delivered
				client.sock.setTimeout(STREAM_CHUNK_SIZE / 2048); // except at least 2KB/s transfer
				var pos = 0, len = str.length;
				while( len > 0 ) {
					var send = len < STREAM_CHUNK_SIZE ? len : STREAM_CHUNK_SIZE - 1; // minus one because mod_tora adds a \0
					client.sendMessageSub(CPrint, str, pos, send);
					pos += send;
					len -= send;
				}
				// back to normal
				client.sock.setTimeout(3);
			} else {
				client.sendMessage(CPrint,str);
			}
			client.dataBytes += str.length;
		} catch( e : Dynamic ) {
			// never abort a print, this might cause side effects on the program
			client.needClose = true; // does NOT send anything else
		}
	}

	function addHeader( msg : String, c : Code, str : String ) {
		if( client.headersSent ) throw NativeString.ofString("Cannot set "+msg+" : Headers already sent");
		client.outputHeaders.add({ code : c, str : str });
	}

	static function makeTable( list : List<{ k : String, v : String }> ) : Dynamic {
		var v : Dynamic = null;
		for( h in list )
			v = untyped __dollar__array(NativeString.ofString(h.k),NativeString.ofString(h.v),v);
		return v;
	}

}
