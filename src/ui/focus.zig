const std = @import("std");

pub const Direction = enum { next, previous };

pub const Focus = struct {
    const Target = struct { key: u64, enabled: bool, group: ?u64 = null };
    const Group = struct { key: u64, active: ?u64 = null, seen: bool = false };

    alloc: std.mem.Allocator,
    current: std.ArrayList(Target) = .empty,
    building: std.ArrayList(Target) = .empty,
    groups: std.ArrayList(Group) = .empty,
    focused: ?u64 = null,
    /// **Focus trap (KIT-08).** While a modal is open it calls `openScope()` just before it
    /// builds its own focusable content; that records the index in `building` from which the
    /// trapped targets begin (the modal is always built last, so everything from here on is
    /// "inside" the modal). Carried into `current` at `endFrame`, it restricts global Tab
    /// traversal (`move`) to that suffix, so Tab/Shift+Tab cycle only within the dialog and
    /// can never land on a control the scrim covers. `null` = no trap (ordinary whole-frame
    /// traversal). Reset every `beginFrame`; a frame that does not `openScope` has no trap.
    scope_start: ?usize = null,
    building_scope_start: ?usize = null,

    pub fn init(alloc: std.mem.Allocator) Focus {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Focus) void {
        self.current.deinit(self.alloc);
        self.building.deinit(self.alloc);
        self.groups.deinit(self.alloc);
    }

    /// Start collecting the new frame. Event-stage traversal has already consumed
    /// `current`; registrations now append to `building` in traversal order.
    pub fn beginFrame(self: *Focus) void {
        self.building.clearRetainingCapacity();
        self.building_scope_start = null; // a fresh frame has no trap until a modal opens one
        for (self.groups.items) |*g| g.seen = false;
    }

    /// Open a focus trap at the current build position (KIT-08). Everything registered after
    /// this call (the modal's own focusables) becomes the trapped set; `move` next frame cycles
    /// only within it. Idempotent within a frame — the earliest open wins (an outer modal).
    pub fn openScope(self: *Focus) void {
        if (self.building_scope_start == null) self.building_scope_start = self.building.items.len;
    }

    pub fn register(self: *Focus, key: u64, enabled: bool) void {
        self.building.append(self.alloc, .{ .key = key, .enabled = enabled }) catch @panic("focus registry OOM");
    }

    pub fn registerRoving(self: *Focus, group_key: u64, key: u64, enabled: bool) void {
        const g = self.group(group_key, true).?;
        g.seen = true;
        if (enabled and g.active == null) g.active = key;
        self.building.append(self.alloc, .{ .key = key, .enabled = enabled, .group = group_key }) catch @panic("focus registry OOM");
    }

    pub fn focusedKey(self: *const Focus) ?u64 {
        return self.focused;
    }

    pub fn isFocused(self: *const Focus, key: u64) bool {
        return self.focused == key;
    }

    /// Focus an enabled target registered in either the frame being built or the last
    /// completed frame. Pointer activation during build therefore takes effect at once.
    pub fn request(self: *Focus, key: u64) bool {
        const target = self.findEnabled(key) orelse return false;
        self.focused = key;
        if (target.group) |group_key| self.group(group_key, true).?.active = key;
        return true;
    }

    pub fn clear(self: *Focus) void {
        self.focused = null;
    }

    /// Traverse the last completed frame's global Tab order. Every ordinary enabled
    /// target participates; each roving group contributes only its active member.
    pub fn move(self: *Focus, direction: Direction, wrap: bool) bool {
        const count = self.globalCount(&self.current, true);
        if (count == 0) {
            self.focused = null;
            return false;
        }
        const current_ord = if (self.focused) |key| self.globalOrdinal(&self.current, key, true) else null;
        const dest: usize = if (current_ord) |ord| switch (direction) {
            .next => if (ord + 1 < count) ord + 1 else if (wrap) 0 else return false,
            .previous => if (ord > 0) ord - 1 else if (wrap) count - 1 else return false,
        } else switch (direction) {
            .next => 0,
            .previous => count - 1,
        };
        self.focused = self.globalAt(&self.current, dest, true).?.key;
        return true;
    }

    /// Move within one roving group without adding every member to global Tab order.
    pub fn moveInGroup(self: *Focus, group_key: u64, direction: Direction, wrap: bool) bool {
        const g = self.group(group_key, false) orelse return false;
        var count: usize = 0;
        var active_ord: ?usize = null;
        for (self.current.items) |target| {
            if (target.group != group_key or !target.enabled) continue;
            if (target.key == g.active) active_ord = count;
            count += 1;
        }
        if (count == 0) return false;
        const dest: usize = if (active_ord) |ord| switch (direction) {
            .next => if (ord + 1 < count) ord + 1 else if (wrap) 0 else return false,
            .previous => if (ord > 0) ord - 1 else if (wrap) count - 1 else return false,
        } else 0;
        var seen: usize = 0;
        for (self.current.items) |target| {
            if (target.group != group_key or !target.enabled) continue;
            if (seen == dest) {
                g.active = target.key;
                self.focused = target.key;
                return true;
            }
            seen += 1;
        }
        unreachable;
    }

    /// Move within the roving group containing the currently focused target. Returns
    /// false for ordinary focus targets or when the group cannot move.
    pub fn moveFocusedInGroup(self: *Focus, direction: Direction, wrap: bool) bool {
        const focused = self.focused orelse return false;
        for (self.current.items) |target| {
            if (target.key != focused) continue;
            const group_key = target.group orelse return false;
            return self.moveInGroup(group_key, direction, wrap);
        }
        return false;
    }

    /// Repair group representatives and singular focus against the completed build,
    /// then publish its order for the next event stage.
    pub fn endFrame(self: *Focus) void {
        const old_ord = if (self.focused) |key| self.globalOrdinal(&self.current, key, false) else null;

        for (self.groups.items) |*g| {
            if (!g.seen) continue;
            if (g.active == null or !self.enabledIn(&self.building, g.active.?, g.key)) {
                g.active = self.firstEnabledInGroup(&self.building, g.key);
            }
        }

        if (self.focused) |key| {
            if (!self.enabledIn(&self.building, key, null)) {
                const count = self.globalCount(&self.building, false);
                self.focused = if (count == 0) null else self.globalAt(&self.building, @min(old_ord orelse 0, count - 1), false).?.key;
            }
        }

        const old = self.current;
        self.current = self.building;
        self.building = old;
        self.building.clearRetainingCapacity();
        // Carry this build's trap suffix into `current` so next frame's `move` traverses only
        // the trapped targets (or the whole order when no modal opened a scope this frame).
        self.scope_start = self.building_scope_start;

        var i = self.groups.items.len;
        while (i > 0) {
            i -= 1;
            if (!self.groups.items[i].seen) _ = self.groups.swapRemove(i);
        }
    }

    fn group(self: *Focus, key: u64, create: bool) ?*Group {
        for (self.groups.items) |*g| if (g.key == key) return g;
        if (!create) return null;
        self.groups.append(self.alloc, .{ .key = key }) catch @panic("focus group OOM");
        return &self.groups.items[self.groups.items.len - 1];
    }

    fn findEnabled(self: *Focus, key: u64) ?Target {
        for (self.building.items) |target| if (target.key == key and target.enabled) return target;
        for (self.current.items) |target| if (target.key == key and target.enabled) return target;
        return null;
    }

    fn enabledIn(_: *const Focus, entries: *const std.ArrayList(Target), key: u64, group_key: ?u64) bool {
        for (entries.items) |target| {
            if (target.key == key and target.enabled and (group_key == null or target.group == group_key)) return true;
        }
        return false;
    }

    fn firstEnabledInGroup(_: *const Focus, entries: *const std.ArrayList(Target), group_key: u64) ?u64 {
        for (entries.items) |target| if (target.group == group_key and target.enabled) return target.key;
        return null;
    }

    fn isGlobal(self: *const Focus, target: Target) bool {
        if (!target.enabled) return false;
        const group_key = target.group orelse return true;
        for (self.groups.items) |g| if (g.key == group_key) return g.active == target.key;
        return false;
    }

    /// Whether the target at `index` participates under the active trap when `respect` is set:
    /// with no scope every index is in; with a scope only indices at or after `scope_start`
    /// (the modal's trapped suffix). Only `move` (traversing `current`) passes `respect=true`;
    /// the `endFrame` repair walks `building` and must not scope-filter, so it passes `false`.
    fn inScope(self: *const Focus, index: usize, respect: bool) bool {
        if (!respect) return true;
        const start = self.scope_start orelse return true;
        return index >= start;
    }

    fn globalCount(self: *const Focus, entries: *const std.ArrayList(Target), respect: bool) usize {
        var count: usize = 0;
        for (entries.items, 0..) |target, i| {
            if (self.inScope(i, respect) and self.isGlobal(target)) count += 1;
        }
        return count;
    }

    fn globalOrdinal(self: *const Focus, entries: *const std.ArrayList(Target), key: u64, respect: bool) ?usize {
        var ordinal: usize = 0;
        for (entries.items, 0..) |target, i| {
            if (!self.inScope(i, respect) or !self.isGlobal(target)) continue;
            if (target.key == key) return ordinal;
            ordinal += 1;
        }
        return null;
    }

    fn globalAt(self: *const Focus, entries: *const std.ArrayList(Target), ordinal: usize, respect: bool) ?Target {
        var seen: usize = 0;
        for (entries.items, 0..) |target, i| {
            if (!self.inScope(i, respect) or !self.isGlobal(target)) continue;
            if (seen == ordinal) return target;
            seen += 1;
        }
        return null;
    }
};

