//! `market` — the Act I Passerby, as authoritative **simulation** state (ACT1-12+).
//!
//! Act I's only counterparty is a passerby who wanders in, lingers a while with a finite
//! satchel, and leaves. This module owns that encounter as a clock-driven **state machine** —
//! `absent → approaching → present → departed → absent` — living on `Sim` beside the run's other
//! non-component state (the log, the reach-set). The UI **reads** the encounter; it never infers
//! it from a hardcoded day, so hiding the strip (STRUCTURE, a tab switch) cannot change whether a
//! passerby is here, and the deal a player opens is the same encounter the strip reports.
//!
//! **Stable identity.** Each arrival bumps a monotonic `id`; a quote/offer captured mid-visit
//! carries that id, so a barter can tell "the passerby I was dealing with" from "a different one
//! who has since arrived" — the revision check ACT1-14 revalidates against.
//!
//! **Finite inventory.** A visit refills a small satchel (per-good stock counts); selling into
//! it and buying out of it decrement those counts, and they do not regenerate until the *next*
//! arrival — scarcity is per-encounter, not per-frame.
//!
//! Later slices layer on: typed bundle/quote contracts (ACT1-13), atomic barter (ACT1-14),
//! diminishing marginal sell prices (ACT1-15), and tool supersession (ACT1-16); the UI wiring is
//! ACT1-17. This slice is the encounter clock and its finite satchel.

const std = @import("std");
const logmod = @import("./log.zig");

/// Where the passerby is in a visit. `absent` — no one here (the long gap between visits);
/// `approaching` — seen coming, not yet dealable (the strip can foreshadow); `present` — here
/// with wares, the only phase a deal opens in; `departed` — just left (a beat before `absent`,
/// so the departure reads as an event rather than a silent disappearance).
pub const Phase = enum { absent, approaching, present, departed };

/// The kinds of thing a passerby's satchel can hold in Act I. Deliberately coarse — Act I trades
/// Food, generic Materials, and a couple of small tools — but named so ACT1-13's typed bundles
/// and ACT1-16's tool families have stable slots to fill. The `count`-per-slot lives in
/// `Encounter.stock`, indexed by `@intFromEnum`.
pub const Ware = enum { food, materials, fish_hook, whetstone };
pub const ware_count = @typeInfo(Ware).@"enum".fields.len;

/// The authoritative encounter. Held on `Sim`; ticked once per frame from the clock.
pub const Encounter = struct {
    phase: Phase = .absent,
    /// Monotonic visit identity — bumped on each arrival so a captured quote can be revalidated
    /// against "still the same passerby". `0` means "no one has ever visited this run".
    id: u32 = 0,
    /// Seconds left in the current phase. Drives the deterministic transitions in `tick`.
    remaining: f32 = 0,
    /// The current visit's finite satchel — units of each `Ware` still available. Refilled on
    /// arrival, decremented by trades, never regenerated until the next arrival.
    stock: [ware_count]u16 = [_]u16{0} ** ware_count,

    /// Whether a deal can be opened right now — only while the passerby is actually present.
    /// The UI gates the Hail button on this; tab visibility never enters into it.
    pub fn dealable(self: *const Encounter) bool {
        return self.phase == .present;
    }

    /// Units of `w` still in the satchel this visit.
    pub fn stockOf(self: *const Encounter, w: Ware) u16 {
        return self.stock[@intFromEnum(w)];
    }

    /// Take `n` units of `w` from the satchel (a completed buy). Saturates at 0 — the caller
    /// (ACT1-14) revalidates stock first, so this is the mechanical decrement.
    pub fn take(self: *Encounter, w: Ware, n: u16) void {
        const i = @intFromEnum(w);
        self.stock[i] -= @min(self.stock[i], n);
    }

    /// Add `n` units of `w` to the satchel (a completed sell — the passerby now carries it).
    pub fn give(self: *Encounter, w: Ware, n: u16) void {
        self.stock[@intFromEnum(w)] += n;
    }
};

/// How long each phase lasts and what a fresh satchel holds. Authored constants (not a hardcoded
/// *day*): the encounter clock is its own thing, so a design tweak to visit cadence never touches
/// the day counter or any screen. Durations are in **in-game seconds** via `secs_per_day`.
pub const Schedule = struct {
    /// The quiet gap between visits (absent → approaching).
    gap_days: f32 = 2.0,
    /// The heads-up before wares are dealable (approaching → present).
    approach_days: f32 = 0.25,
    /// How long the passerby lingers with wares (present → departed).
    linger_days: f32 = 1.0,
    /// The brief beat after leaving before the gap resets (departed → absent).
    depart_days: f32 = 0.15,
    /// A fresh satchel, per `Ware` (indexed by `@intFromEnum`): food, materials, fish_hook,
    /// whetstone. Finite and modest — the passerby is a trickle, not a shop.
    satchel: [ware_count]u16 = blk: {
        var s = [_]u16{0} ** ware_count;
        s[@intFromEnum(Ware.food)] = 8;
        s[@intFromEnum(Ware.materials)] = 20;
        s[@intFromEnum(Ware.fish_hook)] = 1;
        s[@intFromEnum(Ware.whetstone)] = 1;
        break :blk s;
    },
};

