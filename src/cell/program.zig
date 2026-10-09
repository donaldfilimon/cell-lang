//! Compose a previously checked module graph for the bootstrap emitters.
//! Inputs and all parser-owned nodes remain untouched. The caller's arena owns
//! the composed tree; run whole-program borrow checking before lowering it.
const std = @import("std");
const ast = @import("ast.zig");
const load = @import("load.zig");
const symbols = @import("symbols.zig");
const types = @import("types.zig");
const Io = std.Io;

pub fn compose(allocator: std.mem.Allocator, graph: *const load.Graph, table: *const symbols.Table, writer: *Io.Writer) !ast.Module {
    if (graph.units.len == 0) return error.InvalidProgram;
    var result: std.ArrayList(ast.Item) = .empty;
    defer result.deinit(allocator);
    var externs = std.StringHashMap(void).init(allocator);
    defer externs.deinit();
    var entry_externs = std.StringHashMap(void).init(allocator);
    defer entry_externs.deinit();
    for (graph.units, 0..) |unit, index| {
        if (!unit.is_entry) continue;
        for (unit.module.items) |item| {
            if (item.kind == .fn_def and item.kind.fn_def.body == null) {
                const entry = table.get(index, item.kind.fn_def.name) orelse return error.InvalidProgram;
                try entry_externs.put(entry.canonical_name, {});
            }
        }
    }
    for (graph.units, 0..) |unit, index| {
        var cloner = Cloner{ .allocator = allocator, .graph = graph, .table = table, .writer = writer, .unit = index };
        defer cloner.locals.deinit(allocator);
        for (unit.module.items) |item| {
            if (item.kind == .use_decl) continue;
            const name = itemName(item);
            const entry = table.get(index, name) orelse return cloner.fail(item.span, "missing symbol", name);
            if (item.kind == .fn_def and item.kind.fn_def.body == null) {
                if (externs.contains(entry.symbol)) continue;
                try externs.put(entry.symbol, {});
            }
            var cloned = item;
            cloned.span = cloner.stamp(item.span);
            cloned.kind = switch (item.kind) {
                .fn_def => |f| .{ .fn_def = try cloner.function(f, entry) },
                .struct_def => |s| blk: {
                    var def = s;
                    def.name = entry.canonical_name;
                    def.symbol = entry.symbol;
                    def.fields = try allocator.dupe(ast.Field, s.fields);
                    for (def.fields) |*field| field.ty = try cloner.ty(field.ty);
                    break :blk .{ .struct_def = def };
                },
                .enum_def => |e| blk: {
                    var def = e;
                    def.name = entry.canonical_name;
                    def.symbol = entry.symbol;
                    def.variants = try allocator.dupe([]const u8, e.variants);
                    break :blk .{ .enum_def = def };
                },
                .use_decl => unreachable,
            };
            try result.append(allocator, cloned);
        }
    }
    // The entire graph was checked and its ABI claims were collision-checked
    // before this pruning. Unsupported unused imported prelude declarations
    // must not force scalar-first IR backends to lower unavailable APIs.
    var references = std.StringHashMap(void).init(allocator);
    defer references.deinit();
    for (result.items) |item| {
        if (item.kind == .fn_def) {
            if (item.kind.fn_def.body) |body| try referencedStatements(allocator, &references, body);
        }
    }
    var count: usize = 0;
    for (result.items) |item| {
        if (item.kind == .fn_def and item.kind.fn_def.body == null and
            !entry_externs.contains(item.kind.fn_def.name) and !references.contains(item.kind.fn_def.name)) continue;
        result.items[count] = item;
        count += 1;
    }
    result.shrinkRetainingCapacity(count);
    return .{ .path = graph.entry().path, .allocator = allocator, .items = try result.toOwnedSlice(allocator) };
}

fn referencedStatements(allocator: std.mem.Allocator, names: *std.StringHashMap(void), body: []const ast.Stmt) anyerror!void {
    for (body) |stmt| switch (stmt.kind) {
        .let => |decl| if (decl.value) |value| try referencedExpression(allocator, names, value),
        .expr => |value| try referencedExpression(allocator, names, value),
        .return_stmt => |value| if (value) |expression| try referencedExpression(allocator, names, expression),
        .assign => |assignment| {
            try referencedExpression(allocator, names, assignment.target);
            try referencedExpression(allocator, names, assignment.value);
        },
        .while_stmt => |loop| {
            try referencedExpression(allocator, names, loop.cond);
            try referencedStatements(allocator, names, loop.body);
        },
        .break_stmt, .continue_stmt => {},
    };
}

