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
const theme = @import("./theme.zig");

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

// === KIT-02 · primitive style/state fragments ===========================================
//
// The shared vocabulary of *look* every template composes from — surfaces, section labels,
// button variants, tabs/chips/tags, semantic state text, and small chrome (meter, progress,
// legend dot). Two flavors, both fed to the same fold (`resolve`/`apply`):
//
//   • **static** fragments are plain `Style` values (a panel fill, a tag border) — a look
//     with no interaction input.
//   • **stateful** fragments are `fn(*UiCtx, *Node) Style` — resolved *with the just-built
//     node*, so they read `node.query(ctx)` (hover / held / focus-visible / disabled /
//     selected — the `Interaction` bits `publishControlState` sets) and return the chrome for
//     that state. This is the KIT-02 seam KIT-03 leans on: a control publishes its state, and
//     the box paints itself from these fragments by composing e.g. `.{ btn_primary }`.
//
// Every color is a `Theme` *role* (never a literal), so a game palette moves them all at once;
// these fragments live in the foundation because they encode role/interaction policy, not the
// game's values. Precedence is the caller's: later fragments in the tuple win per field, so a
// site can take `btn_primary` and override just its fill.

/// A raised surface — panel fill + a hairline `line` edge. The card/rail/strip background.
pub fn panel(ctx: *UiCtx, _: *Node) Style {
    const t = ctx.res.view.theme;
    return .{ .fill = t.panel, .outline_color = t.line, .outline_width = 1 };
}

/// A section heading (the `heading` role in `acc` ink) — a titled block's lead line.
pub fn section_heading(ctx: *UiCtx, _: *Node) Style {
    var s = heading;
    s.text = ctx.res.view.theme.acc;
    return s;
}

// —— Buttons ————————————————————————————————————————————————————————————————————————————
// The whole outer box owns interaction (KIT-03); these paint it from the published state.
// A disabled control never brightens; otherwise held/hover/focus-visible lifts the ink to
// `acc`. They set only *look* (ink/fill/border); placement/padding stay imperative or come
// from a sibling `pad_*` fragment, so a variant is composable with any size.

/// Interaction ink for the button family: `dim` when disabled, `acc` when held/hovered/
/// focus-visible, else the resting color `rest`. The one place button state → color lives.
fn btn_ink(q: UiCtx.Interaction, t: theme.Theme, rest: Color) Color {
    if (q.disabled) return t.dim;
    if (q.held or q.hovering or q.focus_visible) return t.acc;
    return rest;
}

/// Primary button — a bordered box; text and border share the interaction ink (resting `fg`).
pub fn btn_primary(ctx: *UiCtx, node: *Node) Style {
    const t = ctx.res.view.theme;
    const c = btn_ink(node.query(ctx), t, t.fg);
    return .{ .text = c, .outline_color = c, .outline_width = 1 };
}

/// Secondary button — quieter: resting ink is `dim`, no border, brightening to `acc` on
/// hover/hold/focus like the others.
pub fn btn_secondary(ctx: *UiCtx, node: *Node) Style {
    const t = ctx.res.view.theme;
    return .{ .text = btn_ink(node.query(ctx), t, t.dim) };
}

/// Text button — borderless, resting `fg` ink; the affordance is the hover/focus lift alone.
pub fn btn_text(ctx: *UiCtx, node: *Node) Style {
    const t = ctx.res.view.theme;
    return .{ .text = btn_ink(node.query(ctx), t, t.fg) };
}

/// Icon button — tints a (white-rasterized) icon aspect by the same interaction ink, resting
/// `fg`. Uses `tint` (texture ink), not `text` (glyph ink), so it targets the svg cell.
pub fn btn_icon(ctx: *UiCtx, node: *Node) Style {
    const t = ctx.res.view.theme;
    return .{ .tint = btn_ink(node.query(ctx), t, t.fg) };
}

/// Link button — resting `acc` ink (a link reads as interactive at rest); dims when disabled,
/// no lift needed since it is already the accent.
pub fn btn_link(ctx: *UiCtx, node: *Node) Style {
    const t = ctx.res.view.theme;
    return .{ .text = if (node.query(ctx).disabled) t.dim else t.acc };
}

