#ifndef CELL_RT_H
#define CELL_RT_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>

/*
 * ============================================================================
 * Cell C ABI value model
 * ============================================================================
 *
 * This block is the authoritative reference for what `cell emit` must produce.
 * Everything below is valid C11 and includable from C++ and from Swift via
 * swift/CellBridge.swift. No compound literals, no _Atomic, and no anonymous
 * unions appear in this header, because none of those are portable across all
 * three consumers.
 *
 * ---------------------------------------------------------------------------
 * 1. Primitives
 * ---------------------------------------------------------------------------
 *   Cell            C type      note
 *   Int, Int64      int64_t
 *   Int32           int32_t
 *   UInt, UInt64    uint64_t
 *   Float, Float64  double
 *   Float32         float
 *   Bool            bool        C11 stdbool, 1 byte
 *   Byte            uint8_t
 *   Unit            void        only as a return type
 *
 * Primitives are always passed and returned by value, in every ownership mode.
 * That is forced by the language itself: examples/hello.cell declares
 * `add(shared a: Int, shared b: Int)` and its body is `a + b`. If a `shared`
 * primitive lowered to a pointer, that expression would stop compiling.
 *
 * ---------------------------------------------------------------------------
 * 2. String
 * ---------------------------------------------------------------------------
 * Strings are length-prefixed slices, NOT null-terminated C strings.
 *
 *   shared String     -> cell_str_t     (borrowed view, by value)
 *   owned String      -> cell_string_t  (heap buffer, by value, callee frees)
 *   exclusive String  -> cell_string_t *
 *   arc String        -> cell_arc_t whose .ptr is a heap cell_string_t
 *   copy String       -> cell_string_t produced by cell_string_clone
 *
 * Tradeoff, stated deliberately: a length-prefixed slice makes substrings,
 * embedded NUL bytes, and Zig or Swift interop free, because those languages
 * already model strings as (ptr, len). The cost is that handing a Cell string
 * to a C stdlib function that wants `const char *` needs a copy. We accept
 * that cost, because the old `const char *` mapping cannot express length,
 * cannot express ownership, and makes `owned String` and `shared String`
 * indistinguishable at the ABI level. cell_string_t buffers produced by this
 * runtime are additionally NUL-terminated one byte past `len` as a courtesy,
 * but no consumer may rely on that for a string it did not allocate here.
 *
 * ---------------------------------------------------------------------------
 * 3. Lists, [T]
 * ---------------------------------------------------------------------------
 *   [T] -> cell_slice_t { void *ptr; size_t len; size_t cap; }
 *
 * One type-erased header for every element type, rather than a generated
 * struct per element type. C11 has no generics, and codegen already knows the
 * static element type at every use site, so it can cast `ptr` and pass the
 * right `elem_size`. That keeps the ABI surface a single type instead of an
 * unbounded family of them. The price is that the header carries no element
 * size, so every runtime helper that does arithmetic on elements takes
 * `elem_size` as an explicit parameter.
 *
 * Ownership maps the same way as String: `owned [T]` by value with the callee
 * owning the buffer, `shared [T]` by value as a read-only view, `exclusive
 * [T]` as `cell_slice_t *`, `arc [T]` as a cell_arc_t over a heap slice.
 *
 * ---------------------------------------------------------------------------
 * 4. Optionals, T?
 * ---------------------------------------------------------------------------
 *   T? -> a tagged struct { bool has_value; T value; }
 *
 * Tagged, not sentinel. A sentinel (NULL, or -1, or NaN) cannot represent
 * `Int?`, because every bit pattern of int64_t is a legal Int. Using the
 * tagged form even when T is pointer-shaped keeps one uniform lowering rule,
 * so codegen never has to ask "does this T have a spare value". The cost is
 * padding: cell_opt_i64_t is 16 bytes where a sentinel would have been 8.
 *
 * Instantiate new ones with CELL_DEFINE_OPTIONAL(base, T), which defines
 * `base##_t` plus `base##_some` and `base##_none`. The common instances are
 * pre-defined below.
 *
 * ---------------------------------------------------------------------------
 * 5. Result<T, E>
 * ---------------------------------------------------------------------------
 *   Result<T, E> -> cell_result_t { bool ok; int32_t error_code; cell_value_t value; }
 *
 * `value` is a union of the scalar shapes, so Result<Int, E> carries its
 * payload inline with no heap allocation. The previous `void *value` layout
 * forced a box for every integer. Struct-typed and aggregate T still travel
 * through `value.ptr`. E is narrowed to an int32_t code, which is the one real
 * limitation of this layout: a rich error payload would need the union on the
 * error side too, which this version does not model.
 *
 * ---------------------------------------------------------------------------
 * 6. Structs and enums
 * ---------------------------------------------------------------------------
 * A Cell struct lowers to a C struct with the same field order, each field
 * lowered by the rules above according to its own ownership keyword. A struct
 * is passed by value for `copy` and `owned`, as `const T *` for `shared`, as
 * `T *` for `exclusive`, and inside a cell_arc_t for `arc`.
 *
 * A Cell enum without payloads lowers to a distinct integer type of width
 * int32_t. Codegen currently emits a bare `typedef enum`, whose width is
 * implementation defined; the ABI requires int32_t, so the emitted form needs
 * an explicit integer typedef plus constants.
 *
 * ---------------------------------------------------------------------------
 * 7. Ownership modes at the C boundary
 * ---------------------------------------------------------------------------
 *   copy       By value. Callee gets an independent bitwise copy.
 *   shared     Primitives by value; aggregates as `const T *`; String and
 *              lists by value as views. Callee must not free or mutate.
 *   exclusive  `T *`. Callee may mutate, must not free.
 *   owned      By value, and the caller relinquishes. The callee is
 *              responsible for the eventual free.
 *   arc        cell_arc_t by value. The caller has already retained; the
 *              callee releases when done, or clones to keep it.
 *
 * ---------------------------------------------------------------------------
 * 8. Thread safety
 * ---------------------------------------------------------------------------
 * cell_arc_t refcounts are ATOMIC. examples/ownership.cell documents `arc` as
 * "shared ownership (Swift class / Arc)", and both of those references are
 * thread-safe by definition, so a non-atomic refcount would silently violate
 * the semantics the language already advertises. The atomics live entirely
 * inside cell_rt.c: `struct cell_rc_box` is opaque here, because `_Atomic` is
 * not valid C++ and this header must also compile as C++20.
 *
 * Nothing else in this runtime is thread safe. cell_arena_t in particular is a
 * plain bump pointer with no synchronization, and is single-threaded only.
 * ============================================================================
 */