fn referencedExpression(allocator: std.mem.Allocator, names: *std.StringHashMap(void), expression: ast.Expr) anyerror!void {
    switch (expression.kind) {
        .ident => |name| try names.put(name, {}),
        .int, .float, .string, .bool => {},
        .call => |call| {
            try referencedExpression(allocator, names, call.callee.*);
            for (call.args) |arg| try referencedExpression(allocator, names, arg);
        },
        .binary => |binary| {
            try referencedExpression(allocator, names, binary.left.*);
            try referencedExpression(allocator, names, binary.right.*);
        },
        .unary => |unary| try referencedExpression(allocator, names, unary.operand.*),
        .annotated => |annotated| try referencedExpression(allocator, names, annotated.value.*),
        .field => |field| try referencedExpression(allocator, names, field.base.*),
        .index => |index| {
            try referencedExpression(allocator, names, index.base.*);
            try referencedExpression(allocator, names, index.index.*);
        },
        .struct_lit => |literal| for (literal.fields) |field| try referencedExpression(allocator, names, field.value),
        .list_lit => |elements| for (elements) |element| try referencedExpression(allocator, names, element),
        .block => |body| try referencedStatements(allocator, names, body),
        .if_expr => |conditional| {
            try referencedExpression(allocator, names, conditional.cond.*);
            try referencedExpression(allocator, names, conditional.then_body.*);
            if (conditional.else_body) |other| try referencedExpression(allocator, names, other.*);
        },
        .match_expr => |match| {
            try referencedExpression(allocator, names, match.scrutinee.*);
            for (match.arms) |arm| {
                if (arm.guard) |guard| try referencedExpression(allocator, names, guard.*);
                try referencedExpression(allocator, names, arm.body.*);
            }
        },
        .wrap => |wrap| if (wrap.operand) |operand| try referencedExpression(allocator, names, operand.*),
    }
}

fn itemName(item: ast.Item) []const u8 {
    return switch (item.kind) {
        .fn_def => |f| f.name,
        .struct_def => |s| s.name,
        .enum_def => |e| e.name,
        .use_decl => unreachable,
    };
}

