# macOS App Development Guidelines

> Project-specific conventions for **PTMonitor**, a Swift/AppKit menu bar agent
> built with Command Line Tools only. These are the real conventions extracted
> from the working code, not ideals.

---

## Guidelines Index

| Guide | Description |
| --- | --- |
| [Build and Run](./build-and-run.md) | Exact build/verify commands, the CLT manifest-module gotcha and workaround, the `--selftest` contract, bundle assembly |
| [App Conventions](./app-conventions.md) | Module boundaries, domain-model ownership, API client contracts, polling, persistence, menu bar + dropdown panel rules |

---

## Scope

This project has no backend/frontend split. `PTMonitorCore` is the reusable
library (models, clients, stores, diagnostics) and `PTMonitor` is a thin
executable (argv dispatch + AppKit/SwiftUI). All conventions live here.
