import AppKit
import CoreAudio

/// `audio` lists sound outputs and inputs; Return switches the default device.
/// CoreAudio directly, no extra tools.
enum AudioDevices {
    static let keywords: Set<String> = ["audio", "sound", "output", "speaker", "speakers", "mic"]

    struct Device {
        let id: AudioDeviceID
        let name: String
        let outputs: Bool
        let inputs: Bool
    }

    private static func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ value: inout T) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr
    }

    private static func channels(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func devices() -> [Device] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var name: CFString = "" as CFString
            guard property(id, kAudioObjectPropertyName, &name) else { return nil }
            let out = channels(id, kAudioObjectPropertyScopeOutput) > 0
            let inp = channels(id, kAudioObjectPropertyScopeInput) > 0
            return out || inp ? Device(id: id, name: name as String, outputs: out, inputs: inp) : nil
        }
    }

    private static func current(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
        var id: AudioDeviceID = 0
        _ = property(AudioObjectID(kAudioObjectSystemObject), selector, &id)
        return id
    }

    private static func set(_ selector: AudioObjectPropertySelector, _ id: AudioDeviceID) {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = id
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &value)
        Log.write("audio: set device \(id): \(status)")
    }

    static func results(argument: String) -> [Result] {
        let f = argument.lowercased().trimmingCharacters(in: .whitespaces)
        let all = devices()
        let out = current(kAudioHardwarePropertyDefaultOutputDevice)
        let inp = current(kAudioHardwarePropertyDefaultInputDevice)
        var rows: [Result] = []
        let wantInputs = f.hasPrefix("in") || f == "mic"
        for d in all where d.outputs && !wantInputs && (f.isEmpty || f.hasPrefix("out") || d.name.lowercased().contains(f)) {
            let isCurrent = d.id == out
            rows.append(Result(id: "audio:out:\(d.name)", title: isCurrent ? "\(d.name) · playing now" : "Play Sound on \(d.name)",
                               subtitle: "Output", icon: NSImage(systemSymbolName: isCurrent ? "speaker.wave.2.fill" : "speaker.wave.2", accessibilityDescription: nil),
                               action: isCurrent ? .none : .custom {
                                   set(kAudioHardwarePropertyDefaultOutputDevice, d.id)
                                   set(kAudioHardwarePropertyDefaultSystemOutputDevice, d.id)
                               }))
        }
        for d in all where d.inputs && (wantInputs || (!f.hasPrefix("out") && (f.isEmpty || d.name.lowercased().contains(f)))) {
            let isCurrent = d.id == inp
            rows.append(Result(id: "audio:in:\(d.name)", title: isCurrent ? "\(d.name) · microphone now" : "Use \(d.name) as Microphone",
                               subtitle: "Input", icon: NSImage(systemSymbolName: isCurrent ? "mic.fill" : "mic", accessibilityDescription: nil),
                               action: isCurrent ? .none : .custom { set(kAudioHardwarePropertyDefaultInputDevice, d.id) }))
        }
        return rows.isEmpty ? [Result(id: "audio:none", title: "No matching sound device", subtitle: "audio · audio in · audio airpods", icon: nil, action: .none)] : rows
    }
}

extension AudioDevices {
    static var command: KeaCommand {
        KeaCommand(id: "audio", name: "Sound Devices", keywords: keywords,
                   help: [.init(keyword: "audio", summary: "Switch sound output or microphone", example: "audio · audio in · audio airpods")],
                   results: { results(argument: $0.argument) })
    }
}
