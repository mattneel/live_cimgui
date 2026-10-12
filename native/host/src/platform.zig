//! Narrow platform interface: SDL2 window + OpenGL 3 context + the two upstream
//! Dear ImGui backends.
//!
//! This is the only file that knows about SDL or OpenGL. The rest of the host
//! deals in "the window", "a frame", and "push an event", which is what makes
//! the backend replaceable (see docs/ARCHITECTURE.md, section "Platform
//! backend", for why this machine uses SDL2 rather than SDL3).

const std = @import("std");
const imgui = @import("cimgui.zig").c;

pub const SDL_Window = opaque {};
pub const SDL_GLContext = ?*anyopaque;

// SDL2 constants used here.
pub const SDL_INIT_VIDEO: u32 = 0x0000_0020;
pub const SDL_WINDOWPOS_CENTERED: c_int = 0x2FFF_0000;
pub const SDL_WINDOW_OPENGL: u32 = 0x0000_0002;
pub const SDL_WINDOW_RESIZABLE: u32 = 0x0000_0020;
pub const SDL_WINDOW_ALLOW_HIGHDPI: u32 = 0x0000_2000;
pub const SDL_GL_CONTEXT_MAJOR_VERSION: c_int = 17;
pub const SDL_GL_CONTEXT_MINOR_VERSION: c_int = 18;
pub const SDL_GL_CONTEXT_PROFILE_MASK: c_int = 21;
pub const SDL_GL_CONTEXT_PROFILE_CORE: c_int = 0x0001;
pub const SDL_GL_DOUBLEBUFFER: c_int = 5;
pub const SDL_QUIT: u32 = 0x100;
pub const SDL_WINDOWEVENT: u32 = 0x200;
pub const SDL_WINDOWEVENT_CLOSE: u8 = 14;
pub const SDL_KEYDOWN: u32 = 0x300;
pub const SDL_KEYUP: u32 = 0x301;
pub const SDL_TEXTINPUT: u32 = 0x303;
pub const SDL_MOUSEMOTION: u32 = 0x400;
pub const SDL_MOUSEBUTTONDOWN: u32 = 0x401;
pub const SDL_MOUSEBUTTONUP: u32 = 0x402;
pub const SDLK_ESCAPE: c_int = 27;
pub const KMOD_NONE: u16 = 0;

const SDL_Keysym = extern struct {
    scancode: c_int,
    sym: c_int,
    mod: u16,
    unused: u32,
};

const SDL_KeyboardEvent = extern struct {
    type: u32,
    timestamp: u32,
    windowID: u32,
    state: u8,
    repeat: u8,
    padding2: u8,
    padding3: u8,
    keysym: SDL_Keysym,
};

const SDL_TextInputEvent = extern struct {
    type: u32,
    timestamp: u32,
    windowID: u32,
    text: [32]u8,
};

const SDL_MouseMotionEvent = extern struct {
    type: u32,
    timestamp: u32,
    windowID: u32,
    which: u32,
    state: u32,
    x: c_int,
    y: c_int,
    xrel: c_int,
    yrel: c_int,
};

const SDL_MouseButtonEvent = extern struct {
    type: u32,
    timestamp: u32,
    windowID: u32,
    which: u32,
    button: u8,
    state: u8,
    clicks: u8,
    padding1: u8,
    x: c_int,
    y: c_int,
};

const SDL_WindowEvent = extern struct {
    type: u32,
    timestamp: u32,
    windowID: u32,
    event: u8,
    padding1: u8,
    padding2: u8,
    padding3: u8,
    data1: c_int,
    data2: c_int,
};

/// Largest SDL event payload we handle; SDL guarantees 56 bytes, and the
/// union below is padded to that size so `SDL_PollEvent` can write safely.
pub const Event = extern union {
    type: u32,
    key: SDL_KeyboardEvent,
    text: SDL_TextInputEvent,
    motion: SDL_MouseMotionEvent,
    button: SDL_MouseButtonEvent,
    window: SDL_WindowEvent,
    padding: [56]u8,
};

