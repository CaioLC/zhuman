//! DPI tests at scales 1, 1.5 and 2, SDL-free through the replay rig.
//!
//! Every authored dimension is logical px scaled once through `view.dp` at the `El` and style
//! seams, the layout is solved and hit-tested in device px, and a pointer reaches that space
//! through `pointer_scale`. These tests build one scene at each scale and pin the result:
//! the stamped boxes are the logical boxes times the scale, padding and gaps included; a
//! pointer converted from window coordinates hits the same control at every scale and misses
//! just outside it; a clip crops hits at the scaled edge; the drag threshold stays four
//! logical px; the scrollbar's drag mapping and the focus ring scale with the frame.
//!
//! Text cells are not covered here: a text leaf measures through the platform font, so its
//! scaling (`type.toDevice`) is pinned in `type.zig` and the live pages are checked by the
//! screenshot matrix.

const std = @import("std");
const ui = @import("ui");
const cb = @import("./ctx_binding.zig");
const el = @import("./elements.zig");
const frame_mod = @import("./frame.zig");
const replay = @import("./replay.zig");
const style = @import("./style.zig");
const view = @import("./view.zig");
const drag = @import("./drag.zig");
const paint = @import("./features/paint.zig");

const UiCtx = cb.UiCtx;
const Node = cb.Node;
const Style = style.Style;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const scales = [_]f32{ 1, 1.5, 2 };

const Rig = struct {
    res: @import("../res.zig").Resources,
    arena: std.heap.ArenaAllocator,
    ui: UiCtx,
    driver: frame_mod.Driver,

    fn setUp(self: *Rig) void {
        self.res = replay.headlessResources();
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        self.ui = UiCtx.init(&self.res, std.testing.allocator, self.arena.allocator());
        self.driver = frame_mod.Driver.init(&self.ui, &self.arena, std.testing.io, .none);
    }

    fn tearDown(self: *Rig) void {
        self.ui.deinit();
        self.arena.deinit();
    }
};

/// The scene, in logical px:
///   panel   at (20,10), a 200x100 content box inside padding 12 across and 8 down, a row
///           with a 6px gap
///     a     40x30, the first in the row
///     b     40x30, after a and the gap
///   window  at (300,10), 60x40, clipping
///     inner a 60x40 control offset 30 right, so its right half lies outside the clip
const Scene = struct {
    a_clicks: u32 = 0,
    inner_clicks: u32 = 0,
    dragging: bool = false,

    pub fn build(self: *Scene, ctx: *UiCtx) anyerror!replay.Trees {
        const root = try el.root(ctx, "root");
        const panel = (try root.div("panel"))
            .with_layout(.top_left)
            .with_offset(20, 10)
            .with_size(.{ .fixed = 200 }, .{ .fixed = 100 })
            .with_flow(.{ .dir = .row })
            .with_style(.{style.pad_sym(12, 8)})
            .with_gap(6);
        _ = panel.track();
        const a = (try panel.div("a")).with_size(.{ .fixed = 40 }, .{ .fixed = 30 });
        const aq = a.query();
        if (aq.clicked) self.a_clicks += 1;
        self.dragging = aq.dragging;
        _ = (try panel.div("b")).with_size(.{ .fixed = 40 }, .{ .fixed = 30 }).track();

        const window = (try root.div("window"))
            .with_layout(.top_left)
            .with_offset(300, 10)
            .with_size(.{ .fixed = 60 }, .{ .fixed = 40 })
            .with_overflow(.clip);
        _ = window.pass_through().track();
        const inner = (try window.div("inner"))
            .with_layout(.top_left)
            .with_offset(30, 0)
            .with_size(.{ .fixed = 60 }, .{ .fixed = 40 });
        if (inner.query().clicked) self.inner_clicks += 1;

        const list = try ctx.arena.alloc(*Node, 1);
        list[0] = root.get();
        return list;
    }
};

const root_key = ui.key(0, "root");
const panel_key = ui.key(root_key, "panel");
const a_key = ui.key(panel_key, "a");
const b_key = ui.key(panel_key, "b");
const window_key = ui.key(root_key, "window");
const inner_key = ui.key(window_key, "inner");

