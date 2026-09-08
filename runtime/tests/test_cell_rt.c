/*
 * C test harness for the Cell runtime ABI.
 *
 * Run with `zig build test-runtime -Dswift=false`, or fold in via `zig build
 * test -Dswift=false`. Compiled with -std=c11 -Wall -Wextra -Werror.
 *
 * cell_rt.cpp is deliberately NOT linked into this harness, so the weak-symbol
 * fallback for cell_cxx_probe and cell_swift_probe is exercised for real.
 */

#include "cell_rt.h"

#include <stdio.h>
#include <stdlib.h>

/*
 * The concurrent retain/release test needs real threads. POSIX threads are
 * available on the hosts this repo builds on; elsewhere the test is skipped
 * rather than faked, and the rest of the harness still runs.
 */
#if defined(__APPLE__) || defined(__linux__) || defined(__unix__)
#define CELL_RT_TEST_THREADS 1
#include <pthread.h>
#else
#define CELL_RT_TEST_THREADS 0
#endif

static int g_checks = 0;
static int g_failures = 0;

#define CHECK(cond)                                                            \
    do {                                                                       \
        g_checks += 1;                                                         \
        if (!(cond)) {                                                         \
            g_failures += 1;                                                   \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);    \
        }                                                                      \
    } while (0)

/* ------------------------------------------------------------------------ */
/* Version                                                                   */
/* ------------------------------------------------------------------------ */

static void test_version(void) {
    const char *v = cell_rt_version();
    CHECK(v != NULL);
    CHECK(v[0] != '\0');
}

/* ------------------------------------------------------------------------ */
/* Arena                                                                     */
/* ------------------------------------------------------------------------ */

static void test_arena_alignment(void) {
    /* Deliberately misalign the base so alignment of the OFFSET is not enough. */
    static uint8_t raw[1024];
    cell_arena_t arena;
    cell_arena_init(&arena, raw + 1, sizeof(raw) - 1);

    const size_t aligns[] = { 1, 2, 4, 8, 16, 32, 64 };
    for (size_t i = 0; i < sizeof(aligns) / sizeof(aligns[0]); ++i) {
        size_t a = aligns[i];
        void *p = cell_arena_alloc(&arena, 3, a);
        CHECK(p != NULL);
        if (p != NULL) {
            CHECK(((uintptr_t)p % (uintptr_t)a) == 0);
        }
    }

    /* Zero alignment is treated as 1 and must still succeed. */
    CHECK(cell_arena_alloc(&arena, 1, 0) != NULL);

    /* A non power of two is rejected rather than silently mis-aligning. */
    CHECK(cell_arena_alloc(&arena, 1, 3) == NULL);
    CHECK(cell_arena_alloc(&arena, 1, 24) == NULL);
}

static void test_arena_exhaustion(void) {
    static uint8_t raw[64];
    cell_arena_t arena;
    cell_arena_init(&arena, raw, sizeof(raw));

    void *a = cell_arena_alloc(&arena, 32, 1);
    CHECK(a != NULL);
    CHECK(cell_arena_remaining(&arena, 1) == 32);

    /* Exactly fills the arena. */
    void *b = cell_arena_alloc(&arena, 32, 1);
    CHECK(b != NULL);
    CHECK(cell_arena_remaining(&arena, 1) == 0);

    /* One byte past the end. */
    CHECK(cell_arena_alloc(&arena, 1, 1) == NULL);

    cell_arena_reset(&arena);
    CHECK(cell_arena_remaining(&arena, 1) == sizeof(raw));
    CHECK(cell_arena_alloc(&arena, 64, 1) != NULL);
}

static void test_arena_overflow(void) {
    static uint8_t raw[64];
    cell_arena_t arena;
    cell_arena_init(&arena, raw, sizeof(raw));

    size_t before = arena.offset;
    /* A huge size must return NULL, not wrap the bounds check. */
    CHECK(cell_arena_alloc(&arena, SIZE_MAX, 1) == NULL);
    CHECK(cell_arena_alloc(&arena, SIZE_MAX - 8, 16) == NULL);
    CHECK(arena.offset == before);

    /* A NULL buffer yields an arena that always fails. */
    cell_arena_t empty;
    cell_arena_init(&empty, NULL, 4096);
    CHECK(empty.capacity == 0);
    CHECK(cell_arena_alloc(&empty, 1, 1) == NULL);
    CHECK(cell_arena_remaining(&empty, 1) == 0);
}

/* ------------------------------------------------------------------------ */
/* ARC                                                                       */
/* ------------------------------------------------------------------------ */

