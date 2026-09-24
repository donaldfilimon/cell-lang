/*
 * Host for examples/ir_index.cell. No Cell constructor builds an [Int],
 * [Int32], [Float] or [Bool] outside a list literal, and list literals are
 * refused by the LLVM and MLIR backends until IR step (d), so the lists come
 * from here. Each returns a fresh heap list the caller owns (runtime/cell_rt.h
 * section 7), built through the same `cell_slice_push` the runtime uses.
 */

#include "cell_rt.h"

cell_slice_t cell_host_ints(void);
cell_slice_t cell_host_i32s(void);
cell_slice_t cell_host_floats(void);
cell_slice_t cell_host_bools(void);

static cell_slice_t build(size_t elem, const void *items, size_t n) {
    cell_slice_t s = cell_slice_empty();
    for (size_t i = 0; i < n; i++) {
        if (!cell_slice_push(&s, elem, (const char *)items + i * elem)) cell_panic(cell_str_from_cstr("host list: out of memory"));
    }
    return s;
}

cell_slice_t cell_host_ints(void) {
    static const int64_t v[] = {3, 40, 2};
    return build(sizeof v[0], v, 3);
}

cell_slice_t cell_host_i32s(void) {
    static const int32_t v[] = {-5, 700};
    return build(sizeof v[0], v, 2);
}

cell_slice_t cell_host_floats(void) {
    static const double v[] = {2.5, 0.25};
    return build(sizeof v[0], v, 2);
}

cell_slice_t cell_host_bools(void) {
    static const bool v[] = {false, true};
    return build(sizeof v[0], v, 2);
}
