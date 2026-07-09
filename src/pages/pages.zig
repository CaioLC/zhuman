//! The game's screen builders (`ui_*`) and `build_ui`, the per-frame dispatcher that picks
//! among them. This is game *content*, not reusable host UI plumbing — so it lives in
//! `src/pages/`, its own folder inside `main.zig`'s module, reached by a plain relative
//! import. It is deliberately *not* under `ui_client/` and *not* on the `ha` library
//! barrel: it imports `ha` for the engine/host types, and imports `main.zig` back (`app`)
//! for the spawn/config it shares with the event loop.
//!
//! Rebuilt lean for the post-redesign model (Vigor + InventoryFood + InventoryMaterial +
//! per-agent action components): action buttons drive `actions.action_*`, an Eat button
//! drives `actions.action_eat`, and the vitals show only what the model still backs. The
//! pre-redesign HUD extras — the M4 catalog browser, the capital-goods tray/tooltips, and
//! every satiety/population/durability/trickle readout — were dropped along with the
//! mechanics behind them, to be redesigned on the new model in a later pass.

const std = @import("std");
const ha = @import("ha");
const app = @import("../main.zig");

const comp = ha.comp;
const tag = ha.tag;
const ui = ha.ui;
const uic = ha.ui_client;
const ecs = ha.ecs;
const actions = ha.actions;
const World = ha.world.World;
const Entity = ha.world.Entity;

/// A fullscreen root: the anchor box a whole screen's content positions against. Sized to
/// the live window so `.center`/`.top_left`/… anchors resolve against the full display.
fn ui_root(ui_ctx: *uic.UiCtx, id: []const u8) !*uic.Node {
    const ww, const wh = try ui_ctx.res.window.getSize();
    const root = try uic.Node.create(ui_ctx.arena, id);
    _ = root.with_layout(ui.features.Layout.init(.top_left, .horizontal))
        .with_size(ui.features.Size.initFixed(@floatFromInt(ww), @floatFromInt(wh), null));
    return root;
}

/// This frame's 0..1 "warmth" mood — drives the COLD↔WARM theme blend. Simplified to the
/// actor's vigor fraction for now (the satiety/capital inputs went away with their
/// mechanics); a rested actor reads warm, a spent one cold.
fn compute_warmth(vigor: *const comp.Vigor) f32 {
    return std.math.clamp(vigor.v / vigor.max, 0, 1);
}

