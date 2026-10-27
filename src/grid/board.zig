//! `grid/board` — the progression logic for the Act II STRUCTURE board: the adjacency rule
//! (§7) and atomic research resolution, operating over the **authored roster** (`roster.zig`)
//! and an agent's live `comp.Research` state array. The canonical entry state is seeded by
//! `comp.Research.entry(cat)` at the curtain (`migration.zig`); this module promotes and
//! establishes tiles from there.
//!
//! The board is the catalog's technology table (rings 1..4) keyed by catalog index — the same
//! stable key `comp.Research.state` is indexed by. Ring 0 is a logical Researched neighbor for
//! ring-1 adjacency only — it has no record and is never counted among the tiles (§5).
//!
//! Unlike `hex`, it reads the authored data (`roster.Catalog`) and the agent's state
//! (`comp.Research`). It owns no rendering, palette, or SDL — the rendering layer reads a
//! `comp.Research`'s per-tile state and the catalog's records and draws the bodies itself; it
//! never recomputes adjacency.
//!
//! Adjacency rule (§7): a Locked tile becomes Available when at least one of its six neighbors
//! with a **strictly lower ring number** is Researched. Researching a tile recomputes only its
//! outward neighbors; nothing unrelated opens.

const std = @import("std");
const hex = @import("./hex.zig");
const roster = @import("../roster.zig");
const comp = @import("../components.zig");

const Axial = hex.Axial;
const State = roster.TechState;
const Resource = roster.Resource;
const Catalog = roster.Catalog;
const Technology = roster.Technology;
const Research = comp.Research;

/// Convert an authored board coordinate (`roster.Coord`) to the pure hex geometry's `Axial`.
/// The two carry the same `(q, r)`; the board's adjacency math lives in `hex`, so a tile's
/// authored coordinate crosses into that geometry here.
fn axial(c: roster.Coord) Axial {
    return .{ .q = c.q, .r = c.r };
}

/// A held balance of the research resources, indexed by `@backingInt(Resource)`. Used to test
/// affordability and to apply an atomic research deduction. The six research currencies (Food,
/// Water, Fuel, Metal, Minerals, Biomass) are the only ones a cost ever names; Coin and generic
/// Materials have slots here but are never a research price (§7).
pub const Balances = struct {
    amounts: [res_count]u32 = @splat(0),

    const res_count = @typeInfo(Resource).@"enum".field_names.len;

    pub fn get(self: Balances, r: Resource) u32 {
        return self.amounts[@backingInt(r)];
    }

    pub fn set(self: *Balances, r: Resource, v: u32) void {
        self.amounts[@backingInt(r)] = v;
    }

    pub fn add(self: *Balances, r: Resource, v: u32) void {
        self.amounts[@backingInt(r)] += v;
    }
};

/// One unmet resource requirement, for a factual deficit readout (§7: show the factual deficit
/// only, no acquisition-route advice).
pub const Deficit = struct {
    resource: Resource,
    /// How much more is needed beyond the current balance.
    short: u32,
};

/// The resource a cost line names, as the typed `Resource` the balance is keyed by. A cost line
/// in the authored roster names its item by id (`"food"`, `"biomass"`, …); the research board
/// prices only in resources, so a non-resource id is a content error the loader has already
/// rejected (`roster` validation) — `null` here means the same.
fn lineResource(item: []const u8) ?Resource {
    return Catalog.resource(item);
}

/// The authored research cost of the tile at catalog `index` as a resource/amount pair for each
/// line. The authored quantities are whole numbers (`data/technologies.zon`); they are rounded
/// to the nearest unit for the integer balance the board spends.
fn lineAmount(n: f32) u32 {
    return @intFromFloat(@round(n));
}

/// The number of authored technologies — the number of board tiles (`roster` holds rings 1..4).
pub fn tileCount(cat: *const Catalog) usize {
    return cat.technologies.len;
}

/// The state of the tile at catalog `index`.
pub fn state(board: *const Research, index: usize) State {
    return board.state[index];
}

/// The state of the tile with stable id `id`, or `null` if the catalog has no such tile.
pub fn stateOf(cat: *const Catalog, board: *const Research, id: []const u8) ?State {
    const i = cat.techIndex(id) orelse return null;
    return board.state[i];
}

