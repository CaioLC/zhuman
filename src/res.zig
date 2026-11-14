const std = @import("std");
const sdl = @import("sdl3");
const rostermod = @import("./sim/data/roster.zig");
const savemod = @import("./sim/data/save.zig");
const simres = @import("./sim/res.zig");
const thememod = @import("./ui_client/theme.zig");
const fontmod = @import("./font.zig");

/// Host handles, set once in `Resources.init` and never written again. Read only by
/// the UI — no sim system touches one.
pub const Platform = struct {
    /// The multi-size monospace text backend (see `font.zig`) — measure/render at any
    /// point size, one cached `ttf.Font` per size. Held by pointer, owned by `App`.
    font: *fontmod.Fonts,
    renderer: *const sdl.render.Renderer,
    window: sdl.video.Window,
    tex: sdl.render.Texture,
    /// Sprite sheet of capital-good icons (`assets/icons.png`, a 2×2 grid). Cached once
    /// here; the UI samples cells from it by source rect (see the `img` feature's
    /// `attach_sprite`, re-exported as `ui_client.data_sprite`).
    icons: sdl.render.Texture,
    /// **Renderer generation**. A monotonic counter bumped every time the SDL
    /// renderer's device/targets are (re)set — the host loop advances it on an
    /// `SDL_EVENT_RENDER_TARGETS_RESET` / `RENDER_DEVICE_RESET` / `RENDER_DEVICE_LOST`
    /// event (`bumpGeneration`). It is folded into the text-texture cache key so a texture
    /// uploaded under an older generation is never blitted after a reset invalidates it;
    /// and it lets a cached slot distinguish an ordinary invalidation (renderer alive —
    /// free the old texture) from a post-reset one (underlying GPU texture already dead —
    /// abandon the handle, do **not** double-free). Starts at `0`; the first upload keys on
    /// it. Read-only outside the host loop's reset handler and `Resources.init`.
    generation: u32 = 0,

    /// Advance the renderer generation. Called by the host loop when SDL reports
    /// a render targets/device reset or loss: every GPU texture uploaded under the prior
    /// generation is now invalid, so bumping this makes the text cache miss (and abandon,
    /// not free, the dead handles) and re-rasterize under the new generation. Saturates
    /// rather than wraps so an absurdly long-lived process can never alias an old value.
    pub fn bumpGeneration(self: *Platform) void {
        self.generation +|= 1;
    }
};

/// Persistent host playback controls. They are not run state, so starting a fresh game keeps
/// the player's selected speed. Only the 1×/2×/3× values are accepted.
pub const Playback = struct {
    speed: u8 = 1,
    paused: bool = false,

    pub fn setSpeed(self: *Playback, speed: u8) void {
        self.speed = switch (speed) {
            1, 2, 3 => speed,
            else => 1,
        };
    }

    /// The header stepper's linear scale: pause, then 1×, 2×, 3×.
    pub const max_level: u8 = 3;

    /// Current stepper position: 0 while paused, otherwise the speed.
    pub fn level(self: Playback) u8 {
        return if (self.paused) 0 else self.speed;
    }

    /// Move to a stepper position, clamped to pause..3×. Pausing leaves `speed` as it was;
    /// stepping up out of pause lands on 1×.
    pub fn setLevel(self: *Playback, l: u8) void {
        const clamped = @min(l, max_level);
        if (clamped == 0) {
            self.paused = true;
        } else {
            self.paused = false;
            self.setSpeed(clamped);
        }
    }

    /// Step the stepper one position slower (`-1`) or faster (`+1`), clamped at the ends.
    pub fn step(self: *Playback, delta: i8) void {
        const next = @as(i16, self.level()) + delta;
        self.setLevel(@intCast(std.math.clamp(next, 0, max_level)));
    }

    pub fn multiplier(self: Playback) f32 {
        return if (self.paused) 0 else @floatFromInt(self.speed);
    }

    pub fn simulationDelta(self: Playback, real_dt: f32) f32 {
        return real_dt * self.multiplier();
    }
};

