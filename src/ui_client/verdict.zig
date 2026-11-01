//! `verdict` — what a value from game data **means**, as a word a template states instead of
//! picking a colour: `met`/`unmet`, `gain`/`spent`, `better`/`worse`, `flat`, `absent`,
//! `inactive`, `refused`, `over`, `low`, `attention`. One table (`Roles`) maps each verdict to
//! a theme role; it lives on the view (`res.view.verdicts`) beside the theme, so a game that
//! wants different meanings replaces the table the way it replaces the palette.
//!
//! The helpers (`when`, `of`, `trade`, `margin` and their delta forms) are pure: they turn a
//! fact into a verdict without a ctx. Every comparison of two amounts goes through one
//! tolerance, `delta_eps`.
//!
//! A **leaf module**, like `theme.zig`: it imports only that, so `res.zig` can hold a `Roles`
//! on `View` without an import cycle.

const std = @import("std");
const theme = @import("./theme.zig");

const Role = theme.Role;

/// What a value means. Each tag names a field of `Roles`.
pub const Verdict = enum {
    /// A requirement satisfied, a match found.
    met,
    /// A requirement not satisfied.
    unmet,
    /// A stock that a trade raises.
    gain,
    /// A stock that a trade lowers (an outflow, not a loss).
    spent,
    /// A margin moved the good way from its baseline.
    better,
    /// A margin moved the bad way from its baseline.
    worse,
    /// A value equal to its baseline, within `delta_eps`.
    flat,
    /// An empty readout: no takers, a zero line, nothing you hold.
    absent,
    /// The name of a thing not engaged: an unposted good, a non-matching person, a strip while
    /// its merchant is away, a readout under a disabled control.
    inactive,
    /// A term the counterparty refuses.
    refused,
    /// Past a limit: over budget, a negative balance after a deal.
    over,
    /// A threshold breached: food lasts under two days, food at 0.
    low,
    /// A call to act: nothing posted, water running short.
    attention,
};

/// The role each verdict paints with. Every field is defaulted; a game replaces the whole
/// table, or one field of it, on `res.view.verdicts`.
pub const Roles = struct {
    met: Role = .good,
    unmet: Role = .danger,
    gain: Role = .good,
    spent: Role = .warn,
    better: Role = .good,
    worse: Role = .danger,
    flat: Role = .fg,
    absent: Role = .line2,
    inactive: Role = .dim,
    refused: Role = .line2,
    over: Role = .danger,
    low: Role = .danger,
    attention: Role = .warn,
};

comptime {
    // One field per verdict, in the same order, so neither can gain a tag the other lacks.
    const fields = @typeInfo(Roles).@"struct".field_names;
    const tags = @typeInfo(Verdict).@"enum".field_names;
    std.debug.assert(fields.len == tags.len);
    for (fields, tags) |f, t| std.debug.assert(std.mem.eql(u8, f, t));
}

/// The role `table` gives verdict `v`.
pub fn role(table: Roles, v: Verdict) Role {
    return switch (v) {
        inline else => |tag| @field(table, @tagName(tag)),
    };
}

/// The one tolerance for comparing two amounts: values this close or closer are equal.
pub const delta_eps: f32 = 0.001;

/// `v` while `cond` holds, else no verdict (the style's resting ink stays).
pub fn when(cond: bool, v: Verdict) ?Verdict {
    return if (cond) v else null;
}

/// `yes` while `cond` holds, else `no`.
pub fn of(cond: bool, yes: Verdict, no: Verdict) Verdict {
    return if (cond) yes else no;
}

/// A stock a trade moves from `before` to `after`: `gain` above it by more than `delta_eps`,
/// `spent` below it by more, else `flat`.
pub fn trade(after: f32, before: f32) Verdict {
    if (after > before + delta_eps) return .gain;
    if (after < before - delta_eps) return .spent;
    return .flat;
}

/// `trade` for a change `d` already taken (`after - before`).
pub fn tradeDelta(d: f32) Verdict {
    return trade(d, 0);
}

/// Which way a margin improves.
pub const Better = enum { higher, lower };

