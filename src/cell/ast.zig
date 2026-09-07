const std = @import("std");
const Io = std.Io;

/// A half-open byte range in a single source buffer, plus the 1-based
/// line/column of its first byte so a diagnostic can be printed without
/// rescanning the file.
///
/// Every `Expr`, `Stmt`, `Item` and `Pattern` is a `{ kind, span }` wrapper
/// rather than a bare union. The alternative was a side table keyed by node
/// index, which is cheaper per node but requires an index-based arena AST;
/// this tree is pointer-based, so a side table would need a stable key that
/// does not exist. The wrapper costs 16 bytes per node and makes `node.span`
/// available everywhere without threading a table through every function.
pub const Span = struct {
    start: u32,
    end: u32,
    line: u32,
    column: u32,

    /// A span that points nowhere. Use only for synthesized nodes.
    pub const none: Span = .{ .start = 0, .end = 0, .line = 0, .column = 0 };

    /// Cover both spans, keeping the start position of `a`.
    pub fn merge(a: Span, b: Span) Span {
        return .{
            .start = a.start,
            .end = @max(a.end, b.end),
            .line = a.line,
            .column = a.column,
        };
    }
};

/// Ownership / lifetime annotation inspired by Rust + Swift.
pub const Ownership = enum {
    /// Unique mutable owner (Rust `T`, Zig owned)
    owned,
    /// Shared immutable borrow (Rust `&T`, Swift `borrowing`)
    shared,
    /// Unique mutable borrow (Rust `&mut T`, Swift `inout`)
    exclusive,
    /// Copyable value (Swift value types, Zig by-value)
    copy,
    /// Reference-counted shared (Swift class / Arc)
    arc,
};

pub const TypeExpr = union(enum) {
    name: []const u8,
    optional: *TypeExpr,
    list: *TypeExpr,
    result: struct { ok: *TypeExpr, err: *TypeExpr },
    ref: struct { ownership: Ownership, inner: *TypeExpr },
    unit,
};

pub const BinaryOp = enum { add, sub, mul, div, eq, ne, lt, le, gt, ge, and_op, or_op };
pub const UnaryOp = enum { neg, not, ref_shared, ref_exclusive };

/// One `name: value` initializer inside a struct literal.
pub const FieldInit = struct {
    name: []const u8,
    value: Expr,
    span: Span,
};

pub const Expr = struct {
    kind: Kind,
    span: Span,

    pub const Kind = union(enum) {
        ident: []const u8,
        int: i64,
        float: f64,
        string: []const u8,
        bool: bool,
        call: struct { callee: *Expr, args: []Expr },
        binary: struct { op: BinaryOp, left: *Expr, right: *Expr },
        unary: struct { op: UnaryOp, operand: *Expr },
        /// Written ownership prefix: `shared buf`, `owned x`, `exclusive y`.
        annotated: struct { ownership: Ownership, value: *Expr },
        /// `base.name`
        field: struct { base: *Expr, name: []const u8 },
        /// `Name { a: 1, b: 2 }`
        struct_lit: struct { name: []const u8, fields: []FieldInit },
        /// `[a, b, c]` or `[]`
        list_lit: []Expr,
        block: []Stmt,
        if_expr: struct { cond: *Expr, then_body: *Expr, else_body: ?*Expr },
        match_expr: struct { scrutinee: *Expr, arms: []MatchArm },
    };
};

/// A structured match pattern. Enum variants carry no payload in this
/// grammar, so there are no subpatterns to nest.
pub const Pattern = struct {
    kind: Kind,
    span: Span,

    pub const Kind = union(enum) {
        /// `_`
        wildcard,
        /// `name`, binds the scrutinee
        binding: []const u8,
        /// `Red` or `Color.Red`
        enum_variant: struct { enum_name: ?[]const u8, variant: []const u8 },
        int: i64,
        float: f64,
        string: []const u8,
        bool: bool,
    };
};

pub const MatchArm = struct {
    pattern: Pattern,
    /// `pattern if cond => body`. An extra condition the arm must satisfy on
    /// top of matching the pattern. Null when no guard was written.
    ///
    /// A guard makes an arm conditional, so an arm that WOULD have been a
    /// catch-all stops being one: `_ if c => ...` can fail. Exhaustiveness has
    /// to account for that or a match with only guarded arms would lose its
    /// panic.
    guard: ?*Expr = null,
    body: *Expr,
    span: Span,
};