#ifdef __cplusplus
extern "C" {
#endif

/** Runtime version string (null-terminated). ABI frozen: src/main.zig externs it. */
const char *cell_rt_version(void);

/* ------------------------------------------------------------------------ */
/* String                                                                    */
/* ------------------------------------------------------------------------ */

/** Borrowed string view. Cell `shared String`. */
typedef struct cell_str {
    const char *ptr;
    size_t len;
} cell_str_t;

/** Owning heap string. Cell `owned String`. */
typedef struct cell_string {
    char *ptr;
    size_t len;
    size_t cap;
} cell_string_t;

static inline cell_str_t cell_str_from_parts(const char *ptr, size_t len) {
    cell_str_t s;
    s.ptr = ptr;
    s.len = len;
    return s;
}

static inline cell_str_t cell_str_empty(void) {
    return cell_str_from_parts(NULL, 0);
}

/** Adopt a null-terminated C string as a borrowed view. Does not copy. */
static inline cell_str_t cell_str_from_cstr(const char *cstr) {
    if (cstr == NULL) return cell_str_empty();
    return cell_str_from_parts(cstr, strlen(cstr));
}

static inline bool cell_str_eq(cell_str_t a, cell_str_t b) {
    if (a.len != b.len) return false;
    if (a.len == 0) return true;
    if (a.ptr == NULL || b.ptr == NULL) return false;
    return memcmp(a.ptr, b.ptr, a.len) == 0;
}

/** Borrow an owning string as a view. Valid until the owner is freed or moved. */
static inline cell_str_t cell_string_as_str(const cell_string_t *s) {
    if (s == NULL) return cell_str_empty();
    return cell_str_from_parts(s->ptr, s->len);
}

/** Copy a view onto the heap. Returns a zeroed string on allocation failure. */
cell_string_t cell_string_from_str(cell_str_t view);

/** Copy a null-terminated C string onto the heap. */
cell_string_t cell_string_from_cstr(const char *cstr);

/** Deep copy. Cell `copy String`. */
cell_string_t cell_string_clone(const cell_string_t *src);

/** Release an owning string and zero it. Safe on an already-zeroed string. */
void cell_string_free(cell_string_t *s);

/* ------------------------------------------------------------------------ */
/* Lists, [T]                                                                */
/* ------------------------------------------------------------------------ */

/** Type-erased list header. Cell `[T]`. `elem_size` is supplied by codegen. */
typedef struct cell_slice {
    void *ptr;
    size_t len;
    size_t cap;
} cell_slice_t;

static inline cell_slice_t cell_slice_from_parts(void *ptr, size_t len, size_t cap) {
    cell_slice_t s;
    s.ptr = ptr;
    s.len = len;
    s.cap = cap;
    return s;
}

static inline cell_slice_t cell_slice_empty(void) {
    return cell_slice_from_parts(NULL, 0, 0);
}

/** Allocate room for `cap` elements of `elem_size` bytes. len starts at 0. */
cell_slice_t cell_slice_alloc(size_t elem_size, size_t cap);

/** Grow capacity to at least `new_cap`. Returns false on overflow or OOM. */
bool cell_slice_reserve(cell_slice_t *s, size_t elem_size, size_t new_cap);

/** Append one element by copy, growing if needed. Returns false on failure. */
bool cell_slice_push(cell_slice_t *s, size_t elem_size, const void *elem);

/** Address of element `index`, or NULL when out of bounds. */
void *cell_slice_at(const cell_slice_t *s, size_t elem_size, size_t index);

/** Release the buffer and zero the header. Safe on an already-zeroed slice. */
void cell_slice_free(cell_slice_t *s);

/* ------------------------------------------------------------------------ */
/* Optionals, T?                                                             */
/* ------------------------------------------------------------------------ */

/**
 * Define an optional over T. `CELL_DEFINE_OPTIONAL(cell_opt_i64, int64_t)`
 * defines the type `cell_opt_i64_t` plus the constructors `cell_opt_i64_some`
 * and `cell_opt_i64_none`.
 */
#define CELL_DEFINE_OPTIONAL(base, T)                                          \
    typedef struct base##_s {                                                  \
        bool has_value;                                                        \
        T value;                                                               \
    } base##_t;                                                                \
    static inline base##_t base##_some(T v) {                                  \
        base##_t o;                                                            \
        memset(&o, 0, sizeof(o));                                              \
        o.has_value = true;                                                    \
        o.value = v;                                                           \
        return o;                                                              \
    }                                                                          \
    static inline base##_t base##_none(void) {                                 \
        base##_t o;                                                            \
        memset(&o, 0, sizeof(o));                                              \
        o.has_value = false;                                                   \
        return o;                                                              \
    }

