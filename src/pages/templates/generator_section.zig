//! `generator_section` — owned collectable capital as action-like tiles, the same GENERATORS
//! view in every act (`Shelf`: which acts' generators, the tile density).
//!
//! Generators mature on simulation time without occupying `Busy`. Each owned generator is a
//! `generator_tile` (collect on the body, the mode corner on its lower right), laid in two
//! lanes in authored good order.

const std = @import("std");
const ha = @import("ha");

const comp = ha.sim.comp;
const roster = ha.sim.data.roster;
const World = ha.sim.ecs.World;
const Entity = ha.sim.ecs.Entity;

const uic = ha.ui_client;
const style = uic.style;
const El = uic.elements.El;

const action_tile = @import("./action_tile.zig");
const browser = @import("./browser.zig");
const generator_tile = @import("./generator_tile.zig");

const section_gap: f32 = 12;
const grid_gap: f32 = 10;
/// The compact shelf packs its tiles tighter, as Act II's catalog does.
const compact_grid_gap: f32 = 6;

/// One act's GENERATORS content. Act I lists its own generators; Act II lists the union of
/// both acts' (the settlement keeps what the household built), at the act's compact density.
pub const Shelf = struct {
    /// The latest act whose generators the shelf lists.
    through_act: u8,
    density: action_tile.Density = .regular,
    subtitle: []const u8 = "Let time accumulate, then collect without stopping your work.",

    fn holds(self: Shelf, rec: roster.Good) bool {
        return rec.act <= self.through_act and rec.generator != null;
    }
};

fn ownedCount(world: *const World, e: Entity, cat: *const roster.Catalog, shelf: Shelf) usize {
    const goods = world.get(e, comp.Goods) orelse return 0;
    var count: usize = 0;
    for (cat.goods, 0..) |rec, gi| {
        if (shelf.holds(rec) and goods.count[gi] > 0) count += 1;
    }
    return count;
}

/// Build the act's generator shelf in authored good order.
pub fn generator_section(parent: El, world: *const World, e: Entity, id: []const u8, shelf: Shelf) !El {
    const ctx = parent.ctx;
    const cat = &ctx.res.game.catalog;
    const compact = ctx.res.view.metrics.width_class.atMost(.w440);
    const count = ownedCount(world, e, cat, shelf);
    const act = ha.sim.data.migration.actOf(world, e);
    const gap = if (shelf.density == .compact) compact_grid_gap else grid_gap;

    const section = try parent.box(id, .{
        .w = .{ .pct_of_parent = 1.0 }, .h = .fit_children, .flow = .{ .dir = .column, .cross = .start },
        .gap = section_gap,
    }, .{});

    var count_buf: [24]u8 = undefined;
    const count_text = std.mem.print(&count_buf, "{d} OWNED", .{count}) catch "OWNED";
    _ = try browser.browser_heading(section, "heading", "GENERATORS", shelf.subtitle, count_text);

    if (count == 0) {
        try section.label("empty", "Build a generator to begin accumulating.", .{ style.body, style.faint });
        return section;
    }

    const grid = try section.box("grid", .{ .w = .{ .pct_of_parent = 1.0 }, .h = .fit_children }, .{});
    const lanes: [2]El = if (compact) blk: {
        grid.set(.{ .flow = .{ .dir = .column, .cross = .start }, .gap = gap }, .{});
        break :blk .{ grid, grid };
    } else blk: {
        grid.set(.{ .flow = .{ .dir = .row, .cross = .start }, .gap = gap }, .{});
        const left = try grid.box("left", .{ .w = .grow, .h = .fit_children, .flow = .{ .dir = .column }, .gap = gap }, .{});
        const right = try grid.box("right", .{ .w = .grow, .h = .fit_children, .flow = .{ .dir = .column }, .gap = gap }, .{});
        break :blk .{ left, right };
    };

    const goods = world.get(e, comp.Goods).?;
    var lane: usize = 0;
    for (cat.goods, 0..) |rec, gi| {
        if (!shelf.holds(rec) or goods.count[gi] == 0) continue;
        _ = try generator_tile.generatorTile(lanes[lane % 2], world, e, act, @intCast(gi), shelf.density, .none);
        lane += 1;
    }
    return section;
}
