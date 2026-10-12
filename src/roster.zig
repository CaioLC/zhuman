//! `roster` — the **authored roster**: the labor verbs and the capital goods as data, loaded
//! from `data/actions.zon` and `data/goods.zon` into one `Catalog`.
//!
//! The record grammar is the contract content is written against (the prose is in
//! `src/README.md`, "The authored roster"): one flat id space shared by resources, actions
//! and goods; every quantity a `Line` naming an item, with a cadence of `once` or `day`; a
//! good's behavior a list of `Effect`s from a fixed vocabulary. Loading parses with
//! `std.zon.parse` and then validates every cross-reference and shape rule before the catalog
//! is handed out, so a bad file is refused whole — with a line and column, or a rule and the
//! offending id — never half-applied.
//!
//! Today the catalog is read by tests, which hold it equal to the typed components it
//! transcribes (`typed_actions`/`typed_goods` is that bridge); the interpreter that runs the
//! sim from it is the next step (`docs/roadmap.md`, "CAT-01").

const std = @import("std");
const ha = @import("ha");
const dist = ha.dist;
const comp = ha.comp;

const Allocator = std.mem.Allocator;

// ============================ The grammar ===============================================

/// The ledger's columns — the fungible stocks an agent holds. In code, because each one is
/// structural (a stockline, a palette hue, a board wedge) and each has its own behavior
/// (food spoils, coin settles). A `Line` names one by its tag name, so the spelling here is
/// part of the content contract.
pub const Resource = enum {
    food,
    materials,
    biomass,
    water,
    fuel,
    metal,
    minerals,
    coin,

    /// The first act the stock exists in. Act I is Food and generic Materials; the rest arrive
    /// at the curtain.
    pub fn act(self: Resource) u8 {
        return switch (self) {
            .food, .materials => 1,
            else => 2,
        };
    }
};

/// When a line settles. `once` is paid at begin (an input) or lands at completion (an
/// output); `day` is authored per in-game day and settles every tick while the good is
/// owned, all of a good's day lines together, affordable-or-nothing.
pub const Cadence = enum { once, day };

/// One quantity of one item — the only shape a cost, an upkeep, a yield, a satchel or a
/// quote is written in. `item` is a resource name or a good id. `kind` defaults to `.fixed`,
/// an exact amount; the other kinds draw, and `n` is then the scale (`dist.Dist.s`).
pub const Line = struct {
    item: []const u8,
    n: f32,
    kind: dist.Kind = .fixed,
    sd: f32 = 0,
    per: Cadence = .once,

    /// The line as the distribution the sim samples.
    pub fn asDist(self: Line) dist.Dist {
        return .{ .kind = self.kind, .s = self.n, .sd = self.sd };
    }
};

/// The body-and-time price of an act: energy, a flow that is never a stock, and hours. Kept
/// apart from the lines because energy's gate is strict (vigor may never reach zero) where
/// an item's is not.
pub const Price = struct {
    energy: f32,
    hours: f32,
};

/// What an effect tweaks on its target verb: the price, or one named input/output line.
pub const Stat = union(enum) {
    energy,
    hours,
    input: []const u8,
    output: []const u8,
};

/// What owning a good does. A small fixed vocabulary; the sim is its interpreter, and a new
/// kind of effect is a code change while a new good is not.
pub const Effect = union(enum) {
    /// The target verb exists while this good is held.
    grant: []const u8,
    /// Multiply a stat on the target verb. A yield scale moves `s` and `sd` together.
    scale: Tweak,
    /// Offset a stat on the target verb; a line that is absent is inserted.
    add: Tweak,
    /// Raise the vigor ceiling by this much and fill what it adds; losing it only clamps.
    vigor_ceiling: f32,
    /// Raise the larder's quality by this many steps.
    food_quality: u8,
    /// Multiply the larder's spoilage rate.
    spoil_scale: f32,

    pub const Tweak = struct {
        target: []const u8,
        stat: Stat,
        by: f32,
    };
};

/// A tool family and this good's rank in it. A family's verb takes the effects of the best
/// rank owned; lower ranks in the same family are superseded, not stacked.
pub const Family = struct {
    name: []const u8,
    rank: u8,
};

/// Standing conditions a good asks of its builder, read once at begin — as against `input`,
/// which is what the build spends.
pub const Unlock = struct {
    /// Absolute current vigor, not a fraction of the ceiling.
    vigor_abs: f32,
    /// Units in the larder.
    food: f32,
    /// How many good kinds already owned.
    goods: u32,
};

pub const Tier = enum { crude, manufactured };

/// The act a good's completion ends. At most one good per value.
pub const Milestone = enum { act_one };

