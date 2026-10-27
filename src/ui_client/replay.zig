//! Synthetic input replay — a script of pointer, wheel, key, text, focus, cancellation,
//! and resize events fed through the **same** entry points the SDL loop uses to fill the
//! input model (`Input.record*`, `appendText`, `setWindowFocus`, `cancel`) and to route
//! pointer edges (`route.Router`), then run through the frame driver one frame at a time.
//! Nothing here bypasses `Input.beginFrame`'s edge semantics or the router's policy: a
//! replayed frame is the desktop loop body minus SDL and minus the simulation tick.
//!
//! A replay never paints. The host it drives is headless — trees are built, laid out, and
//! stamped, so hit testing, activation, focus, registries, and pools behave exactly as on
//! the desktop — and the test asserts on `UiCtx`/`Resources` state (or on what its own
//! build function observed) after each frame.

const std = @import("std");
const sdl = @import("sdl3");
const cb = @import("ctx_binding.zig");
const input_mod = @import("input.zig");
const frame_mod = @import("frame.zig");
const route = @import("route.zig");
const view = @import("view.zig");
const Resources = @import("../res.zig").Resources;

pub const UiCtx = cb.UiCtx;
pub const Trees = frame_mod.Trees;
pub const Point = input_mod.Point;
pub const PointerKind = input_mod.PointerKind;
pub const PointerButton = input_mod.PointerButton;
pub const Modifiers = input_mod.Modifiers;
pub const Keycode = sdl.keycode.Keycode;

/// Which pointer a synthetic event comes from. The default is the anonymous mouse, the
/// identity SDL reports for an ordinary desktop mouse.
pub const Pointer = struct { kind: PointerKind = .mouse, id: ?u64 = null };

/// One synthetic event. Coordinates are in the input model's space — device px, the
/// space the layout is solved and hit-tested in.
pub const Event = union(enum) {
    pointer_move: Move,
    pointer_press: Button,
    pointer_release: Button,
    wheel: Wheel,
    key_press: Key,
    key_repeat: Key,
    key_release: Key,
    /// Committed text bytes, as SDL's text-input event delivers them beside the key event.
    text: []const u8,
    focus_lost,
    focus_gained,
    /// Platform/touch cancellation of every held input.
    cancel,
    /// The window changed size: recompute the view metrics and mark geometry stale.
    resize: Resize,

    pub const Move = struct { x: f32, y: f32, pointer: Pointer = .{} };
    pub const Button = struct {
        x: f32,
        y: f32,
        button: PointerButton = .primary,
        clicks: u8 = 1,
        pointer: Pointer = .{},
    };
    pub const Wheel = struct { x: f32, y: f32, dx: f32 = 0, dy: f32 = 0, pointer: Pointer = .{} };
    pub const Key = struct { key: Keycode, modifiers: Modifiers = .{} };
    pub const Resize = struct { logical_w: f32, logical_h: f32, pixel_density: f32 = 1 };
};

