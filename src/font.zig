//! The UI's monospace text backend: the TTF opened at whatever point sizes the style
//! system asks for, one cached `sdl.ttf.Font` per size.
//!
//! Why per-size fonts instead of one font resized on the fly: SDL_ttf keeps a glyph cache
//! *per font*, and `TTF_SetFontSize` **clears** it on every call — so a single mutated
//! font would thrash its cache the moment the HUD mixes body text with a heading. Caching
//! one font per (whole-point) size keeps each size's glyphs hot. Sizes are opened lazily
//! on first use and closed at `deinit`. `sdl.ttf.init()` must already have run.

const std = @import("std");
const sdl = @import("sdl3");

/// Default UI text size (px), used until the style system supplies a per-node font.
/// (Phase 3 folds this into the style layer's `DEFAULT_FONT`.)
pub const default_px: f32 = 24;

pub const Fonts = struct {
    path: [:0]const u8,
    gpa: std.mem.Allocator,
    /// whole-point size → the font opened at it. A handful of entries across a run.
    cache: std.AutoHashMapUnmanaged(u32, sdl.ttf.Font) = .{},

    /// Open the backend for `path` and warm the default size, so a missing font file
    /// errors here at startup (as it did when a single font was opened eagerly at setup).
    pub fn init(gpa: std.mem.Allocator, path: [:0]const u8) !Fonts {
        var self = Fonts{ .path = path, .gpa = gpa };
        _ = try self.at(default_px);
        return self;
    }

    pub fn deinit(self: *Fonts) void {
        var it = self.cache.valueIterator();
        while (it.next()) |f| f.deinit();
        self.cache.deinit(self.gpa);
    }

    /// The font opened at `px` (rounded to a whole point, min 1), opening + caching it on
    /// first use. Returned by value — `sdl.ttf.Font` is a thin handle (a `*TTF_Font`).
    pub fn at(self: *Fonts, px: f32) !sdl.ttf.Font {
        const size: u32 = @intFromFloat(@round(@max(1, px)));
        const gop = try self.cache.getOrPut(self.gpa, size);
        if (!gop.found_existing) {
            gop.value_ptr.* = try sdl.ttf.Font.init(self.path, @floatFromInt(size));
        }
        return gop.value_ptr.*;
    }

    /// Measure `text` at `px` — the intrinsic px extent the `content` size rule reads.
    pub fn measure(self: *Fonts, text: []const u8, px: f32) !struct { c_int, c_int } {
        return (try self.at(px)).getStringSize(text);
    }
};
