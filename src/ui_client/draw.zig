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
/// trees draw on top). Restores the renderer's clip to "none" on the way out so the
/// next tree isn't cropped by this one's leftover clip rect.
pub fn draw_tree(u: *UiCtx, root: *Node) void {
    draw_node(u, root, null);
    u.res.renderer.setClipRect(null) catch {};
}

/// Recursive pre-order paint (a parent draws under its children). `clip` is the
/// effective clip rect inherited from ancestors (`null` = unclipped); it's applied
/// before this node paints, then narrowed for the subtree if this node is `.clip`.
/// Per node, features paint in `list` order (fill → image → svg → text → outline — the
/// z-order); each set aspect's optional payload is unwrapped and handed to its `draw`.
fn draw_node(u: *UiCtx, node: *Node, clip: ?ui.Rect) void {
    u.res.renderer.setClipRect(paint.irect(clip)) catch {};

    inline for (feat.list) |F| {
        if (@field(node.render_data, F.name)) |payload| F.draw(u, node, payload);
    }

    // Overflow only *masks*: `scroll_x/y` already translated the children in the layout
    // pass. A `.clip` node crops its subtree to the intersection of the inherited clip
    // and its own box; `.visible` passes the inherited clip through unchanged.
    const child_clip: ?ui.Rect = if (node.layout.overflow == .clip) blk: {
        const box = paint.full(node) orelse break :blk clip;
        break :blk if (clip) |c| c.intersect(box) else box;
    } else clip;

    for (node.children.items) |c| draw_node(u, c, child_clip);
}
