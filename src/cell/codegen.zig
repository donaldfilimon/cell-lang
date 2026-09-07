//! C emission for the Cell language.
//!
//! The output targets the ABI that `runtime/cell_rt.h` documents in its
//! opening block, so emitted code compiles with `-std=c11 -Wall -Wextra` and
//! links against `runtime/cell_rt.c`. Three rules drive everything here:
//!
//!   1. Ownership selects the C type, it is not a comment. `shared String` is
//!      `cell_str_t`, `exclusive Buffer` is `cell_Buffer *`, and a primitive
//!      stays by value in every mode because cell_rt.h section 1 says so.
//!   2. Every Cell symbol is mangled `cell_<name>`, at the definition AND at
//!      the call, so `print(x)` reaches the runtime's `cell_print`.
//!   3. Call sites lower against the callee's declared parameter ownership.
//!      A written prefix such as `grow(exclusive buf, ...)` is kept on the
//!      AST as `.annotated`; emission still ignores that wrapper and uses
//!      the callee signature to decide that the argument is passed as `&buf`.
//!
//! Expression-position `if`, `match`, `block`, and non-empty list literals
//! lower to a GNU statement expression `({ ... })`. That is a Clang and GCC
//! extension rather than ISO C11: the tradeoff is that MSVC cannot compile
//! such a module, bought against preserving evaluation order and nesting
//! without a hoisting pass over every enclosing statement. Statement-position
//! `if` and `match`, which is every occurrence in `examples/`, stay ISO C.
//!
//! There is no type checker feeding this stage, so types are inferred locally
//! from parameter and field declarations, `let` annotations, literals, and
//! callee return types. An expression whose type cannot be recovered lowers to
//! `void*`, which is visible in the output rather than silently wrong.

const std = @import("std");
const ast = @import("ast.zig");
const Io = std.Io;

/// Anything an emit step can fail with: a writer failure or an arena failure.
pub const EmitError = Io.Writer.Error || std.mem.Allocator.Error;

const Alloc = std.mem.Allocator.Error;

/// The value class a lowered C type belongs to. Ownership picks the spelling,
/// the shape decides how the value may be passed, borrowed, and accessed.
pub const Shape = enum {
    unit,
    integer,
    floating,
    boolean,
    byte,
    /// cell_str_t, a borrowed view
    str,
    /// cell_string_t, an owning heap string
    string,
    /// cell_slice_t
    slice,
    /// cell_arc_t
    arc,
    /// cell_opt_*_t
    optional,
    /// cell_result_t
    result,
    /// a Cell struct
    record,
    /// a Cell enum, an int32_t typedef
    enumeration,
    /// no declaration in scope: void*
    unknown,

    /// Primitives pass and return by value in EVERY ownership mode
    /// (cell_rt.h section 1), so no keyword may turn one into a pointer.
    /// An enum is a distinct integer type, so it counts as one.
    pub fn isPrimitive(self: Shape) bool {
        return switch (self) {
            .unit, .integer, .floating, .boolean, .byte, .enumeration => true,
            else => false,
        };
    }
};

/// A lowered C type: its spelling plus enough classification to decide how a
/// value of it is passed, borrowed, and selected from.
pub const CType = struct {
    text: []const u8,
    shape: Shape,
    /// True when `text` already ends in `*`.
    pointer: bool = false,
    /// The Cell name, for `record` and `enumeration`.
    name: []const u8 = "",

    pub const unknown: CType = .{ .text = "void*", .shape = .unknown };
    pub const void_type: CType = .{ .text = "void", .shape = .unit };
    pub const int64: CType = .{ .text = "int64_t", .shape = .integer };
    pub const float64: CType = .{ .text = "double", .shape = .floating };
    pub const boolean: CType = .{ .text = "bool", .shape = .boolean };
    pub const str: CType = .{ .text = "cell_str_t", .shape = .str };
    pub const string: CType = .{ .text = "cell_string_t", .shape = .string };
    pub const slice: CType = .{ .text = "cell_slice_t", .shape = .slice };
    pub const arc: CType = .{ .text = "cell_arc_t", .shape = .arc };
    pub const result: CType = .{ .text = "cell_result_t", .shape = .result };
};

/// One binding visible while emitting a function body.
const Local = struct {
    name: []const u8,
    ty: CType,
};

/// A resolved call target. `symbol` is null when the callee is a computed
/// expression rather than a name.
const Callee = struct {
    symbol: ?[]const u8,
    def: ?ast.FnDef,
};

/// One `CELL_DEFINE_OPTIONAL` instantiation the module needs.
const OptionalInst = struct {
    /// Macro base, for example `cell_opt_Point`.
    base: []const u8,
    /// Element spelling, for example `cell_Point`.
    elem: []const u8,
    /// False for the instances cell_rt.h already defines.
    generated: bool,
};

