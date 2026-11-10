//! `brightness` — one linear multiply of every pixel the frame has painted, as a single
//! full-window fill after the render walk and before present. The host passes a factor `k`
//! (1 = the frame as painted) and this module turns it into one blended rect:
//!
//!   - `k > 1` lifts: a fill of colour `k - 1` under a custom blend mode whose colour equation
//!     is `dst = dst + dst * src` (source factor DST_COLOR, destination factor ONE, ADD), so
//!     each channel becomes `dst * k`, clamped at white by the 8-bit target;
//!   - `k < 1` dims: a fill of colour `k` under SDL's modulate mode (`dst = dst * src`);
//!   - `k == 1` draws nothing, so the frame is bit-identical to the walk's own.
//!
//! Alpha is left as painted in both modes. Because the pass runs on the finished back buffer,
//! it reaches everything the walk drew — text, lines, fills, gradients, meshes, textures and
//! the clear colour — with no paint feature knowing about it, and anything that reads the
//! window afterwards (a PrintWindow capture) sees the multiplied frame. A colour cached in a
//! texture (the text compositor's render target) is untouched until it reaches the window,
//! so the multiply applies exactly once.
//!
//! A backend that cannot compose the lift's blend mode refuses `SDL_SetRenderDrawBlendMode`;
//! `apply` then draws nothing and reports `error.Unsupported`, and the frame shows at its
//! painted brightness.

const std = @import("std");
const sdl = @import("sdl3");

/// The largest lift one pass gives: `dst + dst * 1` doubles a channel.
pub const max_factor: f32 = 2;

/// The pass a factor asks for: the blended fill's colour, per channel, and which blend.
pub const Pass = union(enum) {
    /// The factor is 1 (or not a positive number): nothing is drawn.
    none,
    /// `dst + dst * c`, with `c = k - 1` in `(0, 1]`.
    lift: f32,
    /// `dst * c`, with `c = k` in `(0, 1)`.
    dim: f32,
};

/// The pass for factor `k`. A factor above `max_factor` lifts by `max_factor`.
pub fn pass(k: f32) Pass {
    if (!(k > 0) or k == 1) return .none;
    if (k > 1) return .{ .lift = @min(k, max_factor) - 1 };
    return .{ .dim = k };
}

/// The lift's blend mode: colour `src * dst + dst`, alpha `dst`. Null when SDL cannot compose it.
fn liftMode() ?sdl.blend_mode.Mode {
    return sdl.blend_mode.Mode.custom(.destination_color, .one, .add, .zero, .one, .add);
}

/// Multiply the current render target by `k`. Call once per frame, after every tree is drawn and
/// before present. The renderer's clip, draw colour and draw blend mode are restored.
pub fn apply(renderer: sdl.render.Renderer, k: f32) error{Unsupported}!void {
    const mode: sdl.blend_mode.Mode, const c: f32 = switch (pass(k)) {
        .none => return,
        .lift => |c| .{ liftMode() orelse return error.Unsupported, c },
        .dim => |c| .{ .mod, c },
    };

    const prior_blend = renderer.getDrawBlendMode() catch null;
    const prior_color = renderer.getDrawColorFloat() catch null;
    const prior_clip = if (renderer.getClipEnabled()) renderer.getClipRect() catch null else null;
    defer {
        renderer.setClipRect(prior_clip) catch {};
        if (prior_color) |pc| renderer.setDrawColorFloat(pc) catch {};
        if (prior_blend) |pb| renderer.setDrawBlendMode(pb) catch {};
    }

    renderer.setDrawBlendMode(mode) catch return error.Unsupported;
    renderer.setClipRect(null) catch {};
    renderer.setDrawColorFloat(.{ .r = c, .g = c, .b = c, .a = 1 }) catch return;
    renderer.renderFillRect(null) catch {};
}

test "brightness: a factor of 1 asks for no pass" {
    try std.testing.expectEqual(Pass.none, pass(1));
    try std.testing.expectEqual(Pass.none, pass(0));
    try std.testing.expectEqual(Pass.none, pass(std.math.nan(f32)));
}

test "brightness: above 1 the pass adds the factor's excess, below 1 it modulates by the factor" {
    const lift = pass(1.4);
    try std.testing.expect(lift == .lift);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), lift.lift, 1e-6);
    const dim = pass(0.8);
    try std.testing.expect(dim == .dim);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), dim.dim, 1e-6);
    // One pass doubles a channel at most.
    try std.testing.expectApproxEqAbs(@as(f32, 1), pass(3).lift, 1e-6);
}

test "brightness: the lift's blend mode composes" {
    try std.testing.expect(liftMode() != null);
}
