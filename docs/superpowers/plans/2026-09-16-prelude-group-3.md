# Prelude group 3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every declaration in `stdlib/prelude.cell` links and runs through `cell build`/`cell run`, with partial operations returning optionals.

**Architecture:** Implementations live in `runtime/cell_rt.c` with prototypes in a new "Prelude" section of `runtime/cell_rt.h`, spelled exactly as the C backend emits them (mangling `cell_<name>`, `shared String` as `cell_str_t`, `owned String` as `cell_string_t`, `[Byte]` as `cell_slice_t`, `exclusive [Byte]` as `cell_slice_t *`, `T?` as `cell_opt_<t>_t`, `arc String` as `cell_arc_t`). Group 2 is closed by moving the runtime to the length-prefixed string. A gate stage 13 diffs the emitted prelude prototypes against the header so the match cannot drift.

**Tech Stack:** C11 at `-Wall -Wextra -Werror`, Zig master host, `tools/check.sh`.

**Spec:** `docs/superpowers/specs/2026-09-16-optional-result-and-prelude-design.md`, section A. **Depends on the B plan (`2026-09-16-optional-result-values.md`) having landed**, because the corpus example matches optionals.

## Global Constraints

- All of the B plan's constraints (`-Dswift=false`, exit-code capture, named-test confirmation, no em dashes).
- Signatures are law: a prototype in the header must be byte-identical to the line `cell emit stdlib/prelude.cell` prints for that declaration. Task 5's stage enforces it.
- Partial operations return optionals (Donald's decision): absent on the conditions in the spec's table, never a panic, never a truncation.
- Every returned `owned String` or `owned [Byte]` is a fresh allocation the caller's drop pass releases; no static buffers are handed out.

---

### Task 1: Prelude signatures and the emitted-prototype oracle

**Files:**
- Modify: `stdlib/prelude.cell` (group 3 return types, the group 2 and group 3 header paragraphs)
- Create: `tools/prelude-signatures.sh`

**Interfaces:**
- Produces: `tools/prelude-signatures.sh <cell-binary>` prints every emitted prototype of `stdlib/prelude.cell`, one per line, sorted; exits 2 if emit fails.

- [ ] **Step 1: Change the partial signatures** in `stdlib/prelude.cell`

```cell
pub fn int32_from_int(copy v: Int) -> Int32?;
pub fn uint_from_int(copy v: Int) -> UInt?;
pub fn int_from_uint(copy v: UInt) -> Int?;
pub fn int_from_float(copy v: Float) -> Int?;
pub fn byte_from_int(copy v: Int) -> Byte?;
pub fn abs_int(copy v: Int) -> Int?;
pub fn rem_int(copy a: Int, copy b: Int) -> Int?;
pub fn str_byte_at(shared s: String, copy index: Int) -> Byte?;
pub fn bytes_at(shared xs: [Byte], copy index: Int) -> Byte?;
```

(`bytes_pop` already returns `Byte?`.) Above each, one doc line naming the absent condition from the spec's table, for example `/// None when index is outside 0..len-1.`

- [ ] **Step 2: The oracle script**

```sh
#!/bin/sh
# Print every prototype the C backend emits for stdlib/prelude.cell, one per
# line, sorted. runtime/cell_rt.h must contain each of these lines verbatim
# for a program calling the prelude to link; gate stage 13 checks that.
# Usage: tools/prelude-signatures.sh ./zig-out/bin/cell
cell=${1:?cell binary}
cd "$(dirname "$0")/.." || exit 2
"$cell" emit stdlib/prelude.cell > /private/tmp/prelude-emit.c 2>/private/tmp/prelude-emit.err || {
    cat /private/tmp/prelude-emit.err >&2; exit 2; }
# A prototype is a line that ends in `);` and starts with a type, not a brace
# or a comment. `cell_cxx_probe`/`cell_swift_probe` are group 1 probes and
# stay in the list on purpose: they must match too.
grep -E '^[a-z_0-9 *]+ \*?cell_[a-z_0-9]+\(.*\);$' /private/tmp/prelude-emit.c | sort
```

`chmod +x tools/prelude-signatures.sh`. Run it after `zig build -Dswift=false` and read the list; it is the contract Task 2 to 4 implement. Copy the printed lines into a scratch file; each header prototype below must equal its line.

