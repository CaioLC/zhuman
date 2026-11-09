//! Capital: the build path over the authored roster, and what owning a good does.
//!
//! A good is a record in `assets/roster/goods.zon` (`roster.zig`); an agent owns it as a count on
//! `comp.Goods`. Building, buying, selling and breaking all move that count, and every change
//! of ownership *settles* the body and larder (`effects.apply`). What a good does to a **verb**
//! is never stored —
//! `effects.verb` derives it. `quote` is the one gate calculation: the `quotes` system writes its
//! answer onto `comp.Quotes` for the BUILD row and a decider, and `begin` asks it again at
//! apply time.
//!
//! Gates beside the price. A good's `requires` names a `tech` that must read researched, and
//! `any`/`all` lists of goods and verbs (`effects.gatesMet`, the verbs' own gate reading): a
//! modifier lists the verb it works on, so you need the hatchet before the tools that sharpen
//! it. `unlock` — standing conditions, read at `begin` and not again, so a dip mid-build
//! doesn't stop work already paid for. The affordability gates are asymmetric on purpose:
//! energy is strict (vigor may never reach zero), a resource may be spent to exactly zero.
//!
//! Every good carries a count, and owning one is no reason you can't make another — building
//! for someone else is what a count is for. **Only the first unit carries the effect**: a
//! second pair of sandals is stock, not a deeper discount, so the effect lands on the way in
//! from absent and leaves with the last unit; losing a spare keeps it.

const std = @import("std");
const comp = @import("../components.zig");
const roster = @import("../data/roster.zig");
const effects = @import("./effects.zig");
const ledger = @import("./ledger.zig");
const actions = @import("./actions.zig");
const migration = @import("../data/migration.zig");
const ecs = @import("../ecs.zig");
const res_mod = @import("../res.zig");
const world = @import("../ecs.zig");
const events = @import("../events.zig");
const condition = @import("./condition.zig");

const World = world.World;
const Entity = world.Entity;
const Resources = res_mod.Resources;
const Catalog = roster.Catalog;
const Reason = events.Refused.Reason;

// --- the quote ---------------------------------------------------------------------------

/// Why a build cannot begin right now, or `ready`: the standing `comp.Quotes` carries per
/// recipe. The order is the precedence: a technology not yet researched says "tech" before
/// anything else, then an `any`/`all` gate that does not pass "needs", standing conditions
/// before the body.
pub const Standing = comp.Quotes.BuildStanding;

pub const Quote = struct {
    gi: u16,
    rec: *const roster.Good,
    /// Units already owned. Owning some is no reason not to build more.
    count: u32,
    standing: Standing,
    /// The first unpayable resource of the build cost when `standing == .short`.
    short: ?roster.Resource = null,
    /// How close the build cost is to affordable: the smallest held/needed over its
    /// resources, 1 when it names none.
    reach: f32,

    pub fn ready(self: Quote) bool {
        return self.standing == .ready;
    }
};

/// The quote for good `gi`, or null when it is not buildable or the agent has no holdings.
pub fn quote(w: *const World, e: Entity, cat: *const Catalog, gi: u16) ?Quote {
    const rec = &cat.goods[gi];
    if (!rec.buildable) return null;
    const h = effects.holdingsOf(w, e) orelse return null;
    const vigor = w.get(e, comp.Vigor) orelse return null;
    const req = &rec.requires;
    var q = Quote{ .gi = gi, .rec = rec, .count = h.goods.count[gi], .standing = .ready, .reach = reachOf(w, e, req) };
    if (!effects.techMet(cat, h, req)) {
        q.standing = .tech;
    } else if (!effects.listsMet(cat, h, req)) {
        q.standing = .needs;
    } else if (!unlockMet(w, e, cat, gi)) {
        q.standing = .unlock;
    } else if (w.has(e, comp.Busy)) {
        q.standing = .busy;
    } else if (req.energy >= vigor.v) {
        q.standing = .energy;
    } else if (ledger.short(w, e, req, 1)) |r| {
        q.standing = .short;
        q.short = r;
    }
    return q;
}

fn reachOf(w: *const World, e: Entity, req: *const roster.Requires) f32 {
    var r: f32 = 1;
    for (std.enums.values(roster.Resource)) |res| {
        const n = req.get(res);
        if (n <= 0) continue;
        r = @min(r, ledger.balance(w, e, res) / n);
    }
    return r;
}

/// Whether the technology a recipe waits on is researched for this agent. No `tech` means
/// yes; an agent without a board has researched nothing.
pub fn techMet(w: *const World, e: Entity, cat: *const Catalog, gi: u16) bool {
    const h = effects.holdingsOf(w, e) orelse return false;
    return effects.techMet(cat, h, &cat.goods[gi].requires);
}

/// Whether a recipe's `any` and `all` gates pass for this agent: a good owned, a verb held.
pub fn gatesMet(w: *const World, e: Entity, cat: *const Catalog, gi: u16) bool {
    return firstUnmetGate(w, e, cat, gi) == null;
}

/// The id of the first `any`/`all` gate entry that stands in the way of recipe `gi`, or null
/// when they pass (`effects.firstUnmet`).
pub fn firstUnmetGate(w: *const World, e: Entity, cat: *const Catalog, gi: u16) ?[]const u8 {
    const req = &cat.goods[gi].requires;
    const h = effects.holdingsOf(w, e) orelse return if (req.any.len > 0) req.any[0] else if (req.all.len > 0) req.all[0] else null;
    return effects.firstUnmet(cat, h, req);
}

/// Whether the builder meets the good's standing conditions. No `unlock` means none.
pub fn unlockMet(w: *const World, e: Entity, cat: *const Catalog, gi: u16) bool {
    const u = cat.goods[gi].unlock orelse return true;
    const vigor = w.get(e, comp.Vigor) orelse return false;
    if (vigor.v < u.vigor_abs) return false; // absolute current vigor, not a fraction
    if (ledger.balance(w, e, .food) < u.food) return false;
    return goodsOwned(w, e, cat) >= u.goods;
}

