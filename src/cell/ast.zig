const std = @import("std");
const Io = std.Io;

pub const Span = struct {
    start: u32,
    end: u32,
    line: u32,
    column: u32,
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

pub const Expr = union(enum) {
    ident: []const u8,
    int: i64,
    float: f64,
    string: []const u8,
    bool: bool,
    call: struct { callee: *Expr, args: []Expr },
    binary: struct { op: BinaryOp, left: *Expr, right: *Expr },
    unary: struct { op: UnaryOp, operand: *Expr },
    block: []Stmt,
    if_expr: struct { cond: *Expr, then_body: *Expr, else_body: ?*Expr },
    match_expr: struct { scrutinee: *Expr, arms: []MatchArm },
};

pub const BinaryOp = enum { add, sub, mul, div, eq, ne, lt, le, gt, ge, and_op, or_op };
pub const UnaryOp = enum { neg, not, ref_shared, ref_exclusive };

pub const MatchArm = struct {
    pattern: []const u8,
    body: *Expr,
};

pub const Stmt = union(enum) {
    let: struct {
        name: []const u8,
        ownership: Ownership,
        mutable: bool,
        ty: ?TypeExpr,
        value: ?Expr,
    },
    expr: Expr,
    return_stmt: ?Expr,
    assign: struct { name: []const u8, value: Expr },
};

pub const Item = union(enum) {
    fn_def: FnDef,
    struct_def: StructDef,
    enum_def: EnumDef,
    use_decl: []const u8,
};

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
            switch (item) {
                .fn_def => |f| try writer.print("  fn {s}({d} params) public={}\n", .{ f.name, f.params.len, f.is_public }),
                .struct_def => |s| try writer.print("  struct {s} ({d} fields)\n", .{ s.name, s.fields.len }),
                .enum_def => |e| try writer.print("  enum {s} ({d} variants)\n", .{ e.name, e.variants.len }),
                .use_decl => |u| try writer.print("  use {s}\n", .{u}),
            }
        }
    }
};
