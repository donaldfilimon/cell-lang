//! Borrow checker tests: R2.a, block tails, R4, R7's write clause, and loop exit liveness.

const std = @import("std");
const bk_tests_support = @import("tests_support.zig");
const LiveHarness = bk_tests_support.LiveHarness;
const firstReturnIn = bk_tests_support.firstReturnIn;
const expectDiagnostics = bk_tests_support.expectDiagnostics;
const expectAccepted = bk_tests_support.expectAccepted;
const expectRejectedWith = bk_tests_support.expectRejectedWith;
const prelude = bk_tests_support.prelude;

test "R2.a: a move inside a loop is rejected, because iteration 2 uses it dead" {
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    var owned buf = Buffer { data: [], len: 0 }
        \\    var i = 0
        \\    while i < 3 {
        \\        take(owned buf)
        \\        i = i + 1
        \\    }
        \\}
    ,
        \\t.cell:13:20: error: 'buf' is moved inside a loop, so the next iteration would use it after the move
        \\t.cell:12:5: note: 'buf' is declared outside this loop; assign to it before the end of the body to revive it
        \\
    );
}

test "R2.a: reassigning before the body ends revives the place and the loop is legal" {
    // R3a already removes a place from the dead list on assignment, so R2.a
    // gets revival for free rather than needing a second rule.
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    var owned buf = Buffer { data: [], len: 0 }
        \\    var i = 0
        \\    while i < 3 {
        \\        take(owned buf)
        \\        buf = Buffer { data: [], len: 1 }
        \\        i = i + 1
        \\    }
        \\}
    );
}

// ── R2.a at a `continue` (2026-09-16) ───────────────────────────────────────
//
// Each refused program below was accepted before this change and ran as an
// AddressSanitizer double free (exit 134), measured with `cell run` and a
// `cc -fsanitize=address` wrapper.

pub const jump_prelude =
    \\pub fn take(owned s: String) { }
    \\pub fn consume(owned s: String) -> Bool { return false }
    \\
;
// jump_prelude occupies lines 1 and 2, so a test body's first line is 3.

test "R2.a: a continue between a move and its revival is refused" {
    try expectDiagnostics(jump_prelude ++
        \\pub fn f(copy n: Int) {
        \\    var owned v: String = "a"
        \\    var i = 0
        \\    while i < 3 {
        \\        i = i + 1
        \\        take(v)
        \\        if i < n {
        \\            continue
        \\        }
        \\        v = "b"
        \\    }
        \\}
    ,
        \\t.cell:8:14: error: 'v' is moved inside a loop, so the next iteration would use it after the move
        \\t.cell:10:13: note: this 'continue' is reached before 'v' is assigned again
        \\
    );
}

test "R2.a: a continue after the revival is accepted" {
    try expectAccepted(jump_prelude ++
        \\pub fn f(copy n: Int) {
        \\    var owned v: String = "a"
        \\    var i = 0
        \\    while i < 3 {
        \\        i = i + 1
        \\        take(v)
        \\        v = "b"
        \\        if i < n {
        \\            continue
        \\        }
        \\    }
        \\}
    );
}

test "R2.a: a continue in an inner loop is checked against the inner loop" {
    try expectDiagnostics(jump_prelude ++
        \\pub fn f() {
        \\    var owned v: String = "a"
        \\    var i = 0
        \\    while i < 2 {
        \\        i = i + 1
        \\        var j = 0
        \\        while j < 2 {
        \\            j = j + 1
        \\            take(v)
        \\            if j < 2 {
        \\                continue
        \\            }
        \\            v = "b"
        \\        }
        \\    }
        \\}
    ,
        \\t.cell:11:18: error: 'v' is moved inside a loop, so the next iteration would use it after the move
        \\t.cell:13:17: note: this 'continue' is reached before 'v' is assigned again
        \\
    );
}

