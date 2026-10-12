# The live_cimgui protocol

This document is the specification both endpoints implement: the Elixir side in
`LiveCimgui.Protocol` / `LiveCimgui.Protocol.Codec` and the native side in
`native/host/src/protocol.zig`. `LiveCimgui.ProtocolTest`, `LiveCimgui.CodecTest`,
`LiveCimgui.ProtocolRandomTest`, and the Zig unit tests in
`native/host/src/protocol.zig` pin it.

## 1. Framing

```
frame := <<size::little-32, version::8, type::8, body::binary-size(size)>>
```

* `size` counts **only** the body, so a reader validates the length before it
  looks at or allocates anything for the body.
* `version` is the protocol version this frame was written with. It is `1`.
  A frame whose version is not the reader's version is rejected with
  `{:unsupported_version, v}` / `error.UnsupportedVersion`; the reader does not
  guess.
* `type` selects the message. Elixir→host codes are `1..31`, host→Elixir codes
  are `32..63`, and `16..31` is reserved for test-only and fault-injection
  messages. A message that arrives in the wrong direction is rejected.
* Strings are `<<size::little-32, bytes>>`. **Every length is checked against a
  limit before the bytes are used**, and a body that has bytes left over after a
  message is fully decoded is rejected (`{:trailing_bytes, n}`), so a corrupted
  stream cannot silently shift the parse.

### Limits

| Limit | Value | Enforced by |
|---|---|---|
| frame body | 1 MiB (`max_frame_bytes/0`) | encoder, NIF, host reader |
| tree depth | 64 | `UI.validate/1`, encoder, host decoder |
| nodes per description | 4096 | `UI.validate/1`, encoder, host decoder |
| children per container | 1024 | `UI.validate/1`, encoder, host decoder |
| text (value/label/content) | 65536 bytes | `UI.validate/1`, encoder, host decoder |
| widget id / key / session id | 256 bytes | `UI.validate/1`, encoder, host decoder |
| window title | 256 bytes | encoder, host decoder |
| capture path | 512 bytes (`max_path_bytes/0`) | encoder, host decoder |
| native outbound queue | 32 frames / 4 MiB | NIF |
| native inbound command queue | 256 messages / 4 MiB | host |
| manager event queue | 256 events | `LiveCimgui.HostManager` |
| commands per native frame | 512 | `native/host/src/render.zig` |

Widget ids and keys must additionally be **nonempty**: an empty id would make
unrelated widgets share one native identity.

## 2. Messages

### Elixir → host

| Code | Message | Fields | Meaning |
|---|---|---|---|
| 1 | `hello` | `session_id`, `view_generation`, `host_generation`, `title`, `width`, `height` | Adopts the session and window identity. The host creates the window on the first `hello` with a new session. |
| 2 | `snapshot` | `view_generation`, `ui_revision`, tree | A complete validated description. Replaceable: a newer snapshot supersedes a queued older one. |
| 3 | `ack` | `view_generation`, `id`, `incarnation`, `acked_revision` | The highest native draft revision Elixir accepted for that editor. |
| 4 | `set_value` | `view_generation`, `id`, `incarnation`, `base_revision`, text | An explicit application replacement (not an acknowledgement). |
| 5 | `inspect` | `request_id` | Asks for native widget state (see `inspect_result`). |
| 6 | `ping` | `request_id` | Liveness probe; answered with `pong`. |
| 7 | `shutdown` | `reason` (`0` normal, `1` restart) | Asks the host to exit cleanly. |
| 16 | `test_input` | `text` / `key` / `focus` / `mouse` / `capture` | **Test-only.** `text`/`key`/`focus`/`mouse` are injected into Dear ImGui's input queue; `capture` takes a path and asks the host to write the next frame to that file as a binary PPM (`P6`) image, written to `<path>.tmp` and renamed into place only when complete. Never produced by application code. |
| 17 | `fault` | `0` stall, `1` crash, `2` exit | **Test-only.** Fault injection through a separate control path. |

### Host → Elixir

