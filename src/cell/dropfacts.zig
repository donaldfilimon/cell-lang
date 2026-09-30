//! Narrow, read-only ownership facts for HIR cleanup insertion.
//! The borrow checker implements this interface; HIR does not import the
//! checker or infer whether an absent fact is safe. Missing evidence means
//! no drop, which can leak but cannot introduce a double free.

pub const ExitKind = @import("borrowck/model.zig").ExitKind;

pub const DropFacts = struct {
    context: *const anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        next_binding_id: *const fn (*const anyopaque) u32,
        binding_name: *const fn (*const anyopaque, u32) ?[]const u8,
        was_moved: *const fn (*const anyopaque, u32) bool,
        live_at_exit: *const fn (*const anyopaque, ExitKind, usize, u32) bool,
        assign_releases_old_value: *const fn (*const anyopaque, [*]const u8) bool,
        /// True when this `break` must jump past the loop's `after_loop_skip`
        /// release. False for an ordinary break, and when the checker has no
        /// record: a missing fact keeps the break on the release path.
        skip_break: *const fn (*const anyopaque, usize) bool,
        /// True when this field path holds a value at the exit. A missing
        /// record is false, so the drop is omitted. Exact path: `"a"` is not
        /// `"inner.a"`.
        field_live_at_exit: *const fn (*const anyopaque, ExitKind, usize, u32, []const u8) bool,
        /// True when every record of this field path at the exit found it
        /// dead. A missing record is false.
        field_dead_at_exit: *const fn (*const anyopaque, ExitKind, usize, u32, []const u8) bool,
        /// True when the binding itself was moved (path `""`), not merely
        /// one of its fields.
        was_wholly_moved: *const fn (*const anyopaque, u32) bool,
    };

    pub fn nextBindingId(self: DropFacts) u32 {
        return self.vtable.next_binding_id(self.context);
    }

    pub fn bindingName(self: DropFacts, id: u32) ?[]const u8 {
        return self.vtable.binding_name(self.context, id);
    }

    pub fn wasMoved(self: DropFacts, id: u32) bool {
        return self.vtable.was_moved(self.context, id);
    }

    pub fn liveAtExit(self: DropFacts, kind: ExitKind, key: usize, id: u32) bool {
        return self.vtable.live_at_exit(self.context, kind, key, id);
    }

    pub fn assignReleasesOldValue(self: DropFacts, name_ptr: [*]const u8) bool {
        return self.vtable.assign_releases_old_value(self.context, name_ptr);
    }

    pub fn skipBreak(self: DropFacts, break_key: usize) bool {
        return self.vtable.skip_break(self.context, break_key);
    }

    pub fn fieldLiveAtExit(self: DropFacts, kind: ExitKind, key: usize, id: u32, path: []const u8) bool {
        return self.vtable.field_live_at_exit(self.context, kind, key, id, path);
    }

    pub fn fieldDeadAtExit(self: DropFacts, kind: ExitKind, key: usize, id: u32, path: []const u8) bool {
        return self.vtable.field_dead_at_exit(self.context, kind, key, id, path);
    }

    pub fn wasWhollyMoved(self: DropFacts, id: u32) bool {
        return self.vtable.was_wholly_moved(self.context, id);
    }
};
