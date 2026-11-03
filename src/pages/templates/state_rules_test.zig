//! Control-state looks pinned against reference ternaries. A screenshot shows only the
//! resting state, so each template's named look (`Style` with `on` rules) is resolved here
//! against a control owner whose published bits run through every combination the template can
//! publish: held, hovering, focus (none, a click's focus, visible focus), and the site's
//! `disabled`/`selected`/`checked` facts. Each `old*` function is the reference `if` chain for
//! a template's look, so a resolved colour that differs from it is a pixel that moved. The
//! look tables keyed by a game state (the action tile's, the BUILD row's, the milestone's) are
//! pinned the same way, each state against its reference chain, with the control disabled
//! where the state is not actionable.
//!
//! The scroll thumb's fill is a ternary on `ScrollState.dragging`; the replay tests at the end
//! record why. The thumb sits beside its viewport, not inside it, so on its own a rule on it has
//! no control to read, and nested in an overflowing scroll view the nearest control is the
//! enclosing viewport, held by any press inside it.

const std = @import("std");
const ha = @import("ha");
const uic = ha.ui_client;
const el = uic.elements;
const style = uic.style;
const Style = style.Style;
const Role = style.ThemeRole;
const UiCtx = uic.UiCtx;
const Node = uic.Node;
const El = el.El;
const Color = uic.Color;
const Interaction = UiCtx.Interaction;

const action_tile = @import("./action_tile.zig");
const button = @import("./button.zig");
const capital_row = @import("./capital_row.zig");
const deal_slip = @import("./deal_slip.zig");
const generator_section = @import("./generator_section.zig");
const market_view = @import("./market_view.zig");
const menu_dialog = @import("./menu_dialog.zig");
const menu_list = @import("./menu_list.zig");
const milestone_goal = @import("./milestone_goal.zig");
const paginator = @import("./paginator.zig");
const quantity_stepper = @import("./quantity_stepper.zig");
const rail = @import("./rail.zig");
const research_board = @import("./research_board.zig");
const settings_panel = @import("./settings_panel.zig");
const speed_controls = @import("./speed_controls.zig");
const tabs = @import("./tabs.zig");
const trade_dialog = @import("./trade_dialog.zig");
const table = @import("./table.zig");
const scroll_view = @import("./scroll_view.zig");

// ---- the resolve-level harness ------------------------------------------------------------

/// One state: the template's local facts and the owner's pointer and focus bits.
const Facts = struct {
    enabled: bool = true,
    /// The site's own selection or toggle fact: a chosen row, a pressed chip, a generator that
    /// is on, the active tab or sort column.
    on: bool = false,
    held: bool = false,
    hovering: bool = false,
    focused: bool = false,
    focus_visible: bool = false,
};

/// What the site's `control()` call publishes from its facts.
const Publish = struct {
    /// `.enabled = enabled`, so `disabled == !enabled`. False: the control is always enabled.
    gate: bool = false,
    /// `.selected = on`.
    selected: bool = false,
    /// `.checked = on`.
    checked: bool = false,
    /// The control is always disabled: a tile or row whose game state is not actionable
    /// (`.enabled = false` for every combination of the pointer and focus bits).
    disabled: bool = false,
};

/// The colours a state paints, by role; null where the look leaves the slot unset.
const Want = struct { text: ?Role = null, fill: ?Role = null, outline: ?Role = null, tint: ?Role = null };

/// Which node the template styles: the control's own box, or a label inside it.
const Target = enum { owner, child };

const OldFn = fn (Facts, Interaction) Want;

