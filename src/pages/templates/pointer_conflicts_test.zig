//! Pointer conflict tests (QA-16), headless through the replay rig over the real templates:
//! a nested control's activation does not reach its parent, the modal scrim blocks the
//! screen behind it, the tooltip takes no hit, the wheel goes to the innermost scroll view
//! under the pointer, and a row scrolled out of its viewport cannot activate.
//!
//! Covered elsewhere, against the same router: a drag past the threshold suppresses the click
//! (`replay.zig`, and at every scale in `dpi_test.zig`); a resize leaves geometry stale for
//! one frame so no press lands on the old rects (`replay.zig`, `route.zig`); cancellation and
//! focus loss drop the gesture (`activation.zig`, `replay.zig`).

const std = @import("std");
const ha = @import("ha");
const uic = ha.ui_client;
const el = uic.elements;
const scroll_mod = @import("./scroll_view.zig");

const UiCtx = uic.UiCtx;
const Node = uic.Node;
const El = el.El;
const Trees = uic.Trees;
const Resources = ha.res.Resources;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const Rig = struct {
    res: Resources,
    arena: std.heap.ArenaAllocator,
    ui: UiCtx,
    driver: uic.FrameDriver,

    fn setUp(self: *Rig) void {
        self.res = uic.replay.headlessResources();
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        self.ui = UiCtx.init(&self.res, std.testing.allocator, self.arena.allocator());
        self.driver = uic.FrameDriver.init(&self.ui, &self.arena, std.testing.io, .none);
    }

    fn tearDown(self: *Rig) void {
        self.ui.deinit();
        self.arena.deinit();
    }
};

fn box(parent: El, id: []const u8, x: f32, y: f32, w: f32, h: f32) !El {
    return (try parent.div(id))
        .with_layout(.top_left)
        .with_offset(x, y)
        .with_size(.{ .fixed = w }, .{ .fixed = h });
}

fn click(r: *uic.Replay, x: f32, y: f32) !void {
    try r.frame(&.{ .{ .pointer_press = .{ .x = x, .y = y } }, .{ .pointer_release = .{ .x = x, .y = y } } });
}

fn list(ctx: *UiCtx, roots: []const *Node) !Trees {
    const out = try ctx.arena.alloc(*Node, roots.len);
    @memcpy(out, roots);
    return out;
}

// -- Nested cancel and overlays ---------------------------------------------------------

/// A build row (0,0 300x60) with a nested cancel corner (260,10 30x30), the way
/// `capital_row` builds one; optionally a modal over everything, or a tooltip over the row.
const Overlay = struct {
    modal: bool = false,
    tooltip: bool = false,
    row_clicks: u32 = 0,
    cancel_clicks: u32 = 0,
    dialog_clicks: u32 = 0,
    outside_clicks: u32 = 0,
    ok_key: u64 = 0,

    pub fn build(self: *Overlay, ctx: *UiCtx) anyerror!Trees {
        const root = try el.root(ctx, "root");
        const row = try box(root, "row", 0, 0, 300, 60);
        const cancel = try box(row, "cancel", 260, 10, 30, 30);
        _ = cancel.control(.{ .name = "Cancel", .role = .button });
        // The corner consumes its own activation, so it neither reports to the row nor
        // starts the row's action.
        if (cancel.consume(.clicked)) self.cancel_clicks += 1;
        // The row reads its activation after its descendants, as `capital_row` does.
        if (row.control(.{ .name = "Build", .role = .button }).clicked) self.row_clicks += 1;

        var roots: [2]*Node = .{ root.get(), undefined };
        var n: usize = 1;
        if (self.modal) {
            const m = try uic.modal(ctx, "dialog", "Dialog");
            const inside = (try m.box.div("ok")).with_size(.{ .fixed = 120 }, .{ .fixed = 40 });
            self.ok_key = inside.get().key;
            if (inside.control(.{ .name = "OK", .role = .button }).clicked) self.dialog_clicks += 1;
            _ = m.box.consume(.clicked);
            if (m.root.consume(.clicked)) self.outside_clicks += 1;
            roots[1] = m.root.get();
            n = 2;
        } else if (self.tooltip) {
            // `uic.tooltip` measures its label through the platform font, which the headless
            // rig has none of; this root is its box as `tooltip.zig` builds it, minus the
            // label: a tracked, pass-through root stamped after the screen.
            const node = try Node.create(ctx.arena, "tip");
            node.layout.anchor = .top_left;
            const tip = El{ .ctx = ctx, .node = node };
            _ = tip.with_size(.{ .fixed = 300 }, .{ .fixed = 60 }).track().pass_through();
            roots[1] = tip.get();
            n = 2;
        }
        return list(ctx, roots[0..n]);
    }
};

test "pointer: a nested cancel consumes its activation; the row does not start" {
    var rig: Rig = undefined;
    rig.setUp();
    defer rig.tearDown();
    var fx = Overlay{};
    var r = uic.Replay.init(&rig.driver, uic.replay.hostOf(Overlay, &fx));
    try r.idle(1);

    try click(&r, 275, 25);
    try expectEqual(@as(u32, 1), fx.cancel_clicks);
    try expectEqual(@as(u32, 0), fx.row_clicks);
    // The row outside the corner still activates.
    try click(&r, 50, 30);
    try expectEqual(@as(u32, 1), fx.row_clicks);
    try expectEqual(@as(u32, 1), fx.cancel_clicks);
}

