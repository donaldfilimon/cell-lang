//! Checker lifecycle, scopes and declarations, and the liveness queries codegen
//! reads (`wasMoved`, `liveAtExit`, ...).
//! Part of the borrow checker; the rules and their rationale are in the module header of `../borrowck.zig`.

const std = @import("std");
const ast = @import("../ast.zig");
const Span = ast.Span;
const bk_model = @import("model.zig");
const bk_root = @import("../borrowck.zig");
const Checker = bk_root.Checker;
const Error = bk_model.Error;
const Binding = bk_model.Binding;
const ExitKind = bk_model.ExitKind;
const typeIsBorrow = bk_model.typeIsBorrow;
const pathPrefix = bk_model.pathPrefix;
const typeStructName = bk_model.typeStructName;

pub const ScopeMark = struct {
    bindings: usize,
    block_loans: usize,
};

pub fn init(
    allocator: std.mem.Allocator,
    path: []const u8,
    source: ?[]const u8,
) Checker {
    return .{
        .allocator = allocator,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .diagnostics = .init(path, source),
    };
}

pub fn deinit(self: *Checker) void {
    self.fns.deinit(self.allocator);
    self.structs.deinit(self.allocator);
    self.enums.deinit(self.allocator);
    self.bindings.deinit(self.allocator);
    self.scopes.deinit(self.allocator);
    self.dead.deinit(self.allocator);
    self.moved.deinit(self.allocator);
    self.moved_paths.deinit(self.allocator);
    self.assign_liveness.deinit(self.allocator);
    self.field_assign_liveness.deinit(self.allocator);
    self.exit_liveness.deinit(self.allocator);
    self.skip_breaks.deinit(self.allocator);
    self.wrap_moves.deinit(self.allocator);
    self.exit_field_liveness.deinit(self.allocator);
    self.loop_moved.deinit(self.allocator);
    self.names.deinit(self.allocator);
    self.block_loans.deinit(self.allocator);
    self.temp_loans.deinit(self.allocator);
    self.open_blocks.deinit(self.allocator);
    for (self.loop_frames.items) |*frame| frame.deinit(self.allocator);
    self.loop_frames.deinit(self.allocator);
    self.diagnostics.deinit(self.allocator);
    self.arena.deinit();
}

pub fn hasErrors(self: *const Checker) bool {
    return self.diagnostics.hasErrors();
}

pub fn msg(self: *Checker, comptime fmt: []const u8, args: anytype) Error![]const u8 {
    return try std.fmt.allocPrint(self.arena.allocator(), fmt, args);
}

// ── module walk ─────────────────────────────────────────────────────

/// Check every function body in `module`, filling `diagnostics`.
pub fn checkModule(self: *Checker, module: *const ast.Module) Error!void {
    self.diagnostics.path = module.path;
    // Signatures first: a call may precede its callee's definition, and
    // R15 and R1 both need the parameter annotations.
    for (module.items) |*item| {
        switch (item.kind) {
            .fn_def => |f| try self.fns.put(self.allocator, f.name, f),
            .struct_def => |s| try self.structs.put(self.allocator, s.name, s),
            .enum_def => |en| try self.enums.put(self.allocator, en.name, en),
            else => {},
        }
    }
    for (module.items) |*item| {
        switch (item.kind) {
            .fn_def => |*f| try self.checkFn(item.span, f),
            .struct_def => |s| try self.checkStructFields(item.span, s),
            else => {},
        }
    }
}

