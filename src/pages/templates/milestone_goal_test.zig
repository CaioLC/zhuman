//! The Shelter card headless through the replay rig, over a live world. The card carries text,
//! so the test opens the real font (SDL_ttf needs no window) and builds the real card the BUILD
//! list pins (`build_list.milestone_goal`); synthetic clicks go through the router onto the
//! CTA's stamped geometry, found by its accessible name. The simulation's side — the build
//! beginning — is the rule itself, called between frames.

const std = @import("std");
const ha = @import("ha");
const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const comp = ha.sim.comp;
const capital = ha.sim.rules.capital;
const roster = ha.sim.data.roster;
const build_list = @import("./build_list.zig");
const World = ha.sim.ecs.World;
const Entity = ha.sim.ecs.Entity;

const testing = std.testing;

/// The Shelter card alone, the width of the BUILD lane.
const ShelterFixture = struct {
    world: *const World,
    e: Entity,

    const words = build_list.MilestoneCopy{
        .which = .act_one,
        .kicker = "A PLACE FOR OTHERS",
        .copy = "",
        .explanation = "",
        .raising = "The Shelter is going up.",
        .waiting = "Everything is on hand; the Shelter waits for free hands.",
        .action = "RAISE SHELTER \u{2192}",
    };

    pub fn build(self: *ShelterFixture, ctx: *uic.UiCtx) anyerror!uic.Trees {
        const root = try el.root(ctx, "root");
        const lane = try root.box("lane", .{ .w = .{ .fixed = 608 }, .h = .fit_children, .flow = .{ .dir = .column } }, .{});
        try build_list.milestone_goal(lane, self.world, self.e, "goal", words);
        const out = try ctx.arena.alloc(*uic.Node, 1);
        out[0] = root.get();
        return out;
    }
};

/// The published control named `name`, or null.
fn controlNamed(res: *const ha.res.Resources, name: []const u8) ?uic.SemanticNode {
    for (res.semantics.snapshot()) |n| if (std.mem.eql(u8, n.labelText(), name)) return n;
    return null;
}

/// Write the agent's quotes, as the `quotes` system does each frame.
fn requote(w: *World, e: Entity, cat: *const roster.Catalog) void {
    ha.sim.systems.quotes.fill(w, e, cat, .{}, w.get(e, comp.Quotes).?);
}

fn click(r: *uic.Replay, x: f32, y: f32) !void {
    try r.frame(&.{ .{ .pointer_press = .{ .x = x, .y = y } }, .{ .pointer_release = .{ .x = x, .y = y } } });
}

test "the Shelter card: busy hands wait, a ready click writes BeginBuild, and raising its CTA is a disabled ■ BUILDING with the build's progress" {
    try ha.sdl.ttf.init();
    defer ha.sdl.ttf.quit();
    var fonts = try ha.font.Fonts.init(testing.allocator, "assets/fonts/JetBrainsMonoNL-Regular.ttf", style.default_font);
    defer fonts.deinit();
    var res = uic.replay.headlessResources();
    res.platform.font = &fonts;
    res.game.catalog = try roster.load(testing.allocator, roster.shipped, null);
    defer res.game.catalog.deinit();
    const cat = &res.game.catalog;
    var w = try World.init(testing.allocator);
    defer w.deinit();

    // A rested, stocked body owning five kinds, the rope bag and leaf bed among them, holding
    // the order.
    const e = ha.sim.systems.run.spawn_player(&w, cat);
    w.get(e, comp.Vigor).?.* = .{ .v = 15, .max = 15 };
    w.get(e, comp.InventoryFood).?.v = 16;
    w.get(e, comp.InventoryBiomass).?.v = 130;
    for ([_][]const u8{ "sandals", "rope_bag", "root_cellar", "leaf_bed", "wire_snares" }) |id| w.get(e, comp.Goods).?.count[cat.goodIndex(id).?] = 1;
    capital.settle(&w, e, cat);
    const shelter = cat.goodIndex("shelter").?;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = uic.UiCtx.init(&res, testing.allocator, arena.allocator());
    defer ui.deinit();
    var driver = uic.FrameDriver.init(&ui, &arena, testing.io, .none);
    var fx = ShelterFixture{ .world = &w, .e = e };
    var r = uic.Replay.init(&driver, uic.replay.hostOf(ShelterFixture, &fx));

    // The hands on a Spear: everything is on hand, so the card waits on them, not on inputs.
    const spear = cat.goodIndex("spear").?;
    w.add(e, comp.Busy{ .doing = .{ .build = spear }, .total = 10, .remaining = 5, .quality = 1 });
    requote(&w, e, cat);
    try testing.expectEqual(comp.Quotes.BuildStanding.busy, w.get(e, comp.Quotes).?.builds[shelter].?.standing);
    try r.idle(2);
    try testing.expect((controlNamed(&res, "HANDS BUSY") orelse return error.NoSuchControl).state.disabled);

    // Free hands: ready to raise.
    w.remove(e, comp.Busy);
    requote(&w, e, cat);
    try r.idle(1);
    const raise = controlNamed(&res, "RAISE SHELTER \u{2192}") orelse return error.NoSuchControl;
    try testing.expect(!raise.state.disabled);
    const rect = ui.rectOf(raise.key) orelse return error.NotStamped;
    const x = rect.x + rect.w / 2;
    const y = rect.y + rect.h / 2;
    try click(&r, x, y);
    try testing.expectEqual(@as(usize, 1), res.game.events.len(ha.sim.events.BeginBuild));

    // The simulation begins the build: the order is paid, the energy spent (vigor falls below
    // the Shelter's standing condition, which the build does not read again), and the hands
    // are on it.
    try testing.expectEqual(@as(?ha.sim.events.Refused.Reason, null), capital.begin(&w, e, &res.game, shelter));
    requote(&w, e, cat);
    try r.idle(1);
    try testing.expect(controlNamed(&res, "RAISE SHELTER \u{2192}") == null);
    const building = controlNamed(&res, "\u{25A0} BUILDING") orelse return error.NoSuchControl;
    try testing.expect(building.state.disabled);
    try testing.expectEqualStrings("0%", building.value.slice());

    // Half built, the CTA speaks the same progress its underbar fills to; a click on it writes
    // nothing.
    const busy = w.get(e, comp.Busy).?;
    busy.remaining = busy.total / 2;
    try r.idle(1);
    try testing.expectEqualStrings("50%", (controlNamed(&res, "\u{25A0} BUILDING") orelse return error.NoSuchControl).value.slice());
    try click(&r, x, y);
    try testing.expectEqual(@as(usize, 1), res.game.events.len(ha.sim.events.BeginBuild));
}
