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
package fcgi;

import fcgi.Message;
import fcgi.StatusCode;
import fcgi.MultipartParser;

import haxe.ds.StringMap;
import haxe.io.Bytes;

import tora.Code;

class ClientFcgi extends Client
{
	inline static var NL = '\r\n';
	
	//fast-cgi
	var requestId : Int;
	var role : Role;
	var flags : Int;
	
	var fcgiParams : List<{ k : String, v : String }>;
	
	var contentType : String;
	var contentLength : Int;
	
	var multipart : Null<MultipartParser>;
	var eoin : Bool;

	var dataIn : String;
	
	var statusOut : String;
	var headersOut : List<String>;
	var stdOut : String;
	
	var statusSent : Bool;
	var bodyStarted : Bool;
	
	public function new(s,secure)
	{
		super(s, secure);
		
		requestId = null;
		role = null;
		flags = null;
		
		fcgiParams = new List();
		
		contentType = null;
		contentLength = null;
		
		multipart = null;
		eoin = false;

		dataIn = null;
		
		statusOut = null;
		headersOut = null;
		stdOut = null;
		
		statusSent = false;
		bodyStarted = false;
	}
	
	override public function prepare( ) : Void
	{
		super.prepare();
		
		requestId = null;
		role = null;
		flags = null;
		
		fcgiParams = new List();
		
		contentType = null;
		contentLength = null;
		
		multipart = null;
		eoin = false;

		dataIn = null;
		
		statusOut = null;
		headersOut = null;
		stdOut = null;
		
		statusSent = false;
		bodyStarted = false;
	}
	
	override public function sendMessageSub( code : Code, msg : String, pos : Int, len : Int ) : Void
	{
		switch(code)
		{
			case CPrint:
				if ( stdOut == null ) stdOut = ''; stdOut += msg.substr(pos, len);
			
			default: Tora.log(Std.string(['sendMessageSub', code, msg, pos, len]));
		}
	}
	
	override public function sendMessage( code : Code, msg : String ) : Void
	{
		switch(code)
		{
			case CReturnCode: statusOut = msg;
			
			case CHeaderKey: key = msg;
			case CHeaderValue, CHeaderAddValue:
				if ( headersOut == null ) headersOut = new List<String>();
				headersOut.add(key + ':' + msg);
			
			case CPrint: if ( stdOut == null ) stdOut = ''; stdOut += msg;
			
			case CFlush: var s = makeStatus() + makeHeaders() + makeBody();
				
				if( s.length > 0 )
					MessageHelper.write(sock.output, requestId, STDOUT(s), true);
			
			case CExecute: var s = makeStatus() + makeHeaders() + makeBody('');
				
				MessageHelper.write(sock.output, requestId, STDOUT(s));
				MessageHelper.write(sock.output, requestId, END_REQUEST(202, REQUEST_COMPLETE));
			
			case CError: var s = makeStatus("500") + NL + msg;
				if ( stdOut != null ) s += NL + stdOut;
				
				Tora.log(msg);
				Tora.log(s);
				
				MessageHelper.write(sock.output, requestId, STDOUT(s));
				MessageHelper.write(sock.output, requestId, STDERR(msg));
				MessageHelper.write(sock.output, requestId, END_REQUEST(202, REQUEST_COMPLETE));
				throw msg;
			
			case CRedirect:
				if ( headersOut == null ) headersOut = new List<String>(); headersOut.add('Location:' + msg);
				
				var s = makeStatus("302") + makeHeaders() + NL;
				
				MessageHelper.write(sock.output, requestId, STDOUT(s));
				MessageHelper.write(sock.output, requestId, END_REQUEST(202, REQUEST_COMPLETE));
			
			case CQueryMultipart:
				if (multipart != null)
					multipart.outputSize = Std.parseInt(msg);

			case CLog:
				// save 2 file
				//Tora.log('App log: ' + msg);
			
			//case CListen:
/*
			CUri
			CTestConnect
			CPostData
			
			CPartKey
			CPartFilename
			CPartDone
			CPartData
			
			CParamValue
			CParamKey
			
			CHttpMethod
			CHostResolve
			CHostName
			CGetParams
			CFile
			CClientIP
*/
			default: Tora.log(Std.string(['sendMessage', code, msg]));
		}
	}
	inline function makeStatus( ?status : String ) : String
	{
		if ( status != null )
			statusOut = status;
		
		if ( statusOut == null )
			statusOut = "200";
		
		var s : String = '';
		if ( !statusSent )
		{
			s += 'Status: ' + statusOut + ' ' + (statusOut.length == 3 ? StatusCode.CODES.get(statusOut) : '') + NL;
			statusSent = true;
		}
		return s;
	}
	inline function makeHeaders( ) : String
	{
		var s = '';
		if ( headersOut != null )
			s = headersOut.join(NL) + NL;
		headersOut = null;
		return s;
	}
	inline function makeBody( ?b : String ) : String
	{
		if ( b != null && stdOut == null )
			stdOut = b;
		
		var s = '';
		if ( stdOut != null )
		{
			if ( !bodyStarted )
			{
				s += NL;
				bodyStarted = true;
			}
			
			s += stdOut;
			stdOut = null;
		}
		return s;
	}
	
