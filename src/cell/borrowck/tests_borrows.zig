//! Borrow checker tests: R9, R14, R7, resource shapes, and moved paths.

const std = @import("std");
const ast = @import("../ast.zig");
const lexer = @import("../lexer.zig");
const parser = @import("../parser.zig");
const bk_root = @import("../borrowck.zig");
const bk_tests_support = @import("tests_support.zig");
const Checker = bk_root.Checker;
const expectDiagnostics = bk_tests_support.expectDiagnostics;
const expectAccepted = bk_tests_support.expectAccepted;
const expectRejectedWith = bk_tests_support.expectRejectedWith;
const prelude = bk_tests_support.prelude;

// ── R9: `arc` grants shared access only ─────────────────────────────────
//
// Every program in this group was ACCEPTED at exit 0 before these checks
// landed, measured against `zig-out/bin/cell` built at `b3698a7`. The
// `docs/SPEC.md` 4.1.4 text calling mutation through `arc` "not permitted in
// this revision" was therefore an overclaimed safety guarantee, which is the
// one direction of documentation error this repository treats as worse than
// silence.

test "R9: an arc place may not be passed to an exclusive parameter" {
    // Measured before this check: accepted, and emitted
    // `cell_grow(((cell_string_t *)s.ptr))` for the String analogue, a mutable
    // pointer into the shared box, clean at `-Wall -Wextra -Werror`.
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let arc b = Buffer { data: [], len: 0 }
        \\    grow(exclusive b, shared 1)
        \\}
    ,
        \\t.cell:11:20: error: cannot borrow 'b' as exclusive: 'arc' grants shared access only
        \\t.cell:11:20: note: mutation through 'arc' needs interior mutability, which Cell does not have yet
        \\
    );
}

test "R9: an arc place may not be borrowed as exclusive by a let" {
    // The other spelling, and the reason the check lives in `createLoan`
    // rather than in `checkCall`: one choke point, not a second enumeration.
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    var arc b = Buffer { data: [], len: 0 }
        \\    let exclusive e = &mut b
        \\}
    ,
        \\t.cell:11:28: error: cannot borrow 'b' as exclusive: 'arc' grants shared access only
        \\t.cell:11:28: note: mutation through 'arc' needs interior mutability, which Cell does not have yet
        \\
    );
}

test "R9 asks every step of the chain, so an arc FIELD is refused too" {
    // The worst of the measured emits: `cell_grow(((cell_string_t *)&b.h.ptr))`
    // for the String analogue, a mutable pointer aimed at the arc handle's own
    // pointer field. Silent, and accepted by `cc`. A check that only asked
    // about the BINDING would miss it, which is this file's recurring failure.
    try expectDiagnostics(prelude ++
        \\pub struct Holder { arc h: Buffer }
        \\pub fn main() {
        \\    let owned k = Holder { h: Buffer { data: [], len: 0 } }
        \\    grow(&mut k.h, shared 1)
        \\}
    ,
        \\t.cell:12:15: error: cannot borrow 'k.h' as exclusive: 'arc' grants shared access only
        \\t.cell:12:15: note: mutation through 'arc' needs interior mutability, which Cell does not have yet
        \\
    );
}

test "R9: a write through an arc binding is refused" {
    // Measured before this check: accepted, and emitted
    // `cell_arc_t b = (cell_B){ .n = 1 }; b.n = 2;`, which `cc` then refused.
    // A loud C error is the mild end of R9; the borrow forms above are silent.
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    var arc b = Buffer { data: [], len: 0 }
        \\    b.len = 2
        \\}
    ,
        \\t.cell:11:5: error: cannot assign to 'b.len': it is reached through the 'arc' handle 'b', which grants shared access only
        \\t.cell:11:5: note: mutation through 'arc' needs interior mutability, which Cell does not have yet
        \\
    );
}

test "R9 refuses an exclusive borrow whose ownership it cannot resolve" {
    // The verdict is total, so an unreadable annotation is a REFUSAL and not
    // silence. `s` is an `Int`, so `s.data` has no field annotation to read.
    try expectDiagnostics(prelude ++
        \\pub fn use_bytes(exclusive d: [Byte]) { }
        \\pub fn main() {
        \\    let copy s = 1
        \\    use_bytes(&mut s.data)
        \\}
    ,
        \\t.cell:12:20: error: cannot borrow 's.data' as exclusive: the ownership of the field 'data' of 's' cannot be resolved here
        \\t.cell:12:20: note: R9 refuses what it cannot prove is not 'arc': a unique reference into a shared value mutates every holder
        \\
    );
}

test "R9 leaves a shared borrow of an arc place alone" {
    // R10's table makes `arc` to a `shared` parameter legal: it borrows the
    // pointee without retaining, and R8 keeps the borrow inside the block.
    // Refusing this would break `examples/arc.cell`.
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    let arc b = Buffer { data: [], len: 0 }
        \\    read(shared b)
        \\}
    );
}

test "R9 leaves rebinding a var arc handle alone" {
    // Assigning to the handle ITSELF replaces the reference and does not
    // mutate the shared value, so it is R11's leak (the previous box is never
    // released) and not R9's rule. That is why the assignment check asks only
    // the STRICT prefixes of the target's path.
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    var arc b = Buffer { data: [], len: 0 }
        \\    b = Buffer { data: [], len: 1 }
        \\}
    );
}

test "a field borrow through a named loan resolves the referent's struct type" {
    // `let exclusive e = &mut buf` carries no type annotation, is not a struct
    // literal and is not a call, so `e` used to reach `declare` with no
    // `struct_name` at all. Harmless while an unresolved annotation meant
    // "permit"; under R9's total verdict it would mean REFUSE, and this
    // ordinary field borrow would stop compiling. Same shape as the call
    // inference `b3698a7` had to add for R10, in a new position.
    try expectAccepted(prelude ++
        \\pub fn use_bytes(exclusive d: [Byte]) { }
        \\pub fn main() {
        \\    var owned buf = Buffer { data: [], len: 0 }
        \\    let exclusive e = &mut buf
        \\    use_bytes(&mut e.data)
        \\}
    );
}