/// Session-local menu lifecycle and host quit request. Opening the menu pauses simulation and
/// remembers whether it was already paused; dismissing restores that prior state, while RESUME
/// explicitly unpauses. `screen` is the menu's sub-screen, `overwrite_slot` the filled slot the
/// overwrite screen asks about, and `flash` the one-shot note a save or load leaves on the menu
/// screen; all three reset on every open.
pub const MenuState = struct {
    open: bool = false,
    restore_paused: bool = false,
    quit_requested: bool = false,
    screen: MenuScreen = .menu,
    overwrite_slot: ?u8 = null,
    flash_buf: [40]u8 = @splat(0),
    flash_len: u8 = 0,

    pub fn show(self: *MenuState, playback: *Playback) void {
        if (self.open) return;
        self.restore_paused = playback.paused;
        self.open = true;
        self.screen = .menu;
        self.overwrite_slot = null;
        self.flash_len = 0;
        playback.paused = true;
    }

    pub fn dismiss(self: *MenuState, playback: *Playback) void {
        self.open = false;
        playback.paused = self.restore_paused;
    }

    pub fn resumeGame(self: *MenuState, playback: *Playback) void {
        self.open = false;
        playback.paused = false;
        self.restore_paused = false;
    }

    /// The one-shot note, if a save or load left one.
    pub fn flash(self: *const MenuState) ?[]const u8 {
        return if (self.flash_len == 0) null else self.flash_buf[0..self.flash_len];
    }

    /// Leave a one-shot note for the menu screen (cut to the buffer).
    pub fn setFlash(self: *MenuState, text: []const u8) void {
        const n = @min(text.len, self.flash_buf.len);
        @memcpy(self.flash_buf[0..n], text[0..n]);
        self.flash_len = @intCast(n);
    }
};

/// The Act I curtain, the UI's response to `ActEnded`. The page build hears the fact with its
/// own cursor (`heard`) and opens it; opening pauses the simulation and remembers whether it
/// was already paused, so the world, which has already crossed into the next act, holds still
/// while the player reads. `step` is the beat on screen. Dismissing (the last beat's Continue)
/// restores the prior pause state, and the next frame routes to the live act.
pub const CurtainState = struct {
    open: bool = false,
    restore_paused: bool = false,
    /// The `ActEnded` cursor: past the last fact the build heard.
    heard: u64 = 0,

    /// Open and pause, remembering the prior pause state. True when this call opened it;
    /// open already is a no-op.
    pub fn show(self: *CurtainState, playback: *Playback) bool {
        if (self.open) return false;
        self.restore_paused = playback.paused;
        self.open = true;
        playback.paused = true;
        return true;
    }

    /// Close and restore the pause state `show` remembered.
    pub fn dismiss(self: *CurtainState, playback: *Playback) void {
        self.open = false;
        playback.paused = self.restore_paused;
    }
};

/// The session menu's screens (`menu.html`). `overwrite` confirms a save over a filled slot.
pub const MenuScreen = enum { menu, save, load, settings, quit, overwrite };

/// Which top-level screen the host shows: the title screen before a run, the arrival scene
/// between New game and the run, the game, or the thank-you the demo ends on.
pub const Route = enum { title, arrival, game, thanks };

/// Where a fade leads: the screen change that happens in the dark.
pub const Transition = enum {
    /// The title's New game: to the arrival scene.
    arrival,
    /// The arrival's Begin: the run begins.
    run,
    /// The Act I curtain's Continue: into Act II.
    act_two,
    /// The Act I curtain's Continue in the demo: to the thank-you.
    thanks,
    /// The thank-you's Title: back to the title screen.
    title,
};