/// Emit C for a Cell module.
pub const Generator = struct {
    allocator: std.mem.Allocator,
    writer: *Io.Writer,

    /// Scratch for composed type names and temporaries. Lives for exactly one
    /// `emitModule` call, so callers keep the two-argument `init`.
    arena: std.mem.Allocator = undefined,
    module: *const ast.Module = undefined,
    locals: std.ArrayList(Local) = .empty,
    temp_counter: usize = 0,
    /// Name of the function being emitted, used in panic messages.
    current_fn: []const u8 = "",

    pub fn init(allocator: std.mem.Allocator, writer: *Io.Writer) Generator {
        return .{
            .allocator = allocator,
            .writer = writer,
        };
    }

    // ── module ──────────────────────────────────────────────────────────

    pub fn emitModule(self: *Generator, module: *const ast.Module) EmitError!void {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();

        self.arena = arena_state.allocator();
        self.module = module;
        self.locals = .empty;
        self.temp_counter = 0;

        const out = self.writer;
        try out.writeAll("// Generated by cell.\n");
        try out.writeAll("// Target ABI: runtime/cell_rt.h (callable from Zig / Swift / C++).\n");
        try out.print("// source: {s}\n\n", .{module.path});
        try out.writeAll("#include \"cell_rt.h\"\n\n");

        for (module.items) |item| {
            if (item.kind == .use_decl) try out.print("// use {s}\n", .{item.kind.use_decl});
        }

        for (module.items) |item| {
            switch (item.kind) {
                .struct_def => |s| try self.emitStruct(s),
                .enum_def => |e| try self.emitEnum(e),
                else => {},
            }
        }

        try self.emitOptionalInstances();

        var wrote_prototype = false;
        for (module.items) |item| {
            if (item.kind != .fn_def) continue;
            try self.emitPrototype(item.kind.fn_def);
            wrote_prototype = true;
        }
        if (wrote_prototype) try out.writeAll("\n");

        for (module.items) |item| {
            if (item.kind != .fn_def) continue;
            if (item.kind.fn_def.body == null) continue;
            try self.emitFn(item.kind.fn_def);
        }

        try self.emitEntryPoint();
    }

    /// `CELL_DEFINE_OPTIONAL` lines for every optional the module names that
    /// cell_rt.h does not already instantiate. They come after the struct
    /// typedefs because an optional over a struct needs that struct first.
    fn emitOptionalInstances(self: *Generator) EmitError!void {
        var seen: std.ArrayList(OptionalInst) = .empty;
        for (self.module.items) |item| {
            switch (item.kind) {
                .fn_def => |f| {
                    for (f.params) |p| try self.collectOptionals(&p.ty, &seen);
                    if (f.return_type) |rt| try self.collectOptionals(&rt, &seen);
                    if (f.body) |body| try self.collectOptionalsInStmts(body, &seen);
                },
                .struct_def => |s| for (s.fields) |fld| try self.collectOptionals(&fld.ty, &seen),
                else => {},
            }
        }
        if (seen.items.len == 0) return;
        for (seen.items) |inst| {
            try self.writer.print("CELL_DEFINE_OPTIONAL({s}, {s})\n", .{ inst.base, inst.elem });
        }
        try self.writer.writeAll("\n");
    }

    fn collectOptionals(self: *Generator, ty: *const ast.TypeExpr, seen: *std.ArrayList(OptionalInst)) Alloc!void {
        switch (ty.*) {
            .optional => |inner| {
                const inst = try self.optionalInstance(inner);
                if (inst.generated) {
                    for (seen.items) |existing| {
                        if (std.mem.eql(u8, existing.base, inst.base)) break;
                    } else try seen.append(self.arena, inst);
                }
                try self.collectOptionals(inner, seen);
            },
            .list => |inner| try self.collectOptionals(inner, seen),
            .ref => |r| try self.collectOptionals(r.inner, seen),
            .result => |r| {
                try self.collectOptionals(r.ok, seen);
                try self.collectOptionals(r.err, seen);
            },
            .name, .unit => {},
        }
    }

    fn collectOptionalsInStmts(self: *Generator, stmts: []const ast.Stmt, seen: *std.ArrayList(OptionalInst)) Alloc!void {
        for (stmts) |s| {
            switch (s.kind) {
                .let => |l| if (l.ty) |t| try self.collectOptionals(&t, seen),
                else => {},
            }
        }
    }

    /// A C `main` that calls the Cell `main`, so a module with an entry point
    /// links into an executable. Without this there is no path from `.cell` to
    /// a program.
    fn emitEntryPoint(self: *Generator) EmitError!void {
        const def = self.findFn("main") orelse return;
        if (def.body == null) return;
        if (def.params.len != 0) return;

        const out = self.writer;
        try out.writeAll("// C entry point for the Cell `main`.\n");
        try out.writeAll("int main(void) {\n");
        const ret = if (def.return_type) |rt| try self.lowerType(&rt, .owned) else CType.void_type;
        if (ret.shape == .integer) {
            try out.writeAll("  return (int)cell_main();\n");
        } else {
            try out.writeAll("  cell_main();\n  return 0;\n");
        }
        try out.writeAll("}\n");
    }

    // ── items ───────────────────────────────────────────────────────────

    fn emitStruct(self: *Generator, s: ast.StructDef) EmitError!void {
        const out = self.writer;
        try out.print("typedef struct cell_{s} {{\n", .{s.name});
        for (s.fields) |f| {
            const ty = try self.lowerType(&f.ty, f.ownership);
            try out.writeAll("  ");
            try self.writeDecl(ty, f.name);
            try out.print("; // {s}\n", .{@tagName(f.ownership)});
        }
        try out.print("}} cell_{s};\n\n", .{s.name});
    }

    /// A payload-free Cell enum is a distinct integer type of width int32_t
    /// (cell_rt.h section 6). A bare `typedef enum` has implementation defined
    /// width, so the typedef is explicit and the constants live in an
    /// anonymous enum. They are enum constants rather than `static const`
    /// because an unused `static const` trips -Wunused-const-variable in C.
    fn emitEnum(self: *Generator, e: ast.EnumDef) EmitError!void {
        const out = self.writer;
        try out.print("typedef int32_t cell_{s};\n", .{e.name});
        if (e.variants.len == 0) {
            try out.writeAll("\n");
            return;
        }
        try out.writeAll("enum {\n");
        for (e.variants, 0..) |v, i| {
            try out.print("  cell_{s}_{s} = {d},\n", .{ e.name, v, i });
        }
        try out.writeAll("};\n\n");
    }

    fn emitPrototype(self: *Generator, f: ast.FnDef) EmitError!void {
        if (f.is_public) try self.writer.writeAll("// export\n");
        try self.writeSignature(f);
        try self.writer.writeAll(";\n");
    }

    /// The C symbol a function definition or declaration carries. Mangling is
    /// `cell_<name>`, except that a BODYLESS declaration of a runtime
    /// intrinsic takes the runtime's own spelling: a declaration means "this
    /// symbol comes from elsewhere at link time", and `assert(cond, msg)`
    /// lives there as `cell_assert_msg`. A function with a body is never
    /// renamed, because that would define over a runtime symbol.
    fn symbolFor(self: *Generator, f: ast.FnDef) Alloc![]const u8 {
        if (f.body == null) {
            if (intrinsicSymbol(f.name, f.params.len)) |sym| return sym;
        }
        return try std.fmt.allocPrint(self.arena, "cell_{s}", .{f.name});
    }

    fn emitFn(self: *Generator, f: ast.FnDef) EmitError!void {
        const body = f.body orelse return;
        const out = self.writer;

        self.locals.clearRetainingCapacity();
        self.current_fn = f.name;
        for (f.params) |p| {
            try self.pushLocal(p.name, try self.lowerType(&p.ty, p.ownership));
        }

        try self.writeSignature(f);
        try out.writeAll(" {\n");

        // -Wunused-parameter is part of -Wextra, and a Cell body is free to
        // ignore a parameter, so name the unused ones explicitly.
        for (f.params) |p| {
            if (stmtsUse(body, p.name)) continue;
            try out.print("  (void){s};\n", .{p.name});
        }

        try self.emitStmts(body, 1);
        try out.writeAll("}\n\n");
        self.locals.clearRetainingCapacity();
    }

    fn writeSignature(self: *Generator, f: ast.FnDef) EmitError!void {
        const out = self.writer;
        const ret = if (f.return_type) |rt| try self.lowerType(&rt, .owned) else CType.void_type;
        const symbol = try self.symbolFor(f);
        if (ret.pointer) {
            try out.print("{s}{s}(", .{ ret.text, symbol });
        } else {
            try out.print("{s} {s}(", .{ ret.text, symbol });
        }
        if (f.params.len == 0) {
            // C11: an empty list is an unprototyped declaration, not a
            // zero-argument one.
            try out.writeAll("void)");
            return;
        }
        for (f.params, 0..) |p, i| {
            if (i > 0) try out.writeAll(", ");
            try self.writeDecl(try self.lowerType(&p.ty, p.ownership), p.name);
        }
        try out.writeAll(")");
    }

    fn writeDecl(self: *Generator, ty: CType, name: []const u8) EmitError!void {
        if (ty.pointer) {
            try self.writer.print("{s}{s}", .{ ty.text, name });
        } else {
            try self.writer.print("{s} {s}", .{ ty.text, name });
        }
    }

    // ── statements ──────────────────────────────────────────────────────

    fn emitStmts(self: *Generator, stmts: []const ast.Stmt, indent: usize) EmitError!void {
        const mark = self.locals.items.len;
        defer self.locals.shrinkRetainingCapacity(mark);
        for (stmts, 0..) |_, i| {
            try self.emitStmt(&stmts[i], stmts[i + 1 ..], indent);
        }
    }

    fn emitStmt(self: *Generator, stmt: *const ast.Stmt, rest: []const ast.Stmt, indent: usize) EmitError!void {
        const out = self.writer;
        switch (stmt.kind) {
            .while_stmt => |w| {
                try self.writeIndent(indent);
                try out.writeAll("while (");
                try self.emitExpr(&w.cond, indent);
                try out.writeAll(") {\n");
                try self.emitStmts(w.body, indent + 4);
                try self.writeIndent(indent);
                try out.writeAll("}\n");
            },
            .break_stmt => {
                try self.writeIndent(indent);
                try out.writeAll("break;\n");
            },
            .continue_stmt => {
                try self.writeIndent(indent);
                try out.writeAll("continue;\n");
            },
            .let => |l| {
                const ty = try self.letType(l.ty, l.value, l.ownership);
                try self.writeIndent(indent);
                try self.writeDecl(ty, l.name);
                if (l.value) |v| {
                    try out.writeAll(" = ");
                    try self.emitArgLike(&v, ty, indent);
                }
                try out.writeAll(";\n");
                try self.pushLocal(l.name, ty);
                // -Wunused-variable is part of -Wall.
                if (!stmtsUse(rest, l.name)) {
                    try self.writeIndent(indent);
                    try out.print("(void){s};\n", .{l.name});
                }
            },
            .return_stmt => |opt| {
                try self.writeIndent(indent);
                try out.writeAll("return");
                if (opt) |v| {
                    try out.writeAll(" ");
                    try self.emitExpr(&v, indent);
                }
                try out.writeAll(";\n");
            },
            .expr => |e| switch (e.kind) {
                .if_expr => |i| try self.emitIfStmt(i, indent),
                .match_expr => |m| try self.emitMatchStmt(m, indent),
                .block => |b| {
                    try self.writeIndent(indent);
                    try out.writeAll("{\n");
                    try self.emitStmts(b, indent + 1);
                    try self.writeIndent(indent);
                    try out.writeAll("}\n");
                },
                .annotated => |a| try self.emitEffect(a.value, indent),
                else => {
                    try self.writeIndent(indent);
                    try self.emitExpr(&e, indent);
                    try out.writeAll(";\n");
                },
            },
            .assign => |a| {
                try self.writeIndent(indent);
                try self.emitExpr(&a.target, indent);
                try out.writeAll(" = ");
                const want = try self.inferExpr(&a.target);
                try self.emitArgLike(&a.value, want, indent);
                try out.writeAll(";\n");
            },
        }
    }

    /// The declared type of a `let`. An annotation wins; otherwise the
    /// initializer decides; otherwise int64_t, matching the language's default
    /// integer.
    fn letType(self: *Generator, ann: ?ast.TypeExpr, value: ?ast.Expr, own: ast.Ownership) Alloc!CType {
        if (ann) |t| return try self.lowerType(&t, own);
        if (value) |v| {
            const inferred = try self.inferExpr(&v);
            if (inferred.shape != .unknown and inferred.shape != .unit) return inferred;
        }
        return CType.int64;
    }

    fn emitIfStmt(self: *Generator, i: anytype, indent: usize) EmitError!void {
        const out = self.writer;
        try self.writeIndent(indent);
        try out.writeAll("if (");
        try self.emitExpr(i.cond, indent);
        try out.writeAll(") ");
        try self.emitBranchStmt(i.then_body, indent);
        if (i.else_body) |eb| {
            try out.writeAll(" else ");
            try self.emitBranchStmt(eb, indent);
        }
        try out.writeAll("\n");
    }

    /// One branch of a statement-position `if`. A nested `if` becomes
    /// `else if` rather than a braced block.
    fn emitBranchStmt(self: *Generator, e: *const ast.Expr, indent: usize) EmitError!void {
        const out = self.writer;
        switch (e.kind) {
            .block => |stmts| {
                try out.writeAll("{\n");
                try self.emitStmts(stmts, indent + 1);
                try self.writeIndent(indent);
                try out.writeAll("}");
            },
            .if_expr => |i| {
                try out.writeAll("if (");
                try self.emitExpr(i.cond, indent);
                try out.writeAll(") ");
                try self.emitBranchStmt(i.then_body, indent);
                if (i.else_body) |eb| {
                    try out.writeAll(" else ");
                    try self.emitBranchStmt(eb, indent);
                }
            },
            .annotated => |a| try self.emitBranchStmt(a.value, indent),
            else => {
                try out.writeAll("{\n");
                try self.writeIndent(indent + 1);
                try self.emitExpr(e, indent + 1);
                try out.writeAll(";\n");
                try self.writeIndent(indent);
                try out.writeAll("}");
            },
        }
    }

    fn emitMatchStmt(self: *Generator, m: anytype, indent: usize) EmitError!void {
        try self.emitMatch(m, null, indent);
    }

    /// Lower a `match` to a scrutinee temporary plus an if/else chain. When
    /// `dest` is set every arm assigns into it instead of running for effect.
    fn emitMatch(self: *Generator, m: anytype, dest: ?[]const u8, indent: usize) EmitError!void {
        const out = self.writer;
        const scrut_ty = try self.inferExpr(m.scrutinee);
        const temp = try self.nextTemp();

        try self.writeIndent(indent);
        try out.writeAll("{\n");
        try self.writeIndent(indent + 1);
        try self.writeDecl(scrut_ty, temp);
        try out.writeAll(" = ");
        try self.emitExpr(m.scrutinee, indent + 1);
        try out.writeAll(";\n");

        var tested: usize = 0;
        var default_arm: ?ast.MatchArm = null;
        for (m.arms) |arm| {
            if (isDefaultPattern(arm.pattern)) {
                default_arm = arm;
                break;
            }
            try self.writeIndent(indent + 1);
            if (tested == 0) {
                try out.writeAll("if (");
            } else {
                try out.writeAll("} else if (");
            }
            try self.emitPatternTest(arm.pattern, temp, scrut_ty);
            try out.writeAll(") {\n");
            try self.emitArmBody(arm, temp, scrut_ty, dest, indent + 2);
            tested += 1;
        }

        if (tested == 0) {
            // The first arm matches everything, so no test is emitted at all.
            if (default_arm) |arm| {
                try self.emitArmBody(arm, temp, scrut_ty, dest, indent + 1);
            }
        } else {
            try self.writeIndent(indent + 1);
            try out.writeAll("} else {\n");
            if (default_arm) |arm| {
                try self.emitArmBody(arm, temp, scrut_ty, dest, indent + 2);
            } else {
                // Cell has no exhaustiveness checking, so an unmatched value
                // aborts rather than falling through with a made-up result.
                try self.writeIndent(indent + 2);
                try out.print("cell_panic(\"non-exhaustive match in {s}\");\n", .{self.current_fn});
            }
            try self.writeIndent(indent + 1);
            try out.writeAll("}\n");
        }

        try self.writeIndent(indent);
        try out.writeAll("}\n");
    }

    fn emitArmBody(
        self: *Generator,
        arm: ast.MatchArm,
        temp: []const u8,
        scrut_ty: CType,
        dest: ?[]const u8,
        indent: usize,
    ) EmitError!void {
        const mark = self.locals.items.len;
        defer self.locals.shrinkRetainingCapacity(mark);

        if (arm.pattern.kind == .binding) {
            const name = arm.pattern.kind.binding;
            try self.writeIndent(indent);
            try self.writeDecl(scrut_ty, name);
            try self.writer.print(" = {s};\n", .{temp});
            try self.pushLocal(name, scrut_ty);
            if (!exprUses(arm.body, name)) {
                try self.writeIndent(indent);
                try self.writer.print("(void){s};\n", .{name});
            }
        }

        if (dest) |d| {
            try self.emitValueInto(arm.body, d, indent);
        } else {
            try self.emitEffect(arm.body, indent);
        }
    }

    /// Emit an expression for its effect, in statement position.
    fn emitEffect(self: *Generator, e: *const ast.Expr, indent: usize) EmitError!void {
        switch (e.kind) {
            .block => |stmts| try self.emitStmts(stmts, indent),
            .if_expr => |i| try self.emitIfStmt(i, indent),
            .match_expr => |m| try self.emitMatchStmt(m, indent),
            .annotated => |a| try self.emitEffect(a.value, indent),
            else => {
                try self.writeIndent(indent);
                try self.emitExpr(e, indent);
                try self.writer.writeAll(";\n");
            },
        }
    }

    fn emitPatternTest(self: *Generator, p: ast.Pattern, temp: []const u8, scrut_ty: CType) EmitError!void {
        const out = self.writer;
        switch (p.kind) {
            .wildcard, .binding => try out.writeAll("true"),
            .int => |v| try out.print("{s} == {d}", .{ temp, v }),
            .float => |v| {
                try out.print("{s} == ", .{temp});
                try self.emitFloat(v);
            },
            .bool => |b| {
                if (b) {
                    try out.print("{s}", .{temp});
                } else {
                    try out.print("!{s}", .{temp});
                }
            },
            .string => |s| {
                try out.writeAll("cell_str_eq(");
                if (scrut_ty.shape == .string and !scrut_ty.pointer) {
                    try out.print("cell_string_as_str(&{s})", .{temp});
                } else if (scrut_ty.shape == .string) {
                    try out.print("cell_string_as_str({s})", .{temp});
                } else {
                    try out.writeAll(temp);
                }
                try out.writeAll(", ");
                try self.emitStringLiteral(s);
                try out.writeAll(")");
            },
            .enum_variant => |ev| {
                const enum_name = ev.enum_name orelse
                    (if (scrut_ty.shape == .enumeration) scrut_ty.name else "");
                if (enum_name.len == 0) {
                    // No enum in scope for this pattern: emit the bare mangled
                    // constant so the C compiler reports the missing name
                    // instead of codegen inventing one.
                    try out.print("{s} == cell_{s}", .{ temp, ev.variant });
                } else {
                    try out.print("{s} == cell_{s}_{s}", .{ temp, enum_name, ev.variant });
                }
            },
        }
    }

    // ── value position ──────────────────────────────────────────────────

    /// `if`, `match`, and `block` in expression position, as a GNU statement
    /// expression. See the module comment for why.
    fn emitValueExpr(self: *Generator, e: *const ast.Expr, indent: usize) EmitError!void {
        const out = self.writer;
        var ty = try self.inferExpr(e);
        if (ty.shape == .unit or ty.shape == .unknown) ty = CType.int64;
        const dest = try self.nextTemp();

        try out.writeAll("({\n");
        try self.writeIndent(indent + 1);
        try self.writeDecl(ty, dest);
        try out.print(" = ({s}){{0}};\n", .{ty.text});
        try self.emitValueInto(e, dest, indent + 1);
        try self.writeIndent(indent + 1);
        try out.print("{s};\n", .{dest});
        try self.writeIndent(indent);
        try out.writeAll("})");
    }

    /// Emit `e` as statements that leave its value in `dest`.
    fn emitValueInto(self: *Generator, e: *const ast.Expr, dest: []const u8, indent: usize) EmitError!void {
        const out = self.writer;
        switch (e.kind) {
            .block => |stmts| {
                try self.writeIndent(indent);
                try out.writeAll("{\n");
                const mark = self.locals.items.len;
                defer self.locals.shrinkRetainingCapacity(mark);
                if (stmts.len > 0) {
                    for (stmts[0 .. stmts.len - 1], 0..) |_, i| {
                        try self.emitStmt(&stmts[i], stmts[i + 1 ..], indent + 1);
                    }
                    const last = &stmts[stmts.len - 1];
                    switch (last.kind) {
                        .expr => |le| try self.emitValueInto(&le, dest, indent + 1),
                        else => try self.emitStmt(last, &.{}, indent + 1),
                    }
                }
                try self.writeIndent(indent);
                try out.writeAll("}\n");
            },
            .if_expr => |i| {
                try self.writeIndent(indent);
                try out.writeAll("if (");
                try self.emitExpr(i.cond, indent);
                try out.writeAll(") {\n");
                try self.emitValueInto(i.then_body, dest, indent + 1);
                try self.writeIndent(indent);
                if (i.else_body) |eb| {
                    try out.writeAll("} else {\n");
                    try self.emitValueInto(eb, dest, indent + 1);
                    try self.writeIndent(indent);
                }
                try out.writeAll("}\n");
            },
            .match_expr => |m| try self.emitMatch(m, dest, indent),
            .annotated => |a| try self.emitValueInto(a.value, dest, indent),
            else => {
                try self.writeIndent(indent);
                try out.print("{s} = ", .{dest});
                try self.emitExpr(e, indent);
                try out.writeAll(";\n");
            },
        }
    }

    // ── expressions ─────────────────────────────────────────────────────

    fn emitExpr(self: *Generator, e: *const ast.Expr, indent: usize) EmitError!void {
        const out = self.writer;
        switch (e.kind) {
            .ident => |n| try out.writeAll(n),
            .int => |v| try out.print("{d}", .{v}),
            .float => |v| try self.emitFloat(v),
            .string => |s| try self.emitStringLiteral(s),
            .bool => |b| try out.writeAll(if (b) "true" else "false"),
            .call => |c| try self.emitCall(c, indent),
            .binary => |b| {
                try out.writeAll("(");
                try self.emitExpr(b.left, indent);
                try out.writeAll(switch (b.op) {
                    .add => " + ",
                    .sub => " - ",
                    .mul => " * ",
                    .div => " / ",
                    .eq => " == ",
                    .ne => " != ",
                    .lt => " < ",
                    .le => " <= ",
                    .gt => " > ",
                    .ge => " >= ",
                    .and_op => " && ",
                    .or_op => " || ",
                });
                try self.emitExpr(b.right, indent);
                try out.writeAll(")");
            },
            .unary => |u| try self.emitUnary(u.op, u.operand, indent),
            .field => |f| {
                if (self.enumVariantOf(f.base, f.name)) |enum_name| {
                    try out.print("cell_{s}_{s}", .{ enum_name, f.name });
                    return;
                }
                const base_ty = try self.inferExpr(f.base);
                try self.emitExpr(f.base, indent);
                if (base_ty.pointer) {
                    try out.print("->{s}", .{f.name});
                } else {
                    try out.print(".{s}", .{f.name});
                }
            },
            .struct_lit => |sl| try self.emitStructLit(sl, indent),
            .list_lit => |items| try self.emitListLit(items, indent),
            .block, .if_expr, .match_expr => try self.emitValueExpr(e, indent),
            .annotated => |a| try self.emitExpr(a.value, indent),
        }
    }

    /// `&x` and `&mut x`. Ownership decides the form: a borrow of a primitive
    /// is the value itself, because cell_rt.h section 1 forbids a primitive
    /// from ever becoming a pointer. A shared borrow of an owning string is
    /// the view the ABI asks for.
    fn emitUnary(self: *Generator, op: ast.UnaryOp, operand: *const ast.Expr, indent: usize) EmitError!void {
        const out = self.writer;
        switch (op) {
            .neg => {
                try out.writeAll("-");
                try self.emitExpr(operand, indent);
            },
            .not => {
                try out.writeAll("!");
                try self.emitExpr(operand, indent);
            },
            .ref_shared => {
                const ty = try self.inferExpr(operand);
                if (ty.pointer or ty.shape.isPrimitive()) {
                    try self.emitExpr(operand, indent);
                } else if (ty.shape == .string) {
                    try out.writeAll("cell_string_as_str(&");
                    try self.emitExpr(operand, indent);
                    try out.writeAll(")");
                } else if (ty.shape == .str or ty.shape == .slice or ty.shape == .arc or
                    ty.shape == .optional or ty.shape == .result)
                {
                    // Views and handles are already the borrowed form.
                    try self.emitExpr(operand, indent);
                } else {
                    try out.writeAll("&");
                    try self.emitExpr(operand, indent);
                }
            },
            .ref_exclusive => {
                const ty = try self.inferExpr(operand);
                if (ty.pointer or ty.shape.isPrimitive()) {
                    try self.emitExpr(operand, indent);
                } else {
                    try out.writeAll("&");
                    try self.emitExpr(operand, indent);
                }
            },
        }
    }

    fn emitCall(self: *Generator, c: anytype, indent: usize) EmitError!void {
        const out = self.writer;
        const callee = try self.resolveCallee(c.callee, c.args.len);
        if (callee.symbol) |sym| {
            try out.writeAll(sym);
        } else {
            try self.emitExpr(c.callee, indent);
        }
        try out.writeAll("(");
        for (c.args, 0..) |_, i| {
            if (i > 0) try out.writeAll(", ");
            const arg = &c.args[i];
            if (callee.def) |def| {
                if (i < def.params.len) {
                    const p = def.params[i];
                    try self.emitArgLike(arg, try self.lowerType(&p.ty, p.ownership), indent);
                    continue;
                }
            }
            try self.emitExpr(arg, indent);
        }
        try out.writeAll(")");
    }

    /// Emit `arg` where a value of type `want` is required, inserting the
    /// address-of, dereference, or view conversion the ABI needs. Call-site
    /// ownership prefixes are `.annotated` wrappers; this still lowers from
    /// the callee signature, so `grow(buf, 16)` becomes `cell_grow(&buf, 16)`
    /// because `grow` takes `exclusive Buffer`, not because of a written prefix.
    fn emitArgLike(self: *Generator, arg: *const ast.Expr, want: CType, indent: usize) EmitError!void {
        const out = self.writer;
        const have = try self.inferExpr(arg);

        if (want.pointer and !have.pointer and isPlace(arg)) {
            try out.writeAll("&");
            try self.emitExpr(arg, indent);
            return;
        }
        if (!want.pointer and have.pointer and want.shape == have.shape) {
            try out.writeAll("*");
            try self.emitExpr(arg, indent);
            return;
        }
        if (want.shape == .str and have.shape == .string) {
            if (have.pointer) {
                try out.writeAll("cell_string_as_str(");
                try self.emitExpr(arg, indent);
                try out.writeAll(")");
            } else if (isPlace(arg)) {
                try out.writeAll("cell_string_as_str(&");
                try self.emitExpr(arg, indent);
                try out.writeAll(")");
            } else {
                try self.emitExpr(arg, indent);
            }
            return;
        }
        try self.emitExpr(arg, indent);
    }

    fn emitStructLit(self: *Generator, sl: anytype, indent: usize) EmitError!void {
        const out = self.writer;
        const ty = try self.namedType(sl.name);
        if (sl.fields.len == 0) {
            try out.print("({s}){{0}}", .{ty.text});
            return;
        }
        const def = self.findStruct(sl.name);
        try out.print("({s}){{ ", .{ty.text});
        for (sl.fields, 0..) |fi, i| {
            if (i > 0) try out.writeAll(", ");
            try out.print(".{s} = ", .{fi.name});
            const want: ?CType = if (def) |d| blk: {
                for (d.fields) |fld| {
                    if (std.mem.eql(u8, fld.name, fi.name)) {
                        break :blk try self.lowerType(&fld.ty, fld.ownership);
                    }
                }
                break :blk null;
            } else null;
            if (want) |w| {
                try self.emitArgLike(&sl.fields[i].value, w, indent);
            } else {
                try self.emitExpr(&sl.fields[i].value, indent);
            }
        }
        try out.writeAll(" }");
    }

    /// `[]` is an empty header. A populated literal needs a heap buffer and a
    /// push per element, which is a statement sequence, so it lowers to the
    /// same statement expression the module comment describes.
    fn emitListLit(self: *Generator, items: []const ast.Expr, indent: usize) EmitError!void {
        const out = self.writer;
        if (items.len == 0) {
            try out.writeAll("cell_slice_empty()");
            return;
        }
        var elem = try self.inferExpr(&items[0]);
        if (elem.shape == .unknown or elem.shape == .unit) elem = CType.int64;
        const list = try self.nextTemp();
        const slot = try self.nextTemp();

        try out.writeAll("({\n");
        try self.writeIndent(indent + 1);
        try out.print("cell_slice_t {s} = cell_slice_alloc(sizeof({s}), {d});\n", .{ list, elem.text, items.len });
        try self.writeIndent(indent + 1);
        try self.writeDecl(elem, slot);
        try out.print(" = ({s}){{0}};\n", .{elem.text});
        for (items, 0..) |_, i| {
            try self.writeIndent(indent + 1);
            try out.print("{s} = ", .{slot});
            try self.emitArgLike(&items[i], elem, indent + 1);
            try out.writeAll(";\n");
            try self.writeIndent(indent + 1);
            try out.print("(void)cell_slice_push(&{s}, sizeof({s}), &{s});\n", .{ list, elem.text, slot });
        }
        try self.writeIndent(indent + 1);
        try out.print("{s};\n", .{list});
        try self.writeIndent(indent);
        try out.writeAll("})");
    }

    /// A float literal always carries a decimal point, so the emitted C is a
    /// double constant rather than an int that happens to convert.
    fn emitFloat(self: *Generator, v: f64) EmitError!void {
        var buf: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d}", .{v}) catch "0";
        try self.writer.writeAll(text);
        for (text) |ch| {
            if (ch == '.' or ch == 'e' or ch == 'E' or ch == 'n' or ch == 'i') return;
        }
        try self.writer.writeAll(".0");
    }

    /// A Cell string is a length-prefixed view, not a C string (cell_rt.h
    /// section 2). The parser strips the quotes without unescaping, so the
    /// bytes are re-escaped here exactly as they are and the length is the
    /// count of those bytes.
    fn emitStringLiteral(self: *Generator, s: []const u8) EmitError!void {
        const out = self.writer;
        try out.writeAll("cell_str_from_parts(\"");
        for (s) |ch| {
            switch (ch) {
                '"' => try out.writeAll("\\\""),
                '\\' => try out.writeAll("\\\\"),
                '\n' => try out.writeAll("\\n"),
                '\r' => try out.writeAll("\\r"),
                '\t' => try out.writeAll("\\t"),
                0x20...0x21, 0x23...0x5b, 0x5d...0x7e => try out.writeByte(ch),
                else => try out.print("\\{o:0>3}", .{ch}),
            }
        }
        try out.print("\", {d})", .{s.len});
    }

    // ── types ───────────────────────────────────────────────────────────

    /// Lower a Cell type under an ownership mode, per cell_rt.h section 7.
    pub fn lowerType(self: *Generator, ty: *const ast.TypeExpr, own: ast.Ownership) Alloc!CType {
        switch (ty.*) {
            .ref => |r| return try self.lowerType(r.inner, r.ownership),
            else => {},
        }
        const base = try self.baseType(ty);
        return try self.applyOwnership(base, own);
    }

    /// The by-value form of a type, before ownership is applied.
    fn baseType(self: *Generator, ty: *const ast.TypeExpr) Alloc!CType {
        return switch (ty.*) {
            .unit => CType.void_type,
            .name => |n| try self.namedType(n),
            .list => CType.slice,
            .optional => |inner| blk: {
                const inst = try self.optionalInstance(inner);
                break :blk .{
                    .text = try std.fmt.allocPrint(self.arena, "{s}_t", .{inst.base}),
                    .shape = .optional,
                };
            },
            .result => CType.result,
            .ref => |r| try self.lowerType(r.inner, r.ownership),
        };
    }

    fn applyOwnership(self: *Generator, base: CType, own: ast.Ownership) Alloc!CType {
        if (base.shape.isPrimitive()) return base;
        return switch (own) {
            .arc => CType.arc,
            .exclusive => try self.pointerTo(base, false),
            .shared => switch (base.shape) {
                .string => CType.str,
                .record, .unknown => try self.pointerTo(base, true),
                else => base,
            },
            .owned, .copy => base,
        };
    }

    fn pointerTo(self: *Generator, base: CType, is_const: bool) Alloc!CType {
        const text = if (is_const)
            try std.fmt.allocPrint(self.arena, "const {s} *", .{base.text})
        else
            try std.fmt.allocPrint(self.arena, "{s} *", .{base.text});
        return .{ .text = text, .shape = base.shape, .pointer = true, .name = base.name };
    }

    fn namedType(self: *Generator, n: []const u8) Alloc!CType {
        if (eq(n, "Int") or eq(n, "Int64")) return CType.int64;
        if (eq(n, "Int32")) return .{ .text = "int32_t", .shape = .integer };
        if (eq(n, "UInt") or eq(n, "UInt64")) return .{ .text = "uint64_t", .shape = .integer };
        if (eq(n, "Float") or eq(n, "Float64")) return CType.float64;
        if (eq(n, "Float32")) return .{ .text = "float", .shape = .floating };
        if (eq(n, "Bool")) return CType.boolean;
        if (eq(n, "Byte")) return .{ .text = "uint8_t", .shape = .byte };
        if (eq(n, "String")) return CType.string;
        if (eq(n, "Unit")) return CType.void_type;

        if (self.findStruct(n) != null) {
            return .{
                .text = try std.fmt.allocPrint(self.arena, "cell_{s}", .{n}),
                .shape = .record,
                .name = n,
            };
        }
        if (self.findEnum(n) != null) {
            return .{
                .text = try std.fmt.allocPrint(self.arena, "cell_{s}", .{n}),
                .shape = .enumeration,
                .name = n,
            };
        }
        return CType.unknown;
    }

    /// Which `CELL_DEFINE_OPTIONAL` instance covers `T?`. cell_rt.h predefines
    /// eight; anything else is instantiated at the top of the module.
    fn optionalInstance(self: *Generator, inner: *const ast.TypeExpr) Alloc!OptionalInst {
        switch (inner.*) {
            .name => |n| {
                if (eq(n, "Int") or eq(n, "Int64")) return .{ .base = "cell_opt_i64", .elem = "int64_t", .generated = false };
                if (eq(n, "UInt") or eq(n, "UInt64")) return .{ .base = "cell_opt_u64", .elem = "uint64_t", .generated = false };
                if (eq(n, "Int32")) return .{ .base = "cell_opt_i32", .elem = "int32_t", .generated = false };
                if (eq(n, "Float") or eq(n, "Float64")) return .{ .base = "cell_opt_f64", .elem = "double", .generated = false };
                if (eq(n, "Bool")) return .{ .base = "cell_opt_bool", .elem = "bool", .generated = false };
                if (eq(n, "Byte")) return .{ .base = "cell_opt_byte", .elem = "uint8_t", .generated = false };
                if (eq(n, "String")) return .{ .base = "cell_opt_str", .elem = "cell_str_t", .generated = false };
                const base = try self.namedType(n);
                if (base.shape == .unknown) return .{ .base = "cell_opt_ptr", .elem = "void *", .generated = false };
                return .{
                    .base = try std.fmt.allocPrint(self.arena, "cell_opt_{s}", .{n}),
                    .elem = base.text,
                    .generated = true,
                };
            },
            .list => return .{ .base = "cell_opt_list", .elem = "cell_slice_t", .generated = true },
            else => return .{ .base = "cell_opt_ptr", .elem = "void *", .generated = false },
        }
    }

    // ── local type inference ────────────────────────────────────────────

    fn inferExpr(self: *Generator, e: *const ast.Expr) Alloc!CType {
        switch (e.kind) {
            .ident => |n| return self.lookupLocal(n) orelse CType.unknown,
            .int => return CType.int64,
            .float => return CType.float64,
            .bool => return CType.boolean,
            .string => return CType.str,
            .binary => |b| switch (b.op) {
                .eq, .ne, .lt, .le, .gt, .ge, .and_op, .or_op => return CType.boolean,
                else => {
                    const left = try self.inferExpr(b.left);
                    if (left.shape != .unknown) return left;
                    return try self.inferExpr(b.right);
                },
            },
            .unary => |u| switch (u.op) {
                .not => return CType.boolean,
                .neg => return try self.inferExpr(u.operand),
                .ref_shared => {
                    const inner = try self.inferExpr(u.operand);
                    if (inner.pointer or inner.shape.isPrimitive()) return inner;
                    if (inner.shape == .string) return CType.str;
                    if (inner.shape == .record or inner.shape == .unknown) return try self.pointerTo(inner, true);
                    return inner;
                },
                .ref_exclusive => {
                    const inner = try self.inferExpr(u.operand);
                    if (inner.pointer or inner.shape.isPrimitive()) return inner;
                    return try self.pointerTo(inner, false);
                },
            },
            .call => |c| {
                const callee = try self.resolveCallee(c.callee, c.args.len);
                if (callee.def) |def| {
                    if (def.return_type) |rt| return try self.lowerType(&rt, .owned);
                    return CType.void_type;
                }
                if (callee.symbol) |sym| {
                    if (eq(sym, "cell_print") or eq(sym, "cell_println") or
                        eq(sym, "cell_assert") or eq(sym, "cell_assert_msg") or
                        eq(sym, "cell_panic")) return CType.void_type;
                }
                return CType.unknown;
            },
            .field => |f| {
                if (self.enumVariantOf(f.base, f.name)) |enum_name| {
                    return try self.namedType(enum_name);
                }
                const base = try self.inferExpr(f.base);
                if (base.shape != .record) return CType.unknown;
                const def = self.findStruct(base.name) orelse return CType.unknown;
                for (def.fields) |fld| {
                    if (eq(fld.name, f.name)) return try self.lowerType(&fld.ty, fld.ownership);
                }
                return CType.unknown;
            },
            .struct_lit => |sl| return try self.namedType(sl.name),
            .list_lit => return CType.slice,
            .block => |stmts| {
                if (stmts.len == 0) return CType.void_type;
                const last = stmts[stmts.len - 1];
                return switch (last.kind) {
                    .expr => |le| try self.inferExpr(&le),
                    else => CType.void_type,
                };
            },
            .if_expr => |i| return try self.inferExpr(i.then_body),
            .match_expr => |m| {
                if (m.arms.len == 0) return CType.void_type;
                return try self.inferExpr(m.arms[0].body);
            },
            .annotated => |a| return try self.inferExpr(a.value),
        }
    }

    /// Resolve a callee to its mangled C symbol. Every Cell function is
    /// `cell_<name>`, which is also how the runtime spells its intrinsics, so
    /// `print` lands on `cell_print` with no special case. `assert` is the one
    /// exception: C has no overloading, so the two-argument form goes to
    /// `cell_assert_msg`.
    fn resolveCallee(self: *Generator, callee: *const ast.Expr, argc: usize) Alloc!Callee {
        switch (callee.kind) {
            .ident => |n| {
                if (self.findFn(n)) |def| {
                    return .{ .symbol = try self.symbolFor(def), .def = def };
                }
                // Nothing declares it here, so it is either a runtime
                // intrinsic or an external symbol under the usual mangling.
                if (intrinsicSymbol(n, argc)) |sym| return .{ .symbol = sym, .def = null };
                return .{
                    .symbol = try std.fmt.allocPrint(self.arena, "cell_{s}", .{n}),
                    .def = null,
                };
            },
            .field => {
                // There is no module resolution, so a dotted callee is mangled
                // by joining its segments: `io.print` is `cell_io_print`,
                // which fails at link time rather than emitting invalid C.
                var parts: std.ArrayList([]const u8) = .empty;
                var cursor = callee;
                while (cursor.kind == .field) {
                    try parts.append(self.arena, cursor.kind.field.name);
                    cursor = cursor.kind.field.base;
                }
                if (cursor.kind != .ident) return .{ .symbol = null, .def = null };
                var name: []const u8 = try std.fmt.allocPrint(self.arena, "cell_{s}", .{cursor.kind.ident});
                var i = parts.items.len;
                while (i > 0) {
                    i -= 1;
                    name = try std.fmt.allocPrint(self.arena, "{s}_{s}", .{ name, parts.items[i] });
                }
                return .{ .symbol = name, .def = null };
            },
            else => return .{ .symbol = null, .def = null },
        }
    }

    // ── lookup and scratch ──────────────────────────────────────────────

    fn findFn(self: *Generator, name: []const u8) ?ast.FnDef {
        for (self.module.items) |item| {
            switch (item.kind) {
                .fn_def => |f| if (eq(f.name, name)) return f,
                else => {},
            }
        }
        return null;
    }

    fn findStruct(self: *Generator, name: []const u8) ?ast.StructDef {
        for (self.module.items) |item| {
            switch (item.kind) {
                .struct_def => |s| if (eq(s.name, name)) return s,
                else => {},
            }
        }
        return null;
    }

    fn findEnum(self: *Generator, name: []const u8) ?ast.EnumDef {
        for (self.module.items) |item| {
            switch (item.kind) {
                .enum_def => |e| if (eq(e.name, name)) return e,
                else => {},
            }
        }
        return null;
    }

    /// `Color.Red` parses as a field selection on the identifier `Color`.
    /// When that identifier is shadowed by no local and names a declared enum
    /// that has this variant, the whole expression is the enum constant.
    fn enumVariantOf(self: *Generator, base: *const ast.Expr, field: []const u8) ?[]const u8 {
        if (base.kind != .ident) return null;
        const name = base.kind.ident;
        if (self.lookupLocal(name) != null) return null;
        const def = self.findEnum(name) orelse return null;
        for (def.variants) |v| {
            if (eq(v, field)) return def.name;
        }
        return null;
    }

    fn lookupLocal(self: *Generator, name: []const u8) ?CType {
        var i = self.locals.items.len;
        while (i > 0) {
            i -= 1;
            if (eq(self.locals.items[i].name, name)) return self.locals.items[i].ty;
        }
        return null;
    }

    fn pushLocal(self: *Generator, name: []const u8, ty: CType) Alloc!void {
        try self.locals.append(self.arena, .{ .name = name, .ty = ty });
    }

    fn nextTemp(self: *Generator) Alloc![]const u8 {
        const name = try std.fmt.allocPrint(self.arena, "_cell_t{d}", .{self.temp_counter});
        self.temp_counter += 1;
        return name;
    }

    fn writeIndent(self: *Generator, n: usize) EmitError!void {
        var i: usize = 0;
        while (i < n) : (i += 1) try self.writer.writeAll("  ");
    }
};

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Runtime intrinsics whose C symbol is not `cell_<name>` for every arity.
/// `print`, `println`, and `panic` already land on their runtime names under
/// the normal mangling; `assert` does not, because C has no overloading and
/// the message-carrying form is a separate symbol.
fn intrinsicSymbol(name: []const u8, arity: usize) ?[]const u8 {
    if (eq(name, "assert")) return if (arity == 2) "cell_assert_msg" else "cell_assert";
    return null;
}

