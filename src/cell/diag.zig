const std = @import("std");
const ast = @import("ast.zig");
const Io = std.Io;

const Span = ast.Span;

pub const Level = enum {
    note,
    warning,
    err,

    /// The word printed in a rendered diagnostic. `err` renders as "error";
    /// `@tagName` would print the Zig identifier instead.
    pub fn text(self: Level) []const u8 {
        return switch (self) {
            .note => "note",
            .warning => "warning",
            .err => "error",
        };
    }
};

/// One diagnostic. The module path lives on the `Bag`, not here: every
/// diagnostic in a bag comes from the same module, so storing it per
/// diagnostic would repeat it and let the two disagree.
pub const Diagnostic = struct {
    level: Level,
    span: Span,
    message: []const u8,
};

pub const Bag = struct {
    /// Module path used as the `path:line:col` prefix.
    path: []const u8 = "",
    /// The module's source buffer, when the caller has it. Without it a
    /// diagnostic still renders its location and message, just no snippet.
    source: ?[]const u8 = null,
    list: std.ArrayList(Diagnostic) = .empty,

    pub fn init(path: []const u8, source: ?[]const u8) Bag {
        return .{ .path = path, .source = source };
    }

    pub fn deinit(self: *Bag, allocator: std.mem.Allocator) void {
        self.list.deinit(allocator);
    }

    pub fn push(
        self: *Bag,
        allocator: std.mem.Allocator,
        level: Level,
        span: Span,
        message: []const u8,
    ) !void {
        try self.list.append(allocator, .{
            .level = level,
            .span = span,
            .message = message,
        });
    }

    pub fn err(self: *Bag, allocator: std.mem.Allocator, span: Span, message: []const u8) !void {
        try self.push(allocator, .err, span, message);
    }

    pub fn warning(self: *Bag, allocator: std.mem.Allocator, span: Span, message: []const u8) !void {
        try self.push(allocator, .warning, span, message);
    }

    pub fn note(self: *Bag, allocator: std.mem.Allocator, span: Span, message: []const u8) !void {
        try self.push(allocator, .note, span, message);
    }

    pub fn hasErrors(self: *const Bag) bool {
        for (self.list.items) |d| {
            if (d.level == .err) return true;
        }
        return false;
    }

    pub fn count(self: *const Bag, level: Level) usize {
        var n: usize = 0;
        for (self.list.items) |d| {
            if (d.level == level) n += 1;
        }
        return n;
    }

    /// Render one diagnostic as
    ///
    ///     path:line:col: error: message
    ///         <the offending source line>
    ///         <spaces>^~~
    ///
    /// The snippet is omitted when no source buffer was supplied.
    pub fn render(self: *const Bag, d: Diagnostic, writer: *Io.Writer) !void {
        try writer.print("{s}:{d}:{d}: {s}: {s}\n", .{
            self.path,
            d.span.line,
            d.span.column,
            d.level.text(),
            d.message,
        });

        const source = self.source orelse return;
        // The byte offset is authoritative; recounting newlines from the
        // recorded line number would drift if either one were stale.
        if (d.span.start > source.len) return;
        const line = lineAt(source, d.span.start);
        try writer.print("    {s}\n    ", .{line.text});

        // Echo tabs so the caret lands under the column when the line mixes
        // tabs and spaces.
        const caret_at = @min(line.offset_in_line, line.text.len);
        for (line.text[0..caret_at]) |c| {
            try writer.writeByte(if (c == '\t') '\t' else ' ');
        }
        const width = if (d.span.end > d.span.start)
            @min(d.span.end - d.span.start, line.text.len - caret_at)
        else
            0;
        try writer.writeByte('^');
        var i: usize = 1;
        while (i < width) : (i += 1) try writer.writeByte('~');
        try writer.writeByte('\n');
    }

    pub fn printAll(self: *const Bag, writer: *Io.Writer) !void {
        for (self.list.items) |d| try self.render(d, writer);
    }
};

const SourceLine = struct {
    /// The line's bytes, without its terminating newline.
    text: []const u8,
    /// Byte offset of the reported position within `text`.
    offset_in_line: usize,
};

/// The source line containing byte offset `at`, found by scanning outward
/// from that offset rather than by counting lines from the top.
fn lineAt(source: []const u8, at: u32) SourceLine {
    const pos = @min(@as(usize, at), source.len);
    var begin = pos;
    while (begin > 0 and source[begin - 1] != '\n') begin -= 1;
    var end = pos;
    while (end < source.len and source[end] != '\n') end += 1;
    var text = source[begin..end];
    if (text.len > 0 and text[text.len - 1] == '\r') text = text[0 .. text.len - 1];
    return .{ .text = text, .offset_in_line = pos - begin };
}

