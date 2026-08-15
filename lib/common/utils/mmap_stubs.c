/*
 * Memory-mapped file C stubs for AlgoStream
 * Provides high-performance memory mapping operations
 */

#include <caml/mlvalues.h>
#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/fail.h>
#include <caml/unixsupport.h>

#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <stdint.h>

/*
 * Memory map a file
 * Parameters: file_descriptor, size, mode, flags
 * Returns: pointer to mapped memory
 */
value algostream_mmap_file(value fd_val, value size_val, value mode_val, value flags_val) {
    CAMLparam4(fd_val, size_val, mode_val, flags_val);

    int fd = Int_val(fd_val);
    size_t size = Long_val(size_val);
    int mode = Int_val(mode_val);
    int flags = Int_val(flags_val);

    int prot = 0;
    int map_flags = 0;

    /* Set protection flags based on mode */
    switch (mode) {
        case 0: /* Read_only */
            prot = PROT_READ;
            break;
        case 1: /* Read_write */
            prot = PROT_READ | PROT_WRITE;
            break;
        case 2: /* Write_only */
            prot = PROT_WRITE;
            break;
        default:
            caml_failwith("Invalid mmap mode");
    }

    /* Set mapping flags */
    if (flags & 1) {
        map_flags |= MAP_SHARED;
    } else {
        map_flags |= MAP_PRIVATE;
    }

#ifdef MAP_POPULATE
    if (flags & 2) {
        map_flags |= MAP_POPULATE;
    }
#endif

#ifdef MAP_HUGETLB
    if (flags & 8) {
        map_flags |= MAP_HUGETLB;
    }
#endif

    void *ptr = mmap(NULL, size, prot, map_flags, fd, 0);
    if (ptr == MAP_FAILED) {
        uerror("mmap", Nothing);
    }

    /* Lock pages in memory if requested */
    if (flags & 4) {
        if (mlock(ptr, size) != 0) {
            /* Don't fail if mlock fails, just continue */
        }
    }

    CAMLreturn(caml_copy_nativeint((intnat)ptr));
}

/*
 * Unmap memory
 */
value algostream_munmap_file(value ptr_val, value size_val) {
    CAMLparam2(ptr_val, size_val);

    void *ptr = (void*)Nativeint_val(ptr_val);
    size_t size = Long_val(size_val);

    if (munmap(ptr, size) != 0) {
        uerror("munmap", Nothing);
    }

    CAMLreturn(Val_unit);
}

/*
 * Synchronize memory range to disk
 */
value algostream_msync_range(value ptr_val, value offset_val, value length_val) {
    CAMLparam3(ptr_val, offset_val, length_val);

    void *ptr = (void*)Nativeint_val(ptr_val);
    size_t offset = Long_val(offset_val);
    size_t length = Long_val(length_val);

    if (msync((char*)ptr + offset, length, MS_SYNC) != 0) {
        uerror("msync", Nothing);
    }

    CAMLreturn(Val_unit);
}

/*
 * Memory advice functions
 */
value algostream_madvise_sequential(value ptr_val, value size_val) {
    CAMLparam2(ptr_val, size_val);

    void *ptr = (void*)Nativeint_val(ptr_val);
    size_t size = Long_val(size_val);

#ifdef MADV_SEQUENTIAL
    madvise(ptr, size, MADV_SEQUENTIAL);
#endif

    CAMLreturn(Val_unit);
}

value algostream_madvise_random(value ptr_val, value size_val) {
    CAMLparam2(ptr_val, size_val);

    void *ptr = (void*)Nativeint_val(ptr_val);
    size_t size = Long_val(size_val);

#ifdef MADV_RANDOM
    madvise(ptr, size, MADV_RANDOM);
#endif

    CAMLreturn(Val_unit);
}

