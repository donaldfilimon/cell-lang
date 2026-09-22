//! Borrow checker tests: R10, R2.b, R12, and the list-element clauses.

const bk_tests_loops = @import("tests_loops.zig");
const bk_tests_support = @import("tests_support.zig");
const expectDiagnostics = bk_tests_support.expectDiagnostics;
const expectAccepted = bk_tests_support.expectAccepted;
const expectRejectedWith = bk_tests_support.expectRejectedWith;
const prelude = bk_tests_support.prelude;
const block_prelude = bk_tests_loops.block_prelude;

test "R10: an arc place may not be passed to an owned parameter" {
    // Ruled a REFUSAL rather than a retain, and the reason is that a retain
    // cannot fix it. `owned [T]` and `shared [T]` are the same C type
    // (`cell_slice_t` by value), so the C backend's unbox emitted
    // `take((*(const cell_slice_t *)xs.ptr))`, which compiles clean at
    // -Werror. `runtime/cell_rt.h` section 7 makes an `owned` callee
    // responsible for the eventual free, and `cell_slice_drop_glue` then
    // frees the same BUFFER again when the box dies. `cell_arc_clone`
    // increments a refcount and the buffer is not what the refcount governs,
    // so the only correct answer is to reject the conversion.
    try expectDiagnostics(
        \\pub fn take(owned xs: [Int]) -> Int;
        \\pub fn main() {
        \\    let arc xs = [1, 2, 3]
        \\    let copy n = take(owned xs)
        \\}
    ,
        \\t.cell:4:29: error: cannot pass 'arc' value 'xs' to 'owned' parameter 'xs': ownership is shared and cannot be made unique
        \\t.cell:4:29: note: an 'owned' holder frees the value, and the 'arc' box would free it again
        \\
    );
}

test "R10: an arc place may not be bound to an owned binding" {
    // The escape the parameter guard did not reach. `let owned ys: [Int] = xs`
    // emitted `cell_slice_t ys = *(const cell_slice_t *)xs.ptr;` and then BOTH
    // `cell_slice_free(&ys)` and the box's own glue freed the same buffer:
    // AddressSanitizer double free, exit 134, while `cell check` exited 0 and
    // `-Wall -Wextra -Werror` was silent.
    try expectDiagnostics(
        \\pub fn main() {
        \\    let arc xs = [1, 2, 3]
        \\    let owned ys: [Int] = xs
        \\}
    ,
        \\t.cell:3:27: error: cannot bind 'arc' value 'xs' to 'owned' binding 'ys': ownership is shared and cannot be made unique
        \\t.cell:3:27: note: an 'owned' holder frees the value, and the 'arc' box would free it again
        \\
    );
}

test "R10: an arc place may not be assigned to an owned place" {
    // The same double free reached by writing into an already-declared
    // `owned` place rather than declaring a new one. Found by enumerating the
    // positions rather than by review, which is the point of enumerating.
    try expectDiagnostics(
        \\pub fn main() {
        \\    let arc xs = [1, 2, 3]
        \\    var owned ys: [Int] = [9]
        \\    ys = xs
        \\}
    ,
        \\t.cell:4:10: error: cannot assign 'arc' value 'xs' to 'owned' place 'ys': ownership is shared and cannot be made unique
        \\t.cell:4:10: note: an 'owned' holder frees the value, and the 'arc' box would free it again
        \\
    );
}

test "R10: an arc place may not be stored in an owned struct field" {
    // Not a double free today, and refused anyway: this backend never drops a
    // `record` shape, so the field's buffer is freed once by the box's glue
    // and the record merely outlives it. It is the same illegal conversion
    // and becomes a double free the moment struct drops land.
    try expectDiagnostics(
        \\pub struct Buf { owned data: [Int]  copy len: Int }
        \\pub fn main() {
        \\    let arc xs = [1, 2, 3]
        \\    let owned b = Buf { data: xs, len: 3 }
        \\}
    ,
        \\t.cell:4:31: error: cannot store 'arc' value 'xs' in 'owned' field 'data': ownership is shared and cannot be made unique
        \\t.cell:4:31: note: an 'owned' holder frees the value, and the 'arc' box would free it again
        \\
    );
}

test "R10 is asked of the EXPRESSION, so a value position escapes none of the four positions" {
    // R10 enumerated four POSITIONS and asserted a property of every
    // consumption. Each position asked `placeOf` first, and a `match` is
    // valued and is not a place, so all four let it through. Measured before
    // the fix, on the same `arc` binding and the same semantic operation:
    //
    //     take(owned xs)                            refused, exit 1
    //     take(owned match c { 0 => xs, _ => xs })  ACCEPTED, exit 0
    //
    // and identically for the `let`, the assignment and the struct field. The
    // emitted C unboxed the arc and handed the box's slice by value to an
    // `owned` parameter, which is the exact shape R10's text names as the
    // double free it exists to prevent. It was masked only by the
    // `cell_arc_clone` in the value temporary holding the refcount off zero.
    //
    // Same axis, place versus value, as `arc` use-after-frees three and four.
    try expectDiagnostics(
        \\pub fn take(owned xs: [Int]) -> Int;
        \\pub fn main() {
        \\    let copy c = 0
        \\    let arc xs = [1, 2, 3]
        \\    let copy n = take(owned match c { 0 => xs, _ => xs })
        \\}
    ,
        \\t.cell:5:44: error: cannot pass 'arc' value 'xs' to 'owned' parameter 'xs': ownership is shared and cannot be made unique
        \\t.cell:5:44: note: an 'owned' holder frees the value, and the 'arc' box would free it again
        \\
    );
    try expectDiagnostics(
        \\pub fn main() {
        \\    let copy c = 0
        \\    let arc xs = [1, 2, 3]
        \\    let owned ys: [Int] = match c { 0 => xs, _ => xs }
        \\}
    ,
        \\t.cell:4:42: error: cannot bind 'arc' value 'xs' to 'owned' binding 'ys': ownership is shared and cannot be made unique
        \\t.cell:4:42: note: an 'owned' holder frees the value, and the 'arc' box would free it again
        \\
    );
    try expectDiagnostics(
        \\pub fn main() {
        \\    let copy c = 0
        \\    let arc xs = [1, 2, 3]
        \\    var owned ys: [Int] = []
        \\    ys = match c { 0 => xs, _ => xs }
        \\}
    ,
        \\t.cell:5:25: error: cannot assign 'arc' value 'xs' to 'owned' place 'ys': ownership is shared and cannot be made unique
        \\t.cell:5:25: note: an 'owned' holder frees the value, and the 'arc' box would free it again
        \\
    );
    try expectDiagnostics(
        \\pub struct Box { owned items: [Int] }
        \\pub fn main() {
        \\    let copy c = 0
        \\    let arc xs = [1, 2, 3]
        \\    let owned b = Box { items: match c { 0 => xs, _ => xs } }
        \\}
    ,
        \\t.cell:5:47: error: cannot store 'arc' value 'xs' in 'owned' field 'items': ownership is shared and cannot be made unique
        \\t.cell:5:47: note: an 'owned' holder frees the value, and the 'arc' box would free it again
        \\
    );
}

