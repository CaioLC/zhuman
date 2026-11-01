//! The composable **style** layer — the "how a node looks" layer (colors, font, padding).
//! A `Style` is a *partial* (every field optional); presets compose from a tuple by a
//! last-non-null-wins fold, CSS-like:
//!
//!   (try p.text("t", "Hi")).with_style(.{ h1, red });  // → font 42, text red
//!
//! A spec is a `Style` value or a (nested) tuple of them. A look that follows the owning
//! control's state (a button's hover ink) is data too: `Style.on` lists **state rules**,
//! evaluated against the control's published `Interaction` when the spec resolves.
//!
//! **Placement is deliberately not here.** Where a node sits and how it arranges children
//! (anchor / children direction / gap / size / overflow) is an *imperative* concern set
//! straight onto the node's `Layout`/`Size` via the `El` handle's `with_layout` /
//! `with_gap` / `with_size` / `with_overflow` methods (`elements.zig`) — no parallel
//! "Placement" struct folding over the engine's values. Style and placement stay apart.

const std = @import("std");
const ui = @import("ui");
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
/// rule; both are the typography payload and, like every field here, fold
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
    /// **Texture-content ink**: the tint a *non-text* content aspect paints with.
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

    // —— Theme-relative ink ————————————————————————————————————————————————————————————
    // Each color slot has a *role* twin that names a `Theme` field instead of a concrete
    // `Color`; `resolve` reads the live `ctx.res.view.theme` for it. A slot and its twin fold
    // as one: whichever a later fragment sets wins, and a fragment that sets both resolves to
    // the role. So `Style{ .text = th.dim }` and `Style{ .ink = .dim }` paint the same
    // pixels, and a call site migrates by dropping its `th`.

    /// Glyph ink by role — the twin of `text`.
    ink: ?ThemeRole = null,
    /// Texture ink by role — the twin of `tint`.
    tint_ink: ?ThemeRole = null,
    /// Fill by role — the twin of `fill`.
    fill_ink: ?ThemeRole = null,
    /// Border color by role — the twin of `outline_color` (and, like it, turns the border on).
    outline_ink: ?ThemeRole = null,

    /// Glyph ink by **meaning**: a `Verdict` the live `ctx.res.view.verdicts` table maps to a
    /// role. A third member of the glyph slot with `text` and `ink`: whichever a later fragment
    /// sets wins, and within one fragment a set verdict wins, so
    /// `Style{ .ink = .fg, .verdict = verdict.when(over, .over) }` paints fg unless over. A
    /// null verdict is unset. An active state rule's `ink` replaces it.
    verdict: ?Verdict = null,

    /// **State rules**: role inks that replace the resting ones while a condition holds on the
    /// owning control, `Style{ .ink = .dim, .on = &.{.{ .when = .hot, .ink = .acc }} }`. Unlike
    /// every other field, `on` *appends* across fragments in fold order; at most `max_rules`
    /// per spec. `resolve` applies them in order after the fold, so a later active rule wins.
    on: []const Rule = &.{},
};

/// A theme role by name (`.fg`, `.dim`, `.line`, `.line2`, `.acc`, `.warn`, `.danger`,
/// `.good`, `.panel`, `.bg`) — one tag per `Theme` field.
pub const ThemeRole = theme.Role;

/// A condition on the owner's published `Interaction`: `hot` and `hover_focus` are its two
/// predicates (`Interaction.hot()`, `Interaction.hover_focus()`), the rest are the bits of
/// the same names. While the owner is `disabled`, only `disabled`, `selected` and `checked`
/// can hold; the pointer and focus conditions read false.
pub const When = enum { hot, hover_focus, hovering, focused, focus_visible, held, disabled, selected, checked };

/// One state rule: while `when` holds on the owner, each set ink replaces that slot's
/// resting ink (a role here wins over a concrete color in the slot).
pub const Rule = struct {
    when: When,
    ink: ?ThemeRole = null,
    tint_ink: ?ThemeRole = null,
    fill_ink: ?ThemeRole = null,
    outline_ink: ?ThemeRole = null,
};

/// The most state rules one resolved spec carries. A fifth is a compile error when the
/// fragments carrying it are comptime-known, and otherwise a safety panic (dropped in release).
pub const max_rules = 4;

/// The (concrete color, role, verdict) fields that fold as one slot. Only the glyph slot has
/// a verdict member.
const ink_slots = [_]struct { []const u8, []const u8, ?[]const u8 }{
    .{ "text", "ink", "verdict" },
    .{ "tint", "tint_ink", null },
    .{ "fill", "fill_ink", null },
    .{ "outline_color", "outline_ink", null },
};

/// The meanings vocabulary (`verdict.zig`): the `Verdict` enum, the `Roles` table on the view,
/// and the pure helpers (`when`, `of`, `trade`, `margin`, `delta_eps`).
pub const verdict = @import("./verdict.zig");
pub const Verdict = verdict.Verdict;

// A bright-red debug outline around any node. `Color` is SDL's `SDL_Color` — u8 fields on
// a 0–255 scale, so the outline must be `a = 255` (opaque) and `r = 255` (full red); the
// earlier `a = 0.0, r = 1.0` read as 0–1 floats and coerced to a=0 (transparent), r=1 (~black).
pub const debug: Style = .{ .outline_color = .{ .r = 255, .g = 0, .b = 0, .a = 255 } };

