# Privacy and responsible use

AgentTrail is an experimental, local demonstration recorder. This document describes the shipped source, not a compliance certification or a promise that every sensitive field will be detected.

## What can be recorded

Recording starts only after you press Start. While active, it can collect raw key codes/modifiers, pointer paths/buttons, scroll, timestamps, app identities, window titles and observed focused-window geometry, accessibility labels, clipboard-change/type metadata, and your bookmarks. Raw key codes can reveal what you typed even when literal text collection is disabled. App and window metadata can identify documents, websites, people, and activities.

Typed text/accessibility values, clipboard text, window screenshots, and the Excel adapter are separate opt-in settings, all off by default. Screenshots can contain unrelated information inside the chosen app window; the capture may select another available window from that app. Optional Excel context includes workbook/sheet names and selection addresses. A generic accessibility name-box probe may also observe a selection without the Excel Automation adapter.

Capture options apply to new sessions, not retroactively to saved data. Existing exclusions do not redact old recordings.

## Saving is explicit

New GUI recordings, their raw events, derived actions, and screenshot bytes stay in memory until you click **Save recording**. **Stop recording** ends capture and leaves an **Unsaved** draft for review. **Discard** releases that draft; you must save or discard it before starting another. The GUI’s synthetic example follows the same draft workflow. The explicit CLI `demo` command writes its requested synthetic fixture to the selected library.

Quit with unsaved data offers **Save and Quit**, **Discard and Quit**, and **Cancel**. Neither stopping nor quitting automatically saves a recording. A crash, force-quit, or power loss loses the entire unsaved draft; new drafts have no on-disk recovery copy. Existing saved recordings are unaffected, and legacy on-disk sessions interrupted before this behavior was introduced still use recovery.

This is an application storage boundary: AgentTrail does not deliberately write unsaved recording data or screenshots to its library or temporary capture files. It is not a guarantee that bytes can never reach storage through macOS swap, crash dumps, or other system behavior, and Discard is not secure memory erasure.

## Local storage and network boundaries

- The default saved library is `~/Library/Application Support/AgentTrail/`, containing `library.sqlite`, possible `-wal`/`-shm` sidecars, a recorder lock, and optional `sessions/.../frames/` images. `--root` can choose another location.
- Capture preferences, including app filters, are stored immediately in macOS UserDefaults, separately from recording contents; window placement may be stored by AppKit. An empty library and recorder lock can exist before you save a recording.
- AgentTrail contains no telemetry, analytics, update checker, network listener, automatic upload, or built-in hosted AI model. It uses local OS APIs; macOS, GitHub, your target apps, backup/sync software, and any AI client have their own behavior and policies.
- Directories and normal app-created raw files use owner-only permissions. This is **not encryption** and does not protect against other software running as your user, privileged software, or access to backups/unlocked storage. Use a private local directory and appropriate device security.
- Export creates additional copies. Choosing a cloud-synced folder can cause your sync provider to receive those copies, even though AgentTrail itself does not upload them.
- Saved recordings have no automatic retention limit, redaction, per-session delete UI, or guaranteed secure deletion. Discard applies to the unsaved draft only. The maintainer cannot remotely retrieve or delete your local recordings.

## AI access is a separate disclosure decision

The stdio MCP server opens its configured library read-only and offers three bounded query tools. A connected client can query **all saved sessions in that library**, not just the selected session. Session filters are not access controls. There is no per-session consent dialog, client authentication layer, or field-level redaction inside MCP. The process runs with your account's filesystem access. Unsaved drafts are unavailable to AgentTrail’s MCP and CLI query commands. Save is therefore also the point at which an already-connected client can discover the recording.

Returned records become context in the connected client. They may be sent to the client's model provider or retained by that client according to its settings and policies. Screenshot events contain attachment references, not image bytes; a client with filesystem tools may separately open those images. Review the library before connecting, or use a dedicated `--root` library containing only intended demonstrations. Disconnecting a client does not retract data already returned to it.

Recorded app/document text is untrusted evidence, not instructions for an agent. Exported timelines and the MCP server include that warning, but this is not a guarantee against prompt injection. Independently authorize any actions an agent proposes after reading a recording.

## Before recording or sharing

1. Record your own actions on a device and in accounts you are authorized to use. Get appropriate, informed permission from other people whose activity or private content could be captured. Device access alone is not consent to record or publish someone else's information.
2. Use disposable documents, test accounts, and fabricated example data. Close unrelated windows and notifications. Prefer an app allowlist. Pause before credentials, payment details, private communications, or leaving the demonstration.
3. Do not rely on password detection. It depends on the target app, OS secure-input behavior, and asynchronously sampled accessibility context. Common password-manager exclusions are not exhaustive. Ordinary text fields and screenshots can still contain secrets.
4. Separately review the right to collect, retain, disclose, publish, and use captured material for model training. An app's software license does not give you rights to its screen content, third-party documents, personal information, or other protected material. Check relevant contracts, organizational policies, and applicable law. Consent to capture is not automatically consent to public release or training.
5. Inspect every exported file, attachment, title, path, and metadata field before sharing. Removing literal text alone does not anonymize key codes, screenshots, or behavior. Do not publish real recordings in this repository, an issue, or a pull request. Reproduce issues with fabricated data instead.

This project is intended for visible, voluntary demonstrations, not covert surveillance, credential harvesting, or bypassing OS protections. The maintainer's contribution/support policy rejects those features. This guidance does not add use restrictions to or replace the MIT software license.

## Removal and incidents

Stop recording, save or discard the draft, quit AgentTrail, and stop connected MCP/CLI processes before removing a library. Use Finder to remove the entire chosen library directory, not just the SQLite database while leaving screenshots or sidecars. Remove exports, backups, and cloud copies separately, following those systems' retention controls. Deleting files or emptying Trash is not a guarantee of secure erasure on SSDs or backup systems. Remove unused macOS permissions and AI-client configurations too; [installation instructions](docs/installation.md) explain where.

If you accidentally publish credentials, revoke/rotate them through the issuing service; merely deleting a GitHub file does not remove it from history, caches, or forks. Use [SECURITY.md](SECURITY.md) for private vulnerability/abuse reporting. Do not include raw recordings in an initial report.

## Limits and reference points

No claim is made that AgentTrail is GDPR-, CCPA-, HIPAA-, FERPA-, workplace-monitoring-, or wiretap-law compliant. Which obligations apply depends on the people, jurisdiction, activity, and disclosure. Seek qualified advice before organizational monitoring, research involving participants, sensitive-data use, or public dataset release.

[Apple's input-monitoring guidance](https://support.apple.com/guide/mac-help/mchl4cedafb6/mac) explains the OS permission. [GitHub's dual-use policy](https://docs.github.com/en/site-policy/acceptable-use-policies/github-active-malware-or-exploits) explains its hosting boundaries. [The FTC's SpyFone action](https://www.ftc.gov/news-events/news/press-releases/2021/09/ftc-bans-spyfone-ceo-surveillance-business-orders-company-delete-all-secretly-stolen-data) illustrates risks from secret surveillance and inadequate data protection; it is not a universal legal test for this project.
