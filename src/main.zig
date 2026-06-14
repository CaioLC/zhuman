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
/// stamina* (`v / max`): a tired actor produces below standard. `Rest` is the lone
/// exception — it yields `stamina_yield` (foregoing production to consume leisure)
/// and is never stamina-scaled. The player ranks these and acts on the one it most
/// prefers; later the sim's AI ranks the same catalog. Praxeology: cost, options,
/// uncertainty, and the two margins — labor/leisure (stamina) and now/later (energy).
const Action = struct {
    label: []const u8,
    energy_cost: f32,
    stamina_cost: f32,
    energy_yield: f32,
    stamina_yield: f32,
    p_success: f32,
};

const actions = [_]Action{
    // Forage: cheap, reliable, small. The hand-to-mouth staple.
    .{ .label = "Forage", .energy_cost = 0, .stamina_cost = 2, .energy_yield = 5, .stamina_yield = 0, .p_success = 0.7 },
    // Fish: dearer and riskier, but a real surplus when it lands.
    .{ .label = "Fish", .energy_cost = 1, .stamina_cost = 4, .energy_yield = 14, .stamina_yield = 0, .p_success = 0.4 },
    // Rest: produce nothing, recover stamina — the deliberate leisure choice.
    .{ .label = "Rest", .energy_cost = 0, .stamina_cost = 0, .energy_yield = 0, .stamina_yield = 6, .p_success = 1.0 },
};

/// Spawn a fresh actor — starved and cold (low energy), but rested (full stamina).
/// Used at startup and on "start over": death wipes the entity, this reseeds the run
/// from the bottom, so everything accumulated is lost. The energy `start` is also the
/// respawn floor.
fn spawn_player(world: *ha.world.World) void {
    _ = world.spawn(.{
        comp.Energy{ .v = 8, .start = 8, .multiplier = 2.0 }, // decays ~0.5/s when idle
        comp.Stamina{ .v = 10, .max = 10, .trickle = 0.2 }, // rested; tiny passive regen
        tag.Player,
    });
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
    // MaybeSingle: the actor is despawned on death, so it may be absent. Energy + Stamina
    // co-spawn on one entity, so one query fetches both (yields `?.{ *Energy, *Stamina }`).
    const q_actor = ecs.MaybeSingle(.{ comp.Energy, comp.Stamina, ecs.With(tag.Player) }){ .world = world };
    const actor = q_actor.get();

    // node graph
    const root = try widgets.Node.create(ui_ctx.arena, "root");
    _ = root.with_layout(ui.features.Layout.init(.top_left, .horizontal))
        .with_size(ui.features.Size.initFixed(@floatFromInt(ww), @floatFromInt(wh), null));
    const center_div = try widgets.Node.pcreate(ui_ctx.arena, "c_div", root);
    _ = center_div.with_layout(ui.features.Layout.init(.center, .vertical));
    {
        // The lone actor under scarcity. Energy is the survival stock (and the
        // accumulation currency) — it decays, and the actor acts to replenish it.
        // Stamina gates how well those actions land. While alive, it faces a menu.
        if (actor) |a| {
            const energy, const stamina = a;

            _ = try widgets.label(ui_ctx, center_div, "energy_text", std.fmt.bufPrint(&char_buf, "Energy: {d:.0} J", .{energy.v}) catch "?");
            _ = try widgets.label(ui_ctx, center_div, "stamina_text", std.fmt.bufPrint(&char_buf, "Stamina: {d:.0}/{d:.0}", .{ stamina.v, stamina.max }) catch "?");
            _ = try widgets.progress_bar(ui_ctx, center_div, "stamina_bar", stamina.v / stamina.max);

            // Decision: each action pays its cost up front for an uncertain yield.
            // Clicking is acting — the actor employs means toward the option it most
            // prefers. The energy yield is scaled by current stamina (`sfac`), so the
            // button shows the *effective* payoff right now; the roll then decides it.
            for (actions, 0..) |act, i| {
                const bkey = try std.fmt.allocPrint(ui_ctx.arena, "act{d}", .{i}); // arena-lived: outlives this frame's tree
                const sfac = stamina.v / stamina.max; // tired → below-standard outcomes
                const txt = if (act.stamina_yield > 0)
                    std.fmt.bufPrint(&char_buf, "{s}  (+{d:.0} stamina)", .{ act.label, act.stamina_yield }) catch act.label
                else
                    std.fmt.bufPrint(&char_buf, "{s}  (-{d:.0} sta, +{d:.1} e, {d:.0}%)", .{ act.label, act.stamina_cost, act.energy_yield * sfac, act.p_success * 100 }) catch act.label;
                const btn = try widgets.button(ui_ctx, center_div, bkey, txt);
                // Only act if the cost is affordable, else the click is a no-op.
                if (btn.query(ui_ctx).clicked and energy.v >= act.energy_cost and stamina.v >= act.stamina_cost) {
                    energy.v -= act.energy_cost;
                    stamina.v -= act.stamina_cost;
                    if (ui_ctx.res.random().float(f32) < act.p_success) energy.v += act.energy_yield * sfac;
                    stamina.v += act.stamina_yield; // Rest's payoff (0 for productive actions)
                    if (stamina.v > stamina.max) stamina.v = stamina.max;
                    if (energy.v < 0) energy.v = 0; // the death pipeline tags + reaps it next frame
                }
            }
        } else {
            // Death is total: the run is over and everything accumulated is gone.
            _ = try widgets.label(ui_ctx, center_div, "dead_text", "You perished, cold and starved.");
            const restart = try widgets.button(ui_ctx, center_div, "restart", "Start over");
            if (restart.query(ui_ctx).clicked) spawn_player(world);
        }
    }

    const bottom_div = try widgets.Node.pcreate(ui_ctx.arena, "b_div", root);
    _ = bottom_div.with_layout(ui.features.Layout.init(.bottom_center, .vertical));
    {
        _ = try widgets.label(ui_ctx, bottom_div, "player_state", "You are hungry.");
        _ = try widgets.label(ui_ctx, bottom_div, "city_state", "You are alone.");
    }
    return root;
}
