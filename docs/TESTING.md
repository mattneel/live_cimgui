# Testing and acceptance

## 1. Toolchain this project is pinned to

| Component | Version | How it is pinned |
|---|---|---|
| Elixir | 1.20 | `mix.exs` (`elixir: "~> 1.20"`) |
| Erlang/OTP | 28 | environment |
| Zig | 0.16.0 | Zigler's `zig_version/0`; `mix live_cimgui.build_native` refuses a different version |
| cimgui | commit `125f397…` (`docking_inter`) | vendored under `native/vendor/cimgui` (`UPSTREAM.md`) |
| Dear ImGui | commit `b48d1af…` (`1.92.9b`, `IMGUI_VERSION_NUM 19291`) | vendored; the exact revision `cimgui.h` was generated from |
| SDL2 | 2.30.0 (`libsdl2-dev`) | system package |
| OpenGL | 3.3 core (GL 4.6 available) | `ldconfig`/driver, provided by the display stack |

System prerequisites (Ubuntu 24.04 names):

```sh
sudo apt-get install -y libsdl2-dev libgl1-mesa-dev
# a display is required for the GUI suite: X11, Wayland, or WSLg
```

Zig resolution order (implemented in `Mix.Tasks.LiveCimgui.BuildNative`):

1. `ZIG` environment variable,
2. Zigler's cache: `~/.cache/zigler/zig-<arch>-<os>-0.16.0/zig`,
3. `zig` on `PATH`.

## 2. Commands

```sh
mix deps.get                                        # dependencies
mix compile                                         # Elixir + NIF + native host executable
mix test                                            # display-independent suite (GUI tests excluded)
mix live_cimgui.native_test                         # native host unit tests (Zig, no display)
mix live_cimgui.gui_test                            # real-window acceptance tests (needs a display)
mix live_cimgui.demo                                # runs the stress-test window
mix release                                         # release, including both native artifacts
mix ci                                              # the project's full gate (compile/format/test/credo/dialyzer/ex_dna/reach)
```

`mix compile` builds the host executable through the project's `compile` alias
(`mix live_cimgui.build_native`, incremental). Build artifacts:

* `priv/lib/Elixir.LiveCimgui.Native.so` — the NIF (built by Zigler),
* `priv/native/live_cimgui_host` — the native host executable (built by the alias).

Both are resolved at runtime through `Application.app_dir/2`
(`LiveCimgui.Native.host_executable/0`), so no source-tree path and no current
working directory is involved.

## 3. What each suite covers

| Suite | Command | Needs a display? | Covers |
|---|---|---|---|
| Protocol | `mix test test/live_cimgui/protocol_test.exs` | no | framing, limits, every message shape, `{:more, n}` boundaries, rejection of unknown version/type/oversized frames |
| Codec | `mix test test/live_cimgui/codec_test.exs` | no | tree encode/decode per node kind, keyed identity, limits, malformed/truncated/trailing bytes, every overload and event payload |
| UI vocabulary | `mix test test/live_cimgui/ui_test.exs` | no | constructors, validation errors with path and reason, duplicate identities, keyed keys, limits |
| Randomized | `mix test test/live_cimgui/protocol_random_test.exs` | no | seeded round trips, keyed permutations, malformed corpora, "never raises" properties |
| Adapter | `mix test test/live_cimgui/phoenix_adapter_test.exs` | no | the exact Phoenix facilities used (assigns, change tracking, checkpoint replay) |
| Native integration | `mix test test/live_cimgui/native_integration_test.exs` | no | real Zigler bridge + real host process: open/submit/ping/pong/stats, idempotent close, malformed and oversized submits, descriptor and thread hygiene over repeated open/close |
| Native boundary | `mix test test/live_cimgui/native_boundary_test.exs` | no | real snapshot traffic through the bridge, session separation, manager session hygiene |
| Service | `mix test test/live_cimgui/demo_state_test.exs` | no | application-service rules (ordering, incarnations, normalization, bounds, broadcasts) |
| GUI interaction | `mix live_cimgui.gui_test` | **yes** | button event → `handle_event/3`, assign change visible in the window, frame progress during a 5 s stall, keyed reorder preserving text/caret/selection, delayed acknowledgement, deleted/recreated incarnation |
| GUI failure | `mix live_cimgui.gui_test` | **yes** | view crash keeps the window, host crash keeps the application, bounded restart policy, queue saturation reporting |

The GUI suites are tagged `:gui` and excluded by `test/test_helper.exs`; run them
with `mix live_cimgui.gui_test` (the task selects `MIX_ENV=test` for you), which
refuses to claim success without a display:

```
No display available (DISPLAY and WAYLAND_DISPLAY are unset): GUI acceptance is UNVERIFIED.
```

## 4. Native diagnostics used as evidence

* `LiveCimgui.HostManager.inspect_host/1` reads the host's real widget state:
  text, caret position, selection range, focus, draft and acknowledged revisions,
  plus the screen rectangles of the interactive items submitted in the last frame.
  GUI tests use those rectangles to click the real widgets.
* `LiveCimgui.HostManager.status/1` exposes generations, queue depths, dropped
  counts, overload history, transport counters, and the BEAM mailbox length.
* `/proc/self/fd` and `/proc/self/status` (threads) are sampled before and after
  repeated open/close cycles to show that resources are released.
* The native host sends diagnostics every 30 frames
  (`{:diagnostics, %{frame_count: …}}`), which is what proves frame progress while
  Elixir is stalled.

## 4b. Automated framebuffer capture (pixels as evidence)

The GUI suites can read the window's own pixels: `{:test_input, :capture, path}`
(protocol type 16) makes the native host write the *next* frame — read with
`glReadPixels` immediately before the buffer swap — to `path` as a binary PPM
(`P6`) image. The image is written to `path <> ".tmp"` and renamed, so a reader
never sees a half-written frame.

