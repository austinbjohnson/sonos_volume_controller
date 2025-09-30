# Feature Roadmap

## App Store Readiness
- [ ] Build as .app bundle
- [ ] Code signing
- [ ] Sandboxing configuration
- [ ] App Store submission

## Completed Improvements
- ✅ Custom Sonos speaker icon for menu bar (replaces "S" text)
- ✅ Exit/quit icon updated to "person leaving" (SF Symbol: figure.walk.departure)

## Future Ideas
- grouping speakers with default: ultrathink on this, make it so i can group speakers easily, my default speaker as set in preferences should be the audio source when grouping other speakers. make sure to lookup 2025 office sonos documentation 09
- when the app first loads, and the default speaker is confirmed as part of the current topology, update the current volume to match the default speaker, if the default speaker is unavailable, leave blank
- BUG sometimes there are missing speakers in the list and I don't know why, do we need a longer timeout? or multiple pings? 
- BUG: when i refresh the speakers in the settings window it updates the options in the menu bar, but the settings drop down doesn't update.
- Enhancement: when i load the app for the first time the user should be prompted to enable the required accessiblity settings so i don't have to dig for them 
- Enhancement: when i try to change the volume but i am not connected to the set trigger audio device, i should see a notice that looks just like the volume changer that appears when i successfully do change the volume so that I know why it is not working 