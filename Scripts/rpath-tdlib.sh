#!/bin/zsh
# Points the vendored dylibs at each other by @rpath, so they work wherever they are copied to —
# Brownie.app/Contents/Frameworks, a test bundle, a CI runner.
#
# This is its own script, and not three lines inside build-tdlib.sh, because CI restores the built
# dylibs from a cache and never runs the build. Whatever that cache holds has to be corrected on the
# way in, or the first openssl bump after it was filled breaks every run with a dlopen failure at
# test time — which is exactly what happened: Homebrew records its own dependencies by Cellar path
# (.../Cellar/openssl@3/3.6.5/lib/...), the version in that path changes with every bump, and the
# old one is deleted. Matching on `brew --prefix` (a symlink, .../opt/openssl@3) never matches it.
#
# So: read what each file actually records and rewrite that, rather than a path we guessed.
set -euo pipefail
cd "$(dirname "$0")/.."
LIB=Vendor/tdlib/lib
[ -d "$LIB" ] || { echo "no $LIB — run Scripts/build-tdlib.sh first"; exit 1 }

chmod u+w "$LIB"/*.dylib
for name in libtdjson libssl.3 libcrypto.3; do
    f="$LIB/$name.dylib"
    [ -f "$f" ] || continue
    install_name_tool -id "@rpath/$name.dylib" "$f"          # first, so the id is not then mistaken for a dependency
    otool -L "$f" | awk 'NR>1 {print $1}' \
        | grep -E '/(libtdjson|libssl\.3|libcrypto\.3)\.dylib$' | grep -v '^@rpath/' \
        | while read -r dep; do install_name_tool -change "$dep" "@rpath/${dep:t}" "$f"; done
done
codesign -fs - "$LIB"/*.dylib

# Fail here, where the cause is on screen, rather than at `swift test` as "the bundle couldn't be loaded".
deps() { otool -L "$LIB"/*.dylib | grep '^\t' | grep -E '/(libtdjson|libssl\.3|libcrypto\.3)\.dylib ' }
if deps | grep -qv '@rpath'; then
    echo "an absolute path to openssl or tdjson survived:"; deps | grep -v '@rpath'; exit 1
fi
echo "vendored dylibs reference each other by @rpath"