// ── R14's second clause: a borrow-holding binding may not be rebound ─────

test "R14: a var-bound exclusive borrow may not be retargeted" {
    // Measured before this check: accepted at exit 0. `placeOf` returns null
    // for a unary, so `checkExpr` made a TEMPORARY loan on the new referent
    // that died with the statement, leaving a loan on the OLD referent and
    // none on the new one; a following `take(owned other)` was accepted.
    //
    // The C backend does not retarget at all: it emits `*e = *&other;`. With
    // heap values that aliases one buffer into two owners and both are freed,
    // measured as an AddressSanitizer double free at exit 134. Refusing is the
    // answer because the statement has two meanings and the compiler
    // implements a different one in each half.
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let owned other = Buffer { data: [], len: 0 }
        \\    var exclusive e = &mut buf
        \\    e = &mut other
        \\}
    ,
        \\t.cell:13:5: error: cannot assign a borrow of 'other' to 'e': it already holds a borrow, and rebinding one is not defined in this revision
        \\t.cell:13:5: note: the C backend writes THROUGH the borrow rather than retargeting it, so the two readings of this statement differ; bind a new name instead
        \\
    );
}

test "R14's rebinding clause reads the loan, not only the annotation" {
    // `checkLetInit` creates a named loan whenever the initializer is a `&`
    // form, REGARDLESS of the annotation, so a binding whose declared mode is
    // not a borrow can hold one. Asking only about the declared mode would be
    // exactly the enumeration this file keeps being caught by; `holdsBorrow`
    // asks both.
    //
    // The witness has now moved TWICE, and the reason is recorded because the
    // clause under test is not what keeps changing. It was `var owned`, which
    // R18 refuses at the `let` so no loan is created; then `var copy`, which
    // R12's binding clause now refuses because `Buffer` owns a `[Byte]` and
    // copying its header would make two owners of one buffer. `var arc` is the
    // third duplicable spelling and still reaches the loan branch, so the
    // clause keeps a live case. The other two spellings are pinned by the R18
    // and R12 tests respectively, so all three halves stay covered.
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let owned other = Buffer { data: [], len: 0 }
        \\    var arc e = &mut buf
        \\    e = &mut other
        \\}
    ,
        \\t.cell:13:5: error: cannot assign a borrow of 'other' to 'e': it already holds a borrow, and rebinding one is not defined in this revision
        \\t.cell:13:5: note: the C backend writes THROUGH the borrow rather than retargeting it, so the two readings of this statement differ; bind a new name instead
        \\
    );
}

test "R14's rebinding clause refuses a value it cannot classify" {
    // `borrowSource` is total for the same reason `arcUniqueSource` is: the
    // permissive default is what every previous widening escaped through.
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    var exclusive e = &mut buf
        \\    e = unresolved_callee()
        \\}
    ,
        \\t.cell:12:5: error: cannot assign to 'e', which holds a borrow: the result of the unresolved callee 'unresolved_callee' cannot be classified as a value or a borrow here
        \\t.cell:12:5: note: R14 refuses what it cannot prove is not a borrow: a retarget the checker does not see leaves a loan on the old referent and none on the new one
        \\
    );
}

test "a whole-value write through a var exclusive borrow is still allowed" {
    // The legitimate neighbour the rebinding clause must not eat.
    // `runtime/cell_rt.h` section 7 defines `exclusive` as the callee mutating
    // the caller's value, and a codegen fix already landed for this form.
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    var exclusive e = &mut buf
        \\    e = Buffer { data: [], len: 3 }
        \\    use_it(e)
        \\}
    );
}

test "a field write through a let-bound exclusive borrow is still allowed" {
    // The other neighbour: `examples/ownership.cell` writes `buf.len` through
    // an `exclusive buf: Buffer` parameter, and the rebinding clause is scoped
    // to an EMPTY path so it never sees this.
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    var owned buf = Buffer { data: [], len: 0 }
        \\    let exclusive e = &mut buf
        \\    grow(exclusive e, shared 1)
        \\    e.len = 4
        \\}
    );
}

test "R9 reaches a VALUE position: an arc call result may not be borrowed as exclusive" {
    // Axis 1 of R10's history, repeating in a new rule. `createLoan` is the
    // choke point for every exclusive loan and only a PLACE creates one, so
    // this escaped the rule that refuses `grow(exclusive b, shared 1)` for the
    // same handle. Measured before this: accepted at exit 0, emitting
    // `cell_grow(((cell_string_t *)&cell_fresh().ptr))`.
    try expectDiagnostics(prelude ++
        \\pub fn fresh() -> arc Buffer;
        \\pub fn main() {
        \\    grow(&mut fresh(), shared 1)
        \\}
    ,
        \\t.cell:11:15: error: cannot borrow 'fresh()' as exclusive: 'arc' grants shared access only
        \\t.cell:11:15: note: mutation through 'arc' needs interior mutability, which Cell does not have yet
        \\
    );
}

test "R9's value position is checked at BOTH sites, not only the unary one" {
    // `checkCall` peels the sigil itself and hands `checkExpr` the operand, so
    // the unary arm never sees a call argument. Fixing only the unary arm left
    // the measured program above still accepted; this test is the bare form
    // that the unary arm does see, and the pair is what keeps them together.
    try expectDiagnostics(prelude ++
        \\pub fn fresh() -> arc Buffer;
        \\pub fn main() {
        \\    &mut fresh()
        \\}
    ,
        \\t.cell:11:10: error: cannot borrow 'fresh()' as exclusive: 'arc' grants shared access only
        \\t.cell:11:10: note: mutation through 'arc' needs interior mutability, which Cell does not have yet
        \\
    );
}

