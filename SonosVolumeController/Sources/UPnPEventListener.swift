import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1

/// Actor responsible for managing UPnP event subscriptions and receiving NOTIFY callbacks
actor UPnPEventListener {

    // MARK: - Types

    struct Subscription: Sendable {
        let sid: String
        let deviceUUID: String
        let deviceIP: String
        let service: UPnPService
        var expiresAt: Date
        var renewalTask: Task<Void, Never>?
    }

    enum UPnPService: String, Sendable {
        case zoneGroupTopology = "ZoneGroupTopology"
        case avTransport = "AVTransport"
        case renderingControl = "RenderingControl"

        var endpoint: String {
            switch self {
            case .zoneGroupTopology:
                return "/ZoneGroupTopology"
            case .avTransport:
                return "/MediaRenderer/AVTransport"
            case .renderingControl:
                return "/MediaRenderer/RenderingControl"
            }
        }
    }

    enum TopologyEvent: Sendable {
        case topologyChanged(xml: String)
        case coordinatorChanged(oldUUID: String, newUUID: String)
        case subscriptionExpired(sid: String)
    }

    enum TransportEvent: Sendable {
        case transportStateChanged(deviceUUID: String, state: String, trackURI: String?, metadata: String?)
        case subscriptionExpired(sid: String)
    }

    enum SubscriptionError: Error {
        case invalidResponse
        case serverNotRunning
        case networkError(Error)
        case parseError
    }

    // MARK: - Properties

    private let eventLoopGroup: MultiThreadedEventLoopGroup
    private var channel: Channel?
    private var subscriptions: [String: Subscription] = [:]
    private var port: Int
    private let localIP: String

    // Event stream for topology changes
    private let eventContinuation: AsyncStream<TopologyEvent>.Continuation
    let events: AsyncStream<TopologyEvent>

    // Event stream for transport state changes
    private let transportContinuation: AsyncStream<TransportEvent>.Continuation
    let transportEvents: AsyncStream<TransportEvent>

    // MARK: - Initialization

    init() async throws {
        print("🎧 Initializing UPnP Event Listener...")

        // Create event loop group with single thread
        self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        // Discover local IP address
        self.localIP = Self.getLocalIPAddress()
        print("📡 Local IP: \(localIP)")

        // Create event streams
        var continuation: AsyncStream<TopologyEvent>.Continuation!
        self.events = AsyncStream { cont in
            continuation = cont
        }
        self.eventContinuation = continuation

        var transportCont: AsyncStream<TransportEvent>.Continuation!
        self.transportEvents = AsyncStream { cont in
            transportCont = cont
        }
        self.transportContinuation = transportCont

        // Initialize port to 0 temporarily
        self.port = 0

        // Start HTTP server with dynamic port allocation
        let (actualPort, serverChannel) = try await Self.startServer(
            on: 0, // System assigns available port
            eventLoopGroup: eventLoopGroup,
            listener: UnsafeListenerReference(self)
        )

        self.port = actualPort
        self.channel = serverChannel

        print("✅ HTTP server listening on port \(port)")
        print("📍 Callback URL: \(callbackURL)")
    }

    deinit {
        print("🛑 Shutting down UPnP Event Listener...")
        // Cleanup is handled in shutdown()
    }

    // MARK: - Public API

    var callbackURL: String {
        "http://\(localIP):\(port)/notify"
    }

    func shutdown() async {
        print("🛑 Shutting down UPnP Event Listener...")

        // Cancel all renewal tasks
        for (_, subscription) in subscriptions {
            subscription.renewalTask?.cancel()
        }
        subscriptions.removeAll()

        // Close event stream
        eventContinuation.finish()

        // Close server channel
        try? await channel?.close()

        // Shutdown event loop group
        try? await eventLoopGroup.shutdownGracefully()

        print("✅ UPnP Event Listener shut down")
    }

    // MARK: - Subscription Management

    /// Subscribe to UPnP events for a device
    func subscribe(deviceUUID: String, deviceIP: String, service: UPnPService = .zoneGroupTopology) async throws -> String {
        print("📡 Subscribing to \(service.rawValue) on \(deviceIP)...")

        let subscriptionURL = "http://\(deviceIP):1400\(service.endpoint)/Event"

        var request = URLRequest(url: URL(string: subscriptionURL)!)
        request.httpMethod = "SUBSCRIBE"
        request.setValue("<\(callbackURL)>", forHTTPHeaderField: "CALLBACK")
        request.setValue("Second-1800", forHTTPHeaderField: "TIMEOUT") // 30 minutes
        request.setValue("upnp:event", forHTTPHeaderField: "NT") // Notification Type
        request.setValue("upnp:propchange", forHTTPHeaderField: "NTS") // Notification Sub Type

        do {
            let (_, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let sid = httpResponse.value(forHTTPHeaderField: "SID"),
                  let timeoutHeader = httpResponse.value(forHTTPHeaderField: "TIMEOUT") else {
                print("❌ Subscription request failed for \(deviceIP)")
                if let httpResponse = response as? HTTPURLResponse {
                    print("   Status: \(httpResponse.statusCode)")
                }
                throw SubscriptionError.invalidResponse
            }

            let timeout = parseTimeout(timeoutHeader) ?? 1800
            let expiresAt = Date().addingTimeInterval(TimeInterval(timeout))

            print("✅ Subscribed with SID: \(sid), expires in \(timeout)s")

            // Schedule renewal at 80% of timeout (before expiration)
            let renewalDelay = TimeInterval(timeout) * 0.8
            let renewalTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(renewalDelay * 1_000_000_000))

                guard !Task.isCancelled else { return }

                do {
                    try await self?.renew(sid: sid, deviceIP: deviceIP, service: service)
                } catch {
                    print("⚠️ Failed to renew subscription \(sid): \(error)")
                    // Emit expiration event
                    self?.eventContinuation.yield(.subscriptionExpired(sid: sid))
                }
            }

            // Store subscription
            var subscription = Subscription(
                sid: sid,
                deviceUUID: deviceUUID,
                deviceIP: deviceIP,
                service: service,
                expiresAt: expiresAt,
                renewalTask: nil
            )
            subscription.renewalTask = renewalTask
            subscriptions[sid] = subscription

            return sid

        } catch {
            print("❌ Subscription failed: \(error)")
            throw SubscriptionError.networkError(error)
        }
    }

    /// Unsubscribe from UPnP events
    func unsubscribe(sid: String) async throws {
        print("🔕 Unsubscribing \(sid)...")

        guard let subscription = subscriptions[sid] else {
            print("⚠️ Subscription not found: \(sid)")
            return
        }

        // Cancel renewal task
        subscription.renewalTask?.cancel()

        // Send UNSUBSCRIBE request
        let subscriptionURL = "http://\(subscription.deviceIP):1400\(subscription.service.endpoint)/Event"

        var request = URLRequest(url: URL(string: subscriptionURL)!)
        request.httpMethod = "UNSUBSCRIBE"
        request.setValue(sid, forHTTPHeaderField: "SID")

        do {
            let (_, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode == 200 {
                print("✅ Unsubscribed \(sid)")
            } else {
                print("⚠️ Unsubscribe returned non-200 status")
            }
        } catch {
            print("⚠️ Unsubscribe error: \(error)")
        }

        // Remove from tracking
        subscriptions.removeValue(forKey: sid)
    }

    /// Renew an existing subscription before it expires
    private func renew(sid: String, deviceIP: String, service: UPnPService) async throws {
        print("🔄 Renewing subscription \(sid)...")

        let subscriptionURL = "http://\(deviceIP):1400\(service.endpoint)/Event"

        var request = URLRequest(url: URL(string: subscriptionURL)!)
        request.httpMethod = "SUBSCRIBE"
        request.setValue(sid, forHTTPHeaderField: "SID")
        request.setValue("Second-1800", forHTTPHeaderField: "TIMEOUT")

        do {
            let (_, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let timeoutHeader = httpResponse.value(forHTTPHeaderField: "TIMEOUT") else {
                throw SubscriptionError.invalidResponse
            }

            let timeout = parseTimeout(timeoutHeader) ?? 1800
            let expiresAt = Date().addingTimeInterval(TimeInterval(timeout))

            print("✅ Renewed \(sid), expires in \(timeout)s")

            // Update subscription with new expiration
            if var subscription = subscriptions[sid] {
                subscription.renewalTask?.cancel()

                let renewalDelay = TimeInterval(timeout) * 0.8
                let renewalTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(renewalDelay * 1_000_000_000))

                    guard !Task.isCancelled else { return }

                    try? await self?.renew(sid: sid, deviceIP: deviceIP, service: service)
                }

                subscription.expiresAt = expiresAt
                subscription.renewalTask = renewalTask
                subscriptions[sid] = subscription
            }

        } catch {
            print("❌ Renewal failed: \(error)")
            throw SubscriptionError.networkError(error)
        }
    }

    /// Parse timeout from TIMEOUT header (e.g., "Second-1800" -> 1800)
    private func parseTimeout(_ header: String) -> Int? {
        let components = header.split(separator: "-")
        guard components.count == 2,
              let timeout = Int(components[1]) else {
            return nil
        }
        return timeout
    }

    // MARK: - Server Setup

    private static func startServer(
        on requestedPort: Int,
        eventLoopGroup: EventLoopGroup,
        listener: UnsafeListenerReference
    ) async throws -> (Int, Channel) {

        let bootstrap = ServerBootstrap(group: eventLoopGroup)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(NotifyRequestHandler(listener: listener))
                }
            }

        let channel = try await bootstrap.bind(host: "0.0.0.0", port: requestedPort).get()
        guard let localAddress = channel.localAddress,
              let actualPort = localAddress.port else {
            throw SubscriptionError.serverNotRunning
        }

        return (actualPort, channel)
    }

    // MARK: - Local IP Discovery

    private static func getLocalIPAddress() -> String {
        var address: String = "127.0.0.1"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0 else {
            return address
        }
        defer { freeifaddrs(ifaddr) }

        var ptr = ifaddr
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }

            guard let interface = ptr?.pointee else { continue }
            let addrFamily = interface.ifa_addr.pointee.sa_family

            // Check for IPv4
            if addrFamily == UInt8(AF_INET) {
                // Get interface name
                let name = String(cString: interface.ifa_name)

                // Skip loopback
                if name == "lo0" { continue }

                // Convert address
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(
                    interface.ifa_addr,
                    socklen_t(interface.ifa_addr.pointee.sa_len),
                    &hostname,
                    socklen_t(hostname.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                ) == 0 {
                    address = String(cString: hostname)
                    // Prefer en0 (WiFi) or en1 (Ethernet)
                    if name.hasPrefix("en") {
                        return address
                    }
                }
            }
        }

        return address
    }

    // MARK: - Event Handling

    func handleNotify(headers: HTTPHeaders, body: String) async {
        print("📨 Received NOTIFY callback")

        // Extract SID from headers
        guard let sid = headers.first(name: "SID") else {
            print("⚠️ NOTIFY missing SID header")
            return
        }

        // Verify subscription exists
        guard let subscription = subscriptions[sid] else {
            print("⚠️ Unknown subscription: \(sid)")
            return
        }

        print("✅ Processing \(subscription.service.rawValue) event for subscription: \(sid)")

        // Route event to appropriate stream based on service type
        switch subscription.service {
        case .zoneGroupTopology:
            eventContinuation.yield(.topologyChanged(xml: body))
        case .avTransport:
            parseAndEmitTransportEvent(deviceUUID: subscription.deviceUUID, xml: body)
        case .renderingControl:
            // Future: Handle rendering control events (volume changes, etc.)
            print("⚠️ RenderingControl events not yet implemented")
        }
    }

    /// Parse AVTransport LastChange XML and emit transport state event
    private func parseAndEmitTransportEvent(deviceUUID: String, xml: String) {
        // First, extract the LastChange value (which is HTML-encoded)
        guard let lastChangeEncoded = extractValue(from: xml, key: "LastChange") else {
            print("⚠️ Failed to extract LastChange from AVTransport event")
            return
        }
        
        // Decode HTML entities to get the actual XML
        let lastChangeXML = lastChangeEncoded
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
        
        // Now parse the decoded LastChange XML to extract transport state
        guard let transportState = extractValue(from: lastChangeXML, key: "TransportState") else {
            print("⚠️ Failed to extract TransportState from AVTransport event")
            return
        }

        let trackURI = extractValue(from: lastChangeXML, key: "CurrentTrackURI")
        let metadata = extractValue(from: lastChangeXML, key: "CurrentTrackMetaData")

        print("🎵 Transport state changed: \(transportState) for device \(deviceUUID)")

        transportContinuation.yield(.transportStateChanged(
            deviceUUID: deviceUUID,
            state: transportState,
            trackURI: trackURI,
            metadata: metadata
        ))
    }

    /// Extract a value from XML (handles both val="..." attributes and element content)
    private func extractValue(from xml: String, key: String) -> String? {
        // Try pattern 1: <key val="value"/> (for attributes)
        let attrPattern = "<\(key)\\s+val=\"([^\"]*)\""
        if let regex = try? NSRegularExpression(pattern: attrPattern),
           let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
           match.numberOfRanges > 1,
           let valueRange = Range(match.range(at: 1), in: xml) {
            let value = String(xml[valueRange])
            return value.replacingOccurrences(of: "&quot;", with: "\"")
                        .replacingOccurrences(of: "&lt;", with: "<")
                        .replacingOccurrences(of: "&gt;", with: ">")
                        .replacingOccurrences(of: "&amp;", with: "&")
        }
        
        // Try pattern 2: <key>content</key> (for element content)
        let contentPattern = "<\(key)>([^<]*)</\(key)>"
        if let regex = try? NSRegularExpression(pattern: contentPattern),
           let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
           match.numberOfRanges > 1,
           let valueRange = Range(match.range(at: 1), in: xml) {
            return String(xml[valueRange])
        }
        
        return nil
    }
}

