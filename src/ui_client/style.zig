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
const typ = @import("./type.zig");
const view = @import("./view.zig");

const UiCtx = cb.UiCtx;
const Node = cb.Node;
const Color = cb.Color;

/// A partial style descriptor — every field optional, so an unset field composes as
/// "leave whatever an earlier fragment (or the default) set". Colors are the host's
/// `Color` (SDL's); `font` is a **logical** px size the content builder measures text at
/// (multiplied by the frame `scale` through `type.toDevice` at `apply` time — the one
/// logical→device seam). `tracking` is letter-spacing in `em` and `transform` is a case
/// rule; both are the TEXT-04 typography payload and, like every field here, fold
/// last-non-null-wins so a role fragment sets them and a later fragment can override.
pub const Style = struct {
    font: ?f32 = null,
    text: ?Color = null,
    /// Letter-spacing in `em` (negative = tighter, positive = looser). Resolved to an integer
    /// device-px delta at `apply` time (`type.deviceTracking` at the device size) and stored
    /// on `TextState.tracking`. Unset composes as "inherit"; the roles set the contract's
    /// values (global -0.025em, heading -0.04em, eyebrow +0.07em).
    tracking: ?f32 = null,
    /// Case transform (`.none`/`.upper`) applied to the rendered bytes at `apply` time. Unset
    /// composes as "inherit". Only the uppercase eyebrow role sets `.upper`.
    transform: ?typ.Transform = null,
    /// **Texture-content ink** (RENDER-02): the tint a *non-text* content aspect paints with.
    /// Today that is `svg` (an icon raster is rasterized white and tinted at blit, the
    /// `svg.draw`/`text` composite model), so a set `tint` recolors `render_data.svg`. It is a
    /// separate field from `text` on purpose — `text` is *glyph* ink and `tint` is *texture*
    /// ink, so a tuple can carry both without either shadowing the other, and each folds
    /// last-non-null-wins independently. Unset composes as "inherit whatever the content
    /// leaf/theme defaulted" (an `svg` leaf defaults its ink to `theme.fg`). Placement
    /// (wrap/overflow) stays imperative on `El`; this is a look, not a measurement constraint.
    tint: ?Color = null,
    fill: ?Color = null,
    /// Border color. Its presence is what makes a border draw; `outline_width` /
    /// `outline_style` only shape a border that a set `outline_color` turned on. Kept as
    /// three CSS-like fields (color / width / style) rather than one bundle so each folds
    /// independently — one fragment can set the color, a later one flip it to dashed.
    outline_color: ?Color = null,
    outline_width: ?f32 = null,
    outline_style: ?cb.LineStyle = null,
    padding: ?ui.Padding = null,
    gap: ?f32 = null,
};

// A bright-red debug outline around any node. `Color` is SDL's `SDL_Color` — u8 fields on
// a 0–255 scale, so the outline must be `a = 255` (opaque) and `r = 255` (full red); the
// earlier `a = 0.0, r = 1.0` read as 0–1 floats and coerced to a=0 (transparent), r=1 (~black).
pub const debug: Style = .{ .outline_color = .{ .r = 255, .g = 0, .b = 0, .a = 255 } };

// Every scalar below is authored at one reference resolution; the responsive scale factor
// (`View.scale`, VIEW-01) is applied at `apply` time through `type.toDevice` — the single
// logical→device multiply point.

// The prototype typography contract lives in `type.zig` (sizes/tracking/transform, all
// regular weight); the presets below are the *style-fragment* projection of those roles, so
// a call site composes `.{ style.heading, ... }` while the numbers stay in one place.

/// What a text leaf renders at when nothing styles it — the base of the ladder below, and
/// the size `text.attach` seeds onto a fresh node. Defined *from* the `body` role's logical
/// size so "unstyled" and "explicitly body" can never drift apart.
pub const default_font: f32 = typ.default_logical_px;

/// Turn a `type.Role` into a composable style fragment (logical size + tracking + transform).
fn role(r: typ.Role) Style {
    return .{ .font = r.size_logical_px, .tracking = r.tracking_em, .transform = r.transform };
}

pub const body: Style = role(typ.body);
pub const small: Style = role(typ.small);
/// The prototype heading (`--h3`, 21 logical px, -0.04em). `h3` is retained as an alias so
/// existing call sites keep compiling; new sites should prefer `heading`.
pub const heading: Style = role(typ.heading);
pub const h3: Style = heading;
/// Uppercase eyebrow / section label — 11px, UPPERCASE, +0.07em tracking.
pub const eyebrow: Style = role(typ.eyebrow);

