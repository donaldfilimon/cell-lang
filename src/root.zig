//! Cell language core library.
//! Blends Rust-style ownership, Swift-style ergonomics, Zig-style explicit control.
const std = @import("std");
const Io = std.Io;

pub const ast = @import("cell/ast.zig");
pub const lexer = @import("cell/lexer.zig");
pub const parser = @import("cell/parser.zig");
pub const typecheck = @import("cell/typecheck.zig");
pub const borrowck = @import("cell/borrowck.zig");
pub const dropfacts = @import("cell/dropfacts.zig");
pub const codegen = @import("cell/codegen.zig");
pub const diag = @import("cell/diag.zig");
pub const load_file = @import("cell/load.zig");
pub const hir = @import("cell/hir.zig");
pub const abi = @import("cell/abi.zig");
pub const cfg = @import("cell/cfg.zig");
pub const liveness = @import("cell/liveness.zig");
pub const llvmemit = @import("cell/llvmemit.zig");
pub const mlirmit = @import("cell/mlirmit.zig");

pub const load = load_file.load;
pub const Loaded = load_file.Loaded;
pub const classify = load_file.classify;

pub const Version = std.SemanticVersion{ .major = 0, .minor = 1, .patch = 0 };

/// Compile a Cell source buffer into an intermediate representation.
pub fn compile(allocator: std.mem.Allocator, source: []const u8, path: []const u8) !ast.Module {
    var lex = lexer.Lexer.init(source, path);
    var tokens = try lex.tokenizeAll(allocator);
    defer tokens.deinit(allocator);

    var p = parser.Parser.init(allocator, tokens.items, path);
    return try p.parseModule();
}

/// Type-check and borrow-check a parsed module, rendering every diagnostic to
/// `writer`.
///
/// `source` is the module's source buffer when the caller still has it; with it
/// each diagnostic gains the offending source line and a caret. Returns
/// `error.TypeError` once the bag has been written, so a caller can exit
/// non-zero without re-inspecting it. Borrow errors use the same exit path:
/// they are check failures, not a second CLI command.
pub fn check(
    allocator: std.mem.Allocator,
    module: *ast.Module,
    source: ?[]const u8,
    writer: *Io.Writer,
) !void {
    var tc = typecheck.Checker.init(allocator);
    defer tc.deinit();
    tc.diagnostics.source = source;
    try tc.checkModule(module);

    var bc = borrowck.Checker.init(allocator, module.path, source);
    defer bc.deinit();
    try bc.checkModule(module);

    try tc.diagnostics.printAll(writer);
    try bc.diagnostics.printAll(writer);
    if (tc.diagnostics.hasErrors() or bc.diagnostics.hasErrors()) return error.TypeError;
}

/// The code generators this compiler ships.
///
/// `c` is the original and the only one that lowers the whole language. The
/// other two are newer, go through `hir`, and are deliberately scalar-first:
/// see the module comments in `llvmemit.zig` and `mlirmit.zig` for what each
/// refuses and why. A construct a backend cannot carry produces a diagnostic
/// at its span, never plausible-looking wrong output.
pub const Target = enum { c, llvm, mlir };

/// Emit C from a checked module, targeting the runtime ABI in `cell_rt.h`.
///
/// Still lowers straight from the AST. The HIR path below is additive: it does
/// not re-seat this emitter, so the tests that pin its exact output are
/// untouched by the backends that came after it.
pub fn emit(allocator: std.mem.Allocator, module: *const ast.Module, writer: *Io.Writer) !void {
    var gen = codegen.Generator.init(allocator, writer);
    try gen.emitModule(module);
}

/// Emit for `target`, rendering any lowering diagnostic to `diag_writer`.
///
/// Returns `error.TypeError` when a backend refused part of the program, so a
/// caller exits non-zero without re-inspecting the bag, matching what `check`
/// does. NOTHING is written to `writer` in that case: a partial emit on stdout
/// becomes a truncated file that a later tool reads as if it were complete.
pub fn emitFor(
    allocator: std.mem.Allocator,
    module: *const ast.Module,
    source: ?[]const u8,
    writer: *Io.Writer,
    target: Target,
    diag_writer: *Io.Writer,
) !void {
    if (target == .c) return emit(allocator, module, writer);

    var bag: diag.Bag = .init(module.path, source);
    defer bag.deinit(allocator);

    // Emit into a buffer, not straight to `writer`. A backend that refuses
    // part of a program has usually already emitted the part before it, and
    // writing that out would leave a TRUNCATED file on disk with no marker in
    // it. `cell emit --target=mlir f.cell > out.mlir` followed by a separate
    // `mlir-opt out.mlir` would then run against a file that looks complete
    // and is not. Nothing reaches `writer` unless the whole module emitted.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var collector = Io.Writer.Allocating.fromArrayList(allocator, &buf);

    var bc = borrowck.Checker.init(allocator, module.path, source);
    defer bc.deinit();
    try bc.checkModule(module);
    if (bc.hasErrors()) {
        try bc.diagnostics.printAll(diag_writer);
        return error.TypeError;
    }
    var lowered = try hir.lowerChecked(allocator, module, &bag, bc.dropFacts());
    switch (target) {
        .c => unreachable,
        .llvm => try llvmemit.emitModule(allocator, &lowered, &collector.writer, &bag),
        .mlir => try mlirmit.emitModule(allocator, &lowered, &collector.writer, &bag),
    }
    buf = collector.toArrayList();

    try bag.printAll(diag_writer);
    if (bag.hasErrors()) return error.TypeError;

    try writer.writeAll(buf.items);
}

/// Load `path` relative to `dir` (pairing a body with its stem-mate) and run
/// the shipped checker. This is the function the CLI uses after it has a path.
pub fn loadAndCheck(
    allocator: std.mem.Allocator,
    io: Io,
    dir: Io.Dir,
    path: []const u8,
    writer: *Io.Writer,
) !ast.Module {
    var loaded = load(allocator, io, dir, path, writer) catch |err| switch (err) {
        error.MissingModule, error.AmbiguousModule, error.PairingMismatch, error.ParseFailed => return error.TypeError,
        else => |e| return e,
    };
    try check(allocator, &loaded.module, loaded.source, writer);
    return loaded.module;
}

test {
    std.testing.refAllDecls(@This());
}

/// Compile and run the shipped `check` on `source`, capturing the rendered
/// diagnostics. This is the same function the CLI uses.
const CheckRun = struct {
    arena: std.heap.ArenaAllocator,
    buf: []u8,
    text: []const u8,
    failed: bool,

    fn deinit(self: *CheckRun) void {
        std.testing.allocator.free(self.buf);
        self.arena.deinit();
    }
};

fn runCheck(source: []const u8) !CheckRun {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    errdefer arena.deinit();
    const buf = try std.testing.allocator.alloc(u8, 16 * 1024);
    errdefer std.testing.allocator.free(buf);
    var w = Io.Writer.fixed(buf);
    var module = try compile(arena.allocator(), source, "t.cell");
    var failed = false;
    check(std.testing.allocator, &module, source, &w) catch |err| switch (err) {
        error.TypeError => failed = true,
        else => return err,
    };
    return .{ .arena = arena, .buf = buf, .text = w.buffered(), .failed = failed };
}

fn expectCheckHas(source: []const u8, needle: []const u8) !void {
    var run = try runCheck(source);
    defer run.deinit();
    try std.testing.expect(run.failed);
    if (std.mem.indexOf(u8, run.text, needle) == null) {
        std.debug.print("wanted:\n{s}\nin:\n{s}\n", .{ needle, run.text });
        return error.TestExpectedDiagnostic;
    }
}

fn expectCheckClean(source: []const u8) !void {
    var run = try runCheck(source);
    defer run.deinit();
    if (run.failed or run.text.len != 0) {
        std.debug.print("wanted a clean check, got:\n{s}\n", .{run.text});
        return error.TestUnexpectedDiagnostic;
    }
}

test "shipped check accepts a legal add-and-print program" {
    try expectCheckClean(
        \\pub fn print_int(copy value: Int);
        \\pub fn add(shared a: Int, shared b: Int) -> Int {
        \\    return a + b
        \\}
        \\pub fn main() {
        \\    let copy n = add(shared 40, shared 2)
        \\    print_int(n)
        \\}
    );
}

test "shipped check rejects use-after-move at the second use" {
    try expectCheckHas(
        \\pub struct Buffer { copy len: Int }
        \\pub fn take(owned b: Buffer) { }
        \\pub fn main() {
        \\    let owned buf = Buffer { len: 0 }
        \\    take(owned buf)
        \\    take(owned buf)
        \\}
    , "use of 'buf' after it was moved");
}

test "shipped check rejects moving out of a borrow" {
    try expectCheckHas(
        \\pub struct Buffer { copy len: Int }
        \\pub fn steal(exclusive b: Buffer) -> Buffer {
        \\    return b
        \\}
    , "cannot move out of 'b'");
}

test "shipped check rejects shared-XOR-exclusive aliasing" {
    try expectCheckHas(
        \\pub struct Buffer { copy len: Int }
        \\pub fn read(shared b: Buffer) -> Int { return b.len }
        \\pub fn use_it(exclusive b: Buffer) { }
        \\pub fn main() {
        \\    let owned buf = Buffer { len: 0 }
        \\    let exclusive e = &mut buf
        \\    let copy n = read(shared buf)
        \\    use_it(e)
        \\}
    , "cannot borrow 'buf' as shared: it is already borrowed as exclusive");
}

test "shipped check rejects an escaping borrow" {
    try expectCheckHas(
        \\pub struct Buffer { copy len: Int }
        \\pub fn peek(shared b: Buffer) -> shared Buffer {
        \\    return b
        \\}
    , "cannot return a shared borrow: Cell has no lifetime annotations, so the borrow cannot be proven to outlive the call");
}

test "shipped check rejects assignment through an immutable field" {
    try expectCheckHas(
        \\pub struct Buffer { copy len: Int }
        \\pub fn main() {
        \\    let owned b = Buffer { len: 0 }
        \\    b.len = 1
        \\}
    , "cannot assign to immutable binding 'b'");
}

fn loadCheckPath(dir: Io.Dir, path: []const u8) !struct { text: []u8, failed: bool, buf: []u8, arena: std.heap.ArenaAllocator } {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    errdefer arena.deinit();
    const buf = try std.testing.allocator.alloc(u8, 16 * 1024);
    errdefer std.testing.allocator.free(buf);
    var w = Io.Writer.fixed(buf);
    var failed = false;
    _ = loadAndCheck(arena.allocator(), std.testing.io, dir, path, &w) catch |err| switch (err) {
        error.TypeError => failed = true,
        else => return err,
    };
    return .{ .text = w.buffered(), .failed = failed, .buf = buf, .arena = arena };
}

