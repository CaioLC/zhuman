//! `milestone_goal` (KIT-20) — the shared anatomy for a run's milestone (Shelter in Act I, the
//! Exchange in Act II): one reusable component both acts fill with their own wording, so a
//! milestone is not a bespoke card per act. The anatomy, left to right / top to bottom:
//!
//!   - a **fixed left semantic bar/wash** whose color is the lifecycle tone (a locked goal is
//!     dim, an unfunded one warns, a ready one accents, a done one reads good);
//!   - a **disclosure** (KIT-11) whose summary row carries the **title**, a **readiness** word,
//!     and a **compact summary**, plus the **primary action** button;
//!   - disclosed **details**: a **kicker**, the **cost**, explanatory **copy**, a **requirement
//!     row**, and the longer **explanation**.
//!
//! **Shared lifecycle** `locked → unfunded → ready → done` is an identity map to a tone and a
//! readiness word (pure, tested); the caller (Shelter/Exchange) supplies the state and all the
//! wording/requirements/terminal copy via the `Goal` descriptor. The component stays **outside**
//! the catalog's recipe filtering/sorting (it is chrome, not a row), and its disclosure uses the
//! already-allocated viewport space (it grows `content`, which the KIT-16 viewport clips/scrolls)
//! rather than growing the fixed terminal.

const std = @import("std");
const ha = @import("ha");

const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const UiCtx = uic.UiCtx;
const El = el.El;
const Color = uic.Color;

const disclosure_mod = @import("./disclosure.zig");

/// The milestone lifecycle (KIT-20). `locked` — prerequisites unmet; `unfunded` — unlocked but
/// not yet affordable; `ready` — buildable now; `done` — achieved (the terminal state).
pub const Lifecycle = enum { locked, unfunded, ready, done };

/// The identity map from lifecycle → semantic tone (the left bar/wash color role) and the
/// readiness word shown in the summary. Pure and tested — one table both acts read.
pub const Presentation = struct { tone: Tone, readiness: []const u8 };
pub const Tone = enum { dim, warn, accent, good };

pub fn presentationOf(state: Lifecycle) Presentation {
    return switch (state) {
        .locked => .{ .tone = .dim, .readiness = "locked" },
        .unfunded => .{ .tone = .warn, .readiness = "not yet" },
        .ready => .{ .tone = .accent, .readiness = "ready" },
        .done => .{ .tone = .good, .readiness = "done" },
    };
}

fn toneColor(ctx: *UiCtx, tone: Tone) Color {
    const th = ctx.res.view.theme;
    return switch (tone) {
        .dim => th.dim,
        .warn => th.warn,
        .accent => th.acc,
        .good => th.good,
    };
}

/// A milestone's wording — everything an act supplies. `title`/`kicker`/`summary`/`copy`/
/// `requirement`/`explanation` are the act's strings; `cost` the formatted cost; `action` the
/// primary-action label; `state` the lifecycle. The component owns none of these — Shelter and
/// Exchange fill them.
pub const Goal = struct {
    state: Lifecycle,
    title: []const u8,
    summary: []const u8,
    kicker: []const u8 = "",
    cost: []const u8 = "",
    copy: []const u8 = "",
    requirement: []const u8 = "",
    explanation: []const u8 = "",
    action: []const u8 = "",
};

/// The built milestone: whether its **primary action** was clicked this frame (the caller acts
/// on it — begins the build / opens the venue).
pub const Milestone = struct { clicked: bool };

