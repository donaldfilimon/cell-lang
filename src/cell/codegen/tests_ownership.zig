//! C backend tests, third quarter in original order: revived-var releases,
//! owning Result instances, and R11 rows 1 and 2.

const std = @import("std");
const cg_tests_support = @import("tests_support.zig");
const emitSource = cg_tests_support.emitSource;
const expectContains = cg_tests_support.expectContains;
const fnDef = cg_tests_support.fnDef;
const expectCompiles = cg_tests_support.expectCompiles;
const expectAbsent = cg_tests_support.expectAbsent;
const expectLineBefore = cg_tests_support.expectLineBefore;
const expectOccurrences = cg_tests_support.expectOccurrences;

test "a revived var is released at the exits where borrowck saw it live" {
    // borrowck's `exit_liveness`, 2026-09-16. Before it, `wasMoved` was
    // permanent for the scope-end drop, so every one of these leaked the
    // revived value (measured with the gate's malloc counter).
    var e = try emitSource(
        \\pub fn take(owned s: String);
        \\pub fn at_end() {
        \\  var owned v: String = "a"
        \\  take(v)
        \\  v = "b"
        \\}
        \\pub fn at_return(copy c: Int) -> Int {
        \\  var owned v: String = "a"
        \\  take(v)
        \\  if c > 0 {
        \\    return 2
        \\  }
        \\  v = "b"
        \\  return 3
        \\}
        \\pub fn in_block() {
        \\  {
        \\    var owned v: String = "a"
        \\    take(v)
        \\    v = "b"
        \\  }
        \\}
        \\pub fn param(owned s: String) {
        \\  take(s)
        \\  s = "p"
        \\}
        \\pub fn list() {
        \\  var owned xs: [Int] = [1, 2]
        \\  var owned ys: [Int] = xs
        \\  xs = [3]
        \\}
        \\pub fn loop_local(copy n: Int) {
        \\  var i = 0
        \\  while i < 3 {
        \\    i = i + 1
        \\    var owned v: String = "a"
        \\    take(v)
        \\    if i > n {
        \\      continue
        \\    }
        \\    v = "b"
        \\  }
        \\}
    );
    defer e.deinit();
    const at_end = try fnDef(e.text, "at_end");
    try expectOccurrences(at_end, "cell_string_free(&v);", 1);
    const at_return = try fnDef(e.text, "at_return");
    // Only the `return 3` path, after the revival; `return 2` has no value.
    try expectOccurrences(at_return, "cell_string_free(&v);", 1);
    try expectLineBefore(at_return, "cell_string_free(&v);", "int64_t _cell_t0 = 3;");
    try expectContains(at_return, "return 2;");
    const in_block = try fnDef(e.text, "in_block");
    try expectOccurrences(in_block, "cell_string_free(&v);", 1);
    const param = try fnDef(e.text, "param");
    try expectOccurrences(param, "cell_string_free(&s);", 1);
    const list = try fnDef(e.text, "list");
    try expectOccurrences(list, "cell_slice_free(&xs);", 1);
    try expectOccurrences(list, "cell_slice_free(&ys);", 1);
    // Declared inside the body, so the back edge carries none of its moves:
    // the body end releases it, the `continue` path does not.
    const loop_local = try fnDef(e.text, "loop_local");
    try expectOccurrences(loop_local, "cell_string_free(&v);", 1);
    try expectLineBefore(loop_local, "cell_string_free(&v);", "v = cell_string_from_str(cell_str_from_parts(\"b\", 1));");
    try expectCompiles(e.text);
}

test "a revived var stays unreleased where the path may not hold a value" {
    // Each shape is accepted by borrowck and would be a double free if the
    // revival were trusted. `break_after` and `back_edge` were measured as
    // AddressSanitizer double frees (exit 134) with `loop_moved` and with
    // the in-loop invalidation removed, respectively.
    var e = try emitSource(
        \\pub fn take(owned s: String);
        \\pub fn one_branch(copy c: Int) {
        \\  var owned v: String = "a"
        \\  take(v)
        \\  if c > 0 {
        \\    v = "b"
        \\  }
        \\}
        \\pub fn moved_again() {
        \\  var owned v: String = "a"
        \\  take(v)
        \\  v = "b"
        \\  take(v)
        \\}
        \\pub fn break_after(copy n: Int) {
        \\  var owned v: String = "a"
        \\  var i = 0
        \\  while i < 3 {
        \\    i = i + 1
        \\    take(v)
        \\    if i > n {
        \\      break
        \\    }
        \\    v = "b"
        \\  }
        \\}
        // back_edge is refused by `cell check` since 2026-09-16 (R2.a at a `continue`); kept only for the drop decision.
        \\pub fn back_edge() {
        \\  var owned v: String = "a"
        \\  var i = 0
        \\  while i < 3 {
        \\    i = i + 1
        \\    if i > 1 {
        \\      return
        \\    }
        \\    take(v)
        \\    if i < 2 {
        \\      continue
        \\    }
        \\    v = "b"
        \\  }
        \\}
    );
    defer e.deinit();
    // one_branch: revival on the then path is released at that branch's end.
    const one = try fnDef(e.text, "one_branch");
    try expectOccurrences(one, "cell_string_free(&v);", 1);
    for ([_][]const u8{ "moved_again", "back_edge" }) |name| {
        const body = try fnDef(e.text, name);
        try expectAbsent(body, "cell_string_free(&v);");
    }
    // break_after is the skip-revival `break` (after_loop_skip, 2026-09-17):
    // released after the loop only behind the jump that keeps the dead
    // `break` path away from it. A plain `break` would reach the release.
    const after = try fnDef(e.text, "break_after");
    try expectOccurrences(after, "cell_string_free(&v);", 1);
    try expectAbsent(after, "break;");
    try expectLineBefore(after, "cell_skip_0:;", "cell_string_free(&v);");
    try expectCompiles(e.text);
}