/// A good in the player's words. Empty strings mean the good has no copy on that surface.
pub const Copy = struct {
    /// What owning it changes, as a sentence fragment for the BUILD row.
    effect: []const u8 = "",
    /// The rail's compact form of the same fact.
    short: []const u8 = "",
    /// The receipt line when the build completes.
    built: []const u8 = "",
};

pub const Action = struct {
    id: []const u8,
    name: []const u8,
    /// The first act the verb exists in.
    act: u8 = 1,
    /// Whether the ACTIONS surface lists it. A verb can exist, and be granted, off-surface.
    on_surface: bool = true,
    /// Spawned on every agent, bare-handed; everything else arrives by a grant.
    innate: bool = false,
    /// Resource domains the verb works in; the specialization model's key.
    sectors: []const []const u8 = &.{},
    /// Retained tooling: ids that must be held for the verb to be offered.
    needs: []const []const u8 = &.{},
    requires: Price,
    input: []const Line = &.{},
    output: []const Line = &.{},
};

pub const Good = struct {
    id: []const u8,
    name: []const u8,
    act: u8 = 1,
    /// False for a good the passerby carries and no one builds; it then has no price or tier.
    buildable: bool = true,
    tier: ?Tier = null,
    sectors: []const []const u8 = &.{},
    requires: ?Price = null,
    /// `once` lines are the build order; `day` lines are the upkeep.
    input: []const Line = &.{},
    /// `once` lines are the product — absent means one of itself; `day` lines are a flow.
    output: []const Line = &.{},
    /// The verb (or tool) a modifier works on; must be held before the good is offered.
    needs: []const []const u8 = &.{},
    family: ?Family = null,
    effects: []const Effect = &.{},
    unlock: ?Unlock = null,
    /// How many humans it houses. Zero for everything but a shelter.
    capacity: u32 = 0,
    milestone: ?Milestone = null,
    copy: Copy = .{},
};

// ============================ The catalog ===============================================

/// The loaded roster. Owns its records' memory; immutable once handed out.
pub const Catalog = struct {
    arena: std.heap.ArenaAllocator,
    actions: []const Action,
    goods: []const Good,

    pub fn deinit(self: *Catalog) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn action(self: *const Catalog, id: []const u8) ?*const Action {
        for (self.actions) |*a| if (std.mem.eql(u8, a.id, id)) return a;
        return null;
    }

    pub fn good(self: *const Catalog, id: []const u8) ?*const Good {
        for (self.goods) |*g| if (std.mem.eql(u8, g.id, id)) return g;
        return null;
    }

    /// The resource an id names, if it names one.
    pub fn resource(id: []const u8) ?Resource {
        return std.meta.stringToEnum(Resource, id);
    }

    /// The first act an item (a resource or a good) exists in, or null for an unknown id.
    pub fn itemAct(self: *const Catalog, id: []const u8) ?u8 {
        if (resource(id)) |r| return r.act();
        if (self.good(id)) |g| return g.act;
        return null;
    }
};

pub const File = enum {
    actions,
    goods,

    pub fn path(self: File) []const u8 {
        return switch (self) {
            .actions => "data/actions.zon",
            .goods => "data/goods.zon",
        };
    }
};

/// The two files' bytes. `shipped` is the copy compiled into the binary.
pub const Sources = struct {
    actions: [:0]const u8,
    goods: [:0]const u8,
};

pub const shipped = Sources{
    .actions = @embedFile("actions.zon"),
    .goods = @embedFile("goods.zon"),
};

/// The shape and cross-reference rules a loaded roster must satisfy.
pub const Rule = enum {
    /// An id is empty or not `[a-z][a-z0-9_]*`.
    bad_id,
    /// An id is used twice, or collides with a resource name.
    duplicate_id,
    /// A line names an item that is neither a resource nor a good.
    unknown_item,
    /// An effect names a verb that does not exist.
    unknown_target,
    /// A `needs` entry names nothing.
    unknown_need,
    /// A sector is not a resource name.
    unknown_sector,
    /// A record references an item or verb from a later act than its own.
    later_act,
    /// A grant targets an innate verb.
    grant_innate,
    /// A scale/add targets a verb the good neither needs nor grants, and that is not innate.
    target_not_held,
    /// Two goods share a rank in one family, or a rank is zero.
    rank_collision,
    /// Two goods claim the same milestone.
    milestone_twice,
    /// A good's once-output names something other than itself.
    output_not_self,
    /// A buildable good lacks a price or tier, or a traded one carries them.
    buildable_shape,
    /// An action carries a day line; actions resolve once.
    bad_cadence,
    /// A negative quantity, a drawn input, or a non-positive scale.
    bad_number,
};