// MARK: - Unsafe Reference Helper

/// Unsafe wrapper to pass actor reference to NIO handlers
/// This is necessary because NIO handlers are not Sendable-aware yet
struct UnsafeListenerReference: @unchecked Sendable {
    private let listener: UPnPEventListener

    init(_ listener: UPnPEventListener) {
        self.listener = listener
    }

    func handleNotify(headers: HTTPHeaders, body: String) async {
        await listener.handleNotify(headers: headers, body: body)
    }
}

// MARK: - HTTP Request Handler

final class NotifyRequestHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let listener: UnsafeListenerReference
    private var headers: HTTPHeaders?
    private var bodyBuffer: ByteBuffer?

    init(listener: UnsafeListenerReference) {
        self.listener = listener
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let reqPart = self.unwrapInboundIn(data)

        switch reqPart {
        case .head(let head):
            self.headers = head.headers
            self.bodyBuffer = nil

        case .body(var buffer):
            if self.bodyBuffer == nil {
                self.bodyBuffer = buffer
            } else {
                self.bodyBuffer?.writeBuffer(&buffer)
            }

        case .end:
            guard let headers = self.headers else {
                sendResponse(context: context, status: .badRequest)
                return
            }

            let bodyString = bodyBuffer.flatMap { buffer in
                String(buffer: buffer)
            } ?? ""

            // Handle NOTIFY request asynchronously
            Task { @Sendable in
                await listener.handleNotify(headers: headers, body: bodyString)
            }

            // Send 200 OK response
            sendResponse(context: context, status: .ok)
        }
    }

    private func sendResponse(context: ChannelHandlerContext, status: HTTPResponseStatus) {
        let headers = HTTPHeaders([("Content-Length", "0")])
        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)

        context.write(self.wrapOutboundOut(.head(head)), promise: nil)
        context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
    }
}