static int g_drop_calls = 0;
static void *g_drop_arg = NULL;

static void test_drop_fn(void *p) {
    g_drop_calls += 1;
    g_drop_arg = p;
}

static void test_arc_retain_release(void) {
    int payload = 42;

    g_drop_calls = 0;
    g_drop_arg = NULL;

    cell_arc_t a = cell_arc_new(&payload, test_drop_fn);
    CHECK(a.ptr == &payload);
    CHECK(cell_arc_strong_count(a) == 1);

    cell_arc_t b = cell_arc_clone(a);
    CHECK(cell_arc_strong_count(a) == 2);
    CHECK(cell_arc_strong_count(b) == 2);
    CHECK(b.ptr == a.ptr);

    cell_arc_t c = cell_arc_clone(b);
    CHECK(cell_arc_strong_count(c) == 3);

    cell_arc_drop(c);
    CHECK(cell_arc_strong_count(a) == 2);
    CHECK(g_drop_calls == 0);

    cell_arc_drop(b);
    CHECK(cell_arc_strong_count(a) == 1);
    CHECK(g_drop_calls == 0);

    /* Last release: the drop callback fires exactly once. */
    cell_arc_drop(a);
    CHECK(g_drop_calls == 1);
    CHECK(g_drop_arg == &payload);
}

static void test_arc_null_cases(void) {
    /* A NULL drop callback is legal and must not be invoked. */
    int payload = 7;
    cell_arc_t a = cell_arc_new(&payload, NULL);
    CHECK(cell_arc_strong_count(a) == 1);
    cell_arc_drop(a);

    /* A zeroed handle has no refcount and releasing it is a no-op. */
    cell_arc_t zero;
    memset(&zero, 0, sizeof(zero));
    CHECK(cell_arc_strong_count(zero) == 0);
    cell_arc_drop(zero);

    /* A NULL payload must not reach the drop callback. */
    g_drop_calls = 0;
    cell_arc_t nul = cell_arc_new(NULL, test_drop_fn);
    cell_arc_drop(nul);
    CHECK(g_drop_calls == 0);
}

#if CELL_RT_TEST_THREADS
#define CELL_RT_TEST_THREAD_COUNT 8
#define CELL_RT_TEST_SPIN_COUNT 20000

static cell_arc_t g_shared_arc;

static void *arc_spin(void *unused) {
    (void)unused;
    for (int i = 0; i < CELL_RT_TEST_SPIN_COUNT; ++i) {
        cell_arc_t held = cell_arc_clone(g_shared_arc);
        cell_arc_drop(held);
    }
    return NULL;
}

/*
 * A non-atomic refcount loses increments here and the final count drifts below
 * 1, or the drop callback fires early. This is the test that backs the "arc is
 * thread safe" claim in the header.
 */
static void test_arc_is_atomic(void) {
    int payload = 5;
    g_drop_calls = 0;
    g_shared_arc = cell_arc_new(&payload, test_drop_fn);

    pthread_t threads[CELL_RT_TEST_THREAD_COUNT];
    int spawned = 0;
    for (int i = 0; i < CELL_RT_TEST_THREAD_COUNT; ++i) {
        if (pthread_create(&threads[i], NULL, arc_spin, NULL) == 0) spawned += 1;
    }
    CHECK(spawned == CELL_RT_TEST_THREAD_COUNT);
    for (int i = 0; i < spawned; ++i) {
        CHECK(pthread_join(threads[i], NULL) == 0);
    }

    CHECK(cell_arc_strong_count(g_shared_arc) == 1);
    CHECK(g_drop_calls == 0);

    cell_arc_drop(g_shared_arc);
    CHECK(g_drop_calls == 1);
}
#else
static void test_arc_is_atomic(void) {
    fprintf(stderr, "note: concurrent arc test skipped (no pthreads)\n");
}
#endif

/* ------------------------------------------------------------------------ */
/* ARC-boxed aggregates: cell_arc_from_string / cell_arc_from_slice          */
/* ------------------------------------------------------------------------ */

static void test_arc_from_string_roundtrip(void) {
    cell_string_t s = cell_string_from_cstr("glue-me");
    CHECK(s.ptr != NULL);

    cell_arc_t a = cell_arc_from_string(s);
    CHECK(a.ptr != NULL);
    CHECK(a.drop == cell_string_drop_glue);
    CHECK(cell_arc_strong_count(a) == 1);

    /* `s` was moved, not copied: this is the very buffer allocated above,
       read back through the box. */
    const cell_string_t *boxed = (const cell_string_t *)a.ptr;
    CHECK(boxed->len == 7);
    CHECK(cell_str_eq(cell_string_as_str(boxed), cell_str_from_cstr("glue-me")));

    cell_arc_drop(a);
}

