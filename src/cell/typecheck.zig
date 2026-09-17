//! The Cell typechecker.
//!
//! Two passes over a module. `collectItems` registers every struct, enum, and
//! function signature at module scope, so a function may call one declared
//! later in the file. `checkItem` then walks bodies with those signatures
//! already visible.
//!
//! Types live in `types.zig` and are allocated from an arena owned by the
//! `Checker`, together with every formatted diagnostic message. One
//! `arena.deinit()` in `Checker.deinit` releases both, which is why a message
//! may be built with `allocPrint` and handed to the bag as a plain slice.
//!
//! Diagnostics are NOT printed here. `checkModule` fills `self.diagnostics` and
//! returns; the caller renders the bag through `diag.Bag.printAll`, which is
//! what produces the source line and caret. `root.check` does that.

const std = @import("std");
const ast = @import("ast.zig");
const diag = @import("diag.zig");
const types = @import("types.zig");

const Type = types.Type;

/// The anonymous payload structs inside `ast.Expr.Kind` have no name to import,
/// so they are named here for the helpers that take one.
const CallExpr = @FieldType(ast.Expr.Kind, "call");
const BinaryExpr = @FieldType(ast.Expr.Kind, "binary");
const FieldExpr = @FieldType(ast.Expr.Kind, "field");
const IndexExpr = @FieldType(ast.Expr.Kind, "index");
const StructLitExpr = @FieldType(ast.Expr.Kind, "struct_lit");

