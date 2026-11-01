//! `milestone_goal` — the shared collapsible end-of-act card used by Shelter and Exchange.
//!
//! The prototype has two distinct rows, not a generic panel with a sentence and a button:
//! a 38px bar (`title · readiness · compact summary · details/close` + fixed 132×28 CTA),
//! with a 7px top and 3px bottom control inset,
//! followed by an optional full-width details region. A 2px lifecycle rail and a subtle
//! horizontal wash belong to the card itself. This template owns that anatomy while callers
//! supply all act-specific wording, requirements, and lifecycle facts.

const std = @import("std");
const ha = @import("ha");

const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const vd = style.verdict;
const Style = style.Style;
const El = el.El;
const Color = uic.Color;
const DisclosureState = uic.UiState.DisclosureState;

pub const Lifecycle = enum { locked, unfunded, ready, done };
pub const Presentation = struct { readiness: []const u8 };

/// The readiness word each lifecycle shows. Callers may provide a more specific phrase.
pub fn presentationOf(state: Lifecycle) Presentation {
    return switch (state) {
        .locked => .{ .readiness = "locked" },
        .unfunded => .{ .readiness = "inputs short" },
        .ready => .{ .readiness = "ready" },
        .done => .{ .readiness = "done" },
    };
}

/// The inks of one lifecycle: the rail and wash role with the wash's opening alpha, the
/// readiness word, the CTA's outline and label, and the details' kicker.
pub const Look = struct {
    tone: style.ThemeRole,
    wash_alpha: u8,
    readiness: Style,
    action_outline: Style,
    action_label: Style,
    kicker: Style,
};

fn lifecycleLook(comptime tone: style.ThemeRole, comptime ready: bool, comptime done: bool) Look {
    const lift: []const style.Rule = if (ready) &.{.{ .when = .hover_focus, .ink = .acc }} else &.{};
    const outline_lift: []const style.Rule = if (ready) &.{.{ .when = .hover_focus, .outline_ink = .acc }} else &.{};
    const rest: style.ThemeRole = if (ready) .fg else .dim;
    return .{
        .tone = tone,
        .wash_alpha = if (tone == .good) 28 else 20,
        .readiness = .{ .ink = tone },
        .action_outline = .{ .outline_ink = rest, .on = outline_lift },
        .action_label = .{ .ink = rest, .on = lift },
        .kicker = .{ .ink = .acc, .verdict = if (done) .met else null },
    };
}

/// Every lifecycle's inks, following the vetted CSS: locked/unfunded use the danger rail and
/// an 8% wash, ready/done the good rail and an 11% wash. Only a ready card's CTA is an enabled
/// control, and it lifts to accent on hover or focus; the others rest dim. A done card's
/// kicker reads `met`.
pub const looks = std.EnumArray(Lifecycle, Look).init(.{
    .locked = lifecycleLook(.danger, false, false),
    .unfunded = lifecycleLook(.danger, false, false),
    .ready = lifecycleLook(.good, true, false),
    .done = lifecycleLook(.good, false, true),
});

fn alpha(c: Color, a: u8) Color {
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = a };
}

/// One requirement token in the expanded row. Label and value are separate so the value can
/// carry the prototype's red/green met-state cue without coloring the label.
pub const Requirement = struct {
    label: []const u8,
    value: []const u8,
    met: bool = false,
};

pub const Goal = struct {
    state: Lifecycle,
    title: []const u8,
    /// Compact summary shown in the collapsed bar (for example `materials 31/60`).
    summary: []const u8,
    /// Optional state-specific phrase; empty uses `presentationOf(state).readiness`.
    readiness: []const u8 = "",
    kicker: []const u8 = "",
    cost: []const u8 = "",
    copy: []const u8 = "",
    requirements: []const Requirement = &.{},
    explanation: []const u8 = "",
    action: []const u8 = "",
    /// Open (or close) the details on this frame — a fixture's first frame; null leaves the
    /// disclosure to the player.
    expand: ?bool = null,
};