test "shipped load+check pairs a body with its module so a module-only name resolves" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "geometry.cell",
        .data =
        \\pub struct Point { copy x: Float64 copy y: Float64 }
        \\pub enum Quadrant { First, Second, Third, Fourth }
        \\pub fn origin() -> Point;
        \\pub fn q() -> Quadrant;
        ,
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "geometry.body",
        .data =
        \\pub fn origin() -> Point {
        \\    return Point { x: 0.0, y: 0.0 }
        \\}
        \\pub fn q() -> Quadrant {
        \\    return Quadrant.First
        \\}
        ,
    });
    var result = try loadCheckPath(tmp.dir, "geometry.body");
    defer std.testing.allocator.free(result.buf);
    defer result.arena.deinit();
    if (result.failed) {
        std.debug.print("paired body failed check:\n{s}\n", .{result.text});
        return error.TestUnexpectedDiagnostic;
    }
}

test "shipped load+check rejects a body with no module file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "orphan.body",
        .data = "pub fn f() { }\n",
    });
    var result = try loadCheckPath(tmp.dir, "orphan.body");
    defer std.testing.allocator.free(result.buf);
    defer result.arena.deinit();
    try std.testing.expect(result.failed);
    if (std.mem.indexOf(u8, result.text, "body file 'orphan.body' has no module file") == null) {
        std.debug.print("wanted missing-module diagnostic, got:\n{s}\n", .{result.text});
        return error.TestExpectedDiagnostic;
    }
    if (std.mem.indexOf(u8, result.text, "expected orphan.cell or orphan.cel") == null) {
        std.debug.print("wanted expected module names, got:\n{s}\n", .{result.text});
        return error.TestExpectedDiagnostic;
    }
}

test "shipped load+check accepts a .cel module alias" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "hello.cel",
        .data =
        \\pub fn add(shared a: Int, shared b: Int) -> Int {
        \\    return a + b
        \\}
        ,
    });
    var result = try loadCheckPath(tmp.dir, "hello.cel");
    defer std.testing.allocator.free(result.buf);
    defer result.arena.deinit();
    if (result.failed) {
        std.debug.print(".cel module failed check:\n{s}\n", .{result.text});
        return error.TestUnexpectedDiagnostic;
    }
}

test "shipped load+check pairs a .body with a .cel stem-mate" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "pair.cel",
        .data = "pub struct Box { copy n: Int }\npub fn make() -> Box;\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "pair.body",
        .data = "pub fn make() -> Box { return Box { n: 1 } }\n",
    });
    var result = try loadCheckPath(tmp.dir, "pair.body");
    defer std.testing.allocator.free(result.buf);
    defer result.arena.deinit();
    if (result.failed) {
        std.debug.print(".cel stem-mate failed:\n{s}\n", .{result.text});
        return error.TestUnexpectedDiagnostic;
    }
}

test "shipped load+check rejects a pub body definition with no module declaration" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "g.cell",
        .data = "pub struct Buffer { copy len: Int }\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "g.body",
        .data = "pub fn grow(exclusive buf: Buffer) { }\n",
    });
    var result = try loadCheckPath(tmp.dir, "g.body");
    defer std.testing.allocator.free(result.buf);
    defer result.arena.deinit();
    try std.testing.expect(result.failed);
    if (std.mem.indexOf(u8, result.text, "'grow' is defined in g.body but not declared in g.cell") == null) {
        std.debug.print("wanted rule 8, got:\n{s}\n", .{result.text});
        return error.TestExpectedDiagnostic;
    }
}

test "shipped load+check rejects a function that has a body in both files" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "g.cell",
        .data = "pub fn grow() { }\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "g.body",
        .data = "pub fn grow() { }\n",
    });
    var result = try loadCheckPath(tmp.dir, "g.body");
    defer std.testing.allocator.free(result.buf);
    defer result.arena.deinit();
    try std.testing.expect(result.failed);
    if (std.mem.indexOf(u8, result.text, "'grow' already has a body in g.cell") == null) {
        std.debug.print("wanted rule 10, got:\n{s}\n", .{result.text});
        return error.TestExpectedDiagnostic;
    }
}

test "shipped load+check rejects a pub definition whose parameter ownership disagrees" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "g.cell",
        .data =
        \\pub struct Buffer { copy len: Int }
        \\pub fn grow(exclusive buf: Buffer, shared extra: Int);
        ,
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "g.body",
        .data =
        \\pub fn grow(owned buf: Buffer, shared extra: Int) { }
        ,
    });
    var result = try loadCheckPath(tmp.dir, "g.body");
    defer std.testing.allocator.free(result.buf);
    defer result.arena.deinit();
    try std.testing.expect(result.failed);
    if (std.mem.indexOf(u8, result.text, "parameter 1 is declared 'exclusive Buffer' but defined 'owned Buffer'") == null) {
        std.debug.print("wanted rule 11, got:\n{s}\n", .{result.text});
        return error.TestExpectedDiagnostic;
    }
}

test "shipped load+check allows a private body function with no module declaration" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "g.cell",
        .data = "pub struct Point { copy x: Int }\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "g.body",
        .data = "fn origin() -> Point { return Point { x: 0 } }\n",
    });
    var result = try loadCheckPath(tmp.dir, "g.body");
    defer std.testing.allocator.free(result.buf);
    defer result.arena.deinit();
    if (result.failed) {
        std.debug.print("private fn should not need a declaration:\n{s}\n", .{result.text});
        return error.TestUnexpectedDiagnostic;
    }
}

test "a backend refusal writes no partial output" {
    // A truncated emit on stdout becomes a file a later tool reads as if it
    // were complete. `cell emit --target=mlir f.cell > out.mlir` followed by a
    // separate `mlir-opt out.mlir` is the exact shape that goes wrong, so the
    // guarantee is that a refused module writes nothing at all.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `arc` is the trigger. It has been a struct, then [Byte], and both now
    // lower; each time the capability landed this test stopped testing
    // anything and had to move. `arc` lasts until OWNERSHIP R11 is
    // implemented, and when that lands this should move again rather than be
    // weakened.
    const source =
        \\pub fn g(arc s: String) -> Int;
    ;
    var module = try compile(a, source, "t.cell");

    var out_buf: [8192]u8 = undefined;
    var out = Io.Writer.fixed(&out_buf);
    var err_buf: [8192]u8 = undefined;
    var errw = Io.Writer.fixed(&err_buf);

    // MLIR cannot place an arc value, so this module cannot emit.
    try std.testing.expectError(
        error.TypeError,
        emitFor(a, &module, source, &out, .mlir, &errw),
    );
    try std.testing.expectEqual(@as(usize, 0), out.buffered().len);
    // The diagnostic still reaches the error stream, so the failure is loud.
    try std.testing.expect(std.mem.indexOf(u8, errw.buffered(), "cannot lower to MLIR") != null);
}

test "a bodyless two-argument assert takes the runtime's own symbol" {
    // codegen.symbolFor renames it to cell_assert_msg because C has no
    // overloading. The HIR must agree, or the backends built on it emit a call
    // to a symbol that does not exist and the failure is at link time.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var module = try compile(a,
        \\pub fn assert(copy cond: Bool, shared msg: String);
        \\pub fn assert1(copy cond: Bool);
    , "t.cell");

    var bag: diag.Bag = .init("t.cell", null);
    defer bag.deinit(a);
    const lowered = try hir.lower(a, &module, &bag);

    try std.testing.expectEqualStrings("cell_assert_msg", lowered.fns[0].symbol);
    try std.testing.expectEqualStrings("cell_assert1", lowered.fns[1].symbol);
}

/// Emit `source` for `target` into an arena-owned string.
fn emitText(a: std.mem.Allocator, source: []const u8, target: Target) ![]const u8 {
    var module = try compile(a, source, "t.cell");
    var out: Io.Writer.Allocating = .init(a);
    var err_buf: [4096]u8 = undefined;
    var errw = Io.Writer.fixed(&err_buf);
    try emitFor(a, &module, source, &out.writer, target, &errw);
    return out.written();
}

test "loop and while true emit byte-identical C, LLVM IR and MLIR, over the same CFG" {
    // Spec invariant 15: `loop` is parsed as `while true`, so no stage can
    // tell the two apart. Byte-identical output on all three targets is the
    // whole-pipeline form of that claim.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const with_loop =
        \\pub fn f(copy n: Int) -> Int {
        \\    var i = 0
        \\    loop {
        \\        i = i + 1
        \\        if i > n {
        \\            break
        \\        }
        \\    }
        \\    return i
        \\}
    ;
    const with_while =
        \\pub fn f(copy n: Int) -> Int {
        \\    var i = 0
        \\    while true {
        \\        i = i + 1
        \\        if i > n {
        \\            break
        \\        }
        \\    }
        \\    return i
        \\}
    ;
    for ([_]Target{ .c, .llvm, .mlir }) |target| {
        try std.testing.expectEqualStrings(
            try emitText(a, with_while, target),
            try emitText(a, with_loop, target),
        );
    }

    var bag: diag.Bag = .init("t.cell", null);
    defer bag.deinit(a);
    var m1 = try compile(a, with_loop, "t.cell");
    var m2 = try compile(a, with_while, "t.cell");
    const h1 = try hir.lower(a, &m1, &bag);
    const h2 = try hir.lower(a, &m2, &bag);
    try std.testing.expect(!bag.hasErrors());
    const g1 = (try cfg.build(a, &h1.fns[0])).?;
    const g2 = (try cfg.build(a, &h2.fns[0])).?;
    try std.testing.expectEqual(g2.blocks.len, g1.blocks.len);
    for (g1.blocks, g2.blocks) |b1, b2| {
        try std.testing.expectEqual(b2.kind, b1.kind);
        try std.testing.expectEqualSlices(u32, b2.succs, b1.succs);
    }
}

test "shipped check refuses a jump to a label no enclosing loop carries" {
    try expectCheckHas(
        \\pub fn f() {
        \\    outer: loop {
        \\        break :outr
        \\    }
        \\}
    , "error: no enclosing loop is labelled 'outr'");
}

