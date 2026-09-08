//! AAPCS64 classification: how a Cell type is passed and returned.
//!
//! A LEAF MODULE. It imports `hir` and `types` and nothing else, so it is
//! testable standalone and neither backend can smuggle target knowledge past
//! it.
//!
//! EVERY FACT HERE WAS MEASURED, not read from documentation. A probe
//! including `runtime/cell_rt.h` was compiled with `cc -S -emit-llvm -O0` on
//! this host (Apple clang 21.0.0, arm64-apple-darwin27.0.0) and the resulting
//! `define` lines read directly. The full table is in
//! `docs/superpowers/specs/2026-09-07-aggregate-abi-design.md`, and the test
//! at the bottom of this file re-checks it against clang on every run rather
//! than trusting it.

const std = @import("std");
const hir = @import("hir.zig");
const types = @import("types.zig");

pub const Layout = struct {
    size: u32,
    alignment: u32,
};

/// Size and alignment of `ty` on this target, or null when this module does
/// not classify the type yet.
///
/// Null is not an error. It means the caller must refuse rather than guess,
/// which is the discipline both new backends already follow.
pub fn layoutOf(m: *const hir.Module, ty: hir.Ty, own: hir.Ownership) ?Layout {
    return switch (ty) {
        .int, .uint, .float => .{ .size = 8, .alignment = 8 },
        .int32, .float32 => .{ .size = 4, .alignment = 4 },
        // An enum is an int32_t typedef in the C ABI (SPEC 10.3), so both
        // backends agree on its width.
        .enum_type => .{ .size = 4, .alignment = 4 },
        .boolean, .byte => .{ .size = 1, .alignment = 1 },
        .unit => .{ .size = 0, .alignment = 1 },
        .struct_type => |name| structLayout(m, name),
        // String is the one type whose SIZE depends on ownership, which is why
        // this function takes it. codegen maps `shared String` to a 16-byte
        // cell_str_t (a borrowed {ptr, len} view) and `owned`/`copy String` to
        // a 24-byte cell_string_t (an owning {ptr, len, cap} buffer).
        //
        // `exclusive` used to be grouped with `shared` here and that was
        // WRONG, measured against the C the reference backend emits.
        // `codegen.applyOwnership` maps `exclusive String` to
        // `cell_string_t *`, a pointer to the OWNING buffer, and writes
        // through it. So the object an `exclusive String` names is 24 bytes,
        // not 16, and `stringStruct` below names it accordingly. The old
        // answer made `llvmemit.zig` give the binding a 16-byte slot and then
        // store a 24-byte value into it: eight bytes past the end of the
        // alloca, plus a lost write, with no diagnostic from anything.
        .string => switch (own) {
            .shared => .{ .size = 16, .alignment = 8 },
            .exclusive, .owned, .copy => .{ .size = 24, .alignment = 8 },
            // arc String is a cell_arc_t over a heap cell_string_t. arc has no
            // retain/release insertion yet (OWNERSHIP R11), so placing one
            // correctly would be lowering half a feature.
            .arc => null,
        },
        // An optional is `{ bool has_value; T value; }` (the
        // CELL_DEFINE_OPTIONAL macro in cell_rt.h), so it lays out like any
        // other two-field struct: the tag, padding to the payload's
        // alignment, the payload, then trailing padding.
        .optional => |inner| blk: {
            const il = layoutOf(m, inner.*, .copy) orelse break :blk null;
            const al = @max(il.alignment, 1);
            break :blk .{ .size = alignUp(alignUp(1, al) + il.size, al), .alignment = al };
        },
        // [T] is a cell_slice_t, `{ void *ptr; size_t len; size_t cap; }`:
        // ONE type-erased header for every element type, with elem_size passed
        // at each call site (cell_rt.h section 3). So its layout does not
        // depend on the element, and at 24 bytes it takes the same indirect
        // path cell_string_t already uses.
        .list => .{ .size = 24, .alignment = 8 },
        // Still out of scope: Result's payload is a union this module does not
        // model yet.
        .result, .func, .unknown => null,
    };
}

/// The runtime's optional-instance base for an element type, matching what
/// codegen emits: `Int?` is a `cell_opt_i64_t`. Null for an element the
/// runtime has no pre-defined instance for.
pub fn optionalBase(elem: hir.Ty) ?[]const u8 {
    return switch (elem) {
        .int => "cell_opt_i64",
        .uint => "cell_opt_u64",
        .int32 => "cell_opt_i32",
        .float => "cell_opt_f64",
        .boolean => "cell_opt_bool",
        .byte => "cell_opt_byte",
        .string => "cell_opt_str",
        else => null,
    };
}

/// The LLVM struct type a `String` occupies, by ownership. Null when this
/// module does not place it.
///
/// For `exclusive` this is the POINTEE, not the parameter: `classifyParam`
/// places an `exclusive String` as a `ptr`, and this names what it points at.
/// The two answers have to be read together, which is why they are both
/// derived from `codegen.applyOwnership` rather than from each other.
pub fn stringStruct(own: hir.Ownership) ?[]const u8 {
    return switch (own) {
        .shared => "%cell_str",
        .exclusive, .owned, .copy => "%cell_string",
        .arc => null,
    };
}