/// Whether a coordinate counts as a Researched neighbor for adjacency. Ring 0 (the foundation)
/// is always a logical Researched neighbor (§5); any authored tile counts only if its current
/// state is `researched`.
fn researchedAt(cat: *const Catalog, board: *const Research, coord: Axial) bool {
    if (hex.ring(coord) == 0) return true; // the foundation is a logical Researched neighbor
    for (cat.technologies, 0..) |t, i| if (axial(t.coord).eql(coord))
        return board.state[i] == .researched;
    return false; // off-board or no tile
}

/// Whether the tile at catalog `index` qualifies as Available under the adjacency rule: at
/// least one neighbor with a **strictly lower ring** is Researched. (A Researched tile trivially
/// also satisfies this; the rule governs the Locked→Available promotion.)
pub fn qualifiesAvailable(cat: *const Catalog, board: *const Research, index: usize) bool {
    const coord = axial(cat.technologies[index].coord);
    const my_ring = hex.ring(coord);
    var buf: [6]Axial = undefined;
    const ns = hex.neighbors(coord, &buf);
    for (ns) |nb| {
        if (hex.ring(nb) < my_ring and researchedAt(cat, board, nb)) return true;
    }
    return false;
}

/// Recompute every Locked tile's eligibility and promote those that now qualify to Available.
/// Available/Researched tiles are left untouched (promotion is one-way here; the UX prototype
/// never demotes). Returns the number of tiles promoted.
pub fn recomputeLocked(cat: *const Catalog, board: *Research) u32 {
    var promoted: u32 = 0;
    for (0..cat.technologies.len) |i| {
        if (board.state[i] == .locked and qualifiesAvailable(cat, board, i)) {
            board.state[i] = .available;
            promoted += 1;
        }
    }
    return promoted;
}

/// Recompute only the **outward neighbors** of the tile at `index` (§7: researching a tile
/// changes only its immediate outward neighbors from Locked to Available; nothing unrelated
/// opens). An outward neighbor is one on a strictly higher ring.
fn promoteOutwardNeighbors(cat: *const Catalog, board: *Research, index: usize) void {
    const coord = axial(cat.technologies[index].coord);
    const my_ring = hex.ring(coord);
    var buf: [6]Axial = undefined;
    const ns = hex.neighbors(coord, &buf);
    for (ns) |nb| {
        if (hex.ring(nb) <= my_ring) continue; // only outward
        for (cat.technologies, 0..) |nt, j| if (axial(nt.coord).eql(nb)) {
            if (board.state[j] == .locked and qualifiesAvailable(cat, board, j))
                board.state[j] = .available;
        };
    }
}

/// Whether the given tile's authored cost is fully affordable from `bal`.
pub fn affordable(tech: *const Technology, bal: Balances) bool {
    for (tech.cost) |line| {
        const r = lineResource(line.item) orelse return false;
        if (bal.get(r) < lineAmount(line.n)) return false;
    }
    return true;
}

/// Fill `out` with the factual deficits for an unaffordable tile and return the slice. `out`
/// must hold at least `tech.cost.len`.
pub fn deficits(tech: *const Technology, bal: Balances, out: []Deficit) []Deficit {
    var n: usize = 0;
    for (tech.cost) |line| {
        const r = lineResource(line.item) orelse continue;
        const need = lineAmount(line.n);
        const have = bal.get(r);
        if (have < need) {
            out[n] = .{ .resource = r, .short = need - have };
            n += 1;
        }
    }
    return out[0..n];
}

/// The outcome of a research attempt.
pub const ResearchResult = enum {
    /// Not Available (Locked, or already Researched) — nothing changed.
    not_available,
    /// Available but the balance cannot pay the full bundle — nothing changed (§7: never a
    /// partial payment).
    unaffordable,
    /// Paid atomically; the tile is now Researched and its outward neighbors recomputed.
    researched,
};

