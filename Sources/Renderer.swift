import Foundation
import Metal
import MetalKit
import simd

final class Renderer: NSObject, MTKViewDelegate {
    // Fixed uniform layout (18 floats) matching the Metal `Uniforms` struct.
    private enum U {
        static let resX = 0, resY = 1, time = 2, dt = 3, mode = 4, decay = 5
        static let zoom = 6, swirl = 7, waveAmp = 8, intensityScale = 9
        static let paletteIndex = 10, paletteCount = 11, paletteRotation = 12
        static let waveBrightness = 13, waveCount = 14, mirror = 15, pad = 16
    }

    static let waveCount = 512
    static let uniformCount = 18
    static let paletteNames = ["Fire", "Ice", "Acid", "Plasma", "Mono", "Rainbow",
                               "Solar Flare", "Oil Shimmer", "Metallic", "Blue Fire"]
    private let simMaxDim = 1024

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let store: WaveformStore

    private var warpPSO: MTLComputePipelineState!
    private var wavePSO: MTLRenderPipelineState!
    private var presentPSO: MTLRenderPipelineState!

    private var bufferA: MTLTexture?
    private var bufferB: MTLTexture?
    private var paletteTexture: MTLTexture!
    private let paletteCount: Int

    private let uniformsBuffer: MTLBuffer
    private let samplesBuffer: MTLBuffer
    private var uniforms = [Float](repeating: 0, count: Renderer.uniformCount)

    private var colorPixelFormat: MTLPixelFormat = .bgra8Unorm
    private var lastTime = CFAbsoluteTimeGetCurrent()
    private var startTime = CFAbsoluteTimeGetCurrent()

    // Adjustable state.
    private var mode = 0
    private var paletteIndex = 0
    private var decay: Float = 0.955
    private var zoom: Float = 1.0
    private var swirl: Float = 1.0
    private var waveAmp: Float = 0.85
    private var intensityScale: Float = 1.0
    private var waveBrightness: Float = 0.85
    private var colorCycle = true
    private var paletteRotation: Float = 0
    private var mirror: Float = 0

    // Named look presets ("styles"). Index 0 is the user's current/custom look;
    // 1… are the fixed variations. Leaving custom snapshots the live params so
    // returning to "Current" restores them.
    private var styleIndex = 0
    private var savedCustom: StyleParams?

    private let debug = ProcessInfo.processInfo.environment["CTHUGHA_DEBUG"] != nil
    private var frameCounter = 0

    init?(device: MTLDevice, store: WaveformStore) {
        guard let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        self.store = store

        guard let ub = device.makeBuffer(length: Renderer.uniformCount * MemoryLayout<Float>.size,
                                          options: .storageModeShared),
              let sb = device.makeBuffer(length: Renderer.waveCount * MemoryLayout<Float>.size,
                                          options: .storageModeShared)
        else { return nil }
        self.uniformsBuffer = ub
        self.samplesBuffer = sb

        let palettes = Renderer.buildPalettes()
        self.paletteCount = palettes.count
        super.init()

        do {
            try buildPipelines()
        } catch {
            NSLog("Cthugha: pipeline build failed: \(error)")
            return nil
        }
        buildPaletteTexture(palettes)
    }

    func setColorPixelFormat(_ fmt: MTLPixelFormat) {
        colorPixelFormat = fmt
        try? buildPresentPipeline()
    }

    // MARK: - Pipelines

    private var library: MTLLibrary!

    private func buildPipelines() throws {
        // Prefer a precompiled default.metallib bundled in Resources; fall back
        // to compiling the embedded shader source at runtime.
        if let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
           let lib = try? device.makeLibrary(URL: url) {
            library = lib
            NSLog("Cthugha: loaded precompiled default.metallib")
        } else {
            library = try device.makeLibrary(source: metalShaderSource, options: nil)
            NSLog("Cthugha: compiled shaders from source at runtime")
        }

        guard let warpFn = library.makeFunction(name: "warp") else {
            throw NSError(domain: "Cthugha", code: 10)
        }
        warpPSO = try device.makeComputePipelineState(function: warpFn)

        let waveDesc = MTLRenderPipelineDescriptor()
        waveDesc.vertexFunction = library.makeFunction(name: "waveVertex")
        waveDesc.fragmentFunction = library.makeFunction(name: "waveFragment")
        let wc = waveDesc.colorAttachments[0]!
        wc.pixelFormat = .r16Float
        wc.isBlendingEnabled = true
        wc.rgbBlendOperation = .add
        wc.alphaBlendOperation = .add
        wc.sourceRGBBlendFactor = .one
        wc.destinationRGBBlendFactor = .one
        wc.sourceAlphaBlendFactor = .one
        wc.destinationAlphaBlendFactor = .one
        wavePSO = try device.makeRenderPipelineState(descriptor: waveDesc)

        try buildPresentPipeline()
    }

