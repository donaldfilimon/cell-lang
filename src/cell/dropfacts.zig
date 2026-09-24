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
};
