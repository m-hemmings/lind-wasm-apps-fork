#!/usr/bin/env bash
set -euo pipefail

# Portable libtirpc build for WASI; no apt, no sudo.
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
MERGE_TMP="$OVERLAY/usr/lib/wasm32-wasi/merge_tmp"
mkdir -p "$OVERLAY/usr/include/tirpc" "$MERGE_TMP"

echo "[libtirpc] CC=$CC_WASI"
pushd "$REPO_ROOT/libtirpc" >/dev/null

autoreconf -fi
CC="$CC_WASI" AR="$AR" RANLIB="$RANLIB" \
CFLAGS="--sysroot=$BASE_SYSROOT -O2 -g" \
LDFLAGS="--sysroot=$BASE_SYSROOT" \
PKG_CONFIG=false \
./configure --host=wasm32-unknown-wasi --disable-gssapi --disable-shared --enable-static --with-pic --sysconfdir=/etc \
  ac_cv_func_malloc_0_nonnull=yes ac_cv_func_memset=yes ac_cv_func_strchr=yes

make -j
rsync -a "tirpc/" "$OVERLAY/usr/include/tirpc/"
find "src" -name '*.o' -exec cp {} "$MERGE_TMP/" \;
"$AR" rcs "$OVERLAY/usr/lib/wasm32-wasi/libtirpc.a" "$MERGE_TMP"/*.o
"$RANLIB" "$OVERLAY/usr/lib/wasm32-wasi/libtirpc.a"

popd >/dev/null
echo "[libtirpc] done → $OVERLAY/usr/lib/wasm32-wasi/libtirpc.a"
