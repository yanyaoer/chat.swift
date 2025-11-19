#!/usr/bin/env xcrun -sdk macosx swift

import AppKit
import Combine
import Foundation
import SwiftUI
import Speech

// MARK: - Application Delegate

extension Notification.Name {
    static let rightOptionKeyDown = Notification.Name("rightOptionKeyDown")
    static let rightOptionKeyUp = Notification.Name("rightOptionKeyUp")
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var eventMonitor: Any?
    private var keyDownTimer: Timer?
    private var isRightOptionDown = false

    private let rightOptionKeyCode: UInt16 = 61

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Configure window appearance
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let window = NSApplication.shared.windows.first {
            window.level = .floating
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
        }

        // Check accessibility permissions for global key monitoring
        let trusted = AXIsProcessTrusted()
        if !trusted {
            print("⚠️  Accessibility permission required for global key monitoring")
            print("⚠️  Please enable in System Settings > Privacy & Security > Accessibility")
        } else {
            print("✅ Accessibility permission granted")
        }

        // Don't request permissions at startup - let them be requested when user first tries to record
        print("ℹ️  Permissions will be requested when you first use recording feature")

        print("🔧 Setting up event monitors for right Option key (keyCode: \(rightOptionKeyCode))")
        
        // Use local event monitor to catch events when app has focus
        NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { event in
            print("⌨️  Flags changed: keyCode=\(event.keyCode), modifierFlags=\(event.modifierFlags.rawValue)")
            if event.keyCode == self.rightOptionKeyCode {
                let isPressed = event.modifierFlags.contains(.option)
                print("✅ Right Option key \(isPressed ? "pressed" : "released")")
                
                if isPressed {
                    if !self.isRightOptionDown {
                        self.isRightOptionDown = true
                        print("📤 Posting rightOptionKeyDown notification (short press)")
                        NotificationCenter.default.post(name: .rightOptionKeyDown, object: nil, userInfo: ["isLongPress": false])
                        self.keyDownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { _ in
                            print("📤 Posting rightOptionKeyDown notification (long press)")
                            NotificationCenter.default.post(name: .rightOptionKeyDown, object: nil, userInfo: ["isLongPress": true])
                        }
                    }
                } else {
                    if self.isRightOptionDown {
                        self.isRightOptionDown = false
                        self.keyDownTimer?.invalidate()
                        print("📤 Posting rightOptionKeyUp notification")
                        NotificationCenter.default.post(name: .rightOptionKeyUp, object: nil)
                    }
                }
            }
            return event
        }
        
        // Also use global monitor for when app doesn't have focus
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { event in
            print("⌨️  Global flags changed: keyCode=\(event.keyCode)")
            if event.keyCode == self.rightOptionKeyCode {
                let isPressed = event.modifierFlags.contains(.option)
                print("✅ Right Option key \(isPressed ? "pressed" : "released") (global)")
                
                if isPressed {
                    if !self.isRightOptionDown {
                        self.isRightOptionDown = true
                        print("📤 Posting rightOptionKeyDown notification (short press)")
                        NotificationCenter.default.post(name: .rightOptionKeyDown, object: nil, userInfo: ["isLongPress": false])
                        self.keyDownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { _ in
                            print("📤 Posting rightOptionKeyDown notification (long press)")
                            NotificationCenter.default.post(name: .rightOptionKeyDown, object: nil, userInfo: ["isLongPress": true])
                        }
                    }
                } else {
                    if self.isRightOptionDown {
                        self.isRightOptionDown = false
                        self.keyDownTimer?.invalidate()
                        print("📤 Posting rightOptionKeyUp notification")
                        NotificationCenter.default.post(name: .rightOptionKeyUp, object: nil)
                    }
                }
            }
        }
        
        if eventMonitor == nil {
            print("❌ Failed to create global event monitor")
        } else {
            print("✅ Event monitors created successfully")
        }
    }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }
}

// MARK: - UI Utilities

struct VisualEffect: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.blendingMode = .behindWindow
    view.state = .active
    view.material = .underWindowBackground
    return view
  }
  func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - UI Style Extensions

extension View {
  func appButtonStyle() -> some View {
    padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(Color.blue.opacity(0.1))
      .cornerRadius(6)
  }

  func popoverStyle() -> some View {
    padding()
      .frame(width: 300, height: 400)
      .background(VisualEffect())
  }
}

// MARK: - Constants

enum AppConstants {
  static let configDirectoryName = "chat.swift"
  static let historyFileName = "history.md"
  static let promptsDirectoryName = "prompts"
  static let mcpConfigFileName = "mcp_config.json"
  static let mainConfigFileName = "config.json"
  
  enum UserDefaults {
    static let modelName = "modelname"
    static let selectedPrompt = "selectedPrompt"
  }
  
  enum DefaultModels {
    static let openAI = "gpt-4-turbo-preview"
  }
}

// MARK: - Error Handling

enum AppError: LocalizedError {
  case configNotFound(String)
  case configCorrupted(String)
  case networkError(String)
  case mcpError(String)
  case fileOperationError(String)
  case jsonParsingError(String)
  case invalidURL(String)
  case mcpServerNotFound(String)
  case mcpExecutionFailed(String)

  var errorDescription: String? {
    switch self {
    case .configNotFound(let path):
      return "配置文件未找到: \(path)"
    case .configCorrupted(let details):
      return "配置文件格式错误: \(details)"
    case .networkError(let message):
      return "网络错误: \(message)"
    case .mcpError(let message):
      return "MCP服务错误: \(message)"
    case .fileOperationError(let message):
      return "文件操作错误: \(message)"
    case .jsonParsingError(let message):
      return "JSON解析错误: \(message)"
    case .invalidURL(let url):
      return "无效的URL: \(url)"
    case .mcpServerNotFound(let name):
      return "MCP服务器未找到或未激活: \(name)"
    case .mcpExecutionFailed(let details):
      return "MCP工具执行失败: \(details)"
    }
  }
}

// MARK: - Data Models

struct ChatMessage: Encodable {
  let role: String
  let content: MessageContent
  let timestamp: Date
  let model: String?
  let reasoning_effort: String?  // "low", "medium", and "high", which behind the scenes we map to 1K, 8K, and 24K thinking token budgets
  var id: String?

  init(
    role: String, content: MessageContent, model: String? = nil, reasoning_effort: String? = nil,
    id: String? = nil
  ) {
    self.role = role
    self.content = content
    self.timestamp = Date()
    self.model = model
    self.reasoning_effort = reasoning_effort
    self.id = id
  }

  private enum CodingKeys: String, CodingKey {
    case role, content, reasoning_effort
  }
}

enum MessageContent: Codable {
  case text(String)
  case multimodal([ContentItem])

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .text(let string):
      try container.encode(string)
    case .multimodal(let items):
      try container.encode(items)
    }
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let string = try? container.decode(String.self) {
      self = .text(string)
    } else if let items = try? container.decode([ContentItem].self) {
      self = .multimodal(items)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "Invalid message content")
    }
  }
}

struct ContentItem: Codable {
  let type: String
  let text: String?
  let image_url: ImageURL?
}

struct ImageURL: Codable {
  let url: String
}

struct ChatRequest: Encodable {
  let model: String
  var messages: [ChatMessage]
  let stream: Bool
}

// MARK: - MCP Models

struct MCPServer: Codable {
  let command: String?
  let args: [String]?
  let env: [String: String]?
  let isActive: Bool?
  let type: String?
  let description: String?
  let url: String?
  let headers: [String: String]?