test "a match arm binding inherits the scrutinee's struct type" {
    // Not R7, which is still unimplemented: only the struct TYPE, which is
    // what `placeOwnership` needs one level down. An arm binding declared with
    // no struct name made this ordinary field borrow undecidable, and R9's
    // total verdict turns undecidable into refused. Found by probing for the
    // same residual the `checkLet` propagation had already closed once.
    try expectAccepted(prelude ++
        \\pub fn use_bytes(exclusive d: [Byte]) { }
        \\pub fn main() {
        \\    var owned src = Buffer { data: [], len: 0 }
        \\    match src {
        \\        x => use_bytes(&mut x.data)
        \\    }
        \\}
    );
}

test "R9 reaches an arc field through a match arm binding" {
    // The other half of the propagation, and the reason it is not a weakening:
    // resolving the arm binding's type turns a vague "cannot be resolved here"
    // into R9's own verdict, read off a real annotation. Both refuse; only one
    // says why.
    try expectDiagnostics(prelude ++
        \\pub struct Holder { arc h: Buffer }
        \\pub fn main() {
        \\    var owned src = Holder { h: Buffer { data: [], len: 0 } }
        \\    match src {
        \\        x => grow(&mut x.h, shared 1)
        \\    }
        \\}
    ,
        \\t.cell:13:24: error: cannot borrow 'x.h' as exclusive: 'arc' grants shared access only
        \\t.cell:13:24: note: mutation through 'arc' needs interior mutability, which Cell does not have yet
        \\
    );
}

// ── R7's consumption clause ─────────────────────────────────────────────
//
// The scrutinee is READ, never moved, so an arm binding is an alias of it and
// not a second owner. Every `owned` consumption site asked `placeOf`, got a
// place rooted at the arm binding, and moved THAT. Eleven shapes were measured
// live at `4698dbc`; the four below that carry a measured exit code name it in
// their comment, and `examples/rejected/owned_move_through_match_binding.cell`
// carries the whole table.

test "R7: an arm binding may not be passed to an owned parameter" {
    // The reproducer, measured at `4698dbc`: `cell check` exit 0,
    // `cc -fsanitize=address` exit 0, running it exit 134,
    // `AddressSanitizer: attempting double-free`.
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    match buf {
        \\        x => take(owned x)
        \\    }
        \\}
    ,
        \\t.cell:12:25: error: cannot pass the match binding 'x' aliasing 'buf' to 'owned' parameter 'b': the scrutinee still owns the value
        \\t.cell:12:25: note: R7 does not move the scrutinee yet, so a match binding is an alias and not a second owner; consuming it frees a buffer the scrutinee's own drop frees again
        \\
    );
}

test "R7: a call-result scrutinee still lowers, because nothing else owns it" {
    // The distinction the rule draws, and the row that must NOT be refused:
    // measured at `4698dbc` and again after the fix, exit 0. A scrutinee with
    // no place behind it has no other owner, so the arm binding is the only
    // handle and consuming it is a move of a temporary.
    try expectAccepted(prelude ++
        \\pub fn fresh() -> Buffer;
        \\pub fn main() {
        \\    match fresh() {
        \\        x => take(owned x)
        \\    }
        \\}
    );
}

test "R7 over-refuses a nested arm binding over a TEMP, and that is the fix" {
    // This program is safe today, measured exit 0, and it is refused anyway.
    // The first version of R7 accepted it, by propagating `.temp` through a
    // whole arm binding: `x` is a temporary with no other owner, so `y` is one
    // too. Sound about ONE consumer, false about two, and the version below is
    // what falsified it -- so this pair is kept together on purpose, the
    // over-refusal above the reason for it.
    try expectDiagnostics(prelude ++
        \\pub fn fresh() -> Buffer;
        \\pub fn main() {
        \\    match fresh() {
        \\        x => match x {
        \\            y => take(owned y)
        \\        }
        \\    }
        \\}
    ,
        \\t.cell:13:29: error: cannot pass the match binding 'y' aliasing 'x' to 'owned' parameter 'b': the scrutinee still owns the value
        \\t.cell:13:29: note: R7 does not move the scrutinee yet, so a match binding is an alias and not a second owner; consuming it frees a buffer the scrutinee's own drop frees again
        \\
    );
}

test "R7: two live handles on one temp, which R2 cannot see" {
    // The measurement that removed the propagation. `x` and `y` are two
    // different bindings with two different ids, both holding one buffer, so
    // R2's use-after-move never fires: `take(owned y)` frees it and
    // `take(owned x)` frees it again, exit 134 under AddressSanitizer.
    //
    // Nesting a `match` is the ONLY construct in this grammar that makes two
    // live handles: `let owned y = x` moves `x`, which is why the `let`
    // spelling was already safe and why this one was not. Refusing the inner
    // binding closes the class rather than this shape.
    try expectDiagnostics(prelude ++
        \\pub fn fresh() -> Buffer;
        \\pub fn main() {
        \\    match fresh() {
        \\        x => { match x {
        \\                   y => take(owned y)
        \\               }
        \\               take(owned x) }
        \\    }
        \\}
    ,
        \\t.cell:13:36: error: cannot pass the match binding 'y' aliasing 'x' to 'owned' parameter 'b': the scrutinee still owns the value
        \\t.cell:13:36: note: R7 does not move the scrutinee yet, so a match binding is an alias and not a second owner; consuming it frees a buffer the scrutinee's own drop frees again
        \\
    );
}

