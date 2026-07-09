//! The **feature interface** and registry. A *feature* is one kind of thing a node can
//! be — text, a fill, an image, an svg — expressed as a single module that co-locates
//! its whole surface:
//!
//!   - `pub const name`     — the `RenderData` field that carries its payload (required)
//!   - `pub const Payload`  — that field's type (required); `?Color`, `?Sprite`, …
//!   - `pub fn draw`        — paint one laid-out node given its (unwrapped) payload (required)
//!   - `pub const State`    — a pooled, `node.key`-addressed persistent state (optional)
//!   - `pub fn attach`      — the build-time mixin: measure + size + set payload/state (optional)
//!
//! This is the mechanism/policy seam drawn *through* a feature: `State` is engine
//! caching (declared in `ctx_binding.UiState`, stored/keyed/evicted by `src/ui/cache.zig`);
//! `Payload`/`attach`/`draw` are host policy (they touch the font, the renderer, the
//! backend). Adding a feature — `svg` was the proof — is one module here + one `list`
//! entry + one matching `RenderData` field; the draw walk and pools follow. `RenderData`
//! stays hand-written, but `assertFeature` fails the build if it drifts from the list.
//!
//! Overflow/clip is deliberately **not** a feature — it's `Layout.overflow` (geometry the
//! render walk *and* hit-testing read), not a paint aspect. See `src/ui/features/layout.zig`.

const std = @import("std");
const cb = @import("../ctx_binding.zig");

pub const text = @import("text.zig");
pub const fill = @import("fill.zig");
pub const outline = @import("outline.zig");
pub const image = @import("image.zig");
pub const svg = @import("svg.zig");

/// The registered features, **in draw order** (back → front): a solid fill under any
/// image/vector, under text, with the outline ring last so it shows over opaque tiles.
/// The list's order *is* the z-order — the render walk (`draw.draw_tree`) iterates it
/// per node. Add a feature by adding its module and one entry here (and its `RenderData`
/// field). Only nodes sharing several aspects (a button's text+outline) see the order.
pub const list = .{ fill, image, svg, text, outline };

/// Compile-time conformance check for one feature `F` — the closest Zig gets to
/// "implements Interface". Verifies the required surface *and* that the hand-written
/// `RenderData` has a matching field, so the descriptor can't silently drift from the
/// list (a listed feature whose field is missing/mistyped is a build error, not a
/// silently-undrawn aspect). Run over the whole `list` in the `comptime` block below.
pub fn assertFeature(comptime F: type) void {
    if (!@hasDecl(F, "name")) @compileError(@typeName(F) ++ ": a feature must declare `pub const name`");
    if (!@hasDecl(F, "Payload")) @compileError(@typeName(F) ++ ": a feature must declare `pub const Payload`");
    if (!@hasDecl(F, "draw")) @compileError(@typeName(F) ++ ": a feature must declare `pub fn draw`");
    if (!@hasField(cb.RenderData, F.name))
        @compileError("RenderData has no field '" ++ F.name ++ "' for feature " ++ @typeName(F));
    if (@FieldType(cb.RenderData, F.name) != F.Payload)
        @compileError("RenderData." ++ F.name ++ " type does not match feature Payload for " ++ @typeName(F));
}

comptime {
    for (list) |F| assertFeature(F);
}

// --- Ergonomic attach wrappers -------------------------------------------------
// The old `data_*` mixin names, now thin aliases onto the owning feature's `attach`.
// Keeps widget/call-site churn to zero while the definitions live with their feature.

pub const data_text = text.attach;
pub const data_img = image.attach_texture;
pub const data_sprite = image.attach_sprite;
pub const data_svg = svg.attach;

test {
    std.testing.refAllDecls(@This());
    _ = paint;
    _ = text;
    _ = fill;
    _ = outline;
    _ = image;
    _ = svg;
}

const paint = @import("paint.zig");
