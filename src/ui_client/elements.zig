//! **Elements** — the *content* layer, plus the **`El` handle** that makes composition
//! fluent. A content element creates a node and sets *what* is in it (a string, a texture,
//! an svg). It returns an `El` (`{ ctx, node }`), a tiny host handle carrying `ctx` so
//! style + placement chain right onto it:
//!
//!   const header = try el.div(ctx, root, "header");
//!   _ = header.with_layout(.top_left)                     // own anchor within the parent
//!             .with_align_children(.horizontal, .center_left) // children: flow + settle
//!             .with_gap(6)
//!             .with_style(.{ h1, red });                  // style — declarative fragment fold
//!
//! Content leaves default their anchor to **`.relative`** (they are always children — roots
//! come from `el.root`, which stays `.top_left`), so flowed layout is the zero-config case.
//! **Placement is set straight onto the node** via `with_layout` (own anchor) /
//! `with_align_children` (children flow + settle) / `with_gap`/`with_size`/`with_overflow`
//! (no "Placement" partial folding over the engine's values); **style** is the fragment fold
//! (`with_style` → `style.apply`). The two stay cleanly separate.
//!
//! Why a handle and not `*Node` methods: applying a `font` re-measures the text (needs the
//! font backend on `ctx`), and the engine `Node` is deliberately ctx-agnostic. Drop to the
//! raw node with `.get()` (for templates / geometry reads).

const std = @import("std");
const sdl = @import("sdl3");
const ui = @import("../ui/root.zig");
const cb = @import("./ctx_binding.zig");
const feat = @import("./features/root.zig");
const style = @import("./style.zig");

const UiCtx = cb.UiCtx;
const Node = cb.Node;
const Sprite = cb.Sprite;

/// A fluent handle over a built node: the node plus the `ctx` needed to style it. Returned
/// by every element constructor. Placement methods write the engine `Layout`/`Size` fields
/// directly; `with_style` folds a style spec. `.get()` drops to the raw `*Node`.
pub const El = struct {
    ctx: *UiCtx,
    node: *Node,

    /// The raw node — for passing to a template, or reading geometry.
    pub fn get(self: El) *Node {
        return self.node;
    }

    /// This node's interaction this frame (buttons read `.clicked`). Uses the handle's ctx.
    pub fn query(self: El) UiCtx.Interaction {
        return self.node.query(self.ctx);
    }

    /// Set this node's own anchor — how *it* sits within its parent. How its children flow
    /// and settle is the separate concern `with_align_children`.
    pub fn with_layout(self: El, anchor: ui.Anchor) El {
        self.node.layout.anchor = anchor;
        return self;
    }

    /// Set how this node's children flow (`flow`) and where they settle within its leftover
    /// space (`anchor` — cross-axis part aligns each child, main-axis part justifies the run;
    /// see `Layout.child_anchor`). Pass `.top_left` for the plain flush-start flow.
    pub fn with_align_children(self: El, flow: ui.ChildrenAlign, anchor: ui.Anchor) El {
        self.node.layout.children_align = flow;
        self.node.layout.child_anchor = anchor;
        return self;
    }

    /// Cross-axis alignment for this node's `.horizontal` children — `.top`/`.center`/
    /// `.bottom` (by box edge) or `.baseline` (text share a common baseline; a box with no
    /// baseline uses its bottom). Default is `.baseline`. No effect on vertical/wrapped flows.
    pub fn with_cross_align(self: El, mode: ui.CrossAlign) El {
        self.node.layout.cross_align = mode;
        return self;
    }

    /// Per-axis size rule — `.fit_children`, `.{ .fixed = 240 }`, `.{ .pct_of_parent = 1 }`, …
    pub fn with_size(self: El, w: ui.SizeRule, h: ui.SizeRule) El {
        self.node.size.w = w;
        self.node.size.h = h;
        return self;
    }

    /// Overflow handling for this node's content (`.visible` / `.clip`).
    pub fn with_overflow(self: El, o: ui.features.Overflow) El {
        self.node.layout.overflow = o;
        return self;
    }

    /// Compose a style spec onto the node (see `style.apply`) — style only, no placement.
    pub fn with_style(self: El, spec: anytype) El {
        style.apply(self.ctx, self.node, spec);
        return self;
    }
};

