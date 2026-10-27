//! The frame lifecycle, locked as an SDL-free integration test.
//!
//! The host drives the engine in one fixed order per frame (`frame.Driver.step`, which the
//! SDL loop and the headless tests both call):
//!
//!   1. event stage    route pointer edges as they arrive (`route.Router`) against the
//!                     geometry stamped by the PREVIOUS frame; then the frame-level pass
//!                     (`Router.routeFrame`): republish held/dragging/captured, dispatch
//!                     key events as commands, feed text to the focused editor, mark hover
//!   2. beginFrame     engine frame counter, paint-order list and focus build buffer; the
//!                     host cursor/command/semantic registries open their build; the arena
//!                     resets and last frame's tree dies
//!   3. rebuild        a fresh tree through `El`; controls run the host protocol (query,
//!                     focus registration, control-state and semantic publication)
//!   4. layout+stamp   `set_global_pos`, then `stamp_rects` per root in list order, which is
//!                     the frame's paint order
//!   5. draw           the render walk paints the roots in that same order
//!   6. endFrame       prune untouched pool slots, repair focus and pointer capture, clear
//!                     transient flags, swap the command and semantic registries
//!
//! `Harness` runs that order over a headless `Resources` (no window, no font, no renderer).
//! Its positive path is the real loop: pointer and key input go through `route.Router`,
//! and `Harness.frame` is one `frame.Driver.step`. It also exposes the driver's phases one
//! at a time, so a probe can read state between two of them and the negative tests can run
//! one phase out of place and assert the wrong-order outcome. `Scene` is the test's
//! `build_ui`. A reordered host loop fails a named test here instead of silently disabling
//! hit testing.

const std = @import("std");
const ui = @import("ui");
const cb = @import("./ctx_binding.zig");
const el = @import("./elements.zig");
const input = @import("./input.zig");
const frame_mod = @import("./frame.zig");
const route = @import("./route.zig");
const replay = @import("./replay.zig");
const semantics = @import("./semantics.zig");
const Resources = @import("../res.zig").Resources;

const UiCtx = cb.UiCtx;
const Node = cb.Node;
const El = el.El;
const StepState = cb.UiState.StepState;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectEqualStrings = std.testing.expectEqualStrings;

// -- Scene: the test's `build_ui` ------------------------------------------------------

/// Which parts of the fixed scene a frame builds. Every control is a 100×50 box anchored
/// at the root's top-left and displaced along x, so the geometry reads as literal
/// coordinates: `a` covers (0,0)–(100,50), `b` (200,0)–(300,50), `field` (400,0)–(500,50).
const Scene = struct {
    a: bool = true,
    b: bool = true,
    /// A later sibling built over exactly a's box.
    cover: bool = false,
    /// A second root tree whose `popup` child covers b's box and owns Escape.
    popup: bool = false,
    /// The always-built root retains a's hidden `StepState` slot (`retainChildState`).
    retain_a_state: bool = false,
    /// A text field registered as text owner and search target.
    field: bool = false,
    /// a captures the pointer during this build.
    a_captures: bool = false,
};

/// What the builder observed during one rebuild: each control's interaction query, the
/// focus projection it published, and a's pooled step counter.
const Observed = struct {
    a: UiCtx.Interaction = .{},
    b: UiCtx.Interaction = .{},
    cover: UiCtx.Interaction = .{},
    popup: UiCtx.Interaction = .{},
    field: UiCtx.Interaction = .{},
    a_focused: bool = false,
    b_focused: bool = false,
    field_focused: bool = false,
    /// a's `StepState.step` after this build incremented it; 0 when a was not built.
    a_step: usize = 0,
    /// Whether `retainChildState` found a's state slot to keep.
    a_retained: bool = false,
};

const root_key = ui.key(0, "root");
const a_key = ui.key(root_key, "a");
const b_key = ui.key(root_key, "b");
const cover_key = ui.key(root_key, "cover");
const field_key = ui.key(root_key, "field");
const overlay_key = ui.key(0, "overlay");
const popup_key = ui.key(overlay_key, "popup");

