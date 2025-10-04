# JIRA Ticket Breakdown: Line-In Audio Grouping Fix

## Document Information

**PM**: Austin Johnson
**Last Updated**: 2025-10-03
**Status**: Ready for Implementation
**Target Timeline**: 2 weeks (phased approach)
**Branch**: `bug/line-in-grouping-fix`

**Related Documentation:**
- **Problem Description**: ROADMAP.md (Line 31 - P0 Critical Bug)
- **Prototype Branch**: `bug/line-in-grouping-fix` (commit 662ad98)
- **Sonos API Docs**: `docs/sonos-api/groups.md`, `docs/sonos-api/upnp-local-api.md`

---

## Executive Summary

When a user groups a speaker playing line-in audio (e.g., turntable, TV) with another speaker, the audio cuts out because the wrong speaker becomes the group coordinator. Line-in sources are device-specific and cannot be shared unless the line-in speaker is the coordinator.

This fix implements intelligent coordinator selection that detects audio sources (line-in, TV, streaming) and ensures the appropriate speaker becomes the group leader. The implementation uses async/await patterns to prevent TOCTOU (Time-of-Check-Time-of-Use) race conditions where audio sources change between detection and grouping.

**Scope**: Convert only the grouping logic to async/await (Option A). Full SonosController refactoring is deferred to future architectural work (ROADMAP.md P1 Architecture section).

**User Impact**: Users can now group speakers playing line-in audio without interrupting playback. The app intelligently chooses the correct coordinator and displays visual badges showing each speaker's audio source.

---

## Implementation Approach

### Architecture Overview

**Current State** (Callback-based):
```
getPlaybackStates() [callbacks]
  → createGroup() [callbacks]
    → addDeviceToGroup() [mixed async/Task]
```

**Target State** (Async/await):
```
await detectAudioSources() [parallel SOAP requests]
  → await createGroup() [sequential operations]
    → await addDeviceToGroup() [clean async chain]
```

### Tech Stack

- **Language**: Swift 5.9+ (actor-based concurrency)
- **Concurrency**: Swift structured concurrency (async/await, Task, TaskGroup)
- **Network**: Existing `SonosNetworkClient` (already async/await capable)
- **SOAP API**: GetPositionInfo for audio source detection
- **UI Framework**: SwiftUI/AppKit hybrid

### Key Technical Decisions

1. **Async/await over callbacks**: Eliminates callback hell, improves error handling, prevents race conditions
2. **Parallel source detection**: Use `TaskGroup` to query all speakers simultaneously (5s timeout per request)
3. **TOCTOU protection**: Re-verify audio source immediately before grouping operation
4. **Backward compatibility**: AudioSource/transportState are optional properties - no migration needed
5. **UI integration**: Bundle badges with backend fix for cohesive user experience

### Prototype vs. Production

**Already Prototyped** ✅:
- SonosDevice model includes `audioSource` and `transportState` properties (lines 77-78)
- AudioSourceType enum with priority system (lines 82-117)
- `getPositionInfo()` SOAP call added to SonosNetworkClient (line 252)

**Needs Implementation** ⚠️:
- Remove callback-based `getPlaybackStates()`, `getPlayingDevices()`, `getPlaybackSources()` (lines 981-1417)
- Convert `createGroup()` to pure async/await (lines 1015-1219)
- Integrate source detection into topology loading (lines 233-409)
- Add UI badges and helper text in MenuBarContentView
- Add timeout handling and error recovery

---

## Ticket Organization

### Phase 1: Backend Refactoring (5-7 days)
**Goal**: Convert grouping logic to async/await, add audio source detection
**Tickets**: LINEIN-1 through LINEIN-4

### Phase 2: UI Integration (3-4 days)
**Goal**: Add visual indicators and user feedback
**Tickets**: LINEIN-5 through LINEIN-7

### Phase 3: Testing & Polish (2-3 days)
**Goal**: Comprehensive testing and edge case handling
**Tickets**: LINEIN-8 through LINEIN-9

---

## Ticket Details

---

### LINEIN-1: Refactor audio source detection to async/await

**Type**: Task
**Priority**: P0
**Size**: L (3-4 days)
**Epic**: Phase 1 - Backend Refactoring
**Dependencies**: None

#### Description

Replace the callback-based audio source detection methods (`getPlaybackStates`, `getPlaybackSources`) with clean async/await implementations. Use structured concurrency (TaskGroup) to fetch position info for multiple speakers in parallel with proper timeout handling.

This is the foundational refactoring that enables the rest of the fix. The existing callback pattern causes callback hell and makes race condition prevention difficult.

#### Acceptance Criteria

- [ ] Remove existing `getPlaybackStates(devices:completion:)` method (SonosController.swift:981-1001)
- [ ] Remove existing `getPlayingDevices(from:completion:)` method (SonosController.swift:1003-1011)
- [ ] Remove existing `getPlaybackSources(devices:completion:)` and SourcesActor helper (SonosController.swift:1365-1417)
- [ ] Add new `async func detectAudioSources(devices: [SonosDevice]) -> [String: AudioSourceInfo]` method
- [ ] Implement parallel fetching using `TaskGroup` to query all speakers simultaneously
- [ ] Add 5-second timeout per SOAP request (use `Task.timeout` or manual cancellation)
- [ ] Return dictionary mapping device UUID → AudioSourceInfo struct containing `(audioSource: AudioSourceType, transportState: String)`
- [ ] Handle network errors gracefully (log and return .idle for failed requests)
- [ ] Update SonosDevice model to make audioSource/transportState mutable for caching detected values
- [ ] Write unit tests for parallel execution and timeout handling

#### Technical Notes

**Implementation Approach**:
```swift
actor SonosController {
    struct AudioSourceInfo {
        let audioSource: AudioSourceType
        let transportState: String
    }

    func detectAudioSources(devices: [SonosDevice]) async -> [String: AudioSourceInfo] {
        await withTaskGroup(of: (String, AudioSourceInfo?).self) { group in
            var results: [String: AudioSourceInfo] = [:]

            for device in devices {
                group.addTask { [weak self] in
                    guard let self = self else { return (device.uuid, nil) }

                    // Add timeout wrapper
                    do {
                        async let state = self.networkClient.getTransportInfo(for: device.ipAddress)
                        async let uri = self.networkClient.getPositionInfo(for: device.ipAddress)

                        let (stateResponse, uriResponse) = try await (state, uri)

                        // Parse responses
                        let transportState = XMLParsingHelpers.extractValue(from: stateResponse, tag: "CurrentTransportState") ?? "STOPPED"
                        let trackURI = XMLParsingHelpers.extractValue(from: uriResponse, tag: "TrackURI")
                        let sourceType = self.detectAudioSourceType(from: trackURI)

                        return (device.uuid, AudioSourceInfo(audioSource: sourceType, transportState: transportState))
                    } catch {
                        print("⚠️ Failed to detect audio source for \(device.name): \(error)")
                        return (device.uuid, AudioSourceInfo(audioSource: .idle, transportState: "STOPPED"))
                    }
                }
            }

            for await (uuid, info) in group {
                if let info = info {
                    results[uuid] = info
                }
            }

            return results
        }
    }
}
```

**Files to Modify**:
- `SonosController.swift` (lines 981-1417): Remove callback methods, add async method
- `SonosController.swift` (lines 69-79): Update SonosDevice model to cache detected sources

**Testing Requirements**:
- Unit test: Verify parallel execution completes within expected time (< 6 seconds for 5 devices)
- Unit test: Verify timeout handling when speaker is unreachable (should not block indefinitely)
- Unit test: Verify correct audio source detection for all URI types (line-in, TV, streaming, idle)

#### Security Considerations

- No sensitive data involved
- Timeout prevents indefinite blocking/DoS from unresponsive devices
- Error handling prevents crashes from malformed SOAP responses

#### Out of Scope

- Refactoring other SonosController methods to async/await (deferred to P1 architecture work)
- Caching audio source info in topology (handled in LINEIN-2)

---

### LINEIN-2: Integrate audio source detection into topology loading