test "an outer var revived across a while is released after the loop" {
    // R16 after_loop, 2026-09-16. `loop_moved` still poisons in-loop jumps
    // and the function-end `block_end`; the drop is the one after `}`.
    // Guards falsified under AddressSanitizer (exit 134) then restored:
    // ignoring a dead `.jump` (`take(v); if i > n { break }; v = "b"`)
    // double-frees because C `break` runs this drop; emitting it for
    // unmoved locals double-frees with function-end; dropping the outer
    // var at `continue` (`take(v); v = "b"; continue`) is a use-after-free
    // on the next iteration; treating a condition move as live
    // (`while consume(v) { v = make() }`) double-frees because the last
    // failing condition already took `v`.
    var e = try emitSource(
        \\pub fn take(owned s: String);
        \\pub fn cross() {
        \\  var owned v: String = "a"
        \\  var i = 0
        \\  while i < 3 {
        \\    take(v)
        \\    v = "b"
        \\    i = i + 1
        \\  }
        \\}
        \\pub fn revival_then_break(copy n: Int) {
        \\  var owned v: String = "a"
        \\  var i = 0
        \\  while i < 3 {
        \\    i = i + 1
        \\    take(v)
        \\    v = "b"
        \\    if i > n {
        \\      break
        \\    }
        \\  }
        \\}
        \\pub fn skip_revival_break(copy n: Int) {
        \\  var owned v: String = "a"
        \\  var i = 0
        \\  while i < 3 {
        \\    i = i + 1
        \\    take(v)
        \\    if i > n {
        \\      break
        \\    }
        \\    v = "b"
        \\  }
        \\}
        \\pub fn untouched() {
        \\  var owned v: String = "a"
        \\  var i = 0
        \\  while i < 3 {
        \\    i = i + 1
        \\  }
        \\}
    );
    defer e.deinit();
    const cross = try fnDef(e.text, "cross");
    try expectOccurrences(cross, "cell_string_free(&v);", 1);
    try expectContains(cross, "}\n  cell_string_free(&v);\n}");
    const revival_break = try fnDef(e.text, "revival_then_break");
    try expectOccurrences(revival_break, "cell_string_free(&v);", 1);
    try expectContains(revival_break, "}\n  cell_string_free(&v);\n}");
    try expectAbsent(revival_break, "cell_string_free(&v);\n      break;");
    // skip-revival break (after_loop_skip, 2026-09-17): released after the
    // loop, and the dead `break` jumps past that release. A plain `break`
    // there was an AddressSanitizer double free (exit 134), measured.
    const skip = try fnDef(e.text, "skip_revival_break");
    try expectOccurrences(skip, "cell_string_free(&v);", 1);
    try expectContains(skip, "goto cell_skip_");
    try expectAbsent(skip, "break;");
    try expectContains(skip, "}\n  cell_string_free(&v);\n  cell_skip_");
    // Unmoved: function-end drops it. after_loop must not, or this is a
    // double free with the scope-end drop (measured, exit 134).
    try expectOccurrences(try fnDef(e.text, "untouched"), "cell_string_free(&v);", 1);
    try expectCompiles(e.text);
}

test "a skip-revival break is lowered as a jump only where every release agrees" {
    // after_loop_skip guards, 2026-09-17. Each negative keeps the leak (no
    // release, no goto): the var belongs to an enclosing loop's block and
    // the inner `break` is dead (`nested`; the outer loop sees a dead jump
    // that is not its own `break`), two vars are dead at different breaks
    // (`mixed`), or the loop also has a var released on every path
    // (`with_plain`); in the last two no single label serves every break.
    // `live_and_dead` and `record` are positives: a `break` that still
    // holds the value stays a `break` and runs the release, and a record
    // moved whole is released through its drop glue.
    var e = try emitSource(
        \\pub fn take(owned s: String);
        \\pub fn nested(copy n: Int) {
        \\  var owned v: String = "a"
        \\  var j = 0
        \\  while j < 2 {
        \\    j = j + 1
        \\    var i = 0
        \\    while i < 3 {
        \\      i = i + 1
        \\      take(v)
        \\      if i > n {
        \\        break
        \\      }
        \\      v = "b"
        \\    }
        \\    v = "c"
        \\  }
        \\}
        \\pub fn live_and_dead(copy n: Int) {
        \\  var owned v: String = "a"
        \\  var i = 0
        \\  while i < 3 {
        \\    i = i + 1
        \\    if i > 5 {
        \\      break
        \\    }
        \\    take(v)
        \\    if i > n {
        \\      break
        \\    }
        \\    v = "b"
        \\  }
        \\}
        \\pub fn mixed(copy n: Int) {
        \\  var owned v: String = "a"
        \\  var owned w: String = "a"
        \\  var i = 0
        \\  while i < 3 {
        \\    i = i + 1
        \\    take(v)
        \\    if i > n {
        \\      break
        \\    }
        \\    v = "b"
        \\    take(w)
        \\    if i > 1 {
        \\      break
        \\    }
        \\    w = "b"
        \\  }
        \\}
        \\pub struct P { a: String, b: String }
        \\pub fn take_p(owned p: P);
        \\pub fn record(copy n: Int, owned p0: P) {
        \\  var owned q: P = p0
        \\  var i = 0
        \\  while i < 3 {
        \\    i = i + 1
        \\    take_p(q)
        \\    if i > n {
        \\      break
        \\    }
        \\    q = P { a: "x", b: "y" }
        \\  }
        \\}
        \\pub fn with_plain(copy n: Int) {
        \\  var owned v: String = "a"
        \\  var owned w: String = "a"
        \\  var i = 0
        \\  while i < 3 {
        \\    i = i + 1
        \\    take(w)
        \\    w = "b"
        \\    take(v)
        \\    if i > n {
        \\      break
        \\    }
        \\    v = "b"
        \\  }
        \\}
    );
    defer e.deinit();
    const nested = try fnDef(e.text, "nested");
    try expectAbsent(nested, "goto");
    try expectAbsent(nested, "cell_string_free(&v);");
    // A `break` still holding the value is ordinary and runs the release;
    // only the dead one jumps past it.
    const both = try fnDef(e.text, "live_and_dead");
    try expectOccurrences(both, "cell_string_free(&v);", 1);
    try expectOccurrences(both, "break;", 1);
    try expectOccurrences(both, "goto cell_skip_", 1);
    const mixed = try fnDef(e.text, "mixed");
    try expectAbsent(mixed, "goto");
    try expectAbsent(mixed, "cell_string_free(&v);");
    try expectAbsent(mixed, "cell_string_free(&w);");
    // A whole-moved record takes the same route through its drop glue.
    const rec = try fnDef(e.text, "record");
    try expectOccurrences(rec, "cell_drop_P(&q);", 1);
    try expectOccurrences(rec, "goto cell_skip_", 1);
    try expectAbsent(rec, "break;");
    const plain = try fnDef(e.text, "with_plain");
    try expectAbsent(plain, "goto");
    try expectAbsent(plain, "cell_string_free(&v);");
    try expectCompiles(e.text);
}