pub const Replay = struct {
    driver: *frame_mod.Driver,
    host: frame_mod.Host,

    pub fn init(driver: *frame_mod.Driver, host: frame_mod.Host) Replay {
        return .{ .driver = driver, .host = host };
    }

    /// One frame as the desktop loop runs it: reset the input model's edges, record and
    /// route every event in order, then run the driver's step.
    pub fn frame(self: *Replay, events: []const Event) !void {
        self.driver.ui.res.input.beginFrame();
        for (events) |event| self.feed(event);
        try self.driver.step(self.host);
    }

    /// `count` frames with no input — the frames that let geometry stamp and registries
    /// publish before a script acts on them.
    pub fn idle(self: *Replay, count: usize) !void {
        for (0..count) |_| try self.frame(&.{});
    }

    /// Record one event into the input model and route it, exactly as the SDL loop does
    /// for the corresponding SDL event. Primary presses/releases route for every pointer
    /// kind: a synthetic touch is the finger event itself, not a synthesized duplicate.
    pub fn feed(self: *Replay, event: Event) void {
        const res = self.driver.ui.res;
        const input = &res.input;
        const router = &self.driver.router;
        switch (event) {
            .pointer_move => |m| {
                const pos = Point{ .x = m.x, .y = m.y };
                const prev = input.pointer.position;
                input.recordMotion(m.pointer.kind, m.pointer.id, pos, .{ .x = pos.x - prev.x, .y = pos.y - prev.y });
                router.pointerMotion(m.pointer.kind, m.pointer.id, pos);
            },
            .pointer_press => |b| {
                const pos = Point{ .x = b.x, .y = b.y };
                input.recordButton(b.pointer.kind, b.pointer.id, b.button, true, b.clicks, pos);
                if (b.button == .primary) router.pointerPress(b.pointer.kind, b.pointer.id, pos);
            },
            .pointer_release => |b| {
                const pos = Point{ .x = b.x, .y = b.y };
                input.recordButton(b.pointer.kind, b.pointer.id, b.button, false, b.clicks, pos);
                if (b.button == .primary) router.pointerRelease(b.pointer.kind, b.pointer.id, pos);
            },
            .wheel => |w| {
                const pos = Point{ .x = w.x, .y = w.y };
                input.recordWheel(w.pointer.kind, w.pointer.id, pos, .{ .x = w.dx, .y = w.dy });
                router.wheel(pos);
            },
            .key_press => |k| input.recordKey(k.key, .press, k.modifiers),
            .key_repeat => |k| input.recordKey(k.key, .repeat, k.modifiers),
            .key_release => |k| input.recordKey(k.key, .release, k.modifiers),
            .text => |bytes| input.appendText(bytes),
            .focus_lost => {
                input.setWindowFocus(false);
                router.windowFocusLost();
            },
            .focus_gained => input.setWindowFocus(true),
            .cancel => {
                input.cancel();
                router.cancelGesture();
            },
            .resize => |r| {
                const m = view.compute(r.logical_w, r.logical_h, r.pixel_density);
                res.view.metrics = m;
                res.view.scale = m.dpi_scale;
                router.geometryChanged();
            },
        }
    }
};

/// A `Resources` for a windowless run: every host registry at its default, the sim fresh,
/// and `platform` left undefined because no renderer, font, or window exists. A headless
/// build must therefore not create text, image, or svg content.
pub fn headlessResources() Resources {
    return .{ .platform = undefined, .sim = .{} };
}

/// A headless `frame_mod.Host` over a fixture whose type declares
/// `fn build(self: *T, ui_ctx: *UiCtx) anyerror!Trees`. No cursor, draw, or report hooks.
pub fn hostOf(comptime T: type, fixture: *T) frame_mod.Host {
    const Thunk = struct {
        fn build(user: *anyopaque, ui_ctx: *UiCtx) anyerror!Trees {
            const self: *T = @ptrCast(@alignCast(user));
            return self.build(ui_ctx);
        }
    };
    return .{ .user = fixture, .build = Thunk.build };
}

/// An in-memory `route.Platform` for tests: one owned clipboard text and a count of
/// text-input session stops.
pub const MemoryPlatform = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,
    has_text: bool = false,
    stops: u32 = 0,

    pub fn platform(self: *MemoryPlatform) route.Platform {
        return .{ .ctx = self, .vtable = &vtable };
    }

    pub fn text(self: *const MemoryPlatform) []const u8 {
        return self.buf[0..self.len];
    }

    const vtable: route.Platform.VTable = .{
        .clipboard_read = read,
        .clipboard_write = write,
        .stop_text_input = stop,
    };

    fn read(ctx: ?*anyopaque, buf: []u8) ?[]const u8 {
        const self: *MemoryPlatform = @ptrCast(@alignCast(ctx.?));
        if (!self.has_text) return null;
        const n = @min(buf.len, self.len);
        @memcpy(buf[0..n], self.buf[0..n]);
        return buf[0..n];
    }

    fn write(ctx: ?*anyopaque, bytes: [:0]const u8) bool {
        const self: *MemoryPlatform = @ptrCast(@alignCast(ctx.?));
        if (bytes.len > self.buf.len) return false;
        @memcpy(self.buf[0..bytes.len], bytes);
        self.len = bytes.len;
        self.has_text = true;
        return true;
    }

    fn stop(ctx: ?*anyopaque) void {
        const self: *MemoryPlatform = @ptrCast(@alignCast(ctx.?));
        self.stops += 1;
    }
};