/// What a tick did — so the caller logs/announces without this module reaching into the log
/// itself (it does, for convenience, but the event is also returned for the UI announcer).
pub const Event = enum { none, arrived, departed };

/// Advance the encounter by `dt` seconds against `sched`, logging arrival/departure. Deterministic
/// and clock-driven: the same elapsed time always produces the same transitions, and nothing here
/// reads the calendar day. Returns the transition that fired this tick (`none` if still within a
/// phase). A phase can only advance one step per tick; `dt` is a frame delta, far smaller than any
/// phase, so that is never a real limit.
pub fn tick(enc: *Encounter, dt: f32, sched: Schedule, spd: f32, log: *logmod.Log) Event {
    enc.remaining -= dt;
    if (enc.remaining > 0) return .none;

    return switch (enc.phase) {
        .absent => {
            // The gap elapsed — someone is approaching.
            enc.phase = .approaching;
            enc.remaining = sched.approach_days * spd;
            return .none; // approaching is not yet an event the player can act on
        },
        .approaching => {
            // Arrival: a new visit. Bump identity, refill the satchel, announce.
            enc.phase = .present;
            enc.id += 1;
            enc.remaining = sched.linger_days * spd;
            enc.stock = sched.satchel;
            log.push(.good, "A passerby stops, and opens a satchel of odds and ends.");
            return .arrived;
        },
        .present => {
            // The visit ended — they move on.
            enc.phase = .departed;
            enc.remaining = sched.depart_days * spd;
            log.push(.dim, "The passerby shoulders the satchel and moves on.");
            return .departed;
        },
        .departed => {
            // Back to the quiet gap.
            enc.phase = .absent;
            enc.remaining = sched.gap_days * spd;
            enc.stock = [_]u16{0} ** ware_count; // nothing to trade while absent
            return .none;
        },
    };
}

// ============================ Typed bundles & quotes (ACT1-13) ===========================
//
// One **transfer representation** for everything a trade moves — Food, generic Materials, and
// owned goods — so barter resolution (ACT1-14) has a single shape to validate and apply, and Act
// II can extend it by adding `Item` variants (typed resources, Coin) without a new grammar.

/// A thing a bundle can carry. Today: Food, generic Materials, and the two small tools the
/// passerby deals in (which map to owned-good components on the player side). Act II adds its
/// typed resources and Coin here — the `Ware` slots are the extension point, so `Item = Ware`.
pub const Item = Ware;

/// One line of a transfer: a quantity of an `Item`. `qty` is `f32` because Food is fractional and
/// Act II resources will be too; whole-unit tools simply use integral values.
pub const Line = struct { item: Item, qty: f32 };

/// The maximum lines a bundle holds — a single Act I trade never moves more than a couple of
/// item kinds, so this is generous and keeps the bundle allocation-free.
pub const bundle_cap = 4;

/// A **typed bundle**: a fixed-capacity set of `Line`s. Both sides of a quote are bundles, so
/// "give Food+Materials, receive a fish hook" and "give a whetstone, receive Materials" are the
/// same shape. Allocation-free and copyable.
pub const Bundle = struct {
    lines: [bundle_cap]Line = undefined,
    len: usize = 0,

    pub fn add(self: *Bundle, item: Item, qty: f32) void {
        if (self.len < bundle_cap) {
            self.lines[self.len] = .{ .item = item, .qty = qty };
            self.len += 1;
        }
    }

    pub fn slice(self: *const Bundle) []const Line {
        return self.lines[0..self.len];
    }

    /// The quantity of `item` in this bundle (0 if absent) — used by affordability/apply.
    pub fn qtyOf(self: *const Bundle, item: Item) f32 {
        var total: f32 = 0;
        for (self.slice()) |l| if (l.item == item) {
            total += l.qty;
        };
        return total;
    }

    /// A one-item bundle — the common case (a whole tool, or a lump of one resource).
    pub fn one(item: Item, qty: f32) Bundle {
        var b = Bundle{};
        b.add(item, qty);
        return b;
    }
};

