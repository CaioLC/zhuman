//! `geometry` feature — untextured colored triangles and honest thick polylines, backed by
//! SDL's `renderGeometry` (RENDER-03). It is the second *variable-length* feature after
//! `line`: a mesh has a variable vertex/index count, so the coordinates live in a pooled
//! `GeometryState` (declared in `ctx_binding.UiState`, like every feature state) and the
//! `RenderData` payload carries only the per-mesh draw parameters (an opacity multiplier).
//!
//! The mesh is built by the **pure, SDL-free** `geometry_tess.zig` (a convex-polygon fan, a
//! thick polyline with miter joins and butt/square caps) into node-local **unit-square**
//! coordinates — (0,0) is the node's top-left, (1,1) its bottom-right — so a shape survives
//! resize and zoom without recomputing, exactly like `line.zig`. `attach` runs the
//! tessellator once at build; `draw` maps the stored unit vertices to device px through the
//! node's laid-out box, converts each per-vertex `Color` (u8) to SDL's float `FColor` with
//! the mesh opacity folded into alpha, and submits one `renderGeometry` call. The render
//! walk's `.blend` baseline (RENDER-01) makes vertex alpha composite; the walk's clip stack
//! crops the triangles like any other paint.
//!
//! This is the primitive shared by hex bodies/rails/markers, distribution curves, slider
//! diamonds, and diagonal indicators. It does **not** yet replace `line.zig`'s
//! first-segment-normal thick-line approximation — that migration waits until the parity
//! consumers (the board) move onto this feature (see docs/roadmap.md RENDER-03).

const std = @import("std");
const sdl = @import("sdl3");
const ui = @import("../../ui/root.zig");
const cb = @import("../ctx_binding.zig");
const paint = @import("paint.zig");
const tess = @import("geometry_tess.zig");

const UiCtx = cb.UiCtx;
const Node = cb.Node;

pub const name = "geometry";
pub const Payload = ?cb.Geometry;
pub const State = cb.UiState.GeometryState;

/// The polyline end-cap discipline, re-exported so call sites (`El.polyline`) name one type.
pub const Cap = tess.Cap;

/// The gradient axis (RENDER-04), re-exported for call sites (`El.gradient`).
pub const Dir = tess.Dir;

/// One host-level gradient stop: a position along the axis (0..1) and a host `Color` there.
/// The feature converts the `Color` to the tessellator's byte `Rgba`. Two stops at the same
/// `pos` make a hard split; a `color → transparent` pair makes a wash. See `attach_gradient`.
pub const GradientStop = struct { pos: f32, color: cb.Color };

/// Give `node` a **convex-polygon fill** through `points` (node-local unit-square coords),
/// flat `color`. Fan-triangulated by the pure tessellator into the pooled mesh. Like
/// `line`, this does not size the node — points are relative, so the caller gives the node a
/// box and the fill stretches to it. `opacity` fades the whole mesh (default opaque).
pub fn attach_polygon(ctx: *UiCtx, node: *Node, points: []const cb.Point, color: cb.Color, opacity: f32) void {
    const st = node.state(ctx, State);
    var vbuf: [State.vcap]tess.Vertex = undefined;
    var ibuf: [State.icap]u16 = undefined;
    var mesh = tess.Mesh.init(&vbuf, &ibuf);
    tess.fillConvex(&mesh, toV2(points), toRgba(color));
    storeMesh(st, &mesh);
    node.render_data.geometry = .{ .opacity = opacity };
}

