/*
 * High-resolution timing C stubs for AlgoStream
 * Provides access to platform-specific high-resolution timers
 */

#include <caml/mlvalues.h>
#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/fail.h>

#include <time.h>
#include <stdint.h>
#include <errno.h>

#ifdef __MACH__
#include <mach/mach_time.h>
#include <sys/time.h>
#endif

#ifdef __linux__
#include <unistd.h>
#include <sys/syscall.h>
#endif

#if defined(__x86_64__) || defined(__i386__)
#include <x86intrin.h>
#endif

/*
 * Get monotonic time in nanoseconds
 * Best for measuring elapsed time and latency
 */
value algostream_get_monotonic_time_ns(value unit) {
    CAMLparam1(unit);
    int64_t ns;

#ifdef __MACH__
    /* macOS implementation using mach_absolute_time */
    static mach_timebase_info_data_t timebase_info = {0, 0};
    if (timebase_info.denom == 0) {
        mach_timebase_info(&timebase_info);
    }
    uint64_t abs_time = mach_absolute_time();
    ns = (int64_t)((abs_time * timebase_info.numer) / timebase_info.denom);

#elif defined(__linux__)
    /* Linux implementation using clock_gettime */
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        caml_failwith("clock_gettime failed");
    }
    ns = (int64_t)ts.tv_sec * 1000000000LL + (int64_t)ts.tv_nsec;

#else
    /* Fallback implementation */
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        caml_failwith("clock_gettime not available");
    }
    ns = (int64_t)ts.tv_sec * 1000000000LL + (int64_t)ts.tv_nsec;
#endif

    CAMLreturn(caml_copy_int64(ns));
}

/*
 * Get real time in nanoseconds since Unix epoch
 * For timestamping market events
 */
value algostream_get_realtime_ns(value unit) {
    CAMLparam1(unit);
    int64_t ns;

#ifdef __MACH__
    /* macOS implementation */
    struct timeval tv;
    if (gettimeofday(&tv, NULL) != 0) {
        caml_failwith("gettimeofday failed");
    }
    ns = (int64_t)tv.tv_sec * 1000000000LL + (int64_t)tv.tv_usec * 1000LL;

#elif defined(__linux__)
    /* Linux implementation using clock_gettime with CLOCK_REALTIME */
    struct timespec ts;
    if (clock_gettime(CLOCK_REALTIME, &ts) != 0) {
        caml_failwith("clock_gettime failed");
    }
    ns = (int64_t)ts.tv_sec * 1000000000LL + (int64_t)ts.tv_nsec;

#else
    /* Fallback implementation */
    struct timespec ts;
    if (clock_gettime(CLOCK_REALTIME, &ts) != 0) {
        caml_failwith("clock_gettime not available");
    }
    ns = (int64_t)ts.tv_sec * 1000000000LL + (int64_t)ts.tv_nsec;
#endif

    CAMLreturn(caml_copy_int64(ns));
}

/*
 * Get CPU cycle count
 * Fastest timer, but requires frequency calibration
 */
value algostream_get_cpu_cycle_count(value unit) {
    CAMLparam1(unit);
    uint64_t cycles;

#if defined(__x86_64__) || defined(__i386__)
    /* x86/x64 implementation using RDTSC */
    cycles = __rdtsc();
#elif defined(__aarch64__)
    /* ARM64 implementation */
    asm volatile("mrs %0, cntvct_el0" : "=r" (cycles));
#else
    /* Fallback to monotonic time for other architectures */
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        caml_failwith("CPU cycle count not available");
    }
    cycles = (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
#endif

    CAMLreturn(caml_copy_int64((int64_t)cycles));
}

/*
 * High-precision nanosleep
 * For precise timing delays
 */
value algostream_nanosleep(value duration_ns_val) {
    CAMLparam1(duration_ns_val);
    int64_t duration_ns = Int64_val(duration_ns_val);

    if (duration_ns <= 0) {
        CAMLreturn(Val_unit);
    }

    struct timespec req;
    req.tv_sec = duration_ns / 1000000000LL;
    req.tv_nsec = duration_ns % 1000000000LL;

    struct timespec rem;
    while (nanosleep(&req, &rem) == -1) {
        if (errno == EINTR) {
            /* Interrupted by signal, continue sleeping for remaining time */
            req = rem;
        } else {
            caml_failwith("nanosleep failed");
        }
    }

    CAMLreturn(Val_unit);
}

/*
 * Prefault memory pages to avoid page faults during trading
 */
value algostream_prefault_pages(value addr_val, value size_val) {
    CAMLparam2(addr_val, size_val);
    void *addr = (void*)Nativeint_val(addr_val);
    size_t size = Long_val(size_val);

    /* Touch every page to ensure it's mapped */
    size_t page_size = 4096; /* Most common page size */
    volatile char *ptr = (volatile char*)addr;

    for (size_t offset = 0; offset < size; offset += page_size) {
        ptr[offset] = ptr[offset]; /* Read and write back */
    }

    CAMLreturn(Val_unit);
}

/*
 * Memory barrier to ensure ordering of memory operations
 */
value algostream_memory_barrier(value unit) {
    CAMLparam1(unit);

#if defined(__GNUC__)
    __sync_synchronize();
#elif defined(_MSC_VER)
    _ReadWriteBarrier();
#else
    /* Fallback - may not be as efficient */
    volatile int dummy = 0;
    dummy = dummy;
#endif

    CAMLreturn(Val_unit);
}