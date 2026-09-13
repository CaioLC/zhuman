const std = @import("std");
const input = @import("input.zig");

pub const Command = enum {
    focus_next,
    focus_previous,
    move_left,
    move_right,
    move_up,
    move_down,
    page_up,
    page_down,
    activate,
    dismiss,
    focus_search,
    delete_backward,
    delete_forward,
    line_start,
    line_end,
    // INPUT-07 single-line editing: anchored selection, clipboard, and clear. Selection
    // variants mirror the movement commands with the anchor held (Shift held). Clipboard
    // commands are gated to the focused text owner and to SDL clipboard availability by
    // the host; the mapping here is pure and platform-agnostic.
    select_left,
    select_right,
    select_line_start,
    select_line_end,
    select_all,
    clipboard_copy,
    clipboard_cut,
    clipboard_paste,
    clear_field,
};

/// Normalize SDL key events into host semantic commands. Release edges never command;
/// repeat is accepted only for movement/editing, not one-shot activation/dismissal.
pub fn fromKeyEvent(event: input.KeyEvent) ?Command {
    if (event.action == .release) return null;
    const one_shot = event.action == .press;
    return switch (event.key) {
        .tab => if (one_shot) (if (event.modifiers.shift) .focus_previous else .focus_next) else null,
        .left_tab => if (one_shot) .focus_previous else null,
        .left => if (event.modifiers.shift) .select_left else .move_left,
        .right => if (event.modifiers.shift) .select_right else .move_right,
        .up => .move_up,
        .down => .move_down,
        .page_up => .page_up,
        .page_down => .page_down,
        .return_key, .return_key2, .kp_enter, .space => if (one_shot) .activate else null,
        .escape => if (one_shot) .dismiss else null,
        .slash => if (one_shot and !event.modifiers.control and !event.modifiers.alt and !event.modifiers.gui) .focus_search else null,
        .backspace, .kp_backspace => .delete_backward,
        .delete => .delete_forward,
        .home => if (event.modifiers.shift) .select_line_start else .line_start,
        .end => if (event.modifiers.shift) .select_line_end else .line_end,
        // Clipboard / select-all use the platform accelerator (Ctrl on desktop). Require
        // the accelerator and forbid Alt so plain typed letters never trigger them; the
        // host still gates these to the focused text owner and to clipboard availability.
        .a => if (one_shot and accel(event.modifiers)) .select_all else null,
        .c => if (one_shot and accel(event.modifiers)) .clipboard_copy else null,
        .x => if (one_shot and accel(event.modifiers)) .clipboard_cut else null,
        .v => if (one_shot and accel(event.modifiers)) .clipboard_paste else null,
        else => null,
    };
}

/// The desktop editing accelerator: Control held, without Alt (which would form an
/// AltGr/other chord). Kept in one place so every clipboard/select-all mapping agrees.
fn accel(mods: input.Modifiers) bool {
    return mods.control and !mods.alt;
}