extern "c" fn SDL_Init(flags: u32) c_int;
extern "c" fn SDL_Quit() void;
extern "c" fn SDL_GetError() [*:0]const u8;
extern "c" fn SDL_CreateWindow(
    title: [*:0]const u8,
    x: c_int,
    y: c_int,
    w: c_int,
    h: c_int,
    flags: u32,
) ?*SDL_Window;
extern "c" fn SDL_DestroyWindow(window: *SDL_Window) void;
extern "c" fn SDL_GL_CreateContext(window: *SDL_Window) SDL_GLContext;
extern "c" fn SDL_GL_DeleteContext(context: SDL_GLContext) void;
extern "c" fn SDL_GL_MakeCurrent(window: *SDL_Window, context: SDL_GLContext) c_int;
extern "c" fn SDL_GL_SetSwapInterval(interval: c_int) c_int;
extern "c" fn SDL_GL_GetDrawableSize(window: *SDL_Window, w: *c_int, h: *c_int) void;
extern "c" fn SDL_GetWindowSize(window: *SDL_Window, w: *c_int, h: *c_int) void;
extern "c" fn SDL_GL_SwapWindow(window: *SDL_Window) void;
extern "c" fn SDL_GL_SetAttribute(attr: c_int, value: c_int) c_int;
extern "c" fn SDL_PollEvent(event: *Event) c_int;
extern "c" fn SDL_PushEvent(event: *Event) c_int;
extern "c" fn SDL_RaiseWindow(window: *SDL_Window) void;
extern "c" fn SDL_GetTicks64() u64;
extern "c" fn SDL_SetWindowTitle(window: *SDL_Window, title: [*:0]const u8) void;
extern "c" fn SDL_GetWindowID(window: *SDL_Window) u32;

// GL functions used for the clear and the viewport.
/// libc file primitives, namespaced so they do not collide with
/// `Platform.open`. Only the capture writer uses them.
const libc = struct {
    extern "c" fn malloc(size: usize) ?*anyopaque;
    extern "c" fn free(ptr: ?*anyopaque) void;
    extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_uint) c_int;
    extern "c" fn write(fd: c_int, buffer: [*]const u8, count: usize) isize;
    extern "c" fn close(fd: c_int) c_int;
    extern "c" fn rename(from: [*:0]const u8, to: [*:0]const u8) c_int;
};

/// Mirrors protocol.max_path_bytes; kept local so this file stays free of
/// protocol dependencies.
const max_path_bytes: usize = 512;

const O_WRONLY: c_int = 0o1;
const O_CREAT: c_int = 0o100;
const O_TRUNC: c_int = 0o1000;

extern "c" fn glViewport(x: c_int, y: c_int, width: c_int, height: c_int) void;
extern "c" fn glClearColor(red: f32, green: f32, blue: f32, alpha: f32) void;
extern "c" fn glClear(mask: c_uint) void;
extern "c" fn glReadPixels(
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
    format: c_uint,
    kind: c_uint,
    pixels: *anyopaque,
) void;

const GL_COLOR_BUFFER_BIT: c_uint = 0x0000_4000;
const GL_RGB: c_uint = 0x1907;
const GL_UNSIGNED_BYTE: c_uint = 0x1401;

// Upstream adapter functions from `glue.cpp`, which is the only place that
// touches the C++ side of Dear ImGui (see that file's comment for why).
extern "c" fn live_cimgui_host_configure_io() void;
extern "c" fn live_cimgui_backend_sdl2_init(window: *SDL_Window, gl_context: SDL_GLContext) bool;
extern "c" fn live_cimgui_backend_sdl2_process_event(event: *const Event) bool;
extern "c" fn live_cimgui_backend_sdl2_new_frame() void;
extern "c" fn live_cimgui_backend_sdl2_shutdown() void;
extern "c" fn live_cimgui_backend_gl3_init(glsl_version: [*:0]const u8) bool;
extern "c" fn live_cimgui_backend_gl3_new_frame() void;
extern "c" fn live_cimgui_backend_gl3_render(draw_data: ?*imgui.ImDrawData) void;
extern "c" fn live_cimgui_backend_gl3_shutdown() void;

