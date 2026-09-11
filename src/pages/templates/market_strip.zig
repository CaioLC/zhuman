//! `market_strip` and `activity_strip` (KIT-13) — the two optional header strips that fill the
//! shell's `regions.market` / `regions.activity`. Both are **identity-map driven**: a small
//! enum selects the glyph, copy, action label, and semantic **tone**, so the presentation is a
//! pure table (unit-tested) and the render just projects the tone to a theme role.
//!
//!   - **MarketStrip** — who is at the market right now: `● PASSERBY`, `● MERCHANT`, or
//!     `◆ EXCHANGE`, each with its copy, an action label (the button to open the deal), and a
//!     semantic color (`dim` idle passerby, `acc` a merchant, `good`/accent the exchange).
//!   - **ActivityStrip** — what the actor is doing: `idle`/`working`/`building` glyph, the
//!     subject, metadata, and exact `dim`/`accent`/`warn` styling; a state change is a **live
//!     announcement** (`ctx.res.announcements`) so a screen reader hears "Building shelter".
//!
//! **STRUCTURE suppresses both without losing state:** suppression is the caller not requesting
//! the region (or passing an empty identity), and the identity/subject live in the caller's sim
//! state — not in either strip — so hiding them keeps their values for when they return.

const std = @import("std");
const ha = @import("ha");

const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const UiCtx = uic.UiCtx;
const El = el.El;

/// A semantic tone — the role a strip's color projects to. Kept as an enum (not a `Color`) so
/// the identity maps stay pure and testable; `toneColor` resolves it against the live theme.
pub const Tone = enum { dim, accent, good, warn, danger };

fn toneColor(ctx: *UiCtx, tone: Tone) uic.Color {
    const th = ctx.res.view.theme;
    return switch (tone) {
        .dim => th.dim,
        .accent => th.acc,
        .good => th.good,
        .warn => th.warn,
        .danger => th.danger,
    };
}

// —— MarketStrip ————————————————————————————————————————————————————————————————————————

/// Who is at the market. The identity map's key.
pub const MarketKind = enum { passerby, merchant, exchange };

/// The presentation an identity resolves to — a pure table row (no ctx, no color).
pub const MarketIdentity = struct {
    glyph: []const u8,
    copy: []const u8,
    action: []const u8,
    tone: Tone,
};

/// The **identity map** (pure, tested): a market kind → glyph, copy, action label, tone.
pub fn marketIdentity(kind: MarketKind) MarketIdentity {
    return switch (kind) {
        .passerby => .{ .glyph = "\u{25CF}", .copy = "A passerby lingers.", .action = "Hail", .tone = .dim },
        .merchant => .{ .glyph = "\u{25CF}", .copy = "A merchant has wares.", .action = "Trade", .tone = .accent },
        .exchange => .{ .glyph = "\u{25C6}", .copy = "The exchange is open.", .action = "Enter", .tone = .good },
    };
}

/// Build the market strip for `kind`. Returns the action button `El` so the caller reads
/// `.query().clicked` to open the deal (the strip owns presentation, the caller owns the deal).
pub fn market_strip(ctx: *UiCtx, parent: El, id: []const u8, kind: MarketKind) !El {
    const idn = marketIdentity(kind);
    const color = toneColor(ctx, idn.tone);

    const row = try el.div(ctx, parent, id);
    _ = row.with_flow(.{ .dir = .row, .cross = .center }).with_gap(ha.tokens.gap.inline_)
        .with_size(.{ .pct_of_parent = 1.0 }, .fit_children);
    _ = (try el.text(ctx, row, "glyph", idn.glyph)).with_style(.{Style{ .text = color }});
    _ = (try el.text(ctx, row, "copy", idn.copy)).with_style(.{ style.body, Style{ .text = ctx.res.view.theme.fg } });
    // A grow spacer pushes the action to the right edge *within* the row's own box, so the
    // button can never overflow the strip / terminal clip.
    const spacer = try el.div(ctx, row, "sp");
    _ = spacer.with_size(.grow, .{ .fixed = 1 });
    // The action: a bordered button box (KIT-03 contract) styled from the KIT-02 button
    // fragment; the caller reads `.query().clicked` to open the deal.
    const act = try el.div(ctx, row, "act");
    ctx.registerFocus(act.get().key, true);
    const aq = act.query();
    if (aq.clicked) _ = ctx.requestFocus(act.get().key);
    const afocused = ctx.isFocused(act.get().key);
    if (aq.hovering) ctx.res.cursor.request(.pointer);
    uic.publishControlState(ctx, act.get().key, .{ .focused = afocused, .focus_visible = afocused });
    // The box is a non-text node, so apply only the resolved border (KIT-02 `btn_primary`'s
    // outline) here — putting the fragment's `.text` on a div would trip the inert-typography
    // assert. The label (a text node) carries the ink from the same fragment.
    const s = style.resolve(ctx, act.get(), .{style.btn_primary});
    if (s.outline_color) |c| act.get().render_data.outline = .{ .color = c };
    _ = act.with_flow(.{ .dir = .row }).with_style(.{style.pad_sym(8, 2)});
    _ = (try el.text(ctx, act, "l", idn.action)).with_style(.{style.btn_primary});
    return act;
}

