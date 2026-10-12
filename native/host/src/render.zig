//! Immediate-mode evaluation of the cached UI description.
//!
//! Runs once per native frame on the host's main thread and never calls back
//! into Elixir: it walks the installed description, emits cimgui calls, and
//! records the semantic commands the frame produced (button clicks, text
//! edits). The caller encodes and publishes those commands after the frame.
//!
//! Identity rules implemented here:
//!   * every interactive widget is drawn inside an `igPushID_Str` scope built
//!     from its explicit application key, so its ImGui ID — and with it ImGui's
//!     cached text state, caret, and selection — follows the key rather than
//!     the widget's position in its parent;
//!   * keyed collections push one ID scope per key, so unkeyed descendants of a
//!     reordered key stay bound to that key;
//!   * labels are display text only and may change without changing identity.

const std = @import("std");
const protocol = @import("protocol.zig");
const scene_mod = @import("scene.zig");
const imgui = @import("cimgui.zig").c;

const Scene = scene_mod.Scene;
const Node = protocol.Node;

pub const max_commands: usize = 512;
pub const max_rects: usize = 64;
pub const max_rect_id_bytes: usize = 128;

pub const Command = union(enum) {
    button_click: struct { id: []const u8, incarnation: u64, event: []const u8 },
    input_edit: struct { id: []const u8, incarnation: u64, draft_revision: u64, text: []const u8 },
    input_submit: struct { id: []const u8, incarnation: u64, draft_revision: u64, text: []const u8 },
};

/// Screen rectangle of an interactive item submitted during the last frame.
/// Copied by value so nothing outlives the frame that produced it.
pub const Rect = struct {
    id: [max_rect_id_bytes]u8 = [_]u8{0} ** max_rect_id_bytes,
    id_len: usize = 0,
    min_x: f32 = 0,
    min_y: f32 = 0,
    max_x: f32 = 0,
    max_y: f32 = 0,

    pub fn idSlice(self: *const Rect) []const u8 {
        return self.id[0..self.id_len];
    }
};

/// Host state the diagnostics node displays. Every value is read from the host
/// itself, so the window stays truthful while an Elixir callback is stalled.
pub const Diagnostics = struct {
    frame_count: u64 = 0,
    ui_revision: u64 = 0,
    view_generation: u64 = 0,
    applied_snapshots: u64 = 0,
    outbound_frames: u32 = 0,
    outbound_bytes: u32 = 0,
    overloads: u64 = 0,
    dropped: u64 = 0,
    uptime_ms: u64 = 0,
    focused_id: []const u8 = "",
    focused_draft_revision: u64 = 0,
    focused_ack_revision: u64 = 0,
};

pub const Context = struct {
    gpa: std.mem.Allocator,
    commands: *std.ArrayListUnmanaged(Command),
    rects: *std.ArrayListUnmanaged(Rect),
    diagnostics: Diagnostics = .{},
    /// Commands not recorded because the per-frame bound was reached. Reported
    /// through overload diagnostics; never silently swallowed.
    dropped_commands: u64 = 0,

    fn push(self: *Context, command: Command) void {
        if (self.commands.items.len >= max_commands) {
            self.dropped_commands += 1;
            return;
        }
        self.commands.append(self.gpa, command) catch {
            self.dropped_commands += 1;
        };
    }

    fn recordRect(self: *Context, id: []const u8) void {
        if (self.rects.items.len >= max_rects) return;
        const min = imgui.igGetItemRectMin();
        const max = imgui.igGetItemRectMax();
        var rect = Rect{
            .min_x = min.x,
            .min_y = min.y,
            .max_x = max.x,
            .max_y = max.y,
        };
        const len = @min(id.len, max_rect_id_bytes);
        @memcpy(rect.id[0..len], id[0..len]);
        rect.id_len = len;
        self.rects.append(self.gpa, rect) catch {};
    }
};

