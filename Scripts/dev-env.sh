# Source this before swift commands on macOS 26 without Xcode 26: the Command Line Tools build the app;
# Swift Testing comes from the CLT's own frameworks folder (plus its interop dylib next door).
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
T=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
L=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
export BROWNIE_TEST_FLAGS="-Xswiftc -F$T -Xlinker -F$T -Xlinker -rpath -Xlinker $T -Xlinker -rpath -Xlinker $L"
