#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# sed WASI build helper for lind-wasm-apps
#
# Cross-compiles GNU sed 4.9 to wasm32-wasi using the merged sysroot and
# toolchain detected by the top-level Makefile preflight target.
###############################################################################

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SED_ROOT="$APPS_ROOT/sed"

APPS_BUILD="$APPS_ROOT/build"
MERGED_SYSROOT="$APPS_BUILD/sysroot_merged"
STAGE_DIR="$APPS_BUILD/bin/sed/wasm32-wasi"
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
  echo "[sed] ERROR: missing toolchain env '$TOOL_ENV' (run 'make preflight' first)" >&2
  exit 1
fi

: "${CLANG:?missing CLANG in $TOOL_ENV}"
: "${AR:?missing AR in $TOOL_ENV}"
: "${RANLIB:?missing RANLIB in $TOOL_ENV}"

# Sanity
if [[ ! -d "$SED_ROOT" ]]; then
  echo "[sed] ERROR: sed source dir not found at: $SED_ROOT" >&2
  exit 1
fi
if [[ ! -d "$MERGED_SYSROOT" ]]; then
  echo "[sed] ERROR: merged sysroot '$MERGED_SYSROOT' not found. Run 'make merge-sysroot' first." >&2
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

echo "[sed] using CLANG       = $CLANG"
echo "[sed] using AR          = $AR"
echo "[sed] using RANLIB      = $RANLIB"
echo "[sed] LIND_WASM_ROOT    = $LIND_WASM_ROOT"
echo "[sed] merged sysroot    = $MERGED_SYSROOT"
echo "[sed] stage dir         = $STAGE_DIR"
echo "[sed] CC_WASM           = $CC_WASM"
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
# 4) Patch gnulib fpending.c and fwriting.c — add __wasi__ fallbacks
# ----------------------------------------------------------------------
patch_fpending() {
  local f="$SED_ROOT/lib/fpending.c"
  [[ -f "$f" ]] || return 0
  if grep -q '__wasi__' "$f"; then
    echo "[sed] [patch] fpending.c already patched; skipping."
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
    print(f"[sed] [patch] added __wasi__ fallback to {p}")
else:
    print(f"[sed] WARN: fpending.c patch pattern not found in {p}", file=sys.stderr)
PY
}

patch_fwriting() {
  local f="$SED_ROOT/lib/fwriting.c"
  [[ -f "$f" ]] || return 0
  if grep -q '__wasi__' "$f"; then
    echo "[sed] [patch] fwriting.c already patched; skipping."
    return 0
  fi
  python3 - <<'PY' "$f"
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text(errors="ignore")

old = """#else
# error "Please port gnulib fwriting.c to your platform!"
#endif"""

new = """#elif defined __wasi__
  /* WASI/Lind fallback: conservatively assume writing. */
  return 1;
#else
# error "Please port gnulib fwriting.c to your platform!"
#endif"""

if old in s:
    p.write_text(s.replace(old, new))
    print(f"[sed] [patch] added __wasi__ fallback to {p}")
else:
    print(f"[sed] WARN: fwriting.c patch pattern not found in {p}", file=sys.stderr)
PY
}

patch_fpending
patch_fwriting

# ----------------------------------------------------------------------
# 5) Prevent autotools regeneration (no aclocal/automake/autoconf needed)
#    Touch generated files in dependency order so make won't re-run them.
# ----------------------------------------------------------------------
(
  cd "$SED_ROOT"
  # Autoconf/automake chain: configure.ac → aclocal.m4 → configure → Makefile.in
  touch aclocal.m4
  touch configure
  find . -name Makefile.in -exec touch {} +
  # Texinfo/man: *.texi → *.info, prevent makeinfo invocation
  find . -name '*.info' -exec touch {} +
  find doc -name '*.1' 2>/dev/null | xargs -r touch
)

# ----------------------------------------------------------------------
# 6) Configure
# ----------------------------------------------------------------------
BUILD_TRIPLET="$("$SED_ROOT/build-aux/config.guess" 2>/dev/null || echo x86_64-unknown-linux-gnu)"
HOST_TRIPLET="wasm32-unknown-linux-gnu"

echo "[sed] configuring…"
(
  cd "$SED_ROOT"
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

if [[ ! -f "$SED_ROOT/Makefile" ]]; then
  echo "[sed] ERROR: configure failed before producing Makefile." >&2
  exit 1
fi

# ----------------------------------------------------------------------
# 7) Build
# ----------------------------------------------------------------------
echo "[sed] building…"
make -C "$SED_ROOT" -j"$JOBS" V=1

# ----------------------------------------------------------------------
# 8) Stage binary
# ----------------------------------------------------------------------
SED_BIN="$SED_ROOT/sed/sed"
if [[ ! -f "$SED_BIN" ]]; then
  echo "[sed] ERROR: expected binary '$SED_BIN' not found after build." >&2
  exit 1
fi

cp "$SED_BIN" "$STAGE_DIR/sed.wasm"
echo "[sed] staged sed.wasm → $STAGE_DIR/sed.wasm"

# ----------------------------------------------------------------------
# 9) wasm-opt (best-effort)
# ----------------------------------------------------------------------
if [[ -x "$WASM_OPT" ]]; then
  echo "[sed] running wasm-opt…"
  "$WASM_OPT" --epoch-injection --asyncify --debuginfo -O2 \
    "$STAGE_DIR/sed.wasm" -o "$STAGE_DIR/sed.opt.wasm" || true
else
  echo "[sed] NOTE: wasm-opt not found at '$WASM_OPT'; skipping optimization."
fi

# ----------------------------------------------------------------------
# 10) cwasm generation (best-effort) via lind-boot --precompile
# ----------------------------------------------------------------------
if [[ -x "$LIND_BOOT" ]]; then
  echo "[sed] generating cwasm via lind-boot --precompile…"
  OPT_WASM="$STAGE_DIR/sed.opt.wasm"
  if [[ -f "$OPT_WASM" ]]; then
    if "$LIND_BOOT" --precompile "$OPT_WASM"; then
      OPT_CWASM="${OPT_WASM%.wasm}.cwasm"
      CLEAN_CWASM="$STAGE_DIR/sed.cwasm"
      if [[ -f "$OPT_CWASM" ]]; then
        mv "$OPT_CWASM" "$CLEAN_CWASM"
      fi
    else
      echo "[sed] WARNING: lind-boot --precompile failed; skipping."
    fi
  else
    "$LIND_BOOT" --precompile "$STAGE_DIR/sed.wasm" || \
      echo "[sed] WARNING: lind-boot --precompile failed; skipping."
  fi
else
  echo "[sed] NOTE: lind-boot not found at '$LIND_BOOT'; skipping cwasm generation."
fi

echo
echo "[sed] build complete. Outputs under:"
echo "  $STAGE_DIR"
ls -lh "$STAGE_DIR" || true