test "checked HIR matches borrow IDs across bodyless declarations and list scratch" {
    const source =
        \\pub fn foreign(owned arg: String);
        \\pub fn f(owned input: String) {
        \\    let owned xs: [Int] = [1]
        \\    let owned s: String = "x"
        \\    let copy matched = match 1 { x => x }
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var module = try compile(a, source, "t.cell");
    var checker = borrowck.Checker.init(a, "t.cell", source);
    defer checker.deinit();
    try checker.checkModule(&module);
    try std.testing.expect(!checker.hasErrors());
    var bag: diag.Bag = .init("t.cell", source);
    defer bag.deinit(a);
    const lowered = try hir.lowerChecked(a, &module, &bag, checker.dropFacts());
    try std.testing.expect(!bag.hasErrors());
    const f = lowered.findFn("f").?;
    try std.testing.expectEqual(@as(?u32, 0), f.bindings[0].bc_id);
    const scratch = f.body.?[0].kind.let.value.?.kind.block.stmts[0].kind.let.slot;
    try std.testing.expect(f.bindings[scratch].bc_id == null);
    try std.testing.expectEqual(@as(?u32, 1), f.bindings[f.body.?[0].kind.let.slot].bc_id);
    try std.testing.expectEqual(@as(?u32, 2), f.bindings[f.body.?[1].kind.let.slot].bc_id);
    const match_value = f.body.?[2].kind.let.value.?;
    const alias_slot = match_value.kind.match_expr.arms[0].pattern.kind.binding;
    try std.testing.expect(!f.bindings[alias_slot].droppable);
    try std.testing.expectEqual(@as(?u32, 3), f.bindings[alias_slot].bc_id);
    try std.testing.expectEqual(@as(?u32, 4), f.bindings[f.body.?[2].kind.let.slot].bc_id);
    try std.testing.expectEqual(@as(u32, 5), checker.next_binding_id);
}

test "checked HIR refuses mismatched borrow identity for every slot" {
    const source =
        \\pub fn f(owned input: String) {
        \\    let owned s: String = "x"
        \\}
    ;
    const other =
        \\pub fn f(owned different: String) {
        \\    let owned s: String = "x"
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var module = try compile(a, source, "t.cell");
    var other_module = try compile(a, other, "other.cell");
    var checker = borrowck.Checker.init(a, "other.cell", other);
    defer checker.deinit();
    try checker.checkModule(&other_module);
    try std.testing.expect(!checker.hasErrors());
    var bag: diag.Bag = .init("t.cell", source);
    defer bag.deinit(a);
    const lowered = try hir.lowerChecked(a, &module, &bag, checker.dropFacts());
    try std.testing.expect(!bag.hasErrors());
    for (lowered.findFn("f").?.bindings) |binding| {
        try std.testing.expect(binding.bc_id == null);
    }
}

test "checked HIR releases a live owned String on simple fallthrough" {
    const source =
        \\pub fn f() {
        \\    let owned s: String = "x"
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var module = try compile(a, source, "t.cell");
    var checker = borrowck.Checker.init(a, "t.cell", source);
    defer checker.deinit();
    try checker.checkModule(&module);
    try std.testing.expect(!checker.hasErrors());
    var bag: diag.Bag = .init("t.cell", source);
    defer bag.deinit(a);
    const lowered = try hir.lowerChecked(a, &module, &bag, checker.dropFacts());
    try std.testing.expect(!bag.hasErrors());
    const body = lowered.findFn("f").?.body.?;
    try std.testing.expectEqual(@as(usize, 2), body.len);
    try std.testing.expectEqualStrings("cell_string_free", body[1].kind.expr.kind.call.symbol.?);
    try std.testing.expectEqual(ast.Ownership.exclusive, body[1].kind.expr.kind.call.modes[0].param);
    try std.testing.expectEqual(body[0].kind.let.slot, body[1].kind.expr.kind.call.args[0].kind.ref);
}

test "checked HIR releases scalar list owners once at simple fallthrough" {
    const source =
        \\pub fn f() {
        \\    let copy b: Byte = 7
        \\    let copy w: Int32 = 9
        \\    let owned bytes: [Byte] = [b]
        \\    let owned ints: [Int] = [42]
        \\    let owned widths: [Int32] = [w]
        \\    let owned floats: [Float] = [1.5]
        \\    let owned bools: [Bool] = [true]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var module = try compile(a, source, "t.cell");
    var checker = borrowck.Checker.init(a, "t.cell", source);
    defer checker.deinit();
    try checker.checkModule(&module);
    try std.testing.expect(!checker.hasErrors());
    var bag: diag.Bag = .init("t.cell", source);
    defer bag.deinit(a);
    const lowered = try hir.lowerChecked(a, &module, &bag, checker.dropFacts());
    try std.testing.expect(!bag.hasErrors());
    const f = lowered.findFn("f").?;
    const body = f.body.?;
    try std.testing.expectEqual(@as(usize, 12), body.len);
    for (0..5) |i| {
        const owner = body[6 - i].kind.let.slot;
        const call = body[7 + i].kind.expr.kind.call;
        try std.testing.expectEqualStrings("cell_slice_free", call.symbol.?);
        try std.testing.expectEqual(ast.Ownership.exclusive, call.modes[0].param);
        try std.testing.expectEqual(owner, call.args[0].kind.ref);
        try std.testing.expect(f.bindings[owner].droppable);
    }
    for (f.bindings) |binding| {
        if (std.mem.startsWith(u8, binding.name, "$list")) try std.testing.expect(!binding.droppable);
    }
}

test "checked HIR does not release a scalar list after transferring it" {
    const source =
        \\pub fn f(owned input: [Int]) {
        \\    let owned output: [Int] = input
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var module = try compile(a, source, "t.cell");
    var checker = borrowck.Checker.init(a, "t.cell", source);
    defer checker.deinit();
    try checker.checkModule(&module);
    try std.testing.expect(!checker.hasErrors());
    var bag: diag.Bag = .init("t.cell", source);
    defer bag.deinit(a);
    const lowered = try hir.lowerChecked(a, &module, &bag, checker.dropFacts());
    try std.testing.expect(!bag.hasErrors());
    const body = lowered.findFn("f").?.body.?;
    try std.testing.expectEqual(@as(usize, 2), body.len);
    try std.testing.expectEqualStrings("cell_slice_free", body[1].kind.expr.kind.call.symbol.?);
    try std.testing.expectEqual(body[0].kind.let.slot, body[1].kind.expr.kind.call.args[0].kind.ref);
}

test "checked HIR evaluates a scalar return before releasing list owners" {
    const source =
        \\pub fn f(owned input: [Int], copy i: Int) -> Int {
        \\    let owned local: [Int] = [7]
        \\    return i + 1
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var module = try compile(a, source, "t.cell");
    var checker = borrowck.Checker.init(a, "t.cell", source);
    defer checker.deinit();
    try checker.checkModule(&module);
    try std.testing.expect(!checker.hasErrors());
    var bag: diag.Bag = .init("t.cell", source);
    defer bag.deinit(a);
    const lowered = try hir.lowerChecked(a, &module, &bag, checker.dropFacts());
    try std.testing.expect(!bag.hasErrors());
    const body = lowered.findFn("f").?.body.?;
    try std.testing.expectEqual(@as(usize, 5), body.len);
    const local = body[0].kind.let.slot;
    const result = body[1].kind.let.slot;
    try std.testing.expectEqualStrings("cell_slice_free", body[2].kind.expr.kind.call.symbol.?);
    try std.testing.expectEqual(local, body[2].kind.expr.kind.call.args[0].kind.ref);
    try std.testing.expectEqualStrings("cell_slice_free", body[3].kind.expr.kind.call.symbol.?);
    try std.testing.expectEqual(@as(u32, 0), body[3].kind.expr.kind.call.args[0].kind.ref);
    try std.testing.expectEqual(result, body[4].kind.ret.?.kind.ref);
}

test "checked HIR keeps a returned owned list for the caller" {
    const source =
        \\pub fn f(owned input: [Int]) -> [Int] {
        \\    return input
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var module = try compile(a, source, "t.cell");
    var checker = borrowck.Checker.init(a, "t.cell", source);
    defer checker.deinit();
    try checker.checkModule(&module);
    try std.testing.expect(!checker.hasErrors());
    var bag: diag.Bag = .init("t.cell", source);
    defer bag.deinit(a);
    const lowered = try hir.lowerChecked(a, &module, &bag, checker.dropFacts());
    try std.testing.expect(!bag.hasErrors());
    const body = lowered.findFn("f").?.body.?;
    try std.testing.expectEqual(@as(usize, 1), body.len);
    try std.testing.expectEqual(@as(u32, 0), body[0].kind.ret.?.kind.ref);
}

test "checked HIR evaluates a call replacement before releasing the old String" {
    const source =
        \\pub fn make() -> String;
        \\pub fn f() -> Int {
        \\    var owned s: String = make()
        \\    s = make()
        \\    return 42
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var module = try compile(a, source, "t.cell");
    var checker = borrowck.Checker.init(a, "t.cell", source);
    defer checker.deinit();
    try checker.checkModule(&module);
    try std.testing.expect(!checker.hasErrors());
    var bag: diag.Bag = .init("t.cell", source);
    defer bag.deinit(a);
    const lowered = try hir.lowerChecked(a, &module, &bag, checker.dropFacts());
    try std.testing.expect(!bag.hasErrors());
    const body = lowered.findFn("f").?.body.?;
    try std.testing.expectEqual(@as(usize, 7), body.len);
    try std.testing.expect(body[1].kind.let.value.?.kind == .call);
    try std.testing.expectEqualStrings("cell_string_free", body[2].kind.expr.kind.call.symbol.?);
    try std.testing.expectEqual(body[0].kind.let.slot, body[2].kind.expr.kind.call.args[0].kind.ref);
    try std.testing.expectEqual(body[1].kind.let.slot, body[3].kind.assign.value.kind.ref);
    try std.testing.expectEqualStrings("cell_string_free", body[5].kind.expr.kind.call.symbol.?);
    try std.testing.expectEqual(body[0].kind.let.slot, body[5].kind.expr.kind.call.args[0].kind.ref);
}

test "checked HIR skips a moved String and releases its new owner" {
    const source =
        \\pub fn f() {
        \\    let owned a: String = "x"
        \\    let owned b: String = a
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var module = try compile(a, source, "t.cell");
    var checker = borrowck.Checker.init(a, "t.cell", source);
    defer checker.deinit();
    try checker.checkModule(&module);
    try std.testing.expect(!checker.hasErrors());
    var bag: diag.Bag = .init("t.cell", source);
    defer bag.deinit(a);
    const lowered = try hir.lowerChecked(a, &module, &bag, checker.dropFacts());
    try std.testing.expect(!bag.hasErrors());
    const body = lowered.findFn("f").?.body.?;
    try std.testing.expectEqual(@as(usize, 3), body.len);
    try std.testing.expectEqual(body[1].kind.let.slot, body[2].kind.expr.kind.call.args[0].kind.ref);
}

test "checked HIR releases an owned String body parameter" {
    const source = "pub fn f(owned s: String) {}";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var module = try compile(a, source, "t.cell");
    var checker = borrowck.Checker.init(a, "t.cell", source);
    defer checker.deinit();
    try checker.checkModule(&module);
    try std.testing.expect(!checker.hasErrors());
    var bag: diag.Bag = .init("t.cell", source);
    defer bag.deinit(a);
    const lowered = try hir.lowerChecked(a, &module, &bag, checker.dropFacts());
    try std.testing.expect(!bag.hasErrors());
    const body = lowered.findFn("f").?.body.?;
    try std.testing.expectEqual(@as(usize, 1), body.len);
    try std.testing.expectEqual(@as(u32, 0), body[0].kind.expr.kind.call.args[0].kind.ref);
}

test "checked HIR releases an old owned String before straight-line reassignment" {
    const source =
        \\pub fn f() {
        \\    var owned s: String = "old"
        \\    s = "new"
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var module = try compile(a, source, "t.cell");
    var checker = borrowck.Checker.init(a, "t.cell", source);
    defer checker.deinit();
    try checker.checkModule(&module);
    try std.testing.expect(!checker.hasErrors());
    var bag: diag.Bag = .init("t.cell", source);
    defer bag.deinit(a);
    const lowered = try hir.lowerChecked(a, &module, &bag, checker.dropFacts());
    try std.testing.expect(!bag.hasErrors());
    const body = lowered.findFn("f").?.body.?;
    try std.testing.expectEqual(@as(usize, 5), body.len);
    try std.testing.expect(body[1].kind == .let);
    try std.testing.expectEqualStrings("cell_string_free", body[2].kind.expr.kind.call.symbol.?);
    try std.testing.expectEqual(body[0].kind.let.slot, body[2].kind.expr.kind.call.args[0].kind.ref);
    try std.testing.expectEqual(body[1].kind.let.slot, body[3].kind.assign.value.kind.ref);
    try std.testing.expectEqualStrings("cell_string_free", body[4].kind.expr.kind.call.symbol.?);
}

test "checked HIR never drops an uninitialized owned String slot" {
    const source = "pub fn f() { var owned s: String }";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var module = try compile(a, source, "t.cell");
    var checker = borrowck.Checker.init(a, "t.cell", source);
    defer checker.deinit();
    try checker.checkModule(&module);
    try std.testing.expect(!checker.hasErrors());
    var bag: diag.Bag = .init("t.cell", source);
    defer bag.deinit(a);
    const lowered = try hir.lowerChecked(a, &module, &bag, checker.dropFacts());
    try std.testing.expect(!bag.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), lowered.findFn("f").?.body.?.len);
}

/// Lower `source` with borrow facts and return the first loop body of `f`.
fn checkedLoopBody(a: std.mem.Allocator, source: []const u8) ![]hir.Stmt {
    var module = try compile(a, source, "t.cell");
    var checker = borrowck.Checker.init(a, "t.cell", source);
    try checker.checkModule(&module);
    try std.testing.expect(!checker.hasErrors());
    var bag: diag.Bag = .init("t.cell", source);
    const lowered = try hir.lowerChecked(a, &module, &bag, checker.dropFacts());
    try std.testing.expect(!bag.hasErrors());
    for (lowered.findFn("f").?.body.?) |stmt| {
        if (stmt.kind == .while_loop) return stmt.kind.while_loop.body;
    }
    return error.TestUnexpectedResult;
}

test "checked HIR releases a loop-body String before break" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body = try checkedLoopBody(arena.allocator(),
        \\pub fn f() {
        \\    while true {
        \\        let owned s: String = "x"
        \\        break
        \\    }
        \\}
    );
    try std.testing.expectEqual(@as(usize, 3), body.len);
    try std.testing.expectEqualStrings("cell_string_free", body[1].kind.expr.kind.call.symbol.?);
    try std.testing.expectEqual(body[0].kind.let.slot, body[1].kind.expr.kind.call.args[0].kind.ref);
    try std.testing.expect(body[2].kind == .brk);
}

test "checked HIR keeps a String moved before break" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body = try checkedLoopBody(arena.allocator(),
        \\pub fn take(owned s: String);
        \\pub fn f() {
        \\    while true {
        \\        let owned s: String = "x"
        \\        take(s)
        \\        break
        \\    }
        \\}
    );
    try std.testing.expectEqual(@as(usize, 3), body.len);
    try std.testing.expect(body[2].kind == .brk);
}

test "checked HIR releases a loop-body String at the body's fall-through end" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body = try checkedLoopBody(arena.allocator(),
        \\pub fn f() {
        \\    var i = 0
        \\    while i < 2 {
        \\        let owned s: String = "x"
        \\        i = i + 1
        \\    }
        \\}
    );
    try std.testing.expectEqual(@as(usize, 3), body.len);
    try std.testing.expectEqualStrings("cell_string_free", body[2].kind.expr.kind.call.symbol.?);
    try std.testing.expectEqual(body[0].kind.let.slot, body[2].kind.expr.kind.call.args[0].kind.ref);
}

test "checked HIR releases inner then outer owners before continue :outer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const outer = try checkedLoopBody(arena.allocator(),
        \\pub fn f() {
        \\    outer: loop {
        \\        let owned a: String = "x"
        \\        loop {
        \\            let owned b: String = "y"
        \\            continue :outer
        \\        }
        \\    }
        \\}
    );
    const a_slot = outer[0].kind.let.slot;
    const inner = outer[1].kind.while_loop.body;
    try std.testing.expectEqual(@as(usize, 4), inner.len);
    try std.testing.expectEqual(inner[0].kind.let.slot, inner[1].kind.expr.kind.call.args[0].kind.ref);
    try std.testing.expectEqual(a_slot, inner[2].kind.expr.kind.call.args[0].kind.ref);
    try std.testing.expectEqual(@as(u32, 1), inner[3].kind.cont);
}

test "checked HIR releases a loop-body String before return" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body = try checkedLoopBody(arena.allocator(),
        \\pub fn f() {
        \\    while true {
        \\        let owned s: String = "x"
        \\        return
        \\    }
        \\}
    );
    try std.testing.expectEqual(@as(usize, 3), body.len);
    try std.testing.expectEqualStrings("cell_string_free", body[1].kind.expr.kind.call.symbol.?);
    try std.testing.expectEqual(body[0].kind.let.slot, body[1].kind.expr.kind.call.args[0].kind.ref);
    try std.testing.expect(body[2].kind == .ret);
}

test "checked HIR releases a loop-body scalar list before return" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body = try checkedLoopBody(arena.allocator(),
        \\pub fn f() {
        \\    while true {
        \\        let owned xs: [Int] = [1]
        \\        return
        \\    }
        \\}
    );
    const owner = body[0].kind.let.slot;
    var freed = false;
    for (body[0 .. body.len - 1]) |stmt| {
        if (stmtFreesSlot(stmt, "cell_slice_free", owner)) freed = true;
    }
    try std.testing.expect(freed);
    try std.testing.expect(body[body.len - 1].kind == .ret);
}

test "checked HIR releases a revived outer String before return inside a loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const f = try checkedFn(arena.allocator(),
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
    const v_slot = f.body.?[0].kind.let.slot;
    try std.testing.expectEqualStrings("v", f.bindings[v_slot].name);
    const loop = f.body.?[2].kind.while_loop.body;
    const branch = loop[loop.len - 1].kind.expr.kind.if_expr.then_body.kind.block;
    try std.testing.expect(branch.stmts.len >= 2);
    try std.testing.expect(stmtFreesSlot(branch.stmts[branch.stmts.len - 2], "cell_string_free", v_slot));
    try std.testing.expect(branch.stmts[branch.stmts.len - 1].kind == .ret);
}

test "checked HIR does not release a String returned between its move and its revival" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const f = try checkedFn(arena.allocator(),
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
    const v_slot = f.body.?[0].kind.let.slot;
    const loop = f.body.?[2].kind.while_loop.body;
    const branch = loop[loop.len - 2].kind.expr.kind.if_expr.then_body.kind.block;
    for (branch.stmts) |stmt| {
        try std.testing.expect(!stmtFreesSlot(stmt, "cell_string_free", v_slot));
    }
    try std.testing.expect(branch.stmts[branch.stmts.len - 1].kind == .ret);
}

test "checked HIR evaluates a scalar return before releasing the loop String it reads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body = try checkedLoopBody(arena.allocator(),
        \\pub fn len(shared s: String) -> Int;
        \\pub fn f() -> Int {
        \\    while true {
        \\        let owned s: String = "x"
        \\        return len(s)
        \\    }
        \\}
    );
    const owner = body[0].kind.let.slot;
    try std.testing.expectEqual(@as(usize, 4), body.len);
    try std.testing.expect(body[1].kind == .let);
    try std.testing.expectEqualStrings("cell_string_free", body[2].kind.expr.kind.call.symbol.?);
    try std.testing.expectEqual(owner, body[2].kind.expr.kind.call.args[0].kind.ref);
    try std.testing.expectEqual(body[1].kind.let.slot, body[3].kind.ret.?.kind.ref);
}

