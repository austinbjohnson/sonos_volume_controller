import Foundation
import Network

class SonosController: @unchecked Sendable {
    private let settings: AppSettings
    private var devices: [SonosDevice] = []
    private var groups: [SonosGroup] = []
    private var _selectedDevice: SonosDevice?
    private var selectedGroup: SonosGroup?

    // Topology cache - persists during app session
    private var topologyCache: [String: String] = [:]  // UUID -> Coordinator UUID
    private var hasLoadedTopology = false

    // Expose selected device
    var selectedDevice: SonosDevice? {
        return _selectedDevice
    }

    // Expose devices for menu population
    var discoveredDevices: [SonosDevice] {
        return devices
    }

    // Expose groups for UI
    var discoveredGroups: [SonosGroup] {
        return groups
    }

    struct SonosDevice {
        let name: String
        let ipAddress: String
        let uuid: String
        let isGroupCoordinator: Bool      // True if this is the group coordinator
        let groupCoordinatorUUID: String? // UUID of the group coordinator (for grouped playback)
        let channelMapSet: String?        // Present if part of a stereo pair
        let pairPartnerUUID: String?      // UUID of the other speaker in the stereo pair
    }

    struct SonosGroup {
        let id: String                    // Group ID (coordinator UUID)
        let coordinatorUUID: String       // UUID of the coordinator
        let coordinator: SonosDevice      // The coordinator device
        let members: [SonosDevice]        // All members including coordinator
        var groupVolume: Int?             // Cached group volume

        var name: String {
            // Generate group name based on members
            if members.count == 1 {
                return coordinator.name
            } else {
                // Join all member names: "Living Room + Kitchen Move"
                return members.map { $0.name }.joined(separator: " + ")
            }
        }

        var displayName: String {
            // More detailed display name
            if members.count == 1 {
                return coordinator.name
            } else {
                let otherNames = members.filter { $0.uuid != coordinatorUUID }.map { $0.name }
                if otherNames.count <= 2 {
                    return "\(coordinator.name) + " + otherNames.joined(separator: " + ")
                } else {
                    return "\(coordinator.name) + \(otherNames.count) speakers"
                }
            }
        }

        func isMember(_ device: SonosDevice) -> Bool {
            return members.contains { $0.uuid == device.uuid }
        }
    }

    init(settings: AppSettings) {
        self.settings = settings
    }