/// Where a load failed: the file, the rule if validation refused it (null for a parse error),
/// and a human-readable message with the line and column or the offending ids.
pub const Diagnostics = struct {
    file: File = .actions,
    rule: ?Rule = null,
    buf: [768]u8 = undefined,
    len: usize = 0,

    pub fn message(self: *const Diagnostics) []const u8 {
        return self.buf[0..self.len];
    }

    fn set(self: *Diagnostics, file: File, rule: ?Rule, comptime fmt: []const u8, args: anytype) void {
        self.file = file;
        self.rule = rule;
        var w = std.Io.Writer.fixed(&self.buf);
        w.print("{s}: ", .{file.path()}) catch {};
        w.print(fmt, args) catch {};
        self.len = w.buffered().len;
    }
};

pub const Error = error{ OutOfMemory, Invalid };

/// Parse and validate both files. On `error.Invalid` nothing is allocated for the caller and
/// `diag`, if given, says why.
pub fn load(gpa: Allocator, src: Sources, diag: ?*Diagnostics) Error!Catalog {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const actions = try parseFile([]const Action, a, .actions, src.actions, diag);
    const goods = try parseFile([]const Good, a, .goods, src.goods, diag);
    var v = Validator{ .actions = actions, .goods = goods, .diag = diag };
    try v.run();
    return .{ .arena = arena, .actions = actions, .goods = goods };
}

fn parseFile(comptime T: type, a: Allocator, file: File, source: [:0]const u8, diag: ?*Diagnostics) Error!T {
    var zd: std.zon.parse.Diagnostics = .{};
    defer zd.deinit(a);
    return std.zon.parse.fromSlice(T, a, source, &zd, .{ .free_on_error = false }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => {
            if (diag) |d| d.set(file, null, "{f}", .{zd});
            return error.Invalid;
        },
    };
}

