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

        // Signatures are resolved only after every named type is registered, so
        // a function may take a struct declared below it.
        for (items) |*item| {
            switch (item.kind) {
                .fn_def => |f| {
                    const params = try self.arena().alloc(Type, f.params.len);
                    for (f.params, 0..) |p, i| params[i] = try self.resolveType(&p.ty);
                    const ret = try self.arena().create(Type);
                    ret.* = if (f.return_type) |rt| try self.resolveType(&rt) else types.t_unit;
                    try self.declare(item.span, f.name, .{
                        .ownership = .copy,
                        .mutable = false,
                        .ty = .{ .func = .{ .params = params, .ret = ret } },
                    });
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
        self.fn_return = if (f.return_type) |rt| try self.resolveType(&rt) else types.t_unit;

        self.pushScope();
        defer self.popScope();

        // Parameters share the function scope with the body's own bindings, so
        // a `let` reusing a parameter name is a duplicate rather than a shadow.
        // A signature and its body are one lexical region here.
        for (f.params) |p| {
            try self.declare(span, p.name, .{
                .ownership = p.ownership,
                .mutable = p.ownership == .exclusive or p.ownership == .owned,
                .ty = try self.resolveType(&p.ty),
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
                const annotated: ?Type = if (l.ty) |t| try self.resolveType(&t) else null;
                var bound: Type = annotated orelse types.t_unknown;
                if (l.value) |*v| {
                    const actual = try self.checkExpr(v);
                    if (annotated) |want| {
                        if (!accepts(want, actual, v)) {
                            try self.errf(
                                v.span,
                                "cannot initialize a binding of type {s} with a value of type {s}",
                                .{ try self.typeName(want), try self.typeName(actual) },
                            );
                        }
                    } else {
                        bound = actual;
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
                for (stmts) |*s| try self.checkStmt(s);
                // A block has no trailing expression in this grammar, so its
                // value is always unit.
                return types.t_unit;
            },

            .if_expr => |*i| {
                const cond = try self.checkExpr(i.cond);
                if (!cond.isUnknown() and cond.tag() != .boolean) {
                    try self.errf(i.cond.span, "if condition must be Bool, found {s}", .{
                        try self.typeName(cond),
                    });
                }
                _ = try self.checkExpr(i.then_body);
                if (i.else_body) |e| _ = try self.checkExpr(e);
                // Both branches are blocks, so both are unit.
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
                        else => {},
                    }
                    if (arm.guard) |g| {
                        // A guard on a BINDING pattern would have to reference
                        // a name the arm body declares, and the C backend
                        // declares that name inside the arm rather than before
                        // the if-chain, so the guard could not see it. Rejected
                        // explicitly rather than emitted wrongly.
                        if (arm.pattern.kind == .binding) {
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
            if (std.mem.eql(u8, field.name, f.name)) return try self.resolveType(&field.ty);
        }
        try self.errf(span, "struct '{s}' has no field '{s}'", .{ struct_name, f.name });
        return types.t_unknown;
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
                const want = try self.resolveType(&field.ty);
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

    /// Lower a syntactic type to a semantic one. An unrecognized name becomes
    /// `unknown` with no diagnostic: reporting it would be a new check on a
    /// grammar where `codegen.mapPrimitive` already accepts any name and maps
    /// it to `void*`, and every use of such a value would then error twice.
    fn resolveType(self: *Checker, te: *const ast.TypeExpr) CheckError!Type {
        return switch (te.*) {
            .name => |n| blk: {
                if (types.fromPrimitiveName(n)) |p| break :blk p;
                if (self.structs.contains(n)) break :blk Type{ .struct_type = n };
                if (self.enums.contains(n)) break :blk Type{ .enum_type = n };
                break :blk types.t_unknown;
            },
            .optional => |inner| blk: {
                const p = try self.arena().create(Type);
                p.* = try self.resolveType(inner);
                break :blk Type{ .optional = p };
            },
            .list => |inner| blk: {
                const p = try self.arena().create(Type);
                p.* = try self.resolveType(inner);
                break :blk Type{ .list = p };
            },
            .result => |r| blk: {
                const ok = try self.arena().create(Type);
                ok.* = try self.resolveType(r.ok);
                const e = try self.arena().create(Type);
                e.* = try self.resolveType(r.err);
                break :blk Type{ .result = .{ .ok = ok, .err = e } };
            },
            // Ownership is orthogonal to the type: `shared T` is a T.
            .ref => |r| try self.resolveType(r.inner),
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
/// no `Byte`, `Int32`, `UInt`, or `Float32` binding could ever be initialized.
/// The rule applies only where an expected type exists (initializer, argument,
/// assignment, return); a literal inside a larger arithmetic expression still
/// types as `Int` or `Float`.
fn accepts(expected: Type, actual: Type, value: *const ast.Expr) bool {
    if (types.compatible(expected, actual)) return true;
    return literalFits(expected, value);
}

fn literalFits(expected: Type, value: *const ast.Expr) bool {
    return switch (value.kind) {
        .int => switch (expected) {
            .int, .int32, .uint, .byte => true,
            else => false,
        },
        .float => switch (expected) {
            .float, .float32 => true,
            else => false,
        },
        .unary => |u| u.op == .neg and literalFits(expected, u.operand),
        .annotated => |a| literalFits(expected, a.value),
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
        \\}
    );
    try t.expectClean();
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
