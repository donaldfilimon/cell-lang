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
const abi = @import("abi.zig");

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

test "function and call retain declared return ownership" {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");

    const source =
        \\pub fn plain() -> String;
        \\pub fn arc_value() -> arc String;
        \\pub fn shared_value() -> shared String;
        \\pub fn exclusive_value() -> exclusive String;
        \\pub fn copy_value() -> copy String;
        \\pub fn defined() -> arc String { return arc_value() }
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var lex = lexer.Lexer.init(source, "t.cell");
    const tokens = try lex.tokenizeAll(allocator);
    var parser_state = parser.Parser.init(allocator, tokens.items, "t.cell");
    var ast_module = try parser_state.parseModule();
    var diagnostics: diag.Bag = .init("t.cell", source);
    defer diagnostics.deinit(allocator);
    const module = try lower(allocator, &ast_module, &diagnostics);

    try std.testing.expectEqual(Ownership.owned, module.findFn("plain").?.ret_ownership);
    try std.testing.expectEqual(Ownership.arc, module.findFn("arc_value").?.ret_ownership);
    try std.testing.expectEqual(Ownership.shared, module.findFn("shared_value").?.ret_ownership);
    try std.testing.expectEqual(Ownership.exclusive, module.findFn("exclusive_value").?.ret_ownership);
    try std.testing.expectEqual(Ownership.copy, module.findFn("copy_value").?.ret_ownership);
    const defined = module.findFn("defined").?;
    try std.testing.expectEqual(Ownership.arc, defined.ret_ownership);
    const returned = defined.body.?[0].kind.ret.?;
    try std.testing.expectEqual(Ownership.arc, returned.kind.call.ret_ownership);
}

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
    /// Declared ownership of the return value. An unannotated return is owned.
    ret_ownership: Ownership,
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
    /// The field's declared ownership. `ty` alone cannot say whether a
    /// `String` field is the borrowed view or the owning value, and the two
    /// differ in size, so a backend reading a field or writing one needs this.
    ownership: Ownership,
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
    /// `pattern if cond => body`. A guarded arm is never a catch-all, however
    /// catch-all its pattern looks.
    guard: ?*Expr,
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
        /// `Ok(x)` or `Err(e)` on a scalar Result scrutinee. `binding` is the
        /// payload's slot, typed as the Result's `ok` or `err` type, or null
        /// for `Ok(_)`/`Err(_)`. Only the pairs `abi.resultShape` lays out
        /// are lowered to this form.
        result_ctor: struct { is_ok: bool, binding: ?u32 },
        /// `Some(x)` or `None` on a scalar optional scrutinee. `binding` is the
        /// payload slot for `Some(x)`, null for `Some(_)` and `None`.
        option_ctor: struct { is_some: bool, binding: ?u32 },
    };
};

