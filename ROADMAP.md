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

## Planned Features

- **Real-time group topology updates**: Subscribe to Sonos topology events to automatically refresh group information when changed from another app (Sonos app, Alexa, etc.). Follow Sonos best practices for ZoneGroupTopology event subscription and handling `groupCoordinatorChanged` events.

- **Trigger device cache management**: Add ability to refresh trigger sources and cache them persistently. Users should be able to manually delete cached devices that are no longer relevant (similar to WiFi network history - devices remain in cache even when not currently available, but can be manually removed).

- **Merge multiple groups**: Allow merging two or more existing groups into a single larger group. Currently can only create new groups from ungrouped speakers.

## Enhancements

- **Simplify settings window**: Remove tabs for trigger source and speaker selection from the full settings window. Both can be handled directly in the menu bar popover, making a separate tabbed preferences window unnecessary.

- **Simplify trigger source UI**: Replace radio button list with read-only info display showing the current trigger device. Now that "Any Device" is the default and works well, the selection UI could be streamlined to just show what's active (with option to change in preferences if needed).

## Known Bugs

- **Individual speaker volume controls group volume**: When adjusting volume sliders for individual speakers within an expanded group view, it controls the entire group volume instead of the individual speaker volume. (TODO in MenuBarContentView.swift:1117)

- **Speakers list spacing**: Adjust spacing/layout in the speakers section of the menu bar popover

## Known Limitations

- **Line-in audio lost when grouping with stereo pairs**: When a stereo pair is playing line-in audio and grouped with another speaker, the line-in audio stops because the non-stereo-pair becomes coordinator and line-in sources are device-specific (cannot be shared). Workaround: Manually set the stereo pair with line-in as the coordinator in the Sonos app, or use streaming sources instead of line-in when grouping.
