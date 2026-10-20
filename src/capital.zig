//! Capital: the build path over the authored roster, and what owning a good does.
//!
//! A good is a record in `data/goods.zon` (`roster.zig`); an agent owns it as a count on
//! `comp.Goods`. Building, buying, selling and breaking all move that count, and every change
//! of ownership *settles* the body and larder (`effects.apply`). What a good does to a **verb**
//! is never stored —
//! `effects.verb` derives it. `quote` is the one gate calculation: the BUILD row, `begin`, and
//! a future decider read the same answer.
//!
//! Two gates beside the price. `needs` — the verb or tool a modifier works on must be held
//! (the roster's only tech-tree edge: you need the hatchet before the tools that sharpen it).
//! `unlock` — standing conditions, read at `begin` and not again, so a dip mid-build doesn't
//! stop work already paid for. The affordability gates are asymmetric on purpose: energy is
//! strict (vigor may never reach zero), an item may be spent to exactly zero.
//!
//! Every good carries a count, and owning one is no reason you can't make another — building
//! for someone else is what a count is for. **Only the first unit carries the effect**: a
//! second pair of sandals is stock, not a deeper discount, so the effect lands on the way in
//! from absent and leaves with the last unit; losing a spare keeps it.

const std = @import("std");
const ha = @import("ha");
const comp = ha.comp;
const roster = ha.roster;
const effects = ha.effects;
const ledger = ha.ledger;
const ecs = @import("./ecs.zig");
const res_mod = @import("./res.zig");
const world = @import("./world.zig");

const World = world.World;
const Entity = world.Entity;
const Resources = res_mod.Resources;
const Catalog = roster.Catalog;

// --- the quote ---------------------------------------------------------------------------

/// Why a build cannot begin right now, or `ready`. The order is the precedence: a technology
/// not yet researched says "tech" before anything else, then a missing prerequisite "needs",
/// standing conditions before the body.
pub const Standing = enum { ready, tech, needs, unlock, busy, energy, short };

pub const Quote = struct {
    gi: u16,
    rec: *const roster.Good,
    /// Units already owned. Owning some is no reason not to build more.
    count: u32,
    standing: Standing,
    /// The first unpayable line of the build order when `standing == .short`.
    short: ?roster.Line = null,
    /// How close the build order is to affordable: the smallest held/needed over its
    /// once-inputs, 1 when it has none.
    reach: f32,

    pub fn ready(self: Quote) bool {
        return self.standing == .ready;
    }
};

/// The quote for good `gi`, or null when it is not buildable or the agent has no holdings.
pub fn quote(w: *World, e: Entity, cat: *const Catalog, gi: u16) ?Quote {
    const rec = &cat.goods[gi];
    if (!rec.buildable) return null;
    const goods = w.get(e, comp.Goods) orelse return null;
    const vigor = w.get(e, comp.Vigor) orelse return null;
    const price = rec.requires.?;
    const order = roster.Lines.only(rec.input, .once);
    var q = Quote{ .gi = gi, .rec = rec, .count = goods.count[gi], .standing = .ready, .reach = reachOf(w, e, cat, order.slice()) };
    if (!techMet(w, e, cat, gi)) {
        q.standing = .tech;
    } else if (!needsMet(w, e, cat, gi)) {
        q.standing = .needs;
    } else if (!unlockMet(w, e, cat, gi)) {
        q.standing = .unlock;
    } else if (w.has(e, comp.Busy)) {
        q.standing = .busy;
    } else if (price.energy >= vigor.v) {
        q.standing = .energy;
    } else if (ledger.short(w, e, cat, order.slice(), 1)) |l| {
        q.standing = .short;
        q.short = l;
    }
    return q;
}

fn reachOf(w: *World, e: Entity, cat: *const Catalog, order: []const roster.Line) f32 {
    var r: f32 = 1;
    for (order) |l| {
        if (l.n <= 0) continue;
        r = @min(r, ledger.held(w, e, cat, l) / l.n);
    }
    return r;
}

