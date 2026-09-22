//! Borrow checker tests: owning Ok/Err/Some payloads and exit liveness records.

const std = @import("std");
const bk_root = @import("../borrowck.zig");
const bk_tests_support = @import("tests_support.zig");
const Checker = bk_root.Checker;
const LiveHarness = bk_tests_support.LiveHarness;
const expectAccepted = bk_tests_support.expectAccepted;
const expectRejectedWith = bk_tests_support.expectRejectedWith;

pub const owning_ok_prelude =
    \\pub fn take(owned s: String) { }
    \\pub fn keep(owned r: Result<String, Int32>) { }
    \\pub fn view(shared s: String) -> Int { return 0 }
    \\pub fn read() -> Result<String, Int32>;
    \\
;

test "Ok moves an owning String operand" {
    // Owning String in Ok (2026-09-17).
    try expectRejectedWith(owning_ok_prelude ++
        \\pub fn f(owned s: String) -> Result<String, Int32> {
        \\    let r: Result<String, Int32> = Ok(s)
        \\    take(s)
        \\    return r
        \\}
        \\
    , "use of 's' after it was moved");
    // A scalar operand is still only read.
    try expectAccepted(
        \\pub fn f(copy n: Int) -> Int {
        \\    let r: Result<Int, Int32> = Ok(n)
        \\    return n
        \\}
        \\
    );
}

test "Ok(owned ..) consumes the Result on its own arm only" {
    try expectRejectedWith(owning_ok_prelude ++
        \\pub fn f(owned r: Result<String, Int32>) {
        \\    match r {
        \\        Ok(owned x) => take(x),
        \\        Err(_) => {},
        \\    }
        \\    keep(r)
        \\}
        \\
    , "use of 'r' after it was moved");
    try expectAccepted(owning_ok_prelude ++
        \\pub fn f(owned r: Result<String, Int32>) {
        \\    match r {
        \\        Ok(owned x) => take(x),
        \\        Err(_) => keep(r),
        \\    }
        \\}
        \\
    );
    try expectRejectedWith(owning_ok_prelude ++
        \\pub fn f(owned r: Result<String, Int32>, copy n: Int) {
        \\    var i = 0
        \\    while i < n {
        \\        i = i + 1
        \\        match r {
        \\            Ok(owned x) => take(x),
        \\            Err(_) => {},
        \\        }
        \\    }
        \\}
        \\
    , "is moved inside a loop");
}

test "Ok(shared ..) borrows the Result for its arm" {
    try expectRejectedWith(owning_ok_prelude ++
        \\pub fn f(owned r: Result<String, Int32>) -> Int {
        \\    return match r {
        \\        Ok(shared x) => {
        \\            keep(r)
        \\            view(x)
        \\        },
        \\        Err(_) => 0,
        \\    }
        \\}
        \\
    , "cannot move 'r' while it is borrowed");
    try expectAccepted(owning_ok_prelude ++
        \\pub fn f(owned r: Result<String, Int32>) -> Int {
        \\    let n = match r {
        \\        Ok(shared x) => view(x),
        \\        Err(_) => 0,
        \\    }
        \\    keep(r)
        \\    return n
        \\}
        \\
    );
}

test "Ok of a match alias is refused like any consumption of an alias" {
    try expectRejectedWith(owning_ok_prelude ++
        \\pub fn f(owned s: String) -> Result<String, Int32> {
        \\    return match s { y => Ok(y) }
        \\}
        \\
    , "the scrutinee still owns the value");
}

pub const owning_err_prelude =
    \\pub fn take(owned s: String) { }
    \\pub fn keepe(owned r: Result<Int, String>) { }
    \\pub fn viewe(shared s: String) -> Int { return 0 }
    \\
;

