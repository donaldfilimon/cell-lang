//! C backend data model: shapes, C types, locals, callees, and optional instances.
//! Part of the C backend; the rules and their rationale are in the module header of `../codegen.zig`.

const ast = @import("../ast.zig");

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
    /// The DECLARED element type, for a `slice`. Null when the type was not
    /// written down (an inferred `let`, or `CType.slice` used as a bare
    /// spelling), in which case the element type has to be inferred from the
    /// literal's first item and can disagree with what the consumer reads.
    ///
    /// `cell_slice_t` is type-erased: it carries a byte length and a stride,
    /// and nothing about it tells C what the elements are. So a list literal
    /// is the one expression whose element C type cannot be recovered from
    /// the expression itself, and getting it wrong is SILENT. `let owned zs:
    /// [String] = [a, a]` with an `arc` `a` built a buffer of `cell_arc_t`
    /// while the declared type said `cell_string_t`, passed `cell check`,
    /// compiled at `-Wall -Wextra -Werror`, and stayed clean under
    /// AddressSanitizer, because reinterpreting a refcount box pointer as a
    /// string length is type confusion rather than a memory error: a
    /// `shared [String]` callee read `len = 105690555222384`.
    ///
    /// Carrying the declared element down to `emitListLit` is what makes
    /// that loud. `applyOwnership` and `pointerTo` must preserve this field
    /// or it vanishes for `shared [T]` and `exclusive [T]`.
    elem: ?*const CType = null,
    /// What this points AT, set by `pointerTo`, which is the only thing in
    /// this file that ever sets `pointer`. Null for a non-pointer.
    ///
    /// Needed because a whole-value assignment through an `exclusive` borrow
    /// has to write the POINTEE, so it needs that type to lower the right
    /// side against. Recovering it by string surgery on `text` (stripping a
    /// leading `const ` and a trailing ` *`) would work today and break the
    /// first time a spelling changes; carrying it is exact.
    pointee: ?*const CType = null,
    /// For `optional`: the `T` of `T?`. For `result`: the ok payload. Null
    /// elsewhere. Preserved by `applyOwnership` and `pointerTo` like `elem`.
    payload: ?*const CType = null,
    /// For `result`: the `E`. Null elsewhere.
    err_payload: ?*const CType = null,

    pub const unknown: CType = .{ .text = "void*", .shape = .unknown };
    pub const void_type: CType = .{ .text = "void", .shape = .unit };
    pub const int64: CType = .{ .text = "int64_t", .shape = .integer };
    pub const float64: CType = .{ .text = "double", .shape = .floating };
    pub const boolean: CType = .{ .text = "bool", .shape = .boolean };
    pub const str: CType = .{ .text = "cell_str_t", .shape = .str };
    pub const string: CType = .{ .text = "cell_string_t", .shape = .string };
    pub const slice: CType = .{ .text = "cell_slice_t", .shape = .slice };
    pub const arc: CType = .{ .text = "cell_arc_t", .shape = .arc };
    /// The deprecated ABI-1 spelling, used only for a Result pair cell_rt.h
    /// has no instance for (see lowerType).
    pub const result: CType = .{ .text = "cell_result_t", .shape = .result };
};

/// One binding visible while emitting a function body.
pub const Local = struct {
    name: []const u8,
    ty: CType,
    /// The declared annotation, read straight off the AST node exactly as
    /// borrowck's own `Binding.ownership` is. Used, not `ty.shape`, to
    /// decide drop eligibility: a `shared`/`copy` local can end up with the
    /// same shape as an `owned` one when its initializer is a call (whose
    /// result type always lowers as owned; see `letType`), so shape alone
    /// cannot tell an owner from a borrow here.
    ownership: ast.Ownership,
    /// The id borrowck assigned to this exact declaration. See the module
    /// doc comment's id-numbering agreement.
    id: u32,
    /// True for a `let`/`var` local and for a parameter (R11 row 1). False
    /// for a match-arm binding, which the module doc comment excludes from
    /// dropping, and cleared by `pushLocal` when it cannot positively confirm
    /// a binding id. Only a candidate: `pendingDropsSince` still requires an
    /// `owned` or `arc` annotation and an unmoved place.
    ///
    /// This is not a return-retain question. A match-arm binding is
    /// undroppable and is still retained when returned, because it is a
    /// bitwise copy of a scrutinee this function may be releasing. A field
    /// named `is_param` once carried that distinction, and removing it on a
    /// derivation that missed the BLOCK arm body (`match s { b => { return b }
    /// }`) reopened a use-after-free; since R11 row 1 no declared binding
    /// is exempt from the retain, so the field went away with the exemption.
    droppable: bool,
};

/// Where a value-position `if`, `match`, or `block` must leave its result,
/// and the C type of that slot.
///
/// The type used to be absent, and its absence was a use-after-free. Each
/// branch assigned into the destination with a bare `emitExpr`, so an `arc`
/// place flowing out of a branch (`let arc r = if (c) { a } else { b }`)
/// aliased the box without retaining it, and scope exit then released both
/// `r` and `a`. A value slot is a position with a declared type exactly as a
/// parameter or a `let` is, so it has to answer the same conversion
/// question, and it cannot answer it without knowing the type.
pub const Dest = struct {
    name: []const u8,
    ty: CType,
};

/// A resolved call target. `symbol` is null when the callee is a computed
/// expression rather than a name.
pub const Callee = struct {
    symbol: ?[]const u8,
    def: ?ast.FnDef,
};

/// One `CELL_DEFINE_OPTIONAL` instantiation the module needs.
/// Where a struct is in the dependency-ordered typedef walk.
/// `visiting` doubles as the cycle mark: meeting it again means the module's
/// structs contain each other, which no emission order can fix.
pub const StructEmitState = enum { unvisited, visiting, emitted };

pub const OptionalInst = struct {
    /// Macro base, for example `cell_opt_Point`.
    base: []const u8,
    /// Element spelling, for example `cell_Point`.
    elem: []const u8,
    /// False for the instances cell_rt.h already defines.
    generated: bool,
};
