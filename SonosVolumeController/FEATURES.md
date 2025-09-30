# Feature Roadmap

## App Store Readiness
- [x] Build as .app bundle
- [x] Code signing
- [ ] Sandboxing configuration
- [ ] App Store submission

## Features
- **Speaker grouping functionality**: Make it easy to group speakers with the default speaker as the audio source. The default speaker (as set in preferences) should be the coordinator when grouping other speakers. Lookup 2025 Sonos office documentation for implementation details.

## Enhancements
- None currently

## Bugs
- None currently

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
- ✅ First launch onboarding - automatically shows popover with welcome banner when no speaker is selected, guiding users to select their default speaker (PR #TBD) 