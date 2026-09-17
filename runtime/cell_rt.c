#include "cell_rt.h"

#include <math.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(__APPLE__)
#include <mach/mach.h>
#include <mach/exception.h>
#ifndef EXC_MASK_CORPSE_NOTIFY
#define EXC_MASK_CORPSE_NOTIFY 0
#endif
#endif

/*
 * Implementation of the Cell C ABI value model. The authoritative description
 * of every type below lives in the comment block at the top of cell_rt.h.
 */

cell_string_t cell_rt_version(void) {
    return cell_string_from_cstr("cell-rt 0.2.0 (c11, atomic arc)");
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
    if (box == NULL) cell_panic(cell_str_from_cstr("cell_arc_new: out of memory"));
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
    if (prev == 0) cell_panic(cell_str_from_cstr("cell_arc_drop: refcount underflow"));
    if (prev != 1) return;

    if (arc.drop != NULL && arc.ptr != NULL) arc.drop(arc.ptr);
    free(arc.refcount);
}

size_t cell_arc_strong_count(cell_arc_t arc) {
    if (arc.refcount == NULL) return 0;
    return atomic_load_explicit(&arc.refcount->count, memory_order_acquire);
}

void cell_string_drop_glue(void *p) {
    if (p == NULL) return;
    cell_string_t *box = (cell_string_t *)p;
    cell_string_free(box);
    free(box);
}

void cell_slice_drop_glue(void *p) {
    if (p == NULL) return;
    cell_slice_t *box = (cell_slice_t *)p;
    cell_slice_free(box);
    free(box);
}

cell_arc_t cell_arc_from_string(cell_string_t s) {
    cell_string_t *box = (cell_string_t *)malloc(sizeof(*box));
    if (box == NULL) cell_panic(cell_str_from_cstr("cell_arc_from_string: out of memory"));
    *box = s; /* move: box now owns the buffer, s must not be freed */
    return cell_arc_new(box, cell_string_drop_glue);
}