fn publish(focus: *Focus, entries: []const Focus.Target) void {
    focus.beginFrame();
    for (entries) |entry| {
        if (entry.group) |group_key|
            focus.registerRoving(group_key, entry.key, entry.enabled)
        else
            focus.register(entry.key, entry.enabled);
    }
    focus.endFrame();
}

test "global traversal skips disabled targets and honors wrap policy" {
    var focus = Focus.init(std.testing.allocator);
    defer focus.deinit();

    publish(&focus, &.{
        .{ .key = 10, .enabled = true },
        .{ .key = 20, .enabled = false },
        .{ .key = 30, .enabled = true },
    });

    try std.testing.expect(focus.move(.next, false));
    try std.testing.expectEqual(@as(?u64, 10), focus.focusedKey());
    try std.testing.expect(focus.move(.next, false));
    try std.testing.expectEqual(@as(?u64, 30), focus.focusedKey());
    try std.testing.expect(!focus.move(.next, false));
    try std.testing.expectEqual(@as(?u64, 30), focus.focusedKey());
    try std.testing.expect(focus.move(.next, true));
    try std.testing.expectEqual(@as(?u64, 10), focus.focusedKey());
    try std.testing.expect(focus.move(.previous, true));
    try std.testing.expectEqual(@as(?u64, 30), focus.focusedKey());
}

