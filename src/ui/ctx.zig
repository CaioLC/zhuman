//! The UI context (`Ctx`): the per-frame builder state threaded through the UI.
//!
//! Holds the widget-state pools (persistent), a reference to the platform
//! `Resources` (rendering + host `input`), and the per-frame arena (node tree).
//! Parametrized over the state-type registry `StateNs`, the host interaction-flag
//! type `IntFlags`, and the `Res` type so the generic `ui` module stays free of any
//! game/platform imports — the concrete binding lives one layer up (see widgets.zig).
//! See docs/ui-building-language-plan.md.

const std = @import("std");
const cache_mod = @import("cache.zig");
const geometry = @import("geometry.zig");

pub const Rect = geometry.Rect;

/// `IntFlags` is a host-defined packed struct of interaction flags (e.g. hovering,
/// clicked, active). The engine stores it opaquely, keyed by widget key — it owns
/// neither the vocabulary nor the transient/latched policy. The host type must
/// declare `pub const transient = [_][]const u8{ ... }` naming the fields the engine
/// zeroes every frame (recomputed from input); fields not listed latch across frames.
pub fn Ctx(comptime StateNs: type, comptime IntFlags: type, comptime Res: type) type {
    const PoolsT = cache_mod.Pools(StateNs);
    const FlagEnum = std.meta.FieldEnum(IntFlags);

    return struct {
        const Self = @This();

        /// The host's interaction-flag type, re-exposed so generic engine code (e.g.
        /// `Node.query`) can name the read-back return type without importing the host.
        pub const Interaction = IntFlags;

        res: *Res,
        gpa: std.mem.Allocator, // persistent — owns the pools
        arena: std.mem.Allocator, // per-frame — owns the node tree
        frame: u64,
        pools: PoolsT,
        /// Engine-owned interaction state, keyed by widget key. The persistence
        /// substrate behind the per-node interaction flags: `mark_*` writes it at the
        /// event stage, the build re-stamps nodes from it. Survives the frame-arena
        /// reset (which the ephemeral node tree does not).
        interactions: cache_mod.Pool(IntFlags) = .{},

        pub fn init(res: *Res, gpa: std.mem.Allocator, arena: std.mem.Allocator) Self {
            return .{ .res = res, .gpa = gpa, .arena = arena, .frame = 0, .pools = .{}, .interactions = .{} };
        }

        pub fn deinit(self: *Self) void {
            inline for (@typeInfo(PoolsT).@"struct".fields) |f| {
                @field(self.pools, f.name).deinit(self.gpa);
            }
            self.interactions.deinit(self.gpa);
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

        /// Set one interaction flag for key `k` (called by the `mark_*` tree walks).
        /// `flag` is checked against the host's `IntFlags` fields at comptime.
        /// Acquiring keeps the slot alive this frame.
        pub fn setFlag(self: *Self, k: u64, comptime flag: FlagEnum, val: bool) void {
            const idx = self.interactions.acquire(self.gpa, k, self.frame) catch @panic("ui interaction OOM");
            @field(self.interactions.get(idx).*, @tagName(flag)) = val;
        }

        /// This key's interaction state. Zeroed (all flags off) the first frame a
        /// widget appears, since `acquire` zero-inits new slots. This is the
        /// read-through query: calling it allocates-or-keeps the slot (a node has
        /// no interaction state until something marks or reads it — lazy slots).
        pub fn interactionOf(self: *Self, k: u64) IntFlags {
            const idx = self.interactions.acquire(self.gpa, k, self.frame) catch @panic("ui interaction OOM");
            return self.interactions.get(idx).*;
        }

        /// Reset the host's *transient* flags on every live slot, leaving latched
        /// flags untouched. Which fields are transient is host policy: the engine
        /// reads the `transient` field-name list off `IntFlags`. Run once per frame
        /// so stale marks don't linger; latched flags persist until userland clears them.
        pub fn clearTransient(self: *Self) void {
            for (self.interactions.slots.items) |*slot| {
                if (!slot.live) continue;
                inline for (IntFlags.transient) |name| {
                    @field(slot.value, name) = false;
                }
            }
        }

        pub fn beginFrame(self: *Self) void {
            self.frame += 1;
        }

        pub fn endFrame(self: *Self) void {
            inline for (@typeInfo(PoolsT).@"struct".fields) |f| {
                @field(self.pools, f.name).prune(self.gpa, self.frame) catch {};
            }
            self.interactions.prune(self.gpa, self.frame) catch {};
            self.clearTransient();
        }
    };
}
