# Aggregate ABI Classifier Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `src/cell/abi.zig`, a leaf module that classifies how a Cell type is passed and returned under AAPCS64, prove it against clang, and make the LLVM backend use it — which fixes a latent bug where structs are passed by a convention C does not agree with.

**Architecture:** A pure function of `(module, type, ownership)` returning a `Class`. It imports `hir.zig` and `types.zig` and nothing else, so it is testable standalone and neither backend can smuggle target knowledge past it. Correctness is enforced by a test that compiles a C probe with clang and asserts the classifier predicted clang's exact signature.

**Tech Stack:** Zig master (`0.17.0-dev.2018+ab30a0b9a` via zvm), Apple clang 21.0.0, target `arm64-apple-darwin27.0.0`.

**Spec:** `docs/superpowers/specs/2026-09-07-aggregate-abi-design.md`

## Global Constraints

- Zig master. Build and test with `-Dswift=false` ALWAYS; the Swift step hardcodes `/Applications/Xcode-beta.app` and fails without that exact beta.
- Capture exit codes directly. `cmd | tail` reports tail's status and has manufactured false green claims in this repo before. Use `cmd > log 2>&1; echo "EXIT: $?"`.
- A failed `zig build` leaves the previous binary in `zig-out/bin/cell`. Check the build's exit code before trusting any run of the binary.
- Use `cc`, never `zig cc`, for anything involving `.ll` files. Measured: `zig cc -x ir` fails with `language not recognized: ir`.
- Emit no `target triple` in LLVM IR. Measured: `clang -x ir` then warns `-Woverride-module`.
- `runtime/cell_rt.h` is NOT modified by this plan.
- No em dashes in source comments, docs, or commit messages.
- The gate after every task: `zig build -Dswift=false`, `zig build test -Dswift=false`, and the four corpus contracts in `examples/README.md`.

## Correction to the spec

The spec sketches `classifyParam(m: *const hir.Module, ty: hir.Ty)`. That signature is insufficient and would be wrong on its first real call. `codegen.applyOwnership` (`src/cell/codegen.zig:997-1009`) makes ownership change the C type of an aggregate:

- `shared Buffer` lowers to `const cell_Buffer *`, `exclusive Buffer` to `cell_Buffer *`, but `owned Buffer` and `copy Buffer` pass **by value**.
- `shared String` is a 16-byte `cell_str_t`; `owned String` is a 24-byte `cell_string_t`.

So the classifier takes ownership. Every function below reflects that.

Primitives are exempt: `runtime/cell_rt.h` section 1 states they pass and return by value in **every** ownership mode, and `examples/hello.cell` depends on it (`add(shared a: Int, shared b: Int)` computes `a + b`, which would not compile if a shared primitive were a pointer).

## Scope

This plan implements spec steps 0 and 1: the classifier, its proof, and its first consumer.

**In scope:** scalars, payload-free enums, and user structs.

**Out of scope, and they return `.unclassified` here:** `String`, `[T]`, `T?`, `Result`, `arc`. Those are spec step 2 and a later plan. `.unclassified` produces the `cannot lower` diagnostic both backends already emit for them, so behavior for those types is unchanged by this plan.

## File Structure

| File | Responsibility |
|---|---|
| `src/cell/abi.zig` (create) | Layout, HFA detection, and classification. Leaf module: imports `hir.zig` and `types.zig` only. |
| `src/root.zig` (modify) | Export `abi` alongside the other stages so `zig test src/root.zig` reaches its tests. |
| `src/cell/llvmemit.zig` (modify) | Consume the classifier when emitting parameters and returns. |

---

### Task 1: Layout — size and alignment

**Files:**
- Create: `src/cell/abi.zig`
- Modify: `src/root.zig` (one line, add the export)
- Test: in `src/cell/abi.zig` (this repo puts tests beside the code)

**Interfaces:**
- Consumes: `hir.Module`, `hir.Ty`, `hir.Struct`, `hir.Field` from `src/cell/hir.zig`.
- Produces: `pub const Layout = struct { size: u32, alignment: u32 }` and `pub fn layoutOf(m: *const hir.Module, ty: hir.Ty) ?Layout`. Returns null for a type this plan does not classify.

- [ ] **Step 1: Write the failing test**

