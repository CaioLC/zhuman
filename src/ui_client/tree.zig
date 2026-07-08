//! Render-walk and frame tree-assembly — the host UI plumbing that turns `build_ui`'s
//! per-screen node trees into pixels, without knowing anything about game content.
//! Moved out of `main.zig`, which now only owns `App`, the event loop, and the sim tick —
//! the game-specific `ui_*` screen builders live in `ui_client/pages.zig`.

const std = @import("std");
const ui = @import("../ui/root.zig");
const sdl = @import("sdl3");
const cb = @import("./ctx_binding.zig");
const draw = @import("./draw.zig");
const Resources = @import("../res.zig").Resources;

const UiCtx = cb.UiCtx;
const Node = cb.Node;

/// One entry in `draw_tree`'s clip stack: the node that pushed the clip (so we know when
/// we've walked back out of its subtree) and the *already-intersected* rect active while
/// inside it (nesting narrows, never widens).
const ClipFrame = struct { node: *Node, rect: ui.Rect };

/// Push/pop `renderer`'s scissor rect to `r` (or disable clipping for `null`). SDL wants
/// integer pixels; the layout solve works in `f32`, so this is the one truncation point.
fn apply_clip(u: *UiCtx, r: ?ui.Rect) void {
    const clip = if (r) |rect| sdl.rect.IRect{
        .x = @intFromFloat(rect.x),
        .y = @intFromFloat(rect.y),
        .w = @intFromFloat(rect.w),
        .h = @intFromFloat(rect.h),
    } else null;
    u.res.renderer.setClipRect(clip) catch {};
}

/// Walk a UI tree and paint each node by its render aspects. Order matters: fill
/// (backmost) → image → text → outline (topmost), so a hover/affordance ring shows
/// over opaque icon tiles. Called once per root tree, in the render list's order.
///
/// `RenderData.clip` marks a node whose subtree should be cropped to its own box (a
/// scroll viewport) — the walk is pre-order, so a stack of currently-open clip nodes is
/// popped whenever the next node isn't inside the one on top (found by climbing
/// `.parent`, since there's no "leaving a subtree" signal from `iterate()`).
pub fn draw_tree(u: *UiCtx, root: *Node) void {
    var clip_stack: [16]ClipFrame = undefined;
    var depth: usize = 0;

    var it = root.iterate();
    while (it.next()) |node| {
        while (depth > 0 and !is_descendant(node, clip_stack[depth - 1].node)) {
            depth -= 1;
            apply_clip(u, if (depth > 0) clip_stack[depth - 1].rect else null);
        }

        if (node.render_data.fill) |c| draw.draw_fill(u, node, c);
        if (node.render_data.img) |s| draw.draw_texture(u, node, s);
        if (node.render_data.text) |c| draw.draw_text(u, node, c);
        if (node.render_data.outline) |c| draw.draw_outline(u, node, c);

        if (node.render_data.clip) {
            const box = ui.Rect{
                .x = node.layout._global_x orelse 0,
                .y = node.layout._global_y orelse 0,
                .w = node.size.width,
                .h = node.size.height,
            };
            const active = if (depth > 0) box.intersect(clip_stack[depth - 1].rect) else box;
            clip_stack[depth] = .{ .node = node, .rect = active };
            depth += 1;
            apply_clip(u, active);
        }
    }
    if (depth > 0) apply_clip(u, null); // don't leak a scissor rect into the next root's draw
}

/// A subtle repeating horizontal darkening every 4px — the redesign's terminal-identity
/// scanline overlay (M5). Drawn last, over the whole frame, at partial alpha (~14%,
/// matching the design's CSS); needs the renderer's blend mode set to `.blend` (done
/// once in `App.init` — every other draw is fully opaque, so that change is invisible
/// everywhere except here).
pub fn draw_scanlines(res: *Resources, ww: usize, wh: usize) void {
    res.renderer.setDrawColor(.{ .r = 0, .g = 0, .b = 0, .a = 36 }) catch return;
    const w: f32 = @floatFromInt(ww);
    const h: f32 = @floatFromInt(wh);
    var y: f32 = 2;
    while (y < h) : (y += 4) {
        res.renderer.renderFillRect(.{ .x = 0, .y = y, .w = w, .h = 1 }) catch {};
    }
}

/// Is `ancestor` `node` itself or one of its ancestors, walking up via `.parent`?
fn is_descendant(node: *Node, ancestor: *Node) bool {
    var n: ?*Node = node;
    while (n) |cur| {
        if (cur == ancestor) return true;
        n = cur.parent;
    }
    return false;
}

/// What `build_ui` hands back each frame: a flat list of independent root trees, laid
/// out and drawn in order (later trees paint on top). Generalizes the old fixed
/// `main`/`overlay` pair — the screen, plus any floating overlays (a hover tooltip,
/// later a modal). A `ui_*` builder returns a single tree or a tuple of them, which
/// `collect` flattens into this list. Arena-backed, so it dies with the frame's tree.
pub const Ui = struct {
    trees: []const *Node,
};

/// Append `item` to the render list, flattening whatever shape a `ui_*` builder hands
/// back: a single `*Node`, an `?*Node` (skipped when null), or a tuple mixing the two
/// (e.g. a screen plus its optional tooltip). Each leaf is an independent root tree; its
/// position in the list is its draw order.
pub fn collect(list: *std.ArrayList(*Node), arena: std.mem.Allocator, item: anytype) !void {
    switch (@typeInfo(@TypeOf(item))) {
        .optional => if (item) |v| try collect(list, arena, v),
        .pointer => try list.append(arena, item), // a single `*Node`
        .@"struct" => |s| inline for (s.fields) |f| try collect(list, arena, @field(item, f.name)),
        else => @compileError("collect: unsupported UI tree shape " ++ @typeName(@TypeOf(item))),
    }
}

/// A fullscreen root: the anchor box a whole screen's content positions against. Every
/// screen (`ui_playgame`, `ui_gameover`) is its own independent tree rooted here, laid
/// out from (0,0) and drawn in the order `build_ui` lists it. Sized to the live window
/// so `.center`/`.center_left`/… anchors resolve against the full display.
pub fn ui_root(ui_ctx: *UiCtx, id: []const u8) !*Node {
    const ww, const wh = try ui_ctx.res.window.getSize();
    const root = try Node.create(ui_ctx.arena, id);
    _ = root.with_layout(ui.features.Layout.init(.top_left, .horizontal))
        .with_size(ui.features.Size.initFixed(@floatFromInt(ww), @floatFromInt(wh), null));
    return root;
}
