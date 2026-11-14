//! `household` — the rail's whole column, the same template in every act: a SETTLEMENT panel of
//! aggregates (the people, then what the settlement makes, uses and holds) and, 12px below it,
//! a PLAYER panel of the player's own condition, which ends on the eating policy. The two are
//! one grammar: the same padding, a title, then `label … value` lines on one rhythm, the label
//! in the body ink and the value small at the panel's right edge. An act with no
//! settlement (Act I, one person) builds no SETTLEMENT panel and PLAYER leads the column. The
//! policy is not a verb, so it lives in the panel whose lines it moves rather than in
//! the action catalog; it collapses with the rail because the rail only builds this while
//! expanded. Rail collapse chrome remains the rail template's responsibility.
//!
//! The panels own presentation only. Each act projects its own domain state into a `Content`
//! (`pages/act_one/household.zig`, `pages/act_two/household.zig`); the strings are the act's and
//! the tones and verdicts are semantic. The one world read is PLAYER's eating policy, which
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
/// Under a panel's title. The rail's collapse control covers the leading panel's upper-right
/// corner, 26px down, and this gap starts the first line, whose value sits at that edge, below it.
const title_gap: f32 = 8;
/// Between a panel's lines, and between PLAYER's last line and the eating policy's.
const line_gap: f32 = 4;

/// A value's semantic color. Labels stay `fg`/`dim`; only the value carries the tone.
pub const Tone = enum { fg, dim, good, warn, danger };
const Verdict = style.Verdict;

/// One `label … value` line. `key` is its stable node id (a resource tag, a condition's name)
/// so a line keeps its identity as the list around it changes. A set `verdict` (what the value
/// means) paints the value instead of `tone`. A non-null `stock` is the amount held, printed
/// in its own column after the value, in `fg` or its `stock_verdict`'s color; empty, it keeps
/// the column for a line with nothing to hold.
pub const Line = struct {
    key: []const u8,
    label: []const u8,
    value: []const u8,
    tone: Tone = .dim,
    verdict: ?Verdict = null,
    stock: ?[]const u8 = null,
    stock_verdict: ?Verdict = null,
};

/// The SETTLEMENT panel: one list of aggregate lines under the title, with no sub-sections. A
/// line of a stock carries what is held after its value.
pub const Settlement = struct {
    lines: []const Line,
};

/// The PLAYER panel's projection: the player's own condition as lines; `note` replaces them
/// when the agent has no projection. The panel adds the eating policy under them.
pub const Player = struct {
    lines: []const Line = &.{},
    note: ?[]const u8 = null,
};

/// What one act shows in the column. A null `settlement` builds no SETTLEMENT panel.
pub const Content = struct {
    settlement: ?Settlement = null,
    player: Player,
};

/// A value's color: its verdict's through the view's table, else its tone's.
fn valueColor(ctx: *uic.UiCtx, tone: Tone, verdict: ?Verdict) uic.Color {
    return if (verdict) |v| style.verdictColor(ctx, v) else style.toneColor(ctx, tone);
}

fn lines(parent: El, id: []const u8, items: []const Line) !void {
    const col = try parent.box(id, .{ .w = .{ .pct_of_parent = 1.0 }, .h = .fit_children, .flow = .{ .dir = .column }, .gap = line_gap }, .{});
    for (items) |l| {
        const color = valueColor(parent.ctx, l.tone, l.verdict);
        if (l.stock) |stock| {
            try readout.kv_stock_line(col, l.key, l.label, l.value, color, stock, valueColor(parent.ctx, .fg, l.stock_verdict));
        } else {
            try readout.kv_line(col, l.key, l.label, l.value, color);
        }
    }
}

fn panel(parent: El, id: []const u8, title: []const u8, col_w: f32) !El {
    const p = try readout.readout_panel(parent, id, col_w - panel_pad.left - panel_pad.right, panel_pad);
    (try readout.section_label(p, "title", title)).set(.{ .margin = .{ .after = title_gap } }, .{});
    return p;
}

