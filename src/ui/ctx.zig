//! The UI context (`Ctx`): the per-frame builder state threaded through the UI.
//!
//! Holds the widget-state pools (persistent), a reference to the platform
//! `Resources` (rendering + host `input`), and the per-frame arena (node tree).
//! Parametrized over the state-type registry `StateNs`, the host interaction-flag
//! type `IntFlags`, and the `Res` type so the generic `ui` module stays free of any
//! game/platform imports — the concrete binding lives one layer up (`ui_client/ctx_binding.zig`).
//! See `README.md` in this folder.

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

        /// One interaction slot: the host's flags plus the geometry the event stage
        /// needs. Keeping it here is what lets `mark` hit-test by iterating slots
        /// instead of walking the node tree — all of it is stamped in after layout
        /// (`stampRect`) and survives into the next frame's event stage.
        pub const Slot = struct {
            flags: IntFlags = .{},
            /// The node's full laid-out box. This is the *geometry* channel — `rectOf`
            /// returns it, and callers size things from it (a scroll container's
            /// content extent, a progress underbar's width). It is deliberately **not**
            /// cropped: clipping it would tell a scroll container its content fits.
            rect: ?Rect = null,
            /// The inherited clip region at stamp time, or null when nothing crops this
            /// node. Only `mark` reads it — a node scrolled out of its viewport keeps
            /// its full `rect` but stops being hittable.
            clip: ?Rect = null,
            /// The nearest *stamped* ancestor, for bubbling a hit up the containment
            /// chain. A key rather than a `*Node`: `Ctx` is not generic over the node
            /// type, and a node pointer would not survive the frame arena's reset.
            parent_key: ?u64 = null,
            /// Skip this node when hit-testing — neither flagged nor occluding. For
            /// nodes queried only to read their own geometry back (`scroll_view`'s
            /// content), which would otherwise swallow the hit for everything beneath.
            /// Default false: nodes block, because a default that blocks nothing makes
            /// `mark` unable to stop, which is the whole point of the ordered walk.
            pass_through: bool = false,
        };

        res: *Res,
        gpa: std.mem.Allocator, // persistent — owns the pools
        arena: std.mem.Allocator, // per-frame — owns the node tree
        frame: u64,
        pools: PoolsT,
        /// Engine-owned interaction state, keyed by widget key. Every live slot is a
        /// node that was `query`'d this frame — it carries that node's flags and rect.
        /// `mark` writes flags at the event stage; the build reads them via
        /// `interactionOf`. Survives the frame-arena reset (the node tree does not).
        interactions: cache_mod.Pool(Slot) = .{},
        /// Slot indices in **paint order**, back to front, rebuilt every frame by the
        /// `stamp_rects` walk (roots in list order, each tree in pre-order — exactly
        /// what the render walk paints). This is the z-axis, and `mark` walks it
        /// backwards so the topmost node takes the hit.
        ///
        /// It is built by the stamp pass and not at `query` time, because query order
        /// is *not* paint order: a template may query a child before its parent, and a
        /// page may append into an earlier sibling after building a later one. The
        /// stamp walk is the tree, so it cannot disagree with the tree.
        ///
        /// Frame coupling: the indices are last frame's, and `mark` runs before this
        /// frame's build. That is safe because slots stamped last frame were touched
        /// last frame, so `prune` kept them, and holes are only reused during the build
        /// that follows. `live` is still checked.
        order: std.ArrayList(u32) = .empty,
        /// The node key that currently owns keyboard text, if any. Focus is singular
        /// and global — unlike interaction, which is per-node — because a platform
        /// delivers text and editing keys as raw events, not routed to whatever the
        /// pointer is over. The engine stores it and reads it back; what *counts* as
        /// taking focus, and what a focused widget does with the keys, stays host
        /// policy. Known gap: a focused node that stops being built leaves this set,
        /// so the host is responsible for clearing it when a screen closes.
        focused: ?u64 = null,

        pub fn init(res: *Res, gpa: std.mem.Allocator, arena: std.mem.Allocator) Self {
            return .{ .res = res, .gpa = gpa, .arena = arena, .frame = 0, .pools = .{}, .interactions = .{}, .focused = null };
        }

        pub fn deinit(self: *Self) void {
            inline for (@typeInfo(PoolsT).@"struct".fields) |f| {
                @field(self.pools, f.name).deinit(self.gpa);
            }
            self.interactions.deinit(self.gpa);
            self.order.deinit(self.gpa);
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

        /// Set one interaction flag for key `k` directly (no hit-test). `flag` is
        /// checked against the host's `IntFlags` fields at comptime. Acquiring keeps
        /// the slot alive this frame.
        pub fn setFlag(self: *Self, k: u64, comptime flag: FlagEnum, val: bool) void {
            const idx = self.interactions.acquire(self.gpa, k, self.frame) catch @panic("ui interaction OOM");
            @field(self.interactions.get(idx).flags, @tagName(flag)) = val;
        }

        /// This key's interaction state. Zeroed (all flags off) the first frame a
        /// widget appears, since `acquire` zero-inits new slots. This is the
        /// read-through query: calling it allocates-or-keeps the slot (a node has
        /// no interaction state until something marks or reads it — lazy slots).
        pub fn interactionOf(self: *Self, k: u64) IntFlags {
            const idx = self.interactions.acquire(self.gpa, k, self.frame) catch @panic("ui interaction OOM");
            return self.interactions.get(idx).flags;
        }

        /// The rect last stamped on key `k`'s slot (i.e. its laid-out box from a prior
        /// frame), or null if `k` has no slot or was never stamped. Reads without
        /// creating a slot — for positioning one node relative to another's last rect
        /// (e.g. a tooltip above a hovered icon) before this frame's layout runs.
        pub fn rectOf(self: *Self, k: u64) ?Rect {
            const idx = self.interactions.index.get(k) orelse return null;
            return self.interactions.slots.items[idx].value.rect;
        }

        /// Mark key `k` as pass-through: present for geometry, invisible to hit-testing.
        /// No-op if `k` has no slot. Set at build time, cleared by nothing — a node that
        /// stops declaring it gets a fresh (blocking) slot when its old one is pruned.
        pub fn setPassThrough(self: *Self, k: u64, v: bool) void {
            const idx = self.interactions.acquire(self.gpa, k, self.frame) catch @panic("ui interaction OOM");
            self.interactions.get(idx).pass_through = v;
        }

        /// Record this node's geometry on key `k`'s slot and append it to the frame's
        /// paint-order list — but only if the slot already exists (i.e. the node was
        /// `query`'d this frame). Returns whether it stamped, which is what lets the
        /// walk pass the nearest *stamped* ancestor down as the next `parent_key`.
        /// Called by the post-layout `stamp_rects` walk, in paint order.
        pub fn stampRect(self: *Self, k: u64, rect: Rect, clip: ?Rect, parent_key: ?u64) bool {
            const idx = self.interactions.index.get(k) orelse return false;
            const slot = &self.interactions.slots.items[idx];
            slot.value.rect = rect;
            slot.value.clip = clip;
            slot.value.parent_key = parent_key;
            self.order.append(self.gpa, idx) catch {}; // a dropped entry costs a hit, not memory safety
            return true;
        }

        /// Event-stage hit-test: set `flag` on the **topmost** node containing (x, y),
        /// then on its ancestors. O(interactive) — walks the paint-order list, not the
        /// node tree. The geometry is last frame's (stamped after that frame's layout);
        /// the point is passed in (mouse/touch/gamepad — the engine never asks where it
        /// came from).
        ///
        /// Topmost-only is what makes occlusion a mechanism: a node genuinely blocks
        /// what is drawn beneath it, so an overlay does not have to trust that whatever
        /// it covers is harmless to double-fire. Ancestors are still flagged, so a row
        /// stays hovered while the pointer is over its own button — containment keeps
        /// working; only the nodes *underneath* the hit are left alone.
        pub fn mark(self: *Self, comptime flag: FlagEnum, x: f32, y: f32) void {
            var i = self.order.items.len;
            while (i > 0) {
                i -= 1;
                const idx = self.order.items[i];
                if (idx >= self.interactions.slots.items.len) continue;
                const slot = &self.interactions.slots.items[idx];
                if (!slot.live or slot.value.pass_through) continue;
                const r = slot.value.rect orelse continue;
                // Cropped out of its scroll viewport: still laid out, no longer hittable.
                if (slot.value.clip) |c| if (!c.contains(x, y)) continue;
                if (!r.contains(x, y)) continue;

                @field(slot.value.flags, @tagName(flag)) = true;
                var pk = slot.value.parent_key;
                var guard: u32 = 0;
                while (pk) |k| : (guard += 1) {
                    if (guard > 256) break; // a cycle can only come from a corrupt stamp
                    const pidx = self.interactions.index.get(k) orelse break;
                    const parent = &self.interactions.slots.items[pidx];
                    if (!parent.live) break;
                    @field(parent.value.flags, @tagName(flag)) = true;
                    pk = parent.value.parent_key;
                }
                return;
            }
        }

        /// Reset the host's *transient* flags on every live slot, leaving latched
        /// flags untouched. Which fields are transient is host policy: the engine
        /// reads the `transient` field-name list off `IntFlags`. Run once per frame
        /// so stale marks don't linger; latched flags persist until userland clears them.
        pub fn clearTransient(self: *Self) void {
            for (self.interactions.slots.items) |*slot| {
                if (!slot.live) continue;
                inline for (IntFlags.transient) |name| {
                    @field(slot.value.flags, name) = false;
                }
            }
        }

        pub fn beginFrame(self: *Self) void {
            self.frame += 1;
            // Last frame's paint order dies here, not at `endFrame` — the host marks
            // input *before* beginning the frame, so the list has to outlive the
            // frame that built it and be dropped only once it has been read.
            self.order.clearRetainingCapacity();
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

// ============================ Tests ==========================================
// The event stage had no coverage at all before these: `test-ui` would go green
// through a total inversion of hit-test semantics, and there is no synthetic-input
// path into the platform, so a screenshot cannot show which of two overlapping nodes
// took a click. `mark` is pure over the slot pool — `res` and `arena` are untouched by
// every method here — so it tests directly with no window and no allocator ceremony.

const TestFlags = packed struct {
    hovering: bool = false,
    clicked: bool = false,
    active: bool = false,
    pub const transient = [_][]const u8{ "hovering", "clicked" };
};
const TestCtx = Ctx(struct {}, TestFlags, u8);

/// Give `k` a slot and stamp it at `r`, painted after everything stamped before it.
fn tstamp(u: *TestCtx, k: u64, r: Rect, clip: ?Rect, parent: ?u64) void {
    _ = u.interactionOf(k); // a node has no slot until it is queried
    _ = u.stampRect(k, r, clip, parent);
}

test "mark hits the topmost node only — later paint order wins" {
    var u = TestCtx.init(undefined, std.testing.allocator, undefined);
    defer u.deinit();
    u.beginFrame();

    const box = Rect{ .x = 0, .y = 0, .w = 100, .h = 100 };
    const under = cache_mod.key(0, "under");
    const over = cache_mod.key(0, "over");
    tstamp(&u, under, box, null, null);
    tstamp(&u, over, box, null, null); // same rect, painted second ⇒ on top

    u.mark(.clicked, 50, 50);
    try std.testing.expect(u.interactionOf(over).clicked);
    try std.testing.expect(!u.interactionOf(under).clicked); // occluded, not double-fired
}

test "mark bubbles to ancestors, so a row stays hovered over its own button" {
    var u = TestCtx.init(undefined, std.testing.allocator, undefined);
    defer u.deinit();
    u.beginFrame();

    const row = cache_mod.key(0, "row");
    const btn = cache_mod.key(0, "btn");
    tstamp(&u, row, .{ .x = 0, .y = 0, .w = 200, .h = 40 }, null, null);
    tstamp(&u, btn, .{ .x = 160, .y = 8, .w = 24, .h = 24 }, null, row);

    u.mark(.hovering, 170, 20); // over the button, inside the row
    try std.testing.expect(u.interactionOf(btn).hovering);
    try std.testing.expect(u.interactionOf(row).hovering); // containment still reads
}

test "a pass-through node neither takes the hit nor occludes what is under it" {
    var u = TestCtx.init(undefined, std.testing.allocator, undefined);
    defer u.deinit();
    u.beginFrame();

    const box = Rect{ .x = 0, .y = 0, .w = 100, .h = 100 };
    const button = cache_mod.key(0, "button");
    const probe = cache_mod.key(0, "probe"); // queried only to read its own geometry back
    tstamp(&u, button, box, null, null);
    u.setPassThrough(probe, true);
    tstamp(&u, probe, box, null, null); // covers the button, painted later

    u.mark(.clicked, 50, 50);
    try std.testing.expect(u.interactionOf(button).clicked);
    try std.testing.expect(!u.interactionOf(probe).clicked);
}

test "a node clipped out of its viewport keeps its rect but stops being hittable" {
    var u = TestCtx.init(undefined, std.testing.allocator, undefined);
    defer u.deinit();
    u.beginFrame();

    // A row scrolled below the fold: laid out at y=200, viewport crops to y<100.
    const viewport = Rect{ .x = 0, .y = 0, .w = 100, .h = 100 };
    const row = cache_mod.key(0, "row");
    tstamp(&u, row, .{ .x = 0, .y = 200, .w = 100, .h = 20 }, viewport, null);

    u.mark(.clicked, 50, 210); // over where it was laid out
    try std.testing.expect(!u.interactionOf(row).clicked);

    // The geometry channel is untouched: cropping it would tell a scroll container
    // its content fits, and the wheel would never do anything again.
    const r = u.rectOf(row).?;
    try std.testing.expectEqual(@as(f32, 200), r.y);
    try std.testing.expectEqual(@as(f32, 20), r.h);
}

test "mark ignores stale order entries once their slot is pruned" {
    var u = TestCtx.init(undefined, std.testing.allocator, undefined);
    defer u.deinit();
    u.beginFrame();

    const gone = cache_mod.key(0, "gone");
    tstamp(&u, gone, .{ .x = 0, .y = 0, .w = 50, .h = 50 }, null, null);

    u.endFrame(); // not touched next frame ⇒ pruned
    u.beginFrame();
    u.endFrame();
    u.beginFrame();

    u.mark(.clicked, 10, 10); // the order list was cleared; nothing to hit
    try std.testing.expect(!u.interactionOf(gone).clicked);
}