pub const Stmt = struct {
    kind: Kind,
    span: Span,

    pub const Kind = union(enum) {
        let: struct {
            name: []const u8,
            ownership: Ownership,
            mutable: bool,
            ty: ?TypeExpr,
            value: ?Expr,
        },
        expr: Expr,
        return_stmt: ?Expr,
        /// `target = value`, where `target` is an ident or a field chain.
        assign: struct { target: Expr, value: Expr },
        /// `while cond { ... }`.
        ///
        /// A STATEMENT, not an expression, unlike `if`. An `if` is an
        /// expression because it produces a value from its branches; a loop
        /// produces nothing, and modelling it as an expression would force a
        /// unit value this language cannot name (SPEC 3.5: `()` does not parse
        /// in type position).
        while_stmt: struct { cond: Expr, body: []Stmt },
        break_stmt,
        continue_stmt,
    };
};

pub const Item = struct {
    kind: Kind,
    span: Span,

    pub const Kind = union(enum) {
        fn_def: FnDef,
        struct_def: StructDef,
        enum_def: EnumDef,
        use_decl: []const u8,
    };
};

/// The name of the binding an expression is rooted at, if any:
/// `buf` for `buf`, `buf` for `buf.len.bytes`, null for anything else.
/// Assignment checking needs the root binding, not the whole path.
pub fn rootName(expr: *const Expr) ?[]const u8 {
    return switch (expr.kind) {
        .ident => |n| n,
        .field => |f| rootName(f.base),
        .annotated => |a| rootName(a.value),
        else => null,
    };
}

pub const FnDef = struct {
    name: []const u8,
    params: []Param,
    return_type: ?TypeExpr,
    body: ?[]Stmt,
    is_public: bool,
};

pub const Param = struct {
    name: []const u8,
    ownership: Ownership,
    ty: TypeExpr,
};

pub const StructDef = struct {
    name: []const u8,
    fields: []Field,
    is_public: bool,
};

pub const Field = struct {
    name: []const u8,
    ty: TypeExpr,
    ownership: Ownership,
};

pub const EnumDef = struct {
    name: []const u8,
    variants: [][]const u8,
    is_public: bool,
};

pub const Module = struct {
    path: []const u8,
    items: []Item,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Module, allocator: std.mem.Allocator) void {
        _ = allocator;
        _ = self;
    }

    pub fn dump(self: *const Module, writer: *Io.Writer) !void {
        try writer.print("module {s}\n", .{self.path});
        for (self.items) |item| {
            try writer.print("  {d}:{d} ", .{ item.span.line, item.span.column });
            switch (item.kind) {
                .fn_def => |f| try writer.print("fn {s}({d} params) public={}\n", .{ f.name, f.params.len, f.is_public }),
                .struct_def => |s| try writer.print("struct {s} ({d} fields)\n", .{ s.name, s.fields.len }),
                .enum_def => |e| try writer.print("enum {s} ({d} variants)\n", .{ e.name, e.variants.len }),
                .use_decl => |u| try writer.print("use {s}\n", .{u}),
            }
        }
    }
};

test "Span.merge covers both operands and keeps the left start" {
    const a: Span = .{ .start = 4, .end = 8, .line = 2, .column = 3 };
    const b: Span = .{ .start = 11, .end = 20, .line = 3, .column = 1 };
    const m = Span.merge(a, b);
    try std.testing.expectEqual(@as(u32, 4), m.start);
    try std.testing.expectEqual(@as(u32, 20), m.end);
    try std.testing.expectEqual(@as(u32, 2), m.line);
    try std.testing.expectEqual(@as(u32, 3), m.column);
}

test "rootName walks a field chain down to its base binding" {
    var base: Expr = .{ .kind = .{ .ident = "buf" }, .span = .none };
    var mid: Expr = .{ .kind = .{ .field = .{ .base = &base, .name = "len" } }, .span = .none };
    const outer: Expr = .{ .kind = .{ .field = .{ .base = &mid, .name = "bytes" } }, .span = .none };

    try std.testing.expectEqualStrings("buf", rootName(&outer).?);
    try std.testing.expectEqualStrings("buf", rootName(&base).?);

    const lit: Expr = .{ .kind = .{ .int = 7 }, .span = .none };
    try std.testing.expect(rootName(&lit) == null);
}
