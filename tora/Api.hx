/* ************************************************************************ */
/*																			*/
/*  Tora - Neko Application Server											*/
/*  Copyright (c)2008 Motion-Twin											*/
/*																			*/
/* This library is free software; you can redistribute it and/or			*/
/* modify it under the terms of the GNU Lesser General Public				*/
/* License as published by the Free Software Foundation; either				*/
/* version 2.1 of the License, or (at your option) any later version.		*/
/*																			*/
/* This library is distributed in the hope that it will be useful,			*/
/* but WITHOUT ANY WARRANTY; without even the implied warranty of			*/
/* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU		*/
/* Lesser General Public License or the LICENSE file for more details.		*/
/*																			*/
/* ************************************************************************ */
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

	static var _ =  {
		var v = neko.Sys.getEnv("MOD_NEKO");
		if( v == null || v == "1" )
			v = "";
		lib = "mod_neko"+v;
	}
	static var unsafe_request = neko.Lib.loadLazy(lib, "tora_unsafe", 0);

}