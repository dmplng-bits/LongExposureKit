//
//  FrameStabilizer.swift
//  LongExposureKit
//
//  Created by Preet Singh on 4/20/26.
//

import Vision
import CoreGraphics
import CoreVideo

public enum StabilizationMode: String, CaseIterable, Sendable {
    /// Fast translation-only registration. Good for 1-5s handheld captures.
    case translation
    /// Full homographic warp. Handles rotation and perspective drift.
    /// Slower per frame; better for longer captures.
    case homographic

    public var displayName: String {
        switch self {
        case .translation: return "Translation"
        case .homographic: return "Homographic"
        }
    }
}

/// Aligns an incoming frame to a reference frame using the Vision framework.
///
/// Stateless per-frame — the caller owns the reference buffer. Typical usage:
/// first frame becomes the reference, all subsequent frames are aligned to it.
public final class FrameStabilizer {
    public let mode: StabilizationMode
    private let handler = VNSequenceRequestHandler()

    public init(mode: StabilizationMode = .translation) {
        self.mode = mode
    }

    /// Compute a transform that maps `current` onto `reference`.
    /// Returns `.identity` if Vision fails — callers should keep going rather
    /// than drop the frame.
    public func transform(from current: CVPixelBuffer,
                          to reference: CVPixelBuffer) -> CGAffineTransform {
        switch mode {
        case .translation: return translation(from: current, to: reference)
        case .homographic: return homographic(from: current, to: reference)
        }
    }

    // MARK: - Translation

    private func translation(from current: CVPixelBuffer,
                             to reference: CVPixelBuffer) -> CGAffineTransform {
        let request = VNTranslationalImageRegistrationRequest(
            targetedCVPixelBuffer: current,
            options: [:]
        )
        do {
            try handler.perform([request], on: reference)
            if let observation = request.results?.first {
                return observation.alignmentTransform
            }
        } catch {
            LogChannel.stabilizer.debug(
                "Translation registration failed: \(String(describing: error), privacy: .public)"
            )
        }
        return .identity
    }

    // MARK: - Homographic

    private func homographic(from current: CVPixelBuffer,
                             to reference: CVPixelBuffer) -> CGAffineTransform {
        let request = VNHomographicImageRegistrationRequest(
            targetedCVPixelBuffer: current,
            options: [:]
        )
        do {
            try handler.perform([request], on: reference)
            if let observation = request.results?.first {
                // Reduce the 3x3 warp to a 2D affine using the top-left 2x3
                // submatrix. For true warp, apply the full matrix via Metal or
                // a custom CIFilter.
                let m = observation.warpTransform
                return CGAffineTransform(
                    a:  CGFloat(m.columns.0.x), b:  CGFloat(m.columns.0.y),
                    c:  CGFloat(m.columns.1.x), d:  CGFloat(m.columns.1.y),
                    tx: CGFloat(m.columns.2.x), ty: CGFloat(m.columns.2.y)
                )
            }
        } catch {
            LogChannel.stabilizer.debug(
                "Homographic registration failed: \(String(describing: error), privacy: .public)"
            )
        }
        return .identity
    }
}
