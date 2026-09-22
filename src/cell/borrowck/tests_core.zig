//! Borrow checker tests: R1 to R8, NLL, and place identity.

const std = @import("std");
const bk_model = @import("model.zig");
const bk_tests_support = @import("tests_support.zig");
const pathPrefix = bk_model.pathPrefix;
const Harness = bk_tests_support.Harness;
const expectDiagnostics = bk_tests_support.expectDiagnostics;
const expectAccepted = bk_tests_support.expectAccepted;
const prelude = bk_tests_support.prelude;

test "R1 and R2: a bare argument to an owned parameter moves, and the next use is an error" {
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    take(buf)
        \\    take(buf)
        \\}
    ,
        \\t.cell:12:10: error: use of 'buf' after it was moved
        \\t.cell:11:10: note: 'buf' was moved here by the call to 'take'
        \\
    );
}

test "R2 accepts a move that is never followed by a use" {
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    read(buf)
        \\    take(buf)
        \\}
    );
}

test "R2: a move through a field kills the whole binding for later reads" {
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    take(buf.data)
        \\    read(buf)
        \\}
    ,
        \\t.cell:12:10: error: use of 'buf.data' after it was moved
        \\t.cell:11:10: note: 'buf.data' was moved here by the call to 'take'
        \\
    );
}

test "R2: a return moves the returned place" {
    try expectDiagnostics(prelude ++
        \\pub fn consume(owned b: Buffer) -> Buffer {
        \\    take(b)
        \\    return b
        \\}
    ,
        \\t.cell:11:12: error: use of 'b' after it was moved
        \\t.cell:10:10: note: 'b' was moved here by the call to 'take'
        \\
    );
}

test "indexing reads the base so a move then a[i] is use after move" {
    try expectDiagnostics(
        \\pub fn take(owned s: String) { }
        \\pub fn main() {
        \\    let owned s = "ab"
        \\    take(s)
        \\    let copy b = s[0]
        \\}
    ,
        \\t.cell:5:18: error: use of 's' after it was moved
        \\t.cell:4:10: note: 's' was moved here by the call to 'take'
        \\
    );
}

test "R3: a whole exclusive borrow cannot be moved out of" {
    try expectDiagnostics(prelude ++
        \\pub fn steal(exclusive b: Buffer) -> Buffer {
        \\    return b
        \\}
    ,
        \\t.cell:10:12: error: cannot move out of 'b': it is an exclusive borrow, not an owner
        \\
    );
}

test "R3: an owned field of a shared borrow cannot be moved out of either" {
    try expectDiagnostics(prelude ++
        \\pub fn peek(shared b: Buffer) -> [Byte] {
        \\    return b.data
        \\}
    ,
        \\t.cell:10:12: error: cannot move out of 'b.data': it is a shared borrow, not an owner
        \\
    );
}

test "R3 accepts returning a copy field of a shared borrow" {
    // This is `read_only` from examples/ownership.cell. It is legal only
    // because `Buffer.len` is declared `copy`, which R12 exempts from R3.
    try expectAccepted(prelude ++
        \\pub fn read_only(shared b: Buffer) -> Int {
        \\    return b.len
        \\}
    );
}

test "R18: an owned binding cannot be initialized from a sigil borrow" {
    // The live double free this rule closes, in its smallest form. Measured
    // at `b61a107` BEFORE the rule existed: `cell check` exit 0, the emitted C
    // carrying TWO `cell_slice_free` calls for one buffer, and running it
    // under AddressSanitizer `attempting double-free` at exit 134.
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    var owned buf = Buffer { data: [], len: 0 }
        \\    let owned e = &buf
        \\    grow(exclusive buf, 1)
        \\}
    ,
        \\t.cell:11:19: error: cannot bind a borrow of 'buf' to the 'owned' binding 'e': a borrow does not confer ownership
        \\t.cell:11:19: note: R18: an 'owned' binding is destroyed at the end of its scope (R16), so binding one to a borrow frees the lender's value twice; write 'let shared e' or 'let exclusive e' to hold the borrow
        \\
    );
}

