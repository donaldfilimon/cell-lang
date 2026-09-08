/*
 * The C side of examples/arc.cell's two bodyless declarations.
 *
 * WHY THIS FILE EXISTS RATHER THAN A BODY IN THE .cell FILE. `observe` and
 * `inspect` are declared without bodies in arc.cell because that is what the
 * example is demonstrating: the `arc` and `shared` calling conventions at the
 * C boundary, which only a C definition can be measured against. Giving them
 * Cell bodies would have made the file self-contained, but it would also have
 * made `observe` unable to read cell_arc_strong_count, and the strong count is
 * the whole point: without it the execution test would prove that the emitted
 * program does not crash, not that the retains are actually balanced.
 *
 * It lives in examples/ beside the file it serves. The corpus loops in
 * tools/check.sh and examples/README.md all glob `*.cell`, so a `.c` file here
 * is invisible to them and cannot accidentally become a corpus entry.
 *
 * Both definitions honour runtime/cell_rt.h section 7 exactly:
 *
 *   arc     "cell_arc_t by value. The caller has already retained; the callee
 *            releases when done, or clones to keep it." So cell_observe drops.
 *   shared  "Callee must not free or mutate." So cell_inspect only reads.
 *
 * That asymmetry is deliberate and it is what makes the counts balance. A Cell
 * function body would NOT release its `arc` parameter today, because the C
 * backend never drops a parameter (see codegen.zig's Local.droppable), so every
 * call-site retain into a Cell-bodied `arc` parameter leaks one reference. This
 * host is the ABI-correct implementation, not a workaround for that gap.
 */

#include "cell_rt.h"

/*
 * Report the strong count this call was handed, then release the reference the
 * caller retained for us. With the call-site clone in place the count reads 3
 * (the original, the `alias` handle, and this call's own retain) and returns to
 * 2 before this function does.
 */
int64_t cell_observe(cell_arc_t name) {
    size_t count = cell_arc_strong_count(name);
    cell_arc_drop(name);
    return (int64_t)count;
}

/* A borrowed view: read the length, retain nothing, free nothing. */
int64_t cell_inspect(cell_str_t name) {
    return (int64_t)name.len;
}