test "a return inside a loop releases an outer var only where it holds a value" {
    // 2026-09-17: an accepted loop's `return` records stay live. `before`
    // (live on every iteration: R2.a) and `after` (revived) release `v`
    // at the return; `between` (moved, not yet revived) must not. The
    // rejected-loop guard is pinned by `back_edge` above.
    var e = try emitSource(
        \\pub fn take(owned s: String);
        \\pub fn before(copy n: Int) {
        \\  var owned v: String = "a"
        \\  var i = 0
        \\  while i < 3 {
        \\    i = i + 1
        \\    if i > n {
        \\      return
        \\    }
        \\    take(v)
        \\    v = "b"
        \\  }
        \\}
        \\pub fn after(copy n: Int) {
        \\  var owned v: String = "a"
        \\  var i = 0
        \\  while i < 3 {
        \\    i = i + 1
        \\    take(v)
        \\    v = "b"
        \\    if i > n {
        \\      return
        \\    }
        \\  }
        \\}
        \\pub fn between(copy n: Int) {
        \\  var owned v: String = "a"
        \\  var i = 0
        \\  while i < 3 {
        \\    i = i + 1
        \\    take(v)
        \\    if i > n {
        \\      return
        \\    }
        \\    v = "b"
        \\  }
        \\}
    );
    defer e.deinit();
    for ([_][]const u8{ "before", "after" }) |name| {
        const body = try fnDef(e.text, name);
        try expectLineBefore(body, "return;", "cell_string_free(&v);");
    }
    const between = try fnDef(e.text, "between");
    try expectLineBefore(between, "return;", "if (i > n) {");
    try expectCompiles(e.text);
}

test "indexing a list reads with the stride the list was built with" {
    // 2026-09-17. Declared, inferred and borrowed lists each pick the
    // bounds-checked reader for their element type.
    var e = try emitSource(
        \\pub fn first(shared xs: [Float]) -> Float? {
        \\  return xs[0]
        \\}
        \\pub fn main() {
        \\  let owned ns = [40, 2]
        \\  let copy a = ns[1]
        \\  let owned bs: [Bool] = [true]
        \\  let copy b = bs[0]
        \\}
    );
    defer e.deinit();
    try expectContains(try fnDef(e.text, "first"), "cell_list_f64_at(");
    const main_body = try fnDef(e.text, "main");
    try expectContains(main_body, "cell_opt_i64_t a = cell_list_i64_at(ns, 1);");
    try expectContains(main_body, "cell_opt_bool_t b = cell_list_bool_at(bs, 0);");
    try expectAbsent(e.text, "cell_index_of_");
    try expectCompiles(e.text);
}

pub const owning_result_prelude =
    \\pub fn take(owned s: String);
    \\pub fn view(shared s: String) -> Int;
    \\pub fn read() -> Result<String, Int32>;
    \\
;

