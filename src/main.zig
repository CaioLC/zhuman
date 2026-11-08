const std = @import("std");

const ha = @import("ha");

const ui_client = ha.ui_client;
const sdl = ha.sdl;
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
/// (window coordinates × pixel density), while SDL delivers mouse/finger coordinates in window
/// coordinates, so every coordinate is multiplied by the frame's `pointer_scale` at this one
/// seam before it reaches the input model or hit-testing. A UI scale changes the logical space,
/// not this factor. At DPI 1 this is identity.
fn pointerAt(app: *App, x: f32, y: f32) ui_client.InputPoint {
    const s = app.resources.view.metrics.pointer_scale;
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
    /// The process's I/O, allocator and environment, from `main`'s `std.process.Init`, which
    /// owns them for the life of the program.
    io: std.Io,
    gpa: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    window: sdl.video.Window,
    renderer: sdl.render.Renderer,
    frame_capper: sdl.extras.FramerateCapper(f32),
    font: ha.font.Fonts,
    resources: Resources,
    world: ha.sim.ecs.World,
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
    /// The once-only trigger for the development layout dump (`HA_LAYOUT_DUMP`).
    layout_dump: ui_client.layout_dump.Trigger = .{},
    /// The `assets/roster/` files' modification times; a change reloads the roster between
    /// frames.
    roster_watch: ha.sim.data.reload.Watch = .{},

    fn init(process: std.process.Init) !App {
        try sdl.init(.{ .video = true, .events = true });
        try sdl.ttf.init();
        // Sized to the BUILD panel, the tallest screen: five shelves of tiles, wide enough
        // from the manufactured tier's three-digit prices that they wrap two to a row.
        // Resizable; the columns do not reflow (docs/roadmap.md, Act I).
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
            .io = process.io,
            .gpa = process.gpa,
            .environ = process.environ_map,
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

    fn setup(self: *App) !void {
        const allocator = self.gpa;
        self.font = try ha.font.Fonts.init(allocator, font_path, ui_client.style.default_font);
        self.resources = try Resources.init(allocator, self.io, self.environ, &self.font, &self.renderer, self.window);
        // Resolve the reduced-motion policy ONCE here: an explicit
        // `HA_REDUCED_MOTION` override wins, else the platform probe (Windows
        // `SPI_GETCLIENTAREAANIMATION`; deterministic `false` elsewhere), else a `false`
        // fallback. No per-frame OS call — `build_ui` only projects this onto
        // `view.reduced_motion` each frame.
        self.resources.motion = ui_client.resolveMotionFromEnv(self.environ, ui_client.PlatformMotionProbe.instance());
        // The world is empty until a `NewRun` (the title's New game) or a load begins a run.
        self.world = try ha.sim.ecs.World.init(allocator);
        self.openSaves();

        self.frame_arena = std.heap.ArenaAllocator.init(allocator);
        self.ui = ui_client.UiCtx.init(&self.resources, allocator, self.frame_arena.allocator());
        // Bind the frame driver to this app's now-stable `ui`/`frame_arena`, with SDL bound to
        // the one routing policy's platform seam (clipboard + text-input stop). The SDL loop
        // routes each pointer event through `driver.router` as it arrives, and runs the rest of
        // the per-frame lifecycle through `driver.step` (via host callbacks below).
        self.driver = ui_client.FrameDriver.init(&self.ui, &self.frame_arena, self.io, sdlPlatform(&self.window));
    }

    /// Open the saves folder, SDL's per-user preference path for the game, and read its slots.
    /// A failure leaves `saves.dir` null and says why; the game runs without saving.
    fn openSaves(self: *App) void {
        const path = sdl.filesystem.getPrefPath("", "human_action") catch |err| {
            std.log.warn("saving is unavailable: no preference path ({s})", .{@errorName(err)});
            return;
        };
        defer sdl.free(path);
        const dir = std.Io.Dir.openDirAbsolute(self.io, path, .{}) catch |err| {
            std.log.warn("saving is unavailable: {s} did not open ({s})", .{ path, @errorName(err) });
            return;
        };
        self.resources.saves.dir = dir;
        self.resources.saves.refresh(self.io, self.gpa, &self.resources.game.config);
    }

    fn deinit(self: *App) void {
        if (self.resources.saves.dir) |d| d.close(self.io);
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
    }
};

pub fn main(process: std.process.Init) !void {
    var app = try App.init(process);
    defer app.deinit();
    try app.setup();

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
        // 1. this frame's timesteps. Host time always advances; simulation time takes the
        // playback multiplier, zero while paused (the menu, the curtain, the stepper).
        const real_dt = app.frame_capper.delay();
        app.resources.game.time.real_dt = real_dt;
        app.resources.game.time.dt = app.resources.playback.simulationDelta(real_dt);
        // 2. a changed `assets/roster/` file reloads the roster here, between frames: before the
        // systems read it and before the page build, so nothing holds the records being replaced.
        if (app.roster_watch.poll(app.io, real_dt)) ha.sim.data.reload.reload(app.io, &app.resources.game, &app.world);
        // A save or a load the menu or the title asked for, here for the same reason: a load
        // replaces the world before the tick refills its derived components and the build reads it.
        applySaveRequest(&app.resources, &app.world, app.io, app.gpa);
        // Host-layer UI transitions advance by real time and follow the reduced-motion policy
        // (a transition started this frame snaps when reduced motion is on). Presentation only.
        app.resources.tween.setPolicy(app.resources.motion);
        app.resources.tween.advance(real_dt);
        // 3. the simulation: the schedule's one tick (`sim/schedule.zig`). It opens the frame's
        // events, applies a pending transition, runs the state's handlers, and its update set
        // while simulation time passes, so the intents the last build wrote are in the world
        // this frame's build reads.
        ha.sim.schedule.tick(&app.world, &app.resources.game);
        // The fixture harness seeds the world here, after the tick and before the build, so a
        // tick cannot move the seeded numbers before they render (`pages.prepare`).
        pages.prepare(&app.ui, &app.world);

        // UI + Render Stage: the canonical per-frame UI lifecycle, run by the frame driver.
        // The host callbacks wrap page build, the cursor apply, the clear/present around the
        // draw walk, and the five-pass + state sample. Everything else — route, begin, layout,
        // stamp, draw, endFrame, registry/a11y publication — is the driver's fixed sequence.
        var host_ctx = FrameHost{ .app = &app };
        try app.driver.step(host_ctx.host());
    }
}