/// Draws the whole description inside one window.
/// The single window a view renders into.
///
/// The platform window *is* the window the user sees: it carries the title (in
/// the platform's own title bar, on the task bar, and to the window manager) and
/// this panel fills its client area exactly — no inset, no drift, and no second
/// title bar restating what the platform title bar already says. Position and
/// size are set on every frame (`Cond_Always`) from the drawable size, so the
/// panel is flush after a resize too, and the title string is used only as the
/// Dear ImGui window id. Movement and resizing are the platform's job, which is
/// why the panel refuses both.
fn windowFlags() c_int {
    return imgui.ImGuiWindowFlags_NoTitleBar |
        imgui.ImGuiWindowFlags_NoResize |
        imgui.ImGuiWindowFlags_NoMove |
        imgui.ImGuiWindowFlags_NoCollapse |
        imgui.ImGuiWindowFlags_NoSavedSettings |
        imgui.ImGuiWindowFlags_NoBringToFrontOnFocus;
}

pub fn drawWindow(scene: *Scene, ctx: *Context, title: [*:0]const u8, width: f32, height: f32) void {
    imgui.igSetNextWindowPos(.{ .x = 0, .y = 0 }, imgui.ImGuiCond_Always, .{ .x = 0, .y = 0 });
    imgui.igSetNextWindowSize(.{ .x = width, .y = height }, imgui.ImGuiCond_Always);

    if (!imgui.igBegin(title, null, windowFlags())) {
        imgui.igEnd();
        return;
    }
    defer imgui.igEnd();

    imgui.igText(
        "ui revision %d   view generation %d   snapshots %d",
        ctx.diagnostics.ui_revision,
        ctx.diagnostics.view_generation,
        ctx.diagnostics.applied_snapshots,
    );

    if (scene.root) |root| {
        imgui.igSeparator();
        drawNode(scene, ctx, root);
    } else {
        imgui.igTextUnformatted("waiting for the first description", null);
    }
}

fn drawNode(scene: *Scene, ctx: *Context, node: *const Node) void {
    switch (node.kind) {
        .text => imgui.igTextUnformatted(z(node.text), null),
        .button => drawButton(ctx, node),
        .input => drawInput(scene, ctx, node),
        .row => drawRow(scene, ctx, node.children),
        .column => drawColumn(scene, ctx, node.children),
        .keyed => drawKeyed(scene, ctx, node),
        .diagnostics => drawDiagnostics(scene, ctx),
    }
}

fn drawRow(scene: *Scene, ctx: *Context, children: []const *Node) void {
    for (children, 0..) |child, index| {
        if (index > 0) imgui.igSameLine(0, 8);
        drawNode(scene, ctx, child);
    }
}

fn drawColumn(scene: *Scene, ctx: *Context, children: []const *Node) void {
    for (children) |child| drawNode(scene, ctx, child);
}

fn drawKeyed(scene: *Scene, ctx: *Context, node: *const Node) void {
    for (node.keyed) |child| {
        // The key is the identity scope: it survives reordering because it is
        // application data, not a position.
        imgui.igPushID_Str(z(child.key));
        defer imgui.igPopID();
        drawNode(scene, ctx, child.node);
    }
}

fn drawButton(ctx: *Context, node: *const Node) void {
    imgui.igPushID_Str(z(node.id));
    defer imgui.igPopID();

    const clicked = imgui.igButton(z(node.text), .{ .x = 0, .y = 0 });
    ctx.recordRect(node.id);
    if (clicked) {
        ctx.push(.{ .button_click = .{
            .id = node.id,
            .incarnation = node.incarnation,
            .event = node.event,
        } });
    }
}

