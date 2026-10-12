//! Host-side transport: one UNIX socket to the BEAM, one IO thread.
//!
//! The IO thread owns every blocking operation (accept is not needed — the host
//! connects to the listener the NIF created — and both reads and writes happen
//! on that thread), so the frame loop never blocks on the socket and the window
//! keeps rendering while Elixir is stalled.
//!
//! Both queues are bounded and every drop is accounted for:
//!   * inbound: awaiting semantic commands in FIFO order, except that a newer
//!     snapshot replaces an older *queued* snapshot (snapshots are replaceable,
//!     commands are not);
//!   * outbound: coalescing is allowed only for replaceable draft updates that
//!     have not been written yet; anything else keeps FIFO order.
//!
//! Saturation never silently loses a semantic command: the transport records an
//! overload and publishes it as soon as the socket accepts bytes again.

const std = @import("std");
const protocol = @import("protocol.zig");

const Inbound = struct {
    type_code: u8,
    body: []u8,
};

/// One queued frame. `storage` is the full allocation and is never re-sliced, so
/// it can always be freed even after a partial write or an in-place coalesce.
const Outbound = struct {
    storage: []u8,
    len: usize,
    written: usize = 0,
    coalesce_key: ?[]u8 = null,

    fn pending(self: *const Outbound) []const u8 {
        return self.storage[self.written..self.len];
    }
};

pub const max_inbound_frames: usize = 256;
pub const max_inbound_bytes: usize = 4 * 1024 * 1024;
pub const max_outbound_frames: usize = 512;
pub const max_outbound_bytes: usize = 4 * 1024 * 1024;

pub const Overload = struct {
    code: protocol.OverloadCode,
    dropped: u64,
    detail: []const u8,
};

