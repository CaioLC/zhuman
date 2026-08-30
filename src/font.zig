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

pub const Fonts = struct {
    path: [:0]const u8,
    gpa: std.mem.Allocator,
    /// whole-point size → the font opened at it. A handful of entries across a run.
    cache: std.AutoHashMapUnmanaged(u32, sdl.ttf.Font) = .{},

    /// Open the backend for `path` and warm one size, so a missing font file errors here
    /// at startup rather than at the first blit. Which size to warm is the caller's call
    /// (`ui_client.style.default_font` is the one every unstyled node uses) — this module
    /// is the backend and owns no typography.
    pub fn init(gpa: std.mem.Allocator, path: [:0]const u8, warm_px: f32) !Fonts {
        var self = Fonts{ .path = path, .gpa = gpa };
        _ = try self.at(warm_px);
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

    /// Like `measure`, plus the cross-axis alignment **baseline** — the px offset of the
    /// text baseline up from the box's bottom edge (= the font's descent). Stored on
    /// `Size.baseline` so a `.horizontal` row can baseline-align mixed sizes; kept next to
    /// the size measure so the two never drift when a heading re-measures at a new px.
    pub fn measureBaseline(self: *Fonts, text: []const u8, px: f32) !struct { c_int, c_int, f32 } {
        const f = try self.at(px);
        const w, const h = try f.getStringSize(text);
        // ascent = baseline→top (positive). baseline-from-bottom = box height − ascent.
        const baseline = @as(f32, @floatFromInt(h)) - @as(f32, @floatFromInt(f.getAscent()));
        return .{ w, h, baseline };
    }
};
