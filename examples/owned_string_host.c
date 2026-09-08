/*
 * Host for examples/owned_string.cell, following the same convention as
 * examples/arc_host.c: the bodyless declarations there are external symbols,
 * and this file is where they live.
 *
 * The point of the file is `cell_take`. An `owned String` parameter is a
 * 24-byte `cell_string_t` passed BY VALUE with the callee owning the buffer
 * (runtime/cell_rt.h section 2 and section 7), so a correct caller hands over
 * a heap copy and a correct callee frees it. Freeing is therefore the
 * assertion: before the conversion existed, that argument was a 16-byte
 * `cell_str_t` view of a static string literal, and `cell_string_free` on
 * that is a free of a non-heap pointer, which AddressSanitizer reports. The
 * whole reason this example is run under the sanitizer rather than merely
 * compiled is that compiling was never the hard part.
 *
 * `cell_view_len` exists because no Cell body can read `cell_str_t.len`. It
 * is what turns the run into a measurement instead of an assertion that the
 * program did not crash: each conversion has a distinct length, so one that
 * produced an empty or a mis-sized value changes the printed total.
 */

#include "cell_rt.h"

int64_t cell_view_len(cell_str_t v);
int64_t cell_take(cell_string_t s);
cell_string_t cell_make(void);

int64_t cell_view_len(cell_str_t v) {
    return (int64_t)v.len;
}

int64_t cell_take(cell_string_t s) {
    const int64_t n = (int64_t)s.len;
    cell_string_free(&s);
    return n;
}

/* An owning value the caller then owns, so `var owned d = make()` has
 * something real to hold before the assignment overwrites it. */
cell_string_t cell_make(void) {
    return cell_string_from_str(cell_str_from_cstr("zz"));
}
