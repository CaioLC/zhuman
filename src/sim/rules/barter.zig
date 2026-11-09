//! `barter` — **atomic** resolution of a Passerby trade.
//!
//! A trade either happens whole or not at all. On acceptance this revalidates the quote against
//! live state — the encounter revision (still the same passerby?), the passerby's stock, the
//! player's affordability, and, for a sell, ownership of the good being given — and only then
//! moves **both** bundles: the give side leaves the player, the receive side arrives, the
//! passerby's finite satchel decrements, any good effect lands or leaves exactly once, and one
//! `Traded` fact is emitted. A failed revalidation touches nothing and returns the
//! `Refused.Reason`, so a stale, departed, sold-out, or unaffordable trade rolls back by never
//! having started. The `barter` handler (`systems/barter.zig`) is its caller.
//!
//! This module bridges the leaf `market` contracts to the world: `market` stays UI- and
//! world-free, `capital` owns ownership and its effects, and `barter` is the one place that
//! applies a `market.Quote` to a player entity. Food and generic Materials move on the inventory
//! components; owned goods move through `capital` (a buy acquires, a sell releases) so a traded
//! tool's effect lands/leaves through the same path a built/broken one does.

const std = @import("std");
const comp = @import("../components.zig");
const migration = @import("../data/migration.zig");
const market = @import("./market.zig");
const capital = @import("./capital.zig");
const res_mod = @import("../res.zig");
const world = @import("../ecs.zig");
const events = @import("../events.zig");

const World = world.World;
const Entity = world.Entity;
const Resources = res_mod.Resources;
const Ware = market.Ware;
const Quote = market.Quote;

const Reason = events.Refused.Reason;

/// A quote's refusal as the handler's reason, by name; null when the quote is takeable.
pub fn reasonOf(r: market.Refusal) ?Reason {
    return switch (r) {
        .none => null,
        inline else => |tag| @field(Reason, @tagName(tag)),
    };
}

/// The roster id a tradeable tool `Ware` maps to, or null for the bulk resources (food /
/// materials, which move on inventory rather than as a good). The passerby's tool slots carry
/// the manufactured Act I unlockers, the fishing rod and hatchet, and their rank-2 successors,
/// the fishing net and hand axe.
pub fn goodOf(w: Ware) ?[]const u8 {
    return switch (w) {
        .food, .biomass => null,
        .fish_hook => "fish_rod",
        .whetstone => "hatchet",
        .fish_net => "fish_net",
        .hand_axe => "hand_axe",
    };
}