/// The fade between a scene and what comes next. The screen darkens (`out`), the change it
/// was leading to happens while it is dark, and the new screen comes up out of it (`in`).
/// `level` is the depth, 0 clear to 1 dark. Real time, not simulation time: it runs while
/// the world is paused.
pub const FadeState = struct {
    pub const Dir = enum { idle, out, in };
    /// Seconds to darken, to clear, and to clear after the curtain's cut to dark.
    pub const out_s: f32 = 0.4;
    pub const in_s: f32 = 0.7;
    pub const curtain_in_s: f32 = 1.2;

    level: f32 = 0,
    dir: Dir = .idle,
    /// Seconds the current `in` takes.
    clear_s: f32 = in_s,
    pending: ?Transition = null,

    /// Darken toward `next`. A fade already leading somewhere keeps its destination, so a
    /// second click changes nothing; one that was clearing turns around from where it is.
    pub fn to(self: *FadeState, next: Transition) void {
        if (self.pending != null) return;
        self.pending = next;
        self.dir = .out;
    }

    /// Cut to dark and clear over `seconds`: for a change that has already happened.
    pub fn dip(self: *FadeState, seconds: f32) void {
        self.* = .{ .level = 1, .dir = .in, .clear_s = seconds };
    }

    /// Advance by `dt` real seconds. Returns the transition to make now, on the frame the
    /// dark is whole; null otherwise. With `reduced_motion` there is no fade: a pending
    /// transition is returned at once and the screen stays clear.
    pub fn advance(self: *FadeState, dt: f32, reduced_motion: bool) ?Transition {
        if (reduced_motion) {
            const next = self.pending;
            self.* = .{};
            return next;
        }
        switch (self.dir) {
            .idle => {},
            .out => {
                self.level += @max(0, dt) / out_s;
                if (self.level >= 1) {
                    const next = self.pending;
                    self.* = .{ .level = 1, .dir = .in };
                    return next;
                }
            },
            .in => {
                self.level -= @max(0, dt) / self.clear_s;
                if (self.level <= 0) self.* = .{};
            },
        }
        return null;
    }
};

/// The clock of the scene that is showing (the arrival, the curtain's shelter, the
/// thank-you): the real time it has been showing. A scene is a pure function of it, so a
/// pinned time reproduces the frame.
pub const SceneState = struct {
    seconds: f32 = 0,
};

/// The title screen's own screens (`title.html`): the menu, the settings panel, the credits.
pub const TitleScreen = enum { menu, settings, credits };

/// The title screen's state. `attract_s` is the real time the title has been showing; the
/// canned attract loop behind the menu is a pure function of it, so a fixture that pins it
/// gets the same frame every launch.
pub const TitleState = struct {
    screen: TitleScreen = .menu,
    attract_s: f32 = 0,
};

