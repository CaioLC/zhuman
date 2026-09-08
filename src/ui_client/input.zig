const std = @import("std");
const sdl = @import("sdl3");

pub const Point = struct { x: f32 = 0, y: f32 = 0 };
pub const PointerKind = enum { mouse, touch, pen, unknown };
pub const PointerButton = enum { primary, middle, secondary, aux1, aux2 };
pub const KeyAction = enum { press, repeat, release };

pub const Modifiers = struct {
    shift: bool = false,
    control: bool = false,
    alt: bool = false,
    gui: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,
    scroll_lock: bool = false,
    mode: bool = false,
};

pub const ButtonState = struct {
    pressed: bool = false,
    held: bool = false,
    released: bool = false,
    clicks: u8 = 0,
    /// Stable down position for controls that acquire capture during the build stage.
    press_position: Point = .{},

    fn beginFrame(self: *ButtonState) void {
        self.pressed = false;
        self.released = false;
        self.clicks = 0;
    }
};

pub const Buttons = struct {
    primary: ButtonState = .{},
    middle: ButtonState = .{},
    secondary: ButtonState = .{},
    aux1: ButtonState = .{},
    aux2: ButtonState = .{},

    pub fn get(self: *Buttons, button: PointerButton) *ButtonState {
        return switch (button) {
            .primary => &self.primary,
            .middle => &self.middle,
            .secondary => &self.secondary,
            .aux1 => &self.aux1,
            .aux2 => &self.aux2,
        };
    }

    fn beginFrame(self: *Buttons) void {
        inline for (@typeInfo(Buttons).@"struct".fields) |field| @field(self, field.name).beginFrame();
    }
};

pub const Pointer = struct {
    position: Point = .{},
    delta: Point = .{},
    wheel: Point = .{},
    kind: PointerKind = .mouse,
    id: ?u64 = null,
    buttons: Buttons = .{},
};

pub const KeyEvent = struct {
    key: sdl.keycode.Keycode,
    action: KeyAction,
    modifiers: Modifiers,
};