value algostream_madvise_willneed(value ptr_val, value size_val) {
    CAMLparam2(ptr_val, size_val);

    void *ptr = (void*)Nativeint_val(ptr_val);
    size_t size = Long_val(size_val);

#ifdef MADV_WILLNEED
    madvise(ptr, size, MADV_WILLNEED);
#endif

    CAMLreturn(Val_unit);
}

/*
 * Memory locking functions
 */
value algostream_mlock_range(value ptr_val, value size_val) {
    CAMLparam2(ptr_val, size_val);

    void *ptr = (void*)Nativeint_val(ptr_val);
    size_t size = Long_val(size_val);

    mlock(ptr, size); /* Ignore errors */

    CAMLreturn(Val_unit);
}

value algostream_munlock_range(value ptr_val, value size_val) {
    CAMLparam2(ptr_val, size_val);

    void *ptr = (void*)Nativeint_val(ptr_val);
    size_t size = Long_val(size_val);

    munlock(ptr, size); /* Ignore errors */

    CAMLreturn(Val_unit);
}

/*
 * Read functions for different data types
 */
value algostream_read_int8(value ptr_val, value offset_val) {
    CAMLparam2(ptr_val, offset_val);

    char *ptr = (char*)Nativeint_val(ptr_val);
    size_t offset = Long_val(offset_val);

    uint8_t value = *(uint8_t*)(ptr + offset);

    CAMLreturn(Val_int(value));
}

value algostream_read_int16_le(value ptr_val, value offset_val) {
    CAMLparam2(ptr_val, offset_val);

    char *ptr = (char*)Nativeint_val(ptr_val);
    size_t offset = Long_val(offset_val);

    uint16_t value;
    memcpy(&value, ptr + offset, sizeof(uint16_t));

    /* Convert from little endian if necessary */
#if __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
    value = __builtin_bswap16(value);
#endif

    CAMLreturn(Val_int(value));
}

value algostream_read_int16_be(value ptr_val, value offset_val) {
    CAMLparam2(ptr_val, offset_val);

    char *ptr = (char*)Nativeint_val(ptr_val);
    size_t offset = Long_val(offset_val);

    uint16_t value;
    memcpy(&value, ptr + offset, sizeof(uint16_t));

    /* Convert from big endian if necessary */
#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
    value = __builtin_bswap16(value);
#endif

    CAMLreturn(Val_int(value));
}

value algostream_read_int32_le(value ptr_val, value offset_val) {
    CAMLparam2(ptr_val, offset_val);

    char *ptr = (char*)Nativeint_val(ptr_val);
    size_t offset = Long_val(offset_val);

    uint32_t value;
    memcpy(&value, ptr + offset, sizeof(uint32_t));

#if __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
    value = __builtin_bswap32(value);
#endif

    CAMLreturn(caml_copy_int32(value));
}

value algostream_read_int32_be(value ptr_val, value offset_val) {
    CAMLparam2(ptr_val, offset_val);

    char *ptr = (char*)Nativeint_val(ptr_val);
    size_t offset = Long_val(offset_val);

    uint32_t value;
    memcpy(&value, ptr + offset, sizeof(uint32_t));

#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
    value = __builtin_bswap32(value);
#endif

    CAMLreturn(caml_copy_int32(value));
}

value algostream_read_int64_le(value ptr_val, value offset_val) {
    CAMLparam2(ptr_val, offset_val);

    char *ptr = (char*)Nativeint_val(ptr_val);
    size_t offset = Long_val(offset_val);

    uint64_t value;
    memcpy(&value, ptr + offset, sizeof(uint64_t));

#if __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
    value = __builtin_bswap64(value);
#endif

    CAMLreturn(caml_copy_int64(value));
}

value algostream_read_int64_be(value ptr_val, value offset_val) {
    CAMLparam2(ptr_val, offset_val);

    char *ptr = (char*)Nativeint_val(ptr_val);
    size_t offset = Long_val(offset_val);

    uint64_t value;
    memcpy(&value, ptr + offset, sizeof(uint64_t));

#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
    value = __builtin_bswap64(value);
#endif

    CAMLreturn(caml_copy_int64(value));
}