test "focus repairs removal disable and an empty conditional subtree" {
    var focus = Focus.init(std.testing.allocator);
    defer focus.deinit();

    publish(&focus, &.{
        .{ .key = 1, .enabled = true },
        .{ .key = 2, .enabled = true },
        .{ .key = 3, .enabled = true },
    });
    try std.testing.expect(focus.request(2));

    publish(&focus, &.{
        .{ .key = 1, .enabled = true },
        .{ .key = 3, .enabled = true },
    });
    try std.testing.expectEqual(@as(?u64, 3), focus.focusedKey());

    publish(&focus, &.{
        .{ .key = 1, .enabled = true },
        .{ .key = 3, .enabled = false },
    });
    try std.testing.expectEqual(@as(?u64, 1), focus.focusedKey());

    publish(&focus, &.{});
    try std.testing.expectEqual(@as(?u64, null), focus.focusedKey());
    try std.testing.expect(!focus.request(3));
}

test "stable domain key preserves focus across reorder" {
    var focus = Focus.init(std.testing.allocator);
    defer focus.deinit();

    publish(&focus, &.{
        .{ .key = 101, .enabled = true },
        .{ .key = 202, .enabled = true },
        .{ .key = 303, .enabled = true },
    });
    try std.testing.expect(focus.request(202));

    publish(&focus, &.{
        .{ .key = 303, .enabled = true },
        .{ .key = 101, .enabled = true },
        .{ .key = 202, .enabled = true },
    });
    try std.testing.expectEqual(@as(?u64, 202), focus.focusedKey());
}

