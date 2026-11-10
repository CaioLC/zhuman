//! The trade dialog's deal slip, headless through the replay rig with the real font (SDL_ttf
//! needs no window), so the slip's wrapped lines take their true heights. The fixture tracks
//! the slip and its content region so their stamped rects can be read beside the call to
//! action's, found by its accessible name.

const std = @import("std");
const ha = @import("ha");
const uic = ha.ui_client;
const style = uic.style;
const res_mod = ha.res;
const td = @import("./trade_dialog.zig");

const testing = std.testing;
const Term = td.Term;
const Lot = td.Lot;

const tall_consequence = "Replaces Fishing rod: Fish yield 1\u{2013}3 \u{2192} 2\u{2013}5. The unlock does not stack.";
/// More stocks than a region holds AFTER rows for (a text leaf holds at most 256 bytes, so the
/// height comes from rows rather than one long line).
const many = [_]Term{
    .{ .key = "water", .n = 6 },  .{ .key = "minerals", .n = 5 }, .{ .key = "fuel", .n = 4 },
    .{ .key = "metal", .n = 3 },  .{ .key = "salt", .n = 4 },     .{ .key = "oil", .n = 3 },
    .{ .key = "nails", .n = 12 }, .{ .key = "cloth", .n = 4 },
};

const lots = [_]Lot{
    // One term each way, no consequence: the shortest takeable slip.
    .{ .id = 1, .mode = .buy, .lot = "Preserved food \u{00d7}10", .effect = "keeps well", .price = &.{.{ .key = "materials", .n = 8 }}, .receive = &.{.{ .key = "food", .n = 10 }}, .stock = 2 },
    // The tallest authored slip: a two-resource price, three AFTER rows and a consequence.
    .{ .id = 2, .mode = .buy, .lot = "Fishing net \u{00d7}1", .effect = "better Fish tool", .price = &.{ .{ .key = "food", .n = 5 }, .{ .key = "materials", .n = 20 } }, .receive = &.{.{ .key = "fishing net", .n = 1, .stock = false }}, .stock = 1, .consequence = tall_consequence },
    // Short of materials: the refusal and CANNOT TRADE.
    .{ .id = 3, .mode = .buy, .lot = "Hand axe \u{00d7}1", .effect = "splitting costs less", .price = &.{ .{ .key = "food", .n = 6 }, .{ .key = "materials", .n = 80 } }, .receive = &.{.{ .key = "hand axe", .n = 1, .stock = false }}, .stock = 1 },
    // Taller than any region: its terms must scroll.
    .{ .id = 4, .mode = .buy, .lot = "Fishing net \u{00d7}1", .effect = "better Fish tool", .price = &.{ .{ .key = "food", .n = 5 }, .{ .key = "materials", .n = 20 } }, .receive = &many, .stock = 2, .consequence = tall_consequence },
};
const balances = [_]td.Balance{
    .{ .key = "food", .held = 31 }, .{ .key = "materials", .held = 61 }, .{ .key = "fishing net", .held = 0 },
    .{ .key = "water", .held = 0 }, .{ .key = "minerals", .held = 0 },   .{ .key = "fuel", .held = 0 },
    .{ .key = "metal", .held = 0 }, .{ .key = "salt", .held = 0 },       .{ .key = "oil", .held = 0 },
    .{ .key = "nails", .held = 0 }, .{ .key = "cloth", .held = 0 },
};
const book = td.Book{ .lots = &lots, .balances = &balances, .notation = .{ .abbrev = &.{ .{ .key = "food", .letter = "f" }, .{ .key = "materials", .letter = "m" } } } };

const TradeFixture = struct {
    st: uic.UiState.TradeState = .{},
    slip: u64 = 0,
    region: u64 = 0,

    pub fn build(self: *TradeFixture, ctx: *uic.UiCtx) anyerror!uic.Trees {
        const r = try td.trade_dialog(ctx, "trade", .passerby, "1.8 DAYS LEFT", book, &.{}, &self.st);
        // Track the slip and its region so their rects stamp for the next frame.
        var it = r.root.iterate();
        while (it.next()) |n| {
            const parent_id = if (n.parent) |p| p.id else "";
            const is_slip = std.mem.eql(u8, n.id, "slip") and std.mem.eql(u8, parent_id, "trade_body");
            const is_region = std.mem.eql(u8, n.id, "region") and std.mem.eql(u8, parent_id, "slip");
            if (!is_slip and !is_region) continue;
            _ = (uic.elements.El{ .ctx = ctx, .node = n }).track();
            if (is_slip) self.slip = n.key else self.region = n.key;
        }
        const out = try ctx.arena.alloc(*uic.Node, 1);
        out[0] = r.root;
        return out;
    }
};