pub const Error = error{ SdlInit, SdlWindow, SdlGlContext, ImGuiContext, ImGuiBackend };

pub const Platform = struct {
    window: *SDL_Window,
    gl_context: SDL_GLContext,
    window_id: u32,
    started_ms: u64,
    backend_name: []const u8 = "SDL2 + OpenGL3",

    pub fn open(title: [*:0]const u8, width: u32, height: u32) Error!Platform {
        if (SDL_Init(SDL_INIT_VIDEO) != 0) return error.SdlInit;
        _ = SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
        _ = SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 3);
        _ = SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);
        _ = SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);

        const window = SDL_CreateWindow(
            title,
            SDL_WINDOWPOS_CENTERED,
            SDL_WINDOWPOS_CENTERED,
            @intCast(width),
            @intCast(height),
            SDL_WINDOW_OPENGL | SDL_WINDOW_RESIZABLE | SDL_WINDOW_ALLOW_HIGHDPI,
        ) orelse return error.SdlWindow;

        const gl_context = SDL_GL_CreateContext(window) orelse return error.SdlGlContext;
        _ = SDL_GL_MakeCurrent(window, gl_context);
        _ = SDL_GL_SetSwapInterval(1);

        if (imgui.igCreateContext(null) == null) return error.ImGuiContext;
        live_cimgui_host_configure_io();
        if (!live_cimgui_backend_sdl2_init(window, gl_context)) return error.ImGuiBackend;
        if (!live_cimgui_backend_gl3_init("#version 330")) return error.ImGuiBackend;

        return .{
            .window = window,
            .gl_context = gl_context,
            .window_id = SDL_GetWindowID(window),
            .started_ms = SDL_GetTicks64(),
        };
    }

    pub fn close(self: *Platform) void {
        live_cimgui_backend_gl3_shutdown();
        live_cimgui_backend_sdl2_shutdown();
        imgui.igDestroyContext(null);
        SDL_GL_DeleteContext(self.gl_context);
        SDL_DestroyWindow(self.window);
        SDL_Quit();
    }

    /// Polls one SDL event; the caller decides what to do with it.
    pub fn poll(self: *Platform, event: *Event) bool {
        _ = self;
        if (SDL_PollEvent(event) == 0) return false;
        _ = live_cimgui_backend_sdl2_process_event(event);
        return true;
    }

    pub fn push(self: *Platform, event: *Event) bool {
        _ = self;
        return SDL_PushEvent(event) == 1;
    }

    pub fn raise(self: *Platform) void {
        SDL_RaiseWindow(self.window);
    }

    pub fn setTitle(self: *Platform, title: [*:0]const u8) void {
        SDL_SetWindowTitle(self.window, title);
    }

    /// Logical size in points. On a high-DPI display this is smaller than the
    /// drawable size, and it is what Dear ImGui lays the UI out in.
    pub fn windowSize(self: *Platform) struct { width: u32, height: u32 } {
        var w: c_int = 0;
        var h: c_int = 0;
        SDL_GetWindowSize(self.window, &w, &h);
        return .{ .width = @intCast(@max(w, 0)), .height = @intCast(@max(h, 0)) };
    }

    /// Drawable pixels per logical point (1.0 on a standard display, 2.0 on a
    /// Retina/HiDPI display). SDL_WINDOW_ALLOW_HIGHDPI is set at creation, so a
    /// scaled display reports its real ratio here.
    pub fn framebufferScale(self: *Platform) f64 {
        const window = self.windowSize();
        const drawable = self.drawableSize();
        if (window.width == 0 or window.height == 0) return 1.0;
        return @as(f64, @floatFromInt(drawable.width)) / @as(f64, @floatFromInt(window.width));
    }

    /// Scales font rasterization (not layout) to the display, so text is crisp
    /// at 2x and identical in physical size at 1x.
    pub fn applyDpiScale(self: *Platform, scale: f64) void {
        _ = self;
        imgui.live_cimgui_host_apply_dpi_scale(@floatCast(scale));
    }

    pub fn drawableSize(self: *Platform) struct { width: u32, height: u32 } {
        var w: c_int = 0;
        var h: c_int = 0;
        SDL_GL_GetDrawableSize(self.window, &w, &h);
        return .{ .width = @intCast(@max(w, 0)), .height = @intCast(@max(h, 0)) };
    }

    pub fn beginFrame(self: *Platform) void {
        _ = self;
        live_cimgui_backend_gl3_new_frame();
        live_cimgui_backend_sdl2_new_frame();
        imgui.igNewFrame();
    }

    /// Renders and presents one frame. When `capture_path` is set, the frame is
    /// also written to that file as binary PPM (P6) before the buffer swap.
    /// Test-only: it is how the GUI acceptance tests get pixels out of a window
    /// this environment has no screenshot tool for.
    pub fn endFrame(self: *Platform, capture_path: ?[]const u8) void {
        imgui.igRender();
        const size = self.drawableSize();
        if (size.width > 0 and size.height > 0) glViewport(0, 0, @intCast(size.width), @intCast(size.height));
        glClearColor(0.06, 0.07, 0.09, 1.0);
        glClear(GL_COLOR_BUFFER_BIT);
        live_cimgui_backend_gl3_render(imgui.igGetDrawData());
        if (capture_path) |path| self.writePpm(path, size.width, size.height);
        SDL_GL_SwapWindow(self.window);
    }

    /// `captureRgb` returns rows bottom-up (OpenGL order); PPM wants them
    /// top-down, so rows are emitted in reverse.
    ///
    /// The image is written to `<path>.tmp` and renamed into place only when it
    /// is complete, so a reader that sees `path` sees a whole frame and never a
    /// half-written one.
    fn writePpm(self: *Platform, path: []const u8, width: u32, height: u32) void {
        if (width == 0 or height == 0) return;
        const suffix = ".tmp";
        if (path.len == 0 or path.len + suffix.len > max_path_bytes) return;

        var path_buffer: [max_path_bytes + 1]u8 = undefined;
        var tmp_buffer: [max_path_bytes + 1]u8 = undefined;
        @memcpy(path_buffer[0..path.len], path);
        path_buffer[path.len] = 0;
        @memcpy(tmp_buffer[0..path.len], path);
        @memcpy(tmp_buffer[path.len .. path.len + suffix.len], suffix);
        tmp_buffer[path.len + suffix.len] = 0;
        const path_z: [:0]const u8 = path_buffer[0..path.len :0];
        const tmp_z: [:0]const u8 = tmp_buffer[0 .. path.len + suffix.len :0];

        const stride: usize = @as(usize, width) * 3;
        const total = stride * @as(usize, height);
        const pixels: [*]u8 = @ptrCast(libc.malloc(total) orelse {
            std.debug.print("live_cimgui: capture allocation of {d} bytes failed\n", .{total});
            return;
        });
        defer libc.free(pixels);
        self.captureRgb(pixels[0..total]);

        var header_buffer: [64]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buffer, "P6\n{d} {d}\n255\n", .{ width, height }) catch return;
        const fd = libc.open(tmp_z, O_WRONLY | O_CREAT | O_TRUNC, 0o644);
        if (fd < 0) {
            std.debug.print("live_cimgui: capture could not open {s}\n", .{path});
            return;
        }
        {
            defer _ = libc.close(fd);
            if (libc.write(fd, header.ptr, header.len) < 0) return;
            var row: usize = height;
            while (row > 0) {
                row -= 1;
                const start = row * stride;
                if (libc.write(fd, pixels + start, stride) < 0) return;
            }
        }
        if (libc.rename(tmp_z, path_z) != 0) {
            std.debug.print("live_cimgui: capture could not rename {s}.tmp\n", .{path});
        }
    }

    pub fn uptimeMillis(self: *Platform) u64 {
        return SDL_GetTicks64() -| self.started_ms;
    }

    /// Reads the framebuffer into `buffer` (RGB, bottom-up as OpenGL returns
    /// it). Used by the GUI acceptance tests as direct evidence of what the
    /// window actually contains.
    pub fn captureRgb(self: *Platform, buffer: []u8) void {
        const size = self.drawableSize();
        glReadPixels(0, 0, @intCast(size.width), @intCast(size.height), GL_RGB, GL_UNSIGNED_BYTE, buffer.ptr);
    }

    /// Injects text straight into Dear ImGui's input queue. This is the
    /// test-only input path: it exercises the same code path as real typing
    /// (ImGui input handling, the widget's own text state, our edit callback),
    /// but does not depend on window focus or a window manager, which this
    /// environment has none of.
    pub fn injectText(self: *Platform, text: [*:0]const u8) void {
        _ = self;
        imgui.ImGuiIO_AddInputCharactersUTF8(imgui.igGetIO_Nil(), text);
    }

    pub fn injectMousePosition(self: *Platform, x: f32, y: f32) void {
        _ = self;
        imgui.ImGuiIO_AddMousePosEvent(imgui.igGetIO_Nil(), x, y);
    }

    pub fn injectMouseButton(self: *Platform, down: bool) void {
        _ = self;
        imgui.ImGuiIO_AddMouseButtonEvent(imgui.igGetIO_Nil(), 0, down);
    }

    pub fn injectFocus(self: *Platform, focused: bool) void {
        _ = self;
        imgui.ImGuiIO_AddFocusEvent(imgui.igGetIO_Nil(), focused);
    }

    pub fn injectKey(self: *Platform, key: c_int, down: bool) void {
        _ = self;
        imgui.ImGuiIO_AddKeyEvent(imgui.igGetIO_Nil(), key, down);
    }

    pub fn sdlVersion(self: *Platform) []const u8 {
        _ = self;
        return "SDL2";
    }

    pub fn glRenderer(self: *Platform) []const u8 {
        _ = self;
        return "OpenGL3 (Dear ImGui backend)";
    }
};