// Every scalar below is authored at one reference resolution; the responsive scale factor
// (`View.scale`) is applied at `apply` time through `type.toDevice` — the single
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

// Legacy above-contract display sizes used by the Act curtain / capital
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

// --- Ink and named role fragments -----------------------------------------------
// Theme-relative looks named by what they mean, for the literals templates repeated. Each
// sets exactly the fields the literal it replaces set (no tracking or transform is added),
// so swapping one in never moves a pixel.

/// Glyph ink by role, as a fragment: `style.ink(.fg)`.
pub fn ink(r: ThemeRole) Style {
    return .{ .ink = r };
}
/// Secondary text: `dim` ink.
pub const muted: Style = .{ .ink = .dim };
/// Tertiary text, quieter than `muted`: `line2` ink.
pub const faint: Style = .{ .ink = .line2 };
/// A tracked 10px dim caps label (`SIDE`, `AFTER`, a slip's field head). Unlike `eyebrow`
/// (11px, uppercased by transform) it keeps its source case and the 10px size.
pub const eyebrow_dim: Style = .{ .font = 10, .tracking = 0.07, .ink = .dim };
/// An 11px dim note: a subtitle, an empty-list message, a sentence's prose around a value.
pub const note: Style = .{ .font = 11, .ink = .dim };
/// A 10px dim caption: a sub-line, an effect line, a corner count.
pub const caption: Style = .{ .font = 10, .ink = .dim };
/// A 10px `line2` caption, one step quieter than `caption`.
pub const caption_faint: Style = .{ .font = 10, .ink = .line2 };
/// 9px dim fine print: a cost, a percentage, a requirement value.
pub const fine_print: Style = .{ .font = 9, .ink = .dim };
/// A hairline rule or divider's fill (`line`). Geometry (1px wide or tall) stays on the node.
pub const rule_fill: Style = .{ .fill_ink = .line };

/// The color the live theme gives role `r`, for a site that needs a `Color` value rather
/// than a style field (a mesh vertex, a helper that takes a color).
pub fn roleColor(ctx: *UiCtx, r: ThemeRole) Color {
    return theme.color(ctx.res.view.theme, r);
}

/// **The one tone mapping.** Each template keeps its own `Tone` enum (its tags are part of
/// its public API), and every one of them maps a tag to the theme role of the same name, with
/// two spellings: `normal` is `fg` and `accent` is `acc`. A tag with no matching role is a
/// compile error, so a new tone cannot silently fall through.
pub fn toneRole(value: anytype) ThemeRole {
    return switch (value) {
        inline else => |t| comptime roleOfTone(@tagName(t)),
    };
}

fn roleOfTone(comptime name: []const u8) ThemeRole {
    if (std.mem.eql(u8, name, "normal")) return .fg;
    if (std.mem.eql(u8, name, "accent")) return .acc;
    return std.meta.stringToEnum(ThemeRole, name) orelse
        @compileError("tone `" ++ name ++ "` names no theme role");
}

/// A tone's live color (`toneRole` resolved against the theme).
pub fn toneColor(ctx: *UiCtx, value: anytype) Color {
    return roleColor(ctx, toneRole(value));
}

/// A tone as a glyph-ink fragment.
pub fn tone(t: anytype) Style {
    return .{ .ink = toneRole(t) };
}

/// The color the live view gives verdict `v`: its role in `ctx.res.view.verdicts`, then that
/// role's color in the theme. For a site that needs a `Color` (a tween's endpoint, a helper
/// that takes a color); a style names the verdict in its `verdict` field instead.
pub fn verdictColor(ctx: *UiCtx, v: Verdict) Color {
    return roleColor(ctx, verdict.role(ctx.res.view.verdicts, v));
}

// === Surfaces and state rules ===================================================
//
// Every fragment is a plain `Style` value, folded the same way. A static look (`panel`, the
// role fragments above) names its inks by `Theme` role, so a palette moves them all at once.
// A look that follows the owning control's state carries it as data, in `on`: each `Rule`
// names a `When` condition and the role inks that replace the resting ones while it holds,
// e.g. `Style{ .ink = .dim, .on = &.{.{ .when = .hot, .ink = .acc }} }`. Precedence is the
// caller's: a later fragment in the tuple wins per field, and its rules come after the
// earlier fragments' rules.

/// A raised surface — panel fill + a hairline `line` edge. The card/rail/strip background.
pub const panel: Style = .{ .fill_ink = .panel, .outline_ink = .line, .outline_width = 1 };

/// The rules a fold collected, in fold order, in a fixed buffer of `max_rules`. A rule past
/// the cap is counted in `refused` and dropped.
const Rules = struct {
    buf: [max_rules]Rule = undefined,
    len: usize = 0,
    refused: usize = 0,

    fn append(self: *Rules, on: []const Rule) void {
        for (on) |r| {
            if (self.len == max_rules) {
                self.refused += 1;
                continue;
            }
            self.buf[self.len] = r;
            self.len += 1;
        }
    }

    fn slice(self: *const Rules) []const Rule {
        return self.buf[0..self.len];
    }
};

