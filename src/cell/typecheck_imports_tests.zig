const std = @import("std");
const ast = @import("ast.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const tc = @import("typecheck.zig");

fn parse(allocator: std.mem.Allocator, source: []const u8) !ast.Module {
    var lex = lexer.Lexer.init(source, "module.cell");
    const tokens = try lex.tokenizeAll(allocator);
    var p = parser.Parser.init(allocator, tokens.items, "module.cell");
    return p.parseModule();
}

fn has(checker: *const tc.Checker, text: []const u8) bool {
    for (checker.diagnostics.list.items) |d| if (std.mem.indexOf(u8, d.message, text) != null) return true;
    return false;
}

test "module imports nominal identity fields and ownership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var geo = try parse(a, "pub struct Point { copy x: Int } pub struct Box { copy point: Point } pub enum Color { Red } pub fn get(copy b: Box) -> Point { return b.point; } pub fn take(owned p: Point);");
    var declared = tc.Checker.init(std.testing.allocator);
    defer declared.deinit();
    try declared.checkModuleWithImports(&geo, "geo", &.{});
    try std.testing.expect(!declared.diagnostics.hasErrors());
    var entry = try parse(a, "pub fn f() -> Int { let copy p: geo.Point = geo.Point { x: 4 }; let copy box: geo.Box = geo.Box { point: p }; let copy c: geo.Color = geo.Color.Red; return geo.get(copy box).x; }");
    var check = tc.Checker.init(std.testing.allocator);
    defer check.deinit();
    try check.checkModuleWithImports(&entry, null, &.{.{ .name = "geo", .module = &geo, .context = &declared }});
    try std.testing.expect(!check.diagnostics.hasErrors());
    try std.testing.expectEqual(ast.Ownership.owned, (try check.importedFunction("geo.take")).?.params[0].ownership);
}

test "module imports refuse unrelated nominal Points and private access" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var geo = try parse(a, "pub struct Point { copy x: Int } struct Hidden { copy x: Int } fn secret() -> Int { return 1; } pub fn take(copy p: Point);");
    var entry = try parse(a, "pub struct Point { copy x: Int } pub fn f() { let copy p = Point { x: 1 }; geo.take(copy p); geo.secret(); let copy x: geo.Hidden; }");
    var check = tc.Checker.init(std.testing.allocator);
    defer check.deinit();
    try check.checkModuleWithImports(&entry, null, &.{.{ .name = "geo", .module = &geo }});
    try std.testing.expect(has(&check, "geo.Point"));
    try std.testing.expect(has(&check, "geo.secret' is private"));
    try std.testing.expect(has(&check, "geo.Hidden' is private"));
}

test "module imports public signatures refuse private nested types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var module = try parse(arena.allocator(), "struct Hidden { copy x: Int } pub fn expose(shared xs: [Hidden]) -> Hidden?; pub struct Export { owned secret: Result<Int, Hidden> }");
    var check = tc.Checker.init(std.testing.allocator);
    defer check.deinit();
    try check.checkModule(&module);
    try std.testing.expect(has(&check, "public signature exposes private type 'Hidden'"));
}

test "module imports locals shadow qualifiers and imports are not transitive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var geo = try parse(a, "pub fn value() -> Int { return 3; }");
    var entry = try parse(a, "pub struct Local { copy value: Int } pub fn f() -> Int { let copy geo = Local { value: 7 }; return geo.value; } pub fn g() { other.value(); }");
    var check = tc.Checker.init(std.testing.allocator);
    defer check.deinit();
    try check.checkModuleWithImports(&entry, null, &.{.{ .name = "geo", .module = &geo }});
    try std.testing.expect(has(&check, "unknown identifier 'other'"));
    try std.testing.expect(!has(&check, "type Local has no field"));
}

