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
    _ = (try parent.div(id)).with_size(.{ .pct_of_parent = 1.0 }, .{ .fixed = 1 })
        .with_style(.{Style{ .fill = color }});
}

/// A full-width band in the column, its 15px insets as flow lanes (a fixed or percentage size
/// is a content box here, so padding would push it past the column). Returns the inner row.
fn band(parent: El, id: []const u8, pad_y: f32) !El {
    const b = try parent.div(id);
    _ = b.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_flow(.{ .dir = .row, .cross = .center })
        .with_style(.{style.pad_sym(0, pad_y)});
    _ = try b.spacer("lead", pad_x, 1);
    const inner = try b.div("inner");
    _ = inner.with_size(.grow, .fit_children)
        .with_flow(.{ .dir = .row, .cross = .center }).with_gap(10);
    _ = try b.spacer("tail", pad_x, 1);
    return inner;
}

fn attractTop(parent: El, a: Attract) !void {
    const th = parent.ctx.res.view.theme;
    const top = try band(parent, "attract_top", 11);
    // `.start`, not `space_between`: the stocks grow into the rest, so the run context still
    // sits flush right, and a packed run keeps the 14px gap out of the stocks' share.
    _ = top.with_flow(.{ .dir = .row, .main = .start, .cross = .start }).with_gap(14);
    const left = try top.div("stocks");
    // `.attract-stock { flex-wrap: wrap }`: the stocks take what the run context leaves and
    // wrap rather than run under it. The grown width is final before heights are solved, so
    // the fit height counts every wrapped line.
    _ = left.with_size(.grow, .fit_children)
        .with_flow(.{ .dir = .row, .cross = .center, .wrap = true }).with_gap(13);
    for (a.stocks, 0..) |s, i| {
        _ = (try (try left.item("s", i)).text("t", s)).with_style(.{Style{ .font = 11, .text = th.line2 }});
    }
    const run = try top.text("run", a.run);
    _ = run.with_style(.{Style{ .font = 11, .tracking = 0.04, .text = th.line2 }});
    try hrule(parent, "top_rule", th.line);
}

fn attractStrip(parent: El, a: Attract) !void {
    const th = parent.ctx.res.view.theme;
    const strip = try band(parent, "attract_strip", 7);
    _ = strip.with_flow(.{ .dir = .row, .main = .start, .cross = .center });
    const lead = try strip.div("lead");
    _ = lead.with_size(.grow, .fit_children).with_flow(.{ .dir = .row, .cross = .center }).with_gap(10);
    const quiet = Style{ .font = 11, .text = th.line2 };
    _ = (try lead.text("dot", "\u{25cf}")).with_style(.{Style{ .font = 11, .text = inks.mid }});
    _ = (try lead.text("signal", a.strip_signal)).with_style(.{quiet});
    _ = (try lead.text("copy", a.strip_copy)).with_style(.{quiet});
    _ = (try strip.text("tail", "TRADE \u{2192}")).with_style(.{Style{ .font = 11, .tracking = 0.06, .text = th.line2 }});
    try hrule(parent, "strip_rule", th.line);
}

fn attractFoot(parent: El, a: Attract) !void {
    const th = parent.ctx.res.view.theme;
    try hrule(parent, "foot_rule", th.line);
    const foot_band = try band(parent, "attract_foot", 10);
    const foot = try foot_band.div("lines");
    _ = foot.with_flow(.{ .dir = .column, .cross = .start }).with_gap(2);
    const tones = [_]uic.Color{ th.dim, inks.mid, th.line2 };
    for (a.log, 0..) |l, i| {
        const row = try foot.item("l", i);
        _ = row.with_flow(.{ .dir = .row, .cross = .center }).with_gap(9);
        _ = (try row.text_fit("t", l.time, .{ .cell = .{ .mode = .clip, .width = 5 * 6.6 } }))
            .with_style(.{Style{ .font = 11, .text = inks.faint }});
        _ = (try row.text("m", l.text)).with_style(.{Style{ .font = 11, .text = tones[@min(i, tones.len - 1)] }});
    }
}

/// The work column and the holdings column, anchored at the screen's upper right.
fn attractSide(parent: El, a: Attract) !void {
    const th = parent.ctx.res.view.theme;
    const work = try parent.div("attract_work");
    _ = work.with_layout(.top_right).with_offset(-pad_x, 108)
        .with_size(.{ .fixed = side_w }, .fit_children)
        .with_flow(.{ .dir = .column }).with_gap(9);
    for (a.work, 0..) |w, i| {
        const row = try work.item("w", i);
        _ = row.with_size(.{ .pct_of_parent = 1.0 }, .fit_children).with_flow(.{ .dir = .column }).with_gap(3);
        const top = try row.div("top");
        _ = top.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
            .with_flow(.{ .dir = .row, .main = .space_between });
        _ = (try top.text("name", w.name)).with_style(.{Style{ .font = 10, .text = inks.head }});
        _ = (try top.text("pct", w.pct)).with_style(.{Style{ .font = 10, .text = inks.head }});
        const bar = try row.div("bar");
        _ = bar.with_size(.{ .pct_of_parent = 1.0 }, .{ .fixed = 2 })
            .with_flow(.{ .dir = .row })
            .with_style(.{Style{ .fill = inks.rule }});
        _ = (try bar.div("fill")).with_size(.{ .pct_of_parent = std.math.clamp(w.fraction, 0, 1) }, .{ .fixed = 2 })
            .with_style(.{Style{ .fill = inks.fill }});
    }

    const rail = try parent.div("attract_rail");
    _ = rail.with_layout(.top_right).with_offset(-pad_x, 236)
        .with_size(.{ .fixed = side_w }, .fit_children)
        .with_flow(.{ .dir = .column }).with_gap(3);
    const head = try rail.div("head");
    _ = head.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_flow(.{ .dir = .row, .main = .space_between })
        .with_style(.{style.pad_each(0, 0, 4, 0)});
    _ = (try head.text("title", "HOLDINGS")).with_style(.{Style{ .font = 10, .tracking = 0.07, .text = inks.head }});
    _ = (try head.text("count", a.rail_count)).with_style(.{Style{ .font = 10, .tracking = 0.07, .text = inks.head }});
    try hrule(rail, "head_rule", inks.rule);
    for (a.rail, 0..) |r, i| {
        const row = try rail.item("r", i);
        _ = row.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
            .with_flow(.{ .dir = .row, .main = .space_between }).with_gap(8);
        _ = (try row.text("label", r.label)).with_style(.{Style{ .font = 10, .text = th.line2 }});
        _ = (try row.text("value", r.value)).with_style(.{Style{ .font = 10, .text = inks.deep }});
    }
}

