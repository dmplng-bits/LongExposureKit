//
//  CamerManager.swift
//  LongExposureKit
//
//  Created by Preet Singh on 4/20/26.
//

#if os(iOS) || os(visionOS)

import AVFoundation

public protocol CameraManagerDelegate: AnyObject {
    /// Frames are passed via `sending` — ownership transfers from the video
    /// queue's isolation region to the delegate. Required for Swift 6
    /// region-based isolation when the delegate hops to a different actor.
    func cameraManager(_ manager: CameraManager,
                       didOutput pixelBuffer: sending CVPixelBuffer,
                       timestamp: CMTime)
    func cameraManager(_ manager: CameraManager,
                       didFinishCaptureAfter frames: Int,
                       duration: TimeInterval)
    func cameraManager(_ manager: CameraManager,
                       didEncounter error: Error)
    /// Called when the AVCaptureSession is interrupted (phone call, app
    /// backgrounded, screen lock, another app took the camera, etc.).
    /// Any in-flight capture should be cancelled.
    func cameraManagerWasInterrupted(_ manager: CameraManager,
                                     reason: AVCaptureSession.InterruptionReason?)
    /// Called when an interruption ends and the session can resume.
    func cameraManagerInterruptionEnded(_ manager: CameraManager)
}

// Default no-op implementations so the new methods don't break existing
// conformers that only care about the original three callbacks.
public extension CameraManagerDelegate {
    func cameraManagerWasInterrupted(_ manager: CameraManager,
                                     reason: AVCaptureSession.InterruptionReason?) {}
    func cameraManagerInterruptionEnded(_ manager: CameraManager) {}
}

public enum CameraError: LocalizedError {
    case deviceUnavailable
    case cannotAddInput
    case cannotAddOutput
    case runtimeError(String)

    public var errorDescription: String? {
        switch self {
        case .deviceUnavailable:
            return "No back-facing camera was found on this device."
        case .cannotAddInput:
            return "The camera input could not be attached to the session."
        case .cannotAddOutput:
            return "The video output could not be attached to the session."
        case .runtimeError(let message):
            return "Camera runtime error: \(message)"
        }
    }
}

/// AVCaptureSession wrapper that streams BGRA frames to a delegate during
/// capture windows defined by `beginCapture(seconds:)`.
public final class CameraManager: NSObject {
    public weak var delegate: CameraManagerDelegate?

