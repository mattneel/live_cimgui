//! LiveCimgui.Native — the Zigler transport between the BEAM and a native host.
//!
//! Ownership model:
//!
//!   * This NIF owns the *transport*: a listening UNIX socket, one accepted
//!     connection, the spawned host process, and one transport OS thread.
//!   * The Zig host executable (`priv/native/live_cimgui_host`) owns the window,
//!     the Dear ImGui context, and the graphics resources, because SDL requires
//!     its video calls on the process main thread. A NIF — normal, dirty, or
//!     Zigler-threaded — never runs on that thread, so the frame loop cannot
//!     live here.
//!   * `LiveCimgui.HostManager` owns the resource returned by `open/3` and is
//!     the only process that submits to or closes it.
//!
//! Bounded behaviour, by construction:
//!
//!   * `open/3` returns once the listener exists and the child is spawned; the
//!     window becoming ready arrives later as a tagged message.
//!   * `submit/2` copies the frame into a bounded queue and acknowledges queue
//!     acceptance, never presentation.
//!   * `close/1` (dirty IO) shuts the socket down, joins the transport thread,
//!     and reaps the child. It is idempotent.
//!   * The resource destructor does bounded work only (no joins, no waits).
//!     Thread joins happen in `close/1` (explicit lifecycle code) and in the
//!     module's on-halt callback, which the VM calls before unloading the NIF
//!     library.
//!
//! The transport moves frames as opaque binaries and never parses UI
//! descriptions; `LiveCimgui.Protocol` owns the wire format.

const std = @import("std");
const beam = @import("beam");
const e = @import("erl_nif");

/// Resource holding every native handle for one host connection.
pub const Transport = beam.Resource(State, @import("root"), .{
    .Callbacks = struct {
        /// Bounded destructor: mark closed and release descriptors. Never joins
        /// the transport thread and never waits for the child; by the time this
        /// runs, the thread has released its own reference.
        pub fn dtor(self: *State) void {
            self.destroyBounded();
        }
    },
});

/// Message tags sent to the owner process. Lengths are taken from the literals
/// at compile time so a wrong hand-counted length can never create a different
/// atom (which would silently drop every message).
const TAG_NATIVE = "live_cimgui_native";
const TAG_NATIVE_ERROR = "live_cimgui_native_error";

const MAX_FRAME_BYTES: usize = 1024 * 1024;
const FRAME_HEADER_BYTES: usize = 6;
const PROTOCOL_VERSION: u8 = 1;
const HOST_TO_ELIXIR_TYPE_MIN: u8 = 32;
const QUEUE_SLOTS: usize = 32;
const QUEUE_BYTE_LIMIT: usize = 4 * 1024 * 1024;
const PATH_CAPACITY: usize = 200;
const ARG_CAPACITY: usize = 256;
const MAX_SESSION_BYTES: usize = 64;
const JOIN_TIMEOUT_MS: u64 = 3000;

// Linux x86_64 / glibc constants.
const AF_UNIX: c_int = 1;
const SOCK_STREAM: c_int = 1;
const SOCK_CLOEXEC: c_int = 0o2000000;
const POLLIN: i16 = 0x001;
const SHUT_RDWR: c_int = 2;
const WNOHANG: c_int = 1;
const SIGTERM: c_int = 15;
const SIGKILL: c_int = 9;
const EINTR: c_int = 4;
const EAGAIN: c_int = 11;
const ECHILD: c_int = 10;
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

const TimeSpec = extern struct {
    sec: isize,
    nsec: isize,
};

// libc entry points used by the transport, declared directly so this module
// needs no translated system headers. The NIF links against the libc the BEAM
// has already loaded, and Zigler allows undefined shlib symbols, so these
// resolve at load time.
const libc = struct {
    extern "c" var environ: [*c][*c]u8;
    extern "c" fn socket(domain: c_int, sock_type: c_int, protocol: c_int) c_int;
    extern "c" fn bind(fd: c_int, addr: *const SockAddrUnix, len: c_uint) c_int;
    extern "c" fn listen(fd: c_int, backlog: c_int) c_int;
    extern "c" fn accept(fd: c_int, addr: ?*anyopaque, len: ?*c_uint) c_int;
    extern "c" fn poll(fds: [*]PollFd, count: c_ulong, timeout_ms: c_int) c_int;
    extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
    extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
    extern "c" fn close(fd: c_int) c_int;
    extern "c" fn shutdown(fd: c_int, how: c_int) c_int;
    extern "c" fn unlink(path: [*:0]const u8) c_int;
    extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
    extern "c" fn rmdir(path: [*:0]const u8) c_int;
    extern "c" fn eventfd(init_val: c_uint, flags: c_int) c_int;
    extern "c" fn posix_spawn(
    pid: *c_int,
    path: [*:0]const u8,
    file_actions: ?*const anyopaque,
    attrs: ?*const anyopaque,
    argv: [*c]const [*c]u8,
    envp: [*c]const [*c]u8,
    ) c_int;
    extern "c" fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;
    extern "c" fn kill(pid: c_int, sig: c_int) c_int;
    extern "c" fn getpid() c_int;
    extern "c" fn nanosleep(req: *const TimeSpec, rem: ?*TimeSpec) c_int;
};

