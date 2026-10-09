//! Attach source provenance before paired modules or whole programs combine.
const ast = @import("ast.zig");

pub fn attach(module: *ast.Module, source: []const u8) void {
    for (module.items) |*item| {
        mark(&item.span, module.path, source);
        switch (item.kind) {
            .fn_def => |*def| if (def.body) |body| statements(body, module.path, source),
            .struct_def, .enum_def, .use_decl => {},
        }
    }
}

fn mark(span: *ast.Span, path: []const u8, source: []const u8) void {
    span.path = path;
    span.source = source;
}

fn statements(body: []ast.Stmt, path: []const u8, source: []const u8) void {
    for (body) |*stmt| {
        mark(&stmt.span, path, source);
        switch (stmt.kind) {
            .let => |*decl| if (decl.value) |*value| expression(value, path, source),
            .expr => |*expr| expression(expr, path, source),
            .return_stmt => |*value| if (value.*) |*expr| expression(expr, path, source),
            .assign => |*assignment| {
                expression(&assignment.target, path, source);
                expression(&assignment.value, path, source);
            },
            .while_stmt => |*loop| {
                expression(&loop.cond, path, source);
                statements(loop.body, path, source);
            },
            .break_stmt, .continue_stmt => {},
        }
    }
}

fn expression(expr: *ast.Expr, path: []const u8, source: []const u8) void {
    mark(&expr.span, path, source);
    switch (expr.kind) {
        .ident, .int, .float, .string, .bool => {},
        .call => |*call| {
            expression(call.callee, path, source);
            for (call.args) |*arg| expression(arg, path, source);
        },
        .binary => |*binary| {
            expression(binary.left, path, source);
            expression(binary.right, path, source);
        },
        .unary => |*unary| expression(unary.operand, path, source),
        .annotated => |*annotated| expression(annotated.value, path, source),
        .field => |*field| expression(field.base, path, source),
        .index => |*index| {
            expression(index.base, path, source);
            expression(index.index, path, source);
        },
        .struct_lit => |*literal| for (literal.fields) |*field| {
            mark(&field.span, path, source);
            expression(&field.value, path, source);
        },
        .list_lit => |elements| for (elements) |*element| expression(element, path, source),
        .block => |body| statements(body, path, source),
        .if_expr => |*conditional| {
            expression(conditional.cond, path, source);
            expression(conditional.then_body, path, source);
            if (conditional.else_body) |other| expression(other, path, source);
        },
        .match_expr => |*match| {
            expression(match.scrutinee, path, source);
            for (match.arms) |*arm| {
                mark(&arm.span, path, source);
                mark(&arm.pattern.span, path, source);
                if (arm.guard) |guard| expression(guard, path, source);
                expression(arm.body, path, source);
            }
        },
        .wrap => |*wrap| if (wrap.operand) |operand| expression(operand, path, source),
    }
}

test "source provenance reaches guards and nested expressions" {
    const std = @import("std");
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    const source = "pub fn f(copy n: Int) -> Int { return match n { 0 if true => { let copy xs = [1]; 2 }, _ => 3 } }";
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var lex = lexer.Lexer.init(source, "original.cell");
    const tokens = try lex.tokenizeAll(allocator);
    var parse = parser.Parser.init(allocator, tokens.items, "original.cell");
    var module = try parse.parseModule();
    attach(&module, source);
    const arm = module.items[0].kind.fn_def.body.?[0].kind.return_stmt.?.kind.match_expr.arms[0];
    try std.testing.expectEqualStrings("original.cell", arm.guard.?.span.path.?);
    try std.testing.expectEqualStrings(source, arm.pattern.span.source.?);
    const element = arm.body.kind.block[0].kind.let.value.?.kind.list_lit[0];
    try std.testing.expectEqualStrings("original.cell", element.span.path.?);
    try std.testing.expectEqualStrings(source, element.span.source.?);
}
