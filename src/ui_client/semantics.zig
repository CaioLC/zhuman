//! Host-side semantic model for interactive nodes/templates (INPUT-08).
//!
//! This is the presentation-side accessibility source that INPUT-09's platform bridge will
//! read from — it is **not** a second source of truth. Labels and values come from
//! authoritative widget/domain facts, and the interaction state carried here must match the
//! same `ControlState`/focus owners a control already publishes through `publishControlState`
//! (see `ctx_binding.zig`). The generic engine (`src/ui/`) never sees any of this; it stays
//! simulation- and accessibility-unaware. Everything lives host-side, keyed by the same
//! stable `node.key` the interaction and command registries use.
//!
//! Two bounded, allocation-free structures:
//!
//!   * `SemanticRegistry` — a fixed, **double-buffered** table built in UI/control paint
//!     order each frame and published after build/end-frame. A completed snapshot from the
//!     *prior* build is exposed without ever borrowing this frame's arena strings: every
//!     label/value is copied into fixed owned storage on the node, so a reader (the bridge)
//!     may hold the prior snapshot across the arena reset. Overflow (too many nodes) and
//!     per-field truncation are **refused explicitly** — never silently dropped or cut —
//!     via flags a reader can inspect. Duplicate keys within one build update the existing
//!     entry in place, preserving first-seen order (deterministic).
//!
//!   * `AnnouncementChannel` — a bounded polite live-region queue of owned announcement
//!     text with a monotonic generation counter. Consecutive unchanged messages are
//!     de-duplicated (the live-region contract: don't re-announce what's already stated),
//!     and overflow past capacity is refused explicitly rather than overwriting. This is
//!     presentation plumbing only: nothing here drives the simulation.
//!
//! The `build*`/`describe*` helpers at the bottom turn authoritative widget/domain facts
//! into `SemanticNode`s for the current stock/game controls (button, icon button, action
//! tile, build row, cancel/goal, tabs, ration choices, the build sort/show/tier radio-like
//! groups and the built checkbox, text input, progress bar, and the modal/dialog shell).
//! No production board/search/modal *consumer* exists at this roadmap stage, so these
//! describe the real controls that do exist and do not invent game content.

const std = @import("std");

/// The accessibility role of an interactive node — the coarse "what kind of control is
/// this" the bridge maps onto a platform role. Deliberately small and concrete to the
/// controls this game actually ships; not an attempt at the full ARIA vocabulary.
pub const Role = enum {
    /// A non-interactive text/label node exposed only for its accessible name.
    text,
    button,
    icon_button,
    /// A member of a single-selection group (tabs, ration choices, sort/show/tier chips).
    radio,
    /// A two-state toggle (the BUILD "built" filter).
    checkbox,
    /// A single-line editable field (search/text input).
    text_input,
    /// A determinate value indicator (an action's progress/countdown bar).
    progress_bar,
    /// A composite actionable card (an action tile / build row) that owns sub-actions.
    tile,
    /// A grouping container (a radio group, a list).
    group,
    /// A modal dialog shell / its scrim.
    dialog,
};

/// Live-region announcement politeness, mirroring the ARIA contract the bridge maps to a
/// platform notification priority. `off` means the node is not itself a live region.
pub const LiveRegion = enum { off, polite, assertive };

/// The semantic interaction state carried per node. These MUST match what the control
/// publishes to the interaction pool through `publishControlState` — this struct is a
/// projection for the bridge, not an independent latch. `expanded` has no interaction-pool
/// equivalent yet (no production disclosure/expander control exists), so it defaults false
/// and is set only by a helper whose control genuinely owns an expanded/collapsed fact.
pub const SemanticState = struct {
    disabled: bool = false,
    focused: bool = false,
    selected: bool = false,
    checked: bool = false,
    expanded: bool = false,
};

