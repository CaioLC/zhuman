//! Component definitions.
//!
//! WARNING: only `pub const <Name> = struct { ... };` type declarations
//! may live in this file. The ECS world enumerates every public decl
//! here at comptime and generates one SparseSet per type. Any non-type
//! decl (functions, consts, imports of types you don't want registered)
//! will fail compilation.
const ha = @import("ha");
const dist = ha.dist;

// Private on purpose: these are pieces of larger components, never components themselves,
// and `World`'s comptime scan only sees a file's *public* decls — so keeping them private
// is what stops a dead `SparseSet` being generated for each.
const Requires = struct {
    energy: f32,
    materials: f32,
    /// Work time, in in-game hours (`res.hours_to_secs` converts; a day = 24h). Time is
    /// a price like the others — under the metabolism, hours are food — so it lives in
    /// the price shape and every presentation shows it. No default on purpose: adding a
    /// duration to a new action is a decision, not an omission.
    hours: f32,
};

const Yields = struct {
    food: dist.Dist,
    materials: dist.Dist,
};

/// What a good demands of the *builder* before it is offered at all - standing
/// conditions, as against `Requires`, which is what the build spends. Read once, in
/// `capital.begin_build`: a dip afterwards doesn't stop work already paid for.
const Unlock = struct {
    /// A vigor *fraction*, not an absolute: capacity capital raises `max`, and `v/max`
    /// is the reading every other part of the game keys off.
    vigor_frac: f32,
    /// Units in the larder.
    food: f32,
    /// How many goods from the catalog the builder must already own.
    goods: u32,
};

// NOTE: These are components
pub const Label = struct { v: []const u8 };

/// Vigor: human energy source. Field defaults are the **authoritative starting baseline**
/// (ACT1-01): a rested agent spawns at the ceiling. `spawn_agent` spawns from these defaults
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

pub const InventoryMaterial = struct {
    v: f32 = 0,
};

// -- Innate actions: the bare-handed verbs every agent spawns with -----------------------
// (`actions.innate_actions_bundle`). Each action owns a distinct *risk texture* — the
// dist kind is content, not decoration, and all five kinds are in play across the roster.

/// Forage: glean the greenbelt. The safe calorie baseline — normal, steady.
pub const ActionForage = struct {
    requires: Requires = .{ .energy = 2.0, .materials = 0.0, .hours = 4 },
    yields: Yields = .{
        .food = .{ .kind = .normal, .s = 2.0 },
        .materials = .{ .kind = .fixed, .s = 0 },
    },
};

/// Scavenge: pick through the derelict edge of town. The day-one *materials* verb —
/// exponential on both yields: mostly scraps, occasionally a jackpot find, and sometimes
/// a forgotten can of food. This is what bootstraps the first tool.
pub const ActionScavenge = struct {
    requires: Requires = .{ .energy = 2.0, .materials = 0.0, .hours = 5 },
    yields: Yields = .{
        .food = .{ .kind = .exponential, .s = 0.5 },
        .materials = .{ .kind = .exponential, .s = 3.0 },
    },
};

// -- Unlocked actions: granted by capital, never spawned innate ---------------------------
// Each arrives with its Unlocker good (`capital.finish_build` adds the component); the
// type's defaults *are* the with-tool stats.

/// Fish: unlocked by the Fishing rod. Better mean than Forage but poisson-lumpy —
/// feast or famine; wants a larder buffer under the metabolism.
pub const ActionFish = struct {
    requires: Requires = .{ .energy = 2.0, .materials = 0.0, .hours = 5 },
    yields: Yields = .{
        .food = .{ .kind = .poisson, .s = 3.0 },
        .materials = .{ .kind = .fixed, .s = 0 },
    },
};

/// Split wood: unlocked by the Hatchet — you cannot split logs bare-handed. Steady
/// materials: beats Scavenge's mean but never jackpots.
pub const ActionChopWood = struct {
    requires: Requires = .{ .energy = 2.0, .materials = 0.0, .hours = 6 },
    yields: Yields = .{
        .food = .{ .kind = .fixed, .s = 0 },
        .materials = .{ .kind = .normal, .s = 5.0 },
    },
};

/// Check traps: unlocked by Wire snares. The first stock-consuming verb — the bait is
/// materials — converting m→f cheaply in both energy and hours; a bad draw eats the
/// bait anyway.
pub const ActionCheckTraps = struct {
    requires: Requires = .{ .energy = 1.0, .materials = 1.0, .hours = 2 },
    yields: Yields = .{
        .food = .{ .kind = .uniform, .s = 3.0 },
        .materials = .{ .kind = .fixed, .s = 0 },
    },
};

/// Hunt: unlocked by the Air rifle. The best food-per-energy in Act One, priced in the
/// two currencies that bite: deep vigor and a whole working day — plus ammo.
pub const ActionHunt = struct {
    requires: Requires = .{ .energy = 4.0, .materials = 1.0, .hours = 8 },
    yields: Yields = .{
        .food = .{ .kind = .poisson, .s = 6.0 },
        .materials = .{ .kind = .fixed, .s = 0 },
    },
};

