---
date: 2025-10-04T13:35:00-07:00
researcher: Claude
git_commit: 3ea86d9ff90070c779ca85ffdadb0d7c5a36e948
branch: feature/playback-controls
repository: abj_volumeController
topic: "UI/UX Improvements for Playback Controls and Layout"
tags: [ui, ux, layout, playback-controls, now-playing, auto-sizing]
status: planning
last_updated: 2025-10-04
last_updated_by: Claude
type: implementation_strategy
---

# Handoff: UI/UX Improvements - Now Playing Display & Layout Fixes

## Task(s)

### Completed ✅
1. **Basic playback controls implementation** - Added play/pause, previous, and next buttons to menu bar UI (PR #54 merged)
   - Controls intelligently adapt based on audio source type
   - Smart routing to group coordinators
   - Real-time state updates via UPnP events
   - Proper spacing and layout between header and volume slider

### Work in Progress / Next Priority 🎯
The user has identified **three critical UI/UX improvements** that should be the top priority:

1. **Add Now Playing display near playback controls**
   - Show current track/source information for the selected speaker/group
   - Should be positioned near the playback controls (likely between controls and volume slider)
   - Include: track title, artist, album art thumbnail (already have infrastructure for this)
   - Reference existing now-playing data structure in `SonosController.swift:89-107` (NowPlayingInfo struct)

2. **Fix text layout overflow in speaker group cards**
   - **Issue**: Group names and metadata are being cut off (see image: "athroom + Bedroom" instead of "Bathroom + Bedroom")
   - **Location**: Group cards in speaker list show truncated text
   - Likely needs better text wrapping or increased card width
   - File: `MenuBarContentView.swift` - group card creation around line 1073

3. **Remove scrolling by making app expand to content**
   - **Current behavior**: Speaker list has internal scroll view with fixed height
   - **Desired behavior**: App window should expand vertically to show all speakers (as long as screen space available)
   - **Constraint**: Should still have max height if speaker list is very long
   - File: `MenuBarContentView.swift:419-444` - scroll view setup for speakers section

## Critical References

- **ROADMAP.md:152** - Recently resolved entry for playback controls feature (PR #54)
- **SonosController.swift:89-107** - NowPlayingInfo struct with track metadata
- **MenuBarContentView.swift:336-426** - Playback controls section setup
- **Current UI state image** - Shows text overflow in "Bathroom + Bedroom" group card

## Recent Changes

### Playback Controls Feature (PR #54)
- `SonosNetworkClient.swift:240-278` - Added pause(), stop(), next(), previous() transport methods
- `SonosController.swift:110-157` - Added .radio AudioSourceType case with supportsSkipping property
- `SonosController.swift:1480-1627` - Implemented high-level transport API (playSelected, pauseSelected, nextTrack, previousTrack)
- `SonosController.swift:482-519` - Made selectDevice() async to fetch audio source info on selection
- `MenuBarContentView.swift:52-56` - Added playback control button properties
- `MenuBarContentView.swift:336-445` - Created setupPlaybackControlsSection() with button layout
- `MenuBarContentView.swift:1847-1931` - Implemented button actions and state management
- `MenuBarContentView.swift:491-498` - Fixed volume section anchor to use second divider (after playback controls)

## Learnings

### Layout Architecture
1. **Divider-based anchoring**: Sections anchor to dividers (`NSBox` views) for vertical positioning. The volume section was initially anchoring to the first divider (after header) instead of the second divider (after playback controls), causing overlap.

2. **Fixed width container**: The entire popover uses a `FixedWidthView` (380px) defined at `MenuBarContentView.swift:4-26`. Content width is 364px (380 - 16px margins).

3. **Scroll view limitation**: The speakers section uses a fixed-height scroll view (`MenuBarContentView.swift:419-444`) with `scrollViewHeightConstraint` managing its size. This is what causes the internal scrolling.

### Now Playing Infrastructure
- Album art caching exists: `SonosController.swift:18` - `albumArtCache` NSCache
- Fetch method exists: `SonosController.swift:1631-1654` - `fetchAlbumArt(url:)` async method
- Real-time updates: Transport state changes trigger `SonosTransportStateDidChange` notifications
- Data is already displayed in speaker cards: `MenuBarContentView.swift:1373-1423` - `updateCardWithNowPlaying()` method

### Audio Source Types
- `.streaming` - Supports skip (queue, Spotify, etc.)
- `.radio` - Play/pause only (no skip support)
- `.lineIn` / `.tv` - Play/pause only
- `.idle` - All controls disabled
- `.grouped` - Following another speaker

## Artifacts

### Created Files
- `thoughts/shared/handoffs/general/2025-10-04_13-35-00_ui-ux-improvements.md` - This handoff document

### Modified Files (PR #54)
- `SonosVolumeController/Sources/Infrastructure/SonosNetworkClient.swift` - Transport control methods
- `SonosVolumeController/Sources/SonosController.swift` - Audio source detection, transport API, async device selection
- `SonosVolumeController/Sources/MenuBarContentView.swift` - Playback controls UI, state management, layout fixes
- `CHANGELOG.md` - Added playback controls feature entry
- `ROADMAP.md` - Moved item to "Recently Resolved" section

## Action Items & Next Steps

### Priority 1: Add Now Playing Display 🎵
**Goal**: Show current track info for selected speaker/group near playback controls

**Implementation approach**:
1. Add new section between playback controls and volume slider
2. Create `setupNowPlayingSection()` method in `MenuBarContentView.swift`
3. UI components needed:
   - Album art thumbnail (40x40pt, 4pt corner radius) - reuse pattern from `MenuBarContentView.swift:1387-1406`
   - Track title label (bold, 13-14pt)
   - Artist/metadata label (regular, 11-12pt, secondary color)
   - Source badge (small colored dot or icon)
4. Update on:
   - Device selection changes
   - Transport state changes (already have notification observer at line 187)
   - Now playing metadata updates
5. Handle states:
   - Streaming: Show track + artist + album art
   - Radio: Show station name
   - Line-in/TV: Show source type
   - Idle: Hide or show "Not playing"

**Key methods to reference**:
- `SonosController.swift:836-857` - `parseNowPlayingFromMetadata()` 
- `SonosController.swift:1559-1608` - `parseNowPlayingInfo()` with album art URL handling
- `MenuBarContentView.swift:1373-1423` - Existing `updateCardWithNowPlaying()` pattern

### Priority 2: Fix Group Card Text Overflow 📝
**Goal**: Prevent group names and metadata from being cut off

**Current issue**: 
- Image shows "athroom + Bedroom" (missing "B") and "Sleeping • Foxwarren...auf" (truncated)
- Group cards appear to have insufficient width or text constraints

**Investigation needed**:
1. Check group card width constraints in `createGroupCard()` around line 1073
2. Review text field setup - likely using single-line with truncation
3. Compare to individual speaker cards which may handle text better

**Potential solutions**:
- Increase card width (but constrained by 364px container width)
- Use wrapping text labels instead of single-line truncation
- Reduce font size for long names
- Add ellipsis at end instead of middle of text
- Show tooltip on hover with full text

**Files to examine**:
- `MenuBarContentView.swift:1071-1100` - `createGroupCard()` method
- `MenuBarContentView.swift:548-671` - May need similar fixes for individual cards (ROADMAP.md:82 mentions this issue)

### Priority 3: Remove Scroll / Dynamic Height 📏
**Goal**: Expand popover vertically to fit all speakers instead of internal scrolling

**Current implementation**:
- `MenuBarContentView.swift:419` - `NSScrollView` for speakers section
- `MenuBarContentView.swift:54` - `scrollViewHeightConstraint` manages fixed height
- `MenuBarContentView.swift:520-546` - Height calculation logic exists

**Implementation approach**:
1. Remove or relax scroll view height constraint
2. Let `NSStackView` (speakerCardsContainer) drive height naturally
3. Add maximum height constraint (e.g., 70% of screen height)
4. Update popover sizing to accommodate dynamic content
5. Test with varying speaker counts (1, 5, 10+ speakers)

**Considerations**:
- Need max height for users with many speakers (10+)
- Should still show scroll if content exceeds screen space
- May need to adjust `MenuBarPopover.swift` configuration
- Consider impact on `containerView` sizing at line 79

**Files to modify**:
- `MenuBarContentView.swift:419-444` - Scroll view and constraint setup
- `MenuBarContentView.swift:79-83` - Container view initial sizing
- `MenuBarPopover.swift` - May need adjustments to popover behavior

## Other Notes

### Current Layout Structure
The menu bar popover is organized as follows (top to bottom):
1. **Header Section** (lines 242-327)
   - Status dot + label
   - Speaker/group name
   - Refresh and power buttons
   - Divider

2. **Playback Controls Section** (lines 336-426) ✅ COMPLETE
   - Previous, play/pause, next buttons (48pt, centered)
   - Divider

3. **Volume Section** (lines 447-517)
   - Volume type label
   - Volume icon + slider + percentage
   - Divider

4. **Speakers Section** (lines 519-601)
   - Permission banner (collapsible)
   - Welcome banner (collapsible)
   - Scroll view with speaker/group cards ⚠️ NEEDS FIXING
   - Group/Ungroup buttons

5. **Trigger Device Section** (lines 603-651)
6. **Actions Section** (lines 653-707)

### Code Organization Tips
- `@MainActor` required for UI updates
- Use `Task { @MainActor in ... }` for async UI updates from actor-isolated methods
- `updateCachedValues()` must be called after modifying devices/groups arrays
- Notification observers: Volume changes (line 115), device discovery (line 124), transport state (line 158)

### Testing Scenarios
When implementing changes, test with:
- Single speaker (ungrouped)
- Multi-speaker group (2-3 members)
- Stereo pair
- Line-in source
- Radio stream
- Streaming music (Spotify, Apple Music)
- Idle speaker (nothing playing)
- Many speakers (10+) to test dynamic height

### Related ROADMAP Items
- **P2:82** - "Long speaker name truncation" - related to group card text issue
- **P2:91** - "Now playing metadata refresh on user interactions" - may inform now-playing display implementation
- **P0:29** - "Non-Apple Music sources not updating UI" - be aware when implementing now-playing display

### Build & Run Commands
```bash
cd SonosVolumeController
swift build                    # Compile
swift run                      # Run in debug mode
./build-app.sh --install       # Build and install to /Applications
pkill SonosVolumeController    # Kill running instance before testing
```

### UI Design Guidelines (from repo rules)
- Four-space indentation
- SF Symbols for icons
- Glass effect containers (`NSGlassEffectView`)
- Subtle animations for state changes
- 44pt minimum tap targets (we use 48pt for playback controls)
- Color-coded badges (green=streaming, blue=line-in/TV, teal=radio, gray=idle)


