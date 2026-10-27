//! `reload` — the authored roster, reloaded while the game runs.
//!
//! A `data/` directory in the working directory — beside `assets/`, where the game finds its
//! other files — overrides the shipped files one by one: at startup (`Resources.init` reads it
//! through `roster.loadData`) and whenever one of its files changes. `Watch` looks at their
//! modification times at most twice a second, and `reload` re-parses. A load that fails — a
//! parse error, a broken reference, an unreadable file — keeps the catalog in place and logs
//! why, to the console in full and to the event log in one line; a load that succeeds says
//! so in the event log.
//!
//! A load that succeeds is swapped in. Everything kept by catalog index is carried to the new
//! indices by id: each agent's goods, generator progress/toggles and research, the work in
//! progress, and the reach seen-set.
//! A record the new files no longer hold takes its count, its research state and any work on
//! it with it. Then every agent resettles its body and larder against the new records. The
//! swap runs between frames, before the systems and the page build, so nothing still reads the
//! old records when they are freed: the text caches, the semantic snapshot and the event log
//! copy their strings, and a node tree lives one frame.

const std = @import("std");
const ha = @import("ha");
const comp = ha.comp;
const roster = ha.roster;
const capital = ha.capital;
const ecs = @import("./ecs.zig");
const world = @import("./world.zig");
const res_mod = @import("./res.zig");

const World = world.World;
const Entity = world.Entity;
const Resources = res_mod.Resources;
const Catalog = roster.Catalog;

const file_names = @typeInfo(roster.File).@"enum".field_names;

/// The modification times of the data files, looked at on a timer.
pub const Watch = struct {
    stamps: [file_names.len]i128 = @splat(0),
    primed: bool = false,
    wait: f32 = 0,

    /// How often, in seconds, the files are looked at.
    pub const period: f32 = 0.5;

    /// Whether a data file appeared, changed or went away since the last look. Looks at most
    /// every `period` seconds of `dt`; the first look only records what is there, since the
    /// startup load already read it.
    pub fn poll(self: *Watch, io: std.Io, dt: f32) bool {
        self.wait -= dt;
        if (self.wait > 0) return false;
        self.wait = period;
        var dir = std.Io.Dir.cwd().openDir(io, roster.data_dir, .{}) catch return self.look(io, null);
        defer dir.close(io);
        return self.look(io, dir);
    }

    /// Record the files' times in `dir` (none when null); true when they differ from the last.
    pub fn look(self: *Watch, io: std.Io, dir: ?std.Io.Dir) bool {
        var now: [file_names.len]i128 = @splat(0);
        if (dir) |d| {
            inline for (file_names, 0..) |name, i| {
                const file: roster.File = @field(roster.File, name);
                if (d.statFile(io, std.fs.path.basename(file.path()), .{})) |st| now[i] = st.mtime.nanoseconds else |_| {}
            }
        }
        const differs = self.primed and !std.mem.eql(i128, &now, &self.stamps);
        self.stamps = now;
        self.primed = true;
        return differs;
    }
};

/// Re-read `data/` (the shipped files where it has none) and swap the result in, or keep the
/// catalog and log why.
pub fn reload(io: std.Io, res: *Resources, w: *World) void {
    var diag = roster.Diagnostics{};
    const next = roster.loadData(res.catalog.arena.child_allocator, io, &diag) catch |err| return refuse(res, err, &diag);
    swap(res, w, next);
    res.sim.log.push(.dim, "The roster reloaded from data/.");
}

/// `reload` from a given directory.
pub fn reloadDir(io: std.Io, res: *Resources, w: *World, dir: std.Io.Dir) void {
    var diag = roster.Diagnostics{};
    const next = roster.loadDir(res.catalog.arena.child_allocator, io, dir, &diag) catch |err| return refuse(res, err, &diag);
    swap(res, w, next);
    res.sim.log.push(.dim, "The roster reloaded from data/.");
}

fn refuse(res: *Resources, err: roster.Error, diag: *const roster.Diagnostics) void {
    switch (err) {
        error.OutOfMemory => std.log.warn("roster reload: out of memory", .{}),
        error.Invalid => std.log.warn("roster reload: {s}", .{diag.message()}),
    }
    var buf: [96]u8 = undefined;
    const msg = std.mem.print(&buf, "The data did not load ({s}); the old roster stays.", .{diag.file.path()}) catch
        "The data did not load; the old roster stays.";
    res.sim.log.push(.danger, msg);
}