test "module imports normalize exported references in declaring context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var geo = try parse(a, "pub struct Point { copy x: Int } pub fn take(owned p: Point) -> [Point];");
    var declared = tc.Checker.init(std.testing.allocator);
    defer declared.deinit();
    try declared.checkModuleWithImports(&geo, "geo", &.{});
    const function = (try declared.exportedFunction("take")).?;
    try std.testing.expectEqualStrings("geo.take", function.name);
    try std.testing.expectEqualStrings("geo.Point", function.params[0].ty.name);
    try std.testing.expectEqualStrings("geo.Point", function.return_type.?.list.name);
    var wrapper = try parse(a, "pub struct Box { copy point: geo.Point } pub fn get(copy b: Box) -> geo.Point { return b.point; }");
    var wrapper_check = tc.Checker.init(std.testing.allocator);
    defer wrapper_check.deinit();
    try wrapper_check.checkModuleWithImports(&wrapper, "wrapper", &.{.{ .name = "geo", .module = &geo, .context = &declared }});
    try std.testing.expect(!wrapper_check.diagnostics.hasErrors());
    const box = (try wrapper_check.exportedStruct("Box")).?;
    try std.testing.expectEqualStrings("geo.Point", box.fields[0].ty.name);
    var entry = try parse(a, "pub struct Point { copy wrong: Bool } pub fn f(shared b: wrapper.Box) -> Int { return wrapper.get(copy b).x; }");
    var check = tc.Checker.init(std.testing.allocator);
    defer check.deinit();
    try check.checkModuleWithImports(&entry, null, &.{.{ .name = "wrapper", .module = &wrapper, .context = &wrapper_check }});
    try std.testing.expect(!check.diagnostics.hasErrors());
}

test "module imports reject duplicate qualifiers and top item collisions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var geo = try parse(a, "pub fn value() -> Int;");
    var entry = try parse(a, "pub struct geo { copy x: Int } pub struct same { copy x: Int } pub fn same();");
    var check = tc.Checker.init(std.testing.allocator);
    defer check.deinit();
    try check.checkModuleWithImports(&entry, null, &.{ .{ .name = "geo", .module = &geo }, .{ .name = "geo", .module = &geo } });
    try std.testing.expect(has(&check, "duplicate declaration of 'geo'"));
    try std.testing.expect(has(&check, "duplicate declaration of 'same'"));
}

test "module imports refuse nominal type heads in ordinary value positions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var geo = try parse(a, "pub struct Point { copy x: Int } pub enum Color { Red }");
    var entry = try parse(a, "pub fn f() { let copy color = geo.Color; let copy point = geo.Point; let copy red = geo.Color.Red; let copy p: geo.Point = geo.Point { x: 7 }; }");
    var check = tc.Checker.init(std.testing.allocator);
    defer check.deinit();
    try check.checkModuleWithImports(&entry, null, &.{.{ .name = "geo", .module = &geo }});
    try std.testing.expect(has(&check, "type 'geo.Color' cannot be used as a value"));
    try std.testing.expect(has(&check, "type 'geo.Point' cannot be used as a value"));
    try std.testing.expectEqual(@as(usize, 2), check.diagnostics.list.items.len);
}

test "module imports enum patterns enforce nominal identity and membership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var geo = try parse(a, "pub enum Color { Red } enum Private { Red }");
    var other = try parse(a, "pub enum Color { Red }");
    var entry = try parse(a, "pub fn f() -> Int { let copy c = geo.Color.Red; return match c { other.Color.Red => 77, geo.Color.Missing => 1, missing.Color.Red => 2, geo.Private.Red => 3, _ => 88 }; }");
    var check = tc.Checker.init(std.testing.allocator);
    defer check.deinit();
    try check.checkModuleWithImports(&entry, null, &.{ .{ .name = "geo", .module = &geo }, .{ .name = "other", .module = &other } });
    try std.testing.expect(has(&check, "enum pattern type mismatch: expected geo.Color, found other.Color"));
    try std.testing.expect(has(&check, "enum 'geo.Color' has no variant 'Missing'"));
    try std.testing.expect(has(&check, "unknown type 'missing.Color'"));
    try std.testing.expect(has(&check, "item 'geo.Private' is private"));
}

test "module imports enum patterns accept own qualified and bare variants" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var geo = try parse(a, "pub enum Color { Red, Blue } pub fn own(copy c: Color) -> Int { return match c { Color.Red => 1, Blue => 2 }; }");
    var declared = tc.Checker.init(std.testing.allocator);
    defer declared.deinit();
    try declared.checkModuleWithImports(&geo, "geo", &.{});
    try std.testing.expect(!declared.diagnostics.hasErrors());
    var entry = try parse(a, "pub fn f(copy c: geo.Color) -> Int { return match c { geo.Color.Red => 1, Blue => 2 }; }");
    var check = tc.Checker.init(std.testing.allocator);
    defer check.deinit();
    try check.checkModuleWithImports(&entry, null, &.{.{ .name = "geo", .module = &geo, .context = &declared }});
    try std.testing.expect(!check.diagnostics.hasErrors());
}
