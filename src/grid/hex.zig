//! `grid/hex` — the **pure** pointy-top axial hex math for the Act II STRUCTURE board.
//!
//! This module is deliberately free of UI, render, ECS, and SDL imports. It uses `std` plus the
//! roster's `Resource` naming cover so board wedge codes cannot drift from the rest of Act II.
//! The board's geometry lives here as plain functions on plain coordinate types so it can be unit-tested without a
//! renderer or a clock, and so the rendering layer reads positions from it rather than
//! re-deriving them. Screen placement is a one-way transform *out* of this module; nothing
//! flows back in. Classification is done from exact axial coordinates, never from a rounded
//! screen angle — floating-point angle thresholds introduce avoidable boundary ambiguity, so
//! the pure path compares integer coordinates instead.
//!
//! Conventions (from `docs/hex_tech_board_spec.md` §1–§3):
//!   - Orientation: pointy-top (a vertex points up).
//!   - Coordinates: axial `(q, r)`, hub at `(0, 0)`.
//!   - Ring of a hex: `max(|q|, |r|, |q + r|)`.
//!   - Wedge order, clockwise from 3 o'clock: Food, Water, Fuel, Metal, Minerals, Biomass.
//!   - Pointy-top axial → pixel for hex size `s` (center→vertex) and board center `(cx, cy)`:
//!       `x = cx + sqrt(3) * s * (q + r / 2)`
//!       `y = cy + 1.5 * s * r`

const std = @import("std");
const roster = @import("../roster.zig");

// ============================ Coordinate types =============================

/// Axial hex coordinate `(q, r)`. The hub is `.{ .q = 0, .r = 0 }`. Integer by design: all
/// classification compares exact axial coordinates, so the board carries no float drift.
pub const Axial = struct {
    q: i32,
    r: i32,

    pub fn eql(a: Axial, b: Axial) bool {
        return a.q == b.q and a.r == b.r;
    }

    pub fn add(a: Axial, b: Axial) Axial {
        return .{ .q = a.q + b.q, .r = a.r + b.r };
    }

    pub fn sub(a: Axial, b: Axial) Axial {
        return .{ .q = a.q - b.q, .r = a.r - b.r };
    }

    pub fn scale(a: Axial, k: i32) Axial {
        return .{ .q = a.q * k, .r = a.r * k };
    }

    /// Convert to cube coordinates `(x, y, z)` with the invariant `x + y + z == 0`.
    pub fn toCube(a: Axial) Cube {
        return .{ .x = a.q, .z = a.r, .y = -a.q - a.r };
    }
};

/// Cube hex coordinate with the invariant `x + y + z == 0`. Useful for distance and the
/// symmetric neighbor/ring algebra; `Axial` is the storage form, `Cube` the working form.
pub const Cube = struct {
    x: i32,
    y: i32,
    z: i32,

    pub fn toAxial(c: Cube) Axial {
        return .{ .q = c.x, .r = c.z };
    }

    /// Whether the cube invariant holds. A valid cube hex always sums to zero.
    pub fn valid(c: Cube) bool {
        return c.x + c.y + c.z == 0;
    }
};

/// A point in screen (pixel) space produced by `toPixel`. Floats only cross *out* of the
/// pure layer here — never back in.
pub const Point = struct { x: f32, y: f32 };

// ============================ Wedges =============================

/// The six resource families, in the fixed clockwise screen order starting at 3 o'clock:
/// Food, Water, Fuel, Metal, Minerals, Biomass. This ordinal order is load-bearing — every
/// adjacent pair forms a hybrid domain, so it must not be reordered. The enum is a pure
/// identity (an index into §2's table); the UI maps it to a palette hue, not this module.
pub const Wedge = enum(u3) {
    food = 0,
    water = 1,
    fuel = 2,
    metal = 3,
    minerals = 4,
    biomass = 5,

    /// The two-letter stable code from §2 (`FO`, `WA`, `FU`, `ME`, `MI`, `BI`). Single
    /// initials would make Food/Fuel and Metal/Minerals ambiguous.
    pub fn code(w: Wedge) []const u8 {
        const resource: roster.Resource = switch (w) {
            .food => .food,
            .water => .water,
            .fuel => .fuel,
            .metal => .metal,
            .minerals => .minerals,
            .biomass => .biomass,
        };
        return resource.abbrevIn(2);
    }

    /// The next wedge clockwise (mod 6) — the partner that closes a hybrid edge.
    pub fn next(w: Wedge) Wedge {
        return @fromBackingInt(@intCast((@backingInt(w) + 1) % 6));
    }

    /// The previous wedge clockwise (mod 6).
    pub fn prev(w: Wedge) Wedge {
        return @fromBackingInt(@intCast((@backingInt(w) + 5) % 6));
    }
};