Create `src/cell/abi.zig` containing ONLY this test plus the imports, so the test fails to compile for the right reason:

```zig
//! AAPCS64 classification: how a Cell type is passed and returned.
//!
//! A LEAF MODULE. It imports hir and types and nothing else, so it is
//! testable standalone and neither backend can smuggle target knowledge past
//! it. Every fact here was measured with `cc -S -emit-llvm` on this host, not
//! read from documentation; see docs/superpowers/specs/2026-09-07-aggregate-abi-design.md.

const std = @import("std");
const hir = @import("hir.zig");
const types = @import("types.zig");

test "scalar layouts match the C ABI in cell_rt.h" {
    const m: hir.Module = .{ .path = "t", .structs = &.{}, .enums = &.{}, .fns = &.{} };
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
    const m: hir.Module = .{ .path = "t", .structs = &structs, .enums = &.{}, .fns = &.{} };
    const l = layoutOf(&m, .{ .struct_type = "Padded" }).?;
    // byte at 0, 7 bytes padding, i64 at 8. Total 16, aligned 8.
    try std.testing.expectEqual(@as(u32, 16), l.size);
    try std.testing.expectEqual(@as(u32, 8), l.alignment);
}

test "an out-of-scope type has no layout yet" {
    const m: hir.Module = .{ .path = "t", .structs = &.{}, .enums = &.{}, .fns = &.{} };
    try std.testing.expect(layoutOf(&m, types.t_string) == null);
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
zig test src/cell/abi.zig > /private/tmp/abi.log 2>&1; echo "EXIT: $?"
```

Expected: FAIL, `use of undeclared identifier 'layoutOf'`.

- [ ] **Step 3: Write the minimal implementation**

Add above the tests in `src/cell/abi.zig`:

```zig
pub const Layout = struct {
    size: u32,
    alignment: u32,
};

/// Size and alignment of `ty` on this target, or null when this module does
/// not classify the type yet.
///
/// Null is not an error. It means the caller must refuse rather than guess,
/// which is the discipline both backends already follow.
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
        // Out of scope for this plan: String, [T], T?, Result, and anything
        // unresolved. Adding them means threading ownership through, because
        // `shared String` is a 16-byte cell_str_t and `owned String` is a
        // 24-byte cell_string_t.
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
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
zig test src/cell/abi.zig > /private/tmp/abi.log 2>&1; echo "EXIT: $?"; tail -3 /private/tmp/abi.log
```

Expected: EXIT 0, `All 3 tests passed.`

- [ ] **Step 5: Export the module so the package gate reaches it**

In `src/root.zig`, find the line `pub const hir = @import("cell/hir.zig");` and add immediately after it:

```zig
pub const abi = @import("cell/abi.zig");
```

- [ ] **Step 6: Run the package gate**

```bash
zig build -Dswift=false > /private/tmp/b.log 2>&1; echo "BUILD: $?"
zig build test -Dswift=false > /private/tmp/t.log 2>&1; echo "TEST: $?"
zig test src/root.zig 2>&1 | tail -1
```

Expected: BUILD 0, TEST 0, and a test count 3 higher than before this task.

- [ ] **Step 7: Commit**

```bash
git add src/cell/abi.zig src/root.zig
git commit -m "feat(abi): C layout rules for the types this backend classifies

Size and alignment for scalars, payload-free enums and user structs, with
C padding rules. String, [T], T?, Result and arc return null deliberately:
they need ownership threaded through, because shared String is a 16-byte
cell_str_t while owned String is a 24-byte cell_string_t.

Null means the caller refuses rather than guesses, which is the discipline
both new backends already follow."
```

---

### Task 2: HFA detection

**Files:**
- Modify: `src/cell/abi.zig`
- Test: in `src/cell/abi.zig`

**Interfaces:**
- Consumes: `layoutOf` from Task 1.
- Produces: `pub const Hfa = struct { count: u32, elem: []const u8 }` and `pub fn hfaOf(m: *const hir.Module, ty: hir.Ty) ?Hfa`. `elem` is the LLVM spelling, `"double"` or `"float"`.

- [ ] **Step 1: Write the failing test**

Append to `src/cell/abi.zig`:

