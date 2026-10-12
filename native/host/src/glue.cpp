// Upstream adapters: the only place where the host uses the C++ Dear ImGui API.
//
// Two things need C++ here:
//
//  1. `io.IniFilename` / `io.LogFilename` have no cimgui setter, and the host
//     must never read or write files relative to the working directory.
//  2. Dear ImGui 1.92 defines `IMGUI_API`/`IMGUI_IMPL_API` as empty, so the
//     upstream backends (`imgui_impl_sdl2`, `imgui_impl_opengl3`) expose
//     C++-mangled symbols. These wrappers give the Zig host stable C names
//     without touching upstream sources.
//
// Nothing else belongs here: UI behaviour lives in Zig through the cimgui C API.

#include "imgui.h"
#include "imgui_impl_opengl3.h"
#include "imgui_impl_sdl2.h"

extern "C" void live_cimgui_host_configure_io(void)
{
    ImGuiIO& io = ImGui::GetIO();
    io.IniFilename = nullptr;
    io.LogFilename = nullptr;
}

// Dear ImGui 1.92 scales font *rasterization* through `style.FontScaleDpi`: on a
// high-DPI display the glyph atlas is rasterized at the display scale (crisp
// text) while layout, padding and widget sizes stay in logical units, so a view
// declaration means the same thing on every display. The flag below lets Dear
// ImGui keep that factor up to date when the monitor changes; the host also sets
// it explicitly from the window/drawable ratio.
extern "C" void live_cimgui_host_apply_dpi_scale(float scale)
{
    ImGuiStyle& style = ImGui::GetStyle();
    style.FontScaleDpi = scale > 0.0f ? scale : 1.0f;
    ImGui::GetIO().ConfigDpiScaleFonts = true;
}

extern "C" bool live_cimgui_backend_sdl2_init(SDL_Window* window, void* gl_context)
{
    return ImGui_ImplSDL2_InitForOpenGL(window, gl_context);
}

extern "C" bool live_cimgui_backend_sdl2_process_event(const SDL_Event* event)
{
    return ImGui_ImplSDL2_ProcessEvent(event);
}

extern "C" void live_cimgui_backend_sdl2_new_frame(void)
{
    ImGui_ImplSDL2_NewFrame();
}

extern "C" void live_cimgui_backend_sdl2_shutdown(void)
{
    ImGui_ImplSDL2_Shutdown();
}

extern "C" bool live_cimgui_backend_gl3_init(const char* glsl_version)
{
    return ImGui_ImplOpenGL3_Init(glsl_version);
}

extern "C" void live_cimgui_backend_gl3_new_frame(void)
{
    ImGui_ImplOpenGL3_NewFrame();
}

extern "C" void live_cimgui_backend_gl3_render(ImDrawData* draw_data)
{
    ImGui_ImplOpenGL3_RenderDrawData(draw_data);
}

extern "C" void live_cimgui_backend_gl3_shutdown(void)
{
    ImGui_ImplOpenGL3_Shutdown();
}
