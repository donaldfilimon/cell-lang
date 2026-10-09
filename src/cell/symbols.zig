//! Whole-program C ABI names, decided before backend lowering. No AST mutation.
const std = @import("std");
const ast = @import("ast.zig");
const load = @import("load.zig");
const types = @import("types.zig");
const Io = std.Io;

pub const Kind = enum { function, structure, enumeration };
pub const Entry = struct {
    unit: usize,
    item: usize,
    name: []const u8,
    kind: Kind,
    canonical_name: []const u8,
    symbol: []const u8,
    linkage: ast.Linkage,
};
pub const Table = struct {
    entries: []Entry,

    pub fn get(self: *const Table, unit: usize, name: []const u8) ?*const Entry {
        for (self.entries) |*entry| {
            if (entry.unit == unit and eql(entry.name, name)) return entry;
        }
        return null;
    }
};

const Claim = struct { entry: usize, signature: ?[]const u8 = null };

pub fn decideSymbols(allocator: std.mem.Allocator, graph: *const load.Graph, writer: *Io.Writer) !Table {
    var entries: std.ArrayList(Entry) = .empty;
    var claims: std.StringHashMapUnmanaged(Claim) = .empty;
    defer claims.deinit(allocator);
    // The caller's arena owns result entries, spellings and ABI descriptions.
    for (graph.units, 0..) |unit, unit_index| {
        for (unit.module.items, 0..) |item, item_index| {
            const name, const kind: Kind, const bodyless, const public = switch (item.kind) {
                .fn_def => |f| .{ f.name, .function, f.body == null, f.is_public },
                .struct_def => |s| .{ s.name, .structure, false, s.is_public },
                .enum_def => |e| .{ e.name, .enumeration, false, e.is_public },
                .use_decl => continue,
            };
            const symbol = if (bodyless and eql(name, "assert") and item.kind.fn_def.params.len == 2)
                "cell_assert_msg"
            else if (bodyless or unit.is_entry)
                try std.fmt.allocPrint(allocator, "cell_{s}", .{name})
            else
                try std.fmt.allocPrint(allocator, "cell_{s}_{s}", .{ unit.name, name });
            const entry: Entry = .{
                .unit = unit_index,
                .item = item_index,
                .name = name,
                .kind = kind,
                .canonical_name = symbol[5..],
                .symbol = symbol,
                .linkage = if (bodyless or public or (unit.is_entry and eql(name, "main"))) .external else .internal,
            };
            const index = entries.items.len;
            try entries.append(allocator, entry);
            const signature = if (bodyless) try externalSignature(allocator, graph, unit_index, item.kind.fn_def) else null;
            try claimSymbol(allocator, graph, writer, &claims, entries.items, symbol, .{ .entry = index, .signature = signature });
            // Glue and enum constants occupy the same C identifier namespace
            // as typedefs/functions, so they participate in the same decisions.
            if (kind == .structure) {
                const drop = try std.fmt.allocPrint(allocator, "cell_drop_{s}", .{entry.canonical_name});
                try claimSymbol(allocator, graph, writer, &claims, entries.items, drop, .{ .entry = index });
            }
            if (kind == .enumeration) {
                for (item.kind.enum_def.variants) |variant| {
                    const constant = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ symbol, variant });
                    try claimSymbol(allocator, graph, writer, &claims, entries.items, constant, .{ .entry = index });
                }
            }
        }
    }
    return .{ .entries = try entries.toOwnedSlice(allocator) };
}

fn claimSymbol(allocator: std.mem.Allocator, graph: *const load.Graph, writer: *Io.Writer, claims: *std.StringHashMapUnmanaged(Claim), entries: []const Entry, symbol: []const u8, claim: Claim) !void {
    if (claims.get(symbol)) |previous| {
        if (previous.signature != null and claim.signature != null and eql(previous.signature.?, claim.signature.?)) return;
        const current = entries[claim.entry];
        const old = entries[previous.entry];
        const unit = graph.units[current.unit];
        const span = unit.module.items[current.item].span;
        try writer.print("{s}:{d}:{d}: error: emitted symbol '{s}' collides with {s}.{s}\n", .{ span.path orelse unit.path, span.line, span.column, symbol, graph.units[old.unit].name, old.name });
        return error.SymbolCollision;
    }
    try claims.put(allocator, symbol, claim);
}