/// Accept an `El` or a bare `*Node` as a parent — the comptime branch picks the node out.
fn nodeOf(parent: anytype) *Node {
    return if (@TypeOf(parent) == El) parent.node else parent;
}

/// A fresh child node, anchored `.relative` — the default for content leaves.
fn child(ctx: *UiCtx, parent: anytype, id: []const u8) !*Node {
    const node = try Node.pcreate(ctx.arena, id, nodeOf(parent));
    node.layout.anchor = .relative; // children flow by default; override with `with_layout`
    return node;
}

// -- Roots & content leaves ------------------------------------------------------------

/// A fullscreen root sized to the live window — the anchor box a screen positions against.
/// A root has no parent and stays non-relative (`.top_left`). Replaces the old `ui_root`.
pub fn root(ctx: *UiCtx, id: []const u8) !El {
    const ww, const wh = try ctx.res.window.getSize();
    const node = try Node.create(ctx.arena, id);
    node.size = ui.features.Size.initFixed(@floatFromInt(ww), @floatFromInt(wh));
    return .{ .ctx = ctx, .node = node };
}

/// A box holding no content — use it to manage placement (a row/column container).
pub fn div(ctx: *UiCtx, parent: anytype, id: []const u8) !El {
    return .{ .ctx = ctx, .node = try child(ctx, parent, id) };
}

/// A content-sized text node holding `str` (measured at the default font; recolor/resize
/// with `with_style`).
pub fn text(ctx: *UiCtx, parent: anytype, id: []const u8, str: []const u8) !El {
    const node = try child(ctx, parent, id);
    try feat.data_text(ctx, node, str);
    return .{ .ctx = ctx, .node = node };
}

/// A whole-texture image node, sized to the texture.
pub fn image(ctx: *UiCtx, parent: anytype, id: []const u8, texture: sdl.render.Texture) !El {
    const node = try child(ctx, parent, id);
    try feat.data_img(ctx, node, texture);
    return .{ .ctx = ctx, .node = node };
}

/// One `src` cell of a sprite sheet, drawn at `px`×`px`.
pub fn sprite(ctx: *UiCtx, parent: anytype, id: []const u8, spr: Sprite, px: f32) !El {
    const node = try child(ctx, parent, id);
    try feat.data_sprite(ctx, node, spr, px);
    return .{ .ctx = ctx, .node = node };
}

/// A cached SVG raster from `path`, drawn at `px`×`px` (recolor the tint with `with_style`).
pub fn svg(ctx: *UiCtx, parent: anytype, id: []const u8, path: [:0]const u8, px: f32) !El {
    const node = try child(ctx, parent, id);
    try feat.data_svg(ctx, node, path, px);
    return .{ .ctx = ctx, .node = node };
}

// -- el: sugar composing a content leaf + a style spec in one call. --------------------

/// What an `el` draws — the content variant it dispatches to a leaf. The image/svg/sprite
/// variants carry their per-call data; reusable *style* rides in the separate `spec` arg.
pub const Content = union(enum) {
    text: []const u8,
    image: sdl.render.Texture,
    sprite: struct { spr: Sprite, px: f32 },
    svg: struct { path: [:0]const u8, px: f32 },
};

/// One-call sugar over `leaf + with_style` (style only; chain placement after). `spec` is
/// the usual style fragment tuple (`.{}` for none).
pub fn el(ctx: *UiCtx, parent: anytype, id: []const u8, content: Content, spec: anytype) !El {
    const e: El = switch (content) {
        .text => |s| try text(ctx, parent, id, s),
        .image => |t| try image(ctx, parent, id, t),
        .sprite => |s| try sprite(ctx, parent, id, s.spr, s.px),
        .svg => |s| try svg(ctx, parent, id, s.path, s.px),
    };
    return e.with_style(spec);
}

test {
    std.testing.refAllDecls(@This());
}
