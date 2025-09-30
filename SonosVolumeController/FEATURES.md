# Feature Roadmap

## App Store Readiness
- [x] Build as .app bundle
- [x] Code signing
- [ ] Sandboxing configuration
- [ ] App Store submission

## Features
- **Speaker grouping functionality**: Make it easy to group speakers with the default speaker as the audio source. The default speaker (as set in preferences) should be the coordinator when grouping other speakers. Lookup 2025 Sonos office documentation for implementation details.
- **Trigger device cache management**: Add ability to refresh trigger sources and cache them persistently. Users should be able to manually delete cached devices that are no longer relevant (similar to WiFi network history - devices remain in cache even when not currently available, but can be manually removed).

## Enhancements
- **Simplify trigger source UI**: Replace radio button list with read-only info display showing the current trigger device. Now that "Any Device" is the default and works well, the selection UI could be streamlined to just show what's active (with option to change in preferences if needed)

## Bugs
- **Speakers list spacing**: Adjust spacing/layout in the speakers section of the menu bar popover

## Completed Improvements
- ✅ Custom Sonos speaker icon for menu bar (replaces "S" text)
- ✅ Exit/quit icon updated to "person leaving" (SF Symbol: figure.walk.departure)
- ✅ Settings dropdown now updates when refreshing Sonos devices (PR #13)
- ✅ Improved device discovery reliability with multiple SSDP packets and longer timeouts (PR #14)
- ✅ Added loading indicator UI when discovering speakers (PR #14)
- ✅ Development workflow documentation (DEVELOPMENT.md)
- ✅ Volume slider syncs with default speaker on app launch (PR #15)
- ✅ Volume slider disabled with "—" until actual volume loads (PR #15)
- ✅ Wrong device HUD notification when volume hotkeys pressed on wrong audio device (PR #16)
- ✅ Menu bar popover auto-close using global event monitor (PR #17)
- ✅ Smooth volume HUD transitions without flicker on rapid hotkey presses (PR #18)
- ✅ Accessibility permissions prompt on first launch with direct link to System Settings (PR #19)
- ✅ Changed default hotkeys to Cmd+Shift+9/0 for better ergonomics (PR #20)
- ✅ Fixed hotkeys not working in installed app - reverted to F11/F12 defaults, fixed CGEventFlags conversion, added network entitlements, improved permission flow with auto-restart (PR #22)
- ✅ First launch onboarding with welcome banner - automatically shows popover when no speaker is selected, plus shows HUD notification when user tries to use hotkeys without a speaker selected (PR #24)
- ✅ Trigger device picker in menu bar - select which audio device activates Sonos hotkeys, defaults to "Any Device" for universal compatibility (PR #25)
- ✅ Hierarchical group UI with expandable member controls - groups display as primary cards with drill-down capability to control individual speakers within groups (PR #27) 