/// The player's settings, shared by the title screen and the session menu. Held for the
/// session. Window size, fullscreen, UI scale, brightness and text act on the host; difficulty, the
/// tutorial flag, the two volumes and contrast are held but have no effect (stand-ins;
/// `docs/roadmap.md`).
pub const Settings = struct {
    pub const Difficulty = enum {
        abundant,
        temperate,
        harsh,
        barren,

        /// Input cost and yield multipliers the difficulty names (a stand-in: no system reads them).
        pub fn cost(self: Difficulty) f32 {
            return switch (self) {
                .abundant => 0.8,
                .temperate => 1.0,
                .harsh => 1.25,
                .barren => 1.5,
            };
        }
        pub fn yield(self: Difficulty) f32 {
            return switch (self) {
                .abundant => 1.25,
                .temperate => 1.0,
                .harsh => 0.8,
                .barren => 0.65,
            };
        }
    };
    pub const UiScale = enum {
        p90,
        p100,
        p110,
        p125,

        pub fn factor(self: UiScale) f32 {
            return switch (self) {
                .p90 => 0.9,
                .p100 => 1.0,
                .p110 => 1.1,
                .p125 => 1.25,
            };
        }
    };
    pub const Tutorial = enum { on, off };
    /// BRIGHTNESS's range and step, in percent; 100 is the palette as authored.
    pub const Brightness = struct {
        pub const min: f32 = 80;
        pub const max: f32 = 140;
        pub const step: f32 = 5;
    };
    pub const Contrast = enum { normal, high };
    /// How glyphs are rasterized: `sharp` is one-bit, every pixel ink or not; `smooth` is
    /// anti-aliased.
    pub const Text = enum { sharp, smooth };
    pub const Window = enum {
        w1280,
        w1600,
        w1920,
        fullscreen,

        /// The windowed size, or null for fullscreen.
        pub fn size(self: Window) ?struct { w: u32, h: u32 } {
            return switch (self) {
                .w1280 => .{ .w = 1280, .h = 720 },
                .w1600 => .{ .w = 1600, .h = 900 },
                .w1920 => .{ .w = 1920, .h = 1080 },
                .fullscreen => null,
            };
        }
    };

    difficulty: Difficulty = .temperate,
    tutorial: Tutorial = .on,
    music: f32 = 60,
    effects: f32 = 75,
    ui_scale: UiScale = .p100,
    /// Percent; the host multiplies every painted colour by `brightnessFactor` before present.
    brightness: f32 = 100,
    contrast: Contrast = .normal,
    /// `build_ui` projects it onto `View.text_smooth` each frame.
    text: Text = .sharp,
    /// The window choice; null until the player picks one (the launch window is its own size).
    window: ?Window = null,

    /// The multiply brightness asks of every painted colour: 1 at 100%.
    pub fn brightnessFactor(self: Settings) f32 {
        return self.brightness / 100;
    }
};

/// The save slots: three files in the saves folder, what each holds as the slot list shows it,
/// and the save or load the menu or the title asked for. The host opens the folder at startup
/// (`dir`; null means saving is unavailable) and applies `request` between frames, before the
/// tick (`main.zig`); the file format is `sim/data/save.zig`.
pub const SaveSlots = struct {
    pub const count = 3;
    pub const Slot = struct {
        filled: bool = false,
        act: u8 = 1,
        day: u32 = 1,
        people: u32 = 1,
    };
    /// A save to, or a load from, a slot index.
    pub const Request = union(enum) { save: u8, load: u8 };

    slots: [count]Slot = @splat(.{}),
    /// The saves folder; null when it could not be opened.
    dir: ?std.Io.Dir = null,
    /// What the menu or the title asked for this frame; the host takes it.
    request: ?Request = null,

    const names = [count][]const u8{ "slot1.zon", "slot2.zon", "slot3.zon" };

    /// The file of slot `i`, in `dir`.
    pub fn fileName(i: usize) []const u8 {
        return names[i];
    }

    /// Read what each slot's file holds. A missing file is an empty slot; one that cannot be
    /// read, or holds another version, is an empty slot and a warning.
    pub fn refresh(self: *SaveSlots, io: std.Io, gpa: std.mem.Allocator, cfg: *const simres.Config) void {
        const dir = self.dir orelse return;
        for (&self.slots, names) |*slot, name| {
            slot.* = .{};
            dir.access(io, name, .{}) catch |err| {
                if (err != error.FileNotFound) std.log.warn("save {s}: {s}", .{ name, @errorName(err) });
                continue;
            };
            const s = savemod.peek(io, dir, name, gpa, cfg) orelse {
                std.log.warn("save {s} could not be read, or is of another version; the slot shows empty", .{name});
                continue;
            };
            slot.* = .{ .filled = true, .act = s.act, .day = s.day, .people = s.people };
        }
    }

    /// The filled slot with the latest day, if any.
    pub fn latest(self: *const SaveSlots) ?usize {
        var best: ?usize = null;
        for (self.slots, 0..) |s, i| {
            if (!s.filled) continue;
            if (best == null or s.day > self.slots[best.?].day) best = i;
        }
        return best;
    }
};

