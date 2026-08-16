//! `ration_dial` template — the eating-policy control: `eating  Ration Normal Feast`
//! chips writing straight to the agent's `comp.Metabolism.setting`. Unlike `tabs` (whose
//! selection is UI state in a pooled slot), this is **sim state on the agent** — eating
//! happens on the metabolism loop whether or not the player ever touches the dial; the
//! dial only sets the rate. Chip chrome mirrors `tabs`: active fg + outline, hover
//! accent, dim idle, with a dim lead-in label. Returns the row `El` (null if the agent
//! has no metabolism).

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

const Option = struct { s: comp.Metabolism.Setting, name: []const u8 };
const options = [_]Option{
    .{ .s = .ration, .name = "Ration" },
    .{ .s = .normal, .name = "Normal" },
    .{ .s = .feast, .name = "Feast" },
};

pub fn ration_dial(ctx: *UiCtx, parent: El, world: *World, e: Entity, id: []const u8) !?El {
    const met = world.get(e, comp.Metabolism) orelse return null;
    const th = ctx.res.theme;

    const bar = try el.div(ctx, parent, id);
    _ = bar.with_flow(.{ .dir = .row }).with_gap(8);
    _ = (try el.text(ctx, bar, "lbl", "eating"))
        .with_style(.{ style.body, Style{ .text = th.dim } });

    for (options, 0..) |opt, i| {
        const key = try std.fmt.allocPrint(ctx.arena, "opt{d}", .{i});
        const chip = try el.div(ctx, bar, key);
        if (chip.query().clicked) met.setting = opt.s;

        const is_active = met.setting == opt.s;
        const c = if (is_active) th.fg else if (chip.query().hovering) th.acc else th.dim;
        const lbl = (try el.text(ctx, chip, "l", opt.name))
            .with_style(.{ style.body, Style{ .text = c }, style.pad_sym(6, 2) });
        if (is_active) _ = chip.with_style(.{Style{ .outline_color = c }});
        chip.get().size.baseline = lbl.get().size.baseline_off(); // padded chip in a row
    }

    return bar;
}
