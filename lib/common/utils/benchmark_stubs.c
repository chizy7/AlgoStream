/*
 * Benchmarking and optimization C stubs for AlgoStream
 * Provides CPU affinity and system optimization functions
 */

#include <caml/mlvalues.h>
#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/fail.h>
#include <caml/unixsupport.h>

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>

#ifdef __linux__
#include <sched.h>
#include <sys/mman.h>
#include <sys/sysinfo.h>
#endif

#ifdef __MACH__
#include <mach/mach.h>
#include <mach/thread_policy.h>
#include <sys/sysctl.h>
#endif

/*
 * Set CPU affinity to bind process to specific core
 */
value algostream_set_cpu_affinity(value cpu_id_val) {
    CAMLparam1(cpu_id_val);

    int cpu_id = Int_val(cpu_id_val);

#ifdef __linux__
    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    CPU_SET(cpu_id, &cpuset);

    if (sched_setaffinity(0, sizeof(cpu_set_t), &cpuset) != 0) {
        uerror("sched_setaffinity", Nothing);
    }

#elif defined(__MACH__)
    /* macOS implementation using thread affinity */
    thread_affinity_policy_data_t policy;
    policy.affinity_tag = cpu_id;

    kern_return_t result = thread_policy_set(
        mach_thread_self(),
        THREAD_AFFINITY_POLICY,
        (thread_policy_t)&policy,
        THREAD_AFFINITY_POLICY_COUNT
    );

    if (result != KERN_SUCCESS) {
        caml_failwith("Failed to set thread affinity on macOS");
    }

#else
    /* Unsupported platform */
    caml_failwith("CPU affinity not supported on this platform");
#endif

    CAMLreturn(Val_unit);
}

/*
 * Get the number of CPU cores
 */
value algostream_get_cpu_count(value unit) {
    CAMLparam1(unit);

    int cpu_count = 0;

#ifdef __linux__
    cpu_count = get_nprocs();

#elif defined(__MACH__)
    size_t size = sizeof(cpu_count);
    if (sysctlbyname("hw.ncpu", &cpu_count, &size, NULL, 0) != 0) {
        cpu_count = 1; /* Fallback */
    }

#else
    cpu_count = sysconf(_SC_NPROCESSORS_ONLN);
    if (cpu_count <= 0) {
        cpu_count = 1; /* Fallback */
    }
#endif

    CAMLreturn(Val_int(cpu_count));
}

/*
 * Disable CPU turbo boost for consistent performance
 */
value algostream_disable_turbo_boost(value unit) {
    CAMLparam1(unit);

#ifdef __linux__
    /* Try to disable Intel turbo boost */
    FILE *turbo_file = fopen("/sys/devices/system/cpu/intel_pstate/no_turbo", "w");
    if (turbo_file) {
        fprintf(turbo_file, "1");
        fclose(turbo_file);
    } else {
        /* Try alternative path for older kernels */
        FILE *boost_file = fopen("/sys/devices/system/cpu/cpufreq/boost", "w");
        if (boost_file) {
            fprintf(boost_file, "0");
            fclose(boost_file);
        }
    }

#else
    /* Not implemented for other platforms */
    caml_failwith("Turbo boost control not supported on this platform");
#endif

    CAMLreturn(Val_unit);
}

/*
 * Set CPU frequency governor
 */
value algostream_set_cpu_governor(value governor_val) {
    CAMLparam1(governor_val);

    const char *governor = String_val(governor_val);

#ifdef __linux__
    /* Try to set governor for all CPUs */
    char path[256];
    int cpu_count = get_nprocs();

    for (int cpu = 0; cpu < cpu_count; cpu++) {
        snprintf(path, sizeof(path),
                "/sys/devices/system/cpu/cpu%d/cpufreq/scaling_governor", cpu);

        FILE *gov_file = fopen(path, "w");
        if (gov_file) {
            fprintf(gov_file, "%s", governor);
            fclose(gov_file);
        }
    }

#else
    /* Not implemented for other platforms */
    caml_failwith("CPU governor control not supported on this platform");
#endif

    CAMLreturn(Val_unit);
}

/*
 * Lock memory pages to prevent paging
 */
value algostream_lock_memory(value ptr_val, value size_val) {
    CAMLparam2(ptr_val, size_val);

    void *ptr = (void*)Nativeint_val(ptr_val);
    size_t size = Long_val(size_val);

    if (mlock(ptr, size) != 0) {
        /* Don't fail, just log warning */
        /* In production, you might want to handle this differently */
    }

    CAMLreturn(Val_unit);
}

/*
 * Unlock memory pages
 */
