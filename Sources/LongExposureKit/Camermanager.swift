//
//  Camermanager.swift
//  LongExposureKit
//
//  Created by Preet Singh on 4/20/26.
//

#if os(iOS) || os(visionOS)

import AVFoundation

public protocol CameraManagerDelegate: AnyObject {
    func cameraManager(_ manager: CameraManager,
                       didOutput pixelBuffer: CVPixelBuffer,
                       timestamp: CMTime)
    func cameraManager(_ manager: CameraManager,
                       didFinishCaptureAfter frames: Int,
                       duration: TimeInterval)
    func cameraManager(_ manager: CameraManager,
                       didEncounter error: Error)
}

public enum CameraError: Error {
    case deviceUnavailable
    case cannotAddInput
    case cannotAddOutput
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

    public override init() { super.init() }

    // MARK: Configuration

    public func configure() {
        sessionQueue.async { [weak self] in self?.configureSession() }
    }

    private func configureSession() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .photo

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
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
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