| Code | Message | Fields | Meaning |
|---|---|---|---|
| 32 | `ready` | `session_id`, `host_generation`, `view_generation`, `sdl_version`, `gl_renderer`, `gl_version`, `pid` | The window exists and the Dear ImGui context is live. |
| 33 | `event` | `view_generation`, `ui_revision`, event | User interaction: `button_click`, `input_edit`, `input_submit`, `window_close`. |
| 34 | `diagnostics` | `frame_count`, `ui_revision`, `view_generation`, `focus_id`, `drafts`, `outbound_queue`, `overloads`, `dropped`, `uptime_ms`, `window_width`, `window_height`, `framebuffer_scale` | Periodic native truth, sent every 30 frames. The last three are geometry: the logical window size and the drawable/logical ratio (`1.0` on a standard display, `2.0` on a HiDPI display). `window_size * framebuffer_scale` is exactly what a framebuffer capture contains. |
| 35 | `overload` | `code`, `dropped`, `queue`, `detail` | Something could not be queued; see the codes below. |
| 36 | `inspect_result` | `request_id`, `frame_count`, `ui_revision`, `view_generation`, `focus_id`, `widgets`, `rects`, `uptime_ms` | Native widget state (text, caret, selection, revisions, focus) and the screen rectangles of the interactive items submitted in the last frame. |
| 37 | `drafts` | `view_generation`, drafts | Full native drafts retained by the host, sent after a snapshot so a restarted view can reconcile. |
| 38 | `pong` | `request_id` | Answer to `ping`. |
| 39 | `bye` | `code`, `detail` | The host is exiting. |
| 40 | `protocol_error` | `code`, `detail` | The host rejected Elixir's stream. |

`event` payloads:

```
button_click : id, incarnation, event
input_edit   : id, incarnation, draft_revision, text      # complete UTF-8 draft
input_submit : id, incarnation, draft_revision, text      # Enter inside the editor
window_close : (no fields)
```

### Overload codes

`outbound_full` (native→Elixir queue full), `command_full` (inbound command
queue full), `draft_full` (per-widget draft state exhausted), `frame_oversized`,
`unknown_message`, `stale_session`, `stale_generation`, `stale_incarnation`,
`stale_revision`, `malformed_frame`. Each is reported, never silently swallowed.

## 3. Revision ownership

Every counter has exactly one writer:

| Concept | Owner | Scope |
|---|---|---|
| `session_id` | host manager | One per manager instance; a new one per host restart. Messages for another session are rejected. |
| `host_generation` | host manager | Incremented on every host (re)start. |
| `view_generation` | host manager | Incremented on every view (re)registration. Native messages and `set_value`/`ack` carrying an older generation are rejected. |
| `ui_revision` | host manager | Incremented for every published description. The host reports the revision it last *applied*. |
| widget identity + `incarnation` | application | Identity is `{id, incarnation}`. The application increments the incarnation when it deletes an editor and later recreates it under the same id. |
| `draft_revision` | native host | Incremented for every local text change. |
| `acked_revision` | view (via the manager) | The highest draft revision Elixir accepted; monotonic per `{id, incarnation}`. |

Mismatches are rejected as `stale_*` rather than applied, which is what makes a
delayed message harmless.

## 4. Text synchronisation

1. The native editor is driven by Dear ImGui with its own buffer, so typing is
   responsive without Elixir.
2. On every local change the host increments `draft_revision` and emits
   `input_edit` with the **complete** UTF-8 draft.
3. `LiveCimgui.ViewServer` acknowledges automatically when the view's
   `handle_event/3` accepted the edit: it sends `ack` with the draft revision it
   received, *before* publishing the next description. A view that rejects the
   text keeps the native draft and rewrites the field with a `set_value`/snapshot
   value instead of silently disagreeing with the window.
4. `ack` is monotonic: an acknowledgement with a revision lower than or equal to
   the current one is rejected as `stale_revision`, so an older acknowledgement
   can never move the acknowledged revision (or the text) backwards.
5. **Application replacement during an active draft.** When a value arrives for
   an editor whose draft is unacknowledged (snapshot value or `set_value`), the
   newest value is remembered and applied as soon as the draft is acknowledged
   or the editor loses focus. This is what keeps an in-progress edit — caret,
   selection, and any composition — from being rewritten under the user.
6. Applying a replacement never moves focus and never resets the caret to the
   start: the buffer is replaced in place and Dear ImGui reloads it, clamping the
   caret into the new text.
7. Draft revisions and text are per `{id, incarnation}`. State for a removed
   editor is deleted (buffers and revisions), and `ack`/`set_value` aimed at the
   previous incarnation of a recreated editor are rejected.
