//! The cached UI description and the per-widget native state machine.
//!
//! The scene is the host's side of the LiveView-style contract:
//!
//!   * Elixir sends complete descriptors; the scene validates them, installs
//!     them atomically between frames, and never calls back into Elixir to draw.
//!   * Widget identity is `{id, incarnation}`. Native state (text buffer, draft
//!     revision, acknowledged revision, caret) follows the identity, so a keyed
//!     reorder keeps an editor's text, caret, and selection, while a widget that
//!     is deleted and recreated under the same id gets a distinct incarnation
//!     and therefore a distinct buffer.
//!   * Text is a replicating value: the native side owns a responsive draft and
//!     a monotonically increasing draft revision; Elixir acknowledges the
//!     highest revision it accepted. An acknowledgement can never overwrite
//!     newer text, and an application replacement that arrives while a draft is
//!     unacknowledged is deferred until the draft settles (see docs/PROTOCOL.md).
//!
//! Nothing in this file draws: `render.zig` walks an installed tree each frame.

const std = @import("std");
const protocol = @import("protocol.zig");

const Node = protocol.Node;
const KeyedChild = protocol.KeyedChild;

pub const max_widget_buffers: usize = 256;
pub const widget_buffer_bytes: usize = 2 * 1024 * 1024;

pub const Widget = struct {
    /// Owned by the scene's long-lived allocator (not the snapshot arena), so it
    /// survives snapshot replacement.
    id: []u8,
    incarnation: u64,
    /// Text the native editor is editing. Always NUL terminated for cimgui.
    buffer: std.ArrayListUnmanaged(u8) = .empty,
    /// Value last applied from Elixir (snapshot value or `set_value`).
    applied_value: std.ArrayListUnmanaged(u8) = .empty,
    /// Application replacement deferred while a draft is unacknowledged.
    pending_replacement: ?std.ArrayListUnmanaged(u8) = null,
    draft_revision: u64 = 0,
    ack_revision: u64 = 0,
    /// Draft revision already handed to Elixir (so unchanged text is not resent).
    published_revision: u64 = 0,
    active: bool = false,
    focused: bool = false,
    cursor: u32 = 0,
    selection: [2]u32 = .{ 0, 0 },
    /// Snapshot in which this widget last appeared (for orphan handling).
    last_seen_snapshot: u64 = 0,
    /// True when the widget survived a view generation change with an
    /// unacknowledged draft and has not been acknowledged by the new view yet.
    orphaned: bool = false,

    /// Prepares the widget's text buffer for one `igInputText` call: the buffer
    /// is NUL terminated and has at least one spare byte, because ImGui writes
    /// into it directly. Returns the writable pointer and the usable capacity.
    pub fn prepareBuffer(self: *Widget, gpa: std.mem.Allocator) struct { ptr: [*c]u8, capacity: usize } {
        const needed = self.buffer.items.len;
        if (self.buffer.capacity <= needed) {
            self.buffer.ensureTotalCapacity(gpa, needed + 1) catch {};
        }
        self.buffer.items.ptr[self.buffer.items.len] = 0;
        return .{ .ptr = self.buffer.items.ptr, .capacity = self.buffer.capacity };
    }

    /// Dear ImGui writes into the buffer in place, so the recorded length is
    /// refreshed from the NUL terminator before the text is read back.
    pub fn refreshFromBuffer(self: *Widget) void {
        if (self.buffer.capacity == 0) {
            self.buffer.items.len = 0;
            return;
        }

        const len = std.mem.sliceTo(self.buffer.items.ptr[0..self.buffer.capacity], 0).len;
        self.buffer.items.len = @min(len, self.buffer.capacity - 1);
    }

    pub fn text(self: *Widget) []const u8 {
        return self.buffer.items;
    }
};

pub const Overload = struct {
    code: protocol.OverloadCode,
    dropped: u64,
    detail: []const u8,
};

