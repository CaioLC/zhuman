//! `market` — the Act I Passerby, as authoritative **simulation** state.
//!
//! Act I's only counterparty is a passerby who wanders in, lingers a while with a finite
//! satchel, and leaves, and who comes only to an actor with a camp (`Schedule.camp_kinds`: the
//! caller passes the kinds the player owns, so this module stays blind to the world). This module
//! owns that encounter as a clock-driven **state machine** —
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
//! **The spread.** The passerby values a food at 2 materials when an agent gives food and at 3
//! when an agent takes it, so a round trip loses a third: buying food is 3 materials a unit,
//! buying materials 2 for a food. A rank-2 tool is offered only to a holder of the rank-1 tool of
//! its family, and the work gloves only to a holder of the hatchet (`prerequisite`).
//!
//! **Memory.** Within a visit every price is fixed and every lot finite, in both directions: the
//! satchel bounds what the passerby hands over and `wanted` bounds the lots of a ware it takes.
//! Between visits it remembers what moved. Each ware carries a price `level` (`modifier`: 0.6
//! to 1.4 of the board's price); when the passerby leaves, `Encounter.remember` rolls each level
//! against the lots traded that visit (`reprice`), so a ware that sold well is likely dearer on
//! the next visit and one that sat unsold likely cheaper, never certainly. The tallies count
//! lots whoever traded them; nothing here names the player. The Coin Merchant keeps the same
//! memory over its lots (`MerchantVisit`).
//!
//! The encounter clock and its finite satchel are here, with the typed bundle/quote contracts
//! and the board's prices below; `barter.zig` resolves a quote atomically and `capital.zig` owns
//! tool supersession.

const std = @import("std");

// ============================ A trader's memory ================================
//
// What a trader carries from one visit to the next: a price level per ware, moved by chance
// against the lots traded in the visit that just ended. Shared by the passerby and the Coin
// Merchant, and blind to who traded.

/// The bound of a price level either side of the board's price: four steps of a tenth.
pub const max_level: i8 = 4;
/// The chance one traded lot is noticed; `noticed` compounds it over a visit's lots.
pub const notice_per_lot: f32 = 0.3;
/// The chance a ware that did not move at all is repriced.
pub const notice_idle: f32 = 0.3;

/// The price multiplier at `level`: 0.6 at the floor, 1 on the board, 1.4 at the ceiling.
pub fn modifier(level: i8) f32 {
    return 1.0 + 0.1 * @as(f32, @floatFromInt(std.math.clamp(level, -max_level, max_level)));
}

/// A board amount at `level`, to the hundredth.
pub fn priced(base: f32, level: i8) f32 {
    return @round(base * modifier(level) * 100) / 100;
}

/// The chance a trader reprices a ware after `lots` of it moved in one visit: none for none,
/// rising with each lot and never certain.
pub fn noticed(lots: u32) f32 {
    return 1.0 - std.math.pow(f32, 1.0 - notice_per_lot, @floatFromInt(lots));
}

/// One ware's visit, from the trader's side: the lots it handed over (`out`) and took (`in`),
/// and whether it deals in that direction at all.
pub const Flow = struct { out: u32 = 0, in: u32 = 0, sells: bool = true, buys: bool = true };

/// A ware's level after a visit of `flow`. Two independent rolls. What the trader sells: lots
/// taken raise the level with chance `noticed`, none taken lower it with chance `notice_idle`.
/// What the trader buys: lots brought lower it, none brought raise it, by the same chances. One
/// step a roll, clamped to `max_level`.
pub fn reprice(level: i8, flow: Flow, rng: std.Random) i8 {
    var l: i8 = level;
    if (flow.sells) {
        if (flow.out > 0) {
            if (rng.float(f32) < noticed(flow.out)) l += 1;
        } else if (rng.float(f32) < notice_idle) l -= 1;
    }
    if (flow.buys) {
        if (flow.in > 0) {
            if (rng.float(f32) < noticed(flow.in)) l -= 1;
        } else if (rng.float(f32) < notice_idle) l += 1;
    }
    return std.math.clamp(l, -max_level, max_level);
}

