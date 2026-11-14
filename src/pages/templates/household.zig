//! `household` — the rail's whole column, the same template in every act: a SETTLEMENT panel of
//! aggregates (the people, the energy, what the settlement makes and uses), a BODY panel of the
//! player's own condition 12px below it, then the eating policy at their foot, aligned to the
//! panels. An act with no settlement (Act I, one person) builds no SETTLEMENT panel and BODY
//! leads the column. The policy is not a verb, so it lives with the body whose projections it
//! moves rather than in the action catalog; it collapses with the rail because the rail only
//! builds this while expanded. Rail collapse chrome remains the rail template's responsibility.
//!
//! The panels own presentation only. Each act projects its own domain state into a `Content`
//! (`pages/act_one/household.zig`, `pages/act_two/household.zig`); the strings are the act's and
//! the tones and verdicts are semantic, so the panels read no world state. The eating policy
//! reads the agent's metabolism and writes the ration intent.

const std = @import("std");
const ha = @import("ha");

const comp = ha.sim.comp;
const World = ha.sim.ecs.World;
const Entity = ha.sim.ecs.Entity;
const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const El = el.El;

const readout = @import("./readout.zig");
const eating_policy_mod = @import("./eating_policy.zig");
const eating_mod = @import("../eating.zig");

// CSS counterpart: a 252px rail minus 2px rail padding and 10px panel margin. The engine's
// fixed sizes are content boxes, so panel widths below subtract their authored padding.
const column_width: f32 = 240;
const panel_pad: readout.Pad = .{ .up = 9, .right = 10, .down = 9, .left = 10 };
const panel_content_width: f32 = 220; // 240 - 10 left - 10 right
const panel_gap: f32 = 12;
/// Under SETTLEMENT's title. The rail's collapse control covers the leading panel's upper-right
/// corner, 26px down, and this gap starts the first line, whose value sits at that edge, below it.
const settlement_title_gap: f32 = 8;
/// Under BODY's title (`.body-panel`): its sentences start at the left and stop short of the
/// control when BODY leads the column.
const body_title_gap: f32 = 1;

/// A value's semantic color. Labels stay `fg`/`dim`; only the value carries the tone.
pub const Tone = enum { fg, dim, good, warn, danger };
const Verdict = style.Verdict;

/// One `label … value` line. `key` is its stable node id (a resource tag, a condition's name)
/// so a line keeps its identity as the list around it changes. A set `verdict` (what the value
/// means) paints the value instead of `tone`.
pub const Line = struct { key: []const u8, label: []const u8, value: []const u8, tone: Tone = .dim, verdict: ?Verdict = null };

/// One BODY sentence: dim prose around one live value, in `verdict`'s color when set, else
/// `tone`'s.
pub const Sentence = struct { key: []const u8, prefix: []const u8, value: []const u8, suffix: []const u8, tone: Tone = .fg, verdict: ?Verdict = null };

/// The SETTLEMENT panel: the aggregate lines, then one titled section of per-day lines.
pub const Settlement = struct {
    lines: []const Line,
    section_title: []const u8,
    section: []const Line,
};

/// The BODY panel: the player's own condition. `sentences` project it forward, `lines` are
/// what the body is working with (the food it eats, its ceiling); `note` replaces the
/// sentences when the act has no projection.
pub const Body = struct {
    sentences: []const Sentence = &.{},
    note: ?[]const u8 = null,
    lines: []const Line = &.{},
};

/// What one act shows in the column. A null `settlement` builds no SETTLEMENT panel.
pub const Content = struct {
    settlement: ?Settlement = null,
    body: Body,
};

/// A value's color: its verdict's through the view's table, else its tone's.
fn valueColor(ctx: *uic.UiCtx, tone: Tone, verdict: ?Verdict) uic.Color {
    return if (verdict) |v| style.verdictColor(ctx, v) else style.toneColor(ctx, tone);
}

fn lines(parent: El, id: []const u8, items: []const Line) !void {
    const col = try parent.box(id, .{ .w = .{ .pct_of_parent = 1.0 }, .h = .fit_children, .flow = .{ .dir = .column }, .gap = 4 }, .{});
    for (items) |l| try readout.kv_line(col, l.key, l.label, l.value, valueColor(parent.ctx, l.tone, l.verdict));
}

fn panel(parent: El, id: []const u8, title: []const u8, title_gap: f32, col_w: f32) !El {
    const p = try readout.readout_panel(parent, id, col_w - panel_pad.left - panel_pad.right, panel_pad);
    (try readout.section_label(p, "title", title)).set(.{ .margin = .{ .after = title_gap } }, .{});
    return p;
}

