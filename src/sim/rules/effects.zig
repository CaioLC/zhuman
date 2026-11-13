//! `effects` — the interpreter of the authored roster's gates and its `Effect` vocabulary.
//!
//! What an agent can do, and on what terms, is a pure function of the catalog and what the
//! agent holds (`Holdings`): the verbs of its own (`comp.Verbs`), the goods it owns and its
//! research. `held` says whether a verb is the agent's: its own, or gated and every gate
//! passing — a researched `tech`, `any` of a list of goods and verbs, `all` of a list; a good
//! passes while one unit is owned, a verb while it is held. `verb` returns a held verb's
//! effective terms by folding every applying good's effects into the base record, in roster
//! order. Nothing is cached and there is no remove path — losing a good is just a different
//! input to the same function, which is what keeps a build → sell → build cycle bit-exact. A
//! good's own gates are read by the same `gatesMet` (`capital.quote`).
//!
//! **A family's best rank wins.** A good in a family applies only while it is the highest
//! rank of that family the agent owns; the lower ranks are superseded, not stacked. Goods
//! outside any family stack freely.
//!
//! The body and the larder are the exception to "derive, never store": their components have
//! other writers (the metabolism), so `apply` computes what the goods
//! contribute, diffs it against `comp.Granted`, and applies the delta — raising the ceiling
//! fills what it adds, lowering it only clamps.

const std = @import("std");
const comp = @import("../components.zig");
const roster = @import("../data/roster.zig");
const dist = @import("../kernel/dist.zig");

const World = @import("../ecs.zig").World;
const Entity = @import("../ecs.zig").Entity;
const Catalog = roster.Catalog;
const Effect = roster.Effect;
const Resource = roster.Resource;

/// A verb's effective terms for one agent: the base record with every applying good's
/// effects folded in. The gates are the record's own.
pub const Verb = struct {
    requires: roster.Requires,
    output: roster.Output,
};

/// What a gate reads of an agent: the verbs of its own (none when null), the goods it owns,
/// and its research board (nothing researched when null).
pub const Holdings = struct {
    verbs: ?*const comp.Verbs = null,
    goods: *const comp.Goods,
    research: ?*const comp.Research = null,
};

/// Agent `e`'s holdings, or null when it owns no `comp.Goods`.
pub fn holdingsOf(w: *const World, e: Entity) ?Holdings {
    return .{
        .verbs = w.get(e, comp.Verbs),
        .goods = w.get(e, comp.Goods) orelse return null,
        .research = w.get(e, comp.Research),
    };
}

/// The best rank of `family` the agent owns; 0 when it owns none of it.
pub fn bestRank(cat: *const Catalog, goods: *const comp.Goods, family: []const u8) u8 {
    var best: u8 = 0;
    for (cat.goods, 0..) |g, gi| {
        if (goods.count[gi] == 0) continue;
        const f = g.family orelse continue;
        if (std.mem.eql(u8, f.name, family) and f.rank > best) best = f.rank;
    }
    return best;
}

/// Whether the good at `gi` currently has its effect: owned, and if it is in a family, the
/// best rank of that family owned.
pub fn applies(cat: *const Catalog, goods: *const comp.Goods, gi: usize) bool {
    if (goods.count[gi] == 0) return false;
    const f = cat.goods[gi].family orelse return true;
    return f.rank == bestRank(cat, goods, f.name);
}

/// Whether `req`'s technology gate passes: none named, or researched on the agent's board.
pub fn techMet(cat: *const Catalog, h: Holdings, req: *const roster.Requires) bool {
    const id = req.tech orelse return true;
    const ti = cat.techIndex(id) orelse return false;
    const research = h.research orelse return false;
    return research.state[ti] == .researched;
}

/// Whether one gate entry passes: a good owned (one unit is all that counts), or a verb held.
/// An id the catalog lacks never passes.
pub fn gatePasses(cat: *const Catalog, h: Holdings, id: []const u8) bool {
    if (cat.goodIndex(id)) |gi| return h.goods.count[gi] > 0;
    if (cat.actionIndex(id)) |ai| return held(cat, h, ai);
    return false;
}