  init(
    command: String? = nil, args: [String]? = nil, env: [String: String]? = nil,
    isActive: Bool? = nil, type: String? = nil, description: String? = nil,
    url: String? = nil, headers: [String: String]? = nil
  ) {
    self.command = command
    self.args = args
    self.env = env
    self.isActive = isActive
    self.type = type
    self.description = description
    self.url = url
    self.headers = headers
  }

  var isRemote: Bool {
    return type == "http" || type == "sse" || url != nil
  }
}

struct MCPConfig: Codable, ConfigLoadable {
  let mcpServers: [String: MCPServer]

  static var configPath: URL {
    return FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".config")
      .appendingPathComponent(AppConstants.configDirectoryName)
      .appendingPathComponent(AppConstants.mcpConfigFileName)
  }
}

// MARK: - Configuration Helper

protocol ConfigLoadable {
  static var configPath: URL { get }
}

extension ConfigLoadable {
  static func loadConfig<T: Codable>(_ type: T.Type) throws -> T {
    let data = try Data(contentsOf: configPath)
    return try JSONDecoder().decode(type, from: data)
  }
}

extension OpenAIConfig {
  static let safeDefaultModel = AppConstants.DefaultModels.openAI
  
  static func getDefaultModel() -> String {
    do {
      let config = try loadConfig(OpenAIConfig.self)
      return config.defaultModel
    } catch {
      print("Warning: Could not load config for default model, using safe fallback")
      return safeDefaultModel
    }
  }
}

struct ToolCall {
  let toolName: String
  let parameters: [String: String]
  let isComplete: Bool
}

// MARK: - Tool Parser

struct ToolParser {
  // Regex patterns as static constants
  private static let toolUseStartTag = "<tool_use>"
  private static let toolUseEndTag = "</tool_use>"
  private static let xmlTagPattern = #"<(\w+)>"#
  private static let parameterPattern = #"<(\w+)>(.*?)</\1>"#
  
  static func extractToolCalls(from text: String) -> [ToolCall] {
    var calls: [ToolCall] = []
    var startIndex = text.startIndex
    
    while let range = text[startIndex...].range(of: toolUseStartTag) {
      let toolStart = range.upperBound
      if let endRange = text[toolStart...].range(of: toolUseEndTag) {
        let toolContent = String(text[toolStart..<endRange.lowerBound])
        if let call = parseToolCall(from: toolContent, isComplete: true) {
          calls.append(call)
        }
        startIndex = endRange.upperBound
      } else {
        // Incomplete tool call
        let toolContent = String(text[toolStart...])
        if let call = parseToolCall(from: toolContent, isComplete: false) {
          calls.append(call)
        }
        break
      }
    }
    return calls
  }
  
  private static func parseToolCall(from content: String, isComplete: Bool) -> ToolCall? {
    // Extract tool name (first XML tag)
    guard let nameMatch = content.range(of: xmlTagPattern, options: .regularExpression),
          let toolName = extractBetween(String(content[nameMatch]), start: "<", end: ">") else {
      return nil
    }
    
    // Extract parameters within tool content
    var parameters: [String: String] = [:]
    
    // Find content within the tool tag first
    let toolTagPattern = "<\(toolName)>(.*?)</\(toolName)>"
    if let toolContentRange = content.range(of: toolTagPattern, options: .regularExpression) {
      let toolContent = String(content[toolContentRange])
        .replacingOccurrences(of: "<\(toolName)>", with: "")
        .replacingOccurrences(of: "</\(toolName)>", with: "")
      
      // Parse individual parameters
      if let regex = try? NSRegularExpression(pattern: parameterPattern, options: [.dotMatchesLineSeparators]) {
        regex.enumerateMatches(in: toolContent, range: NSRange(toolContent.startIndex..<toolContent.endIndex, in: toolContent)) { match, _, _ in
          guard let match = match, match.numberOfRanges >= 3,
                let nameRange = Range(match.range(at: 1), in: toolContent),
                let valueRange = Range(match.range(at: 2), in: toolContent) else { return }
          
          let name = String(toolContent[nameRange])
          let value = String(toolContent[valueRange])
          parameters[name] = value
        }
      }
    }
    
    return ToolCall(toolName: toolName, parameters: parameters, isComplete: isComplete)
  }
  
  private static func extractBetween(_ text: String, start: String, end: String) -> String? {
    guard let startRange = text.range(of: start),
          let endRange = text[startRange.upperBound...].range(of: end) else { return nil }
    return String(text[startRange.upperBound..<endRange.lowerBound])
  }
}

// MARK: - Stream Processor

struct StreamChunk {
  let content: String
  let isReasoning: Bool
}

struct StreamProcessor {
  
  // Process incoming data and split into complete lines
  static func processIncomingData(_ newData: String, buffer: inout String) -> [String] {
    buffer += newData
    
    let lines = buffer.components(separatedBy: "\n")
    
    // Keep the last line in buffer if it's incomplete (no trailing newline)
    if !buffer.hasSuffix("\n") && lines.count > 1 {
      buffer = lines.last ?? ""
      return Array(lines.dropLast())
    } else {
      buffer = ""
      return lines
    }
  }
  
  // Parse SSE (Server-Sent Events) lines and extract content chunks
  static func parseSSELine(_ line: String) -> StreamChunk? {
    // Handle [DONE] marker
    if line.contains("data: [DONE]") {
      return nil
    }
    
    // Must start with "data: "
    guard line.hasPrefix("data: ") else {
      return nil
    }
    
    // Parse JSON data
    let jsonString = String(line.dropFirst(6))
    guard !jsonString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let jsonData = jsonString.data(using: .utf8) else {
      return nil
    }
    
    do {
      guard let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let firstChoice = choices.first,
            let delta = firstChoice["delta"] as? [String: Any] else {
        return nil
      }
      
      // Check for reasoning content first, then regular content
      if let reasoningContent = delta["reasoning_content"] as? String {
        return StreamChunk(content: reasoningContent, isReasoning: true)
      } else if let regularContent = delta["content"] as? String {
        return StreamChunk(content: regularContent, isReasoning: false)
      }
      
      return nil
    } catch {
      print("Error parsing JSON line: \(jsonString), Error: \(error)")
      return nil
    }
  }
}

// MARK: - System Configuration

struct SystemPrompt: Codable {
  let role: String
  let content: String
}

// MARK: - Business Logic Managers

@MainActor
class MCPManager: ObservableObject {
  static let shared = MCPManager()
  @Published private var mcpServers: [String: MCPServer] = [:]
  @Published private var activeMCPServers: Set<String> = []

  private init() {
    loadMCPConfig()
  }

  private func loadMCPConfig() {
    do {
      let config = try MCPConfig.loadConfig(MCPConfig.self)
      mcpServers = config.mcpServers
      activeMCPServers = Set(config.mcpServers.filter { $0.value.isActive == true }.keys)
      print("MCP config loaded successfully: \(mcpServers.count) servers")
    } catch {
      print("Error loading MCP config from \(MCPConfig.configPath): \(error)")
    }
  }

  func getMCPServers() -> [String: MCPServer] {
    return mcpServers
  }

  func getActiveMCPServers() -> Set<String> {
    return activeMCPServers
  }