/// Whether the passerby offers `ware` to agent `e`: a rank-2 tool only to a holder of the
/// rank-1 tool of its family (`market.prerequisite`); every other ware always. A lot not
/// offered is absent from the dialog, and a buy of one is refused.
pub fn offered(w: *const World, e: Entity, cat: *const roster.Catalog, ware: Ware) bool {
    const pre = market.prerequisite(ware) orelse return true;
    return capital.owns(w, e, cat, goodOf(pre).?);
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

/// Resolve `lots` of quote `q` on player `e`, atomically: every line of both bundles scaled
/// linearly by `lots`. Revalidates everything first; on any failure returns the reason and
/// mutates nothing. On success: deducts the give side into the passerby's satchel, credits the
/// receive side out of it, counts a sell's lots on the falling schedule, tallies the visit,
/// lands/leaves good effects once, and emits `Traded` with the materials moved and, for a sell,
/// what the passerby paid.
pub fn resolve(w: *World, e: Entity, res: *Resources, base: *const Quote, lots: u16) ?Reason {
    const enc = &res.sim.encounter;
    const cat = &res.catalog;
    const food = w.get(e, comp.InventoryFood).?;
    const stock = w.get(e, comp.InventoryBiomass).?;
    if (lots == 0) return .sold_out;
    const scaled = base.times(lots);
    const q = &scaled;

    // --- revalidate (all-or-nothing gate) ---------------------------------------------------
    if (reasonOf(q.refusal(enc, food.v, stock.v))) |r| return r;
    if (base.stock < lots) return .sold_out;
    if (!owns_give(w, e, res, q)) return .not_owned; // player lacks the good to give
    // A rank-2 tool is the holder's of the rank-1 tool only.
    for (q.receive.slice()) |line| if (!offered(w, e, cat, line.item)) return .not_owned;
    // `Quote.refusal` has confirmed the satchel holds everything the passerby hands over.

    // --- apply (both bundles move, or neither — we are past every gate now) ------------------
    var biomass_moved: f32 = 0;
    var acquired: ?u16 = null;
    for (q.give.slice()) |line| enc.visit[@backingInt(line.item)] -= line.qty;
    for (q.receive.slice()) |line| enc.visit[@backingInt(line.item)] += line.qty;

    // Give side leaves the player.
    for (q.give.slice()) |line| {
        switch (line.item) {
            .food => food.v -= line.qty,
            .biomass => {
                stock.v -= line.qty;
                biomass_moved += line.qty;
            },
            .fish_hook, .whetstone, .fish_net, .hand_axe => {
                // Selling a good: its effect leaves with the last unit, spares first.
                const gi = cat.goodIndex(goodOf(line.item).?).?;
                const units: u32 = @intFromFloat(@ceil(line.qty));
                _ = capital.release(w, e, res, gi, units);
            },
        }
        enc.give(line.item, line.qty); // the passerby now carries it
    }

    // Receive side arrives to the player.
    for (q.receive.slice()) |line| {
        switch (line.item) {
            .food => food.v += line.qty,
            .biomass => {
                stock.v += line.qty;
                biomass_moved += line.qty;
            },
            .fish_hook, .whetstone, .fish_net, .hand_axe => {
                // Buying a good: own it and its effect lands once (a repeat is stock, not a second
                // effect — the same rule a build follows).
                const gi = cat.goodIndex(goodOf(line.item).?).?;
                const units: u32 = @intFromFloat(@ceil(line.qty));
                capital.acquire(w, e, res, gi, units);
                acquired = gi;
            },
        }
        enc.take(line.item, line.qty); // out of the finite satchel
    }
    // A sell moves its ware one step down the falling schedule per lot.
    if (q.nth != null and q.give.len > 0) enc.sold[@backingInt(q.give.lines[0].item)] += lots;

    _ = res.events.writer(events.Traded).push(.{
        .agent = e,
        .with = .passerby,
        .direction = q.direction,
        .biomass_moved = biomass_moved,
        .acquired = acquired,
        .paid = if (q.direction == .sell and q.receive.len > 0) q.receive.lines[0] else null,
        .act = migration.actOf(w, e),
    });
    return null;
}

// ============================ Tests =====================================================

const testing = std.testing;
const roster = @import("../data/roster.zig");
const effects = @import("./effects.zig");

fn test_res() !Resources {
    var res: Resources = .{
        .sim = .{ .prng = std.Random.DefaultPrng.init(7) },
        .catalog = try roster.load(testing.allocator, roster.shipped, null),
    };
    // A present passerby with a stocked satchel.
    res.sim.encounter = .{ .phase = .present, .id = 1 };
    res.sim.encounter.stock = (market.Schedule{}).satchel;
    return res;
}

fn spawn_trader(w: *World) Entity {
    return w.spawn(.{
        comp.Vigor{ .v = 10, .max = 10 },
        comp.InventoryFood{ .v = 6, .quality = 1, .spoils = 0 },
        comp.InventoryBiomass{ .v = 12 },
        comp.Goods{},
        comp.Granted{},
    });
}

fn held(w: *World, e: Entity, res: *Resources, verb: []const u8) bool {
    return effects.held(&res.catalog, effects.holdingsOf(w, e).?, res.catalog.actionIndex(verb).?);
}

test "a buy moves both bundles atomically and decrements the satchel" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    var res = try test_res();
    defer res.catalog.deinit();
    const e = spawn_trader(&w);

    // Buy a fishing rod for 2 food + 4 materials.
    var q = Quote{
        .id = 1,
        .rev = 1,
        .direction = .buy,
        .give = blk: {
            var g = market.Bundle{};
            g.add(.food, 2);
            g.add(.biomass, 4);
            break :blk g;
        },
        .receive = market.Bundle.one(.fish_hook, 1),
    };

    try testing.expect(!capital.owns(&w, e, &res.catalog, "fish_rod"));
    try testing.expect(resolve(&w, e, &res, &q, 1) == null);
    // Give side left the player.
    try testing.expectApproxEqAbs(@as(f32, 4), w.get(e, comp.InventoryFood).?.v, 1e-5); // 6-2
    try testing.expectApproxEqAbs(@as(f32, 8), w.get(e, comp.InventoryBiomass).?.v, 1e-5); // 12-4
    // Receive side arrived + its effect (the fishing verb) applied once.
    try testing.expect(capital.owns(&w, e, &res.catalog, "fish_rod"));
    try testing.expect(held(&w, e, &res, "fish"));
    // The satchel decremented.
    try testing.expectEqual(@as(f32, 0), res.sim.encounter.stockOf(.fish_hook));
    try testing.expectEqual(@as(usize, 1), res.events.len(events.Traded)); // one fact
}

