# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

AppDockAuditEngine — an AI-native macOS application audit tool built with SwiftUI. It scans installed `.app` bundles, analyzes their source, signatures, permissions, runtime metrics, and provides AI-powered semantic queries via OpenAI-compatible APIs.

## Build & Run Commands

```bash
# Default build (DIRECT flavor — full capabilities)
swift build
swift run

# MAS flavor build (restricted capabilities)
swift build -Xswiftc -DAPP_FLAVOR_MAS

# Verify both flavors compile
swift build && swift build -Xswiftc -DAPP_FLAVOR_MAS
```

**Environment**: macOS 13+, Swift 5.9+ toolchain, Xcode 15+ (optional for UI debugging).

## Architecture

### Entry Point
- `Sources/AppDockAuditEngineApp.swift` — SwiftUI `@main` app, bootstraps `DashboardViewModel`.

### Core Data Model
- `Sources/Models.swift` — All domain types: `AppRecord`, `AppSource`, `SignatureTrustLevel`, `PermissionKind`, `RiskSignal`, `AuditRiskLevel`, `AIProviderError`, etc.

### MVVM Layer
- `Sources/DashboardViewModel.swift` — `@MainActor` ObservableObject. Orchestrates the full pipeline: `AuditPipeline` → risk analysis → update suggestions → AI digest.

### UI Layer
- `Sources/DashboardView.swift` — Main SwiftUI view with three glass panels: app list, audit findings, and update suggestions. Includes `LiquidBackgroundView`, `LiquidBubbleCard`, `AIAssistantBubble`, and `SettingsSheet`.

### Service Layer (audit pipeline)
- `Sources/AuditServices.swift` — Core scanning and audit services:
  - `AppScanner` — discovers apps via `mdfind`
  - `SourceAuditService` — detects App Store vs third-party via `_MASReceipt`
  - `SignatureAuditService` — extracts signing info via `codesign -dv`
  - `PermissionAuditService` — reads `Info.plist` usage descriptions
  - `TCCPermissionReader` — reads TCC.db SQLite states for permission grants
  - `PermissionHeuristicsEngine` — rule-based risk signal detection (unsigned, mismatched permissions, high CPU BG, etc.)
  - `RuntimeMetricsCollector` — collects CPU/memory via `ps`
  - `AuditPipeline` — orchestrates all above into `[AppRecord]`

### AI Integration
- `Sources/AIQueryServices.swift` — AI provider integration:
  - `OpenAICompatibleAdapter` — calls `POST /chat/completions` with Bearer auth
  - `SemanticQueryPlanner` — keyword-based filtering (国产, 后台, CPU)
  - `AIProviderRouter` — routes queries through `SanitizedJsonBuilder` → adapter

### Ops Services
- `Sources/OpsServices.swift` — `UninstallService` (preview residual files) and `UpdateAdvisorService` (Homebrew cask matching).

### Supporting Utilities
- `Sources/ShellExecutor.swift` — Async `Process` wrapper for shell commands.
- `Sources/SanitizedJsonBuilder.swift` — Builds sanitized DTO payloads for AI (truncates to maxBytes).
- `Sources/AppCategoryClassifier.swift` — Heuristic app categorization (development, design, productivity, etc.).
- `Sources/CapabilityPolicy.swift` — Feature gating via `APP_FLAVOR_DIRECT` / `APP_FLAVOR_MAS` compiler flags.

### Build Flavor System

| Feature | DIRECT | MAS |
|---|---|---|
| TCC Read | enabled | disabled |
| Signature Deep Audit | enabled | enabled |
| Uninstall Delete | enabled | disabled |
| Update Probe | enabled | enabled |

The flavor is controlled via Swift compiler flags in `Package.swift` (`APP_FLAVOR_DIRECT` default) or overridden with `-Xswiftc -DAPP_FLAVOR_MAS`.

## Key Design Notes

- **No test suite exists** — the project currently has no `Tests/` directory.
- All shell execution goes through `ShellExecutor` (async `Process` wrapper).
- The `AuditPipeline` is the main data flow: scan → source → signature → TCC → permissions → metrics → `AppRecord`.
- AI payloads are sanitized to ≤1024 bytes via `SanitizedJsonBuilder` (truncates from the end).
- The project is a flat Swift Package (all sources in `Sources/`, no subdirectories).
