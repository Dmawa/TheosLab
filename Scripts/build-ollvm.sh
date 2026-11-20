#!/bin/bash
#
# build-ollvm.sh
# Ain
#
# Created by Ain on 2026/11/20.
#

set -euo pipefail
cd "$(dirname "$0")/.."
destination="${1:-$PWD/Generated/Guest/Toolchain}"
revision=a629c1f9ee54a2dc99797dcb71f5a92a8478563f
build="$(mktemp -d)"
trap 'rm -rf "$build"' EXIT
upstream="$build/upstream"
git init -q "$upstream"
git -C "$upstream" fetch -q --depth 1 https://github.com/eshard/obfuscator-llvm.git "$revision"
git -C "$upstream" checkout -q --detach FETCH_HEAD

llvm_headers="${THEOSLAB_LLVM_HEADERS:-/usr/lib/llvm17/include}"
grep -q '^#define LLVM_VERSION_STRING "17.0.5"$' "$llvm_headers/llvm/Config/llvm-config.h"
sources=(
    Toolchain/TheosLabOLLVM.cpp
    "$upstream/bogus/BogusControlFlow.cpp"
    "$upstream/flattening/Flattening.cpp"
    "$upstream/substitution/Substitution.cpp"
    "$upstream/utils/CryptoUtils.cpp"
    "$upstream/utils/Utils.cpp"
)
target=()
start_files=()
end_files=()
if [[ -n "${THEOSLAB_ALPINE_SYSROOT:-}" ]]; then
    sysroot="$THEOSLAB_ALPINE_SYSROOT"
    cxx_headers="$sysroot/usr/include/c++/13.2.1"
    gcc_lib="$sysroot/usr/lib/gcc/aarch64-alpine-linux-musl/13.2.1"
    target=(
        --target=aarch64-alpine-linux-musl "--sysroot=$sysroot"
        "--ld-path=${THEOSLAB_ELF_LINKER:?Set the path to a host ld.lld}"
        -nostdlib -nostdinc++
        -isystem "$cxx_headers"
        -isystem "$cxx_headers/aarch64-alpine-linux-musl"
        -isystem "$sysroot/usr/include"
        -L "$sysroot/usr/lib"
    )
    start_files=("$gcc_lib/crtbeginS.o")
    end_files=("$sysroot/usr/lib/libstdc++.so.6.0.32" "$sysroot/usr/lib/libgcc_s.so.1"
               "$sysroot/lib/ld-musl-aarch64.so.1" "$gcc_lib/crtendS.o")
fi
"${CXX:-clang++}" -std=c++17 -O2 -DNDEBUG -fPIC ${target[@]+"${target[@]}"} \
    -I "$upstream" -isystem "$llvm_headers" ${start_files[@]+"${start_files[@]}"} \
    "${sources[@]}" -shared -Wl,--no-undefined -lLLVM-17 ${end_files[@]+"${end_files[@]}"} \
    -o "$build/ollvm.so"
mkdir -p "$destination"
cp "$build/ollvm.so" "$destination/ollvm.so"
cp "$upstream/LICENSE-OBFUSCATOR.TXT" "$destination/LICENSE-OBFUSCATOR.TXT"
