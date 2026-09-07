const std = @import("std");
const ast = @import("ast.zig");
const diag = @import("diag.zig");

pub const Checker = struct {
    allocator: std.mem.Allocator,
    symbols: std.StringHashMap(Symbol),
    diagnostics: diag.Bag = .{},

    pub const Symbol = struct {
        ownership: ast.Ownership,
        mutable: bool,
        ty_name: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator) Checker {
        return .{
            .allocator = allocator,
            .symbols = std.StringHashMap(Symbol).init(allocator),
        };
    }

    pub fn deinit(self: *Checker) void {
        self.symbols.deinit();
        self.diagnostics.deinit(self.allocator);
    }

    pub fn checkModule(self: *Checker, module: *ast.Module) !void {
        for (module.items) |*item| {
            try self.checkItem(item);
        }
        if (self.diagnostics.hasErrors()) {
            for (self.diagnostics.list.items) |d| {
                std.debug.print("{s}:{d}:{d}: {s}: {s}\n", .{
                    d.path,
                    d.line,
                    d.column,
                    @tagName(d.level),
                    d.message,
                });
            }
            return error.TypeError;
        }
    }

    fn checkItem(self: *Checker, item: *ast.Item) !void {
        switch (item.*) {
            .fn_def => |*f| try self.checkFn(f),
            .struct_def => |*s| {
                try self.symbols.put(s.name, .{
                    .ownership = .owned,
                    .mutable = false,
                    .ty_name = "Type",
                });
            },
            .enum_def => |*e| {
                try self.symbols.put(e.name, .{
                    .ownership = .copy,
                    .mutable = false,
                    .ty_name = "Enum",
                });
            },
            .use_decl => {},
        }
    }

    fn checkFn(self: *Checker, f: *ast.FnDef) !void {
        for (f.params) |param| {
            const ty_name = typeName(&param.ty);
            try self.symbols.put(param.name, .{
                .ownership = param.ownership,
                .mutable = param.ownership == .exclusive or param.ownership == .owned,
                .ty_name = ty_name,
            });
        }
        if (f.body) |body| {
            for (body) |*stmt| try self.checkStmt(stmt);
        }
    }

    fn checkStmt(self: *Checker, stmt: *ast.Stmt) CheckError!void {
        switch (stmt.*) {
            .let => |*l| {
                if (l.value) |*v| try self.checkExpr(v);
                const ty_name = if (l.ty) |*t| typeName(t) else "Infer";
                try self.symbols.put(l.name, .{
                    .ownership = l.ownership,
                    .mutable = l.mutable,
                    .ty_name = ty_name,
                });
            },
            .expr => |*e| try self.checkExpr(e),
            .return_stmt => |*opt| {
                if (opt.*) |*e| try self.checkExpr(e);
            },
            .assign => |*a| {
                if (self.symbols.get(a.name)) |sym| {
                    if (!sym.mutable) {
                        try self.diagnostics.push(
                            self.allocator,
                            .err,
                            "",
                            0,
                            0,
                            "cannot assign to immutable binding",
                        );
                    }
                }
                try self.checkExpr(&a.value);
            },
        }
    }

    fn checkExpr(self: *Checker, expr: *ast.Expr) CheckError!void {
        switch (expr.*) {
            .ident => {},
            .int, .float, .string, .bool => {},
            .call => |*c| {
                try self.checkExpr(c.callee);
                for (c.args) |*a| try self.checkExpr(a);
            },
            .binary => |*b| {
                try self.checkExpr(b.left);
                try self.checkExpr(b.right);
            },
            .unary => |*u| try self.checkExpr(u.operand),
            .block => |stmts| {
                for (stmts) |*s| try self.checkStmt(s);
            },
            .if_expr => |*i| {
                try self.checkExpr(i.cond);
                try self.checkExpr(i.then_body);
                if (i.else_body) |e| try self.checkExpr(e);
            },
            .match_expr => |*m| {
                try self.checkExpr(m.scrutinee);
                for (m.arms) |arm| try self.checkExpr(arm.body);
            },
        }
    }

    fn typeName(ty: *const ast.TypeExpr) []const u8 {
        return switch (ty.*) {
            .name => |n| n,
            .optional => "Optional",
            .list => "List",
            .result => "Result",
            .ref => "Ref",
            .unit => "()",
        };
    }
};

pub const TypeError = error{TypeError};
pub const CheckError = error{ OutOfMemory, TypeError };