/// How many buildable good **kinds** the agent owns — four pairs of sandals are one.
pub fn goodsOwned(w: *const World, e: Entity, cat: *const Catalog) u32 {
    const goods = w.get(e, comp.Goods) orelse return 0;
    var n: u32 = 0;
    for (cat.goods, 0..) |g, gi| {
        if (g.buildable and goods.count[gi] > 0) n += 1;
    }
    return n;
}

pub fn owns(w: *const World, e: Entity, cat: *const Catalog, id: []const u8) bool {
    const goods = w.get(e, comp.Goods) orelse return false;
    const gi = cat.goodIndex(id) orelse return false;
    return goods.count[gi] > 0;
}

/// Whether the agent owns the good that ends `m` — what the curtain routes on.
pub fn ownsMilestone(w: *const World, e: Entity, cat: *const Catalog, m: roster.Milestone) bool {
    const goods = w.get(e, comp.Goods) orelse return false;
    for (cat.goods, 0..) |g, gi| {
        if (g.milestone == m and goods.count[gi] > 0) return true;
    }
    return false;
}

/// How many humans the agent's goods house.
pub fn capacity(w: *const World, e: Entity, cat: *const Catalog) u32 {
    const goods = w.get(e, comp.Goods) orelse return 0;
    var n: u32 = 0;
    for (cat.goods, 0..) |g, gi| {
        if (goods.count[gi] > 0) n += g.capacity;
    }
    return n;
}

// --- build / acquire / release ------------------------------------------------------------

/// Begin building `gi`: pay the energy and the resources upfront and start the work — the
/// good, and whatever it does, arrives only when `finish` resolves, `requires.hours` later.
/// Emits `WorkBegun` and returns null; when the quote is not ready it changes nothing and
/// returns why. Dying mid-build loses the work.
pub fn begin(w: *World, e: Entity, res: *Resources, gi: u16) ?Reason {
    const cat = &res.catalog;
    if (gi >= cat.goods.len) return .unavailable;
    const q = quote(w, e, cat, gi) orelse return .unavailable;
    if (!q.ready()) return switch (q.standing) {
        .ready => unreachable,
        inline else => |t| @field(Reason, @tagName(t)),
    };
    const price = &q.rec.requires;
    const vigor = w.get(e, comp.Vigor).?;
    vigor.v -= price.energy;
    // The band the toll moves is the build's, not the metabolism's (`rules/condition`).
    const crossing = if (w.get(e, comp.Condition)) |c| condition.refresh(&res.config, vigor, c) else null;
    ledger.pay(w, e, price, 1);
    _ = res.events.writer(events.WorkBegun).push(.{
        .agent = e,
        .doing = .{ .build = gi },
        .weary = condition.wearied(crossing),
        .energy = price.energy,
        .paid = ledger.receiptOf(price, 1),
        .act = migration.actOf(w, e),
    });
    const total = res_mod.hours_to_secs(price.hours, res.config.secs_per_day);
    // quality is a labor concept — a build either completes or it doesn't, so lock 1.
    w.add(e, comp.Busy{ .doing = .{ .build = gi }, .total = total, .remaining = total, .quality = 1 });
    return null;
}

/// Completion of a build: own one more unit, settle its effect if this is the first (a repeat
/// build is stock, not a second effect), and emit `WorkDone` with the unit as its receipt and
/// the count now owned, then `GoodsChanged`. Called by `systems.resolve_busy`.
pub fn finish(w: *World, e: Entity, res: *Resources, gi: u16) void {
    const cat = &res.catalog;
    const goods = w.get(e, comp.Goods) orelse return;
    const was = goods.count[gi];
    const units: u32 = 1;
    goods.count[gi] += units;
    if (was == 0) {
        settle(w, e, cat);
        ensureIfGenerating(w, e, cat);
    }
    var receipt = ledger.Receipt{};
    receipt.add(.{ .good = gi }, @floatFromInt(units));
    _ = res.events.writer(events.WorkDone).push(.{
        .agent = e,
        .doing = .{ .build = gi },
        .receipt = receipt,
        .owned = goods.count[gi],
        .act = migration.actOf(w, e),
    });
    _ = res.events.writer(events.GoodsChanged).push(.{ .agent = e });
}

/// Own `units` more of a good that arrived without a build (a trade). The effect lands once,
/// on the way in from absent. Emits `GoodsChanged`; the trade states its own outcome.
pub fn acquire(w: *World, e: Entity, res: *Resources, gi: u16, units: u32) void {
    const goods = w.get(e, comp.Goods) orelse return;
    const was = goods.count[gi];
    goods.count[gi] += units;
    if (was == 0 and units > 0) {
        settle(w, e, &res.catalog);
        ensureIfGenerating(w, e, &res.catalog);
    }
    if (units > 0) _ = res.events.writer(events.GoodsChanged).push(.{ .agent = e });
}

/// Lose up to `units` of a good, spares first; the effect leaves with the last unit.
/// Emits `GoodsChanged` when any left. Returns how many actually left.
pub fn release(w: *World, e: Entity, res: *Resources, gi: u16, units: u32) u32 {
    const goods = w.get(e, comp.Goods) orelse return 0;
    const had = goods.count[gi];
    const taken = @min(had, units);
    goods.count[gi] -= taken;
    if (had > 0 and goods.count[gi] == 0) settle(w, e, &res.catalog);
    if (taken > 0) _ = res.events.writer(events.GoodsChanged).push(.{ .agent = e });
    return taken;
}

/// Break one unit: `release` plus `GoodBroke`. Nothing calls it (goods have no durability); it
/// is the one path for losing a good to breakage.
pub fn break_one(w: *World, e: Entity, res: *Resources, gi: u16) void {
    if (release(w, e, res, gi, 1) == 0) return;
    _ = res.events.writer(events.GoodBroke).push(.{ .agent = e, .gi = gi });
}

