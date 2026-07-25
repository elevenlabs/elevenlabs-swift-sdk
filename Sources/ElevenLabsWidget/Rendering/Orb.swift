// Ported from ElevenLabs components-swift (OrbVisualizer.swift), trimmed to the
// volume-driven orb; the LiveKit track-based visualizer is not carried over.

#if canImport(UIKit)
import Foundation
import MetalKit
import simd
import SwiftUI
import UIKit

/// CPU-side uniforms must match `OrbUniforms` in `OrbShader.metal` byte‑for‑byte.
/// Stride = 96 bytes.
struct OrbUniforms {
    var time: Float = 0
    var animation: Float = 0
    var inverted: Float = 0
    var _pad0: Float = 0 // 16‑byte align
    var offsets: simd_float8 = .zero // only first 7 used
    var color1: simd_float4 = .zero
    var color2: simd_float4 = .zero
    var inputVolume: Float = 0
    var outputVolume: Float = 0
    var _pad1: SIMD2<Float> = .zero // to 96 bytes

    init() {}
}

/// Convert SwiftUI `Color` -> linear‑space simd_float4.
@inline(__always)
@available(iOS 14, macCatalyst 14, *)
private func colorToSIMD4(_ color: Color) -> simd_float4 {
    let ui = UIColor(color)
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
    ui.getRed(&r, green: &g, blue: &b, alpha: &a)
    func sRGBToLinear(_ v: CGFloat) -> Float {
        if v <= 0.04045 { return Float(v / 12.92) }
        return Float(pow((v + 0.055) / 1.055, 2.4))
    }
    return .init(sRGBToLinear(r), sRGBToLinear(g), sRGBToLinear(b), Float(a))
}

/// Shared Metal renderer backing the SwiftUI representables.
@available(iOS 14, macCatalyst 14, *)
class MetalOrbRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var pipeline: MTLRenderPipelineState!
    private var vertexBuffer: MTLBuffer!

    private var animationTime: Float = 0
    /// Wall-clock-driven time fed to the shader. Unlike `CACurrentMediaTime`
    /// it only advances while the orb is active, so a `.disconnected` orb
    /// freezes instead of swirling as if it were live.
    private var displayTime: Float = 0
    private var lastDrawTime: CFTimeInterval = CACurrentMediaTime()

    private var uniforms = OrbUniforms()
    private var randomOffsets: [Float] = []
    private var currentAgentState: VisualizerAgentState = .unknown

    // MARK: - Init

    override init() {
        guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue() else {
            fatalError("Metal not available")
        }
        device = d
        commandQueue = q
        super.init()
        generateRandomOffsets()
        buildBuffers()
        buildPipeline()
    }

    // MARK: - Public updaters

    func updateColors(color1: Color, color2: Color) {
        uniforms.color1 = colorToSIMD4(color1)
        uniforms.color2 = colorToSIMD4(color2)
    }

    func updateVolumes(input: Float, output: Float) {
        uniforms.inputVolume = max(0, min(1, input))
        uniforms.outputVolume = max(0, min(1, output))
    }

    func updateAgentState(_ state: VisualizerAgentState) {
        // No longer inverting colors for thinking state
        uniforms.inverted = 0
        currentAgentState = state
    }

    // MARK: - MTKViewDelegate

    func mtkView(_: MTKView, drawableSizeWillChange _: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cmd = commandQueue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }

        let now = CACurrentMediaTime()
        let fps = max(view.preferredFramesPerSecond, 1)
        // Capped at one frame: an idle orb stops drawing, and the gap must not
        // land on the clock as a jump when the next call resumes it.
        let dt = min(Float(now - lastDrawTime), 1 / Float(fps))
        lastDrawTime = now

        // A disconnected orb is idle: freeze both animation clocks so it stops
        // swirling (otherwise it looks "active" / live even after a call ends).
        let isIdle = currentAgentState == .disconnected
        if !isIdle {
            // Slow down animation when thinking (0.02x speed instead of 0.1x)
            let animationSpeed: Float = currentAgentState == .thinking ? 0.02 : 0.1
            animationTime += (1.0 / Float(fps)) * animationSpeed
            displayTime += dt
        }
        uniforms.time = displayTime
        uniforms.animation = animationTime
        uniforms.offsets = simd_float8(randomOffsets + [0])

        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)

        var u = uniforms
        if isIdle {
            // Don't let any residual level keep the idle orb pulsing.
            u.inputVolume = 0
            u.outputVolume = 0
        }
        enc.setFragmentBytes(&u, length: MemoryLayout<OrbUniforms>.stride, index: 0)

        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    // MARK: - Private

    private func generateRandomOffsets() {
        randomOffsets = (0 ..< 7).map { _ in Float.random(in: 0 ... (Float.pi * 2)) }
    }

    private func buildBuffers() {
        // full‑screen quad
        let verts: [Float] = [
            -1, 1,
            -1, -1,
            1, 1,
            1, -1
        ]
        vertexBuffer = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<Float>.size, options: [])
    }

    private func buildPipeline() {
        // Try to load the Metal library from various sources
        var lib: MTLLibrary?

        // For Swift Package Manager, try Bundle.module first (contains package resources)
        #if SWIFT_PACKAGE
        lib = try? device.makeDefaultLibrary(bundle: Bundle.module)
        #endif

        // Try default library (works when Metal files are in the main target)
        if lib == nil {
            lib = device.makeDefaultLibrary()
        }

        // If that fails, try the class bundle
        if lib == nil {
            lib = try? device.makeDefaultLibrary(bundle: Bundle(for: type(of: self)))
        }

        // If not found, try the main bundle
        if lib == nil {
            lib = try? device.makeDefaultLibrary(bundle: .main)
        }

        guard let library = lib else {
            fatalError("Unable to load Metal library – ensure OrbShader.metal is included in the target")
        }

        guard let vfn = library.makeFunction(name: "orbVertexShader"),
              let ffn = library.makeFunction(name: "orbFragmentShader")
        else {
            fatalError("Unable to find shader functions in Metal library")
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            fatalError("Orb pipeline creation failed: \(error)")
        }
    }
}