/// Where the passerby is in a visit. `absent` — no one here (the gap between visits, which
/// counts down only while the player has a camp: `Schedule.camp_kinds`);
/// `approaching` — seen coming, not yet dealable (the strip can foreshadow); `present` — here
/// with wares, the only phase a deal opens in; `departed` — just left (a beat before `absent`,
/// so the departure reads as an event rather than a silent disappearance).
pub const Phase = enum { absent, approaching, present, departed };

/// The kinds of thing a passerby's satchel can hold in Act I: Food, generic Materials, and the
/// six goods it carries — the fishing rod (`fish_hook`) and hatchet (`whetstone`), their
/// rank-2 successors, the fishing net and hand axe, and the work gloves and cookpot. The amount
/// per slot lives in `Encounter.stock`, indexed by `@backingInt`; a ware appended here reads as
/// zero from a save written before it.
pub const Ware = enum { food, biomass, fish_hook, whetstone, fish_net, hand_axe, work_gloves, cookpot };
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
    /// Fractional, since a repriced lot pays fractions. Refilled on arrival, drawn down
    /// by what the passerby hands over and topped up by what it takes, never regenerated until
    /// the next arrival.
    stock: [ware_count]f32 = @splat(0),
    /// What this visit has moved, from the player's side — signed units of each `Ware` (paid
    /// out negative, received positive). The trade dialog's footer reads it; arrival clears it.
    visit: [ware_count]f32 = @splat(0),
    /// Lots of each `Ware` sold to the passerby this visit, by anyone, through its sell lot:
    /// counted against `wanted` and read by `remember`. Arrival clears it.
    sold: [ware_count]u16 = @splat(0),
    /// Lots of each `Ware` bought from the passerby this visit, by anyone, through its buy lot.
    /// Read by `remember`; arrival clears it.
    bought: [ware_count]u16 = @splat(0),
    /// The price level of each `Ware`, carried from visit to visit (`modifier`). Food's level
    /// is the one rate food and materials change hands at, so materials' own stays 0.
    level: [ware_count]i8 = @splat(0),

    /// Whether a deal can be opened right now — only while the passerby is actually present.
    /// The UI gates the TRADE action on this; tab visibility never enters into it.
    pub fn dealable(self: *const Encounter) bool {
        return self.phase == .present;
    }

    /// The amount of `w` still in the satchel this visit.
    pub fn stockOf(self: *const Encounter, w: Ware) f32 {
        return self.stock[@backingInt(w)];
    }

    /// Lots of `w` sold to the passerby this visit.
    pub fn soldOf(self: *const Encounter, w: Ware) u16 {
        return self.sold[@backingInt(w)];
    }

    /// The price level of `w`: food's for food and materials, a tool's own.
    pub fn levelOf(self: *const Encounter, w: Ware) i8 {
        return self.level[@backingInt(if (w == .biomass) Ware.food else w)];
    }

    /// The lots of `w` the passerby still takes this visit.
    pub fn wantsLeft(self: *const Encounter, w: Ware) u16 {
        return wanted(w) -| self.soldOf(w);
    }

    /// The visit is over: roll every ware's level against what moved (`reprice`). Food for
    /// materials is one exchange met from both tabs, so food's flow is every lot that moved
    /// food out of the satchel against every lot that moved it in; a tool's is its own lots.
    pub fn remember(self: *Encounter, rng: std.Random) void {
        const f = @backingInt(Ware.food);
        const b = @backingInt(Ware.biomass);
        for (&self.level, 0..) |*l, i| {
            if (i == b) continue;
            const flow: Flow = if (i == f)
                .{ .out = @as(u32, self.bought[f]) + self.sold[b], .in = @as(u32, self.bought[b]) + self.sold[f] }
            else
                .{ .out = self.bought[i], .in = self.sold[i] };
            l.* = reprice(l.*, flow, rng);
        }
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
    /// The camp a visit waits on: the buildable good kinds the player owns before the passerby
    /// sets out (absent → approaching). Nobody comes to trade with someone who has nothing.
    camp_kinds: u32 = 2,
    /// The quiet gap between visits (absent → approaching), counted only while the camp stands.
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
        s[@backingInt(Ware.work_gloves)] = 1;
        s[@backingInt(Ware.cookpot)] = 1;
        break :blk s;
    },
};

