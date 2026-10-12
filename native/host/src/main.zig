//! live_cimgui native host.
//!
//! One process, one window, one thread that owns SDL and OpenGL:
//!
//!   * the main thread runs the platform event loop, evaluates the cached UI
//!     description through cimgui on every frame, and draws — this is the only
//!     thread allowed to touch the platform, because SDL requires its video
//!     calls on the process main thread;
//!   * one IO thread (see `transport.zig`) owns the socket to the BEAM.
//!
//! The host never calls into Elixir to draw. Elixir sends complete descriptions
//! and acknowledges drafts; the host renders whatever description it last
//! accepted, at its own frame rate, whether or not Elixir is busy.

const std = @import("std");
const protocol = @import("protocol.zig");
const scene_mod = @import("scene.zig");
const render = @import("render.zig");
const platform_mod = @import("platform.zig");
const transport_mod = @import("transport.zig");

const Scene = scene_mod.Scene;
const Platform = platform_mod.Platform;
const Transport = transport_mod.Transport;

const diagnostics_interval_frames: u64 = 30;
const frame_budget_ms: u64 = 16;

const Host = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    transport: *Transport,
    scene: Scene,
    scratch: Scene,
    platform: ?Platform = null,
    commands: std.ArrayListUnmanaged(render.Command) = .empty,
    rects: std.ArrayListUnmanaged(render.Rect) = .empty,
    session_id: [64]u8 = [_]u8{0} ** 64,
    session_len: usize = 0,
    title: [256]u8 = [_]u8{0} ** 256,
    view_generation: u64 = 0,
    host_generation: u64 = 0,
    frame_count: u64 = 0,
    drafts_generation: u64 = 0,
    drafts_signature: u64 = 0,
    running: bool = true,
    exit_code: u8 = 0,
    window_close_sent: bool = false,
    capture_path: [protocol.max_path_bytes]u8 = undefined,
    capture_len: usize = 0,
    capture_pending: bool = false,
    dpi_scale: f64 = 0,

    fn sessionSlice(self: *Host) []const u8 {
        return self.session_id[0..self.session_len];
    }

    fn deinit(self: *Host) void {
        self.commands.deinit(self.gpa);
        self.rects.deinit(self.gpa);
        self.scene.deinit();
        self.scratch.deinit();
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    const socket_path = parseSocketPath(args) orelse {
        std.debug.print("live_cimgui_host: missing --socket <path>\n", .{});
        std.process.exit(2);
    };

    const transport = Transport.connect(io, gpa, socket_path) catch |err| {
        std.debug.print("live_cimgui_host: cannot connect to {s}: {s}\n", .{ socket_path, @errorName(err) });
        std.process.exit(2);
    };

    var host = Host{
        .gpa = gpa,
        .io = io,
        .transport = transport,
        .scene = Scene.init(gpa),
        .scratch = Scene.init(gpa),
    };
    defer host.deinit();
    defer transport.close();

    run(&host) catch |err| {
        std.debug.print("live_cimgui_host: fatal: {s}\n", .{@errorName(err)});
        sendBye(&host, 1, @errorName(err));
        std.process.exit(3);
    };

    sendBye(&host, 0, "closed");
    std.process.exit(host.exit_code);
}

fn parseSocketPath(args: []const [:0]const u8) ?[]const u8 {
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--socket") and index + 1 < args.len) {
            return args[index + 1];
        }
    }
    return null;
}

fn run(host: *Host) !void {
    var last_frame_ms: u64 = platform_mod.nowMillis();
    while (host.running) {
        drainInbound(host) catch |err| {
            std.debug.print("live_cimgui_host: protocol handling failed: {s}\n", .{@errorName(err)});
            return err;
        };

        if (host.platform == null) {
            // Waiting for `hello`, which carries the window title and size.
            platform_mod.sleepMillis(5);
            continue;
        }

        var platform = &host.platform.?;

    if (host.dpi_scale == 0) {
        host.dpi_scale = platform.framebufferScale();
        platform.applyDpiScale(host.dpi_scale);
    }
        var event: platform_mod.Event = undefined;
        while (platform.poll(&event)) {
            switch (event.type) {
                platform_mod.SDL_QUIT => try requestWindowClose(host),
                platform_mod.SDL_WINDOWEVENT => {
                    if (event.window.event == platform_mod.SDL_WINDOWEVENT_CLOSE) try requestWindowClose(host);
                },
                platform_mod.SDL_KEYDOWN => {
                    if (event.key.keysym.sym == platform_mod.SDLK_ESCAPE) try requestWindowClose(host);
                },
                else => {},
            }
        }
        if (!host.running) break;

        drawFrame(host) catch |err| {
            std.debug.print("live_cimgui_host: draw failed: {s}\n", .{@errorName(err)});
            return err;
        };

        drainOutbound(host) catch |err| {
            std.debug.print("live_cimgui_host: publish failed: {s}\n", .{@errorName(err)});
            return err;
        };

        // Frame pacing: vsync is requested, but WSLg and some drivers ignore it,
        // so the loop also keeps its own budget.
        const elapsed = platform_mod.nowMillis() - last_frame_ms;
        if (elapsed < frame_budget_ms and host.frame_count % 4 != 0) {
            platform_mod.sleepMillis(frame_budget_ms - elapsed);
        }
        last_frame_ms = platform_mod.nowMillis();
    }
}