pub const Checker = struct {
    allocator: std.mem.Allocator,
    /// Backs every constructed type and every formatted message.
    arena_state: std.heap.ArenaAllocator,
    diagnostics: diag.Bag = .{},

    /// Value bindings, innermost last. A flat stack searched backward rather
    /// than one map per scope: a scope here holds a handful of names, so the
    /// linear scan is cheaper than a hash map and cannot get the shadowing
    /// order wrong.
    scopes: std.ArrayList(Entry) = .empty,
    /// 0 is module scope, a function body is 1, each block nests deeper.
    depth: u32 = 0,

    /// Named types are module-wide. Cell has no local type declarations, so
    /// these do not belong on the scope stack.
    structs: std.StringHashMap(ast.StructDef),
    enums: std.StringHashMap(ast.EnumDef),

    /// Declared return type of the function whose body is being checked.
    fn_return: Type = types.t_unit,
    /// How many `while` bodies enclose the statement being checked. `break`
    /// and `continue` outside a loop have nothing to jump to and would emit C
    /// that does not compile, so they are rejected here rather than there.
    loop_depth: u32 = 0,

    pub const Symbol = struct {
        ownership: ast.Ownership,
        mutable: bool,
        ty: Type,
    };

    const Entry = struct {
        name: []const u8,
        depth: u32,
        sym: Symbol,
    };

    pub fn init(allocator: std.mem.Allocator) Checker {
        return .{
            .allocator = allocator,
            .arena_state = .init(allocator),
            .structs = .init(allocator),
            .enums = .init(allocator),
        };
    }

    pub fn deinit(self: *Checker) void {
        self.scopes.deinit(self.allocator);
        self.structs.deinit();
        self.enums.deinit();
        self.diagnostics.deinit(self.allocator);
        self.arena_state.deinit();
    }

    fn arena(self: *Checker) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    // -- entry point --------------------------------------------------------

    /// Check a module. Problems land in `self.diagnostics`; the only error this
    /// returns is allocation failure. The caller decides what to do with a bag
    /// that `hasErrors()`.
    pub fn checkModule(self: *Checker, module: *ast.Module) CheckError!void {
        self.diagnostics.path = module.path;
        try self.collectItems(module.items);
        for (module.items) |*item| {
            try self.checkItem(item);
        }
    }

    /// Pass one: every item name and signature, before any body is walked.
    fn collectItems(self: *Checker, items: []ast.Item) CheckError!void {
        for (items) |*item| {
            switch (item.kind) {
                .struct_def => |s| {
                    if (self.structs.contains(s.name) or self.enums.contains(s.name)) {
                        try self.duplicate(item.span, s.name);
                        continue;
                    }
                    try self.structs.put(s.name, s);
                },
                .enum_def => |e| {
                    if (self.structs.contains(e.name) or self.enums.contains(e.name)) {
                        try self.duplicate(item.span, e.name);
                        continue;
                    }
                    try self.enums.put(e.name, e);
                },
                .fn_def, .use_decl => {},
            }
        }

        // Signatures and field types are resolved only after every named type
        // is registered, so a function may take a struct declared below it and
        // `struct A { b: B }` may mention `B` before `B` is written.
        for (items) |*item| {
            switch (item.kind) {
                .fn_def => |f| {
                    const params = try self.arena().alloc(Type, f.params.len);
                    for (f.params, 0..) |p, i| {
                        params[i] = try self.resolveType(&p.ty, item.span);
                        try self.refuseUnitValue(item.span, params[i]);
                    }
                    const ret = try self.arena().create(Type);
                    ret.* = if (f.return_type) |rt| try self.resolveType(&rt, item.span) else types.t_unit;
                    try self.declare(item.span, f.name, .{
                        .ownership = .copy,
                        .mutable = false,
                        .ty = .{ .func = .{ .params = params, .ret = ret } },
                    });
                },
                .struct_def => |s| {
                    for (s.fields) |field| {
                        const field_ty = try self.resolveType(&field.ty, item.span);
                        try self.refuseUnitValue(item.span, field_ty);
                    }
                },
                else => {},
            }
        }
    }

    fn checkItem(self: *Checker, item: *ast.Item) CheckError!void {
        switch (item.kind) {
            .fn_def => |*f| try self.checkFn(item.span, f),
            .struct_def, .enum_def, .use_decl => {},
        }
    }

    fn checkFn(self: *Checker, span: ast.Span, f: *const ast.FnDef) CheckError!void {
        const saved_return = self.fn_return;
        defer self.fn_return = saved_return;

        // Signatures were resolved in collectItems. Reuse them so an unknown
        // parameter or return type is reported once, not once per pass.
        const fn_ty = if (self.lookup(f.name)) |sym| sym.ty else types.t_unknown;
        const param_tys: []const Type = switch (fn_ty) {
            .func => |func| func.params,
            else => &.{},
        };
        self.fn_return = switch (fn_ty) {
            .func => |func| func.ret.*,
            else => if (f.return_type) |rt| try self.resolveType(&rt, span) else types.t_unit,
        };

        self.pushScope();
        defer self.popScope();

        // Parameters share the function scope with the body's own bindings, so
        // a `let` reusing a parameter name is a duplicate rather than a shadow.
        // A signature and its body are one lexical region here.
        for (f.params, 0..) |p, i| {
            const ty = if (i < param_tys.len) param_tys[i] else try self.resolveType(&p.ty, span);
            try self.declare(span, p.name, .{
                .ownership = p.ownership,
                .mutable = p.ownership == .exclusive or p.ownership == .owned,
                .ty = ty,
            });
        }

        const body = f.body orelse return; // a bodyless declaration
        for (body) |*stmt| try self.checkStmt(stmt);

        if (self.fn_return.tag() != .unit and !alwaysReturns(body)) {
            try self.errf(span, "missing return in function '{s}' declared to return {s}", .{
                f.name,
                try self.typeName(self.fn_return),
            });
        }
    }

    // -- statements ---------------------------------------------------------

    fn checkStmt(self: *Checker, stmt: *ast.Stmt) CheckError!void {
        switch (stmt.kind) {
            .while_stmt => |*w| {
                const cond = try self.checkExpr(@constCast(&w.cond));
                if (!cond.isUnknown() and cond.tag() != .boolean) {
                    try self.errf(
                        w.cond.span,
                        "a while condition must be Bool, found {s}",
                        .{try self.typeName(cond)},
                    );
                }
                // The body is a scope of its own, so a binding declared in it
                // does not leak past the loop.
                self.pushScope();
                defer self.popScope();
                self.loop_depth += 1;
                defer self.loop_depth -= 1;
                for (w.body) |*s2| try self.checkStmt(@constCast(s2));
            },
            .break_stmt, .continue_stmt => {
                if (self.loop_depth == 0) {
                    try self.errf(
                        stmt.span,
                        "'{s}' is only valid inside a loop",
                        .{if (stmt.kind == .break_stmt) "break" else "continue"},
                    );
                }
            },
            .let => |*l| {
                const annotated: ?Type = if (l.ty) |t| try self.resolveType(&t, stmt.span) else null;
                var bound: Type = annotated orelse types.t_unknown;
                const annotated_unit = annotated != null and annotated.?.tag() == .unit;
                if (annotated_unit) try self.refuseUnitValue(stmt.span, types.t_unit);
                if (annotated == null) {
                    if (l.value) |*v| {
                        if (v.kind == .wrap and v.kind.wrap.ctor != .some) {
                            const word = switch (v.kind.wrap.ctor) {
                                .none => "'None' needs a declared optional type here",
                                .ok => "'Ok' needs a declared Result type here",
                                .err => "'Err' needs a declared Result type here",
                                .some => unreachable,
                            };
                            try self.errf(v.span, "{s}", .{word});
                        }
                    }
                }
                if (l.value) |*v| {
                    const actual = try self.checkExpr(v);
                    if (annotated) |want| {
                        // A `let` of `()` is already refused above. Skip the
                        // mismatch so a unit initializer does not cascade.
                        if (!annotated_unit and !accepts(want, actual, v)) {
                            try self.errf(
                                v.span,
                                "cannot initialize a binding of type {s} with a value of type {s}",
                                .{ try self.typeName(want), try self.typeName(actual) },
                            );
                        }
                    } else {
                        bound = actual;
                        try self.refuseUnitValue(stmt.span, actual);
                    }
                }
                try self.declare(stmt.span, l.name, .{
                    .ownership = l.ownership,
                    .mutable = l.mutable,
                    .ty = bound,
                });
            },

            .expr => |*e| _ = try self.checkExpr(e),

            .return_stmt => |*opt| {
                if (opt.*) |*e| {
                    const actual = try self.checkExpr(e);
                    if (!accepts(self.fn_return, actual, e)) {
                        try self.errf(e.span, "return type mismatch: expected {s}, found {s}", .{
                            try self.typeName(self.fn_return),
                            try self.typeName(actual),
                        });
                    }
                } else if (self.fn_return.tag() != .unit) {
                    try self.errf(stmt.span, "return type mismatch: expected {s}, found {s}", .{
                        try self.typeName(self.fn_return),
                        try self.typeName(types.t_unit),
                    });
                }
            },

            .assign => |*a| {
                // Indexed assignment `a[i] = x` parses (the target is an
                // expression) and is refused here. The runtime helpers return
                // a Byte?; they do not write.
                if (isIndexExpr(&a.target)) {
                    try self.errf(a.target.span, "indexed assignment is not implemented", .{});
                    _ = try self.checkExpr(&a.target);
                    _ = try self.checkExpr(&a.value);
                    return;
                }
                // R14 (immutable assignment) is borrowck's rule. Typecheck only
                // checks that the value's type matches the target.
                const target = try self.checkExpr(&a.target);
                const value = try self.checkExpr(&a.value);
                if (!accepts(target, value, &a.value)) {
                    try self.errf(
                        a.value.span,
                        "cannot assign a value of type {s} to a target of type {s}",
                        .{ try self.typeName(value), try self.typeName(target) },
                    );
                }
            },
        }
    }

    /// Conservative: does this statement list definitely reach a `return`?
    /// Only a `return` at this level, or an `if` whose two arms both always
    /// return, counts. Anything subtler is reported as missing, which errs
    /// toward a diagnostic on correct code rather than silence on incorrect
    /// code.
    fn alwaysReturns(stmts: []const ast.Stmt) bool {
        for (stmts) |s| {
            switch (s.kind) {
                .return_stmt => return true,
                .expr => |e| if (exprAlwaysReturns(&e)) return true,
                else => {},
            }
        }
        return false;
    }

    fn exprAlwaysReturns(e: *const ast.Expr) bool {
        return switch (e.kind) {
            .block => |stmts| alwaysReturns(stmts),
            .if_expr => |i| blk: {
                const els = i.else_body orelse break :blk false;
                break :blk exprAlwaysReturns(i.then_body) and exprAlwaysReturns(els);
            },
            .annotated => |a| exprAlwaysReturns(a.value),
            else => false,
        };
    }

    // -- expressions --------------------------------------------------------

    fn checkExpr(self: *Checker, expr: *ast.Expr) CheckError!Type {
        switch (expr.kind) {
            .ident => |name| {
                if (self.lookup(name)) |sym| return sym.ty;
                try self.errf(expr.span, "unknown identifier '{s}'", .{name});
                return types.t_unknown;
            },
            .int => return types.t_int,
            .float => return types.t_float,
            .string => return types.t_string,
            .bool => return types.t_bool,

            .call => |*c| return try self.checkCall(expr.span, c),
            .binary => |*b| return try self.checkBinary(expr.span, b),
            .field => |*f| return try self.checkField(expr.span, f),
            .index => |*ix| return try self.checkIndex(expr.span, ix),
            .struct_lit => |*sl| return try self.checkStructLit(expr.span, sl),

            .unary => |*u| {
                const operand = try self.checkExpr(u.operand);
                switch (u.op) {
                    // `&x` and `&mut x` borrow a place. Ownership is not part
                    // of a type here, so a borrow has its operand's type.
                    .ref_shared, .ref_exclusive => return operand,
                    .not => {
                        if (!operand.isUnknown() and operand.tag() != .boolean) {
                            try self.errf(
                                expr.span,
                                "operator '!' requires a Bool operand, found {s}",
                                .{try self.typeName(operand)},
                            );
                        }
                        return types.t_bool;
                    },
                    .neg => {
                        if (!operand.isUnknown() and !operand.isNumeric()) {
                            try self.errf(
                                expr.span,
                                "operator '-' requires a numeric operand, found {s}",
                                .{try self.typeName(operand)},
                            );
                            return types.t_unknown;
                        }
                        return operand;
                    },
                }
            },

            .list_lit => |items| {
                if (items.len == 0) {
                    // `[]` has no element type to infer, and `[unknown]` is
                    // compatible with any list, which is what an empty literal
                    // should be.
                    return try self.listOf(types.t_unknown);
                }
                var elem = try self.checkExpr(&items[0]);
                for (items[1..]) |*e| {
                    const other = try self.checkExpr(e);
                    if (!types.compatible(elem, other)) {
                        try self.errf(e.span, "list element has type {s}, expected {s}", .{
                            try self.typeName(other),
                            try self.typeName(elem),
                        });
                        elem = types.t_unknown;
                    }
                }
                return try self.listOf(elem);
            },

            .block => |stmts| {
                self.pushScope();
                defer self.popScope();
                // CORRECTED 2026-09-15. This used to return unit with the
                // comment "a block has no trailing expression in this
                // grammar", which was false when written: SPEC.md 6.10 makes
                // a block a primary expression, and codegen's `emitValueInto`
                // yields the last statement's expression as the block's
                // value. Typing every block as unit let `let arc r = { let arc
                // a = "x" \n a }` through `cell check` and into C that did not
                // compile. A block's type is its last statement's expression
                // type when that statement is an expression, else unit.
                if (stmts.len == 0) return types.t_unit;
                for (stmts[0 .. stmts.len - 1]) |*s| try self.checkStmt(s);
                const last = &stmts[stmts.len - 1];
                switch (last.kind) {
                    .expr => |*e| return try self.checkExpr(e),
                    else => {
                        try self.checkStmt(last);
                        return types.t_unit;
                    },
                }
            },

            .if_expr => |*i| {
                const cond = try self.checkExpr(i.cond);
                if (!cond.isUnknown() and cond.tag() != .boolean) {
                    try self.errf(i.cond.span, "if condition must be Bool, found {s}", .{
                        try self.typeName(cond),
                    });
                }
                // Both branches are blocks, and since 2026-09-15 a block
                // types as its tail expression, so an `if` with an `else`
                // types as its branches do, following `match`'s precedent
                // for arms: disagreement is an error here rather than a C
                // error downstream. Without an `else` the value is unit.
                const then_ty = try self.checkExpr(i.then_body);
                if (i.else_body) |e| {
                    const else_ty = try self.checkExpr(e);
                    if (!types.compatible(then_ty, else_ty)) {
                        try self.errf(e.span, "if branches have types {s} and {s}", .{
                            try self.typeName(then_ty),
                            try self.typeName(else_ty),
                        });
                        return types.t_unknown;
                    }
                    return then_ty;
                }
                return types.t_unit;
            },

            .match_expr => |*m| {
                const scrutinee = try self.checkExpr(m.scrutinee);
                var result: ?Type = null;
                for (m.arms) |arm| {
                    self.pushScope();
                    defer self.popScope();
                    switch (arm.pattern.kind) {
                        .binding => |name| try self.declare(arm.pattern.span, name, .{
                            .ownership = .copy,
                            .mutable = false,
                            .ty = scrutinee,
                        }),
                        .wrap_pattern => |wp| {
                            const payload: ?Type = switch (wp.ctor) {
                                .some, .none => switch (scrutinee) {
                                    .optional => |inner| inner.*,
                                    .unknown => types.t_unknown,
                                    else => blk: {
                                        try self.errf(arm.pattern.span, "pattern '{s}' needs an optional scrutinee, found {s}", .{
                                            if (wp.ctor == .some) "Some" else "None",
                                            try self.typeName(scrutinee),
                                        });
                                        break :blk null;
                                    },
                                },
                                .ok, .err => switch (scrutinee) {
                                    .result => |r| if (wp.ctor == .ok) r.ok.* else r.err.*,
                                    .unknown => types.t_unknown,
                                    else => blk: {
                                        try self.errf(arm.pattern.span, "pattern '{s}' needs a Result scrutinee, found {s}", .{
                                            if (wp.ctor == .ok) "Ok" else "Err",
                                            try self.typeName(scrutinee),
                                        });
                                        break :blk null;
                                    },
                                },
                            };
                            if (wp.binding) |name| {
                                try self.declare(arm.pattern.span, name, .{
                                    .ownership = .copy,
                                    .mutable = false,
                                    .ty = payload orelse types.t_unknown,
                                });
                            }
                        },
                        else => {},
                    }
                    if (arm.guard) |g| {
                        // A guard on a BINDING pattern would have to reference
                        // a name the arm body declares, and the C backend
                        // declares that name inside the arm rather than before
                        // the if-chain, so the guard could not see it. Rejected
                        // explicitly rather than emitted wrongly.
                        const binds = arm.pattern.kind == .binding or
                            (arm.pattern.kind == .wrap_pattern and arm.pattern.kind.wrap_pattern.binding != null);
                        if (binds) {
                            try self.errf(
                                g.span,
                                "a guard on a binding pattern is not implemented yet",
                                .{},
                            );
                        }
                        const gt = try self.checkExpr(g);
                        if (!gt.isUnknown() and gt.tag() != .boolean) {
                            try self.errf(
                                g.span,
                                "a match guard must be Bool, found {s}",
                                .{try self.typeName(gt)},
                            );
                        }
                    }
                    const body = try self.checkExpr(arm.body);
                    if (result) |want| {
                        if (!types.compatible(want, body)) {
                            try self.errf(arm.span, "match arm has type {s}, expected {s}", .{
                                try self.typeName(body),
                                try self.typeName(want),
                            });
                            result = types.t_unknown;
                        }
                    } else {
                        result = body;
                    }
                }
                return result orelse types.t_unit;
            },

            .annotated => |a| return try self.checkExpr(a.value),

            .wrap => |w| {
                const payload: Type = if (w.operand) |o| try self.checkExpr(o) else types.t_unknown;
                switch (w.ctor) {
                    .some => {
                        if (!isScalarPayload(payload)) {
                            try self.errf(expr.span, "optional/Result payloads other than scalar primitives are not implemented", .{});
                            return try self.optionalOf(types.t_unknown);
                        }
                        return try self.optionalOf(payload);
                    },
                    .none => return try self.optionalOf(types.t_unknown),
                    .ok => {
                        if (!isScalarPayload(payload)) {
                            try self.errf(expr.span, "optional/Result payloads other than scalar primitives are not implemented", .{});
                            return try self.resultOf(types.t_unknown, types.t_unknown);
                        }
                        return try self.resultOf(payload, types.t_unknown);
                    },
                    .err => {
                        // E is carried at its own width (cell_rt.h ABI 2), so
                        // it must be a scalar or a payload-free enum.
                        if (!isScalarPayload(payload) and payload.tag() != .enum_type) {
                            try self.errf(expr.span, "optional/Result payloads other than scalar primitives are not implemented", .{});
                            return try self.resultOf(types.t_unknown, types.t_unknown);
                        }
                        return try self.resultOf(types.t_unknown, payload);
                    },
                }
            },
        }
    }

    fn checkCall(self: *Checker, span: ast.Span, c: *const CallExpr) CheckError!Type {
        const callee = try self.checkExpr(c.callee);

        // Each argument is walked exactly once and its type kept. Recomputing
        // it later from the node would have to reimplement `checkExpr` without
        // its diagnostics, and every shape that reimplementation missed would
        // silently become `unknown`, which is compatible with any parameter.
        const arg_types = try self.arena().alloc(Type, c.args.len);
        for (c.args, 0..) |*a, i| arg_types[i] = try self.checkExpr(a);

        if (callee.isUnknown()) return types.t_unknown;
        const f = switch (callee) {
            .func => |f| f,
            else => {
                try self.errf(c.callee.span, "cannot call a value of type {s}", .{
                    try self.typeName(callee),
                });
                return types.t_unknown;
            },
        };

        if (f.params.len != c.args.len) {
            try self.errf(span, "expected {d} arguments, found {d}", .{ f.params.len, c.args.len });
            return f.ret.*;
        }

        for (f.params, c.args, arg_types, 0..) |want, *arg, actual, i| {
            if (!accepts(want, actual, arg)) {
                try self.errf(arg.span, "argument {d} has type {s}, expected {s}", .{
                    i + 1,
                    try self.typeName(actual),
                    try self.typeName(want),
                });
            }
        }
        return f.ret.*;
    }

    fn checkBinary(self: *Checker, span: ast.Span, b: *const BinaryExpr) CheckError!Type {
        const left = try self.checkExpr(b.left);
        const right = try self.checkExpr(b.right);
        const op = b.op;

        const yields_bool = switch (op) {
            .eq, .ne, .lt, .le, .gt, .ge, .and_op, .or_op => true,
            .add, .sub, .mul, .div => false,
        };
        if (left.isUnknown() or right.isUnknown()) {
            return if (yields_bool) types.t_bool else types.t_unknown;
        }

        switch (op) {
            .and_op, .or_op => {
                if (left.tag() != .boolean or right.tag() != .boolean) {
                    try self.errf(
                        span,
                        "operator '{s}' requires Bool operands, found {s} and {s}",
                        .{ opText(op), try self.typeName(left), try self.typeName(right) },
                    );
                }
                return types.t_bool;
            },
            .eq, .ne => {
                if (!types.compatible(left, right)) try self.opMismatch(span, op, left, right);
                return types.t_bool;
            },
            .lt, .le, .gt, .ge => {
                if (!types.compatible(left, right)) {
                    try self.opMismatch(span, op, left, right);
                } else if (!left.isNumeric()) {
                    try self.errf(
                        span,
                        "operator '{s}' requires numeric operands, found {s} and {s}",
                        .{ opText(op), try self.typeName(left), try self.typeName(right) },
                    );
                }
                return types.t_bool;
            },
            .add, .sub, .mul, .div => {
                if (!types.compatible(left, right)) {
                    try self.opMismatch(span, op, left, right);
                    return types.t_unknown;
                }
                if (!left.isNumeric()) {
                    try self.errf(
                        span,
                        "operator '{s}' requires numeric operands, found {s} and {s}",
                        .{ opText(op), try self.typeName(left), try self.typeName(right) },
                    );
                    return types.t_unknown;
                }
                return left;
            },
        }
    }

    fn opMismatch(
        self: *Checker,
        span: ast.Span,
        op: ast.BinaryOp,
        left: Type,
        right: Type,
    ) CheckError!void {
        try self.errf(span, "operator '{s}' cannot be applied to {s} and {s}", .{
            opText(op),
            try self.typeName(left),
            try self.typeName(right),
        });
    }

    fn checkField(self: *Checker, span: ast.Span, f: *const FieldExpr) CheckError!Type {
        // `Color.Red` is a field expression whose base names an enum rather
        // than a value, so enum access is resolved before the base is checked
        // as an expression. A local binding of the same name wins, which is why
        // the scope lookup is tried first.
        if (ast.rootName(f.base)) |base_name| {
            if (self.lookup(base_name) == null) {
                if (self.enums.get(base_name)) |e| {
                    for (e.variants) |v| {
                        if (std.mem.eql(u8, v, f.name)) return .{ .enum_type = e.name };
                    }
                    try self.errf(span, "enum '{s}' has no variant '{s}'", .{ e.name, f.name });
                    return .{ .enum_type = e.name };
                }
            }
        }

        const base = try self.checkExpr(f.base);
        if (base.isUnknown()) return types.t_unknown;
        const struct_name = switch (base) {
            .struct_type => |n| n,
            else => {
                try self.errf(span, "type {s} has no field '{s}'", .{
                    try self.typeName(base),
                    f.name,
                });
                return types.t_unknown;
            },
        };
        const def = self.structs.get(struct_name) orelse return types.t_unknown;
        for (def.fields) |field| {
            if (std.mem.eql(u8, field.name, f.name)) return try self.resolveTypeQuiet(&field.ty);
        }
        try self.errf(span, "struct '{s}' has no field '{s}'", .{ struct_name, f.name });
        return types.t_unknown;
    }

    /// `a[i]` in expression position. `String` and `[Byte]` type as `Byte?`
    /// (the runtime helpers return `cell_opt_byte_t`: absent on OOB, never a
    /// panic). The index is `Int`; other integer widths are refused rather
    /// than truncated. Anything else names the base type and stays unknown.
    fn checkIndex(self: *Checker, span: ast.Span, ix: *const IndexExpr) CheckError!Type {
        const base = try self.checkExpr(ix.base);
        const index = try self.checkExpr(ix.index);
        if (!index.isUnknown() and index.tag() != .int) {
            try self.errf(ix.index.span, "index must be Int, found {s}", .{
                try self.typeName(index),
            });
        }
        if (base.isUnknown()) return try self.optionalOf(types.t_byte);
        // `String` yields a Byte. A list yields its element for the scalar
        // elements the C runtime has a bounds-checked reader for
        // (2026-09-17). `[String][i]` and other owning elements stay
        // refused: what the result owns is an open design question.
        const element: ?Type = switch (base) {
            .string => types.t_byte,
            .list => |elem| switch (elem.tag()) {
                .byte, .int, .int32, .float, .boolean => elem.*,
                else => null,
            },
            else => null,
        };
        if (element == null) {
            try self.errf(span, "cannot index a value of type {s}", .{
                try self.typeName(base),
            });
            return types.t_unknown;
        }
        return try self.optionalOf(element.?);
    }

    fn checkStructLit(self: *Checker, span: ast.Span, sl: *const StructLitExpr) CheckError!Type {
        const def = self.structs.get(sl.name) orelse {
            for (sl.fields) |*fi| _ = try self.checkExpr(&fi.value);
            try self.errf(span, "unknown struct type '{s}'", .{sl.name});
            return types.t_unknown;
        };

        for (sl.fields) |*fi| {
            const actual = try self.checkExpr(&fi.value);
            var found = false;
            for (def.fields) |field| {
                if (!std.mem.eql(u8, field.name, fi.name)) continue;
                found = true;
                const want = try self.resolveTypeQuiet(&field.ty);
                if (!accepts(want, actual, &fi.value)) {
                    try self.errf(fi.span, "field '{s}' has type {s}, expected {s}", .{
                        fi.name,
                        try self.typeName(actual),
                        try self.typeName(want),
                    });
                }
                break;
            }
            if (!found) {
                try self.errf(fi.span, "struct '{s}' has no field '{s}'", .{ sl.name, fi.name });
            }
        }
        return .{ .struct_type = def.name };
    }

    fn listOf(self: *Checker, elem: Type) CheckError!Type {
        const p = try self.arena().create(Type);
        p.* = elem;
        return .{ .list = p };
    }

    fn optionalOf(self: *Checker, inner: Type) CheckError!Type {
        const p = try self.arena().create(Type);
        p.* = inner;
        return .{ .optional = p };
    }

    fn resultOf(self: *Checker, ok: Type, err: Type) CheckError!Type {
        const o = try self.arena().create(Type);
        o.* = ok;
        const e = try self.arena().create(Type);
        e.* = err;
        return .{ .result = .{ .ok = o, .err = e } };
    }

    /// The payloads this slice admits (spec B.2): the scalar primitives.
    fn isScalarPayload(t: Type) bool {
        return switch (t) {
            .unknown, .int, .int8, .int16, .int32, .uint, .uint8, .uint16, .uint32, .float, .float32, .boolean, .byte => true,
            else => false,
        };
    }

    // -- scopes -------------------------------------------------------------

    fn pushScope(self: *Checker) void {
        self.depth += 1;
    }

    fn popScope(self: *Checker) void {
        while (self.scopes.items.len > 0 and
            self.scopes.items[self.scopes.items.len - 1].depth >= self.depth)
        {
            _ = self.scopes.pop();
        }
        self.depth -= 1;
    }

    fn lookup(self: *const Checker, name: []const u8) ?Symbol {
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            const e = self.scopes.items[i];
            if (std.mem.eql(u8, e.name, name)) return e.sym;
        }
        return null;
    }

    /// Bind a name in the current scope.
    ///
    /// The same name at the same depth is a duplicate declaration and an error.
    /// The same name at a shallower depth is shadowing, which is allowed with a
    /// warning: Cell's `let` follows Rust, where an inner binding may shadow an
    /// outer one, and rejecting that would break an inner block whenever an
    /// unrelated outer name is introduced. The warning keeps it visible without
    /// failing the build, and keeping the two cases apart is what lets
    /// "duplicate declaration" stay a real error.
    fn declare(self: *Checker, span: ast.Span, name: []const u8, sym: Symbol) CheckError!void {
        var shadows = false;
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            const e = self.scopes.items[i];
            if (!std.mem.eql(u8, e.name, name)) continue;
            if (e.depth == self.depth) {
                try self.duplicate(span, name);
                return;
            }
            shadows = true;
            break;
        }
        if (shadows) {
            const msg = try std.fmt.allocPrint(
                self.arena(),
                "'{s}' shadows an outer binding",
                .{name},
            );
            try self.diagnostics.warning(self.allocator, span, msg);
        }
        try self.scopes.append(self.allocator, .{ .name = name, .depth = self.depth, .sym = sym });
    }

    fn duplicate(self: *Checker, span: ast.Span, name: []const u8) CheckError!void {
        try self.errf(span, "duplicate declaration of '{s}'", .{name});
    }

    // -- types --------------------------------------------------------------

    /// `()` is a return type, not a value. A parameter, field, or `let` of
    /// unit has no runtime representation, and C `void` is not a valid type
    /// for any of those positions.
    fn refuseUnitValue(self: *Checker, span: ast.Span, ty: Type) CheckError!void {
        if (ty.tag() == .unit) {
            try self.errf(span, "() is not a first-class value; only a function return type may be ()", .{});
        }
    }

    /// Lower a syntactic type to a semantic one. A name is a type iff it is a
    /// primitive, a declared struct, a declared enum, or a constructed type
    /// already implemented (`T?`, `Result<T, E>`, `[T]`). Unit is not a name;
    /// it is `()`. Anything else is refused at `span` and becomes `unknown`,
    /// so later uses of the value do not cascade a second diagnostic.
    fn resolveType(self: *Checker, te: *const ast.TypeExpr, span: ast.Span) CheckError!Type {
        return self.resolveTypeInner(te, span, true);
    }

    /// Same lowering as `resolveType`, without a diagnostic. Field types are
    /// already walked in `collectItems`; a use of the field only needs the
    /// semantic type.
    fn resolveTypeQuiet(self: *Checker, te: *const ast.TypeExpr) CheckError!Type {
        return self.resolveTypeInner(te, ast.Span.none, false);
    }

    fn resolveTypeInner(
        self: *Checker,
        te: *const ast.TypeExpr,
        span: ast.Span,
        report: bool,
    ) CheckError!Type {
        return switch (te.*) {
            .name => |n| blk: {
                if (types.fromPrimitiveName(n)) |p| break :blk p;
                if (self.structs.contains(n)) break :blk Type{ .struct_type = n };
                if (self.enums.contains(n)) break :blk Type{ .enum_type = n };
                if (report) try self.errf(span, "unknown type '{s}'", .{n});
                break :blk types.t_unknown;
            },
            .optional => |inner| blk: {
                const p = try self.arena().create(Type);
                p.* = try self.resolveTypeInner(inner, span, report);
                break :blk Type{ .optional = p };
            },
            .list => |inner| blk: {
                const p = try self.arena().create(Type);
                p.* = try self.resolveTypeInner(inner, span, report);
                break :blk Type{ .list = p };
            },
            .result => |r| blk: {
                const ok = try self.arena().create(Type);
                ok.* = try self.resolveTypeInner(r.ok, span, report);
                const e = try self.arena().create(Type);
                e.* = try self.resolveTypeInner(r.err, span, report);
                break :blk Type{ .result = .{ .ok = ok, .err = e } };
            },
            // Ownership is orthogonal to the type: `shared T` is a T.
            .ref => |r| try self.resolveTypeInner(r.inner, span, report),
            .unit => types.t_unit,
        };
    }

    fn typeName(self: *Checker, ty: Type) CheckError![]const u8 {
        return try types.name(self.arena(), ty);
    }

    fn errf(
        self: *Checker,
        span: ast.Span,
        comptime fmt: []const u8,
        args: anytype,
    ) CheckError!void {
        const msg = try std.fmt.allocPrint(self.arena(), fmt, args);
        try self.diagnostics.err(self.allocator, span, msg);
    }

    fn opText(op: ast.BinaryOp) []const u8 {
        return switch (op) {
            .add => "+",
            .sub => "-",
            .mul => "*",
            .div => "/",
            .eq => "==",
            .ne => "!=",
            .lt => "<",
            .le => "<=",
            .gt => ">",
            .ge => ">=",
            .and_op => "&&",
            .or_op => "||",
        };
    }
};