const a_rect = ui.Rect{ .x = 0, .y = 0, .w = 100, .h = 50 };
const b_rect = ui.Rect{ .x = 200, .y = 0, .w = 100, .h = 50 };

// -- Harness: the host loop over a headless context -------------------------------------

const Harness = struct {
    res: Resources,
    arena: std.heap.ArenaAllocator,
    ui: UiCtx,
    driver: frame_mod.Driver,
    /// The scene the next build constructs, and what that build observed.
    scene: Scene = .{},
    seen: Observed = .{},
    roots_buf: [2]*Node = undefined,
    roots_len: usize = 0,

    /// Heap-allocated so `&res`, `&ui` and the arena the context and driver hold stay stable.
    fn create() !*Harness {
        const h = try std.testing.allocator.create(Harness);
        h.* = .{
            .res = replay.headlessResources(),
            .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
            .ui = undefined,
            .driver = undefined,
        };
        h.ui = UiCtx.init(&h.res, std.testing.allocator, h.arena.allocator());
        h.driver = frame_mod.Driver.init(&h.ui, &h.arena, std.testing.io, .none);
        return h;
    }

    fn destroy(h: *Harness) void {
        h.ui.deinit();
        h.arena.deinit();
        std.testing.allocator.destroy(h);
    }

    fn router(h: *Harness) *route.Router {
        return &h.driver.router;
    }

    fn roots(h: *Harness) []const *Node {
        return h.roots_buf[0..h.roots_len];
    }

    // Phase 1: the event stage. Pointer edges record into the input model and route through
    // the router as they arrive, exactly as the SDL loop and `replay.Replay.feed` do.

    /// Opens the event stage: the host input model's single reset boundary. Input calls
    /// (`press`, `release`, `click`, `hover`, `pressKey`) follow it in event order.
    fn beginEvents(h: *Harness) void {
        h.res.input.beginFrame();
    }

    fn press(h: *Harness, x: f32, y: f32) void {
        const p = input.Point{ .x = x, .y = y };
        h.res.input.recordButton(.mouse, null, .primary, true, 1, p);
        h.router().pointerPress(.mouse, null, p);
    }

    fn release(h: *Harness, x: f32, y: f32) void {
        const p = input.Point{ .x = x, .y = y };
        h.res.input.recordButton(.mouse, null, .primary, false, 1, p);
        h.router().pointerRelease(.mouse, null, p);
    }

    fn click(h: *Harness, x: f32, y: f32) void {
        h.press(x, y);
        h.release(x, y);
    }

    fn hover(h: *Harness, x: f32, y: f32) void {
        const p = input.Point{ .x = x, .y = y };
        const prev = h.res.input.pointer.position;
        h.res.input.recordMotion(.mouse, null, p, .{ .x = p.x - prev.x, .y = p.y - prev.y });
        h.router().pointerMotion(.mouse, null, p);
    }

    /// A key press recorded into the input model. The router dispatches it as a command in
    /// its frame-level pass (`routeFrame`), at the close of the event stage, so its effect
    /// is observed after the frame rather than returned here.
    fn pressKey(h: *Harness, keycode: replay.Keycode) void {
        h.res.input.recordKey(keycode, .press, .{});
    }

    /// Closes the event stage by hand: the router's frame-level pass. `Driver.step` runs
    /// this itself as its first phase; the by-hand sequences call it before `beginFrame`.
    fn endEvents(h: *Harness) void {
        h.router().routeFrame(&h.res.input);
    }

    // Phases 2, 3, 4 and 6 by hand: the driver's phases, separable so a probe can read state
    // between two of them or run one out of place. The positive path never calls these.

    fn beginFrame(h: *Harness) void {
        h.ui.beginFrame();
        h.res.cursor.beginFrame();
        h.res.commands.beginBuild();
        h.res.semantics.beginBuild();
        _ = h.arena.reset(.retain_capacity);
    }

    fn rebuild(h: *Harness, scene: Scene) !Observed {
        h.scene = scene;
        _ = try h.build(&h.ui);
        return h.seen;
    }

    fn layoutAndStamp(h: *Harness) !void {
        for (h.roots()) |t| try t.set_global_pos(h.ui.arena);
        for (h.roots()) |t| ui.stamp_rects(&h.ui, t);
        h.router().geometryStamped();
    }

    fn endFrame(h: *Harness) void {
        h.ui.endFrame();
        h.res.commands.endBuild();
        h.res.semantics.endBuild();
        h.res.a11y.poll(
            h.res.semantics.snapshot(),
            h.res.semantics.snapshotOverflow(),
            h.res.semantics.snapshotFieldRefused(),
            &h.res.announcements,
        );
    }

    // Phase 5 needs a renderer; `drawOrder` is the sequence the render walk would paint.

    /// The order `draw_tree` paints: roots in list order, each pre-order (`Node.iterate`),
    /// restricted to the nodes that own an interaction slot.
    fn drawOrder(h: *Harness, buf: []u64) []u64 {
        var n: usize = 0;
        for (h.roots()) |root| {
            var it = root.iterate();
            while (it.next()) |node| {
                if (!h.hasSlot(node.key)) continue;
                buf[n] = node.key;
                n += 1;
            }
        }
        return buf[0..n];
    }

    /// The paint order `stamp_rects` published, back to front, as stable keys.
    fn publishedOrder(h: *Harness, buf: []u64) []u64 {
        var n: usize = 0;
        for (h.ui.order.items) |idx| {
            buf[n] = h.ui.interactions.slots.items[idx].key;
            n += 1;
        }
        return buf[0..n];
    }

    // The positive path: the real driver.

    /// One frame through `frame.Driver.step`, after the test has routed this frame's input
    /// between `beginEvents` and this call. The step closes the event stage
    /// (`Router.routeFrame`), begins the frame, builds `scene` through `build`, lays out
    /// and stamps every root, and ends the frame.
    fn frame(h: *Harness, scene: Scene) !Observed {
        h.scene = scene;
        try h.driver.step(replay.hostOf(Harness, h));
        return h.seen;
    }

    /// A whole frame with an empty event stage.
    fn quietFrame(h: *Harness, scene: Scene) !Observed {
        h.beginEvents();
        return h.frame(scene);
    }

    /// The driver's build callback (`replay.hostOf` thunks to it): builds `scene` and
    /// records what the build observed in `seen`. The roots live on the harness, which
    /// outlives the step that iterates them.
    pub fn build(h: *Harness, ui_ctx: *UiCtx) anyerror!frame_mod.Trees {
        std.debug.assert(ui_ctx == &h.ui);
        const scene = h.scene;
        var seen: Observed = .{};
        const root = try el.root(&h.ui, "root");
        h.roots_buf[0] = root.node;
        h.roots_len = 1;

        if (scene.a) {
            const a, seen.a, seen.a_focused = try h.control(root, "a", 0, "a");
            const st = a.node.state(&h.ui, StepState);
            st.step += 1;
            seen.a_step = st.step;
            if (scene.a_captures) _ = h.ui.capturePointer(a.node.key);
        } else if (scene.retain_a_state) {
            seen.a_retained = root.node.retainChildState(&h.ui, "a", StepState);
        }
        if (scene.b) {
            _, seen.b, seen.b_focused = try h.control(root, "b", 200, "b");
        }
        if (scene.cover) {
            _, seen.cover, _ = try h.control(root, "cover", 0, "cover");
        }
        if (scene.field) {
            const f = (try root.div("field"))
                .with_layout(.top_left)
                .with_offset(400, 0)
                .with_size(.{ .fixed = 100 }, .{ .fixed = 50 });
            h.ui.registerFocus(f.node.key, true);
            h.res.commands.registerText(f.node.key, f.node.key, true);
            seen.field = f.query();
            if (seen.field.pressed) _ = h.ui.requestFocus(f.node.key);
            seen.field_focused = h.ui.isFocused(f.node.key);
            cb.publishControlState(&h.ui, f.node.key, .{ .focused = seen.field_focused, .focus_visible = seen.field_focused });
            h.res.semantics.publish(semantics.describeTextInput(f.node.key, "field", "", seen.field_focused, false));
        }
        if (scene.popup) {
            const overlay = try el.root(&h.ui, "overlay");
            h.roots_buf[1] = overlay.node;
            h.roots_len = 2;
            _, seen.popup, _ = try h.control(overlay, "popup", 200, "popup");
            h.res.commands.registerEscape(popup_key);
        }
        h.seen = seen;
        return h.roots_buf[0..h.roots_len];
    }

    /// One control following the host protocol a stock button runs, minus the text.
    fn control(h: *Harness, parent: El, id: []const u8, x: f32, label: []const u8) !struct { El, UiCtx.Interaction, bool } {
        const e = (try parent.div(id))
            .with_layout(.top_left)
            .with_offset(x, 0)
            .with_size(.{ .fixed = 100 }, .{ .fixed = 50 });
        h.ui.registerFocus(e.node.key, true);
        const q = e.query();
        if (q.clicked) _ = h.ui.requestFocus(e.node.key);
        const focused = h.ui.isFocused(e.node.key);
        cb.publishControlState(&h.ui, e.node.key, .{ .focused = focused, .focus_visible = focused });
        h.res.semantics.publish(semantics.describeButton(e.node.key, label, true, focused));
        if (q.hovering) h.res.cursor.request(.pointer);
        return .{ e, q, focused };
    }

    // Non-mutating pool probes. `retainState`/`interactionOf` would touch the slot.

    fn hasSlot(h: *Harness, k: u64) bool {
        return h.ui.interactions.index.contains(k);
    }

    fn hasState(h: *Harness, k: u64, comptime T: type) bool {
        return h.ui.pool(T).index.contains(k);
    }
};

