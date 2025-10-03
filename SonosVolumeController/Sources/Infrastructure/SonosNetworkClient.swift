import Foundation

/// Network client for making UPnP/SOAP requests to Sonos devices.
/// Handles low-level HTTP communication and SOAP envelope construction.
actor SonosNetworkClient {

    // MARK: - Types

    /// Sonos UPnP service endpoints
    enum Service {
        case zoneGroupTopology
        case renderingControl
        case groupRenderingControl
        case avTransport

        var path: String {
            switch self {
            case .zoneGroupTopology:
                return "/ZoneGroupTopology/Control"
            case .renderingControl:
                return "/MediaRenderer/RenderingControl/Control"
            case .groupRenderingControl:
                return "/MediaRenderer/GroupRenderingControl/Control"
            case .avTransport:
                return "/MediaRenderer/AVTransport/Control"
            }
        }

        var namespace: String {
            switch self {
            case .zoneGroupTopology:
                return "urn:schemas-upnp-org:service:ZoneGroupTopology:1"
            case .renderingControl:
                return "urn:schemas-upnp-org:service:RenderingControl:1"
            case .groupRenderingControl:
                return "urn:schemas-upnp-org:service:GroupRenderingControl:1"
            case .avTransport:
                return "urn:schemas-upnp-org:service:AVTransport:1"
            }
        }
    }

    /// SOAP request configuration
    struct SOAPRequest {
        let service: Service
        let action: String
        let arguments: [String: String]

        init(service: Service, action: String, arguments: [String: String] = [:]) {
            self.service = service
            self.action = action
            self.arguments = arguments
        }
    }

    // MARK: - Constants

    private enum Constants {
        static let sonosPort = 1400
        static let contentType = "text/xml; charset=\"utf-8\""
    }

    // MARK: - Public Methods

    /// Sends a SOAP request to a Sonos device.
    /// - Parameters:
    ///   - request: The SOAP request configuration
    ///   - ipAddress: Target device IP address
    /// - Returns: Response data from the device
    /// - Throws: Network or HTTP errors
    func sendSOAPRequest(_ request: SOAPRequest, to ipAddress: String) async throws -> Data {
        let url = URL(string: "http://\(ipAddress):\(Constants.sonosPort)\(request.service.path)")!

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.addValue(Constants.contentType, forHTTPHeaderField: "Content-Type")
        urlRequest.addValue("\"\(request.service.namespace)#\(request.action)\"", forHTTPHeaderField: "SOAPACTION")

        let soapBody = buildSOAPEnvelope(action: request.action, namespace: request.service.namespace, arguments: request.arguments)
        urlRequest.httpBody = soapBody.data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: urlRequest)
        return data
    }

    /// Sends a SOAP request with a completion handler (for compatibility with existing callback-based code).
    /// - Parameters:
    ///   - request: The SOAP request configuration
    ///   - ipAddress: Target device IP address
    ///   - completion: Callback with optional data and error
    nonisolated func sendSOAPRequest(_ request: SOAPRequest, to ipAddress: String, completion: @escaping @Sendable (Data?, Error?) -> Void) {
        Task {
            do {
                let data = try await sendSOAPRequest(request, to: ipAddress)
                completion(data, nil)
            } catch {
                completion(nil, error)
            }
        }
    }

    // MARK: - Private Methods

    /// Builds a SOAP envelope with the specified action and arguments.
    private func buildSOAPEnvelope(action: String, namespace: String, arguments: [String: String]) -> String {
        var argsXML = ""
        for (key, value) in arguments {
            argsXML += "<\(key)>\(value)</\(key)>"
        }

        return """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
            <s:Body>
                <u:\(action) xmlns:u="\(namespace)">
                    \(argsXML)
                </u:\(action)>
            </s:Body>
        </s:Envelope>
        """
    }
}

// MARK: - Convenience Extensions

extension SonosNetworkClient {