/// Give `node` a **thick polyline** through `points` (node-local unit-square coords) at
/// `half_width` (in unit-square units, mapped to px at draw), flat `color`, with miter joins
/// and `cap` ends; `closed` connects last→first for a rail loop. Tessellated into the pooled
/// mesh. Does not size the node.
pub fn attach_polyline(ctx: *UiCtx, node: *Node, points: []const cb.Point, half_width: f32, closed: bool, cap: tess.Cap, color: cb.Color, opacity: f32) void {
    const st = node.state(ctx, State);
    var vbuf: [State.vcap]tess.Vertex = undefined;
    var ibuf: [State.icap]u16 = undefined;
    var mesh = tess.Mesh.init(&vbuf, &ibuf);
    tess.strokePolyline(&mesh, toV2(points), half_width, closed, cap, toRgba(color));
    storeMesh(st, &mesh);
    node.render_data.geometry = .{ .opacity = opacity };
}

/// Give `node` an **explicit linear gradient** fill (RENDER-04) along `dir` through ordered
/// `stops` (node-local, positions 0..1 on the axis), drawn by the geometry feature via
/// per-vertex-colored quads. Covers the eating-slider **split track** (two stops at the same
/// position = a hard `acc`|`line2` edge) and milestone/state **washes** (a `tint → transparent`
/// pair). Stops carry a full `Color` (alpha included), so a wash's transparent end is just an
/// `a = 0` stop. Does not size the node — the gradient stretches to its box. `opacity` fades
/// the whole mesh on top of the per-stop alpha.
pub fn attach_gradient(ctx: *UiCtx, node: *Node, dir: Dir, stops: []const GradientStop, opacity: f32) void {
    const st = node.state(ctx, State);
    var sbuf: [State.vcap]tess.Stop = undefined;
    const n = @min(stops.len, sbuf.len);
    for (stops[0..n], 0..) |s, i| sbuf[i] = .{ .pos = s.pos, .color = toRgba(s.color) };
    var vbuf: [State.vcap]tess.Vertex = undefined;
    var ibuf: [State.icap]u16 = undefined;
    var mesh = tess.Mesh.init(&vbuf, &ibuf);
    tess.fillGradient(&mesh, dir, sbuf[0..n]);
    storeMesh(st, &mesh);
    node.render_data.geometry = .{ .opacity = opacity };
}

/// Copy a freshly-tessellated `tess.Mesh` into the pooled `GeometryState` as host `Vert`s.
/// On tessellator overflow the mesh is empty, so `set` stores nothing and `draw` no-ops —
/// whole-refusal, never a torn mesh.
fn storeMesh(st: *State, mesh: *const tess.Mesh) void {
    var vbuf: [State.vcap]cb.Vert = undefined;
    const vs = mesh.vertices();
    if (mesh.overflow or vs.len > State.vcap) {
        st.set(&[_]cb.Vert{}, &[_]u16{});
        return;
    }
    for (vs, 0..) |v, i| vbuf[i] = .{ .p = .{ .x = v.p.x, .y = v.p.y }, .color = .{ .r = v.color.r, .g = v.color.g, .b = v.color.b, .a = v.color.a } };
    st.set(vbuf[0..vs.len], mesh.indices());
}

/// Paint the node's pooled mesh with `renderGeometry`. Maps each unit-square vertex to device
/// px through the node's full box, converts its `Color` to SDL `FColor` (u8 → 0..1) with the
/// payload `opacity` folded into alpha, and submits one indexed draw. A missing box or an
/// empty mesh is a no-op; a submit error is skipped silently (cosmetic, like every paint).
pub fn draw(u: *UiCtx, node: *Node, g: cb.Geometry, opacity: f32) void {
    const st = node.state(u, State);
    const verts = st.vertices();
    const idx = st.indices();
    if (verts.len < 3 or idx.len < 3) return;
    const r = paint.full(node) orelse return;

    // Combine the per-mesh payload opacity with the inherited subtree opacity (RENDER-07).
    const op = std.math.clamp(g.opacity, 0, 1) * std.math.clamp(opacity, 0, 1);
    var out: [State.vcap]sdl.render.Vertex = undefined;
    for (verts, 0..) |v, i| {
        out[i] = .{
            .position = .{ .x = r.x + v.p.x * r.w, .y = r.y + v.p.y * r.h },
            .color = toFColor(v.color, op),
            .tex_coord = .{ .x = 0, .y = 0 },
        };
    }
    // `renderGeometry` wants `[]const c_int` indices; our u16 fit, widened per call.
    var iout: [State.icap]c_int = undefined;
    for (idx, 0..) |ix, i| iout[i] = ix;
    u.res.platform.renderer.renderGeometry(null, out[0..verts.len], iout[0..idx.len]) catch return;
}

