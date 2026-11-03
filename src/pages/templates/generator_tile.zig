//! `generator_tile` — one owned generator as an action-like tile: its name (the generator's
//! label when it has one), a state line (accumulating, off, ready — collect, needs vigor, needs
//! input), the cycle's cost, duration and yield, the underbar filling while it accumulates, and
//! a mode corner in the lower right that cycles the generator on (accumulates and waits to be
//! collected), auto (collects itself) and off (paused, progress kept).
//!
//! A click on the ready tile writes `CollectGenerator`; a click on the corner writes
//! `ToggleGenerator` and never collects. Readiness and progress come from the agent's
//! `comp.Quotes`, cost and output from the record's generator. At the compact density the
//! state word rides the name row and the tile stands at verb height.

const std = @import("std");
const ha = @import("ha");

const comp = ha.sim.comp;
const roster = ha.sim.data.roster;
const World = ha.sim.ecs.World;
const Entity = ha.sim.ecs.Entity;

const uic = ha.ui_client;
const style = uic.style;
const Style = style.Style;
const El = uic.elements.El;

const action_tile = @import("./action_tile.zig");
const info = @import("./action_info.zig");
const fmt = @import("../fmt.zig");

/// A cycle's length in days.
fn cycleDays(spec: roster.Generator) f32 {
    return spec.hours / 24.0;
}

fn cycleCost(act: u8, buf: []u8, rec: *const roster.Good, spec: roster.Generator) []const u8 {
    var wr = std.Io.Writer.fixed(buf);
    var ebuf: [8]u8 = undefined;
    wr.print("\u{2212}{s}e", .{fmt.fmt_amount(&ebuf, spec.energy)}) catch {};
    for (rec.input) |line| {
        if (line.per != .day) continue;
        var nbuf: [8]u8 = undefined;
        wr.print(" \u{2212}{s}{s}", .{ fmt.fmt_amount(&nbuf, line.n * cycleDays(spec)), info.letterOf(act, line.item) }) catch {};
    }
    return wr.buffered();
}

const Yield = struct {
    kind: ha.sim.kernel.dist.Kind = .fixed,
    text: []const u8,
};

fn cycleYield(act: u8, buf: []u8, rec: *const roster.Good, spec: roster.Generator) Yield {
    const cycle_days = cycleDays(spec);
    var best: ?roster.Line = null;
    var best_mean: f32 = -1;
    for (rec.output) |line| {
        if (line.per != .day) continue;
        const mean = ha.sim.kernel.dist.stats(line.asDist()).mean * cycle_days;
        if (mean > best_mean) {
            best = line;
            best_mean = mean;
        }
    }
    if (best) |line| {
        const stats = ha.sim.kernel.dist.stats(line.asDist());
        const lo = @round(stats.p10 * cycle_days);
        const hi = @round(stats.p90 * cycle_days);
        const text = if (lo == hi)
            std.mem.print(buf, "+{d:.0}{s}", .{ hi, info.letterOf(act, line.item) }) catch "+?"
        else
            std.mem.print(buf, "+{d:.0}\u{2013}{d:.0}{s}", .{ lo, hi, info.letterOf(act, line.item) }) catch "+?";
        return .{ .kind = line.kind, .text = text };
    }
    return .{ .text = std.mem.print(buf, "+{d:.1}v", .{spec.vigor}) catch "+?v" };
}

fn stateWord(q: comp.Quotes.Generator) []const u8 {
    return switch (q.standing) {
        .charging => "accumulating",
        .off => "off",
        .ready => "ready — collect",
        .energy => "needs vigor",
        .short => "needs input",
    };
}