```zig
/// Build a one-struct module for a test.
fn testModule(structs: []hir.Struct) hir.Module {
    return .{ .path = "t", .structs = structs, .enums = &.{}, .fns = &.{} };
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
    const m = testModule(&.{});
    try std.testing.expect(hfaOf(&m, types.t_float) == null);
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
zig test src/cell/abi.zig > /private/tmp/abi.log 2>&1; echo "EXIT: $?"
```

Expected: FAIL, `use of undeclared identifier 'hfaOf'`.

- [ ] **Step 3: Write the minimal implementation**

Add to `src/cell/abi.zig`, after `layoutOf`:

```zig
/// A homogeneous float aggregate: every leaf is the same float type and there
/// are at most four of them.
pub const Hfa = struct {
    count: u32,
    /// The LLVM spelling of the leaf type: "double" or "float".
    elem: []const u8,
};

/// AAPCS64's HFA rule, which is the part of this file most likely to be got
/// wrong, and the part the reference implementation explicitly punted on.
///
/// Two things make it unlike every other rule here:
///
///   1. It IGNORES the 16-byte cutoff. A 32-byte four-double aggregate still
///      goes in registers, as `[4 x double]`. Measured.
///   2. Leaves are counted through nesting. Two structs of two doubles is an
///      HFA of four, not of two.
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
/// so a large non-HFA struct costs no more than the first disagreeing field.
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
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
zig test src/cell/abi.zig > /private/tmp/abi.log 2>&1; echo "EXIT: $?"; tail -3 /private/tmp/abi.log
```

Expected: EXIT 0, `All 8 tests passed.`

- [ ] **Step 5: Commit**

```bash
git add src/cell/abi.zig
git commit -m "feat(abi): homogeneous float aggregate detection

The AAPCS64 rule most likely to be got wrong, and the one the reference
implementation's own abi.zig punted on and tagged a hazard. Two things make
it unlike every other rule here: it ignores the 16-byte cutoff, so a 32-byte
four-double aggregate still goes in registers; and leaves are counted through
nesting, so two structs of two doubles is an HFA of four rather than of two.
Both are pinned by tests."
```

---

### Task 3: Classification

**Files:**
- Modify: `src/cell/abi.zig`
- Test: in `src/cell/abi.zig`

**Interfaces:**
- Consumes: `layoutOf` (Task 1), `hfaOf` (Task 2).
- Produces:
  - `pub const Class = union(enum) { direct: []const u8, coerce_int: u32, coerce_float: struct { count: u32, elem: []const u8 }, indirect, unclassified }`
  - `pub fn classifyParam(m: *const hir.Module, ty: hir.Ty, own: hir.Ownership) Class`
  - `pub fn classifyReturn(m: *const hir.Module, ty: hir.Ty) Class`

`classifyReturn` takes no ownership because a return type in this language carries no ownership annotation the backend acts on; `hir.Fn.ret` is a bare `Ty`.

- [ ] **Step 1: Write the failing test**

Append to `src/cell/abi.zig`:

```zig
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
    const m = testModule(&.{});
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
    // `define %struct.Hfa2 @r_hfa2()`. The two positions genuinely disagree.
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
    try expectDirect(classifyReturn(&m, ty), "%cell_Point");
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
    const m = testModule(&.{});
    try std.testing.expect(classifyParam(&m, types.t_string, .shared) == .unclassified);
    try std.testing.expect(classifyReturn(&m, types.t_string) == .unclassified);
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
zig test src/cell/abi.zig > /private/tmp/abi.log 2>&1; echo "EXIT: $?"
```

Expected: FAIL, `use of undeclared identifier 'classifyParam'`.

- [ ] **Step 3: Write the minimal implementation**

Add to `src/cell/abi.zig`:

