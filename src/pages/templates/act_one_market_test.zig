//! Act I's MARKET on the production page, headless through the replay rig, over a live world
//! and the real schedule. The page carries text, so the test opens the real font (SDL_ttf needs
//! no window) and builds the production page; synthetic clicks go through the router onto
//! controls' stamped geometry, found by their accessible names, and the simulation ticks between
//! frames, so an intent the page writes is applied before the next build reads the outcome.

const std = @import("std");
const ha = @import("ha");
const uic = ha.ui_client;
const style = uic.style;
const comp = ha.sim.comp;
const roster = ha.sim.data.roster;
const World = ha.sim.ecs.World;
const play_game = @import("../play_game.zig");
const mv = @import("./market_view.zig");

const testing = std.testing;

/// The page, opening on BUILD: ACTIONS draws its kind icons through the renderer, which the
/// headless rig does not have.
const PageFixture = struct {
    world: *const World,
    first: bool = true,

    pub fn build(self: *PageFixture, ctx: *uic.UiCtx) anyerror!uic.Trees {
        defer self.first = false;
        return play_game.ui_playgame(ctx, self.world, .{ .initial_view = if (self.first) 1 else null });
    }
};

fn control(res: *const ha.res.Resources, name: []const u8) ?uic.SemanticNode {
    for (res.semantics.snapshot()) |n| if (std.mem.eql(u8, n.labelText(), name)) return n;
    return null;
}

/// One frame of the page, then a tick of the simulation, as `main.zig` runs them.
fn step(r: *uic.Replay, w: *World, res: *ha.res.Resources, events: []const uic.replay.Event) !void {
    try r.frame(events);
    ha.sim.schedule.tick(w, &res.game);
}

/// Click the control named `name`, then let two frames apply and stamp what it changed.
fn clickNamed(r: *uic.Replay, ui: *uic.UiCtx, w: *World, res: *ha.res.Resources, name: []const u8) !void {
    const c = control(res, name) orelse {
        std.debug.print("no control named \"{s}\"\n", .{name});
        return error.NoSuchControl;
    };
    const rect = ui.rectOf(c.key) orelse return error.NotStamped;
    const x = rect.x + rect.w / 2;
    const y = rect.y + rect.h / 2;
    try step(r, w, res, &.{ .{ .pointer_press = .{ .x = x, .y = y } }, .{ .pointer_release = .{ .x = x, .y = y } } });
    try step(r, w, res, &.{});
    try step(r, w, res, &.{});
}

test "Act I MARKET is a focus view, and its INVENTORY posts a spare good's offer through the sim" {
    try ha.sdl.ttf.init();
    defer ha.sdl.ttf.quit();
    var fonts = try ha.font.Fonts.init(testing.allocator, "assets/fonts/JetBrainsMonoNL-Regular.ttf", style.default_font);
    defer fonts.deinit();
    var res = uic.replay.headlessResources();
    res.platform.font = &fonts;
    res.game.catalog = try roster.load(testing.allocator, roster.shipped, null);
    defer res.game.catalog.deinit();
    const cat = &res.game.catalog;
    res.game.states = .{ .current = .act_one };
    var w = try World.init(testing.allocator);
    defer w.deinit();

    // Two hatchets, one spare; one pair of sandals, none spare.
    const e = ha.sim.systems.run.spawn_player(&w, cat);
    w.get(e, comp.Goods).?.count[cat.goodIndex("hatchet").?] = 2;
    w.get(e, comp.Goods).?.count[cat.goodIndex("sandals").?] = 1;
    ha.sim.rules.capital.settle(&w, e, cat);
    // More lines than the log shows, so the log is a scroll stop the test can find by name.
    for (0..6) |_| res.game.sim.log.push(.normal, "You return with 3 food.");
    ha.sim.schedule.tick(&w, &res.game);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = uic.UiCtx.init(&res, testing.allocator, arena.allocator());
    defer ui.deinit();
    var driver = uic.FrameDriver.init(&ui, &arena, testing.io, .none);
    var fx = PageFixture{ .world = &w };
    var r = uic.Replay.init(&driver, uic.replay.hostOf(PageFixture, &fx));
    try step(&r, &w, &res, &.{.{ .resize = .{ .logical_w = 900, .logical_h = 820 } }});
    try step(&r, &w, &res, &.{});

    // BUILD: the strips, the log and the expanded Household.
    try testing.expect(control(&res, "TRADE \u{2192}") != null);
    try testing.expect(control(&res, "Event log") != null);
    try testing.expect((control(&res, "HOUSEHOLD") orelse return error.NoSuchControl).state.expanded);

    // MARKET: the strips and the log step aside and the Household collapses.
    try clickNamed(&r, &ui, &w, &res, "MARKET");
    try testing.expect(control(&res, "TRADE \u{2192}") == null);
    try testing.expect(control(&res, "Event log") == null);
    try testing.expect(!(control(&res, "HOUSEHOLD") orelse return error.NoSuchControl).state.expanded);
    try testing.expectEqualStrings("0 offers \u{00b7} 0 wants", try mv.standingLine(arena.allocator(), &res.game.sim.neighbours));

    // Opened again there, it stays open; BUILD kept its own memory; MARKET collapses on the
    // next entry.
    try clickNamed(&r, &ui, &w, &res, "HOUSEHOLD");
    try testing.expect((control(&res, "HOUSEHOLD") orelse return error.NoSuchControl).state.expanded);
    try clickNamed(&r, &ui, &w, &res, "BUILD");
    try testing.expect((control(&res, "HOUSEHOLD") orelse return error.NoSuchControl).state.expanded);
    try testing.expect(control(&res, "Event log") != null);
    try clickNamed(&r, &ui, &w, &res, "MARKET");
    try testing.expect(!(control(&res, "HOUSEHOLD") orelse return error.NoSuchControl).state.expanded);

    // INVENTORY: the spare hatchet steps up; the only pair of sandals and the larder do not.
    try clickNamed(&r, &ui, &w, &res, "Inventory");
    try testing.expect((control(&res, "More sandals") orelse return error.NoSuchControl).state.disabled);
    try testing.expect((control(&res, "More food") orelse return error.NoSuchControl).state.disabled);
    try testing.expect(!(control(&res, "More hatchet") orelse return error.NoSuchControl).state.disabled);
    try clickNamed(&r, &ui, &w, &res, "More hatchet");
    try testing.expectEqual(@as(u16, 1), res.game.sim.neighbours.act_one.of(.{ .good = cat.goodIndex("hatchet").? }));
    try testing.expectEqualStrings("1 offer \u{00b7} 0 wants", try mv.standingLine(arena.allocator(), &res.game.sim.neighbours));
    // Posted at the spare: it steps down, not up.
    try testing.expect((control(&res, "More hatchet") orelse return error.NoSuchControl).state.disabled);
    try testing.expect(!(control(&res, "Fewer hatchet") orelse return error.NoSuchControl).state.disabled);
}
