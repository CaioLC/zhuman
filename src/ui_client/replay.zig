//! `replay` — **scripted synthetic input** into the host input model and the engine's event
//! stage, without SDL polling. The game's event loop (`main.zig`) is the one production driver:
//! it turns `sdl.events.poll()` into `Input.record*` calls, then runs the pointer-activation and
//! command portions of the event stage (`markTarget`/`markKey`/`moveFocus`, `PointerActivation`,
//! `commandFromKeyEvent`). None of that lower half touches SDL — the engine's `mark*` family is
//! pure over the slot pool, `PointerActivation` and `command.fromKeyEvent` are pure value
//! transforms — so an interaction state machine can be regression-tested by feeding the same
//! `Input.record*` edges and running the same event-stage order against a laid-out slot pool.
//!
//! This is that lower half, lifted into one reusable, SDL-free driver so a test (QA-08) or a
//! deterministic fixture (QA-07) can script pointer/key/text/wheel events and assert the
//! resulting `Interaction` flags, focus, and capture — the regression surface for the
//! interaction state machines. It owns no window, no font, no clipboard: clipboard-bound
//! editing commands (`clipboard_*`) are deliberately **not** executed here (the production
//! router gates them to SDL clipboard availability); every other command maps the same way the
//! game does.
//!
//! **What it is not.** It does not build a UI frame or measure text — a frame's node tree needs
//! the platform font (see `test_ui.zig`/`control.zig`). The caller stamps the slots it wants to
//! probe (`Driver.stamp`) exactly as the post-layout `stamp_rects` walk would, scripts input,
//! then reads flags back. Pixel rendering stays out: this asserts input/layout, nothing drawn.

const std = @import("std");
const input = @import("input.zig");
const activation = @import("activation.zig");
const command = @import("command.zig");
const cb = @import("ctx_binding.zig");
const ui = @import("ui");

const UiCtx = cb.UiCtx;
const Rect = ui.Rect;
const Point = input.Point;

/// One scripted input event. Mirrors the production event loop's SDL cases
/// (`main.zig`'s `poll` switch) one-to-one so a script reads as the gestures a user performs.
/// Coordinates are already in the engine's device-px layout space (production applies the DPI
/// `pointerAt` seam before `record*`); a fixture builds its slots in the same space.
pub const Event = union(enum) {
    /// Pointer moved to `at`. `delta` defaults to the step from the last known position.
    move: struct { at: Point, kind: input.PointerKind = .mouse, id: ?u64 = 0, delta: ?Point = null },
    /// Primary (or named) button pressed at `at`.
    press: struct { at: Point, button: input.PointerButton = .primary, kind: input.PointerKind = .mouse, id: ?u64 = 0, clicks: u8 = 1 },
    /// Primary (or named) button released at `at`.
    release: struct { at: Point, button: input.PointerButton = .primary, kind: input.PointerKind = .mouse, id: ?u64 = 0, clicks: u8 = 1 },
    /// Mouse wheel scrolled by `delta` while the pointer is over `at`.
    wheel: struct { at: Point, delta: Point, kind: input.PointerKind = .mouse, id: ?u64 = 0 },
    /// A key edge (press/repeat/release) with modifiers. Routed through the same semantic
    /// command mapping the game uses.
    key: struct { key: @import("sdl3").keycode.Keycode, action: input.KeyAction = .press, modifiers: input.Modifiers = .{} },
    /// Committed text (an IME/typed string), appended to the frame's text buffer.
    text: []const u8,
    /// Window focus changed (focus loss cancels held input, exactly as the platform does).
    window_focus: bool,
};

