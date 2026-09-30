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
const dropfacts = @import("dropfacts.zig");
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
    /// Scratch slots and pattern aliases are not independent owners. The IR
    /// drop pass must positively confirm this flag before releasing a slot.
    droppable: bool = true,
    /// Borrow-checker identity, positively matched by name and order. Null
    /// for compiler scratch, bodyless parameters, or any numbering mismatch.
    bc_id: ?u32 = null,
    /// A `let` that bound a value when declared. A loop-exit drop releases
    /// only these: a declaration without an initializer may hold nothing.
    has_initializer: bool = false,
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
    /// `.runtime` for a bodyless declaration `lower` synthesized because a
    /// conversion it inserted calls into `runtime/cell_rt.c` (see
    /// `runtime_callees`). Such a `Fn` is named `$rt.<name>`, which no Cell
    /// identifier can spell, so `Module.findFn` never returns it for a
    /// source name. The emitters declare it like any other bodyless `Fn`.
    origin: Origin = .source,

    pub const Origin = enum { source, runtime };

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
// Runtime callees
// ---------------------------------------------------------------------------

/// A `runtime/cell_rt.c` entry point that lowering itself may call, as a
/// Cell signature. The emitters print its declaration through the ordinary
/// bodyless-`Fn` path, so its ABI is whatever `abi.zig` says that signature
/// is, and gate stage 10 compares it against clang's reading of the header.
pub const RuntimeCallee = struct {
    /// The synthesized `Fn`'s name. `$` starts no Cell identifier.
    name: []const u8,
    symbol: []const u8,
    params: []const Param,
    ret: Ty,
    ret_ownership: Ownership,

    pub const Param = struct { name: []const u8, ty: Ty, ownership: Ownership };
};

/// The runtime callees, indexed by `Runtime`: the String conversion (IR
/// step (a)), six bounds-checked index readers (step (b)), and scalar-list
/// pushes (step (d)). Calls use the C runtime's signatures on every backend.
pub const Runtime = enum {
    /// `cell_string_t cell_string_from_str(cell_str_t view)`: copies a
    /// borrowed view into a fresh heap buffer the caller owns.
    string_from_str,
    /// `void cell_string_free(cell_string_t *value)`.
    string_free,
    /// `void cell_slice_free(cell_slice_t *value)` for scalar-element lists.
    slice_free,
    /// `cell_opt_byte_t cell_str_byte_at(cell_str_t s, int64_t index)`.
    str_byte_at,
    /// `cell_opt_byte_t cell_bytes_at(cell_slice_t xs, int64_t index)`.
    bytes_at,
    /// `cell_opt_i64_t cell_list_i64_at(cell_slice_t xs, int64_t index)`.
    list_i64_at,
    /// `cell_opt_i32_t cell_list_i32_at(cell_slice_t xs, int64_t index)`.
    list_i32_at,
    /// `cell_opt_f64_t cell_list_f64_at(cell_slice_t xs, int64_t index)`.
    list_f64_at,
    /// `cell_opt_bool_t cell_list_bool_at(cell_slice_t xs, int64_t index)`.
    list_bool_at,
    bytes_push,
    list_i64_push,
    list_i32_push,
    list_f64_push,
    list_bool_push,

    pub fn callee(self: Runtime) RuntimeCallee {
        return runtime_callees[@backingInt(self)];
    }
};

pub const runtime_callees = [_]RuntimeCallee{
    .{
        .name = "$rt.string_from_str",
        .symbol = "cell_string_from_str",
        .params = &.{.{ .name = "view", .ty = types.t_string, .ownership = .shared }},
        .ret = types.t_string,
        .ret_ownership = .owned,
    },
    .{
        .name = "$rt.string_free",
        .symbol = "cell_string_free",
        .params = &.{.{ .name = "value", .ty = types.t_string, .ownership = .exclusive }},
        .ret = types.t_unit,
        .ret_ownership = .owned,
    },
    .{
        .name = "$rt.slice_free",
        .symbol = "cell_slice_free",
        // Every supported scalar list has the same cell_slice_t pointer ABI;
        // [Int] is the internal representative for this runtime callee.
        .params = &.{.{ .name = "value", .ty = .{ .list = &types.t_int }, .ownership = .exclusive }},
        .ret = types.t_unit,
        .ret_ownership = .owned,
    },
    indexReader("$rt.str_byte_at", "cell_str_byte_at", types.t_string, &types.t_byte),
    indexReader("$rt.bytes_at", "cell_bytes_at", .{ .list = &types.t_byte }, &types.t_byte),
    indexReader("$rt.list_i64_at", "cell_list_i64_at", .{ .list = &types.t_int }, &types.t_int),
    indexReader("$rt.list_i32_at", "cell_list_i32_at", .{ .list = &types.t_int32 }, &types.t_int32),
    indexReader("$rt.list_f64_at", "cell_list_f64_at", .{ .list = &types.t_float }, &types.t_float),
    indexReader("$rt.list_bool_at", "cell_list_bool_at", .{ .list = &types.t_bool }, &types.t_bool),
    pushEntry("$rt.bytes_push", "cell_bytes_push", &types.t_byte),
    pushEntry("$rt.list_i64_push", "cell_list_i64_push", &types.t_int),
    pushEntry("$rt.list_i32_push", "cell_list_i32_push", &types.t_int32),
    pushEntry("$rt.list_f64_push", "cell_list_f64_push", &types.t_float),
    pushEntry("$rt.list_bool_push", "cell_list_bool_push", &types.t_bool),
};

/// One index reader: `(shared xs: <base>, copy index: Int) -> <elem>?`.
fn indexReader(comptime name: []const u8, comptime symbol: []const u8, comptime base: Ty, comptime elem: *const Ty) RuntimeCallee {
    return .{
        .name = name,
        .symbol = symbol,
        .params = &.{
            .{ .name = "xs", .ty = base, .ownership = .shared },
            .{ .name = "index", .ty = types.t_int, .ownership = .copy },
        },
        .ret = .{ .optional = elem },
        .ret_ownership = .owned,
    };
}

/// `cell_slice_free` releases only the backing allocation, so this cleanup
/// slice admits exactly the element types that need no per-element drop glue.
fn scalarListElement(elem: Ty) bool {
    return switch (elem) {
        .byte, .int, .int32, .float, .boolean => true,
        else => false,
    };
}

/// Same address borrowck stores for a branch end (`borrowck.branchKeyOf`).
/// A nonempty block is keyed by its statement slice; anything else, including
/// an empty block, is keyed by the expression itself.
fn astBranchKey(e: *const ast.Expr) usize {
    return switch (e.kind) {
        .block => |stmts| if (stmts.len > 0) @intFromPtr(stmts.ptr) else @intFromPtr(e),
        else => @intFromPtr(e),
    };
}

/// True when every path through `e` leaves by `return`, `break`, or
/// `continue`. A release after that jump would not run, and MLIR rejects
/// instructions after a terminator, so the branch keeps the leak.
fn astBranchDiverges(e: *const ast.Expr) bool {
    switch (e.kind) {
        .block => |stmts| {
            if (stmts.len == 0) return false;
            const last = &stmts[stmts.len - 1];
            return switch (last.kind) {
                .return_stmt, .break_stmt, .continue_stmt => true,
                .expr => |*x| astBranchDiverges(x),
                else => false,
            };
        },
        .if_expr => |x| {
            const else_body = x.else_body orelse return false;
            return astBranchDiverges(x.then_body) and astBranchDiverges(else_body);
        },
        .match_expr => |x| {
            if (x.arms.len == 0) return false;
            for (x.arms) |arm| {
                if (!astBranchDiverges(arm.body)) return false;
            }
            return true;
        },
        else => return false,
    }
}

/// One checked builder: `(exclusive xs: [T], copy value: T) -> ()`.
fn pushEntry(comptime name: []const u8, comptime symbol: []const u8, comptime elem: *const Ty) RuntimeCallee {
    return .{
        .name = name,
        .symbol = symbol,
        .params = &.{
            .{ .name = "xs", .ty = .{ .list = elem }, .ownership = .exclusive },
            .{ .name = "value", .ty = elem.*, .ownership = .copy },
        },
        .ret = types.t_unit,
        .ret_ownership = .owned,
    };
}

comptime {
    std.debug.assert(runtime_callees.len == @typeInfo(Runtime).@"enum".field_names.len);
}

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
        /// produces no value. `after` is the release that runs when the
        /// condition fails or a `break` still holds the revived owner. A
        /// skip-revival `break` jumps past it.
        while_loop: struct { cond: Expr, body: []Stmt, after: []const Stmt = &.{} },
        /// `break` and `continue`. `depth` is how many loops the jump leaves
        /// BEYOND the innermost enclosing one: 0 is a plain jump (or a label
        /// naming the innermost loop), 1 targets the loop around it, and so
        /// on. `lower` resolves the label once; every consumer indexes its
        /// own loop stack at `len - 1 - n` and never sees a name. `skip` is
        /// set only on a `break` that borrowck recorded as `after_loop_skip`:
        /// that jump must land after `while_loop.after`.
        brk: struct { depth: u32, skip: bool = false },
        cont: u32,
    };
};

/// True when some `break` that targets the loop `depth` levels out of
/// `stmts` must jump past that loop's after-loop release. Nested loops are
/// scanned one level deeper. A loop with no such break keeps a single end
/// block, so label numbers in a program that never skips stay put.
pub fn loopHasSkipBreak(stmts: []const Stmt, depth: u32) bool {
    for (stmts) |*s| {
        if (stmtHasSkipBreak(s, depth)) return true;
    }
    return false;
}

fn stmtHasSkipBreak(s: *const Stmt, depth: u32) bool {
    return switch (s.kind) {
        .brk => |j| j.skip and j.depth == depth,
        .cont => false,
        .while_loop => |w| loopHasSkipBreak(w.body, depth + 1) or loopHasSkipBreak(w.after, depth),
        .expr => |e| exprHasSkipBreak(&e, depth),
        .let => |l| if (l.value) |v| exprHasSkipBreak(&v, depth) else false,
        .assign => |a| exprHasSkipBreak(&a.value, depth),
        .ret => |r| if (r) |v| exprHasSkipBreak(&v, depth) else false,
    };
}

