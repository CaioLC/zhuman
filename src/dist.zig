//! Yield distributions — the risk profile of an action's payoff.
//!
//! Each action draws its yield from one of these; the *spread is the uncertainty* (there's
//! no separate success roll). `stats` returns the p10–p90 band (and mean) for display;
//! `sample` draws one outcome, always >= 0. Leaf module — imports only `std`; `sample`
//! takes the sim's `std.Random` so chance stays sourced from `res.random()`.

const std = @import("std");

pub const Kind = enum { normal, poisson, uniform, exponential };

/// A yield distribution. `s` is the scale — the mean for `normal`/`poisson`, and the knob
/// that sets the range for `uniform`/`exponential`. `sd` is the standard deviation for
/// `normal` only (0 ⇒ derive `0.3·s`); ignored by the other kinds.
pub const Dist = struct {
    kind: Kind,
    s: f32,
    sd: f32 = 0,
};

/// Display summary: the p10–p90 band (10th–90th percentile) and the mean.
pub const Stats = struct { p10: f32, p90: f32, mean: f32 };

/// z-score for the 10th/90th percentile of a normal — used to band normal & poisson.
const z90: f32 = 1.2816;

fn scaleOf(d: Dist) f32 {
    return @max(0.2, d.s);
}

fn normalSd(d: Dist) f32 {
    return @max(0.3, if (d.sd != 0) d.sd else 0.3 * scaleOf(d));
}

/// The p10–p90 band + mean, for the action label. Pure.
pub fn stats(d: Dist) Stats {
    const s = scaleOf(d);
    return switch (d.kind) {
        .normal => blk: {
            const sd = normalSd(d);
            break :blk .{ .p10 = @max(0, s - z90 * sd), .p90 = s + z90 * sd, .mean = s };
        },
        .poisson => blk: {
            const sd = @sqrt(s);
            break :blk .{ .p10 = @max(0, s - z90 * sd), .p90 = s + z90 * sd, .mean = s };
        },
        .uniform => blk: {
            const lo = @max(0, 0.25 * s);
            const hi = 1.6 * s;
            break :blk .{ .p10 = lo + 0.1 * (hi - lo), .p90 = lo + 0.9 * (hi - lo), .mean = (lo + hi) / 2 };
        },
        .exponential => blk: {
            const m = @max(0.5, s);
            // exponential quantile is -m·ln(1-p): p10 at p=0.1, p90 at p=0.9.
            break :blk .{ .p10 = -m * @log(0.9), .p90 = -m * @log(0.1), .mean = m };
        },
    };
}

/// Draw one yield sample (>= 0). `rng` is the sim's single source of chance.
pub fn sample(d: Dist, rng: std.Random) f32 {
    const s = scaleOf(d);
    return switch (d.kind) {
        .normal => @max(0, gauss(rng) * normalSd(d) + s),
        .poisson => @floatFromInt(poisson(rng, s)),
        .uniform => blk: {
            const lo = @max(0, 0.25 * s);
            const hi = 1.6 * s;
            break :blk lo + rng.float(f32) * (hi - lo);
        },
        .exponential => blk: {
            const m = @max(0.5, s);
            break :blk -m * @log(1 - rng.float(f32));
        },
    };
}

/// Standard normal via Box–Muller (rejects 0 to keep `@log` finite).
fn gauss(rng: std.Random) f32 {
    var u: f32 = 0;
    var v: f32 = 0;
    while (u == 0) u = rng.float(f32);
    while (v == 0) v = rng.float(f32);
    return @sqrt(-2 * @log(u)) * @cos(2 * std.math.pi * v);
}

/// Knuth's sampler for a poisson with mean `lambda`.
fn poisson(rng: std.Random, lambda: f32) u32 {
    const l = @exp(-@max(0.2, lambda));
    var k: u32 = 0;
    var p: f32 = 1;
    while (true) {
        k += 1;
        p *= rng.float(f32);
        if (p <= l) break;
    }
    return k - 1;
}

test "stats bands p10 < mean < p90, all non-negative" {
    for ([_]Dist{
        .{ .kind = .normal, .s = 4, .sd = 1.6 },
        .{ .kind = .poisson, .s = 6 },
        .{ .kind = .uniform, .s = 5 },
        .{ .kind = .exponential, .s = 6 },
    }) |d| {
        const st = stats(d);
        try std.testing.expect(st.p10 >= 0);
        try std.testing.expect(st.p10 < st.mean);
        try std.testing.expect(st.mean < st.p90);
    }
}

test "samples are non-negative across kinds" {
    var prng = std.Random.DefaultPrng.init(0xABCDEF);
    const rng = prng.random();
    for ([_]Dist{
        .{ .kind = .normal, .s = 4, .sd = 1.6 },
        .{ .kind = .poisson, .s = 6 },
        .{ .kind = .uniform, .s = 5 },
        .{ .kind = .exponential, .s = 6 },
    }) |d| {
        var i: usize = 0;
        while (i < 2000) : (i += 1) try std.testing.expect(sample(d, rng) >= 0);
    }
}

test "poisson sample mean converges to lambda" {
    var prng = std.Random.DefaultPrng.init(1);
    const rng = prng.random();
    const d = Dist{ .kind = .poisson, .s = 6 };
    var sum: f64 = 0;
    const n = 50000;
    var i: usize = 0;
    while (i < n) : (i += 1) sum += sample(d, rng);
    try std.testing.expect(@abs(sum / @as(f64, n) - 6) < 0.15);
}
