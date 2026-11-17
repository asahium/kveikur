import Foundation
#if os(macOS)
import CoreAudio
#endif

/// Core Audio device id on macOS; unused on iOS, where the audio session picks the route.
public typealias OutputDeviceID = UInt32

public struct OutputDevice: Identifiable, Hashable, Sendable {
    public var id: OutputDeviceID
    public var uid: String
    public var name: String
}

public struct DeviceDetails: Equatable, Sendable {
    public var name = ""
    public var transport = ""
    public var channels = 0
    public var sampleRate = 0.0
    public var supportedRates: [Double] = []
    public var maxBitDepth = 0
    public var physicalBitDepth = 0
    public var hasHardwareVolume = false
}

#if os(macOS)
/// Thin wrappers over the CoreAudio HAL.
public enum AudioHardware {
    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func getValue<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, default value: T) -> T {
        var addr = address(selector, scope: scope)
        var result = value
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &result)
        return status == noErr ? result : value
    }

    private static func getString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    private static func getArray<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, of: T.Type) -> [T] {
        var addr = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let ptr = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { ptr.deallocate() }
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, ptr) == noErr else { return [] }
        return Array(UnsafeBufferPointer(start: ptr, count: count))
    }

    public static func outputDevices() -> [OutputDevice] {
        let ids = getArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices, of: AudioDeviceID.self)
        return ids.compactMap { id in
            var addr = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return nil }
            guard let uid = getString(id, kAudioDevicePropertyDeviceUID) else { return nil }
            let name = getString(id, kAudioObjectPropertyName) ?? uid
            return OutputDevice(id: id, uid: uid, name: name)
        }
    }

    public static func defaultOutputDevice() -> AudioDeviceID {
        getValue(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, default: AudioDeviceID(0))
    }

    public static func device(uid: String) -> AudioDeviceID? {
        outputDevices().first { $0.uid == uid }?.id
    }

    public static func name(of device: AudioDeviceID) -> String {
        getString(device, kAudioObjectPropertyName) ?? "Unknown"
    }

    public static func nominalSampleRate(_ device: AudioDeviceID) -> Double {
        getValue(device, kAudioDevicePropertyNominalSampleRate, default: Float64(0))
    }

    public static func availableSampleRates(_ device: AudioDeviceID) -> [Double] {
        let ranges = getArray(device, kAudioDevicePropertyAvailableNominalSampleRates, of: AudioValueRange.self)
        let common: [Double] = [44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000]
        var rates = Set<Double>()
        for r in ranges {
            if r.mMinimum == r.mMaximum { rates.insert(r.mMinimum) }
            for c in common where c >= r.mMinimum && c <= r.mMaximum { rates.insert(c) }
        }
        return rates.sorted()
    }

    /// Exact rate if supported, otherwise the smallest integer multiple from the same family.
    public static func bestRate(for source: Double, device: AudioDeviceID) -> Double? {
        let rates = availableSampleRates(device)
        if rates.contains(source) { return source }
        return rates.first { $0 > source && $0.truncatingRemainder(dividingBy: source) == 0 }
    }

    @discardableResult
    public static func setNominalSampleRate(_ device: AudioDeviceID, _ rate: Double, timeout: TimeInterval = 1.5) -> Bool {
        if nominalSampleRate(device) == rate { return true }
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var value = Float64(rate)
        guard AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float64>.size), &value) == noErr else { return false }
        // The clock re-locks asynchronously.
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if nominalSampleRate(device) == rate { return true }
            usleep(20_000)
        }
        return nominalSampleRate(device) == rate
    }

    public static func details(_ device: AudioDeviceID) -> DeviceDetails {
        var d = DeviceDetails()
        d.name = name(of: device)
        d.sampleRate = nominalSampleRate(device)
        d.supportedRates = availableSampleRates(device)
        let t: UInt32 = getValue(device, kAudioDevicePropertyTransportType, default: UInt32(0))
        switch t {
        case kAudioDeviceTransportTypeBuiltIn: d.transport = "Built-in"
        case kAudioDeviceTransportTypeUSB: d.transport = "USB"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: d.transport = "Bluetooth"
        case kAudioDeviceTransportTypeHDMI: d.transport = "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: d.transport = "DisplayPort"
        case kAudioDeviceTransportTypeAirPlay: d.transport = "AirPlay"
        case kAudioDeviceTransportTypeThunderbolt: d.transport = "Thunderbolt"
        case kAudioDeviceTransportTypeVirtual: d.transport = "Virtual"
        case kAudioDeviceTransportTypeAggregate: d.transport = "Aggregate"
        default: d.transport = "Other"
        }

        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        if AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 {
            let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
            defer { raw.deallocate() }
            if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr {
                let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
                d.channels = list.reduce(0) { $0 + Int($1.mNumberChannels) }
            }
        }

        let streams = getArray(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput, of: AudioStreamID.self)
        if let s = streams.first {
            let formats = getArray(s, kAudioStreamPropertyAvailablePhysicalFormats, of: AudioStreamRangedDescription.self)
            d.maxBitDepth = Int(formats.map(\.mFormat.mBitsPerChannel).max() ?? 0)
            let phys: AudioStreamBasicDescription = getValue(s, kAudioStreamPropertyPhysicalFormat, default: AudioStreamBasicDescription())
            d.physicalBitDepth = Int(phys.mBitsPerChannel)
        }

        d.hasHardwareVolume = [kAudioObjectPropertyElementMain, 1].contains { element in
            var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                               mScope: kAudioObjectPropertyScopeOutput, mElement: element)
            return AudioObjectHasProperty(device, &a)
        }
        return d
    }

    public static func hogOwner(_ device: AudioDeviceID) -> pid_t {
        getValue(device, kAudioDevicePropertyHogMode, default: pid_t(-1))
    }

    /// Toggling hog mode flips ownership, so only toggle when it differs from what we want.
    @discardableResult
    public static func setHog(_ device: AudioDeviceID, enabled: Bool) -> Bool {
        let me = getpid()
        let owned = hogOwner(device) == me
        guard owned != enabled else { return true }
        var addr = address(kAudioDevicePropertyHogMode)
        var pid: pid_t = enabled ? me : -1
        let status = AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<pid_t>.size), &pid)
        return status == noErr
    }

    /// Calls `handler` on the main queue whenever devices are added or removed, or the default changes.
    public static func observeDevices(_ handler: @escaping () -> Void) {
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var addr = address(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main) { _, _ in
                handler()
            }
        }
    }
}
#endif
