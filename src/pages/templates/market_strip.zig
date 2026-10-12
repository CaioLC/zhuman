//! `market_strip` and `activity_strip` — the two optional header strips that fill the
//! shell's `regions.market` / `regions.activity`. Both are **identity-map driven**: a small
//! enum selects the signal, stock copy, action label, and semantic **tone**, so presentation is a
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
    signal: []const u8,
    copy: []const u8,
    action: []const u8,
    tone: Tone,
};

/// Prototype border-box geometry: 12px copy in a 32px dashed strip, with 7px vertical and
/// 9px horizontal insets and 10px between the three columns.
const market_h: f32 = 32;
const market_pad_x: f32 = 9;
const market_gap: f32 = 10;
const market_font: f32 = 12;

/// The **identity map** (pure, tested): a market kind → signal, stock copy, link, and tone.
pub fn marketIdentity(kind: MarketKind) MarketIdentity {
    return switch (kind) {
        .passerby => .{
            .signal = "\u{25CF} PASSERBY",
            .copy = "Fishing net, hand axe, preserved food.",
            .action = "TRADE \u{2192}",
            .tone = .warn,
        },
        .merchant => .{
            .signal = "\u{25CF} MERCHANT",
            .copy = "9 lots \u{00B7} water, fuel, metal, minerals, goods.",
            .action = "TRADE \u{2192}",
            .tone = .warn,
        },
        .exchange => .{
            .signal = "\u{25C6} EXCHANGE",
            .copy = "The permanent market is open.",
            .action = "ENTER \u{2192}",
            .tone = .good,
        },
    };
}

/// Build the market strip for `kind`. Returns the borderless action-link `El` so the caller
/// reads `.query().clicked` to open the deal (the strip owns presentation, the caller owns it).
pub fn market_strip(parent: El, id: []const u8, kind: MarketKind) !El {
    const ctx = parent.ctx;
    const th = ctx.res.view.theme;
    const idn = marketIdentity(kind);
    const signal_color = toneColor(ctx, idn.tone);

    // CSS counterpart: `.merchant-strip` — one full-width 32px border-box with a dashed
    // line-2 edge. Padding is represented by in-flow lanes so percentage width remains the
    // border-box width instead of acquiring content-box overflow.
    const strip = try parent.div(id);
    _ = strip.with_size(.{ .pct_of_parent = 1.0 }, .{ .fixed = market_h })
        .with_overflow(.clip)
        .with_style(.{Style{
        .outline_color = th.line2,
        .outline_width = 1,
        .outline_style = .dashed,
    }});

    // Anchor one full-width, fit-height row at the strip center. Signal, copy, and action all
    // use the same 12px font, but copy/action live in wrapper lanes; box centering avoids mixing
    // a direct text baseline with wrapper references and gives all three columns one center line.
    const content = try strip.div("content");
    _ = content.with_layout(.center)
        .with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_flow(.{ .dir = .row, .cross = .center });

    _ = try content.spacer("lead", market_pad_x, 1);

    _ = (try content.text("signal", idn.signal))
        .with_style(.{Style{ .font = market_font, .text = signal_color }});

    _ = try content.spacer("gap_one", market_gap, 1);

    const copy_lane = try content.div("copy_lane");
    _ = copy_lane.with_size(.grow, .fit_children).with_overflow(.clip);
    _ = (try copy_lane.text("copy", idn.copy))
        .with_style(.{Style{ .font = market_font, .text = th.fg }});

    _ = try content.spacer("gap_two", market_gap, 1);

    // The prototype action is a zero-padding link, not a primary button. The text itself is
    // the hit target; it rests dim and lifts to accent on hover/hold/focus.
    const act = try content.div("act");
    _ = act.with_size(.fit_children, .fit_children).with_flow(.{ .dir = .row });
    const aq = act.control(.{ .name = idn.action, .role = .button });
    const action_color = if (aq.hovering or aq.held or aq.focused) th.acc else th.dim;
    _ = (try act.text("label", idn.action))
        .with_style(.{Style{ .font = market_font, .text = action_color }});

    _ = try content.spacer("tail", market_pad_x, 1);
    return act;
}

// —— ActivityStrip ——————————————————————————————————————————————————————————————————————

/// What the actor is doing. The identity map's key.
pub const ActivityState = enum { idle, working, building };

/// The presentation an activity resolves to — a pure table row.
pub const ActivityIdentity = struct {
    signal: []const u8,
    tone: Tone,
};