/// `expected` accepts `actual`, with one widening rule: an untyped numeric
/// literal takes the expected width. Cell has no cast operator, so without this
/// no `Byte`, `Int32`, `UInt32`, or `Float32` binding could ever be initialized.
/// The rule applies only where an expected type exists (initializer, argument,
/// assignment, return); a literal inside a larger arithmetic expression still
/// types as `Int` or `Float`.
fn accepts(expected: Type, actual: Type, value: *const ast.Expr) bool {
    if (types.compatible(expected, actual)) return true;
    return literalFits(expected, value);
}

fn isIndexExpr(e: *const ast.Expr) bool {
    var cur = e;
    while (cur.kind == .annotated) cur = cur.kind.annotated.value;
    return cur.kind == .index;
}

fn literalFits(expected: Type, value: *const ast.Expr) bool {
    return switch (value.kind) {
        .int => switch (expected) {
            .int, .int8, .int16, .int32, .uint, .uint8, .uint16, .uint32, .byte => true,
            else => false,
        },
        .float => switch (expected) {
            .float, .float32 => true,
            else => false,
        },
        .unary => |u| u.op == .neg and literalFits(expected, u.operand),
        .annotated => |a| literalFits(expected, a.value),
        // `Some(3)` as `Byte?` (and `Ok(3)` as `Result<Byte, E>`) is the same
        // untyped-literal widening as a bare `3` as `Byte`: the constructor
        // wraps the literal, it does not change its width.
        .wrap => |w| switch (w.ctor) {
            .some => switch (expected) {
                .optional => |inner| if (w.operand) |o| literalFits(inner.*, o) else false,
                else => false,
            },
            .ok => switch (expected) {
                .result => |r| if (w.operand) |o| literalFits(r.ok.*, o) else false,
                else => false,
            },
            .err => switch (expected) {
                .result => |r| if (w.operand) |o| literalFits(r.err.*, o) else false,
                else => false,
            },
            .none => false,
        },
        else => false,
    };
}

