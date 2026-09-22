//! C backend tests, second quarter in original order: arc retains and
//! releases, shadowing, hoists, and block-scoped releases.

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

test "an arc place passed to an arc parameter is cloned at the call site" {
    var e = try emitSource(
        \\pub fn observe(arc name: String) -> Int;
        \\pub fn f(arc n: String) -> Int {
        \\  return observe(arc n)
        \\}
    );
    defer e.deinit();
    // Written with the `arc n` prefix on purpose: that reaches codegen as an
    // `.annotated` wrapper, and a retain rule that failed to see through it
    // would silently skip the clone at exactly the spelling examples/arc.cell
    // uses. R11 rule 2. The parameter's own reference is released after
    // the call (R11 row 1), so the clone is what keeps the callee's alive.
    const f = try fnDef(e.text, "f");
    try expectContains(f, "cell_observe(cell_arc_clone(n));");
    try expectBefore(f, "cell_observe(cell_arc_clone(n));", "cell_arc_drop(n);");
    try expectOccurrences(f, "cell_arc_drop(n);", 1);
}

test "an arc place passed to a shared parameter is NOT cloned" {
    var e = try emitSource(
        \\pub fn inspect(shared name: String) -> Int;
        \\pub fn f(arc n: String) -> Int {
        \\  return inspect(shared n)
        \\}
    );
    defer e.deinit();
    // R11's one deliberate non-retain. The borrow cannot escape the call
    // (R8), so the caller's own reference already covers it. This assertion
    // is the one that catches over-retaining, which the safety asymmetry
    // otherwise encourages, so the absence is asserted explicitly.
    try expectAbsent(e.text, "cell_arc_clone");
    const call = "cell_inspect(cell_string_as_str((const cell_string_t *)n.ptr));";
    try expectContains(e.text, call);
    // The parameter's own release comes after the borrow ends.
    try expectBefore(e.text, call, "cell_arc_drop(n);");
}

test "an arc place bound to a new arc binding is cloned, not re-boxed" {
    var e = try emitSource(
        \\pub fn f(arc p: String) {
        \\  let arc s = p
        \\}
    );
    defer e.deinit();
    // R11 rule 3: both p and s are live afterward, so s needs its own
    // reference. Re-boxing would build a second box over the same pointee and
    // free it twice.
    try expectContains(e.text, "cell_arc_t s = cell_arc_clone(p);");
    try expectAbsent(e.text, "cell_arc_from_string");
}

test "an arc place stored in a struct field is cloned" {
    var e = try emitSource(
        \\pub struct Session {
        \\  arc name: String
        \\}
        \\pub fn f(arc n: String) {
        \\  let owned s = Session { name: n }
        \\}
    );
    defer e.deinit();
    // R11 rule 4. The struct's own reference is released by its generated
    // glue at scope end since 2026-09-15 (row 2), so this retain is balanced
    // by `cell_drop_Session`; the retain itself is what this test pins.
    try expectContains(e.text, "(cell_Session){ .name = cell_arc_clone(n) }");
}

test "a call that returns arc is bound without a second retain" {
    var e = try emitSource(
        \\pub fn fresh() -> arc String;
        \\pub fn f() {
        \\  let arc b = fresh()
        \\}
    );
    defer e.deinit();
    // A returned arc arrives ALREADY retained (R11 release rule 3, and
    // cell_rt.h section 7), so cloning it here would leak one reference. The
    // retain is gated on the argument being a place for exactly this reason.
    try expectContains(e.text, "cell_arc_t b = cell_fresh();");
    try expectAbsent(e.text, "cell_arc_clone");
}

test "a returned arc local is retained before the drop that would free it" {
    var e = try emitSource(
        \\pub fn f() -> arc String {
        \\  let arc s = "x"
        \\  return s
        \\}
    );
    defer e.deinit();
    // Borrowck never makes an arc place dead (isDuplicable, R10 by design),
    // so a returned arc local is always still in pendingDrops and the drop
    // runs between the return temporary's initialization and the return
    // itself. Without the clone the count reaches zero and the caller
    // receives a freed box: exactly the use-after-free direction the
    // ownership rules forbid. R11 release rule 2's "except the one being
    // returned", paid for on the retain side because the drop pass is not
    // this task's to change.
    try expectContains(e.text,
        \\  cell_arc_t _cell_t0 = cell_arc_clone(s);
        \\  cell_arc_drop(s);
        \\  return _cell_t0;
    );
}

test "a value returned where the declared return type is arc IS boxed" {
    var e = try emitSource(
        \\pub fn make() -> String;
        \\pub fn lit() -> arc String {
        \\  return "x"
        \\}
        \\pub fn from_call() -> arc String {
        \\  return make()
        \\}
        \\pub fn from_list() -> arc [Int] {
        \\  return [1, 2, 3]
        \\}
    );
    defer e.deinit();
    // A `return` lowers a value into the function's DECLARED return type, so
    // it owes R11 rule 1 exactly as a `let`, a call argument, a struct field
    // and a list element do. It was the one such position that never asked,
    // and `emitArcConversion`'s doc comment asserted there was no second
    // position to keep in step. All three of these passed `cell check` and
    // were caught only by `cc`.
    //
    // Three forms, all run: a literal, a call result, and a list literal.
    // Each is boxed rather than cloned because the box does not exist yet.
    try expectContains(e.text, "return cell_arc_from_string(cell_string_from_str(cell_str_from_parts(\"x\", 1)));");
    try expectContains(e.text, "return cell_arc_from_string(cell_make());");
    try expectContains(e.text, "return cell_arc_from_slice(({");
}

test "an arc place returned where a non-arc type is declared stays a loud C type error" {
    var e = try emitSource(
        \\pub fn f(arc xs: [Int]) -> [Int] {
        \\  return xs
        \\}
        \\pub fn g(arc s: String) -> String {
        \\  return s
        \\}
    );
    defer e.deinit();
    // The direction that must NOT be routed through the conversion, and the
    // test that stops someone completing the symmetry. `unboxable` is TRUE
    // for `cell_slice_t`, so routing the unbox here would make `f` COMPILE,
    // emitting `(*(const cell_slice_t *)xs.ptr)`. docs/OWNERSHIP.md R10
    // documents that exact emission and why it is a double free: `owned [T]`
    // and `shared [T]` are the same C type, the callee frees the buffer, and
    // the box's drop glue frees the same buffer again. A refcount does not
    // govern the buffer, so no retain fixes it.
    //
    // borrowck refuses both returns as R10 make-unique positions today,
    // and this C type error is the second, independent refusal behind it.
    // Keeping it loud is the whole point. Since R11 row 1 the parameter is
    // released, so the return goes through a retained temporary, and the
    // temporary's C type is still the declared non-`arc` one.
    try expectContains(e.text, "cell_slice_t _cell_t0 = cell_arc_clone(xs);");
    try expectContains(e.text, "cell_string_t _cell_t1 = cell_arc_clone(s);");
    try expectAbsent(e.text, "unbox");
}

