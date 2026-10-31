//! `holdings` — the rail's HOLDINGS + BODY column, the same template on every act. One bordered
//! HOLDINGS panel carries the owned-good roster and one titled section of readout lines (Act I's
//! MARGINS, Act II's FLOWS / DAY); a distinct bordered BODY panel of one-value sentences sits
//! 12px below it. Rail collapse chrome remains the rail template's responsibility.
//!
//! The template owns presentation only. Each act projects its own domain state into a `Content`
//! (`pages/act_one/holdings.zig`, `pages/act_two/holdings.zig`); the strings are the act's and
//! the tones are semantic, so this file reads no world state.

const std = @import("std");
const ha = @import("ha");

const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const El = el.El;

const readout = @import("./readout.zig");

// CSS counterpart: a 252px rail minus 2px rail padding and 10px panel margin. The engine's
// fixed sizes are content boxes, so panel widths below subtract their authored padding.
const column_width: f32 = 240;
const main_pad: readout.Pad = .{ .up = 10, .right = 16, .down = 9, .left = 10 };
const body_pad: readout.Pad = .{ .up = 9, .right = 10, .down = 9, .left = 10 };
const main_content_width: f32 = 214; // 240 - 10 left - 16 right
const body_content_width: f32 = 220; // 240 - 10 left - 10 right
const panel_gap: f32 = 12;

/// A value's semantic color. Labels stay `fg`/`dim`; only the value carries the tone.
pub const Tone = enum { fg, dim, good, warn, danger };

/// One `label … value` line. `key` is its stable node id (a good's or verb's id, a resource
/// tag) so a line keeps its identity as the list around it changes.
pub const Line = struct { key: []const u8, label: []const u8, value: []const u8, tone: Tone = .dim };

/// One BODY sentence: dim prose around one live value.
pub const Sentence = struct { key: []const u8, prefix: []const u8, value: []const u8, suffix: []const u8, tone: Tone = .fg };

/// What one act shows in the column.
pub const Content = struct {
    /// The HOLDINGS heading's right-hand count (`7 KINDS, 9`).
    count: []const u8,
    /// Owned goods, in the act's order.
    roster: []const Line,
    /// Shown in place of an empty roster.
    empty_roster: []const u8 = "nothing built yet",
    /// The section under the roster: its title and lines.
    section_title: []const u8,
    section: []const Line,
    /// The BODY panel's sentences; `body_note` replaces them when the act has no projection.
    body: []const Sentence,
    body_note: ?[]const u8 = null,
};

fn lines(parent: El, id: []const u8, items: []const Line, gap: f32) !void {
    const col = try parent.div(id);
    _ = col.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_flow(.{ .dir = .column }).with_gap(gap);
    for (items) |l| try readout.kv_line(col, l.key, l.label, l.value, style.toneColor(parent.ctx, l.tone));
}

/// The heading's right inset inside the panel's content box (`.panel-heading`'s 16px), which
/// keeps the count clear of the rail's collapse control at the panel's upper-right corner.
const heading_inset: f32 = 16;

fn mainPanel(parent: El, c: Content, col_w: f32) !void {
    const content_w = col_w - main_pad.left - main_pad.right;
    const panel = try readout.readout_panel(parent, "panel", content_w, main_pad);
    const heading_box = try panel.div("heading_box");
    _ = heading_box.with_size(.{ .fixed = content_w - heading_inset }, .fit_children).with_margin(0, 8);
    _ = try readout.readout_heading(heading_box, "heading", "HOLDINGS", c.count);
    if (c.roster.len == 0) {
        _ = (try panel.text("none", c.empty_roster))
            .with_style(.{ style.body, style.faint });
    } else {
        try lines(panel, "roster", c.roster, 3);
    }
    try readout.divider(panel, "divider", 9, 7);
    _ = (try readout.section_label(panel, "section_title", c.section_title)).with_margin(0, 8);
    try lines(panel, "section", c.section, 4);
}

fn bodyPanel(parent: El, c: Content, col_w: f32) !void {
    const panel = try readout.readout_panel(parent, "body", col_w - body_pad.left - body_pad.right, body_pad);
    _ = (try readout.section_label(panel, "title", "BODY")).with_margin(0, 1);
    if (c.body_note) |note| {
        _ = (try panel.text("note", note)).with_style(.{style.note});
        return;
    }
    // `.body-panel` sets its sentences at 11px on a 1.35 line, no gap between them.
    const list = try panel.div("list");
    _ = list.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_flow(.{ .dir = .column }).with_gap(0);
    for (c.body) |s| try readout.sentence(list, s.key, s.prefix, s.value, s.suffix, style.toneColor(parent.ctx, s.tone));
}

/// The stacked column: one panel's width and whether HOLDINGS and BODY sit side by side.
pub fn stackedColumn(ctx: *uic.UiCtx) struct { total: f32, col_w: f32, two_up: bool } {
    const total = @import("./terminal.zig").stackedWidth(ctx);
    const two_up = !ctx.res.view.metrics.width_class.atMost(.w560);
    return .{ .total = total, .col_w = if (two_up) (total - stacked_gap) / 2 else total, .two_up = two_up };
}

/// Build the HOLDINGS + BODY column from one act's `Content`. Framed, it is the rail's 240px
/// column. Stacked (≤760) it spans the page: HOLDINGS and BODY side by side at the 760 class,
/// one above the other below 560. Returns the box the household's foot (the eating policy)
/// goes into, at one panel's width.
pub fn holdings(parent: El, id: []const u8, c: Content) !El {
    const ctx = parent.ctx;
    const terminal = @import("./terminal.zig");
    if (terminal.stacked(ctx)) {
        const sc = stackedColumn(ctx);
        const total = sc.total;
        const two_up = sc.two_up;
        const col_w = sc.col_w;
        const column = try parent.div(id);
        _ = column.with_size(.{ .fixed = total }, .fit_children)
            .with_flow(.{ .dir = .column, .cross = .start }).with_gap(panel_gap);
        const panels = try column.div("panels");
        _ = panels.with_size(.{ .fixed = total }, .fit_children)
            .with_flow(.{ .dir = if (two_up) .row else .column, .cross = .start }).with_gap(if (two_up) stacked_gap else panel_gap);
        try mainPanel(panels, c, col_w);
        try bodyPanel(panels, c, col_w);
        const foot = try column.div("foot");
        _ = foot.with_size(.{ .fixed = col_w }, .fit_children).with_flow(.{ .dir = .column });
        return foot;
    }
    const column = try parent.div(id);
    _ = column.with_size(.{ .fixed = column_width }, .fit_children)
        .with_flow(.{ .dir = .column, .cross = .start }).with_gap(panel_gap);
    try mainPanel(column, c, column_width);
    try bodyPanel(column, c, column_width);
    return column;
}

/// The stacked rail's column gap (`.side-rail` as a two-column grid).
const stacked_gap: f32 = 22;

test "holdings column geometry mirrors the standalone reference" {
    try std.testing.expectEqual(@as(f32, 240), column_width);
    try std.testing.expectEqual(@as(f32, 12), panel_gap);
    try std.testing.expectEqual(@as(f32, 240), main_content_width + main_pad.left + main_pad.right);
    try std.testing.expectEqual(@as(f32, 240), body_content_width + body_pad.left + body_pad.right);
}