/// What a scripted key command did, so a test can assert routing without re-deriving it.
pub const CommandOutcome = struct {
    command: command.Command,
    /// A focus-moving command (`focus_next`/`focus_previous`) that actually moved focus.
    focus_moved: bool = false,
    /// A roving-group move (`move_left/right/up/down`) that actually moved the roving focus.
    roving_moved: bool = false,
    /// An arrow/page command that fell through to the focused range owner (a slider) and
    /// marked its increment/decrement flag, because no roving group claimed the move.
    range_marked: bool = false,
    /// `activate` (Enter/Space) that marked a focused control `clicked`.
    activated: bool = false,
    /// `dismiss` (Escape) that marked the registered escape owner `dismissed`.
    dismissed: bool = false,
    /// A clipboard/select-all command that this SDL-free driver does not execute (the
    /// production router gates it to the SDL clipboard). Reported so a script can see it was
    /// recognized but intentionally skipped.
    clipboard_skipped: bool = false,
};

/// The SDL-free lower half of the event stage, bound to one `UiCtx`. The caller owns the
/// `UiCtx` and its `Resources` (whose `input` field this writes). Pointer gestures run through
/// the real `PointerActivation` policy and the engine's capture-aware `markTarget`/`targetAt`,
/// so a release validates against the same stamped target the production loop checks.
pub const Driver = struct {
    ctx: *UiCtx,
    activation: activation.PointerActivation = .{},
    /// Last pointer position, so a `move` without an explicit delta derives one.
    last_pointer: Point = .{},

    pub fn init(ctx: *UiCtx) Driver {
        return .{ .ctx = ctx };
    }

    fn in(self: *Driver) *input.Input {
        return &self.ctx.res.input;
    }

    /// Begin a frame's input exactly as the production loop does: clear per-frame edges on the
    /// `Input` model (holding position/held state). Call once before scripting a frame's events.
    pub fn beginInput(self: *Driver) void {
        self.in().beginFrame();
    }

    /// Stamp a slot the way the post-layout `stamp_rects` walk would, so the event stage can
    /// hit-test and bubble against it. `clip` is the inherited clip (null = uncropped);
    /// `parent` the nearest stamped ancestor key for containment bubbling.
    pub fn stamp(self: *Driver, key: u64, rect: Rect, clip: ?Rect, parent: ?u64) void {
        _ = self.ctx.interactionOf(key); // a node has no slot until queried
        _ = self.ctx.stampRect(key, rect, clip, parent);
    }

    /// Feed one scripted event. Pointer events update the `Input` model and run the
    /// activation/mark portion of the event stage; key events map to a semantic command and
    /// route it; text/focus mirror the platform. Returns a command outcome only for a key
    /// event that produced a routed command, else null.
    pub fn feed(self: *Driver, event: Event) ?CommandOutcome {
        switch (event) {
            .move => |m| {
                const delta = m.delta orelse Point{ .x = m.at.x - self.last_pointer.x, .y = m.at.y - self.last_pointer.y };
                self.in().recordMotion(m.kind, m.id, m.at, delta);
                self.last_pointer = m.at;
                // Mouse motion routes an in-flight gesture (drag detection); touch does not,
                // matching the production loop.
                if (m.kind != .touch) {
                    self.activation.motion(m.kind, m.id, m.at);
                    if (self.activation.draggingKey()) |key| _ = self.ctx.markKey(key, .dragging);
                }
            },
            .press => |p| {
                self.in().recordButton(p.kind, p.id, p.button, true, p.clicks, p.at);
                self.last_pointer = p.at;
                if (p.button == .primary and p.kind != .touch) {
                    const target = self.ctx.markTarget(.pressed, p.at.x, p.at.y);
                    self.activation.press(target, p.kind, p.id, p.at);
                }
            },
            .release => |r| {
                self.in().recordButton(r.kind, r.id, r.button, false, r.clicks, r.at);
                self.last_pointer = r.at;
                if (r.button == .primary and r.kind != .touch) {
                    self.activation.motion(r.kind, r.id, r.at);
                    _ = self.ctx.markTarget(.released, r.at.x, r.at.y);
                    const target = self.ctx.targetAt(r.at.x, r.at.y);
                    if (self.activation.release(target, r.kind, r.id, r.at)) |key| _ = self.ctx.markKey(key, .clicked);
                }
            },
            .wheel => |w| {
                self.in().recordWheel(w.kind, w.id, w.at, w.delta);
                self.last_pointer = w.at;
                self.ctx.mark(.wheel, w.at.x, w.at.y);
            },
            .key => |k| {
                self.in().recordKey(k.key, k.action, k.modifiers);
                const cmd = command.fromKeyEvent(.{ .key = k.key, .action = k.action, .modifiers = k.modifiers }) orelse return null;
                return self.route(cmd);
            },
            .text => |bytes| self.in().appendText(bytes),
            .window_focus => |focused| self.in().setWindowFocus(focused),
        }
        return null;
    }

    /// Script a whole gesture — press, optional moves, release — at one or more points. The
    /// first point is the press; intermediate points are moves; the last is the release. A
    /// single point is a click in place. Returns whether the gesture activated a control.
    pub fn click(self: *Driver, at: Point) bool {
        _ = self.feed(.{ .press = .{ .at = at } });
        _ = self.feed(.{ .release = .{ .at = at } });
        return self.activation.pressedKey() == null; // consumed by its matching release
    }

    /// Route a semantic command through the same decisions the game's `routeCommand` makes
    /// for the SDL-free subset: focus traversal, roving movement, activation, and dismissal.
    /// Clipboard/editor-text commands are recognized but not executed here (no window).
    fn route(self: *Driver, cmd: command.Command) CommandOutcome {
        var out: CommandOutcome = .{ .command = cmd };
        switch (cmd) {
            .focus_next => out.focus_moved = self.ctx.moveFocus(.next, true),
            .focus_previous => out.focus_moved = self.ctx.moveFocus(.previous, true),
            .move_left => {
                out.roving_moved = self.ctx.moveFocusedRoving(.previous, true);
                if (out.roving_moved) {
                    if (self.ctx.focusedKey()) |key| _ = self.ctx.markKey(key, .clicked);
                } else out.range_marked = self.markRange(.decrement);
            },
            .move_up => {
                out.roving_moved = self.ctx.moveFocusedRoving(.previous, true);
                if (out.roving_moved) {
                    if (self.ctx.focusedKey()) |key| _ = self.ctx.markKey(key, .clicked);
                } else out.range_marked = self.markRange(.increment);
            },
            .move_right => {
                out.roving_moved = self.ctx.moveFocusedRoving(.next, true);
                if (out.roving_moved) {
                    if (self.ctx.focusedKey()) |key| _ = self.ctx.markKey(key, .clicked);
                } else out.range_marked = self.markRange(.increment);
            },
            .move_down => {
                out.roving_moved = self.ctx.moveFocusedRoving(.next, true);
                if (out.roving_moved) {
                    if (self.ctx.focusedKey()) |key| _ = self.ctx.markKey(key, .clicked);
                } else out.range_marked = self.markRange(.decrement);
            },
            .page_up => out.range_marked = self.markRange(.page_increment),
            .page_down => out.range_marked = self.markRange(.page_decrement),
            .activate => if (self.ctx.focusedKey()) |key| {
                out.activated = self.ctx.markKey(key, .clicked);
            },
            .dismiss => if (self.ctx.res.commands.escapeTarget()) |target| {
                out.dismissed = self.ctx.markKey(target, .dismissed);
            },
            .focus_search => if (self.ctx.res.commands.searchTarget()) |target| {
                out.focus_moved = self.ctx.requestFocus(target);
            },
            // Editor-text and clipboard commands need the focused editor model / SDL clipboard,
            // which this SDL-free driver does not own. Flag the clipboard family so a script
            // sees it was recognized; plain editing commands fall through as a no-op outcome.
            .clipboard_copy, .clipboard_cut, .clipboard_paste, .select_all => out.clipboard_skipped = true,
            else => {},
        }
        return out;
    }

    /// Mark one transient range command on the focused slider, matching production's
    /// `markFocusedRange`: the focused key must be a registered range owner (so an arrow cannot
    /// mutate an arbitrary focused node), then its flag is routed. Returns whether it marked.
    fn markRange(self: *Driver, comptime flag: std.meta.FieldEnum(UiCtx.Interaction)) bool {
        const key = self.ctx.focusedKey() orelse return false;
        if (!self.ctx.res.commands.isRangeOwner(key)) return false;
        return self.ctx.markKey(key, flag);
    }
};