	override public function readMessageBuffer( buf : Bytes ) : Code
	{
		if (multipart != null) {
			var next = multipart.read();
			while (!eoin && next == null) {
				while (!processMessage()) {}
				next = multipart.read();
			}
			if (next != null) {
				if (next.buffer != null) {
					bytes = next.length;
					buf.blit(0, Bytes.ofData(neko.NativeString.ofString(next.buffer)), next.start, bytes);
				}
				return next.code;
			}
		}
		return CExecute;
	}

	override public function processMessage( ) : Bool
	{
		var m = MessageHelper.read(sock.input);
		
		if ( requestId == null )
			requestId = m.requestId;
		else if ( requestId != m.requestId )
			throw "Wrong requestID. Expect: " + requestId +". Get: " + m.requestId;
		
		switch( m.message )
		{
			case BEGIN_REQUEST(role, flags):
				this.role = role;
				this.flags = flags;
			
			case ABORT_REQUEST(_):
			//case ABORT_REQUEST(app, protocol):
				// The Web server sends a FCGI_ABORT_REQUEST record to abort a request.
				// After receiving {FCGI_ABORT_REQUEST, R}, the application responds as soon as possible with {FCGI_END_REQUEST, R, {FCGI_REQUEST_COMPLETE, appStatus}}.
				// This is truly a response from the application, not a low-level acknowledgement from the FastCGI library.
				MessageHelper.write(sock.output, requestId, END_REQUEST(202, REQUEST_COMPLETE));
				this.execute = false;

			case STDIN(s) if (multipart != null):
				if (s == "")
					eoin = true;
				multipart.feed(s);
				execute = true;
				return true;

			case STDIN(s) if (s == ""):
				for (p in getParamValues(getParams, true))
					params.push(p);
				for (p in getParamValues(postData, false))
					params.push(p);
				eoin = true;
				execute = true;
				return true;

			case STDIN(s):
				if (postData == null)
					postData = '';
/*CPostData*/	postData += s;

			case DATA(s): // not implimented @ nginx
				// FCGI_DATA is a second stream record type used to send additional data to the application.
				if ( s == "" )
				{
					return false;
				}
				if ( dataIn == null ) dataIn = '';
				dataIn += s;
				
			
			case PARAMS(h): for ( name in h.keys() ) { var value = h.get(name); switch( name )
			{
/*CFile*/		case 'SCRIPT_FILENAME': if ( secure ) file = value;		// need add doc root
/*CUri*/		case 'DOCUMENT_URI': uri = value;						//DOCUMENT_URI + QUERY_STRING = REQUEST_URI
/*CClientIP*/	case 'REMOTE_ADDR': if ( secure ) ip = value;			//
/*CGetParams*/	case 'QUERY_STRING': getParams = value;
/*CHostName*/	case 'SERVER_NAME': if ( secure ) hostName = value; 	//SERVER_NAME + SERVER_PORT = HTTP_HOST
/*CHttpMethod*/	case 'REQUEST_METHOD': httpMethod = value;

/*CHeaderKey*/	
/*CHeaderValue*/
/*CHeaderAddValue*/
				default: var header = false, n = '';
				
					if ( name.substr(0, 5) == "HTTP_" )
					{
						header = true;
						n = name.substr(5);
					}
					else if ( name == 'CONTENT_TYPE' )
					{
						header = true;
						n = name;
						if ( value == null || value.length < 1 ) continue;
						
						contentType = value;

						if (contentType.indexOf('multipart/form-data') > -1) {
							var pos = contentType.indexOf('boundary=');
							var boundary = pos < 0 ? null : "--" + contentType.substr(pos + 9);
							multipart = new MultipartParser(boundary);
						}
					}
					else if ( name == 'CONTENT_LENGTH' ) 
					{
						header = true;
						n = name;
						if ( value == null || value.length < 1 ) continue;
						
						contentLength = Std.parseInt(value);
					}
					
					if ( header )
					{
						var key = '';
						var ps = n.toLowerCase().split("_");
						var first = true;
						for ( p in ps )
						{
							if ( first ) first = false; else key += '-';
							
							key += p.charAt(0).toUpperCase() + p.substr(1);
						}
						headers.push( { k:key, v:value } );
					}
					else
						fcgiParams.push({ k:name, v:value });
			}}
			
			case GET_VALUES(_): // The Web server can query specific variables within the application.
			//case GET_VALUES(h):
				
			
			default: throw "Unexpected " + Std.string(m.message);
		}
		
		return false;
	}
	
	static function getParamValues( data : String, ?isGet : Bool = false ) : List<{ k : String, v : String }>
	{
		var out = new List();
		if ( data == null || data.length == 0 )
			return out;
		
		if ( isGet )
			data = StringTools.replace(data, ";", "&");
		
		for ( part in data.split("&") )
		{
			var i = part.indexOf("=");
/*CParamKey*/			
			var k = part.substr(0, i);
/*CParamValue*/
			var v = part.substr(i + 1);
			if ( v != "" )
				v = StringTools.urlDecode(v);
			
			out.push({k:k, v:v});
		}
		return out;
	}
}