test "R10 also looks through an if branch and a block tail, which typecheck alone would hide" {
    // Neither of these can reach a typed `owned` position through `cell
    // check` today, because typecheck gives an `if`-expression and a block
    // the type `()` and refuses the argument first. That is an ACCIDENT of
    // the type checker, not enforcement of an ownership rule, and R10's own
    // text objects elsewhere to a rule whose enforcement depends on a
    // coincidence of two types. Borrowck runs independently of typecheck, so
    // this harness reaches both forms and pins them refused on their own
    // merits: when `if` grows a real type, nothing here has to change.
    try expectDiagnostics(
        \\pub fn take(owned xs: [Int]) -> Int;
        \\pub fn main() {
        \\    let copy c = 0
        \\    let arc xs = [1, 2, 3]
        \\    let copy n = take(owned if c > 0 { xs } else { xs })
        \\}
    ,
        \\t.cell:5:40: error: cannot pass 'arc' value 'xs' to 'owned' parameter 'xs': ownership is shared and cannot be made unique
        \\t.cell:5:40: note: an 'owned' holder frees the value, and the 'arc' box would free it again
        \\
    );
    try expectDiagnostics(
        \\pub fn take(owned xs: [Int]) -> Int;
        \\pub fn main() {
        \\    let arc xs = [1, 2, 3]
        \\    let copy n = take(owned { xs })
        \\}
    ,
        \\t.cell:4:31: error: cannot pass 'arc' value 'xs' to 'owned' parameter 'xs': ownership is shared and cannot be made unique
        \\t.cell:4:31: note: an 'owned' holder frees the value, and the 'arc' box would free it again
        \\
    );
}

test "R10's other direction: an owned place may not be moved into an arc box, at five positions" {
    // NOT symmetry for its own sake. `tools/sweep-backends.sh` reported four
    // rows, all `C UNCOMPILABLE: initializing 'cell_arc_t'`, which made this
    // look like a backend typing bug. It is not: the checker does not consume
    // the source, so boxing the place hands the box a buffer the source still
    // frees. Measured before the refusal existed, with an owned LOCAL rather
    // than a parameter, because parameters were not released then and hid it:
    // `let owned s = make()` then `let arc a = match 1 { _ => s }` emitted
    // `cell_arc_from_string(...)` and `cell_string_free(&s)` and died
    // `exit 134`, `attempting double-free ... in cell_string_free`.
    // Implementing the move means deciding who releases the box, which is
    // R11 row 1's ABI question, so this refuses and says "not implemented".
    // The direct `let arc a = p` with `p: owned String` WAS this case; it is
    // implemented since 2026-09-16 (see the test after this one), so the
    // direct form is pinned with a source the box cannot take: an `Int?`.
    try expectDiagnostics(
        \\pub fn f(owned p: Int?) -> Int {
        \\    let arc a = p
        \\    return 0
        \\}
    ,
        \\t.cell:2:17: error: cannot bind 'owned' place 'p' to 'arc' binding 'a': moving an owned place into an 'arc' box is not implemented
        \\t.cell:2:17: note: R10 designs this as a move into a fresh 'arc' box, but the checker does not consume the source, so the box and the source's own drop free the same buffer; bind a fresh value to the 'arc' place, or start from an 'arc' source
        \\
    );
    // THE VALUE POSITION, and the reason this asks `ownedMoveSource` rather
    // than `placeOf`. A first version used `placeOf`, which returns null for a
    // match, and so refused the direct form while accepting this one: the same
    // program wearing a branch. This is the shape that measured exit 134.
    try expectDiagnostics(
        \\pub fn make() -> String {
        \\    return "hello"
        \\}
        \\pub fn main() -> Int {
        \\    let owned s = make()
        \\    let arc a = match 1 { _ => s }
        \\    return 0
        \\}
    ,
        \\t.cell:6:32: error: cannot bind the place 's' reached through a branch to 'arc' binding 'a': moving an owned place into an 'arc' box is not implemented
        \\t.cell:6:32: note: R10 designs this as a move into a fresh 'arc' box, but the checker does not consume the source, so the box and the source's own drop free the same buffer; bind a fresh value to the 'arc' place, or start from an 'arc' source
        \\
    );
}

test "R10's move into arc: a whole owned String or list binding is moved at let" {
    // Implemented 2026-09-16 for this one source shape. The move is real:
    // the source is dead afterwards, exactly as after `let owned q = p`.
    try expectAccepted(
        \\pub fn f(owned p: String, owned xs: [Int]) -> Int {
        \\    let arc a = p
        \\    let arc b = xs
        \\    return 0
        \\}
    );
    try expectDiagnostics(
        \\pub fn view(shared s: String) -> Int;
        \\pub fn f(owned p: String) -> Int {
        \\    let arc a = p
        \\    return view(p)
        \\}
    ,
        \\t.cell:4:17: error: use of 'p' after it was moved
        \\t.cell:3:17: note: 'p' was moved here into the 'arc' box 'a'
        \\
    );
    // A field is still refused: a partial move into a box is not built.
    try expectRejectedWith(
        \\pub struct R { owned s: String }
        \\pub fn f(owned r: R) -> Int {
        \\    let arc a = r.s
        \\    return 0
        \\}
    , "moving an owned place into an 'arc' box is not implemented");
}

test "R10's move into arc: a whole owned String or list binding is moved at return" {
    // Implemented 2026-09-16, the second position after `let`. A local and
    // a parameter, of both boxable types, returned directly.
    try expectAccepted(
        \\pub fn from_param(owned p: String) -> arc String {
        \\    return p
        \\}
        \\pub fn from_list(owned xs: [Int]) -> arc [Int] {
        \\    return xs
        \\}
        \\pub fn from_local() -> arc String {
        \\    let owned t: String = "t"
        \\    return t
        \\}
    );
    // A conditional return followed by a use is ACCEPTED since 2026-09-17:
    // the use is only reached on the path that did not return, where `p`
    // still holds its value. This assertion used to require a refusal, which
    // was the false refusal docs/superpowers/plans/2026-09-17-early-return-divergence.md
    // fixed. That the return moves is pinned where it is observable: the
    // return's liveness record (no drop of `p` there) and
    // examples/leaks/arc_box_move.cell.
    try expectAccepted(
        \\pub fn view(shared s: String) -> Int;
        \\pub fn f(copy c: Int, owned p: String) -> arc String {
        \\    if c > 0 {
        \\        return p
        \\    }
        \\    let n = view(p)
        \\    return "x"
        \\}
    );
    // Every other source keeps the refusal: a field, an `Int?`, a block tail
    // (its binding is block-scoped and that box path was not built), and a
    // branch value.
    const refused = "moving an owned place into an 'arc' box is not implemented";
    try expectRejectedWith(
        \\pub struct R { owned s: String }
        \\pub fn f(owned r: R) -> arc String {
        \\    return r.s
        \\}
    , refused);
    try expectRejectedWith(
        \\pub fn f(owned p: Int?) -> arc Int? {
        \\    return p
        \\}
    , refused);
    try expectRejectedWith(
        \\pub fn f(owned p: String) -> arc String {
        \\    return { p }
        \\}
    , refused);
    try expectRejectedWith(
        \\pub fn f(owned p: String) -> arc String {
        \\    return match 1 { _ => p }
        \\}
    , refused);
}