  func setServerActive(_ serverName: String, active: Bool) {
    if active {
      activeMCPServers.insert(serverName)
    } else {
      activeMCPServers.remove(serverName)
    }
    var updatedServers = mcpServers
    for (name, server) in updatedServers {
      updatedServers[name] = MCPServer(
        command: server.command,
        args: server.args,
        env: server.env,
        isActive: activeMCPServers.contains(name) ? true : nil,
        type: server.type,
        description: server.description,
        url: server.url,
        headers: server.headers
      )
    }
    mcpServers = updatedServers
  }

  func callMCPTool(serverName: String, toolName: String, arguments: [String: Any]) async -> Result<String, AppError> {
    guard let server = mcpServers[serverName], activeMCPServers.contains(serverName) else {
      return .failure(.mcpServerNotFound(serverName))
    }

    if server.isRemote {
      return await callRemoteMCPTool(server: server, toolName: toolName, arguments: arguments)
    } else {
      return await callLocalMCPTool(server: server, toolName: toolName, arguments: arguments)
    }
  }

  private func callRemoteMCPTool(server: MCPServer, toolName: String, arguments: [String: Any])
    async -> Result<String, AppError>
  {
    guard let urlString = server.url, let url = URL(string: urlString) else {
      return .failure(.invalidURL(server.url ?? "nil"))
    }

    // Create the MCP tool call request
    let requestBody: [String: Any] = [
      "method": "tools/call",
      "params": [
        "name": toolName,
        "arguments": arguments,
      ],
    ]

    do {
      var request = URLRequest(url: url)
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")

      // Add custom headers if provided
      if let headers = server.headers {
        for (key, value) in headers {
          request.setValue(value, forHTTPHeaderField: key)
        }
      }

      // Add authorization header if available from GitHub token
      if let token = ProcessInfo.processInfo.environment["GITHUB_TOKEN"] {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      } else if let token = ProcessInfo.processInfo.environment["GITHUB_PERSONAL_ACCESS_TOKEN"] {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      } else if let token = ProcessInfo.processInfo.environment["GH_TOKEN"] {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      }

      request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

      let (data, response) = try await URLSession.shared.data(for: request)

      if let httpResponse = response as? HTTPURLResponse {
        if httpResponse.statusCode == 200 {
          if let jsonResponse = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let result = jsonResponse["result"]
          {
            if let resultData = try? JSONSerialization.data(withJSONObject: result),
              let resultString = String(data: resultData, encoding: .utf8)
            {
              return .success(resultString)
            }
            return .success("\(result)")
          }
          return .success(String(data: data, encoding: .utf8) ?? "No response data")
        } else {
          let errorMsg = String(data: data, encoding: .utf8) ?? "Unknown error"
          return .failure(.networkError("HTTP \(httpResponse.statusCode): \(errorMsg)"))
        }
      }

      return .failure(.networkError("No response"))
    } catch {
      return .failure(.mcpError("Failed to call remote MCP tool: \(error.localizedDescription)"))
    }
  }

  private func callLocalMCPTool(server: MCPServer, toolName: String, arguments: [String: Any]) async
    -> Result<String, AppError>
  {
    guard let command = server.command, let args = server.args else {
      return .failure(.mcpError("Local server missing command or args"))
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [command] + args

    if let env = server.env {
      var environment = ProcessInfo.processInfo.environment
      for (key, value) in env {
        environment[key] = value
      }
      process.environment = environment
    }

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    do {
      try process.run()
      process.waitUntilExit()

      let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
      let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

      if process.terminationStatus == 0 {
        return .success(String(data: outputData, encoding: .utf8) ?? "No output")
      } else {
        let errorOutput = String(data: errorData, encoding: .utf8) ?? "Unknown error"
        return .failure(.mcpExecutionFailed("Error executing MCP tool: \(errorOutput)"))
      }
    } catch {
      return .failure(.mcpError("Failed to execute MCP tool: \(error.localizedDescription)"))
    }
  }
}

@MainActor
class ChatHistory {
  static let shared = ChatHistory()
  private let historyPath: URL
  private let promptsPath: URL
  @AppStorage("selectedPrompt") private var selectedPrompt: String = ""

  private init() {
    let configPath = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".config")
      .appendingPathComponent(AppConstants.configDirectoryName)

    try? FileManager.default.createDirectory(at: configPath, withIntermediateDirectories: true)

    historyPath = configPath.appendingPathComponent(AppConstants.historyFileName)
    promptsPath = configPath.appendingPathComponent(AppConstants.promptsDirectoryName)
    try? FileManager.default.createDirectory(at: promptsPath, withIntermediateDirectories: true)
  }

  func handleFileUpload(fileURL: URL, associatedText: String?) async -> MessageContent? {
    let fileType = fileURL.pathExtension.lowercased()
    let supportedImageTypes = ["jpg", "jpeg", "png", "gif", "webp"]

    guard supportedImageTypes.contains(fileType) else {
      print("Unsupported file type: \(fileType)")
      return nil
    }

    guard fileURL.startAccessingSecurityScopedResource() else {
      print("Failed to access the file at \(fileURL.path)")
      return nil
    }
    defer {
      fileURL.stopAccessingSecurityScopedResource()
    }

    do {
      let fileData = try Data(contentsOf: fileURL)
      let base64String = fileData.base64EncodedString()

      let mimeType: String
      switch fileType {
      case "jpg", "jpeg": mimeType = "image/jpeg"
      case "png": mimeType = "image/png"
      case "gif": mimeType = "image/gif"
      case "webp": mimeType = "image/webp"
      default: mimeType = "application/octet-stream"
      }

      let imageUrl = "data:\(mimeType);base64,\(base64String)"

      var contentItems = [ContentItem]()
      if let text = associatedText, !text.isEmpty {
        contentItems.append(ContentItem(type: "text", text: text, image_url: nil))
      }
      contentItems.append(
        ContentItem(type: "image_url", text: nil, image_url: ImageURL(url: imageUrl)))

      guard !contentItems.isEmpty else {
        print("Error: No content items created for file upload.")
        return nil
      }
      return .multimodal(contentItems)

    } catch {
      print("Error reading or encoding file: \(error.localizedDescription)")
      return nil
    }
  }

  func getAvailablePrompts() async -> [String] {
    do {
      let files = try FileManager.default.contentsOfDirectory(atPath: promptsPath.path)
      return files.filter { $0.hasSuffix(".md") }.map { String($0.dropLast(3)) }.sorted()
    } catch {
      return []
    }
  }

  func loadPromptContent(name: String) -> SystemPrompt? {
    let fileURL = promptsPath.appendingPathComponent("\(name).md")
    do {
      let content = try String(contentsOf: fileURL, encoding: .utf8)
      return SystemPrompt(role: "system", content: content)
    } catch {
      return nil
    }
  }

  func saveMessage(_ message: ChatMessage) {
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let timestamp = dateFormatter.string(from: message.timestamp)

    let modelInfo = message.model.map { " [\($0)]" } ?? ""
    let promptInfo = message.role == "system" ? " [Prompt: \(selectedPrompt)]" : ""
    let idInfo = message.id.map { " [ID: \($0)]" } ?? ""

    let contentText: String
    switch message.content {
    case .text(let text):
      contentText = text
    case .multimodal(let items):
      contentText = items.map { item in
        if let text = item.text {
          return text
        } else if let imageUrl = item.image_url {
          let displayUrl =
            imageUrl.url.count > 100
            ? String(imageUrl.url.prefix(50)) + "..." + String(imageUrl.url.suffix(20))
            : imageUrl.url
          return "[Image: \(displayUrl)]"
        }
        return ""
      }.joined(separator: "\n")
    }

    let text = """
          
      [\(timestamp)] \(message.role)\(modelInfo)\(idInfo)\(promptInfo):
      \(contentText)
      """

    if let data = text.data(using: .utf8) {
      if FileManager.default.fileExists(atPath: historyPath.path) {
        if let handle = try? FileHandle(forWritingTo: historyPath) {
          handle.seekToEndOfFile()
          handle.write(data)
          handle.closeFile()
        }
      } else {
        try? data.write(to: historyPath)
      }
    }
  }

