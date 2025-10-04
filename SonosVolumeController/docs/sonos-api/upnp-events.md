# UPnP Event Subscriptions for Sonos Control

## Overview

UPnP (Universal Plug and Play) uses GENA (General Event Notification Architecture) to enable devices to notify control points of state changes. This is essential for real-time UI updates when Sonos speakers change playback state, group configuration, or volume.

**Key Concept**: Instead of polling devices repeatedly, we subscribe once and receive push notifications (NOTIFY callbacks) whenever state changes.

## GENA Protocol Basics

### SUBSCRIBE Request

To receive events, send an HTTP SUBSCRIBE request to the service's event endpoint.

**Request Format:**
```http
SUBSCRIBE /MediaRenderer/AVTransport/Event HTTP/1.1
HOST: 192.168.1.100:1400
CALLBACK: <http://192.168.1.50:3400/notify>
NT: upnp:event
TIMEOUT: Second-1800
```

**Headers:**
- `CALLBACK`: URL where device will send NOTIFY callbacks (your listener)
- `NT`: Notification Type, always `upnp:event` for subscriptions
- `TIMEOUT`: Subscription duration (e.g., `Second-1800` = 30 minutes)

**Response:**
```http
HTTP/1.1 200 OK
SID: uuid:RINCON_ABC123-1234
TIMEOUT: Second-1800
```

**Response Headers:**
- `SID`: Subscription ID (used to match NOTIFY callbacks and renew subscriptions)
- `TIMEOUT`: Actual timeout granted by device

### NOTIFY Callback

When state changes, the device sends an HTTP NOTIFY request to your callback URL.

**Callback Format:**
```http
NOTIFY /notify HTTP/1.1
HOST: 192.168.1.50:3400
SID: uuid:RINCON_ABC123-1234
SEQ: 0
NT: upnp:event
NTS: upnp:propchange
Content-Type: text/xml

<?xml version="1.0"?>
<e:propertyset xmlns:e="urn:schemas-upnp-org:event-1-0">
  <e:property>
    <LastChange>&lt;Event...&gt;</LastChange>
  </e:property>
</e:propertyset>
```

**Headers:**
- `SID`: Subscription ID (match to your subscription)
- `SEQ`: Sequence number (increments with each notification)
- `NTS`: Notification Sub Type, `upnp:propchange` for state changes

### Subscription Renewal

Subscriptions expire after the timeout period. Renew before expiration to maintain continuous updates.

**Renewal Request:**
```http
SUBSCRIBE /MediaRenderer/AVTransport/Event HTTP/1.1
HOST: 192.168.1.100:1400
SID: uuid:RINCON_ABC123-1234
TIMEOUT: Second-1800
```

**Best Practice**: Renew at **80% of timeout** to handle network delays (e.g., renew at 24 minutes for 30-minute timeout).

### Unsubscribe

To stop receiving events:

```http
UNSUBSCRIBE /MediaRenderer/AVTransport/Event HTTP/1.1
HOST: 192.168.1.100:1400
SID: uuid:RINCON_ABC123-1234
```

## Sonos Event Services

Sonos speakers expose three key services with eventing support:

### 1. ZoneGroupTopology Service

**Endpoint**: `/ZoneGroupTopology/Event`

**Purpose**: Notifies of group changes, coordinator handoffs, speaker additions/removals.

**Key Event Variable**: `ZoneGroupState` (HTML-encoded XML containing full topology)

**Use Cases**:
- Detect when speakers join/leave groups
- Update UI when groups are created/dissolved via Sonos app
- Handle coordinator role changes

**Implementation**: `UPnPEventListener.swift` - subscribed for all coordinators

### 2. AVTransport Service

**Endpoint**: `/MediaRenderer/AVTransport/Event`

**Purpose**: Notifies of playback state changes (play/pause/stop), track changes, metadata updates.

**Key Event Variable**: `LastChange` (XML containing transport state, track URI, metadata)

**Example LastChange XML:**
```xml
<Event xmlns="urn:schemas-upnp-org:metadata-1-0/AVT/">
  <InstanceID val="0">
    <TransportState val="PLAYING"/>
    <CurrentTrackURI val="x-sonos-spotify:..."/>
    <CurrentTrackMetaData val="&lt;DIDL-Lite...&gt;"/>
  </InstanceID>
</Event>
```

**Use Cases**:
- Update play/pause button states in UI
- Display "Now Playing" information
- Show track progress

**Implementation**: `UPnPEventListener.swift` + `SonosController.swift:783-832`

### 3. RenderingControl Service

**Endpoint**: `/MediaRenderer/RenderingControl/Event`

**Purpose**: Notifies of volume changes, mute state changes.

**Key Event Variables**: `Volume`, `Mute`

**Use Cases**:
- Sync volume slider when changed in Sonos app
- Update mute icon

**Status**: Not yet implemented in SonosVolumeController

## Subscription Strategies

### Strategy 1: All-Devices Subscription ⭐ (Current Implementation)

**Approach**: Subscribe to AVTransport events for **every discovered device**.

**Pros:**
- ✅ Simple and stable - no dynamic resubscription logic
- ✅ Handles group changes automatically (topology updates the UUID mapping)
- ✅ Captures events regardless of which device emits them
- ✅ No risk of missing events during coordinator handoffs

**Cons:**
- ❌ More network overhead (more subscriptions = more NOTIFY callbacks)
- ❌ Requires UUID mapping to route events to correct UI components

