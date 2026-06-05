const sdl3 = @import("sdl3");

pub const white: sdl3.ttf.Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };

/// Pure text-state data. Lives in the UI cache (one slot per text widget); the
/// rendering and measurement are wired by the widget layer (see widgets.zig),
/// keeping this module a leaf (no `ui`/`res` imports → no import cycle).
pub const TextData = struct {
    buf: [64]u8,
    len: usize,

    pub fn init() TextData {
        return .{ .buf = undefined, .len = 0 };
    }

    /// Copy `text` into the persistent buffer.
    pub fn update(self: *TextData, t: []const u8) void {
        const n = @min(t.len, self.buf.len);
        @memcpy(self.buf[0..n], t[0..n]);
        self.len = n;
    }

    /// The current text, reconstructed from `buf` + `len` at the call site.
    /// Returns `null` (renders nothing) when empty. Never store the result
    /// across a pool `acquire` — the slot may move; call this again instead.
    pub fn text(self: *const TextData) ?[]const u8 {
        return if (self.len == 0) null else self.buf[0..self.len];
    }
};