// -- Positive: the invariants each phase boundary carries -------------------------------

test "lifecycle: input routed before the rebuild hits last frame's stamp and the builder sees the click" {
    const h = try Harness.create();
    defer h.destroy();

    // Frame 1. Nothing has ever been stamped, so the event stage has nothing to hit; the
    // builder sees no click even though the pointer is over where a will be laid out.
    h.beginEvents();
    try expectEqual(@as(?u64, null), h.ui.targetAt(50, 25));
    h.click(50, 25);
    const f1 = try h.frame(.{});
    try expect(!f1.a.clicked and !f1.a.pressed and !f1.b.clicked);
    // Frame 1's layout stamped a's geometry; that is what the next event stage reads.
    try expectEqual(a_rect, h.ui.rectOf(a_key).?);
    try expectEqual(b_rect, h.ui.rectOf(b_key).?);

    // Frame 2. The same click lands on a, resolved against frame 1's stamp, and the rebuild
    // observes press, release and click on a alone. Pointer completion requested focus,
    // and the control projected it the same build.
    h.beginEvents();
    h.click(50, 25);
    try expect(h.res.input.pointer.buttons.primary.pressed and h.res.input.pointer.buttons.primary.released);
    const f2 = try h.frame(.{});
    try expect(f2.a.pressed and f2.a.released and f2.a.clicked);
    try expect(!f2.b.pressed and !f2.b.released and !f2.b.clicked);
    try expect(f2.a_focused and !f2.b_focused);
    try expectEqual(@as(?u64, a_key), h.ui.focusedKey());

    // Frame 3, event stage. The transient edges were cleared exactly once, at frame 2's
    // endFrame, so nothing on a is clicked. The focus projection is not transient: it is
    // still readable here, before the build republishes it.
    h.beginEvents();
    try expect(!h.res.input.pointer.buttons.primary.pressed and !h.res.input.pointer.buttons.primary.released);
    const at_event_stage = h.ui.interactionOf(a_key);
    try expect(!at_event_stage.clicked and !at_event_stage.pressed and !at_event_stage.released);
    try expect(at_event_stage.focused and at_event_stage.focus_visible);
    const f3 = try h.frame(.{});
    try expect(!f3.a.clicked and !f3.a.pressed and !f3.a.released);
    try expect(f3.a_focused);
}