test "R18: every borrow spelling reaches the same verdict, including the two that did not crash" {
    // THE POINT OF THE RULE. `examples/borrows.cell` states that the sigil and
    // keyword spellings are the same construct, and before this rule they were
    // not treated as one: `&buf` and `&mut buf` were exit-134 double frees
    // while `shared buf` and `exclusive buf` silently MOVED the lender under a
    // written `shared` prefix and exited 0. A fix that left them split would
    // be wrong even where the split is safe-versus-safe, so the table asserts
    // one verdict rather than two.
    //
    // The binding prefix is varied too, because R1 makes an omitted annotation
    // `owned`: `let e = &buf` is the same program as `let owned e = &buf` and
    // was the same crash.
    const prefixes = [_][]const u8{ "let owned", "let", "var owned", "var" };
    const spellings = [_][]const u8{
        "&buf",
        "&mut buf",
        "&var buf",
        "&exclusive buf",
        "shared buf",
        "exclusive buf",
        "shared &buf",
        "exclusive &buf",
    };
    for (prefixes) |prefix| {
        for (spellings) |spelling| {
            var src_buf: [1024]u8 = undefined;
            const src = try std.fmt.bufPrint(&src_buf,
                \\{s}pub fn main() {{
                \\    var owned buf = Buffer {{ data: [], len: 0 }}
                \\    {s} e = {s}
                \\}}
            , .{ prelude, prefix, spelling });

            var h: Harness = .init();
            defer h.deinit();
            var out_buf: [4096]u8 = undefined;
            const out = try h.run(src, &out_buf, false);
            if (std.mem.indexOf(u8, out, "a borrow does not confer ownership") == null) {
                std.debug.print(
                    "\n`{s} e = {s}` was NOT refused by R18. Diagnostics:\n{s}\n",
                    .{ prefix, spelling, out },
                );
                return error.SpellingNotRefused;
            }
        }
    }
}

test "R18 refuses a borrow reached through a branch and a callee that returns one" {
    // `borrowSource` descends into both arms of an `if` and both sides of a
    // `match`, and reads a callee's declared return type. Neither is a
    // spelling anyone would think to enumerate, and both are refused because
    // the question is asked of the classifier rather than of a list.
    //
    // Two things this test pins that are not the rule itself. The error is
    // reported at the BRANCH that supplies the borrow (column 31, the `&buf`
    // inside the `then` arm) rather than at the `if`, because the diagnostic
    // carries the classified sub-expression's span. And R8 fires first on the
    // declaration `-> shared Buffer`: a function returning a borrow cannot be
    // declared in this language at all, so `borrowSource`'s call arm is
    // reachable only in a module R8 has already refused. That is stated here
    // rather than left to look like coverage the rule does not have.
    try expectDiagnostics(prelude ++
        \\pub fn lend(shared b: Buffer) -> shared Buffer;
        \\pub fn main() {
        \\    var copy c = 0
        \\    var owned buf = Buffer { data: [], len: 0 }
        \\    let owned e = if c == 0 { &buf } else { &buf }
        \\    let owned f = lend(shared buf)
        \\}
    ,
        \\t.cell:9:1: error: cannot return a shared borrow: Cell has no lifetime annotations, so the borrow cannot be proven to outlive the call
        \\t.cell:9:1: note: return an 'owned' or 'arc' value instead
        \\t.cell:13:31: error: cannot bind a borrow of 'buf' to the 'owned' binding 'e': a borrow does not confer ownership
        \\t.cell:13:31: note: R18: an 'owned' binding is destroyed at the end of its scope (R16), so binding one to a borrow frees the lender's value twice; write 'let shared e' or 'let exclusive e' to hold the borrow
        \\t.cell:14:19: error: cannot bind the borrow returned by 'lend' to the 'owned' binding 'f': a borrow does not confer ownership
        \\t.cell:14:19: note: R18: an 'owned' binding is destroyed at the end of its scope (R16), so binding one to a borrow frees the lender's value twice; write 'let shared f' or 'let exclusive f' to hold the borrow
        \\
    );
}

