# Sonos Control API Overview

## Key Concepts

### Accounts, Households, and Groups

- A Sonos account includes product registration and contact information
- A household is a set of players on the same network
- Groups are collections of players that play synchronized audio
- Each household has a unique `householdId`
- Players can be moved between groups without interrupting playback

### Communication Basics

- Uses HTTP and JSON for communication
- Commands are sent to the Sonos cloud at `api.ws.sonos.com/control/api`
- Supports different targets:
  - Households
  - Groups
  - Sessions
  - Players

### Command Structure

Example command path:
```
https://api.ws.sonos.com/control/api/v1/groups/{groupId}/playback/content
```

### Key HTTP Headers

- `Authorization`: Bearer token
- `Content-Type`: application/json
- `User-Agent`: Recommended for tracking requests

### Response Types

- 200 OK: Successful command
- 400 Bad Request: Syntax errors
- 401 Unauthorized: Invalid credentials
- 499: Custom errors with detailed error codes

## Playback Control

### Loading Content

You can load content into a group's queue with:
- Content type (album, track, playlist)
- Service ID
- Object ID
- Optional playback actions (play/pause)
- Play modes (repeat, shuffle)

### Example Content Load Payload

```json
{
 "type": "ALBUM",
 "id": {
   "objectId": "spotify:album:2QgGoL5VSQhPHudTObS7zK",
   "serviceId": "12"
 },
 "playbackAction": "PLAY",
 "playModes": {
   "repeat": true
 }
}
```

## Best Practices

- Handle potential errors gracefully
- Provide a meaningful User-Agent
- Respect rate limits
- Use appropriate authentication