/// Whether the technology a recipe waits on is researched for this agent. No `tech` means
/// yes; an agent without a board has researched nothing.
pub fn techMet(w: *World, e: Entity, cat: *const Catalog, gi: u16) bool {
    const id = cat.goods[gi].tech orelse return true;
    const ti = cat.techIndex(id) orelse return false;
    const research = w.get(e, comp.Research) orelse return false;
    return research.state[ti] == .researched;
}

/// Whether every `needs` entry is held: a verb as `actions.holds` answers it, a tool by count.
pub fn needsMet(w: *World, e: Entity, cat: *const Catalog, gi: u16) bool {
    const goods = w.get(e, comp.Goods) orelse return false;
    for (cat.goods[gi].needs) |n| {
        if (cat.actionIndex(n)) |ai| {
            if (!ha.actions.holds(w, e, cat, ai)) return false;
        } else if (cat.goodIndex(n)) |ng| {
            if (goods.count[ng] == 0) return false;
        } else return false;
    }
    return true;
}

/// Whether the builder meets the good's standing conditions. No `unlock` means none.
pub fn unlockMet(w: *World, e: Entity, cat: *const Catalog, gi: u16) bool {
    const u = cat.goods[gi].unlock orelse return true;
    const vigor = w.get(e, comp.Vigor) orelse return false;
    if (vigor.v < u.vigor_abs) return false; // absolute current vigor, not a fraction
    if (ledger.balance(w, e, .food) < u.food) return false;
    return goodsOwned(w, e, cat) >= u.goods;
}

/// How many buildable good **kinds** the agent owns — four pairs of sandals are one.
pub fn goodsOwned(w: *World, e: Entity, cat: *const Catalog) u32 {
    const goods = w.get(e, comp.Goods) orelse return 0;
    var n: u32 = 0;
    for (cat.goods, 0..) |g, gi| {
        if (g.buildable and goods.count[gi] > 0) n += 1;
    }
    return n;
}

pub fn owns(w: *World, e: Entity, cat: *const Catalog, id: []const u8) bool {
    const goods = w.get(e, comp.Goods) orelse return false;
    const gi = cat.goodIndex(id) orelse return false;
    return goods.count[gi] > 0;
}

/// Whether the agent owns the good that ends `m` — what the curtain routes on.
pub fn ownsMilestone(w: *World, e: Entity, cat: *const Catalog, m: roster.Milestone) bool {
    const goods = w.get(e, comp.Goods) orelse return false;
    for (cat.goods, 0..) |g, gi| {
        if (g.milestone == m and goods.count[gi] > 0) return true;
    }
    return false;
}

/// How many humans the agent's goods house.
pub fn capacity(w: *World, e: Entity, cat: *const Catalog) u32 {
    const goods = w.get(e, comp.Goods) orelse return 0;
    var n: u32 = 0;
    for (cat.goods, 0..) |g, gi| {
        if (goods.count[gi] > 0) n += g.capacity;
    }
    return n;
}

// --- build / acquire / release ------------------------------------------------------------

/// Begin building `gi`: pay the price and the build order upfront and start the work — the
/// good, and whatever it does, arrives only when `finish` resolves, `requires.hours` later.
/// Refuses silently when the quote is not ready. Dying mid-build loses the work.
pub fn begin(w: *World, e: Entity, res: *Resources, gi: u16) void {
    const cat = &res.catalog;
    const q = quote(w, e, cat, gi) orelse return;
    if (!q.ready()) return;
    const price = q.rec.requires.?;
    w.get(e, comp.Vigor).?.v -= price.energy;
    ledger.pay(w, e, cat, roster.Lines.only(q.rec.input, .once).slice(), 1);
    const total = res_mod.hours_to_secs(price.hours, res.config.secs_per_day);
    // quality is a labor concept — a build either completes or it doesn't, so lock 1.
    w.add(e, comp.Busy{ .doing = .{ .build = gi }, .total = total, .remaining = total, .quality = 1 });
}

