#ifndef WASM_COMPAT_H
#define WASM_COMPAT_H

#ifdef __wasi__
#include <sys/stat.h>

/* Map old stat field names to WASI fields (seconds only). */
#ifndef st_atime
#define st_atime st_atim.tv_sec
#endif

#ifndef st_mtime
#define st_mtime st_mtim.tv_sec
#endif

#ifndef st_ctime
#define st_ctime st_ctim.tv_sec
#endif

#endif /* __wasi__ */

#endif /* WASM_COMPAT_H */