/// Install `next` as the catalog, carrying every index-keyed state to it by id, resettling
/// every agent, and freeing the catalog it replaces.
pub fn swap(res: *Resources, w: *World, next: Catalog) void {
    var old = res.catalog;
    res.catalog = next;
    const cat = &res.catalog;

    // Goods: each count follows its id.
    {
        var q: ecs.Query(.{comp.Goods}) = .{ .world = w };
        var it = q.iter();
        while (it.next()) |entry| {
            const goods: *comp.Goods = entry;
            const was = goods.*;
            goods.* = .{};
            for (old.goods, 0..) |g, gi| {
                if (was.count[gi] == 0) continue;
                if (cat.goodIndex(g.id)) |ni| goods.count[ni] = was.count[gi];
            }
        }
    }

    // Generator progress and toggles follow the good id independently of ownership counts.
    {
        var q: ecs.Query(.{comp.Generators}) = .{ .world = w };
        var it = q.iter();
        while (it.next()) |entry| {
            const generators: *comp.Generators = entry;
            const was = generators.*;
            generators.* = .{};
            for (old.goods, 0..) |g, gi| {
                if (cat.goodIndex(g.id)) |ni| {
                    generators.progress[ni] = was.progress[gi];
                    generators.off[ni] = was.off[gi];
                }
            }
        }
    }

    // Research: each tile's state follows its id; a tile new to the files opens at its entry
    // state.
    {
        var q: ecs.Query(.{comp.Research}) = .{ .world = w };
        var it = q.iter();
        while (it.next()) |entry| {
            const research: *comp.Research = entry;
            const was = research.*;
            research.* = comp.Research.entry(cat);
            for (old.technologies, 0..) |t, ti| {
                if (cat.techIndex(t.id)) |ni| research.state[ni] = was.state[ti];
            }
        }
    }

    // Work in progress: the verb or recipe follows its id; work on a record that is gone stops.
    {
        var gone: [world.MAX_ENTITIES]Entity = undefined;
        var n: usize = 0;
        var q: ecs.Query(.{ Entity, comp.Busy }) = .{ .world = w };
        var it = q.iter();
        while (it.next()) |entry| {
            const e: Entity, const busy: *comp.Busy = entry;
            const moved: ?comp.Busy.Doing = switch (busy.doing) {
                .labor => |ai| if (cat.actionIndex(old.actions[ai].id)) |ni| .{ .labor = ni } else null,
                .build => |gi| if (cat.goodIndex(old.goods[gi].id)) |ni| .{ .build = ni } else null,
            };
            if (moved) |d| busy.doing = d else {
                gone[n] = e;
                n += 1;
            }
        }
        for (gone[0..n]) |e| {
            w.remove(e, comp.Busy);
            res.sim.log.push(.warn, "The work in progress is gone from the roster.");
        }
    }

    // The reach seen-set follows its ids.
    {
        var seen: [roster.max_goods]bool = @splat(false);
        for (old.goods, 0..) |g, gi| {
            if (!res.sim.reach_seen[gi]) continue;
            if (cat.goodIndex(g.id)) |ni| seen[ni] = true;
        }
        res.sim.reach_seen = seen;
    }

    // Every agent's body and larder against the new records.
    {
        var q: ecs.Query(.{ Entity, comp.Goods }) = .{ .world = w };
        var it = q.iter();
        while (it.next()) |entry| capital.settle(w, entry[0], cat);
    }

    old.deinit();
}

// ============================ Tests =====================================================

const testing = std.testing;

const actions_a =
    \\.{
    \\    .{ .id = "forage", .name = "Forage", .innate = true, .requires = .{ .energy = 1.0, .hours = 1.0 } },
    \\    .{ .id = "fish", .name = "Fish", .requires = .{ .energy = 1.0, .hours = 1.0 } },
    \\}
;
const goods_a =
    \\.{
    \\    .{ .id = "rod", .name = "Rod", .tier = .crude, .requires = .{ .energy = 1.0, .hours = 1.0 }, .effects = .{ .{ .grant = "fish" } } },
    \\    .{ .id = "bed", .name = "Bed", .tier = .crude, .requires = .{ .energy = 1.0, .hours = 1.0 }, .effects = .{ .{ .vigor_ceiling = 2.0 } } },
    \\    .{ .id = "hut", .name = "Hut", .tier = .crude, .requires = .{ .energy = 1.0, .hours = 1.0 } },
    \\}