/// A control owner (marked as `control` marks it) and a label under it, over the default theme,
/// whose ten roles are ten distinct colours.
const Rig = struct {
    res: ha.res.Resources,
    arena: std.heap.ArenaAllocator,
    ctx: UiCtx,
    owner: *Node,
    child: *Node,

    fn setUp(self: *Rig) !void {
        self.res = uic.replay.headlessResources();
        self.res.view.theme = .{};
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        self.ctx = UiCtx.init(&self.res, std.testing.allocator, self.arena.allocator());
        self.owner = try Node.create(self.arena.allocator(), "owner");
        self.owner.render_data.control = true;
        self.child = try Node.create(self.arena.allocator(), "label");
        self.child.parent = self.owner;
    }

    fn tearDown(self: *Rig) void {
        self.ctx.deinit();
        self.arena.deinit();
    }

    /// Seed the owner's bits as the site's `control()` publishes them for `f`, plus the
    /// router's pointer bits, and return the interaction the template would have read.
    fn publish(self: *Rig, p: Publish, f: Facts) Interaction {
        const k = self.owner.key;
        self.ctx.setFlag(k, .disabled, p.disabled or (p.gate and !f.enabled));
        self.ctx.setFlag(k, .selected, p.selected and f.on);
        self.ctx.setFlag(k, .checked, p.checked and f.on);
        self.ctx.setFlag(k, .held, f.held);
        self.ctx.setFlag(k, .hovering, f.hovering);
        self.ctx.setFlag(k, .focused, f.focused);
        self.ctx.setFlag(k, .focus_visible, f.focus_visible);
        return self.ctx.interactionOf(k);
    }

    fn color(self: *Rig, r: ?Role) ?Color {
        return if (r) |role| uic.theme.color(self.res.view.theme, role) else null;
    }

    /// Resolve `look` in every state the site can publish and compare each colour slot with
    /// what `old` picked. Returns the number of states checked.
    fn expectLook(self: *Rig, name: []const u8, look: Style, target: Target, p: Publish, comptime old: OldFn) !usize {
        const node = switch (target) {
            .owner => self.owner,
            .child => self.child,
        };
        var states: usize = 0;
        for ([_]bool{ true, false }) |enabled| {
            if (!enabled and !p.gate) continue;
            for ([_]bool{ false, true }) |on| {
                if (on and !(p.selected or p.checked)) continue;
                for ([_]bool{ false, true }) |held| {
                    for ([_]bool{ false, true }) |hovering| {
                        for (0..3) |focus| {
                            // Focus: none, a click's focus (not visible), keyboard focus (visible).
                            const f = Facts{ .enabled = enabled, .on = on, .held = held, .hovering = hovering, .focused = focus > 0, .focus_visible = focus == 2 };
                            const want = old(f, self.publish(p, f));
                            const got = style.resolve(&self.ctx, node, look);
                            const ok = same(got.text, self.color(want.text)) and
                                same(got.fill, self.color(want.fill)) and
                                same(got.outline_color, self.color(want.outline)) and
                                same(got.tint, self.color(want.tint));
                            if (!ok) {
                                std.debug.print("{s}: {any}\n  want {any}\n  got text={any} fill={any} outline={any} tint={any}\n", .{ name, f, want, got.text, got.fill, got.outline_color, got.tint });
                                return error.LookMovedAPixel;
                            }
                            states += 1;
                        }
                    }
                }
            }
        }
        return states;
    }

    fn same(a: ?Color, b: ?Color) bool {
        if (a == null or b == null) return a == null and b == null;
        return std.meta.eql(a.?, b.?);
    }
};

// ---- the reference ternaries, per template ---------------------------------------------------
// `hot`/`hover_focus` are the predicates the chains call on the interaction `control()`
// returned. Sites whose look is a rule (`.on = hot → acc` beside a ternary rest) read it as
// the rules do: a disabled owner is never hot.

fn OldButton(comptime variant: button.Variant) type {
    return struct {
        // button.zig: `lit = q.hot()`, then
        //   line = if (!enabled) dim else if (lit) (if (danger) danger else acc) else rest_line
        //   text = if (!enabled) dim else if (lit) (if (danger) fg else acc) else rest_text
        const rest: struct { Role, Role } = switch (variant) {
            .primary => .{ .fg, .fg },
            .secondary, .back => .{ .line2, .dim },
            .danger => .{ .danger, .danger },
        };
        fn outline(f: Facts, q: Interaction) Want {
            const lit = q.hot();
            return .{ .outline = if (!f.enabled) .dim else if (lit) (if (variant == .danger) .danger else .acc) else rest[0] };
        }
        fn label(f: Facts, q: Interaction) Want {
            const lit = q.hot();
            return .{ .text = if (!f.enabled) .dim else if (lit) (if (variant == .danger) .fg else .acc) else rest[1] };
        }
    };
}

// deal_slip.zig `action`, market_view.zig PROPOSE (accept = enabled): `lit = enabled and q.hot()`,
//   line = if (!enabled) line else if (lit) acc else fg; ink = if (!enabled) line2 else if (lit) acc else fg
fn oldCtaOutline(f: Facts, q: Interaction) Want {
    const lit = f.enabled and q.hot();
    return .{ .outline = if (!f.enabled) .line else if (lit) .acc else .fg };
}
fn oldCtaLabel(f: Facts, q: Interaction) Want {
    const lit = f.enabled and q.hot();
    return .{ .text = if (!f.enabled) .line2 else if (lit) .acc else .fg };
}

// generator_section.zig mode corner: `.ink = ON good, AUTO fg, OFF dim, .on = hot → acc`.
fn oldGeneratorMode(comptime rest: Role) OldFn {
    return struct {
        fn f(_: Facts, q: Interaction) Want {
            return .{ .text = if (!q.disabled and q.hot()) .acc else rest };
        }
    }.f;
}