**Type**: Task
**Priority**: P0
**Size**: M (2-3 days)
**Epic**: Phase 1 - Backend Refactoring
**Dependencies**: LINEIN-1

#### Description

Extend the topology loading process to fetch audio sources in parallel with group topology. When `updateGroupTopology()` completes, each device should have its `audioSource` and `transportState` properties populated.

This enables the UI to display audio source badges immediately when the menu popover opens, without additional network requests.

#### Acceptance Criteria

- [ ] Modify `updateGroupTopology(completion:)` to call `detectAudioSources()` in parallel with GetZoneGroupState
- [ ] Update SonosDevice instances with detected audio source info before notifying UI
- [ ] Cache audio source info in devices array for UI access via `cachedDiscoveredDevices`
- [ ] Update `refreshSelectedDevice()` to preserve audio source info when updating device references
- [ ] Add logging to show detected sources: "🎵 Detected sources: Living Room (Line-In/PLAYING), Bedroom (Streaming/PLAYING)"
- [ ] Ensure `buildGroups()` maintains audio source info when constructing group objects
- [ ] Update cached values after audio source detection completes
- [ ] Handle edge case: topology loads but audio source detection fails for some speakers

#### Technical Notes

**Implementation Approach**:
```swift
private func updateGroupTopology(completion: (@Sendable () -> Void)? = nil) async {
    guard let anyDevice = devices.first else {
        completion?()
        return
    }

    // Fetch topology and audio sources in parallel
    async let topologyData = fetchZoneGroupState(for: anyDevice.ipAddress)
    async let audioSources = detectAudioSources(devices: devices)

    do {
        let (topology, sources) = try await (topologyData, audioSources)

        // Parse topology first
        parseGroupTopology(topology, completion: nil)

        // Then update devices with audio source info
        self.devices = self.devices.map { device in
            guard let sourceInfo = sources[device.uuid] else { return device }

            return SonosDevice(
                name: device.name,
                ipAddress: device.ipAddress,
                uuid: device.uuid,
                isGroupCoordinator: device.isGroupCoordinator,
                groupCoordinatorUUID: device.groupCoordinatorUUID,
                channelMapSet: device.channelMapSet,
                pairPartnerUUID: device.pairPartnerUUID,
                audioSource: sourceInfo.audioSource,
                transportState: sourceInfo.transportState
            )
        }

        updateCachedValues()
        completion?()
    } catch {
        print("❌ Topology update failed: \(error)")
        completion?()
    }
}
```

**Files to Modify**:
- `SonosController.swift` (lines 233-256): Modify `updateGroupTopology()` to fetch sources in parallel
- `SonosController.swift` (lines 258-409): Update `parseGroupTopology()` to accept and merge audio source data
- `SonosController.swift` (lines 452-466): Update `refreshSelectedDevice()` to preserve audio source info

**Testing Requirements**:
- Integration test: Verify topology loading completes with audio sources populated
- Integration test: Verify audio source info is preserved when refreshing selected device
- Manual test: Open popover and verify audio source badges appear immediately

#### Security Considerations

- Audio source URIs may contain sensitive information (usernames in streaming URIs) - log only URI prefix, not full URI
- Timeout prevents indefinite blocking if speaker is compromised/unresponsive

#### Out of Scope

- Real-time audio source monitoring (deferred - would require UPnP event subscriptions to AVTransport service)
- Audio source detection for individual volume control (only needed for grouping decisions)

---

### LINEIN-3: Refactor createGroup() to async/await with TOCTOU protection

**Type**: Task
**Priority**: P0
**Size**: L (3-4 days)
**Epic**: Phase 1 - Backend Refactoring
**Dependencies**: LINEIN-1

#### Description

Convert `createGroup()` and its helper method `performGrouping()` from callback-based to pure async/await. Implement TOCTOU (Time-of-Check-Time-of-Use) protection by re-verifying the coordinator's audio source immediately before grouping.

This is the core bug fix - ensuring line-in/TV speakers become coordinators and preventing audio sources from changing between detection and grouping.

#### Acceptance Criteria

- [ ] Convert `createGroup(devices:coordinatorDevice:completion:)` to `async func createGroup(devices:coordinatorDevice:) async throws -> Bool`
- [ ] Convert `performGrouping()` and `performGroupingInternal()` to async functions
- [ ] Implement coordinator selection logic using detected audio sources:
  - Priority 1: Line-in source (highest - must be preserved)
  - Priority 2: TV source (high - should be preserved)
  - Priority 3: Single streaming source (medium)
  - Priority 4: Idle/multiple streaming - prefer non-stereo-pair
- [ ] Add TOCTOU protection: Re-fetch coordinator's audio source immediately before calling `addDeviceToGroup()`
- [ ] If coordinator's audio source changed from line-in → something else, abort grouping and throw error
- [ ] If coordinator is stereo pair and grouping fails, auto-retry with different coordinator (existing behavior)
- [ ] Remove all DispatchQueue/DispatchGroup usage from grouping flow
- [ ] Replace completion handlers with proper async error propagation
- [ ] Update `dissolveGroup()` to async/await for consistency
- [ ] Add detailed logging showing coordinator selection reasoning

#### Technical Notes

**Implementation Approach**:
```swift
func createGroup(devices: [SonosDevice], coordinatorDevice: SonosDevice? = nil) async throws -> Bool {
    guard devices.count > 1 else {
        throw SonosError.invalidGroupSize
    }

    let coordinator: SonosDevice

    if let explicitCoordinator = coordinatorDevice {
        // User specified coordinator
        guard devices.contains(where: { $0.uuid == explicitCoordinator.uuid }) else {
            throw SonosError.coordinatorNotInList
        }
        coordinator = explicitCoordinator
    } else {
        // Intelligent selection based on audio sources
        let sources = await detectAudioSources(devices: devices)
        coordinator = selectOptimalCoordinator(devices: devices, sources: sources)
    }

    // TOCTOU Protection: Re-verify coordinator source immediately before grouping
    let verifiedSources = await detectAudioSources(devices: [coordinator])
    guard let currentSource = verifiedSources[coordinator.uuid] else {
        throw SonosError.sourceDetectionFailed
    }

    // Warn if source changed
    if let originalSource = coordinator.audioSource, originalSource != currentSource.audioSource {
        print("⚠️ Coordinator source changed: \(originalSource.description) → \(currentSource.audioSource.description)")

        // ABORT if line-in source was lost
        if originalSource == .lineIn && currentSource.audioSource != .lineIn {
            throw SonosError.lineInSourceLost
        }
    }

    // Perform grouping
    return try await performGrouping(devices: devices, coordinator: coordinator)
}

private func selectOptimalCoordinator(devices: [SonosDevice], sources: [String: AudioSourceInfo]) -> SonosDevice {
    // Priority 1: Line-in
    if let lineInDevice = devices.first(where: { sources[$0.uuid]?.audioSource == .lineIn }) {
        print("🎙️ Line-in detected: Using \(lineInDevice.name) as coordinator")
        return lineInDevice
    }

    // Priority 2: TV
    if let tvDevice = devices.first(where: { sources[$0.uuid]?.audioSource == .tv }) {
        print("📺 TV audio detected: Using \(tvDevice.name) as coordinator")
        return tvDevice
    }

    // Priority 3: Single streaming source
    let streaming = devices.filter { sources[$0.uuid]?.audioSource == .streaming && sources[$0.uuid]?.transportState == "PLAYING" }
    if streaming.count == 1 {
        print("🎵 One device streaming: Using \(streaming[0].name) as coordinator")
        return streaming[0]
    }

    // Priority 4: Prefer non-stereo-pair
    let nonStereoPair = devices.filter { $0.channelMapSet == nil }
    if let device = nonStereoPair.first {
        print("📍 Using first non-stereo-pair: \(device.name)")
        return device
    }

    // Fallback: First device
    print("📍 Using first device: \(devices[0].name)")
    return devices[0]
}

private func performGrouping(devices: [SonosDevice], coordinator: SonosDevice) async throws -> Bool {
    let membersToAdd = devices.filter { $0.uuid != coordinator.uuid }

    // Add members sequentially (Sonos requires this)
    for member in membersToAdd {
        try await addDeviceToGroup(device: member, coordinatorUUID: coordinator.uuid)
    }

    // Wait for topology to stabilize
    try await Task.sleep(nanoseconds: 1_500_000_000)

    // Refresh topology
    await updateGroupTopology(completion: nil)

    return true
}
```

