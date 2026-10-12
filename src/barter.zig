//! `barter` — **atomic** resolution of a Passerby trade.
//!
//! A trade either happens whole or not at all. On acceptance this revalidates the quote against
//! live state — the encounter revision (still the same passerby?), the passerby's stock, the
//! player's affordability, and, for a sell, ownership of the good being given — and only then
//! moves **both** bundles: the give side leaves the player, the receive side arrives, the
//! passerby's finite satchel decrements, any good effect lands or leaves exactly once, and one
//! log line is pushed. A failed revalidation touches nothing and returns a player-readable reason,
//! so a stale, departed, sold-out, or unaffordable trade rolls back by never having started.
//!
//! This module bridges the leaf `market` contracts to the world: `market` stays UI- and
//! world-free, `capital` owns ownership and its effects, and `barter` is the one place that
//! applies a `market.Quote` to a player entity. Food and generic Materials move on the inventory
//! components; owned goods move through `capital` (a buy acquires, a sell releases) so a traded
//! tool's effect lands/leaves through the same path a built/broken one does.

const std = @import("std");
const ha = @import("ha");
const comp = ha.comp;
const market = @import("./market.zig");
const capital = @import("./capital.zig");
const res_mod = @import("./res.zig");
const world = @import("./world.zig");

const World = world.World;
const Entity = world.Entity;
const Resources = res_mod.Resources;
const Ware = market.Ware;
const Quote = market.Quote;

/// The result of attempting a trade: the `refusal` (`.none` on success), and — on success — the
/// realized Materials moved (for a sell, what was paid), so the caller/UI can confirm the number.
pub const Result = struct {
    refusal: market.Refusal,
    materials_moved: f32 = 0,

    pub fn ok(self: Result) bool {
        return self.refusal == .none;
    }
};

/// The roster id a tradeable tool `Ware` maps to, or null for the bulk resources (food /
/// materials, which move on inventory rather than as a good). This is the seam between the
/// generic transfer vocabulary and the authored goods — a fish hook is the fishing net, a
/// whetstone the hand axe: the rank-2 tools `effects` lets supersede the built ones.
pub fn goodOf(w: Ware) ?[]const u8 {
    return switch (w) {
        .food, .materials => null,
        .fish_hook => "fish_net",
        .whetstone => "hand_axe",
    };
}

/// Whether the player can satisfy the give side's **ownership** requirement — every tool line on
/// the give side must be a good the player currently owns. Resource lines are covered by the
/// affordability check in `Quote.refusal`.
fn owns_give(w: *World, e: Entity, res: *Resources, q: *const Quote) bool {
    for (q.give.slice()) |line| {
        const id = goodOf(line.item) orelse continue;
        if (!capital.owns(w, e, &res.catalog, id)) return false;
    }
    return true;
}