/// Reads `XDG_RUNTIME_DIR` from the environment through the BEAM's cached
/// environment, falling back to `/tmp` when it is unset or does not fit.
fn runtimeDir(buffer: []u8) []const u8 {
    var size: usize = buffer.len;
    if (e.enif_getenv("XDG_RUNTIME_DIR", buffer.ptr, &size) == 0) return "/tmp";
    return std.mem.sliceTo(buffer, 0);
}

fn sleepMillis(ms: u64) void {
    const req = TimeSpec{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * 1_000_000) };
    _ = libc.nanosleep(&req, null);
}

// ---- module lifecycle -----------------------------------------------------

/// Mutual exclusion for the global transport registry. Created during `load/3`.
var registry_mutex: ?*e.ErlNifMutex = null;
const MAX_TRANSPORTS: usize = 16;
var registry: [MAX_TRANSPORTS]?*State = [_]?*State{null} ** MAX_TRANSPORTS;
var halting = std.atomic.Value(bool).init(false);

/// Installed as the VM's on-halt callback during `load/3`.
///
/// The VM calls this before unloading the NIF library, so it must stop every
/// native worker: it marks all transports closed, shuts their sockets down, and
/// waits for each transport thread to finish (bounded per transport). It uses
/// no BEAM environment, because the callback receives only `priv_data`.
pub fn onHalt(_: ?*anyopaque) callconv(.c) void {
    halting.store(true, .release);
    if (registry_mutex) |mutex| {
        e.enif_mutex_lock(mutex);
        defer e.enif_mutex_unlock(mutex);
        for (registry) |entry| {
            const state = entry orelse continue;
            _ = state.setClosed();
            if (state.conn_fd >= 0) _ = libc.shutdown(state.conn_fd, SHUT_RDWR);
            if (state.wake_fd >= 0) _ = libc.write(state.wake_fd, &[_]u8{0} ** 8, 8);
        }
    }
    waitForAllFinished();
}

fn waitForAllFinished() void {
    var waited: u64 = 0;
    while (waited < JOIN_TIMEOUT_MS) : (waited += 10) {
        if (registryAllFinished()) return;
        sleepMillis(10);
    }
}

fn registryAllFinished() bool {
    if (registry_mutex) |mutex| {
        e.enif_mutex_lock(mutex);
        defer e.enif_mutex_unlock(mutex);
        for (registry) |entry| {
            const state = entry orelse continue;
            if (!state.isFinished()) return false;
        }
    }
    return true;
}

/// Module load callback: creates the registry mutex and installs the halt
/// contract. `ERL_NIF_OPT_DELAY_HALT` makes the VM wait for in-flight NIF calls
/// before completing a flush halt, which is what lets `close/1` hold the
/// transport mutex safely while a halt is in progress.
pub fn onLoad(env_: beam.env, priv_data: ?*?*anyopaque, load_info: e.ErlNifTerm) c_int {
    _ = priv_data;
    _ = load_info;
    registry_mutex = e.enif_mutex_create(@constCast("live_cimgui_registry")) orelse return -1;
    if (e.enif_set_option(env_, e.ERL_NIF_OPT_DELAY_HALT) != 0) return -1;
    if (e.enif_set_option(env_, e.ERL_NIF_OPT_ON_HALT, @as(?*const anyopaque, @ptrCast(&onHalt))) != 0) return -1;
    return 0;
}

fn registerTransport(state: *State) bool {
    if (registry_mutex) |mutex| e.enif_mutex_lock(mutex);
    defer if (registry_mutex) |mutex| e.enif_mutex_unlock(mutex);
    for (&registry) |*entry| {
        if (entry.* == null) {
            entry.* = state;
            return true;
        }
    }
    return false;
}

fn unregisterTransport(state: *State) void {
    if (registry_mutex) |mutex| e.enif_mutex_lock(mutex);
    defer if (registry_mutex) |mutex| e.enif_mutex_unlock(mutex);
    for (&registry) |*entry| {
        if (entry.* == state) entry.* = null;
    }
}

