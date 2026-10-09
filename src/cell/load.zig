//! Load a Cell compilation unit from a path, pairing module and body files.
//!
//! Parse, check, and emit stay pure functions of one unit. This stage sits in
//! front of them: it classifies the path by extension, finds a same-directory
//! stem-mate for either side, and merges the module's declarations
//! into the body unit so names declared only in the module resolve.

const std = @import("std");
const Io = std.Io;
const ast = @import("ast.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const diag = @import("diag.zig");
const source_map = @import("source_map.zig");

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

/// Read `path` relative to `dir`. Both sides of a module/body pair load the
/// same merged unit. Unknown extensions retain the standalone fallback.
pub fn load(
    allocator: std.mem.Allocator,
    io: Io,
    dir: Io.Dir,
    path: []const u8,
    writer: *Io.Writer,
) !Loaded {
    const source = try dir.readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024));
    var compiled = try parse(allocator, source, path, writer);

    if (classify(path) == .module) {
        const mate = findBodyMate(allocator, io, dir, path) catch |err| {
            if (err == error.AmbiguousBody) {
                try writer.print("{s}:1:1: error: ambiguous body: both .body and .bod mates exist\n", .{path});
            }
            return err;
        };
        if (mate) |body_path| {
            const body_source = try dir.readFileAlloc(io, body_path, allocator, .limited(16 * 1024 * 1024));
            const body_mod = try parse(allocator, body_source, body_path, writer);
            compiled = try merge(allocator, compiled, body_mod, writer);
            return .{ .module = compiled, .source = body_source };
        }
        return .{ .module = compiled, .source = source };
    }
    if (classify(path) != .body) {
        return .{ .module = compiled, .source = source };
    }

    _ = findBodyMate(allocator, io, dir, path) catch |err| {
        if (err == error.AmbiguousBody) {
            try writer.print("{s}:1:1: error: ambiguous body: both .body and .bod mates exist\n", .{path});
        }
        return err;
    };

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

