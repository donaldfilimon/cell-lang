#include "cell_rt.h"

#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/*
 * Implementation of the Cell C ABI value model. The authoritative description
 * of every type below lives in the comment block at the top of cell_rt.h.
 */

const char *cell_rt_version(void) {
    return "cell-rt 0.2.0 (c11, atomic arc)";
}

/* ------------------------------------------------------------------------ */
/* String                                                                    */
/* ------------------------------------------------------------------------ */

static cell_string_t cell_string_zero(void) {
    cell_string_t s;
    s.ptr = NULL;
    s.len = 0;
    s.cap = 0;
    return s;
}

cell_string_t cell_string_from_str(cell_str_t view) {
    cell_string_t out = cell_string_zero();
    size_t len = (view.ptr == NULL) ? 0 : view.len;

    /* Always allocate len + 1 so the buffer is NUL-terminated one past `len`. */
    char *buf = (char *)malloc(len + 1);
    if (buf == NULL) return out;
    if (len > 0) memcpy(buf, view.ptr, len);
    buf[len] = '\0';

    out.ptr = buf;
    out.len = len;
    out.cap = len + 1;
    return out;
}

cell_string_t cell_string_from_cstr(const char *cstr) {
    return cell_string_from_str(cell_str_from_cstr(cstr));
}

cell_string_t cell_string_clone(const cell_string_t *src) {
    if (src == NULL) return cell_string_zero();
    return cell_string_from_str(cell_string_as_str(src));
}

void cell_string_free(cell_string_t *s) {
    if (s == NULL) return;
    free(s->ptr);
    *s = cell_string_zero();
}

/* ------------------------------------------------------------------------ */
/* Lists, [T]                                                                */
/* ------------------------------------------------------------------------ */

cell_slice_t cell_slice_alloc(size_t elem_size, size_t cap) {
    cell_slice_t s = cell_slice_empty();
    if (elem_size == 0 || cap == 0) return s;
    if (cap > SIZE_MAX / elem_size) return s;

    void *buf = malloc(elem_size * cap);
    if (buf == NULL) return s;

    s.ptr = buf;
    s.len = 0;
    s.cap = cap;
    return s;
}

bool cell_slice_reserve(cell_slice_t *s, size_t elem_size, size_t new_cap) {
    if (s == NULL || elem_size == 0) return false;
    if (new_cap <= s->cap) return true;
    if (new_cap > SIZE_MAX / elem_size) return false;

    void *buf = realloc(s->ptr, elem_size * new_cap);
    if (buf == NULL) return false;

    s->ptr = buf;
    s->cap = new_cap;
    return true;
}

bool cell_slice_push(cell_slice_t *s, size_t elem_size, const void *elem) {
    if (s == NULL || elem == NULL || elem_size == 0) return false;

    if (s->len == s->cap) {
        size_t next;
        if (s->cap == 0) {
            next = 4;
        } else if (s->cap > SIZE_MAX / 2) {
            return false;
        } else {
            next = s->cap * 2;
        }
        if (!cell_slice_reserve(s, elem_size, next)) return false;
    }

    memcpy((uint8_t *)s->ptr + (s->len * elem_size), elem, elem_size);
    s->len += 1;
    return true;
}

void *cell_slice_at(const cell_slice_t *s, size_t elem_size, size_t index) {
    if (s == NULL || s->ptr == NULL || elem_size == 0) return NULL;
    if (index >= s->len) return NULL;
    return (void *)((uint8_t *)s->ptr + (index * elem_size));
}

void cell_slice_free(cell_slice_t *s) {
    if (s == NULL) return;
    free(s->ptr);
    *s = cell_slice_empty();
}

/* ------------------------------------------------------------------------ */
/* Arena                                                                     */
/* ------------------------------------------------------------------------ */

void cell_arena_init(cell_arena_t *arena, void *buffer, size_t capacity) {
    if (arena == NULL) return;
    arena->base = (uint8_t *)buffer;
    arena->capacity = (buffer == NULL) ? 0 : capacity;
    arena->offset = 0;
}

/* Offset of the next `align`-aligned address, or capacity + 1 when it wraps. */
static size_t cell_arena_aligned_offset(const cell_arena_t *arena, size_t align) {
    uintptr_t base = (uintptr_t)arena->base;
    uintptr_t cur = base + (uintptr_t)arena->offset;
    uintptr_t mask = (uintptr_t)align - 1u;
    uintptr_t aligned = (cur + mask) & ~mask;
    if (aligned < cur) return arena->capacity + 1u; /* address space wrap */
    return (size_t)(aligned - base);
}