test "checked HIR keeps a String that a loop return moves to the caller" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body = try checkedLoopBody(arena.allocator(),
        \\pub fn f() -> String {
        \\    while true {
        \\        let owned s: String = "x"
        \\        return s
        \\    }
        \\}
    );
    const owner = body[0].kind.let.slot;
    for (body) |stmt| {
        try std.testing.expect(!stmtFreesSlot(stmt, "cell_string_free", owner));
    }
    try std.testing.expect(body[body.len - 1].kind == .ret);
}

test "checked HIR releases a revived outer String once after the loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const f = try checkedFn(arena.allocator(),
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
    const v_slot = f.body.?[0].kind.let.slot;
    const w = f.body.?[2].kind.while_loop;
    for (w.body) |stmt| try std.testing.expect(!stmtFreesSlot(stmt, "cell_string_free", v_slot));
    try std.testing.expectEqual(@as(usize, 0), countTopLevelFrees(f.body.?, "cell_string_free", v_slot));
    try std.testing.expectEqual(@as(usize, 1), countTopLevelFrees(w.after, "cell_string_free", v_slot));
}

test "checked HIR releases a revived outer String after the loop, not before break" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const f = try checkedFn(arena.allocator(),
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
    const v_slot = f.body.?[0].kind.let.slot;
    const w = f.body.?[2].kind.while_loop;
    for (w.body) |stmt| try std.testing.expect(!stmtFreesSlot(stmt, "cell_string_free", v_slot));
    const held = w.body[w.body.len - 1].kind.expr.kind.if_expr.then_body.kind.block.stmts[0].kind.brk;
    try std.testing.expect(!held.skip);
    try std.testing.expectEqual(@as(usize, 0), countTopLevelFrees(f.body.?, "cell_string_free", v_slot));
    try std.testing.expectEqual(@as(usize, 1), countTopLevelFrees(w.after, "cell_string_free", v_slot));
}

test "checked HIR releases an unmoved outer String at function end, not after the loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const f = try checkedFn(arena.allocator(),
        \\pub fn f() {
        \\    var owned v: String = "a"
        \\    var i = 0
        \\    while i < 3 {
        \\        i = i + 1
        \\    }
        \\}
    );
    const v_slot = f.body.?[0].kind.let.slot;
    const w = f.body.?[2].kind.while_loop;
    for (w.body) |stmt| try std.testing.expect(!stmtFreesSlot(stmt, "cell_string_free", v_slot));
    try std.testing.expectEqual(@as(usize, 0), w.after.len);
    try std.testing.expectEqual(@as(usize, 1), countTopLevelFrees(f.body.?, "cell_string_free", v_slot));
    try std.testing.expect(stmtFreesSlot(f.body.?[f.body.?.len - 1], "cell_string_free", v_slot));
}

