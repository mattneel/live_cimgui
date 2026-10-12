# live_cimgui — implementation plan

Recorded before implementation, then updated as evidence landed. Deviations from the
original brief are called out explicitly under **Deviations**.

## 1. Environment (measured, not assumed)

| Item | Value | Evidence |
|---|---|---|
| OS | Ubuntu 24.04.5 LTS (WSL2, kernel 7.2.6-locietta-WSL2-xanmod1) | `cat /etc/os-release` |
| libc | glibc 2.39 | `ldd --version` |
| Arch | x86_64 | `uname -m` |
| Elixir | 1.20.2 (OTP 28) | `elixir --version` |
| OTP | 28 (erts-16.4.0.2) | `erl -noshell -eval ...` |
| Zig | 0.16.0 (mise-managed; 0.15.2 also present) | `~/.local/share/mise/installs/zig/0.16.0/zig version` |
| C/C++ | gcc/g++ 13.3.0 (used only indirectly; Zig's clang drives C/C++) | `cc --version` |
| SDL | SDL2 2.30.0 + headers (`libsdl2-dev` installed) | `pkg-config --modversion sdl2` |
| SDL3 | **not available** (`libsdl3-dev` absent; no `sdl3.pc`) | `pkg-config --modversion sdl3`, `apt-cache policy libsdl3-dev` |
| OpenGL | GL 4.6 via WSLg D3D12 (Mesa 26.1.8), direct rendering | `glxinfo -B` |
| Display | `DISPLAY=:0`, `WAYLAND_DISPLAY=wayland-0` (WSLg); `Xvfb`, `xdotool`, `xwd`, `import` present | environment |

## 2. Pinned dependency set

| Dependency | Pin | Why |
|---|---|---|
| `zigler` | 0.16.0 (already required by `mix.exs`: `~> 0.16`) | Real Elixir↔Zig NIF interface. `Zigler.MixProject.zig_version/0` returns `0.16.0`, so Zig **0.16.0** is the compatible compiler. |
| Zig toolchain | 0.16.0 | Must match Zigler's `zig_version/0`. |
| `cimgui` | commit `125f397e0982fe9466eb0a162de547be5efec849` (branch `docking_inter`) | C API for Dear ImGui, vendored under `native/vendor/cimgui`. |
| `imgui` | commit `b48d1afbe8ee8b238e2961dc363a949dd7304e23` (docking, `IMGUI_VERSION 1.92.9b`, `IMGUI_VERSION_NUM 19291`) | **The exact revision `cimgui.h` was generated from** ("based on imgui.h file version \"1.92.9b\" 19291"). Generated headers are never combined with an unrelated ImGui checkout. |
| SDL | system SDL2 2.30.0 (`-lSDL2`) | See deviation D1. |
| GL loader | ImGui's bundled `imgui_impl_opengl3_loader.h` | No GLEW/GLAD needed; avoids another pinned dependency. |

Vendored file list (with licenses) is documented in `native/vendor/cimgui/UPSTREAM.md`.
No runtime source download happens: sources are in-tree, artifacts are built by Mix.

## 3. Deviations

**D1 — SDL2 instead of SDL3 (documented, required by the brief's own escape hatch).**
The brief prefers SDL3. This environment has no SDL3 development package (`pkg-config sdl3`
fails, `apt-cache policy libsdl3-dev` has no candidate on Ubuntu 24.04). Options were:
(a) vendor and build SDL3 from source, adding a whole windowing/audio stack to the build;
(b) use the already-installed SDL2 with Dear ImGui's matching upstream backend.
Decision: (b) — SDL2 2.30 is a released, supported ImGui backend target
(`imgui_impl_sdl2.cpp` + `imgui_impl_opengl3.cpp`), keeping the build free of a vendored
graphics stack. All SDL usage sits behind one narrow Zig interface
(`native/host/src/platform.zig`), so moving to SDL3 means replacing one file plus its
backend translation units. Not a claim of SDL3 support.

**D2 — Native window host is a separate executable, not a NIF thread.**
SDL requires video calls on the process main thread; Zigler's `:threaded` NIF runs on a
Zigler-spawned thread, and a dirty scheduler is not the process main thread. The host is
therefore `priv/native/live_cimgui_host`, spawned by the NIF with `posix_spawn`, talking
over an `AF_UNIX` socketpair handed to the child as fd 3.

**D3 — Typed UI constructors first, no template compiler in this milestone.**
The brief allows proving the runtime with typed constructors before syntax work. The
typed vocabulary (`text`, `button`, `input`, `row`, `column`, `keyed`) is the initial
implementation; a template layer is explicitly out of scope for this milestone.

## 4. Architecture implemented

```
Application service (LiveCimgui.Demo.State, GenServer — durable demo data)
    ↕
View process (LiveCimgui.ViewServer + use LiveCimgui.View; mount/3, render/1,
              handle_event/3, handle_info/2 — callback contract, not a LiveView socket)
    ↕
Elixir host manager (LiveCimgui.HostManager — owns the native resource, generation
                     routing, bounded mailbox, restart policy)
    ↕
Zigler NIF bridge (LiveCimgui.Native.open/3, submit/2, close/1 — real Zigler resource)
    ↕
Zig native host executable (native/host/src/*.zig: main thread SDL3→SDL2 event loop)
    ↕
cimgui (C API) / Dear ImGui 1.92.9b
    ↕
Platform backend: SDL2 + OpenGL3 (`platform.zig`, narrow interface)
```

Ownership contract: the application service owns application state and work; the view
owns presentation state and subscriptions; the native host owns immediate interaction and
graphics resources. A window's lifetime never defines the application's lifetime.

## 5. Protocol (see docs/PROTOCOL.md for wire format)

Framed, versioned, length-bounded binary messages. Elixir→host: `hello`, `snapshot`,
`ack`, `set_value`, `ping`, `shutdown`. Host→Elixir: `ready`, `event`, `draft_ack_ack`-
free variants, `diagnostics`, `overload`, `drafts`, `bye`, `protocol_error`.

Concepts: host session id, view generation, UI revision, widget identity + incarnation,
native draft revision, acknowledged draft revision. Every revision has exactly one owner.

## 6. Spike order (evidence first)

1. **Native boundary round trip** — Zigler NIF spawns the Zig host; the host opens a real
   SDL2/OpenGL3 window with a real cimgui context; one command crosses Elixir→host; one
   native event crosses host→Elixir; `close` releases everything without leaks.
2. **Stress-test window** — keyed editor list, busy-5s button, reverse/add/remove/restart
   view, live diagnostics.
3. **Failure boundaries** — view crash, host crash, queue saturation, malformed frames,
   repeated open/close, release path without source-tree paths.

## 7. Decisions that changed during implementation (evidence-driven)

* **Protocol v1 gained four fields while both endpoints were still in flux**, and
  both were updated together: `hello` carries the window size, `ack` and
  `set_value` carry the view generation they belong to (so a delayed update from
  a previous generation is rejected), and `inspect_result` carries the screen
  rectangles of the last frame's interactive items plus the host uptime (which is
  what lets GUI tests click *real* widgets instead of guessing coordinates).
  `docs/PROTOCOL.md` is the specification and the tests pin it.
* **Reconciliation is a handshake, not a heartbeat.** The host originally sent a
  full `drafts` frame after every snapshot; because a view re-renders after every
  message, that produced a render loop at ~79 renders/s. The host now sends
  drafts only when the view generation or the draft *signature* changes (a Zig
  unit test pins it), and the manager additionally drops identical repeats.
* **Zigler 0.16 resource callbacks `stop`/`down` are unusable** (their asserted
  signatures do not match their own call sites), so owner death is handled by the
  resource destructor plus the manager's `terminate/2`, and NIF-unload safety is
  handled by `ERL_NIF_OPT_ON_HALT` + `ERL_NIF_OPT_DELAY_HALT`. See
  `docs/ARCHITECTURE.md` section 4.
* **Dear ImGui 1.92 exports the backend symbols as C++**, so a small `glue.cpp`
  adapter (18 lines of wrappers) exists; `IMGUI_API` is empty upstream now. The
  same file carries the `io.IniFilename` adapter, because cimgui has no setter
  for it and the host must not touch the working directory.
* **Test input is injected through Dear ImGui's own input queue** rather than
  SDL_PushEvent: this environment has no window manager, so the window cannot take
  keyboard focus. The window-system path is recorded as a manual check in
  `docs/TESTING.md` instead of being claimed.

## 8. Known risks

- Zig 0.16 rewrote `std.Io`; the host must keep to APIs verified against the installed
  std source (no 0.15 idioms).
- WSLg has no window manager: X input injection (`xdotool`) may need explicit focus.
  GUI acceptance records whichever path actually moved real pixels/events, and reports
  anything that stayed unverified.
- IME: only synthetic input is testable here; IME stays an explicitly unverified claim.
