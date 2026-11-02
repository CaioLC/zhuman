//! `sim.Resources`: the resources a system may reach, and nothing else. The run (`Sim`), the
//! tuning (`Config`), this frame's timesteps (`Time`), the authored roster (`catalog`) and the
//! event store (`events`). The
//! host's `Resources` embeds it as the field `game`; a system, a rule and a sim test take
//! `*sim.Resources`, and every field has a default, so `sim.Resources{}` is a complete value.

const std = @import("std");
const comp = @import("./components.zig");
const logmod = @import("./log.zig");
const marketmod = @import("./rules/market.zig");
const rostermod = @import("./data/roster.zig");
const Events = @import("./ecs.zig").Events;

/// In-game hours → game-seconds (a day is 24h mapped onto `Config.secs_per_day`).
/// Action durations are authored in hours (`Requires.hours`) — human-readable on the
/// tiles — and ticked in game-seconds (`Busy.remaining`).
pub fn hours_to_secs(h: f32, secs_per_day: f32) f32 {
    return h * secs_per_day / 24.0;
}

/// This frame's two timesteps, written by the host loop before systems run. `real_dt` drives
/// host concerns such as roster watching and UI motion; `dt` is real time multiplied by the
/// selected simulation speed, or zero while paused.
pub const Time = struct {
    real_dt: f32 = 0,
    dt: f32 = 0,
};

/// How tired an agent is, in bands. One vocabulary for the condition word, the vigor
/// chip's color, the "you feel weak" log lines and labor's yield penalty — they all key
/// off the same two thresholds, so they read them through `Config.condition` rather than
/// each carrying its own copy of the numbers.
pub const Condition = enum { alive, weary, spent };

/// Tuning knobs. Never written at runtime, and deliberately **not** part of `Sim`, so
/// starting a fresh run doesn't discard a setting the player chose. Every value here is
/// a first guess awaiting playtesting — which is why they're runtime fields rather than
/// consts scattered across `actions.zig`, `systems/tick.zig` and the templates.
pub const Config = struct {
    /// Game-seconds per in-game day — the tempo every per-day rate (metabolism,
    /// starvation, spoilage-as-displayed) is expressed against, and the day counter's
    /// divisor. Lives here (not `main.zig`) so library systems can convert per-day
    /// rates to per-`dt` amounts.
    secs_per_day: f32 = 20,

    // —— condition bands ——
    /// Vigor fraction at or below which an agent is SPENT.
    spent_frac: f32 = 0.12,
    /// Vigor fraction below which an agent is WEARY.
    weary_frac: f32 = 0.35,
    /// Yield multiplier once an agent is no longer `.alive`. A constant step, not a
    /// linear slide — the slide was built once and reverted (band churn, felt bad).
    weary_yield: f32 = 0.7,

    // —— metabolism ——
    /// Vigor drained per day once the larder is empty. ~2.5 days from a full tank to
    /// death — the countdown that makes rationing a real decision.
    starve_per_day: f32 = 4.0,
    /// Vigor gained per unit of food eaten, before the larder's `quality` scales it.
    vigor_per_food: f32 = 2.0,
    /// The bounded metabolism-rate range and default. `Metabolism.rate` is a scalar
    /// multiplier the player sets continuously; the *range* and *default* are config (not UI
    /// words), and `clampMetabolism` is the one place a rate is made legal. Normal is the
    /// default (`1.0`); ration/feast are just points inside `[min, max]`.
    metabolism_rate_min: f32 = 0.5,
    metabolism_rate_max: f32 = 2.0,
    metabolism_rate_default: f32 = 1.0,

    // —— capital ——
    /// Share of a cancelled build's materials that comes back. Flat, not prorated by
    /// how far the work got: materials are spent in full at `capital.begin` and nothing
    /// draws them down over time, so a time-proportional refund would imply a
    /// consumption schedule the sim doesn't run. What it means is salvage — you take
    /// back the stock you hadn't worked in yet. The energy and the hours are gone.
    cancel_refund: f32 = 0.5,

    /// Which band a vigor fraction falls in. The single definition of the two
    /// thresholds; edge-crossing is a change in this value.
    pub fn condition(self: Config, frac: f32) Condition {
        if (frac <= self.spent_frac) return .spent;
        if (frac < self.weary_frac) return .weary;
        return .alive;
    }

    /// Labor's yield multiplier for an agent in this condition.
    pub fn yield_of(self: Config, c: Condition) f32 {
        return if (c == .alive) 1.0 else self.weary_yield;
    }

    /// Clamp a metabolism rate into the authoritative `[min, max]` band — the one
    /// place a rate is made legal, used on migration/reset and by any UI that sets the rate.
    pub fn clampMetabolism(self: Config, rate: f32) f32 {
        return std.math.clamp(rate, self.metabolism_rate_min, self.metabolism_rate_max);
    }
};

