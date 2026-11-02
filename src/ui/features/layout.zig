const std = @import("std");
const Allocator = std.mem.Allocator;

const size_mod = @import("size.zig");
const Size = size_mod.Size;

pub const Anchor = enum {
    top_left,
    top_center,
    top_right,
    center_left,
    center,
    center_right,
    bottom_left,
    bottom_center,
    bottom_right,
    relative,
};

// ============================ Flow ===========================================

/// The **flow** of a parent's in-flow (`.relative`) children: how they arrange. It's a
/// small struct of *orthogonal* axes rather than one flat enum, because arrangement is a
/// product of independent choices — direction × wrap × reverse × main-distribution ×
/// cross-alignment — and enumerating that product by hand is what makes a layout engine
/// sprawl. One flow algorithm (`place`) reads these five knobs; every combination composes.
///
/// Modeled on CSS flexbox (`flex-direction` / `flex-wrap` / `justify-content` /
/// `align-items`). Out-of-flow children (`anchor != .relative`) ignore all of this — they
/// place themselves by their own `Anchor`, like absolute positioning.
pub const Flow = struct {
    /// The **main axis** — the direction children flow along. `.row` ⇒ main = x (children
    /// left-to-right); `.column` ⇒ main = y (top-to-bottom). The **cross axis** is the other
    /// one. Everything below is expressed in main/cross terms and mapped to x/y by `dir`.
    dir: Direction = .row,
    /// Lay the children out in reverse order along the main axis. Composes with any `main`
    /// alignment (it just reverses the sequence before packing).
    reverse: bool = false,
    /// Wrap onto a new line when the running main-axis extent would exceed the box, instead
    /// of overflowing in one line. Lines stack along the cross axis (flush from the start;
    /// `align-content`, which distributes the lines, is not modeled).
    wrap: bool = false,
    /// **Main-axis distribution**: where the *whole run* of children sits within the box's
    /// main extent, and how leftover main-axis space is shared. This is about the group
    /// (flexbox `justify-content`). Defaults to `.start` (flush at the leading edge).
    main: MainAlign = .start,
    /// **Cross-axis alignment**: where *each child individually* sits within its line's
    /// cross extent (flexbox `align-items`). Defaults to `.baseline` — text-first: a row of
    /// mixed-size text shares a common writing line; a plain box (no baseline) falls back to
    /// the trailing edge, and on a `.column` (where baseline is meaningless) it falls back to
    /// the leading edge (`.start`). `.stretch` instead *sizes* auto (`fit_children`/`content`)
    /// children to fill the line in the top-down pass, the way CSS equal-height columns work, so a
    /// template need not fake it with `pct_of_parent = 1.0` or fixed heights.
    cross: CrossAlign = .baseline,
};

pub const Direction = enum { row, column };

/// Main-axis distribution — how the run of children is placed within the box's main extent,
/// and how any leftover main-axis space is shared. `gap` (see `Layout.gap`) still spaces
/// adjacent children for the packed modes (`start`/`center`/`end`); the `space_*` modes
/// derive their own spacing from the free space and ignore `gap`.
pub const MainAlign = enum {
    /// Pack at the leading edge (default). Slack, if any, sits after the last child.
    start,
    /// Pack as a block, centered — slack split evenly before and after the run.
    center,
    /// Pack at the trailing edge — slack sits before the first child.
    end,
    /// First child at the leading edge, last at the trailing edge, equal space *between*
    /// each adjacent pair (no space at the ends). One child ⇒ leading edge.
    space_between,
    /// Equal space *around* every child — the end spaces are half the between spaces.
    space_around,
    /// Equal space *everywhere*, including both ends — n children make n+1 equal gaps.
    space_evenly,
};

/// Cross-axis alignment — where each child sits within its line's cross extent (and, for
/// `stretch`, how far it extends across it). `start`/
/// `center`/`end` are relative to the line's cross band (top/center/bottom for a row;
/// left/center/right for a column). `baseline` (rows only) lines every child's text baseline
/// onto a shared line, so mixed-size text reads on one row; a box with no baseline aligns to
/// its trailing edge, and on a column `baseline` degrades to `start`.
pub const CrossAlign = enum {
    start,
    center,
    end,
    baseline,
    /// Fill the line (CSS `align-items: stretch`): every in-flow child whose cross rule is
    /// auto (`fit_children`/`content`, and cross-axis `grow`, which acts as `content`) has its
    /// border box raised to the line's cross extent, then sits at the line start like
    /// `.start`. `fixed`/`pct_of_parent` children keep their size; a stretch never shrinks a
    /// child, and min/max still bound its content box. A non-wrapping line is the parent's
    /// content box; a wrapping run stretches each child to its own line. Applied top-down
    /// (`stretch_children`), so the stretched axis is definite for the child's descendants.
    /// Never feeds back into a `fit_children` parent, whose cross fit stays the plain max.
    stretch,
};

pub const ChildrenPosInfo = struct {
    x_offset: f32,
    y_offset: f32,
};

/// The **overflow** axis: what happens to content that exceeds a node's box. Pure
/// geometry, read *after* the solve — it never changes any computed size. Distinct
/// from the *sizing* axis (`SizeRule`, where the box yields) and from *content-fill*
/// (tiling/stretching a payload to the box, which is host paint policy): overflow keeps
/// the box fixed and constrains the *content's* visible extent. Orthogonal to
/// `scroll_x/y` — scroll *translates* children, overflow *masks* the result; a scroll
/// viewport is the composition `.clip` + a `scroll_y` offset (see `scroll_view`).
pub const Overflow = enum {
    /// Content spilling past the box paints (and hit-tests) normally. The default —
    /// every ordinary node.
    visible,
    /// Crop this node's subtree to its own box. Read by the host render walk (SDL
    /// clip rect) and by hit-testing.
    clip,
};

// ============================ Grid tracks ====================================

/// How one column track takes its base width (CSS `grid-template-columns` terms).
pub const Basis = union(enum) {
    /// A fixed width in px (the solve's units; the host scales logical px at build).
    px: f32,
    /// A share of the free space, by weight (CSS `Nfr`). The base is the track's `min`, so
    /// the default `min = 0` is CSS `minmax(0, Nfr)`.
    fr: f32,
    /// The widest non-spanning cell in this track over **every** participant of the set
    /// (max-content, measured in pass 1).
    auto,
};

/// One column track of a `TrackSet`.
pub const Track = struct {
    basis: Basis,
    /// Floor on the width (CSS `minmax` min). An `fr` track starts here.
    min: f32 = 0,
    /// Ceiling on the width; an `fr` track stops growing here and its excess goes to the
    /// other `fr` tracks. Below `min`, `min` wins.
    max: ?f32 = null,
    /// Opt-in priority shrink when the tracks overflow: null never shrinks below the base.
    /// Lower orders give way first, each down to its `min`, before the next order is touched;
    /// tracks of one order share in proportion to `(base - min)`. Anything left overflows.
    shrink_order: ?u8 = null,
    /// Dropped at this width: 0 wide, one adjacent gap removed, and implicit placement skips it.
    hidden: bool = false,
};

