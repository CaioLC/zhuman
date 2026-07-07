//! Barrel for the `ui_client` host-binding layer — everything UI code that isn't the
//! generic engine (`src/ui/`) and isn't game content (the `ui_*` screen builders still in
//! `main.zig`). Re-exported flat so callers use one namespace instead of five:
//!   - `ctx_binding` — the concrete engine types (`UiCtx`, `Node`, `RenderData`, `Sprite`)
//!   - `draw`        — render primitives (paint one laid-out node)
//!   - `data`        — feature mixins (attach cached data + size to a node)
//!   - `widgets`      — the widget palette (button, panel, scroll_view, modal, …)
//!   - `tree`        — render-walk + frame tree-assembly (draw_tree, collect, ui_root)
const ctx_binding = @import("./ctx_binding.zig");
const draw = @import("./draw.zig");
const data = @import("./data.zig");
const widgets = @import("./widgets.zig");
const tree = @import("./tree.zig");

// ctx_binding
pub const UiState = ctx_binding.UiState;
pub const Interaction = ctx_binding.Interaction;
pub const UiCtx = ctx_binding.UiCtx;
pub const icon_cell = ctx_binding.icon_cell;
pub const Sprite = ctx_binding.Sprite;
pub const icon_sprite = ctx_binding.icon_sprite;
pub const RenderData = ctx_binding.RenderData;
pub const Node = ctx_binding.Node;

// draw
pub const draw_text = draw.draw_text;
pub const draw_texture = draw.draw_texture;
pub const draw_fill = draw.draw_fill;
pub const draw_outline = draw.draw_outline;

// data
pub const data_text = data.data_text;
pub const data_img = data.data_img;
pub const data_sprite = data.data_sprite;

// widgets
pub const label = widgets.label;
pub const img = widgets.img;
pub const progress_bar = widgets.progress_bar;
pub const button = widgets.button;
pub const icon_button = widgets.icon_button;
pub const tooltip = widgets.tooltip;
pub const panel = widgets.panel;
pub const ScrollView = widgets.ScrollView;
pub const scroll_view = widgets.scroll_view;
pub const Modal = widgets.Modal;
pub const modal = widgets.modal;
pub const text_input = widgets.text_input;

// tree
pub const Ui = tree.Ui;
pub const collect = tree.collect;
pub const ui_root = tree.ui_root;
pub const draw_tree = tree.draw_tree;
pub const draw_scanlines = tree.draw_scanlines;

test {
    _ = ctx_binding;
    _ = draw;
    _ = data;
    _ = widgets;
    _ = tree;
}