value algostream_read_float32_le(value ptr_val, value offset_val) {
    CAMLparam2(ptr_val, offset_val);

    char *ptr = (char*)Nativeint_val(ptr_val);
    size_t offset = Long_val(offset_val);

    uint32_t raw_value;
    memcpy(&raw_value, ptr + offset, sizeof(uint32_t));

#if __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
    raw_value = __builtin_bswap32(raw_value);
#endif

    float value;
    memcpy(&value, &raw_value, sizeof(float));

    CAMLreturn(caml_copy_double((double)value));
}

value algostream_read_float32_be(value ptr_val, value offset_val) {
    CAMLparam2(ptr_val, offset_val);

    char *ptr = (char*)Nativeint_val(ptr_val);
    size_t offset = Long_val(offset_val);

    uint32_t raw_value;
    memcpy(&raw_value, ptr + offset, sizeof(uint32_t));

#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
    raw_value = __builtin_bswap32(raw_value);
#endif

    float value;
    memcpy(&value, &raw_value, sizeof(float));

    CAMLreturn(caml_copy_double((double)value));
}

value algostream_read_float64_le(value ptr_val, value offset_val) {
    CAMLparam2(ptr_val, offset_val);

    char *ptr = (char*)Nativeint_val(ptr_val);
    size_t offset = Long_val(offset_val);

    uint64_t raw_value;
    memcpy(&raw_value, ptr + offset, sizeof(uint64_t));

#if __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
    raw_value = __builtin_bswap64(raw_value);
#endif

    double value;
    memcpy(&value, &raw_value, sizeof(double));

    CAMLreturn(caml_copy_double(value));
}

value algostream_read_float64_be(value ptr_val, value offset_val) {
    CAMLparam2(ptr_val, offset_val);

    char *ptr = (char*)Nativeint_val(ptr_val);
    size_t offset = Long_val(offset_val);

    uint64_t raw_value;
    memcpy(&raw_value, ptr + offset, sizeof(uint64_t));

#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
    raw_value = __builtin_bswap64(raw_value);
#endif

    double value;
    memcpy(&value, &raw_value, sizeof(double));

    CAMLreturn(caml_copy_double(value));
}

/*
 * Write functions for different data types
 */
value algostream_write_int8(value ptr_val, value offset_val, value value_val) {
    CAMLparam3(ptr_val, offset_val, value_val);

    char *ptr = (char*)Nativeint_val(ptr_val);
    size_t offset = Long_val(offset_val);
    uint8_t value = Int_val(value_val);

    *(uint8_t*)(ptr + offset) = value;

    CAMLreturn(Val_unit);
}

value algostream_write_int16_le(value ptr_val, value offset_val, value value_val) {
    CAMLparam3(ptr_val, offset_val, value_val);

    char *ptr = (char*)Nativeint_val(ptr_val);
    size_t offset = Long_val(offset_val);
    uint16_t value = Int_val(value_val);

#if __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
    value = __builtin_bswap16(value);
#endif

    memcpy(ptr + offset, &value, sizeof(uint16_t));

    CAMLreturn(Val_unit);
}

value algostream_write_int16_be(value ptr_val, value offset_val, value value_val) {
    CAMLparam3(ptr_val, offset_val, value_val);

    char *ptr = (char*)Nativeint_val(ptr_val);
    size_t offset = Long_val(offset_val);
    uint16_t value = Int_val(value_val);

#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
    value = __builtin_bswap16(value);
#endif

    memcpy(ptr + offset, &value, sizeof(uint16_t));

    CAMLreturn(Val_unit);
}

value algostream_write_int32_le(value ptr_val, value offset_val, value value_val) {
    CAMLparam3(ptr_val, offset_val, value_val);

    char *ptr = (char*)Nativeint_val(ptr_val);
    size_t offset = Long_val(offset_val);
    uint32_t value = Int32_val(value_val);

#if __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
    value = __builtin_bswap32(value);
#endif

    memcpy(ptr + offset, &value, sizeof(uint32_t));

    CAMLreturn(Val_unit);
}

