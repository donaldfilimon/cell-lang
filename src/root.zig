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

/// Emit C ABI sketch from a checked module.
pub fn emit(allocator: std.mem.Allocator, module: *const ast.Module, writer: *Io.Writer) !void {
    var gen = codegen.Generator.init(allocator, writer);
    try gen.emitModule(module);
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