/// Abandon a build in progress: salvage `config.cancel_refund` of the build's resources and
/// free the body. The energy and every hour already spent are gone — this is an exit from a
/// four-day build with an emptying larder, not an undo. The refund is flat rather than
/// prorated because the resources are charged in full at `begin` and nothing draws them down
/// over time. Refuses on a labor verb (half-foraging is not a thing you can take materials back
/// from) and on an idle body, returning `nothing_to_cancel`; otherwise emits `BuildCancelled`
/// with what came back and returns null.
pub fn cancel_build(w: *World, e: Entity, res: *Resources) ?Reason {
    const busy = w.get(e, comp.Busy) orelse return .nothing_to_cancel;
    const gi = switch (busy.doing) {
        .build => |g| g,
        .labor => return .nothing_to_cancel,
    };
    const cat = &res.catalog;
    const refund = ledger.refund(w, e, &cat.goods[gi].requires, res.config.cancel_refund);
    w.remove(e, comp.Busy);
    _ = res.events.writer(events.BuildCancelled).push(.{ .agent = e, .gi = gi, .refund = refund, .act = migration.actOf(w, e) });
    return null;
}

/// Every change of ownership ends here: the body and larder take the goods' contribution.
/// Public for a fixture that sets counts by hand.
pub fn settle(w: *World, e: Entity, cat: *const Catalog) void {
    effects.apply(w, e, cat);
}


/// A record name in sentence position — "Your fishing rod broke." — by lowering the first
/// letter; names are authored in sentence case.
pub fn lowerName(name: []const u8, buf: *[48]u8) []const u8 {
    const n = @min(name.len, buf.len);
    @memcpy(buf[0..n], name[0..n]);
    if (n > 0) buf[0] = std.ascii.toLower(buf[0]);
    return buf[0..n];
}

// --- generators ---------------------------------------------------------------------------

/// Where a held generator's cycle stands: the standing `comp.Quotes` carries per generator.
pub const GeneratorStanding = comp.Quotes.GeneratorStanding;

/// One held generator verb's authoritative state and collection gate.
pub const GeneratorQuote = struct {
    ai: u16,
    rec: *const roster.Action,
    /// The verb's effective terms: the cycle's hours, the collection's energy and resources,
    /// and the yield.
    verb: effects.Verb,
    standing: GeneratorStanding,
    progress: f32,
    total: f32,
    short: ?roster.Resource = null,

    pub fn ready(self: GeneratorQuote) bool {
        return self.standing == .ready;
    }

    pub fn fraction(self: GeneratorQuote) f32 {
        if (self.total <= 0) return 1;
        return std.math.clamp(self.progress / self.total, 0, 1);
    }
};

fn ensureGenerators(w: *World, e: Entity) *comp.Generators {
    if (w.get(e, comp.Generators)) |state| return state;
    w.add(e, comp.Generators{});
    return w.get(e, comp.Generators).?;
}

/// Give the agent its generator state once it holds a generator verb, so the cycle starts
/// accumulating; an agent that holds none is left without one.
fn ensureIfGenerating(w: *World, e: Entity, cat: *const Catalog) void {
    if (w.has(e, comp.Generators)) return;
    for (cat.actions, 0..) |a, i| {
        if (a.generator and actions.holds(w, e, cat, @intCast(i))) {
            w.add(e, comp.Generators{});
            return;
        }
    }
}

/// The first generator verb whose gate names the good `id`, if one does: what its BUILD row
/// calls a generator and a fixture's mode corner names.
pub fn generatorOf(cat: *const Catalog, id: []const u8) ?u16 {
    return gatedBy(cat, id, true);
}

/// The first verb whose gate names the good `id`, if one does: the verb owning it opens.
pub fn opens(cat: *const Catalog, id: []const u8) ?u16 {
    return gatedBy(cat, id, false);
}

fn gatedBy(cat: *const Catalog, id: []const u8, generator_only: bool) ?u16 {
    for (cat.actions, 0..) |a, i| {
        if (generator_only and !a.generator) continue;
        for ([_][]const []const u8{ a.requires.any, a.requires.all }) |list| for (list) |gate| {
            if (std.mem.eql(u8, gate, id)) return @intCast(i);
        };
    }
    return null;
}

/// Quote collection without consulting `Busy`: generators mature beside body-occupying work.
/// Null when `ai` is not a generator verb the agent holds, or the agent has no generator state
/// or no body.
pub fn generator_quote(w: *const World, e: Entity, cat: *const Catalog, cfg: res_mod.Config, ai: u16) ?GeneratorQuote {
    const rec = &cat.actions[ai];
    if (!rec.generator) return null;
    const v = actions.verbOf(w, e, cat, ai) orelse return null;
    const state = w.get(e, comp.Generators) orelse return null;
    const vigor = w.get(e, comp.Vigor) orelse return null;
    const total = res_mod.hours_to_secs(v.requires.hours, cfg.secs_per_day);
    const progress = @min(state.progress[ai], total);
    var q = GeneratorQuote{ .ai = ai, .rec = rec, .verb = v, .standing = .ready, .progress = progress, .total = total };
    if (state.mode[ai] == .off) {
        q.standing = .off;
    } else if (progress < total) {
        q.standing = .charging;
    } else if (v.requires.energy >= vigor.v) {
        q.standing = .energy;
    } else if (ledger.short(w, e, &v.requires, 1)) |r| {
        q.standing = .short;
        q.short = r;
    }
    return q;
}

/// Accumulate every held generator verb that is not `off` toward readiness, then collect every
/// `auto` generator whose quote is ready, through the same settlement a player's collection
/// takes (`collect`). An `auto` generator the agent cannot pay for (`energy`, `short`) keeps its
/// full cycle and is collected on the first frame it can be; one whose verb is no longer held
/// keeps its progress and does not accumulate. `Busy` is deliberately ignored. The collections
/// run after the query, since a collection writes beyond the iterated storages.
pub fn run_generators(w: *World, res: *Resources) void {
    const cat = &res.catalog;
    var due: [ecs.MAX_ENTITIES]Entity = undefined;
    var n: usize = 0;
    var q: ecs.Query(.{ Entity, comp.Generators }) = .{ .world = w };
    var it = q.iter();
    while (it.next()) |entry| {
        const e: Entity = entry[0];
        const state: *comp.Generators = entry[1];
        var auto_full = false;
        for (cat.actions, 0..) |rec, i| {
            if (!rec.generator or state.mode[i] == .off) continue;
            const v = actions.verbOf(w, e, cat, @intCast(i)) orelse continue;
            const total = res_mod.hours_to_secs(v.requires.hours, res.config.secs_per_day);
            state.progress[i] = @min(total, state.progress[i] + res.time.dt);
            if (state.mode[i] == .auto and state.progress[i] >= total) auto_full = true;
        }
        if (auto_full) {
            due[n] = e;
            n += 1;
        }
    }
    for (due[0..n]) |e| {
        for (cat.actions, 0..) |rec, i| {
            if (!rec.generator) continue;
            const ai: u16 = @intCast(i);
            const state = w.get(e, comp.Generators) orelse break;
            if (state.mode[ai] != .auto) continue;
            const gq = generator_quote(w, e, cat, res.config, ai) orelse continue;
            if (gq.ready()) collect(w, e, res, gq);
        }
    }
}

