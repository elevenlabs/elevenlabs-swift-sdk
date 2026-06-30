/*
 * Original work Copyright 2024 LiveKit, Inc.
 * Modifications Copyright 2025-2026 Eleven Labs Inc.
 *
 * Vendored from https://github.com/elevenlabs/components-swift
 * (Apache 2.0). Audio-track-driven wrapper (`OrbVisualizer`) and
 * `AudioProcessor` intentionally omitted — widget feeds volumes from
 * the SDK's own VAD score / agent state surface.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 */

#if canImport(UIKit)
import Foundation
import MetalKit
import simd
import SwiftUI
import UIKit

// MARK: - VisualizerAgentState

/// State enum for orb visualizer animations.
public enum VisualizerAgentState: Sendable, Equatable {
    case connecting
    case initializing
    case listening
    case speaking
    case disconnected
    case unknown
}

// MARK: - Live audio sample

/// One frame of audio for the orb: the agent and user scalar levels plus each
/// channel's per-band spectrum (low → high). Supply it via ``Orb``'s pull
/// initializer; the Metal render loop samples the provider each frame, so
/// audio-rate updates drive the orb without routing through SwiftUI.
///
/// `agentBands` and `userBands` drive the petals per frequency band (each petal
/// follows the louder of its two bands); `agentLevel` drives the ring pulse and
/// `userLevel` the flow swirl.
public struct OrbAudioSample: Sendable {
    public var agentLevel: Float
    public var userLevel: Float
    public var agentBands: [Float]
    public var userBands: [Float]

    public init(agentLevel: Float, userLevel: Float, agentBands: [Float] = [], userBands: [Float] = []) {
        self.agentLevel = agentLevel
        self.userLevel = userLevel
        self.agentBands = agentBands
        self.userBands = userBands
    }
}

// MARK: - Uniforms

/// CPU-side uniforms must match `OrbUniforms` in `OrbShader.metal` byte-for-byte.
/// Stride = 96 bytes.
struct OrbUniforms {
    var time: Float = 0
    var animation: Float = 0
    var inverted: Float = 0
    var _pad0: Float = 0
    var offsets: simd_float8 = .zero
    var color1: simd_float4 = .zero
    var color2: simd_float4 = .zero
    var agentLevel: Float = 0
    var userLevel: Float = 0
    var _pad1: SIMD2<Float> = .zero

    init() {}
}

/// Convert SwiftUI `Color` -> linear-space simd_float4.
@inline(__always)
private func colorToSIMD4(_ color: Color) -> simd_float4 {
    #if os(macOS)
    let ns = NSColor(color)
    let rgb = ns.usingColorSpace(.deviceRGB) ?? ns
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
    rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
    #else
    let ui = UIColor(color)
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
    ui.getRed(&r, green: &g, blue: &b, alpha: &a)
    #endif
    func sRGBToLinear(_ v: CGFloat) -> Float {
        if v <= 0.04045 { return Float(v / 12.92) }
        return Float(pow((v + 0.055) / 1.055, 2.4))
    }
    return .init(sRGBToLinear(r), sRGBToLinear(g), sRGBToLinear(b), Float(a))
}

// MARK: - Metal renderer