/// Build the tile for owned generator `gi` into `parent`, keyed by the good's id. `act` picks
/// the item letters of the cost and yield.
pub fn generatorTile(parent: El, world: *const World, e: Entity, act: u8, gi: u16, density: action_tile.Density) !void {
    const ctx = parent.ctx;
    const cat = &ctx.res.game.catalog;
    const rec = &cat.goods[gi];
    const spec = rec.generator orelse return;
    const quotes = world.get(e, comp.Quotes) orelse return;
    const q = quotes.generators[gi] orelse return;

    var cost_buf: [40]u8 = undefined;
    var duration_buf: [12]u8 = undefined;
    var yield_buf: [20]u8 = undefined;
    const duration = std.mem.print(&duration_buf, "{d:.0}h", .{spec.hours}) catch "?";
    const yield = cycleYield(act, &yield_buf, rec, spec);
    const progress: ?f32 = if (q.standing == .charging) q.fraction() else null;
    const display_name = if (spec.label.len > 0) spec.label else rec.name;
    const tile = try action_tile.tile(
        parent,
        rec.id,
        display_name,
        stateWord(q),
        cycleCost(act, &cost_buf, rec, spec),
        duration,
        yield.kind,
        yield.text,
        q.ready(),
        progress,
        density,
    );
    // A regular tile stands as tall as the prototype's (`min-height: 82px` plus the state
    // line: 87px outer); a compact one, its state on the name row, as tall as a compact verb.
    tile.el.set(.{
        .w = .{ .pct_of_parent = 1.0 },
        .h = .{ .fixed = if (density == .regular) generator_regular_h else action_tile.height(.compact) },
        .flow = .{ .dir = .column, .main = .center },
    }, .{});

    // Nested control, anchored out of flow in the lower-right corner so it never grows the tile.
    // Right/bottom padding mirror the tile's inner padding (12 x 6 regular, 8 x 5 compact, with
    // the box's 1px bottom inset), aligning the label with the content edge. Pointer hit testing
    // targets this topmost child, but its click (and Enter/Space on its focus) still bubbles to
    // the tile, which ran its lifecycle first; `toggleAndCollect` resolves the two in order.
    const toggle = try tile.el.box("toggle", .{
        .anchor = .bottom_right, .w = .fit_children, .h = .fit_children, .flow = .{ .dir = .row },
    }, .{if (density == .compact) style.pad_each(8, 8, 4, 5) else style.pad_each(12, 12, 5, 6)});
    const mode = toggleAndCollect(tile.el, toggle, world, e, gi, display_name);
    const size: Style = if (density == .compact) .{ .font = 10 } else style.small;
    try toggle.label("label", mode_labels.get(mode), .{ size, mode_inks.get(mode) });
}

/// The mode corner's text per mode.
pub const mode_labels = std.EnumArray(comp.Generators.Mode, []const u8).init(.{
    .on = "\u{25CF} ON",
    .auto = "\u{25C9} AUTO",
    .off = "\u{25CB} OFF",
});

/// The mode corner's inks: ON good, AUTO fg, OFF dim at rest; accent while hot in every mode.
pub const mode_inks = std.EnumArray(comp.Generators.Mode, Style).init(.{
    .on = .{ .ink = .good, .on = &.{.{ .when = .hot, .ink = .acc }} },
    .auto = .{ .ink = .fg, .on = &.{.{ .when = .hot, .ink = .acc }} },
    .off = .{ .ink = .dim, .on = &.{.{ .when = .hot, .ink = .acc }} },
});