/// The six wedge direction vectors in order, indexed by `@backingInt(Wedge)`. A pure corner
/// hex at ring `n` for wedge `w` is `dir[w] * n`. These are the §2 direction vectors.
pub const directions = [6]Axial{
    .{ .q = 1, .r = 0 }, // 0 Food     — 0°   (right)
    .{ .q = 0, .r = 1 }, // 1 Water    — 60°  (lower right)
    .{ .q = -1, .r = 1 }, // 2 Fuel     — 120° (lower left)
    .{ .q = -1, .r = 0 }, // 3 Metal    — 180° (left)
    .{ .q = 0, .r = -1 }, // 4 Minerals — 240° (upper left)
    .{ .q = 1, .r = -1 }, // 5 Biomass  — 300° (upper right)
};

/// The direction vector for a wedge.
pub fn dir(w: Wedge) Axial {
    return directions[@backingInt(w)];
}

// ============================ Distance / ring =============================

/// The ring of a hex: `max(|q|, |r|, |q + r|)`. Ring 0 is the hub; ring `n` holds `6n` hexes.
pub fn ring(a: Axial) u32 {
    const aq: u32 = @abs(a.q);
    const ar: u32 = @abs(a.r);
    const as: u32 = @abs(a.q + a.r);
    return @max(aq, @max(ar, as));
}

/// Hex (ring) distance between two hexes — the number of steps on the grid, i.e. the ring of
/// their difference. Equivalently `(|dx| + |dy| + |dz|) / 2` in cube space.
pub fn distance(a: Axial, b: Axial) u32 {
    return ring(a.sub(b));
}

/// The count of hexes on a given ring: ring 0 = 1, ring `n` = `6n`.
pub fn ringCount(n: u32) u32 {
    return if (n == 0) 1 else 6 * n;
}

// ============================ Neighbors =============================

/// The six neighbor direction vectors, in clockwise screen order. They coincide with the
/// wedge directions (each wedge points at a ring-1 neighbor), so a step toward a wedge and a
/// neighbor step are the same vector.
pub const neighbor_dirs = directions;

/// The neighbor of `a` in neighbor-direction index `i` (0..5, clockwise from the Food
/// direction). Indices wrap mod 6.
pub fn neighbor(a: Axial, i: u32) Axial {
    return a.add(neighbor_dirs[i % 6]);
}

/// Fill `out` with the six neighbors of `a` in clockwise order and return the slice. `out`
/// must have room for 6; the function writes exactly 6.
pub fn neighbors(a: Axial, out: []Axial) []Axial {
    std.debug.assert(out.len >= 6);
    for (0..6) |i| out[i] = a.add(neighbor_dirs[i]);
    return out[0..6];
}

// ============================ Ring enumeration =============================

/// Append every hex on `n`'s ring to `list`, in a stable clockwise order starting at the
/// Food corner. Ring 0 appends only the hub. The order is deterministic so a caller can index
/// tiles by position within a ring without re-sorting.
///
/// Walk: start at `dir(.food) * n` (the Food corner), then for each of the six edges step `n`
/// times along the direction of the wedge two positions ahead — the standard cube-ring walk,
/// adapted to this wedge order so corners land exactly on `dir[w] * n`.
pub fn ringHexes(gpa: std.mem.Allocator, n: u32, list: *std.ArrayList(Axial)) !void {
    if (n == 0) {
        try list.append(gpa, .{ .q = 0, .r = 0 });
        return;
    }
    const ni: i32 = @intCast(n);
    // Start at the Food corner, then traverse the six edges. The edge that departs corner
    // `w` toward corner `w+1` moves along `dir(w+2)` (the ring-walk edge vector), so stepping
    // `n` times reaches the next corner exactly.
    var cur = dir(.food).scale(ni);
    for (0..6) |w| {
        const step_dir = directions[(w + 2) % 6];
        for (0..n) |_| {
            try list.append(gpa, cur);
            cur = cur.add(step_dir);
        }
    }
}

/// Append every hex at ring `0..=max_ring` inclusive, hub first, each ring in `ringHexes`
/// order. The complete Act II board is `ringHexes(0..4)` → 61 logical hexes.
pub fn disk(gpa: std.mem.Allocator, max_ring: u32, list: *std.ArrayList(Axial)) !void {
    var n: u32 = 0;
    while (n <= max_ring) : (n += 1) try ringHexes(gpa, n, list);
}