// —— Tabs / chips / tags ————————————————————————————————————————————————————————————————

/// A tab in a tablist — the *selected* tab paints `acc` ink + `acc` underline-weight border;
/// an unselected one is `dim`, lifting to `fg` on hover. Selection comes from the published
/// `.selected` bit (the tablist owner sets it).
pub fn tab(ctx: *UiCtx, node: *Node) Style {
    const t = ctx.res.view.theme;
    const q = node.query(ctx);
    if (q.selected) return .{ .text = t.acc, .outline_color = t.acc, .outline_width = 1 };
    return .{ .text = if (q.hovering or q.focus_visible) t.fg else t.dim };
}

/// A chip — a small filled `panel` pill with `line` edge and `fg` ink; `selected` accents its
/// border + ink. A compact toggle/filter affordance.
pub fn chip(ctx: *UiCtx, node: *Node) Style {
    const t = ctx.res.view.theme;
    const q = node.query(ctx);
    const edge = if (q.selected or q.hovering or q.focus_visible) t.acc else t.line;
    const ink = if (q.selected) t.acc else t.fg;
    return .{ .fill = t.panel, .outline_color = edge, .outline_width = 1, .text = ink };
}

/// A tag — a static (non-interactive) `line`-bordered label in `dim` ink: metadata, not a
/// control. A fn fragment (not a plain value) so its colors come from the live theme.
pub fn tag(ctx: *UiCtx, _: *Node) Style {
    const t = ctx.res.view.theme;
    return .{ .outline_color = t.line, .outline_width = 1, .text = t.dim };
}

// —— Semantic state text ————————————————————————————————————————————————————————————————
// A readout whose *color* carries meaning: a good value, a caution, a failure, or muted.
// These are the KIT-01 semantic roles projected to text ink, so a "+3 food" reads good and a
// "−2" reads danger without each call site naming a color.

pub fn state_good(ctx: *UiCtx, _: *Node) Style {
    return .{ .text = ctx.res.view.theme.good };
}
pub fn state_warn(ctx: *UiCtx, _: *Node) Style {
    return .{ .text = ctx.res.view.theme.warn };
}
pub fn state_danger(ctx: *UiCtx, _: *Node) Style {
    return .{ .text = ctx.res.view.theme.danger };
}
pub fn state_muted(ctx: *UiCtx, _: *Node) Style {
    return .{ .text = ctx.res.view.theme.dim };
}

// —— Interaction chrome fragments ————————————————————————————————————————————————————————

/// Row hover — a hovered/focus-visible list row lifts its fill to `panel` (a subtle wash);
/// at rest it paints nothing (transparent), so an idle row shows the surface beneath. Reads
/// the node's own interaction, so it works on any keyed row.
pub fn row_hover(ctx: *UiCtx, node: *Node) Style {
    const q = node.query(ctx);
    if (q.hovering or q.focus_visible) return .{ .fill = ctx.res.view.theme.panel };
    return .{};
}

/// Focus-visible outline — draws an `acc` ring **only** when the node's `.focus_visible` bit is
/// set (keyboard/AT focus), never on mere hover, so pointer users don't get a persistent ring.
/// The shared focus cue every control composes last.
pub fn focus_ring(ctx: *UiCtx, node: *Node) Style {
    if (node.query(ctx).focus_visible) return .{ .outline_color = ctx.res.view.theme.acc, .outline_width = 1 };
    return .{};
}

/// Disabled chrome — forces `dim` ink whenever the node's `.disabled` bit is set, overriding a
/// resting color. Compose *after* a variant so a disabled control can never read as active.
pub fn disabled_chrome(ctx: *UiCtx, node: *Node) Style {
    if (node.query(ctx).disabled) return .{ .text = ctx.res.view.theme.dim, .tint = ctx.res.view.theme.dim };
    return .{};
}

/// Selected chrome — an `acc` border + ink when the node's `.selected` bit is set (a chosen
/// list item, an active offer). Idle returns nothing.
pub fn selected_chrome(ctx: *UiCtx, node: *Node) Style {
    if (node.query(ctx).selected) return .{ .outline_color = ctx.res.view.theme.acc, .outline_width = 1, .text = ctx.res.view.theme.acc };
    return .{};
}

