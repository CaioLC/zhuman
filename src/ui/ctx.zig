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
const focus_mod = @import("focus.zig");
const geometry = @import("geometry.zig");

pub const Rect = geometry.Rect;
pub const Geometry = geometry.Geometry;

/// Optional host-supplied local-shape predicate for an interaction slot. The engine
/// first enforces clip and rectangular bounds, then calls this with the stamped rect
/// and global point. Callbacks must be static/persistent; no frame-arena context is kept.
pub const HitTestFn = *const fn (rect: Rect, x: f32, y: f32) bool;

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
            /// Optional host geometry refinement. `mark` invokes it only after the point
            /// passes the inherited clip and full rectangular box. Returning false
            /// rejects this slot and continues down paint order, enabling transparent
            /// corners to fall through without teaching the engine any concrete shape.
            hit_test: ?HitTestFn = null,
            /// Build frame that supplied `hit_test`. Slots persist, but behavior is
            /// immediate-mode: omitting the declaration next build restores a rectangle.
            hit_test_frame: u64 = 0,
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
        /// Singular key-based keyboard focus plus the double-buffered traversal registry.
        /// Event-stage commands traverse the last completed frame; build registration
        /// fills the next order, which `endFrame` repairs and publishes.
        focus: focus_mod.Focus,
        /// Singular pointer capture owner. While set, `mark` routes directly to this
        /// stable key and its stamped ancestors, independent of pointer coordinates.
        pointer_capture: ?u64 = null,

        pub fn init(res: *Res, gpa: std.mem.Allocator, arena: std.mem.Allocator) Self {
            return .{ .res = res, .gpa = gpa, .arena = arena, .frame = 0, .pools = .{}, .interactions = .{}, .focus = focus_mod.Focus.init(gpa) };
        }

        pub fn deinit(self: *Self) void {
            inline for (@typeInfo(PoolsT).@"struct".fields) |f| {
                @field(self.pools, f.name).deinit(self.gpa);
            }
            self.interactions.deinit(self.gpa);
            self.order.deinit(self.gpa);
            self.focus.deinit();
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

        /// Keep an existing `T` slot alive for this frame without acquiring or creating
        /// one. This lets an always-built shell preserve selected state owned by a hidden
        /// conditional child. Retention ends as soon as the shell stops calling it.
        pub fn retainState(self: *Self, k: u64, comptime T: type) bool {
            return self.pool(T).retain(k, self.frame);
        }

        /// Register one stable key in this frame's global traversal order.
        pub fn registerFocus(self: *Self, key: u64, enabled: bool) void {
            self.focus.register(key, enabled);
        }

        /// Register a member whose group contributes one active global Tab stop.
        pub fn registerRovingFocus(self: *Self, group: u64, key: u64, enabled: bool) void {
            self.focus.registerRoving(group, key, enabled);
        }

        pub fn requestFocus(self: *Self, key: u64) bool {
            return self.focus.request(key);
        }

        pub fn clearFocus(self: *Self) void {
            self.focus.clear();
        }

        pub fn focusedKey(self: *const Self) ?u64 {
            return self.focus.focusedKey();
        }

        pub fn isFocused(self: *const Self, key: u64) bool {
            return self.focus.isFocused(key);
        }

        pub fn moveFocus(self: *Self, direction: focus_mod.Direction, wrap: bool) bool {
            return self.focus.move(direction, wrap);
        }

        pub fn moveRovingFocus(self: *Self, group: u64, direction: focus_mod.Direction, wrap: bool) bool {
            return self.focus.moveInGroup(group, direction, wrap);
        }

        /// Capture pointer routing for an existing live interaction key. Capture is
        /// singular; acquiring a different key transfers ownership deliberately.
        pub fn capturePointer(self: *Self, key: u64) bool {
            const idx = self.interactions.index.get(key) orelse return false;
            if (!self.interactions.slots.items[idx].live) return false;
            self.pointer_capture = key;
            return true;
        }

        pub fn capturedPointerKey(self: *const Self) ?u64 {
            return self.pointer_capture;
        }

        pub fn hasPointerCapture(self: *const Self, key: u64) bool {
            return self.pointer_capture == key;
        }

        /// Release only when `key` still owns capture, preventing an unrelated control
        /// from clearing a capture it does not own.
        pub fn releasePointerCapture(self: *Self, key: u64) bool {
            if (self.pointer_capture != key) return false;
            self.pointer_capture = null;
            return true;
        }

        /// Unconditionally cancel capture for host cancellation/window-focus loss.
        pub fn cancelPointerCapture(self: *Self) void {
            self.pointer_capture = null;
        }

        /// Set one interaction flag for key `k` directly (no hit-test). `flag` is
        /// checked against the host's `IntFlags` fields at comptime. Acquiring keeps
        /// the slot alive this frame.
        pub fn setFlag(self: *Self, k: u64, comptime flag: FlagEnum, val: bool) void {
            const idx = self.interactions.acquire(self.gpa, k, self.frame) catch @panic("ui interaction OOM");
            @field(self.interactions.get(idx).flags, @tagName(flag)) = val;
        }

        /// This key's interaction state. Zeroed (all flags off) the first frame a
        /// widget appears. `Slot` has no semantic nonzero defaults, so it uses the
        /// pool's zeroable fallback. This is the
        /// read-through query: calling it allocates-or-keeps the slot (a node has
        /// no interaction state until something marks or reads it — lazy slots).
        pub fn interactionOf(self: *Self, k: u64) IntFlags {
            const idx = self.interactions.acquire(self.gpa, k, self.frame) catch @panic("ui interaction OOM");
            return self.interactions.get(idx).flags;
        }

        /// The full geometry last stamped for key `k` by a prior frame's layout, or null
        /// for a missing/unstamped slot. This non-allocating read makes timing explicit:
        /// current-frame geometry does not exist until layout and stamping after build.
        pub fn priorGeometryOf(self: *Self, k: u64) ?Geometry {
            const idx = self.interactions.index.get(k) orelse return null;
            const slot = &self.interactions.slots.items[idx];
            const rect = slot.value.rect orelse return null;
            return .{ .rect = rect, .clip = slot.value.clip };
        }

        /// Compatibility projection of `priorGeometryOf`; prefer the explicit accessor
        /// when doing coordinate conversion or effective-clip calculations.
        pub fn rectOf(self: *Self, k: u64) ?Rect {
            return (self.priorGeometryOf(k) orelse return null).rect;
        }

        /// Observe and consume one typed flag on `k` and its stamped ancestor chain.
        /// Missing/unset sources return false without allocation. Consumption is
        /// flag-specific: hover and every unrelated host flag remain untouched.
        pub fn consumeFlag(self: *Self, k: u64, comptime flag: FlagEnum) bool {
            const idx = self.interactions.index.get(k) orelse return false;
            const source = &self.interactions.slots.items[idx];
            if (!source.live) return false;
            source.touched = self.frame; // consuming is a read; keep the existing slot alive
            const name = @tagName(flag);
            if (!@field(source.value.flags, name)) return false;

            @field(source.value.flags, name) = false;
            var pk = source.value.parent_key;
            var guard: u32 = 0;
            while (pk) |key| : (guard += 1) {
                if (guard > 256) break;
                const pidx = self.interactions.index.get(key) orelse break;
                const parent = &self.interactions.slots.items[pidx];
                if (!parent.live) break;
                @field(parent.value.flags, name) = false;
                pk = parent.value.parent_key;
            }
            return true;
        }

        /// Mark key `k` as pass-through: present for geometry, invisible to hit-testing.
        /// No-op if `k` has no slot. Set at build time, cleared by nothing — a node that
        /// stops declaring it gets a fresh (blocking) slot when its old one is pruned.
        pub fn setPassThrough(self: *Self, k: u64, v: bool) void {
            const idx = self.interactions.acquire(self.gpa, k, self.frame) catch @panic("ui interaction OOM");
            self.interactions.get(idx).pass_through = v;
        }

        /// Refine key `k`'s rectangular hit box with host-owned geometry for this build.
        /// The callback pointer is copied into the persistent slot, so it must not capture
        /// frame data. If the key is rebuilt without calling this, the predicate expires
        /// and ordinary rectangular hit testing resumes; null also clears it explicitly.
        pub fn setHitTest(self: *Self, k: u64, predicate: ?HitTestFn) void {
            const idx = self.interactions.acquire(self.gpa, k, self.frame) catch @panic("ui interaction OOM");
            const slot = self.interactions.get(idx);
            slot.hit_test = predicate;
            slot.hit_test_frame = self.frame;
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

        fn routeFlag(self: *Self, idx: u32, comptime flag: FlagEnum) void {
            const slot = &self.interactions.slots.items[idx];
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
        }

        /// Event-stage routing: while a live key owns pointer capture, set `flag` on it
        /// and its ancestors regardless of (x, y). Otherwise hit-test the **topmost**
        /// node containing (x, y), then bubble to its ancestors. O(interactive) — walks
        /// the paint-order list, not the node tree. The geometry is last frame's (stamped after that frame's layout);
        /// the point is passed in (mouse/touch/gamepad — the engine never asks where it
        /// came from).
        ///
        /// Topmost-only is what makes occlusion a mechanism: a node genuinely blocks
        /// what is drawn beneath it, so an overlay does not have to trust that whatever
        /// it covers is harmless to double-fire. Ancestors are still flagged, so a row
        /// stays hovered while the pointer is over its own button — containment keeps
        /// working; only the nodes *underneath* the hit are left alone.
        pub fn mark(self: *Self, comptime flag: FlagEnum, x: f32, y: f32) void {
            if (self.pointer_capture) |key| {
                if (self.interactions.index.get(key)) |idx| {
                    if (self.interactions.slots.items[idx].live) {
                        self.routeFlag(idx, flag);
                        return;
                    }
                }
                // Defensive repair; normal disappearance is handled at endFrame.
                self.pointer_capture = null;
            }

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
                if (slot.value.hit_test_frame == self.frame) {
                    if (slot.value.hit_test) |predicate| if (!predicate(r, x, y)) continue;
                }

                self.routeFlag(idx, flag);
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
            self.focus.beginFrame();
        }

        pub fn endFrame(self: *Self) void {
            inline for (@typeInfo(PoolsT).@"struct".fields) |f| {
                @field(self.pools, f.name).prune(self.gpa, self.frame) catch {};
            }
            self.interactions.prune(self.gpa, self.frame) catch {};
            if (self.pointer_capture) |key| {
                const idx = self.interactions.index.get(key);
                if (idx == null or !self.interactions.slots.items[idx.?].live) self.pointer_capture = null;
            }
            self.focus.endFrame();
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

test "prior geometry is null until stamped and carries inherited clip" {
    var u = TestCtx.init(undefined, std.testing.allocator, undefined);
    defer u.deinit();
    u.beginFrame();

    const key = cache_mod.key(0, "geometry");
    try std.testing.expectEqual(@as(?Geometry, null), u.priorGeometryOf(key));
    _ = u.interactionOf(key);
    try std.testing.expectEqual(@as(?Geometry, null), u.priorGeometryOf(key));

    const rect = Rect{ .x = 25, .y = 40, .w = 100, .h = 60 };
    const clip = Rect{ .x = 40, .y = 50, .w = 50, .h = 20 };
    _ = u.stampRect(key, rect, clip, null);
    const prior = u.priorGeometryOf(key).?;
    try std.testing.expectEqual(rect, prior.rect);
    try std.testing.expectEqual(@as(?Rect, clip), prior.clip);
    try std.testing.expectEqual(Rect{ .x = 15, .y = 10, .w = 50, .h = 20 }, prior.effectiveClipLocal());
    try std.testing.expectEqual(rect, u.rectOf(key).?);
}

/// Test-only host geometry: a flat-top hex inscribed in `rect`. Production engine code
/// knows only the callback type; a board binding can supply this or any other predicate.
fn testFlatHex(rect: Rect, x: f32, y: f32) bool {
    if (rect.w <= 0 or rect.h <= 0) return false;
    const local = rect.globalToLocalPoint(.{ .x = x, .y = y });
    const local_x = local.x / rect.w;
    const local_y = local.y / rect.h;
    if (local_x < 0 or local_x > 1 or local_y < 0 or local_y > 1) return false;
    const edge_height = 1 - 2 * @abs(local_x - 0.5);
    return @abs(local_y - 0.5) <= @min(@as(f32, 0.5), edge_height);
}

test "shape corners fall through to the correct neighbor and background" {
    var u = TestCtx.init(undefined, std.testing.allocator, undefined);
    defer u.deinit();
    u.beginFrame();

    const background = cache_mod.key(0, "background");
    const neighbor = cache_mod.key(0, "neighbor");
    const top = cache_mod.key(0, "top");
    tstamp(&u, background, .{ .x = 0, .y = 0, .w = 200, .h = 100 }, null, null);
    u.setHitTest(neighbor, testFlatHex);
    tstamp(&u, neighbor, .{ .x = 0, .y = 0, .w = 100, .h = 100 }, null, null);
    u.setHitTest(top, testFlatHex);
    tstamp(&u, top, .{ .x = 50, .y = 0, .w = 100, .h = 100 }, null, null);

    // Inside the top hex's rectangular bounds but above its transparent left edge;
    // the overlapping neighbor accepts the same point.
    u.mark(.clicked, 55, 30);
    try std.testing.expect(!u.interactionOf(top).clicked);
    try std.testing.expect(u.interactionOf(neighbor).clicked);
    try std.testing.expect(!u.interactionOf(background).clicked);

    u.clearTransient();
    // The opposite transparent corner overlaps no neighbor, so it reaches the backdrop.
    u.mark(.clicked, 145, 10);
    try std.testing.expect(!u.interactionOf(top).clicked);
    try std.testing.expect(!u.interactionOf(neighbor).clicked);
    try std.testing.expect(u.interactionOf(background).clicked);
}

test "clip rejects a shaped node before it can claim the hit" {
    var u = TestCtx.init(undefined, std.testing.allocator, undefined);
    defer u.deinit();
    u.beginFrame();

    const background = cache_mod.key(0, "background");
    const shape = cache_mod.key(0, "shape");
    tstamp(&u, background, .{ .x = 0, .y = 0, .w = 100, .h = 100 }, null, null);
    u.setHitTest(shape, testFlatHex);
    tstamp(
        &u,
        shape,
        .{ .x = 0, .y = 0, .w = 100, .h = 100 },
        .{ .x = 0, .y = 0, .w = 50, .h = 100 },
        null,
    );

    // The point is in the hex and its full rect, but outside its effective viewport.
    u.mark(.clicked, 75, 50);
    try std.testing.expect(!u.interactionOf(shape).clicked);
    try std.testing.expect(u.interactionOf(background).clicked);
}

test "shape predicate expires when the next build omits it" {
    var u = TestCtx.init(undefined, std.testing.allocator, undefined);
    defer u.deinit();

    const shape = cache_mod.key(0, "changing-shape");
    const box = Rect{ .x = 0, .y = 0, .w = 100, .h = 100 };

    u.beginFrame();
    u.setHitTest(shape, testFlatHex);
    tstamp(&u, shape, box, null, null);
    u.endFrame();
    u.mark(.clicked, 5, 5); // transparent hex corner
    try std.testing.expect(!u.interactionOf(shape).clicked);

    u.beginFrame();
    tstamp(&u, shape, box, null, null); // same key, now an ordinary rectangle
    u.endFrame();
    u.mark(.clicked, 5, 5);
    try std.testing.expect(u.interactionOf(shape).clicked);
}

test "child consumption clears one flag through ancestors and preserves hover" {
    var u = TestCtx.init(undefined, std.testing.allocator, undefined);
    defer u.deinit();
    u.beginFrame();

    const grand = cache_mod.key(0, "grand");
    const row = cache_mod.key(grand, "row");
    const cancel = cache_mod.key(row, "cancel");
    const sibling = cache_mod.key(grand, "sibling");
    const box = Rect{ .x = 0, .y = 0, .w = 100, .h = 40 };
    tstamp(&u, grand, box, null, null);
    tstamp(&u, row, box, null, grand);
    tstamp(&u, sibling, .{ .x = 120, .y = 0, .w = 20, .h = 20 }, null, grand);
    tstamp(&u, cancel, .{ .x = 80, .y = 0, .w = 20, .h = 40 }, null, row);

    u.mark(.hovering, 90, 20);
    u.mark(.clicked, 90, 20);
    u.setFlag(sibling, .clicked, true); // unrelated branch must remain untouched

    try std.testing.expect(u.consumeFlag(cancel, .clicked));
    try std.testing.expect(!u.interactionOf(cancel).clicked);
    try std.testing.expect(!u.interactionOf(row).clicked);
    try std.testing.expect(!u.interactionOf(grand).clicked);
    try std.testing.expect(u.interactionOf(sibling).clicked);
    try std.testing.expect(u.interactionOf(cancel).hovering);
    try std.testing.expect(u.interactionOf(row).hovering);
    try std.testing.expect(u.interactionOf(grand).hovering);
    try std.testing.expect(!u.consumeFlag(cancel, .clicked));
    try std.testing.expect(!u.consumeFlag(cache_mod.key(0, "missing"), .clicked));
}

test "captured child activation can be consumed without changing capture" {
    var u = TestCtx.init(undefined, std.testing.allocator, undefined);
    defer u.deinit();
    u.beginFrame();

    const row = cache_mod.key(0, "row");
    const child = cache_mod.key(row, "child");
    tstamp(&u, row, .{ .x = 0, .y = 0, .w = 100, .h = 40 }, null, null);
    tstamp(&u, child, .{ .x = 80, .y = 0, .w = 20, .h = 40 }, null, row);
    try std.testing.expect(u.capturePointer(child));

    u.mark(.clicked, 500, 500);
    try std.testing.expect(u.consumeFlag(child, .clicked));
    try std.testing.expect(!u.interactionOf(row).clicked);
    try std.testing.expect(u.hasPointerCapture(child));
}

test "captured slider drag routes outside and cannot click through" {
    var u = TestCtx.init(undefined, std.testing.allocator, undefined);
    defer u.deinit();
    u.beginFrame();

    const background = cache_mod.key(0, "background");
    const slider = cache_mod.key(0, "slider");
    const thumb = cache_mod.key(slider, "thumb");
    tstamp(&u, background, .{ .x = 0, .y = 0, .w = 200, .h = 100 }, null, null);
    tstamp(&u, slider, .{ .x = 0, .y = 0, .w = 100, .h = 30 }, null, null);
    tstamp(&u, thumb, .{ .x = 0, .y = 0, .w = 20, .h = 30 }, null, slider);

    try std.testing.expect(!u.capturePointer(cache_mod.key(0, "missing")));
    try std.testing.expect(u.capturePointer(thumb));
    try std.testing.expect(u.hasPointerCapture(thumb));

    // Far outside the thumb and slider, over the background: motion/drag-style flags
    // still route to the owner and bubble, while the covered target cannot click through.
    u.mark(.hovering, 180, 80);
    try std.testing.expect(u.interactionOf(thumb).hovering);
    try std.testing.expect(u.interactionOf(slider).hovering);
    try std.testing.expect(!u.interactionOf(background).hovering);
}

test "release outside routes first then restores ordinary targeting" {
    var u = TestCtx.init(undefined, std.testing.allocator, undefined);
    defer u.deinit();
    u.beginFrame();

    const background = cache_mod.key(0, "background");
    const scrollbar = cache_mod.key(0, "scrollbar");
    tstamp(&u, background, .{ .x = 0, .y = 0, .w = 200, .h = 100 }, null, null);
    tstamp(&u, scrollbar, .{ .x = 0, .y = 0, .w = 20, .h = 100 }, null, null);
    try std.testing.expect(u.capturePointer(scrollbar));

    // A host routes its release flag before dropping ownership.
    u.mark(.clicked, 180, 50);
    try std.testing.expect(u.interactionOf(scrollbar).clicked);
    try std.testing.expect(!u.interactionOf(background).clicked);
    try std.testing.expect(!u.releasePointerCapture(background));
    try std.testing.expect(u.releasePointerCapture(scrollbar));
    try std.testing.expectEqual(@as(?u64, null), u.capturedPointerKey());

    u.clearTransient();
    u.mark(.clicked, 180, 50);
    try std.testing.expect(!u.interactionOf(scrollbar).clicked);
    try std.testing.expect(u.interactionOf(background).clicked);
}

test "capture transfers singularly and cancellation clears board pan owner" {
    var u = TestCtx.init(undefined, std.testing.allocator, undefined);
    defer u.deinit();
    u.beginFrame();

    const scrollbar = cache_mod.key(0, "scrollbar");
    const board = cache_mod.key(0, "board");
    tstamp(&u, scrollbar, .{ .x = 0, .y = 0, .w = 20, .h = 100 }, null, null);
    tstamp(&u, board, .{ .x = 20, .y = 0, .w = 180, .h = 100 }, null, null);
    try std.testing.expect(u.capturePointer(scrollbar));
    try std.testing.expect(u.capturePointer(board));
    try std.testing.expect(!u.hasPointerCapture(scrollbar));
    try std.testing.expect(u.hasPointerCapture(board));
    u.cancelPointerCapture(); // host cancellation or window-focus loss
    try std.testing.expectEqual(@as(?u64, null), u.capturedPointerKey());
}

test "disappearing capture owner is repaired at frame end" {
    var u = TestCtx.init(undefined, std.testing.allocator, undefined);
    defer u.deinit();

    const owner = cache_mod.key(0, "temporary-drag-owner");
    u.beginFrame();
    tstamp(&u, owner, .{ .x = 0, .y = 0, .w = 20, .h = 20 }, null, null);
    try std.testing.expect(u.capturePointer(owner));
    u.endFrame();
    try std.testing.expect(u.hasPointerCapture(owner));

    u.beginFrame();
    u.endFrame(); // owner was not touched, so interaction pruning removes it
    try std.testing.expectEqual(@as(?u64, null), u.capturedPointerKey());
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
