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
// The interpreter is held equal to the typed apply/remove pairs in `capital.zig`, verb by
// verb and number by number, across single goods, stacks, family cycles and a long
// build → sell → build loop. These tests are what lets the typed path be deleted.

const testing = std.testing;
const capital = ha.capital;
const Resources = ha.res.Resources;

fn fixture() !Catalog {
    return roster.load(testing.allocator, roster.shipped, null);
}

fn test_res() Resources {
    var res: Resources = undefined;
    res.sim = .{ .prng = std.Random.DefaultPrng.init(11) };
    res.config = .{};
    return res;
}

/// Two agents with the same body and larder: one on the typed roster, one on the data.
const Pair = struct {
    typed: Entity,
    data: Entity,

    fn spawn(w: *World) Pair {
        return .{
            .typed = w.spawn(.{ comp.Vigor{}, comp.InventoryFood{}, comp.InventoryMaterial{} } ++ ha.actions.actions_bundle),
            .data = w.spawn(.{ comp.Vigor{}, comp.InventoryFood{}, comp.InventoryMaterial{}, comp.Goods{}, comp.Granted{} }),
        };
    }

    /// Own one more of `G` on both sides — the typed side through the build path's
    /// on-the-way-in grant, the data side by count.
    fn equip(self: Pair, w: *World, cat: *const Catalog, comptime G: type) void {
        if (w.get(self.typed, G)) |h| {
            h.count += 1;
        } else {
            w.add(self.typed, G{});
            capital.grant_public(w, self.typed, G);
        }
        w.get(self.data, comp.Goods).?.count[cat.goodIndex(ha.bridge.goodIdOf(G)).?] += 1;
        apply(w, self.data, cat);
    }

    /// Lose one of `G` on both sides — the typed side through the reference revoke, spares
    /// first, the data side by count.
    fn drop(self: Pair, w: *World, res: *Resources, cat: *const Catalog, comptime G: type) void {
        _ = res;
        const owned = w.get(self.typed, G).?;
        if (owned.count > 1) owned.count -= 1 else capital.revoke_public(w, self.typed, G);
        w.get(self.data, comp.Goods).?.count[cat.goodIndex(ha.bridge.goodIdOf(G)).?] -= 1;
        apply(w, self.data, cat);
    }
};

fn expectNear(expected: f32, actual: f32, tol: f32) !void {
    if (tol == 0) return testing.expectEqual(expected, actual);
    return testing.expectApproxEqAbs(expected, actual, tol);
}

fn expectQty(side: *const Lines, item: []const u8, qty: f32, tol: f32) !void {
    var s = side.*;
    const l = s.find(item, .once);
    if (qty == 0) {
        if (l) |found| try expectNear(0, found.n, tol) else {}
        return;
    }
    try expectNear(qty, (l orelse return error.MissingLine).n, tol);
}

fn expectDist(side: *const Lines, item: []const u8, d: ha.dist.Dist, tol: f32) !void {
    var s = side.*;
    const l = s.find(item, .once);
    if (d.kind == .fixed and d.s == 0) {
        try testing.expect(l == null);
        return;
    }
    const found = l orelse return error.MissingLine;
    try testing.expectEqual(d.kind, found.kind);
    try expectNear(d.s, found.n, tol);
    try expectNear(d.sd, found.sd, tol);
}

/// Every verb, and the body and larder, equal between the two sides. `tol` is 0 where the
/// two paths multiply in the same order (bit-exact) and small where they do not.
fn expectSame(w: *World, p: Pair, cat: *const Catalog, tol: f32) !void {
    const goods = w.get(p.data, comp.Goods).?;
    inline for (ha.bridge.typed_actions) |pair| {
        const ai = cat.actionIndex(pair[0]).?;
        const v = verb(cat, goods, ai);
        if (w.get(p.typed, pair[1])) |typed| {
            const d = v orelse return error.VerbMissing;
            try expectNear(typed.requires.energy, d.requires.energy, tol);
            try expectNear(typed.requires.hours, d.requires.hours, tol);
            try expectQty(&d.input, "materials", typed.requires.materials, tol);
            try expectDist(&d.output, "food", typed.yields.food, tol);
            try expectDist(&d.output, "materials", typed.yields.materials, tol);
        } else {
            try testing.expect(v == null);
        }
    }
    const tv = w.get(p.typed, comp.Vigor).?;
    const dv = w.get(p.data, comp.Vigor).?;
    try testing.expectEqual(tv.max, dv.max);
    try testing.expectEqual(tv.v, dv.v);
    const tf = w.get(p.typed, comp.InventoryFood).?;
    const df = w.get(p.data, comp.InventoryFood).?;
    try testing.expectEqual(tf.quality, df.quality);
    try expectNear(tf.spoils, df.spoils, 1e-7);
}