- [ ] **Step 3: Commit**

```bash
git add stdlib/prelude.cell tools/prelude-signatures.sh
git commit -m "prelude: partial operations return optionals; emitted-prototype oracle script"
```

---

### Task 2: Output, numeric conversion and helpers

**Files:**
- Modify: `runtime/cell_rt.h` (new section "Prelude (stdlib/prelude.cell group 3)" after the intrinsics), `runtime/cell_rt.c`, `runtime/tests/test_cell_rt.c`

**Interfaces:**
- Produces (prototypes, must equal the oracle's lines):

```c
void cell_eprintln(cell_str_t msg);
int64_t cell_int_from_int32(int32_t v);
cell_opt_i32_t cell_int32_from_int(int64_t v);
cell_opt_u64_t cell_uint_from_int(int64_t v);
cell_opt_i64_t cell_int_from_uint(uint64_t v);
double cell_float_from_int(int64_t v);
cell_opt_i64_t cell_int_from_float(double v);
float cell_float32_from_float(double v);
double cell_float_from_float32(float v);
cell_opt_byte_t cell_byte_from_int(int64_t v);
int64_t cell_int_from_byte(uint8_t v);
cell_opt_i64_t cell_abs_int(int64_t v);
int64_t cell_min_int(int64_t a, int64_t b);
int64_t cell_max_int(int64_t a, int64_t b);
cell_opt_i64_t cell_rem_int(int64_t a, int64_t b);
double cell_abs_float(double v);
double cell_min_float(double a, double b);
double cell_max_float(double a, double b);
```

- [ ] **Step 1: Failing harness test** (new `static void test_prelude_numeric(void)` in `test_cell_rt.c`, called from `main` beside the others)

```c
static void test_prelude_numeric(void) {
    CHECK(cell_int_from_int32(-3) == -3);
    CHECK(cell_int32_from_int(7).has_value && cell_int32_from_int(7).value == 7);
    CHECK(!cell_int32_from_int((int64_t)INT32_MAX + 1).has_value);
    CHECK(!cell_uint_from_int(-1).has_value);
    CHECK(cell_uint_from_int(5).value == 5);
    CHECK(!cell_int_from_uint((uint64_t)INT64_MAX + 1).has_value);
    CHECK(cell_int_from_uint(9).value == 9);
    CHECK(cell_float_from_int(2) == 2.0);
    CHECK(cell_int_from_float(2.9).value == 2);
    CHECK(!cell_int_from_float(NAN).has_value);
    CHECK(!cell_int_from_float(INFINITY).has_value);
    CHECK(!cell_int_from_float(1e300).has_value);
    CHECK(cell_float32_from_float(0.5) == 0.5f);
    CHECK(cell_float_from_float32(0.5f) == 0.5);
    CHECK(cell_byte_from_int(255).value == 255);
    CHECK(!cell_byte_from_int(256).has_value);
    CHECK(!cell_byte_from_int(-1).has_value);
    CHECK(cell_int_from_byte(200) == 200);
    CHECK(cell_abs_int(-4).value == 4);
    CHECK(!cell_abs_int(INT64_MIN).has_value);
    CHECK(cell_min_int(1, 2) == 1 && cell_max_int(1, 2) == 2);
    CHECK(cell_rem_int(7, 3).value == 1);
    CHECK(cell_rem_int(-7, 3).value == -1);
    CHECK(!cell_rem_int(1, 0).has_value);
    CHECK(!cell_rem_int(INT64_MIN, -1).has_value);
    CHECK(cell_abs_float(-1.5) == 1.5);
    CHECK(cell_min_float(1.0, 2.0) == 1.0 && cell_max_float(1.0, 2.0) == 2.0);
}
```

Add `#include <math.h>` and `#include <stdint.h>` at the top of the harness if missing.

- [ ] **Step 2: Run to see it fail**

Run: `zig build test-runtime -Dswift=false > /private/tmp/rt.log 2>&1; echo "EXIT: $?"; grep -m3 'implicit\|error' /private/tmp/rt.log`
Expected: EXIT 1.

- [ ] **Step 3: Implement** (prototypes in the header's new section, bodies in `cell_rt.c`)

```c
void cell_eprintln(cell_str_t msg) {
    fwrite(msg.ptr, 1, msg.len, stderr);
    fputc('\n', stderr);
}

int64_t cell_int_from_int32(int32_t v) { return v; }

cell_opt_i32_t cell_int32_from_int(int64_t v) {
    if (v < INT32_MIN || v > INT32_MAX) return cell_opt_i32_none();
    return cell_opt_i32_some((int32_t)v);
}

cell_opt_u64_t cell_uint_from_int(int64_t v) {
    if (v < 0) return cell_opt_u64_none();
    return cell_opt_u64_some((uint64_t)v);
}

cell_opt_i64_t cell_int_from_uint(uint64_t v) {
    if (v > (uint64_t)INT64_MAX) return cell_opt_i64_none();
    return cell_opt_i64_some((int64_t)v);
}

double cell_float_from_int(int64_t v) { return (double)v; }

cell_opt_i64_t cell_int_from_float(double v) {
    /* 2^63 is exactly representable; INT64_MAX is not, so compare against
     * the power of two on the high side and the exact minimum on the low. */
    if (isnan(v) || isinf(v)) return cell_opt_i64_none();
    if (v >= 9223372036854775808.0 || v < -9223372036854775808.0) return cell_opt_i64_none();
    return cell_opt_i64_some((int64_t)v);
}

float cell_float32_from_float(double v) { return (float)v; }
double cell_float_from_float32(float v) { return (double)v; }

cell_opt_byte_t cell_byte_from_int(int64_t v) {
    if (v < 0 || v > 255) return cell_opt_byte_none();
    return cell_opt_byte_some((uint8_t)v);
}

int64_t cell_int_from_byte(uint8_t v) { return v; }

cell_opt_i64_t cell_abs_int(int64_t v) {
    if (v == INT64_MIN) return cell_opt_i64_none();
    return cell_opt_i64_some(v < 0 ? -v : v);
}

int64_t cell_min_int(int64_t a, int64_t b) { return a < b ? a : b; }
int64_t cell_max_int(int64_t a, int64_t b) { return a > b ? a : b; }

cell_opt_i64_t cell_rem_int(int64_t a, int64_t b) {
    if (b == 0 || (a == INT64_MIN && b == -1)) return cell_opt_i64_none();
    return cell_opt_i64_some(a % b);
}

double cell_abs_float(double v) { return fabs(v); }
double cell_min_float(double a, double b) { return a < b ? a : b; }
double cell_max_float(double a, double b) { return a > b ? a : b; }
```

`cell_rt.c` needs `#include <math.h>`; `cell_opt_i32`/`u64`/`byte` constructors are the header's predefined instances (`CELL_DEFINE_OPTIONAL` block). Link `-lm` if the platform needs it: on macOS `cc` links libm by default; if `zig build test-runtime` fails to link `fabs`, add `rt_test_mod.linkSystemLibrary("m", .{})` and the same on `exe_mod`/`test_exe_mod` in `build.zig`, and add `-lm` to `ccArgv` in `src/main.zig` and to the gate's link lines.

- [ ] **Step 4: Run**

Run: `zig build test-runtime -Dswift=false > /private/tmp/rt.log 2>&1; echo "EXIT: $?"; grep -c FAIL /private/tmp/rt.log`
Expected: EXIT 0, 0 FAIL lines.

- [ ] **Step 5: Commit**

```bash
git add runtime/cell_rt.h runtime/cell_rt.c runtime/tests/test_cell_rt.c
git commit -m "runtime: prelude output, numeric conversion and helpers"
```

---

### Task 3: Strings, and group 2 closed

**Files:**
- Modify: `runtime/cell_rt.h`, `runtime/cell_rt.c`, `runtime/tests/test_cell_rt.c`, `stdlib/prelude.cell` (group 2 paragraph)

**Interfaces:**
- Produces:

```c
int64_t cell_str_len(cell_str_t s);
bool cell_str_eq(cell_str_t a, cell_str_t b);   /* the existing static inline helper becomes this export; see the note below */
cell_string_t cell_str_concat(cell_str_t a, cell_str_t b);
cell_opt_byte_t cell_str_byte_at(cell_str_t s, int64_t index);
cell_string_t cell_str_from_int(int64_t v);
cell_string_t cell_str_from_float(double v);
cell_string_t cell_str_from_bool(bool v);
cell_string_t cell_rt_version(void);
void cell_panic(cell_str_t msg) __attribute__((noreturn));
```

**Name collision, resolved before writing code:** the header already has `static inline bool cell_str_eq(cell_str_t a, cell_str_t b)` (line ~184), and the prelude's `str_eq` mangles to exactly `cell_str_eq`. The emitted prototype `bool cell_str_eq(cell_str_t a, cell_str_t b);` is compatible with a `static inline` definition of the same signature in the same translation unit? No: a non-static prototype after a `static inline` definition is a conflicting linkage error. So the existing helper becomes the prelude function: remove `static inline` from `cell_str_eq` in the header, keep its body in `cell_rt.c` as an ordinary exported function, so the prototype above is the existing name. The `cell_str_eq` callers in codegen (string patterns) keep working. Check `grep -rn cell_str_eq src runtime` before and after.

- [ ] **Step 1: Failing harness test**

```c
static void test_prelude_strings(void) {
    cell_str_t hi = cell_str_from_cstr("hi");
    cell_str_t hi2 = cell_str_from_cstr("hi");
    CHECK(cell_str_len(hi) == 2);
    CHECK(cell_str_eq(hi, hi2));
    cell_string_t cat = cell_str_concat(hi, cell_str_from_cstr("!"));
    CHECK(cat.len == 3 && memcmp(cat.ptr, "hi!", 3) == 0);
    cell_string_free(&cat);
    CHECK(cell_str_byte_at(hi, 1).value == 'i');
    CHECK(!cell_str_byte_at(hi, 2).has_value);
    CHECK(!cell_str_byte_at(hi, -1).has_value);
    cell_string_t n = cell_str_from_int(-42);
    CHECK(n.len == 3 && memcmp(n.ptr, "-42", 3) == 0);
    cell_string_free(&n);
    cell_string_t f = cell_str_from_float(1.5);
    CHECK(f.len == 3 && memcmp(f.ptr, "1.5", 3) == 0);
    cell_string_free(&f);
    cell_string_t t = cell_str_from_bool(true);
    CHECK(t.len == 4 && memcmp(t.ptr, "true", 4) == 0);
    cell_string_free(&t);
    cell_string_t v = cell_rt_version();
    CHECK(v.len > 0);
    cell_string_free(&v);
}
```

Update `test_version` to the new `cell_rt_version` (free the returned string). The existing `test_str_views` may already call `cell_str_eq`; it keeps working.

- [ ] **Step 2: Run to see it fail** (same command as Task 2 Step 2).

- [ ] **Step 3: Implement**

```c
int64_t cell_str_len(cell_str_t s) { return (int64_t)s.len; }

bool cell_str_eq(cell_str_t a, cell_str_t b) {
    return a.len == b.len && (a.len == 0 || memcmp(a.ptr, b.ptr, a.len) == 0);
}

cell_string_t cell_str_concat(cell_str_t a, cell_str_t b) {
    cell_string_t out = cell_string_from_str(a);
    if (b.len == 0) return out;
    size_t need = out.len + b.len;
    if (need > out.cap) {
        char *grown = (char *)realloc(out.ptr, need + 1);
        if (grown == NULL) cell_panic(cell_str_from_cstr("cell_str_concat: out of memory"));
        out.ptr = grown;
        out.cap = need;
    }
    memcpy(out.ptr + out.len, b.ptr, b.len);
    out.len = need;
    out.ptr[out.len] = '\0';
    return out;
}

cell_opt_byte_t cell_str_byte_at(cell_str_t s, int64_t index) {
    if (index < 0 || (uint64_t)index >= s.len) return cell_opt_byte_none();
    return cell_opt_byte_some((uint8_t)s.ptr[index]);
}

static cell_string_t cell_string_from_buf(const char *buf, int n) {
    if (n < 0) n = 0;
    return cell_string_from_str(cell_str_from_parts(buf, (size_t)n));
}

cell_string_t cell_str_from_int(int64_t v) {
    char buf[32];
    int n = snprintf(buf, sizeof buf, "%lld", (long long)v);
    return cell_string_from_buf(buf, n);
}

cell_string_t cell_str_from_float(double v) {
    char buf[64];
    int n = snprintf(buf, sizeof buf, "%.17g", v);
    return cell_string_from_buf(buf, n);
}

cell_string_t cell_str_from_bool(bool v) {
    return cell_string_from_cstr(v ? "true" : "false");
}

cell_string_t cell_rt_version(void) {
    return cell_string_from_cstr(CELL_RT_VERSION_STRING);
}

void cell_panic(cell_str_t msg) {
    fputs("cell panic: ", stderr);
    fwrite(msg.ptr, 1, msg.len, stderr);
    fputc('\n', stderr);
    abort();
}
```

Read the current `cell_rt_version` body for the version string's spelling (`CELL_RT_VERSION_STRING` above stands for whatever macro or literal it returns today; use that). Read `cell_string_from_str` to confirm it NUL-terminates and what `cap` means (the `realloc` above assumes `cap` excludes the terminator; if it includes it, adjust `need + 1`/`cap` accordingly and say so in a comment). Every existing caller of `cell_panic(const char *)` in `cell_rt.c` (the assert helpers, the non-exhaustive match panic emitted by codegen as `cell_panic("...")`) must change: in the runtime wrap the literal with `cell_str_from_cstr(...)`; in `codegen.zig` change the `cell_panic("non-exhaustive match in {s}")` emission to `cell_panic(cell_str_from_cstr("non-exhaustive match in {s}"))` and update the codegen tests that pin that text (`grep -n 'cell_panic' src/cell/codegen.zig`). `%.17g` prints `1.5` as `1.5`; it prints `0.1` as `0.10000000000000001`, which is exact round-trip and is the documented behaviour (write that in the prelude doc line for `str_from_float`).

- [ ] **Step 4: Run** the harness (expect EXIT 0) and `zig build test -Dswift=false > /private/tmp/t.log 2>&1; echo "EXIT: $?"` (the codegen tests for the panic text), expect EXIT 0.

- [ ] **Step 5: Prelude header text**

In `stdlib/prelude.cell`, the group 2 section: keep the two declarations, replace the paragraph with "CLOSED 2026-09-16: the runtime speaks `cell_str_t`/`cell_string_t` here too; both link. Kept as its own group as the record of why they once did not." Move `rt_version` and `panic` doc lines to the matched form (`Emits`/`Runtime` lines equal).

- [ ] **Step 6: Commit**

```bash
git add runtime/cell_rt.h runtime/cell_rt.c runtime/tests/test_cell_rt.c src/cell/codegen.zig stdlib/prelude.cell
git commit -m "runtime: prelude string functions; rt_version and panic take cell_str_t (group 2 closed)"
```

---

### Task 4: Byte lists and explicit arc functions

**Files:**
- Modify: `runtime/cell_rt.h`, `runtime/cell_rt.c`, `runtime/tests/test_cell_rt.c`

**Interfaces:**
- Produces:

```c
int64_t cell_bytes_len(cell_slice_t xs);
cell_opt_byte_t cell_bytes_at(cell_slice_t xs, int64_t index);
void cell_bytes_push(cell_slice_t *xs, uint8_t value);
cell_opt_byte_t cell_bytes_pop(cell_slice_t *xs);
void cell_bytes_clear(cell_slice_t *xs);
cell_slice_t cell_bytes_empty(void);
cell_slice_t cell_bytes_with_capacity(int64_t cap);
cell_arc_t cell_arc_retain_string(cell_arc_t value);
void cell_arc_release_string(cell_arc_t value);
int64_t cell_arc_count_string(cell_arc_t value);
```

- [ ] **Step 1: Failing harness test**

```c
static void test_prelude_bytes_and_arc(void) {
    cell_slice_t xs = cell_bytes_empty();
    CHECK(cell_bytes_len(xs) == 0);
    cell_bytes_push(&xs, 7);
    cell_bytes_push(&xs, 9);
    CHECK(cell_bytes_len(xs) == 2);
    CHECK(cell_bytes_at(xs, 1).value == 9);
    CHECK(!cell_bytes_at(xs, 2).has_value);
    CHECK(cell_bytes_pop(&xs).value == 9);
    CHECK(cell_bytes_len(xs) == 1);
    cell_bytes_clear(&xs);
    CHECK(cell_bytes_len(xs) == 0);
    CHECK(!cell_bytes_pop(&xs).has_value);
    cell_slice_free(&xs);
    cell_slice_t ys = cell_bytes_with_capacity(16);
    CHECK(ys.cap >= 16 && ys.len == 0);
    cell_slice_free(&ys);

    cell_arc_t a = cell_arc_from_string(cell_string_from_cstr("x"));
    CHECK(cell_arc_count_string(a) == 1);
    cell_arc_t b = cell_arc_retain_string(a);   /* callee released its parameter's count and returned +1 */
    CHECK(cell_arc_count_string(b) == 1);
    cell_arc_release_string(b);
    /* `a` and `b` are the same box; after one release from count 1 it is gone.
     * Nothing to CHECK without a use-after-free, so the test ends here and
     * the leaks stage of the gate is the witness. */
}
```

The count arithmetic follows the spec: `arc_retain_string(arc value)` receives a +1 it must release (R11 row 1, callee-releases), returns a clone (+1), net count unchanged. Read `runtime/cell_rt.h` section 7 before trusting this; if the section says the caller of an `arc` parameter passes a clone the callee releases, the harness test above holds as written (the harness itself passes the raw handle, standing in for the caller's clone).

- [ ] **Step 2: Run to see it fail.**

- [ ] **Step 3: Implement**

```c
int64_t cell_bytes_len(cell_slice_t xs) { return (int64_t)xs.len; }

cell_opt_byte_t cell_bytes_at(cell_slice_t xs, int64_t index) {
    if (index < 0 || (uint64_t)index >= xs.len) return cell_opt_byte_none();
    return cell_opt_byte_some(((const uint8_t *)xs.ptr)[index]);
}

void cell_bytes_push(cell_slice_t *xs, uint8_t value) {
    if (!cell_slice_push(xs, sizeof(uint8_t), &value))
        cell_panic(cell_str_from_cstr("cell_bytes_push: out of memory"));
}

cell_opt_byte_t cell_bytes_pop(cell_slice_t *xs) {
    if (xs->len == 0) return cell_opt_byte_none();
    xs->len -= 1;
    return cell_opt_byte_some(((const uint8_t *)xs->ptr)[xs->len]);
}

void cell_bytes_clear(cell_slice_t *xs) { xs->len = 0; }

cell_slice_t cell_bytes_empty(void) { return cell_slice_empty(); }

cell_slice_t cell_bytes_with_capacity(int64_t cap) {
    if (cap < 0) cap = 0;
    return cell_slice_alloc(sizeof(uint8_t), (size_t)cap);
}

cell_arc_t cell_arc_retain_string(cell_arc_t value) {
    cell_arc_t out = cell_arc_clone(value);
    cell_arc_drop(value);   /* the parameter's own reference, R11 row 1 */
    return out;
}

void cell_arc_release_string(cell_arc_t value) {
    cell_arc_drop(value);   /* the parameter's reference; nothing else to do */
}

int64_t cell_arc_count_string(cell_arc_t value) {
    int64_t n = (int64_t)cell_arc_strong_count(value);
    cell_arc_drop(value);
    return n;
}
```

`cell_arc_count_string` therefore reports the count INCLUDING the reference it was handed and then releases that reference, which is the same observation `examples/arc_host.c`'s `observe` makes; document that on the prelude doc line. Whether `cell_slice_push`/`cell_slice_alloc` take `elem_size` first: read their prototypes (`runtime/cell_rt.h` ~233-245) and match.

- [ ] **Step 4: Run** the harness (EXIT 0, 0 FAIL).

- [ ] **Step 5: Commit**

```bash
git add runtime/cell_rt.h runtime/cell_rt.c runtime/tests/test_cell_rt.c
git commit -m "runtime: prelude byte-list and explicit arc functions"
```

---

### Task 5: Gate stage 13 and the prelude corpus example

**Files:**
- Modify: `tools/check.sh` (header comment list, a new stage after stage 12, before the verdict)
- Create: `examples/prelude.cell`
- Modify: `examples/README.md`, `README.md`, `docs/FEATURES.md` (CLI-02), `stdlib/prelude.cell` (group 3 header paragraph)

- [ ] **Step 1: The example**

```cell
// The prelude, exercised end to end: every group 3 function is called, the
// optional-returning ones are matched, and one number is printed.
//
// Status: C only (optionals and owned Strings; LLVM and MLIR refuse
// together). Runs through gate stage 12 (`cell run`) as well as stage 8.
// EXPECT-OUTPUT: 1

pub fn print_int(copy value: Int);
pub fn str_len(shared s: String) -> Int;
pub fn str_eq(shared a: String, shared b: String) -> Bool;
pub fn str_concat(shared a: String, shared b: String) -> owned String;
pub fn str_byte_at(shared s: String, copy index: Int) -> Byte?;
pub fn str_from_int(copy v: Int) -> owned String;
pub fn int_from_byte(copy v: Byte) -> Int;
pub fn rem_int(copy a: Int, copy b: Int) -> Int?;
pub fn abs_int(copy v: Int) -> Int?;
pub fn min_int(copy a: Int, copy b: Int) -> Int;
pub fn byte_from_int(copy v: Int) -> Byte?;
pub fn bytes_empty() -> owned [Byte];
pub fn bytes_push(exclusive xs: [Byte], copy value: Byte);
pub fn bytes_len(shared xs: [Byte]) -> Int;
pub fn bytes_pop(exclusive xs: [Byte]) -> Byte?;

pub fn or_zero(copy o: Int?) -> Int {
    return match o { Some(x) => x, None => 0 }
}

pub fn main() {
    let owned ab: String = str_concat("a", "b")
    let copy n = str_len(ab)                         // 2
    let copy same = str_eq(ab, "ab")                 // true
    let copy c = match str_byte_at(ab, 1) { Some(b) => int_from_byte(b), None => 0 }   // 98
    let copy miss = match str_byte_at(ab, 5) { Some(b) => 1, None => 0 }               // 0
    let owned s42: String = str_from_int(42)
    let copy r = or_zero(rem_int(7, 3))              // 1
    let copy z = or_zero(rem_int(7, 0))              // 0
    let copy a = or_zero(abs_int(-9))                // 9
    let copy m = min_int(3, 4)                       // 3
    let copy ok = match byte_from_int(300) { Some(v) => 1, None => 0 }   // 0
    var owned xs: [Byte] = bytes_empty()
    bytes_push(&mut xs, 5)
    bytes_push(&mut xs, 6)
    let copy l = bytes_len(xs)                       // 2
    let copy p = match bytes_pop(&mut xs) { Some(v) => int_from_byte(v), None => 0 }   // 6
    let copy total = n + c + miss + r + z + a + m + ok + l + p + str_len(s42)
    // 2 + 98 + 0 + 1 + 0 + 9 + 3 + 0 + 2 + 6 + 2 = 123
    if same {
        print_int(total)
    } else {
        print_int(0)
    }
}
```

Hand-derived answer: 123. **The `EXPECT-OUTPUT` line above says 1 on purpose; set it to 123 before running.** If `&mut xs` is not how this corpus spells an exclusive borrow argument, read `examples/write_through.cell` and use its spelling. If the borrow-through-`match`-scrutinee shape `match bytes_pop(&mut xs)` is refused by borrowck (a temporary loan inside a statement is R0.3 exception 1, so it should be accepted), bind it first: `let copy popped = bytes_pop(&mut xs)` then match `popped`.

- [ ] **Step 2: Run it**

Run: `zig build -Dswift=false > /private/tmp/b.log 2>&1; echo "EXIT: $?"; ./zig-out/bin/cell run examples/prelude.cell; echo "EXIT: $?"`
Expected: `123`, exit 0. Every earlier prelude call that used to be an undefined symbol now links, which is the measurement the goal wanted.

- [ ] **Step 3: Stage 13**

In `tools/check.sh` header comment, after the stage 12 entry:

```
#  13. prelude sigs     every prototype the C backend emits for
#                       stdlib/prelude.cell appears verbatim in
#                       runtime/cell_rt.h. The prelude's own comments checked
#                       this by hand ("Emits ... / Runtime ...") and were
#                       found inverted once (2026-09-07); a program that
#                       calls a prelude function links only while this holds.
```

Before `# ---- verdict --`:

```sh
# ------------------------------------------------------------ 13. prelude sigs --
printf '\n== prelude signatures (emitted prototypes are in cell_rt.h) ==\n'
if tools/prelude-signatures.sh "$CELL" > "$TMP/prelude_sigs.txt" 2> "$TMP/prelude_sigs.err"; then
    missing=0
    while IFS= read -r proto; do
        if grep -qF -- "$proto" runtime/cell_rt.h; then
            pass "$proto"
        else
            fail "not in runtime/cell_rt.h: $proto"
            missing=$((missing + 1))
        fi
    done < "$TMP/prelude_sigs.txt"
    [ "$(wc -l < "$TMP/prelude_sigs.txt" | tr -d ' ')" -gt 0 ] || fail "prelude-signatures.sh printed no prototypes (the grep in it matched nothing)"
else
    fail "tools/prelude-signatures.sh could not emit the prelude: $(head -1 "$TMP/prelude_sigs.err")"
fi
```

Read how `pass`/`fail`/`$CELL`/`$TMP` are defined at the top of the script and match them. Also add `examples/prelude.cell` to stage 12's run list (`for pair in hello:42 backends:24 loops:55 prelude:123`).

- [ ] **Step 4: Falsify the stage before trusting it**

Temporarily rename one prototype in `runtime/cell_rt.h` (for example `cell_str_len` to `cell_str_lenx`), run `tools/check.sh > /private/tmp/gate.log 2>&1; echo "EXIT: $?"`, expect EXIT 1 with `not in runtime/cell_rt.h: int64_t cell_str_len(cell_str_t s);` in the log (the build itself may also fail earlier because the harness calls the renamed function; if so the stage's own failure line is enough evidence when reached, otherwise falsify by adding a fake declaration to `stdlib/prelude.cell` instead). Revert.

- [ ] **Step 5: Docs**

- `stdlib/prelude.cell` group 3 header: "CLOSED 2026-09-16 (commit <hash>): every declaration below is implemented in runtime/cell_rt.c; gate stage 13 keeps the prototypes matched." Keep the group heading so the history reads.
- `examples/README.md`: add `prelude.cell` to the C-only list with its pinned answer.
- `README.md` Status: remove "the prelude's group 3 declarations still resolve to no symbol" and say the prelude links; the stage list gains stage 13 ("thirteen stages").
- `docs/FEATURES.md` CLI-02: prelude part `checked`/`lowered` (C); `test` remains absent.
- `CLAUDE.md` gate paragraph: "twelve stages" to "thirteen", list the new one.

- [ ] **Step 6: Gate**

Run: `tools/check.sh > /private/tmp/gate.log 2>&1; echo "CELL_GATE_EXIT: $?" >> /private/tmp/gate.log; grep -E '^== verdict|CELL_GATE_EXIT|FAIL|SKIPPED' /private/tmp/gate.log | tail -5; grep -c '^== ' /private/tmp/gate.log`
Expected: `clean`, exit 0, 14 headings (13 stages plus verdict).

- [ ] **Step 7: Commit and push**

```bash
git add tools/check.sh examples/prelude.cell examples/README.md README.md docs/FEATURES.md stdlib/prelude.cell CLAUDE.md
git commit -m "prelude group 3 linked and pinned: examples/prelude.cell through cell run, gate stage 13 keeps prototypes matched"
git push origin main
```

---

## Self-review

- Spec coverage: A.1 (Tasks 1, 5 stage 13), A.2 (Tasks 2, 3, 4), A.3 (harness tests in 2 to 4, stage 13 and the example in 5, docs in 3 and 5).
- Placeholders: the `EXPECT-OUTPUT` sentinel in Task 5 is deliberate and its correction is a step; `CELL_RT_VERSION_STRING` is named as "whatever the current body returns" with the instruction to read it.
- Type consistency: every prototype in a task's Interfaces block is the one its harness test calls; `cell_str_eq` is the existing helper's name, exported instead of `static inline` (Task 3's note).