test "roving group exposes one global stop and retains directional navigation" {
    var focus = Focus.init(std.testing.allocator);
    defer focus.deinit();

    publish(&focus, &.{
        .{ .key = 1, .enabled = true },
        .{ .key = 11, .enabled = true, .group = 100 },
        .{ .key = 12, .enabled = true, .group = 100 },
        .{ .key = 13, .enabled = false, .group = 100 },
        .{ .key = 2, .enabled = true },
    });

    try std.testing.expect(focus.move(.next, false));
    try std.testing.expectEqual(@as(?u64, 1), focus.focusedKey());
    try std.testing.expect(focus.move(.next, false));
    try std.testing.expectEqual(@as(?u64, 11), focus.focusedKey());
    try std.testing.expect(focus.move(.next, false));
    try std.testing.expectEqual(@as(?u64, 2), focus.focusedKey());

    try std.testing.expect(focus.request(11));
    try std.testing.expect(focus.moveFocusedInGroup(.next, false));
    try std.testing.expectEqual(@as(?u64, 12), focus.focusedKey());
    try std.testing.expect(!focus.moveFocusedInGroup(.next, false));

    publish(&focus, &.{
        .{ .key = 1, .enabled = true },
        .{ .key = 11, .enabled = true, .group = 100 },
        .{ .key = 12, .enabled = false, .group = 100 },
        .{ .key = 2, .enabled = true },
    });
    try std.testing.expectEqual(@as(?u64, 11), focus.focusedKey());
    try std.testing.expect(focus.move(.next, false));
    try std.testing.expectEqual(@as(?u64, 2), focus.focusedKey());
}

test "KIT-08 focus trap: an open scope confines Tab traversal to the modal's suffix" {
    var focus = Focus.init(std.testing.allocator);
    defer focus.deinit();

    // A frame: two background controls (the screen), then a modal opens a scope and registers
    // two of its own controls. The modal is built last, so its controls are the trapped suffix.
    focus.beginFrame();
    focus.register(1, true); // background A
    focus.register(2, true); // background B
    focus.openScope(); // modal opens the trap here
    focus.register(101, true); // dialog control A
    focus.register(102, true); // dialog control B
    focus.endFrame();

    // Tab cycles ONLY within the dialog's two controls — the background is unreachable.
    try std.testing.expect(focus.move(.next, true));
    try std.testing.expectEqual(@as(?u64, 101), focus.focusedKey());
    try std.testing.expect(focus.move(.next, true));
    try std.testing.expectEqual(@as(?u64, 102), focus.focusedKey());
    try std.testing.expect(focus.move(.next, true)); // wraps within the scope
    try std.testing.expectEqual(@as(?u64, 101), focus.focusedKey());
    try std.testing.expect(focus.move(.previous, true)); // and back, still trapped
    try std.testing.expectEqual(@as(?u64, 102), focus.focusedKey());
}

test "KIT-08 focus trap lifts when the modal closes (no scope next frame)" {
    var focus = Focus.init(std.testing.allocator);
    defer focus.deinit();

    // Modal open: trapped to {101,102}.
    focus.beginFrame();
    focus.register(1, true);
    focus.register(2, true);
    focus.openScope();
    focus.register(101, true);
    focus.endFrame();
    try std.testing.expect(focus.move(.next, true));
    try std.testing.expectEqual(@as(?u64, 101), focus.focusedKey());

    // Next frame the modal is gone — no scope opened, so traversal is whole-frame again and
    // reaches the background controls.
    focus.beginFrame();
    focus.register(1, true);
    focus.register(2, true);
    focus.endFrame();
    // Focused key 101 no longer exists; move falls to the whole (unscoped) order.
    try std.testing.expect(focus.move(.next, true));
    try std.testing.expectEqual(@as(?u64, 1), focus.focusedKey());
    try std.testing.expect(focus.move(.next, true));
    try std.testing.expectEqual(@as(?u64, 2), focus.focusedKey());
}
