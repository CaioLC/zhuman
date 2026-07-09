//! Shared, screen-agnostic HUD building blocks (`src/pages/` game content): the ASCII vitals
//! figure, the heartbeat pulse, the actor's condition word, and a labor-action button. The
//! per-screen builders (`play_game`, `gameover`) import these via `@import("./templates.zig")`.

const std = @import("std");
const ha = @import("ha");

const comp = ha.comp;
const ui = ha.ui;
const uic = ha.ui_client;
const World = ha.world.World;
const Entity = ha.world.Entity;

// --- vitals figure (flavor) -------------------------------------------------
pub const Figure = struct { l1: []const u8, l2: []const u8, l3: []const u8 };
pub const fig_robust = Figure{ .l1 = "  \\o/", .l2 = "   |", .l3 = "  / \\" };
pub const fig_ok = Figure{ .l1 = "   O", .l2 = "  /|\\", .l3 = "  / \\" };
pub const fig_weary = Figure{ .l1 = "   o", .l2 = "  /|", .l3 = "  /" };
pub const fig_dead = Figure{ .l1 = "   x", .l2 = "  -|-", .l3 = "  / \\" };

pub fn figure_glyphs(warmth: f32) Figure {
    if (warmth < 0.25) return fig_weary;
    if (warmth > 0.6) return fig_robust;
    return fig_ok;
}

/// Build the figure's 3 lines as stacked labels under `parent`, all in `color`.
pub fn ui_figure(ui_ctx: *uic.UiCtx, parent: *uic.Node, fig: Figure, color: ha.theme.Color) !void {
    const col = try uic.Node.pcreate(ui_ctx.arena, "fig", parent);
    _ = col.with_layout(ui.features.Layout.init(.relative, .vertical));
    const l1 = try uic.label(ui_ctx, col, "l1", fig.l1);
    l1.render_data.text = color;
    const l2 = try uic.label(ui_ctx, col, "l2", fig.l2);
    l2.render_data.text = color;
    const l3 = try uic.label(ui_ctx, col, "l3", fig.l3);
    l3.render_data.text = color;
}

/// A pulsing color between `t.dim` and `t.acc` (period ~1.1s) — the "heartbeat". Driven by
/// `elapsed` (the run clock), so it freezes the instant the actor dies.
pub fn heartbeat_color(t: ha.theme.Theme, elapsed: f32) ha.theme.Color {
    const phase = 0.5 + 0.5 * std.math.sin(elapsed * (2.0 * std.math.pi / 1.1));
    return ha.theme.mix(t.dim, t.acc, phase);
}

/// The actor's condition word + a severity color, from how rested it is (vigor fraction).
pub const Status = struct { word: []const u8, color: ha.theme.Color };
pub fn actor_status(t: ha.theme.Theme, vigor: *const comp.Vigor) Status {
    const frac = vigor.v / vigor.max;
    if (frac <= 0.12) return .{ .word = "SPENT", .color = t.danger };
    if (frac < 0.35) return .{ .word = "WEARY", .color = t.warn };
    return .{ .word = "ALIVE", .color = t.acc };
}

/// One labor-action button. Reads the agent's own copy of `ActionT` for its price/yield,
/// gates affordability on vigor, and funnels a click through `act_fn` (`actions.action_*`).
/// Skips silently if the agent doesn't hold this action component.
pub fn action_button(
    ui_ctx: *uic.UiCtx,
    parent: *uic.Node,
    world: *World,
    e: Entity,
    comptime ActionT: type,
    key: []const u8,
    name: []const u8,
    comptime act_fn: anytype,
) !void {
    if (!world.has(e, ActionT)) return;
    const act = world.get(e, ActionT).?;
    const vigor = world.get(e, comp.Vigor).?;
    // `gather` treats `requires.energy >= vigor.v` as "can't do it", so affordable is strict.
    const can = vigor.v > act.requires.energy;

    // Show the dominant yield's p10–p90 band (food for forage/fish, materials for chop).
    const food_band = ha.dist.stats(act.yields.food);
    const mat_band = ha.dist.stats(act.yields.materials);
    const food_dom = food_band.mean >= mat_band.mean;
    const band = if (food_dom) food_band else mat_band;
    const unit: u8 = if (food_dom) 'f' else 'm';

    var rbuf: [24]u8 = undefined;
    const lo = @round(band.p10);
    const hi = @round(band.p90);
    const range = if (lo == hi)
        std.fmt.bufPrint(&rbuf, "{d:.0}", .{lo}) catch "?"
    else
        std.fmt.bufPrint(&rbuf, "{d:.0}-{d:.0}", .{ lo, hi }) catch "?";

    var buf: [64]u8 = undefined;
    const txt = std.fmt.bufPrint(&buf, "{s}  (-{d:.0} e, +{s}{c})", .{ name, act.requires.energy, range, unit }) catch name;
    const btn = try uic.button(ui_ctx, parent, key, txt, can);
    if (btn.query(ui_ctx).clicked and can) act_fn(world, e, ui_ctx.res);
}

// --- vitals figure (flavor) -------------------------------------------------

const Figure = struct { l1: []const u8, l2: []const u8, l3: []const u8 };
const fig_robust = Figure{ .l1 = "  \\o/", .l2 = "   |", .l3 = "  / \\" };
const fig_ok = Figure{ .l1 = "   O", .l2 = "  /|\\", .l3 = "  / \\" };
const fig_weary = Figure{ .l1 = "   o", .l2 = "  /|", .l3 = "  /" };
const fig_dead = Figure{ .l1 = "   x", .l2 = "  -|-", .l3 = "  / \\" };

