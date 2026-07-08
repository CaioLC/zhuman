//! Barrel for the `ui_client` host-binding layer — everything UI code that isn't the
//! generic engine (`src/ui/`) and isn't game content (the `ui_*` screen builders still in
//! `main.zig`). Re-exported flat so callers use one namespace instead of five:
//!   - `ctx_binding` — the concrete engine types (`UiCtx`, `Node`, `RenderData`, `Sprite`)
//!   - `features`    — the paint-feature registry (text/fill/outline/img/svg) + `attach` mixins
//!   - `draw`        — the render walk (paint a whole laid-out tree, with the clip stack)
//!   - `widgets`      — the widget palette (button, panel, scroll_view, modal, …)
const ctx_binding = @import("./ctx_binding.zig");
const features = @import("./features/root.zig");
const draw = @import("./draw.zig");
const widgets = @import("./widgets.zig");
const pages = @import("./pages.zig");

// ctx_binding
pub const UiCtx = ctx_binding.UiCtx;
pub const Node = ctx_binding.Node;

// draw
pub const draw_tree = draw.draw_tree;

// features (attach mixins — the old `data_*` names)
pub const data_text = features.data_text;
pub const data_img = features.data_img;
pub const data_sprite = features.data_sprite;
pub const data_svg = features.data_svg;

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

// pages
pub const Trees = pages.Trees;
pub const ui_root = pages.ui_root;

test {
    _ = ctx_binding;
    _ = features;
    _ = draw;
    _ = widgets;
    _ = pages;
}