fn exprHasSkipBreak(e: *const Expr, depth: u32) bool {
    return switch (e.kind) {
        .block => |bl| blk: {
            if (loopHasSkipBreak(bl.stmts, depth)) break :blk true;
            if (bl.tail) |t| break :blk exprHasSkipBreak(t, depth);
            break :blk false;
        },
        .if_expr => |i| blk: {
            if (exprHasSkipBreak(i.cond, depth)) break :blk true;
            if (exprHasSkipBreak(i.then_body, depth)) break :blk true;
            if (i.else_body) |eb| break :blk exprHasSkipBreak(eb, depth);
            break :blk false;
        },
        .match_expr => |m| blk: {
            if (exprHasSkipBreak(m.scrutinee, depth)) break :blk true;
            for (m.arms) |arm| {
                if (arm.guard) |g| if (exprHasSkipBreak(g, depth)) break :blk true;
                if (exprHasSkipBreak(arm.body, depth)) break :blk true;
            }
            break :blk false;
        },
        .call => |c| blk: {
            if (exprHasSkipBreak(c.callee, depth)) break :blk true;
            for (c.args) |*a| if (exprHasSkipBreak(a, depth)) break :blk true;
            break :blk false;
        },
        .binary => |b| exprHasSkipBreak(b.left, depth) or exprHasSkipBreak(b.right, depth),
        .unary => |u| exprHasSkipBreak(u.operand, depth),
        .field => |f| exprHasSkipBreak(f.base, depth),
        .struct_lit => |sl| blk: {
            for (sl.fields) |*fv| if (exprHasSkipBreak(fv, depth)) break :blk true;
            break :blk false;
        },
        .list_lit => |items| blk: {
            for (items) |*it| if (exprHasSkipBreak(it, depth)) break :blk true;
            break :blk false;
        },
        .result_ctor => |rc| exprHasSkipBreak(rc.operand, depth),
        .option_ctor => |oc| if (oc.operand) |o| exprHasSkipBreak(o, depth) else false,
        .string_view => |operand| exprHasSkipBreak(operand, depth),
        .int_const, .float_const, .bool_const, .string_const, .ref, .unresolved_ref, .enum_const => false,
    };
}

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
    return lowerChecked(allocator, module, diagnostics, null);
}

/// Lower with optional read-only borrow facts. Checked bindings receive an
/// identity only when their name and declaration order agree with borrowck.
/// Existing unchecked callers receive no identity or ownership-driven drops.
pub fn lowerChecked(
    allocator: std.mem.Allocator,
    module: *const ast.Module,
    diagnostics: *diag.Bag,
    facts: ?dropfacts.DropFacts,
) LowerError!Module {
    var l: Lowerer = .{
        .arena = allocator,
        .diagnostics = diagnostics,
        .module = module,
        .facts = facts,
    };
    return l.run();
}

