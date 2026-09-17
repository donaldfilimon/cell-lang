/*
 * Host for examples/loop_revive_read.cell. `cell_sink` takes an owned
 * String, returns its length and frees it; `cell_view_len` reads a view.
 * A String released early reads as length 0, which changes the total.
 */

#include "cell_rt.h"

int64_t cell_sink(cell_string_t s);
int64_t cell_view_len(cell_str_t s);
cell_string_t cell_digits(int64_t v);

int64_t cell_sink(cell_string_t s) {
    const int64_t n = (int64_t)s.len;
    cell_string_free(&s);
    return n;
}

int64_t cell_view_len(cell_str_t s) {
    return (int64_t)s.len;
}

/* v + 1 copies of 'x', so each revival has a distinct, known length. */
cell_string_t cell_digits(int64_t v) {
    static const char xs[] = "xxxxxxxxxxxxxxxx";
    size_t n = (size_t)(v + 1);
    if (n > sizeof xs - 1) n = sizeof xs - 1;
    return cell_string_from_str(cell_str_from_parts(xs, n));
}