pub const Scene = struct {
    /// Arena holding the currently installed description. Swapped wholesale.
    arena: std.heap.ArenaAllocator,
    gpa: std.mem.Allocator,
    root: ?*const Node = null,
    ui_revision: u64 = 0,
    view_generation: u64 = 0,
    applied_snapshots: u64 = 0,
    widget_generation_clears: u64 = 0,
    widgets: std.ArrayListUnmanaged(*Widget) = .empty,
    widget_buffer_total: usize = 0,
    /// Counter of snapshots whose widget set required state creation.
    created_widgets: u64 = 0,
    removed_widgets: u64 = 0,
    stale_icarnation_rejects: u64 = 0,
    stale_revision_rejects: u64 = 0,
    deferred_replacements: u64 = 0,
    applied_replacements: u64 = 0,
    last_overload: ?Overload = null,
    overload_count: u64 = 0,
    dropped_events: u64 = 0,

    pub fn init(gpa: std.mem.Allocator) Scene {
        return .{
            .arena = std.heap.ArenaAllocator.init(gpa),
            .gpa = gpa,
        };
    }

    pub fn deinit(self: *Scene) void {
        for (self.widgets.items) |widget| destroyWidget(self.gpa, widget);
        self.widgets.deinit(self.gpa);
        self.arena.deinit();
    }

    pub fn allocator(self: *Scene) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Copies a decoded string into the snapshot arena, NUL terminated so that
    /// cimgui can consume it without an extra copy.
    pub fn dupeString(self: *Scene, bytes: []const u8) ![]const u8 {
        const copy = try self.arena.allocator().alloc(u8, bytes.len + 1);
        @memcpy(copy[0..bytes.len], bytes);
        copy[bytes.len] = 0;
        return copy[0..bytes.len];
    }

    pub fn adoptNode(self: *Scene, node: Node) !*Node {
        const stored = try self.arena.allocator().create(Node);
        stored.* = node;
        return stored;
    }

    /// Clears the arena, leaving widget state untouched. Used when a snapshot
    /// installs: the description is replaced, interaction state is not.
    pub fn resetDescription(self: *Scene) void {
        _ = self.arena.reset(.free_all);
        self.root = null;
    }

    /// Installs a prepared snapshot (already decoded into a temporary scene).
    ///
    /// Widget state is reconciled here, between frames:
    ///
    ///   * same view generation: widgets absent from the new description are
    ///     removed, releasing their buffers;
    ///   * new view generation (the view restarted): widgets with an
    ///     unacknowledged draft are kept as orphans so the new view can
    ///     reconcile them, everything else is removed.
    pub fn install(self: *Scene, prepared: *Scene, view_generation: u64, ui_revision: u64) void {
        const generation_changed = view_generation != self.view_generation;

        // Move the prepared description into the live scene: swap arenas. The
        // replaced description's arena ends up in `prepared` and is freed here,
        // so the caller can never free the live one by mistake.
        const replaced_arena = self.arena;
        self.arena = prepared.arena;
        self.root = prepared.root;
        prepared.root = null;
        replaced_arena.deinit();
        prepared.arena = std.heap.ArenaAllocator.init(prepared.gpa);

        self.view_generation = view_generation;
        self.ui_revision = ui_revision;
        self.applied_snapshots += 1;
        if (generation_changed) self.widget_generation_clears += 1;

        self.reconcileWidgets(generation_changed);
    }

    fn reconcileWidgets(self: *Scene, generation_changed: bool) void {
        const snapshot = self.applied_snapshots;
        var present = std.StringHashMap(u64).init(self.gpa);
        defer present.deinit();
        if (self.root) |root| collectWidgets(root, &present, self.gpa) catch {};

        var index: usize = 0;
        while (index < self.widgets.items.len) {
            const widget = self.widgets.items[index];
            const expected = present.get(widget.id);
            const matches = expected != null and expected.? == widget.incarnation;

            if (matches) {
                widget.orphaned = false;
                widget.last_seen_snapshot = snapshot;
                index += 1;
                continue;
            }

            const has_draft = widget.draft_revision > widget.ack_revision;
            if (generation_changed and has_draft) {
                // Surviving draft: keep the text so the replacement view can
                // reconcile it, but mark it as no longer backed by a declaration.
                widget.orphaned = true;
                widget.last_seen_snapshot = snapshot;
                index += 1;
                continue;
            }

            _ = self.widgets.swapRemove(index);
            self.removeWidget(widget);
        }

        var walker = present.iterator();
        while (walker.next()) |entry| {
            const id = entry.key_ptr.*;
            const incarnation = entry.value_ptr.*;
            const existing = self.findWidget(id);
            if (existing) |widget| {
                if (widget.incarnation != incarnation) {
                    // Same identity, new incarnation: the previous editor was
                    // deleted and recreated, so its state must not be reused.
                    _ = self.widgets.swapRemove(std.mem.indexOfScalar(*Widget, self.widgets.items, widget).?);
                    self.removeWidget(widget);
                    _ = self.createWidget(id, incarnation, snapshot);
                }
                continue;
            }
            _ = self.createWidget(id, incarnation, snapshot);
        }

        self.applySnapshotValues();
        self.reapOrphans();
    }

    fn createWidget(self: *Scene, id: []const u8, incarnation: u64, snapshot: u64) ?*Widget {
        if (self.widgets.items.len >= max_widget_buffers) return null;
        const widget = self.gpa.create(Widget) catch return null;
        const id_copy = self.gpa.dupe(u8, id) catch {
            self.gpa.destroy(widget);
            return null;
        };
        widget.* = .{
            .id = id_copy,
            .incarnation = incarnation,
            .last_seen_snapshot = snapshot,
        };
        self.widgets.append(self.gpa, widget) catch {
            self.gpa.free(id_copy);
            self.gpa.destroy(widget);
            return null;
        };
        self.created_widgets += 1;
        return widget;
    }

    fn removeWidget(self: *Scene, widget: *Widget) void {
        self.widget_buffer_total -= @min(self.widget_buffer_total, widget.buffer.capacity);
        self.removed_widgets += 1;
        destroyWidget(self.gpa, widget);
    }

    /// Orphans (kept only for reconciliation after a view restart) are dropped
    /// once the replacement view has acknowledged them, or when the buffer
    /// budget demands it.
    fn reapOrphans(self: *Scene) void {
        var index: usize = 0;
        while (index < self.widgets.items.len) {
            const widget = self.widgets.items[index];
            const settled = widget.orphaned and widget.ack_revision >= widget.draft_revision;
            const over_budget = self.widget_buffer_total > widget_buffer_bytes;
            if (settled or (widget.orphaned and over_budget)) {
                _ = self.widgets.swapRemove(index);
                self.removeWidget(widget);
                continue;
            }
            index += 1;
        }
    }

    pub fn findWidget(self: *Scene, id: []const u8) ?*Widget {
        for (self.widgets.items) |widget| {
            if (std.mem.eql(u8, widget.id, id)) return widget;
        }
        return null;
    }

    fn applySnapshotValues(self: *Scene) void {
        if (self.root) |root| self.applyNodeValues(root);
    }

    fn applyNodeValues(self: *Scene, node: *const Node) void {
        switch (node.kind) {
            .input => {
                if (self.findWidget(node.id)) |widget| {
                    self.proposeApplicationValue(widget, node.value);
                }
            },
            .row, .column => {
                for (node.children) |child| self.applyNodeValues(child);
            },
            .keyed => {
                for (node.keyed) |child| self.applyNodeValues(child.node);
            },
            else => {},
        }
    }

    /// Applies an application-supplied value to a widget.
    ///
    /// Conflict policy: while a local draft is unacknowledged, the newest
    /// application value is remembered and applied as soon as the draft is
    /// acknowledged or the editor loses focus. That keeps an in-progress edit
    /// (caret, selection, composition) intact and guarantees that a
    /// replacement never silently rewrites text the user is still typing.
    pub fn proposeApplicationValue(self: *Scene, widget: *Widget, value: []const u8) void {
        const draft_pending = widget.draft_revision > widget.ack_revision;
        if (draft_pending) {
            self.setDeferred(widget, value) catch {};
            self.deferred_replacements += 1;
            return;
        }
        self.applyValueDirect(widget, value) catch {};
        self.applied_replacements += 1;
    }

    fn applyValueDirect(self: *Scene, widget: *Widget, value: []const u8) !void {
        widget.applied_value.clearRetainingCapacity();
        try widget.applied_value.appendSlice(self.gpa, value);

        // Writing the same text back into a widget's buffer makes Dear ImGui
        // reload its user buffer and report the item as edited, which would turn
        // every snapshot into a fresh draft revision, event, and render. The
        // buffer is therefore only touched when the text actually differs.
        if (!std.mem.eql(u8, widget.text(), value)) {
            setBufferText(self.gpa, widget, value);
        }
    }

    fn setDeferred(self: *Scene, widget: *Widget, value: []const u8) !void {
        if (widget.pending_replacement == null) widget.pending_replacement = .empty;
        var pending = &widget.pending_replacement.?;
        pending.clearRetainingCapacity();
        try pending.appendSlice(self.gpa, value);
    }

    /// Acknowledges the highest draft revision Elixir accepted. Older
    /// acknowledgements and acknowledgements for another incarnation are
    /// rejected, so a delayed message can never move state backwards.
    pub fn acknowledge(self: *Scene, id: []const u8, incarnation: u64, revision: u64) AckOutcome {
        const widget = self.findWidget(id) orelse return .{ .outcome = .stale_incarnation };
        if (widget.incarnation != incarnation) {
            self.stale_icarnation_rejects += 1;
            return .{ .outcome = .stale_incarnation };
        }
        if (revision <= widget.ack_revision) {
            self.stale_revision_rejects += 1;
            return .{ .outcome = .stale_revision };
        }
        widget.ack_revision = revision;
        if (widget.ack_revision >= widget.draft_revision) {
            if (widget.pending_replacement) |pending| {
                self.applyValueDirect(widget, pending.items) catch {};
                widget.pending_replacement = null;
                self.applied_replacements += 1;
                return .{ .outcome = .applied_pending, .widget = widget };
            }
        }
        return .{ .outcome = .acknowledged, .widget = widget };
    }

    pub const AckOutcome = struct {
        outcome: enum { acknowledged, applied_pending, stale_revision, stale_incarnation },
        widget: ?*Widget = null,
    };

    /// Explicit programmatic change (`set_value`), routed through the same
    /// conflict policy as a snapshot value.
    pub fn setValue(self: *Scene, id: []const u8, incarnation: u64, text: []const u8) AckOutcome {
        const widget = self.findWidget(id) orelse return .{ .outcome = .stale_incarnation };
        if (widget.incarnation != incarnation) {
            self.stale_icarnation_rejects += 1;
            return .{ .outcome = .stale_incarnation };
        }
        self.proposeApplicationValue(widget, text);
        return .{ .outcome = .applied_pending, .widget = widget };
    }

    /// Records a native edit produced by the immediate-mode widget, bumping the
    /// draft revision. Called once per changed frame per widget.
    /// Whether a buffer change reported by Dear ImGui is a real user edit rather
    /// than the echo of a value the host itself just wrote into the buffer.
    ///
    /// The buffer length is refreshed first: Dear ImGui writes into the buffer in
    /// place, so `buffer.items.len` is stale until the host reads the text back,
    /// and comparing a stale length would silently discard every real edit.
    pub fn isUserEdit(self: *Scene, widget: *Widget) bool {
        _ = self;
        widget.refreshFromBuffer();
        return !std.mem.eql(u8, widget.text(), widget.applied_value.items);
    }

    pub fn noteLocalEdit(self: *Scene, widget: *Widget) void {
        widget.refreshFromBuffer();
        widget.draft_revision += 1;
        widget.applied_value.clearRetainingCapacity();
        widget.applied_value.appendSlice(self.gpa, widget.text()) catch {};
    }

    pub fn widgetsWithUnpublishedDrafts(self: *Scene, list: *std.ArrayListUnmanaged(*Widget)) void {
        for (self.widgets.items) |widget| {
            if (widget.draft_revision > widget.published_revision) {
                list.append(self.gpa, widget) catch {};
            }
        }
    }

    pub fn markDraftPublished(self: *Scene, widget: *Widget) void {
        widget.published_revision = widget.draft_revision;
        _ = self;
    }

    /// Signature of the native draft set: it changes exactly when some editor's
    /// draft *content* changed (a draft revision moved), not when an
    /// acknowledgement arrives. The host sends a `drafts` frame only when this
    /// signature or the view generation changes, which keeps the reconciliation
    /// handshake one-shot instead of once per snapshot.
    pub fn draftSignature(self: *Scene) u64 {
        var signature: u64 = 0xcbf2_9ce4_8422_2325;

        for (self.widgets.items) |widget| {
            signature ^= std.hash.Wyhash.hash(widget.incarnation, widget.id);
            signature *%= 0x100_0000_01b3;
            signature ^= widget.draft_revision;
            signature *%= 0x100_0000_01b3;
        }

        return signature;
    }

    /// Whether any editor holds text Elixir has not acknowledged yet.
    pub fn hasUnacknowledgedDrafts(self: *Scene) bool {
        for (self.widgets.items) |widget| {
            if (widget.draft_revision > widget.ack_revision) return true;
        }

        return false;
    }

    pub fn recordOverload(self: *Scene, code: protocol.OverloadCode, dropped: u64, detail: []const u8) void {
        self.overload_count += 1;
        self.dropped_events += dropped;
        self.last_overload = .{ .code = code, .dropped = dropped, .detail = detail };
    }

};

