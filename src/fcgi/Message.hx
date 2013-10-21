/**
 * ...
 * @author Constantine
 */

package fcgi;

import haxe.ds.StringMap;
import haxe.io.Bytes;
import haxe.io.BytesInput;
import haxe.io.BytesOutput;
import haxe.io.Input;
import haxe.io.Output;

enum MessageType
{
	_;
	FCGI_BEGIN_REQUEST;
	FCGI_ABORT_REQUEST;
	FCGI_END_REQUEST;
	FCGI_PARAMS;
	FCGI_STDIN;
	FCGI_STDOUT;
	FCGI_STDERR;
	FCGI_DATA;
	FCGI_GET_VALUES;
	FCGI_GET_VALUES_RESULT;
	FCGI_UNKNOWN_TYPE;
}

typedef MessageRequest = {
	var message : Message;
	var requestId : Int;
}
enum Message {
	_;
	BEGIN_REQUEST		(role : Role, flags : Int);
	ABORT_REQUEST		(appStatus : Int, protocolStatus : ProtocolStatus); //appStatus : Int32
	END_REQUEST			(appStatus : Int, protocolStatus : ProtocolStatus); //appStatus : Int32
	PARAMS				(h : StringMap<String>);
	STDIN				(s : String);
	STDOUT				(s : String);
	STDERR				(s : String);
	DATA				(s : String);
	GET_VALUES			(h : StringMap<String>);
	GET_VALUES_RESULT	(h : StringMap<String>);
	UNKNOWN_TYPE		(type : Int);
}

/*
//Input
case BEGIN_REQUEST:
case ABORT_REQUEST:
case STDIN:
case DATA:
case PARAMS:
case GET_VALUES:

//Output
case END_REQUEST:		
case STDOUT:			
case STDERR:			
case GET_VALUES_RESULT:	
case UNKNOWN_TYPE:

enum Flag { _; KEEP_CONN; }
enum GetValues { FCGI_MAX_CONNS; FCGI_MAX_REQS; FCGI_MPXS_CONNS; }
*/

enum ProtocolStatus { REQUEST_COMPLETE; CANT_MPX_CONN; OVERLOADED; UNKNOWN_ROLE; }
enum Role { _; RESPONDER; AUTHORIZER; FILTER; }

typedef MessageHeader = {
	var version : Int;
	var type : MessageType;
	var requestId : Int;
	var contentLength : Int;
	var paddingLength : Int;
	//	reserved[1]
};

class MessageHelper
{
	static var CONTENT_MAX = 64 * 1024 - 1;
	
	static var HEADER_LEN = 8;
	static var VERSION = 1;
	static var TYPES = Type.getEnumConstructs(MessageType);
	static var ROLES = Type.getEnumConstructs(Role);
	static var PROTOS = Type.getEnumConstructs(ProtocolStatus);
	
