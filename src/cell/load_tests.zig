const std = @import("std");
const load = @import("load.zig");

const Fixture = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    diagnostics: std.Io.Writer.Allocating,

    fn init() Fixture {
        return .{
            .tmp = std.testing.tmpDir(.{}),
            .arena = .init(std.testing.allocator),
            .diagnostics = .init(std.testing.allocator),
        };
    }

    fn deinit(self: *Fixture) void {
        self.diagnostics.deinit();
        self.arena.deinit();
        self.tmp.cleanup();
    }

    fn file(self: *Fixture, path: []const u8, source: []const u8) !void {
        if (std.Io.Dir.path.dirname(path)) |parent| try self.tmp.dir.createDirPath(std.testing.io, parent);
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = source });
    }

    fn graph(self: *Fixture, path: []const u8, options: load.GraphOptions) !load.Graph {
        return load.loadGraph(self.arena.allocator(), std.testing.io, self.tmp.dir, path, options, &self.diagnostics.writer);
    }
};

test "module graph pairs either entry side and preserves interface visibility" {
    var f = Fixture.init();
    defer f.deinit();
    try f.file("geometry.cell", "pub fn area() -> Int; fn helper() -> Int;");
    try f.file("geometry.body", "fn area() -> Int { return 42 } pub fn helper() -> Int { return 1 }");
    const module_graph = try f.graph("geometry.cell", .{});
    const body_graph = try f.graph("geometry.body", .{});
    try std.testing.expectEqual(@as(usize, 1), module_graph.units.len);
    try std.testing.expectEqualStrings(module_graph.entry().identity, body_graph.entry().identity);
    try std.testing.expectEqualStrings(module_graph.entry().source, body_graph.entry().source);
    for ([_]load.Graph{ module_graph, body_graph }) |g| {
        try std.testing.expect(g.entry().module.items[0].kind.fn_def.is_public);
        try std.testing.expect(!g.entry().module.items[1].kind.fn_def.is_public);
        try std.testing.expect(g.entry().module.items[0].kind.fn_def.body != null);
    }
}

test "module graph orders diamond dependencies once and repeated imports are idempotent" {
    var f = Fixture.init();
    defer f.deinit();
    try f.file("main.cell", "use left use right use left pub fn main() {}");
    try f.file("left.cell", "use common pub fn left() {}");
    try f.file("right.cel", "use common pub fn right() {}");
    try f.file("common.cell", "pub fn common() {}");
    const graph = try f.graph("main.cell", .{});
    try std.testing.expectEqual(@as(usize, 4), graph.units.len);
    for ([_][]const u8{ "common", "left", "right", "main" }, graph.units) |name, unit| {
        try std.testing.expectEqualStrings(name, unit.name);
    }
    try std.testing.expectEqual(@as(usize, 2), graph.entry().imports.len);
    try std.testing.expectEqual(@as(usize, 0), graph.units[1].imports[0].unit);
    try std.testing.expectEqual(@as(usize, 0), graph.units[2].imports[0].unit);
    try std.testing.expect(graph.entry().is_entry);
    try std.testing.expect(!graph.units[0].is_entry);
}

test "module graph rejects a cycle through a paired body before checking" {
    var f = Fixture.init();
    defer f.deinit();
    try f.file("a.cell", "pub fn a();");
    try f.file("a.body", "use b fn a() {}");
    try f.file("b.cell", "use a pub fn b() {}");
    try std.testing.expectError(error.ImportCycle, f.graph("a.cell", .{}));
    const text = f.diagnostics.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "b.cell:1:1: error: import cycle: a.cell -> b.cell -> a.cell") != null);
}

test "module graph refuses interface and body ambiguity" {
    var f = Fixture.init();
    defer f.deinit();
    try f.file("main.cell", "use geometry pub fn main() {}");
    try f.file("geometry.cell", "pub fn area();");
    try f.file("geometry.cel", "pub fn area();");
    try std.testing.expectError(error.AmbiguousModule, f.graph("main.cell", .{}));
    try std.testing.expect(std.mem.indexOf(u8, f.diagnostics.written(), "ambiguous module 'geometry'") != null);
    try f.tmp.dir.deleteFile(std.testing.io, "geometry.cel");
    try f.file("geometry.body", "fn area() {}");
    try f.file("geometry.bod", "fn area() {}");
    try std.testing.expectError(error.AmbiguousBody, f.graph("geometry.cell", .{}));
    try std.testing.expectError(error.AmbiguousBody, f.graph("geometry.body", .{}));
}