/// Move a generator to its next mode: on, auto, off, then on again (`Generators.Mode.next`).
/// Every mode keeps the accumulated progress. Returns `unavailable`, changing nothing, for a
/// verb that is not a generator the agent holds.
pub fn toggle_generator(w: *World, e: Entity, cat: *const Catalog, ai: u16) ?Reason {
    if (ai >= cat.actions.len or !cat.actions[ai].generator) return .unavailable;
    if (!actions.holds(w, e, cat, ai)) return .unavailable;
    const state = ensureGenerators(w, e);
    state.mode[ai] = state.mode[ai].next();
    return null;
}

/// The player's collection: refuses unless the quote is ready, then settles the cycle
/// (`collect`). This never creates or inspects `Busy`, so collecting does not interrupt other
/// work. Returns why it refused (`unavailable` for a verb that is not a held generator, else
/// the quote's standing), changing nothing, or null.
pub fn collect_generator(w: *World, e: Entity, res: *Resources, ai: u16) ?Reason {
    const cat = &res.catalog;
    if (ai >= cat.actions.len) return .unavailable;
    const q = generator_quote(w, e, cat, res.config, ai) orelse return .unavailable;
    switch (q.standing) {
        .ready => {},
        .charging => return .not_ready,
        .off => return .off,
        .energy => return .energy,
        .short => return .short,
    }
    collect(w, e, res, q);
    return null;
}

/// Settle one ready cycle, the one path for both a player's and an `auto` collection: pay the
/// verb's energy from vigor and its resources, draw its yield, restore its vigor, refresh the
/// condition band, restart accumulation and emit `Collected`. `q` must be ready.
fn collect(w: *World, e: Entity, res: *Resources, q: GeneratorQuote) void {
    std.debug.assert(q.ready());
    const ai = q.ai;
    const vigor = w.get(e, comp.Vigor).?;
    vigor.v -= q.verb.requires.energy;
    ledger.pay(w, e, &q.verb.requires, 1);
    const receipt = ledger.draw(w, e, &q.verb.output, res.random(), 1, 1);
    const restored = @max(0, @min(q.verb.output.vigor, vigor.max - vigor.v));
    vigor.v += restored;
    // A collection's net toll is the collection's, not hunger: the band takes it silently
    // (`rules/condition`).
    if (w.get(e, comp.Condition)) |c| _ = condition.refresh(&res.config, vigor, c);
    ensureGenerators(w, e).progress[ai] = 0;
    _ = res.events.writer(events.Collected).push(.{ .agent = e, .ai = ai, .receipt = receipt, .vigor = restored, .act = migration.actOf(w, e) });
}

// ============================ Tests ==========================================

const testing = std.testing;

/// The simulation's resources with the shipped catalog. The caller deinits the catalog.
fn test_res() !Resources {
    return test_res_over(roster.shipped);
}

fn test_res_over(src: roster.Sources) !Resources {
    return .{
        .sim = .{ .prng = std.Random.DefaultPrng.init(7) },
        .catalog = try roster.load(testing.allocator, src, null),
    };
}

/// Word the facts the rules emitted, as the frame's log system does.
fn logged(w: *World, res: *Resources) void {
    world.run(w, res, @import("../systems/log.zig").log);
}

fn spawn_test_agent(w: *World, materials: f32) Entity {
    return w.spawn(.{
        comp.Vigor{ .v = 10, .max = 10 },
        comp.InventoryFood{ .v = 0, .quality = 1, .spoils = 0.05 },
        comp.InventoryBiomass{ .v = materials },
        comp.Goods{},
        comp.Granted{},
    });
}

fn count(w: *World, e: Entity, cat: *const Catalog, id: []const u8) u32 {
    return w.get(e, comp.Goods).?.count[cat.goodIndex(id).?];
}

fn heldVerb(w: *World, e: Entity, cat: *const Catalog, id: []const u8) bool {
    return effects.held(cat, effects.holdingsOf(w, e).?, cat.actionIndex(id).?);
}

test "build pays upfront and starts the work; finish owns the spear and opens the verb" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    var res = try test_res();
    defer res.catalog.deinit();
    const cat = &res.catalog;
    const rod = cat.goodIndex("spear").?;
    const price = cat.goods[rod].requires;
    const order = cat.goods[rod].requires.biomass;
    const e = spawn_test_agent(&w, order); // exactly the order — spendable to 0
    try testing.expect(!heldVerb(&w, e, cat, "hunt")); // no spear, no verb

    try testing.expect(begin(&w, e, &res, rod) == null);

    // Paid and busy — the spear doesn't exist until the work completes.
    try testing.expectEqual(@as(u32, 0), count(&w, e, cat, "spear"));
    try testing.expect(!heldVerb(&w, e, cat, "hunt"));
    try testing.expectEqual(10 - price.energy, w.get(e, comp.Vigor).?.v);
    try testing.expectEqual(@as(f32, 0), w.get(e, comp.InventoryBiomass).?.v); // spent to 0
    const b = w.get(e, comp.Busy).?;
    try testing.expect(b.isBuild(rod));
    try testing.expectEqual(res_mod.hours_to_secs(price.hours, res.config.secs_per_day), b.total);

    finish(&w, e, &res, rod);
    logged(&w, &res);
    try testing.expectEqual(@as(u32, 1), count(&w, e, cat, "spear"));
    try testing.expect(heldVerb(&w, e, cat, "hunt")); // the unlock
    try testing.expectEqual(@as(usize, 1), res.sim.log.count);
    try testing.expectEqualStrings(cat.goods[rod].copy.built, res.sim.log.get(0).text());
}