/// A pattern that matches everything, so it closes an if/else chain.
fn isDefaultPattern(p: ast.Pattern) bool {
    return switch (p.kind) {
        .wildcard, .binding => true,
        else => false,
    };
}

/// An addressable expression, the only kind `&` may be applied to.
fn isPlace(e: *const ast.Expr) bool {
    return switch (e.kind) {
        .ident, .field => true,
        .annotated => |a| isPlace(a.value),
        else => false,
    };
}

// ── use analysis, for the (void) casts that keep -Wextra quiet ───────────

fn exprUses(e: *const ast.Expr, name: []const u8) bool {
    return switch (e.kind) {
        .ident => |n| eq(n, name),
        .int, .float, .string, .bool => false,
        .call => |c| blk: {
            if (exprUses(c.callee, name)) break :blk true;
            for (c.args, 0..) |_, i| {
                if (exprUses(&c.args[i], name)) break :blk true;
            }
            break :blk false;
        },
        .binary => |b| exprUses(b.left, name) or exprUses(b.right, name),
        .unary => |u| exprUses(u.operand, name),
        .field => |f| exprUses(f.base, name),
        .struct_lit => |sl| blk: {
            for (sl.fields, 0..) |_, i| {
                if (exprUses(&sl.fields[i].value, name)) break :blk true;
            }
            break :blk false;
        },
        .list_lit => |items| blk: {
            for (items, 0..) |_, i| {
                if (exprUses(&items[i], name)) break :blk true;
            }
            break :blk false;
        },
        .block => |stmts| stmtsUse(stmts, name),
        .if_expr => |i| blk: {
            if (exprUses(i.cond, name)) break :blk true;
            if (exprUses(i.then_body, name)) break :blk true;
            if (i.else_body) |eb| break :blk exprUses(eb, name);
            break :blk false;
        },
        .match_expr => |m| blk: {
            if (exprUses(m.scrutinee, name)) break :blk true;
            for (m.arms) |arm| {
                if (exprUses(arm.body, name)) break :blk true;
            }
            break :blk false;
        },
        .annotated => |a| exprUses(a.value, name),
    };
}