test "R10's move into arc: a whole owned String or list binding is moved into a struct-literal arc field" {
    // Implemented 2026-09-16, the fifth position. The record's drop glue
    // releases the box (R11 row 2), so the source must be dead.
    try expectAccepted(
        \\pub struct Box {
        \\    arc s: String
        \\    arc xs: [Int]
        \\}
        \\pub fn f(owned p: String, owned ys: [Int]) {
        \\    let owned b = Box { s: p, xs: ys }
        \\}
    );
    try expectDiagnostics(
        \\pub struct Box {
        \\    arc s: String
        \\}
        \\pub fn view(shared s: String) -> Int;
        \\pub fn f(owned p: String) -> Int {
        \\    let owned b = Box { s: p }
        \\    return view(p)
        \\}
    ,
        \\t.cell:7:17: error: use of 'p' after it was moved
        \\t.cell:6:28: note: 'p' was moved here into the 'arc' field 's'
        \\
    );
    // Every other source keeps the refusal: a field, an `Int?`, a block
    // value (not opened for an `arc` field) and a branch value.
    const refused = "moving an owned place into an 'arc' box is not implemented";
    try expectRejectedWith(
        \\pub struct R { owned s: String }
        \\pub struct Box { arc s: String }
        \\pub fn f(owned r: R) {
        \\    let owned b = Box { s: r.s }
        \\}
    , refused);
    try expectRejectedWith(
        \\pub struct Opt { arc v: Int? }
        \\pub fn f(owned p: Int?) {
        \\    let owned b = Opt { v: p }
        \\}
    , refused);
    try expectRejectedWith(
        \\pub struct Box { arc s: String }
        \\pub fn f(owned p: String) {
        \\    let owned b = Box { s: { p } }
        \\}
    , refused);
    try expectRejectedWith(
        \\pub struct Box { arc s: String }
        \\pub fn f(owned p: String) {
        \\    let owned b = Box { s: match 1 { _ => p } }
        \\}
    , refused);
}

test "R10's move into arc: a whole owned String or list binding is moved at a call argument" {
    // Implemented 2026-09-16, the fourth position. The callee releases the
    // box (cell_rt.h section 7), so the caller's source must be dead, and
    // an explicit `arc` prefix on the argument is the same move.
    try expectAccepted(
        \\pub fn keep(arc s: String);
        \\pub fn keep_list(arc xs: [Int]);
        \\pub fn f(owned p: String, owned xs: [Int]) {
        \\    keep(p)
        \\    keep_list(xs)
        \\}
        \\pub fn g() {
        \\    let owned t: String = "t"
        \\    keep(arc t)
        \\}
    );
    try expectDiagnostics(
        \\pub fn keep(arc s: String);
        \\pub fn view(shared s: String) -> Int;
        \\pub fn f(owned p: String) -> Int {
        \\    keep(p)
        \\    return view(p)
        \\}
    ,
        \\t.cell:5:17: error: use of 'p' after it was moved
        \\t.cell:4:10: note: 'p' was moved here into the 'arc' box passed to 'keep'
        \\
    );
    // Every other source keeps the refusal: a field, an `Int?`, a block
    // argument (not opened for an `arc` parameter) and a branch value.
    const refused = "moving an owned place into an 'arc' box is not implemented";
    try expectRejectedWith(
        \\pub struct R { owned s: String }
        \\pub fn keep(arc s: String);
        \\pub fn f(owned r: R) {
        \\    keep(r.s)
        \\}
    , refused);
    try expectRejectedWith(
        \\pub fn keep_opt(arc v: Int?);
        \\pub fn f(owned p: Int?) {
        \\    keep_opt(p)
        \\}
    , refused);
    try expectRejectedWith(
        \\pub fn keep(arc s: String);
        \\pub fn f(owned p: String) {
        \\    keep({ p })
        \\}
    , refused);
    try expectRejectedWith(
        \\pub fn keep(arc s: String);
        \\pub fn f(owned p: String) {
        \\    keep(match 1 { _ => p })
        \\}
    , refused);
}

test "R10's move into arc: a whole owned String or list binding is moved by assignment" {
    // Implemented 2026-09-16, the third position, into a WHOLE `arc` binding.
    try expectAccepted(
        \\pub fn f(owned p: String, owned xs: [Int]) {
        \\    var arc a: String = "x"
        \\    a = p
        \\    var arc b: [Int] = [1]
        \\    b = xs
        \\}
    );
    try expectRejectedWith(
        \\pub fn view(shared s: String) -> Int;
        \\pub fn f(owned p: String) -> Int {
        \\    var arc a: String = "x"
        \\    a = p
        \\    return view(p)
        \\}
    , "use of 'p' after it was moved");
    const refused = "moving an owned place into an 'arc' box is not implemented";
    // A field target is the struct-field store, a separate position.
    try expectRejectedWith(
        \\pub struct R { arc s: String }
        \\pub fn f(owned p: String) {
        \\    var owned r = R { s: "x" }
        \\    r.s = p
        \\}
    , refused);
    try expectRejectedWith(
        \\pub fn f(owned p: String) {
        \\    var arc a: String = "x"
        \\    a = { p }
        \\}
    , "not implemented");
    try expectRejectedWith(
        \\pub fn f(owned p: String) {
        \\    var arc a: String = "x"
        \\    a = match 1 { _ => p }
        \\}
    , refused);
    try expectRejectedWith(
        \\pub fn mk() -> Int?;
        \\pub fn f(owned p: Int?) {
        \\    var arc a = mk()
        \\    a = p
        \\}
    , refused);
}

test "R10's other direction leaves every legal arc source alone" {
    // The refusal is narrow by construction, and each of these was verified to
    // COMPILE and run, not merely to pass the checker. Over-refusing here
    // would reject the shape every existing arc test is written in.
    //
    // A fresh value: what `emitArcConversion` already boxes correctly.
    try expectAccepted(
        \\pub fn make() -> String {
        \\    return "hello"
        \\}
        \\pub fn f() -> Int {
        \\    let arc a = make()
        \\    return 0
        \\}
    );
    // An `arc` source: the legal arc-to-arc retain, R10's first table row.
    try expectAccepted(
        \\pub fn f(arc p: String) -> Int {
        \\    let arc a = p
        \\    return 0
        \\}
    );
    // A `shared` source: a view, which `cell_arc_from_string(
    // cell_string_from_str(p))` COPIES rather than aliases, so there is no
    // second owner and nothing for this rule to refuse.
    try expectAccepted(
        \\pub fn f(shared p: String) -> Int {
        \\    let arc a = p
        \\    return 0
        \\}
    );
    // A branch whose arms are fresh values stays accepted: the value position
    // is peeled to ask about the SOURCE, not refused for being a branch.
    try expectAccepted(
        \\pub fn make() -> String {
        \\    return "hello"
        \\}
        \\pub fn f(copy c: Int) -> Int {
        \\    let arc a = match c { _ => make() }
        \\    return 0
        \\}
    );
}