test "R2.a: a place already moved before the loop does not fire at a continue" {
    // The body is walked from the entry state, so an iteration that restarts
    // with `v` still moved is exactly the state that was checked. The body
    // never reads `v`, so nothing here is a use.
    try expectAccepted(jump_prelude ++
        \\pub fn f(copy n: Int) {
        \\    var owned v: String = "a"
        \\    take(v)
        \\    var i = 0
        \\    while i < 3 {
        \\        i = i + 1
        \\        if i < n {
        \\            continue
        \\        }
        \\    }
        \\}
    );
}

test "R2.a: a move reached by both a continue and the body end is reported once" {
    try expectDiagnostics(jump_prelude ++
        \\pub fn f(copy n: Int) {
        \\    var owned v: String = "a"
        \\    var i = 0
        \\    while i < 3 {
        \\        i = i + 1
        \\        take(v)
        \\        if i < n {
        \\            continue
        \\        }
        \\    }
        \\}
    ,
        \\t.cell:8:14: error: 'v' is moved inside a loop, so the next iteration would use it after the move
        \\t.cell:10:13: note: this 'continue' is reached before 'v' is assigned again
        \\
    );
}

test "R2.a: reviving a place moved before the loop does not hide a body move" {
    // `a = ...` removes `a`'s entry from `dead` with `swapRemove`, which
    // moved `b`'s in-body entry below the index the body-end check used to
    // start from, so `b` was never reported.
    try expectDiagnostics(jump_prelude ++
        \\pub fn f(copy n: Int) {
        \\    var owned a: String = "a"
        \\    var owned b: String = "b"
        \\    take(a)
        \\    var i = 0
        \\    while i < n {
        \\        i = i + 1
        \\        take(b)
        \\        a = "c"
        \\    }
        \\}
    ,
        \\t.cell:10:14: error: 'b' is moved inside a loop, so the next iteration would use it after the move
        \\t.cell:8:5: note: 'b' is declared outside this loop; assign to it before the end of the body to revive it
        \\
    );
}

// ── a `break` or a condition move leaves the place dead after the loop ──────

test "R2: a use after a loop that may have broken while moved is refused" {
    try expectDiagnostics(jump_prelude ++
        \\pub fn f(copy n: Int) {
        \\    var owned v: String = "a"
        \\    var i = 0
        \\    while i < 3 {
        \\        i = i + 1
        \\        take(v)
        \\        if i > n {
        \\            break
        \\        }
        \\        v = "b"
        \\    }
        \\    take(v)
        \\}
    ,
        \\t.cell:14:10: error: use of 'v' after it was moved
        \\t.cell:8:14: note: 'v' was moved here by the call to 'take'
        \\
    );
}

test "R2: a revival after the loop clears the break state" {
    try expectAccepted(jump_prelude ++
        \\pub fn f(copy n: Int) {
        \\    var owned v: String = "a"
        \\    var i = 0
        \\    while i < 3 {
        \\        i = i + 1
        \\        take(v)
        \\        if i > n {
        \\            break
        \\        }
        \\        v = "b"
        \\    }
        \\    v = "c"
        \\    take(v)
        \\}
    );
}

test "R2: a use after a loop whose condition moves the place is refused" {
    try expectDiagnostics(jump_prelude ++
        \\pub fn f() {
        \\    var owned v: String = "a"
        \\    while consume(v) {
        \\        v = "b"
        \\    }
        \\    take(v)
        \\}
    ,
        \\t.cell:8:10: error: use of 'v' after it was moved
        \\t.cell:5:19: note: 'v' was moved here by the call to 'consume'
        \\
    );
}

test "R2.a: a condition move the body revives is accepted" {
    try expectAccepted(jump_prelude ++
        \\pub fn f() {
        \\    var owned v: String = "a"
        \\    while consume(v) {
        \\        v = "b"
        \\    }
        \\}
    );
}

