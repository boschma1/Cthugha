import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import CoreAudio
import AudioToolbox

// Thread-safe store of the most recent audio samples (mono, auto-gained).
final class WaveformStore {
    private let lock = NSLock()
    private var ring: [Float]
    private let capacity: Int
    private var writeIndex = 0
    private var peak: Float = 0.02

    init(capacity: Int = 8192) {
        self.capacity = capacity
        self.ring = [Float](repeating: 0, count: capacity)
    }

    // Push a chunk of interleaved-downmixed mono samples with light auto-gain.
    func push(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        var chunkPeak: Float = 0
        for s in samples { chunkPeak = max(chunkPeak, abs(s)) }

        lock.lock()
        peak = max(peak * 0.999, chunkPeak)
        let gain = 0.85 / max(peak, 0.02)
        for s in samples {
            ring[writeIndex] = max(-1.0, min(1.0, s * gain))
            writeIndex = (writeIndex + 1) % capacity
        }
        lock.unlock()
    }

    // Copy the latest `n` samples in chronological order.
    func latest(_ n: Int) -> [Float] {
        var out = [Float](repeating: 0, count: n)
        lock.lock()
        var idx = (writeIndex - n + capacity) % capacity
        for i in 0..<n {
            out[i] = ring[idx]
            idx = (idx + 1) % capacity
        }
        lock.unlock()
        return out
    }

    // Reset the auto-gain envelope so a newly-selected source adapts to its own
    // level immediately instead of inheriting the previous source's loudness
    // (whose slow decay otherwise leaves a quieter source looking near-flat).
    func resetGain() {
        lock.lock()
        peak = 0.02
        lock.unlock()
    }
}

protocol AudioSource: AnyObject {
    var name: String { get }
    func start() async throws
    func stop()
}

// Convert a CMSampleBuffer of PCM audio to mono Float samples.
func monoSamples(from sampleBuffer: CMSampleBuffer) -> [Float] {
    guard let fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
          let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc)
    else { return [] }
    let asbd = asbdPtr.pointee
    let frames = CMSampleBufferGetNumSamples(sampleBuffer)
    if frames == 0 { return [] }

    var sizeNeeded = 0
    CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sampleBuffer, bufferListSizeNeededOut: &sizeNeeded, bufferListOut: nil,
        bufferListSize: 0, blockBufferAllocator: nil,
        blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
    if sizeNeeded == 0 { return [] }

    let ablRaw = UnsafeMutableRawPointer.allocate(
        byteCount: sizeNeeded, alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { ablRaw.deallocate() }
    let ablTyped = ablRaw.assumingMemoryBound(to: AudioBufferList.self)

    var blockBuffer: CMBlockBuffer?
    let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: ablTyped,
        bufferListSize: sizeNeeded, blockBufferAllocator: nil,
        blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &blockBuffer)
    guard status == noErr else { return [] }

    let abl = UnsafeMutableAudioBufferListPointer(ablTyped)
    let channels = max(1, Int(asbd.mChannelsPerFrame))
    let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
    let isInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0

    var out = [Float](repeating: 0, count: frames)

    if isFloat {
        if isInterleaved || abl.count == 1 {
            guard let data = abl[0].mData else { return [] }
            let ptr = data.assumingMemoryBound(to: Float.self)
            let ch = isInterleaved ? channels : 1
            for f in 0..<frames {
                var acc: Float = 0
                for c in 0..<ch { acc += ptr[f * ch + c] }
                out[f] = acc / Float(ch)
            }
        } else {
            let ch = min(channels, abl.count)
            for c in 0..<ch {
                guard let data = abl[c].mData else { continue }
                let ptr = data.assumingMemoryBound(to: Float.self)
                for f in 0..<frames { out[f] += ptr[f] }
            }
            if ch > 0 { for f in 0..<frames { out[f] /= Float(ch) } }
        }
    } else {
        // 16-bit signed integer fallback.
        guard let data = abl[0].mData else { return [] }
        let ptr = data.assumingMemoryBound(to: Int16.self)
        let ch = isInterleaved ? channels : 1
        for f in 0..<frames {
            var acc: Float = 0
            for c in 0..<ch { acc += Float(ptr[f * ch + c]) / 32768.0 }
            out[f] = acc / Float(ch)
        }
    }
    return out
}