/// Whether `req`'s `any` and `all` gates pass: one of `any` (when it names any) and every one
/// of `all`.
pub fn listsMet(cat: *const Catalog, h: Holdings, req: *const roster.Requires) bool {
    return firstUnmet(cat, h, req) == null;
}

/// The first gate entry of `any` or `all` that stands in the way — `any`'s first entry when
/// none of it passes, else the first of `all` that does not — or null when both pass.
pub fn firstUnmet(cat: *const Catalog, h: Holdings, req: *const roster.Requires) ?[]const u8 {
    if (req.any.len > 0) {
        var one = false;
        for (req.any) |id| if (gatePasses(cat, h, id)) {
            one = true;
            break;
        };
        if (!one) return req.any[0];
    }
    for (req.all) |id| if (!gatePasses(cat, h, id)) return id;
    return null;
}

/// Whether every gate of `req` passes: its technology, then its lists.
pub fn gatesMet(cat: *const Catalog, h: Holdings, req: *const roster.Requires) bool {
    return techMet(cat, h, req) and listsMet(cat, h, req);
}

/// Whether the agent holds verb `ai`: its own (`h.verbs`), or a verb with a gate whose every
/// gate passes. A verb with no gate is held only as the agent's own. The validator refuses a
/// gate that leads back to its own verb, so the recursion through verb gates ends.
pub fn held(cat: *const Catalog, h: Holdings, ai: usize) bool {
    if (h.verbs) |v| if (v.held[ai]) return true;
    const req = &cat.actions[ai].requires;
    return req.gated() and gatesMet(cat, h, req);
}

/// The effective terms of verb `ai` for an agent with holdings `h`, or null if not held.
pub fn verb(cat: *const Catalog, h: Holdings, ai: usize) ?Verb {
    if (!held(cat, h, ai)) return null;
    return terms(cat, h.goods, ai);
}

/// Verb `ai`'s terms with every applying good's effects folded in, without asking whether the
/// agent holds it.
pub fn terms(cat: *const Catalog, goods: *const comp.Goods, ai: usize) Verb {
    const rec = cat.actions[ai];
    var v = Verb{ .requires = rec.requires, .output = rec.output };
    for (cat.goods, 0..) |g, gi| {
        if (!applies(cat, goods, gi)) continue;
        for (g.effects) |e| switch (e) {
            .scale => |t| if (std.mem.eql(u8, t.target, rec.id)) tweak(&v, t, .scale),
            .add => |t| if (std.mem.eql(u8, t.target, rec.id)) tweak(&v, t, .add),
            else => {},
        };
    }
    return v;
}

const Op = enum { scale, add };

/// Apply one tweak. A scale on an output moves its draw's scale, preserving the distribution's
/// shape; a scale on an absent output is nothing to scale. An `add` on an absent output inserts
/// it as an exact amount, and an `add` on an input adds to its resource's amount, which is how
/// a tool can put a fuel cost on a verb that had none.
fn tweak(v: *Verb, t: Effect.Tweak, op: Op) void {
    switch (t.stat) {
        .energy => v.requires.energy = fold(v.requires.energy, t.by, op),
        .hours => v.requires.hours = fold(v.requires.hours, t.by, op),
        .input => |r| {
            const n = v.requires.ptr(r);
            n.* = fold(n.*, t.by, op);
        },
        .output => |r| {
            const slot = v.output.ptr(r);
            if (slot.*) |*d| {
                const s = d.scalePtr();
                s.* = fold(s.*, t.by, op);
            } else if (op == .add) slot.* = .{ .fixed = t.by };
        },
    }
}

fn fold(x: f32, by: f32, op: Op) f32 {
    return switch (op) {
        .scale => x * by,
        .add => x + by,
    };
}

/// What the owned goods contribute to the body and the larder.
pub const Contribution = struct {
    vigor_ceiling: f32 = 0,
    food_quality: u8 = 0,
    spoil_scale: f32 = 1,
};