pub const Input = struct {
    pub const max_key_events = 64;
    pub const max_held_keys = 32;
    pub const max_text_bytes = 256;

    pointer: Pointer = .{},
    modifiers: Modifiers = .{},
    key_events_buf: [max_key_events]KeyEvent = undefined,
    key_events_len: usize = 0,
    key_events_overflow: bool = false,
    held_keys_buf: [max_held_keys]sdl.keycode.Keycode = undefined,
    held_keys_len: usize = 0,
    held_keys_overflow: bool = false,
    text_buf: [max_text_bytes]u8 = undefined,
    text_len: usize = 0,
    text_overflow: bool = false,
    window_focused: bool = true,
    focus_gained: bool = false,
    focus_lost: bool = false,
    cancelled: bool = false,

    /// Reset every frame edge/event/delta in one place while preserving position,
    /// held buttons/keys, active pointer identity, modifiers, and window focus.
    pub fn beginFrame(self: *Input) void {
        self.pointer.delta = .{};
        self.pointer.wheel = .{};
        self.pointer.buttons.beginFrame();
        self.key_events_len = 0;
        self.key_events_overflow = false;
        self.held_keys_overflow = false;
        self.text_len = 0;
        self.text_overflow = false;
        self.focus_gained = false;
        self.focus_lost = false;
        self.cancelled = false;
    }

    pub fn keyEvents(self: *const Input) []const KeyEvent {
        return self.key_events_buf[0..self.key_events_len];
    }

    pub fn text(self: *const Input) []const u8 {
        return self.text_buf[0..self.text_len];
    }

    pub fn keyHeld(self: *const Input, key: sdl.keycode.Keycode) bool {
        return self.heldKeyIndex(key) != null;
    }

    pub fn recordMotion(self: *Input, kind: PointerKind, id: ?u64, position: Point, delta: Point) void {
        self.pointer.kind = kind;
        self.pointer.id = id;
        self.pointer.position = position;
        self.pointer.delta.x += delta.x;
        self.pointer.delta.y += delta.y;
    }

    pub fn syncButtonHeld(self: *Input, button: PointerButton, held: bool) void {
        self.pointer.buttons.get(button).held = held;
    }

    pub fn recordButton(self: *Input, kind: PointerKind, id: ?u64, button: PointerButton, down: bool, clicks: u8, position: Point) void {
        self.pointer.kind = kind;
        self.pointer.id = id;
        self.pointer.position = position;
        const state = self.pointer.buttons.get(button);
        if (down) {
            state.pressed = true;
            state.held = true;
            state.clicks = @max(state.clicks, clicks);
            state.press_position = position;
        } else {
            state.released = true;
            state.held = false;
            state.clicks = @max(state.clicks, clicks);
        }
    }

    pub fn recordWheel(self: *Input, kind: PointerKind, id: ?u64, position: Point, delta: Point) void {
        self.pointer.kind = kind;
        self.pointer.id = id;
        self.pointer.position = position;
        self.pointer.wheel.x += delta.x;
        self.pointer.wheel.y += delta.y;
    }

    pub fn recordKey(self: *Input, key: sdl.keycode.Keycode, action: KeyAction, modifiers: Modifiers) void {
        self.modifiers = modifiers;
        switch (action) {
            .press => self.addHeldKey(key),
            .repeat => if (!self.keyHeld(key)) self.addHeldKey(key),
            .release => self.removeHeldKey(key),
        }
        self.appendKeyEvent(.{ .key = key, .action = action, .modifiers = modifiers });
    }

    pub fn appendText(self: *Input, bytes: []const u8) void {
        const available = self.text_buf.len - self.text_len;
        const count = @min(available, bytes.len);
        @memcpy(self.text_buf[self.text_len..][0..count], bytes[0..count]);
        self.text_len += count;
        if (count != bytes.len) self.text_overflow = true;
    }

    pub fn setWindowFocus(self: *Input, focused: bool) void {
        if (focused == self.window_focused) return;
        self.window_focused = focused;
        if (focused) {
            self.focus_gained = true;
        } else {
            self.focus_lost = true;
            self.cancel();
        }
    }

    /// Cancel all held input, synthesizing release edges/events where capacity permits.
    pub fn cancel(self: *Input) void {
        self.cancelled = true;
        inline for (@typeInfo(Buttons).@"struct".fields) |field| {
            const button = &@field(self.pointer.buttons, field.name);
            if (button.held) button.released = true;
            button.held = false;
        }
        const mods = self.modifiers;
        for (self.held_keys_buf[0..self.held_keys_len]) |key| {
            self.appendKeyEvent(.{ .key = key, .action = .release, .modifiers = mods });
        }
        self.held_keys_len = 0;
        self.modifiers = .{};
    }

    fn appendKeyEvent(self: *Input, event: KeyEvent) void {
        if (self.key_events_len == self.key_events_buf.len) {
            self.key_events_overflow = true;
            return;
        }
        self.key_events_buf[self.key_events_len] = event;
        self.key_events_len += 1;
    }

    fn heldKeyIndex(self: *const Input, key: sdl.keycode.Keycode) ?usize {
        for (self.held_keys_buf[0..self.held_keys_len], 0..) |held, i| if (held == key) return i;
        return null;
    }

    fn addHeldKey(self: *Input, key: sdl.keycode.Keycode) void {
        if (self.keyHeld(key)) return;
        if (self.held_keys_len == self.held_keys_buf.len) {
            self.held_keys_overflow = true;
            return;
        }
        self.held_keys_buf[self.held_keys_len] = key;
        self.held_keys_len += 1;
    }

    fn removeHeldKey(self: *Input, key: sdl.keycode.Keycode) void {
        const i = self.heldKeyIndex(key) orelse return;
        self.held_keys_len -= 1;
        self.held_keys_buf[i] = self.held_keys_buf[self.held_keys_len];
    }
};

test "beginFrame clears edges and deltas while preserving held state and position" {
    var input: Input = .{};
    input.recordMotion(.mouse, 7, .{ .x = 20, .y = 30 }, .{ .x = 3, .y = -2 });
    input.recordButton(.mouse, 7, .primary, true, 2, .{ .x = 20, .y = 30 });
    input.recordWheel(.mouse, 7, .{ .x = 20, .y = 30 }, .{ .x = 1, .y = -4 });
    input.appendText("x");

    input.beginFrame();
    try std.testing.expectEqual(Point{ .x = 20, .y = 30 }, input.pointer.position);
    try std.testing.expect(input.pointer.buttons.primary.held);
    try std.testing.expectEqual(Point{ .x = 20, .y = 30 }, input.pointer.buttons.primary.press_position);
    try std.testing.expect(!input.pointer.buttons.primary.pressed);
    try std.testing.expect(!input.pointer.buttons.primary.released);
    try std.testing.expectEqual(@as(u8, 0), input.pointer.buttons.primary.clicks);
    try std.testing.expectEqual(Point{}, input.pointer.delta);
    try std.testing.expectEqual(Point{}, input.pointer.wheel);
    try std.testing.expectEqual(@as(usize, 0), input.text().len);
}