fn stmtsUse(stmts: []const ast.Stmt, name: []const u8) bool {
    for (stmts, 0..) |_, i| {
        if (stmtUses(&stmts[i], name)) return true;
    }
    return false;
}

fn stmtUses(s: *const ast.Stmt, name: []const u8) bool {
    return switch (s.kind) {
        .let => |l| if (l.value) |v| exprUses(&v, name) else false,
        .expr => |e| exprUses(&e, name),
        .return_stmt => |opt| if (opt) |v| exprUses(&v, name) else false,
        .assign => |a| targetReads(&a.target, name) or exprUses(&a.value, name),
        // A loop's condition is re-read on every iteration, so a binding used
        // only there is genuinely used and must not get a `(void)` cast.
        .while_stmt => |w| exprUses(&w.cond, name) or stmtsUse(w.body, name),
        .break_stmt, .continue_stmt => false,
    };
}

/// Whether an assignment target READS `name`. `x = e` only writes x, and a
/// binding that is written and never read still trips
/// -Wunused-but-set-variable, so it needs the same `(void)` cast an unused one
/// gets. `x.f = e` does read x, because the store goes through it.
fn targetReads(e: *const ast.Expr, name: []const u8) bool {
    return switch (e.kind) {
        .ident => false,
        .annotated => |a| targetReads(a.value, name),
        else => exprUses(e, name),
    };
}