/// Fixed owned storage for one accessible string. Copies the source bytes so the prior
/// snapshot never borrows the frame arena; a source longer than `cap` is **refused as a
/// whole** (the field reports `truncated = true` and keeps `len = 0`) rather than storing a
/// silently cut prefix — the same non-silent-refusal policy the editor uses for overflow.
pub fn OwnedText(comptime cap_bytes: usize) type {
    return struct {
        const Self = @This();
        pub const cap = cap_bytes;

        buf: [cap]u8 = undefined,
        len: usize = 0,
        /// The last `set` was refused because the source exceeded `cap`. A reader treats a
        /// truncated field as "no reliable name/value here" rather than a cut string.
        truncated: bool = false,

        /// Copy `text` in full, or refuse it whole if it would not fit. Returns whether it
        /// was accepted. Passing an empty slice clears the field (accepted).
        pub fn set(self: *Self, text: []const u8) bool {
            if (text.len > cap) {
                self.len = 0;
                self.truncated = true;
                return false;
            }
            @memcpy(self.buf[0..text.len], text);
            self.len = text.len;
            self.truncated = false;
            return true;
        }

        pub fn slice(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.len == 0;
        }
    };
}

/// Max bytes of an accessible label / value. Generous for the game's short control names
/// and formatted readouts; overflow is refused, not truncated. `value_cap` is sized to
/// comfortably exceed the text editor's `max_query_bytes` (128) so a full search query is
/// represented as a value rather than refused.
pub const label_cap = 96;
pub const value_cap = 160;
pub const Label = OwnedText(label_cap);
pub const Value = OwnedText(value_cap);

/// Maximum stable-key relationship links carried per node. Small on purpose: a control
/// that "controls" or is "described by" a handful of stable keys, not an arbitrary graph.
pub const max_relations = 4;

/// A stable-key relationship set. `controls` links a controller (e.g. a tab) to the
/// stable keys of what it governs; `described_by` links a control to label/description
/// nodes that name it. Both are arrays of the same `node.key` the interaction pool uses,
/// so the bridge resolves them against the published snapshot without any pointer that
/// could dangle across the frame swap.
pub const Relations = struct {
    controls: [max_relations]u64 = undefined,
    controls_len: usize = 0,
    described_by: [max_relations]u64 = undefined,
    described_by_len: usize = 0,
    /// A relation was dropped because the fixed link capacity was exceeded — refused
    /// explicitly rather than silently omitted.
    overflow: bool = false,

    pub fn addControls(self: *Relations, key: u64) void {
        if (self.controls_len == max_relations) {
            self.overflow = true;
            return;
        }
        self.controls[self.controls_len] = key;
        self.controls_len += 1;
    }

    pub fn addDescribedBy(self: *Relations, key: u64) void {
        if (self.described_by_len == max_relations) {
            self.overflow = true;
            return;
        }
        self.described_by[self.described_by_len] = key;
        self.described_by_len += 1;
    }

    pub fn controlsSlice(self: *const Relations) []const u64 {
        return self.controls[0..self.controls_len];
    }

    pub fn describedBySlice(self: *const Relations) []const u64 {
        return self.described_by[0..self.described_by_len];
    }
};

/// One interactive node's complete semantics, owned by the registry. All strings are
/// copied into `label`/`value`, so a completed snapshot outlives the frame arena. `key` is
/// the same stable `node.key` used by focus/interaction/command routing, which is how the
/// bridge cross-references the live interaction state.
pub const SemanticNode = struct {
    key: u64 = 0,
    role: Role = .text,
    label: Label = .{},
    /// Present only when the control has a distinct value text separate from its name
    /// (a text input's contents, a progress bar's readout). `value_present = false` means
    /// "no value semantics", distinct from an empty value string.
    value: Value = .{},
    value_present: bool = false,
    state: SemanticState = .{},
    relations: Relations = .{},
    live: LiveRegion = .off,

    /// Set the accessible name; returns false and marks `label.truncated` if refused.
    pub fn setLabel(self: *SemanticNode, text: []const u8) bool {
        return self.label.set(text);
    }

    /// Set the value text and mark it present; returns false and marks `value.truncated`
    /// if refused (the node still reports `value_present = true` so the bridge knows a
    /// value exists but could not be represented).
    pub fn setValue(self: *SemanticNode, text: []const u8) bool {
        self.value_present = true;
        return self.value.set(text);
    }

    pub fn labelText(self: *const SemanticNode) []const u8 {
        return self.label.slice();
    }

    pub fn valueText(self: *const SemanticNode) ?[]const u8 {
        return if (self.value_present) self.value.slice() else null;
    }
};

