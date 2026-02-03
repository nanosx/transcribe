import Foundation

class Logger {
    static let shared = Logger()
    private let logUrl: URL

    private init() {
        let logPath = FileManager.default.currentDirectoryPath + "/transcriber.log"
        self.logUrl = URL(fileURLWithPath: logPath)
    }

    func log(_ message: String) {
        let entry = "\(Date()): \(message)\n"
        
        // Write to file
        if !FileManager.default.fileExists(atPath: logUrl.path) {
            try? entry.write(to: logUrl, atomically: true, encoding: String.Encoding.utf8)
        } else {
            if let handle = try? FileHandle(forWritingTo: logUrl) {
                handle.seekToEndOfFile()
                if let data = entry.data(using: String.Encoding.utf8) {
                    handle.write(data)
                }
                handle.closeFile()
            }
        }
    }

    func clear() {
        try? "".write(to: logUrl, atomically: true, encoding: String.Encoding.utf8)
    }
}