test "R2.a: a condition move the body does not revive is refused" {
    // The second evaluation of the condition reads the moved `v`.
    try expectDiagnostics(jump_prelude ++
        \\pub fn f() {
        \\    var owned v: String = "a"
        \\    var i = 0
        \\    while consume(v) {
        \\        i = i + 1
        \\        if i > 1 {
        \\            break
        \\        }
        \\    }
        \\}
    ,
        \\t.cell:6:19: error: 'v' is moved inside a loop, so the next iteration would use it after the move
        \\t.cell:6:5: note: 'v' is declared outside this loop; assign to it before the end of the body to revive it
        \\
    );
}

test "R2.a: an inner break while moved reaches the outer body end" {
    try expectDiagnostics(jump_prelude ++
        \\pub fn f() {
        \\    var owned v: String = "a"
        \\    var i = 0
        \\    while i < 2 {
        \\        i = i + 1
        \\        var j = 0
        \\        while j < 2 {
        \\            j = j + 1
        \\            take(v)
        \\            if j < 5 {
        \\                break
        \\            }
        \\            v = "b"
        \\        }
        \\    }
        \\}
    ,
        \\t.cell:11:18: error: 'v' is moved inside a loop, so the next iteration would use it after the move
        \\t.cell:6:5: note: 'v' is declared outside this loop; assign to it before the end of the body to revive it
        \\
    );
}

test "R2: a use after a loop that may run zero times sees the move before it" {
    try expectDiagnostics(jump_prelude ++
        \\pub fn f(copy n: Int) {
        \\    var owned v: String = "a"
        \\    take(v)
        \\    var i = 0
        \\    while i < n {
        \\        i = i + 1
        \\        v = "b"
        \\    }
        \\    take(v)
        \\}
    ,
        \\t.cell:11:10: error: use of 'v' after it was moved
        \\t.cell:5:10: note: 'v' was moved here by the call to 'take'
        \\
    );
}

// ── a block in an `owned` let position (2026-09-15) ────────────────────────

pub const block_prelude =
    \\pub fn make() -> String;
    \\pub fn eat(owned s: String) { }
    \\
;
// block_prelude occupies lines 1 through 3 (its trailing empty line counts), so a
// test body's first line is 4.

test "an owned let takes a block whose tail is the block's own owned local" {
    try expectAccepted(block_prelude ++
        \\pub fn main() {
        \\    let owned s = {
        \\        let owned t = make()
        \\        t
        \\    }
        \\}
    );
}

test "the block's statements are checked in a live scope: a tail moved earlier is a use after move" {
    try expectDiagnostics(block_prelude ++
        \\pub fn main() {
        \\    let owned s = {
        \\        let owned t = make()
        \\        eat(owned t)
        \\        t
        \\    }
        \\}
    ,
        \\t.cell:7:9: error: use of 't' after it was moved
        \\t.cell:6:19: note: 't' was moved here by the call to 'eat'
        \\
    );
}

test "a block tail naming an OUTER owned place moves it, because a block is one path" {
    try expectDiagnostics(block_prelude ++
        \\pub fn main() {
        \\    let owned x = make()
        \\    let owned s = { x }
        \\    eat(owned x)
        \\}
    ,
        \\t.cell:6:15: error: use of 'x' after it was moved
        \\t.cell:5:21: note: 'x' was moved here by binding it to 's'
        \\
    );
}

test "a nested block tail resolves through both scopes" {
    try expectAccepted(block_prelude ++
        \\pub fn main() {
        \\    let owned s = {
        \\        let owned t = make()
        \\        {
        \\            let owned u = t
        \\            u
        \\        }
        \\    }
        \\}
    );
}

test "a block tail that is the block's own arc local is R10, naming the local" {
    try expectDiagnostics(block_prelude ++
        \\pub fn main() {
        \\    let owned s = {
        \\        let arc t = "a"
        \\        t
        \\    }
        \\}
    ,
        \\t.cell:6:9: error: cannot bind 'arc' value 't' to 'owned' binding 's': ownership is shared and cannot be made unique
        \\t.cell:6:9: note: an 'owned' holder frees the value, and the 'arc' box would free it again
        \\
    );
}

