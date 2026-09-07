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
const diag = @import("diag.zig");

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
    var compiled = try parse(allocator, source, path, writer);

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
    const mate_mod = try parse(allocator, mate_source, mate, writer);
    compiled = try merge(allocator, mate_mod, compiled, writer);
    return .{ .module = compiled, .source = source };
}

/// Parse one unit, rendering a parse failure as a diagnostic rather than
/// letting `error.UnexpectedToken` escape to the CLI.
///
/// The parser already records the position and message of the failure that
/// aborted it and can push that into a bag; nothing was calling it on this
/// path, so a syntax error reached `main` as a raw Zig error and printed a
/// STACK TRACE instead of a caret. That was invisible while every rejected
/// example happened to fail in the typechecker instead. Promoting SPEC 2.5's
/// reserved words to real keywords made `while (c) { }` a parse error and
/// exposed it immediately.
fn parse(
    allocator: std.mem.Allocator,
    source: []const u8,
    path: []const u8,
    writer: *Io.Writer,
) !ast.Module {
    var lex = lexer.Lexer.init(source, path);
    var tokens = try lex.tokenizeAll(allocator);
    defer tokens.deinit(allocator);
    var p = parser.Parser.init(allocator, tokens.items, path);
    return p.parseModule() catch |err| switch (err) {
        error.UnexpectedToken, error.InvalidLiteral => {
            var bag: diag.Bag = .init(path, source);
            defer bag.deinit(allocator);
            try p.reportInto(&bag, allocator);
            try bag.printAll(writer);
            return error.ParseFailed;
        },
        else => |e| return e,
    };
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
/// SPEC 1.2 rules 8, 10, and 11 are checked here, at the body definition.
fn merge(
    allocator: std.mem.Allocator,
    module_side: ast.Module,
    body_side: ast.Module,
    writer: *Io.Writer,
) !ast.Module {
    var failed = false;
    const module_base = path_mod.basename(module_side.path);
    const body_base = path_mod.basename(body_side.path);

    for (body_side.items) |item| {
        switch (item.kind) {
            .fn_def => |f| {
                const decl = findFn(module_side, f.name);
                if (f.is_public and decl == null) {
                    try writer.print(
                        "{s}:{d}:{d}: error: '{s}' is defined in {s} but not declared in {s}\n",
                        .{ body_side.path, item.span.line, item.span.column, f.name, body_base, module_base },
                    );
                    failed = true;
                    continue;
                }
                if (decl) |d| {
                    if (d.body != null and f.body != null) {
                        try writer.print(
                            "{s}:{d}:{d}: error: '{s}' already has a body in {s}\n",
                            .{ body_side.path, item.span.line, item.span.column, f.name, module_base },
                        );
                        failed = true;
                        continue;
                    }
                    if (try reportSignatureMismatch(writer, body_side.path, item.span, f, d, module_base)) {
                        failed = true;
                    }
                }
            },
            else => {},
        }
    }

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

    if (failed) return error.PairingMismatch;

    return .{
        .path = body_side.path,
        .items = try items.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

const FnDecl = ast.FnDef;

fn findFn(module_side: ast.Module, name: []const u8) ?FnDecl {
    for (module_side.items) |item| {
        switch (item.kind) {
            .fn_def => |f| {
                if (eql(f.name, name)) return f;
            },
            else => {},
        }
    }
    return null;
}

fn reportSignatureMismatch(
    writer: *Io.Writer,
    path: []const u8,
    span: ast.Span,
    defined: ast.FnDef,
    declared: ast.FnDef,
    module_base: []const u8,
) !bool {
    _ = module_base;
    if (declared.params.len != defined.params.len) {
        try writer.print(
            "{s}:{d}:{d}: error: '{s}' body does not match its declaration: expected {d} parameters, found {d}\n",
            .{ path, span.line, span.column, defined.name, declared.params.len, defined.params.len },
        );
        return true;
    }
    for (declared.params, defined.params, 0..) |want, have, i| {
        if (want.ownership != have.ownership or !typeEq(&want.ty, &have.ty)) {
            var want_buf: [128]u8 = undefined;
            var have_buf: [128]u8 = undefined;
            try writer.print(
                "{s}:{d}:{d}: error: '{s}' body does not match its declaration: parameter {d} is declared '{s} {s}' but defined '{s} {s}'\n",
                .{
                    path,
                    span.line,
                    span.column,
                    defined.name,
                    i + 1,
                    ownName(want.ownership),
                    typeStr(&want.ty, &want_buf),
                    ownName(have.ownership),
                    typeStr(&have.ty, &have_buf),
                },
            );
            return true;
        }
    }
    if (!optionalTypeEq(declared.return_type, defined.return_type)) {
        var want_buf: [128]u8 = undefined;
        var have_buf: [128]u8 = undefined;
        try writer.print(
            "{s}:{d}:{d}: error: '{s}' body does not match its declaration: return type is declared '{s}' but defined '{s}'\n",
            .{
                path,
                span.line,
                span.column,
                defined.name,
                optionalTypeStr(declared.return_type, &want_buf),
                optionalTypeStr(defined.return_type, &have_buf),
            },
        );
        return true;
    }
    return false;
}

fn ownName(o: ast.Ownership) []const u8 {
    return switch (o) {
        .owned => "owned",
        .shared => "shared",
        .exclusive => "exclusive",
        .arc => "arc",
        .copy => "copy",
    };
}

fn typeEq(a: *const ast.TypeExpr, b: *const ast.TypeExpr) bool {
    return switch (a.*) {
        .unit => b.* == .unit,
        .name => |n| switch (b.*) {
            .name => |m| eql(n, m),
            else => false,
        },
        .optional => |inner| switch (b.*) {
            .optional => |other| typeEq(inner, other),
            else => false,
        },
        .list => |inner| switch (b.*) {
            .list => |other| typeEq(inner, other),
            else => false,
        },
        .result => |r| switch (b.*) {
            .result => |s| typeEq(r.ok, s.ok) and typeEq(r.err, s.err),
            else => false,
        },
        .ref => |r| switch (b.*) {
            .ref => |s| r.ownership == s.ownership and typeEq(r.inner, s.inner),
            else => false,
        },
    };
}

fn optionalTypeEq(a: ?ast.TypeExpr, b: ?ast.TypeExpr) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return typeEq(&a.?, &b.?);
}

fn typeStr(ty: *const ast.TypeExpr, buf: *[128]u8) []const u8 {
    var w = Io.Writer.fixed(buf);
    writeType(&w, ty) catch return "?";
    return w.buffered();
}

fn optionalTypeStr(ty: ?ast.TypeExpr, buf: *[128]u8) []const u8 {
    if (ty) |t| return typeStr(&t, buf);
    return "()";
}

fn writeType(w: *Io.Writer, ty: *const ast.TypeExpr) !void {
    switch (ty.*) {
        .name => |n| try w.writeAll(n),
        .unit => try w.writeAll("()"),
        .optional => |inner| {
            try writeType(w, inner);
            try w.writeByte('?');
        },
        .list => |inner| {
            try w.writeAll("[");
            try writeType(w, inner);
            try w.writeAll("]");
        },
        .result => |r| {
            try writeType(w, r.ok);
            try w.writeAll(", ");
            try writeType(w, r.err);
        },
        .ref => |r| {
            try w.print("{s} ", .{ownName(r.ownership)});
            try writeType(w, r.inner);
        },
    }
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