/// Build the milestone into `parent`. The primary action is enabled only when `ready`.
pub fn milestone_goal(ctx: *UiCtx, parent: El, id: []const u8, goal: Goal) !Milestone {
    const th = ctx.res.view.theme;
    const pres = presentationOf(goal.state);
    const tone = toneColor(ctx, pres.tone);
    const ready = goal.state == .ready;

    // Outer: a row of [fixed left semantic bar] + [body], with a faint wash of the tone.
    const outer = try el.div(ctx, parent, id);
    _ = outer.with_flow(.{ .dir = .row }).with_size(.{ .pct_of_parent = 1.0 }, .fit_children)
        .with_style(.{ Style{ .outline_color = th.line }, style.solid });

    const bar = try el.div(ctx, outer, "bar"); // the fixed left semantic bar
    _ = bar.with_size(.{ .fixed = 4 }, .{ .pct_of_parent = 1.0 }).with_style(.{Style{ .fill = tone }});

    const bodywrap = try el.div(ctx, outer, "body");
    _ = bodywrap.with_size(.grow, .fit_children).with_flow(.{ .dir = .column }).with_gap(6)
        .with_style(.{style.pad_sym(10, 8)});

    // The disclosure: summary row (title · readiness · compact summary · primary action),
    // details built into its allocated viewport space when open.
    var clicked = false;
    var dbuf: [96]u8 = undefined;
    const sum = std.fmt.bufPrint(&dbuf, "{s}  \u{00B7} {s} \u{00B7} {s}", .{ goal.title, pres.readiness, goal.summary }) catch goal.title;
    const disc = try disclosure_mod.disclosure(ctx, bodywrap, "disc", sum, true);

    // The primary action rides in the summary area — a bordered button enabled only when ready.
    if (goal.action.len > 0) {
        const act = try el.div(ctx, bodywrap, "act");
        ctx.registerFocus(act.get().key, ready);
        const aq = act.query();
        if (aq.clicked and !ready) _ = ctx.consumeFlag(act.get().key, .clicked);
        if (aq.clicked and ready) _ = ctx.requestFocus(act.get().key);
        const afocused = ctx.isFocused(act.get().key);
        if (aq.hovering) ctx.res.cursor.request(if (ready) .pointer else .not_allowed);
        uic.publishControlState(ctx, act.get().key, .{ .disabled = !ready, .focused = afocused, .focus_visible = afocused });
        const s = style.resolve(ctx, act.get(), .{style.btn_primary});
        if (s.outline_color) |c| act.get().render_data.outline = .{ .color = c };
        _ = act.with_flow(.{ .dir = .row }).with_style(.{style.pad_sym(8, 2)});
        _ = (try el.text(ctx, act, "l", goal.action)).with_style(.{style.btn_primary});
        clicked = ready and aq.clicked;
    }

    // Disclosed details: kicker · cost · copy · requirement row · explanation.
    if (disc.details) |d| {
        if (goal.kicker.len > 0)
            _ = (try el.text(ctx, d, "kick", goal.kicker)).with_style(.{ style.eyebrow, Style{ .text = tone } });
        if (goal.cost.len > 0)
            _ = (try el.text(ctx, d, "cost", goal.cost)).with_style(.{ style.body, Style{ .text = th.dim } });
        if (goal.copy.len > 0)
            _ = (try el.text(ctx, d, "copy", goal.copy)).with_style(.{ style.body, Style{ .text = th.fg } });
        if (goal.requirement.len > 0)
            _ = (try el.text(ctx, d, "req", goal.requirement)).with_style(.{ style.small, Style{ .text = th.dim } });
        if (goal.explanation.len > 0)
            _ = (try el.text(ctx, d, "exp", goal.explanation)).with_style(.{ style.small, Style{ .text = th.line2 } });
    }

    return .{ .clicked = clicked };
}

// ============================ Tests (pure identity map) =================================

test "milestone lifecycle identity map: tone + readiness per state" {
    try std.testing.expectEqual(Tone.dim, presentationOf(.locked).tone);
    try std.testing.expectEqualStrings("locked", presentationOf(.locked).readiness);
    try std.testing.expectEqual(Tone.warn, presentationOf(.unfunded).tone);
    try std.testing.expectEqual(Tone.accent, presentationOf(.ready).tone);
    try std.testing.expectEqualStrings("ready", presentationOf(.ready).readiness);
    try std.testing.expectEqual(Tone.good, presentationOf(.done).tone);
    try std.testing.expectEqualStrings("done", presentationOf(.done).readiness);
}