/// Resolve `q` on player `e`, atomically. Revalidates everything first; on any failure returns the
/// reason and mutates nothing. On success: deducts the give side, credits the receive side,
/// decrements the passerby's stock, lands/leaves good effects once, logs one line.
pub fn resolve(w: *World, e: Entity, res: *Resources, q: *const Quote) Result {
    const enc = &res.sim.encounter;
    const cat = &res.catalog;
    const food = w.get(e, comp.InventoryFood).?;
    const stock = w.get(e, comp.InventoryMaterial).?;

    // --- revalidate (all-or-nothing gate) ---------------------------------------------------
    const r = q.refusal(enc, food.v, stock.v);
    if (r != .none) return .{ .refusal = r };
    if (!owns_give(w, e, res, q)) return .{ .refusal = .sold_out }; // player lacks the good to give
    // The receive side of a buy comes out of the passerby's satchel — confirm the satchel holds
    // every tool ware the player is to receive (bulk food/materials are the passerby's to
    // conjure at the quoted rate; the finite constraint is on the specific wares it carries).
    for (q.receive.slice()) |line| {
        if (goodOf(line.item) == null) continue;
        if (enc.stockOf(line.item) < @as(u16, @intFromFloat(@ceil(line.qty)))) return .{ .refusal = .sold_out };
    }

    // --- apply (both bundles move, or neither — we are past every gate now) ------------------
    var materials_moved: f32 = 0;

    // Give side leaves the player.
    for (q.give.slice()) |line| {
        switch (line.item) {
            .food => food.v -= line.qty,
            .materials => {
                stock.v -= line.qty;
                materials_moved += line.qty;
            },
            .fish_hook, .whetstone => {
                // Selling a good: its effect leaves with the last unit, spares first.
                const gi = cat.goodIndex(goodOf(line.item).?).?;
                const units: u32 = @intFromFloat(@ceil(line.qty));
                _ = capital.release(w, e, res, gi, units);
                enc.give(line.item, @intCast(units)); // the passerby now carries it
            },
        }
    }

    // Receive side arrives to the player.
    for (q.receive.slice()) |line| {
        switch (line.item) {
            .food => food.v += line.qty,
            .materials => {
                stock.v += line.qty;
                materials_moved += line.qty;
            },
            .fish_hook, .whetstone => {
                // Buying a good: own it and its effect lands once (a repeat is stock, not a second
                // effect — the same rule a build follows).
                const gi = cat.goodIndex(goodOf(line.item).?).?;
                const units: u32 = @intFromFloat(@ceil(line.qty));
                capital.acquire(w, e, res, gi, units);
                enc.take(line.item, @intCast(units)); // out of the finite satchel
            },
        }
    }

    var buf: [96]u8 = undefined;
    const msg = switch (q.direction) {
        .buy => std.fmt.bufPrint(&buf, "You trade with the passerby.", .{}) catch "You trade.",
        .sell => std.fmt.bufPrint(&buf, "You sell to the passerby for {d:.0} materials.", .{materials_moved}) catch "You sell.",
    };
    res.sim.log.push(.good, msg);

    return .{ .refusal = .none, .materials_moved = materials_moved };
}

// ============================ Tests =====================================================

const testing = std.testing;
const roster = ha.roster;
const effects = ha.effects;

fn test_res() !Resources {
    var res: Resources = undefined;
    res.sim = .{ .prng = std.Random.DefaultPrng.init(7) };
    res.time = .{ .dt = 0 };
    res.config = .{};
    res.catalog = try roster.load(testing.allocator, roster.shipped, null);
    // A present passerby with a stocked satchel.
    res.sim.encounter = .{ .phase = .present, .id = 1 };
    res.sim.encounter.stock = .{ 8, 20, 1, 1 };
    return res;
}

fn spawn_trader(w: *World) Entity {
    return w.spawn(.{
        comp.Vigor{ .v = 10, .max = 10 },
        comp.InventoryFood{ .v = 6, .quality = 1, .spoils = 0 },
        comp.InventoryMaterial{ .v = 12 },
        comp.Goods{},
        comp.Granted{},
    } ++ @import("./actions.zig").actions_bundle);
}

fn held(w: *World, e: Entity, res: *Resources, verb: []const u8) bool {
    return effects.held(&res.catalog, w.get(e, comp.Goods).?, res.catalog.actionIndex(verb).?);
}

test "a buy moves both bundles atomically and decrements the satchel" {
    var w = World.init();
    var res = try test_res();
    defer res.catalog.deinit();
    const e = spawn_trader(&w);

    // Buy a fish hook (the fishing net) for 2 food + 4 materials.
    var q = Quote{
        .id = 1,
        .rev = 1,
        .direction = .buy,
        .give = blk: {
            var g = market.Bundle{};
            g.add(.food, 2);
            g.add(.materials, 4);
            break :blk g;
        },
        .receive = market.Bundle.one(.fish_hook, 1),
    };

    try testing.expect(!capital.owns(&w, e, &res.catalog, "fish_net"));
    const r = resolve(&w, e, &res, &q);
    try testing.expect(r.ok());
    // Give side left the player.
    try testing.expectApproxEqAbs(@as(f32, 4), w.get(e, comp.InventoryFood).?.v, 1e-5); // 6-2
    try testing.expectApproxEqAbs(@as(f32, 8), w.get(e, comp.InventoryMaterial).?.v, 1e-5); // 12-4
    // Receive side arrived + its effect (the fishing verb) applied once; the shadow follows.
    try testing.expect(capital.owns(&w, e, &res.catalog, "fish_net"));
    try testing.expect(held(&w, e, &res, "fish"));
    try testing.expect(w.has(e, comp.FishNet));
    try testing.expect(w.has(e, comp.ActionFish));
    // The satchel decremented.
    try testing.expectEqual(@as(u16, 0), res.sim.encounter.stockOf(.fish_hook));
    try testing.expectEqual(@as(usize, 1), res.sim.log.count); // one log line
}