/// Host frame input state, fed by the event loop and shared by UI/ECS consumers.
pub const Input = @import("./ui_client/input.zig").Input;

/// This frame's resolved presentation values. Everything here is recomputed in
/// `build_ui`'s prologue from sim state and the window; nothing persists across frames,
/// and nothing outside the UI reads it. State that must survive a frame belongs in a
/// `Ctx` pool; state the sim writes belongs in `Sim`.
pub const View = struct {
    /// This frame's palette — `build_ui` installs one over the foundation's neutral
    /// defaults.
    theme: thememod.Theme = .{},
    /// The role each verdict paints with (`ui_client/verdict.zig`). The foundation's table is
    /// the default; a game replaces it here the way it replaces `theme`.
    verdicts: @import("./ui_client/verdict.zig").Roles = .{},
    /// This frame's terminal **ground** — the near-black the framed terminal floats on
    /// (art direction, not a foundation `Theme` role; installed from `palette.ground` by
    /// `build_ui`). Defaults to the terminal `bg` so a view built before the prologue runs
    /// still has a sane, non-clashing value.
    ground: thememod.Color = .{ .r = 14, .g = 12, .b = 9, .a = 255 },
    /// This frame's six resource/sector colors (Food/Water/Fuel/Metal/Minerals/Biomass) —
    /// game content, not `Theme` roles. Installed from `palette.resources` by
    /// `build_ui`; the HUD/legend samples a hue by name.
    resources: @import("./palette.zig").ResourceColors = .{},
    /// This frame's reduced-motion policy, projected from `Resources.motion`
    /// in `build_ui`'s prologue. When `true`, *optional/decorative* transitions must snap
    /// to their end state (via `ui_client.MotionPolicy.snap`/`.phase`); functional progress
    /// indicators, state changes, pointer/focus cues, and the simulation stay visible and
    /// are never gated by it.
    reduced_motion: bool = false,
    /// Whether text rasterizes anti-aliased (true) or one-bit (false), projected from
    /// `Settings.text` in `build_ui`'s prologue. The text feature reads it at rasterize time
    /// and keys its cached textures on it, so a flip re-rasterizes every label once.
    text_smooth: bool = false,
    /// This frame's **logical→device scale factor**, set from `metrics.dpi_scale`. Every font
    /// size the host resolves is multiplied by this exactly once, in
    /// `ui_client.type.toDevice`, before it reaches the font backend — so a heading at 21
    /// *logical* px opens the font at `21 * scale` device px and tracking is computed at the
    /// device size; every authored dimension goes through `view.dp` with the same factor. Kept
    /// as a single field so there is exactly one multiply point for the whole UI.
    scale: f32 = 1,
    /// This frame's **view metrics**: the logical viewport, drawable/DPI scale, the
    /// centered terminal rect, and the responsive width class — computed once per frame in
    /// `build_ui`'s prologue from the window's coordinate size and pixel density against the
    /// `900×820` reference. `scale` above is set from `metrics.dpi_scale`; the responsive
    /// templates read `metrics.terminal`/`metrics.width_class`. Defaults to the
    /// reference metrics so a view built before the prologue runs is still sane.
    metrics: @import("./ui_client/view.zig").ViewMetrics = .{},
};

