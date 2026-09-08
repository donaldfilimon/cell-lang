//! Cell language core library.
//! Blends Rust-style ownership, Swift-style ergonomics, Zig-style explicit control.
const std = @import("std");
const Io = std.Io;

pub const ast = @import("cell/ast.zig");
pub const lexer = @import("cell/lexer.zig");
pub const parser = @import("cell/parser.zig");
pub const typecheck = @import("cell/typecheck.zig");
pub const borrowck = @import("cell/borrowck.zig");
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

    var lowered = try hir.lower(allocator, module, &bag);
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
