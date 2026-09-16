/*
 * Definitions for examples/leaks/malloc_counter.h. Compile this file on its
 * own, never with that header `-include`d, so the calls below reach the real
 * allocator. At exit it prints one line to stderr:
 *
 *     MALLOC_COUNTER ALLOC=<n> FREE=<n> LIVE=<n>
 *
 * LIVE is the number of blocks obtained and never released, which is what a
 * leak IS; tools/check.sh parses it and requires it to equal the `leaks`
 * reading for the same binary. A realloc of a null pointer is an allocation;
 * any other realloc keeps LIVE unchanged. free(NULL) is not counted because it
 * releases nothing.
 *
 * Printed from an atexit handler registered by a constructor, so it runs
 * whether the program returns from main or calls exit. It writes to stderr
 * because `leaks` reads the program's stdout as its own report channel.
 */

#include <stdio.h>
#include <stdlib.h>

static unsigned long long cell_counted_allocs;
static unsigned long long cell_counted_frees;

static void cell_counted_report(void) {
    fprintf(stderr, "MALLOC_COUNTER ALLOC=%llu FREE=%llu LIVE=%llu\n",
            cell_counted_allocs, cell_counted_frees,
            cell_counted_allocs - cell_counted_frees);
}

__attribute__((constructor)) static void cell_counted_install(void) {
    atexit(cell_counted_report);
}

void *cell_counted_malloc(size_t size) {
    void *ptr = malloc(size);
    if (ptr != NULL) {
        cell_counted_allocs++;
    }
    return ptr;
}

void *cell_counted_realloc(void *ptr, size_t size) {
    void *fresh = realloc(ptr, size);
    if (ptr == NULL && fresh != NULL) {
        cell_counted_allocs++;
    }
    return fresh;
}

void cell_counted_free(void *ptr) {
    if (ptr != NULL) {
        cell_counted_frees++;
    }
    free(ptr);
}
