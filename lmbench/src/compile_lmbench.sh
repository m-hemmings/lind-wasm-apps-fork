#!/usr/bin/env bash
set -euo pipefail

# Paths
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

APPS_BUILD="$REPO_ROOT/build"
APPS_OVERLAY="$APPS_BUILD/sysroot_overlay"
MERGED_SYSROOT="$APPS_BUILD/sysroot_merged"
APPS_LIB_DIR="$APPS_BUILD/lib"
APPS_BIN_ROOT="$APPS_BUILD/bin/lmbench"
TOOL_ENV="$APPS_BUILD/.toolchain.env"

# ----------------------------------------------------------------------
# 1) Load toolchain from Makefile preflight
# ----------------------------------------------------------------------
if [[ -r "$TOOL_ENV" ]]; then
  # shellcheck disable=SC1090
  . "$TOOL_ENV"
else
  echo "[lmbench] ERROR: missing toolchain env '$TOOL_ENV' (run 'make preflight' first)" >&2
  exit 1
fi

: "${CLANG:?missing CLANG in $TOOL_ENV}"
: "${AR:?missing AR in $TOOL_ENV}"
: "${RANLIB:?missing RANLIB in $TOOL_ENV}"

BASE_LIBC="$MERGED_SYSROOT/lib/wasm32-wasi/libc.a"
TIRPC_MERGE_DIR="$APPS_OVERLAY/usr/lib/wasm32-wasi/merge_tmp"

if [[ ! -f "$BASE_LIBC" ]]; then
  echo "[lmbench] ERROR: merged sysroot libc.a not found at: $BASE_LIBC" >&2
  echo "[lmbench] Hint: run 'make merge-sysroot' before 'make lmbench'." >&2
  exit 1
fi

if [[ ! -d "$TIRPC_MERGE_DIR" ]]; then
  echo "[lmbench] ERROR: expected libtirpc .o dir '$TIRPC_MERGE_DIR' not found" >&2
  echo "[lmbench] Hint: did 'make libtirpc' succeed?" >&2
  exit 1
fi

shopt -s nullglob
tirpc_objs=("$TIRPC_MERGE_DIR"/*.o)
shopt -u nullglob

if (( ${#tirpc_objs[@]} == 0 )); then
  echo "[lmbench] ERROR: no libtirpc .o files under $TIRPC_MERGE_DIR" >&2
  exit 1
fi

# ----------------------------------------------------------------------
# 2) Build a combined libc.a = base libc + libtirpc objects
# ----------------------------------------------------------------------
COMB_DIR="$APPS_BUILD/.lmbench_libc_objs"
rm -rf "$COMB_DIR"
mkdir -p "$COMB_DIR"

echo "[lmbench] extracting base libc objects…"
(
  cd "$COMB_DIR"
  "$AR" x "$BASE_LIBC"
)

echo "[lmbench] adding libtirpc objects from $TIRPC_MERGE_DIR…"
cp "${tirpc_objs[@]}" "$COMB_DIR/"

mkdir -p "$APPS_LIB_DIR"
COMBINED_LIBC="$APPS_LIB_DIR/libc.a"

echo "[lmbench] creating combined libc.a → $COMBINED_LIBC"
(
  cd "$COMB_DIR"
  "$AR" rcs "$COMBINED_LIBC" ./*.o
  "$RANLIB" "$COMBINED_LIBC" || true
)

# Replace libc in merged sysroot so clang -lc picks up the combined one
cp "$COMBINED_LIBC" "$BASE_LIBC"



# ----------------------------------------------------------------------
# 3) Run lmbench/src/Makefile with WASI toolchain
# ----------------------------------------------------------------------
LM_BENCH_BIN_DIR="$REPO_ROOT/lmbench/bin/wasm32-wasi"
mkdir -p "$LM_BENCH_BIN_DIR"   # <<< this is the crucial fix

REAL_CC="$CLANG --target=wasm32-unknown-wasi --sysroot=$MERGED_SYSROOT"
CFLAGS="-O2 -g -I$MERGED_SYSROOT/include -I$MERGED_SYSROOT/include/wasm32-wasi -I$MERGED_SYSROOT/include/tirpc"
LDFLAGS="-L$MERGED_SYSROOT/lib/wasm32-wasi -L$MERGED_SYSROOT/usr/lib/wasm32-wasi -L$APPS_LIB_DIR"
# liblmb_stubs.a comes from the Makefile 'stubs' target
LDLIBS="-llmb_stubs -ltirpc -lm"

echo "[lmbench] building suite with REAL_CC='$REAL_CC'"
(
  cd "$REPO_ROOT/lmbench/src"

  # Force a full rebuild so we know fresh binaries are produced
  make clean || true

  make -j \
    OS="wasm32-wasi" \
    O="../bin/wasm32-wasi" \
    CC="$REAL_CC" \
    CFLAGS="$CFLAGS" \
    CPPFLAGS="-I$MERGED_SYSROOT/include/tirpc" \
    LDFLAGS="$LDFLAGS" \
    LDLIBS="$LDLIBS" \
    all
)

    

# ----------------------------------------------------------------------
# 4) Stage binaries under build/bin/lmbench/wasm32-wasi
# ----------------------------------------------------------------------
mkdir -p "$APPS_BIN_ROOT"
OUT_DIR="$APPS_BIN_ROOT/wasm32-wasi"
LM_BENCH_BIN_DIR="$REPO_ROOT/lmbench/bin/wasm32-wasi"

echo "[lmbench] staging binaries from $LM_BENCH_BIN_DIR → $OUT_DIR"

if [[ ! -d "$LM_BENCH_BIN_DIR" ]]; then
  echo "[lmbench] ERROR: expected lmbench output dir '$LM_BENCH_BIN_DIR' not found" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

shopt -s nullglob
bin_files=("$LM_BENCH_BIN_DIR"/*)
shopt -u nullglob

have_files=0
for f in "${bin_files[@]}"; do
  case "$f" in
    *.o|*.a) continue ;;  # skip non-executable artifacts
  esac
  cp "$f" "$OUT_DIR/"
  have_files=1
done

if (( have_files == 0 )); then
  echo "[lmbench] ERROR: no non-.o binaries found in $LM_BENCH_BIN_DIR" >&2
  exit 1
fi

echo "[lmbench] staged binaries under $OUT_DIR"

