//! `Props` constructors (`El.box`/`boxi`/`leaf`/`set`) against the setter chains they replace:
//! the same node fields at scales 1 and 2. SDL-free; text leaves need the platform font, so
//! `label`/`label_fit` are covered by the live pages (the layout audit and the screenshots).

const std = @import("std");
const ui = @import("ui");
const cb = @import("./ctx_binding.zig");
const el = @import("./elements.zig");
const replay = @import("./replay.zig");
const style = @import("./style.zig");

const UiCtx = cb.UiCtx;
const Node = cb.Node;
const Style = style.Style;
const El = el.El;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const scales = [_]f32{ 1, 2 };

const Rig = struct {
    res: @import("../res.zig").Resources,
    arena: std.heap.ArenaAllocator,
    ui: UiCtx,

    fn setUp(self: *Rig, scale: f32) void {
        self.res = replay.headlessResources();
        self.res.view.scale = scale;
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        self.ui = UiCtx.init(&self.res, std.testing.allocator, self.arena.allocator());
    }

    fn tearDown(self: *Rig) void {
        self.ui.deinit();
        self.arena.deinit();
    }

    fn parent(self: *Rig) !El {
        const node = try Node.create(self.ui.arena, "p");
        node.layout.anchor = .top_left;
        return .{ .ctx = &self.ui, .node = node };
    }

    fn passThrough(self: *Rig, n: *Node) !bool {
        const idx = try self.ui.interactions.acquire(self.ui.gpa, n.key, self.ui.frame);
        return self.ui.interactions.get(idx).pass_through;
    }
};

/// The node fields a setter can write, compared whole.
fn expectSameNode(want: *Node, got: *Node) !void {
    try expect(std.meta.eql(want.size, got.size));
    try expect(std.meta.eql(want.layout, got.layout));
    try expect(std.meta.eql(want.render_data, got.render_data));
}

const panel_look = .{ style.pad_sym(12, 8), Style{ .fill_ink = .panel, .outline_ink = .line, .outline_width = 1 } };

test "box: every Props field writes what its setter writes, at scale 1 and 2" {
    for (scales) |s| {
        var rig: Rig = undefined;
        rig.setUp(s);
        defer rig.tearDown();
        const p = try rig.parent();
        const owner = try el.tracks(&rig.ui, &.{ .{ .basis = .{ .fr = 1 } }, .{ .basis = .{ .px = 86 } } }, 10);
        const row = try el.tracks(&rig.ui, &.{.{ .basis = .{ .fr = 1 } }}, 4);

        const chain = (try p.div("chain"))
            .with_layout(.center_right)
            .with_flow(.{ .dir = .row, .cross = .center })
            .with_size(.{ .fixed = 240 }, .{ .pct_of_parent = 0.5 })
            .with_min(30, null)
            .with_max(null, 400)
            .with_pct_less(null, 8)
            .with_margin(3, 9)
            .with_gap(6)
            .with_overflow(.clip)
            .with_offset(5, -7)
            .with_grow(2)
            .with_shrink(1)
            .with_opacity(0.4)
            .with_tracks(owner)
            .in_tracks(row)
            .at_track(1, 2)
            .with_style(panel_look);
        const box = try p.box("box", .{
            .anchor = .center_right,
            .flow = .{ .dir = .row, .cross = .center },
            .w = .{ .fixed = 240 },
            .h = .{ .pct_of_parent = 0.5 },
            .min = .{ .w = 30 },
            .max = .{ .h = 400 },
            .pct_less = .{ .h = 8 },
            .margin = .{ .before = 3, .after = 9 },
            .gap = 6,
            .overflow = .clip,
            .offset = .{ .x = 5, .y = -7 },
            .grow = 2,
            .shrink = 1,
            .opacity = 0.4,
            .tracks = owner,
            .in_tracks = row,
            .at = .{ .col = 1, .span = 2 },
        }, panel_look);
        try expectSameNode(chain.get(), box.get());

        // The scaled values, spelled out once so a setter change cannot hide in both forms.
        const n = box.get();
        try expectEqual(ui.SizeRule{ .fixed = 240 * s }, n.size.w);
        try expectEqual(ui.SizeRule{ .pct_of_parent = 0.5 }, n.size.h);
        try expectEqual(@as(f32, 6 * s), n.layout.gap);
        try expectEqual(@as(f32, 3 * s), n.layout.margin_before);
        try expectEqual(@as(f32, 9 * s), n.layout.margin_after);
        try expectEqual(@as(f32, 30 * s), n.size.min_width);
        try expectEqual(@as(f32, 400 * s), n.size.max_height);
        try expectEqual(@as(f32, 8 * s), n.size.pct_less_height);
        try expectEqual(@as(f32, 12 * s), n.size.padding.left);
        try expectEqual(@as(f32, 8 * s), n.size.padding.up);
        try expectEqual(@as(f32, 5 * s), n.layout.offset_x);
        try expectEqual(owner, n.layout.track_owner.?);
        try expectEqual(row, n.layout.track_row.?);
        try expectEqual(@as(?u16, 1), n.layout.cell_col);
        try expectEqual(@as(u16, 2), n.layout.cell_span);
        try expect(n.render_data.fill != null and n.render_data.outline != null);
    }
}