/// A set of column tracks shared by rows that are not siblings (a table head under the
/// frame and its rows inside a scroll view), so their columns line up without the template
/// threading widths through every row. One node declares it (`Layout.track_owner`); each
/// row that lays out by it is a participant (`Layout.track_row`) whose in-flow children are
/// its cells. See "Grid tracks" in the engine README.
///
/// `auto_max` and `widths` are solve scratch of the same length as `tracks`, provided by the
/// caller (an arena). The solve writes them; nothing else should.
pub const TrackSet = struct {
    tracks: []const Track,
    /// Space between adjacent visible tracks, px.
    col_gap: f32,
    /// Space between the implicit lines of one participant, px (CSS `row-gap`; `gap: 2px 9px`
    /// is row 2, column 9). It belongs to the set, beside `col_gap`, so every participant's
    /// lines are spaced alike; the participant's own `Layout.gap` is not read.
    row_gap: f32 = 0,
    /// Per track, the widest non-spanning cell seen this solve (`auto` tracks only).
    auto_max: []f32,
    /// Per track, the width solved for `solved_for`.
    widths: []f32,
    /// The participant content width `widths` was solved for; equal means reuse.
    solved_for: ?f32 = null,
    /// Debug guard: set while pass 1 is inside the owner's subtree, so a participant
    /// outside it (whose scratch would never be reset) trips an assert.
    open: bool = false,

    /// Solve `widths` for a participant whose content box is `avail` wide (memoized on
    /// `solved_for`). Base = px | auto_max | min (fr), clamped to [min, max]; hidden tracks
    /// are 0. Positive free space water-fills the `fr` tracks by weight up to their max;
    /// with no `fr` track it stays at the end. Negative free space is taken from the tracks
    /// with a `shrink_order`, lowest order first, each down to its min; the rest overflows.
    pub fn solve(self: *TrackSet, avail: f32) void {
        if (self.solved_for) |s| if (s == avail) return;
        self.solved_for = avail;
        var base_sum: f32 = 0;
        for (self.tracks, 0..) |_, t| {
            self.widths[t] = self.base(t);
            base_sum += self.widths[t];
        }
        // `avail − Σbase − gaps`, in that order: with one `fr` track it is exactly the
        // arithmetic `distribute_grow` does for one grower among fixed siblings.
        const free = avail - base_sum - self.gaps();
        if (free > 0) self.grow_fr(free) else if (free < 0) self.shrink(-free);
    }

    /// Track `t`'s base width (before free space is shared).
    fn base(self: *const TrackSet, t: usize) f32 {
        const tr = self.tracks[t];
        if (tr.hidden) return 0;
        return clamp_track(tr, switch (tr.basis) {
            .px => |v| v,
            .auto => self.auto_max[t],
            .fr => tr.min,
        });
    }

    /// The gaps between the visible tracks.
    fn gaps(self: *const TrackSet) f32 {
        var n: usize = 0;
        for (self.tracks) |tr| {
            if (!tr.hidden) n += 1;
        }
        return if (n > 1) self.col_gap * @as(f32, @floatFromInt(n - 1)) else 0;
    }

    /// What a participant's tracks need before any free space: Σ base + gaps. The pass-1
    /// width of a `fit_children` participant.
    fn base_extent(self: *const TrackSet) f32 {
        var sum: f32 = 0;
        for (self.tracks, 0..) |_, t| sum += self.base(t);
        return sum + self.gaps();
    }

    fn has_auto(self: *const TrackSet) bool {
        for (self.tracks) |tr| {
            if (tr.basis == .auto) return true;
        }
        return false;
    }

    /// Reset the per-solve scratch: run by the owner before pass 1 enters its subtree, every
    /// solve, so a re-solve of the same tree starts from nothing.
    fn open_solve(self: *TrackSet) void {
        @memset(self.auto_max, 0);
        self.solved_for = null;
        self.open = true;
    }

    fn fr_weight(tr: Track) f32 {
        if (tr.hidden) return 0;
        return switch (tr.basis) {
            .fr => |w| @max(0, w),
            else => 0,
        };
    }

    /// Weighted water filling over the `fr` tracks, the same rounds as `distribute_grow`: a
    /// track capped by its max keeps what fits and the rest goes round again by weight.
    fn grow_fr(self: *TrackSet, free: f32) void {
        var remaining = free;
        while (remaining > 0.0001) {
            var active: f32 = 0;
            for (self.tracks, 0..) |tr, t| {
                const w = fr_weight(tr);
                if (w <= 0) continue;
                if (track_max(tr)) |m| {
                    if (self.widths[t] + 0.0001 < m) active += w;
                } else active += w;
            }
            if (active <= 0) break; // no fr track, or every one is at its max
            var used: f32 = 0;
            for (self.tracks, 0..) |tr, t| {
                const w = fr_weight(tr);
                if (w <= 0) continue;
                const share = remaining * w / active;
                const capacity = if (track_max(tr)) |m| @max(0, m - self.widths[t]) else share;
                const add = @min(share, capacity);
                if (add <= 0) continue;
                self.widths[t] += add;
                used += add;
            }
            if (used <= 0.0001) break;
            remaining -= used;
        }
    }

    /// Priority shrink: order 0 gives up to its floors first, then order 1, and so on.
    /// Within one order, each track gives in proportion to its room `(width − min)`.
    fn shrink(self: *TrackSet, deficit_in: f32) void {
        var deficit = deficit_in;
        var order: u16 = 0;
        while (order <= std.math.maxInt(u8) and deficit > 0) : (order += 1) {
            var room: f32 = 0;
            for (self.tracks, 0..) |tr, t| {
                if (!gives_at(tr, order)) continue;
                room += @max(0, self.widths[t] - tr.min);
            }
            if (room <= 0) continue;
            const take = @min(deficit, room);
            for (self.tracks, 0..) |tr, t| {
                if (!gives_at(tr, order)) continue;
                if (take >= room) {
                    self.widths[t] = @min(self.widths[t], tr.min);
                } else {
                    // `take × (r / room)`: a lone track of its order gives exactly `take`.
                    const r = @max(0, self.widths[t] - tr.min);
                    self.widths[t] -= take * (r / room);
                }
            }
            deficit -= take;
        }
    }

    /// The first visible track at or after `col` (`tracks.len` when there is none).
    fn first_visible(self: *const TrackSet, col: usize) usize {
        var k = col;
        while (k < self.tracks.len and self.tracks[k].hidden) k += 1;
        return k;
    }

    /// The x of track `col` from the participant's content left: every earlier visible
    /// track plus its gap.
    fn x_of(self: *const TrackSet, col: usize) f32 {
        var x: f32 = 0;
        for (self.tracks[0..col], 0..) |tr, t| {
            if (!tr.hidden) x += self.widths[t] + self.col_gap;
        }
        return x;
    }

    /// A slot's border-box width: its visible tracks plus the gaps between them. A hidden
    /// track inside the span adds neither width nor gap.
    fn span_width(self: *const TrackSet, s: Slot) f32 {
        var w: f32 = 0;
        var shown: usize = 0;
        for (s.col..s.col + s.span) |t| {
            if (self.tracks[t].hidden) continue;
            if (shown > 0) w += self.col_gap;
            w += self.widths[t];
            shown += 1;
        }
        return w;
    }
};

/// Where one cell sits: its first track, how many tracks it covers, and which implicit line
/// of its participant it is on (0 is the first).
const Slot = struct {
    col: usize,
    span: usize,
    line: usize,
};

/// Placement over a participant's in-flow cells, in order: CSS grid auto-placement with
/// implicit rows (`grid-auto-flow: row`, not dense). The cursor is the track after the
/// previous cell. A cell starts a new line, at the line's first track, when
///   - its explicit `cell_col` is lower than the cursor (CSS moves to the next row rather
///     than back), or
///   - it is placed implicitly and its span does not fit in the tracks left on the line
///     (a surplus cell after the last track, or `span = all` after any cell).
/// Neither breaks a line that holds no cell yet: a span wider than the set, or one past its
/// end from an explicit `cell_col`, is clamped to the tracks left. An explicit `cell_col` at
/// or past the last track is a template error (asserted in debug). Every walk over the cells
/// (`collect_auto`, `size_cells`, `TrackLines`, `track_place`) steps this same sequence, so
/// they agree on every slot and every line.
const CellWalk = struct {
    col: usize = 0,
    line: usize = 0,

    fn next(self: *CellWalk, set: *const TrackSet, c: anytype) Slot {
        const n = set.tracks.len;
        const want = @max(1, @as(usize, c.layout.cell_span));
        const started = self.col > 0; // the current line holds a cell
        var col: usize = undefined;
        if (c.layout.cell_col) |k| {
            col = k;
            if (started and col < self.col) self.line += 1;
        } else {
            col = set.first_visible(self.col);
            if (started and col + want > n) {
                self.line += 1;
                col = set.first_visible(0);
            }
        }
        std.debug.assert(col < n); // cell_col out of range, or every track hidden
        col = @min(col, n);
        const span = @min(want, n - col);
        self.col = col + span;
        return .{ .col = col, .span = span, .line = self.line };
    }
};

fn track_max(tr: Track) ?f32 {
    return if (tr.max) |m| @max(tr.min, m) else null;
}

/// Whether `tr` takes part in the priority shrink round `order`.
fn gives_at(tr: Track, order: u16) bool {
    const o = tr.shrink_order orelse return false;
    return !tr.hidden and o == order;
}

fn clamp_track(tr: Track, v: f32) f32 {
    var r = @max(tr.min, v);
    if (track_max(tr)) |m| r = @min(r, m);
    return r;
}

