//! Imported-signature and ownership-consumption regression tests.
const std = @import("std");
const Checker = @import("../borrowck.zig").Checker;
const bk_tests_support = @import("tests_support.zig");

fn checkImportedForTest(allocator: std.mem.Allocator, source: []const u8, imported: []const u8, key: []const u8, writer: *std.Io.Writer) !bool {
    var imported_lexer = bk_tests_support.lexer.Lexer.init(imported, "import.cell");
    const imported_tokens = try imported_lexer.tokenizeAll(allocator);
    var imported_parser = bk_tests_support.parser.Parser.init(allocator, imported_tokens.items, "import.cell");
    const imported_module = try imported_parser.parseModule();
    var lex = bk_tests_support.lexer.Lexer.init(source, "entry.cell");
    const tokens = try lex.tokenizeAll(allocator);
    var parser_state = bk_tests_support.parser.Parser.init(allocator, tokens.items, "entry.cell");
    const module = try parser_state.parseModule();
    var checker = Checker.init(allocator, "entry.cell", source);
    defer checker.deinit();
    try checker.registerImportedSignature(key, imported_module.items[0].kind.fn_def);
    try std.testing.expectEqual(@as(u32, 0), checker.next_binding_id);
    try checker.checkModule(&module);
    try checker.diagnostics.printAll(writer);
    return checker.hasErrors();
}

test "D6 imported arc result refuses all unique consumption sites" {
    const sources = [_][]const u8{
        "pub fn take(owned xs: [Int]); pub fn f() { take(owned geo.fresh()) }",
        "pub fn f() { let owned xs: [Int] = geo.fresh() }",
        "pub fn f() { var owned xs: [Int] = [1]; xs = geo.fresh() }",
        "pub struct Box { owned xs: [Int] } pub fn f() { let owned b = Box { xs: geo.fresh() } }",
        "pub fn f() { let owned xs: [[Int]] = [geo.fresh()] }",
        "pub fn f() -> [Int] { return geo.fresh() }",
        "pub fn take(owned xs: [Int]); pub fn f(copy c: Int) { take(owned match c { 0 => geo.fresh(), _ => geo.fresh() }) }",
    };
    for (sources) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var out: [8192]u8 = undefined;
        var writer = std.Io.Writer.fixed(&out);
        try std.testing.expect(try checkImportedForTest(arena.allocator(), source, "pub fn fresh() -> arc [Int];", "geo.fresh", &writer));
        try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "ownership is shared and cannot be made unique") != null);
    }
}

test "D6 imported owned and shared parameter rules retain local ownership behavior" {
    const cases = [_]struct { signature: []const u8, source: []const u8, rejected: bool }{
        .{ .signature = "pub fn take(owned xs: [Int]);", .source = "pub fn f() { let owned xs: [Int] = [1]; geo.take(xs); let copy n = xs.len }", .rejected = true },
        .{ .signature = "pub fn take(shared xs: [Int]);", .source = "pub fn f() { let owned xs: [Int] = [1]; geo.take(xs); let copy n = xs.len }", .rejected = false },
        .{ .signature = "pub fn take(shared xs: [Int]);", .source = "pub fn f() { let owned xs: [Int] = [1]; geo.take(owned xs) }", .rejected = true },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var out: [8192]u8 = undefined;
        var writer = std.Io.Writer.fixed(&out);
        try std.testing.expectEqual(case.rejected, try checkImportedForTest(arena.allocator(), case.source, case.signature, "geo.take", &writer));
    }
}

test "D6 nested qualified signatures and local qualifier shadowing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var out: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out);
    try std.testing.expect(try checkImportedForTest(arena.allocator(), "pub fn f() -> [Int] { return lib.geo.fresh() }", "pub fn fresh() -> arc [Int];", "lib.geo.fresh", &writer));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "ownership is shared and cannot be made unique") != null);
    writer = std.Io.Writer.fixed(&out);
    try std.testing.expect(try checkImportedForTest(arena.allocator(), "pub fn f() -> [Int] { let copy geo: Int = 1; return geo.fresh() }", "pub fn fresh() -> arc [Int];", "geo.fresh", &writer));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "cannot prove") != null);
}

