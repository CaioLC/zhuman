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

const PointerIdentity = struct { kind: ui_client.PointerKind, id: ?u64 };

fn modifiersFromSdl(mod: sdl.keycode.KeyModifier) ui_client.Modifiers {
    return .{
        .shift = mod.left_shift or mod.right_shift or mod.level5_shift,
        .control = mod.left_control or mod.right_control,
        .alt = mod.left_alt or mod.right_alt,
        .gui = mod.left_gui or mod.right_gui,
        .caps_lock = mod.caps_lock,
        .num_lock = mod.num_lock,
        .scroll_lock = mod.scroll_lock,
        .mode = mod.mode,
    };
}

fn mouseIdentity(id: ?sdl.mouse.Id) PointerIdentity {
    const value = id orelse return .{ .kind = .mouse, .id = null };
    const kind: ui_client.PointerKind = if (value.value == sdl.mouse.Id.touch.value)
        .touch
    else if (value.value == sdl.mouse.Id.pen.value)
        .pen
    else
        .mouse;
    return .{ .kind = kind, .id = @intCast(value.value) };
}

fn pointerButton(button: sdl.mouse.Button) ?ui_client.PointerButton {
    return switch (button) {
        .left => .primary,
        .middle => .middle,
        .right => .secondary,
        .x1 => .aux1,
        .x2 => .aux2,
        else => null,
    };
}

fn syncMouseButtons(input: *ui_client.Input, state: sdl.mouse.ButtonFlags) void {
    input.syncButtonHeld(.primary, state.left);
    input.syncButtonHeld(.middle, state.middle);
    input.syncButtonHeld(.secondary, state.right);
    input.syncButtonHeld(.aux1, state.side1);
    input.syncButtonHeld(.aux2, state.side2);
}

/// Scale an incoming SDL pointer coordinate (window/logical space) into the UI's **device-px**
/// layout space: the layout, hit geometry, and drag math live in device pixels
/// (logical × DPI), while SDL delivers mouse/finger coordinates in window coordinates, so every
/// coordinate is multiplied by the frame's `dpi_scale` at this one seam before it reaches the
/// input model or hit-testing. At DPI 1 this is identity (today's behavior).
fn pointerAt(app: *App, x: f32, y: f32) ui_client.InputPoint {
    const s = app.resources.view.metrics.dpi_scale;
    const k = if (s > 0) s else 1;
    return .{ .x = x * k, .y = y * k };
}

fn routePointerPress(app: *App, kind: ui_client.PointerKind, id: ?u64, position: ui_client.InputPoint) void {
    // Right after a resize the stamped rects are the previous size's, so do not
    // begin an activation against them — a press this frame would target stale geometry.
    if (app.driver.router.geometry_stale) return;
    app.driver.router.pointerPress(kind, id, position);
}

fn routePointerMotion(app: *App, kind: ui_client.PointerKind, id: ?u64, position: ui_client.InputPoint) void {
    app.driver.router.pointerMotion(kind, id, position);
}

fn routePointerRelease(app: *App, kind: ui_client.PointerKind, id: ?u64, position: ui_client.InputPoint) void {
    app.driver.router.pointerRelease(kind, id, position);
}

fn cancelPointerGesture(app: *App) void {
    app.driver.router.cancelGesture();
}

// END CONFIGS

// ---- SDL platform seam for the router -------------------------------------------------
// The one routing policy (`ui_client/route.zig`) reaches the clipboard and the end of the
// platform text-input session through an injectable `route.Platform`. The desktop host binds
// SDL to it; a headless test binds `route.Platform.none` or an in-memory stub. The window is
// the only state the vtable needs, so it is the opaque `ctx`.

fn sdlClipboardRead(ctx: ?*anyopaque, buf: []u8) ?[]const u8 {
    _ = ctx;
    if (!sdl.clipboard.hasText()) return null;
    const clip = sdl.clipboard.getText() catch return null;
    defer sdl.free(clip);
    const n = @min(buf.len, clip.len);
    @memcpy(buf[0..n], clip[0..n]);
    return buf[0..n];
}

fn sdlClipboardWrite(ctx: ?*anyopaque, text: [:0]const u8) bool {
    _ = ctx;
    sdl.clipboard.setText(text) catch return false;
    return true;
}

