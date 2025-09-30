import Foundation
import Network

class SonosController: @unchecked Sendable {
    private let settings: AppSettings
    private var devices: [SonosDevice] = []
    private var selectedDevice: SonosDevice?

    // Topology cache - persists during app session
    private var topologyCache: [String: String] = [:]  // UUID -> Coordinator UUID
    private var hasLoadedTopology = false

    // Expose devices for menu population
    var discoveredDevices: [SonosDevice] {
        return devices
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
        selectedDevice = devices.first { $0.name == name }
        if let device = selectedDevice {
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

    // Refresh selectedDevice reference to pick up updated topology info
    private func refreshSelectedDevice() {
        guard let currentDevice = selectedDevice else { return }

        // Re-find the device in the updated devices array to get current topology info
        if let updatedDevice = devices.first(where: { $0.name == currentDevice.name }) {
            selectedDevice = updatedDevice
            if updatedDevice.channelMapSet != nil {
                print("Refreshed selected device: \(updatedDevice.name) [STEREO PAIR]")
            } else {
                print("Refreshed selected device: \(updatedDevice.name)")
            }
        }
    }

    func getCurrentVolume(completion: @escaping (Int?) -> Void) {
        guard let device = selectedDevice else {
            completion(nil)
            return
        }

        // For stereo pairs, query the visible speaker (it controls both)
        sendSonosCommand(to: device, action: "GetVolume") { volumeStr in
            completion(Int(volumeStr))
        }
    }

    func volumeUp() {
        print("📢 volumeUp() called")
        guard selectedDevice != nil else {
            print("⚠️ No device selected!")
            return
        }
        changeVolume(by: settings.volumeStep)
    }

    func volumeDown() {
        print("📢 volumeDown() called")
        guard selectedDevice != nil else {
            print("⚠️ No device selected!")
            return
        }
        changeVolume(by: -settings.volumeStep)
    }

    func getVolume(completion: @escaping (Int) -> Void) {
        guard let device = selectedDevice else {
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
        guard let device = selectedDevice else {
            print("❌ No Sonos device selected")
            return
        }

        // KEY INSIGHT: For stereo pairs, the visible speaker controls BOTH speakers in the pair
        // Group coordinator is only for playback synchronization, NOT volume control
        // So we ALWAYS send volume to the selected device directly
        let targetDevice = device

        if device.channelMapSet != nil {
            print("🎚️ setVolume(\(volume)) for STEREO PAIR \(device.name)")
        } else {
            print("🎚️ setVolume(\(volume)) for \(device.name)")
        }

        let clampedVolume = max(0, min(100, volume))
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

    func toggleMute() {
        guard let device = selectedDevice else {
            print("No Sonos device selected")
            return
        }

        sendSonosCommand(to: device, action: "GetMute") { currentMute in
            let newMute = currentMute == "1" ? "0" : "1"
            self.sendSonosCommand(to: device, action: "SetMute", arguments: ["DesiredMute": newMute])
        }
    }

    private func changeVolume(by delta: Int) {
        guard let device = selectedDevice else {
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