/// A bounded, double-buffered semantic table. `building` accumulates this frame's nodes in
/// paint order; `endBuild` swaps it into `current`, the completed prior-frame snapshot a
/// reader consumes. Fixed capacity keeps it allocation-free; overflow past capacity is
/// refused and flagged, and the already-registered nodes are preserved. Mirrors the
/// `command.Registry` double-buffer exactly so the lifecycle wiring is uniform.
pub fn SemanticRegistryN(comptime cap_nodes: usize) type {
    return struct {
        const Self = @This();
        pub const cap = cap_nodes;

        current: [cap]SemanticNode = undefined,
        current_len: usize = 0,
        building: [cap]SemanticNode = undefined,
        building_len: usize = 0,
        /// The build in progress overflowed capacity (a node was refused). Cleared each
        /// `beginBuild`; a reader inspects `snapshotOverflow` for the *published* value.
        building_overflow: bool = false,
        current_overflow: bool = false,
        /// A field (label/value) was refused for length, or a relation set overflowed,
        /// somewhere in the build. Surfaced so a reader knows the snapshot is lossy.
        building_field_refused: bool = false,
        current_field_refused: bool = false,

        pub fn beginBuild(self: *Self) void {
            self.building_len = 0;
            self.building_overflow = false;
            self.building_field_refused = false;
        }

        /// Publish one node into the current build, in paint order. Duplicate keys update
        /// the existing entry in place (last write wins) and preserve its first-seen
        /// position — deterministic order and update policy. A new key past capacity is
        /// refused and flagged. Field-level truncation/relation overflow already recorded
        /// on the node is folded into the build's `field_refused` flag.
        pub fn publish(self: *Self, node: SemanticNode) void {
            self.foldFieldRefusal(node);
            for (self.building[0..self.building_len]) |*existing| {
                if (existing.key == node.key) {
                    existing.* = node;
                    return;
                }
            }
            if (self.building_len == cap) {
                self.building_overflow = true;
                return;
            }
            self.building[self.building_len] = node;
            self.building_len += 1;
        }

        fn foldFieldRefusal(self: *Self, node: SemanticNode) void {
            if (node.label.truncated) self.building_field_refused = true;
            if (node.value_present and node.value.truncated) self.building_field_refused = true;
            if (node.relations.overflow) self.building_field_refused = true;
        }

        /// Swap the completed build into the published snapshot. The old `current` buffer
        /// becomes the next `building` scratch (its stale contents are overwritten from
        /// `building_len = 0`). No strings are aliased: each `SemanticNode` owns its bytes
        /// by value, so the swap moves owned storage, never a borrow of the frame arena.
        pub fn endBuild(self: *Self) void {
            const tmp = self.current;
            self.current = self.building;
            self.building = tmp;
            self.current_len = self.building_len;
            self.current_overflow = self.building_overflow;
            self.current_field_refused = self.building_field_refused;
            self.building_len = 0;
            self.building_overflow = false;
            self.building_field_refused = false;
        }

        /// The published prior-frame snapshot, in paint order. Safe to hold across the
        /// frame-arena reset — every string is owned by value here.
        pub fn snapshot(self: *const Self) []const SemanticNode {
            return self.current[0..self.current_len];
        }

        pub fn snapshotOverflow(self: *const Self) bool {
            return self.current_overflow;
        }

        pub fn snapshotFieldRefused(self: *const Self) bool {
            return self.current_field_refused;
        }

        /// Find a published node by stable key, or null. Linear over the small snapshot.
        pub fn find(self: *const Self, key: u64) ?*const SemanticNode {
            for (self.current[0..self.current_len]) |*node| {
                if (node.key == key) return node;
            }
            return null;
        }
    };
}