test "R18 leaves an owned binding of a value alone" {
    // The neighbours the rule must not eat, and the reason it is asked only of
    // an `owned` binding whose initializer classifies as a BORROW: a literal,
    // a fresh aggregate, a call returning a value, and a move of an owned
    // place are all still legal, and so are the `shared` and `exclusive`
    // bindings that hold a borrow properly.
    try expectAccepted(prelude ++
        \\pub fn make() -> Buffer;
        \\pub fn main() {
        \\    let owned a = Buffer { data: [], len: 0 }
        \\    let owned b = make()
        \\    let owned c = b
        \\    var owned buf = Buffer { data: [], len: 0 }
        \\    let shared s = &buf
        \\    let n = read(shared buf)
        \\    let m = s.len
        \\}
    );
}

test "R3a: assigning a fresh value revives a moved-from var" {
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    var owned buf = Buffer { data: [], len: 0 }
        \\    take(buf)
        \\    buf = Buffer { data: [], len: 0 }
        \\    take(buf)
        \\}
    );
}

test "R3a and R14: reviving a let binding is an immutable assignment, not a revival" {
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    take(buf)
        \\    buf = Buffer { data: [], len: 0 }
        \\    take(buf)
        \\}
    ,
        \\t.cell:12:5: error: cannot assign to immutable binding 'buf'
        \\t.cell:10:5: note: 'buf' is declared immutable here
        \\t.cell:13:10: error: use of 'buf' after it was moved
        \\t.cell:11:10: note: 'buf' was moved here by the call to 'take'
        \\
    );
}

test "R14: assignment to an immutable binding names it and points at the let" {
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let copy x = 1
        \\    x = 2
        \\}
    ,
        \\t.cell:11:5: error: cannot assign to immutable binding 'x'
        \\t.cell:10:5: note: 'x' is declared immutable here
        \\
    );
}

test "R14: a field write through an exclusive parameter is allowed" {
    // examples/ownership.cell's `grow` body. The old checker accepted this by
    // failing to look up the joined path at all; here the lookup succeeds and
    // the exclusive borrow is what grants the write.
    try expectAccepted(prelude ++
        \\pub fn widen(exclusive buf: Buffer, shared extra: Int) {
        \\    let copy new_len = buf.len + extra
        \\    buf.len = new_len
        \\}
    );
}

test "R14: a field write through an immutable let is rejected" {
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    buf.len = 3
        \\}
    ,
        \\t.cell:11:5: error: cannot assign to immutable binding 'buf'
        \\t.cell:10:5: note: 'buf' is declared immutable here
        \\
    );
}

test "R15: an ampersand argument whose mode differs from the parameter is rejected" {
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    take(&buf)
        \\}
    ,
        \\t.cell:11:10: error: 'take' expects parameter 'b' as 'owned', but the argument is passed as 'shared'
        \\
    );
}

test "R15: a keyword-prefixed ampersand argument whose mode differs is still rejected" {
    // Grammar is `primary = [ownership] unary`, so `shared &buf` is
    // `.annotated` wrapping `&buf`. The inner sigil is still R15 explicit
    // mode; peeling `.annotated` must not drop it.
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    take(shared &buf)
        \\}
    ,
        \\t.cell:11:10: error: 'take' expects parameter 'b' as 'owned', but the argument is passed as 'shared'
        \\
    );
}

test "R15: an ampersand argument matching the parameter is accepted" {
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    grow(&mut buf, 16)
        \\    read(&buf)
        \\}
    );
}

test "R15: a keyword argument whose mode differs from the parameter is rejected" {
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    take(shared buf)
        \\}
    ,
        \\t.cell:11:10: error: 'take' expects parameter 'b' as 'owned', but the argument is passed as 'shared'
        \\
    );
}

test "R15: a keyword argument matching the parameter is accepted" {
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    grow(exclusive buf, 16)
        \\    take(owned buf)
        \\}
    );
}

test "R15: omitting the call-site prefix infers from the parameter" {
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    take(buf)
        \\}
    );
}

test "R4: any number of shared borrows may coexist" {
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let shared a = buf
        \\    let shared b = buf
        \\    read(&buf)
        \\}
    );
}

test "R5: a shared borrow while an exclusive one is live is rejected" {
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let exclusive e = &mut buf
        \\    read(&buf)
        \\    use_it(e)
        \\}
    ,
        \\t.cell:12:11: error: cannot borrow 'buf' as shared: it is already borrowed as exclusive
        \\t.cell:11:28: note: the exclusive borrow starts here and lasts to the end of this block
        \\
    );
}

