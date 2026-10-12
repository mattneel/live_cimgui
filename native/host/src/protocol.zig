//! Framing and message codec for the host side of the live_cimgui protocol.
//!
//! This mirrors `LiveCimgui.Protocol.Codec` exactly; `docs/PROTOCOL.md` is the
//! specification and `LiveCimgui.ProtocolTest` pins the Elixir side of it.
//!
//! Frames are `<<size u32 little, version u8, type u8, body>>`. `size` counts
//! only the body, and every length inside a body is validated before an
//! allocation is made, so a malformed, oversized, or truncated frame is
//! rejected without touching cached UI state.

const std = @import("std");

pub const protocol_version: u8 = 1;
pub const max_frame_bytes: usize = 1024 * 1024;
pub const header_bytes: usize = 6;
pub const max_text_bytes: usize = 65_536;
pub const max_id_bytes: usize = 256;
pub const max_title_bytes: usize = 256;
pub const max_path_bytes: usize = 512;
pub const max_nodes: usize = 4_096;
pub const max_depth: usize = 64;
pub const max_children: usize = 1_024;

pub const TypeCode = enum(u8) {
    // Elixir -> host
    hello = 1,
    snapshot = 2,
    ack = 3,
    set_value = 4,
    inspect = 5,
    ping = 6,
    shutdown = 7,
    // test-only namespace, never application commands
    test_input = 16,
    fault = 17,
    // host -> Elixir
    ready = 32,
    event = 33,
    diagnostics = 34,
    overload = 35,
    inspect_result = 36,
    drafts = 37,
    pong = 38,
    bye = 39,
    protocol_error = 40,

    pub fn isHostToElixir(self: TypeCode) bool {
        return @intFromEnum(self) >= 32;
    }
};

pub const EventKind = enum(u8) {
    button_click = 0,
    input_edit = 1,
    window_close = 2,
    input_submit = 3,
};

pub const OverloadCode = enum(u8) {
    outbound_full = 0,
    command_full = 1,
    draft_full = 2,
    frame_oversized = 3,
    unknown_message = 4,
    stale_session = 5,
    stale_generation = 6,
    stale_incarnation = 7,
    stale_revision = 8,
    malformed_frame = 9,
};

pub const TestInputKind = enum(u8) {
    text = 0,
    key = 1,
    focus = 2,
    mouse = 3,
    /// Test-only: write the next frame's framebuffer to a PPM file.
    capture = 4,
};

pub const MouseKind = enum(u8) {
    move = 0,
    click = 1,
    release = 2,
};

pub const ShutdownReason = enum(u8) {
    normal = 0,
    restart = 1,
};

/// A decoded message from Elixir. Payload strings point into the caller's frame
/// buffer and are only valid until the next read.
pub const Message = union(enum) {
    hello: Hello,
    snapshot: Snapshot,
    ack: Ack,
    set_value: SetValue,
    inspect: u64,
    ping: u64,
    shutdown: ShutdownReason,
    test_input: TestInput,
    fault: Fault,
};

pub const Hello = struct {
    session_id: []const u8,
    view_generation: u64,
    host_generation: u64,
    title: []const u8,
    width: u32,
    height: u32,
};

pub const Snapshot = struct {
    view_generation: u64,
    ui_revision: u64,
    tree: *const Node,
};

pub const Ack = struct {
    view_generation: u64,
    id: []const u8,
    incarnation: u64,
    acked_revision: u64,
};

pub const SetValue = struct {
    view_generation: u64,
    id: []const u8,
    incarnation: u64,
    base_revision: u64,
    text: []const u8,
};

pub const TestInput = union(enum) {
    text: []const u8,
    key: KeyInput,
    focus: bool,
    mouse: MouseInput,
    capture: []const u8,
};

pub const KeyInput = struct { keycode: u32, down: bool };
pub const MouseInput = struct { kind: MouseKind, x: f64, y: f64 };

pub const Fault = enum(u8) { stall = 0, crash = 1, exit = 2 };

pub const NodeKind = enum(u8) {
    text = 1,
    button = 2,
    input = 3,
    row = 4,
    column = 5,
    keyed = 6,
    diagnostics = 7,
};

