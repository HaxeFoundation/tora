@echo off
haxe tora.hxml
IF EXIST release rmdir /S/Q release
mkdir release
mkdir release\tora
copy "tora.n" "release/tora/run.n"
copy "haxelib.json" "release"
copy "tora.hxml" "release"
copy "CHANGES.txt" "release"
cd tora
copy "*.hx" "../release/tora"
cd ..

rem 7z a -tzip release.zip release
rem del /Q release
rem haxelib submit release.zip
pause