// ---- bounded outbound queue ----------------------------------------------

const Queue = struct {
    slots: [QUEUE_SLOTS]?[]u8 = [_]?[]u8{null} ** QUEUE_SLOTS,
    head: usize = 0,
    len: usize = 0,
    bytes: usize = 0,
    cursor: usize = 0,

    fn push(self: *Queue, frame: []u8) error{Overloaded}!void {
        if (self.len == QUEUE_SLOTS or self.bytes + frame.len > QUEUE_BYTE_LIMIT) return error.Overloaded;
        self.slots[(self.head + self.len) % QUEUE_SLOTS] = frame;
        self.len += 1;
        self.bytes += frame.len;
    }

    fn front(self: *Queue) ?[]u8 {
        if (self.len == 0) return null;
        return self.slots[self.head];
    }

    fn pop(self: *Queue, allocator: std.mem.Allocator) void {
        if (self.len == 0) return;
        if (self.slots[self.head]) |frame| {
            self.bytes -= frame.len;
            allocator.free(frame);
        }
        self.slots[self.head] = null;
        self.head = (self.head + 1) % QUEUE_SLOTS;
        self.len -= 1;
        self.cursor = 0;
    }

    fn clear(self: *Queue, allocator: std.mem.Allocator) void {
        while (self.len > 0) self.pop(allocator);
    }
};

const ErrorReason = enum {
    frame_too_large,
    malformed_frame,
    truncated_frame,
    peer_unavailable,
    owner_unreachable,

    fn name(self: ErrorReason) []const u8 {
        return @tagName(self);
    }
};

var nonce_counter = std.atomic.Value(u64).init(0);