fn sdlStopTextInput(ctx: ?*anyopaque) void {
    const window: *sdl.video.Window = @ptrCast(@alignCast(ctx.?));
    sdl.keyboard.stopTextInput(window.*) catch {};
}

const sdl_platform_vtable: ui_client.RoutePlatform.VTable = .{
    .clipboard_read = sdlClipboardRead,
    .clipboard_write = sdlClipboardWrite,
    .stop_text_input = sdlStopTextInput,
};

fn sdlPlatform(window: *sdl.video.Window) ui_client.RoutePlatform {
    return .{ .ctx = window, .vtable = &sdl_platform_vtable };
}

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
    /// The host frame driver — owns the one routing policy (`route.Router`) and runs the
    /// per-frame UI phase sequence (`frame.Driver.step`). Bound to `&ui`/`&frame_arena` in
    /// `setup`, after those fields have stable addresses.
    driver: ui_client.FrameDriver = undefined,
    platform_cursors: ui_client.PlatformCursors,
    /// Development frame capture (`HA_UI_PROFILE`): five-pass timings paired with per-pool /
    /// interaction / node state counts over one shared report window. Fed by the frame
    /// `sample` hook; a no-op unless the env switch is set and info logging is compiled in.
    ui_capture: ui_client.FrameCapture = .{},
    /// The `data/` files' modification times; a change reloads the roster between frames.
    data_watch: ha.reload.Watch = .{},

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
        // Configure the draw blend mode explicitly. SDL defaults to `.none`
        // (source replaces destination, ignoring alpha); `.blend` makes translucent fills,
        // rings, scrims, and dimming alpha-composite. The render walk re-asserts this per
        // tree so it survives a device reset, but set it here so the initial clear and any
        // pre-walk draw share the same known baseline.
        renderer.setDrawBlendMode(.blend) catch {};
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
            .platform_cursors = ui_client.PlatformCursors.init(),
        };
    }

    fn setup(self: *App, allocator: std.mem.Allocator) !void {
        self.font = try ha.font.Fonts.init(allocator, font_path, ui_client.style.default_font);
        self.resources = try Resources.init(allocator, &self.font, &self.renderer, self.window);
        // Resolve the reduced-motion policy ONCE here: an explicit
        // `HA_REDUCED_MOTION` override wins, else the platform probe (Windows
        // `SPI_GETCLIENTAREAANIMATION`; deterministic `false` elsewhere), else a `false`
        // fallback. No per-frame OS call — `build_ui` only projects this onto
        // `view.reduced_motion` each frame.
        self.resources.motion = ui_client.resolveMotionFromEnv(allocator, ui_client.PlatformMotionProbe.instance());
        self.world = ha.world.World.init();
        _ = spawn_player(&self.world);
        self.resources.sim.log.push(.dim, opening_line);

        self.frame_arena = std.heap.ArenaAllocator.init(allocator);
        self.ui = ui_client.UiCtx.init(&self.resources, allocator, self.frame_arena.allocator());
        // Bind the frame driver to this app's now-stable `ui`/`frame_arena`, with SDL bound to
        // the one routing policy's platform seam (clipboard + text-input stop). The SDL loop
        // routes each pointer event through `driver.router` as it arrives, and runs the rest of
        // the per-frame lifecycle through `driver.step` (via host callbacks below).
        self.driver = ui_client.FrameDriver.init(&self.ui, &self.frame_arena, sdlPlatform(&self.window));
    }

    fn deinit(self: *App) void {
        self.ui.deinit();
        self.frame_arena.deinit();
        self.world.deinit();
        self.resources.deinit();
        self.font.deinit();
        self.platform_cursors.deinit();
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

    while (!app.resources.menu.quit_requested) {
        // Event Stage
        const input = &app.resources.input;
        input.beginFrame();
        while (sdl.events.poll()) |event| {
            switch (event) {
                .quit, .terminating => app.resources.menu.quit_requested = true,
                .key_down, .key_up => |key| if (key.key) |kc| {
                    const action: ui_client.KeyAction = if (!key.down)
                        .release
                    else if (key.repeat)
                        .repeat
                    else
                        .press;
                    input.recordKey(kc, action, modifiersFromSdl(key.mod));
                },
                .text_input => |text| input.appendText(text.text),
                .mouse_motion => |motion| {
                    const pointer = mouseIdentity(motion.id);
                    const mpos = pointerAt(&app, motion.x, motion.y);
                    const mdelta = pointerAt(&app, motion.x_rel, motion.y_rel);
                    input.recordMotion(
                        pointer.kind,
                        pointer.id,
                        mpos,
                        mdelta,
                    );
                    syncMouseButtons(input, motion.state);
                    if (pointer.kind != .touch) {
                        routePointerMotion(&app, pointer.kind, pointer.id, mpos);
                    }
                },
                .mouse_button_down, .mouse_button_up => |button| if (pointerButton(button.button)) |mapped| {
                    const pointer = mouseIdentity(button.id);
                    const position = pointerAt(&app, button.x, button.y);
                    input.recordButton(
                        pointer.kind,
                        pointer.id,
                        mapped,
                        button.down,
                        button.clicks,
                        position,
                    );
                    if (mapped == .primary and pointer.kind != .touch) {
                        if (button.down)
                            routePointerPress(&app, pointer.kind, pointer.id, position)
                        else
                            routePointerRelease(&app, pointer.kind, pointer.id, position);
                    }
                },
                .mouse_wheel => |wheel| {
                    const pointer = mouseIdentity(wheel.id);
                    const wpos = pointerAt(&app, wheel.x, wheel.y);
                    input.recordWheel(
                        pointer.kind,
                        pointer.id,
                        wpos,
                        .{ .x = wheel.scroll_x, .y = wheel.scroll_y }, // scroll amount, not a coordinate
                    );
                    app.driver.router.wheel(wpos);
                },
                .finger_down, .finger_up, .finger_motion => |finger| {
                    // Finger coordinates are normalized 0..1; map to the **device-px** viewport
                    // so touch lands in the same space as the layout/hit geometry.
                    const width: f32 = app.resources.view.metrics.px_w;
                    const height: f32 = app.resources.view.metrics.px_h;
                    const id: u64 = @intCast(finger.finger_id.value);
                    const position = ui_client.InputPoint{ .x = finger.x * width, .y = finger.y * height };
                    switch (event) {
                        .finger_down => {
                            input.recordButton(.touch, id, .primary, true, 1, position);
                            routePointerPress(&app, .touch, id, position);
                        },
                        .finger_up => {
                            input.recordButton(.touch, id, .primary, false, 1, position);
                            routePointerRelease(&app, .touch, id, position);
                        },
                        .finger_motion => {
                            input.recordMotion(
                                .touch,
                                id,
                                position,
                                .{ .x = finger.dx * width, .y = finger.dy * height },
                            );
                            routePointerMotion(&app, .touch, id, position);
                        },
                        else => unreachable,
                    }
                },
                .finger_canceled => {
                    input.cancel();
                    cancelPointerGesture(&app);
                },
                .window_focus_gained => input.setWindowFocus(true),
                .window_focus_lost, .did_enter_background => {
                    input.setWindowFocus(false);
                    // Cancels the in-flight gesture AND ends the platform text-input session
                    // through the router's bound SDL platform seam.
                    app.driver.router.windowFocusLost();
                },
                // A render targets/device reset or loss invalidates every uploaded
                // GPU texture (D3D/GPU device-lost). Bump the renderer generation so the
                // text-texture cache misses and *abandons* (never double-frees) the now-dead
                // handles, re-rasterizing under the new generation on the next draw. CPU-side
                // ttf glyph caches (`font.zig`) are unaffected — only the uploaded textures die.
                .render_targets_reset, .render_device_reset, .render_device_lost => {
                    app.resources.platform.bumpGeneration();
                },
                // The window resized. This frame's stamped rects are still the
                // previous size's, so mark geometry stale — pointer activation is suppressed
                // (a click can't land on the ghost of a moved control) until the frame
                // rebuilds and re-stamps at the new size, when the flag is cleared. Any
                // in-flight gesture is cancelled so it can't complete against stale geometry.
                .window_resized, .window_pixel_size_changed => {
                    app.driver.router.geometryChanged();
                },
                else => {},
            }
        }

        // The per-event routing (pointer edges) ran as events arrived, above. The rest of
        // the event stage — visual-state republish, keyboard commands, text, hover — is the
        // frame driver's first phase (`Router.routeFrame` inside `driver.step`), run against
        // the PREVIOUS frame's stamped geometry. The simulation below runs between the two and
        // mutates nothing the step reads.

        // Update Stage
        // 1. update game resources. Host time always advances normally; simulation time alone
        // takes the selected playback multiplier (and later pause's zero multiplier).
        const real_dt = app.frame_capper.delay();
        app.resources.time.real_dt = real_dt;
        app.resources.time.dt = app.resources.playback.simulationDelta(real_dt);
        // A changed `data/` file reloads the roster here, between frames: before the systems
        // read it and before the page build, so nothing holds the records being replaced.
        if (app.data_watch.poll(real_dt)) ha.reload.reload(&app.resources, &app.world);
        // Advance host-layer UI transitions by the frame delta and keep the
        // reduced-motion policy projected onto the registry (so a transition started this
        // frame snaps when reduced motion is on). Presentation only — always runs, even at
        // the Act I curtain, since UI transitions are independent of the sim clock.
        app.resources.tween.setPolicy(app.resources.motion);
        app.resources.tween.advance(real_dt);
        // 2. update game systems — but only while the run is still being played. A housed
        // actor has ended Act I, and the curtain is a still frame: without this the world
        // would keep spoiling and starving behind the dialog, and a win left on screen
        // long enough would turn into a game over. `pages.build_ui` routes on the same fact.
        const player = ecs.MaybeSingle(.{ ha.world.Entity, comp.Goods, ecs.With(tag.Player) }){ .world = &app.world };
        const housed = if (player.get()) |p| ha.capital.ownsMilestone(&app.world, p[0], &app.resources.catalog, .act_one) else false;
        // Skip the simulation stage entirely while paused: passing zero through systems is not
        // sufficient because boundary-state systems (an encounter at remaining=0, completed work,
        // death/reach edge detectors) may still mutate without consuming time.
        if (!housed and app.resources.time.dt > 0) {
            ecs.run(&app.world, &app.resources, sys.advance_clock); // run clock ticks while alive
            ecs.run(&app.world, &app.resources, sys.update_food); // larder spoils
            ecs.run(&app.world, &app.resources, sys.metabolize); // continuous eating / starvation
            ecs.run(&app.world, &app.resources, sys.resolve_busy); // work in progress ticks/completes
            ecs.run(&app.world, &app.resources, sys.track_reach); // newly in-reach recipes → one log
            // Advance the Passerby encounter on the sim clock (arrival/departure logs,
            // finite satchel). Not an ECS system — the encounter is run state on `Sim`, one per
            // run, so it ticks directly rather than over a per-entity query.
            _ = ha.market.tick(&app.resources.sim.encounter, app.resources.time.dt, .{}, app.resources.config.secs_per_day, &app.resources.sim.log);
            ha.capital.run_generators(&app.world, &app.resources); // collectable capital accumulates
            ecs.run(&app.world, &app.resources, sys.mark_dead); // vigor at 0 → tag Dead
            ecs.run(&app.world, &app.resources, sys.despawn_dead); // reap Dead entities
        }

        // UI + Render Stage: the canonical per-frame UI lifecycle, run by the frame driver.
        // The host callbacks wrap page build, the cursor apply, the clear/present around the
        // draw walk, and the five-pass + state sample. Everything else — route, begin, layout,
        // stamp, draw, endFrame, registry/a11y publication — is the driver's fixed sequence.
        var host_ctx = FrameHost{ .app = &app };
        try app.driver.step(host_ctx.host());
    }
}