pub const Milestone = struct {
    clicked: bool,
    expanded: bool,
};

// Border-box dimensions and spacing. The 7px/3px vertical split retains the bottom
// breathing room while giving the aligned control group a clearly larger top inset.
const bar_pad_top: f32 = 7;
const bar_pad_bottom: f32 = 3;
const action_h: f32 = 28;
const bar_h: f32 = bar_pad_top + action_h + bar_pad_bottom;
const bar_control_offset_y: f32 = (bar_pad_top - bar_pad_bottom) / 2;
const bar_left: f32 = 12; // 2px state rail + 10px bar padding
const bar_gap: f32 = 10;
const bar_right: f32 = 5;
const action_w: f32 = 132;
const summary_gap: f32 = 9;
const detail_left: f32 = 14; // 2px state rail + 12px detail padding
const detail_right: f32 = 10;
const detail_wrap_w: f32 = 560;

/// Build one Shelter/Exchange milestone. The disclosure row and CTA are separate hit targets;
/// only a `.ready` CTA reports `clicked`.
pub fn milestone_goal(parent: El, id: []const u8, goal: Goal) !Milestone {
    const ctx = parent.ctx;
    const pres = presentationOf(goal.state);
    const look = looks.get(goal.state);
    const tone = style.roleColor(ctx, look.tone);
    const readiness = if (goal.readiness.len > 0) goal.readiness else pres.readiness;
    const ready = goal.state == .ready;

    const outer = try parent.box(id, .{
        .w = .{ .pct_of_parent = 1.0 }, .h = .fit_children, .flow = .{ .dir = .column }, .overflow = .clip,
    }, .{});

    // State wash and 2px semantic rail paint behind the in-flow content and do not participate
    // in sizing. The wash opens at the look's alpha and fades out at 76%.
    // Anchored, they take percentages of the card's final (fitted) size, so they cover the
    // collapsed or expanded card in the frame it changes.
    const wash = try outer.gradient("wash", .horizontal, &.{
        .{ .pos = 0, .color = alpha(tone, look.wash_alpha) },
        .{ .pos = 0.76, .color = alpha(tone, 0) },
        .{ .pos = 1, .color = alpha(tone, 0) },
    }, 1.0);
    wash.set(.{ .anchor = .top_left, .w = .{ .pct_of_parent = 1.0 }, .h = .{ .pct_of_parent = 1.0 } }, .{});
    try outer.leaf("state_rail", .{ .anchor = .top_left, .w = .{ .fixed = 2 }, .h = .{ .pct_of_parent = 1.0 } }, .{Style{ .fill = tone }});

    // Bar columns: 12px inset (2px rail + 10px) | flexible disclosure | 10px | 132px CTA |
    // 5px inset. The insets are padding, which the percentage width (a border box) takes out
    // of the card's width; the 10px is the CTA lane's leading margin.
    const bar = try outer.box("bar", .{
        .w = .{ .pct_of_parent = 1.0 }, .h = .{ .fixed = bar_h }, .flow = .{ .dir = .row, .cross = .center },
    }, .{style.pad_each(0, bar_right, 0, bar_left)});

    const disclosure_lane = try bar.box("disclosure_lane", .{
        .w = .grow, .h = .{ .fixed = bar_h }, .flow = .{ .dir = .column, .main = .center },
    }, .{});
    const disclosure = try disclosure_lane.box("disclosure", .{
        .w = .{ .pct_of_parent = 1.0 }, .h = .{ .fixed = action_h }, .offset = .{ .y = bar_control_offset_y },
    }, .{Style{ .fill_ink = .bg }});
    const disclosure_state = disclosure.state(DisclosureState);
    if (goal.expand) |x| disclosure_state.expanded = x;
    // Flip on the click before the lifecycle publishes `expanded`, so it is current this frame.
    if (disclosure.query().clicked) disclosure_state.expanded = !disclosure_state.expanded;
    _ = disclosure.control(.{ .name = goal.title, .role = .button, .expanded = disclosure_state.expanded, .ring = false });

    // Center the complete disclosure composition against the definite 28px control box. If the
    // text leaves sit directly in the fixed-height parent, this engine centers them only within
    // their intrinsic line band; the anchored group gives Shelter, details, and the CTA one
    // shared vertical center while preserving the flexible summary column.
    const disclosure_content = try disclosure.box("content", .{
        .anchor = .center, .w = .{ .pct_of_parent = 1.0 }, .h = .fit_children,
        .flow = .{ .dir = .row, .cross = .center }, .gap = summary_gap,
    }, .{});
    try disclosure_content.label("title", goal.title, .{Style{ .font = 15, .ink = .fg, .on = &.{.{ .when = .hover_focus, .ink = .acc }} }});
    try disclosure_content.label("readiness", readiness, .{ Style{ .font = 9 }, look.readiness });

    // The compact column is the only flexible summary field and clips before it can displace
    // the affordance or fixed action button.
    const compact = try disclosure_content.box("compact", .{ .w = .grow, .h = .fit_children, .overflow = .clip }, .{});
    try compact.label("text", goal.summary, .{style.fine_print});

    const affordance = try disclosure_content.box("affordance", .{
        .w = .fit_children, .h = .fit_children, .flow = .{ .dir = .row, .cross = .center },
        .gap = ha.tokens.gap.inline_,
    }, .{});
    try affordance.label("word", if (disclosure_state.expanded) "close" else "details", .{style.fine_print});
    try affordance.label("arrow", if (disclosure_state.expanded) "\u{2191}" else "\u{2193}", .{style.fine_print});

    var clicked = false;
    if (goal.action.len > 0) {
        const action_lane = try bar.box("action_lane", .{
            .w = .{ .fixed = action_w }, .h = .{ .fixed = bar_h },
            .flow = .{ .dir = .column, .main = .center }, .margin = .{ .before = bar_gap },
        }, .{});
        const action = try action_lane.box("action", .{
            .w = .{ .fixed = action_w }, .h = .{ .fixed = action_h },
            .offset = .{ .y = bar_control_offset_y },
        }, .{});
        const aq = action.control(.{ .enabled = ready, .name = goal.action, .role = .button, .ring = false });
        // The lifecycle's CTA look: only a ready card's lifts; a disabled one rests dim.
        action.set(.{}, .{look.action_outline});
        (try action.text("label", goal.action)).set(.{
            .anchor = .center,
        }, .{ Style{ .font = 9 }, look.action_label });
        clicked = ready and aq.clicked;
    }

    if (disclosure_state.expanded) {
        const details = try outer.box("details", .{ .w = .{ .pct_of_parent = 1.0 }, .h = .fit_children, .flow = .{ .dir = .column } }, .{});
        try details.leaf("divider", .{ .w = .{ .pct_of_parent = 1.0 }, .h = .{ .fixed = 1 } }, .{style.rule_fill});

        // The row's padding is the 14px (2px rail + 12px) / 10px CSS inset; its percentage
        // width is a border box, so the padding comes out of the card's width.
        const detail_row = try details.box("row", .{
            .w = .{ .pct_of_parent = 1.0 }, .h = .fit_children, .flow = .{ .dir = .row },
        }, .{style.pad_each(0, detail_right, 0, detail_left)});
        const content = try detail_row.box("content", .{
            .w = .grow, .h = .fit_children, .flow = .{ .dir = .column }, .gap = 4,
        }, .{style.pad_each(6, 0, 8, 0)});

        if (goal.kicker.len > 0 or goal.cost.len > 0) {
            const head = try content.box("head", .{
                .w = .{ .pct_of_parent = 1.0 }, .h = .fit_children,
                .flow = .{ .dir = .row, .main = .space_between, .cross = .baseline },
            }, .{});
            if (goal.kicker.len > 0) {
                try head.label("kicker", goal.kicker, .{ Style{ .font = 9, .tracking = 0.08 }, look.kicker });
            }
            if (goal.cost.len > 0) {
                try head.label("cost", goal.cost, .{style.fine_print});
            }
        }

        if (goal.copy.len > 0) {
            try content.label_fit("copy", goal.copy, .{ .wrap = detail_wrap_w }, .{Style{ .font = 10, .ink = .fg }});
        }

        if (goal.requirements.len > 0) {
            const requirements = try content.box("requirements", .{
                .w = .{ .pct_of_parent = 1.0 }, .h = .fit_children,
                .flow = .{ .dir = .row, .wrap = true, .cross = .center }, .gap = 13,
            }, .{});
            for (goal.requirements, 0..) |requirement, i| {
                const token = try requirements.boxi("r", i, .{ .flow = .{ .dir = .row, .cross = .baseline }, .gap = 4 }, .{});
                try token.label("label", requirement.label, .{Style{ .font = 8.5, .ink = .line2 }});
                try token.label("value", requirement.value, .{Style{ .font = 8.5, .verdict = vd.of(requirement.met, .met, .unmet) }});
            }
        }

        if (goal.explanation.len > 0) {
            try content.label("explanation", goal.explanation, .{style.fine_print});
        }
    }

    return .{ .clicked = clicked, .expanded = disclosure_state.expanded };
}