CELL_DEFINE_OPTIONAL(cell_opt_i64, int64_t)
CELL_DEFINE_OPTIONAL(cell_opt_u64, uint64_t)
CELL_DEFINE_OPTIONAL(cell_opt_i32, int32_t)
CELL_DEFINE_OPTIONAL(cell_opt_f64, double)
CELL_DEFINE_OPTIONAL(cell_opt_bool, bool)
CELL_DEFINE_OPTIONAL(cell_opt_byte, uint8_t)
CELL_DEFINE_OPTIONAL(cell_opt_str, cell_str_t)
CELL_DEFINE_OPTIONAL(cell_opt_ptr, void *)

/* ------------------------------------------------------------------------ */
/* Result<T, E>                                                              */
/* ------------------------------------------------------------------------ */

/** Inline scalar payload. Aggregates travel through `ptr`. */
typedef union cell_value {
    int64_t i64;
    uint64_t u64;
    double f64;
    bool b;
    void *ptr;
    cell_str_t str;
} cell_value_t;

/** Result type used by the Cell ABI. Carries a scalar payload without boxing. */
typedef struct cell_result {
    bool ok;
    int32_t error_code;
    cell_value_t value;
} cell_result_t;

static inline cell_result_t cell_ok_unit(void) {
    cell_result_t r;
    memset(&r, 0, sizeof(r));
    r.ok = true;
    return r;
}

static inline cell_result_t cell_ok_i64(int64_t v) {
    cell_result_t r = cell_ok_unit();
    r.value.i64 = v;
    return r;
}

