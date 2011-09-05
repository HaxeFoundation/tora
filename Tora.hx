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
import neko.net.Socket.SocketHandle;
import tora.Code;
import tora.Infos;

typedef ThreadData = {
	var id : Int;
	var t : neko.vm.Thread;
	var client : Client;
	var time : Float;
	var hits : Int;
	var errors : Int;
	var stopped : Bool;
}

typedef FileData = {
	var file : String;
	var filetime : Float;
	var loads : Int;
	var cacheHits : Int;
	var bytes : Float;
	var time : Float;
	var lock : neko.vm.Mutex;
	var cache : haxe.FastList<ModToraApi>;
	var cron : Timer;
	var toClean : List<Client>;
}

typedef Timer = {
	var elapsed : Float;
	var time : Float;
	var callb : Void -> Void;
	var repeat : Bool;
}

class Tora {

	var clientQueue : neko.vm.Deque<Client>;
	var pendingSocks : neko.vm.Deque<Client>;
	var threads : Array<ThreadData>;
	var startTime : Float;
	var totalHits : Int;
	var recentHits : Int;
	var activeConnections : Int;
	var files : Hash<FileData>;
	var flock : neko.vm.Mutex;
	var rootLoader : neko.vm.Loader;
	var modulePath : Array<String>;
	var redirect : Dynamic;
	var set_trusted : Dynamic;
	var enable_jit : Bool -> Bool;
	var running : Bool;
	var jit : Bool;
	var hosts : Hash<String>;
	var ports : Array<Int>;
	var tls : neko.vm.Tls<ThreadData>;
	var delayQueue : List<Timer>;
	var delayWait : neko.vm.Lock;
	var delayLock : neko.vm.Mutex;

	function new() {
		totalHits = 0;
		recentHits = 0;
		running = true;
		startTime = haxe.Timer.stamp();
		files = new Hash();
		hosts = new Hash();
		ports = new Array();
		tls = new neko.vm.Tls();
		flock = new neko.vm.Mutex();
		clientQueue = new neko.vm.Deque();
		pendingSocks = new neko.vm.Deque();
		threads = new Array();
		rootLoader = neko.vm.Loader.local();
		modulePath = rootLoader.getPath();
		delayQueue = new List();
		delayWait = new neko.vm.Lock();
		delayLock = new neko.vm.Mutex();
	}

	function init( nthreads : Int ) {
		neko.Sys.putEnv("MOD_NEKO","1");
		redirect = neko.Lib.load("std","print_redirect",1);
		set_trusted = neko.Lib.load("std","set_trusted",1);
		enable_jit = neko.Lib.load("std","enable_jit",1);
		jit = (enable_jit(null) == true);
		neko.vm.Thread.create(callback(startup,nthreads));
		neko.vm.Thread.create(socketsLoop);
		neko.vm.Thread.create(speedDelayLoop);
	}

	function startup( nthreads : Int ) {
		// don't start all threads immediatly : this prevent allocating
		// too many instances because we have too many concurent requests
		// when a server get restarted
		for( i in 0...nthreads ) {
			var inf : ThreadData = {
				id : i,
				t : null,
				client : null,
				hits : 0,
				errors : 0,
				time : haxe.Timer.stamp(),
				stopped : false,
			};
			inf.t = neko.vm.Thread.create(callback(threadLoop,inf));
			threads.push(inf);
			while( true ) {
				neko.Sys.sleep(0.5);
				if( totalHits > i * 10 )
					break;
			}
		}
	}

	// measuring speed and processing delayed events
	function speedDelayLoop() {
		var nextDelay = null;
		var lastTime = neko.Sys.time(), lastHits = totalHits;
		while( true ) {
			var time = neko.Sys.time();
			delayWait.wait((nextDelay == null) ? 1.0 : nextDelay);
			delayLock.acquire();
			var dt = neko.Sys.time() - time;
			var toExecute = null;
			nextDelay = null;
			for( d in delayQueue ) {
				d.elapsed += dt;
				var rem = d.time - d.elapsed;
				if( rem < 0 ) {
					if( toExecute == null ) toExecute = new List();
					toExecute.add(d.callb);
					if( d.repeat )
						d.elapsed += d.time;
					else
						delayQueue.remove(d);
				} else {
					if( nextDelay == null || nextDelay > rem )
						nextDelay = rem;
				}
			}
			delayLock.release();
			if( toExecute != null )
				for( f in toExecute )
					try {
						f();
					} catch( e : Dynamic ) {
						log(Std.string(e)+haxe.Stack.toString(haxe.Stack.exceptionStack()));
					}
			dt = neko.Sys.time() - lastTime;
			if( dt > 1 ) {
				var hits = Std.int((totalHits - lastHits) / dt);
				recentHits = Math.ceil(recentHits * 0.5 + hits * 0.5);
				lastTime += dt;
				lastHits = totalHits;
			}
		}
	}

