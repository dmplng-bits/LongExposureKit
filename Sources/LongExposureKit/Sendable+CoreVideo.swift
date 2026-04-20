//
//  Sendable+CoreVideo.swift
//  LongExposureKit
//
//  Created by Preet Singh on 4/20/26.
//
//  Retroactive Sendable conformance for CVPixelBuffer. CVPixelBuffer is a
//  CF-backed reference type that's thread-safe for the read operations we
//  perform (the pipeline never mutates a pixel buffer). Required under
//  Swift 6 strict concurrency so the buffer can be passed to a `sending`
//  parameter from a non-sending source (e.g. extracted from a CMSampleBuffer).
//


import CoreVideo

extension CVPixelBuffer: @retroactive @unchecked Sendable {}