test "an owned String or list binding assigned to an arc var is moved into the box" {
    // R10's move-into-arc at assignment, implemented 2026-09-16. The
    // reassignment pre-drop releases the old box, then stores the new one,
    // which boxes the moved source; the source has no release of its own.
    var e = try emitSource(
        \\pub fn f(owned p: String) {
        \\  var arc a: String = "x"
        \\  a = p
        \\}
        \\pub fn g(owned xs: [Int]) {
        \\  var arc b: [Int] = [1]
        \\  b = xs
        \\}
    );
    defer e.deinit();
    const f = try fnDef(e.text, "f");
    try expectContains(f, "cell_arc_t _cell_t0 = cell_arc_from_string(p);");
    try expectLineBefore(f, "cell_arc_drop(a);", "cell_arc_t _cell_t0 = cell_arc_from_string(p);");
    try expectLineBefore(f, "a = _cell_t0;", "cell_arc_drop(a);");
    try expectAbsent(f, "cell_string_free(&p);");
    const g = try fnDef(e.text, "g");
    try expectContains(g, "cell_arc_from_slice(xs);");
    try expectAbsent(g, "cell_slice_free(&xs);");
    try expectCompiles(e.text);
}

test "an owned String or list binding returned as arc is moved into the box" {
    // R10's move-into-arc at `return`, implemented 2026-09-16 after `let`.
    // Until then this test pinned `cell_arc_t _cell_t0 = p;`, a loud C type
    // error, because borrowck refused the program and the drop pass still
    // spelled a release for `p`. borrowck now accepts a whole `owned`
    // `String` or list binding returned directly and moves it (the ordinary
    // R2 return move), so `emitArcConversion`'s `isMovedOwnedBinding` boxes
    // exactly that place, nothing frees it, and the caller owns the box. No
    // retain: `returnedArcNeedsRetain` asks about an `arc`-typed place, and
    // `p` is a `String`.
    var e = try emitSource(
        \\pub fn make() -> String;
        \\pub fn f() -> arc String {
        \\  let owned p = make()
        \\  return p
        \\}
        \\pub fn g(owned xs: [Int]) -> arc [Int] {
        \\  return xs
        \\}
    );
    defer e.deinit();
    const f = try fnDef(e.text, "f");
    try expectContains(f, "return cell_arc_from_string(p);");
    try expectAbsent(f, "cell_string_free(&p);");
    try expectAbsent(f, "cell_arc_clone");
    const g = try fnDef(e.text, "g");
    try expectContains(g, "return cell_arc_from_slice(xs);");
    try expectAbsent(g, "cell_slice_free(&xs);");
    try expectCompiles(e.text);
}

test "a returned arc parameter is retained once and released once" {
    var e = try emitSource(
        \\pub fn share(arc n: String) -> arc String {
        \\  return n
        \\}
    );
    defer e.deinit();
    // R11 rule 3 with row 1 closed: the parameter is released at scope
    // end like any `arc` local, so the returned reference is a fresh
    // retain taken before that release. 1 -> 2 -> 1, and the caller owns
    // the one left.
    const f = try fnDef(e.text, "share");
    try expectContains(f, "cell_arc_t _cell_t0 = cell_arc_clone(n);");
    try expectBefore(f, "cell_arc_clone(n);", "cell_arc_drop(n);");
    try expectOccurrences(f, "cell_arc_clone", 1);
    try expectOccurrences(f, "cell_arc_drop", 1);
    try expectContains(f, "return _cell_t0;");
}

test "a returned arc match-arm binding is retained: return inside a BLOCK arm body" {
    var e = try emitSource(
        \\pub fn f() -> arc String {
        \\  let arc s = "aaa"
        \\  match s { b => { return b } }
        \\  return s
        \\}
    );
    defer e.deinit();
    // THE REGRESSION TEST. `Local.is_param` was once removed after a derivation
    // concluded that a match-arm binding could not reach
    // `returnedArcNeedsRetain`. That derivation checked `b => return b`
    // (rejected: `return` is not an expression) and a trailing `match`
    // (rejected: not a return), and missed this third form: an arm body may
    // be a BLOCK, and a block's contents are statements. `cell check` exits 0
    // here, the emitted C compiled at -Werror, and the binding was returned
    // without a retain while `cell_arc_drop(s)` freed the box.
    // AddressSanitizer: heap-use-after-free, exit 134.
    try expectContains(e.text,
        \\    cell_arc_t _cell_t1 = cell_arc_clone(b);
        \\    cell_arc_drop(s);
        \\    return _cell_t1;
    );
}

test "a returned arc match-arm binding is retained: nested if inside a block arm body" {
    var e = try emitSource(
        \\pub fn f(shared c: Int) -> arc String {
        \\  let arc s = "aaa"
        \\  match s {
        \\    b => { if (c > 0) { return b } else { return b } }
        \\  }
        \\  return s
        \\}
    );
    defer e.deinit();
    // The second reachable form of the same escape. Both branches of the
    // nested `if` are returns of the arm binding, and both were bare.
    try expectContains(e.text,
        \\      cell_arc_t _cell_t1 = cell_arc_clone(b);
        \\      cell_arc_drop(s);
        \\      return _cell_t1;
    );
    try expectContains(e.text,
        \\      cell_arc_t _cell_t2 = cell_arc_clone(b);
        \\      cell_arc_drop(s);
        \\      return _cell_t2;
    );
}