test "a sell releases the good, credits materials, and passes it to the passerby" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    var res = try test_res();
    defer res.catalog.deinit();
    const e = spawn_trader(&w);
    // Own a hand axe to sell; its verb comes with it.
    capital.acquire(&w, e, &res, res.catalog.goodIndex("hatchet").?, 1);
    try testing.expect(held(&w, e, &res, "chop_wood"));

    var q = Quote{
        .id = 1,
        .rev = 1,
        .direction = .sell,
        .give = market.Bundle.one(.whetstone, 1), // the hand-axe family
        .receive = market.Bundle.one(.biomass, 5),
    };

    try testing.expect(resolve(&w, e, &res, &q, 1) == null);
    var cursor: u64 = 0;
    const traded = res.events.readerAt(events.Traded, &cursor).next().?;
    try testing.expectEqual(events.Who.passerby, traded.with);
    try testing.expectEqual(market.Direction.sell, traded.direction);
    try testing.expectApproxEqAbs(@as(f32, 5), traded.biomass_moved, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 17), w.get(e, comp.InventoryBiomass).?.v, 1e-5); // 12+5
    // The good left and its verb with it (no lower rank owned, so the verb goes).
    try testing.expect(!capital.owns(&w, e, &res.catalog, "hatchet"));
    try testing.expect(!held(&w, e, &res, "chop_wood"));
    // The passerby now carries a whetstone, and the sale is the only fact.
    try testing.expectEqual(@as(f32, 2), res.sim.encounter.stockOf(.whetstone)); // 1 + 1
    try testing.expectEqual(@as(usize, 1), res.events.len(events.Traded));
}

test "every refusal path rolls back — nothing moves" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    var res = try test_res();
    defer res.catalog.deinit();
    const e = spawn_trader(&w);

    var q = Quote{
        .id = 1,
        .rev = 1,
        .direction = .buy,
        .give = blk: {
            var g = market.Bundle{};
            g.add(.biomass, 999); // more than the player holds
            break :blk g;
        },
        .receive = market.Bundle.one(.fish_hook, 1),
    };

    // Unaffordable → nothing changes.
    const before_mat = w.get(e, comp.InventoryBiomass).?.v;
    try testing.expectEqual(Reason.unaffordable, resolve(&w, e, &res, &q, 1).?);
    try testing.expectEqual(before_mat, w.get(e, comp.InventoryBiomass).?.v);
    try testing.expect(!capital.owns(&w, e, &res.catalog, "fish_rod"));
    try testing.expectEqual(@as(usize, 0), res.events.len(events.Traded));

    // Affordable but stale (a different passerby now) → still nothing.
    q.give = market.Bundle.one(.biomass, 2);
    res.sim.encounter.id = 2;
    try testing.expectEqual(Reason.stale, resolve(&w, e, &res, &q, 1).?);
    try testing.expect(!capital.owns(&w, e, &res.catalog, "fish_rod"));

    // Departed → nothing.
    res.sim.encounter.id = 1;
    res.sim.encounter.phase = .departed;
    try testing.expectEqual(Reason.departed, resolve(&w, e, &res, &q, 1).?);
    try testing.expect(!capital.owns(&w, e, &res.catalog, "fish_rod"));
    try testing.expectEqual(@as(usize, 0), res.events.len(events.Traded)); // never a fact for a failed trade
}

test "selling a good you do not own is refused, not a panic" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    var res = try test_res();
    defer res.catalog.deinit();
    const e = spawn_trader(&w); // owns no hand axe

    var q = Quote{
        .id = 1,
        .rev = 1,
        .direction = .sell,
        .give = market.Bundle.one(.whetstone, 1),
        .receive = market.Bundle.one(.biomass, 5),
    };
    try testing.expectEqual(Reason.not_owned, resolve(&w, e, &res, &q, 1).?);
    try testing.expectApproxEqAbs(@as(f32, 12), w.get(e, comp.InventoryBiomass).?.v, 1e-5); // unchanged
}

test "several lots scale both bundles linearly, decrement stock by lots, and tally the visit" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    var res = try test_res();
    defer res.catalog.deinit();
    const e = spawn_trader(&w);

    // Buy food at 2 materials a lot, three lots.
    const q = Quote{
        .id = 1,
        .rev = 1,
        .direction = .buy,
        .give = market.Bundle.one(.biomass, 2),
        .receive = market.Bundle.one(.food, 1),
        .stock = 8,
    };
    try testing.expect(resolve(&w, e, &res, &q, 3) == null);
    try testing.expectApproxEqAbs(@as(f32, 6), w.get(e, comp.InventoryBiomass).?.v, 1e-5); // 12-6
    try testing.expectApproxEqAbs(@as(f32, 9), w.get(e, comp.InventoryFood).?.v, 1e-5); // 6+3
    try testing.expectApproxEqAbs(@as(f32, -6), res.sim.encounter.visit[@backingInt(Ware.biomass)], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 3), res.sim.encounter.visit[@backingInt(Ware.food)], 1e-5);

    // More lots than the quote's stock is refused whole.
    var short_stock = q;
    short_stock.stock = 2;
    try testing.expectEqual(Reason.sold_out, resolve(&w, e, &res, &short_stock, 3).?);
    // More lots than the player can pay for is refused whole.
    try testing.expectEqual(Reason.unaffordable, resolve(&w, e, &res, &q, 4).?);
    try testing.expectApproxEqAbs(@as(f32, 6), w.get(e, comp.InventoryBiomass).?.v, 1e-5);
}