/// Completion of a build: own the lot, settle its effect if this is the first unit, log the
/// receipt. Called by `systems.resolve_busy`.
pub fn finish(w: *World, e: Entity, res: *Resources, gi: u16) void {
    const cat = &res.catalog;
    const goods = w.get(e, comp.Goods) orelse return;
    const rec = &cat.goods[gi];
    if (rec.generator != null) _ = ensureGenerators(w, e);
    const was = goods.count[gi];
    goods.count[gi] += lot(rec);
    if (was > 0) {
        // A repeat build is stock, not a second effect: count it and say so.
        var nbuf: [48]u8 = undefined;
        var buf: [80]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Another {s}. You have {d}.", .{ lowerName(rec.name, &nbuf), goods.count[gi] }) catch "You made another.";
        res.sim.log.push(.good, msg);
        return;
    }
    settle(w, e, cat);
    res.sim.log.push(.good, if (rec.copy.built.len > 0) rec.copy.built else "You built it.");
}

/// Own `units` more of a good that arrived without a build (a trade). The effect lands once,
/// on the way in from absent. Silent: the trade writes its own line.
pub fn acquire(w: *World, e: Entity, res: *Resources, gi: u16, units: u32) void {
    const goods = w.get(e, comp.Goods) orelse return;
    if (units > 0 and res.catalog.goods[gi].generator != null) _ = ensureGenerators(w, e);
    const was = goods.count[gi];
    goods.count[gi] += units;
    if (was == 0 and units > 0) settle(w, e, &res.catalog);
}

/// Lose up to `units` of a good, spares first; the effect leaves with the last unit.
/// Silent. Returns how many actually left.
pub fn release(w: *World, e: Entity, res: *Resources, gi: u16, units: u32) u32 {
    const goods = w.get(e, comp.Goods) orelse return 0;
    const had = goods.count[gi];
    const taken = @min(had, units);
    goods.count[gi] -= taken;
    if (had > 0 and goods.count[gi] == 0) {
        if (w.get(e, comp.Generators)) |state| {
            state.progress[gi] = 0;
            state.off[gi] = false;
        }
        settle(w, e, &res.catalog);
    }
    return taken;
}

/// Break one unit: `release` plus the receipt line. Nothing calls this yet (no durability);
/// it exists so losing a good has one path.
pub fn break_one(w: *World, e: Entity, res: *Resources, gi: u16) void {
    if (release(w, e, res, gi, 1) == 0) return;
    var nbuf: [48]u8 = undefined;
    var buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Your {s} broke.", .{lowerName(res.catalog.goods[gi].name, &nbuf)}) catch "Something of yours broke.";
    res.sim.log.push(.warn, msg);
}

/// Abandon a build in progress: salvage `config.cancel_refund` of the build order and free
/// the body. The energy and every hour already spent are gone — this is an exit from a
/// four-day build with an emptying larder, not an undo. The refund is flat rather than
/// prorated because the order is charged in full at `begin` and nothing draws it down over
/// time. Refuses on a labor verb (half-foraging is not a thing you can take materials back
/// from). Returns whether it cancelled.
pub fn cancel_build(w: *World, e: Entity, res: *Resources) bool {
    const busy = w.get(e, comp.Busy) orelse return false;
    const gi = switch (busy.doing) {
        .build => |g| g,
        .labor => return false,
    };
    const cat = &res.catalog;
    const rec = &cat.goods[gi];
    var salvaged: f32 = 0;
    var first: ?[]const u8 = null;
    for (rec.input) |l| {
        if (l.per != .once) continue;
        const back = l.n * res.config.cancel_refund;
        _ = ledger.give(w, e, cat, l.item, back);
        salvaged += back;
        if (first == null) first = l.item;
    }
    w.remove(e, comp.Busy);
    var nbuf: [48]u8 = undefined;
    var buf: [96]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "You gave up on the {s}. Salvaged {d:.0} {s}.", .{
        lowerName(rec.name, &nbuf),
        salvaged,
        if (first) |item| ha.actions.itemWord(cat, item, ha.migration.actOf(w, e)) else "units",
    }) catch "You gave up on the build.";
    res.sim.log.push(.warn, msg);
    return true;
}

/// Every change of ownership ends here: the body and larder take the goods' contribution.
/// Public for a fixture that sets counts by hand.
pub fn settle(w: *World, e: Entity, cat: *const Catalog) void {
    effects.apply(w, e, cat);
}

/// A built lot: a once-output naming the good itself, else one unit.
fn lot(rec: *const roster.Good) u32 {
    for (rec.output) |l| {
        if (l.per == .once and std.mem.eql(u8, l.item, rec.id)) return @intFromFloat(@round(l.n));
    }
    return 1;
}

