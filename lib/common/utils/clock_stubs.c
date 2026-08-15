/*
 * Monotonic and realtime clocks.
 *
 * These carry an "algostream_clock_" prefix rather than reusing the names in portable_stubs.c on
 * purpose: that file already defines algostream_get_monotonic_time_ns and
 * algostream_get_realtime_ns, so compiling both translation units would be a duplicate-symbol link
 * error. (Those definitions are also gettimeofday underneath, and nothing binds them — the OCaml
 * side called Unix.gettimeofday directly. See time_stubs.c for the original, uncompiled attempt at
 * this.)
 *
 * Why this is not Unix.gettimeofday:
 *
 *   gettimeofday returns the wall clock, which steps. An NTP correction, a manual clock change or a
 *   VM resume can move it backwards, and every duration measured by subtracting two such readings
 *   then comes out negative. Telemetry discards negative samples — reasonably, since they normally
 *   mean the caller subtracted the wrong way round — so a clock step silently deleted latency data
 *   instead of reporting anything. It also caps resolution at a microsecond, which is coarse for a
 *   function whose return type is nanoseconds.
 *
 * A monotonic clock counts from an unspecified epoch, so its absolute value is meaningless and only
 * differences are defined — exactly what latency measurement wants. Realtime stays a separate
 * function for the callers that genuinely need wall time (audit records, anything a human reads).
 * See below for which monotonic clock id is used on which platform.
 */

#define _POSIX_C_SOURCE 200809L
/* _POSIX_C_SOURCE alone hides the non-POSIX clock ids on Darwin, including CLOCK_MONOTONIC_RAW. */
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif

#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/alloc.h>
#include <caml/fail.h>

#include <time.h>
#include <stdint.h>

/*
 * Which monotonic clock, and why it differs by platform.
 *
 * Measured on this project's macOS dev machine over 200k back-to-back pairs:
 *
 *     CLOCK_MONOTONIC       smallest non-zero delta 1000 ns  (microsecond-granular)
 *     CLOCK_MONOTONIC_RAW   smallest non-zero delta   41 ns
 *
 * macOS rounds CLOCK_MONOTONIC to microseconds, which is useless for a project that measures
 * event-bus latency in nanoseconds — it would report the same resolution as the gettimeofday this
 * replaces. CLOCK_MONOTONIC_RAW is backed by mach_absolute_time and resolves ~24x finer.
 *
 * On Linux CLOCK_MONOTONIC is already nanosecond-resolution and is the better choice: it is
 * NTP-slewed, so it stays aligned with real elapsed seconds, while _RAW is unslewed hardware time
 * that drifts. Neither ever steps backwards, which is the property that matters here.
 */
#if defined(__MACH__) && defined(CLOCK_MONOTONIC_RAW)
#define ALGOSTREAM_MONOTONIC CLOCK_MONOTONIC_RAW
#else
#define ALGOSTREAM_MONOTONIC CLOCK_MONOTONIC
#endif

static int64_t timespec_to_ns(const struct timespec *ts) {
    return (int64_t) ts->tv_sec * 1000000000LL + (int64_t) ts->tv_nsec;
}

/*
 * Never decreases. Unrelated to the Unix epoch — only differences between two readings are
 * meaningful.
 */
CAMLprim value algostream_clock_monotonic_ns(value unit) {
    CAMLparam1(unit);
    CAMLlocal1(result);

    struct timespec ts;
    if (clock_gettime(ALGOSTREAM_MONOTONIC, &ts) != 0) {
        caml_failwith("clock_gettime failed for the monotonic clock");
    }

    result = caml_copy_int64(timespec_to_ns(&ts));
    CAMLreturn(result);
}

/* Wall clock, nanoseconds since the Unix epoch. Steps; do not measure durations with it. */
CAMLprim value algostream_clock_realtime_ns(value unit) {
    CAMLparam1(unit);
    CAMLlocal1(result);

    struct timespec ts;
    if (clock_gettime(CLOCK_REALTIME, &ts) != 0) {
        caml_failwith("clock_gettime(CLOCK_REALTIME) failed");
    }

    result = caml_copy_int64(timespec_to_ns(&ts));
    CAMLreturn(result);
}
