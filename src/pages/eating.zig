//! `eating` — the **shared EatingPolicy/BODY math**, pure and deterministic so every
//! caller computes the *same* numbers from one place.
//! The eating policy is a `0..100` slider value; this module maps it to the consumption rate
//! and the derived BODY projections. Leaf module — imports only `std`, no UI, no sim — so it is
//! fully unit-tested and callable from both the template and a system.
//!
//! Contract (exact, from the prototype):
//!   - **rate** is two exponential halves that meet at normal, `1.0×` at `50`: the lower half
//!     climbs from the band's minimum, the upper to its maximum. The band is the caller's
//!     (`Band.of` reads it from the sim's `Config`), so the numbers live there. The lower half
//!     is a ration; the upper half is a feast, steep on purpose.
//!   - **word** thresholds on the slider value: `≤12 meager`, `≤28 lean`, `≤44 modest`,
//!     `≤58 normal`, `≤72 hearty`, `≤88 generous`, otherwise `lavish`.
//!   - **coverage** = `baseCoverage / rate` — how long the larder covers you (more eating ⇒
//!     less coverage). **recovery** = `max(0.1, baseRecovery / rate)` — days to recover, one
//!     decimal, floored at `0.1`.
//! Act configs (base coverage / base recovery): Act I `5.2 / 0.224`, Act II `10.3 / 0.448`.

const std = @import("std");

/// The rates at the slider's ends; `1.0×` sits at the midpoint.
pub const Band = struct {
    min: f32,
    max: f32,

    /// The band a config owns: its `metabolism_rate_min` and `metabolism_rate_max`.
    pub fn of(cfg: anytype) Band {
        return .{ .min = cfg.metabolism_rate_min, .max = cfg.metabolism_rate_max };
    }
};

/// The eating rate for a slider value in `0..100`: geometric from `band.min` to `1.0×` up to
/// the midpoint and from `1.0×` to `band.max` above it. Clamped to the value domain, so the
/// result is always within the band.
pub fn rate(value: f32, band: Band) f32 {
    const v = std.math.clamp(value, 0, 100);
    if (v <= 50) return band.min * std.math.pow(f32, 1.0 / band.min, v / 50.0);
    return std.math.pow(f32, band.max, (v - 50.0) / 50.0);
}

/// Map a persisted metabolism multiplier back onto the `0..100` slider domain: the exact
/// inverse of `rate`, clamped to the band.
pub fn valueFromRate(r: f32, band: Band) f32 {
    const clamped = std.math.clamp(r, band.min, band.max);
    if (clamped <= 1.0) return 50.0 * @log(clamped / band.min) / @log(1.0 / band.min);
    return 50.0 + 50.0 * @log(clamped) / @log(band.max);
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

/// A band for the tests: any ends either side of normal.
const test_band = Band{ .min = 0.5, .max = 5.0 };

test "rate: the band's ends in two halves, 1.0x at the midpoint" {
    const band = test_band;
    try std.testing.expectApproxEqAbs(band.min, rate(0, band), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), rate(50, band), 1e-3);
    try std.testing.expectApproxEqAbs(band.max, rate(100, band), 1e-3);
    try std.testing.expectApproxEqAbs(@sqrt(band.min), rate(25, band), 1e-3); // halfway down the ration
    try std.testing.expectApproxEqAbs(@sqrt(band.max), rate(75, band), 1e-3); // halfway up the feast
    // Monotonic across the domain, continuous at the midpoint.
    try std.testing.expect(rate(51, band) - rate(50, band) < 0.1);
    var v: f32 = 0;
    while (v < 100) : (v += 1) try std.testing.expect(rate(v + 1, band) > rate(v, band));
    try std.testing.expectApproxEqAbs(band.min, rate(-10, band), 1e-4); // clamps low
    try std.testing.expectApproxEqAbs(band.max, rate(200, band), 1e-3); // clamps high
    // Another band moves the ends and keeps the midpoint.
    const wide = Band{ .min = 0.25, .max = 20 };
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), rate(0, wide), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), rate(50, wide), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 20), rate(100, wide), 1e-3);
}

test "Band.of reads the ends from a config" {
    const band = Band.of(.{ .metabolism_rate_min = @as(f32, 0.5), .metabolism_rate_max = @as(f32, 3) });
    try std.testing.expectEqual(@as(f32, 0.5), band.min);
    try std.testing.expectEqual(@as(f32, 3), band.max);
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
    const band = test_band;
    try std.testing.expectApproxEqAbs(@as(f32, 0), valueFromRate(band.min, band), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 50), valueFromRate(1.0, band), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 100), valueFromRate(band.max, band), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0), valueFromRate(band.min / 5, band), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 100), valueFromRate(band.max * 10, band), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 30), valueFromRate(rate(30, band), band), 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 72), valueFromRate(rate(72, band), band), 1e-3);
}

test "coverage and recovery divide the base by rate; recovery floors at 0.1" {
    const cfg = Config.act_one;
    // At the normal rate the projections equal the base values.
    try std.testing.expectApproxEqAbs(@as(f32, 5.2), coverage(cfg, 1.0), 1e-2);
    try std.testing.expectApproxEqAbs(@as(f32, 0.224), recovery(cfg, 1.0), 1e-3);
    // At twice the rate coverage halves; recovery is 0.224/2 = 0.112 (above the 0.1 floor).
    try std.testing.expectApproxEqAbs(@as(f32, 2.6), coverage(cfg, 2.0), 1e-2);
    try std.testing.expectApproxEqAbs(@as(f32, 0.112), recovery(cfg, 2.0), 1e-3);
}

test "act two config differs from act one" {
    try std.testing.expectApproxEqAbs(@as(f32, 10.3), Config.act_two.base_coverage, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.448), Config.act_two.base_recovery, 1e-4);
    // Recovery floor: a tiny base over a big rate still clamps to 0.1.
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), recovery(.{ .base_coverage = 1, .base_recovery = 0.05 }, 2.0), 1e-4);
}
