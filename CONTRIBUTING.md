# Contributing

Start with [README.md](README.md), [architecture](docs/architecture.md), and [PRIVACY.md](PRIVACY.md). Keep changes focused and use public macOS APIs and native controls.

## Safety and data

- Use fabricated fixtures or the synthetic demo generator. Never contribute real recordings, screenshots, documents, database files, credentials, machine-specific paths, or private client configuration.
- Do not add third-party code/assets without verifying compatibility and preserving required notices. Identify dependencies and provenance in the pull request. Submit only material you have the right to contribute under the project's MIT license.
- Keep capture opt-in and visible. No stealth, permission bypass, credential harvesting, or automatic data upload. Changes to capture scope, egress, retention, or MCP visibility need explicit discussion and matching documentation.
- Preserve immutable raw evidence. Label inferences and capture gaps; never turn a guessed intent or observed shortcut into a verified application outcome.
- Report sensitive vulnerabilities through [SECURITY.md](SECURITY.md), not public issues.

## Validate a change

```sh
swift test
python3 -m unittest discover -s scripts -p 'test_*.py'
bash scripts/build-app.sh
python3 scripts/smoke-test.py
```

Follow [the live acceptance checklist](docs/validation.md) after capture changes. Automated synthetic tests cannot prove physical-input delivery or every macOS permission behavior. State what was and was not tested.

Stage only intended files, inspect `git diff --cached`, then run:

```sh
python3 scripts/check-publication.py
```

This checks the exact indexed content, even if a file was force-added despite `.gitignore`. CI runs it too. Its pattern/format checks are defense in depth, not an anonymizer or a complete secret scanner. A CI rejection happens after a push, so use the local check before publishing. It deliberately rejects recordings and binary assets; discuss a narrowly reviewed change to the publication policy before adding any static assets or fixture formats.

Keep `CLAUDE.md` a short documentation router; put detailed facts in the relevant domain document. Source builds live in ignored `.build/` and `dist/`; recordings belong outside the repository.