// Shared Core Audio device helpers used by both the system-audio and microphone
// capture paths. Bluetooth headsets expose their microphone as a separate input
// endpoint; the moment anything opens that input the headset is forced off the
// high-quality stereo A2DP playback profile and onto the mono "hands-free" (HFP)
// profile, which makes music sound thin and bass-less. These helpers let the
// capture paths steer the system default input away from Bluetooth.
enum AudioDevices {
    static func all() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &devices) == noErr else { return [] }
        return devices
    }

    static func defaultInput() -> AudioDeviceID {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
        return dev
    }

    @discardableResult
    static func setDefaultInput(_ dev: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value = dev
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &value)
        return status == noErr
    }

    static func transportType(_ dev: AudioDeviceID) -> UInt32 {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &transport)
        return transport
    }

    static func isBluetooth(_ dev: AudioDeviceID) -> Bool {
        let t = transportType(dev)
        return t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE
    }

    static func hasInputChannels(_ dev: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, raw) == noErr else { return false }
        let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return abl.contains { $0.mNumberChannels > 0 }
    }

    // A physical input is neither a virtual driver (e.g. conferencing apps, which
    // carry no live signal) nor an aggregate (which could re-include the Bluetooth
    // mic and re-trigger the HFP switch).
    static func isPhysicalInput(_ dev: AudioDeviceID) -> Bool {
        let t = transportType(dev)
        return t != kAudioDeviceTransportTypeVirtual && t != kAudioDeviceTransportTypeAggregate
    }

    // The best non-Bluetooth input: the built-in mic if present, otherwise any
    // other wired/USB input. Returns nil if the only inputs are Bluetooth/virtual.
    static func preferredNonBluetoothInput() -> AudioDeviceID? {
        let inputs = all().filter {
            hasInputChannels($0) && !isBluetooth($0) && isPhysicalInput($0)
        }
        if let builtIn = inputs.first(where: { transportType($0) == kAudioDeviceTransportTypeBuiltIn }) {
            return builtIn
        }
        return inputs.first
    }

    static func name(_ dev: AudioDeviceID) -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &name) == noErr else { return "input" }
        return (name?.takeRetainedValue() as String?) ?? "input"
    }
}

// Keeps a Bluetooth headset on high-quality stereo A2DP playback while Cthugha is
// capturing audio. On macOS 26 every audio-capture mechanism we use (the
// ScreenCaptureKit system-audio stream and Core Audio process taps) activates the
// system default *input* device; when that input is a Bluetooth headset the
// headset is forced onto the mono hands-free (HFP) profile and the user's music
// suddenly sounds thin and bass-less. While a capture is running we steer the
// default input to a non-Bluetooth device (built-in / USB mic) and restore the
// user's original choice when it stops. We never need the microphone to capture
// output audio, so this doesn't affect what Cthugha records.
final class BluetoothPlaybackGuard {
    private var savedInput: AudioDeviceID = 0

    func engage(reason: String) {
        guard savedInput == 0 else { return }
        let current = AudioDevices.defaultInput()
        guard current != 0, AudioDevices.isBluetooth(current) else { return }
        guard let safe = AudioDevices.preferredNonBluetoothInput() else { return }
        if AudioDevices.setDefaultInput(safe) {
            savedInput = current
            NSLog("Cthugha: steered default input to '\(AudioDevices.name(safe))' \(reason)")
        }
    }

    func release() {
        guard savedInput != 0 else { return }
        if AudioDevices.all().contains(savedInput) {
            AudioDevices.setDefaultInput(savedInput)
        }
        savedInput = 0
    }
}