// —— ActivityStrip ——————————————————————————————————————————————————————————————————————

/// What the actor is doing. The identity map's key.
pub const ActivityState = enum { idle, working, building };

/// The presentation an activity resolves to — a pure table row.
pub const ActivityIdentity = struct {
    glyph: []const u8,
    tone: Tone,
};

/// The **identity map** (pure, tested): an activity state → glyph and tone. Idle is quiet
/// (`dim`), working is active (`accent`), building is a caution-toned commitment (`warn`).
pub fn activityIdentity(state: ActivityState) ActivityIdentity {
    return switch (state) {
        .idle => .{ .glyph = "\u{25CB}", .tone = .dim }, // ○ hollow — nothing in progress
        .working => .{ .glyph = "\u{25D0}", .tone = .accent }, // ◐ half — in progress
        .building => .{ .glyph = "\u{25C9}", .tone = .warn }, // ◉ fisheye — a committed build
    };
}

/// Build the activity strip: `state` glyph + `subject` + `metadata`, styled by the state's
/// tone. When `state` differs from `last`, emit a **live announcement** ("Building shelter")
/// so a screen reader hears the change; pass the caller's remembered `last` and store the
/// returned state back. Returns the (possibly unchanged) state to remember.
pub fn activity_strip(ctx: *UiCtx, parent: El, id: []const u8, state: ActivityState, subject: []const u8, metadata: []const u8, last: ActivityState) !ActivityState {
    const idn = activityIdentity(state);
    const color = toneColor(ctx, idn.tone);

    const row = try el.div(ctx, parent, id);
    _ = row.with_flow(.{ .dir = .row, .cross = .center }).with_gap(ha.tokens.gap.inline_)
        .with_size(.{ .pct_of_parent = 1.0 }, .fit_children);
    _ = (try el.text(ctx, row, "glyph", idn.glyph)).with_style(.{Style{ .text = color }});
    _ = (try el.text(ctx, row, "subj", subject)).with_style(.{ style.body, Style{ .text = color } });
    if (metadata.len > 0) {
        _ = (try el.text(ctx, row, "meta", metadata)).with_style(.{ style.small, Style{ .text = ctx.res.view.theme.dim } });
    }

    // Live announcement on a state change (idle→working→building). Composed from the same
    // subject the strip shows, so what is spoken matches what is drawn.
    if (state != last and state != .idle) {
        var buf: [64]u8 = undefined;
        const verb = switch (state) {
            .working => "Working",
            .building => "Building",
            .idle => unreachable,
        };
        const msg = std.fmt.bufPrint(&buf, "{s} {s}", .{ verb, subject }) catch subject;
        _ = ctx.res.announcements.announce(msg);
    }
    return state;
}

// ============================ Tests (pure identity maps) ================================

test "market identity map: glyph, action, and tone per kind" {
    try std.testing.expectEqualStrings("\u{25CF}", marketIdentity(.passerby).glyph);
    try std.testing.expectEqual(Tone.dim, marketIdentity(.passerby).tone);
    try std.testing.expectEqualStrings("Trade", marketIdentity(.merchant).action);
    try std.testing.expectEqual(Tone.accent, marketIdentity(.merchant).tone);
    try std.testing.expectEqualStrings("\u{25C6}", marketIdentity(.exchange).glyph); // ◆ diamond
    try std.testing.expectEqual(Tone.good, marketIdentity(.exchange).tone);
}

test "activity identity map: idle dim, working accent, building warn" {
    try std.testing.expectEqual(Tone.dim, activityIdentity(.idle).tone);
    try std.testing.expectEqual(Tone.accent, activityIdentity(.working).tone);
    try std.testing.expectEqual(Tone.warn, activityIdentity(.building).tone);
}
