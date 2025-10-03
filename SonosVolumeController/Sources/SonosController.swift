import Foundation
import Network

actor SonosController {
    private let settings: AppSettings
    private let networkClient: SonosNetworkClient
    private var devices: [SonosDevice] = []
    private var groups: [SonosGroup] = []
    private var _selectedDevice: SonosDevice?
    private var selectedGroup: SonosGroup?

    // Topology cache - persists during app session
    private var topologyCache: [String: String] = [:]  // UUID -> Coordinator UUID
    private var hasLoadedTopology = false

    // Topology snapshot for change detection
    private var lastTopologySnapshot: String?

    // Thread-safe copies for UI access (updated when internal state changes)
    // Using nonisolated(unsafe) because these are only written from actor context
    // and read from nonisolated context, providing thread-safety through careful usage
    nonisolated(unsafe) private var _cachedDevices: [SonosDevice] = []
    nonisolated(unsafe) private var _cachedGroups: [SonosGroup] = []
    nonisolated(unsafe) private var _cachedSelectedDevice: SonosDevice?

    // Expose selected device (actor-isolated)
    var selectedDevice: SonosDevice? {
        return _selectedDevice
    }

    // Expose devices for menu population (actor-isolated)
    var discoveredDevices: [SonosDevice] {
        return devices
    }

    // Expose groups for UI (actor-isolated)
    var discoveredGroups: [SonosGroup] {
        return groups
    }

    // MARK: - Nonisolated accessors for UI
    // These return cached copies that are safe to access from any thread

    nonisolated var cachedDiscoveredDevices: [SonosDevice] {
        return _cachedDevices
    }

    nonisolated var cachedDiscoveredGroups: [SonosGroup] {
        return _cachedGroups
    }

    nonisolated var cachedSelectedDevice: SonosDevice? {
        return _cachedSelectedDevice
    }

    // Helper to update cached values (must be called from actor context)
    private func updateCachedValues() {
        _cachedDevices = devices
        _cachedGroups = groups
        _cachedSelectedDevice = _selectedDevice
    }

    // MARK: - Real-time Event Subscription

    private var eventListener: UPnPEventListener?
    private var eventProcessingTask: Task<Void, Never>?
    private var coordinatorSubscriptions: [String: String] = [:]  // UUID -> SID

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
        self.networkClient = SonosNetworkClient()
    }

    func discoverDevices(forceRefreshTopology: Bool = false, completion: (@Sendable () -> Void)? = nil) {
        print("Discovering Sonos devices...")

        // Notify UI that discovery is starting
        Task { @MainActor in
            NotificationCenter.default.post(name: NSNotification.Name("SonosDiscoveryStarted"), object: nil)
        }

        // Clear cache if forced refresh is requested
        if forceRefreshTopology {
            print("Clearing topology cache for fresh discovery")
            topologyCache.removeAll()
            hasLoadedTopology = false
        }

        // Use SSDP (Simple Service Discovery Protocol) to find Sonos devices
        Task {
            await performSSDPDiscovery(completion: completion)
        }
    }

    private func performSSDPDiscovery(completion: (@Sendable () -> Void)? = nil) async {
        do {
            let discoveryService = SSDPDiscoveryService()
            let discoveredDevices = try await discoveryService.discoverDevices()

            // Convert discovery results to SonosDevice
            // Topology information (group membership, stereo pairs) will be updated later
            let devices = discoveredDevices.map { result in
                SonosDevice(
                    name: result.name,
                    ipAddress: result.ipAddress,
                    uuid: result.uuid,
                    isGroupCoordinator: false,      // Will be updated after topology loads
                    groupCoordinatorUUID: nil,      // Will be updated after topology loads
                    channelMapSet: nil,             // Will be updated after topology loads
                    pairPartnerUUID: nil            // Will be updated after topology loads
                )
            }

            self.devices = devices
            self.updateCachedValues() // Update thread-safe copies

            // Only fetch topology if not cached
            let needsTopology = !self.hasLoadedTopology
            if needsTopology {
                print("Fetching initial group topology...")
                await self.updateGroupTopology(completion: completion)
                self.hasLoadedTopology = true
            } else {
                print("Using cached topology (refresh to update)")
                // Call completion immediately if using cached topology
                completion?()
            }

            // Post notification so menu can update - needs to be on MainActor
            await MainActor.run {
                NotificationCenter.default.post(name: NSNotification.Name("SonosDevicesDiscovered"), object: nil)
            }
        } catch {
            print("SSDP Discovery error: \(error)")

            // Notify about network error (likely permissions issue)
            Task { @MainActor in
                NotificationCenter.default.post(
                    name: NSNotification.Name("SonosNetworkError"),
                    object: nil,
                    userInfo: ["error": error.localizedDescription]
                )
            }
        }
    }

    private func updateGroupTopology(completion: (@Sendable () -> Void)? = nil) async {
        // Pick any device to query group topology (all devices know about all groups)
        guard let anyDevice = devices.first else {
            completion?()
            return
        }

        do {
            let request = SonosNetworkClient.SOAPRequest(
                service: .zoneGroupTopology,
                action: "GetZoneGroupState"
            )
            let data = try await networkClient.sendSOAPRequest(request, to: anyDevice.ipAddress)

            guard let responseStr = String(data: data, encoding: .utf8) else {
                print("Failed to decode response")
                return
            }

            parseGroupTopology(responseStr, completion: completion)
        } catch {
            print("GetZoneGroupState error: \(error)")
        }
    }

    private func parseGroupTopology(_ xml: String, completion: (@Sendable () -> Void)? = nil) {
        // Extract ZoneGroupState XML from SOAP response
        guard let stateXML = XMLParsingHelpers.extractSection(from: xml, tag: "ZoneGroupState") else {
            print("Could not find ZoneGroupState in response")
            completion?()
            return
        }

        // Decode HTML entities to parse actual XML structure
        let decodedXML = XMLParsingHelpers.decodeHTMLEntities(stateXML)

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

        // Update devices with coordinator information
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
            updateCachedValues() // Update thread-safe copies after updating devices

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

        // Check if topology actually changed before notifying UI
        let newSnapshot = generateTopologySnapshot()
        let topologyChanged = newSnapshot != lastTopologySnapshot

        if topologyChanged {
            print("📊 Topology changed, notifying UI")
            lastTopologySnapshot = newSnapshot

            // Notify that devices have changed (for UI updates)
            Task { @MainActor in
                NotificationCenter.default.post(name: NSNotification.Name("SonosDevicesDiscovered"), object: nil)
            }
        } else {
            print("📊 Topology unchanged, skipping UI update")
        }

        // Call completion handler
        completion?()
    }

    /// Generate a snapshot signature of the current topology for change detection
    private func generateTopologySnapshot() -> String {
        // Create a sorted list of groups with their members
        // This captures all meaningful topology changes (grouping/ungrouping)
        let groupSignatures = groups
            .sorted { $0.id < $1.id }
            .map { group in
                let memberUUIDs = group.members
                    .map { $0.uuid }
                    .sorted()
                    .joined(separator: ",")
                return "\(group.id):[\(memberUUIDs)]"
            }
            .joined(separator: ";")

        return groupSignatures
    }


    func selectDevice(name: String) {
        _selectedDevice = devices.first { $0.name == name }
        updateCachedValues() // Update thread-safe copies
        if let device = _selectedDevice {
            // Track this device as last active
            settings.trackSpeakerActivity(device.name)

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
            updateCachedValues() // Update thread-safe copies
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
        updateCachedValues() // Update thread-safe copies
    }

    // MARK: - Real-time Topology Monitoring

    /// Start monitoring topology changes via UPnP event subscriptions
    func startTopologyMonitoring() async throws {
        print("🎧 Starting topology monitoring...")

        // Create event listener if needed
        if eventListener == nil {
            let listener = try await UPnPEventListener()
            eventListener = listener

            // Start processing events - capture listener to avoid actor isolation issues
            eventProcessingTask = Task { [weak self] in
                for await event in listener.events {
                    await self?.handleTopologyEvent(event)
                }
            }
        }

        // Subscribe to coordinator devices
        await subscribeToCoordinators()

        print("✅ Topology monitoring started")
    }

    /// Stop monitoring topology changes
    func stopTopologyMonitoring() async {
        print("🛑 Stopping topology monitoring...")

        // Cancel event processing
        eventProcessingTask?.cancel()
        eventProcessingTask = nil

        // Shutdown event listener
        if let listener = eventListener {
            await listener.shutdown()
        }

        eventListener = nil
        coordinatorSubscriptions.removeAll()

        print("✅ Topology monitoring stopped")
    }

    /// Subscribe to all coordinator devices
    private func subscribeToCoordinators() async {
        print("📡 Subscribing to coordinators...")

        guard let listener = eventListener else { return }

        // Find unique coordinators
        let coordinatorUUIDs = Set(devices.compactMap { $0.groupCoordinatorUUID })
        let coordinators = coordinatorUUIDs.compactMap { uuid in
            devices.first { $0.uuid == uuid }
        }

        print("   Found \(coordinators.count) coordinators")

        for coordinator in coordinators {
            // Skip if already subscribed
            if coordinatorSubscriptions[coordinator.uuid] != nil {
                print("   Already subscribed to \(coordinator.name)")
                continue
            }

            do {
                let sid = try await listener.subscribe(
                    deviceUUID: coordinator.uuid,
                    deviceIP: coordinator.ipAddress,
                    service: .zoneGroupTopology
                )

                coordinatorSubscriptions[coordinator.uuid] = sid
                print("   ✅ Subscribed to \(coordinator.name) (SID: \(sid))")

            } catch {
                print("   ⚠️ Failed to subscribe to \(coordinator.name): \(error)")
            }
        }
    }

    /// Handle incoming topology events
    private func handleTopologyEvent(_ event: UPnPEventListener.TopologyEvent) async {
        switch event {
        case .topologyChanged(let xml):
            print("🔄 Topology changed - updating...")

            // Parse the new topology (this will post SonosDevicesDiscovered notification)
            parseGroupTopology(xml, completion: nil)

            // Resubscribe to any new coordinators
            await subscribeToCoordinators()

            print("✅ Topology updated from event")

        case .coordinatorChanged(let oldUUID, let newUUID):
            print("🔄 Coordinator changed: \(oldUUID) -> \(newUUID)")

            // Unsubscribe from old coordinator if we were subscribed
            if let oldSID = coordinatorSubscriptions[oldUUID] {
                try? await eventListener?.unsubscribe(sid: oldSID)
                coordinatorSubscriptions.removeValue(forKey: oldUUID)
            }

            // Subscribe to new coordinator
            if let newCoordinator = devices.first(where: { $0.uuid == newUUID }) {
                do {
                    let sid = try await eventListener?.subscribe(
                        deviceUUID: newCoordinator.uuid,
                        deviceIP: newCoordinator.ipAddress,
                        service: .zoneGroupTopology
                    )

                    if let sid = sid {
                        coordinatorSubscriptions[newCoordinator.uuid] = sid
                        print("✅ Subscribed to new coordinator: \(newCoordinator.name)")
                    }
                } catch {
                    print("⚠️ Failed to subscribe to new coordinator: \(error)")
                }
            }

        case .subscriptionExpired(let sid):
            print("⚠️ Subscription expired: \(sid)")

            // Find and remove the expired subscription
            for (uuid, subscriptionSID) in coordinatorSubscriptions {
                if subscriptionSID == sid {
                    coordinatorSubscriptions.removeValue(forKey: uuid)

                    // Try to resubscribe
                    if let device = devices.first(where: { $0.uuid == uuid }) {
                        do {
                            let newSID = try await eventListener?.subscribe(
                                deviceUUID: device.uuid,
                                deviceIP: device.ipAddress,
                                service: .zoneGroupTopology
                            )

                            if let newSID = newSID {
                                coordinatorSubscriptions[uuid] = newSID
                                print("✅ Resubscribed to \(device.name) after expiration")
                            }
                        } catch {
                            print("⚠️ Failed to resubscribe after expiration: \(error)")
                        }
                    }

                    break
                }
            }
        }
    }

    // MARK: - Helper Methods

    /// Get the group that contains the given device (only if it's a multi-speaker group)
    func getGroupForDevice(_ device: SonosDevice) -> SonosGroup? {
        guard let coordUUID = device.groupCoordinatorUUID else { return nil }

        // Find the group and make sure it has more than 1 member
        return groups.first(where: { $0.coordinatorUUID == coordUUID && $0.members.count > 1 })
    }

    // Nonisolated version for UI access
    nonisolated func getCachedGroupForDevice(_ device: SonosDevice) -> SonosGroup? {
        guard let coordUUID = device.groupCoordinatorUUID else { return nil }

        // Find the group and make sure it has more than 1 member
        return _cachedGroups.first(where: { $0.coordinatorUUID == coordUUID && $0.members.count > 1 })
    }

    func getCurrentVolume(completion: @escaping @Sendable (Int?) -> Void) {
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

    func getVolume(completion: @escaping @Sendable (Int) -> Void) {
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

    /// Get volume for a specific device, bypassing group logic
    /// Used for reading individual speaker volumes within a group
    /// - Parameters:
    ///   - device: The specific device to query
    ///   - completion: Callback with volume level (0-100) or nil if failed
    func getIndividualVolume(device: SonosDevice, completion: @escaping @Sendable (Int?) -> Void) {
        // Always query individual speaker volume, even if in a group
        // This bypasses the group-aware logic in getCurrentVolume()
        sendSonosCommand(to: device, action: "GetVolume") { volumeStr in
            completion(Int(volumeStr))
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

    nonisolated private func sendSonosCommand(to device: SonosDevice, action: String, arguments: [String: String] = [:], completion: (@Sendable (String) -> Void)? = nil) {
        // Build arguments with required defaults for RenderingControl
        var fullArguments = arguments
        fullArguments["InstanceID"] = "0"
        fullArguments["Channel"] = "Master"

        let request = SonosNetworkClient.SOAPRequest(
            service: .renderingControl,
            action: action,
            arguments: fullArguments
        )

        networkClient.sendSOAPRequest(request, to: device.ipAddress) { data, error in
            if let error = error {
                print("Sonos command error: \(error)")
                return
            }

            if let data = data, let responseStr = String(data: data, encoding: .utf8) {
                // Extract value using XML helpers
                if let completion = completion {
                    if let value = XMLParsingHelpers.extractValue(from: responseStr, tagPattern: "Current[^>]*") {
                        completion(value)
                    }
                }
            }
        }
    }

    // MARK: - Group Management Commands

    /// Add a device to an existing group (or create a new group)
    /// Uses AVTransport SetAVTransportURI with x-rincon URI
    func addDeviceToGroup(device: SonosDevice, coordinatorUUID: String, shouldRefreshTopology: Bool = true, completion: (@Sendable (Bool) -> Void)? = nil) {
        guard let coordinator = devices.first(where: { $0.uuid == coordinatorUUID }) else {
            print("❌ Coordinator not found: \(coordinatorUUID)")
            completion?(false)
            return
        }

        print("🔗 Adding \(device.name) (UUID: \(device.uuid)) to group led by \(coordinator.name) (UUID: \(coordinatorUUID))")

        // Check if devices are already grouped
        if let deviceGroup = getGroupForDevice(device),
           let coordGroup = getGroupForDevice(coordinator),
           deviceGroup.id == coordGroup.id {
            print("⚠️ Devices are already in the same group")
            completion?(true)
            return
        }

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

        print("📤 Sending SetAVTransportURI to \(device.ipAddress)")
        print("   Target URI: x-rincon:\(coordinatorUUID)")

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
                    print("❌ Failed to add \(device.name) to group - HTTP \(httpResponse.statusCode)")
                    if let data = data, let responseStr = String(data: data, encoding: .utf8) {
                        print("   Response: \(responseStr)")
                        // Parse UPnP error code if available
                        if let errorRange = responseStr.range(of: "<errorCode>([^<]+)</errorCode>", options: .regularExpression) {
                            let errorString = String(responseStr[errorRange])
                            let errorCode = errorString.replacingOccurrences(of: "<errorCode>", with: "").replacingOccurrences(of: "</errorCode>", with: "")
                            print("   UPnP Error Code: \(errorCode)")
                        }
                    }
                    DispatchQueue.main.async {
                        completion?(false)
                    }
                    return
                }
            }

            print("✅ Successfully added \(device.name) to group")

            // Optionally refresh topology before calling completion
            if shouldRefreshTopology {
                Task { [weak self] in
                    // Wait a bit before refreshing topology
                    try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 seconds
                    guard let self = self else { return }

                    await self.updateGroupTopology {
                        DispatchQueue.main.async {
                            completion?(true)
                        }
                    }
                }
            } else {
                DispatchQueue.main.async {
                    completion?(true)
                }
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
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                await self?.updateGroupTopology(completion: nil)
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
    func createGroup(devices deviceList: [SonosDevice], coordinatorDevice: SonosDevice? = nil, completion: (@Sendable (Bool) -> Void)? = nil) {
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
            Task { [weak self] in
                await self?.performGrouping(devices: deviceList, coordinator: explicitCoordinator, completion: completion)
            }
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
                // No devices playing, prefer non-stereo-pair as coordinator
                let nonStereoPairDevices = deviceList.filter { $0.channelMapSet == nil }
                if !nonStereoPairDevices.isEmpty {
                    coordinator = nonStereoPairDevices.first!
                    print("📍 No devices playing, using first non-stereo-pair as coordinator: \(coordinator.name)")
                } else {
                    coordinator = deviceList.first!
                    print("📍 No devices playing, using first device as coordinator: \(coordinator.name)")
                }
            } else if playingDevices.count == 1 {
                // One device playing, use it as coordinator to preserve playback
                coordinator = playingDevices.first!
                print("🎵 One device playing, using it as coordinator to preserve audio: \(coordinator.name)")
                if coordinator.channelMapSet != nil {
                    print("⚠️ Coordinator is a stereo pair - grouping may fail (Sonos limitation)")
                }
            } else {
                // Multiple devices playing - prefer non-stereo-pair
                let nonStereoPairPlaying = playingDevices.filter { $0.channelMapSet == nil }
                if !nonStereoPairPlaying.isEmpty {
                    coordinator = nonStereoPairPlaying.first!
                    print("⚠️ Multiple devices playing, choosing first non-stereo-pair: \(coordinator.name)")
                } else {
                    coordinator = playingDevices.first!
                    print("⚠️ Multiple devices playing (\(playingDevices.count)), defaulting to first: \(coordinator.name)")
                }
                print("   Note: Other playing devices will stop playback")
            }

            Task { [weak self] in
                await self?.performGrouping(devices: deviceList, coordinator: coordinator, completion: completion)
            }
        }
    }

    /// Internal helper to perform the actual grouping with a specified coordinator
    /// If retry is true and coordinator is a stereo pair, will automatically retry with a different coordinator on failure
    private func performGrouping(devices: [SonosDevice], coordinator: SonosDevice, retry: Bool = true, completion: (@Sendable (Bool) -> Void)?) {
        print("🎵 Creating group with coordinator: \(coordinator.name)")

        // Check if coordinator is currently playing - we'll resume it after grouping
        getTransportState(device: coordinator) { [weak self] initialState in
            guard let self = self else { return }
            let coordinatorWasPlaying = (initialState == "PLAYING")
            if coordinatorWasPlaying {
                print("📝 Coordinator is playing - will resume after grouping if needed")
            }

            Task { [weak self] in
                await self?.performGroupingInternal(devices: devices, coordinator: coordinator, coordinatorWasPlaying: coordinatorWasPlaying, retry: retry, completion: completion)
            }
        }
    }

    /// Internal grouping logic after checking coordinator state
    private func performGroupingInternal(devices: [SonosDevice], coordinator: SonosDevice, coordinatorWasPlaying: Bool, retry: Bool, completion: (@Sendable (Bool) -> Void)?) {
        let membersToAdd = devices.filter { $0.uuid != coordinator.uuid }
        let dispatchGroup = DispatchGroup()
        let queue = DispatchQueue(label: "com.sonos.grouping")
        var successCount = 0

        // Add each member to the coordinator's group
        for member in membersToAdd {
            dispatchGroup.enter()
            addDeviceToGroup(device: member, coordinatorUUID: coordinator.uuid, shouldRefreshTopology: false) { success in
                queue.async {
                    if success {
                        successCount += 1
                    }
                    dispatchGroup.leave()
                }
            }
        }

        // Wait for all additions to complete
        dispatchGroup.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            let allSuccess = successCount == membersToAdd.count
            print(allSuccess ? "✅ All members added (\(successCount)/\(membersToAdd.count))" : "⚠️ Some members failed to add (\(successCount)/\(membersToAdd.count))")

            // If failed and coordinator is a stereo pair, retry with different coordinator
            if !allSuccess && retry && coordinator.channelMapSet != nil && membersToAdd.count == 1 {
                print("🔄 Retrying with \(membersToAdd[0].name) as coordinator (stereo pair limitation)")
                Task { [weak self] in
                    await self?.performGrouping(devices: devices, coordinator: membersToAdd[0], retry: false, completion: completion)
                }
                return
            }

            // Refresh topology once after all additions complete
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 seconds
                guard let self = self else { return }

                await self.updateGroupTopology {
                    // If coordinator was playing, check if it's still playing and resume if needed
                    if coordinatorWasPlaying {
                        Task { [weak self] in
                            guard let self = self else { return }
                            await self.getTransportState(device: coordinator) { state in
                                if state != "PLAYING" {
                                    print("🔄 Coordinator paused during grouping - resuming playback")
                                    Task { [weak self] in
                                        guard let self = self else { return }
                                        await self.sendPlayCommand(to: coordinator)
                                    }
                                }
                            }
                        }
                    }

                    print(allSuccess ? "✅ Group created successfully" : "⚠️ Group created with some failures")
                    completion?(allSuccess)
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

    /// Send Play command to a device
    /// Uses AVTransport Play
    private func sendPlayCommand(to device: SonosDevice) {
        let url = URL(string: "http://\(device.ipAddress):1400/MediaRenderer/AVTransport/Control")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.addValue("\"urn:schemas-upnp-org:service:AVTransport:1#Play\"", forHTTPHeaderField: "SOAPACTION")

        let soapBody = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
            <s:Body>
                <u:Play xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
                    <InstanceID>0</InstanceID>
                    <Speed>1</Speed>
                </u:Play>
            </s:Body>
        </s:Envelope>
        """

        request.httpBody = soapBody.data(using: .utf8)

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("❌ Failed to send play command: \(error)")
                return
            }
            print("▶️ Play command sent to \(device.name)")
        }.resume()
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
    func getGroupVolume(group: SonosGroup, completion: @escaping @Sendable (Int?) -> Void) {
        let coordinator = group.coordinator
        print("🎚️ Getting group volume for: \(group.displayName)")

        let request = SonosNetworkClient.SOAPRequest(
            service: .groupRenderingControl,
            action: "GetGroupVolume",
            arguments: ["InstanceID": "0"]
        )

        networkClient.sendSOAPRequest(request, to: coordinator.ipAddress) { data, error in
            if let error = error {
                print("❌ Failed to get group volume: \(error)")
                completion(nil)
                return
            }

            guard let data = data, let responseStr = String(data: data, encoding: .utf8) else {
                completion(nil)
                return
            }

            // Parse volume from response using XML helpers
            if let volume = XMLParsingHelpers.extractIntValue(from: responseStr, tag: "CurrentVolume") {
                print("   Group volume: \(volume)")
                completion(volume)
            } else {
                completion(nil)
            }
        }
    }

    /// Snapshot the current group volume ratios
    /// This captures the relative volume between all players for use by SetGroupVolume
    /// Must be called on the group coordinator before SetGroupVolume
    private func snapshotGroupVolume(group: SonosGroup, completion: @escaping @Sendable (Bool) -> Void) {
        let coordinator = group.coordinator
        print("📸 Taking group volume snapshot for \(group.displayName)")

        let request = SonosNetworkClient.SOAPRequest(
            service: .groupRenderingControl,
            action: "SnapshotGroupVolume",
            arguments: ["InstanceID": "0"]
        )

        networkClient.sendSOAPRequest(request, to: coordinator.ipAddress) { data, error in
            if let error = error {
                print("❌ Failed to snapshot group volume: \(error)")
                completion(false)
                return
            }

            print("✅ Group volume snapshot captured")
            completion(true)
        }
    }

    /// Set the group volume (proportionally adjusts all members)
    /// Must be called on the group coordinator
    func setGroupVolume(group: SonosGroup, volume: Int) {
        let coordinator = group.coordinator
        let clampedVolume = max(0, min(100, volume))
        print("🎚️ ========================================")
        print("🎚️ Setting group volume for \(group.displayName) to \(clampedVolume)")
        print("🎚️ Group has \(group.members.count) members:")
        for member in group.members {
            print("🎚️   - \(member.name)")
        }
        print("🎚️ Step 1: Taking snapshot to capture current speaker ratios")
        print("🎚️ Step 2: SetGroupVolume will use snapshot to maintain ratios")
        print("🎚️ ========================================")

        // First, snapshot the current volume ratios
        snapshotGroupVolume(group: group) { [weak self] success in
            guard let self = self, success else {
                print("❌ Failed to snapshot group volume, aborting SetGroupVolume")
                return
            }

            // Now set the group volume with the captured ratios using network client
            Task {
                do {
                    try await self.networkClient.setGroupVolume(clampedVolume, for: coordinator.ipAddress)
                    print("✅ Group volume set to \(clampedVolume) with snapshot-preserved ratios")

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
                } catch {
                    print("❌ Failed to set group volume: \(error)")
                }
            }
        }
    }

    /// Adjust group volume by a relative amount (+/-)
    /// Ideal for volume up/down buttons
    func changeGroupVolume(group: SonosGroup, by delta: Int) {
        let coordinator = group.coordinator
        print("🎚️ Changing group volume for \(group.displayName) by \(delta)")

        Task { [weak self] in
            guard let self = self else { return }

            do {
                try await self.networkClient.setRelativeGroupVolume(delta, for: coordinator.ipAddress)

                // Get the new volume to show in HUD
                await self.getGroupVolume(group: group) { newVolume in
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
            } catch {
                print("❌ Failed to change group volume: \(error)")
            }
        }
    }
}

