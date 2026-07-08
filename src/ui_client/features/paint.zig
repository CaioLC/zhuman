//! Shared paint geometry for the feature `draw` fns: a node's box in engine `ui.Rect`
//! (f32) plus the conversions SDL wants (`FRect` for fills/blits, `IRect` for clip).
//! Leaf module — imports only the engine, `sdl`, and the concrete `Node`; never a
//! feature module, so every feature can import it without a cycle.

const ui = @import("../../ui/root.zig");
const sdl = @import("sdl3");
const cb = @import("../ctx_binding.zig");

const Node = cb.Node;

/// A node's full resolved box (global pos + solved size), or null if it hasn't been
/// laid out yet. Where `fill`/`outline` paint, and the box a `.clip` node crops to.
pub fn full(node: *Node) ?ui.Rect {
    return .{
        .x = node.layout._global_x orelse return null,
        .y = node.layout._global_y orelse return null,
        .w = node.size.width,
        .h = node.size.height,
    };
}

/// A node's content box: global pos inset by padding, sized to the host-measured
/// `data_*` dims — where `text`/`img`/`svg` blit their payload. Null if not laid out.
pub fn content(node: *Node) ?ui.Rect {
    const s = node.size;
    return .{
        .x = (node.layout._global_x orelse return null) + s.padding.left,
        .y = (node.layout._global_y orelse return null) + s.padding.up,
        .w = s.data_width,
        .h = s.data_height,
    };
}

/// `ui.Rect` (f32) → SDL `FRect`, the shape the renderer's fill/blit primitives take.
pub fn frect(r: ui.Rect) sdl.rect.FRect {
    return .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
}

/// `?ui.Rect` (f32) → `?IRect` (i32), the shape `setClipRect` takes (`null` disables).
pub fn irect(r: ?ui.Rect) ?sdl.rect.IRect {
    const v = r orelse return null;
    return .{
        .x = @intFromFloat(v.x),
        .y = @intFromFloat(v.y),
        .w = @intFromFloat(v.w),
        .h = @intFromFloat(v.h),
    };
}
