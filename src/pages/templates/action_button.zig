//! `action_button` template — one labor-action button over the agent's quote for a verb of
//! the roster. Gates affordability on the quote, shows the dominant yield's p10–p90 band,
//! and reports the gated click; the caller calls the simulation. Returns false silently if
//! the agent doesn't hold the verb. Composes the `button` template.

const std = @import("std");
const ha = @import("ha");

const uic = ha.ui_client;
const World = ha.world.World;
const Entity = ha.world.Entity;
const UiCtx = uic.UiCtx;
const El = uic.elements.El;

const button = @import("./button.zig").button;
const info = @import("./action_info.zig");

pub fn action_button(
    parent: El,
    world: *World,
    e: Entity,
    ai: u16,
    id: []const u8,
) !bool {
    const ctx = parent.ctx;
    const cat = &ctx.res.catalog;
    const q = ha.actions.quote(world, e, cat, ctx.res.config, ai) orelse return false;
    const name = cat.actions[ai].name;
    // Affordable is what `begin` would accept: strict energy, payable inputs, a free body.
    const can = q.ready();

    // Show the dominant yield's p10–p90 band — the shared pick (`action_info`), scaled by
    // the same two-level quality factor `begin` locks.
    var rbuf: [24]u8 = undefined;
    var range: []const u8 = "0";
    var letter: []const u8 = "";
    if (info.dominant(cat, q.verb.output.slice())) |dom| {
        const lo = @round(dom.band.p10 * q.quality);
        const hi = @round(dom.band.p90 * q.quality);
        range = if (lo == hi)
            std.fmt.bufPrint(&rbuf, "{d:.0}", .{lo}) catch "?"
        else
            std.fmt.bufPrint(&rbuf, "{d:.0}-{d:.0}", .{ lo, hi }) catch "?";
        letter = dom.letter;
    }

    var buf: [64]u8 = undefined;
    const txt = std.fmt.bufPrint(&buf, "{s}  (-{d:.0} e, +{s}{s})", .{ name, q.verb.requires.energy, range, letter }) catch name;
    const btn = try button(parent, id, txt, can);
    return btn.query().clicked and can;
}
