//! C backend tests, last quarter in original order: returned arc fields,
//! copy and by-value bindings, String conversions, and Result layout.

const std = @import("std");
const ast = @import("../ast.zig");
const cg_helpers = @import("helpers.zig");
const cg_tests_support = @import("tests_support.zig");
const isNamedLoan = cg_helpers.isNamedLoan;
const scalarSlug = cg_helpers.scalarSlug;
const lexer = cg_tests_support.lexer;
const parser = cg_tests_support.parser;
const emitSource = cg_tests_support.emitSource;
const expectContains = cg_tests_support.expectContains;
const fnDef = cg_tests_support.fnDef;
const expectCompiles = cg_tests_support.expectCompiles;
const expectAbsent = cg_tests_support.expectAbsent;
const expectLineBefore = cg_tests_support.expectLineBefore;
const expectOccurrences = cg_tests_support.expectOccurrences;
const expectBefore = cg_tests_support.expectBefore;

test "a returned arc field survives the caller releasing it, compiled and run" {
    // The execution counterpart to the two emitted-text field tests. It is
    // the one that would have caught the defect: the bare `return s->name;`
    // compiled clean under `-Wall -Wextra -Werror` and passed `cell check`,
    // so only running it and reading the count back distinguishes a correct
    // retain from a missing one.
    //
    // The printed 4 decomposes as: `label` boxes the literal (1); the struct
    // literal clones it into the `arc` field (2); `peek` returns
    // `cell_arc_clone(s->name)` (3); the call site clones again for the
    // `arc` parameter (4), which is the count the host reports before
    // releasing its own reference (3). Delete the field retain and this
    // program prints 3, measured on a deliberately broken binary rather
    // than predicted.
    //
    // Two things this program does NOT show, stated because the number
    // alone invites the wrong conclusion from both. It does not show a
    // crash: broken, it still exits 0 and AddressSanitizer stays silent,
    // because nothing dereferences the record's now-dangling field
    // afterwards. Reaching the actual use-after-free takes a second `peek`
    // (see the task report's F4). And when this was written it did not show
    // a clean heap either: the record's own reference was never released,
    // since this backend did not drop a `record` shape, so the program ended
    // with the box alive at count 1. Since 2026-09-15 row 2's glue releases
    // it and `examples/arc_return_field.cell` measures 0 on both witnesses
    // under the gate's recipe; the sentence is kept because it is why
    // `examples/arc.cell` rather than this test carries the zero-leak
    // evidence. It is also the correct side of the asymmetry: before the
    // retain, the same program left the record pointing at a box the
    // caller had already freed.
    var e = try emitSource(
        \\pub struct Session {
        \\  arc name: String
        \\  copy id: Int
        \\}
        \\pub fn print_int(copy value: Int);
        \\pub fn observe(arc name: String) -> Int;
        \\pub fn peek(shared s: Session) -> arc String {
        \\  return s.name
        \\}
        \\pub fn main() {
        \\  let arc label = "session"
        \\  let owned sess = Session { name: label, id: 1 }
        \\  let arc got = peek(shared sess)
        \\  let copy n = observe(arc got)
        \\  print_int(n)
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "return cell_arc_clone(s->name);");

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
            "emitted program did not exit cleanly:\nstdout:\n{s}\nstderr:\n{s}\n",
            .{ run_result.stdout, run_result.stderr },
        );
        return error.ProgramCrashed;
    }
    try std.testing.expectEqualStrings("4\n", run_result.stdout);
}

test "arc values flowing through if and match branches balance, compiled and run" {
    // The execution counterpart to the two value-position tests. Both defects
    // they cover were silent at every stage that is cheap to check: `cell
    // check` exited 0, `cc -Wall -Wextra -Werror` was silent, and only
    // running the program showed the heap-use-after-free.
    //
    // `pick` returns through a `match` arm and `main` selects through an
    // `if`, so one program exercises both value paths. Unlike the emitted-text
    // tests, this source passes `cell check` (exit 0), which is why `chosen`
    // is never passed to a typed parameter: typecheck gives EVERY
    // if-expression the type `()`, so an if-derived binding flowing into a
    // `String` parameter is rejected for an unrelated, pre-existing reason.
    // The un-annotated `let` is the form that is reachable, and it is the
    // form the defect was reported in.
    //
    // The printed 2 is the strong count `observe` was handed, and it is a
    // measurement: `a` is boxed at 1, the match arm clones for the return (2),
    // `pick`'s scope drop takes it back to 1, the call site clones for the
    // `arc` parameter (2) which is what the host reports before releasing
    // (1), and the `if` branch then clones into `chosen` (2). The three scope
    // drops take both boxes to zero; verified separately under `leaks` as
    // 0 leaks for 0 total leaked bytes and clean under ASan and UBSan.
    //
    // Remove the match-arm clone and `pick` returns a box it already freed.
    // Remove the if-branch clone and `chosen` aliases `got`, so the scope
    // drops release the same box twice. Either way this aborts instead of
    // printing, which is what `error.ProgramCrashed` reports.
    var e = try emitSource(
        \\pub fn print_int(copy value: Int);
        \\pub fn observe(arc name: String) -> Int;
        \\pub fn pick(shared c: Int) -> arc String {
        \\  let arc a = "aaa"
        \\  return match c {
        \\    0 => a,
        \\    _ => a
        \\  }
        \\}
        \\pub fn main() {
        \\  let arc got = pick(shared 0)
        \\  let copy n = observe(arc got)
        \\  let arc other = "bbb"
        \\  let arc chosen = if (1 > 0) { got } else { other }
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
            "emitted program did not exit cleanly (an unretained alias aborts here):\nstdout:\n{s}\nstderr:\n{s}\n",
            .{ run_result.stdout, run_result.stderr },
        );
        return error.ProgramCrashed;
    }
    try std.testing.expectEqualStrings("2\n", run_result.stdout);
}

