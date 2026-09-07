#ifndef CELL_RT_H
#define CELL_RT_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/** Runtime version string (null-terminated). */
const char *cell_rt_version(void);

/** Result type used by Cell ABI. */
typedef struct cell_result {
    bool ok;
    union {
        void *value;
        int32_t error_code;
    } as;
} cell_result_t;

/** Simple arena bump allocator for host demos. */
typedef struct cell_arena {
    uint8_t *base;
    size_t capacity;
    size_t offset;
} cell_arena_t;

void cell_arena_init(cell_arena_t *arena, void *buffer, size_t capacity);
void *cell_arena_alloc(cell_arena_t *arena, size_t size, size_t align);
void cell_arena_reset(cell_arena_t *arena);

/** Reference-counted box (Swift-style arc / Rust Arc). */
typedef struct cell_arc {
    void *ptr;
    size_t *refcount;
    void (*drop)(void *);
} cell_arc_t;

cell_arc_t cell_arc_new(void *ptr, void (*drop)(void *));
cell_arc_t cell_arc_clone(cell_arc_t arc);
void cell_arc_drop(cell_arc_t arc);

/** Panic with message (aborts). */
void cell_panic(const char *msg) __attribute__((noreturn));

/** Optional C++ bridge entry (defined in cell_rt.cpp when linked). */
int cell_cxx_probe(void);

/** Optional Swift bridge entry (defined in CellBridge.swift when linked). */
int cell_swift_probe(void);

#ifdef __cplusplus
}
#endif

#endif /* CELL_RT_H */