const Cloner = struct {
    allocator: std.mem.Allocator,
    graph: *const load.Graph,
    table: *const symbols.Table,
    writer: *Io.Writer,
    unit: usize,
    locals: std.ArrayList(Binding) = .empty,
    next_local: usize = 0,

    const Binding = struct { name: []const u8, alias: []const u8 };

    fn stamp(self: *const Cloner, value: ast.Span) ast.Span {
        var result = value;
        if (result.path == null) result.path = self.graph.units[self.unit].path;
        if (result.source == null) result.source = self.graph.units[self.unit].source;
        return result;
    }

    fn fail(self: *Cloner, span: ast.Span, reason: []const u8, name: []const u8) !ast.Module {
        try self.writer.print("{s}:{d}:{d}: error: composition {s}: '{s}'\n", .{ self.graph.units[self.unit].path, span.line, span.column, reason, name });
        return error.InvalidProgram;
    }

    fn refuse(self: *Cloner, name: []const u8) !void {
        _ = try self.fail(.none, "unresolved name", name);
    }

    fn local(self: *const Cloner, name: []const u8) bool {
        return self.localName(name) != null;
    }

    fn localName(self: *const Cloner, name: []const u8) ?[]const u8 {
        var i = self.locals.items.len;
        while (i > 0) {
            i -= 1;
            const binding = self.locals.items[i];
            if (std.mem.eql(u8, binding.name, name)) return binding.alias;
        }
        return null;
    }

    fn bind(self: *Cloner, name: []const u8) ![]const u8 {
        while (true) {
            const alias = try std.fmt.allocPrint(self.allocator, "_cell_local_{d}_{d}", .{ self.unit, self.next_local });
            self.next_local += 1;
            var collision = false;
            for (self.table.entries) |entry| {
                if (std.mem.eql(u8, entry.canonical_name, alias)) {
                    collision = true;
                    break;
                }
            }
            if (collision) continue;
            try self.locals.append(self.allocator, .{ .name = name, .alias = alias });
            return alias;
        }
    }

    fn qualifier(self: *const Cloner, name: []const u8) ?usize {
        for (self.graph.units[self.unit].imports) |import| if (std.mem.eql(u8, import.name, name)) return import.unit;
        return null;
    }

    fn exported(self: *Cloner, unit: usize, name: []const u8) !*const symbols.Entry {
        const entry = self.table.get(unit, name) orelse {
            try self.refuse(name);
            unreachable;
        };
        const item = self.graph.units[unit].module.items[entry.item];
        const public = switch (item.kind) {
            .fn_def => |v| v.is_public,
            .struct_def => |v| v.is_public,
            .enum_def => |v| v.is_public,
            .use_decl => false,
        };
        if (!public) {
            _ = try self.fail(item.span, "private item", name);
            unreachable;
        }
        return entry;
    }

    fn typeName(self: *Cloner, name: []const u8) ![]const u8 {
        if (types.fromPrimitiveName(name) != null) return name;
        const entry = if (std.mem.indexOfScalar(u8, name, '.')) |dot| blk: {
            const imported = self.qualifier(name[0..dot]) orelse {
                try self.refuse(name);
                unreachable;
            };
            break :blk try self.exported(imported, name[dot + 1 ..]);
        } else self.table.get(self.unit, name) orelse {
            try self.refuse(name);
            unreachable;
        };
        if (entry.kind == .function) {
            try self.refuse(name);
            unreachable;
        }
        return entry.canonical_name;
    }

    fn ty(self: *Cloner, value: ast.TypeExpr) anyerror!ast.TypeExpr {
        return switch (value) {
            .name => |name| .{ .name = try self.typeName(name) },
            .list => |inner| .{ .list = try self.typePtr(inner.*) },
            .optional => |inner| .{ .optional = try self.typePtr(inner.*) },
            .result => |r| .{ .result = .{ .ok = try self.typePtr(r.ok.*), .err = try self.typePtr(r.err.*) } },
            .ref => |r| .{ .ref = .{ .ownership = r.ownership, .inner = try self.typePtr(r.inner.*) } },
            .unit => .unit,
        };
    }

    fn typePtr(self: *Cloner, value: ast.TypeExpr) !*ast.TypeExpr {
        const ptr = try self.allocator.create(ast.TypeExpr);
        ptr.* = try self.ty(value);
        return ptr;
    }

    fn function(self: *Cloner, f: ast.FnDef, entry: *const symbols.Entry) !ast.FnDef {
        var def = f;
        def.name = entry.canonical_name;
        def.symbol = entry.symbol;
        def.linkage = entry.linkage;
        def.params = try self.allocator.dupe(ast.Param, f.params);
        const saved = self.locals.items.len;
        defer self.locals.shrinkRetainingCapacity(saved);
        for (def.params) |*param| {
            param.ty = try self.ty(param.ty);
            // External parameter spellings participate in the prelude/header
            // contract. Without a body there are no references to capture.
            if (f.body != null) param.name = try self.bind(param.name);
        }
        if (f.return_type) |ret| def.return_type = try self.ty(ret);
        if (f.body) |body| def.body = try self.stmts(body);
        return def;
    }

    fn stmts(self: *Cloner, values: []const ast.Stmt) anyerror![]ast.Stmt {
        const saved = self.locals.items.len;
        defer self.locals.shrinkRetainingCapacity(saved);
        const result = try self.allocator.alloc(ast.Stmt, values.len);
        for (values, result) |value, *out| {
            out.* = .{ .span = self.stamp(value.span), .kind = switch (value.kind) {
                .let => |l| blk: {
                    var bound = l;
                    if (l.ty) |annotation| bound.ty = try self.ty(annotation);
                    if (l.value) |initializer| bound.value = try self.expr(initializer);
                    bound.name = try self.bind(l.name);
                    break :blk .{ .let = bound };
                },
                .expr => |e| .{ .expr = try self.expr(e) },
                .return_stmt => |e| .{ .return_stmt = if (e) |v| try self.expr(v) else null },
                .assign => |a| .{ .assign = .{ .target = try self.expr(a.target), .value = try self.expr(a.value) } },
                .while_stmt => |w| .{ .while_stmt = .{ .cond = try self.expr(w.cond), .body = try self.stmts(w.body), .label = w.label } },
                .break_stmt => |jump| .{ .break_stmt = jump },
                .continue_stmt => |jump| .{ .continue_stmt = jump },
            } };
        }
        return result;
    }

    fn exprPtr(self: *Cloner, value: ast.Expr) !*ast.Expr {
        const ptr = try self.allocator.create(ast.Expr);
        ptr.* = try self.expr(value);
        return ptr;
    }

    fn exprs(self: *Cloner, values: []const ast.Expr) ![]ast.Expr {
        const out = try self.allocator.alloc(ast.Expr, values.len);
        for (values, out) |value, *entry| entry.* = try self.expr(value);
        return out;
    }

    fn expr(self: *Cloner, value: ast.Expr) anyerror!ast.Expr {
        var result = value;
        result.span = self.stamp(value.span);
        result.kind = switch (value.kind) {
            .ident => |name| blk: {
                if (self.localName(name)) |alias| break :blk .{ .ident = alias };
                const entry = self.table.get(self.unit, name) orelse {
                    try self.refuse(name);
                    unreachable;
                };
                break :blk .{ .ident = entry.canonical_name };
            },
            .int => |v| .{ .int = v },
            .float => |v| .{ .float = v },
            .string => |v| .{ .string = v },
            .bool => |v| .{ .bool = v },
            .call => |c| .{ .call = .{ .callee = try self.exprPtr(c.callee.*), .args = try self.exprs(c.args) } },
            .binary => |b| .{ .binary = .{ .op = b.op, .left = try self.exprPtr(b.left.*), .right = try self.exprPtr(b.right.*) } },
            .unary => |u| .{ .unary = .{ .op = u.op, .operand = try self.exprPtr(u.operand.*) } },
            .annotated => |a| .{ .annotated = .{ .ownership = a.ownership, .value = try self.exprPtr(a.value.*) } },
            .field => |f| blk: {
                if (f.base.kind == .ident and !self.local(f.base.kind.ident)) {
                    if (self.qualifier(f.base.kind.ident)) |imported| {
                        const entry = try self.exported(imported, f.name);
                        break :blk .{ .ident = entry.canonical_name };
                    }
                }
                break :blk .{ .field = .{ .base = try self.exprPtr(f.base.*), .name = f.name } };
            },
            .index => |i| .{ .index = .{ .base = try self.exprPtr(i.base.*), .index = try self.exprPtr(i.index.*) } },
            .struct_lit => |sl| blk: {
                const fields = try self.allocator.dupe(ast.FieldInit, sl.fields);
                for (fields) |*field| {
                    field.span = self.stamp(field.span);
                    field.value = try self.expr(field.value);
                }
                break :blk .{ .struct_lit = .{ .name = try self.typeName(sl.name), .fields = fields } };
            },
            .list_lit => |values| .{ .list_lit = try self.exprs(values) },
            .block => |values| .{ .block = try self.stmts(values) },
            .if_expr => |i| .{ .if_expr = .{ .cond = try self.exprPtr(i.cond.*), .then_body = try self.exprPtr(i.then_body.*), .else_body = if (i.else_body) |e| try self.exprPtr(e.*) else null } },
            .match_expr => |m| blk: {
                const scrutinee = try self.exprPtr(m.scrutinee.*);
                const arms = try self.allocator.dupe(ast.MatchArm, m.arms);
                for (arms) |*arm| {
                    arm.span = self.stamp(arm.span);
                    arm.pattern.span = self.stamp(arm.pattern.span);
                    const saved = self.locals.items.len;
                    defer self.locals.shrinkRetainingCapacity(saved);
                    arm.pattern.kind = switch (arm.pattern.kind) {
                        .binding => |name| binding: {
                            break :binding .{ .binding = try self.bind(name) };
                        },
                        .wrap_pattern => |p| binding: {
                            var pattern = p;
                            if (p.binding) |name| pattern.binding = try self.bind(name);
                            break :binding .{ .wrap_pattern = pattern };
                        },
                        .enum_variant => |p| .{ .enum_variant = .{ .enum_name = if (p.enum_name) |name| try self.typeName(name) else null, .variant = p.variant } },
                        .wildcard => .wildcard,
                        .int => |v| .{ .int = v },
                        .float => |v| .{ .float = v },
                        .string => |v| .{ .string = v },
                        .bool => |v| .{ .bool = v },
                    };
                    if (arm.guard) |guard| arm.guard = try self.exprPtr(guard.*);
                    arm.body = try self.exprPtr(arm.body.*);
                }
                break :blk .{ .match_expr = .{ .scrutinee = scrutinee, .arms = arms } };
            },
            .wrap => |w| .{ .wrap = .{ .ctor = w.ctor, .operand = if (w.operand) |operand| try self.exprPtr(operand.*) else null } },
        };
        return result;
    }
};

