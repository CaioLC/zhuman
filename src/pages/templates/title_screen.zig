//! `title_screen` — the title screen's whole composition (`title.html`): the attract loop's
//! receded HUD (stockline, merchant strip, work in progress, holdings, event log) around the
//! body, which is the wordmark over the shared menu list, or the shared settings panel, or the
//! credits. Settings and credits replace the menu column; this is a screen, not a modal, so
//! Escape on them steps back to the menu.
//!
//! The page supplies the attract frame (`Attract`) and acts on the result: New game, Quit, and
//! a window setting to apply.

const std = @import("std");
const ha = @import("ha");
const uic = ha.ui_client;
const style = uic.style;
const Style = style.Style;
const El = uic.elements.El;

const terminal_mod = @import("./terminal.zig");
const menu_list_mod = @import("./menu_list.zig");
const settings_mod = @import("./settings_panel.zig");
const button_mod = @import("./button.zig");

pub const Work = struct { name: []const u8, fraction: f32, pct: []const u8 };
pub const RailRow = struct { label: []const u8, value: []const u8 };
pub const LogLine = struct { time: []const u8, text: []const u8 };

/// One frame of the attract loop, formatted.
pub const Attract = struct {
    stocks: []const []const u8,
    run: []const u8,
    strip_signal: []const u8,
    strip_copy: []const u8,
    work: []const Work,
    rail_count: []const u8,
    rail: []const RailRow,
    /// Newest first.
    log: []const LogLine,
};

pub const Action = enum { none, new_game, quit };

pub const Result = struct {
    root: *uic.Node,
    action: Action,
    changed: settings_mod.Changed,
};

const pad_x: f32 = 15;
/// `.title-body`'s left inset.
const body_left: f32 = 56;
const side_w: f32 = 190;
/// `.panel-body`'s cap.
const panel_w: f32 = 540;

/// The prototype's receded inks: the attract loop sits between the ground and `line2`.
const Inks = struct {
    faint: uic.Color, // #2b2a25
    rule: uic.Color, // #1c1b17
    deep: uic.Color, // #343229
    head: uic.Color, // #413f39
    mid: uic.Color, // #4a4841
    fill: uic.Color, // #3a382f
};
const inks = Inks{
    .faint = uic.rgb(0x2b, 0x2a, 0x25),
    .rule = uic.rgb(0x1c, 0x1b, 0x17),
    .deep = uic.rgb(0x34, 0x32, 0x29),
    .head = uic.rgb(0x41, 0x3f, 0x39),
    .mid = uic.rgb(0x4a, 0x48, 0x41),
    .fill = uic.rgb(0x3a, 0x38, 0x2f),
};

fn hrule(parent: El, id: []const u8, color: uic.Color) !void {
    try parent.leaf(id, .{ .w = .{ .pct_of_parent = 1.0 }, .h = .{ .fixed = 1 } }, .{Style{ .fill = color }});
}

/// A full-width band in the column with 15px side insets (its percentage width is a border
/// box, so the padding comes out of the column's width). Returns the inner row.
fn band(parent: El, id: []const u8, pad_y: f32) !El {
    const b = try parent.box(id, .{
        .w = .{ .pct_of_parent = 1.0 }, .h = .fit_children, .flow = .{ .dir = .row, .cross = .center },
    }, .{style.pad_sym(pad_x, pad_y)});
    const inner = try b.box("inner", .{ .w = .grow, .h = .fit_children, .flow = .{ .dir = .row, .cross = .center }, .gap = 10 }, .{});
    return inner;
}

fn attractTop(parent: El, a: Attract) !void {
    const th = parent.ctx.res.view.theme;
    const top = try band(parent, "attract_top", 11);
    // `.start`, not `space_between`: the stocks grow into the rest, so the run context still
    // sits flush right, and a packed run keeps the 14px gap out of the stocks' share.
    top.set(.{ .flow = .{ .dir = .row, .main = .start, .cross = .start }, .gap = 14 }, .{});
    const left = try top.div("stocks");
    // `.attract-stock { flex-wrap: wrap }`: the stocks take what the run context leaves and
    // wrap rather than run under it. The grown width is final before heights are solved, so
    // the fit height counts every wrapped line.
    left.set(.{ .w = .grow, .h = .fit_children, .flow = .{ .dir = .row, .cross = .center, .wrap = true }, .gap = 13 }, .{});
    for (a.stocks, 0..) |s, i| {
        try (try left.item("s", i)).label("t", s, .{Style{ .font = 11, .ink = .line2 }});
    }
    const run = try top.text("run", a.run);
    run.set(.{}, .{Style{ .font = 11, .tracking = 0.04, .ink = .line2 }});
    try hrule(parent, "top_rule", th.line);
}

