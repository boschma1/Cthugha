import Foundation
import AppKit
import CoreAudio
import AudioToolbox

// A running application that is currently producing audio, together with the
// Core Audio process object IDs that belong to it (an app such as a browser can
// own several helper processes, all of which we tap together).
struct AudioApp: Equatable {
    let bundleID: String
    let name: String
    let objectIDs: [AudioObjectID]

    static func == (lhs: AudioApp, rhs: AudioApp) -> Bool { lhs.bundleID == rhs.bundleID }

    // Short uppercase tag for the Dock badge, e.g. "SPO" for Spotify.
    var badgeTag: String {
        let letters = name.uppercased().filter { $0.isLetter || $0.isNumber }
        return String(letters.prefix(3))
    }
}

// Helpers for enumerating audio processes and per-app capture via Core Audio
// process taps (macOS 14.4+). No Screen Recording permission is required.
enum ProcessAudio {
    static func addr(_ selector: AudioObjectPropertySelector,
                     _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                     _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private static func stringProperty(_ obj: AudioObjectID,
                                       _ selector: AudioObjectPropertySelector) -> String? {
        var address = addr(selector)
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(obj, &address, 0, nil, &size, &cf)
        guard status == noErr, let value = cf else { return nil }
        let str = value.takeRetainedValue() as String
        return str.isEmpty ? nil : str
    }

    private static func pidProperty(_ obj: AudioObjectID) -> pid_t {
        var address = addr(kAudioProcessPropertyPID)
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        AudioObjectGetPropertyData(obj, &address, 0, nil, &size, &pid)
        return pid
    }

    // Every process object Core Audio knows about, with its pid and bundle id.
    static func audioProcesses() -> [(objectID: AudioObjectID, pid: pid_t, bundleID: String)] {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var address = addr(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(sys, &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(sys, &address, 0, nil, &size, &ids) == noErr else { return [] }

        var out: [(AudioObjectID, pid_t, String)] = []
        for id in ids {
            guard let bundle = stringProperty(id, kAudioProcessPropertyBundleID) else { continue }
            out.append((id, pidProperty(id), bundle))
        }
        return out
    }

    // Group the audio processes under the regular (Dock) applications that own
    // them, so the caller gets one entry per app (Spotify, Music, a browser…).
    static func listAudioApps(excludingBundleID excluded: String) -> [AudioApp] {
        let processes = audioProcesses()
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != nil
        }

        var groups: [String: (name: String, ids: [AudioObjectID])] = [:]
        for proc in processes {
            guard proc.bundleID != excluded else { continue }

            // Prefer a direct pid match, else attribute helper processes to the
            // owning app by bundle-id prefix (e.g. com.google.Chrome.helper).
            var owner = running.first { $0.processIdentifier == proc.pid }
            if owner == nil {
                owner = running.first { app in
                    guard let bid = app.bundleIdentifier else { return false }
                    return proc.bundleID == bid || proc.bundleID.hasPrefix(bid + ".")
                }
            }
            guard let app = owner, let bid = app.bundleIdentifier else { continue }
            let name = app.localizedName ?? bid
            groups[bid, default: (name, [])].ids.append(proc.objectID)
        }

        return groups
            .map { AudioApp(bundleID: $0.key, name: $0.value.name, objectIDs: $0.value.ids) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// Captures the audio of one specific application via a private Core Audio
// process tap fed through a private aggregate device.
final class ProcessTapAudioSource: AudioSource {
    let name: String
    let bundleID: String
    var badgeTag: String

    private let store: WaveformStore
    private let objectIDs: [AudioObjectID]
    private let ioQueue = DispatchQueue(label: "ink.qualified.cthugha.tap")

    private var tapID = AudioObjectID(0)
    private var aggregateID = AudioObjectID(0)
    private var ioProcID: AudioDeviceIOProcID?

    init(app: AudioApp, store: WaveformStore) {
        self.name = app.name
        self.bundleID = app.bundleID
        self.badgeTag = app.badgeTag
        self.store = store
        self.objectIDs = app.objectIDs
    }

    func start() async throws {
        guard !objectIDs.isEmpty else {
            throw NSError(domain: "Cthugha", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "\(name) is not producing audio."])
        }

        // 1) Private tap that mixes the app's processes down to stereo while
        //    leaving playback audible (.unmuted).
        let desc = CATapDescription(stereoMixdownOfProcesses: objectIDs)
        desc.name = "Cthugha-\(name)"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted

        var tap = AudioObjectID(0)
        var status = AudioHardwareCreateProcessTap(desc, &tap)
        guard status == noErr, tap != 0 else {
            throw NSError(domain: "Cthugha", code: 11,
                          userInfo: [NSLocalizedDescriptionKey:
                                        "Could not tap \(name) (Core Audio error \(status))."])
        }
        tapID = tap

        // 2) Tap's audio format (for interpreting the callback buffers).
        var asbd = AudioStreamBasicDescription()
        var fmtAddr = ProcessAudio.addr(kAudioTapPropertyFormat)
        var fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioObjectGetPropertyData(tap, &fmtAddr, 0, nil, &fmtSize, &asbd)
        let channels = max(1, Int(asbd.mChannelsPerFrame))

        // 3) Private aggregate device wrapping the tap.
        let aggUID = UUID().uuidString
        let subTap: [String: Any] = [
            kAudioSubTapUIDKey as String: desc.uuid.uuidString,
            kAudioSubTapDriftCompensationKey as String: true,
        ]
        let aggDict: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Cthugha Tap",
            kAudioAggregateDeviceUIDKey as String: aggUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [subTap],
        ]
        var agg = AudioObjectID(0)
        status = AudioHardwareCreateAggregateDevice(aggDict as CFDictionary, &agg)
        guard status == noErr, agg != 0 else {
            AudioHardwareDestroyProcessTap(tapID); tapID = 0
            throw NSError(domain: "Cthugha", code: 12,
                          userInfo: [NSLocalizedDescriptionKey:
                                        "Could not create capture device for \(name) (error \(status))."])
        }
        aggregateID = agg

        // 4) IOProc that downmixes each buffer to mono and feeds the store.
        let store = self.store
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, agg, ioQueue) {
            _, inInputData, _, _, _ in
            let abl = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inInputData))
            ProcessTapAudioSource.pushMono(abl, channels: channels, to: store)
        }
        guard status == noErr else {
            teardown()
            throw NSError(domain: "Cthugha", code: 13,
                          userInfo: [NSLocalizedDescriptionKey:
                                        "Could not start capture for \(name) (error \(status))."])
        }

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            teardown()
            throw NSError(domain: "Cthugha", code: 14,
                          userInfo: [NSLocalizedDescriptionKey:
                                        "Could not start capture for \(name) (error \(status))."])
        }
    }

    func stop() { teardown() }

    private func teardown() {
        if let proc = ioProcID {
            if aggregateID != 0 { AudioDeviceStop(aggregateID, proc) }
            if aggregateID != 0 { AudioDeviceDestroyIOProcID(aggregateID, proc) }
            ioProcID = nil
        }
        if aggregateID != 0 { AudioHardwareDestroyAggregateDevice(aggregateID); aggregateID = 0 }
        if tapID != 0 { AudioHardwareDestroyProcessTap(tapID); tapID = 0 }
    }

    private static func pushMono(_ abl: UnsafeMutableAudioBufferListPointer,
                                 channels: Int, to store: WaveformStore) {
        guard abl.count > 0 else { return }
        if abl.count == 1 {
            // Interleaved.
            let buf = abl[0]
            guard let data = buf.mData else { return }
            let ch = max(1, channels)
            let total = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
            let frames = total / ch
            guard frames > 0 else { return }
            let ptr = data.assumingMemoryBound(to: Float.self)
            var out = [Float](repeating: 0, count: frames)
            for f in 0..<frames {
                var acc: Float = 0
                for c in 0..<ch { acc += ptr[f * ch + c] }
                out[f] = acc / Float(ch)
            }
            store.push(out)
        } else {
            // Non-interleaved / planar: one buffer per channel.
            let ch = abl.count
            let frames = Int(abl[0].mDataByteSize) / MemoryLayout<Float>.size
            guard frames > 0 else { return }
            var out = [Float](repeating: 0, count: frames)
            for c in 0..<ch {
                guard let data = abl[c].mData else { continue }
                let ptr = data.assumingMemoryBound(to: Float.self)
                let n = min(frames, Int(abl[c].mDataByteSize) / MemoryLayout<Float>.size)
                for f in 0..<n { out[f] += ptr[f] }
            }
            for f in 0..<frames { out[f] /= Float(ch) }
            store.push(out)
        }
    }
}