**Best For**: Applications where simplicity and reliability outweigh bandwidth concerns.

**When to Use**: 
- Dynamic group environments (frequent grouping/ungrouping)
- When you need guaranteed event delivery
- When network bandwidth is not constrained

### Strategy 2: Coordinator-Only Subscription

**Approach**: Subscribe only to group coordinators and ungrouped speakers.

**Pros:**
- ✅ Reduced network overhead (~50% fewer subscriptions in typical households)
- ✅ Events naturally match UI card identifiers (coordinators)
- ✅ No complex UUID mapping needed

**Cons:**
- ❌ Complex subscription management (subscribe/unsubscribe on group changes)
- ❌ Risk of missing events during coordinator handoffs
- ❌ Must handle topology changes reactively

**Best For**: Applications with stable group configurations and bandwidth constraints.

**When to Use**:
- Groups rarely change
- Network bandwidth is limited
- You have robust topology change handling

### Trade-Off Analysis

| Factor | All-Devices | Coordinator-Only |
|--------|-------------|------------------|
| Complexity | Low | High |
| Reliability | High | Medium |
| Network Overhead | Higher | Lower |
| Maintainability | Easy | Difficult |
| Bug Risk | Low | Medium-High |

**Recommendation**: Start with **All-Devices** subscription for reliability, then optimize to Coordinator-Only if performance becomes an issue.

## Implementation in SonosVolumeController

### Current Architecture

**UPnPEventListener.swift**: HTTP server (SwiftNIO) that receives NOTIFY callbacks
- Listens on dynamic port (system-assigned)
- Routes callbacks to appropriate event streams
- Handles subscription lifecycle (renewal, expiration)

**SonosController.swift**: Manages subscriptions and processes events
- Subscribes to all devices on discovery (`subscribeToAllDevicesForTransport()`)
- Maps UUIDs to route events to correct UI components
- Updates device cache with new state

**MenuBarContentView.swift**: UI updates based on notifications
- Listens for `SonosTransportStateDidChange` NotificationCenter events
- Finds card by UUID and refreshes now-playing info

### Event Flow

```
1. Sonos Speaker → NOTIFY callback → UPnPEventListener HTTP server
2. UPnPEventListener → Parse XML → Emit TransportEvent
3. SonosController → Handle event → Update device cache → Post notification
4. MenuBarContentView → Receive notification → Find card → Update UI
```

### UUID Mapping Strategy

**Problem**: Card identifiers may not match event UUIDs in certain scenarios:

1. **Stereo Pairs**: Satellite speaker is invisible, events come from satellite UUID but card uses visible speaker UUID
2. **Groups**: Member devices may emit events but cards use coordinator UUID

**Solution**: `satelliteToVisibleMap` dictionary maps event UUIDs to card UUIDs.

**Current Mapping** (SonosController.swift:363-373):
```swift
// Maps stereo pair satellites to visible speakers
satelliteToVisibleMap.removeAll()
for device in self.devices {
    if let pairPartnerUUID = pairPartners[device.uuid] {
        if invisibleUUIDs.contains(pairPartnerUUID) {
            satelliteToVisibleMap[pairPartnerUUID] = device.uuid
        }
    }
}
```

**Potential Enhancement**: Expand to include group member → coordinator mapping:
```swift
// Map ALL group members to their coordinators
for device in self.devices {
    if let coordinatorUUID = device.groupCoordinatorUUID,
       coordinatorUUID != device.uuid {
        memberToCoordinatorMap[device.uuid] = coordinatorUUID
    }
}
```

## Debugging Event Subscriptions

### Diagnostic Logging

When troubleshooting event issues, log:

1. **Subscription creation:**
   ```swift
   print("🎵 Subscribed to \(device.name) AVTransport")
   print("   Device UUID: \(device.uuid)")
   print("   SID: \(sid)")
   print("   Callback URL: \(callbackURL)")
   ```

2. **Event arrival:**
   ```swift
   print("🔍 Transport event received:")
   print("   Event UUID: \(deviceUUID)")
   print("   State: \(state)")
   print("   Mapped UUID: \(satelliteToVisibleMap[deviceUUID] ?? "none")")
   ```

3. **Card lookup:**
   ```swift
   print("   Card found: \(cardExists)")
   print("   Device in cache: \(deviceInCache)")
   ```

### Common Issues

**Symptom**: Events not arriving
- Check firewall (allow inbound on callback port)
- Verify callback URL uses correct local IP
- Confirm subscription didn't expire (check timeout)

**Symptom**: Events arrive but UI doesn't update
- UUID mismatch between event and card identifier
- NotificationCenter observer not registered
- Card lookup failing (wrong identifier search)

**Symptom**: Events arrive for some speakers but not others
- Check which devices actually emit events (coordinator vs. member behavior)
- Verify subscriptions created for all expected devices
- Look for subscription errors in logs

## References

- **UPnP Device Architecture 1.0**: https://www.upnp.org/specs/arch/UPnPDA10_20000613.htm
- **UPnP AVTransport Specification**: Open Connectivity Foundation
- **SoCo Python Library**: https://github.com/SoCo/SoCo (reference implementation)
- **Sonos API Documentation**: https://sonos.svrooij.io/ (unofficial)

## Related Files

- `UPnPEventListener.swift` - HTTP server and subscription lifecycle
- `SonosController.swift:634-663` - Subscription initialization
- `SonosController.swift:783-832` - Event processing
- `MenuBarContentView.swift:180-207` - UI updates from events