test "box: unset fields leave the fresh node's values; one axis sets only that axis" {
    for (scales) |s| {
        var rig: Rig = undefined;
        rig.setUp(s);
        defer rig.tearDown();
        const p = try rig.parent();
        const plain = try p.div("plain");
        const empty = try p.box("empty", .{}, .{});
        try expectSameNode(plain.get(), empty.get());

        const w_only = try p.box("w", .{ .w = .{ .fixed = 50 } }, .{});
        try expectEqual(ui.SizeRule{ .fixed = 50 * s }, w_only.get().size.w);
        try expect(std.meta.eql(plain.get().size.h, w_only.get().size.h));
        const h_only = try p.box("h", .{ .h = .grow, .min = .{ .h = 38 } }, .{});
        try expect(std.meta.eql(plain.get().size.w, h_only.get().size.w));
        try expectEqual(ui.SizeRule.grow, h_only.get().size.h);
        try expectEqual(plain.get().size.min_width, h_only.get().size.min_width);
        try expectEqual(@as(f32, 38 * s), h_only.get().size.min_height);

        // A margin with one side given is the setter's `with_margin(0, after)`.
        const m_chain = (try p.div("mc")).with_margin(0, 8);
        const m_box = try p.box("mb", .{ .margin = .{ .after = 8 } }, .{});
        try expectSameNode(m_chain.get(), m_box.get());
    }
}

test "box: the style spec applies after the props, as a trailing with_style does" {
    for (scales) |s| {
        var rig: Rig = undefined;
        rig.setUp(s);
        defer rig.tearDown();
        const p = try rig.parent();
        // A style `gap` lands after `with_gap`, so it wins in both forms.
        const chain = (try p.div("c")).with_gap(4).with_style(.{style.gap(10)});
        const box = try p.box("b", .{ .gap = 4 }, .{style.gap(10)});
        try expectSameNode(chain.get(), box.get());
        try expectEqual(@as(f32, 10 * s), box.get().layout.gap);

        // A role fragment resolves against the theme on the built node, as `with_style` resolves it.
        const fc = (try p.div("fc")).with_size(.grow, .fit_children).with_style(.{ style.panel, style.pad(3) });
        const fb = try p.box("fb", .{ .w = .grow, .h = .fit_children }, .{ style.panel, style.pad(3) });
        try expectSameNode(fc.get(), fb.get());
    }
}

test "boxi, leaf and set: same keys and fields as item/div plus the chain" {
    for (scales) |s| {
        var rig: Rig = undefined;
        rig.setUp(s);
        defer rig.tearDown();
        const p = try rig.parent();

        const ic = (try p.item("row", 3)).with_size(.{ .pct_of_parent = 1.0 }, .fit_children).with_flow(.{ .dir = .row });
        const ib = try p.boxi("row", 4, .{ .w = .{ .pct_of_parent = 1.0 }, .h = .fit_children, .flow = .{ .dir = .row } }, .{});
        try expectSameNode(ic.get(), ib.get());
        try expectEqual(ui.key_i(p.get().key, "row", 4), ib.get().key);

        // `leaf` is a `box` whose handle is dropped: the node is the last child, keyed by its id.
        try p.leaf("rule", .{ .w = .{ .pct_of_parent = 1.0 }, .h = .{ .fixed = 1 } }, .{style.rule_fill});
        const kids = p.get().children.items;
        const rule = kids[kids.len - 1];
        const rule_chain = (try p.div("rule_chain")).with_size(.{ .pct_of_parent = 1.0 }, .{ .fixed = 1 }).with_style(.{style.rule_fill});
        try expectEqual(ui.key(p.get().key, "rule"), rule.key);
        try expectSameNode(rule_chain.get(), rule);

        // `set` on an existing handle, `pass_through` included.
        const sc = (try p.div("sc")).with_layout(.top_left).with_size(.{ .fixed = 7 }, .{ .fixed = 7 }).with_opacity(0.8).pass_through();
        const sb = try p.div("sb");
        sb.set(.{ .anchor = .top_left, .w = .{ .fixed = 7 }, .h = .{ .fixed = 7 }, .opacity = 0.8, .pass_through = true }, .{});
        try expectSameNode(sc.get(), sb.get());
        try expect(try rig.passThrough(sb.get()));
        try expect(!try rig.passThrough(ib.get()));

        // `probe` is `pass_through().track()`.
        const pr = try p.div("probe");
        pr.probe();
        try expect(try rig.passThrough(pr.get()));
    }
}