/// A validated node of the cached UI description. Strings are owned by the
/// scene arena, and are NUL-terminated so they can be handed to cimgui.
pub const Node = struct {
    kind: NodeKind,
    text: []const u8 = "",
    id: []const u8 = "",
    event: []const u8 = "",
    value: []const u8 = "",
    incarnation: u64 = 0,
    children: []const *Node = &.{},
    keyed: []const KeyedChild = &.{},
};

pub const KeyedChild = struct {
    key: []const u8,
    incarnation: u64,
    node: *const Node,
};

/// Reader with explicit bounds checking. Every failure is an error, never a
/// partial value.
pub const Reader = struct {
    body: []const u8,
    offset: usize = 0,

    pub const Error = error{ Truncated, StringTooLong, InvalidValue, TrailingBytes };

    pub fn init(body: []const u8) Reader {
        return .{ .body = body };
    }

    pub fn done(self: *Reader) Error!void {
        if (self.offset != self.body.len) return error.TrailingBytes;
    }

    pub fn get8(self: *Reader) Error!u8 {
        if (self.offset + 1 > self.body.len) return error.Truncated;
        const value = self.body[self.offset];
        self.offset += 1;
        return value;
    }

    pub fn get32(self: *Reader) Error!u32 {
        if (self.offset + 4 > self.body.len) return error.Truncated;
        const value = std.mem.readInt(u32, self.body[self.offset..][0..4], .little);
        self.offset += 4;
        return value;
    }

    pub fn get64(self: *Reader) Error!u64 {
        if (self.offset + 8 > self.body.len) return error.Truncated;
        const value = std.mem.readInt(u64, self.body[self.offset..][0..8], .little);
        self.offset += 8;
        return value;
    }

    pub fn getFloat(self: *Reader) Error!f64 {
        if (self.offset + 8 > self.body.len) return error.Truncated;
        const value: f64 = @bitCast(std.mem.readInt(u64, self.body[self.offset..][0..8], .little));
        self.offset += 8;
        return value;
    }

    /// Length-prefixed string. `limit` is checked before the slice is taken.
    pub fn string(self: *Reader, limit: usize) Error![]const u8 {
        const size = try self.get32();
        if (size > limit) return error.StringTooLong;
        if (self.offset + size > self.body.len) return error.Truncated;
        const value = self.body[self.offset .. self.offset + size];
        self.offset += size;
        return value;
    }
};

/// Errors a decoded message can produce. Spelled out so that the recursive tree
/// decoders have a concrete error set instead of an inferred one (Zig rejects
/// the inference cycle between `decodeTree` and `decodeKeyed`).
pub const DecodeError = error{
    Truncated,
    StringTooLong,
    InvalidValue,
    TrailingBytes,
    UnknownType,
    TreeTooDeep,
    TooManyNodes,
    TooManyChildren,
    InvalidNodeTag,
    OutOfMemory,
};

/// Decodes one c2h body.
pub fn decode(type_code: u8, body: []const u8, scratch: *Scene) !Message {
    const kind = std.enums.fromInt(TypeCode, type_code) orelse return error.UnknownType;
    return switch (kind) {
        .hello => decodeHello(body),
        .snapshot => decodeSnapshot(body, scratch),
        .ack => decodeAck(body),
        .set_value => decodeSetValue(body),
        .inspect => decodeRequestId(body, .inspect),
        .ping => decodeRequestId(body, .ping),
        .shutdown => decodeShutdown(body),
        .test_input => decodeTestInput(body),
        .fault => decodeFault(body),
        else => error.UnknownType,
    };
}

fn decodeHello(body: []const u8) !Message {
    var r = Reader.init(body);
    const session_id = try r.string(max_id_bytes);
    const view_generation = try r.get64();
    const host_generation = try r.get64();
    const title = try r.string(max_title_bytes);
    const width = try r.get32();
    const height = try r.get32();
    try r.done();
    return .{ .hello = .{
        .session_id = session_id,
        .view_generation = view_generation,
        .host_generation = host_generation,
        .title = title,
        .width = width,
        .height = height,
    } };
}

fn decodeSnapshot(body: []const u8, scene: *Scene) !Message {
    var r = Reader.init(body);
    const view_generation = try r.get64();
    const ui_revision = try r.get64();
    const tree = try decodeTree(&r, scene, 1, 0);
    try r.done();
    return .{ .snapshot = .{
        .view_generation = view_generation,
        .ui_revision = ui_revision,
        .tree = tree,
    } };
}