	// checking which listening clients are disconnected
	function socketsLoop() {
		var poll = new neko.net.Poll(4096);
		var socks = new Array();
		var changed = false;
		while( true ) {
			// add new clients
			while( true ) {
				var client = pendingSocks.pop(socks.length == 0);
				if( client == null ) break;
				changed = true;
				if( client.needClose ) {
					close(client);
					socks.remove(client.sock);
				} else {
					client.sock.custom = client;
					socks.push(client.sock);
				}
			}
			if( changed ) {
				poll.prepare(socks,new Array());
				activeConnections = socks.length;
				changed = false;
			}
			// check if some clients sent a message or have been disconnected
			poll.events(0.05);
			var i = 0;
			var toact = null;
			while( true ) {
				var idx = poll.readIndexes[i++];
				if( idx == -1 ) break;
				var client : Client = socks[idx].custom;
				if( toact == null ) toact = new List();
				toact.add(client);
			}
			if( toact != null ) {
				for( c in toact ) {
					socks.remove(c.sock);
					try {
						if( c.needClose ) throw "Closing";
						c.cachedCode = c.sock.input.readByte();
						c.prepare();
						handleRequest(c);
					} catch( e : Dynamic ) {
						close(c);
					}
				}
				changed = true;
				activeConnections = socks.length;
			}
		}
	}

	public function close( c : Client, ?notify : Bool ) {
		// fast path for common requests
		if( c.writeLock == null ) {
			c.sock.close();
			return;
		}
		// no longer allow writes & queue changes
		c.needClose = true;
		// make sure that no write or queue change is in progress
		c.writeLock.acquire();
		// prevent multiple closes
		if( c.closed ) {
			c.writeLock.release();
			return;
		}
		// remove from our socket list (only one time)
		// this will trigger a close() and a socket removal
		if( notify ) {
			if( c.inSocketList ) {
				c.inSocketList = false;
				pendingSocks.add(c);
			}
			c.writeLock.release();
			return;
		}
		c.closed = true;
		c.inSocketList = false;
		c.writeLock.release();
		// close the socket
		c.sock.close();
		
		// store the client in cleanup list
		var f = getFile(c.file);
		f.lock.acquire();
		if( f.toClean.length == 0 ) {
			// setup delayed queue cleanup
			var n = new ModToraApi.NullClient(c.file, c.hostName, "/");
			n.onRequestDone = function(api) {
				f.lock.acquire();
				var toClean = f.toClean;
				f.toClean = new List();
				f.lock.release();
				api.cleanClients(toClean);
			};
			handleRequest(n);
		}
		f.toClean.add(c);
		f.lock.release();
	}

	function initLoader( api : ModToraApi ) {
		var me = this;
		var mod_neko = neko.NativeString.ofString("mod_neko@");
		var mem_size = "std@mem_size";
		var self : neko.vm.Loader = null;
		var first_module = true;
		var loadPrim = function(prim:String,nargs:Int) {
			if( untyped __dollar__sfind(prim.__s,0,mod_neko) == 0 ) {
				var p = Reflect.field(api,prim.substr(9));
				if( p == null || untyped __dollar__nargs(p) != nargs )
					throw "Primitive not found "+prim+" "+nargs;
				return untyped __dollar__varargs( function(args) return __dollar__call(p,api,args) );
			}
			if( prim == mem_size )
				return function(_) return 0;
			return me.rootLoader.loadPrimitive(prim,nargs);
		};
		var loadModule = function(module:String,l) {
			var idx = module.lastIndexOf(".");
			if( idx >= 0 )
				module = module.substr(0,idx);
			var cache : Dynamic = untyped self.l.cache;
			var mod = Reflect.field(cache,module);
			if( mod == null ) {
				if( me.jit && first_module )
					me.enable_jit(true);
				mod = neko.vm.Module.readPath(module,me.modulePath,self);
				if( first_module ) {
					first_module = false;
					api.module = mod;
					if( me.jit ) me.enable_jit(false);
				}
				Reflect.setField(cache,module,mod);
				mod.execute();
			}
			return mod;
		};
		self = neko.vm.Loader.make(loadPrim,loadModule);
		return self;
	}

