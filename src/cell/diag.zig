const std = @import("std");

pub const Level = enum { note, warning, err };

pub const Diagnostic = struct {
    level: Level,
    path: []const u8,
    line: u32,
    column: u32,
    message: []const u8,

    pub fn format(self: Diagnostic, writer: anytype) !void {
        try writer.print("{s}:{d}:{d}: {s}: {s}\n", .{
            self.path,
            self.line,
            self.column,
            @tagName(self.level),
            self.message,
        });
    }
};

pub const Bag = struct {
    list: std.ArrayList(Diagnostic) = .empty,

    pub fn deinit(self: *Bag, allocator: std.mem.Allocator) void {
        self.list.deinit(allocator);
    }

    pub fn push(
        self: *Bag,
        allocator: std.mem.Allocator,
        level: Level,
        path: []const u8,
        line: u32,
        column: u32,
        message: []const u8,
    ) !void {
        try self.list.append(allocator, .{
            .level = level,
            .path = path,
            .line = line,
            .column = column,
            .message = message,
        });
    }

    pub fn hasErrors(self: *const Bag) bool {
        for (self.list.items) |d| {
            if (d.level == .err) return true;
        }
        return false;
    }

    pub fn printAll(self: *const Bag, writer: anytype) !void {
        for (self.list.items) |d| try d.format(writer);
    }
};