test "milestone lifecycle readiness words" {
    try std.testing.expectEqualStrings("locked", presentationOf(.locked).readiness);
    try std.testing.expectEqualStrings("inputs short", presentationOf(.unfunded).readiness);
    try std.testing.expectEqualStrings("ready", presentationOf(.ready).readiness);
    try std.testing.expectEqualStrings("done", presentationOf(.done).readiness);
}

test "milestone looks pin every lifecycle's inks" {
    const R = style.ThemeRole;
    const x = std.testing.expectEqual;
    // tone, wash alpha, CTA rest, kicker verdict
    const Row = struct { Lifecycle, R, u8, R, ?style.Verdict };
    const want = [_]Row{
        .{ .locked, .danger, 20, .dim, null },
        .{ .unfunded, .danger, 20, .dim, null },
        .{ .ready, .good, 28, .fg, null },
        .{ .done, .good, 28, .dim, .met },
    };
    for (want) |w| {
        const l = looks.get(w[0]);
        try x(w[1], l.tone);
        try x(w[2], l.wash_alpha);
        try x(w[1], l.readiness.ink.?);
        try x(w[3], l.action_outline.outline_ink.?);
        try x(w[3], l.action_label.ink.?);
        try x(R.acc, l.kicker.ink.?);
        try x(w[4], l.kicker.verdict);
        try x(@as(usize, 0), l.readiness.on.len);
        try x(@as(usize, 0), l.kicker.on.len);
        // Only the ready CTA carries rules: hover or focus lifts its outline and label to acc.
        const n: usize = if (w[0] == .ready) 1 else 0;
        try x(n, l.action_outline.on.len);
        try x(n, l.action_label.on.len);
        if (n == 1) {
            try x(style.When.hover_focus, l.action_outline.on[0].when);
            try x(R.acc, l.action_outline.on[0].outline_ink.?);
            try x(style.When.hover_focus, l.action_label.on[0].when);
            try x(R.acc, l.action_label.on[0].ink.?);
        }
    }
}

test "milestone bar dimensions preserve the audited control insets" {
    try std.testing.expectEqual(@as(f32, 38), bar_h);
    try std.testing.expectEqual(@as(f32, 132), action_w);
    try std.testing.expectEqual(@as(f32, 28), action_h);
    try std.testing.expectEqual(@as(f32, 7), (bar_h - action_h) / 2 + bar_control_offset_y);
    try std.testing.expectEqual(@as(f32, 3), (bar_h - action_h) / 2 - bar_control_offset_y);
    try std.testing.expectEqual(@as(f32, 2), detail_left - bar_left);
}