**Error Types** (add to SonosController):
```swift
enum SonosError: LocalizedError {
    case invalidGroupSize
    case coordinatorNotInList
    case sourceDetectionFailed
    case lineInSourceLost
    case groupingFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case .lineInSourceLost:
            return "Line-in audio source was lost before grouping could complete. Please try again."
        case .groupingFailed(let reason):
            return "Grouping failed: \(reason)"
        default:
            return "An error occurred during grouping"
        }
    }
}
```

**Files to Modify**:
- `SonosController.swift` (lines 1015-1219): Convert `createGroup()` and helpers to async/await
- `SonosController.swift` (lines 1221-1252): Convert `dissolveGroup()` to async/await
- `SonosController.swift` (top of file): Add `SonosError` enum

**Testing Requirements**:
- Unit test: Verify line-in speaker becomes coordinator when present
- Unit test: Verify TV speaker becomes coordinator when line-in absent
- Unit test: Verify TOCTOU protection aborts if line-in source lost
- Unit test: Verify stereo pair retry logic still works
- Manual test with real Sonos: Group line-in speaker with streaming speaker, verify audio continues

#### Security Considerations

- TOCTOU protection prevents race condition where user changes audio source mid-grouping
- Error messages don't expose sensitive network topology information

#### Out of Scope

- Converting other SonosController methods to async/await (deferred)
- Warning UI before grouping (handled in LINEIN-5)

---

### LINEIN-4: Update MenuBarContentView grouping UI to use async/await

**Type**: Task
**Priority**: P0
**Size**: M (2 days)
**Epic**: Phase 1 - Backend Refactoring
**Dependencies**: LINEIN-3

#### Description

Update the "Group Selected" button handler in MenuBarContentView to call the new async `createGroup()` method. Add proper error handling and loading states to prevent UI freezes during async operations.

#### Acceptance Criteria

- [ ] Update `@objc func groupSpeakers()` to use Task wrapper for async work
- [ ] Add loading indicator (NSProgressIndicator) next to "Group Selected" button
- [ ] Disable "Group Selected" and "Ungroup Selected" buttons while grouping in progress
- [ ] Show error alert if grouping fails with user-friendly message (use SonosError.errorDescription)
- [ ] Re-enable buttons and hide loading indicator when grouping completes
- [ ] Update call sites to use `try await` instead of completion handlers
- [ ] Show success HUD after successful grouping: "Group created: [GroupName]"
- [ ] Handle line-in source lost error specifically: "Line-in source changed. Please try again."

#### Technical Notes

**Implementation Approach**:
```swift
@objc private func groupSpeakers() {
    let selectedDevices = getSelectedDevices()

    guard selectedDevices.count >= 2 else { return }

    // Show loading state
    groupButton.isEnabled = false
    ungroupButton.isEnabled = false
    showLoadingIndicator(next: groupButton)

    Task { @MainActor in
        do {
            let success = try await appDelegate?.sonosController.createGroup(
                devices: selectedDevices,
                coordinatorDevice: nil // Let algorithm choose
            )

            hideLoadingIndicator()

            if success == true {
                // Show success HUD
                VolumeHUD.shared.showSuccess(message: "Group created")

                // Refresh UI
                populateSpeakers()

                // Clear selection
                selectedSpeakerCards.removeAll()
            }
        } catch let error as SonosController.SonosError {
            hideLoadingIndicator()

            // Show user-friendly error
            let alert = NSAlert()
            alert.messageText = "Grouping Failed"
            alert.informativeText = error.errorDescription ?? "An unknown error occurred"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        } catch {
            hideLoadingIndicator()

            print("❌ Grouping error: \(error)")
        }

        // Re-enable buttons
        groupButton.isEnabled = true
        ungroupButton.isEnabled = true
    }
}
```

**Files to Modify**:
- `MenuBarContentView.swift` (lines 1347-1467): Update `groupSpeakers()` to use async/await
- `MenuBarContentView.swift` (lines 1262-1345): Update `ungroupSelected()` to use async/await
- `VolumeHUD.swift`: Add `showSuccess(message:)` method for success feedback

**Testing Requirements**:
- Manual test: Click "Group Selected", verify loading indicator appears
- Manual test: Try grouping while one speaker is unreachable, verify error alert appears
- Manual test: Group line-in speaker, verify success HUD appears

#### Security Considerations

- Error messages don't expose network details or IP addresses
- Loading state prevents multiple simultaneous grouping operations (prevents DoS)

#### Out of Scope

- Adding "Cancel" button to abort in-progress grouping (requires Task cancellation handling)

---

### LINEIN-5: Add audio source badges to speaker cards

**Type**: Story
**Priority**: P0
**Size**: M (2 days)
**Epic**: Phase 2 - UI Integration
**Dependencies**: LINEIN-2

#### Description

Display visual badges on speaker cards showing the current audio source (Line-In, TV, Streaming). This helps users understand what each speaker is playing before grouping, reducing confusion about why certain speakers become coordinators.

Use SF Symbols for icons and color-coded badges matching Sonos design patterns.

#### Acceptance Criteria

- [ ] Add badge view to speaker cards showing audio source type and playback state
- [ ] Use color-coded badges:
  - Line-In: Orange background, "lineout.fill" icon
  - TV: Purple background, "tv.fill" icon
  - Streaming: Green background, "music.note" icon
  - Idle: Gray background, "speaker.slash.fill" icon (only show when hovered)
- [ ] Show transport state text: "Playing Line-In", "Paused (Streaming)", "TV Audio"
- [ ] Position badge in top-right corner of speaker card (10pt padding)
- [ ] Badge size: 16pt icon, 11pt text, 6pt padding, 8pt corner radius
- [ ] Only show badge if audioSource is not nil (graceful degradation if detection fails)
- [ ] Update badge when topology refreshes (observe `SonosDevicesDiscovered` notification)
- [ ] Add tooltip on badge hover showing full details: "Line-In Audio (Playing)\nSource: RINCON_xxx"

#### Technical Notes

**Implementation Approach**:
```swift
private func createSpeakerCard(device: SonosDevice, isActive: Bool) -> NSView {
    let card = NSView()
    // ... existing card setup ...

    // Add audio source badge if available
    if let source = device.audioSource, source != .idle {
        let badge = createAudioSourceBadge(source: source, state: device.transportState)
        card.addSubview(badge)

        NSLayoutConstraint.activate([
            badge.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            badge.topAnchor.constraint(equalTo: card.topAnchor, constant: 10)
        ])
    }

    return card
}

private func createAudioSourceBadge(source: SonosController.AudioSourceType, state: String?) -> NSView {
    let container = NSView()
    container.wantsLayer = true
    container.layer?.backgroundColor = badgeColor(for: source).cgColor
    container.layer?.cornerRadius = 8
    container.translatesAutoresizingMaskIntoConstraints = false

    let icon = NSImageView()
    icon.image = NSImage(systemSymbolName: iconName(for: source), accessibilityDescription: source.description)
    icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
    icon.contentTintColor = .white
    icon.translatesAutoresizingMaskIntoConstraints = false

    let label = NSTextField(labelWithString: badgeText(for: source, state: state))
    label.font = .systemFont(ofSize: 10, weight: .semibold)
    label.textColor = .white
    label.translatesAutoresizingMaskIntoConstraints = false

    container.addSubview(icon)
    container.addSubview(label)

    NSLayoutConstraint.activate([
        container.heightAnchor.constraint(equalToConstant: 24),
        icon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
        icon.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
        label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
        label.centerYAnchor.constraint(equalTo: container.centerYAnchor)
    ])

    // Add tooltip
    container.toolTip = tooltipText(for: source, state: state)

    return container
}

private func badgeColor(for source: SonosController.AudioSourceType) -> NSColor {
    switch source {
    case .lineIn: return NSColor.systemOrange
    case .tv: return NSColor.systemPurple
    case .streaming: return NSColor.systemGreen
    case .idle, .grouped: return NSColor.systemGray
    }
}

private func iconName(for source: SonosController.AudioSourceType) -> String {
    switch source {
    case .lineIn: return "lineout.fill"
    case .tv: return "tv.fill"
    case .streaming: return "music.note"
    case .idle: return "speaker.slash.fill"
    case .grouped: return "link"
    }
}

private func badgeText(for source: SonosController.AudioSourceType, state: String?) -> String {
    let playing = (state == "PLAYING")
    switch source {
    case .lineIn: return playing ? "Line-In" : "Line-In (Paused)"
    case .tv: return "TV"
    case .streaming: return playing ? "Playing" : "Paused"
    case .idle: return "Idle"
    case .grouped: return "Grouped"
    }
}
```

