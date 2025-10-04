# Roadmap

This document outlines planned features, enhancements, known bugs, and work in progress for Sonos Volume Controller.

For completed work with dates and versions, see [CHANGELOG.md](CHANGELOG.md).

## In Progress

_When starting work on a task, add it here with your branch name and username to help coordinate with other developers._

**Example format:**
- **Task description** (branch: feature/task-name, @username)

---

## App Store Readiness

- [x] Build as .app bundle
- [x] Code signing
- [ ] Sandboxing configuration
- [ ] App Store submission

## P0 - Critical Issues

_Issues that break core functionality. Must fix immediately._

### Bugs

### UX Critical

### Architecture Critical

## P1 - High Priority

_Major friction points impacting usability, significant missing features, or important architectural issues._

### Features
- **Trigger device cache management**: Add ability to refresh trigger sources and cache them persistently. Users should be able to manually delete cached devices that are no longer relevant (similar to WiFi network history - devices remain in cache even when not currently available, but can be manually removed).

- **Merge multiple groups**: Allow merging two or more existing groups into a single larger group. Currently can only create new groups from ungrouped speakers.

### Enhancements
- **Real-time trigger device display update**: Trigger device display in menu bar popover only updates when popover is reopened. Add real-time notification/observer pattern so display updates immediately when changed in Preferences without requiring popover close/reopen. (MenuBarContentView.swift:1667, MenuBarPopover.swift:59) [Added by claudeCode]

- **No visual indication when app disabled**: Menu bar icon doesn't change when app is in "Standby" mode (settings.enabled = false). Can't tell at a glance if hotkeys will work. Consider dimming icon or adding slash overlay. (main.swift:32-67) [Added by claudeCode]

- **Loading states during async operations**: No loading indicator when grouping/ungrouping takes 3-5 seconds. Add NSProgressIndicator next to button text and disable button during operation. (MenuBarContentView.swift:1347-1467) [Added by claudeCode]

- **Network error handling improvements**: Network errors show one-time alert, but no way to retry discovery or diagnose issues after dismissal. Add "Refresh" button in Speakers section when no speakers found. (MenuBarContentView.swift:711-719) [Added by claudeCode]

- **Topology cache invalidation**: Topology cache persists for entire app session. If speakers are regrouped via Sonos app or network changes, cache becomes stale. Add automatic invalidation trigger or manual refresh affordance. (SonosController.swift:11-13) [Added by claudeCode]

- **Group expansion click target too small**: Chevron button is only 20x20pt. Make left third of card expandable or increase chevron hit target to 44x44pt. (MenuBarContentView.swift:1102-1133) [Added by claudeCode]

- **No confirmation for destructive actions**: "Ungroup Selected" immediately dissolves groups without confirmation. Add dialog: "Ungroup X speakers? This cannot be undone." or add undo capability. (MenuBarContentView.swift:1262-1345) [Added by claudeCode]

### Architecture
- **God object: SonosController (1,412 lines)**: Violates Single Responsibility Principle. Mixes SSDP discovery, UPnP/SOAP communication, XML parsing, device management, group management, volume control, and network socket management. Split into separate services: DeviceDiscoveryService, GroupManagementService, VolumeControlService, SonosNetworkClient. (SonosController.swift) [Added by claudeCode]

- **Massive view controller: MenuBarContentView (1,602 lines)**: Business logic mixed with UI code. Implement MVVM pattern with MenuBarViewModel to separate concerns. Target ~300-400 lines per view controller. (MenuBarContentView.swift) [Added by claudeCode]

- **Raw network layer without abstraction**: SOAP XML constructed via string concatenation (error-prone). No request/response type safety, inconsistent error handling, no retry logic. Introduce type-safe SOAPRequest/SOAPResponse structs with proper error types. (SonosController.swift) [Added by claudeCode]

## P2 - Medium Priority

_Nice-to-have improvements that enhance UX or reduce technical debt._

### Features
- **Search/filter for speakers**: In large installations (10+ speakers), scrolling list becomes unwieldy. Add search field at top of speaker list. (MenuBarContentView.swift:276-378) [Added by claudeCode]

