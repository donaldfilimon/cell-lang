/*
 * Allocation counter, injected with `cc -include examples/leaks/malloc_counter.h`
 * into the emitted C and runtime/cell_rt.c when the gate's leak stage builds a
 * fixture. It is the second, independent witness beside `leaks -atExit`:
 * `leaks` scans for what is still reachable, this counts what was never freed,
 * and the two must agree before a pinned constant in tools/check.sh may move.
 *
 * Function-like macros so that the prototypes in <stdlib.h>, which this header
 * pulls in first, are left alone; only call sites are redirected. The counters
 * and the counted functions live in malloc_counter.c, ONE definition shared by
 * every translation unit, because a `static` counter per TU would let the
 * emitted C and the runtime each keep a partial tally and print a LIVE figure
 * that is wrong in exactly the way this file exists to catch. malloc_counter.c
 * must therefore be compiled WITHOUT this header injected, or its own calls to
 * the real allocator would recurse into themselves.
 */

#ifndef CELL_MALLOC_COUNTER_H
#define CELL_MALLOC_COUNTER_H

#include <stddef.h>
#include <stdlib.h>

void *cell_counted_malloc(size_t size);
void *cell_counted_realloc(void *ptr, size_t size);
void cell_counted_free(void *ptr);

#define malloc(size) cell_counted_malloc(size)
#define realloc(ptr, size) cell_counted_realloc(ptr, size)
#define free(ptr) cell_counted_free(ptr)

#endif