test "Err moves an owning String and Err(owned ..) consumes on its arm only" {
    // Owning String in Err (sub-project 3, 2026-09-17).
    try expectRejectedWith(owning_err_prelude ++
        \\pub fn f(owned s: String) -> Result<Int, String> {
        \\    let r: Result<Int, String> = Err(s)
        \\    take(s)
        \\    return r
        \\}
        \\
    , "use of 's' after it was moved");
    try expectRejectedWith(owning_err_prelude ++
        \\pub fn f(owned r: Result<Int, String>) {
        \\    match r {
        \\        Ok(_) => {},
        \\        Err(owned e) => take(e),
        \\    }
        \\    keepe(r)
        \\}
        \\
    , "use of 'r' after it was moved");
    try expectAccepted(owning_err_prelude ++
        \\pub fn f(owned r: Result<Int, String>) {
        \\    match r {
        \\        Ok(_) => keepe(r),
        \\        Err(owned e) => take(e),
        \\    }
        \\}
        \\
    );
    try expectRejectedWith(owning_err_prelude ++
        \\pub fn f(owned r: Result<Int, String>) -> Int {
        \\    return match r {
        \\        Ok(_) => 0,
        \\        Err(shared e) => {
        \\            keepe(r)
        \\            viewe(e)
        \\        },
        \\    }
        \\}
        \\
    , "cannot move 'r' while it is borrowed");
    try expectRejectedWith(owning_err_prelude ++
        \\pub fn f(owned s: String) -> Result<Int, String> {
        \\    return match s { y => Err(y) }
        \\}
        \\
    , "the scrutinee still owns the value");
}

test "Some moves an owning String and Some(owned ..) consumes on its arm only" {
    // Sub-project 4 (2026-09-17).
    try expectRejectedWith(
        \\pub fn take(owned s: String) { }
        \\pub fn f(owned s: String) -> String? {
        \\    let o: String? = Some(s)
        \\    take(s)
        \\    return o
        \\}
        \\
    , "use of 's' after it was moved");
    try expectRejectedWith(
        \\pub fn take(owned s: String) { }
        \\pub fn keepo(owned o: String?) { }
        \\pub fn f(owned o: String?) {
        \\    match o {
        \\        Some(owned x) => take(x),
        \\        None => {},
        \\    }
        \\    keepo(o)
        \\}
        \\
    , "use of 'o' after it was moved");
    try expectAccepted(
        \\pub fn take(owned s: String) { }
        \\pub fn keepo(owned o: String?) { }
        \\pub fn f(owned o: String?) {
        \\    match o {
        \\        Some(owned x) => take(x),
        \\        None => keepo(o),
        \\    }
        \\}
        \\
    );
}

test "Ok of a scalar match alias is still only a read" {
    try expectAccepted(
        \\pub fn f(owned n: Int) -> Result<Int, Int32> {
        \\    return match n { y => Ok(y) }
        \\}
        \\
    );
}

test "yielding an Ok(owned ..) binding straight out of its arm is refused" {
    try expectRejectedWith(owning_ok_prelude ++
        \\pub fn f(owned r: Result<String, Int32>) -> Int {
        \\    let owned s: String = match r {
        \\        Ok(owned x) => x,
        \\        Err(_) => "e",
        \\    }
        \\    take(s)
        \\    return 0
        \\}
        \\
    , "yielding the 'Ok(owned x)' binding directly from its arm is not implemented");
}

test "Ok(owned ..) leaves the Result live on the other arm and dead after the match" {
    var h: LiveHarness = try .init(owning_ok_prelude ++
        \\pub fn f(owned res: Result<String, Int32>) {
        \\    match res {
        \\        Ok(owned x) => take(x),
        \\        Err(_) => {},
        \\    }
        \\}
    );
    defer h.deinit();
    // `h.binding` finds the FIRST binding of a name, and the prelude's
    // `keep` has an `r`, hence `res`.
    const r = h.binding("res");
    try std.testing.expect(h.checker.wasMoved(r));
    try std.testing.expect(!h.checker.liveAtExit(.block_end, h.fnBodyKey("f"), r));
}