pub const Expr = struct {
    /// Every expression carries its resolved type. This is the property that
    /// makes the IR worth having.
    ty: Ty,
    span: Span,
    kind: Kind,
    /// The ownership the VALUE carries, which is what decides a `String`'s
    /// representation: `.shared` is the 16-byte borrowed view, `.owned`,
    /// `.copy` and `.exclusive` the 24-byte owning value (`abi.stringStruct`).
    /// Ownership stays out of `Ty`, per the module header; it rides here so
    /// the emitters read one recorded fact instead of re-deriving it.
    ///
    /// Set on a `.ref` (the binding's), a `.field` (the field's), a `.call`
    /// (the declared return), a string constant (`.shared`), a borrow
    /// `.unary` (its operand's), and a `block`/`if`/`match` (its first arm's,
    /// unless a destination stamps it; see `Lowerer.convertTo`). Null means
    /// the lowering recorded nothing, and a reader treats that as the view.
    own: ?Ownership = null,

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
            /// Declared ownership of the call result, or owned when unresolved.
            ret_ownership: Ownership,
        },
        field: struct { base: *Expr, sel: FieldSel },
        struct_lit: struct { name: []const u8, fields: []Expr },
        list_lit: []Expr,
        /// A block in expression position. `tail` is its value, null when the
        /// block yields unit.
        block: struct { stmts: []Stmt, tail: ?*Expr },
        if_expr: struct { cond: *Expr, then_body: *Expr, else_body: ?*Expr },
        match_expr: struct { scrutinee: *Expr, arms: []Arm },
        /// `Ok(x)` or `Err(e)` building the scalar Result named by `ty`. The
        /// operand is already typed as the Result's `ok` or `err` type.
        result_ctor: struct { is_ok: bool, operand: *Expr },
        /// `Some(x)` or `None` building the scalar optional named by `ty`.
        option_ctor: struct { is_some: bool, operand: ?*Expr },
        /// A borrowed view of an owning `String` PLACE: the pointer and length
        /// of a `cell_string_t`, as `cell_string_as_str` builds them. Inserted
        /// only by `Lowerer.convertTo`, only over a place (a binding, a field
        /// of one, or a borrow sigil wrapping either), never over a temporary,
        /// because a view of a temporary would outlive the only owner of its
        /// buffer. Typed `String`, `own = .shared`.
        string_view: *Expr,
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

    /// The declared return type of the function being lowered: the expected
    /// type of a `return Ok(..)`/`return Err(..)`, which has no type of its own.
    ret_ty: Ty = types.t_unit,
    /// The declared return ownership, the other half of a `return`'s
    /// destination for `convertTo`.
    ret_own: Ownership = .owned,

    const ScopeEntry = struct { name: []const u8, slot: u32, depth: u32 };
    const Sig = struct {
        name: []const u8,
        symbol: []const u8,
        params: []ast.Param,
        ret: Ty,
        ret_ownership: Ownership,
    };

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
                    .ret_ownership = returnOwnership(f.return_type),
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
        const ret_ownership = returnOwnership(f.return_type);
        self.ret_ty = ret;
        self.ret_own = ret_ownership;

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
            .ret_ownership = ret_ownership,
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
                // The declared type, when present, is the destination for an
                // untyped integer literal: `let copy a: Int8 = 3` is i8, not
                // Int. No other construct is inferred from it.
                const declared: ?Ty = if (l.ty) |*t| self.resolve(t) else null;
                var value: ?Expr = null;
                if (l.value) |v| value = try self.lowerExprIn(&v, declared);
                // An ANNOTATED `let` converts to its declared destination. An
                // unannotated one takes its type from the value, so C keeps
                // `let owned s = "ab"` a view and this does not copy it
                // either; but its OWNERSHIP still names the slot, and C views
                // an owned place bound `let shared v = s`
                // (`cell_string_as_str`), so the view direction applies.
                // An `exclusive` binding holds an address, so it wants the
                // place itself and never a converted value.
                if (value) |v| if (l.ownership != .exclusive) {
                    if (declared) |d| {
                        value = try self.convertTo(v, d, l.ownership);
                    } else if (stringRep(l.ownership) == .view) {
                        value = try self.convertTo(v, v.ty, l.ownership);
                    }
                };
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
                var value = try self.lowerExpr(&a.value);
                const place = try self.lowerPlace(&a.target);
                // The destination is the target binding, or the last field
                // selected. An `exclusive` target is a write THROUGH the
                // borrow into the owning pointee, so it converts like `owned`.
                const own: Ownership = if (place.path.len != 0)
                    place.path[place.path.len - 1].ownership
                else if (place.slot < self.bindings.items.len)
                    self.bindings.items[place.slot].ownership
                else
                    .owned;
                value = try self.convertTo(value, place.ty, own);
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
                    // Destination typing stays let- and call-arg-only for
                    // literals (`return 7` from `-> Int8` is still Int). The
                    // one form that needs the declared return type is
                    // `Ok`/`Err`, which has no type of its own.
                    const expected: ?Ty = if (e.kind == .wrap) self.ret_ty else null;
                    const value = try self.lowerExprIn(&e, expected);
                    return .{ .span = stmt.span, .kind = .{ .ret = try self.convertTo(value, self.ret_ty, self.ret_own) } };
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
                    return .{ .struct_name = struct_name, .index = @intCast(i), .ty = f.ty, .ownership = f.ownership };
                }
            }
        }
        return null;
    }

    fn lowerExpr(self: *Lowerer, e: *const ast.Expr) LowerError!Expr {
        return self.lowerExprIn(e, null);
    }

    /// Lower `e`. `expected` is the type of the slot the expression fills, and
    /// only `let` initializers and call arguments supply one. An untyped
    /// integer literal then takes that width when the value fits; every other
    /// form ignores it. That is not inference: it is the same destination rule
    /// typecheck.zig already applies, so LLVM and MLIR see i8 rather than i64
    /// for `let copy a: Int8 = 3`.
    fn lowerExprIn(self: *Lowerer, e: *const ast.Expr, expected: ?Ty) LowerError!Expr {
        switch (e.kind) {
            .int => |v| return self.lowerIntLiteral(e.span, v, expected),
            .float => |v| return self.lit(e.span, types.t_float, .{ .float_const = v }),
            .bool => |v| return self.lit(e.span, types.t_bool, .{ .bool_const = v }),
            // A literal is a borrowed view of static bytes.
            .string => |v| return .{ .ty = types.t_string, .span = e.span, .kind = .{ .string_const = v }, .own = .shared },

            .ident => |name| {
                if (self.lookup(name)) |slot| {
                    const b = self.bindings.items[slot];
                    return .{ .ty = b.ty, .span = e.span, .kind = .{ .ref = slot }, .own = b.ownership };
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
                // wrapper does not survive into the IR. The destination does:
                // `take(copy 7)` is still an untyped literal in a typed slot.
                return self.lowerExprIn(an.value, expected);
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
                if (u.op == .neg) {
                    if (try self.lowerNegatedIntLiteral(e.span, u.operand, expected)) |folded| {
                        return folded;
                    }
                }
                const operand = try self.box(try self.lowerExpr(u.operand));
                const ty: Ty = switch (u.op) {
                    .not => types.t_bool,
                    // `&x` and `&mut x` do not change the type: ownership is
                    // not part of a type here.
                    .neg, .ref_shared, .ref_exclusive => operand.ty,
                };
                // A borrow sigil is transparent in both emitters, which emit
                // its operand, so it carries the operand's fact. Without this
                // `peek(&s)` and `peek(shared s)` would read differently.
                const own: ?Ownership = switch (u.op) {
                    .ref_shared, .ref_exclusive => operand.own,
                    .neg, .not => null,
                };
                return .{ .ty = ty, .span = e.span, .kind = .{ .unary = .{ .op = u.op, .operand = operand } }, .own = own };
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
                    return .{ .ty = sel.ty, .span = e.span, .kind = .{ .field = .{ .base = base, .sel = sel } }, .own = sel.ownership };
                }
                // An unknown base type (`void*` in C today, per SPEC 0.6)
                // has no fields to resolve. Keep the projection and type it
                // `unknown` rather than refusing the program.
                return .{
                    .ty = types.t_unknown,
                    .span = e.span,
                    .kind = .{ .field = .{
                        .base = base,
                        .sel = .{ .struct_name = "", .index = 0, .ty = types.t_unknown, .ownership = .owned },
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
                                // A field is a destination with a declared
                                // ownership. An `exclusive` field is left
                                // alone, as at a `let`.
                                if (df.ownership != .exclusive) {
                                    fields[i] = try self.convertTo(fields[i], df.ty, df.ownership);
                                }
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
                    .own = if (tail) |t| t.own else null,
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
                    // The first arm's, as C's `inferExpr` types it, until a
                    // destination stamps its own.
                    .own = if (else_body != null) then_body.own else null,
                };
            },

            .match_expr => |me| {
                var scrutinee_value = try self.lowerExpr(me.scrutinee);
                // A string pattern compares against a borrowed view, so the
                // scrutinee is converted to one; other patterns take it as is.
                for (me.arms) |arm| {
                    if (arm.pattern.kind != .string) continue;
                    scrutinee_value = try self.convertTo(scrutinee_value, scrutinee_value.ty, .shared);
                    break;
                }
                const scrutinee = try self.box(scrutinee_value);
                var arms = try self.arena.alloc(Arm, me.arms.len);
                var result_ty: Ty = types.t_unit;
                var result_own: ?Ownership = null;
                for (me.arms, 0..) |arm, i| {
                    self.pushScope();
                    const pat = try self.lowerPattern(&arm.pattern, scrutinee.ty);
                    var guard: ?*Expr = null;
                    if (arm.guard) |g| guard = try self.box(try self.lowerExpr(g));
                    const body = try self.box(try self.lowerExpr(arm.body));
                    self.popScope();
                    arms[i] = .{ .pattern = pat, .guard = guard, .body = body, .span = arm.span };
                    if (i == 0) {
                        result_ty = body.ty;
                        result_own = body.own;
                    }
                }
                return .{
                    .ty = result_ty,
                    .span = e.span,
                    .kind = .{ .match_expr = .{ .scrutinee = scrutinee, .arms = arms } },
                    .own = result_own,
                };
            },

            .wrap => |w| {
                const want = expected orelse types.t_unknown;
                const is_ok = switch (w.ctor) {
                    .ok => true,
                    .err => false,
                    .some, .none => return self.lowerOptionCtor(e, w.ctor == .some, w.operand, want),
                };
                if (want.tag() != .result) {
                    try self.cannotLower(e.span, "Ok/Err need a declared Result destination (a typed let, a parameter, or a return)");
                    return self.lit(e.span, types.t_unknown, .{ .unresolved_ref = "wrap" });
                }
                const r = want.result;
                if (r.ok.tag() != .unit and abi.resultMember(r.ok.*) == null) {
                    try self.cannotLower(e.span, "a Result whose Ok payload is not a scalar primitive");
                    return self.lit(e.span, types.t_unknown, .{ .unresolved_ref = "wrap" });
                }
                if (abi.resultShape(r) == null) {
                    try self.cannotLower(e.span, "a Result whose Err payload is not a scalar primitive or a payload-free enum");
                    return self.lit(e.span, types.t_unknown, .{ .unresolved_ref = "wrap" });
                }
                const operand_ast = w.operand orelse {
                    try self.cannotLower(e.span, "Ok/Err without an operand");
                    return self.lit(e.span, types.t_unknown, .{ .unresolved_ref = "wrap" });
                };
                const operand = try self.box(try self.lowerExprIn(operand_ast, if (is_ok) r.ok.* else r.err.*));
                return .{
                    .ty = want,
                    .span = e.span,
                    .kind = .{ .result_ctor = .{ .is_ok = is_ok, .operand = operand } },
                };
            },

            .index => {
                try self.cannotLower(e.span, "indexing is not lowered by the IR backends");
                return self.lit(e.span, types.t_unknown, .{ .unresolved_ref = "index" });
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
            const param_ty: ?Ty = blk: {
                if (sig) |s| {
                    if (i < s.params.len) break :blk self.resolve(&s.params[i].ty);
                }
                break :blk null;
            };
            lowered_args[i] = try self.lowerExprIn(&a, param_ty);
            // An `exclusive` parameter takes the argument's ADDRESS, and a
            // converted temporary has none, so it is left for the emitters to
            // refuse, as C leaves it for `cc` (codegen's `want.pointer`).
            if (param_ty) |pt| if (param_mode != .exclusive) {
                lowered_args[i] = try self.convertTo(lowered_args[i], pt, param_mode);
            };
            modes[i] = .{ .param = param_mode, .written = written };
        }

        // The callee expression is lowered only when it is not a known
        // function name, since a name has no value in this language.
        const callee_expr = if (symbol != null)
            try self.box(self.lit(callee.span, types.t_unit, .{ .int_const = 0 }))
        else
            try self.box(try self.lowerExpr(callee));

        const ret_ownership: Ownership = if (sig) |s| s.ret_ownership else .owned;
        return .{
            .ty = if (sig) |s| s.ret else types.t_unknown,
            .span = span,
            .own = ret_ownership,
            .kind = .{ .call = .{
                .symbol = symbol,
                .callee = callee_expr,
                .args = lowered_args,
                .modes = modes,
                .ret_ownership = ret_ownership,
            } },
        };
    }

    /// THE CONVERSION FUNNEL, the IR twin of `codegen.emitConversion`.
    ///
    /// Every position that lowers a value into a destination with a declared
    /// type and ownership asks this one function: an annotated `let`, an
    /// assignment, a call argument, a struct-literal field, a `return`, and
    /// a string-pattern `match` scrutinee. The question is asked of the pair
    /// (what `e` carries in `e.own`, what the slot wants), never of the
    /// position, so a position nobody listed inherits the answer by calling
    /// here rather than by being enumerated.
    ///
    /// An owning String PLACE where a view is wanted is wrapped in a
    /// `string_view`. An owning TEMPORARY is left alone: a view of it would
    /// outlive the value's only owner, so the emitters refuse it, which is
    /// what C does.
    ///
    /// A `block`, `if` or `match` is not a value of its own: the conversion
    /// is pushed into its tail, branches or arms, and the node is stamped with
    /// the wanted ownership, so the value slot a backend allocates for it has
    /// the destination's representation.
    ///
    /// Anything whose representation this cannot name (an `arc` on either
    /// side, a non-String) is returned untouched. The emitters' `fits` guard
    /// stays as the backstop for whatever reaches them unconverted.
    fn convertTo(self: *Lowerer, e: Expr, want_ty: Ty, want_own: Ownership) LowerError!Expr {
        if (e.ty.tag() != .string or want_ty.tag() != .string) return e;
        switch (e.kind) {
            .block => |b| {
                const tail = b.tail orelse return e;
                tail.* = try self.convertTo(tail.*, want_ty, want_own);
                var out = e;
                out.own = want_own;
                return out;
            },
            .if_expr => |ie| {
                const else_body = ie.else_body orelse return e;
                ie.then_body.* = try self.convertTo(ie.then_body.*, want_ty, want_own);
                else_body.* = try self.convertTo(else_body.*, want_ty, want_own);
                var out = e;
                out.own = want_own;
                return out;
            },
            .match_expr => |me| {
                for (me.arms) |arm| {
                    arm.body.* = try self.convertTo(arm.body.*, want_ty, want_own);
                }
                var out = e;
                out.own = want_own;
                return out;
            },
            else => {},
        }
        const have = stringRep(e.own) orelse return e;
        const want = stringRep(want_own) orelse return e;
        if (have == want) return e;
        if (have == .owning) {
            if (!isPlace(&e)) return e;
            return .{
                .ty = e.ty,
                .span = e.span,
                .kind = .{ .string_view = try self.box(e) },
                .own = .shared,
            };
        }
        return e;
    }

    const StringRep = enum { view, owning };

    /// A String's representation for an ownership, mirroring
    /// `abi.stringStruct`: `shared` is the view, and `owned`, `copy` and
    /// `exclusive` (the pointee) the owning value. Null for `arc`, which no
    /// IR backend lowers. A value with no recorded fact is a view.
    fn stringRep(own: ?Ownership) ?StringRep {
        return switch (own orelse .shared) {
            .shared => .view,
            .owned, .copy, .exclusive => .owning,
            .arc => null,
        };
    }

    /// Whether `e` names storage that outlives the expression: a binding, a
    /// field of a place, or a borrow sigil over either.
    fn isPlace(e: *const Expr) bool {
        return switch (e.kind) {
            .ref => true,
            .field => |f| isPlace(f.base),
            .unary => |u| (u.op == .ref_shared or u.op == .ref_exclusive) and isPlace(u.operand),
            else => false,
        };
    }

    fn returnOwnership(return_type: ?ast.TypeExpr) Ownership {
        const ty = return_type orelse return .owned;
        return switch (ty) {
            .ref => |r| r.ownership,
            else => .owned,
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
            .wrap_pattern => |wp| {
                const is_ok = switch (wp.ctor) {
                    .ok => true,
                    .err => false,
                    .some, .none => return self.lowerOptionPattern(p, wp.ctor == .some, wp.binding, scrutinee_ty),
                };
                if (scrutinee_ty.tag() != .result) {
                    try self.cannotLower(p.span, "an Ok/Err pattern on a value that is not a Result");
                    return .{ .kind = .wildcard, .span = p.span };
                }
                const r = scrutinee_ty.result;
                if (abi.resultShape(r) == null) {
                    try self.cannotLower(p.span, "a Result pattern whose payloads are not scalar primitives or a payload-free enum");
                    return .{ .kind = .wildcard, .span = p.span };
                }
                if (wp.binding != null and wp.ctor == .ok and r.ok.tag() == .unit) {
                    try self.cannotLower(p.span, "binding the payload of a unit Ok");
                    return .{ .kind = .wildcard, .span = p.span };
                }
                var binding: ?u32 = null;
                if (wp.binding) |name| {
                    // Payloads are scalar copies, as typecheck.zig binds them
                    // and as the C backend reads them out of the union.
                    const slot: u32 = @intCast(self.bindings.items.len);
                    try self.bindings.append(self.arena, .{
                        .name = name,
                        .ty = if (is_ok) r.ok.* else r.err.*,
                        .ownership = .copy,
                        .mutable = false,
                        .is_param = false,
                        .slot = slot,
                    });
                    try self.scope.append(self.arena, .{ .name = name, .slot = slot, .depth = self.depth });
                    binding = slot;
                }
                return .{ .kind = .{ .result_ctor = .{ .is_ok = is_ok, .binding = binding } }, .span = p.span };
            },
        }
    }

    fn lowerOptionCtor(self: *Lowerer, e: *const ast.Expr, is_some: bool, operand_ast: ?*ast.Expr, want: Ty) LowerError!Expr {
        if (want.tag() != .optional) {
            try self.cannotLower(e.span, "Some/None need a declared optional destination (a typed let, a parameter, or a return)");
            return self.lit(e.span, types.t_unknown, .{ .unresolved_ref = "wrap" });
        }
        const inner = want.optional.*;
        if (!abi.optionPayloadCarried(inner)) {
            try self.cannotLower(e.span, "an optional whose payload is not a scalar with a runtime instance");
            return self.lit(e.span, types.t_unknown, .{ .unresolved_ref = "wrap" });
        }
        var operand: ?*Expr = null;
        if (is_some) {
            const o = operand_ast orelse {
                try self.cannotLower(e.span, "Some without an operand");
                return self.lit(e.span, types.t_unknown, .{ .unresolved_ref = "wrap" });
            };
            operand = try self.box(try self.lowerExprIn(o, inner));
        }
        return .{
            .ty = want,
            .span = e.span,
            .kind = .{ .option_ctor = .{ .is_some = is_some, .operand = operand } },
        };
    }

    fn lowerOptionPattern(self: *Lowerer, p: *const ast.Pattern, is_some: bool, name: ?[]const u8, scrutinee_ty: Ty) LowerError!Pattern {
        if (scrutinee_ty.tag() != .optional or !abi.optionPayloadCarried(scrutinee_ty.optional.*)) {
            try self.cannotLower(p.span, "a Some/None pattern on a value that is not a scalar optional");
            return .{ .kind = .wildcard, .span = p.span };
        }
        var binding: ?u32 = null;
        if (is_some) if (name) |n| {
            const slot: u32 = @intCast(self.bindings.items.len);
            try self.bindings.append(self.arena, .{
                .name = n,
                .ty = scrutinee_ty.optional.*,
                .ownership = .copy,
                .mutable = false,
                .is_param = false,
                .slot = slot,
            });
            try self.scope.append(self.arena, .{ .name = n, .slot = slot, .depth = self.depth });
            binding = slot;
        };
        return .{ .kind = .{ .option_ctor = .{ .is_some = is_some, .binding = binding } }, .span = p.span };
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

    fn lowerIntLiteral(self: *Lowerer, span: Span, v: i64, expected: ?Ty) LowerError!Expr {
        const ty = intLiteralTy(v, expected) orelse {
            try self.cannotLower(span, "integer literal does not fit the destination width");
            return self.lit(span, types.t_unknown, .{ .int_const = v });
        };
        return self.lit(span, ty, .{ .int_const = v });
    }

    /// Fold `-N` into an `int_const` of the destination width when `expected`
    /// is an integer slot. The operand `128` does not fit Int8, but `-128`
    /// does, so the sign has to be applied before the range check; passing
    /// the destination through to the operand would refuse a value that fits.
    /// Without a destination the unary form is left alone.
    fn lowerNegatedIntLiteral(
        self: *Lowerer,
        span: Span,
        operand: *const ast.Expr,
        expected: ?Ty,
    ) LowerError!?Expr {
        const dest = expected orelse return null;
        if (!isIntegerWidth(dest)) return null;
        const v = astIntLiteral(operand) orelse return null;
        if (v == std.math.minInt(i64)) {
            try self.cannotLower(span, "integer literal does not fit the destination width");
            return self.lit(span, types.t_unknown, .{ .int_const = 0 });
        }
        return try self.lowerIntLiteral(span, -v, expected);
    }
};

fn astIntLiteral(e: *const ast.Expr) ?i64 {
    var cur = e;
    while (true) {
        switch (cur.kind) {
            .int => |v| return v,
            .annotated => |an| cur = an.value,
            else => return null,
        }
    }
}

fn isIntegerWidth(ty: Ty) bool {
    return switch (ty) {
        .int, .int8, .int16, .int32, .uint, .uint8, .uint16, .uint32, .byte => true,
        else => false,
    };
}

fn intFitsWidth(v: i64, ty: Ty) bool {
    return switch (ty) {
        .int => true,
        .int8 => v >= std.math.minInt(i8) and v <= std.math.maxInt(i8),
        .int16 => v >= std.math.minInt(i16) and v <= std.math.maxInt(i16),
        .int32 => v >= std.math.minInt(i32) and v <= std.math.maxInt(i32),
        .uint => v >= 0,
        .uint8, .byte => v >= 0 and v <= std.math.maxInt(u8),
        .uint16 => v >= 0 and v <= std.math.maxInt(u16),
        .uint32 => v >= 0 and v <= std.math.maxInt(u32),
        else => false,
    };
}

/// The type an untyped integer literal takes in `expected`, or null when
/// `expected` is an integer width the value does not fit. Null is a refusal,
/// not a cue to truncate.
fn intLiteralTy(v: i64, expected: ?Ty) ?Ty {
    const dest = expected orelse return types.t_int;
    if (!isIntegerWidth(dest)) return types.t_int;
    if (intFitsWidth(v, dest)) return dest;
    return null;
}

const Lowered = struct {
    arena: std.heap.ArenaAllocator,
    diagnostics: diag.Bag,
    module: Module,

    fn deinit(self: *Lowered) void {
        self.diagnostics.deinit(self.arena.allocator());
        self.arena.deinit();
    }
};

fn lowerSource(source: []const u8) !Lowered {
    const lexer = @import("lexer.zig");
    const parser = @import("parser.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();
    var lex = lexer.Lexer.init(source, "t.cell");
    const tokens = try lex.tokenizeAll(allocator);
    var parser_state = parser.Parser.init(allocator, tokens.items, "t.cell");
    var ast_module = try parser_state.parseModule();
    var diagnostics: diag.Bag = .init("t.cell", source);
    errdefer diagnostics.deinit(allocator);
    const module = try lower(allocator, &ast_module, &diagnostics);
    return .{ .arena = arena, .diagnostics = diagnostics, .module = module };
}

test "an untyped integer literal takes the destination width" {
    var l = try lowerSource(
        \\pub fn take8(copy v: Int8) -> Int8;
        \\pub fn takeu32(copy v: UInt32) -> UInt32;
        \\pub fn f() {
        \\    let copy a: Int8 = 3
        \\    let copy b: Int16 = -4
        \\    let copy c: UInt8 = 1
        \\    let copy d: UInt16 = 2
        \\    let copy e: UInt32 = 7
        \\    let copy small: Int32 = -3
        \\    let copy g: Byte = 9
        \\    let copy h = take8(copy 5)
        \\    let copy i = takeu32(copy 16)
        \\}
    );
    defer l.deinit();
    try std.testing.expect(!l.diagnostics.hasErrors());
    const f = l.module.findFn("f").?;
    const body = f.body.?;
    try std.testing.expectEqual(.int8, body[0].kind.let.value.?.ty.tag());
    try std.testing.expectEqual(@as(i64, 3), body[0].kind.let.value.?.kind.int_const);
    try std.testing.expectEqual(.int16, body[1].kind.let.value.?.ty.tag());
    try std.testing.expectEqual(@as(i64, -4), body[1].kind.let.value.?.kind.int_const);
    try std.testing.expectEqual(.uint8, body[2].kind.let.value.?.ty.tag());
    try std.testing.expectEqual(.uint16, body[3].kind.let.value.?.ty.tag());
    try std.testing.expectEqual(.uint32, body[4].kind.let.value.?.ty.tag());
    try std.testing.expectEqual(.int32, body[5].kind.let.value.?.ty.tag());
    try std.testing.expectEqual(.byte, body[6].kind.let.value.?.ty.tag());
    const take8_arg = body[7].kind.let.value.?.kind.call.args[0];
    try std.testing.expectEqual(.int8, take8_arg.ty.tag());
    try std.testing.expectEqual(@as(i64, 5), take8_arg.kind.int_const);
    const takeu32_arg = body[8].kind.let.value.?.kind.call.args[0];
    try std.testing.expectEqual(.uint32, takeu32_arg.ty.tag());
    try std.testing.expectEqual(@as(i64, 16), takeu32_arg.kind.int_const);
}

test "an integer literal that does not fit the destination width is refused" {
    var l = try lowerSource(
        \\pub fn f() {
        \\    let copy a: Int8 = 128
        \\}
    );
    defer l.deinit();
    try std.testing.expect(l.diagnostics.hasErrors());
    var found = false;
    for (l.diagnostics.list.items) |d| {
        if (std.mem.indexOf(u8, d.message, "does not fit the destination width") != null) found = true;
    }
    try std.testing.expect(found);
}

test "a bare integer literal in return position stays Int" {
    // Destination typing is let and call-arg only. `return 7` from `-> Int8`
    // is still Int; LLVM/MLIR refuse the width mismatch rather than convert.
    var l = try lowerSource(
        \\pub fn f() -> Int8 {
        \\    return 7
        \\}
    );
    defer l.deinit();
    try std.testing.expect(!l.diagnostics.hasErrors());
    const ret = l.module.findFn("f").?.body.?[0].kind.ret.?;
    try std.testing.expectEqual(.int, ret.ty.tag());
}

test "Ok/Err lower to result_ctor typed by the declared Result, and patterns bind the payload" {
    var l = try lowerSource(
        \\pub enum ParseError { Empty, TooLong }
        \\pub fn parse_len(copy n: Int) -> Result<Int, ParseError> {
        \\    if n == 0 { return Err(ParseError.Empty) }
        \\    return Ok(n * 2)
        \\}
        \\pub fn score(copy r: Result<Int, ParseError>) -> Int {
        \\    return match r { Ok(v) => v, Err(e) => 1 }
        \\}
    );
    defer l.deinit();
    try std.testing.expect(!l.diagnostics.hasErrors());
    const parse = l.module.findFn("parse_len").?;
    const ok = parse.body.?[1].kind.ret.?;
    try std.testing.expectEqual(.result, ok.ty.tag());
    try std.testing.expect(ok.kind.result_ctor.is_ok);
    try std.testing.expectEqual(.int, ok.kind.result_ctor.operand.ty.tag());

    const score = l.module.findFn("score").?;
    const arms = score.body.?[0].kind.ret.?.kind.match_expr.arms;
    const ok_pat = arms[0].pattern.kind.result_ctor;
    try std.testing.expect(ok_pat.is_ok);
    try std.testing.expectEqual(.int, score.bindings[ok_pat.binding.?].ty.tag());
    const err_pat = arms[1].pattern.kind.result_ctor;
    try std.testing.expect(!err_pat.is_ok);
    try std.testing.expectEqual(.enum_type, score.bindings[err_pat.binding.?].ty.tag());
    try std.testing.expect(score.bindings[err_pat.binding.?].ownership == .copy);
}

test "Some/None lower to option_ctor, and a Some pattern binds the payload" {
    var l = try lowerSource(
        \\pub fn pick(copy a: Int) -> Int? {
        \\    if a > 0 { return Some(a) }
        \\    return None
        \\}
        \\pub fn get(copy o: Byte?, copy d: Byte) -> Byte {
        \\    return match o { Some(v) => v, None => d }
        \\}
    );
    defer l.deinit();
    try std.testing.expect(!l.diagnostics.hasErrors());
    const pick = l.module.findFn("pick").?;
    const none = pick.body.?[1].kind.ret.?;
    try std.testing.expectEqual(.optional, none.ty.tag());
    try std.testing.expect(!none.kind.option_ctor.is_some);
    try std.testing.expect(none.kind.option_ctor.operand == null);
    const get = l.module.findFn("get").?;
    const arms = get.body.?[0].kind.ret.?.kind.match_expr.arms;
    const some = arms[0].pattern.kind.option_ctor;
    try std.testing.expect(some.is_some);
    try std.testing.expectEqual(.byte, get.bindings[some.binding.?].ty.tag());
    try std.testing.expect(arms[1].pattern.kind.option_ctor.binding == null);
}

test "Result and optional forms the IR backends do not carry are refused" {
    const cases = [_]struct { src: []const u8, needle: []const u8 }{
        .{ .src = "pub fn f() { let copy r: Result<String, Int32> = Ok(\"x\") }", .needle = "Ok payload is not a scalar" },
        // `Result<Int, Int>` is carried since 2026-09-17 (per-pair structs);
        // an owning Err is not (sub-project 3).
        .{ .src = "pub fn f() { let copy r: Result<Int, String> = Err(\"x\") }", .needle = "Err payload is not a scalar primitive or a payload-free enum" },
        .{ .src = "pub fn f() { let copy o: String? = Some(\"x\") }", .needle = "optional whose payload is not a scalar" },
        .{ .src = "pub fn f() { let copy o = Some(1) }", .needle = "Some/None need a declared optional destination" },
    };
    for (cases) |c| {
        var l = try lowerSource(c.src);
        defer l.deinit();
        var found = false;
        for (l.diagnostics.list.items) |d| {
            if (std.mem.indexOf(u8, d.message, c.needle) != null) found = true;
        }
        if (!found) {
            std.debug.print("no '{s}' diagnostic for: {s}\n", .{ c.needle, c.src });
            return error.MissingRefusal;
        }
    }
}

test "Expr.own records the ownership a value carries" {
    // The fact the IR emitters read instead of re-deriving ownership from a
    // bare `Ty`, which spells every String as the borrowed view.
    var l = try lowerSource(
        \\pub struct Tag { owned name: String, copy n: Int }
        \\pub fn make() -> String;
        \\pub fn peek(shared v: String) -> Int;
        \\pub fn f(exclusive e: String, shared v: String) -> Int {
        \\    let owned s: String = make()
        \\    let owned t: Tag = Tag { name: make(), n: 1 }
        \\    let copy a = peek(shared s)
        \\    let copy b = peek(&s)
        \\    let copy c = peek(shared t.name)
        \\    let copy d = peek(shared e)
        \\    let copy g = peek(shared v)
        \\    let copy h = peek(shared "lit")
        \\    return t.n
        \\}
    );
    defer l.deinit();
    try std.testing.expect(!l.diagnostics.hasErrors());
    const body = l.module.findFn("f").?.body.?;
    try std.testing.expectEqual(@as(?Ownership, .owned), body[0].kind.let.value.?.own);
    // Each owned argument below reaches a `shared` parameter, so the funnel
    // wraps it in a view; the fact under test is on the wrapped operand.
    const a = body[2].kind.let.value.?.kind.call.args[0].kind.string_view.*;
    try std.testing.expectEqual(@as(?Ownership, .owned), a.own);
    // The sigil spelling carries the operand's fact, so it cannot diverge
    // from the keyword spelling above.
    const b = body[3].kind.let.value.?.kind.call.args[0].kind.string_view.*;
    try std.testing.expectEqual(.unary, std.meta.activeTag(b.kind));
    try std.testing.expectEqual(@as(?Ownership, .owned), b.own);
    const c = body[4].kind.let.value.?.kind.call.args[0].kind.string_view.*;
    try std.testing.expectEqual(.field, std.meta.activeTag(c.kind));
    try std.testing.expectEqual(Ownership.owned, c.kind.field.sel.ownership);
    try std.testing.expectEqual(@as(?Ownership, .owned), c.own);
    try std.testing.expectEqual(@as(?Ownership, .exclusive), body[5].kind.let.value.?.kind.call.args[0].kind.string_view.own);
    try std.testing.expectEqual(@as(?Ownership, .shared), body[6].kind.let.value.?.kind.call.args[0].own);
    try std.testing.expectEqual(@as(?Ownership, .shared), body[7].kind.let.value.?.kind.call.args[0].own);
    // A copy field read is copy, and a scalar call result is owned.
    try std.testing.expectEqual(@as(?Ownership, .copy), body[8].kind.ret.?.own);
    try std.testing.expectEqual(@as(?Ownership, .owned), body[2].kind.let.value.?.own);
}

test "a block, if or match with no destination takes its first arm's ownership" {
    var l = try lowerSource(
        \\pub fn make() -> String;
        \\pub fn f(copy n: Int) {
        \\    match n { 0 => make(), _ => "x", }
        \\    match n { 0 => "x", _ => make(), }
        \\    if n == 0 { make() } else { "x" }
        \\    { make() }
        \\}
    );
    defer l.deinit();
    try std.testing.expect(!l.diagnostics.hasErrors());
    const body = l.module.findFn("f").?.body.?;
    try std.testing.expectEqual(@as(?Ownership, .owned), body[0].kind.expr.own);
    try std.testing.expectEqual(@as(?Ownership, .shared), body[1].kind.expr.own);
    try std.testing.expectEqual(@as(?Ownership, .owned), body[2].kind.expr.own);
    try std.testing.expectEqual(@as(?Ownership, .owned), body[3].kind.expr.own);
}

test "string_view is inserted for an owned place and never for an owned temporary" {
    var l = try lowerSource(
        \\pub struct Tag { owned name: String }
        \\pub fn make() -> String;
        \\pub fn peek(shared v: String) -> Int;
        \\pub fn f(exclusive e: String) -> Int {
        \\    let owned s: String = make()
        \\    let owned t: Tag = Tag { name: make() }
        \\    let copy a = peek(shared s)
        \\    let copy b = peek(&s)
        \\    let copy c = peek(shared t.name)
        \\    let copy d = peek(shared e)
        \\    let copy g = peek(shared make())
        \\    let copy h = peek(shared "x")
        \\    let shared v: String = s
        \\    let shared w = s
        \\    let copy k = match s { x => 1, }
        \\    return match s { "a" => 1, _ => 0, }
        \\}
    );
    defer l.deinit();
    try std.testing.expect(!l.diagnostics.hasErrors());
    const body = l.module.findFn("f").?.body.?;
    const arg = struct {
        fn of(s: Stmt) Expr {
            return s.kind.let.value.?.kind.call.args[0];
        }
    }.of;
    // Owned places, whatever their spelling, become a view.
    for ([_]usize{ 2, 3, 4, 5 }) |i| {
        const v = arg(body[i]);
        if (v.kind != .string_view) {
            std.debug.print("statement {d}: {s}, not a string_view\n", .{ i, @tagName(v.kind) });
            return error.MissingView;
        }
        try std.testing.expectEqual(@as(?Ownership, .shared), v.own);
    }
    try std.testing.expectEqual(.ref, std.meta.activeTag(arg(body[2]).kind.string_view.kind));
    try std.testing.expectEqual(.unary, std.meta.activeTag(arg(body[3]).kind.string_view.kind));
    try std.testing.expectEqual(.field, std.meta.activeTag(arg(body[4]).kind.string_view.kind));
    // A temporary has no place to view, so it is left for the emitters to
    // refuse, and a view stays a view.
    try std.testing.expectEqual(.call, std.meta.activeTag(arg(body[6]).kind));
    try std.testing.expectEqual(.string_const, std.meta.activeTag(arg(body[7]).kind));
    // A `let shared` is a view slot whether or not it is annotated, and C
    // views the place in both spellings.
    try std.testing.expectEqual(.string_view, std.meta.activeTag(body[8].kind.let.value.?.kind));
    try std.testing.expectEqual(.string_view, std.meta.activeTag(body[9].kind.let.value.?.kind));
    // Only a match with a string pattern wants a view of its scrutinee.
    try std.testing.expectEqual(.ref, std.meta.activeTag(body[10].kind.let.value.?.kind.match_expr.scrutinee.kind));
    try std.testing.expectEqual(.string_view, std.meta.activeTag(body[11].kind.ret.?.kind.match_expr.scrutinee.kind));
}

test "UInt8 and Byte stay distinct destination widths" {
    var l = try lowerSource(
        \\pub fn f() {
        \\    let copy a: UInt8 = 1
        \\    let copy b: Byte = 1
        \\}
    );
    defer l.deinit();
    try std.testing.expect(!l.diagnostics.hasErrors());
    const body = l.module.findFn("f").?.body.?;
    try std.testing.expectEqual(.uint8, body[0].kind.let.value.?.ty.tag());
    try std.testing.expectEqual(.byte, body[1].kind.let.value.?.ty.tag());
    try std.testing.expect(!types.compatible(body[0].kind.let.value.?.ty, body[1].kind.let.value.?.ty));
}
