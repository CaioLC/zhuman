//! `settings_panel` — the one settings panel the title screen and the session menu share
//! (`.panel-body`, `.setting`): one row per setting, a 13ch label lane beside its field. A
//! field is a `choices` group (`.choices`, one pressed button), a `level` (a slider with its
//! percentage), and an optional note under it (`.setting-note`).
//!
//! The panel edits `Settings` in place and reports what changed; the caller applies a change
//! the host owns (the window). Difficulty, the volumes and contrast are held only (roadmap
//! PORT-03): the panel shows them exactly as the prototype does.

const std = @import("std");
const ha = @import("ha");
const uic = ha.ui_client;
const style = uic.style;
const Style = style.Style;
const El = uic.elements.El;
const Settings = ha.res.Settings;

const slider_mod = @import("./slider.zig");

/// The label lane: 13ch at the label's 10px.
const label_w: f32 = 13 * 6;
const row_gap: f32 = 12;
const panel_gap: f32 = 15;
/// The level readout's lane: 5ch at 11px.
const level_out_w: f32 = 5 * 6.6;

pub const Options = struct {
    /// The panel's width.
    width: f32,
    /// The title screen's notes under UI SCALE, CONTRAST and WINDOW; the menu shows only
    /// DIFFICULTY's.
    all_notes: bool = false,
};

pub const Changed = struct {
    window: bool = false,
    ui_scale: bool = false,
};

const difficulty_notes = [_][]const u8{
    "The valley is generous. Mistakes are survivable.",
    "The valley as it is.",
    "Everything takes longer and gives less.",
    "You will not build everything. Choose.",
};

/// One `.setting` row: the label, and the field column the caller fills.
fn settingRow(parent: El, id: []const u8, label: []const u8, width: f32) !El {
    const th = parent.ctx.res.view.theme;
    const row = try parent.div(id);
    _ = row.with_size(.{ .fixed = width }, .fit_children)
        .with_flow(.{ .dir = .row, .cross = .start }).with_gap(row_gap);
    _ = (try row.text_fit("label", label, .{ .cell = .{ .mode = .clip, .width = label_w } }))
        .with_style(.{ Style{ .font = 10, .tracking = 0.07, .text = th.dim }, style.pad_each(4, 0, 0, 0) });
    const field = try row.div("field");
    _ = field.with_size(.grow, .fit_children)
        .with_flow(.{ .dir = .column, .cross = .start }).with_gap(4);
    return field;
}

/// A `.choices` group: one button per label, the `selected` one pressed. Returns the button
/// clicked this frame.
pub fn choices(parent: El, id: []const u8, labels: []const []const u8, selected: ?usize) !?usize {
    const th = parent.ctx.res.view.theme;
    const group = try parent.div(id);
    _ = group.with_size(.fit_children, .fit_children)
        .with_flow(.{ .dir = .row, .cross = .center }).with_gap(5);
    var clicked: ?usize = null;
    for (labels, 0..) |label, i| {
        const b = try group.item("c", i);
        _ = b.with_size(.fit_children, .fit_children).with_flow(.{ .dir = .row });
        const on = selected == i;
        const q = b.control(.{ .name = label, .role = .radio, .checked = on, .selected = on });
        if (q.clicked) clicked = i;
        const hot = q.hovering or q.focused;
        const line = if (on) th.acc else if (hot) th.line2 else th.line;
        const text = if (on) th.acc else if (hot) th.fg else th.dim;
        _ = (try b.text("lbl", label)).with_style(.{ Style{ .font = 11, .text = text }, style.pad_sym(9, 3) });
        _ = b.with_style(.{Style{ .outline_color = line }});
    }
    return clicked;
}

/// A `.setting-note`: line2 prose, with an optional run of dim `.b` segments after it.
fn note(parent: El, id: []const u8, text: []const u8) !void {
    const th = parent.ctx.res.view.theme;
    _ = (try parent.text(id, text)).with_style(.{Style{ .font = 10, .text = th.line2 }});
}

