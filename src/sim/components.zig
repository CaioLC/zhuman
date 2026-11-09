//! Component definitions.
//!
//! WARNING: only `pub const <Name> = struct { ... };` type declarations
//! may live in this file. The ECS world enumerates every public decl
//! here at comptime and generates one SparseSet per type. Any non-type
//! decl (functions, consts, imports of types you don't want registered)
//! will fail compilation.
// Relative, like every sim file's imports: `test-ui` and `test-sim` compile this file without `ha`.
const roster = @import("./data/roster.zig");

// Components.
pub const Label = struct { v: []const u8 };

/// Vigor: the human energy source. The field defaults are the authoritative starting baseline:
/// a rested agent spawns at the ceiling. `spawn_agent` spawns from these defaults (the
/// `baselines` module names them) rather than repeating literals, so Holdings derives a
/// current-vs-base margin against the same numbers.
pub const Vigor = struct {
    v: f32 = 10,
    max: f32 = 10,
};

pub const InventoryFood = struct {
    v: f32 = 4,
    quality: u8 = 1,
    spoils: f32 = 0.05,
};

pub const InventoryBiomass = struct {
    v: f32 = 0,
};

/// The capital goods an agent owns, as a count per catalog index of the authored roster
/// (`roster.zig`); zero is not owned. Only ownership carries an effect (a second pair of
/// sandals is stock), so what the goods *do* is derived, never stored here (`effects.zig`).
pub const Goods = struct {
    count: [roster.max_goods]u32 = @splat(0),
};

/// The verbs an agent holds of its own, by catalog index of the authored roster: held whether
/// or not any gate passes (`effects.held`). The player spawns with the
/// starting verbs `systems/run.zig` names.
pub const Verbs = struct {
    held: [roster.max_actions]bool = @splat(false),

    /// The verbs `ids` name, resolved against `cat`; an id the catalog lacks is skipped.
    pub fn of(cat: *const roster.Catalog, ids: []const []const u8) Verbs {
        var v = Verbs{};
        for (ids) |id| {
            if (cat.actionIndex(id)) |ai| v.held[ai] = true;
        }
        return v;
    }
};

/// Passive progress and mode for the agent's generator verbs, keyed by catalog action index.
/// `mode` defaults to `on` so a generator starts accumulating as soon as its verb is held;
/// `off` preserves `progress` and consumes nothing, and so does a verb no longer held.
pub const Generators = struct {
    /// What a generator does with its time (`capital.run_generators`): `on` accumulates and
    /// waits for the player to collect; `auto` accumulates and collects itself whenever the
    /// collection is payable; `off` is paused.
    pub const Mode = enum {
        on,
        auto,
        off,

        /// The mode one toggle moves to: on, auto, off, then on again.
        pub fn next(self: Mode) Mode {
            return switch (self) {
                .on => .auto,
                .auto => .off,
                .off => .on,
            };
        }
    };

    progress: [roster.max_actions]f32 = @splat(0),
    mode: [roster.max_actions]Mode = @splat(.on),
};

/// What the owned goods currently contribute to the body and the larder, so those
/// contributions can be applied as relative deltas (`effects.apply`) and anything else that
/// moves the ceiling composes underneath.
pub const Granted = struct {
    vigor_ceiling: f32 = 0,
    food_quality: u8 = 0,
    spoil_scale: f32 = 1,
};

/// Where each technology of the authored roster stands for this agent, by catalog index
/// (`roster.zig`). Seeded at the curtain from every record's `initial`; the research board
/// promotes and establishes from there. A recipe that names a `tech` is offered only once
/// it reads `researched` here (`capital.quote`).
pub const Research = struct {
    state: [roster.max_techs]roster.TechState = @splat(.locked),

    /// The board as the act opens: every tile at its authored initial state.
    pub fn entry(cat: *const roster.Catalog) Research {
        var r = Research{};
        for (cat.technologies, 0..) |t, i| r.state[i] = t.initial;
        return r;
    }
};

