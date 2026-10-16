//! Host input routing — the policy that turns the frame input model (`input.zig`) into
//! engine interaction flags, focus moves, and editor mutations. SDL-free: the desktop
//! loop translates SDL events into `Resources.input` and calls the `Router` as each event
//! arrives, and a replay script (`replay.zig`) drives the same entry points without a
//! window, so one routing policy serves both.
//!
//! The router owns three things the engine deliberately does not: `PointerActivation`
//! (press → one `.clicked` on a matching release, suppressed by drag/cancel/mismatch),
//! keyboard `Command` dispatch (traversal, roving movement, activation, Escape
//! precedence, slash search, editing into the registered text owner), and the resize
//! ghost guard (`geometry_stale`). Everything it marks goes through the engine's
//! capture-aware, paint-ordered `markTarget`/`markKey`, so overlays occlude by construction.
//!
//! Platform services the routing needs — the clipboard and ending the platform text-input
//! session — are reached through `Platform`, an injectable vtable; `Platform.none` is the
//! inert default a headless test uses.
//!
//! The field→editor seam and the modal search guard follow current host policy: the
//! focused editor is resolved through the command registry's `editorKeyOf` indirection (a
//! field may delegate its model to an always-built owner key), and the slash search
//! shortcut is suppressed while an Escape owner (an open modal) traps focus, so `/` can
//! never jump focus to a catalog field behind the trap.

const std = @import("std");
const cb = @import("ctx_binding.zig");
const input_mod = @import("input.zig");
const activation = @import("activation.zig");
const command = @import("command.zig");

pub const UiCtx = cb.UiCtx;
pub const Input = input_mod.Input;
pub const Point = input_mod.Point;
pub const PointerKind = input_mod.PointerKind;
pub const Command = command.Command;
pub const TextInputState = cb.UiState.TextInputState;

/// Platform services behind an injectable seam. The SDL host binds the clipboard and
/// `stopTextInput`; `none` is inert (no clipboard text, writes refused, nothing to stop).
pub const Platform = struct {
    ctx: ?*anyopaque = null,
    vtable: *const VTable = &none_vtable,

    pub const VTable = struct {
        /// Copy the clipboard text into `buf` and return the copied bytes, or null when the
        /// clipboard holds no text. A text longer than `buf` returns the full-buffer prefix.
        clipboard_read: *const fn (ctx: ?*anyopaque, buf: []u8) ?[]const u8,
        /// Place NUL-terminated text on the clipboard; returns whether the platform took it.
        clipboard_write: *const fn (ctx: ?*anyopaque, text: [:0]const u8) bool,
        /// End the platform text-input session (IME / on-screen keyboard) because no text
        /// owner holds focus any more.
        stop_text_input: *const fn (ctx: ?*anyopaque) void,
    };

    pub const none: Platform = .{};

    const none_vtable: VTable = .{
        .clipboard_read = noneRead,
        .clipboard_write = noneWrite,
        .stop_text_input = noneStop,
    };

    fn noneRead(_: ?*anyopaque, _: []u8) ?[]const u8 {
        return null;
    }
    fn noneWrite(_: ?*anyopaque, _: [:0]const u8) bool {
        return false;
    }
    fn noneStop(_: ?*anyopaque) void {}

    pub fn clipboardRead(self: Platform, buf: []u8) ?[]const u8 {
        return self.vtable.clipboard_read(self.ctx, buf);
    }
    pub fn clipboardWrite(self: Platform, text: [:0]const u8) bool {
        return self.vtable.clipboard_write(self.ctx, text);
    }
    pub fn stopTextInput(self: Platform) void {
        self.vtable.stop_text_input(self.ctx);
    }
};

/// What routing one `Command` did: whether anything consumed it, and whether this
/// frame's text bytes must be dropped (a shortcut's own byte, a clipboard chord).
pub const CommandRoute = struct {
    handled: bool = false,
    suppress_text: bool = false,
};