test "with nothing owned, the innate verbs are the base records and nothing else is held" {
    var cat = try fixture();
    defer cat.deinit();
    var w = World.init();
    const p = Pair.spawn(&w);
    try expectSame(&w, p, &cat, 0);
    const goods = w.get(p.data, comp.Goods).?;
    try testing.expect(held(&cat, goods, cat.actionIndex("forage").?));
    try testing.expect(!held(&cat, goods, cat.actionIndex("fish").?));
}

test "each good alone: equip and drop match the typed grant and revoke, bit for bit" {
    var cat = try fixture();
    defer cat.deinit();
    var res = test_res();
    // One world, re-initialized per good inside a call of its own: an unrolled loop keeps a
    // world-sized temporary per iteration in the test's frame and overflows the stack.
    var w = World.init();
    inline for (ha.bridge.typed_goods) |pair| try checkAlone(pair[1], &w, &res, &cat);
}

fn checkAlone(comptime G: type, w: *World, res: *Resources, cat: *const Catalog) !void {
    w.* = World.init();
    const p = Pair.spawn(w);
    // Start under the ceiling so a fill on equip is observable.
    w.get(p.typed, comp.Vigor).?.v = 7;
    w.get(p.data, comp.Vigor).?.v = 7;
    // A modifier on Split wood needs the hatchet first — on both sides.
    if (G == comp.WorkGloves or G == comp.Chainsaw) p.equip(w, cat, comp.Hatchet);
    p.equip(w, cat, G);
    try expectSame(w, p, cat, 0);
    p.drop(w, res, cat, G);
    try expectSame(w, p, cat, 0);
}

test "goods on one verb stack; a spare carries no second effect" {
    var cat = try fixture();
    defer cat.deinit();
    var res = test_res();
    var w = World.init();
    const p = Pair.spawn(&w);
    p.equip(&w, &cat, comp.Sandals);
    p.equip(&w, &cat, comp.Bicycle);
    try expectSame(&w, p, &cat, 0);
    p.equip(&w, &cat, comp.Sandals); // a second pair is stock
    try expectSame(&w, p, &cat, 0);
    try testing.expectApproxEqAbs(
        @as(f32, 1.7 * 0.85 * 0.6),
        verb(&cat, w.get(p.data, comp.Goods).?, cat.actionIndex("forage").?).?.requires.energy,
        1e-5,
    );
    p.drop(&w, &res, &cat, comp.Sandals); // the spare goes first, the discount stays
    try expectSame(&w, p, &cat, 0);
    p.drop(&w, &res, &cat, comp.Bicycle);
    p.drop(&w, &res, &cat, comp.Sandals);
    try expectSame(&w, p, &cat, 0);
}

test "the chopping stack: hatchet, gloves, chainsaw, then the hand axe supersedes the hatchet" {
    var cat = try fixture();
    defer cat.deinit();
    var res = test_res();
    var w = World.init();
    const p = Pair.spawn(&w);
    p.equip(&w, &cat, comp.Hatchet);
    p.equip(&w, &cat, comp.WorkGloves);
    p.equip(&w, &cat, comp.Chainsaw);
    try expectSame(&w, p, &cat, 0); // same multiplication order on both sides
    p.equip(&w, &cat, comp.HandAxe); // the typed side recomputes base → rank 2 → modifiers
    try expectSame(&w, p, &cat, 1e-5); // the data side folds in roster order
    const goods = w.get(p.data, comp.Goods).?;
    const chop = verb(&cat, goods, cat.actionIndex("chop_wood").?).?;
    try testing.expectApproxEqAbs(@as(f32, 2.5 * 0.7 * 0.75 * 0.3), chop.requires.energy, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 5.0 * 1.4 * 2.5), chop.output.slice()[0].n, 1e-4);
    p.drop(&w, &res, &cat, comp.HandAxe); // back to the hatchet's rank, modifiers kept
    try expectSame(&w, p, &cat, 1e-5);
    p.drop(&w, &res, &cat, comp.Hatchet); // the verb leaves with the last tool
    try expectSame(&w, p, &cat, 0);
    try testing.expect(verb(&cat, goods, cat.actionIndex("chop_wood").?) == null);
}

