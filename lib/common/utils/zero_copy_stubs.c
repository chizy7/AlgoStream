/*
 * Zero-copy message passing C stubs for AlgoStream
 * Provides shared memory and fast memory operations
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
#include <zlib.h>

/*
 * Create or open a shared memory segment
 */
value algostream_create_shared_memory(value name_val, value size_val, value create_val) {
    CAMLparam3(name_val, size_val, create_val);

    const char *name = String_val(name_val);
    size_t size = Long_val(size_val);
    int create_new = Int_val(create_val);

    int flags = O_RDWR;
    if (create_new) {
        flags |= O_CREAT | O_EXCL;
    }

    int fd = shm_open(name, flags, 0644);
    if (fd == -1) {
        if (errno == EEXIST && create_new) {
            /* Segment already exists, try to open it */
            fd = shm_open(name, O_RDWR, 0644);
        }
        if (fd == -1) {
            uerror("shm_open", caml_copy_string(name));
        }
    }

    if (create_new) {
        /* Set the size of the shared memory object */
        if (ftruncate(fd, size) == -1) {
            close(fd);
            shm_unlink(name);
            uerror("ftruncate", caml_copy_string(name));
        }
    }

    /* Map the shared memory */
    void *ptr = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd); /* File descriptor no longer needed */

    if (ptr == MAP_FAILED) {
        if (create_new) {
            shm_unlink(name);
        }
        uerror("mmap", caml_copy_string(name));
    }

    /* Initialize memory to zero if we created it */
    if (create_new) {
        memset(ptr, 0, size);
    }

    CAMLreturn(caml_copy_nativeint((intnat)ptr));
}

/*
 * Attach to an existing shared memory segment
 */
value algostream_attach_shared_memory(value name_val, value size_val) {
    CAMLparam2(name_val, size_val);

    const char *name = String_val(name_val);
    size_t size = Long_val(size_val);

    int fd = shm_open(name, O_RDWR, 0644);
    if (fd == -1) {
        uerror("shm_open", caml_copy_string(name));
    }

    void *ptr = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);

    if (ptr == MAP_FAILED) {
        uerror("mmap", caml_copy_string(name));
    }

    CAMLreturn(caml_copy_nativeint((intnat)ptr));
}

/*
 * Detach from shared memory
 */
value algostream_detach_shared_memory(value ptr_val, value size_val) {
    CAMLparam2(ptr_val, size_val);

    void *ptr = (void*)Nativeint_val(ptr_val);
    size_t size = Long_val(size_val);

    if (munmap(ptr, size) == -1) {
        uerror("munmap", Nothing);
    }

    CAMLreturn(Val_unit);
}

/*
 * Destroy shared memory segment
 */
value algostream_destroy_shared_memory(value name_val) {
    CAMLparam1(name_val);

    const char *name = String_val(name_val);

    if (shm_unlink(name) == -1 && errno != ENOENT) {
        uerror("shm_unlink", caml_copy_string(name));
    }

    CAMLreturn(Val_unit);
}

/*
 * Write message header with atomic operations
 */
value algostream_write_message_header(value ptr_val, value offset_val,
                                    value magic_val, value msg_type_val,
                                    value seq_id_val, value timestamp_val,
                                    value payload_size_val, value checksum_val) {
    CAMLparam5(ptr_val, offset_val, magic_val, msg_type_val, seq_id_val);
    CAMLxparam3(timestamp_val, payload_size_val, checksum_val);

    char *ptr = (char*)Nativeint_val(ptr_val);
    size_t offset = Long_val(offset_val);
    uint32_t magic = Int32_val(magic_val);
    uint32_t msg_type = Int32_val(msg_type_val);
    uint64_t seq_id = Int64_val(seq_id_val);
    uint64_t timestamp = Int64_val(timestamp_val);
    uint32_t payload_size = Int32_val(payload_size_val);
    uint32_t checksum = Int32_val(checksum_val);

    /* Write header fields in order */
    memcpy(ptr + offset, &magic, sizeof(uint32_t));
    memcpy(ptr + offset + 4, &msg_type, sizeof(uint32_t));
    memcpy(ptr + offset + 8, &seq_id, sizeof(uint64_t));
    memcpy(ptr + offset + 16, &timestamp, sizeof(uint64_t));
    memcpy(ptr + offset + 24, &payload_size, sizeof(uint32_t));
    memcpy(ptr + offset + 28, &checksum, sizeof(uint32_t));

    /* Memory barrier to ensure write completion */
    __sync_synchronize();

    CAMLreturn(Val_unit);
}

value algostream_write_message_header_bytecode(value *argv, int argn) {
    return algostream_write_message_header(argv[0], argv[1], argv[2], argv[3],
                                         argv[4], argv[5], argv[6], argv[7]);
}

/*
 * Read message header atomically
 */
