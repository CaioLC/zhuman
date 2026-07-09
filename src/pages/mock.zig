//! A **mock showcase page** standing in for the mid-redesign HUD (`play_game`/`gameover`).
//! It exercises the whole new stack end-to-end so the style system can be eyeballed in the
//! running app: multi-size fonts (h1/h2/h3/body), themed text colors, and every shelf
//! template (`button`, `panel`, `scroll_view`, `figure`, `action_button`, status/heartbeat).
//! Routed by `build_ui` while the real screens are rebuilt (plan Phase 6).

const std = @import("std");
const ha = @import("ha");

const comp = ha.comp;
const tag = ha.tag;
const ui = ha.ui;
const uic = ha.ui_client;
const ecs = ha.ecs;
const actions = ha.actions;
const style = uic.style;
const elements = uic.elements;
const Style = style.Style;
const World = ha.world.World;
const Entity = ha.world.Entity;
const Node = uic.Node;
const UiCtx = uic.UiCtx;

const t = @import("./templates/root.zig");

/// A flowed text leaf with a style applied — the showcase's workhorse (content + style +
/// placement in the primary "B" idiom: leaf, then compose).
fn txt(ctx: *UiCtx, parent: *Node, id: []const u8, s: []const u8, style_spec: anytype) !*Node {
    const n = try elements.text(ctx, parent, id, s);
    style.apply_placement(n, .{style.flow});
    style.apply(ctx, n, style_spec);
    return n;
}

/// A flowed horizontal row container.
fn row(ctx: *UiCtx, parent: *Node, id: []const u8) !*Node {
    const n = try Node.pcreate(ctx.arena, id, parent);
    style.apply_placement(n, .{ style.flow, style.row, style.gap(16) });
    return n;
}

pub fn mock_page(ctx: *UiCtx, world: *World) !*Node {
    const th = ctx.res.theme;
    const ww, const wh = try ctx.res.window.getSize();

    // Fullscreen root: a vertical, padded column over a bg fill. A root stays non-relative
    // (`.top_left`), so no `flow` here.
    const root = try Node.create(ctx.arena, "mock");
    _ = root.with_size(ui.Size.initFixed(@floatFromInt(ww), @floatFromInt(wh), null));
    style.apply_placement(root, .{ style.col, style.gap(14) });
    style.apply(ctx, root, .{Style{ .fill = th.bg, .padding = ui.Padding.init(20) }});

    _ = try txt(ctx, root, "title", "Style System Showcase", .{ style.h1, Style{ .text = th.fg } });

    // Multi-size fonts: same word at each preset, so distinct point sizes are obvious.
    const sizes = try row(ctx, root, "sizes");
    _ = try txt(ctx, sizes, "s1", "H1", .{ style.h1, Style{ .text = th.fg } });
    _ = try txt(ctx, sizes, "s2", "H2", .{ style.h2, Style{ .text = th.fg } });
    _ = try txt(ctx, sizes, "s3", "H3", .{ style.h3, Style{ .text = th.acc } });
    _ = try txt(ctx, sizes, "sb", "body", .{ style.body, Style{ .text = th.dim } });

    // Themed color roles on body text.
    const colors = try row(ctx, root, "colors");
    _ = try txt(ctx, colors, "cfg", "fg", .{Style{ .text = th.fg }});
    _ = try txt(ctx, colors, "cacc", "acc", .{Style{ .text = th.acc }});
    _ = try txt(ctx, colors, "cwarn", "warn", .{Style{ .text = th.warn }});
    _ = try txt(ctx, colors, "cdanger", "danger", .{Style{ .text = th.danger }});

    // Buttons (enabled + disabled chrome).
    const bpanel = try t.panel(ctx, root, "bpanel", "Buttons");
    const brow = try row(ctx, bpanel, "brow");
    _ = try t.button(ctx, brow, "b_on", "Enabled", true);
    _ = try t.button(ctx, brow, "b_off", "Disabled", false);

    // Vitals figure + pulsing heartbeat readout.
    const vpanel = try t.panel(ctx, root, "vpanel", "Vitals");
    const vrow = try row(ctx, vpanel, "vrow");
    try t.figure(ctx, vrow, t.figure_glyphs(0.7), th.acc);
    _ = try txt(ctx, vrow, "heart", "<3 <3 <3", .{Style{ .text = t.heartbeat_color(th, ctx.res.time.elapsed) }});

    // Actions — exercises `action_button` + `actor_status` against the live player.
    const q = ecs.MaybeSingle(.{ Entity, comp.Vigor, ecs.With(tag.Player) }){ .world = world };
    if (q.get()) |a| {
        const e, const vigor = a;
        const apanel = try t.panel(ctx, root, "apanel", "Actions");
        try t.action_button(ctx, apanel, world, e, comp.ActionForage, "forage", "Forage", actions.action_forage);
        try t.action_button(ctx, apanel, world, e, comp.ActionFish, "fish", "Fish", actions.action_fish);
        try t.action_button(ctx, apanel, world, e, comp.ActionChopWood, "chop", "Chop wood", actions.action_chop_wood);
        const s = t.actor_status(th, vigor);
        _ = try txt(ctx, apanel, "status", s.word, .{Style{ .text = s.color }});
    }

    // Scroll view over more rows than fit — wheel to scroll.
    const spanel = try t.panel(ctx, root, "spanel", "Scroll");
    const sv = try t.scroll_view(ctx, spanel, "sv", 260, 120);
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const key = try std.fmt.allocPrint(ctx.arena, "row{d}", .{i});
        var b: [32]u8 = undefined;
        const line = std.fmt.bufPrint(&b, "log entry #{d}", .{i}) catch "row";
        _ = try txt(ctx, sv.content, key, line, .{Style{ .text = th.dim }});
    }

    return root;
}
