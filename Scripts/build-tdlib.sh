#!/bin/zsh
# Builds TDLib (JSON interface) + copies OpenSSL dylibs into Vendor/tdlib so the TelegramSource target links.
# Needs: Xcode, cmake, gperf, openssl@3 (brew install cmake gperf openssl@3). ~20–40 min on Apple silicon.
set -euo pipefail
cd "$(dirname "$0")/.."
TD_COMMIT="${TD_COMMIT:-d1085f9}"      # TDLib 1.8.67 — the version Brownie was tested with
SRC="${TD_SRC:-.build/td}"
OPENSSL="$(brew --prefix openssl@3)"
[ -d "$SRC/.git" ] || git clone https://github.com/tdlib/td.git "$SRC"
git -C "$SRC" fetch -q origin && git -C "$SRC" checkout -q "$TD_COMMIT"
cmake -S "$SRC" -B "$SRC/build" -DCMAKE_BUILD_TYPE=Release -DOPENSSL_ROOT_DIR="$OPENSSL" -DCMAKE_INSTALL_PREFIX="$SRC/out" >/dev/null
cmake --build "$SRC/build" --target tdjson -j "$(sysctl -n hw.ncpu)"
mkdir -p Vendor/tdlib/lib Vendor/tdlib/include/td/telegram
cp "$SRC/build/libtdjson.dylib" Vendor/tdlib/lib/
cp "$SRC/td/telegram/td_json_client.h" Vendor/tdlib/include/td/telegram/
# tdjson_export.h is generated into the build tree
cp "$SRC/build/td/telegram/tdjson_export.h" Vendor/tdlib/include/td/telegram/ 2>/dev/null || cp "$SRC/td/telegram/tdjson_export.h" Vendor/tdlib/include/td/telegram/ 2>/dev/null || echo "tdjson_export.h not regenerated; keeping the vendored copy"
cp "$OPENSSL/lib/libssl.3.dylib" "$OPENSSL/lib/libcrypto.3.dylib" Vendor/tdlib/lib/
# @rpath install names so the dylibs can live in Brownie.app/Contents/Frameworks. Its own script
# because CI restores these from a cache and never gets here — see the note at the top of it.
./Scripts/rpath-tdlib.sh
echo "TDLib ready in Vendor/tdlib/lib"
