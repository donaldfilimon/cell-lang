//! Test helpers shared by the C backend's test files.

const std = @import("std");
const Io = std.Io;
const cg_root = @import("../codegen.zig");
const Generator = cg_root.Generator;

// ── tests ───────────────────────────────────────────────────────────────

pub const lexer = @import("../lexer.zig");
pub const parser = @import("../parser.zig");

/// Parse `src` and return the emitted C. The buffer is caller owned so the
/// returned slice stays valid.
pub fn emitForTest(arena: std.mem.Allocator, buf: []u8, src: []const u8) ![]const u8 {
    var lex = lexer.Lexer.init(src, "t.cell");
    const toks = try lex.tokenizeAll(arena);
    var p = parser.Parser.init(arena, toks.items, "t.cell");
    var module = try p.parseModule();
    var w = Io.Writer.fixed(buf);
    var gen = Generator.init(arena, &w);
    try gen.emitModule(&module);
    return w.buffered();
}

pub const TestEmit = struct {
    arena: std.heap.ArenaAllocator,
    buf: []u8,
    text: []const u8,

    pub fn deinit(self: *TestEmit) void {
        std.testing.allocator.free(self.buf);
        self.arena.deinit();
    }
};

pub fn emitSource(src: []const u8) !TestEmit {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    errdefer arena.deinit();
    const buf = try std.testing.allocator.alloc(u8, 64 * 1024);
    errdefer std.testing.allocator.free(buf);
    const text = try emitForTest(arena.allocator(), buf, src);
    return .{ .arena = arena, .buf = buf, .text = text };
}

pub fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("\nexpected to find:\n{s}\nin:\n{s}\n", .{ needle, haystack });
        return error.NotFound;
    }
}

/// The definition of one emitted function, from its signature line to its
/// closing brace, so a text assertion about one body is not satisfied or
/// broken by another. Since R11 row 1 closed, a callee with an `owned` or
/// `arc` parameter releases it, so a text-wide `expectAbsent` on a free
/// also matches every such callee in the same source.
pub fn fnDef(haystack: []const u8, name: []const u8) ![]const u8 {
    var buf: [128]u8 = undefined;
    const needle = try std.fmt.bufPrint(&buf, " cell_{s}(", .{name});
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, from, needle)) |at| {
        const eol = std.mem.indexOfScalarPos(u8, haystack, at, '\n') orelse break;
        if (haystack[eol - 1] == '{') {
            const end = std.mem.indexOfPos(u8, haystack, eol, "\n}\n") orelse break;
            return haystack[at .. end + 3];
        }
        from = eol;
    }
    std.debug.print("\nno definition of cell_{s} in:\n{s}\n", .{ name, haystack });
    return error.NotFound;
}

/// The emitted translation unit compiles as an object at
/// `-Wall -Wextra -Werror`, the flags the gate's sanitized stage uses.
pub fn expectCompiles(text: []const u8) !void {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "body.c", .data = text });

    var cwd_buf: [4096]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const include = try std.fmt.allocPrint(gpa, "{s}/runtime", .{cwd_buf[0..cwd_len]});
    defer gpa.free(include);

    const result = try std.process.run(gpa, io, .{
        .argv = &.{
            "cc",     "-std=c11", "-Wall", "-Wextra", "-Werror", "-c",
            "body.c", "-I",       include, "-o",      "body.o",
        },
        .cwd = .{ .dir = tmp.dir },
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (!result.term.success()) {
        std.debug.print("cc rejected emitted C:\n{s}\n--- source ---\n{s}\n", .{ result.stderr, text });
        return error.CcRejectedEmittedC;
    }
}

pub fn expectAbsent(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) != null) {
        std.debug.print("\nexpected NOT to find:\n{s}\nin:\n{s}\n", .{ needle, haystack });
        return error.Found;
    }
}

/// How many times `needle` appears, for the assertions where ONE is the
/// answer and two is a double free. `expectContains` cannot tell those apart,
/// and a drop test that only asks "is the free there" passes just as happily
/// when it is there twice.
/// The trimmed line immediately before the first `jump` must be `prev`:
/// how a drop-before-jump test asks its question without hardcoding the
/// indentation of a `while` body nested in an `if`.
pub fn expectLineBefore(haystack: []const u8, jump: []const u8, prev: []const u8) !void {
    const at = std.mem.indexOf(u8, haystack, jump) orelse {
        std.debug.print("\nexpected to find:\n{s}\nin:\n{s}\n", .{ jump, haystack });
        return error.NotFound;
    };
    const line_start = if (std.mem.lastIndexOfScalar(u8, haystack[0..at], '\n')) |i| i + 1 else 0;
    const prev_end = if (line_start > 0) line_start - 1 else 0;
    const prev_start = if (std.mem.lastIndexOfScalar(u8, haystack[0..prev_end], '\n')) |i| i + 1 else 0;
    const got = std.mem.trim(u8, haystack[prev_start..prev_end], " ");
    if (!std.mem.eql(u8, got, prev)) {
        std.debug.print("\nexpected the line before:\n{s}\nto be:\n{s}\nbut it was:\n{s}\nin:\n{s}\n", .{ jump, prev, got, haystack });
        return error.WrongLineBefore;
    }
}

pub fn expectOccurrences(haystack: []const u8, needle: []const u8, want: usize) !void {
    const got = std.mem.count(u8, haystack, needle);
    if (got != want) {
        std.debug.print(
            "\nexpected {d} occurrence(s) of:\n{s}\nbut found {d}, in:\n{s}\n",
            .{ want, needle, got, haystack },
        );
        return error.WrongCount;
    }
}

/// `first` must appear before `second`. An ordering test that only asserted
/// both are present would pass in the exact arrangement `cc` rejects, which
/// is how the forward-reference gap survived: `cell check` said ok and no
/// test looked at the order.
pub fn expectBefore(haystack: []const u8, first: []const u8, second: []const u8) !void {
    const a = std.mem.indexOf(u8, haystack, first) orelse {
        std.debug.print("\nexpected to find:\n{s}\nin:\n{s}\n", .{ first, haystack });
        return error.NotFound;
    };
    const b = std.mem.indexOf(u8, haystack, second) orelse {
        std.debug.print("\nexpected to find:\n{s}\nin:\n{s}\n", .{ second, haystack });
        return error.NotFound;
    };
    if (a >= b) {
        std.debug.print("\nexpected:\n{s}\nbefore:\n{s}\nin:\n{s}\n", .{ first, second, haystack });
        return error.WrongOrder;
    }
}