/// Which way a quote runs, from the player's point of view. `buy` — the player **gives** Food/
/// Materials and **receives** a ware; `sell` — the player **gives** an owned good and **receives**
/// Materials. One enum both the dialog tabs and the resolver read.
pub const Direction = enum { buy, sell };

/// Why a quote cannot be taken right now — a player-readable reason, not a silent disable. `none`
/// means it is takeable. `stale`/`departed` are the encounter-revision failures ACT1-14 revalidates;
/// `sold_out`/`unaffordable` are the stock/holdings failures.
pub const Refusal = enum {
    none,
    unaffordable,
    sold_out,
    stale,
    departed,

    pub fn reason(self: Refusal) []const u8 {
        return switch (self) {
            .none => "",
            .unaffordable => "You can't cover that.",
            .sold_out => "Sold out.",
            .stale => "That offer has changed.",
            .departed => "The passerby has gone.",
        };
    }
};

/// A **quote**: one concrete offer the player can weigh, with everything barter needs to revalidate
/// and everything the dialog needs to render. Captured against a specific encounter visit (`rev` =
/// the encounter `id` at capture) so ACT1-14 can tell a live quote from one whose passerby has left
/// or been replaced. `id` is a stable per-catalog offer identity (which line of the passerby's
/// board this is). `next` is the **next marginal sell quote** — for a sell, what the *following*
/// unit would fetch (filled by ACT1-15's diminishing schedule); null when not applicable.
pub const Quote = struct {
    id: u32,
    rev: u32,
    direction: Direction,
    give: Bundle,
    receive: Bundle,
    effect: []const u8 = "",
    /// Units of this offer still available this visit (buy: the passerby's stock; sell: how many
    /// the player may sell before the schedule bottoms out). 0 ⇒ sold out.
    stock: u16 = 1,
    /// The Materials the *next* unit of a sell would fetch, if this is a sell with more to sell —
    /// exposed before confirmation so diminishing returns are visible, not a surprise (ACT1-15).
    next_unit: ?f32 = null,

    /// Whether this quote is takeable against a live encounter and the player's holdings.
    /// `enc_id` is the current encounter identity; `food`/`materials` the player's holdings; a
    /// sell also needs the player to own the good, which the caller checks (component ownership is
    /// outside this leaf module). Returns the specific `Refusal`.
    pub fn refusal(self: *const Quote, enc: *const Encounter, food: f32, materials: f32) Refusal {
        if (!enc.dealable()) return .departed;
        if (self.rev != enc.id) return .stale;
        if (self.stock == 0) return .sold_out;
        // Affordability: the player must hold every Food/Materials line on the give side.
        if (self.give.qtyOf(.food) > food) return .unaffordable;
        if (self.give.qtyOf(.materials) > materials) return .unaffordable;
        return .none;
    }

    pub fn takeable(self: *const Quote, enc: *const Encounter, food: f32, materials: f32) bool {
        return self.refusal(enc, food, materials) == .none;
    }
};

// ============================ Tests =====================================================

const testing = std.testing;
const secs_per_day: f32 = 120.0; // an arbitrary clock for the tests

test "encounter walks absent → approaching → present → departed → absent on the clock" {
    var log = logmod.Log{};
    var enc = Encounter{}; // absent, remaining 0, id 0
    const sched = Schedule{};

    // First tick from a zeroed absent state: remaining hits 0 immediately → approaching.
    try testing.expectEqual(Event.none, tick(&enc, 0.001, sched, secs_per_day, &log));
    try testing.expectEqual(Phase.approaching, enc.phase);
    try testing.expectEqual(@as(u32, 0), enc.id); // not a visit yet

    // Burn the approach window → present (an arrival: id bumps, satchel fills, one log).
    _ = tick(&enc, sched.approach_days * secs_per_day, sched, secs_per_day, &log);
    try testing.expectEqual(Phase.present, enc.phase);
    try testing.expectEqual(@as(u32, 1), enc.id);
    try testing.expect(enc.dealable());
    try testing.expectEqual(@as(u16, 20), enc.stockOf(.materials));
    try testing.expectEqual(@as(usize, 1), log.count); // exactly the arrival line

    // Burn the linger window → departed (a second log).
    _ = tick(&enc, sched.linger_days * secs_per_day, sched, secs_per_day, &log);
    try testing.expectEqual(Phase.departed, enc.phase);
    try testing.expect(!enc.dealable());
    try testing.expectEqual(@as(usize, 2), log.count);

    // Burn the depart beat → absent (satchel cleared, no new log).
    _ = tick(&enc, sched.depart_days * secs_per_day, sched, secs_per_day, &log);
    try testing.expectEqual(Phase.absent, enc.phase);
    try testing.expectEqual(@as(u16, 0), enc.stockOf(.materials));
    try testing.expectEqual(@as(usize, 2), log.count);
}

