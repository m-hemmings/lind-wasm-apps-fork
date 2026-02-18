#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Bash WASM build helper for lind-wasm-apps
#
# High-level strategy:
#   1. Run a full native (host) bash build:
#        - make distclean
#        - ./configure (host, job control disabled)
#        - make -j (host gcc/cc)
#      This gives us:
#        - builtins/mkbuiltins (native tool)
#        - generated headers (builtext.h, etc.)
#
#   2. Patch builtins/Makefile:
#        - strip -ldl (libdl doesn't exist in wasm32-wasi)
#
#   3. Delete host-built *.o / *.a for the parts we rebuild as WASM,
#      but KEEP mkbuiltins and mkbuiltins.o as native tools.
#
#   4. Rebuild core bash objects and libs with the wasm32-wasi toolchain.
#
#   5. Provide small WASI stubs (termcap, locale, getgroups).
#
#   6. Link bash.wasm into build/bin/bash/wasm32-wasi/bash.wasm and
#      run wasm-opt compile (best-effort).
###############################################################################

# --- basic paths -------------------------------------------------------------

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BASH_ROOT="$APPS_ROOT/bash"

TOOL_ENV="$APPS_ROOT/build/.toolchain.env"

if [[ -r "$TOOL_ENV" ]]; then
  # shellcheck source=/dev/null
  . "$TOOL_ENV"
fi

if [[ -z "${CLANG:-}" ]]; then
  echo "[bash] ERROR: CLANG is not set. Run 'make preflight' from lind-wasm-apps root."
  exit 1
fi

# Default LIND_WASM_ROOT to parent directory (layout: lind-wasm/lind-wasm-apps)
if [[ -z "${LIND_WASM_ROOT:-}" ]]; then
  LIND_WASM_ROOT="$(cd "$APPS_ROOT/.." && pwd)"
fi

BASE_SYSROOT="${BASE_SYSROOT:-$LIND_WASM_ROOT/build/sysroot}"
MERGED_SYSROOT="${APPS_MERGED:-$APPS_ROOT/build/sysroot_merged}"

LLVM_BIN_DIR="$(dirname "$CLANG")"
AR="${AR:-"$LLVM_BIN_DIR/llvm-ar"}"
RANLIB="${RANLIB:-"$LLVM_BIN_DIR/llvm-ranlib"}"

WASM_OPT="${WASM_OPT:-$LIND_WASM_ROOT/tools/binaryen/bin/wasm-opt}"

JOBS="${JOBS:-$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN || echo 4)}"

# Output location
BASH_OUT_DIR="$APPS_ROOT/build/bin/bash/wasm32-wasi"
mkdir -p "$BASH_OUT_DIR"

# wasm_compat header is committed in the repo
WASM_COMPAT_H="$BASH_ROOT/wasm_compat.h"

# --- sanity checks -----------------------------------------------------------

if [[ ! -d "$MERGED_SYSROOT" ]]; then
  echo "[bash] ERROR: merged sysroot '$MERGED_SYSROOT' not found."
  echo "        Run 'make merge-sysroot' (or 'make all') in lind-wasm-apps first."
  exit 1
fi

if [[ ! -r "$BASE_SYSROOT/include/wasm32-wasi/stdio.h" ]]; then
  echo "[bash] ERROR: base sysroot headers missing at '$BASE_SYSROOT'."
  echo "        Did you run 'make sysroot' in lind-wasm?"
  exit 1
fi

if [[ ! -f "$WASM_COMPAT_H" ]]; then
  echo "[bash] ERROR: missing bash/wasm_compat.h (it should be committed in the repo)."
  exit 1
fi

# --- WASM toolchain flags ----------------------------------------------------

CC_WASM="$CLANG --target=wasm32-unknown-wasi --sysroot=$MERGED_SYSROOT -pthread"

CFLAGS_WASM="-O2 -g -std=gnu89 -pthread \
  -DHAVE_STRSIGNAL=1 -DHAVE_MKTIME=1 \
  -include $WASM_COMPAT_H \
  -I$MERGED_SYSROOT/include \
  -I$MERGED_SYSROOT/include/wasm32-wasi"

