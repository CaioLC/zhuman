//! `layout_dump` — a text dump of one laid-out frame (QA-09): every node of every root in paint
//! order, indented by depth, with its stable key, its box and inherited clip in logical px, its
//! render features, its interaction and focus state, and the semantic node published for it.
//! It is the tool for diagnosing an overlap or a clipping fault without a screenshot, and for
//! checking that a hidden or locked control is neither in Tab order nor hittable.
//!
//! A development switch: `HA_LAYOUT_DUMP=<path>` writes the dump once, on frame
//! `HA_LAYOUT_DUMP_FRAME` (default 30, after a fixture has settled). The host calls `write`
//! from the frame driver's `sample` hook, after layout, stamping and drawing and before
//! `endFrame`, so the geometry, the focus registry and the semantic table are all this frame's.
//!
//! One line per node:
//!
//!     <indent><id>[<index>] #<key> <x>,<y> <w>x<h> [clip <x>,<y> <w>x<h>] [clips] <features>
//!         [tab|tab-off] [focused] [ring] [hover] [selected] [disabled] [pass] [role "<name>"]
//!
//! `clip` is the clip the node paints and hits under (its ancestors'), `clips` says the node
//! crops its own subtree, and a `hidden` mark means the clip leaves none of the box visible.
//! A text node's string follows its features in quotes, cut at 40 bytes.

const std = @import("std");
const ui = @import("ui");
const cb = @import("./ctx_binding.zig");
const semantics = @import("./semantics.zig");

const UiCtx = cb.UiCtx;
const Node = cb.Node;

pub const env_path = "HA_LAYOUT_DUMP";
pub const env_frame = "HA_LAYOUT_DUMP_FRAME";
pub const default_frame: u64 = 30;

/// The host's once-only trigger: counts frames and reports when this one is the dump frame.
pub const Trigger = struct {
    frames: u64 = 0,
    done: bool = false,

    /// Whether to dump this frame, given the configured frame (null when the switch is off).
    pub fn fire(self: *Trigger, at: ?u64) bool {
        self.frames += 1;
        const want = at orelse return false;
        if (self.done or self.frames < want) return false;
        self.done = true;
        return true;
    }
};

/// The configured dump frame from the environment value, or the default for an unset or
/// unparsable one.
pub fn frameFrom(raw: ?[]const u8) u64 {
    const s = raw orelse return default_frame;
    return std.fmt.parseInt(u64, std.mem.trim(u8, s, " "), 10) catch default_frame;
}

/// Write the dump of `trees` to `path` (relative to the working directory).
pub fn writeFile(u: *UiCtx, trees: []const *Node, io: std.Io, path: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(u.arena);
    try write(u, trees, &out.writer);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.written() });
}

/// Write the dump of `trees` to `w`.
pub fn write(u: *UiCtx, trees: []const *Node, w: *std.Io.Writer) !void {
    const scale = if (u.res.view.scale > 0) u.res.view.scale else 1;
    try w.print("# layout dump: frame {}, scale {d}, {} roots; geometry in logical px\n", .{ u.frame, scale, trees.len });
    for (trees, 0..) |t, i| {
        try w.print("## root {}\n", .{i});
        try node(u, t, null, 0, scale, w);
    }
}

