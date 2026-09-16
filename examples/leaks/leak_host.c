/*
 * The real `main` for every fixture in this directory when it runs under the
 * gate's leak stage. It exists to defeat one specific false negative.
 *
 * `leaks -atExit` is a conservative scanner: a heap block is "reachable" if
 * any word on the stack or in a register still holds its address at exit.
 * When a fixture's `main` returns straight into exit, the last iteration's
 * three boxes are usually still pointed at by a stale stack slot, so the tool
 * reports 2997 for a program that leaks 3000 (tools/check.sh's header note on
 * the leaks stage carries both measurements that proved this on 2026-09-08).
 *
 * The fix is to make the program's stack dead before the scan runs. The
 * emitted C is compiled with `-Dmain=cell_program_main`, this file's `main`
 * calls it, and then a recursive function overwrites several stack frames'
 * worth of memory with a volatile fill so no stale pointer survives. The
 * program's own return code is preserved.
 *
 * This is deliberately NOT part of the execution stage: it changes nothing
 * about what the program computes, only what a conservative scanner can see
 * afterwards, and it must be compiled as its own translation unit so the
 * rename does not touch this `main`. examples/leaks/malloc_counter.{h,c} is
 * the independent witness that the number this host lets `leaks` see is the
 * true one.
 */

#include <stddef.h>

int cell_program_main(void);

/*
 * 4 KB per frame, eight frames deep: comfortably more stack than any fixture
 * here touches. `volatile` keeps the fill from being optimised away and the
 * recursion keeps each frame at a distinct address.
 */
static void clobber_stack(int depth) {
    volatile unsigned char frame[4096];
    for (size_t i = 0; i < sizeof frame; i++) {
        frame[i] = (unsigned char)depth;
    }
    if (depth > 0) {
        clobber_stack(depth - 1);
    }
}

int main(void) {
    int rc = cell_program_main();
    clobber_stack(8);
    return rc;
}