const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const typecheck = @import("typecheck.zig");

fn testUnit(allocator: std.mem.Allocator, name: []const u8, source: []const u8, is_entry: bool, imports: []load.Import) !load.Unit {
    var lex = lexer.Lexer.init(source, name);
    const tokens = try lex.tokenizeAll(allocator);
    var p = parser.Parser.init(allocator, tokens.items, name);
    return .{ .name = name, .path = name, .identity = name, .source = source, .module = try p.parseModule(), .is_entry = is_entry, .imports = imports };
}

fn testCheck(allocator: std.mem.Allocator, graph: *load.Graph) !void {
    const contexts = try allocator.alloc(typecheck.Checker, graph.units.len);
    defer for (contexts) |*context| context.deinit();
    for (contexts) |*context| context.* = typecheck.Checker.init(allocator);
    for (graph.units, 0..) |*unit, i| {
        const imports = try allocator.alloc(typecheck.ModuleImport, unit.imports.len);
        for (unit.imports, imports) |import, *out| out.* = .{ .name = import.name, .module = &graph.units[import.unit].module, .context = &contexts[import.unit] };
        try contexts[i].checkModuleWithImports(&unit.module, if (unit.is_entry) null else unit.name, imports);
        if (contexts[i].diagnostics.hasErrors()) {
            for (contexts[i].diagnostics.list.items) |d| std.debug.print("{s}\n", .{d.message});
            return error.TestUnexpectedDiagnostic;
        }
    }
}