test "R10 refuses only the owned conversion, not the arc binding itself" {
    // The guard must not swallow what builds an `arc [T]` in the first place.
    try expectAccepted(
        \\pub fn read(shared xs: [Int]) -> Int;
        \\pub fn main() {
        \\    let arc xs = [1, 2, 3]
        \\    let copy n = read(shared xs)
        \\}
    );
}

test "R10 leaves a non-arc owned argument moving exactly as before" {
    // The refusal sits in front of `movePlace`, so the move path it guards
    // has to still fire for every other ownership mode.
    try expectDiagnostics(prelude ++
        \\pub fn f() {
        \\    let owned b = Buffer { data: [], len: 0 }
        \\    take(b)
        \\    take(b)
        \\}
    ,
        \\t.cell:12:10: error: use of 'b' after it was moved
        \\t.cell:11:10: note: 'b' was moved here by the call to 'take'
        \\
    );
}

test "R10 axis 2, the arc SOURCE: a call result typed 'arc' is refused at every site" {
    // THE LIVE DOUBLE FREE THIS CLOSED, and it was live rather than masked.
    // `fresh() -> arc [Int]` hands back a box; the caller's temporary drops
    // it; `take(owned ...)` frees the same buffer through the unbox. Measured
    // end to end before the fix: `cell check` exit 0, `cc -Wall -Wextra
    // -Werror -fsanitize=address` exit 0, running it exit 134, with frames
    // cell_slice_free <- cell_slice_drop_glue <- cell_arc_drop <- cell_main.
    //
    // It escaped because the `arc`-ness comes from a SIGNATURE's return type
    // and not from a binding annotation, so neither the place machinery nor
    // the expression-shape widening of `23353e9` could see it. That is a
    // different axis from place-versus-value, and `23353e9`'s message claiming
    // to land "before any such change and not after" was false for it: the
    // unmasking landed in `460b9a3`, seven commits earlier, measured by
    // emitting this program at both commits.
    //
    // examples/rejected/arc_call_to_owned.cell is the corpus form.
    try expectDiagnostics(
        \\pub fn fresh() -> arc [Int];
        \\pub fn take(owned xs: [Int]) -> Int;
        \\pub fn main() {
        \\    let copy n = take(owned fresh())
        \\}
    ,
        \\t.cell:4:29: error: cannot pass 'arc' value 'fresh()' to 'owned' parameter 'xs': ownership is shared and cannot be made unique
        \\t.cell:4:29: note: an 'owned' holder frees the value, and the 'arc' box would free it again
        \\
    );
    // The `let` position. Before this it emitted no drop at all, so it was a
    // LEAK rather than a double free: an undocumented sixth leak gap, now
    // closed by refusal rather than by a release.
    try expectDiagnostics(
        \\pub fn fresh() -> arc [Int];
        \\pub fn main() {
        \\    let owned ys: [Int] = fresh()
        \\}
    ,
        \\t.cell:3:27: error: cannot bind 'arc' value 'fresh()' to 'owned' binding 'ys': ownership is shared and cannot be made unique
        \\t.cell:3:27: note: an 'owned' holder frees the value, and the 'arc' box would free it again
        \\
    );
    // Through a value position, so the two widenings compose rather than one
    // shadowing the other.
    try expectDiagnostics(
        \\pub fn fresh() -> arc [Int];
        \\pub fn take(owned xs: [Int]) -> Int;
        \\pub fn main() {
        \\    let copy c = 0
        \\    let copy n = take(owned match c { 0 => fresh(), _ => fresh() })
        \\}
    ,
        \\t.cell:5:44: error: cannot pass 'arc' value 'fresh()' to 'owned' parameter 'xs': ownership is shared and cannot be made unique
        \\t.cell:5:44: note: an 'owned' holder frees the value, and the 'arc' box would free it again
        \\
    );
}

test "R10 axis 3, the consumption SITE: a list element and a return were never asked" {
    // A list literal copies each element by value into a buffer the list owns,
    // so every element is made unique. `let owned zss: [[Int]] = [xs, xs]`
    // with an `arc [Int]` place passed `cell check` and compiled clean at
    // -Werror. It is not a use-after-free today only because slice elements
    // are never released, which is a separately disclosed gap; closing that
    // gap detonates this.
    try expectDiagnostics(
        \\pub fn main() {
        \\    let arc xs = [1, 2, 3]
        \\    let owned zss: [[Int]] = [xs, xs]
        \\}
    ,
        \\t.cell:3:31: error: cannot store 'arc' value 'xs' in an 'owned' list element: ownership is shared and cannot be made unique
        \\t.cell:3:31: note: an 'owned' holder frees the value, and the 'arc' box would free it again
        \\t.cell:3:35: error: cannot store 'arc' value 'xs' in an 'owned' list element: ownership is shared and cannot be made unique
        \\t.cell:3:35: note: an 'owned' holder frees the value, and the 'arc' box would free it again
        \\
    );
    // A `-> [Int]` return slot is `owned` by R1. This one was already refused
    // downstream, by `cc` rejecting `cell_slice_t x = cell_arc_clone(...)`,
    // which is protection by a coincidence of two C types and exactly what
    // R10's own text objects to. Refused here so the rule holds for every
    // type rather than for the types whose C spellings happen to differ.
    try expectDiagnostics(
        \\pub fn f() -> [Int] {
        \\    let arc xs = [1, 2, 3]
        \\    return xs
        \\}
    ,
        \\t.cell:3:12: error: cannot return 'arc' value 'xs' from 'owned' function 'f': ownership is shared and cannot be made unique
        \\t.cell:3:12: note: an 'owned' holder frees the value, and the 'arc' box would free it again
        \\
    );
}

test "R10 refuses a source it cannot prove is not arc, rather than permitting it" {
    // The structural point of the whole change. The classifier used to return
    // `?Place`, so any form it did not recognise fell out as `null` and was
    // PERMITTED: silence meant safe, and silence is what an unenumerated form
    // produces. Every one of the three widenings was a form that fell into
    // that default. Now an undecidable source is `.unknown` and refused.
    //
    // `cell check` also reports its own `unknown identifier` here, so no
    // program that was otherwise accepted is lost by this; what is gained is
    // that the next unenumerated form fails closed.
    try expectDiagnostics(
        \\pub fn take(owned xs: [Int]) -> Int;
        \\pub fn main() {
        \\    let copy n = take(owned nowhere())
        \\}
    ,
        \\t.cell:3:29: error: cannot pass the result of the unresolved callee 'nowhere' to 'owned' parameter 'xs': its ownership cannot be resolved here
        \\t.cell:3:29: note: R10 refuses what it cannot prove is not 'arc': an 'arc' value made unique is freed twice
        \\
    );
}

