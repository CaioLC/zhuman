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
const Style = style.Style;
const El = el.El;
const Color = uic.Color;

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

fn toneColor(th: uic.Theme, tone: Tone) Color {
    return switch (tone) {
        .fg => th.fg,
        .dim => th.dim,
        .good => th.good,
        .warn => th.warn,
        .danger => th.danger,
    };
}

fn lines(parent: El, id: []const u8, items: []const Line, gap: f32) !void {
    const th = parent.ctx.res.view.theme;
    const col = try parent.div(id);
    _ = col.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_flow(.{ .dir = .column }).with_gap(gap);
    for (items) |l| try readout.kv_line(col, l.key, l.label, l.value, toneColor(th, l.tone));
}

fn mainPanel(parent: El, c: Content) !void {
    const th = parent.ctx.res.view.theme;
    const panel = try readout.readout_panel(parent, "panel", main_content_width, main_pad);
    _ = try readout.readout_heading(panel, "heading", "HOLDINGS", c.count);
    _ = try panel.spacer("heading_gap", 1, 8);
    if (c.roster.len == 0) {
        _ = (try panel.text("none", c.empty_roster))
            .with_style(.{ style.body, Style{ .text = th.line2 } });
    } else {
        try lines(panel, "roster", c.roster, 3);
    }
    try readout.divider(panel, "divider", 9, 7);
    _ = try readout.section_label(panel, "section_title", c.section_title);
    _ = try panel.spacer("section_gap", 1, 8);
    try lines(panel, "section", c.section, 4);
}

fn bodyPanel(parent: El, c: Content) !void {
    const th = parent.ctx.res.view.theme;
    const panel = try readout.readout_panel(parent, "body", body_content_width, body_pad);
    _ = try readout.section_label(panel, "title", "BODY");
    _ = try panel.spacer("gap", 1, 6);
    if (c.body_note) |note| {
        _ = (try panel.text("note", note)).with_style(.{Style{ .font = 11, .text = th.dim }});
        return;
    }
    const list = try panel.div("list");
    _ = list.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_flow(.{ .dir = .column }).with_gap(5);
    for (c.body) |s| try readout.sentence(list, s.key, s.prefix, s.value, s.suffix, toneColor(th, s.tone));
}

/// Build the HOLDINGS + BODY column from one act's `Content`.
pub fn holdings(parent: El, id: []const u8, c: Content) !El {
    const column = try parent.div(id);
    _ = column.with_size(.{ .fixed = column_width }, .fit_children)
        .with_flow(.{ .dir = .column, .cross = .start }).with_gap(panel_gap);
    try mainPanel(column, c);
    try bodyPanel(column, c);
    return column;
}

test "holdings column geometry mirrors the standalone reference" {
    try std.testing.expectEqual(@as(f32, 240), column_width);
    try std.testing.expectEqual(@as(f32, 12), panel_gap);
    try std.testing.expectEqual(@as(f32, 240), main_content_width + main_pad.left + main_pad.right);
    try std.testing.expectEqual(@as(f32, 240), body_content_width + body_pad.left + body_pad.right);
}
