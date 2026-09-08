const std = @import("std");
const input = @import("input.zig");

const Point = input.Point;
const PointerKind = input.PointerKind;

/// Host policy for turning primary-pointer edges into one control activation.
/// The generic UI engine only supplies stable targets and routes typed flags.
pub const PointerActivation = struct {
    pub const drag_threshold: f32 = 4;

    pressed_key: ?u64 = null,
    pointer_kind: PointerKind = .unknown,
    pointer_id: ?u64 = null,
    origin: Point = .{},
    dragged: bool = false,

    pub fn press(self: *PointerActivation, target: ?u64, kind: PointerKind, id: ?u64, position: Point) void {
        self.* = .{
            .pressed_key = target,
            .pointer_kind = kind,
            .pointer_id = id,
            .origin = position,
        };
    }

    pub fn motion(self: *PointerActivation, kind: PointerKind, id: ?u64, position: Point) void {
        if (self.pressed_key == null or !self.samePointer(kind, id)) return;
        const dx = position.x - self.origin.x;
        const dy = position.y - self.origin.y;
        self.dragged = self.dragged or dx * dx + dy * dy > drag_threshold * drag_threshold;
    }

    /// Complete only for the pointer and stable target that began the gesture. The
    /// candidate is always consumed by its matching release, making completion one-shot.
    pub fn release(self: *PointerActivation, target: ?u64, kind: PointerKind, id: ?u64, position: Point) ?u64 {
        if (self.pressed_key == null or !self.samePointer(kind, id)) return null;
        self.motion(kind, id, position);
        const pressed_key = self.pressed_key;
        const activate = !self.dragged and target == pressed_key;
        self.cancel();
        return if (activate) pressed_key else null;
    }

    pub fn cancel(self: *PointerActivation) void {
        self.* = .{};
    }

    pub fn pressedKey(self: *const PointerActivation) ?u64 {
        return self.pressed_key;
    }

    pub fn draggingKey(self: *const PointerActivation) ?u64 {
        return if (self.dragged) self.pressed_key else null;
    }

    fn samePointer(self: *const PointerActivation, kind: PointerKind, id: ?u64) bool {
        return self.pointer_kind == kind and self.pointer_id == id;
    }
};

test "activation completes once on release over its press target" {
    var activation: PointerActivation = .{};
    activation.press(11, .mouse, 2, .{ .x = 10, .y = 20 });
    try std.testing.expectEqual(@as(?u64, 11), activation.release(11, .mouse, 2, .{ .x = 12, .y = 22 }));
    try std.testing.expectEqual(@as(?u64, null), activation.release(11, .mouse, 2, .{ .x = 12, .y = 22 }));
}

test "release over a different target is suppressed" {
    var activation: PointerActivation = .{};
    activation.press(11, .mouse, null, .{ .x = 10, .y = 20 });
    try std.testing.expectEqual(@as(?u64, null), activation.release(12, .mouse, null, .{ .x = 11, .y = 20 }));
    try std.testing.expectEqual(@as(?u64, null), activation.pressed_key);
}

test "movement through the threshold is tolerated but a drag is suppressed" {
    var activation: PointerActivation = .{};
    activation.press(11, .pen, 4, .{ .x = 10, .y = 10 });
    try std.testing.expectEqual(@as(?u64, 11), activation.pressedKey());
    try std.testing.expectEqual(@as(?u64, null), activation.draggingKey());
    activation.motion(.pen, 4, .{ .x = 14, .y = 10 });
    try std.testing.expect(!activation.dragged);
    try std.testing.expectEqual(@as(?u64, null), activation.draggingKey());
    try std.testing.expectEqual(@as(?u64, 11), activation.release(11, .pen, 4, .{ .x = 14, .y = 10 }));

    activation.press(11, .pen, 4, .{ .x = 10, .y = 10 });
    activation.motion(.pen, 4, .{ .x = 14.01, .y = 10 });
    try std.testing.expect(activation.dragged);
    try std.testing.expectEqual(@as(?u64, 11), activation.draggingKey());
    try std.testing.expectEqual(@as(?u64, null), activation.release(11, .pen, 4, .{ .x = 10, .y = 10 }));
    try std.testing.expectEqual(@as(?u64, null), activation.pressedKey());
}

test "cancellation and a different pointer cannot complete a press" {
    var activation: PointerActivation = .{};
    activation.press(11, .touch, 7, .{ .x = 10, .y = 10 });
    try std.testing.expectEqual(@as(?u64, null), activation.release(11, .touch, 8, .{ .x = 10, .y = 10 }));
    try std.testing.expectEqual(@as(?u64, 11), activation.pressed_key);
    activation.cancel();
    try std.testing.expectEqual(@as(?u64, null), activation.release(11, .touch, 7, .{ .x = 10, .y = 10 }));
}

test "representative control categories receive one completion per gesture" {
    const control_keys = [_]u64{ 101, 102, 103, 104, 105, 106 }; // build, action, offer, tab, disclosure, close
    for (control_keys) |key| {
        var activation: PointerActivation = .{};
        activation.press(key, .mouse, 1, .{ .x = 5, .y = 5 });
        var completions: u8 = 0;
        if (activation.release(key, .mouse, 1, .{ .x = 5, .y = 5 }) != null) completions += 1;
        if (activation.release(key, .mouse, 1, .{ .x = 5, .y = 5 }) != null) completions += 1;
        try std.testing.expectEqual(@as(u8, 1), completions);
    }
}