pub const TypeError = error{TypeError};
pub const CheckError = error{OutOfMemory};

// -- tests ------------------------------------------------------------------

const lexer = @import("lexer.zig");
const parser = @import("parser.zig");

/// Lex, parse, and check one source buffer.
///
/// The AST arena is separate from the checker's, and the checker itself runs on
/// `std.testing.allocator` so its own allocations are leak-checked. The parser
/// allocates nodes it never frees, which is the module's own lifetime story,
/// so those go to the arena instead of the leak detector.
const TestModule = struct {
    arena_state: std.heap.ArenaAllocator,
    checker: Checker,

    fn init() TestModule {
        return .{
            .arena_state = .init(std.testing.allocator),
            .checker = Checker.init(std.testing.allocator),
        };
    }

    fn deinit(self: *TestModule) void {
        self.checker.deinit();
        self.arena_state.deinit();
    }

    fn check(self: *TestModule, source: []const u8) !void {
        const alloc = self.arena_state.allocator();
        var lex = lexer.Lexer.init(source, "t.cell");
        const tokens = try lex.tokenizeAll(alloc);
        var p = parser.Parser.init(alloc, tokens.items, "t.cell");
        var module = try p.parseModule();
        self.checker.diagnostics.source = source;
        try self.checker.checkModule(&module);
    }

    fn dump(self: *const TestModule) void {
        for (self.checker.diagnostics.list.items) |d| {
            std.debug.print("  {d}:{d}: {s}: {s}\n", .{
                d.span.line,
                d.span.column,
                d.level.text(),
                d.message,
            });
        }
    }

    fn expectDiag(
        self: *const TestModule,
        index: usize,
        level: diag.Level,
        line: u32,
        column: u32,
        message: []const u8,
    ) !void {
        const list = self.checker.diagnostics.list.items;
        if (index >= list.len) {
            std.debug.print("wanted diagnostic {d}, got {d}:\n", .{ index, list.len });
            self.dump();
            return error.TestExpectedDiagnostic;
        }
        const d = list[index];
        std.testing.expectEqualStrings(message, d.message) catch |e| {
            self.dump();
            return e;
        };
        try std.testing.expectEqual(level, d.level);
        try std.testing.expectEqual(line, d.span.line);
        try std.testing.expectEqual(column, d.span.column);
    }

    fn expectCount(self: *const TestModule, n: usize) !void {
        const list = self.checker.diagnostics.list.items;
        if (list.len != n) {
            std.debug.print("wanted {d} diagnostics, got {d}:\n", .{ n, list.len });
            self.dump();
            return error.TestUnexpectedDiagnosticCount;
        }
    }

    fn expectClean(self: *const TestModule) !void {
        try self.expectCount(0);
    }
};