pub fn contribution(cat: *const Catalog, goods: *const comp.Goods) Contribution {
    var c = Contribution{};
    for (cat.goods, 0..) |g, gi| {
        if (!applies(cat, goods, gi)) continue;
        for (g.effects) |e| switch (e) {
            .vigor_ceiling => |a| c.vigor_ceiling += a,
            .food_quality => |q| c.food_quality += q,
            .spoil_scale => |s| c.spoil_scale *= s,
            else => {},
        };
    }
    return c;
}

/// Bring the body and the larder in line with what the owned goods now contribute. Called
/// after any change of ownership. The ceiling moves by the delta: a rise fills what it adds
/// (a first night in a real bed), a fall only clamps (a night's rest is kept) — the
/// asymmetry is the designed lifecycle. Quality moves by its delta; spoilage is rescaled.
pub fn apply(w: *World, e: Entity, cat: *const Catalog) void {
    const goods = w.get(e, comp.Goods) orelse return;
    const granted = w.get(e, comp.Granted) orelse return;
    const now = contribution(cat, goods);
    if (w.get(e, comp.Vigor)) |vigor| {
        const delta = now.vigor_ceiling - granted.vigor_ceiling;
        if (delta > 0) {
            vigor.max += delta;
            vigor.v = @min(vigor.v + delta, vigor.max);
        } else if (delta < 0) {
            vigor.max += delta;
            if (vigor.v > vigor.max) vigor.v = vigor.max;
        }
    }
    if (w.get(e, comp.InventoryFood)) |food| {
        const q: i16 = @as(i16, food.quality) - @as(i16, granted.food_quality) + @as(i16, now.food_quality);
        food.quality = @intCast(@max(0, q));
        if (now.spoil_scale != granted.spoil_scale) {
            food.spoils = food.spoils / granted.spoil_scale * now.spoil_scale;
        }
    }
    granted.* = .{
        .vigor_ceiling = now.vigor_ceiling,
        .food_quality = now.food_quality,
        .spoil_scale = now.spoil_scale,
    };
}

// ============================ Tests =====================================================
// The interpreter over the shipped roster: base terms, stacks, family supersession, the body
// and larder deltas, and the property everything rests on — owning then losing a good leaves
// every verb, the vigor ceiling and the larder exactly where they were.

const testing = std.testing;

fn fixture() !Catalog {
    return roster.load(testing.allocator, roster.shipped, null);
}

/// An agent holding the starting pair of its own, as the player spawns.
fn spawnAgent(w: *World, cat: *const Catalog) Entity {
    return w.spawn(.{ comp.Vigor{}, comp.InventoryFood{}, comp.InventoryBiomass{}, comp.Goods{}, comp.Granted{}, comp.Verbs.of(cat, &.{ "forage", "scavenge" }) });
}

/// Own one more of good `id`, settling the body and larder as the build path does.
fn own(w: *World, e: Entity, cat: *const Catalog, id: []const u8) void {
    w.get(e, comp.Goods).?.count[cat.goodIndex(id).?] += 1;
    apply(w, e, cat);
}

/// Lose one of good `id`, spares first.
fn lose(w: *World, e: Entity, cat: *const Catalog, id: []const u8) void {
    w.get(e, comp.Goods).?.count[cat.goodIndex(id).?] -= 1;
    apply(w, e, cat);
}

fn verbOf(w: *World, e: Entity, cat: *const Catalog, id: []const u8) ?Verb {
    return verb(cat, holdingsOf(w, e).?, cat.actionIndex(id).?);
}

/// What an agent can do and how its body stands: every Act I verb's terms, the vigor and the
/// larder.
const Snapshot = struct {
    verbs: [16]?Verb = @splat(null),
    max: f32,
    v: f32,
    quality: u8,
    spoils: f32,

    fn take(w: *World, e: Entity, cat: *const Catalog) Snapshot {
        var s = Snapshot{
            .max = w.get(e, comp.Vigor).?.max,
            .v = w.get(e, comp.Vigor).?.v,
            .quality = w.get(e, comp.InventoryFood).?.quality,
            .spoils = w.get(e, comp.InventoryFood).?.spoils,
        };
        var n: usize = 0;
        for (cat.actions, 0..) |a, ai| {
            if (a.act != 1) continue;
            s.verbs[n] = verb(cat, holdingsOf(w, e).?, ai);
            n += 1;
        }
        return s;
    }
};

