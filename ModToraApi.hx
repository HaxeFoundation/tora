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

typedef Share = {
	var name : String;
	var data : Dynamic;
	var lock : neko.vm.Mutex;
	var owner : Client;
	var free : Bool;
}

typedef Queue = {
	var name : String;
	var lock : neko.vm.Mutex;
	var clients : List<{ c : Client, h : Dynamic, cl : String }>;
}

class NullClient extends Client {

	public var outBuf : StringBuf;
	
	public function new( file : String, host : String, uri : String ) {
		super(cast { setTimeout : function(_) {}, setFastSend : function(_) {}, close : function() {} },true);
		this.file = file;
		this.hostName = host;
		this.uri = uri;
		ip = "127.0.0.1";
		getParams = "";
		httpMethod = "CALL";
		execute = true;
	}

	override public function processMessage() {
		return true;
	}

	override public function sendMessage( code : tora.Code, msg ) {
		switch( code ) {
		case CPrint: if( outBuf != null ) outBuf.add(msg);
		default:
		}
	}

}

class ModuleContext {
	
	var oldClient : Client;
	var api : ModToraApi;
	var curProto : Dynamic;
	var curClass : String;
	var curModule : neko.vm.Module;
	var curFile : String;
	var instances : Hash<ModToraApi>;
	
	public function new(api) {
		this.api = api;
		oldClient = api.client;
		curFile = api.client.file;
		curModule = api.module;
	}
	
	public function restore() {
		api.client = oldClient;
		// put back used instances to cache
		if( instances != null )
			for( i in instances )
				i.client.onRequestDone(null);
	}
	
	public function initHandler( q : { c : Client, cl : String, h : Dynamic } ) {
		if( q.c.file != curFile ) {
			if( q.c.file == oldClient.file ) {
				curFile = oldClient.file;
				curModule = api.module;
			} else {
				var inst = null;
				if( instances == null )
					instances = new Hash();
				else
					inst = instances.get(q.c.file);
				if( inst == null ) {
					inst = Tora.inst.getInstance(q.c.file, q.c.hostName);
					if( inst == null )
						return null;
					instances.set(q.c.file, inst);
				}
				
			}
			curClass = null;
		}
		if( curClass != q.cl ) {
			curClass = q.cl;
			var pl = Reflect.field(curModule.exportsTable(), "__classes");
			for( p in q.cl.split(".") )
				pl = Reflect.field(pl, p);
			curProto = pl == null ? null : pl.prototype;
		}
		if( curProto == null )
			return false;
		api.client = q.c;
		setProto(q.h, curProto);
		return true;
	}
	
	public inline function resetHandler( q : { h : Dynamic } ) {
		setProto(q.h, null);
	}
	
	inline function setProto( h : Dynamic, p : Dynamic ) {
		untyped __dollar__objsetproto(h, p);
	}
	
	
}

class ModToraApi extends ModNekoApi {

	public var module : neko.vm.Module;
	public var time : Float;

	// tora-specific

	function tora_infos() {
		return Tora.inst.infos();
	}

	function tora_command(cmd,param) {
		return Tora.inst.command(cmd,param);
	}

	function tora_unsafe() {
		return !client.secure;
	}

	function tora_set_cron( url : neko.NativeString, delay : Float ) {
		var url = neko.NativeString.toString(url);
		var file = client.file, host = client.hostName;
		var callb = function() Tora.inst.handleRequest(new NullClient(file, host, url));
		var f = Tora.inst.getFile(client.file);
		if( f.cron == null )
			f.cron = Tora.inst.delay(delay, callb, true);
		else {
			f.cron.time = delay;
			f.cron.callb = callb;
		}
	}

	function tora_get_exports( host : neko.NativeString ) {
		var host = neko.NativeString.toString(host);
		var file = Tora.inst.resolveHost(host);
		if( file == null ) throw neko.NativeString.ofString("Unknown host '" + host + "'");
		// fast path : get from cache
		var f = Tora.inst.getFile(file);
		var h = f.cache.head;
		if( h != null && h.elt.time == Tora.inst.getFileTime(file) )
			return h.elt.module.exportsTable();
		// slow path : make an async request on /
		var c = new NullClient(file, host, "/");
		var lock = new neko.vm.Lock();
		var usedApi = null;
		c.onRequestDone = function(api) {
			usedApi = api;
			lock.release();
		};
		Tora.inst.handleRequest(c);
		lock.wait();
		return usedApi.module.exportsTable();
	}
	
	function tora_get_url( host : neko.NativeString, url : neko.NativeString, params : Hash<String> ) : String {
		var host = neko.NativeString.toString(host);
		var file = Tora.inst.resolveHost(host);
		if( file == null ) throw neko.NativeString.ofString("Unknown host '" + host + "'");
		var c = new NullClient(file, host, neko.NativeString.toString(url));
		c.outBuf = new StringBuf();
		for( p in params.keys() )
			c.params.add( { k : Std.string(untyped p.__s), v : Std.string(untyped params.get(p).__s) } );
		var lock = new neko.vm.Lock();
		c.onRequestDone = function(_) {
			lock.release();
		};
		Tora.inst.handleRequest(c);
		client.lockStatus = "Waiting for " + host + url;
		lock.wait();
		client.lockStatus = null;
		return c.outBuf.toString();
	}

	// shares

	public static var shares = new Hash<Share>();
	public static var shares_lock = new neko.vm.Mutex();