test "D6 imported borrowed returns and inferred arc bindings preserve classification" {
    const cases = [_]struct { signature: []const u8, source: []const u8, needle: ?[]const u8 }{
        .{ .signature = "pub fn make() -> shared [Int];", .source = "pub fn f() { let owned xs: [Int] = geo.make() }", .needle = "borrow" },
        .{ .signature = "pub fn make() -> arc [Int];", .source = "pub fn f() -> arc [Int] { return geo.make() }", .needle = null },
        .{ .signature = "pub fn make() -> arc [Int];", .source = "pub fn f() { let arc xs: [Int] = geo.make() }", .needle = null },
        .{ .signature = "pub fn make() -> arc [Int];", .source = "pub fn take(copy xs: [Int]); pub fn f() { let arc xs = geo.make(); take(copy xs) }", .needle = "resource-bearing" },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var out: [8192]u8 = undefined;
        var writer = std.Io.Writer.fixed(&out);
        const rejected = try checkImportedForTest(arena.allocator(), case.source, case.signature, "geo.make", &writer);
        if ((case.needle != null) != rejected) std.debug.print("source: {s}\n{s}\n", .{ case.source, writer.buffered() });
        try std.testing.expectEqual(case.needle != null, rejected);
        if (case.needle) |needle| {
            if (std.mem.indexOf(u8, writer.buffered(), needle) == null) {
                std.debug.print("{s}\n", .{writer.buffered()});
                return error.TestExpectedDiagnostic;
            }
        }
    }
}

test "D6 imported struct return inference follows canonical nested resource fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const imported = "pub fn make() -> Outer; pub struct Outer { owned inner: Inner } pub struct Inner { owned xs: [Int] } pub enum Color { Red, Blue }";
    var lex = bk_tests_support.lexer.Lexer.init(imported, "geo.cell");
    const tokens = try lex.tokenizeAll(allocator);
    var parser_state = bk_tests_support.parser.Parser.init(allocator, tokens.items, "geo.cell");
    const imported_module = try parser_state.parseModule();
    var signature = imported_module.items[0].kind.fn_def;
    signature.return_type = .{ .name = "geo.Outer" };
    var outer = imported_module.items[1].kind.struct_def;
    outer.name = "geo.Outer";
    outer.fields[0].ty = .{ .name = "geo.Inner" };
    var inner = imported_module.items[2].kind.struct_def;
    inner.name = "geo.Inner";
    var color = imported_module.items[3].kind.enum_def;
    color.name = "geo.Color";
    const source = "pub fn f() { let owned outer = geo.make(); let copy duplicate = outer.inner }";
    var entry_lex = bk_tests_support.lexer.Lexer.init(source, "entry.cell");
    const entry_tokens = try entry_lex.tokenizeAll(allocator);
    var entry_parser = bk_tests_support.parser.Parser.init(allocator, entry_tokens.items, "entry.cell");
    const module = try entry_parser.parseModule();
    var checker = Checker.init(allocator, "entry.cell", source);
    defer checker.deinit();
    try checker.registerImportedSignature("geo.make", signature);
    try checker.registerImportedStruct("geo.Outer", outer);
    try checker.registerImportedStruct("geo.Inner", inner);
    try checker.registerImportedEnum("geo.Color", color);
    try std.testing.expectEqual(@as(u32, 0), checker.next_binding_id);
    try std.testing.expect(checker.enums.contains("geo.Color"));
    try checker.checkModule(&module);
    var out: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out);
    try checker.diagnostics.printAll(&writer);
    try std.testing.expect(checker.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "resource-bearing") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "outer.inner") != null);
}

test "D6 borrowed call result cannot become owned at any consumption site" {
    const bodies = [_][]const u8{
        "pub fn take(owned xs: [Int]); pub fn f() { take(owned CALLEE()) }",
        "pub fn f() { let owned xs: [Int] = CALLEE() }",
        "pub fn f() { var owned xs: [Int] = CALLEE() }",
        "pub fn f() { var owned xs: [Int] = [1]; xs = CALLEE() }",
        "pub struct Box { owned xs: [Int] } pub fn f() { let owned b = Box { xs: CALLEE() } }",
        "pub fn f() { let owned xs: [[Int]] = [CALLEE()] }",
        "pub fn f() -> [Int] { return CALLEE() }",
        "pub fn take(owned xs: [Int]); pub fn f(copy c: Int) { take(owned match c { 0 => CALLEE(), _ => CALLEE() }) }",
        "pub fn take(owned xs: [Int]); pub fn f() { take(owned if true { CALLEE() } else { CALLEE() }) }",
    };
    for ([_][]const u8{ "make", "geo.make" }) |callee| {
        for ([_][]const u8{ "shared", "exclusive" }) |ownership| {
            for (bodies) |body| {
                var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
                defer arena.deinit();
                const allocator = arena.allocator();
                const source = try std.mem.replaceOwned(u8, allocator, body, "CALLEE", callee);
                const signature = try std.fmt.allocPrint(allocator, "pub fn make() -> {s} [Int];", .{ownership});
                var out: [8192]u8 = undefined;
                var writer = std.Io.Writer.fixed(&out);
                const rejected = try checkImportedForTest(allocator, source, signature, callee, &writer);
                if (!rejected or (std.mem.indexOf(u8, writer.buffered(), "a borrow does not confer ownership") == null and std.mem.indexOf(u8, writer.buffered(), "a borrow does not transfer ownership") == null)) {
                    std.debug.print("source: {s}\n{s}\n", .{ source, writer.buffered() });
                    return error.TestExpectedBorrowConsumptionRefusal;
                }
            }
        }
    }
}