test "an owning String Result has its own instance and per-module release glue" {
    // Owning String in Ok (2026-09-17).
    var e = try emitSource(owning_result_prelude ++
        \\pub fn relay() -> Result<String, Int32> {
        \\  return read()
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_res_string_i32_t cell_read(void);");
    try expectOccurrences(e.text, "static inline __attribute__((unused)) void cell_drop_res_string_i32(cell_res_string_i32_t *r);", 1);
    try expectContains(e.text, "if (r->ok) cell_string_free(&r->as.ok);");
    try expectCompiles(e.text);

    var plain = try emitSource(
        \\pub fn f(copy r: Result<Int, Int32>) -> Int {
        \\  return 0
        \\}
    );
    defer plain.deinit();
    try expectAbsent(plain.text, "cell_drop_res_");
}

test "Ok moves a resolved owning operand and copies one it was not told moved" {
    var e = try emitSource(owning_result_prelude ++
        \\pub fn moved(owned s: String) -> Result<String, Int32> {
        \\  return Ok(s)
        \\}
        \\pub fn make() -> String;
        \\pub fn copied(copy c: Int) -> Result<String, Int32> {
        \\  let owned s = if c > 0 { make() } else { make() }
        \\  return Ok(s)
        \\}
    );
    defer e.deinit();
    const m = try fnDef(e.text, "moved");
    try expectContains(m, "cell_res_string_i32_ok(s)");
    try expectAbsent(m, "cell_string_free(&s);");
    // borrowck cannot type `s` here, so it only read it; the header is
    // copied into the Result and `s` keeps (and releases) its own.
    const c = try fnDef(e.text, "copied");
    try expectContains(c, "cell_res_string_i32_ok(cell_string_clone(&s))");
    try expectContains(c, "cell_string_free(&s);");
    try expectCompiles(e.text);
}

test "Ok(owned ..) binds the payload and the Result is released on the other arm" {
    var e = try emitSource(owning_result_prelude ++
        \\pub fn f(owned r: Result<String, Int32>) {
        \\  match r {
        \\    Ok(owned x) => take(x),
        \\    Err(_) => {},
        \\  }
        \\}
        \\pub fn g(owned r: Result<String, Int32>) -> Int {
        \\  return match r {
        \\    Ok(owned x) => view(x),
        \\    Err(_) => 0,
        \\  }
        \\}
    );
    defer e.deinit();
    const f = try fnDef(e.text, "f");
    try expectContains(f, "cell_string_t x = _cell_t");
    try expectContains(f, ".as.ok;");
    try expectAbsent(f, "cell_string_free(&x);");
    try expectOccurrences(f, "cell_drop_res_string_i32(&r);", 1);
    const g = try fnDef(e.text, "g");
    try expectOccurrences(g, "cell_string_free(&x);", 1);
    try expectOccurrences(g, "cell_drop_res_string_i32(&r);", 1);
    try expectCompiles(e.text);
}

test "Ok(shared ..) binds a view and the Result is released after the match" {
    var e = try emitSource(owning_result_prelude ++
        \\pub fn f(owned r: Result<String, Int32>) -> Int {
        \\  let n = match r {
        \\    Ok(shared x) => view(x),
        \\    Err(_) => 0,
        \\  }
        \\  return n
        \\}
    );
    defer e.deinit();
    const f = try fnDef(e.text, "f");
    try expectContains(f, "cell_str_t x = cell_string_as_str(&_cell_t");
    try expectAbsent(f, "cell_string_free(&x);");
    try expectOccurrences(f, "cell_drop_res_string_i32(&r);", 1);
    try expectCompiles(e.text);
}

test "a temporary owning Result is released in every arm that does not take it" {
    var e = try emitSource(owning_result_prelude ++
        \\pub fn f() -> Int {
        \\  return match read() {
        \\    Ok(owned x) => view(x),
        \\    Err(_) => 0,
        \\  }
        \\}
    );
    defer e.deinit();
    const f = try fnDef(e.text, "f");
    try expectOccurrences(f, "cell_drop_res_string_i32(&_cell_t", 1);
    try expectCompiles(e.text);
}

test "reassigning an owning Result var releases the old value first" {
    var e = try emitSource(owning_result_prelude ++
        \\pub fn f() {
        \\  var owned r: Result<String, Int32> = read()
        \\  r = read()
        \\}
    );
    defer e.deinit();
    const f = try fnDef(e.text, "f");
    try expectOccurrences(f, "cell_drop_res_string_i32(&r);", 2);
    try expectCompiles(e.text);
}

test "an owning String error is bound, released per side, and copied when unresolved" {
    // Sub-project 3 (2026-09-17).
    var e = try emitSource(
        \\pub fn take(owned s: String);
        \\pub fn view(shared s: String) -> Int;
        \\pub fn make() -> String;
        \\pub fn read() -> Result<Int, String>;
        \\pub fn both() -> Result<String, String>;
        \\pub fn owned_arm(owned r: Result<Int, String>) -> Int {
        \\  return match r {
        \\    Ok(v) => v,
        \\    Err(owned e) => view(e),
        \\  }
        \\}
        \\pub fn shared_arm(owned r: Result<Int, String>) -> Int {
        \\  return match r {
        \\    Ok(v) => v,
        \\    Err(shared e) => view(e),
        \\  }
        \\}
        \\pub fn temp() -> Int {
        \\  return match read() {
        \\    Ok(v) => v,
        \\    Err(owned e) => view(e),
        \\  }
        \\}
        \\pub fn two() -> Int {
        \\  return match both() {
        \\    Ok(owned a) => view(a),
        \\    Err(shared b) => view(b),
        \\  }
        \\}
        \\pub fn unresolved(copy c: Int) -> Result<Int, String> {
        \\  let owned s = if c > 0 { make() } else { make() }
        \\  return Err(s)
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "if (r->ok) cell_string_free(&r->as.ok); else cell_string_free(&r->as.err);");
    const oa = try fnDef(e.text, "owned_arm");
    try expectContains(oa, "cell_string_t e = _cell_t");
    try expectContains(oa, ".as.err;");
    try expectOccurrences(oa, "cell_string_free(&e);", 1);
    try expectOccurrences(oa, "cell_drop_res_i64_string(&r);", 1);
    const sa = try fnDef(e.text, "shared_arm");
    try expectContains(sa, "cell_str_t e = cell_string_as_str(&_cell_t");
    try expectOccurrences(sa, "cell_drop_res_i64_string(&r);", 1);
    const tp = try fnDef(e.text, "temp");
    try expectOccurrences(tp, "cell_drop_res_i64_string(&_cell_t", 1);
    const tw = try fnDef(e.text, "two");
    try expectOccurrences(tw, "cell_drop_res_string_string(&_cell_t", 1);
    const ur = try fnDef(e.text, "unresolved");
    try expectContains(ur, "cell_res_i64_string_err(cell_string_clone(&s))");
    try expectCompiles(e.text);
}

test "an owning String? is its own instance, bound, released and copied when unresolved" {
    // Sub-project 4 (2026-09-17).
    var e = try emitSource(
        \\pub fn take(owned s: String);
        \\pub fn view(shared s: String) -> Int;
        \\pub fn make() -> String;
        \\pub fn find() -> String?;
        \\pub fn wrap(owned s: String) -> String? {
        \\  return Some(s)
        \\}
        \\pub fn owned_arm(owned o: String?) -> Int {
        \\  return match o {
        \\    Some(owned x) => view(x),
        \\    None => 0,
        \\  }
        \\}
        \\pub fn shared_arm(owned o: String?) -> Int {
        \\  return match o {
        \\    Some(shared x) => view(x),
        \\    None => 0,
        \\  }
        \\}
        \\pub fn temp() -> Int {
        \\  return match find() {
        \\    Some(shared x) => view(x),
        \\    None => 0,
        \\  }
        \\}
        \\pub fn reassign() {
        \\  var owned o: String? = find()
        \\  o = find()
        \\}
        \\pub fn unresolved(copy c: Int) -> String? {
        \\  let owned s = if c > 0 { make() } else { make() }
        \\  return Some(s)
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_opt_string_t cell_find(void);");
    try expectOccurrences(e.text, "static inline __attribute__((unused)) void cell_drop_opt_string(cell_opt_string_t *r);", 1);
    try expectContains(e.text, "if (r->has_value) cell_string_free(&r->value);");
    const w = try fnDef(e.text, "wrap");
    try expectContains(w, "cell_opt_string_some(s)");
    try expectAbsent(w, "cell_string_free(&s);");
    const oa = try fnDef(e.text, "owned_arm");
    try expectContains(oa, "cell_string_t x = _cell_t");
    try expectContains(oa, ".value;");
    try expectOccurrences(oa, "cell_string_free(&x);", 1);
    try expectOccurrences(oa, "cell_drop_opt_string(&o);", 1);
    const sa = try fnDef(e.text, "shared_arm");
    try expectContains(sa, "cell_str_t x = cell_string_as_str(&_cell_t");
    try expectOccurrences(sa, "cell_drop_opt_string(&o);", 1);
    // Neither arm takes the payload, so both release the temporary (the
    // glue is a no-op on `None`).
    try expectOccurrences(try fnDef(e.text, "temp"), "cell_drop_opt_string(&_cell_t", 2);
    try expectOccurrences(try fnDef(e.text, "reassign"), "cell_drop_opt_string(&o);", 2);
    try expectContains(try fnDef(e.text, "unresolved"), "cell_opt_string_some(cell_string_clone(&s))");
    try expectCompiles(e.text);
}

test "a temporary owning scrutinee is released when its arm leaves early" {
    // 2026-09-17: the residual sub-projects 2-4 recorded. A `return` releases
    // every untaken temporary; a `break`/`continue` those created inside the
    // loop it leaves; an arm that took the payload releases nothing.
    var e = try emitSource(
        \\pub fn find() -> String?;
        \\pub fn view(shared s: String) -> Int;
        \\pub fn take(owned s: String);
        \\pub fn early() -> Int {
        \\  match find() {
        \\    Some(shared x) => {
        \\      return view(x)
        \\    },
        \\    None => {},
        \\  }
        \\  return 0
        \\}
        \\pub fn taken() -> Int {
        \\  match find() {
        \\    Some(owned x) => {
        \\      take(x)
        \\      return 1
        \\    },
        \\    None => {},
        \\  }
        \\  return 0
        \\}
        \\pub fn loop_exit(copy n: Int) -> Int {
        \\  var i = 0
        \\  while i < n {
        \\    i = i + 1
        \\    match find() {
        \\      Some(_) => {
        \\        break
        \\      },
        \\      None => {
        \\        continue
        \\      },
        \\    }
        \\  }
        \\  return i
        \\}
    );
    defer e.deinit();
    const early = try fnDef(e.text, "early");
    // Before the early return (after its value is computed), and at the end
    // of the None arm.
    try expectOccurrences(early, "cell_drop_opt_string(&_cell_t", 2);
    const tk = try fnDef(e.text, "taken");
    try expectOccurrences(tk, "cell_drop_opt_string(&_cell_t", 1);
    const lx = try fnDef(e.text, "loop_exit");
    try expectOccurrences(lx, "cell_drop_opt_string(&_cell_t", 2);
    try expectCompiles(e.text);
}

test "a temporary owned String scrutinee is released once on every path out" {
    // 2026-09-17: `match str_from_int(i) { "1" => 1, _ => 2 }` never freed
    // the temporary (examples/leaks/match_string_temp.cell, 1000). String
    // patterns bind nothing, so every arm end and every early exit releases
    // it. A binding arm (`x => ...`) is an alias borrowck lets the body move,
    // so it is treated as taken and keeps the leak rather than risk a double
    // free. A `str` scrutinee (a literal) owns nothing and is never freed.
    var e = try emitSource(
        \\pub fn str_from_int(copy v: Int) -> String;
        \\pub fn take(owned s: String);
        \\pub fn once(copy i: Int) -> Int {
        \\  return match str_from_int(i) {
        \\    "1" => 1,
        \\    _ => 2,
        \\  }
        \\}
        \\pub fn early(copy i: Int) -> Int {
        \\  match str_from_int(i) {
        \\    "1" => {
        \\      return 1
        \\    },
        \\    _ => {},
        \\  }
        \\  return 0
        \\}
        \\pub fn loop_exit(copy n: Int) -> Int {
        \\  var i = 0
        \\  while i < n {
        \\    i = i + 1
        \\    match str_from_int(i) {
        \\      "3" => {
        \\        break
        \\      },
        \\      _ => {
        \\        continue
        \\      },
        \\    }
        \\  }
        \\  return i
        \\}
        \\pub fn bound(copy i: Int) {
        \\  match str_from_int(i) {
        \\    x => take(x),
        \\  }
        \\}
        \\pub fn literal() -> Int {
        \\  return match "a" {
        \\    "a" => 1,
        \\    _ => 2,
        \\  }
        \\}
    );
    defer e.deinit();
    // One per arm end.
    try expectOccurrences(try fnDef(e.text, "once"), "cell_string_free(&_cell_t", 2);
    // Before the early return, and at the end of the `_` arm.
    try expectOccurrences(try fnDef(e.text, "early"), "cell_string_free(&_cell_t", 2);
    // Before the `break` and before the `continue`.
    try expectOccurrences(try fnDef(e.text, "loop_exit"), "cell_string_free(&_cell_t", 2);
    try expectAbsent(try fnDef(e.text, "bound"), "cell_string_free(");
    try expectAbsent(try fnDef(e.text, "literal"), "cell_string_free(");
    try expectCompiles(e.text);
}

test "a binding arm that moves a temporary owning scrutinee does not release it" {
    // 2026-09-17, measured: before the binding rule, `match lookup(i) { x =>
    // eat(x) }` released the `String?` temporary at the arm end after `eat`
    // had freed it, a double free AddressSanitizer reported (exit 134).
    // borrowck accepts the move (the scrutinee has no place), and this
    // backend binds `x` as an undropped bitwise copy, so a binding arm that
    // names the value counts as having taken it. One that never names it
    // still releases the temporary.
    var e = try emitSource(
        \\pub fn lookup(copy n: Int) -> String?;
        \\pub fn eat(owned o: String?) -> Int;
        \\pub fn moved(copy i: Int) -> Int {
        \\  return match lookup(i) {
        \\    x => eat(x),
        \\  }
        \\}
        \\pub fn unnamed(copy i: Int) -> Int {
        \\  return match lookup(i) {
        \\    x => 0,
        \\  }
        \\}
    );
    defer e.deinit();
    try expectAbsent(try fnDef(e.text, "moved"), "cell_drop_opt_string(&_cell_t");
    try expectOccurrences(try fnDef(e.text, "unnamed"), "cell_drop_opt_string(&_cell_t", 1);
    try expectCompiles(e.text);
}

test "the owned reassignment pre-drop is decided per store, not per binding" {
    // borrowck's `assign_liveness`, 2026-09-16. A move AFTER the store no
    // longer blocks it; a move BEFORE it (revival) or IN the right side
    // still does; a revived var's NEXT store releases the revived value; and
    // the scope-end drop releases a revived value (`exit_liveness`).
    var e = try emitSource(
        \\pub fn take(owned s: String);
        \\pub fn pass(owned s: String) -> String { return s }
        \\pub fn later() {
        \\  var owned v: String = "a"
        \\  v = "b"
        \\  take(v)
        \\}
        \\pub fn selfmove() {
        \\  var owned v: String = "a"
        \\  v = pass(v)
        \\}
        \\pub fn chain() {
        \\  var owned v: String = "a"
        \\  take(v)
        \\  v = "b"
        \\  v = "c"
        \\}
    );
    defer e.deinit();
    const later = try fnDef(e.text, "later");
    try expectOccurrences(later, "cell_string_free(&v);", 1);
    try expectLineBefore(later, "cell_take(v);", "v = _cell_t0;");
    // `pass` hands ownership back, so the store is a revival: no pre-drop
    // before it, and since `exit_liveness` (2026-09-16) exactly one release
    // at scope end, after it. This line asserted `expectAbsent` while the
    // revived value still leaked.
    const selfmove = try fnDef(e.text, "selfmove");
    try expectOccurrences(selfmove, "cell_string_free(&v);", 1);
    try expectLineBefore(selfmove, "cell_string_free(&v);", "v = cell_pass(v);");
    const chain = try fnDef(e.text, "chain");
    // Of the stores only "c" pre-drops, and what it releases is "b"; then
    // the scope end releases "c", which is live there (`exit_liveness`).
    // Two frees, one per value that is still owned when its slot is reused
    // or left; before 2026-09-16 the second was absent and "c" leaked.
    try expectOccurrences(chain, "cell_string_free(&v);", 2);
    try expectContains(chain, "v = cell_string_from_str(cell_str_from_parts(\"b\", 1));");
    try expectLineBefore(chain, "cell_string_free(&v);", "cell_string_t _cell_t1 = cell_string_from_str(cell_str_from_parts(\"c\", 1));");
    try expectContains(chain, "v = _cell_t1;\n  cell_string_free(&v);\n}");
    try expectCompiles(e.text);
}

test "a store inside a while body that also moves its target keeps no pre-drop" {
    // The back edge can carry a move made later in the body, including one
    // followed by `continue`, to a store earlier in the next iteration.
    // Without the loop invalidation this exact program was an
    // AddressSanitizer double free (exit 134), measured.
    // loopy is refused by `cell check` since 2026-09-16 (R2.a at a `continue`); kept only for the drop decision.
    var e = try emitSource(
        \\pub fn take(owned s: String);
        \\pub fn loopy() {
        \\  var owned v: String = "a"
        \\  var i = 0
        \\  while i < 3 {
        \\    v = "x"
        \\    i = i + 1
        \\    if i > 1 {
        \\      take(v)
        \\      continue
        \\    }
        \\    v = "y"
        \\  }
        \\}
        \\pub fn untouched() {
        \\  var owned v: String = "a"
        \\  var i = 0
        \\  while i < 3 {
        \\    v = "x"
        \\    i = i + 1
        \\  }
        \\}
    );
    defer e.deinit();
    try expectAbsent(try fnDef(e.text, "loopy"), "cell_string_free(&v);");
    // A loop that never moves its target still releases on every store,
    // plus once at scope end.
    try expectOccurrences(try fnDef(e.text, "untouched"), "cell_string_free(&v);", 2);
    try expectCompiles(e.text);
}

test "a droppable var declared without an initializer is zero-initialized" {
    // Before this the scope-end drop ran on garbage, and the reassignment
    // pre-drop would have too.
    var e = try emitSource(
        \\pub fn f() {
        \\  var arc v: String
        \\  v = "one"
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_arc_t v = (cell_arc_t){0};");
    try expectLineBefore(e.text, "v = _cell_t0;", "cell_arc_drop(v);");
}

test "an arc field store is not a reassignment pre-drop: the record is released by its glue, not per store (row 2)" {
    // Two claims, and until 2026-09-15 this test made only the first and its
    // title made a second that is no longer true. A FIELD store does not
    // pre-drop the old box (that is the stated field-store residual: "one"
    // is overwritten unreleased). The record itself IS dropped now, through
    // R11 row 2's glue at scope end, which releases whatever the field holds
    // at that point ("two"). Asserting the glue call is what keeps this test
    // from passing vacuously: the old needle `cell_arc_drop(b.s)` was never
    // how any drop of a record would be spelled.
    var e = try emitSource(
        \\struct Box { arc s: String }
        \\pub fn f() {
        \\  var owned b = Box { s: "one" }
        \\  b.s = "two"
        \\}
    );
    defer e.deinit();
    try expectAbsent(e.text, "cell_arc_drop(b.s);");
    try expectContains(e.text, "cell_drop_Box(&b);");
    try expectContains(e.text, "  cell_arc_drop(r->s);\n");
}

test "a value-position block's tail resolves through a nested block, and later bindings keep their ids" {
    // Two things at once. The nested block: inference has to push the outer
    // block's `let` as scratch and recurse for the inner one. The id
    // agreement: scratch locals bypass `pushLocal`, so `next_binding_id`
    // must not move during inference; if it drifted, `z` would no longer
    // match borrowck's name for its id, `pushLocal` would clear `droppable`,
    // and `z`'s drop would vanish.
    var e = try emitSource(
        \\pub fn f() {
        \\  let arc r = {
        \\    let arc a = "outer"
        \\    {
        \\      let arc b = a
        \\      b
        \\    }
        \\  }
        \\  let arc z = "after"
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_arc_t r = ({");
    try expectContains(e.text, "cell_arc_drop(z);");
    try expectContains(e.text, "cell_arc_drop(r);");
}

test "an owned block tail is moved into the let, and bindings after the block keep their ids" {
    // borrowck checks the block's statements inside `openBlockTail` (the
    // `let`-only `checkOwnedLetFromBlock` at the time this test was written)
    // and never through `checkExpr(v)`, so `t` must be declared exactly once
    // on its side, in the order codegen declares it. If borrowck declared it
    // twice, `z`'s id would no longer match its name, `pushLocal`'s Debug
    // assert would fire under `zig build test`, and in release `droppable`
    // would clear and `z`'s drop would vanish.
    var e = try emitSource(
        \\pub fn make() -> String;
        \\pub fn f() {
        \\  let owned s = {
        \\    let owned t = make()
        \\    t
        \\  }
        \\  let arc z = "after"
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_string_t s = ({");
    try expectOccurrences(e.text, "cell_string_free(&s);", 1);
    try expectAbsent(e.text, "cell_string_free(&t)");
    try expectContains(e.text, "cell_arc_drop(z);");
}

test "R11 row 2: a struct with an arc field gets drop glue and its local is released" {
    // The pinned fixture's shape (`examples/leaks/struct_arc_field.cell`),
    // which measured 3000 leaks on both witnesses before this and 0 after.
    var e = try emitSource(
        \\struct Session { arc name: String, copy id: Int }
        \\pub fn f() {
        \\  let owned sess = Session { name: "session", id: 1 }
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "static inline __attribute__((unused)) void cell_drop_Session(cell_Session *r);");
    try expectContains(e.text, "static inline __attribute__((unused)) void cell_drop_Session(cell_Session *r) {\n  cell_arc_drop(r->name);\n}");
    try expectContains(e.text, "cell_drop_Session(&sess);");
}

test "R11 row 2: nested record glue recurses, and releases fields in reverse order" {
    // `tag` is declared after `inner`, so it is released first, matching
    // `pendingDrops`'s reverse-declaration convention for locals. The nested
    // call resolves whatever order the structs were written in, because
    // every prototype precedes every definition.
    var e = try emitSource(
        \\struct Outer { owned inner: Box, arc tag: String }
        \\struct Box { owned s: String, copy n: Int }
        \\pub fn make() -> String;
        \\pub fn f() {
        \\  let owned o = Outer { inner: Box { s: make(), n: 1 }, tag: "t" }
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "void cell_drop_Outer(cell_Outer *r);\nstatic inline __attribute__((unused)) void cell_drop_Box(cell_Box *r);");
    try expectContains(e.text, "  cell_arc_drop(r->tag);\n  cell_drop_Box(&r->inner);\n}");
    try expectContains(e.text, "  cell_string_free(&r->s);\n}");
    try expectContains(e.text, "cell_drop_Outer(&o);");
}

test "R11 row 2: a scalar-only struct gets no glue and no drop" {
    // THE OVER-EMISSION CONTROL. `needsDrop` keys on the fields, not on the
    // shape: a record with nothing to release is not a drop candidate, and
    // emitting glue for it would be an empty function per struct.
    var e = try emitSource(
        \\struct Point { copy x: Int, copy y: Int }
        \\pub fn f() {
        \\  let owned p = Point { x: 1, y: 2 }
        \\}
    );
    defer e.deinit();
    try expectAbsent(e.text, "cell_drop_Point");
}

test "R11 row 2: a struct that is moved, partially moved, or returned is not dropped" {
    // Three shapes `pendingDrops` must skip, each measured under ASan with the
    // malloc counter at the tree that added the glue. A partial move marks
    // the whole binding moved in borrowck, so the record is skipped entirely:
    // that leaks `n`'s nothing and `s`'s nothing here (the field went to
    // `eat`), and would leak a SECOND owning field if there were one, which
    // is the stated residual and the safe direction. A move into an `owned`
    // parameter hands the record to the callee, which releases it (R11 row
    // 1, so `take`'s own body does drop `b`). A returned local is the
    // caller's.
    var e = try emitSource(
        \\struct Box { owned s: String, copy n: Int }
        \\pub fn make() -> String;
        \\pub fn eat(owned s: String) { }
        \\pub fn take(owned b: Box) { }
        \\pub fn partial() {
        \\  let owned b = Box { s: make(), n: 1 }
        \\  eat(owned b.s)
        \\}
        \\pub fn moved() {
        \\  let owned b = Box { s: make(), n: 1 }
        \\  take(b)
        \\}
        \\pub fn returned() -> Box {
        \\  let owned b = Box { s: make(), n: 1 }
        \\  return b
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_eat(b.s);");
    try expectContains(e.text, "cell_take(b);");
    try expectContains(e.text, "return b;");
    try expectAbsent(try fnDef(e.text, "partial"), "cell_drop_Box(&b);");
    try expectAbsent(try fnDef(e.text, "moved"), "cell_drop_Box(&b);");
    try expectAbsent(try fnDef(e.text, "returned"), "cell_drop_Box(&b);");
    try expectOccurrences(try fnDef(e.text, "take"), "cell_drop_Box(&b);", 1);
}

test "R11 row 2: an uninitialized droppable struct var is zero-initialized, then released" {
    // Same rule as the three runtime shapes: the glue over a zeroed record is
    // three no-ops, so the scope-end drop is safe before the first write.
    var e = try emitSource(
        \\struct Box { owned s: String, copy n: Int }
        \\pub fn make() -> String;
        \\pub fn f() {
        \\  var owned b: Box
        \\  b = Box { s: make(), n: 1 }
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_Box b = (cell_Box){0};");
    try expectContains(e.text, "cell_drop_Box(&b);");
}

test "a shared or copy local is never dropped" {
    var e = try emitSource(
        \\pub fn make() -> String;
        \\pub fn f() {
        \\  let shared a = make()
        \\  let copy b = make()
        \\}
    );
    defer e.deinit();
    try expectAbsent(e.text, "cell_string_free");
    try expectAbsent(e.text, "cell_slice_free");
    try expectAbsent(e.text, "cell_arc_drop");
}

test "R11 row 1: an unmoved owned parameter is released by the callee" {
    // runtime/cell_rt.h section 7: the caller relinquishes an `owned`
    // argument, so the callee frees it. Before 2026-09-16 no parameter was
    // ever dropped and every such argument leaked.
    var e = try emitSource(
        \\pub fn f(owned s: String) {
        \\}
    );
    defer e.deinit();
    try expectOccurrences(try fnDef(e.text, "f"), "cell_string_free(&s);", 1);
}

test "R11 row 1: an owned parameter moved onward or returned is not released" {
    // The double-free direction: once the parameter is moved, the new
    // holder frees it, so this frame must not.
    var e = try emitSource(
        \\pub fn sink(owned s: String) -> Int;
        \\pub fn onward(owned s: String) -> Int {
        \\  return sink(owned s)
        \\}
        \\pub fn back(owned s: String) -> String {
        \\  return s
        \\}
        \\pub fn tail(owned s: String) -> String {
        \\  return { s }
        \\}
        \\pub fn rebind(owned s: String) -> String {
        \\  let owned t: String = s
        \\  return t
        \\}
    );
    defer e.deinit();
    for ([_][]const u8{ "onward", "back", "tail", "rebind" }) |name| {
        try expectAbsent(try fnDef(e.text, name), "cell_string_free");
    }
}

test "R11 row 1: shared and copy parameters are still never released" {
    var e = try emitSource(
        \\pub fn f(shared s: String, copy n: Int) -> Int {
        \\  return n
        \\}
    );
    defer e.deinit();
    try expectAbsent(e.text, "cell_string_free");
    try expectAbsent(e.text, "cell_arc_drop");
}

test "a program that allocates and frees an owned local runs clean under cc" {
    // Owned `String` locals cannot appear in this test: constructing one
    // from a string literal hits a pre-existing, unrelated codegen gap
    // (there is no coercion from the literal's `cell_str_t` view into an
    // owned `cell_string_t`; task 4b added exactly that coercion for `arc`,
    // by way of cell_arc_from_string, and deliberately did not touch
    // `owned`), so `cc` would reject the emitted C for a reason that has
    // nothing to do with drops.
    // `[Int]` sidesteps it: every ownership mode of a list lowers to the
    // same `cell_slice_t`, so there is no literal-to-owned coercion to be
    // missing.
    //
    // `kept` is unmoved and must be freed once. `given` is moved into
    // `sink` (an `owned` parameter), so it must NOT be freed here; `sink`
    // frees it (R11 row 1, since 2026-09-16), which makes this program a
    // double-free detector for the parameter release too. What this test
    // actually proves
    // is that the emitted drop compiles and runs without corrupting the
    // heap: a real double free of `kept`'s buffer would either abort
    // (verified directly, by fault injection, on a smaller program in the
    // task report) or corrupt allocator state in a way `cc`'s own leak/
    // sanitizer-free build would not necessarily catch, so the clean exit
    // and the expected `println` output are the actual assertions.
    var e = try emitSource(
        \\pub fn make_list() -> [Int] {
        \\  return [1, 2, 3]
        \\}
        \\pub fn sink(owned xs: [Int]) {
        \\}
        \\pub fn main() {
        \\  let owned kept = make_list()
        \\  let owned given = make_list()
        \\  sink(owned given)
        \\  println("ok")
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_slice_free(&kept);");
    try expectAbsent(e.text, "cell_slice_free(&given)");

    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "body.c", .data = e.text });

    var cwd_buf: [4096]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const include = try std.fmt.allocPrint(gpa, "{s}/runtime", .{cwd_buf[0..cwd_len]});
    defer gpa.free(include);
    const rt_c = try std.fmt.allocPrint(gpa, "{s}/runtime/cell_rt.c", .{cwd_buf[0..cwd_len]});
    defer gpa.free(rt_c);

    const cc_result = try std.process.run(gpa, io, .{
        .argv = &.{ "cc", "-std=c11", "-Wall", "-Wextra", "body.c", rt_c, "-I", include, "-o", "body" },
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
            "emitted program did not exit cleanly (a double free typically aborts):\nstdout:\n{s}\nstderr:\n{s}\n",
            .{ run_result.stdout, run_result.stderr },
        );
        return error.ProgramCrashed;
    }
    try std.testing.expectEqualStrings("ok\n", run_result.stdout);
}

test "an arc program's retains and releases balance when compiled and run" {
    // The assertion that matters most for R11. Emitted-text tests can only
    // show that a clone appears where one was expected; this one links the
    // emitted C against the REAL runtime and reads the strong count back out
    // at run time, so an unbalanced retain shows up as a wrong number rather
    // than as text that happens to look right.
    //
    // The printed 7 decomposes as 2 + 5 and both halves are measurements:
    //
    //   `fresh` boxes a literal (count 1), retains it for the return so the
    //   scope drop cannot free it (1 -> 2 -> 1), and hands back that single
    //   reference. `a` therefore holds count 1.
    //
    //   `observe(arc a)` clones at the call site, so the host sees 2 and
    //   returns 2, then releases its own reference per cell_rt.h section 7,
    //   taking the count back to 1. Drop the return retain in
    //   `emitReturnStmt` and `fresh` frees the box before returning it: the
    //   count read is then garbage and this program tends to abort rather
    //   than print. Drop the call-site clone and the host reads 1, printing
    //   6 instead of 7.
    //
    //   `inspect(shared a)` must NOT clone (R8), and returns the borrowed
    //   view's length, 5. An unwanted retain here would leave the final
    //   cell_arc_drop at count 1 and leak the box, which the number cannot
    //   see; `tools/check.sh`'s note and a run under `leaks` cover that side.
    //
    // The two bodyless declarations are defined by examples/arc_host.c, the
    // same host examples/arc.cell uses, because only a C definition can read
    // cell_arc_strong_count.
    var e = try emitSource(
        \\pub fn print_int(copy value: Int);
        \\pub fn observe(arc name: String) -> Int;
        \\pub fn inspect(shared name: String) -> Int;
        \\pub fn fresh() -> arc String {
        \\  let arc s = "boxed"
        \\  return s
        \\}
        \\pub fn main() {
        \\  let arc a = fresh()
        \\  let copy n = observe(arc a)
        \\  let copy m = inspect(shared a)
        \\  print_int(n + m)
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_arc_clone(s)");
    try expectContains(e.text, "cell_observe(cell_arc_clone(a))");
    try expectContains(e.text, "cell_arc_drop(a);");

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
    const host_c = try std.fmt.allocPrint(gpa, "{s}/examples/arc_host.c", .{root});
    defer gpa.free(host_c);

    const cc_result = try std.process.run(gpa, io, .{
        .argv = &.{ "cc", "-std=c11", "-Wall", "-Wextra", "body.c", host_c, rt_c, "-I", include, "-o", "body" },
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
            "emitted arc program did not exit cleanly (a released-too-early box typically aborts):\nstdout:\n{s}\nstderr:\n{s}\n",
            .{ run_result.stdout, run_result.stderr },
        );
        return error.ProgramCrashed;
    }
    try std.testing.expectEqualStrings("7\n", run_result.stdout);
}
