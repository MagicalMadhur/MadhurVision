import Foundation
import UIKit

func signalHandler(signal: Int32) {
    let msg = "CRASH: Fatal Signal \(signal) received (e.g., EX_BAD_ACCESS or SIGABRT)"
    AppLogger.shared.log(msg)
    exit(signal)
}

class AppLogger {
    static let shared = AppLogger()
    
    let logFileURL: URL
    private let logQueue = DispatchQueue(label: "AppLoggerQueue")
    
    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        logFileURL = docs.appendingPathComponent("error_log.txt")
    }
    
    func setupCrashHandlers() {
        // Truncate log if larger than 2MB
        if let attr = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
           let size = attr[.size] as? UInt64, size > 2_000_000 {
            try? FileManager.default.removeItem(at: logFileURL)
        }
        
        log("==========================================")
        log("MadhurVision Launched at \(Date())")
        log("Device: \(UIDevice.current.model), System: \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
        log("Screen Bounds: \(UIScreen.main.bounds.size.width)x\(UIScreen.main.bounds.size.height)")
        log("Log File: \(logFileURL.path)")
        log("==========================================")
        
        // 1. Uncaught Exceptions (Swift throw / Obj-C exceptions)
        NSSetUncaughtExceptionHandler { exception in
            let stack = exception.callStackSymbols.joined(separator: "\n")
            let msg = "CRASH EXCEPTION: \(exception.name.rawValue) - \(exception.reason ?? "No reason")\nStack:\n\(stack)"
            AppLogger.shared.log(msg)
        }
        
        // 2. Fatal Signals (EX_BAD_ACCESS, Memory issues)
        signal(SIGABRT, signalHandler)
        signal(SIGILL, signalHandler)
        signal(SIGSEGV, signalHandler)
        signal(SIGFPE, signalHandler)
        signal(SIGBUS, signalHandler)
        signal(SIGPIPE, signalHandler)
    }
    
    func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let formatted = "[\(timestamp)] \(message)\n"
        print(formatted, terminator: "")
        
        logQueue.async { [weak self] in
            guard let self = self else { return }
            if let data = formatted.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: self.logFileURL.path) {
                    if let fileHandle = try? FileHandle(forWritingTo: self.logFileURL) {
                        fileHandle.seekToEndOfFile()
                        fileHandle.write(data)
                        try? fileHandle.synchronize()
                        fileHandle.closeFile()
                    }
                } else {
                    try? data.write(to: self.logFileURL, options: .atomic)
                }
            }
        }
    }
}