// -- Act II stocks: opened at the curtain, never before ------------------------------------
// Biomass exists in Act I (displayed there through the Materials cover). Migration carries
// that balance unchanged and opens the remaining resource stocks at zero. Each is a plain
// balance in the `InventoryBiomass` shape, reached through `ledger.Stock`.

pub const InventoryWater = struct {
    v: f32 = 0,
};

pub const InventoryFuel = struct {
    v: f32 = 0,
};

pub const InventoryMetal = struct {
    v: f32 = 0,
};

pub const InventoryMinerals = struct {
    v: f32 = 0,
};

/// Coin, a stand-in: a balance like the others so the merchant and the neighbours can settle
/// real numbers, opened at the curtain with a small purse. The simulation does not decide that
/// a medium of exchange emerges (`docs/roadmap.md`).
pub const InventoryCoin = struct {
    v: f32 = 0,
};

/// The migration version stamp: the marker the Act I to II migration writes onto an agent the
/// one time it runs. Its presence makes the migration idempotent: a second call sees the stamp
/// and returns without reopening stocks or re-seeding research. The `version` field is the
/// save-version boundary: a migration for an older save shape reads it to decide whether a
/// further step is owed. Act I agents do not carry it; owning it means the agent has crossed
/// the curtain.
pub const Migrated = struct {
    /// The migration schema version this agent was last carried to;
    /// `migration.current_version` is the authority.
    version: u32 = 0,
};

/// The one act in progress: an agent holds at most one (one body, one act at a time;
/// `actions.begin` refuses while it exists). Costs are paid at start; the yield
/// resolves at *completion* (`systems.resolve_busy` dispatches on `doing`). `quality` is
/// locked at the click — the band the tile advertised is the band the draw uses, even if
/// the metabolism drains the body mid-work. Death mid-task loses the work: the component
/// despawns with the agent, paid and undelivered.
pub const Busy = struct {
    /// The act that occupies the body: a labor verb or a capital build, by its index in the
    /// authored roster (`roster.Catalog`). `systems.resolve_busy` dispatches on the tag.
    pub const Doing = union(enum) {
        labor: u16,
        build: u16,
    };
    doing: Doing,
    /// Total work time and what's left of it, in game-seconds (see `res.hours_to_secs`).
    total: f32,
    remaining: f32,
    /// Labor quality locked at begin (see `actions.yield_factor`).
    quality: f32,

    pub fn isLabor(self: Busy, ai: u16) bool {
        return switch (self.doing) {
            .labor => |i| i == ai,
            .build => false,
        };
    }

    pub fn isBuild(self: Busy, gi: u16) bool {
        return switch (self.doing) {
            .build => |i| i == gi,
            .labor => false,
        };
    }
};

/// The continuous eating policy: an agent consumes its own larder every tick, regardless of
/// action (see `systems.metabolize`); what the player controls is the rate. `rate` is a
/// bounded scalar multiplier in `[0.5, 2.0]`, `1.0` at normal: it scales `base_rate`
/// continuously (ration = stretch the larder and stay weak, feast = restore fast and burn the
/// stock). `base_rate` is food/day at `rate = 1.0`. The `Config` owns the range/default and the
/// clamp (`Config.clampMetabolism`); this stores the persisted agent-local choice.
pub const Metabolism = struct {
    rate: f32 = 1.0,
    base_rate: f32 = 1.5,
};

/// The agent's condition band, derived from the vigor fraction by the `condition` system
/// (`systems/condition.zig`) through `rules/condition.refresh`, which holds the two thresholds
/// (`Config.condition`). The condition word, the vigor chip's tone and labor's yield step read
/// this value; none of them recomputes it.
pub const Condition = struct {
    /// How tired an agent is: rested, weary (labor yields `Config.weary_yield`), spent.
    pub const Band = enum { alive, weary, spent };
    band: Band = .alive,
};