test "a block tail that borrows the block's own local is R18" {
    try expectDiagnostics(block_prelude ++
        \\pub fn main() {
        \\    let owned s = {
        \\        let owned t = make()
        \\        &t
        \\    }
        \\}
    ,
        \\t.cell:6:9: error: cannot bind a borrow of 't' to the 'owned' binding 's': a borrow does not confer ownership
        \\t.cell:6:9: note: R18: an 'owned' binding is destroyed at the end of its scope (R16), so binding one to a borrow frees the lender's value twice; write 'let shared s' or 'let exclusive s' to hold the borrow
        \\
    );
}

test "a block-local tail at a call argument resolves like the let position" {
    // CHANGED 2026-09-15 (later the same day): refused until the six
    // consumption sites shared `openBlockTail`. The move is proven by the
    // use-after-move test that follows, not by acceptance alone.
    try expectAccepted(block_prelude ++
        \\pub fn main() {
        \\    eat(owned {
        \\        let owned t = make()
        \\        t
        \\    })
        \\}
    );
}

test "a call argument block whose tail is an OUTER place moves it" {
    try expectDiagnostics(block_prelude ++
        \\pub fn main() {
        \\    let owned s1 = make()
        \\    eat(owned { s1 })
        \\    eat(owned s1)
        \\}
    ,
        \\t.cell:6:15: error: use of 's1' after it was moved
        \\t.cell:5:17: note: 's1' was moved here by the call to 'eat'
        \\
    );
}

test "a return block resolves its own owned local" {
    try expectAccepted(block_prelude ++
        \\pub fn mk() -> String {
        \\    return {
        \\        let owned t = make()
        \\        t
        \\    }
        \\}
    );
}

test "a return block whose tail is an OUTER place is accepted after a conditional return" {
    // A use after a conditional return is reached only on the path that did
    // not return, so it is ACCEPTED since 2026-09-17 (this test used to pin
    // the false refusal). The move itself is pinned by the codegen test "a
    // return block whose tail is an outer owned place moves it: no drop of
    // the source".
    try expectAccepted(block_prelude ++
        \\pub fn mk(copy c: Bool) -> String {
        \\    let owned s1 = make()
        \\    if c {
        \\        return { s1 }
        \\    }
        \\    eat(owned s1)
        \\    return make()
        \\}
    );
}

test "an assignment block resolves its own owned local" {
    try expectAccepted(block_prelude ++
        \\pub fn main() {
        \\    var owned s2 = make()
        \\    s2 = {
        \\        let owned t = make()
        \\        t
        \\    }
        \\}
    );
}

test "an assignment block whose tail is an OUTER place moves it" {
    try expectDiagnostics(block_prelude ++
        \\pub fn main() {
        \\    let owned s1 = make()
        \\    var owned s2 = make()
        \\    s2 = { s1 }
        \\    eat(owned s1)
        \\}
    ,
        \\t.cell:7:15: error: use of 's1' after it was moved
        \\t.cell:6:12: note: 's1' was moved here by assigning it to 's2'
        \\
    );
}

test "a resource-bearing struct field resolves a block-local tail and still refuses the place" {
    // The field site resolves the tail like the other five, and then its
    // own rule applies: a PLACE cannot be moved into an aggregate yet (R11,
    // aggregate transfer). The refusal now names `t` instead of blaming
    // the block.
    try expectDiagnostics(block_prelude ++
        \\struct Box { owned s: String }
        \\pub fn main() {
        \\    let owned b = Box { s: {
        \\        let owned t = make()
        \\        t
        \\    } }
        \\}
    ,
        \\t.cell:7:9: error: cannot store t in owned field 's': moving a place into an aggregate is not implemented
        \\t.cell:7:9: note: aggregate ownership transfer is not implemented; construct a fresh field value instead
        \\
    );
}

