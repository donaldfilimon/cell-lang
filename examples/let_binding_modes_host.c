/*
 * The C side of examples/let_binding_modes.cell's three bodyless declarations.
 *
 * WHY A HOST RATHER THAN CELL BODIES. What the example measures is which
 * ADDRESS a `let` binding hands over, and only the callee can answer that: a
 * Cell body sees whatever it was given and has no way to say whether that was
 * the caller's object or a copy of it. For the `shared` spellings the address
 * is the ONLY observable at all, because Cell forbids mutating a lender while
 * it is shared-borrowed, so a `shared` binding that is secretly a copy cannot
 * be caught by any Cell-side read.
 *
 * This is deliberately a SEPARATE translation unit from write_through_host.c
 * rather than a shared one. Its `seen` table is static, and two examples
 * sharing one table would make each one's `distinct()` depend on whether the
 * other had run in the same process. They are linked into different programs
 * today, and a shared table would turn that into a fact the gate depends on
 * without saying so.
 *
 * It lives in examples/ beside the file it serves. The corpus loops in
 * tools/check.sh and examples/README.md all glob `*.cell`, so a `.c` file here
 * is invisible to them and cannot become a corpus entry; stages 8 and 9 find
 * it by the `<stem>_host.c` convention, which is why the name must stay in
 * step with the example's.
 *
 * Both definitions honour runtime/cell_rt.h section 7 exactly:
 *
 *   exclusive  a mutable borrow, `cell_Buffer *`. The callee may mutate the
 *              caller's value and must not free it. So cell_grow writes.
 *   shared     "Callee must not free or mutate", `const cell_Buffer *`. So
 *              cell_look only records the pointer.
 *
 * The struct is redeclared here rather than included from the emitted header,
 * because the emitted C, the emitted LLVM IR and the emitted MLIR are three
 * different files and this host is linked against all three. A separate
 * translation unit declaring a compatible struct is exactly what the C ABI
 * this language targets is for.
 */

#include "cell_rt.h"

typedef struct cell_Buffer {
    int64_t len;
} cell_Buffer;

/*
 * Every address the Cell side has handed over, deduplicated. Sixteen is more
 * than the nine calls the example makes, so a backend that copies at EVERY
 * call site still fits and still reports an honest count rather than
 * saturating at the correct answer.
 */
#define SEEN_MAX 16
static const cell_Buffer *seen[SEEN_MAX];
static int64_t seen_count;

static void record(const cell_Buffer *b) {
    for (int64_t i = 0; i < seen_count; i++) {
        if (seen[i] == b) return;
    }
    if (seen_count < SEEN_MAX) seen[seen_count++] = b;
}

/* A unique borrow: record the address, then mutate through it. */
void cell_grow(cell_Buffer *b) {
    record(b);
    b->len += 1;
}

/* A shared borrow: record the address, mutate nothing, free nothing. */
void cell_look(const cell_Buffer *b) {
    record(b);
}

int64_t cell_distinct(void) {
    return seen_count;
}
