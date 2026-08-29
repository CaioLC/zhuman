//! A **mock showcase page** standing in for the mid-redesign HUD. It exercises the whole
//! new stack end-to-end so the style system can be eyeballed in the running app: multi-size
//! fonts (h1/h2/h3/body), themed text colors, and every shelf template (`button`, `panel`,
//! `scroll_view`, `figure`, `action_button`, status/heartbeat). Built entirely on
//! `ui_client` — no direct engine (`ha.ui`) import.

const std = @import("std");
const ha = @import("ha");

const comp = ha.comp;
const tag = ha.tag;
const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const El = el.El;
const ecs = ha.ecs;
const actions = ha.actions;
const World = ha.world.World;
const Entity = ha.world.Entity;
const Node = uic.Node;
const UiCtx = uic.UiCtx;

const t = @import("./templates/root.zig");

/// A text leaf with a style — the showcase's workhorse (leaf flows by default, then style).
fn txt(ctx: *UiCtx, parent: El, id: []const u8, s: []const u8, spec: anytype) !El {
    return (try el.text(ctx, parent, id, s)).with_style(spec);
}

pub fn mock_page(ctx: *UiCtx, world: *World) !*Node {
    const th = ctx.res.view.theme;

    // Fullscreen root: a vertical, padded column over a bg fill.
    const root = try el.root(ctx, "mock");
    _ = root.with_layout(.top_left).with_flow(.{ .dir = .column }).with_gap(14)
        .with_style(.{ Style{ .fill = th.bg }, style.pad(20) });

    _ = try txt(ctx, root, "title", "Style System Showcase", .{ style.h1, Style{ .text = th.fg } });

    // Multi-size fonts: same word at each preset, so distinct point sizes are obvious.
    const sizes = try t.row(ctx, root, "sizes");
    _ = try txt(ctx, sizes, "s1", "H1", .{ style.h1, Style{ .text = th.fg } });
    _ = try txt(ctx, sizes, "s2", "H2", .{ style.h2, Style{ .text = th.fg } });
    _ = try txt(ctx, sizes, "s3", "H3", .{ style.h3, Style{ .text = th.acc } });
    _ = try txt(ctx, sizes, "sb", "body", .{ style.body, Style{ .text = th.dim } });

    // Themed color roles on body text.
    const colors = try t.row(ctx, root, "colors");
    _ = try txt(ctx, colors, "cfg", "fg", .{Style{ .text = th.fg }});
    _ = try txt(ctx, colors, "cacc", "acc", .{Style{ .text = th.acc }});
    _ = try txt(ctx, colors, "cwarn", "warn", .{Style{ .text = th.warn }});
    _ = try txt(ctx, colors, "cdanger", "danger", .{Style{ .text = th.danger }});

    // Buttons (enabled + disabled chrome).
    const bpanel = try t.panel(ctx, root, "bpanel", "Buttons");
    const brow = try t.row(ctx, bpanel, "brow");
    _ = try t.button(ctx, brow, "b_on", "Enabled", true);
    _ = try t.button(ctx, brow, "b_off", "Disabled", false);

    // Vitals figure + pulsing heartbeat readout.
    const vpanel = try t.panel(ctx, root, "vpanel", "Vitals");
    const vrow = try t.row(ctx, vpanel, "vrow");
    try t.figure(ctx, vrow, t.figure_glyphs(0.7), th.acc);
    _ = try txt(ctx, vrow, "heart", "<3 <3 <3", .{Style{ .text = t.heartbeat_color(th, ctx.res.sim.elapsed) }});

    // Actions — exercises `action_button` + `actor_status` against the live player.
    const q = ecs.MaybeSingle(.{ Entity, comp.Vigor, ecs.With(tag.Player) }){ .world = world };
    if (q.get()) |a| {
        const e, const vigor = a;
        const apanel = try t.panel(ctx, root, "apanel", "Actions");
        try t.action_button(ctx, apanel, world, e, comp.ActionForage, "forage", "Forage", actions.action_forage);
        try t.action_button(ctx, apanel, world, e, comp.ActionFish, "fish", "Fish", actions.action_fish);
        try t.action_button(ctx, apanel, world, e, comp.ActionChopWood, "chop", "Chop wood", actions.action_chop_wood);
        const s = t.actor_status(th, vigor, ctx.res.config);
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

    return root.get();
}