fn attractStrip(parent: El, a: Attract) !void {
    const th = parent.ctx.res.view.theme;
    const strip = try band(parent, "attract_strip", 7);
    strip.set(.{ .flow = .{ .dir = .row, .main = .start, .cross = .center } }, .{});
    const lead = try strip.box("lead", .{ .w = .grow, .h = .fit_children, .flow = .{ .dir = .row, .cross = .center }, .gap = 10 }, .{});
    const quiet = Style{ .font = 11, .ink = .line2 };
    try lead.label("dot", "\u{25cf}", .{Style{ .font = 11, .text = inks.mid }});
    try lead.label("signal", a.strip_signal, .{quiet});
    try lead.label("copy", a.strip_copy, .{quiet});
    try strip.label("tail", "TRADE \u{2192}", .{Style{ .font = 11, .tracking = 0.06, .ink = .line2 }});
    try hrule(parent, "strip_rule", th.line);
}

fn attractFoot(parent: El, a: Attract) !void {
    const th = parent.ctx.res.view.theme;
    try hrule(parent, "foot_rule", th.line);
    const foot_band = try band(parent, "attract_foot", 10);
    const foot = try foot_band.box("lines", .{ .flow = .{ .dir = .column, .cross = .start }, .gap = 2 }, .{});
    const tones = [_]uic.Color{ th.dim, inks.mid, th.line2 };
    for (a.log, 0..) |l, i| {
        const row = try foot.boxi("l", i, .{ .flow = .{ .dir = .row, .cross = .center }, .gap = 9 }, .{});
        try row.label_fit("t", l.time, .{ .cell = .{ .mode = .clip, .width = 5 * 6.6 } }, .{Style{ .font = 11, .text = inks.faint }});
        try row.label("m", l.text, .{Style{ .font = 11, .text = tones[@min(i, tones.len - 1)] }});
    }
}

/// The work column and the holdings column, anchored at the screen's upper right.
fn attractSide(parent: El, a: Attract) !void {
    const work = try parent.box("attract_work", .{
        .anchor = .top_right, .offset = .{ .x = -pad_x, .y = 108 }, .w = .{ .fixed = side_w },
        .h = .fit_children, .flow = .{ .dir = .column }, .gap = 9,
    }, .{});
    for (a.work, 0..) |w, i| {
        const row = try work.boxi("w", i, .{
            .w = .{ .pct_of_parent = 1.0 }, .h = .fit_children, .flow = .{ .dir = .column }, .gap = 3,
        }, .{});
        const top = try row.box("top", .{
            .w = .{ .pct_of_parent = 1.0 }, .h = .fit_children,
            .flow = .{ .dir = .row, .main = .space_between },
        }, .{});
        try top.label("name", w.name, .{Style{ .font = 10, .text = inks.head }});
        try top.label("pct", w.pct, .{Style{ .font = 10, .text = inks.head }});
        const bar = try row.box("bar", .{
            .w = .{ .pct_of_parent = 1.0 }, .h = .{ .fixed = 2 }, .flow = .{ .dir = .row },
        }, .{Style{ .fill = inks.rule }});
        try bar.leaf("fill", .{
            .w = .{ .pct_of_parent = std.math.clamp(w.fraction, 0, 1) }, .h = .{ .fixed = 2 },
        }, .{Style{ .fill = inks.fill }});
    }

    const rail = try parent.box("attract_rail", .{
        .anchor = .top_right, .offset = .{ .x = -pad_x, .y = 236 }, .w = .{ .fixed = side_w },
        .h = .fit_children, .flow = .{ .dir = .column }, .gap = 3,
    }, .{});
    const head = try rail.box("head", .{
        .w = .{ .pct_of_parent = 1.0 }, .h = .fit_children, .flow = .{ .dir = .row, .main = .space_between },
    }, .{style.pad_each(0, 0, 4, 0)});
    try head.label("title", "HOLDINGS", .{Style{ .font = 10, .tracking = 0.07, .text = inks.head }});
    try head.label("count", a.rail_count, .{Style{ .font = 10, .tracking = 0.07, .text = inks.head }});
    try hrule(rail, "head_rule", inks.rule);
    for (a.rail, 0..) |r, i| {
        const row = try rail.boxi("r", i, .{
            .w = .{ .pct_of_parent = 1.0 }, .h = .fit_children,
            .flow = .{ .dir = .row, .main = .space_between }, .gap = 8,
        }, .{});
        try row.label("label", r.label, .{style.caption_faint});
        try row.label("value", r.value, .{Style{ .font = 10, .text = inks.deep }});
    }
}

/// `.panel-head`: the screen's title and BACK. Returns BACK's click.
fn panelHead(parent: El, title: []const u8) !bool {
    const head = try parent.box("panel_head", .{
        .w = .{ .fixed = panel_w }, .h = .fit_children,
        .flow = .{ .dir = .row, .main = .space_between, .cross = .center }, .gap = 12,
        .margin = .{ .after = 16 },
    }, .{});
    try head.label("title", title, .{Style{ .font = 26, .tracking = -0.04, .ink = .fg }});
    const back = try button_mod.button_variant(head, "back", "BACK", true, .back);
    return back.consume(.clicked);
}

