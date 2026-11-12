//! `sim.Resources`: the resources a system may reach, and nothing else. The run (`Sim`), the
//! tuning (`Config`), this frame's timesteps (`Time`), the authored roster (`catalog`), the
//! event store (`events`) and the run's state (`states`). The host's `Resources` embeds it as
//! the field `game`; a system, a rule and a sim test take `*sim.Resources`, and every field has
//! a default, so `sim.Resources{}` is a complete value, on the title with an empty world.

const std = @import("std");
const comp = @import("./components.zig");
const logmod = @import("./log.zig");
const marketmod = @import("./rules/market.zig");
const rostermod = @import("./data/roster.zig");
const Events = @import("./ecs.zig").Events;
const States = @import("./state.zig").States;

/// In-game hours to game-seconds (a day is 24h mapped onto `Config.secs_per_day`). Action
/// durations are authored in hours (`Requires.hours`), human-readable on the tiles, and ticked
/// in game-seconds (`Busy.remaining`).
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

/// How tired an agent is, in bands: the `comp.Condition` component's enum. One vocabulary for
/// the condition word, the vigor chip's color, the "you feel weak" log lines and labor's yield
/// penalty; the band is applied from the two thresholds in one place (`rules/condition.zig`),
/// and every reader reads the component.
pub const Band = comp.Condition.Band;

/// Tuning knobs. Never written at runtime, and deliberately not part of `Sim`, so starting a
/// fresh run does not discard a setting the player chose. They are runtime fields rather than
/// consts scattered across `actions.zig`, `systems/tick.zig` and the templates.
pub const Config = struct {
    /// Game-seconds per in-game day: the tempo every per-day rate (metabolism, starvation,
    /// spoilage-as-displayed) is expressed against, and the day counter's divisor. It lives
    /// here (not `main.zig`) so library systems can convert per-day rates to per-`dt` amounts.
    secs_per_day: f32 = 20,

    // —— condition bands ——
    /// Vigor fraction at or below which an agent is SPENT.
    spent_frac: f32 = 0.12,
    /// Vigor fraction below which an agent is WEARY.
    weary_frac: f32 = 0.35,
    /// Yield multiplier once an agent is no longer `.alive`. A constant step, not a linear
    /// slide: a slide churned the bands and felt bad.
    weary_yield: f32 = 0.7,

    // —— metabolism ——
    /// Vigor drained per day once the larder is empty, at the normal ration: about 2.5 days
    /// from a full tank to death. The drain scales with `Metabolism.rate` (`tick.metabolize`),
    /// so a meager ration starves slower than this and a lavish one faster.
    starve_per_day: f32 = 4.0,
    /// Vigor regained per day at full speed, the limit the body approaches however much it
    /// eats (`regen`).
    regen_full_per_day: f32 = 10.0,
    /// The share of full speed the normal ration regains. It sets the curve: every further
    /// normal ration closes the same share of what is left, so returns to eating diminish.
    regen_at_normal: f32 = 0.8,
    /// The bounded metabolism-rate range and default. `Metabolism.rate` is a scalar multiplier
    /// the player sets continuously; the range and default are config (not UI words), and
    /// `clampMetabolism` is the one place a rate is made legal. Normal is `1.0`; ration and
    /// feast are points inside `[min, max]`. The top is a feast far beyond what a lone actor's
    /// labor can feed. The default, the ration a body begins at, is the meagerest: a run begins
    /// poor, and the normal ration is something to work up to.
    metabolism_rate_min: f32 = 0.5,
    metabolism_rate_max: f32 = 5.0,
    metabolism_rate_default: f32 = 0.5,

    // —— capital ——
    /// Share of a cancelled build's materials that comes back. Flat, not prorated by
    /// how far the work got: materials are spent in full at `capital.begin` and nothing
    /// draws them down over time, so a time-proportional refund would imply a
    /// consumption schedule the sim doesn't run. What it means is salvage — you take
    /// back the stock you hadn't worked in yet. The energy and the hours are gone.
    cancel_refund: f32 = 0.5,

    /// Which band a vigor fraction falls in. The single definition of the two
    /// thresholds; `rules/condition.refresh` is its one caller, and a crossing is a change in
    /// the `comp.Condition` it writes.
    pub fn condition(self: Config, frac: f32) Band {
        if (frac <= self.spent_frac) return .spent;
        if (frac < self.weary_frac) return .weary;
        return .alive;
    }

    /// Labor's yield multiplier for an agent in this condition.
    pub fn yield_of(self: Config, c: Band) f32 {
        return if (c == .alive) 1.0 else self.weary_yield;
    }

    /// Vigor regained per day while the larder feeds an agent eating at `rate` food of
    /// `quality`: `full × (1 − (1 − at_normal)^(rate × quality))`. Saturating, so each further
    /// unit of food restores less than the one before: at the shipped 0.8, half the normal
    /// ration regains 55% of full speed and twice it 96%. Quality multiplies how far the food
    /// goes; food of no quality restores nothing. `metabolize` applies it and `outlook`
    /// projects with it.
    pub fn regen(self: Config, rate: f32, quality: u8) f32 {
        const fed = self.clampMetabolism(rate) * @as(f32, @floatFromInt(quality));
        return self.regen_full_per_day * (1.0 - std.math.pow(f32, 1.0 - self.regen_at_normal, fed));
    }

    /// Clamp a metabolism rate into the authoritative `[min, max]` band: the one place a rate
    /// is made legal, used on migration/reset and by any UI that sets the rate.
    pub fn clampMetabolism(self: Config, rate: f32) f32 {
        return std.math.clamp(rate, self.metabolism_rate_min, self.metabolism_rate_max);
    }
};