// market_view.zig segButton: `hot = q.hover_focus()`,
//   outline = if (pressed) line2 else bg; ink = if (pressed or hot) fg else dim
fn oldSegOutline(f: Facts, _: Interaction) Want {
    return .{ .outline = if (f.on) .line2 else .bg };
}
fn oldSegLabel(f: Facts, q: Interaction) Want {
    return .{ .text = if (f.on or q.hover_focus()) .fg else .dim };
}

// market_view.zig personRow/goodRow: `hot = q.hover_focus()`,
//   fill = if (chosen or hot) panel else bg; outline = if (chosen) line2 else if (hot) panel else bg
fn oldMarketRow(f: Facts, q: Interaction) Want {
    const hot = q.hover_focus();
    return .{ .fill = if (f.on or hot) .panel else .bg, .outline = if (f.on) .line2 else if (hot) .panel else .bg };
}

// market_view.zig goodRow name: `.ink = if (chosen) .acc else .fg`.
fn oldGoodName(f: Facts, _: Interaction) Want {
    return .{ .text = if (f.on) .acc else .fg };
}

// market_view.zig YOUR STALL: `lit = st.stall or sq.hover_focus()`,
//   outline = if (lit) acc else line2; fill = if (st.stall) panel else bg; ink = if (lit) acc else dim
fn oldStallBox(f: Facts, q: Interaction) Want {
    const lit = f.on or q.hover_focus();
    return .{ .outline = if (lit) .acc else .line2, .fill = if (f.on) .panel else .bg };
}
fn oldStallLabel(f: Facts, q: Interaction) Want {
    const lit = f.on or q.hover_focus();
    return .{ .text = if (lit) .acc else .dim };
}

// menu_dialog.zig slotRow: `hot = enabled and q.hover_focus()`,
//   outline = if (hot) line2 else line; fill = if (hot) panel else bg;
//   what = if (enabled) fg else line2; verb = if (enabled) acc else line2
fn oldSlotRow(f: Facts, q: Interaction) Want {
    const hot = f.enabled and q.hover_focus();
    return .{ .outline = if (hot) .line2 else .line, .fill = if (hot) .panel else .bg };
}
fn oldSlotWhat(f: Facts, _: Interaction) Want {
    return .{ .text = if (f.enabled) .fg else .line2 };
}
fn oldSlotVerb(f: Facts, _: Interaction) Want {
    return .{ .text = if (f.enabled) .acc else .line2 };
}

// menu_list.zig: `lit = item.enabled and q.hover_focus()`,
//   mark = if (lit) acc else bg; label = if (!enabled) line2 else if (lit) fg else dim
fn oldMenuMark(f: Facts, q: Interaction) Want {
    const lit = f.enabled and q.hover_focus();
    return .{ .text = if (lit) .acc else .bg };
}
fn oldMenuLabel(f: Facts, q: Interaction) Want {
    const lit = f.enabled and q.hover_focus();
    return .{ .text = if (!f.enabled) .line2 else if (lit) .fg else .dim };
}

// paginator.zig pageButton, quantity_stepper.zig stepButton: `lit = enabled and q.hot()`,
//   outline = if (!enabled) line else if (lit) acc else line2; ink = if (!enabled) line2 else if (lit) acc else fg
fn oldStepOutline(f: Facts, q: Interaction) Want {
    const lit = f.enabled and q.hot();
    return .{ .outline = if (!f.enabled) .line else if (lit) .acc else .line2 };
}
fn oldStepGlyph(f: Facts, q: Interaction) Want {
    const lit = f.enabled and q.hot();
    return .{ .text = if (!f.enabled) .line2 else if (lit) .acc else .fg };
}

// rail.zig: `toggle_color = if (q.hot()) acc else fg`; the chrome is `.fill_ink = .bg` with
// that outline, and the chevrons and restore label are that ink.
fn oldRailChrome(_: Facts, q: Interaction) Want {
    return .{ .fill = .bg, .outline = if (q.hot()) .acc else .fg };
}
fn oldRailInk(_: Facts, q: Interaction) Want {
    return .{ .text = if (q.hot()) .acc else .fg };
}

// research_board.zig viewButton: `hot = enabled and q.hover_focus()`, outline = if (hot) line2 else bg
fn oldViewButtonOutline(f: Facts, q: Interaction) Want {
    const hot = f.enabled and q.hover_focus();
    return .{ .outline = if (hot) .line2 else .bg };
}

// research_board.zig chip: `.ink = if (pressed) .acc else .dim, .on = hover_focus → acc`.
fn oldChip(f: Facts, q: Interaction) Want {
    return .{ .text = if (!q.disabled and q.hover_focus()) .acc else if (f.on) .acc else .dim };
}

