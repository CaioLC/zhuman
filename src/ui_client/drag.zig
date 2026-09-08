const std = @import("std");
const activation = @import("activation.zig");
const cb = @import("ctx_binding.zig");
const input = @import("input.zig");

pub const Point = input.Point;
pub const drag_threshold = activation.PointerActivation.drag_threshold;

pub const DragUpdate = struct {
    started: bool = false,
    dragging: bool = false,
    delta: Point = .{},
};

/// Reusable threshold policy for board pans and slider-like controls. Capture can be
/// acquired on press, but movement remains zero until distance is strictly greater than
/// four logical pixels—the same threshold PointerActivation uses to suppress a click.
pub const ThresholdDrag = struct {
    active: bool = false,
    crossed: bool = false,
    origin: Point = .{},
    previous: Point = .{},

    pub fn begin(self: *ThresholdDrag, position: Point) void {
        self.* = .{ .active = true, .origin = position, .previous = position };
    }

    pub fn update(self: *ThresholdDrag, position: Point) DragUpdate {
        if (!self.active) return .{};
        const was_crossed = self.crossed;
        const dx = position.x - self.origin.x;
        const dy = position.y - self.origin.y;
        self.crossed = self.crossed or dx * dx + dy * dy > drag_threshold * drag_threshold;
        const delta = if (!self.crossed)
            Point{}
        else if (!was_crossed)
            Point{ .x = dx, .y = dy }
        else
            Point{ .x = position.x - self.previous.x, .y = position.y - self.previous.y };
        self.previous = position;
        return .{ .started = self.crossed and !was_crossed, .dragging = self.crossed, .delta = delta };
    }

    pub fn end(self: *ThresholdDrag) bool {
        const dragged = self.crossed;
        self.* = .{};
        return dragged;
    }
};

pub fn scrollOffsetFromDrag(origin_offset: f32, pointer_delta_y: f32, max_offset: f32, thumb_travel: f32) f32 {
    if (max_offset <= 0 or thumb_travel <= 0) return 0;
    return std.math.clamp(origin_offset + pointer_delta_y * max_offset / thumb_travel, 0, max_offset);
}

/// Capture and update one vertical scrollbar thumb. The press position stored by Input
/// preserves motion that arrives in the same event batch as the press. Release applies
/// its final position before owner-checked capture release; cancellation/lost capture
/// clears the widget state without moving from an unrelated pointer.
pub fn updateScrollThumb(
    ctx: *cb.UiCtx,
    state: *cb.UiState.ScrollState,
    key: u64,
    pressed: bool,
    max_offset: f32,
    thumb_travel: f32,
) void {
    const pointer = &ctx.res.input.pointer;
    if (pressed and ctx.capturePointer(key)) {
        state.dragging = true;
        state.drag_origin_y = pointer.buttons.primary.press_position.y;
        state.drag_origin_offset = state.offset;
        state.drag_pointer_kind = pointer.kind;
        state.drag_pointer_id = pointer.id;
        state.drag_owner_key = key;
    }

    if (!state.dragging) return;
    if (!ctx.hasPointerCapture(key)) {
        state.clearDrag();
        return;
    }
    if (ctx.res.input.cancelled) {
        _ = ctx.releasePointerCapture(key);
        state.clearDrag();
        return;
    }
    if (pointer.kind != state.drag_pointer_kind or pointer.id != state.drag_pointer_id) return;

    state.offset = scrollOffsetFromDrag(
        state.drag_origin_offset,
        pointer.position.y - state.drag_origin_y,
        max_offset,
        thumb_travel,
    );
    if (!pointer.buttons.primary.held) {
        _ = ctx.releasePointerCapture(key);
        state.clearDrag();
    }
}

/// End a scroll drag when overflow disappears before the thumb can rebuild. Generic
/// prune repair is still the final safety net, but normal widget teardown releases now.
pub fn cancelScrollThumb(ctx: *cb.UiCtx, state: *cb.UiState.ScrollState) void {
    if (state.drag_owner_key) |key| _ = ctx.releasePointerCapture(key);
    state.clearDrag();
}