/// Two verbs' terms, bit for bit: every amount they require and every draw they yield.
fn expectTerms(a: *const Verb, b: *const Verb) !void {
    try testing.expectEqual(a.requires.energy, b.requires.energy);
    try testing.expectEqual(a.requires.hours, b.requires.hours);
    for (std.enums.values(Resource)) |r| {
        try testing.expectEqual(a.requires.get(r), b.requires.get(r));
        try testing.expectEqual(a.output.get(r), b.output.get(r));
    }
    try testing.expectEqual(a.output.vigor, b.output.vigor);
}

fn expectSnapshot(a: Snapshot, b: Snapshot) !void {
    for (a.verbs, b.verbs) |x, y| {
        try testing.expectEqual(x == null, y == null);
        const vx = x orelse continue;
        try expectTerms(&vx, &y.?);
    }
    try testing.expectEqual(a.max, b.max);
    // Current vigor keeps what a raised ceiling filled: that is the fill rule, not drift.
    try testing.expect(b.v >= a.v);
    try testing.expectEqual(a.quality, b.quality);
    try testing.expectEqual(a.spoils, b.spoils);
}

test "with nothing owned, the agent's own verbs are the base records and nothing else is held" {
    var cat = try fixture();
    defer cat.deinit();
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    const e = spawnAgent(&w, &cat);
    const h = holdingsOf(&w, e).?;
    const forage = cat.action("forage").?;
    const v = verbOf(&w, e, &cat, "forage").?;
    try expectTerms(&.{ .requires = forage.requires, .output = forage.output }, &v);
    try testing.expect(held(&cat, h, cat.actionIndex("scavenge").?));
    try testing.expect(!held(&cat, h, cat.actionIndex("fish").?));
    try testing.expect(!held(&cat, .{ .goods = h.goods }, cat.actionIndex("forage").?)); // none of its own
}

test "owning a good and losing it again leaves every verb, the ceiling and the larder as they were" {
    var cat = try fixture();
    defer cat.deinit();
    for (cat.goods) |g| {
        if (g.act != 1) continue;
        var w = try World.init(std.testing.allocator);
        defer w.deinit();
        try checkReversible(&w, &cat, g.id);
    }
}

fn checkReversible(w: *World, cat: *const Catalog, id: []const u8) !void {
    const e = spawnAgent(w, cat);
    w.get(e, comp.Vigor).?.v = 7; // under the ceiling, so a fill on the way in shows
    // A modifier on Split wood works only once the hatchet is owned.
    own(w, e, cat, "hatchet");
    const before = Snapshot.take(w, e, cat);
    own(w, e, cat, id);
    lose(w, e, cat, id);
    try expectSnapshot(before, Snapshot.take(w, e, cat));
}

/// What the roster's work gloves make of Split wood's energy.
const gloves_energy: f32 = 0.85;
/// What the roster's hand axe makes of Split wood's yield.
const axe_yield: f32 = 2.0;

test "goods on one verb stack; a spare carries no second effect" {
    var cat = try fixture();
    defer cat.deinit();
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    const e = spawnAgent(&w, &cat);
    own(&w, e, &cat, "hand_axe");
    own(&w, e, &cat, "work_gloves");
    const both = verbOf(&w, e, &cat, "chop_wood").?.requires.energy;
    try testing.expectApproxEqAbs(@as(f32, 4.0 * 0.7) * gloves_energy, both, 1e-5);
    own(&w, e, &cat, "work_gloves"); // a second pair is stock
    try testing.expectEqual(both, verbOf(&w, e, &cat, "chop_wood").?.requires.energy);
    lose(&w, e, &cat, "work_gloves"); // the spare goes first, the discount stays
    try testing.expectEqual(both, verbOf(&w, e, &cat, "chop_wood").?.requires.energy);
    lose(&w, e, &cat, "work_gloves");
    try testing.expectApproxEqAbs(@as(f32, 4.0 * 0.7), verbOf(&w, e, &cat, "chop_wood").?.requires.energy, 1e-5);
    lose(&w, e, &cat, "hand_axe");
    try testing.expect(verbOf(&w, e, &cat, "chop_wood") == null);
}