test "module graph std lookup never opens filesystem shadow modules" {
    var f = Fixture.init();
    defer f.deinit();
    try f.file("main.cell", "use std.prelude pub fn main() {}");
    try f.file("std/prelude.cell", "THIS IS NOT CELL");
    try f.file("prelude.cell", "THIS ALSO IS NOT CELL");
    const graph = try f.graph("main.cell", .{ .std_modules = &.{.{ .name = "prelude", .source = "pub fn print_int(copy n: Int);" }} });
    try std.testing.expectEqual(@as(usize, 2), graph.units.len);
    try std.testing.expectEqualStrings("std.prelude", graph.units[0].identity);
    try std.testing.expectEqualStrings("prelude", graph.entry().imports[0].name);
    try f.file("unknown.cell", "use std.io pub fn main() {}");
    try std.testing.expectError(error.ModuleNotFound, f.graph("unknown.cell", .{}));
    try f.file("root.cell", "use std pub fn main() {}");
    try std.testing.expectError(error.ModuleNotFound, f.graph("root.cell", .{}));
    try std.testing.expect(std.mem.indexOf(u8, f.diagnostics.written(), "standard root, not a module") != null);
}

test "module graph chooses local then configured roots in argument order" {
    var f = Fixture.init();
    defer f.deinit();
    try f.file("app/main.cell", "use util pub fn main() {}");
    try f.file("first/util.cell", "pub fn first() {}");
    try f.file("second/util.cell", "pub fn second() {}");
    const graph = try f.graph("app/main.cell", .{ .module_roots = &.{ "first", "second" } });
    try std.testing.expectEqualStrings("first/util.cell", graph.units[0].path);
    const reversed = try f.graph("app/main.cell", .{ .module_roots = &.{ "second", "first" } });
    try std.testing.expectEqualStrings("second/util.cell", reversed.units[0].path);
    try f.file("app/util.cell", "pub fn local() {}");
    const local = try f.graph("app/main.cell", .{ .module_roots = &.{ "first", "second" } });
    try std.testing.expectEqualStrings("app/util.cell", local.units[0].path);
}

test "module graph diagnoses missing modules with the exact search order" {
    var f = Fixture.init();
    defer f.deinit();
    try f.file("app/main.cell", "use geo pub fn main() {}");
    try f.file("lib/unrelated.cell", "pub fn f() {}");
    try std.testing.expectError(error.ModuleNotFound, f.graph("app/main.cell", .{ .module_roots = &.{"lib"} }));
    try std.testing.expectEqualStrings("app/main.cell:1:1: error: module 'geo' not found; searched app/geo.cell, app/geo.cel, lib/geo.cell, lib/geo.cel\n", f.diagnostics.written());
    try std.testing.expectError(error.InvalidModuleRoot, f.graph("app/main.cell", .{ .module_roots = &.{"absent"} }));
}

test "module graph rejects different units with the same local qualifier" {
    var f = Fixture.init();
    defer f.deinit();
    try f.file("main.cell", "use a.util use b.util pub fn main() {}");
    try f.file("a/util.cell", "pub fn a() {}");
    try f.file("b/util.cell", "pub fn b() {}");
    try std.testing.expectError(error.ModuleNameCollision, f.graph("main.cell", .{}));
    try std.testing.expect(std.mem.indexOf(u8, f.diagnostics.written(), "module name 'util' is already imported from a/util.cell") != null);
}

test "module graph deduplicates a unit reached through normalized filesystem paths" {
    var f = Fixture.init();
    defer f.deinit();
    try f.file("main.cell", "use a use b pub fn main() {}");
    try f.file("a.cell", "use util pub fn a() {}");
    try f.file("sub/b.cell", "use util pub fn b() {}");
    try f.file("util.cell", "pub fn util() {}");
    const graph = try f.graph("main.cell", .{ .module_roots = &.{ "sub", "." } });
    try std.testing.expectEqual(@as(usize, 4), graph.units.len);
    try std.testing.expectEqual(graph.units[1].imports[0].unit, graph.units[2].imports[0].unit);
}

test "module graph rejects nominal namespace collisions through different importers" {
    var f = Fixture.init();
    defer f.deinit();
    try f.file("main.cell", "use a use b pub fn main() {}");
    try f.file("a.cell", "use one.geo pub fn a() {}");
    try f.file("b.cell", "use two.geo pub fn b() {}");
    try f.file("one/geo.cell", "pub struct Point { copy x: Int }");
    try f.file("two/geo.cell", "pub struct Point { copy y: Bool }");
    try std.testing.expectError(error.ModuleNameCollision, f.graph("main.cell", .{}));
    try std.testing.expect(std.mem.indexOf(u8, f.diagnostics.written(), "module name 'geo' is already imported from one/geo.cell; cannot also load two/geo.cell") != null);
}

test "paired interface import diagnostics retain the declaration source path" {
    var f = Fixture.init();
    defer f.deinit();
    try f.file("main.cell", "use missing\npub fn main();\n");
    try f.file("main.body", "fn main() {}\n");
    try std.testing.expectError(error.ModuleNotFound, f.graph("main.cell", .{}));
    try std.testing.expect(std.mem.startsWith(u8, f.diagnostics.written(), "main.cell:1:1: error: module 'missing' not found;"));
    try std.testing.expect(std.mem.indexOf(u8, f.diagnostics.written(), "main.body:") == null);
}