fn node(u: *UiCtx, n: *Node, clip: ?ui.Rect, depth: usize, scale: f32, w: *std.Io.Writer) !void {
    try w.splatByteAll(' ', depth * 2);
    try w.writeAll(n.id);
    if (n.index) |i| try w.print("[{}]", .{i});
    try w.print(" #{x:0>16}", .{n.key});

    const box: ?ui.Rect = if (n.layout._global_x != null and n.layout._global_y != null)
        .{ .x = n.layout._global_x.?, .y = n.layout._global_y.?, .w = n.size.width, .h = n.size.height }
    else
        null;
    if (box) |b| {
        try rect(w, " ", b, scale);
    } else try w.writeAll(" unplaced");
    if (clip) |c| {
        try rect(w, " clip ", c, scale);
        if (box) |b| {
            const seen = c.intersect(b);
            if (seen.w <= 0 or seen.h <= 0) try w.writeAll(" hidden");
        }
    }
    if (n.layout.overflow == .clip) try w.writeAll(" clips");
    if (n.layout.track_owner != null) try w.writeAll(" track_owner");
    if (n.layout.track_row) |set| {
        // Solved for this row's own content width (a no-op when it matches the last solve).
        set.solve(n.size.width - n.size.padding.left - n.size.padding.right);
        try w.writeAll(" tracks=[");
        for (set.tracks, set.widths, 0..) |t, wd, i| {
            if (i > 0) try w.writeByte(',');
            if (t.hidden) try w.writeByte('-') else try w.print("{d:.0}", .{wd / scale});
        }
        try w.writeByte(']');
    }

    const rd = n.render_data;
    if (rd.fill != null) try w.writeAll(" fill");
    if (rd.outline != null) try w.writeAll(" outline");
    if (rd.img != null) try w.writeAll(" img");
    if (rd.svg != null) try w.writeAll(" svg");
    if (rd.geometry != null) try w.writeAll(" geometry");
    if (rd.opacity < 1) try w.print(" opacity={d:.2}", .{rd.opacity});
    if (rd.text != null) {
        const st = n.state(u, cb.UiState.TextState);
        const s = st.text() orelse "";
        const cut = s[0..@min(s.len, 40)];
        try w.print(" text\"{s}{s}\"", .{ cut, if (s.len > cut.len) "\u{2026}" else "" });
        // A `.fill` leaf: the width it was wrapped at this frame (logical px; 0 = unmeasured).
        // A `.cell_fill` leaf: the width it was clipped/elided at (`cell@`).
        if (n.size.measure_h) {
            if (st.fit == .cell_fill)
                try w.print(" cell@{d:.0}", .{st.fit.cellWidth() / scale})
            else
                try w.print(" fill@{d:.0}", .{st.fit.wrapWidth() / scale});
        }
    }

    for (u.focus.building.items) |t| if (t.key == n.key) {
        try w.writeAll(if (t.enabled) " tab" else " tab-off");
        break;
    };
    if (u.focusedKey() == n.key) try w.writeAll(" focused");
    if (rd.focus_ring) try w.writeAll(" ring");
    if (u.interactions.index.get(n.key)) |idx| {
        const slot = u.interactions.slots.items[idx];
        const f = slot.value.flags;
        if (f.hovering) try w.writeAll(" hover");
        if (f.selected) try w.writeAll(" selected");
        if (f.disabled) try w.writeAll(" disabled");
        if (slot.value.pass_through) try w.writeAll(" pass");
    }
    const sem = &u.res.semantics;
    for (sem.building[0..sem.building_len]) |*s| if (s.key == n.key) {
        try w.print(" {s} \"{s}\"", .{ @tagName(s.role), s.labelText() });
        if (s.valueText()) |v| try w.print("={s}", .{v});
        break;
    };
    try w.writeByte('\n');

    const child_clip: ?ui.Rect = if (n.layout.overflow == .clip) blk: {
        const b = box orelse break :blk clip;
        break :blk if (clip) |c| c.intersect(b) else b;
    } else clip;
    for (n.children.items) |c| try node(u, c, child_clip, depth + 1, scale, w);
}

fn rect(w: *std.Io.Writer, lead: []const u8, r: ui.Rect, scale: f32) !void {
    try w.print("{s}{d:.0},{d:.0} {d:.0}x{d:.0}", .{ lead, r.x / scale, r.y / scale, r.w / scale, r.h / scale });
}

test "layout_dump: the trigger fires once, on the configured frame" {
    var t = Trigger{};
    try std.testing.expect(!t.fire(3));
    try std.testing.expect(!t.fire(3));
    try std.testing.expect(t.fire(3));
    try std.testing.expect(!t.fire(3));
    var off = Trigger{};
    for (0..40) |_| try std.testing.expect(!off.fire(null));
}

test "layout_dump: the dump frame parses, else the default" {
    try std.testing.expectEqual(@as(u64, 12), frameFrom("12"));
    try std.testing.expectEqual(default_frame, frameFrom(null));
    try std.testing.expectEqual(default_frame, frameFrom("soon"));
}