    private func buildPresentPipeline() throws {
        guard library != nil else { return }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "presentVertex")
        desc.fragmentFunction = library.makeFunction(name: "presentFragment")
        desc.colorAttachments[0].pixelFormat = colorPixelFormat
        presentPSO = try device.makeRenderPipelineState(descriptor: desc)
    }

    // MARK: - Styles (named look presets)

    struct StyleParams {
        var paletteIndex: Int
        var mode: Int
        var decay: Float
        var zoom: Float
        var swirl: Float
        var waveAmp: Float
        var intensityScale: Float
        var waveBrightness: Float
        var colorCycle: Bool
        var mirror: Float
    }

    // The fixed variations offered by the Style toggle (in addition to "Current").
    // Palette indices 6…9 are the Solar Flare / Oil Shimmer / Metallic / Blue Fire
    // gradients appended in buildPalettes().
    static let variations: [(name: String, params: StyleParams)] = [
        ("Solar Flare", StyleParams(paletteIndex: 6, mode: 0, decay: 0.930, zoom: 1.5,
                                    swirl: 1.2, waveAmp: 1.0, intensityScale: 1.35,
                                    waveBrightness: 1.0, colorCycle: false, mirror: 0)),
        ("Oil Shimmer", StyleParams(paletteIndex: 7, mode: 1, decay: 0.972, zoom: 1.0,
                                    swirl: 1.7, waveAmp: 0.7, intensityScale: 1.0,
                                    waveBrightness: 0.7, colorCycle: true, mirror: 2)),
        ("Metallic Lightning", StyleParams(paletteIndex: 8, mode: 0, decay: 0.900, zoom: 1.1,
                                           swirl: 0.6, waveAmp: 1.15, intensityScale: 1.7,
                                           waveBrightness: 1.2, colorCycle: false, mirror: 1)),
        ("Blue Fire", StyleParams(paletteIndex: 9, mode: 0, decay: 0.930, zoom: 1.5,
                                  swirl: 1.2, waveAmp: 1.0, intensityScale: 1.35,
                                  waveBrightness: 1.0, colorCycle: false, mirror: 0)),
    ]

    static var styleCount: Int { variations.count + 1 } // +1 for "Current"

    static func styleName(_ index: Int) -> String {
        index == 0 ? "Current" : variations[index - 1].name
    }

    private func currentParams() -> StyleParams {
        StyleParams(paletteIndex: paletteIndex, mode: mode, decay: decay, zoom: zoom,
                    swirl: swirl, waveAmp: waveAmp, intensityScale: intensityScale,
                    waveBrightness: waveBrightness, colorCycle: colorCycle, mirror: mirror)
    }

    private func applyParams(_ p: StyleParams) {
        paletteIndex = p.paletteIndex
        mode = p.mode
        decay = p.decay
        zoom = p.zoom
        swirl = p.swirl
        waveAmp = p.waveAmp
        intensityScale = p.intensityScale
        waveBrightness = p.waveBrightness
        colorCycle = p.colorCycle
        mirror = p.mirror
    }

    var currentStyleName: String { Renderer.styleName(styleIndex) }
    var currentStyleIndex: Int { styleIndex }

    func setStyle(_ index: Int) {
        let n = Renderer.styleCount
        let target = ((index % n) + n) % n
        if target == styleIndex { return }
        if styleIndex == 0 { savedCustom = currentParams() } // snapshot the custom look
        styleIndex = target
        if target == 0 {
            if let s = savedCustom { applyParams(s) }
        } else {
            applyParams(Renderer.variations[target - 1].params)
        }
    }

    func nextStyle() { setStyle(styleIndex + 1) }
    func prevStyle() { setStyle(styleIndex - 1) }

    // A manual parameter tweak means the user has left any preset: it becomes the
    // new "Current" look.
    private func markCustom() { styleIndex = 0 }

    // MARK: - Palettes

    private struct Stop { let pos: Float; let r: Float; let g: Float; let b: Float }

    private static func gradient(_ stops: [Stop]) -> [SIMD4<Float>] {
        var out = [SIMD4<Float>](repeating: .zero, count: 256)
        for i in 0..<256 {
            let t = Float(i) / 255.0
            var a = stops[0], b = stops[stops.count - 1]
            for j in 0..<(stops.count - 1) where t >= stops[j].pos && t <= stops[j + 1].pos {
                a = stops[j]; b = stops[j + 1]; break
            }
            let span = max(b.pos - a.pos, 1e-5)
            let k = min(max((t - a.pos) / span, 0), 1)
            out[i] = SIMD4<Float>(a.r + (b.r - a.r) * k,
                                  a.g + (b.g - a.g) * k,
                                  a.b + (b.b - a.b) * k, 1)
        }
        return out
    }

    private static func buildPalettes() -> [[SIMD4<Float>]] {
        return [
            gradient([Stop(pos: 0.0, r: 0, g: 0, b: 0), Stop(pos: 0.25, r: 0.5, g: 0, b: 0),
                      Stop(pos: 0.55, r: 1, g: 0.25, b: 0), Stop(pos: 0.8, r: 1, g: 0.85, b: 0.1),
                      Stop(pos: 1.0, r: 1, g: 1, b: 0.9)]),                                   // Fire
            gradient([Stop(pos: 0.0, r: 0, g: 0, b: 0.05), Stop(pos: 0.35, r: 0, g: 0.1, b: 0.6),
                      Stop(pos: 0.7, r: 0.1, g: 0.7, b: 1), Stop(pos: 1.0, r: 0.9, g: 1, b: 1)]), // Ice
            gradient([Stop(pos: 0.0, r: 0, g: 0, b: 0), Stop(pos: 0.4, r: 0, g: 0.6, b: 0.1),
                      Stop(pos: 0.7, r: 0.6, g: 1, b: 0.1), Stop(pos: 1.0, r: 1, g: 1, b: 0.7)]),  // Acid
            gradient([Stop(pos: 0.0, r: 0.02, g: 0, b: 0.08), Stop(pos: 0.35, r: 0.4, g: 0, b: 0.6),
                      Stop(pos: 0.65, r: 1, g: 0.1, b: 0.7), Stop(pos: 0.85, r: 1, g: 0.6, b: 0.9),
                      Stop(pos: 1.0, r: 1, g: 1, b: 1)]),                                     // Plasma
            gradient([Stop(pos: 0.0, r: 0, g: 0, b: 0), Stop(pos: 0.5, r: 0.35, g: 0.4, b: 0.5),
                      Stop(pos: 1.0, r: 1, g: 1, b: 1)]),                                     // Mono
            gradient([Stop(pos: 0.0, r: 0, g: 0, b: 0), Stop(pos: 0.2, r: 0.6, g: 0.15, b: 0),
                      Stop(pos: 0.45, r: 1, g: 0.55, b: 0), Stop(pos: 0.6, r: 0.2, g: 0.9, b: 0.3),
                      Stop(pos: 0.8, r: 0.1, g: 0.5, b: 1), Stop(pos: 1.0, r: 1, g: 0.4, b: 1)]), // Rainbow
            // Solar Flare — hotter, punchier fire (Wikipedia image 3).
            gradient([Stop(pos: 0.0, r: 0, g: 0, b: 0), Stop(pos: 0.15, r: 0.35, g: 0, b: 0),
                      Stop(pos: 0.4, r: 0.95, g: 0.15, b: 0), Stop(pos: 0.62, r: 1, g: 0.5, b: 0),
                      Stop(pos: 0.82, r: 1, g: 0.85, b: 0.2), Stop(pos: 1.0, r: 1, g: 1, b: 0.9)]),
            // Oil Shimmer — iridescent, oily sheen (Wikipedia image 2).
            gradient([Stop(pos: 0.0, r: 0.02, g: 0, b: 0.08), Stop(pos: 0.2, r: 0.5, g: 0, b: 0.6),
                      Stop(pos: 0.4, r: 0, g: 0.7, b: 0.7), Stop(pos: 0.55, r: 0.95, g: 0.2, b: 0.6),
                      Stop(pos: 0.7, r: 0.95, g: 0.75, b: 0.1), Stop(pos: 0.85, r: 0.2, g: 0.8, b: 0.95),
                      Stop(pos: 1.0, r: 0.95, g: 0.97, b: 1)]),
            // Metallic — electric steel-blue / silver (Wikipedia image 1).
            gradient([Stop(pos: 0.0, r: 0, g: 0, b: 0), Stop(pos: 0.3, r: 0.14, g: 0.2, b: 0.34),
                      Stop(pos: 0.55, r: 0.42, g: 0.56, b: 0.72), Stop(pos: 0.72, r: 0.6, g: 0.85, b: 1),
                      Stop(pos: 0.88, r: 0.88, g: 0.96, b: 1), Stop(pos: 1.0, r: 1, g: 1, b: 1)]),
            // Blue Fire — cool blue flames.
            gradient([Stop(pos: 0.0, r: 0, g: 0, b: 0.03), Stop(pos: 0.25, r: 0, g: 0.06, b: 0.42),
                      Stop(pos: 0.5, r: 0, g: 0.35, b: 0.9), Stop(pos: 0.7, r: 0.2, g: 0.72, b: 1),
                      Stop(pos: 0.88, r: 0.72, g: 0.95, b: 1), Stop(pos: 1.0, r: 1, g: 1, b: 1)])
        ]
    }

    private func buildPaletteTexture(_ palettes: [[SIMD4<Float>]]) {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 256, height: palettes.count, mipmapped: false)
        desc.usage = [.shaderRead]
        paletteTexture = device.makeTexture(descriptor: desc)

        var bytes = [UInt8](repeating: 0, count: 256 * palettes.count * 4)
        for (row, pal) in palettes.enumerated() {
            for x in 0..<256 {
                let c = pal[x]
                let o = (row * 256 + x) * 4
                bytes[o + 0] = UInt8(max(0, min(1, c.x)) * 255)
                bytes[o + 1] = UInt8(max(0, min(1, c.y)) * 255)
                bytes[o + 2] = UInt8(max(0, min(1, c.z)) * 255)
                bytes[o + 3] = 255
            }
        }
        paletteTexture.replace(region: MTLRegionMake2D(0, 0, 256, palettes.count),
                               mipmapLevel: 0, withBytes: bytes, bytesPerRow: 256 * 4)
    }

    // MARK: - Feedback buffers

    private func makeSimTexture(width: Int, height: Int) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Float, width: max(width, 1), height: max(height, 1), mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        desc.storageMode = .private
        return device.makeTexture(descriptor: desc)
    }

    private func clear(_ texture: MTLTexture) {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = texture
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        rpd.colorAttachments[0].storeAction = .store
        guard let cb = queue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.endEncoding()
        cb.commit()
    }

    private func rebuildBuffers(for drawableSize: CGSize) {
        let w = Double(drawableSize.width), h = Double(drawableSize.height)
        guard w > 0, h > 0 else { return }
        let scale = min(1.0, Double(simMaxDim) / max(w, h))
        let sw = max(16, Int((w * scale).rounded()))
        let sh = max(16, Int((h * scale).rounded()))
        bufferA = makeSimTexture(width: sw, height: sh)
        bufferB = makeSimTexture(width: sw, height: sh)
        if let a = bufferA { clear(a) }
        if let b = bufferB { clear(b) }
        uniforms[U.resX] = Float(sw)
        uniforms[U.resY] = Float(sh)
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        rebuildBuffers(for: size)
    }

    func draw(in view: MTKView) {
        if bufferA == nil || bufferB == nil { rebuildBuffers(for: view.drawableSize) }
        guard let cur = bufferA, let next = bufferB,
              let drawable = view.currentDrawable,
              let rpDesc = view.currentRenderPassDescriptor else { return }

        let now = CFAbsoluteTimeGetCurrent()
        let dt = Float(min(now - lastTime, 0.1))
        lastTime = now

        if colorCycle {
            paletteRotation += dt * 0.06
            paletteRotation -= floor(paletteRotation)
        }

        // Upload latest waveform. When there is effectively no audio signal,
        // synthesize a gentle idle waveform so the visuals are never static.
        var samples = store.latest(Renderer.waveCount)
        var peak: Float = 0
        for s in samples { peak = max(peak, abs(s)) }
        if peak < 0.004 {
            let t = Float(now - startTime)
            for i in 0..<Renderer.waveCount {
                let x = Float(i) / Float(Renderer.waveCount)
                samples[i] = 0.14 * sin(x * 22 + t * 2.0) * sin(t * 0.7 + x * 6.0)
                           + 0.06 * sin(x * 55 - t * 3.3)
            }
        }
        samples.withUnsafeBytes { raw in
            samplesBuffer.contents().copyMemory(from: raw.baseAddress!, byteCount: raw.count)
        }

        // Fill uniforms.
        uniforms[U.time] = Float(now - startTime)
        uniforms[U.dt] = dt
        uniforms[U.mode] = Float(mode)
        uniforms[U.decay] = decay
        uniforms[U.zoom] = zoom
        uniforms[U.swirl] = swirl
        uniforms[U.waveAmp] = waveAmp
        uniforms[U.intensityScale] = intensityScale
        uniforms[U.paletteIndex] = Float(paletteIndex)
        uniforms[U.paletteCount] = Float(paletteCount)
        uniforms[U.paletteRotation] = paletteRotation
        uniforms[U.waveBrightness] = waveBrightness
        uniforms[U.waveCount] = Float(Renderer.waveCount)
        uniforms[U.mirror] = mirror
        uniforms.withUnsafeBytes { raw in
            uniformsBuffer.contents().copyMemory(from: raw.baseAddress!, byteCount: raw.count)
        }

        guard let cb = queue.makeCommandBuffer() else { return }

        // 1) Warp + decay: cur -> next.
        if let ce = cb.makeComputeCommandEncoder() {
            ce.setComputePipelineState(warpPSO)
            ce.setTexture(cur, index: 0)
            ce.setTexture(next, index: 1)
            ce.setBuffer(uniformsBuffer, offset: 0, index: 0)
            let tg = MTLSize(width: 16, height: 16, depth: 1)
            let groups = MTLSize(width: (next.width + 15) / 16,
                                 height: (next.height + 15) / 16, depth: 1)
            ce.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
            ce.endEncoding()
        }

        // 2) Draw oscilloscope additively into next.
        let waveRP = MTLRenderPassDescriptor()
        waveRP.colorAttachments[0].texture = next
        waveRP.colorAttachments[0].loadAction = .load
        waveRP.colorAttachments[0].storeAction = .store
        if let re = cb.makeRenderCommandEncoder(descriptor: waveRP) {
            re.setRenderPipelineState(wavePSO)
            re.setVertexBuffer(samplesBuffer, offset: 0, index: 0)
            re.setVertexBuffer(uniformsBuffer, offset: 0, index: 1)
            re.drawPrimitives(type: .lineStrip, vertexStart: 0, vertexCount: Renderer.waveCount)
            re.endEncoding()
        }

        // 3) Present: colourise next into the drawable.
        if let pe = cb.makeRenderCommandEncoder(descriptor: rpDesc) {
            pe.setRenderPipelineState(presentPSO)
            pe.setFragmentTexture(next, index: 0)
            pe.setFragmentTexture(paletteTexture, index: 1)
            pe.setFragmentBuffer(uniformsBuffer, offset: 0, index: 0)
            pe.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            pe.endEncoding()
        }

        cb.present(drawable)
        if debug {
            cb.addCompletedHandler { b in
                if let e = b.error { NSLog("Cthugha[dbg]: GPU error: \(e)") }
            }
        }
        cb.commit()

        if debug {
            frameCounter += 1
            if frameCounter % 120 == 0 {
                var mx: Float = 0
                for s in samples { mx = max(mx, abs(s)) }
                NSLog("Cthugha[dbg]: frame=\(frameCounter) audioPeak=\(String(format: "%.4f", mx)) " +
                      "sim=\(cur.width)x\(cur.height) drawable=\(Int(view.drawableSize.width))x\(Int(view.drawableSize.height)) " +
                      "present=\(presentPSO != nil) rot=\(String(format: "%.2f", paletteRotation))")
            }
        }

        // Ping-pong.
        bufferA = next
        bufferB = cur
    }

    // MARK: - Controls

    var status: String {
        let modes = ["Flame", "Swirl", "Ripple", "Tunnel"]
        return "Style: \(currentStyleName)  Mode: \(modes[mode])  " +
               "Palette: \(paletteName)  " +
               "Cycle: \(colorCycle ? "on" : "off")  Amp: \(String(format: "%.2f", waveAmp))  " +
               "Decay: \(String(format: "%.3f", decay))"
    }

    func nextMode() { mode = (mode + 1) % 4; markCustom() }
    func nextPalette() { paletteIndex = (paletteIndex + 1) % paletteCount; markCustom() }
    func prevPalette() { paletteIndex = (paletteIndex - 1 + paletteCount) % paletteCount; markCustom() }
    var paletteName: String {
        Renderer.paletteNames[min(paletteIndex, Renderer.paletteNames.count - 1)]
    }
    func toggleColorCycle() { colorCycle.toggle(); markCustom() }
    func changeWaveAmp(_ d: Float) { waveAmp = max(0.1, min(3.0, waveAmp + d)); markCustom() }
    func changeDecay(_ d: Float) { decay = max(0.80, min(0.995, decay + d)); markCustom() }
    func changeIntensity(_ d: Float) { intensityScale = max(0.2, min(4.0, intensityScale + d)); markCustom() }
    func changeSwirl(_ d: Float) { swirl = max(-3.0, min(3.0, swirl + d)); markCustom() }
}