// ---- Frame driver host: the SDL/game glue around `frame.Driver.step` ------------------
// `build` is the page build over the live world; `apply_cursor` the SDL cursor; `present`
// the themed clear + renderer present around the draw walk; `sample` the development frame
// capture that pairs the five-pass timings with state counts and logs on its window.

const FrameHost = struct {
    app: *App,

    fn host(self: *FrameHost) ui_client.FrameHost {
        return .{
            .user = self,
            .build = buildThunk,
            .apply_cursor = applyCursorThunk,
            .present = .{ .clear = clearThunk, .show = showThunk },
            .sample = sampleThunk,
        };
    }

    fn buildThunk(user: *anyopaque, ui_ctx: *ui_client.UiCtx) anyerror!ui_client.Trees {
        const self: *FrameHost = @ptrCast(@alignCast(user));
        return pages.build_ui(ui_ctx, &self.app.world);
    }

    fn applyCursorThunk(user: *anyopaque, kind: ui_client.CursorKind) void {
        const self: *FrameHost = @ptrCast(@alignCast(user));
        self.app.platform_cursors.apply(kind);
    }

    fn clearThunk(user: *anyopaque) anyerror!void {
        const self: *FrameHost = @ptrCast(@alignCast(user));
        // window — cleared to the theme's own background, not a fixed color
        const bg = self.app.resources.view.theme.bg;
        try self.app.renderer.setDrawColor(.{ .r = bg.r, .g = bg.g, .b = bg.b, .a = 255 });
        try self.app.renderer.clear();
    }

    fn showThunk(user: *anyopaque) anyerror!void {
        const self: *FrameHost = @ptrCast(@alignCast(user));
        try self.app.renderer.present();
    }

    fn sampleThunk(user: *anyopaque, sample: ui_client.FrameProfileSample, ui_ctx: *ui_client.UiCtx, trees: ui_client.Trees) void {
        const self: *FrameHost = @ptrCast(@alignCast(user));
        // Development capture: the five-pass timings paired with per-pool / interaction /
        // node state counts over one shared window. A no-op unless `HA_UI_PROFILE` is set and
        // info logging is compiled in. The timing lines are preserved verbatim through the
        // capture's `Report.log` (it emits the same five-pass avg/max lines plus state lines).
        self.app.ui_capture.record(sample, ui_ctx, trees);
        if (self.app.ui_capture.takeIfReady(600)) |report| report.log();
    }
};

