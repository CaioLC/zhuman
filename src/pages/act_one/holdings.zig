//! `act_one/holdings` — Act I's content for the shared `holdings` rail template: the owned-good
//! roster, the MARGINS the goods have moved (verb energy, food quality and spoilage, the vigor
//! ceiling, trade stock), and the BODY lines (food days, recovery, work pace) from the agent's
//! `Outlook`.
//! Pure projection over live state into the frame arena; it builds no nodes.

const std = @import("std");
const ha = @import("ha");

const comp = ha.sim.comp;
const effects = ha.sim.rules.effects;
const roster = ha.sim.data.roster;
const uic = ha.ui_client;
const vd = uic.style.verdict;
const World = ha.sim.ecs.World;
const Entity = ha.sim.ecs.Entity;

const t = @import("../templates/root.zig");
const Line = t.HoldingsLine;
const Sentence = t.HoldingsSentence;

/// Units beyond the first of every owned good — what a trader could take, and what the MARKET's
/// INVENTORY may offer (`neighbours.spareOf`).
fn spareUnits(world: *const World, e: Entity, cat: *const roster.Catalog) u32 {
    var spares: u32 = 0;
    for (cat.goods, 0..) |_, gi| spares += @intFromFloat(ha.sim.systems.neighbours.spareOf(world, e, .{ .good = @intCast(gi) }));
    return spares;
}

/// Project agent `e` into the rail's content for this frame.
pub fn content(ctx: *uic.UiCtx, world: *const World, e: Entity) !t.HoldingsContent {
    const a = ctx.arena;
    const cat = &ctx.res.game.catalog;

    // --- roster: owned goods in roster order, keyed by id ---------------------------------
    var owned: std.ArrayList(Line) = .empty;
    var units: u32 = 0;
    if (world.get(e, comp.Goods)) |goods| {
        for (cat.goods, 0..) |rec, gi| {
            const n = goods.count[gi];
            if (n == 0) continue;
            units += n;
            const label = if (n > 1) try a.print("{s} \u{00d7}{d}", .{ rec.name, n }) else rec.name;
            try owned.append(a, .{ .key = rec.id, .label = label, .value = rec.copy.short });
        }
    }

    // --- MARGINS ---------------------------------------------------------------------------
    var margins: std.ArrayList(Line) = .empty;
    if (effects.holdingsOf(world, e)) |h| {
        // One line per held verb whose price the goods have moved: `1.7e → 1.4e`.
        for (cat.actions, 0..) |rec, ai| {
            const live = effects.verb(cat, h, ai) orelse continue;
            const base = rec.requires.energy;
            // A lower energy cost is the better margin; an unmoved one shows no line.
            const moved = vd.margin(live.requires.energy, base, .lower);
            if (moved == .flat) continue;
            try margins.append(a, .{
                .key = rec.id,
                .label = rec.name,
                .value = try a.print("{d:.1}e \u{2192} {d:.1}e", .{ base, live.requires.energy }),
                .verdict = moved,
            });
        }
    }
    if (world.get(e, comp.InventoryFood)) |food| {
        const q0 = ha.sim.baselines.food_quality;
        if (food.quality != q0) try margins.append(a, .{
            .key = "quality",
            .label = "Food quality",
            .value = try a.print("{d} \u{2192} {d}", .{ q0, food.quality }),
            .verdict = vd.margin(@floatFromInt(food.quality), @floatFromInt(q0), .higher),
        });
        const s0 = ha.sim.baselines.food_spoils;
        try margins.append(a, .{
            .key = "spoilage",
            .label = "Food spoilage",
            .value = try a.print("{d:.0}% \u{2192} {d:.0}%/day", .{ s0 * 100, food.spoils * 100 }),
            .verdict = vd.margin(food.spoils, s0, .lower),
        });
    }
    if (world.get(e, comp.Vigor)) |vigor| try margins.append(a, .{
        .key = "vigor",
        .label = "Vigor ceiling",
        .value = try a.print("{d:.0}", .{vigor.max}),
    });
    const spares = spareUnits(world, e, cat);
    try margins.append(a, .{
        .key = "trade",
        .label = "Trade stock",
        .value = try a.print("{d} spare {s}", .{ spares, if (spares == 1) "unit" else "units" }),
    });

    var c = t.HoldingsContent{
        .count = try a.print("{d} KINDS, {d}", .{ owned.items.len, units }),
        .roster = owned.items,
        .section_title = "MARGINS",
        .section = margins.items,
        .body = &.{},
    };

    // --- BODY ------------------------------------------------------------------------------
    // The `outlook` system's projection at the eating policy's rate; the policy reads its own
    // word under BODY, so the body names only what it moves.
    const outlook = world.get(e, comp.Outlook) orelse {
        c.body_note = "no body projection";
        return c;
    };
    var body: std.ArrayList(Sentence) = .empty;
    try body.append(a, .{
        .key = "coverage",
        .prefix = "Food lasts ",
        .value = try a.print("{d:.1}d", .{outlook.food_days}),
        .suffix = ".",
        .verdict = vd.when(outlook.food_days < 2, .low),
    });
    try body.append(a, switch (outlook.recovery) {
        .at_ceiling => Sentence{ .key = "recovery", .prefix = "Vigor is ", .value = "full", .suffix = ".", .tone = .good },
        .no_food => Sentence{ .key = "recovery", .prefix = "Recovery: ", .value = "starving", .suffix = ".", .tone = .danger },
        .no_quality => Sentence{ .key = "recovery", .prefix = "Recovery: ", .value = "no vigor", .suffix = ".", .tone = .danger },
        .partial => |p| Sentence{ .key = "recovery", .prefix = "Can recover ", .value = try a.print("+{d:.0} vigor", .{p.restored}), .suffix = ".", .tone = .warn },
        .recovering => |r| Sentence{ .key = "recovery", .prefix = "Full vigor in ", .value = try a.print("{d:.1}d", .{r.days}), .suffix = "." },
    });
    // The pace the body works at on this ration, as a whole percentage of the normal ration's.
    const pace_pct: i32 = @intFromFloat(@round(outlook.pace * 100));
    try body.append(a, .{ .key = "pace", .prefix = "Work pace ", .value = try a.print("{d}%", .{pace_pct}), .suffix = "." });
    c.body = body.items;
    return c;
}