```elixir
# in a GUI test (see `LiveCimgui.GuiHarness.capture!/2`)
image = capture!(manager, Path.join(tmp_dir, "frame.ppm"))
image.width          # => 940
image.height         # => 620
image.distinct_colors
image.bright_pixels
pixel_diff(before, after)
```

```sh
# an image you can look at, from the demo window
mix run -e '
  {:ok, _} = Application.ensure_all_started(:live_cimgui)
  {:ok, m} = LiveCimgui.Demo.start()
  Process.sleep(1_000)
  :ok = LiveCimgui.HostManager.inject(m, {:test_input, :capture, "/tmp/demo.ppm"})
  Process.sleep(500)
  LiveCimgui.Demo.stop(m)'
convert /tmp/demo.ppm docs/images/demo-window.png   # ImageMagick
```

`test/live_cimgui/gui/capture_test.exs` asserts on those pixels:

* the capture is exactly `window_width * framebuffer_scale` by
  `window_height * framebuffer_scale` pixels, using the geometry the host
  reports in its diagnostics (so the assertion holds on a HiDPI display too);
* the panel covers the whole client area: **no** pixel is the clear colour, which
  is what an inset panel or a stale panel size leaves behind;
* a second window opened at 1024x768 is captured at 1024x768 and flush, so the
  panel follows the window rather than a constant;
* the frame is not a flat fill (`distinct_colors > 4`), text is drawn
  (`bright_pixels > 200`), and a *description change moves pixels* — more than
  500 pixels change when a new row is added, while the untouched remainder
  (19/20 of the frame) does not.

HiDPI itself is **not** verified here: this machine's display runs at
`framebuffer_scale = 1.0`, so the scaled path is exercised but not observed. The
host's font-scaling call and the geometry report are covered; a claim about
crispness on a 2x display needs a 2x display. A screenshot is still never the *only* evidence: the acceptance claims
rest on native widget state, revisions, and frame counters, and the capture is
used where pixels are the observable in question.

GUI tests open a real window on the machine's display; run them when that is
acceptable (`mix live_cimgui.gui_test`), and note that they are excluded from
`mix ci` for that reason.

## 4c. Rebuilding the host (and the one pitfall)

```sh
mix live_cimgui.build_native          # incremental; --force rebuilds
```

`mix compile` runs the same task through the `compile` alias, so `mix test`,
`mix run`, and releases pick up a current host automatically.

**Pitfall.** Mix mirrors `priv/` into `_build/<env>/lib/live_cimgui/priv` on every
compile. A stale `priv/native/live_cimgui_host` left in the *source* tree
therefore silently replaces a freshly built host in `_build`, and the running
node keeps executing the old binary. `mix live_cimgui.build_native` prevents this
by writing the build output to **both** the source `priv/native/` and the
application directory, and by treating either copy as a build target when
deciding whether a rebuild is needed. If a host ever behaves like an older
revision, check both paths:

```sh
md5sum priv/native/live_cimgui_host _build/*/lib/live_cimgui/priv/native/live_cimgui_host
```

## 5. Manual checks (recorded separately from automated results)

These cannot be automated in this environment and are **not** claimed as
verified:

* **Real keyboard/mouse input via the window system.** The GUI suites inject input
  through Dear ImGui's own input queue (`LiveCimgui.HostManager.inject/2`, a
  test-only protocol path). That exercises ImGui's input handling, the widget's
  text state, and the edit callback, but it is not the X/Wayland event path.
  WSLg here has no window manager, so the window cannot take keyboard focus;
  `xdotool`-driven typing is therefore a manual procedure:

  ```sh
  mix live_cimgui.demo &                      # window appears
  xdotool search --name "live_cimgui" windowfocus --sync
  xdotool type --delay 60 "typed by the window system"
  ```
  Record what the window shows, and whether the draft revision and the
  acknowledged revision advanced in the diagnostics block.
* **IME composition** (CJK input, dead keys). Passed through to Dear ImGui's
  platform backend; not exercised automatically. A synthetic ASCII test is *not*
  evidence of IME support.
* **Visual appearance in a real window manager.** Screen-level screenshots are
  not what the automated runs assert on (see the capture path below); the window
  the tests open is nevertheless a real, visible X11 window under WSLg, and
  `docs/images/demo-window.png` in this repository was produced from the demo
  window's own framebuffer.
* **Clipboard and selection gestures.** Copy/paste inside an editor is handled by
  Dear ImGui's own single-line text editor and its SDL2 clipboard binding; the
  acceptance tests exercise typing, caret placement, and selection by pointer
  drag, but not the clipboard round trip.
* **Other platforms.** Only Linux x86_64 with glibc is exercised. macOS, Windows,
  aarch64, and musl are untested and unsupported by this milestone.

## 6. Native allocation diagnostics

* Zig unit tests run with `std.testing.allocator`, which fails the test on leaks
  and double frees.
* `zig build -Doptimize=Debug` (the default for `mix live_cimgui.native_test` when
  the environment does not pass `--release`) keeps safety checks enabled, so
  out-of-bounds and use-after-free panics surface as test failures.
* `Livecimgui.Native.close/1` is idempotent, costs tens of milliseconds, and the
  integration suite checks descriptor and thread counts across repeated cycles.
  The transport thread also reaps the host process, so no zombies remain; note
  that ERTS' own child reaper usually collects the host first, in which case
  `stats/1`'s `child_status` stays `-1`, meaning "exit status not observed".
* Valgrind/ASan are not part of the default runs; `zig build -Dsanitize=…` can be
  added if a deeper native audit is needed.