```zig
pub const Class = union(enum) {
    /// Passed and returned as this exact LLVM type: "i64", "double", "i1",
    /// "ptr", or a named struct like "%cell_Point".
    direct: []const u8,
    /// Coerced to [n x i64].
    coerce_int: u32,
    /// Coerced to [count x elem]. HFA parameters only.
    coerce_float: struct { count: u32, elem: []const u8 },
    /// Parameter: a plain `ptr`. Return: the function returns void and takes
    /// an `sret` pointer as a prepended first parameter.
    indirect,
    /// Not classified by this module. The caller emits `cannot lower` and
    /// refuses the module. Never guess: a refusal is a fact about the
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

pub fn classifyParam(m: *const hir.Module, ty: hir.Ty, own: hir.Ownership) Class {
    // Primitives pass by value in EVERY ownership mode. cell_rt.h section 1
    // fixes this, and the language depends on it.
    if (scalarSpelling(ty)) |s| return .{ .direct = s };

    const layout = layoutOf(m, ty) orelse return .unclassified;

    // A borrow of an aggregate is a pointer, matching codegen.applyOwnership.
    switch (own) {
        .shared, .exclusive => return .{ .direct = "ptr" },
        .owned, .copy, .arc => {},
    }

    // The HFA rule is checked BEFORE the size cutoff, because it ignores it.
    if (hfaOf(m, ty)) |h| return .{ .coerce_float = .{ .count = h.count, .elem = h.elem } };

    if (layout.size > 16) return .indirect;
    return .{ .coerce_int = wordsFor(layout.size) };
}

pub fn classifyReturn(m: *const hir.Module, ty: hir.Ty) Class {
    if (scalarSpelling(ty)) |s| return .{ .direct = s };

    const layout = layoutOf(m, ty) orelse return .unclassified;

    // Measured asymmetry: an HFA parameter coerces to [n x double], but an
    // HFA RETURN is the struct itself. This is the case a single classify()
    // with a flag would get wrong at one call site and not the others.
    if (hfaOf(m, ty) != null) {
        const name = switch (ty) {
            .struct_type => |n| n,
            else => return .unclassified,
        };
        return .{ .direct = structSpelling(name) };
    }

    if (layout.size > 16) return .indirect;
    return .{ .coerce_int = wordsFor(layout.size) };
}

/// Size in 8-byte words, rounded up. A 4-byte aggregate is one word.
fn wordsFor(size: u32) u32 {
    if (size == 0) return 0;
    return (size + 7) / 8;
}

/// The LLVM type name a struct is emitted under. Both backends use the same
/// `%cell_<Name>` convention, so it lives here rather than in either of them.
///
/// Returns a slice into a small fixed buffer is NOT acceptable here because
/// the result outlives the call, so this uses a comptime-safe approach: the
/// caller passes the name and formats it. See usage in llvmemit.
fn structSpelling(name: []const u8) []const u8 {
    // The `%cell_` prefix is added by the caller, which owns an allocator.
    // Returning the bare name keeps this module allocation free, which is what
    // makes it a leaf.
    return name;
}
```

**Note on `structSpelling`:** returning the bare name keeps `abi.zig` allocation free. `classifyReturn` therefore returns `.direct` with the struct's NAME, and the caller prefixes `%cell_`. Adjust the Task 3 test accordingly: change `try expectDirect(classifyReturn(&m, ty), "%cell_Point");` to `try expectDirect(classifyReturn(&m, ty), "Point");` and add a comment saying the caller adds the prefix.

- [ ] **Step 4: Run the test to verify it passes**

```bash
zig test src/cell/abi.zig > /private/tmp/abi.log 2>&1; echo "EXIT: $?"; tail -3 /private/tmp/abi.log
```

Expected: EXIT 0, `All 13 tests passed.`

- [ ] **Step 5: Commit**

```bash
git add src/cell/abi.zig
git commit -m "feat(abi): AAPCS64 parameter and return classification

Two entry points rather than one with a flag, because the positions genuinely
disagree: an HFA parameter coerces to [n x double] while an HFA return is the
struct itself. A single classify() would force every caller to remember that,
which is how it gets forgotten at one call site and not the others.

Ownership is a parameter because it changes the answer. codegen.applyOwnership
makes a borrowed aggregate a pointer while an owned one passes by value, and
primitives are exempt in every mode per cell_rt.h section 1."
```

---

### Task 4: Prove the classifier against clang

**Files:**
- Modify: `src/cell/abi.zig`
- Test: in `src/cell/abi.zig`

**Interfaces:**
- Consumes: `classifyParam`, `classifyReturn` (Task 3).
- Produces: nothing new. This task adds only the test that makes the module trustworthy.

This is the load-bearing test of the whole plan. A hand-written ABI that nothing checks rots silently, and the rot surfaces as a wrong answer in a linked program rather than as a build failure.