pub const Layout = struct {
    /// How *this* node sits within its parent: one of the 9 anchor presets (it places
    /// itself, out-of-flow), or `.relative` (the parent's `flow` places it).
    anchor: Anchor,
    /// How this node's `.relative` children arrange — see `Flow`. Defaults to a plain row.
    flow: Flow = .{},
    /// Space inserted *between* adjacent flowed (`relative`) children along the main axis
    /// (and between wrapped lines on the cross axis). Not before the first / after the last,
    /// and ignored by the `space_*` main distributions (they compute their own spacing).
    /// A `fit_children` parent grows to include the gaps. Defaults to 0 — set via `with_gap`.
    gap: f32,
    /// Main-axis **margins** of this node as an in-flow child (CSS `margin` along the
    /// parent's main axis): extra space before (left in a row, top in a column) and after it,
    /// added to whatever `gap` already separates it from its neighbours. `before` is the
    /// physical leading edge and stays there under `reverse`, as CSS margins do. The packed
    /// run counts every child at its **outer** extent (box plus margins): a `fit_children`
    /// parent sums them, `grow`/`shrink` treat them as fixed space that never grows or
    /// shrinks, wrap packing breaks lines on them, and the `space_*` modes distribute what the
    /// outer extents leave. A margin at the run's start or end stays inside the parent's
    /// content box, so a lone leading margin is a pad of one child, not of the parent.
    ///
    /// Ignored when the parent does not flow this node: an anchored (out-of-flow) node, and a
    /// track cell, whose x comes from its tracks (asserted 0 in debug). There is no cross-axis
    /// margin; a cross inset is the parent's padding. Defaults to 0. Set via `with_margin`.
    margin_before: f32 = 0,
    margin_after: f32 = 0,
    /// Screen origin for a *parentless* (root) node: where its top-left lands. Lets a
    /// second, independent tree — an overlay/tooltip layer — be placed anywhere on
    /// screen instead of stacking at (0,0). Ignored once a node has a parent (it's
    /// positioned relative to that parent). Defaults to (0,0), so the main root is
    /// unaffected. Set via `with_origin`.
    origin_x: f32 = 0,
    origin_y: f32 = 0,
    /// Displace this node from wherever its anchor (or its parent's flow) put it, in px.
    /// Applied last, so it composes with a placement instead of replacing one: `.center`
    /// plus a computed delta is polar placement, which is how anything laid out by its own
    /// arithmetic — a radial board, a graph, a tooltip arrow — gets positioned at all.
    /// Nine anchor presets are otherwise the only way to place a child, and none of them
    /// takes a number. Defaults to (0,0). Set via `with_offset`.
    ///
    /// Distinct from `origin` (which positions a *root*, and only a root) and from
    /// `scroll` (which moves a node's *children*, not the node).
    offset_x: f32 = 0,
    offset_y: f32 = 0,
    /// Translates this node's *children* (not the node itself) by `-scroll_x`/`-scroll_y`
    /// — a positive value shifts flowed content up/left, as if scrolled down/right. This
    /// is how a scroll container (`scroll_view`) moves its overflowing `content`
    /// without a second layout pass: the container holds the offset, `place` folds it into
    /// the base position it hands each child. Defaults to 0 (no effect on ordinary nodes).
    /// Distinct from `origin`, which positions a *root* itself, not its children.
    scroll_x: f32 = 0,
    scroll_y: f32 = 0,
    /// Overflow handling for this node's content — see `Overflow`. Defaults to
    /// `.visible` (no cropping), so ordinary nodes are unaffected. Set directly
    /// (`node.layout.overflow = .clip`) or via `with_overflow`.
    overflow: Overflow = .visible,
    /// Declares a shared column-track set (see `TrackSet`, "Grid tracks" in the README). The
    /// owner resets the set's per-solve scratch before pass 1 visits its subtree, so every
    /// participant (`track_row`) must be a descendant. The owner does not lay its own
    /// children out by the tracks unless it is also a participant. Defaults to null.
    track_owner: ?*TrackSet = null,
    /// Makes this node a track **participant**: its in-flow children are cells, sized and
    /// placed on the x axis by the shared `TrackSet` instead of by `grow`/`shrink`/`main`.
    /// Must be a non-reversed `.row` under the set's owner. Cells that don't fit on the
    /// current line start a new one (CSS implicit grid rows, see `CellWalk`), so `flow.wrap`
    /// would mean nothing here and is asserted off in debug: lines come from the slots, never
    /// from widths. On y each line is aligned by `flow.cross` like one flow line (baseline-
    /// aware); lines stack with the set's `row_gap`.
    track_row: ?*TrackSet = null,
    /// As a cell of a participant: the track this cell starts in. Null (the default) takes
    /// the next visible track after the previous cell; an explicit index moves the cursor,
    /// so skipped tracks are left empty, and one lower than the cursor starts a new line.
    cell_col: ?u16 = null,
    /// As a cell of a participant: how many tracks this cell covers, from `cell_col`. Its
    /// width is the covered visible tracks plus the gaps between them; a span past the last
    /// track is clamped (`maxInt(u16)` is CSS `1 / -1` from track 0). Defaults to 1.
    cell_span: u16 = 1,
    _global_x: ?f32,
    _global_y: ?f32,

    pub fn init(anchor: Anchor, flow: ?Flow) Layout {
        return .{
            .anchor = anchor,
            .flow = flow orelse .{},
            .gap = 0,
            ._global_x = null,
            ._global_y = null,
        };
    }

    /// Copy with `gap` set — chains after `init` (`Layout.init(.., .{ .dir = .column }).with_gap(8)`).
    pub fn with_gap(self: Layout, g: f32) Layout {
        var l = self;
        l.gap = g;
        return l;
    }

    /// Copy with the root `origin` set — chains after `init`. Only meaningful on a root
    /// node (see `origin_x`/`origin_y`); use it to float an overlay tree at a point.
    pub fn with_origin(self: Layout, x: f32, y: f32) Layout {
        var l = self;
        l.origin_x = x;
        l.origin_y = y;
        return l;
    }

    /// Copy with the main-axis margins set — chains after `init`. See `margin_before`.
    pub fn with_margin(self: Layout, before: f32, after: f32) Layout {
        var l = self;
        l.margin_before = before;
        l.margin_after = after;
        return l;
    }

    /// Copy with `offset` set — chains after `init`. Displaces the node from its
    /// resolved placement (see `offset_x`).
    pub fn with_offset(self: Layout, dx: f32, dy: f32) Layout {
        var l = self;
        l.offset_x = dx;
        l.offset_y = dy;
        return l;
    }

    /// Copy with `overflow` set — chains after `init`. `.clip` crops this node's
    /// subtree to its box in the render walk (see `Overflow`).
    pub fn with_overflow(self: Layout, o: Overflow) Layout {
        var l = self;
        l.overflow = o;
        return l;
    }
};

// ============================ Public entry ===================================

/// Solve the whole tree, then place it. Widths are solved before heights, because a
/// wrapping row's height depends on its width (how many lines it breaks into):
///   1. `recalculate_size`    — bottom-up, both axes: intrinsic sizes and provisionals. A
///                              track owner resets its `TrackSet` first; participants
///                              record their `auto` tracks' max-content (`auto_max`).
///   2. `resolve_axis(.x)`    — top-down, x only: percentages, grow, shrink, stretch, and
///                              grid tracks (each participant solves its `TrackSet` and sizes
///                              its cells, definite for their descendants). Every width is
///                              final after it.
///      (boundary)            — with a measurer only: each `measure_h` node's
///                              `data_height`/`baseline` re-measured at its final width.
///   3. `recalculate_axis(.y)`— bottom-up, y only: every height again from scratch, with a
///                              wrapping row's lines packed against its final width.
///   4. `resolve_axis(.y)`    — top-down, y only: the mirror of step 2.
///   5. `place`               — top-down: assign every node its global position (a
///                              participant's cells at their tracks' x, `track_place`).
/// The sizing passes are pure (no host callback — `content` sizes read the host's
/// pre-measured `data_width`/`data_height`, set on the node at build). `place` takes a
/// scratch `Allocator` only to materialize each node's in-flow child list; it never
/// consults the host. Call at the root.
///
/// This entrypoint never re-measures: a `Size.measure_h` node keeps its build-time
/// `data_height`. `set_global_pos_measured` is the same solve with a host measurer called
/// once, between steps 2 and 3, for the opted-in nodes (see `measure_heights`).
pub fn set_global_pos(node: anytype, alloc: Allocator) anyerror!void {
    _ = try solve(node, alloc, null, NoMeasure{});
}

/// A height measured by the host at a node's resolved content width: the new `data_height`
/// and `baseline` (content-relative, like `Size.baseline`). See `set_global_pos_measured`.
pub const Measured = struct { height: f32, baseline: f32 };

/// The measurer behind the plain entrypoints: it has no `height_for_width`, and the solve
/// skips the measure walk for it at comptime, so the pure path makes no callback at all.
const NoMeasure = struct {};

/// `set_global_pos` with a host **measurer** for content whose height depends on its width
/// (text wrapped at the width the solve gives it). `measurer` is a comptime duck-typed
/// struct value with
///   `fn height_for_width(self, node: @TypeOf(node), width: f32) ?Measured`
/// called once per solve for each node with `Size.measure_h`, after every width is final
/// and before any height is computed. `width` is the node's resolved content-box width.
/// Returning null keeps the node's `data_height`/`baseline`. The measurer may only report a
/// height and baseline; it must not mutate the tree's sizing or layout (the solve writes the
/// result itself). It may record what it was given into host-side state it owns (the text
/// host stores the solved width it wraps or elides at), since nothing in the solve reads it.
pub fn set_global_pos_measured(node: anytype, alloc: Allocator, measurer: anytype) anyerror!void {
    _ = try solve(node, alloc, null, measurer);
}

/// The profiled `set_global_pos_measured`: the measure walk is timed as `Sample.measure`.
pub fn set_global_pos_measured_profiled(node: anytype, alloc: Allocator, clock: Clock, measurer: anytype) anyerror!Sample {
    return solve(node, alloc, clock, measurer);
}

// ============================ Sizing (passes 1–4) ============================

const Axis = enum { x, y };

/// Diagnostic variant of `set_global_pos`: identical solve, with nanosecond durations read
/// from the host's `clock`. Both bottom-up passes (1, 3) count as `intrinsic`, both
/// top-down passes (2, 4) as `relative`, and `place` as `placement`. The normal entrypoint
/// is clock-free and callback-free. Like `set_global_pos`, it never re-measures, so
/// `Sample.measure` stays 0.
pub fn set_global_pos_profiled(node: anytype, alloc: Allocator, clock: Clock) anyerror!Sample {
    return solve(node, alloc, clock, NoMeasure{});
}

const Clock = @import("../profile.zig").Clock;
const Sample = @import("../profile.zig").Sample;

/// Adds the time since the previous reading to a `Sample` field; does nothing without a
/// clock, so the unprofiled solve never reads one.
const Lap = struct {
    clock: ?Clock,
    last: u64,

    fn init(clock: ?Clock) Lap {
        return .{ .clock = clock, .last = if (clock) |c| c.now() else 0 };
    }

    fn add(self: *Lap, into: *u64) void {
        const c = self.clock orelse return;
        const t = c.now();
        into.* +|= t -| self.last;
        self.last = t;
    }
};

