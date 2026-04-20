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

/  Controller is iOS/visionOS-only because it owns the camera pipeline.
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
    case finished(CaptureResult)
    case failed(Error)
}

public enum ControllerError: Error {
    case cameraAccessDenied
    case captureInProgress
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
        AsyncStream { continuation in
            guard activeContinuation == nil else {
                continuation.yield(.failed(ControllerError.captureInProgress))
                continuation.finish()
                return
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
        }
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

    fileprivate func handleFrame(_ pixelBuffer: CVPixelBuffer) {
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
            continuation.yield(.failed(NSError(
                domain: "LongExposureKit",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No frames produced"]
            )))
        }
        continuation.finish()
    }

    fileprivate func handleError(_ error: Error) {
        activeContinuation?.yield(.failed(error))
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
                       didOutput pixelBuffer: CVPixelBuffer,
                       timestamp: CMTime) {
        // Retain the buffer across the hop — copying would be safer if you
        // see pool stalls, but for a handful of frames per second this is fine.
        let buffer = pixelBuffer
        Task { @MainActor [weak owner] in
            owner?.handleFrame(buffer)
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
}

#endif