test "pointer: the modal scrim blocks the screen behind it; the dialog takes its own clicks" {
    var rig: Rig = undefined;
    rig.setUp();
    defer rig.tearDown();
    var fx = Overlay{ .modal = true };
    var r = uic.Replay.init(&rig.driver, uic.replay.hostOf(Overlay, &fx));
    try r.idle(2);

    // On the row and on its cancel corner, both under the scrim: an outside activation only.
    try click(&r, 50, 30);
    try click(&r, 275, 25);
    try expectEqual(@as(u32, 0), fx.row_clicks);
    try expectEqual(@as(u32, 0), fx.cancel_clicks);
    try expectEqual(@as(u32, 2), fx.outside_clicks);

    // The dialog's button, centred in the 900x820 window.
    const ok = rig.ui.rectOf(fx.ok_key) orelse return error.Unstamped;
    try click(&r, ok.x + ok.w / 2, ok.y + ok.h / 2);
    try expectEqual(@as(u32, 1), fx.dialog_clicks);
    try expectEqual(@as(u32, 2), fx.outside_clicks);
}

test "pointer: a tooltip over a control takes no hit" {
    var rig: Rig = undefined;
    rig.setUp();
    defer rig.tearDown();
    var fx = Overlay{ .tooltip = true };
    var r = uic.Replay.init(&rig.driver, uic.replay.hostOf(Overlay, &fx));
    try r.idle(2);

    try click(&r, 50, 30);
    try expectEqual(@as(u32, 1), fx.row_clicks);
    try click(&r, 275, 25);
    try expectEqual(@as(u32, 1), fx.cancel_clicks);
}

// -- Nested scroll views ----------------------------------------------------------------

/// An outer scroll view (300x200) whose content is a 40px spacer, an inner scroll view
/// (300x100) of ten 30px rows, and 300px below; the inner rows are controls.
const Nested = struct {
    outer: f32 = 0,
    inner: f32 = 0,
    clicked: [10]u32 = @splat(0),

    pub fn build(self: *Nested, ctx: *UiCtx) anyerror!Trees {
        const root = try el.root(ctx, "root");
        const frame = try box(root, "frame", 0, 0, 300, 200);
        const outer = try scroll_mod.scroll_view(frame, "outer", .{ .width = 300, .height = 200, .gap = 0, .framed = false }, null);
        _ = (try outer.content.div("lead")).with_size(.{ .fixed = 300 }, .{ .fixed = 40 });
        const inner = try scroll_mod.scroll_view(outer.content, "inner", .{ .width = 300, .height = 100, .gap = 0, .framed = false }, null);
        for (0..10) |i| {
            const row = (try inner.content.item("row", i)).with_size(.{ .fixed = 280 }, .{ .fixed = 30 });
            if (row.control(.{ .name = "row", .role = .button }).clicked) self.clicked[i] += 1;
        }
        _ = (try outer.content.div("tail")).with_size(.{ .fixed = 300 }, .{ .fixed = 300 });
        self.outer = outer.outer.state(uic.UiState.ScrollState).offset;
        self.inner = inner.outer.state(uic.UiState.ScrollState).offset;
        return list(ctx, &.{root.get()});
    }
};

fn wheel(r: *uic.Replay, x: f32, y: f32, dy: f32) !void {
    try r.frame(&.{.{ .wheel = .{ .x = x, .y = y, .dy = dy } }});
    try r.idle(1);
}

test "pointer: the wheel scrolls the innermost scroll view under the pointer" {
    var rig: Rig = undefined;
    rig.setUp();
    defer rig.tearDown();
    var fx = Nested{};
    var r = uic.Replay.init(&rig.driver, uic.replay.hostOf(Nested, &fx));
    try r.idle(3);
    try expectEqual(@as(f32, 0), fx.outer);
    try expectEqual(@as(f32, 0), fx.inner);

    // Over the inner view (y 40..140): only it scrolls.
    try wheel(&r, 100, 80, -1);
    try expect(fx.inner > 0);
    try expectEqual(@as(f32, 0), fx.outer);

    // Over the outer view below the inner one: only the outer scrolls.
    const inner_before = fx.inner;
    try wheel(&r, 100, 170, -1);
    try expect(fx.outer > 0);
    try expectEqual(inner_before, fx.inner);
}

test "pointer: a row scrolled out of its viewport cannot activate" {
    var rig: Rig = undefined;
    rig.setUp();
    defer rig.tearDown();
    var fx = Nested{};
    var r = uic.Replay.init(&rig.driver, uic.replay.hostOf(Nested, &fx));
    try r.idle(3);

    // Row 4 sits at content y 120..150, i.e. window y 160..190, below the inner view's
    // 40..140 clip: its stamped box is there but a click on it does not reach it.
    try click(&r, 100, 175);
    try expectEqual(@as(u32, 0), fx.clicked[4]);
    // Row 1 (window y 70..100) is visible and takes the click.
    try click(&r, 100, 85);
    try expectEqual(@as(u32, 1), fx.clicked[1]);
}
