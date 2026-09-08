# AgentTrail

Standalone macOS demonstration recorder for computer-use agent datasets.

This file is a router, not a store — facts go in subdocs, one-line pointers here.

- `README.md` → setup, product behavior, limitations → read for user-facing changes.
- `docs/installation.md` → source builds, permissions, updates/removal → read for installation changes.
- `PRIVACY.md`, `SECURITY.md`, `THIRD_PARTY.md` → data boundaries, reporting, licensing → read before changing collection, sharing, or dependencies.
- `CONTRIBUTING.md`, `scripts/check-publication.py` → synthetic-only contribution and publication checks → read before staging or publishing.
- `docs/architecture.md` → capture, queues, persistence, recovery → read before changing recorder lifecycle or storage.
- `docs/schema.md` → raw events, observations, actions, exports → read before data-format changes.
- `docs/ai-integration.md` → CLI/MCP contracts → read before query-tool changes.
- `docs/validation.md` → automated and live acceptance checks → read when validating capture.
- `Sources/TrailCore/` → platform-independent data layer using system SQLite → test with `swift test`.
- `Sources/AgentTrail/` → native UI and macOS capture adapters → package with `bash scripts/build-app.sh`.

Preserve raw evidence, distinguish sampled context from verified outcomes, and never begin recording automatically. Keep data local unless a user explicitly exports or connects a client. Do not commit actual recordings.