test "R7: a nested arm binding over a PLACE scrutinee is refused" {
    // The same nesting over a place was measured exit 134 at `4698dbc`. The
    // pair with the test above is the whole point: nesting does not launder
    // the question, it forwards it.
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    match buf {
        \\        x => match x {
        \\            y => take(owned y)
        \\        }
        \\    }
        \\}
    ,
        \\t.cell:13:29: error: cannot pass the match binding 'y' aliasing 'x' to 'owned' parameter 'b': the scrutinee still owns the value
        \\t.cell:13:29: note: R7 does not move the scrutinee yet, so a match binding is an alias and not a second owner; consuming it frees a buffer the scrutinee's own drop frees again
        \\
    );
}

test "R7: an arm binding may not be returned" {
    // Measured at `4698dbc`: returning an arm binding out of a `-> String`
    // body was exit 134, the caller's holder and the callee's scope drop
    // freeing one buffer.
    try expectDiagnostics(prelude ++
        \\pub fn pick(owned seed: Buffer) -> Buffer {
        \\    match seed {
        \\        x => { return x }
        \\    }
        \\    return seed
        \\}
    ,
        \\t.cell:11:23: error: cannot return the match binding 'x' aliasing 'seed' from 'owned' function 'pick': the scrutinee still owns the value
        \\t.cell:11:23: note: R7 does not move the scrutinee yet, so a match binding is an alias and not a second owner; consuming it frees a buffer the scrutinee's own drop frees again
        \\
    );
}

test "R7: an arm binding may not be assigned into an owned place" {
    // Measured at `4698dbc`: `match s1 { x => { d = x } }` into a
    // `var owned d` was exit 134.
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    var owned dst = Buffer { data: [], len: 0 }
        \\    match buf {
        \\        x => { dst = x }
        \\    }
        \\}
    ,
        \\t.cell:13:22: error: cannot assign the match binding 'x' aliasing 'buf' to 'owned' place 'dst': the scrutinee still owns the value
        \\t.cell:13:22: note: R7 does not move the scrutinee yet, so a match binding is an alias and not a second owner; consuming it frees a buffer the scrutinee's own drop frees again
        \\
    );
}

test "R7: an arm binding may not initialise an owned let" {
    // NOT a double free at `4698dbc` (measured exit 0), and refused anyway:
    // an arm binding is never dropped either, so the three headers merely
    // aliased one buffer. Arm-scope drops detonate it, and the file's standing
    // choice is to refuse a latent case with the live ones rather than leave
    // it as a trap for the change that lands them.
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    match buf {
        \\        x => { let owned y: Buffer = x
        \\               read(shared y) }
        \\    }
        \\}
    ,
        \\t.cell:12:38: error: cannot bind the match binding 'x' aliasing 'buf' to 'owned' binding 'y': the scrutinee still owns the value
        \\t.cell:12:38: note: R7 does not move the scrutinee yet, so a match binding is an alias and not a second owner; consuming it frees a buffer the scrutinee's own drop frees again
        \\
    );
}

test "R7: a FIELD of an aliasing arm binding is refused too" {
    // The question is asked of the place, not of the name, so `x.data` is the
    // same alias one segment deeper. Measured exit 0 at `4698dbc` only because
    // this backend never drops a `record`, which is R11's gap and not a reason
    // to accept.
    try expectDiagnostics(prelude ++
        \\pub fn eat(owned d: [Byte]) { }
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    match buf {
        \\        x => eat(owned x.data)
        \\    }
        \\}
    ,
        \\t.cell:13:24: error: cannot pass the match binding 'x.data' aliasing 'buf' to 'owned' parameter 'd': the scrutinee still owns the value
        \\t.cell:13:24: note: R7 does not move the scrutinee yet, so a match binding is an alias and not a second owner; consuming it frees a buffer the scrutinee's own drop frees again
        \\
    );
}

test "R7: a BORROWED scrutinee is refused, and the C type is why that matters" {
    // Measured at `4698dbc` with a `shared [Int]` parameter as the scrutinee:
    // exit 134. The `String` spelling of the same program ran clean, because
    // `owned String` and `shared String` are DIFFERENT C types and codegen
    // inserted a copy, while `owned [T]` and `shared [T]` are the same type
    // and it inserted nothing. A rule whose enforcement depends on which two C
    // types happen to coincide is the thing `refuseArcUnique`'s comment
    // already refuses to write, so both spellings are refused here.
    try expectDiagnostics(prelude ++
        \\pub fn borrowing(shared b: Buffer) {
        \\    match b {
        \\        x => take(owned x)
        \\    }
        \\}
    ,
        \\t.cell:11:25: error: cannot pass the match binding 'x' aliasing 'b' to 'owned' parameter 'b': the scrutinee still owns the value
        \\t.cell:11:25: note: R7 does not move the scrutinee yet, so a match binding is an alias and not a second owner; consuming it frees a buffer the scrutinee's own drop frees again
        \\
    );
}

test "a FIELD of a temp arm binding is refused, and R10 gets there first" {
    // Written to pin R7's narrow propagation -- temp-ness crosses an EMPTY
    // path only, so `take(owned x)` is accepted above while `x.data` is not --
    // and MEASURED to be refused by something else entirely. `scrutinee_struct`
    // is read off `placeOf(scrutinee)`, which is null for a call, so a `.temp`
    // arm binding never has a struct name, and R10's total verdict calls every
    // field of it unresolved. That is the residual `checkLet` already records
    // for an unannotated `match` or call initializer, reached from the other
    // side.
    //
    // The test is kept with its real output rather than deleted, because the
    // shape it was written for is genuinely unreachable as an R7 diagnostic
    // today: anyone who closes R10's residual will land here, and the arm
    // below is the answer they need. Both refusals are the safe direction.
    try expectDiagnostics(prelude ++
        \\pub fn fresh() -> Buffer;
        \\pub fn eat(owned d: [Byte]) { }
        \\pub fn main() {
        \\    match fresh() {
        \\        x => eat(owned x.data)
        \\    }
        \\}
    ,
        \\t.cell:13:24: error: cannot pass the place 'x.data' to 'owned' parameter 'd': its ownership cannot be resolved here
        \\t.cell:13:24: note: R10 refuses what it cannot prove is not 'arc': an 'arc' value made unique is freed twice
        \\
    );
}

