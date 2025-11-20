import Foundation

// MARK: - Emoji Constants

enum Emoji {
    // Status
    static let success = "\u{2705}"      // ✅
    static let error = "\u{274C}"        // ❌
    static let warning = "\u{26A0}\u{FE0F}"  // ⚠️
    static let info = "\u{2139}\u{FE0F}"     // ℹ️
    
    // Actions
    static let rocket = "\u{1F680}"      // 🚀
    static let stop = "\u{1F6D1}"        // 🛑
    static let play = "\u{25B6}\u{FE0F}" // ▶️
    static let refresh = "\u{1F504}"     // 🔄
    static let wrench = "\u{1F527}"      // 🔧
    
    // Communication
    static let inbox = "\u{1F4E5}"       // 📥
    static let outbox = "\u{1F4E4}"      // 📤
    static let package = "\u{1F4E6}"     // 📦
    static let memo = "\u{1F4DD}"        // 📝
    
    // Devices & Tech
    static let microphone = "\u{1F3A4}"  // 🎤
    static let keyboard = "\u{2328}\u{FE0F}" // ⌨️
    static let phone = "\u{1F4F1}"       // 📱
    static let globe = "\u{1F310}"       // 🌐
    static let computer = "\u{1F4BB}"    // 💻
    
    // Symbols
    static let magnifier = "\u{1F50D}"   // 🔍
    static let sparkles = "\u{2728}"     // ✨
    static let target = "\u{1F3AF}"      // 🎯
    static let clipboard = "\u{1F4CB}"   // 📋
    static let timer = "\u{23F1}\u{FE0F}" // ⏱️
    static let pin = "\u{1F4CD}"         // 📍
    static let dice = "\u{1F3B2}"        // 🎲
    static let brain = "\u{1F9E0}"       // 🧠
    static let paperclip = "\u{1F4CE}"   // 📎
    static let document = "\u{1F4C4}"    // 📄
    static let return_key = "\u{23CE}"   // ⏎
}

// MARK: - Log Event Types

enum LogEvent: String {
    case app = "APP"
    case mcp = "MCP"
    case asr = "ASR"
    case network = "NET"
    case ui = "UI"
    case config = "CFG"
    case tool = "TOOL"
    case stream = "STREAM"
    case input = "INPUT"
    case cache = "CACHE"
}

// MARK: - Logger

struct Logger {
    private let event: LogEvent
    private let context: String?
    
    // Output mode configuration
    enum OutputMode {
        case console  // Default GUI mode - logs to console
        case file     // CLI mode - logs to file
    }
    
    // Thread-safe storage for global logger state
    private final class LogStorage: @unchecked Sendable {
        static let shared = LogStorage()
        private let queue = DispatchQueue(label: "com.chatswift.logger.storage")
        private var _outputMode: OutputMode = .console
        private var _logFileHandle: FileHandle?
        
        var outputMode: OutputMode {
            get { queue.sync { _outputMode } }
            set { queue.sync { _outputMode = newValue } }
        }
        
        func setFileHandle(_ handle: FileHandle?) {
            queue.sync { _logFileHandle = handle }
        }
        
        func writeToFile(_ data: Data) {
            queue.sync {
                _logFileHandle?.write(data)
            }
        }
        
        func closeFile() {
            queue.sync {
                _logFileHandle?.closeFile()
                _logFileHandle = nil
            }
        }
    }

    static var outputMode: OutputMode {
        get { LogStorage.shared.outputMode }
        set { LogStorage.shared.outputMode = newValue }
    }
    
    init(event: LogEvent, context: String? = nil) {
        self.event = event
        self.context = context
    }
    
    // Enable file logging for CLI mode
    static func enableFileLogging() {
        let configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config")
            .appendingPathComponent("chat.swift")
        
        // Create directory if needed
        try? FileManager.default.createDirectory(at: configPath, withIntermediateDirectories: true)
        
        let logFilePath = configPath.appendingPathComponent("main.log")
        
        // Create or open log file
        if !FileManager.default.fileExists(atPath: logFilePath.path) {
            FileManager.default.createFile(atPath: logFilePath.path, contents: nil)
        }
        
        if let handle = try? FileHandle(forWritingTo: logFilePath) {
            handle.seekToEndOfFile()
            LogStorage.shared.setFileHandle(handle)
            LogStorage.shared.outputMode = .file
            
            // Write session separator
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let separator = "\n=== Session started at \(timestamp) ===\n"
            if let data = separator.data(using: .utf8) {
                LogStorage.shared.writeToFile(data)
            }
        }
    }
    
    // Cleanup file handle on shutdown
    static func shutdown() {
        LogStorage.shared.closeFile()
    }
    
    func info(_ message: String) {
        log(level: "INFO", emoji: Emoji.info, message: message)
    }
    
    func success(_ message: String) {
        log(level: "SUCCESS", emoji: Emoji.success, message: message)
    }
    
    func error(_ message: String) {
        log(level: "ERROR", emoji: Emoji.error, message: message)
    }
    
    func warning(_ message: String) {
        log(level: "WARNING", emoji: Emoji.warning, message: message)
    }
    
    func debug(_ message: String) {
        log(level: "DEBUG", emoji: Emoji.magnifier, message: message)
    }
    
    private func log(level: String, emoji: String, message: String) {
        let contextStr = context.map { " [\($0)]" } ?? ""
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logMessage = "[\(timestamp)] \(emoji) [\(event.rawValue)]\(contextStr) \(message)\n"
        
        switch Logger.outputMode {
        case .console:
            // GUI mode - print to console without timestamp
            print("\(emoji) [\(event.rawValue)]\(contextStr) \(message)")
            
        case .file:
            // CLI mode - write to file with timestamp
            if let data = logMessage.data(using: .utf8) {
                LogStorage.shared.writeToFile(data)
            }
        }
    }
}

// MARK: - Convenience Loggers

extension Logger {
    static func app(_ context: String? = nil) -> Logger {
        Logger(event: .app, context: context)
    }
    
    static func mcp(_ context: String? = nil) -> Logger {
        Logger(event: .mcp, context: context)
    }
    
    static func asr(_ context: String? = nil) -> Logger {
        Logger(event: .asr, context: context)
    }
    
    static func network(_ context: String? = nil) -> Logger {
        Logger(event: .network, context: context)
    }
    
    static func ui(_ context: String? = nil) -> Logger {
        Logger(event: .ui, context: context)
    }
    
    static func config(_ context: String? = nil) -> Logger {
        Logger(event: .config, context: context)
    }
    
    static func tool(_ context: String? = nil) -> Logger {
        Logger(event: .tool, context: context)
    }
    
    static func stream(_ context: String? = nil) -> Logger {
        Logger(event: .stream, context: context)
    }
    
    static func input(_ context: String? = nil) -> Logger {
        Logger(event: .input, context: context)
    }
    
    static func cache(_ context: String? = nil) -> Logger {
        Logger(event: .cache, context: context)
    }
}