void *cell_arena_alloc(cell_arena_t *arena, size_t size, size_t align) {
    if (arena == NULL || arena->base == NULL) return NULL;
    if (align == 0) align = 1;
    if ((align & (align - 1u)) != 0) return NULL; /* not a power of two */

    size_t aligned = cell_arena_aligned_offset(arena, align);
    if (aligned > arena->capacity) return NULL;
    /* Written as a subtraction so a huge `size` cannot wrap the comparison. */
    if (size > arena->capacity - aligned) return NULL;

    void *ptr = arena->base + aligned;
    arena->offset = aligned + size;
    return ptr;
}

void cell_arena_reset(cell_arena_t *arena) {
    if (arena == NULL) return;
    arena->offset = 0;
}

size_t cell_arena_remaining(const cell_arena_t *arena, size_t align) {
    if (arena == NULL || arena->base == NULL) return 0;
    if (align == 0) align = 1;
    if ((align & (align - 1u)) != 0) return 0;

    size_t aligned = cell_arena_aligned_offset(arena, align);
    if (aligned >= arena->capacity) return 0;
    return arena->capacity - aligned;
}

/* ------------------------------------------------------------------------ */
/* ARC                                                                       */
/* ------------------------------------------------------------------------ */

/*
 * The refcount is atomic because examples/ownership.cell defines `arc` as
 * "shared ownership (Swift class / Arc)", and both of those are thread safe.
 * The box is defined here rather than in the header so that `_Atomic`, which
 * is not valid C++, never reaches a C++ or Swift consumer of cell_rt.h.
 */
struct cell_rc_box {
    atomic_size_t count;
};

cell_arc_t cell_arc_new(void *ptr, void (*drop)(void *)) {
    struct cell_rc_box *box = (struct cell_rc_box *)malloc(sizeof(*box));
    if (box == NULL) cell_panic("cell_arc_new: out of memory");
    atomic_init(&box->count, (size_t)1);

    cell_arc_t arc;
    arc.ptr = ptr;
    arc.refcount = box;
    arc.drop = drop;
    return arc;
}

cell_arc_t cell_arc_clone(cell_arc_t arc) {
    if (arc.refcount != NULL) {
        /* Relaxed is sufficient: the caller already holds a live reference. */
        atomic_fetch_add_explicit(&arc.refcount->count, (size_t)1, memory_order_relaxed);
    }
    return arc;
}

void cell_arc_drop(cell_arc_t arc) {
    if (arc.refcount == NULL) return;

    /* acq_rel so the last releaser observes every prior writer's stores. */
    size_t prev = atomic_fetch_sub_explicit(&arc.refcount->count, (size_t)1, memory_order_acq_rel);
    if (prev == 0) cell_panic("cell_arc_drop: refcount underflow");
    if (prev != 1) return;

    if (arc.drop != NULL && arc.ptr != NULL) arc.drop(arc.ptr);
    free(arc.refcount);
}

size_t cell_arc_strong_count(cell_arc_t arc) {
    if (arc.refcount == NULL) return 0;
    return atomic_load_explicit(&arc.refcount->count, memory_order_acquire);
}

/* ------------------------------------------------------------------------ */
/* Host intrinsics declared by stdlib/prelude.cell                           */
/* ------------------------------------------------------------------------ */

void cell_print(cell_str_t msg) {
    if (msg.ptr != NULL && msg.len > 0) {
        size_t written = fwrite(msg.ptr, 1, msg.len, stdout);
        (void)written;
    }
    fputc('\n', stdout);
}

void cell_println(cell_str_t msg) {
    cell_print(msg);
}

void cell_assert(bool cond) {
    if (!cond) cell_panic("assertion failed");
}

void cell_assert_msg(bool cond, cell_str_t msg) {
    if (cond) return;

    /* cell_panic takes a C string, so the view needs a NUL-terminated copy.
       Fall back to the bare message if that allocation fails. */
    cell_string_t owned = cell_string_from_str(msg);
    if (owned.ptr == NULL) cell_panic("assertion failed");
    fprintf(stderr, "cell panic: assertion failed: %s\n", owned.ptr);
    cell_string_free(&owned);
    abort();
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