const Lowerer = struct {
    arena: std.mem.Allocator,
    diagnostics: *diag.Bag,
    module: *const ast.Module,
    facts: ?dropfacts.DropFacts = null,
    next_bc_id: u32 = 0,
    identity_failed: bool = false,
    drop_inserted: bool = false,
    /// The statement list that contains the branch being lowered. Borrowck
    /// records that list as `block_end`. A field drop needs this exit, not
    /// only the merge: a field revived after the `if` is dead at
    /// `after_branch` and live at the block end, and freeing it on the
    /// keeping branch would double-free with the later store.
    enclosing_exit: ?struct { kind: dropfacts.ExitKind, key: usize } = null,

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

    /// The labels of the loops enclosing the statement being lowered,
    /// innermost last, null for an unlabelled loop. Pushed after a loop's
    /// condition is lowered, so a jump in the condition belongs to the
    /// enclosing loop, as typecheck decides it.
    loop_labels: std.ArrayList(?[]const u8) = .empty,
    /// Parallel to `loop_labels`: the `scope` length when each enclosing
    /// loop's body opened. A jump leaving that loop releases the owners
    /// declared from this index on and still in scope at the jump.
    loop_scope_starts: std.ArrayList(usize) = .empty,

    /// The declared return type of the function being lowered: the expected
    /// type of a `return Ok(..)`/`return Err(..)`, which has no type of its own.
    ret_ty: Ty = types.t_unit,
    /// The declared return ownership, the other half of a `return`'s
    /// destination for `convertTo`.
    ret_own: Ownership = .owned,

    /// Which `runtime_callees` a conversion called, so `resolveRuntime` can
    /// declare each exactly once.
    runtime_used: [runtime_callees.len]bool = @splat(false),

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
        if (self.facts) |facts| {
            if (self.next_bc_id != facts.nextBindingId() or self.identity_failed) {
                // An unpaired identity cannot authorize a future release.
                // Clear the whole module, not just the first mismatch, since
                // every later id could name a different binding.
                for (self.fns.items) |*f| {
                    for (f.bindings) |*binding| binding.bc_id = null;
                }
                if (self.drop_inserted) {
                    try self.cannotLower(.none, "HIR and borrow-checker binding identities diverged after cleanup insertion");
                }
            }
        }
        try self.resolveRuntime();

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
        self.loop_labels.clearRetainingCapacity();
        self.loop_scope_starts.clearRetainingCapacity();
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
                .bc_id = if (f.body != null) self.claimId(p.name) else null,
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
            const saved_exit = self.enclosing_exit;
            if (stmts.len > 0) {
                self.enclosing_exit = .{ .kind = .block_end, .key = @intFromPtr(stmts.ptr) };
            }
            body = try self.lowerStmts(stmts);
            self.enclosing_exit = saved_exit;
            body = try self.appendSimpleFallthroughDrops(f.name, stmts, body.?);
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

    fn claimId(self: *Lowerer, name: []const u8) ?u32 {
        const facts = self.facts orelse return null;
        const id = self.next_bc_id;
        self.next_bc_id += 1;
        const checked_name = facts.bindingName(id) orelse {
            self.identity_failed = true;
            return null;
        };
        if (!std.mem.eql(u8, checked_name, name)) {
            self.identity_failed = true;
            return null;
        }
        return id;
    }

    /// Straight-line cleanup slice: lets and literal or call String reassignments,
    /// optionally followed by a scalar return. A statement-position `if` is
    /// allowed through so an owner neither branch moved still gets this one
    /// function-end release. A `while` is allowed through for the same release:
    /// an unmoved owner is not on `while.after`, and a moved one is skipped
    /// here because `wasMoved` is set. A field assignment is allowed through
    /// so a direct record's remaining fields can be released at this exit;
    /// the assignment itself is not rewritten. A `match` or any other statement
    /// still leaves that release out. A body whose length no longer matches
    /// the AST cannot be zipped with it and must be kept as lowered.
    /// Evaluate replacements and the return value before releasing confirmed
    /// live owners at the exit.
    fn appendSimpleFallthroughDrops(self: *Lowerer, fn_name: []const u8, source: []const ast.Stmt, body: []Stmt) LowerError![]Stmt {
        const facts = self.facts orelse return body;
        if (self.identity_failed) return body;
        if (body.len != source.len) return body;
        var terminal_return = false;
        if (source.len != 0 and source[source.len - 1].kind == .return_stmt and body[body.len - 1].kind == .ret) {
            if (body[body.len - 1].kind.ret) |value| {
                switch (value.ty) {
                    .byte, .int, .int8, .int16, .int32, .uint, .uint8, .uint16, .uint32, .float, .float32, .boolean => {},
                    else => return body,
                }
            }
            terminal_return = true;
        }
        for (source, body, 0..) |src, lowered, index| {
            if (terminal_return and index == source.len - 1) continue;
            switch (src.kind) {
                .let => {},
                .while_stmt => {},
                .assign => |a| {
                    if (a.target.kind == .field) {
                        if (lowered.kind != .assign) return body;
                    } else {
                        if (a.target.kind != .ident or (a.value.kind != .string and a.value.kind != .call) or lowered.kind != .assign) return body;
                        const place = lowered.kind.assign.place;
                        if (place.path.len != 0 or place.slot >= self.bindings.items.len) return body;
                        const binding = self.bindings.items[place.slot];
                        if (binding.ownership != .owned or binding.ty.tag() != .string or !binding.droppable) return body;
                    }
                },
                .expr => |ex| {
                    if (ex.kind != .if_expr) return body;
                },
                else => return body,
            }
        }
        var out: std.ArrayList(Stmt) = .empty;
        for (source, body, 0..) |src, lowered, index| {
            if (terminal_return and index == source.len - 1) continue;
            if (src.kind == .assign and src.kind.assign.target.kind == .ident) {
                const a = src.kind.assign;
                const original = lowered.kind.assign;
                const binding = self.bindings.items[original.place.slot];
                // The replacement's constructor may allocate. Keep the old
                // owner alive until that expression has finished evaluating.
                const scratch: u32 = @intCast(self.bindings.items.len);
                try self.bindings.append(self.arena, .{
                    .name = "$drop.replacement",
                    .ty = binding.ty,
                    .ownership = .owned,
                    .mutable = false,
                    .is_param = false,
                    .slot = scratch,
                    .droppable = false,
                });
                try out.append(self.arena, .{ .span = src.span, .kind = .{ .let = .{ .slot = scratch, .value = original.value } } });
                if (facts.assignReleasesOldValue(a.target.kind.ident.ptr)) {
                    const old: Expr = .{ .ty = binding.ty, .span = .none, .own = .owned, .kind = .{ .ref = binding.slot } };
                    const call = try self.runtimeCall(.string_free, .none, &.{old});
                    try out.append(self.arena, .{ .span = .none, .kind = .{ .expr = call } });
                    self.drop_inserted = true;
                }
                const replacement: Expr = .{ .ty = binding.ty, .span = src.span, .own = .owned, .kind = .{ .ref = scratch } };
                try out.append(self.arena, .{ .span = src.span, .kind = .{ .assign = .{ .place = original.place, .value = replacement } } });
            } else {
                try out.append(self.arena, lowered);
            }
        }
        var return_value: ?Expr = null;
        if (terminal_return) {
            if (body[body.len - 1].kind.ret) |value| {
                const scratch: u32 = @intCast(self.bindings.items.len);
                try self.bindings.append(self.arena, .{
                    .name = "$drop.return",
                    .ty = value.ty,
                    .ownership = .owned,
                    .mutable = false,
                    .is_param = false,
                    .slot = scratch,
                    .droppable = false,
                });
                try out.append(self.arena, .{ .span = source[source.len - 1].span, .kind = .{ .let = .{ .slot = scratch, .value = value } } });
                return_value = .{ .ty = value.ty, .span = source[source.len - 1].span, .own = .owned, .kind = .{ .ref = scratch } };
            }
        }
        const exit_kind: dropfacts.ExitKind = if (terminal_return) .return_stmt else .block_end;
        const key = if (terminal_return) @intFromPtr(&source[source.len - 1]) else if (source.len == 0) @intFromPtr(fn_name.ptr) else @intFromPtr(source.ptr);
        var i = self.bindings.items.len;
        while (i > 0) {
            i -= 1;
            const binding = self.bindings.items[i];
            if (!binding.droppable or binding.ownership != .owned) continue;
            const release: Runtime = switch (binding.ty) {
                .string => .string_free,
                .list => |elem| if (scalarListElement(elem.*)) .slice_free else continue,
                else => continue,
            };
            // Only parameters and direct top-level lets. A nested initializer
            // can create slots, but its lifetime is not this function scope.
            if (!binding.is_param) {
                var is_direct = false;
                for (body) |stmt| {
                    if (stmt.kind == .let and stmt.kind.let.slot == binding.slot and stmt.kind.let.value != null) is_direct = true;
                }
                if (!is_direct) continue;
            }
            const id = binding.bc_id orelse continue;
            if (facts.wasMoved(id) or !facts.liveAtExit(exit_kind, key, id)) continue;
            const place: Expr = .{ .ty = binding.ty, .span = .none, .own = .owned, .kind = .{ .ref = binding.slot } };
            const call = try self.runtimeCall(release, .none, &.{place});
            try out.append(self.arena, .{ .span = .none, .kind = .{ .expr = call } });
            self.drop_inserted = true;
        }
        // Direct top-level record lets and owned record parameters. The
        // whole binding is not a String, so the loop above skipped it.
        // Release each remaining owned String or scalar-list field,
        // including a field of a nested record, once. There is no
        // whole-record IR drop. A record declared in a nested block is
        // released at that block's end, not here. `arc` and a wholly
        // moved record stay leaks.
        var j = self.bindings.items.len;
        while (j > 0) {
            j -= 1;
            const binding = self.bindings.items[j];
            if (!binding.droppable or binding.ownership != .owned) continue;
            const struct_name = switch (binding.ty) {
                .struct_type => |name| name,
                else => continue,
            };
            // A parameter has no `let`. A nested-block record is not a
            // direct let of this body, so it stays on the block-end walk.
            if (!binding.is_param) {
                var is_direct = false;
                for (body) |stmt| {
                    if (stmt.kind == .let and stmt.kind.let.slot == binding.slot and stmt.kind.let.value != null) is_direct = true;
                }
                if (!is_direct) continue;
            }
            const id = binding.bc_id orelse continue;
            if (facts.wasWhollyMoved(id)) continue;
            try self.appendScopeEndFieldDrops(&out, binding, id, struct_name, exit_kind, key);
        }
        if (terminal_return) try out.append(self.arena, .{ .span = source[source.len - 1].span, .kind = .{ .ret = return_value } });
        return out.items;
    }

    /// Declare each runtime callee a conversion used, once.
    ///
    /// A source function with the same SYMBOL is either the same declaration
    /// (reused: the module then declares it once, from the source) or a
    /// conflict: a body would define the runtime's own symbol, and a
    /// different signature would give one symbol two ABIs in one module.
    fn resolveRuntime(self: *Lowerer) LowerError!void {
        for (runtime_callees, 0..) |c, i| {
            if (!self.runtime_used[i]) continue;
            var existing: ?*const Fn = null;
            for (self.fns.items) |*f| {
                if (std.mem.eql(u8, f.symbol, c.symbol)) existing = f;
            }
            if (existing) |f| {
                if (f.body != null or !sameSignature(f, c)) {
                    try self.cannotLower(f.span, try std.fmt.allocPrint(
                        self.arena,
                        "'{s}' conflicts with the runtime's {s}, which a String conversion or an index in this module calls",
                        .{ f.name, c.symbol },
                    ));
                }
                continue;
            }
            var bindings = try self.arena.alloc(Binding, c.params.len);
            for (c.params, 0..) |p, j| {
                bindings[j] = .{
                    .name = p.name,
                    .ty = p.ty,
                    .ownership = p.ownership,
                    .mutable = false,
                    .is_param = true,
                    .slot = @intCast(j),
                };
            }
            try self.fns.append(self.arena, .{
                .name = c.name,
                .symbol = c.symbol,
                .param_count = @intCast(c.params.len),
                .bindings = bindings,
                .ret = c.ret,
                .ret_ownership = c.ret_ownership,
                .body = null,
                .is_public = false,
                .span = .none,
                .origin = .runtime,
            });
        }
    }

    fn sameSignature(f: *const Fn, c: RuntimeCallee) bool {
        if (f.param_count != c.params.len) return false;
        for (f.params(), c.params) |p, want| {
            if (p.ownership != want.ownership) return false;
            if (!sameType(p.ty, want.ty)) return false;
        }
        return f.ret_ownership == c.ret_ownership and sameType(f.ret, c.ret);
    }

    /// Strict, unlike `types.compatible`, which lets `unknown` match anything.
    fn sameType(a: Ty, b: Ty) bool {
        return a.tag() == b.tag() and types.compatible(a, b);
    }

    /// A call to a runtime callee, recorded so `resolveRuntime` declares it.
    fn runtimeCall(self: *Lowerer, id: Runtime, span: Span, args: []const Expr) LowerError!Expr {
        const c = id.callee();
        std.debug.assert(args.len == c.params.len);
        self.runtime_used[@backingInt(id)] = true;
        const lowered = try self.arena.dupe(Expr, args);
        var modes = try self.arena.alloc(ArgMode, args.len);
        for (c.params, 0..) |p, i| modes[i] = .{ .param = p.ownership, .written = null };
        return .{
            .ty = c.ret,
            .span = span,
            .own = c.ret_ownership,
            .kind = .{ .call = .{
                .symbol = c.symbol,
                .callee = try self.box(self.lit(span, types.t_unit, .{ .int_const = 0 })),
                .args = lowered,
                .modes = modes,
                .ret_ownership = c.ret_ownership,
            } },
        };
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

    /// Lower a statement list. A `break` or `continue` is preceded by the
    /// releases for the loop bodies it leaves (`appendLoopExitDrops`). A
    /// `return` inside a loop is preceded by the releases for every owner
    /// still live at that return (`appendReturnInLoopDrops`), after the
    /// returned value has been bound. A `while` carries the releases for
    /// owners declared before it on `while_loop.after`
    /// (`collectAfterLoopDrops`). Outside a loop a `return` is unchanged
    /// here; the function-end slice owns that case.
    fn lowerStmts(self: *Lowerer, stmts: []const ast.Stmt) LowerError![]Stmt {
        var out: std.ArrayList(Stmt) = try .initCapacity(self.arena, stmts.len);
        // By address: the borrow checker keys a jump's exit record by the
        // AST statement, so `&s` of a loop-variable copy would never match.
        for (stmts, 0..) |*s, index| {
            const lowered = try self.lowerStmt(s);
            switch (lowered.kind) {
                .brk => |j| try self.appendLoopExitDrops(&out, .jump, @intFromPtr(s), j.depth),
                .cont => |n| try self.appendLoopExitDrops(&out, .jump, @intFromPtr(s), n),
                .ret => if (self.loop_scope_starts.items.len != 0) {
                    try self.appendReturnInLoopDrops(&out, lowered, @intFromPtr(s));
                    continue;
                },
                .while_loop => {
                    var loop_stmt = lowered;
                    loop_stmt.kind.while_loop.after = try self.collectAfterLoopDrops(@intFromPtr(s), stmts[index + 1 ..]);
                    try out.append(self.arena, loop_stmt);
                    continue;
                },
                else => {},
            }
            try out.append(self.arena, lowered);
        }
        return out.items;
    }

    /// Release the owners a loop exit leaves: every confirmed-live, unmoved,
    /// initialized owned String or scalar list declared since the body of the
    /// loop `n` levels out opened, innermost first. `kind`/`key` name the
    /// borrow checker's record for this exit; a missing record keeps the leak.
    fn appendLoopExitDrops(self: *Lowerer, out: *std.ArrayList(Stmt), kind: dropfacts.ExitKind, key: usize, n: u32) LowerError!void {
        const facts = self.facts orelse return;
        if (self.identity_failed) return;
        const loops = self.loop_scope_starts.items.len;
        if (n >= loops) return;
        const start = self.loop_scope_starts.items[loops - 1 - n];
        var i = self.scope.items.len;
        while (i > start) {
            i -= 1;
            const slot = self.scope.items[i].slot;
            if (slot >= self.bindings.items.len) continue;
            const binding = self.bindings.items[slot];
            if (binding.is_param or !binding.droppable or !binding.has_initializer or binding.ownership != .owned) continue;
            const release: Runtime = switch (binding.ty) {
                .string => .string_free,
                .list => |elem| if (scalarListElement(elem.*)) .slice_free else continue,
                else => continue,
            };
            const id = binding.bc_id orelse continue;
            if (facts.wasMoved(id) or !facts.liveAtExit(kind, key, id)) continue;
            const place: Expr = .{ .ty = binding.ty, .span = .none, .own = .owned, .kind = .{ .ref = binding.slot } };
            const call = try self.runtimeCall(release, .none, &.{place});
            try out.append(self.arena, .{ .span = .none, .kind = .{ .expr = call } });
            self.drop_inserted = true;
        }
    }

    /// Release owners a `return` inside a loop still holds. The value is
    /// bound first: it may read a local this return is about to free.
    /// Admission is liveness at this return, not the loop-exit `!wasMoved`
    /// rule, so a revived owner is released and an owner still dead between
    /// the move and the revival is not. A missing record keeps the leak.
    /// String and scalar lists only. The returned owner itself is dead at
    /// this exit and is not released. Records, fields, and `arc` stay out.
    fn appendReturnInLoopDrops(self: *Lowerer, out: *std.ArrayList(Stmt), ret: Stmt, key: usize) LowerError!void {
        const facts = self.facts orelse {
            try out.append(self.arena, ret);
            return;
        };
        if (self.identity_failed) {
            try out.append(self.arena, ret);
            return;
        }
        var returning = ret;
        if (ret.kind.ret) |value| {
            const scratch = try self.branchScratch(&value);
            try out.append(self.arena, .{ .span = value.span, .kind = .{ .let = .{ .slot = scratch, .value = value } } });
            returning = .{
                .span = ret.span,
                .kind = .{ .ret = .{
                    .ty = value.ty,
                    .span = value.span,
                    .own = value.own,
                    .kind = .{ .ref = scratch },
                } },
            };
        }
        var i = self.scope.items.len;
        while (i > 0) {
            i -= 1;
            const slot = self.scope.items[i].slot;
            if (slot >= self.bindings.items.len) continue;
            const binding = self.bindings.items[slot];
            if (!binding.droppable or binding.ownership != .owned) continue;
            if (!binding.has_initializer and !binding.is_param) continue;
            const release: Runtime = switch (binding.ty) {
                .string => .string_free,
                .list => |elem| if (scalarListElement(elem.*)) .slice_free else continue,
                else => continue,
            };
            const id = binding.bc_id orelse continue;
            if (!facts.liveAtExit(.return_stmt, key, id)) continue;
            const place: Expr = .{ .ty = binding.ty, .span = .none, .own = .owned, .kind = .{ .ref = binding.slot } };
            const call = try self.runtimeCall(release, .none, &.{place});
            try out.append(self.arena, .{ .span = .none, .kind = .{ .expr = call } });
            self.drop_inserted = true;
        }
        try out.append(self.arena, returning);
    }

    /// Release an owner declared before this `while` once, after the loop.
    /// Admission is C's `after_loop` or `after_loop_skip`: moved somewhere,
    /// and live on the exits borrowck vouched for. The two records are
    /// exclusive for one binding. The drops hang on `while_loop.after`. A
    /// failing condition and a `break` that still holds the value run them.
    /// A skip-revival `break` is marked `skip` and the backends jump past
    /// them. `continue` and the back edge are not drop sites. An unmoved
    /// owner stays on the function-end path. A later statement that still
    /// reads the name keeps the leak, because the function-end record for a
    /// loop-moved owner is poisoned. String and scalar lists only. Records,
    /// fields, and `arc` stay out.
    fn collectAfterLoopDrops(self: *Lowerer, key: usize, later: []const ast.Stmt) LowerError![]const Stmt {
        const facts = self.facts orelse return &.{};
        if (self.identity_failed) return &.{};
        var out: std.ArrayList(Stmt) = .empty;
        var i = self.scope.items.len;
        while (i > 0) {
            i -= 1;
            const slot = self.scope.items[i].slot;
            if (slot >= self.bindings.items.len) continue;
            const binding = self.bindings.items[slot];
            if (!binding.droppable or binding.ownership != .owned) continue;
            if (!binding.has_initializer and !binding.is_param) continue;
            const release: Runtime = switch (binding.ty) {
                .string => .string_free,
                .list => |elem| if (scalarListElement(elem.*)) .slice_free else continue,
                else => continue,
            };
            const id = binding.bc_id orelse continue;
            const on_after = facts.liveAtExit(.after_loop, key, id);
            const on_skip = facts.liveAtExit(.after_loop_skip, key, id);
            if (on_after and on_skip) continue;
            if (!facts.wasMoved(id) or !(on_after or on_skip)) continue;
            if (astStmtsUse(later, binding.name)) continue;
            const place: Expr = .{ .ty = binding.ty, .span = .none, .own = .owned, .kind = .{ .ref = binding.slot } };
            const call = try self.runtimeCall(release, .none, &.{place});
            try out.append(self.arena, .{ .span = .none, .kind = .{ .expr = call } });
            self.drop_inserted = true;
        }
        return out.items;
    }

    /// Whether a later statement reads `name`. A false yes only keeps a leak.
    /// An assignment `name = e` does not count: it writes the slot. Mirrors
    /// the C emitter's `stmtsUse` so the after-loop release and that emitter
    /// agree on a use that follows the loop.
    fn astStmtsUse(stmts: []const ast.Stmt, name: []const u8) bool {
        for (stmts, 0..) |_, i| {
            if (astStmtUses(&stmts[i], name)) return true;
        }
        return false;
    }

    fn astStmtUses(s: *const ast.Stmt, name: []const u8) bool {
        return switch (s.kind) {
            .let => |l| if (l.value) |v| astExprUses(&v, name) else false,
            .expr => |e| astExprUses(&e, name),
            .return_stmt => |opt| if (opt) |v| astExprUses(&v, name) else false,
            .assign => |a| astTargetReads(&a.target, name) or astExprUses(&a.value, name),
            .while_stmt => |w| astExprUses(&w.cond, name) or astStmtsUse(w.body, name),
            .break_stmt, .continue_stmt => false,
        };
    }

    fn astTargetReads(e: *const ast.Expr, name: []const u8) bool {
        return switch (e.kind) {
            .ident => false,
            .annotated => |a| astTargetReads(a.value, name),
            else => astExprUses(e, name),
        };
    }

    fn astExprUses(e: *const ast.Expr, name: []const u8) bool {
        return switch (e.kind) {
            .ident => |n| std.mem.eql(u8, n, name),
            .int, .float, .string, .bool => false,
            .call => |c| blk: {
                if (astExprUses(c.callee, name)) break :blk true;
                for (c.args, 0..) |_, i| {
                    if (astExprUses(&c.args[i], name)) break :blk true;
                }
                break :blk false;
            },
            .binary => |b| astExprUses(b.left, name) or astExprUses(b.right, name),
            .unary => |u| astExprUses(u.operand, name),
            .field => |f| astExprUses(f.base, name),
            .index => |ix| astExprUses(ix.base, name) or astExprUses(ix.index, name),
            .struct_lit => |sl| blk: {
                for (sl.fields, 0..) |_, i| {
                    if (astExprUses(&sl.fields[i].value, name)) break :blk true;
                }
                break :blk false;
            },
            .list_lit => |items| blk: {
                for (items, 0..) |_, i| {
                    if (astExprUses(&items[i], name)) break :blk true;
                }
                break :blk false;
            },
            .block => |stmts| astStmtsUse(stmts, name),
            .if_expr => |i| blk: {
                if (astExprUses(i.cond, name)) break :blk true;
                if (astExprUses(i.then_body, name)) break :blk true;
                if (i.else_body) |eb| break :blk astExprUses(eb, name);
                break :blk false;
            },
            .match_expr => |m| blk: {
                if (astExprUses(m.scrutinee, name)) break :blk true;
                for (m.arms) |arm| {
                    if (astExprUses(arm.body, name)) break :blk true;
                }
                break :blk false;
            },
            .annotated => |a| astExprUses(a.value, name),
            .wrap => |w| if (w.operand) |o| astExprUses(o, name) else false,
        };
    }

    /// Release outer owners at one branch end. The binding is still in scope
    /// after the branch body is lowered, so it was declared outside that
    /// branch. Admission matches C's non-record branch rule, not the loop
    /// exit's `!wasMoved` rule: moved somewhere, live at this branch end, and
    /// not live after the merge. A missing branch-end record keeps the leak.
    /// Whole bindings are String and scalar lists. A record is not freed
    /// whole here: that double-frees the sibling the scope-end partial drop
    /// still owns. Direct owned String and scalar-list fields are released
    /// when they are live at this branch end and dead at the enclosing
    /// block end. Nested records, wholly moved records, and `arc` stay out.
    fn collectBranchEndDrops(self: *Lowerer, branch_key: usize, merge_key: usize) LowerError![]Stmt {
        const facts = self.facts orelse return &.{};
        if (self.identity_failed) return &.{};
        var out: std.ArrayList(Stmt) = .empty;
        var i = self.scope.items.len;
        while (i > 0) {
            i -= 1;
            const slot = self.scope.items[i].slot;
            if (slot >= self.bindings.items.len) continue;
            const binding = self.bindings.items[slot];
            if (!binding.droppable or binding.ownership != .owned) continue;
            // A parameter arrives initialized. A local without an initializer
            // may hold nothing, and releasing it would free an empty slot.
            if (!binding.has_initializer and !binding.is_param) continue;
            switch (binding.ty) {
                .struct_type => |struct_name| {
                    const id = binding.bc_id orelse continue;
                    // A wholly moved record belongs to the destination. Field
                    // frees would release the destination's buffers. IR has no
                    // whole-record drop glue on this path, so the record stays
                    // a leak rather than a double free.
                    if (facts.wasWhollyMoved(id)) continue;
                    try self.appendBranchEndFieldDrops(&out, binding, id, struct_name, branch_key, merge_key);
                    continue;
                },
                else => {},
            }
            const release: Runtime = switch (binding.ty) {
                .string => .string_free,
                .list => |elem| if (scalarListElement(elem.*)) .slice_free else continue,
                else => continue,
            };
            const id = binding.bc_id orelse continue;
            if (!facts.wasMoved(id)) continue;
            if (!facts.liveAtExit(.branch_end, branch_key, id)) continue;
            if (facts.liveAtExit(.after_branch, merge_key, id)) continue;
            const place: Expr = .{ .ty = binding.ty, .span = .none, .own = .owned, .kind = .{ .ref = binding.slot } };
            const call = try self.runtimeCall(release, .none, &.{place});
            try out.append(self.arena, .{ .span = .none, .kind = .{ .expr = call } });
            self.drop_inserted = true;
        }
        return out.items;
    }

    /// Direct owned fields of `binding`, reverse declaration order. A field
    /// still live after the merge is left for a later use. A field with no
    /// branch-end record, or still live at the enclosing block end, stays a
    /// leak. Nested record fields and `arc` fields are not spelled here.
    fn appendBranchEndFieldDrops(
        self: *Lowerer,
        out: *std.ArrayList(Stmt),
        binding: Binding,
        id: u32,
        struct_name: []const u8,
        branch_key: usize,
        merge_key: usize,
    ) LowerError!void {
        const facts = self.facts orelse return;
        const after = self.enclosing_exit orelse return;
        const def = self.findStructDecl(struct_name) orelse return;
        var i = def.fields.len;
        while (i > 0) {
            i -= 1;
            const field = def.fields[i];
            if (field.ownership != .owned) continue;
            const release: Runtime = switch (field.ty) {
                .string => .string_free,
                .list => |elem| if (scalarListElement(elem.*)) .slice_free else continue,
                else => continue,
            };
            if (facts.fieldLiveAtExit(.after_branch, merge_key, id, field.name)) continue;
            if (!facts.fieldLiveAtExit(.branch_end, branch_key, id, field.name)) continue;
            if (!facts.fieldDeadAtExit(after.kind, after.key, id, field.name)) continue;
            const base = try self.box(.{
                .ty = binding.ty,
                .span = .none,
                .own = binding.ownership,
                .kind = .{ .ref = binding.slot },
            });
            const place: Expr = .{
                .ty = field.ty,
                .span = .none,
                .own = field.ownership,
                .kind = .{ .field = .{
                    .base = base,
                    .sel = .{
                        .struct_name = struct_name,
                        .index = @intCast(i),
                        .ty = field.ty,
                        .ownership = field.ownership,
                    },
                } },
            };
            const call = try self.runtimeCall(release, .none, &.{place});
            try out.append(self.arena, .{ .span = .none, .kind = .{ .expr = call } });
            self.drop_inserted = true;
        }
    }

    /// Slots of direct `let`s in `stmts`. Copied so a later append can reallocate
    /// the statement slice without losing the list.
    fn letSlots(self: *Lowerer, stmts: []const Stmt) LowerError![]u32 {
        var n: usize = 0;
        for (stmts) |stmt| {
            if (stmt.kind == .let and stmt.kind.let.value != null) n += 1;
        }
        const slots = try self.arena.alloc(u32, n);
        var i: usize = 0;
        for (stmts) |stmt| {
            if (stmt.kind == .let and stmt.kind.let.value != null) {
                slots[i] = stmt.kind.let.slot;
                i += 1;
            }
        }
        return slots;
    }

    /// Record lets that belong to this nested block, not to the function.
    /// The same field walk as the function-end release, keyed by this block's
    /// own exit. A wholly moved record is not walked. The function-end pass
    /// does not see these lets, so the two do not both free one field.
    fn appendNestedRecordDrops(
        self: *Lowerer,
        out: *std.ArrayList(Stmt),
        slots: []const u32,
        exit_kind: dropfacts.ExitKind,
        key: usize,
    ) LowerError!void {
        const facts = self.facts orelse return;
        if (self.identity_failed or slots.len == 0) return;
        var j = self.bindings.items.len;
        while (j > 0) {
            j -= 1;
            const binding = self.bindings.items[j];
            if (!binding.droppable or binding.ownership != .owned or binding.is_param) continue;
            if (!binding.has_initializer) continue;
            const struct_name = switch (binding.ty) {
                .struct_type => |name| name,
                else => continue,
            };
            var here = false;
            for (slots) |slot| {
                if (slot == binding.slot) here = true;
            }
            if (!here) continue;
            const id = binding.bc_id orelse continue;
            if (facts.wasWhollyMoved(id)) continue;
            try self.appendScopeEndFieldDrops(out, binding, id, struct_name, exit_kind, key);
        }
    }

    /// Owned String and scalar-list fields still held at a function exit,
    /// including fields of a nested record. Reverse declaration order. A
    /// field the branch-end drop already released is dead at this exit and
    /// is not freed again. A moved String or list fails closed. A nested
    /// record is not freed whole: IR has no `cell_drop_*` glue, so the walk
    /// frees its remaining leaves instead. `arc` is not spelled. Depth 16
    /// matches C's `emitPartialFields`.
    fn appendScopeEndFieldDrops(
        self: *Lowerer,
        out: *std.ArrayList(Stmt),
        binding: Binding,
        id: u32,
        struct_name: []const u8,
        exit_kind: dropfacts.ExitKind,
        key: usize,
    ) LowerError!void {
        const base = try self.box(.{
            .ty = binding.ty,
            .span = .none,
            .own = binding.ownership,
            .kind = .{ .ref = binding.slot },
        });
        try self.appendScopeEndFields(out, id, struct_name, "", base, exit_kind, key, 0);
    }

    fn appendScopeEndFields(
        self: *Lowerer,
        out: *std.ArrayList(Stmt),
        id: u32,
        struct_name: []const u8,
        path_prefix: []const u8,
        base: *Expr,
        exit_kind: dropfacts.ExitKind,
        key: usize,
        depth: usize,
    ) LowerError!void {
        if (depth > 16) return;
        const facts = self.facts orelse return;
        const def = self.findStructDecl(struct_name) orelse return;
        var i = def.fields.len;
        while (i > 0) {
            i -= 1;
            const field = def.fields[i];
            if (field.ownership != .owned) continue;
            const field_path: []const u8 = if (path_prefix.len == 0)
                field.name
            else
                try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ path_prefix, field.name });
            if (facts.fieldWasMovedWhole(id, field_path)) continue;
            if (facts.fieldDeadAtExit(exit_kind, key, id, field_path)) continue;
            const place = try self.box(.{
                .ty = field.ty,
                .span = .none,
                .own = field.ownership,
                .kind = .{ .field = .{
                    .base = base,
                    .sel = .{
                        .struct_name = struct_name,
                        .index = @intCast(i),
                        .ty = field.ty,
                        .ownership = field.ownership,
                    },
                } },
            });
            switch (field.ty) {
                .string => {
                    if (facts.fieldWasMoved(id, field_path)) continue;
                    const call = try self.runtimeCall(.string_free, .none, &.{place.*});
                    try out.append(self.arena, .{ .span = .none, .kind = .{ .expr = call } });
                    self.drop_inserted = true;
                },
                .list => |elem| {
                    if (!scalarListElement(elem.*)) continue;
                    if (facts.fieldWasMoved(id, field_path)) continue;
                    const call = try self.runtimeCall(.slice_free, .none, &.{place.*});
                    try out.append(self.arena, .{ .span = .none, .kind = .{ .expr = call } });
                    self.drop_inserted = true;
                },
                .struct_type => |nested| {
                    // A partial move of one leaf still walks the rest.
                    // `fieldWasMoved` on this path is true in that case and
                    // must not skip the sibling.
                    try self.appendScopeEndFields(out, id, nested, field_path, place, exit_kind, key, depth + 1);
                },
                else => {},
            }
        }
    }

    /// Append `drops` after the branch's own statements and after its value
    /// is computed. A tail is bound to a nondroppable scratch first, so a
    /// release cannot free a buffer the tail still reads.
    fn placeDropsBeforeTail(self: *Lowerer, branch: Expr, drops: []const Stmt) LowerError!Expr {
        switch (branch.kind) {
            .block => |b| {
                const extra: usize = if (b.tail != null) 1 else 0;
                var stmts: std.ArrayList(Stmt) = try .initCapacity(self.arena, b.stmts.len + drops.len + extra);
                try stmts.appendSlice(self.arena, b.stmts);
                var out = branch;
                if (b.tail) |tail| {
                    const scratch = try self.branchScratch(tail);
                    try stmts.append(self.arena, .{ .span = tail.span, .kind = .{ .let = .{ .slot = scratch, .value = tail.* } } });
                    out.kind.block.tail = try self.box(.{
                        .ty = tail.ty,
                        .span = tail.span,
                        .own = tail.own,
                        .kind = .{ .ref = scratch },
                    });
                }
                try stmts.appendSlice(self.arena, drops);
                out.kind.block.stmts = stmts.items;
                return out;
            },
            else => {
                const scratch = try self.branchScratch(&branch);
                var stmts: std.ArrayList(Stmt) = try .initCapacity(self.arena, drops.len + 1);
                try stmts.append(self.arena, .{ .span = branch.span, .kind = .{ .let = .{ .slot = scratch, .value = branch } } });
                try stmts.appendSlice(self.arena, drops);
                const tail = try self.box(.{
                    .ty = branch.ty,
                    .span = branch.span,
                    .own = branch.own,
                    .kind = .{ .ref = scratch },
                });
                return .{
                    .ty = branch.ty,
                    .span = branch.span,
                    .own = branch.own,
                    .kind = .{ .block = .{ .stmts = stmts.items, .tail = tail } },
                };
            },
        }
    }

    /// The scratch a branch value lands in before releases. Not droppable and
    /// not a borrow-checker identity: it is a copy of the value, not a second
    /// owner the drop pass may free.
    fn branchScratch(self: *Lowerer, value: *const Expr) LowerError!u32 {
        const scratch: u32 = @intCast(self.bindings.items.len);
        const ownership: Ownership = value.own orelse if (value.ty.tag() == .string) .shared else .owned;
        try self.bindings.append(self.arena, .{
            .name = "$drop.branch",
            .ty = value.ty,
            .ownership = ownership,
            .mutable = false,
            .is_param = false,
            .slot = scratch,
            .droppable = false,
        });
        return scratch;
    }

    fn insertBranchEndDrops(self: *Lowerer, branch: *Expr, branch_key: usize, merge_key: usize) LowerError!void {
        const drops = try self.collectBranchEndDrops(branch_key, merge_key);
        if (drops.len == 0) return;
        branch.* = try self.placeDropsBeforeTail(branch.*, drops);
    }

    fn lowerStmt(self: *Lowerer, stmt: *const ast.Stmt) LowerError!Stmt {
        switch (stmt.kind) {
            .let => |*l| {
                // The initializer is lowered BEFORE the binding enters scope,
                // so `let x = x` reads the outer `x`. That matches
                // typecheck.zig, which declares after checking the value.
                // The declared type, when present, is the destination for an
                // untyped integer literal: `let copy a: Int8 = 3` is i8, not
                // Int. No other construct is inferred from it.
                // Pointer capture: an `if` or `match` in the initializer is
                // keyed by its address in this statement, the same address
                // borrowck recorded. A by-value capture would miss it.
                const declared: ?Ty = if (l.ty) |*t| self.resolve(t) else null;
                var value: ?Expr = null;
                if (l.value) |*v| value = try self.lowerExprIn(v, declared);
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
                    .bc_id = self.claimId(l.name),
                    .has_initializer = value != null,
                });
                try self.scope.append(self.arena, .{ .name = l.name, .slot = slot, .depth = self.depth });

                return .{ .span = stmt.span, .kind = .{ .let = .{ .slot = slot, .value = value } } };
            },
            .assign => |*a| {
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
            .expr => |*e| return .{ .span = stmt.span, .kind = .{ .expr = try self.lowerExpr(e) } },
            .while_stmt => |*w| {
                const cond = try self.lowerExpr(&w.cond);
                self.pushScope();
                try self.loop_labels.append(self.arena, w.label);
                try self.loop_scope_starts.append(self.arena, self.scope.items.len);
                var body = try self.lowerStmts(w.body);
                // The body's fall-through end releases its own direct owners
                // before the next iteration re-binds them. A body whose last
                // statement already leaves has no fall-through end.
                if (w.body.len > 0) switch (body[body.len - 1].kind) {
                    .brk, .cont, .ret => {},
                    else => {
                        const slots = try self.letSlots(body);
                        var out: std.ArrayList(Stmt) = .fromOwnedSlice(body);
                        const key = @intFromPtr(w.body.ptr);
                        try self.appendLoopExitDrops(&out, .block_end, key, 0);
                        try self.appendNestedRecordDrops(&out, slots, .block_end, key);
                        body = out.items;
                    },
                };
                _ = self.loop_scope_starts.pop();
                _ = self.loop_labels.pop();
                self.popScope();
                return .{ .span = stmt.span, .kind = .{ .while_loop = .{ .cond = cond, .body = body } } };
            },
            .break_stmt => |j| {
                const depth = try self.jumpDepth(stmt.span, j.label);
                const skip = if (self.facts) |facts|
                    !self.identity_failed and facts.skipBreak(@intFromPtr(stmt))
                else
                    false;
                return .{ .span = stmt.span, .kind = .{ .brk = .{ .depth = depth, .skip = skip } } };
            },
            .continue_stmt => |j| return .{ .span = stmt.span, .kind = .{ .cont = try self.jumpDepth(stmt.span, j.label) } },
            .return_stmt => |*maybe| {
                if (maybe.*) |*e| {
                    // Destination typing stays let- and call-arg-only for
                    // literals (`return 7` from `-> Int8` is still Int). The
                    // one form that needs the declared return type is
                    // `Ok`/`Err`, which has no type of its own.
                    const expected: ?Ty = if (e.kind == .wrap) self.ret_ty else null;
                    const value = try self.lowerExprIn(e, expected);
                    return .{ .span = stmt.span, .kind = .{ .ret = try self.convertTo(value, self.ret_ty, self.ret_own) } };
                }
                return .{ .span = stmt.span, .kind = .{ .ret = null } };
            },
        }
    }

    /// How many loops a jump leaves beyond the innermost: 0 for a plain jump
    /// and for a label naming the innermost loop. A label no enclosing loop
    /// carries is reachable only in a module typecheck refused; it is `cannot
    /// lower`, never a guess at the innermost loop (spec invariant 16).
    fn jumpDepth(self: *Lowerer, span: Span, label: ?[]const u8) LowerError!u32 {
        const name = label orelse return 0;
        var i = self.loop_labels.items.len;
        while (i > 0) {
            i -= 1;
            const l = self.loop_labels.items[i] orelse continue;
            if (std.mem.eql(u8, l, name)) return @intCast(self.loop_labels.items.len - 1 - i);
        }
        try self.cannotLower(span, try std.fmt.allocPrint(self.arena, "no enclosing loop is labelled '{s}'", .{name}));
        return 0;
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
                        for (sl.fields) |*init_field| {
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
                    for (sl.fields, 0..) |*init_field, i| {
                        fields[i] = try self.lowerExpr(&init_field.value);
                    }
                }
                return .{
                    .ty = .{ .struct_type = sl.name },
                    .span = e.span,
                    .kind = .{ .struct_lit = .{ .name = sl.name, .fields = fields } },
                };
            },

            .list_lit => |elems| return self.lowerList(e.span, elems, expected),

            .block => |stmts| {
                self.pushScope();
                defer self.popScope();
                const saved_exit = self.enclosing_exit;
                const exit_key: usize = if (stmts.len > 0) @intFromPtr(stmts.ptr) else 0;
                if (stmts.len > 0) {
                    self.enclosing_exit = .{ .kind = .block_end, .key = exit_key };
                }
                defer self.enclosing_exit = saved_exit;
                // A trailing expression statement is the block's value.
                var tail: ?*Expr = null;
                var body_len = stmts.len;
                if (stmts.len > 0 and stmts[stmts.len - 1].kind == .expr) {
                    body_len -= 1;
                }
                const lowered = try self.lowerStmts(stmts[0..body_len]);
                const slots = try self.letSlots(lowered);
                if (slots.len == 0) {
                    if (body_len != stmts.len) {
                        tail = try self.box(try self.lowerExpr(&stmts[stmts.len - 1].kind.expr));
                    }
                    return .{
                        .ty = if (tail) |t| t.ty else types.t_unit,
                        .span = e.span,
                        .kind = .{ .block = .{ .stmts = lowered, .tail = tail } },
                        .own = if (tail) |t| t.own else null,
                    };
                }
                var out: std.ArrayList(Stmt) = .fromOwnedSlice(lowered);
                if (body_len != stmts.len) {
                    const value = try self.lowerExpr(&stmts[stmts.len - 1].kind.expr);
                    const scratch = try self.branchScratch(&value);
                    try out.append(self.arena, .{ .span = value.span, .kind = .{ .let = .{ .slot = scratch, .value = value } } });
                    tail = try self.box(.{
                        .ty = value.ty,
                        .span = value.span,
                        .own = value.own,
                        .kind = .{ .ref = scratch },
                    });
                }
                try self.appendNestedRecordDrops(&out, slots, .block_end, exit_key);
                return .{
                    .ty = if (tail) |t| t.ty else types.t_unit,
                    .span = e.span,
                    .kind = .{ .block = .{ .stmts = out.items, .tail = tail } },
                    .own = if (tail) |t| t.own else null,
                };
            },

            .if_expr => |ie| {
                const cond = try self.box(try self.lowerExpr(ie.cond));
                var then_lowered = try self.lowerExpr(ie.then_body);
                const merge_key = @intFromPtr(e);
                // A source else, not a synthesized one. The if stays unit when
                // the program had no else, even after a release block is added.
                const has_source_else = ie.else_body != null;
                if (!astBranchDiverges(ie.then_body)) {
                    try self.insertBranchEndDrops(&then_lowered, astBranchKey(ie.then_body), merge_key);
                }
                var else_body: ?*Expr = null;
                if (ie.else_body) |eb| {
                    var else_lowered = try self.lowerExpr(eb);
                    if (!astBranchDiverges(eb)) {
                        try self.insertBranchEndDrops(&else_lowered, astBranchKey(eb), merge_key);
                    }
                    else_body = try self.box(else_lowered);
                } else {
                    // Missing else is keyed by the if expression, the same
                    // address borrowck recorded. The block holds only releases.
                    const drops = try self.collectBranchEndDrops(@intFromPtr(e), merge_key);
                    if (drops.len != 0) {
                        else_body = try self.box(.{
                            .ty = types.t_unit,
                            .span = e.span,
                            .kind = .{ .block = .{ .stmts = drops, .tail = null } },
                        });
                    }
                }
                const then_body = try self.box(then_lowered);
                return .{
                    // Without a source else there is no value, so the if is
                    // unit even when the then-branch has a type.
                    .ty = if (has_source_else) then_body.ty else types.t_unit,
                    .span = e.span,
                    .kind = .{ .if_expr = .{ .cond = cond, .then_body = then_body, .else_body = else_body } },
                    // The first arm's, as C's `inferExpr` types it, until a
                    // destination stamps its own.
                    .own = if (has_source_else) then_body.own else null,
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
                const merge_key = @intFromPtr(me.arms.ptr);
                for (me.arms, 0..) |arm, i| {
                    self.pushScope();
                    const pat = try self.lowerPattern(&arm.pattern, scrutinee.ty);
                    var guard: ?*Expr = null;
                    if (arm.guard) |g| guard = try self.box(try self.lowerExpr(g));
                    var body = try self.lowerExpr(arm.body);
                    self.popScope();
                    if (!astBranchDiverges(arm.body)) {
                        try self.insertBranchEndDrops(&body, astBranchKey(arm.body), merge_key);
                    }
                    arms[i] = .{ .pattern = pat, .guard = guard, .body = try self.box(body), .span = arm.span };
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

            .index => |ix| return self.lowerIndex(e, ix.base, ix.index),
        }
    }

    /// `a[i]` as a call to the bounds-checked runtime reader C calls. The
    /// reader is picked from the base's HIR type, naming every accepted
    /// element; anything else is refused, as is an `arc` base (no retain or
    /// release in the IR, and an `arc [T]` is a box, not a slice). A String
    /// base goes through `convertTo`, so an owned place becomes a view and an
    /// owned temporary stays owning, which the emitters' `fits` refuses.
    fn lowerIndex(self: *Lowerer, e: *const ast.Expr, base_ast: *const ast.Expr, index_ast: *const ast.Expr) LowerError!Expr {
        var base = try self.lowerExpr(base_ast);
        const index = try self.lowerExprIn(index_ast, types.t_int);
        if (base.own == .arc) {
            try self.cannotLower(e.span, "indexing an 'arc' value (no retain or release in the IR backends)");
            return self.lit(e.span, types.t_unknown, .{ .unresolved_ref = "index" });
        }
        const id: Runtime = switch (base.ty) {
            .string => .str_byte_at,
            .list => |elem| switch (elem.*) {
                .byte => .bytes_at,
                .int => .list_i64_at,
                .int32 => .list_i32_at,
                .float => .list_f64_at,
                .boolean => .list_bool_at,
                else => {
                    try self.cannotLower(e.span, "indexing a value with no bounds-checked runtime reader");
                    return self.lit(e.span, types.t_unknown, .{ .unresolved_ref = "index" });
                },
            },
            else => {
                try self.cannotLower(e.span, "indexing a value with no bounds-checked runtime reader");
                return self.lit(e.span, types.t_unknown, .{ .unresolved_ref = "index" });
            },
        };
        if (id == .str_byte_at) base = try self.convertTo(base, types.t_string, .shared);
        return self.runtimeCall(id, e.span, &.{ base, index });
    }

    /// A non-empty scalar list is a value block: start with an empty owned
    /// header, append each element in source order, then yield the header.
    /// The scratch is a transfer source, never a second owner for the drop
    /// pass. It is intentionally absent from the name scope and borrowck IDs.
    fn lowerList(self: *Lowerer, span: Span, elems: []const ast.Expr, expected: ?Ty) LowerError!Expr {
        const expected_elem: ?Ty = if (expected) |want| switch (want) {
            .list => |p| p.*,
            else => null,
        } else null;
        if (elems.len == 0) {
            const p = try self.arena.create(Ty);
            p.* = expected_elem orelse types.t_unknown;
            return .{ .ty = .{ .list = p }, .span = span, .kind = .{ .list_lit = &.{} }, .own = .owned };
        }

        var values = try self.arena.alloc(Expr, elems.len);
        values[0] = try self.lowerExprIn(&elems[0], expected_elem);
        const elem_ty = expected_elem orelse values[0].ty;
        const push: Runtime = switch (elem_ty) {
            .byte => .bytes_push,
            .int => .list_i64_push,
            .int32 => .list_i32_push,
            .float => .list_f64_push,
            .boolean => .list_bool_push,
            else => {
                try self.cannotLower(span, "a list literal whose element has no runtime push");
                return self.emptyList(span, elem_ty);
            },
        };
        if (!sameType(values[0].ty, elem_ty)) {
            try self.cannotLower(span, "a list literal element does not match its destination type");
            return self.emptyList(span, elem_ty);
        }
        for (elems[1..], 1..) |*el, i| {
            values[i] = try self.lowerExprIn(el, elem_ty);
            if (!sameType(values[i].ty, elem_ty)) {
                try self.cannotLower(el.span, "a list literal element does not match its destination type");
                return self.emptyList(span, elem_ty);
            }
        }

        const p = try self.arena.create(Ty);
        p.* = elem_ty;
        const list_ty: Ty = .{ .list = p };
        const slot: u32 = @intCast(self.bindings.items.len);
        try self.bindings.append(self.arena, .{
            .name = "$list",
            .ty = list_ty,
            .ownership = .owned,
            .mutable = true,
            .is_param = false,
            .slot = slot,
            .droppable = false,
        });

        var stmts = try self.arena.alloc(Stmt, values.len + 1);
        stmts[0] = .{ .span = span, .kind = .{ .let = .{ .slot = slot, .value = try self.emptyList(span, elem_ty) } } };
        for (values, 0..) |value, i| {
            const base: Expr = .{ .ty = list_ty, .span = span, .kind = .{ .ref = slot }, .own = .owned };
            stmts[i + 1] = .{ .span = elems[i].span, .kind = .{ .expr = try self.runtimeCall(push, elems[i].span, &.{ base, value }) } };
        }
        const tail: Expr = .{ .ty = list_ty, .span = span, .kind = .{ .ref = slot }, .own = .owned };
        return .{ .ty = list_ty, .span = span, .kind = .{ .block = .{ .stmts = stmts, .tail = try self.box(tail) } }, .own = .owned };
    }

    fn emptyList(self: *Lowerer, span: Span, elem_ty: Ty) LowerError!Expr {
        const p = try self.arena.create(Ty);
        p.* = elem_ty;
        return .{ .ty = .{ .list = p }, .span = span, .kind = .{ .list_lit = &.{} }, .own = .owned };
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
        for (args, 0..) |*a, i| {
            // The written prefix is read off the AST before lowering strips it.
            // `a` stays the argument in the call's slice: an `if` there is
            // keyed by that address, which a by-value capture would replace.
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
            lowered_args[i] = try self.lowerExprIn(a, param_ty);
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
    /// A borrowed view where an owning String is wanted becomes a call to
    /// `cell_string_from_str` (`Runtime.string_from_str`). Any source is safe,
    /// because the call COPIES: it takes no ownership from its operand and
    /// makes no second owner of a buffer. The result is owned by the
    /// destination; only the narrow all-let fall-through shape has IR cleanup
    /// so far, and `examples/leaks/` pins the remaining unfreed positions.
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
        return switch (have) {
            .view => try self.runtimeCall(.string_from_str, e.span, &.{e}),
            .owning => if (isPlace(&e)) .{
                .ty = e.ty,
                .span = e.span,
                .kind = .{ .string_view = try self.box(e) },
                .own = .shared,
            } else e,
        };
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
                    .droppable = false,
                    .bc_id = self.claimId(name),
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
                        .droppable = false,
                        .bc_id = self.claimId(name),
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
                .droppable = false,
                .bc_id = self.claimId(n),
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

fn isStringFromStr(e: Expr) bool {
    return e.kind == .call and e.kind.call.symbol != null and
        std.mem.eql(u8, e.kind.call.symbol.?, "cell_string_from_str") and
        e.kind.call.args.len == 1 and e.kind.call.args[0].own == .shared and
        e.own == .owned;
}

fn countSymbol(m: Module, symbol: []const u8) usize {
    var n: usize = 0;
    for (m.fns) |f| {
        if (std.mem.eql(u8, f.symbol, symbol)) n += 1;
    }
    return n;
}

test "a synthetic cell_string_from_str call is inserted at every conversion position" {
    // The eight positions examples/owned_string.cell exercises, plus the
    // write through an exclusive borrow and a `copy String` binding.
    var l = try lowerSource(
        \\pub struct Tag { owned name: String }
        \\pub fn make() -> String;
        \\pub fn take(owned s: String) -> Int;
        \\pub fn label() -> String { return "ab" }
        \\pub fn pick(copy n: Int) -> String { return match n { 0 => make(), _ => "abcdefghi", } }
        \\pub fn reset(exclusive s: String) { s = "cd" }
        \\pub fn main() {
        \\    let owned b: String = "abc"
        \\    var owned c: String = "abcd"
        \\    let copy x = take(owned "abcde")
        \\    let owned t: Tag = Tag { name: "abcdef" }
        \\    var owned d: String = make()
        \\    d = "abcdefg"
        \\    let copy n = 1
        \\    let owned e: String = match n { 0 => make(), _ => "abcdefgh", }
        \\    let copy k: String = "ab"
        \\}
    );
    defer l.deinit();
    try std.testing.expect(!l.diagnostics.hasErrors());
    const m = l.module;
    try std.testing.expect(isStringFromStr(m.findFn("label").?.body.?[0].kind.ret.?));
    const pick = m.findFn("pick").?.body.?[0].kind.ret.?;
    try std.testing.expectEqual(@as(?Ownership, .owned), pick.own);
    try std.testing.expect(!isStringFromStr(pick.kind.match_expr.arms[0].body.*));
    try std.testing.expect(isStringFromStr(pick.kind.match_expr.arms[1].body.*));
    try std.testing.expect(isStringFromStr(m.findFn("reset").?.body.?[0].kind.assign.value));
    const body = m.findFn("main").?.body.?;
    try std.testing.expect(isStringFromStr(body[0].kind.let.value.?));
    try std.testing.expect(isStringFromStr(body[1].kind.let.value.?));
    try std.testing.expect(isStringFromStr(body[2].kind.let.value.?.kind.call.args[0]));
    try std.testing.expect(isStringFromStr(body[3].kind.let.value.?.kind.struct_lit.fields[0]));
    try std.testing.expect(!isStringFromStr(body[4].kind.let.value.?));
    try std.testing.expect(isStringFromStr(body[5].kind.assign.value));
    const e = body[7].kind.let.value.?;
    try std.testing.expectEqual(@as(?Ownership, .owned), e.own);
    try std.testing.expect(isStringFromStr(e.kind.match_expr.arms[1].body.*));
    try std.testing.expect(isStringFromStr(body[8].kind.let.value.?));

    // One bodyless declaration, whatever the number of calls, under a name
    // `findFn` cannot return for a source name.
    try std.testing.expectEqual(@as(usize, 1), countSymbol(m, "cell_string_from_str"));
    const rt = m.findFn("$rt.string_from_str").?;
    try std.testing.expectEqual(Fn.Origin.runtime, rt.origin);
    try std.testing.expect(rt.body == null);
    try std.testing.expectEqual(@as(u32, 1), rt.param_count);
    try std.testing.expectEqual(Ownership.shared, rt.params()[0].ownership);
    try std.testing.expectEqual(.string, rt.params()[0].ty.tag());
    try std.testing.expectEqual(.string, rt.ret.tag());
    try std.testing.expectEqual(Ownership.owned, rt.ret_ownership);
    try std.testing.expect(m.findFn("string_from_str") == null);
}

test "a match with a destination stamps its ownership over a view first arm" {
    var l = try lowerSource(
        \\pub fn f(copy n: Int) {
        \\    let owned s: String = match n { 0 => "a", _ => "b", }
        \\}
    );
    defer l.deinit();
    try std.testing.expect(!l.diagnostics.hasErrors());
    const v = l.module.findFn("f").?.body.?[0].kind.let.value.?;
    try std.testing.expectEqual(@as(?Ownership, .owned), v.own);
    for (v.kind.match_expr.arms) |arm| try std.testing.expect(isStringFromStr(arm.body.*));
}

test "the unannotated let, binding patterns and exclusive destinations are not converted" {
    // C keeps an unannotated `let owned s = "ab"` a view, binding patterns
    // bind the scrutinee as it is, and an `exclusive` destination wants an
    // address a converted temporary does not have. All three are left for
    // the emitters' backstop to refuse, and no runtime declaration appears.
    var l = try lowerSource(
        \\pub fn g(exclusive s: String);
        \\pub fn f() -> Int {
        \\    let owned s = "ab"
        \\    g(exclusive "cd")
        \\    return match "x" { y => 1, }
        \\}
    );
    defer l.deinit();
    const body = l.module.findFn("f").?.body.?;
    try std.testing.expectEqual(.string_const, std.meta.activeTag(body[0].kind.let.value.?.kind));
    try std.testing.expectEqual(.string_const, std.meta.activeTag(body[1].kind.expr.kind.call.args[0].kind));
    try std.testing.expectEqual(.string_const, std.meta.activeTag(body[2].kind.ret.?.kind.match_expr.scrutinee.kind));
    try std.testing.expectEqual(@as(usize, 0), countSymbol(l.module, "cell_string_from_str"));
}

test "a matching source declaration of the runtime symbol is reused" {
    var l = try lowerSource(
        \\pub fn string_from_str(shared v: String) -> String;
        \\pub fn f() -> String { return "ab" }
    );
    defer l.deinit();
    try std.testing.expect(!l.diagnostics.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), countSymbol(l.module, "cell_string_from_str"));
    try std.testing.expectEqual(Fn.Origin.source, l.module.findFn("string_from_str").?.origin);
    try std.testing.expect(l.module.findFn("$rt.string_from_str") == null);
}

test "a conflicting source declaration of the runtime symbol is refused" {
    const cases = [_][]const u8{
        // A body would DEFINE the runtime's symbol.
        \\pub fn string_from_str(shared v: String) -> String { return v }
        \\pub fn f() -> String { return "ab" }
        ,
        \\pub fn string_from_str(owned v: String) -> String;
        \\pub fn f() -> String { return "ab" }
        ,
        \\pub fn string_from_str(shared v: String) -> Int;
        \\pub fn f() -> String { return "ab" }
        ,
        \\pub fn string_from_str(shared v: String, copy n: Int) -> String;
        \\pub fn f() -> String { return "ab" }
        ,
        \\pub fn string_from_str(shared v: String) -> arc String;
        \\pub fn f() -> String { return "ab" }
        ,
    };
    for (cases, 0..) |src, i| {
        var l = try lowerSource(src);
        defer l.deinit();
        var found = false;
        for (l.diagnostics.list.items) |d| {
            if (std.mem.indexOf(u8, d.message, "conflicts with the runtime's cell_string_from_str") != null) found = true;
        }
        if (!found) {
            std.debug.print("case {d} was not refused as a conflict:\n{s}\n", .{ i, src });
            return error.MissingConflict;
        }
        try std.testing.expectEqual(@as(usize, 1), countSymbol(l.module, "cell_string_from_str"));
    }
}

fn isReaderCall(e: Expr, symbol: []const u8, elem: std.meta.Tag(Ty)) bool {
    return e.kind == .call and e.kind.call.symbol != null and
        std.mem.eql(u8, e.kind.call.symbol.?, symbol) and
        e.kind.call.args.len == 2 and e.kind.call.args[1].ty.tag() == .int and
        e.ty.tag() == .optional and e.ty.optional.tag() == elem;
}

test "an index lowers to a call to the runtime reader C calls, declared once" {
    var l = try lowerSource(
        \\pub fn f(shared s: String, shared b: [Byte], shared n: [Int], shared w: [Int32], shared x: [Float], shared y: [Bool]) {
        \\    let copy a = s[0]
        \\    let copy c = b[1]
        \\    let copy d = n[2]
        \\    let copy e = w[3]
        \\    let copy g = x[4]
        \\    let copy h = y[5]
        \\    let copy k = n[-1]
        \\    let copy m = n[1 + 1]
        \\}
    );
    defer l.deinit();
    try std.testing.expect(!l.diagnostics.hasErrors());
    const body = l.module.findFn("f").?.body.?;
    try std.testing.expect(isReaderCall(body[0].kind.let.value.?, "cell_str_byte_at", .byte));
    try std.testing.expect(isReaderCall(body[1].kind.let.value.?, "cell_bytes_at", .byte));
    try std.testing.expect(isReaderCall(body[2].kind.let.value.?, "cell_list_i64_at", .int));
    try std.testing.expect(isReaderCall(body[3].kind.let.value.?, "cell_list_i32_at", .int32));
    try std.testing.expect(isReaderCall(body[4].kind.let.value.?, "cell_list_f64_at", .float));
    try std.testing.expect(isReaderCall(body[5].kind.let.value.?, "cell_list_bool_at", .boolean));
    // The index is `Int` whatever its spelling.
    try std.testing.expect(isReaderCall(body[6].kind.let.value.?, "cell_list_i64_at", .int));
    try std.testing.expect(isReaderCall(body[7].kind.let.value.?, "cell_list_i64_at", .int));
    // Each reader is declared exactly once, however many uses.
    for ([_][]const u8{ "cell_str_byte_at", "cell_bytes_at", "cell_list_i64_at", "cell_list_i32_at", "cell_list_f64_at", "cell_list_bool_at" }) |sym| {
        try std.testing.expectEqual(@as(usize, 1), countSymbol(l.module, sym));
    }
    const rt = l.module.findFn("$rt.list_i64_at").?;
    try std.testing.expectEqual(Fn.Origin.runtime, rt.origin);
    try std.testing.expectEqual(Ownership.shared, rt.params()[0].ownership);
    try std.testing.expectEqual(Ownership.copy, rt.params()[1].ownership);
}

test "a String index base is viewed when it is an owned place, and left alone otherwise" {
    var l = try lowerSource(
        \\pub struct T { owned name: String }
        \\pub fn mk() -> String;
        \\pub fn f(shared v: String, owned o: String, exclusive x: String) {
        \\    let owned s: String = "ab"
        \\    let owned t: T = T { name: "cd" }
        \\    let copy a = s[0]
        \\    let copy b = o[0]
        \\    let copy c = x[0]
        \\    let copy d = t.name[0]
        \\    let copy e = v[0]
        \\    let copy g = "lit"[0]
        \\    let copy h = mk()[0]
        \\}
    );
    defer l.deinit();
    const body = l.module.findFn("f").?.body.?;
    for (body[2..6]) |st| {
        const base = st.kind.let.value.?.kind.call.args[0];
        try std.testing.expectEqual(.string_view, std.meta.activeTag(base.kind));
    }
    for (body[6..8]) |st| {
        const base = st.kind.let.value.?.kind.call.args[0];
        try std.testing.expect(std.meta.activeTag(base.kind) != .string_view);
        try std.testing.expectEqual(@as(?Ownership, .shared), base.own);
    }
    // An owned temporary stays owning, for the emitters' `fits` to refuse:
    // a view of it would outlive its only owner.
    const tmp = body[8].kind.let.value.?.kind.call.args[0];
    try std.testing.expectEqual(@as(?Ownership, .owned), tmp.own);
}

test "an index with no reader, or over an arc base, is cannot lower" {
    const cases = [_][]const u8{
        \\pub fn f(shared xs: [String]) { let copy a = xs[0] }
        ,
        \\pub fn f(shared xs: [Int8]) { let copy a = xs[0] }
        ,
        \\pub fn f(copy n: Int) { let copy a = n[0] }
        ,
        \\pub fn f(arc xs: [Int]) { let copy a = xs[0] }
        ,
        \\pub fn f(arc s: String) { let copy a = s[0] }
        ,
    };
    for (cases, 0..) |src, i| {
        var l = try lowerSource(src);
        defer l.deinit();
        var found = false;
        for (l.diagnostics.list.items) |d| {
            if (std.mem.indexOf(u8, d.message, "cannot lower: indexing") != null) found = true;
        }
        if (!found) {
            std.debug.print("case {d} was not refused:\n{s}\n", .{ i, src });
            return error.MissingRefusal;
        }
    }
}

test "scalar list literals lower to ordered typed pushes and a nondroppable scratch" {
    var l = try lowerSource(
        \\pub fn f() {
        \\    let owned ints: [Int] = [1, 2, 3]
        \\    let owned bytes: [Byte] = []
        \\    let owned bools = [true, false]
        \\}
    );
    defer l.deinit();
    try std.testing.expect(!l.diagnostics.hasErrors());
    const f = l.module.findFn("f").?;
    const body = f.body.?;
    const ints = body[0].kind.let.value.?;
    try std.testing.expectEqual(.block, std.meta.activeTag(ints.kind));
    try std.testing.expectEqual(@as(usize, 4), ints.kind.block.stmts.len);
    const scratch = ints.kind.block.stmts[0].kind.let.slot;
    try std.testing.expect(!f.bindings[scratch].droppable);
    try std.testing.expectEqual(Ownership.owned, f.bindings[scratch].ownership);
    for (ints.kind.block.stmts[1..], 1..) |stmt, index| {
        const call = stmt.kind.expr.kind.call;
        try std.testing.expectEqualStrings("cell_list_i64_push", call.symbol.?);
        try std.testing.expectEqual(@as(i64, @intCast(index)), call.args[1].kind.int_const);
    }
    try std.testing.expectEqual(scratch, ints.kind.block.tail.?.kind.ref);
    try std.testing.expectEqual(.list_lit, std.meta.activeTag(body[1].kind.let.value.?.kind));
    try std.testing.expectEqual(.byte, body[1].kind.let.value.?.ty.list.tag());
    const bools = body[2].kind.let.value.?;
    try std.testing.expectEqualStrings("cell_list_bool_push", bools.kind.block.stmts[1].kind.expr.kind.call.symbol.?);
    try std.testing.expectEqualStrings("cell_list_bool_push", bools.kind.block.stmts[2].kind.expr.kind.call.symbol.?);
    try std.testing.expectEqual(@as(usize, 1), countSymbol(l.module, "cell_list_i64_push"));
    try std.testing.expectEqual(@as(usize, 1), countSymbol(l.module, "cell_list_bool_push"));
}

test "unsupported list elements refuse once before an emitter sees a nonempty literal" {
    const cases = [_][]const u8{
        \\pub fn f() { let owned xs: [String] = ["a"] }
        ,
        \\pub fn f() { let owned xs: [[Int]] = [[1]] }
        ,
        \\pub fn f() { let owned xs: [Int8] = [1] }
        ,
    };
    for (cases) |source| {
        var l = try lowerSource(source);
        defer l.deinit();
        try std.testing.expectEqual(@as(usize, 1), l.diagnostics.list.items.len);
        try std.testing.expect(std.mem.indexOf(u8, l.diagnostics.list.items[0].message, "list literal whose element has no runtime push") != null);
        const init = l.module.findFn("f").?.body.?[0].kind.let.value.?;
        try std.testing.expectEqual(.list_lit, std.meta.activeTag(init.kind));
        try std.testing.expectEqual(@as(usize, 0), init.kind.list_lit.len);
    }
}

test "pattern bindings are aliases and never droppable owners" {
    var l = try lowerSource(
        \\pub fn f(copy n: Int, copy r: Result<Int, Int>, copy o: Int?) {
        \\    let copy a = match n { x => x, }
        \\    let copy b = match r { Ok(v) => v, Err(e) => e, }
        \\    let copy c = match o { Some(v) => v, None => 0, }
        \\}
    );
    defer l.deinit();
    try std.testing.expect(!l.diagnostics.hasErrors());
    const f = l.module.findFn("f").?;
    for (f.bindings[f.param_count..]) |binding| {
        if (std.mem.eql(u8, binding.name, "x") or std.mem.eql(u8, binding.name, "v") or std.mem.eql(u8, binding.name, "e")) {
            try std.testing.expect(!binding.droppable);
        }
    }
}

test "a matching reader declaration is reused and a conflicting one is refused as an index's" {
    {
        var l = try lowerSource(
            \\pub fn list_i64_at(shared xs: [Int], copy index: Int) -> Int?;
            \\pub fn f(shared n: [Int]) -> Int? { return n[0] }
        );
        defer l.deinit();
        try std.testing.expect(!l.diagnostics.hasErrors());
        try std.testing.expectEqual(@as(usize, 1), countSymbol(l.module, "cell_list_i64_at"));
        try std.testing.expect(l.module.findFn("$rt.list_i64_at") == null);
    }
    {
        var l = try lowerSource(
            \\pub fn list_i64_at(owned xs: [Int], copy index: Int) -> Int?;
            \\pub fn f(shared n: [Int]) -> Int? { return n[0] }
        );
        defer l.deinit();
        var found = false;
        for (l.diagnostics.list.items) |d| {
            if (std.mem.indexOf(u8, d.message, "conflicts with the runtime's cell_list_i64_at, which a String conversion or an index") != null) found = true;
        }
        try std.testing.expect(found);
    }
}

test "a labelled jump lowers to how many loops it leaves beyond the innermost" {
    var l = try lowerSource(
        \\pub fn f(copy n: Int) {
        \\    outer: while n > 0 {
        \\        mid: loop {
        \\            loop {
        \\                break :outer
        \\                continue :mid
        \\                break
        \\                continue
        \\            }
        \\        }
        \\    }
        \\}
    );
    defer l.deinit();
    try std.testing.expect(!l.diagnostics.hasErrors());
    const outer = l.module.findFn("f").?.body.?[0].kind.while_loop;
    const mid = outer.body[0].kind.while_loop;
    const inner = mid.body[0].kind.while_loop;
    try std.testing.expectEqual(@as(u32, 2), inner.body[0].kind.brk.depth);
    try std.testing.expectEqual(@as(u32, 1), inner.body[1].kind.cont);
    try std.testing.expectEqual(@as(u32, 0), inner.body[2].kind.brk.depth);
    try std.testing.expectEqual(@as(u32, 0), inner.body[3].kind.cont);
}

test "a label naming the innermost loop lowers exactly like a plain jump" {
    var l = try lowerSource(
        \\pub fn f() {
        \\    here: loop {
        \\        break :here
        \\    }
        \\}
    );
    defer l.deinit();
    try std.testing.expect(!l.diagnostics.hasErrors());
    const w = l.module.findFn("f").?.body.?[0].kind.while_loop;
    try std.testing.expectEqual(@as(u32, 0), w.body[0].kind.brk.depth);
}

test "an unresolvable label is cannot lower, never a guess at the innermost loop" {
    // Unchecked input: typecheck refuses this before any backend runs.
    var l = try lowerSource(
        \\pub fn f() {
        \\    loop {
        \\        break :nowhere
        \\    }
        \\}
    );
    defer l.deinit();
    try std.testing.expect(l.diagnostics.hasErrors());
    var found = false;
    for (l.diagnostics.list.items) |d| {
        if (std.mem.eql(u8, d.message, "cannot lower: no enclosing loop is labelled 'nowhere'")) found = true;
    }
    try std.testing.expect(found);
}