test "R10's widening does not over-refuse a call result, an arc return, or an enum variant" {
    // The controls for the three arms most likely to fail closed by accident.
    // An `owned` call result is the whole point of `owned`.
    try expectAccepted(
        \\pub fn fresh() -> [Int];
        \\pub fn take(owned xs: [Int]) -> Int;
        \\pub fn main() {
        \\    let copy n = take(owned fresh())
        \\}
    );
    // `-> arc T` returning its own `arc` local is the legal arc-to-arc case,
    // and it is what the reproducer's `fresh` is made of: refusing it would
    // have made the double free unreproducible instead of refused.
    try expectAccepted(
        \\pub fn fresh() -> arc [Int] {
        \\    let arc xs: [Int] = [1, 2, 3]
        \\    return xs
        \\}
    );
    // A qualified enum variant is a `field` whose base is an `ident` that is
    // not a binding, so `placeOf` fails on it exactly as it fails on
    // `fresh().len`. Told apart by the enum table, and found by the gate:
    // examples/pairing/geometry.body returns one, and the first draft of this
    // change refused it.
    try expectAccepted(
        \\pub enum Quadrant { First, Second }
        \\pub fn q() -> Quadrant {
        \\    return Quadrant.First
        \\}
    );
    // A plain owned place in the parameter position, the case the whole rule
    // has to keep accepting.
    try expectAccepted(
        \\pub fn take(owned xs: [Int]) -> Int;
        \\pub fn main() {
        \\    let owned xs: [Int] = [1, 2, 3]
        \\    let copy n = take(owned xs)
        \\}
    );
}

test "R10's total verdict needs a struct type inferred from a CALL, or it refuses valid code" {
    // The cost of a verdict with no permissive default: every annotation it
    // cannot resolve becomes load-bearing. `Binding.struct_name` was inferred
    // from a declared type and from a struct literal, but not from a call, so
    //
    //     let owned s = make()          // make() -> Session
    //     take(owned s.data)            // Session { owned data: [Int] }
    //
    // left `struct_name` null, `placeOwnership` returned null on the first
    // segment, and the field's plainly `owned` annotation was never read.
    // Measured: accepted at `b6aadb5`, refused after the widening, with NO
    // typecheck error alongside it, i.e. a valid program lost. `checkLet` now
    // reads the callee's return type, the same lookup `arcCallResult` does.
    try expectAccepted(
        \\pub struct Session {
        \\    owned data: [Int]
        \\    copy id: Int
        \\}
        \\pub fn make() -> Session;
        \\pub fn take(owned xs: [Int]) -> Int;
        \\pub fn main() {
        \\    let owned s = make()
        \\    let copy n = take(owned s.data)
        \\}
    );
    // The annotated form was never affected, and is here so a future change
    // that breaks only one of the two is caught rather than half-caught.
    try expectAccepted(
        \\pub struct Session {
        \\    owned data: [Int]
        \\    copy id: Int
        \\}
        \\pub fn make() -> Session;
        \\pub fn take(owned xs: [Int]) -> Int;
        \\pub fn main() {
        \\    let owned s: Session = make()
        \\    let copy n = take(owned s.data)
        \\}
    );
    // Resolving the type is not the same as permitting the field, and this is
    // the direction that matters: an `arc` field reached through an
    // unannotated `let` is now REFUSED where the old permissive default let it
    // through, so the inference strengthens the rule rather than widening a
    // hole in it.
    try expectDiagnostics(
        \\pub struct Session {
        \\    arc name: String
        \\    copy id: Int
        \\}
        \\pub fn make() -> Session;
        \\pub fn take_str(owned s: String) -> Int;
        \\pub fn main() {
        \\    let owned s = make()
        \\    let copy n = take_str(owned s.name)
        \\}
    ,
        \\t.cell:9:33: error: cannot pass 'arc' value 's.name' to 'owned' parameter 's': ownership is shared and cannot be made unique
        \\t.cell:9:33: note: an 'owned' holder frees the value, and the 'arc' box would free it again
        \\
    );
}

test "R2.b: a value shape reaching an owned position was READ, not moved, and double freed" {
    // THE DEFECT. R2 enumerates the forms that move a PLACE, and every one of
    // its consumption sites asked `placeOf` first: a place moved, and anything
    // else fell through to `checkExpr`, which only reads. A `match` is not a
    // place, so
    //
    //     let owned s2: String = match c { 0 => s1, _ => s1 }
    //
    // read `s1`. `wasMoved(s1)` stayed false, codegen's `pendingDrops` kept
    // BOTH `s1` and `s2`, and `emitValueInto`'s leaf emitted a bitwise
    // `_cell_t0 = s1;`, so two headers held one buffer. Measured end to end
    // against `zig-out/bin/cell` built at `0e82266`:
    //
    //     cell check                  exit 0
    //     cc -fsanitize=address       exit 0
    //     running it                  exit 134
    //     AddressSanitizer: attempting double-free, under cell_string_free
    //
    // This has nothing to do with `arc`: it is ordinary `owned String` code,
    // and it predates every line of the `arc` work. It is R10 axis 1 in the
    // general rule R10 is a special case of.
    try expectDiagnostics(
        \\pub fn mk() -> String;
        \\pub fn main() {
        \\    var copy c = 0
        \\    let owned s1 = mk()
        \\    let owned s2: String = match c { 0 => s1, _ => s1 }
        \\}
    ,
        \\t.cell:5:43: error: cannot bind the place 's1' reached through a branch to 'owned' binding 's2': which owned place it gives up cannot be resolved here
        \\t.cell:5:43: note: R2 moves a place, not a value that may yield one on some paths and not others; bind the value to a name first, or produce a fresh value on every path
        \\
    );
}