// Legacy above-contract display sizes used by the mock showcase / Act curtain / capital
// header. They are **not** part of the prototype body/small/heading contract; they inherit
// the global tracking unless a fragment overrides it. Kept so those sites keep compiling.
pub const h2: Style = .{ .font = 28, .tracking = typ.body.tracking_em };
pub const h1: Style = .{ .font = 36, .tracking = typ.body.tracking_em };

/// Padding as a style fragment (padding is a `Style` field — a visual inset). Lets a caller
/// set padding without naming `ui.Padding`, keeping the game off the engine surface.
pub fn pad(n: f32) Style {
    return .{ .padding = ui.Padding.init(n) };
}
pub fn pad_sym(w: f32, h: f32) Style {
    return .{ .padding = ui.Padding.initSymmetric(w, h) };
}
pub fn pad_each(up: f32, right: f32, down: f32, left: f32) Style {
    return .{ .padding = ui.Padding.initEach(up, right, down, left) };
}

// Gap as a style fragment. Lets a caller set the spacing between children elements
pub fn gap(n: f32) Style {
    return .{ .gap = n };
}

// --- Outline fragments -------------------------------------------------------
// Border thickness as a style fragment (only visible once an `outline_color` is also set).
pub fn stroke_w(n: f32) Style {
    return .{ .outline_width = n };
}
// Border pattern fragments — compose after an `outline_color` to shape it.
pub const solid: Style = .{ .outline_style = .solid };
pub const dashed: Style = .{ .outline_style = .dashed };
pub const dotted: Style = .{ .outline_style = .dotted };

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
    // A set `outline_color` turns the border on; width/style shape it (defaults 1px solid).
    if (s.outline_color) |c| node.render_data.outline = .{
        .color = c,
        .width = s.outline_width orelse 1,
        .style = s.outline_style orelse .solid,
    };
    // VIEW-02: padding and gap are authored in *logical* px; scale to device by the frame
    // scale (`view.dp`) to match the device-px layout and text boxes. `outline_width` is NOT
    // scaled here — it is scaled at draw by `paint.hairline` (RENDER-06), so scaling it here
    // too would double-apply.
    if (s.padding) |p| {
        const sc = ctx.res.view.scale;
        node.size.padding = .{
            .up = view.dp(p.up, sc),
            .right = view.dp(p.right, sc),
            .down = view.dp(p.down, sc),
            .left = view.dp(p.left, sc),
        };
    }
    if (s.gap) |g| node.layout.gap = view.dp(g, ctx.res.view.scale);

    // RENDER-02: texture-content ink. A set `tint` recolors a present `svg` aspect (an icon
    // raster tinted at blit), routed through the same fragment fold as every other look — so
    // a caller styles an icon's color instead of poking `render_data.svg` directly.
    if (node.render_data.svg != null) {
        if (s.tint) |c| node.render_data.svg = c;
    }

    if (node.render_data.text != null) {
        if (s.text) |c| node.render_data.text = c;
        // The typography payload (size / tracking / transform) is applied together and then
        // re-measured **once** through the one shared routine, so the reserved box always
        // matches the spaced/transformed glyphs `draw` will place — the TEXT-01..03
        // "measure and draw read one source" invariant, extended to TEXT-04 tracking/case.
        const wants_type = s.font != null or s.tracking != null or s.transform != null;
        if (wants_type) {
            const st = node.state(ctx, cb.UiState.TextState);
            if (st.text()) |_| {
                // Case transform first — it may rewrite the buffer bytes, and everything
                // downstream (measure, wrap, clip, draw) reads `st.text()`. ASCII fold keeps
                // byte length/offsets, so wrap/clip byte math is unaffected.
                if (s.transform) |t| applyTransformInPlace(st, t);
                // Size: logical → device through the single `type.toDevice` seam (frame scale).
                if (s.font) |logical_px| st.px = typ.toDevice(logical_px, ctx.res.view.scale);
                // Tracking: em → integer device-px delta at the (now-final) device size. Stored
                // as POD device px so measure and draw add the identical gap between clusters.
                if (s.tracking) |em| st.tracking = typ.deviceTracking(em, st.px);
                // Re-measure at the final px + tracking (and re-wrap at the same constraint if
                // `wrap_width` is set). Box + render agree.
                @import("features/text.zig").remeasure(ctx, node);
            }
        }
    } else {
        // Typography style (`text`/`font`/`tracking`/`transform`) is inert on a non-text node
        // — catch that mistake in debug. `tint` is *not* typography: it legitimately targets a
        // non-text (svg) aspect and is allowed here (it simply no-ops on a node with no svg,
        // like any unmatched decoration). So the assert covers only the genuinely-inert set.
        std.debug.assert(s.text == null and s.font == null and s.tracking == null and s.transform == null);
    }
}