test "Some carries its operand's type and None needs a declared slot" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn f() -> Int? {
        \\    let a: Int? = Some(1)
        \\    let b: Int? = None
        \\    let c = None
        \\    return a
        \\}
    );
    try t.expectCount(1);
    try t.expectDiag(0, .err, 4, 13, "'None' needs a declared optional type here");
}

test "Ok and Err are checked against the declared Result" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub enum IoError { Missing, Denied }
        \\pub fn f() -> Result<Int, IoError> {
        \\    let r: Result<Int, IoError> = Ok(1)
        \\    let e: Result<Int, IoError> = Err(IoError.Denied)
        \\    let bad: Result<Int, Int32> = Err("x")
        \\    let untyped = Ok(1)
        \\    return r
        \\}
    );
    try t.expectCount(2);
    try t.expectDiag(0, .err, 5, 35, "optional/Result payloads other than scalar primitives are not implemented");
    try t.expectDiag(1, .err, 6, 19, "'Ok' needs a declared Result type here");
}

test "scalar payloads only" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn f(owned s: String) -> String? {
        \\    return Some(s)
        \\}
    );
    try t.expectCount(1);
    try t.expectDiag(0, .err, 2, 12, "optional/Result payloads other than scalar primitives are not implemented");
}

test "wrap patterns bind the payload and need the matching scrutinee" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn f(copy o: Int?, copy r: Result<Int, Int32>, copy n: Int) -> Int {
        \\    let a = match o { Some(x) => x, None => 0 }
        \\    let b = match r { Ok(v) => v, Err(code) => 0 }
        \\    let c = match n { Some(x) => x, _ => 0 }
        \\    return a + b + c
        \\}
    );
    try t.expectCount(1);
    try t.expectDiag(0, .err, 4, 23, "pattern 'Some' needs an optional scrutinee, found Int");
}

