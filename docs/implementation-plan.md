# BingDesk Implementation Plan

> **For agentic workers:** Use the subagent-driven-development workflow for the core implementation and independent final review. The controller owns app integration, packaging and installation.

**Goal:** Deliver an installed menu bar wallpaper app and a reproducible GitHub cloud-built DMG.

**Architecture:** SwiftPM builds WallpaperCore and the BingDesk executable. WallpaperCore uses actors for network and disk ownership; the app uses MainActor for state and NSWorkspace. A native macOS CI runner tests, builds, signs ad hoc and packages the app.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Foundation URLSession, ImageIO, ServiceManagement, XCTest, GitHub Actions.

**Spec:** docs/spec.md

## Global Constraints

- Do not install local Xcode or compile locally; run Swift tests and builds on GitHub only.
- Actual image size must satisfy width >= 3840 and height >= 2160; never upscale or use thumbnails as wallpaper.
- Keep existing wallpaper on failure. All NSWorkspace desktop updates happen on MainActor.
- Cache limit: 10 images and 200 MiB, with active desktop files protected.
- No credentials, signing certificates or Apple account required. Never store tokens in the repository.
- Keep code readable with Chinese documentation comments; avoid forced unwraps and unsafe Sendable workarounds.

## Task 1: Source, policy and cache core

Files: Package.swift, Sources/WallpaperCore/*.swift, Tests/WallpaperCoreTests/*.swift.

- [ ] Define the core public interfaces in docs/core-contract.md and write behavioral tests for resolution rejection, daily scheduling, date and URL validation, archive parsing, and eviction protection.
- [ ] Push a core stub and tests, run the cloud test workflow, and confirm the missing behavior fails assertions.
- [ ] Implement the core, run cloud tests, fix covering failures and review the diff.

## Task 2: App, CI and native packaging

Files: Sources/BingDesk/*.swift, Resources/Info.plist, scripts/package.sh, scripts/MakeIcon.swift, .github/workflows/build.yml, README.md.

- [ ] Implement the Chinese menu bar popup, owned tasks/timer/observers, persisted state, daily/random actions and login toggle against the core contract.
- [ ] Add CLI diagnostics/smoke mode for actual installed-binary verification, without exposing developer controls in the product menu.
- [ ] Add cloud tests, release build, arm64 ad-hoc signature verification, DMG creation and artifact publication.
- [ ] Independently review the completed branch for spec compliance and lifecycle/concurrency correctness, then resolve concrete findings.

## Task 3: Cloud release and installed verification

- [ ] Observe successful cloud checks and DMG artifact, download and verify checksums, DMG integrity, signature and architecture.
- [ ] Back up current desktop URLs; install to /Applications/BingDesk.app without overwriting an unrelated app.
- [ ] Run installed app smoke checks for daily and random 4K changes, same-day de-duplication and current-screen readback.
- [ ] Open the real menu UI and verify its visible state, try login registration and report any required physical/system approval accurately.
- [ ] Publish a GitHub release with the verified DMG; return its link and the verified limitations.
