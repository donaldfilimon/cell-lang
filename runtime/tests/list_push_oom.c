/* One subprocess per typed writer. The gate requires panic/abort on OOM. */
#include "cell_rt.h"

#include <stddef.h>
#include <string.h>

void *cell_test_realloc(void *ptr, size_t size) {
    (void)ptr;
    (void)size;
    return NULL;
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    cell_slice_t xs = cell_slice_empty();
    if (strcmp(argv[1], "byte") == 0) cell_bytes_push(&xs, 1);
    else if (strcmp(argv[1], "i64") == 0) cell_list_i64_push(&xs, 1);
    else if (strcmp(argv[1], "i32") == 0) cell_list_i32_push(&xs, 1);
    else if (strcmp(argv[1], "f64") == 0) cell_list_f64_push(&xs, 1.0);
    else if (strcmp(argv[1], "bool") == 0) cell_list_bool_push(&xs, true);
    else return 2;
    return 0; /* A failed push must never return a shortened list. */
}
