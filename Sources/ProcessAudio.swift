import Foundation
import AppKit
import CoreAudio
import AudioToolbox
import AVFoundation
import CoreGraphics

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
// process taps (macOS 14.4+). Capturing another app's audio this way requires
// the "Screen & System Audio Recording" permission (the same one
// ScreenCaptureKit uses); without it the tap is created but delivers silence.
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

    // The Core Audio process objects that currently belong to one app (matched by
    // its bundle id, including helper processes such as com.google.Chrome.helper).
    // Re-resolved on demand so a tap always targets the app's *current* audio
    // processes, which change across track switches, pause/resume and re-inits.
    static func objectIDs(forBundleID bid: String) -> [AudioObjectID] {
        audioProcesses()
            .filter { $0.bundleID == bid || $0.bundleID.hasPrefix(bid + ".") }
            .map { $0.objectID }
    }

    // Whether Cthugha already holds Microphone (audio-input) authorization, used
    // by the microphone source and the mic fallback (not by process taps).
    static var isAudioInputAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    // Prompt for Microphone (audio-input) access if it hasn't been decided yet.
    // Called at launch so the permission dialog appears up front rather than the
    // first per-app tap silently returning zeros.
    @discardableResult
    static func requestAudioInputAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}

// Thrown when a per-app tap can't capture because "Screen & System Audio
// Recording" access is off, so the UI can point the user straight at the
// relevant System Settings pane.
enum ProcessTapError: LocalizedError {
    case screenRecordingDenied(String)
    var errorDescription: String? {
        switch self {
        case .screenRecordingDenied(let app):
            return "\(app) audio can't be captured without Screen & System Audio Recording access. " +
                   "Enable it for Cthugha in System Settings ▸ Privacy & Security ▸ " +
                   "Screen & System Audio Recording, then reselect the source."
        }
    }
}

// Captures the audio of one specific application via a private Core Audio
// process tap fed through a private aggregate device.
final class ProcessTapAudioSource: AudioSource {
    let name: String
    let bundleID: String
    var badgeTag: String

    private let store: WaveformStore
    private var objectIDs: [AudioObjectID]
    private let ioQueue = DispatchQueue(label: "ink.qualified.cthugha.tap")

    private var tapID = AudioObjectID(0)
    private var aggregateID = AudioObjectID(0)
    private var ioProcID: AudioDeviceIOProcID?

    // Steers the system default input off Bluetooth while the tap runs. Creating
    // and starting the tap's aggregate device otherwise forces a Bluetooth headset
    // onto the low-quality HFP profile, wrecking the user's playback.
    private let btGuard = BluetoothPlaybackGuard()

    // Timestamp of the last non-silent buffer, so a watchdog can notice when a
    // tap has gone silent (e.g. its process object went stale) and rebuild it.
    private let audioLock = NSLock()
    private var lastAudioAt: CFAbsoluteTime = 0

    // The process objects this tap is currently listening to (re-resolved at
    // start), exposed so the watchdog can tell whether fresher objects exist.
    private(set) var activeObjectIDs: [AudioObjectID] = []

    init(app: AudioApp, store: WaveformStore) {
        self.name = app.name
        self.bundleID = app.bundleID
        self.badgeTag = app.badgeTag
        self.store = store
        self.objectIDs = app.objectIDs
    }

    func secondsSinceAudio() -> CFAbsoluteTime {
        audioLock.lock(); defer { audioLock.unlock() }
        return CFAbsoluteTimeGetCurrent() - lastAudioAt
    }

    // Synchronous so it is safe to call from both the async `start()` and the
    // real-time IOProc without tripping Swift's async-context lock checks.
    private func markAudio() {
        audioLock.lock(); lastAudioAt = CFAbsoluteTimeGetCurrent(); audioLock.unlock()
    }

    // Ensure "Screen & System Audio Recording" authorization before creating a
    // tap; on macOS 14.4+ a Core Audio process tap of another app's audio is
    // created successfully but only ever delivers *silence* unless the app holds
    // this permission (the same TCC grant ScreenCaptureKit uses). Microphone
    // access is unrelated and is not sufficient.
    private static func ensureScreenRecordingAuthorized(for app: String) throws {
        if CGPreflightScreenCaptureAccess() { return }
        // Surface the system prompt if the permission hasn't been decided yet.
        if CGRequestScreenCaptureAccess() { return }
        throw ProcessTapError.screenRecordingDenied(app)
    }

    func start() async throws {
        // Re-resolve the app's audio process objects right now — the ids captured
        // when the menu was built can be stale by the time the user selects them.
        let fresh = ProcessAudio.objectIDs(forBundleID: bundleID)
        if !fresh.isEmpty { objectIDs = fresh }
        activeObjectIDs = objectIDs

        guard !objectIDs.isEmpty else {
            throw NSError(domain: "Cthugha", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "\(name) is not producing audio."])
        }

        // A process tap of another app's audio delivers *zeros* unless Cthugha
        // holds "Screen & System Audio Recording" access, so require it before
        // creating the tap — otherwise the visuals just stay calm with no hint why.
        try Self.ensureScreenRecordingAuthorized(for: name)

        // Creating and starting the tap's aggregate device activates the system
        // default input; if that's a Bluetooth headset it would be forced onto the
        // mono HFP profile and ruin the user's music. Steer the default input to a
        // non-Bluetooth device for the lifetime of the tap.
        btGuard.engage(reason: "to keep Bluetooth playback in full A2DP quality while capturing \(name).")

        markAudio()

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
        _ = AudioObjectGetPropertyData(tap, &fmtAddr, 0, nil, &fmtSize, &asbd)
        let channels = max(1, Int(asbd.mChannelsPerFrame))

        // 3) Aggregate device wrapping the tap.
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
            [weak self] _, inInputData, _, _, _ in
            let abl = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inInputData))
            let peak = ProcessTapAudioSource.pushMono(abl, channels: channels, to: store)
            if peak > 0.002, let self {
                self.markAudio()
            }
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
        btGuard.release()
    }

    @discardableResult
    private static func pushMono(_ abl: UnsafeMutableAudioBufferListPointer,
                                 channels: Int, to store: WaveformStore) -> Float {
        guard abl.count > 0 else { return 0 }
        var peak: Float = 0
        if abl.count == 1 {
            // Interleaved.
            let buf = abl[0]
            guard let data = buf.mData else { return 0 }
            let ch = max(1, channels)
            let total = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
            let frames = total / ch
            guard frames > 0 else { return 0 }
            let ptr = data.assumingMemoryBound(to: Float.self)
            var out = [Float](repeating: 0, count: frames)
            for f in 0..<frames {
                var acc: Float = 0
                for c in 0..<ch { acc += ptr[f * ch + c] }
                let v = acc / Float(ch)
                out[f] = v
                peak = max(peak, abs(v))
            }
            store.push(out)
        } else {
            // Non-interleaved / planar: one buffer per channel.
            let ch = abl.count
            let frames = Int(abl[0].mDataByteSize) / MemoryLayout<Float>.size
            guard frames > 0 else { return 0 }
            var out = [Float](repeating: 0, count: frames)
            for c in 0..<ch {
                guard let data = abl[c].mData else { continue }
                let ptr = data.assumingMemoryBound(to: Float.self)
                let n = min(frames, Int(abl[c].mDataByteSize) / MemoryLayout<Float>.size)
                for f in 0..<n { out[f] += ptr[f] }
            }
            for f in 0..<frames { out[f] /= Float(ch); peak = max(peak, abs(out[f])) }
            store.push(out)
        }
        return peak
    }
}