test "a returned arc match-arm binding survives its scrutinee's release, run" {
    // The execution counterpart to the two block-arm-body tests. Without the
    // retain this aborts: `cell_arc_drop(s)` takes the box to zero and the
    // caller then clones a freed handle, which is where AddressSanitizer
    // reported the heap-use-after-free.
    //
    // The printed 2 is a measurement. `s` is boxed at 1, the arm binding is a
    // bitwise copy of it, the return clones (2), `f`'s scope drop of `s`
    // takes it back to 1, the call site clones for the `arc` parameter (2),
    // which is what the host reports before releasing (1), and `got`'s scope
    // drop takes it to zero.
    var e = try emitSource(
        \\pub fn observe(arc name: String) -> Int;
        \\pub fn print_int(copy value: Int);
        \\pub fn f() -> arc String {
        \\  let arc s = "aaa"
        \\  match s { b => { return b } }
        \\  return s
        \\}
        \\pub fn main() {
        \\  let arc got = f()
        \\  let copy n = observe(arc got)
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
            "emitted program did not exit cleanly (an unretained arm binding aborts here):\nstdout:\n{s}\nstderr:\n{s}\n",
            .{ run_result.stdout, run_result.stderr },
        );
        return error.ProgramCrashed;
    }
    try std.testing.expectEqualStrings("2\n", run_result.stdout);
}

test "an unbound arc temporary's release balances, compiled and run under ASan" {
    // The execution counterpart to the hoist tests above, and the one that
    // covers BOTH directions of the asymmetry in one program, because
    // neither emitted text nor a single tool covers both.
    //
    //   OVER-DROP is caught by AddressSanitizer. `inspect(shared fresh())`
    //   holds the only reference to its box, so a drop emitted before the
    //   call rather than after it takes the count to zero and
    //   `cell_string_as_str`'s result points at freed characters. That is a
    //   heap-use-after-free, and it is the failure this whole change had to
    //   avoid.
    //
    //   UNDER-DROP is caught by the printed number. `dup(arc a)` clones at
    //   the call site and returns its own parameter, so the hoisted handle
    //   is the second reference to `a`'s box. If the hoist's release is
    //   missing, the count never comes back down and the `observe` that
    //   follows reports 3 instead of 2, printing 13 instead of 12.
    //
    // The 12 decomposes as 5 + 5 + 2: "boxed" and "count" are both five
    // characters, and `cell_observe` returns the strong count it was handed,
    // which is the caller's one reference plus its own call-site retain.
    // AddressSanitizer on macOS does not detect leaks, so the leak numbers
    // for this shape stay a `leaks` measurement outside the test suite.
    var e = try emitSource(
        \\pub fn print_int(copy value: Int);
        \\pub fn observe(arc name: String) -> Int;
        \\pub fn inspect(shared name: String) -> Int;
        \\pub fn dup(arc n: String) -> arc String {
        \\  return n
        \\}
        \\pub fn fresh() -> arc String {
        \\  let arc s = "boxed"
        \\  return s
        \\}
        \\pub fn main() {
        \\  let arc a = "count"
        \\  let copy w = inspect(shared fresh())
        \\  let copy x = inspect(shared dup(arc a))
        \\  let copy y = observe(arc a)
        \\  print_int(w + x + y)
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_arc_t _cell_t2 = cell_fresh();");
    try expectContains(e.text, "cell_arc_t _cell_t4 = cell_dup(cell_arc_clone(a));");

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
        .argv = &.{
            "cc", "-std=c11",                     "-Wall",  "-Wextra", "-Werror",
            "-g", "-fsanitize=address,undefined", "body.c", host_c,    rt_c,
            "-I", include,                        "-o",     "body",
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
            "the hoisted arc temporary's release is unsafe (ASan reports a use-after-free when the drop runs before the call):\nstdout:\n{s}\nstderr:\n{s}\n",
            .{ run_result.stdout, run_result.stderr },
        );
        return error.ProgramCrashed;
    }
    try std.testing.expectEqualStrings("12\n", run_result.stdout);
}

// ── `let` bindings: the annotation decides, not the initializer's shape ──
//
// FIVE MISCOMPILES LIVED IN ONE MISSING QUESTION, and `letType`'s doc comment
// says which. The tests below pin the answer at the level the defects lived
// at, the emitted DECLARATION, plus one that runs a program because the
// String case is a double free rather than a wrong number and no text
// comparison can tell those apart.
//
// The corpus half is examples/let_binding_modes.cell (records, all three
// backends, a host that counts distinct addresses because a `shared` copy has
// no other observable) and examples/let_binding_owning.cell (String and [T],
// C only). Measured against the ea36e3d compiler, the first prints 44241 in C
// where LLVM and MLIR print 14242, and the second aborts under
// AddressSanitizer at exit 134 with `attempting double-free`.

test "an unannotated string-literal list builds the owning element the declared path builds" {
    // F2 (2026-09-22): `let owned ss = ["ab", "c"]` passes `cell check` as
    // `[String]`, and a `shared [String]` reader walks 24-byte owning
    // elements, so a 16-byte view buffer is a silent miscompile. Both
    // spellings must emit the same allocation and the same conversion.
    var e = try emitSource(
        \\pub fn lens(shared xs: [String]) -> Int;
        \\pub fn annotated() -> Int {
        \\  let owned ss: [String] = ["ab", "c"]
        \\  return lens(ss)
        \\}
        \\pub fn inferred() -> Int {
        \\  let owned ss = ["ab", "c"]
        \\  return lens(ss)
        \\}
    );
    defer e.deinit();
    try expectCompiles(e.text);
    const a = try fnDef(e.text, "annotated");
    const b = try fnDef(e.text, "inferred");
    try expectContains(a, "cell_slice_alloc(sizeof(cell_string_t), 2)");
    try expectContains(b, "cell_slice_alloc(sizeof(cell_string_t), 2)");
    try expectContains(b, "cell_string_from_str(cell_str_from_parts(\"ab\", 2))");
    try expectAbsent(b, "sizeof(cell_str_t)");
}

test "an unannotated string-literal list reads back its lengths, compiled and run" {
    // The execution twin of the text pin above: the host walks the buffer
    // as `cell_string_t` and sums `.len`. Broken, this printed 2256 for
    // one call's worth of garbage strides; the answer is 3.
    var e = try emitSource(
        \\pub fn print_int(copy value: Int);
        \\pub fn lens(shared xs: [String]) -> Int;
        \\pub fn main() {
        \\  let owned ss = ["ab", "c"]
        \\  print_int(lens(ss))
        \\}
    );
    defer e.deinit();

    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "body.c", .data = e.text });
    try tmp.dir.writeFile(io, .{ .sub_path = "host.c", .data =
        \\#include "cell_rt.h"
        \\int64_t cell_lens(cell_slice_t xs) {
        \\    const cell_string_t *p = xs.ptr;
        \\    int64_t s = 0;
        \\    for (size_t i = 0; i < xs.len; i++) s += (int64_t)p[i].len;
        \\    return s;
        \\}
        \\
    });

    var cwd_buf: [4096]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const root = cwd_buf[0..cwd_len];
    const include = try std.fmt.allocPrint(gpa, "{s}/runtime", .{root});
    defer gpa.free(include);
    const rt_c = try std.fmt.allocPrint(gpa, "{s}/runtime/cell_rt.c", .{root});
    defer gpa.free(rt_c);

    const cc_result = try std.process.run(gpa, io, .{
        .argv = &.{ "cc", "-std=c11", "-Wall", "-Wextra", "body.c", "host.c", rt_c, "-I", include, "-o", "body" },
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
        std.debug.print("emitted program did not exit cleanly:\nstdout:\n{s}\nstderr:\n{s}\n", .{ run_result.stdout, run_result.stderr });
        return error.ProgramCrashed;
    }
    try std.testing.expectEqualStrings("3\n", run_result.stdout);
}

