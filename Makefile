# -*- makefile -*-
# lind-wasm-apps unified build (hardened, with lmbench build wrapper)

SHELL := /bin/bash
.ONESHELL:
.SHELLFLAGS := -eu -o pipefail -c

# -------- Paths ---------------------------------------------------------------
LIND_WASM_ROOT ?= $(HOME)/lind-wasm
BASE_SYSROOT   ?= $(LIND_WASM_ROOT)/src/glibc/sysroot

APPS_ROOT      := $(CURDIR)
APPS_BUILD     := $(APPS_ROOT)/build
APPS_OVERLAY   := $(APPS_BUILD)/sysroot_overlay
MERGED_SYSROOT := $(APPS_BUILD)/sysroot_merged
APPS_BIN_DIR   := $(APPS_BUILD)/bin
APPS_LIB_DIR   := $(APPS_BUILD)/lib

TOOL_ENV       := $(APPS_BUILD)/.toolchain.env
JOBS ?= $(shell nproc 2>/dev/null || getconf _NPROCESSORS_ONLN || echo 4)

# -------- Phonies -------------------------------------------------------------
.PHONY: all preflight dirs print-config libtirpc gnulib zlib openssl merge-sysroot lmbench bash nginx coreutils grep sed clean clean-all

all: preflight libtirpc gnulib merge-sysroot lmbench bash


print-config:
	@echo "LIND_WASM_ROOT=$(LIND_WASM_ROOT)"
	@echo "BASE_SYSROOT=$(BASE_SYSROOT)"
	@echo "APPS_OVERLAY=$(APPS_OVERLAY)"
	@echo "MERGED_SYSROOT=$(MERGED_SYSROOT)"
	@echo "APPS_BIN_DIR=$(APPS_BIN_DIR)"
	@echo "APPS_LIB_DIR=$(APPS_LIB_DIR)"
	@if [[ -r '$(TOOL_ENV)' ]]; then . '$(TOOL_ENV)'; \
	  echo "CLANG=$$CLANG"; echo "AR=$$AR"; echo "RANLIB=$$RANLIB"; fi

dirs:
	mkdir -p \
	  '$(APPS_OVERLAY)/usr/include' \
	  '$(APPS_OVERLAY)/usr/lib/wasm32-wasi' \
	  '$(APPS_OVERLAY)/lib/wasm32-wasi' \
	  '$(MERGED_SYSROOT)/include' \
	  '$(MERGED_SYSROOT)/include/wasm32-wasi' \
	  '$(MERGED_SYSROOT)/lib/wasm32-wasi' \
	  '$(MERGED_SYSROOT)/usr/lib/wasm32-wasi' \
	  '$(APPS_BIN_DIR)' \
	  '$(APPS_LIB_DIR)'

#   TODO:
#     Once we have a shared helper in lind-wasm (or a stable
#     container path for the toolchain), we should move this into a small
#     script (e.g. scripts/detect_toolchain.sh) or reuse a common helper
#     so the Makefile itself can stay leaner.
preflight: dirs
	@echo "[*] preflight checks…"
	[ -r '$(BASE_SYSROOT)/include/wasm32-wasi/stdio.h' ] || { echo "ERROR: sysroot headers missing at $(BASE_SYSROOT)"; exit 1; }
	{
	  set -euo pipefail
	  CLANG_CAND=( \
	    "$(LIND_WASM_ROOT)/clang+llvm-18.1.8-x86_64-linux-gnu-ubuntu-18.04/bin/clang" \
	    "$$(command -v clang-18 || true)" \
	    "$$(command -v clang || true)" \
	  )
	  AR_CAND=( \
	    "$(LIND_WASM_ROOT)/clang+llvm-18.1.8-x86_64-linux-gnu-ubuntu-18.04/bin/llvm-ar" \
	    "$$(command -v llvm-ar || true)" \
	    "$$(command -v ar || true)" \
	  )
	  RANLIB_CAND=( \
	    "$(LIND_WASM_ROOT)/clang+llvm-18.1.8-x86_64-linux-gnu-ubuntu-18.04/bin/llvm-ranlib" \
	    "$$(command -v llvm-ranlib || true)" \
	    "$$(command -v ranlib || true)" \
	  )
	  pick() { for x in "$$@"; do [[ -x "$$x" ]] && { echo "$$x"; return; }; done; echo ""; }
	  CLANG="$$(pick "$${CLANG_CAND[@]}")"
	  AR="$$(pick   "$${AR_CAND[@]}")"
	  RANLIB="$$(pick "$${RANLIB_CAND[@]}")"
	  [[ -x "$$CLANG"  ]] || { echo "ERROR: clang not found (tried: $${CLANG_CAND[*]})"; exit 1; }
	  [[ -x "$$AR"     ]] || { echo "ERROR: llvm-ar/ar not found (tried: $${AR_CAND[*]})"; exit 1; }
	  [[ -x "$$RANLIB" ]] || { echo "ERROR: llvm-ranlib/ranlib not found (tried: $${RANLIB_CAND[*]})"; exit 1; }
	  {
	    echo "export CLANG='$$CLANG'"
	    echo "export AR='$$AR'"
	    echo "export RANLIB='$$RANLIB'"
	  } > '$(TOOL_ENV)'
	  echo "[*] preflight OK"
	  "$$CLANG" --version | head -n1
	}

# ---------------- libtirpc (via compile_libtirpc.sh) -------------------------
libtirpc: preflight
	. '$(TOOL_ENV)'
	'$(APPS_ROOT)/libtirpc/compile_libtirpc.sh'