test "a resource-free struct field reads a block-local tail" {
    try expectAccepted(block_prelude ++
        \\struct Pair { owned n: Int }
        \\pub fn main() {
        \\    let owned p = Pair { n: {
        \\        let copy t = 1
        \\        t
        \\    } }
        \\}
    );
}

test "a list element block resolves its own owned local, and reads it like any element" {
    try expectAccepted(block_prelude ++
        \\pub fn main() {
        \\    let owned xs: [String] = [{
        \\        let owned t = make()
        \\        t
        \\    }]
        \\}
    );
}

test "an owned keyword in front of a block is peeled, so the block still opens" {
    try expectDiagnostics(block_prelude ++
        \\pub fn main() {
        \\    let owned s1 = make()
        \\    let owned s2 = owned { s1 }
        \\    eat(owned s1)
        \\}
    ,
        \\t.cell:6:15: error: use of 's1' after it was moved
        \\t.cell:5:28: note: 's1' was moved here by binding it to 's2'
        \\
    );
}

test "a block-local tail reached through a BRANCH is still refused, and says so" {
    // A block inside an `if` arm is not the consumed expression; the `if`
    // is, and which arm ran is unknown. The classifier's block arm is now
    // reached only this way.
    try expectDiagnostics(block_prelude ++
        \\pub fn main(copy c: Bool) {
        \\    let owned s = if c {
        \\        let owned t = make()
        \\        t
        \\    } else {
        \\        make()
        \\    }
        \\}
    ,
        \\t.cell:6:9: error: cannot bind the block-local binding 't' reached through a branch to 'owned' binding 's': its ownership cannot be resolved here
        \\t.cell:6:9: note: R10 refuses what it cannot prove is not 'arc': an 'arc' value made unique is freed twice
        \\
    );
}

test "a valueless block at an assignment is walked exactly once" {
    // The `.unit` arm must RETURN, not fall through to `checkExpr`. The
    // discriminator is a move of an OUTER place inside the block: a second
    // walk would see `s1` already moved and report a use-after-move. A
    // canary on a later binding's line would not catch this, because
    // borrowck's own ids stay self-consistent across a double walk; only
    // codegen's `wasMoved` lookups would drift. The typecheck unit mismatch
    // is not in the way: this harness runs borrowck alone.
    try expectAccepted(block_prelude ++
        \\pub fn main() {
        \\    let owned s1 = make()
        \\    var owned s2 = make()
        \\    s2 = {
        \\        eat(owned s1)
        \\    }
        \\}
    );
}

test "a valueless block at a call argument is walked exactly once" {
    // The `.unit` arm `continue`s the argument loop; same discriminator.
    try expectAccepted(block_prelude ++
        \\pub fn main() {
        \\    let owned s1 = make()
        \\    eat(owned {
        \\        eat(owned s1)
        \\    })
        \\}
    );
}

test "a block tail that is a borrow alias of the block's own local cannot leave through an owned position" {
    // The value-position release in codegen keeps a local the tail can
    // reach alive; this is the other half, at the owned sites, where a
    // borrow alias is refused outright rather than copied.
    try expectDiagnostics(block_prelude ++
        \\pub fn mk() -> String {
        \\    return {
        \\        let owned t = make()
        \\        let shared v = &t
        \\        v
        \\    }
        \\}
    ,
        \\t.cell:7:9: error: cannot move out of 'v': it is a shared borrow, not an owner
        \\
    );
}

test "R4 refuses reassigning an arc var while a shared borrow of it is live, which the row 5 pre-drop relies on" {
    // codegen's reassignment pre-drop (R11 row 5) frees the old box before
    // the store; a view of that box surviving the statement would dangle.
    // It cannot: this is the refusal. A borrow that is DEAD by then (NLL)
    // is accepted and never read again.
    try expectDiagnostics(
        \\pub fn inspect(shared s: String) -> Int { return 1 }
        \\pub fn main() {
        \\    var arc v = "one"
        \\    let shared w = &v
        \\    v = "two"
        \\    inspect(w)
        \\}
    ,
        \\t.cell:5:5: error: cannot assign to 'v' while it is borrowed as shared
        \\t.cell:4:21: note: the shared borrow starts here and lasts to the end of this block
        \\
    );
}

