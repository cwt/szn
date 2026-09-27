---
type: index
title: "szn Documentation Bundle"
description: "OKF v0.2 knowledge bundle root for the szn project."
status: stable
sources:
  - docs/
verified: human-reviewed
tags: [index, okf, bundle]
timestamp: 2026-09-27T09:58:00Z
---

# szn Docs

## Reference

- [Architecture Overview](architecture.md)
- [IPC Protocol](ipc-protocol.md)
- [Build, Run, and Test](build-run.md)
- [Concepts Glossary](concepts.md)
- [Text Reflow](text_reflow.md)

## Meta

- [Bundle Log](log.md)

## Sub-bundles

- [Development](development/index.md)
- [Releases](releases/index.md)

## Metadata conventions

This bundle follows [OKF v0.2](https://github.com/google/okf). Every concept
document carries `type`, `title`, `description`, `timestamp`, `status`,
`sources`, `verified`, `stale_after`, and `tags`. Two deliberate exemptions:

* **Reserved filenames.** `index.md` (this file and the three sub-bundle
  indexes) is a directory map, and `log.md` is the running chronological log.
  OKF §2.2 reserves both names for non-concept use, so they carry no
  `stale_after` or `tags` — a structural map does not expire, and an append-only
  log is not a tagged concept.
* **Release notes.** `releases/v*.md` are immutable point-in-time records of
  what shipped in a tagged revision. They carry no `stale_after`, because a
  record of what was true at v0.9.0 cannot become wrong.

`timestamp` and `stale_after` are ISO-8601 **UTC** with a `Z` suffix. Bug
entries use `stale_after: 2026-12-31T00:00:00Z`; living design documents use
`2027-01-01T00:00:00Z`, since a resolved-bug record ages faster than an
architecture description. Bug `status` is a closed vocabulary of
`resolved` / `false_positive` / `open`; the resolution narrative lives in each
document's body.