fn named(module: *const ast.Module, name: []const u8) ast.FnDef {
    for (module.items) |item| if (item.kind == .fn_def and std.mem.eql(u8, item.kind.fn_def.name, name)) return item.kind.fn_def;
    unreachable;
}

test "program composition qualifies nominal types and calls without mutating graph" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var imports = [_]load.Import{.{ .name = "geo", .unit = 0, .span = .none }};
    var units = [_]load.Unit{
        try testUnit(a, "geo", "pub struct Point { copy x: Int } pub fn get(copy p: Point) -> Int { return p.x; } pub fn main() -> Int { return 5; }", false, &.{}),
        try testUnit(a, "entry", "pub struct Point { copy y: Int } pub fn main() -> Int { let copy p: geo.Point = geo.Point { x: 7 }; return geo.get(copy p) + geo.main(); }", true, &imports),
    };
    var graph = load.Graph{ .units = &units };
    try testCheck(a, &graph);
    var output = Io.Writer.Allocating.init(a);
    const table = try symbols.decideSymbols(a, &graph, &output.writer);
    const module = try compose(a, &graph, &table, &output.writer);
    const get = named(&module, "geo_get");
    try std.testing.expectEqualStrings("geo_Point", get.params[0].ty.name);
    try std.testing.expectEqualStrings("Point", units[0].module.items[1].kind.fn_def.params[0].ty.name);
    const main = named(&module, "main");
    try std.testing.expectEqualStrings("geo_Point", main.body.?[0].kind.let.ty.?.name);
    const sum = main.body.?[1].kind.return_stmt.?.kind.binary;
    try std.testing.expectEqualStrings("geo_get", sum.left.kind.call.callee.kind.ident);
    try std.testing.expectEqualStrings("geo_main", sum.right.kind.call.callee.kind.ident);
    try std.testing.expectEqualStrings("entry", sum.left.span.path.?);
    try std.testing.expectEqualStrings(units[1].source, sum.left.span.source.?);
    try std.testing.expect(units[1].module.items[1].kind.fn_def.body.?[1].kind.return_stmt.?.kind.binary.left.kind.call.callee.kind == .field);
}

