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
#if (haxe_ver >= 4)
import sys.thread.Mutex;
#else
import neko.vm.Mutex;
#end

import tora.Code;
import ModToraApi.Queue;
import ModToraApi.Share;

class Client {

	static var CODES = Type.getEnumConstructs(Code);

	// protocol
	public var sock : sys.net.Socket;
	public var data : String;
	public var bytes : Int;
	public var dataBytes : Int;
	public var cachedCode : Int;

	// variables
	public var execute : Bool;
	public var file : String;
	public var uri : String;
	public var ip : String;
	public var getParams : String;
	public var postData : String;
	public var headers : List<{ k : String, v : String }>;
	public var params : List<{ k : String, v : String }>;
	public var hostName : String;
	public var httpMethod : String;
	public var headersSent : Bool;
	public var outputHeaders : List<{ code : Code, str : String }>;
	
	// tora variables
	public var secure : Bool;
	public var queues : List<Queue>;
	public var waitingShare : Share;
	public var lockedShares : List<Share>;
	public var writeLock : Mutex;
	public var needClose : Bool;
	public var closed : Bool;
	public var inSocketList : Bool;
	public var lockStatus : Null<String>;

	var key : String;

	public function new(s,secure) {
		sock = s;
		this.secure = secure;
		dataBytes = 0;
		headersSent = false;
		headers = new List();
		outputHeaders = new List();
		params = new List();
	}

	public function prepare() {
		dataBytes = 0;
		headersSent = false;
		outputHeaders = new List();
		headers = new List();
		params = new List();
		getParams = null;
		postData = null;
		execute = null;
	}

	public function sendHeaders() {
		if( headersSent ) return;
		headersSent = true;
		for( h in outputHeaders )
			sendMessage(h.code,h.str);
	}

	public function readMessageBuffer( buf : haxe.io.Bytes ) : Code {
		var i = sock.input;
		var code = i.readByte();
		if( code == 0 || code > CODES.length )
			throw "Invalid proto code "+code;
		bytes = i.readUInt24();
		i.readFullBytes(buf,0,bytes);
		return Reflect.field(Code,CODES[code-1]);
	}

	public function readMessage() : Code {
		var i = sock.input;
		var code;
		if( cachedCode == null )
			code = i.readByte();
		else {
			code = cachedCode;
			cachedCode = null;
		}
		if( code == 0 || code > CODES.length ) {
			if( code == "<".code ) {
				try {
					data = i.readString(22);
				} catch( e : Dynamic ) {
					data = null;
				}
				if( data == "policy-file-request/>\x00" ) {
					var str = Tora.inst.getCrossDomainXML();
					sock.output.writeString(str);
					data = null;
					return CTestConnect;
				}
			}
			throw "Invalid proto code "+code;
		}
		var len = i.readUInt24();
		data = i.readString(len);
		return Reflect.field(Code,CODES[code-1]);
	}

	public function sendMessage( code : Code, msg : String ) {
		sendMessageSub(code, msg, 0, msg.length);
	}
	
	public function sendMessageSub( code : Code, msg : String, pos : Int, len : Int ) {
		var o = sock.output;
		if( needClose ) return;
		if( writeLock != null ) {
			writeLock.acquire();
			if( needClose ) {
				writeLock.release();
				return;
			}
			try {
				o.writeByte( Type.enumIndex(code) + 1 );
				o.writeUInt24( len );
				o.writeFullBytes( neko.Lib.bytesReference(msg), pos, len );
			} catch( e : Dynamic ) {
				writeLock.release();
				neko.Lib.rethrow(e);
			}
			writeLock.release();
		} else {
			o.writeByte( Type.enumIndex(code) + 1 );
			o.writeUInt24( len );
			o.writeFullBytes( neko.Lib.bytesReference(msg), pos, len );
		}
	}

	public function processMessage() {
		var code = readMessage();
		//trace(Std.string(code)+" ["+data+"]");
		switch( code ) {
		case CFile: if( secure ) file = data;
		case CUri: uri = data;
		case CClientIP: if( secure ) ip = data;
		case CGetParams: getParams = data;
		case CPostData: postData = data;
		case CHeaderKey: key = data;
		case CHeaderValue, CHeaderAddValue: headers.push({ k : key, v : data });
		case CParamKey: key = data;
		case CParamValue: params.push({ k : key, v : data });
		case CHostName: if( secure ) hostName = data;
		case CHttpMethod: httpMethod = data;
		case CExecute: execute = true; return true;
		case CTestConnect: execute = false; return true;
		case CHostResolve:
			hostName = data;
			ip = sock.peer().host.toString();
			file = Tora.inst.resolveHost(hostName);
			httpMethod = "TORA";
			if( file == null ) {
				sendMessage(CError,"Unknown host");
				execute = false;
				return true;
			}
		case CError: throw data;
		default: throw "Unexpected "+Std.string(code);
		}
		data = null;
		return false;
	}

	public function getURL() {
		var h = hostName;
		var u = uri;
		if( h == null ) h = "???";
		if( u == null ) u = "/???";
		return h + u;
	}
	
	public dynamic function onRequestDone( api : ModToraApi ) {
	}

}