/// The run: everything the simulation writes that isn't a component. `reset` starts a
/// fresh one — a new field added here is cleared by that call for free, which is the
/// point of the grouping.
pub const Sim = struct {
    /// Seconds of game time elapsed this run — advanced while the actor lives (see
    /// `advance_clock`). Drives the day counter.
    elapsed: f32 = 0,
    /// Newest-first event feed shown in the HUD log panel; one feed for the run.
    log: logmod.Log = .{},
    /// The player has successfully begun at least one action this run. Set by
    /// `actions.begin_labor`; retained as run-progression memory even though the full Act-I
    /// workspace is now visible from the first frame.
    tutorial_done: bool = false,
    /// The simulation's one source of chance — every uncertain outcome is rolled
    /// against this. Held here so the player today and the AI deciders later draw
    /// uncertainty from the same stream. Reached through `Resources.random()`.
    prng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0),
    /// **Eligibility transition memory** — one bit per good, by catalog index, recording
    /// whether the good's prerequisite has *already* been seen satisfied this run. The
    /// `systems.track_reach` tick flips a bit false→true and logs "A new recipe is within reach"
    /// exactly once; because it is sim state (not UI), tab switches / filter / sort / rebuilds
    /// never touch it, so the line cannot repeat. Cleared by `reset` for a fresh run.
    reach_seen: [rostermod.max_goods]bool = @splat(false),

    /// **The Passerby encounter** — the run's one Act I counterparty as a clock-driven
    /// state machine (absent/approaching/present/departed, a stable visit `id`, and a finite
    /// per-visit satchel). Ticked each frame by `market.tick` off the sim clock (never a hardcoded
    /// day); the UI reads it. Cleared by `reset` for a fresh run.
    encounter: marketmod.Encounter = .{},

    /// **The Act II Coin Merchant's visits** — present or away, a visit identity, the time left,
    /// and the lots sold this visit. Ticked by the `merchant` system in Act II and dealt with by
    /// `merchant_deal` (`systems/merchant.zig`); the merchant dialog and strip read it.
    merchant: marketmod.MerchantVisit = .{},

    /// **The neighbours, stubbed** — Act II's MARKET view reads and trades with this
    /// deterministic stand-in until the population and market model exist (ACT2-01..09).
    /// Seeded on first use; cleared by `reset` for a fresh run.
    neighbours: @import("./rules/neighbours.zig").Market = .{},

    /// **The Exchange, stubbed** — Act II's milestone. `standing` once it is raised (the
    /// settlement then reads as Act III); `population` overrides the page's stand-in
    /// population until the population model exists (ACT2-01), so a fixture can reach every
    /// state of the card. Cleared by `reset`.
    exchange: Exchange = .{},

    pub const Exchange = struct {
        standing: bool = false,
        population: ?f32 = null,
        /// Raised this frame: the card opens its details on the next build (ACT2-18).
        reveal: bool = false,
    };

    /// Begin a fresh run. The prng is **carried over on purpose**: rewinding it would
    /// make every run replay the first one's luck.
    pub fn reset(self: *Sim) void {
        self.* = .{ .prng = self.prng };
    }
};

/// What a system may reach. `run` binds a system's group params (`*Sim`, `*const Config`,
/// `*const Time`, `*const roster.Catalog`) and its event params from these fields. One writer each: `time` by the host
/// loop, `sim` by systems, `config` by nobody, `catalog` by `reload.swap`, between frames.
pub const Resources = struct {
    sim: Sim = .{},
    config: Config = .{},
    time: Time = .{},
    /// The authored roster (`roster.zig`): loaded at init from `data/` where it has a file,
    /// the shipped copy for the rest, and replaced only by `reload.swap`, between frames. A
    /// system reads it as `*const roster.Catalog`. Defaults to no records, so a rig that never
    /// reads the roster needs nothing.
    catalog: rostermod.Catalog = rostermod.Catalog.empty,
    /// The intents and facts (`events.zig`). Written through `events.writer(T)` or an
    /// `EventWriter(T)` param, read by the handler and log systems with their stored cursors;
    /// `update()` opens each frame.
    events: Events = .{},

    /// A `std.Random` over `sim.prng` — call `.float(f32)`, `.boolean()`, etc. on it.
    pub fn random(self: *Resources) std.Random {
        return self.sim.prng.random();
    }
};

test "Config.clampMetabolism bounds the rate into [min, max]" {
    const cfg = Config{}; // min 0.5, max 2.0, default 1.0
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), cfg.clampMetabolism(1.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), cfg.clampMetabolism(0.1), 1e-6); // clamps low
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), cfg.clampMetabolism(9.0), 1e-6); // clamps high
    try std.testing.expectApproxEqAbs(@as(f32, 1.3), cfg.clampMetabolism(1.3), 1e-6); // in-band untouched
    try std.testing.expectEqual(cfg.metabolism_rate_default, (comp.Metabolism{}).rate); // default matches component
}