pub fn checkFn(self: *Checker, span: Span, f: *const ast.FnDef) Error!void {
    self.fn_return_borrow = null;
    self.fn_return_owned = null;
    self.fn_return_arc = null;
    self.current_fn = f;
    defer self.current_fn = null;
    if (f.return_type) |*rt| {
        const returns_arc = switch (rt.*) {
            .ref => |r| r.ownership == .arc,
            .name, .optional, .list, .result, .unit => false,
        };
        if (!returns_arc) self.fn_return_owned = f.name;
        if (returns_arc) self.fn_return_arc = f.name;
        if (typeIsBorrow(rt)) |kind| {
            self.fn_return_borrow = kind;
            // A bodyless `-> shared T` has no return expression to point
            // at, so the function item is the use site. A body reports at
            // each `return` instead (see checkStmt).
            if (f.body == null) try self.reportEscapingReturn(span, kind);
        }
    }
    // R12 at the parameter position, asked BEFORE the bodyless return so a
    // declared-only `fn f(copy b: Box);` is refused too: its caller is what
    // duplicates the header, and that call site exists whether or not this
    // module carries the body.
    for (f.params) |p| {
        if (p.ownership == .copy) {
            try self.refuseResourceCopy(span, "parameter", p.name, p.ty);
        }
    }

    const body = f.body orelse return;

    // A fresh scope per function. This is what keeps a parameter of one
    // function from leaking into the next (OWNERSHIP.md 0.4), without
    // depending on typecheck.zig's symbol table.
    try self.pushScope();
    defer self.popScope();
    // Each function starts from a clean move and loan state.
    self.dead.clearRetainingCapacity();

    for (f.params) |p| {
        _ = try self.declare(.{
            .id = 0,
            .name = p.name,
            .ownership = p.ownership,
            // R14 defect 3: a parameter is writable exactly when it owns
            // its value or holds an exclusive borrow. `arc` is immutable
            // by R9, `shared` by definition, `copy` because a duplicate
            // parameter is not a `var`.
            .mutable = p.ownership == .owned or p.ownership == .exclusive,
            .struct_name = typeStructName(&p.ty),
            .ty = p.ty,
            .decl_span = .none,
        });
    }
    try self.checkBlockStmts(body);
}

// ── scopes ──────────────────────────────────────────────────────────

pub fn pushScope(self: *Checker) Error!void {
    try self.scopes.append(self.allocator, .{
        .bindings = self.bindings.items.len,
        .block_loans = self.block_loans.items.len,
    });
}

pub fn popScope(self: *Checker) void {
    const mark = self.scopes.pop() orelse return;
    self.bindings.shrinkRetainingCapacity(mark.bindings);
    // R0.3: a named loan ends with the block that created it.
    self.block_loans.shrinkRetainingCapacity(mark.block_loans);
}

pub fn declare(self: *Checker, proto: Binding) Error!u32 {
    var b = proto;
    b.id = self.next_binding_id;
    self.next_binding_id += 1;
    try self.bindings.append(self.allocator, b);
    try self.names.put(self.allocator, b.id, b.name);
    return b.id;
}

/// The innermost visible binding named `name`, so shadowing works.
pub fn lookup(self: *const Checker, name: []const u8) ?*const Binding {
    var i = self.bindings.items.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, self.bindings.items[i].name, name)) {
            return &self.bindings.items[i];
        }
    }
    return null;
}

pub fn bindingById(self: *const Checker, id: u32) ?*const Binding {
    for (self.bindings.items) |*b| {
        if (b.id == id) return b;
    }
    return null;
}

/// Whether `binding` was moved anywhere in the function that declared
/// it. Conservative in the same direction `dead` already is: a move on
/// only one branch of an `if` answers true for the whole rest of the
/// function (see the doc comment on `moved`), so this is "maybe
/// moved", never "definitely moved right here". A caller deciding
/// whether to destroy a place MUST treat "maybe" as "yes": not
/// destroying a place that is actually still live only leaks it: task
/// 3's whole design rests on that asymmetry, spelled out in
/// codegen.zig's module doc comment.
///
/// This reads `moved`, not `bindings`, so it still answers correctly
/// after the binding's own scope has popped and after the whole module
/// has finished checking -- exactly the state codegen queries it in
/// (see codegen.zig's module doc comment: it runs `checkModule` once,
/// up front, then emits).
pub fn wasMoved(self: *const Checker, binding: u32) bool {
    return self.moved.contains(binding);
}