  func sendMessage(
    userText: String?,
    messageContent: MessageContent? = nil,
    modelname: String,
    selectedPrompt: String,
    streamDelegate: StreamDelegate,
    messageID: String,
    onQueryCompleted: @escaping () -> Void
  ) async {
    print("🚀 [sendMessage] === START ===")
    print("🚀 [sendMessage] Message ID: \(messageID)")
    print("🚀 [sendMessage] Model: \(modelname)")
    print("🚀 [sendMessage] User text: \(userText ?? "nil")")
    print("🚀 [sendMessage] Has message content: \(messageContent != nil)")
    
    let config = OpenAIConfig.load()
    guard let modelConfig = config.getConfig(for: modelname),
          let baseURL = modelConfig.baseURL,
          let apiKey = modelConfig.apiKey else {
      print("❌ [sendMessage] Error: Model configuration not found or incomplete for \(modelname)")
      onQueryCompleted()
      return
    }

    print("🚀 [sendMessage] Base URL: \(baseURL)")
    print("🚀 [sendMessage] API Key: \(apiKey.prefix(10))...")
    
    let url = URL(string: "\(baseURL)/chat/completions")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

    var messagesToSend: [ChatMessage] = []

    if !selectedPrompt.isEmpty, selectedPrompt != "None",
      let prompt = loadPromptContent(name: selectedPrompt)
    {
      let systemMessage = ChatMessage(role: prompt.role, content: .text(prompt.content), model: nil)
      messagesToSend.append(systemMessage)
    }

    // Add MCP context if active servers exist
    let activeMCPServers = MCPManager.shared.getActiveMCPServers()
    if !activeMCPServers.isEmpty {
      let mcpContext = """
        Available MCP servers: \(Array(activeMCPServers).joined(separator: ", ")).

        To use MCP tools, use this XML format:
        <tool_use>
        <mcp_call>
        <server>server_name</server>
        <tool>tool_name</tool>
        <param1>value1</param1>
        <param2>value2</param2>
        </mcp_call>
        </tool_use>

        For GitHub MCP servers, example tools include:
        - create_issue: Create a new issue
        - list_issues: List repository issues  
        - create_pull_request: Create a pull request
        - search_repositories: Search for repositories

        Note: Remote GitHub MCP servers require authentication via GITHUB_TOKEN environment variable.
        """
      let mcpSystemMessage = ChatMessage(role: "system", content: .text(mcpContext), model: nil)
      messagesToSend.append(mcpSystemMessage)
    }

    let finalContent: MessageContent
    if let content = messageContent {
      finalContent = content
    } else if let text = userText, !text.isEmpty {
      finalContent = .text(text)
    } else {
      print("Error: No message content to send.")
      onQueryCompleted()
      return
    }

    let userMessage = ChatMessage(
      role: "user", content: finalContent, model: modelname, id: messageID)
    messagesToSend.append(userMessage)
    saveMessage(userMessage)

    // Extract pure model name without @provider suffix for API request
    let pureModelName = modelname.split(separator: "@").first.map(String.init) ?? modelname
    print("🚀 [sendMessage] Using pure model name for API: '\(pureModelName)' (from '\(modelname)')")
    
    let chatRequest = ChatRequest(
      model: pureModelName, messages: messagesToSend, stream: true
    )

    print("🚀 [sendMessage] Preparing request with \(messagesToSend.count) messages")
    
    do {
      let encoder = JSONEncoder()
      request.httpBody = try encoder.encode(chatRequest)
      
      if let httpBody = request.httpBody, let bodyString = String(data: httpBody, encoding: .utf8) {
        print("🚀 [sendMessage] Request body preview: \(bodyString.prefix(200))...")
      }
    } catch {
      print("❌ [sendMessage] Error encoding request: \(error)")
      onQueryCompleted()
      return
    }

    let sessionConfig = URLSessionConfiguration.default
    if let proxyEnabled = modelConfig.proxyEnabled, proxyEnabled,
      let proxyURLString = modelConfig.proxyURL, !proxyURLString.isEmpty,
      let proxyComponents = URLComponents(string: proxyURLString),
      let proxyHost = proxyComponents.host,
      let proxyPort = proxyComponents.port
    {
      let scheme = proxyComponents.scheme?.lowercased()
      switch scheme {
      case "socks5":
        sessionConfig.connectionProxyDictionary = [
          kCFNetworkProxiesSOCKSEnable: true,
          kCFNetworkProxiesSOCKSProxy: proxyHost,
          kCFNetworkProxiesSOCKSPort: proxyPort,
          kCFStreamPropertySOCKSVersion: kCFStreamSocketSOCKSVersion5,
        ]
      case "http":
        sessionConfig.connectionProxyDictionary = [
          kCFNetworkProxiesHTTPEnable: true,
          kCFNetworkProxiesHTTPProxy: proxyHost,
          kCFNetworkProxiesHTTPPort: proxyPort,
        ]
      case "https":
        sessionConfig.connectionProxyDictionary = [
          kCFNetworkProxiesHTTPSEnable: true,
          kCFNetworkProxiesHTTPSProxy: proxyHost,
          kCFNetworkProxiesHTTPSPort: proxyPort,
        ]
      default:
        print("Unsupported proxy scheme: \(scheme ?? "nil"). Proxy not configured.")
      }
    }

    print("🚀 [sendMessage] Setting up stream delegate...")
    streamDelegate.output = AttributedString("")
    streamDelegate.setModel(modelname)
    streamDelegate.currentMessageID = messageID
    streamDelegate.setQueryCompletionCallback(onQueryCompleted)

    print("🚀 [sendMessage] Creating URLSession and starting task...")
    let session = URLSession(
      configuration: sessionConfig, delegate: streamDelegate, delegateQueue: nil)
    let task = session.dataTask(with: request)
    streamDelegate.currentTask = task
    task.resume()
    print("🚀 [sendMessage] Task resumed, waiting for response...")
    print("🚀 [sendMessage] === END ===")
  }
}

// MARK: - Network Layer

final class StreamDelegate: NSObject, URLSessionDataDelegate, ObservableObject, @unchecked Sendable
{
  @Published var output: AttributedString = ""
  private var currentResponse: String = ""
  private var currentModel: String = ""
  private var isCurrentlyReasoning: Bool = false
  private var pendingMCPCall: String = ""
  private var dataBuffer: String = ""  // Buffer for incomplete streaming data
  var currentTask: URLSessionDataTask?
  var currentMessageID: String?
  var onQueryCompleted: (() -> Void)?

  override init() {
    super.init()
  }

  func cancelCurrentQuery() {
    print("🛑 [cancelCurrentQuery] Cancelling query...")
    currentTask?.cancel()
    DispatchQueue.main.async {
      self.output = AttributedString("")
      self.currentResponse = ""
      self.isCurrentlyReasoning = false
      self.pendingMCPCall = ""
      self.dataBuffer = ""
      self.onQueryCompleted?()
    }
    self.currentTask = nil
    self.currentMessageID = nil
    print("🛑 [cancelCurrentQuery] Query cancelled and StreamDelegate state reset.")
  }