test "begin refuses when unaffordable or busy; the quote says why" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    var res = try test_res();
    defer res.catalog.deinit();
    const cat = &res.catalog;
    const rod = cat.goodIndex("spear").?;
    const order = cat.goods[rod].requires.biomass;
    const e = spawn_test_agent(&w, order - 1); // one material short

    try testing.expectEqual(Standing.short, quote(&w, e, cat, rod).?.standing);
    try testing.expectEqual(roster.Resource.biomass, quote(&w, e, cat, rod).?.short.?);
    try testing.expectEqual(Reason.short, begin(&w, e, &res, rod).?);
    try testing.expect(!w.has(e, comp.Busy)); // refused, no work started
    try testing.expectEqual(@as(f32, 10), w.get(e, comp.Vigor).?.v); // unpaid

    w.get(e, comp.InventoryBiomass).?.v = order + 12;
    _ = begin(&w, e, &res, rod); // starts the build
    try testing.expectEqual(Standing.busy, quote(&w, e, cat, rod).?.standing);
    try testing.expectEqual(Reason.busy, begin(&w, e, &res, rod).?); // must refuse, not double-pay
    try testing.expectEqual(@as(f32, 12), w.get(e, comp.InventoryBiomass).?.v); // paid once

    w.remove(e, comp.Busy);
    finish(&w, e, &res, rod);
    try testing.expectEqual(@as(u32, 1), quote(&w, e, cat, rod).?.count); // owned, and still buildable
    _ = begin(&w, e, &res, rod); // 12 materials short of a second
    try testing.expect(!w.has(e, comp.Busy));
}

test "a repeat build is stock: the count rises, the effect does not" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    var res = try test_res();
    defer res.catalog.deinit();
    const cat = &res.catalog;
    const sandals = cat.goodIndex("sandals").?;
    const forage = cat.actionIndex("forage").?;
    const e = spawn_test_agent(&w, cat.goods[sandals].requires.biomass * 3);
    w.add(e, comp.Verbs.of(cat, &.{"forage"}));
    const base = effects.verb(cat, effects.holdingsOf(&w, e).?, forage).?.requires.energy;

    _ = begin(&w, e, &res, sandals);
    finish(&w, e, &res, sandals);
    w.remove(e, comp.Busy);
    const once = effects.verb(cat, effects.holdingsOf(&w, e).?, forage).?.requires.energy;
    try testing.expectEqual(@as(u32, 1), count(&w, e, cat, "sandals"));
    try testing.expect(once < base); // the first pair is capital in use

    _ = begin(&w, e, &res, sandals);
    finish(&w, e, &res, sandals);
    w.remove(e, comp.Busy);
    try testing.expectEqual(@as(u32, 2), count(&w, e, cat, "sandals"));
    try testing.expectEqual(once, effects.verb(cat, effects.holdingsOf(&w, e).?, forage).?.requires.energy); // no second discount
    logged(&w, &res);
    try testing.expectEqualStrings("Another sandals. You have 2.", res.sim.log.get(0).text());
    try testing.expectEqual(@as(u32, 1), goodsOwned(&w, e, cat)); // kinds, not units

    // Losing a spare keeps the discount; losing the last pair takes it back.
    break_one(&w, e, &res, sandals);
    try testing.expectEqual(@as(u32, 1), count(&w, e, cat, "sandals"));
    try testing.expectEqual(once, effects.verb(cat, effects.holdingsOf(&w, e).?, forage).?.requires.energy);
    break_one(&w, e, &res, sandals);
    try testing.expectEqual(@as(u32, 0), count(&w, e, cat, "sandals"));
    try testing.expectEqual(base, effects.verb(cat, effects.holdingsOf(&w, e).?, forage).?.requires.energy);
    logged(&w, &res);
    try testing.expectEqualStrings("Your sandals broke.", res.sim.log.get(0).text());
}

test "the hatchet unlocks splitting wood; a modifier on it refuses until then" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    var res = try test_res();
    defer res.catalog.deinit();
    const cat = &res.catalog;
    const e = spawn_test_agent(&w, 100);
    const hatchet = cat.goodIndex("hatchet").?;
    const gloves = cat.goodIndex("work_gloves").?;
    try testing.expect(!heldVerb(&w, e, cat, "chop_wood")); // not held bare-handed

    // No hatchet ⟹ no Split wood ⟹ gloves have nothing to improve.
    try testing.expectEqual(Standing.needs, quote(&w, e, cat, gloves).?.standing);
    try testing.expectEqual(Reason.needs, begin(&w, e, &res, gloves).?);
    try testing.expect(!w.has(e, comp.Busy)); // refused, not a panic
    try testing.expectEqual(@as(f32, 100), w.get(e, comp.InventoryBiomass).?.v); // unpaid

    acquire(&w, e, &res, hatchet, 1);
    try testing.expect(heldVerb(&w, e, cat, "chop_wood"));
    try testing.expect(gatesMet(&w, e, cat, gloves));
    _ = begin(&w, e, &res, gloves);
    try testing.expect(w.has(e, comp.Busy));
    w.remove(e, comp.Busy);

    break_one(&w, e, &res, hatchet);
    try testing.expect(!heldVerb(&w, e, cat, "chop_wood")); // the verb leaves with the tool
}

