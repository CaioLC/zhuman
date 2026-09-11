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

/// An absolutely-placed, fixed-size filled rect inside `parent` (RENDER-01 blending fixture).
/// Anchored top-left and offset in px so layers overlap and their alpha composites — the
/// point being that a translucent `fill` (a < 255) must blend against what is under it, not
/// paint opaque. `col` carries its own alpha byte.
fn layer(ctx: *UiCtx, parent: El, id: []const u8, dx: f32, dy: f32, w: f32, h: f32, col: uic.Color) !El {
    const box = try el.div(ctx, parent, id);
    _ = box.with_layout(.top_left)
        .with_offset(dx, dy)
        .with_size(.{ .fixed = w }, .{ .fixed = h })
        .with_style(.{Style{ .fill = col }});
    return box;
}

/// A translucent color: `base` with an explicit alpha byte (0..255). The RENDER-01 fixture
/// leans on this — every layer's alpha is authored so the composite is predictable on screen.
fn alpha(base: uic.Color, a: u8) uic.Color {
    return .{ .r = base.r, .g = base.g, .b = base.b, .a = a };
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
    _ = try txt(ctx, sizes, "s3", "Heading", .{ style.heading, Style{ .text = th.acc } });
    _ = try txt(ctx, sizes, "sb", "body", .{ style.body, Style{ .text = th.dim } });
    _ = try txt(ctx, sizes, "ssm", "small", .{ style.small, Style{ .text = th.dim } });

    // TEXT-04 eyebrow role: a section label authored in normal case; the role uppercases it
    // (ASCII fold) and applies the loosened in-band tracking. Proves the transform + tracking
    // travel together from the role through `style.apply` to the drawn glyphs.
    _ = try txt(ctx, root, "eyebrow", "Section Label", .{ style.eyebrow, Style{ .text = th.acc } });

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
    // TEXT-03 clip cell: the heartbeat is status copy in a narrow readout. A `.clip` cell of
    // a fixed width keeps the row's geometry stable — the box and hit target are exactly the
    // 64px cell, and the glyphs are cropped to it (renderer-scoped, prior clip restored)
    // rather than letting a longer readout widen the vitals row. The short `<3 <3 <3` draws
    // in full; the cell only bites if the copy grows.
    _ = (try txt(ctx, vrow, "heart", "<3 <3 <3", .{Style{ .text = t.heartbeat_color(th, ctx.res.sim.elapsed, ctx.res.motion) }}))
        .with_cell(.clip, 64);

    // RENDER-01 blending fixture: translucent fills only look right if the renderer's draw
    // blend mode is `.blend` (SDL defaults to `.none`, which would render every layer opaque).
    // Each sub-figure stacks a translucent `fill` over an opaque base so the alpha composite
    // is visible on screen. A gradient feature (RENDER-04) does not exist yet, so the "wash"
    // is honestly a stack of translucent bands, not a true gradient.
    const bpanel2 = try t.panel(ctx, root, "blendpanel", "Blending");
    const blend_stage = try el.div(ctx, bpanel2, "blend_stage");
    _ = blend_stage.with_layout(.top_left)
        .with_size(.{ .fixed = 560 }, .{ .fixed = 120 });

    // (1) Translucent row hover: an opaque panel band with a low-alpha accent overlay on top,
    // as a hovered row would tint. If blending is off the accent covers the band completely.
    _ = try layer(ctx, blend_stage, "hover_base", 0, 0, 180, 32, th.panel);
    _ = try layer(ctx, blend_stage, "hover_tint", 0, 0, 180, 32, alpha(th.acc, 40));
    _ = (try txt(ctx, blend_stage, "hover_cap", "row hover", .{Style{ .text = th.dim, .font = 11 }}))
        .with_layout(.top_left).with_offset(188, 8);

    // (2) Backdrop scrim: a bright accent block half-covered by a translucent dark scrim, as a
    // modal backdrop would dim what is behind it. The overlapped half must read darker, not black.
    _ = try layer(ctx, blend_stage, "scrim_bright", 0, 44, 180, 32, th.acc);
    _ = try layer(ctx, blend_stage, "scrim_dark", 90, 44, 100, 32, alpha(th.bg, 150));

    // (3) Locked-tile dimming: an opaque `warn` tile with a translucent bg overlay covering it,
    // as a locked board tile is dimmed. The tile must show through at reduced opacity.
    _ = try layer(ctx, blend_stage, "lock_tile", 0, 88, 84, 28, th.warn);
    _ = try layer(ctx, blend_stage, "lock_dim", 0, 88, 84, 28, alpha(th.bg, 170));
    _ = (try txt(ctx, blend_stage, "lock_cap", "locked", .{Style{ .text = th.dim, .font = 11 }}))
        .with_layout(.top_left).with_offset(92, 96);

    // (4) Stacked-band wash: eight translucent white bands over a dark base build up a
    // left-to-right brightening ramp purely through alpha compositing (each band adds ~12%).
    _ = try layer(ctx, blend_stage, "wash_base", 220, 0, 320, 116, th.panel);
    var band: usize = 0;
    while (band < 8) : (band += 1) {
        const key = try std.fmt.allocPrint(ctx.arena, "wash_band{d}", .{band});
        const bx = 220 + @as(f32, @floatFromInt(band)) * 40;
        _ = try layer(ctx, blend_stage, key, bx, 0, 320 - @as(f32, @floatFromInt(band)) * 40, 116, alpha(th.fg, 30));
    }

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