test "lifecycle: stamp_rects publishes the draw walk's order and a later sibling occludes an earlier one" {
    const h = try Harness.create();
    defer h.destroy();
    const scene = Scene{ .cover = true, .popup = true };

    // Frame 1 builds a, b, a later sibling over a, and a second root whose popup covers b.
    _ = try h.quietFrame(scene);
    var draw_buf: [8]u64 = undefined;
    var pub_buf: [8]u64 = undefined;
    try expectEqualSlices(u64, &.{ a_key, b_key, cover_key, popup_key }, h.publishedOrder(&pub_buf));
    try expectEqualSlices(u64, h.drawOrder(&draw_buf), h.publishedOrder(&pub_buf));
    try expectEqual(a_rect, h.ui.rectOf(cover_key).?);
    try expectEqual(b_rect, h.ui.rectOf(popup_key).?);

    // Frame 2. The topmost slot takes the hit: the cover over a, the popup root over b.
    // Covered controls are not double-fired.
    h.beginEvents();
    h.click(50, 25);
    h.click(250, 25);
    const f2 = try h.frame(scene);
    try expect(f2.cover.clicked and !f2.a.clicked);
    try expect(f2.popup.clicked and !f2.b.clicked);

    // Frame 3. The cover and popup are dropped from the build, but this event stage still
    // routes against frame 2's stamp, so the click lands on the cover one more time and a
    // does not see it; the cover's slot then dies at this endFrame.
    h.beginEvents();
    h.click(50, 25);
    try expect(h.ui.interactionOf(cover_key).clicked);
    const f3 = try h.frame(.{});
    try expect(!f3.a.clicked);
    try expect(!h.hasSlot(cover_key) and !h.hasSlot(popup_key));
    try expectEqualSlices(u64, &.{ a_key, b_key }, h.publishedOrder(&pub_buf));

    // Frame 4. Ordinary targeting resumes at the same points.
    h.beginEvents();
    h.click(50, 25);
    h.click(250, 25);
    const f4 = try h.frame(.{});
    try expect(f4.a.clicked and f4.b.clicked);
}

