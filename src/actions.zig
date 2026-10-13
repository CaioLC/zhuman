//! Actions: per-agent labor over the authored roster.
//!
//! A verb is a record in `data/actions.zon` (`roster.zig`). Whether an agent holds it, and
//! on what terms, is derived from the goods it owns (`effects.verb`) and, for a verb that names
//! a `tech`, from the agent's research (`verbOf`); nothing about a verb is stored on the agent.
//! `quote` is the one gate calculation — the tile, `begin`, and a future
//! decider read the same answer — and labor resolves in two halves because it takes time:
//! `begin` gates, pays and starts the work; `finish` draws the yield at the quality locked at
//! begin and deposits it, dispatched by `systems.resolve_busy` when the timer runs out.
//!
//! The affordability gates are asymmetric on purpose: **energy is strict** (vigor may never
//! reach zero, so labor alone cannot kill), an item may be spent to exactly zero.

const std = @import("std");
const ha = @import("ha");
const comp = ha.comp;
const roster = ha.roster;
const effects = ha.effects;
const ledger = ha.ledger;
const res_mod = @import("./res.zig");
const world = @import("./world.zig");

const Resources = res_mod.Resources;
const World = world.World;
const Entity = world.Entity;
const Catalog = roster.Catalog;

// --- labor quality: two levels, one constant step ---
// An agent that isn't `.alive` yields `Config.weary_yield`; one that is yields full. A
// constant step, not a linear slide: it keeps the advertised band stable — the band only
// moves at a threshold crossing — and the crossing is the same one that flips the condition
// word to WEARY and tints the V chip warn, so the state is announced before the band changes.
// (The linear slide was built once and reverted: constant band churn, and it felt bad.)

/// The current yield multiplier for an agent's vigor — 1.0 while `.alive`, else
/// `Config.weary_yield`. The thresholds live on `Config` (`res.zig`) so the sim, the
/// condition word and the vigor chip can't drift apart.
pub fn yield_factor(vigor: *const comp.Vigor, cfg: res_mod.Config) f32 {
    return cfg.yield_of(cfg.condition(vigor.v / vigor.max));
}

/// Why a verb cannot begin right now, or `ready`.
pub const Standing = enum { ready, busy, energy, short };

/// What one click would do: the verb's effective terms for this agent, the quality it would
/// lock, and whether it can begin now. One calculation for the tile, the gate and a decider.
pub const Quote = struct {
    verb: effects.Verb,
    standing: Standing,
    /// The first unpayable input when `standing == .short`.
    short: ?roster.Line = null,
    /// The yield multiplier a begin right now would lock.
    quality: f32,

    pub fn ready(self: Quote) bool {
        return self.standing == .ready;
    }
};

/// Whether verb `ai`'s technology is researched for this agent. A verb without one is not
/// opened by research.
fn researched(w: *World, e: Entity, cat: *const Catalog, ai: u16) bool {
    const id = cat.actions[ai].tech orelse return false;
    const ti = cat.techIndex(id) orelse return false;
    const research = w.get(e, comp.Research) orelse return false;
    return research.state[ti] == .researched;
}

/// Verb `ai`'s effective terms for agent `e`, or null when the agent does not hold it: innate,
/// granted by an applying good, or opened by its researched technology. Owned goods modify it
/// the same way in every case.
pub fn verbOf(w: *World, e: Entity, cat: *const Catalog, ai: u16) ?effects.Verb {
    const goods = w.get(e, comp.Goods) orelse return null;
    if (effects.verb(cat, goods, ai)) |v| return v;
    if (!researched(w, e, cat, ai)) return null;
    return effects.terms(cat, goods, ai);
}

/// Whether agent `e` holds verb `ai` (see `verbOf`).
pub fn holds(w: *World, e: Entity, cat: *const Catalog, ai: u16) bool {
    return verbOf(w, e, cat, ai) != null;
}

/// The quote for verb `ai`, or null when the agent does not hold it.
pub fn quote(w: *World, e: Entity, cat: *const Catalog, cfg: res_mod.Config, ai: u16) ?Quote {
    const v = verbOf(w, e, cat, ai) orelse return null;
    const vigor = w.get(e, comp.Vigor) orelse return null;
    var q = Quote{ .verb = v, .standing = .ready, .quality = yield_factor(vigor, cfg) };
    if (w.has(e, comp.Busy)) {
        q.standing = .busy; // one body, one act
    } else if (v.requires.energy >= vigor.v) {
        q.standing = .energy; // strict: spending vigor to exactly 0 is death
    } else if (ledger.short(w, e, cat, v.input.slice(), 1)) |l| {
        q.standing = .short;
        q.short = l;
    }
    return q;
}