test "R7 aliases cannot enter owning resource fields" {
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    match buf {
        \\        x => read(shared Buffer { data: x, len: 0 })
        \\    }
        \\}
    ,
        \\t.cell:12:41: error: cannot store the match binding 'x' aliasing 'buf' in owned field 'data': the source is not a fresh owned value
        \\t.cell:12:41: note: aggregate ownership transfer is not implemented; construct a fresh field value instead
        \\
    );
}

test "R7 leaves a shared read of an arm binding alone" {
    // The rule is scoped to `owned` consumption. Reading through an arm
    // binding is what `match` is for, was measured exit 0, and stays exit 0.
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    match buf {
        \\        x => use_it(shared x)
        \\    }
        \\    take(buf)
        \\}
    );
}

test "R7 does not touch a copy scrutinee" {
    // A `copy` place duplicates rather than moving, so nothing is aliased and
    // there is nothing to refuse. Measured exit 0 before and after.
    try expectAccepted(prelude ++
        \\pub fn show(copy n: Int) { }
        \\pub fn main() {
        \\    let copy n = 3
        \\    match n {
        \\        x => show(copy x)
        \\    }
        \\}
    );
}

test "R7 closes an R10 escape: an arm binding launders an arc scrutinee" {
    // `arcUniqueSource` reads the ARM BINDING's own annotation, which
    // `checkMatch` declares `.owned`, so it could not see the scrutinee's
    // `arc`. Measured at `4698dbc` with an `arc [Int]` place:
    // `take_list(owned a)` was already refused by R10, and
    // `match a { x => take_list(owned x) }` was `cell check` exit 0 and
    // running it exit 134. R7's question is asked of the PLACE and does not
    // need to know the scrutinee is `arc`, which is why one check closes two
    // rules' escapes.
    try expectDiagnostics(prelude ++
        \\pub fn shared_buf() -> arc Buffer;
        \\pub fn main() {
        \\    let arc a: Buffer = shared_buf()
        \\    match a {
        \\        x => take(owned x)
        \\    }
        \\}
    ,
        \\t.cell:13:25: error: cannot pass the match binding 'x' aliasing 'a' to 'owned' parameter 'b': the scrutinee still owns the value
        \\t.cell:13:25: note: R7 does not move the scrutinee yet, so a match binding is an alias and not a second owner; consuming it frees a buffer the scrutinee's own drop frees again
        \\
    );
}

test "resource shape is total across every declared type variant" {
    var checker = Checker.init(std.testing.allocator, "t.cell", null);
    defer checker.deinit();

    var string_ty: ast.TypeExpr = .{ .name = "String" };
    var int_ty: ast.TypeExpr = .{ .name = "Int" };
    var float64_ty: ast.TypeExpr = .{ .name = "Float64" };
    var unknown_ty: ast.TypeExpr = .{ .name = "Missing" };
    var list_ty: ast.TypeExpr = .{ .list = &int_ty };
    var optional_ty: ast.TypeExpr = .{ .optional = &string_ty };
    var result_ty: ast.TypeExpr = .{ .result = .{ .ok = &int_ty, .err = &string_ty } };
    var ref_ty: ast.TypeExpr = .{ .ref = .{ .ownership = .copy, .inner = &string_ty } };
    var unit_ty: ast.TypeExpr = .unit;

    try std.testing.expectEqual(Checker.ResourceShape.resources, try checker.resourceShape(&string_ty));
    try std.testing.expectEqual(Checker.ResourceShape.no_resources, try checker.resourceShape(&int_ty));
    try std.testing.expectEqual(Checker.ResourceShape.no_resources, try checker.resourceShape(&float64_ty));
    try std.testing.expectEqual(Checker.ResourceShape.unknown, try checker.resourceShape(&unknown_ty));
    try std.testing.expectEqual(Checker.ResourceShape.resources, try checker.resourceShape(&list_ty));
    try std.testing.expectEqual(Checker.ResourceShape.resources, try checker.resourceShape(&optional_ty));
    try std.testing.expectEqual(Checker.ResourceShape.resources, try checker.resourceShape(&result_ty));
    try std.testing.expectEqual(Checker.ResourceShape.resources, try checker.resourceShape(&ref_ty));
    try std.testing.expectEqual(Checker.ResourceShape.no_resources, try checker.resourceShape(&unit_ty));

    var color_variants = [_][]const u8{"Red"};
    const color = ast.EnumDef{ .name = "Color", .variants = &color_variants, .is_public = false };
    try checker.enums.put(checker.allocator, color.name, color);
    var color_ty: ast.TypeExpr = .{ .name = "Color" };
    try std.testing.expectEqual(Checker.ResourceShape.no_resources, try checker.resourceShape(&color_ty));

    var scalar_fields = [_]ast.Field{.{
        .name = "n",
        .ty = .{ .name = "Int" },
        .ownership = .copy,
    }};
    var nested_fields = [_]ast.Field{.{
        .name = "s",
        .ty = .{ .name = "String" },
        .ownership = .owned,
    }};
    var cycle_fields = [_]ast.Field{.{
        .name = "next",
        .ty = .{ .name = "Cycle" },
        .ownership = .owned,
    }};
    const scalar = ast.StructDef{ .name = "Scalar", .fields = &scalar_fields, .is_public = false };
    const nested = ast.StructDef{ .name = "Nested", .fields = &nested_fields, .is_public = false };
    const cycle = ast.StructDef{ .name = "Cycle", .fields = &cycle_fields, .is_public = false };
    try checker.structs.put(checker.allocator, scalar.name, scalar);
    try checker.structs.put(checker.allocator, nested.name, nested);
    try checker.structs.put(checker.allocator, cycle.name, cycle);
    var scalar_ty: ast.TypeExpr = .{ .name = "Scalar" };
    var nested_ty: ast.TypeExpr = .{ .name = "Nested" };
    var cycle_ty: ast.TypeExpr = .{ .name = "Cycle" };
    try std.testing.expectEqual(Checker.ResourceShape.no_resources, try checker.resourceShape(&scalar_ty));
    try std.testing.expectEqual(Checker.ResourceShape.resources, try checker.resourceShape(&nested_ty));
    try std.testing.expectEqual(Checker.ResourceShape.unknown, try checker.resourceShape(&cycle_ty));
}

