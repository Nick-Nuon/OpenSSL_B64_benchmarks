
#ifndef __linux__
    #error "This program requires a Linux system to compile."
#endif

#define _GNU_SOURCE
#include <linux/perf_event.h>
#include <sys/syscall.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <time.h>
#include <errno.h>
#include <stdatomic.h>
#include <sys/stat.h>
#include <dirent.h>
#include <openssl/evp.h>

#define EVP_ENCODE_CTX_NO_NEWLINES          1
#define EVP_ENCODE_CTX_USE_SRP_ALPHABET     2

static const size_t min_repeats = 5;  
static const size_t min_time_ns = 1000000000ULL;  // 1 second
static const size_t max_repeats = 1000000;
static const size_t warmup_runs = 10000;
static const size_t max_files = 1024;

typedef struct {
    char *filename;
    unsigned char *content;
    size_t size;
    size_t encoded_size;
    unsigned char *encoded;
} FileData;

static long perf_event_open(struct perf_event_attr *hw_event, pid_t pid,
                            int cpu, int group_fd, unsigned long flags) {
    return syscall(__NR_perf_event_open, hw_event, pid, cpu, group_fd, flags);
}

double elapsed_seconds(struct timespec start, struct timespec end) {
    return (end.tv_sec - start.tv_sec) + (end.tv_nsec - start.tv_nsec) / 1e9;
}

uint64_t elapsed_nanoseconds(struct timespec start, struct timespec end) {
    return (end.tv_sec - start.tv_sec) * 1000000000ULL + (end.tv_nsec - start.tv_nsec);
}

int load_files_from_dir(const char *dirpath, FileData *files, size_t *file_count) {
    DIR *dir = opendir(dirpath);
    if (!dir) {
        perror("opendir");
        fprintf(stderr, "Failed on path: %s\n", dirpath);
        return 0;
    }

    struct dirent *entry;
    size_t count = 0;

    while ((entry = readdir(dir)) != NULL) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0)
            continue;

        if (count >= max_files) {
            fprintf(stderr, "Too many files in directory.\n");
            break;
        }

        char fullpath[4096];
        snprintf(fullpath, sizeof(fullpath), "%s/%s", dirpath, entry->d_name);

        struct stat st;
        if (stat(fullpath, &st) != 0 || !S_ISREG(st.st_mode)) {
            continue;
        }

        FILE *f = fopen(fullpath, "rb");
        if (!f) {
            perror("fopen");
            continue;
        }

        unsigned char *file_content = malloc(st.st_size);
        // --- NO_NL mode -- 
        size_t enc = 4 * ((st.st_size + 2) / 3);
        size_t encoded_total = enc * 10 + 64;  // very very generous headroom

        unsigned char *encoded_output = malloc(encoded_total);

        if (!file_content || !encoded_output) {
            printf("free once");
            perror("malloc");
            free(file_content);
            free(encoded_output);
            fclose(f);
            continue;
        }



        size_t read = fread(file_content, 1, st.st_size, f);
        fclose(f);

        // additional checks
        if (read != st.st_size) {
            fprintf(stderr, "Warning: incomplete read of %s\n", fullpath);
            free(file_content);
            free(encoded_output);
            continue;
        }

        files[count].filename = strdup(entry->d_name);
        files[count].content = file_content;
        files[count].size = st.st_size;
        files[count].encoded_size = encoded_total;
        files[count].encoded = encoded_output;
        count++;
    }

    closedir(dir);
    *file_count = count;
    return 1;
}



typedef int (*encode_update_fn)(EVP_ENCODE_CTX *ctx, unsigned char *out, int *outl,
                              const unsigned char *in, int inl);
typedef void (*encode_final_fn)(EVP_ENCODE_CTX *ctx, unsigned char *out, int *outl);

size_t base64_encode_custom(unsigned char *dst, size_t dstlen,
    const unsigned char *src, size_t srclen,
    encode_update_fn update_fn,
    encode_final_fn final_fn,
    int disable_newlines,
    int ctx_length,
    int use_srp) {
    EVP_ENCODE_CTX *ctx = EVP_ENCODE_CTX_new();
    if (!ctx) {
        fprintf(stderr, "Failed to allocate EVP_ENCODE_CTX\n");
        exit(1);
    }

    int outlen = 0;
    int taillen = 0;

    EVP_EncodeInit(ctx);
    if (disable_newlines) {
        evp_encode_ctx_set_flags(ctx, EVP_ENCODE_CTX_NO_NEWLINES);
    }
    if (use_srp) {
        evp_encode_ctx_set_flags(ctx, EVP_ENCODE_CTX_USE_SRP_ALPHABET);
    }
    ctx->length =  ctx_length;

    if (update_fn(ctx, dst, &outlen, src, (int)srclen) < 0) {
        fprintf(stderr, "Error: Custom base64 encoding failed.\n");
        EVP_ENCODE_CTX_free(ctx);
        exit(1);
    }
    final_fn(ctx, dst + outlen, &taillen);

    EVP_ENCODE_CTX_free(ctx);
    return (size_t)(outlen + taillen);
}

    typedef int (*encode_benchmark_fn)(EVP_ENCODE_CTX *ctx, unsigned char *out, int *outl,
                                  const unsigned char *in, int inl);
