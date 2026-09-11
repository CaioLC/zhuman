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
/// layout space (VIEW-02): the layout, hit geometry, and drag math live in device pixels
/// (logical × DPI), while SDL delivers mouse/finger coordinates in window coordinates, so every
/// coordinate is multiplied by the frame's `dpi_scale` at this one seam before it reaches the
/// input model or hit-testing. At DPI 1 this is identity (today's behavior).
fn pointerAt(app: *App, x: f32, y: f32) ui_client.InputPoint {
    const s = app.resources.view.metrics.dpi_scale;
    const k = if (s > 0) s else 1;
    return .{ .x = x * k, .y = y * k };
}

fn routePointerPress(app: *App, kind: ui_client.PointerKind, id: ?u64, position: ui_client.InputPoint) void {
    // VIEW-05: right after a resize the stamped rects are the previous size's, so do not
    // begin an activation against them — a press this frame would target stale geometry.
    if (app.geometry_stale) return;
    const target = app.ui.markTarget(.pressed, position.x, position.y);
    app.pointer_activation.press(target, kind, id, position);
}

fn routePointerMotion(app: *App, kind: ui_client.PointerKind, id: ?u64, position: ui_client.InputPoint) void {
    app.pointer_activation.motion(kind, id, position);
    if (app.pointer_activation.draggingKey()) |key| {
        _ = app.ui.markKey(key, .dragging);
    }
}

fn routePointerRelease(app: *App, kind: ui_client.PointerKind, id: ?u64, position: ui_client.InputPoint) void {
    // VIEW-05: while geometry is stale from a resize, cancel any in-flight gesture rather than
    // routing a release/click to the previous frame's rects (the one-frame clickable ghost).
    if (app.geometry_stale) {
        cancelPointerGesture(app);
        return;
    }
    routePointerMotion(app, kind, id, position);
    _ = app.ui.markTarget(.released, position.x, position.y);
    const target = app.ui.targetAt(position.x, position.y);
    if (app.pointer_activation.release(target, kind, id, position)) |key| {
        _ = app.ui.markKey(key, .clicked);
    }
}

fn cancelPointerGesture(app: *App) void {
    app.pointer_activation.cancel();
    app.ui.cancelPointerCapture();
}

fn publishPointerVisualState(app: *App, input: *const ui_client.Input) void {
    if (input.pointer.buttons.primary.held) {
        if (app.pointer_activation.pressedKey()) |key| {
            _ = app.ui.markKey(key, .held);
        }
    }
    if (app.pointer_activation.draggingKey()) |key| {
        _ = app.ui.markKey(key, .dragging);
    }
    if (app.ui.capturedPointerKey()) |key| {
        app.ui.setFlag(key, .captured, true);
    }
}

// END CONFIGS

const CommandRoute = struct {
    handled: bool = false,
    suppress_text: bool = false,
};

/// The authoritative editor model for the currently focused text owner, or null when the
/// focused control is not a registered text field. `main` only *routes* into this model;
/// all editing rules live in `ui_client/editor.zig` (INPUT-07).
fn focusedEditor(app: *App) ?*ui_client.UiState.TextInputState {
    const key = app.ui.focusedKey() orelse return null;
    if (!app.resources.commands.isTextOwner(key)) return null;
    const idx = app.ui.cache(key, ui_client.UiState.TextInputState);
    return app.ui.pool(ui_client.UiState.TextInputState).get(idx);
}

/// Copy the current selection to the SDL clipboard when both a selection and clipboard
/// support exist. Returns whether the platform accepted the text. The editor slice is
/// only valid until the next mutation, so it is NUL-terminated into a stack buffer first.
fn copySelectionToClipboard(ed: *ui_client.UiState.TextInputState) bool {
    if (!ed.hasSelection()) return false;
    const sel = ed.selectionSlice();
    var tmp: [ui_client.UiState.TextInputState.max_query_bytes + 1]u8 = undefined;
    if (sel.len > tmp.len - 1) return false;
    @memcpy(tmp[0..sel.len], sel);
    tmp[sel.len] = 0;
    sdl.clipboard.setText(tmp[0..sel.len :0]) catch return false;
    return true;
}