test "every unique-borrow spelling in a let initializer binds the lender" {
    // examples/borrows.cell declares these five identical, and
    // write_through.cell pins that for the ARGUMENT position. A `let`
    // initializer used to break the group in two: `exclusive buf` emitted a
    // COPY and `exclusive &buf` emitted a const pointer whose qualifier the
    // next call discarded.
    var e = try emitSource(
        \\pub struct Buffer { copy len: Int }
        \\pub fn grow(exclusive b: Buffer);
        \\pub fn main() {
        \\  var owned buf = Buffer { len: 1 }
        \\  let exclusive e1 = exclusive buf
        \\  grow(exclusive e1)
        \\  let exclusive e2 = &mut buf
        \\  grow(exclusive e2)
        \\  let exclusive e3 = &var buf
        \\  grow(exclusive e3)
        \\  let exclusive e4 = &exclusive buf
        \\  grow(exclusive e4)
        \\  let exclusive e5 = exclusive &buf
        \\  grow(exclusive e5)
        \\}
    );
    defer e.deinit();
    for ([_][]const u8{ "e1", "e2", "e3", "e4", "e5" }) |name| {
        var buf: [64]u8 = undefined;
        try expectContains(e.text, try std.fmt.bufPrint(&buf, "cell_Buffer *{s} = &buf;", .{name}));
    }
    // The two that were wrong, spelled out so a regression names itself.
    try expectAbsent(e.text, "cell_Buffer e1 = buf;");
    try expectAbsent(e.text, "const cell_Buffer *e5");
}

test "every shared spelling in a let initializer binds the lender" {
    // `let shared s = buf` emitted `cell_Buffer s = buf;`, a copy, while
    // `let shared s = &buf` emitted the pointer. borrowck creates one
    // identical shared loan for both (`checkLetInit`), so the split was the
    // backend's alone. It is invisible to any Cell-side read, because Cell
    // forbids mutating a lender while it is shared-borrowed: only the address
    // the callee is handed can tell a copy from a reference, which is what
    // examples/let_binding_modes.cell's host counts.
    var e = try emitSource(
        \\pub struct Buffer { copy len: Int }
        \\pub fn look(shared b: Buffer);
        \\pub fn main() {
        \\  var owned buf = Buffer { len: 1 }
        \\  let shared s1 = buf
        \\  look(shared s1)
        \\  let shared s2 = shared buf
        \\  look(shared s2)
        \\  let shared s3 = &buf
        \\  look(shared s3)
        \\}
    );
    defer e.deinit();
    for ([_][]const u8{ "s1", "s2", "s3" }) |name| {
        var buf: [64]u8 = undefined;
        try expectContains(e.text, try std.fmt.bufPrint(&buf, "const cell_Buffer *{s} = &buf;", .{name}));
    }
    try expectAbsent(e.text, "cell_Buffer s1 = buf;");
}