test "an owned String or list binding stored in a struct-literal arc field is moved into the box" {
    // R10's move-into-arc at a struct-literal field, implemented
    // 2026-09-16. The literal takes the fresh box and the record's drop
    // glue releases it (R11 row 2); the source has no drop of its own
    // because borrowck moved it.
    var e = try emitSource(
        \\pub struct Box {
        \\  arc s: String
        \\  arc xs: [Int]
        \\}
        \\pub fn make() -> String;
        \\pub fn f(owned ys: [Int]) {
        \\  let owned a = make()
        \\  let owned b = Box { s: a, xs: ys }
        \\}
    );
    defer e.deinit();
    const f = try fnDef(e.text, "f");
    try expectContains(f, ".s = cell_arc_from_string(a)");
    try expectContains(f, ".xs = cell_arc_from_slice(ys)");
    try expectAbsent(f, "cell_string_free(&a);");
    try expectAbsent(f, "cell_slice_free(&ys);");
    try expectContains(f, "cell_drop_Box(");
    try expectCompiles(e.text);
}

test "an owned String or list binding passed to an arc parameter is moved into the box" {
    // R10's move-into-arc at a call argument, implemented 2026-09-16. The
    // box is handed to the callee at count 1 and the callee releases it
    // (R11 row 1), exactly as a boxed literal argument is; the source has
    // no drop of its own because borrowck moved it.
    var e = try emitSource(
        \\pub fn keep(arc s: String);
        \\pub fn keep_list(arc xs: [Int]);
        \\pub fn make() -> String;
        \\pub fn f() {
        \\  let owned a = make()
        \\  keep(a)
        \\}
        \\pub fn g(owned xs: [Int]) {
        \\  keep_list(xs)
        \\}
    );
    defer e.deinit();
    const f = try fnDef(e.text, "f");
    try expectContains(f, "cell_keep(cell_arc_from_string(a));");
    try expectAbsent(f, "cell_string_free(&a);");
    try expectAbsent(f, "cell_arc_drop");
    const g = try fnDef(e.text, "g");
    try expectContains(g, "cell_keep_list(cell_arc_from_slice(xs));");
    try expectAbsent(g, "cell_slice_free(&xs);");
    try expectCompiles(e.text);
}

test "an owned String or list binding bound as arc is moved into the box" {
    // R10's move-into-arc at `let`, implemented 2026-09-16. Until then this
    // test pinned the opposite: `cell_arc_t b = a;`, a loud C type error,
    // because borrowck did not consume `a` and boxing it would have freed the
    // buffer twice. borrowck now moves `a` (`boxableOwnedBinding`), so the
    // box takes the header and `a` has no drop of its own.
    var e = try emitSource(
        \\pub fn make() -> String;
        \\pub fn list() -> [Int];
        \\pub fn f() {
        \\  let owned a = make()
        \\  let arc b = a
        \\}
        \\pub fn g(owned xs: [Int]) {
        \\  let arc b = xs
        \\}
    );
    defer e.deinit();
    const f = try fnDef(e.text, "f");
    try expectContains(f, "cell_arc_t b = cell_arc_from_string(a);");
    try expectAbsent(f, "cell_string_free(&a);");
    try expectOccurrences(f, "cell_arc_drop(b);", 1);
    const g = try fnDef(e.text, "g");
    try expectContains(g, "cell_arc_t b = cell_arc_from_slice(xs);");
    try expectAbsent(g, "cell_slice_free(&xs);");
    try expectCompiles(e.text);
}

test "a returned arc FIELD is retained when the function drops nothing" {
    var e = try emitSource(
        \\pub struct Session {
        \\  arc name: String
        \\  copy id: Int
        \\}
        \\pub fn peek(shared s: Session) -> arc String {
        \\  return s.name
        \\}
    );
    defer e.deinit();
    // The `pendingDrops` empty branch of `emitReturnStmt`, which used not to
    // consult the retain rule at all. R11 release rule 3 is categorical: a
    // returned `arc` is returned ALREADY RETAINED. Without the clone this
    // hands the caller the record's own reference, the caller releases it,
    // and the record is left pointing at a freed box: reproduced under
    // AddressSanitizer as a heap-use-after-free in `cell_arc_drop`.
    try expectContains(e.text, "  return cell_arc_clone(s->name);");
}

test "a returned arc FIELD is retained when the function also drops a local" {
    var e = try emitSource(
        \\pub struct Session {
        \\  arc name: String
        \\  copy id: Int
        \\}
        \\pub fn peek(shared s: Session) -> arc String {
        \\  let arc extra = "x"
        \\  return s.name
        \\}
    );
    defer e.deinit();
    // The other branch. Both are asserted because the first version of this
    // rule declined a `.field` root inside `returnedArcNeedsRetain` itself,
    // so BOTH branches emitted the bare field and only one of them was even
    // reached by the earlier tests.
    try expectContains(e.text,
        \\  cell_arc_t _cell_t0 = cell_arc_clone(s->name);
        \\  cell_arc_drop(extra);
        \\  return _cell_t0;
    );
}

test "a shadowed arc local is dropped once, naming the inner binding" {
    var e = try emitSource(
        \\pub fn shadowed(shared k: Int) -> Int {
        \\  let arc s = "outer"
        \\  if (k > 0) {
        \\    let arc s = "inner"
        \\    return 1
        \\  }
        \\  return 2
        \\}
    );
    defer e.deinit();
    // `emitDropFor` spells a drop by NAME, so two visible bindings sharing
    // one name emitted two identical `cell_arc_drop(s)` calls, both
    // resolving to the INNER `s`: a double free of the inner box and a leak
    // of the outer one. Measured under AddressSanitizer before the fix.
    // Suppressing the unnameable outer drop leaks it instead, which is the
    // correct side of this backend's asymmetry. Note `cell check` only WARNS
    // about shadowing, so nothing upstream prevents this source.
    try expectContains(e.text,
        \\    int64_t _cell_t0 = 1;
        \\    cell_arc_drop(s);
        \\    return _cell_t0;
    );
    try expectAbsent(e.text,
        \\    cell_arc_drop(s);
        \\    cell_arc_drop(s);
    );
}

