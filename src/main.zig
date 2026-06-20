const std = @import("std");
const ha = @import("ha");

const comp = ha.comp;
const tag = ha.tag;
const ui = ha.ui;
const Resources = ha.res.Resources;
const widgets = ha.widgets;
const sdl = ha.sdl;
const sys = ha.systems;
const ecs = ha.ecs;

const fps = 60;
const font_path = "assets/fonts/Kenney Mini Square.ttf";

/// A choice open to the actor. Acting pays `energy_cost` + `stamina_cost` up front
/// (whether or not it pays off) for a `p_success` chance at `energy_yield` energy —
/// a means expended against an uncertain end. The energy yield is *scaled by current
/// stamina* (`v / max`): a tired actor produces below standard. Stamina recovers only
/// by the passive trickle, so the labor/leisure margin is implicit — keep working
/// while drained, or pause and let stamina refill (paying energy decay meanwhile).
/// The player ranks these and acts on the one it most prefers; later the sim's AI
/// ranks the same catalog. Praxeology: cost, options, uncertainty.
const Action = struct {
    label: []const u8,
    energy_cost: f32,
    stamina_cost: f32,
    energy_yield: f32,
    p_success: f32,
};

const actions = [_]Action{
    // Forage: cheap, reliable, small. The hand-to-mouth staple.
    .{ .label = "Forage", .energy_cost = 0, .stamina_cost = 2, .energy_yield = 5, .p_success = 0.7 },
    // Fish: dearer and riskier, but a real surplus when it lands.
    .{ .label = "Fish", .energy_cost = 1, .stamina_cost = 4, .energy_yield = 14, .p_success = 0.4 },
    // Fish: dearest and riskiest, but a real surplus when it lands.
    .{ .label = "Hunt", .energy_cost = 1, .stamina_cost = 6, .energy_yield = 30, .p_success = 0.2 },
};

const CapitalKind = enum { tool, comfort };

/// A capital good: surplus energy spent now (`cost`) for a permanent improvement —
/// the *now-vs-later* margin. A `.tool` improves one action (`target` indexes into
/// `actions`): it scales that action's yield by `yield_mult` and adds `prob_add` to
/// its success chance. A `.comfort` good raises stamina recovery (`trickle_add`) and
/// may carry `upkeep` — extra energy decay per second to sustain it (a lit fireplace).
/// One-time unlocks, tracked by a bit in `comp.Capital.owned` at this good's index.
const Good = struct {
    label: []const u8,
    energy_cost: f32,
    stamina_cost: f32, // building it is tiring too
    kind: CapitalKind,
    target: usize = 0, // tool only: which action it improves
    yield_mult: f32 = 1.0, // tool only
    prob_add: f32 = 0.0, // tool only
    trickle_add: f32 = 0.0, // comfort only
    upkeep: f32 = 0.0, // comfort only: added energy decay/s
    icon_x: f32 = 0, // source cell origin in the icons.png sheet (icon_cell-sized squares)
    icon_y: f32 = 0,
};

/// Each sprite cell in `assets/icons.png` is this many pixels square (the sheet is a
/// 2×2 grid of 512px cells). `icon_x`/`icon_y` below index into it.
const icon_cell = 512.0;
/// On-screen size of a capital icon button.
const icon_px = 56.0;
/// Gap between a hovered icon and the tooltip floating above it.
const tip_gap = 6.0;

const capital = [_]Good{
    // Sandals: Walking is easier, makes gathering more effective. (sheet: top-right)
    .{ .label = "Sandals", .energy_cost = 10, .stamina_cost = 3, .kind = .tool, .target = 0, .yield_mult = 1.1, .prob_add = 0.10, .icon_x = icon_cell, .icon_y = 0 },
    // Fishing rod: makes Fish (actions[1]) land more often and yield more. (sheet: top-left)
    .{ .label = "Fishing rod", .energy_cost = 30, .stamina_cost = 5, .kind = .tool, .target = 1, .yield_mult = 1.6, .prob_add = 0.25, .icon_x = 0, .icon_y = 0 },
    // Bed: rest better — stamina trickles back faster, no upkeep. (sheet: bottom-left)
    .{ .label = "Bed", .energy_cost = 20, .stamina_cost = 4, .kind = .comfort, .trickle_add = 0.4, .icon_x = 0, .icon_y = icon_cell },
    // Fireplace: warmth speeds recovery a lot, but burns energy to stay lit. (sheet: bottom-right)
    .{ .label = "Fireplace", .energy_cost = 80, .stamina_cost = 6, .kind = .comfort, .trickle_add = 0.8, .upkeep = 0.3, .icon_x = icon_cell, .icon_y = icon_cell },
};