fn drawFrame(host: *Host) !void {
    var platform = &host.platform.?;

    if (host.dpi_scale == 0) {
        host.dpi_scale = platform.framebufferScale();
        platform.applyDpiScale(host.dpi_scale);
    }
    host.commands.clearRetainingCapacity();
    host.rects.clearRetainingCapacity();

    host.frame_count += 1;
    const depth = host.transport.queueDepth();

    var ctx = render.Context{
        .gpa = host.gpa,
        .commands = &host.commands,
        .rects = &host.rects,
        .diagnostics = .{
            .frame_count = host.frame_count,
            .ui_revision = host.scene.ui_revision,
            .view_generation = host.scene.view_generation,
            .applied_snapshots = host.scene.applied_snapshots,
            .outbound_frames = depth.frames,
            .outbound_bytes = depth.bytes,
            .overloads = host.transport.overloads,
            .dropped = host.transport.dropped_outbound + host.transport.dropped_inbound,
            .uptime_ms = platform.uptimeMillis(),
        },
    };

    const capture: ?[]const u8 = if (host.capture_pending) host.capture_path[0..host.capture_len] else null;
    host.capture_pending = false;

    // The panel is the window: it takes the window's logical size every frame, so
    // a resize or a move to a display with another scale cannot leave it inset.
    const scale = platform.framebufferScale();
    if (@abs(scale - host.dpi_scale) > 0.01) {
        platform.applyDpiScale(scale);
        host.dpi_scale = scale;
    }

    const window_size = platform.windowSize();

    platform.beginFrame();
    render.drawWindow(
        &host.scene,
        &ctx,
        @ptrCast(&host.title),
        @floatFromInt(@max(window_size.width, 1)),
        @floatFromInt(@max(window_size.height, 1)),
    );
    platform.endFrame(capture);

    if (ctx.dropped_commands > 0) {
        host.transport.recordOverload(.outbound_full, ctx.dropped_commands, "per-frame command bound reached");
    }
}

fn drainOutbound(host: *Host) !void {
    for (host.commands.items) |command| {
        var buffer: [protocol.max_frame_bytes]u8 = undefined;
        const coalesce_key = encodeCommand(&buffer, host, command) orelse continue;
        host.transport.enqueue(coalesce_key.frame, coalesce_key.key) catch {};
    }
    host.commands.clearRetainingCapacity();

    // Publish native diagnostics periodically so Elixir can expose queue
    // pressure without polling the host per frame.
    if (host.frame_count % diagnostics_interval_frames == 0) {
        var buffer: [4096]u8 = undefined;
        const frame = encodeDiagnostics(&buffer, host);
        host.transport.enqueue(frame, null) catch {};
    }
}

const Encoded = struct { frame: []const u8, key: ?[]const u8 };

fn encodeCommand(buffer: []u8, host: *Host, command: render.Command) ?Encoded {
    var writer = protocol.Writer.init(buffer);
    switch (command) {
        .button_click => |click| {
            writer.put64(host.scene.view_generation) catch return null;
            writer.put64(host.scene.ui_revision) catch return null;
            writer.put8(@intFromEnum(protocol.EventKind.button_click)) catch return null;
            writer.string(click.id) catch return null;
            writer.put64(click.incarnation) catch return null;
            writer.string(click.event) catch return null;
            return .{ .frame = writer.finish(.event), .key = null };
        },
        .input_edit => |edit| {
            writer.put64(host.scene.view_generation) catch return null;
            writer.put64(host.scene.ui_revision) catch return null;
            writer.put8(@intFromEnum(protocol.EventKind.input_edit)) catch return null;
            writer.string(edit.id) catch return null;
            writer.put64(edit.incarnation) catch return null;
            writer.put64(edit.draft_revision) catch return null;
            writer.string(edit.text) catch return null;
            const frame = writer.finish(.event);
            return .{ .frame = frame, .key = edit.id };
        },
        .input_submit => |submit| {
            writer.put64(host.scene.view_generation) catch return null;
            writer.put64(host.scene.ui_revision) catch return null;
            writer.put8(@intFromEnum(protocol.EventKind.input_submit)) catch return null;
            writer.string(submit.id) catch return null;
            writer.put64(submit.incarnation) catch return null;
            writer.put64(submit.draft_revision) catch return null;
            writer.string(submit.text) catch return null;
            const frame = writer.finish(.event);
            return .{ .frame = frame, .key = submit.id };
        },
    }
}

