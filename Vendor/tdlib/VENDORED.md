TDLib 1.8.67 (Boost Software License 1.0), built from github.com/tdlib/td on 14 Sep 2026 with
`cmake -DCMAKE_BUILD_TYPE=Release` on Apple silicon, plus OpenSSL 3 dylibs from Homebrew, all with
@rpath install names so they can ship inside Brownie.app/Contents/Frameworks.
Rebuild: clone td, cmake --build --target tdjson, copy libtdjson.dylib + the two headers here.

The dylibs are not in git (29 MB of binaries). Run `Scripts/build-tdlib.sh` once to produce them.