cell_arc_t cell_arc_from_slice(cell_slice_t s) {
    cell_slice_t *box = (cell_slice_t *)malloc(sizeof(*box));
    if (box == NULL) cell_panic(cell_str_from_cstr("cell_arc_from_slice: out of memory"));
    *box = s; /* move: box now owns the buffer, s must not be freed */
    return cell_arc_new(box, cell_slice_drop_glue);
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

void cell_print_int(int64_t value) {
    printf("%lld\n", (long long)value);
}

/*
 * `cell run` / `cell test` set CELL_NO_CRASH_REPORTER=1 on the child so an
 * aborting program does not pop macOS Crash Reporter. abort() still raises
 * SIGABRT; the parent still sees WIFSIGNALED (shell 134). Measured 2026-09-16
 * on this Mac: CRASHREPORTER_DISABLE=1 does not suppress DiagnosticReports;
 * task_set_exception_ports with EXC_MASK_CRASH|RESOURCE|GUARD|CORPSE_NOTIFY
 * and MACH_PORT_NULL does, and wait-status stays 134. A binary built with
 * `cell build` does not get the env var, so abort() is unchanged there.
 */
static const char cell_no_crash_reporter_env[] = "CELL_NO_CRASH_REPORTER";

static int cell_should_suppress_crash_reporter(void) {
    const char *v = getenv(cell_no_crash_reporter_env);
    return v != NULL && v[0] != '\0';
}

static void cell_disable_crash_reporter(void) {
#if defined(__APPLE__)
    exception_mask_t mask = EXC_MASK_CRASH | EXC_MASK_RESOURCE | EXC_MASK_GUARD | EXC_MASK_CORPSE_NOTIFY;
    (void)task_set_exception_ports(
        mach_task_self(),
        mask,
        MACH_PORT_NULL,
        EXCEPTION_DEFAULT,
        THREAD_STATE_NONE);
#endif
}

#if defined(__APPLE__)
__attribute__((constructor))
static void cell_maybe_disable_crash_reporter(void) {
    if (cell_should_suppress_crash_reporter()) cell_disable_crash_reporter();
}
#endif

__attribute__((noreturn))
static void cell_abort(void) {
    if (cell_should_suppress_crash_reporter()) cell_disable_crash_reporter();
    abort();
}

void cell_assert(bool cond) {
    if (!cond) cell_panic(cell_str_from_cstr("assertion failed"));
}

void cell_assert_msg(bool cond, cell_str_t msg) {
    if (cond) return;
    fputs("cell panic: assertion failed: ", stderr);
    if (msg.ptr != NULL && msg.len > 0) fwrite(msg.ptr, 1, msg.len, stderr);
    fputc('\n', stderr);
    cell_abort();
}

__attribute__((noreturn))
void cell_panic(cell_str_t msg) {
    fputs("cell panic: ", stderr);
    if (msg.ptr != NULL && msg.len > 0) fwrite(msg.ptr, 1, msg.len, stderr);
    fputc('\n', stderr);
    cell_abort();
}

bool cell_str_eq(cell_str_t a, cell_str_t b) {
    if (a.len != b.len) return false;
    if (a.len == 0) return true;
    if (a.ptr == NULL || b.ptr == NULL) return false;
    return memcmp(a.ptr, b.ptr, a.len) == 0;
}

/* ------------------------------------------------------------------------ */
/* Prelude group 3                                                           */
/* ------------------------------------------------------------------------ */

void cell_eprintln(cell_str_t msg) {
    if (msg.ptr != NULL && msg.len > 0) fwrite(msg.ptr, 1, msg.len, stderr);
    fputc('\n', stderr);
}

int64_t cell_int_from_int32(int32_t v) { return v; }

cell_opt_i32_t cell_int32_from_int(int64_t v) {
    if (v < INT32_MIN || v > INT32_MAX) return cell_opt_i32_none();
    return cell_opt_i32_some((int32_t)v);
}

cell_opt_u64_t cell_uint_from_int(int64_t v) {
    if (v < 0) return cell_opt_u64_none();
    return cell_opt_u64_some((uint64_t)v);
}

cell_opt_i64_t cell_int_from_uint(uint64_t v) {
    if (v > (uint64_t)INT64_MAX) return cell_opt_i64_none();
    return cell_opt_i64_some((int64_t)v);
}

double cell_float_from_int(int64_t v) { return (double)v; }

cell_opt_i64_t cell_int_from_float(double v) {
    /* 2^63 is exactly representable; INT64_MAX is not, so compare against
     * the power of two on the high side and the exact minimum on the low. */
    if (isnan(v) || isinf(v)) return cell_opt_i64_none();
    if (v >= 9223372036854775808.0 || v < -9223372036854775808.0) return cell_opt_i64_none();
    return cell_opt_i64_some((int64_t)v);
}

float cell_float32_from_float(double v) { return (float)v; }
double cell_float_from_float32(float v) { return (double)v; }

cell_opt_byte_t cell_byte_from_int(int64_t v) {
    if (v < 0 || v > 255) return cell_opt_byte_none();
    return cell_opt_byte_some((uint8_t)v);
}

int64_t cell_int_from_byte(uint8_t v) { return v; }

cell_opt_i64_t cell_abs_int(int64_t v) {
    if (v == INT64_MIN) return cell_opt_i64_none();
    return cell_opt_i64_some(v < 0 ? -v : v);
}

int64_t cell_min_int(int64_t a, int64_t b) { return a < b ? a : b; }
int64_t cell_max_int(int64_t a, int64_t b) { return a > b ? a : b; }

cell_opt_i64_t cell_rem_int(int64_t a, int64_t b) {
    if (b == 0 || (a == INT64_MIN && b == -1)) return cell_opt_i64_none();
    return cell_opt_i64_some(a % b);
}

double cell_abs_float(double v) { return fabs(v); }
double cell_min_float(double a, double b) { return a < b ? a : b; }
double cell_max_float(double a, double b) { return a > b ? a : b; }

int64_t cell_str_len(cell_str_t s) { return (int64_t)s.len; }

cell_string_t cell_str_concat(cell_str_t a, cell_str_t b) {
    cell_string_t out = cell_string_from_str(a);
    if (b.len == 0) return out;
    /* cap includes the NUL terminator (see cell_string_from_str). */
    size_t need = out.len + b.len;
    if (need + 1 > out.cap) {
        char *grown = (char *)realloc(out.ptr, need + 1);
        if (grown == NULL) cell_panic(cell_str_from_cstr("cell_str_concat: out of memory"));
        out.ptr = grown;
        out.cap = need + 1;
    }
    memcpy(out.ptr + out.len, b.ptr, b.len);
    out.len = need;
    out.ptr[out.len] = '\0';
    return out;
}

cell_opt_byte_t cell_str_byte_at(cell_str_t s, int64_t index) {
    if (index < 0 || (uint64_t)index >= s.len) return cell_opt_byte_none();
    return cell_opt_byte_some((uint8_t)s.ptr[index]);
}

static cell_string_t cell_string_from_buf(const char *buf, int n) {
    if (n < 0) n = 0;
    return cell_string_from_str(cell_str_from_parts(buf, (size_t)n));
}

cell_string_t cell_str_from_int(int64_t v) {
    char buf[32];
    int n = snprintf(buf, sizeof buf, "%lld", (long long)v);
    return cell_string_from_buf(buf, n);
}

cell_string_t cell_str_from_float(double v) {
    char buf[64];
    int n = snprintf(buf, sizeof buf, "%.17g", v);
    return cell_string_from_buf(buf, n);
}

cell_string_t cell_str_from_bool(bool v) {
    return cell_string_from_cstr(v ? "true" : "false");
}

int64_t cell_bytes_len(cell_slice_t xs) { return (int64_t)xs.len; }

cell_opt_byte_t cell_bytes_at(cell_slice_t xs, int64_t index) {
    if (index < 0 || (uint64_t)index >= xs.len) return cell_opt_byte_none();
    return cell_opt_byte_some(((const uint8_t *)xs.ptr)[index]);
}

#define CELL_LIST_AT(fn, base, T)                                               \
    base##_t fn(cell_slice_t xs, int64_t index) {                               \
        if (index < 0 || (uint64_t)index >= xs.len) return base##_none();       \
        return base##_some(((const T *)xs.ptr)[index]);                         \
    }