/// The host bundle, held by `Ctx` as `*Res`. One field per writer: `platform` is set at init,
/// `input` and `game.time` by the event loop, `playback` and the session-only `menu` by HUD/menu
/// controls, `game` (the simulation's resources) by systems, and `view` by `build_ui`.
pub const Resources = struct {
    platform: Platform,
    input: Input = .{},
    cursor: @import("./ui_client/cursor.zig").State = .{},
    commands: @import("./ui_client/command.zig").Registry = .{},
    /// Host-side accessibility model: the double-buffered semantic snapshot the
    /// platform bridge reads, plus the polite live-announcement channel.
    /// Presentation plumbing only — no simulation system reads or writes it. Built in paint
    /// order during `build_ui` and published after end-frame, exactly like `commands`.
    semantics: @import("./ui_client/semantics.zig").SemanticRegistry = .{},
    announcements: @import("./ui_client/semantics.zig").AnnouncementChannel = .{},
    /// The event-log lines already announced (`Log.pushed` when last read); null before the
    /// first page reads the log, which then announces only its newest line.
    log_heard: ?u64 = null,
    /// Host-side accessibility bridge: consumes the published `semantics` snapshot
    /// and drains `announcements` to the active platform provider each frame. Default provider
    /// is the inert `NoopProvider`: there is no Windows UIA screen-reader tree (`zig-sdl3`
    /// 0.2.3 exposes no `WM_GETOBJECT` hook), and the bridge's capability report says so.
    /// All platform policy stays host-side; no simulation system touches it.
    a11y: @import("./ui_client/a11y.zig").Bridge =
        @import("./ui_client/a11y.zig").Bridge.init(@import("./ui_client/a11y.zig").NoopProvider.instance()),
    /// Host-side reduced-motion policy: a one-bit preference, off unless
    /// `HA_REDUCED_MOTION` asks for it, resolved **once** at init and then projected onto
    /// `view.reduced_motion` every frame in `build_ui`. Presentation policy only; no
    /// simulation system reads or writes it.
    motion: @import("./ui_client/motion.zig").Policy = .{},
    /// Host-side transition/tween registry: scalar transitions keyed by stable
    /// node/domain id for the functional animations (the rail's collapse, stock-token font
    /// swap, board state changes). `main` advances it by the frame `dt` and projects the
    /// reduced-motion policy onto it each frame; a consumer reads `value(id, fallback)` to
    /// drive a size/gap/opacity. Presentation only; no simulation system reads it. Bounded and
    /// non-allocating (POD), so it lives inline on `Resources`.
    tween: @import("./ui_client/tween.zig").Registry = .{},
    playback: Playback = .{},
    menu: MenuState = .{},
    /// The act curtain over the live world, opened by the page build on `ActEnded`.
    curtain: CurtainState = .{},
    /// The top-level screen. A launch opens on the title; New game routes to the arrival
    /// scene, and its Begin to the game.
    route: Route = .title,
    title: TitleState = .{},
    scene: SceneState = .{},
    /// The fade between a scene and what comes next; `build_ui` advances it and makes the
    /// change it leads to.
    fade: FadeState = .{},
    /// This build is the Act I demo (`zig build -Ddemo`): the Act I curtain leads to the
    /// thank-you instead of to Act II.
    demo: bool = false,
    settings: Settings = .{},
    saves: SaveSlots = .{},
    view: View = .{},
    /// The simulation's resources (`sim/res.zig`): the run, the tuning, this frame's timesteps
    /// and the authored roster. A system reaches only these, through `ecs.run(world, &res.game,
    /// sys)`; the UI reads them as `res.game.*`.
    game: @import("./sim/res.zig").Resources = .{},
    /// The process environment, owned by `main`'s `std.process.Init` and outliving every
    /// frame. Read through `env`; null (every variable unset) in a rig built by hand.
    environ: ?*const std.process.Environ.Map = null,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, f: *fontmod.Fonts, r: *const sdl.render.Renderer, w: sdl.video.Window) !Resources {
        // A broken `assets/roster/` file does not stop the game: it starts on the shipped copy
        // and says why.
        var diag = rostermod.Diagnostics{};
        var catalog = rostermod.loadData(gpa, io, &diag) catch |err| blk: {
            if (err == error.OutOfMemory) return err;
            std.log.err("assets/roster/ did not load, starting on the shipped roster: {s}", .{diag.message()});
            break :blk try rostermod.load(gpa, rostermod.shipped, null);
        };
        errdefer catalog.deinit();
        const tex = try sdl.image.loadTexture(r.*, "assets/hello.png");
        const icons = try sdl.image.loadTexture(r.*, "assets/icons.png");
        var seed: u64 = undefined;
        io.random(std.mem.asBytes(&seed));
        return .{
            .platform = .{ .font = f, .renderer = r, .window = w, .tex = tex, .icons = icons },
            .game = .{ .sim = .{ .prng = std.Random.DefaultPrng.init(seed) }, .catalog = catalog },
            .environ = environ,
        };
    }

    /// The value of the environment variable `name`, or null when it is unset.
    pub fn env(self: *const Resources, name: []const u8) ?[]const u8 {
        const map = self.environ orelse return null;
        return map.get(name);
    }

    pub fn deinit(self: *Resources) void {
        self.platform.tex.deinit();
        self.platform.icons.deinit();
        self.game.catalog.deinit();
    }
};

