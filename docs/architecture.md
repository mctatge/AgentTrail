# Architecture

AgentTrail records explicitly started demonstrations on macOS. It keeps immutable input evidence alongside replaceable interpretations. It has no server, telemetry, automatic upload, OS action replay engine, or model dependency.

## Capture path

`InputCapture` installs a listen-only annotated-session `CGEventTap` on a dedicated `CaptureRunLoop` thread. Its callback only copies event fields, checks secure input, handles recorder shortcuts, and appends to a locked `InputEventBuffer`. It never calls AppKit, the clipboard, AX, SQLite, or UI callbacks. A disabled tap is immediately re-enabled on its own thread and a failure marker retains the OS disable cause. It does not consume or modify application events. macOS event coalescing occurs before this layer.

The input buffer delivers batches on a 25 ms main-thread timer in common run-loop modes, so ordinary menu tracking and resizing do not suspend delivery. Capture continues independently during a main-thread stall, subject to an 8,000-record delivery budget. Overflow retains a counted gap at the correct position. Pause/resume switches immediately inside the buffer, before main-thread delivery; their ordered lifecycle records and bounded-input overflow marker are drained on stop. Lifecycle markers can exceed the ordinary-input budget. Stop joins the capture thread before flushing, so inputs cannot arrive after the session-end marker.

Application lookup occurs only during main-thread delivery. `target_pid` from annotated CG events identifies the recipient when available, including interactions with inactive windows. Otherwise the event retains the last observed foreground snapshot and its observation time; attribution is labeled, not presented as a guaranteed event target. An unresolvable nonzero target is omitted with a privacy gap rather than attributed to another app. Workspace activation drains earlier buffered inputs before updating the fallback snapshot.

`RecordingModel` applies session/pause/application/secure-input gates, attaches a recent context only if it was observed no later than the input, and enqueues events. A serial writer queue commits batches through `TrailStore` about every 100 ms using a common-mode flush timer. The writer also feeds `ActionBuilder`. Main-thread stalls can delay persistence/context, but cannot directly stall the tap callback. Long stalls or slow storage can still exhaust a buffer and are not lossless.

Intentional recorder/app/password exclusions keep raw `gap` boundaries but display as “Not recorded,” not capture failures. `CaptureGap` normalizes legacy derived summaries on read without changing the recorded evidence. Timeouts, capacity exhaustion, and other capture failures remain visibly labeled “Capture gap.”

`ContextResolver` uses a separate queue and bounded AX messaging timeouts. It samples a focused element or hit-tests a click and reads app/window metadata. The optional `ExcelResolver` uses a separate AppleScript queue with a two-second event timeout. Neither writes to the foreground application. A generation token invalidates pending observations on pause, app change, or stop.

`ScreenshotCapture` uses ScreenCaptureKit only when selected, after meaningful inputs and at most once per second. It captures an available window belonging to the foreground process. Capture callbacks are discarded after a session/app change or protected-input transition. Frames are JPEGs and linked by a separate timestamped event. This is best-effort visual context, not synchronized video.

## Data path

`TrailStore` owns a system SQLite connection. The schema has sessions, raw events, and grouped actions. Access is serialized with a recursive lock; writes use explicit WAL transactions and full synchronization. Reads in the UI run off the main thread. `WriterLease` prevents two app/demo writer processes from using the same library at once; MCP clients use separate read-only connections.

A raw event receives its monotonic database ID at insertion. JSON stored inside the row initially contains ID zero; decoding always replaces it with the SQLite row ID. References use that actual row ID. Session IDs are UUIDs. Every query is bound and constrained to a session; query tools expose no raw SQL.

Action groups retain first/last event IDs, app identity, timestamps, counts, and an optional sampled context. Modifier and key-up records remain in the raw stream but do not each become timeline actions. Context and screenshot observations carry `relatedEventID` and can appear later than their input in insertion order. The inspector joins linked observations. Live action groups become visible when a boundary closes them; finishing flushes the final group.

`SessionExport` walks all event/action pages for a finished session, writes JSONL and Markdown, and copies safe attachment paths. Exports refuse existing destinations and clean up partial results on failure. The training wrapper explicitly sets outcome/input-origin verification to false. It does not manufacture a successful result or a pre-action screenshot.

