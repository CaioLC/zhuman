//! `tween` — a small **host-layer transition/tween state** (RENDER-08) for the prototype's
//! few *functional* transitions: the Holdings column/gap collapse (`120ms`), a stock token's
//! font-size change (`90ms`), and the board's opacity/stroke changes (`100–110ms`). It is a
//! deliberately tiny **value provider**, not a general timeline engine and not a node feature:
//! a consumer keys a scalar tween by a **stable node/domain id** (a `u64`, the same stable-key
//! discipline the interaction/focus/semantic registries use — so a tween survives reorder,
//! filter, and rebuild), advances all tweens once per frame by the frame `dt`, and reads the
//! current interpolated value to feed into a size, gap, opacity, or font px.
//!
//! **Interrupt / reverse cleanly:** `retarget(id, to, duration)` redirects an existing tween
//! toward a new target **from its current value**, not from its original start — so reversing
//! a half-open Holdings rail glides back from where it is instead of snapping to the far end
//! and re-animating. A brand-new id starts at its `to` (nothing to animate from yet) or from
//! an explicit `start` via `from`.
//!
//! **Obeys reduced motion:** every start routes through the INPUT-10 `motion.Policy` — when
//! reduced motion is on, a tween reports its **end value immediately** (the transition snaps),
//! while the functional end state is always reached. The policy is the single gate INPUT-10
//! shipped for exactly this.
//!
//! Pure and SDL-free: fixed-capacity, no allocator, deterministic — unit-tested without a
//! renderer or a clock (the caller supplies `dt`).

const std = @import("std");
const motion = @import("./motion.zig");

/// Prototype functional-transition durations, in **seconds** (the CSS ms ÷ 1000), named so a
/// consumer cites the prototype token rather than a bare number. Not decorative — these are
/// the Holdings collapse, the stock-token font swap, and the board state changes.
pub const holdings_s: f32 = 0.120;
pub const stock_token_s: f32 = 0.090;
pub const board_s: f32 = 0.105; // the 100–110ms band, mid value

/// One scalar tween: a linear ramp from `from` to `to` over `duration` seconds, `elapsed`
/// tracking progress. A `duration <= 0` (or reduced motion) means "already at `to`". Plain
/// value type — copied freely, no allocation.
pub const Tween = struct {
    from: f32,
    to: f32,
    elapsed: f32 = 0,
    duration: f32,

    /// The interpolated value at the current `elapsed` — linear, clamped to `[0,1]` param.
    /// A non-positive duration reports `to` (instant).
    pub fn value(self: Tween) f32 {
        if (self.duration <= 0) return self.to;
        const t = std.math.clamp(self.elapsed / self.duration, 0, 1);
        return self.from + (self.to - self.from) * t;
    }

    /// Whether the ramp has reached its target.
    pub fn done(self: Tween) bool {
        return self.duration <= 0 or self.elapsed >= self.duration;
    }

    /// Advance by `dt` seconds (clamped at the duration so `value` lands exactly on `to`).
    pub fn advance(self: *Tween, dt: f32) void {
        self.elapsed = @min(self.elapsed + @max(0, dt), self.duration);
    }
};

