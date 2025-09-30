# Sonos UPnP/SOAP Local API

## Overview

Sonos speakers expose a local UPnP (Universal Plug and Play) API that allows programmatic control through SOAP (Simple Object Access Protocol) requests on the local network. Every Sonos speaker has several SOAP services, each with one or more actions you can call.

**Important**: This is the API we use in SonosVolumeController - direct device communication without cloud dependencies.

## Network Communication

- **HTTP Port**: 1400
- **SSDP Port**: 1900 (UDP for discovery)
- **Base URL**: `http://{speaker-ip}:1400`

## Key Services

### 1. ZoneGroupTopology Service

**Endpoint**: `/ZoneGroupTopology/Control`

**Purpose**: Handles network topology, group information, diagnostics

**Key Actions**:
- `GetZoneGroupState` - Returns complete group topology XML
- `GetZoneGroupAttributes` - Get group attributes
- `RegisterMobileDevice` - Register for notifications

**SOAP Action Header**: `"urn:schemas-upnp-org:service:ZoneGroupTopology:1#{ActionName}"`

**Example GetZoneGroupState Request**:
```xml
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
            s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:GetZoneGroupState xmlns:u="urn:schemas-upnp-org:service:ZoneGroupTopology:1">
    </u:GetZoneGroupState>
  </s:Body>
</s:Envelope>
```

**Response Format**: Contains `<ZoneGroupState>` with HTML-encoded XML containing:
- `<ZoneGroup>` elements with `Coordinator` attribute
- `<ZoneGroupMember>` elements with:
  - `UUID` - unique device identifier
  - `Invisible` - "1" for satellite speakers in stereo pairs
  - `ChannelMapSet` - stereo pair configuration
  - `Location` - device URL

### 2. AVTransport Service

**Endpoint**: `/MediaRenderer/AVTransport/Control`

**Purpose**: Transport control (play, pause, seek, queue management)

**Key Actions**:
- `AddURIToQueue` - Add songs to queue
- `BecomeGroupCoordinatorAndSource` - Leave group (ungroup)
- `DelegateGroupCoordinationTo` - Transfer coordinator role
- `SetAVTransportURI` - Set current playback URI
- `Play` - Start playback
- `Pause` - Pause playback
- `Stop` - Stop playback
- `Next` - Skip to next track
- `Previous` - Go to previous track

**SOAP Action Header**: `"urn:schemas-upnp-org:service:AVTransport:1#{ActionName}"`

### 3. RenderingControl Service

**Endpoint**: `/MediaRenderer/RenderingControl/Control`

**Purpose**: Individual speaker volume and audio settings

**Key Actions**:
- `GetVolume` - Get current volume (0-100)
- `SetVolume` - Set absolute volume level
- `GetMute` - Get mute state (0 or 1)
- `SetMute` - Set mute state

**SOAP Action Header**: `"urn:schemas-upnp-org:service:RenderingControl:1#{ActionName}"`

**Example SetVolume Request**:
```xml
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
            s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:SetVolume xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1">
      <InstanceID>0</InstanceID>
      <Channel>Master</Channel>
      <DesiredVolume>50</DesiredVolume>
    </u:SetVolume>
  </s:Body>
</s:Envelope>
```

### 4. GroupRenderingControl Service

**Endpoint**: `/MediaRenderer/GroupRenderingControl/Control` (on coordinator)

**Purpose**: Group-wide volume control

**Key Actions**:
- `GetGroupVolume` - Get average group volume
- `SetGroupVolume` - Set proportional group volume
- `SetRelativeGroupVolume` - Adjust by delta (+/-)
- `GetGroupMute` - Get group mute state
- `SetGroupMute` - Mute/unmute entire group

**SOAP Action Header**: `"urn:schemas-upnp-org:service:GroupRenderingControl:1#{ActionName}"`

**Important**: Group volume commands must be sent to the **group coordinator**, not individual members.

## Group Management via UPnP

### Creating Groups

To create a group, use AVTransport service:

**Action**: `SetAVTransportURI` on the desired coordinator with special URI

**URI Format**: `x-rincon:{COORDINATOR_UUID}`

This makes a speaker join the group of the coordinator.

### Ungrouping

**Action**: `BecomeGroupCoordinatorAndSource` on the speaker to ungroup

This removes the speaker from its current group and makes it standalone.

### Group Coordinator

- One speaker in each group is the **coordinator**
- The coordinator manages playback for the entire group
- Group volume commands must go to the coordinator
- Individual volume commands can go to any member

## Volume Control Patterns

### Individual Speaker Volume
```
POST http://{speaker-ip}:1400/MediaRenderer/RenderingControl/Control
Action: SetVolume
Parameters: InstanceID=0, Channel=Master, DesiredVolume={0-100}
```

### Group Volume (Proportional)
```
POST http://{coordinator-ip}:1400/MediaRenderer/GroupRenderingControl/Control
Action: SetGroupVolume
Parameters: InstanceID=0, DesiredVolume={0-100}
```

This adjusts all group members proportionally, maintaining relative volume differences.

### Group Volume (Relative)
```
POST http://{coordinator-ip}:1400/MediaRenderer/GroupRenderingControl/Control
Action: SetRelativeGroupVolume
Parameters: InstanceID=0, Adjustment={-100 to +100}
```

This is ideal for volume up/down buttons.

## Data Types

- **Booleans**: Represented as `1` (true) or `0` (false)
- **Volume**: Integer 0-100
- **UUIDs**: Format `RINCON_XXXXXXXXXXXX`

## Discovery

**SSDP Multicast**: 239.255.255.250:1900

**M-SEARCH Request**:
```
M-SEARCH * HTTP/1.1
HOST: 239.255.255.250:1900
MAN: "ssdp:discover"
MX: 3
ST: urn:schemas-upnp-org:device:ZonePlayer:1
```

**Device Description**: `http://{speaker-ip}:1400/xml/device_description.xml`

## Implementation Notes

1. **Current Implementation** (SonosController.swift):
   - Uses SSDP discovery ✓
   - Fetches ZoneGroupTopology ✓
   - Parses group coordinator info ✓
   - Handles stereo pairs ✓
   - Individual volume control via RenderingControl ✓

2. **To Add for Full Grouping**:
   - Group creation via SetAVTransportURI
   - Ungrouping via BecomeGroupCoordinatorAndSource
   - Group volume via GroupRenderingControl service
   - Track full group membership (currently only tracks coordinator UUID)
   - UI for visualizing and modifying groups

## References

- SoCo Python library: https://github.com/SoCo/SoCo
- Unofficial API docs: https://sonos.svrooij.io/
- UPnP specs: Open Connectivity Foundation MediaServer:4, MediaRenderer:3