/// The one solve behind every entrypoint (see `set_global_pos` for the passes).
fn solve(node: anytype, alloc: Allocator, clock: ?Clock, measurer: anytype) anyerror!Sample {
    var sample: Sample = .{};
    var lap = Lap.init(clock);

    recalculate_size(node);
    lap.add(&sample.intrinsic);
    resolve_axis(node, .x);
    lap.add(&sample.relative);

    // Phase boundary: every width is final and no height has been resolved yet. A
    // `measure_h` node (text wrapped at its resolved width) is re-measured here by the host
    // measurer, before step 3 reads `data_height`. Pass 1's heights for those nodes came
    // from the build-time seed, and step 3 recomputes every height from scratch, so nothing
    // computed from the seed survives. Without a measurer this is compiled out.
    if (@TypeOf(measurer) != NoMeasure) {
        measure_heights(node, measurer);
        lap.add(&sample.measure);
    }

    recalculate_axis(node, .y);
    lap.add(&sample.intrinsic);
    resolve_axis(node, .y);
    lap.add(&sample.relative);

    try place(node, alloc, null);
    lap.add(&sample.placement);
    return sample;
}

/// The phase-boundary walk: every `measure_h` node in the subtree, pre-order, is measured at
/// its final content width. A non-null result replaces `data_height` and `baseline`;
/// `data_width` (the seed the x pass already used) is never touched.
fn measure_heights(node: anytype, measurer: anytype) void {
    if (node.size.measure_h) {
        if (measurer.height_for_width(node, inner_extent(node, .x))) |m| {
            node.size.data_height = m.height;
            node.size.baseline = m.baseline;
        }
    }
    for (node.children.items) |c| measure_heights(c, measurer);
}

/// The main (flow) axis of a parent's children: x for a row, y for a column. `fit_children`
/// sums child extents along this axis and maxes them across it.
fn main_axis(flow: Flow) Axis {
    return switch (flow.dir) {
        .row => .x,
        .column => .y,
    };
}

/// This box's extent along `axis`.
fn extent(node: anytype, axis: Axis) f32 {
    return if (axis == .x) node.size.width else node.size.height;
}

fn padding_extent(s: *const Size, axis: Axis) f32 {
    return if (axis == .x) s.padding.left + s.padding.right else s.padding.up + s.padding.down;
}

fn pct_less(s: *const Size, axis: Axis) f32 {
    return if (axis == .x) s.pct_less_width else s.pct_less_height;
}

fn min_extent(s: *const Size, axis: Axis) f32 {
    return @max(0, if (axis == .x) s.min_width else s.min_height);
}

fn max_extent(s: *const Size, axis: Axis) ?f32 {
    const raw = if (axis == .x) s.max_width else s.max_height;
    return if (raw) |v| @max(min_extent(s, axis), v) else null;
}

fn constrain_inner(s: *const Size, axis: Axis, value: f32) f32 {
    var result = @max(min_extent(s, axis), value);
    if (max_extent(s, axis)) |maximum| result = @min(result, maximum);
    return result;
}

fn inner_extent(node: anytype, axis: Axis) f32 {
    return extent(node, axis) - padding_extent(&node.size, axis);
}

fn set_inner_extent(node: anytype, axis: Axis, value: f32) void {
    const resolved = constrain_inner(&node.size, axis, value) + padding_extent(&node.size, axis);
    if (axis == .x) node.size.width = resolved else node.size.height = resolved;
}

fn axis_rule(node: anytype, axis: Axis) size_mod.SizeRule {
    return if (axis == .x) node.size.w else node.size.h;
}

/// The fixed space an in-flow child's margins add to its parent's main-axis run
/// (`Layout.margin_before` + `margin_after`). Never grows or shrinks.
fn margins(c: anytype) f32 {
    return c.layout.margin_before + c.layout.margin_after;
}

/// An in-flow child's **outer** extent on its parent's main axis `main`: its border box plus
/// its margins. Every walk that packs a run (`fit_axis`, `wrap_cross`, `stretch_children`,
/// `distribute_grow`, `distribute_shrink`, `flow_place`) measures a child by this, so they
/// agree on how much of the run each child takes.
fn outer_main(c: anytype, main: Axis) f32 {
    return extent(c, main) + margins(c);
}

/// How far child `c` advances a line being packed on `main`: its outer extent, plus `gap`
/// unless it opens the line (`first`). The one step behind every line break (`wrap_cross`,
/// `stretch_children`, `flow_place`), so the three break a wrapping run at the same children.
fn pack_step(c: anytype, main: Axis, first: bool, gap: f32) f32 {
    const om = outer_main(c, main);
    return if (first) om else gap + om;
}

/// `fit_children` on one axis. On the **main** axis: sum of *in-flow* child outer extents
/// (box plus `Layout.margin_*`) plus one `gap` per adjacent pair — a `fit` parent wraps its
/// spaced children exactly.
/// Anchored (out-of-flow) children are **excluded** from the main sum: they overlay,
/// they don't size their parent — a progress bar anchored
/// inside a tile must not make the tile grow/pulse with it (CSS absolute semantics). On
/// the **cross** axis: `fit_cross` (a max, or a baseline-aware ascent+descent for a
/// baseline row) — which deliberately *does* still count anchored children (the header's
/// fit-height is set by its two anchored groups). Reads children's already-resolved
/// bottom-up sizes.
///
/// A `wrap`ping run is measured across **all** its lines (`wrap_cross`)
/// whenever the main extent is knowable — otherwise a shelf that wraps to two rows would
/// report one row of height and whatever follows it would draw on top. `resolved_main` is
/// the node's final inner main extent when the caller has one (step 3, for a row).
fn fit_axis(node: anytype, axis: Axis, main: Axis, resolved_main: ?f32) f32 {
    const flow = node.layout.flow;
    if (axis != main) {
        // A track participant's lines come from its slots, not from `wrap` (asserted off).
        if (node.layout.track_row) |set| return track_cross(node, set);
        if (flow.wrap) {
            if (wrap_cross(node, axis, main, flow, resolved_main)) |h| return h;
        }
        return fit_cross(node, axis, flow);
    }
    // A track participant's main extent is its tracks' base widths, not the cells' sum.
    if (axis == .x) {
        if (node.layout.track_row) |set| return set.base_extent();
    }

    var acc: f32 = 0;
    var flow_count: usize = 0;
    for (node.children.items) |c| {
        if (c.layout.anchor != .relative) continue; // overlays don't size their parent
        acc += outer_main(c, axis);
        flow_count += 1;
    }
    if (flow_count > 1) acc += node.layout.gap * @as(f32, @floatFromInt(flow_count - 1));
    return acc;
}

/// The `k`-th in-flow child, in flow order. Linear per call (so the wrap measurement is
/// O(n²) in children) — deliberately allocation-free, since bottom-up sizing has no
/// allocator, and a wrapping run is a handful of tiles.
fn nth_flow_child(node: anytype, k: usize) @TypeOf(node) {
    var seen: usize = 0;
    for (node.children.items) |c| {
        if (c.layout.anchor != .relative) continue;
        if (seen == k) return c;
        seen += 1;
    }
    unreachable; // callers only ask for k < the counted in-flow child count
}

/// Cross-axis `fit` for a **wrapping** run: pack the in-flow children into lines exactly
/// the way `flow_place` does, then sum the line extents plus one `gap` per break. The limit
/// packed against is `resolved_main` when given, else a `fixed` main rule; with neither it
/// returns `null` and the caller falls back to the single-line max.
///
/// A row gets `resolved_main` in step 3 (`recalculate_axis(.y)`): its width and its
/// children's widths are final by then, whatever their rules (`grow`, `pct_of_parent`,
/// shrunk, stretched), so the lines counted are the lines `flow_place` will place. Pass 1
/// passes `null`, since only a `fixed` rule is known bottom-up (`pct_of_parent` is still
/// provisional and `fit_children` on the main axis is circular). A `fixed` rule value *is*
/// the content extent, the same number `flow_place` packs against after subtracting its
/// padding.
///
/// A column-wrap (main = y) is measured in pass 1 only: its `fit_children` width is needed
/// by the x pass, before any height is final, so it packs against a `fixed` height and the
/// children's pass-1 heights. That is the one coupling running from y back to x.
///
/// `reverse` is mirrored, since reversing changes which children share a line and
/// therefore how deep each line is.
fn wrap_cross(node: anytype, cross_axis: Axis, main: Axis, flow: Flow, resolved_main: ?f32) ?f32 {
    const main_rule = if (main == .x) node.size.w else node.size.h;
    const main_size = resolved_main orelse switch (main_rule) {
        .fixed => |n| constrain_inner(&node.size, main, n),
        else => return null,
    };
    const gap = node.layout.gap;

    var n: usize = 0;
    for (node.children.items) |c| {
        if (c.layout.anchor == .relative) n += 1;
    }
    if (n == 0) return 0;

    var total: f32 = 0;
    var lines: usize = 0;
    var i: usize = 0;
    while (i < n) {
        var j = i;
        var run: f32 = 0; // main extent incl. gaps so far — the wrap test
        var cross_max: f32 = 0;
        var max_ascent: f32 = 0;
        var max_descent: f32 = 0;
        while (j < n) {
            // Mirror `flow_place`'s child order: it reverses the in-flow list before packing.
            const c = nth_flow_child(node, if (flow.reverse) n - 1 - j else j);
            const step = pack_step(c, main, j == i, gap); // no leading gap on the first child
            if (j > i and run + step > main_size) break;
            run += step;
            cross_max = @max(cross_max, extent(c, cross_axis));
            if (main == .x) { // baseline only means something for a row
                max_ascent = @max(max_ascent, c.size.height - c.size.baseline_off());
                max_descent = @max(max_descent, c.size.baseline_off());
            }
            j += 1;
        }
        total += if (flow.dir == .row and flow.cross == .baseline)
            @max(max_ascent + max_descent, cross_max)
        else
            cross_max;
        lines += 1;
        i = j;
    }
    if (lines > 1) total += gap * @as(f32, @floatFromInt(lines - 1));
    return total;
}