/// A fixed, keyed table of active tweens. Bounded and non-allocating; a full table refuses a
/// new id (the transition simply snaps to its target via the caller's fallback — never a crash
/// or an allocation). The stable `u64` key is a node/domain id, so a tween is not lost across
/// reorder/filter/rebuild.
pub const Registry = struct {
    pub const cap = 64;

    const Slot = struct {
        id: u64 = 0,
        active: bool = false,
        tween: Tween = .{ .from = 0, .to = 0, .duration = 0 },
    };

    slots: [cap]Slot = [_]Slot{.{}} ** cap,
    policy: motion.Policy = .{},

    /// Install the reduced-motion policy (projected from `Resources.motion` once per frame,
    /// like `View.reduced_motion`). When on, every `retarget`/`from` reports the end state.
    pub fn setPolicy(self: *Registry, policy: motion.Policy) void {
        self.policy = policy;
    }

    fn find(self: *Registry, id: u64) ?*Slot {
        for (&self.slots) |*s| if (s.active and s.id == id) return s;
        return null;
    }
    fn claim(self: *Registry, id: u64) ?*Slot {
        for (&self.slots) |*s| if (!s.active) {
            s.* = .{ .id = id, .active = true, .tween = .{ .from = 0, .to = 0, .duration = 0 } };
            return s;
        };
        return null; // full — caller's `value` falls back to the target (snaps)
    }

    /// Redirect (or start) the tween keyed by `id` toward `to` over `duration` seconds.
    /// **Interrupt/reverse from the current value:** an existing tween restarts from whatever
    /// it currently shows (a smooth reversal), a new id starts from `to` (nothing to animate
    /// from). Under reduced motion the tween is set **immediately to `to`** (snaps). A full
    /// table drops the request — the consumer's `value(id, fallback)` then returns its target.
    pub fn retarget(self: *Registry, id: u64, to: f32, duration: f32) void {
        if (self.find(id)) |slot| {
            // Existing tween: interrupt/reverse from the current value.
            const cur = slot.tween.value();
            if (self.policy.reduced_motion or duration <= 0) {
                slot.tween = .{ .from = to, .to = to, .elapsed = 0, .duration = 0 }; // instant
                return;
            }
            // Already heading to this target and still moving: keep going (no restart).
            if (slot.tween.to == to and !slot.tween.done()) return;
            slot.tween = .{ .from = cur, .to = to, .elapsed = 0, .duration = duration };
            return;
        }
        // Brand-new id: nothing to animate from, so it simply sits at its target (a control's
        // first appearance is its current state, not a transition). Later retargets animate.
        const slot = self.claim(id) orelse return; // full table → caller's fallback snaps
        slot.tween = .{ .from = to, .to = to, .elapsed = 0, .duration = 0 };
    }

    /// Start a tween keyed by `id` explicitly from `start` toward `to` (e.g. seeding an
    /// initial reveal). Reduced motion snaps to `to`.
    pub fn from(self: *Registry, id: u64, start: f32, to: f32, duration: f32) void {
        const slot = self.find(id) orelse self.claim(id) orelse return;
        if (self.policy.reduced_motion or duration <= 0) {
            slot.tween = .{ .from = to, .to = to, .elapsed = 0, .duration = 0 };
            return;
        }
        slot.tween = .{ .from = start, .to = to, .elapsed = 0, .duration = duration };
    }

    /// The current value of the tween keyed by `id`, or `fallback` if no such tween exists
    /// (never animated, or dropped by a full table) — the consumer passes the target value as
    /// the fallback so an un-tweened control simply shows its end state.
    pub fn value(self: *Registry, id: u64, fallback: f32) f32 {
        const slot = self.find(id) orelse return fallback;
        return slot.tween.value();
    }

    /// Advance every active tween by `dt` seconds (the frame delta). Called once per frame.
    pub fn advance(self: *Registry, dt: f32) void {
        for (&self.slots) |*s| if (s.active) s.tween.advance(dt);
    }

    /// Drop the tween keyed by `id` (a consumer that disappears releases its slot). Idempotent.
    pub fn release(self: *Registry, id: u64) void {
        if (self.find(id)) |s| s.active = false;
    }

    /// How many tweens are active — for tests/diagnostics.
    pub fn activeCount(self: *const Registry) usize {
        var n: usize = 0;
        for (self.slots) |s| {
            if (s.active) n += 1;
        }
        return n;
    }
};

// ============================ Tests (deterministic, SDL-free) =========================

const testing = std.testing;

test "Tween: linear interpolation over the duration, clamped at the ends" {
    var t = Tween{ .from = 0, .to = 100, .duration = 0.1 };
    try testing.expectEqual(@as(f32, 0), t.value());
    t.advance(0.05); // half
    try testing.expectApproxEqAbs(@as(f32, 50), t.value(), 1e-4);
    t.advance(0.05); // full
    try testing.expectApproxEqAbs(@as(f32, 100), t.value(), 1e-4);
    try testing.expect(t.done());
    // Advancing past the end clamps at `to`.
    t.advance(1.0);
    try testing.expectApproxEqAbs(@as(f32, 100), t.value(), 1e-4);
}

