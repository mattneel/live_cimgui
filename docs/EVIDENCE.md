# Evidence report

Everything below was produced by running the commands shown, in this workspace,
against the current tree. Nothing here is inferred from reading code. Results I
could not obtain are listed explicitly as unexecuted or unverified.

## 1. Environment

| Item | Value | Command |
|---|---|---|
| OS | Ubuntu 24.04.5 LTS (WSL2) | `cat /etc/os-release` |
| kernel | 7.2.6-locietta-WSL2-xanmod1 | `uname -r` |
| libc | glibc 2.39 | `ldd --version` |
| arch | x86_64 | `uname -m` |
| Elixir | 1.20.2 | `elixir --version` |
| OTP | 28 | `erl -noshell -eval ...` |
| Zig | 0.16.0 (`~/.cache/zigler/zig-x86_64-linux-0.16.0/zig`) | `zig version` |
| SDL | SDL2 2.30.0 + headers | `pkg-config --modversion sdl2` |
| OpenGL | GL 4.6 via WSLg (D3D12/Mesa 26.1.8), direct rendering | `glxinfo -B` |
| display | `DISPLAY=:0`, `WAYLAND_DISPLAY=wayland-0` (WSLg) | environment |

SDL3 is **not** available on this system (`pkg-config sdl3` fails, no
`libsdl3-dev` candidate), which is why the platform backend uses SDL2 with Dear
ImGui's matching `imgui_impl_sdl2` backend. See `docs/ARCHITECTURE.md` §5.

## 2. Commands and results

| Command | Result |
|---|---|
| `mix deps.get && mix compile` | builds the Zigler NIF and the host executable; no warnings |
| `mix test` | **119 passed** (1 doctest, 118 tests), 10 excluded (`:gui`) |
| `mix live_cimgui.gui_test` | **10 passed**, 104 excluded — real window, real Dear ImGui, real input injection |
| `mix live_cimgui.native_test` | **13 passed** (host unit tests, display-independent) |
| `mix live_cimgui.gui_test` pressure case (reported by the failure suite) | 1200 injected frames, 0 rejected as overloaded, 262 events handled, `pending_events: 0`, `dropped_events: 138` (first drop at 1), `overloads: 0`, `stale_messages: 0` — bounded and loud, exactly as documented |
| `mix run /tmp/demo_iex_check.exs` (test env) | demo title, widgets, IEx reorder, view restart — see §4 |
| `mix ci` | **exit 0**: `compile --warnings-as-errors`, `format --check-formatted`, `test` (119 passed), `credo --strict` (no issues), `dialyzer` (0 errors), `ex_dna --max-clones 0` (no clones), `reach.check --arch --smells` (policy OK) |
| clean checkout + `mix release` | see §5 |

## 3. Acceptance cases