/// The **identity map** (pure, tested): exact prototype signal and semantic tone per state.
pub fn activityIdentity(state: ActivityState) ActivityIdentity {
    return switch (state) {
        .idle => .{ .signal = "\u{25CB} IDLING", .tone = .dim },
        .working => .{ .signal = "\u{25CF} WORKING", .tone = .accent },
        .building => .{ .signal = "\u{25A0} BUILDING", .tone = .warn },
    };
}

/// Build the activity strip: state signal + fg subject + state-toned metadata. The strip shares
/// the market's exact 32px dashed border-box and three-column geometry. When `state` differs
/// from `last`, emit a live announcement ("Building shelter") and return the state to remember.
pub fn activity_strip(parent: El, id: []const u8, state: ActivityState, subject: []const u8, metadata: []const u8, last: ActivityState) !ActivityState {
    const ctx = parent.ctx;
    const th = ctx.res.view.theme;
    const idn = activityIdentity(state);
    const state_color = toneColor(ctx, idn.tone);

    const strip = try parent.div(id);
    _ = strip.with_size(.{ .pct_of_parent = 1.0 }, .{ .fixed = market_h })
        .with_overflow(.clip)
        .with_style(.{Style{
        .outline_color = th.line2,
        .outline_width = 1,
        .outline_style = .dashed,
    }});

    // Every visible field is 12px. Center their boxes rather than mixing direct-text and
    // wrapper baselines, the same correction used by market_strip.
    const content = try strip.div("content");
    _ = content.with_layout(.center)
        .with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_flow(.{ .dir = .row, .cross = .center });

    _ = try content.spacer("lead", market_pad_x, 1);

    _ = (try content.text("signal", idn.signal))
        .with_style(.{Style{ .font = market_font, .text = state_color }});

    _ = try content.spacer("gap_one", market_gap, 1);

    const subject_lane = try content.div("subject_lane");
    _ = subject_lane.with_size(.grow, .fit_children).with_overflow(.clip);
    _ = (try subject_lane.text("subject", subject))
        .with_style(.{Style{ .font = market_font, .text = th.fg }});

    _ = try content.spacer("gap_two", market_gap, 1);

    if (metadata.len > 0) {
        _ = (try content.text("metadata", metadata))
            .with_style(.{Style{ .font = market_font, .text = state_color }});
    }

    _ = try content.spacer("tail", market_pad_x, 1);

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

test "market identity map mirrors prototype signal copy action and tone" {
    const passerby = marketIdentity(.passerby);
    try std.testing.expectEqualStrings("\u{25CF} PASSERBY", passerby.signal);
    try std.testing.expectEqualStrings("Fishing net, hand axe, preserved food.", passerby.copy);
    try std.testing.expectEqualStrings("TRADE \u{2192}", passerby.action);
    try std.testing.expectEqual(Tone.warn, passerby.tone);

    const merchant = marketIdentity(.merchant);
    try std.testing.expectEqualStrings("\u{25CF} MERCHANT", merchant.signal);
    try std.testing.expectEqualStrings("9 lots \u{00B7} water, fuel, metal, minerals, goods.", merchant.copy);
    try std.testing.expectEqualStrings("TRADE \u{2192}", merchant.action);
    try std.testing.expectEqual(Tone.warn, merchant.tone);

    try std.testing.expectEqualStrings("\u{25C6} EXCHANGE", marketIdentity(.exchange).signal);
    try std.testing.expectEqual(Tone.good, marketIdentity(.exchange).tone);
}

test "market strip geometry mirrors prototype border box" {
    try std.testing.expectEqual(@as(f32, 32), market_h);
    try std.testing.expectEqual(@as(f32, 9), market_pad_x);
    try std.testing.expectEqual(@as(f32, 10), market_gap);
    try std.testing.expectEqual(@as(f32, 12), market_font);
}

test "activity identity map mirrors prototype signal and tone" {
    const idle = activityIdentity(.idle);
    try std.testing.expectEqualStrings("\u{25CB} IDLING", idle.signal);
    try std.testing.expectEqual(Tone.dim, idle.tone);

    const working = activityIdentity(.working);
    try std.testing.expectEqualStrings("\u{25CF} WORKING", working.signal);
    try std.testing.expectEqual(Tone.accent, working.tone);

    const building = activityIdentity(.building);
    try std.testing.expectEqualStrings("\u{25A0} BUILDING", building.signal);
    try std.testing.expectEqual(Tone.warn, building.tone);

    // Activity and market are the same shared prototype strip box.
    try std.testing.expectEqual(@as(f32, 32), market_h);
    try std.testing.expectEqual(@as(f32, 9), market_pad_x);
    try std.testing.expectEqual(@as(f32, 10), market_gap);
    try std.testing.expectEqual(@as(f32, 12), market_font);
}
