#include <stdint.h>
extern int64_t cell_geo_twice(int64_t value);
int main(void) { return cell_geo_twice(21) == 42 ? 0 : 1; }