// ── tests ───────────────────────────────────────────────────────────────

const lexer = @import("lexer.zig");
const parser = @import("parser.zig");

/// Parse `src` and return the emitted C. The buffer is caller owned so the
/// returned slice stays valid.
fn emitForTest(arena: std.mem.Allocator, buf: []u8, src: []const u8) ![]const u8 {
    var lex = lexer.Lexer.init(src, "t.cell");
    const toks = try lex.tokenizeAll(arena);
    var p = parser.Parser.init(arena, toks.items, "t.cell");
    var module = try p.parseModule();
    var w = Io.Writer.fixed(buf);
    var gen = Generator.init(arena, &w);
    try gen.emitModule(&module);
    return w.buffered();
}

const TestEmit = struct {
    arena: std.heap.ArenaAllocator,
    buf: []u8,
    text: []const u8,

    fn deinit(self: *TestEmit) void {
        std.testing.allocator.free(self.buf);
        self.arena.deinit();
    }
};

fn emitSource(src: []const u8) !TestEmit {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    errdefer arena.deinit();
    const buf = try std.testing.allocator.alloc(u8, 64 * 1024);
    errdefer std.testing.allocator.free(buf);
    const text = try emitForTest(arena.allocator(), buf, src);
    return .{ .arena = arena, .buf = buf, .text = text };
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("\nexpected to find:\n{s}\nin:\n{s}\n", .{ needle, haystack });
        return error.NotFound;
    }
}