**Files to Modify**:
- `MenuBarContentView.swift` (lines 548-671): Modify `createSpeakerCard()` to add badge
- `MenuBarContentView.swift` (new methods): Add badge creation helpers

**Design Reference**:
- Match Liquid Glass design system used elsewhere in the app
- Similar to group indicator badges already in use

**Testing Requirements**:
- Manual test: Open popover with line-in speaker playing, verify orange badge appears
- Manual test: Open popover with TV audio, verify purple badge appears
- Manual test: Pause music, verify badge updates to "Paused"
- Visual regression test: Verify badge doesn't break card layout

#### Security Considerations

- Tooltip text doesn't expose sensitive RINCON IDs (removed from final implementation)

#### Out of Scope

- Real-time badge updates without reopening popover (requires AVTransport event subscriptions)
- Animated transitions when badge changes (nice-to-have polish)

---

### LINEIN-6: Add grouping preview helper text

**Type**: Story
**Priority**: P1
**Size**: S (1 day)
**Epic**: Phase 2 - UI Integration
**Dependencies**: LINEIN-3, LINEIN-5

#### Description

Show helper text above the "Group Selected" button explaining what will happen when the user groups speakers. This provides transparency about coordinator selection and helps users understand why line-in/TV speakers become group leaders.

#### Acceptance Criteria

- [ ] Add helper text label above "Group Selected" button (between speaker list and button)
- [ ] Show coordinator prediction when 2+ speakers selected:
  - "Will use [Speaker Name] as group leader (Line-In audio)"
  - "Will use [Speaker Name] as group leader (TV audio)"
  - "Will use [Speaker Name] as group leader (Currently playing)"
  - "Will use [Speaker Name] as group leader" (default)
- [ ] Helper text color: `.secondaryLabelColor`
- [ ] Helper text font: 11pt system font, regular weight
- [ ] Hide helper text when < 2 speakers selected
- [ ] Update helper text in real-time as speaker selection changes
- [ ] Add warning icon (⚠️) when selecting line-in speaker + stereo pair: "Grouping may fail due to stereo pair limitations"

#### Technical Notes

**Implementation Approach**:
```swift
private var groupingHelperLabel: NSTextField!

private func setupSpeakersSection(in container: NSView) {
    // ... existing code ...

    // Grouping helper text
    groupingHelperLabel = NSTextField(wrappingLabelWithString: "")
    groupingHelperLabel.font = .systemFont(ofSize: 11, weight: .regular)
    groupingHelperLabel.textColor = .secondaryLabelColor
    groupingHelperLabel.alignment = .center
    groupingHelperLabel.isHidden = true
    groupingHelperLabel.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(groupingHelperLabel)

    NSLayoutConstraint.activate([
        groupingHelperLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
        groupingHelperLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
        groupingHelperLabel.bottomAnchor.constraint(equalTo: groupButton.topAnchor, constant: -8)
    ])
}

@objc private func speakerSelectionChanged(_ sender: NSButton) {
    // ... existing selection logic ...

    updateGroupingHelperText()
}

private func updateGroupingHelperText() {
    let selectedDevices = getSelectedDevices()

    guard selectedDevices.count >= 2 else {
        groupingHelperLabel.isHidden = true
        return
    }

    // Predict coordinator using same logic as createGroup()
    Task {
        let sources = await appDelegate?.sonosController.detectAudioSources(devices: selectedDevices)

        await MainActor.run {
            guard let sources = sources else { return }

            // Find predicted coordinator
            let lineIn = selectedDevices.first { sources[$0.uuid]?.audioSource == .lineIn }
            let tv = selectedDevices.first { sources[$0.uuid]?.audioSource == .tv }
            let streaming = selectedDevices.filter { sources[$0.uuid]?.audioSource == .streaming && sources[$0.uuid]?.transportState == "PLAYING" }

            var helperText = ""
            var showWarning = false

            if let coordinator = lineIn {
                helperText = "Will use \(coordinator.name) as group leader (Line-In audio)"
                showWarning = coordinator.channelMapSet != nil
            } else if let coordinator = tv {
                helperText = "Will use \(coordinator.name) as group leader (TV audio)"
                showWarning = coordinator.channelMapSet != nil
            } else if streaming.count == 1 {
                helperText = "Will use \(streaming[0].name) as group leader (Currently playing)"
            } else {
                helperText = "Will group \(selectedDevices.count) speakers"
            }

            if showWarning {
                helperText += "\n⚠️ Grouping may fail (stereo pair limitation)"
            }

            groupingHelperLabel.stringValue = helperText
            groupingHelperLabel.isHidden = false
        }
    }
}
```

**Files to Modify**:
- `MenuBarContentView.swift` (lines 298-411): Add helper label to `setupSpeakersSection()`
- `MenuBarContentView.swift` (new method): Add `updateGroupingHelperText()`
- `MenuBarContentView.swift` (line ~1467): Call `updateGroupingHelperText()` in `speakerSelectionChanged()`

**Testing Requirements**:
- Manual test: Select line-in speaker + streaming speaker, verify helper text shows line-in as coordinator
- Manual test: Select TV speaker + idle speaker, verify helper text shows TV as coordinator
- Manual test: Select 2 idle speakers, verify generic helper text appears
- Manual test: Select stereo pair with line-in, verify warning appears

#### Security Considerations

- None (informational UI only)

#### Out of Scope

- Interactive coordinator override ("Change coordinator" dropdown) - add to P2 enhancements

---

### LINEIN-7: Add error handling and validation for grouping

**Type**: Story
**Priority**: P1
**Size**: M (1-2 days)
**Epic**: Phase 2 - UI Integration
**Dependencies**: LINEIN-4

#### Description

Implement comprehensive error handling for grouping failures, including user-friendly error messages, retry logic, and graceful degradation when audio source detection fails.

#### Acceptance Criteria

- [ ] Show specific error messages for each SonosError type:
  - `.lineInSourceLost`: "Line-in audio changed. Please check your source and try again."
  - `.sourceDetectionFailed`: "Couldn't detect audio sources. Grouping with default coordinator."
  - `.groupingFailed`: "Grouping failed: [reason]"
- [ ] Add "Try Again" button to error alerts
- [ ] If audio source detection times out, allow grouping to continue with warning
- [ ] Log detailed error context for debugging (device UUIDs, network errors)
- [ ] Add fallback behavior: If TOCTOU check fails for line-in → non-line-in change, show warning but allow user to continue
- [ ] Show loading indicator during retry attempts
- [ ] Limit retries to 2 attempts before showing final error
- [ ] Add telemetry/logging for grouping failures (anonymized device counts, error types)

#### Technical Notes