/// Spawn a fresh actor — starved and cold (low energy), but rested (full stamina).
/// Used at startup and on "start over": death wipes the entity, this reseeds the run
/// from the bottom, so everything accumulated is lost. The energy `start` is also the
/// respawn floor.
fn spawn_player(world: *ha.world.World) void {
    _ = world.spawn(.{
        comp.Energy{ .v = 8, .max = 8, .decay = 0.4 }, // starved; bleeds 0.5/s when idle
        comp.Stamina{ .v = 10, .max = 10, .trickle = 0.3 }, // rested; tiny passive regen
        comp.Capital{}, // owns nothing yet
        tag.Player,
    });
}

/// Bit mask for capital good `i` (its index in the `capital` catalog).
fn bit(i: usize) u32 {
    return @as(u32, 1) << @as(u5, @intCast(i));
}

/// Whether the actor owns capital good `i`.
fn owns(cap: *const comp.Capital, i: usize) bool {
    return (cap.owned & bit(i)) != 0;
}

/// Format a good's hover detail into `buf`: "owned" once bought, else its costs and
/// the effect it grants (tool: yield×/odds; comfort: stamina trickle, and upkeep if any).
/// Falls back to the bare label if the buffer is somehow too small.
fn capital_tip(buf: []u8, g: Good, is_owned: bool) []const u8 {
    if (is_owned) return std.fmt.bufPrint(buf, "{s}: owned", .{g.label}) catch g.label;
    return switch (g.kind) {
        .tool => std.fmt.bufPrint(buf, "{s}: {d:.0} e, {d:.0} sta | x{d:.1} yield, +{d:.0}%", .{ g.label, g.energy_cost, g.stamina_cost, g.yield_mult, g.prob_add * 100 }) catch g.label,
        .comfort => if (g.upkeep > 0)
            std.fmt.bufPrint(buf, "{s}: {d:.0} e, {d:.0} sta | +{d:.1}/s sta, -{d:.1}/s e", .{ g.label, g.energy_cost, g.stamina_cost, g.trickle_add, g.upkeep }) catch g.label
        else
            std.fmt.bufPrint(buf, "{s}: {d:.0} e, {d:.0} sta | +{d:.1}/s sta", .{ g.label, g.energy_cost, g.stamina_cost, g.trickle_add }) catch g.label,
    };
}

const App = struct {
    gpa: std.heap.GeneralPurposeAllocator(.{}),
    window: sdl.video.Window,
    renderer: sdl.render.Renderer,
    frame_capper: sdl.extras.FramerateCapper(f32),
    font: sdl.ttf.Font,
    resources: Resources,
    world: ha.world.World,
    frame_arena: std.heap.ArenaAllocator,
    ui: widgets.UiCtx,

    fn init() !App {
        const gpa = std.heap.GeneralPurposeAllocator(.{}){};
        try sdl.init(.{ .video = true, .events = true });
        try sdl.ttf.init();
        const window, const renderer = try sdl.render.Renderer.initWithWindow(
            "Human Action",
            800,
            600,
            .{ .resizable = true },
        );
        var frame_capper = sdl.extras.FramerateCapper(f32){ .mode = .{ .unlimited = {} } };
        renderer.setVSync(.{ .on_each_num_refresh = 1 }) catch {
            frame_capper.mode = .{ .limited = fps };
        };
        return .{
            .gpa = gpa,
            .window = window,
            .renderer = renderer,
            .frame_capper = frame_capper,
            .font = undefined,
            .resources = undefined,
            .world = undefined,
            .frame_arena = undefined,
            .ui = undefined,
        };
    }

    fn setup(self: *App, allocator: std.mem.Allocator) !void {
        self.font = try sdl.ttf.Font.init(font_path, 24);
        self.resources = try Resources.init(&self.font, &self.renderer, self.window);
        self.world = ha.world.World.init();
        spawn_player(&self.world);

        self.frame_arena = std.heap.ArenaAllocator.init(allocator);
        self.ui = widgets.UiCtx.init(&self.resources, allocator, self.frame_arena.allocator());
    }

    fn deinit(self: *App) void {
        self.ui.deinit();
        self.frame_arena.deinit();
        self.world.deinit();
        self.resources.deinit();
        self.font.deinit();
        self.renderer.deinit();
        self.window.deinit();
        sdl.ttf.quit();
        sdl.quit(.{ .video = true, .events = true });
        _ = self.gpa.deinit();
    }
};

