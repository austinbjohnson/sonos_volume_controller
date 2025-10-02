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

_No enhancements currently planned. See "Planned Features" for major new functionality._

## Known Bugs

- **Individual speaker volume controls group volume**: When adjusting volume sliders for individual speakers within an expanded group view, it controls the entire group volume instead of the individual speaker volume. (TODO in MenuBarContentView.swift:1117)

- **Header visibility after speakers load**: After speakers are populated in the popover, the header section ("Active" status and speaker name) may not be visible until the popover is reopened or the view is interacted with. The Y coordinate of the header label becomes incorrect (~726px instead of ~40-60px) after population. Scroll-to-top commands don't fix the issue, suggesting a deeper layout coordinate system problem.

## Known Limitations

- **Line-in audio lost when grouping with stereo pairs**: When a stereo pair is playing line-in audio and grouped with another speaker, the line-in audio stops because the non-stereo-pair becomes coordinator and line-in sources are device-specific (cannot be shared). Workaround: Manually set the stereo pair with line-in as the coordinator in the Sonos app, or use streaming sources instead of line-in when grouping.