fn expectAbsent(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) != null) {
        std.debug.print("\nexpected NOT to find:\n{s}\nin:\n{s}\n", .{ needle, haystack });
        return error.Found;
    }
}

test "every module includes the runtime header" {
    var e = try emitSource("pub fn f(copy v: Int) -> Int;");
    defer e.deinit();
    try expectContains(e.text, "#include \"cell_rt.h\"");
}

test "ownership selects the parameter type for each mode" {
    var e = try emitSource(
        \\pub struct Buffer {
        \\  copy len: Int
        \\}
        \\pub fn by_copy(copy v: Int) -> Int;
        \\pub fn by_shared_primitive(shared v: Int) -> Int;
        \\pub fn by_exclusive_primitive(exclusive v: Int) -> Int;
        \\pub fn by_shared_string(shared s: String) -> Int;
        \\pub fn by_owned_string(owned s: String) -> Int;
        \\pub fn by_exclusive_string(exclusive s: String) -> Int;
        \\pub fn by_arc_string(arc s: String) -> Int;
        \\pub fn by_shared_struct(shared b: Buffer) -> Int;
        \\pub fn by_exclusive_struct(exclusive b: Buffer) -> Int;
        \\pub fn by_owned_struct(owned b: Buffer) -> Int;
        \\pub fn by_shared_list(shared xs: [Byte]) -> Int;
        \\pub fn by_exclusive_list(exclusive xs: [Byte]) -> Int;
    );
    defer e.deinit();

    // Primitives stay by value in every mode: cell_rt.h section 1.
    try expectContains(e.text, "int64_t cell_by_copy(int64_t v);");
    try expectContains(e.text, "int64_t cell_by_shared_primitive(int64_t v);");
    try expectContains(e.text, "int64_t cell_by_exclusive_primitive(int64_t v);");

    try expectContains(e.text, "int64_t cell_by_shared_string(cell_str_t s);");
    try expectContains(e.text, "int64_t cell_by_owned_string(cell_string_t s);");
    try expectContains(e.text, "int64_t cell_by_exclusive_string(cell_string_t *s);");
    try expectContains(e.text, "int64_t cell_by_arc_string(cell_arc_t s);");

    try expectContains(e.text, "int64_t cell_by_shared_struct(const cell_Buffer *b);");
    try expectContains(e.text, "int64_t cell_by_exclusive_struct(cell_Buffer *b);");
    try expectContains(e.text, "int64_t cell_by_owned_struct(cell_Buffer b);");

    try expectContains(e.text, "int64_t cell_by_shared_list(cell_slice_t xs);");
    try expectContains(e.text, "int64_t cell_by_exclusive_list(cell_slice_t *xs);");
}