test "checked HIR releases an unmoved scalar list at function end when the body contains a while" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const f = try checkedFn(arena.allocator(),
        \\pub fn f() {
        \\    let owned xs: [Int] = [1]
        \\    var i = 0
        \\    while i < 3 {
        \\        i = i + 1
        \\    }
        \\}
    );
    const slot = f.body.?[0].kind.let.slot;
    const w = f.body.?[2].kind.while_loop;
    for (w.body) |stmt| try std.testing.expect(!stmtFreesSlot(stmt, "cell_slice_free", slot));
    try std.testing.expectEqual(@as(usize, 0), w.after.len);
    try std.testing.expectEqual(@as(usize, 1), countTopLevelFrees(f.body.?, "cell_slice_free", slot));
    try std.testing.expect(stmtFreesSlot(f.body.?[f.body.?.len - 1], "cell_slice_free", slot));
}

test "checked HIR binds a scalar return before releasing an unmoved String beside a while" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const f = try checkedFn(arena.allocator(),
        \\pub fn f() -> Int {
        \\    var owned v: String = "a"
        \\    var i = 0
        \\    while i < 3 {
        \\        i = i + 1
        \\    }
        \\    return i
        \\}
    );
    const v_slot = f.body.?[0].kind.let.slot;
    const w = f.body.?[2].kind.while_loop;
    try std.testing.expectEqual(@as(usize, 0), w.after.len);
    const body = f.body.?;
    try std.testing.expect(body[body.len - 1].kind == .ret);
    try std.testing.expect(stmtFreesSlot(body[body.len - 2], "cell_string_free", v_slot));
    try std.testing.expectEqual(@as(usize, 1), countTopLevelFrees(body, "cell_string_free", v_slot));
}

test "checked HIR does not release a revived outer String at continue" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const f = try checkedFn(arena.allocator(),
        \\pub fn take(owned s: String) { }
        \\pub fn f() {
        \\    var owned v: String = "a"
        \\    var i = 0
        \\    while i < 3 {
        \\        take(v)
        \\        v = "b"
        \\        i = i + 1
        \\        continue
        \\    }
        \\}
    );
    const v_slot = f.body.?[0].kind.let.slot;
    const w = f.body.?[2].kind.while_loop;
    for (w.body) |stmt| try std.testing.expect(!stmtFreesSlot(stmt, "cell_string_free", v_slot));
    try std.testing.expect(w.body[w.body.len - 1].kind == .cont);
    try std.testing.expectEqual(@as(usize, 0), countTopLevelFrees(f.body.?, "cell_string_free", v_slot));
    try std.testing.expectEqual(@as(usize, 1), countTopLevelFrees(w.after, "cell_string_free", v_slot));
}

test "checked HIR releases an outer String after the loop and skips the dead break" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const f = try checkedFn(arena.allocator(),
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
    const v_slot = f.body.?[0].kind.let.slot;
    const w = f.body.?[2].kind.while_loop;
    for (w.body) |stmt| try std.testing.expect(!stmtFreesSlot(stmt, "cell_string_free", v_slot));
    const dead = w.body[2].kind.expr.kind.if_expr.then_body.kind.block.stmts[0].kind.brk;
    try std.testing.expect(dead.skip);
    try std.testing.expectEqual(@as(u32, 0), dead.depth);
    try std.testing.expectEqual(@as(usize, 0), countTopLevelFrees(f.body.?, "cell_string_free", v_slot));
    try std.testing.expectEqual(@as(usize, 1), countTopLevelFrees(w.after, "cell_string_free", v_slot));
}

test "llvm branches a skip-revival break past the after-loop release" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source =
        \\pub fn take(owned s: String) { }
        \\pub fn f(copy n: Int) {
        \\    var owned v: String = "a"
        \\    var i = 0
        \\    while i < 3 {
        \\        i = i + 1
        \\        if i > 5 {
        \\            break
        \\        }
        \\        take(v)
        \\        if i > n {
        \\            break
        \\        }
        \\        v = "b"
        \\    }
        \\}
    ;
    var module = try compile(a, source, "t.cell");
    var buf: [64 * 1024]u8 = undefined;
    var w = Io.Writer.fixed(&buf);
    var diag_buf: [4096]u8 = undefined;
    var dw = Io.Writer.fixed(&diag_buf);
    try emitFor(a, &module, source, &w, .llvm, &dw);
    const text = w.buffered();
    // The body's `v = "b"` also frees the previous String, so the after-loop
    // release is the call that follows the end block.
    const end_at = std.mem.indexOf(u8, text, "loop.end.").?;
    const free_at = std.mem.indexOfPos(u8, text, end_at, "call void @cell_string_free") orelse {
        std.debug.print("{s}\n", .{text});
        return error.TestUnexpectedResult;
    };
    const skip_at = std.mem.indexOfPos(u8, text, free_at, "loop.skip.") orelse {
        std.debug.print("{s}\n", .{text});
        return error.TestUnexpectedResult;
    };
    try std.testing.expect(end_at < free_at);
    try std.testing.expect(free_at < skip_at);
    try std.testing.expect(std.mem.indexOf(u8, text, "br label %loop.end.") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "br label %loop.skip.") != null);
}

test "checked HIR keeps one after-loop release when one break still holds the String" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const f = try checkedFn(arena.allocator(),
        \\pub fn take(owned s: String) { }
        \\pub fn f(copy n: Int) {
        \\    var owned v: String = "a"
        \\    var i = 0
        \\    while i < 3 {
        \\        i = i + 1
        \\        if i > 5 {
        \\            break
        \\        }
        \\        take(v)
        \\        if i > n {
        \\            break
        \\        }
        \\        v = "b"
        \\    }
        \\}
    );
    const v_slot = f.body.?[0].kind.let.slot;
    const w = f.body.?[2].kind.while_loop;
    const live = w.body[1].kind.expr.kind.if_expr.then_body.kind.block.stmts[0].kind.brk;
    const dead = w.body[3].kind.expr.kind.if_expr.then_body.kind.block.stmts[0].kind.brk;
    try std.testing.expect(!live.skip);
    try std.testing.expect(dead.skip);
    for (w.body) |stmt| try std.testing.expect(!stmtFreesSlot(stmt, "cell_string_free", v_slot));
    try std.testing.expectEqual(@as(usize, 1), countTopLevelFrees(w.after, "cell_string_free", v_slot));
}

test "checked HIR does not release an outer String when the loop's breaks disagree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nested = try checkedFn(arena.allocator(),
        \\pub fn take(owned s: String) { }
        \\pub fn f(copy n: Int) {
        \\    var owned v: String = "a"
        \\    var j = 0
        \\    while j < 2 {
        \\        j = j + 1
        \\        var i = 0
        \\        while i < 3 {
        \\            i = i + 1
        \\            take(v)
        \\            if i > n {
        \\                break
        \\            }
        \\            v = "b"
        \\        }
        \\        v = "c"
        \\    }
        \\}
    );
    const nested_slot = nested.body.?[0].kind.let.slot;
    try expectNoSkipRelease(nested.body.?, "cell_string_free", nested_slot);

    const mixed = try checkedFn(arena.allocator(),
        \\pub fn take(owned s: String) { }
        \\pub fn f(copy n: Int) {
        \\    var owned v: String = "a"
        \\    var owned w: String = "a"
        \\    var i = 0
        \\    while i < 3 {
        \\        i = i + 1
        \\        take(v)
        \\        if i > n {
        \\            break
        \\        }
        \\        v = "b"
        \\        take(w)
        \\        if i > 1 {
        \\            break
        \\        }
        \\        w = "b"
        \\    }
        \\}
    );
    try expectNoSkipRelease(mixed.body.?, "cell_string_free", mixed.body.?[0].kind.let.slot);
    try expectNoSkipRelease(mixed.body.?, "cell_string_free", mixed.body.?[1].kind.let.slot);

    const plain = try checkedFn(arena.allocator(),
        \\pub fn take(owned s: String) { }
        \\pub fn f(copy n: Int) {
        \\    var owned v: String = "a"
        \\    var owned w: String = "a"
        \\    var i = 0
        \\    while i < 3 {
        \\        i = i + 1
        \\        take(w)
        \\        w = "b"
        \\        take(v)
        \\        if i > n {
        \\            break
        \\        }
        \\        v = "b"
        \\    }
        \\}
    );
    // `v` is dead at the break, but `w` is live on every exit, so borrowck
    // records `after_loop` for `w` and refuses the skip. `v` stays a leak.
    try expectNoSkipRelease(plain.body.?, "cell_string_free", plain.body.?[0].kind.let.slot);
    const plain_w = plain.body.?[3].kind.while_loop;
    try std.testing.expect(!plain_w.body[4].kind.expr.kind.if_expr.then_body.kind.block.stmts[0].kind.brk.skip);
    try std.testing.expectEqual(@as(usize, 1), countTopLevelFrees(plain_w.after, "cell_string_free", plain.body.?[1].kind.let.slot));
    try std.testing.expectEqual(@as(usize, 0), countTopLevelFrees(plain_w.after, "cell_string_free", plain.body.?[0].kind.let.slot));
}

fn expectNoSkipRelease(stmts: []const hir.Stmt, symbol: []const u8, slot: u32) anyerror!void {
    for (stmts) |stmt| {
        try std.testing.expect(!stmtFreesSlot(stmt, symbol, slot));
        switch (stmt.kind) {
            .brk => |j| try std.testing.expect(!j.skip),
            .while_loop => |w| {
                try std.testing.expectEqual(@as(usize, 0), countTopLevelFrees(w.after, symbol, slot));
                try expectNoSkipRelease(w.body, symbol, slot);
                try expectNoSkipRelease(w.after, symbol, slot);
            },
            .expr => |e| try expectNoSkipExpr(&e),
            .let => |l| if (l.value) |v| try expectNoSkipExpr(&v),
            .assign => |a| try expectNoSkipExpr(&a.value),
            .ret => |r| if (r) |v| try expectNoSkipExpr(&v),
            .cont => {},
        }
    }
}

fn expectNoSkipExpr(e: *const hir.Expr) anyerror!void {
    switch (e.kind) {
        .block => |bl| {
            try expectNoSkipRelease(bl.stmts, "cell_string_free", 0);
            if (bl.tail) |t| try expectNoSkipExpr(t);
        },
        .if_expr => |i| {
            try expectNoSkipExpr(i.cond);
            try expectNoSkipExpr(i.then_body);
            if (i.else_body) |eb| try expectNoSkipExpr(eb);
        },
        else => {},
    }
}

test "checked HIR does not release a revived outer String a later statement still uses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const f = try checkedFn(arena.allocator(),
        \\pub fn take(owned s: String) { }
        \\pub fn f() {
        \\    var owned v: String = "a"
        \\    var i = 0
        \\    while i < 3 {
        \\        take(v)
        \\        v = "b"
        \\        i = i + 1
        \\    }
        \\    take(v)
        \\}
    );
    const v_slot = f.body.?[0].kind.let.slot;
    try std.testing.expectEqual(@as(usize, 0), countTopLevelFrees(f.body.?, "cell_string_free", v_slot));
}

