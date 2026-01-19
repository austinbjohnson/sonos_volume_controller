# Repository Guidelines

## Project Structure & Module Organization
Core code lives in `SonosVolumeController/Sources`, with infrastructure services under `Infrastructure/`, input monitors in `VolumeKeyMonitor.swift` and `AudioDeviceMonitor.swift`, and UI surfaces in `MenuBarContentView.swift`, `MenuBarPopover.swift`, and `PreferencesWindow.swift`. Packaging assets and entitlements sit in `Resources/`. Docs such as `docs/sonos-api/` hold Sonos protocol notes; keep new research there for future contributors.

## Build, Test, and Development Commands
`swift run` from `SonosVolumeController/` provides the fastest feedback loop; run `pkill SonosVolumeController` first to avoid duplicate menu bar icons. `swift build -c release` validates optimized builds. Use `./build-app.sh` to bundle locally and `./build-app.sh --install` to copy into `/Applications` and relaunch the production build.

## Coding Style & Naming Conventions
Code targets Swift 6 with four-space indentation, `CamelCase` types, `lowerCamelCase` members, and trailing commas retained for multi-line literals. Maintain actor isolation (`@MainActor`, `SonosController` actor) and group extensions by role. Logging should stay terse; reuse the existing emoji-prefixed style only when expanding a subsystem that already uses it.

## Testing Guidelines
Automated tests are not yet wired, so document manual coverage in PRs: `swift run`, select a speaker, adjust volume, and confirm HUD updates through network hiccups. Monitor console output for `SonosDevicesDiscovered` and `SonosNetworkError`. If you add XCTest targets, mirror file names (e.g., `SonosControllerTests.swift`) and register them in `Package.swift`.

## Commit & Pull Request Guidelines
Commits stay scoped and imperative. When produced with an AI agent, follow the template `Feature: Short description`, add an attribution line in the form `🤖 Generated with [Tool Name](URL)`, and include a `Co-Authored-By: Tool Name <email>` line. If the tool is OpenAI, omit the email address in the Co-Authored-By line. PRs must summarize behavioral changes, list manual test commands, attach screenshots for UI updates, and link related GitHub issues. Update `CHANGELOG.md` before opening the PR (no number) and again after GitHub assigns one.

## AI Collaboration Workflow
Start every effort with `/start <descriptor>` to sync GitHub issues (priority + status labels), branch correctly, and log ownership; end with `/finish` to run the completion checklist. Break multi-step work with the TodoWrite tool, marking entries in progress or complete immediately. Launch specialized agents proactively: `architecture-advisor` for structural decisions, `ux-ui-designer` for menu bar or HUD tweaks, `discovery-documenter`/`requirements-writer`/`ticket-breaker` for product planning, and `/security-review` before merging sensitive changes.

## Security & Configuration Tips
Grant Accessibility control so volume hotkeys fire, and ensure the Mac shares a subnet with Sonos hardware for multicast discovery. Store credentials via `AppSettings` or keychain helpers—never hardcode secrets. Reinstall via `./build-app.sh --install` when testing login-item behavior or entitlement changes.