8. **Text encoding.** Drafts are UTF-8. The native buffer is capacity-bounded
   (`protocol.max_text_bytes`); a draft that would exceed the bound is truncated
   at the buffer and reported as `draft_full`. Embedded NUL bytes terminate the
   draft: C string APIs cannot carry them, so a NUL is treated as the end of the
   text (documented limitation, not silent corruption). IME composition is
   passed through to Dear ImGui and is recorded as *unverified* in
   `docs/TESTING.md`.

## 5. Bound queues and pressure

* Native outbound (host→Elixir): 32 frames / 4 MiB. Draft updates may be
  **coalesced** while queued (an unsent draft for the same widget is replaced);
  nothing else is coalesced. Saturation reports `outbound_full`.
* Native inbound (Elixir→host): 256 messages / 4 MiB. A newer queued snapshot
  replaces an older queued snapshot; commands keep FIFO order. Saturation
  reports `command_full`.
* Manager event queue: at most 256 pending events per view. Adjacent text edits
  for the same editor coalesce (the newest draft wins); button clicks never
  coalesce. Saturation reports an overload to the view and counts
  `dropped_events`.
* Manager outbound: at most one event in flight per view. The next event is sent
  only when the view commits a render carrying the in-flight render reference,
  which gives natural back-pressure while another event is being processed.
* Per-frame command bound: 512 commands per native frame; overflow is reported
  as `outbound_full` and counted.

## 6. Delivery guarantees

* Native events reach the view **at most once**, in order, per view generation.
  There is no acknowledgement of individual events back to the host, so
  exactly-once delivery is *not* promised and must not be assumed.
* A draft update that is superseded by a newer draft for the same editor may be
  dropped **only** when it is still queued and has not been delivered: the newer
  draft is a complete replacement for the older one.
* Button clicks and `input_submit` events are never coalesced and never dropped
  silently: if a queue cannot take them, the overflow is reported as an
  `overload` and counted in `dropped_events`.
* While a view is stalled, events queue up bounded; a view restart discards the
  queue (and reports how many events were dropped) rather than replaying
  non-idempotent actions blindly.

## 7. Recovery rules

**No atoms from native bytes.** Decoding never turns native input into an atom:
type codes, node tags, event kinds, overload codes and test-input kinds are
matched against fixed tables, and anything unmatched is rejected as
`{:unknown_*, value}`. A hostile or corrupted host therefore cannot exhaust the
atom table.

**Diagnostics are not protocol.** Everything on the socket is framed protocol.
Host diagnostics (startup, window creation, injected input, overloads, panics)
go to the host process's **stderr**, so a reader of the protocol never has to
skip non-protocol output.

**Stale or invalid input.** Unknown version, unknown type, oversized frame,
truncated frame, trailing bytes, invalid enum, invalid identity, and a tree that
violates a limit are all rejected *before* any native state changes; the host
counts `protocol_errors` and, when the stream is unusable, terminates the
transport and reports it to the manager.

**Base mismatch.** The protocol has no partial patches yet: every description is
a complete snapshot, so there is no base revision to mismatch. If patches are
added later they must carry `base_revision` and a mismatch must request a fresh
snapshot (never a partial apply).

**View restart.** The host keeps rendering throughout. A replacement view calls
`HostManager.register_view/2`, receives a fresh `view_generation` plus the
presentation checkpoint of the previous incarnation, and publishes a fresh
snapshot. The host accepts a snapshot for a newer generation, keeps widgets whose
incarnation still matches, and reports surviving unacknowledged drafts in
`drafts`; the view folds those into the application and acknowledges them.
Messages from the previous generation are rejected.

**Host restart.** The manager closes the resource, reports the failure, starts a
new host (new `host_generation`, new `session_id`) within a bounded policy, and
republishes the last validated description. Native drafts do **not** survive host
death unless the application already owns the text; that is not promised.

**Window closed by the user.** The host emits `event.window_close` and `bye`
and exits; the manager treats it as a host failure and applies the restart
policy, so a closed window is visible to the application rather than silent.

**Application shutdown versus view detachment.** `HostManager.close/1` stops the
transport and the host; the application service and the BEAM keep running. A
view process is independent: it can crash or be restarted without touching the
window, and the window can die without touching the application.

## 8. Versioning

`version` is bumped when the framing or any message body changes
incompatibly. Both endpoints reject frames whose version they do not implement
instead of guessing, and the type-code ranges are stable: a new host→Elixir
message takes the next free code in `32..63`, a new test-only message the next
free code in `16..31`.
