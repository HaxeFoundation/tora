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
	var clients : List<Client>;
}

class NullClient extends Client {

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
		case CPrint:
		case CError, CExecute: onExecute();
		default:
		}
	}

	public dynamic function onExecute() {
	}

}


class ModToraApi extends ModNekoApi {

	// keep a list of clients in case the module is updated
	public var listening : List<Client>;
	public var lock : neko.vm.Mutex;
	
	public var module : neko.vm.Module;
	public var time : Float;

	public function new(client) {
		super(client);
		listening = new List();
		lock = new neko.vm.Mutex();
	}

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
		var c = new NullClient(client.file, client.hostName, url);
		var callb = function() Tora.inst.handleRequest(c);
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
		c.onExecute = function() lock.release();
		Tora.inst.handleRequest(c);
		lock.wait();
		return c.usedAPI.module.exportsTable();
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

	function queue_listen( q : Queue, onNotify, onStop ) {
		if( client.notifyApi != null )
			throw neko.NativeString.ofString("Can't listen on several queues");
		if( this.main == null )
			throw neko.NativeString.ofString("Can't listen on not cached module");
		client.notifyApi = this;
		client.notifyQueue = q;
		client.onNotify = onNotify;
		var me = this;
		client.onStop = onStop;
		// add to listeners
		lock.acquire();
		listening.add(client);
		lock.release();
		// add to queue
		q.lock.acquire();
		q.clients.add(client);
		if( client.writeLock == null )
			client.writeLock = new neko.vm.Mutex();
		q.lock.release();
	}

	function queue_notify( q : Queue, message : Dynamic ) {
		q.lock.acquire();
		var old = this.client, oldapi = client.notifyApi;
		client.notifyApi = this;
		for( c in q.clients ) {
			client = c;
			Tora.inst.handleNotify(c,message);
		}
		client = old;
		client.notifyApi = oldapi;
		q.lock.release();
	}

	function queue_count( q : Queue ) {
		return q.clients.length;
	}

	function queue_stop( q : Queue ) {
		// if we are inside a onNotify/onStop, queue_stop is a closure on the API the module
		// was initialized with, which is not the current thread API.
		// we then need to fetch our real client
		// Note : only print (per-thread) and queue_stop (with above fix)
		// are working correctly in onNotify/onStop
		var client = Tora.inst.getCurrentClient().notifyApi.client;
		if( client.notifyQueue != q )
			throw neko.NativeString.ofString("You can't stop on a queue you're not waiting");
		q.lock.acquire(); // we should already have it, but in case...
		q.clients.remove(client);
		client.onNotify = null;
		client.onStop = null;
		try client.sendMessage(tora.Code.CExecute,"") catch( e : Dynamic) {};
		client.needClose = true;
		q.lock.release();
		// the api might be different than 'this'
		var api = client.notifyApi;
		api.lock.acquire();
		api.listening.remove(client);
		api.lock.release();
	}

}