/// Copy each *set* field of `frag` onto `out` — the last-non-null-wins step of the fold — and
/// append its rules. A color slot, its role twin and (for glyph ink) its verdict fold as one
/// slot: a later fragment's any one replaces an earlier one's others, and within one fragment
/// a verdict beats a role beats a color.
fn merge(out: *Style, rules: *Rules, frag: Style) void {
    inline for (@typeInfo(Style).@"struct".field_names) |name| {
        if (comptime std.mem.eql(u8, name, "on")) continue;
        if (@field(frag, name)) |v| @field(out, name) = v;
    }
    inline for (ink_slots) |slot| {
        const by_verdict = if (comptime slot[2]) |vf| @field(frag, vf) != null else false;
        if (by_verdict) {
            @field(out, slot[0]) = null;
            @field(out, slot[1]) = null;
        } else if (@field(frag, slot[1]) != null) {
            @field(out, slot[0]) = null; // the role wins over the color within one fragment
            clearVerdict(out, slot);
        } else if (@field(frag, slot[0]) != null) {
            @field(out, slot[1]) = null;
            clearVerdict(out, slot);
        }
    }
    rules.append(frag.on);
}

/// Unset the verdict member of `slot` on `out`, for a slot that has one.
inline fn clearVerdict(out: *Style, comptime slot: anytype) void {
    if (comptime slot[2]) |vf| @field(out, vf) = null;
}

/// Fold a style spec into a single `Style`. `spec` is one `Style` or a (possibly nested)
/// tuple of them. Later fragments win per field; `on` rules append in fold order.
///
/// The result is **concrete**: the collected rules are applied in order against the owner's
/// interaction (`ruleOwner`), each active rule writing its set inks over the result, then a
/// verdict resolves to its role through the live `ctx.res.view.verdicts` and every role twin
/// to its color through the live theme. The returned `Style` carries only
/// `text`/`tint`/`fill`/`outline_color` and an empty `on`. A spec with no roles, verdicts or
/// rules never reads `ctx` or `node`.
pub fn resolve(ctx: *UiCtx, node: *Node, spec: anytype) Style {
    comptime {
        if (knownRuleCount(@TypeOf(spec)) > max_rules)
            @compileError("style spec: more than four state rules (`Style.on`) in its comptime-known fragments");
    }
    var out: Style = .{};
    var rules: Rules = .{};
    fold(&out, &rules, spec);
    if (rules.refused != 0) refuseRules();
    if (rules.len != 0) applyRules(ctx, node, &out, rules.slice());
    inline for (ink_slots) |slot| {
        if (comptime slot[2]) |vf| {
            if (@field(out, vf)) |v| {
                @field(out, slot[1]) = verdict.role(ctx.res.view.verdicts, v);
                @field(out, vf) = null;
            }
        }
        if (@field(out, slot[1])) |r| {
            @field(out, slot[0]) = theme.color(ctx.res.view.theme, r);
            @field(out, slot[1]) = null;
        }
    }
    return out;
}

/// The overflow refusal: a spec that resolved with more than `max_rules` rules is a template
/// bug, a panic in safe builds; release builds keep the first four.
fn refuseRules() void {
    if (std.debug.runtime_safety) @panic("Style.on: more than four state rules in one style spec");
}

/// How many rules the **comptime-known** fragments of a spec of type `T` carry. A tuple field
/// whose value is comptime-known is a `comptime` field with that value as its default, so its
/// `on.len` is readable from the type; a runtime `Style` counts zero here and is counted by
/// the fold instead. Nested tuples recurse through their types.
fn knownRuleCount(comptime T: type) usize {
    if (T == Style) return 0;
    const s = switch (@typeInfo(T)) {
        .@"struct" => |s| if (s.is_tuple) s else return 0,
        else => return 0, // `fold` reports the type error
    };
    var n: usize = 0;
    inline for (s.field_types, s.field_attrs) |FT, a| {
        if (FT == Style) {
            if (a.@"comptime") n += (a.defaultValue(Style) orelse continue).on.len;
        } else n += knownRuleCount(FT);
    }
    return n;
}

/// Apply `rules` in order over `out`: each rule whose condition holds on the owner replaces
/// the slots it sets (a role wins over a concrete color or a verdict), so a later active rule
/// wins. A spec with rules and no owner is a template bug (a safety panic; release applies none).
fn applyRules(ctx: *UiCtx, node: *Node, out: *Style, rules: []const Rule) void {
    const q = ruleOwner(ctx, node) orelse {
        if (std.debug.runtime_safety) @panic("Style.on: no control owner; call control() on the node or an ancestor before styling it");
        return;
    };
    for (rules) |r| {
        if (!holds(q, r.when)) continue;
        inline for (ink_slots) |slot| {
            if (@field(r, slot[1])) |lit| {
                @field(out, slot[1]) = lit;
                @field(out, slot[0]) = null;
                clearVerdict(out, slot);
            }
        }
    }
}

/// Whether `when` holds on an owner whose published interaction is `q`. A disabled owner
/// holds only `disabled`, `selected` and `checked`.
fn holds(q: UiCtx.Interaction, when: When) bool {
    return switch (when) {
        .disabled => q.disabled,
        .selected => q.selected,
        .checked => q.checked,
        .hot => !q.disabled and q.hot(),
        .hover_focus => !q.disabled and q.hover_focus(),
        .hovering => !q.disabled and q.hovering,
        .focused => !q.disabled and q.focused,
        .focus_visible => !q.disabled and q.focus_visible,
        .held => !q.disabled and q.held,
    };
}

/// The control whose interaction state rules on `node` read: `node` itself or its nearest
/// ancestor that `control` ran on (`render_data.control`). Null when there is none.
pub fn controlOwner(node: *Node) ?*Node {
    var n: ?*Node = node;
    while (n) |cur| : (n = cur.parent) {
        if (cur.render_data.control) return cur;
    }
    return null;
}

