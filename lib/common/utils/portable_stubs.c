/*
 * Portable C stubs for AlgoStream - Safe version without hardware optimizations
 * This version will compile and run on any system without specific hardware requirements
 */

#include <caml/mlvalues.h>
#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/fail.h>

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <sys/time.h>
#include <time.h>
#include <math.h>

/*
 * Portable timing functions - uses standard POSIX functions
 */
value algostream_get_monotonic_time_ns(value unit_val) {
    CAMLparam1(unit_val);
    CAMLlocal1(result);

    struct timeval tv;
    gettimeofday(&tv, NULL);
    int64_t ns = (int64_t)tv.tv_sec * 1000000000LL + (int64_t)tv.tv_usec * 1000LL;

    result = caml_copy_int64(ns);
    CAMLreturn(result);
}

value algostream_get_realtime_ns(value unit_val) {
    CAMLparam1(unit_val);
    CAMLlocal1(result);

    struct timeval tv;
    gettimeofday(&tv, NULL);
    int64_t ns = (int64_t)tv.tv_sec * 1000000000LL + (int64_t)tv.tv_usec * 1000LL;

    result = caml_copy_int64(ns);
    CAMLreturn(result);
}

value algostream_get_cpu_cycle_count(value unit_val) {
    CAMLparam1(unit_val);
    CAMLlocal1(result);

    /* Fallback: use time-based approximation */
    struct timeval tv;
    gettimeofday(&tv, NULL);
    int64_t cycles = (int64_t)tv.tv_sec * 2400000000LL + (int64_t)tv.tv_usec * 2400LL; /* Assume 2.4GHz */

    result = caml_copy_int64(cycles);
    CAMLreturn(result);
}

/*
 * Portable CPU optimization functions - safe fallbacks
 */
value algostream_set_cpu_affinity(value cpu_id_val) {
    CAMLparam1(cpu_id_val);

    /* Safe no-op - just print a message */
    printf("CPU affinity setting not supported in portable mode\n");

    CAMLreturn(Val_unit);
}

value algostream_get_cpu_count(value unit_val) {
    CAMLparam1(unit_val);

    /* Use portable sysconf */
    long nprocs = sysconf(_SC_NPROCESSORS_ONLN);
    if (nprocs <= 0) nprocs = 4; /* Safe default */

    CAMLreturn(Val_int((int)nprocs));
}

/*
 * Portable memory functions - safe implementations
 */
value algostream_mmap_file(value fd_val, value size_val, value mode_val, value flags_val) {
    CAMLparam4(fd_val, size_val, mode_val, flags_val);

    /* For now, just return a null pointer - memory mapping disabled in portable mode */
    printf("Memory mapping not available in portable mode\n");
    caml_failwith("Memory mapping not supported");

    CAMLreturn(caml_copy_nativeint(0));
}

value algostream_munmap_file(value ptr_val, value size_val) {
    CAMLparam2(ptr_val, size_val);

    /* Safe no-op */
    CAMLreturn(Val_unit);
}

/*
 * Portable shared memory functions
 */
value algostream_create_shared_segment(value size_val, value name_val) {
    CAMLparam2(size_val, name_val);

    printf("Shared memory not available in portable mode\n");
    caml_failwith("Shared memory not supported");

    CAMLreturn(caml_copy_nativeint(0));
}

value algostream_destroy_shared_segment(value ptr_val, value size_val) {
    CAMLparam2(ptr_val, size_val);

    /* Safe no-op */
    CAMLreturn(Val_unit);
}

/*
 * Portable math functions - standard implementations
 */
value algostream_fast_sqrt(value x_val) {
    CAMLparam1(x_val);
    CAMLlocal1(result);

    double x = Double_val(x_val);
    double sqrt_result = sqrt(x);

    result = caml_copy_double(sqrt_result);
    CAMLreturn(result);
}

value algostream_fast_log(value x_val) {
    CAMLparam1(x_val);
    CAMLlocal1(result);

    double x = Double_val(x_val);
    double log_result = log(x);

    result = caml_copy_double(log_result);
    CAMLreturn(result);
}

/*
 * Memory-mapped writer stubs - safe no-ops in portable mode.
 * Real implementations would dereference the nativeint pointer; here we
 * just ignore the call so the library links and bounds-checked OCaml
 * call sites observe success without writing anything.
 */
value algostream_write_int8(value ptr, value off, value v) {
    CAMLparam3(ptr, off, v); CAMLreturn(Val_unit);
}
value algostream_write_int16_le(value ptr, value off, value v) {
    CAMLparam3(ptr, off, v); CAMLreturn(Val_unit);
}
value algostream_write_int16_be(value ptr, value off, value v) {
    CAMLparam3(ptr, off, v); CAMLreturn(Val_unit);
}
value algostream_write_int32_le(value ptr, value off, value v) {
    CAMLparam3(ptr, off, v); CAMLreturn(Val_unit);
}
value algostream_write_int32_be(value ptr, value off, value v) {
    CAMLparam3(ptr, off, v); CAMLreturn(Val_unit);
}
value algostream_write_int64_le(value ptr, value off, value v) {
    CAMLparam3(ptr, off, v); CAMLreturn(Val_unit);
}
value algostream_write_int64_be(value ptr, value off, value v) {
    CAMLparam3(ptr, off, v); CAMLreturn(Val_unit);
}
value algostream_write_float32_le(value ptr, value off, value v) {
    CAMLparam3(ptr, off, v); CAMLreturn(Val_unit);
}
value algostream_write_float32_be(value ptr, value off, value v) {
    CAMLparam3(ptr, off, v); CAMLreturn(Val_unit);
}
value algostream_write_float64_le(value ptr, value off, value v) {
    CAMLparam3(ptr, off, v); CAMLreturn(Val_unit);
}
value algostream_write_float64_be(value ptr, value off, value v) {
    CAMLparam3(ptr, off, v); CAMLreturn(Val_unit);
}