/// Cross-axis `fit`. For a baseline row the run's extent is the deepest above-baseline
/// (ascent) plus the deepest below-baseline (descent), so mixed-size text still fits — an
/// out-of-flow child just contributes its own extent. Every other case is a plain max of
/// child cross-extents (which is what `start`/`center`/`end` need). Reduces to
/// `max(child cross-extent)` when no baseline row widens it. `stretch` is the plain max too:
/// it raises children to this fitted line in the top-down pass and never feeds back into it.
fn fit_cross(node: anytype, cross_axis: Axis, flow: Flow) f32 {
    if (flow.dir == .row and flow.cross == .baseline) {
        var max_ascent: f32 = 0; // deepest above the baseline (height − baseline)
        var max_descent: f32 = 0; // deepest below it (the stored baseline offset)
        var max_anchored: f32 = 0;
        for (node.children.items) |c| {
            const h = c.size.height;
            if (c.layout.anchor == .relative) {
                max_ascent = @max(max_ascent, h - c.size.baseline_off());
                max_descent = @max(max_descent, c.size.baseline_off());
            } else {
                max_anchored = @max(max_anchored, h);
            }
        }
        return @max(max_ascent + max_descent, max_anchored);
    }
    var acc: f32 = 0;
    for (node.children.items) |c| acc = @max(acc, extent(c, cross_axis));
    return acc;
}

/// Pass 1 — bottom-up sizing, both axes. Resolves `fixed`, `content`, and `fit_children`
/// (from already-resolved children); `pct_of_parent` and `grow` take a provisional = their
/// content size (the fallback value), finalized top-down in `resolve_axis`. A wrapping
/// row's height here counts lines only against a `fixed` width; step 3 redoes it.
///
/// Grid tracks hook in here twice: a `track_owner` resets its set before its subtree
/// (pre-order) and, when the set has an `auto` track, redoes its subtree's x extents once
/// every participant has reported; a `track_row` records its cells into `auto_max` after
/// they are sized (post-order), and its `fit_children` width is the tracks' base extent.
fn recalculate_size(node: anytype) void {
    // A track owner resets its set before any participant below it measures into it.
    if (node.layout.track_owner) |set| set.open_solve();
    for (node.children.items) |c| recalculate_size(c);
    if (node.layout.track_row) |set| collect_auto(node, set);
    if (node.layout.track_owner) |set| {
        // A `fit_children` participant (or anything fitting around one) read `auto_max` while
        // later participants had yet to report. The max now covers every participant, so
        // the subtree's x extents are redone; the max is idempotent, so the redo measures
        // the same.
        if (set.has_auto()) {
            for (node.children.items) |c| recalculate_axis(c, .x);
        }
        set.open = false;
    }
    bottom_up(node, .x, null);
    bottom_up(node, .y, null);
}

/// Pass 1 at a participant, its cells already sized: every non-spanning in-flow cell in an
/// `auto` track raises that track's `auto_max` to its border-box width.
fn collect_auto(node: anytype, set: *TrackSet) void {
    std.debug.assert(set.open); // a participant must be a descendant of its set's owner
    const flow = node.layout.flow;
    // Lines are implicit (`CellWalk`): `wrap` has no meaning on a participant.
    std.debug.assert(flow.dir == .row and !flow.wrap and !flow.reverse);
    var walk: CellWalk = .{};
    for (node.children.items) |c| {
        if (c.layout.anchor != .relative) continue;
        // A cell's x comes from its tracks; a main-axis margin would mean nothing there.
        std.debug.assert(margins(c) == 0);
        const s = walk.next(set, c);
        if (c.layout.cell_span != 1 or s.col >= set.tracks.len) continue;
        if (set.tracks[s.col].basis == .auto) set.auto_max[s.col] = @max(set.auto_max[s.col], extent(c, .x));
    }
}

/// Step 3 — pass 1 again on `axis` alone (the solve calls it for `.y`), after step 2 has
/// finalized the other axis. Every extent on `axis` is recomputed from its rule and the
/// children's fresh extents, so it depends only on rules, `data_*` and the other axis.
/// The only difference from pass 1 is that a row's `wrap_cross` packs against the row's
/// final inner width and its children's final widths, for any main rule.
fn recalculate_axis(node: anytype, comptime axis: Axis) void {
    for (node.children.items) |c| recalculate_axis(c, axis);
    const main = main_axis(node.layout.flow);
    // Only a row-wrap's height is solved against a final main extent. A column-wrap's width
    // would need final heights, which come after it (see `wrap_cross`).
    const resolved_main: ?f32 = if (axis == .y and main == .x) inner_extent(node, .x) else null;
    bottom_up(node, axis, resolved_main);
}

/// One node's bottom-up extent on `axis`, its children's already computed.
fn bottom_up(node: anytype, axis: Axis, resolved_main: ?f32) void {
    const s = &node.size;
    const main = main_axis(node.layout.flow);
    const content = if (axis == .x) s.data_width else s.data_height;
    const raw = switch (axis_rule(node, axis)) {
        .fixed => |n| n,
        .content => content,
        .pct_of_parent, .grow => content, // provisional; the top-down pass finalizes these
        .fit_children => fit_axis(node, axis, main, resolved_main),
    };
    const resolved = constrain_inner(s, axis, raw) + padding_extent(s, axis);
    if (axis == .x) s.width = resolved else s.height = resolved;
}

/// Steps 2 and 4 — top-down parent-relative finalize on one axis. Percentages resolve
/// against definite parent content boxes and size the child's whole box (its padding
/// included, see `finalize_axis`), then, when `axis` is the parent's main axis, in-flow
/// `grow` children divide the remaining space and opted-in shrinkers absorb an overflow
/// before their descendants resolve. `fit_children` is indefinite for its in-flow children,
/// whose percentages and growers fall back to content; an out-of-flow child's percentage
/// resolves against the fitted size.
///
/// When `axis` is the cross axis of a `cross = .stretch` parent, auto-sized in-flow children
/// are then raised to their line's cross extent (`stretch_children`), still before their
/// descendants resolve, so a stretched `fit_children` axis counts as definite for them: a
/// `1.0` grandchild fills the stretched box. Per parent the order is finalize children →
/// main-axis `grow` → main-axis shrink → cross-axis stretch → recurse.
///
/// A track participant (`Layout.track_row`) replaces grow and shrink on x with `size_cells`:
/// its `TrackSet` is solved against its content width and every in-flow cell takes its slot's
/// width, which counts as definite for the cell's descendants (`is_cell`).
///
/// Run for x first, then (after step 3) for y. No x decision reads a height except a
/// column-wrap's stretch, which packs its lines against the pass-1 heights.
fn resolve_axis(root: anytype, comptime axis: Axis) void {
    finalize_node(root, axis, true, 0);
    resolve_children(root, axis, rule_definite(axis_rule(root, axis)));
}

fn finalize_node(node: anytype, comptime axis: Axis, p_def: bool, p_inner: f32) void {
    const s = &node.size;
    const content = if (axis == .x) s.data_width else s.data_height;
    set_inner_extent(node, axis, finalize_axis(s, axis, axis_rule(node, axis), content, inner_extent(node, axis), p_def, p_inner));
}

fn rule_definite(rule: size_mod.SizeRule) bool {
    return switch (rule) {
        .fit_children => false,
        else => true,
    };
}

fn resolve_children(node: anytype, comptime axis: Axis, def: bool) void {
    const p_inner = inner_extent(node, axis);
    // An out-of-flow child never feeds its parent's fit on the main axis, and on the cross
    // axis only through its bottom-up (content) extent, so a `fit_children` parent's size is
    // final by now: a percentage on an anchored child resolves against it. In-flow
    // children keep the indefinite fallback, since their size is what the fit summed.
    for (node.children.items) |c| {
        const oof = c.layout.anchor != .relative;
        finalize_node(c, axis, def or oof, p_inner);
    }

    const main = main_axis(node.layout.flow);
    if (axis == .x and node.layout.track_row != null) {
        size_cells(node, node.layout.track_row.?);
    } else if (main == axis and def) {
        distribute_grow(node, main);
        distribute_shrink(node, main);
    }
    if (node.layout.flow.cross == .stretch and cross(main) == axis) stretch_children(node, main);

    for (node.children.items) |c| {
        resolve_children(c, axis, rule_definite(axis_rule(c, axis)) or stretches(node, c, axis) or is_cell(node, c, axis));
    }
}