fn encodeDiagnostics(buffer: []u8, host: *Host) []u8 {
    var writer = protocol.Writer.init(buffer);
    const depth = host.transport.queueDepth();
    writer.put64(host.frame_count) catch {};
    writer.put64(host.scene.ui_revision) catch {};
    writer.put64(host.scene.view_generation) catch {};
    writer.string(focusedId(host)) catch {};
    writeDraftSummaries(&writer, host);
    writer.put32(depth.frames) catch {};
    writer.put64(host.transport.overloads) catch {};
    writer.put64(host.transport.dropped_inbound + host.transport.dropped_outbound) catch {};
    writer.put64(if (host.platform) |*platform| platform.uptimeMillis() else 0) catch {};

    // Native geometry: the logical window size and the drawable/logical ratio.
    // Together they describe exactly what a framebuffer capture must contain,
    // at any display scale.
    if (host.platform) |*platform| {
        const window = platform.windowSize();
        writer.put32(window.width) catch {};
        writer.put32(window.height) catch {};
        writer.putFloat(platform.framebufferScale()) catch {};
    } else {
        writer.put32(0) catch {};
        writer.put32(0) catch {};
        writer.putFloat(1.0) catch {};
    }
    return writer.finish(.diagnostics);
}

fn focusedId(host: *Host) []const u8 {
    for (host.scene.widgets.items) |widget| {
        if (widget.focused) return widget.id;
    }
    return "";
}

fn writeDraftSummaries(writer: *protocol.Writer, host: *Host) void {
    const count: u32 = @intCast(@min(host.scene.widgets.items.len, render.max_rects * 4));
    writer.put32(count) catch return;
    for (host.scene.widgets.items[0..count]) |widget| {
        writer.string(widget.id) catch return;
        writer.put64(widget.incarnation) catch return;
        writer.put64(widget.draft_revision) catch return;
        writer.put64(widget.ack_revision) catch return;
    }
}

fn drainInbound(host: *Host) !void {
    while (host.transport.dequeue()) |entry| {
        defer host.transport.releaseInbound(entry);
        const message = protocol.decode(entry.type_code, entry.body, &host.scratch) catch |err| {
            std.debug.print("live_cimgui_host: rejected type {d} ({d} bytes): {s}\n", .{ entry.type_code, entry.body.len, @errorName(err) });
            host.transport.recordOverload(.malformed_frame, 1, @errorName(err));
            continue;
        };
        try handleMessage(host, message);
    }
}

fn handleMessage(host: *Host, message: protocol.Message) !void {
    switch (message) {
        .hello => |hello| try handleHello(host, hello),
        .snapshot => |snapshot| try applySnapshot(host, snapshot),
        .ack => |ack| {
            if (ack.view_generation != host.scene.view_generation) {
                host.transport.recordOverload(.stale_generation, 1, "ack from another view generation");
                return;
            }

            switch (host.scene.acknowledge(ack.id, ack.incarnation, ack.acked_revision).outcome) {
                // Rejections are reported rather than silently ignored: a caller
                // can see that its update was refused and why.
                .stale_incarnation => host.transport.recordOverload(.stale_incarnation, 1, "ack for another incarnation"),
                .stale_revision => host.transport.recordOverload(.stale_revision, 1, "ack older than the acknowledged revision"),
                else => {},
            }
        },
        .set_value => |set| {
            if (set.view_generation != host.scene.view_generation) {
                host.transport.recordOverload(.stale_generation, 1, "set_value from another view generation");
                return;
            }

            switch (host.scene.setValue(set.id, set.incarnation, set.text).outcome) {
                .stale_incarnation => host.transport.recordOverload(.stale_incarnation, 1, "set_value for another incarnation"),
                else => {},
            }
        },
        .inspect => |request_id| try sendInspect(host, request_id),
        .ping => |request_id| sendPong(host, request_id),
        .shutdown => |reason| {
            std.debug.print("live_cimgui_host: shutdown requested ({s})\n", .{@tagName(reason)});
            host.running = false;
        },
        .test_input => |input| try injectTestInput(host, input),
        .fault => |fault| try injectFault(host, fault),
    }
}