test "R5: an exclusive borrow while a shared one is live is rejected" {
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let shared s = buf
        \\    grow(&mut buf, 1)
        \\    read_shared(s)
        \\}
    ,
        \\t.cell:12:15: error: cannot borrow 'buf' as exclusive: it is already borrowed as shared
        \\t.cell:11:20: note: the shared borrow starts here and lasts to the end of this block
        \\
    );
}

test "R5: reading the whole owner through a live exclusive borrow is rejected" {
    // R5's own example wording, naming the place as a whole. `println` has no
    // signature here, so the argument is a plain read rather than a move.
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let exclusive e = &mut buf
        \\    println(buf)
        \\    use_it(e)
        \\}
    ,
        \\t.cell:12:13: error: cannot use 'buf' while it is exclusively borrowed
        \\t.cell:11:28: note: the exclusive borrow starts here and lasts to the end of this block
        \\
    );
}

test "R5: reading a field of the owner through a live exclusive borrow is rejected" {
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let exclusive e = &mut buf
        \\    let copy n = buf.len
        \\    use_it(e)
        \\}
    ,
        \\t.cell:12:18: error: cannot use 'buf.len' while it is exclusively borrowed
        \\t.cell:11:28: note: the exclusive borrow starts here and lasts to the end of this block
        \\
    );
}

test "NLL slice 1: a named loan whose holder is mentioned nowhere again is accepted" {
    // This test was a REJECTION carrying a note that said NLL would accept it.
    // It is now that acceptance. `e` is mentioned nowhere after its own `let`,
    // so the loan is dead by the time `read(&buf)` wants a shared borrow.
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let exclusive e = &mut buf
        \\    read(&buf)
        \\}
    );

    // MUTATION 1, the forward half. One later use of the holder and the same
    // program is rejected again. Without this the acceptance would pass even
    // if the predicate never read the forward scan at all.
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let exclusive e = &mut buf
        \\    read(&buf)
        \\    use_it(e)
        \\}
    ,
        \\t.cell:12:11: error: cannot borrow 'buf' as shared: it is already borrowed as exclusive
        \\t.cell:11:28: note: the exclusive borrow starts here and lasts to the end of this block
        \\
    );

    // MUTATION 2, the window half. One earlier mention in a value position,
    // which copies the loan into a holder used later, and it is rejected
    // again. `f` stays `ineligible` rather than being followed: slice 3 is
    // deliberately absent.
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let exclusive e = &mut buf
        \\    let exclusive f = e
        \\    read(&buf)
        \\    use_it(f)
        \\}
    ,
        \\t.cell:13:11: error: cannot borrow 'buf' as shared: it is already borrowed as exclusive
        \\t.cell:11:28: note: the exclusive borrow starts here and lasts to the end of this block
        \\
    );
}

test "NLL slice 2: a holder passed as a direct call argument is dead after that call" {
    // The shape users actually hit. The mention of `e` between the loan and
    // the conflict is a direct call argument, which R8 proves cannot propagate
    // the reference anywhere, so the window scan lets it through.
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let exclusive e = &mut buf
        \\    grow(exclusive e, shared 1)
        \\    read(&buf)
        \\}
    );

    // MUTATION 1, the forward half.
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let exclusive e = &mut buf
        \\    grow(exclusive e, shared 1)
        \\    read(&buf)
        \\    use_it(e)
        \\}
    ,
        \\t.cell:13:11: error: cannot borrow 'buf' as shared: it is already borrowed as exclusive
        \\t.cell:11:28: note: the exclusive borrow starts here and lasts to the end of this block
        \\
    );

    // MUTATION 2, the window half: the SAME mention of `e`, moved out of the
    // whitelisted position into a `let` initializer. The whitelist is what
    // separates these two programs, and nothing else about them differs.
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let exclusive e = &mut buf
        \\    let copy n = use_it(e) + e.len
        \\    read(&buf)
        \\}
    ,
        \\t.cell:13:11: error: cannot borrow 'buf' as shared: it is already borrowed as exclusive
        \\t.cell:11:28: note: the exclusive borrow starts here and lasts to the end of this block
        \\
    );
}

