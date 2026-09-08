# Schema version 1

Exports use UTF-8 JSON Lines, one independently parseable object per line. Field names use Swift's camelCase. Missing optional values are omitted. Future readers must tolerate unknown fields and event kinds.

## Session

`id`, `title`, `startedAt`, optional `endedAt`, `status`, `options`, `eventCount`, `actionCount`, and string-valued `metadata`.

Status is recording, paused, complete, or interrupted. Exported counts are computed from committed database rows. Metadata includes schema/app/OS versions, coordinate conventions, and the initial AppKit display layout. Synthetic examples have `metadata.synthetic = "true"`.

## Raw event

| Field | Meaning |
| --- | --- |
| `id` | Ordered SQLite row ID, unique within the library |
| `sessionID` | Session UUID |
| `timestamp` | Unix seconds at input receipt/observation completion, UTC |
| `monotonicNS` | CGEvent timestamp for OS inputs; Dispatch uptime for application-generated observations |
| `kind` | Event type listed below |
| `app`, `bundleID` | Event recipient when a target PID resolves, otherwise sampled foreground identity; empty for recorder lifecycle records |
| `x`, `y` | Global macOS pointer coordinates in display points; negative coordinates are possible |
| `deltaX`, `deltaY` | Scroll point deltas |
| `button` | OS mouse button number; 0 left, 1 right, others retained |
| `keyCode`, `key` | Physical macOS key code and ANSI display label |
| `modifiers` | Ordered names: control, option, shift, command, caps_lock, function |
| `text` | Optional Unicode/clipboard/bookmark content |
| `context` | Independently timestamped sampled context |
| `relatedEventID` | Input this asynchronous context/frame was requested for |
| `attachment` | Relative screenshot path under the library/export |
| `fields` | Extra string fields such as source_pid, repeat, printable, reason, timing |

Kinds: `key_down`, `key_up`, `flags_changed`, `mouse_down`, `mouse_up`, `mouse_move`, `mouse_drag`, `scroll`, `app_focus`, `context`, `clipboard`, `screenshot`, `marker`, `gap`, `pause`, `resume`, `session_start`, `session_end`.

`monotonicNS` preserves source clocks without converting them to fabricated wall times. Order records by ID, use wall timestamps for cross-observation navigation, and compare monotonic deltas only for known compatible sources. `source_pid` is evidence about OS event provenance, not a human/AI classification.

From 0.2.1, `target_pid` retains the annotated event's recipient PID. `app_attribution` is `cg_event_target_pid` when resolved, otherwise `last_observed_foreground`; `foreground_observed_at` dates that fallback snapshot. Receipt timestamps are assigned on the dedicated capture thread, not after UI delivery. A `gap` can carry `category: intentional_exclusion`, an OS-disable `cause`, or `dropped_count`/`last_dropped_at` for delivery overflow. Old recordings lack these fields. Intentional exclusions display as “Not recorded”; the raw `gap` kind and reason are preserved for discontinuity-aware consumers.

## Context

`observedAt`, `app`, `bundleID`, `pid`, optional `window`, `role`, `label`, `value`, `bounds`, `selection`, `worksheet`, `workbook`, `source`, `secure`, and optional `error`.

Bounds are `[x, y, width, height]` in accessibility coordinates. `source` identifies accessibility, excel_applescript, or synthetic_example. Selection from the Excel adapter is a sampled address, not a worksheet mutation. When cached Excel fields enrich a raw input, `fields.excel_observed_at` stores that adapter's separate sample time.

A click hit-test runs after the click has reached the app; the UI may already have changed. `observedAt` can be earlier or later than the associated input. Neither proximity nor an element label establishes causation. Periodic observations may have no related event ID.

## Derived action

`id`, `sessionID`, `startedAt`, `endedAt`, `kind`, `summary`, `app`, `bundleID`, `firstEventID`, `lastEventID`, `eventCount`, optional `context`, and optional `inference`.

IDs in the inclusive raw range can include ignored modifier/up/context events; `eventCount` counts inputs consumed into that group, not necessarily every row in the range. Actions are rebuilt on interrupted-session recovery, so action IDs are not stable across a rebuild. Raw event IDs remain stable.

Kinds include shortcut, typing, click, release, drag, move, scroll, and recorder marker/lifecycle kinds. A one-second input gap, app change, session change, or action category change closes a group. A held drag remains grouped across long pauses until a release or another action boundary.

## Training step

`schemaVersion`, `source`, `inputOriginVerified`, `observationTiming`, `outcomeVerified`, and `action`.

`source` is desktop_demonstration or synthetic_example. Both verification booleans are false. Build a task-specific converter if your training pipeline requires images before every action, normalized coordinates, verified outcomes, or human/agent labels. Keep raw evidence available while doing so.
