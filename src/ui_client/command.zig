const std = @import("std");
const input = @import("input.zig");

pub const Command = enum {
    focus_next,
    focus_previous,
    move_left,
    move_right,
    move_up,
    move_down,
    activate,
    dismiss,
    focus_search,
    delete_backward,
    delete_forward,
    line_start,
    line_end,
};

/// Normalize SDL key events into host semantic commands. Release edges never command;
/// repeat is accepted only for movement/editing, not one-shot activation/dismissal.
pub fn fromKeyEvent(event: input.KeyEvent) ?Command {
    if (event.action == .release) return null;
    const one_shot = event.action == .press;
    return switch (event.key) {
        .tab => if (one_shot) (if (event.modifiers.shift) .focus_previous else .focus_next) else null,
        .left_tab => if (one_shot) .focus_previous else null,
        .left => .move_left,
        .right => .move_right,
        .up => .move_up,
        .down => .move_down,
        .return_key, .return_key2, .kp_enter, .space => if (one_shot) .activate else null,
        .escape => if (one_shot) .dismiss else null,
        .slash => if (one_shot and !event.modifiers.control and !event.modifiers.alt and !event.modifiers.gui) .focus_search else null,
        .backspace, .kp_backspace => .delete_backward,
        .delete => .delete_forward,
        .home => .line_start,
        .end => .line_end,
        else => null,
    };
}

/// Prior-build command owners used during the next event stage. Fixed capacity keeps
/// routing allocator-free; overflow is explicit and preserves already registered owners.
pub const Registry = struct {
    pub const max_text_owners = 32;

    current_text: [max_text_owners]u64 = undefined,
    current_text_len: usize = 0,
    building_text: [max_text_owners]u64 = undefined,
    building_text_len: usize = 0,
    current_search: ?u64 = null,
    building_search: ?u64 = null,
    current_escape: ?u64 = null,
    building_escape: ?u64 = null,
    overflow: bool = false,

    pub fn beginBuild(self: *Registry) void {
        self.building_text_len = 0;
        self.building_search = null;
        self.building_escape = null;
        self.overflow = false;
    }

    pub fn registerText(self: *Registry, key: u64, search_shortcut: bool) void {
        for (self.building_text[0..self.building_text_len]) |existing| {
            if (existing == key) {
                if (search_shortcut) self.building_search = key;
                return;
            }
        }
        if (self.building_text_len == self.building_text.len) {
            self.overflow = true;
            return;
        }
        self.building_text[self.building_text_len] = key;
        self.building_text_len += 1;
        if (search_shortcut) self.building_search = key;
    }

    /// Later overlays/views win, matching independent-root paint order.
    pub fn registerEscape(self: *Registry, key: u64) void {
        self.building_escape = key;
    }

    pub fn endBuild(self: *Registry) void {
        const old = self.current_text;
        self.current_text = self.building_text;
        self.building_text = old;
        self.current_text_len = self.building_text_len;
        self.current_search = self.building_search;
        self.current_escape = self.building_escape;
        self.building_text_len = 0;
        self.building_search = null;
        self.building_escape = null;
    }

    pub fn isTextOwner(self: *const Registry, key: u64) bool {
        for (self.current_text[0..self.current_text_len]) |owner| if (owner == key) return true;
        return false;
    }

    pub fn searchTarget(self: *const Registry) ?u64 {
        return self.current_search;
    }

    pub fn escapeTarget(self: *const Registry) ?u64 {
        return self.current_escape;
    }
};

test "key events map to complete command vocabulary with repeat policy" {
    const press = input.KeyAction.press;
    const repeat = input.KeyAction.repeat;
    try std.testing.expectEqual(Command.focus_next, fromKeyEvent(.{ .key = .tab, .action = press, .modifiers = .{} }).?);
    try std.testing.expectEqual(Command.focus_previous, fromKeyEvent(.{ .key = .tab, .action = press, .modifiers = .{ .shift = true } }).?);
    try std.testing.expectEqual(Command.move_left, fromKeyEvent(.{ .key = .left, .action = repeat, .modifiers = .{} }).?);
    try std.testing.expectEqual(Command.move_right, fromKeyEvent(.{ .key = .right, .action = press, .modifiers = .{} }).?);
    try std.testing.expectEqual(Command.move_up, fromKeyEvent(.{ .key = .up, .action = press, .modifiers = .{} }).?);
    try std.testing.expectEqual(Command.move_down, fromKeyEvent(.{ .key = .down, .action = press, .modifiers = .{} }).?);
    try std.testing.expectEqual(Command.activate, fromKeyEvent(.{ .key = .return_key, .action = press, .modifiers = .{} }).?);
    try std.testing.expectEqual(Command.activate, fromKeyEvent(.{ .key = .space, .action = press, .modifiers = .{} }).?);
    try std.testing.expectEqual(Command.dismiss, fromKeyEvent(.{ .key = .escape, .action = press, .modifiers = .{} }).?);
    try std.testing.expectEqual(Command.focus_search, fromKeyEvent(.{ .key = .slash, .action = press, .modifiers = .{} }).?);
    try std.testing.expectEqual(Command.delete_backward, fromKeyEvent(.{ .key = .backspace, .action = repeat, .modifiers = .{} }).?);
    try std.testing.expectEqual(Command.delete_forward, fromKeyEvent(.{ .key = .delete, .action = press, .modifiers = .{} }).?);
    try std.testing.expectEqual(Command.line_start, fromKeyEvent(.{ .key = .home, .action = press, .modifiers = .{} }).?);
    try std.testing.expectEqual(Command.line_end, fromKeyEvent(.{ .key = .end, .action = press, .modifiers = .{} }).?);
    try std.testing.expectEqual(@as(?Command, null), fromKeyEvent(.{ .key = .space, .action = repeat, .modifiers = .{} }));
    try std.testing.expectEqual(@as(?Command, null), fromKeyEvent(.{ .key = .escape, .action = .release, .modifiers = .{} }));
    try std.testing.expectEqual(@as(?Command, null), fromKeyEvent(.{ .key = .slash, .action = press, .modifiers = .{ .control = true } }));
}

test "registry publishes prior-build text search and topmost escape owners" {
    var registry: Registry = .{};
    registry.beginBuild();
    registry.registerText(10, false);
    registry.registerText(20, true);
    registry.registerText(20, true);
    registry.registerEscape(30);
    registry.registerEscape(40);
    registry.endBuild();

    try std.testing.expect(registry.isTextOwner(10));
    try std.testing.expect(registry.isTextOwner(20));
    try std.testing.expect(!registry.isTextOwner(99));
    try std.testing.expectEqual(@as(?u64, 20), registry.searchTarget());
    try std.testing.expectEqual(@as(?u64, 40), registry.escapeTarget());

    registry.beginBuild();
    registry.endBuild();
    try std.testing.expectEqual(@as(?u64, null), registry.searchTarget());
    try std.testing.expectEqual(@as(?u64, null), registry.escapeTarget());
    try std.testing.expect(!registry.isTextOwner(10));
}
