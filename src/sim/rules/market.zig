//! `market` — the Act I Passerby, as authoritative **simulation** state.
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
//! who has since arrived" — the revision check `barter.resolve` revalidates against.
//!
//! **Finite inventory.** A visit refills a small satchel (per-ware amounts). Whatever the
//! passerby hands over comes out of it — the food, materials or tool a buy receives, and the
//! payment for a sell — and whatever the player hands over goes into it; a quote that would
//! overdraw it is refused, and it does not regenerate until the *next* arrival — scarcity is
//! per-encounter, not per-frame.
//!
//! **The spread.** The passerby values a food at 2 materials when the player gives food and at 3
//! when the player takes it, so a round trip loses a third: buying food is 3 materials a unit,
//! buying materials 2 for a food. A sell is the same exchange at a price that falls with each lot
//! sold this visit (`sell_value`). A rank-2 tool is offered only to a player holding the rank-1
//! tool of its family (`prerequisite`).
//!
//! The encounter clock and its finite satchel are here, with the typed bundle/quote contracts
//! and the diminishing sell-price schedule below; `barter.zig` resolves a quote atomically and
//! `capital.zig` owns tool supersession.

const std = @import("std");

/// Where the passerby is in a visit. `absent` — no one here (the long gap between visits);
/// `approaching` — seen coming, not yet dealable (the strip can foreshadow); `present` — here
/// with wares, the only phase a deal opens in; `departed` — just left (a beat before `absent`,
/// so the departure reads as an event rather than a silent disappearance).
pub const Phase = enum { absent, approaching, present, departed };

/// The kinds of thing a passerby's satchel can hold in Act I: Food, generic Materials, and the
/// four tools it carries — the fishing rod (`fish_hook`) and hatchet (`whetstone`), and their
/// rank-2 successors, the fishing net and hand axe. The amount per slot lives in
/// `Encounter.stock`, indexed by `@backingInt`; a ware appended here reads as zero from a save
/// written before it.
pub const Ware = enum { food, biomass, fish_hook, whetstone, fish_net, hand_axe };
pub const ware_count = @typeInfo(Ware).@"enum".field_names.len;

