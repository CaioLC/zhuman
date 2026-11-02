//! The condition band: the one place the two vigor thresholds (`Config.condition`) are applied
//! to an agent. `refresh` brings a `comp.Condition` up to date with the vigor and returns the
//! crossing when the band moved, so whoever calls it decides what the crossing means.
//!
//! The `condition` system (`systems/condition.zig`) is the component's writer, and every
//! crossing it reports is worded as the metabolism's ("You feel weak with hunger."). A rule
//! that lowers the vigor fraction itself calls `refresh` on that agent right after the charge,
//! because the log words labor's own drop differently (`WorkBegun.weary`, "You feel weak. Work
//! will yield less."), and a writer that only compares with the previous value cannot tell the
//! two causes apart: `actions.begin` and `capital.begin` refresh and carry the crossing on
//! `WorkBegun`, and `capital.collect_generator`, whose collection energy can outweigh the vigor
//! it restores, refreshes so a collection is not reported as hunger. Nothing else lowers the
//! fraction (a ceiling change through `effects.apply` can only raise it), so no other rule
//! calls it.

const std = @import("std");
const comp = @import("../components.zig");
const Config = @import("../res.zig").Config;

pub const Band = comp.Condition.Band;

/// A band change: where the agent was and where it is now.
pub const Crossing = struct { from: Band, to: Band };

/// Set `cond` to the band `vigor` falls in. Returns the crossing when the band changed, else
/// null; a second call on the same vigor returns null.
pub fn refresh(cfg: *const Config, vigor: *const comp.Vigor, cond: *comp.Condition) ?Crossing {
    const now = cfg.condition(vigor.v / vigor.max);
    if (now == cond.band) return null;
    const was = cond.band;
    cond.band = now;
    return .{ .from = was, .to = now };
}

/// Whether a crossing is the first step out of `alive`: what `WorkBegun.weary` says.
pub fn wearied(crossing: ?Crossing) bool {
    const c = crossing orelse return false;
    return c.from == .alive and c.to != .alive;
}

// ============================ Tests ==========================================

const testing = std.testing;

test "refresh writes the band, reports a crossing once, and nothing on an unchanged vigor" {
    const cfg = Config{};
    var cond = comp.Condition{};
    var vigor = comp.Vigor{ .v = 10, .max = 10 };
    try testing.expect(refresh(&cfg, &vigor, &cond) == null);
    vigor.v = 3.4; // below the WEARY 35%
    try testing.expectEqual(Crossing{ .from = .alive, .to = .weary }, refresh(&cfg, &vigor, &cond).?);
    try testing.expectEqual(Band.weary, cond.band);
    try testing.expect(refresh(&cfg, &vigor, &cond) == null);
    vigor.v = 1.0; // below the SPENT 12%
    try testing.expectEqual(Crossing{ .from = .weary, .to = .spent }, refresh(&cfg, &vigor, &cond).?);
    vigor.v = 9;
    try testing.expectEqual(Crossing{ .from = .spent, .to = .alive }, refresh(&cfg, &vigor, &cond).?);
}

test "wearied is a fall out of alive, and nothing else" {
    try testing.expect(wearied(.{ .from = .alive, .to = .weary }));
    try testing.expect(wearied(.{ .from = .alive, .to = .spent }));
    try testing.expect(!wearied(.{ .from = .weary, .to = .spent }));
    try testing.expect(!wearied(.{ .from = .weary, .to = .alive }));
    try testing.expect(!wearied(null));
}