static void test_arc_from_slice_roundtrip(void) {
    const size_t esz = sizeof(int64_t);
    cell_slice_t s = cell_slice_alloc(esz, 4);
    for (int64_t i = 0; i < 4; ++i) {
        CHECK(cell_slice_push(&s, esz, &i));
    }

    cell_arc_t a = cell_arc_from_slice(s);
    CHECK(a.ptr != NULL);
    CHECK(a.drop == cell_slice_drop_glue);
    CHECK(cell_arc_strong_count(a) == 1);

    const cell_slice_t *boxed = (const cell_slice_t *)a.ptr;
    CHECK(boxed->len == 4);
    for (size_t i = 0; i < boxed->len; ++i) {
        const int64_t *slot = (const int64_t *)cell_slice_at(boxed, esz, i);
        CHECK(slot != NULL);
        if (slot != NULL) CHECK(*slot == (int64_t)i);
    }

    cell_arc_drop(a);
}

/*
 * "The strong count reached zero" is not evidence the glue actually freed
 * anything: a glue that frees only the box, or only the payload, still
 * drives the count to zero and never crashes on its own. These two tests
 * prove BOTH halves were really released by asking the allocator for blocks
 * of the exact sizes just freed, immediately afterward and in the same order
 * the glue itself frees things (payload buffer first, then box), with no
 * other allocation in between.
 *
 * This harness links plain libc malloc/free, no interposition and no
 * sanitizer, so a freshly freed small block is handed straight back to the
 * very next request for a matching size on this toolchain, as long as
 * nothing else allocates in between. A glue that leaks either half leaves
 * that address still live, so the allocator is forced to hand out fresh
 * memory instead of the address that was just supposedly freed, and the
 * comparison below fails. Verified empirically, and by deliberately
 * breaking each half in turn: see task-4a-report.md.
 *
 * WHICH DIRECTION THIS FAILS IN, now MEASURED rather than reasoned. The
 * heuristic above is not guaranteed by the C standard, so the question that
 * decides whether it is worth having is what happens when it stops holding.
 * Built with Apple clang and `-fsanitize=address`, this harness exits 1 with
 * exactly two failures, `buf_freed` here and its slice twin, and NO
 * AddressSanitizer error: the code is clean and ASan's quarantine simply
 * refuses to hand a freed block straight back. So a broken allocator
 * assumption costs a FALSE FAILURE on correct code, loudly, and can never
 * produce a silent pass on broken code, because a leaked block is still live
 * and malloc cannot return a live block.
 *
 * That asymmetry is the whole argument for keeping this test. Earlier notes
 * called the ASan half "reasoned, not reproduced", because `zig cc
 * -fsanitize=address` would not link in the environments that tried it. Plain
 * `cc` does link it, and the measurement above is that run.
 */
static void test_arc_string_glue_frees_both_halves(void) {
    cell_string_t s = cell_string_from_cstr("dropme!");
    char *buf_addr = s.ptr;
    size_t buf_cap = s.cap;

    cell_arc_t a = cell_arc_from_string(s);
    void *box_addr = a.ptr;

    cell_arc_t b = cell_arc_clone(a);
    CHECK(cell_arc_strong_count(a) == 2);

    cell_arc_drop(b);
    CHECK(cell_arc_strong_count(a) == 1);

    /* Pointee is still readable at count 1: the glue has not run yet. */
    const cell_string_t *still = (const cell_string_t *)a.ptr;
    CHECK(cell_str_eq(cell_string_as_str(still), cell_str_from_cstr("dropme!")));

    cell_arc_drop(a); /* last release: cell_string_drop_glue runs here */

    void *reuse_buf = malloc(buf_cap);
    void *reuse_box = malloc(sizeof(cell_string_t));
    bool buf_freed = (reuse_buf == buf_addr);
    bool box_freed = (reuse_box == box_addr);

    /*
     * The buffer probe runs first (matching the order the glue itself frees
     * things, per the comment above), so only ITS result is unconditionally
     * trustworthy: if the buffer genuinely leaked, no allocator behavior can
     * make `reuse_buf` come back equal to `buf_addr`, because that block is
     * still live. Report that leak on its own merits.
     *
     * The box probe runs second, and a leaked buffer can make it lie: when
     * `malloc(buf_cap)` cannot satisfy the request from the buffer's own
     * free list, it has to look elsewhere, and on this allocator that
     * observably perturbs the box's size-class free list too (verified
     * directly: temporarily making the glue leak only the buffer makes
     * BOTH `buf_freed` and `box_freed` come back false, even though the box
     * was freed correctly). So the box probe is asserted only once the
     * buffer probe has proven the buffer side clean; at that point nothing
     * has disturbed the box's free list and its probe is a clean
     * discriminator. If the buffer leaked, the box probe is skipped rather
     * than asserted, so a failure here never blames the box for damage the
     * buffer's own leak caused; the buffer CHECK below already fails the
     * suite on its own.
     */
    CHECK(buf_freed);
    if (buf_freed) CHECK(box_freed);

    free(reuse_buf);
    free(reuse_box);
}

