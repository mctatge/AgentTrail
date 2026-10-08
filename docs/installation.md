# Installation and troubleshooting

## Build from source

The initial release is an experimental source release. There is no hosted service, account, subscription, app-store listing, notarized download, or prebuilt installer. No dependency manager downloads additional libraries during the Swift build.

You need macOS 14+, Swift 5.9+, Git, and Xcode 15+ or Apple Command Line Tools with a macOS 14+ SDK. Install developer tools with `xcode-select --install` if needed. Complete Apple's installer, then check `swift --version` and `xcrun --show-sdk-path`.

```sh
git clone https://github.com/mctatge/AgentTrail.git
cd AgentTrail
bash scripts/build-app.sh
open dist/AgentTrail.app
```

The script builds a release executable, packages `dist/AgentTrail.app`, includes the license/privacy notices, and applies an ad-hoc signature. It does not install background services or start recording. The build targets your current Mac's architecture, not a universal binary. Keep the checkout in a stable location. After building, `Open AgentTrail.command` launches it; that launcher builds only if the app is missing.

Do not disable Gatekeeper, System Integrity Protection, or other OS protections to run AgentTrail. Do not run downloaded app bundles from untrusted forks. A local ad-hoc signature is not Developer ID signing, notarization, or an Apple review.

## App icon

`Resources/AppIcon.png` is the 1024-pixel master; `Resources/AppIcon.icns` contains the macOS icon sizes. The build script copies the ICNS into the app bundle, and `CFBundleIconFile` selects it for Finder and the Dock. The artwork was generated with the built-in imagegen tool; its exact prompt is in [app-icon-prompt.txt](app-icon-prompt.txt). Both image files are reviewed by exact SHA-256 in the publication checker.

To keep AgentTrail in the Dock, open `dist/AgentTrail.app`, then right-click its Dock icon and choose **Options → Keep in Dock**.

## Permissions

Open AgentTrail's **Capture settings**. It links to the corresponding macOS settings:

| Permission | Purpose | Required? |
| --- | --- | --- |
| Input Monitoring | Listen to keyboard and pointer events while recording | For input capture |
| Accessibility | Read sampled app/window/element context and detect supported secure fields | For context |
| Screen Recording | Capture optional window screenshots | Only if screenshots are enabled |
| Automation → Microsoft Excel | Read workbook, worksheet, and selection | Only for the optional Excel adapter |

If AgentTrail is not listed in **System Settings → Privacy & Security → Input Monitoring** or **Accessibility**:

1. Click **+** below the applications list.
2. Press **Command–Shift–G**, enter the full path to your checkout's `dist/` folder, and press Return.
3. Select **AgentTrail.app**, click **Open**, and enable it. Authenticate using the normal macOS prompt if asked.
4. Fully quit and reopen AgentTrail. Closing only its window leaves the menu-bar app running.

Grant access to the packaged app, not to the compiler, shell, or AI client as a workaround. macOS permissions cover sensitive computer input; enable only the permissions needed for your demonstration. App options still control optional text, clipboard content, screenshots, and Excel sampling. All four optional content settings default to off. The app allowlist is empty by default, meaning all apps except the exclusions; narrow it before recording sensitive workflows.

Rebuilding or moving an ad-hoc-signed app can invalidate the recognized permissions. Stop recording, save or discard the draft, and quit before updating. If an old entry no longer works, remove only AgentTrail's stale entry, add the newly built app, and relaunch. Do not reset permissions for unrelated applications. A stable Developer ID identity can be selected using `AGENTTRAIL_SIGN_IDENTITY` when building; obtaining a signing identity and notarizing a distribution are separate maintainer tasks.

### Settings says enabled, but AgentTrail does not

Use **Capture settings → Recheck access** after returning from System Settings. If access is still unavailable, stop recording, save or discard the draft, choose **Quit AgentTrail**, and reopen the same app. Closing the red window button leaves the menu-bar recorder running; it is not a restart. The macOS grant and AgentTrail's optional screenshot/text switches are separate controls.

If Accessibility still appears unavailable after a full restart, use **Reveal this app** to locate the exact running copy. Remove only AgentTrail's old entry from the relevant Privacy & Security list, add that app copy again, and enable it through the normal macOS authorization prompt. Do not authorize a different build or disable macOS protections. Screen Recording can also require a full quit/reopen before a grant is recognized.

Capture choices save immediately and survive quitting before the next session. This preference persistence is separate from recording persistence: new recordings stay in memory until **Save recording**. Permission checks and termination waits work in AppKit modal mode, and AgentTrail's settings/review sheets allow the delegate to handle Quit. If an older build ignores Quit, first close its settings or review sheet with **Done**.

In the current app, Quit with unsaved data asks for **Save and Quit**, **Discard and Quit**, or **Cancel**. Force Quit loses the entire unsaved recording; only older recordings already written to disk can be recovered after an interrupted capture.

## First recording

Read [Privacy and responsible use](../PRIVACY.md). Start with a blank, disposable document and no sensitive windows. Name the session, press **Start recording**, switch to the target app, type a short phrase, drag, and press **Stop recording**. Check raw key and pointer events in the unsaved draft's inspector and cursor viewer. An app-focus or context observation alone does not prove input capture worked. Choose **Save recording** to keep it or **Discard** to release it. Save or discard before starting another recording.

The draft's data and screenshot bytes stay in memory until Save. Export, CLI queries, and MCP queries use saved recordings only. **Explore an example** also creates an unsaved draft. A crash loses unsaved data; this is not a guarantee against macOS swap or crash dumps and Discard is not secure erasure.

**Control–Option–Command–P** pauses/resumes. **Control–Option–Command–M** adds a bookmark. These shortcuts are observed, not consumed, so another app may also respond to them.

**Not recorded · AgentTrail controls (intentional)** means the recorder deliberately skipped its own UI. **Capture gap** means input coverage is incomplete. If you see listener failures, stop and save the session, verify permissions, and retry a short test. Missing inputs cannot be reconstructed by the recorder. See [validation](validation.md) for the full acceptance checklist and current unverified areas.

## AI and command-line use

Open the app once to initialize its library. Then follow [AI integration](ai-integration.md) for Claude Code, Codex, exports, or the raw JSONL stream. The CLI does not start capture; the GUI is used to start recording. MCP can query saved sessions without the GUI running.

For a separate demonstration library, fully quit the existing app and run from the checkout:

```sh
dist/AgentTrail.app/Contents/MacOS/AgentTrail --root "$HOME/AgentTrail-Demonstrations"
```

Use a local, non-shared, non-synchronized directory. Configure MCP with that same `--root` if you want the client to see only that library.

## Update or uninstall

Stop recording, save or discard the draft, and fully quit before updating source. Review incoming changes, pull the new version, and rerun the build script. Existing libraries live outside the checkout and are not included in the repository. Back up any recordings you need before an update; backups also contain sensitive data.

To uninstall, quit the app, disconnect any MCP client configuration, remove AgentTrail's macOS permission entries, and move the built app/checkout to Trash. That does **not** delete recordings. To remove the default library, use Finder → Go → Go to Folder and enter `~/Library/Application Support/AgentTrail/`; after closing AgentTrail and its MCP/CLI clients, move that whole folder to Trash. Treat exported copies, custom libraries, backups, and synced copies separately. There is no per-session deletion UI, retention scheduler, encryption, redaction, or secure-erasure feature in this release. See [PRIVACY.md](../PRIVACY.md).