// ============================ Tests ==========================================
// Every fixture builds interactive nodes without text, so no font is needed. A fixture
// records what its build observed (`.clicked`, focus, editor text, scroll offset) and the
// test asserts on that after each frame — the same information a real screen acts on.

const el = @import("elements.zig");
const drag = @import("drag.zig");
const ui_root = @import("ui");
const UiState = cb.UiState;
const Node = cb.Node;

/// Everything one headless run owns, with stable addresses for the pointers between them.
const Rig = struct {
    res: Resources,
    arena: std.heap.ArenaAllocator,
    ui: UiCtx,
    driver: frame_mod.Driver,

    fn setUp(self: *Rig, platform: route.Platform) void {
        self.res = headlessResources();
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        self.ui = UiCtx.init(&self.res, std.testing.allocator, self.arena.allocator());
        self.driver = frame_mod.Driver.init(&self.ui, &self.arena, std.testing.io, platform);
    }

    fn tearDown(self: *Rig) void {
        self.ui.deinit();
        self.arena.deinit();
    }

    fn replay(self: *Rig, host: frame_mod.Host) Replay {
        return Replay.init(&self.driver, host);
    }
};

fn roots(ui_ctx: *UiCtx, root: *Node) !Trees {
    const list = try ui_ctx.arena.alloc(*Node, 1);
    list[0] = root;
    return list;
}

/// One 100×40 interactive box at (20, 20).
const ClickFixture = struct {
    clicks: u32 = 0,
    pressed: bool = false,
    held: bool = false,
    dragging: bool = false,

    fn build(self: *ClickFixture, ui_ctx: *UiCtx) anyerror!Trees {
        const root = try el.root(ui_ctx, "root");
        const btn = (try root.div("btn"))
            .with_layout(.top_left)
            .with_offset_px(20, 20)
            .with_size_px(.{ .fixed = 100 }, .{ .fixed = 40 });
        const q = btn.query();
        self.pressed = q.pressed;
        self.held = q.held;
        self.dragging = q.dragging;
        if (q.clicked) self.clicks += 1;
        return roots(ui_ctx, root.get());
    }
};

test "replay: press and release on an interactive node yields .clicked to its builder once" {
    var rig: Rig = undefined;
    rig.setUp(.none);
    defer rig.tearDown();
    var fx = ClickFixture{};
    var r = rig.replay(hostOf(ClickFixture, &fx));

    try r.idle(1); // build, layout, stamp — nothing is hittable before this
    try std.testing.expectEqual(@as(u32, 0), fx.clicks);

    // Press in one frame: the builder sees press and held, no click yet.
    try r.frame(&.{.{ .pointer_press = .{ .x = 50, .y = 30 } }});
    try std.testing.expect(fx.pressed and fx.held);
    try std.testing.expectEqual(@as(u32, 0), fx.clicks);

    // Release over the same node in the next frame: exactly one click, then none.
    try r.frame(&.{.{ .pointer_release = .{ .x = 52, .y = 31 } }});
    try std.testing.expectEqual(@as(u32, 1), fx.clicks);
    try std.testing.expect(!fx.held);
    try r.idle(1);
    try std.testing.expectEqual(@as(u32, 1), fx.clicks);

    // Press and release inside one frame also complete.
    try r.frame(&.{ .{ .pointer_press = .{ .x = 50, .y = 30 } }, .{ .pointer_release = .{ .x = 50, .y = 30 } } });
    try std.testing.expectEqual(@as(u32, 2), fx.clicks);
}

test "replay: a release outside the pressed node suppresses activation" {
    var rig: Rig = undefined;
    rig.setUp(.none);
    defer rig.tearDown();
    var fx = ClickFixture{};
    var r = rig.replay(hostOf(ClickFixture, &fx));
    try r.idle(1);

    // Two pixels of travel, from just inside the right edge to just outside: no drag,
    // but the geometric target differs, so no click.
    try r.frame(&.{.{ .pointer_press = .{ .x = 119, .y = 30 } }});
    try r.frame(&.{.{ .pointer_release = .{ .x = 121, .y = 30 } }});
    try std.testing.expectEqual(@as(u32, 0), fx.clicks);
    try std.testing.expect(!fx.dragging);
}