static void test_arc_slice_glue_frees_both_halves(void) {
    const size_t esz = sizeof(int64_t);
    /* cap 1 so the buffer (8 bytes) and the box (24 bytes) fall in different
       allocator size classes and cannot be confused with one another. */
    cell_slice_t s = cell_slice_alloc(esz, 1);
    int64_t v = 99;
    CHECK(cell_slice_push(&s, esz, &v));
    void *buf_addr = s.ptr;
    size_t buf_bytes = esz * s.cap;

    cell_arc_t a = cell_arc_from_slice(s);
    void *box_addr = a.ptr;

    cell_arc_t b = cell_arc_clone(a);
    CHECK(cell_arc_strong_count(a) == 2);

    cell_arc_drop(b);
    CHECK(cell_arc_strong_count(a) == 1);

    const cell_slice_t *still = (const cell_slice_t *)a.ptr;
    CHECK(still->len == 1);

    cell_arc_drop(a); /* last release: cell_slice_drop_glue runs here */

    void *reuse_buf = malloc(buf_bytes);
    void *reuse_box = malloc(sizeof(cell_slice_t));
    bool buf_freed = (reuse_buf == buf_addr);
    bool box_freed = (reuse_box == box_addr);

    /* See the comment on the string version of this test above: the buffer
       probe's result is unconditionally trustworthy, but a leaked buffer can
       make the box probe lie, so the box probe is asserted only once the
       buffer has been proven clean. */
    CHECK(buf_freed);
    if (buf_freed) CHECK(box_freed);

    free(reuse_buf);
    free(reuse_box);
}

static void test_drop_glue_null_is_noop(void) {
    /* Must not crash. Reaching the CHECK below (and every test after it) is
       the proof; a crash here would abort the whole harness instead of
       failing one assertion. */
    cell_string_drop_glue(NULL);
    cell_slice_drop_glue(NULL);
    CHECK(true);
}

/* ------------------------------------------------------------------------ */
/* String                                                                    */
/* ------------------------------------------------------------------------ */

static void test_str_views(void) {
    cell_str_t hello = cell_str_from_cstr("hello");
    CHECK(hello.len == 5);
    CHECK(hello.ptr != NULL);

    CHECK(cell_str_eq(hello, cell_str_from_cstr("hello")));
    CHECK(!cell_str_eq(hello, cell_str_from_cstr("hellO")));
    CHECK(!cell_str_eq(hello, cell_str_from_cstr("hell")));

    cell_str_t empty = cell_str_empty();
    CHECK(empty.len == 0);
    CHECK(empty.ptr == NULL);
    CHECK(cell_str_eq(empty, cell_str_from_cstr("")));
    CHECK(cell_str_eq(empty, cell_str_from_cstr(NULL)));

    /* The whole point of carrying a length: embedded NUL bytes survive. */
    static const char raw[3] = { 'a', '\0', 'b' };
    cell_str_t withnul = cell_str_from_parts(raw, sizeof(raw));
    CHECK(withnul.len == 3);
    CHECK(!cell_str_eq(withnul, cell_str_from_cstr("a")));
}

