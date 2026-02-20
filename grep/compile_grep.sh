#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# grep WASI build helper for lind-wasm-apps
#
# Cross-compiles GNU grep 3.12 to wasm32-wasi using the merged sysroot and
# toolchain detected by the top-level Makefile preflight target.
###############################################################################

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GREP_ROOT="$APPS_ROOT/grep"

APPS_BUILD="$APPS_ROOT/build"
MERGED_SYSROOT="$APPS_BUILD/sysroot_merged"
STAGE_DIR="$APPS_BUILD/bin/grep/wasm32-wasi"
TOOL_ENV="$APPS_BUILD/.toolchain.env"

# Default LIND_WASM_ROOT to parent directory (layout: lind-wasm/lind-wasm-apps)
if [[ -z "${LIND_WASM_ROOT:-}" ]]; then
  LIND_WASM_ROOT="$(cd "$APPS_ROOT/.." && pwd)"
fi

WASM_OPT="${WASM_OPT:-$LIND_WASM_ROOT/tools/binaryen/bin/wasm-opt}"
LIND_BOOT="${LIND_BOOT:-$LIND_WASM_ROOT/build/lind-boot}"

JOBS="${JOBS:-$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN || echo 4)}"

# ----------------------------------------------------------------------
# 1) Load toolchain from Makefile preflight
# ----------------------------------------------------------------------
if [[ -r "$TOOL_ENV" ]]; then
  # shellcheck disable=SC1090
  . "$TOOL_ENV"
else
  echo "[grep] ERROR: missing toolchain env '$TOOL_ENV' (run 'make preflight' first)" >&2
  exit 1
fi

: "${CLANG:?missing CLANG in $TOOL_ENV}"
: "${AR:?missing AR in $TOOL_ENV}"
: "${RANLIB:?missing RANLIB in $TOOL_ENV}"

# Sanity
if [[ ! -d "$GREP_ROOT" ]]; then
  echo "[grep] ERROR: grep source dir not found at: $GREP_ROOT" >&2
  exit 1
fi
if [[ ! -d "$MERGED_SYSROOT" ]]; then
  echo "[grep] ERROR: merged sysroot '$MERGED_SYSROOT' not found. Run 'make merge-sysroot' first." >&2
  exit 1
fi

mkdir -p "$STAGE_DIR"

# ----------------------------------------------------------------------
# 2) WASM toolchain flags
# ----------------------------------------------------------------------
CC_WASM="$CLANG --target=wasm32-unknown-wasi --sysroot=$MERGED_SYSROOT -pthread"

CFLAGS_WASM=(
  -O2 -g -std=gnu99 -pthread
  -I"$MERGED_SYSROOT/include"
  -I"$MERGED_SYSROOT/include/wasm32-wasi"
)

LDFLAGS_WASM=(
  "-Wl,--import-memory,--export-memory,--max-memory=67108864,--export=__stack_pointer,--export=__stack_low"
  -L"$MERGED_SYSROOT/lib/wasm32-wasi"
  -L"$MERGED_SYSROOT/usr/lib/wasm32-wasi"
)

echo "[grep] using CLANG       = $CLANG"
echo "[grep] using AR          = $AR"
echo "[grep] using RANLIB      = $RANLIB"
echo "[grep] LIND_WASM_ROOT    = $LIND_WASM_ROOT"
echo "[grep] merged sysroot    = $MERGED_SYSROOT"
echo "[grep] stage dir         = $STAGE_DIR"
echo "[grep] CC_WASM           = $CC_WASM"
echo

# ----------------------------------------------------------------------
# 3) Force static-only
# ----------------------------------------------------------------------
export enable_shared=no
export enable_static=yes
export lt_cv_prog_compiler_pic_works=no
export lt_cv_prog_compiler_static_works=yes

export CFLAGS="${CFLAGS:-} ${CFLAGS_WASM[*]}"
export CPPFLAGS="${CPPFLAGS:-} -I$MERGED_SYSROOT/include -I$MERGED_SYSROOT/include/wasm32-wasi"
export LDFLAGS="${LDFLAGS:-} ${LDFLAGS_WASM[*]}"

# ----------------------------------------------------------------------
# 4) Patch gnulib fpending.c — add __wasi__ fallback before #error
# ----------------------------------------------------------------------
patch_fpending() {
  local f="$GREP_ROOT/lib/fpending.c"
  [[ -f "$f" ]] || return 0
  if grep -q '__wasi__' "$f"; then
    echo "[grep] [patch] fpending.c already patched; skipping."
    return 0
  fi
  python3 - <<'PY' "$f"
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text(errors="ignore")

old = """#else
# error "Please port gnulib fpending.c to your platform!"
  return 1;
#endif"""

new = """#elif defined __wasi__
  /* WASI/Lind fallback: no stdio internals; return 0 (no pending bytes). */
  return 0;
#else
# error "Please port gnulib fpending.c to your platform!"
  return 1;
#endif"""

if old in s:
    p.write_text(s.replace(old, new))
    print(f"[grep] [patch] added __wasi__ fallback to {p}")
else:
    print(f"[grep] WARN: fpending.c patch pattern not found in {p}", file=sys.stderr)
PY
}