test "replay: a drag past the threshold suppresses the click and publishes .dragging" {
    var rig: Rig = undefined;
    rig.setUp(.none);
    defer rig.tearDown();
    var fx = ClickFixture{};
    var r = rig.replay(hostOf(ClickFixture, &fx));
    try r.idle(1);

    try r.frame(&.{.{ .pointer_press = .{ .x = 50, .y = 30 } }});
    try r.frame(&.{.{ .pointer_move = .{ .x = 60, .y = 30 } }}); // 10px > the 4px threshold
    try std.testing.expect(fx.dragging);
    try r.frame(&.{.{ .pointer_release = .{ .x = 50, .y = 30 } }}); // back over the node
    try std.testing.expectEqual(@as(u32, 0), fx.clicks);

    // The gesture is consumed: the next ordinary click completes.
    try r.frame(&.{ .{ .pointer_press = .{ .x = 50, .y = 30 } }, .{ .pointer_release = .{ .x = 50, .y = 30 } } });
    try std.testing.expectEqual(@as(u32, 1), fx.clicks);
}

test "replay: window focus loss and cancellation drop the in-flight activation" {
    var rig: Rig = undefined;
    rig.setUp(.none);
    defer rig.tearDown();
    var fx = ClickFixture{};
    var r = rig.replay(hostOf(ClickFixture, &fx));
    try r.idle(1);

    try r.frame(&.{.{ .pointer_press = .{ .x = 50, .y = 30 } }});
    try r.frame(&.{ .focus_lost, .{ .pointer_release = .{ .x = 50, .y = 30 } } });
    try std.testing.expectEqual(@as(u32, 0), fx.clicks);
    try std.testing.expect(!rig.res.input.window_focused);

    try r.frame(&.{ .focus_gained, .{ .pointer_press = .{ .x = 50, .y = 30 } } });
    try r.frame(&.{ .cancel, .{ .pointer_release = .{ .x = 50, .y = 30 } } });
    try std.testing.expectEqual(@as(u32, 0), fx.clicks);
}

test "replay: a resize makes geometry stale for one frame so no click lands on the ghost" {
    var rig: Rig = undefined;
    rig.setUp(.none);
    defer rig.tearDown();
    var fx = ClickFixture{};
    var r = rig.replay(hostOf(ClickFixture, &fx));
    try r.idle(1);

    try r.frame(&.{
        .{ .resize = .{ .logical_w = 1200, .logical_h = 1000 } },
        .{ .pointer_press = .{ .x = 50, .y = 30 } },
        .{ .pointer_release = .{ .x = 50, .y = 30 } },
    });
    try std.testing.expectEqual(@as(u32, 0), fx.clicks);
    try std.testing.expectEqual(@as(f32, 1200), rig.res.view.metrics.px_w);
    // The frame re-stamped at the new size, so the guard lifted.
    try std.testing.expect(!rig.driver.router.geometry_stale);

    try r.frame(&.{ .{ .pointer_press = .{ .x = 50, .y = 30 } }, .{ .pointer_release = .{ .x = 50, .y = 30 } } });
    try std.testing.expectEqual(@as(u32, 1), fx.clicks);
}

/// Two focusable boxes registered in order; `a` reports keyboard activation.
const FocusFixture = struct {
    a: u64 = 0,
    b: u64 = 0,
    a_clicks: u32 = 0,

    fn build(self: *FocusFixture, ui_ctx: *UiCtx) anyerror!Trees {
        const root = try el.root(ui_ctx, "root");
        const a = (try root.div("a"))
            .with_layout(.top_left)
            .with_size_px(.{ .fixed = 40 }, .{ .fixed = 40 });
        const b = (try root.div("b"))
            .with_layout(.top_left)
            .with_offset_px(60, 0)
            .with_size_px(.{ .fixed = 40 }, .{ .fixed = 40 });
        ui_ctx.registerFocus(a.node.key, true);
        ui_ctx.registerFocus(b.node.key, true);
        if (a.query().clicked) self.a_clicks += 1;
        _ = b.query();
        self.a = a.node.key;
        self.b = b.node.key;
        return roots(ui_ctx, root.get());
    }
};