- [ ] **Step 1: Write the failing test**

Append to `src/cell/abi.zig`:

```zig
/// One shape to check against clang: the C declaration, and what this module
/// predicts for it.
const ProbeCase = struct {
    /// A C struct definition, or "" for a scalar.
    c_decl: []const u8,
    /// The C type name used in the probe functions.
    c_type: []const u8,
    /// The `define` fragment clang must produce for the parameter function.
    want_param: []const u8,
    /// The `define` fragment clang must produce for the return function.
    want_return: []const u8,
};

test "the classifier predicts what clang actually does" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Skip rather than pass vacuously when the toolchain is absent, following
    // the precedent set by the MLIR execution test in mlirmit.zig.
    const probe = std.process.run(gpa, io, .{ .argv = &.{ "cc", "--version" } }) catch
        return error.SkipZigTest;
    gpa.free(probe.stdout);
    gpa.free(probe.stderr);
    if (!probe.term.success()) return error.SkipZigTest;

    const cases = [_]ProbeCase{
        .{
            .c_decl = "typedef struct { double x, y; } T;",
            .c_type = "T",
            .want_param = "[2 x double]",
            .want_return = "%struct.",
        },
        .{
            .c_decl = "typedef struct { double x, y, z, w; } T;",
            .c_type = "T",
            .want_param = "[4 x double]",
            .want_return = "%struct.",
        },
        .{
            .c_decl = "typedef struct { long long a, b; } T;",
            .c_type = "T",
            .want_param = "[2 x i64]",
            .want_return = "[2 x i64]",
        },
        .{
            .c_decl = "typedef struct { long long a, b, c; } T;",
            .c_type = "T",
            .want_param = "ptr",
            .want_return = "sret",
        },
        .{
            .c_decl = "typedef struct { long long a; double b; } T;",
            .c_type = "T",
            .want_param = "[2 x i64]",
            .want_return = "[2 x i64]",
        },
        .{
            .c_decl = "typedef struct { char c; long long a; } T;",
            .c_type = "T",
            .want_param = "[2 x i64]",
            .want_return = "[2 x i64]",
        },
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    for (cases, 0..) |case, i| {
        const src = try std.fmt.allocPrint(gpa,
            \\{s}
            \\long long p_in(T v);
            \\long long p_in(T v) {{ (void)v; return 0; }}
            \\T r_out(void);
            \\T r_out(void) {{ T t; __builtin_memset(&t, 0, sizeof t); return t; }}
        , .{case.c_decl});
        defer gpa.free(src);

        const name = try std.fmt.allocPrint(gpa, "probe{d}.c", .{i});
        defer gpa.free(name);
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = src });

        const run = try std.process.run(gpa, io, .{
            .argv = &.{ "cc", "-S", "-emit-llvm", "-O0", name, "-o", "-" },
            .cwd = .{ .dir = tmp.dir },
        });
        defer gpa.free(run.stdout);
        defer gpa.free(run.stderr);
        if (!run.term.success()) {
            std.debug.print("cc failed on probe {d}:\n{s}\n", .{ i, run.stderr });
            return error.ProbeFailed;
        }

        if (std.mem.indexOf(u8, run.stdout, case.want_param) == null) {
            std.debug.print(
                "probe {d}: expected parameter form '{s}' in clang output:\n{s}\n",
                .{ i, case.want_param, run.stdout },
            );
            return error.ParamFormChanged;
        }
        if (std.mem.indexOf(u8, run.stdout, case.want_return) == null) {
            std.debug.print(
                "probe {d}: expected return form '{s}' in clang output:\n{s}\n",
                .{ i, case.want_return, run.stdout },
            );
            return error.ReturnFormChanged;
        }
    }
}
```

- [ ] **Step 2: Run the test to verify it exercises clang**

```bash
zig test src/cell/abi.zig > /private/tmp/abi.log 2>&1; echo "EXIT: $?"; tail -5 /private/tmp/abi.log
```

Expected: EXIT 0. If a case fails, clang's ABI on this host disagrees with the spec's measurement table, which is exactly what this test exists to detect. Do not edit the expectation to match; re-measure and update the spec's table, saying so in the commit.

- [ ] **Step 3: Verify the test actually runs rather than skipping**

