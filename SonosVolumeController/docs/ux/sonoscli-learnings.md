# sonoscli learnings for Sonos Volume Controller

Source repo: https://github.com/steipete/sonoscli (commit 8b14e2130f5674f1c4f2bd5ebf07c4efc1ac58d7)
Scope reviewed:
- README.md
- docs/spec.md
- docs/improvements.md
- docs/testing.md
- internal/sonos/discover.go
- internal/sonos/topology.go
- internal/sonos/group_rendering.go
- internal/cli/group.go

Intent: capture UX and code patterns worth adapting (not copying) for Sonos Volume Controller.

## UX and product patterns worth adapting

### Reliability-first discovery
- Discovery prioritizes topology-based device lists over raw SSDP responses to avoid partial results.
- Clear fallback strategy: SSDP search -> topology via candidates -> subnet scan -> direct device description parse.
- Discovery includes an "include invisible" option for advanced diagnostics and bonded devices.

### Coordinator-aware actions
- Commands always resolve to the group coordinator for transport and queue operations.
- Grouping actions deliberately target the joining speaker, not the coordinator, to match Sonos semantics.
- This reduces user confusion because actions "just work" even when a room is grouped.

### Scriptable output and explicit formats
- Consistent output formats (plain/json/tsv) make it easy to use in automation.
- Human-readable output stays concise, while JSON is structurally consistent across commands.

### Live event streaming
- "Watch" mode subscribes to AVTransport + RenderingControl eventing and prints changes in real time.
- Helps validate that state updates are flowing and makes debugging a first-class experience.

### Scenes as repeatable states
- Scenes capture grouping and per-room volume/mute, not just a single room.
- This is a strong fit for menu bar UX (e.g., "Morning", "Movie") as quick presets.

### User-friendly resolution
- Fuzzy name matching with ambiguity suggestions provides a forgiving UX for command input.

## Code and architecture patterns worth adapting

### Topology-first discovery algorithm
- Use topology as the source of truth for room list; SSDP is only a bootstrap step.
- Query multiple candidate devices and prefer the largest topology snapshot (best coverage).
- Use timeouts per phase with clear logging and fallback sequencing.

### Speaker identification logic
- Accept both room name and IP; if input looks like an IP, treat it as such.
- Case-insensitive and substring matching to resolve user input.
- Ambiguous matches return suggestions to resolve uncertainty.

### Group volume and mute semantics
- Group volume changes call SnapshotGroupVolume before SetGroupVolume to align with Sonos expectations.
- Group mute uses GroupRenderingControl, not individual speaker rendering, for consistency.

### Service boundaries
- Separate internal packages for CLI parsing, Sonos protocol, and service-specific logic.
- Keeps protocol handling testable and removes UI concerns from networking concerns.

### Documentation as a spec
- A living spec (docs/spec.md) captures commands, protocols, and non-goals in one place.
- A detailed manual test plan (docs/testing.md) makes regressions reproducible even without automated UI tests.

## Candidate issue seeds for Sonos Volume Controller

1. Discovery flow should prefer topology responses and fall back to subnet scan if SSDP is incomplete.
2. Use coordinator-aware routing for transport and queue actions; only grouping commands target the joining speaker.
3. Add fuzzy speaker matching (case-insensitive + substring) with ambiguity suggestions in UI search.
4. Provide a "watch" style diagnostic UI to stream live AVTransport/RenderingControl changes.
5. Add Scenes (grouping + volume/mute) as first-class presets in the menu bar.
6. Expose an "Include invisible/bonded" advanced toggle for troubleshooting.
7. Use SnapshotGroupVolume before group volume changes to reduce Sonos errors.
8. Adopt a single source of truth for topology to avoid conflicting device lists.
9. Add a living spec and manual test plan section in docs to align contributors.

## Notes for adaptation
- sonoscli is CLI-first, but its coordinator awareness and topology-first discovery map cleanly to our menu bar UX.
- The fuzzy matching logic can inform a typeahead search in the speaker list.
- The test plan structure is useful for our manual testing guidelines (swift run + hotkey workflow).

