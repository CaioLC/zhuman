//! The debug poke handler: the template audit harness (`pages/debug_page.zig`) sets one
//! component of an agent to a sample value through a `DebugPoke` intent, so the page itself
//! holds only `*const World`. A poke is a developer's door, not a decision: it is never refused,
//! and a poke at an agent without the component (or with no agent at all) changes nothing.
//!
//! `rate` is clamped into the configured band by `Config.clampMetabolism`, as `SetRation` is;
//! `good` sets one good's count and `settle` then lets the goods' effects follow
//! (`capital.settle`), so a harness sets several counts and settles once. `generator_mode` sets
//! one generator's mode, as the toggle's cycle would leave it.

const std = @import("std");
const ecs = @import("../ecs.zig");
const events = @import("../events.zig");
const comp = @import("../components.zig");
const res_mod = @import("../res.zig");
const capital = @import("../rules/capital.zig");
const Catalog = @import("../data/roster.zig").Catalog;

const World = ecs.World;

pub fn poke(
    w: *World,
    cat: *const Catalog,
    cfg: *const res_mod.Config,
    intents: ecs.EventReader(events.DebugPoke, .debug),
) void {
    while (intents.next()) |it| switch (it.what) {
        .food => |v| if (w.get(it.agent, comp.InventoryFood)) |food| {
            food.v = v;
        },
        .vigor => |v| if (w.get(it.agent, comp.Vigor)) |vigor| {
            vigor.v = v.v;
            vigor.max = v.max;
        },
        .rate => |r| if (w.get(it.agent, comp.Metabolism)) |met| {
            met.rate = cfg.clampMetabolism(r);
        },
        .biomass => |v| if (w.get(it.agent, comp.InventoryBiomass)) |stock| {
            stock.v = v;
        },
        .good => |g| if (w.get(it.agent, comp.Goods)) |goods| {
            if (g.gi < goods.count.len) goods.count[g.gi] = g.count;
        },
        .settle => if (w.has(it.agent, comp.Goods)) capital.settle(w, it.agent, cat),
        .generator_mode => |g| if (w.get(it.agent, comp.Generators)) |gens| {
            if (g.gi < gens.mode.len) gens.mode[g.gi] = g.mode;
        },
    };
}

// ============================ Tests ==========================================

const testing = std.testing;

test "a poke sets the named component, the rate clamped into the band" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    var res = res_mod.Resources{};
    res.events.update();
    const e = w.spawn(.{ comp.Vigor{}, comp.InventoryFood{}, comp.InventoryBiomass{}, comp.Metabolism{}, comp.Goods{}, comp.Generators{} });
    const poker = res.events.writer(events.DebugPoke);
    _ = poker.push(.{ .agent = e, .what = .{ .food = 7.8 } });
    _ = poker.push(.{ .agent = e, .what = .{ .vigor = .{ .v = 14.4, .max = 15 } } });
    _ = poker.push(.{ .agent = e, .what = .{ .rate = 99 } });
    _ = poker.push(.{ .agent = e, .what = .{ .biomass = 31 } });
    _ = poker.push(.{ .agent = e, .what = .{ .good = .{ .gi = 2, .count = 3 } } });
    _ = poker.push(.{ .agent = e, .what = .{ .generator_mode = .{ .gi = 4, .mode = .auto } } });
    ecs.run(&w, &res, poke);
    try testing.expectEqual(@as(f32, 7.8), w.get(e, comp.InventoryFood).?.v);
    try testing.expectEqual(comp.Vigor{ .v = 14.4, .max = 15 }, w.get(e, comp.Vigor).?.*);
    try testing.expectEqual(res.config.metabolism_rate_max, w.get(e, comp.Metabolism).?.rate);
    try testing.expectEqual(@as(f32, 31), w.get(e, comp.InventoryBiomass).?.v);
    try testing.expectEqual(@as(u32, 3), w.get(e, comp.Goods).?.count[2]);
    try testing.expectEqual(comp.Generators.Mode.auto, w.get(e, comp.Generators).?.mode[4]);
    // Read once: a second run applies nothing again.
    w.get(e, comp.InventoryFood).?.v = 1;
    ecs.run(&w, &res, poke);
    try testing.expectEqual(@as(f32, 1), w.get(e, comp.InventoryFood).?.v);
}

test "a poke at a missing agent or a missing component changes nothing" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    var res = res_mod.Resources{};
    res.events.update();
    const e = w.spawn(.{comp.Vigor{}});
    const gone = w.spawn(.{comp.InventoryFood{}});
    w.despawn(gone);
    const poker = res.events.writer(events.DebugPoke);
    _ = poker.push(.{ .agent = gone, .what = .{ .food = 9 } });
    _ = poker.push(.{ .agent = e, .what = .{ .food = 9 } });
    _ = poker.push(.{ .agent = e, .what = .{ .rate = 2 } });
    _ = poker.push(.{ .agent = e, .what = .{ .good = .{ .gi = 0, .count = 1 } } });
    _ = poker.push(.{ .agent = e, .what = .settle });
    _ = poker.push(.{ .agent = e, .what = .{ .generator_mode = .{ .gi = 0, .mode = .off } } });
    ecs.run(&w, &res, poke);
    try testing.expectEqual(comp.Vigor{}, w.get(e, comp.Vigor).?.*);
    try testing.expect(!w.has(e, comp.InventoryFood));
    try testing.expect(!w.has(e, comp.Metabolism));
    try testing.expect(!w.has(e, comp.Goods));
    try testing.expect(!w.has(e, comp.Generators));
    try testing.expect(w.get(gone, comp.InventoryFood) == null);
}
