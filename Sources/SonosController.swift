import Foundation
import Network

class SonosController {
    private let settings: AppSettings
    private var devices: [SonosDevice] = []
    private var selectedDevice: SonosDevice?
    private let volumeStep = 5 // Volume change per key press

    struct SonosDevice {
        let name: String
        let ipAddress: String
        let uuid: String
    }

    init(settings: AppSettings) {
        self.settings = settings
    }

    func discoverDevices() {
        print("Discovering Sonos devices...")

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
                self.devices = foundDevices
                print("Found \(foundDevices.count) Sonos devices")
                for device in foundDevices {
                    print("  - \(device.name) at \(device.ipAddress)")
                }
            }
        } catch {
            print("SSDP Discovery error: \(error)")
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

        // Fetch device description to get friendly name
        let name = fetchDeviceName(from: location) ?? host

        return SonosDevice(name: name, ipAddress: host, uuid: location)
    }

    private func fetchDeviceName(from location: String) -> String? {
        guard let url = URL(string: location) else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 2.0

        var result: String?
        let semaphore = DispatchSemaphore(value: 0)

        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }

            guard let data = data,
                  let xml = String(data: data, encoding: .utf8) else {
                return
            }

            // Simple XML parsing for roomName or friendlyName
            if let nameRange = xml.range(of: "<roomName>([^<]+)</roomName>", options: .regularExpression) {
                let nameString = String(xml[nameRange])
                result = nameString.replacingOccurrences(of: "<roomName>", with: "")
                    .replacingOccurrences(of: "</roomName>", with: "")
            } else if let nameRange = xml.range(of: "<friendlyName>([^<]+)</friendlyName>", options: .regularExpression) {
                let nameString = String(xml[nameRange])
                result = nameString.replacingOccurrences(of: "<friendlyName>", with: "")
                    .replacingOccurrences(of: "</friendlyName>", with: "")
            }
        }.resume()

        _ = semaphore.wait(timeout: .now() + 3)
        return result
    }

    func selectDevice(name: String) {
        selectedDevice = devices.first { $0.name == name }
        if let device = selectedDevice {
            settings.selectedSonosDevice = device.name
            print("Selected Sonos device: \(device.name)")
        }
    }

    func volumeUp() {
        changeVolume(by: volumeStep)
    }

    func volumeDown() {
        changeVolume(by: -volumeStep)
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
            print("No Sonos device selected")
            return
        }

        // Get current volume
        sendSonosCommand(to: device, action: "GetVolume") { currentVolumeStr in
            guard let currentVolume = Int(currentVolumeStr) else { return }
            let newVolume = max(0, min(100, currentVolume + delta))
            self.sendSonosCommand(to: device, action: "SetVolume", arguments: ["DesiredVolume": String(newVolume)])
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

// Simple UDP socket helper
class Socket {
    private var socket: NWConnection?

    init() throws {
        let host = NWEndpoint.Host("239.255.255.250")
        let port = NWEndpoint.Port(integerLiteral: 1900)

        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true

        socket = NWConnection(host: host, port: port, using: parameters)
        socket?.start(queue: .global())
    }

    func send(_ message: String, to address: String, port: UInt16) throws {
        let data = message.data(using: .utf8)!
        socket?.send(content: data, completion: .contentProcessed({ error in
            if let error = error {
                print("Send error: \(error)")
            }
        }))
    }

    func receive(timeout: TimeInterval) throws -> (data: String, address: String)? {
        var result: (String, String)?
        let semaphore = DispatchSemaphore(value: 0)

        socket?.receiveMessage { data, context, isComplete, error in
            defer { semaphore.signal() }

            if let data = data, let string = String(data: data, encoding: .utf8) {
                result = (string, "unknown")
            }
        }

        _ = semaphore.wait(timeout: .now() + timeout)
        return result
    }
}