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

        _ = self.world.spawn(.{
            comp.Counter{ .v = 0, .multiplier = 1.0 },
            tag.Player,
        });
        _ = self.world.spawn(.{
            comp.TimerWrap{ .v = 10, .start = 10, .end = 0, .multiplier = 0.5 },
            tag.Player,
        });
        _ = self.world.spawn(.{
            comp.CounterFill{ .v = 0, .start = 0, .end = 10, .multiplier = 0.5 },
            tag.Player,
        });
        _ = self.world.spawn(.{
            comp.Life{ .v = 10, .start = 10, .multiplier = 1.0 }, // drains 10→0 over 10s, then dies
            tag.Player,
        });

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
        ecs.run(&app.world, &app.resources, sys.update_counter);
        ecs.run(&app.world, &app.resources, sys.update_timer_wrap);
        ecs.run(&app.world, &app.resources, sys.update_counter_fill);
        ecs.run(&app.world, &app.resources, sys.update_life); // drain life toward 0
        ecs.run(&app.world, &app.resources, sys.mark_dead); // life at 0 → tag Dead
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
    const q_counter = ecs.Single(.{ comp.Counter, ecs.With(tag.Player) }){ .world = world };
    const c = q_counter.get();
    const q_timer = ecs.Single(.{ comp.TimerWrap, ecs.With(tag.Player) }){ .world = world };
    const t = q_timer.get();
    const ft_q = ecs.Single(.{ comp.CounterFill, ecs.With(tag.Player) }){ .world = world };
    const ft = ft_q.get();
    // MaybeSingle: the life entity is despawned on death, so it may be absent.
    const q_life = ecs.MaybeSingle(.{ comp.Life, ecs.With(tag.Player) }){ .world = world };
    const life = q_life.get();

    // node graph
    const root = try widgets.Node.create(ui_ctx.arena, "root");
    _ = root.with_layout(ui.features.Layout.init(.top_left, .horizontal))
        .with_size(ui.features.Size.initFixed(@floatFromInt(ww), @floatFromInt(wh), null));
    const center_div = try widgets.Node.pcreate(ui_ctx.arena, "c_div", root);
    _ = center_div.with_layout(ui.features.Layout.init(.center, .vertical));
    {
        // Counter: clickable readout — clicking it resets the count.
        const counter = try widgets.label(ui_ctx, center_div, "counter", std.fmt.bufPrint(&char_buf, "Counter: {d:.0}", .{c.v}) catch "?");
        if (counter.query(ui_ctx).clicked) c.v = 0;
        _ = try widgets.label(ui_ctx, center_div, "timer_text", std.fmt.bufPrint(&char_buf, "Time: {d:.0}", .{@ceil(t.v)}) catch "?");
        _ = try widgets.progress_bar(ui_ctx, center_div, "bar", t.v / t.start);
        const frac = (ft.v - ft.start) / (ft.end - ft.start); // 0.0 (empty) → 1.0 (full)
        const fill_outer = try widgets.progress_bar(ui_ctx, center_div, "fill", frac);
        // query() keeps the slot alive so its rect is stamped for next frame's hit-test
        if (fill_outer.query(ui_ctx).clicked) ft.v = ft.start;

        // Life: a draining bar + readout, shown only while the entity is alive.
        if (life) |l| {
            _ = try widgets.label(ui_ctx, center_div, "life_text", std.fmt.bufPrint(&char_buf, "Life: {d:.0}", .{@ceil(l.v)}) catch "?");
            _ = try widgets.progress_bar(ui_ctx, center_div, "life", l.v / l.start);
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