/// True only when EVERY check of the whole-binding assignment whose
/// target name starts at `name_ptr` found the target holding a live
/// value that no path through an enclosing loop could have moved. False
/// for an unknown site, so a store the checker did not vouch for keeps
/// the leak. See `assign_liveness`.
pub fn assignReleasesOldValue(self: *const Checker, name_ptr: [*]const u8) bool {
    const key = @intFromPtr(name_ptr);
    var found = false;
    for (self.assign_liveness.items) |entry| {
        if (entry.key != key) continue;
        if (!entry.live) return false;
        found = true;
    }
    return found;
}

/// The field-store twin of `assignReleasesOldValue`: true only when every
/// check of the field store whose ROOT identifier starts at `name_ptr`
/// found the whole target path live, with enclosing loops accounted for.
/// False for an unknown site. See `field_assign_liveness`.
pub fn fieldAssignReleasesOldValue(self: *const Checker, name_ptr: [*]const u8) bool {
    const key = @intFromPtr(name_ptr);
    var found = false;
    for (self.field_assign_liveness.items) |entry| {
        if (entry.key != key) continue;
        if (!entry.live) return false;
        found = true;
    }
    return found;
}

/// A record binding is released whole at an exit when it holds a value
/// there (revived after any move) and no field path of it is dead on
/// this path. Same records as `liveAtExit`; `recordExit` already folds
/// any dead field path into `live = false`.
pub fn recordLiveAtExit(self: *const Checker, kind: ExitKind, key: usize, binding: u32) bool {
    return self.liveAtExit(kind, key, binding);
}

/// True only when EVERY record for `binding` at the exit (`kind`, `key`)
/// found it holding a value that no loop could have moved. False for an
/// exit the checker did not record, so a drop point it did not vouch for
/// keeps the leak. See `exit_liveness`.
/// True when the `Ok(x)` whose operand is at this address moved it.
pub fn wrapMoved(self: *const Checker, wrap_key: usize) bool {
    return std.mem.indexOfScalar(usize, self.wrap_moves.items, wrap_key) != null;
}

/// The `while` whose `after_loop_skip` releases this `break` must jump
/// past, or null for an ordinary `break`.
pub fn skipBreakLoop(self: *const Checker, break_key: usize) ?usize {
    for (self.skip_breaks.items) |sb| {
        if (sb.break_key == break_key) return sb.loop_key;
    }
    return null;
}

/// True when some `break` of this `while` jumps past its releases, so
/// codegen places a label after them.
pub fn loopHasSkipBreaks(self: *const Checker, loop_key: usize) bool {
    for (self.skip_breaks.items) |sb| {
        if (sb.loop_key == loop_key) return true;
    }
    return false;
}

pub fn liveAtExit(self: *const Checker, kind: ExitKind, key: usize, binding: u32) bool {
    var found = false;
    for (self.exit_liveness.items) |entry| {
        if (entry.kind != kind or entry.key != key or entry.binding != binding) continue;
        if (!entry.live) return false;
        found = true;
    }
    return found;
}

/// True only when EVERY record for this field path at the exit found it
/// holding a value. False for a missing record, so a drop point the
/// checker did not vouch for keeps the leak. Exact path: `"a"` is not
/// `"inner.a"`. See `exit_field_liveness`.
pub fn fieldLiveAtExit(
    self: *const Checker,
    kind: ExitKind,
    key: usize,
    binding: u32,
    path: []const u8,
) bool {
    var found = false;
    for (self.exit_field_liveness.items) |entry| {
        if (entry.kind != kind or entry.key != key or entry.binding != binding) continue;
        if (!std.mem.eql(u8, entry.path, path)) continue;
        if (!entry.live) return false;
        found = true;
    }
    return found;
}

/// True only when EVERY record for this field path at the exit found it
/// dead. False for a missing record (the other half of the leak). The
/// branch-end rule needs both: live here AND dead after the merge.
pub fn fieldDeadAtExit(
    self: *const Checker,
    kind: ExitKind,
    key: usize,
    binding: u32,
    path: []const u8,
) bool {
    var found = false;
    for (self.exit_field_liveness.items) |entry| {
        if (entry.kind != kind or entry.key != key or entry.binding != binding) continue;
        if (!std.mem.eql(u8, entry.path, path)) continue;
        if (entry.live) return false;
        found = true;
    }
    return found;
}