// research_board.zig RESEARCH →: `lit = can and bq.hot()`,
//   outline = if (!can) line2 else if (lit) acc else fg; ink = if (!can) dim else if (lit) acc else fg
fn oldResearchOutline(f: Facts, q: Interaction) Want {
    const lit = f.enabled and q.hot();
    return .{ .outline = if (!f.enabled) .line2 else if (lit) .acc else .fg };
}
fn oldResearchLabel(f: Facts, q: Interaction) Want {
    const lit = f.enabled and q.hot();
    return .{ .text = if (!f.enabled) .dim else if (lit) .acc else .fg };
}

// settings_panel.zig choices: `hot = q.hover_focus()`,
//   line = if (on) acc else if (hot) line2 else line; text = if (on) acc else if (hot) fg else dim
fn oldChoiceOutline(f: Facts, q: Interaction) Want {
    return .{ .outline = if (f.on) .acc else if (q.hover_focus()) .line2 else .line };
}
fn oldChoiceLabel(f: Facts, q: Interaction) Want {
    return .{ .text = if (f.on) .acc else if (q.hover_focus()) .fg else .dim };
}

// speed_controls.zig chevron: `.ink = if (enabled) .dim else .line2, .on = hot → acc`.
fn oldChevron(f: Facts, q: Interaction) Want {
    return .{ .text = if (!q.disabled and q.hot()) .acc else if (f.enabled) .dim else .line2 };
}

// tabs.zig: `.ink = if (is_active) .fg else .dim, .on = hot → acc`.
fn oldTab(f: Facts, q: Interaction) Want {
    return .{ .text = if (!q.disabled and q.hot()) .acc else if (f.on) .fg else .dim };
}

// trade_dialog.zig ledgerRow: `hot = q.hover_focus()`,
//   fill = if (chosen or hot) panel else bg; outline = if (chosen) line2 else if (chosen or hot) panel else bg
fn oldLedgerRow(f: Facts, q: Interaction) Want {
    const hot = q.hover_focus();
    return .{ .fill = if (f.on or hot) .panel else .bg, .outline = if (f.on) .line2 else if (f.on or hot) .panel else .bg };
}

// table.zig sort_header_cell: `.ink = if (shown != .none) .fg else .line2, .on = hot → acc`.
fn oldSortLabel(f: Facts, q: Interaction) Want {
    return .{ .text = if (!q.disabled and q.hot()) .acc else if (f.on) .fg else .line2 };
}

// ---- the reference game-state chains -----------------------------------------------------------
// These looks are keyed by a game state (a look table); the chains below pick the same colours
// from the template's facts and the interaction `control()` returned.

fn OldTile(comptime can: bool, comptime running: bool) type {
    return struct {
        // action_tile.zig `tile`: `enabled = !running and can`, `lit = can or running`,
        //   chrome = if (running) fg else if (!enabled) dim else fg
        //   name = if (enabled and q.hot()) acc else chrome; state = if (running) acc else dim
        //   metric, icon tint = if (lit) dim else chrome; yield = if (lit) fg else chrome
        const enabled = !running and can;
        const lit = can or running;
        const chrome: Role = if (running) .fg else if (!enabled) .dim else .fg;
        fn outline(_: Facts, _: Interaction) Want {
            return .{ .outline = chrome };
        }
        fn name(_: Facts, q: Interaction) Want {
            return .{ .text = if (enabled and q.hot()) .acc else chrome };
        }
        fn state(_: Facts, _: Interaction) Want {
            return .{ .text = if (running) .acc else if (!enabled) .dim else .dim };
        }
        fn metric(_: Facts, _: Interaction) Want {
            return .{ .text = if (lit) .dim else chrome };
        }
        fn icon(_: Facts, _: Interaction) Want {
            return .{ .tint = if (lit) .dim else chrome };
        }
        fn yield(_: Facts, _: Interaction) Want {
            return .{ .text = if (lit) .fg else chrome };
        }
    };
}

fn OldCapitalRow(comptime kind: capital_row.Kind) type {
    return struct {
        // capital_row.zig: `lit` is a switch on kind, `.ready => if (ctl.hot()) acc else fg`,
        //   building/reach/busy/locked fg, owned/blocked dim;
        //   faint = if (ready or building) fg else dim; sentence = if (blocked or owned) dim else fg
        fn name(_: Facts, q: Interaction) Want {
            return .{ .text = switch (kind) {
                .ready => if (q.hot()) .acc else .fg,
                .building => .fg,
                .owned, .blocked => .dim,
                .reach, .busy, .locked => .fg,
            } };
        }
        fn ink(_: Facts, _: Interaction) Want {
            return .{ .text = if (kind == .ready or kind == .building) .fg else .dim };
        }
        fn effect(_: Facts, _: Interaction) Want {
            return .{ .text = if (kind == .blocked or kind == .owned) .dim else .fg };
        }
    };
}