LDFLAGS_WASM="-Wl,--import-memory,--export-memory,\
--max-memory=67108864,--export=__stack_pointer,--export=__stack_low \
-L$MERGED_SYSROOT/lib/wasm32-wasi \
-L$MERGED_SYSROOT/usr/lib/wasm32-wasi"

echo "[bash] using CLANG       = $CLANG"
echo "[bash] using AR          = $AR"
echo "[bash] LIND_WASM_ROOT    = $LIND_WASM_ROOT"
echo "[bash] merged sysroot    = $MERGED_SYSROOT"
echo "[bash] output dir        = $BASH_OUT_DIR"
echo

pushd "$BASH_ROOT" >/dev/null

###############################################################################
# 1. Native (host) bash build for mkbuiltins + generated headers
###############################################################################

echo "[bash] [host] cleaning any previous host build..."
make distclean >/dev/null 2>&1 || true

echo "[bash] [host] configuring (native, job control disabled)..."
./configure \
  --without-bash-malloc \
  --disable-nls \
  --disable-profiling \
  --disable-job-control

###############################################################################
# 2. Patch builtins/Makefile for WASI (-ldl is not available in wasm32-wasi)
###############################################################################

if [[ -f builtins/Makefile ]]; then
  if grep -q -- '-ldl' builtins/Makefile 2>/dev/null; then
    echo "[bash] [patch] stripping -ldl from builtins/Makefile for WASI/native build"
    sed -i 's/-ldl//g' builtins/Makefile
  fi
fi

echo "[bash] [host] building full native bash (this may take a bit)..."
make -j"$JOBS"

if [[ ! -x builtins/mkbuiltins ]]; then
  echo "[bash] ERROR: host builtins/mkbuiltins was not produced."
  exit 1
fi

###############################################################################
# 3. Clean host-built objects/libs that we will rebuild as WASM
#    IMPORTANT: keep mkbuiltins and mkbuiltins.o as native tools.
###############################################################################

echo "[bash] [wasm] cleaning host-built core objects..."
rm -f \
  shell.o eval.o y.tab.o general.o make_cmd.o print_cmd.o \
  dispose_cmd.o execute_cmd.o variables.o copy_cmd.o error.o \
  expr.o flags.o nojobs.o subst.o hashcmd.o hashlib.o mailcheck.o \
  trap.o input.o unwind_prot.o pathexp.o sig.o test.o version.o \
  alias.o array.o arrayfunc.o assoc.o braces.o bracecomp.o \
  bashhist.o bashline.o siglist.o list.o stringlib.o locale.o \
  findcmd.o redir.o pcomplete.o pcomplib.o syntax.o xmalloc.o \
  signames.o

