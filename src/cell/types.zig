//! The Cell type representation used by `typecheck.zig`.
//!
//! A tagged union allocated out of an arena, not an interning table. Interning
//! buys pointer equality and one allocation per distinct type, but it needs a
//! structural hash context over a recursive union, and the payoff only arrives
//! at a program size this compiler is nowhere near. The arena gives the same
//! lifetime story (one `deinit`) for a fraction of the code, and `compatible`
//! below is a structural comparison either way.
//!
//! Type aliases are folded at construction: `Int` and `Int64` are one tag,
//! `UInt` and `UInt64` are one tag, `Float` and `Float64` are one tag. That
//! matches `codegen.mapPrimitive`, which maps each pair to a single C type, and
//! it is what lets a `1.0` literal initialize a `Float64` field.
//!
//! Ownership is deliberately NOT part of a type. `ast.Param` and `ast.Field`
//! carry ownership beside the type, so a `shared Int` parameter and an `Int`
//! local hold the same type and differ only in how they may be used. A type
//! written `shared T` lowers to `T`.

const std = @import("std");
const Io = std.Io;

pub const Func = struct {
    params: []const Type,
    ret: *const Type,
};

pub const ResultType = struct {
    ok: *const Type,
    err: *const Type,
};

pub const Type = union(enum) {
    /// The type of anything the checker could not work out. It absorbs
    /// operations rather than producing a second diagnostic, so one unresolved
    /// name yields one error instead of one per use.
    unknown,
    unit,
    /// `Int` and `Int64`.
    int,
    int32,
    /// `UInt` and `UInt64`.
    uint,
    /// `Float` and `Float64`.
    float,
    float32,
    boolean,
    string,
    byte,
    optional: *const Type,
    list: *const Type,
    result: ResultType,
    /// A user struct, named. Field lookup goes through the checker's table.
    struct_type: []const u8,
    /// A user enum, named.
    enum_type: []const u8,
    func: Func,

    pub fn tag(self: Type) std.meta.Tag(Type) {
        return std.meta.activeTag(self);
    }

    pub fn isUnknown(self: Type) bool {
        return self.tag() == .unknown;
    }

    pub fn isNumeric(self: Type) bool {
        return switch (self) {
            .int, .int32, .uint, .float, .float32, .byte => true,
            else => false,
        };
    }
};

/// Singletons for the payload-free variants. A union field is not a value the
/// way an enum field is, so `Type.int` does not name anything; these do, and
/// they give `&t_int` a stable address for the pointer-carrying variants.
pub const t_unknown: Type = .unknown;
pub const t_unit: Type = .unit;
pub const t_int: Type = .int;
pub const t_int32: Type = .int32;
pub const t_uint: Type = .uint;
pub const t_float: Type = .float;
pub const t_float32: Type = .float32;
pub const t_bool: Type = .boolean;
pub const t_string: Type = .string;
pub const t_byte: Type = .byte;

/// The eleven primitive names `codegen.mapPrimitive` recognizes, and nothing
/// else. A name that is not here is a user type or unresolved.
pub fn fromPrimitiveName(text: []const u8) ?Type {
    const table = .{
        .{ "Int", t_int },
        .{ "Int64", t_int },
        .{ "Int32", t_int32 },
        .{ "UInt", t_uint },
        .{ "UInt64", t_uint },
        .{ "Float", t_float },
        .{ "Float64", t_float },
        .{ "Float32", t_float32 },
        .{ "Bool", t_bool },
        .{ "String", t_string },
        .{ "Byte", t_byte },
    };
    inline for (table) |entry| {
        if (std.mem.eql(u8, text, entry[0])) return entry[1];
    }
    return null;
}

/// Structural compatibility, tolerant of `unknown` on either side at any
/// depth. `[]` types as `list(unknown)` so it initializes a `[Byte]` field
/// without the checker inventing an element type it cannot know.
pub fn compatible(a: Type, b: Type) bool {
    if (a.isUnknown() or b.isUnknown()) return true;
    return switch (a) {
        .unknown => true,
        .unit, .int, .int32, .uint, .float, .float32, .boolean, .string, .byte => a.tag() == b.tag(),
        .optional => |ai| switch (b) {
            .optional => |bi| compatible(ai.*, bi.*),
            else => false,
        },
        .list => |ai| switch (b) {
            .list => |bi| compatible(ai.*, bi.*),
            else => false,
        },
        .result => |ar| switch (b) {
            .result => |br| compatible(ar.ok.*, br.ok.*) and compatible(ar.err.*, br.err.*),
            else => false,
        },
        .struct_type => |an| switch (b) {
            .struct_type => |bn| std.mem.eql(u8, an, bn),
            else => false,
        },
        .enum_type => |an| switch (b) {
            .enum_type => |bn| std.mem.eql(u8, an, bn),
            else => false,
        },
        .func => |af| switch (b) {
            .func => |bf| blk: {
                if (af.params.len != bf.params.len) break :blk false;
                for (af.params, bf.params) |ap, bp| {
                    if (!compatible(ap, bp)) break :blk false;
                }
                break :blk compatible(af.ret.*, bf.ret.*);
            },
            else => false,
        },
    };
}

