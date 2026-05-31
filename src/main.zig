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

const ROOT_SEED: u64 = 0;

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
    ui: widgets.Ui,
    /// Last frame's (laid-out) node tree, kept across the frame boundary so the
    /// event stage can mark it before the arena is reset. `null` on frame 0.
    prev_root: ?*ui.Node,

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
            .prev_root = null,
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
        self.ui = widgets.Ui.init(&self.resources, allocator, self.frame_arena.allocator());
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

    const raw_ctx: *anyopaque = @ptrCast(&app.ui);
    var quit = false;

    while (!quit) {
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
                    if (mb.button == .left) app.resources.input.mouse_down = true;
                },
                else => {},
            }
        }

        // Event stage: pepper last frame's (laid-out) tree with interaction flags
        // from this frame's input. Conditions are userland — the engine just walks
        // and stamps. `active` would be latched here on a press and cleared on a
        // release; left out until there's a real use (no release tracking yet).
        if (app.prev_root) |prev| {
            const in = app.resources.input;
            ui.mark_at(&app.ui, prev, .hovering, in.mouse_x, in.mouse_y);
            if (in.mouse_down) ui.mark_at(&app.ui, prev, .clicked, in.mouse_x, in.mouse_y);
        }

        app.resources.time.dt = app.frame_capper.delay();
        ecs.run(&app.world, &app.resources, sys.update_counter);

        app.ui.beginFrame();
        _ = app.frame_arena.reset(.retain_capacity); // prev_root's memory dies here

        const root = try build_ui(&app.ui, &app.world, app.player);
        try root.set_global_pos(null, raw_ctx);
        app.prev_root = root; // retain for next frame's event-stage marking

        try app.renderer.setDrawColor(.{ .r = 20, .g = 20, .b = 40, .a = 255 });
        try app.renderer.clear();
        ui.render(root, raw_ctx);
        try app.renderer.present();

        app.ui.endFrame();
    }
}

fn build_ui(u: *widgets.Ui, world: *ha.world.World, player: ha.world.Entity) !*ui.Node {
    const a = u.arena;

    const root = try ui.Node.create(a, "root");
    _ = root.with_size(ui.Size.init(&screen_size, null));
    _ = root.with_layout(ui.Layout.init(.top_left, .centered_wrapped));

    // Counter: clickable, shows the live component value. Click resets it —
    // mutating the component inline (Fork 2), no callback.
    const c = world.get(player, comp.Counter).?;
    var cbuf: [64]u8 = undefined;
    const ctext = std.fmt.bufPrint(&cbuf, "Counter: {d:.0}", .{c.v}) catch "?";
    if ((try widgets.button(u, root, ROOT_SEED, "counter", ctext)).clicked) {
        c.v = 0;
        c.buffer = 0;
    }

    const left = try ui.Node.create(a, "left_panel");
    _ = left.with_size(ui.Size.initFixed(300, 600, null));
    _ = left.with_layout(ui.Layout.init(.top_left, .vertical));
    try root.add_child(a, left);
    const left_seed = ui.key(ROOT_SEED, "left_panel");
    inline for (.{ "population", "demand", "produce", "calories", "stockpile" }) |id| {
        try widgets.label(u, left, left_seed, id, "");
    }

    const right = try ui.Node.create(a, "right_panel");
    _ = right.with_size(ui.Size.initFixed(300, 600, null));
    _ = right.with_layout(ui.Layout.init(.top_right, .vertical_right));
    try root.add_child(a, right);
    const right_seed = ui.key(ROOT_SEED, "right_panel");
    inline for (.{ "calendar", "money" }) |id| {
        try widgets.label(u, right, right_seed, id, "");
    }

    return root;
}

pub fn screen_size(raw_ctx: *anyopaque, _: *ui.Node) anyerror!struct { f32, f32 } {
    const u: *widgets.Ui = @ptrCast(@alignCast(raw_ctx));
    const width, const height = try u.res.window.getSize();
    return .{ @floatFromInt(width), @floatFromInt(height) };
}