/// The authoritative encounter. Held on `Sim`; ticked once per frame from the clock.
pub const Encounter = struct {
    phase: Phase = .absent,
    /// Monotonic visit identity — bumped on each arrival so a captured quote can be revalidated
    /// against "still the same passerby". `0` means "no one has ever visited this run".
    id: u32 = 0,
    /// Seconds left in the current phase. Drives the deterministic transitions in `tick`.
    remaining: f32 = 0,
    /// The current visit's finite satchel — the amount of each `Ware` still available.
    /// Fractional, since a sell's falling price pays fractions. Refilled on arrival, drawn down
    /// by what the passerby hands over and topped up by what it takes, never regenerated until
    /// the next arrival.
    stock: [ware_count]f32 = @splat(0),
    /// What this visit has moved, from the player's side — signed units of each `Ware` (paid
    /// out negative, received positive). The trade dialog's footer reads it; arrival clears it.
    visit: [ware_count]f32 = @splat(0),
    /// Lots of each `Ware` the player has sold this visit: where its sell price stands on the
    /// falling schedule (`sell_value`). Arrival clears it.
    sold: [ware_count]u16 = @splat(0),

    /// Whether a deal can be opened right now — only while the passerby is actually present.
    /// The UI gates the TRADE action on this; tab visibility never enters into it.
    pub fn dealable(self: *const Encounter) bool {
        return self.phase == .present;
    }

    /// The amount of `w` still in the satchel this visit.
    pub fn stockOf(self: *const Encounter, w: Ware) f32 {
        return self.stock[@backingInt(w)];
    }

    /// Lots of `w` sold this visit.
    pub fn soldOf(self: *const Encounter, w: Ware) u16 {
        return self.sold[@backingInt(w)];
    }

    /// Whether the satchel holds `n` of `w` (a hair of float slack, so a quote built from the
    /// satchel's own amount is never refused by rounding).
    pub fn holds(self: *const Encounter, w: Ware, n: f32) bool {
        return self.stockOf(w) + 1e-4 >= n;
    }

    /// Take `n` of `w` from the satchel (what the passerby hands over). Saturates at 0 — the
    /// caller revalidates stock first, so this is the mechanical decrement.
    pub fn take(self: *Encounter, w: Ware, n: f32) void {
        const i = @backingInt(w);
        self.stock[i] = @max(0, self.stock[i] - n);
    }

    /// Add `n` of `w` to the satchel (what the passerby takes — it now carries it).
    pub fn give(self: *Encounter, w: Ware, n: f32) void {
        self.stock[@backingInt(w)] += n;
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
    /// A generous two-day window to inspect and complete several exchanges.
    linger_days: f32 = 2.0,
    /// The brief beat after leaving before the gap resets (departed → absent).
    depart_days: f32 = 0.15,
    /// A fresh satchel, per `Ware` (indexed by `@backingInt`): food, materials and one of each
    /// tool. Finite and modest — the passerby is a trickle, not a shop.
    satchel: [ware_count]f32 = blk: {
        var s: [ware_count]f32 = @splat(0);
        s[@backingInt(Ware.food)] = 8;
        s[@backingInt(Ware.biomass)] = 20;
        s[@backingInt(Ware.fish_hook)] = 1;
        s[@backingInt(Ware.whetstone)] = 1;
        s[@backingInt(Ware.fish_net)] = 1;
        s[@backingInt(Ware.hand_axe)] = 1;
        break :blk s;
    },
};

/// What a tick did. The passerby system turns it into an `Arrived` or `Departed` fact.
pub const Event = enum { none, arrived, departed };

/// Advance the encounter by `dt` seconds against `sched`. Deterministic and clock-driven: the
/// same elapsed time always produces the same transitions, and nothing here reads the calendar
/// day. Returns the transition that fired this tick (`none` if still within a phase). A phase can
/// only advance one step per tick; `dt` is a frame delta, far smaller than any phase, so that is
/// never a real limit.
pub fn tick(enc: *Encounter, dt: f32, sched: Schedule, spd: f32) Event {
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
            // Arrival: a new visit. Bump identity, refill the satchel.
            enc.phase = .present;
            enc.id += 1;
            enc.remaining = sched.linger_days * spd;
            enc.stock = sched.satchel;
            enc.visit = @splat(0);
            enc.sold = @splat(0);
            return .arrived;
        },
        .present => {
            // The visit ended — they move on.
            enc.phase = .departed;
            enc.remaining = sched.depart_days * spd;
            return .departed;
        },
        .departed => {
            // Back to the quiet gap.
            enc.phase = .absent;
            enc.remaining = sched.gap_days * spd;
            enc.stock = @splat(0); // nothing to trade while absent
            return .none;
        },
    };
}

// ============================ Typed bundles & quotes ===========================
//
// One **transfer representation** for everything a trade moves — Food, generic Materials, and
// owned goods — so barter resolution has a single shape to validate and apply.

/// A thing a bundle can carry: Food, generic Materials, and the two small tools the passerby
/// deals in (which map to owned-good components on the player side). `Item = Ware`.
pub const Item = Ware;

/// One line of a transfer: a quantity of an `Item`. `qty` is `f32` because Food is fractional;
/// whole-unit tools use integral values.
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
/// means it is takeable. `stale`/`departed` are the encounter-revision failures
/// `barter.resolve` revalidates; `sold_out`/`unaffordable` are the stock/holdings failures.
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
/// the encounter `id` at capture) so barter can tell a live quote from one whose passerby has left
/// or been replaced. `id` is a stable per-catalog offer identity (which line of the passerby's
/// board this is). A sell is captured at a point on its falling schedule (`nth`), and
/// `next_unit` is what the *following* lot would fetch.
pub const Quote = struct {
    id: u32,
    rev: u32,
    direction: Direction,
    give: Bundle,
    receive: Bundle,
    /// Lots of this offer still available this visit: a buy, what the satchel holds of it; a
    /// sell, one while the satchel can pay for the next lot (its price falls lot by lot, so each
    /// is quoted on its own). 0 ⇒ sold out.
    stock: u16 = 1,
    /// For a sell: the lots of its ware already sold this visit when it was quoted — the point
    /// on the schedule its price was read at. A sale since makes it stale.
    nth: ?u16 = null,
    /// What the *next* lot of a sell would fetch — exposed before confirmation so diminishing
    /// returns are visible, not a surprise.
    next_unit: ?f32 = null,

    /// Whether this quote is takeable against a live encounter and the player's holdings.
    /// `food`/`biomass` are the player's holdings; a sell also needs the player to own the good,
    /// which the caller checks (component ownership is outside this leaf module). The satchel
    /// must hold everything the passerby is to hand over. Returns the specific `Refusal`.
    pub fn refusal(self: *const Quote, enc: *const Encounter, food: f32, biomass: f32) Refusal {
        if (!enc.dealable()) return .departed;
        if (self.rev != enc.id) return .stale;
        if (self.nth) |n| if (self.give.len > 0 and enc.soldOf(self.give.lines[0].item) != n) return .stale;
        if (self.stock == 0) return .sold_out;
        for (self.receive.slice()) |l| if (!enc.holds(l.item, l.qty)) return .sold_out;
        // Affordability: the player must hold every Food/Biomass line on the give side.
        if (self.give.qtyOf(.food) > food) return .unaffordable;
        if (self.give.qtyOf(.biomass) > biomass) return .unaffordable;
        return .none;
    }

    pub fn takeable(self: *const Quote, enc: *const Encounter, food: f32, biomass: f32) bool {
        return self.refusal(enc, food, biomass) == .none;
    }

    /// The same quote taken `lots` times over: every line scaled linearly. Stock counts lots.
    pub fn times(self: *const Quote, lots: u16) Quote {
        var q = self.*;
        const k: f32 = @floatFromInt(lots);
        for (q.give.lines[0..q.give.len]) |*l| l.qty *= k;
        for (q.receive.lines[0..q.receive.len]) |*l| l.qty *= k;
        return q;
    }
};