/// Max interactive nodes tracked per frame. Comfortably covers the busiest screen (the
/// BUILD tab: ten filter chips + a checkbox + up to fifteen rows with build/cancel plus
/// the goal card and its actions) with headroom; past it, overflow is refused and flagged.
pub const max_semantic_nodes = 128;
pub const SemanticRegistry = SemanticRegistryN(max_semantic_nodes);

/// One queued polite announcement: owned text plus the monotonic generation it was
/// accepted at. The generation lets a reader detect "there is something new to speak"
/// without diffing text, and orders announcements deterministically.
pub const Announcement = struct {
    text: OwnedText(value_cap) = .{},
    generation: u64 = 0,

    pub fn slice(self: *const Announcement) []const u8 {
        return self.text.slice();
    }
};

/// A bounded polite live-region channel. `announce` copies owned text, drops a message
/// identical to the most recent one (consecutive dedup — the live-region contract), and
/// refuses (does not overwrite) once the queue is full or a message exceeds capacity.
/// A monotonic `generation` increments on every accepted message. This is presentation
/// plumbing: it holds text for the bridge to speak and has no authority over simulation.
pub fn AnnouncementChannelN(comptime cap_msgs: usize) type {
    return struct {
        const Self = @This();
        pub const cap = cap_msgs;

        queue: [cap]Announcement = undefined,
        len: usize = 0,
        /// Monotonic across the whole session, never reset — a reader compares it to the
        /// generation it last spoke to know what is new.
        generation: u64 = 0,
        /// The last accepted message's generation (0 = nothing accepted yet). Used for the
        /// consecutive-dedup comparison and as the reader's "latest" cursor.
        last_generation: u64 = 0,
        /// The most recent `announce` was refused: queue full or message too long. Cleared
        /// on the next accepted message. A dropped *duplicate* is not a refusal (it is the
        /// intended dedup), so it does not set this.
        overflow: bool = false,

        /// Queue a polite announcement. Returns whether it was accepted (a deduped
        /// duplicate returns false but does not set `overflow`; a refused message returns
        /// false and sets `overflow`). The generation of an accepted message is available
        /// via `lastGeneration`.
        pub fn announce(self: *Self, text: []const u8) bool {
            if (self.len > 0) {
                const prev = &self.queue[self.len - 1];
                if (std.mem.eql(u8, prev.slice(), text)) {
                    // Identical to the most recent message — the dedup contract. Not an
                    // overflow; simply nothing new to speak.
                    return false;
                }
            }
            if (self.len == cap) {
                self.overflow = true;
                return false;
            }
            var msg: Announcement = .{};
            if (!msg.text.set(text)) {
                // Too long to represent — refuse whole (matches the field policy).
                self.overflow = true;
                return false;
            }
            self.generation += 1;
            msg.generation = self.generation;
            self.queue[self.len] = msg;
            self.len += 1;
            self.last_generation = self.generation;
            self.overflow = false;
            return true;
        }

        /// The queued announcements in order.
        pub fn pending(self: *const Self) []const Announcement {
            return self.queue[0..self.len];
        }

        /// The most recent accepted announcement, or null if the queue is empty.
        pub fn latest(self: *const Self) ?*const Announcement {
            if (self.len == 0) return null;
            return &self.queue[self.len - 1];
        }

        pub fn lastGeneration(self: *const Self) u64 {
            return self.last_generation;
        }

        /// Drop everything the reader has already consumed up to and including
        /// `through_generation`, compacting the queue. A reader calls this after speaking
        /// so the bounded queue does not stay full. Messages newer than the cursor remain.
        pub fn drainThrough(self: *Self, through_generation: u64) void {
            var kept: usize = 0;
            for (self.queue[0..self.len]) |msg| {
                if (msg.generation > through_generation) {
                    self.queue[kept] = msg;
                    kept += 1;
                }
            }
            self.len = kept;
            if (kept == 0) self.overflow = false;
        }
    };
}