fn destroyWidget(gpa: std.mem.Allocator, widget: *Widget) void {
    gpa.free(widget.id);
    widget.buffer.deinit(gpa);
    widget.applied_value.deinit(gpa);
    if (widget.pending_replacement) |*pending| pending.deinit(gpa);
    gpa.destroy(widget);
}

fn setBufferText(gpa: std.mem.Allocator, widget: *Widget, text: []const u8) void {
    widget.buffer.clearRetainingCapacity();
    widget.buffer.appendSlice(gpa, text) catch return;

    // The NUL terminator is part of the buffer's contract: Dear ImGui reads and
    // writes it in place, and the host reads the text back through it. Without
    // it, stale bytes after the text look like extra content.
    if (widget.buffer.capacity <= widget.buffer.items.len) {
        widget.buffer.ensureTotalCapacity(gpa, widget.buffer.items.len + 1) catch return;
    }

    widget.buffer.items.ptr[widget.buffer.items.len] = 0;
}

fn collectWidgets(node: *const Node, out: *std.StringHashMap(u64), gpa: std.mem.Allocator) !void {
    switch (node.kind) {
        .button, .input => try out.put(node.id, node.incarnation),
        .row, .column => for (node.children) |child| try collectWidgets(child, out, gpa),
        .keyed => for (node.keyed) |child| try collectWidgets(child.node, out, gpa),
        else => {},
    }
}