/// Whether `c` is a track cell of `node` on `axis`: its width came from the tracks, so it is
/// definite for its descendants the way a stretched axis is (a `.fill` text or a `1.0`
/// grandchild resolves against the track).
fn is_cell(node: anytype, c: anytype, axis: Axis) bool {
    return axis == .x and node.layout.track_row != null and c.layout.anchor == .relative;
}

/// `resolve_axis(.x)` at a participant, in place of grow and shrink: solve the shared tracks
/// against this row's content width, then give each in-flow cell its slot's border box (its
/// own padding inside, its min/max on the content box).
fn size_cells(node: anytype, set: *TrackSet) void {
    set.solve(inner_extent(node, .x));
    var walk: CellWalk = .{};
    for (node.children.items) |c| {
        if (c.layout.anchor != .relative) continue;
        const s = walk.next(set, c);
        set_inner_extent(c, .x, @max(0, set.span_width(s) - padding_extent(&c.size, .x)));
    }
}

/// Whether `c`'s `axis` is stretched by its parent `node`: the parent's flow is `.stretch`,
/// `c` is in flow, `axis` is the parent's cross axis, and `c`'s rule there is auto. The same
/// test picks who `stretch_children` raises and whose axis then counts as definite, so the
/// two can't disagree. Every such child is raised (the line is always known in the top-down pass).
fn stretches(node: anytype, c: anytype, axis: Axis) bool {
    if (node.layout.flow.cross != .stretch or c.layout.anchor != .relative) return false;
    if (axis == main_axis(node.layout.flow)) return false;
    return switch (axis_rule(c, axis)) {
        // Cross-axis `grow` has no share to take and falls back to content, so it stretches.
        .fit_children, .content, .grow => true,
        .fixed, .pct_of_parent => false,
    };
}

/// Raise `c`'s cross border box to `line`. Never shrinks it below its current (bottom-up)
/// extent; `set_inner_extent` keeps min/max on the content box, so a max can cap it short.
fn stretch_to(c: anytype, axis: Axis, line: f32) void {
    const target = @max(extent(c, axis), line);
    set_inner_extent(c, axis, target - padding_extent(&c.size, axis));
}

/// `cross = .stretch`, top-down. A single line is the parent's content box on the cross axis
/// (for a `fit_children` parent that is the already-fitted max, so shorter siblings grow to
/// the tallest, as in CSS). A wrapping run is packed into lines exactly as `flow_place` packs
/// them (flow order, `reverse`, `gap`, against the content-box main extent) and each child
/// takes its own line's max. `place`'s line extents come out unchanged, because no child
/// grows past the line it was measured in. A row-wrap stretches in the y pass against final
/// widths; a column-wrap stretches in the x pass, so it packs against bottom-up heights. A
/// track participant takes its lines from its slots instead (`track_stretch`).
fn stretch_children(node: anytype, main: Axis) void {
    const ca = cross(main);
    const flow = node.layout.flow;
    if (node.layout.track_row) |set| return track_stretch(node, set);
    if (!flow.wrap) {
        const line = inner_extent(node, ca);
        for (node.children.items) |c| {
            if (stretches(node, c, ca)) stretch_to(c, ca, line);
        }
        return;
    }

    var n: usize = 0;
    for (node.children.items) |c| {
        if (c.layout.anchor == .relative) n += 1;
    }
    const main_size = inner_extent(node, main);
    const gap = node.layout.gap;
    var i: usize = 0;
    while (i < n) {
        var j = i;
        var run: f32 = 0;
        var line: f32 = 0;
        while (j < n) {
            const c = nth_flow_child(node, if (flow.reverse) n - 1 - j else j);
            const step = pack_step(c, main, j == i, gap);
            if (j > i and run + step > main_size) break;
            run += step;
            line = @max(line, extent(c, ca));
            j += 1;
        }
        for (i..j) |k| {
            const c = nth_flow_child(node, if (flow.reverse) n - 1 - k else k);
            if (stretches(node, c, ca)) stretch_to(c, ca, line);
        }
        i = j;
    }
}

fn is_grow(rule: size_mod.SizeRule) bool {
    return switch (rule) {
        .grow => true,
        else => false,
    };
}

/// The spacing a main-axis run spends between its `flow_count` in-flow children: one `gap`
/// per adjacent pair for the packed modes (`start`/`center`/`end`), 0 for the `space_*`
/// modes, which derive their own spacing from the free space.
fn main_spacing(node: anytype, flow_count: usize) f32 {
    const uses_gap = switch (node.layout.flow.main) {
        .start, .center, .end => true,
        else => false,
    };
    return if (uses_gap and flow_count > 1)
        node.layout.gap * @as(f32, @floatFromInt(flow_count - 1))
    else
        0;
}

/// A grower's weight (`Size.grow_weight`); anything `<= 0` means it does not grow.
fn grow_weight(c: anytype) f32 {
    return @max(0, c.size.grow_weight);
}

/// Weighted water filling (CSS `flex-grow`) over the in-flow growers on the parent's main
/// axis. Every grower starts at its minimum. Each round, an active grower (positive weight,
/// below its max) takes `remaining × w / Σ w(active)`; a max-capped grower keeps only what
/// fits and the unused part goes round again to the others, still by weight. A weight of 0
/// holds the grower at its minimum, and an all-zero sum leaves every grower there. With all
/// weights 1 this is the plain equal share, bit for bit. Fixed siblings and minimums are
/// never reduced here: if they exceed the parent the run overflows, unless
/// `distribute_shrink` takes the overflow out of siblings that opted in. Every in-flow
/// child's margins (a grower's too) are fixed space taken off the top.
fn distribute_grow(node: anytype, main: Axis) void {
    var flow_count: usize = 0;
    var grow_count: usize = 0;
    var fixed_sum: f32 = 0;
    var grow_padding: f32 = 0;
    var min_sum: f32 = 0;

    for (node.children.items) |c| {
        if (c.layout.anchor != .relative) continue;
        flow_count += 1;
        fixed_sum += margins(c);
        if (is_grow(axis_rule(c, main))) {
            grow_count += 1;
            grow_padding += padding_extent(&c.size, main);
            const minimum = min_extent(&c.size, main);
            min_sum += minimum;
            set_inner_extent(c, main, minimum);
        } else {
            fixed_sum += extent(c, main);
        }
    }
    if (grow_count == 0) return;

    const spacing = main_spacing(node, flow_count);
    const available = @max(0, inner_extent(node, main) - fixed_sum - grow_padding - spacing);
    var remaining = @max(0, available - min_sum);

    while (remaining > 0.0001) {
        var active_weight: f32 = 0;
        for (node.children.items) |c| {
            if (c.layout.anchor != .relative or !is_grow(axis_rule(c, main))) continue;
            const w = grow_weight(c);
            if (w <= 0) continue;
            const current = inner_extent(c, main);
            if (max_extent(&c.size, main)) |maximum| {
                if (current + 0.0001 < maximum) active_weight += w;
            } else active_weight += w;
        }
        if (active_weight <= 0) break; // every grower is capped, or every weight is 0

        var used: f32 = 0;
        for (node.children.items) |c| {
            if (c.layout.anchor != .relative or !is_grow(axis_rule(c, main))) continue;
            const w = grow_weight(c);
            if (w <= 0) continue;
            // `remaining × w` first: with w = 1 that is exact, so all-1 weights reproduce
            // the equal `remaining / active` share bit for bit.
            const share = remaining * w / active_weight;
            const current = inner_extent(c, main);
            const capacity = if (max_extent(&c.size, main)) |maximum| @max(0, maximum - current) else share;
            const add = @min(share, capacity);
            if (add <= 0) continue;
            set_inner_extent(c, main, current + add);
            used += add;
        }
        if (used <= 0.0001) break;
        remaining -= used;
    }
}

/// Whether `c` takes part in `distribute_shrink`: in flow, `shrink > 0`, and not a grower
/// on `main` (a grower is already at its minimum whenever the run overflows, so its
/// `shrink` is ignored).
fn shrinks(c: anytype, main: Axis) bool {
    return c.layout.anchor == .relative and c.size.shrink > 0 and !is_grow(axis_rule(c, main));
}

/// How much shrink ratio `c` can absorb before it reaches its floor:
/// `(base − floor) / (shrink × base)`, with `base` its current content extent. A child with
/// no content (`base = 0`) has no room.
fn shrink_room(c: anytype, main: Axis) f32 {
    const base = inner_extent(c, main);
    const scaled = c.size.shrink * base;
    if (scaled <= 0) return 0;
    return @max(0, base - min_extent(&c.size, main)) / scaled;
}

const ShrinkTally = struct {
    /// Shrinkers frozen at their floor at this ratio.
    frozen: usize = 0,
    /// The overflow the frozen ones absorb, `Σ (base − floor)`.
    released: f32 = 0,
    /// `Σ (shrink × base)` over the ones still free.
    weight: f32 = 0,
};

/// Split the shrinkers at `ratio`: those whose room is below it would pass their floor and
/// freeze there; the rest share what is left of the overflow.
fn shrink_tally(node: anytype, main: Axis, ratio: f32) ShrinkTally {
    var t: ShrinkTally = .{};
    for (node.children.items) |c| {
        if (!shrinks(c, main)) continue;
        const base = inner_extent(c, main);
        if (shrink_room(c, main) < ratio) {
            t.frozen += 1;
            t.released += @max(0, base - min_extent(&c.size, main));
        } else t.weight += c.size.shrink * base;
    }
    return t;
}