fn scaled(r: ui.Rect, s: f32) ui.Rect {
    return .{ .x = r.x * s, .y = r.y * s, .w = r.w * s, .h = r.h * s };
}

fn expectRect(want: ui.Rect, got: ?ui.Rect) !void {
    const g = got orelse return error.Unstamped;
    try std.testing.expectApproxEqAbs(want.x, g.x, 0.01);
    try std.testing.expectApproxEqAbs(want.y, g.y, 0.01);
    try std.testing.expectApproxEqAbs(want.w, g.w, 0.01);
    try std.testing.expectApproxEqAbs(want.h, g.h, 0.01);
}

/// A window-coordinate point as the SDL loop hands it to the router (`main.pointerAt`).
fn atWindow(m: view.ViewMetrics, x: f32, y: f32) replay.Point {
    return .{ .x = x * m.pointer_scale, .y = y * m.pointer_scale };
}

fn click(r: *replay.Replay, p: replay.Point) !void {
    try r.frame(&.{ .{ .pointer_press = .{ .x = p.x, .y = p.y } }, .{ .pointer_release = .{ .x = p.x, .y = p.y } } });
}

test "dpi: stamped boxes, padding and gaps are the logical ones times the scale" {
    for (scales) |s| {
        var rig: Rig = undefined;
        rig.setUp();
        defer rig.tearDown();
        var scene = Scene{};
        var r = replay.Replay.init(&rig.driver, replay.hostOf(Scene, &scene));
        try r.frame(&.{.{ .resize = .{ .logical_w = 900, .logical_h = 820, .pixel_density = s } }});
        try r.idle(1);

        try expectEqual(s, rig.res.view.scale);
        try std.testing.expectApproxEqAbs(@as(f32, 900) * s, rig.res.view.metrics.px_w, 0.01);
        // A fixed size is the content box; the padding (12 across, 8 down) adds to it.
        try expectRect(scaled(.{ .x = 20, .y = 10, .w = 224, .h = 116 }, s), rig.ui.rectOf(panel_key));
        try expectRect(scaled(.{ .x = 32, .y = 18, .w = 40, .h = 30 }, s), rig.ui.rectOf(a_key));
        try expectRect(scaled(.{ .x = 78, .y = 18, .w = 40, .h = 30 }, s), rig.ui.rectOf(b_key));
        // The clipped control keeps its whole box; its clip is the window's, scaled.
        const g = rig.ui.priorGeometryOf(inner_key) orelse return error.Unstamped;
        try expectRect(scaled(.{ .x = 330, .y = 10, .w = 60, .h = 40 }, s), g.rect);
        try expectRect(scaled(.{ .x = 300, .y = 10, .w = 60, .h = 40 }, s), g.clip);
    }
}

test "dpi: a window-coordinate pointer hits the same control at every scale, and misses past its edge" {
    for (scales) |s| {
        var rig: Rig = undefined;
        rig.setUp();
        defer rig.tearDown();
        var scene = Scene{};
        var r = replay.Replay.init(&rig.driver, replay.hostOf(Scene, &scene));
        try r.frame(&.{.{ .resize = .{ .logical_w = 900, .logical_h = 820, .pixel_density = s } }});
        try r.idle(1);
        const m = rig.res.view.metrics;
        try expectEqual(s, m.pointer_scale);

        // Inside a near its far corner: a click.
        try click(&r, atWindow(m, 71, 47));
        try expectEqual(@as(u32, 1), scene.a_clicks);
        // In the 6px gap between a and b: nothing.
        try click(&r, atWindow(m, 74, 30));
        try expectEqual(@as(u32, 1), scene.a_clicks);
        // Just past a's bottom edge, in the panel's padding: nothing.
        try click(&r, atWindow(m, 50, 49));
        try expectEqual(@as(u32, 1), scene.a_clicks);
    }
}