test "R2.b is asked at all six owned consumption sites, four of which were live" {
    // FOUR of these were AddressSanitizer double frees at exit 134, measured
    // at `0e82266` with the same `mk() -> String` and the same `match`: the
    // `let` above, the assignment, the call argument and the return. The
    // opening brief named the `let`, the assignment, the struct field and the
    // list element; the call argument and the return are the two it did not
    // name and both were live. That is this repository's recurring
    // undercount, so the sites are enumerated in a test rather than in prose.
    //
    // The remaining two are latent for reasons that belong to other gaps and
    // are refused with the rest rather than left as traps for closing them:
    // a `record` shape is never dropped, and slice elements are never
    // released (OWNERSHIP.md R11).
    try expectDiagnostics(
        \\pub fn mk() -> String;
        \\pub fn main() {
        \\    var copy c = 0
        \\    let owned s1 = mk()
        \\    var owned s2: String = mk()
        \\    s2 = match c { 0 => s1, _ => s1 }
        \\}
    ,
        \\t.cell:6:25: error: cannot assign the place 's1' reached through a branch to 'owned' place 's2': which owned place it gives up cannot be resolved here
        \\t.cell:6:25: note: R2 moves a place, not a value that may yield one on some paths and not others; bind the value to a name first, or produce a fresh value on every path
        \\
    );
    try expectDiagnostics(
        \\pub fn mk() -> String;
        \\pub fn take(owned s: String);
        \\pub fn main() {
        \\    var copy c = 0
        \\    let owned s1 = mk()
        \\    take(owned match c { 0 => s1, _ => s1 })
        \\}
    ,
        \\t.cell:6:31: error: cannot pass the place 's1' reached through a branch to 'owned' parameter 's': which owned place it gives up cannot be resolved here
        \\t.cell:6:31: note: R2 moves a place, not a value that may yield one on some paths and not others; bind the value to a name first, or produce a fresh value on every path
        \\
    );
    try expectDiagnostics(
        \\pub fn mk() -> String;
        \\pub fn pick(copy c: Int) -> String {
        \\    let owned s1 = mk()
        \\    return match c { 0 => s1, _ => s1 }
        \\}
    ,
        \\t.cell:4:27: error: cannot return the place 's1' reached through a branch from 'owned' function 'pick': which owned place it gives up cannot be resolved here
        \\t.cell:4:27: note: R2 moves a place, not a value that may yield one on some paths and not others; bind the value to a name first, or produce a fresh value on every path
        \\
    );
    try expectDiagnostics(
        \\pub struct Box { owned items: [Int] }
        \\pub fn fresh() -> [Int];
        \\pub fn main() {
        \\    var copy c = 0
        \\    let owned xs: [Int] = fresh()
        \\    let owned b = Box { items: match c { 0 => xs, _ => xs } }
        \\}
    ,
        \\t.cell:6:47: error: cannot store the place 'xs' reached through a branch in owned field 'items': the source is not a fresh owned value
        \\t.cell:6:47: note: aggregate ownership transfer is not implemented; construct a fresh field value instead
        \\
    );
    try expectDiagnostics(
        \\pub fn fresh() -> [Int];
        \\pub fn main() {
        \\    var copy c = 0
        \\    let owned xs: [Int] = fresh()
        \\    let owned zss: [[Int]] = [match c { 0 => xs, _ => xs }]
        \\}
    ,
        \\t.cell:5:46: error: cannot store the place 'xs' reached through a branch in an 'owned' list element: which owned place it gives up cannot be resolved here
        \\t.cell:5:46: note: R2 moves a place, not a value that may yield one on some paths and not others; bind the value to a name first, or produce a fresh value on every path
        \\
    );
}

test "R2.b covers an if branch and a block tail, which typecheck alone would hide" {
    // Neither reaches a typed `owned` position through `cell check` today:
    // typecheck gives an `if`-expression and a block the type `()` and
    // refuses the initializer first. Measured, both of them. That is an
    // ACCIDENT of the type checker rather than enforcement of this rule, and
    // R10's own text objects to a rule enforced by a coincidence of two
    // types. Borrowck runs independently of typecheck, so its own tests reach
    // both forms and pin them on their own merits.
    try expectDiagnostics(
        \\pub fn mk() -> String;
        \\pub fn main() {
        \\    var copy c = 0
        \\    let owned s1 = mk()
        \\    let owned s2 = if c == 0 { s1 } else { s1 }
        \\}
    ,
        \\t.cell:5:32: error: cannot bind the place 's1' reached through a branch to 'owned' binding 's2': which owned place it gives up cannot be resolved here
        \\t.cell:5:32: note: R2 moves a place, not a value that may yield one on some paths and not others; bind the value to a name first, or produce a fresh value on every path
        \\
    );
    // CHANGED 2026-09-15: the block half is no longer refused. A block is
    // ONE path, so its tail always evaluates and `s1` is moved through it
    // (`openBlockTail`); the branch reasoning above is for `if`
    // and `match`, whose taken arm is unknown. The test "a block tail naming
    // an OUTER owned place moves it" proves the move is recorded, by using
    // `x` afterwards and getting a use-after-move.
    try expectAccepted(
        \\pub fn mk() -> String;
        \\pub fn main() {
        \\    let owned s1 = mk()
        \\    let owned s2 = { s1 }
        \\}
    );
    // An `owned` keyword in front of the value does not get around it.
    // `placeOf` already peels `.annotated`, so this arm adds no move that
    // `placeOf` was not already making: `let owned s2: String = owned s1`
    // already reported use-after-move at `0e82266`, and it still does (the
    // control below). Only the value shape underneath is new.
    try expectDiagnostics(
        \\pub fn mk() -> String;
        \\pub fn main() {
        \\    var copy c = 0
        \\    let owned s1 = mk()
        \\    let owned s2: String = owned match c { 0 => s1, _ => s1 }
        \\}
    ,
        \\t.cell:5:49: error: cannot bind the place 's1' reached through a branch to 'owned' binding 's2': which owned place it gives up cannot be resolved here
        \\t.cell:5:49: note: R2 moves a place, not a value that may yield one on some paths and not others; bind the value to a name first, or produce a fresh value on every path
        \\
    );
}

test "R2.b moves bindings but owning resource fields refuse place transfers" {
    // THE OVER-REFUSAL CONTROLS. The fix refuses; the risk of a refusal is
    // that it refuses everything, and the risk of routing a move decision
    // through a new classifier is that the move stops happening. This is what
    // proves the move still happens: `s1` is moved, so reading it afterwards
    // is R2's use-after-move. If `ownedMoveSource` ever returned
    // `.no_owned_place` for a plain place, this test would report nothing and
    // codegen's `pendingDrops` would free the buffer twice, which is the
    // defect this whole rule exists to close, reintroduced by its own fix.
    try expectDiagnostics(
        \\pub fn mk() -> String;
        \\pub fn use_it(shared s: String) -> Int;
        \\pub fn main() {
        \\    let owned s1 = mk()
        \\    let owned s2: String = s1
        \\    let copy n = use_it(shared s1)
        \\}
    ,
        \\t.cell:6:32: error: use of 's1' after it was moved
        \\t.cell:5:28: note: 's1' was moved here by binding it to 's2'
        \\
    );
    // A `match` whose arms are all fresh values owns nothing an existing
    // binding still holds, so it is accepted. This is the common shape and
    // refusing it would have made `match` unusable as an initializer.
    try expectAccepted(
        \\pub fn mk() -> String;
        \\pub fn main() {
        \\    var copy c = 0
        \\    let owned s2: String = match c { 0 => mk(), _ => mk() }
        \\}
    );
    // Scalar arms, the same claim one type down.
    try expectAccepted(
        \\pub fn main() {
        \\    var copy c = 0
        \\    let owned n: Int = match c { 0 => 1, _ => 2 }
        \\}
    );
    // Aggregate ownership transfer is absent, so a resource-bearing owned
    // field refuses a place rather than copying its owning header: the copy
    // would leave two owners of one buffer. Scope-end release of a record's
    // UNMOVED fields exists (`moved_paths`), but it cannot make that safe.
    try expectDiagnostics(
        \\pub struct Box { owned s: String }
        \\pub fn mk() -> String;
        \\pub fn main() {
        \\    let owned s1 = mk()
        \\    let owned b: Box = Box { s: s1 }
        \\}
    ,
        \\t.cell:5:33: error: cannot store s1 in owned field 's': moving a place into an aggregate is not implemented
        \\t.cell:5:33: note: aggregate ownership transfer is not implemented; construct a fresh field value instead
        \\
    );
    // List-element transfer WAS a disclosed boundary and is now refused.
    // This program was accepted until R2's list-element clause landed, on the
    // argument that slice elements are never released. That argument covered
    // the wrong half: the defect is the SOURCE's release, not the element's.
    // `xs` keeps its own header, `cell_slice_free(&xs)` runs at its scope end,
    // and `zss`'s element is left pointing at the freed buffer. The same shape
    // one type down was measured under AddressSanitizer at `76128ba` and
    // reported `heap-use-after-free`; see `refuseListElementMove`.
    try expectDiagnostics(
        \\pub fn fresh() -> [Int];
        \\pub fn main() {
        \\    let owned xs: [Int] = fresh()
        \\    let owned zss: [[Int]] = [xs]
        \\}
    ,
        \\t.cell:4:31: error: cannot store 'xs' in an 'owned' list element: a list literal copies the element's header by value and the source keeps its own
        \\t.cell:4:31: note: the source is released at its scope end while the list still holds the same buffer; build the element from a fresh value instead
        \\
    );
}

