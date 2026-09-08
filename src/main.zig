const std = @import("std");

const ha = @import("ha");

const comp = ha.comp;
const tag = ha.tag;
const ui_client = ha.ui_client;
const sdl = ha.sdl;
const sys = ha.systems;
const ecs = ha.ecs;
const actions = ha.actions;
const pages = @import("./pages/root.zig");
const Resources = ha.res.Resources;

// CONFIGS
const fps = 60;
const font_path = "assets/fonts/JetBrainsMonoNL-Regular.ttf";

fn nsToUs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_us;
}

// END CONFIGS

const App = struct {
    gpa: std.heap.GeneralPurposeAllocator(.{}),
    window: sdl.video.Window,
    renderer: sdl.render.Renderer,
    frame_capper: sdl.extras.FramerateCapper(f32),
    font: ha.font.Fonts,
    resources: Resources,
    world: ha.world.World,
    frame_arena: std.heap.ArenaAllocator,
    ui: ui_client.UiCtx,
    ui_profiler: ui_client.FrameProfiler = .{},

    fn init() !App {
        const gpa = std.heap.GeneralPurposeAllocator(.{}){};
        try sdl.init(.{ .video = true, .events = true });
        try sdl.ttf.init();
        // Sized to the BUILD panel, which is the tallest screen: five shelves of tiles whose
        // width grew with the manufactured tier's three-digit prices, so they wrap two to a
        // row. Resizable, and the columns do not yet reflow (docs/roadmap.md, Act I).
        const window, const renderer = try sdl.render.Renderer.initWithWindow(
            "Human Action",
            900,
            820,
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
        self.font = try ha.font.Fonts.init(allocator, font_path, ui_client.style.default_font);
        self.resources = try Resources.init(&self.font, &self.renderer, self.window);
        self.world = ha.world.World.init();
        _ = spawn_player(&self.world);
        self.resources.sim.log.push(.dim, "You wake alone. Cold. Hungry.");

        self.frame_arena = std.heap.ArenaAllocator.init(allocator);
        self.ui = ui_client.UiCtx.init(&self.resources, allocator, self.frame_arena.allocator());
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
        app.resources.input.wheel_y = 0; // edge: nonzero only on a wheel tick this frame
        while (sdl.events.poll()) |event| {
            switch (event) {
                .quit, .terminating => quit = true,
                .key_down => |key| if (key.key) |kc| {
                    if (kc == .escape) {
                        if (app.ui.focusedKey() != null) {
                            // Typing: Escape unfocuses the field rather than quitting.
                            app.ui.clearFocus();
                            sdl.keyboard.stopTextInput(app.window) catch {};
                        } else {
                            quit = true;
                        }
                    } else if (kc == .backspace) {
                        if (app.ui.focusedKey()) |fk| {
                            const idx = app.ui.cache(fk, ui_client.UiState.TextInputState);
                            const st = app.ui.pool(ui_client.UiState.TextInputState).get(idx);
                            var n = st.len;
                            if (n > 0) {
                                n -= 1;
                                while (n > 0 and (st.buf[n] & 0xC0) == 0x80) n -= 1; // skip UTF-8 continuation bytes
                                st.len = n;
                            }
                        }
                    }
                },
                .text_input => |ti| if (app.ui.focusedKey()) |fk| {
                    const idx = app.ui.cache(fk, ui_client.UiState.TextInputState);
                    const st = app.ui.pool(ui_client.UiState.TextInputState).get(idx);
                    if (st.len + ti.text.len <= st.buf.len) {
                        @memcpy(st.buf[st.len..][0..ti.text.len], ti.text);
                        st.len += ti.text.len;
                    }
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
                .mouse_wheel => |mw| {
                    app.resources.input.wheel_y = mw.scroll_y;
                },
                else => {},
            }
        }

        // Update Stage
        // 1. update game resources
        app.resources.time.dt = app.frame_capper.delay();
        // 2. update game systems — but only while the run is still being played. A housed
        // actor has ended Act I, and the curtain is a still frame: without this the world
        // would keep spoiling and starving behind the dialog, and a win left on screen
        // long enough would turn into a game over. `pages.build_ui` routes on the same fact.
        const housed = ecs.MaybeSingle(.{ comp.Shelter, ecs.With(tag.Player) }){ .world = &app.world };
        if (housed.get() == null) {
            ecs.run(&app.world, &app.resources, sys.advance_clock); // run clock ticks while alive
            ecs.run(&app.world, &app.resources, sys.update_food); // larder spoils
            ecs.run(&app.world, &app.resources, sys.metabolize); // continuous eating / starvation
            ecs.run(&app.world, &app.resources, sys.resolve_busy); // work in progress ticks/completes
            ha.capital.run_generators(&app.world, &app.resources); // capital that runs itself
            ecs.run(&app.world, &app.resources, sys.mark_dead); // vigor at 0 → tag Dead
            ecs.run(&app.world, &app.resources, sys.despawn_dead); // reap Dead entities
        }
        // 3. update ui
        app.ui.mark(.hovering, app.resources.input.mouse_x, app.resources.input.mouse_y);
        app.ui.beginFrame();
        _ = app.frame_arena.reset(.retain_capacity); // last frame's node tree dies here
        const frame = try pages.build_ui(&app.ui, &app.world);
        var ui_sample: ui_client.FrameProfileSample = .{};
        // Profile the solver's three internal passes per independent root, then stamp all
        // roots as one aggregate pass. The normal set_global_pos entry remains clock-free.
        for (frame) |t| {
            const layout_sample = try t.set_global_pos_profiled(app.ui.arena);
            ui_sample.add(layout_sample);
        }
        var ui_timer = try std.time.Timer.start();
        for (frame) |t| {
            ui_client.stamp_rects(&app.ui, t); // geometry + paint order for next event stage
        }
        ui_sample.stamping = ui_timer.read();

        // Render Stage
        // window — cleared to the theme's own background, not a fixed color
        const bg = app.resources.view.theme.bg;
        try app.renderer.setDrawColor(.{ .r = bg.r, .g = bg.g, .b = bg.b, .a = 255 });
        try app.renderer.clear();
        // ui — trees painted in list order, so later ones (overlays) land on top
        ui_timer.reset();
        for (frame) |t| ui_client.draw_tree(&app.ui, t);
        ui_sample.drawing = ui_timer.read();
        app.ui_profiler.record(ui_sample);
        if (app.ui_profiler.takeIfReady(600)) |report| {
            const avg = report.average;
            const max = report.maximum;
            const stamp_share: f64 = @as(f64, @floatFromInt(report.stampingPermille())) / 10.0;
            std.log.info(
                "ui five-pass {d}f avg us intrinsic={d:.1} relative={d:.1} place={d:.1} stamp={d:.1} draw={d:.1}; stamp={d:.1}%",
                .{ report.frames, nsToUs(avg.intrinsic), nsToUs(avg.relative), nsToUs(avg.placement), nsToUs(avg.stamping), nsToUs(avg.drawing), stamp_share },
            );
            std.log.info(
                "ui five-pass max us intrinsic={d:.1} relative={d:.1} place={d:.1} stamp={d:.1} draw={d:.1}",
                .{ nsToUs(max.intrinsic), nsToUs(max.relative), nsToUs(max.placement), nsToUs(max.stamping), nsToUs(max.drawing) },
            );
        }
        // present
        try app.renderer.present();

        app.ui.endFrame();
    }
}

fn spawn_agent(world: *ha.world.World) ha.world.Entity {
    return world.spawn(.{
        comp.Vigor{ .v = 10, .max = 10 }, // rested
        comp.InventoryFood{ .v = 4, .quality = 1, .spoils = 0.05 }, // a thin, perishable larder
        comp.InventoryMaterial{ .v = 0 }, // nothing stockpiled yet
        comp.Metabolism{}, // eats continuously from the first breath (normal ration)
    } ++ actions.actions_bundle);
}

pub fn spawn_player(world: *ha.world.World) ha.world.Entity {
    const e = spawn_agent(world);
    world.add(e, tag.Player{});
    return e;
}