test "dpi: a clip crops hits at its scaled edge" {
    for (scales) |s| {
        var rig: Rig = undefined;
        rig.setUp();
        defer rig.tearDown();
        var scene = Scene{};
        var r = replay.Replay.init(&rig.driver, replay.hostOf(Scene, &scene));
        try r.frame(&.{.{ .resize = .{ .logical_w = 900, .logical_h = 820, .pixel_density = s } }});
        try r.idle(1);
        const m = rig.res.view.metrics;

        // The inner control's visible part (330..360) takes the click.
        try click(&r, atWindow(m, 355, 20));
        try expectEqual(@as(u32, 1), scene.inner_clicks);
        // Its clipped part (360..390) is inside its box but outside the window's clip.
        try click(&r, atWindow(m, 365, 20));
        try expectEqual(@as(u32, 1), scene.inner_clicks);
    }
}

test "dpi: the drag threshold stays four logical px" {
    for (scales) |s| {
        var rig: Rig = undefined;
        rig.setUp();
        defer rig.tearDown();
        var scene = Scene{};
        var r = replay.Replay.init(&rig.driver, replay.hostOf(Scene, &scene));
        try r.frame(&.{.{ .resize = .{ .logical_w = 900, .logical_h = 820, .pixel_density = s } }});
        try r.idle(1);
        const m = rig.res.view.metrics;

        const start = atWindow(m, 40, 25);
        try r.frame(&.{.{ .pointer_press = .{ .x = start.x, .y = start.y } }});
        // Three logical px is under the threshold at every scale, though it is six device px at 2.
        const near = atWindow(m, 43, 25);
        try r.frame(&.{.{ .pointer_move = .{ .x = near.x, .y = near.y } }});
        try expect(!scene.dragging);
        const far = atWindow(m, 45, 25);
        try r.frame(&.{.{ .pointer_move = .{ .x = far.x, .y = far.y } }});
        try expect(scene.dragging);
        // A drag suppresses the click.
        try r.frame(&.{.{ .pointer_release = .{ .x = far.x, .y = far.y } }});
        try expectEqual(@as(u32, 0), scene.a_clicks);
    }
}

test "dpi: a UI scale zooms the logical space while the pointer keeps the pixel density" {
    for (scales) |s| {
        const m = view.computeZoomed(900, 820, s, 1.25);
        try std.testing.expectApproxEqAbs(@as(f32, 900 / 1.25), m.logical_w, 0.01);
        try std.testing.expectApproxEqAbs(s * 1.25, m.dpi_scale, 0.001);
        try expectEqual(s, m.pointer_scale);
        try std.testing.expectApproxEqAbs(@as(f32, 900) * s, m.px_w, 0.01);
    }
}

test "dpi: the scrollbar's drag maps the same logical distance to the same offset" {
    // The scroll view sizes its thumb travel and its offset in device px; a drag of the same
    // logical distance at any scale moves the content by the same logical amount.
    const travel_l: f32 = 200;
    const max_l: f32 = 600;
    for (scales) |s| {
        const off = drag.scrollOffsetFromDrag(0, 50 * s, max_l * s, travel_l * s);
        try std.testing.expectApproxEqAbs(@as(f32, 150) * s, off, 0.01);
        // Clamped at both ends in device px.
        try std.testing.expectApproxEqAbs(max_l * s, drag.scrollOffsetFromDrag(0, 400 * s, max_l * s, travel_l * s), 0.01);
        try std.testing.expectApproxEqAbs(@as(f32, 0), drag.scrollOffsetFromDrag(0, -10 * s, max_l * s, travel_l * s), 0.01);
    }
}

test "dpi: the focus ring's offset and hairline round to whole device px" {
    const box: ui.Rect = .{ .x = 100, .y = 50, .w = 40, .h = 20 };
    // 1.5: offset round(4.5) = 5 (ties away), hairline round(1.5) = 2, so 7 out on each side.
    try expectRect(.{ .x = 93, .y = 43, .w = 54, .h = 34 }, paint.focusRing(box, null, 1.5));
    for (scales) |s| {
        const ring = paint.focusRing(box, null, s).?;
        const out = box.x - ring.x;
        try expectEqual(@round(out), out);
        try expect(out >= 4 * s - 1);
    }
}