void run_benchmark(const char *name, int fd_cycles, FileData *files, size_t file_count,
                    encode_update_fn update_fn, encode_final_fn final_fn, int NO_NL, int ctx_length, int use_srp) {
    uint64_t total_cycles = 0, total_instructions = 0, total_elapsed_ns = 0;
    size_t N = min_repeats;
    if (N == 0) N = 1;

    // Calculate total bytes processed
    size_t total_bytes = 0;
    for (size_t f = 0; f < file_count; f++) {
        total_bytes += files[f].size;
    }

    for (size_t i = 0; i < N; i++) {
        struct timespec start_time, end_time;
        atomic_thread_fence(memory_order_acquire);
        clock_gettime(CLOCK_MONOTONIC, &start_time);

        ioctl(fd_cycles, PERF_EVENT_IOC_RESET, PERF_IOC_FLAG_GROUP);
        ioctl(fd_cycles, PERF_EVENT_IOC_ENABLE, PERF_IOC_FLAG_GROUP);

        for (size_t f = 0; f < file_count; f++) {
            base64_encode_custom(files[f].encoded,
                                files[f].encoded_size,
                                files[f].content,
                                files[f].size,
                                update_fn,
                                final_fn,
                                NO_NL,
                                ctx_length,
                                use_srp);
        }

        ioctl(fd_cycles, PERF_EVENT_IOC_DISABLE, PERF_IOC_FLAG_GROUP);
        atomic_thread_fence(memory_order_release);
        clock_gettime(CLOCK_MONOTONIC, &end_time);

        uint64_t values[3];
        if (read(fd_cycles, values, sizeof(values)) == -1) {
            perror("read (perf group)");
            return;
        }

        if (i >= warmup_runs) {
            total_cycles += values[1];
            total_instructions += values[2];
            total_elapsed_ns += elapsed_nanoseconds(start_time, end_time);
        }

        if ((i + 1 == N) && (total_elapsed_ns < min_time_ns) && (N < max_repeats)) {
            N *= 10;
        }
    }

    size_t effective_runs = N > warmup_runs ? (N - warmup_runs) : 1;
    double elapsed_sec = total_elapsed_ns / 1e9;
    double ipc = total_cycles > 0 ? ((double)total_instructions / total_cycles) : 0.0;
    double gb_per_sec = (total_bytes * effective_runs) / (elapsed_sec * 1e9);
    double instr_per_byte = total_bytes > 0 && effective_runs > 0 ? ((double)total_instructions / (total_bytes * effective_runs)) : 0.0;


    printf("\n\n ***** Benchmarking %s *****:\n", name);
    printf("Benchmark ran %zu iterations (%zu used after warmup)\n", N, effective_runs);
    printf("Total elapsed (wall):     %.6f s\n", elapsed_sec);
    printf("CPU cycles (avg):         %llu\n", (unsigned long long)(total_cycles / effective_runs));
    printf("Instructions (avg):       %llu\n", (unsigned long long)(total_instructions / effective_runs));
    printf("Instructions per cycle:   %.4f\n", ipc);
    printf("Instructions per byte:    %.4f\n", instr_per_byte);
    printf("Throughput:              %.2f GB/s\n", gb_per_sec);
}



int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <directory>\n", argv[0]);
        return 1;
    }

    const char *dirpath = argv[1];
    FileData files[max_files];
    size_t file_count = 0;

    if (!load_files_from_dir(dirpath, files, &file_count)) {
        fprintf(stderr, "Failed to load files.\n");
        return 1;
    }

    struct perf_event_attr pe_cycles;
    memset(&pe_cycles, 0, sizeof(pe_cycles));
    pe_cycles.type = PERF_TYPE_HARDWARE;
    pe_cycles.size = sizeof(pe_cycles);
    pe_cycles.config = PERF_COUNT_HW_CPU_CYCLES;
    pe_cycles.disabled = 1;
    pe_cycles.exclude_kernel = 1;
    pe_cycles.exclude_hv = 1;
    pe_cycles.read_format = PERF_FORMAT_GROUP;

    int fd_cycles = perf_event_open(&pe_cycles, 0, -1, -1, 0);
    if (fd_cycles == -1) {
        perror("perf_event_open (cycles)");
        printf("perf_event_open (cycles)");

        return 1;
    }

    struct perf_event_attr pe_instr = pe_cycles;
    pe_instr.config = PERF_COUNT_HW_INSTRUCTIONS;
    int fd_instr = perf_event_open(&pe_instr, 0, -1, fd_cycles, 0);
    if (fd_instr == -1) {
        perror("perf_event_open (instructions)");
        printf("perf_event_open (instructions)");
        return 1;
    }

    for (int use_srp = 0; use_srp <= 1; ++use_srp) {
        const char *alpha = use_srp ? "SRP" : "STD";

        printf("\n======================= Alphabet: %s =======================\n", alpha);
        printf ("-----------------------DISABLE NEWLINES/NO_NL mode---------------------------");
        run_benchmark("EVP_EncodeUpdate", fd_cycles, files, file_count, 
                    EVP_EncodeUpdate, EVP_EncodeFinal, 1,48, use_srp);

        // A newline is inserted after every 47 bytes. 
        printf ("-----------------------PEM mode---------------------------");
        run_benchmark("EVP_EncodeUpdate", fd_cycles, files, file_count, 
                    EVP_EncodeUpdate, EVP_EncodeFinal, 0,48,use_srp);

        for (int ctx_len = 33; ctx_len <= 80; ctx_len += 3) {
            printf ("-----------------------Custom ctx->lengths mode: %d---------------------------", ctx_len);
            run_benchmark("EVP_EncodeUpdate", fd_cycles, files, file_count, 
                        EVP_EncodeUpdate, EVP_EncodeFinal, 0,ctx_len, use_srp);
        }
    }


        printf("\n\nProcessed files:\n");

        for (size_t i = 0; i < file_count; i++) {
            printf("File: %s (%zu bytes)\n", files[i].filename, files[i].size);
            if (files[i].content) free(files[i].content);
            if (files[i].filename) free(files[i].filename);
            if (files[i].encoded) free(files[i].encoded);
        }

    close(fd_instr);
    close(fd_cycles);
    return 0;
}