static void test_owned_string(void) {
    cell_string_t s = cell_string_from_cstr("cell");
    CHECK(s.ptr != NULL);
    CHECK(s.len == 4);
    CHECK(s.cap == 5);
    CHECK(s.ptr[s.len] == '\0');
    CHECK(cell_str_eq(cell_string_as_str(&s), cell_str_from_cstr("cell")));

    /* copy String is a deep copy: same bytes, independent buffer. */
    cell_string_t clone = cell_string_clone(&s);
    CHECK(clone.ptr != NULL);
    CHECK(clone.ptr != s.ptr);
    CHECK(cell_str_eq(cell_string_as_str(&clone), cell_string_as_str(&s)));

    clone.ptr[0] = 'b';
    CHECK(!cell_str_eq(cell_string_as_str(&clone), cell_string_as_str(&s)));

    cell_string_free(&clone);
    CHECK(clone.ptr == NULL);
    CHECK(clone.len == 0);
    CHECK(clone.cap == 0);
    /* Freeing a zeroed string is safe. */
    cell_string_free(&clone);

    cell_string_free(&s);
    CHECK(s.ptr == NULL);

    /* An empty owned string still has a valid, NUL-terminated buffer. */
    cell_string_t e = cell_string_from_str(cell_str_empty());
    CHECK(e.ptr != NULL);
    CHECK(e.len == 0);
    CHECK(e.cap == 1);
    CHECK(e.ptr[0] == '\0');
    cell_string_free(&e);

    CHECK(cell_string_clone(NULL).ptr == NULL);
    CHECK(cell_str_eq(cell_string_as_str(NULL), cell_str_empty()));
}

/* ------------------------------------------------------------------------ */
/* Lists                                                                     */
/* ------------------------------------------------------------------------ */

static void test_slice(void) {
    cell_slice_t empty = cell_slice_empty();
    CHECK(empty.ptr == NULL);
    CHECK(empty.len == 0);
    CHECK(empty.cap == 0);

    const size_t esz = sizeof(int64_t);
    cell_slice_t s = cell_slice_alloc(esz, 4);
    CHECK(s.ptr != NULL);
    CHECK(s.len == 0);
    CHECK(s.cap == 4);

    /* Push past the initial capacity to force a realloc. */
    for (int64_t i = 0; i < 10; ++i) {
        CHECK(cell_slice_push(&s, esz, &i));
    }
    CHECK(s.len == 10);
    CHECK(s.cap >= 10);

    for (size_t i = 0; i < s.len; ++i) {
        int64_t *slot = (int64_t *)cell_slice_at(&s, esz, i);
        CHECK(slot != NULL);
        if (slot != NULL) CHECK(*slot == (int64_t)i);
    }

    CHECK(cell_slice_at(&s, esz, s.len) == NULL);
    CHECK(cell_slice_at(&s, esz, SIZE_MAX) == NULL);
    CHECK(cell_slice_at(NULL, esz, 0) == NULL);

    /* Reserving below the current capacity is a successful no-op. */
    size_t cap_before = s.cap;
    CHECK(cell_slice_reserve(&s, esz, 1));
    CHECK(s.cap == cap_before);

    CHECK(cell_slice_reserve(&s, esz, cap_before + 100));
    CHECK(s.cap >= cap_before + 100);

    cell_slice_free(&s);
    CHECK(s.ptr == NULL);
    CHECK(s.len == 0);
    CHECK(s.cap == 0);
    /* Freeing a zeroed slice is safe. */
    cell_slice_free(&s);

    /* Degenerate and overflowing requests fail cleanly. */
    CHECK(cell_slice_alloc(0, 8).ptr == NULL);
    CHECK(cell_slice_alloc(esz, 0).ptr == NULL);
    CHECK(cell_slice_alloc(SIZE_MAX, 4).ptr == NULL);

    cell_slice_t z = cell_slice_empty();
    CHECK(!cell_slice_reserve(&z, esz, SIZE_MAX));
    CHECK(!cell_slice_reserve(NULL, esz, 4));
    CHECK(!cell_slice_push(&z, esz, NULL));
    CHECK(z.ptr == NULL);
}

/* ------------------------------------------------------------------------ */
/* Optionals                                                                 */
/* ------------------------------------------------------------------------ */

