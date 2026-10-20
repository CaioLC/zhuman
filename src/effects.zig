//! `effects` — the interpreter of the authored roster's `Effect` vocabulary.
//!
//! What an agent can do, and on what terms, is a pure function of the catalog and the goods
//! the agent owns: `verb` returns a verb's effective terms by folding every applying good's
//! effects into the base record, in roster order, and returns null when nothing grants the
//! verb. Nothing is cached and there is no remove path — losing a good is just a different
//! input to the same function, which is what keeps a build → sell → build cycle bit-exact.
//!
//! **A family's best rank wins.** A good in a family applies only while it is the highest
//! rank of that family the agent owns; the lower ranks are superseded, not stacked. Goods
//! outside any family stack freely.
//!
//! The body and the larder are the exception to "derive, never store": their components have
//! other writers (the metabolism, a future aging term), so `apply` computes what the goods
//! contribute, diffs it against `comp.Granted`, and applies the delta — raising the ceiling
//! fills what it adds, lowering it only clamps.

const std = @import("std");
const ha = @import("ha");
const comp = ha.comp;
const roster = ha.roster;

const World = ha.world.World;
const Entity = ha.world.Entity;
const Catalog = roster.Catalog;
const Line = roster.Line;
const Lines = roster.Lines;
const Effect = roster.Effect;

/// A verb's effective terms for one agent: the base record with every applying good's
/// effects folded in.
pub const Verb = struct {
    requires: roster.Price,
    input: Lines,
    output: Lines,
};

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

/// Whether the agent holds verb `ai`: innate, or granted by an applying good.
pub fn held(cat: *const Catalog, goods: *const comp.Goods, ai: usize) bool {
    const id = cat.actions[ai].id;
    if (cat.actions[ai].innate) return true;
    for (cat.goods, 0..) |g, gi| {
        if (!applies(cat, goods, gi)) continue;
        for (g.effects) |e| switch (e) {
            .grant => |t| if (std.mem.eql(u8, t, id)) return true,
            else => {},
        };
    }
    return false;
}

/// The effective terms of verb `ai` for an agent owning `goods`, or null if not held.
pub fn verb(cat: *const Catalog, goods: *const comp.Goods, ai: usize) ?Verb {
    if (!held(cat, goods, ai)) return null;
    return terms(cat, goods, ai);
}

/// Verb `ai`'s terms with every applying good's effects folded in, without asking whether the
/// goods hold it — for a caller that opens the verb another way, as research does
/// (`actions.verbOf`).
pub fn terms(cat: *const Catalog, goods: *const comp.Goods, ai: usize) Verb {
    const rec = cat.actions[ai];
    var v = Verb{
        .requires = rec.requires,
        .input = Lines.of(rec.input),
        .output = Lines.of(rec.output),
    };
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

/// Apply one tweak. A scale on a line moves `n` and `sd` together, preserving the
/// distribution's shape; a scale on an absent line is nothing to scale. An `add` on an
/// absent line inserts it as an exact once-line, which is how a tool can put a fuel cost on
/// a verb that had none.
fn tweak(v: *Verb, t: Effect.Tweak, op: Op) void {
    switch (t.stat) {
        .energy => v.requires.energy = fold(v.requires.energy, t.by, op),
        .hours => v.requires.hours = fold(v.requires.hours, t.by, op),
        .input => |item| tweakLine(&v.input, item, t.by, op),
        .output => |item| tweakLine(&v.output, item, t.by, op),
    }
}

fn tweakLine(side: *Lines, item: []const u8, by: f32, op: Op) void {
    if (side.find(item, .once)) |l| {
        l.n = fold(l.n, by, op);
        if (op == .scale) l.sd *= by;
        return;
    }
    if (op == .add) side.push(.{ .item = item, .n = by });
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

fn spawnAgent(w: *World) Entity {
    return w.spawn(.{ comp.Vigor{}, comp.InventoryFood{}, comp.InventoryBiomass{}, comp.Goods{}, comp.Granted{} });
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
    return verb(cat, w.get(e, comp.Goods).?, cat.actionIndex(id).?);
}

/// What an agent can do and how its body stands: every Act I verb's terms, the vigor and the
/// larder.
const Snapshot = struct {
    verbs: [8]?Verb = [_]?Verb{null} ** 8,
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
            s.verbs[n] = verb(cat, w.get(e, comp.Goods).?, ai);
            n += 1;
        }
        return s;
    }
};