// System audio capture via ScreenCaptureKit (macOS 13+, fully supported on 26).
final class SystemAudioSource: NSObject, AudioSource, SCStreamDelegate, SCStreamOutput {
    let name = "System audio"
    private let store: WaveformStore
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "ink.qualified.cthugha.audio")
    private let videoQueue = DispatchQueue(label: "ink.qualified.cthugha.video")
    // Steers the system default input off Bluetooth for the lifetime of capture so
    // SCK audio capture can't force the headset into low-quality HFP mode.
    private let btGuard = BluetoothPlaybackGuard()

    init(store: WaveformStore) { self.store = store }

    func start() async throws {
        // On macOS 26, enabling ScreenCaptureKit audio capture activates the system
        // default *input* device. If that input is a Bluetooth headset, the headset
        // is dragged off high-quality stereo A2DP playback onto the mono hands-free
        // (HFP) profile — so the user's music suddenly sounds thin and bass-less,
        // even though we only ever wanted the *output* audio.
        btGuard.engage(reason: "to keep Bluetooth playback in full A2DP quality during system-audio capture.")

        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            btGuard.release()
            throw NSError(domain: "Cthugha", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for capture."])
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true
        // A display stream always produces video too; keep it tiny and slow and
        // register a no-op video output so SCK doesn't drop frames with errors.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 4) // ~4 fps
        config.queueDepth = 3

        do {
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
            try await stream.startCapture()
            self.stream = stream
        } catch {
            btGuard.release()
            throw error
        }
    }

    func stop() {
        stream?.stopCapture(completionHandler: { _ in })
        stream = nil
        btGuard.release()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio else { return }
        let samples = monoSamples(from: sampleBuffer)
        if !samples.isEmpty { store.push(samples) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Cthugha: system audio stream stopped: \\(error.localizedDescription)")
    }
}

// Microphone / line-in fallback via AVAudioEngine.
final class MicAudioSource: AudioSource {
    let name = "Microphone"
    private let store: WaveformStore
    private var engine = AVAudioEngine()

    init(store: WaveformStore) { self.store = store }

    func start() async throws {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else {
            throw NSError(domain: "Cthugha", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Microphone access denied."])
        }

        // Rebuild the engine on every start. The input hardware can change while
        // the app runs (e.g. a Bluetooth mic disconnects, or the machine slept),
        // which leaves the cached input node reporting a stale/invalid format;
        // a fresh engine always queries the current default input. This also
        // guarantees no leftover tap is installed on bus 0.
        engine.stop()
        engine = AVAudioEngine()
        let input = engine.inputNode

        // Never capture from a Bluetooth headset's microphone: opening a BT input
        // forces the headset off the high-quality A2DP playback profile and onto
        // the mono "hands-free" (HFP) profile, which makes music sound thin and
        // bass-less. Redirect capture to a non-Bluetooth input (the built-in mic,
        // or a wired/USB mic). If the only microphone is Bluetooth, refuse rather
        // than wreck the user's playback — a mic can't hear headphone audio anyway.
        try Self.selectSafeInputDevice(on: input)

        // When no usable input device is available the format comes back as
        // 0 Hz / 0 channels. Installing a tap with such a format makes AVFAudio
        // raise an Objective-C NSException, which Swift cannot catch — so the
        // whole process would abort (SIGABRT). Validate up front and throw a
        // normal Swift error instead, letting callers fall back gracefully.
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw NSError(domain: "Cthugha", code: 3,
                          userInfo: [NSLocalizedDescriptionKey:
                                        "No usable microphone input is available right now."])
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, let ch = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            let channels = Int(buffer.format.channelCount)
            var out = [Float](repeating: 0, count: frames)
            for f in 0..<frames {
                var acc: Float = 0
                for c in 0..<channels { acc += ch[c][f] }
                out[f] = acc / Float(max(channels, 1))
            }
            self.store.push(out)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    // Point the engine's input at a non-Bluetooth device so that opening the mic
    // never drags a Bluetooth headset off its high-quality A2DP playback profile.
    // If the default input is already non-Bluetooth we leave it untouched. If the
    // only available input is a Bluetooth headset we throw, so callers keep the
    // user's music pristine instead of capturing at the cost of playback quality.
    private static func selectSafeInputDevice(on input: AVAudioInputNode) throws {
        let current = AudioDevices.defaultInput()
        if current != 0, !AudioDevices.isBluetooth(current) { return }

        guard let safe = AudioDevices.preferredNonBluetoothInput(), let unit = input.audioUnit else {
            throw NSError(domain: "Cthugha", code: 4, userInfo: [NSLocalizedDescriptionKey:
                "Microphone capture is unavailable: the only microphone is a Bluetooth "
                + "headset, and opening it would drop your headphones to low-quality call "
                + "audio. Connect a wired or USB microphone, or use system-audio capture."])
        }
        var dev = safe
        AudioUnitSetProperty(unit,
                             kAudioOutputUnitProperty_CurrentDevice,
                             kAudioUnitScope_Global, 0,
                             &dev, UInt32(MemoryLayout<AudioDeviceID>.size))

        // Fail-safe: confirm the input unit actually switched to the non-Bluetooth
        // device. If the override didn't take (still 0 or still Bluetooth), refuse
        // rather than fall through and open the Bluetooth mic — protecting playback
        // is more important than capturing.
        var actual = AudioDeviceID(0)
        var actualSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioUnitGetProperty(unit,
                             kAudioOutputUnitProperty_CurrentDevice,
                             kAudioUnitScope_Global, 0,
                             &actual, &actualSize)
        guard actual == safe || (actual != 0 && !AudioDevices.isBluetooth(actual)) else {
            throw NSError(domain: "Cthugha", code: 5, userInfo: [NSLocalizedDescriptionKey:
                "Microphone capture is unavailable: could not switch off the Bluetooth "
                + "headset mic, and opening it would drop your headphones to low-quality "
                + "call audio. Connect a wired or USB microphone, or use system-audio capture."])
        }
        NSLog("Cthugha: microphone capture routed to '\(AudioDevices.name(safe))' "
              + "to keep Bluetooth playback in full quality.")
    }
}