test "lifecycle: endFrame publishes build N's focus order, command owners and semantics for frame N+1" {
    const h = try Harness.create();
    defer h.destroy();
    const scene = Scene{ .field = true, .popup = true };

    // Frame 1, event stage: nothing has been published. Tab, slash and Escape are recorded
    // and dispatched by the router's frame-level pass, but there is no stop, no search
    // owner and no Escape target yet, so focus stays clear; the semantic snapshot is empty.
    h.beginEvents();
    h.pressKey(.tab);
    h.pressKey(.slash);
    h.pressKey(.escape);
    try expectEqual(@as(usize, 0), h.res.semantics.snapshot().len);
    h.endEvents();
    try expectEqual(@as(?u64, null), h.ui.focusedKey());
    h.beginFrame();
    const f1 = try h.rebuild(scene);
    try expect(!f1.a_focused and !f1.field_focused and !f1.popup.dismissed);
    // Mid-build: this build's registrations are not yet effective. Traversal reads the
    // published (empty) order, and the registries still hold the prior publication.
    try expect(!h.ui.moveFocus(.next, true));
    try expect(!h.res.commands.isTextOwner(field_key));
    try expectEqual(@as(?u64, null), h.res.commands.searchTarget());
    try expectEqual(@as(?u64, null), h.res.commands.escapeTarget());
    try expectEqual(@as(?*const semantics.SemanticNode, null), h.res.semantics.find(a_key));
    try h.layoutAndStamp();
    h.endFrame();
    // Published at endFrame: effective for frame 2's event stage, in paint order.
    try expect(h.res.commands.isTextOwner(field_key));
    try expectEqual(@as(?u64, field_key), h.res.commands.searchTarget());
    try expectEqual(@as(?u64, popup_key), h.res.commands.escapeTarget());
    const snap = h.res.semantics.snapshot();
    try expectEqual(@as(usize, 4), snap.len);
    try expectEqualSlices(u64, &.{ a_key, b_key, field_key, popup_key }, &.{ snap[0].key, snap[1].key, snap[2].key, snap[3].key });
    try expectEqualStrings("a", snap[0].labelText());
    try expectEqual(semantics.Role.text_input, snap[2].role);

    // Frame 2, event stage: Tab lands on build 1's first stop; Enter activates it through
    // the same `.clicked` flag a pointer release produces; Escape, with no text owner
    // focused, reaches the popup. All three dispatch inside the step, before the rebuild.
    h.beginEvents();
    h.pressKey(.tab);
    h.pressKey(.return_key);
    h.pressKey(.escape);
    const f2 = try h.frame(scene);
    try expectEqual(@as(?u64, a_key), h.ui.focusedKey());
    try expect(f2.a.clicked and f2.a_focused);
    try expect(f2.popup.dismissed);
    try expect(h.res.semantics.find(a_key).?.state.focused);

    // Frame 3, event stage: slash focuses the registered search owner.
    // Frame 3 drops the popup: with no Escape owner (no open modal) the host's
    // modal-blocked `/` policy lets the search shortcut through. This quiet frame publishes
    // the field-only registries (search owner, no escape target) for frame 4's event stage.
    const field_only = Scene{ .field = true };
    _ = try h.quietFrame(field_only);
    try expectEqual(@as(?u64, field_key), h.res.commands.searchTarget());
    try expectEqual(@as(?u64, null), h.res.commands.escapeTarget());

    // Frame 4, event stage: slash focuses the registered search owner — unblocked now that
    // no modal traps focus.
    h.beginEvents();
    h.pressKey(.slash);
    const f4 = try h.frame(field_only);
    try expectEqual(@as(?u64, field_key), h.ui.focusedKey());
    try expect(f4.field_focused and !f4.a_focused);
    try expect(h.res.semantics.find(field_key).?.state.focused);

    // Frame 5, event stage: Escape while a text owner holds focus is consumed by that
    // owner before any view — focus clears, and with no escape target nothing is dismissed.
    h.beginEvents();
    h.pressKey(.escape);
    const f5 = try h.frame(field_only);
    try expectEqual(@as(?u64, null), h.ui.focusedKey());
    try expect(!f5.field_focused);

    // Frame 6 drops the field. After its endFrame the owners are gone and the snapshot no
    // longer describes them.
    _ = try h.quietFrame(.{});
    try expect(!h.res.commands.isTextOwner(field_key));
    try expectEqual(@as(?u64, null), h.res.commands.searchTarget());
    try expectEqual(@as(?u64, null), h.res.commands.escapeTarget());
    try expectEqual(@as(?*const semantics.SemanticNode, null), h.res.semantics.find(field_key));
    try expectEqual(@as(usize, 2), h.res.semantics.snapshot().len);
    // Frame 7: slash now has no owner to focus.
    h.beginEvents();
    h.pressKey(.slash);
    const f7 = try h.frame(.{});
    try expectEqual(@as(?u64, null), h.ui.focusedKey());
    try expect(!f7.a_focused and !f7.b_focused);
}