pub fn main() !void {
    var app = try App.init();
    defer app.deinit();
    try app.setup(app.gpa.allocator());

    var quit = false;

    while (!quit) {
        // Event Stage
        app.resources.input.mouse_down = false; // edge: true only on a press this frame
        while (sdl.events.poll()) |event| {
            switch (event) {
                .quit, .terminating => quit = true,
                .key_down => |key| if (key.key == .escape) {
                    quit = true;
                },
                .mouse_motion => |mm| {
                    app.resources.input.mouse_x = mm.x;
                    app.resources.input.mouse_y = mm.y;
                },
                .mouse_button_down => |mb| {
                    app.resources.input.mouse_x = mb.x;
                    app.resources.input.mouse_y = mb.y;
                    if (mb.button == .left) {
                        app.resources.input.mouse_down = true;
                        app.ui.mark(.clicked, mb.x, mb.y);
                    }
                },
                else => {},
            }
        }

        // Update Stage
        // 1. update game resources
        app.resources.time.dt = app.frame_capper.delay();
        // 2. update game systems
        ecs.run(&app.world, &app.resources, sys.update_energy); // energy decays while idle
        ecs.run(&app.world, &app.resources, sys.update_stamina); // tiny passive stamina trickle
        ecs.run(&app.world, &app.resources, sys.mark_dead); // energy at 0 → tag Dead
        ecs.run(&app.world, &app.resources, sys.despawn_dead); // reap Dead entities
        // 3. update ui
        app.ui.mark(.hovering, app.resources.input.mouse_x, app.resources.input.mouse_y);
        app.ui.beginFrame();
        _ = app.frame_arena.reset(.retain_capacity); // last frame's node tree dies here
        const frame = try build_ui(&app.ui, &app.world);
        // Lay out + stamp each root. The overlay is its own tree, positioned via its
        // layout origin (set in build_ui) rather than the main tree's flow.
        try frame.main.set_global_pos();
        ui.stamp_rects(&app.ui, frame.main); // capture rects into interaction slots for next frame's hit-test
        if (frame.overlay) |ov| {
            try ov.set_global_pos();
            ui.stamp_rects(&app.ui, ov);
        }

        // Render Stage
        // window
        try app.renderer.setDrawColor(.{ .r = 20, .g = 20, .b = 40, .a = 255 });
        try app.renderer.clear();
        // ui — main tree first, then the overlay on top
        draw_tree(&app.ui, frame.main);
        if (frame.overlay) |ov| draw_tree(&app.ui, ov);
        // present
        try app.renderer.present();

        app.ui.endFrame();
    }
}

/// Walk a UI tree and paint each node by its render aspects. Order matters: fill
/// (backmost) → image → text → outline (topmost), so a hover/affordance ring shows
/// over opaque icon tiles. Called per root — the main tree, then any overlay.
fn draw_tree(u: *widgets.UiCtx, root: *widgets.Node) void {
    var it = root.iterate();
    while (it.next()) |node| {
        if (node.render_data.fill) |c| widgets.draw_fill(u, node, c);
        if (node.render_data.img) |s| widgets.draw_texture(u, node, s);
        if (node.render_data.text) |c| widgets.draw_text(u, node, c);
        if (node.render_data.outline) |c| widgets.draw_outline(u, node, c);
    }
}

/// What `build_ui` hands back each frame: the main tree, plus an optional floating
/// overlay tree (the hover tooltip). The render loop lays out and draws each in order —
/// the overlay last, so it sits on top. Two layers for now; grow to a list if needed.
const Ui = struct {
    main: *widgets.Node,
    overlay: ?*widgets.Node = null,
};