test "R7 write clause: assigning to the scrutinee while an arm binding aliases it is refused" {
    // Measured at 4c93571 before this clause existed: `cell check` exit 0,
    // ASan heap-use-after-free at `print(x)`, because the row 5 pre-drop
    // released the box `x` still pointed at. Flat and inside a `while`.
    try expectDiagnostics(
        \\pub fn print(shared s: String);
        \\pub fn main() {
        \\    var arc v = "one"
        \\    match v {
        \\        x => {
        \\            v = "two"
        \\            print(x)
        \\        }
        \\    }
        \\}
    ,
        \\t.cell:6:13: error: cannot assign to 'v' while the match binding 'x' aliases it
        \\t.cell:5:9: note: R7: a match binding aliases the scrutinee rather than copying or borrowing it, and lasts to the end of its arm; assign after the match, or bind a copy of the value before it
        \\
    );
    try expectDiagnostics(
        \\pub fn print(shared s: String);
        \\pub fn main() {
        \\    var arc v = "one"
        \\    var i = 0
        \\    while i < 3 {
        \\        match v {
        \\            x => {
        \\                v = "two"
        \\                print(x)
        \\            }
        \\        }
        \\        i = i + 1
        \\    }
        \\}
    ,
        \\t.cell:8:17: error: cannot assign to 'v' while the match binding 'x' aliases it
        \\t.cell:7:13: note: R7: a match binding aliases the scrutinee rather than copying or borrowing it, and lasts to the end of its arm; assign after the match, or bind a copy of the value before it
        \\
    );
}

test "R7 write clause covers owned scrutinees too, and an assignment after the match is fine" {
    try expectDiagnostics(
        \\pub fn make() -> String;
        \\pub fn print(shared s: String);
        \\pub fn main() {
        \\    var owned s = make()
        \\    match s {
        \\        x => {
        \\            s = make()
        \\            print(x)
        \\        }
        \\    }
        \\}
    ,
        \\t.cell:7:13: error: cannot assign to 's' while the match binding 'x' aliases it
        \\t.cell:6:9: note: R7: a match binding aliases the scrutinee rather than copying or borrowing it, and lasts to the end of its arm; assign after the match, or bind a copy of the value before it
        \\
    );
    try expectAccepted(
        \\pub fn print(shared s: String);
        \\pub fn main() {
        \\    var arc v = "one"
        \\    match v {
        \\        x => {
        \\            print(x)
        \\        }
        \\    }
        \\    v = "two"
        \\    print(v)
        \\}
    );
}

test "R2.a does not fire for a place declared inside the loop body" {
    // A binding created fresh each iteration is not moved across the back
    // edge, so there is nothing to catch. Getting this wrong would reject
    // every loop that owns anything.
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    var i = 0
        \\    while i < 3 {
        \\        let owned tmp = Buffer { data: [], len: 0 }
        \\        take(owned tmp)
        \\        i = i + 1
        \\    }
        \\}
    );
}

test "after_loop is live for an outer var revived on every path out of the while" {
    // R16 residual: a var declared outside a while, moved inside it, and
    // revived before the body ends. `loop_moved` still poisons in-loop
    // exits and the function-end `block_end`; `after_loop` is the one
    // record that stays live. P_exit: no condition move, not dead at body
    // end, every jump this walk saw still held a value (none here).
    var h: LiveHarness = try .init(
        \\pub fn take(owned s: String) { }
        \\pub fn f() {
        \\    var owned v: String = "a"
        \\    var i = 0
        \\    while i < 3 {
        \\        take(v)
        \\        v = "b"
        \\        i = i + 1
        \\    }
        \\}
    );
    defer h.deinit();
    const v = h.binding("v");
    const key = h.firstWhile("f");
    try std.testing.expect(h.checker.liveAtExit(.after_loop, key, v));
    try std.testing.expect(!h.checker.liveAtExit(.block_end, h.fnBodyKey("f"), v));
}