**Implementation Approach**:
```swift
@objc private func groupSpeakers() {
    attemptGrouping(retryCount: 0)
}

private func attemptGrouping(retryCount: Int, maxRetries: Int = 2) {
    let selectedDevices = getSelectedDevices()

    guard selectedDevices.count >= 2 else { return }

    groupButton.isEnabled = false
    showLoadingIndicator(next: groupButton)

    Task { @MainActor in
        do {
            let success = try await appDelegate?.sonosController.createGroup(
                devices: selectedDevices,
                coordinatorDevice: nil
            )

            hideLoadingIndicator()

            if success == true {
                VolumeHUD.shared.showSuccess(message: "Group created")
                populateSpeakers()
                selectedSpeakerCards.removeAll()
            }
        } catch SonosController.SonosError.lineInSourceLost {
            hideLoadingIndicator()

            let alert = NSAlert()
            alert.messageText = "Line-In Source Changed"
            alert.informativeText = "The line-in audio source changed while grouping. Please check your audio input and try again."
            alert.alertStyle = .warning

            if retryCount < maxRetries {
                alert.addButton(withTitle: "Try Again")
                alert.addButton(withTitle: "Cancel")

                let response = alert.runModal()
                if response == .alertFirstButtonReturn {
                    attemptGrouping(retryCount: retryCount + 1, maxRetries: maxRetries)
                    return
                }
            } else {
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }

        } catch SonosController.SonosError.sourceDetectionFailed {
            hideLoadingIndicator()

            // Allow grouping to continue with warning
            let alert = NSAlert()
            alert.messageText = "Audio Source Detection Failed"
            alert.informativeText = "Couldn't detect what your speakers are playing. Grouping will use the first selected speaker as the leader.\n\nContinue anyway?"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Cancel")

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                // Retry with explicit coordinator (first selected)
                Task {
                    do {
                        _ = try await appDelegate?.sonosController.createGroup(
                            devices: selectedDevices,
                            coordinatorDevice: selectedDevices[0]
                        )
                        VolumeHUD.shared.showSuccess(message: "Group created")
                        populateSpeakers()
                        selectedSpeakerCards.removeAll()
                    } catch {
                        showGenericError(error)
                    }
                }
            }

        } catch {
            hideLoadingIndicator()
            showGenericError(error)
        }

        groupButton.isEnabled = true
    }
}

private func showGenericError(_ error: Error) {
    let alert = NSAlert()
    alert.messageText = "Grouping Failed"
    alert.informativeText = error.localizedDescription
    alert.alertStyle = .critical
    alert.addButton(withTitle: "OK")
    alert.runModal()
}
```

**Files to Modify**:
- `MenuBarContentView.swift` (lines 1347-1467): Enhance `groupSpeakers()` with retry logic
- `MenuBarContentView.swift` (new methods): Add error handling helpers

**Testing Requirements**:
- Manual test: Disconnect line-in cable mid-grouping, verify error message appears
- Manual test: Disable network mid-grouping, verify retry logic works
- Manual test: Exceed retry limit, verify final error message appears
- Unit test: Verify retry counter increments correctly

#### Security Considerations

- Error logs don't include IP addresses or network topology
- Anonymize telemetry data (only error types and counts, no device identifiers)

#### Out of Scope

- Automatic retry without user confirmation (could cause infinite loops)
- Undo functionality for failed grouping attempts

---

### LINEIN-8: Comprehensive testing with real Sonos hardware

**Type**: Task
**Priority**: P0
**Size**: M (2 days)
**Epic**: Phase 3 - Testing & Polish
**Dependencies**: LINEIN-1, LINEIN-2, LINEIN-3, LINEIN-4, LINEIN-5, LINEIN-6, LINEIN-7

#### Description

Perform comprehensive manual testing with real Sonos speakers to validate the line-in grouping fix across various scenarios. Document test results and file follow-up tickets for any discovered issues.

#### Acceptance Criteria

**Scenario 1: Line-In Grouping (Primary Use Case)**
- [ ] Connect turntable/phone to speaker line-in port
- [ ] Play audio (verify audio playing before grouping)
- [ ] Group line-in speaker with 2nd speaker via app
- [ ] Verify audio continues playing on both speakers
- [ ] Verify line-in badge shows on speaker card
- [ ] Verify line-in speaker is group coordinator (check topology)
- [ ] Adjust group volume, verify both speakers change
- [ ] Ungroup, verify audio continues on line-in speaker

**Scenario 2: TV Audio Grouping**
- [ ] Connect TV to Sonos soundbar or speaker
- [ ] Play TV audio (verify audio playing)
- [ ] Group TV speaker with 2nd speaker
- [ ] Verify TV audio plays on both speakers
- [ ] Verify TV badge shows on speaker card
- [ ] Verify TV speaker is group coordinator

**Scenario 3: Streaming Audio Grouping**
- [ ] Play Spotify on Speaker A (solo)
- [ ] Group Speaker A with Speaker B (idle)
- [ ] Verify streaming speaker becomes coordinator
- [ ] Verify Spotify continues playing on both speakers
- [ ] Verify green "Playing" badge shows on speaker card

**Scenario 4: Multiple Streaming Sources**
- [ ] Play Spotify on Speaker A
- [ ] Play Apple Music on Speaker B
- [ ] Group both speakers
- [ ] Verify one streaming source continues (the selected coordinator)
- [ ] Verify other speaker stops playback

**Scenario 5: Stereo Pair + Line-In**
- [ ] Create stereo pair (Speaker A + Speaker B)
- [ ] Connect line-in to stereo pair
- [ ] Play line-in audio
- [ ] Group stereo pair with Speaker C
- [ ] Verify audio continues OR retry logic kicks in (stereo pair limitation)

**Scenario 6: TOCTOU Protection**
- [ ] Start playing line-in audio on Speaker A
- [ ] Select Speaker A + Speaker B for grouping
- [ ] **While grouping in progress**, disconnect line-in cable
- [ ] Verify error message: "Line-in source changed"
- [ ] Verify grouping aborted (speakers remain separate)

**Scenario 7: Network Timeout**
- [ ] Disconnect Speaker B from WiFi
- [ ] Try to group Speaker A + Speaker B
- [ ] Verify timeout error appears within 5 seconds
- [ ] Verify "Try Again" button works after reconnecting Speaker B

**Scenario 8: UI Validation**
- [ ] Verify badges appear immediately when opening popover (no delay)
- [ ] Verify helper text updates when selecting different speakers
- [ ] Verify loading indicator shows during grouping
- [ ] Verify success HUD appears after grouping completes
- [ ] Verify error alerts are user-friendly (no technical jargon)

**Edge Cases**
- [ ] Group 3 speakers (A=line-in, B=streaming, C=idle) → verify A becomes coordinator
- [ ] Group 2 idle speakers → verify first becomes coordinator
- [ ] Group speaker with itself (should be prevented by UI)
- [ ] Group already-grouped speaker with another group (merge groups)

#### Technical Notes

**Test Environment**:
- Minimum 3 Sonos speakers (at least one with line-in port)
- Audio source (turntable, phone, or TV)
- WiFi network with stable connection
- macOS test machine with accessibility permissions granted

**Documentation**:
- Record test results in GitHub issue or spreadsheet
- Screenshot any UI bugs or unexpected behavior
- Note timing of async operations (should complete within 2-5 seconds)
- Document any Sonos API quirks discovered

**Files to Review**:
- All files modified in LINEIN-1 through LINEIN-7

**Testing Requirements**:
- All 8 scenarios must pass
- All edge cases must be handled gracefully
- No crashes or frozen UI
- No audio interruptions for line-in/TV sources

#### Security Considerations

- Test with guest WiFi network to ensure no local network permission issues
- Verify app doesn't expose speaker IP addresses in UI

#### Out of Scope

- Automated integration tests (deferred to future test infrastructure work)
- Performance testing with 10+ speakers (test with 3-5 speakers only)

---

### LINEIN-9: Add unit tests for coordinator selection logic

**Type**: Task
**Priority**: P1
**Size**: S (1 day)
**Epic**: Phase 3 - Testing & Polish
**Dependencies**: LINEIN-3

#### Description

Write unit tests for the new coordinator selection logic to ensure correct priority ordering and prevent regressions in future refactoring.

#### Acceptance Criteria

