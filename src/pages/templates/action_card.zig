//! `action_card` template — one action, front and center, unpacked for learning: a
//! clickable button over three body-size info lines exposing the anatomy every action
//! shares — **cost** (the energy price), **yield** (what lands, on average), **odds**
//! (the p10–p90 band read as "N-M in 8 of 10", plus the distribution's name). The
//! no-tutorial teacher: the player's first action *is* the reference card. Mechanics
//! mirror `action_button` (gate on vigor, click funnels through `act_fn`); returns the
//! card `El` (or null if the agent doesn't hold the action) — the caller places it.

const std = @import("std");
const ha = @import("ha");

const comp = ha.comp;
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
fn info(ctx: *UiCtx, parent: El, id: []const u8, label: []const u8, value: []const u8) !void {
    const th = ctx.res.theme;
    const line = try el.div(ctx, parent, id);
    _ = line.with_flow(.{ .dir = .row }).with_gap(8);
    _ = (try el.text(ctx, line, "l", label)).with_style(.{ style.body, Style{ .text = th.dim } });
    _ = (try el.text(ctx, line, "v", value)).with_style(.{ style.body, Style{ .text = th.fg } });
}

pub fn action_card(
    ctx: *UiCtx,
    parent: El,
    world: *World,
    e: Entity,
    comptime ActionT: type,
    id: []const u8,
    name: []const u8,
    comptime act_fn: anytype,
) !?El {
    if (!world.has(e, ActionT)) return null;
    const act = world.get(e, ActionT).?;
    const vigor = world.get(e, comp.Vigor).?;
    // Same strict energy gate as `gather`: spending vigor to exactly 0 would be death.
    const can = vigor.v > act.requires.energy;

    const card = try el.div(ctx, parent, id);
    _ = card.with_flow(.{ .dir = .column, .cross = .center }).with_gap(10);

    const btn = try button(ctx, card, "btn", name, can);
    if (btn.query().clicked and can) act_fn(world, e, ctx.res);

    // Dominant yield (food or materials, by mean) — the shared pick (`action_info`),
    // scaled by the same two-level quality factor `gather` draws with.
    const dom = info_mod.dominant(act.yields);
    const quality = ha.actions.yield_factor(vigor);

    var buf: [48]u8 = undefined; // one line at a time — el.text copies at build
    const cost_txt = if (act.requires.materials > 0)
        std.fmt.bufPrint(&buf, "{d:.0} energy + {d:.0} materials", .{ act.requires.energy, act.requires.materials }) catch "?"
    else
        std.fmt.bufPrint(&buf, "{d:.0} energy", .{act.requires.energy}) catch "?";
    try info(ctx, card, "cost", "cost", cost_txt);

    try info(ctx, card, "yield", "yield", std.fmt.bufPrint(&buf, "{s}, {d:.0} on average", .{ dom.word, dom.band.mean * quality }) catch "?");

    // p10–p90 spelled out: 8 of 10 draws land inside the band. The spread IS the risk.
    try info(ctx, card, "odds", "odds", std.fmt.bufPrint(&buf, "{d:.0}-{d:.0} in 8 of 10 ({s})", .{ @round(dom.band.p10 * quality), @round(dom.band.p90 * quality), @tagName(dom.kind) }) catch "?");

    return card;
}