| # | Requirement | Evidence | Status |
|---|---|---|---|
| 1 | A native button event reaches `handle_event/3`; an assign change updates the native window | `test/live_cimgui/gui/interaction_test.exs` "case 1a" (injected click → `{:view, {:button, "a", %{"id" => "a", "incarnation" => 1, "event" => "a"}}}`), "case 1 (window side)" (click changes an assign that the window then displays: `clicks=0` → `clicks=1` → `clicks=3`, `ui_revision` increases) | **passed** |
| 2 | Native input and frame progress continue during the five-second callback; Elixir later acknowledges the draft | "case 2": during the stall `frame_count` advances past a +20-frame bound, injected text produces a native draft with `draft_revision ≥ 1` and `ack_revision < draft_revision`, the callback takes ≥ 4.5 s, and only afterwards the view receives the edit and the host reports `ack_revision ≥ draft_revision` with the text intact | **passed** |
| 3 | A keyed reorder preserves the editor's text, caret, and selection; native state follows the key | "case 3": two editors typed into, a selection dragged with real pointer input, then the view reverses its keyed collection; the tracked editor moves from last to first (`render_order` reversed), and its `incarnation`, `text`, `cursor`, and `selection` are unchanged; no editor inherits another's text | **passed** |
| 4 | A delayed acknowledgement cannot overwrite newer text; a deleted editor cannot receive an update for its previous incarnation | "case 4" (ack with an older revision leaves `ack_revision` and text untouched; the host reports the rejection as an `overload`) and "case 4b" (deleted editor leaves the widget set, the recreated key appears with incarnation 2 and fresh text, and a `set_value` aimed at incarnation 1 is refused) | **passed** |
| 5 | A view crash does not close the native window; the replacement view restores subscriptions and reconciles state | `test/live_cimgui/gui/failure_test.exs` (view restarted: `view_generation` bump, host `host_generation` unchanged, frame progress continues); the demo run in §4 (`view_generation 1 → 2`, widgets intact); and a dedicated re-subscription probe (below) | **passed** |
| 6 | A native host crash does not terminate the application service; a replacement host reconstructs the UI | `failure_test.exs` (host killed: `host_generation` increases, an `Agent` acting as the application service stays alive, the manager stays responsive, the description is rebuilt) and `HostManager.restart_host/2` exercised in `test/live_cimgui/native_integration_test.exs` | **passed** |
| 7 | Queue saturation stays bounded and reports overload without corrupt state | `failure_test.exs` pressure case (≈400 alternating clicks against a stalled view: `pending_events ≤ 256`, `dropped_events > 0`, manager responsive, no stale messages) plus host-side queue bounds and `overload` frames | **passed** |
| 8 | Malformed, oversized, truncated, and obsolete messages are handled without unsafe access | `test/live_cimgui/protocol_test.exs`, `codec_test.exs`, `protocol_random_test.exs` (every truncation of valid frames, random byte frames, bad versions, unknown types, trailing bytes; "never raises" properties), `native_integration_test.exs` (`submit/2` rejects short/mismatched/wrong-direction/oversized frames), Zig unit tests in `native/host/src/protocol.zig`, `HostManager` session-hygiene test | **passed** |
| 9 | Repeated open/close/restart/add/remove release resources; closed resources reject submission | `native_integration_test.exs` (repeated open/close cycles with `/proc/self/fd` and `/proc/self/status` thread counts before/after; `close/1` idempotent; `submit/2` → `:closed` after close), demo add/remove/reverse drives in §4, `HostManager.restart_host/2` and `restart_view/1` | **passed** |
| 10 | A clean checkout builds through the documented commands; a release finds its native executable without source-tree paths | `/tmp/verify_clean.sh` — staged tree without `_build`, `deps`, `.git`, or built artifacts: `mix deps.get`, `mix compile`, `mix test`, `mix live_cimgui.native_test`, `mix release`, then a release-run window check from `/` as the working directory | see §5 |

## 4. Demo (the stress-test window) — independent run

`MIX_ENV=test mix run /tmp/demo_iex_check.exs`, with the real window:

```
DEMO: title="live_cimgui — Native interaction. Elixir application state."
DEMO: window=940x620
DEMO: widgets=["reverse", "restart-view", "bravo", "busy", "add", "alpha", "remove", "draft", "charlie"]
DEMO: frame_count=34 applied_revision=2
DEMO: rows=[{"alpha", 1, "Alpha"}, {"bravo", 1, "Bravo"}, {"charlie", 1, "Charlie"}]
DEMO: focused="charlie" charlie=%{text: "Charlie-iex", cursor: 11, incarnation: 1, selection: {7, 7}, draft_revision: 1, ack_revision: 0}
DEMO: after reverse editors=["charlie", "bravo", "alpha"]
DEMO: focus_id="charlie" charlie=%{text: "Charlie-iex", cursor: 11, incarnation: 1, selection: {7, 7}, draft_revision: 1, ack_revision: 1}
DEMO: focus preserved=true
DEMO: state preserved=true
DEMO: view_generation 1 -> 2
DEMO: after view restart widgets=["reverse", "restart-view", "bravo", "busy", "add", "alpha", "remove", "draft", "charlie"]
DEMO: stop=:ok
```

This is the "list reorder from IEx without an unrelated focus change"
requirement: `LiveCimgui.Demo.reverse/0` reordered the rows, the editor moved from
last to first, and the focused editor kept its text, caret, selection, and focus.
`LiveCimgui.Demo.restart_view/0` then replaced the view process (generation 1 → 2)
while the window and its widget set survived.

