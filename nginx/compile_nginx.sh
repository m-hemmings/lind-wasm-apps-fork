#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# nginx WASM build helper for lind-wasm-apps
#
# High-level strategy:
#   1. Configure nginx with WASM cross-compilation settings
#   2. Apply patches for WASI compatibility
#   3. Build nginx with wasm32-wasi toolchain
#   4. Optimize with wasm-opt (asyncify for multi-process support)
#   5. Precompile with wasmtime compile
#
# Prerequisites:
#   - Run 'make preflight' and 'make merge-sysroot' from lind-wasm-apps root
#   - Or run 'make all' to build everything including dependencies
###############################################################################

# --- basic paths -------------------------------------------------------------

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
NGINX_ROOT="$APPS_ROOT/nginx"

TOOL_ENV="$APPS_ROOT/build/.toolchain.env"

if [[ -r "$TOOL_ENV" ]]; then
    # shellcheck source=/dev/null
    . "$TOOL_ENV"
fi

if [[ -z "${CLANG:-}" ]]; then
    echo "[nginx] ERROR: CLANG is not set. Run 'make preflight' from lind-wasm-apps root."
    exit 1
fi

# Default LIND_WASM_ROOT to parent directory (layout: lind-wasm/lind-wasm-apps)
if [[ -z "${LIND_WASM_ROOT:-}" ]]; then
    LIND_WASM_ROOT="$(cd "$APPS_ROOT/.." && pwd)"
fi

BASE_SYSROOT="${BASE_SYSROOT:-$LIND_WASM_ROOT/src/glibc/sysroot}"
MERGED_SYSROOT="${APPS_MERGED:-$APPS_ROOT/build/sysroot_merged}"

LLVM_BIN_DIR="$(dirname "$CLANG")"
AR="${AR:-"$LLVM_BIN_DIR/llvm-ar"}"
RANLIB="${RANLIB:-"$LLVM_BIN_DIR/llvm-ranlib"}"

# Wasm optimization and precompilation tools
WASM_OPT="${WASM_OPT:-$LIND_WASM_ROOT/tools/binaryen/bin/wasm-opt}"

JOBS="${JOBS:-$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN || echo 4)}"

# Output location
NGINX_OUT_DIR="$APPS_ROOT/build/bin/nginx/wasm32-wasi"
mkdir -p "$NGINX_OUT_DIR"

# WASM compatibility header
WASM_COMPAT_H="$NGINX_ROOT/wasm_compat.h"

# --- sanity checks -----------------------------------------------------------

if [[ ! -d "$MERGED_SYSROOT" ]]; then
    echo "[nginx] ERROR: merged sysroot '$MERGED_SYSROOT' not found."
    echo "        Run 'make merge-sysroot' (or 'make all') in lind-wasm-apps first."
    exit 1
fi

if [[ ! -r "$BASE_SYSROOT/include/wasm32-wasi/stdio.h" ]]; then
    echo "[nginx] ERROR: base sysroot headers missing at '$BASE_SYSROOT'."
    echo "        Did you run 'make sysroot' in lind-wasm?"
    exit 1
fi

if [[ ! -f "$WASM_COMPAT_H" ]]; then
    echo "[nginx] ERROR: missing nginx/wasm_compat.h (it should be in the repo)."
    exit 1
fi

# --- WASM toolchain flags ----------------------------------------------------

# CFLAGS for WASM cross-compilation
# Note: We pass these via --with-cc-opt during configure
CFLAGS_WASM="-O2 -g -pthread -matomics -mbulk-memory \
    -include $WASM_COMPAT_H \
    -I$MERGED_SYSROOT/include \
    -I$MERGED_SYSROOT/include/wasm32-wasi \
    -D_GNU_SOURCE"

# LDFLAGS for WASM linking
# Note: nginx's generated Makefile does not use $(LDFLAGS). Instead, the link
# rule uses $(LINK) as the full linker command. We pass these flags via the
# LINK make override at build time (not via --with-ld-opt, which configure
# would test and fail for WASM-specific flags).
LDFLAGS_WASM="-Wl,--shared-memory,--import-memory,--export-memory,--max-memory=67108864 \
    -Wl,--export=__stack_pointer,--export=__stack_low \
    -L$MERGED_SYSROOT/lib/wasm32-wasi \
    -L$MERGED_SYSROOT/usr/lib/wasm32-wasi"