test "checked HIR releases a revived outer scalar list once after the loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const f = try checkedFn(arena.allocator(),
        \\pub fn take_xs(owned xs: [Int]) { }
        \\pub fn f() {
        \\    var owned xs: [Int] = [1]
        \\    var i = 0
        \\    while i < 1 {
        \\        take_xs(xs)
        \\        xs = [2]
        \\        i = i + 1
        \\    }
        \\}
    );
    const slot = f.body.?[0].kind.let.slot;
    const w = f.body.?[2].kind.while_loop;
    for (w.body) |stmt| try std.testing.expect(!stmtFreesSlot(stmt, "cell_slice_free", slot));
    try std.testing.expectEqual(@as(usize, 0), countTopLevelFrees(f.body.?, "cell_slice_free", slot));
    try std.testing.expectEqual(@as(usize, 1), countTopLevelFrees(w.after, "cell_slice_free", slot));
}

fn checkedFn(a: std.mem.Allocator, source: []const u8) !hir.Fn {
    var module = try compile(a, source, "t.cell");
    var checker = borrowck.Checker.init(a, "t.cell", source);
    try checker.checkModule(&module);
    try std.testing.expect(!checker.hasErrors());
    var bag: diag.Bag = .init("t.cell", source);
    const lowered = try hir.lowerChecked(a, &module, &bag, checker.dropFacts());
    try std.testing.expect(!bag.hasErrors());
    return lowered.findFn("f").?.*;
}

fn stmtFreesSlot(stmt: hir.Stmt, symbol: []const u8, slot: u32) bool {
    if (stmt.kind != .expr) return false;
    const call = stmt.kind.expr;
    if (call.kind != .call) return false;
    const c = call.kind.call;
    const name = c.symbol orelse return false;
    if (!std.mem.eql(u8, name, symbol)) return false;
    if (c.args.len != 1 or c.args[0].kind != .ref) return false;
    return c.args[0].kind.ref == slot;
}

fn blockFreesSlot(block_expr: *const hir.Expr, symbol: []const u8, slot: u32) bool {
    const b = block_expr.kind.block;
    for (b.stmts) |stmt| {
        if (stmtFreesSlot(stmt, symbol, slot)) return true;
    }
    return false;
}

fn stmtFreesField(stmt: hir.Stmt, symbol: []const u8, slot: u32, index: u32) bool {
    if (stmt.kind != .expr) return false;
    const call = stmt.kind.expr;
    if (call.kind != .call) return false;
    const c = call.kind.call;
    const name = c.symbol orelse return false;
    if (!std.mem.eql(u8, name, symbol)) return false;
    if (c.args.len != 1 or c.args[0].kind != .field) return false;
    const field = c.args[0].kind.field;
    if (field.base.kind != .ref or field.base.kind.ref != slot) return false;
    return field.sel.index == index;
}

fn blockFreesField(block_expr: *const hir.Expr, symbol: []const u8, slot: u32, index: u32) bool {
    if (block_expr.kind != .block) return false;
    for (block_expr.kind.block.stmts) |stmt| {
        if (stmtFreesField(stmt, symbol, slot, index)) return true;
    }
    return false;
}

fn countTopLevelFrees(body: []const hir.Stmt, symbol: []const u8, slot: u32) usize {
    var n: usize = 0;
    for (body) |stmt| {
        if (stmtFreesSlot(stmt, symbol, slot)) n += 1;
    }
    return n;
}

fn countTopLevelFieldFrees(body: []const hir.Stmt, symbol: []const u8, slot: u32, index: u32) usize {
    var n: usize = 0;
    for (body) |stmt| {
        if (stmtFreesField(stmt, symbol, slot, index)) n += 1;
    }
    return n;
}

fn stmtFreesNestedField(stmt: hir.Stmt, symbol: []const u8, slot: u32, parent: u32, index: u32) bool {
    if (stmt.kind != .expr) return false;
    const call = stmt.kind.expr;
    if (call.kind != .call) return false;
    const c = call.kind.call;
    const name = c.symbol orelse return false;
    if (!std.mem.eql(u8, name, symbol)) return false;
    if (c.args.len != 1 or c.args[0].kind != .field) return false;
    const leaf = c.args[0].kind.field;
    if (leaf.sel.index != index or leaf.base.kind != .field) return false;
    const parent_field = leaf.base.kind.field;
    return parent_field.sel.index == parent and parent_field.base.kind == .ref and parent_field.base.kind.ref == slot;
}

fn countNestedFieldFrees(body: []const hir.Stmt, symbol: []const u8, slot: u32, parent: u32, index: u32) usize {
    var n: usize = 0;
    for (body) |stmt| {
        if (stmtFreesNestedField(stmt, symbol, slot, parent, index)) n += 1;
    }
    return n;
}

test "checked HIR releases an outer owned String on the branch that kept it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const f = try checkedFn(arena.allocator(),
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
    const v_slot = f.body.?[0].kind.let.slot;
    try std.testing.expectEqualStrings("v", f.bindings[v_slot].name);
    const if_stmt = f.body.?[2].kind.expr;
    const ie = if_stmt.kind.if_expr;
    try std.testing.expect(ie.then_body.kind == .block);
    try std.testing.expect(ie.else_body.?.kind == .block);
    try std.testing.expect(!blockFreesSlot(ie.then_body, "cell_string_free", v_slot));
    try std.testing.expect(blockFreesSlot(ie.else_body.?, "cell_string_free", v_slot));
}

test "checked HIR does not branch-release a String neither branch moved" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const f = try checkedFn(arena.allocator(),
        \\pub fn f(copy c: Int) {
        \\    var owned v: String = "a"
        \\    var i = 0
        \\    if c > 0 {
        \\        i = i + 1
        \\    } else {
        \\        i = i + 1
        \\    }
        \\}
    );
    const body = f.body.?;
    const v_slot = body[0].kind.let.slot;
    try std.testing.expectEqualStrings("v", f.bindings[v_slot].name);
    const ie = body[2].kind.expr.kind.if_expr;
    try std.testing.expect(ie.then_body.kind == .block);
    try std.testing.expect(ie.else_body.?.kind == .block);
    try std.testing.expect(!blockFreesSlot(ie.then_body, "cell_string_free", v_slot));
    try std.testing.expect(!blockFreesSlot(ie.else_body.?, "cell_string_free", v_slot));
    try std.testing.expectEqual(@as(usize, 1), countTopLevelFrees(body, "cell_string_free", v_slot));
}

test "checked HIR releases an outer owned String in a synthesized else" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const f = try checkedFn(arena.allocator(),
        \\pub fn take(owned s: String) { }
        \\pub fn f(copy c: Int) {
        \\    var owned v: String = "a"
        \\    if c > 0 {
        \\        take(v)
        \\    }
        \\}
    );
    const v_slot = f.body.?[0].kind.let.slot;
    try std.testing.expectEqualStrings("v", f.bindings[v_slot].name);
    const if_expr = f.body.?[1].kind.expr;
    try std.testing.expect(if_expr.ty == .unit);
    const ie = if_expr.kind.if_expr;
    try std.testing.expect(ie.then_body.kind == .block);
    const else_body = ie.else_body orelse return error.TestUnexpectedResult;
    try std.testing.expect(else_body.kind == .block);
    try std.testing.expect(!blockFreesSlot(ie.then_body, "cell_string_free", v_slot));
    try std.testing.expect(blockFreesSlot(else_body, "cell_string_free", v_slot));
}

test "checked HIR releases an outer owned scalar list on the branch that kept it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const f = try checkedFn(arena.allocator(),
        \\pub fn take(owned xs: [Int]) { }
        \\pub fn f(copy c: Int) {
        \\    let owned xs: [Int] = [1]
        \\    var i = 0
        \\    if c > 0 {
        \\        take(xs)
        \\    } else {
        \\        i = i + 1
        \\    }
        \\}
    );
    const xs_slot = f.body.?[0].kind.let.slot;
    try std.testing.expectEqualStrings("xs", f.bindings[xs_slot].name);
    const ie = f.body.?[2].kind.expr.kind.if_expr;
    try std.testing.expect(ie.then_body.kind == .block);
    try std.testing.expect(ie.else_body.?.kind == .block);
    try std.testing.expect(!blockFreesSlot(ie.then_body, "cell_slice_free", xs_slot));
    try std.testing.expect(blockFreesSlot(ie.else_body.?, "cell_slice_free", xs_slot));
}

test "checked HIR releases a kept String field on the synthesized else" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const f = try checkedFn(arena.allocator(),
        \\pub struct Pair {
        \\    owned a: String
        \\    owned b: String
        \\}
        \\pub fn take(owned s: String) { }
        \\pub fn f(copy c: Int) {
        \\    let owned p: Pair = Pair { a: "x", b: "y" }
        \\    if c > 0 {
        \\        take(p.a)
        \\    }
        \\}
    );
    const p_slot = f.body.?[0].kind.let.slot;
    try std.testing.expectEqualStrings("p", f.bindings[p_slot].name);
    const ie = f.body.?[1].kind.expr.kind.if_expr;
    const else_body = ie.else_body orelse return error.TestUnexpectedResult;
    // `a` is index 0, `b` is index 1. The keeping branch frees `a` only.
    // Freeing the whole record, or `b`, double-frees with the scope-end drop.
    try std.testing.expect(!blockFreesField(ie.then_body, "cell_string_free", p_slot, 0));
    try std.testing.expect(!blockFreesField(ie.then_body, "cell_string_free", p_slot, 1));
    try std.testing.expect(blockFreesField(else_body, "cell_string_free", p_slot, 0));
    try std.testing.expect(!blockFreesField(else_body, "cell_string_free", p_slot, 1));
    try std.testing.expect(!blockFreesSlot(else_body, "cell_string_free", p_slot));
    // `b` is the unmoved sibling. One function-end free, not a second free of `a`.
    try std.testing.expectEqual(@as(usize, 0), countTopLevelFieldFrees(f.body.?, "cell_string_free", p_slot, 0));
    try std.testing.expectEqual(@as(usize, 1), countTopLevelFieldFrees(f.body.?, "cell_string_free", p_slot, 1));
}

test "checked HIR releases a kept nested String field on the synthesized else" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const f = try checkedFn(arena.allocator(),
        \\pub struct Inner {
        \\    owned a: String
        \\    owned b: String
        \\}
        \\pub struct Outer {
        \\    owned inner: Inner
        \\    owned tag: String
        \\}
        \\pub fn take(owned s: String) { }
        \\pub fn f(copy c: Int) {
        \\    let owned p: Outer = Outer { inner: Inner { a: "x", b: "y" }, tag: "t" }
        \\    if c > 0 {
        \\        take(p.inner.a)
        \\    }
        \\}
    );
    const p_slot = f.body.?[0].kind.let.slot;
    const ie = f.body.?[1].kind.expr.kind.if_expr;
    const else_body = ie.else_body orelse return error.TestUnexpectedResult;
    // `inner` is index 0. `a` is its index 0, `b` is index 1.
    // The keeping branch frees `inner.a` only. `inner.b` and `tag` stay
    // for the function-end walk.
    var then_a = false;
    var else_a = false;
    var else_b = false;
    for (ie.then_body.kind.block.stmts) |stmt| {
        if (stmtFreesNestedField(stmt, "cell_string_free", p_slot, 0, 0)) then_a = true;
    }
    for (else_body.kind.block.stmts) |stmt| {
        if (stmtFreesNestedField(stmt, "cell_string_free", p_slot, 0, 0)) else_a = true;
        if (stmtFreesNestedField(stmt, "cell_string_free", p_slot, 0, 1)) else_b = true;
    }
    try std.testing.expect(!then_a);
    try std.testing.expect(else_a);
    try std.testing.expect(!else_b);
    try std.testing.expect(!blockFreesField(else_body, "cell_string_free", p_slot, 1));
    try std.testing.expectEqual(@as(usize, 0), countNestedFieldFrees(f.body.?, "cell_string_free", p_slot, 0, 0));
    try std.testing.expectEqual(@as(usize, 1), countNestedFieldFrees(f.body.?, "cell_string_free", p_slot, 0, 1));
    try std.testing.expectEqual(@as(usize, 1), countTopLevelFieldFrees(f.body.?, "cell_string_free", p_slot, 1));
}

