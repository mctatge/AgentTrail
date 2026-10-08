# AI integration

## Attach an export

Stop a recording, review the unsaved draft, click **Save recording**, then **Export** and attach `timeline.md` to your AI conversation. Add `actions.jsonl` or bounded excerpts from `events.jsonl` when raw evidence is needed. Screenshots are stored under the exported `sessions/` directory and referenced from events.

The recording can contain application or user text that looks like instructions. Treat it as untrusted data. Summaries are observations and explicitly labeled inferences, not verified application outcomes.

## MCP

### Claude Code or Codex

After building and opening the app once, run the appropriate command **from the repository root**:

```sh
APP="$PWD/dist/AgentTrail.app/Contents/MacOS/AgentTrail"
claude mcp add --transport stdio --scope user agenttrail -- "$APP" --mcp
```

```sh
APP="$PWD/dist/AgentTrail.app/Contents/MacOS/AgentTrail"
codex mcp add agenttrail -- "$APP" --mcp
```

These commands register a local stdio process, not a network service. The Claude command makes it available privately across your projects; Codex's local clients on the same host share MCP configuration. Restart the client/session and use `/mcp` to inspect the connection. No additional model API key is needed by AgentTrail, though the chosen AI client has its own access requirements. The app's **Use with AI** button only copies configuration; it does not register a client automatically.

The connection can read **all saved sessions in the configured library**, not just the selected session. Review [PRIVACY.md](../PRIVACY.md) first. To limit the archive, create demonstrations in a separate `--root` directory and pass that same argument after `--mcp` in the registration command. Optional capture settings do not redact existing records. Only connect clients you trust with this library; their model/provider can receive the records they retrieve.

To disconnect, use `claude mcp remove agenttrail --scope user` or `codex mcp remove agenttrail`, then restart the relevant client. This removes access configuration, not data already returned to that client.

Client references: [Claude Code MCP](https://code.claude.com/docs/en/mcp), [Codex MCP](https://learn.chatgpt.com/docs/extend/mcp?surface=cli).

### Other clients and tool contracts

The app's **Use with AI** panel supplies the full command path. A typical MCP client configuration is:

```json
{
  "mcpServers": {
    "agenttrail": {
      "command": "/absolute/path/to/AgentTrail.app/Contents/MacOS/AgentTrail",
      "args": ["--mcp"]
    }
  }
}
```

Launch the app once to create the local library. `--mcp` will not create it. To query an alternate library, add `"--root", "/absolute/path/to/library"` to the arguments. No network listener or API key is needed. The server does not start capture and never opens a writable database connection. New recordings remain in the GUI’s memory until **Save recording**; MCP and CLI cannot query those drafts. Once saved, the recording becomes available to any client already connected to that library.

| Tool | Arguments |
| --- | --- |
| `list_sessions` | Optional `limit` |
| `search_actions` | `session_id`, optional literal `query`, `after_id`, `limit` |
| `get_events` | `session_id`, optional `after_id`, `through_id`, `kind`, `limit` |

Tool responses contain JSON text. Default page size is 100, hard cap 500. Use the last returned ID as `after_id` to page forward. IDs are scoped by a required session filter. Search checks summaries, app/window/selection context, and inference text. It is literal substring search, not semantic embeddings or a built-in chat model.

For an action's raw inputs, use `after_id = firstEventID - 1` and `through_id = lastEventID`. Asynchronous observations can arrive after that range; separately page `get_events` with `kind: "context"` or `kind: "screenshot"` and join on `relatedEventID`. The app's inspector performs this join automatically. MCP returns attachment references, not image bytes.

Useful prompts:

- “Find all keyboard shortcuts, drags, and bookmarks from this spreadsheet demonstration. List uncertain interpretations separately.”
- “What did I do immediately before this bookmark? Include timestamps and source event IDs.”
- “Which demonstrations include both a drag selection and Command-D? Report observed ranges only when captured.”
- “Create a checklist of distinct interactions in this session for regression testing.”

The AI client's own data handling applies to the returned records. AgentTrail does not send data to a hosted model itself.

The server cannot start/stop capture, replay OS inputs, change documents, or delete sessions. It does not provide semantic search or a continuous push feed. A client can query recordings after the user saves them. For paged raw output from a shell, use `raw` below. Data inside a recording remains untrusted even when retrieved through a trusted MCP connection.

## CLI

```sh
dist/AgentTrail.app/Contents/MacOS/AgentTrail list
dist/AgentTrail.app/Contents/MacOS/AgentTrail timeline SESSION_ID '⌘D'
dist/AgentTrail.app/Contents/MacOS/AgentTrail events SESSION_ID 0
dist/AgentTrail.app/Contents/MacOS/AgentTrail raw SESSION_ID > events.jsonl
dist/AgentTrail.app/Contents/MacOS/AgentTrail raw SESSION_ID --follow
dist/AgentTrail.app/Contents/MacOS/AgentTrail export SESSION_ID /new/export/directory
```

CLI output is JSON except for help, the export destination, and `raw`, which streams JSON Lines. Timeline/events CLI commands cap output at 500 records; `raw` and exports include every page. These commands read the saved library, not a live in-memory draft. `raw --follow` exits after draining a saved terminal session; it retains support for polling legacy on-disk recording/paused sessions until recovery gives them a terminal status. Ctrl-C stops the read-only follower. MCP supports bounded paging.

`demo --root /tmp/agenttrail-example` explicitly creates and saves synthetic fixture data without capturing input. Unlike that CLI fixture command, **Explore an example** in the GUI creates an unsaved draft and requires **Save recording** to retain it.