	public function getFileTime( file ) {
		return try neko.FileSystem.stat(file).mtime.getTime() catch( e : Dynamic ) 0.;
	}

	public function getCurrentClient() {
		var t = tls.value;
		return (t == null) ? null : t.client;
	}

	public function delay( t : Float, f, repeat : Bool ) {
		var t : Timer = { time : t, elapsed : 0., callb : f, repeat : repeat };
		delayLock.acquire();
		delayQueue.add(t);
		delayLock.release();
		delayWait.release(); // signal
		return t;
	}
	
	public function getFile( file : String ) {
		var f = files.get(file);
		if( f != null )
			return f;
		// file entry not found : we need to acquire
		// a global lock before setting the entry
		flock.acquire();
		f = files.get(file);
		if( f == null ) {
			f = {
				file : file,
				filetime : 0.,
				loads : 0,
				cacheHits : 0,
				lock : new neko.vm.Mutex(),
				cache : new haxe.FastList<ModToraApi>(),
				bytes : 0.,
				time : 0.,
				cron : null,
				toClean : new List(),
			};
			files.set(file,f);
		}
		flock.release();
		return f;
	}
	
	public function getInstance( file : String, host : String ) {
		var f = getFile(file);
		
		// fast path : get from cache
		f.lock.acquire();
		var time = getFileTime(file);
		var api = if( time == f.filetime ) f.cache.pop() else null;
		f.lock.release();
		
		// at the end of the request, put back to cache
		var nc = new ModToraApi.NullClient(file, host, "/");
		nc.onRequestDone = function(_) {
			f.lock.acquire();
			api.client = null;
			if( api.main != null && f.filetime == time )
				f.cache.add(api);
			f.lock.release();
		};
		
		if( api != null ) {
			api.client = nc;
			return api;
		}
		
		// slow path : load a new instance
		api = new ModToraApi(nc);
		redirect(api.print);
		try {
			initLoader(api).loadModule(file);
		} catch( e : Dynamic ) {
		}
		return api;
	}
	
	function threadLoop( t : ThreadData ) {
		tls.value = t;
		set_trusted(true);
		while( true ) {
			var client = clientQueue.pop(true);
			if( client == null ) {
				// let other threads pop 'null' as well
				// in case of global restart
				t.stopped = true;
				break;
			}
			t.time = haxe.Timer.stamp();
			t.client = client;
			t.hits++;
			// retrieve request
			try {
				client.sock.setTimeout(3);
				while( !client.processMessage() ) {
				}
				if( client.execute && client.file == null )
					throw "Missing module file";
				if( client.execute && client.needClose )
					throw "Closed client";
			} catch( e : Dynamic ) {
				if( client.secure ) log("Error while reading request ("+Std.string(e)+")");
				t.errors++;
				client.execute = false;
			}
			// check if we need to do something
			if( !client.execute ) {
				close(client);
				t.client = null;
				continue;
			}
			var f = getFile(client.file);
			var api = null;
			// check if up-to-date cache is available
			f.lock.acquire();
			var time = getFileTime(client.file);
			if( time != f.filetime ) {
				f.filetime = time;
				f.cache = new haxe.FastList<ModToraApi>();
			}
			api = f.cache.pop();
			if( api == null )
				f.loads++;
			else
				f.cacheHits++;
			f.lock.release();
			// execute
			var code = CExecute;
			var data = "";
			try {
				if( api == null ) {
					api = new ModToraApi(client);
					api.time = time;
					redirect(api.print);
					initLoader(api).loadModule(client.file);
				} else {
					api.client = client;
					redirect(api.print);
					api.main();
				}
				if( client.queues != null )
					code = CListen;
			} catch( e : Dynamic ) {
				code = CError;
				data = try Std.string(e) + haxe.Stack.toString(haxe.Stack.exceptionStack()) catch( _ : Dynamic ) "??? TORA Error";
			}
			// send result
			try {
				client.sendHeaders(); // if no data has been printed
				client.sock.setFastSend(true);
				client.sendMessage(code,data);
			} catch( e : Dynamic ) {
				if( client.secure ) log("Error while sending answer ("+Std.string(e)+")");
				t.errors++;
				client.needClose = true;
			}
			
			client.onRequestDone(api);
			
			// save infos
			f.lock.acquire();
			f.time += haxe.Timer.stamp() - t.time;
			f.bytes += client.dataBytes;
			api.client = null;
			if( api.main != null && f.filetime == time )
				f.cache.add(api);
			f.lock.release();
			// cleanup
			redirect(null);
			t.client = null;
			// release shares
			if( client.lockedShares != null ) {
				for( s in client.lockedShares ) {
					s.owner = null;
					s.lock.release();
				}
				client.lockedShares = null;
			}
			// close
			if( client.queues == null || client.needClose )
				close(client);
			else {
				client.inSocketList = true;
				pendingSocks.add(client);
			}
		}
	}