test "replay: Tab then Shift+Tab move focus between two registered targets; Enter activates" {
    var rig: Rig = undefined;
    rig.setUp(.none);
    defer rig.tearDown();
    var fx = FocusFixture{};
    var r = rig.replay(hostOf(FocusFixture, &fx));
    try r.idle(1); // the build registers; endFrame publishes the traversal order
    try std.testing.expectEqual(@as(?u64, null), rig.ui.focusedKey());

    try r.frame(&.{.{ .key_press = .{ .key = .tab } }});
    try std.testing.expectEqual(@as(?u64, fx.a), rig.ui.focusedKey());
    try r.frame(&.{.{ .key_press = .{ .key = .tab } }});
    try std.testing.expectEqual(@as(?u64, fx.b), rig.ui.focusedKey());
    try r.frame(&.{.{ .key_press = .{ .key = .tab, .modifiers = .{ .shift = true } } }});
    try std.testing.expectEqual(@as(?u64, fx.a), rig.ui.focusedKey());

    // Enter emits the same `.clicked` a pointer release would; a repeat does not.
    try r.frame(&.{.{ .key_press = .{ .key = .return_key } }});
    try std.testing.expectEqual(@as(u32, 1), fx.a_clicks);
    try r.frame(&.{.{ .key_repeat = .{ .key = .return_key } }});
    try std.testing.expectEqual(@as(u32, 1), fx.a_clicks);
}

/// A registered search field over a view that registers itself as the Escape target.
const SearchFixture = struct {
    field: u64 = 0,
    focused: bool = false,
    text: [UiState.TextInputState.max_query_bytes]u8 = undefined,
    len: usize = 0,
    refused: bool = false,
    view_dismissed: u32 = 0,

    fn build(self: *SearchFixture, ui_ctx: *UiCtx) anyerror!Trees {
        const root = try el.root(ui_ctx, "root");
        const view_el = (try root.div("view"))
            .with_layout(.top_left)
            .with_size_px(.{ .fixed = 400 }, .{ .fixed = 300 });
        // No Escape owner is registered here: under the host's modal-blocked `/` policy a
        // registered Escape target (an open modal) would suppress the search shortcut. A
        // catalog search field is not behind a modal, so it stays slash-reachable. The view
        // query keeps its slot alive and lets the test assert it is never dismissed.
        if (view_el.query().dismissed) self.view_dismissed += 1;

        const field = (try view_el.div("search"))
            .with_layout(.top_left)
            .with_offset_px(10, 10)
            .with_size_px(.{ .fixed = 200 }, .{ .fixed = 30 });
        ui_ctx.registerFocus(field.node.key, true);
        // `editorKeyOf` indirection: a field owns its own editor model, so the editor key
        // is the field key; `search_shortcut = true` makes `/` focus it.
        ui_ctx.res.commands.registerText(field.node.key, field.node.key, true);
        _ = field.query();
        const ed = field.node.state(ui_ctx, UiState.TextInputState);
        const t = ed.text();
        @memcpy(self.text[0..t.len], t);
        self.len = t.len;
        self.refused = ed.refused;
        self.focused = ui_ctx.isFocused(field.node.key);
        self.field = field.node.key;
        return roots(ui_ctx, root.get());
    }

    fn shown(self: *const SearchFixture) []const u8 {
        return self.text[0..self.len];
    }
};

test "replay: slash focuses the registered text owner and typed text lands in its editor" {
    var rig: Rig = undefined;
    rig.setUp(.none);
    defer rig.tearDown();
    var fx = SearchFixture{};
    var r = rig.replay(hostOf(SearchFixture, &fx));
    try r.idle(1);
    try std.testing.expect(!fx.focused);

    // The slash key arrives with its own text byte; the shortcut suppresses that byte.
    try r.frame(&.{ .{ .key_press = .{ .key = .slash } }, .{ .text = "/" } });
    try std.testing.expect(fx.focused);
    try std.testing.expectEqualStrings("", fx.shown());

    try r.frame(&.{ .{ .key_press = .{ .key = .a } }, .{ .text = "a" }, .{ .key_press = .{ .key = .b } }, .{ .text = "b" } });
    try std.testing.expectEqualStrings("ab", fx.shown());
    try r.frame(&.{.{ .key_press = .{ .key = .backspace } }});
    try std.testing.expectEqualStrings("a", fx.shown());

    // Escape reaches the focused text owner first: focus clears, the view is not dismissed.
    try r.frame(&.{.{ .key_press = .{ .key = .escape } }});
    try std.testing.expect(!fx.focused);
    try std.testing.expectEqual(@as(u32, 0), fx.view_dismissed);
    // Text with no focused owner goes nowhere.
    try r.frame(&.{.{ .text = "z" }});
    try std.testing.expectEqualStrings("a", fx.shown());
}

