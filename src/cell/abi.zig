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
pub fn layoutOf(m: *const hir.Module, ty: hir.Ty) ?Layout {
    return switch (ty) {
        .int, .uint, .float => .{ .size = 8, .alignment = 8 },
        .int32, .float32 => .{ .size = 4, .alignment = 4 },
        // An enum is an int32_t typedef in the C ABI (SPEC 10.3), so both
        // backends agree on its width.
        .enum_type => .{ .size = 4, .alignment = 4 },
        .boolean, .byte => .{ .size = 1, .alignment = 1 },
        .unit => .{ .size = 0, .alignment = 1 },
        .struct_type => |name| structLayout(m, name),
        // Out of scope for now: String, [T], T?, Result. Adding them means
        // threading ownership through, because `shared String` is a 16-byte
        // cell_str_t while `owned String` is a 24-byte cell_string_t. Until
        // then a null here becomes a `cannot lower` diagnostic, which is what
        // both backends already do with these types.
        .string, .list, .optional, .result, .func, .unknown => null,
    };
}

/// C struct layout: each field aligned to its own alignment, the struct
/// aligned to its widest member, trailing padding to a multiple of that.
fn structLayout(m: *const hir.Module, name: []const u8) ?Layout {
    const s = m.findStruct(name) orelse return null;
    var offset: u32 = 0;
    var max_align: u32 = 1;
    for (s.fields) |f| {
        const fl = layoutOf(m, f.ty) orelse return null;
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

    const layout = layoutOf(m, ty) orelse return .unclassified;

    switch (own) {
        .shared, .exclusive => return .{ .direct = "ptr" },
        .owned, .copy, .arc => {},
    }

    // The HFA rule is checked BEFORE the size cutoff, because it ignores it.
    if (hfaOf(m, ty)) |h| return .{ .coerce_float = .{ .count = h.count, .elem = h.elem } };

    if (layout.size > 16) return .indirect;
    return .{ .coerce_int = wordsFor(layout.size) };
}

/// How a return of `ty` is placed. Takes no ownership: `hir.Fn.ret` is a bare
/// `Ty` with no annotation the backend acts on.
pub fn classifyReturn(m: *const hir.Module, ty: hir.Ty) Class {
    if (scalarSpelling(ty)) |s| return .{ .direct = s };

    const layout = layoutOf(m, ty) orelse return .unclassified;

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
    try std.testing.expectEqual(@as(u32, 8), layoutOf(&m, types.t_int).?.size);
    try std.testing.expectEqual(@as(u32, 4), layoutOf(&m, types.t_int32).?.size);
    try std.testing.expectEqual(@as(u32, 8), layoutOf(&m, types.t_float).?.size);
    try std.testing.expectEqual(@as(u32, 4), layoutOf(&m, types.t_float32).?.size);
    try std.testing.expectEqual(@as(u32, 1), layoutOf(&m, types.t_bool).?.size);
    try std.testing.expectEqual(@as(u32, 1), layoutOf(&m, types.t_byte).?.size);
    // An enum is an int32_t typedef in the C ABI, SPEC 10.3.
    try std.testing.expectEqual(@as(u32, 4), layoutOf(&m, .{ .enum_type = "Color" }).?.size);
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
    const l = layoutOf(&m, .{ .struct_type = "Padded" }).?;
    // byte at 0, 7 bytes padding, i64 at 8. Total 16, aligned 8.
    try std.testing.expectEqual(@as(u32, 16), l.size);
    try std.testing.expectEqual(@as(u32, 8), l.alignment);
}

test "an out-of-scope type has no layout yet" {
    const m = emptyModule();
    try std.testing.expect(layoutOf(&m, types.t_string) == null);
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
    try std.testing.expect(classifyParam(&m, types.t_string, .shared) == .unclassified);
    try std.testing.expect(classifyReturn(&m, types.t_string) == .unclassified);
}