fn settlementPanel(parent: El, s: Settlement, col_w: f32) !void {
    const p = try panel(parent, "settlement", "SETTLEMENT", settlement_title_gap, col_w);
    try lines(p, "lines", s.lines);
    try readout.divider(p, "divider", 9, 7);
    (try readout.section_label(p, "section_title", s.section_title)).set(.{ .margin = .{ .after = 8 } }, .{});
    try lines(p, "section", s.section);
}

fn bodyPanel(parent: El, b: Body, col_w: f32) !void {
    const p = try panel(parent, "body", "BODY", body_title_gap, col_w);
    if (b.note) |note| {
        try p.label("note", note, .{style.note});
    } else {
        // `.body-panel` sets its sentences at 11px on a 1.35 line, no gap between them.
        const list = try p.box("list", .{ .w = .{ .pct_of_parent = 1.0 }, .h = .fit_children, .flow = .{ .dir = .column }, .gap = 0 }, .{});
        for (b.sentences) |s| try readout.sentence(list, s.key, s.prefix, s.value, s.suffix, valueColor(parent.ctx, s.tone, s.verdict));
    }
    if (b.lines.len == 0) return;
    try readout.divider(p, "divider", 9, 7);
    try lines(p, "lines", b.lines);
}

/// The stacked column: one panel's width and whether two panels sit side by side.
pub fn stackedColumn(ctx: *uic.UiCtx) struct { total: f32, col_w: f32, two_up: bool } {
    const total = @import("./terminal.zig").stackedWidth(ctx);
    const two_up = !ctx.res.view.metrics.width_class.atMost(.w560);
    return .{ .total = total, .col_w = if (two_up) (total - stacked_gap) / 2 else total, .two_up = two_up };
}

/// The stacked rail's column gap (`.side-rail` as a two-column grid).
const stacked_gap: f32 = 22;

/// Build the SETTLEMENT and BODY panels from one act's `Content`. Framed, they are the rail's
/// 240px column. Stacked (≤760) they span the page: side by side at the 760 class, one above
/// the other below 560. Returns the box the column's foot (the eating policy) goes into, at
/// one panel's width.
fn panels(parent: El, id: []const u8, c: Content) !El {
    const ctx = parent.ctx;
    const terminal = @import("./terminal.zig");
    if (terminal.stacked(ctx)) {
        const sc = stackedColumn(ctx);
        const column = try parent.box(id, .{
            .w = .{ .fixed = sc.total }, .h = .fit_children, .flow = .{ .dir = .column, .cross = .start },
            .gap = panel_gap,
        }, .{});
        const row = try column.box("panels", .{
            .w = .{ .fixed = sc.total }, .h = .fit_children,
            .flow = .{ .dir = if (sc.two_up) .row else .column, .cross = .start },
            .gap = if (sc.two_up) stacked_gap else panel_gap,
        }, .{});
        if (c.settlement) |s| try settlementPanel(row, s, sc.col_w);
        try bodyPanel(row, c.body, sc.col_w);
        return column.box("foot", .{ .w = .{ .fixed = sc.col_w }, .h = .fit_children, .flow = .{ .dir = .column } }, .{});
    }
    const column = try parent.box(id, .{
        .w = .{ .fixed = column_width }, .h = .fit_children, .flow = .{ .dir = .column, .cross = .start },
        .gap = panel_gap,
    }, .{});
    if (c.settlement) |s| try settlementPanel(column, s, column_width);
    try bodyPanel(column, c.body, column_width);
    return column;
}

/// Build the column for agent `e`; when the slider's rate differs from its metabolism rate,
/// write `SetRation`, which the ration handler applies before the next build. Only a change is
/// written, so a still slider writes nothing. An agent with no metabolism shows the policy
/// disabled at normal.
pub fn household(parent: El, world: *const World, e: Entity, id: []const u8, content: Content) !El {
    const ctx = parent.ctx;
    const column = try panels(parent, id, content);
    if (world.get(e, comp.Metabolism)) |met| {
        const band = eating_mod.Band.of(ctx.res.game.config);
        const value = try eating_policy_mod.eating_policy(column, "eating_policy", eating_mod.valueFromRate(met.rate, band), true);
        const rate = eating_mod.rate(value, band);
        if (rate != met.rate) _ = ctx.res.game.events.writer(ha.sim.events.SetRation).push(.{ .agent = e, .rate = rate });
    } else {
        _ = try eating_policy_mod.eating_policy(column, "eating_policy", 50, false);
    }
    return column;
}

test "household column geometry mirrors the standalone reference" {
    try std.testing.expectEqual(@as(f32, 240), column_width);
    try std.testing.expectEqual(@as(f32, 12), panel_gap);
    try std.testing.expectEqual(@as(f32, 240), panel_content_width + panel_pad.left + panel_pad.right);
}