# ---------------- gnulib (via compile_gnulib.sh) -----------------------------
gnulib: preflight
	. '$(TOOL_ENV)'
	'$(APPS_ROOT)/gnulib/compile_gnulib.sh'

# ---------------- zlib (via compile_zlib.sh) ----------------------------------
zlib: preflight
	. '$(TOOL_ENV)'
	'$(APPS_ROOT)/zlib/compile_zlib.sh'

# ---------------- openssl (via compile_openssl.sh) ----------------------------
openssl: preflight
	. '$(TOOL_ENV)'
	'$(APPS_ROOT)/openssl/compile_openssl.sh'

# ---------------- Merge sysroot + overlay -------------------------------------
merge-sysroot: libtirpc gnulib zlib openssl
	@echo "[merge] refreshing merged sysroot"
	rsync -a --delete '$(BASE_SYSROOT)/' '$(MERGED_SYSROOT)/'

	# libtirpc headers
	mkdir -p '$(MERGED_SYSROOT)/include/tirpc' '$(MERGED_SYSROOT)/include/wasm32-wasi/tirpc'
	rsync -a '$(APPS_OVERLAY)/usr/include/tirpc/' '$(MERGED_SYSROOT)/include/tirpc/' || true
	rsync -a '$(APPS_OVERLAY)/usr/include/tirpc/' '$(MERGED_SYSROOT)/include/wasm32-wasi/tirpc/' || true

	# gnulib headers (placed under include/gnulib/)
	mkdir -p '$(MERGED_SYSROOT)/include/gnulib' '$(MERGED_SYSROOT)/include/wasm32-wasi/gnulib'
	rsync -a '$(APPS_OVERLAY)/usr/include/gnulib/' '$(MERGED_SYSROOT)/include/gnulib/' || true
	rsync -a '$(APPS_OVERLAY)/usr/include/gnulib/' '$(MERGED_SYSROOT)/include/wasm32-wasi/gnulib/' || true

	# zlib headers
	cp -f '$(APPS_OVERLAY)/usr/include/zlib.h' '$(MERGED_SYSROOT)/include/' || true
	cp -f '$(APPS_OVERLAY)/usr/include/zconf.h' '$(MERGED_SYSROOT)/include/' || true
	cp -f '$(APPS_OVERLAY)/usr/include/zlib.h' '$(MERGED_SYSROOT)/include/wasm32-wasi/' || true
	cp -f '$(APPS_OVERLAY)/usr/include/zconf.h' '$(MERGED_SYSROOT)/include/wasm32-wasi/' || true

	# openssl headers
	mkdir -p '$(MERGED_SYSROOT)/include/openssl' '$(MERGED_SYSROOT)/include/wasm32-wasi/openssl'
	rsync -a '$(APPS_OVERLAY)/usr/include/openssl/' '$(MERGED_SYSROOT)/include/openssl/' || true
	rsync -a '$(APPS_OVERLAY)/usr/include/openssl/' '$(MERGED_SYSROOT)/include/wasm32-wasi/openssl/' || true

	# libs
	rsync -a '$(APPS_OVERLAY)/usr/lib/wasm32-wasi/' '$(MERGED_SYSROOT)/lib/wasm32-wasi/' || true
	rsync -a '$(APPS_OVERLAY)/lib/wasm32-wasi/'     '$(MERGED_SYSROOT)/lib/wasm32-wasi/' || true

# ---------------- lmbench (via compile_lmbench.sh) ---------------------------
lmbench: libtirpc merge-sysroot
	. '$(TOOL_ENV)'
	'$(APPS_ROOT)/lmbench/src/compile_lmbench.sh'

# ---------------- bash (WASM build) -------------------------------------------
# Uses bash/compile_bash.sh to build bash as a wasm32-wasi binary using the
# merged sysroot and toolchain detected by preflight, and stages artifacts
# under build/bin/bash/wasm32-wasi/.
bash: merge-sysroot
	. '$(TOOL_ENV)'
	'$(APPS_ROOT)/bash/compile_bash.sh'

# ---------------- nginx (WASM build) -------------------------------------------
# Uses nginx/compile_nginx.sh to build nginx as a wasm32-wasi binary using the
# merged sysroot and toolchain detected by preflight, and stages artifacts
# under build/bin/nginx/wasm32-wasi/.
nginx: merge-sysroot
	. '$(TOOL_ENV)'
	'$(APPS_ROOT)/nginx/compile_nginx.sh'

# ---------------- coreutils (WASM build) --------------------------------------
# Uses coreutils/compile_coreutils.sh and requires the merged sysroot.
coreutils: merge-sysroot
	. '$(TOOL_ENV)'
	'$(APPS_ROOT)/coreutils/compile_coreutils.sh'

# ---------------- grep (WASM build) -------------------------------------------
grep: merge-sysroot
	. '$(TOOL_ENV)'
	'$(APPS_ROOT)/grep/compile_grep.sh'

# ---------------- sed (WASM build) --------------------------------------------
sed: merge-sysroot
	. '$(TOOL_ENV)'
	'$(APPS_ROOT)/sed/compile_sed.sh'

clean:
	$(MAKE) -C '$(APPS_ROOT)/lmbench/src' clean || true
	-rm -rf '$(APPS_BIN_DIR)/lmbench'
	-rm -rf '$(APPS_BIN_DIR)/nginx'
	-$(MAKE) -C '$(APPS_ROOT)/nginx' clean || true
	-rm -rf '$(APPS_OVERLAY)' '$(MERGED_SYSROOT)' '$(APPS_BIN_DIR)' '$(APPS_LIB_DIR)' '$(TOOL_ENV)'
	$(MAKE) -C '$(APPS_ROOT)/libtirpc' distclean || true

