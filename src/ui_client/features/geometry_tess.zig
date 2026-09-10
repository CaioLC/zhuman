//! `geometry_tess` — the **pure, SDL-free tessellation** behind the `geometry` feature
//! (RENDER-03). It turns high-level shapes (a convex polygon, a thick polyline) into an
//! indexed triangle mesh: a flat vertex list plus `u16` indices, three per triangle. It
//! touches no SDL, no allocator, and no I/O — the caller hands it fixed-capacity slices and
//! it reports overflow rather than allocating — so the geometry math (fan triangulation,
//! miter joins, caps) is unit-tested deterministically without a graphics context, the same
//! discipline `wrap.zig` uses for line breaking.
//!
//! **Coordinates are the caller's.** The routines are unit-agnostic: `features/geometry.zig`
//! feeds them **node-local unit-square** points (0..1 on each axis, like `line.zig`) so a
//! shape survives resize/zoom, and maps the emitted vertices to device px at draw. Tests
//! feed whatever coordinates make the assertion clearest. Color is a plain rgba byte quad
//! here (the feature converts to SDL's float `FColor` at draw), keeping this module free of
//! the host `Color`/SDL types.
//!
//! **Why indexed triangles:** SDL's `renderGeometry` takes a vertex array + optional index
//! array, drawing one triangle per index triple. A convex polygon fan and a polyline strip
//! both reuse shared vertices, so indices keep the vertex count minimal and are the shape
//! the feature forwards directly.

const std = @import("std");

/// A 2D point in the caller's coordinate space (unit-square local for the feature).
pub const V2 = struct { x: f32, y: f32 };

/// An rgba color as bytes (0..255) — the host `Color`'s shape without importing SDL. The
/// feature converts this to SDL's float `FColor` at draw; per-vertex color is what lets one
/// mesh carry a gradient (RENDER-04's seam) or a multi-hue rail.
pub const Rgba = struct { r: u8, g: u8, b: u8, a: u8 };

/// One mesh vertex: a position plus its own color. `renderGeometry` interpolates the colors
/// across each triangle, so a fill with equal vertex colors is flat and unequal ones ramp.
pub const Vertex = struct { p: V2, color: Rgba };

/// A bounded mesh builder over **caller-owned** fixed-capacity slices — the POD contract of
/// the pooled `GeometryState`. It never allocates: `addVertex`/`addTriangle` append while
/// there is room and latch `overflow` (refusing the whole excess, never a partial triangle)
/// otherwise, so a shape too big for the pool's capacity draws nothing rather than a torn
/// mesh — the same whole-refusal policy as `TextState`/`LineState`.
pub const Mesh = struct {
    verts: []Vertex,
    idx: []u16,
    vlen: usize = 0,
    ilen: usize = 0,
    overflow: bool = false,

    pub fn init(verts: []Vertex, idx: []u16) Mesh {
        return .{ .verts = verts, .idx = idx };
    }

    /// Append a vertex, returning its index. On overflow it latches `overflow` and returns
    /// the last valid index (the caller's triangle add will also refuse), so no out-of-range
    /// index is ever emitted.
    pub fn addVertex(self: *Mesh, v: Vertex) u16 {
        if (self.vlen >= self.verts.len or self.vlen > std.math.maxInt(u16)) {
            self.overflow = true;
            return if (self.vlen == 0) 0 else @intCast(self.vlen - 1);
        }
        self.verts[self.vlen] = v;
        const i: u16 = @intCast(self.vlen);
        self.vlen += 1;
        return i;
    }

    /// Append one triangle by three existing vertex indices. Refuses as a whole on index
    /// overflow (never a partial 1–2 index write that would desync the triple grouping).
    pub fn addTriangle(self: *Mesh, a: u16, b: u16, c: u16) void {
        if (self.ilen + 3 > self.idx.len) {
            self.overflow = true;
            return;
        }
        self.idx[self.ilen] = a;
        self.idx[self.ilen + 1] = b;
        self.idx[self.ilen + 2] = c;
        self.ilen += 3;
    }

    /// The filled vertex slice.
    pub fn vertices(self: *const Mesh) []const Vertex {
        return self.verts[0..self.vlen];
    }
    /// The filled index slice (length is a multiple of 3).
    pub fn indices(self: *const Mesh) []const u16 {
        return self.idx[0..self.ilen];
    }
};