test "a generator accumulates without moving resources and settles only when collected" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    var res = try test_res();
    defer res.catalog.deinit();
    res.time = .{ .dt = res.config.secs_per_day }; // one full day per tick
    const e = w.spawn(.{
        comp.Vigor{ .v = 10, .max = 10 },
        comp.InventoryFood{ .v = 0, .quality = 1, .spoils = 0 },
        comp.InventoryBiomass{ .v = 0.2 }, // exactly one two-day cycle of upkeep
        comp.Goods{},
        comp.Generators{},
        comp.Granted{},
    });
    const garden = res.catalog.actionIndex("tend_garden").?;
    w.get(e, comp.Goods).?.count[res.catalog.goodIndex("garden_bed").?] = 1;

    run_generators(&w, &res); // halfway through a 48h cycle
    try testing.expectApproxEqAbs(@as(f32, 0.2), w.get(e, comp.InventoryBiomass).?.v, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), w.get(e, comp.InventoryFood).?.v, 1e-6);
    try testing.expectEqual(GeneratorStanding.charging, generator_quote(&w, e, &res.catalog, res.config, garden).?.standing);

    run_generators(&w, &res); // ready, but still no automatic settlement
    try testing.expect(generator_quote(&w, e, &res.catalog, res.config, garden).?.ready());
    try testing.expectApproxEqAbs(@as(f32, 0), w.get(e, comp.InventoryFood).?.v, 1e-6);
    try testing.expect(collect_generator(&w, e, &res, garden) == null);
    try testing.expectApproxEqAbs(@as(f32, 0), w.get(e, comp.InventoryBiomass).?.v, 1e-6);
    try testing.expect(w.get(e, comp.InventoryFood).?.v > 0);
    try testing.expectEqual(GeneratorStanding.charging, generator_quote(&w, e, &res.catalog, res.config, garden).?.standing);
}

/// An agent owning one garden bed, its generator state fresh, with `biomass` on hand.
fn spawn_gardener(w: *World, cat: *const Catalog, biomass: f32) Entity {
    const e = w.spawn(.{
        comp.Vigor{ .v = 10, .max = 10 },
        comp.InventoryFood{ .v = 0, .quality = 1, .spoils = 0 },
        comp.InventoryBiomass{ .v = biomass },
        comp.Goods{},
        comp.Generators{},
        comp.Granted{},
    });
    w.get(e, comp.Goods).?.count[cat.goodIndex("garden_bed").?] = 1;
    return e;
}

test "the toggle cycles a generator on, auto, off and on again, keeping its progress" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    var res = try test_res();
    defer res.catalog.deinit();
    const cat = &res.catalog;
    const garden = cat.actionIndex("tend_garden").?;
    const e = spawn_gardener(&w, cat, 0);
    const state = w.get(e, comp.Generators).?;
    state.progress[garden] = 3;

    try testing.expectEqual(comp.Generators.Mode.on, state.mode[garden]);
    for ([_]comp.Generators.Mode{ .auto, .off, .on }) |want| {
        try testing.expect(toggle_generator(&w, e, cat, garden) == null);
        try testing.expectEqual(want, state.mode[garden]);
        try testing.expectEqual(@as(f32, 3), state.progress[garden]);
    }
}

test "an off generator keeps its progress; on accumulates and waits for the player" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    var res = try test_res();
    defer res.catalog.deinit();
    const cat = &res.catalog;
    const garden = cat.actionIndex("tend_garden").?;
    const total = res_mod.hours_to_secs(cat.actions[garden].requires.hours, res.config.secs_per_day);
    const e = spawn_gardener(&w, cat, 1);
    const state = w.get(e, comp.Generators).?;
    state.progress[garden] = 3;
    state.mode[garden] = .off;
    res.time = .{ .dt = total };

    run_generators(&w, &res);
    try testing.expectEqual(@as(f32, 3), state.progress[garden]);
    try testing.expectEqual(GeneratorStanding.off, generator_quote(&w, e, cat, res.config, garden).?.standing);

    state.mode[garden] = .on;
    run_generators(&w, &res);
    try testing.expectEqual(total, state.progress[garden]); // full, and uncollected
    try testing.expectEqual(@as(f32, 0), w.get(e, comp.InventoryFood).?.v);
}

test "a generator whose good is gone keeps its progress and does not accumulate" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    var res = try test_res();
    defer res.catalog.deinit();
    const cat = &res.catalog;
    const garden = cat.actionIndex("tend_garden").?;
    const bed = cat.goodIndex("garden_bed").?;
    const e = spawn_gardener(&w, cat, 1);
    const state = w.get(e, comp.Generators).?;
    state.progress[garden] = 3;
    state.mode[garden] = .auto;
    res.time = .{ .dt = 5 };

    try testing.expectEqual(@as(u32, 1), release(&w, e, &res, bed, 1));
    run_generators(&w, &res);
    try testing.expectEqual(@as(f32, 3), state.progress[garden]);
    try testing.expectEqual(comp.Generators.Mode.auto, state.mode[garden]);
    try testing.expect(generator_quote(&w, e, cat, res.config, garden) == null);
    try testing.expectEqual(Reason.unavailable, collect_generator(&w, e, &res, garden).?);

    acquire(&w, e, &res, bed, 2); // a second bed is stock: one cycle runs
    run_generators(&w, &res);
    try testing.expectEqual(@as(f32, 8), state.progress[garden]);
}

test "an auto generator collects itself in the run that completes its cycle" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    var res = try test_res();
    defer res.catalog.deinit();
    const cat = &res.catalog;
    const garden = cat.actionIndex("tend_garden").?;
    const spec = cat.actions[garden].requires;
    const e = spawn_gardener(&w, cat, 0.2); // exactly one two-day cycle of upkeep
    w.get(e, comp.Generators).?.mode[garden] = .auto;
    res.time = .{ .dt = res.config.secs_per_day }; // one full day per tick
    res.events.update();

    run_generators(&w, &res); // halfway through a 48h cycle
    try testing.expectEqual(@as(f32, 0), w.get(e, comp.InventoryFood).?.v);
    try testing.expectEqual(@as(usize, 0), res.events.len(events.Collected));

    run_generators(&w, &res); // the cycle completes and is collected in the same run
    try testing.expectEqual(@as(f32, 0), w.get(e, comp.Generators).?.progress[garden]);
    try testing.expect(w.get(e, comp.InventoryFood).?.v > 0);
    try testing.expectApproxEqAbs(@as(f32, 0), w.get(e, comp.InventoryBiomass).?.v, 1e-6);
    try testing.expectApproxEqAbs(@min(10, 10 - spec.energy + cat.actions[garden].output.vigor), w.get(e, comp.Vigor).?.v, 1e-6);
    var cursor: u64 = 0;
    try testing.expectEqual(garden, res.events.readerAt(events.Collected, &cursor).next().?.ai);
    try testing.expectEqual(comp.Generators.Mode.auto, w.get(e, comp.Generators).?.mode[garden]);
}