test "D6 borrowed call ownership refusal preserves borrowed uses and fresh owned results" {
    const cases = [_]struct { signature: []const u8, source: []const u8 }{
        .{ .signature = "pub fn make() -> shared [Int];", .source = "pub fn take(shared xs: [Int]); pub fn f() { take(shared geo.make()) }" },
        .{ .signature = "pub fn make() -> exclusive [Int];", .source = "pub fn take(exclusive xs: [Int]); pub fn f() { take(exclusive geo.make()) }" },
        .{ .signature = "pub fn make() -> [Int];", .source = "pub fn take(owned xs: [Int]); pub fn f() { take(owned geo.make()) }" },
        .{ .signature = "pub fn make() -> [Int];", .source = "pub fn f() -> [Int] { return geo.make() }" },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var out: [8192]u8 = undefined;
        var writer = std.Io.Writer.fixed(&out);
        const rejected = try checkImportedForTest(arena.allocator(), case.source, case.signature, "geo.make", &writer);
        if (rejected) std.debug.print("source: {s}\n{s}\n", .{ case.source, writer.buffered() });
        try std.testing.expect(!rejected);
    }
}

test "D6 imported enum variants resolve through the full qualifier in every owning position" {
    const sources = [_][]const u8{
        "pub fn f() { let owned color = geo.Color.Red; let copy other = color }",
        "pub fn f() { var owned color: geo.Color = geo.Color.Red; color = geo.Color.Blue }",
        "pub fn take(owned color: geo.Color); pub fn f() { take(owned geo.Color.Red) }",
        "pub fn f() -> geo.Color { return geo.Color.Red }",
        "pub struct Box { owned color: geo.Color } pub fn f() { let owned box = Box { color: geo.Color.Red } }",
        "pub fn f() { let owned colors: [geo.Color] = [geo.Color.Red, geo.Color.Blue] }",
        "pub fn f(copy n: Int) -> geo.Color { return match n { 0 => geo.Color.Red, _ => geo.Color.Blue } }",
    };
    for (sources) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var lex = bk_tests_support.lexer.Lexer.init(source, "entry.cell");
        const tokens = try lex.tokenizeAll(allocator);
        var parser_state = bk_tests_support.parser.Parser.init(allocator, tokens.items, "entry.cell");
        const module = try parser_state.parseModule();
        var checker = Checker.init(allocator, "entry.cell", source);
        defer checker.deinit();
        var variants = [_][]const u8{ "Red", "Blue" };
        try checker.registerImportedEnum("geo.Color", .{ .name = "geo.Color", .variants = &variants, .is_public = true });
        try checker.checkModule(&module);
        var out: [4096]u8 = undefined;
        var writer = std.Io.Writer.fixed(&out);
        try checker.diagnostics.printAll(&writer);
        if (checker.hasErrors()) std.debug.print("source: {s}\n{s}\n", .{ source, writer.buffered() });
        try std.testing.expect(!checker.hasErrors());
    }
}

test "D6 enum variants reject missing names and respect a local qualifier" {
    const sources = [_][]const u8{
        "pub fn f() -> geo.Color { return geo.Color.Green }",
        "pub fn f() -> geo.Color { return wrong.Color.Red }",
        "pub fn f() -> geo.Color { let copy geo: Int = 1; return geo.Color.Red }",
    };
    for (sources) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var lex = bk_tests_support.lexer.Lexer.init(source, "entry.cell");
        const tokens = try lex.tokenizeAll(allocator);
        var parser_state = bk_tests_support.parser.Parser.init(allocator, tokens.items, "entry.cell");
        const module = try parser_state.parseModule();
        var checker = Checker.init(allocator, "entry.cell", source);
        defer checker.deinit();
        var variants = [_][]const u8{ "Red", "Blue" };
        try checker.registerImportedEnum("geo.Color", .{ .name = "geo.Color", .variants = &variants, .is_public = true });
        try checker.checkModule(&module);
        try std.testing.expect(checker.hasErrors());
    }
}