  func setQueryCompletionCallback(_ callback: @escaping () -> Void) {
    self.onQueryCompleted = callback
  }

  func setModel(_ model: String) {
    currentModel = model
  }

  private func detectAndExecuteMCPCall(_ text: String) async {
    let toolCalls = ToolParser.extractToolCalls(from: text)
    for call in toolCalls where call.isComplete && call.toolName == "mcp_call" {
      await executeMCPTool(call)
    }
  }
  
  private func executeMCPTool(_ call: ToolCall) async {
    guard let server = call.parameters["server"],
          let tool = call.parameters["tool"] else { return }
    
    let args = call.parameters.filter { !["server", "tool"].contains($0.key) }
    let argsDisplay = args.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
    
    let argsInfo = argsDisplay.isEmpty ? "" : "参数:\n\(argsDisplay)\n"
    await updateUI("🔧 执行 MCP 工具", "服务器: \(server)\n工具: \(tool)\n\(argsInfo)\n执行中...")
    
    let result = await MCPManager.shared.callMCPTool(serverName: server, toolName: tool, arguments: args)
    
    switch result {
    case .success(let output):
        let formatted = formatResult(output)
        await updateUI("📋 工具结果", "```\n\(formatted)\n```")
    case .failure(let error):
        await updateUI("❌ 工具执行失败", error.localizedDescription)
    }
  }
  
  @MainActor private func updateUI(_ header: String, _ content: String) {
    var headerAttr = AttributedString("\n\(header)\n")
    headerAttr.foregroundColor = header.contains("工具结果") ? .green : .blue
    
    var contentAttr = AttributedString(content + "\n")
    contentAttr.foregroundColor = .primary
    
    output += headerAttr + contentAttr
    if header.contains("工具结果") {
      currentResponse += "\n\(header):\n\(content)\n"
    }
  }
  
  private func formatResult(_ result: String) -> String {
    var formatted = result
      .replacingOccurrences(of: "\\n", with: "\n")
      .replacingOccurrences(of: "\\\"", with: "\"")
    
    // Pretty print JSON if possible
    if formatted.hasPrefix("{") || formatted.hasPrefix("["),
       let data = formatted.data(using: .utf8),
       let json = try? JSONSerialization.jsonObject(with: data),
       let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]),
       let prettyString = String(data: pretty, encoding: .utf8) {
      formatted = prettyString
    }
    return formatted
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    let msgID = currentMessageID ?? "nil"
    print("📥 [didReceive] Received \(data.count) bytes, Message ID: \(msgID)")
    
    guard currentTask == dataTask, currentMessageID != nil else {
      print("⚠️ [didReceive] Ignoring data - task mismatch or no message ID")
      return
    }

    if let text = String(data: data, encoding: .utf8) {
      print("📥 [didReceive] Data text preview: \(text.prefix(100))...")
      if let response = dataTask.response as? HTTPURLResponse,
        response.statusCode >= 400
      {
        DispatchQueue.main.async {
          var errorChunk = AttributedString("\nError: HTTP \(response.statusCode)\n\(text)")
          errorChunk.foregroundColor = .red
          self.output += errorChunk
          self.isCurrentlyReasoning = false
          self.onQueryCompleted?()
        }
        return
      }

      // Use StreamProcessor to handle buffer and extract complete lines
      let lines = StreamProcessor.processIncomingData(text, buffer: &dataBuffer)
      processLines(lines)
    }
  }

  private func processLines(_ lines: [String]) {
    for line in lines {
      print("🔄 [processLines] Processing line: \(line.prefix(100))...")
      
      // Check for [DONE] marker
      if line.contains("data: [DONE]") {
        print("✅ [processLines] Received [DONE] marker")
        let finalResponse = currentResponse
        DispatchQueue.main.async {
          if !finalResponse.isEmpty {
            let assistantMessage = ChatMessage(
              role: "assistant", content: .text(finalResponse), model: self.currentModel,
              id: self.currentMessageID)
            ChatHistory.shared.saveMessage(assistantMessage)
          }
          self.currentResponse = ""
          self.isCurrentlyReasoning = false
          self.pendingMCPCall = ""
          self.dataBuffer = ""
          self.currentTask = nil
          self.currentMessageID = nil
          self.onQueryCompleted?()
        }
        return
      }

      // Use StreamProcessor to parse SSE line
      guard let chunk = StreamProcessor.parseSSELine(line) else {
        continue
      }
      
      print("✨ [processLines] Got content chunk (\(chunk.isReasoning ? "reasoning" : "normal")): \(chunk.content.prefix(50))...")
      
      DispatchQueue.main.async { [chunk] in
        guard self.currentMessageID != nil else { return }

        var chunkToAppend = chunk.content
        var attributedChunk: AttributedString

        // Handle transition from reasoning to normal content
        if !chunk.isReasoning && self.isCurrentlyReasoning {
          chunkToAppend = "\n" + chunkToAppend
          self.isCurrentlyReasoning = false
        }

        if chunk.isReasoning {
          self.isCurrentlyReasoning = true
        }

        self.currentResponse += chunkToAppend
        self.pendingMCPCall += chunkToAppend

        attributedChunk = AttributedString(chunkToAppend)
        if chunk.isReasoning {
          attributedChunk.foregroundColor = .secondary
        }
        self.output += attributedChunk

        // Check for MCP action pattern in accumulated text
        Task {
          await self.detectAndExecuteMCPCall(self.pendingMCPCall)
        }
      }
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard currentTask == task && currentMessageID != nil else {
      if error == nil || (error as NSError?)?.code == NSURLErrorCancelled {
        print("Completion handler for an outdated/cancelled task, ignoring.")
      } else if let error = error {
        print("Error for an outdated task: \(error.localizedDescription)")
      }
      return
    }

    if let error = error {
      DispatchQueue.main.async {
        self.currentResponse = ""
        if (error as NSError).code == NSURLErrorCancelled {
          print("URLSession task explicitly cancelled.")
        } else {
          var errorChunk = AttributedString("\nNetwork Error: \(error.localizedDescription)")
          errorChunk.foregroundColor = .red
          self.output += errorChunk
        }
        self.isCurrentlyReasoning = false
        self.pendingMCPCall = ""
        self.dataBuffer = ""
        self.onQueryCompleted?()
      }
    } else {
      // Only save if not already saved in [DONE] handler
      DispatchQueue.main.async {
        if !self.currentResponse.isEmpty {
          let assistantMessage = ChatMessage(
            role: "assistant", content: .text(self.currentResponse), model: self.currentModel,
            id: self.currentMessageID)
          ChatHistory.shared.saveMessage(assistantMessage)
        }
        self.currentResponse = ""
        self.isCurrentlyReasoning = false
        self.pendingMCPCall = ""
        self.dataBuffer = ""
        self.onQueryCompleted?()
      }
    }
    self.currentTask = nil
    self.currentMessageID = nil
  }
}

// MARK: - View Model

@MainActor
final class ChatViewModel: ObservableObject {
  @Published var input: String = ""
  @Published var isQueryActive: Bool = false
  @Published var currentMessageID: String?
  @Published var selectedFileURL: URL?
  @Published var selectedFileName: String?
  
  let streamDelegate: StreamDelegate
  let speechManager: SpeechManager
  
  var modelname: String = OpenAIConfig.getDefaultModel()
  var selectedPrompt: String = ""
  
  private var cancellables = Set<AnyCancellable>()
  
