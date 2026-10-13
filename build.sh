#!/usr/bin/env bash
# Builds RogControl.kext and rogctl.
#   ./build.sh [Release|Debug]
# macOS: uses Xcode or the Command Line Tools (xcrun).
# Linux: cross build; set TOOLCHAIN (Apple clang + ld64 + otool + nm in bin/) and MACOS_SDK.
set -euo pipefail

config="${1:-Release}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
version="${MODULE_VERSION:-2.0.0}"
deps="$here/deps"

if [[ "$(uname)" == Darwin ]]; then
    clang="${CLANG:-$(xcrun -f clang)}"
    clangxx="${CLANGXX:-$(xcrun -f clang++)}"
    clang_user="${CLANG_USER:-$clang}"
    ld64="${LD64:-$(xcrun -f ld)}"
    otool="${OTOOL:-$(xcrun -f otool)}"
    nm_tool="${NM:-$(xcrun -f nm)}"
    sdk="${MACOS_SDK:-$(xcrun --show-sdk-path)}"
else
    # The kext needs Apple's clang (kext-style static destructors); upstream clang 17
    # lowers them to __cxa_atexit, which the kernel does not export.
    toolchain="${TOOLCHAIN:?set TOOLCHAIN to the Apple clang/ld64 toolchain}"
    clang="${CLANG:-$toolchain/bin/clang}"
    clangxx="${CLANGXX:-$toolchain/bin/clang++}"
    clang_user="${CLANG_USER:?set CLANG_USER to a clang that targets the macOS SDK}"
    ld64="${LD64:-$toolchain/bin/ld}"
    otool="${OTOOL:-$toolchain/bin/otool}"
    nm_tool="${NM:-$toolchain/bin/nm}"
    sdk="${MACOS_SDK:?set MACOS_SDK to a macOS SDK}"
fi

for f in "$clang" "$clangxx" "$ld64" "$otool" "$nm_tool" "$sdk/SDKSettings.json" \
         "$deps/MacKernelSDK/Library/x86_64/libkmod.a" "$deps/Lilu/Lilu/Headers/kern_api.hpp" \
         "$deps/VirtualSMC/VirtualSMCSDK/kern_vsmcapi.hpp"; do
    [[ -e "$f" ]] || { echo "missing build dependency: $f (run: git submodule update --init)" >&2; exit 1; }
done

case "$config" in
    Release) opt=(-O2 -DNDEBUG=1) ;;
    Debug)   opt=(-O0 -g -DDEBUG=1) ;;
    *) echo "usage: $0 [Release|Debug]" >&2; exit 2 ;;
esac

out="$here/build/$config"
obj="$out/obj"
bundle="$out/RogControl.kext"
rm -rf "$out"
mkdir -p "$obj" "$bundle/Contents/MacOS"

kflags=(
    -target x86_64-apple-macos10.15
    -mkernel -fno-builtin -fno-common -nostdlib -fno-use-cxa-atexit
    -fno-asynchronous-unwind-tables -fno-non-call-exceptions
    -mmmx -msse -msse2 -msse3 -mssse3 -mfpmath=sse -ftree-vectorize
    -DKERNEL -DPRODUCT_NAME=RogControl "-DMODULE_VERSION=$version" -DLILU_CUSTOM_IOKIT_INIT=1
    -I "$deps/MacKernelSDK/Headers" -I "$deps/Lilu/Lilu" -I "$deps/VirtualSMC" -I "$here/RogControl"
    -Wall -Wno-unused-parameter -Wno-ossharedptr-misuse -Wno-vla -Wno-unknown-warning-option
    -Wno-deprecated-declarations -Wno-inconsistent-missing-override
)

objects=()
for src in RogControl/RogControl.cpp RogControl/KeyImplementations.cpp; do
    o="$obj/$(basename "$src" .cpp).o"
    echo "CXX $src"
    "$clangxx" "${kflags[@]}" "${opt[@]}" -std=gnu++20 -fapple-kext -fno-rtti -fno-exceptions -c "$here/$src" -o "$o"
    objects+=("$o")
done

echo "CC  Tools/kmod_info.c"
"$clang" -target x86_64-apple-macos10.15 -mkernel -fno-builtin -fno-common -nostdlib -DKERNEL \
    -I "$deps/MacKernelSDK/Headers" \
    '-DKMOD_INFO_NAME=kmod_info' '-DKMOD_BUNDLE_ID="com.pengubow.RogControl"' "-DKMOD_BUNDLE_VERSION=\"$version\"" \
    -c "$here/Tools/kmod_info.c" -o "$obj/kmod_info.o"
objects+=("$obj/kmod_info.o")

echo "LD  RogControl.kext"
"$ld64" -arch x86_64 -kext -static -macos_version_min 10.15 -undefined dynamic_lookup \
    -o "$bundle/Contents/MacOS/RogControl" "${objects[@]}" "$deps/MacKernelSDK/Library/x86_64/libkmod.a"

sed "s/@VERSION@/$version/g" "$here/RogControl/Info.plist" > "$bundle/Contents/Info.plist"

# Sanity checks: a real kext bundle with the entry points the kernel loader needs.
# (Output is captured first: grep -q exits early, which fails the producer under pipefail.)
header="$("$otool" -hv "$bundle/Contents/MacOS/RogControl")"
grep -q "KEXTBUNDLE" <<<"$header" || { echo "not an MH_KEXT_BUNDLE" >&2; exit 1; }
symbols="$("$nm_tool" "$bundle/Contents/MacOS/RogControl")"
for sym in _kmod_info _RogControl_kern_start _RogControl_kern_stop __realmain __antimain; do
    grep -q " $sym\$" <<<"$symbols" || { echo "missing symbol $sym" >&2; exit 1; }
done
# The kernel exports no __cxa_atexit: a static destructor lowered to it would fail to load.
if grep -q " U ___cxa_atexit\$" <<<"$symbols"; then
    echo "kext imports __cxa_atexit (static destructor); it would not load" >&2; exit 1
fi
echo "built $bundle"

echo "CC  rogctl"
"$clang_user" -target x86_64-apple-macos11 -isysroot "$sdk" -O2 -Wall -fuse-ld="$ld64" \
    -framework IOKit -framework CoreFoundation \
    -o "$out/rogctl" "$here/rogctl/rogctl.c"
echo "built $out/rogctl"