pub const max_announcements = 16;
pub const AnnouncementChannel = AnnouncementChannelN(max_announcements);

// --- Representative publication helpers -------------------------------------------------
//
// Pure functions that turn authoritative widget/domain facts into a `SemanticNode`. They
// take the same stable key, label text, and `ControlState`-equivalent booleans the widget
// already computed, so the semantics can never disagree with the interaction pool. They do
// not touch `UiCtx` or the frame arena — a caller invokes them right where it already calls
// `publishControlState`, then hands the result to `SemanticRegistry.publish`. Kept here (not
// in the widgets) so `describe*` shapes stay testable in isolation and `src/ui` stays clean.

/// A plain button. `label` is the button's own text (authoritative widget fact);
/// `enabled` is the caller's domain gate, `focused` the focus registry's answer.
pub fn describeButton(key: u64, label: []const u8, enabled: bool, focused: bool) SemanticNode {
    var node = SemanticNode{ .key = key, .role = .button };
    _ = node.setLabel(label);
    node.state = .{ .disabled = !enabled, .focused = focused };
    return node;
}

/// An icon button, whose accessible name cannot come from a glyph — the caller must pass
/// an explicit name from the domain (what the icon *does*), which is why icon buttons
/// require a name argument the visual does not.
pub fn describeIconButton(key: u64, name: []const u8, enabled: bool, focused: bool) SemanticNode {
    var node = SemanticNode{ .key = key, .role = .icon_button };
    _ = node.setLabel(name);
    node.state = .{ .disabled = !enabled, .focused = focused };
    return node;
}

/// A member of a single-selection group (a tab, a ration choice, a sort/show/tier chip).
/// `selected` mirrors the group's active choice; `group_key` links the member back to its
/// owning group via a `described_by` relation so the bridge can announce the group name.
pub fn describeRadio(key: u64, label: []const u8, selected: bool, focused: bool, group_key: ?u64) SemanticNode {
    var node = SemanticNode{ .key = key, .role = .radio };
    _ = node.setLabel(label);
    node.state = .{ .selected = selected, .focused = focused };
    if (group_key) |g| node.relations.addDescribedBy(g);
    return node;
}

/// A radio/selection group container. `controls` are the stable keys of its members, in
/// paint order — the controller→governed relationship the bridge walks.
pub fn describeGroup(key: u64, label: []const u8, members: []const u64) SemanticNode {
    var node = SemanticNode{ .key = key, .role = .group };
    _ = node.setLabel(label);
    for (members) |m| node.relations.addControls(m);
    return node;
}

/// A two-state toggle (the BUILD "built" filter). `checked` mirrors the toggle's fact.
pub fn describeCheckbox(key: u64, label: []const u8, checked: bool, focused: bool) SemanticNode {
    var node = SemanticNode{ .key = key, .role = .checkbox };
    _ = node.setLabel(label);
    node.state = .{ .checked = checked, .focused = focused };
    return node;
}

/// A single-line text input. `name` is the field's accessible name (its placeholder /
/// purpose), `value` its current contents (authoritative editor model text). A refused
/// edit is surfaced as an assertive live region so the bridge can announce the rejection
/// non-silently, matching the widget's `danger` outline.
pub fn describeTextInput(
    key: u64,
    name: []const u8,
    value: []const u8,
    focused: bool,
    refused: bool,
) SemanticNode {
    var node = SemanticNode{ .key = key, .role = .text_input };
    _ = node.setLabel(name);
    _ = node.setValue(value);
    node.state = .{ .focused = focused };
    node.live = if (refused) .assertive else .off;
    return node;
}

