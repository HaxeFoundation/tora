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

private typedef Handle = Dynamic;

class Queue<T> {

	var q : Handle;
	public var name(default,null) : String;

	function new() {
	}

	public function addHandler( h : Handler<T> ) {
		queue_add_handler(q,h);
	}

	public function notify( message : T ) {
		queue_notify(q,message);
	}

	public function count() : Int {
		return queue_count(q);
	}

	public function stop() : Void {
		queue_stop(q);
	}
	
	public static function get<T>( name ) : Queue<T> {
		if( queue_init == null ) {
			queue_init = neko.Lib.load(Api.lib,"queue_init",1);
			queue_add_handler = neko.Lib.load(Api.lib,"queue_add_handler",2);
			queue_notify = neko.Lib.load(Api.lib,"queue_notify",2);
			queue_count = neko.Lib.load(Api.lib,"queue_count",1);
			queue_stop = neko.Lib.load(Api.lib, "queue_stop", 1);
		}
		var q = new Queue();
		q.name = name;
		q.q = queue_init(untyped name.__s);
		return q;
	}

	static var queue_init : neko.NativeString -> Handle;
	static var queue_add_handler : Handle -> {} -> Void;
	static var queue_notify : Handle -> Dynamic -> Void;
	static var queue_count : Handle -> Int;
	static var queue_stop : Handle -> Void;
}