fn externalSignature(allocator: std.mem.Allocator, graph: *const load.Graph, unit: usize, f: ast.FnDef) ![]const u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    if (f.return_type) |*ret| try writeType(graph, unit, ret, .owned, &out.writer) else try out.writer.writeAll("unit");
    for (f.params) |p| {
        try out.writer.writeByte('|');
        try writeType(graph, unit, &p.ty, p.ownership, &out.writer);
    }
    return try out.toOwnedSlice();
}

fn writeType(graph: *const load.Graph, unit: usize, ty: *const ast.TypeExpr, ownership: ast.Ownership, out: *Io.Writer) !void {
    if (ty.* == .ref) return writeType(graph, unit, ty.ref.inner, ty.ref.ownership, out);
    switch (ty.*) {
        .unit => try out.writeAll("unit"),
        .name => |name| {
            if (eql(name, "Unit")) return out.writeAll("unit");
            if (types.fromPrimitiveName(name)) |primitive| {
                if (primitive != .string) return out.writeAll(@tagName(primitive));
                try out.print("{s}:string", .{@tagName(ownership)});
                return;
            }
            var owner = unit;
            var leaf = name;
            if (std.mem.indexOfScalar(u8, name, '.')) |dot| {
                for (graph.units[unit].imports) |import| {
                    if (eql(import.name, name[0..dot])) {
                        owner = import.unit;
                        break;
                    }
                }
                leaf = name[dot + 1 ..];
            }
            // File identity, rather than leaf module spelling, is the nominal
            // identity used when comparing repeated foreign declarations.
            try out.print("{s}:{s}.{s}", .{ @tagName(ownership), graph.units[owner].identity, leaf });
        },
        .list => |inner| {
            try out.print("{s}:[", .{@tagName(ownership)});
            try writeType(graph, unit, inner, .owned, out);
            try out.writeByte(']');
        },
        .optional => |inner| {
            try out.print("{s}:?", .{@tagName(ownership)});
            try writeType(graph, unit, inner, .owned, out);
        },
        .result => |r| {
            try out.print("{s}:Result<", .{@tagName(ownership)});
            try writeType(graph, unit, r.ok, .owned, out);
            try out.writeByte(',');
            try writeType(graph, unit, r.err, .owned, out);
            try out.writeByte('>');
        },
        .ref => unreachable,
    }
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

const lexer = @import("lexer.zig");
const parser = @import("parser.zig");

fn testUnit(allocator: std.mem.Allocator, name: []const u8, source: []const u8, entry: bool) !load.Unit {
    var lex = lexer.Lexer.init(source, name);
    const tokens = try lex.tokenizeAll(allocator);
    var p = parser.Parser.init(allocator, tokens.items, name);
    return .{ .name = name, .path = name, .identity = name, .module = try p.parseModule(), .source = source, .imports = &.{}, .is_entry = entry };
}

test "whole graph symbols preserve entry ABI and qualify private definitions independently of lowering" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var units = [_]load.Unit{
        try testUnit(a, "geo", "fn hidden() {} pub fn open() {} pub struct Point { copy x: Int } pub enum Color { Red } pub fn host(copy x: Int);", false),
        try testUnit(a, "main", "fn main() {} fn private() {} pub fn host(shared n: Int64); pub fn assert(copy ok: Bool, shared message: String);", true),
    };
    const graph: load.Graph = .{ .units = &units };
    var diagnostics: Io.Writer.Allocating = .init(a);
    const table = try decideSymbols(a, &graph, &diagnostics.writer);
    try std.testing.expectEqualStrings("cell_geo_hidden", table.get(0, "hidden").?.symbol);
    try std.testing.expectEqual(ast.Linkage.internal, table.get(0, "hidden").?.linkage);
    try std.testing.expectEqualStrings("geo_Point", table.get(0, "Point").?.canonical_name);
    try std.testing.expectEqualStrings("cell_geo_Color", table.get(0, "Color").?.symbol);
    try std.testing.expectEqual(ast.Linkage.external, table.get(0, "open").?.linkage);
    try std.testing.expectEqualStrings("cell_main", table.get(1, "main").?.symbol);
    try std.testing.expectEqual(ast.Linkage.external, table.get(1, "main").?.linkage);
    try std.testing.expectEqual(ast.Linkage.internal, table.get(1, "private").?.linkage);
    try std.testing.expectEqualStrings("cell_host", table.get(0, "host").?.symbol);
    try std.testing.expectEqualStrings("cell_host", table.get(1, "host").?.symbol);
    try std.testing.expectEqualStrings("cell_assert_msg", table.get(1, "assert").?.symbol);
    try std.testing.expect(units[0].module.items[0].kind.fn_def.symbol == null);
    try std.testing.expectEqualStrings("hidden", units[0].module.items[0].kind.fn_def.name);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.written().len);
}