const Validator = struct {
    actions: []const Action,
    goods: []const Good,
    diag: ?*Diagnostics,

    fn fail(self: *Validator, file: File, rule: Rule, id: []const u8, subject: []const u8) Error {
        if (self.diag) |d| d.set(file, rule, "{s} in '{s}': '{s}'", .{ @tagName(rule), id, subject });
        return error.Invalid;
    }

    fn run(self: *Validator) Error!void {
        try self.ids();
        for (self.actions) |a| try self.checkAction(a);
        var claimed = [_]bool{false} ** @typeInfo(Milestone).@"enum".fields.len;
        for (self.goods, 0..) |g, gi| try self.checkGood(g, gi, &claimed);
    }

    fn ids(self: *Validator) Error!void {
        for (self.actions, 0..) |a, i| {
            try self.checkId(.actions, a.id);
            if (Catalog.resource(a.id) != null) return self.fail(.actions, .duplicate_id, a.id, "a resource");
            for (self.actions[0..i]) |o| if (eql(a.id, o.id)) return self.fail(.actions, .duplicate_id, a.id, o.id);
        }
        for (self.goods, 0..) |g, i| {
            try self.checkId(.goods, g.id);
            if (Catalog.resource(g.id) != null) return self.fail(.goods, .duplicate_id, g.id, "a resource");
            for (self.goods[0..i]) |o| if (eql(g.id, o.id)) return self.fail(.goods, .duplicate_id, g.id, o.id);
            for (self.actions) |a| if (eql(g.id, a.id)) return self.fail(.goods, .duplicate_id, g.id, "an action");
        }
    }

    fn checkId(self: *Validator, file: File, id: []const u8) Error!void {
        if (id.len == 0 or !std.ascii.isLower(id[0])) return self.fail(file, .bad_id, id, "must start with a lowercase letter");
        for (id) |c| {
            if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_')) return self.fail(file, .bad_id, id, "only [a-z0-9_]");
        }
    }

    fn checkPrice(self: *Validator, file: File, id: []const u8, p: Price) Error!void {
        if (p.energy < 0 or p.hours < 0) return self.fail(file, .bad_number, id, "a negative price");
    }

    fn checkAction(self: *Validator, a: Action) Error!void {
        try self.checkPrice(.actions, a.id, a.requires);
        for (a.input) |l| {
            try self.checkLine(.actions, a.id, a.act, l, true);
            if (l.per == .day) return self.fail(.actions, .bad_cadence, a.id, l.item);
        }
        for (a.output) |l| {
            try self.checkLine(.actions, a.id, a.act, l, false);
            if (l.per == .day) return self.fail(.actions, .bad_cadence, a.id, l.item);
        }
        for (a.sectors) |s| if (Catalog.resource(s) == null) return self.fail(.actions, .unknown_sector, a.id, s);
        for (a.needs) |n| try self.checkNeed(.actions, a.id, a.act, n);
    }

    fn checkGood(self: *Validator, g: Good, gi: usize, claimed: []bool) Error!void {
        if (g.buildable) {
            if (g.requires == null or g.tier == null) return self.fail(.goods, .buildable_shape, g.id, "a buildable good carries requires and tier");
        } else if (g.requires != null or g.tier != null) {
            return self.fail(.goods, .buildable_shape, g.id, "a traded good has no price or tier");
        }
        if (g.requires) |p| try self.checkPrice(.goods, g.id, p);
        for (g.input) |l| try self.checkLine(.goods, g.id, g.act, l, true);
        for (g.output) |l| {
            try self.checkLine(.goods, g.id, g.act, l, false);
            if (l.per == .once and !eql(l.item, g.id)) return self.fail(.goods, .output_not_self, g.id, l.item);
        }
        for (g.sectors) |s| if (Catalog.resource(s) == null) return self.fail(.goods, .unknown_sector, g.id, s);
        for (g.needs) |n| try self.checkNeed(.goods, g.id, g.act, n);
        for (g.effects) |e| try self.checkEffect(g, e);
        if (g.family) |f| {
            if (f.rank == 0) return self.fail(.goods, .rank_collision, g.id, "rank 0");
            for (self.goods[0..gi]) |o| {
                if (o.family) |of| {
                    if (eql(of.name, f.name) and of.rank == f.rank) return self.fail(.goods, .rank_collision, g.id, o.id);
                }
            }
        }
        if (g.milestone) |m| {
            const i = @intFromEnum(m);
            if (claimed[i]) return self.fail(.goods, .milestone_twice, g.id, @tagName(m));
            claimed[i] = true;
        }
    }

    fn checkLine(self: *Validator, file: File, id: []const u8, act: u8, l: Line, is_input: bool) Error!void {
        const item_act = self.itemAct(l.item) orelse return self.fail(file, .unknown_item, id, l.item);
        if (item_act > act) return self.fail(file, .later_act, id, l.item);
        if (l.n < 0 or l.sd < 0) return self.fail(file, .bad_number, id, l.item);
        if (is_input and l.kind != .fixed) return self.fail(file, .bad_number, id, "an input is an exact amount");
    }

    fn checkNeed(self: *Validator, file: File, id: []const u8, act: u8, need: []const u8) Error!void {
        if (self.findAction(need)) |a| {
            if (a.act > act) return self.fail(file, .later_act, id, need);
            return;
        }
        if (self.findGood(need)) |g| {
            if (g.act > act) return self.fail(file, .later_act, id, need);
            return;
        }
        return self.fail(file, .unknown_need, id, need);
    }

    fn checkEffect(self: *Validator, g: Good, e: Effect) Error!void {
        switch (e) {
            .grant => |t| {
                const a = self.findAction(t) orelse return self.fail(.goods, .unknown_target, g.id, t);
                if (a.act > g.act) return self.fail(.goods, .later_act, g.id, t);
                if (a.innate) return self.fail(.goods, .grant_innate, g.id, t);
            },
            .scale, .add => |tw| {
                const a = self.findAction(tw.target) orelse return self.fail(.goods, .unknown_target, g.id, tw.target);
                if (a.act > g.act) return self.fail(.goods, .later_act, g.id, tw.target);
                if (!a.innate and !self.holds(g, tw.target)) return self.fail(.goods, .target_not_held, g.id, tw.target);
                switch (tw.stat) {
                    .energy, .hours => {},
                    .input, .output => |item| {
                        if (self.itemAct(item) == null) return self.fail(.goods, .unknown_item, g.id, item);
                    },
                }
                if (e == .scale and tw.by <= 0) return self.fail(.goods, .bad_number, g.id, "a scale must be positive");
            },
            .vigor_ceiling => |v| if (v <= 0) return self.fail(.goods, .bad_number, g.id, "vigor_ceiling must be positive"),
            .food_quality => {},
            .spoil_scale => |s| if (s <= 0) return self.fail(.goods, .bad_number, g.id, "spoil_scale must be positive"),
        }
    }

    /// Whether `g` guarantees the verb `target` exists when its effects apply: it needs it or
    /// grants it itself.
    fn holds(self: *Validator, g: Good, target: []const u8) bool {
        _ = self;
        for (g.needs) |n| if (eql(n, target)) return true;
        for (g.effects) |e| switch (e) {
            .grant => |t| if (eql(t, target)) return true,
            else => {},
        };
        return false;
    }

    fn findAction(self: *Validator, id: []const u8) ?*const Action {
        for (self.actions) |*a| if (eql(a.id, id)) return a;
        return null;
    }

    fn findGood(self: *Validator, id: []const u8) ?*const Good {
        for (self.goods) |*g| if (eql(g.id, id)) return g;
        return null;
    }

    fn itemAct(self: *Validator, id: []const u8) ?u8 {
        if (Catalog.resource(id)) |r| return r.act();
        if (self.findGood(id)) |g| return g.act;
        return null;
    }
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// ============================ The bridge to the typed roster ============================
// Which record each typed component transcribes. The tests below hold the two equal; the
// interpreter that retires the typed roster deletes this table with it.

pub const typed_actions = .{
    .{ "forage", comp.ActionForage },
    .{ "scavenge", comp.ActionScavenge },
    .{ "fish", comp.ActionFish },
    .{ "chop_wood", comp.ActionChopWood },
    .{ "check_traps", comp.ActionCheckTraps },
    .{ "hunt", comp.ActionHunt },
};

pub const typed_goods = .{
    .{ "fish_rod", comp.FishRod },
    .{ "hatchet", comp.Hatchet },
    .{ "wire_snares", comp.WireSnares },
    .{ "air_rifle", comp.AirRifle },
    .{ "sandals", comp.Sandals },
    .{ "work_gloves", comp.WorkGloves },
    .{ "bicycle", comp.Bicycle },
    .{ "cookpot", comp.Cookpot },
    .{ "root_cellar", comp.RootCellar },
    .{ "chainsaw", comp.Chainsaw },
    .{ "leaf_bed", comp.LeafBed },
    .{ "pantry", comp.Pantry },
    .{ "medicine_chest", comp.MedicineChest },
    .{ "garden_bed", comp.GardenBed },
    .{ "chicken_coop", comp.ChickenCoop },
    .{ "shelter", comp.Shelter },
    .{ "fish_net", comp.FishNet },
    .{ "hand_axe", comp.HandAxe },
};

/// The record id a typed action component transcribes.
pub fn actionIdOf(comptime ActionT: type) []const u8 {
    inline for (typed_actions) |pair| {
        if (pair[1] == ActionT) return pair[0];
    }
    @compileError("no roster record for " ++ @typeName(ActionT));
}

/// The record id a typed good component transcribes.
pub fn goodIdOf(comptime GoodT: type) []const u8 {
    inline for (typed_goods) |pair| {
        if (pair[1] == GoodT) return pair[0];
    }
    @compileError("no roster record for " ++ @typeName(GoodT));
}

// ============================ Tests =====================================================

const testing = std.testing;

fn loadShipped() !Catalog {
    var d = Diagnostics{};
    return load(testing.allocator, shipped, &d) catch |err| {
        std.debug.print("{s}\n", .{d.message()});
        return err;
    };
}

/// A once-line for `item` with exactly `qty` when `qty > 0`, and no line for it at all when
/// `qty == 0` — the typed `Requires.materials = 0` has no line to transcribe.
fn expectQty(lines: []const Line, item: []const u8, qty: f32) !void {
    var found: ?Line = null;
    for (lines) |l| if (l.per == .once and eql(l.item, item)) {
        found = l;
    };
    if (qty == 0) {
        try testing.expect(found == null);
        return;
    }
    const l = found orelse return error.MissingLine;
    try testing.expectEqual(dist.Kind.fixed, l.kind);
    try testing.expectEqual(qty, l.n);
}

/// A line for `item` equal to the typed distribution, or none when the typed yield is the
/// `.fixed` zero placeholder that means "nothing on this side".
fn expectDist(lines: []const Line, item: []const u8, per: Cadence, d: dist.Dist) !void {
    var found: ?Line = null;
    for (lines) |l| if (l.per == per and eql(l.item, item)) {
        found = l;
    };
    if (d.kind == .fixed and d.s == 0) {
        try testing.expect(found == null);
        return;
    }
    const l = found orelse return error.MissingLine;
    try testing.expectEqual(d.kind, l.kind);
    try testing.expectEqual(d.s, l.n);
    try testing.expectEqual(d.sd, l.sd);
}

test "the shipped files load and validate" {
    var cat = try loadShipped();
    defer cat.deinit();
    try testing.expectEqual(typed_actions.len, cat.actions.len);
    try testing.expectEqual(typed_goods.len, cat.goods.len);
}

test "every typed action is one record, number for number" {
    var cat = try loadShipped();
    defer cat.deinit();
    inline for (typed_actions) |pair| {
        const rec = cat.action(pair[0]) orelse return error.MissingRecord;
        const typed = (pair[1]{});
        try testing.expectEqual(typed.requires.energy, rec.requires.energy);
        try testing.expectEqual(typed.requires.hours, rec.requires.hours);
        try expectQty(rec.input, "materials", typed.requires.materials);
        try testing.expectEqual(@as(usize, if (typed.requires.materials > 0) 1 else 0), rec.input.len);
        try expectDist(rec.output, "food", .once, typed.yields.food);
        try expectDist(rec.output, "materials", .once, typed.yields.materials);
        // Innate ⇔ spawned on every agent; on-surface ⇔ the stable-id catalog's flag; the
        // name is the one the activity strip speaks.
        var innate = false;
        inline for (ha.actions.actions_bundle) |A| {
            if (A == pair[1]) innate = true;
        }
        try testing.expectEqual(innate, rec.innate);
        var on_surface: ?bool = null;
        for (ha.catalog.actions) |r| {
            if (eql(r.id, "act." ++ pair[0])) on_surface = r.on_surface;
        }
        try testing.expectEqual(on_surface.?, rec.on_surface);
        try testing.expectEqualStrings(ha.actions.doing_label(ha.actions.doing_of(pair[1])), rec.name);
        try testing.expectEqual(@as(u8, 1), rec.act);
    }
}

test "every typed good is one record, number for number" {
    var cat = try loadShipped();
    defer cat.deinit();
    var buildable: usize = 0;
    inline for (typed_goods) |pair| {
        const G = pair[1];
        const rec = cat.good(pair[0]) orelse return error.MissingRecord;
        const typed = (G{});
        try testing.expectEqual(@as(u8, 1), rec.act);
        if (@hasField(G, "requires")) {
            // Buildable: the price, the build order, the tier, the stable id, the receipt.
            buildable += 1;
            try testing.expect(rec.buildable);
            try testing.expectEqual(typed.requires.energy, rec.requires.?.energy);
            try testing.expectEqual(typed.requires.hours, rec.requires.?.hours);
            try expectQty(rec.input, "materials", typed.requires.materials);
            try testing.expectEqual(
                if (ha.capital.is_crude(G)) Tier.crude else Tier.manufactured,
                rec.tier.?,
            );
            try testing.expectEqualStrings(ha.catalog.goodId(G), "good." ++ pair[0]);
            try testing.expectEqualStrings(ha.capital.built_msg(G), rec.copy.built);
            try testing.expectEqualStrings(ha.actions.doing_label(ha.capital.doing_of_good(G)), rec.name);
        } else {
            try testing.expect(!rec.buildable);
            try testing.expectEqual(@as(?Price, null), rec.requires);
            try testing.expectEqual(@as(?Tier, null), rec.tier);
        }
        // The prerequisite verb is the one `needs` names.
        if (ha.capital.prereq_of(G)) |P| {
            try testing.expectEqual(@as(usize, 1), rec.needs.len);
            try testing.expectEqualStrings(actionIdOf(P), rec.needs[0]);
        } else {
            try testing.expectEqual(@as(usize, 0), rec.needs.len);
        }
        // A generator's upkeep and yield are its day lines; nothing else has any.
        if (@hasField(G, "upkeep")) {
            try expectDist(rec.input, "materials", .day, .{ .kind = .fixed, .s = typed.upkeep.materials });
            try expectDist(rec.output, "food", .day, typed.yields.food);
            try expectDist(rec.output, "materials", .day, typed.yields.materials);
        } else {
            for (rec.input) |l| try testing.expectEqual(Cadence.once, l.per);
            for (rec.output) |l| try testing.expectEqual(Cadence.once, l.per);
        }
        // The shelter's standing conditions and capacity.
        if (@hasField(G, "unlock")) {
            try testing.expectEqual(typed.unlock.vigor_abs, rec.unlock.?.vigor_abs);
            try testing.expectEqual(typed.unlock.food, rec.unlock.?.food);
            try testing.expectEqual(typed.unlock.goods, rec.unlock.?.goods);
        } else {
            try testing.expectEqual(@as(?Unlock, null), rec.unlock);
        }
        if (@hasField(G, "capacity")) {
            try testing.expectEqual(typed.capacity, rec.capacity);
        } else {
            try testing.expectEqual(@as(u32, 0), rec.capacity);
        }
    }
    try testing.expectEqual(ha.capital.buildable_bundle.len, buildable);
}

test "an unlocker's grant names the verb its typed grant adds" {
    var cat = try loadShipped();
    defer cat.deinit();
    var w = ha.world.World.init();
    const pairs = .{
        .{ "fish_rod", comp.FishRod, "fish", comp.ActionFish },
        .{ "hatchet", comp.Hatchet, "chop_wood", comp.ActionChopWood },
        .{ "wire_snares", comp.WireSnares, "check_traps", comp.ActionCheckTraps },
        .{ "air_rifle", comp.AirRifle, "hunt", comp.ActionHunt },
        .{ "fish_net", comp.FishNet, "fish", comp.ActionFish },
        .{ "hand_axe", comp.HandAxe, "chop_wood", comp.ActionChopWood },
    };
    inline for (pairs) |p| {
        const rec = cat.good(p[0]).?;
        var granted = false;
        for (rec.effects) |e| switch (e) {
            .grant => |t| if (eql(t, p[2])) {
                granted = true;
            },
            else => {},
        };
        try testing.expect(granted);
        const e = w.spawn(.{ comp.Vigor{}, comp.InventoryFood{}, comp.InventoryMaterial{} });
        w.add(e, p[1]{});
        ha.capital.grant_public(&w, e, p[1]);
        try testing.expect(w.has(e, p[3]));
    }
}

test "the two tool families rank rod under net and hatchet under hand axe" {
    var cat = try loadShipped();
    defer cat.deinit();
    try testing.expectEqualStrings("fishing", cat.good("fish_rod").?.family.?.name);
    try testing.expectEqual(@as(u8, 1), cat.good("fish_rod").?.family.?.rank);
    try testing.expectEqual(@as(u8, 2), cat.good("fish_net").?.family.?.rank);
    try testing.expectEqualStrings("chopping", cat.good("hand_axe").?.family.?.name);
    try testing.expectEqual(@as(u8, 1), cat.good("hatchet").?.family.?.rank);
    try testing.expectEqual(@as(u8, 2), cat.good("hand_axe").?.family.?.rank);
}

// —— the validator bites ————————————————————————————————————————————————————————————————

const ok_actions =
    \\.{
    \\    .{ .id = "forage", .name = "Forage", .innate = true, .requires = .{ .energy = 1.0, .hours = 1.0 } },
    \\    .{ .id = "fish", .name = "Fish", .requires = .{ .energy = 1.0, .hours = 1.0 } },
    \\}
;

const ok_goods =
    \\.{
    \\    .{ .id = "rod", .name = "Rod", .tier = .crude, .requires = .{ .energy = 1.0, .hours = 1.0 },
    \\       .input = .{ .{ .item = "materials", .n = 1.0 } }, .effects = .{ .{ .grant = "fish" } } },
    \\}
;

fn expectRule(actions_src: [:0]const u8, goods_src: [:0]const u8, rule: Rule) !void {
    var d = Diagnostics{};
    if (load(testing.allocator, .{ .actions = actions_src, .goods = goods_src }, &d)) |*cat| {
        var c = cat.*;
        c.deinit();
        return error.ExpectedInvalid;
    } else |err| {
        try testing.expectEqual(Error.Invalid, err);
        try testing.expectEqual(rule, d.rule.?);
        try testing.expect(d.len > 0);
    }
}

test "the minimal fixture is valid" {
    var cat = try load(testing.allocator, .{ .actions = ok_actions, .goods = ok_goods }, null);
    defer cat.deinit();
}

test "a parse error names the file, the line and the column" {
    var d = Diagnostics{};
    const bad =
        \\.{
        \\    .{ .id = "forage", .nmae = "Forage", .requires = .{ .energy = 1.0, .hours = 1.0 } },
        \\}
    ;
    try testing.expectError(error.Invalid, load(testing.allocator, .{ .actions = bad, .goods = ok_goods }, &d));
    try testing.expectEqual(File.actions, d.file);
    try testing.expect(d.rule == null);
    try testing.expect(std.mem.startsWith(u8, d.message(), "data/actions.zon: 2:"));
}

test "ids are plain, unique, and never a resource name" {
    try expectRule(
        \\.{ .{ .id = "Forage", .name = "Forage", .requires = .{ .energy = 1.0, .hours = 1.0 } } }
    , ok_goods, .bad_id);
    try expectRule(
        \\.{ .{ .id = "food", .name = "Food", .requires = .{ .energy = 1.0, .hours = 1.0 } } }
    , ok_goods, .duplicate_id);
    try expectRule(ok_actions,
        \\.{ .{ .id = "fish", .name = "Fish", .tier = .crude, .requires = .{ .energy = 1.0, .hours = 1.0 } } }
    , .duplicate_id);
}

test "lines name real items of the record's own act" {
    try expectRule(
        \\.{ .{ .id = "forage", .name = "Forage", .requires = .{ .energy = 1.0, .hours = 1.0 },
        \\     .output = .{ .{ .item = "berries", .n = 1.0 } } } }
    , ok_goods, .unknown_item);
    try expectRule(
        \\.{ .{ .id = "forage", .name = "Forage", .requires = .{ .energy = 1.0, .hours = 1.0 },
        \\     .output = .{ .{ .item = "water", .n = 1.0 } } } }
    , ok_goods, .later_act);
    try expectRule(
        \\.{ .{ .id = "forage", .name = "Forage", .requires = .{ .energy = 1.0, .hours = 1.0 },
        \\     .input = .{ .{ .item = "materials", .n = 1.0, .kind = .normal } } } }
    , ok_goods, .bad_number);
    try expectRule(
        \\.{ .{ .id = "forage", .name = "Forage", .requires = .{ .energy = 1.0, .hours = 1.0 },
        \\     .output = .{ .{ .item = "food", .n = 1.0, .per = .day } } } }
    , ok_goods, .bad_cadence);
}

test "effects point at verbs the good can reach" {
    try expectRule(ok_actions,
        \\.{ .{ .id = "rod", .name = "Rod", .tier = .crude, .requires = .{ .energy = 1.0, .hours = 1.0 },
        \\     .effects = .{ .{ .grant = "swim" } } } }
    , .unknown_target);
    try expectRule(ok_actions,
        \\.{ .{ .id = "rod", .name = "Rod", .tier = .crude, .requires = .{ .energy = 1.0, .hours = 1.0 },
        \\     .effects = .{ .{ .grant = "forage" } } } }
    , .grant_innate);
    // A modifier on a non-innate verb must need it or grant it.
    try expectRule(ok_actions,
        \\.{ .{ .id = "gloves", .name = "Gloves", .tier = .crude, .requires = .{ .energy = 1.0, .hours = 1.0 },
        \\     .effects = .{ .{ .scale = .{ .target = "fish", .stat = .energy, .by = 0.5 } } } } }
    , .target_not_held);
    try expectRule(ok_actions,
        \\.{ .{ .id = "gloves", .name = "Gloves", .tier = .crude, .requires = .{ .energy = 1.0, .hours = 1.0 },
        \\     .needs = .{"fish"}, .effects = .{ .{ .scale = .{ .target = "fish", .stat = .energy, .by = 0.0 } } } } }
    , .bad_number);
    try expectRule(ok_actions,
        \\.{ .{ .id = "gloves", .name = "Gloves", .tier = .crude, .requires = .{ .energy = 1.0, .hours = 1.0 },
        \\     .needs = .{"row"} } }
    , .unknown_need);
}

test "goods keep their shape" {
    try expectRule(ok_actions,
        \\.{ .{ .id = "rod", .name = "Rod", .requires = .{ .energy = 1.0, .hours = 1.0 } } }
    , .buildable_shape);
    try expectRule(ok_actions,
        \\.{ .{ .id = "net", .name = "Net", .buildable = false, .tier = .crude } }
    , .buildable_shape);
    try expectRule(ok_actions,
        \\.{ .{ .id = "kiln", .name = "Kiln", .tier = .crude, .requires = .{ .energy = 1.0, .hours = 1.0 },
        \\     .output = .{ .{ .item = "food", .n = 4.0 } } } }
    , .output_not_self);
    try expectRule(ok_actions,
        \\.{
        \\    .{ .id = "rod", .name = "Rod", .tier = .crude, .requires = .{ .energy = 1.0, .hours = 1.0 },
        \\       .family = .{ .name = "fishing", .rank = 1 } },
        \\    .{ .id = "net", .name = "Net", .buildable = false, .family = .{ .name = "fishing", .rank = 1 } },
        \\}
    , .rank_collision);
    try expectRule(ok_actions,
        \\.{
        \\    .{ .id = "hut", .name = "Hut", .tier = .crude, .requires = .{ .energy = 1.0, .hours = 1.0 }, .milestone = .act_one },
        \\    .{ .id = "hall", .name = "Hall", .tier = .crude, .requires = .{ .energy = 1.0, .hours = 1.0 }, .milestone = .act_one },
        \\}
    , .milestone_twice);
}

test "a lot of an intermediate is its own once-output" {
    var cat = try load(testing.allocator, .{ .actions = ok_actions, .goods = 
        \\.{ .{ .id = "charcoal", .name = "Charcoal", .tier = .crude, .requires = .{ .energy = 1.0, .hours = 1.0 },
        \\     .input = .{ .{ .item = "materials", .n = 6.0 } }, .output = .{ .{ .item = "charcoal", .n = 4.0 } } } }
    }, null);
    defer cat.deinit();
    try testing.expectEqual(@as(f32, 4.0), cat.good("charcoal").?.output[0].n);
}
