# Feature Roadmap

## App Store Readiness
- [x] Build as .app bundle
- [x] Code signing
- [ ] Sandboxing configuration
- [ ] App Store submission

## Completed Improvements
- ✅ Custom Sonos speaker icon for menu bar (replaces "S" text)
- ✅ Exit/quit icon updated to "person leaving" (SF Symbol: figure.walk.departure)
- ✅ Settings dropdown now updates when refreshing Sonos devices (PR #13)
- ✅ Improved device discovery reliability with multiple SSDP packets and longer timeouts (PR #14)
- ✅ Added loading indicator UI when discovering speakers (PR #14)
- ✅ Development workflow documentation (DEVELOPMENT.md)
- ✅ Volume slider syncs with default speaker on app launch (PR #15)
- ✅ Volume slider disabled with "—" until actual volume loads (PR #15)

## Future Ideas
- grouping speakers with default: ultrathink on this, make it so i can group speakers easily, my default speaker as set in preferences should be the audio source when grouping other speakers. make sure to lookup 2025 office sonos documentation 09
- Enhancement: when i load the app for the first time the user should be prompted to enable the required accessiblity settings so i don't have to dig for them
- Enhancement: when i try to change the volume but i am not connected to the set trigger audio device, i should see a notice that looks just like the volume changer that appears when i successfully do change the volume so that I know why it is not working 