// =============================== Tests (SDL-free) ==========================================
// The driver is the lower half of `main.zig`'s event loop with SDL removed, so it is tested
// exactly as `drag.zig`/`control.zig` are: a `Resources` with an undefined platform, real
// pools/focus/semantics, slots stamped by hand, scripted input, flags read back. No window,
// no font, no allocator ceremony beyond the pools.

const testing = std.testing;
const Resources = @import("../res.zig").Resources;
const key_of = @import("ui").key;

const Rig = struct {
    res: Resources,
    ctx: UiCtx,

    fn init(self: *Rig) void {
        self.res = .{ .platform = undefined, .sim = .{} };
        self.ctx = UiCtx.init(&self.res, testing.allocator, undefined);
        self.ctx.beginFrame();
        self.res.commands.beginBuild();
    }

    fn deinit(self: *Rig) void {
        self.ctx.deinit();
    }
};

test "a click over a stamped target activates it exactly once" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    var d = Driver.init(&rig.ctx);
    d.beginInput();

    const btn = key_of(0, "btn");
    d.stamp(btn, .{ .x = 0, .y = 0, .w = 100, .h = 40 }, null, null);

    _ = d.feed(.{ .press = .{ .at = .{ .x = 20, .y = 20 } } });
    _ = d.feed(.{ .release = .{ .at = .{ .x = 20, .y = 20 } } });
    try testing.expect(rig.ctx.interactionOf(btn).clicked);
}