test "each visit bumps a stable identity and refills the satchel" {
    var log = logmod.Log{};
    var enc = Encounter{};
    const sched = Schedule{};

    // Run a full cycle to the first arrival.
    _ = tick(&enc, 0.001, sched, secs_per_day, &log); // → approaching
    _ = tick(&enc, sched.approach_days * secs_per_day, sched, secs_per_day, &log); // → present (id 1)
    try testing.expectEqual(@as(u32, 1), enc.id);

    // Spend some stock this visit, then complete the cycle back to a second arrival.
    enc.take(.materials, 5);
    try testing.expectEqual(@as(u16, 15), enc.stockOf(.materials));
    _ = tick(&enc, sched.linger_days * secs_per_day, sched, secs_per_day, &log); // → departed
    _ = tick(&enc, sched.depart_days * secs_per_day, sched, secs_per_day, &log); // → absent
    _ = tick(&enc, sched.gap_days * secs_per_day, sched, secs_per_day, &log); // → approaching
    _ = tick(&enc, sched.approach_days * secs_per_day, sched, secs_per_day, &log); // → present (id 2)

    try testing.expectEqual(@as(u32, 2), enc.id); // a *different* passerby
    try testing.expectEqual(@as(u16, 20), enc.stockOf(.materials)); // the satchel refilled
}

test "dealability is present-only and independent of any day/tab" {
    var enc = Encounter{};
    try testing.expect(!enc.dealable()); // absent
    enc.phase = .approaching;
    try testing.expect(!enc.dealable());
    enc.phase = .present;
    try testing.expect(enc.dealable());
    enc.phase = .departed;
    try testing.expect(!enc.dealable());
}

test "take saturates at zero and give adds to the satchel" {
    var enc = Encounter{};
    enc.stock[@intFromEnum(Ware.food)] = 3;
    enc.take(.food, 5); // more than held
    try testing.expectEqual(@as(u16, 0), enc.stockOf(.food));
    enc.give(.food, 4);
    try testing.expectEqual(@as(u16, 4), enc.stockOf(.food));
}

test "bundle carries typed lines and reports quantities" {
    var b = Bundle{};
    b.add(.food, 2.5);
    b.add(.materials, 6);
    try testing.expectEqual(@as(usize, 2), b.len);
    try testing.expectApproxEqAbs(@as(f32, 2.5), b.qtyOf(.food), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 6), b.qtyOf(.materials), 1e-6);
    try testing.expectEqual(@as(f32, 0), b.qtyOf(.fish_hook)); // absent ⇒ 0
    // The one-item convenience form.
    const w = Bundle.one(.whetstone, 1);
    try testing.expectEqual(@as(f32, 1), w.qtyOf(.whetstone));
}

test "quote refusal distinguishes departed, stale, sold-out, unaffordable, and takeable" {
    var enc = Encounter{ .phase = .present, .id = 3 };
    enc.stock[@intFromEnum(Ware.materials)] = 10;

    // A buy: give 2 food + 4 materials, receive a fish hook, captured at the live revision.
    var q = Quote{
        .id = 1,
        .rev = 3,
        .direction = .buy,
        .give = blk: {
            var g = Bundle{};
            g.add(.food, 2);
            g.add(.materials, 4);
            break :blk g;
        },
        .receive = Bundle.one(.fish_hook, 1),
        .stock = 1,
    };

    // Enough holdings, live encounter, in stock ⇒ takeable.
    try testing.expect(q.takeable(&enc, 5, 10));
    // Short on materials ⇒ unaffordable.
    try testing.expectEqual(Refusal.unaffordable, q.refusal(&enc, 5, 3));
    // Short on food ⇒ unaffordable.
    try testing.expectEqual(Refusal.unaffordable, q.refusal(&enc, 1, 10));
    // Sold out ⇒ sold_out (checked before affordability passes).
    q.stock = 0;
    try testing.expectEqual(Refusal.sold_out, q.refusal(&enc, 5, 10));
    q.stock = 1;
    // A different passerby now (id moved) ⇒ stale.
    enc.id = 4;
    try testing.expectEqual(Refusal.stale, q.refusal(&enc, 5, 10));
    // Not present at all ⇒ departed (takes precedence over everything).
    enc.phase = .departed;
    try testing.expectEqual(Refusal.departed, q.refusal(&enc, 5, 10));
    // Every refusal has player-readable copy.
    try testing.expect(Refusal.unaffordable.reason().len > 0);
    try testing.expectEqualStrings("", Refusal.none.reason());
}