fn settlementPanel(parent: El, s: Settlement, col_w: f32) !void {
    const p = try panel(parent, "settlement", "SETTLEMENT", col_w);
    try lines(p, "lines", s.lines);
}

/// PLAYER: the lines, then the eating policy as the list's last line and its slider. When the slider's rate differs
/// from agent `e`'s metabolism rate it writes `SetRation`, which the ration handler applies
/// before the next build; only a change is written, so a still slider writes nothing. An agent
/// with no metabolism shows the policy disabled at normal.
fn playerPanel(parent: El, world: *const World, e: Entity, b: Player, col_w: f32) !void {
    const ctx = parent.ctx;
    const p = try panel(parent, "player", "PLAYER", col_w);
    if (b.note) |note| {
        try p.label("note", note, .{style.note});
    } else {
        try lines(p, "lines", b.lines);
    }
    // The policy's line follows the others on the same rhythm.
    const slot = try p.box("policy", .{
        .w = .{ .pct_of_parent = 1.0 }, .h = .fit_children, .flow = .{ .dir = .column }, .margin = .{ .before = line_gap },
    }, .{});
    if (world.get(e, comp.Metabolism)) |met| {
        const band = eating_mod.Band.of(ctx.res.game.config);
        const value = try eating_policy_mod.eating_policy(slot, "eating_policy", eating_mod.valueFromRate(met.rate, band), true);
        const rate = eating_mod.rate(value, band);
        if (rate != met.rate) _ = ctx.res.game.events.writer(ha.sim.events.SetRation).push(.{ .agent = e, .rate = rate });
    } else {
        _ = try eating_policy_mod.eating_policy(slot, "eating_policy", 50, false);
    }
}

/// The stacked column: one panel's width and whether two panels sit side by side.
pub fn stackedColumn(ctx: *uic.UiCtx) struct { total: f32, col_w: f32, two_up: bool } {
    const total = @import("./terminal.zig").stackedWidth(ctx);
    const two_up = !ctx.res.view.metrics.width_class.atMost(.w560);
    return .{ .total = total, .col_w = if (two_up) (total - stacked_gap) / 2 else total, .two_up = two_up };
}

/// The stacked rail's column gap (`.side-rail` as a two-column grid).
const stacked_gap: f32 = 22;

/// Build the column for agent `e` from one act's `Content`. Framed, it is the rail's 240px
/// column. Stacked (≤760) it spans the page: the panels side by side at the 760 class, each
/// half the page wide, one above the other below 560.
pub fn household(parent: El, world: *const World, e: Entity, id: []const u8, c: Content) !El {
    const ctx = parent.ctx;
    const terminal = @import("./terminal.zig");
    if (terminal.stacked(ctx)) {
        const sc = stackedColumn(ctx);
        const row = try parent.box(id, .{
            .w = .{ .fixed = sc.total }, .h = .fit_children,
            .flow = .{ .dir = if (sc.two_up) .row else .column, .cross = .start },
            .gap = if (sc.two_up) stacked_gap else panel_gap,
        }, .{});
        if (c.settlement) |s| try settlementPanel(row, s, sc.col_w);
        try playerPanel(row, world, e, c.player, sc.col_w);
        return row;
    }
    const column = try parent.box(id, .{
        .w = .{ .fixed = column_width }, .h = .fit_children, .flow = .{ .dir = .column, .cross = .start },
        .gap = panel_gap,
    }, .{});
    if (c.settlement) |s| try settlementPanel(column, s, column_width);
    try playerPanel(column, world, e, c.player, column_width);
    return column;
}

test "household column geometry mirrors the standalone reference" {
    try std.testing.expectEqual(@as(f32, 240), column_width);
    try std.testing.expectEqual(@as(f32, 12), panel_gap);
    try std.testing.expectEqual(@as(f32, 240), panel_content_width + panel_pad.left + panel_pad.right);
}