fn spawn_agent(world: *ha.world.World) ha.world.Entity {
    // Spawn from the components' authoritative default baselines (see `baselines.zig`)
    // rather than repeating literals — `Vigor{}` is rested at the ceiling, `InventoryFood{}` is
    // the thin perishable larder, `Metabolism{}` eats continuously at the normal rate — so the
    // starting state has exactly one source and Holdings can derive current-vs-base against it.
    return world.spawn(.{
        comp.Vigor{}, // rested at the ceiling (10/10)
        comp.InventoryFood{}, // a thin, perishable larder (4 units, quality 1, spoils 0.05)
        comp.InventoryBiomass{ .v = 0 }, // nothing stockpiled yet
        comp.Metabolism{}, // eats continuously from the first breath (normal rate)
        comp.Goods{}, // owns nothing yet; what it can do is derived from this and the roster
        comp.Generators{}, // collectable capital accumulates independently of the body's work
        comp.Granted{}, // and the goods contribute nothing to the body or larder yet
    });
}

pub fn spawn_player(world: *ha.world.World) ha.world.Entity {
    const e = spawn_agent(world);
    world.add(e, tag.Player{});
    return e;
}

/// The opening line every run begins with.
pub const opening_line = "You wake alone. Cold. Hungry.";

/// Begin a fresh run: retire any living player (a settled actor is still alive at the Act I
/// curtain, so spawning over them would leave two), spawn a new one, clear the run state
/// (clock, log, teaching flag), unpause, and log the opening line. Speed survives a new run.
pub fn start_over(world: *ha.world.World, res: *ha.res.Resources) void {
    const living = ecs.MaybeSingle(.{ ha.world.Entity, comp.Vigor, ecs.With(tag.Player) }){ .world = world };
    if (living.get()) |entry| world.despawn(entry[0]);
    res.playback.paused = false;
    _ = spawn_player(world);
    res.sim.reset();
    res.sim.log.push(.dim, opening_line);
}

// The pages are game content outside the `ha` library; the executable module is their test
// root, so this block is what pulls their test declarations into `zig build test`.
test {
    _ = pages;
}