/// A margin at `live` against its baseline `base`: `better` or `worse` when it moved by more
/// than `delta_eps` (which is which follows `dir`), else `flat`.
pub fn margin(live: f32, base: f32, comptime dir: Better) Verdict {
    const up: ?bool = if (live > base + delta_eps) true else if (live < base - delta_eps) false else null;
    const rose = up orelse return .flat;
    return if (rose == (dir == .higher)) .better else .worse;
}

/// `margin` for a change `d` from a zero baseline (a per-day flow).
pub fn marginDelta(d: f32, comptime dir: Better) Verdict {
    return margin(d, 0, dir);
}

// ============================ Tests =====================================================

const testing = std.testing;

test "verdict: the default table maps every verdict to its role" {
    const t: Roles = .{};
    const want = [_]struct { Verdict, Role }{
        .{ .met, .good },       .{ .unmet, .danger },  .{ .gain, .good },
        .{ .spent, .warn },     .{ .better, .good },   .{ .worse, .danger },
        .{ .flat, .fg },        .{ .absent, .line2 },  .{ .inactive, .dim },
        .{ .refused, .line2 },  .{ .over, .danger },   .{ .low, .danger },
        .{ .attention, .warn },
    };
    try testing.expectEqual(@typeInfo(Verdict).@"enum".field_names.len, want.len);
    for (want) |w| try testing.expectEqual(w[1], role(t, w[0]));
}

test "verdict: a replaced table changes the role" {
    const t: Roles = .{ .spent = .danger, .flat = .dim };
    try testing.expectEqual(Role.danger, role(t, .spent));
    try testing.expectEqual(Role.dim, role(t, .flat));
    try testing.expectEqual(Role.good, role(t, .gain)); // the rest keep their defaults
}

test "verdict: when and of" {
    try testing.expectEqual(@as(?Verdict, .over), when(true, .over));
    try testing.expectEqual(@as(?Verdict, null), when(false, .over));
    try testing.expectEqual(Verdict.met, of(true, .met, .absent));
    try testing.expectEqual(Verdict.absent, of(false, .met, .absent));
}

test "verdict: trade is gain, spent or flat, with exactly delta_eps apart flat" {
    try testing.expectEqual(Verdict.gain, trade(5, 3));
    try testing.expectEqual(Verdict.spent, trade(3, 5));
    try testing.expectEqual(Verdict.flat, trade(4, 4));
    // The boundary: exactly eps apart is flat, a hair beyond is not.
    try testing.expectEqual(Verdict.flat, trade(delta_eps, 0));
    try testing.expectEqual(Verdict.flat, trade(-delta_eps, 0));
    try testing.expectEqual(Verdict.gain, trade(0.0011, 0));
    try testing.expectEqual(Verdict.spent, trade(-0.0011, 0));
    try testing.expectEqual(Verdict.flat, trade(10.0005, 10));
    try testing.expectEqual(Verdict.gain, tradeDelta(0.0011));
    try testing.expectEqual(Verdict.spent, tradeDelta(-0.0011));
    try testing.expectEqual(Verdict.flat, tradeDelta(delta_eps));
}

test "verdict: margin follows the better direction, with exactly delta_eps apart flat" {
    try testing.expectEqual(Verdict.better, margin(2, 1, .higher));
    try testing.expectEqual(Verdict.worse, margin(0, 1, .higher));
    try testing.expectEqual(Verdict.better, margin(1.4, 1.7, .lower));
    try testing.expectEqual(Verdict.worse, margin(0.1, 0.05, .lower));
    try testing.expectEqual(Verdict.flat, margin(0.05, 0.05, .lower));
    // The boundary, both directions.
    try testing.expectEqual(Verdict.flat, margin(delta_eps, 0, .higher));
    try testing.expectEqual(Verdict.flat, margin(-delta_eps, 0, .lower));
    try testing.expectEqual(Verdict.better, margin(0.0011, 0, .higher));
    try testing.expectEqual(Verdict.worse, margin(0.0011, 0, .lower));
    try testing.expectEqual(Verdict.worse, margin(-0.0011, 0, .higher));
    try testing.expectEqual(Verdict.better, margin(-0.0011, 0, .lower));
    // A flow of exactly zero is flat; a flow either side is better or worse.
    try testing.expectEqual(Verdict.flat, marginDelta(0, .higher));
    try testing.expectEqual(Verdict.better, marginDelta(6, .higher));
    try testing.expectEqual(Verdict.worse, marginDelta(-3, .higher));
}
