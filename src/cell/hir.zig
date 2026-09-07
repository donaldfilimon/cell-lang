//! A typed, slot-resolved intermediate representation between `check` and the
//! backends.
//!
//! WHY THIS EXISTS. `codegen.zig` walks the AST and writes C text in one pass,
//! so every fact a backend needs -- the type of an expression, which binding a
//! name refers to, the ownership mode a call argument is passed in -- is
//! recomputed inline and thrown away. That is affordable for exactly one
//! backend. It is not affordable for three, and re-deriving it in each is how
//! two backends drift apart on the same program.
//!
//! WHAT LOWERING ASSUMES. Normally `lower` runs on a module that has already
//! passed `root.check`, so it *computes* types instead of *checking* them and
//! carries no diagnostic paths for programs the checker already rejects.
//!
//! But lowering is deliberately TOTAL and TOLERANT, not merely unchecked. It
//! must accept every program `codegen.zig` accepts, including ones the checker
//! would reject, because 27 of codegen's tests never run the checker at all and
//! several of them call `print` or `assert` with no declaration in the source.
//! A lowering that refused those could never be differential-tested against the
//! emitter it is meant to replace. So an unresolved name becomes an
//! `unresolved_ref` typed `unknown` rather than an error, matching what the C
//! emitter already does with it, and `cannot lower` is reserved for the one
//! case that is genuinely unrepresentable rather than merely unresolved.
//!
//! WHAT IT DELIBERATELY DOES NOT DO.
//!
//! Ownership is not part of a type here, matching the invariant `types.zig`
//! states at its head: a `shared Int` parameter and an `Int` local hold the
//! same `Ty` and differ only in how they may be used. Ownership rides on
//! `Param`, `Local` and `Field`, which is where the AST puts it and where
//! `borrowck.zig` reads it. Folding it into `Ty` would make `compatible`
//! wrong and would make every backend re-split it.
//!
//! Names are resolved to slots, but slots are NOT SSA. There is no dominance
//! property here and no phi. A backend that wants SSA builds it; the LLVM
//! backend uses stack slots and lets `opt` promote them, which is the standard
//! frontend approach and keeps this IR readable.
//!
//! A NOTE ON THE REFERENCE IMPLEMENTATION. The CELL v2.0 tree in
//! `~/Downloads/cell-lang 2` has an `src/hir.zig` solving the same problem for
//! a different language. Its `Expr` has 14 tags and its `Stmt` has 8, with no
//! representation for enums, strings, slices, or pattern matching, and it
//! carries `while`, which this language does not have. None of it was copied;
//! the ideas taken are slot binding, carrying an explicit ABI/ownership mode on
//! calls, and emitting a `cannot lower` diagnostic instead of a placeholder.

const std = @import("std");
const Io = std.Io;
const ast = @import("ast.zig");
const types = @import("types.zig");
const diag = @import("diag.zig");

pub const Ty = types.Type;
pub const Ownership = ast.Ownership;
pub const Span = ast.Span;

pub const LowerError = error{OutOfMemory};

// ---------------------------------------------------------------------------
// Module structure
// ---------------------------------------------------------------------------

pub const Field = struct {
    name: []const u8,
    ty: Ty,
    ownership: Ownership,
};

pub const Struct = struct {
    name: []const u8,
    fields: []Field,
    is_public: bool,
};

pub const Enum = struct {
    name: []const u8,
    /// Variant i has the value i. `codegen.zig` emits an `int32_t` typedef
    /// plus constants rather than a C `enum`, so the values are fixed by
    /// declaration order and this IR records that rather than re-deriving it.
    variants: [][]const u8,
    is_public: bool,
};

/// A binding, whether it came from a parameter or a `let`.
///
/// Parameters and locals share one slot space per function. A backend that
/// wants them separate can filter on `is_param`; keeping one space means a
/// `Ref` is a single index and shadowing is just a later slot with the same
/// name, resolved at lowering time and never at emit time.
pub const Binding = struct {
    name: []const u8,
    ty: Ty,
    ownership: Ownership,
    mutable: bool,
    is_param: bool,
    slot: u32,
};