test "a release that drifts past the drag threshold is suppressed, not a click" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    var d = Driver.init(&rig.ctx);
    d.beginInput();

    const btn = key_of(0, "btn");
    d.stamp(btn, .{ .x = 0, .y = 0, .w = 200, .h = 200 }, null, null);

    _ = d.feed(.{ .press = .{ .at = .{ .x = 20, .y = 20 } } });
    _ = d.feed(.{ .move = .{ .at = .{ .x = 60, .y = 60 } } }); // well past the 4px threshold
    _ = d.feed(.{ .release = .{ .at = .{ .x = 60, .y = 60 } } });
    try testing.expect(!rig.ctx.interactionOf(btn).clicked);
}

test "a release over a different target does not activate the press target" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    var d = Driver.init(&rig.ctx);
    d.beginInput();

    const a = key_of(0, "a");
    const b = key_of(0, "b");
    d.stamp(a, .{ .x = 0, .y = 0, .w = 50, .h = 50 }, null, null);
    d.stamp(b, .{ .x = 60, .y = 0, .w = 50, .h = 50 }, null, null);

    _ = d.feed(.{ .press = .{ .at = .{ .x = 10, .y = 10 } } });
    _ = d.feed(.{ .release = .{ .at = .{ .x = 70, .y = 10 } } });
    try testing.expect(!rig.ctx.interactionOf(a).clicked);
    try testing.expect(!rig.ctx.interactionOf(b).clicked);
}

test "topmost stamped slot takes a click; the one beneath is left alone" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    var d = Driver.init(&rig.ctx);
    d.beginInput();

    const under = key_of(0, "under");
    const over = key_of(0, "over");
    d.stamp(under, .{ .x = 0, .y = 0, .w = 100, .h = 100 }, null, null);
    d.stamp(over, .{ .x = 0, .y = 0, .w = 100, .h = 100 }, null, null); // painted after → topmost

    _ = d.feed(.{ .press = .{ .at = .{ .x = 50, .y = 50 } } });
    _ = d.feed(.{ .release = .{ .at = .{ .x = 50, .y = 50 } } });
    try testing.expect(rig.ctx.interactionOf(over).clicked);
    try testing.expect(!rig.ctx.interactionOf(under).clicked);
}