/// A determinate progress/countdown bar. `name` names what is progressing; `value` is a
/// caller-formatted readout of the fraction/quantity (the bar has no text of its own, so
/// the caller supplies the authoritative readout from the same domain number it fills to).
pub fn describeProgressBar(key: u64, name: []const u8, value: []const u8) SemanticNode {
    var node = SemanticNode{ .key = key, .role = .progress_bar };
    _ = node.setLabel(name);
    _ = node.setValue(value);
    return node;
}

/// A composite actionable card — an action tile or a build row. `controls` links it to the
/// stable keys of its own sub-actions (build / cancel / goal), which the bridge exposes as
/// children rather than flattening.
pub fn describeTile(
    key: u64,
    label: []const u8,
    enabled: bool,
    focused: bool,
    sub_actions: []const u64,
) SemanticNode {
    var node = SemanticNode{ .key = key, .role = .tile };
    _ = node.setLabel(label);
    node.state = .{ .disabled = !enabled, .focused = focused };
    for (sub_actions) |s| node.relations.addControls(s);
    return node;
}

/// A modal dialog shell. `expanded` is genuinely owned here — a dialog is either open
/// (expanded) or it is not built at all — so this is the one control that sets it. The
/// scrim/dialog root is a polite live region so opening it can be announced.
pub fn describeDialog(key: u64, title: []const u8, focused: bool) SemanticNode {
    var node = SemanticNode{ .key = key, .role = .dialog };
    _ = node.setLabel(title);
    node.state = .{ .focused = focused, .expanded = true };
    node.live = .polite;
    return node;
}

// --- Tests ------------------------------------------------------------------------------

const testing = std.testing;

test "owned text copies in full and refuses whole when over capacity" {
    var t = OwnedText(8){};
    try testing.expect(t.set("hello"));
    try testing.expectEqualStrings("hello", t.slice());
    try testing.expect(!t.truncated);
    // Over capacity: refused whole, not a cut prefix, and length stays 0.
    try testing.expect(!t.set("way too long"));
    try testing.expect(t.truncated);
    try testing.expectEqual(@as(usize, 0), t.len);
    // A subsequent fitting set clears the refusal.
    try testing.expect(t.set("ok"));
    try testing.expect(!t.truncated);
    try testing.expectEqualStrings("ok", t.slice());
}

test "registry publishes prior snapshot with owned strings across a frame swap" {
    var reg = SemanticRegistry{};
    var scratch: [8]u8 = undefined;
    reg.beginBuild();
    @memcpy(scratch[0..5], "Sleep");
    // Publish from a volatile buffer, then clobber it: the snapshot must own its bytes.
    reg.publish(describeButton(1, scratch[0..5], true, false));
    @memcpy(scratch[0..5], "XXXXX");
    reg.endBuild();

    const snap = reg.snapshot();
    try testing.expectEqual(@as(usize, 1), snap.len);
    try testing.expectEqualStrings("Sleep", snap[0].labelText());
    try testing.expectEqual(Role.button, snap[0].role);

    // A fresh empty build does not disturb the still-published prior snapshot until swap.
    reg.beginBuild();
    reg.publish(describeButton(2, "Forage", false, true));
    try testing.expectEqualStrings("Sleep", reg.snapshot()[0].labelText());
    reg.endBuild();
    const snap2 = reg.snapshot();
    try testing.expectEqual(@as(usize, 1), snap2.len);
    try testing.expectEqualStrings("Forage", snap2[0].labelText());
    try testing.expect(snap2[0].state.disabled);
    try testing.expect(snap2[0].state.focused);
}