pub const Router = struct {
    ui: *UiCtx,
    platform: Platform = .none,
    activation: activation.PointerActivation = .{},
    /// Set when the window resizes, cleared once the frame re-stamps geometry. While set,
    /// pointer activation is suppressed so a click cannot land on the previous frame's
    /// now-stale stamped rects (the "one-frame clickable ghost").
    geometry_stale: bool = false,

    pub fn init(ui: *UiCtx, platform: Platform) Router {
        return .{ .ui = ui, .platform = platform };
    }

    // ---- pointer events, routed in arrival order against prior stamped geometry ----

    /// Primary pointer down: route transient `.pressed` to the capture-aware target and
    /// begin an activation on it. Begins nothing while geometry is stale — a press this
    /// frame would target the previous size's rects.
    pub fn pointerPress(self: *Router, kind: PointerKind, id: ?u64, position: Point) void {
        if (self.geometry_stale) return;
        const target = self.ui.markTarget(.pressed, position.x, position.y);
        self.activation.press(target, kind, id, position);
    }

    /// Pointer motion: advance the drag classification and republish `.dragging` on the
    /// pressed key once the threshold is crossed.
    pub fn pointerMotion(self: *Router, kind: PointerKind, id: ?u64, position: Point) void {
        self.activation.motion(kind, id, position);
        if (self.activation.draggingKey()) |key| {
            _ = self.ui.markKey(key, .dragging);
        }
    }

    /// Primary pointer up: route `.released` through capture, then complete the activation
    /// as one `.clicked` only when the geometric topmost key is still the pressed key.
    /// While geometry is stale from a resize the in-flight gesture is cancelled instead of
    /// routing a release/click to the previous frame's rects.
    pub fn pointerRelease(self: *Router, kind: PointerKind, id: ?u64, position: Point) void {
        if (self.geometry_stale) {
            self.cancelGesture();
            return;
        }
        self.pointerMotion(kind, id, position);
        _ = self.ui.markTarget(.released, position.x, position.y);
        const target = self.ui.targetAt(position.x, position.y);
        if (self.activation.release(target, kind, id, position)) |key| {
            _ = self.ui.markKey(key, .clicked);
        }
    }

    /// A wheel event: route transient `.wheel` at its own pointer position. The frame
    /// model accumulates the delta; the targeted scroll region reads it during the build.
    pub fn wheel(self: *Router, position: Point) void {
        self.ui.mark(.wheel, position.x, position.y);
    }

    /// Drop the in-flight activation and engine pointer capture (platform/touch
    /// cancellation, window-focus loss, resize).
    pub fn cancelGesture(self: *Router) void {
        self.activation.cancel();
        self.ui.cancelPointerCapture();
    }

    /// The window lost focus: cancel the gesture and end the platform text-input session.
    /// The input model's own focus-loss edge (`Input.setWindowFocus`) is the caller's.
    pub fn windowFocusLost(self: *Router) void {
        self.cancelGesture();
        self.platform.stopTextInput();
    }

    /// The window resized: this frame's stamped rects are the previous size's, so mark
    /// geometry stale and cancel any gesture so it cannot complete against them.
    pub fn geometryChanged(self: *Router) void {
        self.geometry_stale = true;
        self.cancelGesture();
    }

    /// Geometry was re-stamped at the current size; the next event stage may route
    /// activation again. The frame driver calls this right after stamping.
    pub fn geometryStamped(self: *Router) void {
        self.geometry_stale = false;
    }

    // ---- per-frame routing, after every event of the frame has been recorded ----

    /// The frame-level pass over the completed input model: republish held/dragging/
    /// captured on their owners, dispatch every key event as a `Command`, feed the frame's
    /// text bytes into the focused registered editor unless a command suppressed them,
    /// and mark hover at the pointer position. Runs before `beginFrame`, so every mark
    /// lands on the prior frame's stamped slots.
    pub fn routeFrame(self: *Router, input: *const Input) void {
        self.publishPointerVisualState(input);
        const suppress_text = self.routeKeyboardCommands(input);
        if (!suppress_text) if (self.focusedEditor()) |ed| {
            const text = input.text();
            if (text.len > 0) {
                // The editor enforces UTF-8 / single-line admissibility and the explicit
                // max query length, refusing oversized or incompatible text as a whole and
                // raising its non-silent `refused` flag for the widget to surface.
                _ = ed.insert(text);
            }
        };
        self.ui.mark(.hovering, input.pointer.position.x, input.pointer.position.y);
    }

    /// Republish the transient pointer facts: `held` on the stable press key while primary
    /// stays down, `dragging` once the threshold is crossed, `captured` on the exact owner.
    pub fn publishPointerVisualState(self: *Router, input: *const Input) void {
        if (input.pointer.buttons.primary.held) {
            if (self.activation.pressedKey()) |key| {
                _ = self.ui.markKey(key, .held);
            }
        }
        if (self.activation.draggingKey()) |key| {
            _ = self.ui.markKey(key, .dragging);
        }
        if (self.ui.capturedPointerKey()) |key| {
            self.ui.setFlag(key, .captured, true);
        }
    }

    /// Dispatch every key event of the frame in order; returns whether any routed command
    /// suppresses this frame's text bytes.
    pub fn routeKeyboardCommands(self: *Router, input: *const Input) bool {
        var suppress_text = false;
        for (input.keyEvents()) |event| {
            const cmd = command.fromKeyEvent(event) orelse continue;
            const routed = self.routeCommand(cmd);
            suppress_text = suppress_text or routed.suppress_text;
        }
        return suppress_text;
    }

    /// The authoritative editor model for the currently focused text owner, or null when
    /// the focused control is not a registered text field. The field registers which key
    /// holds its model (itself, or an always-built owner) through `editorKeyOf`; routing
    /// only *drives* this model — every editing rule lives in `editor.zig`.
    pub fn focusedEditor(self: *Router) ?*TextInputState {
        const key = self.ui.focusedKey() orelse return null;
        const editor_key = self.ui.res.commands.editorKeyOf(key) orelse return null;
        const idx = self.ui.cache(editor_key, TextInputState);
        return self.ui.pool(TextInputState).get(idx);
    }

    /// Mark one transient range command on the focused slider. The command registry is
    /// built from the prior UI frame, matching focus/text routing: a key is eligible only
    /// while its slider is still live and registered, so arrows cannot mutate an arbitrary
    /// focused node.
    fn markFocusedRange(self: *Router, comptime flag: std.meta.FieldEnum(UiCtx.Interaction)) bool {
        const key = self.ui.focusedKey() orelse return false;
        if (!self.ui.res.commands.isRangeOwner(key)) return false;
        return self.ui.markKey(key, flag);
    }

    /// Copy the current selection to the platform clipboard when both a selection and a
    /// clipboard exist. Returns whether the platform accepted the text. The editor slice is
    /// only valid until the next mutation, so it is NUL-terminated into a stack buffer first.
    fn copySelectionToClipboard(self: *Router, ed: *TextInputState) bool {
        if (!ed.hasSelection()) return false;
        const sel = ed.selectionSlice();
        var tmp: [TextInputState.max_query_bytes + 1]u8 = undefined;
        if (sel.len > tmp.len - 1) return false;
        @memcpy(tmp[0..sel.len], sel);
        tmp[sel.len] = 0;
        return self.platform.clipboardWrite(tmp[0..sel.len :0]);
    }

    /// Paste the clipboard into the editor through its whole-text validation. The probe
    /// buffer is one byte longer than the editor's maximum: any text that overruns it is
    /// over the maximum regardless of its tail, so the editor refuses the prefix exactly as
    /// it would refuse the whole — nothing inserted, `refused` raised.
    fn pasteFromClipboard(self: *Router, ed: *TextInputState) void {
        var buf: [TextInputState.max_query_bytes + 1]u8 = undefined;
        const clip = self.platform.clipboardRead(&buf) orelse return;
        _ = ed.insert(clip);
    }

    pub fn routeCommand(self: *Router, cmd: Command) CommandRoute {
        const ui = self.ui;
        switch (cmd) {
            .focus_next => return .{ .handled = ui.moveFocus(.next, true) },
            .focus_previous => return .{ .handled = ui.moveFocus(.previous, true) },
            .move_left => {
                const moved = ui.moveFocusedRoving(.previous, true);
                if (moved) {
                    if (ui.focusedKey()) |key| _ = ui.markKey(key, .clicked);
                }
                return .{ .handled = moved or self.markFocusedRange(.decrement) };
            },
            .move_right => {
                const moved = ui.moveFocusedRoving(.next, true);
                if (moved) {
                    if (ui.focusedKey()) |key| _ = ui.markKey(key, .clicked);
                }
                return .{ .handled = moved or self.markFocusedRange(.increment) };
            },
            .move_up => {
                const moved = ui.moveFocusedRoving(.previous, true);
                if (moved) {
                    if (ui.focusedKey()) |key| _ = ui.markKey(key, .clicked);
                }
                return .{ .handled = moved or self.markFocusedRange(.increment) };
            },
            .move_down => {
                const moved = ui.moveFocusedRoving(.next, true);
                if (moved) {
                    if (ui.focusedKey()) |key| _ = ui.markKey(key, .clicked);
                }
                return .{ .handled = moved or self.markFocusedRange(.decrement) };
            },
            .page_up => return .{ .handled = self.markFocusedRange(.page_increment) },
            .page_down => return .{ .handled = self.markFocusedRange(.page_decrement) },
            .activate => {
                const key = ui.focusedKey() orelse return .{};
                return .{ .handled = ui.markKey(key, .clicked) };
            },
            .dismiss => {
                // A focused text owner consumes Escape first; otherwise the topmost
                // registered overlay/view receives transient `.dismissed`. Unhandled
                // Escape never quits.
                if (ui.focusedKey()) |key| {
                    if (ui.res.commands.isTextOwner(key)) {
                        ui.clearFocus();
                        self.platform.stopTextInput();
                        return .{ .handled = true };
                    }
                }
                const target = ui.res.commands.escapeTarget() orelse return .{};
                return .{ .handled = ui.markKey(target, .dismissed) };
            },
            .focus_search => {
                // An open modal owns focus. Do not let `/` move focus to a catalog field
                // behind its trap; consume the shortcut until the topmost Escape owner closes.
                if (ui.res.commands.escapeTarget() != null) return .{ .handled = true, .suppress_text = true };
                const target = ui.res.commands.searchTarget() orelse return .{};
                const handled = ui.requestFocus(target);
                return .{ .handled = handled, .suppress_text = handled };
            },
            .delete_backward => {
                const ed = self.focusedEditor() orelse return .{};
                _ = ed.deleteBackward();
                return .{ .handled = true };
            },
            .delete_forward => {
                const ed = self.focusedEditor() orelse return .{};
                _ = ed.deleteForward();
                return .{ .handled = true };
            },
            .line_start => {
                if (self.focusedEditor()) |ed| {
                    ed.home(false);
                    return .{ .handled = true };
                }
                return .{ .handled = self.markFocusedRange(.minimum) };
            },
            .line_end => {
                if (self.focusedEditor()) |ed| {
                    ed.end(false);
                    return .{ .handled = true };
                }
                return .{ .handled = self.markFocusedRange(.maximum) };
            },
            .select_left => {
                const ed = self.focusedEditor() orelse return .{};
                ed.moveLeft(true);
                return .{ .handled = true };
            },
            .select_right => {
                const ed = self.focusedEditor() orelse return .{};
                ed.moveRight(true);
                return .{ .handled = true };
            },
            .select_line_start => {
                const ed = self.focusedEditor() orelse return .{};
                ed.home(true);
                return .{ .handled = true };
            },
            .select_line_end => {
                const ed = self.focusedEditor() orelse return .{};
                ed.end(true);
                return .{ .handled = true };
            },
            .select_all => {
                const ed = self.focusedEditor() orelse return .{};
                ed.selectAll();
                return .{ .handled = true, .suppress_text = true };
            },
            .clipboard_copy => {
                const ed = self.focusedEditor() orelse return .{};
                _ = self.copySelectionToClipboard(ed);
                // Handled by the focused editor regardless: Ctrl+C must never fall through
                // to typing a 'c', even when there is nothing selected to copy.
                return .{ .handled = true, .suppress_text = true };
            },
            .clipboard_cut => {
                const ed = self.focusedEditor() orelse return .{};
                if (self.copySelectionToClipboard(ed)) _ = ed.deleteBackward(); // delete-selection
                return .{ .handled = true, .suppress_text = true };
            },
            .clipboard_paste => {
                const ed = self.focusedEditor() orelse return .{};
                self.pasteFromClipboard(ed);
                return .{ .handled = true, .suppress_text = true };
            },
            .clear_field => {
                const ed = self.focusedEditor() orelse return .{};
                _ = ed.clear();
                return .{ .handled = true, .suppress_text = true };
            },
        }
    }
};