test "after_loop is absent when a break is taken while the outer var is dead" {
    // `take(v); if i > n { break }; v = "b"`. The jump is recorded live=false
    // before invalidation, so P_exit fails and there is no after_loop record.
    // Ignoring that dead jump and emitting the drop was an AddressSanitizer
    // double free (exit 134), measured: the `break` path already handed the
    // buffer to `take`, and C `break` runs the code after the while.
    var h: LiveHarness = try .init(
        \\pub fn take(owned s: String) { }
        \\pub fn f(copy n: Int) {
        \\    var owned v: String = "a"
        \\    var i = 0
        \\    while i < 3 {
        \\        i = i + 1
        \\        take(v)
        \\        if i > n {
        \\            break
        \\        }
        \\        v = "b"
        \\    }
        \\}
    );
    defer h.deinit();
    const v = h.binding("v");
    const key = h.firstWhile("f");
    try std.testing.expect(!h.checker.liveAtExit(.after_loop, key, v));
}

test "after_loop_skip is live for a skip-revival break, and names that break" {
    // Same program as the test above. `after_loop` stays absent; the new
    // kind vouches for the release only together with the skip record.
    var h: LiveHarness = try .init(
        \\pub fn take(owned s: String) { }
        \\pub fn f(copy n: Int) {
        \\    var owned v: String = "a"
        \\    var i = 0
        \\    while i < 3 {
        \\        i = i + 1
        \\        take(v)
        \\        if i > n {
        \\            break
        \\        }
        \\        v = "b"
        \\    }
        \\}
    );
    defer h.deinit();
    const v = h.binding("v");
    const key = h.firstWhile("f");
    try std.testing.expect(!h.checker.liveAtExit(.after_loop, key, v));
    try std.testing.expect(h.checker.liveAtExit(.after_loop_skip, key, v));
    try std.testing.expectEqual(@as(?usize, key), h.checker.skipBreakLoop(h.firstJump("f")));
    try std.testing.expect(h.checker.loopHasSkipBreaks(key));
}

test "after_loop_skip is absent for a field move" {
    // A field move is released per field elsewhere (`exit_field_liveness`),
    // never by a whole-binding release after the loop. (A dead `continue`
    // never reaches this rule: R2.a refuses it.)
    var h: LiveHarness = try .init(
        \\pub struct P { a: String, b: String }
        \\pub fn take(owned s: String) { }
        \\pub fn field(copy n: Int, owned p: P) {
        \\    var owned q: P = p
        \\    var i = 0
        \\    while i < 3 {
        \\        i = i + 1
        \\        take(q.a)
        \\        if i > n {
        \\            break
        \\        }
        \\        q.a = "b"
        \\    }
        \\}
    );
    defer h.deinit();
    const key = h.firstWhile("field");
    try std.testing.expect(!h.checker.liveAtExit(.after_loop_skip, key, h.binding("q")));
    try std.testing.expect(!h.checker.loopHasSkipBreaks(key));
}

test "a return inside an accepted loop keeps the walk's liveness" {
    // 2026-09-17. An accepted loop no longer poisons its `return` records:
    // after the revival the value is live at the `return`.
    var h: LiveHarness = try .init(
        \\pub fn take(owned s: String) { }
        \\pub fn f(copy n: Int) {
        \\    var owned v: String = "a"
        \\    var i = 0
        \\    while i < 3 {
        \\        i = i + 1
        \\        take(v)
        \\        v = "b"
        \\        if i > n {
        \\            return
        \\        }
        \\    }
        \\}
    );
    defer h.deinit();
    try std.testing.expect(h.checker.liveAtExit(.return_stmt, firstReturnIn(h.fnBody("f")).?, h.binding("v")));
}