/// Shared Metal renderer backing the SwiftUI representables.
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

    /// Latest per-band levels (low → high) for each channel, resampled to the
    /// shader's petals each draw. Each petal follows the louder of its agent and
    /// mic band. Empty ⇒ that channel contributes nothing.
    private var agentBands: [Float] = []
    private var userBands: [Float] = []
    private let petalCount = 7

    /// Optional live audio source, sampled once per frame from the draw loop.
    /// When set it supersedes the pushed `updateLevels`/`updateBands` values, so
    /// audio-rate data is *pulled* at render cadence and never routed through
    /// SwiftUI. `@MainActor` because it reads the SDK's main-actor level snapshot;
    /// the draw loop runs on the main thread (asserted via `assumeIsolated`).
    private var audioProvider: (@MainActor () -> OrbAudioSample)?

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

    func updateColors(color1: Color, color2: Color) {
        uniforms.color1 = colorToSIMD4(color1)
        uniforms.color2 = colorToSIMD4(color2)
    }

    func updateLevels(agent: Float, user: Float) {
        uniforms.agentLevel = max(0, min(1, agent))
        uniforms.userLevel = max(0, min(1, user))
    }

    func updateBands(agent: [Float], user: [Float]) {
        agentBands = agent
        userBands = user
    }

    func setAudioProvider(_ provider: (@MainActor () -> OrbAudioSample)?) {
        audioProvider = provider
    }

    func updateAgentState(_ state: VisualizerAgentState) {
        uniforms.inverted = 0
        currentAgentState = state
    }

    func mtkView(_: MTKView, drawableSizeWillChange _: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cmd = commandQueue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }

        let now = CACurrentMediaTime()
        let dt = Float(now - lastDrawTime)
        lastDrawTime = now

        // A disconnected orb is idle: freeze both animation clocks so it stops
        // swirling (otherwise it looks "active" / live even after a call ends).
        let isIdle = currentAgentState == .disconnected
        if !isIdle {
            let fps = max(view.preferredFramesPerSecond, 1)
            animationTime += (1.0 / Float(fps)) * 0.1
            displayTime += dt
        }
        uniforms.time = displayTime
        uniforms.animation = animationTime
        uniforms.offsets = simd_float8(randomOffsets + [0])

        // Pull the latest audio frame at render cadence (60fps), bypassing
        // SwiftUI entirely. `draw(in:)` runs on the main thread, so reading the
        // main-actor snapshot via `assumeIsolated` is safe.
        if let audioProvider {
            let sample = MainActor.assumeIsolated { audioProvider() }
            uniforms.agentLevel = max(0, min(1, sample.agentLevel))
            uniforms.userLevel = max(0, min(1, sample.userLevel))
            agentBands = sample.agentBands
            userBands = sample.userBands
        }

        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)

        var u = uniforms
        if isIdle {
            // Don't let any residual level keep the idle orb pulsing.
            u.agentLevel = 0
            u.userLevel = 0
        }
        enc.setFragmentBytes(&u, length: MemoryLayout<OrbUniforms>.stride, index: 0)

        // Per-petal band amplitudes for each channel, resampled to the shader's
        // petals (buffer 1 = agent, buffer 2 = mic). Zeroed while idle.
        var agentPetals = isIdle ? [Float](repeating: 0, count: petalCount) : resampleToPetals(agentBands)
        var userPetals = isIdle ? [Float](repeating: 0, count: petalCount) : resampleToPetals(userBands)
        enc.setFragmentBytes(&agentPetals, length: MemoryLayout<Float>.stride * petalCount, index: 1)
        enc.setFragmentBytes(&userPetals, length: MemoryLayout<Float>.stride * petalCount, index: 2)

        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()

        // An idle orb is fully static (clocks frozen and levels zeroed above), so
        // the frame just presented won't change. Pausing the view stops the 60fps
        // loop from re-compositing identical frames — the common case for the
        // always-on floating button. `updateUIView`/`updateNSView` flip `isPaused`
        // back to false on any state/appearance change, so the loop resumes the
        // moment the orb goes live (or needs a one-off idle redraw on a colour or
        // size change), at which point this frame is the clean idle orb.
        if isIdle {
            view.isPaused = true
        }
    }

    /// Map an arbitrary-length band array (low → high) onto the shader's petals.
    /// Empty input ⇒ all-zero (that channel just doesn't contribute).
    private func resampleToPetals(_ bands: [Float]) -> [Float] {
        guard !bands.isEmpty else { return [Float](repeating: 0, count: petalCount) }
        if bands.count == petalCount { return bands }
        let last = bands.count - 1
        return (0 ..< petalCount).map { i in
            let idx = Int((Float(i) / Float(petalCount - 1)) * Float(last) + 0.5)
            return bands[min(idx, last)]
        }
    }

    private func generateRandomOffsets() {
        randomOffsets = (0 ..< 7).map { _ in Float.random(in: 0 ... (Float.pi * 2)) }
    }

    private func buildBuffers() {
        let verts: [Float] = [
            -1, 1,
            -1, -1,
            1, 1,
            1, -1,
        ]
        vertexBuffer = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<Float>.size, options: [])
    }

    private func buildPipeline() {
        var lib: MTLLibrary?

        // SwiftPM package resources land in Bundle.module.
        #if SWIFT_PACKAGE
        lib = try? device.makeDefaultLibrary(bundle: Bundle.module)
        #endif

        if lib == nil {
            lib = device.makeDefaultLibrary()
        }
        if lib == nil {
            lib = try? device.makeDefaultLibrary(bundle: Bundle(for: type(of: self)))
        }
        if lib == nil {
            lib = try? device.makeDefaultLibrary(bundle: .main)
        }

        guard let library = lib else {
            fatalError("Unable to load Metal library — ensure OrbShader.metal is included as a resource on the ElevenLabsWidget target")
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

// MARK: - Platform-specific view representable

#if os(macOS)
struct _OrbPlatformView: NSViewRepresentable {
    var color1: Color
    var color2: Color
    var agentLevel: Float
    var userLevel: Float
    var agentBands: [Float] = []
    var userBands: [Float] = []
    var audioProvider: (@MainActor () -> OrbAudioSample)? = nil
    var agentState: VisualizerAgentState

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.delegate = context.coordinator
        configure(view: view)
        context.coordinator.updateAll(color1: color1, color2: color2, agent: agentLevel, user: userLevel, agentBands: agentBands, userBands: userBands, audioProvider: audioProvider, state: agentState)
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        // Resume the loop on any update; an idle orb re-pauses itself after one
        // frame inside `draw(in:)`. This is what restarts rendering on an
        // idle → live transition (or a one-off idle redraw on colour/size change).
        view.isPaused = false
        context.coordinator.updateAll(color1: color1, color2: color2, agent: agentLevel, user: userLevel, agentBands: agentBands, userBands: userBands, audioProvider: audioProvider, state: agentState)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

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
        func updateAll(color1: Color, color2: Color, agent: Float, user: Float, agentBands: [Float], userBands: [Float], audioProvider: (@MainActor () -> OrbAudioSample)?, state: VisualizerAgentState) {
            updateColors(color1: color1, color2: color2)
            setAudioProvider(audioProvider)
            if audioProvider == nil {
                updateLevels(agent: agent, user: user)
                updateBands(agent: agentBands, user: userBands)
            }
            updateAgentState(state)
        }
    }
}
#else
struct _OrbPlatformView: UIViewRepresentable {
    var color1: Color
    var color2: Color
    var agentLevel: Float
    var userLevel: Float
    var agentBands: [Float] = []
    var userBands: [Float] = []
    var audioProvider: (@MainActor () -> OrbAudioSample)? = nil
    var agentState: VisualizerAgentState

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.delegate = context.coordinator
        configure(view: view)
        context.coordinator.updateAll(color1: color1, color2: color2, agent: agentLevel, user: userLevel, agentBands: agentBands, userBands: userBands, audioProvider: audioProvider, state: agentState)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        // Resume the loop on any update; an idle orb re-pauses itself after one
        // frame inside `draw(in:)`. This is what restarts rendering on an
        // idle → live transition (or a one-off idle redraw on colour/size change).
        view.isPaused = false
        context.coordinator.updateAll(color1: color1, color2: color2, agent: agentLevel, user: userLevel, agentBands: agentBands, userBands: userBands, audioProvider: audioProvider, state: agentState)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

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
        func updateAll(color1: Color, color2: Color, agent: Float, user: Float, agentBands: [Float], userBands: [Float], audioProvider: (@MainActor () -> OrbAudioSample)?, state: VisualizerAgentState) {
            updateColors(color1: color1, color2: color2)
            setAudioProvider(audioProvider)
            if audioProvider == nil {
                updateLevels(agent: agent, user: user)
                updateBands(agent: agentBands, user: userBands)
            }
            updateAgentState(state)
        }
    }
}
#endif