test "registry keeps paint order and updates duplicate keys in place" {
    var reg = SemanticRegistry{};
    reg.beginBuild();
    reg.publish(describeButton(10, "A", true, false));
    reg.publish(describeButton(20, "B", true, false));
    reg.publish(describeButton(30, "C", true, false));
    // Duplicate key 20: updates in place, keeps its original second position.
    reg.publish(describeButton(20, "B2", false, true));
    reg.endBuild();

    const snap = reg.snapshot();
    try testing.expectEqual(@as(usize, 3), snap.len);
    try testing.expectEqualStrings("A", snap[0].labelText());
    try testing.expectEqualStrings("B2", snap[1].labelText());
    try testing.expectEqualStrings("C", snap[2].labelText());
    try testing.expect(snap[1].state.disabled and snap[1].state.focused);

    // find resolves by stable key against the published snapshot.
    try testing.expectEqualStrings("C", reg.find(30).?.labelText());
    try testing.expectEqual(@as(?*const SemanticNode, null), reg.find(999));
}

test "registry refuses node overflow explicitly and preserves earlier nodes" {
    var reg = SemanticRegistryN(2){};
    reg.beginBuild();
    reg.publish(describeButton(1, "one", true, false));
    reg.publish(describeButton(2, "two", true, false));
    reg.publish(describeButton(3, "three", true, false)); // past capacity → refused
    reg.endBuild();
    try testing.expect(reg.snapshotOverflow());
    const snap = reg.snapshot();
    try testing.expectEqual(@as(usize, 2), snap.len);
    try testing.expectEqualStrings("one", snap[0].labelText());
    try testing.expectEqualStrings("two", snap[1].labelText());
    // A later clean build clears the published overflow flag.
    reg.beginBuild();
    reg.publish(describeButton(1, "one", true, false));
    reg.endBuild();
    try testing.expect(!reg.snapshotOverflow());
}

test "registry surfaces field truncation refusal in the published snapshot" {
    var reg = SemanticRegistry{};
    var long: [label_cap + 1]u8 = undefined;
    @memset(&long, 'x');
    reg.beginBuild();
    reg.publish(describeButton(1, &long, true, false)); // label too long → refused whole
    reg.endBuild();
    try testing.expect(reg.snapshotFieldRefused());
    // The refused label reads empty (not a cut prefix), and the flag is on the node too.
    const snap = reg.snapshot();
    try testing.expectEqual(@as(usize, 0), snap[0].labelText().len);
    try testing.expect(snap[0].label.truncated);
}

test "state and relationships mirror authoritative facts" {
    // Radio member links to its group; group controls its members in order.
    const g = describeGroup(100, "SORT", &[_]u64{ 101, 102, 103 });
    try testing.expectEqual(Role.group, g.role);
    try testing.expectEqualSlices(u64, &[_]u64{ 101, 102, 103 }, g.relations.controlsSlice());

    const r = describeRadio(101, "reach", true, false, 100);
    try testing.expect(r.state.selected);
    try testing.expectEqualSlices(u64, &[_]u64{100}, r.relations.describedBySlice());

    const c = describeCheckbox(200, "built", true, true);
    try testing.expect(c.state.checked and c.state.focused);
    try testing.expectEqual(Role.checkbox, c.role);

    const tile = describeTile(300, "Fell a tree", true, false, &[_]u64{ 301, 302 });
    try testing.expectEqualSlices(u64, &[_]u64{ 301, 302 }, tile.relations.controlsSlice());

    const d = describeDialog(400, "Act I complete", true);
    try testing.expect(d.state.expanded and d.state.focused);
    try testing.expectEqual(LiveRegion.polite, d.live);
}