test "an unresolved name is reported at its own span" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn main() {
        \\    print(1)
        \\}
    );
    try t.expectCount(1);
    try t.expectDiag(0, .err, 2, 5, "unknown identifier 'print'");
    try std.testing.expect(t.checker.diagnostics.hasErrors());
}

test "calling a non-function reports the callee's type at the callee's span" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn main() {
        \\    let copy x = 1
        \\    x(2)
        \\}
    );
    try t.expectCount(1);
    try t.expectDiag(0, .err, 3, 5, "cannot call a value of type Int");
}

test "a call with the wrong number of arguments reports both counts" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn add(copy a: Int, copy b: Int) -> Int {
        \\    return a + b
        \\}
        \\pub fn main() -> Int {
        \\    return add(1)
        \\}
    );
    try t.expectCount(1);
    try t.expectDiag(0, .err, 5, 12, "expected 2 arguments, found 1");
}

test "an argument of the wrong type is reported by position at the argument" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn takes(copy a: Int, copy b: Int) -> Int {
        \\    return a
        \\}
        \\pub fn main() -> Int {
        \\    return takes(1, true)
        \\}
    );
    try t.expectCount(1);
    try t.expectDiag(0, .err, 5, 21, "argument 2 has type Bool, expected Int");
}

test "a returned value that does not match the declared return type is reported" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn f() -> Int {
        \\    return true
        \\}
    );
    try t.expectCount(1);
    try t.expectDiag(0, .err, 2, 12, "return type mismatch: expected Int, found Bool");
}

test "a bare return in a function that declares a return type is reported" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn f() -> Int {
        \\    return
        \\}
    );
    try t.expectCount(1);
    try t.expectDiag(0, .err, 2, 5, "return type mismatch: expected Int, found ()");
}

test "a non-unit function whose body never returns is reported at the function" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn f() -> Int {
        \\    let copy x = 1
        \\}
    );
    try t.expectCount(1);
    try t.expectDiag(0, .err, 1, 1, "missing return in function 'f' declared to return Int");
}

test "an if whose two branches both return counts as returning" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn f(shared c: Bool) -> Int {
        \\    if (c) { return 1 } else { return 2 }
        \\}
    );
    try t.expectClean();
}

test "a bodyless declaration needs no return" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn f(shared s: String) -> Int;
    );
    try t.expectClean();
}

test "a non-Bool if condition is reported at the condition" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn f() {
        \\    if 1 { }
        \\}
    );
    try t.expectCount(1);
    try t.expectDiag(0, .err, 2, 8, "if condition must be Bool, found Int");
}

test "a binary operator over incompatible operands names both types" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn f() -> Bool {
        \\    return 1 == true
        \\}
    );
    try t.expectCount(1);
    try t.expectDiag(0, .err, 2, 12, "operator '==' cannot be applied to Int and Bool");
}

test "arithmetic over non-numeric operands of the same type is still rejected" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn f(shared a: String, shared b: String) -> String {
        \\    return a + b
        \\}
    );
    try t.expectCount(1);
    try t.expectDiag(0, .err, 2, 12, "operator '+' requires numeric operands, found String and String");
}

