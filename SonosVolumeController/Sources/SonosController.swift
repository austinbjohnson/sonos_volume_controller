import Foundation
import Network
import AppKit

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

    // Album art image cache (thread-safe NSCache)
    private let albumArtCache = NSCache<NSString, NSImage>()

    // Topology snapshot for change detection
    private var lastTopologySnapshot: String?

    // Thread-safe copies for UI access (updated when internal state changes)
    // Using nonisolated(unsafe) because these are only written from actor context
    // and read from nonisolated context, providing thread-safety through careful usage
    nonisolated(unsafe) private var _cachedDevices: [SonosDevice] = []
    nonisolated(unsafe) private var _cachedGroups: [SonosGroup] = []
    nonisolated(unsafe) private var _cachedSelectedDevice: SonosDevice?
    nonisolated(unsafe) private var _cachedLastRefreshDate: Date?
    nonisolated(unsafe) private var _cachedLastRefreshErrorDate: Date?

    private var lastRefreshDate: Date?
    private var lastRefreshErrorDate: Date?

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

    nonisolated var cachedLastRefreshDate: Date? {
        return _cachedLastRefreshDate
    }

    nonisolated var cachedLastRefreshErrorDate: Date? {
        return _cachedLastRefreshErrorDate
    }

    // Helper to update cached values (must be called from actor context)
    private func updateCachedValues() {
        _cachedDevices = devices
        _cachedGroups = groups
        _cachedSelectedDevice = _selectedDevice
        _cachedLastRefreshDate = lastRefreshDate
        _cachedLastRefreshErrorDate = lastRefreshErrorDate
    }

    private func updateCachedRefreshStatus() {
        _cachedLastRefreshDate = lastRefreshDate
        _cachedLastRefreshErrorDate = lastRefreshErrorDate
    }

    private func notifyRefreshStatusChanged() {
        Task { @MainActor in
            NotificationCenter.default.post(name: NSNotification.Name("SonosRefreshStatusChanged"), object: nil)
        }
    }

    private func markRefreshSuccess() {
        lastRefreshDate = Date()
        lastRefreshErrorDate = nil
        updateCachedRefreshStatus()
        notifyRefreshStatusChanged()
    }

    private func markRefreshFailure() {
        lastRefreshErrorDate = Date()
        updateCachedRefreshStatus()
        notifyRefreshStatusChanged()
    }

    // MARK: - Real-time Event Subscription

    private var eventListener: UPnPEventListener?
    private var eventProcessingTask: Task<Void, Never>?
    private var transportEventProcessingTask: Task<Void, Never>?
    private var coordinatorSubscriptions: [String: String] = [:]  // UUID -> SID
    private var transportSubscriptions: [String: String] = [:]    // UUID -> SID (for active speaker)
    private var satelliteToVisibleMap: [String: String] = [:]     // Satellite UUID -> Visible Speaker UUID

    struct SonosDevice {
        let name: String
        let ipAddress: String
        let uuid: String
        let isGroupCoordinator: Bool      // True if this is the group coordinator
        let groupCoordinatorUUID: String? // UUID of the group coordinator (for grouped playback)
        let channelMapSet: String?        // Present if part of a stereo pair
        let pairPartnerUUID: String?      // UUID of the other speaker in the stereo pair
        var audioSource: AudioSourceType? // Current audio source type
        var transportState: String?       // Current transport state (PLAYING, PAUSED, STOPPED)
        var nowPlaying: NowPlayingInfo?   // Current track metadata (streaming only)
    }

    /// Now Playing metadata from DIDL-Lite
    struct NowPlayingInfo {
        let title: String?
        let artist: String?
        let album: String?
        let albumArtURL: String?
        let duration: TimeInterval?
        let position: TimeInterval?

        /// Display text for UI (e.g., "Song Title • Artist")
        var displayText: String {
            switch (title, artist) {
            case let (t?, a?): return "\(t) • \(a)"
            case let (t?, nil): return t
            case let (nil, a?): return a
            case (nil, nil): return "Unknown Track"
            }
        }
    }

    /// Audio source type detected from track URI
    enum AudioSourceType {
        case lineIn         // x-rincon-stream: (physical line-in input)
        case tv             // x-sonos-htastream: (TV/home theater)
        case streaming      // Spotify, queue, etc. (supports skipping)
        case radio          // x-rincon-mp3radio: (radio streams - no skipping)
        case grouped        // x-rincon: (device is a group member)
        case idle           // Not playing anything

        var priority: Int {
            switch self {
            case .lineIn: return 3      // Highest priority - must be preserved
            case .tv: return 2          // High priority - should be preserved
            case .streaming: return 1   // Medium priority - can be interrupted
            case .radio: return 1       // Medium priority - can be interrupted
            case .grouped: return 0     // Already grouped
            case .idle: return 0        // No special handling
            }
        }

        var description: String {
            switch self {
            case .lineIn: return "Line-In"
            case .tv: return "TV"
            case .streaming: return "Streaming"
            case .radio: return "Radio"
            case .grouped: return "Grouped"
            case .idle: return "Idle"
            }
        }

        var badgeColor: String {
            switch self {
            case .lineIn: return "orange"
            case .tv: return "purple"
            case .streaming: return "green"
            case .radio: return "blue"
            case .grouped, .idle: return "gray"
            }
        }

        /// Whether this source type supports skip next/previous commands
        var supportsSkipping: Bool {
            switch self {
            case .streaming: return true    // Queue, Spotify, etc.
            case .lineIn, .tv, .radio, .grouped, .idle: return false
            }
        }
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

            self.markRefreshSuccess()

            // Post notification so menu can update - needs to be on MainActor
            await MainActor.run {
                NotificationCenter.default.post(name: NSNotification.Name("SonosDevicesDiscovered"), object: nil)
            }
        } catch {
            print("SSDP Discovery error: \(error)")
            self.markRefreshFailure()

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
                markRefreshFailure()
                return
            }

            parseGroupTopology(responseStr, completion: completion)
        } catch {
            print("GetZoneGroupState error: \(error)")
            markRefreshFailure()
        }
    }

    private func parseGroupTopology(_ xml: String, completion: (@Sendable () -> Void)? = nil) {
        // Extract ZoneGroupState XML from SOAP response
        guard let stateXML = XMLParsingHelpers.extractSection(from: xml, tag: "ZoneGroupState") else {
            print("Could not find ZoneGroupState in response")
            markRefreshFailure()
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

        // Build satellite-to-visible mapping for transport event routing
        satelliteToVisibleMap.removeAll()
        for device in self.devices {
            if let pairPartnerUUID = pairPartners[device.uuid] {
                // If this device has a pair partner that's invisible, map satellite -> visible
                if invisibleUUIDs.contains(pairPartnerUUID) {
                    satelliteToVisibleMap[pairPartnerUUID] = device.uuid
                    print("Mapped satellite \(pairPartnerUUID) -> visible \(device.uuid) (\(device.name))")
                }
            }
        }

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

        markRefreshSuccess()

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


    func selectDevice(name: String) async {
        _selectedDevice = devices.first { $0.name == name }
        
        if let device = _selectedDevice {
            // Track this device as last active
            settings.trackSpeakerActivity(device.name)

            var info = "✅ Selected: \(device.name)"
            if device.channelMapSet != nil {
                info += " [STEREO PAIR]"
            }
            if device.groupCoordinatorUUID != nil {
                if device.isGroupCoordinator {
                    info += " (Group Leader)"
                } else {
                    info += " (in group)"
                }
            }
            print(info)
            
            // Fetch and update audio source info for the selected device
            if let sourceInfo = await getAudioSourceInfo(for: device) {
                // Update the device in our devices array with the audio source
                if let index = devices.firstIndex(where: { $0.uuid == device.uuid }) {
                    devices[index].audioSource = sourceInfo.sourceType
                    devices[index].transportState = sourceInfo.state
                    devices[index].nowPlaying = sourceInfo.nowPlaying
                    
                    // Update the selected device reference
                    _selectedDevice = devices[index]
                    
                    print("📊 Device source: \(sourceInfo.sourceType.description), state: \(sourceInfo.state)")
                }
            }
        }
        
        updateCachedValues() // Update thread-safe copies
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

            // Start processing topology events - capture listener to avoid actor isolation issues
            eventProcessingTask = Task { [weak self] in
                for await event in listener.events {
                    await self?.handleTopologyEvent(event)
                }
            }

            // Start processing transport events
            transportEventProcessingTask = Task { [weak self] in
                for await event in listener.transportEvents {
                    await self?.handleTransportEvent(event)
                }
            }
        }

        // Subscribe to coordinator devices
        await subscribeToCoordinators()

        // Subscribe to transport events for all discovered devices
        await subscribeToAllDevicesForTransport()

        print("✅ Topology monitoring started")
    }

    /// Stop monitoring topology changes
    func stopTopologyMonitoring() async {
        print("🛑 Stopping topology monitoring...")

        // Cancel event processing
        eventProcessingTask?.cancel()
        eventProcessingTask = nil
        transportEventProcessingTask?.cancel()
        transportEventProcessingTask = nil

        // Shutdown event listener
        if let listener = eventListener {
            await listener.shutdown()
        }

        eventListener = nil
        coordinatorSubscriptions.removeAll()
        transportSubscriptions.removeAll()

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

    /// Subscribe to AVTransport events for all discovered devices
    private func subscribeToAllDevicesForTransport() async {
        print("🎵 Subscribing to transport events for all devices...")

        guard let listener = eventListener else { return }

        for device in devices {
            // Skip if already subscribed
            if transportSubscriptions[device.uuid] != nil {
                print("   Already subscribed to \(device.name)")
                continue
            }

            do {
                let sid = try await listener.subscribe(
                    deviceUUID: device.uuid,
                    deviceIP: device.ipAddress,
                    service: .avTransport
                )

                transportSubscriptions[device.uuid] = sid
                print("   🎵 ✅ Subscribed to \(device.name) (SID: \(sid))")

            } catch {
                print("   ⚠️ Failed to subscribe to \(device.name): \(error)")
            }
        }

        print("🎵 Transport monitoring started for \(transportSubscriptions.count) devices")
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

            // Subscribe to transport events for any new devices
            await subscribeToAllDevicesForTransport()

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

    /// Subscribe to AVTransport events for a specific device
    func subscribeToTransportUpdates(for deviceUUID: String) async {
        guard let device = devices.first(where: { $0.uuid == deviceUUID }),
              let listener = eventListener else {
            print("⚠️ Cannot subscribe to transport updates: device or listener not found")
            return
        }

        // Skip if already subscribed
        if transportSubscriptions[deviceUUID] != nil {
            print("   Already subscribed to transport updates for \(device.name)")
            return
        }

        do {
            let sid = try await listener.subscribe(
                deviceUUID: device.uuid,
                deviceIP: device.ipAddress,
                service: .avTransport
            )

            transportSubscriptions[device.uuid] = sid
            print("🎵 ✅ Subscribed to transport updates for \(device.name) (SID: \(sid))")

        } catch {
            print("⚠️ Failed to subscribe to transport updates for \(device.name): \(error)")
        }
    }

    /// Unsubscribe from AVTransport events for a specific device
    func unsubscribeFromTransportUpdates(for deviceUUID: String) async {
        guard let sid = transportSubscriptions[deviceUUID] else { return }

        do {
            try await eventListener?.unsubscribe(sid: sid)
            transportSubscriptions.removeValue(forKey: deviceUUID)
            print("🎵 Unsubscribed from transport updates for device \(deviceUUID)")
        } catch {
            print("⚠️ Failed to unsubscribe from transport updates: \(error)")
        }
    }

    /// Handle incoming transport events
    private func handleTransportEvent(_ event: UPnPEventListener.TransportEvent) async {
        switch event {
        case .transportStateChanged(var deviceUUID, let state, let trackURI, let metadata):
            // Translate satellite speaker UUID to visible speaker UUID if needed
            if let visibleUUID = satelliteToVisibleMap[deviceUUID] {
                print("🎵 Transport event for satellite \(deviceUUID), translating to visible speaker \(visibleUUID)")
                deviceUUID = visibleUUID
            }

            print("🎵 Transport state changed for \(deviceUUID): \(state)")

            // Update the device's transport state in our cache
            if let index = devices.firstIndex(where: { $0.uuid == deviceUUID }) {
                devices[index].transportState = state

                // If metadata is present, parse and update now playing info
                if let metadata = metadata, !metadata.isEmpty {
                    let nowPlaying = parseNowPlayingFromMetadata(metadata)
                    devices[index].nowPlaying = nowPlaying
                }

                // Notify UI of the change (must happen on main thread)
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: NSNotification.Name("SonosTransportStateDidChange"),
                        object: nil,
                        userInfo: [
                            "deviceUUID": deviceUUID,
                            "state": state,
                            "trackURI": trackURI as Any,
                            "metadata": metadata as Any
                        ]
                    )
                }
            }

            markRefreshSuccess()

        case .subscriptionExpired(let sid):
            print("⚠️ Transport subscription expired: \(sid)")

            // Find and resubscribe
            for (uuid, subscriptionSID) in transportSubscriptions {
                if subscriptionSID == sid {
                    transportSubscriptions.removeValue(forKey: uuid)

                    // Try to resubscribe
                    await subscribeToTransportUpdates(for: uuid)
                    break
                }
            }
        }
    }

    /// Parse now playing info from DIDL-Lite metadata XML
    private func parseNowPlayingFromMetadata(_ metadata: String) -> NowPlayingInfo? {
        // This is a simplified version - reuse existing parseNowPlayingInfo logic
        let title = extractXMLValue(from: metadata, tag: "dc:title")
        let artist = extractXMLValue(from: metadata, tag: "dc:creator")
        let album = extractXMLValue(from: metadata, tag: "upnp:album")

        // Extract album art URL
        var albumArtURL: String?
        if let artTag = extractXMLValue(from: metadata, tag: "upnp:albumArtURI") {
            albumArtURL = artTag.hasPrefix("http") ? artTag : nil
        }

        return NowPlayingInfo(
            title: title,
            artist: artist,
            album: album,
            albumArtURL: albumArtURL,
            duration: nil,
            position: nil
        )
    }

    /// Extract a simple XML tag value
    private func extractXMLValue(from xml: String, tag: String) -> String? {
        let pattern = "<\(tag)>([^<]+)</\(tag)>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        let range = NSRange(xml.startIndex..., in: xml)
        guard let match = regex.firstMatch(in: xml, range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: xml) else {
            return nil
        }

        return String(xml[valueRange])
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
    /// Async/await wrapper for adding device to group
    nonisolated func addDeviceToGroup(device: SonosDevice, coordinatorUUID: String, shouldRefreshTopology: Bool = true) async -> Bool {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                await self.addDeviceToGroupCallback(device: device, coordinatorUUID: coordinatorUUID, shouldRefreshTopology: shouldRefreshTopology) { success in
                    continuation.resume(returning: success)
                }
            }
        }
    }

    func addDeviceToGroupCallback(device: SonosDevice, coordinatorUUID: String, shouldRefreshTopology: Bool = true, completion: (@Sendable (Bool) -> Void)? = nil) {
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

        print("📤 Sending SetAVTransportURI to \(device.ipAddress)")
        print("   Target URI: x-rincon:\(coordinatorUUID)")

        Task { [weak self] in
            guard let self = self else { return }

            do {
                try await self.networkClient.setAVTransportURI("x-rincon:\(coordinatorUUID)", for: device.ipAddress)
                print("✅ Successfully added \(device.name) to group")

                // Optionally refresh topology before calling completion
                if shouldRefreshTopology {
                    // Wait a bit before refreshing topology
                    try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 seconds

                    await self.updateGroupTopology {
                        DispatchQueue.main.async {
                            completion?(true)
                        }
                    }
                } else {
                    DispatchQueue.main.async {
                        completion?(true)
                    }
                }
            } catch {
                print("❌ Failed to add device to group: \(error)")
                DispatchQueue.main.async {
                    completion?(false)
                }
            }
        }
    }

    /// Remove a device from its current group (make it standalone)
    /// Uses AVTransport BecomeGroupCoordinatorAndSource
    func removeDeviceFromGroup(device: SonosDevice, completion: (@Sendable (Bool) -> Void)? = nil) {
        print("🔓 Removing \(device.name) from group")

        Task { [weak self] in
            guard let self = self else { return }

            do {
                try await self.networkClient.becomeStandaloneCoordinator(for: device.ipAddress)
                print("✅ Successfully removed \(device.name) from group")
                completion?(true)

                // Refresh topology after a short delay
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                await self.updateGroupTopology(completion: nil)
            } catch {
                print("❌ Failed to remove device from group: \(error)")
                completion?(false)
            }
        }
    }

    /// Create a new group with specified devices
    /// The first device becomes the coordinator
    /// Get playback states for multiple devices
    /// Returns dictionary mapping device UUID to transport state
    func getPlaybackStates(devices: [SonosDevice], completion: @escaping @Sendable ([String: String]) -> Void) {
        let queue = DispatchQueue(label: "com.sonos.playbackStates")
        var states: [String: String] = [:]
        let dispatchGroup = DispatchGroup()

        for device in devices {
            dispatchGroup.enter()
            getTransportState(device: device) { state in
                queue.async {
                    if let state = state {
                        states[device.uuid] = state
                    }
                    dispatchGroup.leave()
                }
            }
        }

        dispatchGroup.notify(queue: .main) {
            completion(states)
        }
    }

    /// Get list of devices that are currently playing
    func getPlayingDevices(from devices: [SonosDevice], completion: @escaping @Sendable ([SonosDevice]) -> Void) {
        getPlaybackStates(devices: devices) { states in
            let playingDevices = devices.filter { device in
                states[device.uuid] == "PLAYING"
            }
            completion(playingDevices)
        }
    }

    /// Result of coordinator selection analysis
    struct CoordinatorSelection {
        let suggestedCoordinator: SonosDevice
        let playingDevices: [SonosDevice]
        let requiresUserChoice: Bool  // True if multiple devices are playing
    }
    
    /// Create a group from multiple devices with smart coordinator selection (async/await)
    /// If coordinatorDevice is not specified, will choose intelligently based on audio sources
    func createGroup(devices deviceList: [SonosDevice], coordinatorDevice: SonosDevice? = nil, completion: (@Sendable (Bool) -> Void)? = nil) {
        guard deviceList.count > 1 else {
            print("❌ Need at least 2 devices to create a group")
            completion?(false)
            return
        }

        Task { [weak self] in
            guard let self = self else { return }

            // If coordinator is explicitly specified, use it
            if let explicitCoordinator = coordinatorDevice {
                guard deviceList.contains(where: { $0.uuid == explicitCoordinator.uuid }) else {
                    print("❌ Specified coordinator not in device list")
                    completion?(false)
                    return
                }
                await self.performGrouping(devices: deviceList, coordinator: explicitCoordinator, completion: completion)
                return
            }

            // Otherwise, intelligently select coordinator based on audio sources
            print("🔍 Detecting audio sources to choose best coordinator...")
            let coordinator = await self.selectBestCoordinator(from: deviceList)

            await self.performGrouping(devices: deviceList, coordinator: coordinator, completion: completion)
        }
    }
    
    /// Analyze devices and determine best coordinator selection
    /// Returns coordinator selection info including whether user input is needed
    func analyzeCoordinatorSelection(from devices: [SonosDevice]) async -> CoordinatorSelection {
        // Get audio source info for all devices in parallel
        let sourceInfos = await withTaskGroup(of: (String, (state: String, sourceType: AudioSourceType, nowPlaying: NowPlayingInfo?, trackURI: String?)?).self) { group in
            for device in devices {
                group.addTask {
                    if let info = await self.getAudioSourceInfo(for: device) {
                        return (device.uuid, (state: info.state, sourceType: info.sourceType, nowPlaying: info.nowPlaying, trackURI: info.trackURI))
                    }
                    return (device.uuid, nil)
                }
            }

            var results: [String: (state: String, sourceType: AudioSourceType, nowPlaying: NowPlayingInfo?, trackURI: String?)] = [:]
            for await (uuid, info) in group {
                if let info = info {
                    results[uuid] = info
                }
            }
            return results
        }
        
        // Line-in should always win when actively playing (high intent source).
        let lineInDevices = devices.filter { device in
            guard let info = sourceInfos[device.uuid] else { return false }
            return info.state == "PLAYING" && info.sourceType == .lineIn
        }

        if !lineInDevices.isEmpty {
            if lineInDevices.count == 1 {
                let coordinator = lineInDevices[0]
                print("🎙️ Line-in playing on \(coordinator.name) - using as coordinator")
                return CoordinatorSelection(
                    suggestedCoordinator: coordinator,
                    playingDevices: lineInDevices,
                    requiresUserChoice: false
                )
            }

            print("⚠️ Multiple line-in sources playing - user input required")
            return CoordinatorSelection(
                suggestedCoordinator: lineInDevices[0],
                playingDevices: lineInDevices,
                requiresUserChoice: true
            )
        }

        func contentKey(for device: SonosDevice, info: (state: String, sourceType: AudioSourceType, nowPlaying: NowPlayingInfo?, trackURI: String?)) -> String {
            if let uri = info.trackURI, !uri.isEmpty {
                return uri
            }
            if let coordinatorUUID = device.groupCoordinatorUUID {
                return "group:\(coordinatorUUID)"
            }
            if let nowPlaying = info.nowPlaying {
                return "np:\(nowPlaying.displayText)"
            }
            return "device:\(device.uuid)"
        }

        // Find all devices that are currently PLAYING (new simplified priority model)
        let playingDevices = devices.filter { device in
            sourceInfos[device.uuid]?.state == "PLAYING"
        }
        
        print("🎵 Coordinator analysis: \(playingDevices.count) of \(devices.count) devices are playing")
        
        if playingDevices.isEmpty {
            // No devices playing - choose first device (prefer non-stereo-pair)
            let nonStereoPair = devices.first { $0.channelMapSet == nil }
            let coordinator = nonStereoPair ?? devices.first!
            print("📍 No devices playing - using \(coordinator.name) as coordinator")
            return CoordinatorSelection(
                suggestedCoordinator: coordinator,
                playingDevices: [],
                requiresUserChoice: false
            )
        } else if playingDevices.count == 1 {
            // One device playing - automatic choice
            let coordinator = playingDevices[0]
            print("🎵 One device playing (\(coordinator.name)) - using as coordinator")
            return CoordinatorSelection(
                suggestedCoordinator: coordinator,
                playingDevices: playingDevices,
                requiresUserChoice: false
            )
        } else {
            let contentKeys = playingDevices.compactMap { device -> String? in
                guard let info = sourceInfos[device.uuid] else { return nil }
                return contentKey(for: device, info: info)
            }
            let uniqueKeys = Set(contentKeys)
            if uniqueKeys.count == 1 {
                let nonStereoPair = playingDevices.first { $0.channelMapSet == nil }
                let coordinator = nonStereoPair ?? playingDevices[0]
                print("🎵 Multiple devices playing the same content - using \(coordinator.name) as coordinator")
                return CoordinatorSelection(
                    suggestedCoordinator: coordinator,
                    playingDevices: playingDevices,
                    requiresUserChoice: false
                )
            }

            // Multiple devices playing - user must choose
            print("⚠️ Multiple devices playing - user input required")
            for device in playingDevices {
                if let info = sourceInfos[device.uuid] {
                    print("  - \(device.name): \(info.sourceType.description)")
                }
            }
            // Suggest first playing device but require user confirmation
            return CoordinatorSelection(
                suggestedCoordinator: playingDevices[0],
                playingDevices: playingDevices,
                requiresUserChoice: true
            )
        }
    }

    /// Select the best coordinator from a list of devices based on audio source priority
    private func selectBestCoordinator(from devices: [SonosDevice]) async -> SonosDevice {
        // Get audio source info for all devices in parallel
        let sourceInfos = await withTaskGroup(of: (String, (state: String, sourceType: AudioSourceType, trackURI: String?)?).self) { group in
            for device in devices {
                group.addTask {
                    if let info = await self.getAudioSourceInfo(for: device) {
                        return (device.uuid, (state: info.state, sourceType: info.sourceType, trackURI: info.trackURI))
                    }
                    return (device.uuid, nil)
                }
            }

            var results: [String: (state: String, sourceType: AudioSourceType, trackURI: String?)] = [:]
            for await (uuid, info) in group {
                if let info = info {
                    results[uuid] = info
                }
            }
            return results
        }

        // Categorize devices by source type
        let lineInDevices = devices.filter { sourceInfos[$0.uuid]?.sourceType == .lineIn }
        let tvDevices = devices.filter { sourceInfos[$0.uuid]?.sourceType == .tv }
        let streamingDevices = devices.filter {
            let type = sourceInfos[$0.uuid]?.sourceType
            let state = sourceInfos[$0.uuid]?.state
            return (type == .streaming || type == .radio) && state == "PLAYING"
        }

        // Priority 1: Line-in sources (highest priority - must be preserved)
        if let coordinator = lineInDevices.first {
            print("🎙️ Line-in audio detected on \(coordinator.name) - using as coordinator to preserve audio")
            if coordinator.channelMapSet != nil {
                print("⚠️ Coordinator is a stereo pair - grouping may fail (Sonos limitation)")
            }
            return coordinator
        }

        // Priority 2: TV/Home theater sources
        if let coordinator = tvDevices.first {
            print("📺 TV audio detected on \(coordinator.name) - using as coordinator to preserve audio")
            if coordinator.channelMapSet != nil {
                print("⚠️ Coordinator is a stereo pair - grouping may fail (Sonos limitation)")
            }
            return coordinator
        }

        // Priority 3: Streaming sources
        if streamingDevices.count == 1, let coordinator = streamingDevices.first {
            print("🎵 One device streaming (\(coordinator.name)) - using as coordinator to preserve playback")
            if coordinator.channelMapSet != nil {
                print("⚠️ Coordinator is a stereo pair - grouping may fail (Sonos limitation)")
            }
            return coordinator
        } else if streamingDevices.count > 1 {
            let nonStereoPair = streamingDevices.first { $0.channelMapSet == nil }
            let coordinator = nonStereoPair ?? streamingDevices.first!
            print("⚠️ Multiple devices streaming - choosing \(coordinator.name) as coordinator")
            print("   Note: Other streaming devices will stop playback")
            return coordinator
        }

        // Priority 4: No devices playing - prefer non-stereo-pair
        let nonStereoPair = devices.first { $0.channelMapSet == nil }
        let coordinator = nonStereoPair ?? devices.first!
        print("📍 No devices playing - using \(coordinator.name) as coordinator")
        return coordinator
    }

    /// Internal helper to perform the actual grouping with a specified coordinator (async/await)
    /// Includes TOCTOU protection by re-verifying audio source immediately before grouping
    private func performGrouping(devices: [SonosDevice], coordinator: SonosDevice, retry: Bool = true, completion: (@Sendable (Bool) -> Void)?) async {
        print("🎵 Creating group with coordinator: \(coordinator.name)")

        // Verify coordinator's audio source immediately before grouping (TOCTOU protection)
        guard let sourceInfo = await getAudioSourceInfo(for: coordinator) else {
            print("❌ Could not verify coordinator audio source")
            completion?(false)
            return
        }

        let coordinatorWasPlaying = (sourceInfo.state == "PLAYING")
        if coordinatorWasPlaying {
            print("📝 Coordinator is playing \(sourceInfo.sourceType.description) - will resume after grouping if needed")
        }

        // Perform the actual grouping
        let success = await performGroupingInternal(
            devices: devices,
            coordinator: coordinator,
            coordinatorWasPlaying: coordinatorWasPlaying,
            retry: retry
        )

        completion?(success)
    }

    /// Internal grouping logic using async/await for clean concurrent operations
    private func performGroupingInternal(devices: [SonosDevice], coordinator: SonosDevice, coordinatorWasPlaying: Bool, retry: Bool) async -> Bool {
        let membersToAdd = devices.filter { $0.uuid != coordinator.uuid }

        // Add all members to coordinator's group in parallel
        let results = await withTaskGroup(of: Bool.self) { group in
            for member in membersToAdd {
                group.addTask {
                    await self.addDeviceToGroup(device: member, coordinatorUUID: coordinator.uuid, shouldRefreshTopology: false)
                }
            }

            var successCount = 0
            for await success in group {
                if success {
                    successCount += 1
                }
            }
            return successCount
        }

        let allSuccess = results == membersToAdd.count
        print(allSuccess ? "✅ All members added (\(results)/\(membersToAdd.count))" : "⚠️ Some members failed (\(results)/\(membersToAdd.count))")

        // If failed and coordinator is a stereo pair, retry with different coordinator
        if !allSuccess && retry && coordinator.channelMapSet != nil && membersToAdd.count == 1 {
            print("🔄 Retrying with \(membersToAdd[0].name) as coordinator (stereo pair limitation)")
            return await performGroupingInternal(devices: devices, coordinator: membersToAdd[0], coordinatorWasPlaying: false, retry: false)
        }

        // Refresh topology after grouping
        try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 seconds
        await updateGroupTopology()

        // If coordinator was playing, resume if needed
        if coordinatorWasPlaying {
            if let currentInfo = await getAudioSourceInfo(for: coordinator), currentInfo.state != "PLAYING" {
                print("🔄 Coordinator paused during grouping - resuming playback")
                await sendPlayCommand(to: coordinator)
            }
        }

        print(allSuccess ? "✅ Group created successfully" : "⚠️ Group created with some failures")
        return allSuccess
    }

    /// Dissolve a group by ungrouping all members
    func dissolveGroup(group: SonosGroup, completion: (@Sendable (Bool) -> Void)? = nil) {
        print("💥 Dissolving group: \(group.displayName)")

        let nonCoordinatorMembers = group.members.filter { $0.uuid != group.coordinatorUUID }

        guard !nonCoordinatorMembers.isEmpty else {
            print("ℹ️ Group already standalone")
            completion?(true)
            return
        }

        let queue = DispatchQueue(label: "com.sonos.dissolveGroup")
        var successCount = 0
        let totalMembers = nonCoordinatorMembers.count

        for member in nonCoordinatorMembers {
            removeDeviceFromGroup(device: member) { success in
                queue.async {
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
    }

    /// Send Play command to a device
    /// Uses AVTransport Play
    private func sendPlayCommand(to device: SonosDevice) {
        Task { [weak self] in
            guard let self = self else { return }

            do {
                try await self.networkClient.play(for: device.ipAddress)
                print("▶️ Play command sent to \(device.name)")
            } catch {
                print("❌ Failed to send play command: \(error)")
            }
        }
    }

    // MARK: - Transport Controls (Public API)

    /// Play/resume the selected speaker or group
    func playSelected() {
        guard let device = _selectedDevice else {
            print("⚠️ No device selected for play")
            showNoSpeakerSelectedNotification()
            return
        }

        // If in a group, send command to coordinator
        let targetDevice: SonosDevice
        if let group = getGroupForDevice(device), group.members.count > 1 {
            targetDevice = group.coordinator
            print("▶️ Playing group: \(group.displayName)")
        } else {
            targetDevice = device
            print("▶️ Playing: \(device.name)")
        }

        Task { [weak self] in
            guard let self = self else { return }
            do {
                try await self.networkClient.play(for: targetDevice.ipAddress)
                print("✅ Play command successful")
            } catch {
                print("❌ Failed to play: \(error)")
                await MainActor.run {
                    VolumeHUD.shared.showError(title: "Playback Error", message: "Failed to play")
                }
            }
        }
    }

    /// Pause the selected speaker or group
    func pauseSelected() {
        guard let device = _selectedDevice else {
            print("⚠️ No device selected for pause")
            showNoSpeakerSelectedNotification()
            return
        }

        // If in a group, send command to coordinator
        let targetDevice: SonosDevice
        if let group = getGroupForDevice(device), group.members.count > 1 {
            targetDevice = group.coordinator
            print("⏸️ Pausing group: \(group.displayName)")
        } else {
            targetDevice = device
            print("⏸️ Pausing: \(device.name)")
        }

        Task { [weak self] in
            guard let self = self else { return }
            do {
                try await self.networkClient.pause(for: targetDevice.ipAddress)
                print("✅ Pause command successful")
            } catch {
                print("❌ Failed to pause: \(error)")
                await MainActor.run {
                    VolumeHUD.shared.showError(title: "Playback Error", message: "Failed to pause")
                }
            }
        }
    }

    /// Skip to next track (if supported by current audio source)
    func nextTrack() {
        guard let device = _selectedDevice else {
            print("⚠️ No device selected for next")
            showNoSpeakerSelectedNotification()
            return
        }

        // If in a group, send command to coordinator
        let targetDevice: SonosDevice
        if let group = getGroupForDevice(device), group.members.count > 1 {
            targetDevice = group.coordinator
            print("⏭️ Next track for group: \(group.displayName)")
        } else {
            targetDevice = device
            print("⏭️ Next track for: \(device.name)")
        }

        Task { [weak self] in
            guard let self = self else { return }
            do {
                try await self.networkClient.next(for: targetDevice.ipAddress)
                print("✅ Next command successful")
            } catch {
                print("❌ Failed to skip next: \(error)")
                await MainActor.run {
                    VolumeHUD.shared.showError(title: "Skip Error", message: "Failed to skip track")
                }
            }
        }
    }

    /// Skip to previous track (if supported by current audio source)
    func previousTrack() {
        guard let device = _selectedDevice else {
            print("⚠️ No device selected for previous")
            showNoSpeakerSelectedNotification()
            return
        }

        // If in a group, send command to coordinator
        let targetDevice: SonosDevice
        if let group = getGroupForDevice(device), group.members.count > 1 {
            targetDevice = group.coordinator
            print("⏮️ Previous track for group: \(group.displayName)")
        } else {
            targetDevice = device
            print("⏮️ Previous track for: \(device.name)")
        }

        Task { [weak self] in
            guard let self = self else { return }
            do {
                try await self.networkClient.previous(for: targetDevice.ipAddress)
                print("✅ Previous command successful")
            } catch {
                print("❌ Failed to skip previous: \(error)")
                await MainActor.run {
                    VolumeHUD.shared.showError(title: "Skip Error", message: "Failed to skip track")
                }
            }
        }
    }

    /// Get transport capabilities for the selected device
    /// Returns (canControl: Bool, supportsSkipping: Bool)
    nonisolated func getTransportCapabilities() -> (canControl: Bool, supportsSkipping: Bool) {
        guard let selectedDevice = _cachedSelectedDevice else {
            return (false, false)
        }

        let transportDevice: SonosDevice
        if let group = getCachedGroupForDevice(selectedDevice) {
            transportDevice = group.coordinator
        } else {
            transportDevice = selectedDevice
        }

        // Check if we have audio source info
        let sourceType = transportDevice.audioSource ?? .idle
        
        // Can control if not idle
        let canControl = sourceType != .idle
        
        // Can skip if streaming content
        let supportsSkipping = sourceType.supportsSkipping

        return (canControl, supportsSkipping)
    }

    /// Get the transport state of a device (PLAYING, PAUSED_PLAYBACK, STOPPED, etc.)
    /// Uses AVTransport GetTransportInfo
    func getTransportState(device: SonosDevice, completion: @escaping @Sendable (String?) -> Void) {
        Task { [weak self] in
            guard let self = self else { return }

            do {
                let responseStr = try await self.networkClient.getTransportInfo(for: device.ipAddress)

                // Extract CurrentTransportState value using XMLParsingHelpers
                if let state = XMLParsingHelpers.extractValue(from: responseStr, tag: "CurrentTransportState") {
                    print("🎵 Transport state for \(device.name): \(state)")
                    completion(state)
                } else {
                    print("⚠️ Could not parse transport state for \(device.name)")
                    completion(nil)
                }
            } catch {
                print("❌ Failed to get transport state: \(error)")
                completion(nil)
            }
        }
    }

    // MARK: - Audio Source Detection

    /// Get audio source information for a device (async/await)
    /// Returns tuple of (transportState, audioSource, nowPlaying) or nil if unable to determine
    func getAudioSourceInfo(for device: SonosDevice) async -> (state: String, sourceType: AudioSourceType, nowPlaying: NowPlayingInfo?, trackURI: String?)? {
        do {
            // Get transport state and position info in parallel
            async let transportResponse = networkClient.getTransportInfo(for: device.ipAddress)
            async let positionResponse = networkClient.getPositionInfo(for: device.ipAddress)

            let (transportStr, positionStr) = try await (transportResponse, positionResponse)

            // Parse transport state
            guard let state = XMLParsingHelpers.extractValue(from: transportStr, tag: "CurrentTransportState") else {
                print("⚠️ Could not parse transport state for \(device.name)")
                return nil
            }

            // Parse track URI
            let uri = XMLParsingHelpers.extractValue(from: positionStr, tag: "TrackURI")
            let sourceType = detectAudioSourceType(from: uri, state: state)

            // Parse Now Playing metadata for streaming content
            var nowPlaying: NowPlayingInfo? = nil
            if sourceType == .streaming {
                nowPlaying = parseNowPlayingInfo(from: positionStr, device: device)
            }

            if let np = nowPlaying {
                print("🎵 \(device.name): \(state) - \(sourceType.description) - \(np.displayText)")
            } else {
                print("🎵 \(device.name): \(state) - \(sourceType.description)")
            }

            return (state: state, sourceType: sourceType, nowPlaying: nowPlaying, trackURI: uri)

        } catch {
            print("❌ Failed to get audio source info for \(device.name): \(error)")
            return nil
        }
    }

    /// Fetch audio source info and update the cached device entry.
    func refreshAudioSourceInfo(for device: SonosDevice) async -> (state: String, sourceType: AudioSourceType, nowPlaying: NowPlayingInfo?, trackURI: String?)? {
        guard let info = await getAudioSourceInfo(for: device) else {
            return nil
        }

        if let index = devices.firstIndex(where: { $0.uuid == device.uuid }) {
            devices[index].audioSource = info.sourceType
            devices[index].transportState = info.state
            devices[index].nowPlaying = info.nowPlaying

            if _selectedDevice?.uuid == device.uuid {
                _selectedDevice = devices[index]
            }

            updateCachedValues()
        }

        return info
    }

    /// Detect audio source type from track URI and transport state
    nonisolated func detectAudioSourceType(from uri: String?, state: String) -> AudioSourceType {
        // Check URI first - line-in and TV sources should be detected even when paused
        if let uri = uri {
            if uri.hasPrefix("x-rincon-stream:") {
                return .lineIn
            } else if uri.hasPrefix("x-sonos-htastream:") {
                return .tv
            } else if uri.hasPrefix("x-rincon:") {
                return .grouped
            } else if uri.hasPrefix("x-rincon-mp3radio:") {
                // Radio streams - detected even when paused
                return .radio
            }
        }

        // If not playing/paused, and not line-in/TV/grouped/radio, it's idle
        guard state == "PLAYING" || state == "PAUSED_PLAYBACK", let uri = uri else {
            return .idle
        }

        // Streaming sources (queue, Spotify, etc.)
        if uri.hasPrefix("x-rincon-queue:") || uri.hasPrefix("x-sonos-spotify:") || uri.hasPrefix("x-sonos-http:") {
            return .streaming
        }

        return .streaming // Default to streaming for unknown URIs when playing
    }

    /// Parse Now Playing metadata from GetPositionInfo response
    /// Extracts title, artist, album, and album art from DIDL-Lite XML
    func parseNowPlayingInfo(from positionResponse: String, device: SonosDevice) -> NowPlayingInfo? {
        // Extract TrackMetaData (contains DIDL-Lite XML)
        guard let trackMetaData = XMLParsingHelpers.extractValue(from: positionResponse, tag: "TrackMetaData") else {
            return nil
        }

        // Decode HTML entities (TrackMetaData is HTML-encoded in the SOAP response)
        guard let decodedMetadata = trackMetaData.decodeHTMLEntities() else {
            return nil
        }

        // Parse DIDL-Lite fields and decode any remaining HTML entities
        let title = XMLParsingHelpers.extractValue(from: decodedMetadata, tag: "dc:title")?.decodeHTMLEntities()
        let artist = XMLParsingHelpers.extractValue(from: decodedMetadata, tag: "dc:creator")?.decodeHTMLEntities()
        let album = XMLParsingHelpers.extractValue(from: decodedMetadata, tag: "upnp:album")?.decodeHTMLEntities()

        // Extract album art URL from <upnp:albumArtURI>
        var albumArtURL: String? = nil
        if let artURI = XMLParsingHelpers.extractValue(from: decodedMetadata, tag: "upnp:albumArtURI"),
           let decodedURI = artURI.decodeHTMLEntities() {
            // Album art URI is often relative - make it absolute if needed
            if decodedURI.hasPrefix("http") {
                albumArtURL = decodedURI
            } else if decodedURI.hasPrefix("/") {
                // Construct absolute URL using device IP
                albumArtURL = "http://\(device.ipAddress):1400\(decodedURI)"
            }
        }

        // Extract duration and position (in format "H:MM:SS" or "M:SS")
        let durationStr = XMLParsingHelpers.extractValue(from: positionResponse, tag: "TrackDuration")
        let positionStr = XMLParsingHelpers.extractValue(from: positionResponse, tag: "RelTime")

        let duration = parseTimeInterval(from: durationStr)
        let position = parseTimeInterval(from: positionStr)

        // Return nil if we don't have at least a title
        guard title != nil || artist != nil else {
            return nil
        }

        return NowPlayingInfo(
            title: title,
            artist: artist,
            album: album,
            albumArtURL: albumArtURL,
            duration: duration,
            position: position
        )
    }

    /// Parse time string "H:MM:SS" or "M:SS" to TimeInterval
    nonisolated private func parseTimeInterval(from timeString: String?) -> TimeInterval? {
        guard let timeString = timeString else { return nil }

        let components = timeString.split(separator: ":").compactMap { Int($0) }
        guard !components.isEmpty else { return nil }

        if components.count == 3 {
            // H:MM:SS
            return TimeInterval(components[0] * 3600 + components[1] * 60 + components[2])
        } else if components.count == 2 {
            // M:SS
            return TimeInterval(components[0] * 60 + components[1])
        } else if components.count == 1 {
            // Just seconds
            return TimeInterval(components[0])
        }

        return nil
    }

    /// Fetch album art image asynchronously with caching
    /// Returns cached image if available, otherwise downloads and caches
    func fetchAlbumArt(url: String) async -> NSImage? {
        let cacheKey = url as NSString

        // Check cache first
        if let cachedImage = albumArtCache.object(forKey: cacheKey) {
            return cachedImage
        }

        // Download image
        guard let imageURL = URL(string: url) else { return nil }

        do {
            let (data, _) = try await URLSession.shared.data(from: imageURL)
            guard let image = NSImage(data: data) else { return nil }

            // Cache the image
            albumArtCache.setObject(image, forKey: cacheKey)
            return image
        } catch {
            return nil
        }
    }

    // MARK: - Group Volume Control

    /// Get the group volume (average across all members)
    /// Must be called on the group coordinator
    func getGroupVolume(group: SonosGroup, completion: @escaping @Sendable (Int?) -> Void) {
        let coordinator = group.coordinator
        #if DEBUG
        print("🎚️ Getting group volume for: \(group.displayName)")
        #endif

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

// MARK: - String Extensions for HTML Entity Decoding

extension String {
    /// Decodes HTML entities like &lt; &gt; &quot; &amp; etc
    func decodeHTMLEntities() -> String? {
        guard let data = self.data(using: .utf8) else { return nil }

        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]

        guard let attributedString = try? NSAttributedString(data: data, options: options, documentAttributes: nil) else {
            return nil
        }

        return attributedString.string
    }
}