fn findBodyMate(allocator: std.mem.Allocator, io: Io, dir: Io.Dir, path: []const u8) !?[]const u8 {
    const parent = path_mod.dirname(path);
    const stem = path_mod.stem(path_mod.basename(path));
    const body_path = try joinMate(allocator, parent, stem, ".body");
    const bod_path = try joinMate(allocator, parent, stem, ".bod");
    const has_body = try accessibleFile(dir, io, body_path);
    const has_bod = try accessibleFile(dir, io, bod_path);
    if (has_body and has_bod) return error.AmbiguousBody;
    if (has_body) return body_path;
    if (has_bod) return bod_path;
    return null;
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
    var module = p.parseModule() catch |err| switch (err) {
        error.UnexpectedToken, error.InvalidLiteral => {
            var bag: diag.Bag = .init(path, source);
            defer bag.deinit(allocator);
            try p.reportInto(&bag, allocator);
            try bag.printAll(writer);
            return error.ParseFailed;
        },
        else => |e| return e,
    };
    source_map.attach(&module, source);
    return module;
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
    const has_cell = try accessibleFile(dir, io, cell_path);
    const has_cel = try accessibleFile(dir, io, cel_path);
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

fn accessibleFile(dir: Io.Dir, io: Io, sub: []const u8) !bool {
    dir.access(io, sub, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
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
        var merged_item = item;
        // The interface owns visibility, including a private declaration
        // whose body redundantly writes pub. The body cannot widen exports.
        if (merged_item.kind == .fn_def) {
            if (findFn(module_side, merged_item.kind.fn_def.name)) |decl| {
                merged_item.kind.fn_def.is_public = decl.is_public;
            }
        }
        try items.append(allocator, merged_item);
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

/// All graph allocations, sources and parsed nodes share the caller's arena.
/// Dependencies precede importers, and the entry is the last unit.
pub const Graph = struct {
    units: []Unit,

    pub fn entry(self: *const Graph) *const Unit {
        return &self.units[self.units.len - 1];
    }
};

pub const Unit = struct {
    name: []const u8,
    /// File spelling used for diagnostics, or an embedded std identity.
    path: []const u8,
    /// Canonical module file identity, even when entered via its body mate.
    identity: []const u8,
    module: ast.Module,
    source: []const u8,
    imports: []Import,
    is_entry: bool,
};

pub const Import = struct {
    name: []const u8,
    unit: usize,
    span: ast.Span,
};

pub const StdModule = struct { name: []const u8, source: []const u8 };
pub const GraphOptions = struct {
    module_roots: []const []const u8 = &.{},
    std_modules: []const StdModule = &.{},
};

pub fn isDiagnosticError(err: anyerror) bool {
    return switch (err) {
        error.TypeError,
        error.MissingModule,
        error.AmbiguousModule,
        error.AmbiguousBody,
        error.PairingMismatch,
        error.ParseFailed,
        error.InvalidModuleRoot,
        error.ModuleNotFound,
        error.ImportCycle,
        error.ModuleNameCollision,
        error.AmbiguousStdModule,
        error.ModuleLoadFailed,
        => true,
        else => false,
    };
}

pub fn loadGraph(
    allocator: std.mem.Allocator,
    io: Io,
    dir: Io.Dir,
    entry_path: []const u8,
    options: GraphOptions,
    writer: *Io.Writer,
) !Graph {
    var builder: GraphBuilder = .{
        .allocator = allocator,
        .io = io,
        .dir = dir,
        .options = options,
        .writer = writer,
        .seen = .init(allocator),
        .names = .init(allocator),
    };
    defer builder.seen.deinit();
    defer builder.names.deinit();
    defer builder.stack.deinit(allocator);
    errdefer builder.units.deinit(allocator);
    for (options.module_roots) |root| {
        const opened = dir.openDir(io, root, .{}) catch |err| {
            try writer.print("{s}:1:1: error: --module-root '{s}': {s}\n", .{ entry_path, root, @errorName(err) });
            return error.InvalidModuleRoot;
        };
        opened.close(io);
    }
    const name = path_mod.stem(path_mod.basename(entry_path));
    _ = try builder.visit(.{ .path = entry_path }, name, true, null);
    return .{ .units = try builder.units.toOwnedSlice(allocator) };
}

const GraphBuilder = struct {
    allocator: std.mem.Allocator,
    io: Io,
    dir: Io.Dir,
    options: GraphOptions,
    writer: *Io.Writer,
    units: std.ArrayList(Unit) = .empty,
    /// null denotes a unit on the active DFS stack; an index denotes done.
    seen: std.StringHashMap(?usize),
    names: std.StringHashMap(struct { identity: []const u8, path: []const u8 }),
    stack: std.ArrayList([]const u8) = .empty,

    const Resolved = union(enum) { path: []const u8, embedded: StdModule };
    const Location = struct { path: []const u8, span: ast.Span };

    fn visit(self: *GraphBuilder, resolved: Resolved, name: []const u8, is_entry: bool, location: ?Location) anyerror!usize {
        const path = switch (resolved) {
            .path => |p| p,
            .embedded => |m| try std.fmt.allocPrint(self.allocator, "std.{s}", .{m.name}),
        };
        const identity = self.identityOf(resolved, path) catch |err| {
            try self.writer.print("{s}:1:1: error: cannot load module: {s}\n", .{ path, @errorName(err) });
            return error.ModuleLoadFailed;
        };
        if (self.seen.get(identity)) |index| {
            if (index) |done| return done;
            const from = location.?;
            try self.writer.print("{s}:{d}:{d}: error: import cycle: ", .{ from.path, from.span.line, from.span.column });
            for (self.stack.items) |active| try self.writer.print("{s} -> ", .{active});
            try self.writer.print("{s}\n", .{path});
            return error.ImportCycle;
        }
        // Nominal identities and emitted names use the module's leaf name.
        // Different files may not silently acquire the same namespace even
        // when they are reached through different intermediate importers.
        if (!is_entry) {
            if (self.names.get(name)) |prior| {
                if (!eql(prior.identity, identity)) {
                    const from = location.?;
                    try self.writer.print("{s}:{d}:{d}: error: module name '{s}' is already imported from {s}; cannot also load {s}\n", .{
                        from.path, from.span.line, from.span.column, name, prior.path, path,
                    });
                    return error.ModuleNameCollision;
                }
            } else {
                try self.names.put(name, .{ .identity = identity, .path = path });
            }
        }
        try self.seen.put(identity, null);
        try self.stack.append(self.allocator, path);
        defer _ = self.stack.pop();
        const loaded: Loaded = switch (resolved) {
            .path => |p| load(self.allocator, self.io, self.dir, p, self.writer) catch |err| {
                if (isDiagnosticError(err)) return err;
                try self.writer.print("{s}:1:1: error: cannot read module: {s}\n", .{ p, @errorName(err) });
                return error.ModuleLoadFailed;
            },
            .embedded => |m| .{
                .module = try parse(self.allocator, m.source, path, self.writer),
                .source = m.source,
            },
        };
        var imports: std.ArrayList(Import) = .empty;
        errdefer imports.deinit(self.allocator);
        for (loaded.module.items) |item| {
            if (item.kind != .use_decl) continue;
            const use_path = item.kind.use_decl;
            const qualifier = if (std.mem.lastIndexOfScalar(u8, use_path, '.')) |dot| use_path[dot + 1 ..] else use_path;
            const from: Location = .{ .path = item.span.path orelse loaded.module.path, .span = item.span };
            const dependency = self.resolve(use_path, path, from) catch |err| {
                if (isDiagnosticError(err)) return err;
                try self.writer.print("{s}:{d}:{d}: error: cannot resolve module '{s}': {s}\n", .{ from.path, from.span.line, from.span.column, use_path, @errorName(err) });
                return error.ModuleLoadFailed;
            };
            const dependency_index = try self.visit(dependency, qualifier, false, from);
            for (imports.items) |prior| {
                if (!eql(prior.name, qualifier)) continue;
                if (prior.unit != dependency_index) {
                    try self.writer.print("{s}:{d}:{d}: error: module name '{s}' is already imported from {s}\n", .{
                        from.path, from.span.line, from.span.column, qualifier, self.units.items[prior.unit].path,
                    });
                    return error.ModuleNameCollision;
                }
            }
            // Repeating an import of the same unit is idempotent.
            var duplicate = false;
            for (imports.items) |prior| {
                if (prior.unit == dependency_index and eql(prior.name, qualifier)) duplicate = true;
            }
            if (!duplicate) try imports.append(self.allocator, .{ .name = qualifier, .unit = dependency_index, .span = item.span });
        }
        const index = self.units.items.len;
        try self.units.append(self.allocator, .{
            .name = name,
            .path = path,
            .identity = identity,
            .module = loaded.module,
            .source = loaded.source,
            .imports = try imports.toOwnedSlice(self.allocator),
            .is_entry = is_entry,
        });
        try self.seen.put(identity, index);
        return index;
    }

    fn identityOf(self: *GraphBuilder, resolved: Resolved, path: []const u8) ![]const u8 {
        return switch (resolved) {
            .path => |p| blk: {
                const module_path = if (classify(p) == .body)
                    try findModuleMate(self.allocator, self.io, self.dir, p)
                else
                    p;
                break :blk try self.dir.realPathFileAlloc(self.io, module_path, self.allocator);
            },
            .embedded => path,
        };
    }

    fn resolve(self: *GraphBuilder, use_path: []const u8, importer: []const u8, from: Location) !Resolved {
        if (eql(use_path, "std")) {
            try self.writer.print("{s}:{d}:{d}: error: 'std' is the standard root, not a module\n", .{ from.path, from.span.line, from.span.column });
            return error.ModuleNotFound;
        }
        if (std.mem.startsWith(u8, use_path, "std.")) {
            const rest = use_path[4..];
            var found: ?StdModule = null;
            for (self.options.std_modules) |m| {
                if (!eql(m.name, rest)) continue;
                if (found != null) {
                    try self.writer.print("{s}:{d}:{d}: error: ambiguous embedded module '{s}'\n", .{ from.path, from.span.line, from.span.column, use_path });
                    return error.AmbiguousStdModule;
                }
                found = m;
            }
            if (found) |m| return .{ .embedded = m };
            try self.writer.print("{s}:{d}:{d}: error: module '{s}' not found; the embedded std root provides:", .{ from.path, from.span.line, from.span.column, use_path });
            for (self.options.std_modules) |m| try self.writer.print(" std.{s}", .{m.name});
            try self.writer.writeByte('\n');
            return error.ModuleNotFound;
        }
        const relative = try self.allocator.dupe(u8, use_path);
        for (relative) |*c| if (c.* == '.') {
            c.* = path_mod.sep;
        };
        var searched: Io.Writer.Allocating = .init(self.allocator);
        defer searched.deinit();
        const local_root = path_mod.dirname(importer) orelse "";
        for (0..self.options.module_roots.len + 1) |i| {
            const root = if (i == 0) local_root else self.options.module_roots[i - 1];
            const base = try path_mod.join(self.allocator, &.{ root, relative });
            const cell_path = try std.fmt.allocPrint(self.allocator, "{s}.cell", .{base});
            const cel_path = try std.fmt.allocPrint(self.allocator, "{s}.cel", .{base});
            const has_cell = try accessibleFile(self.dir, self.io, cell_path);
            const has_cel = try accessibleFile(self.dir, self.io, cel_path);
            if (has_cell and has_cel) {
                try self.writer.print("{s}:{d}:{d}: error: ambiguous module '{s}': both {s} and {s} exist\n", .{ from.path, from.span.line, from.span.column, use_path, cell_path, cel_path });
                return error.AmbiguousModule;
            }
            if (has_cell) return .{ .path = cell_path };
            if (has_cel) return .{ .path = cel_path };
            try searched.writer.print("{s}{s}, {s}", .{ if (i == 0) "" else ", ", cell_path, cel_path });
        }
        try self.writer.print("{s}:{d}:{d}: error: module '{s}' not found; searched {s}\n", .{ from.path, from.span.line, from.span.column, use_path, searched.written() });
        return error.ModuleNotFound;
    }
};

comptime {
    _ = @import("load_tests.zig");
}

test "classify maps the four pairing extensions" {
    try std.testing.expectEqual(Role.module, classify("geometry.cell"));
    try std.testing.expectEqual(Role.module, classify("geometry.cel"));
    try std.testing.expectEqual(Role.body, classify("geometry.body"));
    try std.testing.expectEqual(Role.body, classify("geometry.bod"));
    try std.testing.expectEqual(Role.other, classify("notes.txt"));
    try std.testing.expectEqual(Role.module, classify("examples/pairing/geometry.cell"));
}