test "a bulk buy takes its units from the satchel and the payment goes into it; an overdraw is refused" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    var res = try test_res();
    defer res.catalog.deinit();
    const e = spawn_trader(&w); // 6 food, 12 materials
    const enc = &res.sim.encounter;

    // Two food at 3 materials each: the satchel's food falls by two, its materials rise by six.
    const food = market.buy_quote(enc, .food);
    try testing.expect(resolve(&w, e, &res, &food, 2) == null);
    try testing.expectApproxEqAbs(@as(f32, 6), enc.stockOf(.food), 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 26), enc.stockOf(.biomass), 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 8), w.get(e, comp.InventoryFood).?.v, 1e-5);

    // A satchel with one food left refuses a quote for two, whole.
    enc.stock[@backingInt(Ware.food)] = 1;
    try testing.expectEqual(Reason.sold_out, resolve(&w, e, &res, &food, 2).?);
    try testing.expectApproxEqAbs(@as(f32, 8), w.get(e, comp.InventoryFood).?.v, 1e-5);
}

test "a sell is paid out of the satchel and the next lot's price falls" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    var res = try test_res();
    defer res.catalog.deinit();
    const e = spawn_trader(&w); // 6 food, 12 materials
    const enc = &res.sim.encounter;

    const first = market.sell_quote(enc, .food);
    try testing.expect(resolve(&w, e, &res, &first, 1) == null);
    try testing.expectApproxEqAbs(@as(f32, 14), w.get(e, comp.InventoryBiomass).?.v, 1e-5); // +2
    try testing.expectApproxEqAbs(@as(f32, 18), enc.stockOf(.biomass), 1e-5); // paid out of 20
    try testing.expectApproxEqAbs(@as(f32, 9), enc.stockOf(.food), 1e-5); // it carries the food
    try testing.expectEqual(@as(u16, 1), enc.soldOf(.food));
    // The same quote again is stale: the price has moved.
    try testing.expectEqual(Reason.stale, resolve(&w, e, &res, &first, 1).?);
    const second = market.sell_quote(enc, .food);
    try testing.expectApproxEqAbs(@as(f32, 1.5), second.receive.qtyOf(.biomass), 1e-5);

    // A satchel that cannot pay refuses the sell.
    enc.stock[@backingInt(Ware.biomass)] = 1;
    try testing.expectEqual(Reason.sold_out, resolve(&w, e, &res, &second, 1).?);

    // The last cycle: a sell lot of materials is paid in food.
    const mats = market.sell_quote(enc, .biomass);
    try testing.expect(resolve(&w, e, &res, &mats, 1) == null);
    try testing.expectApproxEqAbs(@as(f32, 6), w.get(e, comp.InventoryFood).?.v, 1e-5); // 6 - 1 + 1
    var cursor: u64 = 0;
    const r = res.events.readerAt(events.Traded, &cursor);
    _ = r.next().?;
    const paid = r.next().?.paid.?;
    try testing.expectEqual(Ware.food, paid.item);
}

test "a rank-2 tool is the rank-1 holder's: the net is refused to a player without the rod" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    var res = try test_res();
    defer res.catalog.deinit();
    const e = spawn_trader(&w);
    w.get(e, comp.InventoryFood).?.v = 10;
    w.get(e, comp.InventoryBiomass).?.v = 40;
    const net = market.buy_quote(&res.sim.encounter, .fish_net);
    try testing.expect(!offered(&w, e, &res.catalog, .fish_net));
    try testing.expectEqual(Reason.not_owned, resolve(&w, e, &res, &net, 1).?);
    try testing.expect(!capital.owns(&w, e, &res.catalog, "fish_net"));

    capital.acquire(&w, e, &res, res.catalog.goodIndex("fish_rod").?, 1);
    try testing.expect(offered(&w, e, &res.catalog, .fish_net));
    try testing.expect(resolve(&w, e, &res, &net, 1) == null);
    try testing.expect(capital.owns(&w, e, &res.catalog, "fish_net"));
    try testing.expectApproxEqAbs(@as(f32, 5), w.get(e, comp.InventoryFood).?.v, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 20), w.get(e, comp.InventoryBiomass).?.v, 1e-5);
}