/// `.panel-head`: the screen's title and BACK. Returns BACK's click.
fn panelHead(parent: El, title: []const u8) !bool {
    const th = parent.ctx.res.view.theme;
    const head = try parent.div("panel_head");
    _ = head.with_size(.{ .fixed = panel_w }, .fit_children)
        .with_flow(.{ .dir = .row, .main = .space_between, .cross = .center }).with_gap(12);
    _ = (try head.text("title", title)).with_style(.{Style{ .font = 26, .tracking = -0.04, .text = th.fg }});
    const back = try button_mod.button_variant(head, "back", "BACK", true, .back);
    _ = try parent.spacer("head_gap", 1, 16);
    return back.consume(.clicked);
}

fn credits(parent: El) !void {
    const th = parent.ctx.res.view.theme;
    const wrap: f32 = 56 * 7.2;
    const copy = Style{ .font = 12, .text = th.dim };
    const col = try parent.div("credits");
    _ = col.with_flow(.{ .dir = .column, .cross = .start }).with_gap(11);
    _ = (try col.text_fit("p1", "A game about what people do when they cannot have everything.", .{ .wrap = wrap })).with_style(.{copy});
    const p2 = try col.div("p2");
    _ = p2.with_flow(.{ .dir = .column, .cross = .start }).with_gap(2);
    _ = (try p2.text_fit("a", "You begin alone, and every hour you spend is an hour you did not spend on something else. That is the whole difficulty. Later there are others, and you will find they are better than you at some things \u{2014}", .{ .wrap = wrap })).with_style(.{copy});
    _ = (try p2.text_fit("em", "and that this turns out to be good news.", .{ .wrap = wrap })).with_style(.{Style{ .font = 12, .text = th.fg }});
    _ = (try col.text_fit("p3", "Named after a long book by Ludwig von Mises. You don't have to read it.", .{ .wrap = wrap })).with_style(.{copy});

    _ = try col.spacer("meta_gap", 1, 1);
    const meta = try col.div("meta");
    _ = meta.with_size(.{ .fixed = wrap }, .fit_children).with_flow(.{ .dir = .column, .cross = .start }).with_gap(3);
    try hrule(meta, "rule", th.line);
    _ = try meta.spacer("pad", 1, 9);
    const rows = [_][2][]const u8{
        .{ "Design and code", "Caio Lacerda de Castro" },
        .{ "Built with", "Zig and SDL3, no engine" },
        .{ "Typeface", "JetBrains Mono" },
    };
    for (rows, 0..) |r, i| {
        const row = try meta.item("m", i);
        _ = row.with_flow(.{ .dir = .row, .cross = .center });
        _ = (try row.text("k", r[0])).with_style(.{Style{ .font = 10, .text = th.dim }});
        _ = (try row.text("v", try parent.ctx.arena.print(" \u{00b7} {s}", .{r[1]}))).with_style(.{Style{ .font = 10, .text = th.line2 }});
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

    const column = try sh.content.div("column");
    _ = column.with_size(.{ .pct_of_parent = 1.0 }, .{ .pct_of_parent = 1.0 })
        .with_flow(.{ .dir = .column, .cross = .start });
    try attractTop(column, a);
    try attractStrip(column, a);

    // The body band fills the height between the bands and centres the menu column in it
    // (`.title-body { align-content: center }`), 56px in from the left.
    const middle = try column.div("middle");
    _ = middle.with_size(.{ .pct_of_parent = 1.0 }, .grow)
        .with_flow(.{ .dir = .column, .main = .center, .cross = .start });
    const lane = try middle.div("lane");
    _ = lane.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_flow(.{ .dir = .row, .cross = .start });
    _ = try lane.spacer("lead", body_left, 1);
    const body = try lane.div(@tagName(screen.*));
    _ = body.with_size(.grow, .fit_children).with_flow(.{ .dir = .column, .cross = .start });
    switch (screen.*) {
        .menu => {
            _ = (try body.text("wordmark", "Human Action")).with_style(.{Style{ .font = 46, .tracking = -0.06, .text = th.fg }});
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
    _ = try lane.spacer("tail", pad_x, 1);

    try attractFoot(column, a);
    // The side columns are anchored out of flow, painted after the bands.
    try attractSide(sh.content, a);

    return .{ .root = sh.root.get(), .action = action, .changed = changed };
}