// ============================ Classification =============================

/// Pure/hybrid classification of a ring hex (§3). Ring 0 is `.foundation`. A ring-`n ≥ 1`
/// hex is either a `.pure` corner owned by one wedge, or a `.hybrid` edge between two adjacent
/// wedges with a position index `k` (`1..n-1`). `k` small leans toward `wedge`; `k` large
/// leans toward `wedge.next()`.
pub const Kind = union(enum) {
    /// Ring 0 — the neutral foundation; no resource identity.
    foundation,
    /// A corner hex `dir(wedge) * n`: belongs to the single `wedge`.
    pure: struct { wedge: Wedge },
    /// An edge hex between `wedge` and `wedge.next()`, at position `k` (`1..n-1`).
    hybrid: struct { wedge: Wedge, k: u32 },
};

/// Classify a hex from its exact axial coordinates. Compares against the six corner equations
/// first; otherwise solves the unique `(w, k)` edge equation. Never rounds a screen angle.
///
/// Edge equation (§3): `pos = n * dir[w] + k * (dir[w+1] - dir[w])`, for `k = 1..n-1`.
pub fn classify(a: Axial) Kind {
    const n = ring(a);
    if (n == 0) return .foundation;
    const ni: i32 = @intCast(n);

    // Corners first: a pure hex is exactly `dir[w] * n` for one wedge.
    for (0..6) |w| {
        const corner = directions[w].scale(ni);
        if (a.eql(corner)) return .{ .pure = .{ .wedge = @fromBackingInt(@intCast(w)) } };
    }

    // Otherwise it is an edge hex. Find the wedge `w` whose edge toward `w+1` contains it.
    // Along that edge, `pos = corner_w + k * (dir[w+1] - dir[w])`, so solve for integer `k`
    // in `1..n-1` and verify the full vector matches (guards against a false single-axis fit).
    for (0..6) |w| {
        const w_next = (w + 1) % 6;
        const corner_w = directions[w].scale(ni);
        const edge_vec = directions[w_next].sub(directions[w]);
        const delta = a.sub(corner_w);
        if (solveK(delta, edge_vec)) |k| {
            if (k >= 1 and k <= n - 1) {
                // Verify both axes reconstruct the coordinate exactly.
                const reconstructed = corner_w.add(edge_vec.scale(@intCast(k)));
                if (a.eql(reconstructed))
                    return .{ .hybrid = .{ .wedge = @fromBackingInt(@intCast(w)), .k = k } };
            }
        }
    }

    unreachable; // every ring-`n≥1` hex is a corner or an edge of exactly one wedge
}

/// Solve `delta == k * edge_vec` for a non-negative integer `k`, or `null` if there is no such
/// integer. Uses whichever axis of `edge_vec` is non-zero and checks the quotient is exact and
/// consistent across both axes.
fn solveK(delta: Axial, edge_vec: Axial) ?u32 {
    // Prefer a non-zero divisor axis.
    if (edge_vec.q != 0) {
        if (@rem(delta.q, edge_vec.q) != 0) return null;
        const k = @divExact(delta.q, edge_vec.q);
        if (k < 0) return null;
        // Consistency on the other axis.
        if (delta.r != k * edge_vec.r) return null;
        return @intCast(k);
    }
    if (edge_vec.r != 0) {
        if (@rem(delta.r, edge_vec.r) != 0) return null;
        const k = @divExact(delta.r, edge_vec.r);
        if (k < 0) return null;
        if (delta.q != k * edge_vec.q) return null;
        return @intCast(k);
    }
    return null; // zero edge vector — not a real edge
}

// ============================ Pixel transform =============================

/// Pointy-top axial → pixel for hex size `s` (center→vertex) and board center `(cx, cy)`:
///   `x = cx + sqrt(3) * s * (q + r / 2)`
///   `y = cy + 1.5 * s * r`
/// One-way out of the pure layer: the renderer reads this; nothing flows back in.
pub fn toPixel(a: Axial, s: f32, cx: f32, cy: f32) Point {
    const q: f32 = @floatFromInt(a.q);
    const r: f32 = @floatFromInt(a.r);
    const sqrt3 = std.math.sqrt(3.0);
    return .{
        .x = cx + sqrt3 * s * (q + r / 2.0),
        .y = cy + 1.5 * s * r,
    };
}

