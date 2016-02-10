# tora

[![Build Status](https://travis-ci.org/HaxeFoundation/tora.svg?branch=master)](https://travis-ci.org/HaxeFoundation/tora)

NekoVM Application Server

## quick start

1. Install neko, which includes `mod_neko*.ndll` and `mod_tora*.ndll` (`*` should be a number).

2. Enable mod_neko and mod_tora in the apache configuration file:
 ```
 LoadModule neko_module path/to/mod_neko*.ndll
 LoadModule tora_module path/to/mod_tora*.ndll
 AddHandler tora-handler .n
 DirectoryIndex index.n
 ```

3. Compile and launch the tora server.
 ```
 cd path/to/tora
 haxe tora.hxml
 neko tora.n
 ```

4. Compile a index.n, which is the application code.
 ```haxe
 // Index.hx
 class Index {
 	static function main():Void {
 		trace("hello world!");
 	}
 }
 ```
 ```
 # build.hxml
 -neko index.n
 -main Index
 ```

5. Place `index.n` in the `DocumentRoot` as specified by the apache configuration file.

6. Visit the address and port (`Listen`, `ServerName`, and/or `VirtualHost`) as specified by the apache configuration file. It is usually `http://localhost/` or `http://localhost:8080/`. The page should show `Index.hx:3: hello world!`.
