//! `act_one/holdings` — Act I's content for the shared `holdings` rail template: the owned-good
//! roster, the MARGINS the goods have moved (verb energy, food quality and spoilage, the vigor
//! ceiling, trade stock), and the BODY lines (food days, recovery) from the agent's `Outlook`.
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

/// Units beyond the first of every owned good — what a trader could take.
fn spareUnits(world: *const World, e: Entity, cat: *const roster.Catalog) u32 {
    const goods = world.get(e, comp.Goods) orelse return 0;
    var spares: u32 = 0;
    for (cat.goods, 0..) |_, gi| spares += goods.count[gi] -| 1;
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
    if (world.get(e, comp.Goods)) |goods| {
        // One line per held verb whose price the goods have moved: `1.7e → 1.4e`.
        for (cat.actions, 0..) |rec, ai| {
            const live = effects.verb(cat, goods, ai) orelse continue;
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
            .value = try a.print("{d:.2} \u{2192} {d:.2}/day", .{ s0, food.spoils }),
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
