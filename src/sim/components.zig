//! Component definitions.
//!
//! WARNING: only `pub const <Name> = struct { ... };` type declarations
//! may live in this file. The ECS world enumerates every public decl
//! here at comptime and generates one SparseSet per type. Any non-type
//! decl (functions, consts, imports of types you don't want registered)
//! will fail compilation.
// Relative, like every sim file's imports: `test-ui` and `test-sim` compile this file without `ha`.
const roster = @import("./data/roster.zig");

// NOTE: These are components
pub const Label = struct { v: []const u8 };

/// Vigor: human energy source. Field defaults are the **authoritative starting baseline**
/// A rested agent spawns at the ceiling. `spawn_agent` spawns from these defaults
/// (and the `baselines` module names them) rather than repeating literals, so Holdings can
/// derive a current-vs-base margin against the same numbers.
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
/// (`roster.zig`); zero is not owned. Only ownership carries an effect — a second pair of
/// sandals is stock — so what the goods *do* is derived, never stored here (`effects.zig`).
pub const Goods = struct {
    count: [roster.max_goods]u32 = @splat(0),
};

/// Passive progress and on/off state for owned collectable generators, keyed by catalog good
/// index. `off` defaults false so a newly acquired generator starts accumulating immediately;
/// toggling off preserves `progress` and consumes nothing.
pub const Generators = struct {
    progress: [roster.max_goods]f32 = @splat(0),
    off: [roster.max_goods]bool = @splat(false),
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
/// promotes and establishes from there, and a recipe that names a `tech` is offered only once
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

// -- Additional Act II stocks: opened at the curtain, never before --------------------------
// Biomass already exists in Act I (displayed there through the Materials cover). Migration
// carries that balance unchanged and opens the remaining resource stocks at zero. Each is a
// plain balance in the `InventoryBiomass` shape, reached through `ledger.Stock`.

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

/// **Coin, stubbed.** A balance like the others so the merchant and the neighbours can settle
/// real numbers, opened at the curtain with a small purse. The simulation does not yet decide
/// that a medium of exchange emerges (`docs/roadmap.md`, ACT2-09); this stands in until it does.
pub const InventoryCoin = struct {
    v: f32 = 0,
};

/// **Migration version stamp** — the versioned marker the Act I → II migration writes onto an
/// agent the one time it runs. Its presence is what makes the migration idempotent: a second
/// call sees the stamp and returns without reopening stocks or re-seeding research. The
/// `version` field is the save-version boundary — a migration authored for an older save shape
/// can read it and decide whether a further step is owed. Act I agents do not carry it; owning
/// it *is* "this agent has crossed the curtain".
pub const Migrated = struct {
    /// The migration schema version this agent was last carried to. Bumped when the migration
    /// gains a new step; `migration.current_version` is the authority.
    version: u32 = 0,
};

/// The one act in progress — an agent holds at most one (one body, one act at a time;
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

/// The continuous eating policy: an agent consumes its own larder every tick — eating
/// happens regardless of action (see `systems.metabolize`); what the player controls is
/// the *rate*. `rate` is a **bounded scalar multiplier** in `[0.5, 2.0]`, `1.0` at
/// normal: it scales `base_rate` continuously (ration = stretch the larder and stay weak,
/// feast = restore fast and burn the stock), replacing the old three-value ration/normal/feast
/// enum. `base_rate` is food/day at `rate = 1.0`. The `Config` owns the range/default and the
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
    /// The recovery outcome — a tagged result, never a bare number, so a reader renders the
    /// right copy for each state instead of guessing from a sentinel.
    pub const Recovery = union(enum) {
        /// Already at the vigor ceiling — nothing to recover.
        at_ceiling,
        /// No larder — the body is starving, not recovering.
        no_food,
        /// Food has zero quality — it fills the belly but yields no vigor, so no recovery.
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
    /// A `short` index that names no line: the order is payable.
    pub const none: u8 = 0xff;
    /// Why a verb cannot begin right now, or `ready` (`actions.Standing`).
    pub const VerbStanding = enum { ready, busy, energy, short };
    /// Why a build cannot begin right now, or `ready`, in precedence order (`capital.Standing`).
    pub const BuildStanding = enum { ready, tech, needs, unlock, busy, energy, short };
    /// Where an owned generator's cycle stands (`capital.GeneratorStanding`).
    pub const GeneratorStanding = enum { charging, off, ready, energy, short };

    /// `short`: index of the first unpayable line in the effective verb's `input` (`none` when payable).
    pub const Verb = struct {
        standing: VerbStanding,
        short: u8 = none,
        /// The yield multiplier a begin right now would lock.
        quality: f32,

        pub fn ready(self: Verb) bool {
            return self.standing == .ready;
        }
    };

    /// `short`: index of the first unpayable line in the record's `input` (`none` when payable).
    pub const Build = struct {
        standing: BuildStanding,
        short: u8 = none,
        /// Units already owned.
        count: u32,
        /// How close the build order is to affordable: the smallest held/needed over its
        /// once-inputs, 1 when it has none.
        reach: f32,

        pub fn ready(self: Build) bool {
            return self.standing == .ready;
        }
    };

    /// `short`: index of the first unpayable line in the record's `input` (`none` when payable).
    pub const Generator = struct {
        standing: GeneratorStanding,
        short: u8 = none,
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
    /// By good index; null: not an owned generator.
    generators: [roster.max_goods]?Generator = @splat(null),
};