// ============================ The passerby's board ==========================
//
// The posted prices and the falling sell schedule. A buy is a flat price at the passerby's
// taking rate (a food for 3 materials, 2 materials for a food); a sell starts at its giving
// rate (a food fetches 2 materials, 3 materials fetch a food) and falls with each lot sold this
// visit, geometrically toward a floor that is never zero — so selling always beats throwing
// surplus away, yet a long sell-off earns less per lot than the first, and the spread means a
// round trip loses a third.

/// The tool a rank-2 tool's lot waits on: the passerby offers the fishing net only to a holder
/// of the fishing rod, the hand axe only to a holder of the hatchet. Null for every other ware.
pub fn prerequisite(w: Ware) ?Ware {
    return switch (w) {
        .fish_net => .fish_hook,
        .hand_axe => .whetstone,
        else => null,
    };
}

/// What the passerby pays for the **`n`-th** lot of `ware` sold this visit (0-based): materials
/// for a food or a tool, food for a lot of 3 materials. Geometric decline (`base · ratio^n`)
/// clamped to a `floor`, so it is **monotonically non-increasing** and always positive.
pub fn sell_value(ware: Ware, n: u32) f32 {
    const base: f32, const ratio: f32, const floor: f32 = switch (ware) {
        // Surplus food: 2 materials for the first, falling to half a material.
        .food => .{ 2.0, 0.75, 0.5 },
        // Surplus materials, by the lot of 3: a food for the first, falling faster.
        .biomass => .{ 1.0, 0.6, 0.25 },
        // A tool: the first fetches real value, a duplicate almost nothing.
        .fish_hook => .{ 8.0, 0.3, 1.0 },
        .whetstone => .{ 6.0, 0.3, 1.0 },
        .fish_net => .{ 16.0, 0.3, 1.0 },
        .hand_axe => .{ 13.0, 0.3, 1.0 },
    };
    const raw = base * std.math.pow(f32, ratio, @floatFromInt(n));
    return @max(floor, raw);
}

/// The units of `ware` one sell lot gives: 3 materials, otherwise one.
pub fn sell_lot(ware: Ware) f32 {
    return if (ware == .biomass) 3 else 1;
}

/// What a sell of `ware` is paid in: food for materials, materials for anything else.
pub fn paid_in(ware: Ware) Ware {
    return if (ware == .biomass) .food else .biomass;
}