fn expectLines(a: *const Lines, b: *const Lines) !void {
    try testing.expectEqual(a.len, b.len);
    for (a.slice(), b.slice()) |x, y| {
        try testing.expectEqualStrings(x.item, y.item);
        try testing.expectEqual(x.n, y.n);
        try testing.expectEqual(x.sd, y.sd);
        try testing.expectEqual(x.kind, y.kind);
    }
}

fn expectSnapshot(a: Snapshot, b: Snapshot) !void {
    for (a.verbs, b.verbs) |x, y| {
        try testing.expectEqual(x == null, y == null);
        const vx = x orelse continue;
        const vy = y.?;
        try testing.expectEqual(vx.requires.energy, vy.requires.energy);
        try testing.expectEqual(vx.requires.hours, vy.requires.hours);
        try expectLines(&vx.input, &vy.input);
        try expectLines(&vx.output, &vy.output);
    }
    try testing.expectEqual(a.max, b.max);
    // Current vigor keeps what a raised ceiling filled: that is the fill rule, not drift.
    try testing.expect(b.v >= a.v);
    try testing.expectEqual(a.quality, b.quality);
    try testing.expectEqual(a.spoils, b.spoils);
}

test "with nothing owned, the innate verbs are the base records and nothing else is held" {
    var cat = try fixture();
    defer cat.deinit();
    var w = World.init();
    const e = spawnAgent(&w);
    const goods = w.get(e, comp.Goods).?;
    const forage = cat.action("forage").?;
    const v = verbOf(&w, e, &cat, "forage").?;
    try testing.expectEqual(forage.requires.energy, v.requires.energy);
    try testing.expectEqual(forage.requires.hours, v.requires.hours);
    try expectLines(&Lines.of(forage.output), &v.output);
    try testing.expect(held(&cat, goods, cat.actionIndex("scavenge").?));
    try testing.expect(!held(&cat, goods, cat.actionIndex("fish").?));
}

test "owning a good and losing it again leaves every verb, the ceiling and the larder as they were" {
    var cat = try fixture();
    defer cat.deinit();
    // One world, re-initialized per good inside a call of its own: a world-sized temporary
    // per iteration would overflow the test's stack.
    var w = World.init();
    for (cat.goods) |g| {
        if (g.act != 1) continue;
        try checkReversible(&w, &cat, g.id);
    }
}

fn checkReversible(w: *World, cat: *const Catalog, id: []const u8) !void {
    w.* = World.init();
    const e = spawnAgent(w);
    w.get(e, comp.Vigor).?.v = 7; // under the ceiling, so a fill on the way in shows
    // A modifier on Split wood works only once the hatchet is owned.
    if (cat.good(id).?.needs.len > 0) own(w, e, cat, "hatchet");
    const before = Snapshot.take(w, e, cat);
    own(w, e, cat, id);
    lose(w, e, cat, id);
    try expectSnapshot(before, Snapshot.take(w, e, cat));
}

test "goods on one verb stack; a spare carries no second effect" {
    var cat = try fixture();
    defer cat.deinit();
    var w = World.init();
    const e = spawnAgent(&w);
    own(&w, e, &cat, "sandals");
    own(&w, e, &cat, "bicycle");
    const both = verbOf(&w, e, &cat, "forage").?.requires.energy;
    try testing.expectApproxEqAbs(@as(f32, 1.7 * 0.85 * 0.6), both, 1e-5);
    own(&w, e, &cat, "sandals"); // a second pair is stock
    try testing.expectEqual(both, verbOf(&w, e, &cat, "forage").?.requires.energy);
    lose(&w, e, &cat, "sandals"); // the spare goes first, the discount stays
    try testing.expectEqual(both, verbOf(&w, e, &cat, "forage").?.requires.energy);
    lose(&w, e, &cat, "bicycle");
    lose(&w, e, &cat, "sandals");
    try testing.expectEqual(cat.action("forage").?.requires.energy, verbOf(&w, e, &cat, "forage").?.requires.energy);
}