pub const Transport = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    fd: c_int,

    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    wake: c_int,

    inbound: std.ArrayListUnmanaged(Inbound) = .empty,
    inbound_bytes: usize = 0,
    outbound: std.ArrayListUnmanaged(Outbound) = .empty,
    outbound_bytes: usize = 0,
    pending_overload: ?Overload = null,

    closed: bool = false,
    io_thread: ?std.Thread = null,
    frames_read: u64 = 0,
    frames_written: u64 = 0,
    dropped_inbound: u64 = 0,
    dropped_outbound: u64 = 0,
    overloads: u64 = 0,
    protocol_errors: u64 = 0,
    read_error: ?[]const u8 = null,

    pub const Error = error{ ConnectFailed, SocketFailed, EventFdFailed, ThreadFailed, Closed };

    pub fn connect(io: std.Io, gpa: std.mem.Allocator, path: []const u8) Error!*Transport {
        const socket = try connectUnix(path);
        const transport = gpa.create(Transport) catch return error.SocketFailed;
        errdefer gpa.destroy(transport);

        const wake = libc.eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
        if (wake < 0) return error.EventFdFailed;

        transport.* = .{
            .io = io,
            .gpa = gpa,
            .fd = socket,
            .wake = wake,
        };
        transport.io_thread = std.Thread.spawn(.{}, ioLoop, .{transport}) catch return error.ThreadFailed;
        return transport;
    }

    pub fn close(self: *Transport) void {
        self.lock();
        const already_closed = self.closed;
        self.closed = true;
        self.unlock();
        if (already_closed) return;
        _ = libc.shutdown(self.fd, SHUT_RDWR);
        self.signal();
        if (self.io_thread) |thread| thread.join();
        _ = libc.close(self.fd);
        _ = libc.close(self.wake);
        self.fd = -1;
        self.wake = -1;
        self.freeQueues();
    }

    fn freeQueues(self: *Transport) void {
        for (self.inbound.items) |entry| self.gpa.free(entry.body);
        self.inbound.deinit(self.gpa);
        for (self.outbound.items) |entry| {
            self.gpa.free(entry.storage);
            if (entry.coalesce_key) |key| self.gpa.free(key);
        }
        self.outbound.deinit(self.gpa);
        self.inbound_bytes = 0;
        self.outbound_bytes = 0;
    }

    fn lock(self: *Transport) void {
        self.mutex.lockUncancelable(self.io);
    }

    fn unlock(self: *Transport) void {
        self.mutex.unlock(self.io);
    }

    fn signal(self: *Transport) void {
        var one: [8]u8 = @bitCast(@as(u64, 1));
        _ = libc.write(self.wake, &one, one.len);
    }

    /// Queues one frame for the socket. `coalesce_key` marks a replaceable
    /// draft update: a queued, not yet written entry with the same key is
    /// replaced instead of appended.
    pub fn enqueue(self: *Transport, frame: []const u8, coalesce_key: ?[]const u8) Error!void {
        self.lock();
        defer self.unlock();
        if (self.closed) return error.Closed;

        if (coalesce_key) |key| {
            if (self.findCoalescible(key)) |index| {
                const existing = &self.outbound.items[index];
                if (existing.storage.len >= frame.len) {
                    @memcpy(existing.storage[0..frame.len], frame);
                    self.outbound_bytes -= existing.len - frame.len;
                    existing.len = frame.len;
                    self.signal();
                    return;
                }
                self.outbound_bytes -= existing.len;
                self.gpa.free(existing.storage);
                if (existing.coalesce_key) |old_key| self.gpa.free(old_key);
                _ = self.outbound.orderedRemove(index);
            }
        }

        if (self.outbound.items.len >= max_outbound_frames or
            self.outbound_bytes + frame.len > max_outbound_bytes)
        {
            self.recordOverload(.outbound_full, 1, "outbound queue full");
            return;
        }

        const copy = self.gpa.dupe(u8, frame) catch {
            self.recordOverload(.outbound_full, 1, "outbound allocation failed");
            return;
        };
        const key_copy: ?[]u8 = if (coalesce_key) |key| self.gpa.dupe(u8, key) catch null else null;
        self.outbound.append(self.gpa, .{
            .storage = copy,
            .len = copy.len,
            .coalesce_key = key_copy,
        }) catch {
            self.gpa.free(copy);
            if (key_copy) |key| self.gpa.free(key);
            self.recordOverload(.outbound_full, 1, "outbound queue append failed");
            return;
        };
        self.outbound_bytes += copy.len;
        self.signal();
    }

    /// Only entries that have not started writing can be replaced, so a
    /// partially transmitted frame is never rewritten under the socket.
    fn findCoalescible(self: *Transport, key: []const u8) ?usize {
        var index = self.outbound.items.len;
        while (index > 0) {
            index -= 1;
            const entry = &self.outbound.items[index];
            if (entry.written > 0) return null;
            const entry_key = entry.coalesce_key orelse return null;
            if (std.mem.eql(u8, entry_key, key)) return index;
        }
        return null;
    }

    /// Records that something could not be queued. The newest overload wins;
    /// reporting is bounded by one entry, and is retried by the IO thread.
    pub fn recordOverload(self: *Transport, code: protocol.OverloadCode, dropped: u64, detail: []const u8) void {
        self.overloads += 1;
        if (self.pending_overload == null) {
            self.pending_overload = .{ .code = code, .dropped = dropped, .detail = detail };
        } else {
            const pending = &self.pending_overload.?;
            pending.code = code;
            pending.dropped += dropped;
        }
    }

    pub fn takeOverload(self: *Transport) ?Overload {
        self.lock();
        defer self.unlock();
        const pending = self.pending_overload;
        self.pending_overload = null;
        return pending;
    }

    /// Pops the next inbound frame. The caller owns the returned body and must
    /// free it with `releaseInbound`.
    pub fn dequeue(self: *Transport) ?Inbound {
        self.lock();
        defer self.unlock();
        if (self.inbound.items.len == 0) return null;
        const entry = self.inbound.orderedRemove(0);
        self.inbound_bytes -= entry.body.len;
        return entry;
    }

    pub fn releaseInbound(self: *Transport, entry: Inbound) void {
        self.gpa.free(entry.body);
    }

    pub fn queueDepth(self: *Transport) struct { frames: u32, bytes: u32 } {
        self.lock();
        defer self.unlock();
        return .{
            .frames = @intCast(self.outbound.items.len),
            .bytes = @intCast(@min(self.outbound_bytes, std.math.maxInt(u32))),
        };
    }

    fn pushInbound(self: *Transport, type_code: u8, body: []const u8) void {
        const replaceable = type_code == @intFromEnum(protocol.TypeCode.snapshot);
        if (replaceable) {
            for (self.inbound.items, 0..) |entry, index| {
                if (entry.type_code != type_code) continue;
                self.inbound_bytes -= entry.body.len;
                const copy = self.gpa.dupe(u8, body) catch {
                    self.recordOverload(.command_full, 1, "inbound snapshot allocation failed");
                    return;
                };
                self.gpa.free(entry.body);
                self.inbound.items[index] = .{ .type_code = type_code, .body = copy };
                self.inbound_bytes += copy.len;
                return;
            }
        }

        if (self.inbound.items.len >= max_inbound_frames or self.inbound_bytes + body.len > max_inbound_bytes) {
            self.dropped_inbound += 1;
            self.recordOverload(.command_full, 1, "inbound queue full");
            return;
        }
        const copy = self.gpa.dupe(u8, body) catch {
            self.dropped_inbound += 1;
            self.recordOverload(.command_full, 1, "inbound allocation failed");
            return;
        };
        self.inbound.append(self.gpa, .{ .type_code = type_code, .body = copy }) catch {
            self.gpa.free(copy);
            self.dropped_inbound += 1;
            self.recordOverload(.command_full, 1, "inbound append failed");
            return;
        };
        self.inbound_bytes += copy.len;
    }

    fn ioLoop(self: *Transport) void {
        while (true) {
            self.lock();
            const closed = self.closed;
            self.unlock();
            if (closed) return;

            // Readability is always requested; writability only while there is
            // something to write, so idle frames do not spin on the socket.
            const socket_events: i16 = if (self.hasOutbound()) POLLIN | POLLOUT else POLLIN;
            var fds = [_]PollFd{
                .{ .fd = self.wake, .events = POLLIN, .revents = 0 },
                .{ .fd = self.fd, .events = socket_events, .revents = 0 },
            };

            const ready = libc.poll(&fds, 2, 50);
            if (ready < 0) {
                if (errno() == EINTR) continue;
                return;
            }

            if (fds[0].revents != 0) {
                var drain: [8]u8 = undefined;
                _ = libc.read(self.wake, &drain, drain.len);
            }
            if (fds[1].revents & POLLIN != 0) {
                if (!self.readOneFrame()) return;
            }
            if (fds[1].revents & POLLOUT != 0) {
                self.writePending();
            }
            self.publishOverloadIfPossible();
        }
    }

    fn hasOutbound(self: *Transport) bool {
        self.lock();
        defer self.unlock();
        return self.outbound.items.len > 0 or self.pending_overload != null;
    }

    fn readOneFrame(self: *Transport) bool {
        var header: [protocol.header_bytes]u8 = undefined;
        if (!readExact(self.fd, &header)) return false;
        const size = std.mem.readInt(u32, header[0..4], .little);
        const version = header[4];
        const type_code = header[5];
        if (version != protocol.protocol_version or size > protocol.max_frame_bytes) {
            self.protocol_errors += 1;
            self.recordOverload(.malformed_frame, 1, "invalid frame header from Elixir");
            return false;
        }
        const body = self.gpa.alloc(u8, size) catch return false;
        defer self.gpa.free(body);
        if (size > 0 and !readExact(self.fd, body)) return false;
        self.frames_read += 1;
        self.lock();
        self.pushInbound(type_code, body);
        self.unlock();
        return true;
    }

    fn writePending(self: *Transport) void {
        while (true) {
            self.lock();
            if (self.outbound.items.len == 0) {
                self.unlock();
                return;
            }
            const entry = &self.outbound.items[0];
            const pending = entry.pending();
            if (pending.len == 0) {
                self.unlock();
                return;
            }
            const written = libc.write(self.fd, pending.ptr, pending.len);
            if (written < 0) {
                const err = errno();
                self.unlock();
                if (err == EINTR or err == EAGAIN or err == EWOULDBLOCK) return;
                return;
            }
            entry.written += @intCast(written);
            self.outbound_bytes -= @intCast(written);
            const complete = entry.written >= entry.len;
            self.unlock();

            if (!complete) return;

            self.lock();
            if (self.outbound.items.len == 0) {
                self.unlock();
                return;
            }
            const written_entry = self.outbound.orderedRemove(0);
            self.gpa.free(written_entry.storage);
            if (written_entry.coalesce_key) |key| self.gpa.free(key);
            self.frames_written += 1;
            self.unlock();
        }
    }

    fn publishOverloadIfPossible(self: *Transport) void {
        const pending = self.takeOverload() orelse return;
        var buffer: [512]u8 = undefined;
        var writer = protocol.Writer.init(&buffer);
        writer.put8(@intFromEnum(pending.code)) catch return;
        writer.put64(pending.dropped) catch return;
        writer.put8(0) catch return;
        writer.string(pending.detail) catch return;
        const frame = writer.finish(.overload);
        self.enqueue(frame, null) catch {};
    }
};