// ── tests ───────────────────────────────────────────────────────────────

fn renderToBuf(bag: *const Bag, buf: []u8) ![]u8 {
    var w = Io.Writer.fixed(buf);
    try bag.printAll(&w);
    return w.buffered();
}

test "a diagnostic renders path:line:col with the source line and a caret" {
    const source =
        \\pub fn main() {
        \\  buf.len = 3
        \\}
    ;
    var bag: Bag = .init("examples/ownership.cell", source);
    defer bag.deinit(std.testing.allocator);

    // `buf` on line 2 starts at column 3.
    const start: u32 = @intCast(std.mem.indexOf(u8, source, "buf").?);
    try bag.err(
        std.testing.allocator,
        .{ .start = start, .end = start + 3, .line = 2, .column = 3 },
        "cannot assign to immutable binding",
    );

    var buf: [512]u8 = undefined;
    const out = try renderToBuf(&bag, &buf);
    try std.testing.expectEqualStrings(
        \\examples/ownership.cell:2:3: error: cannot assign to immutable binding
        \\      buf.len = 3
        \\      ^~~
        \\
    , out);
}

test "without a source buffer only the location line is rendered" {
    var bag: Bag = .init("t.cell", null);
    defer bag.deinit(std.testing.allocator);
    try bag.warning(
        std.testing.allocator,
        .{ .start = 0, .end = 1, .line = 7, .column = 11 },
        "unused binding",
    );

    var buf: [256]u8 = undefined;
    const out = try renderToBuf(&bag, &buf);
    try std.testing.expectEqualStrings("t.cell:7:11: warning: unused binding\n", out);
}

test "all three levels render their own word and are counted separately" {
    var bag: Bag = .init("t.cell", null);
    defer bag.deinit(std.testing.allocator);
    const span: Span = .{ .start = 0, .end = 0, .line = 1, .column = 1 };
    try bag.err(std.testing.allocator, span, "boom");
    try bag.warning(std.testing.allocator, span, "careful");
    try bag.note(std.testing.allocator, span, "context");

    try std.testing.expect(bag.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), bag.count(.err));
    try std.testing.expectEqual(@as(usize, 1), bag.count(.warning));
    try std.testing.expectEqual(@as(usize, 1), bag.count(.note));

    var buf: [256]u8 = undefined;
    const out = try renderToBuf(&bag, &buf);
    try std.testing.expectEqualStrings(
        \\t.cell:1:1: error: boom
        \\t.cell:1:1: warning: careful
        \\t.cell:1:1: note: context
        \\
    , out);
}

test "an empty bag has no errors and renders nothing" {
    var bag: Bag = .init("t.cell", null);
    defer bag.deinit(std.testing.allocator);
    try std.testing.expect(!bag.hasErrors());

    var buf: [64]u8 = undefined;
    const out = try renderToBuf(&bag, &buf);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "lineAt finds the containing line and the offset within it" {
    const source = "aa\nbbbb\ncc\n";
    const first = lineAt(source, 1);
    try std.testing.expectEqualStrings("aa", first.text);
    try std.testing.expectEqual(@as(usize, 1), first.offset_in_line);

    const second = lineAt(source, 5);
    try std.testing.expectEqualStrings("bbbb", second.text);
    try std.testing.expectEqual(@as(usize, 2), second.offset_in_line);

    // A position past the last newline still resolves to the final line.
    const past = lineAt(source, @intCast(source.len));
    try std.testing.expectEqualStrings("", past.text);
}

test "a caret under a tab-indented line echoes the tab" {
    const source = "fn f() {\n\tlet x = 1\n}\n";
    var bag: Bag = .init("t.cell", source);
    defer bag.deinit(std.testing.allocator);
    const start: u32 = @intCast(std.mem.indexOf(u8, source, "let").?);
    try bag.err(
        std.testing.allocator,
        .{ .start = start, .end = start + 3, .line = 2, .column = 2 },
        "nope",
    );

    var buf: [256]u8 = undefined;
    const out = try renderToBuf(&bag, &buf);
    try std.testing.expectEqualStrings(
        "t.cell:2:2: error: nope\n" ++
            "    \tlet x = 1\n" ++
            "    \t^~~\n",
        out,
    );
}