test "lifecycle: focus on a vanished key is repaired at endFrame and an orphaned capture is released" {
    const h = try Harness.create();
    defer h.destroy();

    // Frame 1 stamps a and b. Frame 2: a click focuses a, and a captures the pointer.
    _ = try h.quietFrame(.{});
    h.beginEvents();
    h.click(50, 25);
    const f2 = try h.frame(.{ .a_captures = true });
    try expect(f2.a_focused);
    try expectEqual(@as(?u64, a_key), h.ui.focusedKey());
    try expectEqual(@as(?u64, a_key), h.ui.capturedPointerKey());

    // Frame 3, event stage: capture wins before geometry, so hovering over b routes to a.
    h.beginEvents();
    h.hover(250, 25);
    h.endEvents();
    try expect(h.ui.interactionOf(a_key).hovering and h.ui.interactionOf(a_key).captured);
    try expect(!h.ui.interactionOf(b_key).hovering);
    // Frame 3 builds without a. endFrame prunes a's slot, releases the capture it owned,
    // and moves focus to the enabled stop at a's prior ordinal, which is now b.
    h.beginFrame();
    _ = try h.rebuild(.{ .a = false });
    try h.layoutAndStamp();
    h.endFrame();
    try expect(!h.hasSlot(a_key));
    try expectEqual(@as(?u64, null), h.ui.capturedPointerKey());
    try expectEqual(@as(?u64, b_key), h.ui.focusedKey());

    // Frame 4: ordinary targeting resumes and b projects the repaired focus.
    h.beginEvents();
    h.hover(250, 25);
    const f4 = try h.frame(.{ .a = false });
    try expect(f4.b.hovering and f4.b_focused);

    // Frame 5: nothing focusable is built, so focus clears.
    _ = try h.quietFrame(.{ .a = false, .b = false });
    try expectEqual(@as(?u64, null), h.ui.focusedKey());
}

