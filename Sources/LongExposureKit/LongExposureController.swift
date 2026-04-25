//
//  LongExposureController.swift
//  LongExposureKit
//
//  Created by Preet Singh on 4/20/26.
//
//  High-level entry point. Hides CameraManager / LongExposureProcessor /
//  FrameStabilizer behind a single async-stream-based API.
//
//  Typical usage from an app:
//
//      let controller = LongExposureController()
//      try await controller.startCamera()
//
//      let settings = CaptureSettings(duration: 5,
//                                     blendMode: .mean,
//                                     stabilization: .translation)
//
//      for await event in controller.capture(settings: settings) {
//          switch event {
//          case .progress(let p):        updateProgressBar(p)
//          case .stabilizing:            showStabilizerBadge()
//          case .finished(let result):   present(result.image)
//          case .failed(let error):      show(error)
//          case .started:                break
//          }
//      }
//

//  Controller is iOS/visionOS-only because it owns the camera pipeline.
//  On other platforms, use LongExposureProcessor + FrameStabilizer directly
//  with frames from any source.

#if os(iOS) || os(visionOS)

import AVFoundation
import UIKit

public struct CaptureSettings: Sendable {
    public var duration: TimeInterval
    public var blendMode: BlendMode
    public var stabilization: StabilizationMode?

    public init(duration: TimeInterval,
                blendMode: BlendMode = .mean,
                stabilization: StabilizationMode? = nil) {
        self.duration = duration
        self.blendMode = blendMode
        self.stabilization = stabilization
    }
}

public struct CaptureResult: @unchecked Sendable {
    public let image: UIImage
    public let frameCount: Int
    public let duration: TimeInterval
}

public enum CaptureEvent: @unchecked Sendable {
    case started
    case progress(Double)              // 0...1
    case stabilizing                   // emitted once when alignment begins
    case interrupted                   // session interrupted mid-capture
    /// Periodic snapshot of the evolving long-exposure during capture.
    /// Emitted at most every ~10 frames so the UI can show a developing
    /// preview without thrashing.
    case preview(UIImage)
    case finished(CaptureResult)
    case failed(Error)
}

public enum ControllerError: LocalizedError {
    case cameraAccessDenied
    case captureInProgress
    case noFramesProduced

    public var errorDescription: String? {
        switch self {
        case .cameraAccessDenied:
            return "Camera access is required. Enable it in Settings."
        case .captureInProgress:
            return "A capture is already in progress."
        case .noFramesProduced:
            return "Capture finished without producing any frames."
        }
    }
}

@MainActor
public final class LongExposureController {
    public let camera: CameraManager
    public var processor: LongExposureProcessor?
    public var stabilizer: FrameStabilizer?

    public var session: AVCaptureSession { camera.session }

    private var delegateBridge: DelegateBridge?
    private var activeContinuation: AsyncStream<CaptureEvent>.Continuation?
    private var referenceBuffer: CVPixelBuffer?
    private var captureStartedAt: Date?
    private var currentDuration: TimeInterval = 0
    private var stabilizingEmitted: Bool = false

    public init() {
        self.camera = CameraManager()
        let bridge = DelegateBridge()
        bridge.owner = self
        self.delegateBridge = bridge
        self.camera.delegate = bridge
        self.camera.configure()
    }

    // MARK: Camera lifecycle

    /// Requests camera permission (if needed) and starts the session.
    public func startCamera() async throws {
        let granted = await requestCameraAccess()
        guard granted else { throw ControllerError.cameraAccessDenied }
        camera.start()
    }

    public func stopCamera() { camera.stop() }

    private func requestCameraAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    // MARK: Capture