/// What a tick did. The passerby system turns it into an `Arrived` or `Departed` fact.
pub const Event = enum { none, arrived, departed };

/// Advance the encounter by `dt` seconds against `sched`, the player owning `kinds` buildable
/// good kinds. Deterministic and clock-driven: the same elapsed time always produces the same
/// transitions, and nothing here reads the calendar day. Returns the transition that fired this
/// tick (`none` if still within a phase). A phase can only advance one step per tick; `dt` is a
/// frame delta, far smaller than any phase, so that is never a real limit.
///
/// While `kinds` is below `sched.camp_kinds` an absent encounter stands still: its gap does not
/// count down, so no visit begins and none is banked. A run starts with no gap left, so the
/// first camp is seen approaching the tick it stands; a gap interrupted by the camp's loss
/// resumes where it stopped. A visit already under way runs its course whatever `kinds` is.
pub fn tick(enc: *Encounter, dt: f32, sched: Schedule, spd: f32, kinds: u32) Event {
    if (enc.phase == .absent and kinds < sched.camp_kinds) return .none;
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
            enc.bought = @splat(0);
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

/// A thing a bundle can carry: Food, generic Materials, and the goods the passerby deals in
/// (which map to owned-good components on the player side). `Item = Ware`.
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

/// Which way a quote runs, from the agent's point of view. `buy` — the agent **gives** Food/
/// Materials and **receives** a ware; `sell` — the agent **gives** a ware and **receives**
/// Food or Materials. One enum both the dialog tabs and the resolver read.
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
/// board this is). Its amounts are the board's at the visit's price levels, fixed until the
/// passerby leaves.
pub const Quote = struct {
    id: u32,
    rev: u32,
    direction: Direction,
    give: Bundle,
    receive: Bundle,
    /// Lots of this offer still available this visit: a buy, what the satchel holds of it; a
    /// sell, what the passerby still wants of the ware and its satchel can pay for. 0 ⇒ sold out.
    stock: u16 = 1,

    /// Whether this quote is takeable against a live encounter and the player's holdings.
    /// `food`/`biomass` are the player's holdings; a sell also needs the player to own the good,
    /// which the caller checks (component ownership is outside this leaf module). The satchel
    /// must hold everything the passerby is to hand over. Returns the specific `Refusal`.
    pub fn refusal(self: *const Quote, enc: *const Encounter, food: f32, biomass: f32) Refusal {
        if (!enc.dealable()) return .departed;
        if (self.rev != enc.id) return .stale;
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
// The posted prices. Food and materials change hands at one rate: a food costs 3 materials to
// take and fetches 2 to give, both scaled by food's price level, so the two tabs quote the same
// exchange and a round trip loses a third at every level. A tool costs its food and materials
// scaled by its own level, and sells back for its materials alone at the same level.

/// The tool a lot waits on: the passerby offers the fishing net only to a holder of the fishing
/// rod, the hand axe and the work gloves only to a holder of the hatchet. Null for every other
/// ware.
pub fn prerequisite(w: Ware) ?Ware {
    return switch (w) {
        .fish_net => .fish_hook,
        .hand_axe, .work_gloves => .whetstone,
        else => null,
    };
}

/// Materials a food costs to take, at level 0.
pub const food_ask: f32 = 3;
/// Materials a food fetches when given, at level 0.
pub const food_bid: f32 = 2;

/// A tool's board price: the food and the materials a buy gives. Zero for food and materials.
pub fn tool_price(ware: Ware) struct { food: f32, biomass: f32 } {
    return switch (ware) {
        .food, .biomass => .{ .food = 0, .biomass = 0 },
        .fish_hook => .{ .food = 3, .biomass = 10 },
        .whetstone => .{ .food = 4, .biomass = 12 },
        .fish_net => .{ .food = 7, .biomass = 28 },
        .hand_axe => .{ .food = 6, .biomass = 24 },
        .work_gloves => .{ .food = 5, .biomass = 18 },
        .cookpot => .{ .food = 10, .biomass = 40 },
    };
}

/// The lots of `ware` the passerby takes in one visit: a trickle of food and materials, one of
/// each tool.
pub fn wanted(ware: Ware) u16 {
    return switch (ware) {
        .food => 6,
        .biomass => 4,
        else => 1,
    };
}

/// What the passerby pays for one sell lot of `ware` this visit: materials for a food or a
/// tool, food for a lot of 3 materials. Fixed for the visit.
pub fn sell_value(enc: *const Encounter, ware: Ware) f32 {
    const level = enc.levelOf(ware);
    return switch (ware) {
        .food => priced(food_bid, level),
        // 3 materials at the rate a food costs to take.
        .biomass => @round(sell_lot(.biomass) / (food_ask * modifier(level)) * 100) / 100,
        else => priced(tool_price(ware).biomass, level),
    };
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
    const level = enc.levelOf(ware);
    var per_lot: f32 = 1;
    switch (ware) {
        .food => q.give.add(.biomass, priced(food_ask, level)),
        .biomass => {
            // 2 materials at the rate a food fetches when given.
            per_lot = 2;
            q.give.add(.food, @round(per_lot / (food_bid * modifier(level)) * 100) / 100);
        },
        else => {
            const p = tool_price(ware);
            q.give.add(.food, priced(p.food, level));
            q.give.add(.biomass, priced(p.biomass, level));
        },
    }
    q.receive = Bundle.one(ware, per_lot);
    q.stock = @intFromFloat(@min(@floor((enc.stockOf(ware) + 1e-4) / per_lot), std.math.maxInt(u16)));
    return q;
}

/// The passerby's offer for `ware` sold to it this visit, at the visit's fixed price. Its stock
/// is the lots it still wants that its satchel can pay for.
pub fn sell_quote(enc: *const Encounter, ware: Ware) Quote {
    const pay = sell_value(enc, ware);
    const in = paid_in(ware);
    const payable: f32 = @min(@floor((enc.stockOf(in) + 1e-4) / pay), std.math.maxInt(u16));
    return .{
        .id = 101 + @as(u32, @backingInt(ware)),
        .rev = enc.id,
        .direction = .sell,
        .give = Bundle.one(ware, sell_lot(ware)),
        .receive = Bundle.one(in, pay),
        .stock = @min(enc.wantsLeft(ware), @as(u16, @intFromFloat(payable))),
    };
}

// ============================ The Act II merchant's visits =========================
//
// The Coin Merchant stays a few days, packs up, and comes back after a short absence with fresh
// stock. A smaller clock than the passerby's: two phases, a visit identity that bumps on each
// return (so a lot sold out last visit is restocked), and an `Event` at each edge. It keeps the
// passerby's memory: a price level per lot, rolled when the cart leaves against the lots dealt
// that visit. Ticked off the
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
    /// Lots dealt this visit, by lot index and by anyone; a lot's stock left is its record's
    /// stock less this. The `merchant` system clears it when a new visit begins.
    taken: [merchant_lot_count]u16 = @splat(0),
    /// The price level of each lot's coin side, carried from visit to visit (`modifier`). The
    /// lots of one item share a level, kept at the first of them (`systems/merchant.zig`).
    level: [merchant_lot_count]i8 = @splat(0),

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
    try testing.expectEqual(Event.none, tick(&enc, 0.001, sched, secs_per_day, sched.camp_kinds));
    try testing.expectEqual(Phase.approaching, enc.phase);
    try testing.expectEqual(@as(u32, 0), enc.id); // not a visit yet

    // Burn the approach window → present (an arrival: id bumps, satchel fills).
    try testing.expectEqual(Event.arrived, tick(&enc, sched.approach_days * secs_per_day, sched, secs_per_day, sched.camp_kinds));
    try testing.expectEqual(Phase.present, enc.phase);
    try testing.expectEqual(@as(u32, 1), enc.id);
    try testing.expect(enc.dealable());
    try testing.expectEqual(@as(f32, 20), enc.stockOf(.biomass));

    // Burn the linger window → departed.
    try testing.expectEqual(Event.departed, tick(&enc, sched.linger_days * secs_per_day, sched, secs_per_day, sched.camp_kinds));
    try testing.expectEqual(Phase.departed, enc.phase);
    try testing.expect(!enc.dealable());

    // Burn the depart beat → absent (satchel cleared, no event).
    try testing.expectEqual(Event.none, tick(&enc, sched.depart_days * secs_per_day, sched, secs_per_day, sched.camp_kinds));
    try testing.expectEqual(Phase.absent, enc.phase);
    try testing.expectEqual(@as(f32, 0), enc.stockOf(.biomass));
}

test "each visit bumps a stable identity and refills the satchel" {
    var enc = Encounter{};
    const sched = Schedule{};

    // Run a full cycle to the first arrival.
    _ = tick(&enc, 0.001, sched, secs_per_day, sched.camp_kinds); // → approaching
    _ = tick(&enc, sched.approach_days * secs_per_day, sched, secs_per_day, sched.camp_kinds); // → present (id 1)
    try testing.expectEqual(@as(u32, 1), enc.id);

    // Spend some stock this visit, then complete the cycle back to a second arrival.
    enc.take(.biomass, 5);
    try testing.expectEqual(@as(f32, 15), enc.stockOf(.biomass));
    _ = tick(&enc, sched.linger_days * secs_per_day, sched, secs_per_day, sched.camp_kinds); // → departed
    _ = tick(&enc, sched.depart_days * secs_per_day, sched, secs_per_day, sched.camp_kinds); // → absent
    _ = tick(&enc, sched.gap_days * secs_per_day, sched, secs_per_day, sched.camp_kinds); // → approaching
    _ = tick(&enc, sched.approach_days * secs_per_day, sched, secs_per_day, sched.camp_kinds); // → present (id 2)

    try testing.expectEqual(@as(u32, 2), enc.id); // a *different* passerby
    try testing.expectEqual(@as(f32, 20), enc.stockOf(.biomass)); // the satchel refilled
}

test "no one sets out for an actor without a camp; the first camp is seen approaching at once" {
    var enc = Encounter{};
    const sched = Schedule{};
    // Below the camp, however long it waits, the encounter stays absent and banks nothing.
    try testing.expectEqual(Event.none, tick(&enc, 30 * secs_per_day, sched, secs_per_day, sched.camp_kinds - 1));
    try testing.expectEqual(Phase.absent, enc.phase);
    try testing.expectEqual(@as(f32, 0), enc.remaining);
    try testing.expectEqual(Event.none, tick(&enc, 0.001, sched, secs_per_day, 0));
    try testing.expectEqual(Phase.absent, enc.phase);
    // The camp stands: the next tick is an approach.
    try testing.expectEqual(Event.none, tick(&enc, 0.001, sched, secs_per_day, sched.camp_kinds));
    try testing.expectEqual(Phase.approaching, enc.phase);
}

test "a visit under way runs its course when the camp is lost; the next waits for it" {
    var enc = Encounter{};
    const sched = Schedule{};
    const camp = sched.camp_kinds;
    _ = tick(&enc, 0.001, sched, secs_per_day, camp); // → approaching
    // The camp goes while the passerby is on the way: it still arrives, lingers and leaves.
    try testing.expectEqual(Event.arrived, tick(&enc, sched.approach_days * secs_per_day, sched, secs_per_day, 0));
    try testing.expect(enc.dealable());
    try testing.expectEqual(Event.departed, tick(&enc, sched.linger_days * secs_per_day, sched, secs_per_day, 0));
    _ = tick(&enc, sched.depart_days * secs_per_day, sched, secs_per_day, 0); // → absent
    try testing.expectEqual(Phase.absent, enc.phase);
    // No camp: the gap does not count down, and no new visit begins.
    _ = tick(&enc, 10 * sched.gap_days * secs_per_day, sched, secs_per_day, camp - 1);
    try testing.expectEqual(Phase.absent, enc.phase);
    try testing.expectApproxEqAbs(sched.gap_days * secs_per_day, enc.remaining, 1e-3);
    // The camp is back: the gap runs in full before the next approach.
    _ = tick(&enc, sched.gap_days * secs_per_day * 0.5, sched, secs_per_day, camp);
    try testing.expectEqual(Phase.absent, enc.phase);
    _ = tick(&enc, sched.gap_days * secs_per_day * 0.5, sched, secs_per_day, camp);
    try testing.expectEqual(Phase.approaching, enc.phase);
    try testing.expectEqual(@as(u32, 1), enc.id);
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

test "a sell is fixed for the visit and bounded by what the passerby wants" {
    var enc = Encounter{ .phase = .present, .id = 3, .stock = (Schedule{}).satchel };
    const q = sell_quote(&enc, .food);
    try testing.expectEqual(Direction.sell, q.direction);
    try testing.expectEqual(@as(u32, 3), q.rev);
    try testing.expectApproxEqAbs(@as(f32, 2), q.receive.qtyOf(.biomass), 1e-5);
    try testing.expectEqual(wanted(.food), q.stock);
    try testing.expect(q.takeable(&enc, 1, 0));
    // Lots sold this visit leave the price alone and take from what is wanted.
    enc.sold[@backingInt(Ware.food)] = 2;
    const again = sell_quote(&enc, .food);
    try testing.expectApproxEqAbs(@as(f32, 2), again.receive.qtyOf(.biomass), 1e-5);
    try testing.expectEqual(wanted(.food) - 2, again.stock);
    try testing.expect(q.takeable(&enc, 1, 0)); // the earlier quote still stands
    enc.sold[@backingInt(Ware.food)] = wanted(.food);
    try testing.expectEqual(@as(u16, 0), sell_quote(&enc, .food).stock);
    // A tool is wanted once.
    try testing.expectEqual(@as(u16, 1), sell_quote(&enc, .whetstone).stock);
}

test "a price level scales the board, keeps the spread, and bounds at 0.6 and 1.4" {
    try testing.expectApproxEqAbs(@as(f32, 0.6), modifier(-max_level), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.4), modifier(max_level), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.4), modifier(100), 1e-6);
    var enc = Encounter{ .phase = .present, .id = 1, .stock = (Schedule{}).satchel };
    var level: i8 = -max_level;
    while (level <= max_level) : (level += 1) {
        enc.level[@backingInt(Ware.food)] = level;
        enc.level[@backingInt(Ware.whetstone)] = level;
        // Food for materials is one rate from either tab, and a round trip loses a third.
        const take = buy_quote(&enc, .food).give.qtyOf(.biomass); // materials a food costs
        const fetch = sell_quote(&enc, .food).receive.qtyOf(.biomass); // materials a food fetches
        try testing.expectApproxEqAbs(@as(f32, 2.0 / 3.0), fetch / take, 1e-2);
        const mats = buy_quote(&enc, .biomass);
        try testing.expectApproxEqAbs(fetch, mats.receive.qtyOf(.biomass) / mats.give.qtyOf(.food), 5e-2);
        const food = sell_quote(&enc, .biomass);
        try testing.expectApproxEqAbs(take, food.give.qtyOf(.biomass) / food.receive.qtyOf(.food), 5e-2);
        // A tool sells back for less than it costs.
        const hatchet = buy_quote(&enc, .whetstone);
        try testing.expectApproxEqAbs(12 * modifier(level), hatchet.give.qtyOf(.biomass), 1e-2);
        try testing.expectApproxEqAbs(4 * modifier(level), hatchet.give.qtyOf(.food), 1e-2);
        try testing.expectApproxEqAbs(hatchet.give.qtyOf(.biomass), sell_value(&enc, .whetstone), 1e-4);
    }
}

test "reprice: trades make a move likely, never certain; an unmoved ware drifts the other way" {
    var prng = std.Random.DefaultPrng.init(11);
    const rng = prng.random();
    try testing.expectEqual(@as(f32, 0), noticed(0));
    try testing.expectApproxEqAbs(notice_per_lot, noticed(1), 1e-6);
    try testing.expect(noticed(3) > noticed(2) and noticed(40) < 1.0001);

    const trials = 4000;
    var up_one: u32 = 0;
    var up_five: u32 = 0;
    var down_idle: u32 = 0;
    var down_glut: u32 = 0;
    var up_unsupplied: u32 = 0;
    for (0..trials) |_| {
        // One-directional flows, so a single roll decides.
        if (reprice(0, .{ .out = 1, .buys = false }, rng) == 1) up_one += 1;
        if (reprice(0, .{ .out = 5, .buys = false }, rng) == 1) up_five += 1;
        if (reprice(0, .{ .buys = false }, rng) == -1) down_idle += 1;
        if (reprice(0, .{ .in = 5, .sells = false }, rng) == -1) down_glut += 1;
        if (reprice(0, .{ .sells = false }, rng) == 1) up_unsupplied += 1;
    }
    const n: f32 = trials;
    try testing.expectApproxEqAbs(noticed(1), @as(f32, @floatFromInt(up_one)) / n, 0.04);
    try testing.expectApproxEqAbs(noticed(5), @as(f32, @floatFromInt(up_five)) / n, 0.04);
    try testing.expectApproxEqAbs(notice_idle, @as(f32, @floatFromInt(down_idle)) / n, 0.04);
    try testing.expectApproxEqAbs(noticed(5), @as(f32, @floatFromInt(down_glut)) / n, 0.04);
    try testing.expectApproxEqAbs(notice_idle, @as(f32, @floatFromInt(up_unsupplied)) / n, 0.04);
    // The bounds hold.
    for (0..50) |_| {
        try testing.expectEqual(max_level, reprice(max_level, .{ .out = 99, .buys = false }, rng));
        try testing.expectEqual(-max_level, reprice(-max_level, .{ .in = 99, .sells = false }, rng));
    }
}

test "the passerby remembers across visits: levels survive an arrival, the tallies do not" {
    var prng = std.Random.DefaultPrng.init(5);
    var enc = Encounter{ .phase = .present, .id = 1, .stock = (Schedule{}).satchel };
    const sched = Schedule{};
    // A visit where the hatchet is bought over and over ends dearer, in time.
    const w = @backingInt(Ware.whetstone);
    var visits: u32 = 0;
    while (enc.level[w] < max_level and visits < 200) : (visits += 1) {
        enc.bought[w] = 1;
        enc.remember(prng.random());
    }
    try testing.expect(visits < 200);
    try testing.expect(enc.level[@backingInt(Ware.biomass)] == 0); // materials ride food's level
    const dear = buy_quote(&enc, .whetstone).give.qtyOf(.biomass);
    try testing.expect(dear > 12);

    // Leave and come back: the tallies clear, the level stays.
    enc.phase = .present;
    enc.remaining = 0;
    const kept = enc.level;
    _ = tick(&enc, 1, sched, secs_per_day, sched.camp_kinds); // → departed
    _ = tick(&enc, sched.depart_days * secs_per_day, sched, secs_per_day, sched.camp_kinds); // → absent
    _ = tick(&enc, sched.gap_days * secs_per_day, sched, secs_per_day, sched.camp_kinds); // → approaching
    _ = tick(&enc, sched.approach_days * secs_per_day, sched, secs_per_day, sched.camp_kinds); // → present
    try testing.expectEqual(@as(u32, 2), enc.id);
    try testing.expectEqual(@as(u16, 0), enc.bought[w]);
    try testing.expectEqual(kept, enc.level);
    try testing.expectApproxEqAbs(dear, buy_quote(&enc, .whetstone).give.qtyOf(.biomass), 1e-6);
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
    try testing.expectApproxEqAbs(@as(f32, 28), buy_quote(&enc, .fish_net).give.qtyOf(.biomass), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 6), buy_quote(&enc, .hand_axe).give.qtyOf(.food), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 4), buy_quote(&enc, .whetstone).give.qtyOf(.food), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 18), buy_quote(&enc, .work_gloves).give.qtyOf(.biomass), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 40), buy_quote(&enc, .cookpot).give.qtyOf(.biomass), 1e-6);
    try testing.expectEqual(@as(u16, 1), buy_quote(&enc, .cookpot).stock);
    try testing.expectEqual(@as(?Ware, .whetstone), prerequisite(.hand_axe));
    try testing.expectEqual(@as(?Ware, .whetstone), prerequisite(.work_gloves));
    try testing.expectEqual(@as(?Ware, null), prerequisite(.whetstone));
    try testing.expectEqual(@as(?Ware, null), prerequisite(.cookpot));
    // A good sells for the materials half of its price.
    try testing.expectApproxEqAbs(@as(f32, 40), sell_value(&enc, .cookpot), 1e-6);
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
