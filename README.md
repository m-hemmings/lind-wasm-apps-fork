# lind-wasm-apps
Various WebAssembly (WASM) application builds intended for use with Lind-Wasm.

This repository contains example and utility applications (benchmarks, demos, etc.) that integrate with the Lind runtime environment to showcase capabilities, facilitate testing, and serve as starting points for WASM-based development.

Lind is a platform for running WASM applications in a secure, sandboxed environment. The lind-wasm-apps project exists to:

- Provide realistic examples of applications compiled to WASM for use in Lind.

- Offer benchmarks and performance tests to validate and stress-test Lind’s runtime.

- Serve as reference implementations or scaffolding for developers building their own WASM apps targeting Lind

Clone this repo (commonly alongside `lind-wasm`):
- git clone https://github.com/Lind-Project/lind-wasm-apps.git
- cd lind-wasm-apps

## Build

==Build everything:==
- make all

Artifacts land under`build/`:

- `build/sysroot_overlay/` – staged headers/libs (e.g., libtirpc)
- `build/sysroot_merged/` – base sysroot + overlay
- `build/lib/` – helper archives (e.g., `liblmb_stubs.a`, combined `libc.a`)
- `build/bin/lmbench/wasm32-wasi/` – lmbench binaries
- `build/bin/bash/wasm32-wasi/` – bash outputs

==List produced binaries:==
- find build/bin -maxdepth 4 -type f -printf '%P\n' | sort

## Makefile targets

- `make preflight`  
	Detects toolchain (`clang`, `llvm-ar`, `llvm-ranlib`) and writes `build/.toolchain.env`.
- `make libtirpc`  
	Builds libtirpc (WASI) and stages into `build/sysroot_overlay/`.
- `make merge-sysroot`  
	Copies the base sysroot into `build/sysroot_merged/` and overlays libtirpc.
- `make stubs`  
	Creates small compatibility stubs needed for lmbench (temporary workaround; see TODOs in Makefile).
- `make lmbench`  
	Builds lmbench via `lmbench/src/compile_lmbench.sh` and stages into `build/bin/lmbench/wasm32-wasi/`.
- `make bash`  
	Builds bash via `bash/compile_bash.sh` and stages into `build/bin/bash/wasm32-wasi/`.
- `make clean
	Remove build outputs and merged sysroot + overlay.

## Optional environment variables

- `LIND_WASM_ROOT` – path to `lind-wasm` (default: `~/lind-wasm`)
- `WASMTIME_PROFILE` – `debug` or `release` (scripts fall back to `release` if missing)
- `WASM_OPT`, `WASMTIME` – override tool paths if needed

