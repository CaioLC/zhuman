//! The host frame driver — the per-frame UI phase sequence as one function that the SDL
//! loop and the headless tests both call:
//!
//! ```text
//! route this frame's recorded input against prior stamped geometry   (Router.routeFrame)
//!         ↓
//! beginFrame · cursor/command/semantic registries open · frame arena reset
//!         ↓
//! build (host-supplied)
//!         ↓
//! layout (profiled per root) · stamp geometry and paint order · geometry fresh
//!         ↓
//! draw (only with a presenting host) · hand the five-pass sample to the host · present
//!         ↓
//! endFrame (prune) · registries publish · accessibility bridge polls
//! ```
//!
//! Per-event pointer routing is *not* here: events route as they arrive, in order, through
//! `Router` — the SDL loop and `replay.zig` both do that before calling `step`. The
//! simulation tick is not here either; it runs between the event stage and `step`, and
//! reads nothing the step mutates.
//!
//! Headless means no `present`: the trees are built, laid out, and stamped — so hit
//! testing, focus, registries, and pools behave exactly as on the desktop — but nothing
//! paints and no renderer is touched.

const std = @import("std");
const ui = @import("ui");
const cb = @import("ctx_binding.zig");
const cursor = @import("cursor.zig");
const draw = @import("draw.zig");
const route = @import("route.zig");
const tree = @import("tree.zig");

pub const UiCtx = cb.UiCtx;
pub const Trees = tree.Trees;
pub const Sample = ui.FrameProfileSample;

/// What the host supplies to one frame. `build` is mandatory; the rest are the desktop
/// loop's platform glue and stay null in a headless run.
pub const Host = struct {
    user: *anyopaque,
    /// Build this frame's root trees into `ui.arena`.
    build: *const fn (user: *anyopaque, ui_ctx: *UiCtx) anyerror!Trees,
    /// Apply the cursor the build requested, right after the build.
    apply_cursor: ?*const fn (user: *anyopaque, kind: cursor.Kind) void = null,
    /// Clear and present around the draw walk. Null skips drawing entirely.
    present: ?Present = null,
    /// Receives each frame's five-pass timing sample together with the context and the
    /// trees it measured, after drawing and before presenting; the host aggregates and
    /// reports as it sees fit.
    sample: ?*const fn (user: *anyopaque, sample: Sample, ui_ctx: *UiCtx, trees: Trees) void = null,
};

pub const Present = struct {
    /// Clear the render target before the trees paint.
    clear: *const fn (user: *anyopaque) anyerror!void,
    /// Present the painted frame.
    show: *const fn (user: *anyopaque) anyerror!void,
};

pub const Driver = struct {
    ui: *UiCtx,
    /// The frame arena behind `ui.arena`; reset once per frame before the build.
    arena: *std.heap.ArenaAllocator,
    router: route.Router,
    /// The host's I/O; its monotonic clock times the five passes.
    io: std.Io,

    pub fn init(ui_ctx: *UiCtx, arena: *std.heap.ArenaAllocator, io: std.Io, platform: route.Platform) Driver {
        return .{ .ui = ui_ctx, .arena = arena, .io = io, .router = route.Router.init(ui_ctx, platform) };
    }

    /// The engine's profiling clock over `io`'s monotonic (`awake`) clock.
    fn awakeClock(self: *const Driver) ui.FrameClock {
        return .{ .ctx = &self.io, .nowFn = ioNow };
    }

    fn ioNow(ctx: *const anyopaque) u64 {
        const io: *const std.Io = @ptrCast(@alignCast(ctx));
        return @intCast(std.Io.Timestamp.now(io.*, .awake).toNanoseconds());
    }

    /// Run one frame. The caller has already reset the input model's edges, recorded this
    /// frame's events, and routed each pointer event through `router`.
    pub fn step(self: *Driver, host: Host) !void {
        const u = self.ui;
        const res = u.res;

        // Event stage, frame-level: visual-state republish, keyboard commands, text, hover.
        self.router.routeFrame(&res.input);

        // Begin: open the frame and every per-build registry; last frame's tree dies here.
        u.beginFrame();
        res.cursor.beginFrame();
        res.commands.beginBuild();
        res.semantics.beginBuild();
        _ = self.arena.reset(.retain_capacity);

        // Build.
        const trees = try host.build(host.user, u);
        if (host.apply_cursor) |apply| apply(host.user, res.cursor.requested);

        // Layout: the solver's three internal passes, profiled per independent root; then
        // stamp every root as one aggregate pass — geometry plus paint order for the next
        // event stage. The normal `set_global_pos` entry remains clock-free.
        var sample: Sample = .{};
        const clock = self.awakeClock();
        for (trees) |t| {
            const layout_sample = try t.set_global_pos_profiled(u.arena, clock);
            sample.add(layout_sample);
        }
        const stamp_start = clock.now();
        for (trees) |t| ui.stamp_rects(u, t);
        sample.stamping = clock.now() -| stamp_start;
        // Geometry is re-stamped at the current size: the resize guard may lift.
        self.router.geometryStamped();

        // Draw: trees in list order, so later ones (overlays) land on top.
        if (host.present) |present| {
            try present.clear(host.user);
            const draw_start = clock.now();
            for (trees) |t| draw.draw_tree(u, t);
            sample.drawing = clock.now() -| draw_start;
        }
        if (host.sample) |emit| emit(host.user, sample, u, trees);
        if (host.present) |present| try present.show(host.user);

        // End: prune pools and slots, repair focus/capture, clear transient flags, then
        // publish the command and semantic registries and let the accessibility bridge
        // consume the just-published snapshot.
        u.endFrame();
        res.commands.endBuild();
        res.semantics.endBuild();
        res.a11y.poll(
            res.semantics.snapshot(),
            res.semantics.snapshotOverflow(),
            res.semantics.snapshotFieldRefused(),
            &res.announcements,
        );
    }
};
