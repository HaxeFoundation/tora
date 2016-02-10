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
package tora;

class Api {

	public static var lib(default,null) : String;

	public static function getInfos() : Infos {
		return neko.Lib.load(lib,"tora_infos",0)();
	}

	public static function command( cmd : String, ?param : String ) : Dynamic {
		return neko.Lib.load(lib,"tora_command",2)(cmd,param);
	}

	public static function unsafeRequest() : Bool {
		return unsafe_request();
	}

	public static function setCron( url : String, delay : Float ) {
		neko.Lib.load(lib, "tora_set_cron", 2)(untyped url.__s, delay);
	}

	public static function getExports( host : String ) : Dynamic {
		return neko.Lib.load(lib, "tora_get_exports", 1)(untyped host.__s);
	}

	public static function getURL( host : String, uri : String, params : Map<String,String> ) {
		if( !neko.Web.isTora ) {
			var h = new haxe.Http("http://" + host + uri);
			for( p in params.keys() )
				h.setParameter(p, params.get(p));
			var data = "NO DATA";
			h.onData = function(d) data = d;
			h.request(false);
			return data;
		}
		return neko.Lib.load(lib,"tora_get_url",3)(untyped host.__s,untyped uri.__s,params);
	}

	static var _ =  {
		var v = Sys.getEnv("MOD_NEKO");
		if( v == null || v == "1" )
			v = "";
		lib = "mod_neko"+v;
	}
	static var unsafe_request = neko.Lib.loadLazy(lib, "tora_unsafe", 0);

}