/// Fan-triangulate a **convex** polygon `points` (a hex body, a marker) in one flat color.
/// Fan from vertex 0: triangles `(0, i, i+1)` for `i in 1..n-1`, so `n` points yield `n-2`
/// triangles sharing vertex 0 — minimal vertices, correct for any convex ring (concave
/// polygons would self-overlap, which the board never draws). Fewer than 3 points is a
/// no-op. Overflow is reported through the mesh.
pub fn fillConvex(mesh: *Mesh, points: []const V2, color: Rgba) void {
    fillConvexMulti(mesh, points, color, null);
}

/// Fan-triangulate a convex polygon with **per-vertex** colors (`colors[i]` for `points[i]`),
/// so `renderGeometry` interpolates them across the fill — a flat tint when all equal, a
/// gradient/mixed fill when not (the RENDER-04 seam). `colors` must be at least `points.len`
/// long; when `null`, `flat` is used for every vertex. Fewer than 3 points is a no-op.
pub fn fillConvexMulti(mesh: *Mesh, points: []const V2, flat: Rgba, colors: ?[]const Rgba) void {
    if (points.len < 3) return;
    var base: [1]u16 = undefined;
    // Emit all vertices first (shared by the fan), then index the triangles.
    var i: usize = 0;
    var first: u16 = 0;
    while (i < points.len) : (i += 1) {
        const col = if (colors) |cs| cs[i] else flat;
        const vi = mesh.addVertex(.{ .p = points[i], .color = col });
        if (i == 0) {
            first = vi;
            base[0] = vi;
        }
    }
    if (mesh.overflow) return;
    var t: usize = 1;
    while (t + 1 < points.len) : (t += 1) {
        mesh.addTriangle(first, first + @as(u16, @intCast(t)), first + @as(u16, @intCast(t + 1)));
    }
}

/// How a thick open polyline terminates at its two ends.
pub const Cap = enum {
    /// Flush at the endpoint (no extension) — the default for a rail segment.
    butt,
    /// Extended by `half_width` past each endpoint (a squared-off nib).
    square,
};

/// The miter limit: when a join's miter length exceeds `miter_limit × half_width` (a sharp,
/// acute corner), fall back to a **bevel** join rather than letting the spike run to
/// infinity. `4.0` matches the common SVG/canvas default (≈ 29° threshold).
pub const miter_limit: f32 = 4.0;

fn sub(a: V2, b: V2) V2 {
    return .{ .x = a.x - b.x, .y = a.y - b.y };
}
fn len(a: V2) f32 {
    return @sqrt(a.x * a.x + a.y * a.y);
}
/// Left normal (rotate +90°) of a unit-ish direction, normalized. Zero for a zero vector.
fn leftNormal(d: V2) V2 {
    const l = len(d);
    if (l < 1e-6) return .{ .x = 0, .y = 0 };
    return .{ .x = -d.y / l, .y = d.x / l };
}

/// Tessellate a **thick polyline** through `points` at `half_width` (half the stroke
/// thickness) into triangles, with **miter joins** (bevel fallback past `miter_limit`) at
/// interior vertices and `cap` ends when open. `closed` connects the last point back to the
/// first (a hex rail, a closed loop) and gives every vertex a join instead of a cap.
///
/// The core is offsetting: each polyline vertex gets a left and right offset point along the
/// join's **miter direction** (the angle bisector of its two adjacent segments) at the miter
/// distance `half_width / cos(theta/2)` so the stroke's outer edges stay parallel to the
/// segments. Consecutive offset pairs form a quad (two triangles). A join too sharp for the
/// miter limit inserts a bevel: the offsets are clamped to the per-segment normal and the
/// corner is filled with an extra triangle. Degenerate (near-zero) segments are skipped.
/// Fewer than 2 points, or a zero width, is a no-op. Overflow is reported through the mesh.
pub fn strokePolyline(mesh: *Mesh, points: []const V2, half_width: f32, closed: bool, cap: Cap, color: Rgba) void {
    if (points.len < 2 or half_width <= 0) return;

    const n = points.len;
    // For each vertex, compute its left/right offset point. We build them, then stitch quads.
    // Small fixed scratch is avoided (variable n): we emit per-segment, computing the two
    // ends' offsets on the fly. To keep miter joins we compute an offset per *vertex*.
    //
    // Segment direction i is points[i]->points[i+1] (wrapping if closed).
    const segCount = if (closed) n else n - 1;

    // Helper closures via a small inner struct so we can index segment dirs cheaply.
    const Ctx = struct {
        points: []const V2,
        n: usize,
        closed: bool,
        fn segDir(self: @This(), s: usize) V2 {
            const a = self.points[s];
            const b = self.points[(s + 1) % self.n];
            return sub(b, a);
        }
    };
    const cx = Ctx{ .points = points, .n = n, .closed = closed };

    // Emit the stroke as a strip: for each segment, place its 4 corner vertices (left/right at
    // each end) using the join miter direction at shared vertices, then two triangles. This
    // duplicates shared-vertex offsets per segment (simpler and robust); the vertex budget is
    // 4·segCount, well within the pool cap for the shapes this draws.
    var s: usize = 0;
    while (s < segCount) : (s += 1) {
        const ia = s;
        const ib = (s + 1) % n;
        const a = points[ia];
        const b = points[ib];
        const dir = sub(b, a);
        if (len(dir) < 1e-6) continue;
        const nrm = leftNormal(dir);

        // Start-of-segment offset direction/distance (miter at vertex ia if it is a join).
        const off_a = jointOffset(cx, ia, s, nrm, half_width, closed, cap, true);
        const off_b = jointOffset(cx, ib, s, nrm, half_width, closed, cap, false);

        const al = V2{ .x = a.x + off_a.left.x, .y = a.y + off_a.left.y };
        const ar = V2{ .x = a.x + off_a.right.x, .y = a.y + off_a.right.y };
        const bl = V2{ .x = b.x + off_b.left.x, .y = b.y + off_b.left.y };
        const br = V2{ .x = b.x + off_b.right.x, .y = b.y + off_b.right.y };

        const val = mesh.addVertex(.{ .p = al, .color = color });
        const var_ = mesh.addVertex(.{ .p = ar, .color = color });
        const vbl = mesh.addVertex(.{ .p = bl, .color = color });
        const vbr = mesh.addVertex(.{ .p = br, .color = color });
        if (mesh.overflow) return;
        // Quad (al, ar, br, bl) → triangles (al,ar,br) and (al,br,bl).
        mesh.addTriangle(val, var_, vbr);
        mesh.addTriangle(val, vbr, vbl);
    }
}