test "NLL: the acceptance reaches all four conflict sites, including assignment" {
    // `checkAssign` was the one conflict site that never consulted the NLL
    // predicate. Three sites enumerated, a fourth missed. Each of these four
    // programs is rejected by the lexical model and accepted here, and each
    // exercises a different site: createLoan, readPlace, movePlace, and the
    // assignment.
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let exclusive e = &mut buf
        \\    read(&buf)
        \\}
    );
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let exclusive e = &mut buf
        \\    let copy n = buf.len
        \\}
    );
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let exclusive e = &mut buf
        \\    take(buf)
        \\}
    );
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    var owned buf = Buffer { data: [], len: 0 }
        \\    let exclusive e = &mut buf
        \\    buf.len = 1
        \\}
    );
}

test "NLL: a use of the holder on the far side of a while back edge keeps the loan live" {
    // The forward scan counts the ENCLOSING statement in full and recurses
    // into a `while`'s condition and body, so a use that only a second
    // iteration reaches still reads as "used". Without that this would be
    // accepted and the second iteration would alias.
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let exclusive e = &mut buf
        \\    while read(&buf) > 0 {
        \\        let copy n = use_it(e)
        \\    }
        \\}
    ,
        \\t.cell:12:17: error: cannot borrow 'buf' as shared: it is already borrowed as exclusive
        \\t.cell:11:28: note: the exclusive borrow starts here and lasts to the end of this block
        \\
    );
}

test "NLL soundness rests on R8: a borrow still cannot escape by return or struct field" {
    // NAMED FOR THE INVARIANT ON PURPOSE. The call-argument whitelist in
    // `argPropagatesName` is the entire reason slice 2 can accept anything,
    // and it is sound only because a callee has nowhere to put what it is
    // handed: R8 refuses a returned borrow and a borrow in a struct field,
    // and Cell has no lifetime parameters, no references inside aggregates
    // and no closures. If lifetime parameters ever land, this test fails, and
    // when it does the NLL acceptance must be revisited with it rather than
    // this test being updated to match the new behaviour.
    try expectDiagnostics(prelude ++
        \\pub fn peek(shared b: Buffer) -> shared Buffer {
        \\    return b
        \\}
    ,
        \\t.cell:10:12: error: cannot return a shared borrow: Cell has no lifetime annotations, so the borrow cannot be proven to outlive the call
        \\t.cell:10:12: note: return an 'owned' or 'arc' value instead
        \\
    );
    try expectDiagnostics(
        \\pub struct View {
        \\    exclusive buf: Buffer
        \\}
    ,
        // "a exclusive" is the message `checkStructFields` actually prints:
        // it interpolates `LoanKind.word()` with a fixed article. Pinned as
        // it is rather than fixed here, so this change touches no diagnostic
        // text it does not own.
        \\t.cell:1:1: error: cannot store a exclusive borrow in field 'buf': Cell has no lifetime annotations, so the borrow cannot be proven to outlive the value
        \\t.cell:1:1: note: store an 'owned' or 'arc' value instead
        \\
    );
}

test "0.3: a holder that was copied into a second borrow behind the conflict is not dead" {
    // The forward scan alone said "'e' is never used again" here and printed
    // a note claiming NLL would accept this. NLL REJECTS it: `f` aliases `buf`
    // through `e`, and `f` is used afterwards. `nameUsedFrom` starts at the
    // conflicting statement and can never see the `let exclusive f = e`
    // BEHIND it, which is what the window scan is for.
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let exclusive e = &mut buf
        \\    let exclusive f = e
        \\    read(&buf)
        \\    grow(exclusive f, shared 1)
        \\}
    ,
        \\t.cell:13:11: error: cannot borrow 'buf' as shared: it is already borrowed as exclusive
        \\t.cell:11:28: note: the exclusive borrow starts here and lasts to the end of this block
        \\
    );
}