test "a copy binding of a live borrow is a snapshot, not a second name for it" {
    // The other direction of the same defect: a binding that is NOT a borrow
    // inherited the initializer's reference-ness, so `snap` ALIASED the lender
    // and saw every later write. `copy` means a value copy, and the LLVM
    // backend loads through, so C was the deviant one here too.
    var e = try emitSource(
        \\pub struct Buffer { copy len: Int }
        \\pub fn grow(exclusive b: Buffer);
        \\pub fn main() {
        \\  var owned buf = Buffer { len: 1 }
        \\  let exclusive v = &mut buf
        \\  let copy snap = v
        \\  grow(exclusive v)
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_Buffer snap = *v;");
    try expectAbsent(e.text, "cell_Buffer *snap = v;");
}

test "an exclusive let over an owning place binds the header, not a shallow copy" {
    // `cell_string_t` and `cell_slice_t` are OWNING headers. A shallow copy of
    // one is not a lost write, it is a second owner of the same heap buffer,
    // and the function-scope drop then frees what the callee already freed.
    // examples/let_binding_owning.cell runs this; here it is pinned at the
    // declaration for both types at once.
    var e = try emitSource(
        \\pub fn make() -> String;
        \\pub fn extend(exclusive s: String);
        \\pub fn fresh() -> [Int];
        \\pub fn push(exclusive xs: [Int]);
        \\pub fn main() {
        \\  var owned text = make()
        \\  let exclusive a = text
        \\  extend(exclusive a)
        \\  var owned xs = fresh()
        \\  let exclusive b = xs
        \\  push(exclusive b)
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_string_t *a = &text;");
    try expectContains(e.text, "cell_slice_t *b = &xs;");
    try expectAbsent(e.text, "cell_string_t a = text;");
    try expectAbsent(e.text, "cell_slice_t b = xs;");
}

test "a let whose initializer is not a place keeps the initializer's owned type" {
    // THE ASYMMETRY THIS FIX HAD TO PRESERVE, and the reason `isNamedLoan`
    // exists instead of an unconditional `applyOwnership`. `Local.ownership`'s
    // doc comment records that a `shared`/`copy` local initialized from a CALL
    // keeps the call's owned result type, and the drop pass reads the declared
    // annotation rather than the shape precisely so it can tell those apart.
    // A call result is not a place, so no loan is created and the binding is
    // NOT demoted to a `cell_str_t` view of a temporary nothing owns.
    var e = try emitSource(
        \\pub fn make() -> String;
        \\pub fn fresh() -> [Int];
        \\pub fn main() {
        \\  let copy a = make()
        \\  let shared b = make()
        \\  let copy c = fresh()
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_string_t a = cell_make();");
    try expectContains(e.text, "cell_string_t b = cell_make();");
    try expectContains(e.text, "cell_slice_t c = cell_fresh();");
    try expectAbsent(e.text, "cell_str_t b");
}

test "an arc let is answered before any dereference of the initializer" {
    // `arc` is asked first in `letType` and never reaches the deref, because
    // an `arc` is a handle by value and `applyOwnership` never makes one a
    // pointer. Pinned because moving the `arc` clause below the deref would
    // still pass every other test in this file.
    var e = try emitSource(
        \\pub fn observe(arc s: String) -> Int;
        \\pub fn main() {
        \\  let arc a = "x"
        \\  let arc b = a
        \\  let copy n = observe(arc b)
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_arc_t b = cell_arc_clone(a);");
    try expectAbsent(e.text, "cell_arc_t *b");
}

test "an exclusive String let is not a double free, run under AddressSanitizer" {
    // THE ONE THAT NEEDED RUNNING. Every other test here compares emitted
    // text, and text comparison cannot tell a wrong number from a double free.
    // Against the ea36e3d compiler this exact program aborts at exit 134 with
    // `AddressSanitizer: attempting double-free`, because `cell_string_t a =
    // text;` makes `a` and `text` two owners of one buffer: `reset` releases
    // it through `&a`, the read after that is a use after free, and the
    // function-scope `cell_string_free(&text)` frees it a second time.
    //
    // The host is written inline rather than reusing examples/arc_host.c,
    // because the operation that matters is "free the old buffer, then install
    // a new one", which is what turns a shallow copy of the header from a
    // wrong answer into a double free. A host that only appended would leave
    // the defect silent.
    var e = try emitSource(
        \\pub fn make_text() -> String;
        \\pub fn reset(exclusive s: String);
        \\pub fn text_len(shared s: String) -> Int;
        \\pub fn print_int(copy value: Int);
        \\pub fn main() {
        \\  var owned text = make_text()
        \\  let exclusive a = text
        \\  reset(exclusive a)
        \\  print_int(text_len(shared text))
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_string_t *a = &text;");

    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "body.c", .data = e.text });
    try tmp.dir.writeFile(io, .{
        .sub_path = "host.c",
        .data =
        \\#include "cell_rt.h"
        \\cell_string_t cell_make_text(void) { return cell_string_from_cstr("hi"); }
        \\void cell_reset(cell_string_t *s) {
        \\    cell_string_t bigger = cell_string_from_cstr("hello, world");
        \\    cell_string_free(s);
        \\    *s = bigger;
        \\}
        \\int64_t cell_text_len(cell_str_t s) { return (int64_t)s.len; }
        ,
    });

    var cwd_buf: [4096]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const root = cwd_buf[0..cwd_len];
    const include = try std.fmt.allocPrint(gpa, "{s}/runtime", .{root});
    defer gpa.free(include);
    const rt_c = try std.fmt.allocPrint(gpa, "{s}/runtime/cell_rt.c", .{root});
    defer gpa.free(rt_c);

    const cc_result = try std.process.run(gpa, io, .{
        .argv = &.{
            "cc", "-std=c11",                     "-Wall",  "-Wextra", "-Werror",
            "-g", "-fsanitize=address,undefined", "body.c", "host.c",  rt_c,
            "-I", include,                        "-o",     "body",
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
            "an exclusive String let is not binding the lender's header (ASan reports a double free):\nstdout:\n{s}\nstderr:\n{s}\n",
            .{ run_result.stdout, run_result.stderr },
        );
        return error.ProgramCrashed;
    }
    // 12 is "hello, world", which `reset` installed THROUGH the borrow. A copy
    // reads 2, the length of what `make_text` returned, if it survives at all.
    try std.testing.expectEqualStrings("12\n", run_result.stdout);
}

test "isNamedLoan mirrors borrowck.checkLetInit over every initializer shape" {
    // The predicate itself, asked directly, because the emission tests above
    // all go through `applyOwnership` and would still pass if this answered
    // correctly for the wrong reason. The table is `checkLetInit`'s two
    // clauses and its catch-all, and the catch-all is what makes this total:
    // an initializer shape nobody enumerated becomes a COPY, never a
    // reference.
    const arena_backing = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(arena_backing);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Case = struct {
        src: []const u8,
        own: ast.Ownership,
        want: bool,
        why: []const u8,
    };
    // Each source is a whole `let` statement; the initializer is parsed out of
    // it, so the spellings here are the ones a user actually writes.
    const cases = [_]Case{
        .{ .src = "&buf", .own = .exclusive, .want = true, .why = "clause 1, shared sigil over a place" },
        .{ .src = "&mut buf", .own = .exclusive, .want = true, .why = "clause 1, unique sigil over a place" },
        .{ .src = "exclusive &buf", .own = .exclusive, .want = true, .why = "clause 1 through an annotation" },
        .{ .src = "&buf", .own = .copy, .want = true, .why = "clause 1 does not consult the annotation" },
        .{ .src = "buf", .own = .exclusive, .want = true, .why = "clause 2, keyword over a bare place" },
        .{ .src = "exclusive buf", .own = .exclusive, .want = true, .why = "clause 2 through an annotation" },
        .{ .src = "buf", .own = .shared, .want = true, .why = "clause 2, shared" },
        .{ .src = "buf.len", .own = .shared, .want = true, .why = "a field path is a place" },
        .{ .src = "buf", .own = .copy, .want = false, .why = "copy of a place is a value" },
        .{ .src = "buf", .own = .owned, .want = false, .why = "owned of a place is a move, not a loan" },
        .{ .src = "make()", .own = .exclusive, .want = false, .why = "a call result is not a place" },
        .{ .src = "Buffer { len: 1 }", .own = .exclusive, .want = false, .why = "a struct literal is not a place" },
        .{ .src = "1 + 2", .own = .exclusive, .want = false, .why = "the catch-all is by value" },
        .{ .src = "&make()", .own = .exclusive, .want = false, .why = "clause 1 still requires a place" },
    };

    for (cases) |c| {
        const src = try std.fmt.allocPrint(arena, "pub fn f() {{ let copy x = {s} }}", .{c.src});
        var lex = lexer.Lexer.init(src, "t.cell");
        const toks = try lex.tokenizeAll(arena);
        var p = parser.Parser.init(arena, toks.items, "t.cell");
        const module = try p.parseModule();
        const body = module.items[0].kind.fn_def.body.?;
        const init_expr = body[0].kind.let.value.?;
        const got = isNamedLoan(&init_expr, c.own);
        if (got != c.want) {
            std.debug.print("\nisNamedLoan(\"{s}\", .{s}) = {}, want {} ({s})\n", .{
                c.src, @tagName(c.own), got, c.want, c.why,
            });
            return error.WrongVerdict;
        }
    }
}

test "a by-value binding of an owning header keeps the loud reference spelling" {
    // THE FOURTH DEFECT, DEMONSTRATED RATHER THAN SHIPPED. The first version of
    // the `letType` rule above derived the type from the annotation for EVERY
    // mode, which turned these three from a `cc` error into a silent double
    // free: `let owned s = &mut name` is a LOAN on borrowck's side rather than
    // a move, so the lender is still dropped, and an `owned` binding of a
    // droppable shape is dropped too. Measured at that intermediate revision,
    // all three were `AddressSanitizer: attempting double-free` at exit 134,
    // and the last of them PRINTED CORRECTLY before the change.
    //
    // Keeping the pointer is not a claim that the pointer is right. It is the
    // spelling this backend already had, and it is loud: `cell_string_free(&s)`
    // against a `cell_string_t **` is a `-Werror` error, which the gate's
    // sanitizer stage compiles at.
    //
    // NOTE, added with OWNERSHIP.md R18: the two `let owned ... = &mut ...`
    // lines below no longer pass `cell check` at all, because an `owned`
    // binding may not be initialized from a borrow. This test still emits them
    // because `emitForTest` runs the parser and this backend WITHOUT borrowck,
    // which is the point: the guard is defence in depth behind a front-end
    // refusal, and it must not be deleted on the strength of that refusal.
    // `var copy c = &mut other`, the third case, is still a legal program.
    var e = try emitSource(
        \\pub fn make_text() -> String;
        \\pub fn fresh() -> [Int];
        \\pub fn reset(exclusive s: String);
        \\pub fn main() {
        \\  var owned name = make_text()
        \\  let owned s = &mut name
        \\  var owned list = fresh()
        \\  let owned xs = &mut list
        \\  var owned other = make_text()
        \\  var copy c = &mut other
        \\  reset(exclusive c)
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_string_t *s = &name;");
    try expectContains(e.text, "cell_slice_t *xs = &list;");
    try expectContains(e.text, "cell_string_t *c = &other;");
    // The shallow copies that would be silent double frees.
    try expectAbsent(e.text, "cell_string_t s = *&name;");
    try expectAbsent(e.text, "cell_slice_t xs = *&list;");
    try expectAbsent(e.text, "cell_string_t c = *&other;");
}

test "the owning-header guard is keyed on the drop call, so records still copy" {
    // The guard's boundary, both sides in one module. A record has no drop
    // CALL (`hasDropCall`), so a by-value binding of a borrowed record is a
    // real copy and defect 3 stays fixed; a String has one, so the same
    // spelling keeps the reference. Pinned together because widening the
    // guard to every shape would silently reinstate the alias this whole
    // change removes, and narrowing it to none would reinstate the double
    // free above. Since R11 row 2 a record CAN be dropped, through
    // `needsDrop`; this guard deliberately still keys on `hasDropCall`, which
    // is why that predicate was added beside it rather than widened.
    //
    // Read this before trusting the test's second half. `emitForTest` runs
    // the lexer, the parser and the generator and NO borrowck, so `emitSource`
    // emits for a program `cell check` refuses. Since c314a0e that is this
    // program: `let copy text = &mut name` resolves through the borrow to
    // `String`, and R12's binding clause refuses it (verified with `cell
    // check`). The `Buffer` half is scalar-only and stays accepted. The String
    // half is kept, as a REJECTED program, because what it pins is the
    // generator's guard and not the front end: for the three runtime shapes
    // the guard makes a `copy` of a borrow a POINTER (`cell_string_t *text`),
    // never a header copy, so R12's refusal of it is the safe direction and
    // an over-refusal, not a soundness need. Stated in OWNERSHIP.md R12.
    var e = try emitSource(
        \\pub struct Buffer { copy len: Int }
        \\pub fn make_text() -> String;
        \\pub fn grow(exclusive b: Buffer);
        \\pub fn main() {
        \\  var owned buf = Buffer { len: 1 }
        \\  let exclusive v = &mut buf
        \\  let copy snap = v
        \\  grow(exclusive v)
        \\  var owned name = make_text()
        \\  let copy text = &mut name
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_Buffer snap = *v;");
    try expectContains(e.text, "cell_string_t *text = &name;");
}

// ── str -> owning String, the funnel (defect 10) ────────────────────────
//
// EIGHT POSITIONS, and the count is the point of the section rather than a
// heading. The defect was recorded as a table of six, and the table was
// itself an instance of the reasoning failure it recorded: two more positions
// have the same cause and appear in neither the table nor the report that
// produced it. All eight route through `emitConversion`, so what these tests
// pin is one predicate observed from eight sides, not eight fixes.
//
// The three negatives at the end are the half that matters more. Turning six
// loud `cc` errors into six silent double frees is the failure mode this
// change is one commit away from at every moment, and it has happened twice
// in this file's history.

test "row 1: a literal returned from a -> String body is copied into an owning value" {
    var e = try emitSource(
        \\pub fn f() -> String {
        \\  return "ab"
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "return cell_string_from_str(cell_str_from_parts(\"ab\", 2));");
}

test "rows 2 and 3: let owned and var owned initializers convert, and are freed once each" {
    // Both spellings in one module because they are one code path
    // (`emitStmt`'s `.let` arm handles `var` too) and pinning only one of
    // them would leave the other free to drift.
    //
    // The `expectOccurrences` half is the safety half. The conversion
    // allocates, so the local must be freed exactly once; twice is the double
    // free this whole design is arranged to avoid, and `expectContains` alone
    // cannot see the difference.
    var e = try emitSource(
        \\pub fn f() {
        \\  let owned s: String = "ab"
        \\  var owned t: String = "cd"
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_string_t s = cell_string_from_str(cell_str_from_parts(\"ab\", 2));");
    try expectContains(e.text, "cell_string_t t = cell_string_from_str(cell_str_from_parts(\"cd\", 2));");
    try expectOccurrences(e.text, "cell_string_free(&s);", 1);
    try expectOccurrences(e.text, "cell_string_free(&t);", 1);
}

test "row 4: a literal passed to an owned String parameter is copied for the callee" {
    // The callee owns and frees what it is handed (cell_rt.h section 7), so
    // handing it a view of a static literal would be a free of a non-heap
    // pointer. examples/owned_string_host.c does exactly that free, under
    // AddressSanitizer, which is what makes this more than a compile check.
    var e = try emitSource(
        \\pub fn g(owned s: String);
        \\pub fn f() {
        \\  g(owned "ab")
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_g(cell_string_from_str(cell_str_from_parts(\"ab\", 2)));");
}

test "row 5: a struct literal field of declared type String converts" {
    var e = try emitSource(
        \\pub struct B { name: String }
        \\pub fn f() {
        \\  let owned b: B = B { name: "ab" }
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, ".name = cell_string_from_str(cell_str_from_parts(\"ab\", 2))");
    // The field's buffer is freed through the record's generated glue (R11
    // row 2), never by name: `cell_string_free(&b...)` is still absent, and
    // until 2026-09-15 that absence was the whole assertion, which would have
    // kept passing after the glue landed while its comment called the field
    // unmanaged. Both halves are pinned now.
    try expectAbsent(e.text, "cell_string_free(&b");
    try expectContains(e.text, "cell_drop_B(&b);");
    try expectContains(e.text, "  cell_string_free(&r->name);\n");
}

test "row 6: an assignment's right side converts, with the only literal on the assignment" {
    // `make()` supplies the initializer on purpose. A literal there would
    // convert first and mask whether the ASSIGNMENT converts, which is how
    // this row hides.
    var e = try emitSource(
        \\pub fn make() -> String;
        \\pub fn f() {
        \\  var owned s: String = make()
        \\  s = "cd"
        \\}
    );
    defer e.deinit();
    // Since 2026-09-16 the never-moved `owned` reassignment is pre-dropped,
    // so the converted value lands in the temporary rather than straight in
    // `s`, and `s` is released twice: the old value before the store, and
    // the new one at scope end.
    try expectContains(e.text, "cell_string_t _cell_t0 = cell_string_from_str(cell_str_from_parts(\"cd\", 2));");
    try expectContains(e.text, "s = _cell_t0;");
    try expectOccurrences(e.text, "cell_string_free(&s);", 2);
}

test "row 7: a match arm writing into an owning String value slot converts" {
    // NOT IN THE RECORDED TABLE OF SIX. `inferExpr` types a `match` from its
    // FIRST arm, so the first arm's `make()` makes the slot `cell_string_t`
    // and the second arm then writes a literal into it. This reaches
    // `emitValueInto`, which is a different call site from `emitArgLike`, and
    // it was found only by asking which positions route through the funnel
    // rather than by reading the table.
    var e = try emitSource(
        \\pub fn make() -> String;
        \\pub fn f(shared c: Int) {
        \\  let owned s: String = match c {
        \\    0 => make(),
        \\    _ => "x",
        \\  }
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "= cell_string_from_str(cell_str_from_parts(\"x\", 1));");
    try expectOccurrences(e.text, "cell_string_free(&s);", 1);
}

test "row 8: the same match arm shape at a return converts" {
    var e = try emitSource(
        \\pub fn make() -> String;
        \\pub fn f(shared c: Int) -> String {
        \\  return match c {
        \\    0 => make(),
        \\    _ => "x",
        \\  }
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "= cell_string_from_str(cell_str_from_parts(\"x\", 1));");
}

test "row 7's slot type follows the first arm, so an all-literal match converts once outside" {
    // The other half of `inferExpr`'s first-arm rule, and it is a different
    // emission rather than a variation on the same one: with both arms
    // literal the SLOT is `cell_str_t`, so no arm converts and the single
    // conversion wraps the whole statement expression. Pinned because a
    // "fix" that converted per arm instead would still compile here and
    // would then allocate on a path that discards the result.
    var e = try emitSource(
        \\pub fn f(shared c: Int) {
        \\  let owned s: String = match c {
        \\    0 => "a",
        \\    _ => "x",
        \\  }
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_string_t s = cell_string_from_str(({");
    try expectOccurrences(e.text, "cell_string_from_str", 1);
    try expectOccurrences(e.text, "cell_string_free(&s);", 1);
}

test "an OWNED String place is NOT converted, and the moved pair is freed exactly once" {
    // THE TRAP, and the reason the predicate tests `have.shape == .str`
    // rather than enumerating source expressions. An owned place is already a
    // `cell_string_t`; wrapping it in `cell_string_from_str` would not even
    // type-check, and a conversion that took ownership instead would make two
    // owners of one buffer, which is exactly why `emitArcConversion` refuses
    // to BOX an owned place. borrowck moves `s` into `t`, so the pair owes
    // ONE free, and that is what is counted here.
    var e = try emitSource(
        \\pub fn make() -> String;
        \\pub fn f() {
        \\  let owned s: String = make()
        \\  let owned t: String = s
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_string_t t = s;");
    try expectAbsent(e.text, "cell_string_from_str");
    try expectOccurrences(e.text, "cell_string_free", 1);
}

test "an exclusive String destination is a pointer and is NOT converted" {
    // `exclusive String` is `cell_string_t *` and a freshly converted value
    // has no address to hand over, so this stays the loud `cc` error it is
    // today. The guard is `want.pointer`, and dropping it would emit a
    // 24-byte value where a pointer is read.
    var e = try emitSource(
        \\pub fn g(exclusive s: String);
        \\pub fn f() {
        \\  g(exclusive "ab")
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_g(cell_str_from_parts(\"ab\", 2));");
    try expectAbsent(e.text, "cell_string_from_str");
}

test "an arc value returned from a -> String body is still refused by cc" {
    // The unbox direction stays unrouted. `emitReturnValue`'s guard is on
    // `have` alone now, and this pins that widening it to cover the string
    // conversion did not also open the arc-to-owned one: docs/OWNERSHIP.md
    // R10 documents that emission as a double free, and the C type error is
    // the only thing refusing it at this layer.
    var e = try emitSource(
        \\pub fn f(arc a: String) -> String {
        \\  return a
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_string_t _cell_t0 = cell_arc_clone(a);");
    try expectAbsent(e.text, "cell_string_from_str");
}

test "a shared String parameter borrowed for a shared parameter is not converted either" {
    // The neighbouring direction, `.string` -> `.str`, which runs the other
    // way through `emitArgLike` and must be untouched by the new rule. If the
    // funnel ever answered this pair it would allocate a copy for every
    // borrow in the corpus.
    var e = try emitSource(
        \\pub fn inspect(shared v: String) -> Int;
        \\pub fn make() -> String;
        \\pub fn f() -> Int {
        \\  let owned s: String = make()
        \\  return inspect(shared s)
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_inspect(cell_string_as_str(&s))");
    try expectAbsent(e.text, "cell_string_from_str");
}

test "a copy String destination converts, and the leak that follows is pinned here" {
    // THE ONE DELIBERATE DECISION IN THIS RULE, pinned rather than left in a
    // report. `copy` means an independent value, and `cell_string_from_str`
    // is exactly the deep copy R12 asks for at a copy site, so converting is
    // right. What is missing is the drop: `pendingDrops` takes only `.owned`
    // and `.arc`, so the copy is never freed.
    //
    // That leak is not introduced here and is not about literals. `var copy s
    // = make()` leaks today for the same reason, so the choice is between a
    // deep copy that leaks and a `cc` error, and this backend's stated
    // asymmetry puts a leak on the acceptable side and a double free on the
    // other. Measured under AddressSanitizer: clean, exit 0.
    var e = try emitSource(
        \\pub fn f() {
        \\  let copy s: String = "ab"
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_string_t s = cell_string_from_str(cell_str_from_parts(\"ab\", 2));");
    try expectOccurrences(e.text, "cell_string_free", 0);
}

test "a list element is a ninth position, and it inherits the conversion by routing" {
    // THE THESIS OF THE FUNNEL, stated as a test rather than as a claim in a
    // doc comment. This position is in no table: the defect was recorded with
    // six, a value slot at a `let` and at a `return` made eight, and a
    // `[String]` element was never enumerated at any point. It converts
    // anyway, because `emitListLit` lowers each item through `emitArgLike`
    // against the DECLARED element type and `emitArgLike` asks the funnel.
    //
    // Each element is a real heap copy, and `cell_slice_free` frees the
    // buffer and not the elements, so this leaks. Same side of the same
    // asymmetry as the `copy` case above, and pre-existing: an element of an
    // `owned [String]` was never dropped by anything.
    var e = try emitSource(
        \\pub fn f() {
        \\  let owned xs: [String] = ["a", "bb"]
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "= cell_string_from_str(cell_str_from_parts(\"a\", 1));");
    try expectContains(e.text, "= cell_string_from_str(cell_str_from_parts(\"bb\", 2));");
    try expectContains(e.text, "cell_slice_alloc(sizeof(cell_string_t), 2)");
    try expectOccurrences(e.text, "cell_slice_free(&xs);", 1);
}

test "Some/None/Ok/Err lower onto the runtime constructors" {
    var e = try emitSource(
        \\pub enum E { A, B }
        \\pub fn f() -> Int {
        \\  let a: Int? = Some(1)
        \\  let b: Int? = None
        \\  let c: Int32? = Some(2)
        \\  let d: Result<Int, E> = Ok(3)
        \\  let g: Result<Int, E> = Err(E.B)
        \\  let h: Result<Byte, Int32> = Ok(4)
        \\  let i = Some(5)
        \\  return 0
        \\}
    );
    defer e.deinit();
    const f = try fnDef(e.text, "f");
    try expectContains(f, "cell_opt_i64_t a = cell_opt_i64_some(1);");
    try expectContains(f, "cell_opt_i64_t b = cell_opt_i64_none();");
    try expectContains(f, "cell_opt_i32_t c = cell_opt_i32_some(2);");
    try expectContains(f, "cell_res_i64_i32_t d = cell_res_i64_i32_ok(3);");
    try expectContains(f, "cell_res_i64_i32_t g = cell_res_i64_i32_err(cell_E_B);");
    try expectContains(f, "cell_res_byte_i32_t h = cell_res_byte_i32_ok(4);");
    try expectContains(f, "cell_opt_i64_t i = cell_opt_i64_some(5);");
    try expectCompiles(e.text);
}

test "wrap patterns test the tag and bind the payload" {
    var e = try emitSource(
        \\pub enum E { A, B }
        \\pub fn f(copy o: Int?, copy r: Result<Byte, E>) -> Int {
        \\  let copy a = match o { Some(x) => x, None => 0 }
        \\  let copy b = match r { Ok(v) => 1, Err(code) => 2 }
        \\  return a + b
        \\}
    );
    defer e.deinit();
    const f = try fnDef(e.text, "f");
    try expectContains(f, "if (_cell_t1.has_value) {");
    try expectContains(f, "int64_t x = _cell_t1.value;");
    try expectContains(f, "} else if (!_cell_t1.has_value) {");
    try expectContains(f, "if (_cell_t3.ok) {");
    try expectContains(f, "uint8_t v = _cell_t3.as.ok;");
    try expectContains(f, "cell_E code = (cell_E)_cell_t3.as.err;");
    try expectCompiles(e.text);
}

test "a Result keeps its error at full width and its payload in its own type" {
    var e = try emitSource(
        \\pub fn big(copy n: Int) -> Result<Bool, Int> {
        \\  if n > 0 {
        \\    return Ok(true)
        \\  }
        \\  return Err(5000000000)
        \\}
        \\pub fn half(copy x: Float32) -> Result<Float32, UInt16> {
        \\  return Ok(x)
        \\}
        \\pub fn get(copy r: Result<Bool, Int>) -> Int {
        \\  return match r { Ok(v) => 1, Err(e) => e }
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_res_bool_i64_t cell_big(int64_t n);");
    try expectContains(try fnDef(e.text, "big"), "return cell_res_bool_i64_err(5000000000);");
    try expectContains(try fnDef(e.text, "half"), "return cell_res_f32_u16_ok(x);");
    try expectContains(try fnDef(e.text, "get"), "int64_t e = _cell_t");
    try expectAbsent(e.text, "cell_result_t");
    try expectAbsent(e.text, "(int32_t)");
    try expectCompiles(e.text);
}

test "the C Result slugs match abi.resultMember for every scalar name" {
    const abi = @import("../abi.zig");
    const types = @import("../types.zig");
    const Pair = struct { name: []const u8, ty: types.Type };
    const pairs = [_]Pair{
        .{ .name = "Int", .ty = types.t_int },       .{ .name = "Int8", .ty = types.t_int8 },
        .{ .name = "Int16", .ty = types.t_int16 },   .{ .name = "Int32", .ty = types.t_int32 },
        .{ .name = "UInt", .ty = types.t_uint },     .{ .name = "UInt8", .ty = types.t_uint8 },
        .{ .name = "UInt16", .ty = types.t_uint16 }, .{ .name = "UInt32", .ty = types.t_uint32 },
        .{ .name = "Float", .ty = types.t_float },   .{ .name = "Float32", .ty = types.t_float32 },
        .{ .name = "Bool", .ty = types.t_bool },     .{ .name = "Byte", .ty = types.t_byte },
    };
    for (pairs) |p| {
        try std.testing.expectEqualStrings(abi.resultMember(p.ty).?.slug, scalarSlug(p.name).?);
    }
    try std.testing.expect(scalarSlug("String") == null);
}

test "a var moved on one branch is released at the end of the other" {
    var e = try emitSource(
        \\pub fn take(owned s: String);
        \\pub fn f(copy c: Int) {
        \\  var owned v: String = "a"
        \\  if c > 0 {
        \\    take(v)
        \\  } else {
        \\    c = c + 1
        \\  }
        \\}
        \\pub fn g(copy c: Int) {
        \\  var owned v: String = "a"
        \\  if c > 0 {
        \\    take(v)
        \\  }
        \\}
        \\pub fn both(copy c: Int) {
        \\  var owned v: String = "a"
        \\  if c > 0 {
        \\    take(v)
        \\  } else {
        \\    take(v)
        \\  }
        \\}
        \\pub fn neither(copy c: Int) {
        \\  var owned v: String = "a"
        \\  if c > 0 {
        \\    c = c + 1
        \\  }
        \\}
    );
    defer e.deinit();
    const f = try fnDef(e.text, "f");
    try expectOccurrences(f, "cell_string_free(&v);", 1);
    try expectLineBefore(f, "cell_string_free(&v);", "c = (c + 1);");
    const g = try fnDef(e.text, "g");
    try expectOccurrences(g, "cell_string_free(&v);", 1);
    try expectContains(g, "} else {\n    cell_string_free(&v);\n  }");
    const both = try fnDef(e.text, "both");
    try expectAbsent(both, "cell_string_free(&v);");
    const neither = try fnDef(e.text, "neither");
    try expectOccurrences(neither, "cell_string_free(&v);", 1);
    try expectCompiles(e.text);
}

test "a revived loop-local is released at a continue" {
    var e = try emitSource(
        \\pub fn take(owned s: String);
        \\pub fn f(copy n: Int) {
        \\  var i = 0
        \\  while i < n {
        \\    i = i + 1
        \\    var owned v: String = "a"
        \\    take(v)
        \\    v = "b"
        \\    if i > 0 {
        \\      continue
        \\    }
        \\  }
        \\}
    );
    defer e.deinit();
    const f = try fnDef(e.text, "f");
    try expectOccurrences(f, "cell_string_free(&v);", 2);
    try expectContains(f, "cell_string_free(&v);\n            continue;");
    try expectCompiles(e.text);
}

test "a var revived in a value block is released after the tail" {
    var e = try emitSource(
        \\pub fn take(owned s: String);
        \\pub fn f() -> Int {
        \\  let copy n = {
        \\    var owned v: String = "a"
        \\    take(v)
        \\    v = "b"
        \\    3
        \\  }
        \\  return n
        \\}
    );
    defer e.deinit();
    const f = try fnDef(e.text, "f");
    try expectOccurrences(f, "cell_string_free(&v);", 1);
    try expectBefore(f, "= 3;", "cell_string_free(&v);");
    try expectCompiles(e.text);
}

test "a revived record is released whole at scope end" {
    var e = try emitSource(
        \\pub struct Box { owned s: String }
        \\pub fn take(owned b: Box);
        \\pub fn f() {
        \\  var owned b = Box { s: "one" }
        \\  take(b)
        \\  b = Box { s: "two" }
        \\}
        \\pub fn g() {
        \\  var owned b = Box { s: "one" }
        \\  take(b)
        \\  b = Box { s: "two" }
        \\  let owned moved: String = b.s
        \\}
    );
    defer e.deinit();
    const f = try fnDef(e.text, "f");
    try expectOccurrences(f, "cell_drop_Box(&b);", 1);
    // Released after the revival, not before it: a drop ahead of the store
    // would free the buffer `take` already owns.
    try expectBefore(f, "b = (cell_Box){ .s = cell_string_from_str(cell_str_from_parts(\"two\", 3)) };", "cell_drop_Box(&b);");
    // Plan D Task 5's second half: a field moved out after the revival keeps
    // the partial path. `s` is Box's only owning field, so nothing of `b` is
    // released; the moved string is released through `moved`.
    const g = try fnDef(e.text, "g");
    try expectOccurrences(g, "cell_drop_Box(&b);", 0);
    try expectOccurrences(g, "cell_string_free(&moved);", 1);
    try expectOccurrences(g, "cell_string_free(&b.s);", 0);
    try expectCompiles(e.text);
}