fn routeCommand(app: *App, command: ui_client.Command) CommandRoute {
    switch (command) {
        .focus_next => return .{ .handled = app.ui.moveFocus(.next, true) },
        .focus_previous => return .{ .handled = app.ui.moveFocus(.previous, true) },
        .move_left, .move_up => {
            const moved = app.ui.moveFocusedRoving(.previous, true);
            if (moved) {
                if (app.ui.focusedKey()) |key| _ = app.ui.markKey(key, .clicked);
            }
            return .{ .handled = moved };
        },
        .move_right, .move_down => {
            const moved = app.ui.moveFocusedRoving(.next, true);
            if (moved) {
                if (app.ui.focusedKey()) |key| _ = app.ui.markKey(key, .clicked);
            }
            return .{ .handled = moved };
        },
        .activate => {
            const key = app.ui.focusedKey() orelse return .{};
            return .{ .handled = app.ui.markKey(key, .clicked) };
        },
        .dismiss => {
            if (app.ui.focusedKey()) |key| {
                if (app.resources.commands.isTextOwner(key)) {
                    app.ui.clearFocus();
                    sdl.keyboard.stopTextInput(app.window) catch {};
                    return .{ .handled = true };
                }
            }
            const target = app.resources.commands.escapeTarget() orelse return .{};
            return .{ .handled = app.ui.markKey(target, .dismissed) };
        },
        .focus_search => {
            const target = app.resources.commands.searchTarget() orelse return .{};
            const handled = app.ui.requestFocus(target);
            return .{ .handled = handled, .suppress_text = handled };
        },
        .delete_backward => {
            const ed = focusedEditor(app) orelse return .{};
            _ = ed.deleteBackward();
            return .{ .handled = true };
        },
        .delete_forward => {
            const ed = focusedEditor(app) orelse return .{};
            _ = ed.deleteForward();
            return .{ .handled = true };
        },
        .line_start => {
            const ed = focusedEditor(app) orelse return .{};
            ed.home(false);
            return .{ .handled = true };
        },
        .line_end => {
            const ed = focusedEditor(app) orelse return .{};
            ed.end(false);
            return .{ .handled = true };
        },
        .select_left => {
            const ed = focusedEditor(app) orelse return .{};
            ed.moveLeft(true);
            return .{ .handled = true };
        },
        .select_right => {
            const ed = focusedEditor(app) orelse return .{};
            ed.moveRight(true);
            return .{ .handled = true };
        },
        .select_line_start => {
            const ed = focusedEditor(app) orelse return .{};
            ed.home(true);
            return .{ .handled = true };
        },
        .select_line_end => {
            const ed = focusedEditor(app) orelse return .{};
            ed.end(true);
            return .{ .handled = true };
        },
        .select_all => {
            const ed = focusedEditor(app) orelse return .{};
            ed.selectAll();
            return .{ .handled = true, .suppress_text = true };
        },
        .clipboard_copy => {
            const ed = focusedEditor(app) orelse return .{};
            _ = copySelectionToClipboard(ed);
            // Handled by the focused editor regardless: Ctrl+C must never fall through to
            // typing a 'c', even when there is nothing selected to copy.
            return .{ .handled = true, .suppress_text = true };
        },
        .clipboard_cut => {
            const ed = focusedEditor(app) orelse return .{};
            if (copySelectionToClipboard(ed)) _ = ed.deleteBackward(); // delete-selection
            return .{ .handled = true, .suppress_text = true };
        },
        .clipboard_paste => {
            const ed = focusedEditor(app) orelse return .{};
            if (sdl.clipboard.hasText()) {
                if (sdl.clipboard.getText()) |clip| {
                    defer sdl.free(clip);
                    // The editor validates and refuses non-single-line / oversized text
                    // as a whole; refusal is surfaced by its `refused` flag in the widget.
                    _ = ed.insert(clip);
                } else |_| {}
            }
            return .{ .handled = true, .suppress_text = true };
        },
        .clear_field => {
            const ed = focusedEditor(app) orelse return .{};
            _ = ed.clear();
            return .{ .handled = true, .suppress_text = true };
        },
    }
}

