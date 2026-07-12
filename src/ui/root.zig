//! Library root for the engine (`src/ui/`). Re-exports the pieces a host binds against —
//! the `Node` tree atom (in `node.zig`), the per-frame `Ctx`, the cache, and the layout
//! feature types — under one namespace, so a host imports `ui` and reaches everything.

pub const features = @import("./features/root.zig");
pub const cache = @import("./cache.zig");
pub const geometry = @import("./geometry.zig");

pub const Ctx = @import("./ctx.zig").Ctx;
pub const Rect = geometry.Rect;
pub const key = cache.key;
pub const key_i = cache.key_i;
// Note: no `Color` here — RGBA is host policy (the engine carries `RenderData`
// opaquely and never reads a color). The host aliases its own (see `src/theme.zig`).
pub const Pool = cache.Pool;
pub const Pools = cache.Pools;

pub const Anchor = features.Anchor;
pub const Flow = features.Flow;
pub const Direction = features.Direction;
pub const MainAlign = features.MainAlign;
pub const CrossAlign = features.CrossAlign;
pub const Padding = features.Padding;
pub const Size = features.Size;
pub const SizeRule = features.SizeRule;
pub const Layout = features.Layout;

/// The tree atom (generic over the host's `RenderData`) and the post-layout `stamp_rects`
/// walk — both defined in `node.zig`, re-exported here as `ui.Node` / `ui.stamp_rects`.
pub const Node = @import("./node.zig").Node;
pub const stamp_rects = @import("./node.zig").stamp_rects;

test {
    _ = @import("./node.zig");
    _ = cache;
    _ = @import("./ctx.zig");
}
