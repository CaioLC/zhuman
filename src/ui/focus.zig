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
        for (self.groups.items) |*g| g.seen = false;
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
        const count = self.globalCount(&self.current);
        if (count == 0) {
            self.focused = null;
            return false;
        }
        const current_ord = if (self.focused) |key| self.globalOrdinal(&self.current, key) else null;
        const dest: usize = if (current_ord) |ord| switch (direction) {
            .next => if (ord + 1 < count) ord + 1 else if (wrap) 0 else return false,
            .previous => if (ord > 0) ord - 1 else if (wrap) count - 1 else return false,
        } else switch (direction) {
            .next => 0,
            .previous => count - 1,
        };
        self.focused = self.globalAt(&self.current, dest).?.key;
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

    /// Repair group representatives and singular focus against the completed build,
    /// then publish its order for the next event stage.
    pub fn endFrame(self: *Focus) void {
        const old_ord = if (self.focused) |key| self.globalOrdinal(&self.current, key) else null;

        for (self.groups.items) |*g| {
            if (!g.seen) continue;
            if (g.active == null or !self.enabledIn(&self.building, g.active.?, g.key)) {
                g.active = self.firstEnabledInGroup(&self.building, g.key);
            }
        }

        if (self.focused) |key| {
            if (!self.enabledIn(&self.building, key, null)) {
                const count = self.globalCount(&self.building);
                self.focused = if (count == 0) null else self.globalAt(&self.building, @min(old_ord orelse 0, count - 1)).?.key;
            }
        }

        const old = self.current;
        self.current = self.building;
        self.building = old;
        self.building.clearRetainingCapacity();

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

    fn globalCount(self: *const Focus, entries: *const std.ArrayList(Target)) usize {
        var count: usize = 0;
        for (entries.items) |target| {
            if (self.isGlobal(target)) count += 1;
        }
        return count;
    }

    fn globalOrdinal(self: *const Focus, entries: *const std.ArrayList(Target), key: u64) ?usize {
        var ordinal: usize = 0;
        for (entries.items) |target| {
            if (!self.isGlobal(target)) continue;
            if (target.key == key) return ordinal;
            ordinal += 1;
        }
        return null;
    }

    fn globalAt(self: *const Focus, entries: *const std.ArrayList(Target), ordinal: usize) ?Target {
        var seen: usize = 0;
        for (entries.items) |target| {
            if (!self.isGlobal(target)) continue;
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

    try std.testing.expect(focus.moveInGroup(100, .next, false));
    try std.testing.expectEqual(@as(?u64, 12), focus.focusedKey());
    try std.testing.expect(!focus.moveInGroup(100, .next, false));

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
