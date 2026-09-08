# Validation

## Automated

`swift test` exercises drag boundaries and retained coordinates, shortcut inference, typing/pause/app boundaries, context separation, pagination, transaction rollback, literal search, read-only access, recovery, exports, path rejection, asynchronous evidence links, MCP requests, capture filters, writer exclusion, and raw Unicode/timestamp round trips.

`bash scripts/build-app.sh` builds a release executable, packages `dist/AgentTrail.app`, signs it locally, and verifies the signature.

`python3 scripts/smoke-test.py` uses the packaged binary in a disposable library to validate demo creation, CLI search, complete exports, synthetic training labels, MCP stdio requests/batches, read-only access, and database permissions.

`python3 -m unittest discover -s scripts -p 'test_*.py'` tests the publication gate, including index-versus-working-copy content, credentials, private paths, forbidden artifacts, symlinks/submodules, and binary/large files. After staging, `python3 scripts/check-publication.py` inspects the exact source being published. CI repeats that check, uses a pinned checkout action without persisted credentials, and never uploads generated recordings or app bundles. The packaging smoke test verifies bundled license/privacy notices.

These tests do not grant macOS privacy permissions or prove delivery of every physical device report. Live capture must be tested on the target macOS/app versions after granting permissions.

Capture regression tests run a real background CFRunLoop with a synthetic in-process source while the test's main thread is blocked for over half a second. They verify ordered key/pointer buffering, immediate pause suppression before UI delivery, counted overflow, capture-time foreground snapshots, shutdown/restart/installation failure, and intentional-versus-failure gap labels without rewriting old raw evidence. They do not inject OS events or require Input Monitoring.

### 0.2.1 capture-stall fix — 2026-09-08

A reported 0.2.0 session contained context/focus/gap records but no raw keyboard or pointer inputs. Its tap ran on the main thread and synchronously called application lookup and recorder callbacks, including clipboard access. The 0.2.1 fix isolates the tap from that work and distinguishes intentional exclusions from failures. All 33 tests and the packaged CLI/export/MCP smoke test passed. The installed app correctly displays legacy exclusion labels without rewriting raw records. The existing paused session was finished and preserved before the update. The updated ad-hoc build did not retain recognized Input Monitoring/Accessibility grants, so physical-input/live-resize verification is still pending user reauthorization; synthetic tests are not a substitute for that check.

Cursor-specific tests cover negative coordinates and aspect ratio, gaps/pauses/app switches, invalid points, stationary/vertical paths, event-range paging and session isolation, clock changes/equal-time samples, click/drag classification, and complete/resumable raw JSONL output. The synthetic example includes a straight drag, a curved move, and a right-button press for visual review. Check session-wide and action-scoped trails, playback, the time slider, per-sample stepping, speed selection, empty ranges, and page navigation. Verify that viewing a trail does not generate OS input or mutate recorded events.

## First live session

Use a disposable document and restrict the app allowlist if helpful. Record the following sequence, then inspect the saved timeline and raw events:

1. Enter several values, including a shifted character and a non-ASCII character with text enabled. Inspect physical key codes, modifiers, and optional Unicode separately.
2. Select `B2:B10`, press Command-D, then undo. Confirm the shortcut appears and any fill-down label remains an inference. With Excel context enabled, check the range's separate observation timestamp.
3. Drag across cells, scroll horizontally and vertically, right-click, and double-click. Check button IDs, click counts, coordinates, and grouped drag boundaries.
4. Switch to a browser, click a labeled button, then return. Check app-focus records and available accessibility labels. A canvas with no element labels is an expected limitation.
5. Add a bookmark, pause, type a disposable distinctive phrase, resume, and finish. Confirm the paused phrase has no recorded inputs.
6. If screenshots are enabled, check the captured window, timing fields, and attachment paths in the export.
7. Start another disposable session and force-quit. On relaunch, verify its interrupted status and that committed raw events have a rebuilt timeline.
8. Export and query through a read-only MCP client. Check pagination, raw event links, and separation of observed facts from inferences.
9. Resize AgentTrail and another application's window, open/close a menu, then type a disposable phrase and drag in the other app. Confirm raw key/pointer inputs continue after switching apps and during ordinary resizing. AgentTrail's own controls are intentionally excluded, but there should be no listener timeout. Do not mistake AX-only context rows for successful input capture.

Record results with macOS version, app version, input device/layout, capture options, and any gaps. Do not publish real recordings containing personal information as test fixtures.