fn OldMilestone(comptime state: milestone_goal.Lifecycle) type {
    return struct {
        // milestone_goal.zig: `tone = toneColor(presentationOf(state).tone)`, danger while
        //   locked/unfunded, good while ready/done; readiness `.text = tone`;
        //   action_ink = if (ready) fg else dim, with `.on = hover_focus → acc` on the outline
        //   and the label (the CTA publishes `.enabled = ready`).
        const ready = state == .ready;
        const tone: Role = switch (state) {
            .locked, .unfunded => .danger,
            .ready, .done => .good,
        };
        fn readiness(_: Facts, _: Interaction) Want {
            return .{ .text = tone };
        }
        fn outline(_: Facts, q: Interaction) Want {
            return .{ .outline = if (!q.disabled and q.hover_focus()) .acc else if (ready) .fg else .dim };
        }
        fn label(_: Facts, q: Interaction) Want {
            return .{ .text = if (!q.disabled and q.hover_focus()) .acc else if (ready) .fg else .dim };
        }
    };
}

// ---- the looks -------------------------------------------------------------------------------

test "state rules: every button variant paints what its ternary did, in every state" {
    var rig: Rig = undefined;
    try rig.setUp();
    defer rig.tearDown();
    const gated = Publish{ .gate = true };
    var n: usize = 0;
    inline for (.{ .primary, .secondary, .danger, .back }) |v| {
        const look = button.looks.get(v);
        const Old = OldButton(v);
        n += try rig.expectLook("button " ++ @tagName(v) ++ " outline", look.outline, .owner, gated, Old.outline);
        n += try rig.expectLook("button " ++ @tagName(v) ++ " label", look.label, .child, gated, Old.label);
    }
    try std.testing.expectEqual(@as(usize, 8 * 24), n);
}

test "state rules: calls to action, steppers and page buttons" {
    var rig: Rig = undefined;
    try rig.setUp();
    defer rig.tearDown();
    const gated = Publish{ .gate = true };
    _ = try rig.expectLook("deal_slip action outline", deal_slip.action_outline, .owner, gated, oldCtaOutline);
    _ = try rig.expectLook("deal_slip action label", deal_slip.action_label, .child, gated, oldCtaLabel);
    _ = try rig.expectLook("market PROPOSE outline", market_view.propose_outline, .owner, gated, oldCtaOutline);
    _ = try rig.expectLook("market PROPOSE label", market_view.propose_label, .child, gated, oldCtaLabel);
    _ = try rig.expectLook("paginator outline", paginator.page_outline, .owner, gated, oldStepOutline);
    _ = try rig.expectLook("paginator glyph", paginator.page_glyph, .child, gated, oldStepGlyph);
    _ = try rig.expectLook("stepper outline", quantity_stepper.step_outline, .owner, gated, oldStepOutline);
    _ = try rig.expectLook("stepper glyph", quantity_stepper.step_glyph, .child, gated, oldStepGlyph);
    _ = try rig.expectLook("research action outline", research_board.research_outline, .owner, gated, oldResearchOutline);
    _ = try rig.expectLook("research action label", research_board.research_label, .child, gated, oldResearchLabel);
    _ = try rig.expectLook("research view button outline", research_board.view_button_outline, .owner, gated, oldViewButtonOutline);
    _ = try rig.expectLook("speed chevron", speed_controls.chevron_glyph, .child, gated, oldChevron);
}

test "state rules: rows, menus and the rail" {
    var rig: Rig = undefined;
    try rig.setUp();
    defer rig.tearDown();
    const gated = Publish{ .gate = true };
    const chosen = Publish{ .selected = true };
    _ = try rig.expectLook("market row", market_view.row_look, .owner, chosen, oldMarketRow);
    _ = try rig.expectLook("market good name", market_view.good_name, .child, chosen, oldGoodName);
    _ = try rig.expectLook("market stall box", market_view.stall_outline, .owner, chosen, oldStallBox);
    _ = try rig.expectLook("market stall label", market_view.stall_label, .child, chosen, oldStallLabel);
    _ = try rig.expectLook("trade ledger row", trade_dialog.row_look, .owner, chosen, oldLedgerRow);
    _ = try rig.expectLook("menu slot row", menu_dialog.slot_look, .owner, gated, oldSlotRow);
    _ = try rig.expectLook("menu slot what", menu_dialog.slot_what, .child, gated, oldSlotWhat);
    _ = try rig.expectLook("menu slot verb", menu_dialog.slot_verb, .child, gated, oldSlotVerb);
    _ = try rig.expectLook("menu list mark", menu_list.mark_look, .child, gated, oldMenuMark);
    _ = try rig.expectLook("menu list label", menu_list.label_look, .child, gated, oldMenuLabel);
    _ = try rig.expectLook("rail chrome", rail.toggle_chrome, .owner, .{}, oldRailChrome);
    _ = try rig.expectLook("rail ink", rail.toggle_ink, .child, .{}, oldRailInk);
}