fn handleHello(host: *Host, hello: protocol.Hello) !void {
    if (host.platform != null) {
        if (!std.mem.eql(u8, hello.session_id, host.sessionSlice())) {
            host.transport.recordOverload(.stale_session, 1, "hello from another session");
            return;
        }
    }

    const len = @min(hello.session_id.len, host.session_id.len);
    @memcpy(host.session_id[0..len], hello.session_id[0..len]);
    host.session_len = len;
    host.view_generation = hello.view_generation;
    host.host_generation = hello.host_generation;

    const title_len = @min(hello.title.len, host.title.len - 1);
    @memcpy(host.title[0..title_len], hello.title[0..title_len]);
    host.title[title_len] = 0;

    if (host.platform == null) {
        const width = if (hello.width == 0) 940 else hello.width;
        const height = if (hello.height == 0) 620 else hello.height;
        host.platform = Platform.open(@ptrCast(&host.title), width, height) catch |err| {
            std.debug.print("live_cimgui_host: cannot open window: {s}\n", .{@errorName(err)});
            sendProtocolError(host, 1, "window initialization failed");
            host.running = false;
            return err;
        };
        std.debug.print(
            "live_cimgui_host: window open (session {s}, generation {d}, {s})\n",
            .{ host.sessionSlice(), host.view_generation, host.platform.?.backend_name },
        );
    } else if (host.platform) |*platform| {
        platform.setTitle(@ptrCast(&host.title));
        platform.raise();
    }

    sendReady(host);
}

fn applySnapshot(host: *Host, snapshot: protocol.Snapshot) !void {
    if (snapshot.view_generation < host.scene.view_generation) {
        host.transport.recordOverload(.stale_generation, 1, "snapshot from an older view generation");
        return;
    }

    // The scratch scene already holds the decoded description; install it
    // atomically and recycle the replaced arena.
    host.scratch.root = snapshot.tree;
    host.scene.install(&host.scratch, snapshot.view_generation, snapshot.ui_revision);
    host.view_generation = snapshot.view_generation;

    // Reconciliation is a handshake, not a heartbeat: a `drafts` frame goes out
    // once per view generation and once per draft-content change. Sending it on
    // every snapshot would make a view that re-renders on every message loop.
    const signature = host.scene.draftSignature();

    if (host.scene.view_generation != host.drafts_generation or signature != host.drafts_signature) {
        host.drafts_generation = host.scene.view_generation;
        host.drafts_signature = signature;

        if (host.scene.widgets.items.len > 0) {
            var buffer: [protocol.max_frame_bytes]u8 = undefined;
            const frame = encodeDrafts(&buffer, host);
            host.transport.enqueue(frame, null) catch {};
        }
    }
}

/// Full native drafts, so a restarted or reconciling view learns what the
/// window is holding before it publishes anything.
fn encodeDrafts(buffer: []u8, host: *Host) []u8 {
    var writer = protocol.Writer.init(buffer);
    writer.put64(host.scene.view_generation) catch {};
    const count: u32 = @intCast(host.scene.widgets.items.len);
    writer.put32(count) catch {};
    for (host.scene.widgets.items) |widget| {
        writer.string(widget.id) catch break;
        writer.put64(widget.incarnation) catch break;
        writer.put64(widget.draft_revision) catch break;
        writer.put64(widget.ack_revision) catch break;
        writer.string(widget.text()) catch break;
    }
    return writer.finish(.drafts);
}

fn sendReady(host: *Host) void {
    var buffer: [1024]u8 = undefined;
    var writer = protocol.Writer.init(&buffer);
    const platform = &(host.platform orelse return);
    writer.string(host.sessionSlice()) catch return;
    writer.put64(host.host_generation) catch return;
    writer.put64(host.scene.view_generation) catch return;
    writer.string(platform.sdlVersion()) catch return;
    writer.string(platform.glRenderer()) catch return;
    writer.string("OpenGL 3.3 core") catch return;
    writer.put64(@intCast(std.os.linux.getpid())) catch return;
    host.transport.enqueue(writer.finish(.ready), null) catch {};
}

fn sendPong(host: *Host, request_id: u64) void {
    var buffer: [64]u8 = undefined;
    var writer = protocol.Writer.init(&buffer);
    writer.put64(request_id) catch return;
    host.transport.enqueue(writer.finish(.pong), null) catch {};
}

fn sendBye(host: *Host, code: u8, detail: []const u8) void {
    var buffer: [512]u8 = undefined;
    var writer = protocol.Writer.init(&buffer);
    writer.put8(code) catch return;
    writer.string(detail) catch return;
    host.transport.enqueue(writer.finish(.bye), null) catch {};
}