test "an arc place flowing out of an if-expression branch is cloned" {
    var e = try emitSource(
        \\pub fn f(shared c: Int) {
        \\  let arc a = "aaa"
        \\  let arc b = "bbb"
        \\  let arc r = if (c > 0) { a } else { b }
        \\}
    );
    defer e.deinit();
    // A VALUE position, not a place position. The retain rules were derived
    // by searching return-position places, and this escaped all of them: the
    // branch assigned into the statement expression's temporary with a bare
    // `emitExpr`, so `r` aliased `a`'s box and scope exit released both.
    // Reproduced as a heap-use-after-free in `cell_arc_drop`, exit 134,
    // while `cell check` exited 0 and `cc -Wall -Wextra -Werror` was silent.
    try expectContains(e.text, "_cell_t0 = cell_arc_clone(a);");
    try expectContains(e.text, "_cell_t0 = cell_arc_clone(b);");
}

test "an arc place flowing out of a match arm in return position is cloned" {
    var e = try emitSource(
        \\pub fn pick(shared c: Int) -> arc String {
        \\  let arc a = "aaa"
        \\  return match c {
        \\    0 => a,
        \\    _ => a
        \\  }
        \\}
    );
    defer e.deinit();
    // The same leak of the same abstraction, one step further in: a `match`
    // IS valued in return position (an `if` there is rejected by typecheck),
    // but it is not a PLACE, so `returnedArcNeedsRetain` never fired and
    // `cell_arc_drop(a)` ran before the `return`. The retain belongs in the
    // arm, not at the return, because that is where the aliasing happens.
    try expectContains(e.text, "_cell_t1 = cell_arc_clone(a);");
    try expectContains(e.text,
        \\  cell_arc_drop(a);
        \\  return _cell_t0;
    );
}

test "an unbound arc call result is hoisted out of the call and released after it" {
    var e = try emitSource(
        \\pub fn inspect(shared name: String) -> Int;
        \\pub fn fresh() -> arc String {
        \\  let arc s = "x"
        \\  return s
        \\}
        \\pub fn f() -> Int {
        \\  return inspect(shared fresh())
        \\}
    );
    defer e.deinit();
    // R11's largest disclosed gap, measured at 2998 leaks / 63968 bytes over
    // 1000 iterations. `fresh` hands back a reference this frame owns, the
    // handle was never bound, and the emitted C read `.ptr` off the call's
    // return value and let the handle go.
    //
    // The whole statement expression is asserted, not just the drop, because
    // ORDER is what makes this safe rather than a use-after-free: the
    // unboxed `cell_str_t` points into the box's payload, so the drop must
    // come after `cell_inspect` returns. A drop emitted inside the argument
    // instead would free the characters the callee is reading.
    try expectContains(e.text,
        \\  return ({
        \\    cell_arc_t _cell_t1 = cell_fresh();
        \\    int64_t _cell_t2 = cell_inspect(cell_string_as_str((const cell_string_t *)_cell_t1.ptr));
        \\    cell_arc_drop(_cell_t1);
        \\    _cell_t2;
        \\  });
    );
}

test "two unbound arc call results in one call are both released, in reverse order" {
    var e = try emitSource(
        \\pub fn note(shared a: String, shared b: String);
        \\pub fn fresh() -> arc String {
        \\  let arc s = "x"
        \\  return s
        \\}
        \\pub fn f() {
        \\  note(shared fresh(), shared fresh())
        \\}
    );
    defer e.deinit();
    // Two things one argument cannot show. Both handles are hoisted rather
    // than only the first, and a VOID callee gets no result slot, so the
    // statement expression's value is the last drop's, which is also void.
    // `cc -Wall -Wextra -Werror` accepts that; a stray result temporary of
    // type `void` would not compile at all.
    try expectContains(e.text,
        \\    cell_arc_t _cell_t1 = cell_fresh();
        \\    cell_arc_t _cell_t2 = cell_fresh();
        \\    cell_note(cell_string_as_str((const cell_string_t *)_cell_t1.ptr), cell_string_as_str((const cell_string_t *)_cell_t2.ptr));
        \\    cell_arc_drop(_cell_t2);
        \\    cell_arc_drop(_cell_t1);
    );
}

test "a hoisted call whose value is DISCARDED emits no result slot" {
    var e = try emitSource(
        \\pub fn inspect(shared name: String) -> Int;
        \\pub fn fresh() -> arc String {
        \\  let arc s = "x"
        \\  return s
        \\}
        \\pub fn bare() {
        \\  inspect(shared fresh())
        \\}
    );
    defer e.deinit();
    // A regression the hoist itself introduced, caught by compiling a form
    // the corpus does not contain rather than by any gate. `-Wunused-value`
    // is part of `-Wall` and fires on a statement expression's trailing
    // result when the statement expression's own value is discarded, so
    // `int64_t _t = cell_inspect(...); ... _t;` made source that compiled
    // before the hoist stop compiling at `-Wall -Wextra -Werror`.
    //
    // With the value discarded there is nothing to carry across the drops,
    // so the result slot is omitted and this ends on a void `cell_arc_drop`
    // exactly as the void-callee case already did. The release is unchanged,
    // which is the part that must not regress.
    try expectContains(e.text,
        \\void cell_bare(void) {
        \\  ({
        \\    cell_arc_t _cell_t1 = cell_fresh();
        \\    cell_inspect(cell_string_as_str((const cell_string_t *)_cell_t1.ptr));
        \\    cell_arc_drop(_cell_t1);
        \\  });
        \\}
    );
}

test "a hoist nested inside another hoist composes, inner released first" {
    var e = try emitSource(
        \\pub fn inspect(shared name: String) -> Int;
        \\pub fn wrap(shared s: String) -> arc String {
        \\  let arc b = s
        \\  return b
        \\}
        \\pub fn fresh() -> arc String {
        \\  let arc s = "x"
        \\  return s
        \\}
        \\pub fn f() -> Int {
        \\  return inspect(shared wrap(shared fresh()))
        \\}
    );
    defer e.deinit();
    // The other form the corpus does not contain: a hoisted argument whose
    // own expression needs a hoist. It falls out of the recursion rather
    // than being handled, and the nesting is what pins that the inner
    // handle is released inside the initializer of the outer one, before
    // the outer call runs, and that each release names its own temporary.
    try expectContains(e.text,
        \\  return ({
        \\    cell_arc_t _cell_t2 = ({
        \\      cell_arc_t _cell_t3 = cell_fresh();
        \\      cell_arc_t _cell_t4 = cell_wrap(cell_string_as_str((const cell_string_t *)_cell_t3.ptr));
        \\      cell_arc_drop(_cell_t3);
        \\      _cell_t4;
        \\    });
        \\    int64_t _cell_t5 = cell_inspect(cell_string_as_str((const cell_string_t *)_cell_t2.ptr));
        \\    cell_arc_drop(_cell_t2);
        \\    _cell_t5;
        \\  });
    );
}

