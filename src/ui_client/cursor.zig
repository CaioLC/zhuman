const std = @import("std");
const sdl = @import("sdl3");

/// Host cursor vocabulary. Widgets request one during build; the last hovered control
/// built wins, matching paint order without leaking cursor meaning into the generic UI.
pub const Kind = enum {
    default,
    pointer,
    text,
    grab,
    grabbing,
    horizontal_resize,
    not_allowed,
};

pub const State = struct {
    requested: Kind = .default,

    pub fn beginFrame(self: *State) void {
        self.requested = .default;
    }

    pub fn request(self: *State, kind: Kind) void {
        self.requested = kind;
    }
};

/// SDL has no distinct grab/grabbing system cursors. Both deliberately degrade to its
/// four-way move cursor; every other contract cursor has a direct SDL equivalent.
pub fn systemCursor(kind: Kind) sdl.mouse.SystemCursor {
    return switch (kind) {
        .default => .default,
        .pointer => .pointer,
        .text => .text,
        .grab, .grabbing => .move,
        .horizontal_resize => .east_west_resize,
        .not_allowed => .not_allowed,
    };
}

/// Main-thread SDL cursor resources. Unsupported system cursors stay null and fall back
/// to the platform default rather than making application startup fail.
pub const PlatformCursors = struct {
    pointer: ?sdl.mouse.Cursor = null,
    text: ?sdl.mouse.Cursor = null,
    move: ?sdl.mouse.Cursor = null,
    horizontal_resize: ?sdl.mouse.Cursor = null,
    not_allowed: ?sdl.mouse.Cursor = null,
    active: ?Kind = null,

    pub fn init() PlatformCursors {
        return .{
            .pointer = sdl.mouse.Cursor.initSystem(.pointer) catch null,
            .text = sdl.mouse.Cursor.initSystem(.text) catch null,
            .move = sdl.mouse.Cursor.initSystem(.move) catch null,
            .horizontal_resize = sdl.mouse.Cursor.initSystem(.east_west_resize) catch null,
            .not_allowed = sdl.mouse.Cursor.initSystem(.not_allowed) catch null,
        };
    }

    pub fn deinit(self: *PlatformCursors) void {
        // Stop SDL from referring to a cursor before destroying our owned handles.
        sdl.mouse.set(sdl.mouse.getDefault() catch null) catch {};
        if (self.pointer) |cursor| cursor.deinit();
        if (self.text) |cursor| cursor.deinit();
        if (self.move) |cursor| cursor.deinit();
        if (self.horizontal_resize) |cursor| cursor.deinit();
        if (self.not_allowed) |cursor| cursor.deinit();
        self.* = .{};
    }

    pub fn apply(self: *PlatformCursors, kind: Kind) void {
        if (self.active == kind) return;
        sdl.mouse.set(self.forKind(kind)) catch return;
        self.active = kind;
    }

    fn forKind(self: *const PlatformCursors, kind: Kind) ?sdl.mouse.Cursor {
        const fallback = sdl.mouse.getDefault() catch null;
        return switch (kind) {
            .default => fallback,
            .pointer => self.pointer orelse fallback,
            .text => self.text orelse fallback,
            .grab, .grabbing => self.move orelse fallback,
            .horizontal_resize => self.horizontal_resize orelse fallback,
            .not_allowed => self.not_allowed orelse fallback,
        };
    }
};

test "cursor requests reset to default and later hovered controls win" {
    var state: State = .{};
    state.request(.pointer);
    state.request(.text);
    try std.testing.expectEqual(Kind.text, state.requested);
    state.beginFrame();
    try std.testing.expectEqual(Kind.default, state.requested);
}

test "cursor vocabulary maps to available SDL system cursors" {
    try std.testing.expectEqual(sdl.mouse.SystemCursor.default, systemCursor(.default));
    try std.testing.expectEqual(sdl.mouse.SystemCursor.pointer, systemCursor(.pointer));
    try std.testing.expectEqual(sdl.mouse.SystemCursor.text, systemCursor(.text));
    try std.testing.expectEqual(sdl.mouse.SystemCursor.move, systemCursor(.grab));
    try std.testing.expectEqual(sdl.mouse.SystemCursor.move, systemCursor(.grabbing));
    try std.testing.expectEqual(sdl.mouse.SystemCursor.east_west_resize, systemCursor(.horizontal_resize));
    try std.testing.expectEqual(sdl.mouse.SystemCursor.not_allowed, systemCursor(.not_allowed));
}