test "whole graph symbols reject function type drop enum and underscore collisions" {
    const cases = .{
        .{ "a", "pub fn b_c() {}", "a_b", "pub fn c() {}", "cell_a_b_c" },
        .{ "geo", "pub struct Point {}", "main", "pub fn geo_Point() {}", "cell_geo_Point" },
        .{ "geo", "pub struct Point {}", "main", "pub fn drop_geo_Point() {}", "cell_drop_geo_Point" },
        .{ "geo", "pub enum Color { Red }", "main", "pub fn geo_Color_Red() {}", "cell_geo_Color_Red" },
        .{ "geo", "pub fn host(copy x: Int);", "main", "pub fn host(copy x: Float);", "cell_host" },
        .{ "geo", "pub fn host(copy x: Int);", "main", "pub fn host(copy x: Int) {}", "cell_host" },
    };
    inline for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var units = [_]load.Unit{
            try testUnit(a, case[0], case[1], false),
            try testUnit(a, case[2], case[3], eql(case[2], "main")),
        };
        const graph: load.Graph = .{ .units = &units };
        var diagnostics: Io.Writer.Allocating = .init(a);
        try std.testing.expectError(error.SymbolCollision, decideSymbols(a, &graph, &diagnostics.writer));
        try std.testing.expect(std.mem.indexOf(u8, diagnostics.written(), case[4]) != null);
    }
}

test "repeated external signatures preserve nominal module identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var units = [_]load.Unit{
        try testUnit(a, "geo", "pub struct Point {} pub fn host(shared p: Point);", false),
        try testUnit(a, "main", "use geo; pub fn host(shared p: geo.Point);", true),
    };
    var imports = [_]load.Import{.{ .name = "geo", .unit = 0, .span = .none }};
    units[1].imports = &imports;
    const graph: load.Graph = .{ .units = &units };
    var diagnostics: Io.Writer.Allocating = .init(a);
    _ = try decideSymbols(a, &graph, &diagnostics.writer);
    units[1] = try testUnit(a, "main", "pub struct Point {} pub fn host(shared p: Point);", true);
    try std.testing.expectError(error.SymbolCollision, decideSymbols(a, &graph, &diagnostics.writer));
}

test "C backend obeys explicit graph symbols and linkage while preserving standalone defaults" {
    const codegen = @import("codegen.zig");
    const support = @import("codegen/tests_support.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var unit = try testUnit(a, "geo", "struct Point { copy x: Int } enum Color { Red } fn hidden() -> Int { return 7 } pub fn external();", false);
    unit.module.items[0].kind.struct_def.symbol = "cell_geo_Point";
    unit.module.items[1].kind.enum_def.symbol = "cell_geo_Color";
    unit.module.items[2].kind.fn_def.symbol = "cell_geo_hidden";
    unit.module.items[2].kind.fn_def.linkage = .internal;
    unit.module.items[3].kind.fn_def.symbol = "cell_host_external";
    unit.module.items[3].kind.fn_def.linkage = .internal; // Bodyless is always external.
    var out: Io.Writer.Allocating = .init(a);
    var gen = codegen.Generator.init(a, &out.writer);
    try gen.emitModule(&unit.module);
    try support.expectContains(out.written(), "typedef struct cell_geo_Point");
    try support.expectContains(out.written(), "typedef int32_t cell_geo_Color;");
    try support.expectContains(out.written(), "cell_geo_Color_Red = 0");
    try support.expectContains(out.written(), "static __attribute__((unused)) int64_t cell_geo_hidden(void)");
    try support.expectContains(out.written(), "void cell_host_external(void);");
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "static __attribute__((unused)) void cell_host_external") == null);
    try support.expectCompiles(out.written());
}