  init() {
    self.streamDelegate = StreamDelegate()
    self.speechManager = SpeechManager()
    
    // Forward nested ObservableObjects' changes to trigger view updates
    speechManager.objectWillChange.sink { [weak self] _ in
      self?.objectWillChange.send()
    }.store(in: &cancellables)
    
    streamDelegate.objectWillChange.sink { [weak self] _ in
      self?.objectWillChange.send()
    }.store(in: &cancellables)
  }
  
  func submitInput() async {
    print("📤 [submitInput] === START ===")
    print("📤 [submitInput] Input text: '\(input)'")
    
    let newMessageID = UUID().uuidString
    self.currentMessageID = newMessageID
    
    let textToSend = self.input
    let fileURLToSend = self.selectedFileURL
    
    print("📤 [submitInput] Message ID: \(newMessageID)")
    print("📤 [submitInput] Text to send: '\(textToSend)'")
    print("📤 [submitInput] Model: \(modelname)")
    print("📤 [submitInput] Prompt: \(selectedPrompt)")
    print("📤 [submitInput] Has file: \(fileURLToSend != nil)")
    
    self.selectedFileURL = nil
    self.selectedFileName = nil
    
    if let url = fileURLToSend {
      print("📤 [submitInput] Processing file upload...")
      if let contentToSend = await ChatHistory.shared.handleFileUpload(
        fileURL: url,
        associatedText: textToSend
      ) {
        print("📤 [submitInput] Calling sendMessage with file content...")
        await ChatHistory.shared.sendMessage(
          userText: nil,
          messageContent: contentToSend,
          modelname: modelname,
          selectedPrompt: selectedPrompt,
          streamDelegate: streamDelegate,
          messageID: newMessageID,
          onQueryCompleted: self.queryDidComplete
        )
      } else {
        print("❌ [submitInput] Error processing file upload, message not sent.")
        self.queryDidComplete()
      }
    } else if !textToSend.isEmpty {
      print("📤 [submitInput] Calling sendMessage with text content...")
      await ChatHistory.shared.sendMessage(
        userText: textToSend,
        messageContent: nil,
        modelname: modelname,
        selectedPrompt: selectedPrompt,
        streamDelegate: streamDelegate,
        messageID: newMessageID,
        onQueryCompleted: self.queryDidComplete
      )
      print("📤 [submitInput] sendMessage call completed")
    } else {
      print("⚠️ [submitInput] No content to send")
      self.queryDidComplete()
    }
    print("📤 [submitInput] === END ===")
  }
  
  func queryDidComplete() {
    print("✅ [queryDidComplete] Query completed, setting isQueryActive to false")
    isQueryActive = false
  }
  
  func cancelQuery() {
    print("🛑 [cancelQuery] Cancelling query...")
    streamDelegate.cancelCurrentQuery()
    queryDidComplete()
  }
}

// MARK: - UI Components - Main App

@MainActor
struct App: SwiftUI.App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  @StateObject private var viewModel = ChatViewModel()
  @AppStorage(AppConstants.UserDefaults.modelName) public var modelname = OpenAIConfig.getDefaultModel()
  @AppStorage(AppConstants.UserDefaults.selectedPrompt) private var selectedPrompt: String = ""
  
  // Speech recognition state
  @State private var initialInputText = ""
  @State private var insertionIndex = 0
  
  @FocusState private var focused: Bool

  var body: some Scene {
    WindowGroup {
      VStack(alignment: .leading) {
        HStack {
          ModelMenuView(modelname: $modelname)
          PromptMenuView(selectedPrompt: $selectedPrompt)
          MCPMenuView()

          FileUploadButton(selectedFileName: $viewModel.selectedFileName) { fileURL in
            viewModel.selectedFileURL = fileURL
          }
        }
        .offset(x: 0, y: 5)
        .ignoresSafeArea()
        .frame(maxWidth: .infinity, maxHeight: 0, alignment: .trailing)

        LLMInputView
        Divider()

        if !viewModel.streamDelegate.output.characters.isEmpty {
          LLMOutputView
        } else {
          Spacer(minLength: 20)
        }
      }
      .background(VisualEffect().ignoresSafeArea())
      .frame(minWidth: 400, minHeight: 150, alignment: .topLeading)
      .onReceive(
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification),
        perform: { _ in
          exit(0)
        }
      )
      .onAppear {
        focused = true
        viewModel.modelname = modelname
        viewModel.selectedPrompt = selectedPrompt
      }
      .onChange(of: modelname) { _, newValue in
        viewModel.modelname = newValue
      }
      .onChange(of: selectedPrompt) { _, newValue in
        viewModel.selectedPrompt = newValue
      }
    }
    .windowStyle(HiddenTitleBarWindowStyle())
    .defaultSize(width: 0.5, height: 1.0)
  }
}

// MARK: - App Extensions - Input View

extension App {
  private var LLMInputView: some View {
    HStack {
      Button(action: {
        if viewModel.isQueryActive {
          print("🛑 [Button] User manually stopping query")
          viewModel.cancelQuery()
          viewModel.input = ""
        } else {
          if !viewModel.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            print("▶️ [Button] User starting query")
            Task {
              viewModel.isQueryActive = true
              await viewModel.submitInput()
            }
          } else {
            print("⚠️ [Button] Empty input, not starting query")
          }
        }
      }) {
        // Text(viewModel.isQueryActive ? "\u{1F9CA}" : "\u{1F3B2}")
        Text("\u{1F3B2}")
          .foregroundColor(.white)
          .cornerRadius(5)
      }
      .buttonStyle(PlainButtonStyle())
      .rotationEffect(viewModel.isQueryActive ? .degrees(360) : .degrees(0))
      .animation(
        viewModel.isQueryActive
          ? Animation.linear(duration: 2.0).repeatForever(autoreverses: false) : .default,
        value: viewModel.isQueryActive)

      TextField("write something..", text: $viewModel.input, axis: .vertical)
        .lineLimit(1...5)
        .textFieldStyle(.plain)
        .focused($focused)
        .onSubmit {
          if !viewModel.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            print("⏎ [onSubmit] User submitted input via Enter key")
            Task {
              viewModel.isQueryActive = true
              await viewModel.submitInput()
            }
          } else {
            print("⚠️ [onSubmit] Empty input, not submitting")
          }
        }
        .onChange(of: viewModel.speechManager.transcribedText) { oldValue, newValue in
            print("🔄 [onChange] transcribedText changed from '\(oldValue)' to '\(newValue)'")
            if !newValue.isEmpty {
                print("📝 [onChange] Inserting text at index \(insertionIndex)")
                print("📝 [onChange] Initial text: '\(initialInputText)'")
                // Insert at the captured cursor position
                let prefix = String(initialInputText.prefix(insertionIndex))
                let suffix = String(initialInputText.suffix(initialInputText.count - insertionIndex))
                viewModel.input = prefix + newValue + suffix
                print("📝 [onChange] New input: '\(viewModel.input)'")
                
                // Calculate the new cursor position (after the inserted text)
                let newCursorPosition = insertionIndex + newValue.count
                
                // Use DispatchQueue to defer cursor update until after SwiftUI updates the TextField
                DispatchQueue.main.async {
                    // Access the underlying NSTextView to set cursor position
                    if let window = NSApplication.shared.keyWindow,
                       let textView = window.firstResponder as? NSTextView {
                        // Set the selected range to position cursor after the inserted text
                        // selectedRange is an NSRange with location and length
                        // For a cursor position (no selection), length = 0
                        let range = NSRange(location: min(newCursorPosition, self.viewModel.input.count), length: 0)
                        textView.setSelectedRange(range)
                        print("📍 Cursor positioned at: \(newCursorPosition)")
                    }
                }
            }
        }
    }
    .padding(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
    .onReceive(NotificationCenter.default.publisher(for: .rightOptionKeyDown)) { notification in
        print("🎤 Right Option key down detected")
        guard notification.userInfo?["isLongPress"] != nil else { return }
        if !viewModel.speechManager.isRecording {
            print("🎤 Starting recording")
            
            // Capture current input and cursor position
            initialInputText = viewModel.input
            
            // Try to get cursor position from the underlying NSTextView
            if let window = NSApplication.shared.keyWindow,
               let textView = window.firstResponder as? NSTextView {
                // Use the selected range's location
                // Note: This is an NSRange location (UTF-16 code units)
                // We need to be careful mapping this to Swift String index if there are emojis
                // For simplicity, we'll clamp it to the string count
                let range = textView.selectedRange()
                // Convert NSRange location to String index offset safely
                // This is a simplification; for complex emojis it might need more robust handling
                // but for a basic implementation it usually works fine as long as we don't split graphemes
                insertionIndex = min(max(0, range.location), viewModel.input.count)
            } else {
                // Fallback to appending
                insertionIndex = viewModel.input.count
            }
            
            print("📍 Insertion index: \(insertionIndex)")
            viewModel.speechManager.startRecording()
        }
    }
    .onReceive(NotificationCenter.default.publisher(for: .rightOptionKeyUp)) { _ in
        print("🎤 Right Option key up detected")
        Task { @MainActor in
            if viewModel.speechManager.isRecording {
                print("🎤 Stopping recording")
                viewModel.speechManager.stopRecording()
            }
        }
    }
  }
}