/// Opt-in flex shrink (CSS `flex-shrink` with CSS's weighting) on a definite parent's main
/// axis, run right after `distribute_grow`. When the in-flow children's outer extents (border
/// box plus margins, which never shrink) plus spacing (`gap` only for the packed modes, as in
/// `distribute_grow`) exceed the parent's
/// content box, the overflow comes out of the children with `Size.shrink > 0`, each in
/// proportion to `shrink × base`, where `base` is its content extent after finalize and
/// grow. Weighting by base means a wide column gives up more than a narrow one with the
/// same factor, so neither is driven to zero first. Padding never shrinks.
///
/// No child goes below its main-axis minimum. One that would is frozen at it and the rest
/// of the overflow is shared again among the others (the same water filling as the grow
/// caps). If every shrinker reaches its floor, the run still overflows. The loop needs no
/// per-child storage: at a common ratio `λ`, a child is frozen exactly when its
/// `shrink_room` is below `λ`, and freezing a child only raises `λ`, so the frozen set
/// only grows and settles within one round per shrinker. Sizes are written once at the
/// end, so every round reads the untouched bases.
///
/// Skipped for a wrapping run, which breaks lines instead (CSS shrinks each line on its
/// own; the engine does not). Descendants resolve against the shrunk size, since the
/// recursion runs afterwards. A shrunk `fit_children` child keeps its rule, so its own
/// in-flow children still see an indefinite parent; only its box got smaller.
fn distribute_shrink(node: anytype, main: Axis) void {
    if (node.layout.flow.wrap) return;
    var flow_count: usize = 0;
    var shrinker_count: usize = 0;
    var total: f32 = 0;
    for (node.children.items) |c| {
        if (c.layout.anchor != .relative) continue;
        flow_count += 1;
        total += outer_main(c, main);
        if (shrinks(c, main)) shrinker_count += 1;
    }
    if (shrinker_count == 0) return;
    const overflow = total + main_spacing(node, flow_count) - inner_extent(node, main);
    if (!(overflow > 0)) return;

    var ratio: f32 = 0; // λ; 0 freezes nobody, so the first round tallies everyone
    var frozen: usize = 0;
    var round: usize = 0;
    while (round <= shrinker_count) : (round += 1) {
        const t = shrink_tally(node, main, ratio);
        if (round > 0 and t.frozen == frozen) break; // λ agrees with the set it came from
        frozen = t.frozen;
        if (t.weight <= 0) { // everyone is at their floor; the rest overflows
            ratio = std.math.inf(f32);
            break;
        }
        ratio = @max(0, overflow - t.released) / t.weight;
    }

    for (node.children.items) |c| {
        if (!shrinks(c, main)) continue;
        const base = inner_extent(c, main);
        const target = if (shrink_room(c, main) < ratio)
            min_extent(&c.size, main)
        else
            base - ratio * c.size.shrink * base;
        set_inner_extent(c, main, target);
    }
}

/// One axis's final **content** extent (the caller adds padding back on). Intrinsic rules
/// (`fixed`, `content`, `fit_children`) size the content and padding grows the box around
/// it. A definite `pct_of_parent` sizes the whole box instead, as `grow` does: the fraction
/// is taken of the parent's content box and the node's own padding comes out of that share,
/// so `1.0` plus padding fills the parent rather than overflowing it by the padding. Padding
/// wider than the share leaves 0 content (the box is then just the padding). A percentage's
/// `Size.pct_less_*` comes off the share before the padding does (CSS `calc(p% − Npx)`).
/// Min/max still bound the content box. The indefinite fallback is `content_seed`, a content
/// size.
fn finalize_axis(s: *const Size, axis: Axis, rule: size_mod.SizeRule, content_seed: f32, pass1_inner: f32, p_def: bool, p_inner: f32) f32 {
    const raw = switch (rule) {
        .fixed => |n| n,
        .content => content_seed,
        .fit_children => pass1_inner,
        .pct_of_parent => |f| if (p_def) @max(0, p_inner * f - pct_less(s, axis) - padding_extent(s, axis)) else content_seed,
        .grow => content_seed,
    };
    return constrain_inner(s, axis, raw);
}

// ============================ Placement (pass 3) =============================

/// Assign global positions top-down. Sizes are already resolved, so this is pure geometry;
/// the `Allocator` is scratch space to materialize each node's in-flow child list (so the
/// flow algorithm reads as one clean loop, and there are no fixed-size stack buffers).
///
/// Each node: resolve its own global position, place its out-of-flow (anchored) children
/// (each self-anchors), then run `flow_place` over its in-flow (`.relative`) children.
fn place(node: anytype, alloc: Allocator, info: ?ChildrenPosInfo) anyerror!void {
    const s: *Size = &node.size;
    const l: *Layout = &node.layout;

    // --- this node's own global position -------------------------------------------------
    var pw: f32 = 0.0;
    var ph: f32 = 0.0;
    var px: f32 = 0.0;
    var py: f32 = 0.0;
    if (node.parent) |p| {
        // Base against the parent's *content box*, not its full box: shrink the extent by
        // the parent's padding and shift the origin in by its leading padding. This is the
        // one spot that makes padding inset children — both the flowed run below (whose
        // offsets add onto px/py) and the anchored path (which anchors within pw/ph at
        // px/py) inherit the inset for free, so `flow_place`/`set_indep_global_pos` can work
        // in pure content-box coordinates (origin 0).
        const pp = p.size.padding;
        pw = p.size.width - pp.left - pp.right;
        ph = p.size.height - pp.up - pp.down;
        px = (p.layout._global_x orelse 0.0) - p.layout.scroll_x + pp.left;
        py = (p.layout._global_y orelse 0.0) - p.layout.scroll_y + pp.up;
    } else {
        // Root: seed from its `origin` (0,0 for the main tree; the cursor/icon point for a
        // floating overlay). Anchor math runs against a zero-size parent, so a `.top_left`
        // overlay lands exactly on its origin.
        px = l.origin_x;
        py = l.origin_y;
    }

    var x: f32, var y: f32 = .{ undefined, undefined };
    if (l.anchor != .relative) {
        x, y = set_indep_global_pos(s.*, l.anchor, pw, ph);
    } else {
        const my_offsets = info orelse return error.NoInfoForChildren;
        x = my_offsets.x_offset;
        y = my_offsets.y_offset;
    }
    // `offset` is the last word on position, applied after the anchor (or the flow) has
    // resolved — so it *displaces* a placement rather than replacing it. Both paths get
    // it: `.center` plus a delta is polar placement, and a flowed node can be nudged
    // without leaving the run.
    l._global_x = px + x + l.offset_x;
    l._global_y = py + y + l.offset_y;

    // --- children: place anchored (out-of-flow) inline, collect the in-flow run ----------
    var n_flow: usize = 0;
    for (node.children.items) |c| {
        if (c.layout.anchor == .relative) {
            n_flow += 1;
        } else {
            try place(c, alloc, null); // out-of-flow: places itself by its own anchor
        }
    }
    if (n_flow == 0) return;

    const flow_kids = try alloc.alloc(@TypeOf(node), n_flow);
    var w: usize = 0;
    for (node.children.items) |c| {
        if (c.layout.anchor == .relative) {
            flow_kids[w] = c;
            w += 1;
        }
    }
    if (l.flow.reverse) std.mem.reverse(@TypeOf(node), flow_kids);

    if (l.track_row) |set| return track_place(node, alloc, flow_kids, set);
    try flow_place(node, alloc, flow_kids);
}

/// The cross extent of one line of children, and its shared baseline: the plain max of the
/// children's cross extents, or for a baseline row the deepest ascent plus the deepest
/// descent when that is larger. `flow_place` keeps one per line; `TrackLines` one per line
/// of a track participant.
const LineCross = struct {
    max: f32 = 0,
    ascent: f32 = 0,
    descent: f32 = 0,

    fn add(self: *LineCross, c: anytype, m: Axis) void {
        self.max = @max(self.max, extent(c, cross(m)));
        if (m == .x) { // baseline only means something for a row
            self.ascent = @max(self.ascent, c.size.height - c.size.baseline_off());
            self.descent = @max(self.descent, c.size.baseline_off());
        }
    }

    fn line(self: LineCross, flow: Flow) f32 {
        return if (flow.dir == .row and flow.cross == .baseline)
            @max(self.ascent + self.descent, self.max) // a baseline row can be deeper than any child
        else
            self.max;
    }
};

/// Place a track participant's in-flow `kids` line by line (`TrackLines`): each cell at its
/// track's x (the visible tracks before it plus their gaps) and across its line by
/// `flow.cross`, exactly as `flow_place` aligns one line; each line starts at the previous
/// line's cross extent plus the set's `row_gap`. `flow.main` is not read: free space the
/// tracks don't take stays after the last track. The tracks are solved again for this row's
/// width, which is free when it matches the last solve and keeps rows of different widths
/// correct.
fn track_place(node: anytype, alloc: Allocator, kids: []@TypeOf(node), set: *TrackSet) anyerror!void {
    const flow = node.layout.flow;
    set.solve(inner_extent(node, .x));
    var lines = TrackLines(@TypeOf(node)){ .set = set, .kids = kids };
    var walk: CellWalk = .{}; // the same steps `lines` takes, so the same slots
    var line_start: f32 = 0;
    while (lines.next()) |ln| {
        const line_cross = ln.lc.line(flow);
        for (kids[ln.start..ln.end]) |c| {
            const s = walk.next(set, c);
            const xo = set.x_of(s.col);
            const yo = line_start + cross_within(flow, .x, line_cross, c, ln.lc.ascent);
            try place(c, alloc, .{ .x_offset = xo, .y_offset = yo });
        }
        line_start += line_cross + set.row_gap;
    }
}