/// Reserve declarations from build-preprocessed authoritative C inputs. The
/// header includes inline helpers; the implementation contributes only global
/// functions (its static helpers live in a different translation unit).
/// Preprocess with cc -E -P -x c; unsupported macro input fails closed.
pub fn reserveRuntimeSymbols(allocator: std.mem.Allocator, graph: *const load.Graph, table: *const Table, header: []const u8, source: []const u8, writer: *Io.Writer) !void {
    var reserved: std.StringHashMapUnmanaged(RuntimeClaim) = .empty;
    defer reserved.deinit(allocator);
    collectRuntimeDeclarations(allocator, header, false, &reserved) catch |err| {
        if (err == error.UnsupportedRuntimeInterface) try writer.writeAll("runtime/cell_rt.h:1:1: error: unsupported preprocessed runtime interface; refusing symbol decisions\n");
        return err;
    };
    collectRuntimeDeclarations(allocator, source, true, &reserved) catch |err| {
        if (err == error.UnsupportedRuntimeInterface) try writer.writeAll("runtime/cell_rt.c:1:1: error: unsupported preprocessed runtime interface; refusing symbol decisions\n");
        return err;
    };
    for (table.entries) |entry| {
        const unit = graph.units[entry.unit];
        const item = unit.module.items[entry.item];
        var conflicting: ?[]const u8 = if (reserved.contains(entry.symbol)) entry.symbol else null;
        if (entry.kind == .structure) {
            const drop = try std.fmt.allocPrint(allocator, "cell_drop_{s}", .{entry.canonical_name});
            if (reserved.contains(drop)) conflicting = drop;
        }
        if (entry.kind == .enumeration) {
            for (item.kind.enum_def.variants) |variant| {
                const constant = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ entry.symbol, variant });
                if (reserved.contains(constant)) conflicting = constant;
            }
        }
        const symbol = conflicting orelse continue;
        const runtime = reserved.get(symbol).?;
        if (entry.kind == .function and item.kind.fn_def.body == null and eql(symbol, entry.symbol) and runtime.function) {
            const actual = try runtimeCellSignature(allocator, &unit.module, item.kind.fn_def);
            if (runtime.signature != null and actual != null and eql(runtime.signature.?, actual.?)) continue;
            try writer.print("{s}:{d}:{d}: error: declaration of runtime symbol '{s}' has an incompatible or unsupported C ABI signature\n", .{ item.span.path orelse unit.path, item.span.line, item.span.column, symbol });
            return error.RuntimeSignatureConflict;
        }
        try writer.print("{s}:{d}:{d}: error: emitted symbol '{s}' collides with the runtime interface\n", .{ item.span.path orelse unit.path, item.span.line, item.span.column, symbol });
        return error.RuntimeSymbolCollision;
    }
}

const RuntimeClaim = struct { function: bool, signature: ?[]const u8 = null };
const CToken = struct { text: []const u8, identifier: bool };

fn cTokens(allocator: std.mem.Allocator, input: []const u8) ![]CToken {
    var tokens: std.ArrayList(CToken) = .empty;
    var i: usize = 0;
    while (i < input.len) {
        const c = input[i];
        if (std.ascii.isWhitespace(c)) {
            i += 1;
            continue;
        }
        if (c == '/' and i + 1 < input.len and input[i + 1] == '/') {
            while (i < input.len and input[i] != '\n') : (i += 1) {}
            continue;
        }
        if (c == '/' and i + 1 < input.len and input[i + 1] == '*') {
            i += 2;
            while (i + 1 < input.len and !(input[i] == '*' and input[i + 1] == '/')) : (i += 1) {}
            if (i + 1 >= input.len) return error.UnsupportedRuntimeInterface;
            i += 2;
            continue;
        }
        if (c == '"' or c == '\'') {
            const quote = c;
            i += 1;
            while (i < input.len and input[i] != quote) : (i += 1) {
                if (input[i] == '\\') i += 1;
            }
            if (i >= input.len) return error.UnsupportedRuntimeInterface;
            i += 1;
            // Keep an inert token so strings cannot join two identifiers.
            try tokens.append(allocator, .{ .text = "<literal>", .identifier = false });
            continue;
        }
        if (c == '#') {
            // Native headers may retain pragmas even under -E -P. They do
            // not introduce identifiers; macro definitions remain refused.
            i += 1;
            while (i < input.len and (input[i] == ' ' or input[i] == '\t')) : (i += 1) {}
            if (!std.mem.startsWith(u8, input[i..], "pragma") or (i + 6 < input.len and !std.ascii.isWhitespace(input[i + 6]))) return error.UnsupportedRuntimeInterface;
            while (i < input.len and input[i] != '\n') : (i += 1) {}
            continue;
        }
        const start = i;
        const identifier = std.ascii.isAlphabetic(c) or c == '_';
        i += 1;
        if (identifier) while (i < input.len and (std.ascii.isAlphanumeric(input[i]) or input[i] == '_')) : (i += 1) {};
        try tokens.append(allocator, .{ .text = input[start..i], .identifier = identifier });
    }
    return try tokens.toOwnedSlice(allocator);
}

