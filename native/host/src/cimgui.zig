//! Exactly the Dear ImGui C API (`cimgui`) the host uses, declared with C
//! linkage. Keeping the surface small makes it obvious which upstream
//! functions the host depends on, and keeps C++ limited to upstream code plus
//! `glue.cpp`.
//!
//! Text rules that matter for safety:
//!   * application text is drawn with `igTextUnformatted`, never as a format
//!     string;
//!   * widget labels are identity anchors only: identity always comes from an
//!     explicit `igPushID_Str` scope derived from application keys.

const std = @import("std");

pub const c = struct {
    pub const ImVec2 = extern struct {
        x: f32 = 0,
        y: f32 = 0,
    };
    pub const ImGuiContext = opaque {};
    pub const ImDrawData = opaque {};
    pub const ImGuiInputTextState = opaque {};

    // ---- context and frame lifecycle -----------------------------------
    pub extern "c" fn igCreateContext(shared_font_atlas: ?*anyopaque) ?*ImGuiContext;
    /// Upstream adapter (see glue.cpp): applies the display scale to font
    /// rasterization. Declared here so the host can call it without C++.
    pub extern "c" fn live_cimgui_host_apply_dpi_scale(scale: f32) void;
    pub extern "c" fn igDestroyContext(ctx: ?*ImGuiContext) void;
    pub extern "c" fn igNewFrame() void;
    pub extern "c" fn igRender() void;
    pub extern "c" fn igGetDrawData() ?*ImDrawData;
    pub extern "c" fn igGetFrameCount() c_int;
    pub extern "c" fn igGetTime() f64;

    // ---- windows and layout --------------------------------------------
    pub extern "c" fn igBegin(name: [*c]const u8, p_open: ?*bool, flags: c_int) bool;
    pub extern "c" fn igEnd() void;
    pub extern "c" fn igSetNextWindowSize(size: ImVec2, cond: c_int) void;
    pub extern "c" fn igSetNextWindowPos(pos: ImVec2, cond: c_int, pivot: ImVec2) void;
    pub extern "c" fn igSameLine(offset_from_start_x: f32, spacing: f32) void;
    pub extern "c" fn igSpacing() void;
    pub extern "c" fn igSeparator() void;
    pub extern "c" fn igPushItemWidth(item_width: f32) void;
    pub extern "c" fn igPopItemWidth() void;
    pub extern "c" fn igPushStyleVar_Float(idx: c_int, value: f32) void;
    pub extern "c" fn igPopStyleVar(count: c_int) void;

    // ---- text ------------------------------------------------------------
    pub extern "c" fn igTextUnformatted(text: [*c]const u8, text_end: [*c]const u8) void;
    pub extern "c" fn igText(fmt: [*c]const u8, ...) void;

    // ---- identity --------------------------------------------------------
    pub extern "c" fn igPushID_Str(str_id: [*c]const u8) void;
    pub extern "c" fn igPushID_Int(int_id: c_int) void;
    pub extern "c" fn igPopID() void;
    pub extern "c" fn igGetID_Str(str_id: [*c]const u8) u32;
    pub extern "c" fn igGetItemID() u32;
    pub extern "c" fn igGetActiveID() u32;
    pub extern "c" fn igGetFocusID() u32;

    // ---- widgets ---------------------------------------------------------
    pub extern "c" fn igButton(label: [*c]const u8, size: ImVec2) bool;
    pub extern "c" fn igInputText(
        label: [*c]const u8,
        buf: [*c]u8,
        buf_size: usize,
        flags: c_int,
        callback: ?*anyopaque,
        user_data: ?*anyopaque,
    ) bool;
    pub extern "c" fn igIsItemActive() bool;
    pub extern "c" fn igIsItemFocused() bool;
    pub extern "c" fn igGetItemRectMin() ImVec2;
    pub extern "c" fn igGetItemRectMax() ImVec2;
    pub extern "c" fn igSetKeyboardFocusHere(offset: c_int) void;
    pub extern "c" fn igSetItemDefaultFocus() void;

    // ---- input-text introspection (caret and selection) ------------------
    pub extern "c" fn igGetInputTextState(id: u32) ?*ImGuiInputTextState;
    pub extern "c" fn ImGuiInputTextState_GetText(state: *ImGuiInputTextState) [*:0]const u8;
    pub extern "c" fn ImGuiInputTextState_GetCursorPos(state: *ImGuiInputTextState) c_int;
    pub extern "c" fn ImGuiInputTextState_GetSelectionStart(state: *ImGuiInputTextState) c_int;
    pub extern "c" fn ImGuiInputTextState_GetSelectionEnd(state: *ImGuiInputTextState) c_int;

    pub extern "c" fn igIsKeyPressed_Bool(key: c_int, repeat: bool) bool;

    // ---- IO injection (test-only path) ----------------------------------
    pub const ImGuiIO = opaque {};
    pub extern "c" fn igGetIO_Nil() *ImGuiIO;
    pub extern "c" fn ImGuiIO_AddKeyEvent(io: *ImGuiIO, key: c_int, down: bool) void;
    pub extern "c" fn ImGuiIO_AddMousePosEvent(io: *ImGuiIO, x: f32, y: f32) void;
    pub extern "c" fn ImGuiIO_AddMouseButtonEvent(io: *ImGuiIO, button: c_int, down: bool) void;
    pub extern "c" fn ImGuiIO_AddFocusEvent(io: *ImGuiIO, focused: bool) void;
    pub extern "c" fn ImGuiIO_AddInputCharactersUTF8(io: *ImGuiIO, text: [*:0]const u8) void;

    // ---- flags -----------------------------------------------------------
    // Dear ImGui 1.92: named keys start at 512 (`ImGuiKey_NamedKey_BEGIN`);
    // small integers are *not* valid key values and trip an internal assert.
    pub const ImGuiKey_NamedKey_Begin: c_int = 512;
    pub const ImGuiKey_Enter: c_int = 525;
    pub const ImGuiKey_Escape: c_int = 526;
    pub const ImGuiInputTextFlags_None: c_int = 0;
    pub const ImGuiInputTextFlags_EnterReturnsTrue: c_int = 1 << 4;
    pub const ImGuiCond_Always: c_int = 1 << 0;
    pub const ImGuiCond_FirstUseEver: c_int = 1 << 2;
    pub const ImGuiWindowFlags_None: c_int = 0;
    pub const ImGuiWindowFlags_NoTitleBar: c_int = 1 << 0;
    pub const ImGuiWindowFlags_NoResize: c_int = 1 << 1;
    pub const ImGuiWindowFlags_NoMove: c_int = 1 << 2;
    pub const ImGuiWindowFlags_NoCollapse: c_int = 1 << 5;
    pub const ImGuiWindowFlags_NoSavedSettings: c_int = 1 << 8;
    pub const ImGuiWindowFlags_NoBringToFrontOnFocus: c_int = 1 << 13;
    pub const ImGuiStyleVar_ItemSpacing: c_int = 6;
    pub const ImGuiStyleVar_FramePadding: c_int = 11;
};