/// The six pointy-top vertex offsets (from a hex center) at radius `s`, at angles
/// `-30°, 30°, 90°, 150°, 210°, 270°` (§1). Returns offsets in screen space (`y` down). A
/// caller adds a center `Point` to each to draw the polygon; draw ordinary tiles at radius
/// `s - 1.5` to leave a visible gap between neighbors.
pub fn vertexOffsets(s: f32) [6]Point {
    var out: [6]Point = undefined;
    // Pointy-top: first vertex at -30°, stepping 60°. Screen y is down.
    const angles = [6]f32{ -30, 30, 90, 150, 210, 270 };
    for (angles, 0..) |deg, i| {
        const rad = deg * std.math.pi / 180.0;
        out[i] = .{ .x = s * std.math.cos(rad), .y = s * std.math.sin(rad) };
    }
    return out;
}

// ============================ Tests =============================

const testing = std.testing;

test "ring: hub is 0, the six wedge directions are ring 1, outer corners scale" {
    try testing.expectEqual(@as(u32, 0), ring(.{ .q = 0, .r = 0 }));
    for (directions) |d| try testing.expectEqual(@as(u32, 1), ring(d));
    try testing.expectEqual(@as(u32, 4), ring(.{ .q = 4, .r = 0 }));
    try testing.expectEqual(@as(u32, 4), ring(.{ .q = -4, .r = 4 }));
    try testing.expectEqual(@as(u32, 3), ring(.{ .q = 1, .r = 2 })); // |q+r| = 3 dominates
}

test "ringCount: 1, 6, 12, 18, 24" {
    try testing.expectEqual(@as(u32, 1), ringCount(0));
    try testing.expectEqual(@as(u32, 6), ringCount(1));
    try testing.expectEqual(@as(u32, 12), ringCount(2));
    try testing.expectEqual(@as(u32, 18), ringCount(3));
    try testing.expectEqual(@as(u32, 24), ringCount(4));
}

test "cube: axial↔cube round-trips and keeps the x+y+z==0 invariant" {
    const samples = [_]Axial{
        .{ .q = 0, .r = 0 }, .{ .q = 1, .r = 0 }, .{ .q = -2, .r = 3 }, .{ .q = 4, .r = -4 },
    };
    for (samples) |a| {
        const c = a.toCube();
        try testing.expect(c.valid());
        try testing.expect(a.eql(c.toAxial()));
    }
}

test "distance: equals the ring of the difference" {
    try testing.expectEqual(@as(u32, 0), distance(.{ .q = 2, .r = -1 }, .{ .q = 2, .r = -1 }));
    try testing.expectEqual(@as(u32, 1), distance(.{ .q = 0, .r = 0 }, .{ .q = 1, .r = 0 }));
    try testing.expectEqual(@as(u32, 4), distance(.{ .q = 0, .r = 0 }, .{ .q = -4, .r = 4 }));
    // Symmetric.
    const a = Axial{ .q = 2, .r = -3 };
    const b = Axial{ .q = -1, .r = 2 };
    try testing.expectEqual(distance(a, b), distance(b, a));
}

test "neighbors: six distinct ring-1 steps, each at distance 1" {
    const origin = Axial{ .q = 0, .r = 0 };
    var buf: [6]Axial = undefined;
    const ns = neighbors(origin, &buf);
    try testing.expectEqual(@as(usize, 6), ns.len);
    for (ns) |nb| try testing.expectEqual(@as(u32, 1), distance(origin, nb));
    // All distinct.
    for (0..6) |i| for (i + 1..6) |j| try testing.expect(!ns[i].eql(ns[j]));
}

test "ringHexes: ring n has exactly 6n hexes, each on ring n, all distinct" {
    for (0..5) |n| {
        var list: std.ArrayList(Axial) = .empty;
        defer list.deinit(testing.allocator);
        try ringHexes(testing.allocator, @intCast(n), &list);
        try testing.expectEqual(ringCount(@intCast(n)), @as(u32, @intCast(list.items.len)));
        for (list.items) |h| try testing.expectEqual(@as(u32, @intCast(n)), ring(h));
        for (0..list.items.len) |i| for (i + 1..list.items.len) |j|
            try testing.expect(!list.items[i].eql(list.items[j]));
    }
}

test "disk: rings 0..4 total exactly 61 logical hexes, all distinct" {
    var list: std.ArrayList(Axial) = .empty;
    defer list.deinit(testing.allocator);
    try disk(testing.allocator, 4, &list);
    try testing.expectEqual(@as(usize, 61), list.items.len);
    for (0..list.items.len) |i| for (i + 1..list.items.len) |j|
        try testing.expect(!list.items[i].eql(list.items[j]));
}