echo "[nginx] using CLANG        = $CLANG"
echo "[nginx] using AR           = $AR"
echo "[nginx] LIND_WASM_ROOT     = $LIND_WASM_ROOT"
echo "[nginx] merged sysroot     = $MERGED_SYSROOT"
echo "[nginx] output dir         = $NGINX_OUT_DIR"
echo

pushd "$NGINX_ROOT" >/dev/null

###############################################################################
# 1. Clean any previous build
###############################################################################

echo "[nginx] cleaning any previous build..."
if [[ -f Makefile ]]; then
    make clean >/dev/null 2>&1 || true
fi
rm -rf objs

###############################################################################
# 1.5. Patch auto/types/sizeof for cross-compilation
###############################################################################

# nginx's configure tries to compile and RUN a program to detect type sizes.
# This fails for cross-compilation. We patch it to use compile-time sizeof check.
echo "[nginx] patching auto/types/sizeof for cross-compilation..."

cat > auto/types/sizeof << 'SIZEOF_PATCH'

# Copyright (C) Igor Sysoev
# Copyright (C) Nginx, Inc.
# Patched for WASM cross-compilation

echo $ngx_n "checking for $ngx_type size ...$ngx_c"

cat << END >> $NGX_AUTOCONF_ERR

----------------------------------------
checking for $ngx_type size

END

ngx_size=

cat << END > $NGX_AUTOTEST.c

#include <sys/types.h>
#include <sys/time.h>
$NGX_INCLUDE_UNISTD_H
#include <signal.h>
#include <stdio.h>
#include <sys/resource.h>
$NGX_INCLUDE_INTTYPES_H
$NGX_INCLUDE_AUTO_CONFIG_H

int main(void) {
    printf("%d", (int) sizeof($ngx_type));
    return 0;
}

END

ngx_test="$CC $CC_TEST_FLAGS $CC_AUX_FLAGS \
          -o $NGX_AUTOTEST $NGX_AUTOTEST.c $NGX_LD_OPT $ngx_feature_libs"

eval "$ngx_test >> $NGX_AUTOCONF_ERR 2>&1"

# For cross-compilation (WASM), we cannot run the test binary.
# Try to run it, if that fails, use hardcoded sizes for wasm32.
if [ -x $NGX_AUTOTEST ]; then
    ngx_size=`$NGX_AUTOTEST 2>/dev/null` || ngx_size=""
fi

# If we couldn't get the size by running, use hardcoded sizes for wasm32
if [ -z "$ngx_size" ]; then
    echo " (cross-compile detection)"

    # wasm32 ILP32: int/long/pointers are 4 bytes
    # off_t and time_t are 4 bytes in this sysroot (no _FILE_OFFSET_BITS=64)
    case "$ngx_type" in
        int)
            ngx_size=4
        ;;
        long)
            ngx_size=4
        ;;
        "long long")
            ngx_size=8
        ;;
        "void *")
            ngx_size=4
        ;;
        "size_t")
            ngx_size=4
        ;;
        "off_t")
            ngx_size=4
        ;;
        "time_t")
            ngx_size=4
        ;;
        "sig_atomic_t")
            ngx_size=4
        ;;
        *)
            # Default to 4 for unknown types on wasm32
            ngx_size=4
        ;;
    esac
    echo " $ngx_size bytes (assumed for wasm32)"
else
    echo " $ngx_size bytes"
fi

case $ngx_size in
    4)
        ngx_max_value=2147483647
        ngx_max_len='(sizeof("-2147483648") - 1)'
    ;;

    8)
        ngx_max_value=9223372036854775807LL
        ngx_max_len='(sizeof("-9223372036854775808") - 1)'
    ;;

    *)
        echo
        echo "$0: error: can not detect $ngx_type size"

        echo "----------"    >> $NGX_AUTOCONF_ERR
        cat $NGX_AUTOTEST.c  >> $NGX_AUTOCONF_ERR
        echo "----------"    >> $NGX_AUTOCONF_ERR
        echo $ngx_test       >> $NGX_AUTOCONF_ERR
        echo "----------"    >> $NGX_AUTOCONF_ERR

        rm -rf $NGX_AUTOTEST*

        exit 1