test "a struct lowers each field by its own ownership" {
    var e = try emitSource(
        \\pub struct Buffer {
        \\  owned data: [Byte]
        \\  copy len: Int
        \\  shared name: String
        \\}
    );
    defer e.deinit();
    try expectContains(e.text,
        \\typedef struct cell_Buffer {
        \\  cell_slice_t data; // owned
        \\  int64_t len; // copy
        \\  cell_str_t name; // shared
        \\} cell_Buffer;
    );
}

test "an enum is an int32_t typedef, not an implementation defined enum" {
    var e = try emitSource(
        \\pub enum Color {
        \\  Red,
        \\  Green,
        \\  Blue,
        \\}
    );
    defer e.deinit();
    try expectContains(e.text,
        \\typedef int32_t cell_Color;
        \\enum {
        \\  cell_Color_Red = 0,
        \\  cell_Color_Green = 1,
        \\  cell_Color_Blue = 2,
        \\};
    );
    try expectAbsent(e.text, "typedef enum");
}

test "a zero-parameter function is prototyped with void" {
    var e = try emitSource("pub fn tick();");
    defer e.deinit();
    try expectContains(e.text, "void cell_tick(void);");
}

test "an optional lowers to the tagged runtime type, not void*" {
    var e = try emitSource(
        \\pub struct Point { copy x: Int }
        \\pub fn maybe_int(shared v: Int?) -> Bool;
        \\pub fn maybe_point(shared p: Point?) -> Bool;
    );
    defer e.deinit();
    try expectContains(e.text, "CELL_DEFINE_OPTIONAL(cell_opt_Point, cell_Point)");
    try expectContains(e.text, "bool cell_maybe_int(cell_opt_i64_t v);");
    try expectContains(e.text, "bool cell_maybe_point(cell_opt_Point_t p);");
}

test "a list parameter lowers to a slice, not void*" {
    var e = try emitSource("pub fn count(shared xs: [Byte]) -> Int;");
    defer e.deinit();
    try expectContains(e.text, "int64_t cell_count(cell_slice_t xs);");
    try expectAbsent(e.text, "void*");
}