test "R2.b over-refuses a match over copy places, and the workaround is a name" {
    // NAMED RATHER THAN LEFT TO BE DISCOVERED. This program was accepted at
    // `0e82266`, runs clean, and is now REFUSED:
    //
    //     pub fn pick(copy c: Int, copy a: Int, copy b: Int) -> Int {
    //         return match c { 0 => a, _ => b }
    //     }
    //
    // A `copy` place is exempt from R2 by R12 and `pendingDrops` never drops
    // one, so an exemption for it looks free. It was considered and REJECTED.
    // The exemption would be an enumeration of the ownership modes this
    // backend drops today, asserted over every `copy` place, which is exactly
    // the reasoning failure this rule is the sixteenth instance of; and the
    // neighbouring claim is already false, because `copy String` is spellable
    // and `let owned s: String = a` over one emits a shallow header copy and
    // frees `a`'s buffer through `s`. Refusing costs a program that can be
    // spelled with a name. Accepting costs a free of something still live.
    try expectDiagnostics(
        \\pub fn pick(copy c: Int, copy a: Int, copy b: Int) -> Int {
        \\    return match c { 0 => a, _ => b }
        \\}
    ,
        \\t.cell:2:27: error: cannot return the place 'a' reached through a branch from 'owned' function 'pick': which owned place it gives up cannot be resolved here
        \\t.cell:2:27: note: R2 moves a place, not a value that may yield one on some paths and not others; bind the value to a name first, or produce a fresh value on every path
        \\
    );
    // The workaround, verified rather than asserted: bind the value to a name
    // whose annotation says what it is, then hand the name over.
    try expectAccepted(
        \\pub fn pick(copy c: Int, copy a: Int, copy b: Int) -> Int {
        \\    let copy r = match c { 0 => a, _ => b }
        \\    return copy r
        \\}
    );
}

test "R12 refuses a copy place whose type owns resources, by all three routes" {
    // THE PRECONDITION FOR R11 ROW 2. Each of these three was ACCEPTED and
    // emitted a plain `cell_Box snap = buf;` (measured at `76128ba`, three
    // separate `cell emit` runs). That was harmless only while a `record` was
    // never dropped. Row 2's drop glue drops both names, which is a double
    // free of one `cell_string_t`, so the refusal has to land first.
    //
    // Route 1: a direct `copy` of an owned record.
    try expectDiagnostics(
        \\pub fn make() -> String;
        \\pub struct Box { owned s: String, copy n: Int }
        \\pub fn mk() -> Box {
        \\    let owned buf = Box { s: make(), n: 1 }
        \\    let copy snap = buf
        \\    return snap
        \\}
    ,
        \\t.cell:5:5: error: cannot declare copy binding 'snap': its type may own resources and copying its header would create two owners
        \\t.cell:5:5: note: use an 'owned' or 'arc' place, or take a 'shared' borrow; resource-bearing copy places are unsupported
        \\
    );
    // Route 2: THROUGH an exclusive borrow, which is the route a type read off
    // the initializer alone would miss -- `v` is a borrow, and what the copy
    // duplicates is its referent's header. `inferBindingType` answers with the
    // referent for exactly this case.
    try expectDiagnostics(
        \\pub fn make() -> String;
        \\pub struct Box { owned s: String, copy n: Int }
        \\pub fn mk() -> Box {
        \\    var owned buf = Box { s: make(), n: 1 }
        \\    let exclusive v = &mut buf
        \\    let copy snap = v
        \\    return snap
        \\}
    ,
        \\t.cell:6:5: error: cannot declare copy binding 'snap': its type may own resources and copying its header would create two owners
        \\t.cell:6:5: note: use an 'owned' or 'arc' place, or take a 'shared' borrow; resource-bearing copy places are unsupported
        \\
    );
    // Route 3: the parameter position. The caller is what duplicates the
    // header, so this is refused at the declaration whether or not a body
    // follows; the bodyless spelling is the second case below.
    try expectDiagnostics(
        \\pub struct Box { owned s: String, copy n: Int }
        \\pub fn f(copy b: Box) -> Box { return b }
    ,
        \\t.cell:2:1: error: cannot declare copy parameter 'b': its type may own resources and copying its header would create two owners
        \\t.cell:2:1: note: use an 'owned' or 'arc' place, or take a 'shared' borrow; resource-bearing copy places are unsupported
        \\
    );
    try expectDiagnostics(
        \\pub struct Box { owned s: String, copy n: Int }
        \\pub fn f(copy b: Box) -> Int;
    ,
        \\t.cell:2:1: error: cannot declare copy parameter 'b': its type may own resources and copying its header would create two owners
        \\t.cell:2:1: note: use an 'owned' or 'arc' place, or take a 'shared' borrow; resource-bearing copy places are unsupported
        \\
    );
    // A bare `String` reaches it too, through the call-return and the
    // source-place routes rather than through a struct name.
    try expectDiagnostics(
        \\pub fn make() -> String;
        \\pub fn main() {
        \\    let copy s = make()
        \\}
    ,
        \\t.cell:3:5: error: cannot declare copy binding 's': its type may own resources and copying its header would create two owners
        \\t.cell:3:5: note: use an 'owned' or 'arc' place, or take a 'shared' borrow; resource-bearing copy places are unsupported
        \\
    );
}

test "R12 refuses a copy binding whose type comes back through a match arm" {
    // The fourth route, and the one that was open after the other three were
    // closed: `inferBindingType` had no `.match_expr` arm, so the binding's
    // type resolved to null and `refuseResourceCopy` returned without a
    // verdict. Nothing caught it downstream either -- codegen's own inference
    // had the same hole, the temporary fell back to `int64_t`, and `cc`
    // rejected the module. That C type error was the ONLY thing standing
    // between this program and two `cell_string_t` headers over one buffer.
    try expectDiagnostics(
        \\pub fn make() -> String {
        \\    return "hello"
        \\}
        \\pub fn main() -> Int {
        \\    let owned s = make()
        \\    let copy c = match s { x => x }
        \\    return 0
        \\}
    ,
        \\t.cell:6:5: error: cannot declare copy binding 'c': its type may own resources and copying its header would create two owners
        \\t.cell:6:5: note: use an 'owned' or 'arc' place, or take a 'shared' borrow; resource-bearing copy places are unsupported
        \\
    );
    // The inference is by SHAPE and stays narrow: an arm body that is not the
    // arm's own binding still resolves through the body, so a scalar match
    // keeps being accepted rather than being swept up by the new arm.
    try expectAccepted(
        \\pub fn main() -> Int {
        \\    let copy n = 7
        \\    let copy c = match n { x => x }
        \\    return c
        \\}
    );
}