fn readExact(fd: c_int, buffer: []u8) bool {
    var filled: usize = 0;
    while (filled < buffer.len) {
        const got = libc.read(fd, buffer.ptr + filled, buffer.len - filled);
        if (got > 0) {
            filled += @intCast(got);
            continue;
        }
        if (got == 0) return false;
        const err = errno();
        if (err == EINTR or err == EAGAIN or err == EWOULDBLOCK) continue;
        return false;
    }
    return true;
}

fn connectUnix(path: []const u8) Transport.Error!c_int {
    if (path.len > 107) return error.ConnectFailed;
    const fd = libc.socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return error.SocketFailed;
    var address = std.mem.zeroes(SockAddrUnix);
    address.family = AF_UNIX;
    @memcpy(address.path[0..path.len], path);
    if (libc.connect(fd, &address, @sizeOf(SockAddrUnix)) != 0) {
        _ = libc.close(fd);
        return error.ConnectFailed;
    }
    return fd;
}

const AF_UNIX: c_int = 1;
const SOCK_STREAM: c_int = 1;
const SOCK_CLOEXEC: c_int = 0o2000000;
const POLLIN: i16 = 0x001;
const POLLOUT: i16 = 0x004;
const SHUT_RDWR: c_int = 2;
const EINTR: c_int = 4;
const EAGAIN: c_int = 11;
const EWOULDBLOCK: c_int = 11;
const EFD_CLOEXEC: c_int = 0o2000000;
const EFD_NONBLOCK: c_int = 0o4000;

