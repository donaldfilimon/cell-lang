//! Bootstrap inventory of public declarations in the selected Zig sources.
//! Uses Zig's parser so comments and string contents cannot invent APIs.
const std = @import("std");

const Declaration = struct {
    name: []const u8,
    kind: enum { function, constant, variable },
    line: usize,
    byte_offset: u32,
    root: bool,
};

fn declarations(allocator: std.mem.Allocator, source: [:0]const u8) ![]Declaration {
    var tree = try std.zig.Ast.parse(allocator, source, .{});
    defer tree.deinit(allocator);
    if (tree.errors.len != 0) return error.InvalidZigSource;
    var result: std.ArrayList(Declaration) = .empty;
    errdefer result.deinit(allocator);
    for (0..tree.nodes.len) |index| {
        const node: std.zig.Ast.Node.Index = @fromBackingInt(@intCast(index));
        var fn_buffer: [1]std.zig.Ast.Node.Index = undefined;
        var name_token: ?std.zig.Ast.TokenIndex = null;
        var kind: @FieldType(Declaration, "kind") = .constant;
        if (tree.fullVarDecl(node)) |decl| {
            if (decl.visib_token == null) continue;
            name_token = decl.ast.mut_token + 1;
            kind = if (tree.tokenTag(decl.ast.mut_token) == .keyword_var) .variable else .constant;
        } else if (tree.fullFnProto(&fn_buffer, node)) |decl| {
            // A definition and its prototype are separate AST nodes. Keep
            // only the definition, or a standalone bodyless prototype.
            if (decl.visib_token == null or decl.name_token == null) continue;
            name_token = decl.name_token;
            kind = .function;
        } else continue;
        const token = name_token.?;
        const offset = tree.tokenStart(token);
        var duplicate = false;
        for (result.items) |entry| {
            if (entry.byte_offset == offset) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) continue;
        var root = false;
        for (tree.rootDecls()) |decl| {
            if (decl == node) {
                root = true;
                break;
            }
            var root_fn_buffer: [1]std.zig.Ast.Node.Index = undefined;
            if (tree.fullFnProto(&root_fn_buffer, decl)) |root_fn| {
                if (root_fn.name_token) |root_name| {
                    if (tree.tokenStart(root_name) == offset) root = true;
                }
            }
        }
        // Keep source spelling, including Zig's quoted identifiers. The
        // caller owns the source buffer for the lifetime of these slices.
        try result.append(allocator, .{
            .name = tree.tokenSlice(token),
            .kind = kind,
            .line = 1 + std.mem.count(u8, source[0..offset], "\n"),
            .byte_offset = offset,
            .root = root,
        });
    }
    std.mem.sort(Declaration, result.items, {}, struct {
        fn less(_: void, a: Declaration, b: Declaration) bool {
            return a.byte_offset < b.byte_offset;
        }
    }.less);
    return result.toOwnedSlice(allocator);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len < 2) return error.MissingSourcePaths;
    var buffer: [8192]u8 = undefined;
    var output: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    for (args[1..]) |path| {
        var file_arena: std.heap.ArenaAllocator = .init(init.gpa);
        defer file_arena.deinit();
        const file_allocator = file_arena.allocator();
        const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, file_allocator, .limited(32 * 1024 * 1024));
        const source = try file_allocator.dupeSentinel(u8, bytes, 0);
        const entries = try declarations(file_allocator, source);
        try std.json.Stringify.value(.{ .path = path, .declarations = entries }, .{}, &output.interface);
        try output.interface.writeByte('\n');
    }
    try output.interface.flush();
}

test "inventory ignores fake declarations and retains nested and quoted APIs once" {
    const source =
        \\// pub fn fake() void {}
        \\const hidden = "pub const fake = 1;";
        \\pub const Box = struct {
        \\    pub fn method() void {}
        \\    fn private() void {}
        \\};
        \\pub extern fn external() void;
        \\pub const @"quoted-name" = 1;
        \\pub var mutable: u8 = 0;
    ;
    const found = try declarations(std.testing.allocator, source);
    defer std.testing.allocator.free(found);
    try std.testing.expectEqual(@as(usize, 5), found.len);
    try std.testing.expectEqualStrings("Box", found[0].name);
    try std.testing.expect(found[0].root);
    try std.testing.expectEqualStrings("method", found[1].name);
    try std.testing.expect(!found[1].root);
    try std.testing.expectEqualStrings("external", found[2].name);
    try std.testing.expectEqualStrings("@\"quoted-name\"", found[3].name);
    try std.testing.expectEqual(.variable, found[4].kind);
    try std.testing.expectEqual(@as(usize, 4), found[1].line);
}

test "inventory fails closed on invalid source" {
    try std.testing.expectError(error.InvalidZigSource, declarations(std.testing.allocator, "pub fn broken( {}"));
}

test "inventory marks root function definitions as root" {
    const found = try declarations(std.testing.allocator, "pub fn top() void {}\npub const X = struct { pub fn nested() void {} };");
    defer std.testing.allocator.free(found);
    try std.testing.expectEqual(@as(usize, 3), found.len);
    try std.testing.expectEqualStrings("top", found[0].name);
    try std.testing.expect(found[0].root);
    try std.testing.expect(!found[2].root);
}