test "the chopping stack: hatchet, gloves, chainsaw, then the hand axe supersedes the hatchet" {
    var cat = try fixture();
    defer cat.deinit();
    var w = World.init();
    const e = spawnAgent(&w);
    own(&w, e, &cat, "hatchet");
    own(&w, e, &cat, "work_gloves");
    own(&w, e, &cat, "chainsaw");
    const with_hatchet = verbOf(&w, e, &cat, "chop_wood").?;
    own(&w, e, &cat, "hand_axe");
    const chop = verbOf(&w, e, &cat, "chop_wood").?;
    try testing.expectApproxEqAbs(@as(f32, 5.0 * 0.7 * 0.75 * 0.3), chop.requires.energy, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 5.0 * 1.4 * 2.5), chop.output.slice()[0].n, 1e-4);
    lose(&w, e, &cat, "hand_axe"); // back to the hatchet's rank, modifiers kept
    const again = verbOf(&w, e, &cat, "chop_wood").?;
    try testing.expectEqual(with_hatchet.requires.energy, again.requires.energy);
    try expectLines(&with_hatchet.output, &again.output);
    lose(&w, e, &cat, "hatchet"); // the verb leaves with the last tool
    try testing.expect(verbOf(&w, e, &cat, "chop_wood") == null);
}

test "fifty rod → net → sell → sell cycles leave the fishing terms bit-exact" {
    var cat = try fixture();
    defer cat.deinit();
    var w = World.init();
    const e = spawnAgent(&w);
    own(&w, e, &cat, "fish_rod");
    const rod = verbOf(&w, e, &cat, "fish").?;
    own(&w, e, &cat, "fish_net");
    try testing.expect(verbOf(&w, e, &cat, "fish").?.output.slice()[0].n != rod.output.slice()[0].n);
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
    try testing.expectEqual(rod.requires.energy, after.requires.energy);
    try expectLines(&rod.output, &after.output);
}

test "the body and larder: ceilings fill on the way up and clamp on the way down" {
    var cat = try fixture();
    defer cat.deinit();
    var w = World.init();
    const e = spawnAgent(&w);
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
    try testing.expectApproxEqAbs(@as(f32, 0.025), w.get(e, comp.InventoryFood).?.spoils, 1e-7);
    lose(&w, e, &cat, "root_cellar");
    lose(&w, e, &cat, "cookpot");
    try testing.expectEqual(@as(u8, 1), w.get(e, comp.InventoryFood).?.quality);
    try testing.expectApproxEqAbs(@as(f32, 0.05), w.get(e, comp.InventoryFood).?.spoils, 1e-7);
}

test "a scale on an absent line is nothing to scale; an add inserts the line" {
    var cat = try fixture();
    defer cat.deinit();
    var v = Verb{
        .requires = .{ .energy = 1, .hours = 1 },
        .input = .{},
        .output = Lines.of(&.{.{ .item = "food", .n = 2, .kind = .normal, .sd = 0.5 }}),
    };
    tweak(&v, .{ .target = "x", .stat = .{ .output = "biomass" }, .by = 3 }, .scale);
    try testing.expectEqual(@as(u8, 1), v.output.len);
    tweak(&v, .{ .target = "x", .stat = .{ .output = "food" }, .by = 3 }, .scale);
    try testing.expectEqual(@as(f32, 6), v.output.items[0].n);
    try testing.expectEqual(@as(f32, 1.5), v.output.items[0].sd); // shape preserved
    tweak(&v, .{ .target = "x", .stat = .{ .input = "biomass" }, .by = 1 }, .add);
    try testing.expectEqual(@as(u8, 1), v.input.len);
    try testing.expectEqual(@as(f32, 1), v.input.items[0].n);
    try testing.expectEqual(ha.dist.Kind.fixed, v.input.items[0].kind);
}
