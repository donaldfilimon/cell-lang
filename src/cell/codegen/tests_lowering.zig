//! C backend tests, first quarter in original order: type and signature
//! lowering, literals, conditions, entry points, and early drop insertion.

const std = @import("std");
const cg_tests_support = @import("tests_support.zig");
const emitSource = cg_tests_support.emitSource;
const expectContains = cg_tests_support.expectContains;
const fnDef = cg_tests_support.fnDef;
const expectCompiles = cg_tests_support.expectCompiles;
const expectAbsent = cg_tests_support.expectAbsent;
const expectLineBefore = cg_tests_support.expectLineBefore;
const expectOccurrences = cg_tests_support.expectOccurrences;
const expectBefore = cg_tests_support.expectBefore;

test "every module includes the runtime header" {
    var e = try emitSource("pub fn f(copy v: Int) -> Int;");
    defer e.deinit();
    try expectContains(e.text, "#include \"cell_rt.h\"");
}

test "Int8 Int16 UInt8 UInt16 UInt32 lower to their C types" {
    var e = try emitSource(
        \\pub fn take_int8(copy v: Int8) -> Int8;
        \\pub fn take_int16(copy v: Int16) -> Int16;
        \\pub fn take_uint8(copy v: UInt8) -> UInt8;
        \\pub fn take_uint16(copy v: UInt16) -> UInt16;
        \\pub fn take_uint32(copy v: UInt32) -> UInt32;
        \\pub fn maybe_u32(copy v: UInt32?) -> Bool;
        \\pub fn maybe_u8(copy v: UInt8?) -> Bool;
        \\pub fn maybe_byte(copy v: Byte?) -> Bool;
    );
    defer e.deinit();
    try expectContains(e.text, "int8_t cell_take_int8(int8_t v);");
    try expectContains(e.text, "int16_t cell_take_int16(int16_t v);");
    try expectContains(e.text, "uint8_t cell_take_uint8(uint8_t v);");
    try expectContains(e.text, "uint16_t cell_take_uint16(uint16_t v);");
    try expectContains(e.text, "uint32_t cell_take_uint32(uint32_t v);");
    try expectContains(e.text, "bool cell_maybe_u32(cell_opt_u32_t v);");
    try expectContains(e.text, "bool cell_maybe_u8(cell_opt_u8_t v);");
    try expectContains(e.text, "bool cell_maybe_byte(cell_opt_byte_t v);");
}

test "ownership selects the parameter type for each mode" {
    var e = try emitSource(
        \\pub struct Buffer {
        \\  copy len: Int
        \\}
        \\pub fn by_copy(copy v: Int) -> Int;
        \\pub fn by_shared_primitive(shared v: Int) -> Int;
        \\pub fn by_exclusive_primitive(exclusive v: Int) -> Int;
        \\pub fn by_shared_string(shared s: String) -> Int;
        \\pub fn by_owned_string(owned s: String) -> Int;
        \\pub fn by_exclusive_string(exclusive s: String) -> Int;
        \\pub fn by_arc_string(arc s: String) -> Int;
        \\pub fn by_shared_struct(shared b: Buffer) -> Int;
        \\pub fn by_exclusive_struct(exclusive b: Buffer) -> Int;
        \\pub fn by_owned_struct(owned b: Buffer) -> Int;
        \\pub fn by_shared_list(shared xs: [Byte]) -> Int;
        \\pub fn by_exclusive_list(exclusive xs: [Byte]) -> Int;
    );
    defer e.deinit();

    // Primitives stay by value in every mode: cell_rt.h section 1.
    try expectContains(e.text, "int64_t cell_by_copy(int64_t v);");
    try expectContains(e.text, "int64_t cell_by_shared_primitive(int64_t v);");
    try expectContains(e.text, "int64_t cell_by_exclusive_primitive(int64_t v);");

    try expectContains(e.text, "int64_t cell_by_shared_string(cell_str_t s);");
    try expectContains(e.text, "int64_t cell_by_owned_string(cell_string_t s);");
    try expectContains(e.text, "int64_t cell_by_exclusive_string(cell_string_t *s);");
    try expectContains(e.text, "int64_t cell_by_arc_string(cell_arc_t s);");

    try expectContains(e.text, "int64_t cell_by_shared_struct(const cell_Buffer *b);");
    try expectContains(e.text, "int64_t cell_by_exclusive_struct(cell_Buffer *b);");
    try expectContains(e.text, "int64_t cell_by_owned_struct(cell_Buffer b);");

    try expectContains(e.text, "int64_t cell_by_shared_list(cell_slice_t xs);");
    try expectContains(e.text, "int64_t cell_by_exclusive_list(cell_slice_t *xs);");
}

test "a struct lowers each field by its own ownership" {
    var e = try emitSource(
        \\pub struct Buffer {
        \\  owned data: [Byte]
        \\  copy len: Int
        \\  shared name: String
        \\}
    );
    defer e.deinit();
    try expectContains(e.text,
        \\typedef struct cell_Buffer {
        \\  cell_slice_t data; // owned
        \\  int64_t len; // copy
        \\  cell_str_t name; // shared
        \\} cell_Buffer;
    );
}

test "an enum is an int32_t typedef, not an implementation defined enum" {
    var e = try emitSource(
        \\pub enum Color {
        \\  Red,
        \\  Green,
        \\  Blue,
        \\}
    );
    defer e.deinit();
    try expectContains(e.text,
        \\typedef int32_t cell_Color;
        \\enum {
        \\  cell_Color_Red = 0,
        \\  cell_Color_Green = 1,
        \\  cell_Color_Blue = 2,
        \\};
    );
    try expectAbsent(e.text, "typedef enum");
}

test "a struct field naming a later struct emits that struct's typedef first" {
    // `cell check` accepts this and source order emitted `cell_A` first, so
    // `cc` refused the module with `unknown type name 'cell_B'`.
    var e = try emitSource(
        \\pub struct A { owned b: B }
        \\pub struct B { owned name: String }
    );
    defer e.deinit();
    try expectBefore(e.text, "} cell_B;", "typedef struct cell_A {");
}

test "a ref field takes the same ordering edge as a value field" {
    // `shared b: B` lowers to `cell_B *`, which still needs the typedef.
    var e = try emitSource(
        \\pub struct A { shared b: B }
        \\pub struct B { copy x: Int }
    );
    defer e.deinit();
    try expectBefore(e.text, "} cell_B;", "typedef struct cell_A {");
}

