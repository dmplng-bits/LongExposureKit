//
//  Logger.swift
//  LongExposureKit
//
//  Created by Preet Singh on 4/25/26.
//
//  Centralized os.Logger instances. One per subsystem so consumers can
//  filter by category in Console.app or `log stream`:
//
//      log stream --predicate 'subsystem == "com.dmplng.LongExposureKit"'
//      log stream --predicate 'subsystem == "com.dmplng.LongExposureKit" && category == "camera"'
//

import OSLog

enum LogChannel {
    static let subsystem = "com.dmplng.LongExposureKit"

    static let camera     = Logger(subsystem: subsystem, category: "camera")
    static let processor  = Logger(subsystem: subsystem, category: "processor")
    static let stabilizer = Logger(subsystem: subsystem, category: "stabilizer")
    static let controller = Logger(subsystem: subsystem, category: "controller")
}