test "threshold drag starts only beyond four logical pixels and reports pan deltas" {
    var drag: ThresholdDrag = .{};
    drag.begin(.{ .x = 10, .y = 10 });
    try std.testing.expectEqual(DragUpdate{}, drag.update(.{ .x = 14, .y = 10 }));

    const start = drag.update(.{ .x = 14.01, .y = 10 });
    try std.testing.expect(start.started and start.dragging);
    try std.testing.expectApproxEqAbs(@as(f32, 4.01), start.delta.x, 0.0001);

    const continuation = drag.update(.{ .x = 16, .y = 12 });
    try std.testing.expect(!continuation.started and continuation.dragging);
    try std.testing.expectApproxEqAbs(@as(f32, 1.99), continuation.delta.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 2), continuation.delta.y, 0.0001);
    try std.testing.expect(drag.end());
    try std.testing.expect(!drag.end());
}

test "scroll thumb drag maps track travel to clamped content offset" {
    try std.testing.expectEqual(@as(f32, 200), scrollOffsetFromDrag(100, 25, 400, 100));
    try std.testing.expectEqual(@as(f32, 0), scrollOffsetFromDrag(20, -50, 400, 100));
    try std.testing.expectEqual(@as(f32, 400), scrollOffsetFromDrag(390, 50, 400, 100));
    try std.testing.expectEqual(@as(f32, 0), scrollOffsetFromDrag(100, 25, 0, 100));
}

test "scroll thumb captures through outside motion and applies release position" {
    var resources: @import("../res.zig").Resources = undefined;
    resources.input = .{};
    resources.cursor = .{};
    var ctx = cb.UiCtx.init(&resources, std.testing.allocator, undefined);
    defer ctx.deinit();
    ctx.beginFrame();

    const key = @import("../ui/root.zig").key(0, "thumb");
    _ = ctx.interactionOf(key);
    _ = ctx.stampRect(key, .{ .x = 0, .y = 0, .w = 10, .h = 20 }, null, null);

    var state: cb.UiState.ScrollState = .{};
    resources.input.recordButton(.mouse, 7, .primary, true, 1, .{ .x = 5, .y = 10 });
    resources.input.recordMotion(.mouse, 7, .{ .x = 500, .y = 60 }, .{ .x = 495, .y = 50 });
    updateScrollThumb(&ctx, &state, key, true, 400, 100);
    try std.testing.expect(ctx.hasPointerCapture(key));
    try std.testing.expect(state.dragging);
    try std.testing.expectEqual(@as(f32, 200), state.offset);

    resources.input.recordButton(.mouse, 7, .primary, false, 1, .{ .x = 500, .y = 70 });
    updateScrollThumb(&ctx, &state, key, false, 400, 100);
    try std.testing.expectEqual(@as(f32, 240), state.offset);
    try std.testing.expect(!state.dragging);
    try std.testing.expectEqual(@as(?u64, null), ctx.capturedPointerKey());

    resources.input.recordButton(.mouse, 7, .primary, true, 1, .{ .x = 5, .y = 10 });
    updateScrollThumb(&ctx, &state, key, true, 400, 100);
    const before_mismatch = state.offset;
    resources.input.recordMotion(.pen, 99, .{ .x = 5, .y = 90 }, .{ .x = 0, .y = 80 });
    updateScrollThumb(&ctx, &state, key, false, 400, 100);
    try std.testing.expectEqual(before_mismatch, state.offset);
    try std.testing.expect(ctx.hasPointerCapture(key));

    resources.input.cancel();
    updateScrollThumb(&ctx, &state, key, false, 400, 100);
    try std.testing.expect(!state.dragging);
    try std.testing.expectEqual(@as(?u64, null), ctx.capturedPointerKey());

    resources.input = .{};
    resources.input.recordButton(.mouse, 7, .primary, true, 1, .{ .x = 5, .y = 10 });
    updateScrollThumb(&ctx, &state, key, true, 400, 100);
    ctx.cancelPointerCapture();
    updateScrollThumb(&ctx, &state, key, false, 400, 100);
    try std.testing.expect(!state.dragging);
}
