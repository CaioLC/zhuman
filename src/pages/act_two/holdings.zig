//! `act_two/holdings` — Act II's content for the shared `holdings` rail template (ACT2-15):
//! every good the settlement owns (Act I's carried across the curtain beside Act II's) with its
//! short copy, the per-day FLOWS (generation vs
//! consumption; a positive flow `good`, a deficit `danger`), and **population-relevant** BODY
//! projections (how long the larder feeds everyone, when water runs short, the hall's
//! aggregate vigor). No decorative durability/maintenance meters: those systems do not exist.
//!
//! The roster is live; the flows and the Body sentences come from `fixtures.zig`, since no
//! population model computes them yet. Pure projection into the frame arena; no nodes.

const std = @import("std");
const ha = @import("ha");
const fx = @import("./fixtures.zig");

const comp = ha.comp;
const uic = ha.ui_client;
const World = ha.world.World;
const Entity = ha.world.Entity;

const t = @import("../templates/root.zig");
const Line = t.HoldingsLine;
const Sentence = t.HoldingsSentence;

/// Whether good `rec` is one the rail lists: owned. The settlement keeps what the household
/// built in Act I, so its goods list beside the Act II capital.
fn listed(count: u32) bool {
    return count > 0;
}

/// Project agent `e`'s settlement into the rail's content for this frame.
pub fn content(ctx: *uic.UiCtx, world: *World, e: Entity) !t.HoldingsContent {
    const a = ctx.arena;
    const cat = &ctx.res.catalog;

    var owned: std.ArrayList(Line) = .empty;
    var units: u32 = 0;
    if (world.get(e, comp.Goods)) |g| {
        for (cat.goods, 0..) |*rec, gi| {
            const n = g.count[gi];
            if (!listed(n)) continue;
            units += n;
            const label = if (n > 1) try a.print("{s} \u{00d7}{d}", .{ rec.name, n }) else rec.name;
            try owned.append(a, .{ .key = rec.id, .label = label, .value = rec.copy.short });
        }
    }

    const flows = try a.alloc(Line, fx.flows.len);
    for (fx.flows, flows) |f, *l| l.* = .{ .key = f.resource, .label = f.label, .value = f.value, .tone = if (f.positive) .good else .danger };

    const body = try a.alloc(Sentence, fx.body_projection.len);
    for (fx.body_projection, body) |b, *s| s.* = .{ .key = @tagName(b.key), .prefix = b.prefix, .value = if (b.key == .population) try a.print("{}", .{@as(u32, @intFromFloat(fx.populationOf(&ctx.res.sim)))}) else b.value, .suffix = b.suffix, .tone = if (b.positive) .good else .warn };

    return .{
        .count = try a.print("{d} KINDS, {d}", .{ owned.items.len, units }),
        .roster = owned.items,
        .empty_roster = "nothing established yet",
        .section_title = "FLOWS / DAY",
        .section = flows,
        .body = body,
    };
}

test "the body projection carries a deficit as well as a positive line" {
    var has_deficit = false;
    for (fx.body_projection) |b| {
        if (!b.positive) has_deficit = true;
    }
    try std.testing.expect(has_deficit); // low/positive semantics both represented
}