    func discoverDevices(forceRefreshTopology: Bool = false, completion: (@Sendable () -> Void)? = nil) {
        print("Discovering Sonos devices...")

        // Notify UI that discovery is starting
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: NSNotification.Name("SonosDiscoveryStarted"), object: nil)
        }

        // Clear cache if forced refresh is requested
        if forceRefreshTopology {
            print("Clearing topology cache for fresh discovery")
            topologyCache.removeAll()
            hasLoadedTopology = false
        }

        // Use SSDP (Simple Service Discovery Protocol) to find Sonos devices
        let queue = DispatchQueue(label: "sonos.discovery")

        queue.async { [weak self] in
            self?.performSSDPDiscovery(completion: completion)
        }
    }

    private func performSSDPDiscovery(completion: (@Sendable () -> Void)? = nil) {
        // Increased MX from 1 to 3 to give devices more time to respond
        let ssdpMessage = """
        M-SEARCH * HTTP/1.1\r
        HOST: 239.255.255.250:1900\r
        MAN: "ssdp:discover"\r
        MX: 3\r
        ST: urn:schemas-upnp-org:device:ZonePlayer:1\r
        \r

        """

        do {
            let socket = try Socket()

            // Send multiple discovery packets to catch devices that might miss the first one
            print("📡 Sending discovery packet 1/3...")
            try socket.send(ssdpMessage, to: "239.255.255.250", port: 1900)

            Thread.sleep(forTimeInterval: 0.5)

            print("📡 Sending discovery packet 2/3...")
            try socket.send(ssdpMessage, to: "239.255.255.250", port: 1900)

            Thread.sleep(forTimeInterval: 0.5)

            print("📡 Sending discovery packet 3/3...")
            try socket.send(ssdpMessage, to: "239.255.255.250", port: 1900)

            // Listen for responses with extended timeout (increased from 3 to 5 seconds)
            let timeout = DispatchTime.now() + .seconds(5)
            var foundDevices: [SonosDevice] = []

            print("👂 Listening for responses...")
            while DispatchTime.now() < timeout {
                if let response = try? socket.receive(timeout: 1.0) {
                    if let device = parseSSDPResponse(response.data, from: response.address) {
                        foundDevices.append(device)
                    }
                }
            }

            DispatchQueue.main.async {
                // Deduplicate devices by UUID (not name, since stereo pairs have duplicate names)
                var uniqueDevices: [SonosDevice] = []
                var seenUUIDs = Set<String>()

                for device in foundDevices {
                    if !seenUUIDs.contains(device.uuid) {
                        uniqueDevices.append(device)
                        seenUUIDs.insert(device.uuid)
                    }
                }

                // Apply cached topology if available (but we'll refresh it anyway)
                // Just keep the devices as-is, topology will be updated in updateGroupTopology()

                self.devices = uniqueDevices
                print("Found \(foundDevices.count) Sonos devices (\(uniqueDevices.count) unique)")
                for device in uniqueDevices {
                    print("  - \(device.name) at \(device.ipAddress)")
                }

                // Only fetch topology if not cached
                if !self.hasLoadedTopology {
                    print("Fetching initial group topology...")
                    self.updateGroupTopology(completion: completion)
                    self.hasLoadedTopology = true
                } else {
                    print("Using cached topology (refresh to update)")
                    // Call completion immediately if using cached topology
                    completion?()
                }

                // Post notification so menu can update
                NotificationCenter.default.post(name: NSNotification.Name("SonosDevicesDiscovered"), object: nil)
            }
        } catch {
            print("SSDP Discovery error: \(error)")

            // Notify about network error (likely permissions issue)
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: NSNotification.Name("SonosNetworkError"),
                    object: nil,
                    userInfo: ["error": error.localizedDescription]
                )
            }
        }
    }

    private func updateGroupTopology(completion: (@Sendable () -> Void)? = nil) {
        // Pick any device to query group topology (all devices know about all groups)
        guard let anyDevice = devices.first else {
            completion?()
            return
        }

        let url = URL(string: "http://\(anyDevice.ipAddress):1400/ZoneGroupTopology/Control")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.addValue("\"urn:schemas-upnp-org:service:ZoneGroupTopology:1#GetZoneGroupState\"", forHTTPHeaderField: "SOAPACTION")

        let soapBody = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
            <s:Body>
                <u:GetZoneGroupState xmlns:u="urn:schemas-upnp-org:service:ZoneGroupTopology:1">
                </u:GetZoneGroupState>
            </s:Body>
        </s:Envelope>
        """

        request.httpBody = soapBody.data(using: .utf8)

        let semaphore = DispatchSemaphore(value: 0)

        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }

            if let error = error {
                print("GetZoneGroupState error: \(error)")
                return
            }

            guard let data = data, let responseStr = String(data: data, encoding: .utf8) else {
                return
            }

            self.parseGroupTopology(responseStr, completion: completion)
        }.resume()

        _ = semaphore.wait(timeout: .now() + 3)
    }

    private func parseGroupTopology(_ xml: String, completion: (@Sendable () -> Void)? = nil) {
        // Extract ZoneGroupState XML from SOAP response
        guard let stateRange = xml.range(of: "<ZoneGroupState>([\\s\\S]*?)</ZoneGroupState>", options: .regularExpression) else {
            print("Could not find ZoneGroupState in response")
            DispatchQueue.main.async {
                completion?()
            }
            return
        }

        let stateXML = String(xml[stateRange])

        // Decode HTML entities to parse actual XML structure
        let decodedXML = stateXML
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")

        // Parse each ZoneGroup to find coordinators and invisible devices
        let groupPattern = "<ZoneGroup Coordinator=\"([^\"]+)\"[^>]*>([\\s\\S]*?)</ZoneGroup>"
        let regex = try? NSRegularExpression(pattern: groupPattern, options: [])
        let nsString = decodedXML as NSString
        let matches = regex?.matches(in: decodedXML, options: [], range: NSRange(location: 0, length: nsString.length)) ?? []

        var groupInfo: [String: String] = [:]           // UUID -> Group Coordinator UUID
        var invisibleUUIDs: Set<String> = []            // UUIDs of invisible/satellite speakers
        var channelMapSets: [String: String] = [:]      // UUID -> ChannelMapSet (for stereo pairs)
        var pairPartners: [String: String] = [:]        // UUID -> Pair Partner UUID

        for match in matches {
            if match.numberOfRanges >= 3 {
                let coordinatorUUID = nsString.substring(with: match.range(at: 1))
                let membersXML = nsString.substring(with: match.range(at: 2))

                // Find all members in this group
                let memberPattern = "<ZoneGroupMember UUID=\"([^\"]+)\"[^>]*?"
                let memberRegex = try? NSRegularExpression(pattern: memberPattern, options: [])
                let memberMatches = memberRegex?.matches(in: membersXML, options: [], range: NSRange(location: 0, length: (membersXML as NSString).length)) ?? []

                for memberMatch in memberMatches {
                    if memberMatch.numberOfRanges >= 2 {
                        let memberUUID = (membersXML as NSString).substring(with: memberMatch.range(at: 1))
                        groupInfo[memberUUID] = coordinatorUUID

                        // Extract the full ZoneGroupMember element
                        if let memberElementRange = membersXML.range(of: "<ZoneGroupMember UUID=\"\(memberUUID)\"[^>]*>", options: .regularExpression) {
                            let memberElement = String(membersXML[memberElementRange])

                            // Check for invisible attribute
                            if memberElement.contains("Invisible=\"1\"") {
                                invisibleUUIDs.insert(memberUUID)
                                print("Found invisible/satellite speaker: \(memberUUID)")
                            }

                            // Extract ChannelMapSet (indicates stereo pair)
                            if let channelMapRange = memberElement.range(of: "ChannelMapSet=\"([^\"]+)\"", options: .regularExpression) {
                                let channelMapMatch = String(memberElement[channelMapRange])
                                if let channelMapSet = channelMapMatch.components(separatedBy: "\"").dropFirst().first {
                                    channelMapSets[memberUUID] = channelMapSet

                                    // Parse pair partner from ChannelMapSet
                                    // Format: "UUID1:RF,RF;UUID2:LF,LF"
                                    let pairs = channelMapSet.components(separatedBy: ";")
                                    for pair in pairs {
                                        let parts = pair.components(separatedBy: ":")
                                        if let pairUUID = parts.first, pairUUID != memberUUID {
                                            pairPartners[memberUUID] = pairUUID
                                            print("Stereo pair: \(memberUUID) <-> \(pairUUID)")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // Update devices with coordinator information on main queue (thread safety)
        DispatchQueue.main.async {
            // Store in cache for future use
            self.topologyCache = groupInfo
            print("Cached topology for \(groupInfo.count) devices")
            print("Found \(invisibleUUIDs.count) invisible/satellite speakers to filter out")

            // Update devices with PAIR and GROUP information, filter out invisible speakers
            self.devices = self.devices.compactMap { device in
                // Filter out invisible/satellite speakers from device list
                if invisibleUUIDs.contains(device.uuid) {
                    print("Filtering out invisible speaker: \(device.name) (\(device.uuid))")
                    return nil
                }

                // Rebuild device with topology information
                let groupCoordUUID = groupInfo[device.uuid]
                let channelMap = channelMapSets[device.uuid]
                let pairPartner = pairPartners[device.uuid]

                return SonosDevice(
                    name: device.name,
                    ipAddress: device.ipAddress,
                    uuid: device.uuid,
                    isGroupCoordinator: device.uuid == groupCoordUUID,
                    groupCoordinatorUUID: groupCoordUUID,
                    channelMapSet: channelMap,
                    pairPartnerUUID: pairPartner
                )
            }

            // Build groups from topology
            self.buildGroups(from: groupInfo)

            print("Updated topology (visible speakers/pairs only):")
            for device in self.devices {
                var info = device.name
                if device.channelMapSet != nil {
                    info += " [STEREO PAIR"
                    if let partner = device.pairPartnerUUID {
                        info += " with \(partner.suffix(4))"
                    }
                    info += "]"
                }
                if let groupCoord = device.groupCoordinatorUUID {
                    if device.isGroupCoordinator {
                        info += " (Group Leader)"
                    } else {
                        info += " (in group led by \(groupCoord.suffix(4)))"
                    }
                }
                print("  - \(info)")
            }

            print("\nGroups detected:")
            for group in self.groups {
                print("  - \(group.displayName) (\(group.members.count) member(s))")
            }

            // Refresh selected device to pick up new coordinator information
            self.refreshSelectedDevice()

            // Notify that devices have changed (for UI updates)
            NotificationCenter.default.post(name: NSNotification.Name("SonosDevicesDiscovered"), object: nil)

            // Call completion handler
            completion?()
        }
    }

    private func parseSSDPResponse(_ data: String, from address: String) -> SonosDevice? {
        // Extract location URL from SSDP response
        guard let locationLine = data.components(separatedBy: "\r\n")
            .first(where: { $0.uppercased().hasPrefix("LOCATION:") }) else {
            return nil
        }

        let location = locationLine.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)

        guard let url = URL(string: location),
              let host = url.host else {
            return nil
        }

        // Fetch device description to get friendly name and UUID
        let (name, uuid) = fetchDeviceInfo(from: location)
        let deviceName = name ?? host

        return SonosDevice(
            name: deviceName,
            ipAddress: host,
            uuid: uuid ?? location,
            isGroupCoordinator: false,      // Will be updated after topology loads
            groupCoordinatorUUID: nil,      // Will be updated after topology loads
            channelMapSet: nil,             // Will be updated after topology loads
            pairPartnerUUID: nil            // Will be updated after topology loads
        )
    }

    private func fetchDeviceInfo(from location: String) -> (name: String?, uuid: String?) {
        guard let url = URL(string: location) else { return (nil, nil) }

        var request = URLRequest(url: url)
        request.timeoutInterval = 2.0

        var resultName: String?
        var resultUUID: String?
        let semaphore = DispatchSemaphore(value: 0)

        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }

            guard let data = data,
                  let xml = String(data: data, encoding: .utf8) else {
                return
            }

            // Parse roomName or friendlyName
            if let nameRange = xml.range(of: "<roomName>([^<]+)</roomName>", options: .regularExpression) {
                let nameString = String(xml[nameRange])
                resultName = nameString.replacingOccurrences(of: "<roomName>", with: "")
                    .replacingOccurrences(of: "</roomName>", with: "")
            } else if let nameRange = xml.range(of: "<friendlyName>([^<]+)</friendlyName>", options: .regularExpression) {
                let nameString = String(xml[nameRange])
                resultName = nameString.replacingOccurrences(of: "<friendlyName>", with: "")
                    .replacingOccurrences(of: "</friendlyName>", with: "")
            }

            // Parse UDN (Unique Device Name) which contains the UUID
            if let udnRange = xml.range(of: "<UDN>([^<]+)</UDN>", options: .regularExpression) {
                let udnString = String(xml[udnRange])
                let udn = udnString.replacingOccurrences(of: "<UDN>", with: "")
                    .replacingOccurrences(of: "</UDN>", with: "")
                // UDN format is typically "uuid:RINCON_XXXXXXXXXXXX"
                if let uuidPart = udn.components(separatedBy: ":").last {
                    resultUUID = uuidPart
                }
            }
        }.resume()

        _ = semaphore.wait(timeout: .now() + 3)
        return (resultName, resultUUID)
    }

    func selectDevice(name: String) {
        _selectedDevice = devices.first { $0.name == name }
        if let device = _selectedDevice {
            settings.selectedSonosDevice = device.name

            var info = "✅ Selected: \(device.name)"
            if device.channelMapSet != nil {
                info += " [STEREO PAIR]"
            }
            if let groupCoord = device.groupCoordinatorUUID {
                if device.isGroupCoordinator {
                    info += " (Group Leader)"
                } else {
                    info += " (in group)"
                }
            }
            print(info)
        }
    }

    // Refresh _selectedDevice reference to pick up updated topology info
    private func refreshSelectedDevice() {
        guard let currentDevice = _selectedDevice else { return }

        // Re-find the device in the updated devices array to get current topology info
        if let updatedDevice = devices.first(where: { $0.name == currentDevice.name }) {
            _selectedDevice = updatedDevice
            if updatedDevice.channelMapSet != nil {
                print("Refreshed selected device: \(updatedDevice.name) [STEREO PAIR]")
            } else {
                print("Refreshed selected device: \(updatedDevice.name)")
            }
        }
    }

    // Build group objects from topology information
    private func buildGroups(from groupInfo: [String: String]) {
        // Group devices by their coordinator UUID
        var groupMap: [String: [SonosDevice]] = [:]

        for device in devices {
            guard let coordUUID = device.groupCoordinatorUUID else { continue }

            if groupMap[coordUUID] == nil {
                groupMap[coordUUID] = []
            }
            groupMap[coordUUID]?.append(device)
        }

        // Build SonosGroup objects
        groups = groupMap.compactMap { (coordUUID, members) in
            // Find the coordinator device
            guard let coordinator = members.first(where: { $0.uuid == coordUUID }) else {
                return nil
            }

            return SonosGroup(
                id: coordUUID,
                coordinatorUUID: coordUUID,
                coordinator: coordinator,
                members: members.sorted { $0.name < $1.name },
                groupVolume: nil  // Will be fetched on demand
            )
        }.sorted { $0.coordinator.name < $1.coordinator.name }
    }

    // MARK: - Helper Methods

    /// Get the group that contains the given device (only if it's a multi-speaker group)
    func getGroupForDevice(_ device: SonosDevice) -> SonosGroup? {
        guard let coordUUID = device.groupCoordinatorUUID else { return nil }

        // Find the group and make sure it has more than 1 member
        return groups.first(where: { $0.coordinatorUUID == coordUUID && $0.members.count > 1 })
    }

    func getCurrentVolume(completion: @escaping (Int?) -> Void) {
        guard let device = _selectedDevice else {
            completion(nil)
            return
        }

        // Check if device is in a multi-speaker group
        if let group = getGroupForDevice(device) {
            // Get group volume
            getGroupVolume(group: group, completion: completion)
        } else {
            // For stereo pairs or standalone, query the visible speaker (it controls both)
            sendSonosCommand(to: device, action: "GetVolume") { volumeStr in
                completion(Int(volumeStr))
            }
        }
    }

    func volumeUp() {
        print("📢 volumeUp() called")
        guard let device = _selectedDevice else {
            print("⚠️ No device selected!")
            showNoSpeakerSelectedNotification()
            return
        }

        // Check if device is in a multi-speaker group
        if let group = getGroupForDevice(device) {
            print("🎚️ Adjusting group volume (relative)")
            changeGroupVolume(group: group, by: settings.volumeStep)
        } else {
            changeVolume(by: settings.volumeStep)
        }
    }

    func volumeDown() {
        print("📢 volumeDown() called")
        guard let device = _selectedDevice else {
            print("⚠️ No device selected!")
            showNoSpeakerSelectedNotification()
            return
        }

        // Check if device is in a multi-speaker group
        if let group = getGroupForDevice(device) {
            print("🎚️ Adjusting group volume (relative)")
            changeGroupVolume(group: group, by: -settings.volumeStep)
        } else {
            changeVolume(by: -settings.volumeStep)
        }
    }

    private func showNoSpeakerSelectedNotification() {
        Task { @MainActor in
            VolumeHUD.shared.showError(
                title: "No Speaker Selected",
                message: "Click the menu bar icon to select your Sonos speaker"
            )
        }
    }

    func getVolume(completion: @escaping (Int) -> Void) {
        guard let device = _selectedDevice else {
            print("❌ No Sonos device selected")
            completion(50) // Default
            return
        }

        // For stereo pairs, query the visible speaker (it controls both)
        sendSonosCommand(to: device, action: "GetVolume") { volumeStr in
            if let volume = Int(volumeStr) {
                completion(volume)
            } else {
                completion(50) // Default
            }
        }
    }

    func setVolume(_ volume: Int) {
        guard let device = _selectedDevice else {
            print("❌ No Sonos device selected")
            return
        }

        let clampedVolume = max(0, min(100, volume))

        // Check if device is in a multi-speaker group
        if let group = getGroupForDevice(device) {
            print("🎚️ setVolume(\(clampedVolume)) for GROUP \(group.displayName)")
            setGroupVolume(group: group, volume: clampedVolume)
            return
        }

        // Individual speaker or stereo pair control
        // KEY INSIGHT: For stereo pairs, the visible speaker controls BOTH speakers in the pair
        let targetDevice = device

        if device.channelMapSet != nil {
            print("🎚️ setVolume(\(clampedVolume)) for STEREO PAIR \(device.name)")
        } else {
            print("🎚️ setVolume(\(clampedVolume)) for \(device.name)")
        }

        sendSonosCommand(to: targetDevice, action: "SetVolume", arguments: ["DesiredVolume": String(clampedVolume)])

        // Show HUD and notify observers
        Task { @MainActor in
            VolumeHUD.shared.show(speaker: device.name, volume: clampedVolume)

            // Post notification for UI updates
            NotificationCenter.default.post(
                name: NSNotification.Name("SonosVolumeDidChange"),
                object: nil,
                userInfo: ["volume": clampedVolume]
            )
        }
    }

    /// Set volume for a specific device, bypassing group logic
    /// Used for controlling individual speakers within a group
    /// - Parameters:
    ///   - device: The specific device to control
    ///   - volume: Volume level (0-100)
    func setIndividualVolume(device: SonosDevice, volume: Int) {
        let clampedVolume = max(0, min(100, volume))
        print("🎚️ setIndividualVolume(\(clampedVolume)) for \(device.name)")

        // Directly set volume using RenderingControl (not GroupRenderingControl)
        // This works even when the device is part of a group
        sendSonosCommand(to: device, action: "SetVolume", arguments: ["DesiredVolume": String(clampedVolume)])
    }

    func toggleMute() {
        guard let device = _selectedDevice else {
            print("No Sonos device selected")
            return
        }

        sendSonosCommand(to: device, action: "GetMute") { currentMute in
            let newMute = currentMute == "1" ? "0" : "1"
            self.sendSonosCommand(to: device, action: "SetMute", arguments: ["DesiredMute": newMute])
        }
    }

    private func changeVolume(by delta: Int) {
        guard let device = _selectedDevice else {
            print("❌ No Sonos device selected")
            return
        }

        // For stereo pairs, the visible speaker controls BOTH speakers
        let targetDevice = device

        if device.channelMapSet != nil {
            print("🎚️ Changing volume by \(delta) for STEREO PAIR \(device.name)")
        } else {
            print("🎚️ Changing volume by \(delta) for \(device.name)")
        }

        // Get current volume
        sendSonosCommand(to: targetDevice, action: "GetVolume") { currentVolumeStr in
            print("   Current volume string: '\(currentVolumeStr)'")
            guard let currentVolume = Int(currentVolumeStr) else {
                print("   ❌ Failed to parse volume: '\(currentVolumeStr)'")
                return
            }
            let newVolume = max(0, min(100, currentVolume + delta))
            print("   📊 \(currentVolume) → \(newVolume)")
            self.sendSonosCommand(to: targetDevice, action: "SetVolume", arguments: ["DesiredVolume": String(newVolume)])

            // Show HUD and notify observers
            Task { @MainActor in
                VolumeHUD.shared.show(speaker: device.name, volume: newVolume)

                // Post notification for UI updates
                NotificationCenter.default.post(
                    name: NSNotification.Name("SonosVolumeDidChange"),
                    object: nil,
                    userInfo: ["volume": newVolume]
                )
            }
        }
    }

    private func sendSonosCommand(to device: SonosDevice, action: String, arguments: [String: String] = [:], completion: ((String) -> Void)? = nil) {
        let url = URL(string: "http://\(device.ipAddress):1400/MediaRenderer/RenderingControl/Control")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.addValue("\"urn:schemas-upnp-org:service:RenderingControl:1#\(action)\"", forHTTPHeaderField: "SOAPACTION")

        var argsXML = "<InstanceID>0</InstanceID><Channel>Master</Channel>"
        for (key, value) in arguments {
            argsXML += "<\(key)>\(value)</\(key)>"
        }

        let soapBody = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
            <s:Body>
                <u:\(action) xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1">
                    \(argsXML)
                </u:\(action)>
            </s:Body>
        </s:Envelope>
        """

        request.httpBody = soapBody.data(using: .utf8)

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("Sonos command error: \(error)")
                return
            }

            if let data = data, let responseStr = String(data: data, encoding: .utf8) {
                // Simple XML value extraction
                if let completion = completion {
                    if let valueRange = responseStr.range(of: "<Current[^>]*>([^<]+)</Current", options: .regularExpression) {
                        let valueString = String(responseStr[valueRange])
                        let value = valueString.replacingOccurrences(of: #"<Current[^>]*>"#, with: "", options: .regularExpression)
                            .replacingOccurrences(of: "</Current", with: "")
                        completion(value)
                    }
                }
            }
        }.resume()
    }

    // MARK: - Group Management Commands

    /// Add a device to an existing group (or create a new group)
    /// Uses AVTransport SetAVTransportURI with x-rincon URI
    func addDeviceToGroup(device: SonosDevice, coordinatorUUID: String, shouldRefreshTopology: Bool = true, completion: ((Bool) -> Void)? = nil) {
        guard let coordinator = devices.first(where: { $0.uuid == coordinatorUUID }) else {
            print("❌ Coordinator not found: \(coordinatorUUID)")
            completion?(false)
            return
        }

        print("🔗 Adding \(device.name) to group led by \(coordinator.name)")

        let url = URL(string: "http://\(device.ipAddress):1400/MediaRenderer/AVTransport/Control")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.addValue("\"urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI\"", forHTTPHeaderField: "SOAPACTION")

        let soapBody = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
            <s:Body>
                <u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
                    <InstanceID>0</InstanceID>
                    <CurrentURI>x-rincon:\(coordinatorUUID)</CurrentURI>
                    <CurrentURIMetaData></CurrentURIMetaData>
                </u:SetAVTransportURI>
            </s:Body>
        </s:Envelope>
        """

        request.httpBody = soapBody.data(using: .utf8)

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("❌ Failed to add device to group: \(error)")
                completion?(false)
                return
            }

            // Check HTTP status code
            if let httpResponse = response as? HTTPURLResponse {
                print("📡 HTTP Status: \(httpResponse.statusCode) for \(device.name)")
                if httpResponse.statusCode != 200 {
                    print("❌ Unexpected status code: \(httpResponse.statusCode)")
                    if let data = data, let responseStr = String(data: data, encoding: .utf8) {
                        print("   Response: \(responseStr)")
                    }
                }
            }

            print("✅ Successfully added \(device.name) to group")

            // Optionally refresh topology before calling completion
            if shouldRefreshTopology {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    self.updateGroupTopology {
                        completion?(true)
                    }
                }
            } else {
                completion?(true)
            }
        }.resume()
    }

    /// Remove a device from its current group (make it standalone)
    /// Uses AVTransport BecomeGroupCoordinatorAndSource
    func removeDeviceFromGroup(device: SonosDevice, completion: ((Bool) -> Void)? = nil) {
        print("🔓 Removing \(device.name) from group")

        let url = URL(string: "http://\(device.ipAddress):1400/MediaRenderer/AVTransport/Control")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.addValue("\"urn:schemas-upnp-org:service:AVTransport:1#BecomeCoordinatorOfStandaloneGroup\"", forHTTPHeaderField: "SOAPACTION")

        let soapBody = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
            <s:Body>
                <u:BecomeCoordinatorOfStandaloneGroup xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
                    <InstanceID>0</InstanceID>
                </u:BecomeCoordinatorOfStandaloneGroup>
            </s:Body>
        </s:Envelope>
        """

        request.httpBody = soapBody.data(using: .utf8)

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("❌ Failed to remove device from group: \(error)")
                completion?(false)
                return
            }

            print("✅ Successfully removed \(device.name) from group")
            completion?(true)

            // Refresh topology after a short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.updateGroupTopology()
            }
        }.resume()
    }

    /// Create a new group with specified devices
    /// The first device becomes the coordinator
    /// Get playback states for multiple devices
    /// Returns dictionary mapping device UUID to transport state
    func getPlaybackStates(devices: [SonosDevice], completion: @escaping ([String: String]) -> Void) {
        var states: [String: String] = [:]
        let dispatchGroup = DispatchGroup()

        for device in devices {
            dispatchGroup.enter()
            getTransportState(device: device) { state in
                if let state = state {
                    states[device.uuid] = state
                }
                dispatchGroup.leave()
            }
        }

        dispatchGroup.notify(queue: .main) {
            completion(states)
        }
    }

    /// Get list of devices that are currently playing
    func getPlayingDevices(from devices: [SonosDevice], completion: @escaping ([SonosDevice]) -> Void) {
        getPlaybackStates(devices: devices) { states in
            let playingDevices = devices.filter { device in
                states[device.uuid] == "PLAYING"
            }
            completion(playingDevices)
        }
    }

    /// Create a group from multiple devices with smart coordinator selection
    /// If coordinatorDevice is not specified, will choose intelligently based on playback state
    func createGroup(devices deviceList: [SonosDevice], coordinatorDevice: SonosDevice? = nil, completion: ((Bool) -> Void)? = nil) {
        guard deviceList.count > 1 else {
            print("❌ Need at least 2 devices to create a group")
            completion?(false)
            return
        }

        // If coordinator is explicitly specified, use it
        if let explicitCoordinator = coordinatorDevice {
            guard deviceList.contains(where: { $0.uuid == explicitCoordinator.uuid }) else {
                print("❌ Specified coordinator not in device list")
                completion?(false)
                return
            }
            performGrouping(devices: deviceList, coordinator: explicitCoordinator, completion: completion)
            return
        }

        // Otherwise, intelligently select coordinator based on playback state
        print("🔍 Checking playback states to choose coordinator...")
        getPlaybackStates(devices: deviceList) { [weak self] states in
            guard let self = self else { return }

            // Find devices that are currently playing
            let playingDevices = deviceList.filter { device in
                states[device.uuid] == "PLAYING"
            }

            let coordinator: SonosDevice
            if playingDevices.isEmpty {
                // No devices playing, use first device
                coordinator = deviceList.first!
                print("📍 No devices playing, using first device as coordinator: \(coordinator.name)")
            } else if playingDevices.count == 1 {
                // One device playing, use it as coordinator to preserve playback
                coordinator = playingDevices.first!
                print("🎵 One device playing, using it as coordinator to preserve audio: \(coordinator.name)")
            } else {
                // Multiple devices playing - this requires user input
                // For now, use first playing device but log warning
                coordinator = playingDevices.first!
                print("⚠️ Multiple devices playing (\(playingDevices.count)), defaulting to first: \(coordinator.name)")
                print("   Note: Other playing devices will stop playback")
            }

            self.performGrouping(devices: deviceList, coordinator: coordinator, completion: completion)
        }
    }

    /// Internal helper to perform the actual grouping with a specified coordinator
    private func performGrouping(devices: [SonosDevice], coordinator: SonosDevice, completion: ((Bool) -> Void)?) {
        print("🎵 Creating group with coordinator: \(coordinator.name)")

        let membersToAdd = devices.filter { $0.uuid != coordinator.uuid }
        var successCount = 0
        let totalMembers = membersToAdd.count

        // Add each member to the coordinator's group
        for member in membersToAdd {
            addDeviceToGroup(device: member, coordinatorUUID: coordinator.uuid, shouldRefreshTopology: false) { success in
                if success {
                    successCount += 1
                }

                // Check if all members have been added
                if successCount + (totalMembers - successCount) == totalMembers {
                    let allSuccess = successCount == totalMembers
                    print(allSuccess ? "✅ All members added" : "⚠️ Some members failed to add")

                    // Refresh topology once after all additions complete
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        self.updateGroupTopology {
                            print(allSuccess ? "✅ Group created successfully" : "⚠️ Group created with some failures")
                            completion?(allSuccess)
                        }
                    }
                }
            }
        }
    }

    /// Dissolve a group by ungrouping all members
    func dissolveGroup(group: SonosGroup, completion: ((Bool) -> Void)? = nil) {
        print("💥 Dissolving group: \(group.displayName)")

        let nonCoordinatorMembers = group.members.filter { $0.uuid != group.coordinatorUUID }

        guard !nonCoordinatorMembers.isEmpty else {
            print("ℹ️ Group already standalone")
            completion?(true)
            return
        }

        var successCount = 0
        let totalMembers = nonCoordinatorMembers.count

        for member in nonCoordinatorMembers {
            removeDeviceFromGroup(device: member) { success in
                if success {
                    successCount += 1
                }

                if successCount + (totalMembers - successCount) == totalMembers {
                    let allSuccess = successCount == totalMembers
                    print(allSuccess ? "✅ Group dissolved successfully" : "⚠️ Group dissolved with some failures")
                    completion?(allSuccess)
                }
            }
        }
    }

    /// Get the transport state of a device (PLAYING, PAUSED_PLAYBACK, STOPPED, etc.)
    /// Uses AVTransport GetTransportInfo
    func getTransportState(device: SonosDevice, completion: @escaping (String?) -> Void) {
        let url = URL(string: "http://\(device.ipAddress):1400/MediaRenderer/AVTransport/Control")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.addValue("\"urn:schemas-upnp-org:service:AVTransport:1#GetTransportInfo\"", forHTTPHeaderField: "SOAPACTION")

        let soapBody = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
            <s:Body>
                <u:GetTransportInfo xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
                    <InstanceID>0</InstanceID>
                </u:GetTransportInfo>
            </s:Body>
        </s:Envelope>
        """

        request.httpBody = soapBody.data(using: .utf8)

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("❌ Failed to get transport state: \(error)")
                completion(nil)
                return
            }

            if let data = data, let responseStr = String(data: data, encoding: .utf8) {
                // Extract CurrentTransportState value
                if let stateRange = responseStr.range(of: "<CurrentTransportState>([^<]+)</CurrentTransportState>", options: .regularExpression) {
                    let stateString = String(responseStr[stateRange])
                    let state = stateString
                        .replacingOccurrences(of: "<CurrentTransportState>", with: "")
                        .replacingOccurrences(of: "</CurrentTransportState>", with: "")
                    print("🎵 Transport state for \(device.name): \(state)")
                    completion(state)
                } else {
                    print("⚠️ Could not parse transport state for \(device.name)")
                    completion(nil)
                }
            } else {
                completion(nil)
            }
        }.resume()
    }

    // MARK: - Group Volume Control

    /// Get the group volume (average across all members)
    /// Must be called on the group coordinator
    func getGroupVolume(group: SonosGroup, completion: @escaping (Int?) -> Void) {
        let coordinator = group.coordinator
        print("🎚️ Getting group volume for: \(group.displayName)")

        let url = URL(string: "http://\(coordinator.ipAddress):1400/MediaRenderer/GroupRenderingControl/Control")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.addValue("\"urn:schemas-upnp-org:service:GroupRenderingControl:1#GetGroupVolume\"", forHTTPHeaderField: "SOAPACTION")

        let soapBody = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
            <s:Body>
                <u:GetGroupVolume xmlns:u="urn:schemas-upnp-org:service:GroupRenderingControl:1">
                    <InstanceID>0</InstanceID>
                </u:GetGroupVolume>
            </s:Body>
        </s:Envelope>
        """

        request.httpBody = soapBody.data(using: .utf8)

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("❌ Failed to get group volume: \(error)")
                completion(nil)
                return
            }

            guard let data = data, let responseStr = String(data: data, encoding: .utf8) else {
                completion(nil)
                return
            }

            // Parse volume from response
            if let volumeRange = responseStr.range(of: "<CurrentVolume>([^<]+)</CurrentVolume>", options: .regularExpression) {
                let volumeString = String(responseStr[volumeRange])
                let volumeValue = volumeString.replacingOccurrences(of: "<CurrentVolume>", with: "")
                    .replacingOccurrences(of: "</CurrentVolume>", with: "")
                if let volume = Int(volumeValue) {
                    print("   Group volume: \(volume)")
                    completion(volume)
                    return
                }
            }

            completion(nil)
        }.resume()
    }

    /// Set the group volume (proportionally adjusts all members)
    /// Must be called on the group coordinator
    func setGroupVolume(group: SonosGroup, volume: Int) {
        let coordinator = group.coordinator
        let clampedVolume = max(0, min(100, volume))
        print("🎚️ Setting group volume for \(group.displayName) to \(clampedVolume)")

        let url = URL(string: "http://\(coordinator.ipAddress):1400/MediaRenderer/GroupRenderingControl/Control")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.addValue("\"urn:schemas-upnp-org:service:GroupRenderingControl:1#SetGroupVolume\"", forHTTPHeaderField: "SOAPACTION")

        let soapBody = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
            <s:Body>
                <u:SetGroupVolume xmlns:u="urn:schemas-upnp-org:service:GroupRenderingControl:1">
                    <InstanceID>0</InstanceID>
                    <DesiredVolume>\(clampedVolume)</DesiredVolume>
                </u:SetGroupVolume>
            </s:Body>
        </s:Envelope>
        """

        request.httpBody = soapBody.data(using: .utf8)

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("❌ Failed to set group volume: \(error)")
                return
            }

            print("✅ Group volume set to \(clampedVolume)")

            // Show HUD
            Task { @MainActor in
                VolumeHUD.shared.show(speaker: group.displayName, volume: clampedVolume)

                // Post notification for UI updates
                NotificationCenter.default.post(
                    name: NSNotification.Name("SonosVolumeDidChange"),
                    object: nil,
                    userInfo: ["volume": clampedVolume]
                )
            }
        }.resume()
    }

    /// Adjust group volume by a relative amount (+/-)
    /// Ideal for volume up/down buttons
    func changeGroupVolume(group: SonosGroup, by delta: Int) {
        let coordinator = group.coordinator
        print("🎚️ Changing group volume for \(group.displayName) by \(delta)")

        let url = URL(string: "http://\(coordinator.ipAddress):1400/MediaRenderer/GroupRenderingControl/Control")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.addValue("\"urn:schemas-upnp-org:service:GroupRenderingControl:1#SetRelativeGroupVolume\"", forHTTPHeaderField: "SOAPACTION")

        let soapBody = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
            <s:Body>
                <u:SetRelativeGroupVolume xmlns:u="urn:schemas-upnp-org:service:GroupRenderingControl:1">
                    <InstanceID>0</InstanceID>
                    <Adjustment>\(delta)</Adjustment>
                </u:SetRelativeGroupVolume>
            </s:Body>
        </s:Envelope>
        """

        request.httpBody = soapBody.data(using: .utf8)

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("❌ Failed to change group volume: \(error)")
                return
            }

            // Get the new volume to show in HUD
            self.getGroupVolume(group: group) { newVolume in
                guard let volume = newVolume else { return }

                Task { @MainActor in
                    VolumeHUD.shared.show(speaker: group.displayName, volume: volume)

                    NotificationCenter.default.post(
                        name: NSNotification.Name("SonosVolumeDidChange"),
                        object: nil,
                        userInfo: ["volume": volume]
                    )
                }
            }
        }.resume()
    }
}