/// The passerby's buy offer for `ware` this visit, its stock the whole lots the satchel holds.
pub fn buy_quote(enc: *const Encounter, ware: Ware) Quote {
    var q = Quote{ .id = 1 + @as(u32, @backingInt(ware)), .rev = enc.id, .direction = .buy, .give = .{}, .receive = .{} };
    var per_lot: f32 = 1;
    switch (ware) {
        .food => q.give.add(.biomass, 3),
        .biomass => {
            q.give.add(.food, 1);
            per_lot = 2;
        },
        .fish_hook => {
            q.give.add(.food, 2);
            q.give.add(.biomass, 8);
        },
        .whetstone => {
            q.give.add(.food, 2);
            q.give.add(.biomass, 6);
        },
        .fish_net => {
            q.give.add(.food, 5);
            q.give.add(.biomass, 20);
        },
        .hand_axe => {
            q.give.add(.food, 4);
            q.give.add(.biomass, 16);
        },
    }
    q.receive = Bundle.one(ware, per_lot);
    q.stock = @intFromFloat(@min(@floor((enc.stockOf(ware) + 1e-4) / per_lot), std.math.maxInt(u16)));
    return q;
}

/// The passerby's offer for the next lot of `ware` the player sells this visit, at its point on
/// the falling schedule, with `next_unit` already filled so the decline is visible before the
/// player confirms. Its stock is one lot while the satchel can pay for it, else zero.
pub fn sell_quote(enc: *const Encounter, ware: Ware) Quote {
    const n = enc.soldOf(ware);
    const pay = sell_value(ware, n);
    const in = paid_in(ware);
    return .{
        .id = 101 + @as(u32, @backingInt(ware)),
        .rev = enc.id,
        .direction = .sell,
        .give = Bundle.one(ware, sell_lot(ware)),
        .receive = Bundle.one(in, pay),
        .stock = @intFromBool(enc.holds(in, pay)),
        .nth = n,
        .next_unit = sell_value(ware, n + 1),
    };
}

// ============================ The Act II merchant's visits =========================
//
// The Coin Merchant stays a few days, packs up, and comes back after a short absence with fresh
// stock. A smaller clock than the passerby's: two phases, a visit identity that bumps on each
// return (so a lot sold out last visit is restocked), and an `Event` at each edge. Ticked off the
// sim clock in Act II only, by the `merchant` system (`systems/merchant.zig`), which holds the
// merchant's lots; the dialog and the strip read it.

/// The merchant's lot records (`systems/merchant.zig`'s `lots`), which that file asserts.
pub const merchant_lot_count = 19;

pub const MerchantVisit = struct {
    present: bool = true,
    /// Bumps on every return.
    id: u32 = 1,
    /// Seconds left in the current phase; negative until the first tick seeds the stay.
    remaining: f32 = -1,
    /// Lots sold this visit, by lot index; a lot's stock left is its record's stock less this.
    /// The `merchant` system clears it when a new visit begins.
    taken: [merchant_lot_count]u16 = @splat(0),

    pub fn dealable(self: *const MerchantVisit) bool {
        return self.present;
    }
};

pub const MerchantSchedule = struct {
    stay_days: f32 = 3.0,
    away_days: f32 = 1.5,
};

/// Advance the merchant by `dt` seconds; a departure and a return are its `Event`s.
pub fn tickMerchant(v: *MerchantVisit, dt: f32, sched: MerchantSchedule, spd: f32) Event {
    if (v.remaining < 0) v.remaining = sched.stay_days * spd;
    v.remaining -= dt;
    if (v.remaining > 0) return .none;
    if (v.present) {
        v.present = false;
        v.remaining = sched.away_days * spd;
        return .departed;
    }
    v.present = true;
    v.id += 1;
    v.remaining = sched.stay_days * spd;
    return .arrived;
}

// ============================ Tests =====================================================

const testing = std.testing;
const secs_per_day: f32 = 120.0; // an arbitrary clock for the tests

test "encounter walks absent → approaching → present → departed → absent on the clock" {
    var enc = Encounter{}; // absent, remaining 0, id 0
    const sched = Schedule{};

    // First tick from a zeroed absent state: remaining hits 0 immediately → approaching.
    try testing.expectEqual(Event.none, tick(&enc, 0.001, sched, secs_per_day));
    try testing.expectEqual(Phase.approaching, enc.phase);
    try testing.expectEqual(@as(u32, 0), enc.id); // not a visit yet

    // Burn the approach window → present (an arrival: id bumps, satchel fills).
    try testing.expectEqual(Event.arrived, tick(&enc, sched.approach_days * secs_per_day, sched, secs_per_day));
    try testing.expectEqual(Phase.present, enc.phase);
    try testing.expectEqual(@as(u32, 1), enc.id);
    try testing.expect(enc.dealable());
    try testing.expectEqual(@as(f32, 20), enc.stockOf(.biomass));

    // Burn the linger window → departed.
    try testing.expectEqual(Event.departed, tick(&enc, sched.linger_days * secs_per_day, sched, secs_per_day));
    try testing.expectEqual(Phase.departed, enc.phase);
    try testing.expect(!enc.dealable());

    // Burn the depart beat → absent (satchel cleared, no event).
    try testing.expectEqual(Event.none, tick(&enc, sched.depart_days * secs_per_day, sched, secs_per_day));
    try testing.expectEqual(Phase.absent, enc.phase);
    try testing.expectEqual(@as(f32, 0), enc.stockOf(.biomass));
}

