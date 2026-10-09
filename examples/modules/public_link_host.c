#include <stdint.h>
typedef struct { int64_t x; } cell_geo_Point;
extern int64_t cell_geo_area(cell_geo_Point point);
int main(void) { return cell_geo_area((cell_geo_Point){21}) == 42 ? 0 : 1; }
