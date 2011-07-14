package tora;

class Handler<T> {

	public function new() {
	}
	
	public function onNotify( msg : T ) {
	}
	
	public function onStop() {
	}
	
	public function sendData( d : String ) {
		neko.Lib.print(d);
	}
	
}