value algostream_read_message_header(value ptr_val, value offset_val) {
    CAMLparam2(ptr_val, offset_val);
    CAMLlocal1(result);

    char *ptr = (char*)Nativeint_val(ptr_val);
    size_t offset = Long_val(offset_val);

    uint32_t magic, msg_type, payload_size, checksum;
    uint64_t seq_id, timestamp;

    /* Read header fields */
    memcpy(&magic, ptr + offset, sizeof(uint32_t));
    memcpy(&msg_type, ptr + offset + 4, sizeof(uint32_t));
    memcpy(&seq_id, ptr + offset + 8, sizeof(uint64_t));
    memcpy(&timestamp, ptr + offset + 16, sizeof(uint64_t));
    memcpy(&payload_size, ptr + offset + 24, sizeof(uint32_t));
    memcpy(&checksum, ptr + offset + 28, sizeof(uint32_t));

    /* Create OCaml tuple */
    result = caml_alloc_tuple(6);
    Store_field(result, 0, caml_copy_int32(magic));
    Store_field(result, 1, caml_copy_int32(msg_type));
    Store_field(result, 2, caml_copy_int64(seq_id));
    Store_field(result, 3, caml_copy_int64(timestamp));
    Store_field(result, 4, caml_copy_int32(payload_size));
    Store_field(result, 5, caml_copy_int32(checksum));

    CAMLreturn(result);
}

/*
 * Calculate CRC32 checksum for data integrity
 */
value algostream_calculate_crc32(value ptr_val, value offset_val, value length_val) {
    CAMLparam3(ptr_val, offset_val, length_val);

    char *ptr = (char*)Nativeint_val(ptr_val);
    size_t offset = Long_val(offset_val);
    size_t length = Long_val(length_val);

    uint32_t crc = crc32(0L, Z_NULL, 0);
    crc = crc32(crc, (const Bytef*)(ptr + offset), length);

    CAMLreturn(caml_copy_int32(crc));
}

/*
 * Fast memory copy optimized for message passing
 */
value algostream_memory_copy_fast(value src_ptr_val, value src_offset_val,
                                 value dst_ptr_val, value dst_offset_val,
                                 value length_val) {
    CAMLparam5(src_ptr_val, src_offset_val, dst_ptr_val, dst_offset_val, length_val);

    char *src_ptr = (char*)Nativeint_val(src_ptr_val);
    size_t src_offset = Long_val(src_offset_val);
    char *dst_ptr = (char*)Nativeint_val(dst_ptr_val);
    size_t dst_offset = Long_val(dst_offset_val);
    size_t length = Long_val(length_val);

    /* Use optimized memory copy */
    memcpy(dst_ptr + dst_offset, src_ptr + src_offset, length);

    CAMLreturn(Val_unit);
}

/*
 * Memory prefetch hint for cache optimization
 */
value algostream_prefetch_memory(value ptr_val, value offset_val, value length_val) {
    CAMLparam3(ptr_val, offset_val, length_val);

    char *ptr = (char*)Nativeint_val(ptr_val);
    size_t offset = Long_val(offset_val);
    size_t length = Long_val(length_val);

    /* Prefetch memory into cache */
#ifdef __GNUC__
    char *addr = ptr + offset;
    for (size_t i = 0; i < length; i += 64) { /* Assume 64-byte cache lines */
        __builtin_prefetch(addr + i, 0, 3); /* Read, high temporal locality */
    }
#endif

    CAMLreturn(Val_unit);
}

/*
 * Non-temporal memory copy to avoid cache pollution
 */
value algostream_memory_copy_nt(value src_ptr_val, value src_offset_val,
                               value dst_ptr_val, value dst_offset_val,
                               value length_val) {
    CAMLparam5(src_ptr_val, src_offset_val, dst_ptr_val, dst_offset_val, length_val);

    char *src_ptr = (char*)Nativeint_val(src_ptr_val);
    size_t src_offset = Long_val(src_offset_val);
    char *dst_ptr = (char*)Nativeint_val(dst_ptr_val);
    size_t dst_offset = Long_val(dst_offset_val);
    size_t length = Long_val(length_val);

    /* For large copies, use non-temporal stores to avoid cache pollution */
    if (length > 1024) {
#if defined(__x86_64__) && defined(__SSE2__)
        /* Use streaming stores for large copies */
        char *src = src_ptr + src_offset;
        char *dst = dst_ptr + dst_offset;
        size_t simd_length = length & ~15; /* Align to 16 bytes */

        for (size_t i = 0; i < simd_length; i += 16) {
            __m128i data = _mm_load_si128((__m128i*)(src + i));
            _mm_stream_si128((__m128i*)(dst + i), data);
        }

        /* Copy remaining bytes */
        if (length > simd_length) {
            memcpy(dst + simd_length, src + simd_length, length - simd_length);
        }

        /* Ensure all stores complete */
        _mm_sfence();
#else
        memcpy(dst_ptr + dst_offset, src_ptr + src_offset, length);
#endif
    } else {
        memcpy(dst_ptr + dst_offset, src_ptr + src_offset, length);
    }

    CAMLreturn(Val_unit);
}