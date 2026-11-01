//! `act_page` — the skeleton every playable act page shares: the responsive shell (header,
//! body, optional rail, the framed log footer), the HUD header (stockline + runline with the
//! day), the live event log, and the page's roots in draw order. Two phases, because a page
//! reads its stocks and builds its body in between:
//!
//!   const page = try act_page(ctx, .{ .id = "play", .act = .act_one });
//!   // ... build into page.regions.body / page.regions.rail, collect stocks ...
//!   return page.finish(.{ .stocks = &stocks, .act_label = "Act I", .overlay = dialog });
//!
//! The act's content — which stocks, the act label, an energy rate, the body — stays the page's.

const std = @import("std");
const ha = @import("ha");

const comp = ha.sim.comp;
const uic = ha.ui_client;
const Node = uic.Node;
const UiCtx = uic.UiCtx;

const terminal_mod = @import("./terminal.zig");
const header_mod = @import("./header.zig");
const stock_mod = @import("./stock_token.zig");
const log_view_mod = @import("./log_view.zig");

pub const Options = struct {
    id: []const u8,
    act: terminal_mod.Act,
    /// A shell rail region (Act II's Holdings/BODY); Act I's workspace carries its own rail.
    rail: bool = false,
};

pub const Finish = struct {
    stocks: []const stock_mod.Stock,
    /// The long-line stockline form (Act II's nine stocks).
    compact_stocks: bool = false,
    act_label: []const u8,
    /// Per-unit energy generated and consumed; zero hides the runline's energy segment.
    gen: f32 = 0,
    consumed: f32 = 0,
    /// The framed event log under the page grid. A focus view drops it, and the grid takes
    /// its height.
    log: bool = true,
    /// A dialog's own overlay root, drawn after the shell.
    overlay: ?*Node = null,
};

pub const ActPage = struct {
    ctx: *UiCtx,
    regions: terminal_mod.Regions,
    /// At or below the 560 width class: reduced padding, the act label dropped.
    compact: bool,
    page_pad: f32,

    /// Build the header and the log, and return the roots in draw order.
    pub fn finish(self: ActPage, f: Finish) !uic.Trees {
        const ctx = self.ctx;
        _ = try header_mod.header(self.regions.header, "hud", .{
            .stocks = f.stocks,
            .compact_stocks = f.compact_stocks,
            .run = .{
                .gen = f.gen,
                .consumed = f.consumed,
                .act_label = f.act_label,
                .day = day(ctx),
                // The prototype keeps the act label at every width (it has no `.optional` run
                // segment), so the runline never drops it.
                .compact = false,
            },
        });
        // The log's new lines are announced whether or not this view shows the log: a focus
        // view (RESEARCH, MARKET) hides the footer, not the events. An announcement is a
        // polite live region, never a focus move.
        announceLog(ctx);
        // The footer is the content column's last row, so it is built here, after the body,
        // once the page knows whether the active view keeps the log. log_view authors in
        // logical px: the terminal's logical width less the page padding.
        if (f.log) {
            const footer = try terminal_mod.footer_band(self.regions.content, self.page_pad);
            try log_view_mod.log_view(footer, "feed", &ctx.res.game.sim.log, ctx.res.view.metrics.terminal.w - 2 * self.page_pad, 4);
        }
        var roots: std.ArrayList(*Node) = .empty;
        try roots.append(ctx.arena, self.regions.root.get());
        if (f.overlay) |o| try roots.append(ctx.arena, o);
        return roots.items;
    }
};

/// Announce the event-log lines pushed since the last read, oldest first; the first read
/// announces only the newest, so a launch does not recite the history.
pub fn announceLog(ctx: *UiCtx) void {
    const log = &ctx.res.game.sim.log;
    var seen = ctx.res.log_heard orelse log.pushed -| 1;
    // A fresh run starts a new log behind the old count: hear it from its newest line.
    if (seen > log.pushed) seen = log.pushed -| 1;
    var n = log.newSince(seen);
    while (n > 0) : (n -= 1) _ = ctx.res.announcements.announce(log.get(n - 1).text());
    ctx.res.log_heard = log.pushed;
}

/// Open the page: the shell with the log footer, at the width class's padding.
pub fn act_page(ctx: *UiCtx, opts: Options) !ActPage {
    const compact = ctx.res.view.metrics.width_class.atMost(.w560);
    const page_pad: f32 = if (compact) ha.tokens.pad_page_compact else ha.tokens.pad_page;
    const regions = try terminal_mod.shell(ctx, .{
        .id = opts.id,
        .act = opts.act,
        .page_pad = page_pad,
        .section_gap = ha.tokens.gap.section,
        .rail = opts.rail,
        // `finish` appends the footer last, when the page knows whether its view keeps it.
        .footer = false,
    });
    return .{ .ctx = ctx, .regions = regions, .compact = compact, .page_pad = page_pad };
}

/// The run's day counter, from 1.
pub fn day(ctx: *UiCtx) u64 {
    return 1 + @as(u64, @intFromFloat(ctx.res.game.sim.elapsed / ctx.res.game.config.secs_per_day));
}

/// The Vigor stock token, toned by the body's condition — the same reading every act shows.
pub fn vigorStock(ctx: *UiCtx, abbrev: []const u8, vigor: *const comp.Vigor) stock_mod.Stock {
    return .{
        .abbrev = abbrev,
        .full = "Vigor",
        .value = vigor.v,
        .max = vigor.max,
        .tone = switch (ctx.res.game.config.condition(vigor.v / vigor.max)) {
            .alive => .normal,
            .weary => .warn,
            .spent => .danger,
        },
    };
}

test "the log's new lines are announced once each, in order, without moving focus" {
    var res = uic.replay.headlessResources();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ctx = UiCtx.init(&res, std.testing.allocator, arena.allocator());
    defer ctx.deinit();
    const ch = &res.announcements;

    res.game.sim.log.push(.dim, "You wake alone. Cold. Hungry.");
    res.game.sim.log.push(.normal, "You return with 3 food.");
    // The first read hears only the newest line, not the history.
    announceLog(&ctx);
    try std.testing.expectEqual(@as(usize, 1), ch.pending().len);
    try std.testing.expectEqualStrings("You return with 3 food.", ch.pending()[0].slice());
    // A frame with nothing new says nothing.
    announceLog(&ctx);
    try std.testing.expectEqual(@as(usize, 1), ch.pending().len);
    // Two lines in one frame are both heard, oldest first, whether a view shows the log or not.
    res.game.sim.log.push(.good, "A passerby stops, and opens a satchel of odds and ends.");
    res.game.sim.log.push(.dim, "The merchant packs the cart and takes the river road.");
    announceLog(&ctx);
    try std.testing.expectEqual(@as(usize, 3), ch.pending().len);
    try std.testing.expectEqualStrings("A passerby stops, and opens a satchel of odds and ends.", ch.pending()[1].slice());
    // A fresh run's log is heard from its newest line.
    res.game.sim.log = .{};
    res.game.sim.log.push(.dim, "You wake alone. Cold. Hungry.");
    announceLog(&ctx);
    try std.testing.expectEqualStrings("You wake alone. Cold. Hungry.", ch.pending()[3].slice());
    // An announcement is a live region; nothing here touches focus.
    try std.testing.expectEqual(@as(?u64, null), ctx.focusedKey());
}
