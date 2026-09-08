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

Rebuilding or moving an ad-hoc-signed app can invalidate the recognized permissions. Finish the session and quit before updating. If an old entry no longer works, remove only AgentTrail's stale entry, add the newly built app, and relaunch. Do not reset permissions for unrelated applications. A stable Developer ID identity can be selected using `AGENTTRAIL_SIGN_IDENTITY` when building; obtaining a signing identity and notarizing a distribution are separate maintainer tasks.

## First recording

Read [Privacy and responsible use](../PRIVACY.md). Start with a blank, disposable document and no sensitive windows. Name the session, press **Start recording**, switch to the target app, type a short phrase, drag, and finish. Check raw key and pointer events in the inspector and cursor viewer. An app-focus or context observation alone does not prove input capture worked.

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

Finish recording and fully quit before updating source. Review incoming changes, pull the new version, and rerun the build script. Existing libraries live outside the checkout and are not included in the repository. Back up any recordings you need before an update; backups also contain sensitive data.

To uninstall, quit the app, disconnect any MCP client configuration, remove AgentTrail's macOS permission entries, and move the built app/checkout to Trash. That does **not** delete recordings. To remove the default library, use Finder → Go → Go to Folder and enter `~/Library/Application Support/AgentTrail/`; after closing AgentTrail and its MCP/CLI clients, move that whole folder to Trash. Treat exported copies, custom libraries, backups, and synced copies separately. There is no per-session deletion UI, retention scheduler, encryption, redaction, or secure-erasure feature in this release. See [PRIVACY.md](../PRIVACY.md).