    public let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "longexposurekit.session")
    private let videoQueue   = DispatchQueue(label: "longexposurekit.video")

    private var videoDevice: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private var videoOutput: AVCaptureVideoDataOutput?

    // Capture-window state (videoQueue only)
    private var isCapturing = false
    private var captureStartTime: CMTime?
    private var targetDuration: TimeInterval = 0
    private var framesCaptured = 0

    public override init() {
        super.init()
        subscribeToInterruptionNotifications()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Configuration

    public func configure() {
        sessionQueue.async { [weak self] in self?.configureSession() }
    }

    // MARK: Interruption handling

    private func subscribeToInterruptionNotifications() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(handleSessionInterruption(_:)),
            name: AVCaptureSession.wasInterruptedNotification,
            object: session
        )
        center.addObserver(
            self,
            selector: #selector(handleSessionInterruptionEnded(_:)),
            name: AVCaptureSession.interruptionEndedNotification,
            object: session
        )
        center.addObserver(
            self,
            selector: #selector(handleRuntimeError(_:)),
            name: AVCaptureSession.runtimeErrorNotification,
            object: session
        )
    }

    @objc private func handleSessionInterruption(_ note: Notification) {
        // Cancel any in-flight capture so partial results don't get delivered.
        cancelCapture()

        let reason: AVCaptureSession.InterruptionReason? = {
            guard let raw = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int else {
                return nil
            }
            return AVCaptureSession.InterruptionReason(rawValue: raw)
        }()
        delegate?.cameraManagerWasInterrupted(self, reason: reason)
    }

    @objc private func handleSessionInterruptionEnded(_ note: Notification) {
        delegate?.cameraManagerInterruptionEnded(self)
    }

    @objc private func handleRuntimeError(_ note: Notification) {
        cancelCapture()
        let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            ?? CameraError.runtimeError("Unknown")
        LogChannel.camera.error("Runtime error: \(String(describing: error), privacy: .public)")
        delegate?.cameraManager(self, didEncounter: error)
    }

    private func configureSession() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // .hd1920x1080 is the best preset for AVCaptureVideoDataOutput use.
        // .photo (the old value) fights with video-data output pipelines on
        // some devices, producing err=-17281 from FigCaptureSourceRemote.
        // 1920x1080 is also more than enough resolution for long-exposure
        // blending and uses far less memory per frame (~8MB vs ~48MB on
        // 12MP sensors).
        if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        } else {
            session.sessionPreset = .high
        }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                   for: .video,
                                                   position: .back) else {
            delegate?.cameraManager(self, didEncounter: CameraError.deviceUnavailable)
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                delegate?.cameraManager(self, didEncounter: CameraError.cannotAddInput)
                return
            }
            session.addInput(input)
            videoDevice = device
            videoInput = input
        } catch {
            delegate?.cameraManager(self, didEncounter: error)
            return
        }

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.alwaysDiscardsLateVideoFrames = false
        output.setSampleBufferDelegate(self, queue: videoQueue)

        guard session.canAddOutput(output) else {
            delegate?.cameraManager(self, didEncounter: CameraError.cannotAddOutput)
            return
        }
        session.addOutput(output)
        videoOutput = output

        if let connection = output.connection(with: .video) {
            // iOS 17+ replacement for videoOrientation = .portrait.
            // 90° = portrait for the back wide camera.
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .off
            }
        }
    }

    // MARK: Lifecycle

    public func start() {
        sessionQueue.async { [weak self] in
            guard let self = self, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    public func stop() {
        sessionQueue.async { [weak self] in self?.session.stopRunning() }
    }

    // MARK: Manual exposure (optional)

    public func lockExposure(iso: Float? = nil, duration: CMTime? = nil) throws {
        guard let device = videoDevice else { return }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        let clampedISO: Float = {
            guard let iso = iso else {
                return min(max(device.activeFormat.minISO, 400),
                           device.activeFormat.maxISO)
            }
            return min(max(iso, device.activeFormat.minISO),
                      device.activeFormat.maxISO)
        }()
        let d = duration ?? device.activeFormat.maxExposureDuration
        device.setExposureModeCustom(duration: d, iso: clampedISO)
        device.focusMode = .locked
    }

    public func unlockExposure() throws {
        guard let device = videoDevice else { return }
        try device.lockForConfiguration()
        device.exposureMode = .continuousAutoExposure
        device.focusMode = .continuousAutoFocus
        device.unlockForConfiguration()
    }

    /// Focus + expose at a normalized point in the device's coordinate space
    /// (0,0 = top-left, 1,1 = bottom-right of the unrotated landscape sensor).
    /// `AVCaptureVideoPreviewLayer.captureDevicePointConverted(fromLayerPoint:)`
    /// handles the rotation/mirroring math from the preview's coordinates.
    public func focusAndExpose(at devicePoint: CGPoint) throws {
        guard let device = videoDevice else { return }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        if device.isFocusPointOfInterestSupported,
           device.isFocusModeSupported(.autoFocus) {
            device.focusPointOfInterest = devicePoint
            device.focusMode = .autoFocus
        }
        if device.isExposurePointOfInterestSupported,
           device.isExposureModeSupported(.autoExpose) {
            device.exposurePointOfInterest = devicePoint
            device.exposureMode = .autoExpose
        }
        device.isSubjectAreaChangeMonitoringEnabled = true
    }

    // MARK: Capture window

    public func beginCapture(seconds: TimeInterval) {
        videoQueue.async { [weak self] in
            guard let self = self else { return }
            self.targetDuration = seconds
            self.framesCaptured = 0
            self.captureStartTime = nil
            self.isCapturing = true
        }
    }

    public func cancelCapture() {
        videoQueue.async { [weak self] in self?.isCapturing = false }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput,
                              didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        guard isCapturing,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let ts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if captureStartTime == nil { captureStartTime = ts }
        let start = captureStartTime!
        let elapsed = CMTimeGetSeconds(CMTimeSubtract(ts, start))

        delegate?.cameraManager(self, didOutput: pixelBuffer, timestamp: ts)
        framesCaptured += 1

        if elapsed >= targetDuration {
            isCapturing = false
            delegate?.cameraManager(self,
                                    didFinishCaptureAfter: framesCaptured,
                                    duration: elapsed)
        }
    }
}

#endif
