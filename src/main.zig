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
};

const capital = [_]Good{
    // Sandals: Walking is easier, makes gathering more effective.
    .{ .label = "Sandals", .energy_cost = 10, .stamina_cost = 3, .kind = .tool, .target = 0, .yield_mult = 1.1, .prob_add = 0.10 },
    // Fishing rod: makes Fish (actions[1]) land more often and yield more.
    .{ .label = "Fishing rod", .energy_cost = 30, .stamina_cost = 5, .kind = .tool, .target = 1, .yield_mult = 1.6, .prob_add = 0.25 },
    // Bed: rest better — stamina trickles back faster, no upkeep.
    .{ .label = "Bed", .energy_cost = 20, .stamina_cost = 4, .kind = .comfort, .trickle_add = 0.4 },
    // Fireplace: warmth speeds recovery a lot, but burns energy to stay lit.
    .{ .label = "Fireplace", .energy_cost = 80, .stamina_cost = 6, .kind = .comfort, .trickle_add = 0.8, .upkeep = 0.3 },
};

/// Spawn a fresh actor — starved and cold (low energy), but rested (full stamina).
/// Used at startup and on "start over": death wipes the entity, this reseeds the run
/// from the bottom, so everything accumulated is lost. The energy `start` is also the
/// respawn floor.
fn spawn_player(world: *ha.world.World) void {
    _ = world.spawn(.{
        comp.Energy{ .v = 8, .start = 8, .decay = 0.5 }, // starved; bleeds 0.5/s when idle
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
        self.resources = Resources.init(&self.font, &self.renderer, self.window);
        self.world = ha.world.World.init();
        spawn_player(&self.world);

        self.frame_arena = std.heap.ArenaAllocator.init(allocator);
        self.ui = widgets.UiCtx.init(&self.resources, allocator, self.frame_arena.allocator());
    }

    fn deinit(self: *App) void {
        self.ui.deinit();
        self.frame_arena.deinit();
        self.world.deinit();
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
        const root = try build_ui(&app.ui, &app.world);
        try root.set_global_pos();
        ui.stamp_rects(&app.ui, root); // capture rects into interaction slots for next frame's hit-test

        // Render Stage
        // window
        try app.renderer.setDrawColor(.{ .r = 20, .g = 20, .b = 40, .a = 255 });
        try app.renderer.clear();
        // ui
        var it = root.iterate();
        while (it.next()) |node| {
            if (node.render_flags.fill) widgets.draw_fill(&app.ui, node);
            if (node.render_flags.outline) widgets.draw_outline(&app.ui, node);
            if (node.render_flags.text) widgets.draw_text(&app.ui, node);
        }
        // present
        try app.renderer.present();

        app.ui.endFrame();
    }
}

fn build_ui(ui_ctx: *widgets.UiCtx, world: *ha.world.World) !*widgets.Node {
    // "globals"
    var char_buf: [64]u8 = undefined;
    const ww, const wh = try ui_ctx.res.window.getSize();
    // queries
    // MaybeSingle: the actor is despawned on death, so it may be absent. Energy, Stamina
    // and Capital co-spawn on one entity, so one query fetches all three.
    const q_actor = ecs.MaybeSingle(.{ comp.Energy, comp.Stamina, comp.Capital, ecs.With(tag.Player) }){ .world = world };
    const actor = q_actor.get();

    // node graph
    const root = try widgets.Node.create(ui_ctx.arena, "root");
    _ = root.with_layout(ui.features.Layout.init(.top_left, .horizontal))
        .with_size(ui.features.Size.initFixed(@floatFromInt(ww), @floatFromInt(wh), null));
    const center_div = try widgets.Node.pcreate(ui_ctx.arena, "c_div", root);
    _ = center_div.with_layout(ui.features.Layout.init(.center, .vertical).with_gap(10));
    {
        // The lone actor under scarcity. Energy is the survival stock (and the
        // accumulation currency) — it decays, and the actor acts to replenish it.
        // Stamina gates how well those actions land. While alive, it faces a menu.
        if (actor) |a| {
            const energy, const stamina, const cap = a;

            // Resources panel — the actor's stocks. The rate next to each count is read
            // straight off the component: energy decays at `decay`/s (capital upkeep
            // raises it), stamina trickles up at `trickle`/s (comfort capital raises it).
            const res_panel = try widgets.panel(ui_ctx, center_div, "res_panel", "Resources");
            _ = try widgets.label(ui_ctx, res_panel, "energy_text", std.fmt.bufPrint(&char_buf, "Energy: {d:.0} J  (-{d:.1}/s)", .{ energy.v, energy.decay }) catch "?");
            _ = try widgets.label(ui_ctx, res_panel, "stamina_text", std.fmt.bufPrint(&char_buf, "Stamina: {d:.0}/{d:.0}  (+{d:.1}/s)", .{ stamina.v, stamina.max, stamina.trickle }) catch "?");
            _ = try widgets.progress_bar(ui_ctx, res_panel, "stamina_bar", stamina.v / stamina.max, .{ .r = 230, .g = 180, .b = 80 });

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
            // unlocks — an owned good shows as a static line; an unowned one is a buy
            // button (greyed out by an affordability guard if you can't pay yet).
            const cap_panel = try widgets.panel(ui_ctx, center_div, "cap_panel", "Capital");
            for (capital, 0..) |g, gi| {
                const ckey = try std.fmt.allocPrint(ui_ctx.arena, "cap{d}", .{gi});
                if (owns(cap, gi)) {
                    _ = try widgets.label(ui_ctx, cap_panel, ckey, std.fmt.bufPrint(&char_buf, "{s}: owned", .{g.label}) catch g.label);
                    continue;
                }
                const txt = switch (g.kind) {
                    .tool => std.fmt.bufPrint(&char_buf, "Buy {s} [{d:.0} e, {d:.0} sta]  x{d:.1} yield, +{d:.0}%", .{ g.label, g.energy_cost, g.stamina_cost, g.yield_mult, g.prob_add * 100 }) catch g.label,
                    .comfort => if (g.upkeep > 0)
                        std.fmt.bufPrint(&char_buf, "Buy {s} [{d:.0} e, {d:.0} sta]  +{d:.1}/s sta, -{d:.1}/s e", .{ g.label, g.energy_cost, g.stamina_cost, g.trickle_add, g.upkeep }) catch g.label
                    else
                        std.fmt.bufPrint(&char_buf, "Buy {s} [{d:.0} e, {d:.0} sta]  +{d:.1}/s sta", .{ g.label, g.energy_cost, g.stamina_cost, g.trickle_add }) catch g.label,
                };
                const affordable = energy.v >= g.energy_cost and stamina.v >= g.stamina_cost;
                const buy = try widgets.button(ui_ctx, cap_panel, ckey, txt, affordable);
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
    return root;
}