// MARK: - App Extensions - Output View

extension App {
  private var LLMOutputView: some View {
    ScrollView {
      Text(viewModel.streamDelegate.output)
        .lineLimit(nil)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 10)
        .lineSpacing(5)
    }
    .defaultScrollAnchor(.bottom)
  }
}

// MARK: - UI Components - Reusable Components

struct PopoverSelectorRow<Content: View>: View {
  let label: () -> Content
  let isSelected: Bool
  let onTap: () -> Void
  @State private var isHovering = false
  var body: some View {
    Button(action: onTap) {
      label()
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          Group {
            if isSelected {
              Color.accentColor.opacity(0.18)
            } else if isHovering {
              Color.primary.opacity(0.07)
            } else {
              Color.clear
            }
          }
        )
        .cornerRadius(6)
    }
    .buttonStyle(PlainButtonStyle())
    .onHover { hover in
      isHovering = hover
    }
  }
}

struct PopoverSelector<T: Hashable & CustomStringConvertible>: View {
  @Binding var selection: T
  let options: [T]
  let label: () -> AnyView
  @State private var showPopover = false

  var body: some View {
    Button(action: { showPopover.toggle() }) {
      label()
    }
    .buttonStyle(PlainButtonStyle())
    .popover(isPresented: $showPopover) {
      ScrollView {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(options, id: \.self) { option in
            PopoverSelectorRow(
              label: {
                AnyView(
                  HStack {
                    Text(option.description).font(.system(size: 12))
                      .foregroundColor(selection == option ? .accentColor : .primary)
                    Spacer()
                    if selection == option {
                      Image(systemName: "checkmark")
                        .foregroundColor(.accentColor)
                    }
                  }
                )
              },
              isSelected: selection == option,
              onTap: {
                selection = option
                showPopover = false
              }
            )
          }
        }
        .padding(10)
      }
    }
  }
}

// MARK: - UI Components - Menu Views

struct ModelMenuView: View {
  @Binding public var modelname: String
  @State private var modelProviderMap: [(model: String, provider: String, fullName: String)]
  @State private var showPopover = false
  
  init(modelname: Binding<String>) {
    self._modelname = modelname
    
    // Load models synchronously during initialization
    let config = OpenAIConfig.load()
    var tempMap: [(model: String, provider: String, fullName: String)] = []
    
    print("🔍 Loading models from config. Providers found: \(config.models.keys.joined(separator: ", "))")
    
    for (providerKey, modelConfig) in config.models {
      print("  Provider '\(providerKey)' has \(modelConfig.models.count) models")
      for model in modelConfig.models {
        let fullName = "\(model)@\(providerKey)"
        tempMap.append((model: model, provider: providerKey, fullName: fullName))
      }
    }
    
    self._modelProviderMap = State(initialValue: tempMap.sorted { $0.model < $1.model })
    print("✅ Loaded \(tempMap.count) models total in init()")
  }
  
  var body: some View {
    Button(action: { showPopover.toggle() }) {
      HStack(spacing: 6) {
        Text("\u{1F9E0}").font(.system(size: 14))
        // Display only the model name part (without @provider)
        let displayName = modelname.components(separatedBy: "@").first ?? modelname
        Text(displayName).font(.system(size: 12)).foregroundColor(.primary)
      }
      .padding(.horizontal, 2)
    }
    .buttonStyle(PlainButtonStyle())
    .popover(isPresented: $showPopover) {
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(modelProviderMap, id: \.fullName) { item in
            Button(action: {
              modelname = item.fullName
              showPopover = false
            }) {
              HStack {
                Text(item.model).font(.system(size: 12))
                  .foregroundColor(modelname == item.fullName ? .accentColor : .primary)
                Spacer()
                Text(item.provider)
                  .font(.system(size: 10))
                  .foregroundColor(.secondary)
                if modelname == item.fullName {
                  Image(systemName: "checkmark")
                    .foregroundColor(.accentColor)
                    .padding(.leading, 4)
                }
              }
              .padding(.vertical, 6).padding(.horizontal, 10)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(modelname == item.fullName ? Color.accentColor.opacity(0.18) : Color.clear)
              .cornerRadius(6)
            }
            .buttonStyle(PlainButtonStyle())
          }
        }
        .padding(10)
      }
      .frame(minWidth: 250, maxHeight: 500)
    }
  }
}

struct PromptMenuView: View {
  @Binding var selectedPrompt: String
  @State private var prompts: [String] = ["None"]

  var body: some View {
    PopoverSelector(
      selection: $selectedPrompt, options: prompts,
      label: {
        AnyView(
          HStack(spacing: 6) {
            Text("📄").font(.system(size: 14))
            if selectedPrompt != "None" {
              Text(selectedPrompt).font(.system(size: 12)).foregroundColor(.primary)
            }
          }
          .padding(.horizontal, 2)
        )
      }
    )
    .frame(alignment: .trailing)
    .task {
      let availablePrompts = await ChatHistory.shared.getAvailablePrompts()
      prompts = ["None"] + availablePrompts
      if !prompts.contains(selectedPrompt) {
        selectedPrompt = "None"
      }
    }
  }
}

struct MCPMenuView: View {
  @State private var mcpServers: [String: MCPServer] = [:]
  @State private var activeMCPServers: Set<String> = []
  @State private var showPopover = false

  init() {
    // Initialize state immediately from MCPManager
    let manager = MCPManager.shared
    _mcpServers = State(initialValue: manager.getMCPServers())
    _activeMCPServers = State(initialValue: manager.getActiveMCPServers())
  }