pub const State = struct {
    mutex: ?*e.ErlNifMutex = null,
    cond: ?*e.ErlNifCond = null,
    wake_fd: c_int = -1,
    listen_fd: c_int = -1,
    conn_fd: c_int = -1,
    child_pid: c_int = -1,
    owner: beam.pid,
    session_id: [MAX_SESSION_BYTES]u8 = [_]u8{0} ** MAX_SESSION_BYTES,
    session_len: usize = 0,
    closed: bool = false,
    accepted: bool = false,
    finished: bool = false,
    child_reaped: bool = false,
    child_status: i32 = -1,
    /// Heap-allocated read buffer. Keeping it out of the resource struct is
    /// deliberate: the struct is copied into the resource allocation on `open/3`,
    /// and a megabyte-sized member would be copied on the calling scheduler's
    /// stack.
    read_buffer: ?[]u8 = null,
    queue: Queue = .{},
    /// The joinable thread handle, heap-allocated behind an opaque pointer so
    /// that the resource payload stays representable by Zigler's type
    /// introspection (std.Thread contains a pthread opaque).
    thread_box: ?*anyopaque = null,
    holds_thread_reference: bool = false,
    frames_in: u64 = 0,
    frames_out: u64 = 0,
    overloads: u64 = 0,
    dropped: u64 = 0,
    malformed: u64 = 0,
    protocol_errors: u64 = 0,
    dir_path: [PATH_CAPACITY]u8 = [_]u8{0} ** PATH_CAPACITY,
    dir_len: usize = 0,
    sock_path: [PATH_CAPACITY]u8 = [_]u8{0} ** PATH_CAPACITY,
    sock_len: usize = 0,

    fn session(self: *const State) []const u8 {
        return self.session_id[0..self.session_len];
    }

    fn lock(self: *State) void {
        if (self.mutex) |mutex| e.enif_mutex_lock(mutex);
    }

    fn unlock(self: *State) void {
        if (self.mutex) |mutex| e.enif_mutex_unlock(mutex);
    }

    fn isClosed(self: *State) bool {
        // The lock is held by callers that already own it; this variant is only
        // used by waiters, which is safe because `closed` is only ever set
        // monotonically.
        self.lock();
        defer self.unlock();
        return self.closed;
    }

    fn isFinished(self: *State) bool {
        self.lock();
        defer self.unlock();
        return self.finished;
    }

    fn setClosed(self: *State) bool {
        self.lock();
        defer self.unlock();
        if (self.closed) return false;
        self.closed = true;
        return true;
    }

    fn signal(self: *State) void {
        var one: [8]u8 = @bitCast(@as(u64, 1));
        if (self.wake_fd >= 0) _ = libc.write(self.wake_fd, &one, one.len);
        if (self.cond) |cond| e.enif_cond_broadcast(cond);
    }

    /// Bounded teardown path used by the resource destructor, which may run in
    /// BEAM GC or VM-shutdown context: no joins, no waits.
    fn destroyBounded(self: *State) void {
        _ = self.setClosed();
        self.signal();
        self.freeReadBuffer();
        const conn = self.conn_fd;
        if (conn >= 0) {
            self.conn_fd = -1;
            _ = libc.shutdown(conn, SHUT_RDWR);
            _ = libc.close(conn);
        }
        const listener = self.listen_fd;
        if (listener >= 0) {
            self.listen_fd = -1;
            _ = libc.close(listener);
        }
        const wake = self.wake_fd;
        if (wake >= 0) {
            self.wake_fd = -1;
            _ = libc.close(wake);
        }
        if (self.child_pid > 0 and !self.child_reaped) _ = libc.kill(self.child_pid, SIGTERM);
        self.removeSocketFiles();
    }

    fn removeSocketFiles(self: *State) void {
        var buf: [PATH_CAPACITY + 1]u8 = [_]u8{0} ** (PATH_CAPACITY + 1);
        if (self.sock_len > 0) {
            @memcpy(buf[0..self.sock_len], self.sock_path[0..self.sock_len]);
            _ = libc.unlink(@ptrCast(&buf));
            self.sock_len = 0;
        }
        @memset(&buf, 0);
        if (self.dir_len > 0) {
            @memcpy(buf[0..self.dir_len], self.dir_path[0..self.dir_len]);
            _ = libc.rmdir(@ptrCast(&buf));
            self.dir_len = 0;
        }
    }

    /// Runs at the end of the transport thread: releases the extra resource
    /// reference taken in `open/3`, so the BEAM can only destroy the resource
    /// once no thread can still touch it.
    fn freeReadBuffer(self: *State) void {
        if (self.read_buffer) |buffer| {
            beam.allocator.free(buffer);
            self.read_buffer = null;
        }
    }

    fn onThreadExit(self: *State) void {
        self.queue.clear(beam.allocator);
        self.freeReadBuffer();

        // If the loop ended without an explicit close, the host went away or the
        // stream broke: the owner must hear about it so it can apply its restart
        // policy instead of waiting forever for frames.
        if (!self.closed) {
            const env_ = beam.context.env;
            const session_term = makeBinary(env_, self.session());
            const tag = e.enif_make_atom_len(env_, TAG_NATIVE_ERROR.ptr, TAG_NATIVE_ERROR.len);
            const reason = e.enif_make_atom_len(env_, "host_gone", 9);
            const message = e.enif_make_tuple3(env_, tag, session_term, reason);
            const pid = self.owner;
            _ = e.enif_send(null, @constCast(&pid), env_, message);
            e.enif_clear_env(env_);
        }
        const conn = self.conn_fd;
        if (conn >= 0) {
            self.conn_fd = -1;
            _ = libc.close(conn);
        }
        const listener = self.listen_fd;
        if (listener >= 0) {
            self.listen_fd = -1;
            _ = libc.close(listener);
        }
        self.removeSocketFiles();
        self.reapChild(2000);
        self.lock();
        self.finished = true;
        self.unlock();
        self.signal();
        unregisterTransport(self);
        if (self.mutex) |mutex| e.enif_mutex_destroy(mutex);
        self.mutex = null;
        if (self.cond) |cond| e.enif_cond_destroy(cond);
        self.cond = null;
        if (self.wake_fd >= 0) {
            _ = libc.close(self.wake_fd);
            self.wake_fd = -1;
        }
        if (self.holds_thread_reference) {
            self.holds_thread_reference = false;
            e.enif_release_resource(@ptrCast(self));
        }
    }

    /// Waits for the host process with a bound.
    ///
    /// The runtime's own child reaper may have collected the process already; in
    /// that case `waitpid` reports `ECHILD` and there is no status left to read,
    /// so the wait ends immediately instead of blocking for the whole timeout on
    /// every close (`child_status` then stays -1, which means "not observed").
    fn reapChild(self: *State, timeout_ms: u64) void {
        if (self.child_pid <= 0 or self.child_reaped) return;

        switch (tryReap(self)) {
            .queued => return,
            .already_reaped => {
                self.child_reaped = true;
                return;
            },
            .still_running => {},
        }

        _ = libc.kill(self.child_pid, SIGTERM);

        var waited: u64 = 0;
        while (waited < timeout_ms) : (waited += 20) {
            switch (tryReap(self)) {
                .queued => return,
                .already_reaped => {
                    self.child_reaped = true;
                    return;
                },
                .still_running => {},
            }

            sleepMillis(20);
        }

        _ = libc.kill(self.child_pid, SIGKILL);
        switch (tryReap(self)) {
            .queued, .already_reaped => self.child_reaped = true,
            .still_running => {},
        }
    }

    const ReapOutcome = enum { queued, already_reaped, still_running };

    fn tryReap(self: *State) ReapOutcome {
        var status: c_int = 0;
        const result = libc.waitpid(self.child_pid, &status, WNOHANG);

        if (result == self.child_pid) {
            self.child_status = status;
            return .queued;
        }

        if (result < 0 and errno() == ECHILD) return .already_reaped;
        return .still_running;
    }

    // ---- transport thread -------------------------------------------------

    fn spawnTransportThread(self: *State) !void {
        const box = beam.allocator.create(std.Thread) catch return error.ThreadSpawn;
        box.* = std.Thread.spawn(.{}, State.transportMain, .{self}) catch {
            beam.allocator.destroy(box);
            return error.ThreadSpawn;
        };
        self.thread_box = @ptrCast(box);
    }

    /// Joins the transport thread. Safe to call more than once; exactly one
    /// caller takes ownership of the handle.
    fn joinTransportThread(self: *State) void {
        self.lock();
        const raw = self.thread_box;
        self.thread_box = null;
        self.unlock();
        const raw_handle = raw orelse return;
        const box: *std.Thread = @ptrCast(@alignCast(raw_handle));
        box.join();
        beam.allocator.destroy(box);
    }

    fn transportMain(self: *State) void {
        beam.independent_context(.{});
        defer beam.free_env(beam.context.env);
        self.loop();
        self.onThreadExit();
    }

    fn loop(self: *State) void {
        while (!self.isClosed() and !halting.load(.acquire)) {
            if (!self.flushOutbound()) return;
            var fds: [2]PollFd = undefined;
            fds[0] = .{ .fd = self.wake_fd, .events = POLLIN, .revents = 0 };
            const watch_fd = if (self.accepted) self.conn_fd else self.listen_fd;
            if (watch_fd < 0) return;
            fds[1] = .{ .fd = watch_fd, .events = POLLIN, .revents = 0 };

            const ready = libc.poll(&fds, 2, 100);
            if (ready < 0) {
                if (errno() == EINTR) continue;
                return;
            }
            if (self.isClosed() or halting.load(.acquire)) return;

            for (fds) |entry| {
                if (entry.revents == 0) continue;
                if (entry.fd == self.wake_fd) {
                    var drain: [8]u8 = undefined;
                    _ = libc.read(self.wake_fd, &drain, drain.len);
                } else if (!self.accepted and entry.fd == self.listen_fd) {
                    if (!self.acceptConnection()) return;
                } else if (entry.fd == self.conn_fd) {
                    if (!self.readAndDeliver()) return;
                }
            }
        }
    }

    fn acceptConnection(self: *State) bool {
        const conn = libc.accept(self.listen_fd, null, null);
        if (conn < 0) {
            const err = errno();
            if (err == EINTR or err == EAGAIN or err == EWOULDBLOCK) return true;
            std.debug.print("live_cimgui_nif: accept failed (errno {d})\n", .{err});
            self.protocol_errors += 1;
            self.notifyError(.peer_unavailable);
            return false;
        }
        self.conn_fd = conn;
        self.accepted = true;
        return true;
    }

    /// Reads exactly one frame and hands it to the owner process. Returns false
    /// when the transport must stop.
    fn readAndDeliver(self: *State) bool {
        const buffer = self.read_buffer orelse return false;
        if (!self.readExact(buffer[0..FRAME_HEADER_BYTES])) return false;
        const size = readU32le(buffer[0..4]);
        const version = buffer[4];
        const kind = buffer[5];
        if (version != PROTOCOL_VERSION or kind < HOST_TO_ELIXIR_TYPE_MIN or size > MAX_FRAME_BYTES) {
            self.protocol_errors += 1;
            self.notifyError(if (size > MAX_FRAME_BYTES) .frame_too_large else .malformed_frame);
            return false;
        }
        const total = FRAME_HEADER_BYTES + size;
        if (size > 0 and !self.readExact(buffer[FRAME_HEADER_BYTES..total])) return false;
        self.frames_in += 1;
        return self.deliver(buffer[0..total]);
    }

    fn readExact(self: *State, buffer: []u8) bool {
        var filled: usize = 0;
        while (filled < buffer.len) {
            if (self.isClosed() or halting.load(.acquire)) return false;
            var fds = [_]PollFd{.{ .fd = self.conn_fd, .events = POLLIN, .revents = 0 }};
            const ready = libc.poll(&fds, 1, 5000);
            if (ready < 0) {
                if (errno() == EINTR) continue;
                return false;
            }
            if (ready == 0) {
                self.protocol_errors += 1;
                self.notifyError(.truncated_frame);
                return false;
            }
            const got = libc.read(self.conn_fd, buffer.ptr + filled, buffer.len - filled);
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

    /// Drains the outbound queue.
    ///
    /// The queue is shared with `submit/2`, which runs on a scheduler thread, so
    /// every inspection and mutation of its indices happens under the transport
    /// mutex. Only this thread ever pops, so the frame slice stays valid while the
    /// lock is released for the (blocking) write.
    fn flushOutbound(self: *State) bool {
        // Nothing can be written before the host has connected: the loop accepts
        // and writes in the same iteration, and writing to the not-yet-assigned
        // connection descriptor would fail with EBADF and look like a dead peer.
        if (!self.accepted or self.conn_fd < 0) return true;

        while (true) {
            self.lock();
            const frame = self.queue.front() orelse {
                self.unlock();
                return true;
            };
            const offset = self.queue.cursor;
            self.unlock();

            if (offset >= frame.len) {
                self.lock();
                self.queue.pop(beam.allocator);
                self.unlock();
                continue;
            }

            const written = libc.write(self.conn_fd, frame.ptr + offset, frame.len - offset);
            if (written > 0) {
                self.lock();
                self.queue.cursor += @intCast(written);

                if (self.queue.cursor >= frame.len) {
                    self.queue.pop(beam.allocator);
                    self.frames_out += 1;
                }

                const closed = self.closed;
                self.unlock();

                if (closed) return false;
                continue;
            }

            if (written < 0 and errno() == EINTR) continue;

            std.debug.print("live_cimgui_nif: socket write failed (errno {d})\n", .{errno()});
            self.lock();
            self.queue.pop(beam.allocator);
            self.unlock();
            self.dropped += 1;
            self.overloads += 1;
            self.notifyError(.peer_unavailable);
            return false;
        }
    }

    fn deliver(self: *State, frame: []const u8) bool {
        const env_ = beam.context.env;
        const binary = makeBinary(env_, frame);
        const session_term = makeBinary(env_, self.session());
        const tag = e.enif_make_atom_len(env_, TAG_NATIVE.ptr, TAG_NATIVE.len);
        const message = e.enif_make_tuple3(env_, tag, session_term, binary);
        const delivered = sendToOwner(self, env_, message);
        e.enif_clear_env(env_);
        return delivered;
    }

    fn notifyError(self: *State, reason: ErrorReason) void {
        const env_ = beam.context.env;
        const session_term = makeBinary(env_, self.session());
        const tag = e.enif_make_atom_len(env_, TAG_NATIVE_ERROR.ptr, TAG_NATIVE_ERROR.len);
        const reason_term = e.enif_make_atom_len(env_, reason.name().ptr, reason.name().len);
        const message = e.enif_make_tuple3(env_, tag, session_term, reason_term);
        _ = sendToOwner(self, env_, message);
        e.enif_clear_env(env_);
    }

    fn sendToOwner(self: *State, env_: beam.env, message: e.ErlNifTerm) bool {
        var pid = self.owner;
        if (e.enif_send(null, @constCast(&pid), env_, message) == 0) {
            self.dropped += 1;
            return false;
        }
        return true;
    }
};

fn errno() c_int {
    return std.c._errno().*;
}

fn makeBinary(env_: beam.env, bytes: []const u8) e.ErlNifTerm {
    var term: e.ErlNifTerm = undefined;
    const ptr = e.enif_make_new_binary(env_, bytes.len, &term);
    if (bytes.len > 0) @memcpy(ptr[0..bytes.len], bytes);
    return term;
}

fn readU32le(bytes: []const u8) usize {
    return @as(usize, bytes[0]) |
        (@as(usize, bytes[1]) << 8) |
        (@as(usize, bytes[2]) << 16) |
        (@as(usize, bytes[3]) << 24);
}

fn atomTerm(env_: beam.env, name: []const u8) e.ErlNifTerm {
    return e.enif_make_atom_len(env_, name.ptr, name.len);
}

// ---- NIF entry points -----------------------------------------------------

/// `LiveCimgui.Native.open(executable, owner, session_id)` — see the Elixir
/// module docs. Returns `{:ok, transport}` or `{:error, reason}`.
pub fn open(executable: []const u8, owner: beam.pid, session_id: []const u8) beam.term {
    const result = openTransport(executable, owner, session_id) catch |err| {
        return openError(err);
    };
    return result;
}

fn openError(err: anyerror) beam.term {
    const env_ = beam.context.env;
    const reason = switch (err) {
        error.InvalidSessionId => "invalid_session_id",
        error.InvalidExecutable => "invalid_executable",
        error.MutexCreate, error.CondCreate => "native_init",
        error.EventFd => "event_fd",
        error.BufferAlloc => "buffer_alloc",
        error.Mkdir => "socket_dir",
        error.Socket => "socket",
        error.Bind => "socket_bind",
        error.Listen => "socket_listen",
        error.PathTooLong => "socket_path",
        error.SpawnFailed => "spawn_failed",
        error.TransportLimit => "transport_limit",
        error.ThreadSpawn => "thread_spawn",
        else => "native_init",
    };
    return .{ .v = e.enif_make_tuple2(env_, atomTerm(env_, "error"), atomTerm(env_, reason)) };
}

fn openTransport(executable: []const u8, owner: beam.pid, session_id: []const u8) !beam.term {
    if (session_id.len == 0 or session_id.len > MAX_SESSION_BYTES) return error.InvalidSessionId;
    if (executable.len == 0 or executable.len >= ARG_CAPACITY) return error.InvalidExecutable;

    var state = State{ .owner = owner };
    state.session_len = session_id.len;
    @memcpy(state.session_id[0..session_id.len], session_id);

    state.mutex = e.enif_mutex_create(@constCast("live_cimgui_transport")) orelse return error.MutexCreate;
    errdefer if (state.mutex) |mutex| e.enif_mutex_destroy(mutex);

    state.cond = e.enif_cond_create(@constCast("live_cimgui_transport")) orelse return error.CondCreate;
    errdefer if (state.cond) |cond| e.enif_cond_destroy(cond);

    state.read_buffer = beam.allocator.alloc(u8, MAX_FRAME_BYTES + FRAME_HEADER_BYTES) catch return error.BufferAlloc;
    errdefer if (state.read_buffer) |buffer| {
        beam.allocator.free(buffer);
        state.read_buffer = null;
    };

    const wake = libc.eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    if (wake < 0) return error.EventFd;
    state.wake_fd = wake;
    errdefer {
        if (state.wake_fd >= 0) {
            _ = libc.close(state.wake_fd);
            state.wake_fd = -1;
        }
    }

    try prepareListener(&state);
    errdefer {
        if (state.listen_fd >= 0) {
            _ = libc.close(state.listen_fd);
            state.listen_fd = -1;
        }
        state.removeSocketFiles();
    }

    try spawnHost(&state, executable);
    errdefer {
        if (state.child_pid > 0) {
            _ = libc.kill(state.child_pid, SIGKILL);
            var status: c_int = 0;
            _ = libc.waitpid(state.child_pid, &status, 0);
            state.child_pid = -1;
        }
    }

    const transport = try Transport.create(state, .{});
    const payload: *State = @ptrCast(transport.__payload);
    if (!registerTransport(payload)) return error.TransportLimit;
    errdefer unregisterTransport(payload);

    // Keep a reference for the transport thread: the thread owns raw native
    // memory, so the resource must outlive the thread.
    e.enif_keep_resource(@ptrCast(payload));
    payload.holds_thread_reference = true;

    payload.spawnTransportThread() catch {
        e.enif_release_resource(@ptrCast(payload));
        payload.holds_thread_reference = false;
        return error.ThreadSpawn;
    };

    const env_ = beam.context.env;
    const resource_term = transport.make(.{});
    return .{ .v = e.enif_make_tuple2(env_, atomTerm(env_, "ok"), resource_term.v) };
}

pub const SubmitResult = enum { ok, overloaded, closed, malformed };

/// `LiveCimgui.Native.submit(transport, frame)` — acknowledges queue
/// acceptance, not presentation. Short and bounded: it copies the frame into
/// the bounded outbound queue under the transport mutex.
pub fn submit(transport: Transport, frame: []const u8) !SubmitResult {
    const state: *State = @ptrCast(transport.__payload);

    if (frame.len < FRAME_HEADER_BYTES or
        frame.len > MAX_FRAME_BYTES or
        frame[4] != PROTOCOL_VERSION or
        frame[5] >= HOST_TO_ELIXIR_TYPE_MIN or
        readU32le(frame[0..4]) + FRAME_HEADER_BYTES != frame.len)
    {
        state.lock();
        state.malformed += 1;
        state.unlock();
        return .malformed;
    }

    state.lock();
    defer state.unlock();
    if (state.closed) return .closed;

    const copy = beam.allocator.alloc(u8, frame.len) catch {
        state.overloads += 1;
        state.dropped += 1;
        return .overloaded;
    };
    @memcpy(copy, frame);
    state.queue.push(copy) catch {
        beam.allocator.free(copy);
        state.overloads += 1;
        state.dropped += 1;
        return .overloaded;
    };
    state.signal();
    return .ok;
}

/// `LiveCimgui.Native.close(transport)` — idempotent, dirty IO. Shuts the
/// socket down, joins the transport thread, and reaps the child.
pub fn close(transport: Transport) !void {
    const state: *State = @ptrCast(transport.__payload);
    _ = state.setClosed();
    if (state.conn_fd >= 0) _ = libc.shutdown(state.conn_fd, SHUT_RDWR);
    state.signal();
    state.joinTransportThread();

    var waited: u64 = 0;
    while (waited < JOIN_TIMEOUT_MS) : (waited += 5) {
        if (state.isFinished()) return;
        sleepMillis(5);
    }
    return error.ThreadStillRunning;
}

/// `LiveCimgui.Native.stats(transport)` — transport counters as
/// `{queued_frames, queued_bytes, frames_in, frames_out, overloads, dropped,
/// malformed, protocol_errors, closed?, child_status}`.
pub fn stats(transport: Transport) beam.term {
    const state: *State = @ptrCast(transport.__payload);
    state.lock();
    defer state.unlock();
    const env_ = beam.context.env;
    const items = [10]e.ErlNifTerm{
        e.enif_make_uint64(env_, state.queue.len),
        e.enif_make_uint64(env_, state.queue.bytes),
        e.enif_make_uint64(env_, state.frames_in),
        e.enif_make_uint64(env_, state.frames_out),
        e.enif_make_uint64(env_, state.overloads),
        e.enif_make_uint64(env_, state.dropped),
        e.enif_make_uint64(env_, state.malformed),
        e.enif_make_uint64(env_, state.protocol_errors),
        e.enif_make_atom_len(env_, if (state.closed) "true" else "false", if (state.closed) 4 else 5),
        e.enif_make_int64(env_, state.child_status),
    };
    return .{ .v = e.enif_make_tuple_from_array(env_, &items, 10) };
}

// ---- setup helpers --------------------------------------------------------

fn prepareListener(self: *State) !void {
    var base_buf: [PATH_CAPACITY]u8 = undefined;
    const base = runtimeDir(&base_buf);
    // Uniqueness only has to be very likely: the monotonic clock (bit-cast, so
    // its sign is irrelevant), the pid, and a per-process counter are combined.
    const stamp: u64 = @bitCast(e.enif_monotonic_time(e.ERL_NIF_NSEC));
    const nonce = stamp ^ (@as(u64, @intCast(libc.getpid())) << 40) ^ nonce_counter.fetchAdd(1, .monotonic);
    const dir = std.fmt.bufPrint(self.dir_path[0..], "{s}/live_cimgui_{d}_{x}", .{ base, libc.getpid(), nonce }) catch
        return error.PathTooLong;
    self.dir_len = dir.len;

    var dir_buf: [PATH_CAPACITY + 1]u8 = [_]u8{0} ** (PATH_CAPACITY + 1);
    @memcpy(dir_buf[0..dir.len], dir);
    if (libc.mkdir(@ptrCast(&dir_buf), 0o700) != 0) return error.Mkdir;

    const sock = std.fmt.bufPrint(self.sock_path[0..], "{s}/sock", .{dir}) catch return error.PathTooLong;
    self.sock_len = sock.len;

    const fd = libc.socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return error.Socket;
    self.listen_fd = fd;

    var addr = std.mem.zeroes(SockAddrUnix);
    addr.family = AF_UNIX;
    @memcpy(addr.path[0..sock.len], sock);
    if (libc.bind(fd, &addr, @sizeOf(SockAddrUnix)) != 0) return error.Bind;
    if (libc.listen(fd, 4) != 0) return error.Listen;
}

fn spawnHost(self: *State, executable: []const u8) !void {
    var exe_buf: [ARG_CAPACITY]u8 = [_]u8{0} ** ARG_CAPACITY;
    @memcpy(exe_buf[0..executable.len], executable);

    var sock_buf: [PATH_CAPACITY + 1]u8 = [_]u8{0} ** (PATH_CAPACITY + 1);
    @memcpy(sock_buf[0..self.sock_len], self.sock_path[0..self.sock_len]);

    var argv: [4:null]?[*:0]const u8 = .{
        @ptrCast(&exe_buf),
        "--socket",
        @ptrCast(&sock_buf),
        null,
    };

    var pid: c_int = 0;
    const rc = libc.posix_spawn(&pid, @ptrCast(&exe_buf), null, null, @ptrCast(&argv), @ptrCast(libc.environ));
    if (rc != 0) return error.SpawnFailed;
    self.child_pid = pid;
}