test "FadeState darkens, hands over its transition once in the dark, and clears" {
    var f = FadeState{};
    try std.testing.expectEqual(@as(?Transition, null), f.advance(1, false));
    f.to(.run);
    // A second request while leaving does not change where it leads.
    f.to(.title);
    try std.testing.expectEqual(@as(?Transition, null), f.advance(FadeState.out_s * 0.5, false));
    try std.testing.expect(f.level > 0.4 and f.level < 0.6);
    try std.testing.expectEqual(@as(?Transition, .run), f.advance(FadeState.out_s, false));
    try std.testing.expectEqual(@as(f32, 1), f.level);
    try std.testing.expectEqual(FadeState.Dir.in, f.dir);
    // It is handed over once.
    try std.testing.expectEqual(@as(?Transition, null), f.advance(FadeState.in_s * 0.5, false));
    try std.testing.expect(f.level > 0.4 and f.level < 0.6);
    try std.testing.expectEqual(@as(?Transition, null), f.advance(FadeState.in_s, false));
    try std.testing.expectEqual(FadeState{}, f);
}

test "FadeState: a fade that was clearing turns around from where it is" {
    var f = FadeState{};
    f.dip(FadeState.curtain_in_s);
    try std.testing.expectEqual(@as(f32, 1), f.level);
    _ = f.advance(FadeState.curtain_in_s * 0.75, false);
    const level = f.level;
    f.to(.act_two);
    try std.testing.expectEqual(level, f.level);
    try std.testing.expectEqual(FadeState.Dir.out, f.dir);
}

test "FadeState: under reduced motion the transition is immediate and nothing darkens" {
    var f = FadeState{};
    f.to(.arrival);
    try std.testing.expectEqual(@as(?Transition, .arrival), f.advance(0.016, true));
    try std.testing.expectEqual(FadeState{}, f);
    f.dip(1);
    try std.testing.expectEqual(@as(?Transition, null), f.advance(0.016, true));
    try std.testing.expectEqual(@as(f32, 0), f.level);
}

test "Playback stepper walks pause..3x and clamps at both ends" {
    var p = Playback{};
    try std.testing.expectEqual(@as(u8, 1), p.level());
    p.step(-1);
    try std.testing.expect(p.paused);
    try std.testing.expectEqual(@as(u8, 0), p.level());
    try std.testing.expectEqual(@as(f32, 0), p.multiplier());
    p.step(-1); // already at pause
    try std.testing.expectEqual(@as(u8, 0), p.level());
    p.step(1);
    try std.testing.expectEqual(@as(u8, 1), p.level());
    try std.testing.expect(!p.paused);
    p.setLevel(3);
    p.step(1); // already at 3x
    try std.testing.expectEqual(@as(u8, 3), p.level());
    try std.testing.expectEqual(@as(f32, 3), p.multiplier());
}

test "Playback stepping up out of pause lands on 1x" {
    var p = Playback{ .speed = 3, .paused = true };
    p.step(1);
    try std.testing.expectEqual(@as(u8, 1), p.level());
}