test "an arc call result unboxed OUTSIDE a call argument is NOT hoisted or released" {
    var e = try emitSource(
        \\pub fn fresh() -> arc String {
        \\  let arc s = "x"
        \\  return s
        \\}
        \\pub fn f() {
        \\  let shared v: String = fresh()
        \\}
    );
    defer e.deinit();
    // The boundary of the fix above, and the test that catches the next
    // person moving the hoist down into `emitArgLike` where every unbox
    // would reach it. `v` is a view INTO the box's payload and it outlives
    // the statement that produced it, so a `cell_arc_drop` here would leave
    // `v` dangling for the rest of the scope. This form still leaks the box,
    // deliberately: a leak is the safe side of this backend's asymmetry and
    // a use-after-free is not.
    //
    // The WHOLE function is spelled out rather than just the unbox, because
    // the absence is the claim and a `cell_arc_drop` could otherwise sit on
    // any line this assertion does not name. A bare
    // `expectAbsent("cell_arc_drop")` cannot say it: `fresh`'s own body is
    // in the same emitted module and legitimately contains one.
    try expectContains(e.text,
        \\void cell_f(void) {
        \\  cell_str_t v = cell_string_as_str((const cell_string_t *)cell_fresh().ptr);
        \\  (void)v;
        \\}
    );
    try expectAbsent(e.text, "cell_arc_drop(_cell_t");
}

test "an arc call result passed to an arc parameter is transferred, not hoisted" {
    var e = try emitSource(
        \\pub fn observe(arc name: String) -> Int;
        \\pub fn fresh() -> arc String {
        \\  let arc s = "x"
        \\  return s
        \\}
        \\pub fn f() -> Int {
        \\  return observe(arc fresh())
        \\}
    );
    defer e.deinit();
    // The adjacent path the hoist must not touch. Here the reference is
    // HANDED to the callee, which releases it per cell_rt.h section 7, so
    // hoisting and dropping it in this frame would be a double free. The
    // absence is what pins that, and the whole function is spelled out to
    // say it: a bare `expectAbsent("cell_arc_drop")` would fail on `fresh`'s
    // own legitimate drop in the same emitted module.
    try expectContains(e.text,
        \\int64_t cell_f(void) {
        \\  return cell_observe(cell_fresh());
        \\}
    );
    try expectAbsent(e.text, "cell_arc_drop(_cell_t");
}

test "no drop is emitted after a body-terminating return" {
    var e = try emitSource(
        \\pub fn f() -> arc String {
        \\  let arc s = "x"
        \\  return s
        \\}
    );
    defer e.deinit();
    // `emitReturnStmt` already emits every drop that `return` owes, and
    // `emitFn` then ran `emitScopeDrops` again at the end of the body, so a
    // second identical `cell_arc_drop(s);` sat after the `return` where no
    // execution reaches it. Harmless under `-Wall -Wextra` (clang does not
    // put `-Wunreachable-code` in either), but it is emitted dead code.
    //
    // The positive half is what keeps this honest: an `expectAbsent` alone
    // would pass just as well if the drop pass stopped firing altogether.
    try expectContains(e.text,
        \\  cell_arc_drop(s);
        \\  return _cell_t0;
        \\}
    );
    try expectAbsent(e.text,
        \\  return _cell_t0;
        \\  cell_arc_drop(s);
    );
}

test "a list literal uses the DECLARED element type, making a mismatch loud" {
    var e = try emitSource(
        \\pub fn takes(shared zs: [String]) -> Int;
        \\pub fn build() -> Int {
        \\  let arc a = "hello"
        \\  let owned zs: [String] = [a, a]
        \\  return takes(shared zs)
        \\}
    );
    defer e.deinit();
    // `cell_slice_t` is type-erased, so a list literal is the one expression
    // whose element C type cannot be recovered from the expression itself,
    // and getting it wrong is SILENT. This program built a buffer of
    // `cell_arc_t` against a declared `[String]`, passed `cell check`,
    // compiled at `-Wall -Wextra -Werror`, and stayed clean under
    // AddressSanitizer, because reinterpreting a refcount box pointer as a
    // string is type confusion rather than a memory error. Both types happen
    // to be 24 bytes here, so even the stride matched and only the fields
    // lied: a `shared [String]` callee read `len = 105690555222384`.
    //
    // The fix does not make this program work, it makes it FAIL LOUDLY. An
    // element of an `owned [String]` is a make-unique position, R10 refuses
    // four such positions, and this is a fifth one R10 does not reach; the C
    // type error is what refuses it. Both halves are asserted, because the
    // stride alone would pass with the elements still assigned unconverted.
    try expectContains(e.text, "cell_slice_alloc(sizeof(cell_string_t), 2)");
    try expectContains(e.text, "cell_string_t _cell_t1 = (cell_string_t){0};");
    try expectAbsent(e.text, "sizeof(cell_arc_t)");
    // The retain is gone with the conversion: `emitArgLike` now declines
    // arc-to-owned-String instead of cloning into a mistyped slot, which is
    // also the two-references-per-list leak that rode on top of the
    // confusion.
    try expectAbsent(e.text, "cell_arc_clone");
}

test "a list literal reached through a match arm also uses the declared element type" {
    var e = try emitSource(
        \\pub fn takes(shared zs: [String]) -> Int;
        \\pub fn f(copy c: Int) -> Int {
        \\  let arc a = "hello"
        \\  let owned zs: [String] = match c {
        \\    0 => [a],
        \\    _ => [a]
        \\  }
        \\  return takes(shared zs)
        \\}
    );
    defer e.deinit();
    // The form that made the first fix incomplete, and it is reachable
    // rather than hypothetical: this passes `cell check` today. The literal
    // arrives through a value-position `match`, so it reaches
    // `emitValueInto`'s leaf rather than `emitArgLike`'s, and with only the
    // argument-position fix it inferred `cell_arc_t` all over again and
    // compiled clean. Same axis as every other finding in this file: one
    // form of a construct was handled and a second was not.
    try expectContains(e.text, "cell_slice_alloc(sizeof(cell_string_t), 1)");
    try expectAbsent(e.text, "sizeof(cell_arc_t)");
}