test "R12's copy clause leaves scalar places alone, which is most of the corpus" {
    // THE OVER-REFUSAL CONTROLS. A refusal keyed on a resource shape is only
    // as good as its negative answer, and every `copy` in `examples/` is one
    // of these shapes. A scalar-only record is the interesting one: it has a
    // struct name, so a rule keyed on "is it a record" rather than on the
    // shape would refuse it.
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let copy n = buf.len
        \\    let copy m = 1
        \\}
    );
    try expectAccepted(
        \\pub struct Point { copy x: Int, copy y: Int }
        \\pub fn dist(copy a: Point, copy b: Point) -> Int { return a.x - b.x }
        \\pub fn main() {
        \\    let owned p = Point { x: 1, y: 2 }
        \\    let copy q = p
        \\    let copy d = dist(copy p, copy q)
        \\}
    );
    // An `arc` binding of the same resource-bearing type is NOT refused: an
    // `arc` place retains rather than duplicating, which is R12's other half.
    try expectAccepted(
        \\pub fn make() -> String;
        \\pub fn main() {
        \\    let arc s = make()
        \\    let arc alias = s
        \\}
    );
}

test "R2 refuses an owned place in a list element, and still accepts a fresh one" {
    // The measurement behind the refusal, so the next reader does not have to
    // re-derive it: emitted at `76128ba`, `mks` freed `s` BEFORE returning the
    // list that held its header, and the caller's read reported
    // `heap-use-after-free` under AddressSanitizer with `cell_string_free` as
    // the freeing frame. A live defect for `String`, independent of R11.
    try expectDiagnostics(
        \\pub fn make() -> String;
        \\pub fn mks() -> [String] {
        \\    let owned s = make()
        \\    return [s]
        \\}
    ,
        \\t.cell:4:13: error: cannot store 's' in an 'owned' list element: a list literal copies the element's header by value and the source keeps its own
        \\t.cell:4:13: note: the source is released at its scope end while the list still holds the same buffer; build the element from a fresh value instead
        \\
    );
    // A record element is the same defect, and is what R11 row 2's drop glue
    // would otherwise have created for every record on the day it landed.
    try expectDiagnostics(
        \\pub fn make() -> String;
        \\pub struct Box { owned s: String, copy n: Int }
        \\pub fn mk() -> [Box] {
        \\    let owned buf = Box { s: make(), n: 1 }
        \\    return [buf]
        \\}
    ,
        \\t.cell:5:13: error: cannot store 'buf' in an 'owned' list element: a list literal copies the element's header by value and the source keeps its own
        \\t.cell:5:13: note: the source is released at its scope end while the list still holds the same buffer; build the element from a fresh value instead
        \\
    );
    // THE OVER-REFUSAL CONTROLS. A fresh value has no source to outlive it, a
    // scalar place owns nothing, and a `copy` place is duplicable by R12.
    try expectAccepted(
        \\pub fn make() -> String;
        \\pub fn main() {
        \\    let owned n = 3
        \\    let owned xs: [Int] = [n]
        \\    let owned ys: [String] = [make()]
        \\}
    );
    // And the block-tail local, which the watermark in the list arm exists to
    // keep: `t` is the block's VALUE, excluded from `emitValueBlockDrops`, so
    // the element is its only owner. An OUTER place reached through the same
    // block tail keeps its own header and is refused.
    try expectAccepted(block_prelude ++
        \\pub fn main() {
        \\    let owned xs: [String] = [{
        \\        let owned t = make()
        \\        t
        \\    }]
        \\}
    );
    try expectDiagnostics(block_prelude ++
        \\pub fn main() {
        \\    let owned s = make()
        \\    let owned xs: [String] = [{ s }]
        \\}
    ,
        \\t.cell:5:33: error: cannot store 's' in an 'owned' list element: a list literal copies the element's header by value and the source keeps its own
        \\t.cell:5:33: note: the source is released at its scope end while the list still holds the same buffer; build the element from a fresh value instead
        \\
    );
}

test "R7 refuses a match-arm alias in a list element, the other half of R2's list clause" {
    // The advisor caught this after the `.place` half landed: the same site
    // still read an ALIAS, on the same justification the `.place` half had
    // just retracted. Measured before the fix, `cell check` accepted this and
    // the caller's read reported heap-use-after-free under AddressSanitizer,
    // with `cell_string_free` on the scrutinee as the freeing frame.
    try expectDiagnostics(
        \\pub fn make() -> String;
        \\pub fn f() -> [String] {
        \\    let owned s = make()
        \\    return match s { x => [x] }
        \\}
    ,
        \\t.cell:4:28: error: cannot store the match binding 'x' aliasing 's' in an 'owned' list element: the scrutinee still owns the value
        \\t.cell:4:28: note: R7 does not move the scrutinee yet, so a match binding is an alias and not a second owner; consuming it frees a buffer the scrutinee's own drop frees again
        \\
    );
    // THE OVER-REFUSAL CONTROL: a fresh value in every arm is not an alias.
    try expectAccepted(
        \\pub fn make() -> String;
        \\pub fn f(copy c: Int) -> [String] {
        \\    return match c { 0 => [make()], _ => [] }
        \\}
    );
}

test "R8 accepts returning an arc, which is not a borrow" {
    try expectAccepted(
        \\pub fn share_name(arc name: String) -> arc String {
        \\    return name
        \\}
    );
}

// The three cases below pin decisions OWNERSHIP.md leaves open for a binding
// that holds a borrow rather than a value. They are separated from the
// parameter cases above because a `let exclusive e = &mut buf` is a local, so
// it takes the `mutable` path in `checkAssign` that a parameter never reaches.

test "a write through a let-bound exclusive borrow is allowed" {
    // The borrow kind grants mutability of the referent, so the `let` being
    // immutable does not block a write through it.
    try expectAccepted(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let exclusive e = &mut buf
        \\    e.len = 1
        \\    use_it(e)
        \\}
    );
}

test "rebinding a let-bound exclusive borrow still needs var" {
    // Mutability of the referent is not mutability of the binding: pointing
    // `e` at something else is an ordinary R14 immutable assignment.
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let owned other = Buffer { data: [], len: 0 }
        \\    let exclusive e = &mut buf
        \\    e = &mut other
        \\}
    ,
        \\t.cell:13:5: error: cannot assign to immutable binding 'e'
        \\t.cell:12:5: note: 'e' is declared immutable here
        \\
    );
}

test "R3: a let-bound exclusive borrow cannot be moved into an owned parameter" {
    try expectDiagnostics(prelude ++
        \\pub fn main() {
        \\    let owned buf = Buffer { data: [], len: 0 }
        \\    let exclusive e = &mut buf
        \\    take(e)
        \\}
    ,
        \\t.cell:12:10: error: cannot move out of 'e': it is an exclusive borrow, not an owner
        \\
    );
}