@available(iOS 14, macCatalyst 14, *)
struct OrbMetalView: UIViewRepresentable {
    var color1: Color
    var color2: Color
    var inputVolume: Float
    var outputVolume: Float
    var agentState: VisualizerAgentState

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.delegate = context.coordinator
        configure(view: view)
        context.coordinator.updateAll(color1: color1, color2: color2, input: inputVolume, output: outputVolume, state: agentState)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.updateAll(color1: color1, color2: color2, input: inputVolume, output: outputVolume, state: agentState)
        setIdle(isIdle, on: view)
    }

    /// A disconnected, silent orb renders a still frame, so the launcher isn't
    /// driving the GPU at 60fps while it sits in the host's UI.
    private var isIdle: Bool {
        agentState == .disconnected && inputVolume == 0 && outputVolume == 0
    }

    private func setIdle(_ idle: Bool, on view: MTKView) {
        view.isPaused = idle
        // On demand rather than never, so layout changes still get a frame.
        view.enableSetNeedsDisplay = idle
        if idle { view.setNeedsDisplay() }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    private func configure(view: MTKView) {
        view.framebufferOnly = false
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 60
        view.clearColor = .init(red: 0, green: 0, blue: 0, alpha: 0)
        view.colorPixelFormat = .bgra8Unorm
        view.autoResizeDrawable = true
    }

    final class Coordinator: MetalOrbRenderer {
        func updateAll(color1: Color, color2: Color, input: Float, output: Float, state: VisualizerAgentState) {
            updateColors(color1: color1, color2: color2)
            updateVolumes(input: input, output: output)
            updateAgentState(state)
        }
    }
}

@available(iOS 14, macCatalyst 14, *)
struct Orb: View {
    var color1: Color
    var color2: Color
    var inputVolume: Float
    var outputVolume: Float
    var agentState: VisualizerAgentState = .unknown

    var body: some View {
        GeometryReader { geo in
            let side = max(1, min(geo.size.width, geo.size.height))
            OrbMetalView(
                color1: color1,
                color2: color2,
                inputVolume: inputVolume,
                outputVolume: outputVolume,
                agentState: agentState
            )
            .frame(width: side, height: side)
            .clipShape(Circle())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(Text("Orb visualizer"))
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
#endif