fn balancedEnd(tokens: []const CToken, start: usize, open: []const u8, close: []const u8) !usize {
    var depth: usize = 0;
    for (tokens[start..], start..) |token, i| {
        if (eql(token.text, open)) depth += 1;
        if (eql(token.text, close)) {
            if (depth == 0) return error.UnsupportedRuntimeInterface;
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return error.UnsupportedRuntimeInterface;
}

fn collectRuntimeDeclarations(allocator: std.mem.Allocator, input: []const u8, source: bool, reserved: *std.StringHashMapUnmanaged(RuntimeClaim)) !void {
    const tokens = try cTokens(allocator, input);
    var start: usize = 0;
    var i: usize = 0;
    while (i < tokens.len) : (i += 1) {
        const text = tokens[i].text;
        if (tokens[i].identifier and std.mem.startsWith(u8, text, "CELL_") and i + 1 < tokens.len and eql(tokens[i + 1].text, "(")) return error.UnsupportedRuntimeInterface;
        if (eql(text, "(")) {
            const end = try balancedEnd(tokens, i, "(", ")");
            i = end;
            continue;
        }
        if (eql(text, "{")) {
            const end = try balancedEnd(tokens, i, "{", "}");
            const prefix = tokens[start..i];
            if (findFunction(prefix)) |fn_index| {
                const is_static = tokenContains(prefix, "static");
                if (!source or !is_static) try reserveCFunction(allocator, prefix, fn_index, reserved);
                i = end;
                start = end + 1;
                continue;
            }
            // Aggregate declarations continue after the body to their typedef
            // alias/semicolon. Enum members are ordinary namespace constants.
            if (!source and tokenContains(prefix, "enum")) try reserveEnumMembers(allocator, tokens[i + 1 .. end], reserved);
            i = end;
            continue;
        }
        if (eql(text, ";")) {
            const declaration = tokens[start..i];
            if (!source and declaration.len > 1 and eql(declaration[0].text, "typedef")) {
                var alias: ?[]const u8 = null;
                const last = declaration[declaration.len - 1];
                if (last.identifier) alias = last.text;
                // A function-pointer typedef's alias is inside its declarator,
                // not the parameter type/name at the end of the statement.
                for (declaration, 0..) |token, index| {
                    if (index > 0 and index + 1 < declaration.len and token.identifier and eql(declaration[index - 1].text, "*") and eql(declaration[index + 1].text, ")")) alias = token.text;
                }
                if (alias) |name| {
                    if (std.mem.startsWith(u8, name, "cell_")) try reserved.put(allocator, name, .{ .function = false });
                } else {
                    for (declaration) |token| {
                        if (token.identifier and std.mem.startsWith(u8, token.text, "cell_")) return error.UnsupportedRuntimeInterface;
                    }
                }
            } else if (findFunction(declaration)) |fn_index| {
                if (!source or !tokenContains(declaration, "static")) try reserveCFunction(allocator, declaration, fn_index, reserved);
            } else if (!source or !tokenContains(declaration, "static")) {
                var declarator_end = declaration.len;
                for (declaration, 0..) |token, index| {
                    if (eql(token.text, "=")) {
                        declarator_end = index;
                        break;
                    }
                }
                if (declarator_end > 1) {
                    const name = declaration[declarator_end - 1];
                    if (name.identifier and std.mem.startsWith(u8, name.text, "cell_")) try reserved.put(allocator, name.text, .{ .function = false });
                }
            }
            start = i + 1;
        }
    }
    if (start != tokens.len) return error.UnsupportedRuntimeInterface;
}

fn findFunction(tokens: []const CToken) ?usize {
    var depth: usize = 0;
    for (tokens, 0..) |token, i| {
        if (depth == 0 and eql(token.text, "=")) return null;
        if (eql(token.text, "(")) {
            if (depth == 0 and i > 0 and tokens[i - 1].identifier and std.mem.startsWith(u8, tokens[i - 1].text, "cell_")) return i - 1;
            depth += 1;
        } else if (eql(token.text, ")") and depth > 0) depth -= 1;
    }
    return null;
}

fn tokenContains(tokens: []const CToken, needle: []const u8) bool {
    for (tokens) |token| if (eql(token.text, needle)) return true;
    return false;
}

fn reserveEnumMembers(allocator: std.mem.Allocator, tokens: []const CToken, reserved: *std.StringHashMapUnmanaged(RuntimeClaim)) !void {
    var expect_name = true;
    var i: usize = 0;
    while (i < tokens.len) : (i += 1) {
        if (expect_name and tokens[i].identifier) {
            if (std.mem.startsWith(u8, tokens[i].text, "cell_")) try reserved.put(allocator, tokens[i].text, .{ .function = false });
            expect_name = false;
        }
        if (eql(tokens[i].text, "(") or eql(tokens[i].text, "{")) {
            i = try balancedEnd(tokens, i, tokens[i].text, if (eql(tokens[i].text, "(")) ")" else "}");
        } else if (eql(tokens[i].text, ",")) expect_name = true;
    }
}

fn reserveCFunction(allocator: std.mem.Allocator, declaration: []const CToken, index: usize, reserved: *std.StringHashMapUnmanaged(RuntimeClaim)) !void {
    const name = declaration[index].text;
    const end = try balancedEnd(declaration, index + 1, "(", ")");
    var out: Io.Writer.Allocating = .init(allocator);
    const valid = try writeCType(declaration[0..index], false, &out.writer);
    var signature: ?[]const u8 = null;
    if (valid) {
        var start = index + 2;
        var i = start;
        var supported = true;
        while (i <= end) : (i += 1) {
            if (i == end or eql(declaration[i].text, ",")) {
                const param = declaration[start..i];
                if (!(param.len == 1 and eql(param[0].text, "void")) and param.len != 0) {
                    try out.writer.writeByte('|');
                    if (!try writeCType(param, true, &out.writer)) supported = false;
                }
                start = i + 1;
            }
        }
        if (supported) signature = try out.toOwnedSlice();
    }
    if (reserved.get(name)) |old| {
        if (!old.function) return error.UnsupportedRuntimeInterface;
        if (old.signature != null and signature != null and !eql(old.signature.?, signature.?)) return error.UnsupportedRuntimeInterface;
        if (old.signature != null) return;
    }
    try reserved.put(allocator, name, .{ .function = true, .signature = signature });
}

fn writeCType(tokens: []const CToken, parameter: bool, out: *Io.Writer) !bool {
    var end = tokens.len;
    if (parameter and end > 1 and tokens[end - 1].identifier) end -= 1;
    var i: usize = 0;
    var wrote = false;
    while (i < end) : (i += 1) {
        const token = tokens[i];
        if (eql(token.text, "__attribute__")) {
            if (i + 1 >= end or !eql(tokens[i + 1].text, "(")) return false;
            i = try balancedEnd(tokens[0..end], i + 1, "(", ")");
            continue;
        }
        if (eql(token.text, "static") or eql(token.text, "inline") or eql(token.text, "extern") or eql(token.text, "const") or eql(token.text, "volatile") or eql(token.text, "restrict") or eql(token.text, "_Noreturn")) continue;
        if (token.identifier) {
            if (wrote) return false; // Unsupported multiword/function-pointer type.
            try out.writeAll(if (eql(token.text, "bool")) "_Bool" else token.text);
            wrote = true;
        } else if (eql(token.text, "*")) {
            try out.writeByte('*');
        } else return false;
    }
    return wrote;
}

fn runtimeCellSignature(allocator: std.mem.Allocator, module: *const ast.Module, f: ast.FnDef) !?[]const u8 {
    // Reuse the C ABI type classifier rather than invent a second ownership
    // mapping. This does not emit or mutate the AST and needs no HIR lowering.
    const codegen = @import("codegen.zig");
    var out: Io.Writer.Allocating = .init(allocator);
    var gen = codegen.Generator.init(allocator, &out.writer);
    gen.arena = allocator;
    gen.module = module;
    if (f.return_type) |ret| {
        const ty = try gen.lowerType(&ret, .owned);
        if (ty.shape == .unknown) return null;
        const tokens = try cTokens(allocator, ty.text);
        if (!try writeCType(tokens, false, &out.writer)) return null;
    } else try out.writer.writeAll("void");
    for (f.params) |p| {
        const ty = try gen.lowerType(&p.ty, p.ownership);
        if (ty.shape == .unknown) return null;
        try out.writer.writeByte('|');
        const tokens = try cTokens(allocator, ty.text);
        if (!try writeCType(tokens, false, &out.writer)) return null;
    }
    return try out.toOwnedSlice();
}

test "runtime interface refuses definitions types glue constants and incompatible foreign declarations" {
    const cases = .{
        .{ "pub fn print_int(copy n: Int) {}", "void cell_print_int(int64_t value);", error.RuntimeSymbolCollision },
        .{ "pub struct string_t {}", "typedef struct { int x; } cell_string_t;", error.RuntimeSymbolCollision },
        .{ "pub enum string_t { A }", "typedef struct { int x; } cell_string_t;", error.RuntimeSymbolCollision },
        .{ "pub struct callback_t {}", "typedef void (*cell_callback_t)(int64_t value);", error.RuntimeSymbolCollision },
        .{ "pub fn global() {}", "extern const int64_t cell_global;", error.RuntimeSymbolCollision },
        .{ "pub struct Point {}", "void cell_drop_Point(void *value);", error.RuntimeSymbolCollision },
        .{ "pub enum Color { Red }", "enum { cell_Color_Red = 1 };", error.RuntimeSymbolCollision },
        .{ "pub fn print_int(copy n: Float);", "void cell_print_int(int64_t value);", error.RuntimeSignatureConflict },
        .{ "pub fn print_int(copy n: Opaque);", "void cell_print_int(int64_t value);", error.RuntimeSignatureConflict },
        .{ "pub fn callbacks(copy n: Int);", "void cell_callbacks(void (*callback)(int64_t value));", error.RuntimeSignatureConflict },
    };
    inline for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var units = [_]load.Unit{try testUnit(a, "main", case[0], true)};
        const graph: load.Graph = .{ .units = &units };
        var diagnostics: Io.Writer.Allocating = .init(a);
        const table = try decideSymbols(a, &graph, &diagnostics.writer);
        try std.testing.expectError(case[2], reserveRuntimeSymbols(a, &graph, &table, case[1], "", &diagnostics.writer));
        try std.testing.expect(std.mem.indexOf(u8, diagnostics.written(), "error:") != null);
    }
}

test "runtime interface ignores comments strings references and implementation static helpers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var units = [_]load.Unit{try testUnit(a, "main", "pub fn print_int(copy n: Int); pub fn print(shared s: String); pub fn assert(copy ok: Bool, shared msg: String); pub fn spoof() {} pub fn called() {} pub fn secret() {}", true)};
    const graph: load.Graph = .{ .units = &units };
    var diagnostics: Io.Writer.Allocating = .init(a);
    const table = try decideSymbols(a, &graph, &diagnostics.writer);
    const header =
        \\/* void cell_spoof(void); */
        \\// void cell_spoof(void);
        \\void cell_print_int(int64_t value);
        \\void cell_print(cell_str_t value);
        \\void cell_assert_msg(_Bool ok, cell_str_t msg);
        \\static inline void cell_helper(void) { cell_called(); const char *s = "void cell_spoof(void);"; }
    ;
    const source = "void cell_print_int(int64_t value) {} static void cell_secret(void) {}";
    try reserveRuntimeSymbols(a, &graph, &table, header, source, &diagnostics.writer);
    // Header inline helpers belong to every consumer translation unit.
    units[0] = try testUnit(a, "main", "pub fn helper() {}", true);
    const helper_table = try decideSymbols(a, &graph, &diagnostics.writer);
    try std.testing.expectError(error.RuntimeSymbolCollision, reserveRuntimeSymbols(a, &graph, &helper_table, header, source, &diagnostics.writer));
    units[0] = try testUnit(a, "main", "pub fn global() {}", true);
    const global_table = try decideSymbols(a, &graph, &diagnostics.writer);
    try std.testing.expectError(error.RuntimeSymbolCollision, reserveRuntimeSymbols(a, &graph, &global_table, "", "void cell_global(void) {}", &diagnostics.writer));
    try std.testing.expectError(error.UnsupportedRuntimeInterface, reserveRuntimeSymbols(a, &graph, &global_table, "#define CELL_NEW(base) base##_t\n", "", &diagnostics.writer));
    try std.testing.expectError(error.UnsupportedRuntimeInterface, reserveRuntimeSymbols(a, &graph, &global_table, "CELL_NEW(cell_new)", "", &diagnostics.writer));
}