test "the chopping stack: hatchet, gloves, then the hand axe supersedes the hatchet" {
    var cat = try fixture();
    defer cat.deinit();
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    const e = spawnAgent(&w, &cat);
    own(&w, e, &cat, "hatchet");
    own(&w, e, &cat, "work_gloves");
    const with_hatchet = verbOf(&w, e, &cat, "chop_wood").?;
    try testing.expectApproxEqAbs(@as(f32, 4.0) * gloves_energy, with_hatchet.requires.energy, 1e-5);
    own(&w, e, &cat, "hand_axe");
    const chop = verbOf(&w, e, &cat, "chop_wood").?;
    try testing.expectApproxEqAbs(@as(f32, 4.0 * 0.7) * gloves_energy, chop.requires.energy, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 8.0) * axe_yield, chop.output.biomass.?.scale(), 1e-4);
    lose(&w, e, &cat, "hand_axe"); // back to the hatchet's rank, modifiers kept
    const again = verbOf(&w, e, &cat, "chop_wood").?;
    try expectTerms(&with_hatchet, &again);
    lose(&w, e, &cat, "hatchet"); // the verb leaves with the last tool
    try testing.expect(verbOf(&w, e, &cat, "chop_wood") == null);
}

test "fifty rod → net → sell → sell cycles leave the fishing terms bit-exact" {
    var cat = try fixture();
    defer cat.deinit();
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    const e = spawnAgent(&w, &cat);
    own(&w, e, &cat, "fish_rod");
    const rod = verbOf(&w, e, &cat, "fish").?;
    own(&w, e, &cat, "fish_net");
    try testing.expect(verbOf(&w, e, &cat, "fish").?.output.food.?.scale() != rod.output.food.?.scale());
    lose(&w, e, &cat, "fish_net");
    lose(&w, e, &cat, "fish_rod");
    try testing.expect(verbOf(&w, e, &cat, "fish") == null);
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        own(&w, e, &cat, "fish_rod");
        own(&w, e, &cat, "fish_net");
        lose(&w, e, &cat, "fish_net");
        lose(&w, e, &cat, "fish_rod");
    }
    own(&w, e, &cat, "fish_rod");
    const after = verbOf(&w, e, &cat, "fish").?;
    try expectTerms(&rod, &after);
}

test "the body and larder: ceilings fill on the way up and clamp on the way down" {
    var cat = try fixture();
    defer cat.deinit();
    var w = try World.init(std.testing.allocator);
    defer w.deinit();
    const e = spawnAgent(&w, &cat);
    w.get(e, comp.Vigor).?.v = 8;
    own(&w, e, &cat, "leaf_bed"); // max 11, v 9
    own(&w, e, &cat, "rope_bag"); // max 12, v 10
    try testing.expectEqual(@as(f32, 12), w.get(e, comp.Vigor).?.max);
    try testing.expectEqual(@as(f32, 10), w.get(e, comp.Vigor).?.v);
    w.get(e, comp.Vigor).?.v = 12;
    lose(&w, e, &cat, "rope_bag"); // max 11, v clamped to 11
    try testing.expectEqual(@as(f32, 11), w.get(e, comp.Vigor).?.v);
    lose(&w, e, &cat, "leaf_bed"); // max 10, v clamped to 10
    try testing.expectEqual(@as(f32, 10), w.get(e, comp.Vigor).?.max);
    try testing.expectEqual(@as(f32, 10), w.get(e, comp.Vigor).?.v);

    own(&w, e, &cat, "cookpot");
    own(&w, e, &cat, "root_cellar");
    try testing.expectEqual(@as(u8, 2), w.get(e, comp.InventoryFood).?.quality);
    try testing.expectApproxEqAbs(@as(f32, 0.05), w.get(e, comp.InventoryFood).?.spoils, 1e-7);
    lose(&w, e, &cat, "root_cellar");
    lose(&w, e, &cat, "cookpot");
    try testing.expectEqual(@as(u8, 1), w.get(e, comp.InventoryFood).?.quality);
    try testing.expectApproxEqAbs(@as(f32, 0.1), w.get(e, comp.InventoryFood).?.spoils, 1e-7);
}

