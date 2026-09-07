//! Load a Cell compilation unit from a path, pairing module and body files.
//!
//! Parse, check, and emit stay pure functions of one unit. This stage sits in
//! front of them: it classifies the path by extension, finds a same-directory
//! stem-mate when the path is a body, and merges the module's declarations
//! into the body unit so names declared only in the module resolve.

const std = @import("std");
const Io = std.Io;
const ast = @import("ast.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");

const path_mod = Io.Dir.path;

pub const Role = enum { module, body, other };

pub const Loaded = struct {
    module: ast.Module,
    source: []const u8,
};

pub fn classify(path: []const u8) Role {
    const ext = path_mod.extension(path);
    if (eql(ext, ".cell") or eql(ext, ".cel")) return .module;
    if (eql(ext, ".body") or eql(ext, ".bod")) return .body;
    return .other;
}

/// Read `path` relative to `dir`. A `.body`/`.bod` file is paired with a
/// same-directory `.cell` or `.cel` stem-mate; the module's declarations are
/// merged into the body unit. `.cell`/`.cel` and unknown extensions load as a
/// standalone module.
pub fn load(
    allocator: std.mem.Allocator,
    io: Io,
    dir: Io.Dir,
    path: []const u8,
    writer: *Io.Writer,
) !Loaded {
    const source = try dir.readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024));
    var compiled = try parse(allocator, source, path);

    if (classify(path) != .body) {
        return .{ .module = compiled, .source = source };
    }

    const mate = findModuleMate(allocator, io, dir, path) catch |err| {
        const base = path_mod.basename(path);
        const stem = path_mod.stem(base);
        switch (err) {
            error.MissingModule => {
                try writer.print(
                    "{s}:1:1: error: body file '{s}' has no module file (expected {s}.cell or {s}.cel)\n",
                    .{ path, base, stem, stem },
                );
                return error.MissingModule;
            },
            error.AmbiguousModule => {
                try writer.print(
                    "{s}:1:1: error: ambiguous module '{s}': both {s}.cell and {s}.cel exist\n",
                    .{ path, stem, stem, stem },
                );
                return error.AmbiguousModule;
            },
            else => |e| return e,
        }
    };

    const mate_source = try dir.readFileAlloc(io, mate, allocator, .limited(16 * 1024 * 1024));
    const mate_mod = try parse(allocator, mate_source, mate);
    compiled = try merge(allocator, mate_mod, compiled);
    return .{ .module = compiled, .source = source };
}

fn parse(allocator: std.mem.Allocator, source: []const u8, path: []const u8) !ast.Module {
    var lex = lexer.Lexer.init(source, path);
    var tokens = try lex.tokenizeAll(allocator);
    defer tokens.deinit(allocator);
    var p = parser.Parser.init(allocator, tokens.items, path);
    return try p.parseModule();
}

fn findModuleMate(
    allocator: std.mem.Allocator,
    io: Io,
    dir: Io.Dir,
    path: []const u8,
) ![]const u8 {
    const parent = path_mod.dirname(path);
    const stem = path_mod.stem(path_mod.basename(path));
    const cell_path = try joinMate(allocator, parent, stem, ".cell");
    const cel_path = try joinMate(allocator, parent, stem, ".cel");
    const has_cell = fileExists(dir, io, cell_path);
    const has_cel = fileExists(dir, io, cel_path);
    if (has_cell and has_cel) return error.AmbiguousModule;
    if (has_cell) return cell_path;
    if (has_cel) return cel_path;
    return error.MissingModule;
}

fn joinMate(
    allocator: std.mem.Allocator,
    parent: ?[]const u8,
    stem: []const u8,
    ext: []const u8,
) ![]u8 {
    if (parent) |d| {
        return std.fmt.allocPrint(allocator, "{s}/{s}{s}", .{ d, stem, ext });
    }
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ stem, ext });
}

fn fileExists(dir: Io.Dir, io: Io, sub: []const u8) bool {
    dir.access(io, sub, .{}) catch return false;
    return true;
}

/// Module declarations first, then body items. A function the body defines
/// is omitted from the module side so collectItems does not see two signatures.
fn merge(allocator: std.mem.Allocator, module_side: ast.Module, body_side: ast.Module) !ast.Module {
    var items: std.ArrayList(ast.Item) = .empty;
    errdefer items.deinit(allocator);

    for (module_side.items) |item| {
        if (fnName(item)) |name| {
            if (bodyDefines(body_side, name)) continue;
        }
        try items.append(allocator, item);
    }
    for (body_side.items) |item| {
        try items.append(allocator, item);
    }

    return .{
        .path = body_side.path,
        .items = try items.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

fn fnName(item: ast.Item) ?[]const u8 {
    return switch (item.kind) {
        .fn_def => |f| f.name,
        else => null,
    };
}

fn bodyDefines(body_side: ast.Module, name: []const u8) bool {
    for (body_side.items) |item| {
        switch (item.kind) {
            .fn_def => |f| {
                if (eql(f.name, name)) return true;
            },
            else => {},
        }
    }
    return false;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

test "classify maps the four pairing extensions" {
    try std.testing.expectEqual(Role.module, classify("geometry.cell"));
    try std.testing.expectEqual(Role.module, classify("geometry.cel"));
    try std.testing.expectEqual(Role.body, classify("geometry.body"));
    try std.testing.expectEqual(Role.body, classify("geometry.bod"));
    try std.testing.expectEqual(Role.other, classify("notes.txt"));
    try std.testing.expectEqual(Role.module, classify("examples/pairing/geometry.cell"));
}