pub const Fn = struct {
    name: []const u8,
    /// The mangled C ABI symbol. Computed once here so every backend agrees;
    /// `codegen.zig` derives the same string with its own `symbolFor`.
    symbol: []const u8,
    /// Slots `0..param_count` are the parameters, in declaration order.
    param_count: u32,
    bindings: []Binding,
    ret: Ty,
    /// Null for a bodyless declaration, which is the C-ABI-first form: it
    /// emits a prototype and no definition.
    body: ?[]Stmt,
    is_public: bool,
    span: Span,

    pub fn params(self: *const Fn) []Binding {
        return self.bindings[0..self.param_count];
    }
};

pub const Module = struct {
    path: []const u8,
    structs: []Struct,
    enums: []Enum,
    fns: []Fn,

    pub fn findStruct(self: *const Module, name: []const u8) ?*const Struct {
        for (self.structs) |*s| {
            if (std.mem.eql(u8, s.name, name)) return s;
        }
        return null;
    }

    pub fn findEnum(self: *const Module, name: []const u8) ?*const Enum {
        for (self.enums) |*e| {
            if (std.mem.eql(u8, e.name, name)) return e;
        }
        return null;
    }

    pub fn findFn(self: *const Module, name: []const u8) ?*const Fn {
        for (self.fns) |*f| {
            if (std.mem.eql(u8, f.name, name)) return f;
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// Expressions
// ---------------------------------------------------------------------------

/// A selected field: the struct it belongs to and the index within it.
/// Resolving the index here means no backend re-looks-up a field by name.
pub const FieldSel = struct {
    struct_name: []const u8,
    index: u32,
    ty: Ty,
};

/// How a value reaches a callee. Recorded per argument because the call site
/// may write its own ownership prefix (`take(shared buf)`), which R15 requires
/// to agree with the parameter, and because a backend lowering `exclusive`
/// aggregates takes an address while `owned` does not.
pub const ArgMode = struct {
    /// The callee parameter's declared mode, which is what governs lowering.
    param: Ownership,
    /// The mode written at the call site, when one was written. R15 has
    /// already established that this equals `param` if present.
    written: ?Ownership,
};

pub const Arm = struct {
    pattern: Pattern,
    body: *Expr,
    span: Span,
};

pub const Pattern = struct {
    kind: Kind,
    span: Span,

    pub const Kind = union(enum) {
        wildcard,
        /// Binds the scrutinee to a slot.
        binding: u32,
        /// Resolved to the enum's declaration order value.
        enum_variant: struct { enum_name: []const u8, variant: []const u8, value: i64 },
        int: i64,
        float: f64,
        string: []const u8,
        bool: bool,
    };
};

pub const Expr = struct {
    /// Every expression carries its resolved type. This is the property that
    /// makes the IR worth having.
    ty: Ty,
    span: Span,
    kind: Kind,

    pub const Kind = union(enum) {
        int_const: i64,
        float_const: f64,
        bool_const: bool,
        string_const: []const u8,
        /// Read of a parameter or local, by slot.
        ref: u32,
        /// A name that resolves to no binding and no enum variant.
        ///
        /// This is NOT an error here, and that is deliberate. `codegen.zig`
        /// accepts undeclared names today and emits the bare identifier, and
        /// 27 of its tests never run the checker at all -- several of them
        /// call `print` and `assert` with no declaration in the source. A
        /// lowering that refused those could never be differential-tested
        /// against the emitter it is meant to replace. Unresolved stays
        /// unresolved, typed `unknown`, and the backends decide.
        unresolved_ref: []const u8,
        /// A qualified or bare enum variant in value position.
        enum_const: struct { enum_name: []const u8, variant: []const u8, value: i64 },
        binary: struct { op: ast.BinaryOp, left: *Expr, right: *Expr },
        unary: struct { op: ast.UnaryOp, operand: *Expr },
        call: struct {
            /// Null when the callee is a computed expression rather than a
            /// name. `codegen.zig` has the same case and emits the expression.
            symbol: ?[]const u8,
            callee: *Expr,
            args: []Expr,
            modes: []ArgMode,
        },
        field: struct { base: *Expr, sel: FieldSel },
        struct_lit: struct { name: []const u8, fields: []Expr },
        list_lit: []Expr,
        /// A block in expression position. `tail` is its value, null when the
        /// block yields unit.
        block: struct { stmts: []Stmt, tail: ?*Expr },
        if_expr: struct { cond: *Expr, then_body: *Expr, else_body: ?*Expr },
        match_expr: struct { scrutinee: *Expr, arms: []Arm },
    };
};

// ---------------------------------------------------------------------------
// Statements
// ---------------------------------------------------------------------------

/// An assignable location: a binding plus zero or more field selections.
/// Flattened at lowering time so a backend never walks a field chain.
pub const Place = struct {
    slot: u32,
    path: []FieldSel,
    ty: Ty,
};

pub const Stmt = struct {
    span: Span,
    kind: Kind,

    pub const Kind = union(enum) {
        /// Slot initialization. `value` is null for a declaration with no
        /// initializer.
        let: struct { slot: u32, value: ?Expr },
        assign: struct { place: Place, value: Expr },
        expr: Expr,
        ret: ?Expr,
        /// `while cond { ... }`. A statement, not an expression: a loop
        /// produces no value.
        while_loop: struct { cond: Expr, body: []Stmt },
        brk,
        cont,
    };
};

// ---------------------------------------------------------------------------
// Lowering
// ---------------------------------------------------------------------------

/// Lower a checked module into HIR.
///
/// `allocator` should be an arena: every node here is allocated from it and
/// nothing is freed individually, matching how `parser.zig` builds the AST.
/// Diagnostics land in `diagnostics`; the only returned error is allocation
/// failure. A module that produced any diagnostic here is not safe to emit.
pub fn lower(
    allocator: std.mem.Allocator,
    module: *const ast.Module,
    diagnostics: *diag.Bag,
) LowerError!Module {
    var l: Lowerer = .{
        .arena = allocator,
        .diagnostics = diagnostics,
        .module = module,
    };
    return l.run();
}

const Lowerer = struct {
    arena: std.mem.Allocator,
    diagnostics: *diag.Bag,
    module: *const ast.Module,

    structs: std.ArrayList(Struct) = .empty,
    enums: std.ArrayList(Enum) = .empty,
    fns: std.ArrayList(Fn) = .empty,

    /// Signatures of every function in the module, for typing calls.
    sigs: std.ArrayList(Sig) = .empty,

    /// Per-function binding table. Index is the slot.
    bindings: std.ArrayList(Binding) = .empty,
    /// Names visible right now, innermost last. A flat stack searched
    /// backward, the same shape `typecheck.zig` uses, so shadowing resolves
    /// identically in both.
    scope: std.ArrayList(ScopeEntry) = .empty,

    depth: u32 = 0,

    const ScopeEntry = struct { name: []const u8, slot: u32, depth: u32 };
    const Sig = struct { name: []const u8, symbol: []const u8, params: []ast.Param, ret: Ty };

    fn run(self: *Lowerer) LowerError!Module {
        // Pass one: named types and signatures, so order of declaration in the
        // file does not matter to a call or a struct literal.
        for (self.module.items) |item| {
            switch (item.kind) {
                .struct_def => |s| {
                    var fields = try self.arena.alloc(Field, s.fields.len);
                    for (s.fields, 0..) |f, i| {
                        fields[i] = .{
                            .name = f.name,
                            .ty = self.resolve(&f.ty),
                            .ownership = f.ownership,
                        };
                    }
                    try self.structs.append(self.arena, .{
                        .name = s.name,
                        .fields = fields,
                        .is_public = s.is_public,
                    });
                },
                .enum_def => |e| try self.enums.append(self.arena, .{
                    .name = e.name,
                    .variants = e.variants,
                    .is_public = e.is_public,
                }),
                .fn_def => |f| try self.sigs.append(self.arena, .{
                    .name = f.name,
                    .symbol = try self.symbolFor(f),
                    .params = f.params,
                    .ret = if (f.return_type) |*rt| self.resolve(rt) else types.t_unit,
                }),
                .use_decl => {},
            }
        }

        for (self.module.items) |item| {
            switch (item.kind) {
                .fn_def => |f| try self.lowerFn(item.span, f),
                else => {},
            }
        }

        return .{
            .path = self.module.path,
            .structs = self.structs.items,
            .enums = self.enums.items,
            .fns = self.fns.items,
        };
    }

    fn lowerFn(self: *Lowerer, span: Span, f: ast.FnDef) LowerError!void {
        self.bindings.clearRetainingCapacity();
        self.scope.clearRetainingCapacity();
        self.depth = 1;

        for (f.params) |p| {
            const slot: u32 = @intCast(self.bindings.items.len);
            try self.bindings.append(self.arena, .{
                .name = p.name,
                .ty = self.resolve(&p.ty),
                .ownership = p.ownership,
                // A parameter is writable exactly when it owns or exclusively
                // borrows its value; `borrowck.zig` states the same rule.
                .mutable = p.ownership == .owned or p.ownership == .exclusive,
                .is_param = true,
                .slot = slot,
            });
            try self.scope.append(self.arena, .{ .name = p.name, .slot = slot, .depth = self.depth });
        }
        const param_count: u32 = @intCast(self.bindings.items.len);
        const ret = if (f.return_type) |*rt| self.resolve(rt) else types.t_unit;

        var body: ?[]Stmt = null;
        if (f.body) |stmts| {
            body = try self.lowerStmts(stmts);
        }

        try self.fns.append(self.arena, .{
            .name = f.name,
            .symbol = try self.symbolFor(f),
            .param_count = param_count,
            .bindings = try self.arena.dupe(Binding, self.bindings.items),
            .ret = ret,
            .body = body,
            .is_public = f.is_public,
            .span = span,
        });
    }

    /// The C ABI symbol for a function. Mirrors `codegen.symbolFor`: a
    /// BODYLESS declaration of a runtime intrinsic takes the runtime's own
    /// spelling, and a function with a body is never renamed, because that
    /// would define over a runtime symbol. Only `assert` needs this, and only
    /// at arity 2, because C has no overloading and the message-carrying form
    /// is a separate symbol. Getting this wrong is a link error, not a
    /// compile error, so the two must agree.
    fn symbolFor(self: *Lowerer, f: ast.FnDef) LowerError![]const u8 {
        if (f.body == null and std.mem.eql(u8, f.name, "assert") and f.params.len == 2) {
            return "cell_assert_msg";
        }
        return std.fmt.allocPrint(self.arena, "cell_{s}", .{f.name});
    }

    fn lowerStmts(self: *Lowerer, stmts: []const ast.Stmt) LowerError![]Stmt {
        var out = try self.arena.alloc(Stmt, stmts.len);
        for (stmts, 0..) |s, i| {
            out[i] = try self.lowerStmt(&s);
        }
        return out;
    }

    fn lowerStmt(self: *Lowerer, stmt: *const ast.Stmt) LowerError!Stmt {
        switch (stmt.kind) {
            .let => |l| {
                // The initializer is lowered BEFORE the binding enters scope,
                // so `let x = x` reads the outer `x`. That matches
                // typecheck.zig, which declares after checking the value.
                var value: ?Expr = null;
                if (l.value) |v| value = try self.lowerExpr(&v);

                const declared: ?Ty = if (l.ty) |*t| self.resolve(t) else null;
                const ty = declared orelse if (value) |v| v.ty else types.t_unknown;

                const slot: u32 = @intCast(self.bindings.items.len);
                try self.bindings.append(self.arena, .{
                    .name = l.name,
                    .ty = ty,
                    .ownership = l.ownership,
                    .mutable = l.mutable,
                    .is_param = false,
                    .slot = slot,
                });
                try self.scope.append(self.arena, .{ .name = l.name, .slot = slot, .depth = self.depth });

                return .{ .span = stmt.span, .kind = .{ .let = .{ .slot = slot, .value = value } } };
            },
            .assign => |a| {
                const value = try self.lowerExpr(&a.value);
                const place = try self.lowerPlace(&a.target);
                return .{ .span = stmt.span, .kind = .{ .assign = .{ .place = place, .value = value } } };
            },
            .expr => |e| return .{ .span = stmt.span, .kind = .{ .expr = try self.lowerExpr(&e) } },
            .while_stmt => |w| {
                const cond = try self.lowerExpr(&w.cond);
                self.pushScope();
                const body = try self.lowerStmts(w.body);
                self.popScope();
                return .{ .span = stmt.span, .kind = .{ .while_loop = .{ .cond = cond, .body = body } } };
            },
            .break_stmt => return .{ .span = stmt.span, .kind = .brk },
            .continue_stmt => return .{ .span = stmt.span, .kind = .cont },
            .return_stmt => |maybe| {
                if (maybe) |e| {
                    return .{ .span = stmt.span, .kind = .{ .ret = try self.lowerExpr(&e) } };
                }
                return .{ .span = stmt.span, .kind = .{ .ret = null } };
            },
        }
    }

    /// Flatten an assignment target into a slot plus a field path.
    fn lowerPlace(self: *Lowerer, target: *const ast.Expr) LowerError!Place {
        var path: std.ArrayList(FieldSel) = .empty;
        var cursor = target;
        // Walk down to the root, collecting selections, then reverse.
        while (true) {
            switch (cursor.kind) {
                .field => |fe| {
                    cursor = fe.base;
                },
                .annotated => |an| cursor = an.value,
                else => break,
            }
        }
        const root_slot: u32 = blk: {
            if (cursor.kind == .ident) {
                if (self.lookup(cursor.kind.ident)) |slot| break :blk slot;
            }
            // `borrowck.zig` already rejects an assignment whose target is
            // not a place, so anything reaching here has been checked.
            break :blk 0;
        };

        // Second walk, top down, now that the root type is known.
        var ty = if (root_slot < self.bindings.items.len)
            self.bindings.items[root_slot].ty
        else
            types.t_unknown;
        try self.collectPath(target, &path, &ty);

        return .{ .slot = root_slot, .path = path.items, .ty = ty };
    }

    fn collectPath(self: *Lowerer, e: *const ast.Expr, path: *std.ArrayList(FieldSel), ty: *Ty) LowerError!void {
        switch (e.kind) {
            .field => |fe| {
                try self.collectPath(fe.base, path, ty);
                if (self.selectField(ty.*, fe.name)) |sel| {
                    try path.append(self.arena, sel);
                    ty.* = sel.ty;
                } else {
                    ty.* = types.t_unknown;
                }
            },
            .annotated => |an| try self.collectPath(an.value, path, ty),
            else => {},
        }
    }

    fn selectField(self: *Lowerer, base: Ty, name: []const u8) ?FieldSel {
        const struct_name = switch (base) {
            .struct_type => |n| n,
            else => return null,
        };
        for (self.structs.items) |s| {
            if (!std.mem.eql(u8, s.name, struct_name)) continue;
            for (s.fields, 0..) |f, i| {
                if (std.mem.eql(u8, f.name, name)) {
                    return .{ .struct_name = struct_name, .index = @intCast(i), .ty = f.ty };
                }
            }
        }
        return null;
    }

    fn lowerExpr(self: *Lowerer, e: *const ast.Expr) LowerError!Expr {
        switch (e.kind) {
            .int => |v| return self.lit(e.span, types.t_int, .{ .int_const = v }),
            .float => |v| return self.lit(e.span, types.t_float, .{ .float_const = v }),
            .bool => |v| return self.lit(e.span, types.t_bool, .{ .bool_const = v }),
            .string => |v| return self.lit(e.span, types.t_string, .{ .string_const = v }),

            .ident => |name| {
                if (self.lookup(name)) |slot| {
                    return .{ .ty = self.bindings.items[slot].ty, .span = e.span, .kind = .{ .ref = slot } };
                }
                // A bare enum variant in value position, `Red` for `Color.Red`.
                if (self.findVariant(null, name)) |ev| {
                    return .{
                        .ty = .{ .enum_type = ev.enum_name },
                        .span = e.span,
                        .kind = .{ .enum_const = .{ .enum_name = ev.enum_name, .variant = name, .value = ev.value } },
                    };
                }
                // Neither a binding nor a variant. Tolerated, per the note on
                // `unresolved_ref`.
                return self.lit(e.span, types.t_unknown, .{ .unresolved_ref = name });
            },

            .annotated => |an| {
                // The prefix is a checked assertion about a call argument
                // (R15), not a value transformation. It has already been
                // verified, and `modes` on the call carries it forward, so the
                // wrapper does not survive into the IR.
                return self.lowerExpr(an.value);
            },

            .binary => |b| {
                const left = try self.box(try self.lowerExpr(b.left));
                const right = try self.box(try self.lowerExpr(b.right));
                const ty: Ty = switch (b.op) {
                    .eq, .ne, .lt, .le, .gt, .ge, .and_op, .or_op => types.t_bool,
                    // Arithmetic takes the left operand's type. The checker has
                    // already established both sides agree.
                    else => left.ty,
                };
                return .{ .ty = ty, .span = e.span, .kind = .{ .binary = .{ .op = b.op, .left = left, .right = right } } };
            },

            .unary => |u| {
                const operand = try self.box(try self.lowerExpr(u.operand));
                const ty: Ty = switch (u.op) {
                    .not => types.t_bool,
                    // `&x` and `&mut x` do not change the type: ownership is
                    // not part of a type here.
                    .neg, .ref_shared, .ref_exclusive => operand.ty,
                };
                return .{ .ty = ty, .span = e.span, .kind = .{ .unary = .{ .op = u.op, .operand = operand } } };
            },

            .field => |fe| {
                const base = try self.box(try self.lowerExpr(fe.base));
                // A qualified enum variant, `Color.Red`, parses as a field
                // access and is a constant, not a projection.
                if (fe.base.kind == .ident) {
                    if (self.lookup(fe.base.kind.ident) == null) {
                        if (self.findVariant(fe.base.kind.ident, fe.name)) |ev| {
                            return .{
                                .ty = .{ .enum_type = ev.enum_name },
                                .span = e.span,
                                .kind = .{ .enum_const = .{ .enum_name = ev.enum_name, .variant = fe.name, .value = ev.value } },
                            };
                        }
                    }
                }
                if (self.selectField(base.ty, fe.name)) |sel| {
                    return .{ .ty = sel.ty, .span = e.span, .kind = .{ .field = .{ .base = base, .sel = sel } } };
                }
                // An unknown base type (`void*` in C today, per SPEC 0.6)
                // has no fields to resolve. Keep the projection and type it
                // `unknown` rather than refusing the program.
                return .{
                    .ty = types.t_unknown,
                    .span = e.span,
                    .kind = .{ .field = .{
                        .base = base,
                        .sel = .{ .struct_name = "", .index = 0, .ty = types.t_unknown },
                    } },
                };
            },

            .call => |c| return self.lowerCall(e.span, c.callee, c.args),

            .struct_lit => |sl| {
                const decl = self.findStructDecl(sl.name);
                const n = if (decl) |d| d.fields.len else sl.fields.len;
                var fields = try self.arena.alloc(Expr, n);
                // Reorder initializers into declaration order, so a backend
                // emits fields positionally without re-matching names.
                if (decl) |d| {
                    for (d.fields, 0..) |df, i| {
                        var found = false;
                        for (sl.fields) |init_field| {
                            if (std.mem.eql(u8, init_field.name, df.name)) {
                                fields[i] = try self.lowerExpr(&init_field.value);
                                found = true;
                                break;
                            }
                        }
                        if (!found) {
                            // The checker reports a missing initializer. Emit a
                            // zero so lowering stays total; a program that
                            // reaches a backend has already passed `check`.
                            fields[i] = self.lit(e.span, df.ty, .{ .int_const = 0 });
                        }
                    }
                } else {
                    for (sl.fields, 0..) |init_field, i| {
                        fields[i] = try self.lowerExpr(&init_field.value);
                    }
                }
                return .{
                    .ty = .{ .struct_type = sl.name },
                    .span = e.span,
                    .kind = .{ .struct_lit = .{ .name = sl.name, .fields = fields } },
                };
            },

            .list_lit => |elems| {
                var out = try self.arena.alloc(Expr, elems.len);
                for (elems, 0..) |el, i| out[i] = try self.lowerExpr(&el);
                const elem_ty = try self.arena.create(Ty);
                elem_ty.* = if (out.len > 0) out[0].ty else types.t_unknown;
                return .{ .ty = .{ .list = elem_ty }, .span = e.span, .kind = .{ .list_lit = out } };
            },

            .block => |stmts| {
                self.pushScope();
                defer self.popScope();
                // A trailing expression statement is the block's value.
                var tail: ?*Expr = null;
                var body_len = stmts.len;
                if (stmts.len > 0 and stmts[stmts.len - 1].kind == .expr) {
                    body_len -= 1;
                }
                const lowered = try self.lowerStmts(stmts[0..body_len]);
                if (body_len != stmts.len) {
                    tail = try self.box(try self.lowerExpr(&stmts[stmts.len - 1].kind.expr));
                }
                return .{
                    .ty = if (tail) |t| t.ty else types.t_unit,
                    .span = e.span,
                    .kind = .{ .block = .{ .stmts = lowered, .tail = tail } },
                };
            },

            .if_expr => |ie| {
                const cond = try self.box(try self.lowerExpr(ie.cond));
                const then_body = try self.box(try self.lowerExpr(ie.then_body));
                var else_body: ?*Expr = null;
                if (ie.else_body) |eb| else_body = try self.box(try self.lowerExpr(eb));
                return .{
                    // Without an else there is no value, so the if is unit even
                    // when the then-branch has a type.
                    .ty = if (else_body != null) then_body.ty else types.t_unit,
                    .span = e.span,
                    .kind = .{ .if_expr = .{ .cond = cond, .then_body = then_body, .else_body = else_body } },
                };
            },

            .match_expr => |me| {
                const scrutinee = try self.box(try self.lowerExpr(me.scrutinee));
                var arms = try self.arena.alloc(Arm, me.arms.len);
                var result_ty: Ty = types.t_unit;
                for (me.arms, 0..) |arm, i| {
                    self.pushScope();
                    const pat = try self.lowerPattern(&arm.pattern, scrutinee.ty);
                    const body = try self.box(try self.lowerExpr(arm.body));
                    self.popScope();
                    arms[i] = .{ .pattern = pat, .body = body, .span = arm.span };
                    if (i == 0) result_ty = body.ty;
                }
                return .{
                    .ty = result_ty,
                    .span = e.span,
                    .kind = .{ .match_expr = .{ .scrutinee = scrutinee, .arms = arms } },
                };
            },
        }
    }

    fn lowerCall(self: *Lowerer, span: Span, callee: *const ast.Expr, args: []const ast.Expr) LowerError!Expr {
        var symbol: ?[]const u8 = null;
        var sig: ?Sig = null;
        if (callee.kind == .ident) {
            const name = callee.kind.ident;
            if (self.lookup(name) == null) {
                for (self.sigs.items) |s| {
                    if (std.mem.eql(u8, s.name, name)) {
                        sig = s;
                        symbol = s.symbol;
                        break;
                    }
                }
            }
        }

        var lowered_args = try self.arena.alloc(Expr, args.len);
        var modes = try self.arena.alloc(ArgMode, args.len);
        for (args, 0..) |a, i| {
            // The written prefix is read off the AST before lowering strips it.
            const written: ?Ownership = switch (a.kind) {
                .annotated => |an| an.ownership,
                else => null,
            };
            const param_mode: Ownership = blk: {
                if (sig) |s| {
                    if (i < s.params.len) break :blk s.params[i].ownership;
                }
                break :blk written orelse .owned;
            };
            lowered_args[i] = try self.lowerExpr(&a);
            modes[i] = .{ .param = param_mode, .written = written };
        }

        // The callee expression is lowered only when it is not a known
        // function name, since a name has no value in this language.
        const callee_expr = if (symbol != null)
            try self.box(self.lit(callee.span, types.t_unit, .{ .int_const = 0 }))
        else
            try self.box(try self.lowerExpr(callee));

        return .{
            .ty = if (sig) |s| s.ret else types.t_unknown,
            .span = span,
            .kind = .{ .call = .{
                .symbol = symbol,
                .callee = callee_expr,
                .args = lowered_args,
                .modes = modes,
            } },
        };
    }

    fn lowerPattern(self: *Lowerer, p: *const ast.Pattern, scrutinee_ty: Ty) LowerError!Pattern {
        switch (p.kind) {
            .wildcard => return .{ .kind = .wildcard, .span = p.span },
            .int => |v| return .{ .kind = .{ .int = v }, .span = p.span },
            .float => |v| return .{ .kind = .{ .float = v }, .span = p.span },
            .string => |v| return .{ .kind = .{ .string = v }, .span = p.span },
            .bool => |v| return .{ .kind = .{ .bool = v }, .span = p.span },
            .enum_variant => |ev| {
                if (self.findVariant(ev.enum_name, ev.variant)) |found| {
                    return .{
                        .kind = .{ .enum_variant = .{
                            .enum_name = found.enum_name,
                            .variant = ev.variant,
                            .value = found.value,
                        } },
                        .span = p.span,
                    };
                }
                try self.cannotLower(p.span, "pattern names no known enum variant");
                return .{ .kind = .wildcard, .span = p.span };
            },
            .binding => |name| {
                // A pattern binding inherits the scrutinee's ownership
                // (OWNERSHIP.md R7), which is not enforced yet; the slot
                // records `owned` so a backend has a definite mode.
                const slot: u32 = @intCast(self.bindings.items.len);
                try self.bindings.append(self.arena, .{
                    .name = name,
                    .ty = scrutinee_ty,
                    .ownership = .owned,
                    .mutable = false,
                    .is_param = false,
                    .slot = slot,
                });
                try self.scope.append(self.arena, .{ .name = name, .slot = slot, .depth = self.depth });
                return .{ .kind = .{ .binding = slot }, .span = p.span };
            },
        }
    }

    // -- helpers ------------------------------------------------------------

    fn lit(self: *Lowerer, span: Span, ty: Ty, kind: Expr.Kind) Expr {
        _ = self;
        return .{ .ty = ty, .span = span, .kind = kind };
    }

    fn box(self: *Lowerer, e: Expr) LowerError!*Expr {
        const p = try self.arena.create(Expr);
        p.* = e;
        return p;
    }

    fn pushScope(self: *Lowerer) void {
        self.depth += 1;
    }

    fn popScope(self: *Lowerer) void {
        var i = self.scope.items.len;
        while (i > 0 and self.scope.items[i - 1].depth >= self.depth) : (i -= 1) {}
        self.scope.shrinkRetainingCapacity(i);
        self.depth -= 1;
    }

    fn lookup(self: *const Lowerer, name: []const u8) ?u32 {
        var i = self.scope.items.len;
        while (i > 0) : (i -= 1) {
            const entry = self.scope.items[i - 1];
            if (std.mem.eql(u8, entry.name, name)) return entry.slot;
        }
        return null;
    }

    const FoundVariant = struct { enum_name: []const u8, value: i64 };

    fn findVariant(self: *const Lowerer, enum_name: ?[]const u8, variant: []const u8) ?FoundVariant {
        for (self.enums.items) |e| {
            if (enum_name) |want| {
                if (!std.mem.eql(u8, e.name, want)) continue;
            }
            for (e.variants, 0..) |v, i| {
                if (std.mem.eql(u8, v, variant)) {
                    return .{ .enum_name = e.name, .value = @intCast(i) };
                }
            }
        }
        return null;
    }

    fn findStructDecl(self: *const Lowerer, name: []const u8) ?Struct {
        for (self.structs.items) |s| {
            if (std.mem.eql(u8, s.name, name)) return s;
        }
        return null;
    }

    fn resolve(self: *Lowerer, te: *const ast.TypeExpr) Ty {
        switch (te.*) {
            .unit => return types.t_unit,
            .name => |n| {
                if (types.fromPrimitiveName(n)) |t| return t;
                for (self.structs.items) |s| {
                    if (std.mem.eql(u8, s.name, n)) return .{ .struct_type = n };
                }
                for (self.enums.items) |e| {
                    if (std.mem.eql(u8, e.name, n)) return .{ .enum_type = n };
                }
                // Unknown type names are accepted by the checker today and
                // become void* in C; SPEC 0.6 records that. Carrying `unknown`
                // keeps the IR honest about it rather than inventing a type.
                return types.t_unknown;
            },
            // Ownership is not part of a type: `shared T` lowers to `T`, which
            // is what types.zig's header states.
            .ref => |r| return self.resolve(r.inner),
            .optional => |inner| {
                const p = self.arena.create(Ty) catch return types.t_unknown;
                p.* = self.resolve(inner);
                return .{ .optional = p };
            },
            .list => |inner| {
                const p = self.arena.create(Ty) catch return types.t_unknown;
                p.* = self.resolve(inner);
                return .{ .list = p };
            },
            .result => |r| {
                const ok = self.arena.create(Ty) catch return types.t_unknown;
                const err = self.arena.create(Ty) catch return types.t_unknown;
                ok.* = self.resolve(r.ok);
                err.* = self.resolve(r.err);
                return .{ .result = .{ .ok = ok, .err = err } };
            },
        }
    }

    fn cannotLower(self: *Lowerer, span: Span, message: []const u8) LowerError!void {
        try self.diagnostics.err(
            self.arena,
            span,
            try std.fmt.allocPrint(self.arena, "cannot lower: {s}", .{message}),
        );
    }
};