/// The one act in progress — an agent holds at most one (one body, one act at a time;
/// `actions.begin_labor` refuses while it exists). Costs are paid at start; the yield
/// resolves at *completion* (`systems.resolve_busy` dispatches on `doing`). `quality` is
/// locked at the click — the band the tile advertised is the band the draw uses, even if
/// the metabolism drains the body mid-work. Death mid-task loses the work: the component
/// despawns with the agent, paid and undelivered.
pub const Busy = struct {
    /// Every act that can occupy the one body — labor verbs and capital builds alike.
    /// Manual, like `actions_bundle`/`generator_bundle`: a fact about types, not entities
    /// (`actions.doing_of` / `capital.doing_of_good` map the comptime type to its name,
    /// and `systems.resolve_busy` dispatches back).
    pub const Doing = enum {
        // labor
        forage,
        scavenge,
        fish,
        chop_wood,
        check_traps,
        hunt,
        // capital builds
        build_fish_rod,
        build_hatchet,
        build_wire_snares,
        build_air_rifle,
        build_sandals,
        build_work_gloves,
        build_bicycle,
        build_cookpot,
        build_root_cellar,
        build_chainsaw,
        build_leaf_bed,
        build_pantry,
        build_medicine_chest,
        build_garden_bed,
        build_chicken_coop,
        build_shelter,
    };
    doing: Doing,
    /// Total work time and what's left of it, in game-seconds (see `res.hours_to_secs`).
    total: f32,
    remaining: f32,
    /// Labor quality locked at begin (see `actions.yield_factor`).
    quality: f32,
};

/// The continuous eating policy: an agent consumes its own larder every tick — eating
/// happens regardless of action (see `systems.metabolize`); what the player controls is
/// the *rate*. `setting` is that standing choice: ration (stretch the larder, stay
/// weak), normal, or feast (restore fast, burn the stock). `base_rate` is food/day at
/// `normal`; ration halves it, feast doubles it.
pub const Metabolism = struct {
    pub const Setting = enum { ration, normal, feast };
    setting: Setting = .normal,
    base_rate: f32 = 1.5,
};

// ============================ Capital goods ==================================
// Every buildable good carries `requires` — its **build price**, `hours` included, paid
// once by `capital.begin_build`. What the good *does* once built is its category (see
// capital.zig): an Unlocker grants a verb, an ActionModifier mutates a margin, a
// Generator starts running. One per agent, backed by the sparse-set's structural
// guarantee.
//
// Every good also carries a `count`, because once a trader will take goods off your
// hands a lone actor stops building only what he means to use — a second pair of sandals
// is stock, not a deeper discount. **Only the first unit carries the effect**: that is a
// balance call, not a structural one, and it is why `finish_build` grants on the way in
// from absent rather than on every completion.
//
// The roster splits in two, and the prices are what says which is which. **Crude** goods
// — sandals, leaf bed, wire snares, root cellar, garden bed — are what a person alone can
// make from scavenged scrap and their own hands: a few materials, half a day. **Manufactured**
// goods are everything else, and a lone actor cannot sensibly produce them: they carry ×8 the
// materials and ×10 the hours, so a hatchet is four days of building nothing else while the
// larder drains. They stay buildable on purpose — nothing forbids them, they are simply
// priced past what one body's time is worth, which is the argument for trading instead.

// -- Unlockers: owning the tool is what makes the verb possible at all --------------------

/// Fishing rod → `ActionFish`.
pub const FishRod = struct {
    requires: Requires = .{ .energy = 3.0, .materials = 64.0, .hours = 120 },
    /// How many of this good the agent holds. Only the first carries the effect.
    count: u32 = 1,
};

/// Hatchet → `ActionChopWood`. The first step off bare hands into steady materials.
pub const Hatchet = struct {
    requires: Requires = .{ .energy = 2.0, .materials = 48.0, .hours = 100 },
    /// How many of this good the agent holds. Only the first carries the effect.
    count: u32 = 1,
};

/// Wire snares → `ActionCheckTraps`.
pub const WireSnares = struct {
    requires: Requires = .{ .energy = 2.0, .materials = 5.0, .hours = 8 },
    /// How many of this good the agent holds. Only the first carries the effect.
    count: u32 = 1,
};

/// Air rifle → `ActionHunt`. The long save of the labor roster.
pub const AirRifle = struct {
    requires: Requires = .{ .energy = 2.0, .materials = 200.0, .hours = 160 },
    /// How many of this good the agent holds. Only the first carries the effect.
    count: u32 = 1,
};

// -- ActionModifiers: a margin on a verb you already have ---------------------------------

/// Rudimentary sandals: Forage costs a little less body. Bark and cordage — crude, and
/// priced like it; the margin is small because the footwear is bad.
pub const Sandals = struct {
    requires: Requires = .{ .energy = 1.0, .materials = 3.0, .hours = 6 },
    /// How many of this good the agent holds. Only the first carries the effect.
    count: u32 = 1,
};

/// Work gloves: splitting wood costs less body.
pub const WorkGloves = struct {
    requires: Requires = .{ .energy = 1.0, .materials = 24.0, .hours = 50 },
    /// How many of this good the agent holds. Only the first carries the effect.
    count: u32 = 1,
};