esac


rm -rf $NGX_AUTOTEST*

SIZEOF_PATCH

# Also patch auto/types/typedef for cross-compilation
# It checks if the binary is executable, but WASM binaries aren't native executables
echo "[nginx] patching auto/types/typedef for cross-compilation..."

cat > auto/types/typedef << 'TYPEDEF_PATCH'

# Copyright (C) Igor Sysoev
# Copyright (C) Nginx, Inc.
# Patched for WASM cross-compilation

echo $ngx_n "checking for $ngx_type ...$ngx_c"

cat << END >> $NGX_AUTOCONF_ERR

----------------------------------------
checking for $ngx_type

END

ngx_found=no

for ngx_try in $ngx_type $ngx_types
do

    cat << END > $NGX_AUTOTEST.c

#include <sys/types.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/resource.h>
#include <netinet/in.h>
$NGX_INCLUDE_INTTYPES_H

int main(void) {
    $ngx_try i = 0;
    return (int) i;
}

END

    ngx_test="$CC $CC_TEST_FLAGS $CC_AUX_FLAGS \
              -o $NGX_AUTOTEST $NGX_AUTOTEST.c $NGX_LD_OPT $ngx_feature_libs"

    eval "$ngx_test >> $NGX_AUTOCONF_ERR 2>&1"

    # For cross-compilation, check if compilation succeeded (file exists)
    # rather than if it's executable (WASM files aren't native executables)
    if [ -f $NGX_AUTOTEST ]; then
        if [ $ngx_try = $ngx_type ]; then
            echo " found"
            ngx_found=yes
        else
            echo ", $ngx_try used"
            ngx_found=$ngx_try
        fi
    fi

    if [ $ngx_found = no ]; then
        if [ $ngx_try = $ngx_type ]; then
            echo $ngx_n " $ngx_try not found$ngx_c"
        else
            echo $ngx_n ", $ngx_try not found$ngx_c"
        fi

        echo "----------"    >> $NGX_AUTOCONF_ERR
        cat $NGX_AUTOTEST.c  >> $NGX_AUTOCONF_ERR
        echo "----------"    >> $NGX_AUTOCONF_ERR
        echo $ngx_test       >> $NGX_AUTOCONF_ERR
        echo "----------"    >> $NGX_AUTOCONF_ERR
    fi

    rm -rf $NGX_AUTOTEST*

    if [ $ngx_found != no ]; then
        break
    fi
done

if [ $ngx_found = no ]; then
    echo
    echo "$0: error: can not define $ngx_type"

    exit 1
fi

if [ $ngx_found != yes ]; then
    echo "typedef $ngx_found  $ngx_type;"   >> $NGX_AUTO_CONFIG_H
fi

TYPEDEF_PATCH

# Also patch auto/feature to check for file existence instead of executable
echo "[nginx] patching auto/feature for cross-compilation..."

cat > auto/feature << 'FEATURE_PATCH'

# Copyright (C) Igor Sysoev
# Copyright (C) Nginx, Inc.
# Patched for WASM cross-compilation


echo $ngx_n "checking for $ngx_feature ...$ngx_c"

cat << END >> $NGX_AUTOCONF_ERR

----------------------------------------
checking for $ngx_feature

END

ngx_found=no

if test -n "$ngx_feature_name"; then
    ngx_have_feature=`echo $ngx_feature_name \
                   | tr abcdefghijklmnopqrstuvwxyz ABCDEFGHIJKLMNOPQRSTUVWXYZ`
fi

if test -n "$ngx_feature_path"; then
    for ngx_temp in $ngx_feature_path; do
        ngx_feature_inc_path="$ngx_feature_inc_path -I $ngx_temp"
    done
fi

cat << END > $NGX_AUTOTEST.c

#include <sys/types.h>
$NGX_INCLUDE_UNISTD_H
$ngx_feature_incs

int main(void) {
    $ngx_feature_test;
    return 0;
}

END


ngx_test="$CC $CC_TEST_FLAGS $CC_AUX_FLAGS $ngx_feature_inc_path \
          -o $NGX_AUTOTEST $NGX_AUTOTEST.c $NGX_TEST_LD_OPT $ngx_feature_libs"

ngx_feature_inc_path=

