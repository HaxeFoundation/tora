#!/bin/bash
haxe tora.hxml
if [ -d "release" ]
then
	rm -rf release
fi
mkdir release
mkdir release\tora

cp "tora.n" "release/tora/run.n"
cp "haxelib.json" "release"
cp "tora.hxml" "release"
cp "CHANGES.txt" "release"
cd tora
cp "*.hx" "../release/tora"
cd ..

#7z a -tzip release.zip release
#rm -rf release
#haxelib submit release.zip
read -rsp $'Press any key to continue...\n' -n1 key