fn sendProtocolError(host: *Host, code: u8, detail: []const u8) void {
    var buffer: [512]u8 = undefined;
    var writer = protocol.Writer.init(&buffer);
    writer.put8(code) catch return;
    writer.string(detail) catch return;
    host.transport.enqueue(writer.finish(.protocol_error), null) catch {};
}

fn sendInspect(host: *Host, request_id: u64) !void {
    var buffer: [protocol.max_frame_bytes]u8 = undefined;
    var writer = protocol.Writer.init(&buffer);
    const platform = &(host.platform orelse return);

    writer.put64(request_id) catch {};
    writer.put64(host.frame_count) catch {};
    writer.put64(host.scene.ui_revision) catch {};
    writer.put64(host.scene.view_generation) catch {};
    writer.string(focusedId(host)) catch {};

    const widget_count: u32 = @intCast(host.scene.widgets.items.len);
    writer.put32(widget_count) catch {};
    for (host.scene.widgets.items) |widget| {
        writer.string(widget.id) catch break;
        writer.put64(widget.incarnation) catch break;
        writer.put64(widget.draft_revision) catch break;
        writer.put64(widget.ack_revision) catch break;
        writer.put8(if (widget.active) 1 else 0) catch break;
        writer.put32(widget.cursor) catch break;
        writer.put32(widget.selection[0]) catch break;
        writer.put32(widget.selection[1]) catch break;
        writer.string(widget.text()) catch break;
    }

    // Geometry of the interactive items submitted in the last frame, so tests
    // can drive real pointer input to a named widget instead of guessing.
    const rect_count: u32 = @intCast(host.rects.items.len);
    writer.put32(rect_count) catch {};
    for (host.rects.items) |rect| {
        writer.string(rect.idSlice()) catch break;
        writer.putFloat(rect.min_x) catch break;
        writer.putFloat(rect.min_y) catch break;
        writer.putFloat(rect.max_x) catch break;
        writer.putFloat(rect.max_y) catch break;
    }

    writer.put64(platform.uptimeMillis()) catch {};
    host.transport.enqueue(writer.finish(.inspect_result), null) catch {};
}

fn requestWindowClose(host: *Host) !void {
    if (host.window_close_sent) return;
    host.window_close_sent = true;
    var buffer: [64]u8 = undefined;
    var writer = protocol.Writer.init(&buffer);
    writer.put64(host.scene.view_generation) catch {};
    writer.put64(host.scene.ui_revision) catch {};
    writer.put8(@intFromEnum(protocol.EventKind.window_close)) catch {};
    host.transport.enqueue(writer.finish(.event), null) catch {};
    sendBye(host, 0, "window closed");
    host.running = false;
}

fn injectTestInput(host: *Host, input: protocol.TestInput) !void {
    const platform = &(host.platform orelse return);
    switch (input) {
        .text => |text| {
            var buffer: [protocol.max_text_bytes + 1]u8 = undefined;
            const len = @min(text.len, protocol.max_text_bytes);
            @memcpy(buffer[0..len], text[0..len]);
            buffer[len] = 0;
            platform.injectText(@ptrCast(&buffer));
        },
        .key => |key| {
            if (key.down) platform.injectFocus(true);
            platform.injectKey(@intCast(key.keycode), key.down);
        },
        .focus => |focused| {
            if (focused) platform.raise();
            platform.injectFocus(focused);
        },
        .capture => |path| {
            const len = @min(path.len, protocol.max_path_bytes);
            @memcpy(host.capture_path[0..len], path[0..len]);
            host.capture_len = len;
            host.capture_pending = true;
        },
        .mouse => |mouse| {
            // Position precedes the button event so the click lands on the
            // widget under the injected cursor.
            platform.injectMousePosition(@floatCast(mouse.x), @floatCast(mouse.y));
            switch (mouse.kind) {
                .move => {},
                .click => platform.injectMouseButton(true),
                .release => platform.injectMouseButton(false),
            }
        },
    }
    std.debug.print("live_cimgui_host: injected test input\n", .{});
}

/// Fault injection, reachable only through the test-only protocol range.
/// `crash` ends the process without unwinding, exactly like a real host crash.
fn injectFault(host: *Host, fault: protocol.Fault) !void {
    switch (fault) {
        .stall => platform_mod.sleepMillis(1000),
        .crash => std.process.abort(),
        .exit => {
            std.debug.print("live_cimgui_host: exiting on injected fault\n", .{});
            host.exit_code = 2;
            host.running = false;
        },
    }
}