/// Map a log entry's tone to the current theme's matching color role (host policy).
fn log_tone_color(t: ha.theme.Theme, tone: ha.log.Tone) ui.Color {
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

/// The live HUD while the actor is alive: a top-left status column (day + resources + log)
/// and a centered Actions panel. Reads/mutates the actor's components inline on click.
fn ui_playgame(
    ui_ctx: *uic.UiCtx,
    world: *World,
    e: Entity,
    vigor: *comp.Vigor,
    food: *comp.InventoryFood,
    materials: *comp.InventoryMaterial,
) !*uic.Node {
    var char_buf: [64]u8 = undefined;
    const play = try ui_root(ui_ctx, "play");
    const warmth = compute_warmth(vigor);

    // Status column (top-left): day + resources panel + log.
    const status_div = try uic.Node.pcreate(ui_ctx.arena, "status_div", play);
    _ = status_div.with_layout(ui.features.Layout.init(.top_left, .vertical).with_gap(10));

    const day = 1 + @as(u64, @intFromFloat(ui_ctx.res.time.elapsed / app.secs_per_day));
    _ = try uic.label(ui_ctx, status_div, "day_text", std.fmt.bufPrint(&char_buf, "Day {d}", .{day}) catch "?");

    const res_panel = try uic.panel(ui_ctx, status_div, "res_panel", "Resources");

    // Vitals: a small ASCII figure (mood from warmth) beside a pulsing "heartbeat". Flavor.
    const vitals = try uic.Node.pcreate(ui_ctx.arena, "vitals", res_panel);
    _ = vitals.with_layout(ui.features.Layout.init(.relative, .horizontal).with_gap(10));
    const fig_color = if (warmth < 0.25) ui_ctx.res.theme.warn else ui_ctx.res.theme.acc;
    try ui_figure(ui_ctx, vitals, figure_glyphs(warmth), fig_color);
    const heart = try uic.label(ui_ctx, vitals, "heartbeat", "<3 <3 <3");
    heart.render_data.text = heartbeat_color(ui_ctx.res.theme, ui_ctx.res.time.elapsed);

    _ = try uic.label(ui_ctx, res_panel, "vigor_text", std.fmt.bufPrint(&char_buf, "Vigor: {d:.0}/{d:.0}", .{ vigor.v, vigor.max }) catch "?");
    _ = try uic.label(ui_ctx, res_panel, "food_text", std.fmt.bufPrint(&char_buf, "Food: {d:.0}  (q{d}, spoils {d:.2}/s)", .{ food.v, food.quality, food.spoils }) catch "?");
    var mat_buf: [16]u8 = undefined;
    _ = try uic.label(ui_ctx, res_panel, "materials_text", std.fmt.bufPrint(&char_buf, "Materials: {s}", .{fmt_num(&mat_buf, materials.v)}) catch "?");

    // Event log — newest-first, scrollable, each line recolored by its tone.
    const log_panel = try uic.panel(ui_ctx, status_div, "log_panel", "Log");
    const feed = &ui_ctx.res.log;
    const log_view = try uic.scroll_view(ui_ctx, log_panel, "log_view", 260, 160);
    var li: usize = 0;
    while (li < feed.count) : (li += 1) {
        const entry = feed.get(li);
        const lkey = try std.fmt.allocPrint(ui_ctx.arena, "log{d}", .{li});
        const lnode = try uic.label(ui_ctx, log_view.content, lkey, entry.text());
        lnode.render_data.text = log_tone_color(ui_ctx.res.theme, entry.tone);
    }

    // Actor condition word, pinned top-right (colored by severity).
    const status = actor_status(ui_ctx.res.theme, vigor);
    const status_node = try uic.label(ui_ctx, play, "status_text", status.word);
    status_node.render_data.text = status.color;
    _ = status_node.with_layout(ui.features.Layout.init(.top_right, null));

    // Actions (center): the labor actions the agent holds + an Eat action.
    const center_div = try uic.Node.pcreate(ui_ctx.arena, "c_div", play);
    _ = center_div.with_layout(ui.features.Layout.init(.center, .vertical).with_gap(10));
    const act_panel = try uic.panel(ui_ctx, center_div, "act_panel", "Actions");
    try action_button(ui_ctx, act_panel, world, e, comp.ActionForage, "forage", "Forage", actions.action_forage);
    try action_button(ui_ctx, act_panel, world, e, comp.ActionFish, "fish", "Fish", actions.action_fish);
    try action_button(ui_ctx, act_panel, world, e, comp.ActionChopWood, "chop", "Chop wood", actions.action_chop_wood);

    // Eat — separate: `action_eat` takes no `res` and converts one food unit into vigor,
    // scaled by the food's quality.
    const can_eat = food.v >= 1.0;
    var ebuf: [48]u8 = undefined;
    const eat_txt = std.fmt.bufPrint(&ebuf, "Eat  (-1 food, +{d} vig)", .{2 * @as(u32, food.quality)}) catch "Eat";
    const eat_btn = try uic.button(ui_ctx, act_panel, "eat", eat_txt, can_eat);
    if (eat_btn.query(ui_ctx).clicked and can_eat) actions.action_eat(world, e);

    return play;
}

/// The game-over screen: a dead figure, a line, and a "Start over" button that respawns
/// the player and resets the run clock + log.
fn ui_gameover(ui_ctx: *uic.UiCtx, world: *World) !*uic.Node {
    const over = try ui_root(ui_ctx, "over");
    const center_div = try uic.Node.pcreate(ui_ctx.arena, "c_div", over);
    _ = center_div.with_layout(ui.features.Layout.init(.center, .vertical).with_gap(10));
    try ui_figure(ui_ctx, center_div, fig_dead, ui_ctx.res.theme.danger);
    _ = try uic.label(ui_ctx, center_div, "dead_text", "You perished, cold and starved.");
    const restart = try uic.button(ui_ctx, center_div, "restart", "Start over", true);
    if (restart.query(ui_ctx).clicked) {
        _ = app.spawn_player(world);
        ui_ctx.res.time.elapsed = 0; // fresh run starts on Day 1
        ui_ctx.res.log.clear();
        ui_ctx.res.log.push(.dim, "You wake alone. Cold. Hungry.");
    }
    return over;
}

pub fn build_ui(ui_ctx: *uic.UiCtx, world: *World) !uic.Trees {
    // MaybeSingle: the actor is despawned on death, so it may be absent. `Entity` yields
    // the id (to call `actions.action_*`); the stocks co-spawn on the one player entity.
    const q = ecs.MaybeSingle(.{ Entity, comp.Vigor, comp.InventoryFood, comp.InventoryMaterial, ecs.With(tag.Player) }){ .world = world };
    const actor = q.get();

    // Resolve this frame's COLD↔WARM theme before building anything. Death reads cold —
    // there's no live actor to compute a warmth from, and game-over is meant to feel that way.
    ui_ctx.res.theme = if (actor) |a| ha.theme.lerp(compute_warmth(a[1])) else ha.theme.cold;

    var trees: std.ArrayList(*uic.Node) = .empty;
    if (actor) |a| {
        const e, const vigor, const food, const materials = a;
        try uic.collect(&trees, ui_ctx.arena, try ui_playgame(ui_ctx, world, e, vigor, food, materials));
    } else {
        try uic.collect(&trees, ui_ctx.arena, try ui_gameover(ui_ctx, world));
    }

    return .{ .trees = trees.items };
}