test "runtime interface is derived from the native preprocessed header and global implementation" {
    const gpa = std.testing.allocator;
    const header = try std.process.run(gpa, std.testing.io, .{ .argv = &.{ "cc", "-E", "-P", "-x", "c", "runtime/cell_rt.h" } });
    defer gpa.free(header.stdout);
    defer gpa.free(header.stderr);
    try std.testing.expect(header.term.success());
    const source = try std.process.run(gpa, std.testing.io, .{ .argv = &.{ "cc", "-E", "-P", "-x", "c", "-I", "runtime", "runtime/cell_rt.c" } });
    defer gpa.free(source.stdout);
    defer gpa.free(source.stderr);
    try std.testing.expect(source.term.success());
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var units = [_]load.Unit{try testUnit(a, "main", "pub fn print_int(copy n: Int); pub fn bytes_at(shared xs: [Byte], copy index: Int) -> Byte?; pub fn main() {}", true)};
    const graph: load.Graph = .{ .units = &units };
    var diagnostics: Io.Writer.Allocating = .init(a);
    const table = try decideSymbols(a, &graph, &diagnostics.writer);
    try reserveRuntimeSymbols(a, &graph, &table, header.stdout, source.stdout, &diagnostics.writer);
    // Macro-generated types must be reserved too; scanning raw macro source
    // would miss every one of these hundreds of declarations.
    inline for (.{ "pub struct opt_i64_t {}", "pub struct res_i64_string_t {}", "pub fn print_int(copy n: Int) {}" }) |code| {
        units[0] = try testUnit(a, "main", code, true);
        const conflict = try decideSymbols(a, &graph, &diagnostics.writer);
        try std.testing.expectError(error.RuntimeSymbolCollision, reserveRuntimeSymbols(a, &graph, &conflict, header.stdout, source.stdout, &diagnostics.writer));
    }
}