/// The interaction state rules on `node` read: its `controlOwner`'s published interaction, or
/// null when no control runs on the node or an ancestor. The owner must already have run
/// `control` — call it on the row before styling the row's children, as the templates do.
fn ruleOwner(ctx: *UiCtx, node: *Node) ?UiCtx.Interaction {
    const owner = controlOwner(node) orelse return null;
    return owner.query(ctx);
}

fn fold(out: *Style, rules: *Rules, frag: anytype) void {
    const T = @TypeOf(frag);
    if (T == Style) return merge(out, rules, frag);
    switch (@typeInfo(T)) {
        .@"struct" => |s| if (s.is_tuple) {
            inline for (s.field_names) |name| fold(out, rules, @field(frag, name));
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
    // Padding and gap are authored in *logical* px; scale to device by the frame
    // scale (`view.dp`) to match the device-px layout and text boxes. `outline_width` is NOT
    // scaled here — it is scaled at draw by `paint.hairline`, so scaling it here
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

    // Texture-content ink. A set `tint` recolors a present `svg` aspect (an icon
    // raster tinted at blit), routed through the same fragment fold as every other look — so
    // a caller styles an icon's color instead of poking `render_data.svg` directly.
    if (node.render_data.svg != null) {
        if (s.tint) |c| node.render_data.svg = c;
    }

    if (node.render_data.text != null) {
        if (s.text) |c| node.render_data.text = c;
        // The typography payload (size / tracking / transform) is applied together and then
        // re-measured **once** through the one shared routine, so the reserved box always
        // matches the spaced/transformed glyphs `draw` will place — the
        // "measure and draw read one source" invariant, extended to tracking/case.
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

/// Apply a case transform to a `TextState`'s buffer in place. The uppercase fold is
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

test "apply: decorations + padding write; inert text style on a non-text node is allowed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const node = try Node.create(arena.allocator(), "n");

    // `apply` scales padding/gap by `ctx.res.view.scale`, so give it a real ctx with
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

// ---- typography roles ----------------------------------------------------------

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
    // The style payload composes for free through the field-wise merge — a caller can take
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

// ---- texture-content tint ----------------------------------------------------

test "style: tint folds last-non-null-wins independently of text" {
    const red: Color = .{ .r = 200, .g = 40, .b = 40, .a = 255 };
    const blue: Color = .{ .r = 40, .g = 40, .b = 200, .a = 255 };
    // `tint` and `text` are separate fields — a tuple can carry both, neither shadows the
    // other, and each folds last-non-null-wins on its own.
    const s = resolve(undefined, undefined, .{ Style{ .tint = red, .text = blue }, Style{ .tint = blue } });
    try std.testing.expectEqual(blue, s.tint.?); // tint overridden by the later fragment
    try std.testing.expectEqual(blue, s.text.?); // text kept from the first fragment
}

test "apply: tint recolors a present svg aspect and is inert without one" {
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

// ---- surfaces, theme-relative ink, role fragments, tones, state rules -------------

// A test harness: an arena, a real ctx, and a theme installed on the view, so role inks
// resolve against known colors and rules read published interaction bits.
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

test "panel: a role fragment, the same pixels as the concrete panel literal" {
    const f = try KitFixture.init();
    defer f.deinit();
    const th = f.resources.view.theme;
    const n = try f.node("p");
    const s = resolve(&f.ctx, n, panel);
    try std.testing.expectEqual(resolve(&f.ctx, n, Style{ .fill = th.panel, .outline_color = th.line, .outline_width = 1 }), s);
}

test "later fragment overrides one field of a surface (precedence)" {
    const f = try KitFixture.init();
    defer f.deinit();
    const red: Color = .{ .r = 200, .g = 0, .b = 0, .a = 255 };
    // Take `panel` but override just the fill; the edge stays the surface's.
    const n = try f.node("o");
    const s = resolve(&f.ctx, n, .{ panel, Style{ .fill = red } });
    try std.testing.expectEqual(red, s.fill.?);
    try std.testing.expectEqual(f.resources.view.theme.line, s.outline_color.?);
}

test "ink: a role resolves to the live theme color, the same as the concrete literal" {
    const f = try KitFixture.init();
    defer f.deinit();
    const th = f.resources.view.theme;
    const n = try f.node("ink");
    const by_role = resolve(&f.ctx, n, Style{ .ink = .dim, .fill_ink = .line, .outline_ink = .acc, .tint_ink = .good });
    const by_color = resolve(&f.ctx, n, Style{ .text = th.dim, .fill = th.line, .outline_color = th.acc, .tint = th.good });
    try std.testing.expectEqual(by_color, by_role);
    // The result is concrete: no role twin or rule survives resolution.
    try std.testing.expectEqual(@as(?ThemeRole, null), by_role.ink);
    try std.testing.expectEqual(@as(usize, 0), by_role.on.len);
}

test "ink: a slot and its role twin fold as one, last fragment wins either way" {
    const f = try KitFixture.init();
    defer f.deinit();
    const th = f.resources.view.theme;
    const red: Color = .{ .r = 200, .g = 0, .b = 0, .a = 255 };
    const n = try f.node("twin");
    // role then color: the color wins.
    try std.testing.expectEqual(red, resolve(&f.ctx, n, .{ muted, Style{ .text = red } }).text.?);
    // color then role: the role wins.
    try std.testing.expectEqual(th.acc, resolve(&f.ctx, n, .{ Style{ .text = red }, ink(.acc) }).text.?);
    // both in one fragment: the role wins.
    try std.testing.expectEqual(th.fg, resolve(&f.ctx, n, Style{ .text = red, .ink = .fg }).text.?);
    // a role leaves unrelated slots alone.
    const s = resolve(&f.ctx, n, .{ Style{ .fill = red }, muted });
    try std.testing.expectEqual(red, s.fill.?);
    try std.testing.expectEqual(th.dim, s.text.?);
}

test "ink: a spec without roles or rules never reads ctx" {
    const plain = resolve(undefined, undefined, .{ h2, stroke_w(2) });
    try std.testing.expectEqual(@as(?f32, 28), plain.font);
}

test "role fragments set exactly the literal's fields" {
    const f = try KitFixture.init();
    defer f.deinit();
    const th = f.resources.view.theme;
    const n = try f.node("roles");
    const eq = std.testing.expectEqual;
    try eq(resolve(&f.ctx, n, Style{ .font = 10, .tracking = 0.07, .text = th.dim }), resolve(&f.ctx, n, eyebrow_dim));
    try eq(resolve(&f.ctx, n, Style{ .font = 11, .text = th.dim }), resolve(&f.ctx, n, note));
    try eq(resolve(&f.ctx, n, Style{ .font = 10, .text = th.dim }), resolve(&f.ctx, n, caption));
    try eq(resolve(&f.ctx, n, Style{ .font = 10, .text = th.line2 }), resolve(&f.ctx, n, caption_faint));
    try eq(resolve(&f.ctx, n, Style{ .font = 9, .text = th.dim }), resolve(&f.ctx, n, fine_print));
    try eq(resolve(&f.ctx, n, Style{ .text = th.dim }), resolve(&f.ctx, n, muted));
    try eq(resolve(&f.ctx, n, Style{ .text = th.line2 }), resolve(&f.ctx, n, faint));
    try eq(resolve(&f.ctx, n, Style{ .fill = th.line }), resolve(&f.ctx, n, rule_fill));
    // `eyebrow_dim` is not `eyebrow`: no uppercase transform, 10px not 11px.
    try eq(@as(?typ.Transform, null), eyebrow_dim.transform);
}

test "toneRole: every template tone maps to the same-named role, normal=fg, accent=acc" {
    const eq = std.testing.expectEqual;
    const Holdings = enum { fg, dim, good, warn, danger };
    const Log = enum { dim, normal, good, warn, danger };
    const Strip = enum { dim, accent, good, warn, danger };
    const Milestone = enum { danger, good };
    const Stock = enum { normal, warn, danger, accent };
    try eq(ThemeRole.fg, toneRole(Holdings.fg));
    try eq(ThemeRole.dim, toneRole(Holdings.dim));
    try eq(ThemeRole.fg, toneRole(Log.normal));
    try eq(ThemeRole.good, toneRole(Log.good));
    try eq(ThemeRole.acc, toneRole(Strip.accent));
    try eq(ThemeRole.warn, toneRole(Strip.warn));
    try eq(ThemeRole.danger, toneRole(Milestone.danger));
    try eq(ThemeRole.good, toneRole(Milestone.good));
    try eq(ThemeRole.acc, toneRole(Stock.accent));
    try eq(ThemeRole.fg, toneRole(Stock.normal));

    const f = try KitFixture.init();
    defer f.deinit();
    const th = f.resources.view.theme;
    try eq(th.warn, toneColor(&f.ctx, Stock.warn));
    try eq(th.acc, resolve(&f.ctx, try f.node("tone"), tone(Strip.accent)).text.?);
}

test "verdict: resolves through the view's table to the theme's color" {
    const f = try KitFixture.init();
    defer f.deinit();
    const th = f.resources.view.theme;
    const n = try f.node("v");
    const eq = std.testing.expectEqual;
    inline for (@typeInfo(Verdict).@"enum".field_names) |name| {
        const v = @field(Verdict, name);
        const want = theme.color(th, verdict.role(.{}, v));
        try eq(want, resolve(&f.ctx, n, Style{ .verdict = v }).text.?);
        try eq(want, verdictColor(&f.ctx, v));
    }
    // Concrete: no verdict survives resolution.
    try eq(@as(?Verdict, null), resolve(&f.ctx, n, Style{ .verdict = .over }).verdict);
}

test "verdict: folds with text and ink as one slot, last fragment wins, a null verdict is unset" {
    const f = try KitFixture.init();
    defer f.deinit();
    const th = f.resources.view.theme;
    const red: Color = .{ .r = 200, .g = 0, .b = 0, .a = 255 };
    const n = try f.node("vf");
    const eq = std.testing.expectEqual;
    // ink then verdict, verdict then ink, text then verdict, verdict then text.
    try eq(th.danger, resolve(&f.ctx, n, .{ ink(.fg), Style{ .verdict = .over } }).text.?);
    try eq(th.fg, resolve(&f.ctx, n, .{ Style{ .verdict = .over }, ink(.fg) }).text.?);
    try eq(th.good, resolve(&f.ctx, n, .{ Style{ .text = red }, Style{ .verdict = .met } }).text.?);
    try eq(red, resolve(&f.ctx, n, .{ Style{ .verdict = .met }, Style{ .text = red } }).text.?);
    // Within one fragment the verdict wins over the ink and the color.
    try eq(th.danger, resolve(&f.ctx, n, Style{ .ink = .fg, .verdict = verdict.when(true, .over) }).text.?);
    try eq(th.danger, resolve(&f.ctx, n, Style{ .text = red, .ink = .fg, .verdict = .over }).text.?);
    // A null verdict leaves the resting ink, in the same fragment or a later one.
    try eq(th.fg, resolve(&f.ctx, n, Style{ .ink = .fg, .verdict = verdict.when(false, .over) }).text.?);
    try eq(th.dim, resolve(&f.ctx, n, .{ muted, Style{ .verdict = null } }).text.?);
    try eq(red, resolve(&f.ctx, n, .{ Style{ .text = red }, Style{ .font = 12, .verdict = null } }).text.?);
    // A verdict touches only glyph ink.
    const s = resolve(&f.ctx, n, .{ Style{ .fill_ink = .panel, .tint_ink = .acc }, Style{ .verdict = .low } });
    try eq(th.panel, s.fill.?);
    try eq(th.acc, s.tint.?);
    try eq(th.danger, s.text.?);
}

test "verdict: an active state rule beats it, an inactive one leaves it" {
    const f = try KitFixture.init();
    defer f.deinit();
    const th = f.resources.view.theme;
    const r = try HotRig.init(f, "vrule");
    const spec = Style{ .ink = .fg, .verdict = .inactive, .on = &.{.{ .when = .selected, .ink = .acc }} };
    try std.testing.expectEqual(th.dim, resolve(&f.ctx, r.child, spec).text.?);
    f.ctx.setFlag(r.row.key, .selected, true);
    try std.testing.expectEqual(th.acc, resolve(&f.ctx, r.child, spec).text.?);
    // A rule from an earlier fragment still applies after a later fragment's verdict.
    const split = .{ Style{ .ink = .fg, .on = &.{.{ .when = .selected, .ink = .acc }} }, Style{ .verdict = .inactive } };
    try std.testing.expectEqual(th.acc, resolve(&f.ctx, r.child, split).text.?);
}

test "verdict: replacing the view's table changes the resolved color" {
    const f = try KitFixture.init();
    defer f.deinit();
    const th = f.resources.view.theme;
    const n = try f.node("vo");
    try std.testing.expectEqual(th.warn, resolve(&f.ctx, n, Style{ .verdict = .spent }).text.?);
    f.resources.view.verdicts = .{ .spent = .danger };
    try std.testing.expectEqual(th.danger, resolve(&f.ctx, n, Style{ .verdict = .spent }).text.?);
    try std.testing.expectEqual(th.danger, verdictColor(&f.ctx, .spent));
    try std.testing.expectEqual(th.good, verdictColor(&f.ctx, .gain)); // the rest keep defaults
}

// A control owner and a text child under it, as a template builds them: `control` marks the
// row, the child carries the rules and resolves them against the row's published interaction.
const HotRig = struct {
    row: *Node,
    child: *Node,
    fn init(f: *KitFixture, key: []const u8) !HotRig {
        const row = try f.node(key);
        row.render_data.control = true;
        const child = try Node.create(f.arena.allocator(), "t");
        child.parent = row;
        return .{ .row = row, .child = child };
    }
    fn set(r: HotRig, f: *KitFixture, held: bool, hovering: bool, focused: bool) void {
        f.ctx.setFlag(r.row.key, .held, held);
        f.ctx.setFlag(r.row.key, .hovering, hovering);
        f.ctx.setFlag(r.row.key, .focused, focused);
        f.ctx.setFlag(r.row.key, .focus_visible, focused); // `control` publishes them equal
    }
};

test "rules: a hot rule resolves to the color each old ternary picked, for all three predicate forms" {
    const f = try KitFixture.init();
    defer f.deinit();
    const th = f.resources.view.theme;
    const r = try HotRig.init(f, "row");

    const hot_spec = Style{ .ink = .dim, .on = &.{.{ .when = .hot, .ink = .acc }} };
    const hf_spec = Style{ .ink = .fg, .on = &.{.{ .when = .hover_focus, .ink = .acc }} };
    for (0..8) |bits| {
        const held = bits & 1 != 0;
        const hovering = bits & 2 != 0;
        const focused = bits & 4 != 0;
        r.set(f, held, hovering, focused);
        // `held or hovering or focused` → `.hot`
        const old_hot = if (held or hovering or focused) th.acc else th.dim;
        try std.testing.expectEqual(old_hot, resolve(&f.ctx, r.child, hot_spec).text.?);
        // `hovering or focused` → `.when = .hover_focus`
        const old_hf = if (hovering or focused) th.acc else th.fg;
        try std.testing.expectEqual(old_hf, resolve(&f.ctx, r.child, hf_spec).text.?);
        // `held or hovering` on a control that can never be focused (`focusable = false`, the
        // speed chevrons) → `.hot`, since `focused` is always false there.
        if (!focused) {
            const old_hh = if (held or hovering) th.acc else th.dim;
            try std.testing.expectEqual(old_hh, resolve(&f.ctx, r.child, hot_spec).text.?);
        }
    }
}

test "rules: the owner is the nearest control; a disabled owner does not lift on hot; fill lifts too" {
    const f = try KitFixture.init();
    defer f.deinit();
    const th = f.resources.view.theme;
    const outer = try HotRig.init(f, "outer");
    // A nested control inside the outer row (a build row's +1 corner): its child reads it.
    const inner = try Node.create(f.arena.allocator(), "inner");
    inner.parent = outer.row;
    inner.render_data.control = true;
    const label = try Node.create(f.arena.allocator(), "label");
    label.parent = inner;
    outer.set(f, false, true, false); // outer hovered, inner not
    const spec = Style{ .ink = .dim, .on = &.{.{ .when = .hot, .ink = .acc }} };
    try std.testing.expectEqual(th.dim, resolve(&f.ctx, label, spec).text.?);
    try std.testing.expectEqual(th.acc, resolve(&f.ctx, outer.child, spec).text.?);
    try std.testing.expectEqual(inner, controlOwner(label).?);

    // The owner's own style: `node` itself is the owner.
    const row_spec = Style{ .on = &.{.{ .when = .hot, .fill_ink = .panel }} };
    try std.testing.expectEqual(th.panel, resolve(&f.ctx, outer.row, row_spec).fill.?);
    outer.set(f, false, false, false);
    try std.testing.expectEqual(@as(?Color, null), resolve(&f.ctx, outer.row, row_spec).fill);

    // Disabled: hovered but no lift.
    outer.set(f, false, true, false);
    f.ctx.setFlag(outer.row.key, .disabled, true);
    try std.testing.expectEqual(th.dim, resolve(&f.ctx, outer.child, spec).text.?);
}

test "rules: two fragments' hot rules both apply, each to its own slot" {
    const f = try KitFixture.init();
    defer f.deinit();
    const th = f.resources.view.theme;
    const r = try HotRig.init(f, "fw");
    const spec = .{ Style{ .ink = .dim, .on = &.{.{ .when = .hot, .ink = .acc }} }, Style{ .on = &.{.{ .when = .hot, .outline_ink = .line2 }} } };
    r.set(f, false, false, false);
    const rest = resolve(&f.ctx, r.child, spec);
    try std.testing.expectEqual(th.dim, rest.text.?);
    try std.testing.expectEqual(@as(?Color, null), rest.outline_color);
    r.set(f, false, true, false);
    const lit = resolve(&f.ctx, r.child, spec);
    try std.testing.expectEqual(th.acc, lit.text.?);
    try std.testing.expectEqual(th.line2, lit.outline_color.?);
}

test "Interaction.hot and hover_focus differ only for a press dragged off the control" {
    const I = UiCtx.Interaction;
    try std.testing.expect((I{ .held = true }).hot());
    try std.testing.expect(!(I{ .held = true }).hover_focus());
    try std.testing.expect((I{ .hovering = true }).hot() and (I{ .hovering = true }).hover_focus());
    try std.testing.expect((I{ .focus_visible = true }).hot() and (I{ .focus_visible = true }).hover_focus());
    try std.testing.expect(!(I{}).hot() and !(I{}).hover_focus());
}
test "rules: applied in order, a later active rule wins its slot" {
    const f = try KitFixture.init();
    defer f.deinit();
    const th = f.resources.view.theme;
    const r = try HotRig.init(f, "order");
    const sel_then_hot = Style{ .ink = .dim, .on = &.{ .{ .when = .selected, .ink = .fg }, .{ .when = .hot, .ink = .acc } } };
    const hot_then_sel = Style{ .ink = .dim, .on = &.{ .{ .when = .hot, .ink = .acc }, .{ .when = .selected, .ink = .fg } } };

    f.ctx.setFlag(r.row.key, .selected, true);
    r.set(f, false, true, false); // selected and hot: the later rule wins
    try std.testing.expectEqual(th.acc, resolve(&f.ctx, r.child, sel_then_hot).text.?);
    try std.testing.expectEqual(th.fg, resolve(&f.ctx, r.child, hot_then_sel).text.?);

    r.set(f, false, false, false); // selected only: either order gives the selected ink
    try std.testing.expectEqual(th.fg, resolve(&f.ctx, r.child, sel_then_hot).text.?);
    try std.testing.expectEqual(th.fg, resolve(&f.ctx, r.child, hot_then_sel).text.?);

    f.ctx.setFlag(r.row.key, .selected, false);
    try std.testing.expectEqual(th.dim, resolve(&f.ctx, r.child, sel_then_hot).text.?); // neither
}

test "rules: `on` appends across fragments while the other fields stay last-wins" {
    const f = try KitFixture.init();
    defer f.deinit();
    const th = f.resources.view.theme;
    const r = try HotRig.init(f, "append");
    // The third fragment sets no rules and replaces the resting ink; both earlier rules stay.
    const spec = .{
        Style{ .ink = .dim, .on = &.{.{ .when = .hot, .ink = .acc }} },
        Style{ .on = &.{.{ .when = .selected, .outline_ink = .acc }} },
        Style{ .ink = .line2 },
    };
    r.set(f, false, false, false);
    const rest = resolve(&f.ctx, r.child, spec);
    try std.testing.expectEqual(th.line2, rest.text.?);
    try std.testing.expectEqual(@as(?Color, null), rest.outline_color);

    r.set(f, false, true, false);
    const hot = resolve(&f.ctx, r.child, spec);
    try std.testing.expectEqual(th.acc, hot.text.?);
    try std.testing.expectEqual(@as(?Color, null), hot.outline_color);

    r.set(f, false, false, false);
    f.ctx.setFlag(r.row.key, .selected, true);
    const sel = resolve(&f.ctx, r.child, spec);
    try std.testing.expectEqual(th.line2, sel.text.?);
    try std.testing.expectEqual(th.acc, sel.outline_color.?);
}

test "rules: a disabled owner holds only disabled, selected and checked" {
    const f = try KitFixture.init();
    defer f.deinit();
    const th = f.resources.view.theme;
    const r = try HotRig.init(f, "dis");
    // Every pointer and focus bit on, plus selected and checked.
    r.set(f, true, true, true);
    f.ctx.setFlag(r.row.key, .selected, true);
    f.ctx.setFlag(r.row.key, .checked, true);

    const pointer_focus = [_]When{ .hot, .hover_focus, .hovering, .focused, .focus_visible, .held };
    inline for (pointer_focus) |w| {
        const spec = Style{ .ink = .dim, .on = &.{.{ .when = w, .ink = .acc }} };
        f.ctx.setFlag(r.row.key, .disabled, false);
        try std.testing.expectEqual(th.acc, resolve(&f.ctx, r.child, spec).text.?);
        f.ctx.setFlag(r.row.key, .disabled, true);
        try std.testing.expectEqual(th.dim, resolve(&f.ctx, r.child, spec).text.?);
    }
    // Disabled: the state conditions still hold.
    inline for ([_]When{ .disabled, .selected, .checked }) |w| {
        const spec = Style{ .ink = .dim, .on = &.{.{ .when = w, .ink = .acc }} };
        try std.testing.expectEqual(th.acc, resolve(&f.ctx, r.child, spec).text.?);
    }
    // And `disabled` reads false on an enabled owner.
    f.ctx.setFlag(r.row.key, .disabled, false);
    const dis_spec = Style{ .ink = .dim, .on = &.{.{ .when = .disabled, .ink = .acc }} };
    try std.testing.expectEqual(th.dim, resolve(&f.ctx, r.child, dis_spec).text.?);
}


test "rules: with no control ancestor there is no owner, even for a node that owns a slot" {
    const f = try KitFixture.init();
    defer f.deinit();
    const parent = try f.node("plain_parent");
    const n = try Node.create(f.arena.allocator(), "orphan");
    n.parent = parent;
    // A slot of its own (something set or read its interaction) is not a control.
    f.ctx.setFlag(parent.key, .hovering, true);
    try std.testing.expectEqual(@as(?*Node, null), controlOwner(n));
    try std.testing.expectEqual(@as(?UiCtx.Interaction, null), ruleOwner(&f.ctx, n));
    try std.testing.expectEqual(@as(?UiCtx.Interaction, null), ruleOwner(&f.ctx, parent));
    try std.testing.expect(!f.ctx.interactions.index.contains(n.key)); // the lookup touched no slot
}

test "rules: a fifth rule from a runtime fragment is refused, the first four kept in order" {
    // A runtime-built fragment: its rules are not comptime-known, so only the fold sees them.
    var five: [5]Rule = undefined;
    for (&five, 0..) |*r, i| r.* = .{ .when = @fromBackingInt(@intCast(i)) };
    const frag = Style{ .on = five[0..] };
    try std.testing.expectEqual(@as(usize, 0), comptime knownRuleCount(@TypeOf(.{frag})));

    var out: Style = .{};
    var rules: Rules = .{};
    fold(&out, &rules, .{frag});
    try std.testing.expectEqual(@as(usize, max_rules), rules.len);
    try std.testing.expectEqual(@as(usize, 1), rules.refused); // `resolve` refuses on this
    for (rules.slice(), 0..) |r, i| try std.testing.expectEqual(@as(When, @fromBackingInt(@intCast(i))), r.when);

    // The cap counts across fragments: three then two refuses one.
    var out2: Style = .{};
    var rules2: Rules = .{};
    fold(&out2, &rules2, .{ Style{ .on = five[0..3] }, .{Style{ .on = five[3..5] }} });
    try std.testing.expectEqual(@as(usize, max_rules), rules2.len);
    try std.testing.expectEqual(@as(usize, 1), rules2.refused);

    // Four is the cap, not an overflow.
    var rules4: Rules = .{};
    fold(&out2, &rules4, .{Style{ .on = five[0..4] }});
    try std.testing.expectEqual(@as(usize, 0), rules4.refused);
}

test "rules: comptime-known fragments count their rules from the spec's type" {
    const hot: Rule = .{ .when = .hot, .ink = .acc };
    const three = Style{ .on = &.{ hot, hot, hot } };
    const two = Style{ .on = &.{ hot, hot } };
    // `resolve` turns a count past `max_rules` into a compile error; these read the count.
    try std.testing.expectEqual(@as(usize, 5), comptime knownRuleCount(@TypeOf(.{ three, two })));
    try std.testing.expectEqual(@as(usize, 5), comptime knownRuleCount(@TypeOf(.{ three, .{two} })));
    try std.testing.expectEqual(@as(usize, 4), comptime knownRuleCount(@TypeOf(.{ panel, three, Style{ .on = &.{hot} } })));
    // A runtime fragment beside comptime ones counts zero; the fold counts it instead.
    var rt: [2]Rule = .{ hot, hot };
    try std.testing.expectEqual(@as(usize, 3), comptime knownRuleCount(@TypeOf(.{ three, Style{ .on = rt[0..] } })));
    rt[0].ink = .fg;
}