// ---- Saves ------------------------------------------------------------------------------

/// Apply the save or load `saves.request` holds, between frames and before the tick
/// (`sim/data/save.zig`). A save is refused unless the run is in an act with no transition
/// pending and the curtain is closed; it leaves its outcome as the menu's flash and rereads the
/// slots. A load replaces the world, `Sim` and the state, routes to the game with the menu and
/// the curtain closed and the simulation paused, forgets the log lines already announced (the
/// log's count came back from the file), and logs that it loaded.
fn applySaveRequest(res: *Resources, world: *ha.sim.ecs.World, io: std.Io, gpa: std.mem.Allocator) void {
    const save = ha.sim.data.save;
    const request = res.saves.request orelse return;
    res.saves.request = null;
    var buf: [64]u8 = undefined;
    switch (request) {
        .save => |i| {
            const dir = res.saves.dir orelse return res.menu.setFlash("Cannot save now.");
            if (i >= ha.res.SaveSlots.count or !save.canSave(&res.game) or res.curtain.open) return res.menu.setFlash("Cannot save now.");
            save.write(io, dir, ha.res.SaveSlots.fileName(i), gpa, &res.game, world) catch |err| {
                std.log.err("save to slot {d} failed: {s}", .{ i + 1, @errorName(err) });
                return res.menu.setFlash("Could not save.");
            };
            res.menu.setFlash(std.mem.print(&buf, "Saved to slot {d}.", .{i + 1}) catch "Saved.");
            res.saves.refresh(io, gpa, &res.game.config);
        },
        .load => |i| {
            const dir = res.saves.dir orelse return;
            if (i >= ha.res.SaveSlots.count) return;
            var loaded = save.read(io, dir, ha.res.SaveSlots.fileName(i), gpa) catch |err| {
                std.log.err("load from slot {d} failed: {s}", .{ i + 1, @errorName(err) });
                return res.menu.setFlash(std.mem.print(&buf, "Could not load slot {d}.", .{i + 1}) catch "Could not load.");
            };
            defer loaded.deinit();
            const report = save.apply(&res.game, world, &loaded.save);
            // Nothing written before the load is readable after it: an intent from the frame
            // before would name an entity of the run that is gone. Opening the store twice
            // expires every event; a reader's cursor stays valid by the store's own rule.
            res.game.events.update();
            res.game.events.update();
            res.route = .game;
            res.title = .{};
            res.menu.open = false;
            res.menu.screen = .menu;
            res.menu.flash_len = 0;
            res.curtain = .{ .heard = res.curtain.heard };
            res.playback.paused = true;
            res.log_heard = null;
            const log = &res.game.sim.log;
            log.push(.normal, std.mem.print(&buf, "Loaded slot {d}.", .{i + 1}) catch "Loaded.");
            if (report.dropped == 1) log.push(.warn, "1 record in the save is gone from the roster.");
            if (report.dropped > 1) log.push(.warn, std.mem.print(&buf, "{d} records in the save are gone from the roster.", .{report.dropped}) catch "Records in the save are gone from the roster.");
        },
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
        // info logging is compiled in. `Report.log` emits the five-pass avg/max lines plus
        // the state lines.
        self.app.ui_capture.record(sample, ui_ctx, trees);
        if (self.app.ui_capture.takeIfReady(600)) |report| report.log();
        // Development node/layout dump (`HA_LAYOUT_DUMP=<path>`): once, on the configured frame.
        const dump = ui_client.layout_dump;
        if (self.app.resources.env(dump.env_path)) |path| {
            if (path.len > 0 and self.app.layout_dump.fire(dump.frameFrom(self.app.resources.env(dump.env_frame)))) {
                if (dump.writeFile(ui_ctx, trees, self.app.io, path)) {
                    std.log.info("layout dump written to {s}", .{path});
                } else |err| std.log.warn("layout dump to {s} failed: {s}", .{ path, @errorName(err) });
            }
        }
    }
};

