# Security policy

## Report privately

Use [GitHub private vulnerability reporting](https://github.com/mctatge/AgentTrail/security/advisories/new) for a suspected security/privacy vulnerability or sensitive abuse report. Start with the affected source version, a description, and a reproduction using fabricated data. Do not send credentials, private screenshots, database files, or real event logs.

If private reporting is unavailable, open a public issue containing only a request for a private reporting channel and a non-sensitive description. Do not post exploit details or personal information there. There is no promised response time or service-level agreement.

## Supported scope

This is an experimental source release. Security fixes target the latest default-branch source; no older release is promised long-term support. There is no notarized binary distribution or independent penetration-test certification.

Relevant boundaries include: opt-in/visible capture, pause/secure-field/app exclusions, capture queue behavior, local file access, export attachment paths, read-only MCP, untrusted recorded text, and accidental publication of recordings. Capture gaps are a data-integrity concern and must not be hidden or interpreted as verified events.

The application is not a sandbox against other software running as the same user. Local file permissions are not encryption. Password detection and screenshot isolation are best-effort. MCP can read all sessions in its chosen library; see [PRIVACY.md](PRIVACY.md).

## Project policy

Do not propose stealth capture, hidden persistence, permission bypasses, credential extraction, or unsolicited upload. This is a maintainer support/contribution policy, not a modification of the MIT license. Public issues and test fixtures must use synthetic data only.