CELL_LIST_AT(cell_list_i64_at, cell_opt_i64, int64_t)
CELL_LIST_AT(cell_list_i32_at, cell_opt_i32, int32_t)
CELL_LIST_AT(cell_list_f64_at, cell_opt_f64, double)
CELL_LIST_AT(cell_list_bool_at, cell_opt_bool, bool)
#undef CELL_LIST_AT

void cell_bytes_push(cell_slice_t *xs, uint8_t value) {
    if (!cell_slice_push(xs, sizeof(uint8_t), &value))
        cell_panic(cell_str_from_cstr("cell_bytes_push: out of memory"));
}

cell_opt_byte_t cell_bytes_pop(cell_slice_t *xs) {
    if (xs->len == 0) return cell_opt_byte_none();
    xs->len -= 1;
    return cell_opt_byte_some(((const uint8_t *)xs->ptr)[xs->len]);
}

void cell_bytes_clear(cell_slice_t *xs) { xs->len = 0; }

cell_slice_t cell_bytes_empty(void) { return cell_slice_empty(); }

cell_slice_t cell_bytes_with_capacity(int64_t cap) {
    if (cap < 0) cap = 0;
    return cell_slice_alloc(sizeof(uint8_t), (size_t)cap);
}

cell_arc_t cell_arc_retain_string(cell_arc_t value) {
    cell_arc_t out = cell_arc_clone(value);
    cell_arc_drop(value);
    return out;
}

void cell_arc_release_string(cell_arc_t value) {
    cell_arc_drop(value);
}

int64_t cell_arc_count_string(cell_arc_t value) {
    int64_t n = (int64_t)cell_arc_strong_count(value);
    cell_arc_drop(value);
    return n;
}

/* Weak stubs if C++ / Swift not linked. Strong symbols override these. */
__attribute__((weak)) int32_t cell_cxx_probe(void) {
    return 0;
}

__attribute__((weak)) int32_t cell_swift_probe(void) {
    return 0;
}