/// C struct layout: each field aligned to its own alignment, the struct
/// aligned to its widest member, trailing padding to a multiple of that.
fn structLayout(m: *const hir.Module, name: []const u8) ?Layout {
    const s = m.findStruct(name) orelse return null;
    var offset: u32 = 0;
    var max_align: u32 = 1;
    for (s.fields) |f| {
        const fl = layoutOf(m, f.ty, f.ownership) orelse return null;
        if (fl.alignment > max_align) max_align = fl.alignment;
        offset = alignUp(offset, fl.alignment) + fl.size;
    }
    return .{ .size = alignUp(offset, max_align), .alignment = max_align };
}

fn alignUp(value: u32, alignment: u32) u32 {
    if (alignment == 0) return value;
    return (value + alignment - 1) / alignment * alignment;
}

/// A homogeneous float aggregate: every leaf is the same float type and there
/// are at most four of them.
pub const Hfa = struct {
    count: u32,
    /// The LLVM spelling of the leaf type: "double" or "float".
    elem: []const u8,
};

/// AAPCS64's HFA rule, which is the part of this file most likely to be got
/// wrong, and the part the reference implementation explicitly punted on and
/// tagged a hazard.
///
/// Two things make it unlike every other rule here:
///
///   1. It IGNORES the 16-byte cutoff. A 32-byte four-double aggregate still
///      goes in registers, as `[4 x double]`. Measured.
///   2. Leaves are counted through nesting. Two structs of two doubles is an
///      HFA of four, not of two. Counting top-level members instead would let
///      a five-leaf aggregate be wrongly register-passed.
///
/// Only aggregates can be HFAs; a bare `double` is a scalar and is classified
/// as one.
pub fn hfaOf(m: *const hir.Module, ty: hir.Ty) ?Hfa {
    const name = switch (ty) {
        .struct_type => |n| n,
        else => return null,
    };
    var elem: ?[]const u8 = null;
    var count: u32 = 0;
    if (!collectHfa(m, name, &elem, &count)) return null;
    if (count == 0 or count > 4) return null;
    return .{ .count = count, .elem = elem.? };
}

/// Walk the leaves. Returns false as soon as the aggregate cannot be an HFA,
/// so a large non-HFA struct costs no more than its first disagreeing field.
fn collectHfa(m: *const hir.Module, name: []const u8, elem: *?[]const u8, count: *u32) bool {
    const s = m.findStruct(name) orelse return false;
    if (s.fields.len == 0) return false;
    for (s.fields) |f| {
        switch (f.ty) {
            .float, .float32 => {
                const spelling: []const u8 = if (f.ty.tag() == .float) "double" else "float";
                if (elem.*) |have| {
                    if (!std.mem.eql(u8, have, spelling)) return false;
                } else {
                    elem.* = spelling;
                }
                count.* += 1;
                if (count.* > 4) return false;
            },
            .struct_type => |inner| {
                if (!collectHfa(m, inner, elem, count)) return false;
            },
            else => return false,
        }
    }
    return true;
}

pub const Class = union(enum) {
    /// Passed and returned as this exact LLVM type: "i64", "double", "i1",
    /// "ptr", or, for an HFA return, the struct's bare NAME. The caller adds
    /// the `%cell_` prefix, which keeps this module allocation free and is
    /// what makes it a leaf.
    direct: []const u8,
    /// Coerced to [n x i64].
    coerce_int: u32,
    /// Coerced to [count x elem]. HFA parameters only.
    coerce_float: struct { count: u32, elem: []const u8 },
    /// Parameter: a plain `ptr`. Return: the function returns void and takes
    /// an `sret` pointer as a prepended first parameter.
    indirect,
    /// Not classified by this module. The caller emits `cannot lower` and
    /// refuses the module. NEVER guess: a refusal is a fact about the
    /// compiler, a wrong placement is a crash in someone's program.
    unclassified,
};

/// The LLVM spelling of a scalar, or null when `ty` is not a scalar.
fn scalarSpelling(ty: hir.Ty) ?[]const u8 {
    return switch (ty) {
        .int, .uint => "i64",
        .int32 => "i32",
        .float => "double",
        .float32 => "float",
        .boolean => "i1",
        .byte => "i8",
        .enum_type => "i32",
        .unit => "void",
        else => null,
    };
}

