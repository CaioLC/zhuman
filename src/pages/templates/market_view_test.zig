//! The MARKET view headless through the replay rig, over the stand-in neighbour book. The view
//! carries text, so the test opens the real font (SDL_ttf needs no window) and builds the real
//! view; synthetic clicks go through the router onto controls' stamped geometry, found by their
//! accessible names. It walks THE DEAL's back button both ways: a deal opened from a good's
//! detail returns there, one opened from a person row closes.

const std = @import("std");
const ha = @import("ha");
const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const roster = ha.sim.data.roster;
const nb = ha.sim.rules.neighbours;
const mv = @import("./market_view.zig");

const testing = std.testing;

/// The view alone in a 900 × 640 box, as the Act II page hosts it.
const MarketFixture = struct {
    m: nb.Market = .{},
    st: uic.UiState.MarketState = .{},
    player: mv.Player,

    pub fn build(self: *MarketFixture, ctx: *uic.UiCtx) anyerror!uic.Trees {
        const root = try el.root(ctx, "root");
        const query_owner = try root.div("query");
        const stall_owner = try root.div("stall_query");
        const host = try root.box("host", .{ .w = .{ .fixed = 900 }, .h = .{ .fixed = 640 } }, .{});
        _ = try mv.market_view(host, "market", &self.m, &self.st, self.player, query_owner, stall_owner);
        const out = try ctx.arena.alloc(*uic.Node, 1);
        out[0] = root.get();
        return out;
    }
};

fn control(res: *const ha.res.Resources, name: []const u8) ?uic.SemanticNode {
    for (res.semantics.snapshot()) |n| if (std.mem.eql(u8, n.labelText(), name)) return n;
    return null;
}

/// Click the control named `name` and let the next frame stamp what the click changed.
fn clickNamed(r: *uic.Replay, ui: *uic.UiCtx, res: *const ha.res.Resources, name: []const u8) !void {
    const c = control(res, name) orelse {
        std.debug.print("no control named \"{s}\"\n", .{name});
        return error.NoSuchControl;
    };
    const rect = ui.rectOf(c.key) orelse return error.NotStamped;
    const x = rect.x + rect.w / 2;
    const y = rect.y + rect.h / 2;
    try r.frame(&.{ .{ .pointer_press = .{ .x = x, .y = y } }, .{ .pointer_release = .{ .x = x, .y = y } } });
    try r.idle(2);
}