test "a moved-then-break branch is accepted inside the loop and refused after it" {
    try expectAccepted(
        \\pub fn take(owned s: String) { }
        \\pub fn f(copy c: Bool, owned s: String) {
        \\    var owned v: String = s
        \\    var i = 0
        \\    while i < 3 {
        \\        i = i + 1
        \\        if c {
        \\            take(v)
        \\            break
        \\        }
        \\        take(v)
        \\        v = "c"
        \\    }
        \\}
        \\
    );
    try expectRejectedWith(
        \\pub fn take(owned s: String) { }
        \\pub fn f(copy c: Bool, owned s: String) {
        \\    var owned v: String = s
        \\    var i = 0
        \\    while i < 3 {
        \\        i = i + 1
        \\        if c {
        \\            take(v)
        \\            break
        \\        }
        \\    }
        \\    take(v)
        \\}
        \\
    , "use of 'v' after it was moved");
}

test "after_loop is absent when the condition moves the outer var" {
    // `while consume(v) { v = make() }`: the last failing condition already
    // took `v`. Treating that as live and dropping after the loop was an
    // AddressSanitizer double free (exit 134), measured.
    var h: LiveHarness = try .init(
        \\pub fn consume(owned s: String) -> Bool { return true }
        \\pub fn f() {
        \\    var owned v: String = "a"
        \\    while consume(v) {
        \\        v = "b"
        \\    }
        \\}
    );
    defer h.deinit();
    const v = h.binding("v");
    const key = h.firstWhile("f");
    try std.testing.expect(!h.checker.liveAtExit(.after_loop, key, v));
}

test "after_loop is live for a revival then break, and the jump itself stays dead" {
    // `take(v); v = "b"; if i > n { break }`. Every jump this walk saw still
    // held a value, so after_loop is live. The jump record is poisoned by
    // `loop_moved`, so codegen must not drop at `break` (C break already
    // runs the code after the while).
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
        \\            break
        \\        }
        \\    }
        \\}
    );
    defer h.deinit();
    const v = h.binding("v");
    const key = h.firstWhile("f");
    try std.testing.expect(h.checker.liveAtExit(.after_loop, key, v));
    try std.testing.expect(!h.checker.liveAtExit(.jump, h.firstJump("f"), v));
}

test "R16 field live at the non-moving branch_end and dead after the merge" {
    // Residual 1 at field granularity: `take(owned p.a)` inside `if c`
    // marks `p.a` moved for the whole function, so whole-binding
    // `liveAtExit` is false on every path (any dead field path). The
    // sibling field records keep the else path live and the merge dead.
    var h: LiveHarness = try .init(
        \\pub struct Pair {
        \\    owned a: String
        \\    owned b: String
        \\}
        \\pub fn take(owned s: String) { }
        \\pub fn f(shared c: Bool) {
        \\    let owned p: Pair = Pair { a: "x", b: "y" }
        \\    if (c) {
        \\        take(owned p.a)
        \\    }
        \\}
    );
    defer h.deinit();
    const p = h.binding("p");
    const if_expr = h.firstIf("f");
    const then_key = Checker.branchKeyOf(if_expr.kind.if_expr.then_body);
    const else_key = @intFromPtr(if_expr);
    const end_key = h.fnBodyKey("f");
    try std.testing.expect(!h.checker.fieldLiveAtExit(.branch_end, then_key, p, "a"));
    try std.testing.expect(h.checker.fieldLiveAtExit(.branch_end, else_key, p, "a"));
    try std.testing.expect(h.checker.fieldDeadAtExit(.block_end, end_key, p, "a"));
    try std.testing.expect(!h.checker.fieldDeadAtExit(.branch_end, else_key, p, "a"));
    // `b` was never moved, so there is no field record: missing => leak.
    try std.testing.expect(!h.checker.fieldLiveAtExit(.branch_end, else_key, p, "b"));
    try std.testing.expect(!h.checker.fieldDeadAtExit(.block_end, end_key, p, "b"));
    // Whole-binding `liveAtExit` is true on the keeping path (no field is
    // dead there) and false after the merge (any dead field path folds in).
    try std.testing.expect(h.checker.liveAtExit(.branch_end, else_key, p));
    try std.testing.expect(!h.checker.liveAtExit(.block_end, end_key, p));
}