test "lifecycle: endFrame prunes what the build did not touch; retainState keeps hidden state one frame at a time" {
    const h = try Harness.create();
    defer h.destroy();

    // Frame 1: a owns a fresh state slot (step 1) and an interaction slot.
    const f1 = try h.quietFrame(.{});
    try expectEqual(@as(usize, 1), f1.a_step);
    try expect(h.hasState(a_key, StepState) and h.hasSlot(a_key));

    // Frame 2 hides a and nothing retains it. Both slots are still owned through the
    // build and die at this endFrame, taking the stamped geometry with them.
    h.beginEvents();
    h.endEvents();
    h.beginFrame();
    _ = try h.rebuild(.{ .a = false });
    try expect(h.hasState(a_key, StepState) and h.hasSlot(a_key));
    try h.layoutAndStamp();
    h.endFrame();
    try expect(!h.hasState(a_key, StepState) and !h.hasSlot(a_key));
    try expectEqual(@as(?ui.Rect, null), h.ui.rectOf(a_key));

    // Frame 3: a returns with a fresh slot.
    const f3 = try h.quietFrame(.{});
    try expectEqual(@as(usize, 1), f3.a_step);

    // Frame 4 hides a, but the always-built root retains the state slot. The state
    // survives; the interaction slot does not, because retention is state-only.
    const f4 = try h.quietFrame(.{ .a = false, .retain_a_state = true });
    try expect(f4.a_retained);
    try expect(h.hasState(a_key, StepState));
    try expect(!h.hasSlot(a_key));

    // Frame 5: a returns and continues from the retained value.
    const f5 = try h.quietFrame(.{});
    try expectEqual(@as(usize, 2), f5.a_step);

    // Frame 6 retains; frame 7 stops retaining, and the slot is pruned at its endFrame.
    _ = try h.quietFrame(.{ .a = false, .retain_a_state = true });
    try expect(h.hasState(a_key, StepState));
    const f7 = try h.quietFrame(.{ .a = false });
    try expect(!f7.a_retained);
    try expect(!h.hasState(a_key, StepState));

    // Frame 8: fresh again; retaining a slot that never existed finds nothing.
    const f8 = try h.quietFrame(.{});
    try expectEqual(@as(usize, 1), f8.a_step);
}

// -- Negative: one phase out of place, and the outcome the order prevents -----------------
// These sequence the driver's phases by hand on purpose: a sealed `Driver.step` cannot be
// misordered, and the point is to show what each misplacement costs.

test "misordered: beginFrame ahead of routing drops the paint order, so a stamped control takes no hit" {
    const h = try Harness.create();
    defer h.destroy();

    _ = try h.quietFrame(.{});

    // Frame 2. Misplaced phase: beginFrame runs BEFORE the event stage routes the press.
    // beginFrame clears the paint-order list that `markTarget` walks, so even though a's
    // slot still carries its stamped rect, the press finds no target and the builder sees
    // no click. This is the silent hit-testing failure the order exists to prevent.
    h.beginEvents();
    h.endEvents();
    h.beginFrame();
    try expectEqual(a_rect, h.ui.rectOf(a_key).?);
    try expectEqual(@as(?u64, null), h.ui.targetAt(50, 25));
    h.click(50, 25);
    const f2 = try h.rebuild(.{});
    try expect(!f2.a.clicked and !f2.a.pressed);
    try h.layoutAndStamp();
    h.endFrame();

    // Frame 3 in the correct order: the same click hits a.
    h.beginEvents();
    h.click(50, 25);
    const f3 = try h.frame(.{});
    try expect(f3.a.clicked);
}

