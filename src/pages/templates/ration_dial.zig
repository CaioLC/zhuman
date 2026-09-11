//! `ration_dial` template — the eating-policy control: `eating  Ration Normal Feast`
//! `ration_dial` template — the eating-policy control: `eating  Ration Normal Feast`
//! chips writing straight to the agent's `comp.Metabolism.rate` — the bounded scalar
//! (ACT1-02); the three chips are named points (0.5 / 1.0 / 2.0) inside the config's
//! `[0.5, 2.0]` band. Unlike `tabs` (whose selection is UI state in a pooled slot), this is
//! **sim state on the agent** — eating happens on the metabolism loop whether or not the
//! player ever touches the dial; the dial only sets the rate. Chip chrome mirrors `tabs`:
//! active fg + outline, hover accent, dim idle, with a dim lead-in label. Returns the row
//! `El` (null if the agent has no metabolism).

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

const Option = struct { rate: f32, name: []const u8 };
const options = [_]Option{
    .{ .rate = 0.5, .name = "Ration" },
    .{ .rate = 1.0, .name = "Normal" },
    .{ .rate = 2.0, .name = "Feast" },
};

pub fn ration_dial(ctx: *UiCtx, parent: El, world: *World, e: Entity, id: []const u8) !?El {
    const met = world.get(e, comp.Metabolism) orelse return null;
    const food = world.get(e, comp.InventoryFood);
    const th = ctx.res.view.theme;

    const bar = try el.div(ctx, parent, id);
    _ = bar.with_flow(.{ .dir = .row }).with_gap(8);
    const bar_key = bar.get().key;
    _ = (try el.text(ctx, bar, "lbl", "eating"))
        .with_style(.{ style.body, Style{ .text = th.dim } });

    var member_keys: [uic.semantic.max_relations]u64 = undefined;
    var member_len: usize = 0;

    for (options, 0..) |opt, i| {
        const key = try std.fmt.allocPrint(ctx.arena, "opt{d}", .{i});
        const chip = try el.div(ctx, bar, key);
        const chip_key = chip.get().key;
        const q = chip.query();
        ctx.registerRovingFocus(bar_key, chip_key, true);
        if (q.clicked) _ = ctx.requestFocus(chip_key);
        const focused = ctx.isFocused(chip_key);
        if (q.hovering) ctx.res.cursor.request(.pointer);
        if (q.clicked) met.rate = opt.rate;
        // Active iff the agent's scalar rate matches this chip's rate (ACT1-02). The three
        // chips are named points inside the bounded `[0.5, 2.0]` band the config owns.
        const is_active = @abs(met.rate - opt.rate) < 0.001;
        uic.publishControlState(ctx, chip_key, .{
            .focused = focused,
            .focus_visible = focused,
            .selected = is_active,
        });
        // INPUT-08: a ration choice is a single-selection member; the authoritative
        // `selected` fact is `met.rate == opt.rate` (sim state on the agent). Linked to
        // the eating group by key.
        ctx.res.semantics.publish(uic.semantic.describeRadio(chip_key, opt.name, is_active, focused, bar_key));
        if (member_len < member_keys.len) {
            member_keys[member_len] = chip_key;
            member_len += 1;
        }

        // The eating pulse: the active chip fills with progress through the *current
        // food unit* (`ceil(F) − F`) and resets as each unit is consumed — a repeating
        // full-chip pulse for a continuous process (vs the action underbar's one-shot
        // fill). Its speed IS the rate: Feast races, Ration crawls, an empty larder
        // stops pulsing entirely. Built before the label so the text paints on top;
        // sized from LAST frame's rect (prior-frame pattern); anchored, so the chip
        // never widens with it.
        if (is_active) {
            if (food) |f| {
                if (f.v > 0) {
                    if (chip.get().rect(ctx)) |r| {
                        const fill = std.math.ceil(f.v) - f.v;
                        const pulse = try el.div(ctx, chip, "pulse");
                        // `r` is the stamped (device-px) chip rect; the pulse fills a fraction
                        // of it, so both dims are device px — `with_size_px` (VIEW-02).
                        _ = pulse.with_layout(.top_left)
                            .with_size_px(.{ .fixed = r.w * fill }, .{ .fixed = r.h })
                            .with_style(.{Style{ .fill = th.line }});
                    }
                }
            }
        }

        const c = if (is_active) th.fg else if (q.held or q.hovering or focused) th.acc else th.dim;
        const lbl = (try el.text(ctx, chip, "l", opt.name))
            .with_style(.{ style.body, Style{ .text = c }, style.pad_sym(6, 2) });
        if (is_active) _ = chip.with_style(.{Style{ .outline_color = c }});
        chip.get().size.baseline = lbl.get().size.baseline_off(); // padded chip in a row
    }

    // The dial is a single-selection group ("eating") controlling its ration members.
    ctx.res.semantics.publish(uic.semantic.describeGroup(bar_key, "eating", member_keys[0..member_len]));

    return bar;
}
