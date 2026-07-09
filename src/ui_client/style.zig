//! The composable **style** layer — the "how a node looks" layer (colors, font, padding).
//! A `Style` is a *partial* (every field optional); presets compose from a tuple by a
//! last-non-null-wins fold, CSS-like:
//!
//!   el.text(ctx, p, "t", "Hi")).with_style(.{ h1, red });  // → font 42, text red
//!
//! A fragment is a `Style` value **or** a `fn(*UiCtx, *Node) Style` — the function form is
//! resolved with the just-built node, so interaction-aware chrome (a button's hover color)
//! can read `node.query(ctx)` itself.
//!
//! **Placement is deliberately not here.** Where a node sits and how it arranges children
//! (anchor / children direction / gap / size / overflow) is an *imperative* concern set
//! straight onto the node's `Layout`/`Size` via the `El` handle's `with_layout` /
//! `with_gap` / `with_size` / `with_overflow` methods (`elements.zig`) — no parallel
//! "Placement" struct folding over the engine's values. Style and placement stay apart.

const std = @import("std");
const ui = @import("../ui/root.zig");
const cb = @import("./ctx_binding.zig");

const UiCtx = cb.UiCtx;
const Node = cb.Node;
const Color = cb.Color;

/// A partial style descriptor — every field optional, so an unset field composes as
/// "leave whatever an earlier fragment (or the default) set". Colors are the host's
/// `Color` (SDL's); `font` is a point size (px) the content builder measures text at.
pub const Style = struct {
    font: ?f32 = null,
    text: ?Color = null,
    fill: ?Color = null,
    outline: ?Color = null,
    padding: ?ui.Padding = null,
    gap: ?f32 = null,
};

pub const debug: Style = .{ .outline = .{ .a = 0.0, .r = 1.0, .g = 0.0, .b = 0.0 } };

// A generic typography scale (font size only — colors are game art direction and live
// with the theme/templates). Tunable; `body` matches `font.default_px`.
pub const body: Style = .{ .font = 14 };
pub const h3: Style = .{ .font = 22 };
pub const h2: Style = .{ .font = 28 };
pub const h1: Style = .{ .font = 36 };

/// Padding as a style fragment (padding is a `Style` field — a visual inset). Lets a caller
/// set padding without naming `ui.Padding`, keeping the game off the engine surface.
pub fn pad(n: f32) Style {
    return .{ .padding = ui.Padding.init(n) };
}
pub fn pad_sym(w: f32, h: f32) Style {
    return .{ .padding = ui.Padding.initSymmetric(w, h) };
}

// Gap as a style fragment. Lets a caller set the spacing between children elements
pub fn gap(n: f32) Style {
    return .{ .gap = n };
}

/// Copy each *set* field of `frag` onto `out` — the last-non-null-wins step of the fold.
fn merge(out: *Style, frag: Style) void {
    inline for (std.meta.fields(Style)) |f| {
        if (@field(frag, f.name)) |v| @field(out, f.name) = v;
    }
}

/// Fold a style spec into a single `Style`. `spec` is one fragment or a (possibly nested)
/// tuple of fragments; each fragment is a `Style` value or a `fn(*UiCtx, *Node) Style`
/// (called with the node, so it can read interaction/theme). Later fragments win per field.
pub fn resolve(ctx: *UiCtx, node: *Node, spec: anytype) Style {
    var out: Style = .{};
    fold(ctx, node, &out, spec);
    return out;
}

fn fold(ctx: *UiCtx, node: *Node, out: *Style, frag: anytype) void {
    const T = @TypeOf(frag);
    if (T == Style) return merge(out, frag);
    switch (@typeInfo(T)) {
        .@"fn" => merge(out, frag(ctx, node)), // fn value fragment
        .pointer => |p| if (@typeInfo(p.child) == .@"fn")
            merge(out, frag(ctx, node)) // fn-pointer fragment
        else
            @compileError("style fragment: unexpected pointer " ++ @typeName(T)),
        .@"struct" => |s| if (s.is_tuple) {
            inline for (s.fields) |f| fold(ctx, node, out, @field(frag, f.name));
        } else @compileError("style fragment must be `Style` or a tuple of fragments; got " ++ @typeName(T)),
        else => @compileError("unsupported style fragment: " ++ @typeName(T)),
    }
}

/// Resolve `spec` and write it onto `node`. Decorations (`fill`/`outline`) and `padding`
/// write unconditionally (a decoration is present iff set). For a **text** node (detected by
/// the `text` aspect the content leaf flagged), a `text` color recolors the glyphs and a
/// `font` size re-measures them at that size — the leaf measured at the default, so a heading
/// re-measures, and the new `px` is stored on the text state so `draw` renders at it. On a
/// non-text node, `font`/`text` are inert; a debug-only assert catches that mistake. Called
/// by `El.with_style`, so it runs after the content leaf (aspect + text state exist).
pub fn apply(ctx: *UiCtx, node: *Node, spec: anytype) void {
    const s = resolve(ctx, node, spec);
    if (s.fill) |c| node.render_data.fill = c;
    if (s.outline) |c| node.render_data.outline = c;
    if (s.padding) |p| node.size.padding = p;
    if (s.gap) |g| node.layout.gap = g;

    if (node.render_data.text != null) {
        if (s.text) |c| node.render_data.text = c;
        if (s.font) |px| {
            const st = node.state(ctx, cb.UiState.TextState);
            if (st.text()) |str| {
                const tw, const th = ctx.res.font.measure(str, px) catch return;
                node.size.data_width = @floatFromInt(tw);
                node.size.data_height = @floatFromInt(th);
                st.px = px; // set only on a successful re-measure, so box + render agree
            }
        }
    } else {
        std.debug.assert(s.text == null and s.font == null); // inert text style on a non-text node
    }
}

// ============================ Tests ==========================================

test "style: single fragment resolves its fields" {
    const s = resolve(undefined, undefined, h1);
    try std.testing.expectEqual(@as(?f32, 36), s.font);
    try std.testing.expectEqual(@as(?Color, null), s.text);
}

test "style: tuple folds left→right, last non-null field wins" {
    const red: Color = .{ .r = 200, .g = 40, .b = 40, .a = 255 };
    const s = resolve(undefined, undefined, .{ h1, Style{ .font = 10, .text = red } });
    try std.testing.expectEqual(@as(?f32, 10), s.font); // overridden
    try std.testing.expectEqual(red, s.text.?); // added
}

test "style: a function fragment is called and merged" {
    const S = struct {
        fn tint(_: *UiCtx, _: *Node) Style {
            return .{ .fill = .{ .r = 1, .g = 2, .b = 3, .a = 4 } };
        }
    };
    const s = resolve(undefined, undefined, .{ h2, S.tint });
    try std.testing.expectEqual(@as(?f32, 28), s.font); // from h2
    try std.testing.expectEqual(@as(u8, 2), s.fill.?.g); // from the fn fragment
}

test "apply: decorations + padding write; inert text style on a non-text node is allowed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const node = try Node.create(arena.allocator(), "n");

    const line: Color = .{ .r = 10, .g = 20, .b = 30, .a = 255 };
    apply(undefined, node, .{ Style{ .outline = line }, pad(4) });
    try std.testing.expectEqual(line, node.render_data.outline.?);
    try std.testing.expectEqual(@as(f32, 4), node.size.padding.left);
}