const Offset = struct { left: V2, right: V2 };

/// The left/right offset vectors at vertex `vi` for the segment whose left normal is `nrm`.
/// At an interior join (a vertex shared by two segments) the offset follows the **miter**
/// (angle-bisector) direction at distance `half_width / cos(theta/2)`, clamped to a bevel
/// (the plain segment normal) past `miter_limit`. At an open end it is the plain normal,
/// extended by `half_width` along the segment for a `.square` cap. `is_start` picks which
/// segment end (and thus which neighbor) forms the join.
fn jointOffset(cx: anytype, vi: usize, seg: usize, nrm: V2, half_width: f32, closed: bool, cap: Cap, is_start: bool) Offset {
    const n = cx.n;
    // Determine the neighbor segment sharing this vertex, if any.
    const has_prev = closed or vi > 0;
    const has_next = closed or vi + 1 < n;
    const is_join = if (is_start) has_prev else has_next;

    if (!is_join) {
        // Open end: plain normal offset, plus optional square-cap extension along the segment.
        var ext = V2{ .x = 0, .y = 0 };
        if (cap == .square) {
            const dir = cx.segDir(seg);
            const l = len(dir);
            if (l >= 1e-6) {
                const u = V2{ .x = dir.x / l, .y = dir.y / l };
                // Start extends backward (−u), end extends forward (+u).
                const signed: f32 = if (is_start) -half_width else half_width;
                ext = .{ .x = u.x * signed, .y = u.y * signed };
            }
        }
        return .{
            .left = .{ .x = nrm.x * half_width + ext.x, .y = nrm.y * half_width + ext.y },
            .right = .{ .x = -nrm.x * half_width + ext.x, .y = -nrm.y * half_width + ext.y },
        };
    }

    // Interior join: bisect the two adjacent segment directions.
    // The segment before this vertex and after this vertex (both pointing "forward").
    const prev_seg = (vi + n - 1) % n;
    const dir_in = cx.segDir(prev_seg); // into the vertex
    const dir_out = cx.segDir(vi % n); // out of the vertex
    const li = len(dir_in);
    const lo = len(dir_out);
    if (li < 1e-6 or lo < 1e-6) {
        return .{ .left = .{ .x = nrm.x * half_width, .y = nrm.y * half_width }, .right = .{ .x = -nrm.x * half_width, .y = -nrm.y * half_width } };
    }
    const nin = leftNormal(dir_in);
    const nout = leftNormal(dir_out);
    // Miter direction = normalized sum of the two edge normals (the bisector of the turn).
    var mvec = V2{ .x = nin.x + nout.x, .y = nin.y + nout.y };
    const ml = len(mvec);
    if (ml < 1e-6) {
        // 180° reversal — fall back to the plain normal.
        return .{ .left = .{ .x = nrm.x * half_width, .y = nrm.y * half_width }, .right = .{ .x = -nrm.x * half_width, .y = -nrm.y * half_width } };
    }
    mvec = .{ .x = mvec.x / ml, .y = mvec.y / ml };
    // Miter length factor: 1/cos(theta/2) = 1 / (mvec · nin) (both unit). Clamp to the limit.
    const cos_half = mvec.x * nin.x + mvec.y * nin.y;
    var scale: f32 = if (@abs(cos_half) < 1e-6) miter_limit else 1.0 / cos_half;
    if (@abs(scale) > miter_limit) scale = std.math.sign(scale) * miter_limit;
    const dist = half_width * scale;
    return .{
        .left = .{ .x = mvec.x * dist, .y = mvec.y * dist },
        .right = .{ .x = -mvec.x * dist, .y = -mvec.y * dist },
    };
}

