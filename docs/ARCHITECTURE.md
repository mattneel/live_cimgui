# live_cimgui architecture

## 1. Layers and who owns them

```
Application service        (LiveCimgui.Demo.State)      owns application state and work
      ↕ messages
View process               (LiveCimgui.ViewServer)      owns presentation state + subscriptions
      ↕ synchronous calls
Elixir host manager        (LiveCimgui.HostManager)     owns the native resource + protocol
      ↕ Zigler NIF         (LiveCimgui.Native)
Zig native host executable (native/host)                owns immediate interaction + graphics
      ↕ cimgui / Dear ImGui
Platform + renderer        (SDL2 + OpenGL3)
```

Each layer is a real process or OS thread, not a module boundary:

| Layer | Runs where | May block? |
|---|---|---|
| Application service | one BEAM process (supervised) | yes (its own callers wait) |
| View process | one BEAM process (supervised, per window) | yes — this is what the stress demo proves |
| Host manager | one BEAM process | never on view callbacks; only on short NIF calls |
| NIF transport | one OS thread per host (created by `open/3`) | yes — it owns blocking socket I/O |
| Native host | one OS process, main thread | yes — the frame loop and the event loop |
| Host I/O | one OS thread inside the host | yes — blocking socket I/O |

## 2. The ownership contract

* **Application services own application state and work.** The demo's
  `LiveCimgui.Demo.State` holds rows, incarnations, and counters, and survives
  view restarts, view crashes, and host crashes. It is a supervised process, not
  a field in a view.
* **Views own presentation state and subscriptions.** A view holds a
  `%Phoenix.LiveView.Socket{}` with assigns, subscribes to whatever it needs,
  and is the only thing that calls `render/1`. It may block for as long as its
  callbacks take.
* **The native host owns immediate interaction and graphics resources.** It
  holds the Dear ImGui context, the GL objects, and the per-editor text buffers,
  and it keeps drawing and accepting input whether or not Elixir is busy.
* **The host manager owns the native connection.** It is the only process that
  calls `LiveCimgui.Native.submit/2`, the only owner of the resource, and the
  only writer of `view_generation` and `ui_revision`.

Consequences that the code enforces:

* a window's lifetime never defines an application's lifetime: `HostManager.close/1`
  stops the transport and the host, and nothing else;
* a view crash never closes the window, and a host crash never stops a view or
  the application service;
* the host never contains application state: it caches *one validated
  description* plus interaction state (buffers, draft revisions, focus). There is
  no second model of the application in Zig.

## 3. Threading model, and why

SDL requires its video calls on the **process main thread**. In the BEAM, no
such thread exists for a library: a normal NIF runs on a scheduler thread, a
`:dirty_io`/`:dirty_cpu` NIF runs on a dirty scheduler, and Zigler's `:threaded`
NIF runs on a Zigler-created thread. None of those is the host process's main
thread, so the frame loop cannot live in a NIF.

Therefore:

* `LiveCimgui.Native.open/3` spawns a **separate executable** with `posix_spawn`
  (never `fork`+work in a post-fork child) and hands it a UNIX socket path.
* The host's `main/1` owns the platform: `SDL_Init`, the window, the GL context,
  `ImGui_CreateContext`, the two upstream backends, and the frame loop.
* The NIF owns one transport thread that does all blocking socket I/O and calls
  `beam.independent_context/1` + `enif_send/4` to deliver frames to the manager.
  It never touches SDL, GL, or Dear ImGui.

Stack and lifetime notes that came from real failures:

* Resource payloads must stay small. A 1 MiB buffer inside the resource struct
  crashed the BEAM when the struct was copied on a scheduler stack; the read
  buffer is heap-allocated and owned by the transport thread.
* The transport thread holds an extra `enif_keep_resource` reference for its own
  lifetime, so the resource can only be destroyed after the thread has exited.

### Process environment and the working directory

Normal operation changes neither VM-global environment variables nor the working
directory. The host disables Dear ImGui's `.ini`/`.log` persistence
(`io.IniFilename = io.LogFilename = nil`, the only reason `glue.cpp` touches the
IO struct), so no file is ever written relative to the current directory; the
Elixir side resolves paths through `Application.app_dir/2` rather than `cwd`.