;
const techs_a =
    \\.{
    \\    .{ .id = "kilns", .name = "Kilns", .coord = .{ .q = 1, .r = 0 }, .initial = .available },
    \\    .{ .id = "wells", .name = "Wells", .coord = .{ .q = 0, .r = 1 }, .initial = .available },
    \\}
;

/// The same roster reordered, with a verb, a good and a tile added at the front.
const actions_b =
    \\.{
    \\    .{ .id = "hunt", .name = "Hunt", .requires = .{ .energy = 2.0, .hours = 2.0 } },
    \\    .{ .id = "fish", .name = "Fish", .requires = .{ .energy = 1.0, .hours = 1.0 } },
    \\    .{ .id = "forage", .name = "Forage", .innate = true, .requires = .{ .energy = 1.0, .hours = 1.0 } },
    \\}
;
const goods_b =
    \\.{
    \\    .{ .id = "net", .name = "Net", .tier = .crude, .requires = .{ .energy = 1.0, .hours = 1.0 } },
    \\    .{ .id = "hut", .name = "Hut", .tier = .crude, .requires = .{ .energy = 1.0, .hours = 1.0 } },
    \\    .{ .id = "bed", .name = "Bed", .tier = .crude, .requires = .{ .energy = 1.0, .hours = 1.0 }, .effects = .{ .{ .vigor_ceiling = 2.0 } } },
    \\    .{ .id = "rod", .name = "Rod", .tier = .crude, .requires = .{ .energy = 1.0, .hours = 1.0 }, .effects = .{ .{ .grant = "fish" } } },
    \\}
;
const techs_b =
    \\.{
    \\    .{ .id = "mills", .name = "Mills", .coord = .{ .q = -1, .r = 0 }, .initial = .locked },
    \\    .{ .id = "wells", .name = "Wells", .coord = .{ .q = 0, .r = 1 }, .initial = .available },
    \\    .{ .id = "kilns", .name = "Kilns", .coord = .{ .q = 1, .r = 0 }, .initial = .available },
    \\}
;

fn rig(src: roster.Sources) !Resources {
    var res: Resources = undefined;
    res.sim = .{};
    res.config = .{};
    res.catalog = try roster.load(testing.allocator, src, null);
    return res;
}

fn agent(w: *World) Entity {
    return w.spawn(.{ comp.Vigor{ .v = 10, .max = 10 }, comp.InventoryFood{}, comp.Goods{}, comp.Granted{} });
}

test "a swap carries goods, research, work and the reach seen-set to the new indices by id" {
    var w = World.init();
    var res = try rig(.{ .actions = actions_a, .goods = goods_a, .technologies = techs_a });
    defer res.catalog.deinit();
    const e = agent(&w);
    const a = &res.catalog;
    w.get(e, comp.Goods).?.count[a.goodIndex("rod").?] = 2;
    w.get(e, comp.Goods).?.count[a.goodIndex("bed").?] = 1;
    capital.settle(&w, e, a);
    try testing.expectEqual(@as(f32, 12), w.get(e, comp.Vigor).?.max);
    var research = comp.Research.entry(a);
    research.state[a.techIndex("wells").?] = .researched;
    w.add(e, research);
    w.add(e, comp.Busy{ .doing = .{ .labor = a.actionIndex("fish").? }, .total = 1, .remaining = 1, .quality = 1 });
    res.sim.reach_seen[a.goodIndex("hut").?] = true;

    swap(&res, &w, try roster.load(testing.allocator, .{ .actions = actions_b, .goods = goods_b, .technologies = techs_b }, null));
    const b = &res.catalog;
    const goods = w.get(e, comp.Goods).?;
    try testing.expectEqual(@as(u32, 2), goods.count[b.goodIndex("rod").?]);
    try testing.expectEqual(@as(u32, 1), goods.count[b.goodIndex("bed").?]);
    try testing.expectEqual(@as(u32, 0), goods.count[b.goodIndex("net").?]);
    try testing.expectEqual(@as(f32, 12), w.get(e, comp.Vigor).?.max); // the bed still counts once
    const r = w.get(e, comp.Research).?;
    try testing.expectEqual(roster.TechState.researched, r.state[b.techIndex("wells").?]);
    try testing.expectEqual(roster.TechState.available, r.state[b.techIndex("kilns").?]);
    try testing.expectEqual(roster.TechState.locked, r.state[b.techIndex("mills").?]); // new: entry state
    try testing.expect(w.get(e, comp.Busy).?.isLabor(b.actionIndex("fish").?));
    try testing.expect(res.sim.reach_seen[b.goodIndex("hut").?]);
    try testing.expect(!res.sim.reach_seen[b.goodIndex("net").?]);
}