/// Whether `codegen.applyOwnership` makes `(ty, own)` a POINTER TO THE
/// LENDER'S OBJECT rather than the object itself.
///
/// THIS MIRRORS ONE FUNCTION AND THAT IS THE WHOLE CONTRACT. The C backend is
/// the reference: it writes C and the C compiler places the argument, so
/// whatever `applyOwnership` spells is what the ABI is. This says the same
/// thing so the two newer backends can agree with it, and it is written as a
/// switch over ownership rather than a list of types for the reason the rest
/// of this repository keeps relearning: a list of types is an enumeration,
/// and the form nobody enumerated is the one that ships wrong.
///
/// `applyOwnership` reads, in full:
///
///     if (base.shape.isPrimitive()) return base;      // never a pointer
///     .arc       => cell_arc_t                        // not placed here
///     .exclusive => `T *`                             // EVERY non-primitive
///     .shared    => .string        => cell_str_t      // a view, by value
///                   .record        => `const T *`
///                   .unknown       => `const T *`
///                   else           => T               // by value
///     .owned, .copy => T                              // by value
///
/// The `.exclusive` row is the one this module got wrong. It had a rule about
/// borrowed STRUCTS and applied it to every borrow, so `exclusive String`,
/// `exclusive [T]` and `exclusive T?` were classified BY VALUE while codegen
/// passed a pointer and wrote through it. That is not a placement detail: a
/// write through such a parameter cannot reach the caller, which is exactly
/// what `docs/OWNERSHIP.md` R1 and `runtime/cell_rt.h` section 7 define
/// `exclusive` to do.
///
/// `.unknown` is deliberately absent: `layoutOf` refuses it anyway, and
/// claiming a placement for a type this module cannot size would be the
/// guess this file exists to avoid.
pub fn borrowedByPointer(ty: hir.Ty, own: hir.Ownership) bool {
    // A primitive is passed by value in every mode, including `exclusive`,
    // which is `applyOwnership`'s first line and cell_rt.h section 1.
    if (scalarSpelling(ty) != null) return false;
    return switch (own) {
        .exclusive => true,
        .shared => ty.tag() == .struct_type,
        .owned, .copy, .arc => false,
    };
}

/// How a parameter of `(ty, own)` is placed.
///
/// Ownership is a parameter because it changes the answer:
/// `codegen.applyOwnership` makes `shared Buffer` a `const cell_Buffer *` and
/// `exclusive Buffer` a `cell_Buffer *`, while `owned` and `copy` pass by
/// value.
pub fn classifyParam(m: *const hir.Module, ty: hir.Ty, own: hir.Ownership) Class {
    // Primitives pass by value in EVERY ownership mode. cell_rt.h section 1
    // fixes this and the language depends on it, so the check comes first.
    if (scalarSpelling(ty)) |s| return .{ .direct = s };

    // A borrow the C backend passes by pointer. Measured, not read: a probe
    // declaring `void f(cell_string_t *)`, `void f(cell_slice_t *)` and
    // `void f(cell_opt_i64_t *)` compiled with `cc -S -emit-llvm -O0` on this
    // host emits `define void @f(ptr noundef %0)` for all three, and the test
    // at the bottom of this file re-runs that comparison rather than trusting
    // this sentence.
    //
    // The layout is still demanded first. A `ptr` for a type this module
    // cannot size would let a backend name a pointee it has no spelling for,
    // and `.unclassified` is the honest answer there.
    if (borrowedByPointer(ty, own)) {
        _ = layoutOf(m, ty, own) orelse return .unclassified;
        return .{ .direct = "ptr" };
    }

    const layout = layoutOf(m, ty, own) orelse return .unclassified;

    // The HFA rule is checked BEFORE the size cutoff, because it ignores it.
    if (hfaOf(m, ty)) |h| return .{ .coerce_float = .{ .count = h.count, .elem = h.elem } };

    if (layout.size > 16) return .indirect;
    return .{ .coerce_int = wordsFor(layout.size) };
}

/// How a return of `ty` is placed. Takes no ownership: `hir.Fn.ret` is a bare
/// `Ty` with no annotation the backend acts on.
pub fn classifyReturn(m: *const hir.Module, ty: hir.Ty) Class {
    if (scalarSpelling(ty)) |s| return .{ .direct = s };

    // A return carries no ownership annotation, and codegen treats `-> String`
    // as owning (cell_string_t), so classify it that way.
    const layout = layoutOf(m, ty, .owned) orelse return .unclassified;

    // The measured asymmetry: an HFA PARAMETER coerces to [n x double], but an
    // HFA RETURN is the struct itself. This is the case a single classify()
    // with a flag would get wrong at one call site and not the others.
    if (hfaOf(m, ty) != null) {
        return switch (ty) {
            .struct_type => |n| .{ .direct = n },
            else => .unclassified,
        };
    }

    if (layout.size > 16) return .indirect;
    return .{ .coerce_int = wordsFor(layout.size) };
}

/// Size in 8-byte words, rounded up. A 4-byte aggregate is one word.
fn wordsFor(size: u32) u32 {
    if (size == 0) return 0;
    return (size + 7) / 8;
}

/// Render a parameter's LLVM type, or null when this module cannot place it.
///
/// Lives here rather than in the backend so that the backend and the
/// clang-comparison test below use the SAME renderer. If the test formatted
/// its own prediction, the two could drift: the test would keep passing
/// against clang while the backend emitted something else, which is the exact
/// failure this whole file exists to prevent.
pub fn renderParam(
    arena: std.mem.Allocator,
    m: *const hir.Module,
    ty: hir.Ty,
    own: hir.Ownership,
) ?[]const u8 {
    return renderClass(arena, classifyParam(m, ty, own), ty, false);
}

/// Render a return's LLVM type, or null when this module cannot place it.
/// An `.indirect` return renders as "void"; the caller adds the `sret`
/// parameter, because that changes the signature rather than the type.
pub fn renderReturn(arena: std.mem.Allocator, m: *const hir.Module, ty: hir.Ty) ?[]const u8 {
    return renderClass(arena, classifyReturn(m, ty), ty, true);
}