/// A record name in sentence position — "Your fishing rod broke." — by lowering the first
/// letter; names are authored in sentence case.
pub fn lowerName(name: []const u8, buf: *[48]u8) []const u8 {
    const n = @min(name.len, buf.len);
    @memcpy(buf[0..n], name[0..n]);
    if (n > 0) buf[0] = std.ascii.toLower(buf[0]);
    return buf[0..n];
}

// --- collectable generators ---------------------------------------------------------------

pub const GeneratorStanding = enum { charging, off, ready, energy, short };

/// One owned generator's authoritative state and collection gate.
pub const GeneratorQuote = struct {
    gi: u16,
    rec: *const roster.Good,
    spec: roster.Generator,
    standing: GeneratorStanding,
    progress: f32,
    total: f32,
    cycle_days: f32,
    short: ?roster.Line = null,

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

/// Quote collection without consulting `Busy`: generators mature beside body-occupying work.
pub fn generator_quote(w: *World, e: Entity, cat: *const Catalog, cfg: res_mod.Config, gi: u16) ?GeneratorQuote {
    const rec = &cat.goods[gi];
    const spec = rec.generator orelse return null;
    const goods = w.get(e, comp.Goods) orelse return null;
    if (goods.count[gi] == 0) return null;
    const state = w.get(e, comp.Generators) orelse return null;
    const vigor = w.get(e, comp.Vigor) orelse return null;
    const total = res_mod.hours_to_secs(spec.hours, cfg.secs_per_day);
    const progress = @min(state.progress[gi], total);
    const cycle_days = spec.hours / 24.0;
    var q = GeneratorQuote{
        .gi = gi,
        .rec = rec,
        .spec = spec,
        .standing = .ready,
        .progress = progress,
        .total = total,
        .cycle_days = cycle_days,
    };
    if (state.off[gi]) {
        q.standing = .off;
    } else if (progress < total) {
        q.standing = .charging;
    } else if (spec.energy >= vigor.v) {
        q.standing = .energy;
    } else if (ledger.short(w, e, cat, roster.Lines.only(rec.input, .day).slice(), cycle_days)) |line| {
        q.standing = .short;
        q.short = line;
    }
    return q;
}

/// Accumulate owned, enabled generators to readiness. No resources move here and `Busy` is
/// deliberately ignored; the collection click is the sole settlement point.
pub fn run_generators(w: *World, res: *Resources) void {
    const cat = &res.catalog;
    var q: ecs.Query(.{ Entity, comp.Goods, comp.Generators }) = .{ .world = w };
    var it = q.iter();
    while (it.next()) |entry| {
        const goods: *comp.Goods = entry[1];
        const state: *comp.Generators = entry[2];
        for (cat.goods, 0..) |rec, gi| {
            const spec = rec.generator orelse continue;
            if (goods.count[gi] == 0 or state.off[gi]) continue;
            const total = res_mod.hours_to_secs(spec.hours, res.config.secs_per_day);
            state.progress[gi] = @min(total, state.progress[gi] + res.time.dt);
        }
    }
}

/// Toggle accumulation. Turning a generator off preserves its accumulated progress.
pub fn toggle_generator(w: *World, e: Entity, cat: *const Catalog, gi: u16) void {
    if (cat.goods[gi].generator == null) return;
    const goods = w.get(e, comp.Goods) orelse return;
    if (goods.count[gi] == 0) return;
    const state = ensureGenerators(w, e);
    state.off[gi] = !state.off[gi];
}

/// Atomically pay collection energy/upkeep, realize the cycle yield, and restart accumulation.
/// This never creates or inspects `Busy`, so collecting does not interrupt other work.
pub fn collect_generator(w: *World, e: Entity, res: *Resources, gi: u16) bool {
    const cat = &res.catalog;
    const q = generator_quote(w, e, cat, res.config, gi) orelse return false;
    if (!q.ready()) return false;

    const vigor = w.get(e, comp.Vigor).?;
    vigor.v -= q.spec.energy;
    ledger.pay(w, e, cat, roster.Lines.only(q.rec.input, .day).slice(), q.cycle_days);
    const receipt = ledger.draw(w, e, cat, roster.Lines.only(q.rec.output, .day).slice(), res.random(), 1, q.cycle_days);
    const restored = @min(q.spec.vigor, vigor.max - vigor.v);
    vigor.v += restored;
    ensureGenerators(w, e).progress[gi] = 0;

    var buf: [120]u8 = undefined;
    var wr = std.Io.Writer.fixed(&buf);
    wr.print("{s} cycle collected", .{q.rec.name}) catch {};
    if (receipt.len > 0 or restored > 0) {
        wr.writeAll(": ") catch {};
        var wrote = false;
        for (receipt.slice()) |d| {
            if (wrote) wr.writeAll(", ") catch {};
            wr.print("{d:.1} {s}", .{ d.amount, ha.actions.itemWord(cat, d.item, ha.migration.actOf(w, e)) }) catch {};
            wrote = true;
        }
        if (restored > 0) {
            if (wrote) wr.writeAll(", ") catch {};
            wr.print("+{d:.1} vigor", .{restored}) catch {};
        }
    }
    wr.writeAll(".") catch {};
    res.sim.log.push(.good, wr.buffered());
    return true;
}

// ============================ Tests ==========================================

const testing = std.testing;

/// A Resources with the groups the build path touches initialized — `platform` stays
/// undefined. The caller deinits the catalog.
fn test_res() !Resources {
    return test_res_over(roster.shipped);
}

fn test_res_over(src: roster.Sources) !Resources {
    var res: Resources = undefined;
    res.sim = .{ .prng = std.Random.DefaultPrng.init(7) };
    res.time = .{ .dt = 0 };
    res.config = .{};
    res.catalog = try roster.load(testing.allocator, src, null);
    return res;
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
    return effects.held(cat, w.get(e, comp.Goods).?, cat.actionIndex(id).?);
}

test "build pays upfront and starts the work; finish owns the spear and grants the verb" {
    var w = World.init();
    var res = try test_res();
    defer res.catalog.deinit();
    const cat = &res.catalog;
    const rod = cat.goodIndex("spear").?;
    const price = cat.goods[rod].requires.?;
    const order = cat.goods[rod].input[0].n;
    const e = spawn_test_agent(&w, order); // exactly the order — spendable to 0
    try testing.expect(!heldVerb(&w, e, cat, "hunt")); // no spear, no verb

    begin(&w, e, &res, rod);

    // Paid and busy — the spear doesn't exist until the work completes.
    try testing.expectEqual(@as(u32, 0), count(&w, e, cat, "spear"));
    try testing.expect(!heldVerb(&w, e, cat, "hunt"));
    try testing.expectEqual(10 - price.energy, w.get(e, comp.Vigor).?.v);
    try testing.expectEqual(@as(f32, 0), w.get(e, comp.InventoryBiomass).?.v); // spent to 0
    const b = w.get(e, comp.Busy).?;
    try testing.expect(b.isBuild(rod));
    try testing.expectEqual(res_mod.hours_to_secs(price.hours, res.config.secs_per_day), b.total);

    finish(&w, e, &res, rod);
    try testing.expectEqual(@as(u32, 1), count(&w, e, cat, "spear"));
    try testing.expect(heldVerb(&w, e, cat, "hunt")); // the unlock
    try testing.expectEqual(@as(usize, 1), res.sim.log.count);
    try testing.expectEqualStrings(cat.goods[rod].copy.built, res.sim.log.get(0).text());
}

test "begin refuses when unaffordable or busy; the quote says why" {
    var w = World.init();
    var res = try test_res();
    defer res.catalog.deinit();
    const cat = &res.catalog;
    const rod = cat.goodIndex("spear").?;
    const order = cat.goods[rod].input[0].n;
    const e = spawn_test_agent(&w, order - 1); // one material short

    try testing.expectEqual(Standing.short, quote(&w, e, cat, rod).?.standing);
    try testing.expectEqualStrings("biomass", quote(&w, e, cat, rod).?.short.?.item);
    begin(&w, e, &res, rod);
    try testing.expect(!w.has(e, comp.Busy)); // refused, no work started
    try testing.expectEqual(@as(f32, 10), w.get(e, comp.Vigor).?.v); // unpaid

    w.get(e, comp.InventoryBiomass).?.v = order + 12;
    begin(&w, e, &res, rod); // starts the build
    try testing.expectEqual(Standing.busy, quote(&w, e, cat, rod).?.standing);
    begin(&w, e, &res, rod); // busy — must refuse, not double-pay
    try testing.expectEqual(@as(f32, 12), w.get(e, comp.InventoryBiomass).?.v); // paid once

    w.remove(e, comp.Busy);
    finish(&w, e, &res, rod);
    try testing.expectEqual(@as(u32, 1), quote(&w, e, cat, rod).?.count); // owned, and still buildable
    begin(&w, e, &res, rod); // 12 materials short of a second
    try testing.expect(!w.has(e, comp.Busy));
}

test "a repeat build is stock: the count rises, the effect does not" {
    var w = World.init();
    var res = try test_res();
    defer res.catalog.deinit();
    const cat = &res.catalog;
    const sandals = cat.goodIndex("sandals").?;
    const forage = cat.actionIndex("forage").?;
    const e = spawn_test_agent(&w, cat.goods[sandals].input[0].n * 3);
    const goods = w.get(e, comp.Goods).?;
    const base = effects.verb(cat, goods, forage).?.requires.energy;

    begin(&w, e, &res, sandals);
    finish(&w, e, &res, sandals);
    w.remove(e, comp.Busy);
    const once = effects.verb(cat, goods, forage).?.requires.energy;
    try testing.expectEqual(@as(u32, 1), count(&w, e, cat, "sandals"));
    try testing.expect(once < base); // the first pair is capital in use

    begin(&w, e, &res, sandals);
    finish(&w, e, &res, sandals);
    w.remove(e, comp.Busy);
    try testing.expectEqual(@as(u32, 2), count(&w, e, cat, "sandals"));
    try testing.expectEqual(once, effects.verb(cat, goods, forage).?.requires.energy); // no second discount
    try testing.expectEqualStrings("Another sandals. You have 2.", res.sim.log.get(0).text());
    try testing.expectEqual(@as(u32, 1), goodsOwned(&w, e, cat)); // kinds, not units

    // Losing a spare keeps the discount; losing the last pair takes it back.
    break_one(&w, e, &res, sandals);
    try testing.expectEqual(@as(u32, 1), count(&w, e, cat, "sandals"));
    try testing.expectEqual(once, effects.verb(cat, goods, forage).?.requires.energy);
    break_one(&w, e, &res, sandals);
    try testing.expectEqual(@as(u32, 0), count(&w, e, cat, "sandals"));
    try testing.expectEqual(base, effects.verb(cat, goods, forage).?.requires.energy);
    try testing.expectEqualStrings("Your sandals broke.", res.sim.log.get(0).text());
}

test "the hatchet unlocks splitting wood; a modifier on it refuses until then" {
    var w = World.init();
    var res = try test_res();
    defer res.catalog.deinit();
    const cat = &res.catalog;
    const e = spawn_test_agent(&w, 100);
    const hatchet = cat.goodIndex("hatchet").?;
    const gloves = cat.goodIndex("work_gloves").?;
    try testing.expect(!heldVerb(&w, e, cat, "chop_wood")); // not innate

    // No hatchet ⟹ no Split wood ⟹ gloves have nothing to improve.
    try testing.expectEqual(Standing.needs, quote(&w, e, cat, gloves).?.standing);
    begin(&w, e, &res, gloves);
    try testing.expect(!w.has(e, comp.Busy)); // refused, not a panic
    try testing.expectEqual(@as(f32, 100), w.get(e, comp.InventoryBiomass).?.v); // unpaid

    acquire(&w, e, &res, hatchet, 1);
    try testing.expect(heldVerb(&w, e, cat, "chop_wood"));
    try testing.expect(needsMet(&w, e, cat, gloves));
    begin(&w, e, &res, gloves);
    try testing.expect(w.has(e, comp.Busy));
    w.remove(e, comp.Busy);

    break_one(&w, e, &res, hatchet);
    try testing.expect(!heldVerb(&w, e, cat, "chop_wood")); // the verb leaves with the tool
}

test "a generator accumulates without moving resources and settles only when collected" {
    var w = World.init();
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
    const garden = res.catalog.goodIndex("garden_bed").?;
    w.get(e, comp.Goods).?.count[garden] = 1;

    run_generators(&w, &res); // halfway through a 48h cycle
    try testing.expectApproxEqAbs(@as(f32, 0.2), w.get(e, comp.InventoryBiomass).?.v, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), w.get(e, comp.InventoryFood).?.v, 1e-6);
    try testing.expectEqual(GeneratorStanding.charging, generator_quote(&w, e, &res.catalog, res.config, garden).?.standing);

    run_generators(&w, &res); // ready, but still no automatic settlement
    try testing.expect(generator_quote(&w, e, &res.catalog, res.config, garden).?.ready());
    try testing.expectApproxEqAbs(@as(f32, 0), w.get(e, comp.InventoryFood).?.v, 1e-6);
    try testing.expect(collect_generator(&w, e, &res, garden));
    try testing.expectApproxEqAbs(@as(f32, 0), w.get(e, comp.InventoryBiomass).?.v, 1e-6);
    try testing.expect(w.get(e, comp.InventoryFood).?.v > 0);
    try testing.expectEqual(GeneratorStanding.charging, generator_quote(&w, e, &res.catalog, res.config, garden).?.standing);
}