test "copy fields reject resource and unknown shapes but preserve scalar records" {
    try expectDiagnostics(
        \\pub struct BadString { copy value: String }
        \\pub struct BadList { copy value: [Int] }
        \\pub struct Inner { owned value: String }
        \\pub struct BadNested { copy value: Inner }
        \\pub struct BadOptional { copy value: String? }
        \\pub struct BadUnknown { copy value: Missing }
    ,
        \\t.cell:1:1: error: cannot declare copy field 'value': its type may own resources and copying its header would create two owners
        \\t.cell:1:1: note: use an 'owned' or 'arc' field; resource-bearing copy fields are unsupported
        \\t.cell:2:1: error: cannot declare copy field 'value': its type may own resources and copying its header would create two owners
        \\t.cell:2:1: note: use an 'owned' or 'arc' field; resource-bearing copy fields are unsupported
        \\t.cell:4:1: error: cannot declare copy field 'value': its type may own resources and copying its header would create two owners
        \\t.cell:4:1: note: use an 'owned' or 'arc' field; resource-bearing copy fields are unsupported
        \\t.cell:5:1: error: cannot declare copy field 'value': its type may own resources and copying its header would create two owners
        \\t.cell:5:1: note: use an 'owned' or 'arc' field; resource-bearing copy fields are unsupported
        \\t.cell:6:1: error: cannot declare copy field 'value': its type may own resources and copying its header would create two owners
        \\t.cell:6:1: note: use an 'owned' or 'arc' field; resource-bearing copy fields are unsupported
        \\
    );
    try expectAccepted(
        \\pub enum Color { Red, Blue }
        \\pub struct Point { copy x: Int copy color: Color }
        \\pub struct Wrapper { copy point: Point }
    );
}

test "a boxed record hides in a copy field until the classifier reads field ownership" {
    // The gap the owning-field slice left open. `arc Point` is NOT `Point`:
    // it emits `cell_arc_t point;` while `Point` emits two `int64_t`s, both
    // measured. A classifier that recursed on the declared TYPE and skipped
    // the KEYWORD saw a scalar-only record and let a `copy` field shallow-copy
    // a refcount header, which is a second owner that never retained.
    try expectDiagnostics(
        \\pub enum Color { Red, Blue }
        \\pub struct Point { copy x: Int copy y: Int }
        \\pub struct ArcRecord { arc point: Point }
        \\pub struct BadNestedArc { copy holder: ArcRecord }
        \\pub struct BadQualifiedArc { copy point: arc Point }
        \\pub struct ArcString { arc name: String }
        \\pub struct BadNestedArcString { copy s: ArcString }
    ,
        \\t.cell:4:1: error: cannot declare copy field 'holder': its type may own resources and copying its header would create two owners
        \\t.cell:4:1: note: use an 'owned' or 'arc' field; resource-bearing copy fields are unsupported
        \\t.cell:5:1: error: cannot declare copy field 'point': its type may own resources and copying its header would create two owners
        \\t.cell:5:1: note: use an 'owned' or 'arc' field; resource-bearing copy fields are unsupported
        \\t.cell:7:1: error: cannot declare copy field 's': its type may own resources and copying its header would create two owners
        \\t.cell:7:1: note: use an 'owned' or 'arc' field; resource-bearing copy fields are unsupported
        \\
    );
    // The controls that keep this from being "reject every arc". Primitive
    // ARC is by value under the language contract: `arc Int` emits `int64_t`
    // and an enum is a distinct integer type, so neither is a handle and
    // neither may be refused. `copy n: arc Int` is the qualified spelling of
    // the same thing and must agree with the annotated one.
    try expectAccepted(
        \\pub enum Color { Red, Blue }
        \\pub struct Point { copy x: Int copy y: Int }
        \\pub struct PrimitiveArc { arc n: Int }
        \\pub struct OkPrimitiveArc { copy h: PrimitiveArc }
        \\pub struct EnumArc { arc c: Color }
        \\pub struct OkEnumArc { copy e: EnumArc }
        \\pub struct OkScalarRecord { copy p: Point }
        \\pub struct OkQualifiedPrimitiveArc { copy n: arc Int }
    );
}