/// Apply a case transform to a `TextState`'s buffer in place (TEXT-04). The uppercase fold is
/// ASCII-only and length-preserving, so byte offsets used by wrap/clip/ellipsis stay valid,
/// and `text()`'s length/`refused` invariants are untouched (we rewrite bytes, never the
/// length). A `.none` transform is a no-op. Idempotent: re-applying is safe if `apply` runs
/// more than once for the same node/frame.
fn applyTransformInPlace(st: *cb.UiState.TextState, t: typ.Transform) void {
    const cur = st.text() orelse return;
    var tmp: [cb.UiState.TextState.cap]u8 = undefined;
    const out = typ.applyTransform(t, cur, tmp[0..cur.len]);
    // `applyTransform` returns `cur` unchanged for `.none` or a too-small buffer; only copy
    // back when a real transform produced new bytes of the same length.
    if (out.ptr != cur.ptr) @memcpy(st.buf[0..out.len], out);
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

    // VIEW-02: `apply` scales padding/gap by `ctx.res.view.scale`, so give it a real ctx with
    // the default view (scale 1) rather than `undefined`.
    var resources: @import("../res.zig").Resources = undefined;
    resources.view = .{};
    var ctx = cb.UiCtx.init(&resources, std.testing.allocator, arena.allocator());
    defer ctx.deinit();

    const line: Color = .{ .r = 10, .g = 20, .b = 30, .a = 255 };
    apply(&ctx, node, .{ Style{ .outline_color = line }, pad(4) });
    try std.testing.expectEqual(line, node.render_data.outline.?.color);
    try std.testing.expectEqual(@as(f32, 1), node.render_data.outline.?.width); // default thickness
    try std.testing.expectEqual(cb.LineStyle.solid, node.render_data.outline.?.style); // default pattern
    try std.testing.expectEqual(@as(f32, 4), node.size.padding.left);
}

test "apply: outline width + style fragments compose onto the border payload" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const node = try Node.create(arena.allocator(), "n");

    const line: Color = .{ .r = 10, .g = 20, .b = 30, .a = 255 };
    apply(undefined, node, .{ Style{ .outline_color = line }, stroke_w(3), dashed });
    const o = node.render_data.outline.?;
    try std.testing.expectEqual(line, o.color);
    try std.testing.expectEqual(@as(f32, 3), o.width);
    try std.testing.expectEqual(cb.LineStyle.dashed, o.style);
}

test "apply: outline width/style without a color draw nothing (no border)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const node = try Node.create(arena.allocator(), "n");

    apply(undefined, node, .{ stroke_w(3), dotted }); // no outline_color ⟹ no border
    try std.testing.expectEqual(@as(?cb.Outline, null), node.render_data.outline);
}

// ---- TEXT-04 typography roles ----------------------------------------------------------

test "style: default_font equals the body role's logical size (unstyled == body)" {
    try std.testing.expectEqual(typ.default_logical_px, default_font);
    try std.testing.expectEqual(@as(f32, 14), default_font);
    // The `body` fragment carries exactly the contract triple.
    const s = resolve(undefined, undefined, body);
    try std.testing.expectEqual(@as(?f32, 14), s.font);
    try std.testing.expectEqual(@as(?f32, -0.025), s.tracking);
    try std.testing.expectEqual(typ.Transform.none, s.transform.?);
}

test "style: role fragments carry the prototype contract (size + tracking + transform)" {
    const sb = resolve(undefined, undefined, small);
    try std.testing.expectEqual(@as(?f32, 11), sb.font);
    try std.testing.expectEqual(@as(?f32, -0.025), sb.tracking);

    const sh = resolve(undefined, undefined, heading);
    try std.testing.expectEqual(@as(?f32, 21), sh.font); // the prototype --h3
    try std.testing.expectEqual(@as(?f32, -0.04), sh.tracking);
    // `h3` is a retained alias for `heading`.
    const s3 = resolve(undefined, undefined, h3);
    try std.testing.expectEqual(sh.font, s3.font);
    try std.testing.expectEqual(sh.tracking, s3.tracking);

    const se = resolve(undefined, undefined, eyebrow);
    try std.testing.expectEqual(@as(?f32, 11), se.font);
    try std.testing.expectEqual(typ.Transform.upper, se.transform.?);
    try std.testing.expect(se.tracking.? >= typ.eyebrow_tracking_min);
    try std.testing.expect(se.tracking.? <= typ.eyebrow_tracking_max);
}