static void test_optionals(void) {
    cell_opt_i64_t some = cell_opt_i64_some(-9001);
    CHECK(some.has_value);
    CHECK(some.value == -9001);

    cell_opt_i64_t none = cell_opt_i64_none();
    CHECK(!none.has_value);

    /* The cases a sentinel representation could not express. */
    cell_opt_i64_t zero = cell_opt_i64_some(0);
    CHECK(zero.has_value);
    CHECK(zero.value == 0);

    cell_opt_i64_t neg1 = cell_opt_i64_some(-1);
    CHECK(neg1.has_value);
    CHECK(neg1.value == -1);

    cell_opt_ptr_t nullsome = cell_opt_ptr_some(NULL);
    CHECK(nullsome.has_value);
    CHECK(nullsome.value == NULL);
    CHECK(!cell_opt_ptr_none().has_value);

    cell_opt_bool_t bfalse = cell_opt_bool_some(false);
    CHECK(bfalse.has_value);
    CHECK(bfalse.value == false);

    cell_opt_f64_t f = cell_opt_f64_some(2.5);
    CHECK(f.has_value);
    CHECK(f.value == 2.5);
    CHECK(!cell_opt_f64_none().has_value);

    cell_opt_str_t st = cell_opt_str_some(cell_str_from_cstr("hi"));
    CHECK(st.has_value);
    CHECK(cell_str_eq(st.value, cell_str_from_cstr("hi")));

    cell_opt_str_t sn = cell_opt_str_none();
    CHECK(!sn.has_value);
    CHECK(sn.value.ptr == NULL);
    CHECK(sn.value.len == 0);

    CHECK(!cell_opt_byte_none().has_value);
    CHECK(cell_opt_u64_some(0u).has_value);
    CHECK(cell_opt_i32_some(-3).value == -3);
}

/* ------------------------------------------------------------------------ */
/* Result                                                                    */
/* ------------------------------------------------------------------------ */

static void test_result(void) {
    /* Result<Int, E> carries its payload inline, with no boxing. */
    cell_result_t ok = cell_ok_i64(INT64_MIN);
    CHECK(ok.ok);
    CHECK(ok.error_code == 0);
    CHECK(ok.value.i64 == INT64_MIN);

    cell_result_t okmax = cell_ok_i64(INT64_MAX);
    CHECK(okmax.value.i64 == INT64_MAX);

    cell_result_t err = cell_err(-3);
    CHECK(!err.ok);
    CHECK(err.error_code == -3);

    cell_result_t unit = cell_ok_unit();
    CHECK(unit.ok);
    CHECK(unit.error_code == 0);

    cell_result_t f = cell_ok_f64(1.25);
    CHECK(f.ok);
    CHECK(f.value.f64 == 1.25);

    cell_result_t u = cell_ok_u64(UINT64_MAX);
    CHECK(u.value.u64 == UINT64_MAX);

    cell_result_t b = cell_ok_bool(false);
    CHECK(b.ok);
    CHECK(b.value.b == false);

    int marker = 0;
    cell_result_t p = cell_ok_ptr(&marker);
    CHECK(p.ok);
    CHECK(p.value.ptr == &marker);

    cell_result_t s = cell_ok_str(cell_str_from_cstr("payload"));
    CHECK(s.ok);
    CHECK(cell_str_eq(s.value.str, cell_str_from_cstr("payload")));
}

/* ------------------------------------------------------------------------ */
/* Host intrinsics and weak bridge fallbacks                                 */
/* ------------------------------------------------------------------------ */

static void test_intrinsics(void) {
    /*
     * cell_print writes to stdout, so this asserts linkage and non-crashing
     * behavior rather than captured output. The false branch of cell_assert
     * aborts by design and is therefore not exercised here.
     */
    cell_print(cell_str_from_cstr("cell_rt self test"));
    cell_print(cell_str_empty());
    cell_println(cell_str_from_cstr("cell_rt self test (println)"));
    cell_assert(true);
    cell_assert_msg(true, cell_str_from_cstr("not reached"));
    CHECK(true);
}

static void test_weak_bridge_fallbacks(void) {
    /* cell_rt.cpp and CellBridge.swift are not linked into this harness, so
     * the weak stubs in cell_rt.c must be what resolves. */
    CHECK(cell_cxx_probe() == 0);
    CHECK(cell_swift_probe() == 0);
}

/* ------------------------------------------------------------------------ */

int main(void) {
    test_version();
    test_arena_alignment();
    test_arena_exhaustion();
    test_arena_overflow();
    test_arc_retain_release();
    test_arc_null_cases();
    test_arc_is_atomic();
    test_arc_from_string_roundtrip();
    test_arc_from_slice_roundtrip();
    test_arc_string_glue_frees_both_halves();
    test_arc_slice_glue_frees_both_halves();
    test_drop_glue_null_is_noop();
    test_str_views();
    test_owned_string();
    test_slice();
    test_optionals();
    test_result();
    test_intrinsics();
    test_weak_bridge_fallbacks();

    if (g_failures != 0) {
        fprintf(stderr, "cell_rt tests: %d/%d checks FAILED\n", g_failures, g_checks);
        return 1;
    }
    fprintf(stderr, "cell_rt tests: %d checks passed\n", g_checks);
    return 0;
}