test "each visit bumps a stable identity and refills the satchel" {
    var enc = Encounter{};
    const sched = Schedule{};

    // Run a full cycle to the first arrival.
    _ = tick(&enc, 0.001, sched, secs_per_day); // → approaching
    _ = tick(&enc, sched.approach_days * secs_per_day, sched, secs_per_day); // → present (id 1)
    try testing.expectEqual(@as(u32, 1), enc.id);

    // Spend some stock this visit, then complete the cycle back to a second arrival.
    enc.take(.biomass, 5);
    try testing.expectEqual(@as(f32, 15), enc.stockOf(.biomass));
    _ = tick(&enc, sched.linger_days * secs_per_day, sched, secs_per_day); // → departed
    _ = tick(&enc, sched.depart_days * secs_per_day, sched, secs_per_day); // → absent
    _ = tick(&enc, sched.gap_days * secs_per_day, sched, secs_per_day); // → approaching
    _ = tick(&enc, sched.approach_days * secs_per_day, sched, secs_per_day); // → present (id 2)

    try testing.expectEqual(@as(u32, 2), enc.id); // a *different* passerby
    try testing.expectEqual(@as(f32, 20), enc.stockOf(.biomass)); // the satchel refilled
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
    enc.stock[@backingInt(Ware.food)] = 3;
    enc.take(.food, 5); // more than held
    try testing.expectEqual(@as(f32, 0), enc.stockOf(.food));
    enc.give(.food, 4);
    try testing.expectEqual(@as(f32, 4), enc.stockOf(.food));
}

test "bundle carries typed lines and reports quantities" {
    var b = Bundle{};
    b.add(.food, 2.5);
    b.add(.biomass, 6);
    try testing.expectEqual(@as(usize, 2), b.len);
    try testing.expectApproxEqAbs(@as(f32, 2.5), b.qtyOf(.food), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 6), b.qtyOf(.biomass), 1e-6);
    try testing.expectEqual(@as(f32, 0), b.qtyOf(.fish_hook)); // absent ⇒ 0
    // The one-item convenience form.
    const w = Bundle.one(.whetstone, 1);
    try testing.expectEqual(@as(f32, 1), w.qtyOf(.whetstone));
}

