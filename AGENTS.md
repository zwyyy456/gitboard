# GitStride Repository Guidelines

## Project Facts

- GitStride is a native SwiftUI menu bar app for macOS 14+, built from `GitStride.xcodeproj` with the `GitStride` scheme.
- The app uses GitHub CLI (`gh`) for authentication and GitHub GraphQL/API access, and uses Sparkle for updates.
- The repository contains the `GitStride` application target and a focused `GitStrideTests` unit test target.
- `docs-index.md` is the command and document index; it does not define engineering rules.

## Document Routing

| Change | Read |
| --- | --- |
| App composition, scene lifetime, state ownership, concurrency, persistence, GitHub integration, or directory boundaries | `architecture.md` |
| Code location or an unfamiliar execution path | `docs/overview.md` |
| Build and behavior validation | `docs/testing/validation-reference.md` and the command entry in `docs-index.md` |

## Project Constraints

- Long-lived engineering rules belong in `architecture.md`. Keep product descriptions and usage instructions in `README.md`; do not turn them into engineering requirements.
- Keep plans, progress notes, one-off investigation results, and completed validation evidence out of normative documents. Git owns source history.
- Do not introduce a new contract, abstraction, compatibility path, fallback, or configuration switch without a current consumer or demonstrated compatibility requirement.
- GitHub credentials and complete private GitHub payloads must not be written to logs, fixtures, generated artifacts, or documentation.

## Validation

- Use the narrowest validation that covers the changed engineering boundary.
- The default compile check is the macOS app build documented in `docs-index.md`.
- Use `GitStrideTests` only for important deterministic behavior, external-data decoding boundaries, and confirmed regressions likely to recur.
- Do not run UI tests unless the user explicitly requests them.