/// Attempt to research the tile at catalog `index`, paying from `bal` (§7 research resolution):
/// verify it is Available and fully affordable; deduct the complete bundle atomically; mark it
/// Researched on `research`; recompute only its outward neighbors. On any failure nothing
/// changes and `bal` is untouched.
pub fn research(cat: *const Catalog, board: *Research, index: usize, bal: *Balances) ResearchResult {
    if (board.state[index] != .available) return .not_available;
    const tech = &cat.technologies[index];
    if (!affordable(tech, bal.*)) return .unaffordable;
    // Atomic deduction — affordability was proven above, so no entry underflows.
    for (tech.cost) |line| {
        const r = lineResource(line.item).?;
        bal.amounts[@backingInt(r)] -= lineAmount(line.n);
    }
    board.state[index] = .researched;
    promoteOutwardNeighbors(cat, board, index);
    return .researched;
}

/// Count tiles in a given state — for tests and HUD summaries.
pub fn countState(cat: *const Catalog, board: *const Research, s: State) u32 {
    var n: u32 = 0;
    for (0..cat.technologies.len) |i| if (board.state[i] == s) {
        n += 1;
    };
    return n;
}

// ============================ Tests =============================

const testing = std.testing;

/// The shipped roster — the authored technology table the board runs over. Caller must deinit.
fn testCatalog() !Catalog {
    return roster.load(testing.allocator, roster.shipped, null);
}

/// The entry board for an agent crossing the curtain: every tile at its authored `initial`.
fn entry(cat: *const Catalog) Research {
    return Research.entry(cat);
}

/// The index of a tile by id — tests know the ids; the catalog resolves them.
fn indexOf(cat: *const Catalog, id: []const u8) usize {
    return cat.techIndex(id).?;
}

/// The canonical opening balances at the curtain: Food and Biomass carry opening values;
/// Water/Fuel/Metal/Minerals begin at zero (§8). Generous enough that the openers are
/// affordable, for the research-flow tests.
fn openingBalances() Balances {
    var b = Balances{};
    b.set(.food, 30);
    b.set(.biomass, 30);
    return b;
}

test "entry board matches the canonical curtain: 2 Researched, 9 Available, 49 Locked" {
    var cat = try testCatalog();
    defer cat.deinit();
    var r = entry(&cat);
    try testing.expectEqual(@as(u32, 2), countState(&cat, &r, .researched)); // Foraging, Woodcutting
    // Four ring-1 + five ring-2 openers = 9 Available.
    try testing.expectEqual(@as(u32, 9), countState(&cat, &r, .available));
    try testing.expectEqual(@as(u32, 49), countState(&cat, &r, .locked));
    try testing.expectEqual(@as(u32, 60), countState(&cat, &r, .researched) + countState(&cat, &r, .available) + countState(&cat, &r, .locked));
}

test "entry states equal what the adjacency rule computes from the two migrated tiles" {
    // Start from only the two migrated Researched tiles Locked-elsewhere, then let the
    // adjacency rule run. It must reproduce the authored 9 Available openers exactly — proving
    // the authored `initial` fields are consistent with §7, not hand-waved.
    var cat = try testCatalog();
    defer cat.deinit();
    var r = Research{};
    for (cat.technologies, 0..) |t, i| {
        r.state[i] = if (t.initial == .researched) .researched else .locked;
    }
    _ = recomputeLocked(&cat, &r);
    const canon = entry(&cat);
    for (0..cat.technologies.len) |i| {
        // Ignore the Researched set (identical by construction); compare Available/Locked.
        if (canon.state[i] == .researched) continue;
        try testing.expectEqual(canon.state[i], r.state[i]);
    }
}

test "ring-1 tiles are all at least Available (ring 0 is their logical Researched neighbor)" {
    var cat = try testCatalog();
    defer cat.deinit();
    const r = entry(&cat);
    for (cat.technologies, 0..) |t, i| if (t.coord.ring() == 1) {
        try testing.expect(r.state[i] != .locked);
    };
}

test "affordability is not a state: an unaffordable opener stays Available" {
    var cat = try testCatalog();
    defer cat.deinit();
    var r = entry(&cat);
    var bal = Balances{}; // empty — cannot afford anything
    // Spring well is Available and now unaffordable.
    const idx = indexOf(&cat, "spring_well");
    try testing.expectEqual(State.available, r.state[idx]);
    const result = research(&cat, &r, idx, &bal);
    try testing.expectEqual(ResearchResult.unaffordable, result);
    try testing.expectEqual(State.available, r.state[idx]); // unchanged
}

