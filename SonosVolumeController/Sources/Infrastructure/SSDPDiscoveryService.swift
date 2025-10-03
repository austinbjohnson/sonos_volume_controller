import Foundation

/// Result from SSDP device discovery containing basic device information.
/// Additional topology information (group membership, stereo pairs) is loaded separately.
struct SSDPDiscoveryResult {
    let name: String
    let ipAddress: String
    let uuid: String
}

/// Service responsible for discovering Sonos devices on the local network using SSDP
/// (Simple Service Discovery Protocol). Handles multicast discovery, response parsing,
/// and device information fetching.
actor SSDPDiscoveryService {

    // MARK: - Constants

    private enum Constants {
        static let multicastAddress = "239.255.255.250"
        static let multicastPort: UInt16 = 1900
        static let discoveryTimeout: UInt64 = 5_000_000_000 // 5 seconds in nanoseconds
        static let packetDelay: UInt64 = 500_000_000 // 500ms in nanoseconds
        static let deviceInfoTimeout: TimeInterval = 3.0

        static let ssdpMessage = """
        M-SEARCH * HTTP/1.1\r
        HOST: 239.255.255.250:1900\r
        MAN: "ssdp:discover"\r
        MX: 3\r
        ST: urn:schemas-upnp-org:device:ZonePlayer:1\r
        \r

        """
    }

    // MARK: - Public Methods

    /// Discovers Sonos devices on the local network using SSDP multicast.
    /// Sends multiple discovery packets and listens for responses over a 5-second window.
    /// - Returns: Array of discovered devices with their basic information
    /// - Throws: Network or socket errors
    func discoverDevices() async throws -> [SSDPDiscoveryResult] {
        let socket = try SSDPSocket()

        // Send multiple discovery packets to improve reliability
        print("📡 Sending discovery packet 1/3...")
        try socket.send(Constants.ssdpMessage, to: Constants.multicastAddress, port: Constants.multicastPort)

        try await Task.sleep(nanoseconds: Constants.packetDelay)

        print("📡 Sending discovery packet 2/3...")
        try socket.send(Constants.ssdpMessage, to: Constants.multicastAddress, port: Constants.multicastPort)

        try await Task.sleep(nanoseconds: Constants.packetDelay)

        print("📡 Sending discovery packet 3/3...")
        try socket.send(Constants.ssdpMessage, to: Constants.multicastAddress, port: Constants.multicastPort)

        // Listen for responses
        let timeout = DispatchTime.now() + .nanoseconds(Int(Constants.discoveryTimeout))
        var foundDevices: [SSDPDiscoveryResult] = []

        print("👂 Listening for responses...")
        while DispatchTime.now() < timeout {
            if let response = try? socket.receive(timeout: 1.0) {
                if let device = parseSSDPResponse(response.data, from: response.address) {
                    foundDevices.append(device)
                }
            }
        }

        // Deduplicate by UUID
        var uniqueDevices: [SSDPDiscoveryResult] = []
        var seenUUIDs = Set<String>()

        for device in foundDevices {
            if !seenUUIDs.contains(device.uuid) {
                uniqueDevices.append(device)
                seenUUIDs.insert(device.uuid)
            }
        }

        print("Found \(foundDevices.count) Sonos devices (\(uniqueDevices.count) unique)")
        for device in uniqueDevices {
            print("  - \(device.name) at \(device.ipAddress)")
        }

        return uniqueDevices
    }

    // MARK: - Private Methods

    /// Parses SSDP response data to extract device location and fetch device details.
    private func parseSSDPResponse(_ data: String, from address: String) -> SSDPDiscoveryResult? {
        // Extract location URL from SSDP response headers
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

        return SSDPDiscoveryResult(
            name: deviceName,
            ipAddress: host,
            uuid: uuid ?? location
        )
    }

    /// Fetches device information (name and UUID) from the device's description XML.
    /// Uses synchronous networking with a short timeout since this is called during discovery.
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

        _ = semaphore.wait(timeout: .now() + Constants.deviceInfoTimeout)
        return (resultName, resultUUID)
    }
}