test "a logical operator over non-Bool operands is rejected" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn f(shared a: Int, shared b: Int) -> Bool {
        \\    return a && b
        \\}
    );
    try t.expectCount(1);
    try t.expectDiag(0, .err, 2, 12, "operator '&&' requires Bool operands, found Int and Int");
}

test "unary ! wants a Bool and unary - wants a number" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn f(shared n: Int, shared s: String) {
        \\    let copy a = !n
        \\    let copy b = -s
        \\}
    );
    try t.expectCount(2);
    try t.expectDiag(0, .err, 2, 18, "operator '!' requires a Bool operand, found Int");
    try t.expectDiag(1, .err, 3, 18, "operator '-' requires a numeric operand, found String");
}

test "an assignment whose value does not match the target is reported" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn f() {
        \\    let mut copy x: Int = 1
        \\    x = true
        \\}
    );
    try t.expectCount(1);
    try t.expectDiag(0, .err, 3, 9, "cannot assign a value of type Bool to a target of type Int");
}

test "assignment of a matching type is typecheck-clean on an immutable binding" {
    // R14 lives in borrowck; a same-type write to `let` is not a type error.
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn f() {
        \\    let copy x: Int = 1
        \\    x = 2
        \\}
    );
    try t.expectCount(0);
}

test "a type mismatch on assignment is reported even when the binding is immutable" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn f() {
        \\    let copy x: Int = 1
        \\    x = true
        \\}
    );
    try t.expectCount(1);
    try t.expectDiag(0, .err, 3, 9, "cannot assign a value of type Bool to a target of type Int");
}

test "an initializer that does not match its annotation is reported" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn f() {
        \\    let copy x: Int = true
        \\}
    );
    try t.expectCount(1);
    try t.expectDiag(0, .err, 2, 23, "cannot initialize a binding of type Int with a value of type Bool");
}

test "reading a field a struct does not have is reported" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub struct Point {
        \\    copy x: Int
        \\}
        \\pub fn f(shared p: Point) -> Int {
        \\    return p.y
        \\}
    );
    try t.expectCount(1);
    try t.expectDiag(0, .err, 5, 12, "struct 'Point' has no field 'y'");
}

test "String and [Byte] index as Byte?" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn f(shared s: String, shared xs: [Byte], copy i: Int) -> Byte? {
        \\    let copy a: Byte? = s[i]
        \\    let copy b: Byte? = xs[0]
        \\    return a
        \\}
    );
    try t.expectClean();
}

test "indexing a list of scalars yields the element's optional" {
    // 2026-09-17: [Int], [Int32], [Float] and [Bool] join [Byte].
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn f(shared xs: [Int]) -> Int? {
        \\    return xs[0]
        \\}
        \\pub fn g(shared xs: [Float]) -> Float? {
        \\    return xs[1]
        \\}
        \\pub fn h(shared xs: [Bool]) -> Bool? {
        \\    return xs[2]
        \\}
        \\pub fn k(shared xs: [Int32]) -> Int32? {
        \\    return xs[3]
        \\}
    );
    try t.expectClean();
}

test "indexing [String] names the base type" {
    // What an indexed owning element would own is an open design question.
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn f(shared xs: [String]) -> Byte? {
        \\    return xs[0]
        \\}
    );
    try t.expectCount(1);
    try t.expectDiag(0, .err, 2, 12, "cannot index a value of type [String]");
}

test "indexing a struct names the base type" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub struct Point { copy x: Int }
        \\pub fn f(shared p: Point) -> Byte? {
        \\    return p[0]
        \\}
    );
    try t.expectCount(1);
    try t.expectDiag(0, .err, 3, 12, "cannot index a value of type Point");
}

test "an index that is not Int is refused rather than truncated" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn f(shared s: String, copy i: UInt32) -> Byte? {
        \\    return s[i]
        \\}
    );
    try t.expectCount(1);
    try t.expectDiag(0, .err, 2, 14, "index must be Int, found UInt32");
}

test "indexed assignment is not implemented" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn f(exclusive xs: [Byte], copy i: Int, copy v: Byte) {
        \\    xs[i] = v
        \\}
    );
    try t.expectCount(1);
    try t.expectDiag(0, .err, 2, 5, "indexed assignment is not implemented");
}

test "a struct literal checks each field's name and type" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub struct Point {
        \\    copy x: Int
        \\}
        \\pub fn f() {
        \\    let owned p = Point { x: true, z: 1 }
        \\}
    );
    try t.expectCount(2);
    try t.expectDiag(0, .err, 5, 27, "field 'x' has type Bool, expected Int");
    try t.expectDiag(1, .err, 5, 36, "struct 'Point' has no field 'z'");
}

test "an empty list literal initializes a typed list field" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub struct Buffer {
        \\    owned data: [Byte]
        \\    copy len: Int
        \\}
        \\pub fn f() {
        \\    let owned b = Buffer { data: [], len: 0 }
        \\}
    );
    try t.expectClean();
}

test "a list literal whose elements disagree is reported at the odd element" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn f() {
        \\    let owned xs = [1, 2, true]
        \\}
    );
    try t.expectCount(1);
    try t.expectDiag(0, .err, 2, 27, "list element has type Bool, expected Int");
}

test "a name declared twice in one scope is a duplicate declaration" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn f() {
        \\    let copy x = 1
        \\    let copy x = 2
        \\}
    );
    try t.expectCount(1);
    try t.expectDiag(0, .err, 3, 5, "duplicate declaration of 'x'");
}

test "two items with the same name are a duplicate declaration" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn f() {
        \\}
        \\pub fn f() {
        \\}
    );
    try t.expectCount(1);
    try t.expectDiag(0, .err, 3, 1, "duplicate declaration of 'f'");
}

test "a binding that shadows an outer one warns rather than failing" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn f(copy x: Int) -> Int {
        \\    if true { let copy x = 2 }
        \\    return x
        \\}
    );
    try t.expectCount(1);
    try t.expectDiag(0, .warning, 2, 15, "'x' shadows an outer binding");
    try std.testing.expect(!t.checker.diagnostics.hasErrors());
}

test "a parameter is not visible inside the next function" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn a(copy x: Int) -> Int {
        \\    return x
        \\}
        \\pub fn b() -> Int {
        \\    return x
        \\}
    );
    try t.expectCount(1);
    try t.expectDiag(0, .err, 5, 12, "unknown identifier 'x'");
}

test "a binding declared in a block is not visible after it" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn f() {
        \\    if true { let copy inner = 1 }
        \\    let copy outer = inner
        \\}
    );
    try t.expectCount(1);
    try t.expectDiag(0, .err, 3, 22, "unknown identifier 'inner'");
}

test "a block types as its tail expression, so it can initialize a typed binding" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn mk() -> String;
        \\pub fn f() {
        \\    let owned x: String = { mk() }
        \\    let owned y: String = { let owned inner = mk()
        \\        inner }
        \\}
    );
    try t.expectClean();
}

test "a block whose tail does not match the annotation is reported, not typed as unit" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn mk() -> String;
        \\pub fn f() {
        \\    let copy x: Int = { mk() }
        \\}
    );
    try t.expectCount(1);
    try t.expectDiag(0, .err, 3, 23, "cannot initialize a binding of type Int with a value of type String");
}

test "a block whose last statement is not an expression is unit" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn f() {
        \\    let copy x: Int = { let copy y = 1 }
        \\}
    );
    try t.expectCount(1);
    try t.expectDiag(0, .err, 2, 23, "cannot initialize a binding of type Int with a value of type ()");
}

