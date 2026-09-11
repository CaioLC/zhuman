//! `holdings` template — what the actor owns, and what it is doing for them.
//!
//! Two blocks, and the second is the point. The **roster** lists every owned good with
//! its count, because a good is no longer one-per-agent: a second pair of sandals is
//! stock, made to trade, and nothing else on screen would say so. The **margins** block
//! underneath is the readout that has never existed — three modifiers land on Forage and
//! nothing tells you why it costs 1.7 energy instead of 2.
//!
//! Margins are *derived*, never restated: each live action component is compared against
//! its own catalog default (`(comp.ActionForage{}).requires.energy`), so the numbers here
//! cannot drift from the numbers `capital.zig` applies. That rules out three rows worth
//! having — the vigor ceiling, spoilage and food quality — whose baseline is a literal in
//! `main.spawn_agent` rather than a catalog default, so they are shown as current values
//! rather than deltas (see `docs/roadmap.md`, Act I).
//!
//! The effect text is presentation and shared with the BUILD list (`good_text.zig`), so
//! one sentence answers both "what would this get me?" and "what is it doing for me?"
//! rather than two lists of sixteen strings drifting apart.

const std = @import("std");
const ha = @import("ha");

const comp = ha.comp;
const capital = ha.capital;
const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const UiCtx = uic.UiCtx;
const El = el.El;
const World = ha.world.World;
const Entity = ha.world.Entity;

const gt = @import("./good_text.zig");

/// One `label … value` line, the shape both blocks share.
fn line(ctx: *UiCtx, parent: El, id: []const u8, left: []const u8, right: []const u8, right_color: uic.Color) !void {
    const th = ctx.res.view.theme;
    const row = try el.div(ctx, parent, id);
    _ = row.with_size(.{ .pct_of_parent = 1.0 }, .fit_children).with_flow(.{ .dir = .row });
    _ = (try el.text(ctx, row, "l", left)).with_style(.{ style.body, Style{ .text = th.fg } });
    const tail = try el.div(ctx, row, "r");
    _ = tail.with_layout(.center_right);
    _ = (try el.text(ctx, tail, "v", right)).with_style(.{ style.body, Style{ .text = right_color } });
}

/// The margin an owned modifier has already worked into a live action: its catalog
/// default against what the component now says. Null when nothing has touched it, so a
/// verb the actor has but has never improved stays off the list.
fn margin_line(ctx: *UiCtx, parent: El, w: *World, e: Entity, comptime ActionT: type, id: []const u8, name: []const u8) !void {
    const live = w.get(e, ActionT) orelse return; // the verb itself is locked
    const base = (ActionT{}).requires.energy;
    if (@abs(live.requires.energy - base) < 0.001) return;
    var buf: [40]u8 = undefined;
    const txt = std.fmt.bufPrint(&buf, "{d:.1}e -> {d:.1}e", .{ base, live.requires.energy }) catch return;
    try line(ctx, parent, id, name, txt, ctx.res.view.theme.acc);
}

/// The holdings panel. Returns the panel `El` (shelf convention) — the caller places it.
pub fn holdings(ctx: *UiCtx, parent: El, world: *World, e: Entity, id: []const u8) !El {
    const th = ctx.res.view.theme;
    var buf: [48]u8 = undefined;

    // Fills its parent's width (the KIT-05 rail body, a definite width), and the rows inside
    // right-align against it (`pct_of_parent`). Before KIT-05 this was a fixed 300 in the
    // cramped centre column; in the rail it takes the rail's width so the rows track it.
    const panel = try el.div(ctx, parent, id);
    _ = panel.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_flow(.{ .dir = .column }).with_gap(3)
        .with_style(.{ Style{ .outline_color = th.line }, style.solid, style.pad_sym(10, 9) });

    // --- header: kinds and units are different numbers, and the Shelter counts kinds ---
    var units: u32 = 0;
    inline for (capital.buildable_bundle) |G| {
        if (world.get(e, G)) |held| units += held.count;
    }
    const kinds = capital.goods_owned(world, e);
    const head = std.fmt.bufPrint(&buf, "HOLDINGS  {d} kinds, {d}", .{ kinds, units }) catch "HOLDINGS";
    _ = (try el.text(ctx, panel, "hh", head))
        .with_style(.{ style.body, Style{ .text = th.dim } });

    if (kinds == 0) {
        _ = (try el.text(ctx, panel, "none", "nothing built yet"))
            .with_style(.{ style.body, Style{ .text = th.line2 } });
        return panel;
    }

    // --- roster: one line per owned kind, count shown only when there are spares ------
    const roster = try el.div(ctx, panel, "roster");
    _ = roster.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_flow(.{ .dir = .column }).with_gap(1)
        .with_style(.{style.pad_each(0, 0, 6, 0)});
    inline for (capital.buildable_bundle, 0..) |G, i| {
        if (world.get(e, G)) |held| {
            var nbuf: [40]u8 = undefined;
            const label = if (held.count > 1)
                std.fmt.bufPrint(&nbuf, "{s} x{d}", .{ capital.good_name(G), held.count }) catch capital.good_name(G)
            else
                capital.good_name(G);
            const id_buf = std.fmt.comptimePrint("g{d}", .{i});
            try line(ctx, roster, id_buf, label, gt.effect(G), th.dim);
        }
    }

    // --- margins: what the roster has actually bought, derived from the components ----
    const margins = try el.div(ctx, panel, "margins");
    _ = margins.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_flow(.{ .dir = .column }).with_gap(1)
        .with_style(.{ Style{ .outline_color = th.line }, style.pad_each(0, 6, 6, 0) });

    try margin_line(ctx, margins, world, e, comp.ActionForage, "m_for", "Forage");
    try margin_line(ctx, margins, world, e, comp.ActionScavenge, "m_sca", "Scavenge");
    try margin_line(ctx, margins, world, e, comp.ActionChopWood, "m_chp", "Split wood");
    try margin_line(ctx, margins, world, e, comp.ActionFish, "m_fsh", "Fish");
    try margin_line(ctx, margins, world, e, comp.ActionCheckTraps, "m_trp", "Traps");
    try margin_line(ctx, margins, world, e, comp.ActionHunt, "m_hnt", "Hunt");

    // Generators are a flow, not a margin: what they add per day is their own `yields`.
    var per_day: f32 = 0;
    inline for (.{ comp.GardenBed, comp.ChickenCoop }) |G| {
        if (world.has(e, G)) per_day += (G{}).yields.food.s;
    }
    if (per_day > 0) {
        var fbuf: [24]u8 = undefined;
        const txt = std.fmt.bufPrint(&fbuf, "+{d:.1}/day", .{per_day}) catch "?";
        try line(ctx, margins, "m_gen", "Food", txt, th.acc);
    }

    // The vigor ceiling is shown, not diffed: its baseline is a spawn literal rather than
    // a catalog default, so a delta here would mean restating a number capital.zig owns.
    const vigor = world.get(e, comp.Vigor) orelse return panel;
    var vbuf: [24]u8 = undefined;
    const vtxt = std.fmt.bufPrint(&vbuf, "{d:.0}", .{vigor.max}) catch "?";
    try line(ctx, margins, "m_max", "Vigor ceiling", vtxt, th.dim);

    return panel;
}