test "0.3: a holder used inside a match GUARD is not dead" {
    // A match arm has two expression positions and the forward scan walked
    // one. `exprUsesName` recursed into `arm.body` and not `arm.guard`, so
    // this printed the NLL note, and under the acceptance that predicate now
    // gates it would have ended a loan the guard still holds.
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let exclusive e = &mut buf
        \\    read(&buf)
        \\    let copy m = match 1 { _ if use_it(shared e) > 0 => 1, _ => 2 }
        \\}
    ,
        \\t.cell:12:11: error: cannot borrow 'buf' as shared: it is already borrowed as exclusive
        \\t.cell:11:28: note: the exclusive borrow starts here and lasts to the end of this block
        \\
    );
}

test "0.3 exception 1: a borrow created as a call argument ends with its statement" {
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    read(&buf)
        \\    grow(&mut buf, 16)
        \\    take(buf)
        \\}
    );
}

test "0.3 exception 2: a borrow created in a condition ends when the if finishes" {
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    if read(&buf) > 0 {
        \\        let copy z = 1
        \\    }
        \\    grow(&mut buf, 16)
        \\}
    );
}

test "R6: two disjoint field borrows coexist" {
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let exclusive d = &mut buf.data
        \\    let exclusive l = &mut buf.len
        \\    use_it(d)
        \\}
    );
}

test "R6: moving the owner while one of its fields is borrowed is rejected" {
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let exclusive d = &mut buf.data
        \\    take(buf)
        \\    use_it(d)
        \\}
    ,
        \\t.cell:12:10: error: cannot move 'buf': its field 'buf.data' is borrowed
        \\t.cell:11:28: note: the exclusive borrow starts here and lasts to the end of this block
        \\
    );
}

test "R6: borrowing a field while the whole place is borrowed exclusively is rejected" {
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let exclusive e = &mut buf
        \\    read(&buf.len)
        \\    use_it(e)
        \\}
    ,
        \\t.cell:12:11: error: cannot borrow 'buf.len' as shared: it is already borrowed as exclusive
        \\t.cell:11:28: note: the exclusive borrow starts here and lasts to the end of this block
        \\
    );
}

test "places are keyed by binding identity, so sibling blocks do not share a move" {
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    {
        \\        let owned a = Buffer { data: [], len: 0 }
        \\        take(a)
        \\    }
        \\    {
        \\        let owned a = Buffer { data: [], len: 0 }
        \\        take(a)
        \\    }
        \\}
    );
}

test "shadowing in one block introduces a new place rather than reviving the old one" {
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    let owned a = Buffer { data: [], len: 0 }
        \\    take(a)
        \\    let owned a = Buffer { data: [], len: 0 }
        \\    take(a)
        \\}
    );
}

test "a parameter of one function is not visible in the next" {
    // OWNERSHIP.md 0.4: typecheck.zig's flat symbol table leaks parameters
    // across functions. This checker's per-function scope does not.
    try expectAccepted(prelude ++
        \\pub fn first(owned b: Buffer) { take(b) }
        \\pub fn second() -> Int { return 1 }
    );
}

test "a move inside one branch of an if kills the place after the if" {
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    if 1 > 0 {
        \\        take(buf)
        \\    }
        \\    read(&buf)
        \\}
    ,
        \\t.cell:14:11: error: use of 'buf' after it was moved
        \\t.cell:12:14: note: 'buf' was moved here by the call to 'take'
        \\
    );
}

test "0.3 exception 2: a condition's borrow is still live inside the branches" {
    // The exception narrows a condition borrow to the end of the `if`, not to
    // the end of the condition, so the branch bodies are inside it. This is
    // the checker's conservatism showing: NLL would end the loan at the
    // comparison. There is no named holder to point at, so no NLL note.
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    if read(&buf) > 0 {
        \\        take(buf)
        \\    }
        \\}
    ,
        \\t.cell:12:14: error: cannot move 'buf' while it is borrowed
        \\t.cell:11:14: note: the shared borrow starts here and lasts until this statement completes
        \\
    );
}

test "a revival inside one branch only is rejected conservatively" {
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    var owned buf = Buffer { data: [], len: 0 }
        \\    take(buf)
        \\    if 1 > 0 {
        \\        buf = Buffer { data: [], len: 0 }
        \\    }
        \\    read(&buf)
        \\}
    ,
        \\t.cell:15:11: error: use of 'buf' after it was moved
        \\t.cell:11:10: note: 'buf' was moved here by the call to 'take'
        \\
    );
}