test "replay: clipboard chords route through the injected platform seam" {
    var platform = MemoryPlatform{};
    var rig: Rig = undefined;
    rig.setUp(platform.platform());
    defer rig.tearDown();
    var fx = SearchFixture{};
    var r = rig.replay(hostOf(SearchFixture, &fx));
    try r.idle(1);

    try r.frame(&.{.{ .key_press = .{ .key = .slash } }});
    try r.frame(&.{.{ .text = "ab" }});
    const ctrl = Modifiers{ .control = true };
    // Ctrl+A selects all and Ctrl+C copies; their letter bytes are suppressed.
    try r.frame(&.{
        .{ .key_press = .{ .key = .a, .modifiers = ctrl } },
        .{ .text = "a" },
        .{ .key_press = .{ .key = .c, .modifiers = ctrl } },
        .{ .text = "c" },
    });
    try std.testing.expectEqualStrings("ab", platform.text());
    try std.testing.expectEqualStrings("ab", fx.shown());
    // End collapses the selection to the end; Ctrl+V pastes there.
    try r.frame(&.{.{ .key_press = .{ .key = .end } }});
    try r.frame(&.{ .{ .key_press = .{ .key = .v, .modifiers = ctrl } }, .{ .text = "v" } });
    try std.testing.expectEqualStrings("abab", fx.shown());
    try std.testing.expect(!fx.refused);

    // Escape on the text owner ends the platform text-input session; so does focus loss.
    try r.frame(&.{.{ .key_press = .{ .key = .escape } }});
    try std.testing.expectEqual(@as(u32, 1), platform.stops);
    try r.frame(&.{.focus_lost});
    try std.testing.expectEqual(@as(u32, 2), platform.stops);
}

/// Two overlapping views that both register for Escape; the later one is topmost.
const EscapeFixture = struct {
    under_dismissed: u32 = 0,
    over_dismissed: u32 = 0,

    fn build(self: *EscapeFixture, ui_ctx: *UiCtx) anyerror!Trees {
        const root = try el.root(ui_ctx, "root");
        const under = (try root.div("under"))
            .with_layout(.top_left)
            .with_size_px(.{ .fixed = 300 }, .{ .fixed = 300 });
        ui_ctx.res.commands.registerEscape(under.node.key);
        if (under.query().dismissed) self.under_dismissed += 1;
        const over = (try root.div("over"))
            .with_layout(.top_left)
            .with_offset_px(50, 50)
            .with_size_px(.{ .fixed = 100 }, .{ .fixed = 100 });
        ui_ctx.res.commands.registerEscape(over.node.key);
        if (over.query().dismissed) self.over_dismissed += 1;
        return roots(ui_ctx, root.get());
    }
};

test "replay: Escape reaches the topmost registered target as .dismissed" {
    var rig: Rig = undefined;
    rig.setUp(.none);
    defer rig.tearDown();
    var fx = EscapeFixture{};
    var r = rig.replay(hostOf(EscapeFixture, &fx));
    try r.idle(1);

    try r.frame(&.{.{ .key_press = .{ .key = .escape } }});
    try std.testing.expectEqual(@as(u32, 1), fx.over_dismissed);
    try std.testing.expectEqual(@as(u32, 0), fx.under_dismissed);
    // Dismissal is transient: the next frame sees nothing without a new press.
    try r.idle(1);
    try std.testing.expectEqual(@as(u32, 1), fx.over_dismissed);
    // A repeat never dismisses.
    try r.frame(&.{.{ .key_repeat = .{ .key = .escape } }});
    try std.testing.expectEqual(@as(u32, 1), fx.over_dismissed);
}