	function run( host : String, port : Int, secure : Bool ) {
		var s = new neko.net.Socket();
		try {
			s.bind(new neko.net.Host(host),port);
		} catch( e : Dynamic ) {
			throw "Failed to bind socket : invalid host or port is busy";
		}
		s.listen(100);
		try {
			while( running ) {
				var sock = s.accept();
				handleRequest(new Client(sock,secure));
			}
		} catch( e : Dynamic ) {
			log("accept() failure : maybe too much FD opened ?");
		}
		// close our waiting socket
		s.close();
	}

	function stop() {
		log("Shuting down...");
		// inform all threads that we are stopping
		for( i in 0...threads.length )
			clientQueue.add(null);
		// our own marker
		clientQueue.add(null);
		var count = 0;
		while( true ) {
			var c = clientQueue.pop(false);
			if( c == null )
				break;
			close(c);
			count++;
		}
		log(count + " sockets closed in queue...");
		// wait for threads to stop
		neko.Sys.sleep(5);
		count = 0;
		for( t in threads )
			if( t.stopped )
				count++;
			else
				log("Thread "+t.id+" is locked in "+((t.client == null)?"???":t.client.getURL()));
		log(count + " / " + threads.length + " threads stopped");
	}


	public function command( cmd : String, param : String ) : Void {
		switch( cmd ) {
		case "stop":
			running = false;
		case "gc":
			neko.vm.Gc.run(true);
		case "clean":
			flock.acquire();
			for( f in files.keys() )
				files.remove(f);
			flock.release();
		case "hosts":
			for( h in hosts.keys() )
				neko.Lib.println("Host '"+h+"', Root '"+hosts.get(h)+"'<br>");
		case "share":
			ModToraApi.shares_lock.acquire();
			var bytes = neko.Lib.load("std","mem_size",1);
			var total = 0;
			for( s in ModToraApi.shares ) {
				var c = s.owner;
				var size = bytes(s.data);
				total += size;
				neko.Lib.print("Share '"+s.name+"' "+Math.ceil(size/1024)+" KB");
				if( c != null ) {
					neko.Lib.print(" locked by "+c.getURL());
					var ws = c.waitingShare;
					if( ws != null ) neko.Lib.print(" waiting for "+ws.name);
				}
				neko.Lib.println("<br>");
			}
			neko.Lib.println("Total : "+Math.ceil(total/1024)+" KB<br>");
			ModToraApi.shares_lock.release();
		case "thread":
			var t = threads[Std.parseInt(param)];
			if( t == null ) throw "No such thread";
			var c = t.client;
			var inf = [
				"Thread " + (t.id + 1),
				"URL " + (c == null ? "idle" : c.getURL()),
			];
			if( c != null ) {
				inf.push("Host " + c.hostName);
				inf.push("GET " + c.getParams);
				if( c.postData != null )
					inf.push("POST " + StringTools.urlEncode(c.postData));
				inf.push("Headers:");
				for( h in c.headers )
					inf.push("\t" + h.k + ": " + h.v);
				try {
					var s = untyped haxe.Stack.makeStack(neko.Lib.load("std", "thread_stack", 1)(untyped t.t.handle));
					inf.push("Stack:");
					var selts = haxe.Stack.toString(s).split("\n");
					if( selts[0] == "" ) selts.shift();
					for( s in selts )
						inf.push("\t" + s);
				} catch( e : Dynamic ) {
					inf.push("Stack not available");
				}
			}
			var lines = StringTools.htmlEscape(inf.join("\n")).split("\n");
			for( i in 0...lines.length ) {
				var li = lines[i];
				if( li.charCodeAt(0) != "\t".code ) {
					var parts = li.split(" ");
					var w = parts.shift();
					lines[i] = "<b>" + w + "</b> " + parts.join(" ");
				}
			}
			neko.Lib.println(lines.join("<br>").split("\t").join("&nbsp; &nbsp; "));
		default:
			throw "No such command '"+cmd+"'";
		}
	}

