#!/usr/bin/env bash
set -euo pipefail

# Cross-compile zlib as a static library for wasm32-wasi (LindWasm).
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
: "${LIND_WASM_ROOT:=${LIND_WASM_ROOT:-$(cd "$REPO_ROOT/.." && pwd)/lind-wasm}}"

BASE_SYSROOT="${BASE_SYSROOT:-$LIND_WASM_ROOT/src/glibc/sysroot}"
LLVM_BIN="${LLVM_BIN:-$(ls -d "$LIND_WASM_ROOT"/clang+llvm-*/bin 2>/dev/null | head -n1)}"

if [[ -z "${LLVM_BIN}" || ! -x "$LLVM_BIN/clang" ]]; then
  echo "ERROR: LLVM not found under $LIND_WASM_ROOT"; exit 1
fi
if [[ ! -r "$BASE_SYSROOT/include/wasm32-wasi/stdio.h" ]]; then
  echo "ERROR: sysroot headers missing at $BASE_SYSROOT"; exit 1
fi

CC_WASI="$LLVM_BIN/clang --target=wasm32-unknown-wasi --sysroot=$BASE_SYSROOT"
AR="$LLVM_BIN/llvm-ar"
RANLIB="$LLVM_BIN/llvm-ranlib"

OVERLAY="$REPO_ROOT/build/sysroot_overlay"
mkdir -p "$OVERLAY/usr/lib/wasm32-wasi" "$OVERLAY/usr/include"

echo "[zlib] CC=$CC_WASI"
pushd "$REPO_ROOT/zlib" >/dev/null

make distclean || true

CC="$CC_WASI" AR="$AR" RANLIB="$RANLIB" \
CFLAGS="--sysroot=$BASE_SYSROOT -O2 -g" \
LDFLAGS="--sysroot=$BASE_SYSROOT" \
./configure --static --prefix="$OVERLAY/usr"

make -j

cp libz.a "$OVERLAY/usr/lib/wasm32-wasi/libz.a"
"$RANLIB" "$OVERLAY/usr/lib/wasm32-wasi/libz.a"
cp zlib.h zconf.h "$OVERLAY/usr/include/"

popd >/dev/null
echo "[zlib] done → $OVERLAY/usr/lib/wasm32-wasi/libz.a"