test "symbol diagnostics preserve paired body span provenance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var units = [_]load.Unit{try testUnit(a, "paired.cell", "pub fn print_int(copy n: Int) {}", true)};
    units[0].module.items[0].span.path = "paired.body";
    units[0].module.items[0].span.line = 3;
    const graph: load.Graph = .{ .units = &units };
    var diagnostics: Io.Writer.Allocating = .init(a);
    const table = try decideSymbols(a, &graph, &diagnostics.writer);
    try std.testing.expectError(error.RuntimeSymbolCollision, reserveRuntimeSymbols(a, &graph, &table, "void cell_print_int(int64_t n);", "", &diagnostics.writer));
    try std.testing.expect(std.mem.startsWith(u8, diagnostics.written(), "paired.body:3:1: error:"));

    // The graph-to-graph collision path must use the same provenance rule.
    var collision_units = [_]load.Unit{
        try testUnit(a, "geo", "pub fn twice() {}", false),
        try testUnit(a, "paired.cell", "pub fn geo_twice() {}", true),
    };
    collision_units[1].module.items[0].span.path = "paired.body";
    collision_units[1].module.items[0].span.line = 8;
    const collision_graph: load.Graph = .{ .units = &collision_units };
    var collision_diagnostics: Io.Writer.Allocating = .init(a);
    try std.testing.expectError(error.SymbolCollision, decideSymbols(a, &collision_graph, &collision_diagnostics.writer));
    try std.testing.expect(std.mem.startsWith(u8, collision_diagnostics.written(), "paired.body:8:1: error:"));
}