- [ ] Add test suite: `CoordinatorSelectionTests.swift`
- [ ] Test priority 1: Line-in speaker selected over TV/streaming/idle
- [ ] Test priority 2: TV speaker selected over streaming/idle (when no line-in)
- [ ] Test priority 3: Single streaming speaker selected over idle (when no line-in/TV)
- [ ] Test multiple streaming sources: Prefer non-stereo-pair
- [ ] Test fallback: Idle speakers default to first non-stereo-pair
- [ ] Test stereo pair detection: channelMapSet != nil
- [ ] Test audio source type detection from URI (x-rincon-stream:, x-sonos-htastream:, etc.)
- [ ] Test TOCTOU scenario: Mock audio source changing mid-grouping
- [ ] Achieve >80% code coverage for `selectOptimalCoordinator()` method

#### Technical Notes

**Implementation Approach**:
```swift
import XCTest
@testable import SonosVolumeController

final class CoordinatorSelectionTests: XCTestCase {

    func testLineInSpeakerHasHighestPriority() {
        let devices = [
            createDevice(name: "Speaker A", audioSource: .streaming),
            createDevice(name: "Speaker B", audioSource: .lineIn),
            createDevice(name: "Speaker C", audioSource: .idle)
        ]

        let sources = createSources(for: devices)
        let coordinator = SonosController.selectOptimalCoordinator(devices: devices, sources: sources)

        XCTAssertEqual(coordinator.name, "Speaker B", "Line-in speaker should be selected")
    }

    func testTVSpeakerSelectedWhenNoLineIn() {
        let devices = [
            createDevice(name: "Speaker A", audioSource: .streaming),
            createDevice(name: "Speaker B", audioSource: .tv),
            createDevice(name: "Speaker C", audioSource: .idle)
        ]

        let sources = createSources(for: devices)
        let coordinator = SonosController.selectOptimalCoordinator(devices: devices, sources: sources)

        XCTAssertEqual(coordinator.name, "Speaker B", "TV speaker should be selected when no line-in")
    }

    func testSingleStreamingSpeakerSelected() {
        let devices = [
            createDevice(name: "Speaker A", audioSource: .streaming, state: "PLAYING"),
            createDevice(name: "Speaker B", audioSource: .idle),
            createDevice(name: "Speaker C", audioSource: .idle)
        ]

        let sources = createSources(for: devices)
        let coordinator = SonosController.selectOptimalCoordinator(devices: devices, sources: sources)

        XCTAssertEqual(coordinator.name, "Speaker A", "Single streaming speaker should be selected")
    }

    func testMultipleStreamingPreferNonStereoPair() {
        let devices = [
            createDevice(name: "Stereo Pair", audioSource: .streaming, state: "PLAYING", isStereoPair: true),
            createDevice(name: "Solo Speaker", audioSource: .streaming, state: "PLAYING", isStereoPair: false)
        ]

        let sources = createSources(for: devices)
        let coordinator = SonosController.selectOptimalCoordinator(devices: devices, sources: sources)

        XCTAssertEqual(coordinator.name, "Solo Speaker", "Should prefer non-stereo-pair when multiple streaming")
    }

    func testAudioSourceDetectionFromURI() {
        let lineInURI = "x-rincon-stream:RINCON_ABC123"
        let tvURI = "x-sonos-htastream:RINCON_DEF456:spdif"
        let spotifyURI = "x-sonos-spotify:spotify%3atrack%3a..."

        XCTAssertEqual(SonosController.detectAudioSourceType(from: lineInURI), .lineIn)
        XCTAssertEqual(SonosController.detectAudioSourceType(from: tvURI), .tv)
        XCTAssertEqual(SonosController.detectAudioSourceType(from: spotifyURI), .streaming)
    }

    // Helper methods
    private func createDevice(name: String, audioSource: SonosController.AudioSourceType, state: String = "STOPPED", isStereoPair: Bool = false) -> SonosController.SonosDevice {
        return SonosController.SonosDevice(
            name: name,
            ipAddress: "192.168.1.100",
            uuid: UUID().uuidString,
            isGroupCoordinator: false,
            groupCoordinatorUUID: nil,
            channelMapSet: isStereoPair ? "PAIR_123" : nil,
            pairPartnerUUID: nil,
            audioSource: audioSource,
            transportState: state
        )
    }

    private func createSources(for devices: [SonosController.SonosDevice]) -> [String: SonosController.AudioSourceInfo] {
        var sources: [String: SonosController.AudioSourceInfo] = [:]
        for device in devices {
            sources[device.uuid] = SonosController.AudioSourceInfo(
                audioSource: device.audioSource ?? .idle,
                transportState: device.transportState ?? "STOPPED"
            )
        }
        return sources
    }
}
```

**Files to Create**:
- `Tests/CoordinatorSelectionTests.swift`

**Files to Modify**:
- `SonosController.swift`: Make `selectOptimalCoordinator()` testable (may need to extract to separate file or make internal)

**Testing Requirements**:
- All tests must pass
- Code coverage >80% for coordinator selection logic
- Tests run in <1 second (no network calls, all mocked)

#### Security Considerations

- Mock data doesn't include real device UUIDs or IP addresses

#### Out of Scope

- Integration tests with real network calls (handled in LINEIN-8)
- UI testing (no UI in unit tests)

---

## Ticket Sizing Guide

**Story Points Estimation**:

- **S (Small) - 1 day**: Single component change, well-understood problem, minimal dependencies
  - Example: LINEIN-6 (Add helper text)

- **M (Medium) - 2-3 days**: Multiple related components, moderate complexity, few dependencies
  - Example: LINEIN-2 (Integrate source detection into topology)

- **L (Large) - 3-4 days**: Complex feature with multiple parts, high complexity, significant new code
  - Example: LINEIN-1 (Refactor to async/await), LINEIN-3 (createGroup refactor)

- **XL (Extra Large) - 5+ days**: Should be broken down further
  - None in this breakdown (all tickets are appropriately sized)

**Effort vs. Complexity**:
- Effort is calendar time (includes testing, code review, documentation)
- Complexity is technical difficulty (algorithm design, concurrency patterns)
- Some tickets are high complexity but low effort (LINEIN-9: unit tests)
- Some tickets are low complexity but high effort (LINEIN-8: manual testing)

---

## Critical Path

```
┌─────────────┐
│  LINEIN-1   │ ← Start here (no dependencies)
│  Audio      │
│  Detection  │
│  Async      │
│  (3-4 days) │
└──────┬──────┘
       │
       ├──────────────────────┐
       │                      │
       ▼                      ▼
┌─────────────┐        ┌─────────────┐
│  LINEIN-2   │        │  LINEIN-3   │ ← Can work in parallel
│  Topology   │        │  createGroup│
│  Integration│        │  Refactor   │
│  (2-3 days) │        │  (3-4 days) │
└──────┬──────┘        └──────┬──────┘
       │                      │
       │                      ▼
       │               ┌─────────────┐
       │               │  LINEIN-4   │
       │               │  UI Update  │
       │               │  (2 days)   │
       │               └──────┬──────┘
       │                      │
       └──────────┬───────────┘
                  │
                  ▼
           ┌─────────────┐
           │  LINEIN-5   │ ← UI work can happen in parallel
           │  Badges     │
           │  (2 days)   │
           └──────┬──────┘
                  │
                  ▼
           ┌─────────────┐
           │  LINEIN-6   │
           │  Helper Text│
           │  (1 day)    │
           └──────┬──────┘
                  │
                  ▼
           ┌─────────────┐
           │  LINEIN-7   │
           │  Error      │
           │  Handling   │
           │  (1-2 days) │
           └──────┬──────┘
                  │
                  ├──────────────────────┐
                  │                      │
                  ▼                      ▼
           ┌─────────────┐        ┌─────────────┐
           │  LINEIN-8   │        │  LINEIN-9   │ ← Can work in parallel
           │  Manual     │        │  Unit Tests │
           │  Testing    │        │  (1 day)    │
           │  (2 days)   │        └─────────────┘
           └─────────────┘
```

**Critical Path Duration**: 12-15 days (assuming sequential work)
**Optimized Duration with Parallelization**: 10-12 days