```bash
zig test src/cell/abi.zig 2>&1 | grep -c 'SKIP' || echo "no skips: good"
```

Expected: `no skips: good` on a machine with `cc`. A test that silently skips is worth nothing, so confirm it ran.

- [ ] **Step 4: Verify the test can fail**

Temporarily change the first case's `want_param` from `"[2 x double]"` to `"[2 x i64]"`, re-run, and confirm it FAILS with `ParamFormChanged`. Then change it back and re-run to confirm it passes again. A test that cannot fail is not a test.

```bash
zig test src/cell/abi.zig > /private/tmp/abi.log 2>&1; echo "EXIT: $? (want non-zero while sabotaged)"
```

- [ ] **Step 5: Commit**

```bash
git add src/cell/abi.zig
git commit -m "test(abi): pin the classifier against what clang actually does

For each shape, write a C probe, run cc -S -emit-llvm, and assert the form
clang emits. A live comparison against the compiler that owns the ABI, not a
golden file: a golden file records what clang did once, this records what
clang does now.

Skips when cc is absent rather than passing vacuously, following the MLIR
execution test's precedent. Verified it can fail by sabotaging one
expectation before committing.

If a case ever fails, clang's ABI on this host disagrees with the spec's
measurement table. Re-measure and update the table; do not edit the
expectation to match, which is how a real regression gets absorbed."
```

---

### Task 5: The LLVM backend adopts the classifier

**Files:**
- Modify: `src/cell/llvmemit.zig` (`emitDeclare` at `:185`, `emitFn` at `:205`)
- Test: in `src/cell/llvmemit.zig`

**Interfaces:**
- Consumes: `classifyParam`, `classifyReturn` (Task 3).
- Produces: no new public API. Behavior change: struct parameters and returns now use the AAPCS64 form.

This is the spec's step 0, the latent-bug fix. `llvmemit` currently passes `%cell_Point` directly where AAPCS64 says `[2 x double]`. It is masked because struct passing is Cell-to-Cell within one emitted module, so both sides are consistently wrong together.

**The three existing assertions in the `%cell_Point` test at `src/cell/llvmemit.zig:956` do NOT change.** They cover the type definition, the `alloca` and the `insertvalue`, none of which this task touches, and that test's `main()` takes no parameters. Verified before writing this plan. If any of them does change, stop and investigate rather than editing the assertion.

- [ ] **Step 1: Write the failing test**

Append to the test section of `src/cell/llvmemit.zig`:

```zig
test "an HFA struct parameter uses the AAPCS64 coerced form" {
    // Measured with clang: a {double, double} parameter is [2 x double], not
    // the struct type. Passing it directly is invisible while both sides of
    // the call are Cell, and wrong the moment it crosses to C.
    var e = try emitSource(
        \\pub struct Point { copy x: Float, copy y: Float }
        \\pub fn length2(copy p: Point) -> Float { return p.x }
    );
    defer e.deinit();
    try expectContains(e.text, "define double @cell_length2([2 x double]");
}

test "a borrowed struct parameter is a pointer" {
    var e = try emitSource(
        \\pub struct Buffer { copy len: Int }
        \\pub fn read(shared b: Buffer) -> Int { return b.len }
    );
    defer e.deinit();
    try expectContains(e.text, "define i64 @cell_read(ptr");
}

test "a non-HFA struct over 16 bytes is passed indirectly" {
    var e = try emitSource(
        \\pub struct Big { copy a: Int, copy b: Int, copy c: Int }
        \\pub fn first(copy v: Big) -> Int { return v.a }
    );
    defer e.deinit();
    try expectContains(e.text, "define i64 @cell_first(ptr");
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
zig test src/cell/llvmemit.zig > /private/tmp/ll.log 2>&1; echo "EXIT: $?"; grep -A3 'expected' /private/tmp/ll.log | head -20
```

Expected: FAIL. The first test finds `define double @cell_length2(%cell_Point` instead of `[2 x double]`, which is the bug this task fixes.

- [ ] **Step 3: Write the implementation**

In `src/cell/llvmemit.zig`, add the import at the top beside the existing ones:

```zig
const abi = @import("abi.zig");
```

Add this helper to the `Emitter` struct, next to `llType`:

```zig
/// The LLVM type a parameter of `(ty, own)` is written as, or null when this
/// backend cannot place it. Ownership matters: a borrowed aggregate is a
/// pointer while an owned one passes by value.
fn paramType(self: *Emitter, ty: hir.Ty, own: hir.Ownership) ?[]const u8 {
    return switch (abi.classifyParam(self.module, ty, own)) {
        .direct => |s| s,
        .coerce_int => |n| std.fmt.allocPrint(self.arena, "[{d} x i64]", .{n}) catch null,
        .coerce_float => |f| std.fmt.allocPrint(
            self.arena,
            "[{d} x {s}]",
            .{ f.count, f.elem },
        ) catch null,
        // An indirect parameter is a pointer to a caller-owned copy.
        .indirect => "ptr",
        .unclassified => null,
    };
}

/// The LLVM type a return of `ty` is written as, or null when this backend
/// cannot place it. `.indirect` returns "void" here; the sret parameter is
/// added by the caller, which is why this is not just paramType.
fn returnType(self: *Emitter, ty: hir.Ty) ?[]const u8 {
    return switch (abi.classifyReturn(self.module, ty)) {
        .direct => |s| blk: {
            // classifyReturn hands back a bare struct NAME for an HFA return,
            // because abi.zig is allocation free. The prefix is ours.
            if (ty.tag() == .struct_type) {
                break :blk std.fmt.allocPrint(self.arena, "%cell_{s}", .{s}) catch null;
            }
            break :blk s;
        },
        .coerce_int => |n| std.fmt.allocPrint(self.arena, "[{d} x i64]", .{n}) catch null,
        .coerce_float => |f| std.fmt.allocPrint(
            self.arena,
            "[{d} x {s}]",
            .{ f.count, f.elem },
        ) catch null,
        .indirect => "void",
        .unclassified => null,
    };
}
```

In `emitDeclare` (currently line 185) and `emitFn` (currently line 205), replace each `self.llType(p.ty)` used for a PARAMETER with `self.paramType(p.ty, p.ownership)`, and each `self.llType(f.ret)` used for a RETURN with `self.returnType(f.ret)`.