fn routeKeyboardCommands(app: *App, input: *const ui_client.Input) bool {
    var suppress_text = false;
    for (input.keyEvents()) |event| {
        const command = ui_client.commandFromKeyEvent(event) orelse continue;
        const routed = routeCommand(app, command);
        suppress_text = suppress_text or routed.suppress_text;
    }
    return suppress_text;
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
    pointer_activation: ui_client.PointerActivation = .{},
    platform_cursors: ui_client.PlatformCursors,
    ui_profiler: ui_client.FrameProfiler = .{},
    /// VIEW-05: set when the window resizes, cleared after the frame re-stamps geometry.
    /// While set, pointer activation is suppressed so a click cannot land on the previous
    /// frame's now-stale stamped rects (the "one-frame clickable ghost").
    geometry_stale: bool = false,

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
        // RENDER-01: configure the draw blend mode explicitly. SDL defaults to `.none`
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
        self.resources = try Resources.init(&self.font, &self.renderer, self.window);
        // Resolve the reduced-motion policy ONCE here (INPUT-10): an explicit
        // `HA_REDUCED_MOTION` override wins, else the platform probe (Windows
        // `SPI_GETCLIENTAREAANIMATION`; deterministic `false` elsewhere), else a `false`
        // fallback. No per-frame OS call — `build_ui` only projects this onto
        // `view.reduced_motion` each frame.
        self.resources.motion = ui_client.resolveMotionFromEnv(allocator, ui_client.PlatformMotionProbe.instance());
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

    var quit = false;

    while (!quit) {
        // Event Stage
        const input = &app.resources.input;
        input.beginFrame();
        while (sdl.events.poll()) |event| {
            switch (event) {
                .quit, .terminating => quit = true,
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
                    app.ui.mark(.wheel, wpos.x, wpos.y);
                },
                .finger_down, .finger_up, .finger_motion => |finger| {
                    // Finger coordinates are normalized 0..1; map to the **device-px** viewport
                    // (VIEW-02) so touch lands in the same space as the layout/hit geometry.
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
                    cancelPointerGesture(&app);
                    sdl.keyboard.stopTextInput(app.window) catch {};
                },
                // TEXT-05: a render targets/device reset or loss invalidates every uploaded
                // GPU texture (D3D/GPU device-lost). Bump the renderer generation so the
                // text-texture cache misses and *abandons* (never double-frees) the now-dead
                // handles, re-rasterizing under the new generation on the next draw. CPU-side
                // ttf glyph caches (`font.zig`) are unaffected — only the uploaded textures die.
                .render_targets_reset, .render_device_reset, .render_device_lost => {
                    app.resources.platform.bumpGeneration();
                },
                // VIEW-05: the window resized. This frame's stamped rects are still the
                // previous size's, so mark geometry stale — pointer activation is suppressed
                // (a click can't land on the ghost of a moved control) until the frame
                // rebuilds and re-stamps at the new size, when the flag is cleared. Any
                // in-flight gesture is cancelled so it can't complete against stale geometry.
                .window_resized, .window_pixel_size_changed => {
                    app.geometry_stale = true;
                    cancelPointerGesture(&app);
                },
                else => {},
            }
        }

        publishPointerVisualState(&app, input);

        const suppress_text = routeKeyboardCommands(&app, input);
        if (!suppress_text) if (focusedEditor(&app)) |ed| {
            const text = input.text();
            if (text.len > 0) {
                // The editor enforces UTF-8 / single-line admissibility and the explicit
                // max query length, refusing oversized or incompatible text as a whole and
                // raising its non-silent `refused` flag for the widget to surface.
                _ = ed.insert(text);
            }
        };

        // Update Stage
        // 1. update game resources
        app.resources.time.dt = app.frame_capper.delay();
        // RENDER-08: advance host-layer UI transitions by the frame delta and keep the
        // reduced-motion policy projected onto the registry (so a transition started this
        // frame snaps when reduced motion is on). Presentation only — always runs, even at
        // the Act I curtain, since UI transitions are independent of the sim clock.
        app.resources.tween.setPolicy(app.resources.motion);
        app.resources.tween.advance(app.resources.time.dt);
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
            ecs.run(&app.world, &app.resources, sys.track_reach); // ACT1-06: newly in-reach recipes → one log
            // ACT1-12: advance the Passerby encounter on the sim clock (arrival/departure logs,
            // finite satchel). Not an ECS system — the encounter is run state on `Sim`, one per
            // run, so it ticks directly rather than over a per-entity query.
            _ = ha.market.tick(&app.resources.sim.encounter, app.resources.time.dt, .{}, app.resources.config.secs_per_day, &app.resources.sim.log);
            ha.capital.run_generators(&app.world, &app.resources); // capital that runs itself
            ecs.run(&app.world, &app.resources, sys.mark_dead); // vigor at 0 → tag Dead
            ecs.run(&app.world, &app.resources, sys.despawn_dead); // reap Dead entities
        }
        // 3. update ui
        app.ui.mark(.hovering, input.pointer.position.x, input.pointer.position.y);
        app.ui.beginFrame();
        app.resources.cursor.beginFrame();
        app.resources.commands.beginBuild();
        app.resources.semantics.beginBuild(); // INPUT-08: rebuild the semantic tree in paint order
        _ = app.frame_arena.reset(.retain_capacity); // last frame's node tree dies here
        const frame = try pages.build_ui(&app.ui, &app.world);
        app.platform_cursors.apply(app.resources.cursor.requested);
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
        // VIEW-05: geometry has now been re-stamped at the current window size, so the next
        // event stage can safely route pointer activation again — clear the resize guard.
        app.geometry_stale = false;

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
        app.resources.commands.endBuild();
        app.resources.semantics.endBuild(); // INPUT-08: publish this frame's snapshot for the bridge
        // INPUT-09: the accessibility bridge consumes the just-published snapshot and drains
        // the announcement channel to the active provider (a no-op sink on this build — no
        // Windows UIA tree; see a11y.zig). Host-side only; the sim never sees it.
        app.resources.a11y.poll(
            app.resources.semantics.snapshot(),
            app.resources.semantics.snapshotOverflow(),
            app.resources.semantics.snapshotFieldRefused(),
            &app.resources.announcements,
        );
    }
}

fn spawn_agent(world: *ha.world.World) ha.world.Entity {
    // ACT1-01: spawn from the components' authoritative default baselines (see `baselines.zig`)
    // rather than repeating literals — `Vigor{}` is rested at the ceiling, `InventoryFood{}` is
    // the thin perishable larder, `Metabolism{}` eats continuously at the normal rate — so the
    // starting state has exactly one source and Holdings can derive current-vs-base against it.
    return world.spawn(.{
        comp.Vigor{}, // rested at the ceiling (10/10)
        comp.InventoryFood{}, // a thin, perishable larder (4 units, quality 1, spoils 0.05)
        comp.InventoryMaterial{ .v = 0 }, // nothing stockpiled yet
        comp.Metabolism{}, // eats continuously from the first breath (normal rate)
    } ++ actions.actions_bundle);
}

pub fn spawn_player(world: *ha.world.World) ha.world.Entity {
    const e = spawn_agent(world);
    world.add(e, tag.Player{});
    return e;
}
