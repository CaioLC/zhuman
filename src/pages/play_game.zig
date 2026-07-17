/// The live HUD while the actor is alive: a top-left status column (day + resources + log)
/// and a centered Actions panel. Reads/mutates the actor's components inline on click.
const std = @import("std");
// general lib ECS
const ha = @import("ha");
const ecs = ha.ecs;
const comp = ha.comp;
const tag = ha.tag;
const actions = ha.actions;
const World = ha.world.World;
const Entity = ha.world.Entity;
// Ui Interface
const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Node = uic.Node;
// Game templates
const t = @import("./templates/root.zig");

pub fn ui_playgame(
    ctx: *uic.UiCtx,
    _: *World,
) !*Node {
    //globals
    // var char_buf: [64]u8 = undefined;
    // const warmth = compute_warmth(vigor);

    // UI
    const root = try el.root(ctx, "play");
    _ = root.with_layout(.top_left).with_flow(.{ .dir = .column });

    const header = try el.div(ctx, root, "header");
    _ = header
        .with_size(.{ .pct_of_parent = 1.0 }, .fit_children);

    const header_left = try el.div(ctx, header, "header");
    _ = header_left
        .with_layout(.bottom_left)
        .with_flow(.{ .dir = .row })
        .with_style(.{style.gap(6.0)});
    const title = try el.text(ctx, header_left, "title", "Human Action");
    _ = title
        .with_style(.{style.h1});
    const subtitle = try el.text(ctx, header_left, "subtitle", "Act 1");
    _ = subtitle
        .with_style(.{style.h2});

    const header_right = try el.div(ctx, header, "header");
    _ = header_right
        .with_layout(.bottom_right)
        .with_style(.{style.gap(6.0)});
    const day_counter = try el.text(ctx, header_right, "dcounter", "Day 1");
    _ = day_counter.with_style(.{style.h2});
    _ = try t.button(ctx, header_right, "status_buttom", "Alive", true);

    // --- padding demo: a bordered panel (pad 12) whose content is now inset from the border.
    const demo = try t.panel(ctx, root, "pad_demo", "Padding demo");
    const line1 = try el.text(ctx, demo, "l1", "content sits 12px inside the border");
    _ = line1.with_style(.{style.body});
    const boxed = try el.text(ctx, demo, "l2", "child with its own border");
    _ = boxed.with_style(.{ style.body, style.Style{ .outline_color = ctx.res.theme.acc } });

    //
    // const header_left = try uic.Node.pcreate(ui_ctx.arena, "header_left", header);
    // _ = header_left.with_layout(Layout.init(.center_left, .horizontal)).with_size(Size.init(.{ .pct_of_parent = 0.7 }, .fit_children, null));
    // _ = try uic.label(ui_ctx, header_left, "game_title", "ACT I: Robinson Crusoe");
    // const header_right = try uic.Node.pcreate(ui_ctx.arena, "header_right", header);
    // _ = header_right
    //     .with_layout(Layout.init(.center_right, .horizontal).with_gap(5.0))
    //     .with_size(Size.init(.{ .pct_of_parent = 0.3 }, .fit_children, null));
    // _ = try uic.label(ui_ctx, header_right, "calendar", "Day 1");
    // _ = try uic.label(ui_ctx, header_right, "status", "Alive");
    //
    // // Status column (top-left): day + resources panel + log.
    // const status_div = try uic.Node.pcreate(ui_ctx.arena, "status_div", play_root);
    // _ = status_div.with_layout(ui.features.Layout.init(.top_left, .vertical).with_gap(10));
    //
    // const day = 1 + @as(u64, @intFromFloat(ui_ctx.res.time.elapsed / app.secs_per_day));
    // _ = try uic.label(ui_ctx, status_div, "day_text", std.fmt.bufPrint(&char_buf, "Day {d}", .{day}) catch "?");
    //
    // const res_panel = try uic.panel(ui_ctx, status_div, "res_panel", "Resources");
    //
    // // Vitals: a small ASCII figure (mood from warmth) beside a pulsing "heartbeat". Flavor.
    // const vitals = try uic.Node.pcreate(ui_ctx.arena, "vitals", res_panel);
    // _ = vitals.with_layout(ui.features.Layout.init(.relative, .horizontal).with_gap(10));
    // const fig_color = if (warmth < 0.25) ui_ctx.res.theme.warn else ui_ctx.res.theme.acc;
    // try t.ui_figure(ui_ctx, vitals, t.figure_glyphs(warmth), fig_color);
    // const heart = try uic.label(ui_ctx, vitals, "heartbeat", "<3 <3 <3");
    // heart.render_data.text = heartbeat_color(ui_ctx.res.theme, ui_ctx.res.time.elapsed);
    //
    // _ = try uic.label(ui_ctx, res_panel, "vigor_text", std.fmt.bufPrint(&char_buf, "Vigor: {d:.0}/{d:.0}", .{ vigor.v, vigor.max }) catch "?");
    // _ = try uic.label(ui_ctx, res_panel, "food_text", std.fmt.bufPrint(&char_buf, "Food: {d:.0}  (q{d}, spoils {d:.2}/s)", .{ food.v, food.quality, food.spoils }) catch "?");
    // var mat_buf: [16]u8 = undefined;
    // _ = try uic.label(ui_ctx, res_panel, "materials_text", std.fmt.bufPrint(&char_buf, "Materials: {s}", .{fmt_num(&mat_buf, materials.v)}) catch "?");
    //
    // // Event log — newest-first, scrollable, each line recolored by its tone.
    // const log_panel = try uic.panel(ui_ctx, status_div, "log_panel", "Log");
    // const feed = &ui_ctx.res.log;
    // const log_view = try uic.scroll_view(ui_ctx, log_panel, "log_view", 260, 160);
    // var li: usize = 0;
    // while (li < feed.count) : (li += 1) {
    //     const entry = feed.get(li);
    //     const lkey = try std.fmt.allocPrint(ui_ctx.arena, "log{d}", .{li});
    //     const lnode = try uic.label(ui_ctx, log_view.content, lkey, entry.text());
    //     lnode.render_data.text = log_tone_color(ui_ctx.res.theme, entry.tone);
    // }
    //
    // // Actor condition word, pinned top-right (colored by severity).
    // const status = actor_status(ui_ctx.res.theme, vigor);
    // const status_node = try uic.label(ui_ctx, play_root, "status_text", status.word);
    // status_node.render_data.text = status.color;
    // _ = status_node.with_layout(ui.features.Layout.init(.top_right, null));
    //
    // // Actions (center): the labor actions the agent holds + an Eat action.
    // const center_div = try uic.Node.pcreate(ui_ctx.arena, "c_div", play_root);
    // _ = center_div.with_layout(ui.features.Layout.init(.center, .vertical).with_gap(10));
    // const act_panel = try uic.panel(ui_ctx, center_div, "act_panel", "Actions");
    // try action_button(ui_ctx, act_panel, world, e, comp.ActionForage, "forage", "Forage", actions.action_forage);
    // try action_button(ui_ctx, act_panel, world, e, comp.ActionFish, "fish", "Fish", actions.action_fish);
    // try action_button(ui_ctx, act_panel, world, e, comp.ActionChopWood, "chop", "Chop wood", actions.action_chop_wood);
    //
    // // Eat — separate: `action_eat` takes no `res` and converts one food unit into vigor,
    // // scaled by the food's quality.
    // const can_eat = food.v >= 1.0;
    // var ebuf: [48]u8 = undefined;
    // const eat_txt = std.fmt.bufPrint(&ebuf, "Eat  (-1 food, +{d} vig)", .{2 * @as(u32, food.quality)}) catch "Eat";
    // const eat_btn = try uic.button(ui_ctx, act_panel, "eat", eat_txt, can_eat);
    // if (eat_btn.query(ui_ctx).clicked and can_eat) actions.action_eat(world, e);

    return root.get();
}