value algostream_unlock_memory(value ptr_val, value size_val) {
    CAMLparam2(ptr_val, size_val);

    void *ptr = (void*)Nativeint_val(ptr_val);
    size_t size = Long_val(size_val);

    if (munlock(ptr, size) != 0) {
        /* Don't fail, just continue */
    }

    CAMLreturn(Val_unit);
}

/*
 * Allocate memory using huge pages for better performance
 */
value algostream_huge_page_alloc(value size_val) {
    CAMLparam1(size_val);

    size_t size = Long_val(size_val);
    void *ptr = NULL;

#ifdef __linux__
    /* Try to allocate using huge pages */
    ptr = mmap(NULL, size, PROT_READ | PROT_WRITE,
               MAP_PRIVATE | MAP_ANONYMOUS | MAP_HUGETLB, -1, 0);

    if (ptr == MAP_FAILED) {
        /* Fallback to regular allocation */
        ptr = mmap(NULL, size, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);

        if (ptr == MAP_FAILED) {
            uerror("mmap", Nothing);
        }
    }

#else
    /* Regular allocation for other platforms */
    ptr = mmap(NULL, size, PROT_READ | PROT_WRITE,
               MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);

    if (ptr == MAP_FAILED) {
        uerror("mmap", Nothing);
    }
#endif

    CAMLreturn(caml_copy_nativeint((intnat)ptr));
}

/*
 * Free huge page allocation
 */
value algostream_huge_page_free(value ptr_val, value size_val) {
    CAMLparam2(ptr_val, size_val);

    void *ptr = (void*)Nativeint_val(ptr_val);
    size_t size = Long_val(size_val);

    if (munmap(ptr, size) != 0) {
        uerror("munmap", Nothing);
    }

    CAMLreturn(Val_unit);
}

/*
 * Prefault memory pages to ensure they are mapped
 */
value algostream_prefault_memory(value ptr_val, value size_val) {
    CAMLparam2(ptr_val, size_val);

    char *ptr = (char*)Nativeint_val(ptr_val);
    size_t size = Long_val(size_val);

    /* Touch every page to ensure it's mapped */
    size_t page_size = getpagesize();
    volatile char dummy;

    for (size_t offset = 0; offset < size; offset += page_size) {
        size_t access_offset = (offset + page_size - 1 < size) ? offset : size - 1;
        dummy = ptr[access_offset];
        ptr[access_offset] = dummy; /* Write back to ensure page is writable */
    }

    CAMLreturn(Val_unit);
}

/*
 * Get current CPU frequency (for performance monitoring)
 */
value algostream_get_cpu_frequency(value unit) {
    CAMLparam1(unit);

    double frequency = 0.0;

#ifdef __linux__
    FILE *freq_file = fopen("/proc/cpuinfo", "r");
    if (freq_file) {
        char line[256];
        while (fgets(line, sizeof(line), freq_file)) {
            if (strncmp(line, "cpu MHz", 7) == 0) {
                char *colon = strchr(line, ':');
                if (colon) {
                    frequency = strtod(colon + 1, NULL);
                    break;
                }
            }
        }
        fclose(freq_file);
    }

#elif defined(__MACH__)
    size_t size = sizeof(uint64_t);
    uint64_t freq_hz;
    if (sysctlbyname("hw.cpufrequency", &freq_hz, &size, NULL, 0) == 0) {
        frequency = (double)freq_hz / 1000000.0; /* Convert to MHz */
    }

#endif

    CAMLreturn(caml_copy_double(frequency));
}

/*
 * Set process priority for real-time scheduling
 */
value algostream_set_realtime_priority(value priority_val) {
    CAMLparam1(priority_val);

    int priority = Int_val(priority_val);

#ifdef __linux__
    struct sched_param param;
    param.sched_priority = priority;

    if (sched_setscheduler(0, SCHED_FIFO, &param) != 0) {
        /* Don't fail if we can't set real-time priority */
        /* This typically requires root privileges */
    }

#elif defined(__MACH__)
    /* macOS real-time priority setting */
    struct sched_param param;
    param.sched_priority = priority;

    if (pthread_setschedparam(pthread_self(), SCHED_FIFO, &param) != 0) {
        /* Don't fail, just continue */
    }

#endif

    CAMLreturn(Val_unit);
}

/*
 * Disable address space layout randomization for consistent performance
 */
value algostream_disable_aslr(value unit) {
    CAMLparam1(unit);

#ifdef __linux__
    /* This typically requires system-level configuration */
    /* We can only suggest or attempt to set it */
    FILE *aslr_file = fopen("/proc/sys/kernel/randomize_va_space", "w");
    if (aslr_file) {
        fprintf(aslr_file, "0");
        fclose(aslr_file);
    }

#endif

    CAMLreturn(Val_unit);
}