import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia

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

// System audio capture via ScreenCaptureKit (macOS 13+, fully supported on 26).
final class SystemAudioSource: NSObject, AudioSource, SCStreamDelegate, SCStreamOutput {
    let name = "System audio"
    private let store: WaveformStore
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "ink.qualified.cthugha.audio")
    private let videoQueue = DispatchQueue(label: "ink.qualified.cthugha.video")

    init(store: WaveformStore) { self.store = store }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
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

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() {
        stream?.stopCapture(completionHandler: { _ in })
        stream = nil
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
    private let engine = AVAudioEngine()

    init(store: WaveformStore) { self.store = store }

    func start() async throws {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else {
            throw NSError(domain: "Cthugha", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Microphone access denied."])
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
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
}
