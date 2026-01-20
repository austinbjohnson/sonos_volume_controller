# Menu Bar UX Overhaul (Issue #116)

## Goal
Create a calmer, clearer menu bar experience by prioritizing the primary playback target and reducing visual noise, while keeping grouping/selection actions obvious and reliable.

## Primary Problems (Observed)
- Header content clips when new rows (e.g., Last updated) are added.
- Multiple dots/badges compete for attention without clear meaning.
- Group cards + member sliders visually fight with primary transport/volume controls.
- Selection and grouping affordances feel ambiguous.

## Direction (Option A: Focus-first layout)
Make "Now Playing + Transport + Primary Volume" the hero area and push the speaker list down with reduced chrome.

### Layout Hierarchy
1) Header
- Row 1: Status dot + Active/Standby + Last updated (small, muted).
- Row 2: Primary target name (large, single focus).
- Right-aligned icon cluster: Refresh + Power.

2) Transport controls (large, centered)

3) Now Playing card (single, bold)
- Album art + title + artist.
- Only show one source tag if it changes behavior (e.g., Line-In).

4) Primary Volume
- Single slider and label.
- If group, add a small "Group Volume" tag under label.

5) Speakers list (secondary)
- Default collapsed groups with a clear expand affordance.
- Remove per-group colored dots unless critical status is being conveyed.
- Selection = one clear highlight style (no extra dot).

6) Grouping actions
- Place "Group" / "Ungroup" buttons in a subdued strip below list.
- Buttons enabled only when selection is valid.

## Visual Simplification Rules
- Prefer one indicator per row; avoid stacking dots + badges + highlight.
- Use subtler text color for metadata (Last updated, Group Volume, etc.).
- Keep member sliders visually lighter than the primary volume control.

## Interaction Model
- Single click selects speaker or group (focus target).
- Grouping selection uses checkboxes only in a grouping state (or on hover if no mode is added).
- Group member sliders remain in expanded view only.

## Success Criteria
- Header never clips at default size.
- Primary focus target is obvious in <1s glance.
- Users can select, play, and adjust volume without ambiguous clicks.
- Group list feels secondary and calmer.

## Open Questions
- Do we introduce an explicit "Manage Groups" mode, or keep hover-only checkboxes?
- How aggressive should we be with removing source badges in the list?