test "state rules: chips, choices, tabs, sort headers and the generator mode corner" {
    var rig: Rig = undefined;
    try rig.setUp();
    defer rig.tearDown();
    const pressed = Publish{ .selected = true, .checked = true };
    _ = try rig.expectLook("market seg outline", market_view.seg_outline, .owner, pressed, oldSegOutline);
    _ = try rig.expectLook("market seg label", market_view.seg_label, .child, pressed, oldSegLabel);
    _ = try rig.expectLook("research chip", research_board.chip_label, .child, pressed, oldChip);
    _ = try rig.expectLook("settings choice outline", settings_panel.choice_outline, .owner, pressed, oldChoiceOutline);
    _ = try rig.expectLook("settings choice label", settings_panel.choice_label, .child, pressed, oldChoiceLabel);
    _ = try rig.expectLook("tab label", tabs.tab_label, .child, .{ .selected = true }, oldTab);
    _ = try rig.expectLook("sort header label", table.sort_label, .child, .{ .selected = true }, oldSortLabel);
    _ = try rig.expectLook("generator mode on", generator_section.mode_inks.get(.on), .child, .{}, oldGeneratorMode(.good));
    _ = try rig.expectLook("generator mode auto", generator_section.mode_inks.get(.auto), .child, .{}, oldGeneratorMode(.fg));
    _ = try rig.expectLook("generator mode off", generator_section.mode_inks.get(.off), .child, .{}, oldGeneratorMode(.dim));
}

test "look tables: every action tile state paints what its chain did, in every state" {
    var rig: Rig = undefined;
    try rig.setUp();
    defer rig.tearDown();
    var n: usize = 0;
    inline for (.{ .{ true, false }, .{ false, false }, .{ true, true }, .{ false, true } }) |c| {
        const can = c[0];
        const running = c[1];
        const Old = OldTile(can, running);
        const look = action_tile.tile_looks.get(action_tile.tileState(can, running));
        // The tile's control publishes `.enabled = !running and can`.
        const p = Publish{ .disabled = !Old.enabled };
        const tag = comptime std.fmt.comptimePrint("tile can={} running={} ", .{ can, running });
        n += try rig.expectLook(tag ++ "outline", look.outline, .owner, p, Old.outline);
        n += try rig.expectLook(tag ++ "name", look.name, .child, p, Old.name);
        n += try rig.expectLook(tag ++ "state", look.state, .child, p, Old.state);
        n += try rig.expectLook(tag ++ "metric", look.metric, .child, p, Old.metric);
        n += try rig.expectLook(tag ++ "icon", look.icon, .child, p, Old.icon);
        n += try rig.expectLook(tag ++ "yield", look.yield, .child, p, Old.yield);
    }
    try std.testing.expectEqual(@as(usize, 4 * 6 * 12), n);
}

test "look tables: every BUILD row kind paints what its chain did, in every state" {
    var rig: Rig = undefined;
    try rig.setUp();
    defer rig.tearDown();
    var n: usize = 0;
    inline for (comptime std.enums.values(capital_row.Kind)) |kind| {
        const Old = OldCapitalRow(kind);
        const look = capital_row.row_looks.get(kind);
        // The row's control publishes `.enabled = kind == .ready`.
        const p = Publish{ .disabled = kind != .ready };
        const tag = "row " ++ @tagName(kind) ++ " ";
        n += try rig.expectLook(tag ++ "name", look.name, .child, p, Old.name);
        n += try rig.expectLook(tag ++ "ink", look.ink, .child, p, Old.ink);
        n += try rig.expectLook(tag ++ "sentence", look.effect, .child, p, Old.effect);
    }
    try std.testing.expectEqual(@as(usize, 7 * 3 * 12), n);
}

test "look tables: every milestone lifecycle paints what its chain did, in every state" {
    var rig: Rig = undefined;
    try rig.setUp();
    defer rig.tearDown();
    var n: usize = 0;
    inline for (comptime std.enums.values(milestone_goal.Lifecycle)) |state| {
        const Old = OldMilestone(state);
        const look = milestone_goal.looks.get(state);
        try std.testing.expectEqual(Old.tone, look.tone);
        // The CTA publishes `.enabled = state == .ready`.
        const p = Publish{ .disabled = state != .ready };
        const tag = "milestone " ++ @tagName(state) ++ " ";
        n += try rig.expectLook(tag ++ "readiness", look.readiness, .child, p, Old.readiness);
        n += try rig.expectLook(tag ++ "cta outline", look.action_outline, .owner, p, Old.outline);
        n += try rig.expectLook(tag ++ "cta label", look.action_label, .child, p, Old.label);
    }
    try std.testing.expectEqual(@as(usize, 4 * 3 * 12), n);
}

// ---- the scroll thumb ------------------------------------------------------------------------