eval "/bin/sh -c \"$ngx_test\" >> $NGX_AUTOCONF_ERR 2>&1"


if [ -f $NGX_AUTOTEST ]; then

    case "$ngx_feature_run" in

        yes)
            # For cross-compilation, we can't run tests
            # Just check if it compiled successfully
            if /bin/sh -c $NGX_AUTOTEST >> $NGX_AUTOCONF_ERR 2>&1; then
                echo " found"
                ngx_found=yes

                if test -n "$ngx_feature_name"; then
                    have=$ngx_have_feature . auto/have
                fi

            else
                echo " found but is not working"
            fi
        ;;

        value)
            # For cross-compilation, we can't run tests
            # Try to run, if it fails, just mark as found
            if ngx_feature_value=`/bin/sh -c $NGX_AUTOTEST 2>/dev/null`; then
                echo " found"
                ngx_found=yes

                cat << END >> $NGX_AUTO_CONFIG_H

#ifndef $ngx_feature_name
#define $ngx_feature_name  $ngx_feature_value
#endif

END
            else
                echo " found (cross-compile: value unknown)"
                ngx_found=yes
                if test -n "$ngx_feature_name"; then
                    have=$ngx_have_feature . auto/have
                fi
            fi
        ;;

        bug)
            # For cross-compilation, we can't run tests
            # Assume no bug
            if /bin/sh -c $NGX_AUTOTEST >> $NGX_AUTOCONF_ERR 2>&1; then
                echo " not found"
            else
                echo " found"
                ngx_found=yes

                if test -n "$ngx_feature_name"; then
                    have=$ngx_have_feature . auto/have
                fi
            fi
        ;;

        *)
            echo " found"
            ngx_found=yes

            if test -n "$ngx_feature_name"; then
                have=$ngx_have_feature . auto/have
            fi
        ;;

    esac

else
    echo " not found"

    echo "----------"    >> $NGX_AUTOCONF_ERR
    cat $NGX_AUTOTEST.c  >> $NGX_AUTOCONF_ERR
    echo "----------"    >> $NGX_AUTOCONF_ERR
    echo $ngx_test       >> $NGX_AUTOCONF_ERR
    echo "----------"    >> $NGX_AUTOCONF_ERR
fi

rm -rf $NGX_AUTOTEST*

FEATURE_PATCH

###############################################################################
# 2. Configure nginx for WASM cross-compilation
###############################################################################

echo "[nginx] configuring for wasm32-wasi cross-compilation..."

# Configure nginx with minimal modules for WASM compatibility
# Note: Some modules are opt-in (--with-X) and disabled by default, so we don't
# need --without-X for them. Only use --without-X for modules enabled by default.
#
# Opt-in modules (disabled by default, don't need --without):
#   http_ssl, http_v2, http_realip, http_addition, http_sub, http_dav,
#   http_flv, http_mp4, http_gunzip, http_gzip_static, http_random_index,
#   http_secure_link, http_degradation, http_slice, http_stub_status,
#   http_perl, stream, mail
#
# Opt-out modules (enabled by default, use --without to disable):
#   http_gzip, http_rewrite, http_userid, http_auth_basic, etc.

# Note: We do NOT use --with-ld-opt here because configure tests it with the
# native compiler, which fails for WASM flags. We'll patch the Makefile instead.
./configure \
    --crossbuild=Linux::wasm32 \
    --with-cc="$CLANG" \
    --with-cc-opt="--target=wasm32-unknown-wasi --sysroot=$MERGED_SYSROOT $CFLAGS_WASM" \
    --prefix=/usr/local/nginx \
    --conf-path=/etc/nginx/nginx.conf \
    --error-log-path=/var/log/nginx/error.log \
    --http-log-path=/var/log/nginx/access.log \
    --pid-path=/var/run/nginx.pid \
    --lock-path=/var/run/nginx.lock \
    --with-poll_module \
    --without-select_module \
    --without-http_rewrite_module \
    --without-http_gzip_module \
    --without-http_ssi_module \
    --without-http_userid_module \
    --without-http_auth_basic_module \
    --without-http_mirror_module \
    --without-http_autoindex_module \
    --without-http_geo_module \
    --without-http_map_module \
    --without-http_split_clients_module \
    --without-http_referer_module \
    --without-http_fastcgi_module \
    --without-http_uwsgi_module \
    --without-http_scgi_module \
    --without-http_grpc_module \
    --without-http_memcached_module \
    --without-http_empty_gif_module \
    --without-http_browser_module \
    --without-http_upstream_hash_module \
    --without-http_upstream_ip_hash_module \
    --without-http_upstream_least_conn_module \
    --without-http_upstream_random_module \
    --without-http_upstream_keepalive_module \
    --without-http_upstream_zone_module \
    --without-pcre