/// The run: everything the simulation writes that isn't a component. `reset` starts a fresh
/// one, clearing every field here, which is the point of the grouping.
pub const Sim = struct {
    /// Seconds of game time elapsed this run, advanced while the actor lives (see
    /// `advance_clock`). Drives the day counter.
    elapsed: f32 = 0,
    /// Newest-first event feed shown in the HUD log panel; one feed for the run.
    log: logmod.Log = .{},
    /// The player has successfully begun at least one action this run. Set by
    /// `actions.begin_labor`; run-progression memory.
    tutorial_done: bool = false,
    /// The simulation's one source of chance: every uncertain outcome is rolled against this,
    /// so every actor draws uncertainty from the same stream. Reached through
    /// `Resources.random()`.
    prng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0),
    /// Eligibility transition memory: one bit per good, by catalog index, recording whether
    /// the good's prerequisite has been seen satisfied this run. The `systems.track_reach`
    /// tick flips a bit false to true and logs "A new recipe is within reach" exactly once;
    /// because it is sim state (not UI), tab switches, filters, sorts and rebuilds never touch
    /// it, so the line cannot repeat. Cleared by `reset`.
    reach_seen: [rostermod.max_goods]bool = @splat(false),

    /// The Passerby encounter: the run's one Act I counterparty as a clock-driven state
    /// machine (absent/approaching/present/departed, a stable visit `id`, and a finite
    /// per-visit satchel). Ticked each frame by `market.tick` off the sim clock (never a
    /// hardcoded day); the UI reads it. Cleared by `reset`.
    encounter: marketmod.Encounter = .{},

    /// The Act II Coin Merchant's visits: present or away, a visit identity, the time left,
    /// and the lots sold this visit. Ticked by the `merchant` system in Act II and dealt with by
    /// `merchant_deal` (`systems/merchant.zig`); the merchant dialog and strip read it.
    merchant: marketmod.MerchantVisit = .{},

    /// The neighbours, a stand-in: Act II's MARKET view reads and trades with this
    /// deterministic stand-in for the population and market model (`docs/roadmap.md`), and in
    /// Act I it holds the lone actor's offers (`Market.act_one`), which the curtain drops.
    /// Seeded on first use; cleared by `reset`.
    neighbours: @import("./rules/neighbours.zig").Market = .{},

    /// The Exchange: Act II's milestone, `standing` once it is raised (the settlement then
    /// reads as Act III). Raised by `systems/exchange.zig`. Cleared by `reset`.
    exchange: Exchange = .{},

    /// The settlement's population: a stand-in number (`docs/roadmap.md`). The Exchange's unlock
    /// and the Act II header read it; a fixture sets it to reach every state of the Exchange card.
    population: f32 = 48,

    pub const Exchange = struct {
        standing: bool = false,
    };

    /// Begin a fresh run. The prng is carried over on purpose: rewinding it would make every
    /// run replay the first one's luck.
    pub fn reset(self: *Sim) void {
        self.* = .{ .prng = self.prng };
    }
};

