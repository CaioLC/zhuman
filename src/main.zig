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

const screen_width: c_int = 800;
const screen_height: c_int = 600;
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
    player: ha.world.Entity,
    frame_arena: std.heap.ArenaAllocator,
    ui: widgets.UiCtx,

    fn init() !App {
        const gpa = std.heap.GeneralPurposeAllocator(.{}){};
        try sdl.init(.{ .video = true, .events = true });
        try sdl.ttf.init();
        const window, const renderer = try sdl.render.Renderer.initWithWindow(
            "Human Action",
            screen_width,
            screen_height,
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
            .player = 0,
            .frame_arena = undefined,
            .ui = undefined,
        };
    }

    fn setup(self: *App, allocator: std.mem.Allocator) !void {
        self.font = try sdl.ttf.Font.init(font_path, 24);
        self.resources = Resources.init(&self.font, &self.renderer, self.window);
        self.world = ha.world.World.init();

        self.player = self.world.spawn();
        self.world.add(self.player, comp.Counter{ .v = 0, .multiplier = 1.0, .buffer = 0 });
        self.world.add(self.player, tag.Player{});

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

    // node graph + data
    const root = try widgets.Node.create(ui_ctx.arena, "root");
    const center_div = try widgets.Node.pcreate(ui_ctx.arena, "div", root);
    const counter = try widgets.Node.pcreate(ui_ctx.arena, "counter", center_div);
    {
        // counter data
        const counter_q = ecs.Single(.{ comp.Counter, ecs.With(tag.Player) }){ .world = world };
        const c = counter_q.get();
        try widgets.data_text(ui_ctx, counter, std.fmt.bufPrint(&char_buf, "Counter: {d:.0}", .{c.v}) catch "?");
        if (counter.query(ui_ctx).clicked) {
            c.v = 0;
            c.buffer = 0;
        }
    }
    const box = try widgets.Node.pcreate(ui_ctx.arena, "box", center_div);
    try widgets.data_text(ui_ctx, box, "Box");

    // layout
    _ = root.with_layout(ui.features.Layout.init(.top_left, .horizontal))
        .with_size(ui.features.Size.initFixed(@floatFromInt(ww), @floatFromInt(wh), null));
    _ = center_div.with_layout(ui.features.Layout.init(.center, .vertical));
    _ = counter.with_layout(ui.features.Layout.init(.relative, null));
    _ = box.with_layout(ui.features.Layout.init(.relative, null));

    return root;
}