  var body: some View {
    Button(action: {
      showPopover.toggle()
    }) {
      HStack(spacing: 6) {
        Text("🔧").font(.system(size: 12))
        if !activeMCPServers.isEmpty {
          Text("\(activeMCPServers.count)").font(.system(size: 10)).foregroundColor(.accentColor)
        }
      }
      .padding(.horizontal, 2)
    }
    .buttonStyle(PlainButtonStyle())
    .popover(isPresented: $showPopover, arrowEdge: .bottom) {
      VStack(alignment: .leading, spacing: 0) {
        Text("MCP Servers")
          .font(.headline)
          .padding(.horizontal, 10)
          .padding(.top, 10)

        if mcpServers.isEmpty {
          Text("No MCP servers configured")
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        } else {
          ForEach(Array(mcpServers.keys.sorted()), id: \.self) { serverName in
            let server = mcpServers[serverName]!
            MCPServerRow(
              serverName: serverName,
              server: server,
              isActive: activeMCPServers.contains(serverName),
              onToggle: { isActive in
                Task { @MainActor in
                  MCPManager.shared.setServerActive(serverName, active: isActive)
                  mcpServers = MCPManager.shared.getMCPServers()
                  activeMCPServers = MCPManager.shared.getActiveMCPServers()
                }
              }
            )
          }
        }
      }
      .padding(.bottom, 10)
      .frame(width: 250)
    }
  }
}

struct MCPServerRow: View {
  let serverName: String
  let server: MCPServer
  @State var isActive: Bool
  let onToggle: (Bool) -> Void

  var body: some View {
    HStack {
      Toggle("", isOn: $isActive)
        .labelsHidden()
        .toggleStyle(CheckboxToggleStyle())
        .onChange(of: isActive) { _, newValue in
          onToggle(newValue)
        }

      VStack(alignment: .leading, spacing: 2) {
        HStack {
          Text(serverName)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.primary)

          if server.isRemote {
            Text("🌐")
              .font(.system(size: 10))
              .foregroundColor(.blue)
          } else {
            Text("💻")
              .font(.system(size: 10))
              .foregroundColor(.green)
          }
        }

        if let description = server.description {
          Text(description)
            .font(.system(size: 10))
            .foregroundColor(.secondary)
            .lineLimit(1)
        } else if let url = server.url {
          Text(url)
            .font(.system(size: 10))
            .foregroundColor(.secondary)
            .lineLimit(1)
        } else if let command = server.command {
          Text(command)
            .font(.system(size: 10))
            .foregroundColor(.secondary)
            .lineLimit(1)
        }
      }

      Spacer()
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 4)
  }
}

struct CheckboxToggleStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    Button(action: {
      configuration.isOn.toggle()
    }) {
      HStack {
        Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
          .foregroundColor(configuration.isOn ? .accentColor : .secondary)
          .font(.system(size: 14))
        configuration.label
      }
    }
    .buttonStyle(PlainButtonStyle())
  }
}

// MARK: - UI Components - Utility Views

struct FileUploadButton: View {
  @Binding var selectedFileName: String?
  @State private var isFilePickerPresented = false
  let onFileSelected: (URL) -> Void

  var body: some View {
    HStack(spacing: 4) {
      Button(action: {
        isFilePickerPresented = true
      }) {
        Text("\u{1F4CE}")
          .font(.system(size: 12))
          .padding(.horizontal, 2)
      }
      .buttonStyle(PlainButtonStyle())
      .frame(height: 10, alignment: .trailing)
      if let fileName = selectedFileName {
        Text(fileName + " ✕")
          .font(.system(size: 11))
          .foregroundColor(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .onTapGesture {
            selectedFileName = nil
          }
      }
    }
    .padding(.trailing, 4)
    .fileImporter(
      isPresented: $isFilePickerPresented,
      allowedContentTypes: [.image],
      allowsMultipleSelection: false
    ) { result in
      switch result {
      case .success(let files):
        if let file = files.first {
          selectedFileName = file.lastPathComponent
          onFileSelected(file)
        } else {
          selectedFileName = nil
        }
      case .failure(let error):
        print("Error selecting file: \(error.localizedDescription)")
        selectedFileName = nil
      }
    }
  }
}

// MARK: - Application Setup

DispatchQueue.main.async {
  NSApplication.shared.setActivationPolicy(.accessory)
  NSApplication.shared.activate(ignoringOtherApps: true)
  if let window = NSApplication.shared.windows.first {
    window.level = .floating
    window.standardWindowButton(.closeButton)?.isHidden = true
    window.standardWindowButton(.miniaturizeButton)?.isHidden = true
    window.standardWindowButton(.zoomButton)?.isHidden = true
  }
}

// MARK: - Configuration Models

struct ModelConfig: Codable {
  let baseURL: String?
  let apiKey: String?
  let models: [String]
  let proxyEnabled: Bool?
  let proxyURL: String?
}

struct OpenAIConfig: Codable, ConfigLoadable {
  let models: [String: ModelConfig]
  let legacy: [String: ModelConfig]?
  let defaultModel: String
  
  // Only get models from the main models section, ignore legacy
  var allModels: [String] {
    return models.values.flatMap { $0.models }.sorted()
  }

  static var configPath: URL {
    return FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".config")
      .appendingPathComponent(AppConstants.configDirectoryName)
      .appendingPathComponent(AppConstants.mainConfigFileName)
  }

  static func load() -> OpenAIConfig {
    do {
      let config = try loadConfig(OpenAIConfig.self)

      if config.getConfig(for: config.defaultModel) == nil {
        print("Warning: Default model '\(config.defaultModel)' not found in config. Falling back.")
        let fallbackModel = config.allModels.first ?? AppConstants.DefaultModels.openAI
        print("Using fallback model: \(fallbackModel)")
        return OpenAIConfig(models: config.models, legacy: config.legacy, defaultModel: fallbackModel)
      }
      return config

    } catch {
      print("Error loading config: \(error). Using default configuration.")
      let defaultModels = [
        "default": ModelConfig(
          baseURL: "https://api.openai.com/v1", apiKey: "YOUR_API_KEY",
          models: [AppConstants.DefaultModels.openAI, "gpt-3.5-turbo"], proxyEnabled: false, proxyURL: nil)
      ]
      return OpenAIConfig(models: defaultModels, legacy: nil, defaultModel: AppConstants.DefaultModels.openAI)
    }
  }

  func getConfig(for model: String) -> ModelConfig? {
    print("🔍 [getConfig] Looking up config for model: '\(model)'")
    
    // Handle model@provider format
    let components = model.split(separator: "@")
    let modelName = String(components.first ?? "")
    let providerName = components.count > 1 ? String(components.last!) : nil
    
    print("🔍 [getConfig] Parsed - model: '\(modelName)', provider: '\(providerName ?? "nil")'")
    
    // If provider is specified, look in that provider's config
    if let provider = providerName, let config = models[provider] {
      print("🔍 [getConfig] Found provider '\(provider)' config with models: \(config.models)")
      if config.models.contains(modelName) {
        print("✅ [getConfig] Found model '\(modelName)' in provider '\(provider)'")
        return config
      }
    }
    
    // Fallback: search all providers for the full model string or just model name
    print("🔍 [getConfig] Searching all providers...")
    for (providerKey, config) in models {
      print("🔍 [getConfig] Checking provider '\(providerKey)': \(config.models)")
      if config.models.contains(model) || config.models.contains(modelName) {
        print("✅ [getConfig] Found model in provider '\(providerKey)'")
        return config
      }
    }
    
    print("❌ [getConfig] Configuration for model '\(model)' not found in any provider.")
    return nil
  }
}

// MARK: - Application Entry Point

App.main()