test "independent structs keep source order" {
    // The reorder must be minimal: structs that do not reference each other
    // emit exactly as they did before the dependency walk existed.
    var e = try emitSource(
        \\pub struct First { copy x: Int }
        \\pub struct Second { copy y: Int }
    );
    defer e.deinit();
    try expectBefore(e.text, "} cell_First;", "typedef struct cell_Second {");
}

test "a struct cycle terminates, emits both typedefs, and drops the back edge" {
    // No emission order compiles a by-value cycle, so the pass must not hang
    // or drop a struct; it leaves the cycle for `cc` to report.
    //
    // The order assertion documents what the DFS actually does rather than
    // stating a requirement: A is visited first, recurses into B, B's edge
    // back to A meets `visiting` and returns, so B completes and emits first.
    // It is pinned because the first version of this test asserted only that
    // both were present, and that blindness let the doc comment claim for a
    // while that a cycle was "left in source order" when it is not.
    var e = try emitSource(
        \\pub struct A { owned b: B }
        \\pub struct B { owned a: A }
    );
    defer e.deinit();
    try expectContains(e.text, "} cell_A;");
    try expectContains(e.text, "} cell_B;");
    try expectBefore(e.text, "} cell_B;", "typedef struct cell_A {");
}

test "an enum a struct field names is emitted before the struct" {
    var e = try emitSource(
        \\pub struct Tagged { copy c: Color }
        \\pub enum Color { Red, Green }
    );
    defer e.deinit();
    try expectBefore(e.text, "typedef int32_t cell_Color;", "typedef struct cell_Tagged {");
}

