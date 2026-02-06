#!/usr/bin/env bash
set -euo pipefail

# lmbench WASM build helper for lind-wasm-apps
#
# High level:
#   1) Load toolchain from build/.toolchain.env (set by top-level Makefile preflight).
#   2) Build a combined libc.a = merged sysroot libc.a + libtirpc objects.
#   3) Build lmbench with a WASI toolchain (REAL_CC).
#   4) Stage binaries under build/bin/lmbench/wasm32-wasi.
#   5) Run wasm-opt + wasmtime compile on staged binaries:
#        - <name>.opt.wasm
#        - <name>.cwasm


# ----------------------------------------------------------------------
# 0) Paths and repo layout
# ----------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Default LIND_WASM_ROOT to parent directory (layout: lind-wasm/lind-wasm-apps)
if [[ -z "${LIND_WASM_ROOT:-}" ]]; then
  LIND_WASM_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
fi

APPS_BUILD="$REPO_ROOT/build"
APPS_OVERLAY="$APPS_BUILD/sysroot_overlay"
MERGED_SYSROOT="$APPS_BUILD/sysroot_merged"
APPS_LIB_DIR="$APPS_BUILD/lib"
APPS_BIN_ROOT="$APPS_BUILD/bin/lmbench"
TOOL_ENV="$APPS_BUILD/.toolchain.env"
MAX_WASM_MEMORY="${MAX_WASM_MEMORY:-67108864}"
ENABLE_WASI_THREADS="${ENABLE_WASI_THREADS:-1}"

# We follow lind_compile's convention for WASMTIME_PROFILE (debug vs release)
WASM_OPT="${WASM_OPT:-$LIND_WASM_ROOT/tools/binaryen/bin/wasm-opt}"

WASMTIME_PROFILE="${WASMTIME_PROFILE:-release}"
WASMTIME="${WASMTIME:-$LIND_WASM_ROOT/build/wasmtime}"
# Fallback to release if the requested profile isn't built yet.
if [[ ! -x "${WASMTIME}" ]]; then
  echo "ERROR: wasmtime missing: ${WASMTIME}" >&2
  exit 127 # Note: This is the traditional "command not found" exit code, can be changed as needed
fi

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

supports_cflag() {
  local flag="$1"
  printf 'int main(void){return 0;}\n' | \
    "$CLANG" --target=wasm32-unknown-wasi --sysroot="$MERGED_SYSROOT" \
    $flag -x c -c -o /dev/null - >/dev/null 2>&1
}


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
mkdir -p "$LM_BENCH_BIN_DIR"

REAL_CC="$CLANG --target=wasm32-unknown-wasi --sysroot=$MERGED_SYSROOT"
CFLAGS="-O2 -g -I$MERGED_SYSROOT/include -I$MERGED_SYSROOT/include/wasm32-wasi -I$MERGED_SYSROOT/include/tirpc"
LDFLAGS_WASM=(
  "-Wl,--import-memory,--export-memory,--max-memory=${MAX_WASM_MEMORY},--export=__stack_pointer,--export=__stack_low"
"-L$MERGED_SYSROOT/lib/wasm32-wasi"
  "-L$MERGED_SYSROOT/usr/lib/wasm32-wasi"
  "-L$APPS_LIB_DIR"
)
if [[ "$ENABLE_WASI_THREADS" == "1" ]]; then
  thread_flag="-mthread-model=posix"
  if ! supports_cflag "$thread_flag"; then
    thread_flag=""
  fi
  if supports_cflag "-pthread" && supports_cflag "-matomics" && supports_cflag "-mbulk-memory"; then
    CFLAGS+=" -pthread -matomics -mbulk-memory"
    if [[ -n "$thread_flag" ]]; then
      CFLAGS+=" $thread_flag"
    else
      echo "[lmbench] WARNING: clang does not support -mthread-model=posix; skipping thread model flag."
    fi
    LDFLAGS_WASM+=("-Wl,--shared-memory")
  else
    echo "[lmbench] WARNING: clang does not support wasi-threads flags; disabling shared memory."
    ENABLE_WASI_THREADS="0"
  fi
fi
LDFLAGS="${LDFLAGS_WASM[*]}"
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

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

shopt -s nullglob
bin_files=("$LM_BENCH_BIN_DIR"/*)
shopt -u nullglob

have_files=0
for f in "${bin_files[@]}"; do
  case "$f" in
    *.o|*.a|*.cwasm|*.opt.wasm|*.opt.wasm.cwasm) continue ;;  # skip non-executable artifacts and post-processed outputs
  esac
  cp "$f" "$OUT_DIR/"
  have_files=1
done

if (( have_files == 0 )); then
  echo "[lmbench] ERROR: no non-.o binaries found in $LM_BENCH_BIN_DIR" >&2
  exit 1
fi

echo "[lmbench] staged binaries under $OUT_DIR"

# ----------------------------------------------------------------------
# 5) wasm-opt + wasmtime compile per binary
# ----------------------------------------------------------------------
if [[ ! -x "$WASM_OPT" && ! -x "$WASMTIME" ]]; then
  echo "[lmbench] NOTE: neither wasm-opt nor wasmtime found; skipping .opt.wasm/.cwasm generation."
  exit 0
fi

echo "[lmbench] post-processing staged binaries under $OUT_DIR ..."

shopt -s nullglob
stage_bins=("$OUT_DIR"/*)
shopt -u nullglob

for f in "${stage_bins[@]}"; do
  case "$f" in
    *.o|*.a|*.cwasm|*.opt.wasm|*.opt.wasm.cwasm) continue ;;
  esac

  base="$(basename -- "$f")"
  bin_for_compile="$f"

  # wasm-opt pass -> <name>.opt.wasm
  if [[ -x "$WASM_OPT" ]]; then
    OPT_OUT="$OUT_DIR/${base}.opt.wasm"
    echo "[lmbench]   wasm-opt: $base → $(basename -- "$OPT_OUT")"
    if "$WASM_OPT" --epoch-injection --asyncify --debuginfo -O2 \
        "$f" -o "$OPT_OUT"; then
      bin_for_compile="$OPT_OUT"
    else
      echo "[lmbench]   WARNING: wasm-opt failed for '$base'; continuing with unoptimized binary."
      bin_for_compile="$f"
    fi
  fi

  # wasmtime compile -> <name>.cwasm
  if [[ -x "$WASMTIME" ]]; then
    CWASM_OUT="$OUT_DIR/${base}.cwasm"
    echo "[lmbench]   wasmtime compile: $base → $(basename -- "$CWASM_OUT")"
    if ! "$WASMTIME" compile "$bin_for_compile" -o "$CWASM_OUT"; then
      echo "[lmbench]   WARNING: wasmtime compile failed for '$base'; continuing."
    fi
  fi
done

echo "[lmbench] post-processing complete."