/// Prior-build command owners used during the next event stage. Fixed capacity keeps
/// routing allocator-free; overflow is explicit and preserves already registered owners.
pub const Registry = struct {
    pub const max_text_owners = 32;
    pub const max_range_owners = 16;

    current_text: [max_text_owners]u64 = undefined,
    current_text_len: usize = 0,
    building_text: [max_text_owners]u64 = undefined,
    building_text_len: usize = 0,
    current_range: [max_range_owners]u64 = undefined,
    current_range_len: usize = 0,
    building_range: [max_range_owners]u64 = undefined,
    building_range_len: usize = 0,
    current_search: ?u64 = null,
    building_search: ?u64 = null,
    current_escape: ?u64 = null,
    building_escape: ?u64 = null,
    overflow: bool = false,

    pub fn beginBuild(self: *Registry) void {
        self.building_text_len = 0;
        self.building_range_len = 0;
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

    pub fn registerRange(self: *Registry, key: u64) void {
        for (self.building_range[0..self.building_range_len]) |existing| {
            if (existing == key) return;
        }
        if (self.building_range_len == self.building_range.len) {
            self.overflow = true;
            return;
        }
        self.building_range[self.building_range_len] = key;
        self.building_range_len += 1;
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
        const old_range = self.current_range;
        self.current_range = self.building_range;
        self.building_range = old_range;
        self.current_range_len = self.building_range_len;
        self.current_search = self.building_search;
        self.current_escape = self.building_escape;
        self.building_text_len = 0;
        self.building_range_len = 0;
        self.building_search = null;
        self.building_escape = null;
    }

    pub fn isTextOwner(self: *const Registry, key: u64) bool {
        for (self.current_text[0..self.current_text_len]) |owner| if (owner == key) return true;
        return false;
    }

    pub fn isRangeOwner(self: *const Registry, key: u64) bool {
        for (self.current_range[0..self.current_range_len]) |owner| if (owner == key) return true;
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
    try std.testing.expectEqual(Command.page_up, fromKeyEvent(.{ .key = .page_up, .action = repeat, .modifiers = .{} }).?);
    try std.testing.expectEqual(Command.page_down, fromKeyEvent(.{ .key = .page_down, .action = press, .modifiers = .{} }).?);
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

test "shift and accelerator chords map to INPUT-07 selection, clipboard, and select-all" {
    const press = input.KeyAction.press;
    const repeat = input.KeyAction.repeat;
    const shift = input.Modifiers{ .shift = true };
    const ctrl = input.Modifiers{ .control = true };

    // Shift + movement keys select instead of moving; repeat still extends selection.
    try std.testing.expectEqual(Command.select_left, fromKeyEvent(.{ .key = .left, .action = press, .modifiers = shift }).?);
    try std.testing.expectEqual(Command.select_right, fromKeyEvent(.{ .key = .right, .action = repeat, .modifiers = shift }).?);
    try std.testing.expectEqual(Command.select_line_start, fromKeyEvent(.{ .key = .home, .action = press, .modifiers = shift }).?);
    try std.testing.expectEqual(Command.select_line_end, fromKeyEvent(.{ .key = .end, .action = press, .modifiers = shift }).?);

    // Without shift the same keys keep their plain movement meaning.
    try std.testing.expectEqual(Command.move_left, fromKeyEvent(.{ .key = .left, .action = press, .modifiers = .{} }).?);
    try std.testing.expectEqual(Command.line_start, fromKeyEvent(.{ .key = .home, .action = press, .modifiers = .{} }).?);
    try std.testing.expectEqual(Command.line_end, fromKeyEvent(.{ .key = .end, .action = press, .modifiers = .{} }).?);

    // Ctrl accelerators: select-all / copy / cut / paste, all one-shot only.
    try std.testing.expectEqual(Command.select_all, fromKeyEvent(.{ .key = .a, .action = press, .modifiers = ctrl }).?);
    try std.testing.expectEqual(Command.clipboard_copy, fromKeyEvent(.{ .key = .c, .action = press, .modifiers = ctrl }).?);
    try std.testing.expectEqual(Command.clipboard_cut, fromKeyEvent(.{ .key = .x, .action = press, .modifiers = ctrl }).?);
    try std.testing.expectEqual(Command.clipboard_paste, fromKeyEvent(.{ .key = .v, .action = press, .modifiers = ctrl }).?);
    try std.testing.expectEqual(@as(?Command, null), fromKeyEvent(.{ .key = .a, .action = repeat, .modifiers = ctrl }));
    try std.testing.expectEqual(@as(?Command, null), fromKeyEvent(.{ .key = .v, .action = repeat, .modifiers = ctrl }));

    // Plain letters without the accelerator are never editing commands — they type.
    try std.testing.expectEqual(@as(?Command, null), fromKeyEvent(.{ .key = .a, .action = press, .modifiers = .{} }));
    try std.testing.expectEqual(@as(?Command, null), fromKeyEvent(.{ .key = .c, .action = press, .modifiers = .{} }));
    // Alt held cancels the accelerator (AltGr / other chords must not clobber typing).
    try std.testing.expectEqual(@as(?Command, null), fromKeyEvent(.{ .key = .c, .action = press, .modifiers = .{ .control = true, .alt = true } }));
}

test "registry publishes prior-build text, range, search, and topmost escape owners" {
    var registry: Registry = .{};
    registry.beginBuild();
    registry.registerText(10, false);
    registry.registerText(20, true);
    registry.registerText(20, true);
    registry.registerRange(50);
    registry.registerRange(50);
    registry.registerEscape(30);
    registry.registerEscape(40);
    registry.endBuild();

    try std.testing.expect(registry.isTextOwner(10));
    try std.testing.expect(registry.isTextOwner(20));
    try std.testing.expect(!registry.isTextOwner(99));
    try std.testing.expect(registry.isRangeOwner(50));
    try std.testing.expect(!registry.isRangeOwner(99));
    try std.testing.expectEqual(@as(?u64, 20), registry.searchTarget());
    try std.testing.expectEqual(@as(?u64, 40), registry.escapeTarget());

    registry.beginBuild();
    registry.endBuild();
    try std.testing.expectEqual(@as(?u64, null), registry.searchTarget());
    try std.testing.expectEqual(@as(?u64, null), registry.escapeTarget());
    try std.testing.expect(!registry.isTextOwner(10));
    try std.testing.expect(!registry.isRangeOwner(50));
}