test "the fishing family: rod, net, sell the net, sell the rod" {
    var cat = try fixture();
    defer cat.deinit();
    var res = test_res();
    var w = World.init();
    const p = Pair.spawn(&w);
    p.equip(&w, &cat, comp.FishRod);
    try expectSame(&w, p, &cat, 0);
    p.equip(&w, &cat, comp.FishNet);
    try expectSame(&w, p, &cat, 0);
    p.drop(&w, &res, &cat, comp.FishNet);
    try expectSame(&w, p, &cat, 0);
    p.drop(&w, &res, &cat, comp.FishRod);
    try expectSame(&w, p, &cat, 0);
}

test "fifty build → upgrade → sell → sell cycles leave the base untouched" {
    var cat = try fixture();
    defer cat.deinit();
    var res = test_res();
    var w = World.init();
    const p = Pair.spawn(&w);
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        p.equip(&w, &cat, comp.FishRod);
        p.equip(&w, &cat, comp.FishNet);
        p.drop(&w, &res, &cat, comp.FishNet);
        p.drop(&w, &res, &cat, comp.FishRod);
    }
    p.equip(&w, &cat, comp.FishRod);
    try expectSame(&w, p, &cat, 0);
    const fish = verb(&cat, w.get(p.data, comp.Goods).?, cat.actionIndex("fish").?).?;
    try testing.expectEqual((comp.ActionFish{}).requires.energy, fish.requires.energy);
}

test "the body and larder: ceilings fill on the way up and clamp on the way down" {
    var cat = try fixture();
    defer cat.deinit();
    var res = test_res();
    var w = World.init();
    const p = Pair.spawn(&w);
    w.get(p.typed, comp.Vigor).?.v = 8;
    w.get(p.data, comp.Vigor).?.v = 8;
    p.equip(&w, &cat, comp.LeafBed); // max 11, v 9
    try expectSame(&w, p, &cat, 0);
    p.equip(&w, &cat, comp.Pantry); // max 13, v 11
    try expectSame(&w, p, &cat, 0);
    try testing.expectEqual(@as(f32, 13), w.get(p.data, comp.Vigor).?.max);
    try testing.expectEqual(@as(f32, 11), w.get(p.data, comp.Vigor).?.v);
    w.get(p.typed, comp.Vigor).?.v = 13;
    w.get(p.data, comp.Vigor).?.v = 13;
    p.drop(&w, &res, &cat, comp.Pantry); // max 11, v clamped to 11
    try expectSame(&w, p, &cat, 0);
    p.drop(&w, &res, &cat, comp.LeafBed); // max 10, v clamped to 10
    try expectSame(&w, p, &cat, 0);
    try testing.expectEqual(@as(f32, 10), w.get(p.data, comp.Vigor).?.v);

    p.equip(&w, &cat, comp.Cookpot);
    p.equip(&w, &cat, comp.RootCellar);
    try expectSame(&w, p, &cat, 0);
    try testing.expectEqual(@as(u8, 2), w.get(p.data, comp.InventoryFood).?.quality);
    try testing.expectApproxEqAbs(@as(f32, 0.025), w.get(p.data, comp.InventoryFood).?.spoils, 1e-7);
    p.drop(&w, &res, &cat, comp.RootCellar);
    p.drop(&w, &res, &cat, comp.Cookpot);
    try expectSame(&w, p, &cat, 0);
}

test "a scale on an absent line is nothing to scale; an add inserts the line" {
    var cat = try fixture();
    defer cat.deinit();
    var v = Verb{
        .requires = .{ .energy = 1, .hours = 1 },
        .input = .{},
        .output = Lines.of(&.{.{ .item = "food", .n = 2, .kind = .normal, .sd = 0.5 }}),
    };
    tweak(&v, .{ .target = "x", .stat = .{ .output = "materials" }, .by = 3 }, .scale);
    try testing.expectEqual(@as(u8, 1), v.output.len);
    tweak(&v, .{ .target = "x", .stat = .{ .output = "food" }, .by = 3 }, .scale);
    try testing.expectEqual(@as(f32, 6), v.output.items[0].n);
    try testing.expectEqual(@as(f32, 1.5), v.output.items[0].sd); // shape preserved
    tweak(&v, .{ .target = "x", .stat = .{ .input = "materials" }, .by = 1 }, .add);
    try testing.expectEqual(@as(u8, 1), v.input.len);
    try testing.expectEqual(@as(f32, 1), v.input.items[0].n);
    try testing.expectEqual(ha.dist.Kind.fixed, v.input.items[0].kind);
}
