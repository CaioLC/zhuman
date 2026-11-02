//! The `quotes` system: the one writer of `comp.Quotes`. For every agent it asks the gate rules
//! what each verb, recipe and generator would answer right now (`actions.quote`,
//! `capital.quote`, `capital.generator_quote`) and writes each standing into its slot, so the
//! ACTIONS tile, the BUILD row, the GENERATORS tile and a decider read the same answer. It runs
//! before `log` in each act's `handle` and `update` sets, after every writer of what a quote
//! reads (the ledger, the goods, the busy body, the condition band), so an intent applied while
//! the run is paused shows in the tiles the next frame. Running it again on an unchanged world
//! changes nothing.
//!
//! The handlers do not read the component: `begin` and `collect_generator` ask the rule again at
//! apply time, and the rule is the authority; the component is the tile's answer.

const std = @import("std");
const ecs = @import("../ecs.zig");
const comp = @import("../components.zig");
const res_mod = @import("../res.zig");
const roster = @import("../data/roster.zig");
const actions = @import("../rules/actions.zig");
const capital = @import("../rules/capital.zig");

const World = ecs.World;
const Entity = ecs.Entity;
const Catalog = roster.Catalog;
const Quotes = comp.Quotes;

pub fn quotes(
    w: *World,
    cat: *const Catalog,
    cfg: *const res_mod.Config,
    q: ecs.Query(.{ Entity, comp.Quotes }),
) void {
    var it = q.iter();
    while (it.next()) |entry| fill(w, entry[0], cat, cfg.*, entry[1]);
}

/// Write every slot of agent `e`'s quotes: the verbs the catalog has, then its goods; every slot
/// past the catalog's records is null.
pub fn fill(w: *const World, e: Entity, cat: *const Catalog, cfg: res_mod.Config, out: *Quotes) void {
    out.* = .{};
    for (0..cat.actions.len) |i| {
        const ai: u16 = @intCast(i);
        const vq = actions.quote(w, e, cat, cfg, ai) orelse continue;
        out.verbs[i] = .{
            .standing = vq.standing,
            .short = if (vq.short) |l| indexOf(vq.verb.input.slice(), l) else Quotes.none,
            .quality = vq.quality,
        };
    }
    for (cat.goods, 0..) |*rec, i| {
        const gi: u16 = @intCast(i);
        if (capital.quote(w, e, cat, gi)) |bq| out.builds[i] = .{
            .standing = bq.standing,
            .short = if (bq.short) |l| indexOf(rec.input, l) else Quotes.none,
            .count = bq.count,
            .reach = bq.reach,
        };
        if (capital.generator_quote(w, e, cat, cfg, gi)) |gq| out.generators[i] = .{
            .standing = gq.standing,
            .short = if (gq.short) |l| indexOf(rec.input, l) else Quotes.none,
            .progress = gq.progress,
            .total = gq.total,
        };
    }
}

/// The index of `line` in `lines`, matched by item and cadence; `none` when it is not there.
fn indexOf(lines: []const roster.Line, line: roster.Line) u8 {
    for (lines, 0..) |l, i| {
        if (l.per == line.per and std.mem.eql(u8, l.item, line.item)) return @intCast(i);
    }
    return Quotes.none;
}

// ============================ Tests ==========================================

const testing = std.testing;

fn rig() !res_mod.Resources {
    return .{ .catalog = try roster.load(testing.allocator, roster.shipped, null) };
}

test "quotes answers what the rules answer, slot by slot" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    var res = try rig();
    defer res.catalog.deinit();
    const cat = &res.catalog;
    const e = w.spawn(.{
        comp.Vigor{ .v = 10, .max = 10 },
        comp.InventoryFood{ .v = 0, .quality = 1, .spoils = 0 },
        comp.InventoryBiomass{ .v = 0 },
        comp.Goods{},
        comp.Generators{},
        comp.Granted{},
        comp.Condition{},
        comp.Quotes{},
    });
    const spear = cat.goodIndex("spear").?;
    const garden = cat.goodIndex("garden_bed").?;
    const hunt = cat.actionIndex("hunt").?;
    w.get(e, comp.Goods).?.count[spear] = 1; // the spear grants the hunt, whose bait is short
    w.get(e, comp.Goods).?.count[garden] = 1;

    ecs.run(&w, &res, quotes);
    const got = w.get(e, comp.Quotes).?;
    for (0..cat.actions.len) |i| {
        const want = actions.quote(&w, e, cat, res.config, @intCast(i));
        try testing.expectEqual(want == null, got.verbs[i] == null);
        if (want) |v| {
            try testing.expectEqual(v.standing, got.verbs[i].?.standing);
            try testing.expectEqual(v.quality, got.verbs[i].?.quality);
        }
    }
    for (0..cat.goods.len) |i| {
        const want = capital.quote(&w, e, cat, @intCast(i));
        try testing.expectEqual(want == null, got.builds[i] == null);
        if (want) |b| {
            try testing.expectEqual(b.standing, got.builds[i].?.standing);
            try testing.expectEqual(b.count, got.builds[i].?.count);
            try testing.expectEqual(b.reach, got.builds[i].?.reach);
        }
        try testing.expectEqual(capital.generator_quote(&w, e, cat, res.config, @intCast(i)) == null, got.generators[i] == null);
    }
    for (cat.actions.len..roster.max_actions) |i| try testing.expect(got.verbs[i] == null);

    // The short line is named by its index in the lines it indexes.
    const hunt_q = got.verbs[hunt].?;
    try testing.expectEqual(Quotes.VerbStanding.short, hunt_q.standing);
    const bait = actions.verbOf(&w, e, cat, hunt).?.input.slice()[hunt_q.short];
    try testing.expectEqualStrings("biomass", bait.item);
    const spear_q = got.builds[spear].?;
    try testing.expectEqual(Quotes.BuildStanding.short, spear_q.standing);
    try testing.expectEqualStrings("biomass", cat.goods[spear].input[spear_q.short].item);
    try testing.expectEqual(Quotes.GeneratorStanding.charging, got.generators[garden].?.standing);
}

test "quotes is idempotent: a second run on an unchanged world writes the same answers" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    var res = try rig();
    defer res.catalog.deinit();
    const e = w.spawn(.{
        comp.Vigor{ .v = 10, .max = 10 },
        comp.InventoryFood{ .v = 3, .quality = 1, .spoils = 0 },
        comp.InventoryBiomass{ .v = 7 },
        comp.Goods{},
        comp.Generators{},
        comp.Granted{},
        comp.Condition{},
        comp.Quotes{},
    });
    w.get(e, comp.Goods).?.count[res.catalog.goodIndex("hatchet").?] = 1;

    ecs.run(&w, &res, quotes);
    const once = w.get(e, comp.Quotes).?.*;
    ecs.run(&w, &res, quotes);
    try testing.expect(std.meta.eql(once, w.get(e, comp.Quotes).?.*));
}

test "Quotes stays small" {
    // The world holds every component's storage inline for its full entity capacity, so each
    // byte here is a kilobyte of world; the terms stay out of it (`actions.verbOf`).
    try testing.expect(@sizeOf(comp.Quotes) <= 6144);
}