const TradeRig = struct {
    fonts: ha.font.Fonts,
    res: res_mod.Resources,
    arena: std.heap.ArenaAllocator,
    ui: uic.UiCtx,
    driver: uic.FrameDriver,
    fx: TradeFixture = .{},

    fn setUp(self: *TradeRig) !void {
        try ha.sdl.ttf.init();
        self.fonts = try ha.font.Fonts.init(testing.allocator, "assets/fonts/JetBrainsMonoNL-Regular.ttf", style.default_font);
        self.res = uic.replay.headlessResources();
        self.res.platform.font = &self.fonts;
        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        self.ui = uic.UiCtx.init(&self.res, testing.allocator, self.arena.allocator());
        self.driver = uic.FrameDriver.init(&self.ui, &self.arena, testing.io, .none);
        self.fx = .{};
    }

    fn tearDown(self: *TradeRig) void {
        self.ui.deinit();
        self.arena.deinit();
        self.fonts.deinit();
        ha.sdl.ttf.quit();
    }

    /// Open the dialog in a `w` × 820 window and let it stamp.
    fn open(_: *TradeRig, r: *uic.Replay, w: f32) !void {
        try r.frame(&.{.{ .resize = .{ .logical_w = w, .logical_h = 820 } }});
        try r.idle(2);
    }

    /// Select lot `id` and run frames until the slip's geometry has settled.
    fn pick(self: *TradeRig, r: *uic.Replay, id: u32) !void {
        self.fx.st.selected = id;
        self.fx.st.lots = 1;
        try r.idle(3);
    }

    fn keyNamed(self: *TradeRig, name: []const u8) ?u64 {
        for (self.res.semantics.snapshot()) |n| {
            if (std.mem.eql(u8, n.labelText(), name)) return n.key;
        }
        return null;
    }

    fn rectNamed(self: *TradeRig, name: []const u8) !uic.Rect {
        const key = self.keyNamed(name) orelse return error.NoSuchControl;
        return self.ui.rectOf(key) orelse error.NotStamped;
    }

    fn nameOf(self: *TradeRig, key: u64) []const u8 {
        for (self.res.semantics.snapshot()) |n| {
            if (n.key == key) return n.labelText();
        }
        return "";
    }
};

/// The slip's call to action for lot `id`: pinned inside the slip, below the region, at the
/// slip's foot. Returns its rect.
fn expectPinned(rig: *TradeRig, r: *uic.Replay, id: u32, cta_name: []const u8) !uic.Rect {
    try rig.pick(r, id);
    const cta = try rig.rectNamed(cta_name);
    const slip = rig.ui.rectOf(rig.fx.slip) orelse return error.NotStamped;
    const region = rig.ui.rectOf(rig.fx.region) orelse return error.NotStamped;
    // Wholly inside the slip, its foot on the slip's bottom padding.
    try testing.expect(cta.y >= slip.y and cta.y + cta.h <= slip.y + slip.h);
    try testing.expectApproxEqAbs(slip.y + slip.h - 13, cta.y + cta.h, 0.5);
    // The region takes what the heading and the call to action leave: it ends one gap above it.
    try testing.expectApproxEqAbs(cta.y - 10, region.y + region.h, 0.5);
    return cta;
}

test "trade: the slip's call to action holds one place for a short, a tall, a refused and an overflowing lot" {
    var rig: TradeRig = undefined;
    try rig.setUp();
    defer rig.tearDown();
    var r = uic.Replay.init(&rig.driver, uic.replay.hostOf(TradeFixture, &rig.fx));
    try rig.open(&r, 900);

    const short = try expectPinned(&rig, &r, 1, "TRADE \u{2192}");
    const tall = try expectPinned(&rig, &r, 2, "TRADE \u{2192}");
    // The tallest authored slip fits its region: nothing scrolls.
    try testing.expectEqual(@as(?u64, null), rig.keyNamed("The deal"));
    const refused = try expectPinned(&rig, &r, 3, "CANNOT TRADE");
    const over = try expectPinned(&rig, &r, 4, "TRADE \u{2192}");
    // Past the region, the region scrolls (a focus stop) and the call to action stays put.
    try testing.expect(rig.keyNamed("The deal") != null);

    for ([_]uic.Rect{ tall, refused, over }) |c| {
        try testing.expectApproxEqAbs(short.y, c.y, 0.5);
        try testing.expectApproxEqAbs(short.h, c.h, 0.5);
    }
    // The slip is the body's height, whatever lot is chosen.
    const slip = rig.ui.rectOf(rig.fx.slip).?;
    try testing.expectApproxEqAbs(td.body_h, slip.h, 0.5);
}

test "trade: stacked, the 250px slip scrolls its terms and Tab still reaches the stepper and the call to action" {
    var rig: TradeRig = undefined;
    try rig.setUp();
    defer rig.tearDown();
    var r = uic.Replay.init(&rig.driver, uic.replay.hostOf(TradeFixture, &rig.fx));
    try rig.open(&r, 560);

    const short = try expectPinned(&rig, &r, 1, "TRADE \u{2192}");
    const refused = try expectPinned(&rig, &r, 3, "CANNOT TRADE");
    const tall = try expectPinned(&rig, &r, 2, "TRADE \u{2192}");
    const slip = rig.ui.rectOf(rig.fx.slip).?;
    try testing.expectApproxEqAbs(td.narrow_slip_h, slip.h, 0.5);
    for ([_]uic.Rect{ refused, tall }) |c| try testing.expectApproxEqAbs(short.y, c.y, 0.5);
    // The tall lot outgrows the stacked region: it scrolls, and the call to action is unmoved.
    try testing.expect(rig.keyNamed("The deal") != null);

    // Tab through the dialog on a lot of two (its stepper's + is live): the stepper inside the
    // scrolling region and the call to action are both stops.
    _ = try expectPinned(&rig, &r, 4, "TRADE \u{2192}");
    var saw_stepper = false;
    var saw_cta = false;
    for (0..16) |_| {
        try r.frame(&.{.{ .key_press = .{ .key = .tab } }});
        const fk = rig.ui.focusedKey() orelse continue;
        const name = rig.nameOf(fk);
        if (std.mem.eql(u8, name, "One lot more")) saw_stepper = true;
        if (std.mem.eql(u8, name, "TRADE \u{2192}")) saw_cta = true;
    }
    try testing.expect(saw_stepper);
    try testing.expect(saw_cta);
}
