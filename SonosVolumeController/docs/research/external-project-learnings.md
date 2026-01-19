# External Project Learnings

## CodexBar
Learnings:
- Encode status directly in the menu bar icon (dim on stale/error, overlays for incidents).
- Provide a manual refresh action alongside background refresh cadence.
- Offer a "merge icons" mode to reduce menu bar clutter when many items exist.
- Separate short-term vs. long-term usage with clear reset countdowns to set expectations.
- Keep advanced settings available but guarded with clear explanations and safe defaults.
- Publish actionable troubleshooting steps for permissions and system-level issues.

Suggested applications:
- Add stale/error state indicators to the menu bar icon and an in-menu status row.
- Add an explicit manual refresh button and "last updated" label for topology/now-playing.
- Add short, plain-language permission copy that explains scope and opt-out.

## sonoscli
Learnings:
- Resolve control commands to the group coordinator by default, even when a member is targeted.
- Expose explicit source switching (line-in, TV) as first-class actions to reduce ambiguity.
- Provide scene/preset concepts for grouping + per-room volume/mute.
- Offer a live watch mode for real-time transport/volume updates during debugging.
- Favor consistent, scriptable output formats and a global debug flag.
- Improve grouping ergonomics with clear "join/unjoin/party/solo/dissolve" flows.

Suggested applications:
- Ensure transport/playback routes to coordinators while keeping member volume per-speaker.
- Add quick actions for line-in/TV source selection in the menu bar.
- Consider lightweight "scene" presets for common group/volume setups.