test "calls are mangled and reach the runtime intrinsics" {
    var e = try emitSource(
        \\pub fn add(shared a: Int, shared b: Int) -> Int {
        \\  return a + b
        \\}
        \\pub fn main() {
        \\  let copy n = add(shared 40, shared 2)
        \\  print("hi")
        \\  println("hi")
        \\  assert(true)
        \\  assert(true, "boom")
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "int64_t n = cell_add(40, 2);");
    try expectContains(e.text, "cell_print(cell_str_from_parts(\"hi\", 2));");
    try expectContains(e.text, "cell_println(cell_str_from_parts(\"hi\", 2));");
    try expectContains(e.text, "cell_assert(true);");
    try expectContains(e.text, "cell_assert_msg(true, cell_str_from_parts(\"boom\", 4));");
    // A shared primitive argument is passed by value, never addressed.
    try expectAbsent(e.text, "cell_add(&40, &2)");
}

test "a bodyless declaration of an intrinsic takes the runtime spelling" {
    var e = try emitSource(
        \\pub fn assert(shared cond: Bool, shared msg: String);
        \\pub fn main() {
        \\  assert(true, "boom")
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "void cell_assert_msg(bool cond, cell_str_t msg);");
    try expectContains(e.text, "cell_assert_msg(true, cell_str_from_parts(\"boom\", 4));");
    try expectAbsent(e.text, "void cell_assert(bool cond, cell_str_t msg)");
}

test "a defined function is never renamed onto a runtime symbol" {
    var e = try emitSource(
        \\pub fn assert(shared cond: Bool, shared msg: String) {
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "void cell_assert(bool cond, cell_str_t msg) {");
    try expectAbsent(e.text, "cell_assert_msg");
}

test "a string literal becomes a length-prefixed view with escapes preserved" {
    var e = try emitSource(
        \\pub fn main() {
        \\  print("a\"b")
        \\}
    );
    defer e.deinit();
    // The parser does not unescape, so the value holds a backslash and the
    // emitted literal must reproduce it exactly.
    try expectContains(e.text, "cell_str_from_parts(\"a\\\\\\\"b\", 4)");
}

test "a shared borrow of a primitive drops the ampersand" {
    var e = try emitSource(
        \\pub struct Buffer { copy len: Int }
        \\pub fn take_int(shared v: Int) -> Int;
        \\pub fn take_buf(shared b: Buffer) -> Int;
        \\pub fn main() {
        \\  let copy n = 1
        \\  let owned b = Buffer { len: 0 }
        \\  let copy x = take_int(&n)
        \\  let copy y = take_buf(&b)
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_take_int(n);");
    try expectContains(e.text, "cell_take_buf(&b);");
}

test "a call site is lowered against the callee's parameter ownership" {
    var e = try emitSource(
        \\pub struct Buffer { copy len: Int }
        \\pub fn grow(exclusive buf: Buffer, shared extra: Int) {
        \\  let copy new_len = buf.len + extra
        \\  buf.len = new_len
        \\}
        \\pub fn read_only(shared b: Buffer) -> Int {
        \\  return b.len
        \\}
        \\pub fn main() {
        \\  let owned buf = Buffer { len: 0 }
        \\  grow(exclusive buf, shared 16)
        \\  let copy n = read_only(shared buf)
        \\}
    );
    defer e.deinit();
    // Emission still follows the callee signature, so `exclusive buf`
    // becomes `&buf` because `grow` takes `exclusive Buffer`.
    try expectContains(e.text, "cell_grow(&buf, 16);");
    try expectContains(e.text, "cell_read_only(&buf);");
    // Inside grow, buf is a pointer, so field selection uses `->`.
    try expectContains(e.text, "int64_t new_len = (buf->len + extra);");
    try expectContains(e.text, "buf->len = new_len;");
}

test "a struct literal becomes a designated compound literal" {
    var e = try emitSource(
        \\pub struct Point {
        \\  copy x: Float64
        \\  copy y: Float64
        \\}
        \\pub fn main() {
        \\  let owned p = Point { x: 1.0, y: 2.0 }
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_Point p = (cell_Point){ .x = 1.0, .y = 2.0 };");
}

test "list literals lower to slice headers" {
    var e = try emitSource(
        \\pub struct Buffer {
        \\  owned data: [Byte]
        \\  copy len: Int
        \\}
        \\pub fn main() {
        \\  let owned b = Buffer { data: [], len: 0 }
        \\  let owned xs = [1, 2]
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, ".data = cell_slice_empty()");
    try expectContains(e.text, "cell_slice_t _cell_t0 = cell_slice_alloc(sizeof(int64_t), 2);");
    try expectContains(e.text, "(void)cell_slice_push(&_cell_t0, sizeof(int64_t), &_cell_t1);");
}

test "statement position if is plain C" {
    var e = try emitSource(
        \\pub fn pick(shared c: Bool) -> Int {
        \\  if (c) { return 1 } else { return 2 }
        \\  return 0
        \\}
    );
    defer e.deinit();
    try expectContains(e.text,
        \\  if (c) {
        \\    return 1;
        \\  } else {
        \\    return 2;
        \\  }
    );
    try expectAbsent(e.text, "/*if*/");
}

test "expression position if becomes a statement expression" {
    var e = try emitSource(
        \\pub fn pick(shared c: Bool) -> Int {
        \\  let copy v = if (c) { 1 } else { 2 }
        \\  return v
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "int64_t v = ({");
    try expectContains(e.text, "_cell_t0 = 1;");
    try expectContains(e.text, "_cell_t0 = 2;");
}

test "match lowers to a scrutinee temporary and an if chain" {
    var e = try emitSource(
        \\pub enum Color { Red, Green, Blue }
        \\pub fn describe(shared c: Color) -> Int {
        \\  return match c {
        \\    Color.Red => 1,
        \\    Green => 2,
        \\    _ => 0,
        \\  }
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_Color _cell_t1 = c;");
    try expectContains(e.text, "if (_cell_t1 == cell_Color_Red) {");
    try expectContains(e.text, "} else if (_cell_t1 == cell_Color_Green) {");
    try expectAbsent(e.text, "/*match*/");
}

test "a match without a catch-all arm panics instead of inventing a value" {
    var e = try emitSource(
        \\pub fn describe(shared n: Int) -> Int {
        \\  return match n {
        \\    1 => 10,
        \\    2 => 20,
        \\  }
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_panic(\"non-exhaustive match in describe\");");
}

test "a match arm binding is declared and kept quiet when unused" {
    var e = try emitSource(
        \\pub fn describe(shared n: Int) -> Int {
        \\  return match n {
        \\    1 => 10,
        \\    other => 0,
        \\  }
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "int64_t other = _cell_t1;");
    try expectContains(e.text, "(void)other;");
}

test "unused parameters and locals are named so -Wextra stays quiet" {
    var e = try emitSource(
        \\pub struct Buffer { copy len: Int }
        \\pub fn take(owned b: Buffer) {
        \\}
        \\pub fn main() {
        \\  let copy unused = 1
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "void cell_take(cell_Buffer b) {\n  (void)b;\n}");
    try expectContains(e.text, "(void)unused;");
}

test "a qualified enum variant in expression position is the enum constant" {
    var e = try emitSource(
        \\pub enum Color { Red, Green, Blue }
        \\pub fn describe(copy c: Color) -> Int;
        \\pub fn main() {
        \\  let copy n = describe(Color.Green)
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "cell_describe(cell_Color_Green)");
}

test "a binding that is only assigned still gets a (void) cast" {
    // -Wunused-but-set-variable fires on a write-only binding, so a plain
    // assignment target does not count as a use.
    var e = try emitSource(
        \\pub fn f() {
        \\  var counter: Int = 0
        \\  counter = 1
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "int64_t counter = 0;\n  (void)counter;\n  counter = 1;");
}

test "a module with a main gets a C entry point" {
    var e = try emitSource(
        \\pub fn main() {
        \\  print("hi")
        \\}
    );
    defer e.deinit();
    try expectContains(e.text,
        \\int main(void) {
        \\  cell_main();
        \\  return 0;
        \\}
    );
}

test "a module without a main gets no C entry point" {
    var e = try emitSource("pub fn helper(copy v: Int) -> Int;");
    defer e.deinit();
    try expectAbsent(e.text, "int main(void)");
}

test "the hello example emits runtime-backed C" {
    // The example file itself cannot be read from here: @embedFile is limited
    // to the module root at src/, so the source is inlined.
    var e = try emitSource(
        \\use std.io
        \\
        \\pub struct Point {
        \\  copy x: Float64
        \\  copy y: Float64
        \\}
        \\
        \\pub enum Color {
        \\  Red,
        \\  Green,
        \\  Blue,
        \\}
        \\
        \\pub fn add(shared a: Int, shared b: Int) -> Int {
        \\  return a + b
        \\}
        \\
        \\pub fn main() {
        \\  let owned p = Point { x: 1.0, y: 2.0 }
        \\  let copy n = add(shared 40, shared 2)
        \\  print("hello from cell")
        \\}
    );
    defer e.deinit();
    try expectContains(e.text, "#include \"cell_rt.h\"");
    try expectContains(e.text, "cell_print(");
    try expectContains(e.text, "int64_t cell_add(int64_t a, int64_t b) {");
    try expectContains(e.text, "cell_Point p = (cell_Point){ .x = 1.0, .y = 2.0 };");
    try expectContains(e.text, "int main(void) {");
}

test "generated C for a function body compiles with cc -c" {
    var e = try emitSource(
        \\pub fn add(shared a: Int, shared b: Int) -> Int {
        \\  return a + b
        \\}
        \\pub fn print_int(copy value: Int);
        \\pub fn main() {
        \\  let copy n = add(shared 40, shared 2)
        \\  print_int(n)
        \\}
    );
    defer e.deinit();

    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "body.c", .data = e.text });

    var cwd_buf: [4096]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const include = try std.fmt.allocPrint(gpa, "{s}/runtime", .{cwd_buf[0..cwd_len]});
    defer gpa.free(include);

    const result = try std.process.run(gpa, io, .{
        .argv = &.{ "cc", "-std=c11", "-Wall", "-Wextra", "-c", "body.c", "-I", include, "-o", "body.o" },
        .cwd = .{ .dir = tmp.dir },
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (!result.term.success()) {
        std.debug.print("cc rejected emitted C:\n{s}\n--- source ---\n{s}\n", .{ result.stderr, e.text });
        return error.CcRejectedEmittedC;
    }
}