/// A 100×100 scroll view holding ten 30px rows (336px of content with the 4px gaps).
/// Rebuilt from the current `El`/node APIs plus the host scroll primitives (`ScrollState`,
/// the wheel policy, and `drag.updateScrollThumb`) rather than a packaged widget: a viewport
/// clips a `fit_children` content column, the wheel over the viewport advances the clamped
/// offset at 24 px/tick, and the offset folds into `content.layout.scroll_y`.
const ScrollFixture = struct {
    offset: f32 = 0,

    /// Wheel delta → px scrolled per tick — the host scroll policy the viewport reads.
    const scroll_speed: f32 = 24.0;
    const scrollbar_w: f32 = 6.0;

    fn build(self: *ScrollFixture, ui_ctx: *UiCtx) anyerror!Trees {
        const root = try el.root(ui_ctx, "root");
        const outer = (try root.div("scroll"))
            .with_layout(.relative)
            .with_flow(.{ .dir = .row })
            .with_size_px(.fit_children, .fit_children);

        const viewport = (try outer.div("viewport"))
            .with_layout(.relative)
            .with_size_px(.{ .fixed = 100 }, .{ .fixed = 100 })
            .with_overflow(.clip);

        const content = (try viewport.div("content"))
            .with_layout(.relative)
            .with_flow(.{ .dir = .column })
            .with_gap(4);
        inline for (0..10) |i| {
            _ = (try content.item("row", i))
                .with_layout(.relative)
                .with_size_px(.{ .fixed = 100 }, .{ .fixed = 30 });
        }

        // Clamp needs content height, read back from last frame's stamped rect; a geometry
        // probe that must not take the hit.
        const content_h = if (content.node.rect(ui_ctx)) |rc| rc.h else 0;
        _ = content.pass_through().track();

        const max_offset = @max(0.0, content_h - 100);
        const state = outer.node.state(ui_ctx, UiState.ScrollState);
        if (viewport.query().wheel and ui_ctx.res.input.pointer.wheel.y != 0) {
            state.offset -= ui_ctx.res.input.pointer.wheel.y * scroll_speed; // wheel up → toward the top
        }
        state.offset = std.math.clamp(state.offset, 0, max_offset);

        if (max_offset > 0) {
            const track = (try outer.div("track"))
                .with_layout(.relative)
                .with_size_px(.{ .fixed = scrollbar_w }, .{ .fixed = 100 });
            const thumb_h = @min(100.0, @max(16.0, 100.0 * 100.0 / content_h));
            const thumb_travel = 100.0 - thumb_h;
            const thumb = (try track.div("thumb"))
                .with_layout(.relative)
                .with_size_px(.{ .fixed = scrollbar_w }, .{ .fixed = thumb_h });
            const thumb_q = thumb.query();
            drag.updateScrollThumb(ui_ctx, state, thumb.node.key, thumb_q.pressed, max_offset, thumb_travel);
        } else if (state.dragging) {
            drag.cancelScrollThumb(ui_ctx, state);
        }

        content.node.layout.scroll_y = state.offset;
        self.offset = state.offset;
        return roots(ui_ctx, root.get());
    }
};

test "replay: a wheel event over a scroll region scrolls it; elsewhere it does not" {
    var rig: Rig = undefined;
    rig.setUp(.none);
    defer rig.tearDown();
    var fx = ScrollFixture{};
    var r = rig.replay(hostOf(ScrollFixture, &fx));
    // Frame 1 stamps the content; frame 2 reads its height and knows it overflows.
    try r.idle(2);
    try std.testing.expectEqual(@as(f32, 0), fx.offset);

    try r.frame(&.{.{ .wheel = .{ .x = 50, .y = 50, .dy = -1 } }}); // wheel down → scroll toward the bottom
    try std.testing.expectEqual(@as(f32, 24), fx.offset);
    try r.frame(&.{.{ .wheel = .{ .x = 50, .y = 50, .dy = -1 } }});
    try std.testing.expectEqual(@as(f32, 48), fx.offset);

    // A wheel over empty space routes to nothing; the offset holds.
    try r.frame(&.{.{ .wheel = .{ .x = 500, .y = 500, .dy = -1 } }});
    try std.testing.expectEqual(@as(f32, 48), fx.offset);

    // Scrolling back past the top clamps at zero.
    try r.frame(&.{.{ .wheel = .{ .x = 50, .y = 50, .dy = 5 } }});
    try std.testing.expectEqual(@as(f32, 0), fx.offset);
}