// MARK: - Public Orb View

/// A SwiftUI view that renders an animated orb visualizer driven by audio + agent state.
///
/// Levels are 0...1 floats. `agentBands` and `userBands` (each channel's per-band
/// spectrum, low → high) drive the petals — each petal follows the louder of its
/// agent and mic band. `agentLevel` drives the ring pulse and `userLevel` the
/// mic swirl. Map the SDK's `isAgentSpeaking` flag to ``VisualizerAgentState``.
///
/// For live audio prefer the pull initializer (`Orb(color1:color2:agentState:audio:)`):
/// it samples an ``OrbAudioSample`` from the render loop each frame, so
/// audio-rate updates never re-render SwiftUI.
public struct Orb: View {
    public var color1: Color
    public var color2: Color
    public var agentLevel: Float
    public var userLevel: Float
    public var agentBands: [Float]
    public var userBands: [Float]
    var audioProvider: (@MainActor () -> OrbAudioSample)?
    public var agentState: VisualizerAgentState

    /// Push: drive the orb from fixed values (recomputed by the caller).
    public init(
        color1: Color,
        color2: Color,
        agentLevel: Float,
        userLevel: Float,
        agentBands: [Float] = [],
        userBands: [Float] = [],
        agentState: VisualizerAgentState = .unknown
    ) {
        self.color1 = color1
        self.color2 = color2
        self.agentLevel = agentLevel
        self.userLevel = userLevel
        self.agentBands = agentBands
        self.userBands = userBands
        self.audioProvider = nil
        self.agentState = agentState
    }

    /// Pull: the render loop samples `audio` every frame. Use this for live
    /// audio so high-frequency levels/bands bypass SwiftUI.
    public init(
        color1: Color,
        color2: Color,
        agentState: VisualizerAgentState = .unknown,
        audio: @escaping @MainActor () -> OrbAudioSample
    ) {
        self.color1 = color1
        self.color2 = color2
        self.agentLevel = 0
        self.userLevel = 0
        self.agentBands = []
        self.userBands = []
        self.audioProvider = audio
        self.agentState = agentState
    }

    public var body: some View {
        GeometryReader { geo in
            let side = max(1, min(geo.size.width, geo.size.height))
            _OrbPlatformView(
                color1: color1,
                color2: color2,
                agentLevel: agentLevel,
                userLevel: userLevel,
                agentBands: agentBands,
                userBands: userBands,
                audioProvider: audioProvider,
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