## Cursor review and raw output

`TrailStore.cursorPage` reads session-scoped pointer inputs and discontinuity markers by event ID, capped at 20,000 records plus one look-ahead row. It supports an action's inclusive event range and never silently downsamples. `CursorTrail` derives drawable samples, breaks, bounds, and relative playback time. Invalid coordinates are omitted from drawing and break the path; their raw records remain intact. Aspect-preserving projection supports negative global coordinates and degenerate stationary/vertical paths.

`CursorTrailView` loads pages off the main thread, draws with native SwiftUI Canvas, and runs visual playback at up to 30 updates per second. It uses recorded monotonic deltas when available, with nonnegative wall-time deltas as a fallback. The UI always displays actual samples instead of inferred intermediate cursor positions. Equal-time inputs remain individually inspectable using the step buttons. Discontinuities, app/session changes, and idle intervals over two seconds prevent misleading connecting lines. A page starts its own path; use Previous/Next part to inspect longer sessions. This viewer is a coordinate map, not a screenshot registration layer or OS input replayer.

`RawLog.write` pages through all committed raw events and streams one canonical JSON object per line to an output callback, returning the last emitted ID. The CLI `raw` command uses this for full output; `--follow` polls for additional committed rows and drains once more after the session reaches a terminal status. A paused session keeps the reader waiting. Ctrl-C stops only the reader. Interrupted sessions whose writer crashed remain followable until recovery marks them interrupted, so a user can interrupt a waiting reader manually. Read-only clients do not create or repair sessions.

## Recovery and lifecycle

There is no auto-start capture. Start creates a session and event tap; Pause keeps the pause shortcut available but drops ordinary inputs; Finish tears down capture, drains queued writes, flushes actions, and marks the session complete. Sleep or loss of the login session pauses recording. Closing the workspace keeps the menu item visible. Quit waits for session finalization.

`AppRunLoopTimer` registers permission-refresh and termination polling in common modes and explicitly in AppKit's modal-panel mode. A default-mode-only timer can stop firing during deferred termination: Apple's [`terminateLater` contract](https://developer.apple.com/documentation/appkit/nsapplication/terminatereply/terminatelater) runs a modal loop until the delegate replies. The timer never forces termination before the writer finishes. Permissions are also rechecked when the app becomes active or Capture settings opens. Checks report what macOS recognizes; they do not grant access or repair stale signing identities.

Capture choices persist to UserDefaults as soon as they change, including before any recording starts. Session options remain a snapshot taken at Start. Settings provide Recheck access, Reveal this app, and an explicit Quit command; content scrolls while Done and Quit remain visible. A source rebuild can still require reauthorization because the default signature is ad hoc.

`NonblockingSheet` sets [`preventsApplicationTerminationWhenModal`](https://developer.apple.com/documentation/appkit/nswindow/preventsapplicationterminationwhenmodal) to false only for AgentTrail's settings, AI-help, and cursor-review sheets. These sheets have no unsaved document requiring a termination veto. Otherwise AppKit can reject Quit before calling the delegate at all. The delegate still performs save-before-quit; this does not force exit, skip persistence, or change system authorization dialogs.

On launch, sessions still marked recording/paused are treated as interrupted. Their actions are rebuilt from committed raw inputs. No fake end timestamp is assigned. Up to the uncommitted queue can be lost in a process or machine failure. The 8,000-input budget includes both pending and queued writer batches; dropped input is recorded as a gap. Lifecycle/context markers are permitted beyond the input budget so failures can still be described. A failed batch prevents that session from being marked complete. Validate throughput and gap reporting in long sessions on the target hardware.

## Extension points

- Add DOM/ARIA observations with a browser extension and an explicitly paired local transport.
- Add worksheet-change observations through an Office add-in without overriding user commands.
- Add frame-accurate video, device/display change events, and richer gesture coverage.
- Add dataset labels, retention management, and model-specific converters above the immutable raw stream.

Preserve observed-versus-inferred distinctions. Changing a coalescing rule should rebuild derived actions; it must never rewrite the source events.