###############################################################################
# 3. Patch generated files for WASI compatibility
###############################################################################

echo "[nginx] patching generated configuration for WASI..."

# Patch objs/ngx_auto_config.h to disable features that configure may have
# incorrectly detected (cross-compile tests compile but don't run)
if [[ -f objs/ngx_auto_config.h ]]; then
    # Disable sendfile - not available in WASI
    sed -i 's/#define NGX_HAVE_SENDFILE\s*1/#define NGX_HAVE_SENDFILE 0/' objs/ngx_auto_config.h || true
    sed -i 's/#define NGX_HAVE_SENDFILE64\s*1/#define NGX_HAVE_SENDFILE64 0/' objs/ngx_auto_config.h || true

    # Disable AIO - not available in WASI
    sed -i 's/#define NGX_HAVE_FILE_AIO\s*1/#define NGX_HAVE_FILE_AIO 0/' objs/ngx_auto_config.h || true

    # Disable epoll - use poll instead (epoll is Linux-specific)
    sed -i 's/#define NGX_HAVE_EPOLL\s*1/#define NGX_HAVE_EPOLL 0/' objs/ngx_auto_config.h || true
    sed -i 's/#define NGX_HAVE_EPOLLRDHUP\s*1/#define NGX_HAVE_EPOLLRDHUP 0/' objs/ngx_auto_config.h || true

    # Disable eventfd - Linux-specific
    sed -i 's/#define NGX_HAVE_EVENTFD\s*1/#define NGX_HAVE_EVENTFD 0/' objs/ngx_auto_config.h || true

    # Disable mmap MAP_ANON if configured (we support MAP_ANONYMOUS)
    # Note: Lind does support mmap, but with limited flags

    # Disable prctl - Linux-specific
    sed -i 's/#define NGX_HAVE_PR_SET_DUMPABLE\s*1/#define NGX_HAVE_PR_SET_DUMPABLE 0/' objs/ngx_auto_config.h || true

    # Disable sched_setaffinity - not meaningful in WASM
    sed -i 's/#define NGX_HAVE_SCHED_SETAFFINITY\s*1/#define NGX_HAVE_SCHED_SETAFFINITY 0/' objs/ngx_auto_config.h || true

    # Disable SO_SETFIB - BSD-specific
    sed -i 's/#define NGX_HAVE_SETFIB\s*1/#define NGX_HAVE_SETFIB 0/' objs/ngx_auto_config.h || true

    # Disable TCP_FASTOPEN - may not be available
    sed -i 's/#define NGX_HAVE_TCP_FASTOPEN\s*1/#define NGX_HAVE_TCP_FASTOPEN 0/' objs/ngx_auto_config.h || true

    # Disable UNIX domain socket credentials - may not work in WASI
    sed -i 's/#define NGX_HAVE_UNIX_DOMAIN\s*1/#define NGX_HAVE_UNIX_DOMAIN 0/' objs/ngx_auto_config.h || true

    # ENABLE MAP_ANON for shared memory (Lind supports mmap with MAP_ANONYMOUS)
    # Note: MAP_ANON is equivalent to MAP_ANONYMOUS
    if ! grep -q "NGX_HAVE_MAP_ANON" objs/ngx_auto_config.h; then
        echo "" >> objs/ngx_auto_config.h
        echo "#ifndef NGX_HAVE_MAP_ANON" >> objs/ngx_auto_config.h
        echo "#define NGX_HAVE_MAP_ANON  1" >> objs/ngx_auto_config.h
        echo "#endif" >> objs/ngx_auto_config.h
    fi

    # ENABLE POSIX semaphores (Lind supports sem_init, sem_wait, etc.)
    if ! grep -q "NGX_HAVE_POSIX_SEM" objs/ngx_auto_config.h; then
        echo "" >> objs/ngx_auto_config.h
        echo "#ifndef NGX_HAVE_POSIX_SEM" >> objs/ngx_auto_config.h
        echo "#define NGX_HAVE_POSIX_SEM  1" >> objs/ngx_auto_config.h
        echo "#endif" >> objs/ngx_auto_config.h
    fi

    echo "[nginx] patched objs/ngx_auto_config.h"