- **Volume presets**: Add quick volume buttons (25%, 50%, 75%) near slider for instant adjustment. Common pattern in TV remotes and audio apps. [Added by claudeCode]

- **Basic playback controls**: Add play/pause, next/previous buttons since topology is already loaded. Users wouldn't need to switch to Sonos app for basic transport. [Added by claudeCode]

### Enhancements
- **Volume normalization when grouping**: Individual speaker volumes preserved when creating groups, which can result in unbalanced audio. Consider normalizing to average or coordinator volume. (SonosController.swift:937-998) [Added by claudeCode]

- **Group expand/collapse state persistence**: Expanded groups reset to collapsed when reopening popover. Persist `expandedGroups` Set to UserDefaults. (MenuBarContentView.swift:50) [Added by claudeCode]

- **Volume step size visibility**: Volume step configured in Preferences (1-20%) not shown in popover. Show "±5%" next to slider or in HUD. (PreferencesWindow.swift:84-102) [Added by claudeCode]

- **Stereo pair limitation warning**: When selecting stereo pair as coordinator, operation may fail (Sonos limitation). Warn before attempting or disable stereo pairs as group leaders in UI. (SonosController.swift:980-982) [Added by claudeCode]

- **Graceful degradation for slow networks**: 5s discovery timeout may miss devices on congested networks. Add progressive disclosure: "Discovering... Found 2 speakers, still searching..." with "Search Longer" button. (SonosController.swift:133-143) [Added by claudeCode]

- **Group/individual volume visual differentiation**: Group cards use subtle icon differences. Add colored left border (blue, 3pt) to groups for clearer distinction. (MenuBarContentView.swift:381-466) [Added by claudeCode]

- **Success feedback for grouping**: After grouping, popover refreshes but no explicit success confirmation. Show success HUD: "Group Created: [Name]" and auto-expand new group. (MenuBarContentView.swift:1419-1467) [Added by claudeCode]

- **Wrong device HUD clarity**: "Wrong audio device" message doesn't guide users to fix it. Change to "Switch to [Trigger Device] to use hotkeys" with current device shown. (VolumeKeyMonitor.swift) [Added by claudeCode]

- **Long speaker name truncation**: Names truncated with ellipsis in cards. Add tooltip showing full name on hover or use 2-line wrapping. (MenuBarContentView.swift:548-671) [Added by claudeCode]

- **Offline/unreachable speaker detection**: Offline speakers remain in list, controls fail silently. Detect timeouts, show "Offline" badge, auto-refresh topology every 60s. (SonosController.swift) [Added by claudeCode]

### Architecture
- **Permission monitoring observer cleanup**: AppSettings tracks permission observers in array but never removes them, potential memory leak if components are deallocated. Add `removePermissionObserver()` method or use weak references. Also consider converting to Combine Publishers for better lifecycle management. (AppSettings.swift:233-240) [Added by claudeCode - Phase 1 technical debt]

- **VolumeKeyMonitor needs pause/resume for testing**: Test Hotkeys feature (Phase 2) requires temporarily disabling main event tap to avoid conflicts. Add `pause()` and `resume()` methods to VolumeKeyMonitor that disable/enable the event tap without full teardown. Store tap state to handle re-entrancy. (VolumeKeyMonitor.swift) [Added by claudeCode - Phase 2 requirement]

- **Excessive debug logging from group volume work**: PR #39 added comprehensive 📊/🎚️ logging for debugging group volume synchronization. Now that it's working, clean up duplicate/verbose logs and wrap remaining debug statements in `#if DEBUG`. Focus on: MenuBarContentView.swift:1063-1215 (volumeChanged, refreshMemberVolumes, performMemberVolumeRefresh), SonosController.swift:1496-1598 (snapshotGroupVolume, setGroupVolume). [Added by claudeCode]

- **Excessive debug logging from popover height work**: PR #41 added comprehensive 🔍 logging for debugging animation timing and layout measurement during expand/collapse. Clean up logs and wrap in `#if DEBUG`. Focus on: MenuBarContentView.swift:1347-1451 (animateInsertMemberCards, animateRemoveMemberCards, card height logging), calculateContentHeight, updatePopoverSize. [Added by claudeCode]