test "an if whose branches disagree is reported at the else branch" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn f(copy c: Bool) {
        \\    let copy x: Int = if c { 1 } else { "s" }
        \\}
    );
    try t.expectCount(1);
    try t.expectDiag(0, .err, 2, 39, "if branches have types Int and String");
}

test "a function may call one declared later in the file" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn a() -> Int {
        \\    return b()
        \\}
        \\pub fn b() -> Int {
        \\    return 1
        \\}
    );
    try t.expectClean();
}

test "a function may take a struct declared later in the file" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn area(shared p: Point) -> Int {
        \\    return p.x
        \\}
        \\pub struct Point {
        \\    copy x: Int
        \\}
    );
    try t.expectClean();
}

test "an unknown enum variant is reported and the enum type survives" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub enum Color {
        \\    Red,
        \\    Green,
        \\}
        \\pub fn f() {
        \\    let copy c = Color.Purple
        \\}
    );
    try t.expectCount(1);
    try t.expectDiag(0, .err, 6, 18, "enum 'Color' has no variant 'Purple'");
}

test "a known enum variant types as its enum" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub enum Color {
        \\    Red,
        \\}
        \\pub fn pick() -> Color {
        \\    return Color.Red
        \\}
    );
    try t.expectClean();
}

test "Int and Int64 are the same type, and Float32 is not Float" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn takes64(copy v: Int64) -> Int64 {
        \\    return v
        \\}
        \\pub fn f(copy n: Int) -> Int {
        \\    return takes64(n)
        \\}
        \\pub fn g(copy a: Float32, copy b: Float64) -> Float {
        \\    return a + b
        \\}
    );
    try t.expectCount(1);
    try t.expectDiag(0, .err, 8, 12, "operator '+' cannot be applied to Float32 and Float");
}

test "a borrow has the type of the place it borrows" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn takes(shared a: Int) -> Int {
        \\    return a
        \\}
        \\pub fn f() -> Int {
        \\    let copy x = 1
        \\    return takes(&x)
        \\}
    );
    try t.expectClean();
}

test "an untyped integer literal takes the width it is assigned to" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn f() {
        \\    let copy b: Byte = 7
        \\    let copy small: Int32 = -3
        \\    let copy f32: Float32 = 1.5
        \\    let copy i8: Int8 = -1
        \\    let copy u32: UInt32 = 7
        \\}
    );
    try t.expectClean();
}

test "UInt32 typechecks and UInt8 is not Byte" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn take_u32(copy v: UInt32) -> UInt32 {
        \\    return v
        \\}
        \\pub fn take_u8(copy v: UInt8) -> UInt8 {
        \\    return v
        \\}
        \\pub fn take_byte(copy v: Byte) -> Byte {
        \\    return v
        \\}
        \\pub fn mix(copy a: UInt8) -> Byte {
        \\    return a
        \\}
    );
    try t.expectCount(1);
    try t.expectDiag(0, .err, 11, 12, "return type mismatch: expected Byte, found UInt8");
}

test "one unresolved name does not cascade into its uses" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn f() -> Int {
        \\    return missing + 1
        \\}
    );
    try t.expectCount(1);
    try t.expectDiag(0, .err, 2, 12, "unknown identifier 'missing'");
}

test "a compound argument expression is type checked, not skipped" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn takes(copy a: Int) -> Int {
        \\    return a
        \\}
        \\pub fn f(copy x: Float, copy y: Float) -> Int {
        \\    return takes(x + y)
        \\}
    );
    try t.expectCount(1);
    try t.expectDiag(0, .err, 5, 18, "argument 1 has type Float, expected Int");
}

test "a list literal argument is type checked against the parameter" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn takes(shared xs: [Byte]) -> Int;
        \\pub fn f() -> Int {
        \\    return takes([true])
        \\}
    );
    try t.expectCount(1);
    try t.expectDiag(0, .err, 3, 18, "argument 1 has type [Bool], expected [Byte]");
}

test "-> () is the same unit as an omitted arrow" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn nothing() -> () {
        \\    return
        \\}
        \\pub fn also() {
        \\    return
        \\}
        \\pub fn declared() -> ();
    );
    try t.expectClean();
}

test "a let of () is refused" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn nothing() -> () {
        \\    return
        \\}
        \\pub fn f() {
        \\    let copy u: () = nothing()
        \\}
        \\pub fn g() {
        \\    let copy v = nothing()
        \\}
        \\pub fn takes(copy u: ());
    );
    try t.expectCount(3);
    try t.expectDiag(0, .err, 10, 1, "() is not a first-class value; only a function return type may be ()");
    try t.expectDiag(1, .err, 5, 5, "() is not a first-class value; only a function return type may be ()");
    try t.expectDiag(2, .err, 8, 5, "() is not a first-class value; only a function return type may be ()");
}

test "unknown type names are still refused" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn ok() -> () {
        \\    return
        \\}
        \\pub fn misspelled(shared s: Strng) -> ();
        \\pub fn no_such_width(shared v: Int128) -> Int;
    );
    try t.expectCount(2);
    try t.expectDiag(0, .err, 4, 1, "unknown type 'Strng'");
    try t.expectDiag(1, .err, 5, 1, "unknown type 'Int128'");
}

test "unknown type names are refused and a declared struct name is accepted" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn misspelled(shared s: Strng) -> Int;
        \\pub fn no_such_width(shared v: Int128) -> Int;
        \\pub fn entirely_invented(shared v: Widget) -> Int;
        \\pub struct Point {
        \\    copy x: Int
        \\}
        \\pub fn takes_point(shared p: Point) -> Int;
        \\pub fn takes_enum(copy c: Color) -> Int;
        \\pub enum Color { Red }
    );
    try t.expectCount(3);
    try t.expectDiag(0, .err, 1, 1, "unknown type 'Strng'");
    try t.expectDiag(1, .err, 2, 1, "unknown type 'Int128'");
    try t.expectDiag(2, .err, 3, 1, "unknown type 'Widget'");
    try std.testing.expect(t.checker.diagnostics.hasErrors());
}

test "an unknown name is refused inside T?, Result, a list, and a let" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub fn opt(copy v: Strng?) -> Int;
        \\pub fn res(copy v: Result<Int128, Int>) -> Int;
        \\pub fn list(shared v: [Widget]) -> Int;
        \\pub fn local() {
        \\    let copy x: Missing = 1
        \\}
    );
    try t.expectCount(4);
    try t.expectDiag(0, .err, 1, 1, "unknown type 'Strng'");
    try t.expectDiag(1, .err, 2, 1, "unknown type 'Int128'");
    try t.expectDiag(2, .err, 3, 1, "unknown type 'Widget'");
    try t.expectDiag(3, .err, 5, 5, "unknown type 'Missing'");
}

test "an unknown field type is refused even when the field is unused" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub struct Box {
        \\    copy x: Widget
        \\}
        \\pub fn f() {}
    );
    try t.expectCount(1);
    try t.expectDiag(0, .err, 1, 1, "unknown type 'Widget'");
}

test "a struct field may name a struct declared later in the file" {
    var t: TestModule = .init();
    defer t.deinit();
    try t.check(
        \\pub struct A {
        \\    copy b: B
        \\}
        \\pub struct B {
        \\    copy x: Int
        \\}
        \\pub fn f(shared a: A) -> Int {
        \\    return a.b.x
        \\}
    );
    try t.expectClean();
}