test "an auto generator the agent cannot pay for waits with its full cycle, then collects" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    var res = try test_res();
    defer res.catalog.deinit();
    const cat = &res.catalog;
    const garden = cat.actionIndex("tend_garden").?;
    const spec = cat.actions[garden].requires;
    const total = res_mod.hours_to_secs(spec.hours, res.config.secs_per_day);
    const e = spawn_gardener(&w, cat, 1);
    const state = w.get(e, comp.Generators).?;
    state.mode[garden] = .auto;
    state.progress[garden] = total;
    w.get(e, comp.Vigor).?.v = spec.energy; // energy is strict: vigor may not reach zero
    res.time = .{ .dt = 1 };
    res.events.update();

    run_generators(&w, &res);
    run_generators(&w, &res);
    try testing.expectEqual(GeneratorStanding.energy, generator_quote(&w, e, cat, res.config, garden).?.standing);
    try testing.expectEqual(total, state.progress[garden]);
    try testing.expectEqual(@as(f32, 0), w.get(e, comp.InventoryFood).?.v);
    try testing.expectEqual(spec.energy, w.get(e, comp.Vigor).?.v);
    try testing.expectEqual(@as(usize, 0), res.events.len(events.Collected));

    w.get(e, comp.Vigor).?.v = 10;
    run_generators(&w, &res);
    try testing.expectEqual(@as(f32, 0), state.progress[garden]);
    try testing.expect(w.get(e, comp.InventoryFood).?.v > 0);
    try testing.expectEqual(@as(usize, 1), res.events.len(events.Collected));
}

/// An agent stocked to build a shelter: the unlock's three conditions all met, and enough
/// materials for the price.
fn spawn_settler(w: *World, cat: *const Catalog) Entity {
    const e = w.spawn(.{
        comp.Vigor{ .v = 16, .max = 20 }, // 16 >= the absolute 15, max is irrelevant
        comp.InventoryFood{ .v = 25, .quality = 1, .spoils = 0 }, // >= the unlock's 12
        comp.InventoryBiomass{ .v = 100 }, // >= the 60 price
        comp.Goods{},
        comp.Granted{},
    });
    const goods = w.get(e, comp.Goods).?;
    for ([_][]const u8{ "sandals", "leaf_bed", "cookpot", "root_cellar", "wire_snares" }) |id| {
        goods.count[cat.goodIndex(id).?] = 1; // five goods owned >= the unlock's 5
    }
    return e;
}

test "the shelter is offered only once its standing conditions are met" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    var res = try test_res();
    defer res.catalog.deinit();
    const cat = &res.catalog;
    const shelter = cat.goodIndex("shelter").?;
    const e = spawn_settler(&w, cat);

    try testing.expectEqual(@as(u32, 5), goodsOwned(&w, e, cat));
    try testing.expect(unlockMet(&w, e, cat, shelter));
    try testing.expect(!ownsMilestone(&w, e, cat, .act_one));

    _ = begin(&w, e, &res, shelter);
    try testing.expect(w.get(e, comp.Busy).?.isBuild(shelter));
    try testing.expectEqual(@as(f32, 4), w.get(e, comp.Vigor).?.v); // 16 - 12 energy
    try testing.expectEqual(@as(f32, 40), w.get(e, comp.InventoryBiomass).?.v); // 100 - 60

    // Vigor fell below the absolute 15 mid-build — the work is already paid for, so it stands.
    try testing.expect(!unlockMet(&w, e, cat, shelter));

    finish(&w, e, &res, shelter);
    try testing.expect(ownsMilestone(&w, e, cat, .act_one));
    try testing.expectEqual(@as(u32, 4), capacity(&w, e, cat));
}

test "each standing condition refuses the shelter on its own" {
    var res = try test_res();
    defer res.catalog.deinit();
    const cat = &res.catalog;
    const shelter = cat.goodIndex("shelter").?;
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    // Too tired: below the absolute 15 current vigor refuses, regardless of the ceiling.
    {
        const e = spawn_settler(&w, cat);
        w.get(e, comp.Vigor).?.v = 7;
        try testing.expectEqual(Standing.unlock, quote(&w, e, cat, shelter).?.standing);
        try testing.expectEqual(Reason.unlock, begin(&w, e, &res, shelter).?);
        try testing.expect(!w.has(e, comp.Busy));
    }
    // Boundary: an *absolute* 15, independent of `max`.
    {
        const e = spawn_settler(&w, cat);
        const v = w.get(e, comp.Vigor).?;
        for ([_]f32{ 15, 20, 100 }) |ceiling| {
            v.max = ceiling;
            v.v = 14.99;
            try testing.expect(!unlockMet(&w, e, cat, shelter));
            v.v = 15;
            try testing.expect(unlockMet(&w, e, cat, shelter));
        }
    }
    // Larder too thin.
    {
        const e = spawn_settler(&w, cat);
        w.get(e, comp.InventoryFood).?.v = 11;
        try testing.expect(!unlockMet(&w, e, cat, shelter));
    }
    // Nothing built yet - a full larder is not a settled life.
    {
        const e = spawn_settler(&w, cat);
        w.get(e, comp.Goods).?.count[cat.goodIndex("sandals").?] = 0;
        try testing.expectEqual(@as(u32, 4), goodsOwned(&w, e, cat));
        try testing.expect(!unlockMet(&w, e, cat, shelter));
    }
}

