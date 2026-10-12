//! `control` — the one host-side control lifecycle. Every ordinary control used to repeat
//! the same ritual by hand: register focus, query, consume a disabled click, request focus on
//! click, read focus, publish `ControlState`, request the cursor, publish semantics. This is
//! that ritual once, for the node it is handed (`El.control`). The caller keeps only what is
//! genuinely its own: the enabled gate, the accessible name and role, and the chrome it
//! paints from the result.
//!
//! The result is the node's interaction read **after** publication, so `focused`,
//! `focus_visible`, `disabled`, `selected` and `checked` are the published bits — the same
//! ones the `style.btn_*` fragments read off the node — and `clicked` is already false for a
//! disabled control. Pointer and keyboard activation share `.clicked`: Enter/Space on the
//! focused control mark the same flag a pointer release does. Nested consumption
//! (`El.consume`) stays with the caller, since only it knows which descendant is the
//! sub-action; ancestor hover is preserved either way.

const cb = @import("./ctx_binding.zig");
const semantics = @import("./semantics.zig");
const cursor = @import("./cursor.zig");

const UiCtx = cb.UiCtx;
const Node = cb.Node;

pub const Options = struct {
    /// The caller's domain gate. A disabled control is not focusable, consumes a stray click so
    /// it neither reports nor bubbles, publishes `disabled`, and asks for the not-allowed cursor.
    enabled: bool = true,
    /// The accessible name. A text control passes its label; an icon or glyph control passes
    /// what it does, because a glyph is not a string.
    name: []const u8,
    role: semantics.Role,
    /// Single-selection membership (a tab, a chosen offer row), published as `selected`.
    selected: bool = false,
    /// A two-state toggle's fact, published as `checked`.
    checked: bool = false,
    /// A disclosure's or popup owner's open state, published as `expanded`.
    expanded: bool = false,
    /// A spoken value beside the name: a progress readout, a field's text, a slider's reading.
    value: ?[]const u8 = null,
    /// Stable keys of nested controls this one owns (a build row's cancel corner), exposed by
    /// the bridge as children rather than flattened.
    controls: []const u64 = &.{},
    /// Register under this roving-focus group instead of the global Tab order (a tab in its
    /// strip); also published as the member's `described_by` relation.
    roving_group: ?u64 = null,
    /// Focus registration when it differs from `enabled`: a running action tile stays in
    /// traversal only while it already holds focus. Null means `enabled`.
    focusable: ?bool = null,
    /// The hover cursor while enabled. Disabled always shows not-allowed.
    cursor: cursor.Kind = .pointer,
    /// Live-region policy of the published node (a refused edit announces assertively).
    live: semantics.LiveRegion = .off,
};

/// Run the lifecycle on `node` and return its published interaction.
pub fn control(ctx: *UiCtx, node: *Node, opts: Options) UiCtx.Interaction {
    const key = node.key;
    const focusable = opts.focusable orelse opts.enabled;
    if (opts.roving_group) |group| {
        ctx.registerRovingFocus(group, key, focusable);
    } else {
        ctx.registerFocus(key, focusable);
    }

    const q = node.query(ctx);
    // A disabled control cannot activate. Its click is consumed here, so it neither
    // reports to the caller nor bubbles to an ancestor control.
    if (q.clicked and !opts.enabled) _ = ctx.consumeFlag(key, .clicked);
    if (q.clicked and opts.enabled) _ = ctx.requestFocus(key);
    const focused = ctx.isFocused(key);

    // Publish every semantic bit from its owner each build, including false, so a key can
    // never retain stale state across a change of facts. Desktop policy keeps every focused
    // control visibly outlined, so `focus_visible` follows `focused`.
    cb.publishControlState(ctx, key, .{
        .disabled = !opts.enabled,
        .focused = focused,
        .focus_visible = focused,
        .selected = opts.selected,
        .checked = opts.checked,
    });

    // Mirror the same facts into the semantic snapshot, in paint order.
    var sem = semantics.SemanticNode{ .key = key, .role = opts.role };
    _ = sem.setLabel(opts.name);
    if (opts.value) |v| _ = sem.setValue(v);
    sem.state = .{
        .disabled = !opts.enabled,
        .focused = focused,
        .selected = opts.selected,
        .checked = opts.checked,
        .expanded = opts.expanded,
    };
    for (opts.controls) |c| sem.relations.addControls(c);
    if (opts.roving_group) |g| sem.relations.addDescribedBy(g);
    sem.live = opts.live;
    ctx.res.semantics.publish(sem);

    if (q.hovering) ctx.res.cursor.request(if (opts.enabled) opts.cursor else .not_allowed);

    return node.query(ctx);
}