// ============================ Tests (deterministic, SDL-free) =========================

const testing = std.testing;

fn scratch(v: []Vertex, i: []u16) Mesh {
    return Mesh.init(v, i);
}

test "fillConvex: a hexagon fans into n-2 triangles sharing vertex 0" {
    var v: [16]Vertex = undefined;
    var idx: [48]u16 = undefined;
    var m = scratch(&v, &idx);
    // A unit hexagon (6 points). Fan → 4 triangles → 12 indices, 6 vertices.
    const hex = [_]V2{
        .{ .x = 1, .y = 0 },  .{ .x = 0.5, .y = 0.87 },   .{ .x = -0.5, .y = 0.87 },
        .{ .x = -1, .y = 0 }, .{ .x = -0.5, .y = -0.87 }, .{ .x = 0.5, .y = -0.87 },
    };
    const red = Rgba{ .r = 200, .g = 40, .b = 40, .a = 255 };
    fillConvex(&m, &hex, red);
    try testing.expect(!m.overflow);
    try testing.expectEqual(@as(usize, 6), m.vertices().len);
    try testing.expectEqual(@as(usize, 12), m.indices().len); // 4 triangles
    // Every triangle shares vertex 0 (the fan center).
    var t: usize = 0;
    while (t < m.indices().len) : (t += 3) {
        try testing.expectEqual(@as(u16, 0), m.indices()[t]);
    }
    // All vertices carry the flat color.
    for (m.vertices()) |vert| try testing.expectEqual(red, vert.color);
}

test "fillConvex: fewer than 3 points is a no-op" {
    var v: [8]Vertex = undefined;
    var idx: [8]u16 = undefined;
    var m = scratch(&v, &idx);
    fillConvex(&m, &[_]V2{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 1 } }, .{ .r = 1, .g = 2, .b = 3, .a = 4 });
    try testing.expectEqual(@as(usize, 0), m.vertices().len);
    try testing.expectEqual(@as(usize, 0), m.indices().len);
}

test "fillConvexMulti: per-vertex colors are preserved (mixed-color / gradient fill)" {
    var v: [8]Vertex = undefined;
    var idx: [12]u16 = undefined;
    var m = scratch(&v, &idx);
    const tri = [_]V2{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 0, .y = 1 } };
    const cols = [_]Rgba{
        .{ .r = 255, .g = 0, .b = 0, .a = 255 },
        .{ .r = 0, .g = 255, .b = 0, .a = 255 },
        .{ .r = 0, .g = 0, .b = 255, .a = 255 },
    };
    fillConvexMulti(&m, &tri, .{ .r = 0, .g = 0, .b = 0, .a = 0 }, &cols);
    try testing.expectEqual(@as(usize, 3), m.vertices().len);
    try testing.expectEqual(@as(usize, 3), m.indices().len); // one triangle
    try testing.expectEqual(cols[0], m.vertices()[0].color);
    try testing.expectEqual(cols[1], m.vertices()[1].color);
    try testing.expectEqual(cols[2], m.vertices()[2].color);
}

test "fillConvex: overflow refuses the whole mesh (no torn triangle)" {
    var v: [4]Vertex = undefined; // room for 4 vertices only
    var idx: [12]u16 = undefined;
    var m = scratch(&v, &idx);
    const hex = [_]V2{
        .{ .x = 1, .y = 0 },  .{ .x = 0.5, .y = 0.87 },   .{ .x = -0.5, .y = 0.87 },
        .{ .x = -1, .y = 0 }, .{ .x = -0.5, .y = -0.87 }, .{ .x = 0.5, .y = -0.87 },
    };
    fillConvex(&m, &hex, .{ .r = 1, .g = 1, .b = 1, .a = 255 });
    try testing.expect(m.overflow);
    try testing.expectEqual(@as(usize, 0), m.indices().len); // no triangles emitted on overflow
}