Leave every other `llType` call alone. Locals, loads and stores use the in-memory type, which is the struct itself, not its coerced parameter form.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
zig test src/cell/llvmemit.zig > /private/tmp/ll.log 2>&1; echo "EXIT: $?"; tail -3 /private/tmp/ll.log
```

Expected: EXIT 0. If the pre-existing `%cell_Point` test now fails, STOP and investigate; this plan predicted it would not.

- [ ] **Step 5: Verify a struct actually crosses to C correctly**

This is the test whose absence let the defect ship. Append to `src/cell/llvmemit.zig`:

```zig
test "a struct passed to a C function arrives with the right values" {
    // The regression test for the whole task. A wrong calling convention is
    // invisible Cell-to-Cell and only shows up here, at a real C boundary.
    var e = try emitSource(
        \\pub struct Point { copy x: Float, copy y: Float }
        \\pub fn print_int(copy value: Int);
        \\pub fn sum(copy p: Point) -> Int { return 0 }
        \\pub fn main() {
        \\  let owned p = Point { x: 1.0, y: 2.0 }
        \\  print_int(sum(copy p))
        \\}
    );
    defer e.deinit();
    try std.testing.expect(!e.bag.hasErrors());
    const out = try runEmitted(e.text);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("0\n", out);
}
```

```bash
zig test src/cell/llvmemit.zig > /private/tmp/ll.log 2>&1; echo "EXIT: $?"
```

Expected: EXIT 0.

- [ ] **Step 6: Run the full gate**

```bash
zig build -Dswift=false > /private/tmp/b.log 2>&1; echo "BUILD: $?"
zig build test -Dswift=false > /private/tmp/t.log 2>&1; echo "TEST: $?"
zig test src/root.zig 2>&1 | tail -1
for f in examples/*.cell; do ./zig-out/bin/cell check "$f" >/dev/null 2>&1 || echo "FAIL $f"; done
for f in examples/rejected/*.cell; do want=$(grep -m1 '^// EXPECT:' "$f" | sed 's|^// EXPECT: ||'); if ./zig-out/bin/cell check "$f" >/dev/null 2>&1; then got=currently-accepted; else got=currently-rejected; fi; [ "$want" = "$got" ] || echo "MISMATCH $f"; done
for f in examples/future/*.cell; do ./zig-out/bin/cell check "$f" >/dev/null 2>&1 && echo "PARSER GREW $f"; done
```

Expected: BUILD 0, TEST 0, no FAIL/MISMATCH/PARSER GREW lines.

- [ ] **Step 7: Verify all three backends still agree**

```bash
S=/private/tmp/gate; mkdir -p $S; L=/opt/homebrew/opt/llvm/bin
cc -c -I runtime runtime/cell_rt.c -o $S/rt.o
printf 'extern void cell_main(void);\nint main(void){cell_main();return 0;}\n' > $S/drv.c
./zig-out/bin/cell emit examples/backends.cell > $S/b.c 2>/dev/null
cc -I runtime $S/b.c runtime/cell_rt.c -o $S/bc && printf 'C    : ' && $S/bc
./zig-out/bin/cell emit --target=llvm examples/backends.cell > $S/b.ll 2>/dev/null
cc -Wno-override-module -x ir $S/b.ll -c -o $S/b.o 2>/dev/null
cc $S/b.o $S/rt.o -o $S/bl && printf 'LLVM : ' && $S/bl
./zig-out/bin/cell emit --target=mlir examples/backends.cell > $S/b.mlir 2>/dev/null
$L/mlir-opt $S/b.mlir --expand-strided-metadata --finalize-memref-to-llvm --convert-cf-to-llvm --convert-func-to-llvm --convert-arith-to-llvm --reconcile-unrealized-casts -o $S/bl.mlir
$L/mlir-translate --mlir-to-llvmir $S/bl.mlir -o $S/bm.ll
$L/llc -filetype=obj $S/bm.ll -o $S/bm.o
cc $S/bm.o $S/drv.c $S/rt.o -o $S/bm_prog && printf 'MLIR : ' && $S/bm_prog
```

Expected: `C : 24`, `LLVM : 24`, `MLIR : 24`.

- [ ] **Step 8: Commit**

```bash
git add src/cell/llvmemit.zig
git commit -m "fix(llvm): pass structs by the convention C actually uses

The backend emitted %cell_Point as a parameter where AAPCS64 says
[2 x double]. It was invisible because struct passing is Cell-to-Cell inside
one emitted module, so both sides were consistently wrong together, and
examples/hello.cell declares exactly such a struct.

Parameters and returns now go through abi.zig. Locals, loads and stores keep
using the in-memory struct type, which is unchanged: only the calling
convention was wrong.

The regression test is the one whose absence let this ship: a struct passed
across a real C boundary, linked against the runtime and run. Cell-to-Cell
tests cannot catch a wrong convention, because both halves share it."
```

---

## Self-Review

**Spec coverage.** Spec step 0 (fix `%cell_Point`) is Task 5. Step 1 (`abi.zig` plus the clang-comparison test) is Tasks 1 through 4. Spec steps 2 and 3, LLVM aggregate adoption and MLIR structs, are deliberately out of this plan and named in Scope; they need ownership threaded into `layoutOf`, which this plan's `null` return makes a compile-time-obvious gap rather than a silent one.

The spec's two "not probed" rows, mixed and padded 16-byte structs as returns, are covered by Task 4's cases 5 and 6, which assert both positions.

**Correction carried:** the spec's `classifyParam(m, ty)` signature is insufficient. The plan uses `(m, ty, own)` and states why at the top. The spec should be amended to match; that is a doc edit, not a code change, and it belongs in Task 3's commit.

**Placeholder scan:** no TBDs, no "add error handling", every code step carries real code.

**Type consistency:** `Class.coerce_float` uses field name `count` in both the definition and every use. `hfaOf` returns `Hfa{count, elem}`, and `classifyParam` maps it to `coerce_float{count, elem}`. `layoutOf` returns `?Layout` and every caller handles null. `classifyReturn` returns a bare struct name and `llvmemit.returnType` adds the `%cell_` prefix, stated in both places.

**Known wrinkle, deliberately left:** `structSpelling` is a one-line identity function. It exists to document why the name is returned bare rather than prefixed. If a reviewer finds that unhelpful, inline it and keep the comment.
