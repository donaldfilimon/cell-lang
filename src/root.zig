//! Cell language core library.
//! Blends Rust-style ownership, Swift-style ergonomics, Zig-style explicit control.
const std = @import("std");
const Io = std.Io;

pub const ast = @import("cell/ast.zig");
pub const lexer = @import("cell/lexer.zig");
pub const parser = @import("cell/parser.zig");
pub const typecheck = @import("cell/typecheck.zig");
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

/// Type-check a parsed module, rendering every diagnostic to `writer`.
///
/// `source` is the module's source buffer when the caller still has it; with it
/// each diagnostic gains the offending source line and a caret. Returns
/// `error.TypeError` once the bag has been written, so a caller can exit
/// non-zero without re-inspecting it.
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
    try tc.diagnostics.printAll(writer);
    if (tc.diagnostics.hasErrors()) return error.TypeError;
}

/// Emit C ABI sketch from a checked module.
pub fn emit(allocator: std.mem.Allocator, module: *const ast.Module, writer: *Io.Writer) !void {
    var gen = codegen.Generator.init(allocator, writer);
    try gen.emitModule(module);
}

test {
    std.testing.refAllDecls(@This());
}