test "a scale on an absent output is nothing to scale; an add inserts it, or adds to an input" {
    var v = Verb{
        .requires = .{ .energy = 1, .hours = 1 },
        .output = .{ .food = .{ .normal = 2 } },
    };
    tweak(&v, .{ .target = "x", .stat = .{ .output = .biomass }, .by = 3 }, .scale);
    try testing.expect(v.output.biomass == null);
    tweak(&v, .{ .target = "x", .stat = .{ .output = .food }, .by = 3 }, .scale);
    try testing.expectEqual(roster.Draw{ .normal = 6 }, v.output.food.?); // shape preserved
    tweak(&v, .{ .target = "x", .stat = .{ .input = .biomass }, .by = 1 }, .add);
    try testing.expectEqual(@as(f32, 1), v.requires.biomass);
    tweak(&v, .{ .target = "x", .stat = .{ .output = .biomass }, .by = 2 }, .add);
    try testing.expectEqual(roster.Draw{ .fixed = 2 }, v.output.biomass.?);
    tweak(&v, .{ .target = "x", .stat = .{ .output = .food }, .by = 1 }, .add);
    try testing.expectEqual(roster.Draw{ .normal = 7 }, v.output.food.?);
}

test "a gate passes on one unit of a good, a held verb or a researched technology" {
    var cat = try roster.load(testing.allocator, .{
        .actions =
        \\.{
        \\    .{ .id = "fish", .name = "Fish", .requires = .{ .energy = 1.0, .any = .{ "rod", "net" } } },
        \\    .{ .id = "smoke", .name = "Smoke", .act = 2, .requires = .{ .energy = 1.0, .tech = "kilns", .all = .{ "fish", "rack" } } },
        \\    .{ .id = "idle", .name = "Idle", .requires = .{ .energy = 1.0 } },
        \\}
        ,
        .goods =
        \\.{
        \\    .{ .id = "rod", .name = "Rod", .tier = .crude },
        \\    .{ .id = "net", .name = "Net", .tier = .crude },
        \\    .{ .id = "rack", .name = "Rack", .act = 2, .tier = .crude },
        \\}
        ,
        .technologies =
        \\.{ .{ .id = "kilns", .name = "Kilns", .coord = .{ .q = 1, .r = 0 }, .cost = .{ .food = 1.0 } } }
        ,
    }, null);
    defer cat.deinit();
    var goods = comp.Goods{};
    var research = comp.Research.entry(&cat);
    const h = Holdings{ .goods = &goods, .research = &research };
    const fish = cat.actionIndex("fish").?;
    const smoke = cat.actionIndex("smoke").?;
    try testing.expect(!held(&cat, h, fish));
    goods.count[cat.goodIndex("net").?] = 2; // any one of the list; a second unit is stock
    try testing.expect(held(&cat, h, fish));
    goods.count[cat.goodIndex("rack").?] = 1;
    try testing.expect(!held(&cat, h, smoke)); // the board has not established the kilns
    try testing.expectEqualStrings("kilns", cat.action("smoke").?.requires.tech.?);
    research.state[cat.techIndex("kilns").?] = .researched;
    try testing.expect(held(&cat, h, smoke)); // the verb gate passes through the fish
    goods.count[cat.goodIndex("net").?] = 0;
    try testing.expect(!held(&cat, h, smoke));
    try testing.expectEqualStrings("fish", firstUnmet(&cat, h, &cat.actions[smoke].requires).?);
    // A verb with no gate is held only as an agent's own.
    try testing.expect(!held(&cat, h, cat.actionIndex("idle").?));
}