test "Tween: a non-positive duration is instant at `to`" {
    const t = Tween{ .from = 0, .to = 42, .duration = 0 };
    try testing.expectEqual(@as(f32, 42), t.value());
    try testing.expect(t.done());
}

test "Registry: retarget starts a new id at its target and reverses from current on interrupt" {
    var r = Registry{};
    // New id: nothing to animate from, so it sits at the target (a first reveal has no source).
    r.retarget(1, 100, 0.1);
    try testing.expectApproxEqAbs(@as(f32, 100), r.value(1, 0), 1e-4);
    // Interrupt toward 0: it reverses from the CURRENT value (100).
    r.retarget(1, 0, 0.1);
    try testing.expectApproxEqAbs(@as(f32, 100), r.value(1, 0), 1e-4); // starts at current
    r.advance(0.05);
    try testing.expectApproxEqAbs(@as(f32, 50), r.value(1, 0), 1e-4); // halfway back
    // Interrupt again toward 100 mid-flight: reverses smoothly from 50, no jump.
    r.retarget(1, 100, 0.1);
    try testing.expectApproxEqAbs(@as(f32, 50), r.value(1, 0), 1e-4);
    r.advance(0.05);
    try testing.expectApproxEqAbs(@as(f32, 75), r.value(1, 0), 1e-4);
}

test "Registry: a repeated retarget to the same in-flight target does not restart" {
    var r = Registry{};
    r.from(1, 0, 100, 0.1);
    r.advance(0.05); // at 50, heading to 100
    r.retarget(1, 100, 0.1); // same target, still in flight → keep going
    try testing.expectApproxEqAbs(@as(f32, 50), r.value(1, 0), 1e-4); // not reset
    r.advance(0.05);
    try testing.expectApproxEqAbs(@as(f32, 100), r.value(1, 0), 1e-4);
}

test "Registry: reduced motion snaps to the target immediately" {
    var r = Registry{};
    r.setPolicy(.{ .reduced_motion = true });
    r.from(1, 0, 100, 0.1);
    try testing.expectApproxEqAbs(@as(f32, 100), r.value(1, 0), 1e-4); // no ramp
    r.retarget(1, 0, 0.1);
    try testing.expectApproxEqAbs(@as(f32, 0), r.value(1, 0), 1e-4); // snaps to new target
}

test "Registry: value falls back for an unknown id; keyed by stable id" {
    var r = Registry{};
    try testing.expectApproxEqAbs(@as(f32, 7), r.value(999, 7), 1e-4); // unknown → fallback
    // Two domain ids animate independently; identity is the key, not insertion order.
    r.from(10, 0, 30, 0.1);
    r.from(20, 0, 60, 0.1);
    r.advance(0.05);
    try testing.expectApproxEqAbs(@as(f32, 15), r.value(10, 0), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 30), r.value(20, 0), 1e-4);
    try testing.expectEqual(@as(usize, 2), r.activeCount());
    r.release(10);
    try testing.expectEqual(@as(usize, 1), r.activeCount());
    try testing.expectApproxEqAbs(@as(f32, 5), r.value(10, 5), 1e-4); // released → fallback
}

test "Registry: a full table drops new ids (the transition snaps via fallback)" {
    var r = Registry{};
    var i: u64 = 0;
    while (i < Registry.cap) : (i += 1) r.from(i + 1, 0, 1, 0.1);
    try testing.expectEqual(@as(usize, Registry.cap), r.activeCount());
    // One more id can't claim a slot; its `value` returns the fallback (its target), so the
    // control shows its end state with no animation rather than crashing/allocating.
    r.retarget(9999, 100, 0.1);
    try testing.expectApproxEqAbs(@as(f32, 100), r.value(9999, 100), 1e-4);
}

test "Registry: prototype durations are the CSS ms in seconds" {
    try testing.expectApproxEqAbs(@as(f32, 0.120), holdings_s, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.090), stock_token_s, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.105), board_s, 1e-6);
}
