const std = @import("std");
const sdl = @import("sdl3");
const hand = @import("./hand_cursor.zig");

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

/// The shapes the host draws itself because SDL 3 has no system cursor for them.
pub const Custom = enum { open_hand, closed_hand };

/// The custom shape `kind` shows, or null when a system cursor serves it.
pub fn customCursor(kind: Kind) ?Custom {
    return switch (kind) {
        .grab => .open_hand,
        .grabbing => .closed_hand,
        .default, .pointer, .text, .horizontal_resize, .not_allowed => null,
    };
}

/// The SDL system cursor for `kind`. For a custom kind it is the stand-in shown when the
/// custom cursor cannot be created: grab and grabbing both fall back to the four-way move.
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

/// Main-thread SDL cursor resources. A cursor SDL cannot create stays null: a custom hand
/// falls back to the move cursor, and anything else to the platform default, rather than
/// making application startup fail.
pub const PlatformCursors = struct {
    pointer: ?sdl.mouse.Cursor = null,
    text: ?sdl.mouse.Cursor = null,
    move: ?sdl.mouse.Cursor = null,
    horizontal_resize: ?sdl.mouse.Cursor = null,
    not_allowed: ?sdl.mouse.Cursor = null,
    open_hand: ?sdl.mouse.Cursor = null,
    closed_hand: ?sdl.mouse.Cursor = null,
    active: ?Kind = null,

    pub fn init() PlatformCursors {
        return .{
            .pointer = sdl.mouse.Cursor.initSystem(.pointer) catch null,
            .text = sdl.mouse.Cursor.initSystem(.text) catch null,
            .move = sdl.mouse.Cursor.initSystem(.move) catch null,
            .horizontal_resize = sdl.mouse.Cursor.initSystem(.east_west_resize) catch null,
            .not_allowed = sdl.mouse.Cursor.initSystem(.not_allowed) catch null,
            .open_hand = initHand(hand.open_hand),
            .closed_hand = initHand(hand.closed_hand),
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
        if (self.open_hand) |cursor| cursor.deinit();
        if (self.closed_hand) |cursor| cursor.deinit();
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
            .grab, .grabbing => self.drawn(customCursor(kind).?) orelse self.move orelse fallback,
            .horizontal_resize => self.horizontal_resize orelse fallback,
            .not_allowed => self.not_allowed orelse fallback,
        };
    }

    fn drawn(self: *const PlatformCursors, custom: Custom) ?sdl.mouse.Cursor {
        return switch (custom) {
            .open_hand => self.open_hand,
            .closed_hand => self.closed_hand,
        };
    }
};

/// A colour cursor from `art`, with its doubled image attached as the alternate SDL uses
/// on a 2x display; null when SDL cannot build it. A missing alternate leaves the 1x image,
/// which SDL scales.
fn initHand(comptime art: hand.Art) ?sdl.mouse.Cursor {
    const base = handSurface(art, 1) catch return null;
    // SDL_CreateColorCursor copies the images; the surfaces are ours to release.
    defer base.deinit();
    if (handSurface(art, 2)) |double| {
        defer double.deinit();
        base.addAlternateImage(double) catch {};
    } else |_| {}
    return sdl.mouse.Cursor.initColor(base, art.hot_x, art.hot_y) catch null;
}

fn handSurface(comptime art: hand.Art, comptime scale: usize) !sdl.surface.Surface {
    const side = hand.size * scale;
    const bytes = comptime hand.rgba(art, scale);
    const surface = try sdl.surface.Surface.init(side, side, sdl.pixels.Format.array_rgba_32);
    errdefer surface.deinit();
    const pixels = surface.getPixels() orelse return error.SurfaceNotWritable;
    const pitch = surface.getPitch();
    for (0..side) |y| {
        @memcpy(pixels[y * pitch ..][0 .. side * 4], bytes[y * side * 4 ..][0 .. side * 4]);
    }
    return surface;
}

test {
    _ = hand;
}

test "cursor requests reset to default and later hovered controls win" {
    var state: State = .{};
    state.request(.pointer);
    state.request(.text);
    try std.testing.expectEqual(Kind.text, state.requested);
    state.beginFrame();
    try std.testing.expectEqual(Kind.default, state.requested);
}

test "grab and grabbing are custom hands; every other kind is a system cursor" {
    try std.testing.expectEqual(@as(?Custom, .open_hand), customCursor(.grab));
    try std.testing.expectEqual(@as(?Custom, .closed_hand), customCursor(.grabbing));
    for ([_]Kind{ .default, .pointer, .text, .horizontal_resize, .not_allowed }) |kind| {
        try std.testing.expectEqual(@as(?Custom, null), customCursor(kind));
    }
}

test "cursor vocabulary maps to SDL system cursors, the hands falling back to move" {
    try std.testing.expectEqual(sdl.mouse.SystemCursor.default, systemCursor(.default));
    try std.testing.expectEqual(sdl.mouse.SystemCursor.pointer, systemCursor(.pointer));
    try std.testing.expectEqual(sdl.mouse.SystemCursor.text, systemCursor(.text));
    try std.testing.expectEqual(sdl.mouse.SystemCursor.move, systemCursor(.grab));
    try std.testing.expectEqual(sdl.mouse.SystemCursor.move, systemCursor(.grabbing));
    try std.testing.expectEqual(sdl.mouse.SystemCursor.east_west_resize, systemCursor(.horizontal_resize));
    try std.testing.expectEqual(sdl.mouse.SystemCursor.not_allowed, systemCursor(.not_allowed));
}