fi

###############################################################################
# 4. Build nginx
###############################################################################

echo "[nginx] building nginx with wasm32-wasi toolchain..."

# nginx's generated Makefile uses $(CC), $(CFLAGS), and $(LINK) — but NOT
# $(LDFLAGS). The link rule is: $(LINK) -o objs/nginx <objects> <libs>
# So WASM linker flags must be passed via LINK, not LDFLAGS.
make -j"$JOBS" \
    CC="$CLANG --target=wasm32-unknown-wasi --sysroot=$MERGED_SYSROOT" \
    CFLAGS="$CFLAGS_WASM" \
    LINK="$CLANG --target=wasm32-unknown-wasi --sysroot=$MERGED_SYSROOT $LDFLAGS_WASM"

if [[ ! -f objs/nginx ]]; then
    echo "[nginx] ERROR: nginx binary was not produced."
    exit 1
fi

# Copy the binary to output directory
cp objs/nginx "$NGINX_OUT_DIR/nginx.wasm"
echo "[nginx] built: $NGINX_OUT_DIR/nginx.wasm"

###############################################################################
# 5. Optimize with wasm-opt (asyncify for fork/exec support)
###############################################################################

if [[ -x "$WASM_OPT" ]]; then
    echo "[nginx] running wasm-opt (asyncify + optimization)..."
    "$WASM_OPT" \
        --epoch-injection \
        --asyncify \
        --debuginfo \
        -O2 \
        "$NGINX_OUT_DIR/nginx.wasm" \
        -o "$NGINX_OUT_DIR/nginx.opt.wasm"
    echo "[nginx] optimized: $NGINX_OUT_DIR/nginx.opt.wasm"
else
    echo "[nginx] NOTE: wasm-opt not found at $WASM_OPT; skipping optimization."
    cp "$NGINX_OUT_DIR/nginx.wasm" "$NGINX_OUT_DIR/nginx.opt.wasm"
fi

###############################################################################
# 6. Copy configuration files
###############################################################################

echo "[nginx] copying configuration files..."
mkdir -p "$NGINX_OUT_DIR/conf"
cp -r "$NGINX_ROOT/conf/"* "$NGINX_OUT_DIR/conf/" 2>/dev/null || true
cp -r "$NGINX_ROOT/html" "$NGINX_OUT_DIR/" 2>/dev/null || true

# Create a minimal nginx.conf for WASM testing
cat > "$NGINX_OUT_DIR/conf/nginx-wasm.conf" << 'EOF'
# nginx configuration for WASM/Lind runtime
# Run in foreground, single-process mode for initial testing

daemon off;
master_process off;
worker_processes 1;

error_log /dev/stderr info;

events {
    use poll;
    worker_connections 64;
}

http {
    include       mime.types;
    default_type  application/octet-stream;

    access_log /dev/stdout;

    sendfile off;
    keepalive_timeout 65;

    server {
        listen 8080;
        server_name localhost;

        location / {
            root   html;
            index  index.html index.htm;
        }

        error_page 500 502 503 504 /50x.html;
        location = /50x.html {
            root html;
        }
    }
}
EOF
echo "[nginx] created minimal config: $NGINX_OUT_DIR/conf/nginx-wasm.conf"

popd >/dev/null

###############################################################################
# Done
###############################################################################

echo
echo "[nginx] build complete. Outputs:"
ls -lh "$NGINX_OUT_DIR"/*.wasm 2>/dev/null || true
echo
echo "To run nginx in Lind:"
echo "  $LIND_WASM_ROOT/scripts/lind_run $NGINX_OUT_DIR/nginx.opt.wasm -c /etc/nginx/nginx.conf"
echo
echo "Or with the test config:"
echo "  $LIND_WASM_ROOT/scripts/lind_run $NGINX_OUT_DIR/nginx.opt.wasm -c conf/nginx-wasm.conf"
