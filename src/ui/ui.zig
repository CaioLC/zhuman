//! The UI context: the per-frame builder state threaded through the UI.
//!
//! Holds the widget-state pools (persistent), a reference to the platform
//! `Resources` (rendering), and the per-frame arena (node tree). Parametrized
//! over the state-type registry `StateNs` and the `Res` type so the generic
//! `ui` module stays free of any game/platform imports — the concrete binding
//! lives one layer up (see widgets.zig). See docs/ui-building-language-plan.md.

const std = @import("std");
const cache_mod = @import("cache.zig");

/// Per-frame mouse state, fed by the host event loop and read by `comm` during
/// build (against the previous frame's cached widget rects).
pub const Input = struct {
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    /// A press occurred during this frame's event poll (one-frame edge).
    mouse_down: bool = false,
};

pub fn Ui(comptime StateNs: type, comptime Res: type) type {
    const PoolsT = cache_mod.Pools(StateNs);

    return struct {
        const Self = @This();

        res: *Res,
        gpa: std.mem.Allocator, // persistent — owns the pools
        arena: std.mem.Allocator, // per-frame — owns the node tree
        frame: u64,
        pools: PoolsT,
        input: Input,

        pub fn init(res: *Res, gpa: std.mem.Allocator, arena: std.mem.Allocator) Self {
            return .{ .res = res, .gpa = gpa, .arena = arena, .frame = 0, .pools = .{}, .input = .{} };
        }

        pub fn deinit(self: *Self) void {
            inline for (@typeInfo(PoolsT).@"struct".fields) |f| {
                @field(self.pools, f.name).deinit(self.gpa);
            }
        }

        /// The pool for state type `T` (must be registered in `StateNs`).
        pub fn pool(self: *Self, comptime T: type) *cache_mod.Pool(T) {
            inline for (@typeInfo(PoolsT).@"struct".fields) |f| {
                if (f.type == cache_mod.Pool(T)) return &@field(self.pools, f.name);
            }
            @compileError("no UI pool registered for " ++ @typeName(T));
        }

        /// Find-or-create this frame's slot for `k` in the `T` pool; returns its handle.
        pub fn cache(self: *Self, k: u64, comptime T: type) u32 {
            return self.pool(T).acquire(self.gpa, k, self.frame) catch @panic("ui cache OOM");
        }

        pub fn beginFrame(self: *Self) void {
            self.frame += 1;
        }

        pub fn endFrame(self: *Self) void {
            inline for (@typeInfo(PoolsT).@"struct".fields) |f| {
                @field(self.pools, f.name).prune(self.gpa, self.frame) catch {};
            }
        }
    };
}
