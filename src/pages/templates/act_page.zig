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

const comp = ha.comp;
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
                .compact = self.compact,
            },
        });
        // log_view authors in logical px: the terminal's logical width less the page padding.
        if (self.regions.footer) |footer| {
            try log_view_mod.log_view(footer, "feed", &ctx.res.sim.log, ctx.res.view.metrics.terminal.w - 2 * self.page_pad, 4);
        }
        var roots: std.ArrayList(*Node) = .empty;
        try roots.append(ctx.arena, self.regions.root.get());
        if (f.overlay) |o| try roots.append(ctx.arena, o);
        return roots.items;
    }
};

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
        .footer = true,
    });
    return .{ .ctx = ctx, .regions = regions, .compact = compact, .page_pad = page_pad };
}

/// The run's day counter, from 1.
pub fn day(ctx: *UiCtx) u64 {
    return 1 + @as(u64, @intFromFloat(ctx.res.sim.elapsed / ctx.res.config.secs_per_day));
}

/// The Vigor stock token, toned by the body's condition — the same reading every act shows.
pub fn vigorStock(ctx: *UiCtx, abbrev: []const u8, vigor: *const comp.Vigor) stock_mod.Stock {
    return .{
        .abbrev = abbrev,
        .full = "Vigor",
        .value = vigor.v,
        .max = vigor.max,
        .tone = switch (ctx.res.config.condition(vigor.v / vigor.max)) {
            .alive => .normal,
            .weary => .warn,
            .spent => .danger,
        },
    };
}
