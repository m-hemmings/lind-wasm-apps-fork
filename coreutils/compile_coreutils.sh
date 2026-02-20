#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# coreutils WASI build helper for lind-wasm-apps (best-effort / partial OK)
#
# Goals:
#   - Use merged sysroot (build/sysroot_merged)
#   - Force static-only (avoid wasm-ld: --export-memory incompatible with --shared)
#   - Avoid configure running conftest binaries (cross compile)
#   - Disable mountlist fatal (no mtab/mount table on WASI)
#   - Patch a few gnulib portability #error sites to WASI-safe fallbacks
#   - Stage produced wasm binaries even if some targets fail to link
#   - wasm-opt compile (best-effort) on staged binaries
###############################################################################

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COREUTILS_ROOT="$APPS_ROOT/coreutils"

APPS_BUILD="$APPS_ROOT/build"
MERGED_SYSROOT="$APPS_BUILD/sysroot_merged"
BUILD_ROOT="$APPS_BUILD/coreutils_wasi"
BUILD_DIR="$BUILD_ROOT/build"
STAGE_DIR="$APPS_BUILD/bin/coreutils/wasm32-wasi"
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
  echo "[coreutils] ERROR: missing toolchain env '$TOOL_ENV' (run 'make preflight' first)" >&2
  exit 1
fi

: "${CLANG:?missing CLANG in $TOOL_ENV}"
: "${AR:?missing AR in $TOOL_ENV}"
: "${RANLIB:?missing RANLIB in $TOOL_ENV}"

# Sanity
if [[ ! -d "$COREUTILS_ROOT" ]]; then
  echo "[coreutils] ERROR: coreutils source dir not found at: $COREUTILS_ROOT" >&2
  exit 1
fi
if [[ ! -d "$MERGED_SYSROOT" ]]; then
  echo "[coreutils] ERROR: merged sysroot '$MERGED_SYSROOT' not found. Run 'make merge-sysroot' first." >&2
  exit 1
fi

mkdir -p "$BUILD_DIR" "$STAGE_DIR"

# Optional compat header (like bash’s wasm_compat.h). If you add one later,
# the script will automatically include it.
WASM_COMPAT_H="$COREUTILS_ROOT/wasm_compat.h"
WASM_COMPAT_INC=()
if [[ -f "$WASM_COMPAT_H" ]]; then
  WASM_COMPAT_INC=(-include "$WASM_COMPAT_H")
else
  echo "[coreutils] NOTE: $WASM_COMPAT_H missing; continuing without -include."
fi

# ----------------------------------------------------------------------
# 2) WASM toolchain flags (match bash style)
#    NOTE: configure wants C99+ for some probes; use gnu99 here.
# ----------------------------------------------------------------------
CC_WASM="$CLANG --target=wasm32-unknown-wasi --sysroot=$MERGED_SYSROOT -pthread"

CFLAGS_WASM=(
  -O2 -g -std=gnu99 -pthread
  -DHAVE_STRSIGNAL=1 -DHAVE_MKTIME=1 # needed to bypass some configure checks
  -DSLOW_BUT_NO_HACKS=1
  "${WASM_COMPAT_INC[@]}"
  -I"$MERGED_SYSROOT/include"
  -I"$MERGED_SYSROOT/include/wasm32-wasi"
)

LDFLAGS_WASM=(
  "-Wl,--import-memory,--export-memory,--max-memory=67108864,--export=__stack_pointer,--export=__stack_low"
  -L"$MERGED_SYSROOT/lib/wasm32-wasi"
  -L"$MERGED_SYSROOT/usr/lib/wasm32-wasi"
)

echo "[coreutils] using CLANG       = $CLANG"
echo "[coreutils] using AR          = $AR"
echo "[coreutils] using RANLIB      = $RANLIB"
echo "[coreutils] LIND_WASM_ROOT    = $LIND_WASM_ROOT"
echo "[coreutils] merged sysroot    = $MERGED_SYSROOT"
echo "[coreutils] build dir         = $BUILD_DIR"
echo "[coreutils] stage dir         = $STAGE_DIR"
echo "[coreutils] CC_WASM           = $CC_WASM"
echo