// --- Conversions ------------------------------------------------------------------------

fn toV2(points: []const cb.Point) []const tess.V2 {
    // `cb.Point` and `tess.V2` are both `{ x: f32, y: f32 }`; reinterpret the slice so the
    // tessellator stays SDL/host-type-free without a per-point copy.
    return @ptrCast(points);
}

fn toRgba(c: cb.Color) tess.Rgba {
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a };
}

/// `Color` (u8 0..255) → SDL `FColor` (f32 0..1), with `opacity` (0..1) multiplied into
/// alpha. `renderGeometry` interpolates these float colors across each triangle.
fn toFColor(c: cb.Color, opacity: f32) sdl.pixels.FColor {
    const inv: f32 = 1.0 / 255.0;
    return .{
        .r = @as(f32, @floatFromInt(c.r)) * inv,
        .g = @as(f32, @floatFromInt(c.g)) * inv,
        .b = @as(f32, @floatFromInt(c.b)) * inv,
        .a = @as(f32, @floatFromInt(c.a)) * inv * opacity,
    };
}

// ============================ Tests ====================================================
//
// The tessellation math is exhaustively tested SDL-free in `geometry_tess.zig` (pulled in
// below). Here we cover the two host-side pure conversions `draw` relies on — the
// `Color`→`FColor` + opacity fold and the unit-square→device mapping — without a renderer.

test {
    _ = tess; // pull the SDL-free tessellation tests into this feature's test binary
}

test "geometry: Color u8 → FColor 0..1 with opacity folded into alpha" {
    const c: cb.Color = .{ .r = 255, .g = 0, .b = 128, .a = 200 };
    const f = toFColor(c, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), f.r, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), f.g, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), f.b, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 200.0 / 255.0), f.a, 1e-6);
    // Opacity multiplies alpha only.
    const half = toFColor(c, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), half.r, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, (200.0 / 255.0) * 0.5), half.a, 1e-6);
}

test "geometry: a unit-square vertex maps into the node's device box" {
    // The mapping `draw` applies: device = origin + unit * size. Pinned here without a
    // renderer, so the local→device contract (survives resize/zoom/scale) is guarded.
    const box = ui.Rect{ .x = 100, .y = 50, .w = 200, .h = 80 };
    const corners = [_]cb.Point{
        .{ .x = 0, .y = 0 }, // top-left → box origin
        .{ .x = 1, .y = 1 }, // bottom-right → box far corner
        .{ .x = 0.5, .y = 0.5 }, // center
    };
    const expect = [_]sdl.rect.FPoint{
        .{ .x = 100, .y = 50 },
        .{ .x = 300, .y = 130 },
        .{ .x = 200, .y = 90 },
    };
    for (corners, expect) |p, e| {
        const dx = box.x + p.x * box.w;
        const dy = box.y + p.y * box.h;
        try std.testing.expectApproxEqAbs(e.x, dx, 1e-4);
        try std.testing.expectApproxEqAbs(e.y, dy, 1e-4);
    }
}

test "geometry: toV2 reinterprets Point as V2 without a copy" {
    const pts = [_]cb.Point{ .{ .x = 1, .y = 2 }, .{ .x = 3, .y = 4 } };
    const v2 = toV2(&pts);
    try std.testing.expectEqual(@as(usize, 2), v2.len);
    try std.testing.expectEqual(@as(f32, 3), v2[1].x);
    try std.testing.expectEqual(@as(f32, 4), v2[1].y);
}