fn decodeTree(r: *Reader, scene: *Scene, depth: usize, count: usize) DecodeError!*Node {
    if (depth > max_depth) return error.TreeTooDeep;
    if (count >= max_nodes) return error.TooManyNodes;
    const tag = try r.get8();
    const kind = std.enums.fromInt(NodeKind, tag) orelse return error.InvalidNodeTag;
    var node = Node{ .kind = kind };
    switch (kind) {
        .text => node.text = try scene.dupeString(try r.string(max_text_bytes)),
        .button => {
            node.id = try scene.dupeString(try r.string(max_id_bytes));
            node.incarnation = try r.get64();
            node.text = try scene.dupeString(try r.string(max_text_bytes));
            node.event = try scene.dupeString(try r.string(max_id_bytes));
        },
        .input => {
            node.id = try scene.dupeString(try r.string(max_id_bytes));
            node.incarnation = try r.get64();
            node.text = try scene.dupeString(try r.string(max_text_bytes));
            node.value = try scene.dupeString(try r.string(max_text_bytes));
        },
        .diagnostics => {},
        .row, .column => node.children = try decodeChildren(r, scene, depth, count),
        .keyed => {
            node.id = try scene.dupeString(try r.string(max_id_bytes));
            node.keyed = try decodeKeyed(r, scene, depth, count);
        },
    }
    return scene.adoptNode(node);
}

fn decodeChildren(r: *Reader, scene: *Scene, depth: usize, count: usize) DecodeError![]const *Node {
    const child_count = try r.get32();
    if (child_count > max_children) return error.TooManyChildren;
    const list = try scene.allocator().alloc(*Node, child_count);
    var seen = count + 1;
    for (0..child_count) |i| {
        list[i] = try decodeTree(r, scene, depth + 1, seen);
        seen += 1;
    }
    return list;
}

fn decodeKeyed(r: *Reader, scene: *Scene, depth: usize, count: usize) DecodeError![]const KeyedChild {
    const child_count = try r.get32();
    if (child_count > max_children) return error.TooManyChildren;
    const list = try scene.allocator().alloc(KeyedChild, child_count);
    var seen = count + 1;
    for (0..child_count) |i| {
        const key = try scene.dupeString(try r.string(max_id_bytes));
        const incarnation = try r.get64();
        const node = try decodeTree(r, scene, depth + 1, seen);
        seen += 1;
        list[i] = .{ .key = key, .incarnation = incarnation, .node = node };
    }
    return list;
}

fn decodeAck(body: []const u8) !Message {
    var r = Reader.init(body);
    const view_generation = try r.get64();
    const id = try r.string(max_id_bytes);
    const incarnation = try r.get64();
    const acked_revision = try r.get64();
    try r.done();
    return .{ .ack = .{
        .view_generation = view_generation,
        .id = id,
        .incarnation = incarnation,
        .acked_revision = acked_revision,
    } };
}

fn decodeSetValue(body: []const u8) !Message {
    var r = Reader.init(body);
    const view_generation = try r.get64();
    const id = try r.string(max_id_bytes);
    const incarnation = try r.get64();
    const base_revision = try r.get64();
    const text = try r.string(max_text_bytes);
    try r.done();
    return .{ .set_value = .{
        .view_generation = view_generation,
        .id = id,
        .incarnation = incarnation,
        .base_revision = base_revision,
        .text = text,
    } };
}

fn decodeRequestId(body: []const u8, comptime tag: std.meta.Tag(Message)) !Message {
    var r = Reader.init(body);
    const request_id = try r.get64();
    try r.done();
    return @unionInit(Message, @tagName(tag), request_id);
}

fn decodeShutdown(body: []const u8) !Message {
    var r = Reader.init(body);
    const code = try r.get8();
    try r.done();
    return .{ .shutdown = std.enums.fromInt(ShutdownReason, code) orelse return error.InvalidValue };
}

fn decodeFault(body: []const u8) !Message {
    var r = Reader.init(body);
    const code = try r.get8();
    try r.done();
    return .{ .fault = std.enums.fromInt(Fault, code) orelse return error.InvalidValue };
}