# ----------------------------------------------------------------------
# 3) Force static-only (prevent wasm-ld seeing --shared)
# ----------------------------------------------------------------------
export enable_shared=no
export enable_static=yes
export lt_cv_prog_compiler_pic_works=no
export lt_cv_prog_compiler_static_works=yes
export ac_cv_prog_cc_pic_works=no

# Keep shared out even if something injects defaults
export CFLAGS="${CFLAGS:-} ${CFLAGS_WASM[*]}"
export CPPFLAGS="${CPPFLAGS:-} -I$MERGED_SYSROOT/include -I$MERGED_SYSROOT/include/wasm32-wasi"
export LDFLAGS="${LDFLAGS:-} ${LDFLAGS_WASM[*]}"

# ----------------------------------------------------------------------
# 4) config.site: force cross-compile behavior and disable mountlist
# ----------------------------------------------------------------------
CONFIG_SITE_FILE="$BUILD_ROOT/config.site"
mkdir -p "$BUILD_ROOT"

cat >"$CONFIG_SITE_FILE" <<EOF
# coreutils on WASI: do not attempt to run test executables
cross_compiling=yes

# ---- coreutils/gnulib mountlist: disable entirely ----
fu_cv_mounted_fs_supported=no
gl_cv_list_mounted_fs=no
fu_cv_sys_mounted_fread=no
fu_cv_sys_mounted_getmntent=no
fu_cv_sys_mounted_getmntinfo=no
fu_cv_sys_mounted_getfsstat=no
fu_cv_sys_mounted_mnttab=no
fu_cv_sys_mounted_vfstab=no
fu_cv_sys_mounted_vmount=no

# Some configure scripts look for listmntent(3)
ac_cv_func_listmntent=no

# ---- WASI: force gnulib replacements for *at() functions ----
# WASI headers declare these but don't implement them. Without this,
# configure takes the "no replacement needed" branch in openat.m4
# (yes+yes case) and the rpl_* objects never get compiled, causing
# undefined symbol errors at link time.
ac_cv_func_openat=no
ac_cv_func_fstatat=no
ac_cv_func_unlinkat=no
ac_cv_func_fchmodat=no
ac_cv_func_mkdirat=no
ac_cv_func_fchownat=no
ac_cv_func_linkat=no
ac_cv_func_symlinkat=no
ac_cv_func_readlinkat=no

# ---- WASI: no inotify support ----
# Prevents tail from trying to use inotify_add_watch/inotify_rm_watch.
ac_cv_func_inotify_init=no

# ---- WASI: no libcrypt ----
# Prevents su from trying to link against crypt().
ac_cv_search_crypt=no
EOF

export CONFIG_SITE="$CONFIG_SITE_FILE"

# ----------------------------------------------------------------------
# 5) Patches (all done without perl quoting hell; use python)
# ----------------------------------------------------------------------
patch_mountlist_fatal() {
  local in="$COREUTILS_ROOT/configure"
  local out="$BUILD_ROOT/configure.patched"

  cp "$in" "$out"

  python3 - <<'PY' "$out"
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text(errors="ignore")

needle = r'as_fn_error\s+\$\?\s+"could not determine how to read list of mounted file systems"\s+"\$LINENO"\s+5'
repl = r'''{ echo "configure: WARNING: disabling mountlist on WASI (no mount table support)" >&2; }
fu_cv_mounted_fs_supported=no
gl_cv_list_mounted_fs=no
fu_cv_sys_mounted_fread=no
fu_cv_sys_mounted_getmntent=no
fu_cv_sys_mounted_getmntinfo=no
fu_cv_sys_mounted_getfsstat=no
fu_cv_sys_mounted_mnttab=no
fu_cv_sys_mounted_vfstab=no
fu_cv_sys_mounted_vmount=no
'''

new_s, n = re.subn(needle, repl, s)
if n:
  p.write_text(new_s)
else:
  print(f"[coreutils] WARN: mountlist fatal pattern not found in {p}", file=sys.stderr)
PY

  chmod +x "$out"
  echo "[coreutils] [patch] disable mountlist AC_MSG_ERROR: $out"
}

