//! `barter` — **atomic** resolution of a Passerby trade (ACT1-14).
//!
//! A trade either happens whole or not at all. On acceptance this revalidates the quote against
//! live state — the encounter revision (still the same passerby?), the passerby's stock, the
//! player's affordability, and, for a sell, ownership of the good being given — and only then
//! moves **both** bundles: the give side leaves the player, the receive side arrives, the
//! passerby's finite satchel decrements, any good effect applies/revokes exactly once, and one
//! log line is pushed. A failed revalidation touches nothing and returns a player-readable reason,
//! so a stale, departed, sold-out, or unaffordable trade rolls back by never having started.
//!
//! This module bridges the leaf `market` contracts to the world: `market` stays UI- and
//! world-free, `capital` owns good grant/revoke, and `barter` is the one place that applies a
//! `market.Quote` to a player entity. Food and generic Materials move on the inventory
//! components; owned goods move through `capital` (a buy grants, a sell breaks) so a traded tool's
//! effect lands/leaves through the same symmetric path a built/broken one does.

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

/// The good component a tradeable tool `Ware` maps to, or null for the bulk resources (food /
/// materials, which move on inventory rather than as a good). This is the seam between the
/// generic transfer vocabulary and the concrete components — a fish hook is a Fishing rod, a
/// whetstone is a Hatchet (the hand-tool family ACT1-16 supersedes). Comptime-dispatched by the
/// caller through an `inline` over `Ware`.
pub fn goodOf(w: Ware) ?type {
    return switch (w) {
        .food, .materials => null,
        .fish_hook => comp.FishNet, // the passerby carries the *upgrade* (rank-2 fishing tool)
        .whetstone => comp.HandAxe, // the rank-2 chopping tool
    };
}

/// Whether the player can satisfy the give side's **ownership** requirement — every non-resource
/// (tool) line on the give side must be a good the player currently owns. Resource lines are
/// covered by the affordability check in `Quote.refusal`.
fn owns_give(w: *World, e: Entity, q: *const Quote) bool {
    for (q.give.slice()) |line| {
        switch (line.item) {
            .food, .materials => {},
            inline .fish_hook, .whetstone => |ware| {
                const G = comptime goodOf(ware).?;
                if (!w.has(e, G)) return false;
            },
        }
    }
    return true;
}

/// Resolve `q` on player `e`, atomically. Revalidates everything first; on any failure returns the
/// reason and mutates nothing. On success: deducts the give side, credits the receive side,
/// decrements the passerby's stock, applies/revokes good effects once, logs one line.
pub fn resolve(w: *World, e: Entity, res: *Resources, q: *const Quote) Result {
    const enc = &res.sim.encounter;
    const food = w.get(e, comp.InventoryFood).?;
    const stock = w.get(e, comp.InventoryMaterial).?;

    // --- revalidate (all-or-nothing gate) ---------------------------------------------------
    const r = q.refusal(enc, food.v, stock.v);
    if (r != .none) return .{ .refusal = r };
    if (!owns_give(w, e, q)) return .{ .refusal = .sold_out }; // player lacks the good to give
    // The receive side of a buy comes out of the passerby's satchel — confirm the satchel holds
    // every tool/resource ware the player is to receive (bulk food/materials are the passerby's
    // to conjure at the quoted rate; the finite constraint is on the specific wares it carries).
    for (q.receive.slice()) |line| {
        if (enc.stockOf(line.item) < @as(u16, @intFromFloat(@ceil(line.qty)))) {
            // Only tool wares are truly finite in the satchel; bulk resources are not stock-gated
            // on the receive side (the passerby always has coin-of-the-realm Materials/Food to
            // hand over up to `Quote.stock`, which the refusal already checked).
            switch (line.item) {
                .food, .materials => {},
                else => return .{ .refusal = .sold_out },
            }
        }
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
            inline .fish_hook, .whetstone => |ware| {
                const G = comptime goodOf(ware).?;
                // Selling a good: break it (its effect leaves symmetrically). Spares go first.
                capital.break_good(w, e, res, G);
                enc.give(ware, @intFromFloat(@ceil(line.qty))); // the passerby now carries it
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
            inline .fish_hook, .whetstone => |ware| {
                const G = comptime goodOf(ware).?;
                // Buying a good: own it and apply its effect once (a repeat is stock, not a second
                // effect — the same rule `finish_build` follows).
                if (w.get(e, G)) |held| {
                    held.count += 1;
                } else {
                    w.add(e, G{});
                    capital.grant_public(w, e, G);
                }
                enc.take(ware, @intFromFloat(@ceil(line.qty))); // out of the finite satchel
            },
        }
    }

    // Decrement the offer's own stock and log one line.
    if (q.stock > 0) {
        // The caller holds the quote; the encounter-level satchel is the durable stock. The
        // per-offer `stock` is advisory for the schedule and re-derived next quote.
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

fn test_res() Resources {
    var res: Resources = undefined;
    res.sim = .{ .prng = std.Random.DefaultPrng.init(7) };
    res.time = .{ .dt = 0 };
    res.config = .{};
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
    } ++ @import("./actions.zig").actions_bundle);
}