// ============================ Tests ==========================================
// Pointer routing touches only the interaction pool, so `res`/`arena` stay `undefined`
// here exactly as in `ctx_binding`'s activation tests.

const ui_root = @import("ui");

fn stampControl(u: *UiCtx, key: u64, rect: ui_root.Rect) void {
    _ = u.interactionOf(key);
    _ = u.stampRect(key, rect, null, null);
}

test "press and matching release route one click through the engine targets" {
    var u = UiCtx.init(undefined, std.testing.allocator, undefined);
    defer u.deinit();
    u.beginFrame();
    const key = ui_root.key(0, "route-btn");
    stampControl(&u, key, .{ .x = 0, .y = 0, .w = 100, .h = 40 });

    var router = Router.init(&u, .none);
    router.pointerPress(.mouse, 1, .{ .x = 10, .y = 10 });
    try std.testing.expect(u.interactionOf(key).pressed);
    try std.testing.expect(!u.interactionOf(key).clicked);
    router.pointerRelease(.mouse, 1, .{ .x = 12, .y = 12 });
    try std.testing.expect(u.interactionOf(key).released);
    try std.testing.expect(u.interactionOf(key).clicked);
}

test "stale geometry begins no activation and a release while stale cancels the gesture" {
    var u = UiCtx.init(undefined, std.testing.allocator, undefined);
    defer u.deinit();
    u.beginFrame();
    const key = ui_root.key(0, "resized-btn");
    stampControl(&u, key, .{ .x = 0, .y = 0, .w = 100, .h = 40 });

    var router = Router.init(&u, .none);
    router.geometryChanged();
    try std.testing.expect(router.geometry_stale);
    router.pointerPress(.mouse, 1, .{ .x = 10, .y = 10 });
    try std.testing.expectEqual(@as(?u64, null), router.activation.pressedKey());
    try std.testing.expect(!u.interactionOf(key).pressed);

    // A gesture that began before the resize cannot complete against the old rects.
    router.geometryStamped();
    router.pointerPress(.mouse, 1, .{ .x = 10, .y = 10 });
    router.geometryChanged();
    router.pointerRelease(.mouse, 1, .{ .x = 10, .y = 10 });
    try std.testing.expect(!u.interactionOf(key).clicked);
    try std.testing.expectEqual(@as(?u64, null), router.activation.pressedKey());

    // Fresh geometry restores ordinary activation.
    router.geometryStamped();
    router.pointerPress(.mouse, 1, .{ .x = 10, .y = 10 });
    router.pointerRelease(.mouse, 1, .{ .x = 10, .y = 10 });
    try std.testing.expect(u.interactionOf(key).clicked);
}

test "window focus loss cancels the gesture and releases pointer capture" {
    var u = UiCtx.init(undefined, std.testing.allocator, undefined);
    defer u.deinit();
    u.beginFrame();
    const key = ui_root.key(0, "captured-thumb");
    stampControl(&u, key, .{ .x = 0, .y = 0, .w = 20, .h = 100 });

    var router = Router.init(&u, .none);
    router.pointerPress(.mouse, 1, .{ .x = 5, .y = 5 });
    try std.testing.expect(u.capturePointer(key));
    router.windowFocusLost();
    try std.testing.expectEqual(@as(?u64, null), router.activation.pressedKey());
    try std.testing.expectEqual(@as(?u64, null), u.capturedPointerKey());
    router.pointerRelease(.mouse, 1, .{ .x = 5, .y = 5 });
    try std.testing.expect(!u.interactionOf(key).clicked);
}
