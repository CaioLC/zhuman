//! `eating` — the **shared EatingPolicy/BODY math** (KIT-19), pure and deterministic so the
//! display and the (future) authoritative simulation compute the *same* numbers from one place.
//! The eating policy is a `0..100` slider value; this module maps it to the consumption rate
//! and the derived BODY projections. Leaf module — imports only `std`, no UI, no sim — so it is
//! fully unit-tested and callable from both the template and a system.
//!
//! Contract (exact, from the prototype):
//!   - **rate** = `0.5 × 4^(value/100)` — a smooth `0.5×..2.0×` curve, `1.0×` at `50`.
//!   - **word** thresholds on the slider value: `≤12 meager`, `≤28 lean`, `≤44 modest`,
//!     `≤58 normal`, `≤72 hearty`, `≤88 generous`, otherwise `lavish`.
//!   - **coverage** = `baseCoverage / rate` — how long the larder covers you (more eating ⇒
//!     less coverage). **recovery** = `max(0.1, baseRecovery / rate)` — days to recover, one
//!     decimal, floored at `0.1`.
//! Act configs (base coverage / base recovery): Act I `5.2 / 0.224`, Act II `10.3 / 0.448`.

const std = @import("std");

/// The eating rate for a slider value in `0..100`: `0.5 × 4^(value/100)`. Clamped to the value
/// domain, so the result is always within `0.5×..2.0×`.
pub fn rate(value: f32) f32 {
    const v = std.math.clamp(value, 0, 100);
    return 0.5 * std.math.pow(f32, 4.0, v / 100.0);
}

/// Map a persisted metabolism multiplier back onto the prototype's `0..100` slider domain.
/// This is the exact inverse of `rate`: `100 × log₄(rate / 0.5)`, clamped to `0.5×..2.0×`.
pub fn valueFromRate(r: f32) f32 {
    const clamped = std.math.clamp(r, 0.5, 2.0);
    return 100.0 * @log(clamped / 0.5) / @log(4.0);
}

/// The policy word for a slider value — the label the control shows and speaks.
pub fn word(value: f32) []const u8 {
    if (value <= 12) return "meager";
    if (value <= 28) return "lean";
    if (value <= 44) return "modest";
    if (value <= 58) return "normal";
    if (value <= 72) return "hearty";
    if (value <= 88) return "generous";
    return "lavish";
}

/// The per-act base coverage/recovery constants the projections divide by `rate`.
pub const Config = struct {
    base_coverage: f32,
    base_recovery: f32,

    pub const act_one: Config = .{ .base_coverage = 5.2, .base_recovery = 0.224 };
    pub const act_two: Config = .{ .base_coverage = 10.3, .base_recovery = 0.448 };
};

/// Days the larder covers at this rate: `baseCoverage / rate` (more eating ⇒ less coverage).
pub fn coverage(cfg: Config, r: f32) f32 {
    return cfg.base_coverage / r;
}

/// Days to recover at this rate: `max(0.1, baseRecovery / rate)` (floored, one-decimal display).
pub fn recovery(cfg: Config, r: f32) f32 {
    return @max(0.1, cfg.base_recovery / r);
}

// ============================ Tests =====================================================

test "rate: 0.5x..2.0x curve, 1.0x at the midpoint" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), rate(0), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), rate(50), 1e-3); // 0.5 * 4^0.5 = 0.5*2 = 1.0
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), rate(100), 1e-4);
    // Monotonic and bounded across the domain.
    try std.testing.expect(rate(25) > rate(0) and rate(25) < rate(50));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), rate(-10), 1e-4); // clamps low
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), rate(200), 1e-4); // clamps high
}

test "word thresholds partition the 0..100 range exactly" {
    try std.testing.expectEqualStrings("meager", word(0));
    try std.testing.expectEqualStrings("meager", word(12));
    try std.testing.expectEqualStrings("lean", word(13));
    try std.testing.expectEqualStrings("lean", word(28));
    try std.testing.expectEqualStrings("modest", word(44));
    try std.testing.expectEqualStrings("normal", word(50));
    try std.testing.expectEqualStrings("normal", word(58));
    try std.testing.expectEqualStrings("hearty", word(72));
    try std.testing.expectEqualStrings("generous", word(88));
    try std.testing.expectEqualStrings("lavish", word(89));
    try std.testing.expectEqualStrings("lavish", word(100));
}

test "valueFromRate is the clamped inverse of rate" {
    try std.testing.expectApproxEqAbs(@as(f32, 0), valueFromRate(0.5), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 50), valueFromRate(1.0), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 100), valueFromRate(2.0), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0), valueFromRate(0.1), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 100), valueFromRate(5.0), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 72), valueFromRate(rate(72)), 1e-3);
}

test "coverage and recovery divide the base by rate; recovery floors at 0.1" {
    const cfg = Config.act_one;
    // At the midpoint rate is 1.0, so the projections equal the base values.
    try std.testing.expectApproxEqAbs(@as(f32, 5.2), coverage(cfg, rate(50)), 1e-2);
    try std.testing.expectApproxEqAbs(@as(f32, 0.224), recovery(cfg, rate(50)), 1e-3);
    // At max rate (2.0) coverage halves; recovery is 0.224/2 = 0.112 (above the 0.1 floor).
    try std.testing.expectApproxEqAbs(@as(f32, 2.6), coverage(cfg, rate(100)), 1e-2);
    try std.testing.expectApproxEqAbs(@as(f32, 0.112), recovery(cfg, rate(100)), 1e-3);
}

test "act two config differs from act one" {
    try std.testing.expectApproxEqAbs(@as(f32, 10.3), Config.act_two.base_coverage, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.448), Config.act_two.base_recovery, 1e-4);
    // Recovery floor: a tiny base over a big rate still clamps to 0.1.
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), recovery(.{ .base_coverage = 1, .base_recovery = 0.05 }, 2.0), 1e-4);
}
