#include "cell_rt.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

const char *cell_rt_version(void) {
    return "cell-rt 0.1.0 (c11)";
}

void cell_arena_init(cell_arena_t *arena, void *buffer, size_t capacity) {
    arena->base = (uint8_t *)buffer;
    arena->capacity = capacity;
    arena->offset = 0;
}

void *cell_arena_alloc(cell_arena_t *arena, size_t size, size_t align) {
    if (align == 0) align = 1;
    size_t mask = align - 1;
    size_t aligned = (arena->offset + mask) & ~mask;
    if (aligned + size > arena->capacity) return NULL;
    void *ptr = arena->base + aligned;
    arena->offset = aligned + size;
    return ptr;
}

void cell_arena_reset(cell_arena_t *arena) {
    arena->offset = 0;
}

cell_arc_t cell_arc_new(void *ptr, void (*drop)(void *)) {
    size_t *rc = (size_t *)malloc(sizeof(size_t));
    if (!rc) cell_panic("cell_arc_new: oom");
    *rc = 1;
    cell_arc_t arc = { .ptr = ptr, .refcount = rc, .drop = drop };
    return arc;
}

cell_arc_t cell_arc_clone(cell_arc_t arc) {
    if (arc.refcount) {
        (*arc.refcount)++;
    }
    return arc;
}

void cell_arc_drop(cell_arc_t arc) {
    if (!arc.refcount) return;
    if (--(*arc.refcount) == 0) {
        if (arc.drop && arc.ptr) arc.drop(arc.ptr);
        free(arc.refcount);
    }
}

void cell_panic(const char *msg) {
    fprintf(stderr, "cell panic: %s\n", msg ? msg : "(null)");
    abort();
}

/* Weak stubs if C++ / Swift not linked. Strong symbols override these. */
__attribute__((weak)) int cell_cxx_probe(void) {
    return 0;
}

__attribute__((weak)) int cell_swift_probe(void) {
    return 0;
}