## 4. Lifecycle

| Event | What happens | Guarantee |
|---|---|---|
| View callback blocks (5 s) | the host keeps rendering at its own rate; the manager keeps reading the socket and queues events | native frame progress and native input continue; the transport owner is outside the blocked callback |
| View crashes | the manager keeps the resource, drops its queued events (and counts them), the supervisor starts a replacement which registers a **new generation** and re-publishes a fresh description | the window stays open and keeps its identity; pending non-idempotent actions are not replayed |
| View restarts | native drafts are preserved by the host and reported through `drafts`; the replacement view folds them into the application and acknowledges | local drafts are not reset by an unrelated snapshot |
| Host crashes (killed, panics, closes) | the NIF thread reports `host_gone`/`peer_unavailable`; the manager closes the resource, starts a new host within a bounded policy (default 3 restarts per 5 s), and republishes the last description | the BEAM, the view, and the application service are untouched; native drafts do **not** survive host death |
| Host restart policy exhausted | the manager stops with `{:shutdown, :host_restart_intensity}` and notifies the view | failures are loud, never a restart loop |
| User closes the window | the host emits `event.window_close` and `bye` and exits | visible to the application through the normal failure path |
| `HostManager.close/1` | transport closed (idempotent), host process reaped, resource released | the application keeps running; a closed resource rejects further submits (`:closed`); a manager started under `Livecimgui.HostSupervisor` uses a `:transient` child spec, so a *normal* close never resurrects a window while a crash still gets a replacement |
| BEAM exit | the module's on-halt callback stops every transport worker before the NIF library is unloaded; resource destructors only close descriptors and kill the child | no thread outlives the library; destructors are bounded |

`ERL_NIF_OPT_ON_HALT` + `ERL_NIF_OPT_DELAY_HALT` are installed during `load/3`
(`native/nif/transport.zig`). Zigler's resource `stop`/`down` callbacks are
deliberately **not** used: in Zigler 0.16 they assert signatures their own shims
do not call (`deps/zigler/priv/beam/resource.zig:48-56` versus the call sites at
`:168-182`), so relying on them would be unsound. Owner death is handled by the
resource destructor plus the manager's own `terminate/2`.

## 5. Platform backend

`native/host/src/platform.zig` is the only file that mentions SDL or OpenGL. It
exposes: `open/3` (window + GL context + ImGui context + backends),
`close/0`, `poll/1`, `push/1`, `beginFrame/0`, `endFrame/0`, `drawableSize/0`,
`uptimeMillis/0`, `captureRgb/1`, and the test-only ImGui input injection
helpers. Swapping SDL2 for SDL3 means replacing this file and the two backend
translation units.

**Why SDL2 here:** the brief prefers SDL3, but this environment has no SDL3
development package (no `sdl3.pc`, no `libsdl3-dev` candidate on Ubuntu 24.04).
The alternatives were vendoring and building SDL3, or using the installed SDL2
2.30 with Dear ImGui's matching upstream `imgui_impl_sdl2` backend. SDL2 was
chosen to keep a whole graphics stack out of the build; this is a documented
deviation, not a claim of SDL3 support. Neither choice implies bare-framebuffer
support: an X11/Wayland window is not a framebuffer.

## 6. Display scaling (DPI)

`SDL_WINDOW_ALLOW_HIGHDPI` is set at window creation, so on a scaled display the
drawable area is larger than the logical window. The split is:

* **Layout stays in logical units.** The panel is placed at `(0, 0)` and sized
  from the window size (not the drawable) on *every* frame, so it is the client
  area of the window at any scale and after any resize. It is also frameless:
  the platform window already carries the title, and restating it in a second
  title bar inside the client area is chrome nobody asked for. (An earlier
  version sized the panel `Cond_FirstUseEver` and never positioned it, which is
  what left a 940x620 window showing an 880x560 panel at Dear ImGui's default
  `(60, 60)`.)
