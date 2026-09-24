/* Inject realloc failure into the runtime's list-growth path only. */
#ifndef CELL_FAIL_LIST_ALLOC_H
#define CELL_FAIL_LIST_ALLOC_H

#include <stddef.h>
#include <stdlib.h>

void *cell_test_realloc(void *ptr, size_t size);
#define realloc(ptr, size) cell_test_realloc(ptr, size)

#endif
