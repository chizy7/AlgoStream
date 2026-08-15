/*
 * CPU affinity stubs for AlgoStream.
 *
 * These carry an "algostream_affinity_" prefix rather than reusing the names in benchmark_stubs.c
 * on purpose: portable_stubs.c — the one C file this library has ever compiled — already defines
 * algostream_set_cpu_affinity and algostream_get_cpu_count as printf no-ops, so building both
 * translation units is a duplicate-symbol link error. Lifting only the affinity bodies into their
 * own file with their own prefix also keeps benchmark_stubs.c's algostream_disable_aslr,
 * algostream_set_realtime_priority and algostream_set_cpu_governor out of the build, which is where
 * they belong until someone has a reason for them.
 *
 * Real pinning is Linux-only, and deliberately so. macOS exposes THREAD_AFFINITY_POLICY via
 * thread_policy_set, but it is an advisory hint that groups threads into affinity sets rather than
 * binding one to a core, and it is ignored outright on Apple Silicon. Calling it and reporting
 * success would be a lie, so every non-Linux platform reports unsupported and the OCaml side turns
 * that into an `Unsupported error. See affinity.mli.
 */

/*
 * Must precede every #include, system or otherwise — the caml headers pull in libc headers of their
 * own, and once features.h has been processed the macro has no effect.
 *
 * glibc hides cpu_set_t, CPU_SETSIZE, CPU_ZERO, CPU_SET and sched_setaffinity behind _GNU_SOURCE;
 * they are GNU extensions, not POSIX. Without it <sched.h> compiles cleanly and simply declares
 * none of them, so the failure is not a missing header but three implicit-function-declaration
 * warnings and one hard error on CPU_SETSIZE.
 *
 * This was not caught before it reached CI because macOS compiles none of the block below — the
 * Linux path only ever exists on the platform that was not being built locally.
 */
#define _GNU_SOURCE

#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/fail.h>
#include <caml/unixsupport.h>

#include <errno.h>
#include <unistd.h>

#ifdef __linux__
#define ALGOSTREAM_HAVE_AFFINITY 1
#include <sched.h>
#else
#define ALGOSTREAM_HAVE_AFFINITY 0
#endif

CAMLprim value algostream_affinity_supported(value unit) {
    CAMLparam1(unit);
    CAMLreturn(Val_bool(ALGOSTREAM_HAVE_AFFINITY));
}

/*
 * Pin the *calling thread* to one core.
 *
 * On Linux a pid of 0 means the calling thread, not the process — that is precisely what makes
 * per-Domain pinning work: each Domain calls this from inside its own entry point and binds only
 * itself, leaving its siblings free to be placed elsewhere.
 */
CAMLprim value algostream_affinity_pin(value cpu_id_val) {
    CAMLparam1(cpu_id_val);

#if ALGOSTREAM_HAVE_AFFINITY
    int cpu_id = Int_val(cpu_id_val);

    /* CPU_SET past CPU_SETSIZE writes outside the mask. Check before, rather than letting
       sched_setaffinity report EINVAL after the damage is done. */
    if (cpu_id < 0 || cpu_id >= CPU_SETSIZE) {
        caml_unix_error(EINVAL, "sched_setaffinity", Nothing);
    }

    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(cpu_id, &set);

    if (sched_setaffinity(0, sizeof(cpu_set_t), &set) != 0) {
        caml_uerror("sched_setaffinity", Nothing);
    }
#else
    (void) cpu_id_val;
    caml_failwith("cpu affinity is not supported on this platform");
#endif

    CAMLreturn(Val_unit);
}

/*
 * Online core count. Portable, unlike the pinning above — sysconf is available everywhere this
 * project builds, so this is a real answer on macOS too rather than benchmark.ml's hardcoded 4.
 */
CAMLprim value algostream_affinity_cpu_count(value unit) {
    CAMLparam1(unit);

    long n = sysconf(_SC_NPROCESSORS_ONLN);
    if (n <= 0) {
        n = 1;
    }

    CAMLreturn(Val_int((int) n));
}
