//! The game's screen builders (`ui_*`) and `build_ui` live in this module.
//! This is how we display game *content* into UI components.

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

// Screens are mid-redesign (plan Phase 6): the mock showcase stands in for them. Restore
// these imports + the actor-dispatch block in `build_ui` when play_game/gameover land.
// const ui_playgame = @import("./play_game.zig").ui_playgame;
// const ui_gameover = @import("./gameover.zig").ui_gameover;
const mock_page = @import("./mock.zig").mock_page;

/// A fullscreen root: the anchor box a whole screen's content positions against. Sized to
/// the live window so `.center`/`.top_left`/… anchors resolve against the full display.
pub fn ui_root(ui_ctx: *uic.UiCtx, id: []const u8) !*uic.Node {
    const ww, const wh = try ui_ctx.res.window.getSize();
    const root = try uic.Node.create(ui_ctx.arena, id);
    _ = root.with_size(ui.features.Size.initFixed(@floatFromInt(ww), @floatFromInt(wh), null));
    return root;
}

pub fn build_ui(ui_ctx: *uic.UiCtx, world: *World) !uic.Trees {
    // Mock mode (plan Phase 5/6): the HUD screens are being rebuilt on the new style
    // system, so route to the showcase page under a fixed mid-warm palette. Restore the
    // actor-dispatch block below when play_game/gameover return.
    ui_ctx.res.theme = ha.theme.lerp(0.6);
    var trees: std.ArrayList(*uic.Node) = .empty;
    try uic.collect(&trees, ui_ctx.arena, try mock_page(ui_ctx, world));
    return trees.items;

    // -- Actor-dispatch HUD (parked while the screens are rebuilt) --
    // MaybeSingle: the actor is despawned on death, so it may be absent. `Entity` yields
    // the id (to call `actions.action_*`); the stocks co-spawn on the one player entity.
    // const q = ecs.MaybeSingle(.{ Entity, comp.Vigor, comp.InventoryFood, comp.InventoryMaterial, ecs.With(tag.Player) }){ .world = world };
    // const actor = q.get();
    // ui_ctx.res.theme = if (actor) |a| ha.theme.lerp(compute_warmth(a[1])) else ha.theme.cold;
    // var trees: std.ArrayList(*uic.Node) = .empty;
    // if (actor) |a| {
    //     const e, const vigor, const food, const materials = a;
    //     try uic.collect(&trees, ui_ctx.arena, try ui_playgame(ui_ctx, world, e, vigor, food, materials));
    // } else {
    //     try uic.collect(&trees, ui_ctx.arena, try ui_gameover(ui_ctx, world));
    // }
    // return trees.items;
}

// -- HELPER FUNCTIONS --

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
