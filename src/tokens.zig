//! `tokens` — the game's **design tokens, encoded once** (KIT-01). One authoritative place
//! for the finalized non-color layout scalars: page padding, the common gap ladder, the
//! hairline width, the control-height ladder, and a re-export of the already-centralized
//! typography sizes (`ui_client.type`) and functional-transition durations
//! (`ui_client.tween`). Colors are the other half of the token set and live where a color
//! *role* belongs: the foundation roles in `ui_client/theme.zig` (`Theme`, incl. the KIT-01
//! `good` role) and the game's values + resource/sector hues + terminal ground in
//! `palette.zig`. So a call site cites `tokens.pad_page` / `tokens.gap.row` /
//! `tokens.control.h_std` / `type.heading` / `tween.holdings_s` instead of a bare literal,
//! and every finalized number has exactly one definition.
//!
//! **All scalars here are *logical* px / seconds** — the pre-scale authoring units. The one
//! logical→device multiply is `ui_client.type.toDevice` (fonts) / `view.dp` (geometry) /
//! `paint.hairline` (borders); nothing here is pre-multiplied, so a token is stable across
//! DPI and the responsive scale is applied downstream exactly once (VIEW-01/02).
//!
//! A **leaf, data-only** module: no SDL, no engine, no allocation — just named constants —
//! so it is free to import from any tier (templates, screens, `res`).

const typ = @import("./ui_client/type.zig");
const tween = @import("./ui_client/tween.zig");

// —— Typography sizes (re-exported; authored in `ui_client/type.zig`) ————————————————————
// The typography contract (size + tracking + case, coupled) already lives in one module
// (TEXT-04). Re-exported here as bare logical-px sizes so KIT-01's "centralize body/small/
// heading sizes" has a single citation point next to the other layout tokens, without
// duplicating the numbers — these *are* the `type` roles' sizes.

/// Body copy — the base of the ladder and the unstyled default (14 logical px).
pub const size_body: f32 = typ.body.size_logical_px;
/// Small/secondary copy — captions, dense readouts (11 logical px).
pub const size_small: f32 = typ.small.size_logical_px;
/// Heading — the prototype `--h3` (21 logical px).
pub const size_heading: f32 = typ.heading.size_logical_px;

// —— Page padding —————————————————————————————————————————————————————————————————————
/// The standard page inset (desktop / roomy width classes). The responsive branch narrows
/// it (VIEW-04 uses `pad_page_compact` at ≤560); both were bare literals in `play_game.zig`
/// before KIT-01.
pub const pad_page: f32 = 16;
/// The compact page inset applied at the ≤560 width class (VIEW-04).
pub const pad_page_compact: f32 = 10;

// —— The common gap ladder ————————————————————————————————————————————————————————————
/// Named steps for the spacing between children — the recurring values the templates set
/// via `El.with_gap` / `style.gap`. A small fixed ladder rather than free numbers so the
/// rhythm stays consistent; a site picks the nearest step by intent.
pub const gap = struct {
    /// Hairline-tight rows inside a dense list (Holdings rows).
    pub const tight: f32 = 3;
    /// Between a label and its value, icon and text — the default inline gap.
    pub const inline_: f32 = 6;
    /// Between stacked lines in a card / column.
    pub const stack: f32 = 10;
    /// Between distinct groups on a row (a runline, a header cluster).
    pub const group: f32 = 12;
    /// Between top-level page sections.
    pub const section: f32 = 16;
    /// A loose wrap gap for chip/check strips.
    pub const wrap: f32 = 20;
};

// —— Hairline ——————————————————————————————————————————————————————————————————————————
/// The authored border/separator thickness (1 logical px). Snapped to a whole *device* px
/// at draw by `paint.hairline` (RENDER-06), so this is the pre-scale intent, not the drawn
/// width. The default `outline_width` when a `Style` sets only an `outline_color`.
pub const hairline: f32 = 1;

// —— Control heights ——————————————————————————————————————————————————————————————————
/// The control-height ladder — the fixed heights interactive controls stand at, in logical
/// px. `compact` is the prototype's `30px` popup/select height (KIT-09 cites it); `std` is
/// the ordinary button/field height; `tall` is a primary/CTA row.
pub const control = struct {
    pub const h_compact: f32 = 30;
    pub const h_std: f32 = 34;
    pub const h_tall: f32 = 40;
};

// —— Rail widths (KIT-05) ——————————————————————————————————————————————————————————————
/// The collapsible Holdings/BODY rail widths (KIT-05): `expanded` `252`, `collapsed` `36`.
/// Encoded here so the rail template and any layout that reserves space for it read one value.
pub const rail = struct {
    pub const expanded: f32 = 252;
    pub const collapsed: f32 = 36;
};

// —— Transition durations (re-exported; authored in `ui_client/tween.zig`) ————————————————
// The functional-transition durations already live in one module (RENDER-08), in seconds.
// Re-exported so KIT-01's "centralize transition durations" has one citation point beside
// the layout tokens without duplicating the values.

/// Holdings/BODY rail collapse transition (`120ms`, KIT-05).
pub const dur_rail_s: f32 = tween.holdings_s;
/// Stock-token font swap transition (`90ms`).
pub const dur_stock_token_s: f32 = tween.stock_token_s;
/// Board state-change transition (`~105ms`).
pub const dur_board_s: f32 = tween.board_s;

// ============================ Tests ==========================================
const std = @import("std");

test "token sizes mirror the type roles (single source, no drift)" {
    try std.testing.expectEqual(@as(f32, 14), size_body);
    try std.testing.expectEqual(@as(f32, 11), size_small);
    try std.testing.expectEqual(@as(f32, 21), size_heading);
    try std.testing.expectEqual(typ.body.size_logical_px, size_body);
}

test "token durations mirror the tween durations (single source, no drift)" {
    try std.testing.expectEqual(tween.holdings_s, dur_rail_s);
    try std.testing.expectEqual(@as(f32, 0.120), dur_rail_s);
}

test "the rail widths are the KIT-05 finalized values" {
    try std.testing.expectEqual(@as(f32, 252), rail.expanded);
    try std.testing.expectEqual(@as(f32, 36), rail.collapsed);
}

test "the gap ladder is monotonic" {
    try std.testing.expect(gap.tight < gap.inline_);
    try std.testing.expect(gap.inline_ < gap.stack);
    try std.testing.expect(gap.stack < gap.group);
    try std.testing.expect(gap.group < gap.section);
    try std.testing.expect(gap.section < gap.wrap);
}

test "the control-height ladder is monotonic" {
    try std.testing.expect(control.h_compact < control.h_std);
    try std.testing.expect(control.h_std < control.h_tall);
}