test "owned resource fields accept fresh values and refuse every unsafe source class" {
    try expectAccepted(
        \\pub struct Tag { owned name: String }
        \\pub fn make() -> String;
        \\pub fn main() {
        \\    let owned a = Tag { name: "literal" }
        \\    let owned b = Tag { name: make() }
        \\}
    );
    try expectDiagnostics(
        \\pub struct Tag { owned name: String }
        \\pub fn make() -> String;
        \\pub fn main() {
        \\    let owned source = make()
        \\    let owned a = Tag { name: source }
        \\    let owned b = Tag { name: owned source }
        \\}
    ,
        \\t.cell:5:31: error: cannot store source in owned field 'name': moving a place into an aggregate is not implemented
        \\t.cell:5:31: note: aggregate ownership transfer is not implemented; construct a fresh field value instead
        \\t.cell:6:31: error: cannot store source in owned field 'name': moving a place into an aggregate is not implemented
        \\t.cell:6:31: note: aggregate ownership transfer is not implemented; construct a fresh field value instead
        \\
    );
    try expectDiagnostics(
        \\pub struct Tag { owned name: String }
        \\pub fn inspect(shared s: String) -> shared String;
        \\pub fn main(shared source: String) {
        \\    let owned a = Tag { name: &source }
        \\    let owned b = Tag { name: shared source }
        \\    let owned c = Tag { name: inspect(shared source) }
        \\}
    ,
        \\t.cell:2:1: error: cannot return a shared borrow: Cell has no lifetime annotations, so the borrow cannot be proven to outlive the call
        \\t.cell:2:1: note: return an 'owned' or 'arc' value instead
        \\t.cell:4:31: error: cannot store a borrow of 'source' in owned field 'name': a borrow does not transfer ownership
        \\t.cell:4:31: note: aggregate ownership transfer is not implemented; construct a fresh field value instead
        \\t.cell:5:31: error: cannot store a borrow of 'source' in owned field 'name': a borrow does not transfer ownership
        \\t.cell:5:31: note: aggregate ownership transfer is not implemented; construct a fresh field value instead
        \\t.cell:6:31: error: cannot store the borrow returned by 'inspect' in owned field 'name': a borrow does not transfer ownership
        \\t.cell:6:31: note: aggregate ownership transfer is not implemented; construct a fresh field value instead
        \\
    );
}

test "owning field guard follows field paths and recursive destination shapes" {
    try expectDiagnostics(
        \\pub struct Inner { owned name: String }
        \\pub struct Outer { owned inner: Inner }
        \\pub struct Maybe { owned name: String? }
        \\pub struct Lists { owned items: [Int] }
        \\pub fn make_string() -> String;
        \\pub fn make_inner() -> Inner;
        \\pub fn make_list() -> [Int];
        \\pub fn main() {
        \\    let owned source = make_string()
        \\    let owned inner = Inner { name: make_string() }
        \\    let owned a = Inner { name: inner.name }
        \\    let owned b = Outer { inner: inner }
        \\    let owned c = Maybe { name: source }
        \\    let owned d = Lists { items: make_list() }
        \\}
    ,
        \\t.cell:11:33: error: cannot store inner.name in owned field 'name': moving a place into an aggregate is not implemented
        \\t.cell:11:33: note: aggregate ownership transfer is not implemented; construct a fresh field value instead
        \\t.cell:12:34: error: cannot store inner in owned field 'inner': moving a place into an aggregate is not implemented
        \\t.cell:12:34: note: aggregate ownership transfer is not implemented; construct a fresh field value instead
        \\t.cell:13:33: error: cannot store source in owned field 'name': moving a place into an aggregate is not implemented
        \\t.cell:13:33: note: aggregate ownership transfer is not implemented; construct a fresh field value instead
        \\
    );
}

test "owning field guard fails closed for unknown and cyclic destination shapes" {
    try expectDiagnostics(
        \\pub struct Mystery { owned value: Missing }
        \\pub struct Node { owned next: Node }
        \\pub fn make_node() -> Node;
        \\pub fn main() {
        \\    let owned a = Mystery { value: 1 }
        \\    let owned b = Node { next: make_node() }
        \\}
    ,
        \\t.cell:5:36: error: cannot store a value of unresolved resource shape in owned field 'value': the destination field's resource shape cannot be resolved
        \\t.cell:5:36: note: aggregate ownership transfer is not implemented; construct a fresh field value instead
        \\t.cell:6:32: error: cannot store a value of unresolved resource shape in owned field 'next': the destination field's resource shape cannot be resolved
        \\t.cell:6:32: note: aggregate ownership transfer is not implemented; construct a fresh field value instead
        \\
    );
}

// ── moved_paths: the field-level record codegen's partial drop reads ─────

/// Borrow-check `src` and hand back the checker, so a test can query the
/// permanent move records the way codegen does after `checkModule`.
pub fn checkedFor(gpa: std.mem.Allocator, src: []const u8) !Checker {
    var lex = lexer.Lexer.init(src, "t.cell");
    const tokens = try lex.tokenizeAll(gpa);
    var p = parser.Parser.init(gpa, tokens.items, "t.cell");
    const module = try gpa.create(ast.Module);
    module.* = try p.parseModule();
    var checker: Checker = .init(gpa, "t.cell", null);
    errdefer checker.deinit();
    try checker.checkModule(module);
    return checker;
}

/// The id borrowck gave the (single) binding named `name`, found through the
/// same permanent name table codegen uses to cross-check its numbering.
pub fn idNamed(checker: *const Checker, name: []const u8) !u32 {
    var found: ?u32 = null;
    var it = checker.names.iterator();
    while (it.next()) |kv| {
        if (std.mem.eql(u8, kv.value_ptr.*, name)) {
            if (found != null) return error.AmbiguousName;
            found = kv.key_ptr.*;
        }
    }
    return found orelse error.NoSuchBinding;
}

pub const partial_move_src =
    \\pub struct Pair {
    \\    owned a: String
    \\    owned b: String
    \\}
    \\pub fn f() {
    \\  let owned p: Pair = Pair { a: "x", b: "y" }
    \\  let owned m: String = p.a
    \\}
;

test "moved_paths: a field move is recorded as that field, not as the whole binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var checker = try checkedFor(arena.allocator(), partial_move_src);
    defer checker.deinit();
    try std.testing.expect(!checker.hasErrors());
    const p = try idNamed(&checker, "p");
    // The binding-level answer is unchanged, which is what every existing
    // caller of `wasMoved` still relies on.
    try std.testing.expect(checker.wasMoved(p));
    try std.testing.expect(!checker.wasWhollyMoved(p));
    try std.testing.expect(checker.fieldWasMoved(p, "a"));
    try std.testing.expect(!checker.fieldWasMoved(p, "b"));
}