	function share_init( name : neko.NativeString, ?make : Void -> Dynamic ) : Share {
		var name = neko.NativeString.toString(name);
		var s = shares.get(name);
		if( s == null ) {
			shares_lock.acquire();
			s = shares.get(name);
			if( s == null ) {
				var tmp = new Hash();
				for( s in shares )
					tmp.set(s.name,s);
				s = {
					name : name,
					data : try make() catch( e : Dynamic ) { shares_lock.release(); neko.Lib.rethrow(e); },
					lock : new neko.vm.Mutex(),
					owner : null,
					free : false,
				};
				tmp.set(name,s);
				shares = tmp;
			}
			shares_lock.release();
		}
		return s;
	}

	function share_get( s : Share, lock : Bool ) {
		if( lock && s.owner != client ) {
			if( s.free ) throw neko.NativeString.ofString("Can't lock a share which have been free");
			if( !s.lock.tryAcquire() ) {
				client.waitingShare = s;
				var owner = s.owner;
				var ws = if( owner == null ) null else owner.waitingShare;
				if( ws != null && client.lockedShares != null )
					for( s in client.lockedShares )
						if( s == ws ) {
							client.waitingShare = null;
							throw neko.NativeString.ofString("Deadlock between "+client.getURL()+":"+s.name+" and "+owner.getURL()+":"+ws.name);
						}
				s.lock.acquire();
				client.waitingShare = null;
			}
			s.owner = client;
			if( client.lockedShares == null )
				client.lockedShares = new List();
			client.lockedShares.add(s);
		}
		return s.data;
	}

	function share_set( s : Share, data : Dynamic ) {
		s.data = data;
	}

	function share_commit( s : Share ) {
		if( s.owner != client ) throw neko.NativeString.ofString("Can't commit a not locked share");
		s.owner = null;
		s.lock.release();
		client.lockedShares.remove(s);
	}

	function share_free( s : Share ) {
		if( s.owner != client ) throw neko.NativeString.ofString("Can't free a not locked share");
		if( s.free ) return;
		shares_lock.acquire();
		shares.remove(s.name); // MT-safe
		s.free = true;
		shares_lock.release();
	}

	function share_commit_all() {
		if( client.lockedShares != null ) {
			for( s in client.lockedShares ) {
				s.owner = null;
				s.lock.release();
			}
			client.lockedShares = null;
		}
	}

	// queues

	static var queues = new Hash<Queue>();
	static var queues_lock = new neko.vm.Mutex();

	function queue_init( name : neko.NativeString ) : Queue {
		var name = neko.NativeString.toString(name);
		queues_lock.acquire();
		var q = queues.get(name);
		if( q == null ) {
			q = {
				name : name,
				lock : new neko.vm.Mutex(),
				clients : new List(),
			};
			queues.set(name,q);
		}
		queues_lock.release();
		return q;
	}
	
	function queue_add_handler( q : Queue, h : { } ) {
		var h = Reflect.copy(h);
		var cl = Type.getClassName(Type.getClass(h));
		if( cl == null )
			throw neko.NativeString.ofString("Invalid handler");
		cl = Std.string(cl); // use our local String class
		new ModuleContext(this).resetHandler({ h : h });
		if( client.writeLock == null )
			client.writeLock = new neko.vm.Mutex();
		if( client.queues == null )
			client.queues = new List();
		client.writeLock.acquire();
		if( client.needClose ) {
			client.writeLock.release();
			return; // cancel
		}
		client.queues.add(q);
		client.writeLock.release();
		q.lock.acquire();
		q.clients.add({ c : client, h : h, cl : cl });
		q.lock.release();
	}
	
	function queue_notify( q : Queue, message : Dynamic ) {
		q.lock.acquire();
		var ctx = new ModuleContext(this);
		for( qc in q.clients ) {
			if( qc.c.needClose ) continue;
			if( !ctx.initHandler(qc) )
				qc.c.needClose = true;
			try {
				qc.h.onNotify(message);
			} catch( e : Dynamic ) {
				var data = try {
					var stack = haxe.Stack.callStack().concat(haxe.Stack.exceptionStack());
					Std.string(e) + haxe.Stack.toString(stack);
				} catch( _ : Dynamic ) "???";
				try {
					qc.c.sendMessage(tora.Code.CError,data);
				} catch( _ : Dynamic ) {
					qc.c.needClose = true;
				}
			}
			ctx.resetHandler(qc);
			if( qc.c.needClose )
				Tora.inst.close(qc.c, true);
		}
		ctx.restore();
		q.lock.release();
	}
	
	/*
		remove all closed clients from queues and call stop handlers
	*/
	public function cleanClients( clients : List<Client> ) {
		var ctx = new ModuleContext(this);
		for( c in clients ) {
			for( q in c.queues ) {
				q.lock.acquire();
				for( qc in q.clients ) {
					if( !qc.c.closed )
						continue;
					q.clients.remove(qc);
					if( ctx.initHandler(qc) )
						try {
							qc.h.onStop();
						} catch( e : Dynamic ) {
							var stack = haxe.Stack.toString(haxe.Stack.exceptionStack());
							var data = try Std.string(e) catch( _ : Dynamic ) "???";
							Tora.log(data + stack);
						}
				}
				q.lock.release();
			}
		}
		ctx.restore();
	}

	function queue_count( q : Queue ) {
		return q.clients.length;
	}

	function queue_stop( q : Queue ) {
		q.lock.acquire();
		for( qc in q.clients )
			if( qc.c == client )
				q.clients.remove(qc);
		q.lock.release();
		
		client.writeLock.acquire();
		client.queues.remove(q);
		client.writeLock.release();
		
		if( client.queues.length == 0 ) {
			client.needClose = true;
			Tora.inst.close(client, true);
		}
	}

}