/// The **begin** half: gate → pay → start the work. The yield resolves only at completion.
/// Quality is locked here: the band the tile advertised at the click is the band the draw
/// will use, even if the metabolism drains the body while working. Refuses silently when the
/// quote is not ready.
pub fn begin(w: *World, e: Entity, res: *Resources, ai: u16) void {
    const cat = &res.catalog;
    const q = quote(w, e, cat, res.config, ai) orelse return;
    if (!q.ready()) return;
    const vigor = w.get(e, comp.Vigor).?;
    const frac_before = vigor.v / vigor.max;

    // Pay the price upfront. The strict energy gate keeps vigor > 0, so labor alone can't
    // kill — running the body to death takes starving it of the refill.
    vigor.v -= q.verb.requires.energy;
    ledger.pay(w, e, cat, q.verb.input.slice(), 1);
    if (res.config.condition(frac_before) == .alive and
        res.config.condition(vigor.v / vigor.max) != .alive)
        res.sim.log.push(.warn, "You feel weak. Work will yield less.");

    // The feed shows the debit the moment the work begins; the yield is the receipt later.
    {
        var buf: [64]u8 = undefined;
        res.sim.log.push(.dim, paymentText(&buf, cat, q.verb));
    }

    const total = res_mod.hours_to_secs(q.verb.requires.hours, res.config.secs_per_day);
    w.add(e, comp.Busy{ .doing = .{ .labor = ai }, .total = total, .remaining = total, .quality = q.quality });

    res.sim.tutorial_done = true; // remember that this run has successfully begun an action
}

/// The **finish** half: draw each output line at the quality locked at begin (the spread
/// *is* the risk — no separate success roll), deposit, and log the receipt. A verb lost
/// mid-task (the tool was sold while fishing) finishes as nothing rather than a crash.
pub fn finish(w: *World, e: Entity, res: *Resources, ai: u16, quality: f32) void {
    const cat = &res.catalog;
    const v = verbOf(w, e, cat, ai) orelse {
        res.sim.log.push(.dim, "The work came to nothing.");
        return;
    };
    const receipt = ledger.draw(w, e, cat, v.output.slice(), res.random(), quality, 1);
    var buf: [96]u8 = undefined;
    const msg = receiptText(&buf, cat, receipt);
    res.sim.log.push(if (std.mem.eql(u8, msg, nothing_text)) .dim else .normal, msg);
}

/// What the activity strip says the body is doing: the verb's or the recipe's name.
pub fn doing_label(cat: *const Catalog, d: comp.Busy.Doing) []const u8 {
    return switch (d) {
        .labor => |ai| cat.actions[ai].name,
        .build => |gi| cat.goods[gi].name,
    };
}

/// Whether a `Busy` is a capital build (vs a labor verb) — the activity strip picks the
/// `.building` glyph for a build, `.working` for labor.
pub fn is_build(d: comp.Busy.Doing) bool {
    return d == .build;
}

// --- the receipt and the payment line -------------------------------------------------

const nothing_text = "You gathered nothing.";

/// The display word for an item in a sentence: a resource's tag name, a good's name.
pub fn itemWord(cat: *const Catalog, id: []const u8) []const u8 {
    if (Catalog.resource(id)) |r| return @tagName(r);
    if (cat.good(id)) |g| return g.name;
    return id;
}

/// "You gathered 3 food and 2 materials." Amounts are rounded the way the HUD displays
/// them; a rounded-to-zero draw reads as the miss it felt like.
fn receiptText(buf: []u8, cat: *const Catalog, r: ledger.Receipt) []const u8 {
    var n: usize = 0;
    for (r.slice()) |d| if (@round(d.amount) > 0) {
        n += 1;
    };
    if (n == 0) return nothing_text;
    var wr = std.Io.Writer.fixed(buf);
    wr.writeAll("You gathered ") catch {};
    var i: usize = 0;
    for (r.slice()) |d| {
        const amt = @round(d.amount);
        if (amt <= 0) continue;
        if (i > 0) wr.writeAll(if (i + 1 == n) " and " else ", ") catch {};
        wr.print("{d:.0} {s}", .{ amt, itemWord(cat, d.item) }) catch {};
        i += 1;
    }
    wr.writeAll(".") catch {};
    return wr.buffered();
}

/// "You spend 1.7e 1m to begin." — the energy, then every input line.
fn paymentText(buf: []u8, cat: *const Catalog, v: effects.Verb) []const u8 {
    var wr = std.Io.Writer.fixed(buf);
    wr.print("You spend {d:.1}e", .{v.requires.energy}) catch {};
    for (v.input.slice()) |l| {
        if (Catalog.resource(l.item)) |r| {
            wr.print(" {d:.0}{s}", .{ l.n, r.letter() }) catch {};
        } else {
            wr.print(" {d:.0} {s}", .{ l.n, itemWord(cat, l.item) }) catch {};
        }
    }
    wr.writeAll(" to begin.") catch {};
    return wr.buffered();
}

