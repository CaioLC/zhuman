pub const Padding = struct {
    up: f32,
    right: f32,
    down: f32,
    left: f32,

    pub fn init(p: f32) Padding {
        return .{ .up = p, .right = p, .down = p, .left = p };
    }

    pub fn initSymmetric(w: f32, h: f32) Padding {
        return .{ .up = h, .right = w, .down = h, .left = w };
    }

    pub fn initEach(u: f32, r: f32, d: f32, l: f32) Padding {
        return .{ .up = u, .right = r, .down = d, .left = l };
    }
};

/// How a node derives its size on **one axis** — the host *must* pick, per axis.
/// Resolution lives in `layout.zig`; the variants differ in dependency direction,
/// which is what drives the multi-pass solve:
///   - `fixed` / `content` — leaf, *definite* (known without parent or children).
///   - `pct_of_parent`      — needs the parent; definite iff the parent's axis is.
///   - `fit_children`       — needs the children; the only *indefinite* rule.
/// A `.pct_of_parent` under an indefinite (`fit_children`) parent has no definite
/// base, so it falls back to `content` (→ the node's measured `data_*`, or 0).
pub const SizeRule = union(enum) {
    fixed: f32,
    content, // sizes to the host-measured `data_width`/`data_height`
    pct_of_parent: f32, // fraction in 0..1
    fit_children,
};

pub const Size = struct {
    w: SizeRule,
    h: SizeRule,
    padding: Padding,
    /// Resolved box size (content-box + padding), filled by the solve passes.
    width: f32,
    height: f32,
    /// Intrinsic content size in px — the **host measures it at build** (text
    /// metrics, a sprite's dims) and stores it here. The `content` rule sizes to
    /// it; the host renderer draws to it. 0 for nodes with no intrinsic content.
    /// Sizing is pure: core reads these, never computes them (no host callback).
    data_width: f32,
    data_height: f32,
    /// Cross-axis **alignment reference** for a `.horizontal` flow: the px offset of this
    /// box's reference line *up from its bottom edge*. `0` (the default) ⇒ the reference is
    /// the bottom edge, so a plain box aligns by its bottom. The host sets it for text (=
    /// the font's descent) so a mixed-size row can share a common baseline. Consumed only by
    /// `layout.cross_ref` under `cross_align = .baseline`; ignored by every other rule and by
    /// non-horizontal flows. Measured at build like `data_*`, so the solve stays pure.
    baseline: f32 = 0,

    /// General constructor: pick a `SizeRule` per axis. Padding is **not** set here — it's
    /// a visual property owned by the style layer (`style.apply` writes `node.size.padding`),
    /// so a fresh box starts with zero padding. A `.content` axis sizes to
    /// `data_width`/`data_height` — supply those via `initContent`, or set the fields after
    /// construction; otherwise they default to 0. `width`/`height` are seeded to 0; the
    /// layout solve recomputes them (content + padding) every frame, so the seed is transient.
    pub fn init(w: SizeRule, h: SizeRule) Size {
        return .{
            .w = w,
            .h = h,
            .padding = Padding.init(0),
            .width = 0,
            .height = 0,
            .data_width = 0,
            .data_height = 0,
        };
    }

    /// Both axes fixed to explicit px.
    pub fn initFixed(width: f32, height: f32) Size {
        return init(.{ .fixed = width }, .{ .fixed = height });
    }

    /// Both axes sized to the host's pre-measured content dims (text, sprite, …).
    /// The host measures at build (it has the font/asset on hand) and passes the px
    /// extent in; the renderer reads it back from `data_width`/`data_height`.
    pub fn initContent(content_w: f32, content_h: f32) Size {
        var s = init(.content, .content);
        s.data_width = content_w;
        s.data_height = content_h;
        return s;
    }
};
