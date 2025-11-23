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
.PHONY: all preflight dirs print-config libtirpc merge-sysroot stubs lmbench clean clean-all

all: preflight libtirpc merge-sysroot stubs lmbench

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

# ---------------- Merge sysroot + overlay -------------------------------------
merge-sysroot: libtirpc
	@echo "[merge] refreshing merged sysroot"
	rsync -a --delete '$(BASE_SYSROOT)/' '$(MERGED_SYSROOT)/'
	mkdir -p '$(MERGED_SYSROOT)/include/tirpc' '$(MERGED_SYSROOT)/include/wasm32-wasi/tirpc'
	rsync -a '$(APPS_OVERLAY)/usr/include/tirpc/' '$(MERGED_SYSROOT)/include/tirpc/' || true
	rsync -a '$(APPS_OVERLAY)/usr/include/tirpc/' '$(MERGED_SYSROOT)/include/wasm32-wasi/tirpc/' || true
	rsync -a '$(APPS_OVERLAY)/usr/lib/wasm32-wasi/' '$(MERGED_SYSROOT)/lib/wasm32-wasi/' || true
	rsync -a '$(APPS_OVERLAY)/lib/wasm32-wasi/'     '$(MERGED_SYSROOT)/lib/wasm32-wasi/' || true

# ---------------- Stubs (libm + WASI sched_*) --------------------------------
# NOTE:
#   The current lind-wasm WASI sysroot does not always ship a libm.a or
#   implementations of the POSIX scheduler calls that lmbench expects
#   (sched_get_priority_max, sched_setscheduler). To keep the lmbench build
#   self-contained, we:
#     * synthesize a tiny dummy libm.a when it is missing, and
#     * build a small compatibility archive (liblmb_stubs.a) that provides
#       "not supported" stubs for the missing scheduler APIs.
#
#   This lets lmbench link successfully without pretending the functionality
#   is actually supported at runtime (the stubs just set errno = ENOTSUP and
#   return an error).
#
#   TODO:
#     Once the lind-wasm toolchain / sysroot grows proper libm and scheduler
#     support for wasm32-wasi, we should delete this target and have lmbench
#     link directly against the real libraries instead of these stubs.
stubs: merge-sysroot
	. '$(TOOL_ENV)'
	if [[ ! -f '$(MERGED_SYSROOT)/lib/wasm32-wasi/libm.a' ]]; then
	  echo "[stubs] creating stub libm.a"
	  printf 'void __libm_stub(void){}' > '$(APPS_BUILD)/.libm.c'
	  "$$CLANG" --target=wasm32-unknown-wasi --sysroot='$(MERGED_SYSROOT)' -c '$(APPS_BUILD)/.libm.c' -o '$(APPS_BUILD)/.libm.o'
	  "$$AR" rcs '$(MERGED_SYSROOT)/lib/wasm32-wasi/libm.a' '$(APPS_BUILD)/.libm.o'
	  "$$RANLIB" '$(MERGED_SYSROOT)/lib/wasm32-wasi/libm.a' || true
	fi
	cat > '$(APPS_BUILD)/wasi_compat_stubs.c' <<-'EOF'
		#include <errno.h>
		#include <sched.h>
		int sched_get_priority_max(int policy) { (void)policy; errno = ENOTSUP; return -1; }
		int sched_setscheduler(pid_t pid, int policy, const struct sched_param *param) {
		  (void)pid; (void)policy; (void)param; errno = ENOTSUP; return -1;
		}
	EOF
	"$$CLANG" --target=wasm32-unknown-wasi --sysroot='$(MERGED_SYSROOT)' -c \
	  '$(APPS_BUILD)/wasi_compat_stubs.c' -o '$(APPS_BUILD)/wasi_compat_stubs.o'
	"$$AR" rcs '$(APPS_LIB_DIR)/liblmb_stubs.a' '$(APPS_BUILD)/wasi_compat_stubs.o'
	"$$RANLIB" '$(APPS_LIB_DIR)/liblmb_stubs.a' || true

# ---------------- lmbench (via compile_lmbench.sh) ---------------------------
lmbench: stubs
	. '$(TOOL_ENV)'
	'$(APPS_ROOT)/lmbench/src/compile_lmbench.sh'

clean:
	$(MAKE) -C '$(APPS_ROOT)/lmbench/src' clean || true
	-rm -f '$(APPS_BUILD)/.libm.c' '$(APPS_BUILD)/.libm.o' \
	       '$(APPS_BUILD)/wasi_compat_stubs.c' '$(APPS_BUILD)/wasi_compat_stubs.o' \
	       '$(APPS_LIB_DIR)/liblmb_stubs.a'
	-rm -rf '$(APPS_BIN_DIR)/lmbench'

clean-all: clean
	-rm -rf '$(APPS_OVERLAY)' '$(MERGED_SYSROOT)' '$(APPS_BIN_DIR)' '$(APPS_LIB_DIR)' '$(TOOL_ENV)'
	$(MAKE) -C '$(APPS_ROOT)/libtirpc' distclean || true