/// Record every visible binding's liveness at one scope exit.
pub fn recordExit(self: *Checker, kind: ExitKind, key: usize) Error!void {
    for (self.bindings.items) |b| {
        var live = !self.loop_moved.contains(b.id);
        if (live) {
            for (self.dead.items) |d| {
                if (d.binding == b.id) {
                    live = false;
                    break;
                }
            }
        }
        try self.exit_liveness.append(self.allocator, .{
            .kind = kind,
            .key = key,
            .binding = b.id,
            .live = live,
        });
        // Per-field sibling: every path `moved_paths` recorded under
        // this binding, including paths moved on a different branch.
        // Iterating `dead` alone would omit the keeping path (nothing
        // dead there) and the else-path drop would miss its record.
        // `live` is filled from THIS path's `dead` (pre-merge at a
        // `branch_end`). Overlap matches `findDead`: a whole-binding
        // dead or a descendant still marks the field dead.
        for (self.moved_paths.items) |m| {
            if (m.binding != b.id or m.path.len == 0) continue;
            var field_live = !self.loop_moved.contains(b.id);
            if (field_live) {
                for (self.dead.items) |d| {
                    if (d.binding != b.id) continue;
                    if (pathPrefix(d.path, m.path) or pathPrefix(m.path, d.path)) {
                        field_live = false;
                        break;
                    }
                }
            }
            try self.exit_field_liveness.append(self.allocator, .{
                .kind = kind,
                .key = key,
                .binding = b.id,
                .path = m.path,
                .live = field_live,
            });
        }
    }
}

/// True when the binding ITSELF was moved (path `""`), as opposed to
/// only some of its fields. A wholly moved record is gone and codegen
/// releases none of it; a record with only fields moved out is still
/// partly live, and its remaining owning fields still need releasing.
pub fn wasWhollyMoved(self: *const Checker, binding: u32) bool {
    for (self.moved_paths.items) |m| {
        if (m.binding == binding and m.path.len == 0) return true;
    }
    return false;
}

/// True when `path` itself was moved (exact match: `"inner"`, not
/// `"inner.a"`). Codegen skips that field whole. A whole-binding move
/// is deliberately NOT reported here: callers check `wasWhollyMoved`
/// first.
pub fn fieldWasMovedWhole(self: *const Checker, binding: u32, path: []const u8) bool {
    for (self.moved_paths.items) |m| {
        if (m.binding != binding or m.path.len == 0) continue;
        if (m.revived and !self.loop_moved.contains(binding)) continue;
        if (std.mem.eql(u8, m.path, path)) return true;
    }
    return false;
}

/// True when `path` of `binding` was moved, in whole (`path`) or in
/// part (`path.x`). The fail-closed skip: codegen releases a field
/// only when this is false, so an unrecognised descendant still leaks
/// rather than being freed while something else may own a piece of it.
/// A whole-binding move is deliberately NOT reported here: callers
/// check `wasWhollyMoved` first. `path` is a dotted field path, so
/// `"inner"` and `"inner.a"` are both valid. A path R3a revived is
/// skipped unless the binding is `loop_moved`: a skip-revival
/// `continue` can leave an outer field taken, and releasing it at
/// function end is a double free.
pub fn fieldWasMoved(self: *const Checker, binding: u32, field: []const u8) bool {
    for (self.moved_paths.items) |m| {
        if (m.binding != binding or m.path.len == 0) continue;
        if (m.revived and !self.loop_moved.contains(binding)) continue;
        if (std.mem.eql(u8, m.path, field)) return true;
        if (m.path.len > field.len and std.mem.startsWith(u8, m.path, field) and m.path[field.len] == '.') return true;
    }
    return false;
}

/// The name `binding` was declared under. See the doc comment on
/// `names` for why this exists: a numbering cross-check, not a feature
/// borrowck itself needs.
pub fn bindingName(self: *const Checker, binding: u32) ?[]const u8 {
    return self.names.get(binding);
}