fn credits(parent: El) !void {
    const th = parent.ctx.res.view.theme;
    const wrap: f32 = 56 * 7.2;
    const copy = Style{ .font = 12, .ink = .dim };
    const col = try parent.box("credits", .{ .flow = .{ .dir = .column, .cross = .start }, .gap = 11 }, .{});
    try col.label_fit("p1", "A game about what people do when they cannot have everything.", .{ .wrap = wrap }, .{copy});
    const p2 = try col.box("p2", .{ .flow = .{ .dir = .column, .cross = .start }, .gap = 2 }, .{});
    try p2.label_fit("a", "You begin alone, and every hour you spend is an hour you did not spend on something else. That is the whole difficulty. Later there are others, and you will find they are better than you at some things \u{2014}", .{ .wrap = wrap }, .{copy});
    try p2.label_fit("em", "and that this turns out to be good news.", .{ .wrap = wrap }, .{Style{ .font = 12, .ink = .fg }});
    try col.label_fit("p3", "Named after a long book by Ludwig von Mises. You don't have to read it.", .{ .wrap = wrap }, .{copy});

    // 1px over the column's 11px gap above the meta block, and 9px over the meta column's
    // 3px gap between its rule and the first row.
    const meta = try col.box("meta", .{
        .w = .{ .fixed = wrap }, .h = .fit_children, .flow = .{ .dir = .column, .cross = .start }, .gap = 3,
        .margin = .{ .before = 1 + 11 },
    }, .{});
    try hrule(meta, "rule", th.line);
    const rows = [_][2][]const u8{
        .{ "Design and code", "Caio Lacerda de Castro" },
        .{ "Built with", "Zig and SDL3, no engine" },
        .{ "Typeface", "JetBrains Mono" },
    };
    for (rows, 0..) |r, i| {
        const row = try meta.boxi("m", i, .{
            .flow = .{ .dir = .row, .cross = .center },
            .margin = .{ .before = if (i == 0) @as(f32, 9 + 3) else 0 },
        }, .{});
        try row.label("k", r[0], .{style.caption});
        try row.label("v", try parent.ctx.arena.print(" \u{00b7} {s}", .{r[1]}), .{style.caption_faint});
    }
}

pub fn title_screen(ctx: *uic.UiCtx, id: []const u8, a: Attract) !Result {
    const th = ctx.res.view.theme;
    // `.title-screen`: `min(700px, 100vh)` high on a `line` hairline, and it never scrolls.
    const sh = try terminal_mod.terminal_with(ctx, id, .{ .max_h = 700, .scroll = false, .outline = th.line });
    const screen = &ctx.res.title.screen;
    var action: Action = .none;
    var changed: settings_mod.Changed = .{};

    // The title is the screen's own Escape owner: Escape on settings or credits steps back.
    ctx.res.commands.registerEscape(sh.root.get().key);
    if (sh.root.query().dismissed and screen.* != .menu) screen.* = .menu;

    const column = try sh.content.box("column", .{
        .w = .{ .pct_of_parent = 1.0 }, .h = .{ .pct_of_parent = 1.0 },
        .flow = .{ .dir = .column, .cross = .start },
    }, .{});
    try attractTop(column, a);
    try attractStrip(column, a);

    // The body band fills the height between the bands and centres the menu column in it
    // (`.title-body { align-content: center }`), 56px in from the left.
    const middle = try column.box("middle", .{
        .w = .{ .pct_of_parent = 1.0 }, .h = .grow,
        .flow = .{ .dir = .column, .main = .center, .cross = .start },
    }, .{});
    const lane = try middle.box("lane", .{
        .w = .{ .pct_of_parent = 1.0 }, .h = .fit_children, .flow = .{ .dir = .row, .cross = .start },
    }, .{style.pad_each(0, pad_x, 0, body_left)});
    const body = try lane.box(@tagName(screen.*), .{ .w = .grow, .h = .fit_children, .flow = .{ .dir = .column, .cross = .start } }, .{});
    switch (screen.*) {
        .menu => {
            try body.label("wordmark", "Human Action", .{Style{ .font = 46, .tracking = -0.06, .ink = .fg }});
            const list = try menu_list_mod.menu_list(body, "menu", &.{
                .{ .id = "continue", .label = "Continue", .enabled = false, .why = "no settlement in progress" },
                .{ .id = "new", .label = "New game" },
                .{ .id = "settings", .label = "Settings" },
                .{ .id = "credits", .label = "Credits" },
                .{ .id = "quit", .label = "Quit" },
            }, .{});
            if (list.clicked) |i| switch (i) {
                1 => action = .new_game,
                2 => screen.* = .settings,
                3 => screen.* = .credits,
                4 => action = .quit,
                else => {},
            };
        },
        .settings => {
            if (try panelHead(body, "Settings")) {
                screen.* = .menu;
            } else {
                changed = try settings_mod.settings_panel(body, "settings", &ctx.res.settings, .{ .width = panel_w, .all_notes = true });
            }
        },
        .credits => {
            if (try panelHead(body, "Credits")) screen.* = .menu else try credits(body);
        },
    }

    try attractFoot(column, a);
    // The side columns are anchored out of flow, painted after the bands.
    try attractSide(sh.content, a);

    return .{ .root = sh.root.get(), .action = action, .changed = changed };
}