test "quote refusal distinguishes departed, stale, sold-out, unaffordable, and takeable" {
    var enc = Encounter{ .phase = .present, .id = 3 };
    enc.stock[@backingInt(Ware.biomass)] = 10;
    enc.stock[@backingInt(Ware.fish_hook)] = 1;

    // A buy: give 2 food + 4 materials, receive a fish hook, captured at the live revision.
    var q = Quote{
        .id = 1,
        .rev = 3,
        .direction = .buy,
        .give = blk: {
            var g = Bundle{};
            g.add(.food, 2);
            g.add(.biomass, 4);
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
    // The satchel no longer holds the rod ⇒ sold_out.
    enc.stock[@backingInt(Ware.fish_hook)] = 0;
    try testing.expectEqual(Refusal.sold_out, q.refusal(&enc, 5, 10));
    enc.stock[@backingInt(Ware.fish_hook)] = 1;
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

test "sell value declines monotonically to a positive floor" {
    inline for (std.enums.values(Ware)) |ware| {
        var prev = sell_value(ware, 0);
        try testing.expect(prev > 0); // the first unit always pays something
        var n: u32 = 1;
        while (n < 20) : (n += 1) {
            const v = sell_value(ware, n);
            try testing.expect(v <= prev); // monotonically non-increasing
            try testing.expect(v > 0); // never zero — selling is never strictly dominated
            prev = v;
        }
    }
    // The first food unit pays clearly more than the floor — production for sale is not
    // strictly dominated (the early units are worth trading).
    try testing.expect(sell_value(.food, 0) > sell_value(.food, 10));
    try testing.expectApproxEqAbs(@as(f32, 0.5), sell_value(.food, 50), 1e-4); // bottomed at the floor
}

test "sell_quote exposes the next unit's diminished value before confirmation" {
    var enc = Encounter{ .phase = .present, .id = 3, .stock = (Schedule{}).satchel };
    const q = sell_quote(&enc, .food);
    try testing.expectEqual(Direction.sell, q.direction);
    try testing.expectEqual(@as(u32, 3), q.rev);
    // This unit is the 0-th value; next_unit is the 1st — strictly lower.
    try testing.expectApproxEqAbs(@as(f32, 2), q.receive.qtyOf(.biomass), 1e-5);
    try testing.expect(q.next_unit.? < q.receive.qtyOf(.biomass));
    try testing.expectApproxEqAbs(sell_value(.food, 1), q.next_unit.?, 1e-5);
    try testing.expect(q.takeable(&enc, 1, 0));
    // A lot sold since the quote was read moves the price: the quote is stale.
    enc.sold[@backingInt(Ware.food)] = 1;
    try testing.expectEqual(Refusal.stale, q.refusal(&enc, 1, 0));
    try testing.expectApproxEqAbs(@as(f32, 1.5), sell_quote(&enc, .food).receive.qtyOf(.biomass), 1e-5);
}

test "the board's spread: food buys at 3 materials and sells for 2, so a round trip loses a third" {
    const enc = Encounter{ .phase = .present, .id = 1, .stock = (Schedule{}).satchel };
    const buy_food = buy_quote(&enc, .food);
    try testing.expectApproxEqAbs(@as(f32, 3), buy_food.give.qtyOf(.biomass), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1), buy_food.receive.qtyOf(.food), 1e-6);
    try testing.expectEqual(@as(u16, 8), buy_food.stock); // eight food in the satchel
    const buy_mat = buy_quote(&enc, .biomass);
    try testing.expectApproxEqAbs(@as(f32, 1), buy_mat.give.qtyOf(.food), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 2), buy_mat.receive.qtyOf(.biomass), 1e-6);
    try testing.expectEqual(@as(u16, 10), buy_mat.stock); // twenty materials, two a lot
    const sell_mat = sell_quote(&enc, .biomass);
    try testing.expectApproxEqAbs(@as(f32, 3), sell_mat.give.qtyOf(.biomass), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1), sell_mat.receive.qtyOf(.food), 1e-6);
    // 3 materials buy a food, which buys back 2 materials.
    try testing.expectApproxEqAbs(@as(f32, 2.0 / 3.0), buy_mat.receive.qtyOf(.biomass) / buy_food.give.qtyOf(.biomass), 1e-6);
    // The tools' prices.
    try testing.expectApproxEqAbs(@as(f32, 20), buy_quote(&enc, .fish_net).give.qtyOf(.biomass), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 4), buy_quote(&enc, .hand_axe).give.qtyOf(.food), 1e-6);
    try testing.expectEqual(@as(?Ware, .whetstone), prerequisite(.hand_axe));
    try testing.expectEqual(@as(?Ware, null), prerequisite(.whetstone));
}

test "a sell the satchel cannot pay for is out of stock" {
    var enc = Encounter{ .phase = .present, .id = 1 };
    enc.stock[@backingInt(Ware.biomass)] = 1.5; // less than a food's 2 materials
    const q = sell_quote(&enc, .food);
    try testing.expectEqual(@as(u16, 0), q.stock);
    try testing.expectEqual(Refusal.sold_out, q.refusal(&enc, 5, 0));
}

test "the merchant stays, leaves, and returns as a new visit" {
    var v = MerchantVisit{};
    const sched = MerchantSchedule{};
    try testing.expectEqual(Event.none, tickMerchant(&v, 1, sched, secs_per_day));
    try testing.expect(v.dealable());
    try testing.expectApproxEqAbs(sched.stay_days * secs_per_day - 1, v.remaining, 1e-3);

    try testing.expectEqual(Event.departed, tickMerchant(&v, sched.stay_days * secs_per_day, sched, secs_per_day));
    try testing.expect(!v.dealable());
    try testing.expectEqual(@as(u32, 1), v.id);

    try testing.expectEqual(Event.arrived, tickMerchant(&v, sched.away_days * secs_per_day, sched, secs_per_day));
    try testing.expect(v.dealable());
    try testing.expectEqual(@as(u32, 2), v.id); // a fresh visit
}
