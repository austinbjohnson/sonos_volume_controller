# Changelog

All notable changes to Sonos Volume Controller will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Custom Sonos speaker icon for menu bar (replaces "S" text)
- Exit/quit icon updated to "person leaving" (SF Symbol: figure.walk.departure)
- Settings dropdown now updates when refreshing Sonos devices (PR #13)
- Improved device discovery reliability with multiple SSDP packets and longer timeouts (PR #14)
- Added loading indicator UI when discovering speakers (PR #14)
- Development workflow documentation (DEVELOPMENT.md)
- Volume slider syncs with default speaker on app launch (PR #15)
- Volume slider disabled with "—" until actual volume loads (PR #15)
- Wrong device HUD notification when volume hotkeys pressed on wrong audio device (PR #16)
- Menu bar popover auto-close using global event monitor (PR #17)
- Smooth volume HUD transitions without flicker on rapid hotkey presses (PR #18)
- Accessibility permissions prompt on first launch with direct link to System Settings (PR #19)
- First launch onboarding with welcome banner - automatically shows popover when no speaker is selected, plus shows HUD notification when user tries to use hotkeys without a speaker selected (PR #24)
- Trigger device picker in menu bar - select which audio device activates Sonos hotkeys, defaults to "Any Device" for universal compatibility (PR #25)
- Hierarchical group UI with expandable member controls - groups display as primary cards with drill-down capability to control individual speakers within groups (PR #27)
- Real-time topology updates via UPnP event subscriptions - automatically detects and reflects speaker grouping changes made from Sonos app or other controllers without manual refresh (PR #36)
- Audio trigger source dropdown in Preferences window for selecting which audio device activates Sonos control (PR #37)
- Accessibility permission feedback system: Warning banner in menu bar popover when permission not granted, HUD notification when hotkeys pressed without permission (with "Open Settings" button), real-time permission status monitoring with automatic UI updates (PR #45)
- Hotkey diagnostics in Preferences: Permission status indicator (green checkmark when enabled, orange warning when disabled), "Test Hotkeys" button verifies F11/F12 detection with success/failure overlays, real-time permission status updates, troubleshooting guidance for failed tests (PR #46)

### Changed
- Simplified active speaker concept - replaced manual "default speaker" configuration with automatic "last active speaker" tracking, app now remembers what you were last controlling, replaced yellow star button with blue dot indicator, hover-only checkboxes for cleaner UI (PR #40)
- Fixed checkbox vs. card click confusion by adding explicit star buttons to set default speaker/group - eliminates accidental clicks between selecting for grouping vs setting as default (PR #34)
- Simplified UI by streamlining trigger display and preferences window - replaced radio button list with read-only display, removed redundant Audio Devices and Sonos tabs from preferences (PR #32)
- Changed default hotkeys to Cmd+Shift+9/0 for better ergonomics (PR #20)
- Fixed hotkeys not working in installed app - reverted to F11/F12 defaults, fixed CGEventFlags conversion, added network entitlements, improved permission flow with auto-restart (PR #22)

### Technical
- Infrastructure layer extraction - refactored SonosController god object by extracting infrastructure components (SSDPSocket, SSDPDiscoveryService, SonosNetworkClient, XMLParsingHelpers) into separate, focused modules with clean interfaces and improved testability, reduced SonosController from 1,732 to 1,471 lines (-15%)
- Complete SOAP migration - migrated all 6 remaining SOAP operations (group volume, grouping/ungrouping, playback control) to use SonosNetworkClient, eliminated 229 lines of boilerplate URLSession code, added type-safe AVTransport convenience methods, fixed pre-existing thread safety issues

### Fixed
- Group volume slider flicker during adjustment - fixed visual glitching and instability when adjusting group volume by improving slider update synchronization and debouncing (PR #44)
- Popover height calculation - fixed tiny scroll area on initial display by forcing Auto Layout before measurement, increased max scroll height to accommodate expanded groups with 6+ cards, smooth expand/collapse animations without flicker (PR #41)
- Real-time group volume slider synchronization - member sliders within expanded groups now update immediately when adjusting group volume, with smooth animations and visual feedback via pulsing connection lines (PR #39)
- Enhanced group volume controls with bidirectional synchronization - individual speaker sliders now correctly display and control their own volumes (not group volume), group slider updates when individual speakers change, smooth animations throughout (PR #38)
- Thread safety violations with @unchecked Sendable - converted SonosController to actor with proper async/await patterns, eliminated data race risks (PR #35)
- Fixed ungroup functionality for group checkboxes - properly handles both group IDs and device names when ungrouping (PR #29)
- Fixed audio dropout when grouping speakers - intelligently selects playing speaker as coordinator to preserve audio, prompts user when multiple speakers are playing (PR #30)
- Improved group expand/collapse UX - smooth animations with group card anchored in place while member cards slide in/out (PR #30)