    /// Start a long-exposure capture. Returns an `AsyncStream` that emits
    /// progress events and finishes (or fails) at the end.
    ///
    /// Only one capture may be in flight at a time.
    public func capture(settings: CaptureSettings) -> AsyncStream<CaptureEvent> {
        // Using makeStream() instead of the closure-based AsyncStream init so
        // we don't cross the @Sendable boundary when mutating @MainActor state.
        let (stream, continuation) = AsyncStream<CaptureEvent>.makeStream()

        guard activeContinuation == nil else {
            continuation.yield(.failed(ControllerError.captureInProgress))
            continuation.finish()
            return stream
        }

        self.processor           = LongExposureProcessor(mode: settings.blendMode)
        self.stabilizer          = settings.stabilization.map(FrameStabilizer.init)
        self.referenceBuffer     = nil
        self.captureStartedAt    = Date()
        self.currentDuration     = settings.duration
        self.stabilizingEmitted  = false
        self.activeContinuation  = continuation

        continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.camera.cancelCapture()
                self?.resetCaptureState()
            }
        }

        continuation.yield(.started)
        camera.beginCapture(seconds: settings.duration)

        return stream
    }

    /// Cancel an in-progress capture. The stream will finish without a
    /// `.finished` event.
    public func cancelCapture() {
        camera.cancelCapture()
        activeContinuation?.finish()
        resetCaptureState()
    }

    private func resetCaptureState() {
        processor = nil
        stabilizer = nil
        referenceBuffer = nil
        captureStartedAt = nil
        activeContinuation = nil
        stabilizingEmitted = false
    }

    // MARK: Delegate callbacks (invoked on main actor via the bridge)

    fileprivate func handleFrame(_ pixelBuffer: sending CVPixelBuffer) {
        guard let processor = processor,
              let continuation = activeContinuation else { return }

        var transform: CGAffineTransform = .identity
        if let stabilizer = stabilizer {
            if let ref = referenceBuffer {
                transform = stabilizer.transform(from: pixelBuffer, to: ref)
                if !stabilizingEmitted {
                    stabilizingEmitted = true
                    continuation.yield(.stabilizing)
                }
            } else {
                referenceBuffer = pixelBuffer
            }
        }
        processor.add(pixelBuffer: pixelBuffer, transform: transform)

        // Periodically emit the developing image as a preview so the UI can
        // overlay it on the camera feed. Throttled to every 10th frame to
        // avoid spending all our time rendering during capture.
        if processor.frameCount % 10 == 0,
           let preview = processor.renderUIImage() {
            continuation.yield(.preview(preview))
        }

        if let start = captureStartedAt {
            let p = min(1.0, Date().timeIntervalSince(start) / currentDuration)
            continuation.yield(.progress(p))
        }
    }

    fileprivate func handleFinish(frames: Int, duration: TimeInterval) {
        guard let continuation = activeContinuation else { return }
        defer { resetCaptureState() }

        if let image = processor?.renderUIImage() {
            let result = CaptureResult(image: image,
                                       frameCount: frames,
                                       duration: duration)
            continuation.yield(.finished(result))
        } else {
            continuation.yield(.failed(ControllerError.noFramesProduced))
        }
        continuation.finish()
    }

    fileprivate func handleError(_ error: Error) {
        activeContinuation?.yield(.failed(error))
        activeContinuation?.finish()
        resetCaptureState()
    }

    fileprivate func handleInterruption() {
        activeContinuation?.yield(.interrupted)
        activeContinuation?.finish()
        resetCaptureState()
    }
}

// MARK: - Delegate bridge

// CameraManager's delegate is called off the main thread. This bridge hops to
// main and calls back into the controller.
private final class DelegateBridge: NSObject, CameraManagerDelegate {
    weak var owner: LongExposureController?

    func cameraManager(_ manager: CameraManager,
                       didOutput pixelBuffer: sending CVPixelBuffer,
                       timestamp: CMTime) {
        // `sending` transfers the buffer into the Task's isolation region,
        // so the @MainActor hop is safe under Swift 6 strict concurrency.
        Task { @MainActor [weak owner] in
            owner?.handleFrame(pixelBuffer)
        }
    }

    func cameraManager(_ manager: CameraManager,
                       didFinishCaptureAfter frames: Int,
                       duration: TimeInterval) {
        Task { @MainActor [weak owner] in
            owner?.handleFinish(frames: frames, duration: duration)
        }
    }

    func cameraManager(_ manager: CameraManager,
                       didEncounter error: Error) {
        Task { @MainActor [weak owner] in
            owner?.handleError(error)
        }
    }

    func cameraManagerWasInterrupted(_ manager: CameraManager,
                                     reason: AVCaptureSession.InterruptionReason?) {
        Task { @MainActor [weak owner] in
            owner?.handleInterruption()
        }
    }
}

#endif