test "checked HIR does not branch-release a String field revived after the if" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const f = try checkedFn(arena.allocator(),
        \\pub struct Pair {
        \\    owned a: String
        \\    owned b: String
        \\}
        \\pub fn take(owned s: String) { }
        \\pub fn f(copy c: Int) {
        \\    var owned p: Pair = Pair { a: "x", b: "y" }
        \\    if c > 0 {
        \\        take(p.a)
        \\    }
        \\    p.a = "c"
        \\}
    );
    const p_slot = f.body.?[0].kind.let.slot;
    const ie = f.body.?[1].kind.expr.kind.if_expr;
    try std.testing.expect(!blockFreesField(ie.then_body, "cell_string_free", p_slot, 0));
    if (ie.else_body) |else_body| {
        try std.testing.expect(!blockFreesField(else_body, "cell_string_free", p_slot, 0));
        try std.testing.expect(!blockFreesField(else_body, "cell_string_free", p_slot, 1));
    }
    // Both fields hold a value at scope end: `a` was revived, `b` was never moved.
    try std.testing.expectEqual(@as(usize, 1), countTopLevelFieldFrees(f.body.?, "cell_string_free", p_slot, 0));
    try std.testing.expectEqual(@as(usize, 1), countTopLevelFieldFrees(f.body.?, "cell_string_free", p_slot, 1));
}

test "checked HIR releases a kept scalar-list field on the synthesized else" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const f = try checkedFn(arena.allocator(),
        \\pub struct Pair {
        \\    owned a: [Int]
        \\    owned b: [Int]
        \\}
        \\pub fn take(owned xs: [Int]) { }
        \\pub fn f(copy c: Int) {
        \\    let owned p: Pair = Pair { a: [1], b: [2] }
        \\    if c > 0 {
        \\        take(p.a)
        \\    }
        \\}
    );
    const p_slot = f.body.?[0].kind.let.slot;
    const ie = f.body.?[1].kind.expr.kind.if_expr;
    const else_body = ie.else_body orelse return error.TestUnexpectedResult;
    try std.testing.expect(!blockFreesField(ie.then_body, "cell_slice_free", p_slot, 0));
    try std.testing.expect(blockFreesField(else_body, "cell_slice_free", p_slot, 0));
    try std.testing.expect(!blockFreesField(else_body, "cell_slice_free", p_slot, 1));
    try std.testing.expectEqual(@as(usize, 0), countTopLevelFieldFrees(f.body.?, "cell_slice_free", p_slot, 0));
    try std.testing.expectEqual(@as(usize, 1), countTopLevelFieldFrees(f.body.?, "cell_slice_free", p_slot, 1));
}

test "checked HIR does not field-release a wholly moved record" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const f = try checkedFn(arena.allocator(),
        \\pub struct Pair {
        \\    owned a: String
        \\    owned b: String
        \\}
        \\pub fn f(copy c: Int) {
        \\    let owned p: Pair = Pair { a: "x", b: "y" }
        \\    let owned q: Pair = p
        \\    var i = 0
        \\    if c > 0 {
        \\        i = i + 1
        \\    } else {
        \\        i = i + 1
        \\    }
        \\}
    );
    const p_slot = f.body.?[0].kind.let.slot;
    const q_slot = f.body.?[1].kind.let.slot;
    const ie = f.body.?[3].kind.expr.kind.if_expr;
    try std.testing.expect(!blockFreesField(ie.then_body, "cell_string_free", p_slot, 0));
    try std.testing.expect(!blockFreesField(ie.then_body, "cell_string_free", p_slot, 1));
    try std.testing.expect(!blockFreesField(ie.else_body.?, "cell_string_free", p_slot, 0));
    try std.testing.expect(!blockFreesField(ie.else_body.?, "cell_string_free", p_slot, 1));
    try std.testing.expectEqual(@as(usize, 0), countTopLevelFieldFrees(f.body.?, "cell_string_free", p_slot, 0));
    try std.testing.expectEqual(@as(usize, 0), countTopLevelFieldFrees(f.body.?, "cell_string_free", p_slot, 1));
    // `q` received the record. Its fields are still owned at scope end.
    try std.testing.expectEqual(@as(usize, 1), countTopLevelFieldFrees(f.body.?, "cell_string_free", q_slot, 0));
    try std.testing.expectEqual(@as(usize, 1), countTopLevelFieldFrees(f.body.?, "cell_string_free", q_slot, 1));
}

test "checked HIR scope-releases a record declared inside a branch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const f = try checkedFn(arena.allocator(),
        \\pub struct Pair {
        \\    owned a: String
        \\    owned b: String
        \\}
        \\pub fn f(copy c: Int) {
        \\    if c > 0 {
        \\        let owned p: Pair = Pair { a: "x", b: "y" }
        \\    }
        \\}
    );
    var p_slot: ?u32 = null;
    for (f.bindings) |b| {
        if (std.mem.eql(u8, b.name, "p")) p_slot = b.slot;
    }
    const slot = p_slot orelse return error.TestUnexpectedResult;
    const ie = f.body.?[0].kind.expr.kind.if_expr;
    try std.testing.expect(blockFreesField(ie.then_body, "cell_string_free", slot, 0));
    try std.testing.expect(blockFreesField(ie.then_body, "cell_string_free", slot, 1));
    // The function-end walk does not free this record a second time.
    try std.testing.expectEqual(@as(usize, 0), countTopLevelFieldFrees(f.body.?, "cell_string_free", slot, 0));
    try std.testing.expectEqual(@as(usize, 0), countTopLevelFieldFrees(f.body.?, "cell_string_free", slot, 1));
}

test "checked HIR scope-releases only the unmoved field of a record inside a branch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const f = try checkedFn(arena.allocator(),
        \\pub struct Pair {
        \\    owned a: String
        \\    owned b: String
        \\}
        \\pub fn take(owned s: String) { }
        \\pub fn f(copy c: Int) {
        \\    if c > 0 {
        \\        let owned p: Pair = Pair { a: "x", b: "y" }
        \\        take(p.a)
        \\    }
        \\}
    );
    var p_slot: ?u32 = null;
    for (f.bindings) |b| {
        if (std.mem.eql(u8, b.name, "p")) p_slot = b.slot;
    }
    const slot = p_slot orelse return error.TestUnexpectedResult;
    const ie = f.body.?[0].kind.expr.kind.if_expr;
    try std.testing.expect(!blockFreesField(ie.then_body, "cell_string_free", slot, 0));
    try std.testing.expect(blockFreesField(ie.then_body, "cell_string_free", slot, 1));
    try std.testing.expectEqual(@as(usize, 0), countTopLevelFieldFrees(f.body.?, "cell_string_free", slot, 0));
    try std.testing.expectEqual(@as(usize, 0), countTopLevelFieldFrees(f.body.?, "cell_string_free", slot, 1));
}

test "checked HIR scope-releases a record declared inside a while" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const f = try checkedFn(arena.allocator(),
        \\pub struct Pair {
        \\    owned a: String
        \\    owned b: String
        \\}
        \\pub fn f() {
        \\    var i = 0
        \\    while i < 2 {
        \\        let owned p: Pair = Pair { a: "x", b: "y" }
        \\        i = i + 1
        \\    }
        \\}
    );
    var p_slot: ?u32 = null;
    for (f.bindings) |b| {
        if (std.mem.eql(u8, b.name, "p")) p_slot = b.slot;
    }
    const slot = p_slot orelse return error.TestUnexpectedResult;
    const loop = f.body.?[1];
    try std.testing.expect(loop.kind == .while_loop);
    try std.testing.expectEqual(@as(usize, 1), countTopLevelFieldFrees(loop.kind.while_loop.body, "cell_string_free", slot, 0));
    try std.testing.expectEqual(@as(usize, 1), countTopLevelFieldFrees(loop.kind.while_loop.body, "cell_string_free", slot, 1));
    try std.testing.expectEqual(@as(usize, 0), countTopLevelFieldFrees(f.body.?, "cell_string_free", slot, 0));
    try std.testing.expectEqual(@as(usize, 0), countTopLevelFieldFrees(f.body.?, "cell_string_free", slot, 1));
}

test "checked HIR scope-releases an owned record parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const f = try checkedFn(arena.allocator(),
        \\pub struct Pair {
        \\    owned a: String
        \\    owned b: String
        \\}
        \\pub fn f(owned p: Pair) {
        \\    let copy n = 0
        \\}
    );
    try std.testing.expect(f.bindings[0].is_param);
    try std.testing.expectEqualStrings("p", f.bindings[0].name);
    try std.testing.expectEqual(@as(usize, 1), countTopLevelFieldFrees(f.body.?, "cell_string_free", 0, 0));
    try std.testing.expectEqual(@as(usize, 1), countTopLevelFieldFrees(f.body.?, "cell_string_free", 0, 1));
    try std.testing.expectEqual(@as(usize, 0), countTopLevelFrees(f.body.?, "cell_string_free", 0));
}

test "checked HIR scope-releases only the unmoved field of an owned record parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const f = try checkedFn(arena.allocator(),
        \\pub struct Pair {
        \\    owned a: String
        \\    owned b: String
        \\}
        \\pub fn f(owned p: Pair) {
        \\    let owned moved: String = p.a
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), countTopLevelFieldFrees(f.body.?, "cell_string_free", 0, 0));
    try std.testing.expectEqual(@as(usize, 1), countTopLevelFieldFrees(f.body.?, "cell_string_free", 0, 1));
}

test "checked HIR does not scope-release a wholly moved owned record parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const f = try checkedFn(arena.allocator(),
        \\pub struct Pair {
        \\    owned a: String
        \\    owned b: String
        \\}
        \\pub fn f(owned p: Pair) {
        \\    let owned q: Pair = p
        \\}
    );
    var q_slot: ?u32 = null;
    for (f.bindings) |b| {
        if (std.mem.eql(u8, b.name, "q")) q_slot = b.slot;
    }
    const q = q_slot orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 0), countTopLevelFieldFrees(f.body.?, "cell_string_free", 0, 0));
    try std.testing.expectEqual(@as(usize, 0), countTopLevelFieldFrees(f.body.?, "cell_string_free", 0, 1));
    try std.testing.expectEqual(@as(usize, 1), countTopLevelFieldFrees(f.body.?, "cell_string_free", q, 0));
    try std.testing.expectEqual(@as(usize, 1), countTopLevelFieldFrees(f.body.?, "cell_string_free", q, 1));
}

