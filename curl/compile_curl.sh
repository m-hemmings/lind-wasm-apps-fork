#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# curl WASI build helper for lind-wasm-apps
#
# Cross-compiles curl for wasm32-wasi with OpenSSL and zlib (both already
# present in the merged sysroot).  Only HTTP/HTTPS protocols are enabled;
# everything else is disabled to minimise surface area and link complexity.
#
# Prerequisites:
#   - Run 'make preflight' and 'make merge-sysroot' first
#   - autoreconf (autoconf/automake/libtool) must be installed on the host
###############################################################################

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CURL_ROOT="$APPS_ROOT/curl"

APPS_BUILD="$APPS_ROOT/build"
MERGED_SYSROOT="$APPS_BUILD/sysroot_merged"
STAGE_DIR="$APPS_BUILD/bin/curl/wasm32-wasi"
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
  echo "[curl] ERROR: missing toolchain env '$TOOL_ENV' (run 'make preflight' first)" >&2
  exit 1
fi

: "${CLANG:?missing CLANG in $TOOL_ENV}"
: "${AR:?missing AR in $TOOL_ENV}"
: "${RANLIB:?missing RANLIB in $TOOL_ENV}"

# Sanity
if [[ ! -d "$CURL_ROOT" ]]; then
  echo "[curl] ERROR: curl source dir not found at: $CURL_ROOT" >&2
  exit 1
fi
if [[ ! -d "$MERGED_SYSROOT" ]]; then
  echo "[curl] ERROR: merged sysroot '$MERGED_SYSROOT' not found. Run 'make merge-sysroot' first." >&2
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

echo "[curl] using CLANG       = $CLANG"
echo "[curl] using AR          = $AR"
echo "[curl] using RANLIB      = $RANLIB"
echo "[curl] LIND_WASM_ROOT    = $LIND_WASM_ROOT"
echo "[curl] merged sysroot    = $MERGED_SYSROOT"
echo "[curl] stage dir         = $STAGE_DIR"
echo "[curl] CC_WASM           = $CC_WASM"
echo

# ----------------------------------------------------------------------
# 3) Force static-only (prevent wasm-ld seeing --shared)
# ----------------------------------------------------------------------
export enable_shared=no
export enable_static=yes
export lt_cv_prog_compiler_pic_works=no
export lt_cv_prog_compiler_static_works=yes

export CFLAGS="${CFLAGS:-} ${CFLAGS_WASM[*]}"
export CPPFLAGS="${CPPFLAGS:-} -I$MERGED_SYSROOT/include -I$MERGED_SYSROOT/include/wasm32-wasi"
export LDFLAGS="${LDFLAGS:-} ${LDFLAGS_WASM[*]}"

# ----------------------------------------------------------------------
# 4) autoreconf (generate configure from configure.ac)
# ----------------------------------------------------------------------
cd "$CURL_ROOT"

echo "[curl] cleaning previous build artifacts…"
make distclean 2>/dev/null || true

echo "[curl] running autoreconf -fi…"
autoreconf -fi

# ----------------------------------------------------------------------
# 5) Configure
# ----------------------------------------------------------------------
echo "[curl] configuring…"

./configure \
  --build="$(./config.guess)" \
  --host=wasm32-unknown-linux-gnu \
  --disable-shared --enable-static --disable-libtool-lock \
  --with-openssl --with-zlib \
  --without-libssh2 --without-libssh --without-brotli --without-zstd \
  --without-libpsl --without-nghttp2 --without-librtmp --without-gssapi \
  --without-gsasl --without-libidn2 --without-winidn \
  --disable-ftp --disable-file --disable-ldap --disable-ldaps \
  --disable-rtsp --disable-dict --disable-telnet --disable-tftp \
  --disable-pop3 --disable-imap --disable-smb --disable-smtp \
  --disable-gopher --disable-mqtt --disable-ipfs \
  --enable-http --enable-proxy --enable-ipv6 \
  --disable-manual --disable-docs --disable-threaded-resolver \
  --disable-websockets --disable-openssl-auto-load-config \
  --without-ca-bundle --without-ca-path --with-ca-fallback \
  CC="$CC_WASM" \
  AR="$AR" \
  RANLIB="$RANLIB" \
  CFLAGS="${CFLAGS_WASM[*]}" \
  CPPFLAGS="$CPPFLAGS" \
  LDFLAGS="${LDFLAGS_WASM[*]}" \
  LIBS="-lssl -lcrypto -lz" \
  PKG_CONFIG=false \
  curl_cv_writable_argv=yes

# ----------------------------------------------------------------------
# 6) Build
# ----------------------------------------------------------------------
echo "[curl] building…"
make -j"$JOBS" V=1

# ----------------------------------------------------------------------
# 7) Stage binary
# ----------------------------------------------------------------------
echo "[curl] staging binary…"

# libtool puts the real binary in src/.libs/curl; fall back to src/curl
CURL_BIN=""
for candidate in "$CURL_ROOT/src/.libs/curl" "$CURL_ROOT/src/curl"; do
  if [[ -f "$candidate" ]]; then
    CURL_BIN="$candidate"
    break
  fi
done

if [[ -z "$CURL_BIN" ]]; then
  echo "[curl] ERROR: curl binary not found in src/.libs/curl or src/curl" >&2
  exit 1
fi

cp "$CURL_BIN" "$STAGE_DIR/curl.wasm"
echo "[curl] staged: $STAGE_DIR/curl.wasm"

# ----------------------------------------------------------------------
# 8) wasm-opt (best-effort)
# ----------------------------------------------------------------------
if [[ -x "$WASM_OPT" ]]; then
  echo "[curl] running wasm-opt (asyncify + optimization)…"
  "$WASM_OPT" \
    --epoch-injection \
    --asyncify \
    --debuginfo \
    -O2 \
    "$STAGE_DIR/curl.wasm" \
    -o "$STAGE_DIR/curl.opt.wasm" || true
else
  echo "[curl] NOTE: wasm-opt not found at '$WASM_OPT'; skipping optimization."
fi

# ----------------------------------------------------------------------
# 9) cwasm generation (best-effort) via lind-boot --precompile
# ----------------------------------------------------------------------
if [[ -x "$LIND_BOOT" ]]; then
  echo "[curl] generating cwasm via lind-boot --precompile…"
  OPT_WASM="$STAGE_DIR/curl.opt.wasm"
  if [[ -f "$OPT_WASM" ]]; then
    if "$LIND_BOOT" --precompile "$OPT_WASM"; then
      # Rename curl.opt.cwasm → curl.cwasm (drop .opt)
      OPT_CWASM="${OPT_WASM%.wasm}.cwasm"
      CLEAN_CWASM="${OPT_CWASM/.opt/}"
      if [[ "$OPT_CWASM" != "$CLEAN_CWASM" && -f "$OPT_CWASM" ]]; then
        mv "$OPT_CWASM" "$CLEAN_CWASM"
      fi
    else
      echo "[curl] WARNING: lind-boot --precompile failed; skipping cwasm generation."
    fi
  else
    echo "[curl] NOTE: no optimized wasm found; trying raw binary…"
    "$LIND_BOOT" --precompile "$STAGE_DIR/curl.wasm" || \
      echo "[curl] WARNING: lind-boot --precompile failed; skipping cwasm generation."
  fi
else
  echo "[curl] NOTE: lind-boot not found at '$LIND_BOOT'; skipping cwasm generation."
fi

echo
echo "[curl] build complete. Outputs under:"
echo "  $STAGE_DIR"
ls -lh "$STAGE_DIR" || true