- **Remaining Sendable warnings in SonosController**: Multiple warnings for mutation of captured vars and non-Sendable completion handlers. Convert remaining completion handler callbacks to use `@Sendable` closures or pure async/await patterns. (SonosController.swift:461, 465, 476, 790, 926, 1075, 1213, 1266) [Added by claudeCode]

- **Inconsistent concurrency patterns**: Mix of callbacks, Tasks, DispatchQueue, DispatchSemaphore, Thread.sleep. Establish clear async/await strategy throughout codebase. [Added by claudeCode]

- **Poor error propagation**: Silent failures (print statements only). Introduce structured SonosError enum with LocalizedError conformance for proper user-facing error messages. [Added by claudeCode]

- **Tight coupling to frameworks**: Direct URLSession, Core Audio APIs in business logic. No dependency injection makes testing difficult. Add protocol abstractions (NetworkSession, AudioDeviceProvider). [Added by claudeCode]

## P3 - Low Priority

_Polish, minor improvements, and long-term architectural refactoring._

### Features
- **About window**: Add window showing version, changelog, support links. No current way to check version without quitting. [Added by claudeCode]

- **Settings import/export**: Users who reinstall or use multiple Macs can't transfer configuration. Add export/import for trigger device, hotkeys, default speaker. [Added by claudeCode]

- **Multi-room scene support**: Sonos supports scenes (predefined group+volume+source). Expose via quick-action buttons. [Added by claudeCode]

- **Sonos alarm management**: View or disable alarms from menu bar (common use case: turn off alarm after waking). [Added by claudeCode]

### Enhancements
- **Preferences keyboard shortcut**: Add standard Cmd+, to open Preferences. Add tooltip to gear icon showing shortcut. (main.swift) [Added by claudeCode]

- **Volume slider fine control**: Add modifier key support (Shift = 1% increments, Option = 5%) and show percentage tooltip while dragging. (MenuBarContentView.swift:1016-1022) [Added by claudeCode]

- **Hover states**: Add subtle background color change on hover for speaker cards and scale-up (1.02x) for buttons. (MenuBarContentView.swift) [Added by claudeCode]

- **Welcome banner dismissal**: Add close button (X) to banner and persist dismissal preference. (MenuBarContentView.swift:967-1006) [Added by claudeCode]

- **Empty state styling**: "No speakers found" is plain text. Add SF Symbol icon (`antenna.radiowaves.left.and.right.slash`) and helpful suggestion. (MenuBarContentView.swift:711-719) [Added by claudeCode]

- **Grouping button tooltips**: Disabled buttons show no hint about requirements. Add tooltip: "Select 2+ speakers to group". (MenuBarContentView.swift:317-336) [Added by claudeCode]

- **Volume HUD group context**: HUD doesn't indicate if controlling a group. Add group icon and member count: "Living Room + 2 speakers". (VolumeHUD.swift:103-187) [Added by claudeCode]

- **Haptic feedback**: Add NSHapticFeedbackManager for tactile responses on button clicks, volume min/max, group creation. [Added by claudeCode]

- **Console logging in production**: Extensive print() statements. Wrap in #if DEBUG or use os_log for production builds. [Added by claudeCode]

### Architecture
- **Deprecated String(cString:) usage**: Replace deprecated String(cString:) with String(decoding:as:UTF8.self) after null termination truncation. (SonosController.swift:1467) [Added by claudeCode]

- **Extract configuration constants**: Magic numbers and strings scattered throughout. Create SonosConstants enum for ports, timeouts, multicast addresses. [Added by claudeCode]

- **Missing protocol abstractions**: No protocol definitions for key components. Would benefit from dependency inversion for testing. [Added by claudeCode]

## Known Bugs

_Remaining bugs tracked separately from prioritized items above._

_(Moved to P0/P1 sections)_

## Known Limitations

- **Line-in audio lost when grouping with stereo pairs**: When a stereo pair is playing line-in audio and grouped with another speaker, the line-in audio stops because the non-stereo-pair becomes coordinator and line-in sources are device-specific (cannot be shared). Workaround: Manually set the stereo pair with line-in as the coordinator in the Sonos app, or use streaming sources instead of line-in when grouping.