const SockAddrUnix = extern struct {
    family: u16,
    path: [108]u8,
};

const PollFd = extern struct {
    fd: c_int,
    events: i16,
    revents: i16,
};

const libc = struct {
    extern "c" fn socket(domain: c_int, kind: c_int, protocol_number: c_int) c_int;
    extern "c" fn connect(fd: c_int, address: *const SockAddrUnix, length: c_uint) c_int;
    extern "c" fn close(fd: c_int) c_int;
    extern "c" fn read(fd: c_int, buffer: [*]u8, count: usize) isize;
    extern "c" fn write(fd: c_int, buffer: [*]const u8, count: usize) isize;
    extern "c" fn poll(fds: [*]PollFd, count: c_ulong, timeout_ms: c_int) c_int;
    extern "c" fn shutdown(fd: c_int, how: c_int) c_int;
    extern "c" fn eventfd(init: c_uint, flags: c_int) c_int;
};

fn errno() c_int {
    return std.c._errno().*;
}

test "outbound coalescing replaces a queued draft update" {
    var transport = Transport{
        .io = std.testing.io,
        .gpa = std.testing.allocator,
        .fd = -1,
        .wake = -1,
    };
    defer transport.freeQueues();
    try transport.enqueue(&[_]u8{ 1, 2, 3 }, "editor/alpha");
    try transport.enqueue(&[_]u8{ 4, 5 }, "editor/alpha");
    try std.testing.expectEqual(@as(usize, 1), transport.outbound.items.len);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 4, 5 }, transport.outbound.items[0].pending());
}

test "non-coalescible frames keep FIFO order" {
    var transport = Transport{
        .io = std.testing.io,
        .gpa = std.testing.allocator,
        .fd = -1,
        .wake = -1,
    };
    defer transport.freeQueues();
    try transport.enqueue(&[_]u8{1}, "editor/alpha");
    try transport.enqueue(&[_]u8{2}, null);
    try transport.enqueue(&[_]u8{3}, "editor/alpha");
    try std.testing.expectEqual(@as(usize, 3), transport.outbound.items.len);
}