test "program composition lexical shadows nested guards enums and repeated externs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var imports = [_]load.Import{.{ .name = "geo", .unit = 0, .span = .none }};
    var units = [_]load.Unit{
        try testUnit(a, "geo", "pub enum Color { Red } pub fn get() -> Int { return 7; } pub fn external(copy n: Int) -> Int;", false, &.{}),
        try testUnit(a, "entry", "pub fn external(copy n: Int) -> Int; pub struct Local { copy get: Int } pub fn main() -> Int { let copy values = [geo.get(), external(copy geo.get())]; let copy c = geo.Color.Red; let copy answer = match c { geo.Color.Red if geo.get() == 7 => geo.get(), _ => 0 }; let copy geo = Local { get: 4 }; return geo.get + answer; }", true, &imports),
    };
    var graph = load.Graph{ .units = &units };
    try testCheck(a, &graph);
    var output = Io.Writer.Allocating.init(a);
    const table = try symbols.decideSymbols(a, &graph, &output.writer);
    const module = try compose(a, &graph, &table, &output.writer);
    var external_count: usize = 0;
    for (module.items) |item| if (item.kind == .fn_def and std.mem.eql(u8, item.kind.fn_def.name, "external")) {
        external_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), external_count);
    const main = named(&module, "main");
    const arms = main.body.?[2].kind.let.value.?.kind.match_expr.arms;
    try std.testing.expectEqualStrings("geo_Color", arms[0].pattern.kind.enum_variant.enum_name.?);
    try std.testing.expectEqualStrings("geo_get", arms[0].guard.?.kind.binary.left.kind.call.callee.kind.ident);
    const returned = main.body.?[4].kind.return_stmt.?.kind.binary.left;
    try std.testing.expectEqualStrings(main.body.?[3].kind.let.name, returned.kind.field.base.kind.ident);
    try std.testing.expectEqualStrings("get", returned.kind.field.name);
}

test "program composition refuses unresolved identifiers instead of forwarding them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var units = [_]load.Unit{try testUnit(a, "entry", "pub fn main() -> Int { return missing(); }", true, &.{})};
    const graph = load.Graph{ .units = &units };
    var output = Io.Writer.Allocating.init(a);
    const table = try symbols.decideSymbols(a, &graph, &output.writer);
    try std.testing.expectError(error.InvalidProgram, compose(a, &graph, &table, &output.writer));
}

test "program composition aliases remain hygienic against source locals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var imports = [_]load.Import{.{ .name = "geo", .unit = 0, .span = .none }};
    var units = [_]load.Unit{
        try testUnit(a, "geo", "pub fn get() -> Int { return 7; }", false, &.{}),
        try testUnit(a, "entry", "pub fn _cell_local_1_0() -> Int { return 2; } pub fn main() -> Int { let copy geo_get = 3; return geo.get() + geo_get; }", true, &imports),
    };
    var graph = load.Graph{ .units = &units };
    try testCheck(a, &graph);
    var output = Io.Writer.Allocating.init(a);
    const table = try symbols.decideSymbols(a, &graph, &output.writer);
    var module = try compose(a, &graph, &table, &output.writer);
    const main = named(&module, "main");
    const local_alias = main.body.?[0].kind.let.name;
    try std.testing.expect(!std.mem.eql(u8, local_alias, "geo_get"));
    try std.testing.expect(!std.mem.eql(u8, local_alias, "_cell_local_1_0"));
    const sum = main.body.?[1].kind.return_stmt.?.kind.binary;
    try std.testing.expectEqualStrings("geo_get", sum.left.kind.call.callee.kind.ident);
    try std.testing.expectEqualStrings(local_alias, sum.right.kind.ident);
    var checker = typecheck.Checker.init(a);
    defer checker.deinit();
    try checker.checkModule(&module);
    try std.testing.expect(!checker.diagnostics.hasErrors());
}

test "program composition clones while assignment wrappers indexes and lexical block scopes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var imports = [_]load.Import{.{ .name = "geo", .unit = 0, .span = .none }};
    var units = [_]load.Unit{
        try testUnit(a, "geo", "pub fn get() -> Int { return 7; }", false, &.{}),
        try testUnit(a, "entry", "pub fn main() -> Int { var copy n = 0; outer: while n < geo.get() { n = n + geo.get(); if n > 5 { break :outer; } else { continue :outer; }; } let owned xs = [geo.get()]; let copy v: Int? = xs[0]; let copy w: Int? = Some(geo.get()); let copy answer = match w { Some(x) => x, None => 0 }; return if n > 0 { geo.get() + answer } else { 0 }; }", true, &imports),
    };
    var graph = load.Graph{ .units = &units };
    try testCheck(a, &graph);
    var output = Io.Writer.Allocating.init(a);
    const table = try symbols.decideSymbols(a, &graph, &output.writer);
    var module = try compose(a, &graph, &table, &output.writer);
    const main = named(&module, "main");
    const loop = main.body.?[1].kind.while_stmt;
    try std.testing.expectEqualStrings("geo_get", loop.cond.kind.binary.right.kind.call.callee.kind.ident);
    try std.testing.expectEqualStrings(main.body.?[0].kind.let.name, loop.body[0].kind.assign.target.kind.ident);
    try std.testing.expect(loop.body.ptr != units[1].module.items[0].kind.fn_def.body.?[1].kind.while_stmt.body.ptr);
    const pattern = main.body.?[5].kind.let.value.?.kind.match_expr.arms[0].pattern.kind.wrap_pattern;
    try std.testing.expectEqualStrings(pattern.binding.?, main.body.?[5].kind.let.value.?.kind.match_expr.arms[0].body.kind.ident);
    var checker = typecheck.Checker.init(a);
    defer checker.deinit();
    try checker.checkModule(&module);
    try std.testing.expect(!checker.diagnostics.hasErrors());
}