test "a sell releases the good, credits materials, and passes it to the passerby" {
    var w = World.init();
    var res = try test_res();
    defer res.catalog.deinit();
    const e = spawn_trader(&w);
    // Own a hand axe to sell; its verb comes with it.
    capital.acquire(&w, e, &res, res.catalog.goodIndex("hand_axe").?, 1);
    try testing.expect(held(&w, e, &res, "chop_wood"));

    var q = Quote{
        .id = 1,
        .rev = 1,
        .direction = .sell,
        .give = market.Bundle.one(.whetstone, 1), // the hand-axe family
        .receive = market.Bundle.one(.materials, 5),
    };

    const r = resolve(&w, e, &res, &q);
    try testing.expect(r.ok());
    try testing.expectApproxEqAbs(@as(f32, 5), r.materials_moved, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 17), w.get(e, comp.InventoryMaterial).?.v, 1e-5); // 12+5
    // The good left and its verb with it (no lower rank owned, so the verb goes).
    try testing.expect(!capital.owns(&w, e, &res.catalog, "hand_axe"));
    try testing.expect(!held(&w, e, &res, "chop_wood"));
    try testing.expect(!w.has(e, comp.HandAxe));
    try testing.expect(!w.has(e, comp.ActionChopWood));
    // The passerby now carries a whetstone, and the sale is the only line.
    try testing.expectEqual(@as(u16, 2), res.sim.encounter.stockOf(.whetstone)); // 1 + 1
    try testing.expectEqual(@as(usize, 1), res.sim.log.count);
}

test "every refusal path rolls back — nothing moves" {
    var w = World.init();
    var res = try test_res();
    defer res.catalog.deinit();
    const e = spawn_trader(&w);

    var q = Quote{
        .id = 1,
        .rev = 1,
        .direction = .buy,
        .give = blk: {
            var g = market.Bundle{};
            g.add(.materials, 999); // more than the player holds
            break :blk g;
        },
        .receive = market.Bundle.one(.fish_hook, 1),
    };

    // Unaffordable → nothing changes.
    const before_mat = w.get(e, comp.InventoryMaterial).?.v;
    try testing.expectEqual(market.Refusal.unaffordable, resolve(&w, e, &res, &q).refusal);
    try testing.expectEqual(before_mat, w.get(e, comp.InventoryMaterial).?.v);
    try testing.expect(!capital.owns(&w, e, &res.catalog, "fish_net"));
    try testing.expectEqual(@as(usize, 0), res.sim.log.count);

    // Affordable but stale (a different passerby now) → still nothing.
    q.give = market.Bundle.one(.materials, 2);
    res.sim.encounter.id = 2;
    try testing.expectEqual(market.Refusal.stale, resolve(&w, e, &res, &q).refusal);
    try testing.expect(!capital.owns(&w, e, &res.catalog, "fish_net"));

    // Departed → nothing.
    res.sim.encounter.id = 1;
    res.sim.encounter.phase = .departed;
    try testing.expectEqual(market.Refusal.departed, resolve(&w, e, &res, &q).refusal);
    try testing.expect(!capital.owns(&w, e, &res.catalog, "fish_net"));
    try testing.expectEqual(@as(usize, 0), res.sim.log.count); // never logged a failed trade
}

test "selling a good you do not own is refused, not a panic" {
    var w = World.init();
    var res = try test_res();
    defer res.catalog.deinit();
    const e = spawn_trader(&w); // owns no hand axe

    var q = Quote{
        .id = 1,
        .rev = 1,
        .direction = .sell,
        .give = market.Bundle.one(.whetstone, 1),
        .receive = market.Bundle.one(.materials, 5),
    };
    try testing.expectEqual(market.Refusal.sold_out, resolve(&w, e, &res, &q).refusal);
    try testing.expectApproxEqAbs(@as(f32, 12), w.get(e, comp.InventoryMaterial).?.v, 1e-5); // unchanged
}