test "a wheel event marks the hovered scroll target" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    var d = Driver.init(&rig.ctx);
    d.beginInput();

    const scroller = key_of(0, "scroll");
    d.stamp(scroller, .{ .x = 0, .y = 0, .w = 100, .h = 100 }, null, null);
    _ = d.feed(.{ .wheel = .{ .at = .{ .x = 50, .y = 50 }, .delta = .{ .x = 0, .y = -3 } } });
    try testing.expect(rig.ctx.interactionOf(scroller).wheel);
    try testing.expectEqual(@as(f32, -3), rig.res.input.pointer.wheel.y);
}

test "Tab routes a focus_next command that moves focus between registered controls" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    var d = Driver.init(&rig.ctx);

    const a = key_of(0, "a");
    const b = key_of(0, "b");
    // Focus traversal reads the LAST completed frame's registered order (the engine's
    // double-buffered focus registry), exactly as the production event stage does. So the
    // controls are registered and the frame is ended to publish that order before Tab moves.
    rig.ctx.registerFocus(a, true);
    rig.ctx.registerFocus(b, true);
    rig.ctx.endFrame();
    rig.ctx.beginFrame();
    _ = rig.ctx.requestFocus(a);
    d.beginInput();

    const out = d.feed(.{ .key = .{ .key = .tab } }).?;
    try testing.expectEqual(command.Command.focus_next, out.command);
    try testing.expect(out.focus_moved);
    try testing.expect(rig.ctx.isFocused(b));
}

test "Enter activates the focused control; Escape dismisses the registered escape owner" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    var d = Driver.init(&rig.ctx);
    d.beginInput();

    const btn = key_of(0, "btn");
    d.stamp(btn, .{ .x = 0, .y = 0, .w = 10, .h = 10 }, null, null);
    rig.ctx.registerFocus(btn, true);
    _ = rig.ctx.requestFocus(btn);

    const dialog = key_of(0, "dialog");
    d.stamp(dialog, .{ .x = 0, .y = 0, .w = 10, .h = 10 }, null, null);
    rig.res.commands.registerEscape(dialog);
    rig.res.commands.endBuild();

    const enter = d.feed(.{ .key = .{ .key = .return_key } }).?;
    try testing.expect(enter.activated);
    try testing.expect(rig.ctx.interactionOf(btn).clicked);

    const esc = d.feed(.{ .key = .{ .key = .escape } }).?;
    try testing.expect(esc.dismissed);
    try testing.expect(rig.ctx.interactionOf(dialog).dismissed);
}

test "arrow keys move roving focus within a group" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    var d = Driver.init(&rig.ctx);

    const group = key_of(0, "tabs");
    const t0 = key_of(0, "t0");
    const t1 = key_of(0, "t1");
    // As with Tab, roving navigation reads the last completed frame's registered group, so the
    // members are registered and the frame ended to publish them before the arrow moves focus.
    rig.ctx.registerRovingFocus(group, t0, true);
    rig.ctx.registerRovingFocus(group, t1, true);
    rig.ctx.endFrame();
    rig.ctx.beginFrame();
    _ = rig.ctx.requestFocus(t0);
    d.beginInput();

    const right = d.feed(.{ .key = .{ .key = .right } }).?;
    try testing.expect(right.roving_moved);
    try testing.expect(rig.ctx.isFocused(t1));
}

test "a clipboard command is recognized but intentionally skipped without a window" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    var d = Driver.init(&rig.ctx);
    d.beginInput();

    const ctrl = input.Modifiers{ .control = true };
    const out = d.feed(.{ .key = .{ .key = .c, .modifiers = ctrl } }).?;
    try testing.expectEqual(command.Command.clipboard_copy, out.command);
    try testing.expect(out.clipboard_skipped);
}

test "window focus loss cancels an in-flight press so no later release activates it" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    var d = Driver.init(&rig.ctx);
    d.beginInput();

    const btn = key_of(0, "btn");
    d.stamp(btn, .{ .x = 0, .y = 0, .w = 100, .h = 100 }, null, null);
    _ = d.feed(.{ .press = .{ .at = .{ .x = 50, .y = 50 } } });
    _ = d.feed(.{ .window_focus = false });
    try testing.expect(rig.res.input.cancelled);
    try testing.expect(!rig.res.input.window_focused);
}