test "pointer accumulates motion wheel and press release edges" {
    var input: Input = .{};
    input.recordMotion(.pen, 42, .{ .x = 10, .y = 12 }, .{ .x = 2, .y = 3 });
    input.recordMotion(.pen, 42, .{ .x = 15, .y = 10 }, .{ .x = 5, .y = -2 });
    input.recordWheel(.pen, 42, .{ .x = 15, .y = 10 }, .{ .x = 1.5, .y = -2 });
    input.recordWheel(.pen, 42, .{ .x = 15, .y = 10 }, .{ .x = 0.5, .y = 3 });
    input.recordButton(.pen, 42, .primary, true, 2, .{ .x = 15, .y = 10 });
    input.recordButton(.pen, 42, .primary, false, 2, .{ .x = 15, .y = 10 });

    try std.testing.expectEqual(.pen, input.pointer.kind);
    try std.testing.expectEqual(@as(?u64, 42), input.pointer.id);
    try std.testing.expectEqual(Point{ .x = 7, .y = 1 }, input.pointer.delta);
    try std.testing.expectEqual(Point{ .x = 2, .y = 1 }, input.pointer.wheel);
    try std.testing.expect(input.pointer.buttons.primary.pressed);
    try std.testing.expect(input.pointer.buttons.primary.released);
    try std.testing.expect(!input.pointer.buttons.primary.held);
    try std.testing.expectEqual(@as(u8, 2), input.pointer.buttons.primary.clicks);
}

test "key events track press repeat release held state and modifiers" {
    var input: Input = .{};
    const mods = Modifiers{ .shift = true, .control = true };
    input.recordKey(.a, .press, mods);
    input.recordKey(.a, .repeat, mods);
    try std.testing.expect(input.keyHeld(.a));
    input.recordKey(.a, .release, .{});
    try std.testing.expect(!input.keyHeld(.a));
    try std.testing.expectEqual(@as(usize, 3), input.keyEvents().len);
    try std.testing.expectEqual(KeyAction.press, input.keyEvents()[0].action);
    try std.testing.expectEqual(KeyAction.repeat, input.keyEvents()[1].action);
    try std.testing.expectEqual(KeyAction.release, input.keyEvents()[2].action);
    try std.testing.expect(input.keyEvents()[0].modifiers.shift);

    input.beginFrame();
    try std.testing.expectEqual(@as(usize, 0), input.keyEvents().len);
}

test "text is copied and overflow is explicit" {
    var input: Input = .{};
    input.appendText("hello ");
    input.appendText("world");
    try std.testing.expectEqualStrings("hello world", input.text());
    var large: [Input.max_text_bytes]u8 = @splat('x');
    input.appendText(&large);
    try std.testing.expect(input.text_overflow);
    try std.testing.expectEqual(Input.max_text_bytes, input.text().len);
}

test "focus loss cancels held pointer and keyboard state" {
    var input: Input = .{};
    input.recordButton(.touch, 9, .primary, true, 1, .{ .x = 4, .y = 5 });
    input.recordKey(.left_shift, .press, .{ .shift = true });
    input.setWindowFocus(false);

    try std.testing.expect(input.focus_lost);
    try std.testing.expect(input.cancelled);
    try std.testing.expect(!input.window_focused);
    try std.testing.expect(!input.pointer.buttons.primary.held);
    try std.testing.expect(input.pointer.buttons.primary.released);
    try std.testing.expect(!input.keyHeld(.left_shift));
    try std.testing.expectEqual(KeyAction.release, input.keyEvents()[1].action);
    try std.testing.expect(!input.modifiers.shift);

    input.beginFrame();
    input.setWindowFocus(true);
    try std.testing.expect(input.focus_gained);
    try std.testing.expect(input.window_focused);
}