patch_gnulib_slow_but_no_hacks() {
  # freadahead/freadptr/freadseek: if SLOW_BUT_NO_HACKS is defined, do a safe fallback
  # (don’t abort(), don’t #error)
  for f in "$COREUTILS_ROOT/lib/freadahead.c" "$COREUTILS_ROOT/lib/freadptr.c" "$COREUTILS_ROOT/lib/freadseek.c"; do
    [[ -f "$f" ]] || continue
    python3 - <<'PY' "$f"
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text(errors="ignore")

# Replace the SLOW_BUT_NO_HACKS branch body (commonly "abort(); return 0;")
# with a WASI-safe return.
s2 = re.sub(
  r'(#elif\s+defined\s+SLOW_BUT_NO_HACKS\s*/\*[^*]*\*/\s*\n)(.*?\n)(#else\s*\n\s*#error\s+"Please port gnulib .*?\n\s*#endif)',
  lambda m: m.group(1) + "  /* WASI fallback: no stdio internals; behave conservatively. */\n  return 0;\n" + m.group(3),
  s,
  flags=re.S
)

# Some variants have SLOW_BUT_NO_HACKS without /* comment */
s2 = re.sub(
  r'(#elif\s+defined\s+SLOW_BUT_NO_HACKS\s*\n)(.*?\n)(#else\s*\n\s*#error\s+"Please port gnulib .*?\n\s*#endif)',
  lambda m: m.group(1) + "  /* WASI fallback: no stdio internals; behave conservatively. */\n  return 0;\n" + m.group(3),
  s2,
  flags=re.S
)

if s2 != s:
  p.write_text(s2)
PY
    echo "[coreutils] [patch] make SLOW_BUT_NO_HACKS a safe fallback: $f"
  done

  # fseterr.c: avoid hard fail on unknown stdio internals; no-op on WASI
  local fseterr="$COREUTILS_ROOT/lib/fseterr.c"
  if [[ -f "$fseterr" ]]; then
    python3 - <<'PY' "$fseterr"
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text(errors="ignore")

# Insert a __wasi__ branch right before the final #else #error.
pat = r'(#elif\s+defined\s+__MINT__[^#]*\n\s*fp->__error\s*=\s*1;\s*\n)(#elif\s+0\s*/\*\s*unknown\s*\*/|#else\s*\n\s*#error)'
m = re.search(pat, s, flags=re.S)
if m and "#elif defined __wasi__" not in s:
  insert = m.group(1) + "#elif defined __wasi__\n  (void)fp; /* WASI: no FILE internals; best-effort no-op. */\n"
  s = s[:m.start(1)] + insert + s[m.end(1):]
  p.write_text(s)
PY
    echo "[coreutils] [patch] avoid hard fail in fseterr portability hack: $fseterr"
  fi

  # fseeko.c: replace final portability #error with simple fallback
  local fseeko="$COREUTILS_ROOT/lib/fseeko.c"
  if [[ -f "$fseeko" ]]; then
    python3 - <<'PY' "$fseeko"
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text(errors="ignore")

pat = r'#else\s*\n\s*#error\s+"Please port gnulib fseeko\.c[^"]*"\s*\n\s*#endif'
repl = (
  "#else\n"
  "  /* WASI fallback: no stdio internals; just call the underlying fseeko/fseek. */\n"
  "  return fseeko (fp, offset, whence);\n"
  "#endif"
)
s2, n = re.subn(pat, repl, s, flags=re.M)
if n:
  p.write_text(s2)
PY
    echo "[coreutils] [patch] avoid hard fail in fseeko portability hack: $fseeko"
  fi

  # unlinkat.c: ensure stdlib.h is included (malloc/free prototypes)
  local unlinkat="$COREUTILS_ROOT/lib/unlinkat.c"
  if [[ -f "$unlinkat" ]]; then
    python3 - <<'PY' "$unlinkat"
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text(errors="ignore")
if "<stdlib.h>" not in s:
  # Put it near other system includes.
  s2 = re.sub(r'(#include\s+<unistd\.h>\s*\n)', r'\1#include <stdlib.h>\n', s, count=1)
  if s2 == s:
    s2 = re.sub(r'(#include\s+<config\.h>\s*\n)', r'\1#include <stdlib.h>\n', s, count=1)
  p.write_text(s2)
PY
    echo "[coreutils] [patch] add <stdlib.h> for malloc/free: $unlinkat"
  fi

  # sigaction.c: gnulib version is Win32-tailored; replace with WASI stub.
  local sigaction_c="$COREUTILS_ROOT/lib/sigaction.c"
  if [[ -f "$sigaction_c" ]]; then
    cat >"$sigaction_c" <<'EOF'
/* WASI stub for gnulib sigaction module.
 *
 * coreutils pulls this in via gnulib on some platforms. On WASI/Lind, signals
 * are not fully supported in a POSIX way; provide a minimal stub so we can
 * build userland tools.
 */
#include <config.h>
#include <signal.h>
#include <errno.h>

int sigaction (int sig, const struct sigaction *restrict act,
               struct sigaction *restrict oact)
{
  (void)sig;
  (void)act;
  (void)oact;
  errno = ENOTSUP;
  return -1;
}
EOF
    echo "[coreutils] [patch] replace gnulib sigaction() with WASI stub: $sigaction_c"
  fi
}