// The pages are game content outside the `ha` library; the executable module is their test
// root, so this block is what pulls their test declarations into `zig build test`.
test {
    _ = pages;
}

test "a save request writes the slot's file, and a load request restores it and routes to the game paused" {
    const testing = std.testing;
    var res = ui_client.replay.headlessResources();
    res.game.catalog = try ha.sim.data.roster.load(testing.allocator, ha.sim.data.roster.shipped, null);
    defer res.game.catalog.deinit();
    var world = try ha.sim.ecs.World.init(testing.allocator);
    defer world.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    res.saves.dir = tmp.dir;

    const e = ha.sim.systems.run.spawn_player(&world, &res.game.catalog);
    world.get(e, ha.sim.comp.Vigor).?.v = 6.5;
    res.game.states = .{ .current = .act_one };
    res.game.sim.elapsed = 45;
    res.menu.show(&res.playback);
    res.saves.request = .{ .save = 0 };
    applySaveRequest(&res, &world, testing.io, testing.allocator);
    try testing.expectEqual(@as(?ha.res.SaveSlots.Request, null), res.saves.request);
    try tmp.dir.access(testing.io, "slot1.zon", .{});
    try testing.expectEqualStrings("Saved to slot 1.", res.menu.flash().?);
    try testing.expect(res.saves.slots[0].filled);
    try testing.expectEqual(@as(u32, 3), res.saves.slots[0].day);
    try testing.expectEqual(@as(?usize, 0), res.saves.latest());

    // A pending transition refuses the save.
    res.game.states.set(.act_two);
    res.saves.request = .{ .save = 1 };
    applySaveRequest(&res, &world, testing.io, testing.allocator);
    try testing.expectEqualStrings("Cannot save now.", res.menu.flash().?);
    try testing.expect(!res.saves.slots[1].filled);

    // The run moves on; the load puts it back, from the title.
    world.get(e, ha.sim.comp.Vigor).?.v = 1;
    res.game.states = .{ .current = .game_over };
    res.route = .title;
    res.menu.open = false;
    res.playback.paused = false;
    res.log_heard = 7;
    _ = res.game.events.writer(ha.sim.events.BeginLabor).push(.{ .agent = e, .ai = 0 }); // from the run that is gone
    res.saves.request = .{ .load = 0 };
    applySaveRequest(&res, &world, testing.io, testing.allocator);
    try testing.expectEqual(@as(usize, 0), res.game.events.len(ha.sim.events.BeginLabor));
    try testing.expectEqual(ha.sim.GameState.act_one, res.game.states.current);
    try testing.expectEqual(@as(f32, 6.5), world.get(0, ha.sim.comp.Vigor).?.v);
    try testing.expectEqual(ha.res.Route.game, res.route);
    try testing.expect(res.playback.paused);
    try testing.expect(!res.menu.open);
    try testing.expectEqual(@as(?u64, null), res.log_heard);
    try testing.expectEqualStrings("Loaded slot 1.", res.game.sim.log.get(0).text());
}