test "a match arm's binding pattern carries the scrutinee's type into inference" {
    // `match s { x => x }` used to infer nothing from `x`, so `emitValueExpr`
    // fell back to `CType.int64` and `cc` rejected the module with
    // `assigning to 'int64_t' from incompatible type 'cell_string_t'`.
    // Asserting the DECLARED TYPE of the destination rather than merely that
    // a match was emitted: the wrong type is what compiled, not a missing
    // statement, so a presence-only test would pass on the broken output.
    var e = try emitSource(
        \\pub fn make() -> String {
        \\    return "hello"
        \\}
        \\pub fn demo() -> Int {
        \\    let owned s = make()
        \\    let shared c = match s { x => x }
        \\    return 0
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_string_t c = ({");
    try expectAbsent(e.text, "int64_t c = ({");
}

test "a scalar scrutinee is not over-typed by that inference" {
    // The other direction of the same change: the arm binding must take the
    // scrutinee's type, not a resource type by default.
    var e = try emitSource(
        \\pub fn demo() -> Int {
        \\    let copy n = 7
        \\    let copy c = match n { x => x }
        \\    return c
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "int64_t c = ({");
}

test "an arm body that is not the binding still infers from the body" {
    // Pins that the fix did not reroute every match through the scrutinee:
    // a literal arm body keeps its own type, which is what already worked.
    var e = try emitSource(
        \\pub fn make() -> String {
        \\    return "hello"
        \\}
        \\pub fn demo() -> Int {
        \\    let owned s = make()
        \\    let shared c = match s { x => "lit" }
        \\    return 0
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_str_t c = ({");
}

test "a zero-parameter function is prototyped with void" {
    var e = try emitSource("pub fn tick();");
    defer e.deinit();
    try expectContains(e.text, "void cell_tick(void);");
}

test "an optional lowers to the tagged runtime type, not void*" {
    var e = try emitSource(
        \\pub struct Point { copy x: Int }
        \\pub fn maybe_int(shared v: Int?) -> Bool;
        \\pub fn maybe_point(shared p: Point?) -> Bool;
    );
    defer e.deinit();
    try expectContains(e.text, "CELL_DEFINE_OPTIONAL(cell_opt_Point, cell_Point)");
    try expectContains(e.text, "bool cell_maybe_int(cell_opt_i64_t v);");
    try expectContains(e.text, "bool cell_maybe_point(cell_opt_Point_t p);");
}

test "a list parameter lowers to a slice, not void*" {
    var e = try emitSource("pub fn count(shared xs: [Byte]) -> Int;");
    defer e.deinit();
    try expectContains(e.text, "int64_t cell_count(cell_slice_t xs);");
    try expectAbsent(e.text, "void*");
}

test "postfix indexing of String and [Byte] calls the bounds-checked helpers" {
    var e = try emitSource(
        \\pub fn f(shared s: String, shared xs: [Byte], copy i: Int) -> Byte? {
        \\  return s[i]
        \\}
        \\pub fn g(shared xs: [Byte]) -> Byte? {
        \\  return xs[0]
        \\}
        \\pub fn h(owned s: String, copy i: Int) -> Byte? {
        \\  return s[i]
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_str_byte_at(s, i)");
    try expectContains(e.text, "cell_bytes_at(xs, 0)");
    try expectContains(e.text, "cell_str_byte_at(cell_string_as_str(&s), i)");
    try expectAbsent(e.text, ".ptr[");
}

test "calls are mangled and reach the runtime intrinsics" {
    var e = try emitSource(
        \\pub fn add(shared a: Int, shared b: Int) -> Int {
        \\  return a + b
        \\}
        \\pub fn main() {
        \\  let copy n = add(shared 40, shared 2)
        \\  print("hi")
        \\  println("hi")
        \\  assert(true)
        \\  assert(true, "boom")
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "int64_t n = cell_add(40, 2);");
    try expectContains(e.text, "cell_print(cell_str_from_parts(\"hi\", 2));");
    try expectContains(e.text, "cell_println(cell_str_from_parts(\"hi\", 2));");
    try expectContains(e.text, "cell_assert(true);");
    try expectContains(e.text, "cell_assert_msg(true, cell_str_from_parts(\"boom\", 4));");
    // A shared primitive argument is passed by value, never addressed.
    try expectAbsent(e.text, "cell_add(&40, &2)");
}

test "a bodyless declaration of an intrinsic takes the runtime spelling" {
    var e = try emitSource(
        \\pub fn assert(shared cond: Bool, shared msg: String);
        \\pub fn main() {
        \\  assert(true, "boom")
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "void cell_assert_msg(bool cond, cell_str_t msg);");
    try expectContains(e.text, "cell_assert_msg(true, cell_str_from_parts(\"boom\", 4));");
    try expectAbsent(e.text, "void cell_assert(bool cond, cell_str_t msg)");
}

test "a defined function is never renamed onto a runtime symbol" {
    var e = try emitSource(
        \\pub fn assert(shared cond: Bool, shared msg: String) {
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "void cell_assert(bool cond, cell_str_t msg) {");
    try expectAbsent(e.text, "cell_assert_msg");
}

test "a string literal decodes escapes then re-escapes them for C" {
    var quote = try emitSource(
        \\pub fn main() {
        \\  print("a\"b")
        \\}
    );
    defer quote.deinit();
    // `"a\"b"` is three bytes a"b. The C literal re-escapes the quote.
    try expectContains(quote.text, "cell_str_from_parts(\"a\\\"b\", 3)");

    var nl = try emitSource(
        \\pub fn main() {
        \\  print("\n")
        \\}
    );
    defer nl.deinit();
    try expectContains(nl.text, "cell_str_from_parts(\"\\n\", 1)");

    var bs = try emitSource(
        \\pub fn main() {
        \\  print("\\")
        \\}
    );
    defer bs.deinit();
    try expectContains(bs.text, "cell_str_from_parts(\"\\\\\", 1)");
}

test "a shared borrow of a primitive drops the ampersand" {
    var e = try emitSource(
        \\pub struct Buffer { copy len: Int }
        \\pub fn take_int(shared v: Int) -> Int;
        \\pub fn take_buf(shared b: Buffer) -> Int;
        \\pub fn main() {
        \\  let copy n = 1
        \\  let owned b = Buffer { len: 0 }
        \\  let copy x = take_int(&n)
        \\  let copy y = take_buf(&b)
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_take_int(n);");
    try expectContains(e.text, "cell_take_buf(&b);");
}

test "a call site is lowered against the callee's parameter ownership" {
    var e = try emitSource(
        \\pub struct Buffer { copy len: Int }
        \\pub fn grow(exclusive buf: Buffer, shared extra: Int) {
        \\  let copy new_len = buf.len + extra
        \\  buf.len = new_len
        \\}
        \\pub fn read_only(shared b: Buffer) -> Int {
        \\  return b.len
        \\}
        \\pub fn main() {
        \\  let owned buf = Buffer { len: 0 }
        \\  grow(exclusive buf, shared 16)
        \\  let copy n = read_only(shared buf)
        \\}
    );
    defer e.deinit();
    // Emission still follows the callee signature, so `exclusive buf`
    // becomes `&buf` because `grow` takes `exclusive Buffer`.
    try expectContains(e.text, "cell_grow(&buf, 16);");
    try expectContains(e.text, "cell_read_only(&buf);");
    // Inside grow, buf is a pointer, so field selection uses `->`.
    try expectContains(e.text, "int64_t new_len = (buf->len + extra);");
    try expectContains(e.text, "buf->len = new_len;");
}

test "a struct literal becomes a designated compound literal" {
    var e = try emitSource(
        \\pub struct Point {
        \\  copy x: Float64
        \\  copy y: Float64
        \\}
        \\pub fn main() {
        \\  let owned p = Point { x: 1.0, y: 2.0 }
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_Point p = (cell_Point){ .x = 1.0, .y = 2.0 };");
}

test "list literals lower to slice headers" {
    var e = try emitSource(
        \\pub struct Buffer {
        \\  owned data: [Byte]
        \\  copy len: Int
        \\}
        \\pub fn main() {
        \\  let owned b = Buffer { data: [], len: 0 }
        \\  let owned xs = [1, 2]
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, ".data = cell_slice_empty()");
    try expectContains(e.text, "cell_slice_t _cell_t0 = cell_slice_alloc(sizeof(int64_t), 2);");
    try expectContains(e.text, "(void)cell_slice_push(&_cell_t0, sizeof(int64_t), &_cell_t1);");
}

test "statement position if is plain C" {
    var e = try emitSource(
        \\pub fn pick(shared c: Bool) -> Int {
        \\  if (c) { return 1 } else { return 2 }
        \\  return 0
        \\}
    );
    defer e.deinit();
    try expectContains(e.text,
        \\  if (c) {
        \\    return 1;
        \\  } else {
        \\    return 2;
        \\  }
    );
    try expectAbsent(e.text, "/*if*/");
}

test "expression position if becomes a statement expression" {
    var e = try emitSource(
        \\pub fn pick(shared c: Bool) -> Int {
        \\  let copy v = if (c) { 1 } else { 2 }
        \\  return v
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "int64_t v = ({");
    try expectContains(e.text, "_cell_t0 = 1;");
    try expectContains(e.text, "_cell_t0 = 2;");
}

test "a match whose reached arms never read the scrutinee voids its temporary" {
    // Measured 2026-09-16: `let arc a = match c { _ => make() }` emitted
    // `int64_t _cell_t4 = c;` with no reader and failed -Werror. The
    // scrutinee is still evaluated; only the unused-variable warning goes.
    var e = try emitSource(
        \\pub fn f(copy c: Int) -> Int {
        \\  return match c { _ => 7 }
        \\}
        \\pub fn g(copy c: Int, copy b: Bool) -> Int {
        \\  return match c { _ if b => 1, _ => 2 }
        \\}
        \\pub fn h(copy c: Int) -> Int {
        \\  return match c { 1 => 1, _ => 2 }
        \\}
        \\pub fn k(copy c: Int) -> Int {
        \\  return match c { x => x }
        \\}
    );
    defer e.deinit();
    try expectContains(try fnDef(e.text, "f"), "(void)_cell_t");
    try expectContains(try fnDef(e.text, "g"), "(void)_cell_t");
    try expectAbsent(try fnDef(e.text, "h"), "(void)_cell_t");
    try expectAbsent(try fnDef(e.text, "k"), "(void)_cell_t");
    try expectCompiles(e.text);
}

test "TYPE-06: a Result with an owning String error is its own instance and is released" {
    // Until sub-project 3 (2026-09-17) this pair was the ABI-1 `cell_result_t`
    // pass-through and was never dropped (a leak). It now has an instance and
    // release glue: a returned value moves, an ignored owned one is released.
    var e = try emitSource(
        \\pub fn read() -> Result<Int, String>;
        \\pub fn relay() -> Result<Int, String> {
        \\  return read()
        \\}
        \\pub fn keep(owned r: Result<Int, String>) -> Result<Int, String> {
        \\  return r
        \\}
        \\pub fn ignore(owned r: Result<Int, String>) -> Int {
        \\  return 1
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_res_i64_string_t cell_read(void);");
    try expectContains(e.text, "if (!r->ok) cell_string_free(&r->as.err);");
    try expectContains(try fnDef(e.text, "relay"), "return cell_read();");
    try expectContains(try fnDef(e.text, "keep"), "return r;");
    try expectAbsent(try fnDef(e.text, "keep"), "cell_drop_res_i64_string(&r);");
    try expectOccurrences(try fnDef(e.text, "ignore"), "cell_drop_res_i64_string(&r);", 1);
    try expectAbsent(e.text, "cell_arc_drop");
    try expectCompiles(e.text);
}

test "match lowers to a scrutinee temporary and an if chain" {
    var e = try emitSource(
        \\pub enum Color { Red, Green, Blue }
        \\pub fn describe(shared c: Color) -> Int {
        \\  return match c {
        \\    Color.Red => 1,
        \\    Green => 2,
        \\    _ => 0,
        \\  }
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_Color _cell_t1 = c;");
    try expectContains(e.text, "if (_cell_t1 == cell_Color_Red) {");
    try expectContains(e.text, "} else if (_cell_t1 == cell_Color_Green) {");
    try expectAbsent(e.text, "/*match*/");
}

test "an equality condition gets one pair of parentheses, not two" {
    // `if ((a == 2))` is rejected by clang's -Wparentheses-equality under
    // -Werror. Every condition site goes through `emitCond`: statement and
    // value `if`, `else if`, `while`, a guard-only arm and a pattern arm's
    // `&& (guard)`. Operands keep their own parentheses.
    var e = try emitSource(
        \\pub enum Color { Red, Green }
        \\pub fn stmt(copy a: Int, copy b: Int) -> Int {
        \\  var i = 0
        \\  while i != a {
        \\    i = i + 1
        \\  }
        \\  if a == 2 {
        \\    return 1
        \\  } else if a != b {
        \\    return 2
        \\  }
        \\  if (a + 1) == (b - 1) {
        \\    return 3
        \\  }
        \\  return 0
        \\}
        \\pub fn value(copy a: Int) -> Int {
        \\  let copy v = if a == 3 { 4 } else { 5 }
        \\  return v
        \\}
        \\pub fn guarded(copy c: Color, copy n: Int) -> Int {
        \\  return match c {
        \\    Color.Green if n == 5 => 7,
        \\    _ => 0,
        \\  }
        \\}
        \\pub fn guard_only(copy n: Int) -> Int {
        \\  return match n {
        \\    _ if n == 1 => 1,
        \\    _ => 0,
        \\  }
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "while (i != a) {");
    try expectContains(e.text, "if (a == 2) {");
    try expectContains(e.text, "} else if (a != b) {");
    try expectContains(e.text, "if ((a + 1) == (b - 1)) {");
    try expectContains(e.text, "if (a == 3) {");
    try expectContains(e.text, "&& (n == 5)) {");
    try expectContains(e.text, "if (n == 1) {");
    try expectAbsent(e.text, "((a == 2))");
    try expectAbsent(e.text, "((n == 5))");
    try expectCompiles(e.text);
}

test "a match without a catch-all arm panics instead of inventing a value" {
    var e = try emitSource(
        \\pub fn describe(shared n: Int) -> Int {
        \\  return match n {
        \\    1 => 10,
        \\    2 => 20,
        \\  }
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_panic(cell_str_from_cstr(\"non-exhaustive match in describe\"));");
}

test "a match arm binding is declared and kept quiet when unused" {
    var e = try emitSource(
        \\pub fn describe(shared n: Int) -> Int {
        \\  return match n {
        \\    1 => 10,
        \\    other => 0,
        \\  }
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "int64_t other = _cell_t1;");
    try expectContains(e.text, "(void)other;");
}

test "unused parameters and locals are named so -Wextra stays quiet" {
    var e = try emitSource(
        \\pub struct Buffer { copy len: Int }
        \\pub fn take(owned b: Buffer) {
        \\}
        \\pub fn main() {
        \\  let copy unused = 1
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "void cell_take(cell_Buffer b) {\n  (void)b;\n}");
    try expectContains(e.text, "(void)unused;");
}

test "a qualified enum variant in expression position is the enum constant" {
    var e = try emitSource(
        \\pub enum Color { Red, Green, Blue }
        \\pub fn describe(copy c: Color) -> Int;
        \\pub fn main() {
        \\  let copy n = describe(Color.Green)
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_describe(cell_Color_Green)");
}

test "a binding that is only assigned still gets a (void) cast" {
    // -Wunused-but-set-variable fires on a write-only binding, so a plain
    // assignment target does not count as a use.
    var e = try emitSource(
        \\pub fn f() {
        \\  var counter: Int = 0
        \\  counter = 1
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "int64_t counter = 0;\n  (void)counter;\n  counter = 1;");
}

test "a module with a main gets a C entry point" {
    var e = try emitSource(
        \\pub fn main() {
        \\  print("hi")
        \\}
    );
    defer e.deinit();
    try expectContains(e.text,
        \\int main(void) {
        \\  cell_main();
        \\  return 0;
        \\}
    );
}

test "a module without a main gets no C entry point" {
    var e = try emitSource("pub fn helper(copy v: Int) -> Int;");
    defer e.deinit();
    try expectAbsent(e.text, "int main(void)");
}

test "the hello example emits runtime-backed C" {
    // The example file itself cannot be read from here: @embedFile is limited
    // to the module root at src/, so the source is inlined.
    var e = try emitSource(
        \\use std.io
        \\
        \\pub struct Point {
        \\  copy x: Float64
        \\  copy y: Float64
        \\}
        \\
        \\pub enum Color {
        \\  Red,
        \\  Green,
        \\  Blue,
        \\}
        \\
        \\pub fn add(shared a: Int, shared b: Int) -> Int {
        \\  return a + b
        \\}
        \\
        \\pub fn main() {
        \\  let owned p = Point { x: 1.0, y: 2.0 }
        \\  let copy n = add(shared 40, shared 2)
        \\  print("hello from cell")
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "#include \"cell_rt.h\"");
    try expectContains(e.text, "cell_print(");
    try expectContains(e.text, "int64_t cell_add(int64_t a, int64_t b) {");
    try expectContains(e.text, "cell_Point p = (cell_Point){ .x = 1.0, .y = 2.0 };");
    try expectContains(e.text, "int main(void) {");
}

test "generated C for a function body compiles with cc -c" {
    var e = try emitSource(
        \\pub fn add(shared a: Int, shared b: Int) -> Int {
        \\  return a + b
        \\}
        \\pub fn print_int(copy value: Int);
        \\pub fn main() {
        \\  let copy n = add(shared 40, shared 2)
        \\  print_int(n)
        \\}
    );
    defer e.deinit();

    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "body.c", .data = e.text });

    var cwd_buf: [4096]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const include = try std.fmt.allocPrint(gpa, "{s}/runtime", .{cwd_buf[0..cwd_len]});
    defer gpa.free(include);

    const result = try std.process.run(gpa, io, .{
        .argv = &.{ "cc", "-std=c11", "-Wall", "-Wextra", "-c", "body.c", "-I", include, "-o", "body.o" },
        .cwd = .{ .dir = tmp.dir },
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (!result.term.success()) {
        std.debug.print("cc rejected emitted C:\n{s}\n--- source ---\n{s}\n", .{ result.stderr, e.text });
        return error.CcRejectedEmittedC;
    }
}

test "a match guard is ANDed into the arm's test" {
    var e = try emitSource(
        \\pub enum Color { Red, Green }
        \\pub fn f(copy c: Color, copy n: Int) -> Int {
        \\  return match c { Color.Green if n > 5 => 7, _ => 0, }
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "== cell_Color_Green && (");
}

test "a guarded catch-all arm still leaves the non-exhaustive panic in place" {
    // `_ if c` can fail, so dropping the panic would let an unmatched value
    // fall through with a made-up result. This is the whole reason a guarded
    // arm is not treated as a default.
    var e = try emitSource(
        \\pub fn f(copy n: Int) -> Int {
        \\  return match n { _ if n > 5 => 7, }
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_panic(cell_str_from_cstr(\"non-exhaustive match in f\")");
}

test "an unguarded catch-all still removes the panic" {
    var e = try emitSource(
        \\pub fn f(copy n: Int) -> Int {
        \\  return match n { 1 => 1, _ => 0, }
        \\}
    );
    defer e.deinit();
    if (std.mem.indexOf(u8, e.text, "non-exhaustive") != null) {
        std.debug.print("unexpected panic:\n{s}\n", .{e.text});
        return error.UnexpectedPanic;
    }
}

// ── drop insertion (task 3) ───────────────────────────────────────────────
//
// The first two are the safety tests, and come first on purpose: they pin
// the double-free guard before anything else pins the feature working at
// all. Every scenario here was probed against the real `cell emit` output
// before being written down, and the first two were also verified by fault
// injection -- see the task report -- by temporarily deleting the
// `wasMoved` check in `pendingDrops` and confirming a real double free (a
// `main()` that assigns one owned local's value onto another, then lets
// both reach scope exit) aborts, then restoring the check and confirming
// the same program exits clean.

test "a whole-value assignment through an exclusive borrow writes the POINTEE" {
    var e = try emitSource(
        \\pub struct Buffer {
        \\  copy len: Int
        \\}
        \\pub fn make() -> String;
        \\pub fn reset(exclusive b: Buffer) {
        \\  b = Buffer { len: 42 }
        \\}
        \\pub fn set_str(exclusive s: String) {
        \\  s = make()
        \\}
    );
    defer e.deinit();
    // An `exclusive` parameter lowers to a pointer, and writing the whole
    // value through it means writing what it points at. Both of these passed
    // `cell check` and emitted the value into the POINTER: `cc` refused with
    // `assigning to 'cell_Buffer *' from incompatible type 'cell_Buffer';
    // take the address with &`. Two forms, a record and a string, because
    // the record is the reported one and the string is the same defect
    // reached through a different `applyOwnership` branch.
    try expectContains(e.text, "  *b = (cell_Buffer){ .len = 42 };");
    try expectContains(e.text, "  *s = cell_make();");
}

test "a FIELD assignment through an exclusive borrow is unchanged" {
    var e = try emitSource(
        \\pub struct Buffer {
        \\  copy len: Int
        \\}
        \\pub fn bump(exclusive b: Buffer) {
        \\  b.len = b.len + 5
        \\}
        \\pub fn local() {
        \\  var owned b = Buffer { len: 1 }
        \\  b = Buffer { len: 2 }
        \\}
    );
    defer e.deinit();
    // The two neighbours the dereference must not touch. A `.field` target
    // gets the FIELD's type from `inferExpr` and `emitExpr` already spells
    // the base with `->`, and an owned local is not a pointer at all. Adding
    // a `*` to either would be a fresh miscompile rather than a fix, so both
    // are pinned by exact text.
    try expectContains(e.text, "  b->len = (b->len + 5);");
    try expectContains(e.text, "  b = (cell_Buffer){ .len = 2 };");
    try expectAbsent(e.text, "*b->len");
}

test "a write through an exclusive borrow reaches the caller, compiled and run" {
    // The assertion emitted text cannot make. The reporting agent measured
    // that the MLIR backend prints 37 for this shape, i.e. it silently drops
    // the write, so "it compiles" is not evidence that the caller sees it.
    // Only running it and reading the caller's own value back distinguishes
    // a write through the borrow from a write to a copy.
    //
    // The printed 47 decomposes as 42 + 5, and both halves are measurements:
    // `reset` replaces the whole value through the borrow, and `bump` then
    // adds 5 through the field path. If the whole-value write went to a copy
    // this prints 6, and if either write were dropped it prints 6 or 43.
    // No host is needed: `cell_print_int` is in the runtime.
    var e = try emitSource(
        \\pub struct Buffer {
        \\  copy len: Int
        \\}
        \\pub fn print_int(copy value: Int);
        \\pub fn reset(exclusive b: Buffer) {
        \\  b = Buffer { len: 42 }
        \\}
        \\pub fn bump(exclusive b: Buffer) {
        \\  b.len = b.len + 5
        \\}
        \\pub fn main() {
        \\  let owned buf = Buffer { len: 1 }
        \\  reset(exclusive buf)
        \\  bump(exclusive buf)
        \\  print_int(buf.len)
        \\}
    );
    defer e.deinit();
    // Both sides of the call, because the adjacent LLVM fix a few hours ago
    // turned out to be TWO bugs, one per side, and either alone still
    // printed the wrong number.
    try expectContains(e.text, "  *b = (cell_Buffer){ .len = 42 };");
    try expectContains(e.text, "  cell_reset(&buf);");

    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "body.c", .data = e.text });

    var cwd_buf: [4096]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const root = cwd_buf[0..cwd_len];
    const include = try std.fmt.allocPrint(gpa, "{s}/runtime", .{root});
    defer gpa.free(include);
    const rt_c = try std.fmt.allocPrint(gpa, "{s}/runtime/cell_rt.c", .{root});
    defer gpa.free(rt_c);

    const cc_result = try std.process.run(gpa, io, .{
        .argv = &.{
            "cc",    "-std=c11",                     "-Wall",  "-Wextra", "-Werror",
            "-g",    "-fsanitize=address,undefined", "body.c", rt_c,      "-I",
            include, "-o",                           "body",
        },
        .cwd = .{ .dir = tmp.dir },
    });
    defer gpa.free(cc_result.stdout);
    defer gpa.free(cc_result.stderr);
    if (!cc_result.term.success()) {
        std.debug.print("cc rejected emitted C:\n{s}\n--- source ---\n{s}\n", .{ cc_result.stderr, e.text });
        return error.CcRejectedEmittedC;
    }

    const run_result = try std.process.run(gpa, io, .{
        .argv = &.{"./body"},
        .cwd = .{ .dir = tmp.dir },
    });
    defer gpa.free(run_result.stdout);
    defer gpa.free(run_result.stderr);
    if (!run_result.term.success()) {
        std.debug.print(
            "the emitted program did not exit cleanly:\nstdout:\n{s}\nstderr:\n{s}\n",
            .{ run_result.stdout, run_result.stderr },
        );
        return error.ProgramCrashed;
    }
    // 6 means the whole-value write went to a copy the caller never sees.
    try std.testing.expectEqualStrings("47\n", run_result.stdout);
}

test "a moved value is not dropped" {
    // The double-free guard: `s` is moved into `take` (borrowck's call-site
    // move, R1/R2), so it must never reach `cell_string_free`.
    var e = try emitSource(
        \\pub fn make() -> String;
        \\pub fn take(owned s: String) { }
        \\pub fn f() {
        \\  let owned s = make()
        \\  take(owned s)
        \\}
    );
    defer e.deinit();
    try expectAbsent(try fnDef(e.text, "f"), "cell_string_free");
}

test "a value moved in one branch of an if is released on the other" {
    // R16 residual 1: the merge still records `s` moved, so the scope-end
    // drop skips it. The non-moving branch now releases it at its own end.
    var e = try emitSource(
        \\pub fn make() -> String;
        \\pub fn take(owned s: String) { }
        \\pub fn f(shared c: Bool) {
        \\  let owned s = make()
        \\  if (c) {
        \\    take(owned s)
        \\  }
        \\}
    );
    defer e.deinit();
    const f = try fnDef(e.text, "f");
    try expectOccurrences(f, "cell_string_free(&s);", 1);
    try expectContains(f, "} else {\n    cell_string_free(&s);\n  }");
}

test "a value moved only AFTER an if or match is not released inside it" {
    // Found 2026-09-17 while grounding IR String step (b). The branch-end
    // release (1eaed84, extended to match arms in 38e33a2) asked "moved
    // somewhere in the function" and "dead at the enclosing block's end",
    // so a value moved by a statement AFTER an unrelated if/match was freed
    // at the end of every branch, and the later move read a freed header:
    // `print_int(e + take(ns))` printed 1 in C where LLVM printed 43, with
    // AddressSanitizer silent because the free zeroes the header. The fix
    // asks borrowck whether the value is still held right after the merge
    // (`ExitKind.after_branch`); only a value some branch moved is released.
    var e = try emitSource(
        \\pub struct Pair { owned a: String, owned b: String }
        \\pub fn make() -> String;
        \\pub fn pair() -> Pair;
        \\pub fn print_int(copy value: Int);
        \\pub fn take(owned s: String) -> Int;
        \\pub fn eat(owned p: Pair) -> Int;
        \\pub fn f(copy flag: Bool) {
        \\  let owned s = make()
        \\  let owned p = pair()
        \\  let owned q = pair()
        \\  if flag { print_int(1) } else { print_int(0) }
        \\  match flag {
        \\    true => print_int(2),
        \\    false => print_int(3),
        \\  }
        \\  let copy e = match flag {
        \\    true => 1,
        \\    false => 0,
        \\  }
        \\  if flag { print_int(4) } else if e > 0 { print_int(5) }
        \\  print_int(e + take(s) + eat(p) + take(q.a))
        \\}
    );
    defer e.deinit();
    const f = try fnDef(e.text, "f");
    try expectAbsent(f, "cell_string_free(&s);");
    try expectAbsent(f, "cell_drop_Pair(&p);");
    try expectAbsent(f, "cell_string_free(&q.a);");
    // q.b is still released once, at function end.
    try expectOccurrences(f, "cell_string_free(&q.b);", 1);
}

test "a value moved on one branch is still released on the other, after the fix" {
    // The case the branch-end release exists for must survive the
    // after_branch guard: moved in `then`, held in `else`, dead after.
    var e = try emitSource(
        \\pub fn make() -> String;
        \\pub fn take(owned s: String) -> Int;
        \\pub fn print_int(copy value: Int);
        \\pub fn f(copy flag: Bool) {
        \\  let owned s = make()
        \\  match flag {
        \\    true => print_int(take(s)),
        \\    false => print_int(0),
        \\  }
        \\}
    );
    defer e.deinit();
    const f = try fnDef(e.text, "f");
    try expectOccurrences(f, "cell_string_free(&s);", 1);
}

test "a value revived in a loop and read after it is not released at the loop exit" {
    // Found 2026-09-17 while grounding IR String step (c). The after-loop
    // release held back only when the enclosing block end recorded the
    // value live, and `loop_moved` forces that record false, so a READ
    // after the loop was never considered: C emitted
    // `cell_string_free(&s); cell_print(cell_string_as_str(&s));` and
    // printed an empty line where LLVM and MLIR printed "again". Silent:
    // the free zeroes the header, so ASan and the malloc counter saw nothing.
    // Now a binding mentioned after the loop (in the rest of any enclosing
    // block, or anywhere in an enclosing loop body) is not released there;
    // it leaks instead, the safe direction, until the drop is precise.
    var e = try emitSource(
        \\pub fn print(shared msg: String);
        \\pub fn take(owned s: String);
        \\pub fn str_len(shared s: String) -> Int;
        \\pub fn f() {
        \\  var owned s: String = "first"
        \\  var j = 0
        \\  while j < 2 {
        \\    take(owned s)
        \\    s = "again"
        \\    j = j + 1
        \\  }
        \\  print(shared s)
        \\}
        \\pub fn g(copy flag: Bool) -> Int {
        \\  var owned t: String = "x"
        \\  if flag {
        \\    var j = 0
        \\    while j < 2 {
        \\      take(owned t)
        \\      t = "y"
        \\      j = j + 1
        \\    }
        \\  }
        \\  return str_len(shared t)
        \\}
        \\pub fn h() {
        \\  var owned u: String = "p"
        \\  var j = 0
        \\  while j < 2 {
        \\    take(owned u)
        \\    u = "q"
        \\    j = j + 1
        \\  }
        \\}
    );
    defer e.deinit();
    const f = try fnDef(e.text, "f");
    try expectAbsent(f, "cell_string_free(&s);\n  cell_print");
    const g = try fnDef(e.text, "g");
    try expectAbsent(g, "cell_string_free(&t);");
    // Not read after the loop: the after-loop release is still right.
    const h = try fnDef(e.text, "h");
    try expectOccurrences(h, "cell_string_free(&u);", 1);
}

test "a value moved by being returned is not dropped" {
    // The third of borrowck's four move sites (`movePlace` is called from
    // the `return` arm), and until now the only one with no test. It is the
    // site where a wrong drop is worst: emitting a free here would lower to
    // `tmp = s; cell_string_free(&s); return tmp;`, handing every caller a
    // struct whose buffer this function already released -- a use after
    // free at the CALL site, where nothing in this file would see it.
    var e = try emitSource(
        \\pub fn make() -> String;
        \\pub fn f() -> String {
        \\  let owned s = make()
        \\  return s
        \\}
    );
    defer e.deinit();
    try expectAbsent(e.text, "cell_string_free");
}

test "a value moved into another let binding is not dropped, but its new owner is" {
    // The last untested move site: `let owned b = a` moves `a` into `b`.
    // This pins both halves of the transfer in one program, which neither
    // safety test above does: the source must NOT be freed (it no longer
    // owns anything) and the destination MUST be (it now does). A single
    // `expectAbsent` on "cell_string_free" would pass vacuously if drops
    // stopped firing altogether, so the positive half is what keeps this
    // test honest.
    var e = try emitSource(
        \\pub fn make() -> String;
        \\pub fn f() {
        \\  let owned a = make()
        \\  let owned b = a
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_string_free(&b);");
    try expectAbsent(e.text, "cell_string_free(&a);");
}

test "an unmoved owned String local is freed at scope end" {
    var e = try emitSource(
        \\pub fn make() -> String;
        \\pub fn f() {
        \\  let owned s = make()
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_string_free(&s);");
}

test "a record with one owning field moved out releases the other field, not the moved one" {
    // The partial-move leak. `p.a` is moved into `m`, so `m` owns that
    // buffer and releases it; `p.b` is still `p`'s, and before
    // `moved_paths` nothing released it because the whole record was
    // skipped. Counted, not just searched for: a free of `p.a` here would be
    // a double free, and `expectContains` passes just as happily on two.
    var e = try emitSource(
        \\pub struct Pair {
        \\    owned a: String
        \\    owned b: String
        \\}
        \\pub fn f() {
        \\  let owned p: Pair = Pair { a: "x", b: "y" }
        \\  let owned m: String = p.a
        \\}
    );
    defer e.deinit();
    try expectOccurrences(e.text, "cell_string_free(&p.b);", 1);
    try expectAbsent(e.text, "cell_string_free(&p.a);");
    try expectAbsent(e.text, "cell_drop_Pair(&p);");
    try expectOccurrences(e.text, "cell_string_free(&m);", 1);
}

test "a record whose only owning field was moved out releases nothing of its own" {
    // The case the old all-or-nothing skip happened to get RIGHT, pinned so
    // the partial drop cannot regress it: the one droppable field is gone,
    // so releasing it, or calling the glue, would free `m`'s buffer twice.
    var e = try emitSource(
        \\pub struct One {
        \\    owned a: String
        \\    copy n: Int
        \\}
        \\pub fn f() {
        \\  let owned p: One = One { a: "x", n: 1 }
        \\  let owned m: String = p.a
        \\}
    );
    defer e.deinit();
    try expectAbsent(e.text, "cell_string_free(&p.a);");
    try expectAbsent(e.text, "cell_drop_One(&p);");
    try expectOccurrences(e.text, "cell_string_free(&m);", 1);
}

test "a field moved on only one branch of an if is released on the other" {
    // Residual 1 at field granularity. The merge still records `p.a` moved,
    // so the scope-end partial drop skips it. The non-moving branch now
    // releases it at its own end. `p.b` was never moved and is released
    // once at scope end. The whole record is never dropped on the else
    // path: that would double-free `p.b` with the later partial drop.
    // Falsified 2026-09-16: freeing `cell_drop_Pair(&p)` on the else path,
    // freeing `p.a` at scope end as well as else, or freeing `p.a` on the
    // then path, each AddressSanitizer double free at exit 134. Restored.
    var e = try emitSource(
        \\pub struct Pair {
        \\    owned a: String
        \\    owned b: String
        \\}
        \\pub fn take(owned s: String) { }
        \\pub fn f(shared c: Bool) {
        \\  let owned p: Pair = Pair { a: "x", b: "y" }
        \\  if (c) {
        \\    take(owned p.a)
        \\  }
        \\}
    );
    defer e.deinit();
    const f = try fnDef(e.text, "f");
    try expectOccurrences(f, "cell_string_free(&p.a);", 1);
    try expectContains(f, "} else {\n    cell_string_free(&p.a);\n  }");
    try expectOccurrences(f, "cell_string_free(&p.b);", 1);
    try expectAbsent(f, "cell_drop_Pair(&p);");
}

test "a record moved as a whole after nothing else is still not dropped at all" {
    // `wasWhollyMoved` is the gate that keeps the partial path from ever
    // touching a record that went away entirely; `q` now owns both fields.
    var e = try emitSource(
        \\pub struct Pair {
        \\    owned a: String
        \\    owned b: String
        \\}
        \\pub fn f() {
        \\  let owned p: Pair = Pair { a: "x", b: "y" }
        \\  let owned q: Pair = p
        \\}
    );
    defer e.deinit();
    try expectAbsent(e.text, "cell_drop_Pair(&p);");
    try expectAbsent(e.text, "&p.a");
    try expectAbsent(e.text, "&p.b");
    try expectOccurrences(e.text, "cell_drop_Pair(&q);", 1);
}

test "a record with nothing moved still goes through its drop glue" {
    // The partial path is taken only when borrowck recorded a move under
    // the binding; an untouched record keeps the one glue call R11 row 2
    // introduced, rather than an inline expansion of it.
    var e = try emitSource(
        \\pub struct Pair {
        \\    owned a: String
        \\    owned b: String
        \\}
        \\pub fn f() {
        \\  let owned p: Pair = Pair { a: "x", b: "y" }
        \\}
    );
    defer e.deinit();
    try expectOccurrences(e.text, "cell_drop_Pair(&p);", 1);
    try expectAbsent(e.text, "fields moved out");
}

test "a skip-revival continue does not free a field taken before the jump" {
    // The walk still sees `p.a = "c"` after `continue`, which retracts
    // `fieldWasMoved`. Freeing `p.a` at the jump would double-free with
    // `take`. Dead at this jump => skip; `p.b` is still released.
    var e = try emitSource(
        \\pub struct Pair {
        \\    owned a: String
        \\    owned b: String
        \\}
        \\pub fn take(owned s: String) { }
        \\pub fn f() {
        \\  var i = 0
        \\  while i < 1 {
        \\    var owned p: Pair = Pair { a: "x", b: "y" }
        \\    take(owned p.a)
        \\    if i < 1 { continue }
        \\    p.a = "c"
        \\    i = i + 1
        \\  }
        \\}
    );
    defer e.deinit();
    const f = try fnDef(e.text, "f");
    try expectContains(f, "cell_string_free(&p.b);");
    try expectLineBefore(f, "continue;", "cell_string_free(&p.b);");
}

test "a field revived after it was moved is released at scope end" {
    // R16 field revival. `take(owned p.a)` marks `a` moved; `p.a = "c"`
    // revives it. Before, `moved_paths` stayed set, so the partial drop
    // skipped the new value. `p.b` was never moved. Still partial: no
    // whole-record glue (that would double-free if `a` had not revived).
    var e = try emitSource(
        \\pub struct Pair {
        \\    owned a: String
        \\    owned b: String
        \\}
        \\pub fn take(owned s: String) { }
        \\pub fn f() {
        \\  var owned p: Pair = Pair { a: "x", b: "y" }
        \\  take(owned p.a)
        \\  p.a = "c"
        \\}
    );
    defer e.deinit();
    const f = try fnDef(e.text, "f");
    try expectOccurrences(f, "cell_string_free(&p.a);", 1);
    try expectOccurrences(f, "cell_string_free(&p.b);", 1);
    try expectAbsent(f, "cell_drop_Pair(&p);");
}

test "a moved field of a nested record releases the sibling, not the moved field" {
    // `p.inner.a` moves only part of `p.inner`. Recursing the partial drop
    // frees `p.inner.b` and skips `p.inner.a` (`m` owns that buffer). The
    // whole-inner glue and the outer glue stay absent: either would free
    // `m` a second time. Falsified 2026-09-16 by emitting
    // `cell_drop_Inner(&p.inner)` (and separately `cell_string_free(&p.inner.a)`)
    // on this program: AddressSanitizer double free of `m`, exit 134.
    // Restored; the sibling free is the remaining owning field, not glue.
    var e = try emitSource(
        \\pub struct Inner {
        \\    owned a: String
        \\    owned b: String
        \\}
        \\pub struct Outer {
        \\    owned inner: Inner
        \\    owned tag: String
        \\}
        \\pub fn f() {
        \\  let owned p: Outer = Outer { inner: Inner { a: "x", b: "y" }, tag: "t" }
        \\  let owned m: String = p.inner.a
        \\}
    );
    defer e.deinit();
    try expectOccurrences(e.text, "cell_string_free(&p.inner.b);", 1);
    try expectAbsent(e.text, "cell_string_free(&p.inner.a);");
    try expectAbsent(e.text, "cell_drop_Inner(&p.inner);");
    try expectAbsent(e.text, "cell_drop_Outer(&p);");
    try expectOccurrences(e.text, "cell_string_free(&p.tag);", 1);
    try expectOccurrences(e.text, "cell_string_free(&m);", 1);
}

test "an unmoved arc local gets cell_arc_drop, by value with no ampersand" {
    var e = try emitSource(
        \\pub fn f(arc p: String) {
        \\  let arc s = p
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_arc_drop(s);");
    try expectAbsent(e.text, "cell_arc_drop(&s)");
}

// ── arc retain insertion, OWNERSHIP.md R11 (task 4b) ────────────────────

test "an arc binding is a cell_arc_t and a literal initializer is boxed" {
    var e = try emitSource(
        \\pub fn f() {
        \\  let arc s = "x"
        \\}
    );
    defer e.deinit();
    // R11 rule 1: the box does not exist yet, so this is cell_arc_new by way
    // of the from_string helper, not a clone. cell_string_from_str copies the
    // literal's characters onto the heap, so the box owns them outright.
    try expectContains(e.text,
        \\  cell_arc_t s = cell_arc_from_string(cell_string_from_str(cell_str_from_parts("x", 1)));
    );
    try expectAbsent(e.text, "cell_arc_clone");
}