/// The body's outlook at the current eating rate, written by the `outlook` system
/// (`systems/outlook.zig`) from the vigor, the larder and the metabolism: how many days the
/// larder lasts, and whether and how fast the vigor recovers. The BODY lines read it.
pub const Outlook = struct {
    /// The recovery outcome: a tagged result, never a bare number, so a reader renders the
    /// right copy for each state instead of guessing from a sentinel.
    pub const Recovery = union(enum) {
        /// Already at the vigor ceiling: nothing to recover.
        at_ceiling,
        /// No larder: the body is starving, not recovering.
        no_food,
        /// Food has zero quality: it fills the belly but yields no vigor, so no recovery.
        no_quality,
        /// The larder yields some vigor but **cannot reach the ceiling**; carries the days the
        /// larder lasts and the vigor it will have restored by then (a partial recovery).
        partial: struct { days: f32, restored: f32 },
        /// Full vigor is reachable at the current rate; carries the days to reach it.
        recovering: struct { days: f32 },
    };
    /// Days of food at the current rate; `0` when the larder is empty.
    food_days: f32 = 0,
    recovery: Recovery = .no_food,
};

/// What each of the agent's verbs, recipes and generators would answer right now, written by
/// the `quotes` system (`systems/quotes.zig`) through `actions.quote`, `capital.quote` and
/// `capital.generator_quote`, so a tile, a BUILD row and a decider read one answer. It holds the
/// standings and the per-item numbers, not the terms: a verb's effective terms stay the pure read
/// `actions.verbOf`, because the world holds every component's storage for its full
/// `MAX_ENTITIES` capacity, and a copy of the terms per verb would add tens of megabytes to it. Every
/// slot is indexed by the record's catalog index.
pub const Quotes = struct {
    /// Why a verb cannot begin right now, or `ready` (`actions.Standing`).
    pub const VerbStanding = enum { ready, busy, energy, short };
    /// Why a build cannot begin right now, or `ready`, in precedence order (`capital.Standing`).
    pub const BuildStanding = enum { ready, tech, needs, unlock, busy, energy, short };
    /// Where a held generator's cycle stands (`capital.GeneratorStanding`).
    pub const GeneratorStanding = enum { charging, off, ready, energy, short };

    /// `short`: the first resource the effective verb requires that the agent cannot pay.
    pub const Verb = struct {
        standing: VerbStanding,
        short: ?roster.Resource = null,
        /// The yield multiplier a begin right now would lock.
        quality: f32,

        pub fn ready(self: Verb) bool {
            return self.standing == .ready;
        }
    };

    /// `short`: the first resource the record requires that the agent cannot pay.
    pub const Build = struct {
        standing: BuildStanding,
        short: ?roster.Resource = null,
        /// Units already owned.
        count: u32,
        /// How close the build cost is to affordable: the smallest held/needed over its
        /// resources, 1 when it names none.
        reach: f32,

        pub fn ready(self: Build) bool {
            return self.standing == .ready;
        }
    };

    /// `short`: the first resource the record requires that the agent cannot pay.
    pub const Generator = struct {
        standing: GeneratorStanding,
        short: ?roster.Resource = null,
        /// Game-seconds accumulated toward the cycle, and the cycle's length.
        progress: f32,
        total: f32,

        pub fn ready(self: Generator) bool {
            return self.standing == .ready;
        }

        /// How far through its cycle, in [0, 1].
        pub fn fraction(self: Generator) f32 {
            if (self.total <= 0) return 1;
            return @min(@max(self.progress / self.total, 0), 1);
        }
    };

    /// By verb index; null: the agent does not hold the verb.
    verbs: [roster.max_actions]?Verb = @splat(null),
    /// By good index; null: not buildable, or the agent has no holdings.
    builds: [roster.max_goods]?Build = @splat(null),
    /// By verb index; null: not a held generator verb.
    generators: [roster.max_actions]?Generator = @splat(null),
};