	public function infos() : Infos {
		var tinf = new Array();
		var tot = 0;
		for( t in threads ) {
			var cur = t.client;
			var ti : ThreadInfos = {
				hits : t.hits,
				errors : t.errors,
				file : (cur == null) ? null : (cur.file == null ? "???" : cur.file),
				url : (cur == null) ? null : cur.getURL(),
				time : (haxe.Timer.stamp() - t.time),
			};
			tot += t.hits;
			tinf.push(ti);
		}
		var finf = new Array();
		for( f in files ) {
			var f : FileInfos = {
				file : f.file,
				loads : f.loads,
				cacheHits : f.cacheHits,
				cacheCount : Lambda.count(f.cache),
				bytes : f.bytes,
				time : f.time,
			};
			finf.push(f);
		}
		var queue = new List();
		while( true ) {
			var c = clientQueue.pop(false);
			if( c == null ) break;
			queue.add(c);
		}
		var queueSize = queue.length;
		for( c in queue )
			clientQueue.add(c);
		return {
			threads : tinf,
			files : finf,
			totalHits : totalHits,
			recentHits : recentHits,
			queue : totalHits - tot,
			activeConnections : activeConnections,
			upTime : haxe.Timer.stamp() - startTime,
			jit : jit,
		};
	}

	function loadConfig( cfg : String ) {
		var vhost = false;
		var root = null, names = null;
		// parse the apache configuration to extract virtual hosts
		for( l in ~/[\r\n]+/g.split(cfg) ) {
			l = StringTools.trim(l);
			var lto = l.toLowerCase();
			if( !vhost ) {
				if( StringTools.startsWith(lto,"<virtualhost") ) {
					vhost = true;
					root = null;
					names = new Array();
				}
			} else if( lto == "</virtualhost>" ) {
				vhost = false;
				if( root != null )
					for( n in names )
						if( !hosts.exists(n) )
							hosts.set(n,root);
			} else {
				var cmd = ~/[ \t]+/g.split(l);
				switch( cmd.shift().toLowerCase() ) {
				case "documentroot":
					var path = cmd.join(" ");
					// replace all \ by / (same as apache)
					path = path.split("\\").join("/");
					if( path.length > 0 && path.charAt(path.length-1) != "/" )
						path += "/";
					root = path+"index.n";
				case "servername", "serveralias": names = names.concat(cmd);
				}
			}
		}
	}

	public function resolveHost( name : String ) {
		return hosts.get(name);
	}

	public function handleRequest( c : Client ) {
		totalHits++;
		clientQueue.add(c);
	}

	var xmlCache : String;
	public function getCrossDomainXML() {
		if( xmlCache != null ) return xmlCache;
		var buf = new StringBuf();
		buf.add("<cross-domain-policy>");
		for( host in hosts.keys() )
			buf.add('<allow-access-from domain="'+host+'" to-ports="'+ports.join(",")+'"/>');
		buf.add("</cross-domain-policy>");
		buf.addChar(0);
		xmlCache = buf.toString();
		return xmlCache;
	}

	public static function log( msg : String ) {
		neko.io.File.stderr().writeString("["+Date.now().toString()+"] "+msg+"\n");
	}

	public static var inst : Tora;

	static function main() {
		var host = "127.0.0.1";
		var port = 6666;
		var args = neko.Sys.args();
		var nthreads = 32;
		var i = 0;
		// skip first argument for haxelib "run"
		if( args[0] != null && StringTools.endsWith(args[0],"/") )
			i++;
		var unsafe = new List();
		inst = new Tora();
		while( true ) {
			var kind = args[i++];
			var value = function() { var v = args[i++]; if( v == null ) throw "Missing value for '"+kind+"'"; return v; };
			if( kind == null ) break;
			switch( kind ) {
			case "-h","-host": host = value();
			case "-p","-port": port = Std.parseInt(value());
			case "-t","-threads": nthreads = Std.parseInt(value());
			case "-config": inst.loadConfig(neko.io.File.getContent(value()));
			case "-unsafe":
				var hp = value().split(":");
				if( hp.length != 2 ) throw "Unsafe format should be host:port";
				var port = Std.parseInt(hp[1]);
				inst.ports.push(port);
				unsafe.add({ host : hp[0], port : port });
			default: throw "Unknown argument "+kind;
			}
		}
		inst.init(nthreads);
		for( u in unsafe ) {
			log("Opening unsafe port on "+u.host+":"+u.port);
			neko.vm.Thread.create(callback(inst.run,u.host,u.port,false));
		}
		log("Starting Tora server on "+host+":"+port+" with "+nthreads+" threads");
		inst.run(host,port,true);
		inst.stop();
	}

}