/// Dashed provisional chrome — a `dim` dashed border marking a not-yet-committed / placeholder
/// box (a build slot in reach, a provisional offer). Static: it is a look, not a state.
pub fn provisional(ctx: *UiCtx, _: *Node) Style {
    return .{ .outline_color = ctx.res.view.theme.dim, .outline_width = 1, .outline_style = .dashed };
}

// —— Small chrome: meter / progress / legend dot ————————————————————————————————————————
// These style the *track* and *fill* boxes a component lays out; the geometry (how wide the
// fill is) stays imperative on the node. A fragment only supplies the color contract.

/// A meter/track background — the inactive `line` bar behind a value fill. Pair with `meter_fill`.
pub fn meter_track(ctx: *UiCtx, _: *Node) Style {
    return .{ .fill = ctx.res.view.theme.line };
}
/// A meter fill — the filled portion, `acc`. The node's width encodes the value.
pub fn meter_fill(ctx: *UiCtx, _: *Node) Style {
    return .{ .fill = ctx.res.view.theme.acc };
}
/// A thin progress-bar fill — same `acc` fill; the "thin" is the node's height, set imperatively.
pub const progress_fill = meter_fill;

/// A resource legend dot — a filled swatch for one of the six resource hues (KIT-01,
/// `view.resources`). `which` picks the hue by field name so a legend cites the resource,
/// not a color: `.{ style.legend_dot(.food) }`.
pub const Resource = enum { food, water, fuel, metal, minerals, biomass };
pub fn legend_dot(comptime which: Resource) fn (*UiCtx, *Node) Style {
    return struct {
        fn frag(ctx: *UiCtx, _: *Node) Style {
            return .{ .fill = @field(ctx.res.view.resources, @tagName(which)) };
        }
    }.frag;
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

// ---- KIT-02 primitive style/state fragments --------------------------------------------

// A test harness: an arena, a real ctx, and a theme+resources installed on the view, so the
// stateful fragments resolve against known role colors and published interaction bits.
const KitFixture = struct {
    arena: std.heap.ArenaAllocator,
    resources: @import("../res.zig").Resources,
    ctx: UiCtx,

    fn init() !*KitFixture {
        const f = try std.testing.allocator.create(KitFixture);
        f.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        f.resources = undefined;
        f.resources.view = .{
            .theme = .{
                .fg = .{ .r = 1, .g = 1, .b = 1, .a = 255 },
                .dim = .{ .r = 2, .g = 2, .b = 2, .a = 255 },
                .acc = .{ .r = 3, .g = 3, .b = 3, .a = 255 },
                .line = .{ .r = 4, .g = 4, .b = 4, .a = 255 },
                .panel = .{ .r = 5, .g = 5, .b = 5, .a = 255 },
                .good = .{ .r = 6, .g = 6, .b = 6, .a = 255 },
                .warn = .{ .r = 7, .g = 7, .b = 7, .a = 255 },
                .danger = .{ .r = 8, .g = 8, .b = 8, .a = 255 },
            },
            .resources = .{ .food = .{ .r = 90, .g = 91, .b = 92, .a = 255 } },
        };
        f.ctx = UiCtx.init(&f.resources, std.testing.allocator, f.arena.allocator());
        return f;
    }
    fn deinit(f: *KitFixture) void {
        f.ctx.deinit();
        f.arena.deinit();
        std.testing.allocator.destroy(f);
    }
    fn node(f: *KitFixture, key: []const u8) !*Node {
        return Node.create(f.arena.allocator(), key);
    }
};

test "KIT-02 btn_primary: dim disabled, acc on hover/held/focus, else fg" {
    const f = try KitFixture.init();
    defer f.deinit();
    const th = f.resources.view.theme;

    // Resting: fg ink + fg border.
    const rest = try f.node("b_rest");
    const s0 = resolve(&f.ctx, rest, .{btn_primary});
    try std.testing.expectEqual(th.fg, s0.text.?);
    try std.testing.expectEqual(th.fg, s0.outline_color.?);

    // Hovered → acc.
    const hov = try f.node("b_hov");
    f.ctx.setFlag(hov.key, .hovering, true);
    try std.testing.expectEqual(th.acc, resolve(&f.ctx, hov, .{btn_primary}).text.?);

    // Disabled → dim, and disabled wins even if also hovered.
    const dis = try f.node("b_dis");
    f.ctx.setFlag(dis.key, .disabled, true);
    f.ctx.setFlag(dis.key, .hovering, true);
    try std.testing.expectEqual(th.dim, resolve(&f.ctx, dis, .{btn_primary}).text.?);
}

test "KIT-02 tab: selected accents ink+border; unselected is dim, fg on hover" {
    const f = try KitFixture.init();
    defer f.deinit();
    const th = f.resources.view.theme;

    const unsel = try f.node("t_un");
    try std.testing.expectEqual(th.dim, resolve(&f.ctx, unsel, .{tab}).text.?);

    const sel = try f.node("t_sel");
    f.ctx.setFlag(sel.key, .selected, true);
    const ss = resolve(&f.ctx, sel, .{tab});
    try std.testing.expectEqual(th.acc, ss.text.?);
    try std.testing.expectEqual(th.acc, ss.outline_color.?);
}

test "KIT-02 semantic state text maps to the right roles" {
    const f = try KitFixture.init();
    defer f.deinit();
    const th = f.resources.view.theme;
    const n = try f.node("s");
    try std.testing.expectEqual(th.good, resolve(&f.ctx, n, .{state_good}).text.?);
    try std.testing.expectEqual(th.warn, resolve(&f.ctx, n, .{state_warn}).text.?);
    try std.testing.expectEqual(th.danger, resolve(&f.ctx, n, .{state_danger}).text.?);
    try std.testing.expectEqual(th.dim, resolve(&f.ctx, n, .{state_muted}).text.?);
}

test "KIT-02 focus_ring draws only on focus_visible, never on hover alone" {
    const f = try KitFixture.init();
    defer f.deinit();
    const th = f.resources.view.theme;

    // Hover alone: no ring.
    const hov = try f.node("f_hov");
    f.ctx.setFlag(hov.key, .hovering, true);
    try std.testing.expectEqual(@as(?Color, null), resolve(&f.ctx, hov, .{focus_ring}).outline_color);

    // focus-visible: acc ring.
    const fv = try f.node("f_fv");
    f.ctx.setFlag(fv.key, .focus_visible, true);
    try std.testing.expectEqual(th.acc, resolve(&f.ctx, fv, .{focus_ring}).outline_color.?);
}

test "KIT-02 row_hover lifts fill on hover, transparent at rest" {
    const f = try KitFixture.init();
    defer f.deinit();
    const th = f.resources.view.theme;

    const rest = try f.node("r_rest");
    try std.testing.expectEqual(@as(?Color, null), resolve(&f.ctx, rest, .{row_hover}).fill);

    const hov = try f.node("r_hov");
    f.ctx.setFlag(hov.key, .hovering, true);
    try std.testing.expectEqual(th.panel, resolve(&f.ctx, hov, .{row_hover}).fill.?);
}

test "KIT-02 provisional is a dim dashed border" {
    const f = try KitFixture.init();
    defer f.deinit();
    const th = f.resources.view.theme;
    const n = try f.node("p");
    const s = resolve(&f.ctx, n, .{provisional});
    try std.testing.expectEqual(th.dim, s.outline_color.?);
    try std.testing.expectEqual(cb.LineStyle.dashed, s.outline_style.?);
}

test "KIT-02 legend_dot fills with the named resource hue" {
    const f = try KitFixture.init();
    defer f.deinit();
    const n = try f.node("d");
    const s = resolve(&f.ctx, n, .{legend_dot(.food)});
    try std.testing.expectEqual(f.resources.view.resources.food, s.fill.?);
}

test "KIT-02 later fragment overrides a variant field (precedence)" {
    const f = try KitFixture.init();
    defer f.deinit();
    const red: Color = .{ .r = 200, .g = 0, .b = 0, .a = 255 };
    // Take btn_primary but override just the ink; the border stays the variant's.
    const n = try f.node("o");
    const s = resolve(&f.ctx, n, .{ btn_primary, Style{ .text = red } });
    try std.testing.expectEqual(red, s.text.?);
    try std.testing.expectEqual(f.resources.view.theme.fg, s.outline_color.?);
}