test "every buildable good carries the rail's compact copy" {
    var cat = try roster.load(std.testing.allocator, roster.shipped, null);
    defer cat.deinit();
    for (cat.goods) |g| {
        if (g.buildable) try std.testing.expect(g.copy.short.len > 0);
    }
    try std.testing.expectEqualStrings("forage costs less", cat.good("sandals").?.copy.short);
    try std.testing.expectEqualStrings("food keeps 2\u{00d7}", cat.good("root_cellar").?.copy.short);
}

test "spare goods feed the trade-stock margin" {
    var cat = try roster.load(std.testing.allocator, roster.shipped, null);
    defer cat.deinit();
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    const e = w.spawn(.{comp.Goods{}});
    const goods = w.get(e, comp.Goods).?;
    goods.count[cat.goodIndex("sandals").?] = 3;
    try std.testing.expectEqual(@as(u32, 2), spareUnits(&w, e, &cat));
}

test "BODY ends on the work pace: 100% at the normal ration, the slowest pace's share unfed" {
    var res = uic.replay.headlessResources();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = uic.UiCtx.init(&res, std.testing.allocator, arena.allocator());
    defer ctx.deinit();
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    const e = w.spawn(.{comp.Outlook{ .food_days = 5.2, .recovery = .{ .recovering = .{ .days = 0.4 } }, .pace = 1 }});

    var c = try content(&ctx, &w, e);
    try std.testing.expectEqual(@as(usize, 3), c.body.len);
    const last = c.body[c.body.len - 1];
    try std.testing.expectEqualStrings("pace", last.key);
    try std.testing.expectEqualStrings("Work pace ", last.prefix);
    try std.testing.expectEqualStrings("100%", last.value);
    try std.testing.expectEqualStrings(".", last.suffix);
    // The neutral value ink of "Food lasts 5.2d.", with no verdict.
    try std.testing.expect(last.tone == .fg and last.verdict == null);

    const cfg = res.game.config;
    w.get(e, comp.Outlook).?.pace = cfg.pace(1.0, 1, false);
    c = try content(&ctx, &w, e);
    const slowest = try std.fmt.allocPrint(arena.allocator(), "{d}%", .{@as(i32, @intFromFloat(@round(cfg.pace(cfg.metabolism_rate_min, 1, true) * 100)))});
    try std.testing.expectEqualStrings(slowest, c.body[c.body.len - 1].value);
    try std.testing.expectEqualStrings("69%", c.body[c.body.len - 1].value);
}

test "BODY with no projection carries no lines, the pace among them" {
    var res = uic.replay.headlessResources();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = uic.UiCtx.init(&res, std.testing.allocator, arena.allocator());
    defer ctx.deinit();
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    const e = w.spawn(.{comp.Goods{}});
    const c = try content(&ctx, &w, e);
    try std.testing.expectEqual(@as(usize, 0), c.body.len);
    try std.testing.expectEqualStrings("no body projection", c.body_note.?);
}