/// Render a type the way a Cell programmer writes it, so a diagnostic reads in
/// source syntax rather than in compiler tags.
pub fn write(ty: Type, w: *Io.Writer) Io.Writer.Error!void {
    switch (ty) {
        .unknown => try w.writeAll("<unknown>"),
        .unit => try w.writeAll("()"),
        .int => try w.writeAll("Int"),
        .int32 => try w.writeAll("Int32"),
        .uint => try w.writeAll("UInt"),
        .float => try w.writeAll("Float"),
        .float32 => try w.writeAll("Float32"),
        .boolean => try w.writeAll("Bool"),
        .string => try w.writeAll("String"),
        .byte => try w.writeAll("Byte"),
        .optional => |inner| {
            try write(inner.*, w);
            try w.writeByte('?');
        },
        .list => |inner| {
            try w.writeByte('[');
            try write(inner.*, w);
            try w.writeByte(']');
        },
        .result => |r| {
            try w.writeAll("Result<");
            try write(r.ok.*, w);
            try w.writeAll(", ");
            try write(r.err.*, w);
            try w.writeByte('>');
        },
        .struct_type, .enum_type => |n| try w.writeAll(n),
        .func => |f| {
            try w.writeAll("fn(");
            for (f.params, 0..) |p, i| {
                if (i > 0) try w.writeAll(", ");
                try write(p, w);
            }
            try w.writeAll(") -> ");
            try write(f.ret.*, w);
        },
    }
}

/// `write` into memory owned by `allocator`. Callers pass an arena, so the
/// result lives as long as the diagnostic that quotes it.
pub fn name(allocator: std.mem.Allocator, ty: Type) std.mem.Allocator.Error![]const u8 {
    var aw: Io.Writer.Allocating = .init(allocator);
    // An `Allocating` writer fails only when its allocator fails, so a
    // `WriteFailed` here is out of memory and nothing else.
    write(ty, &aw.writer) catch return error.OutOfMemory;
    return aw.written();
}

// -- tests ------------------------------------------------------------------

test "Int and Int64 fold to one tag, and so do the UInt and Float pairs" {
    try std.testing.expect(compatible(fromPrimitiveName("Int").?, fromPrimitiveName("Int64").?));
    try std.testing.expect(compatible(fromPrimitiveName("UInt").?, fromPrimitiveName("UInt64").?));
    try std.testing.expect(compatible(fromPrimitiveName("Float").?, fromPrimitiveName("Float64").?));
    try std.testing.expect(!compatible(fromPrimitiveName("Float").?, fromPrimitiveName("Float32").?));
    try std.testing.expect(!compatible(fromPrimitiveName("Int").?, fromPrimitiveName("Int32").?));
    try std.testing.expect(fromPrimitiveName("Strng") == null);
}

test "unknown is compatible with everything, at the top level and nested" {
    const byte: Type = .byte;
    const unknown: Type = .unknown;
    try std.testing.expect(compatible(unknown, byte));
    try std.testing.expect(compatible(byte, unknown));

    const list_of_byte: Type = .{ .list = &byte };
    const list_of_unknown: Type = .{ .list = &unknown };
    try std.testing.expect(compatible(list_of_byte, list_of_unknown));

    const list_of_string: Type = .{ .list = &t_string };
    try std.testing.expect(!compatible(list_of_byte, list_of_string));
}

test "named types compare by name, not by tag" {
    const a: Type = .{ .struct_type = "Point" };
    const b: Type = .{ .struct_type = "Point" };
    const c: Type = .{ .struct_type = "Buffer" };
    const e: Type = .{ .enum_type = "Point" };
    try std.testing.expect(compatible(a, b));
    try std.testing.expect(!compatible(a, c));
    try std.testing.expect(!compatible(a, e));
}

test "functions compare by arity, parameters, and return type" {
    const int: Type = .int;
    const unit: Type = .unit;
    const one: Type = .{ .func = .{ .params = &.{ .int, .boolean }, .ret = &int } };
    const same: Type = .{ .func = .{ .params = &.{ .int, .boolean }, .ret = &int } };
    const fewer: Type = .{ .func = .{ .params = &.{.int}, .ret = &int } };
    const other_ret: Type = .{ .func = .{ .params = &.{ .int, .boolean }, .ret = &unit } };
    try std.testing.expect(compatible(one, same));
    try std.testing.expect(!compatible(one, fewer));
    try std.testing.expect(!compatible(one, other_ret));
}

test "type names render in Cell source syntax" {
    const arena_backing = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(arena_backing);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const byte: Type = .byte;
    const int: Type = .int;
    const opt: Type = .{ .optional = &int };

    try std.testing.expectEqualStrings("Byte", try name(arena, byte));
    try std.testing.expectEqualStrings("Int?", try name(arena, opt));
    try std.testing.expectEqualStrings("[Int?]", try name(arena, .{ .list = &opt }));
    try std.testing.expectEqualStrings("()", try name(arena, .unit));
    try std.testing.expectEqualStrings("<unknown>", try name(arena, .unknown));
    try std.testing.expectEqualStrings("Point", try name(arena, .{ .struct_type = "Point" }));
    try std.testing.expectEqualStrings(
        "Result<Int, String>",
        try name(arena, .{ .result = .{ .ok = &int, .err = &t_string } }),
    );
    try std.testing.expectEqualStrings(
        "fn(Int, Byte) -> ()",
        try name(arena, .{ .func = .{ .params = &.{ .int, .byte }, .ret = &t_unit } }),
    );
}

test "isNumeric covers every integer and float tag and nothing else" {
    try std.testing.expect(Type.isNumeric(.int));
    try std.testing.expect(Type.isNumeric(.int32));
    try std.testing.expect(Type.isNumeric(.uint));
    try std.testing.expect(Type.isNumeric(.float));
    try std.testing.expect(Type.isNumeric(.float32));
    try std.testing.expect(Type.isNumeric(.byte));
    try std.testing.expect(!Type.isNumeric(.boolean));
    try std.testing.expect(!Type.isNumeric(.string));
    try std.testing.expect(!Type.isNumeric(.unit));
    try std.testing.expect(!Type.isNumeric(.unknown));
}