test "moved_paths: a whole-binding move is wholly moved and reports no field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var checker = try checkedFor(arena.allocator(),
        \\pub struct Pair {
        \\    owned a: String
        \\    owned b: String
        \\}
        \\pub fn f() {
        \\  let owned p: Pair = Pair { a: "x", b: "y" }
        \\  let owned q: Pair = p
        \\}
    );
    defer checker.deinit();
    const p = try idNamed(&checker, "p");
    try std.testing.expect(checker.wasWhollyMoved(p));
    // `fieldWasMoved` deliberately does not report a whole move; callers
    // check `wasWhollyMoved` first.
    try std.testing.expect(!checker.fieldWasMoved(p, "a"));
    try std.testing.expect(!checker.fieldWasMoved(p, "b"));
    const q = try idNamed(&checker, "q");
    try std.testing.expect(!checker.wasMoved(q));
}

test "moved_paths: a nested field path counts against its top-level field only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var checker = try checkedFor(arena.allocator(),
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
    defer checker.deinit();
    const p = try idNamed(&checker, "p");
    try std.testing.expect(!checker.wasWhollyMoved(p));
    try std.testing.expect(checker.fieldWasMoved(p, "inner"));
    try std.testing.expect(!checker.fieldWasMovedWhole(p, "inner"));
    try std.testing.expect(checker.fieldWasMovedWhole(p, "inner.a"));
    try std.testing.expect(!checker.fieldWasMovedWhole(p, "inner.b"));
    try std.testing.expect(checker.fieldWasMoved(p, "inner.a"));
    try std.testing.expect(!checker.fieldWasMoved(p, "inner.b"));
    try std.testing.expect(!checker.fieldWasMoved(p, "tag"));
    try std.testing.expect(!checker.fieldWasMovedWhole(p, "tag"));
    // A prefix that is not a whole path segment must not match: `in` is not
    // `inner`.
    try std.testing.expect(!checker.fieldWasMoved(p, "in"));
}

test "moved_paths: a partial move is still ACCEPTED, with no diagnostic" {
    // The fix lives entirely in what borrowck records, never in what it
    // refuses: reading the rest of a partly moved record stays legal.
    try expectAccepted(
        \\pub struct Pair {
        \\    owned a: String
        \\    owned b: String
        \\}
        \\pub fn view(shared s: String) -> Int;
        \\pub fn f() -> Int {
        \\  let owned p: Pair = Pair { a: "x", b: "y" }
        \\  let owned m: String = p.a
        \\  return view(shared p.b)
        \\}
    );
}

test "moved_paths: a field revived after it was moved is no longer fieldWasMoved" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var checker = try checkedFor(arena.allocator(),
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
    defer checker.deinit();
    try std.testing.expect(!checker.hasErrors());
    const p = try idNamed(&checker, "p");
    try std.testing.expect(checker.wasMoved(p));
    try std.testing.expect(!checker.wasWhollyMoved(p));
    try std.testing.expect(!checker.fieldWasMoved(p, "a"));
    try std.testing.expect(!checker.fieldWasMovedWhole(p, "a"));
    try std.testing.expect(!checker.fieldWasMoved(p, "b"));
}

test "moved_paths: a field moved and never revived stays fieldWasMoved" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var checker = try checkedFor(arena.allocator(),
        \\pub struct Pair {
        \\    owned a: String
        \\    owned b: String
        \\}
        \\pub fn take(owned s: String) { }
        \\pub fn f() {
        \\  let owned p: Pair = Pair { a: "x", b: "y" }
        \\  take(owned p.a)
        \\}
    );
    defer checker.deinit();
    try std.testing.expect(!checker.hasErrors());
    const p = try idNamed(&checker, "p");
    try std.testing.expect(checker.fieldWasMoved(p, "a"));
    try std.testing.expect(checker.fieldWasMovedWhole(p, "a"));
    try std.testing.expect(!checker.fieldWasMoved(p, "b"));
}

test "moved_paths: reviving one field does not clear a moved sibling" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var checker = try checkedFor(arena.allocator(),
        \\pub struct Pair {
        \\    owned a: String
        \\    owned b: String
        \\}
        \\pub fn take(owned s: String) { }
        \\pub fn f() {
        \\  var owned p: Pair = Pair { a: "x", b: "y" }
        \\  take(owned p.a)
        \\  take(owned p.b)
        \\  p.a = "c"
        \\}
    );
    defer checker.deinit();
    try std.testing.expect(!checker.hasErrors());
    const p = try idNamed(&checker, "p");
    try std.testing.expect(!checker.fieldWasMoved(p, "a"));
    try std.testing.expect(checker.fieldWasMoved(p, "b"));
    try std.testing.expect(!checker.wasWhollyMoved(p));
}

test "Some reads its operand and a wrap-pattern binding is a copy" {
    try expectAccepted(
        \\pub fn view(copy n: Int) -> Int;
        \\pub fn f(copy n: Int) -> Int {
        \\    let o: Int? = Some(n)
        \\    let m = view(n)
        \\    let copy a = match o { Some(x) => x + m, None => m }
        \\    return a
        \\}
    );
    try expectRejectedWith(
        \\pub fn f(copy o: Int?) -> Int {
        \\    let copy a = match o {
        \\        Some(x) => { x = 1 x },
        \\        None => 0,
        \\    }
        \\    return a
        \\}
    , "cannot assign to immutable binding 'x'");
    try expectAccepted(
        \\pub fn f(copy o: Int?) -> Int {
        \\    return match o { Some(x) => x, None => 0 }
        \\}
    );
}
