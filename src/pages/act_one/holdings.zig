//! `act_one/holdings` — Act I's content for the shared `holdings` rail template: the owned-good
//! roster, the MARGINS the goods have moved (verb energy, food quality and spoilage, the vigor
//! ceiling, trade stock), and the BODY projection (eating policy, larder coverage, recovery).
//! Pure projection over live state into the frame arena; it builds no nodes.

const std = @import("std");
const ha = @import("ha");

const comp = ha.comp;
const effects = ha.effects;
const roster = ha.roster;
const uic = ha.ui_client;
const World = ha.world.World;
const Entity = ha.world.Entity;

const t = @import("../templates/root.zig");
const Line = t.HoldingsLine;
const Sentence = t.HoldingsSentence;

/// Units beyond the first of every owned good — what a trader could take.
fn spareUnits(world: *World, e: Entity, cat: *const roster.Catalog) u32 {
    const goods = world.get(e, comp.Goods) orelse return 0;
    var spares: u32 = 0;
    for (cat.goods, 0..) |_, gi| spares += goods.count[gi] -| 1;
    return spares;
}

/// Project agent `e` into the rail's content for this frame.
pub fn content(ctx: *uic.UiCtx, world: *World, e: Entity) !t.HoldingsContent {
    const a = ctx.arena;
    const cat = &ctx.res.catalog;

    // --- roster: owned goods in roster order, keyed by id ---------------------------------
    var owned: std.ArrayList(Line) = .empty;
    var units: u32 = 0;
    if (world.get(e, comp.Goods)) |goods| {
        for (cat.goods, 0..) |rec, gi| {
            const n = goods.count[gi];
            if (n == 0) continue;
            units += n;
            const label = if (n > 1) try std.fmt.allocPrint(a, "{s} \u{00d7}{d}", .{ rec.name, n }) else rec.name;
            try owned.append(a, .{ .key = rec.id, .label = label, .value = rec.copy.short });
        }
    }

    // --- MARGINS ---------------------------------------------------------------------------
    var margins: std.ArrayList(Line) = .empty;
    if (world.get(e, comp.Goods)) |goods| {
        // One line per held verb whose price the goods have moved: `1.7e → 1.4e`.
        for (cat.actions, 0..) |rec, ai| {
            const live = effects.verb(cat, goods, ai) orelse continue;
            const base = rec.requires.energy;
            if (@abs(live.requires.energy - base) < 0.001) continue;
            try margins.append(a, .{
                .key = rec.id,
                .label = rec.name,
                .value = try std.fmt.allocPrint(a, "{d:.1}e \u{2192} {d:.1}e", .{ base, live.requires.energy }),
                .tone = if (live.requires.energy < base) .good else .danger,
            });
        }
    }
    if (world.get(e, comp.InventoryFood)) |food| {
        const q0 = ha.baselines.food_quality;
        if (food.quality != q0) try margins.append(a, .{
            .key = "quality",
            .label = "Food quality",
            .value = try std.fmt.allocPrint(a, "{d} \u{2192} {d}", .{ q0, food.quality }),
            .tone = if (food.quality > q0) .good else .danger,
        });
        const s0 = ha.baselines.food_spoils;
        try margins.append(a, .{
            .key = "spoilage",
            .label = "Food spoilage",
            .value = try std.fmt.allocPrint(a, "{d:.2} \u{2192} {d:.2}/day", .{ s0, food.spoils }),
            .tone = if (food.spoils < s0) .good else if (food.spoils > s0) .danger else .dim,
        });
    }
    if (world.get(e, comp.Vigor)) |vigor| try margins.append(a, .{
        .key = "vigor",
        .label = "Vigor ceiling",
        .value = try std.fmt.allocPrint(a, "{d:.0}", .{vigor.max}),
    });
    const spares = spareUnits(world, e, cat);
    try margins.append(a, .{
        .key = "trade",
        .label = "Trade stock",
        .value = try std.fmt.allocPrint(a, "{d} spare {s}", .{ spares, if (spares == 1) "unit" else "units" }),
    });

    var c = t.HoldingsContent{
        .count = try std.fmt.allocPrint(a, "{d} KINDS, {d}", .{ owned.items.len, units }),
        .roster = owned.items,
        .section_title = "MARGINS",
        .section = margins.items,
        .body = &.{},
    };

    // --- BODY ------------------------------------------------------------------------------
    const met = world.get(e, comp.Metabolism) orelse {
        c.body_note = "no body projection";
        return c;
    };
    const food = world.get(e, comp.InventoryFood) orelse return c;
    const vigor = world.get(e, comp.Vigor) orelse return c;
    var body: std.ArrayList(Sentence) = .empty;
    const rate = ctx.res.config.clampMetabolism(met.rate);
    try body.append(a, .{ .key = "policy", .prefix = "Eating ", .value = ha.eating.word(ha.eating.valueFromRate(rate)), .suffix = "." });

    const net = ha.systems.net_food_drawdown(met.base_rate, rate, 0);
    if (net <= 0.001) {
        try body.append(a, .{ .key = "coverage", .prefix = "Larder ", .value = "holds", .suffix = ".", .tone = .good });
    } else {
        const days = food.v / net;
        try body.append(a, .{
            .key = "coverage",
            .prefix = "Food lasts ",
            .value = try std.fmt.allocPrint(a, "{d:.1}d", .{days}),
            .suffix = ".",
            .tone = if (days < 2) .danger else .fg,
        });
    }

    const projection = ha.body.project(.{
        .food = food.v,
        .quality = food.quality,
        .vigor = vigor.v,
        .vigor_max = vigor.max,
        .base_rate = met.base_rate,
        .rate = rate,
        .vigor_per_food = ctx.res.config.vigor_per_food,
    });
    try body.append(a, switch (projection.recovery) {
        .at_ceiling => Sentence{ .key = "recovery", .prefix = "Vigor is ", .value = "full", .suffix = ".", .tone = .good },
        .no_food => Sentence{ .key = "recovery", .prefix = "Recovery: ", .value = "starving", .suffix = ".", .tone = .danger },
        .no_quality => Sentence{ .key = "recovery", .prefix = "Recovery: ", .value = "no vigor", .suffix = ".", .tone = .danger },
        .partial => |p| Sentence{ .key = "recovery", .prefix = "Can recover ", .value = try std.fmt.allocPrint(a, "+{d:.0} vigor", .{p.restored}), .suffix = ".", .tone = .warn },
        .recovering => |r| Sentence{ .key = "recovery", .prefix = "Full vigor in ", .value = try std.fmt.allocPrint(a, "{d:.1}d", .{r.days}), .suffix = "." },
    });
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
    var w = World.init();
    const e = w.spawn(.{comp.Goods{}});
    const goods = w.get(e, comp.Goods).?;
    goods.count[cat.goodIndex("sandals").?] = 3;
    try std.testing.expectEqual(@as(u32, 2), spareUnits(&w, e, &cat));
}