* **Rasterization follows the display.** The host computes `drawable / window`
  and applies it with `style.FontScaleDpi` — Dear ImGui 1.92 scales glyph
  rasterization, not widget sizes — and re-applies it whenever the ratio
  changes, e.g. when the window moves to a monitor with another scale. That
  adapter lives in `glue.cpp`, because the style API is C++-only.
* **Input needs no conversion.** Dear ImGui works in logical units and the
  upstream SDL2 backend reports logical pointer coordinates and sets
  `io.DisplayFramebufferScale` (`1.0` here) from the drawable.
* **The framebuffer is drawable-sized.** `glViewport` uses the drawable size,
  and `io.DisplayFramebufferScale` maps the logical drawing space onto it.

The host reports `window_width`, `window_height` and `framebuffer_scale` in its
diagnostics, so a client — including the GUI tests — can compute the expected
pixel geometry of a window instead of assuming it: a capture is
`window_size * framebuffer_scale` pixels, exactly.

## 7. Identity and revisions

The rules live in `docs/PROTOCOL.md` (section 3 for ownership, section 4 for text
sync). The architectural points:

* a widget's native identity is `{explicit id, incarnation}`, and the id is
  derived from application keys — never from row position or a display label;
* keyed collections push one Dear ImGui ID scope per key, so an editor's text
  buffer, caret, and selection follow the key across a reorder;
* a deleted and recreated editor gets a greater incarnation, so its predecessor's
  state can never be applied to it;
* revisions are monotonic per owner; every mismatch is rejected as `stale_*`
  instead of applied.

## 8. Phoenix integration

`lib/live_cimgui/phoenix_adapter.ex` is the only file that mentions Phoenix
(besides `use LiveCimgui.View`, which imports `assign/2,3` and `update/3`). The
compatibility level is documented there: LiveView's *view callbacks and assigns*,
not LiveView's runtime, transport, components, or diff engine. All
version-sensitive behaviour is pinned by `test/live_cimgui/phoenix_adapter_test.exs`.

## 9. C++ surface

C++ is limited to upstream code plus `native/host/src/glue.cpp`, which contains
exactly two adapters:

1. `live_cimgui_host_configure_io/0` — cimgui has no setter for
   `io.IniFilename`/`io.LogFilename`, and the host must never read or write files
   relative to the working directory.
2. the backend wrappers — Dear ImGui 1.92 defines `IMGUI_API`/`IMGUI_IMPL_API` as
   empty, so `imgui_impl_sdl2`/`imgui_impl_opengl3` export C++-mangled symbols;
   the wrappers give the Zig host stable C names without patching upstream.

Nothing else C++-shaped exists: UI evaluation, protocol handling, queues, and
lifecycle live in Zig, and the UI itself is a small typed description rather than
a second UI framework.

## 10. Build and artifact layout

```
native/vendor/cimgui/      pinned cimgui + Dear ImGui (see UPSTREAM.md)
native/nif/transport.zig   Zigler NIF source (built by Zigler during mix compile)
native/host/               the executable's Zig sources + build.zig
priv/lib/Elixir.LiveCimgui.Native.so     NIF artifact (Zigler)
priv/native/live_cimgui_host             host artifact (mix live_cimgui.build_native)
```

* The host is built by the same pinned Zig compiler Zigler uses for the NIF; the
  task refuses to run with a different version.
* `LiveCimgui.Native.host_executable/0` resolves the executable through
  `Application.app_dir/2`, so neither dev nor a release needs source-tree paths
  or the current working directory.
* Both artifacts live in the application's `priv`, which is what a Mix release
  copies.

## 11. What this milestone deliberately does not do

* No template compiler or HEEx/HTML rendering: the typed constructors are the
  render target (the brief allows proving the runtime first).
* No incremental patches: every update is a complete validated snapshot.
  `docs/PROTOCOL.md` states what a patch would have to carry.
* No docking, multi-viewport, themes, or broad widget coverage.
* One window per host manager, one platform (Linux x86_64 + glibc, X11/Wayland
  via SDL2), no macOS/Windows/aarch64/musl claims.
* IME composition is passed through to Dear ImGui but is **not** verified
  automatically; see `docs/TESTING.md`.