value algostream_write_int32_be(value ptr_val, value offset_val, value value_val) {
    CAMLparam3(ptr_val, offset_val, value_val);

    char *ptr = (char*)Nativeint_val(ptr_val);
    size_t offset = Long_val(offset_val);
    uint32_t value = Int32_val(value_val);

#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
    value = __builtin_bswap32(value);
#endif

    memcpy(ptr + offset, &value, sizeof(uint32_t));

    CAMLreturn(Val_unit);
}

value algostream_write_int64_le(value ptr_val, value offset_val, value value_val) {
    CAMLparam3(ptr_val, offset_val, value_val);

    char *ptr = (char*)Nativeint_val(ptr_val);
    size_t offset = Long_val(offset_val);
    uint64_t value = Int64_val(value_val);

#if __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
    value = __builtin_bswap64(value);
#endif

    memcpy(ptr + offset, &value, sizeof(uint64_t));

    CAMLreturn(Val_unit);
}

value algostream_write_int64_be(value ptr_val, value offset_val, value value_val) {
    CAMLparam3(ptr_val, offset_val, value_val);

    char *ptr = (char*)Nativeint_val(ptr_val);
    size_t offset = Long_val(offset_val);
    uint64_t value = Int64_val(value_val);

#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
    value = __builtin_bswap64(value);
#endif

    memcpy(ptr + offset, &value, sizeof(uint64_t));

    CAMLreturn(Val_unit);
}

value algostream_write_float32_le(value ptr_val, value offset_val, value value_val) {
    CAMLparam3(ptr_val, offset_val, value_val);

    char *ptr = (char*)Nativeint_val(ptr_val);
    size_t offset = Long_val(offset_val);
    float value = (float)Double_val(value_val);

    uint32_t raw_value;
    memcpy(&raw_value, &value, sizeof(float));

#if __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
    raw_value = __builtin_bswap32(raw_value);
#endif

    memcpy(ptr + offset, &raw_value, sizeof(uint32_t));

    CAMLreturn(Val_unit);
}

value algostream_write_float32_be(value ptr_val, value offset_val, value value_val) {
    CAMLparam3(ptr_val, offset_val, value_val);

    char *ptr = (char*)Nativeint_val(ptr_val);
    size_t offset = Long_val(offset_val);
    float value = (float)Double_val(value_val);

    uint32_t raw_value;
    memcpy(&raw_value, &value, sizeof(float));

#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
    raw_value = __builtin_bswap32(raw_value);
#endif

    memcpy(ptr + offset, &raw_value, sizeof(uint32_t));

    CAMLreturn(Val_unit);
}

value algostream_write_float64_le(value ptr_val, value offset_val, value value_val) {
    CAMLparam3(ptr_val, offset_val, value_val);

    char *ptr = (char*)Nativeint_val(ptr_val);
    size_t offset = Long_val(offset_val);
    double value = Double_val(value_val);

    uint64_t raw_value;
    memcpy(&raw_value, &value, sizeof(double));

#if __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
    raw_value = __builtin_bswap64(raw_value);
#endif

    memcpy(ptr + offset, &raw_value, sizeof(uint64_t));

    CAMLreturn(Val_unit);
}

value algostream_write_float64_be(value ptr_val, value offset_val, value value_val) {
    CAMLparam3(ptr_val, offset_val, value_val);

    char *ptr = (char*)Nativeint_val(ptr_val);
    size_t offset = Long_val(offset_val);
    double value = Double_val(value_val);

    uint64_t raw_value;
    memcpy(&raw_value, &value, sizeof(double));

#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
    raw_value = __builtin_bswap64(raw_value);
#endif

    memcpy(ptr + offset, &raw_value, sizeof(uint64_t));

    CAMLreturn(Val_unit);
}