patch_fpending

# ----------------------------------------------------------------------
# 5) Prevent autotools regeneration (no aclocal/automake/autoconf needed)
#    Touch generated files in dependency order so make won't re-run them.
# ----------------------------------------------------------------------
(
  cd "$GREP_ROOT"
  # Autoconf/automake chain: configure.ac → aclocal.m4 → configure → Makefile.in
  touch aclocal.m4
  touch configure
  find . -name Makefile.in -exec touch {} +
  # Texinfo/man: *.texi → *.info, prevent makeinfo invocation
  find . -name '*.info' -exec touch {} +
  find doc -name '*.1' -o -name '*.in.1' 2>/dev/null | xargs -r touch
)

# ----------------------------------------------------------------------
# 6) Configure
# ----------------------------------------------------------------------
BUILD_TRIPLET="$("$GREP_ROOT/build-aux/config.guess" 2>/dev/null || echo x86_64-unknown-linux-gnu)"
HOST_TRIPLET="wasm32-unknown-linux-gnu"

echo "[grep] configuring…"
(
  cd "$GREP_ROOT"
  ./configure \
    --build="$BUILD_TRIPLET" \
    --host="$HOST_TRIPLET" \
    --disable-nls \
    CC="$CC_WASM" \
    AR="$AR" \
    RANLIB="$RANLIB" \
    CFLAGS="${CFLAGS_WASM[*]}" \
    CPPFLAGS="$CPPFLAGS" \
    LDFLAGS="${LDFLAGS_WASM[*]}"
)

if [[ ! -f "$GREP_ROOT/Makefile" ]]; then
  echo "[grep] ERROR: configure failed before producing Makefile." >&2
  exit 1
fi

# ----------------------------------------------------------------------
# 7) Build
# ----------------------------------------------------------------------
echo "[grep] building…"
make -C "$GREP_ROOT" -j"$JOBS" V=1

# ----------------------------------------------------------------------
# 8) Stage binary
# ----------------------------------------------------------------------
GREP_BIN="$GREP_ROOT/src/grep"
if [[ ! -f "$GREP_BIN" ]]; then
  echo "[grep] ERROR: expected binary '$GREP_BIN' not found after build." >&2
  exit 1
fi

cp "$GREP_BIN" "$STAGE_DIR/grep.wasm"
echo "[grep] staged grep.wasm → $STAGE_DIR/grep.wasm"

# ----------------------------------------------------------------------
# 9) wasm-opt (best-effort)
# ----------------------------------------------------------------------
if [[ -x "$WASM_OPT" ]]; then
  echo "[grep] running wasm-opt…"
  "$WASM_OPT" --epoch-injection --asyncify --debuginfo -O2 \
    "$STAGE_DIR/grep.wasm" -o "$STAGE_DIR/grep.opt.wasm" || true
else
  echo "[grep] NOTE: wasm-opt not found at '$WASM_OPT'; skipping optimization."
fi

# ----------------------------------------------------------------------
# 10) cwasm generation (best-effort) via lind-boot --precompile
# ----------------------------------------------------------------------
if [[ -x "$LIND_BOOT" ]]; then
  echo "[grep] generating cwasm via lind-boot --precompile…"
  OPT_WASM="$STAGE_DIR/grep.opt.wasm"
  if [[ -f "$OPT_WASM" ]]; then
    if "$LIND_BOOT" --precompile "$OPT_WASM"; then
      OPT_CWASM="${OPT_WASM%.wasm}.cwasm"
      CLEAN_CWASM="$STAGE_DIR/grep.cwasm"
      if [[ -f "$OPT_CWASM" ]]; then
        mv "$OPT_CWASM" "$CLEAN_CWASM"
      fi
    else
      echo "[grep] WARNING: lind-boot --precompile failed; skipping."
    fi
  else
    "$LIND_BOOT" --precompile "$STAGE_DIR/grep.wasm" || \
      echo "[grep] WARNING: lind-boot --precompile failed; skipping."
  fi
else
  echo "[grep] NOTE: lind-boot not found at '$LIND_BOOT'; skipping cwasm generation."
fi

echo
echo "[grep] build complete. Outputs under:"
echo "  $STAGE_DIR"
ls -lh "$STAGE_DIR" || true