test "relation set overflow is refused explicitly" {
    var rel: Relations = .{};
    var i: u64 = 0;
    while (i < max_relations) : (i += 1) rel.addControls(i);
    try testing.expect(!rel.overflow);
    rel.addControls(999); // past capacity
    try testing.expect(rel.overflow);
    try testing.expectEqual(@as(usize, max_relations), rel.controlsSlice().len);
}

test "text input carries value and refusal live region" {
    const ok = describeTextInput(1, "Search goods", "iron", true, false);
    try testing.expectEqualStrings("Search goods", ok.labelText());
    try testing.expectEqualStrings("iron", ok.valueText().?);
    try testing.expect(ok.state.focused);
    try testing.expectEqual(LiveRegion.off, ok.live);

    const refused = describeTextInput(1, "Search goods", "iron", true, true);
    try testing.expectEqual(LiveRegion.assertive, refused.live);

    // An empty value is still "present" (distinct from a control with no value at all).
    const empty = describeTextInput(2, "Search", "", false, false);
    try testing.expect(empty.value_present);
    try testing.expectEqualStrings("", empty.valueText().?);

    // A plain button has no value semantics.
    const btn = describeButton(3, "Go", true, false);
    try testing.expectEqual(@as(?[]const u8, null), btn.valueText());
}

test "progress bar carries a name and a formatted value readout" {
    const p = describeProgressBar(1, "Building shelter", "62%");
    try testing.expectEqualStrings("Building shelter", p.labelText());
    try testing.expectEqualStrings("62%", p.valueText().?);
    try testing.expectEqual(Role.progress_bar, p.role);
}

test "announcement channel dedups consecutive, generations monotonic" {
    var ch = AnnouncementChannel{};
    try testing.expect(ch.announce("Shelter raised."));
    try testing.expectEqual(@as(u64, 1), ch.lastGeneration());
    // Same message immediately again: deduped, not a refusal, generation unchanged.
    try testing.expect(!ch.announce("Shelter raised."));
    try testing.expect(!ch.overflow);
    try testing.expectEqual(@as(u64, 1), ch.lastGeneration());
    // A different message is accepted and bumps the generation.
    try testing.expect(ch.announce("You feel weak."));
    try testing.expectEqual(@as(u64, 2), ch.lastGeneration());
    // The earlier message repeated is accepted again — dedup is only *consecutive*.
    try testing.expect(ch.announce("Shelter raised."));
    try testing.expectEqual(@as(u64, 3), ch.lastGeneration());
    try testing.expectEqual(@as(usize, 3), ch.pending().len);
    try testing.expectEqualStrings("Shelter raised.", ch.latest().?.slice());
}

test "announcement channel refuses overflow and over-long messages explicitly" {
    var ch = AnnouncementChannelN(2){};
    try testing.expect(ch.announce("one"));
    try testing.expect(ch.announce("two"));
    // Queue full: refused explicitly.
    try testing.expect(!ch.announce("three"));
    try testing.expect(ch.overflow);
    try testing.expectEqual(@as(usize, 2), ch.pending().len);

    // Draining consumed messages compacts the queue and clears overflow when empty.
    ch.drainThrough(ch.lastGeneration());
    try testing.expectEqual(@as(usize, 0), ch.pending().len);
    try testing.expect(!ch.overflow);

    // Over-long message: refused whole, flagged.
    var over: [value_cap + 1]u8 = undefined;
    @memset(&over, 'y');
    try testing.expect(!ch.announce(&over));
    try testing.expect(ch.overflow);
    try testing.expectEqual(@as(usize, 0), ch.pending().len);
}

test "announcement drain keeps messages newer than the cursor" {
    var ch = AnnouncementChannel{};
    _ = ch.announce("a");
    _ = ch.announce("b");
    const cursor = ch.lastGeneration();
    _ = ch.announce("c");
    ch.drainThrough(cursor); // speak through b, keep c
    try testing.expectEqual(@as(usize, 1), ch.pending().len);
    try testing.expectEqualStrings("c", ch.pending()[0].slice());
}