fn decodeTestInput(body: []const u8) !Message {
    var r = Reader.init(body);
    const kind = std.enums.fromInt(TestInputKind, try r.get8()) orelse return error.InvalidValue;
    switch (kind) {
        .text => {
            const text = try r.string(max_text_bytes);
            try r.done();
            return .{ .test_input = .{ .text = text } };
        },
        .key => {
            const keycode = try r.get32();
            const down = (try r.get8()) != 0;
            try r.done();
            return .{ .test_input = .{ .key = .{ .keycode = keycode, .down = down } } };
        },
        .focus => {
            const focused = (try r.get8()) != 0;
            try r.done();
            return .{ .test_input = .{ .focus = focused } };
        },
        .mouse => {
            const mouse_kind = std.enums.fromInt(MouseKind, try r.get8()) orelse return error.InvalidValue;
            const x = try r.getFloat();
            const y = try r.getFloat();
            try r.done();
            return .{ .test_input = .{ .mouse = .{ .kind = mouse_kind, .x = x, .y = y } } };
        },
        .capture => {
            const path = try r.string(max_path_bytes);
            try r.done();
            return .{ .test_input = .{ .capture = path } };
        },
    }
}

/// Writer for host-to-Elixir frames. Bodies are built in a caller-provided
/// buffer so that a frame is never partially written to the socket.
pub const Writer = struct {
    buffer: []u8,
    offset: usize = header_bytes,

    pub const Error = error{FrameTooLarge};

    pub fn init(buffer: []u8) Writer {
        std.debug.assert(buffer.len > header_bytes);
        @memset(buffer[0..header_bytes], 0);
        return .{ .buffer = buffer };
    }

    pub fn put8(self: *Writer, value: u8) Error!void {
        return self.raw(&[_]u8{value});
    }

    pub fn put32(self: *Writer, value: u32) Error!void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        return self.raw(&bytes);
    }

    pub fn put64(self: *Writer, value: u64) Error!void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .little);
        return self.raw(&bytes);
    }

    pub fn putI64(self: *Writer, value: i64) Error!void {
        return self.put64(@bitCast(value));
    }

    pub fn putFloat(self: *Writer, value: f64) Error!void {
        return self.put64(@bitCast(value));
    }

    pub fn raw(self: *Writer, bytes: []const u8) Error!void {
        if (self.offset + bytes.len > self.buffer.len) return error.FrameTooLarge;
        @memcpy(self.buffer[self.offset..][0..bytes.len], bytes);
        self.offset += bytes.len;
    }

    pub fn string(self: *Writer, bytes: []const u8) Error!void {
        try self.put32(@intCast(bytes.len));
        return self.raw(bytes);
    }

    /// Finalizes the frame into a slice of `buffer`, filling in size/version/type.
    pub fn finish(self: *Writer, type_code: TypeCode) []u8 {
        const body_len = self.offset - header_bytes;
        std.mem.writeInt(u32, self.buffer[0..4], @intCast(body_len), .little);
        self.buffer[4] = protocol_version;
        self.buffer[5] = @intFromEnum(type_code);
        return self.buffer[0..self.offset];
    }
};

/// Scene storage is defined in `scene.zig`; the codec only needs its allocator
/// and node adoption so that decoded trees live in the scene's arena.
pub const Scene = @import("scene.zig").Scene;

test "reader rejects a string longer than its limit before slicing" {
    const body = [_]u8{ 0xff, 0xff, 0xff, 0x7f, 'a', 'b' };
    var r = Reader.init(&body);
    try std.testing.expectError(error.StringTooLong, r.string(16));
}

test "reader rejects a truncated body" {
    const body = [_]u8{ 5, 0, 0, 0, 'a' };
    var r = Reader.init(&body);
    try std.testing.expectError(error.Truncated, r.string(64));
}

test "reader rejects trailing bytes" {
    var r = Reader.init(&[_]u8{ 1, 2, 3 });
    _ = try r.get8();
    try std.testing.expectError(error.TrailingBytes, r.done());
}

test "writer round-trips through the reader" {
    var buffer: [128]u8 = undefined;
    var w = Writer.init(&buffer);
    try w.string("live");
    try w.put64(42);
    const frame = w.finish(.ready);
    try std.testing.expectEqual(@as(u8, protocol_version), frame[4]);
    try std.testing.expectEqual(@as(u8, @intFromEnum(TypeCode.ready)), frame[5]);

    var r = Reader.init(frame[header_bytes..]);
    try std.testing.expectEqualStrings("live", try r.string(16));
    try std.testing.expectEqual(@as(u64, 42), try r.get64());
    try r.done();
}
