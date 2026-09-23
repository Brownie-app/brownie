#!/bin/zsh
# Compile-check the pure targets with swiftc directly (used while SwiftPM is unavailable).
set -e
cd "$(dirname "$0")/.."
OUT=.build/check; mkdir -p $OUT
SDK=$(xcrun --show-sdk-path)
FLAGS=(-sdk $SDK -target arm64-apple-macosx14.0 -parse-as-library -I $OUT -L $OUT -Xcc -I -Xcc Sources/CSQLite -Xcc -fmodule-map-file=Sources/CSQLite/module.modulemap)
build() { # name, deps...
  local name=$1; shift
  local libs=(); for d in "$@"; do libs+=(-l$d); done
  echo "→ $name"
  swiftc "${FLAGS[@]}" -module-name $name -emit-module -emit-module-path $OUT/$name.swiftmodule -emit-library -o $OUT/lib$name.dylib "${libs[@]}" Sources/$name/*.swift
}
build Support
build Domain Support
build Platform Support Domain -lsqlite3
build Privacy Support Domain
build LocalSources Support Domain Platform
echo "all good"