test "acknowledgement cannot move state backwards" {
    var scene = Scene.init(std.testing.allocator);
    defer scene.deinit();
    const widget = scene.createWidget("editor", 1, 1).?;
    widget.draft_revision = 5;
    try std.testing.expectEqual(.acknowledged, scene.acknowledge("editor", 1, 5).outcome);
    try std.testing.expectEqual(.stale_revision, scene.acknowledge("editor", 1, 3).outcome);
    try std.testing.expectEqual(@as(u64, 5), widget.ack_revision);
}

test "acknowledgement for another incarnation is rejected" {
    var scene = Scene.init(std.testing.allocator);
    defer scene.deinit();
    _ = scene.createWidget("editor", 2, 1).?;
    try std.testing.expectEqual(.stale_incarnation, scene.acknowledge("editor", 1, 7).outcome);
}

test "a keyed reorder keeps widget state with its identity" {
    var scene = Scene.init(std.testing.allocator);
    defer scene.deinit();
    const alpha = scene.createWidget("editor/alpha", 1, 1).?;
    try alpha.buffer.appendSlice(scene.gpa, "hello from alpha");
    try std.testing.expectEqualStrings("hello from alpha", scene.findWidget("editor/alpha").?.buffer.items);
    try std.testing.expectEqual(alpha, scene.findWidget("editor/alpha").?);
}