// BSD socket for SSDP discovery
import Darwin

class Socket {
    private var sockfd: Int32 = -1

    init() throws {
        sockfd = socket(AF_INET, SOCK_DGRAM, 0)
        guard sockfd >= 0 else {
            throw NSError(domain: "Socket", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Failed to create socket"])
        }

        // Allow socket reuse
        var reuseAddr: Int32 = 1
        setsockopt(sockfd, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, socklen_t(MemoryLayout<Int32>.size))

        #if os(macOS)
        var reusePort: Int32 = 1
        setsockopt(sockfd, SOL_SOCKET, SO_REUSEPORT, &reusePort, socklen_t(MemoryLayout<Int32>.size))
        #endif

        // Set timeout for receives
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(sockfd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    deinit {
        if sockfd >= 0 {
            close(sockfd)
        }
    }

    func send(_ message: String, to address: String, port: UInt16) throws {
        guard let data = message.data(using: .utf8) else { return }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, address, &addr.sin_addr)

        let sent = data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Int in
            return withUnsafePointer(to: addr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    return sendto(sockfd, buffer.baseAddress, buffer.count, 0, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        guard sent >= 0 else {
            throw NSError(domain: "Socket", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Failed to send"])
        }
    }

    func receive(timeout: TimeInterval) throws -> (data: String, address: String)? {
        var buffer = [UInt8](repeating: 0, count: 8192)
        var addr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

        let received = withUnsafeMutablePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                recvfrom(sockfd, &buffer, buffer.count, 0, sockaddrPtr, &addrLen)
            }
        }

        guard received > 0 else {
            return nil
        }

        guard let string = String(bytes: buffer[..<received], encoding: .utf8) else {
            return nil
        }

        var hostBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &addr.sin_addr, &hostBuffer, socklen_t(INET_ADDRSTRLEN))
        let host = String(cString: hostBuffer)

        return (string, host)
    }
}