fn build_ui(ui_ctx: *widgets.UiCtx, world: *ha.world.World) !Ui {
    // "globals"
    const res = ui_ctx.res;
    const ww, const wh = try res.window.getSize();
    var char_buf: [64]u8 = undefined;
    var overlay: ?*widgets.Node = null; // floating tooltip, built on hover below

    // queries
    // MaybeSingle: the actor is despawned on death, so it may be absent. Energy, Stamina
    // and Capital co-spawn on one entity, so one query fetches all three.
    const q_actor = ecs.MaybeSingle(.{ comp.Energy, comp.Stamina, comp.Capital, ecs.With(tag.Player) }){ .world = world };
    const actor = q_actor.get();

    // node graph
    const root = try widgets.Node.create(ui_ctx.arena, "root");
    _ = root.with_layout(ui.features.Layout.init(.top_left, .horizontal))
        .with_size(ui.features.Size.initFixed(@floatFromInt(ww), @floatFromInt(wh), null));
    // Test image, pinned top-right. `img` sizes the node to the texture; we only
    // override the anchor. Texture is cached on Resources, not pooled per-node.
    // const top_right = try widgets.img(ui_ctx, root, "img", res.tex);
    // _ = top_right.with_layout(ui.features.Layout.init(.top_right, null));
    const center_div = try widgets.Node.pcreate(ui_ctx.arena, "c_div", root);
    _ = center_div.with_layout(ui.features.Layout.init(.center, .vertical).with_gap(10));
    {
        if (actor) |a| {
            const energy, const stamina, const cap = a;

            // Resources panel — the actor's stocks. The rate next to each count is read
            // straight off the component: energy decays at `decay`/s (capital upkeep
            // raises it), stamina trickles up at `trickle`/s (comfort capital raises it).
            const res_panel = try widgets.panel(ui_ctx, center_div, "res_panel", "Resources");
            _ = try widgets.label(ui_ctx, res_panel, "energy_text", std.fmt.bufPrint(&char_buf, "Energy: {d:.0} J  (-{d:.1}/s)", .{ energy.v, energy.decay }) catch "?");
            // _ = try widgets.progress_bar(ui_ctx, res_panel, "energy_bar", energy.v / energy.max, .{ .r = 230, .g = 180, .b = 80 });
            _ = try widgets.label(ui_ctx, res_panel, "stamina_text", std.fmt.bufPrint(&char_buf, "Stamina: {d:.0}/{d:.0}  (+{d:.1}/s)", .{ stamina.v, stamina.max, stamina.trickle }) catch "?");

            // Actions panel — each action pays its cost up front for an uncertain yield.
            // Clicking is acting — the actor employs means toward the option it most
            // prefers. The effective yield/odds fold in any owned tool that targets this
            // action (a rod boosts Fish), then the yield is scaled by current stamina
            // (`sfac`); the button shows that effective payoff, the roll then decides it.
            const act_panel = try widgets.panel(ui_ctx, center_div, "act_panel", "Actions");
            for (actions, 0..) |act, i| {
                const bkey = try std.fmt.allocPrint(ui_ctx.arena, "act{d}", .{i}); // arena-lived: outlives this frame's tree
                const sfac = stamina.v / stamina.max; // tired → below-standard outcomes

                var eff_yield = act.energy_yield;
                var eff_prob = act.p_success;
                for (capital, 0..) |g, gi| {
                    if (g.kind == .tool and g.target == i and owns(cap, gi)) {
                        eff_yield *= g.yield_mult;
                        eff_prob += g.prob_add;
                    }
                }
                if (eff_prob > 1.0) eff_prob = 1.0;

                const txt = std.fmt.bufPrint(&char_buf, "{s}  (-{d:.0} sta, +{d:.1} e, {d:.0}%)", .{ act.label, act.stamina_cost, eff_yield * sfac, eff_prob * 100 }) catch act.label;
                // Affordability drives both the look (dimmed when unpayable) and the
                // guard (the click is a no-op unless it's affordable).
                const affordable = energy.v >= act.energy_cost and stamina.v >= act.stamina_cost;
                const btn = try widgets.button(ui_ctx, act_panel, bkey, txt, affordable);
                if (btn.query(ui_ctx).clicked and affordable) {
                    energy.v -= act.energy_cost;
                    stamina.v -= act.stamina_cost;
                    if (ui_ctx.res.random().float(f32) < eff_prob) energy.v += eff_yield * sfac;
                    if (energy.v < 0) energy.v = 0; // the death pipeline tags + reaps it next frame
                }
            }

            // Capital panel — spend surplus energy now on a permanent edge later. One-time
            // unlocks, shown as a horizontal tray of icons (icons.png sheet). An owned good
            // is a static icon; an unowned one is an icon_button — its ring brightens on
            // hover and dims when unaffordable (the click is also affordability-guarded).
            // The buttons are icon-only; hovering one fills the detail line below the tray
            // with its costs/effects (queried off last frame's stamped rects).
            const cap_panel = try widgets.panel(ui_ctx, center_div, "cap_panel", "Capital");
            const cap_row = try widgets.Node.pcreate(ui_ctx.arena, "cap_row", cap_panel);
            _ = cap_row.with_layout(ui.features.Layout.init(.relative, .horizontal).with_gap(8));
            var hovered: ?usize = null; // which good the cursor is over
            var hov_rect: ?ui.Rect = null; // and where it sat last frame, to float the tooltip over it
            for (capital, 0..) |g, gi| {
                const ckey = try std.fmt.allocPrint(ui_ctx.arena, "cap{d}", .{gi});
                const src = sdl.rect.FRect{ .x = g.icon_x, .y = g.icon_y, .w = icon_cell, .h = icon_cell };
                if (owns(cap, gi)) {
                    // Owned: a static icon, no ring, not clickable — but still queried so
                    // hovering it shows its tooltip.
                    const node = try widgets.Node.pcreate(ui_ctx.arena, ckey, cap_row);
                    try widgets.data_sprite(ui_ctx, node, res.icons, src, icon_px);
                    _ = node.with_layout(ui.features.Layout.init(.relative, null));
                    if (node.query(ui_ctx).hovering) {
                        hovered = gi;
                        hov_rect = node.rect(ui_ctx);
                    }
                    continue;
                }
                const affordable = energy.v >= g.energy_cost and stamina.v >= g.stamina_cost;
                const buy = try widgets.icon_button(ui_ctx, cap_row, ckey, res.icons, src, icon_px, affordable);
                if (buy.query(ui_ctx).hovering) {
                    hovered = gi;
                    hov_rect = buy.rect(ui_ctx);
                }
                if (buy.query(ui_ctx).clicked and affordable) {
                    energy.v -= g.energy_cost;
                    stamina.v -= g.stamina_cost;
                    cap.owned |= bit(gi);
                    // Comfort effects bake into the components (so the readouts track them);
                    // tool effects are folded in at action resolution above.
                    if (g.kind == .comfort) {
                        stamina.trickle += g.trickle_add;
                        energy.decay += g.upkeep;
                    }
                }
            }
            // Hover tooltip — a floating overlay tree showing the hovered good's costs/
            // effects, pinned above its icon. Built only when a good is hovered and its
            // last-frame rect is known (the tray is static, so last frame's rect is right).
            // Sized by a throwaway layout pass, then given an origin centred over the icon.
            if (hovered) |hi| {
                if (hov_rect) |r| {
                    const tip = capital_tip(&char_buf, capital[hi], owns(cap, hi));
                    const box = try widgets.tooltip(ui_ctx, "tip", tip);
                    try box.set_global_pos(); // resolve its size (origin still 0,0)
                    const ox = r.x + (r.w - box.size.width) / 2; // centred over the icon
                    const oy = r.y - box.size.height - tip_gap; // floating just above it
                    box.layout = box.layout.with_origin(ox, oy);
                    overlay = box;
                }
            }
        } else {
            // Death is total: the run is over and everything accumulated is gone.
            _ = try widgets.label(ui_ctx, center_div, "dead_text", "You perished, cold and starved.");
            const restart = try widgets.button(ui_ctx, center_div, "restart", "Start over", true);
            if (restart.query(ui_ctx).clicked) spawn_player(world);
        }
    }

    // const bottom_div = try widgets.Node.pcreate(ui_ctx.arena, "b_div", root);
    // _ = bottom_div.with_layout(ui.features.Layout.init(.bottom_center, .vertical).with_gap(4));
    // {
    //     _ = try widgets.label(ui_ctx, bottom_div, "player_state", "You are hungry.");
    //     _ = try widgets.label(ui_ctx, bottom_div, "city_state", "You are alone.");
    // }
    return .{ .main = root, .overlay = overlay };
}