test "misordered: routing after the rebuild finds no target on the first frame, and stamping before layout publishes nothing" {
    const h = try Harness.create();
    defer h.destroy();

    // Frame 1. Misplaced phase: the press is routed AFTER the rebuild and before layout
    // and stamp. On the first frame nothing has been stamped yet, so there is no target,
    // and a's slot (created by its query this build) carries no geometry to hit.
    h.beginEvents();
    h.endEvents();
    h.beginFrame();
    _ = try h.rebuild(.{});
    try expect(h.hasSlot(a_key));
    try expectEqual(@as(?ui.Rect, null), h.ui.rectOf(a_key));
    try expectEqual(@as(?u64, null), h.ui.targetAt(50, 25));
    h.click(50, 25);
    try expect(!h.ui.interactionOf(a_key).clicked);
    try h.layoutAndStamp();
    h.endFrame();

    // Frame 2. Misplaced phase: `stamp_rects` runs BEFORE `set_global_pos`. No node has a
    // resolved position yet, so nothing is stamped. a's slot still carries frame 1's rect,
    // but the paint order the router walks is empty, so the next event stage has nothing
    // to hit: the geometry channel alone never makes a node hittable.
    h.beginEvents();
    h.endEvents();
    h.beginFrame();
    _ = try h.rebuild(.{});
    for (h.roots()) |t| ui.stamp_rects(&h.ui, t);
    try expectEqual(@as(usize, 0), h.ui.order.items.len);
    try expectEqual(a_rect, h.ui.rectOf(a_key).?);
    for (h.roots()) |t| try t.set_global_pos(h.ui.arena);
    h.endFrame();
    h.beginEvents();
    try expectEqual(@as(?u64, null), h.ui.targetAt(50, 25));
    h.click(50, 25);
    const f3 = try h.frame(.{});
    try expect(!f3.a.clicked);

    // Frame 4 in the correct order: frame 3 stamped after layout, so the click hits a.
    h.beginEvents();
    h.click(50, 25);
    const f4 = try h.frame(.{});
    try expect(f4.a.clicked);
}

test "misordered: clearing transient flags before the rebuild erases the click the builder needs" {
    const h = try Harness.create();
    defer h.destroy();

    _ = try h.quietFrame(.{});

    // Frame 2. The press is routed correctly and a is clicked at the event stage. Misplaced
    // phase: endFrame's transient reset runs BEFORE the rebuild, so the flag is gone by the
    // time a's builder queries it. The driver runs `clearTransient` inside endFrame, after
    // the build has read the flags.
    h.beginEvents();
    h.click(50, 25);
    try expect(h.ui.interactionOf(a_key).clicked);
    h.endEvents();
    h.beginFrame();
    h.ui.clearTransient();
    const f2 = try h.rebuild(.{});
    try expect(!f2.a.clicked and !f2.a.pressed and !f2.a.released);
    try h.layoutAndStamp();
    h.endFrame();

    // Frame 3 in the correct order: the click is observed.
    h.beginEvents();
    h.click(50, 25);
    const f3 = try h.frame(.{});
    try expect(f3.a.clicked);
}

test "misordered: pruning before the rebuild drops state the frame still owns" {
    const h = try Harness.create();
    defer h.destroy();

    const f1 = try h.quietFrame(.{});
    try expectEqual(@as(usize, 1), f1.a_step);

    // Frame 2. Misplaced phase: endFrame's prune runs BEFORE the rebuild re-touches last
    // frame's slots. Every slot built in frame 1 is untouched in frame 2 at that moment, so
    // a's state is evicted and the build starts over at step 1 instead of reaching 2.
    h.beginEvents();
    h.endEvents();
    h.beginFrame();
    h.ui.endFrame();
    try expect(!h.hasState(a_key, StepState) and !h.hasSlot(a_key));
    const f2 = try h.rebuild(.{});
    try expectEqual(@as(usize, 1), f2.a_step);
    try h.layoutAndStamp();
    h.endFrame();

    // Frame 3 in the correct order: the slot touched by frame 2's build survives its
    // endFrame and the counter continues.
    const f3 = try h.quietFrame(.{});
    try expectEqual(@as(usize, 2), f3.a_step);
}