echo "[bash] [wasm] cleaning host-built library objects (preserving mkbuiltins.o)..."
# Remove all .o in builtins/ except mkbuiltins.o
find builtins -maxdepth 1 -type f -name '*.o' ! -name 'mkbuiltins.o' -delete || true
rm -f lib/glob/*.o lib/sh/*.o lib/readline/*.o lib/tilde/*.o || true

echo "[bash] [wasm] cleaning host-built archives..."
rm -f \
  builtins/libbuiltins.a \
  lib/glob/libglob.a \
  lib/sh/libsh.a \
  lib/readline/libreadline.a \
  lib/readline/libhistory.a \
  lib/tilde/libtilde.a

###############################################################################
# 4. WASM build: core objects
###############################################################################

echo "[bash] [wasm] building core objects with wasm32-wasi toolchain..."
make -j1 \
  V=1 \
  CC="$CC_WASM" \
  CFLAGS="$CFLAGS_WASM" \
  LDFLAGS="$LDFLAGS_WASM" \
  AR="$AR" \
  ARFLAGS="crs" \
  RANLIB="echo" \
  TERMCAP_LIB="" \
  shell.o eval.o y.tab.o general.o make_cmd.o print_cmd.o \
  dispose_cmd.o execute_cmd.o variables.o copy_cmd.o error.o \
  expr.o flags.o nojobs.o subst.o hashcmd.o hashlib.o mailcheck.o \
  trap.o input.o unwind_prot.o pathexp.o sig.o test.o version.o \
  alias.o array.o arrayfunc.o assoc.o braces.o bracecomp.o \
  bashhist.o bashline.o siglist.o list.o stringlib.o locale.o \
  findcmd.o redir.o pcomplete.o pcomplib.o syntax.o xmalloc.o

###############################################################################
# 5. WASM build: libraries in subdirectories
###############################################################################

echo "[bash] [wasm] building builtins/libbuiltins.a..."
make -j1 -C builtins \
  V=1 \
  CC="$CC_WASM" \
  CFLAGS="$CFLAGS_WASM" \
  AR="$AR" ARFLAGS="crs" RANLIB="echo" \
  libbuiltins.a

echo "[bash] [wasm] building lib/glob/libglob.a..."
make -j1 -C lib/glob \
  V=1 \
  CC="$CC_WASM" \
  CFLAGS="$CFLAGS_WASM" \
  AR="$AR" ARFLAGS="crs" RANLIB="echo" \
  libglob.a

echo "[bash] [wasm] building lib/sh/libsh.a..."
make -j1 -C lib/sh \
  V=1 \
  CC="$CC_WASM" \
  CFLAGS="$CFLAGS_WASM" \
  AR="$AR" ARFLAGS="crs" RANLIB="echo" \
  libsh.a

echo "[bash] [wasm] building lib/readline/libreadline.a + libhistory.a..."
make -j1 -C lib/readline \
  V=1 \
  CC="$CC_WASM" \
  CFLAGS="$CFLAGS_WASM" \
  AR="$AR" ARFLAGS="crs" RANLIB="echo" \
  libreadline.a libhistory.a

# Avoid duplicate xmalloc/xrealloc by dropping readline's xmalloc.o from both
# libreadline.a and libhistory.a. bash's own xmalloc.o is built and linked directly instead
for archive in libreadline.a libhistory.a; do
  if [[ -f "./lib/readline/$archive" ]]; then
    echo "[bash] [wasm] stripping xmalloc.o from ./lib/readline/$archive to avoid duplicate xmalloc/xrealloc (TODO: cleaner config option)."
    "$AR" d "./lib/readline/$archive" xmalloc.o || true
  fi
done

echo "[bash] [wasm] building lib/tilde/libtilde.a..."
make -j1 -C lib/tilde \
  V=1 \
  CC="$CC_WASM" \
  CFLAGS="$CFLAGS_WASM" \
  AR="$AR" ARFLAGS="crs" RANLIB="echo" \
  libtilde.a

###############################################################################
# 6. Termcap + locale + getgroups stubs (WASI compatibility)
###############################################################################

TPUTS_STUB_C="$BASH_ROOT/tputs_stub.c"
TPUTS_STUB_O="$BASH_ROOT/tputs_stub.o"

cat > "$TPUTS_STUB_C" << 'EOF'
/* Minimal termcap stubs for readline on WASI. */

int tputs(const char *str, int affcnt, int (*putc_fn)(int))
{
    (void)affcnt;
    if (!str || !putc_fn)
        return 0;
    const unsigned char *p = (const unsigned char *)str;
    while (*p)
        putc_fn(*p++);
    return 0;
}

char *tgoto(const char *cm, int destcol, int destline)
{
    (void)cm;
    (void)destcol;
    (void)destline;
    static char buf[1];
    buf[0] = '\0';
    return buf;
}

int tgetnum(const char *id)
{
    (void)id;
    return -1;
}

int tgetent(char *bp, const char *name)
{
    (void)bp;
    (void)name;
    return 0;
}

char *tgetstr(const char *id, char **area)
{
    (void)id;
    (void)area;
    return (char *)0;
}

