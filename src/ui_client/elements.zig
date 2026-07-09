//! **Elements** — the *content* layer (first of the four: content / style / layout /
//! behavior). An element is a pure content leaf: it creates a node and sets *what* is in
//! it (a string, a texture, an svg) — nothing about how it looks or where it sits. Style
//! and placement compose onto it from the outside (`style.apply` / `style.apply_placement`),
//! so elements stay trivially composable and reusable. This is the foundation the
//! game-specific `pages/templates/` shelf builds its heavier, pre-styled pieces on.
//!
//! Primary idiom is the leaf + separate compose steps:
//!   const day = try elements.text(ctx, panel, "day", "Day 3");
//!   style.apply(ctx, day, .{ style.h2 });          // how it looks
//!   style.apply_placement(day, .{ style.flow });   // where it sits
//! `el` is sugar that does the same in one call for the common case.

const std = @import("std");
const sdl = @import("sdl3");
const cb = @import("./ctx_binding.zig");
const feat = @import("./features/root.zig");
const style = @import("./style.zig");

const UiCtx = cb.UiCtx;
const Node = cb.Node;
const Sprite = cb.Sprite;

// -- Content leaves: create a node + set its content. No style, no placement. ---------

/// A content-sized text node holding `str` (measured at the default font; recolor/resize
/// it with `style.apply`). Wired under `parent`/`id`; returns it for compose + query.
pub fn text(ctx: *UiCtx, parent: *Node, id: []const u8, str: []const u8) !*Node {
    const node = try Node.pcreate(ctx.arena, id, parent);
    try feat.data_text(ctx, node, str);
    return node;
}

/// A whole-texture image node, sized to the texture.
pub fn image(ctx: *UiCtx, parent: *Node, id: []const u8, texture: sdl.render.Texture) !*Node {
    const node = try Node.pcreate(ctx.arena, id, parent);
    try feat.data_img(ctx, node, texture);
    return node;
}

/// One `src` cell of a sprite sheet, drawn at `px`×`px`.
pub fn sprite(ctx: *UiCtx, parent: *Node, id: []const u8, spr: Sprite, px: f32) !*Node {
    const node = try Node.pcreate(ctx.arena, id, parent);
    try feat.data_sprite(ctx, node, spr, px);
    return node;
}

/// A cached SVG raster from `path`, drawn at `px`×`px` (recolor the tint with `style.apply`).
pub fn svg(ctx: *UiCtx, parent: *Node, id: []const u8, path: [:0]const u8, px: f32) !*Node {
    const node = try Node.pcreate(ctx.arena, id, parent);
    try feat.data_svg(ctx, node, path, px);
    return node;
}

// -- el: sugar composing a content leaf + style + placement in one call. --------------

/// What an `el` draws — the content variant it dispatches to a leaf. The image/svg/sprite
/// variants carry their per-call data (texture/path/size); a reusable *style* rides in the
/// separate `style` arg, never here.
pub const Content = union(enum) {
    text: []const u8,
    image: sdl.render.Texture,
    sprite: struct { spr: Sprite, px: f32 },
    svg: struct { path: [:0]const u8, px: f32 },
};

/// One-call sugar over `leaf + style.apply + style.apply_placement`. `style_spec` and
/// `place_spec` are the usual fragment tuples (`.{}` for none). Primary code is expected to
/// use the leaves + compose steps directly (they read clearer when layers are set
/// conditionally); `el` is for the terse, all-three-at-once common case.
pub fn el(
    ctx: *UiCtx,
    parent: *Node,
    id: []const u8,
    content: Content,
    style_spec: anytype,
    place_spec: anytype,
) !*Node {
    const node = switch (content) {
        .text => |s| try text(ctx, parent, id, s),
        .image => |t| try image(ctx, parent, id, t),
        .sprite => |s| try sprite(ctx, parent, id, s.spr, s.px),
        .svg => |s| try svg(ctx, parent, id, s.path, s.px),
    };
    style.apply(ctx, node, style_spec);
    style.apply_placement(node, place_spec);
    return node;
}

test {
    std.testing.refAllDecls(@This());
}