test "draft signature changes with draft content and not with acknowledgements" {
    var scene = Scene.init(std.testing.allocator);
    defer scene.deinit();
    const widget = scene.createWidget("editor/alpha", 1, 1).?;

    const initial = scene.draftSignature();
    try std.testing.expectEqual(initial, scene.draftSignature());

    widget.draft_revision = 1;
    const after_draft = scene.draftSignature();
    try std.testing.expect(after_draft != initial);

    widget.ack_revision = 1;
    try std.testing.expectEqual(after_draft, scene.draftSignature());
    try std.testing.expect(!scene.hasUnacknowledgedDrafts());

    widget.draft_revision = 2;
    try std.testing.expect(scene.hasUnacknowledgedDrafts());
}

test "rewriting the same value does not touch the buffer" {
    var scene = Scene.init(std.testing.allocator);
    defer scene.deinit();
    const widget = scene.createWidget("editor/alpha", 1, 1).?;

    try scene.applyValueDirect(widget, "same text");
    const pointer_before = widget.text().ptr;

    try scene.applyValueDirect(widget, "same text");
    try std.testing.expectEqual(pointer_before, widget.text().ptr);
    try std.testing.expect(!scene.isUserEdit(widget));

    // A genuine edit differs from the value the framework knows about.
    setBufferText(std.testing.allocator, widget, "edited");
    try std.testing.expect(scene.isUserEdit(widget));
}

test "an edit is detected even when the buffer length is stale" {
    var scene = Scene.init(std.testing.allocator);
    defer scene.deinit();
    const widget = scene.createWidget("editor/alpha", 1, 1).?;

    try scene.applyValueDirect(widget, "Bravo");
    try std.testing.expect(!scene.isUserEdit(widget));

    // Dear ImGui writes into the user buffer in place; the recorded length only
    // changes when the host reads the text back.
    const buffer = widget.prepareBuffer(std.testing.allocator);
    @memcpy(buffer.ptr[0..8], "Bravo-XY");
    buffer.ptr[8] = 0;

    try std.testing.expect(scene.isUserEdit(widget));
    scene.noteLocalEdit(widget);
    try std.testing.expectEqualStrings("Bravo-XY", widget.text());
    try std.testing.expectEqual(@as(u64, 1), widget.draft_revision);
    try std.testing.expect(!scene.isUserEdit(widget));
}
