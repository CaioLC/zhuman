//! `action_card` template — one action, front and center, unpacked for learning: a
//! clickable button over three body-size info lines exposing the anatomy every action
//! shares — **cost** (the energy price and every input), **yield** (what lands, on
//! average), **odds** (the p10–p90 band read as "N-M in 8 of 10", plus the distribution's
//! name). The no-tutorial teacher: the player's first action *is* the reference card.
//! Mechanics mirror `action_button` (gate on the quote, report the click); returns the card
//! and its activation (or null if the agent doesn't hold the verb) — the caller places it
//! and calls the simulation.

const std = @import("std");
const ha = @import("ha");

const uic = ha.ui_client;
const World = ha.world.World;
const Entity = ha.world.Entity;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const UiCtx = uic.UiCtx;
const El = el.El;

const button = @import("./button.zig").button;
const info_mod = @import("./action_info.zig");

/// One dim-label / fg-value info line at body size.
fn info(parent: El, id: []const u8, label: []const u8, value: []const u8) !void {
    const ctx = parent.ctx;
    const th = ctx.res.view.theme;
    const line = try parent.div(id);
    _ = line.with_flow(.{ .dir = .row }).with_gap(8);
    _ = (try line.text("l", label)).with_style(.{ style.body, Style{ .text = th.dim } });
    _ = (try line.text("v", value)).with_style(.{ style.body, Style{ .text = th.fg } });
}

pub const Card = struct { el: El, clicked: bool };

pub fn action_card(
    parent: El,
    world: *World,
    e: Entity,
    ai: u16,
    id: []const u8,
) !?Card {
    const ctx = parent.ctx;
    const cat = &ctx.res.catalog;
    const q = ha.actions.quote(world, e, cat, ctx.res.config, ai) orelse return null;
    const name = cat.actions[ai].name;
    // Same gates as `begin`: strict energy, payable inputs, one act at a time.
    const can = q.ready();

    const card = try parent.div(id);
    _ = card.with_flow(.{ .dir = .column, .cross = .center }).with_gap(10);

    const btn = try button(card, "btn", name, can);
    const clicked = btn.query().clicked and can;

    var buf: [64]u8 = undefined; // one line at a time — el.text copies at build
    {
        var cw = std.Io.Writer.fixed(&buf);
        cw.print("{d:.0} energy", .{q.verb.requires.energy}) catch {};
        for (q.verb.input.slice()) |l| cw.print(" + {d:.0} {s}", .{ l.n, ha.actions.itemWord(cat, l.item) }) catch {};
        try info(card, "cost", "cost", cw.buffered());
    }

    // Time spelled out — the fourth price the compact tile will abbreviate to "4h".
    // Under the metabolism, working hours are eaten hours.
    try info(card, "time", "time", std.fmt.bufPrint(&buf, "{d:.0} hours", .{q.verb.requires.hours}) catch "?");

    // Dominant yield (by mean) — the shared pick (`action_info`), scaled by the same
    // two-level quality factor `begin` locks.
    if (info_mod.dominant(cat, q.verb.output.slice())) |dom| {
        try info(card, "yield", "yield", std.fmt.bufPrint(&buf, "{s}, {d:.0} on average", .{ dom.word, dom.band.mean * q.quality }) catch "?");
        // p10–p90 spelled out: 8 of 10 draws land inside the band. The spread IS the risk.
        try info(card, "odds", "odds", std.fmt.bufPrint(&buf, "{d:.0}-{d:.0} in 8 of 10 ({s})", .{ @round(dom.band.p10 * q.quality), @round(dom.band.p90 * q.quality), @tagName(dom.kind) }) catch "?");
    }

    return .{ .el = card, .clicked = clicked };
}
