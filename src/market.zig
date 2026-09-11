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