test "a recipe that names a technology waits on the board" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    var res = try test_res_over(.{
        .actions =
        \\.{ .{ .id = "forage", .name = "Forage", .requires = .{ .energy = 1.0, .hours = 1.0 } } }
        ,
        .goods =
        \\.{ .{ .id = "oven", .name = "Oven", .act = 2, .tier = .crude,
        \\     .requires = .{ .energy = 1.0, .hours = 1.0, .biomass = 2.0, .tech = "kilns" } } }
        ,
        .technologies =
        \\.{ .{ .id = "kilns", .name = "Kilns", .coord = .{ .q = 1, .r = 0 },
        \\     .cost = .{ .food = 2.0 }, .initial = .available } }
        ,
    });
    defer res.catalog.deinit();
    const cat = &res.catalog;
    const oven = cat.goodIndex("oven").?;
    const kilns = cat.techIndex("kilns").?;
    const e = w.spawn(.{ comp.Vigor{ .v = 10, .max = 10 }, comp.InventoryBiomass{ .v = 2 }, comp.Goods{}, comp.Granted{} });

    // No board at all: nothing is researched.
    try testing.expectEqual(Standing.tech, quote(&w, e, cat, oven).?.standing);
    // The curtain's board carries the tile at its authored state — offered, not established.
    w.add(e, comp.Research.entry(cat));
    try testing.expectEqual(roster.TechState.available, w.get(e, comp.Research).?.state[kilns]);
    try testing.expectEqual(Standing.tech, quote(&w, e, cat, oven).?.standing);
    // Established: the recipe is offered, and `begin` runs.
    w.get(e, comp.Research).?.state[kilns] = .researched;
    try testing.expectEqual(Standing.ready, quote(&w, e, cat, oven).?.standing);
    _ = begin(&w, e, &res, oven);
    try testing.expect(w.get(e, comp.Busy).?.isBuild(oven));
}

test "a good with no unlock has no standing conditions, and a traded good has no quote" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    var res = try test_res();
    defer res.catalog.deinit();
    const cat = &res.catalog;
    const e = spawn_test_agent(&w, 0);
    try testing.expect(unlockMet(&w, e, cat, cat.goodIndex("fish_rod").?));
    try testing.expect(unlockMet(&w, e, cat, cat.goodIndex("chicken_coop").?));
    try testing.expect(quote(&w, e, cat, cat.goodIndex("fish_rod").?) == null);
}

test "cancel salvages half the build order, frees the body, and opens nothing" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    var res = try test_res();
    defer res.catalog.deinit();
    const cat = &res.catalog;
    const rod = cat.goodIndex("spear").?;
    const order = cat.goods[rod].requires.biomass;
    const price = cat.goods[rod].requires;
    const e = spawn_test_agent(&w, order);

    _ = begin(&w, e, &res, rod);
    try testing.expectEqual(@as(f32, 0), w.get(e, comp.InventoryBiomass).?.v); // paid in full

    try testing.expect(cancel_build(&w, e, &res) == null);
    logged(&w, &res);
    try testing.expect(!w.has(e, comp.Busy)); // the body is free again
    try testing.expectEqual(@as(u32, 0), count(&w, e, cat, "spear")); // and owns nothing for the trouble
    try testing.expect(!heldVerb(&w, e, cat, "hunt"));
    try testing.expectApproxEqAbs(order * res.config.cancel_refund, w.get(e, comp.InventoryBiomass).?.v, 1e-5);
    try testing.expectEqualStrings("You gave up on the spear. Salvaged 5 materials.", res.sim.log.get(0).text());
    // The energy is gone with the hours — cancelling is an exit, not an undo.
    try testing.expectEqual(10 - price.energy, w.get(e, comp.Vigor).?.v);
}

test "cancel refuses on labor, and on an idle body" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    var res = try test_res();
    defer res.catalog.deinit();
    const e = spawn_test_agent(&w, 5);

    try testing.expectEqual(Reason.nothing_to_cancel, cancel_build(&w, e, &res).?); // nothing in progress

    w.add(e, comp.Busy{ .doing = .{ .labor = res.catalog.actionIndex("forage").? }, .total = 10, .remaining = 4, .quality = 1 });
    try testing.expectEqual(Reason.nothing_to_cancel, cancel_build(&w, e, &res).?); // `Busy` covers labor too
    try testing.expect(w.has(e, comp.Busy)); // still foraging
    try testing.expectEqual(@as(f32, 5), w.get(e, comp.InventoryBiomass).?.v);
}

test "a bought tool supersedes the built one; selling it restores the next-best rank" {
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    var res = try test_res();
    defer res.catalog.deinit();
    const cat = &res.catalog;
    const rod = cat.goodIndex("fish_rod").?;
    const net = cat.goodIndex("fish_net").?;
    const fish = cat.actionIndex("fish").?;
    const e = spawn_test_agent(&w, 0);
    acquire(&w, e, &res, rod, 1);
    const base_energy = cat.actions[fish].requires.energy;
    try testing.expectEqual(base_energy, effects.verb(cat, effects.holdingsOf(&w, e).?, fish).?.requires.energy);

    acquire(&w, e, &res, net, 1); // rank 2: the stats replace the rod's, not stack
    try testing.expectApproxEqAbs(base_energy * 0.7, effects.verb(cat, effects.holdingsOf(&w, e).?, fish).?.requires.energy, 1e-6);
    try testing.expectEqual(@as(u32, 1), count(&w, e, cat, "fish_rod")); // the rod is still owned (sellable)

    try testing.expectEqual(@as(u32, 1), release(&w, e, &res, net, 1)); // sell the net
    try testing.expectEqual(base_energy, effects.verb(cat, effects.holdingsOf(&w, e).?, fish).?.requires.energy); // the rod's rank
    try testing.expectEqual(@as(u32, 1), release(&w, e, &res, rod, 1)); // sell the rod too
    try testing.expect(effects.verb(cat, effects.holdingsOf(&w, e).?, fish) == null); // no fishing tool left ⇒ the verb goes
    try testing.expectEqual(@as(u32, 0), release(&w, e, &res, rod, 1)); // nothing left to release
}

test "lowerName puts a sentence-case name into a sentence" {
    var buf: [48]u8 = undefined;
    try testing.expectEqualStrings("fishing rod", lowerName("Fishing rod", &buf));
    try testing.expectEqualStrings("", lowerName("", &buf));
}