/// A participant's cells, one implicit line at a time: each `next` returns the next line's
/// range `[start, end)` of `kids` and its `LineCross`. Anchored children inside the range are
/// skipped (they are not cells and never break a line). The one line walk behind the
/// participant's height (`track_cross`), its stretch (`track_stretch`) and its placement
/// (`track_place`), so the three can't disagree on which cells share a line.
fn TrackLines(comptime N: type) type {
    return struct {
        set: *const TrackSet,
        kids: []const N,
        walk: CellWalk = .{},
        i: usize = 0,

        const Line = struct { start: usize, end: usize, lc: LineCross };

        fn next(self: *@This()) ?Line {
            while (self.i < self.kids.len and self.kids[self.i].layout.anchor != .relative) self.i += 1;
            if (self.i >= self.kids.len) return null;
            const start = self.i;
            var lc: LineCross = .{};
            var line: ?usize = null;
            while (self.i < self.kids.len) : (self.i += 1) {
                const c = self.kids[self.i];
                if (c.layout.anchor != .relative) continue;
                const before = self.walk;
                const s = self.walk.next(self.set, c);
                if (line) |l| {
                    if (s.line != l) {
                        self.walk = before; // this cell opens the next line; step it again there
                        break;
                    }
                }
                line = s.line;
                lc.add(c, .x);
            }
            return .{ .start = start, .end = self.i, .lc = lc };
        }
    };
}

/// A track participant's `fit_children` height: Σ over its lines of the line's cross extent
/// (`LineCross`, so a baseline row counts ascent + descent per line), plus `row_gap` between
/// lines. An anchored child still raises it to its own height, as `fit_cross` does, so one
/// line reproduces `fit_cross` exactly.
fn track_cross(node: anytype, set: *const TrackSet) f32 {
    const flow = node.layout.flow;
    var lines = TrackLines(@TypeOf(node)){ .set = set, .kids = node.children.items };
    var total: f32 = 0;
    var count: usize = 0;
    while (lines.next()) |ln| {
        total += ln.lc.line(flow);
        count += 1;
    }
    if (count > 1) total += set.row_gap * @as(f32, @floatFromInt(count - 1));
    var anchored: f32 = 0;
    for (node.children.items) |c| {
        if (c.layout.anchor != .relative) anchored = @max(anchored, c.size.height);
    }
    return @max(total, anchored);
}

/// `cross = .stretch` on a participant. One line stretches to the participant's content box,
/// as a non-wrapping row does; with several lines each cell stretches to its own line's
/// extent, as a wrapping run does (no `align-content`: a taller participant keeps its slack
/// after the last line).
fn track_stretch(node: anytype, set: *const TrackSet) void {
    var counting = TrackLines(@TypeOf(node)){ .set = set, .kids = node.children.items };
    var count: usize = 0;
    while (counting.next()) |_| count += 1;
    var lines = TrackLines(@TypeOf(node)){ .set = set, .kids = node.children.items };
    while (lines.next()) |ln| {
        const line = if (count == 1) inner_extent(node, .y) else ln.lc.line(node.layout.flow);
        for (node.children.items[ln.start..ln.end]) |c| {
            if (stretches(node, c, .y)) stretch_to(c, .y, line);
        }
    }
}

/// The one flow algorithm: arrange `kids` (already ordered, reverse applied) inside `node`'s
/// box per its `Flow`. Breaks them into lines (one line unless `wrap`), distributes each line
/// along the main axis (`flow.main`), aligns each child across it (`flow.cross`), and stacks
/// the lines along the cross axis. Axis-generic: it works in (main, cross) and maps to (x, y)
/// via `dir`, so a row and a column share every line of code. Each child takes its outer
/// extent (`outer_main`) of the line: the cursor steps over its `margin_before`, places it,
/// then steps over its box and `margin_after`, and the distribution shares what the outer
/// extents leave (CSS distributes free space between margin boxes).
fn flow_place(node: anytype, alloc: Allocator, kids: []@TypeOf(node)) anyerror!void {
    const flow = node.layout.flow;
    const m = main_axis(flow); // .x for a row, .y for a column
    const pad = node.size.padding;
    // Flow within the *content* box, not the full box. `place` already shifted this node's
    // children's origin in by the leading padding (via px/py), so here we only shrink the
    // main extent by the padding on the main axis — every offset below is content-relative
    // (origin 0). The cross axis needs nothing: no distribution reads the box's cross extent,
    // and `line_start` starting at 0 plus the px/py inset already places the first line
    // against the leading cross padding.
    const main_size = extent(node, m) - (if (m == .x) pad.left + pad.right else pad.up + pad.down);
    const gap = node.layout.gap;

    var line_start: f32 = 0; // cross-axis cursor: where the current line begins
    var i: usize = 0;
    while (i < kids.len) {
        // -- gather this line [i, j): pack children until the box is full (when wrapping) --
        var j = i;
        var run: f32 = 0; // main extent incl. gaps so far — the wrap test
        var main_sum: f32 = 0; // sum of child outer main extents (no gaps)
        var lc: LineCross = .{};
        while (j < kids.len) {
            const c = kids[j];
            const step = pack_step(c, m, j == i, gap); // no leading gap on the first child
            if (flow.wrap and j > i and run + step > main_size) break;
            run += step;
            main_sum += outer_main(c, m);
            lc.add(c, m);
            j += 1;
        }
        const count = j - i;
        const fcount: f32 = @floatFromInt(count);
        const line_cross = lc.line(flow);

        // -- main-axis distribution: leading offset + spacing between children --
        var lead: f32 = 0;
        var between: f32 = gap;
        switch (flow.main) {
            .start => {},
            .center => lead = (main_size - (main_sum + gap * (fcount - 1))) / 2,
            .end => lead = main_size - (main_sum + gap * (fcount - 1)),
            .space_between => between = if (count > 1) (main_size - main_sum) / (fcount - 1) else 0,
            .space_around => {
                const u = (main_size - main_sum) / fcount;
                lead = u / 2;
                between = u;
            },
            .space_evenly => {
                const u = (main_size - main_sum) / (fcount + 1);
                lead = u;
                between = u;
            },
        }

        // -- place each child of the line --
        var cursor = lead;
        for (kids[i..j]) |c| {
            cursor += c.layout.margin_before;
            const co = line_start + cross_within(flow, m, line_cross, c, lc.ascent);
            const xo = if (m == .x) cursor else co;
            const yo = if (m == .x) co else cursor;
            try place(c, alloc, .{ .x_offset = xo, .y_offset = yo });
            cursor += extent(c, m) + c.layout.margin_after + between;
        }

        line_start += line_cross + gap; // wrapped lines are gap-separated on the cross axis
        i = j;
    }
}

/// The axis perpendicular to `m`.
fn cross(m: Axis) Axis {
    return if (m == .x) .y else .x;
}

/// A child's offset within its line's cross band (measured from the line's cross start).
/// `start`/`center`/`end` position the box; `baseline` (rows only) drops the child so its
/// baseline lands on the line's shared baseline (at `max_ascent` from the line top), and on
/// a column falls back to `start`. `stretch` already sized the child to the line in the top-down pass,
/// so it only places it at the line start.
fn cross_within(flow: Flow, m: Axis, line_cross: f32, c: anytype, max_ascent: f32) f32 {
    const cc = extent(c, cross(m));
    return switch (flow.cross) {
        .start, .stretch => 0, // stretch sized the child in the top-down pass; it sits at the line start
        .center => (line_cross - cc) / 2,
        .end => line_cross - cc,
        .baseline => if (flow.dir == .row) max_ascent - (c.size.height - c.size.baseline_off()) else 0,
    };
}

/// Position for a node that anchors *itself* within its parent (an out-of-flow child, or a
/// root against a zero-size parent). Pure function of the box size, the anchor, and the
/// parent extent.
fn set_indep_global_pos(s: Size, anchor: Anchor, pw: f32, ph: f32) struct { f32, f32 } {
    var x: f32 = 0;
    var y: f32 = 0;
    switch (anchor) {
        .top_left => {},
        .top_center => x = pw * 0.5 - s.width * 0.5,
        .top_right => x = pw - s.width,
        .center_left => y = ph * 0.5 - s.height * 0.5,
        .center => {
            x = pw * 0.5 - s.width * 0.5;
            y = ph * 0.5 - s.height * 0.5;
        },
        .center_right => {
            x = pw - s.width;
            y = ph * 0.5 - s.height * 0.5;
        },
        .bottom_left => y = ph - s.height,
        .bottom_center => {
            x = pw * 0.5 - s.width * 0.5;
            y = ph - s.height;
        },
        .bottom_right => {
            x = pw - s.width;
            y = ph - s.height;
        },
        .relative => unreachable,
    }
    return .{ x, y };
}
