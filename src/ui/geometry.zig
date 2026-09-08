//! Pure geometry primitives for the UI engine. No platform or userland deps —
//! the caller supplies coordinates; the engine never reaches into `Resources`.

const std = @import("std");

pub const Point = struct {
    x: f32 = 0,
    y: f32 = 0,
};

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    /// Inclusive point-in-rect test. The caller passes the point; interpreting
    /// *where* the point came from (mouse, touch, …) is userland's concern.
    pub fn contains(self: Rect, x: f32, y: f32) bool {
        return x >= self.x and x <= self.x + self.w and
            y >= self.y and y <= self.y + self.h;
    }

    /// Translate a global point into pixel coordinates relative to this rect's origin.
    pub fn globalToLocalPoint(self: Rect, point: Point) Point {
        return .{ .x = point.x - self.x, .y = point.y - self.y };
    }

    /// Translate a pixel-local point from this rect's origin into global coordinates.
    pub fn localToGlobalPoint(self: Rect, point: Point) Point {
        return .{ .x = point.x + self.x, .y = point.y + self.y };
    }

    /// Translate a global rect into this rect's pixel-local space; size is unchanged.
    pub fn globalToLocalRect(self: Rect, rect: Rect) Rect {
        return .{ .x = rect.x - self.x, .y = rect.y - self.y, .w = rect.w, .h = rect.h };
    }

    /// Translate a pixel-local rect into global space; size is unchanged.
    pub fn localToGlobalRect(self: Rect, rect: Rect) Rect {
        return .{ .x = rect.x + self.x, .y = rect.y + self.y, .w = rect.w, .h = rect.h };
    }

    /// The overlapping region of `self` and `other`. Non-overlapping inputs collapse to
    /// a zero-area rect (`w`/`h` floored at 0) rather than going negative — used to nest
    /// clip regions (a scroll viewport inside another) without a special not-visible case.
    pub fn intersect(self: Rect, other: Rect) Rect {
        const x0 = @max(self.x, other.x);
        const y0 = @max(self.y, other.y);
        const x1 = @min(self.x + self.w, other.x + other.w);
        const y1 = @min(self.y + self.h, other.y + other.h);
        return .{ .x = x0, .y = y0, .w = @max(0, x1 - x0), .h = @max(0, y1 - y0) };
    }
};

/// A node's last stamped global box and inherited global clip. Translation helpers use
/// pixel-local coordinates; no scale is implied. `clip == null` means no ancestor clip.
pub const Geometry = struct {
    rect: Rect,
    clip: ?Rect = null,

    pub fn globalToLocalPoint(self: Geometry, point: Point) Point {
        return self.rect.globalToLocalPoint(point);
    }

    pub fn localToGlobalPoint(self: Geometry, point: Point) Point {
        return self.rect.localToGlobalPoint(point);
    }

    pub fn globalToLocalRect(self: Geometry, rect: Rect) Rect {
        return self.rect.globalToLocalRect(rect);
    }

    pub fn localToGlobalRect(self: Geometry, rect: Rect) Rect {
        return self.rect.localToGlobalRect(rect);
    }

    /// The globally visible/hittable part of the node's own box.
    pub fn effectiveClipGlobal(self: Geometry) Rect {
        return if (self.clip) |clip| self.rect.intersect(clip) else self.rect;
    }

    /// `effectiveClipGlobal` translated into this node's pixel-local space.
    pub fn effectiveClipLocal(self: Geometry) Rect {
        return self.globalToLocalRect(self.effectiveClipGlobal());
    }
};

test "point and rect transforms round trip through pixel-local space" {
    const frame = Rect{ .x = 120, .y = -30, .w = 300, .h = 180 };
    const global_point = Point{ .x = 155, .y = 12 };
    const local_point = frame.globalToLocalPoint(global_point);
    try std.testing.expectEqual(Point{ .x = 35, .y = 42 }, local_point);
    try std.testing.expectEqual(global_point, frame.localToGlobalPoint(local_point));

    const global_rect = Rect{ .x = 140, .y = -10, .w = 80, .h = 25 };
    const local_rect = frame.globalToLocalRect(global_rect);
    try std.testing.expectEqual(Rect{ .x = 20, .y = 20, .w = 80, .h = 25 }, local_rect);
    try std.testing.expectEqual(global_rect, frame.localToGlobalRect(local_rect));
}

test "geometry exposes effective clip in global and local coordinates" {
    const unclipped = Geometry{ .rect = .{ .x = 100, .y = 50, .w = 80, .h = 40 } };
    try std.testing.expectEqual(unclipped.rect, unclipped.effectiveClipGlobal());
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 80, .h = 40 }, unclipped.effectiveClipLocal());

    const clipped = Geometry{
        .rect = .{ .x = 100, .y = 50, .w = 80, .h = 40 },
        .clip = .{ .x = 120, .y = 40, .w = 30, .h = 30 },
    };
    try std.testing.expectEqual(Rect{ .x = 120, .y = 50, .w = 30, .h = 20 }, clipped.effectiveClipGlobal());
    try std.testing.expectEqual(Rect{ .x = 20, .y = 0, .w = 30, .h = 20 }, clipped.effectiveClipLocal());

    const local = Point{ .x = -4, .y = 9 };
    try std.testing.expectEqual(local, clipped.globalToLocalPoint(clipped.localToGlobalPoint(local)));
}