/// Bicycle: distance gets cheap — both roaming verbs at once.
pub const Bicycle = struct {
    requires: Requires = .{ .energy = 2.0, .materials = 120.0, .hours = 140 },
    /// How many of this good the agent holds. Only the first carries the effect.
    count: u32 = 1,
};

/// Cookpot: consumption-side capital — cooking raises the larder's `quality`, so every
/// stored unit of food converts to more vigor under the metabolism.
pub const Cookpot = struct {
    requires: Requires = .{ .energy = 2.0, .materials = 56.0, .hours = 80 },
    /// How many of this good the agent holds. Only the first carries the effect.
    count: u32 = 1,
};

/// Root cellar: storage capital — halves spoilage. Worth exactly what your surpluses are.
pub const RootCellar = struct {
    requires: Requires = .{ .energy = 4.0, .materials = 10.0, .hours = 12 },
    /// How many of this good the agent holds. Only the first carries the effect.
    count: u32 = 1,
};

/// Chainsaw: the Act One capstone and the Act II teaser — the first substitution of
/// *external* energy for muscle. Splitting wood stops pricing the body and starts
/// pricing fuel.
pub const Chainsaw = struct {
    requires: Requires = .{ .energy = 3.0, .materials = 480.0, .hours = 300 },
    /// How many of this good the agent holds. Only the first carries the effect.
    count: u32 = 1,
};

// -- Health goods: capacity capital ------------------------------------------------------
// Sleeps well / eats better / patched up properly ⟹ actually healthier: each raises the
// vigor *ceiling* (see `capital.health_apply`) — by 1 for the crude leaf bed, by 2 for the
// two manufactured goods. A future aging component decrementing
// `max` composes underneath, since every mutation here is relative.

/// Leaf bed — the crude one, so it buys half of what the built furniture does.
pub const LeafBed = struct {
    requires: Requires = .{ .energy = 2.0, .materials = 6.0, .hours = 10 },
    /// How many of this good the agent holds. Only the first carries the effect.
    count: u32 = 1,
};

/// Pantry.
pub const Pantry = struct {
    requires: Requires = .{ .energy = 2.0, .materials = 112.0, .hours = 140 },
    /// How many of this good the agent holds. Only the first carries the effect.
    count: u32 = 1,
};

/// Medicine chest.
pub const MedicineChest = struct {
    requires: Requires = .{ .energy = 2.0, .materials = 160.0, .hours = 160 },
    /// How many of this good the agent holds. Only the first carries the effect.
    count: u32 = 1,
};

// -- Generators: capital that runs itself ------------------------------------------------
// Two prices, not one: `requires` is the build order (paid once, hours included) and
// `upkeep` is the per-tick drain `capital.run_generator` must keep affording. `yields`
// and `upkeep` are authored **per in-game day** and scaled by the frame's dt, so the
// flow reads as a trickle rather than a lump (a discrete daily harvest is a later
// refinement). `upkeep.hours` is 0: affordability is not a work order.

/// Garden bed: a lump of materials becomes a perpetual food trickle (uniform: weather),
/// for a little upkeep (water, stakes).
pub const GardenBed = struct {
    requires: Requires = .{ .energy = 4.0, .materials = 12.0, .hours = 16 },
    /// How many of this good the agent holds. Only the first carries the effect.
    count: u32 = 1,
    upkeep: Requires = .{ .energy = 0.0, .materials = 0.1, .hours = 0 },
    yields: Yields = .{
        .food = .{ .kind = .uniform, .s = 1.5 },
        .materials = .{ .kind = .fixed, .s = 0 },
    },
};

/// Chicken coop: a bigger flow than the garden (poisson: eggs) for real upkeep (feed).
pub const ChickenCoop = struct {
    requires: Requires = .{ .energy = 3.0, .materials = 144.0, .hours = 200 },
    /// How many of this good the agent holds. Only the first carries the effect.
    count: u32 = 1,
    upkeep: Requires = .{ .energy = 0.0, .materials = 0.3, .hours = 0 },
    yields: Yields = .{
        .food = .{ .kind = .poisson, .s = 2.5 },
        .materials = .{ .kind = .fixed, .s = 0 },
    },
};

// -- Shelter: the roof that ends Act I ---------------------------------------------------
// The one good that is neither a verb, a margin, a ceiling nor a flow. Owning it *is* Act
// I's win condition: a lone actor who can house four has stopped surviving and started
// settling, which is what a second human can be invited into. `unlock` is why it reads as
// an achievement rather than a purchase - the conditions say you already made a life here.

/// Shelter.
pub const Shelter = struct {
    requires: Requires = .{ .energy = 6.0, .materials = 80.0, .hours = 48 },
    /// How many of this good the agent holds. Only the first carries the effect.
    count: u32 = 1,
    unlock: Unlock = .{ .vigor_frac = 0.8, .food = 20.0, .goods = 4 },
    /// How many humans live under it. Act II's population fills this; Act I only asks
    /// whether it is more than one.
    capacity: u32 = 4,
};
