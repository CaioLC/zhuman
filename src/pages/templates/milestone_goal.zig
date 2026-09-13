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
const Style = style.Style;
const UiCtx = uic.UiCtx;
const El = el.El;
const Color = uic.Color;
const DisclosureState = uic.UiState.DisclosureState;

pub const Lifecycle = enum { locked, unfunded, ready, done };
pub const Tone = enum { danger, good };
pub const Presentation = struct { tone: Tone, readiness: []const u8 };

/// The shared visual state follows the vetted CSS: locked/unfunded use the danger rail/wash;
/// ready/done use the good rail/wash. Callers may provide a more specific readiness phrase.
pub fn presentationOf(state: Lifecycle) Presentation {
    return switch (state) {
        .locked => .{ .tone = .danger, .readiness = "locked" },
        .unfunded => .{ .tone = .danger, .readiness = "inputs short" },
        .ready => .{ .tone = .good, .readiness = "ready" },
        .done => .{ .tone = .good, .readiness = "done" },
    };
}

fn toneColor(ctx: *UiCtx, tone: Tone) Color {
    const th = ctx.res.view.theme;
    return switch (tone) {
        .danger => th.danger,
        .good => th.good,
    };
}

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
pub fn milestone_goal(ctx: *UiCtx, parent: El, id: []const u8, goal: Goal) !Milestone {
    const th = ctx.res.view.theme;
    const pres = presentationOf(goal.state);
    const tone = toneColor(ctx, pres.tone);
    const readiness = if (goal.readiness.len > 0) goal.readiness else pres.readiness;
    const ready = goal.state == .ready;

    const outer = try el.div(ctx, parent, id);
    _ = outer.query(); // keep a stamped geometry slot for the paint-only wash/rail next frame
    _ = outer.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_flow(.{ .dir = .column })
        .with_overflow(.clip);

    // State wash and 2px semantic rail paint behind the in-flow content and do not participate
    // in sizing. Ready/done are 11% good; locked/unfunded are 8% danger, fading at 76%.
    const wash_alpha: u8 = if (pres.tone == .good) 28 else 20;
    const wash = try el.gradient(ctx, outer, "wash", .horizontal, &.{
        .{ .pos = 0, .color = alpha(tone, wash_alpha) },
        .{ .pos = 0.76, .color = alpha(tone, 0) },
        .{ .pos = 1, .color = alpha(tone, 0) },
    }, 1.0);
    _ = wash.with_layout(.top_left).pass_through();
    const state_rail = try el.div(ctx, outer, "state_rail");
    _ = state_rail.with_layout(.top_left)
        .with_style(.{Style{ .fill = tone }})
        .pass_through();
    // Anchored percentage height under a fit-content parent is indefinite in the pure layout
    // pass. Size these paint-only layers from the prior stamped card rect (the established
    // prior-geometry pattern) so they cover the complete collapsed or expanded card.
    if (outer.get().rect(ctx)) |r| {
        _ = wash.with_size_px(.{ .fixed = r.w }, .{ .fixed = r.h });
        _ = state_rail.with_size_px(.{ .fixed = uic.view.dp(2, ctx.res.view.scale) }, .{ .fixed = r.h });
    }

    // Exact bar columns without content-box padding drift:
    // 10px inset | flexible disclosure | 10px | 132px CTA | 5px inset.
    const bar = try el.div(ctx, outer, "bar");
    _ = bar.with_size(.{ .pct_of_parent = 1.0 }, .{ .fixed = bar_h })
        .with_flow(.{ .dir = .row, .cross = .center });
    const lead = try el.div(ctx, bar, "lead");
    _ = lead.with_size(.{ .fixed = bar_left }, .{ .fixed = bar_h }).pass_through();

    const disclosure_lane = try el.div(ctx, bar, "disclosure_lane");
    _ = disclosure_lane.with_size(.grow, .{ .fixed = bar_h })
        .with_flow(.{ .dir = .column, .main = .center });
    const disclosure = try el.div(ctx, disclosure_lane, "disclosure");
    _ = disclosure.with_size(.{ .pct_of_parent = 1.0 }, .{ .fixed = action_h })
        .with_offset(0, bar_control_offset_y)
        .with_style(.{Style{ .fill = th.bg }});
    const disclosure_key = disclosure.get().key;
    const disclosure_state = disclosure.get().state(ctx, DisclosureState);
    ctx.registerFocus(disclosure_key, true);
    const dq = disclosure.query();
    if (dq.clicked) {
        _ = ctx.requestFocus(disclosure_key);
        disclosure_state.expanded = !disclosure_state.expanded;
    }
    if (dq.hovering) ctx.res.cursor.request(.pointer);
    const disclosure_focused = ctx.isFocused(disclosure_key);
    uic.publishControlState(ctx, disclosure_key, .{
        .focused = disclosure_focused,
        .focus_visible = disclosure_focused,
    });
    var disclosure_semantics = uic.semantic.describeButton(disclosure_key, goal.title, true, disclosure_focused);
    disclosure_semantics.state.expanded = disclosure_state.expanded;
    ctx.res.semantics.publish(disclosure_semantics);

    const title_color = if (dq.hovering or disclosure_focused) th.acc else th.fg;
    // Center the complete disclosure composition against the definite 28px control box. If the
    // text leaves sit directly in the fixed-height parent, this engine centers them only within
    // their intrinsic line band; the anchored group gives Shelter, details, and the CTA one
    // shared vertical center while preserving the flexible summary column.
    const disclosure_content = try el.div(ctx, disclosure, "content");
    _ = disclosure_content.with_layout(.center)
        .with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_flow(.{ .dir = .row, .cross = .center })
        .with_gap(summary_gap);
    _ = (try el.text(ctx, disclosure_content, "title", goal.title))
        .with_style(.{Style{ .font = 15, .text = title_color }});
    _ = (try el.text(ctx, disclosure_content, "readiness", readiness))
        .with_style(.{Style{ .font = 9, .text = tone }});

    // The compact column is the only flexible summary field and clips before it can displace
    // the affordance or fixed action button.
    const compact = try el.div(ctx, disclosure_content, "compact");
    _ = compact.with_size(.grow, .fit_children)
        .with_overflow(.clip);
    _ = (try el.text(ctx, compact, "text", goal.summary))
        .with_style(.{Style{ .font = 9, .text = th.dim }});

    const affordance = try el.div(ctx, disclosure_content, "affordance");
    _ = affordance.with_size(.fit_children, .fit_children)
        .with_flow(.{ .dir = .row, .cross = .center })
        .with_gap(ha.tokens.gap.inline_);
    _ = (try el.text(ctx, affordance, "word", if (disclosure_state.expanded) "close" else "details"))
        .with_style(.{Style{ .font = 9, .text = th.dim }});
    _ = (try el.text(ctx, affordance, "arrow", if (disclosure_state.expanded) "\u{2191}" else "\u{2193}"))
        .with_style(.{Style{ .font = 9, .text = th.dim }});

    var clicked = false;
    if (goal.action.len > 0) {
        const gap = try el.div(ctx, bar, "action_gap");
        _ = gap.with_size(.{ .fixed = bar_gap }, .{ .fixed = bar_h }).pass_through();

        const action_lane = try el.div(ctx, bar, "action_lane");
        _ = action_lane.with_size(.{ .fixed = action_w }, .{ .fixed = bar_h })
            .with_flow(.{ .dir = .column, .main = .center });
        const action = try el.div(ctx, action_lane, "action");
        _ = action.with_size(.{ .fixed = action_w }, .{ .fixed = action_h })
            .with_offset(0, bar_control_offset_y);
        const action_key = action.get().key;
        ctx.registerFocus(action_key, ready);
        const aq = action.query();
        if (aq.clicked and !ready) _ = ctx.consumeFlag(action_key, .clicked);
        if (aq.clicked and ready) _ = ctx.requestFocus(action_key);
        if (aq.hovering) ctx.res.cursor.request(if (ready) .pointer else .not_allowed);
        const action_focused = ctx.isFocused(action_key);
        uic.publishControlState(ctx, action_key, .{
            .disabled = !ready,
            .focused = action_focused,
            .focus_visible = action_focused,
        });
        ctx.res.semantics.publish(uic.semantic.describeButton(action_key, goal.action, ready, action_focused));
        const action_color = if (!ready) th.dim else if (aq.hovering or action_focused) th.acc else th.fg;
        _ = action.with_style(.{Style{ .outline_color = action_color }});
        _ = (try el.text(ctx, action, "label", goal.action))
            .with_layout(.center)
            .with_style(.{Style{ .font = 9, .text = action_color }});
        clicked = ready and aq.clicked;
    }
    const tail = try el.div(ctx, bar, "tail");
    _ = tail.with_size(.{ .fixed = bar_right }, .{ .fixed = bar_h }).pass_through();

    if (disclosure_state.expanded) {
        const details = try el.div(ctx, outer, "details");
        _ = details.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
            .with_flow(.{ .dir = .column });
        const divider = try el.div(ctx, details, "divider");
        _ = divider.with_size(.{ .pct_of_parent = 1.0 }, .{ .fixed = 1 })
            .with_style(.{Style{ .fill = th.line }});

        // Horizontal spacer nodes reproduce 12px/10px CSS padding without percentage-width
        // content-box overflow. Vertical padding remains a harmless style inset.
        const detail_row = try el.div(ctx, details, "row");
        _ = detail_row.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
            .with_flow(.{ .dir = .row });
        const detail_lead = try el.div(ctx, detail_row, "lead");
        _ = detail_lead.with_size(.{ .fixed = detail_left }, .{ .fixed = 1 }).pass_through();
        const content = try el.div(ctx, detail_row, "content");
        _ = content.with_size(.grow, .fit_children)
            .with_flow(.{ .dir = .column }).with_gap(4)
            .with_style(.{style.pad_each(6, 0, 8, 0)});
        const detail_tail = try el.div(ctx, detail_row, "tail");
        _ = detail_tail.with_size(.{ .fixed = detail_right }, .{ .fixed = 1 }).pass_through();

        if (goal.kicker.len > 0 or goal.cost.len > 0) {
            const head = try el.div(ctx, content, "head");
            _ = head.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
                .with_flow(.{ .dir = .row, .main = .space_between, .cross = .baseline });
            if (goal.kicker.len > 0) {
                const kicker_color = if (goal.state == .done) th.good else th.acc;
                _ = (try el.text(ctx, head, "kicker", goal.kicker))
                    .with_style(.{Style{ .font = 9, .tracking = 0.08, .text = kicker_color }});
            }
            if (goal.cost.len > 0) {
                _ = (try el.text(ctx, head, "cost", goal.cost))
                    .with_style(.{Style{ .font = 9, .text = th.dim }});
            }
        }

        if (goal.copy.len > 0) {
            _ = (try el.text(ctx, content, "copy", goal.copy))
                .with_wrap(detail_wrap_w)
                .with_style(.{Style{ .font = 10, .text = th.fg }});
        }

        if (goal.requirements.len > 0) {
            const requirements = try el.div(ctx, content, "requirements");
            _ = requirements.with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
                .with_flow(.{ .dir = .row, .wrap = true, .cross = .center })
                .with_gap(13);
            for (goal.requirements, 0..) |requirement, i| {
                const key = try std.fmt.allocPrint(ctx.arena, "r{d}", .{i});
                const token = try el.div(ctx, requirements, key);
                _ = token.with_flow(.{ .dir = .row, .cross = .baseline }).with_gap(4);
                _ = (try el.text(ctx, token, "label", requirement.label))
                    .with_style(.{Style{ .font = 8.5, .text = th.line2 }});
                _ = (try el.text(ctx, token, "value", requirement.value))
                    .with_style(.{Style{ .font = 8.5, .text = if (requirement.met) th.good else th.danger }});
            }
        }

        if (goal.explanation.len > 0) {
            _ = (try el.text(ctx, content, "explanation", goal.explanation))
                .with_style(.{Style{ .font = 9, .text = th.dim }});
        }
    }

    return .{ .clicked = clicked, .expanded = disclosure_state.expanded };
}

test "milestone lifecycle maps to prototype danger/good states" {
    try std.testing.expectEqual(Tone.danger, presentationOf(.locked).tone);
    try std.testing.expectEqualStrings("locked", presentationOf(.locked).readiness);
    try std.testing.expectEqual(Tone.danger, presentationOf(.unfunded).tone);
    try std.testing.expectEqualStrings("inputs short", presentationOf(.unfunded).readiness);
    try std.testing.expectEqual(Tone.good, presentationOf(.ready).tone);
    try std.testing.expectEqualStrings("ready", presentationOf(.ready).readiness);
    try std.testing.expectEqual(Tone.good, presentationOf(.done).tone);
}

test "milestone bar dimensions preserve the audited control insets" {
    try std.testing.expectEqual(@as(f32, 38), bar_h);
    try std.testing.expectEqual(@as(f32, 132), action_w);
    try std.testing.expectEqual(@as(f32, 28), action_h);
    try std.testing.expectEqual(@as(f32, 7), (bar_h - action_h) / 2 + bar_control_offset_y);
    try std.testing.expectEqual(@as(f32, 3), (bar_h - action_h) / 2 - bar_control_offset_y);
    try std.testing.expectEqual(@as(f32, 2), detail_left - bar_left);
}