/// DIFFICULTY's note: its sentence, then the two multipliers it names, in dim.
fn difficultyNote(parent: El, d: Settings.Difficulty) !void {
    const ctx = parent.ctx;
    const th = ctx.res.view.theme;
    try note(parent, "note", difficulty_notes[@intFromEnum(d)]);
    const terms = try parent.div("terms");
    _ = terms.with_flow(.{ .dir = .row, .cross = .center });
    const quiet = Style{ .font = 10, .text = th.line2 };
    const loud = Style{ .font = 10, .text = th.dim };
    _ = (try terms.text("a", "Inputs cost ")).with_style(.{quiet});
    _ = (try terms.text("cost", try ctx.arena.print("\u{00d7}{d:.2}", .{d.cost()}))).with_style(.{loud});
    _ = (try terms.text("b", ", yields return ")).with_style(.{quiet});
    _ = (try terms.text("yield", try ctx.arena.print("\u{00d7}{d:.2}", .{d.yield()}))).with_style(.{loud});
    _ = (try terms.text("c", ".")).with_style(.{quiet});
}

/// A `.level`: the slider filling the lane, then its value as a percentage.
fn level(parent: El, id: []const u8, label: []const u8, value: *f32) !void {
    const ctx = parent.ctx;
    const th = ctx.res.view.theme;
    const row = try parent.div(id);
    _ = row.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_flow(.{ .dir = .row, .cross = .center }).with_gap(10);
    const lane = try row.div("lane");
    _ = lane.with_size(.grow, .fit_children);
    const s = try slider_mod.slider(lane, .{ .id = "range", .label = label, .value = value.*, .min = 0, .max = 100, .step = 1 });
    value.* = s.value;
    _ = (try row.text_fit("out", try ctx.arena.print("{d:.0}%", .{s.value}), .{ .cell = .{ .mode = .clip, .width = level_out_w } }))
        .with_style(.{Style{ .font = 11, .text = th.fg }});
}

pub fn settings_panel(parent: El, id: []const u8, s: *Settings, opts: Options) !Changed {
    var changed: Changed = .{};
    const panel = try parent.div(id);
    _ = panel.with_size(.{ .fixed = opts.width }, .fit_children)
        .with_flow(.{ .dir = .column, .cross = .start }).with_gap(panel_gap);

    {
        const f = try settingRow(panel, "difficulty", "DIFFICULTY", opts.width);
        if (try choices(f, "choices", &.{ "ABUNDANT", "TEMPERATE", "HARSH", "BARREN" }, @intFromEnum(s.difficulty))) |i|
            s.difficulty = @enumFromInt(i);
        try difficultyNote(f, s.difficulty);
    }
    {
        const f = try settingRow(panel, "music", "MUSIC", opts.width);
        try level(f, "level", "Music volume", &s.music);
    }
    {
        const f = try settingRow(panel, "effects", "EFFECTS", opts.width);
        try level(f, "level", "Effects volume", &s.effects);
    }
    {
        const f = try settingRow(panel, "scale", "UI SCALE", opts.width);
        if (try choices(f, "choices", &.{ "90%", "100%", "110%", "125%" }, @intFromEnum(s.ui_scale))) |i| {
            const next: Settings.UiScale = @enumFromInt(i);
            changed.ui_scale = next != s.ui_scale;
            s.ui_scale = next;
        }
        if (opts.all_notes) try note(f, "note", "The interface is dense and mostly small text.");
    }
    {
        const f = try settingRow(panel, "contrast", "CONTRAST", opts.width);
        if (try choices(f, "choices", &.{ "NORMAL", "HIGH" }, @intFromEnum(s.contrast))) |i| s.contrast = @enumFromInt(i);
        if (opts.all_notes) try note(f, "note", "Raises the palette and separates the resource colours for red-green vision.");
    }
    {
        const f = try settingRow(panel, "window", "WINDOW", opts.width);
        const current: ?usize = if (s.window) |w| @intFromEnum(w) else null;
        if (try choices(f, "choices", &.{ "1280\u{00d7}720", "1600\u{00d7}900", "1920\u{00d7}1080", "FULLSCREEN" }, current)) |i| {
            const next: Settings.Window = @enumFromInt(i);
            changed.window = s.window != next;
            s.window = next;
        }
        if (opts.all_notes) try note(f, "note", "The terminal centres in the window; a wider one shows more of the rail.");
    }
    return changed;
}

test "difficulty notes cover every difficulty" {
    try std.testing.expectEqual(@typeInfo(Settings.Difficulty).@"enum".field_names.len, difficulty_notes.len);
}
