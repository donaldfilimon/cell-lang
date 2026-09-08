/*
 * The C side of examples/write_through.cell's three bodyless declarations.
 *
 * WHY THIS FILE EXISTS RATHER THAN BODIES IN THE .cell FILE. What the example
 * measures is which ADDRESS a call site hands over for a borrow, and only the
 * callee can answer that: a Cell body would see whatever it was given and have
 * no way to say whether it was the caller's object or a copy of it. It also
 * keeps the example lowering through all three backends, since the MLIR
 * backend refuses assignment through a field path today and a Cell-bodied
 * `grow` would therefore be measurable in two backends instead of three.
 *
 * It lives in examples/ beside the file it serves, the same way arc_host.c
 * does. The corpus loops in tools/check.sh and examples/README.md all glob
 * `*.cell`, so a `.c` file here is invisible to them and cannot accidentally
 * become a corpus entry. tools/check.sh finds it by the `<stem>_host.c`
 * convention those two files already share.
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
 * this language targets is for, and it is the same boundary a Zig or Swift
 * caller would cross.
 */

#include "cell_rt.h"

typedef struct cell_Buffer {
    int64_t len;
} cell_Buffer;

/*
 * Every address the Cell side has handed over, deduplicated. Sixteen is more
 * than the seven calls the example makes, so a backend that copies at EVERY
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