// ============================ Tests ==========================================

const testing = std.testing;

/// A Resources with only the groups the labor path touches (`sim`, `config`, `catalog`)
/// initialized — `platform` stays undefined and untouched. The prng is seeded fixed so a
/// test's draws are reproducible. The caller deinits the catalog.
fn test_res() !Resources {
    var res: Resources = undefined;
    res.sim = .{ .prng = std.Random.DefaultPrng.init(42) };
    res.config = .{};
    res.catalog = try roster.load(testing.allocator, roster.shipped, null);
    return res;
}

fn spawn_agent(w: *World, vigor: f32, materials: f32) Entity {
    return w.spawn(.{
        comp.Vigor{ .v = vigor, .max = 10 },
        comp.InventoryFood{ .v = 0, .quality = 1, .spoils = 0 },
        comp.InventoryMaterial{ .v = materials },
        comp.Goods{},
        comp.Granted{},
    });
}

test "begin pays upfront and starts the work; finish deposits and logs the receipt" {
    var w = World.init();
    var res = try test_res();
    defer res.catalog.deinit();
    // 0 materials on purpose: a zero-input action must act at stock 0.
    const e = spawn_agent(&w, 10, 0);
    const forage = res.catalog.actionIndex("forage").?;

    begin(&w, e, &res, forage);

    // Paid and busy — but nothing delivered yet.
    try testing.expectApproxEqAbs(@as(f32, 8.3), w.get(e, comp.Vigor).?.v, 1e-5); // 10 − 1.7 energy
    const b = w.get(e, comp.Busy).?;
    try testing.expect(b.isLabor(forage));
    try testing.expectEqual(res_mod.hours_to_secs(4, res.config.secs_per_day), b.total); // Forage's 4h
    try testing.expectEqual(@as(f32, 1.0), b.quality); // locked at full strength
    try testing.expectEqual(@as(f32, 0), w.get(e, comp.InventoryFood).?.v); // no deposit
    try testing.expectEqual(@as(usize, 1), res.sim.log.count); // the upfront-payment line
    try testing.expectEqualStrings("You spend 1.7e to begin.", res.sim.log.get(0).text());
    try testing.expect(res.sim.tutorial_done); // a successful begin sets run-progression memory

    // A second begin while busy must refuse, leaving no trace.
    begin(&w, e, &res, forage);
    try testing.expectApproxEqAbs(@as(f32, 8.3), w.get(e, comp.Vigor).?.v, 1e-5); // unpaid

    finish(&w, e, &res, forage, b.quality);
    try testing.expect(w.get(e, comp.InventoryFood).?.v >= 0); // yield deposited (≥ 0 draw)
    try testing.expectEqual(@as(usize, 2), res.sim.log.count); // payment + the receipt line
}

test "quote: not held, then short, ready, energy, weary quality, busy" {
    var w = World.init();
    var res = try test_res();
    defer res.catalog.deinit();
    const cat = &res.catalog;
    const e = spawn_agent(&w, 10, 0);
    const traps = cat.actionIndex("check_traps").?;
    w.get(e, comp.Goods).?.count[cat.goodIndex("wire_snares").?] = 1;
    const q = quote(&w, e, cat, res.config, traps).?;
    try testing.expectEqual(Standing.short, q.standing);
    try testing.expectEqualStrings("materials", q.short.?.item);
    try testing.expectEqual(@as(f32, 1.0), q.quality);

    w.get(e, comp.InventoryMaterial).?.v = 1; // exactly the bait — spendable to 0
    try testing.expect(quote(&w, e, cat, res.config, traps).?.ready());
    w.get(e, comp.Vigor).?.v = 1.0; // exactly the price — strict gate refuses
    try testing.expectEqual(Standing.energy, quote(&w, e, cat, res.config, traps).?.standing);
    w.get(e, comp.Vigor).?.v = 3.0; // 30%: weary, so the quality drops a step
    try testing.expectEqual(res.config.weary_yield, quote(&w, e, cat, res.config, traps).?.quality);
    w.add(e, comp.Busy{ .doing = .{ .labor = traps }, .total = 1, .remaining = 1, .quality = 1 });
    try testing.expectEqual(Standing.busy, quote(&w, e, cat, res.config, traps).?.standing);
}

test "yield_factor: two stable levels split at the WEARY threshold" {
    const cfg = res_mod.Config{};
    var v = comp.Vigor{ .v = 10, .max = 10 };
    try testing.expectEqual(@as(f32, 1.0), yield_factor(&v, cfg));
    v.v = 3.5; // exactly the threshold — not yet weak (strictly below crosses)
    try testing.expectEqual(@as(f32, 1.0), yield_factor(&v, cfg));
    v.v = 3.4;
    try testing.expectEqual(cfg.weary_yield, yield_factor(&v, cfg));
}

