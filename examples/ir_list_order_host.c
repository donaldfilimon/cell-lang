#include "cell_rt.h"

#include <stdint.h>

static int64_t calls;

int64_t cell_mark(int64_t value) {
    calls = calls * 10 + value;
    return value;
}

int64_t cell_order(void) { return calls; }
