/*
 * Host for examples/move_after_branch.cell. `cell_take` returns the length
 * of the String it is handed and frees it, so a caller that already freed
 * the value (a zeroed header) makes it return 0 and changes the printed
 * total. That is the whole measurement: before the fix, the C backend
 * released these values at the end of every branch of an unrelated
 * `if`/`match` and the later move handed over an empty header, which
 * AddressSanitizer does not report because free(NULL) is legal.
 */

#include "cell_rt.h"

int64_t cell_take(cell_string_t s);
cell_string_t cell_make(void);

int64_t cell_take(cell_string_t s) {
    const int64_t n = (int64_t)s.len;
    cell_string_free(&s);
    return n;
}

cell_string_t cell_make(void) {
    return cell_string_from_str(cell_str_from_cstr("abcdefg"));
}