/// What a system may reach. `run` binds a system's group params (`*Sim`, `*const Config`,
/// `*const Time`, `*const roster.Catalog`, `*States`) and its event params from these fields.
/// One writer each: `time` by the host loop, `sim` by systems, `config` by nobody, `catalog` by
/// `reload.swap`, between frames, `states` by the transition systems and the schedule.
pub const Resources = struct {
    sim: Sim = .{},
    config: Config = .{},
    time: Time = .{},
    /// The authored roster (`roster.zig`): loaded at init from `assets/roster/` where it has a file,
    /// the shipped copy for the rest, and replaced only by `reload.swap`, between frames. A
    /// system reads it as `*const roster.Catalog`. Defaults to no records, so a rig that never
    /// reads the roster needs nothing.
    catalog: rostermod.Catalog = rostermod.Catalog.empty,
    /// The intents and facts (`events.zig`). Written through `events.writer(T)` or an
    /// `EventWriter(T)` param, read by the handler and log systems with their stored cursors;
    /// `update()` opens each frame.
    events: Events = .{},
    /// The run's state (`state.zig`): requested by the transition systems through `set`,
    /// applied by `schedule.tick`, read by the UI. Begins on the title.
    states: States = .{},

    /// A `std.Random` over `sim.prng`: call `.float(f32)`, `.boolean()`, etc. on it.
    pub fn random(self: *Resources) std.Random {
        return self.sim.prng.random();
    }
};

test "Config.clampMetabolism bounds the rate into [min, max]" {
    const cfg = Config{};
    try std.testing.expect(cfg.metabolism_rate_min < 1.0 and 1.0 < cfg.metabolism_rate_max); // normal is inside
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), cfg.clampMetabolism(1.0), 1e-6);
    try std.testing.expectApproxEqAbs(cfg.metabolism_rate_min, cfg.clampMetabolism(cfg.metabolism_rate_min / 5), 1e-6); // clamps low
    try std.testing.expectApproxEqAbs(cfg.metabolism_rate_max, cfg.clampMetabolism(cfg.metabolism_rate_max * 5), 1e-6); // clamps high
    try std.testing.expectApproxEqAbs(@as(f32, 1.3), cfg.clampMetabolism(1.3), 1e-6); // in-band untouched
    try std.testing.expectEqual(cfg.metabolism_rate_default, (comp.Metabolism{}).rate); // default matches component
    try std.testing.expectEqual(cfg.metabolism_rate_min, cfg.metabolism_rate_default); // a body begins at the meagerest
}

test "Config.regen saturates: the normal ration regains its share of full speed and each further ration less" {
    const cfg = Config{};
    const full = cfg.regen_full_per_day;
    const left = 1.0 - cfg.regen_at_normal; // the share of full speed the normal ration leaves
    try std.testing.expectApproxEqAbs(cfg.regen_at_normal * full, cfg.regen(1.0, 1), 1e-4);
    try std.testing.expectApproxEqAbs((1.0 - @sqrt(left)) * full, cfg.regen(0.5, 1), 1e-4);
    try std.testing.expectApproxEqAbs((1.0 - left * left) * full, cfg.regen(2.0, 1), 1e-4);
    // Decreasing marginal returns: the second half-ration adds less than the first, and the
    // top of the band is short of full speed by a hair.
    try std.testing.expect(cfg.regen(1.0, 1) - cfg.regen(0.5, 1) < cfg.regen(0.5, 1));
    try std.testing.expect(cfg.regen(cfg.metabolism_rate_max, 1) < full);
    try std.testing.expect(cfg.regen(cfg.metabolism_rate_max, 1) > 0.99 * full);
    // Quality multiplies how far the food goes; none restores nothing.
    try std.testing.expectApproxEqAbs(cfg.regen(1.0, 1), cfg.regen(0.5, 2), 1e-4);
    try std.testing.expectEqual(@as(f32, 0), cfg.regen(1.0, 0));
}