test "market: THE DEAL's back returns to the good it was opened from, and closes a deal opened from a person" {
    try ha.sdl.ttf.init();
    defer ha.sdl.ttf.quit();
    var fonts = try ha.font.Fonts.init(testing.allocator, "assets/fonts/JetBrainsMonoNL-Regular.ttf", style.default_font);
    defer fonts.deinit();
    var res = uic.replay.headlessResources();
    res.platform.font = &fonts;
    res.game.catalog = try roster.load(testing.allocator, roster.shipped, null);
    defer res.game.catalog.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = uic.UiCtx.init(&res, testing.allocator, arena.allocator());
    defer ui.deinit();
    var driver = uic.FrameDriver.init(&ui, &arena, testing.io, .none);
    var fx = MarketFixture{ .player = .{ .trade = "forager", .held = @splat(0), .reserved = @splat(0), .coin = 40 } };
    fx.player.held[0] = 20;
    fx.player.held[5] = 30;
    fx.m.seed(24);
    fx.st.group = 2; // by good
    var r = uic.Replay.init(&driver, uic.replay.hostOf(MarketFixture, &fx));
    try r.frame(&.{.{ .resize = .{ .logical_w = 900, .logical_h = 820 } }});
    try r.idle(2);

    // The cheapest seller of food heads its detail's CHEAPEST SELLING.
    var cheapest: ?usize = null;
    for (fx.m.people(), 0..) |a, k| {
        if (a.sells[0] == 0) continue;
        if (cheapest == null or a.ask[0] < fx.m.agents[cheapest.?].ask[0]) cheapest = k;
    }
    const seller = fx.m.agents[cheapest.?];
    // The frame driver resets `arena` every frame, so the names the test holds live on the stack.
    var seller_buf: [64]u8 = undefined;
    const seller_line = try std.fmt.bufPrint(&seller_buf,"{s} {s} \u{00d7}{d}", .{ seller.firstName(), seller.lastName(), seller.sells[0] });

    // Open food's detail, then pick its cheapest seller: the deal opens with a way back to food,
    // and food's row stays chosen while it is open.
    try clickNamed(&r, &ui, &res, "food");
    try testing.expectEqual(@as(u8, 2), fx.st.pick_kind);
    try testing.expectEqual(@as(u8, 0), fx.st.pick);
    try testing.expect(control(&res, "Back to food") == null);
    try clickNamed(&r, &ui, &res, seller_line);
    try testing.expectEqual(@as(u8, 1), fx.st.pick_kind);
    try testing.expectEqual(@as(u8, @intCast(cheapest.?)), fx.st.pick);
    try testing.expectEqual(@as(?u8, 0), fx.st.from);
    try testing.expect(control(&res, "Back to food") != null);
    try testing.expect(control(&res, "Propose") != null);
    try testing.expect((control(&res, "food") orelse return error.NoSuchControl).state.selected);

    // Back: food's detail again, its names offered once more.
    try clickNamed(&r, &ui, &res, "Back to food");
    try testing.expectEqual(@as(u8, 2), fx.st.pick_kind);
    try testing.expectEqual(@as(u8, 0), fx.st.pick);
    try testing.expectEqual(@as(?u8, null), fx.st.from);
    try testing.expect(control(&res, "Back to food") == null);
    try testing.expect(control(&res, "Propose") == null);
    try testing.expect(control(&res, seller_line) != null);
    try testing.expect((control(&res, "food") orelse return error.NoSuchControl).state.selected);

    // With the deal open again, clicking food's highlighted row clears the pick.
    try clickNamed(&r, &ui, &res, seller_line);
    try testing.expectEqual(@as(u8, 1), fx.st.pick_kind);
    try clickNamed(&r, &ui, &res, "food");
    try testing.expectEqual(@as(u8, 0), fx.st.pick_kind);
    try testing.expectEqual(@as(?u8, null), fx.st.from);
    try testing.expect(!(control(&res, "food") orelse return error.NoSuchControl).state.selected);

    // By person: a deal opened from a person row has nothing to return to, so back closes it.
    try clickNamed(&r, &ui, &res, "PERSON");
    const first = fx.m.agents[0];
    var name_buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf,"{s} {s}", .{ first.firstName(), first.lastName() });
    try clickNamed(&r, &ui, &res, name);
    try testing.expectEqual(@as(u8, 1), fx.st.pick_kind);
    try testing.expectEqual(@as(u8, 0), fx.st.pick);
    try testing.expectEqual(@as(?u8, null), fx.st.from);
    try testing.expect(control(&res, "Propose") != null);
    try clickNamed(&r, &ui, &res, "Close the deal");
    try testing.expectEqual(@as(u8, 0), fx.st.pick_kind);
    try testing.expect(control(&res, "Close the deal") == null);
    try testing.expect(control(&res, "Propose") == null);
}

test "market: with no neighbours the view builds every mode, the player's own row in the list" {
    try ha.sdl.ttf.init();
    defer ha.sdl.ttf.quit();
    var fonts = try ha.font.Fonts.init(testing.allocator, "assets/fonts/JetBrainsMonoNL-Regular.ttf", style.default_font);
    defer fonts.deinit();
    var res = uic.replay.headlessResources();
    res.platform.font = &fonts;
    res.game.catalog = try roster.load(testing.allocator, roster.shipped, null);
    defer res.game.catalog.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = uic.UiCtx.init(&res, testing.allocator, arena.allocator());
    defer ui.deinit();
    var driver = uic.FrameDriver.init(&ui, &arena, testing.io, .none);
    var fx = MarketFixture{ .player = .{ .trade = "", .held = @splat(0), .reserved = @splat(0), .coin = 0 } };
    fx.player.held[0] = 11;
    fx.m.seed(0);
    // A deal left open on a neighbour the book does not have closes rather than reading it.
    fx.st.pick_kind = 1;
    fx.st.pick = 3;
    var r = uic.Replay.init(&driver, uic.replay.hostOf(MarketFixture, &fx));
    try r.frame(&.{.{ .resize = .{ .logical_w = 900, .logical_h = 820 } }});
    try r.idle(2);
    try testing.expectEqual(@as(u8, 0), fx.st.pick_kind);
    try testing.expect(control(&res, "Your inventory") != null);
    try clickNamed(&r, &ui, &res, "GOOD");
    try testing.expect(control(&res, "Your inventory") == null);
    try clickNamed(&r, &ui, &res, "Inventory");
    try testing.expect(fx.st.stall);
    try clickNamed(&r, &ui, &res, "WANTS");
    try testing.expectEqual(@as(u8, 1), fx.st.side);
}