// --- Tests: the lifecycle without a window ---------------------------------------------------
// `control` never touches the platform, so a `Resources` with an undefined platform and a
// default simulation is enough to run it against the real pools, focus registry, semantic
// registry and cursor state.

const std = @import("std");
const testing = std.testing;
const Resources = @import("../res.zig").Resources;

const Rig = struct {
    res: Resources,
    arena: std.heap.ArenaAllocator,
    ctx: UiCtx,

    fn init(self: *Rig) void {
        self.res = .{ .platform = undefined, .sim = .{} };
        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        self.ctx = UiCtx.init(&self.res, testing.allocator, self.arena.allocator());
        self.ctx.beginFrame();
        self.res.semantics.beginBuild();
    }

    fn deinit(self: *Rig) void {
        self.ctx.deinit();
        self.arena.deinit();
    }
};

test "a disabled control consumes its click, publishes disabled, and asks for not-allowed" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const ctx = &rig.ctx;

    const root = try Node.create(ctx.arena, "root");
    const btn = try Node.pcreate(ctx.arena, "btn", root);
    ctx.setFlag(btn.key, .clicked, true);
    ctx.setFlag(btn.key, .hovering, true);

    const q = control(ctx, btn, .{ .enabled = false, .name = "Build", .role = .button });
    try testing.expect(!q.clicked); // consumed: it neither reports nor bubbles
    try testing.expect(!ctx.interactionOf(btn.key).clicked);
    try testing.expect(q.disabled and !q.focused and !q.focus_visible);
    try testing.expect(!ctx.isFocused(btn.key));
    try testing.expectEqual(cursor.Kind.not_allowed, rig.res.cursor.requested);
}

test "an enabled click focuses the control and publishes its state and semantics" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const ctx = &rig.ctx;

    const root = try Node.create(ctx.arena, "root");
    const btn = try Node.pcreate(ctx.arena, "btn", root);
    ctx.setFlag(btn.key, .clicked, true);
    ctx.setFlag(btn.key, .hovering, true);

    const q = control(ctx, btn, .{ .name = "Build", .role = .button, .selected = true, .value = "ready" });
    try testing.expect(q.clicked and q.focused and q.focus_visible and q.selected and !q.disabled);
    try testing.expect(ctx.isFocused(btn.key));
    try testing.expectEqual(cursor.Kind.pointer, rig.res.cursor.requested);

    rig.res.semantics.endBuild();
    var found = false;
    for (rig.res.semantics.snapshot()) |n| {
        if (n.key != btn.key) continue;
        found = true;
        try testing.expectEqual(semantics.Role.button, n.role);
        try testing.expectEqualStrings("Build", n.label.slice());
        try testing.expectEqualStrings("ready", n.value.slice());
        try testing.expect(n.state.selected and n.state.focused and !n.state.disabled);
    }
    try testing.expect(found);
}

test "the focusable override keeps an enabled control out of focus; a roving member focuses" {
    var rig: Rig = undefined;
    rig.init();
    defer rig.deinit();
    const ctx = &rig.ctx;

    const root = try Node.create(ctx.arena, "root");
    const tile = try Node.pcreate(ctx.arena, "tile", root);
    ctx.setFlag(tile.key, .clicked, true);
    const running = control(ctx, tile, .{ .name = "Forage", .role = .tile, .focusable = false });
    try testing.expect(running.clicked and !running.focused);
    try testing.expect(!ctx.isFocused(tile.key));

    const strip = try Node.pcreate(ctx.arena, "strip", root);
    const chip = try Node.pcreate(ctx.arena, "chip", strip);
    ctx.setFlag(chip.key, .clicked, true);
    const member = control(ctx, chip, .{ .name = "BUILD", .role = .radio, .roving_group = strip.key });
    try testing.expect(member.clicked and member.focused);
    try testing.expect(ctx.isFocused(chip.key));
}
