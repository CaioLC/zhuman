//! The composable **style** and **placement** layers — the second and third of the UI's
//! four layers (content / style / layout / behavior). Both are *partials* (structs of
//! optional fields, unset = "leave alone") composed from a tuple by a last-non-null-wins
//! fold, exactly like CSS `class="h1 red"`:
//!
//!   resolve(ctx, node, .{ h1, red })        // → Style{ .font = 42, .text = <red> }
//!   apply_placement(node, .{ row, gap(8) }) // → children flow horizontally, gap 8
//!
//! **Style** (`font`/`text`/`fill`/`outline`/`padding`) is *how a node looks*; a fragment
//! is a `Style` value **or** a function `fn(*UiCtx, *Node) Style` — the function form is
//! resolved with the just-built node, so an interaction-aware fragment (a button's
//! hover chrome) can read `node.query(ctx)` itself. **Placement** (`anchor`/`children`/
//! `gap`/`w`/`h`/`overflow`) is *where a node sits and how it arranges children*; its
//! fragments are plain values (placement never depends on the node), with parameterized
//! ones exposed as functions evaluated at the call site (`gap(8)`).
//!
//! This module is pure composition machinery: it folds specs and writes *placement* onto
//! a node. Writing *style* onto a node is entangled with content (text must be re-measured
//! at the resolved `font`), so that lives in the element constructor (`el`, Phase 4) which
//! has the content on hand — here we only `resolve` a Style to a value.

const std = @import("std");
const ui = @import("../ui/root.zig");
const cb = @import("./ctx_binding.zig");

const UiCtx = cb.UiCtx;
const Node = cb.Node;
const Color = cb.Color;

// ============================ Style (the "how it looks" layer) ================

/// A partial style descriptor — every field optional, so an unset field composes as
/// "leave whatever an earlier fragment (or the default) set". Colors are the host's
/// `Color` (SDL's); `font` is a point size (px) the content builder measures text at.
pub const Style = struct {
    font: ?f32 = null,
    text: ?Color = null,
    fill: ?Color = null,
    outline: ?Color = null,
    padding: ?ui.Padding = null,
};

// A generic typography scale (font size only — colors are game art direction and live
// with the theme/templates). Tunable; `body` matches `font.default_px`.
pub const body: Style = .{ .font = 24 };
pub const h3: Style = .{ .font = 28 };
pub const h2: Style = .{ .font = 34 };
pub const h1: Style = .{ .font = 42 };

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