test "an unknown callee's argument is read rather than moved" {
    // Without a signature there is no parameter mode to infer from, so
    // inventing a move would reject every call to a builtin.
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    println(buf)
        \\    take(buf)
        \\}
    );
}

test "examples/ownership.cell is accepted verbatim" {
    // Inlined because @embedFile cannot reach outside the module root and the
    // build's `examples` step only checks hello.cell. The text below is the
    // code of examples/ownership.cell with its comments removed.
    try expectAccepted(
        \\pub struct Buffer {
        \\    owned data: [Byte]
        \\    copy len: Int
        \\}
        \\pub fn grow(exclusive buf: Buffer, shared extra: Int) {
        \\    let copy new_len = buf.len + extra
        \\    buf.len = new_len
        \\}
        \\pub fn share_name(arc name: String) -> arc String {
        \\    return name
        \\}
        \\pub fn take(owned b: Buffer) {
        \\}
        \\pub fn read_only(shared b: Buffer) -> Int {
        \\    return b.len
        \\}
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    grow(exclusive buf, shared 16)
        \\    let copy n = read_only(shared buf)
        \\    take(owned buf)
        \\}
    );
}

test "with a source buffer the caret lands on the offending column" {
    var h: Harness = .init();
    defer h.deinit();
    const src =
        \\pub fn take(owned b: Buffer) { }
        \\pub fn main() {
        \\    let owned buf = 0
        \\    take(buf)
        \\    take(buf)
        \\}
    ;
    var buf: [1024]u8 = undefined;
    const out = try h.run(src, &buf, true);
    try std.testing.expectEqualStrings(
        \\t.cell:5:10: error: use of 'buf' after it was moved
        \\        take(buf)
        \\             ^~~
        \\t.cell:4:10: note: 'buf' was moved here by the call to 'take'
        \\        take(buf)
        \\             ^~~
        \\
    , out);
}

test "pathPrefix compares whole segments, not bytes" {
    try std.testing.expect(pathPrefix("", "len"));
    try std.testing.expect(pathPrefix("len", "len"));
    try std.testing.expect(pathPrefix("a", "a.b"));
    try std.testing.expect(!pathPrefix("a", "ab"));
    try std.testing.expect(!pathPrefix("a.b", "a"));
    try std.testing.expect(!pathPrefix("le", "len"));
}

test "R8: a function may not return a shared borrow" {
    try expectDiagnostics(prelude ++
        \\pub fn peek(shared b: Buffer) -> shared Buffer {
        \\    return b
        \\}
    ,
        \\t.cell:10:12: error: cannot return a shared borrow: Cell has no lifetime annotations, so the borrow cannot be proven to outlive the call
        \\t.cell:10:12: note: return an 'owned' or 'arc' value instead
        \\
    );
}

test "R8: a function may not return an exclusive borrow" {
    try expectDiagnostics(prelude ++
        \\pub fn leak(exclusive b: Buffer) -> exclusive Buffer {
        \\    return b
        \\}
    ,
        \\t.cell:10:12: error: cannot return an exclusive borrow: Cell has no lifetime annotations, so the borrow cannot be proven to outlive the call
        \\t.cell:10:12: note: return an 'owned' or 'arc' value instead
        \\
    );
}

test "R8: a bodyless shared-borrow return still errors at the function" {
    try expectDiagnostics(prelude ++
        \\pub fn peek(shared b: Buffer) -> shared Buffer;
    ,
        \\t.cell:9:1: error: cannot return a shared borrow: Cell has no lifetime annotations, so the borrow cannot be proven to outlive the call
        \\t.cell:9:1: note: return an 'owned' or 'arc' value instead
        \\
    );
}

test "R8: a struct field may not store a shared borrow" {
    try expectDiagnostics(
        \\pub struct View {
        \\    shared buf: Buffer
        \\}
    ,
        \\t.cell:1:1: error: cannot store a shared borrow in field 'buf': Cell has no lifetime annotations, so the borrow cannot be proven to outlive the value
        \\t.cell:1:1: note: store an 'owned' or 'arc' value instead
        \\
    );
}