patch_generated_signal_h_after_configure() {
  # After configure, gnulib may generate build/lib/signal.h that defines
  # `struct sigaction` even though WASI headers already define it.
  local gen="$BUILD_DIR/lib/signal.h"
  [[ -f "$gen" ]] || return 0

  python3 - <<'PY' "$gen"
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text(errors="ignore")

# Wrap the "struct sigaction { ... };" block in #ifndef __wasi__
# (only the first one we hit).
m = re.search(r'\nstruct sigaction\s*\{.*?\n\};\n', s, flags=re.S)
if not m:
  sys.exit(0)

block = m.group(0)
wrapped = "\n#ifndef __wasi__\n" + block + "#endif\n"
s2 = s[:m.start()] + wrapped + s[m.end():]
p.write_text(s2)
PY

  echo "[coreutils] [patch] avoid struct sigaction redefinition: $gen"
}

# ----------------------------------------------------------------------
# 6) Configure + build (best-effort)
# ----------------------------------------------------------------------
patch_mountlist_fatal
patch_gnulib_slow_but_no_hacks

HOST_TRIPLET="${HOST_TRIPLET:-wasm32-unknown-linux-gnu}"
BUILD_TRIPLET="${BUILD_TRIPLET:-$(./config.guess 2>/dev/null || echo x86_64-unknown-linux-gnu)}"
# IMPORTANT: --build != --host so configure knows it's cross and won't run conftest.

echo "[coreutils] configuring (best-effort; may still warn)"
(
  cd "$BUILD_DIR"

  # Make sure we start clean-ish if the user reruns.
  rm -f config.cache || true

  # Run patched configure out-of-tree with explicit srcdir
  "$BUILD_ROOT/configure.patched" \
    --srcdir="$COREUTILS_ROOT" \
    --build="$BUILD_TRIPLET" \
    --host="$HOST_TRIPLET" \
    --disable-shared \
    --enable-static \
    --disable-libtool-lock \
    --without-selinux \
    --without-libcap \
    CC="$CC_WASM" \
    AR="$AR" \
    RANLIB="$RANLIB" \
    CFLAGS="${CFLAGS_WASM[*]}" \
    CPPFLAGS="$CPPFLAGS" \
    LDFLAGS="${LDFLAGS_WASM[*]}" \
    || echo "[coreutils] WARNING: configure exited nonzero ($?)."
)

# If configure produced a generated signal.h, patch it now.
patch_generated_signal_h_after_configure

if [[ ! -f "$BUILD_DIR/Makefile" ]]; then
  echo "[coreutils] ERROR: configure failed before producing Makefile." >&2
  if [[ -f "$BUILD_DIR/config.log" ]]; then
    echo "[coreutils] --- first 'Exec format error' or 'error:' from config.log ---" >&2
    grep -n -m1 -E 'Exec format error|configure: error:|: error:|cannot execute binary file' "$BUILD_DIR/config.log" >&2 || true
  fi
  exit 1
fi

echo "[coreutils] building (best-effort; partial failures allowed)"
(
  cd "$BUILD_DIR"
  # coreutils link failures (crypt/fmod/etc.) are expected for some targets; don't stop the world.
  set +e
  make -j"$JOBS" V=1 \
    CC="$CC_WASM" \
    AR="$AR" \
    RANLIB="$RANLIB" \
    CFLAGS="${CFLAGS_WASM[*]}" \
    CPPFLAGS="$CPPFLAGS" \
    LDFLAGS="${LDFLAGS_WASM[*]}" \
    all
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    echo "[coreutils] NOTE: make returned $rc (expected for some tools); staging whatever built."
  fi
)