	public static function write( output : Output, requestId : Int, message : Message, ?noFinilize : Bool = false ) : Void
	{
		var paddings = Bytes.ofString(StringTools.rpad('', ' ', 8));
		var o : BytesOutput = new BytesOutput();
		
		var finilize = false;
		
		var type : MessageType = switch( message )
		{
			case END_REQUEST(app, protocol):
				o.writeInt32(app);
				o.writeInt8(Type.enumIndex(protocol));
				o.writeBytes(paddings, 0, 3); // reserved[3];
				FCGI_END_REQUEST;
			
			case STDOUT(s): finilize = true && !noFinilize;
				while ( s.length > CONTENT_MAX )
				{
					write(output, requestId, STDOUT(s.substr(0, CONTENT_MAX)), true);
					s = s.substr(CONTENT_MAX);
				}
				
				o.writeString(s);
				FCGI_STDOUT;
			
			case STDERR(s): finilize = true && !noFinilize;
				while ( s.length > CONTENT_MAX )
				{
					write(output, requestId, STDERR(s.substr(0, CONTENT_MAX)), true);
					s = s.substr(CONTENT_MAX);
				}
				o.writeString(s);
				FCGI_STDERR;
			
			case GET_VALUES_RESULT(h):
				for ( name in h.keys() )
					writePair(o, name, h.get(name));
				FCGI_GET_VALUES_RESULT;
			
			case UNKNOWN_TYPE(type):
				o.writeInt8(type);
				o.writeBytes(paddings, 0, 7); // reserved[7];
				FCGI_UNKNOWN_TYPE;
			
			default: throw "Unexpected " + Std.string(message);
		}
		var content = o.getBytes();
		var len = content.length;
		
		o = new BytesOutput();
		var h : MessageHeader = {
			version: VERSION,
			type: type,
			requestId: requestId,
			contentLength: len,
			paddingLength: (len % 8) > 0 ? (8 - len % 8) : 0,
		};
		writeHeader(o, h);
		
		output.write(o.getBytes());
		output.write(content);
		output.writeBytes(paddings, 0, h.paddingLength);
		
		if ( finilize )
		{
			var hf : MessageHeader = {
				version: VERSION,
				type: type,
				requestId: requestId,
				contentLength: 0,
				paddingLength: 0
			};
			writeHeader(output, hf);
		}
	}
	public static function read( input : Input ) : MessageRequest
	{
		var i : BytesInput;
		
		i = new BytesInput(input.read(HEADER_LEN));
		var h : MessageHeader = readHeader(i);
		
		i = new BytesInput(input.read(h.contentLength));
		if ( h.paddingLength > 0 ) input.read(h.paddingLength);
		
		i.bigEndian = true;
		var message : Message = switch( h.type )
		{
			case FCGI_BEGIN_REQUEST: var role = i.readUInt16(), flags = i.readInt8(); i.read(5); //reserved[5]
								BEGIN_REQUEST(Reflect.field(Role, ROLES[role]), flags);
			
			case FCGI_ABORT_REQUEST:	var app = i.readInt32(), protocol = i.readInt8(); i.read(3); //reserved[3]
								ABORT_REQUEST(app, Reflect.field(ProtocolStatus, PROTOS[protocol]));
			
			case FCGI_STDIN:			STDIN(i.readString(h.contentLength));
			case FCGI_DATA:			DATA(i.readString(h.contentLength));
			case FCGI_PARAMS:		PARAMS(readPairs(i));
			case FCGI_GET_VALUES:	GET_VALUES(readPairs(i));
			
			default: throw "Unexpected " + Std.string(h.type);
		};
		
		return {
			message: message,
			requestId: h.requestId
		};
	}
	
	
	static function readHeader( i : Input ) : MessageHeader
	{
		i.bigEndian = true;
		
		var h = {
			version: i.readInt8(),
			type: Reflect.field(MessageType, TYPES[i.readInt8()]),
			requestId: i.readUInt16(),
			contentLength: i.readUInt16(),
			paddingLength: i.readInt8(),
		};
		i.readInt8(); // reserved[1]
		
		if ( h.version != VERSION )
			throw "Wrong version";
		
		return h;
	}
	static function writeHeader( o : Output, h : MessageHeader ) : Void
	{
		o.bigEndian = true;
		
		o.writeInt8(h.version);
		o.writeInt8(Type.enumIndex(h.type));
		o.writeUInt16(h.requestId);
		o.writeUInt16(h.contentLength);
		o.writeInt8(h.paddingLength);
		o.writeInt8(0);//reserved[1]
	}
	
	
	static function readPairs( i : Input ) : StringMap<String>
	{
		var h : StringMap<String> = new StringMap();
		while ( true )
		{
			var pair = try readPair(i) catch ( _ : Dynamic ) null;
			if ( pair == null )
				break;
			h.set(pair.name, pair.value);
		}
		return h;
	}
	static function readPair( i : Input ) : { name:String, value:String }
	{
		var nl : Int;
		var vl : Int;
		
		nl = i.readByte();
		if ( (nl >> 7) == 1 ) nl =
			((nl & 0x7f)   << 24) +
			 (i.readByte() << 16) +
			 (i.readByte() <<  8) + 
			 (i.readByte())
			;
		
		vl = i.readByte();
		if ( (vl >> 7) == 1 ) vl =
			((vl & 0x7f)   << 24) +
			 (i.readByte() << 16) +
			 (i.readByte() <<  8) + 
			 (i.readByte())
			;
		
		return {
			name: i.readString(nl),
			value: i.readString(vl)
		};
	}
	static function writePair( o : Output, name : String, value : String ) : Void
	{
		var nl : Int = name.length;
		var vl : Int = value.length;
		
		if ( nl < 128 )	o.writeByte(nl);
		else
		{
			o.writeByte(((nl >> 24) & 0x7f) + 0x80);
			o.writeByte( (nl >> 16) & 0xff);
			o.writeByte( (nl >>  8) & 0xff);
			o.writeByte( (nl 	  ) & 0xff);
		}
		
		o.writeInt32(nl);
		if ( vl < 128 )	o.writeByte(vl);
		else
		{
			o.writeByte(((vl >> 24) & 0x7f) + 0x80);
			o.writeByte( (vl >> 16) & 0xff);
			o.writeByte( (vl >>  8) & 0xff);
			o.writeByte( (vl 	  ) & 0xff);
		}
		
		o.writeString(name);
		o.writeString(value);
	}
}