/// Resolve one generator tile's activations once the tile (`action_tile.tile`, built and
/// lifecycle-run before this child existed) and its mode corner `toggle` stand. A click on the
/// toggle, a pointer release or Enter/Space on its focus, is routed to the toggle and bubbles
/// to the tile, so:
///
/// - the toggle writes `ToggleGenerator` on the click and reads the mode that intent asks for
///   (`Mode.next`) before its lifecycle publishes, so the accessible name and the label (from
///   the returned mode) are current on the click frame, as `tabs` and `rail` do; the handler
///   applies it before the next build;
/// - the flip is gated by the same `enabled` the lifecycle receives, so a click the lifecycle
///   would consume as disabled can never flip it;
/// - the toggle then consumes its click, and the tile is re-queried after it, as
///   `capital_row` does: only a click on the tile body writes `CollectGenerator`.
///
/// The corner is a button named for the generator and its mode (`Garden bed generator · auto`):
/// a three-way cycle has no `checked` to publish. Returns the mode after this frame's activation.
fn toggleAndCollect(tile: El, toggle: El, world: *const World, e: Entity, gi: u16, display_name: []const u8) comp.Generators.Mode {
    const ctx = toggle.ctx;
    // A generator can always be paused or resumed. The flip and the lifecycle share this gate.
    const enabled = true;
    const flip = enabled and toggle.query().clicked;
    if (flip) _ = ctx.res.game.events.writer(ha.sim.events.ToggleGenerator).push(.{ .agent = e, .gi = gi });
    const was = world.get(e, comp.Generators).?.mode[gi];
    const mode = if (flip) was.next() else was;
    const q = toggle.control(.{
        .enabled = enabled,
        .name = ctx.arena.print("{s} generator \u{00B7} {s}", .{ display_name, @tagName(mode) }) catch display_name,
        .role = .button,
        .ring = false, // the mode label lifts to accent
    });
    // The flip read exactly the activation the lifecycle reports.
    std.debug.assert(q.clicked == flip);
    _ = toggle.consume(.clicked);
    // The tile's lifecycle gated its own click on readiness (a disabled tile consumed it);
    // read it again now that the toggle has taken its click.
    if (tile.query().clicked) _ = ctx.res.game.events.writer(ha.sim.events.CollectGenerator).push(.{ .agent = e, .gi = gi });
    return mode;
}

/// A regular generator tile's outer height (border included), logical px.
pub const generator_regular_h: f32 = 87;

// --- Tests: the toggle and the tile's collect, headless ---------------------------------------
// The headless replay rig has no font, so it cannot build the real tile's labels. The fixture
// stands in boxes for the tile and the toggle, runs the tile's lifecycle as `action_tile.tile`
// does (enabled while the generator is ready, before its toggle exists), then the real
// `toggleAndCollect` against a real world: synthetic pointer and keyboard input go through the
// router, hit testing and bubbling on stamped geometry.

const testing = std.testing;
const UiCtx = uic.UiCtx;
const Node = uic.Node;
const el = uic.elements;

const GenRig = struct {
    res: ha.res.Resources,
    arena: std.heap.ArenaAllocator,
    ui: UiCtx,
    driver: uic.FrameDriver,
    world: World,

    fn setUp(self: *GenRig) !void {
        self.res = uic.replay.headlessResources();
        self.res.game.catalog = try roster.load(testing.allocator, roster.shipped, null);
        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        self.ui = UiCtx.init(&self.res, testing.allocator, self.arena.allocator());
        self.driver = uic.FrameDriver.init(&self.ui, &self.arena, testing.io, .none);
        self.world = try World.init(testing.allocator);
    }

    fn tearDown(self: *GenRig) void {
        self.world.deinit();
        self.ui.deinit();
        self.arena.deinit();
        self.res.game.catalog.deinit();
    }

    /// An agent owning one garden bed whose cycle is complete: ready to collect.
    fn gardener(self: *GenRig) GenFixture {
        const e = self.world.spawn(.{
            comp.Vigor{ .v = 10, .max = 10 },
            comp.InventoryFood{ .v = 0, .quality = 1, .spoils = 0 },
            comp.InventoryBiomass{ .v = 10 },
            comp.Goods{},
            comp.Generators{},
            comp.Granted{},
            comp.Condition{},
            comp.Quotes{},
        });
        const gi: u16 = @intCast(self.res.game.catalog.goodIndex("garden_bed").?);
        self.world.get(e, comp.Goods).?.count[gi] = 1;
        self.world.get(e, comp.Generators).?.progress[gi] = 1e9;
        ha.sim.ecs.run(&self.world, &self.res.game, ha.sim.systems.quotes.quotes);
        return .{ .world = &self.world, .e = e, .gi = gi };
    }
};

