//
//  LongExposureProcessor.swift
//  LongExposureKit
//
//  Created by Preet Singh on 4/20/26.
//

import CoreImage
import CoreGraphics
import CoreVideo

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public enum BlendMode: String, CaseIterable, Identifiable, Sendable {
    case mean      // daytime: smooths motion (waterfalls, crowds)
    case lighten   // nighttime: accumulates light trails

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .mean:    return "Day"
        case .lighten: return "Night"
        }
    }
}

/// Stateful frame blender. Feed it pixel buffers, get a single long-exposure
/// image out at the end.
///
/// Two modes:
///   - `.mean`: running average. `accumulator_n = ((n-1)/n)*acc + (1/n)*frame`.
///   - `.lighten`: per-pixel max across frames.
///
/// Thread-safety: NOT thread-safe. Feed frames from a single queue.
public final class LongExposureProcessor {
    public let mode: BlendMode

    private let ciContext: CIContext
    private var accumulatorImage: CIImage?
    private var extent: CGRect?
    private(set) public var frameCount: Int = 0

    public init(mode: BlendMode, ciContext: CIContext? = nil) {
        self.mode = mode
        self.ciContext = ciContext ?? CIContext(options: [.useSoftwareRenderer: false])
    }

    /// Add a frame to the running blend.
    /// - Parameters:
    ///   - pixelBuffer: BGRA pixel buffer from the capture pipeline.
    ///   - transform: optional affine transform to align this frame to the
    ///     reference frame. Identity = no stabilization.
    public func add(pixelBuffer: CVPixelBuffer,
                    transform: CGAffineTransform = .identity) {
        var frame = CIImage(cvPixelBuffer: pixelBuffer)
        if !transform.isIdentity {
            frame = frame.transformed(by: transform)
        }

        if extent == nil {
            extent = CIImage(cvPixelBuffer: pixelBuffer).extent
        }
        guard let extent = extent else { return }

        frameCount += 1

        guard let prev = accumulatorImage else {
            accumulatorImage = frame.cropped(to: extent)
            return
        }

        let blended: CIImage
        switch mode {
        case .mean:    blended = meanBlend(prev: prev, frame: frame, n: frameCount)
        case .lighten: blended = lightenBlend(prev: prev, frame: frame)
        }

        // Flatten the CI graph between frames — otherwise it grows unbounded.
        if let cg = ciContext.createCGImage(blended, from: extent) {
            accumulatorImage = CIImage(cgImage: cg)
        } else {
            accumulatorImage = blended.cropped(to: extent)
        }
    }

    /// Final image as CGImage — the cross-platform primitive.
    /// Returns nil if no frames were added.
    public func renderCGImage() -> CGImage? {
        guard let image = accumulatorImage, let extent = extent else { return nil }
        return ciContext.createCGImage(image, from: extent)
    }

    #if canImport(UIKit)
    /// Convenience for iOS/tvOS/visionOS/watchOS apps.
    public func renderUIImage() -> UIImage? {
        guard let cg = renderCGImage() else { return nil }
        let scale: CGFloat = {
            #if os(iOS) || os(tvOS) || os(visionOS)
            return UIScreen.main.scale
            #else
            return 1
            #endif
        }()
        return UIImage(cgImage: cg, scale: scale, orientation: .up)
    }
    #endif

    #if canImport(AppKit)
    /// Convenience for macOS apps.
    public func renderNSImage() -> NSImage? {
        guard let cg = renderCGImage(),
              let extent = extent else { return nil }
        return NSImage(cgImage: cg, size: extent.size)
    }
    #endif

    /// Reset state to start a fresh capture without reallocating the CIContext.
    public func reset() {
        accumulatorImage = nil
        extent = nil
        frameCount = 0
    }

    // MARK: - Blend math

    private func meanBlend(prev: CIImage, frame: CIImage, n: Int) -> CIImage {
        let n = CGFloat(n)
        let prevWeight = (n - 1.0) / n
        let newWeight  = 1.0 / n
        let weightedPrev = scaleRGB(prev, by: prevWeight)
        let weightedNew  = scaleRGB(frame, by: newWeight)
        return weightedNew.applyingFilter("CIAdditionCompositing", parameters: [
            kCIInputBackgroundImageKey: weightedPrev
        ])
    }

    private func lightenBlend(prev: CIImage, frame: CIImage) -> CIImage {
        frame.applyingFilter("CILightenBlendMode", parameters: [
            kCIInputBackgroundImageKey: prev
        ])
    }

    private func scaleRGB(_ image: CIImage, by w: CGFloat) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector":    CIVector(x: w, y: 0, z: 0, w: 0),
            "inputGVector":    CIVector(x: 0, y: w, z: 0, w: 0),
            "inputBVector":    CIVector(x: 0, y: 0, z: w, w: 0),
            "inputAVector":    CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ])
    }
}
