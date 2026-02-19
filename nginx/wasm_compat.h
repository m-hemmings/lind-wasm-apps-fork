/*
 * wasm_compat.h - WASI/Lind compatibility header for nginx
 *
 * This header provides compatibility definitions for nginx running on
 * the Lind-Wasm runtime.
 *
 * NOTE: As of the latest lind-wasm sysroot, most POSIX functions are now
 * implemented in the glibc sysroot. This file now only contains:
 *   - Preprocessor defines to disable unavailable features
 *   - Stat time field mappings for WASI compatibility
 *   - CPU affinity type definitions (if missing)
 *
 * The following functions ARE now provided by the sysroot:
 *   - setuid, setgid, seteuid, setegid
 *   - getpwnam, getgrnam, getpwuid, getgrgid
 *   - initgroups, getgroups
 *   - getrlimit, setrlimit
 *   - setpriority, getpriority
 *   - sched_setaffinity, sched_getaffinity
 *   - daemon
 *
 * Usage: Include via -include wasm_compat.h in CFLAGS
 */

#ifndef _WASM_COMPAT_H
#define _WASM_COMPAT_H

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Sendfile Fallback
 *
 * sendfile() is NOT implemented in Lind. nginx has fallback code paths
 * when sendfile is not available. Ensure NGX_HAVE_SENDFILE is not defined.
 */

#ifdef NGX_HAVE_SENDFILE
#undef NGX_HAVE_SENDFILE
#endif

#ifdef NGX_HAVE_SENDFILE64
#undef NGX_HAVE_SENDFILE64
#endif

/*
 * Time-related stat field mappings
 *
 * WASI uses timespec for file times; map the traditional fields.
 * Only define if not already provided.
 */

#ifndef st_atime
#define st_atime st_atim.tv_sec
#endif

#ifndef st_mtime
#define st_mtime st_mtim.tv_sec
#endif

#ifndef st_ctime
#define st_ctime st_ctim.tv_sec
#endif

/*
 * CPU Affinity Type Definitions
 *
 * The sysroot may not define cpu_set_t type and macros.
 * These are needed for nginx's CPU affinity handling.
 */

#include <sched.h>
#include <string.h>

#ifndef CPU_SETSIZE
#define CPU_SETSIZE 1024
typedef struct {
    unsigned long __bits[CPU_SETSIZE / (8 * sizeof(unsigned long))];
} cpu_set_t;
#endif

#ifndef CPU_ZERO
#define CPU_ZERO(set) memset((set), 0, sizeof(cpu_set_t))
#endif

#ifndef CPU_SET
#define CPU_SET(cpu, set) ((void)0)
#endif

#ifndef CPU_ISSET
#define CPU_ISSET(cpu, set) (0)
#endif

/*
 * crypt() stub
 *
 * If crypt() is not available in the sysroot, provide a stub that
 * always fails authentication (safer than always succeeding).
 * The auth_basic module is disabled anyway.
 */

#if !defined(HAVE_CRYPT) && !defined(_CRYPT_H)
static inline char *crypt(const char *key, const char *salt) {
    (void)key;
    (void)salt;
    /* Return NULL to indicate failure - passwords won't verify */
    return (char *)0;
}
#define HAVE_CRYPT 1
#endif

#ifdef __cplusplus
}
#endif

#endif /* _WASM_COMPAT_H */
