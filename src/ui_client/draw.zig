//! The render walk: turn a laid-out node tree into pixels. This module owns the
//! traversal, the clip stack, and the per-node feature dispatch — the actual paint
//! primitives live with their feature (`features/*.zig`), one `draw` per aspect. So
//! adding a visual is adding a feature, not editing this file.

const ui = @import("../ui/root.zig");
const cb = @import("./ctx_binding.zig");
const feat = @import("./features/root.zig");
const paint = @import("./features/paint.zig");

const UiCtx = cb.UiCtx;
const Node = cb.Node;

/// Paint a whole UI tree. Called once per root tree, in the render list's order (later
/// trees draw on top). Establishes the explicit alpha-blending baseline (RENDER-01) and
/// restores the renderer's clip to "none" on the way out so the next tree isn't cropped
/// by this one's leftover clip rect.
///
/// **Blend-mode policy (RENDER-01):** the draw blend mode is set to `.blend` here, once per
/// tree, so every geometry primitive a feature paints (`fill`/`outline`/`line`
/// `renderFillRect`/`renderLines`) alpha-blends against what is underneath — SDL's default is
/// `.none` (source replaces destination, ignoring `a`), which would render a translucent hover
/// row, scrim, or dimmed tile fully opaque. Setting it per tree (not only once at init) makes
/// the baseline self-healing: a renderer/device reset cannot silently strip it, and any inner
/// pass that temporarily changes it (the text compositor's render-target pass) snapshots and
/// restores *this* baseline. Texture blits carry their own per-texture blend mode.
pub fn draw_tree(u: *UiCtx, root: *Node) void {
    u.res.platform.renderer.setDrawBlendMode(.blend) catch {};
    draw_node(u, root, null, 1);
    u.res.platform.renderer.setClipRect(null) catch {};
}

/// Recursive pre-order paint (a parent draws under its children). `clip` is the
/// effective clip rect inherited from ancestors (`null` = unclipped); it's applied
/// before this node paints, then narrowed for the subtree if this node is `.clip`.
/// `opacity` is the inherited visual opacity (RENDER-07): this node's own
/// `render_data.opacity` multiplies it, the product is folded into every feature's paint
/// alpha, and the same product inherits to the children — so a whole subtree dims without
/// recomputing child colors. Opacity is purely visual; hit-testing never reads it.
/// Per node, features paint in `list` order (fill → image → svg → geometry → line → text →
/// outline — the z-order); each set aspect's optional payload is unwrapped and handed to its
/// `draw` along with the effective opacity.
fn draw_node(u: *UiCtx, node: *Node, clip: ?ui.Rect, opacity: f32) void {
    u.res.platform.renderer.setClipRect(paint.irect(clip)) catch {};

    const eff = opacity * node.render_data.opacity;
    inline for (feat.list) |F| {
        if (@field(node.render_data, F.name)) |payload| F.draw(u, node, payload, eff);
    }

    // Overflow only *masks*: `scroll_x/y` already translated the children in the layout
    // pass. A `.clip` node crops its subtree to the intersection of the inherited clip
    // and its own box; `.visible` passes the inherited clip through unchanged.
    const child_clip: ?ui.Rect = if (node.layout.overflow == .clip) blk: {
        const box = paint.full(node) orelse break :blk clip;
        break :blk if (clip) |c| c.intersect(box) else box;
    } else clip;

    for (node.children.items) |c| draw_node(u, c, child_clip, eff);
}