# ----------------------------------------------------------------------
# 7) Stage produced wasm binaries (even if named without .wasm)
#    coreutils builds in build/src/; binaries are plain names like "ls".
# ----------------------------------------------------------------------
echo "[coreutils] staging wasm binaries…"

SRC_BIN_DIR="$BUILD_DIR/src"
if [[ ! -d "$SRC_BIN_DIR" ]]; then
  echo "[coreutils] ERROR: expected build output dir '$SRC_BIN_DIR' not found" >&2
  exit 1
fi

python3 - <<'PY' "$SRC_BIN_DIR" "$STAGE_DIR"
import os, sys

src = sys.argv[1]
dst = sys.argv[2]
os.makedirs(dst, exist_ok=True)

def is_wasm(path: str) -> bool:
  try:
    with open(path, "rb") as f:
      return f.read(4) == b"\0asm"
  except Exception:
    return False

count = 0
for name in sorted(os.listdir(src)):
  p = os.path.join(src, name)
  if not os.path.isfile(p):
    continue
  # Skip obvious non-binaries
  if name.endswith((".o", ".a", ".la", ".lo", ".Plo")):
    continue
  if is_wasm(p):
    out = os.path.join(dst, name + ".wasm")
    with open(p, "rb") as fi, open(out, "wb") as fo:
      fo.write(fi.read())
    count += 1

print(f"[coreutils] staged {count} wasm binaries into {dst}")
PY

# ----------------------------------------------------------------------
# 8) wasm-opt (best-effort) for each staged .wasm
# ----------------------------------------------------------------------
shopt -s nullglob
wasm_files=("$STAGE_DIR"/*.wasm)
shopt -u nullglob

if (( ${#wasm_files[@]} == 0 )); then
  echo "[coreutils] WARNING: no staged .wasm files found in $STAGE_DIR"
  exit 0
fi

if [[ -x "$WASM_OPT" ]]; then
  echo "[coreutils] running wasm-opt (best-effort) on staged binaries…"
  for w in "${wasm_files[@]}"; do
    out="${w%.wasm}.opt.wasm"
    "$WASM_OPT" --epoch-injection --asyncify --debuginfo -O2 "$w" -o "$out" || true
  done
else
  echo "[coreutils] NOTE: wasm-opt not found at '$WASM_OPT'; skipping optimization."
fi

# ----------------------------------------------------------------------
# 9) cwasm generation (best-effort) via lind-boot --precompile
# ----------------------------------------------------------------------
if [[ -x "$LIND_BOOT" ]]; then
  echo "[coreutils] generating cwasm via lind-boot --precompile..."
  shopt -s nullglob
  opt_files=("$STAGE_DIR"/*.opt.wasm)
  shopt -u nullglob
  if (( ${#opt_files[@]} > 0 )); then
    for w in "${opt_files[@]}"; do
      if "$LIND_BOOT" --precompile "$w"; then
        # Rename foo.opt.cwasm → foo.cwasm (drop .opt)
        OPT_CWASM="${w%.wasm}.cwasm"
        CLEAN_CWASM="${OPT_CWASM/.opt/}"
        if [[ "$OPT_CWASM" != "$CLEAN_CWASM" && -f "$OPT_CWASM" ]]; then
          mv "$OPT_CWASM" "$CLEAN_CWASM"
        fi
      else
        echo "[coreutils] WARNING: lind-boot --precompile failed for '$(basename "$w")'; skipping."
      fi
    done
  else
    # fall back to raw .wasm if no opt files were produced
    for w in "${wasm_files[@]}"; do
      "$LIND_BOOT" --precompile "$w" || \
        echo "[coreutils] WARNING: lind-boot --precompile failed for '$(basename "$w")'; skipping."
    done
  fi
else
  echo "[coreutils] NOTE: lind-boot not found at '$LIND_BOOT'; skipping cwasm generation."
fi

echo
echo "[coreutils] build complete. Outputs under:"
echo "  $STAGE_DIR"
ls -lh "$STAGE_DIR" || true