test "market: the header counts every standing offer and want, singular at one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m: nb.Market = .{};
    m.seed(0);
    try testing.expectEqualStrings("0 offers \u{00b7} 0 wants", try mv.standingLine(a, &m));
    m.sell_posts[5] = .{ .qty = 2, .price = 4 };
    m.buy_posts[0] = .{ .qty = 1, .price = 5 };
    try testing.expectEqualStrings("1 offer \u{00b7} 1 want", try mv.standingLine(a, &m));
}

/// The view as Act I hosts it: the lone actor's inventory, its offers on the book's `act_one`,
/// and a stepped offer applied as the `PostOffer` handler would, capped at the spare.
const ActOneFixture = struct {
    m: nb.Market = .{},
    st: uic.UiState.MarketState = .{},
    own: []const mv.Own,

    pub fn build(self: *ActOneFixture, ctx: *uic.UiCtx) anyerror!uic.Trees {
        const root = try el.root(ctx, "root");
        const query_owner = try root.div("query");
        const stall_owner = try root.div("stall_query");
        const host = try root.box("host", .{ .w = .{ .fixed = 900 }, .h = .{ .fixed = 640 } }, .{});
        const player = mv.Player{ .trade = "", .held = @splat(0), .reserved = @splat(0), .coin = 0, .own = self.own };
        const r = try mv.market_view(host, "market", &self.m, &self.st, player, query_owner, stall_owner);
        if (r.offer) |o| for (self.own) |h| {
            if (std.meta.eql(h.item, o.item)) _ = self.m.act_one.post(o.item, o.qty, h.spare);
        };
        const out = try ctx.arena.alloc(*uic.Node, 1);
        out[0] = root.get();
        return out;
    }
};

test "market: Act I's INVENTORY steps a spare good's offer up, holds the rest, and shows no price" {
    try ha.sdl.ttf.init();
    defer ha.sdl.ttf.quit();
    var fonts = try ha.font.Fonts.init(testing.allocator, "assets/fonts/JetBrainsMonoNL-Regular.ttf", style.default_font);
    defer fonts.deinit();
    var res = uic.replay.headlessResources();
    res.platform.font = &fonts;
    res.game.catalog = try roster.load(testing.allocator, roster.shipped, null);
    defer res.game.catalog.deinit();
    const cat = &res.game.catalog;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = uic.UiCtx.init(&res, testing.allocator, arena.allocator());
    defer ui.deinit();
    var driver = uic.FrameDriver.init(&ui, &arena, testing.io, .none);
    const hatchet: nb.Holding = .{ .good = cat.goodIndex("hatchet").? };
    const own = [_]mv.Own{
        .{ .item = .food, .held = 11.6, .spare = 0 },
        .{ .item = .biomass, .held = 31, .spare = 0 },
        .{ .item = .{ .good = cat.goodIndex("sandals").? }, .held = 1, .spare = 0 },
        .{ .item = hatchet, .held = 2, .spare = 1 },
    };
    var fx = ActOneFixture{ .own = &own };
    var r = uic.Replay.init(&driver, uic.replay.hostOf(ActOneFixture, &fx));
    try r.frame(&.{.{ .resize = .{ .logical_w = 900, .logical_h = 820 } }});
    try r.idle(2);
    try testing.expectEqualStrings("0 offers \u{00b7} 0 wants", try mv.standingLine(arena.allocator(), &fx.m));
    try testing.expect(control(&res, "Your inventory") != null);

    try clickNamed(&r, &ui, &res, "Inventory");
    try testing.expect(fx.st.stall);
    // No PRICE column: no price stepper anywhere.
    try testing.expect(control(&res, "Raise price") == null);
    try testing.expect((control(&res, "More sandals") orelse return error.NoSuchControl).state.disabled);
    try testing.expect((control(&res, "More materials") orelse return error.NoSuchControl).state.disabled);
    try clickNamed(&r, &ui, &res, "More hatchet");
    try testing.expectEqual(@as(u16, 1), fx.m.act_one.of(hatchet));
    try testing.expectEqualStrings("1 offer \u{00b7} 0 wants", try mv.standingLine(arena.allocator(), &fx.m));
    try testing.expect((control(&res, "More hatchet") orelse return error.NoSuchControl).state.disabled);

    // WANTS: nobody offers anything to want.
    try clickNamed(&r, &ui, &res, "WANTS");
    try testing.expect(control(&res, "More hatchet") == null);

    // By good, the offered hatchet is a row of its own; picked, its detail opens.
    try clickNamed(&r, &ui, &res, "Inventory");
    try clickNamed(&r, &ui, &res, "GOOD");
    try clickNamed(&r, &ui, &res, "hatchet");
    try testing.expectEqual(@as(u8, 2), fx.st.pick_kind);
    try testing.expectEqual(@as(u8, @intCast(hatchet.key())), fx.st.pick);
}