test "branch ends record liveness before the merge" {
    // Plan D Task 2 at whole-binding granularity (the test above is the
    // field form). A var moved on the then-branch only: that branch end is
    // dead, the else-branch end is live, and the function end after the
    // merge is dead. Both branches are blocks, so both keys are the block's
    // statement slice, which is what codegen asks with.
    var h: LiveHarness = try .init(
        \\pub fn take(owned s: String) { }
        \\pub fn f(copy c: Int) {
        \\    var owned v: String = "a"
        \\    var i = 0
        \\    if c > 0 {
        \\        take(v)
        \\    } else {
        \\        i = i + 1
        \\    }
        \\}
    );
    defer h.deinit();
    const v = h.binding("v");
    const if_expr = h.firstIf("f");
    const then_body = if_expr.kind.if_expr.then_body;
    const else_body = if_expr.kind.if_expr.else_body.?;
    try std.testing.expect(then_body.kind == .block and else_body.kind == .block);
    const then_key = Checker.branchKeyOf(then_body);
    const else_key = Checker.branchKeyOf(else_body);
    try std.testing.expect(then_key != else_key);
    try std.testing.expect(!h.checker.liveAtExit(.branch_end, then_key, v));
    try std.testing.expect(h.checker.liveAtExit(.branch_end, else_key, v));
    try std.testing.expect(!h.checker.liveAtExit(.block_end, h.fnBodyKey("f"), v));
}

test "a jump records liveness at the jump" {
    // Plan D Task 2: a LOOP-LOCAL var moved and revived before a `continue`
    // holds a value at the jump. `loop_moved` poisons only vars declared
    // outside the while (the after_loop tests above), so this record stays
    // live and codegen releases `v` at the `continue`.
    var h: LiveHarness = try .init(
        \\pub fn take(owned s: String) { }
        \\pub fn f(copy n: Int) {
        \\    var i = 0
        \\    while i < n {
        \\        i = i + 1
        \\        var owned v: String = "a"
        \\        take(v)
        \\        v = "b"
        \\        if i > 0 {
        \\            continue
        \\        }
        \\    }
        \\}
    );
    defer h.deinit();
    const v = h.binding("v");
    try std.testing.expect(h.checker.liveAtExit(.jump, h.firstJump("f"), v));
}

test "a jump taken while a loop-local is moved records it dead" {
    // The converse of the test above: the `continue` sits between the move
    // and the revival, so releasing `v` there would free a buffer `take`
    // already owns.
    var h: LiveHarness = try .init(
        \\pub fn take(owned s: String) { }
        \\pub fn f(copy n: Int) {
        \\    var i = 0
        \\    while i < n {
        \\        i = i + 1
        \\        var owned v: String = "a"
        \\        take(v)
        \\        if i > 0 {
        \\            continue
        \\        }
        \\        v = "b"
        \\    }
        \\}
    );
    defer h.deinit();
    const v = h.binding("v");
    try std.testing.expect(!h.checker.liveAtExit(.jump, h.firstJump("f"), v));
}

test "a record reassigned whole after a move is live at scope end" {
    // Plan D Task 5. One harness per function, so `binding("b")` cannot
    // pick the other function's `b`.
    var hf: LiveHarness = try .init(
        \\pub struct Box { owned s: String }
        \\pub fn take(owned b: Box);
        \\pub fn f() {
        \\    var owned b = Box { s: "one" }
        \\    take(b)
        \\    b = Box { s: "two" }
        \\}
    );
    defer hf.deinit();
    try std.testing.expect(hf.checker.recordLiveAtExit(.block_end, hf.fnBodyKey("f"), hf.binding("b")));

    // A field moved out AFTER the revival leaves a dead field path, so the
    // record is not released whole; the partial path handles it instead.
    var hg: LiveHarness = try .init(
        \\pub struct Box { owned s: String }
        \\pub fn take(owned b: Box);
        \\pub fn g() {
        \\    var owned b = Box { s: "one" }
        \\    take(b)
        \\    b = Box { s: "two" }
        \\    let owned moved: String = b.s
        \\}
    );
    defer hg.deinit();
    try std.testing.expect(!hg.checker.recordLiveAtExit(.block_end, hg.fnBodyKey("g"), hg.binding("b")));
}