test "classify: ring 0 is the foundation" {
    try testing.expectEqual(Kind.foundation, classify(.{ .q = 0, .r = 0 }));
}

test "classify: the six ring-1 corners are pure, one per wedge in order" {
    inline for (0..6) |w| {
        const wedge: Wedge = @fromBackingInt(@intCast(w));
        const k = classify(dir(wedge));
        try testing.expect(k == .pure);
        try testing.expectEqual(wedge, k.pure.wedge);
    }
}

test "classify: outer corners stay pure at their wedge" {
    // Metal corner at ring 3 is (-3, 0).
    const k = classify(.{ .q = -3, .r = 0 });
    try testing.expect(k == .pure);
    try testing.expectEqual(Wedge.metal, k.pure.wedge);
}

test "classify: ring-2 hybrids sit between adjacent wedges at k=1" {
    // (1,1) is the Food–Water edge hybrid (ring 2).
    const k = classify(.{ .q = 1, .r = 1 });
    try testing.expect(k == .hybrid);
    try testing.expectEqual(Wedge.food, k.hybrid.wedge);
    try testing.expectEqual(@as(u32, 1), k.hybrid.k);
}

test "classify: ring-3 Food–Water edge distinguishes k=1 and k=2 by lean" {
    // Per spec §10 ring 3: (2,1) is Food–Water k=1, (1,2) is Food–Water k=2.
    const a = classify(.{ .q = 2, .r = 1 });
    try testing.expect(a == .hybrid);
    try testing.expectEqual(Wedge.food, a.hybrid.wedge);
    try testing.expectEqual(@as(u32, 1), a.hybrid.k);

    const b = classify(.{ .q = 1, .r = 2 });
    try testing.expect(b == .hybrid);
    try testing.expectEqual(Wedge.food, b.hybrid.wedge);
    try testing.expectEqual(@as(u32, 2), b.hybrid.k);
}

test "classify: every ring-n hex is 6 pure corners + 6(n-1) hybrids" {
    for (1..5) |n| {
        var list: std.ArrayList(Axial) = .empty;
        defer list.deinit(testing.allocator);
        try ringHexes(testing.allocator, @intCast(n), &list);
        var pures: u32 = 0;
        var hybrids: u32 = 0;
        for (list.items) |h| switch (classify(h)) {
            .foundation => try testing.expect(false),
            .pure => pures += 1,
            .hybrid => hybrids += 1,
        };
        try testing.expectEqual(@as(u32, 6), pures);
        try testing.expectEqual(@as(u32, @intCast(6 * (n - 1))), hybrids);
    }
}

test "toPixel: the hub lands on the board center; +q steps right by sqrt(3)*s" {
    const p0 = toPixel(.{ .q = 0, .r = 0 }, 10, 100, 100);
    try testing.expectApproxEqAbs(@as(f32, 100), p0.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 100), p0.y, 1e-4);
    const p1 = toPixel(.{ .q = 1, .r = 0 }, 10, 100, 100);
    try testing.expectApproxEqAbs(@as(f32, 100 + std.math.sqrt(3.0) * 10), p1.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 100), p1.y, 1e-4);
    // +r steps down by 1.5*s and right by half a column.
    const p2 = toPixel(.{ .q = 0, .r = 1 }, 10, 100, 100);
    try testing.expectApproxEqAbs(@as(f32, 100 + 1.5 * 10), p2.y, 1e-4);
}

test "vertexOffsets: six vertices at radius s, pointy-top (a vertex points up)" {
    const vs = vertexOffsets(10);
    for (vs) |v| {
        const radius = std.math.sqrt(v.x * v.x + v.y * v.y);
        try testing.expectApproxEqAbs(@as(f32, 10), radius, 1e-4);
    }
    // The 270° vertex points straight up (screen y negative).
    try testing.expectApproxEqAbs(@as(f32, 0), vs[5].x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, -10), vs[5].y, 1e-4);
}

test "Wedge: code, next, prev wrap in the fixed clockwise order" {
    try testing.expectEqualStrings("FO", Wedge.food.code());
    try testing.expectEqualStrings("MI", Wedge.minerals.code());
    try testing.expectEqual(Wedge.water, Wedge.food.next());
    try testing.expectEqual(Wedge.food, Wedge.biomass.next()); // wrap
    try testing.expectEqual(Wedge.biomass, Wedge.food.prev()); // wrap
}