/// The thumb fill a `.held` rule would give: line2, acc while its owner is held.
const held_rule = Style{ .fill_ink = .line2, .on = &.{.{ .when = .held, .fill_ink = .acc }} };

/// A 300x100 scroll view of ten 30px rows, standalone at the origin or nested 40px down in an
/// overflowing 320x200 outer view (a lead spacer, the view, a 300px tail). Each build records
/// what the thumb painted and what a `.held` rule would have resolved to beside it.
const ThumbFixture = struct {
    nested: bool,
    outer_state: uic.UiState.ScrollState = .{},
    state: uic.UiState.ScrollState = .{},
    thumb_key: ?u64 = null,
    outer_viewport_key: ?u64 = null,
    /// The thumb's own published `held` bit.
    held: bool = false,
    painted: ?Color = null,
    /// `held_rule` resolved on the thumb, when it has an owner to read.
    by_rule: ?Color = null,
    /// The control a rule on the thumb reads; null when there is none.
    rule_owner: ?u64 = null,

    fn child(n: *Node, id: []const u8) ?*Node {
        for (n.children.items) |c| if (std.mem.eql(u8, c.id, id)) return c;
        return null;
    }

    pub fn build(self: *ThumbFixture, ctx: *UiCtx) anyerror!uic.Trees {
        const root = try el.root(ctx, "root");
        const frame = (try root.div("frame")).with_layout(.top_left).with_size(.{ .fixed = 320 }, .{ .fixed = 200 });
        var host = frame;
        var outer: ?scroll_view.ScrollView = null;
        if (self.nested) {
            outer = try scroll_view.scroll_view(frame, "outer", .{ .width = 320, .height = 200, .gap = 0, .framed = false }, &self.outer_state);
            host = outer.?.content;
            try host.leaf("lead", .{ .w = .{ .fixed = 320 }, .h = .{ .fixed = 40 } }, .{});
        }
        const sv = try scroll_view.scroll_view(host, "sv", .{ .width = 300, .height = 100, .gap = 0, .framed = false }, &self.state);
        for (0..10) |i| _ = (try sv.content.item("row", i)).with_size(.{ .fixed = 300 }, .{ .fixed = 30 });
        if (outer) |o| {
            try o.content.leaf("tail", .{ .w = .{ .fixed = 320 }, .h = .{ .fixed = 300 } }, .{});
            self.outer_viewport_key = o.viewport.get().key;
        }

        self.thumb_key = null;
        const track = child(sv.outer.get(), "track");
        const thumb = if (track) |t| child(t, "thumb") else null;
        if (thumb) |t| {
            self.thumb_key = t.key;
            self.held = ctx.interactionOf(t.key).held;
            self.painted = t.render_data.fill;
            self.rule_owner = if (style.controlOwner(t)) |o| o.key else null;
            // A rule needs an owner (`resolve` refuses without one), so the comparison exists
            // only where the thumb has a control above it.
            self.by_rule = if (self.rule_owner != null) style.resolve(ctx, t, held_rule).fill else null;
        }
        const out = try ctx.arena.alloc(*Node, 1);
        out[0] = root.get();
        return out;
    }
};

const ThumbRig = struct {
    res: ha.res.Resources,
    arena: std.heap.ArenaAllocator,
    ui: UiCtx,
    driver: uic.FrameDriver,

    fn setUp(self: *ThumbRig) void {
        self.res = uic.replay.headlessResources();
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        self.ui = UiCtx.init(&self.res, std.testing.allocator, self.arena.allocator());
        self.driver = uic.FrameDriver.init(&self.ui, &self.arena, std.testing.io, .none);
    }

    fn tearDown(self: *ThumbRig) void {
        self.ui.deinit();
        self.arena.deinit();
    }

    /// The thumb's centre, from its stamped rect.
    fn thumbAt(self: *ThumbRig, fx: *const ThumbFixture) !struct { x: f32, y: f32 } {
        const r = self.ui.rectOf(fx.thumb_key orelse return error.NoThumb) orelse return error.Unstamped;
        return .{ .x = r.x + r.w / 2, .y = r.y + r.h / 2 };
    }
};

/// The standalone thumb: no control above it, so a rule has nothing to read, while its `held`
/// bit, its `dragging` state and the painted fill agree at every step.
fn expectCoincide(rig: *ThumbRig, fx: *const ThumbFixture, dragging: bool) !void {
    const th = rig.res.view.theme;
    try std.testing.expect(fx.thumb_key != null);
    try std.testing.expectEqual(@as(?u64, null), fx.rule_owner);
    try std.testing.expectEqual(@as(?Color, null), fx.by_rule);
    try std.testing.expectEqual(dragging, fx.state.dragging);
    try std.testing.expectEqual(dragging, fx.held);
    try std.testing.expectEqual(@as(?Color, if (dragging) th.acc else th.line2), fx.painted);
}