fn figure_glyphs(warmth: f32) Figure {
    if (warmth < 0.25) return fig_weary;
    if (warmth > 0.6) return fig_robust;
    return fig_ok;
}

/// Build the figure's 3 lines as stacked labels under `parent`, all in `color`.
fn ui_figure(ui_ctx: *uic.UiCtx, parent: *uic.Node, fig: Figure, color: ui.Color) !void {
    const col = try uic.Node.pcreate(ui_ctx.arena, "fig", parent);
    _ = col.with_layout(ui.features.Layout.init(.relative, .vertical));
    const l1 = try uic.label(ui_ctx, col, "l1", fig.l1);
    l1.render_data.text = color;
    const l2 = try uic.label(ui_ctx, col, "l2", fig.l2);
    l2.render_data.text = color;
    const l3 = try uic.label(ui_ctx, col, "l3", fig.l3);
    l3.render_data.text = color;
}

/// A pulsing color between `t.dim` and `t.acc` (period ~1.1s) — the "heartbeat". Driven by
/// `elapsed` (the run clock), so it freezes the instant the actor dies.
fn heartbeat_color(t: ha.theme.Theme, elapsed: f32) ui.Color {
    const phase = 0.5 + 0.5 * std.math.sin(elapsed * (2.0 * std.math.pi / 1.1));
    return ui.Color.lerp(t.dim, t.acc, phase);
}

/// The actor's condition word + a severity color, from how rested it is (vigor fraction).
const Status = struct { word: []const u8, color: ui.Color };
fn actor_status(t: ha.theme.Theme, vigor: *const comp.Vigor) Status {
    const frac = vigor.v / vigor.max;
    if (frac <= 0.12) return .{ .word = "SPENT", .color = t.danger };
    if (frac < 0.35) return .{ .word = "WEARY", .color = t.warn };
    return .{ .word = "ALIVE", .color = t.acc };
}

/// One labor-action button. Reads the agent's own copy of `ActionT` for its price/yield,
/// gates affordability on vigor, and funnels a click through `act_fn` (`actions.action_*`).
/// Skips silently if the agent doesn't hold this action component.
fn action_button(
    ui_ctx: *uic.UiCtx,
    parent: *uic.Node,
    world: *World,
    e: Entity,
    comptime ActionT: type,
    key: []const u8,
    name: []const u8,
    comptime act_fn: anytype,
) !void {
    if (!world.has(e, ActionT)) return;
    const act = world.get(e, ActionT).?;
    const vigor = world.get(e, comp.Vigor).?;
    // `gather` treats `requires.energy >= vigor.v` as "can't do it", so affordable is strict.
    const can = vigor.v > act.requires.energy;

    // Show the dominant yield's p10–p90 band (food for forage/fish, materials for chop).
    const food_band = ha.dist.stats(act.yields.food);
    const mat_band = ha.dist.stats(act.yields.materials);
    const food_dom = food_band.mean >= mat_band.mean;
    const band = if (food_dom) food_band else mat_band;
    const unit: u8 = if (food_dom) 'f' else 'm';

    var rbuf: [24]u8 = undefined;
    const lo = @round(band.p10);
    const hi = @round(band.p90);
    const range = if (lo == hi)
        std.fmt.bufPrint(&rbuf, "{d:.0}", .{lo}) catch "?"
    else
        std.fmt.bufPrint(&rbuf, "{d:.0}-{d:.0}", .{ lo, hi }) catch "?";

    var buf: [64]u8 = undefined;
    const txt = std.fmt.bufPrint(&buf, "{s}  (-{d:.0} e, +{s}{c})", .{ name, act.requires.energy, range, unit }) catch name;
    const btn = try uic.button(ui_ctx, parent, key, txt, can);
    if (btn.query(ui_ctx).clicked and can) act_fn(world, e, ui_ctx.res);
}

/// This frame's 0..1 "warmth" mood — drives the COLD↔WARM theme blend. Simplified to the
/// actor's vigor fraction for now (the satiety/capital inputs went away with their
/// mechanics); a rested actor reads warm, a spent one cold.
pub fn compute_warmth(vigor: *const comp.Vigor) f32 {
    return std.math.clamp(vigor.v / vigor.max, 0, 1);
}

/// Map a log entry's tone to the current theme's matching color role (host policy).
fn log_tone_color(t: ha.theme.Theme, tone: ha.log.Tone) ha.theme.Color {
    return switch (tone) {
        .dim => t.dim,
        .normal => t.fg,
        .good => t.acc,
        .warn => t.warn,
        .danger => t.danger,
    };
}

/// Compact number format for the HUD's big counters — `1.2M`, `12k`, `3.4k`, or a bare int.
fn fmt_num(buf: []u8, n: f32) []const u8 {
    const r = @round(n);
    if (r >= 1_000_000) return std.fmt.bufPrint(buf, "{d:.1}M", .{r / 1_000_000}) catch "?";
    if (r >= 10_000) return std.fmt.bufPrint(buf, "{d:.0}k", .{r / 1000}) catch "?";
    if (r >= 1_000) return std.fmt.bufPrint(buf, "{d:.1}k", .{r / 1000}) catch "?";
    return std.fmt.bufPrint(buf, "{d:.0}", .{r}) catch "?";
}