static inline cell_result_t cell_ok_u64(uint64_t v) {
    cell_result_t r = cell_ok_unit();
    r.value.u64 = v;
    return r;
}

static inline cell_result_t cell_ok_f64(double v) {
    cell_result_t r = cell_ok_unit();
    r.value.f64 = v;
    return r;
}

static inline cell_result_t cell_ok_bool(bool v) {
    cell_result_t r = cell_ok_unit();
    r.value.b = v;
    return r;
}

static inline cell_result_t cell_ok_ptr(void *v) {
    cell_result_t r = cell_ok_unit();
    r.value.ptr = v;
    return r;
}

static inline cell_result_t cell_ok_str(cell_str_t v) {
    cell_result_t r = cell_ok_unit();
    r.value.str = v;
    return r;
}

static inline cell_result_t cell_err(int32_t code) {
    cell_result_t r;
    memset(&r, 0, sizeof(r));
    r.ok = false;
    r.error_code = code;
    return r;
}

/* ------------------------------------------------------------------------ */
/* Arena                                                                     */
/* ------------------------------------------------------------------------ */

/** Simple bump allocator for host demos. Single-threaded only. */
typedef struct cell_arena {
    uint8_t *base;
    size_t capacity;
    size_t offset;
} cell_arena_t;

void cell_arena_init(cell_arena_t *arena, void *buffer, size_t capacity);

/**
 * Bump-allocate `size` bytes aligned to `align`, which must be a power of two
 * (0 is treated as 1). Alignment is applied to the returned ADDRESS, not to
 * the offset, so the guarantee holds even when `base` is itself misaligned.
 * Returns NULL when the request does not fit, and never wraps on overflow.
 */
void *cell_arena_alloc(cell_arena_t *arena, size_t size, size_t align);

void cell_arena_reset(cell_arena_t *arena);

/** Bytes still allocatable at the given alignment. */
size_t cell_arena_remaining(const cell_arena_t *arena, size_t align);

/* ------------------------------------------------------------------------ */
/* ARC                                                                       */
/* ------------------------------------------------------------------------ */

/** Opaque atomic refcount box. Defined in cell_rt.c so C++ never sees _Atomic. */
struct cell_rc_box;

/** Reference-counted box (Swift class / Rust Arc). The refcount is ATOMIC. */
typedef struct cell_arc {
    void *ptr;
    struct cell_rc_box *refcount;
    void (*drop)(void *);
} cell_arc_t;

/** Take ownership of `ptr` with strong count 1. `drop` may be NULL. */
cell_arc_t cell_arc_new(void *ptr, void (*drop)(void *));

/** Retain. The returned handle must be released exactly once. */
cell_arc_t cell_arc_clone(cell_arc_t arc);

/** Release. Runs `drop` exactly once when the last strong reference goes away. */
void cell_arc_drop(cell_arc_t arc);

/** Current strong count, or 0 for a null handle. For tests and diagnostics. */
size_t cell_arc_strong_count(cell_arc_t arc);

/* ------------------------------------------------------------------------ */
/* Host intrinsics declared by stdlib/prelude.cell                           */
/* ------------------------------------------------------------------------ */

/**
 * `pub fn print(shared msg: String)`.
 * Writes the bytes of `msg` to stdout followed by a single newline. The
 * newline is added by the runtime rather than by the caller, so that `print`
 * matches the line-oriented behavior of every language Cell borrows from.
 * A zero-length or null-pointer view prints just the newline.
 */
void cell_print(cell_str_t msg);

/**
 * `pub fn assert(shared cond: Bool)`.
 * No-op when true; calls cell_panic and aborts when false.
 */
void cell_assert(bool cond);

/** Panic with message (aborts). */
void cell_panic(const char *msg) __attribute__((noreturn));

/* ------------------------------------------------------------------------ */
/* Bridge probes. ABI frozen: src/main.zig externs both.                     */
/* ------------------------------------------------------------------------ */

/** Optional C++ bridge entry (defined in cell_rt.cpp when linked). */
int cell_cxx_probe(void);

/** Optional Swift bridge entry (defined in CellBridge.swift when linked). */
int cell_swift_probe(void);

#ifdef __cplusplus
}
#endif

#endif /* CELL_RT_H */