/// An agent stocked to build a shelter: the unlock's three conditions all met, and enough
/// materials for the price.
fn spawn_settler(w: *World, cat: *const Catalog) Entity {
    const e = w.spawn(.{
        comp.Vigor{ .v = 16, .max = 20 }, // 16 >= the absolute 15, max is irrelevant
        comp.InventoryFood{ .v = 25, .quality = 1, .spoils = 0 }, // >= the finalized 12
        comp.InventoryBiomass{ .v = 100 }, // >= the finalized 60 price
        comp.Goods{},
        comp.Granted{},
    });
    const goods = w.get(e, comp.Goods).?;
    for ([_][]const u8{ "sandals", "leaf_bed", "cookpot", "root_cellar", "wire_snares" }) |id| {
        goods.count[cat.goodIndex(id).?] = 1; // five goods owned >= the finalized 5
    }
    return e;
}

test "the shelter is offered only once its standing conditions are met" {
    var w = World.init();
    var res = try test_res();
    defer res.catalog.deinit();
    const cat = &res.catalog;
    const shelter = cat.goodIndex("shelter").?;
    const e = spawn_settler(&w, cat);

    try testing.expectEqual(@as(u32, 5), goodsOwned(&w, e, cat));
    try testing.expect(unlockMet(&w, e, cat, shelter));
    try testing.expect(!ownsMilestone(&w, e, cat, .act_one));

    begin(&w, e, &res, shelter);
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
    var w = World.init();
    // Too tired: below the absolute 15 current vigor refuses, regardless of the ceiling.
    {
        const e = spawn_settler(&w, cat);
        w.get(e, comp.Vigor).?.v = 7;
        try testing.expectEqual(Standing.unlock, quote(&w, e, cat, shelter).?.standing);
        begin(&w, e, &res, shelter);
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
    var w = World.init();
    var res = try test_res_over(.{
        .actions =
        \\.{ .{ .id = "forage", .name = "Forage", .innate = true, .requires = .{ .energy = 1.0, .hours = 1.0 } } }
        ,
        .goods =
        \\.{ .{ .id = "oven", .name = "Oven", .act = 2, .tier = .crude, .requires = .{ .energy = 1.0, .hours = 1.0 },
        \\     .input = .{ .{ .item = "biomass", .n = 2.0 } }, .tech = "kilns" } }
        ,
        .technologies =
        \\.{ .{ .id = "kilns", .name = "Kilns", .coord = .{ .q = 1, .r = 0 },
        \\     .cost = .{ .{ .item = "food", .n = 2.0 } }, .initial = .available } }
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
    begin(&w, e, &res, oven);
    try testing.expect(w.get(e, comp.Busy).?.isBuild(oven));
}

test "a good with no unlock has no standing conditions, and a traded good has no quote" {
    var w = World.init();
    var res = try test_res();
    defer res.catalog.deinit();
    const cat = &res.catalog;
    const e = spawn_test_agent(&w, 0);
    try testing.expect(unlockMet(&w, e, cat, cat.goodIndex("fish_rod").?));
    try testing.expect(unlockMet(&w, e, cat, cat.goodIndex("chicken_coop").?));
    try testing.expect(quote(&w, e, cat, cat.goodIndex("fish_rod").?) == null);
}

test "cancel salvages half the build order, frees the body, and grants nothing" {
    var w = World.init();
    var res = try test_res();
    defer res.catalog.deinit();
    const cat = &res.catalog;
    const rod = cat.goodIndex("spear").?;
    const order = cat.goods[rod].input[0].n;
    const price = cat.goods[rod].requires.?;
    const e = spawn_test_agent(&w, order);

    begin(&w, e, &res, rod);
    try testing.expectEqual(@as(f32, 0), w.get(e, comp.InventoryBiomass).?.v); // paid in full

    try testing.expect(cancel_build(&w, e, &res));
    try testing.expect(!w.has(e, comp.Busy)); // the body is free again
    try testing.expectEqual(@as(u32, 0), count(&w, e, cat, "spear")); // and owns nothing for the trouble
    try testing.expect(!heldVerb(&w, e, cat, "hunt"));
    try testing.expectApproxEqAbs(order * res.config.cancel_refund, w.get(e, comp.InventoryBiomass).?.v, 1e-5);
    try testing.expectEqualStrings("You gave up on the spear. Salvaged 5 materials.", res.sim.log.get(0).text());
    // The energy is gone with the hours — cancelling is an exit, not an undo.
    try testing.expectEqual(10 - price.energy, w.get(e, comp.Vigor).?.v);
}

test "cancel refuses on labor, and on an idle body" {
    var w = World.init();
    var res = try test_res();
    defer res.catalog.deinit();
    const e = spawn_test_agent(&w, 5);

    try testing.expect(!cancel_build(&w, e, &res)); // nothing in progress

    w.add(e, comp.Busy{ .doing = .{ .labor = res.catalog.actionIndex("forage").? }, .total = 10, .remaining = 4, .quality = 1 });
    try testing.expect(!cancel_build(&w, e, &res)); // `Busy` covers labor too
    try testing.expect(w.has(e, comp.Busy)); // still foraging
    try testing.expectEqual(@as(f32, 5), w.get(e, comp.InventoryBiomass).?.v);
}

test "a bought tool supersedes the built one; selling it restores the next-best rank" {
    var w = World.init();
    var res = try test_res();
    defer res.catalog.deinit();
    const cat = &res.catalog;
    const rod = cat.goodIndex("fish_rod").?;
    const net = cat.goodIndex("fish_net").?;
    const fish = cat.actionIndex("fish").?;
    const e = spawn_test_agent(&w, 0);
    const goods = w.get(e, comp.Goods).?;
    acquire(&w, e, &res, rod, 1);
    const base_energy = cat.actions[fish].requires.energy;
    try testing.expectEqual(base_energy, effects.verb(cat, goods, fish).?.requires.energy);

    acquire(&w, e, &res, net, 1); // rank 2: the stats replace the rod's, not stack
    try testing.expectApproxEqAbs(base_energy * 0.7, effects.verb(cat, goods, fish).?.requires.energy, 1e-6);
    try testing.expectEqual(@as(u32, 1), count(&w, e, cat, "fish_rod")); // the rod is still owned (sellable)

    try testing.expectEqual(@as(u32, 1), release(&w, e, &res, net, 1)); // sell the net
    try testing.expectEqual(base_energy, effects.verb(cat, goods, fish).?.requires.energy); // the rod's rank
    try testing.expectEqual(@as(u32, 1), release(&w, e, &res, rod, 1)); // sell the rod too
    try testing.expect(effects.verb(cat, goods, fish) == null); // no fishing tool left ⇒ the verb goes
    try testing.expectEqual(@as(u32, 0), release(&w, e, &res, rod, 1)); // nothing left to release
}

test "lowerName puts a sentence-case name into a sentence" {
    var buf: [48]u8 = undefined;
    try testing.expectEqualStrings("fishing rod", lowerName("Fishing rod", &buf));
    try testing.expectEqualStrings("", lowerName("", &buf));
}