/// A 300x87 tile at the origin with its toggle in the lower-right 60x27 corner.
const GenFixture = struct {
    world: *World,
    e: Entity,
    gi: u16,
    tile_key: u64 = 0,
    toggle_key: u64 = 0,
    /// The mode `toggleAndCollect` returned, the one the corner's label reads.
    shown: comp.Generators.Mode = .on,
    /// The click the tile's own lifecycle reported (before its toggle was built).
    tile_lifecycle_click: bool = false,
    /// The tile's click once the toggle resolved, the one that decides a collect.
    tile_collect_click: bool = false,

    fn place(parent: El, id: []const u8, x: f32, y: f32, w: f32, h: f32) !El {
        return (try parent.div(id))
            .with_layout(.top_left)
            .with_offset(x, y)
            .with_size(.{ .fixed = w }, .{ .fixed = h });
    }

    pub fn build(self: *GenFixture, ctx: *UiCtx) anyerror!uic.Trees {
        const root = try el.root(ctx, "root");
        const tile = try place(root, "tile", 0, 0, 300, 87);
        const ready = self.world.get(self.e, comp.Quotes).?.generators[self.gi].?.ready();
        self.tile_lifecycle_click = tile.control(.{ .enabled = ready, .name = "Garden bed", .role = .tile }).clicked;
        const toggle = try place(tile, "toggle", 240, 60, 60, 27);
        self.shown = toggleAndCollect(tile, toggle, self.world, self.e, self.gi, "Garden bed");
        self.tile_collect_click = tile.query().clicked;
        self.tile_key = tile.get().key;
        self.toggle_key = toggle.get().key;
        // The next frame's handler stage, as the host runs it between builds, so a test reads
        // the world the next build sees.
        ctx.res.game.events.update();
        ha.sim.ecs.run(self.world, &ctx.res.game, ha.sim.systems.generators.generators_toggle);
        ha.sim.ecs.run(self.world, &ctx.res.game, ha.sim.systems.generators.generators_collect);
        ha.sim.ecs.run(self.world, &ctx.res.game, ha.sim.systems.quotes.quotes);
        const out = try ctx.arena.alloc(*Node, 1);
        out[0] = root.get();
        return out;
    }

    fn mode(self: *const GenFixture) comp.Generators.Mode {
        return self.world.get(self.e, comp.Generators).?.mode[self.gi];
    }

    /// A collect restarts the cycle; an uncollected bed keeps its full progress.
    fn collected(self: *const GenFixture) bool {
        return self.world.get(self.e, comp.Generators).?.progress[self.gi] == 0;
    }
};

fn genClick(r: *uic.Replay, x: f32, y: f32) !void {
    try r.frame(&.{ .{ .pointer_press = .{ .x = x, .y = y } }, .{ .pointer_release = .{ .x = x, .y = y } } });
}

test "generator: a pointer click on the toggle toggles once and does not collect" {
    var rig: GenRig = undefined;
    try rig.setUp();
    defer rig.tearDown();
    var fx = rig.gardener();
    var r = uic.Replay.init(&rig.driver, uic.replay.hostOf(GenFixture, &fx));
    try r.idle(1);

    try genClick(&r, 270, 73);
    try testing.expect(fx.mode() == .auto and fx.shown == .auto);
    // The click reached the ready tile's lifecycle by bubbling; the toggle took it back first.
    try testing.expect(fx.tile_lifecycle_click);
    try testing.expect(!fx.tile_collect_click);
    try testing.expect(!fx.collected());
    try testing.expectEqual(@as(?u64, fx.toggle_key), rig.ui.focusedKey());

    // The next click turns it off, the one after back on (a full cycle is ready again); none
    // collects.
    try genClick(&r, 270, 73);
    try testing.expect(fx.mode() == .off and fx.shown == .off);
    try genClick(&r, 270, 73);
    try testing.expect(fx.mode() == .on and fx.shown == .on);
    try testing.expect(!fx.collected());
    try r.idle(1);
    try testing.expect(fx.mode() == .on and !fx.collected()); // exactly once per click
}