pub fn nowMillis() u64 {
    return SDL_GetTicks64();
}

const TimeSpec = extern struct {
    sec: isize,
    nsec: isize,
};

extern "c" fn nanosleep(request: *const TimeSpec, remaining: ?*TimeSpec) c_int;

pub fn sleepMillis(ms: u64) void {
    const request = TimeSpec{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * 1_000_000) };
    _ = nanosleep(&request, null);
}

pub fn eventText(event: *Event, out: *[32]u8) ?[]const u8 {
    if (event.type != SDL_TEXTINPUT) return null;
    @memcpy(out[0..32], &event.text.text);
    const len = std.mem.sliceTo(out, 0).len;
    return out[0..len];
}

pub fn makeKeyEvent(kind: u32, keycode: c_int, down: bool) Event {
    var event = std.mem.zeroes(Event);
    event.type = kind;
    event.key.type = kind;
    event.key.state = if (down) 1 else 0;
    event.key.keysym.scancode = keycode;
    event.key.keysym.sym = keycode;
    event.key.keysym.mod = KMOD_NONE;
    return event;
}

pub fn makeTextEvent(text: []const u8) Event {
    var event = std.mem.zeroes(Event);
    event.type = SDL_TEXTINPUT;
    event.text.type = SDL_TEXTINPUT;
    const len = @min(text.len, 31);
    @memcpy(event.text.text[0..len], text[0..len]);
    event.text.text[len] = 0;
    return event;
}

pub fn makeMouseEvent(kind: u32, button: u8, down: bool, x: f64, y: f64) Event {
    var event = std.mem.zeroes(Event);
    event.type = kind;
    switch (kind) {
        SDL_MOUSEMOTION => {
            event.motion.type = kind;
            event.motion.x = @intFromFloat(x);
            event.motion.y = @intFromFloat(y);
            event.motion.state = if (down) 1 else 0;
        },
        else => {
            event.button.type = kind;
            event.button.button = button;
            event.button.state = if (down) 1 else 0;
            event.button.clicks = 1;
            event.button.x = @intFromFloat(x);
            event.button.y = @intFromFloat(y);
        },
    }
    return event;
}