test "a list literal with no declared type still infers its element type" {
    var e = try emitSource(
        \\pub fn takes(shared zs: [Int]) -> Int;
        \\pub fn f() -> Int {
        \\  let owned ys = [4, 5]
        \\  return takes(shared ys)
        \\}
    );
    defer e.deinit();
    // The other side of the same change, and the one that would catch a fix
    // that simply required an annotation. Nothing declares an element type
    // here, so inference from the first item is still the answer and the
    // emitted C is unchanged.
    try expectContains(e.text, "cell_slice_alloc(sizeof(int64_t), 2)");
}

test "a declared element type survives shared and exclusive ownership" {
    var e = try emitSource(
        \\pub fn takes(shared zs: [String]) -> Int;
        \\pub fn f() -> Int {
        \\  let shared zs: [String] = ["a"]
        \\  return takes(shared zs)
        \\}
    );
    defer e.deinit();
    // `applyOwnership` and `pointerTo` build NEW CTypes, and both had to be
    // taught to carry `elem` across. If either drops it, the declared
    // element vanishes for every borrowed list and this silently reverts to
    // inference, which is how the defect looked in the first place.
    try expectContains(e.text, "cell_slice_alloc(sizeof(cell_string_t), 1)");
    try expectAbsent(e.text, "sizeof(cell_str_t)");
}

test "an owned String call result bound as arc IS boxed" {
    var e = try emitSource(
        \\pub fn make() -> String;
        \\pub fn f() {
        \\  let arc b = make()
        \\}
    );
    defer e.deinit();
    // The complement of the test above: a call result is not a local the drop
    // pass will also free, so moving it into the box is safe and correct.
    try expectContains(e.text, "cell_arc_t b = cell_arc_from_string(cell_make());");
}

test "an unmoved owned [Byte] local gets cell_slice_free" {
    var e = try emitSource(
        \\pub fn f() {
        \\  let owned xs = [1, 2]
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_slice_free(&xs);");
}

test "drops happen before an early return, not only at the end of the body" {
    var e = try emitSource(
        \\pub fn make() -> String;
        \\pub fn f(shared c: Bool) -> Int {
        \\  let owned s = make()
        \\  if (c) {
        \\    return 1
        \\  }
        \\  return 2
        \\}
    );
    defer e.deinit();
    // The early return, nested inside the `if`, one indent level deeper.
    try expectContains(e.text,
        \\    cell_string_free(&s);
        \\    return _cell_t0;
    );
    // The end-of-body return, back at the function's own indent level. A
    // plain literal return still needs the return-value temporary: the
    // drop has to run between computing the value and returning it (see
    // `emitReturnStmt`), and that ordering does not depend on whether this
    // particular return expression happens to read `s`.
    try expectContains(e.text,
        \\  cell_string_free(&s);
        \\  return _cell_t1;
    );
}

test "drops run in reverse declaration order" {
    var e = try emitSource(
        \\pub fn make() -> String;
        \\pub fn f() {
        \\  let owned a = make()
        \\  let owned b = make()
        \\  let owned c = make()
        \\}
    );
    defer e.deinit();
    try expectContains(e.text,
        \\  cell_string_free(&c);
        \\  cell_string_free(&b);
        \\  cell_string_free(&a);
    );
}

// ── block-scoped release, OWNERSHIP.md R11 row 4 (closed 2026-09-15) ────

test "an arc local declared in a while body is released at the end of every iteration" {
    // The exact shape of examples/leaks/block_scoped_local.cell, which
    // measured 3000 leaks over 1000 iterations before this drop existed.
    var e = try emitSource(
        \\pub fn f() {
        \\  var i = 0
        \\  while i < 1000 {
        \\    let arc a = "leaked-block-local"
        \\    i = i + 1
        \\  }
        \\}
    );
    defer e.deinit();
    // Once, inside the loop, after the body's last statement.
    try expectOccurrences(e.text, "cell_arc_drop(a);", 1);
    try expectContains(e.text,
        \\          i = (i + 1);
        \\          cell_arc_drop(a);
        \\  }
    );
}

test "an owned local declared in a bare block is freed at that block's closing brace" {
    var e = try emitSource(
        \\pub fn make() -> String;
        \\pub fn f() {
        \\  {
        \\    let owned s = make()
        \\  }
        \\}
    );
    defer e.deinit();
    try expectOccurrences(e.text, "cell_string_free(&s);", 1);
    try expectContains(e.text,
        \\    cell_string_free(&s);
        \\  }
        \\}
    );
}

test "a break drops the loop body's locals before jumping, and the normal exit drops them too" {
    var e = try emitSource(
        \\pub fn make() -> String;
        \\pub fn f(shared k: Int) {
        \\  var i = 0
        \\  while i < 10 {
        \\    let owned s = make()
        \\    if (i == k) {
        \\      break
        \\    }
        \\    i = i + 1
        \\  }
        \\}
    );
    defer e.deinit();
    // The `break` sits inside an `if` branch inside the body: it must drop
    // since the LOOP's mark, not the branch's, so `s` is released there.
    try expectLineBefore(e.text, "break;", "cell_string_free(&s);");
    // And the `if` branch itself ends in a jump, so it emits no second drop.
    try expectOccurrences(e.text, "cell_string_free(&s);", 2);
}

test "a continue drops the loop body's locals before jumping" {
    var e = try emitSource(
        \\pub fn make() -> String;
        \\pub fn f(shared k: Int) {
        \\  var i = 0
        \\  while i < 10 {
        \\    i = i + 1
        \\    let owned s = make()
        \\    if (i == k) {
        \\      continue
        \\    }
        \\  }
        \\}
    );
    defer e.deinit();
    try expectLineBefore(e.text, "continue;", "cell_string_free(&s);");
    try expectOccurrences(e.text, "cell_string_free(&s);", 2);
}

test "a loop-body local moved into an owned parameter is not dropped at the body's end" {
    var e = try emitSource(
        \\pub fn make() -> String;
        \\pub fn take(owned s: String);
        \\pub fn f() {
        \\  var i = 0
        \\  while i < 10 {
        \\    let owned s = make()
        \\    take(s)
        \\    i = i + 1
        \\  }
        \\}
    );
    defer e.deinit();
    try expectAbsent(e.text, "cell_string_free(&s)");
}