test "strokePolyline: a straight horizontal segment is a rectangle of the right width" {
    var v: [8]Vertex = undefined;
    var idx: [12]u16 = undefined;
    var m = scratch(&v, &idx);
    const pts = [_]V2{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 } };
    strokePolyline(&m, &pts, 2, false, .butt, .{ .r = 1, .g = 2, .b = 3, .a = 255 });
    try testing.expect(!m.overflow);
    try testing.expectEqual(@as(usize, 4), m.vertices().len); // one quad
    try testing.expectEqual(@as(usize, 6), m.indices().len); // two triangles
    // Left normal of +x is +y; the offsets are ±2 in y around y=0.
    var min_y: f32 = 1e9;
    var max_y: f32 = -1e9;
    for (m.vertices()) |vert| {
        min_y = @min(min_y, vert.p.y);
        max_y = @max(max_y, vert.p.y);
    }
    try testing.expectApproxEqAbs(@as(f32, -2), min_y, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 2), max_y, 1e-4);
}

test "strokePolyline: a square cap extends the ends by half_width along the segment" {
    var v: [8]Vertex = undefined;
    var idx: [12]u16 = undefined;
    var m = scratch(&v, &idx);
    const pts = [_]V2{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 } };
    strokePolyline(&m, &pts, 2, false, .square, .{ .r = 1, .g = 1, .b = 1, .a = 255 });
    var min_x: f32 = 1e9;
    var max_x: f32 = -1e9;
    for (m.vertices()) |vert| {
        min_x = @min(min_x, vert.p.x);
        max_x = @max(max_x, vert.p.x);
    }
    // Butt would be [0,10]; square extends both ends by half_width (2) → [-2, 12].
    try testing.expectApproxEqAbs(@as(f32, -2), min_x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 12), max_x, 1e-4);
}

test "strokePolyline: an acute right-angle join miters to the bisector distance" {
    var v: [16]Vertex = undefined;
    var idx: [24]u16 = undefined;
    var m = scratch(&v, &idx);
    // An L: right then up. The join at (10,0) turns 90°; the miter bisector distance is
    // half_width / cos(45°) = 2 / 0.7071 ≈ 2.828 (within the miter limit).
    const pts = [_]V2{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 }, .{ .x = 10, .y = 10 } };
    strokePolyline(&m, &pts, 2, false, .butt, .{ .r = 1, .g = 1, .b = 1, .a = 255 });
    try testing.expect(!m.overflow);
    // The join at (10,0) produces miter offset vertices near that corner. The outer miter
    // sits at the bisector distance ≈ 2.828; the inner at the same distance on the other
    // side. Segment *ends* at (0,0)/(10,10) are ~10 away, so restrict to vertices within a
    // small neighborhood of the corner and take the max — that is the outer miter point.
    const corner = V2{ .x = 10, .y = 0 };
    var miter_d: f32 = 0;
    for (m.vertices()) |vert| {
        const d = len(sub(vert.p, corner));
        if (d < 5) miter_d = @max(miter_d, d); // only the corner's own offset vertices
    }
    try testing.expectApproxEqAbs(@as(f32, 2.8284), miter_d, 1e-2);
}

test "strokePolyline: a closed loop strokes every edge including last→first" {
    var v: [32]Vertex = undefined;
    var idx: [48]u16 = undefined;
    var m = scratch(&v, &idx);
    // A unit square as a closed rail: 4 points, 4 edges (including the closing edge).
    const sq = [_]V2{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 }, .{ .x = 10, .y = 10 }, .{ .x = 0, .y = 10 } };
    strokePolyline(&m, &sq, 1, true, .butt, .{ .r = 1, .g = 1, .b = 1, .a = 255 });
    try testing.expect(!m.overflow);
    // 4 edges × one quad each = 16 vertices, 8 triangles (24 indices).
    try testing.expectEqual(@as(usize, 16), m.vertices().len);
    try testing.expectEqual(@as(usize, 24), m.indices().len);
}

test "strokePolyline: fewer than 2 points or zero width is a no-op" {
    var v: [8]Vertex = undefined;
    var idx: [8]u16 = undefined;
    var m = scratch(&v, &idx);
    strokePolyline(&m, &[_]V2{.{ .x = 0, .y = 0 }}, 2, false, .butt, .{ .r = 1, .g = 1, .b = 1, .a = 255 });
    try testing.expectEqual(@as(usize, 0), m.indices().len);
    strokePolyline(&m, &[_]V2{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 } }, 0, false, .butt, .{ .r = 1, .g = 1, .b = 1, .a = 255 });
    try testing.expectEqual(@as(usize, 0), m.indices().len);
}
