/*
 * The C side of examples/exclusive_aggregates.cell's nine bodyless
 * declarations.
 *
 * WHY THIS FILE EXISTS RATHER THAN BODIES IN THE .cell FILE. The example
 * measures whether an `exclusive String`, `[T]` and `T?` cross the C ABI as
 * POINTERS, the way runtime/cell_rt.h section 7 says they must. Only a C
 * translation unit compiled by the system compiler can answer that: it is the
 * clang-declared signature the emitted code has to match, and a Cell body
 * would be built by the same backend that is under test.
 *
 * It lives beside the file it serves, under the `<stem>_host.c` convention
 * arc_host.c and write_through_host.c already share. The corpus loops in
 * tools/check.sh and examples/README.md glob `*.cell`, so a `.c` here cannot
 * accidentally become a corpus entry of its own.
 *
 * Every signature below is written from cell_rt.h section 7 directly:
 *
 *   exclusive String  cell_string_t *      a mutable borrow of the OWNING
 *                                          24-byte buffer, not the 16-byte
 *                                          view. The callee may mutate the
 *                                          caller's value and must not free
 *                                          it.
 *   exclusive [T]     cell_slice_t *
 *   exclusive Int?    cell_opt_i64_t *
 *
 * The three observers therefore take pointers and READ THROUGH them. If the
 * emitted code passed the aggregate by value instead, this file would receive
 * the first two words of that value where it expects an address and would
 * dereference them, which is a crash rather than a wrong number. That is the
 * intended failure: the example prints one integer, and a backend that gets
 * the ABI wrong cannot reach the print.
 *
 * NOTHING HERE FREES ANYTHING. `reset_str` overwrites the caller's string with
 * a second heap buffer and neither backend inserts a drop for a borrowed
 * binding, so the first buffer leaks by design for the length of one process.
 * A free here would be a double free the moment drop insertion reaches this
 * shape, and the example exists to measure a write, not a lifetime.
 */

#include "cell_rt.h"

#include <stdlib.h>

/* -- String. 3 characters before the write, 20 after. --------------------- */

cell_string_t cell_first_str(void) {
    return cell_string_from_cstr("abc");
}

cell_string_t cell_second_str(void) {
    return cell_string_from_cstr("abcdefghijklmnopqrst");
}

int64_t cell_str_len(cell_string_t *s) {
    return (int64_t)s->len;
}

/* -- [Int]. 4 elements before the write, 300 after. ------------------------ */

static cell_slice_t make_list(size_t n) {
    cell_slice_t xs = cell_slice_alloc(sizeof(int64_t), n);
    int64_t *elems = (int64_t *)xs.ptr;
    for (size_t i = 0; i < n; i++) elems[i] = (int64_t)i;
    xs.len = n;
    return xs;
}

cell_slice_t cell_first_list(void) {
    return make_list(4);
}

cell_slice_t cell_second_list(void) {
    return make_list(300);
}

int64_t cell_list_len(cell_slice_t *xs) {
    return (int64_t)xs->len;
}

/* -- Int?. Some(5) before the write, Some(7000) after. -------------------- */

cell_opt_i64_t cell_first_opt(void) {
    return cell_opt_i64_some(5);
}

cell_opt_i64_t cell_second_opt(void) {
    return cell_opt_i64_some(7000);
}

/*
 * `-1` for a `None` rather than `0`, so a backend that hands over a zeroed
 * aggregate is distinguishable from one that hands over a correct
 * `Some(0)`. The example never produces a None, and that is exactly why the
 * sentinel has to be unreachable arithmetic rather than a plausible value.
 */
int64_t cell_opt_val(cell_opt_i64_t *o) {
    return o->has_value ? o->value : -1;
}
