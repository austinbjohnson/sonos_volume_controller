import Foundation
import CoreAudio

class AudioDeviceMonitor {
    private let settings: AppSettings
    private(set) var currentDeviceName: String = "Unknown"
    private var currentDeviceID: AudioDeviceID = 0

    init(settings: AppSettings) {
        self.settings = settings
    }

    func start() {
        updateCurrentDevice()
        setupDeviceChangeListener()
    }

    var shouldInterceptVolumeKeys: Bool {
        guard settings.enabled else { return false }
        return currentDeviceName == settings.triggerDeviceName
    }

    func getAllAudioDevices() -> [String] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        )

        guard status == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )

        guard status == noErr else { return [] }

        // Get names and filter to output devices only
        var deviceNames: [String] = []
        for deviceID in deviceIDs {
            if isOutputDevice(deviceID: deviceID) {
                let name = getDeviceName(deviceID: deviceID)
                if !name.isEmpty && name != "Unknown" {
                    deviceNames.append(name)
                }
            }
        }

        return deviceNames.sorted()
    }

    private func isOutputDevice(deviceID: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize
        )

        return status == noErr && dataSize > 0
    }

    private func updateCurrentDevice() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &size,
            &deviceID
        )

        guard status == noErr else {
            print("Error getting default audio device")
            return
        }

        currentDeviceID = deviceID
        currentDeviceName = getDeviceName(deviceID: deviceID)
        print("Current audio device: \(currentDeviceName)")
    }

    private func getDeviceName(deviceID: AudioDeviceID) -> String {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &size,
            &name
        )

        guard status == noErr else {
            return "Unknown"
        }

        return name as String
    }

    private func setupDeviceChangeListener() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let callback: AudioObjectPropertyListenerProc = { _, _, _, userData in
            guard let userData = userData else { return 0 }
            let monitor = Unmanaged<AudioDeviceMonitor>.fromOpaque(userData).takeUnretainedValue()
            monitor.updateCurrentDevice()
            return 0
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            callback,
            selfPtr
        )
    }
}