test "program composition omits unused imported externs while retaining entry declarations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var imports = [_]load.Import{.{ .name = "prelude", .unit = 0, .span = .none }};
    var units = [_]load.Unit{
        try testUnit(a, "prelude", "pub fn print_int(copy n: Int); pub fn arc_retain_string(arc s: String) -> arc String; pub fn unused(copy n: Int);", false, &.{}),
        try testUnit(a, "entry", "pub fn unused(copy n: Int); pub fn entry_only(arc s: String) -> arc String; pub fn main() { prelude.print_int(copy 42); }", true, &imports),
    };
    var graph = load.Graph{ .units = &units };
    try testCheck(a, &graph);
    var output = Io.Writer.Allocating.init(a);
    const table = try symbols.decideSymbols(a, &graph, &output.writer);
    const module = try compose(a, &graph, &table, &output.writer);
    var found_print = false;
    var found_unused = false;
    var found_entry_only = false;
    for (module.items) |item| {
        if (item.kind != .fn_def) continue;
        const name = item.kind.fn_def.name;
        try std.testing.expect(!std.mem.eql(u8, name, "arc_retain_string"));
        if (std.mem.eql(u8, name, "print_int")) found_print = true;
        if (std.mem.eql(u8, name, "unused")) found_unused = true;
        if (std.mem.eql(u8, name, "entry_only")) found_entry_only = true;
    }
    try std.testing.expect(found_print and found_unused and found_entry_only);
}

test "program composition whole installed prelude emits only referenced imported declarations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = try Io.Dir.cwd().readFileAlloc(std.testing.io, "stdlib/prelude.cell", a, .limited(1024 * 1024));
    var imports = [_]load.Import{.{ .name = "prelude", .unit = 0, .span = .none }};
    var units = [_]load.Unit{
        try testUnit(a, "prelude", source, false, &.{}),
        try testUnit(a, "entry", "pub fn unused(copy n: Int); pub fn main() { prelude.print_int(copy 42); }", true, &imports),
    };
    var graph = load.Graph{ .units = &units };
    try testCheck(a, &graph);
    var output = Io.Writer.Allocating.init(a);
    const table = try symbols.decideSymbols(a, &graph, &output.writer);
    const module = try compose(a, &graph, &table, &output.writer);
    try std.testing.expectEqual(@as(usize, 3), module.items.len);
    try std.testing.expectEqualStrings("print_int", module.items[0].kind.fn_def.name);
    try std.testing.expectEqualStrings("unused", module.items[1].kind.fn_def.name);
    try std.testing.expectEqualStrings("main", module.items[2].kind.fn_def.name);
}

test "program composition preserves external parameter spellings and definition hygiene" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var units = [_]load.Unit{try testUnit(a, "entry", "pub fn external(shared value: String, copy count: Int); pub fn body(copy count: Int) -> Int { return count; }", true, &.{})};
    var graph = load.Graph{ .units = &units };
    try testCheck(a, &graph);
    var output = Io.Writer.Allocating.init(a);
    const table = try symbols.decideSymbols(a, &graph, &output.writer);
    const module = try compose(a, &graph, &table, &output.writer);
    const external = named(&module, "external");
    try std.testing.expectEqualStrings("value", external.params[0].name);
    try std.testing.expectEqualStrings("count", external.params[1].name);
    const body = named(&module, "body");
    try std.testing.expect(!std.mem.eql(u8, body.params[0].name, "count"));
    try std.testing.expectEqualStrings(body.params[0].name, body.body.?[0].kind.return_stmt.?.kind.ident);
}
