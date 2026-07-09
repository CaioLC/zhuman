const std = @import("std");
const sdl = @import("sdl3");
const comp = @import("./components.zig");
const logmod = @import("./log.zig");
const thememod = @import("./theme.zig");
const fontmod = @import("./font.zig");

pub const Time = struct {
    dt: f32,
    /// Seconds of game time elapsed this run — advanced while the actor lives (see
    /// `advance_clock`), reset on start over. Drives the day counter.
    elapsed: f32 = 0,
};

/// Host input state for this frame, fed by the event loop. Shared by both the
/// UI (hit-testing via `comm`) and ECS systems — one source of truth.
pub const Input = struct {
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    /// A press occurred during this frame's event poll (one-frame edge).
    mouse_down: bool = false,
    /// Vertical wheel delta this frame (one-frame edge; 0 when idle). Positive = away
    /// from the user (SDL convention) — `scroll_view` treats that as "scroll up".
    wheel_y: f32 = 0,
};

pub const Resources = struct {
    /// The multi-size monospace text backend (see `font.zig`) — measure/render at any
    /// point size, one cached `ttf.Font` per size. Held by pointer, owned by `App`.
    font: *fontmod.Fonts,
    renderer: *const sdl.render.Renderer,
    window: sdl.video.Window,
    time: Time,
    input: Input,
    /// Newest-first event feed shown in the HUD log panel; global (one feed for the run).
    log: logmod.Log = .{},
    /// The simulation's one source of chance — every uncertain outcome (an action
    /// that may or may not deliver) is rolled against this. Held here so the player
    /// today and the AI deciders later draw uncertainty from the same stream.
    prng: std.Random.DefaultPrng,
    tex: sdl.render.Texture,
    /// Sprite sheet of capital-good icons (`assets/icons.png`, a 2×2 grid). Cached once
    /// here; the UI samples cells from it by source rect (see the `img` feature's
    /// `attach_sprite`, re-exported as `ui_client.data_sprite`).
    icons: sdl.render.Texture,
    /// This frame's resolved COLD↔WARM palette — recomputed once per frame in
    /// `build_ui` (from `compute_warmth`) and read by every widget via `ctx.res.theme`,
    /// rather than threading a theme argument through every widget call. Defaults cold.
    theme: thememod.Theme = thememod.cold,
    /// Which `text_input` widget (by `node.key`) currently owns keyboard text, if any —
    /// host-global because SDL delivers `.text_input`/backspace as raw keyboard events,
    /// not routed to a widget. `null` means no field is focused (the common case; SDL's
    /// text-input mode is started/stopped to match, see `widgets.text_input`).
    focused_text: ?u64 = null,

    pub fn init(f: *fontmod.Fonts, r: *const sdl.render.Renderer, w: sdl.video.Window) !Resources {
        const tex = try sdl.image.loadTexture(r.*, "assets/hello.png");
        const icons = try sdl.image.loadTexture(r.*, "assets/icons.png");
        return .{
            .font = f,
            .renderer = r,
            .window = w,
            .time = .{ .dt = 0 },
            .input = .{},
            .prng = std.Random.DefaultPrng.init(@bitCast(std.time.milliTimestamp())),
            .tex = tex,
            .icons = icons,
        };
    }

    pub fn deinit(self: *Resources) void {
        self.tex.deinit();
        self.icons.deinit();
    }

    /// A `std.Random` over `prng` — call `.float(f32)`, `.boolean()`, etc. on it.
    pub fn random(self: *Resources) std.Random {
        return self.prng.random();
    }
};