fn drawInput(scene: *Scene, ctx: *Context, node: *const Node) void {
    const widget = scene.findWidget(node.id) orelse {
        imgui.igTextUnformatted("(editor state unavailable)", null);
        return;
    };
    if (widget.incarnation != node.incarnation) {
        // A description for a newer incarnation has not been reconciled yet:
        // draw nothing rather than editing the previous incarnation's buffer.
        imgui.igTextUnformatted("(editor awaiting incarnation change)", null);
        return;
    }

    imgui.igPushID_Str(z(node.id));
    defer imgui.igPopID();

    if (node.text.len > 0) imgui.igTextUnformatted(z(node.text), null);

    const buffer = widget.prepareBuffer(scene.gpa);
    imgui.igPushItemWidth(-1);
    // The label is hidden ("##"): the editor's identity comes from the explicit
    // id scope above, and its visible name is the label text drawn as a node.
    const changed = imgui.igInputText(z(hidden_label), buffer.ptr, buffer.capacity, imgui.ImGuiInputTextFlags_None, null, null);
    imgui.igPopItemWidth();
    ctx.recordRect(node.id);

    const active = imgui.igIsItemActive();
    const focused = imgui.igIsItemFocused();
    widget.active = active;
    widget.focused = focused;
    const item_id = imgui.igGetItemID();

    if (changed and scene.isUserEdit(widget)) {
        scene.noteLocalEdit(widget);
        ctx.push(.{ .input_edit = .{
            .id = node.id,
            .incarnation = widget.incarnation,
            .draft_revision = widget.draft_revision,
            .text = widget.text(),
        } });
    }

    if (focused) {
        ctx.diagnostics.focused_id = node.id;
        ctx.diagnostics.focused_draft_revision = widget.draft_revision;
        ctx.diagnostics.focused_ack_revision = widget.ack_revision;
        captureCaretAndSelection(widget, item_id);
        if (imgui.igIsKeyPressed_Bool(imgui.ImGuiKey_Enter, false)) {
            ctx.push(.{ .input_submit = .{
                .id = node.id,
                .incarnation = widget.incarnation,
                .draft_revision = widget.draft_revision,
                .text = widget.text(),
            } });
        }
    }
}

/// Reads the caret and selection of a focused editor through cimgui's
/// input-text-state accessors. Values are ImGui byte offsets, which is exactly
/// the unit a keyed reorder must preserve.
fn captureCaretAndSelection(widget: *scene_mod.Widget, item_id: u32) void {
    const state = imgui.igGetInputTextState(item_id) orelse return;
    widget.cursor = clampToU32(imgui.ImGuiInputTextState_GetCursorPos(state));
    widget.selection = .{
        clampToU32(imgui.ImGuiInputTextState_GetSelectionStart(state)),
        clampToU32(imgui.ImGuiInputTextState_GetSelectionEnd(state)),
    };
}

fn clampToU32(value: c_int) u32 {
    return @intCast(@max(value, 0));
}

fn drawDiagnostics(scene: *Scene, ctx: *Context) void {
    const diagnostics = ctx.diagnostics;
    imgui.igSeparator();
    imgui.igText("native frames: %d", asInt(diagnostics.frame_count));
    imgui.igText("native uptime ms: %d", asInt(diagnostics.uptime_ms));
    imgui.igText("applied ui revision: %d   view generation: %d", diagnostics.ui_revision, diagnostics.view_generation);
    imgui.igText(
        "outbound queue: %d frames / %d bytes   overloads: %d   dropped: %d",
        diagnostics.outbound_frames,
        diagnostics.outbound_bytes,
        asInt(diagnostics.overloads),
        asInt(diagnostics.dropped),
    );
    imgui.igText(
        "focused editor draft revision: %d   acknowledged: %d",
        asInt(diagnostics.focused_draft_revision),
        asInt(diagnostics.focused_ack_revision),
    );
    imgui.igText("editors (%d):", asInt(scene.widgets.items.len));
    for (scene.widgets.items) |widget| {
        imgui.igText(
            "  %s  incarnation %d  draft %d  ack %d  chars %d",
            z(widget.id),
            widget.incarnation,
            widget.draft_revision,
            widget.ack_revision,
            asInt(widget.text().len),
        );
    }
}

fn asInt(value: anytype) c_int {
    return @intCast(@min(@as(u64, value), std.math.maxInt(c_int)));
}

/// Hidden label for interactive widgets: `##` makes Dear ImGui use the string
/// for identity only, so nothing extra is displayed next to the widget.
const hidden_label = "##value";

fn z(bytes: []const u8) [*c]const u8 {
    // Scene strings are NUL terminated by construction (see Scene.dupeString and
    // Widget.prepareBuffer), so the pointer can be handed to cimgui directly.
    return bytes.ptr;
}
