//! The pointy-top hex pixel transform the research board paints with: axial → pixel, the six
//! vertex offsets, pixel → hex, and the point-in-hex test. This is the one place that math
//! lives; the topology it maps out of is `sim.kernel.hex`, and floats cross one way, out of it.
//!
//! For hex size `s` (centre → vertex) and board centre `(cx, cy)`:
//!   `x = cx + sqrt(3) * s * (q + r / 2)`
//!   `y = cy + 1.5 * s * r`

const std = @import("std");
const ha = @import("ha");
const hex = ha.sim.kernel.hex;
const Axial = hex.Axial;
const Point = ha.ui_client.Point;

/// Pointy-top axial → pixel for hex size `s` (centre → vertex) and board centre `(cx, cy)`.
pub fn toPixel(a: Axial, s: f32, cx: f32, cy: f32) Point {
    const q: f32 = @floatFromInt(a.q);
    const r: f32 = @floatFromInt(a.r);
    const sqrt3 = std.math.sqrt(3.0);
    return .{
        .x = cx + sqrt3 * s * (q + r / 2.0),
        .y = cy + 1.5 * s * r,
    };
}

/// The six pointy-top vertex offsets (from a hex centre) at radius `s`, at angles
/// `-30°, 30°, 90°, 150°, 210°, 270°`, in screen space (`y` down). A caller adds a centre to
/// each to draw the polygon.
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

/// Pixel → the hex containing it, the inverse of `toPixel` for size `s` and centre `(cx, cy)`:
/// fractional axial coordinates, then cube rounding (the component with the largest rounding
/// error is recomputed from the other two, so `x + y + z == 0` holds).
pub fn fromPixel(p: Point, s: f32, cx: f32, cy: f32) Axial {
    const sqrt3 = std.math.sqrt(3.0);
    const px = p.x - cx;
    const py = p.y - cy;
    const fq = (sqrt3 / 3.0 * px - 1.0 / 3.0 * py) / s;
    const fr = (2.0 / 3.0 * py) / s;
    const fx = fq;
    const fz = fr;
    const fy = -fx - fz;
    var rx = @round(fx);
    const ry = @round(fy);
    var rz = @round(fz);
    const dx = @abs(rx - fx);
    const dy = @abs(ry - fy);
    const dz = @abs(rz - fz);
    if (dx > dy and dx > dz) {
        rx = -ry - rz;
    } else if (dy <= dz) {
        rz = -rx - ry;
    }
    return .{ .q = @intFromFloat(rx), .r = @intFromFloat(rz) };
}

/// Whether `p` lies inside the pointy-top hex of radius `s` centred on `c` (edges included).
pub fn containsPoint(c: Point, s: f32, p: Point) bool {
    const sqrt3 = std.math.sqrt(3.0);
    const dx = @abs(p.x - c.x);
    const dy = @abs(p.y - c.y);
    if (dx > s * sqrt3 / 2.0 or dy > s) return false;
    return dy <= s - dx / sqrt3;
}

// ============================ Tests =============================

const testing = std.testing;

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

test "fromPixel: every hex's centre maps back to it, and a near-centre point too" {
    var list: std.ArrayList(Axial) = .empty;
    defer list.deinit(testing.allocator);
    try hex.disk(testing.allocator, 4, &list);
    for (list.items) |a| {
        const c = toPixel(a, 31, 310, 310);
        try testing.expect(fromPixel(c, 31, 310, 310).eql(a));
        try testing.expect(fromPixel(.{ .x = c.x + 9, .y = c.y - 7 }, 31, 310, 310).eql(a));
    }
}

test "containsPoint: the centre and a vertex are in; the bounding-box corner is out" {
    const c = Point{ .x = 0, .y = 0 };
    try testing.expect(containsPoint(c, 10, c));
    try testing.expect(containsPoint(c, 10, .{ .x = 0, .y = 10 })); // the bottom vertex
    try testing.expect(!containsPoint(c, 10, .{ .x = 8.6, .y = 9.9 })); // past a slanted edge
    try testing.expect(!containsPoint(c, 10, .{ .x = 0, .y = 10.1 }));
}

test "fromPixel and containsPoint agree on the visible tile area" {
    const a = Axial{ .q = 2, .r = -1 };
    const c = toPixel(a, 31, 310, 310);
    var dy: f32 = -25;
    while (dy <= 25) : (dy += 5) {
        var dx: f32 = -25;
        while (dx <= 25) : (dx += 5) {
            const p = Point{ .x = c.x + dx, .y = c.y + dy };
            if (containsPoint(c, 29.5, p)) try testing.expect(fromPixel(p, 31, 310, 310).eql(a));
        }
    }
}
