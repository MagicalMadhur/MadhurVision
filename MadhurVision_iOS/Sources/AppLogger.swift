import Foundation

func signalHandler(signal: Int32) {
    let msg = "CRASH: Fatal Signal \(signal) received (e.g., EX_BAD_ACCESS or SIGABRT)\n"
    AppLogger.shared.log(msg)
    exit(signal)
}

class AppLogger {
    static let shared = AppLogger()
    
    let logFileURL: URL
    
    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        logFileURL = docs.appendingPathComponent("error_log.txt")
    }
    
    func setupCrashHandlers() {
        // Clear log on startup if it's too large (>1MB)
        if let attr = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
           let size = attr[.size] as? UInt64, size > 1_000_000 {
            try? FileManager.default.removeItem(at: logFileURL)
        }
        
        log("--- App Launched ---")
        
        // 1. Uncaught Exceptions (Swift throw / Obj-C exceptions)
        NSSetUncaughtExceptionHandler { exception in
            let stack = exception.callStackSymbols.joined(separator: "\n")
            let msg = "CRASH: \(exception.name.rawValue) - \(exception.reason ?? "No reason")\nStack:\n\(stack)\n"
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
        print(formatted)
        
        if let data = formatted.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFileURL.path) {
                if let fileHandle = try? FileHandle(forWritingTo: logFileURL) {
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(data)
                    fileHandle.closeFile()
                }
            } else {
                try? data.write(to: logFileURL)
            }
        }
    }
}