fn renderClass(
    arena: std.mem.Allocator,
    class: Class,
    ty: hir.Ty,
    is_return: bool,
) ?[]const u8 {
    return switch (class) {
        .direct => |s| blk: {
            // classifyReturn hands back a struct's bare name for an HFA
            // return. The `%cell_` prefix is ours to add.
            if (is_return and ty.tag() == .struct_type) {
                break :blk std.fmt.allocPrint(arena, "%cell_{s}", .{s}) catch null;
            }
            break :blk s;
        },
        .coerce_int => |n| std.fmt.allocPrint(arena, "[{d} x i64]", .{n}) catch null,
        .coerce_float => |f| std.fmt.allocPrint(
            arena,
            "[{d} x {s}]",
            .{ f.count, f.elem },
        ) catch null,
        .indirect => if (is_return) "void" else "ptr",
        .unclassified => null,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Build a module for a test. `hir.Module.structs` is a mutable slice, so a
/// fixture has to pass a `var` array rather than an anonymous `&.{}`, which
/// would be `*const [0]Struct` and coerce only to a const slice.
fn testModule(structs: []hir.Struct) hir.Module {
    return .{ .path = "t", .structs = structs, .enums = &.{}, .fns = &.{} };
}

fn emptyModule() hir.Module {
    const empty = struct {
        var structs: [0]hir.Struct = .{};
    };
    return testModule(&empty.structs);
}

test "scalar layouts match the C ABI in cell_rt.h" {
    const m = emptyModule();
    try std.testing.expectEqual(@as(u32, 8), layoutOf(&m, types.t_int, .copy).?.size);
    try std.testing.expectEqual(@as(u32, 4), layoutOf(&m, types.t_int32, .copy).?.size);
    try std.testing.expectEqual(@as(u32, 8), layoutOf(&m, types.t_float, .copy).?.size);
    try std.testing.expectEqual(@as(u32, 4), layoutOf(&m, types.t_float32, .copy).?.size);
    try std.testing.expectEqual(@as(u32, 1), layoutOf(&m, types.t_bool, .copy).?.size);
    try std.testing.expectEqual(@as(u32, 1), layoutOf(&m, types.t_byte, .copy).?.size);
    // An enum is an int32_t typedef in the C ABI, SPEC 10.3.
    try std.testing.expectEqual(@as(u32, 4), layoutOf(&m, .{ .enum_type = "Color" }, .copy).?.size);
}

test "a struct is laid out with C padding rules" {
    var fields = [_]hir.Field{
        .{ .name = "c", .ty = types.t_byte, .ownership = .copy },
        .{ .name = "a", .ty = types.t_int, .ownership = .copy },
    };
    var structs = [_]hir.Struct{
        .{ .name = "Padded", .fields = &fields, .is_public = true },
    };
    const m = testModule(&structs);
    const l = layoutOf(&m, .{ .struct_type = "Padded" }, .copy).?;
    // byte at 0, 7 bytes padding, i64 at 8. Total 16, aligned 8.
    try std.testing.expectEqual(@as(u32, 16), l.size);
    try std.testing.expectEqual(@as(u32, 8), l.alignment);
}

test "an out-of-scope type has no layout yet" {
    const m = emptyModule();
    try std.testing.expect(layoutOf(&m, types.t_string, .arc) == null);
}

test "two doubles are an HFA of two" {
    var fields = [_]hir.Field{
        .{ .name = "x", .ty = types.t_float, .ownership = .copy },
        .{ .name = "y", .ty = types.t_float, .ownership = .copy },
    };
    var structs = [_]hir.Struct{.{ .name = "Point", .fields = &fields, .is_public = true }};
    const m = testModule(&structs);
    const h = hfaOf(&m, .{ .struct_type = "Point" }).?;
    try std.testing.expectEqual(@as(u32, 2), h.count);
    try std.testing.expectEqualStrings("double", h.elem);
}

test "a mixed aggregate is not an HFA even at 16 bytes" {
    // Measured: clang passes {i64, double} as [2 x i64], not [2 x double].
    var fields = [_]hir.Field{
        .{ .name = "a", .ty = types.t_int, .ownership = .copy },
        .{ .name = "b", .ty = types.t_float, .ownership = .copy },
    };
    var structs = [_]hir.Struct{.{ .name = "Mixed", .fields = &fields, .is_public = true }};
    const m = testModule(&structs);
    try std.testing.expect(hfaOf(&m, .{ .struct_type = "Mixed" }) == null);
}

test "HFA leaf members are counted through nesting, not at the top level" {
    // Two structs of two doubles each is an HFA of FOUR, not of two. Counting
    // top-level members would misclassify this, and a five-leaf aggregate
    // would then be wrongly register-passed.
    var inner_fields = [_]hir.Field{
        .{ .name = "x", .ty = types.t_float, .ownership = .copy },
        .{ .name = "y", .ty = types.t_float, .ownership = .copy },
    };
    var outer_fields = [_]hir.Field{
        .{ .name = "a", .ty = .{ .struct_type = "Pair" }, .ownership = .copy },
        .{ .name = "b", .ty = .{ .struct_type = "Pair" }, .ownership = .copy },
    };
    var structs = [_]hir.Struct{
        .{ .name = "Pair", .fields = &inner_fields, .is_public = true },
        .{ .name = "Quad", .fields = &outer_fields, .is_public = true },
    };
    const m = testModule(&structs);
    const h = hfaOf(&m, .{ .struct_type = "Quad" }).?;
    try std.testing.expectEqual(@as(u32, 4), h.count);
}

test "more than four leaf members is not an HFA" {
    var fields = [_]hir.Field{
        .{ .name = "a", .ty = types.t_float, .ownership = .copy },
        .{ .name = "b", .ty = types.t_float, .ownership = .copy },
        .{ .name = "c", .ty = types.t_float, .ownership = .copy },
        .{ .name = "d", .ty = types.t_float, .ownership = .copy },
        .{ .name = "e", .ty = types.t_float, .ownership = .copy },
    };
    var structs = [_]hir.Struct{.{ .name = "Five", .fields = &fields, .is_public = true }};
    const m = testModule(&structs);
    try std.testing.expect(hfaOf(&m, .{ .struct_type = "Five" }) == null);
}

test "a bare float is not an HFA; only aggregates are" {
    const m = emptyModule();
    try std.testing.expect(hfaOf(&m, types.t_float) == null);
}

fn expectDirect(c: Class, want: []const u8) !void {
    switch (c) {
        .direct => |got| try std.testing.expectEqualStrings(want, got),
        else => return error.NotDirect,
    }
}

test "primitives pass by value in every ownership mode" {
    // cell_rt.h section 1 is explicit, and examples/hello.cell depends on it:
    // add(shared a: Int, shared b: Int) computes a + b, which would not
    // compile if a shared primitive became a pointer.
    const m = emptyModule();
    for ([_]hir.Ownership{ .owned, .shared, .exclusive, .copy, .arc }) |own| {
        try expectDirect(classifyParam(&m, types.t_int, own), "i64");
        try expectDirect(classifyParam(&m, types.t_float, own), "double");
        try expectDirect(classifyParam(&m, types.t_bool, own), "i1");
    }
}

test "a borrowed struct is a pointer, an owned struct is by value" {
    var fields = [_]hir.Field{
        .{ .name = "a", .ty = types.t_int, .ownership = .copy },
        .{ .name = "b", .ty = types.t_int, .ownership = .copy },
    };
    var structs = [_]hir.Struct{.{ .name = "Int2", .fields = &fields, .is_public = true }};
    const m = testModule(&structs);
    const ty: hir.Ty = .{ .struct_type = "Int2" };

    try expectDirect(classifyParam(&m, ty, .shared), "ptr");
    try expectDirect(classifyParam(&m, ty, .exclusive), "ptr");
    switch (classifyParam(&m, ty, .owned)) {
        .coerce_int => |n| try std.testing.expectEqual(@as(u32, 2), n),
        else => return error.WrongClass,
    }
}

test "an HFA coerces to floats as a parameter and returns directly" {
    // Measured: clang emits `define double @f_hfa2([2 x double] %0)` but
    // `define %struct.Hfa2 @r_hfa2()`. The two positions genuinely disagree,
    // which is why this module has two entry points rather than one flag.
    var fields = [_]hir.Field{
        .{ .name = "x", .ty = types.t_float, .ownership = .copy },
        .{ .name = "y", .ty = types.t_float, .ownership = .copy },
    };
    var structs = [_]hir.Struct{.{ .name = "Point", .fields = &fields, .is_public = true }};
    const m = testModule(&structs);
    const ty: hir.Ty = .{ .struct_type = "Point" };

    switch (classifyParam(&m, ty, .owned)) {
        .coerce_float => |f| {
            try std.testing.expectEqual(@as(u32, 2), f.count);
            try std.testing.expectEqualStrings("double", f.elem);
        },
        else => return error.WrongClass,
    }
    // The bare NAME, not "%cell_Point": this module is allocation free, so the
    // caller owns the prefix.
    try expectDirect(classifyReturn(&m, ty), "Point");
}

test "a non-HFA over 16 bytes is indirect in both positions" {
    var fields = [_]hir.Field{
        .{ .name = "a", .ty = types.t_int, .ownership = .copy },
        .{ .name = "b", .ty = types.t_int, .ownership = .copy },
        .{ .name = "c", .ty = types.t_int, .ownership = .copy },
    };
    var structs = [_]hir.Struct{.{ .name = "Int3", .fields = &fields, .is_public = true }};
    const m = testModule(&structs);
    const ty: hir.Ty = .{ .struct_type = "Int3" };
    try std.testing.expect(classifyParam(&m, ty, .owned) == .indirect);
    try std.testing.expect(classifyReturn(&m, ty) == .indirect);
}

test "an out-of-scope type is unclassified, not guessed" {
    const m = emptyModule();
    // [T] used to be the example here. It is now a cell_slice_t, so `arc` is
    // what remains: retain and release are not inserted (OWNERSHIP R11), and
    // placing a cell_arc_t without them would be lowering half a feature.
    try std.testing.expect(classifyParam(&m, types.t_string, .arc) == .unclassified);
}

test "[T] is a cell_slice_t: one header for every element type" {
    // cell_rt.h section 3: a single type-erased header with elem_size passed
    // at each call site, so the layout does not depend on the element and 24
    // bytes puts it on the same indirect path cell_string_t uses.
    const m = emptyModule();
    const elem = types.t_byte;
    const list_ty: hir.Ty = .{ .list = &elem };
    try std.testing.expectEqual(@as(u32, 24), layoutOf(&m, list_ty, .shared).?.size);
    try std.testing.expect(classifyParam(&m, list_ty, .shared) == .indirect);
    try std.testing.expect(classifyReturn(&m, list_ty) == .indirect);
}

test "String's size depends on ownership, and only String's does" {
    // codegen maps `shared String` to a 16-byte cell_str_t, a borrowed
    // {ptr, len} view, and `owned String` to a 24-byte cell_string_t, an
    // owning {ptr, len, cap} buffer. Measured from the C the backend emits:
    //   int64_t cell_a(cell_str_t s);      // shared
    //   int64_t cell_b(cell_string_t s);   // owned
    const m = emptyModule();
    try std.testing.expectEqual(@as(u32, 16), layoutOf(&m, types.t_string, .shared).?.size);
    try std.testing.expectEqual(@as(u32, 24), layoutOf(&m, types.t_string, .owned).?.size);
    try std.testing.expectEqual(@as(u32, 24), layoutOf(&m, types.t_string, .copy).?.size);
    // `exclusive String` is `cell_string_t *`, so the OBJECT it names is the
    // 24-byte owning buffer. Grouping it with `shared` at 16 was the
    // misclassification `borrowedByPointer` was written to close.
    try std.testing.expectEqual(@as(u32, 24), layoutOf(&m, types.t_string, .exclusive).?.size);
    try std.testing.expectEqualStrings("%cell_str", stringStruct(.shared).?);
    try std.testing.expectEqualStrings("%cell_string", stringStruct(.exclusive).?);
}

test "a shared String coerces to two words; an owned one is indirect" {
    const m = emptyModule();
    switch (classifyParam(&m, types.t_string, .shared)) {
        .coerce_int => |n| try std.testing.expectEqual(@as(u32, 2), n),
        else => return error.WrongClass,
    }
    // 24 bytes, so it goes indirect rather than in registers.
    try std.testing.expect(classifyParam(&m, types.t_string, .owned) == .indirect);
    // A SHARED String is NOT a pointer, unlike a borrowed struct: a
    // cell_str_t is already a borrowed view and passes by value.
    switch (classifyParam(&m, types.t_string, .shared)) {
        .direct => return error.ShouldNotBePointer,
        else => {},
    }
}

test "every exclusive aggregate is a pointer, because codegen writes through it" {
    // The divergence this closes, measured at 9e591ab: `classifyParam` said
    // `exclusive String` was `[2 x i64]` while `codegen.applyOwnership`
    // emitted `cell_string_t *`. `llvmemit.zig` followed this module,
    // ACCEPTED the program, gave the binding a 16-byte slot and stored a
    // 24-byte value into it. `mlirmit.zig` refused the same shape, so the two
    // backends also disagreed on the VERDICT.
    //
    // `[T]` is the case that hid it: a cell_slice_t is 24 bytes, so it was
    // already `.indirect` and already rendered as the four characters `ptr`.
    // The spelling was right by coincidence and the MEANING was wrong, since
    // an indirect argument is a caller-allocated copy the callee may scribble
    // on while a borrow is the lender's own object.
    const m = emptyModule();
    const elem = types.t_byte;
    const list_ty: hir.Ty = .{ .list = &elem };
    const inner = types.t_int;
    const opt_ty: hir.Ty = .{ .optional = &inner };

    try expectDirect(classifyParam(&m, types.t_string, .exclusive), "ptr");
    try expectDirect(classifyParam(&m, list_ty, .exclusive), "ptr");
    try expectDirect(classifyParam(&m, opt_ty, .exclusive), "ptr");

    // The predicate itself, so an unenumerated aggregate is covered by the
    // ownership row rather than by having been listed above.
    try std.testing.expect(borrowedByPointer(types.t_string, .exclusive));
    try std.testing.expect(borrowedByPointer(list_ty, .exclusive));
    try std.testing.expect(borrowedByPointer(opt_ty, .exclusive));
    // `shared` does NOT follow: only a struct is a pointer there, matching
    // `applyOwnership`'s `.record => const T *` row.
    try std.testing.expect(!borrowedByPointer(types.t_string, .shared));
    try std.testing.expect(!borrowedByPointer(list_ty, .shared));
    try std.testing.expect(!borrowedByPointer(opt_ty, .shared));
    // And a primitive is by value in every mode, `exclusive` included.
    try std.testing.expect(!borrowedByPointer(types.t_int, .exclusive));
    try std.testing.expect(!borrowedByPointer(types.t_bool, .exclusive));
    try expectDirect(classifyParam(&m, types.t_int, .exclusive), "i64");
}

// ---------------------------------------------------------------------------
// The clang-comparison test
//
// This is the load-bearing test of this module. A hand-written ABI that
// nothing checks rots silently, and the rot surfaces as a wrong answer in a
// linked program rather than as a build failure.
//
// For each shape it builds BOTH a C declaration and the equivalent Cell type,
// runs clang on the C, runs this module on the Cell, and asserts they agree.
// It is a live comparison against the compiler that owns the ABI, not a golden
// file: a golden file records what clang did once, this records what clang
// does now.
// ---------------------------------------------------------------------------

/// One shape, expressed twice: once for clang and once for us.
const ProbeCase = struct {
    name: []const u8,
    /// The body of a C struct, e.g. "double x, y;".
    c_body: []const u8,
    /// The equivalent Cell field types, in order.
    fields: []const hir.Ty,
};

test "the classifier predicts what clang actually does" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Skip rather than pass vacuously when the toolchain is absent, following
    // the precedent set by the MLIR execution test in mlirmit.zig. A test that
    // silently succeeds when its subject is missing is worse than no test.
    const have_cc = std.process.run(gpa, io, .{ .argv = &.{ "cc", "--version" } }) catch
        return error.SkipZigTest;
    gpa.free(have_cc.stdout);
    gpa.free(have_cc.stderr);
    if (!have_cc.term.success()) return error.SkipZigTest;

    const f = types.t_float;
    const i = types.t_int;
    const b = types.t_byte;

    const cases = [_]ProbeCase{
        .{ .name = "Hfa2", .c_body = "double x; double y;", .fields = &.{ f, f } },
        .{ .name = "Hfa4", .c_body = "double a; double b; double c; double d;", .fields = &.{ f, f, f, f } },
        .{ .name = "Int2", .c_body = "long long a; long long b;", .fields = &.{ i, i } },
        .{ .name = "Int3", .c_body = "long long a; long long b; long long c;", .fields = &.{ i, i, i } },
        .{ .name = "Mixed", .c_body = "long long a; double b;", .fields = &.{ i, f } },
        .{ .name = "Padded", .c_body = "char c; long long a;", .fields = &.{ b, i } },
    };

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    for (cases, 0..) |case, idx| {
        // Build the Cell side.
        var fields = try arena.alloc(hir.Field, case.fields.len);
        for (case.fields, 0..) |ty, k| {
            fields[k] = .{
                .name = try std.fmt.allocPrint(arena, "f{d}", .{k}),
                .ty = ty,
                .ownership = .copy,
            };
        }
        var structs = [_]hir.Struct{
            .{ .name = case.name, .fields = fields, .is_public = true },
        };
        const m = testModule(&structs);
        const ty: hir.Ty = .{ .struct_type = case.name };

        const want_param = renderParam(arena, &m, ty, .owned).?;
        const want_return = renderReturn(arena, &m, ty).?;

        // Build the C side and ask clang.
        const src = try std.fmt.allocPrint(arena,
            \\typedef struct {{ {s} }} T;
            \\long long p_in(T v);
            \\long long p_in(T v) {{ (void)v; return 0; }}
            \\T r_out(void);
            \\T r_out(void) {{ T t; __builtin_memset(&t, 0, sizeof t); return t; }}
        , .{case.c_body});

        const file = try std.fmt.allocPrint(arena, "probe{d}.c", .{idx});
        try tmp.dir.writeFile(io, .{ .sub_path = file, .data = src });

        const run = try std.process.run(gpa, io, .{
            .argv = &.{ "cc", "-S", "-emit-llvm", "-O0", file, "-o", "-" },
            .cwd = .{ .dir = tmp.dir },
        });
        defer gpa.free(run.stdout);
        defer gpa.free(run.stderr);
        if (!run.term.success()) {
            std.debug.print("cc failed on {s}:\n{s}\n", .{ case.name, run.stderr });
            return error.ProbeFailed;
        }

        const param_line = lineContaining(run.stdout, "@p_in(") orelse return error.NoParamDefine;
        const return_line = lineContaining(run.stdout, "@r_out(") orelse return error.NoReturnDefine;

        // The parameter form must appear literally in clang's signature.
        if (std.mem.indexOf(u8, param_line, want_param) == null) {
            std.debug.print(
                "{s}: we predict parameter '{s}', clang emitted:\n  {s}\n",
                .{ case.name, want_param, param_line },
            );
            return error.ParamClassDisagrees;
        }

        // Returns need one translation: we say "%cell_Name" where clang says
        // "%struct.T", and we say "void" where clang says "void" plus sret.
        if (std.mem.startsWith(u8, want_return, "%cell_")) {
            if (std.mem.indexOf(u8, return_line, "%struct.T") == null) {
                std.debug.print(
                    "{s}: we predict a direct struct return, clang emitted:\n  {s}\n",
                    .{ case.name, return_line },
                );
                return error.ReturnClassDisagrees;
            }
        } else if (std.mem.eql(u8, want_return, "void")) {
            if (std.mem.indexOf(u8, return_line, "sret") == null) {
                std.debug.print(
                    "{s}: we predict an sret return, clang emitted:\n  {s}\n",
                    .{ case.name, return_line },
                );
                return error.ReturnClassDisagrees;
            }
        } else if (std.mem.indexOf(u8, return_line, want_return) == null) {
            std.debug.print(
                "{s}: we predict return '{s}', clang emitted:\n  {s}\n",
                .{ case.name, want_return, return_line },
            );
            return error.ReturnClassDisagrees;
        }
    }
}

/// One runtime type in one ownership mode, expressed twice: the C parameter
/// the reference backend emits for it, and the Cell `(ty, own)` pair this
/// module classifies.
const OwnedProbeCase = struct {
    name: []const u8,
    /// The C parameter declaration `codegen.applyOwnership` produces, spelled
    /// against the REAL `runtime/cell_rt.h` rather than a transcription of
    /// it, so a change to the header breaks this test instead of drifting
    /// past it.
    c_param: []const u8,
    own: hir.Ownership,
};

test "the ownership rows predict what clang does with the runtime's own types" {
    // THE TEST THE PREVIOUS PROBE DID NOT HAVE. Its six cases are all
    // `.owned` structs, so the ownership axis was never compared against
    // clang at all, and `exclusive String` sat misclassified underneath a
    // module whose header says every fact in it was measured.
    //
    // The Cell side is built here; the C side is compiled against the actual
    // cell_rt.h, which is why this needs the repository's `runtime/` on the
    // include path and follows llvmemit.zig's tests in finding it from the
    // process's own working directory.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const have_cc = std.process.run(gpa, io, .{ .argv = &.{ "cc", "--version" } }) catch
        return error.SkipZigTest;
    gpa.free(have_cc.stdout);
    gpa.free(have_cc.stderr);
    if (!have_cc.term.success()) return error.SkipZigTest;

    var cwd_buf: [4096]u8 = undefined;
    const cwd_len = std.process.currentPath(io, &cwd_buf) catch return error.SkipZigTest;
    const include = try std.fmt.allocPrint(gpa, "{s}/runtime", .{cwd_buf[0..cwd_len]});
    defer gpa.free(include);

    const elem = types.t_byte;
    const list_ty: hir.Ty = .{ .list = &elem };
    const inner = types.t_int;
    const opt_ty: hir.Ty = .{ .optional = &inner };

    // `ty` cannot live in the struct literal beside a pointer to a stack
    // local in a comptime-known array, so the two halves are parallel arrays.
    const cases = [_]OwnedProbeCase{
        .{ .name = "excl_string", .c_param = "cell_string_t *v", .own = .exclusive },
        .{ .name = "shared_string", .c_param = "cell_str_t v", .own = .shared },
        .{ .name = "owned_string", .c_param = "cell_string_t v", .own = .owned },
        .{ .name = "excl_slice", .c_param = "cell_slice_t *v", .own = .exclusive },
        .{ .name = "shared_slice", .c_param = "cell_slice_t v", .own = .shared },
        .{ .name = "excl_opt", .c_param = "cell_opt_i64_t *v", .own = .exclusive },
        .{ .name = "copy_opt", .c_param = "cell_opt_i64_t v", .own = .copy },
        .{ .name = "excl_int", .c_param = "int64_t v", .own = .exclusive },
    };
    const tys = [_]hir.Ty{
        types.t_string,
        types.t_string,
        types.t_string,
        list_ty,
        list_ty,
        opt_ty,
        opt_ty,
        types.t_int,
    };

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    try src.appendSlice(gpa, "#include \"cell_rt.h\"\n");
    for (cases) |case| {
        try src.appendSlice(gpa, try std.fmt.allocPrint(
            arena,
            "void {s}({s});\nvoid {s}({s}) {{ (void)v; }}\n",
            .{ case.name, case.c_param, case.name, case.c_param },
        ));
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "own_probe.c", .data = src.items });

    const m = emptyModule();
    const run = try std.process.run(gpa, io, .{
        .argv = &.{ "cc", "-S", "-emit-llvm", "-O0", "-I", include, "own_probe.c", "-o", "-" },
        .cwd = .{ .dir = tmp.dir },
    });
    defer gpa.free(run.stdout);
    defer gpa.free(run.stderr);
    if (!run.term.success()) {
        std.debug.print("cc failed on the ownership probe:\n{s}\n", .{run.stderr});
        return error.ProbeFailed;
    }

    for (cases, tys) |case, ty| {
        const want = renderParam(arena, &m, ty, case.own) orelse {
            std.debug.print("{s}: this module refuses to place it\n", .{case.name});
            return error.Unclassified;
        };
        const needle = try std.fmt.allocPrint(arena, "@{s}(", .{case.name});
        const line = lineContaining(run.stdout, needle) orelse return error.NoParamDefine;
        if (std.mem.indexOf(u8, line, want) == null) {
            std.debug.print(
                "{s}: we predict parameter '{s}', clang emitted:\n  {s}\n",
                .{ case.name, want, line },
            );
            return error.ParamClassDisagrees;
        }
    }
}

fn lineContaining(haystack: []const u8, needle: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, haystack, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, needle) != null and
            std.mem.startsWith(u8, line, "define")) return line;
    }
    return null;
}
