//
//  Sendable+CoreVideo.swift
//  LongExposureKit
//
//  Created by Preet Singh on 4/20/26.
//
//  Retroactive Sendable conformances for Core Video / Core Media types we
//  pass across concurrency boundaries. These types are CF-backed and
//  thread-safe for the read-only operations we perform (the pipeline only
//  reads pixel data; it never mutates a CVPixelBuffer).
//
//  Required under Swift 6 strict concurrency for the frame-delivery hop
//  from AVCaptureOutput's video queue to the @MainActor controller.
//

import CoreVideo

extension CVPixelBuffer: @retroactive @unchecked Sendable {}