**Parallelization Opportunities**:
1. LINEIN-2 and LINEIN-3 can be developed simultaneously by different engineers
2. LINEIN-5, LINEIN-6, LINEIN-7 are UI-focused and can be done by frontend engineer while backend work is in review
3. LINEIN-8 and LINEIN-9 can be done in parallel (manual testing + unit testing)

**Blocking Dependencies**:
- LINEIN-4 blocks all UI work (must wait for backend refactor)
- LINEIN-8 blocks release (comprehensive testing required before merge)

---

## Dependencies & Blockers

### Internal Dependencies

**Sequential Dependencies**:
- LINEIN-2 → requires LINEIN-1 (needs async detection method)
- LINEIN-3 → requires LINEIN-1 (needs async detection method)
- LINEIN-4 → requires LINEIN-3 (needs async createGroup method)
- LINEIN-5 → requires LINEIN-2 (needs audioSource populated in topology)
- LINEIN-6 → requires LINEIN-3 + LINEIN-5 (needs coordinator prediction + badges)
- LINEIN-7 → requires LINEIN-4 (enhances UI error handling)
- LINEIN-8 → requires LINEIN-1 through LINEIN-7 (tests complete feature)
- LINEIN-9 → requires LINEIN-3 (tests coordinator selection logic)

**Parallel Work Streams**:
- **Backend Track**: LINEIN-1 → LINEIN-2 + LINEIN-3 → LINEIN-4
- **UI Track**: LINEIN-5 → LINEIN-6 → LINEIN-7 (can start after LINEIN-2 completes)
- **Testing Track**: LINEIN-8 + LINEIN-9 (can start after LINEIN-7)

### External Dependencies

**None** - This is a self-contained bug fix with no external dependencies:
- No API changes required
- No new libraries or frameworks
- No design system updates
- No backend service changes

### Known Blockers

**Before Starting Work**:
- [ ] Ensure test environment has 3+ Sonos speakers available
- [ ] Ensure at least 1 speaker has line-in port for testing
- [ ] Ensure development Mac has accessibility permissions granted
- [ ] Confirm SonosNetworkClient already supports async/await (verified: yes)

**During Implementation**:
- **Sonos API Rate Limits**: None known, but excessive SOAP requests during development could trigger device rate limiting. Recommendation: Add 100ms delay between requests during testing.
- **Network Instability**: SOAP requests may timeout on congested WiFi. Recommendation: Test on stable network, use 5-second timeouts.
- **Stereo Pair Limitations**: Sonos API has undocumented limitations grouping stereo pairs. Recommendation: Implement retry logic, document limitation in UI.

---

## Handoff Plan

### Away Team vs. Owning Team

**This project uses an away team model**:
- **Away Team**: Builds and delivers the complete feature
- **Owning Team**: Maintains the code long-term after handoff

**For This Ticket Breakdown**:
- **Away Team (Austin)** will implement LINEIN-1 through LINEIN-9 completely
- **Owning Team** will receive fully-implemented, tested, and documented feature
- No mid-implementation handoff required

### What the Away Team Delivers

**Code Deliverables**:
- [ ] All 9 tickets implemented and merged to main branch
- [ ] Unit tests written and passing (LINEIN-9)
- [ ] Manual test results documented (LINEIN-8)
- [ ] No known bugs or regressions
- [ ] Code review completed by at least 1 other developer

**Documentation Deliverables**:
- [ ] This JIRA breakdown document (for future reference)
- [ ] Updated CHANGELOG.md with feature description and PR number
- [ ] Updated ROADMAP.md (remove bug from P0, add any deferred enhancements to P1/P2)
- [ ] Inline code comments explaining coordinator selection algorithm
- [ ] README section explaining how line-in grouping works (user-facing docs)

**Knowledge Transfer**:
- [ ] Record 5-minute demo video showing feature in action
- [ ] Document any Sonos API quirks discovered during implementation
- [ ] List any follow-up work or tech debt items in ROADMAP.md

### What the Owning Team Receives

**Production-Ready Code**:
- Fully tested async/await grouping logic
- UI with badges and helper text
- Comprehensive error handling
- No known critical bugs

**Maintenance Guidance**:
- Inline comments explain coordinator selection priority
- Unit tests document expected behavior
- Manual test scenarios documented for regression testing
- Known Sonos API limitations documented

**Future Enhancement Ideas** (deferred to P1/P2):
- Real-time badge updates without reopening popover (requires AVTransport event subscriptions)
- Interactive coordinator override UI ("Choose different leader" dropdown)
- Animated badge transitions when audio source changes
- Telemetry dashboard for grouping success rates

---

## Testing Strategy

### Unit Testing

**Scope**: Core business logic (coordinator selection, audio source detection)

**Test Coverage Goals**:
- `selectOptimalCoordinator()`: 85% coverage
- `detectAudioSourceType()`: 90% coverage
- `detectAudioSources()`: 75% coverage (async logic)

**Test Files**:
- `CoordinatorSelectionTests.swift` (LINEIN-9)
- `AudioSourceDetectionTests.swift` (LINEIN-9)

**Mocking Strategy**:
- Mock `SonosNetworkClient` for SOAP responses
- Use test fixtures for SOAP XML responses
- No real network calls in unit tests

### Integration Testing

**Scope**: End-to-end flows with real Sonos speakers

**Test Scenarios**: Documented in LINEIN-8 (8 scenarios + edge cases)

**Environment**:
- 3+ Sonos speakers (1 with line-in)
- macOS test machine
- Stable WiFi network

**Success Criteria**:
- All 8 scenarios pass
- No audio interruptions
- No UI freezes
- Error handling works as expected

### Manual Testing

**Focus Areas**:
1. **Audio Quality**: No clicks, pops, or dropouts during grouping
2. **UI Responsiveness**: Loading indicators appear, buttons disable correctly
3. **Error Messages**: User-friendly, actionable, no technical jargon
4. **Badge Accuracy**: Badges match actual audio sources
5. **Helper Text**: Predictions match actual coordinator selection

**Test Checklist**: See LINEIN-8 acceptance criteria

### Performance Testing

**Metrics to Track**:
- Source detection time for 5 speakers: <5 seconds
- Grouping operation time: 2-5 seconds
- UI update latency after topology change: <500ms

**No Formal Load Testing Required** (small-scale home audio app)

---

## Deployment & Rollout

### Deployment Strategy

**Approach**: Always-on improvement (Option B)

**Rationale**:
- This is a bug fix, not a new feature - should be available immediately
- No feature flag needed - behavior is backward compatible
- Extensively tested before merge (LINEIN-8)

### Build & Release Process

**Build Steps**:
```bash
# Build release binary
./build-app.sh

# Run unit tests
swift test

# Build and install for manual testing
./build-app.sh --install
```

**Pre-Merge Checklist**:
- [ ] All unit tests passing
- [ ] Manual test scenarios completed (LINEIN-8)
- [ ] Code review approved
- [ ] No compiler warnings
- [ ] CHANGELOG.md updated
- [ ] ROADMAP.md updated

**Merge Process**:
1. Squash and merge PR to `main` branch
2. Tag release: `git tag v1.x.x`
3. Build release binary: `./build-app.sh`
4. Distribute to beta testers (if applicable)
5. Monitor for issues via GitHub Issues

### Rollback Plan

**If Critical Bug Found Post-Merge**:
1. Revert the merge commit immediately
2. Create hotfix branch from previous stable commit
3. Fix issue in hotfix branch
4. Re-test thoroughly before merging again

**Rollback Command**:
```bash
git revert <merge-commit-hash>
git push origin main
```

### Monitoring & Observability

**Logging**:
- Add structured logging for grouping operations:
  - Coordinator selection reasoning
  - Audio source detection results
  - TOCTOU check outcomes
  - Grouping success/failure

**Log Format**:
```
🔍 [GROUPING] Selecting coordinator for 3 devices
🎙️ [GROUPING] Line-in detected: Speaker A (priority: 3)
✅ [GROUPING] Selected: Speaker A (Line-In)
⚠️ [GROUPING] TOCTOU check: Source unchanged (Line-In)
✅ [GROUPING] Group created successfully
```

