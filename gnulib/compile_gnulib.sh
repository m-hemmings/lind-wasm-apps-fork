#!/usr/bin/env bash
set -euo pipefail

# Build a minimal libgnu.a from gnulib for wasm32-wasi (LindWasm).
# Uses gnulib-tool to generate a buildable testdir, then cross-compiles it.

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

# Where your gnulib checkout lives
GNULIB_DIR="${GNULIB_DIR:-$REPO_ROOT/gnulib}"

if [[ ! -x "$GNULIB_DIR/gnulib-tool" && ! -x "$GNULIB_DIR/gnulib-tool.py" ]]; then
  echo "ERROR: gnulib-tool(.py) not found/executable under $GNULIB_DIR"
  exit 1
fi

# Prefer wrapper if present, else call python script directly
if [[ -x "$GNULIB_DIR/gnulib-tool" ]]; then
  GNULIB_TOOL="$GNULIB_DIR/gnulib-tool"
else
  GNULIB_TOOL="$GNULIB_DIR/gnulib-tool.py"
fi

OVERLAY="$REPO_ROOT/build/sysroot_overlay"
mkdir -p "$OVERLAY/usr/lib/wasm32-wasi" "$OVERLAY/usr/include"

BUILD_ROOT="$REPO_ROOT/build/gnulib_wasi"
TESTDIR="$BUILD_ROOT/testdir"
mkdir -p "$BUILD_ROOT"
rm -rf "$TESTDIR"

# Pick modules deliberately. Add only what you need.
MODULES=(
  canonicalize-lgpl
  mkstemp
  putenv
  rpmatch
)

echo "[gnulib] generating testdir at $TESTDIR"
pushd "$GNULIB_DIR" >/dev/null

"$GNULIB_TOOL" \
  --create-testdir \
  --dir="$TESTDIR" \
  --single-configure \
  --without-tests \
  --avoid=threadlib \
  "${MODULES[@]}"

popd >/dev/null

echo "[gnulib] configure/build (host=wasm32-unknown-wasi)"
pushd "$TESTDIR" >/dev/null

# Cross-compile cache answers. Add as configure complains.
CACHE_VARS=(
  "gl_cv_func_getcwd_null=yes"
  "gl_cv_func_getcwd_path_max=yes"
  "gl_cv_func_working_mkstemp=yes"
  "gl_cv_func_working_putenv=yes"
  "gl_cv_func_working_rpmatch=yes"
  "ac_cv_func_malloc_0_nonnull=yes"
  "ac_cv_func_realloc_0_nonnull=yes"
)

# Bootstrap the generated project (safe if bootstrap isn't present)
if [[ -x ./bootstrap ]]; then
  ./bootstrap --no-git --skip-po || true
fi

CC="$CC_WASI" AR="$AR" RANLIB="$RANLIB" \
CFLAGS="--sysroot=$BASE_SYSROOT -O2 -g" \
LDFLAGS="--sysroot=$BASE_SYSROOT" \
PKG_CONFIG=false \
./configure \
  --host=wasm32-unknown-wasi \
  --disable-shared \
  --enable-static \
  --disable-nls \
  "${CACHE_VARS[@]}"

make -j

# gnulib testdirs often put libgnu.a in gllib/, sometimes in lib/
LIBGNU_PATH=""
if [[ -f "gllib/libgnu.a" ]]; then
  LIBGNU_PATH="gllib/libgnu.a"
elif [[ -f "lib/libgnu.a" ]]; then
  LIBGNU_PATH="lib/libgnu.a"
else
  echo "ERROR: expected libgnu.a not found; listing archives:"
  find . -maxdepth 3 -name '*.a' -print
  exit 1
fi

cp -f "$LIBGNU_PATH" "$OVERLAY/usr/lib/wasm32-wasi/libgnu.a"
"$RANLIB" "$OVERLAY/usr/lib/wasm32-wasi/libgnu.a"

# Headers: in testdirs they typically live in gllib/ (sometimes lib/)
mkdir -p "$OVERLAY/usr/include/gnulib"

if [[ -d "gllib" ]]; then
  rsync -a --include='*.h' --exclude='*' "gllib/" "$OVERLAY/usr/include/gnulib/"
fi
if [[ -d "lib" ]]; then
  rsync -a --include='*.h' --exclude='*' "lib/" "$OVERLAY/usr/include/gnulib/" || true
fi

# Generated config headers (names vary)
[[ -f "config.h" ]] && cp -f "config.h" "$OVERLAY/usr/include/gnulib/config.h"
[[ -f "gllib/config.h" ]] && cp -f "gllib/config.h" "$OVERLAY/usr/include/gnulib/gllib_config.h"
[[ -f "lib/config.h" ]] && cp -f "lib/config.h" "$OVERLAY/usr/include/gnulib/lib_config.h"

popd >/dev/null

echo "[gnulib] done → $OVERLAY/usr/lib/wasm32-wasi/libgnu.a"
echo "[gnulib] headers → $OVERLAY/usr/include/gnulib/"