test "checked HIR scope-releases the unmoved sibling of a nested field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const f = try checkedFn(arena.allocator(),
        \\pub struct Inner {
        \\    owned a: String
        \\    owned b: String
        \\}
        \\pub struct Outer {
        \\    owned inner: Inner
        \\    owned tag: String
        \\}
        \\pub fn f() -> Int {
        \\    let owned p: Outer = Outer { inner: Inner { a: "x", b: "y" }, tag: "t" }
        \\    let owned moved: String = p.inner.a
        \\    return 1
        \\}
    );
    const p_slot = f.body.?[0].kind.let.slot;
    try std.testing.expectEqualStrings("p", f.bindings[p_slot].name);
    // `inner` is index 0, `tag` is index 1. `a` is 0 and `b` is 1 inside Inner.
    // The moved leaf is not freed. The nested sibling and the direct tag are.
    try std.testing.expectEqual(@as(usize, 0), countNestedFieldFrees(f.body.?, "cell_string_free", p_slot, 0, 0));
    try std.testing.expectEqual(@as(usize, 1), countNestedFieldFrees(f.body.?, "cell_string_free", p_slot, 0, 1));
    try std.testing.expectEqual(@as(usize, 1), countTopLevelFieldFrees(f.body.?, "cell_string_free", p_slot, 1));
}

test "checked HIR scope-releases every leaf of an unmoved nested record" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const f = try checkedFn(arena.allocator(),
        \\pub struct Inner {
        \\    owned a: String
        \\    owned b: String
        \\}
        \\pub struct Outer {
        \\    owned inner: Inner
        \\    owned tag: String
        \\}
        \\pub fn f() -> Int {
        \\    let owned p: Outer = Outer { inner: Inner { a: "x", b: "y" }, tag: "t" }
        \\    return 1
        \\}
    );
    const p_slot = f.body.?[0].kind.let.slot;
    try std.testing.expectEqual(@as(usize, 1), countNestedFieldFrees(f.body.?, "cell_string_free", p_slot, 0, 0));
    try std.testing.expectEqual(@as(usize, 1), countNestedFieldFrees(f.body.?, "cell_string_free", p_slot, 0, 1));
    try std.testing.expectEqual(@as(usize, 1), countTopLevelFieldFrees(f.body.?, "cell_string_free", p_slot, 1));
}

test "checked HIR does not scope-release a wholly moved nested record" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const f = try checkedFn(arena.allocator(),
        \\pub struct Inner {
        \\    owned a: String
        \\    owned b: String
        \\}
        \\pub struct Outer {
        \\    owned inner: Inner
        \\    owned tag: String
        \\}
        \\pub fn f() -> Int {
        \\    let owned p: Outer = Outer { inner: Inner { a: "x", b: "y" }, tag: "t" }
        \\    let owned q: Inner = p.inner
        \\    return 1
        \\}
    );
    const p_slot = f.body.?[0].kind.let.slot;
    const q_slot = f.body.?[1].kind.let.slot;
    try std.testing.expectEqual(@as(usize, 0), countNestedFieldFrees(f.body.?, "cell_string_free", p_slot, 0, 0));
    try std.testing.expectEqual(@as(usize, 0), countNestedFieldFrees(f.body.?, "cell_string_free", p_slot, 0, 1));
    try std.testing.expectEqual(@as(usize, 1), countTopLevelFieldFrees(f.body.?, "cell_string_free", p_slot, 1));
    try std.testing.expectEqual(@as(usize, 1), countTopLevelFieldFrees(f.body.?, "cell_string_free", q_slot, 0));
    try std.testing.expectEqual(@as(usize, 1), countTopLevelFieldFrees(f.body.?, "cell_string_free", q_slot, 1));
}

test "checked HIR scope-releases an unmoved nested scalar-list sibling" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const f = try checkedFn(arena.allocator(),
        \\pub struct Inner {
        \\    owned a: [Int]
        \\    owned b: [Int]
        \\}
        \\pub struct Outer {
        \\    owned inner: Inner
        \\}
        \\pub fn f() -> Int {
        \\    let owned p: Outer = Outer { inner: Inner { a: [1], b: [2] } }
        \\    let owned moved: [Int] = p.inner.a
        \\    return 1
        \\}
    );
    const p_slot = f.body.?[0].kind.let.slot;
    try std.testing.expectEqual(@as(usize, 0), countNestedFieldFrees(f.body.?, "cell_slice_free", p_slot, 0, 0));
    try std.testing.expectEqual(@as(usize, 1), countNestedFieldFrees(f.body.?, "cell_slice_free", p_slot, 0, 1));
}

test "checked HIR String slice hoists a nested return before releasing its readers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const f = try checkedFn(arena.allocator(),
        \\pub fn str_len(shared s: String) -> Int;
        \\pub fn f(owned input: String, copy flag: Bool) -> Int {
        \\    if flag {
        \\        let owned local: String = "abc"
        \\        return str_len(input) + str_len(local)
        \\    }
        \\    return 0
        \\}
    );
    const branch = f.body.?[0].kind.expr.kind.if_expr.then_body.kind.block;
    try std.testing.expect(branch.tail == null);
    try std.testing.expectEqual(@as(usize, 5), branch.stmts.len);
    const local = branch.stmts[0].kind.let.slot;
    const scratch = branch.stmts[1].kind.let.slot;
    try std.testing.expect(!f.bindings[scratch].droppable);
    try std.testing.expect(stmtFreesSlot(branch.stmts[2], "cell_string_free", local));
    try std.testing.expect(stmtFreesSlot(branch.stmts[3], "cell_string_free", 0));
    try std.testing.expectEqual(scratch, branch.stmts[4].kind.ret.?.kind.ref);
}

test "checked HIR String slice transfers the returned owner and frees the sibling" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const f = try checkedFn(arena.allocator(),
        \\pub fn f(owned input: String) -> String {
        \\    let owned other: String = "other"
        \\    return input
        \\}
    );
    const body = f.body.?;
    try std.testing.expectEqual(@as(usize, 4), body.len);
    try std.testing.expectEqual(@as(usize, 0), countTopLevelFrees(body, "cell_string_free", 0));
    try std.testing.expect(stmtFreesSlot(body[2], "cell_string_free", body[0].kind.let.slot));
    try std.testing.expectEqual(body[1].kind.let.slot, body[3].kind.ret.?.kind.ref);
}

test "checked HIR String slice releases branch locals after computing an unrelated tail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const f = try checkedFn(arena.allocator(),
        \\pub fn f(copy flag: Bool) -> Int {
        \\    return if flag { let owned s: String = "abc" 7 } else { 8 }
        \\}
    );
    const branch = f.body.?[0].kind.let.value.?.kind.if_expr.then_body.kind.block;
    try std.testing.expectEqual(@as(usize, 3), branch.stmts.len);
    try std.testing.expect(stmtFreesSlot(branch.stmts[2], "cell_string_free", branch.stmts[0].kind.let.slot));
    try std.testing.expectEqual(branch.stmts[1].kind.let.slot, branch.tail.?.kind.ref);
}

test "checked HIR String slice preserves a tail reachable owner and moved aliases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const f = try checkedFn(arena.allocator(),
        \\pub fn str_len(shared s: String) -> Int;
        \\pub fn f() -> Int {
        \\    return { let owned s: String = "abc" str_len(s) }
        \\}
    );
    const branch = f.body.?[0].kind.let.value.?.kind.block;
    try std.testing.expectEqual(@as(usize, 0), countTopLevelFrees(branch.stmts, "cell_string_free", branch.stmts[0].kind.let.slot));
}

test "checked HIR String slice releases fresh discarded calls but never discarded places" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const f = try checkedFn(arena.allocator(),
        \\pub fn make() -> String;
        \\pub fn f(owned input: String) {
        \\    make()
        \\    input
        \\}
    );
    const body = f.body.?;
    try std.testing.expectEqual(@as(usize, 3), body.len);
    const scratch = body[0].kind.let.slot;
    try std.testing.expect(!f.bindings[scratch].droppable);
    try std.testing.expect(f.bindings[scratch].bc_id == null);
    try std.testing.expect(stmtFreesSlot(body[1], "cell_string_free", scratch));
    try std.testing.expectEqual(@as(usize, 0), countTopLevelFrees(body, "cell_string_free", 0));
}

test "checked HIR String slice releases both labelled break scopes in reverse order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body = try checkedLoopBody(arena.allocator(),
        \\pub fn f() {
        \\    outer: loop {
        \\        let owned a: String = "a"
        \\        loop {
        \\            let owned b: String = "b"
        \\            break :outer
        \\        }
        \\    }
        \\}
    );
    const inner = body[1].kind.while_loop.body;
    try std.testing.expectEqual(@as(usize, 4), inner.len);
    try std.testing.expect(stmtFreesSlot(inner[1], "cell_string_free", inner[0].kind.let.slot));
    try std.testing.expect(stmtFreesSlot(inner[2], "cell_string_free", body[0].kind.let.slot));
    try std.testing.expectEqual(@as(u32, 1), inner[3].kind.brk.depth);
}

test "checked HIR String slice keeps owners referenced by a tail match guard" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const f = try checkedFn(arena.allocator(),
        \\pub fn str_len(shared s: String) -> Int;
        \\pub fn f() -> Int {
        \\    return {
        \\        let owned s: String = "abc"
        \\        match 1 { _ if str_len(s) > 0 => 7, _ => 8 }
        \\    }
        \\}
    );
    const block = f.body.?[0].kind.let.value.?.kind.block;
    try std.testing.expectEqual(@as(usize, 0), countTopLevelFrees(block.stmts, "cell_string_free", block.stmts[0].kind.let.slot));
}

test "checked HIR String slice leaves unchecked discarded calls unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var module = try compile(a, "pub fn make() -> String; pub fn f() { make() }", "t.cell");
    var bag: diag.Bag = .init("t.cell", "");
    const lowered = try hir.lower(a, &module, &bag);
    try std.testing.expect(!bag.hasErrors());
    const body = lowered.findFn("f").?.body.?;
    try std.testing.expectEqual(@as(usize, 1), body.len);
    try std.testing.expectEqualStrings("cell_make", body[0].kind.expr.kind.call.symbol.?);
    try std.testing.expect(lowered.findFn("$rt.string_free") == null);
}

test "checked HIR String slice preserves an owning block tail transfer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const f = try checkedFn(arena.allocator(),
        \\pub fn f() -> String {
        \\    return { let owned s: String = "abc" s }
        \\}
    );
    const block = f.body.?[0].kind.ret.?.kind.block;
    try std.testing.expectEqual(@as(usize, 0), countTopLevelFrees(block.stmts, "cell_string_free", block.stmts[0].kind.let.slot));
}