    /// Common rendering control requests
    func setVolume(_ volume: Int, for deviceIP: String, channel: String = "Master") async throws {
        let request = SOAPRequest(
            service: .renderingControl,
            action: "SetVolume",
            arguments: [
                "InstanceID": "0",
                "Channel": channel,
                "DesiredVolume": "\(volume)"
            ]
        )
        _ = try await sendSOAPRequest(request, to: deviceIP)
    }

    func getVolume(for deviceIP: String, channel: String = "Master") async throws -> String {
        let request = SOAPRequest(
            service: .renderingControl,
            action: "GetVolume",
            arguments: [
                "InstanceID": "0",
                "Channel": channel
            ]
        )
        let data = try await sendSOAPRequest(request, to: deviceIP)
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Group rendering control requests
    func setGroupVolume(_ volume: Int, for coordinatorIP: String) async throws {
        let request = SOAPRequest(
            service: .groupRenderingControl,
            action: "SetGroupVolume",
            arguments: [
                "InstanceID": "0",
                "DesiredVolume": "\(volume)"
            ]
        )
        _ = try await sendSOAPRequest(request, to: coordinatorIP)
    }

    func setRelativeGroupVolume(_ adjustment: Int, for coordinatorIP: String) async throws {
        let request = SOAPRequest(
            service: .groupRenderingControl,
            action: "SetRelativeGroupVolume",
            arguments: [
                "InstanceID": "0",
                "Adjustment": "\(adjustment)"
            ]
        )
        _ = try await sendSOAPRequest(request, to: coordinatorIP)
    }

    func snapshotGroupVolume(for coordinatorIP: String) async throws {
        let request = SOAPRequest(
            service: .groupRenderingControl,
            action: "SnapshotGroupVolume",
            arguments: ["InstanceID": "0"]
        )
        _ = try await sendSOAPRequest(request, to: coordinatorIP)
    }

    func getGroupVolume(for coordinatorIP: String) async throws -> String {
        let request = SOAPRequest(
            service: .groupRenderingControl,
            action: "GetGroupVolume",
            arguments: ["InstanceID": "0"]
        )
        let data = try await sendSOAPRequest(request, to: coordinatorIP)
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - AVTransport Operations

    /// Sets the AVTransport URI for a device (used for grouping)
    func setAVTransportURI(_ uri: String, for deviceIP: String, metadata: String = "") async throws {
        let request = SOAPRequest(
            service: .avTransport,
            action: "SetAVTransportURI",
            arguments: [
                "InstanceID": "0",
                "CurrentURI": uri,
                "CurrentURIMetaData": metadata
            ]
        )
        _ = try await sendSOAPRequest(request, to: deviceIP)
    }

    /// Makes a device become a standalone coordinator (used for ungrouping)
    func becomeStandaloneCoordinator(for deviceIP: String) async throws {
        let request = SOAPRequest(
            service: .avTransport,
            action: "BecomeCoordinatorOfStandaloneGroup",
            arguments: ["InstanceID": "0"]
        )
        _ = try await sendSOAPRequest(request, to: deviceIP)
    }

    /// Sends a Play command to start/resume playback
    func play(for deviceIP: String, speed: String = "1") async throws {
        let request = SOAPRequest(
            service: .avTransport,
            action: "Play",
            arguments: [
                "InstanceID": "0",
                "Speed": speed
            ]
        )
        _ = try await sendSOAPRequest(request, to: deviceIP)
    }

    /// Gets the current transport state (PLAYING, PAUSED, STOPPED)
    func getTransportInfo(for deviceIP: String) async throws -> String {
        let request = SOAPRequest(
            service: .avTransport,
            action: "GetTransportInfo",
            arguments: ["InstanceID": "0"]
        )
        let data = try await sendSOAPRequest(request, to: deviceIP)
        return String(data: data, encoding: .utf8) ?? ""
    }
}