test "style: a later fragment overrides a role's tracking/transform (last-wins fold)" {
    // RENDER-02 payload composes for free through the field-wise merge — a caller can take
    // the eyebrow role but override its tracking, or drop the uppercase transform.
    const s = resolve(undefined, undefined, .{ eyebrow, Style{ .tracking = 0.05, .transform = .none } });
    try std.testing.expectEqual(@as(?f32, 11), s.font); // kept from eyebrow
    try std.testing.expectEqual(@as(?f32, 0.05), s.tracking); // overridden
    try std.testing.expectEqual(typ.Transform.none, s.transform.?); // overridden
}

test "applyTransformInPlace: uppercases the buffer in place, preserving length; none is a no-op" {
    var st = cb.UiState.TextState.init();
    try std.testing.expect(st.update("In Reach"));
    applyTransformInPlace(&st, .upper);
    try std.testing.expectEqualStrings("IN REACH", st.text().?);
    // Idempotent + length-preserving (byte offsets used by wrap/clip stay valid).
    applyTransformInPlace(&st, .upper);
    try std.testing.expectEqualStrings("IN REACH", st.text().?);
    try std.testing.expectEqual(@as(usize, "In Reach".len), st.text().?.len);
    // `.none` leaves the buffer untouched.
    applyTransformInPlace(&st, .none);
    try std.testing.expectEqualStrings("IN REACH", st.text().?);
}

// ---- RENDER-02 texture-content tint ----------------------------------------------------

test "style: tint folds last-non-null-wins independently of text" {
    const red: Color = .{ .r = 200, .g = 40, .b = 40, .a = 255 };
    const blue: Color = .{ .r = 40, .g = 40, .b = 200, .a = 255 };
    // `tint` and `text` are separate fields — a tuple can carry both, neither shadows the
    // other, and each folds last-non-null-wins on its own.
    const s = resolve(undefined, undefined, .{ Style{ .tint = red, .text = blue }, Style{ .tint = blue } });
    try std.testing.expectEqual(blue, s.tint.?); // tint overridden by the later fragment
    try std.testing.expectEqual(blue, s.text.?); // text kept from the first fragment
}

test "apply: tint recolors a present svg aspect (RENDER-02) and is inert without one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const accent: Color = .{ .r = 90, .g = 150, .b = 210, .a = 255 };

    // A node with a present `svg` aspect (an icon leaf sets this): `tint` recolors it. No
    // ctx is dereferenced on this path (no text node), matching the other apply tests.
    const icon = try Node.create(arena.allocator(), "icon");
    icon.render_data.svg = .{ .r = 220, .g = 220, .b = 220, .a = 255 }; // default fg-ish ink
    apply(undefined, icon, .{Style{ .tint = accent }});
    try std.testing.expectEqual(accent, icon.render_data.svg.?);

    // On a node with no svg aspect, `tint` simply no-ops (like any unmatched decoration) and
    // does not trip the inert-typography assert — it is not typography.
    const bare = try Node.create(arena.allocator(), "bare");
    apply(undefined, bare, .{Style{ .tint = accent }});
    try std.testing.expectEqual(@as(?Color, null), bare.render_data.svg);
    try std.testing.expectEqual(@as(?Color, null), bare.render_data.text);
}

test "apply: tint does not disturb text ink; text ink does not disturb svg tint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tint_c: Color = .{ .r = 1, .g = 2, .b = 3, .a = 255 };
    // Tinting an svg node sets only its svg ink; the glyph-ink `text` field is left null
    // (the two are orthogonal fields, so an icon tint never leaks into text ink).
    const icon = try Node.create(arena.allocator(), "icon2");
    icon.render_data.svg = .{ .r = 9, .g = 9, .b = 9, .a = 255 };
    apply(undefined, icon, .{Style{ .tint = tint_c }});
    try std.testing.expectEqual(tint_c, icon.render_data.svg.?);
    try std.testing.expectEqual(@as(?Color, null), icon.render_data.text);
}