test "begin warns once when its own toll crosses into weakness, and locks pre-pay quality" {
    var w = World.init();
    var res = try test_res();
    defer res.catalog.deinit();
    const e = spawn_agent(&w, 4, 0); // 40% — paying 1.7 lands at 23%, across the WEARY line
    const forage = res.catalog.actionIndex("forage").?;

    begin(&w, e, &res, forage);
    try testing.expectApproxEqAbs(@as(f32, 2.3), w.get(e, comp.Vigor).?.v, 1e-5); // 4 − 1.7
    try testing.expectEqual(@as(usize, 2), res.sim.log.count); // the weakness warning + payment
    // Quality was judged before paying: 40% was not weak, so the locked factor is 1.0.
    try testing.expectEqual(@as(f32, 1.0), w.get(e, comp.Busy).?.quality);
}

test "begin refuses when energy would hit zero, leaving no trace" {
    var w = World.init();
    var res = try test_res();
    defer res.catalog.deinit();
    const e = spawn_agent(&w, 1.7, 0); // exactly the price — strict gate must refuse
    const forage = res.catalog.actionIndex("forage").?;

    begin(&w, e, &res, forage);

    try testing.expectApproxEqAbs(@as(f32, 1.7), w.get(e, comp.Vigor).?.v, 1e-5); // unpaid
    try testing.expect(!w.has(e, comp.Busy)); // no work started
    try testing.expectEqual(@as(usize, 0), res.sim.log.count); // no lines
    try testing.expect(!res.sim.tutorial_done); // a refused action records no progress
}

test "an input is paid at begin and named in the payment line" {
    var w = World.init();
    var res = try test_res();
    defer res.catalog.deinit();
    const e = spawn_agent(&w, 10, 3);
    w.get(e, comp.Goods).?.count[res.catalog.goodIndex("wire_snares").?] = 1;
    const traps = res.catalog.actionIndex("check_traps").?;
    begin(&w, e, &res, traps);
    try testing.expectEqual(@as(f32, 2), w.get(e, comp.InventoryMaterial).?.v); // the bait
    try testing.expectEqualStrings("You spend 1.0e 1m to begin.", res.sim.log.get(0).text());
}

test "a verb lost mid-task finishes as nothing" {
    var w = World.init();
    var res = try test_res();
    defer res.catalog.deinit();
    const e = spawn_agent(&w, 10, 0);
    const fish = res.catalog.actionIndex("fish").?;
    // Never held the rod: the busy marker is stale, and finishing it must not crash.
    finish(&w, e, &res, fish, 1);
    try testing.expectEqual(@as(usize, 1), res.sim.log.count);
    try testing.expectEqualStrings("The work came to nothing.", res.sim.log.get(0).text());
}

test "the receipt names what landed, in line order" {
    var cat = try roster.load(testing.allocator, roster.shipped, null);
    defer cat.deinit();
    var buf: [96]u8 = undefined;
    var r = ledger.Receipt{};
    r.items[0] = .{ .item = "food", .amount = 2.6 };
    r.items[1] = .{ .item = "materials", .amount = 0.2 }; // rounds to nothing
    r.len = 2;
    try testing.expectEqualStrings("You gathered 3 food.", receiptText(&buf, &cat, r));
    r.items[1].amount = 1.5;
    try testing.expectEqualStrings("You gathered 3 food and 2 materials.", receiptText(&buf, &cat, r));
    r.len = 0;
    try testing.expectEqualStrings(nothing_text, receiptText(&buf, &cat, r));
}

test "a verb that names a technology is held once that technology is researched" {
    var w = World.init();
    var cat = try roster.load(testing.allocator, .{
        .actions =
        \\.{ .{ .id = "fire", .name = "Fire", .act = 2, .tech = "kilns", .requires = .{ .energy = 1.0, .hours = 1.0 } } }
        ,
        .goods = ".{}",
        .technologies =
        \\.{ .{ .id = "kilns", .name = "Kilns", .coord = .{ .q = 1, .r = 0 }, .initial = .available } }
        ,
    }, null);
    defer cat.deinit();
    const e = w.spawn(.{ comp.Vigor{ .v = 10, .max = 10 }, comp.Goods{}, comp.Granted{} });

    try testing.expect(!holds(&w, e, &cat, 0)); // no board at all
    w.add(e, comp.Research.entry(&cat));
    try testing.expect(!holds(&w, e, &cat, 0)); // offered on the board, not established
    w.get(e, comp.Research).?.state[0] = .researched;
    try testing.expect(holds(&w, e, &cat, 0));
    try testing.expect(quote(&w, e, &cat, .{}, 0).?.ready());
}