/// Resolve `spec` and write it onto `node` — the style layer's node-application step
/// (its content-aware half, unlike `apply_placement`). Decorations (`fill`/`outline`)
/// and `padding` write unconditionally (a decoration is present iff set). For a **text**
/// node (detected by the `text` aspect the content leaf already flagged), a `text` color
/// recolors the glyphs and a `font` size re-measures them at that size — the leaf measured
/// at the default, so a heading has to re-measure, and the new `px` is stored on the text
/// state so `draw` renders at it. On a non-text node, `font`/`text` are inert; a
/// debug-only assert catches that mistake (compiled out in release — see the plan's
/// "failure modes"). Call *after* the content leaf, so the aspect + text state exist.
pub fn apply(ctx: *UiCtx, node: *Node, spec: anytype) void {
    const s = resolve(ctx, node, spec);
    if (s.fill) |c| node.render_data.fill = c;
    if (s.outline) |c| node.render_data.outline = c;
    if (s.padding) |p| node.size.padding = p;

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

// ============================ Placement (the "where it sits" layer) ===========

/// A partial placement descriptor — the layout/size fields a preset touches, each
/// optional (unset = leave the node's current value). Spans both `Layout` (`anchor`,
/// `children`, `gap`, `overflow`) and `Size` (`w`, `h`) since "how a node is placed"
/// covers both. Padding is intentionally *not* here — it's a `Style` field (visual inset).
pub const Placement = struct {
    anchor: ?ui.Anchor = null,
    children: ?ui.ChildrenAlign = null,
    gap: ?f32 = null,
    w: ?ui.SizeRule = null,
    h: ?ui.SizeRule = null,
    overflow: ?ui.features.Overflow = null,
};

/// A child that flows in its parent's layout (`children_align`), rather than anchoring
/// itself. Most content nodes want this — the engine's default anchor is `.top_left`
/// (self-positioned), so a flowed child must opt in. (A *root* must stay non-relative.)
pub const flow: Placement = .{ .anchor = .relative };
pub const row: Placement = .{ .children = .horizontal };
pub const col: Placement = .{ .children = .vertical };
pub const fit: Placement = .{ .w = .fit_children, .h = .fit_children };
pub const fill: Placement = .{ .w = .{ .pct_of_parent = 1 }, .h = .{ .pct_of_parent = 1 } };
pub const center: Placement = .{ .anchor = .center };
pub const clip: Placement = .{ .overflow = .clip };

/// Parameterized presets — evaluated at the call site to a `Placement` value.
pub fn gap(n: f32) Placement {
    return .{ .gap = n };
}
pub fn fixed(w: f32, h: f32) Placement {
    return .{ .w = .{ .fixed = w }, .h = .{ .fixed = h } };
}

fn merge_placement(out: *Placement, frag: Placement) void {
    inline for (std.meta.fields(Placement)) |f| {
        if (@field(frag, f.name)) |v| @field(out, f.name) = v;
    }
}

/// Fold a placement spec into a single `Placement`. `spec` is one `Placement` value or a
/// (possibly nested) tuple of them; later fragments win per field. No `fn` form — placement
/// never depends on the node, so parameterized presets (`gap(8)`) evaluate at the call site.
pub fn resolve_placement(spec: anytype) Placement {
    var out: Placement = .{};
    fold_placement(&out, spec);
    return out;
}

fn fold_placement(out: *Placement, frag: anytype) void {
    const T = @TypeOf(frag);
    if (T == Placement) return merge_placement(out, frag);
    switch (@typeInfo(T)) {
        .@"struct" => |s| if (s.is_tuple) {
            inline for (s.fields) |f| fold_placement(out, @field(frag, f.name));
        } else @compileError("placement fragment must be `Placement` or a tuple; got " ++ @typeName(T)),
        else => @compileError("unsupported placement fragment: " ++ @typeName(T)),
    }
}

/// Resolve `spec` and write each set field onto `node`'s layout/size. Content-agnostic
/// (placement never touches a payload), so it's the whole placement layer — unlike style,
/// which the content builder finishes (measuring text at the resolved `font`).
pub fn apply_placement(node: *Node, spec: anytype) void {
    const p = resolve_placement(spec);
    if (p.anchor) |a| node.layout.anchor = a;
    if (p.children) |c| node.layout.children_align = c;
    if (p.gap) |g| node.layout.gap = g;
    if (p.overflow) |o| node.layout.overflow = o;
    if (p.w) |w| node.size.w = w;
    if (p.h) |h| node.size.h = h;
}

// ============================ Tests ==========================================

test "style: single fragment resolves its fields" {
    const s = resolve(undefined, undefined, h1);
    try std.testing.expectEqual(@as(?f32, 42), s.font);
    try std.testing.expectEqual(@as(?Color, null), s.text);
}

test "style: tuple folds left→right, last non-null field wins" {
    const red: Color = .{ .r = 200, .g = 40, .b = 40, .a = 255 };
    // h1 sets font; the second fragment overrides font and adds a text color.
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
    try std.testing.expectEqual(@as(?f32, 34), s.font); // from h2
    try std.testing.expectEqual(@as(u8, 2), s.fill.?.g); // from the fn fragment
}

test "apply: decorations + padding write; inert text style on a non-text node is allowed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const node = try Node.create(arena.allocator(), "n");

    // No text aspect on this node, and no text/font in the spec, so the inert-guard holds.
    // (ctx is unused on this path — decorations/padding need neither font nor content.)
    const line: Color = .{ .r = 10, .g = 20, .b = 30, .a = 255 };
    apply(undefined, node, .{ Style{ .outline = line }, Style{ .padding = ui.Padding.init(4) } });
    try std.testing.expectEqual(line, node.render_data.outline.?);
    try std.testing.expectEqual(@as(f32, 4), node.size.padding.left);
}

test "placement: tuple folds; apply writes onto the node" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const node = try Node.create(arena.allocator(), "n");

    apply_placement(node, .{ col, gap(8), fit });
    try std.testing.expectEqual(ui.ChildrenAlign.vertical, node.layout.children_align);
    try std.testing.expectEqual(@as(f32, 8), node.layout.gap);
    try std.testing.expectEqual(ui.SizeRule.fit_children, node.size.w);
    try std.testing.expectEqual(ui.SizeRule.fit_children, node.size.h);
}