**No Telemetry/Analytics** (privacy-focused app - no tracking)

**User Feedback Channels**:
- GitHub Issues for bug reports
- Monitor Console.app logs for crash reports

### Launch Checklist

**Pre-Launch** (1 day before merge):
- [ ] All tickets (LINEIN-1 through LINEIN-9) completed
- [ ] Code review passed
- [ ] Manual testing completed
- [ ] Documentation updated
- [ ] Beta testers notified (if applicable)

**Launch Day**:
- [ ] Merge PR to main
- [ ] Build release binary
- [ ] Update GitHub Release notes
- [ ] Monitor GitHub Issues for bug reports

**Post-Launch** (1 week after merge):
- [ ] Review GitHub Issues for regression reports
- [ ] Collect user feedback
- [ ] Plan follow-up enhancements (if needed)

---

## Risk Assessment

### Technical Risks

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| **TOCTOU race condition not fully prevented** | Medium | High | Comprehensive manual testing (LINEIN-8 Scenario 6), unit tests for edge cases |
| **Async/await refactor introduces deadlocks** | Low | High | Code review by Swift concurrency expert, manual testing with multiple grouping operations |
| **Timeout handling causes UI freezes** | Low | Medium | Test on slow network, use structured concurrency (TaskGroup with timeouts) |
| **Stereo pair grouping still fails** | Medium | Low | Document limitation in UI (warning text), implement retry logic |
| **Audio source detection false positives** | Low | Medium | Test with multiple audio source types, validate against Sonos app behavior |
| **Performance degradation with 10+ speakers** | Low | Low | Parallel source detection with TaskGroup (should scale linearly), defer to future optimization if needed |

### Timeline Risks

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| **Async/await refactor takes longer than estimated** | Medium | Medium | LINEIN-1 and LINEIN-3 are sized as L (3-4 days) with buffer, break into smaller subtasks if needed |
| **Manual testing uncovers critical bugs** | Medium | High | Allocate 2 full days for LINEIN-8, plan for 1-2 days of bug fixes before merge |
| **Code review feedback requires significant changes** | Low | Medium | Share design doc before implementation, conduct mid-sprint code review |
| **Test environment (Sonos speakers) unavailable** | Low | High | Confirm speaker availability before starting work, have backup test plan |

### User Impact Risks

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| **Users group line-in speakers before update and audio cuts out** | High (current bug) | High | Fix is P0 - prioritize completion, no workarounds available |
| **New error messages confuse users** | Low | Low | User-friendly error text (LINEIN-7), avoid technical jargon |
| **Badges show incorrect audio sources** | Low | Medium | Comprehensive testing (LINEIN-8), validate against Sonos app |
| **Grouping takes longer than before** | Low | Low | Parallel source detection should be faster than sequential, monitor performance |

---

## Open Questions

**Architecture & Implementation**:

1. **Q**: Should we add feature flag for gradual rollout?
   **A**: No - this is a bug fix, should be always-on. Well-tested before merge.

2. **Q**: Should we cache audio sources to avoid re-detection on every grouping?
   **A**: No - audio sources change frequently (user plays/pauses music). Always fetch fresh data, add caching as future optimization if performance issues arise.

3. **Q**: Should we add undo functionality for grouping?
   **A**: Out of scope - deferred to P2 enhancement.

4. **Q**: How do we handle devices that fail source detection (timeout)?
   **A**: Default to `.idle` audioSource, log warning, allow grouping to continue with warning message to user (LINEIN-7).

**Testing & Quality**:

5. **Q**: What's the minimum Sonos speaker count for testing?
   **A**: 3 speakers minimum (1 with line-in). Ideal: 5 speakers including 1 stereo pair.

6. **Q**: Should we add automated integration tests?
   **A**: Out of scope - manual testing (LINEIN-8) is sufficient for this phase. Add automated tests as future tech debt (P2).

7. **Q**: How do we test TOCTOU race conditions reliably?
   **A**: Manual test (LINEIN-8 Scenario 6): Disconnect line-in cable mid-grouping. Difficult to automate, requires real hardware.

**UI & UX**:

8. **Q**: Should badges update in real-time as audio sources change?
   **A**: No - requires AVTransport event subscriptions (significant complexity). Deferred to P1 enhancement. Badges refresh when popover reopens (acceptable for v1).

9. **Q**: What if user disagrees with coordinator selection?
   **A**: Deferred to P2 enhancement: "Choose different leader" dropdown. For v1, algorithm is intelligent enough for 95% of cases.

10. **Q**: Should we show a confirmation dialog before grouping line-in speakers?
    **A**: No - helper text (LINEIN-6) provides transparency, confirmation dialog adds friction. If grouping fails, user can retry.

**Sonos API & Limitations**:

11. **Q**: What if Sonos API changes GetPositionInfo response format?
    **A**: XML parsing is defensive (uses optional extraction). Add error logging if parsing fails, default to `.idle` source type.

12. **Q**: Can we detect AirPlay 2 sources?
    **A**: Unknown - needs testing. If AirPlay URIs have distinct prefix (e.g., `x-sonos-airplay:`), add to AudioSourceType enum. Deferred until testing confirms.

---

## Future Enhancements

**Deferred to ROADMAP.md** (not blocking this bug fix):

### P1 Enhancements

- **Real-time audio source monitoring**: Subscribe to AVTransport UPnP events to update badges without reopening popover (requires significant event handling infrastructure)
- **Interactive coordinator override**: "Choose different leader" dropdown when multiple high-priority sources present
- **Merge multiple groups**: Extend grouping logic to merge 2+ existing groups (currently only groups ungrouped speakers)

### P2 Enhancements

- **Volume normalization when grouping**: Ask user if they want to normalize volumes or preserve individual levels
- **Undo grouping**: Add "Undo Last Group" button (requires state snapshot before grouping)
- **Animated badge transitions**: Smooth fade when audio source changes (requires real-time monitoring)
- **Grouping history**: Show "Recently grouped" suggestions based on past behavior

### Technical Debt

- **Complete SonosController async/await refactor**: Convert remaining callback-based methods (volume control, discovery, topology loading) to async/await
- **Extract coordinator selection to separate service**: `CoordinatorSelectionService` to reduce SonosController complexity
- **Add automated integration tests**: Mock Sonos API responses for CI/CD testing
- **Performance optimization**: Cache audio sources for 5-10 seconds to avoid redundant SOAP requests

---

## Appendix: File Reference

**Files Modified in This Fix**:

| File | Lines | Tickets | Description |
|------|-------|---------|-------------|
| `SonosController.swift` | 981-1417 | LINEIN-1, LINEIN-3 | Remove callbacks, add async detection and grouping |
| `SonosController.swift` | 233-409 | LINEIN-2 | Integrate source detection into topology |
| `SonosController.swift` | Top | LINEIN-3 | Add SonosError enum |
| `MenuBarContentView.swift` | 1347-1467 | LINEIN-4, LINEIN-7 | Update grouping UI to async/await |
| `MenuBarContentView.swift` | 548-671 | LINEIN-5 | Add audio source badges |
| `MenuBarContentView.swift` | 298-411 | LINEIN-6 | Add grouping helper text |
| `VolumeHUD.swift` | ~150 | LINEIN-4 | Add showSuccess() method |
| `Tests/CoordinatorSelectionTests.swift` | New file | LINEIN-9 | Unit tests for coordinator logic |

**Related Documentation**:
- `docs/sonos-api/groups.md`: Sonos grouping best practices
- `docs/sonos-api/upnp-local-api.md`: GetPositionInfo SOAP endpoint reference
- `ROADMAP.md` (line 31): Original bug description
- `CHANGELOG.md`: Update after PR merge

---

**Document End**

*This JIRA breakdown was created on 2025-10-03 by Austin Johnson for the Sonos Volume Controller project. For questions or clarifications, create a GitHub issue or comment on the tracking PR.*