test "generator: a pointer click on the tile body collects and does not toggle" {
    var rig: GenRig = undefined;
    try rig.setUp();
    defer rig.tearDown();
    var fx = rig.gardener();
    var r = uic.Replay.init(&rig.driver, uic.replay.hostOf(GenFixture, &fx));
    try r.idle(1);

    try genClick(&r, 50, 30);
    try testing.expect(fx.tile_collect_click);
    try testing.expect(fx.collected());
    try testing.expect(fx.mode() == .on and fx.shown == .on);
    try testing.expect(rig.world.get(fx.e, comp.InventoryFood).?.v > 0);
}

test "generator: Tab to the toggle and Enter toggles it and does not collect" {
    var rig: GenRig = undefined;
    try rig.setUp();
    defer rig.tearDown();
    var fx = rig.gardener();
    var r = uic.Replay.init(&rig.driver, uic.replay.hostOf(GenFixture, &fx));
    try r.idle(1);

    // The ready tile is the first stop, the toggle the second.
    try r.frame(&.{.{ .key_press = .{ .key = .tab } }});
    try testing.expectEqual(@as(?u64, fx.tile_key), rig.ui.focusedKey());
    try r.frame(&.{.{ .key_press = .{ .key = .tab } }});
    try testing.expectEqual(@as(?u64, fx.toggle_key), rig.ui.focusedKey());

    try r.frame(&.{.{ .key_press = .{ .key = .return_key } }});
    try testing.expect(fx.mode() == .auto and fx.shown == .auto);
    try testing.expect(fx.tile_lifecycle_click and !fx.tile_collect_click);
    try testing.expect(!fx.collected());
    try testing.expectEqual(@as(?u64, fx.toggle_key), rig.ui.focusedKey());

    // Space as well: off, still uncollected, focus kept.
    try r.frame(&.{.{ .key_press = .{ .key = .space } }});
    try testing.expect(fx.mode() == .off and fx.shown == .off and !fx.collected());
    try testing.expectEqual(@as(?u64, fx.toggle_key), rig.ui.focusedKey());
}

test "generator: the published name carries the mode the label shows on the toggle frame" {
    var rig: GenRig = undefined;
    try rig.setUp();
    defer rig.tearDown();
    var fx = rig.gardener();
    var r = uic.Replay.init(&rig.driver, uic.replay.hostOf(GenFixture, &fx));
    try r.idle(1);
    {
        const n = rig.res.semantics.find(fx.toggle_key).?;
        try testing.expect(fx.shown == .on);
        try testing.expectEqual(uic.SemanticRole.button, n.role);
        try testing.expectEqualStrings("Garden bed generator \u{00B7} on", n.label.slice());
    }

    // The label reads `fx.shown`; the snapshot published on the same frame agrees with it, and
    // a three-way cycle publishes no `checked`.
    const want = [_]struct { comp.Generators.Mode, []const u8 }{
        .{ .auto, "Garden bed generator \u{00B7} auto" },
        .{ .off, "Garden bed generator \u{00B7} off" },
        .{ .on, "Garden bed generator \u{00B7} on" },
    };
    for (want) |w| {
        try genClick(&r, 270, 73);
        const n = rig.res.semantics.find(fx.toggle_key).?;
        try testing.expect(fx.shown == w[0]);
        try testing.expectEqualStrings(w[1], n.label.slice());
        try testing.expect(!n.state.checked and !rig.ui.interactionOf(fx.toggle_key).checked);
    }
}
