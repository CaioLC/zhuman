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
    const row = try parent.box(id, .{
        .w = .{ .fixed = width }, .h = .fit_children, .flow = .{ .dir = .row, .cross = .start },
        .gap = row_gap,
    }, .{});
    try row.label_fit("label", label, .{ .cell = .{ .mode = .clip, .width = label_w } }, .{ style.eyebrow_dim, style.pad_each(4, 0, 0, 0) });
    const field = try row.box("field", .{ .w = .grow, .h = .fit_children, .flow = .{ .dir = .column, .cross = .start }, .gap = 4 }, .{});
    return field;
}

/// A `.choices` button's chrome: a line edge and dim label at rest, line2/fg on hover or
/// visible focus, and accent edge and label while it is the selected choice.
pub const choice_outline = Style{ .outline_ink = .line, .on = &.{ .{ .when = .hover_focus, .outline_ink = .line2 }, .{ .when = .selected, .outline_ink = .acc } } };
pub const choice_label = Style{ .ink = .dim, .on = &.{ .{ .when = .hover_focus, .ink = .fg }, .{ .when = .selected, .ink = .acc } } };

/// A `.choices` group: one button per label, the `selected` one pressed. Returns the button
/// clicked this frame.
pub fn choices(parent: El, id: []const u8, labels: []const []const u8, selected: ?usize) !?usize {
    const group = try parent.box(id, .{
        .w = .fit_children, .h = .fit_children, .flow = .{ .dir = .row, .cross = .center }, .gap = 5,
    }, .{});
    var clicked: ?usize = null;
    for (labels, 0..) |label, i| {
        const b = try group.boxi("c", i, .{ .w = .fit_children, .h = .fit_children, .flow = .{ .dir = .row } }, .{});
        const on = selected == i;
        const q = b.control(.{ .name = label, .role = .radio, .checked = on, .selected = on, .ring = false });
        if (q.clicked) clicked = i;
        try b.label("lbl", label, .{ Style{ .font = 11 }, choice_label, style.pad_sym(9, 3) });
        b.set(.{}, .{choice_outline});
    }
    return clicked;
}

/// A `.setting-note`: line2 prose, with an optional run of dim `.b` segments after it.
fn note(parent: El, id: []const u8, text: []const u8) !void {
    try parent.label(id, text, .{style.caption_faint});
}

/// DIFFICULTY's note: its sentence, then the two multipliers it names, in dim.
fn difficultyNote(parent: El, d: Settings.Difficulty) !void {
    const ctx = parent.ctx;
    try note(parent, "note", difficulty_notes[@intFromEnum(d)]);
    const terms = try parent.box("terms", .{ .flow = .{ .dir = .row, .cross = .center } }, .{});
    const quiet = style.caption_faint;
    const loud = style.caption;
    try terms.label("a", "Inputs cost ", .{quiet});
    try terms.label("cost", try ctx.arena.print("\u{00d7}{d:.2}", .{d.cost()}), .{loud});
    try terms.label("b", ", yields return ", .{quiet});
    try terms.label("yield", try ctx.arena.print("\u{00d7}{d:.2}", .{d.yield()}), .{loud});
    try terms.label("c", ".", .{quiet});
}

/// A `.level`: the slider filling the lane, then its value as a percentage.
fn level(parent: El, id: []const u8, label: []const u8, value: *f32) !void {
    const ctx = parent.ctx;
    const row = try parent.box(id, .{
        .w = .{ .pct_of_parent = 1.0 }, .h = .fit_children, .flow = .{ .dir = .row, .cross = .center },
        .gap = 10,
    }, .{});
    const lane = try row.box("lane", .{ .w = .grow, .h = .fit_children }, .{});
    const s = try slider_mod.slider(lane, .{ .id = "range", .label = label, .value = value.*, .min = 0, .max = 100, .step = 1 });
    value.* = s.value;
    try row.label_fit("out", try ctx.arena.print("{d:.0}%", .{s.value}), .{ .cell = .{ .mode = .clip, .width = level_out_w } }, .{Style{ .font = 11, .ink = .fg }});
}

pub fn settings_panel(parent: El, id: []const u8, s: *Settings, opts: Options) !Changed {
    var changed: Changed = .{};
    const panel = try parent.box(id, .{
        .w = .{ .fixed = opts.width }, .h = .fit_children, .flow = .{ .dir = .column, .cross = .start },
        .gap = panel_gap,
    }, .{});

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