int tgetflag(const char *id)
{
    (void)id;
    return 0;
}
EOF

echo "[bash] [wasm] compiling termcap stubs..."
$CC_WASM $CFLAGS_WASM -c "$TPUTS_STUB_C" -o "$TPUTS_STUB_O"

LOCALE_STUB_C="$BASH_ROOT/locale_stub.c"
LOCALE_STUB_O="$BASH_ROOT/locale_stub.o"

cat > "$LOCALE_STUB_C" << 'EOF'
/* Minimal locale stub for WASM. Avoids heavy locale logic. */

#include <stddef.h>

size_t __ctype_get_mb_cur_max(void)
{
    /* Treat all locales as single-byte for now. */
    return 1;
}
EOF

echo "[bash] [wasm] compiling locale stubs..."
$CC_WASM $CFLAGS_WASM -c "$LOCALE_STUB_C" -o "$LOCALE_STUB_O"

GROUPS_STUB_C="$BASH_ROOT/getgroups_stub.c"
GROUPS_STUB_O="$BASH_ROOT/getgroups_stub.o"

cat > "$GROUPS_STUB_C" << 'EOF'
/* Minimal getgroups(2) stub for WASI.
 *
 * Upstream configure detects getgroups() on the native host, but the WASI
 * sysroot does not provide it. For now, we provide a stub that reports
 * no supplementary groups. TODO: replace with a proper WASI-aware check
 * in configure or a dedicated compatibility layer.
 */

#include <sys/types.h>

int getgroups(int size, gid_t list[])
{
    (void)size;
    (void)list;
    return 0;
}
EOF

echo "[bash] [wasm] compiling getgroups stub..."
$CC_WASM $CFLAGS_WASM -c "$GROUPS_STUB_C" -o "$GROUPS_STUB_O"

###############################################################################
# 7. Link bash.wasm
###############################################################################

BASH_WASM="$BASH_OUT_DIR/bash.wasm"

echo "[bash] [wasm] linking bash → $BASH_WASM ..."
$CC_WASM \
  -L./builtins \
  -L./lib/readline \
  -L./lib/glob \
  -L./lib/tilde \
  -L./lib/sh \
  $LDFLAGS_WASM \
  -o "$BASH_WASM" \
  "$LOCALE_STUB_O" \
  "$GROUPS_STUB_O" \
  shell.o eval.o y.tab.o general.o make_cmd.o print_cmd.o \
  dispose_cmd.o execute_cmd.o variables.o copy_cmd.o error.o \
  expr.o flags.o nojobs.o subst.o hashcmd.o hashlib.o mailcheck.o \
  trap.o input.o unwind_prot.o pathexp.o sig.o test.o version.o \
  alias.o array.o arrayfunc.o assoc.o braces.o bracecomp.o \
  bashhist.o bashline.o siglist.o list.o stringlib.o locale.o \
  findcmd.o redir.o pcomplete.o pcomplib.o syntax.o xmalloc.o \
  "$TPUTS_STUB_O" \
  -lbuiltins -lglob -lsh -lreadline -lhistory -ltilde

if [[ ! -f "$BASH_WASM" ]]; then
  echo "[bash] ERROR: bash.wasm was not produced."
  exit 1
fi

###############################################################################
# 8. wasm-opt compile (best-effort)
###############################################################################

if [[ -x "$WASM_OPT" ]]; then
  echo "[bash] running wasm-opt (best-effort)..."
  OPT_WASM="$BASH_OUT_DIR/bash.opt.wasm"
  "$WASM_OPT" --epoch-injection --asyncify --debuginfo -O2 \
    "$BASH_WASM" -o "$OPT_WASM"
  BASH_WASM="$OPT_WASM"
else
  echo "[bash] NOTE: wasm-opt not found; skipping optimization step."
fi

popd >/dev/null

echo
echo "[bash] build complete. Outputs under:"
echo "  $BASH_OUT_DIR"
ls -lh "$BASH_OUT_DIR" || true