test "a record the new files drop takes its count and its work with it" {
    var w = World.init();
    var res = try rig(.{ .actions = actions_a, .goods = goods_a, .technologies = techs_a });
    defer res.catalog.deinit();
    const e = agent(&w);
    const a = &res.catalog;
    w.get(e, comp.Goods).?.count[a.goodIndex("bed").?] = 1;
    capital.settle(&w, e, a);
    w.add(e, comp.Busy{ .doing = .{ .build = a.goodIndex("bed").? }, .total = 1, .remaining = 1, .quality = 1 });

    // The bed is gone from the new goods.
    swap(&res, &w, try roster.load(testing.allocator, .{ .actions = actions_a, .goods =
        \\.{ .{ .id = "rod", .name = "Rod", .tier = .crude, .requires = .{ .energy = 1.0, .hours = 1.0 }, .effects = .{ .{ .grant = "fish" } } } }
    , .technologies = techs_a }, null));
    try testing.expectEqual(@as(f32, 10), w.get(e, comp.Vigor).?.max); // its ceiling went with it
    try testing.expect(!w.has(e, comp.Busy));
    try testing.expectEqual(@as(usize, 1), res.sim.log.count);
}

test "a bad file keeps the catalog and logs why" {
    var w = World.init();
    var res = try rig(.{ .actions = actions_a, .goods = goods_a, .technologies = techs_a });
    defer res.catalog.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "goods.zon", .data = ".{ .{ .id = \"Rod\" } }" });

    reloadDir(testing.io, &res, &w, tmp.dir);
    try testing.expectEqual(@as(usize, 3), res.catalog.goods.len); // the old roster stays
    try testing.expectEqual(@as(usize, 1), res.sim.log.count);
    try testing.expect(std.mem.find(u8, res.sim.log.get(0).text(), "data/goods.zon") != null);
}

test "a directory overrides the files it holds and falls back for the rest" {
    var w = World.init();
    var res = try rig(.{ .actions = actions_a, .goods = goods_a, .technologies = techs_a });
    defer res.catalog.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // Only the goods file is overridden: one recipe. The verbs and tiles are the shipped ones.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "goods.zon", .data =
        \\.{ .{ .id = "hatchet", .name = "Hatchet", .tier = .crude, .requires = .{ .energy = 1.0, .hours = 1.0 }, .effects = .{ .{ .grant = "chop_wood" } } } }
    });
    reloadDir(testing.io, &res, &w, tmp.dir);
    try testing.expectEqual(@as(usize, 1), res.catalog.goods.len);
    try testing.expect(res.catalog.action("chop_wood") != null); // from the shipped verbs
    try testing.expect(res.catalog.technologies.len > 0);
}

test "the watch reports a change only after its first look, and only when a time moves" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "goods.zon", .data = ".{}" });
    var watch = Watch{};
    try testing.expect(!watch.look(testing.io, tmp.dir)); // the first look records
    try testing.expect(!watch.look(testing.io, tmp.dir)); // nothing moved
    var f = try tmp.dir.openFile(testing.io, "goods.zon", .{ .mode = .read_write });
    try f.setTimestamps(testing.io, .{
        .access_timestamp = .{ .new = .fromNanoseconds(0) },
        .modify_timestamp = .{ .new = .fromNanoseconds(std.time.ns_per_s * 1_000_000_000) },
    });
    f.close(testing.io);
    try testing.expect(watch.look(testing.io, tmp.dir));
    try testing.expect(!watch.look(testing.io, tmp.dir));
    try tmp.dir.deleteFile(testing.io, "goods.zon");
    try testing.expect(watch.look(testing.io, tmp.dir)); // a file going away is a change too
}
