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
    
    init(event: LogEvent, context: String? = nil) {
        self.event = event
        self.context = context
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
        print("\(emoji) [\(event.rawValue)]\(contextStr) \(message)")
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