test "research deducts the full bundle atomically and marks Researched" {
    var cat = try testCatalog();
    defer cat.deinit();
    var r = entry(&cat);
    var bal = openingBalances();
    const idx = indexOf(&cat, "spring_well"); // food 2, biomass 3
    const food_before = bal.get(.food);
    const biomass_before = bal.get(.biomass);
    const result = research(&cat, &r, idx, &bal);
    try testing.expectEqual(ResearchResult.researched, result);
    try testing.expectEqual(State.researched, r.state[idx]);
    try testing.expectEqual(food_before - 2, bal.get(.food));
    try testing.expectEqual(biomass_before - 3, bal.get(.biomass));
}

test "researching Spring well opens exactly its outward neighbor, nothing unrelated" {
    var cat = try testCatalog();
    defer cat.deinit();
    var r = entry(&cat);
    var bal = openingBalances();
    // Capture the Locked set before.
    var locked_before: [roster.max_techs]bool = @splat(false);
    for (0..cat.technologies.len) |i| locked_before[i] = (r.state[i] == .locked);

    const idx = indexOf(&cat, "spring_well"); // (0,1) Water ring 1
    _ = research(&cat, &r, idx, &bal);

    // Well & cistern (0,2) is Spring well's outward Water neighbor → now Available.
    try testing.expectEqual(State.available, r.state[indexOf(&cat, "well_cistern")]);

    // Every tile that was Locked and is now Available must be an outward neighbor of (0,1).
    var buf: [6]Axial = undefined;
    const ns = hex.neighbors(.{ .q = 0, .r = 1 }, &buf);
    for (0..cat.technologies.len) |i| {
        if (locked_before[i] and r.state[i] == .available) {
            var is_neighbor = false;
            for (ns) |nb| if (axial(cat.technologies[i].coord).eql(nb)) {
                is_neighbor = true;
            };
            try testing.expect(is_neighbor);
            try testing.expect(cat.technologies[i].coord.ring() > 1); // strictly outward
        }
    }
}

test "a Locked tile cannot be researched" {
    var cat = try testCatalog();
    defer cat.deinit();
    var r = entry(&cat);
    var bal = openingBalances();
    const idx = indexOf(&cat, "salting_smoking"); // ring 3, Locked at entry
    try testing.expectEqual(State.locked, r.state[idx]);
    try testing.expectEqual(ResearchResult.not_available, research(&cat, &r, idx, &bal));
}

test "deficits report the factual shortfall only" {
    var cat = try testCatalog();
    defer cat.deinit();
    const tech = cat.technology("spring_well").?; // food 2, biomass 3
    var bal = Balances{};
    bal.set(.food, 1); // short 1 food
    bal.set(.biomass, 0); // short 3 biomass
    var out: [8]Deficit = undefined;
    const defs = deficits(tech, bal, &out);
    try testing.expectEqual(@as(usize, 2), defs.len);
    // Both shortfalls present with exact amounts; no advice, just facts.
    var food_short: u32 = 0;
    var biomass_short: u32 = 0;
    for (defs) |d| switch (d.resource) {
        .food => food_short = d.short,
        .biomass => biomass_short = d.short,
        else => {},
    };
    try testing.expectEqual(@as(u32, 1), food_short);
    try testing.expectEqual(@as(u32, 3), biomass_short);
}

test "a chain of research walks a wedge outward without opening other wedges" {
    var cat = try testCatalog();
    defer cat.deinit();
    var r = entry(&cat);
    var bal = Balances{};
    // Fund generously so cost is never the blocker in this adjacency test.
    for (0..bal.amounts.len) |i| bal.amounts[i] = 1000;

    // Water wedge: Spring well (r1) → Well & cistern (r2) → Aqueduct (r3) → Pumping station (r4).
    const chain = [_][]const u8{ "spring_well", "well_cistern", "aqueduct", "pumping_station" };
    for (chain) |id| {
        const idx = indexOf(&cat, id);
        try testing.expectEqual(State.available, r.state[idx]); // adjacency opened it
        try testing.expectEqual(ResearchResult.researched, research(&cat, &r, idx, &bal));
    }
    try testing.expectEqual(State.researched, stateOf(&cat, &r, "pumping_station").?);
    // A far wedge pure corner (Metal ring 4) stays Locked — nothing unrelated opened.
    try testing.expectEqual(State.locked, stateOf(&cat, &r, "precision_machining").?);
}