test "a buy moves both bundles atomically and decrements the satchel" {
    var w = World.init();
    var res = test_res();
    const e = spawn_trader(&w);

    // Buy a fish hook (a Fishing rod) for 2 food + 4 materials.
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

    try testing.expect(!w.has(e, comp.FishNet));
    const r = resolve(&w, e, &res, &q);
    try testing.expect(r.ok());
    // Give side left the player.
    try testing.expectApproxEqAbs(@as(f32, 4), w.get(e, comp.InventoryFood).?.v, 1e-5); // 6-2
    try testing.expectApproxEqAbs(@as(f32, 8), w.get(e, comp.InventoryMaterial).?.v, 1e-5); // 12-4
    // Receive side arrived + its effect (the fishing verb, via the family recompute) applied once.
    try testing.expect(w.has(e, comp.FishNet));
    try testing.expect(w.has(e, comp.ActionFish));
    // The satchel decremented.
    try testing.expectEqual(@as(u16, 0), res.sim.encounter.stockOf(.fish_hook));
    try testing.expectEqual(@as(usize, 1), res.sim.log.count); // one log line
}

test "a sell breaks the good, credits materials, and passes it to the passerby" {
    var w = World.init();
    var res = test_res();
    const e = spawn_trader(&w);
    // Own a hand axe to sell (grant its verb too, via the chopping-family recompute).
    w.add(e, comp.HandAxe{});
    capital.grant_public(&w, e, comp.HandAxe);
    try testing.expect(w.has(e, comp.ActionChopWood));

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
    // The good left and its verb with it (symmetric break — no lower rank owned, so the verb goes).
    try testing.expect(!w.has(e, comp.HandAxe));
    try testing.expect(!w.has(e, comp.ActionChopWood));
    // The passerby now carries a whetstone.
    try testing.expectEqual(@as(u16, 2), res.sim.encounter.stockOf(.whetstone)); // 1 + 1
}

test "every refusal path rolls back — nothing moves" {
    var w = World.init();
    var res = test_res();
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
    try testing.expect(!w.has(e, comp.FishRod));
    try testing.expectEqual(@as(usize, 0), res.sim.log.count);

    // Affordable but stale (a different passerby now) → still nothing.
    q.give = market.Bundle.one(.materials, 2);
    res.sim.encounter.id = 2;
    try testing.expectEqual(market.Refusal.stale, resolve(&w, e, &res, &q).refusal);
    try testing.expect(!w.has(e, comp.FishRod));

    // Departed → nothing.
    res.sim.encounter.id = 1;
    res.sim.encounter.phase = .departed;
    try testing.expectEqual(market.Refusal.departed, resolve(&w, e, &res, &q).refusal);
    try testing.expect(!w.has(e, comp.FishRod));
    try testing.expectEqual(@as(usize, 0), res.sim.log.count); // never logged a failed trade
}

test "selling a good you do not own is refused, not a panic" {
    var w = World.init();
    var res = test_res();
    const e = spawn_trader(&w); // owns no hatchet

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