Fault injection is a separate control path (`LiveCimgui.Demo.restart_host/0`,
`LiveCimgui.Demo.restart_view/0`, `LiveCimgui.HostManager.inject/2` with the
protocol's test namespaces), never an application command.

### Re-subscription after a view restart (probe output)

```
SUB: generation=1 rows=["alpha", "bravo", "charlie"]
SUB: after restart generation=2
SUB: add_row -> {:ok, %{text: "Row 1", key: "row-1", incarnation: 1}}
SUB: application rows now=["alpha", "bravo", "charlie", "row-1"]
SUB: window widgets now=["reverse", "restart-view", "bravo", "busy", "add", "alpha", "remove", "draft", "charlie", "row-1"]
SUB: replacement view is subscribed=true
SUB: stop=:ok
```

The application change was made *after* the restart, and the replacement view
rendered it into the window (`row-1` appears in the native widget set), which is
what "restores subscriptions" means here: the new view process subscribes in
`mount/3`, and the application service prunes dead subscribers on broadcast.

## 5. Clean checkout and release

`bash /tmp/verify_clean.sh` stages the working tree into `/tmp/lvclean` **without
`_build`, `deps`, `.git`, or any built artifact**, then runs the documented
commands there:

| Step | Result |
|---|---|
| `mix deps.get` | ok |
| `mix compile` | NIF built by Zigler (`priv/lib/Elixir.LiveCimgui.Native.so`), host built and installed (`priv/native/live_cimgui_host`) |
| `mix test` | **119 passed** (1 doctest, 118 tests), 10 excluded |
| `mix live_cimgui.native_test` | **13/13 tests passed** |
| `mix release` | ok |
| release artifacts | `lib/live_cimgui-0.1.0/priv/lib/Elixir.LiveCimgui.Native.so`, `lib/live_cimgui-0.1.0/priv/native/live_cimgui_host` |
| release resolves its executable | `/tmp/lvclean/_build/prod/rel/live_cimgui/lib/live_cimgui-0.1.0/priv/native/live_cimgui_host`, `exists=true`, `cwd=/tmp/lvclean` |
| release opens a window from `/` as cwd | `live_cimgui_host: window open (session …, SDL2 + OpenGL3)` … `release window check: ok` |
| whole script | `CLEAN_EXIT=0` |

No source-tree path and no download is involved at runtime: the release carries
both artifacts and resolves the host through `Application.app_dir/2`.

## 6. Quality gate

`mix ci` runs `compile --warnings-as-errors`, `format --check-formatted`, `test`,
`credo --strict`, `dialyzer`, `ex_dna --max-clones 0`, and
`reach.check --arch --smells`. Results are recorded in §7.

## 7. Results of the final gate

`mix ci` passes end to end (`CI_EXIT=0`):

| Step | Result |
|---|---|
| `compile --warnings-as-errors` | clean |
| `format --check-formatted` | clean |
| `test` | 119 passed (1 doctest, 118 tests), 10 `:gui` excluded |
| `credo --strict` | no issues (36 files, 625 mods/funs) |
| `dialyzer` | `Total errors: 0` (PLT includes `:ex_unit` and `:mix`, which the custom mix tasks need) |
| `ex_dna --max-clones 0` | no code duplication detected (22 files) |
| `reach.check --arch --smells` | architecture policy OK |

Alongside it: `mix live_cimgui.gui_test` → 10 passed (real window), and
`mix live_cimgui.native_test` → 13 passed.

Two measured numbers worth recording, because they were defects before they were
numbers: `Livecimgui.Native.close/1` costs **~20 ms** per transport (it was
~2010 ms while the reap waited out a timeout for a child the runtime had already
collected), and a saturated view queue sheds load loudly — 1200 injected frames,
0 rejected, 262 events handled, `dropped_events: 138`, `overloads: 0`,
`stale_messages: 0` — instead of hanging as it did before the queue-locking fix.

## 7b. Framebuffer capture: pixels as evidence

Added after the first report, because the question "what does the window actually
show?" deserved an answer better than "the widget state says so".

| Step | Command | Result |
|---|---|---|
| Build the capture-capable host | `mix live_cimgui.build_native` | installed to `priv/native/live_cimgui_host` and `_build/dev/lib/live_cimgui/priv/native/live_cimgui_host` |
| Demo window (initial state) | the `mix run -e` snippet in `docs/TESTING.md` §4b (`Demo.start/0`, wait for the first applied revision, `{:test_input, :capture, path}`) | `captured /tmp/live_cimgui_demo.ppm: 1748415 bytes` (`940 * 620 * 3 + 15` — header plus every pixel, so no frame was truncated) |
| Encode for viewing | `convert /tmp/live_cimgui_demo.ppm docs/images/demo-window.png` | `940x620`, 19 colours |
| Pixel statistics | binary PPM parsed directly | 17 distinct colours in the raw frame, 1569 near-white glyph pixels, dominant colours `(15,15,15)` window body, `(15,18,23)` clear colour, `(41,74,122)` active title bar |
| Pixel tests | `mix live_cimgui.gui_test test/live_cimgui/gui/capture_test.exs` | **3 passed**: geometry = `window_size * framebuffer_scale` from the host's own diagnostics, **zero clear-colour pixels** (the panel covers the client area), `distinct_colors > 4`, `bright_pixels > 200`, a description change moving **>500 pixels while leaving 19/20 of the frame untouched**, and a 1024x768 window captured at exactly 1024x768 and flush |
| Layout defect, before and after | the same capture routine, before/after the fix | before: panel at `(60, 60)`, `880x560`, **60 px clear-colour margins** top and left, plus a second title bar inside the client area; after: panel at `(0, 0)`, `940x620`, **0** clear-colour pixels, one title (the platform window's) |

`docs/images/demo-window.png` is that demo frame. The rendering was also
confirmed by eye on this machine's display (WSLg) for the capture-test window:
title bar reading `live_cimgui capture`, diagnostics line
`ui revision 2  view generation 1  snapshots 2`, `capture view`, a `draft:`
editor showing `draft text`, the keyed editor `alpha` showing `Alpha`, and the
`Act` button.

## 8. Defects found by this work (and fixed)

Verification paid for itself: the following were discovered by tests and fixed,
not by reading code.

| Defect | How it was found | Fix |
|---|---|---|
| `EBADF` write before `accept` made every host restart fail (`peer_unavailable` → restart loop) | `/tmp/probe_restart_host.exs` (demo agent) + `HostManager.restart_host/2` | transport only writes once the host has connected |
| Outbound queue drained without the transport mutex → `bytes` underflow panic (SIGABRT in the BEAM) | full-suite run of the GUI acceptance tests | every queue inspection/mutation now happens under the transport mutex |
| `flush_acks/1` reducer arity/key mismatch → `BadArityError` on the first keystroke | demo agent's editor drive | reducer matches `{ {id, incarnation} => revision }` |
| A `drafts` frame after every snapshot made views render forever (~79 renders/s) | demo agent's revision measurements | host sends drafts only on generation change or draft-signature change; manager drops identical repeats |
| `isUserEdit` compared a stale buffer length, discarding every real edit | text injection tests | refresh the buffer from its NUL terminator before comparing |
| `setBufferText` never wrote the NUL terminator, so stale bytes looked like text | Zig unit test | buffer writes always terminate |
| Writing an unchanged value back into an editor's buffer made Dear ImGui report an edit every frame (draft-revision storm) | spike run | skip identical writes; ignore reload echoes |
| `UI.validate/1` raised instead of returning an error for malformed keyed children and accepted empty/over-long/non-binary keys | protocol/UI test agent | keyed children and keys are validated totally |
| Snapshot decoding dropped the message envelope (returned the raw tree tuple) | protocol/UI test agent | decoder consumes the tree's rest and count; trailing bytes rejected |
| `Protocol.decode` did not enforce the children limit, and `set_value` had mismatched encode/decode shapes | protocol/UI test agent | decoder enforces limits; `set_value` carries its view generation on both sides |
| `mod:` named the application module with the wrong capitalization, so the supervision tree never started | GUI acceptance run | `mod: {LiveCimgui.Application, []}` |
| Supervised managers were `:permanent`, so a normal `HostManager.close/1` **resurrected a window** and, under repeated restarts, took the host supervisor down (which then made `start_child` fail with `:shutdown`) | GUI acceptance run (setup failed in one test) | `HostManager.child_spec/1` uses `restart: :transient`: a normal stop stays stopped, a crash still gets a replacement |
| After the manager-state refactor, `queue_ack/4` wrote a phantom top-level `:pending_acks` key, so acknowledgements were silently lost (native text stayed unacknowledged) | ack-path probe (`/tmp/ack_probe.exs`) | the ack queue writes `pending.acks`; a direct probe now shows `outcome=acknowledged` and a duplicate ack rejected as `stale_revision` |
| `Native.close/1` cost ~2010 ms per transport and always SIGKILLed: the runtime's child reaper had already collected the host, so `waitpid` never returned it and the reap waited out its full timeout | TestStack measurement + `/tmp/close` probe | `reapChild/2` treats `ECHILD` as "already reaped" and returns immediately: **measured close 20 ms**, and `child_status` stays `-1`, which now means "not observed" rather than "still running" |
| `submit/2`'s rejection paths did not increment the transport's `malformed` counter | TestStack | rejections are counted; verified `malformed: 1` after a rejected frame |
| `PhoenixAdapter.assign_many/2` called `Map`-style access on the `{key, value}` tuples it enumerates, so a *map* argument raised `BadMapError` | the adapter compatibility test written for the documented behaviour | the map is enumerated with `Map.to_list/1`; both map and keyword inputs are covered |
| `writePpm` copied the capture path into its temp-path buffer with mismatched lengths → `@memcpy` panic (SIGABRT) on the first capture request; the manager restarted the host, which is how it was seen | first capture probe run | copy the path and the `.tmp` suffix separately |
| The panel was sized `Cond_FirstUseEver` and never positioned: every window showed an 880x560 panel at Dear ImGui's default `(60, 60)` with its own title bar restating the platform window's title | the user's screenshot of a running test window (two window frames, visibly off-centre content) | the panel is positioned `(0, 0)` and sized from the live window every frame (`Cond_Always`), with `NoTitleBar\|NoResize\|NoMove\|NoCollapse`; the platform window is the only frame, and the defect is now a test: a capture must contain zero clear-colour pixels |
| A pre-capture `priv/native/live_cimgui_host` in the source tree silently replaced every freshly built host in `_build`, because Mix mirrors `priv/` into the application directory on each compile — the running node kept executing the old binary while `mix live_cimgui.build_native` reported a successful install | capture requests rejected as `malformed_frame` after a successful rebuild; `md5sum` of both paths showed the stale file winning | the build task now installs to **both** the source `priv/native/` and the application directory, and treats either as a build target; documented as a pitfall in `docs/TESTING.md` §4c |
| Dialyzer could not see the hand-built socket as `Socket.t()` (a mounted LiveView socket has a router and endpoint; this one deliberately has neither) | `mix ci` | the adapter's `socket()` type now states exactly which fields are `nil`, and `:mix`/`:ex_unit` are in the PLT so the mix tasks are analysable |

## 9. Not executed here (and therefore unverified)

* **Real X11/Wayland input** (`xdotool` typing into the window): WSLg here has no
  window manager, so the window cannot take keyboard focus. GUI tests inject
  input through Dear ImGui's own input queue, which exercises ImGui's input
  handling, the widget text state, and the edit callback, but not the X event
  path. The manual procedure is documented in `docs/TESTING.md` §5.
* **IME composition** (CJK, dead keys): not exercised. An ASCII test is not
  evidence of IME support.
* **Other platforms** (macOS, Windows, aarch64, musl) and other backends
  (SDL3, Vulkan, GLES): untested; no support claimed.
* **Valgrind/ASan** runs: not performed; Zig's safety checks and
  `std.testing.allocator` leak detection are used instead.
* **Bare framebuffer**: not supported and not tested.