test "an arc local declared in a statement-position match arm body is released at the arm's end" {
    // OWNERSHIP.md row 4 named the match-arm form beside the block form.
    var e = try emitSource(
        \\pub fn f(shared k: Int) {
        \\  match k {
        \\    1 => {
        \\      let arc a = "arm-local"
        \\    },
        \\    _ => 0,
        \\  }
        \\}
    );
    defer e.deinit();
    try expectOccurrences(e.text, "cell_arc_drop(a);", 1);
}

test "an arc local that is a VALUE-position block's tail is released after the clone" {
    // CLOSED 2026-09-15 (evening): `emitValueBlockDrops`. The destination is
    // `arc`, so the tail was lowered as `cell_arc_clone(a)`, and `a`'s own
    // reference is dropped after it: 1 -> 2 -> 1, and `r`'s release frees
    // the box. examples/leaks/value_block_local.cell measures this at 0 on
    // both witnesses; it read 3000 before.
    var e = try emitSource(
        \\pub fn f() {
        \\  let arc r = {
        \\    let arc a = "inner"
        \\    a
        \\  }
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_arc_t r = ({");
    try expectLineBefore(e.text, "cell_arc_drop(a);", "_cell_t0 = cell_arc_clone(a);");
    try expectContains(e.text, "cell_arc_drop(r);");
}

test "an owned local a VALUE-position block does not use in its tail is released, and the moved tail is not" {
    var e = try emitSource(
        \\pub fn make() -> String { return "abc" }
        \\pub fn f() {
        \\  let owned r = {
        \\    let owned junk = make()
        \\    let owned t = make()
        \\    t
        \\  }
        \\}
    );
    defer e.deinit();
    try expectLineBefore(e.text, "cell_string_free(&junk);", "_cell_t0 = t;");
    try expectAbsent(e.text, "cell_string_free(&t);");
    try expectContains(e.text, "cell_string_free(&r);");
}

test "an owned local READ as a list element's block tail is not released: the element would dangle" {
    // The list element site reads a block tail rather than moving it, and
    // slice elements are never released, so `t` is copied by value into the
    // buffer. Freeing it here would leave the element pointing at freed
    // memory; ASan cannot see it (elements are never read back), so this
    // assertion is the only witness. The leak is the disclosed list-element
    // gap, unchanged.
    var e = try emitSource(
        \\pub fn make() -> String { return "abc" }
        \\pub fn f() {
        \\  let owned xs: [String] = [{
        \\    let owned t = make()
        \\    t
        \\  }]
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "_cell_t2 = t;");
    try expectAbsent(e.text, "cell_string_free(&t);");
}

test "a local the VALUE-position block's tail borrows is not released before the copy outside the braces" {
    // `cell_string_from_str(...)` wraps the statement expression, so the
    // view `_cell_t0` must still point at live memory at the closing brace.
    var e = try emitSource(
        \\pub fn make() -> String { return "abc" }
        \\pub fn mk() -> String {
        \\  return {
        \\    let owned t = make()
        \\    &t
        \\  }
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "_cell_t0 = cell_string_as_str(&t);");
    try expectAbsent(e.text, "cell_string_free(&t);");
}

test "a return block whose tail is an outer owned place moves it: no drop of the source" {
    // Borrowck records the move through `openBlockTail`, so `pendingDrops`
    // at the `return` skips `s1`; the block hands the buffer to the caller
    // once. Measured 2026-09-15 under ASan with the malloc counter:
    // ALLOC=1 FREE=1 LIVE=0 for this shape, for the block-local tail below,
    // and for the plain `return s1` control.
    var e = try emitSource(
        \\pub fn make() -> String { return "abc" }
        \\pub fn mk() -> String {
        \\    let owned s1 = make()
        \\    return { s1 }
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "_cell_t0 = s1;");
    try expectAbsent(e.text, "cell_string_free(&s1);");
}

test "a call argument block whose tail is the block's own owned local frees nothing itself" {
    // `t` is moved into the parameter, so the value-position block emits no
    // drop for it and the callee owns the buffer (the callee releases it
    // since R11 row 1; this test pins only that the caller does not).
    var e = try emitSource(
        \\pub fn make() -> String { return "abc" }
        \\pub fn eat(owned s: String) { }
        \\pub fn main() {
        \\    eat(owned {
        \\        let owned t = make()
        \\        t
        \\    })
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_eat(({");
    try expectContains(e.text, "_cell_t0 = t;");
    try expectAbsent(e.text, "cell_string_free(&t);");
}

test "a local a VALUE-position block's tail reaches through a borrow alias is not released" {
    // 85570d6 freed `t` here: the tail names `v`, not `t`, and a by-name
    // use scan cannot see that `v` is a view of `t`. `let shared s = { ... }`
    // then held a dangling view (the emitted C had `cell_string_free(&t)`
    // before `_cell_t0` left the braces). `tailReach` follows the block's
    // own `let`s to a fixpoint, so `t` is reached and kept. The leak of `t`
    // is the exclusion's stated cost.
    var e = try emitSource(
        \\pub fn make() -> String { return "abc" }
        \\pub fn inspect(shared s: String) -> Int { return 1 }
        \\pub fn f() {
        \\  let shared s = {
        \\    let owned t = make()
        \\    let shared v = &t
        \\    v
        \\  }
        \\  inspect(s)
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "_cell_t0 = v;");
    try expectAbsent(e.text, "cell_string_free(&t);");
}

test "tail reach is transitive through two aliases and an assignment, and unrelated locals still drop" {
    var e = try emitSource(
        \\pub fn make() -> String { return "abc" }
        \\pub fn inspect(shared s: String) -> Int { return 1 }
        \\pub fn f() {
        \\  let shared s = {
        \\    let owned junk = make()
        \\    let owned t = make()
        \\    let shared v = &t
        \\    var shared w = v
        \\    w = v
        \\    w
        \\  }
        \\  inspect(s)
        \\}
    );
    defer e.deinit();
    try expectAbsent(e.text, "cell_string_free(&t);");
    try expectLineBefore(e.text, "cell_string_free(&junk);", "_cell_t0 = w;");
}

test "reassigning an arc var evaluates the value into a temporary, drops the old box, then stores" {
    // R11 row 5, CLOSED 2026-09-15. examples/leaks/reassigned_var.cell read
    // 3000 on both witnesses before and 0 after; the gate went red on the
    // old pin before the constant moved.
    var e = try emitSource(
        \\pub fn inspect(shared s: String) -> Int { return 1 }
        \\pub fn f() {
        \\  var arc v = "one"
        \\  v = "two"
        \\  inspect(v)
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_arc_t _cell_t0 = cell_arc_from_string(");
    try expectLineBefore(e.text, "cell_arc_drop(v);", "cell_arc_t _cell_t0 = cell_arc_from_string(cell_string_from_str(cell_str_from_parts(\"two\", 3)));");
    try expectLineBefore(e.text, "v = _cell_t0;", "cell_arc_drop(v);");
}

test "reassigning a never-moved owned var releases the old value first" {
    // Until 2026-09-16 this test pinned the opposite (no temporary, no free
    // before the store), because `[s]` copied the header without marking `s`
    // moved and a pre-drop would have freed under that element. borrowck
    // refuses that element since c314a0e, so the `arc` reassignment pre-drop
    // now covers a never-moved `owned` `String` or list var too.
    var e = try emitSource(
        \\pub fn make() -> String { return "abc" }
        \\pub fn list() -> [Int] { return [1] }
        \\pub fn f() {
        \\  var owned s = make()
        \\  s = make()
        \\}
        \\pub fn g() {
        \\  var owned xs = list()
        \\  xs = list()
        \\}
    );
    defer e.deinit();
    const f = try fnDef(e.text, "f");
    // The value goes into a temporary first (`s = mk(s)` reads the old
    // value), then the old value is released, then the store.
    try expectLineBefore(f, "cell_string_free(&s);", "cell_string_t _cell_t2 = cell_make();");
    try expectLineBefore(f, "s = _cell_t2;", "cell_string_free(&s);");
    try expectOccurrences(f, "cell_string_free(&s);", 2);
    const g = try fnDef(e.text, "g");
    try expectOccurrences(g, "cell_slice_free(&xs);", 2);
    try expectCompiles(e.text);
}

test "a field store releases the old owned String or list field first" {
    // examples/leaks/field_store_old.cell, pinned at 1000 until 2026-09-21:
    // `t.name = v` never released the old value. Same shape as the
    // whole-binding pre-drop: temporary, release, store.
    var e = try emitSource(
        \\pub fn make() -> String { return "abc" }
        \\pub fn list() -> [Int] { return [1] }
        \\pub struct Tag {
        \\  owned name: String
        \\  owned xs: [Int]
        \\}
        \\pub fn f() {
        \\  var owned t = Tag { name: make(), xs: list() }
        \\  t.name = make()
        \\  t.xs = list()
        \\}
    );
    defer e.deinit();
    const f = try fnDef(e.text, "f");
    try expectOccurrences(f, "cell_string_free(&t.name);", 1);
    try expectOccurrences(f, "cell_slice_free(&t.xs);", 1);
    try expectLineBefore(f, "t.name = _cell_t", "cell_string_free(&t.name);");
    try expectCompiles(e.text);
}

test "a field store keeps the leak when the field, or any path of its root in a loop, was moved" {
    // Three guards, each the leak direction. `revive`: the old value went to
    // `take` (R3a revival), so a pre-drop would double free it. `in_loop`: a
    // move of ANY path of `t` inside the enclosing `while` body invalidates
    // the store, conservatively (the back edge could carry it). `through`:
    // an `exclusive` root; the old value belongs to the referent and the
    // shape was not measured.
    var e = try emitSource(
        \\pub fn make() -> String { return "abc" }
        \\pub fn take(owned s: String);
        \\pub struct Tag {
        \\  owned name: String
        \\  owned other: String
        \\}
        \\pub fn revive() {
        \\  var owned t = Tag { name: make(), other: make() }
        \\  take(t.name)
        \\  t.name = make()
        \\}
        \\pub fn in_loop(copy c: Int) {
        \\  var owned t = Tag { name: make(), other: make() }
        \\  var i = 0
        \\  while i < c {
        \\    t.name = make()
        \\    take(t.other)
        \\    t.other = make()
        \\    i = i + 1
        \\  }
        \\}
        \\pub fn through(exclusive t: Tag) {
        \\  t.name = make()
        \\}
    );
    defer e.deinit();
    // The scope-end drop still releases the revived field once, after the
    // store, so what must be absent is the PRE-drop shape: the value into a
    // temporary, then a free before the store.
    for ([_][]const u8{ "revive", "in_loop" }) |name| {
        const body = try fnDef(e.text, name);
        try expectAbsent(body, "_cell_t");
        try expectOccurrences(body, "cell_string_free(&t.name);", 1);
        // The one free is the scope-end release: it comes AFTER the store.
        const store = std.mem.indexOf(u8, body, "t.name = cell_make();").?;
        const free = std.mem.indexOf(u8, body, "cell_string_free(&t.name);").?;
        try std.testing.expect(store < free);
    }
    try expectAbsent(try fnDef(e.text, "through"), "cell_string_free(");
    try expectCompiles(e.text);
}

test "reassigning a moved owned var keeps no pre-drop: its old value is gone" {
    // R3a revival and a move on one branch. borrowck's `wasMoved` is
    // permanent and branch-conservative, so both answer "moved" and no
    // release is emitted before the store: the old value belongs to `take`.
    // Removing that guard was measured as an AddressSanitizer double free
    // (exit 134). The reassigned value is live at the end of both bodies,
    // so the scope-end drop releases it (borrowck's `exit_liveness`), and
    // that is the only release: it comes after the store.
    var e = try emitSource(
        \\pub fn take(owned s: String);
        \\pub fn revive() {
        \\  var owned v: String = "a"
        \\  take(v)
        \\  v = "b"
        \\}
        \\pub fn branch(copy c: Int) {
        \\  var owned v: String = "a"
        \\  if c > 0 {
        \\    take(v)
        \\  }
        \\  v = "b"
        \\}
    );
    defer e.deinit();
    for ([_][]const u8{ "revive", "branch" }) |name| {
        const body = try fnDef(e.text, name);
        try expectOccurrences(body, "cell_string_free(&v);", 1);
        try expectLineBefore(body, "cell_string_free(&v);", "v = cell_string_from_str(cell_str_from_parts(\"b\", 1));");
        try expectAbsent(body, "_cell_t0");
    }
    try expectCompiles(e.text);
}