test "scroll thumb: held and dragging coincide through press, drag, release, focus loss and cancel" {
    var rig: ThumbRig = undefined;
    rig.setUp();
    defer rig.tearDown();
    var fx = ThumbFixture{ .nested = false };
    var r = uic.Replay.init(&rig.driver, uic.replay.hostOf(ThumbFixture, &fx));
    try r.idle(3);
    try std.testing.expectEqual(@as(?u64, null), fx.rule_owner);
    try expectCoincide(&rig, &fx, false);

    // Press captures the pointer and starts the drag on the same frame the router marks held.
    var at = try rig.thumbAt(&fx);
    try r.frame(&.{.{ .pointer_press = .{ .x = at.x, .y = at.y } }});
    try expectCoincide(&rig, &fx, true);
    try r.idle(1); // held still, no motion
    try expectCoincide(&rig, &fx, true);
    try r.frame(&.{.{ .pointer_move = .{ .x = at.x, .y = at.y + 30 } }});
    try expectCoincide(&rig, &fx, true);
    try std.testing.expect(fx.state.offset > 0);
    // Off the narrow track: the capture keeps the drag, the press latch keeps held.
    try r.frame(&.{.{ .pointer_move = .{ .x = 500, .y = 150 } }});
    try expectCoincide(&rig, &fx, true);
    try r.frame(&.{.{ .pointer_release = .{ .x = 500, .y = 150 } }});
    try expectCoincide(&rig, &fx, false);

    // Window focus loss mid-drag (`Router.windowFocusLost`) ends both.
    at = try rig.thumbAt(&fx);
    try r.frame(&.{.{ .pointer_press = .{ .x = at.x, .y = at.y } }});
    try expectCoincide(&rig, &fx, true);
    try r.frame(&.{.focus_lost});
    try expectCoincide(&rig, &fx, false);
    try r.frame(&.{.focus_gained});
    try expectCoincide(&rig, &fx, false);

    // Platform cancellation (`Router.cancelGesture`) ends both.
    at = try rig.thumbAt(&fx);
    try r.frame(&.{.{ .pointer_press = .{ .x = at.x, .y = at.y } }});
    try expectCoincide(&rig, &fx, true);
    try r.frame(&.{.cancel});
    try expectCoincide(&rig, &fx, false);

    // A press and release inside one frame: the drag begins and ends before the fill is set.
    at = try rig.thumbAt(&fx);
    try r.frame(&.{ .{ .pointer_press = .{ .x = at.x, .y = at.y } }, .{ .pointer_release = .{ .x = at.x, .y = at.y } } });
    try expectCoincide(&rig, &fx, false);
}

test "scroll thumb: nested in an overflowing view, a rule on the thumb reads the outer viewport" {
    var rig: ThumbRig = undefined;
    rig.setUp();
    defer rig.tearDown();
    const th = rig.res.view.theme;
    var fx = ThumbFixture{ .nested = true };
    var r = uic.Replay.init(&rig.driver, uic.replay.hostOf(ThumbFixture, &fx));
    try r.idle(4);
    try std.testing.expect(fx.outer_viewport_key != null);
    try std.testing.expectEqual(fx.outer_viewport_key, fx.rule_owner);

    // Dragging the inner thumb: its own held bit and the drag agree and it paints acc. The
    // engine bubbles `held` to stamped ancestors, so the outer viewport is held too and the rule
    // agrees here.
    var at = try rig.thumbAt(&fx);
    try r.frame(&.{.{ .pointer_press = .{ .x = at.x, .y = at.y } }});
    try std.testing.expect(fx.state.dragging and fx.held);
    try std.testing.expectEqual(@as(?Color, th.acc), fx.painted);
    try std.testing.expectEqual(fx.painted, fx.by_rule);
    try r.frame(&.{.{ .pointer_release = .{ .x = at.x, .y = at.y } }});
    try std.testing.expectEqual(fx.painted, fx.by_rule);

    // They diverge on any press elsewhere in the outer view: on its own content, or on a row of
    // the inner view, the outer viewport is held and the rule would light a thumb that is not
    // dragging.
    at = try rig.thumbAt(&fx);
    for ([_][2]f32{ .{ 100, 20 }, .{ 100, at.y } }) |p| {
        try r.frame(&.{.{ .pointer_press = .{ .x = p[0], .y = p[1] } }});
        try std.testing.expect(!fx.state.dragging and !fx.held);
        try std.testing.expectEqual(@as(?Color, th.line2), fx.painted);
        try std.testing.expectEqual(@as(?Color, th.acc), fx.by_rule);
        try r.frame(&.{.{ .pointer_release = .{ .x = p[0], .y = p[1] } }});
    }
}
