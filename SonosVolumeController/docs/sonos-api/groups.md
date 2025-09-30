# Sonos Groups: Comprehensive Guide

## Overview

Sonos groups represent a core feature of the Sonos sound system, allowing listeners to synchronize music playback across multiple speakers in different rooms. The groups functionality is fundamental to the Sonos experience.

## Key Concepts

### Group Characteristics

- A group can include one or more Sonos speakers
- Groups allow synchronized playback across multiple rooms
- Groups can be dynamically created, modified, and dissolved

### Group Management Requirements

1. **Accurate Group Tracking**
   - Apps must keep group information up-to-date in real-time
   - Groups can change in other apps or integrations
   - Continuous tracking is essential for a seamless user experience

2. **Group Discovery**
   - Apps should display current Sonos speaker groupings
   - Allow users to select and interact with groups
   - Highlight selected groups visually

### Group Coordination

The system supports dynamic group changes through events like `groupCoordinatorChanged`, which can signal:
- Group status updates
- Group dissolution
- Speaker movement between groups

## Technical Implementation

### API Endpoints for Group Management

- `getGroups`: Retrieve current household groups
- `createGroup`: Establish new speaker groups
- `modifyGroupMembers`: Add or remove speakers from groups
- `setGroupMembers`: Completely redefine group composition

### Best Practices

- Continuously refresh group information
- Handle group changes gracefully
- Provide clear visual feedback on group status
- Support real-time group modifications

## User Experience Considerations

- Groups should feel "magical" and predictable
- Seamless music continuity across rooms
- Intuitive group creation and management
- Minimal user intervention required