test "a return between the move and the revival stays dead" {
    var h: LiveHarness = try .init(
        \\pub fn take(owned s: String) { }
        \\pub fn f(copy n: Int) {
        \\    var owned v: String = "a"
        \\    var i = 0
        \\    while i < 3 {
        \\        i = i + 1
        \\        take(v)
        \\        if i > n {
        \\            return
        \\        }
        \\        v = "b"
        \\    }
        \\}
    );
    defer h.deinit();
    try std.testing.expect(!h.checker.liveAtExit(.return_stmt, firstReturnIn(h.fnBody("f")).?, h.binding("v")));
}

test "an if branch that always returns does not reach the code after the if" {
    // 2026-09-17, docs/superpowers/plans/2026-09-17-early-return-divergence.md.
    try expectAccepted(
        \\pub fn take(owned s: String) { }
        \\pub fn early(copy c: Bool, owned s: String) {
        \\    if c {
        \\        take(s)
        \\        return
        \\    }
        \\    take(s)
        \\}
        \\pub fn early_value(copy c: Bool, owned s: String) -> String {
        \\    if c {
        \\        return s
        \\    }
        \\    return s
        \\}
        \\pub fn else_side(copy c: Bool, owned s: String) {
        \\    if c {
        \\        let n = 1
        \\    } else {
        \\        take(s)
        \\        return
        \\    }
        \\    take(s)
        \\}
        \\pub fn nested(copy c: Bool, copy d: Bool, owned s: String) {
        \\    if c {
        \\        take(s)
        \\        if d {
        \\            return
        \\        } else {
        \\            return
        \\        }
        \\    }
        \\    take(s)
        \\}
        \\
    );
}

test "a match arm that always leaves does not reach the code after the match" {
    // 2026-09-17, design C: the divergence rule applied to `match` arms.
    try expectAccepted(
        \\pub fn take(owned s: String) { }
        \\pub fn arm(copy o: Int?, owned s: String) {
        \\    match o {
        \\        Some(x) => {
        \\            take(s)
        \\            return
        \\        },
        \\        None => {
        \\            let n = 0
        \\        },
        \\    }
        \\    take(s)
        \\}
        \\pub fn tail_match(copy c: Bool, copy o: Int?, owned s: String) {
        \\    if c {
        \\        take(s)
        \\        match o {
        \\            Some(x) => {
        \\                return
        \\            },
        \\            None => {
        \\                return
        \\            },
        \\        }
        \\    }
        \\    take(s)
        \\}
        \\
    );
    try expectRejectedWith(
        \\pub fn take(owned s: String) { }
        \\pub fn f(copy o: Int?, copy d: Bool, owned s: String) {
        \\    match o {
        \\        Some(x) => {
        \\            take(s)
        \\            if d {
        \\                return
        \\            }
        \\        },
        \\        None => {
        \\            let n = 0
        \\        },
        \\    }
        \\    take(s)
        \\}
        \\
    , "use of 's' after it was moved");
    try expectRejectedWith(
        \\pub fn take(owned s: String) { }
        \\pub fn g(copy o: Int?, owned s: String) {
        \\    take(s)
        \\    match o {
        \\        Some(x) => {
        \\            return
        \\        },
        \\        None => {
        \\            return
        \\        },
        \\    }
        \\    take(s)
        \\}
        \\
    , "use of 's' after it was moved");
}

test "a branch that only sometimes returns still reaches the code after the if" {
    try expectRejectedWith(
        \\pub fn take(owned s: String) { }
        \\pub fn f(copy c: Bool, copy d: Bool, owned s: String) {
        \\    if c {
        \\        take(s)
        \\        if d {
        \\            return
        \\        }
        \\    }
        \\    take(s)
        \\}
        \\
    , "use of 's' after it was moved");
    try expectRejectedWith(
        \\pub fn take(owned s: String) { }
        \\pub fn g(copy c: Bool, owned s: String) {
        \\    if c {
        \\        return
        \\    } else {
        \\        take(s)
        \\    }
        \\    take(s)
        \\}
        \\
    , "use of 's' after it was moved");
}
