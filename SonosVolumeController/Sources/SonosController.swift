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
        let isCoordinator: Bool
        let coordinatorUUID: String?  // UUID of the group coordinator
    }

    init(settings: AppSettings) {
        self.settings = settings
    }

    func discoverDevices(forceRefreshTopology: Bool = false) {
        print("Discovering Sonos devices...")

        // Clear cache if forced refresh is requested
        if forceRefreshTopology {
            print("Clearing topology cache for fresh discovery")
            topologyCache.removeAll()
            hasLoadedTopology = false
        }

        // Use SSDP (Simple Service Discovery Protocol) to find Sonos devices
        let queue = DispatchQueue(label: "sonos.discovery")

        queue.async { [weak self] in
            self?.performSSDPDiscovery()
        }
    }

    private func performSSDPDiscovery() {
        let ssdpMessage = """
        M-SEARCH * HTTP/1.1\r
        HOST: 239.255.255.250:1900\r
        MAN: "ssdp:discover"\r
        MX: 1\r
        ST: urn:schemas-upnp-org:device:ZonePlayer:1\r
        \r

        """

        do {
            let socket = try Socket()
            try socket.send(ssdpMessage, to: "239.255.255.250", port: 1900)

            // Listen for responses
            let timeout = DispatchTime.now() + .seconds(3)
            var foundDevices: [SonosDevice] = []

            while DispatchTime.now() < timeout {
                if let response = try? socket.receive(timeout: 1.0) {
                    if let device = parseSSDPResponse(response.data, from: response.address) {
                        foundDevices.append(device)
                    }
                }
            }

            DispatchQueue.main.async {
                // Deduplicate devices by name (keeps first occurrence)
                var uniqueDevices: [SonosDevice] = []
                var seenNames = Set<String>()

                for device in foundDevices {
                    if !seenNames.contains(device.name) {
                        uniqueDevices.append(device)
                        seenNames.insert(device.name)
                    }
                }

                // Apply cached topology if available
                if !self.topologyCache.isEmpty {
                    uniqueDevices = uniqueDevices.map { device in
                        if let coordinatorUUID = self.topologyCache[device.uuid] {
                            return SonosDevice(
                                name: device.name,
                                ipAddress: device.ipAddress,
                                uuid: device.uuid,
                                isCoordinator: device.uuid == coordinatorUUID,
                                coordinatorUUID: coordinatorUUID
                            )
                        }
                        return device
                    }
                    print("Applied cached topology to \(uniqueDevices.count) devices")
                }

                self.devices = uniqueDevices
                print("Found \(foundDevices.count) Sonos devices (\(uniqueDevices.count) unique)")
                for device in uniqueDevices {
                    let role = device.isCoordinator ? " (Coordinator)" : ""
                    print("  - \(device.name) at \(device.ipAddress)\(role)")
                }

                // Only fetch topology if not cached
                if !self.hasLoadedTopology {
                    print("Fetching initial group topology...")
                    self.updateGroupTopology()
                    self.hasLoadedTopology = true
                } else {
                    print("Using cached topology (refresh to update)")
                }

                // Post notification so menu can update
                NotificationCenter.default.post(name: NSNotification.Name("SonosDevicesDiscovered"), object: nil)
            }
        } catch {
            print("SSDP Discovery error: \(error)")
        }
    }

    private func updateGroupTopology() {
        // Pick any device to query group topology (all devices know about all groups)
        guard let anyDevice = devices.first else { return }

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

            self.parseGroupTopology(responseStr)
        }.resume()

        _ = semaphore.wait(timeout: .now() + 3)
    }

    private func parseGroupTopology(_ xml: String) {
        // Extract ZoneGroupState XML from SOAP response
        guard let stateRange = xml.range(of: "<ZoneGroupState>([\\s\\S]*?)</ZoneGroupState>", options: .regularExpression) else {
            print("Could not find ZoneGroupState in response")
            return
        }

        let stateXML = String(xml[stateRange])

        // Parse each ZoneGroup to find coordinators
        let groupPattern = "<ZoneGroup Coordinator=\"([^\"]+)\"[^>]*>([\\s\\S]*?)</ZoneGroup>"
        let regex = try? NSRegularExpression(pattern: groupPattern, options: [])
        let nsString = stateXML as NSString
        let matches = regex?.matches(in: stateXML, options: [], range: NSRange(location: 0, length: nsString.length)) ?? []

        var groupInfo: [String: String] = [:]  // UUID -> Coordinator UUID

        for match in matches {
            if match.numberOfRanges >= 3 {
                let coordinatorUUID = nsString.substring(with: match.range(at: 1))
                let membersXML = nsString.substring(with: match.range(at: 2))

                // Find all members in this group
                let memberPattern = "<ZoneGroupMember UUID=\"([^\"]+)\""
                let memberRegex = try? NSRegularExpression(pattern: memberPattern, options: [])
                let memberMatches = memberRegex?.matches(in: membersXML, options: [], range: NSRange(location: 0, length: (membersXML as NSString).length)) ?? []

                for memberMatch in memberMatches {
                    if memberMatch.numberOfRanges >= 2 {
                        let memberUUID = (membersXML as NSString).substring(with: memberMatch.range(at: 1))
                        groupInfo[memberUUID] = coordinatorUUID
                    }
                }
            }
        }

        // Store in cache for future use
        topologyCache = groupInfo
        print("Cached topology for \(groupInfo.count) devices")

        // Update devices with coordinator information
        devices = devices.map { device in
            if let coordinatorUUID = groupInfo[device.uuid] {
                return SonosDevice(
                    name: device.name,
                    ipAddress: device.ipAddress,
                    uuid: device.uuid,
                    isCoordinator: device.uuid == coordinatorUUID,
                    coordinatorUUID: coordinatorUUID
                )
            }
            return device
        }

        print("Updated group topology:")
        for device in devices {
            let role = device.isCoordinator ? "(Coordinator)" : ""
            print("  - \(device.name) \(role)")
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
            isCoordinator: false,  // Will be updated later
            coordinatorUUID: nil   // Will be updated later
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
            print("Selected Sonos device: \(device.name)")
        }
    }

    func getCurrentVolume(completion: @escaping (Int?) -> Void) {
        guard let device = selectedDevice else {
            completion(nil)
            return
        }

        // Query coordinator if device is part of a group
        let targetDevice: SonosDevice
        if let coordinatorUUID = device.coordinatorUUID,
           let coordinator = devices.first(where: { $0.uuid == coordinatorUUID }) {
            targetDevice = coordinator
        } else {
            targetDevice = device
        }

        sendSonosCommand(to: targetDevice, action: "GetVolume") { volumeStr in
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

        // Find the coordinator for this device
        let targetDevice: SonosDevice
        if let coordinatorUUID = device.coordinatorUUID,
           let coordinator = devices.first(where: { $0.uuid == coordinatorUUID }) {
            targetDevice = coordinator
        } else {
            targetDevice = device
        }

        sendSonosCommand(to: targetDevice, action: "GetVolume") { volumeStr in
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

        // Find the coordinator for this device
        let targetDevice: SonosDevice
        if let coordinatorUUID = device.coordinatorUUID,
           let coordinator = devices.first(where: { $0.uuid == coordinatorUUID }) {
            targetDevice = coordinator
        } else {
            targetDevice = device
        }

        let clampedVolume = max(0, min(100, volume))
        sendSonosCommand(to: targetDevice, action: "SetVolume", arguments: ["DesiredVolume": String(clampedVolume)])

        // Show HUD with new volume
        Task { @MainActor in
            VolumeHUD.shared.show(speaker: device.name, volume: clampedVolume)
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

        // Find the coordinator for this device (for stereo pairs/groups)
        let targetDevice: SonosDevice
        if let coordinatorUUID = device.coordinatorUUID,
           let coordinator = devices.first(where: { $0.uuid == coordinatorUUID }) {
            targetDevice = coordinator
            print("🎚️ Changing volume by \(delta) for \(device.name) via coordinator \(coordinator.name)")
        } else {
            targetDevice = device
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

            // Show HUD with new volume
            Task { @MainActor in
                VolumeHUD.shared.show(speaker: device.name, volume: newVolume)
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