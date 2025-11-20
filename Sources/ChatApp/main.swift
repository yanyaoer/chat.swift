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
            Logger.app("AppDelegate").warning("Accessibility permission required for global key monitoring")
            Logger.app("AppDelegate").warning("Please enable in System Settings > Privacy & Security > Accessibility")
        } else {
            Logger.app("AppDelegate").success("Accessibility permission granted")
        }

        // Don't request permissions at startup - let them be requested when user first tries to record
        Logger.app("AppDelegate").info("Permissions will be requested when you first use recording feature")

        Logger.app("AppDelegate").info("Setting up event monitors for right Option key (keyCode: \(rightOptionKeyCode))")
        
        // Use local event monitor to catch events when app has focus
        NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { event in
            Logger.input("EventMonitor").debug("Flags changed: keyCode=\(event.keyCode), modifierFlags=\(event.modifierFlags.rawValue)")
            if event.keyCode == self.rightOptionKeyCode {
                let isPressed = event.modifierFlags.contains(.option)
                Logger.input("EventMonitor").success("Right Option key \(isPressed ? "pressed" : "released")")
                
                if isPressed {
                    if !self.isRightOptionDown {
                        self.isRightOptionDown = true
                        Logger.input("EventMonitor").info("Posting rightOptionKeyDown notification (short press)")
                        NotificationCenter.default.post(name: .rightOptionKeyDown, object: nil, userInfo: ["isLongPress": false])
                        self.keyDownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { _ in
                            Logger.input("EventMonitor").info("Posting rightOptionKeyDown notification (long press)")
                            NotificationCenter.default.post(name: .rightOptionKeyDown, object: nil, userInfo: ["isLongPress": true])
                        }
                    }
                } else {
                    if self.isRightOptionDown {
                        self.isRightOptionDown = false
                        self.keyDownTimer?.invalidate()
                        Logger.input("EventMonitor").info("Posting rightOptionKeyUp notification")
                        NotificationCenter.default.post(name: .rightOptionKeyUp, object: nil)
                    }
                }
            }
            return event
        }
        
        // Also use global monitor for when app doesn't have focus
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { event in
            Logger.input("GlobalEventMonitor").debug("Global flags changed: keyCode=\(event.keyCode)")
            if event.keyCode == self.rightOptionKeyCode {
                let isPressed = event.modifierFlags.contains(.option)
                Logger.input("GlobalEventMonitor").success("Right Option key \(isPressed ? "pressed" : "released") (global)")
                
                if isPressed {
                    if !self.isRightOptionDown {
                        self.isRightOptionDown = true
                        Logger.input("GlobalEventMonitor").info("Posting rightOptionKeyDown notification (short press)")
                        NotificationCenter.default.post(name: .rightOptionKeyDown, object: nil, userInfo: ["isLongPress": false])
                        self.keyDownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { _ in
                            Logger.input("GlobalEventMonitor").info("Posting rightOptionKeyDown notification (long press)")
                            NotificationCenter.default.post(name: .rightOptionKeyDown, object: nil, userInfo: ["isLongPress": true])
                        }
                    }
                } else {
                    if self.isRightOptionDown {
                        self.isRightOptionDown = false
                        self.keyDownTimer?.invalidate()
                        Logger.input("GlobalEventMonitor").info("Posting rightOptionKeyUp notification")
                        NotificationCenter.default.post(name: .rightOptionKeyUp, object: nil)
                    }
                }
            }
        }
        
        if eventMonitor == nil {
            Logger.app("AppDelegate").error("Failed to create global event monitor")
        } else {
            Logger.app("AppDelegate").success("Event monitors created successfully")
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
  static let mcpConfigFileName = "mcp.json"
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

// MARK: - Configuration Extensions

extension OpenAIConfig {
  static let safeDefaultModel = AppConstants.DefaultModels.openAI
  
  static func getDefaultModel() -> String {
    do {
      let config = try loadConfig(OpenAIConfig.self)
      return config.defaultModel
    } catch {
      Logger.config("OpenAIConfig").warning("Could not load config for default model, using safe fallback")
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
      Logger.tool("ToolParser").warning("Could not extract tool name from: \(content.prefix(100))")
      return nil
    }
    
    Logger.tool("ToolParser").debug("Extracted tool name: \(toolName)")
    
    // Extract parameters within tool content
    var parameters: [String: String] = [:]
    
    // Find content within the tool tag first
    let toolTagPattern = "<\(toolName)>(.*?)</\(toolName)>"
    if let regex = try? NSRegularExpression(pattern: toolTagPattern, options: [.dotMatchesLineSeparators]),
       let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..<content.endIndex, in: content)),
       match.numberOfRanges >= 2,
       let toolContentRange = Range(match.range(at: 1), in: content) {
      
      let toolContent = String(content[toolContentRange])
      Logger.tool("ToolParser").debug("Tool content: \(toolContent)")
      
      // Parse individual parameters
      if let paramRegex = try? NSRegularExpression(pattern: parameterPattern, options: [.dotMatchesLineSeparators]) {
        paramRegex.enumerateMatches(in: toolContent, range: NSRange(toolContent.startIndex..<toolContent.endIndex, in: toolContent)) { match, _, _ in
          guard let match = match, match.numberOfRanges >= 3,
                let nameRange = Range(match.range(at: 1), in: toolContent),
                let valueRange = Range(match.range(at: 2), in: toolContent) else { return }
          
          let name = String(toolContent[nameRange])
          let value = String(toolContent[valueRange])
          parameters[name] = value
          Logger.tool("ToolParser").debug("Found parameter: \(name) = \(value)")
        }
      }
    } else {
      Logger.tool("ToolParser").warning("Could not find tool content for tag: \(toolName)")
    }
    
    Logger.tool("ToolParser").debug("Final params: \(parameters)")
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
      Logger.stream("parseSSELine").error("Error parsing JSON line: \(jsonString), Error: \(error)")
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
      Logger.app("ChatHistory").warning("Unsupported file type: \(fileType)")
      return nil
    }

    guard fileURL.startAccessingSecurityScopedResource() else {
      Logger.app("ChatHistory").error("Failed to access the file at \(fileURL.path)")
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
        Logger.app("ChatHistory").error("No content items created for file upload")
        return nil
      }
      return .multimodal(contentItems)

    } catch {
      Logger.app("ChatHistory").error("Error reading or encoding file: \(error.localizedDescription)")
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
    onQueryCompleted: @escaping @Sendable () -> Void
  ) async {
    Logger.network("sendMessage").info("=== START ===")
    Logger.network("sendMessage").info("Message ID: \(messageID)")
    Logger.network("sendMessage").info("Model: \(modelname)")
    Logger.network("sendMessage").info("User text: \(userText ?? "nil")")
    Logger.network("sendMessage").info("Has message content: \(messageContent != nil)")
    
    let config = OpenAIConfig.load()
    guard let modelConfig = config.getConfig(for: modelname),
          let baseURL = modelConfig.baseURL,
          let apiKey = modelConfig.apiKey else {
      Logger.network("sendMessage").error("Model configuration not found or incomplete for \(modelname)")
      onQueryCompleted()
      return
    }

    Logger.network("sendMessage").info("Base URL: \(baseURL)")
    Logger.network("sendMessage").info("API Key: \(apiKey.prefix(10))...")
    
    let url = URL(string: "\(baseURL)/chat/completions")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    
    // Add custom headers from config
    if let customHeaders = modelConfig.headers {
      for (key, value) in customHeaders {
        request.setValue(value, forHTTPHeaderField: key)
        Logger.network("sendMessage").debug("Adding custom header: \(key) = \(value)")
      }
    }

    var messagesToSend: [ChatMessage] = []

    if !selectedPrompt.isEmpty, selectedPrompt != "None",
      let prompt = loadPromptContent(name: selectedPrompt)
    {
      let systemMessage = ChatMessage(role: prompt.role, content: .text(prompt.content), model: nil)
      messagesToSend.append(systemMessage)
    }

    // Detect @mentions in the user message or system prompt
    var mentionedServers: Set<String> = []
    
    // Helper to extract mentions
    func extractMentions(from text: String) -> Set<String> {
        var servers: Set<String> = []
        let words = text.components(separatedBy: .whitespacesAndNewlines)
        for word in words {
            if word.hasPrefix("@") {
                let serverName = String(word.dropFirst())
                // Check against ALL configured servers
                if MCPManager.shared.getMCPServers().keys.contains(serverName) {
                    servers.insert(serverName)
                }
            }
        }
        return servers
    }
    
    if let text = userText {
        mentionedServers.formUnion(extractMentions(from: text))
    }
    
    // Also check selected prompt content if any
    if !selectedPrompt.isEmpty, selectedPrompt != "None",
       let prompt = loadPromptContent(name: selectedPrompt) {
         mentionedServers.formUnion(extractMentions(from: prompt.content))
    }

    // Inject tools for mentioned servers
    if !mentionedServers.isEmpty {
        var allTools: [ToolDefinition] = []
        for server in mentionedServers {
            if let tools = await MCPToolCache.shared.getTools(for: server) {
                allTools.append(contentsOf: tools)
            } else {
                // Try to fetch if missing (auto-fetch strategy)
                await MCPManager.shared.refreshTools(for: server)
                if let tools = await MCPToolCache.shared.getTools(for: server) {
                    allTools.append(contentsOf: tools)
                }
            }
        }
        
        if !allTools.isEmpty {
            // Convert tools to XML format for the LLM
            var toolsXML = "<tools>\n"
            for tool in allTools {
                toolsXML += "<tool_definition>\n"
                toolsXML += "<name>\(tool.name)</name>\n"
                if let desc = tool.description {
                    toolsXML += "<description>\(desc)</description>\n"
                }
                // Simplified schema representation for now. 
                // Ideally we should serialize inputSchema to JSON/XML
                if let schema = tool.inputSchema {
                    // Quick and dirty JSON serialization of schema
                    if let jsonData = try? JSONEncoder().encode(schema),
                       let jsonString = String(data: jsonData, encoding: .utf8) {
                        toolsXML += "<parameters>\n\(jsonString)\n</parameters>\n"
                    }
                }
                toolsXML += "</tool_definition>\n"
            }
            toolsXML += "</tools>\n"
            
            let mcpInstructions = """
            You have access to the following MCP tools from the servers: \(mentionedServers.joined(separator: ", ")).
            
            \(toolsXML)
            
            To use a tool, please use the following XML format:
            <tool_use>
            <mcp_call>
            <server>server_name</server>
            <tool>tool_name</tool>
            <actual_param_name_1>value1</actual_param_name_1>
            <actual_param_name_2>value2</actual_param_name_2>
            </mcp_call>
            </tool_use>
            
            IMPORTANT: Use the actual parameter names from the tool's parameters schema, not generic names like "param1" or "param2".
            For example, if a tool expects a "city" parameter, use <city>Beijing</city>, not <param1>Beijing</param1>.
            
            When you use a tool, the system will execute it and provide the result.
            """
            
            let mcpSystemMessage = ChatMessage(role: "system", content: .text(mcpInstructions), model: nil)
            messagesToSend.append(mcpSystemMessage)
        }
    }

    let finalContent: MessageContent
    if let content = messageContent {
      finalContent = content
    } else if let text = userText, !text.isEmpty {
      finalContent = .text(text)
    } else {
      Logger.network("sendMessage").error("No message content to send")
      onQueryCompleted()
      return
    }

    let userMessage = ChatMessage(
      role: "user", content: finalContent, model: modelname, id: messageID)
    messagesToSend.append(userMessage)
      messagesToSend.append(userMessage)
    saveMessage(userMessage)

    // Extract pure model name without @provider suffix for API request
    let pureModelName = modelname.split(separator: "@").first.map(String.init) ?? modelname
    Logger.network("sendMessage").info("Using pure model name for API: '\(pureModelName)' (from '\(modelname)')")
    
    let chatRequest = ChatRequest(
      model: pureModelName, messages: messagesToSend, stream: true
    )

    Logger.network("sendMessage").info("Preparing request with \(messagesToSend.count) messages")
    
    do {
      let encoder = JSONEncoder()
      request.httpBody = try encoder.encode(chatRequest)
      
      // Log full request body
      if let jsonData = try? encoder.encode(chatRequest),
         let jsonString = String(data: jsonData, encoding: .utf8) {
          Logger.network("sendMessage").debug("Full Request Body:\n\(jsonString)")
      }

      if let httpBody = request.httpBody, let bodyString = String(data: httpBody, encoding: .utf8) {
        Logger.network("sendMessage").debug("Request body preview: \(bodyString.prefix(200))...")
      }
    } catch {
      Logger.network("sendMessage").error("Error encoding request: \(error)")
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
        Logger.network("sendMessage").warning("Unsupported proxy scheme: \(scheme ?? "nil"). Proxy not configured")
      }
    }

    Logger.network("sendMessage").info("Setting up stream delegate...")
    streamDelegate.output = AttributedString("")
    streamDelegate.setModel(modelname)
    streamDelegate.currentMessageID = messageID
    streamDelegate.setQueryCompletionCallback(onQueryCompleted)

    Logger.network("sendMessage").info("Creating URLSession and starting task...")
    let session = URLSession(
      configuration: sessionConfig, delegate: streamDelegate, delegateQueue: nil)
    let task = session.dataTask(with: request)
    streamDelegate.currentTask = task
    task.resume()
    Logger.network("sendMessage").info("Task resumed, waiting for response...")
    Logger.network("sendMessage").info("=== END ===")
  }
}

// MARK: - Network Layer

class StreamDelegate: NSObject, URLSessionDataDelegate, ObservableObject, @unchecked Sendable
{
  @Published var output: AttributedString = ""
  private var currentResponse: String = ""
  private var currentModel: String = ""
  private var isCurrentlyReasoning: Bool = false
  private var pendingMCPCall: String = ""
  private var dataBuffer: String = ""  // Buffer for incomplete streaming data
  var currentTask: URLSessionDataTask?
  var currentMessageID: String?
  var onQueryCompleted: (@Sendable () -> Void)?
  var isHandlingDone: Bool = false

  override init() {
    super.init()
  }

  // Hooks for subclasses (e.g. CLI mode)
  func onStreamContent(_ content: String, isReasoning: Bool) {}
  func onStreamError(_ error: String) {}
  func onStreamComplete() {}

  func cancelCurrentQuery() {
    Logger.stream("cancelCurrentQuery").info("Cancelling query...")
    currentTask?.cancel()
    DispatchQueue.main.async {
      self.output = AttributedString("")
      self.currentResponse = ""
      self.isCurrentlyReasoning = false
      self.pendingMCPCall = ""
      self.dataBuffer = ""
      self.isHandlingDone = false
      self.onQueryCompleted?()
      self.onStreamComplete()
    }
    self.currentTask = nil
    self.currentMessageID = nil
    Logger.stream("cancelCurrentQuery").success("Query cancelled and StreamDelegate state reset")
  }

  func setQueryCompletionCallback(_ callback: @escaping @Sendable () -> Void) {
    self.onQueryCompleted = callback
  }

  func setModel(_ model: String) {
    currentModel = model
  }

  private func detectAndExecuteMCPCall(_ text: String) async -> Bool {
    Logger.tool("detectAndExecuteMCPCall").debug("Checking text of length \(text.count)")
    Logger.tool("detectAndExecuteMCPCall").debug("Text preview: \(text.suffix(200))")
    let toolCalls = ToolParser.extractToolCalls(from: text)
    Logger.tool("detectAndExecuteMCPCall").info("Found \(toolCalls.count) tool calls in text")
    
    var didExecute = false
    
    for call in toolCalls {
      Logger.tool("detectAndExecuteMCPCall").debug("Tool: \(call.toolName), Complete: \(call.isComplete), Params: \(call.parameters)")
      if call.isComplete && call.toolName == "mcp_call" {
        Logger.tool("detectAndExecuteMCPCall").success("Executing MCP tool")
        let result = await executeMCPTool(call)
        
        // Send result back to LLM
        switch result {
        case .success(let output):
            let formatted = formatResult(output)
            let toolResultMessage = """
            Tool execution result:
            \(formatted)
            """
            Logger.tool("detectAndExecuteMCPCall").info("Sending tool result back to LLM")
            
            // We need to call sendMessage again with the tool result
            // This creates a multi-turn conversation: User -> Assistant (Tool) -> User (Result) -> Assistant (Answer)
            if self.currentMessageID != nil {
                await ChatHistory.shared.sendMessage(
                    userText: toolResultMessage,
                    messageContent: nil,
                    modelname: self.currentModel.isEmpty ? OpenAIConfig.getDefaultModel() : self.currentModel,
                    selectedPrompt: "", // Don't re-apply prompt
                    streamDelegate: self, // Reuse delegate
                    messageID: UUID().uuidString, // New ID for the new turn
                    onQueryCompleted: self.onQueryCompleted ?? {} // Pass original completion handler
                )
                didExecute = true
            }
            
        case .failure(let error):
            let errorMessage = "Tool execution failed: \(error.localizedDescription)"
            Logger.tool("detectAndExecuteMCPCall").error("Sending error back to LLM")
            
            if self.currentMessageID != nil {
                await ChatHistory.shared.sendMessage(
                    userText: errorMessage,
                    messageContent: nil,
                    modelname: self.currentModel.isEmpty ? OpenAIConfig.getDefaultModel() : self.currentModel,
                    selectedPrompt: "",
                    streamDelegate: self,
                    messageID: UUID().uuidString,
                    onQueryCompleted: self.onQueryCompleted ?? {}
                )
                didExecute = true
            }
        }
      } else if !call.isComplete {
        Logger.tool("detectAndExecuteMCPCall").info("Tool call incomplete, waiting for more data")
      }
    }
    return didExecute
  }
  
  private func executeMCPTool(_ call: ToolCall) async -> Result<String, AppError> {
    guard let server = call.parameters["server"],
          let tool = call.parameters["tool"] else { 
      Logger.tool("executeMCPTool").error("Missing server or tool parameter")
      return .failure(.mcpError("Missing server or tool parameter")) 
    }
    
    Logger.tool("executeMCPTool").info("Server: \(server), Tool: \(tool)")
    Logger.tool("executeMCPTool").debug("All parameters (raw): \(call.parameters)")
    Logger.tool("executeMCPTool").debug("Number of parameters: \(call.parameters.count)")
    
    // Parse parameters - handle both direct params and JSON-wrapped params
    var args: [String: Any] = [:]
    
    // First, check if there's a single param that contains a JSON object
    // This handles cases like <param1>{"city":"北京"}</param1>
    let nonMetaParams = call.parameters.filter { !["server", "tool"].contains($0.key) }
    
    Logger.tool("executeMCPTool").debug("Non-meta params count: \(nonMetaParams.count)")
    Logger.tool("executeMCPTool").debug("Non-meta params: \(nonMetaParams)")
    
    if nonMetaParams.count == 1,
       let (paramKey, value) = nonMetaParams.first,
       let data = value.data(using: .utf8),
       let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      // Single parameter contains a JSON object - use it directly as arguments
      args = jsonObject
      Logger.tool("executeMCPTool").info("Unwrapped JSON object from parameter '\(paramKey)': \(args)")
    } else {
      // Multiple parameters or non-JSON - parse each individually
      Logger.tool("executeMCPTool").info("Processing \(nonMetaParams.count) parameters individually")
      for (key, value) in nonMetaParams {
        Logger.tool("executeMCPTool").debug("Processing param: \(key) = '\(value)'")
        // Try to parse as JSON first
        if let data = value.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) {
          args[key] = json
          Logger.tool("executeMCPTool").debug("Parsed \(key) as JSON: \(json)")
        } else {
          // Use as string if not valid JSON
          args[key] = value
          Logger.tool("executeMCPTool").debug("Using \(key) as string: '\(value)'")
        }
      }
    }
    
    Logger.tool("executeMCPTool").info("Final arguments dictionary to pass to MCP: \(args)")
    Logger.tool("executeMCPTool").debug("Arguments keys: \(args.keys.sorted())")
    for (k, v) in args {
      Logger.tool("executeMCPTool").debug("  \(k): '\(v)' (type: \(type(of: v)))")
    }
    
    let argsDisplay = args.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
    let argsInfo = argsDisplay.isEmpty ? "" : "参数:\n\(argsDisplay)\n"
    
    Logger.tool("executeMCPTool").info("Calling updateUI with 'executing' message")
    await updateUI("🔧 执行 MCP 工具", "服务器: \(server)\n工具: \(tool)\n\(argsInfo)\n执行中...")
    
    Logger.tool("executeMCPTool").info("Calling MCPManager.callMCPTool with args: \(args), bypassing active check")
    // Bypass active check when calling from mention - allow any configured server
    let result = await MCPManager.shared.callMCPTool(serverName: server, toolName: tool, arguments: args, bypassActiveCheck: true)
    
    Logger.tool("executeMCPTool").debug("Got result: \(result)")
    
    switch result {
    case .success(let output):
        Logger.tool("executeMCPTool").success("Success! Output length: \(output.count)")
        let formatted = formatResult(output)
        Logger.tool("executeMCPTool").debug("Formatted output length: \(formatted.count)")
        await updateUI("📋 工具结果", "```\n\(formatted)\n```")
        Logger.tool("executeMCPTool").success("UI updated with result")
        return .success(output)
    case .failure(let error):
        Logger.tool("executeMCPTool").error("Failure: \(error.localizedDescription)")
        await updateUI("❌ 工具执行失败", error.localizedDescription)
        Logger.tool("executeMCPTool").error("UI updated with error")
        return .failure(error)
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
    Logger.stream("didReceive").debug("Received \(data.count) bytes, Message ID: \(msgID)")
    
    guard currentTask == dataTask, currentMessageID != nil else {
      Logger.stream("didReceive").warning("Ignoring data - task mismatch or no message ID")
      return
    }

    if let text = String(data: data, encoding: .utf8) {
      Logger.stream("didReceive").debug("Data text preview: \(text.prefix(100))...")
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
    var isDone = false
    var accumulatedContent = ""  // Accumulate content locally to avoid async issues
    var accumulatedOutput: [AttributedString] = []  // Accumulate UI updates
    
    // First pass: process all content chunks
    for line in lines {
      Logger.stream("processLines").debug("Processing line: \(line.prefix(100))...")
      
      // Check for [DONE] marker but don't process it yet
      if line.contains("data: [DONE]") {
        Logger.stream("processLines").success("Found [DONE] marker, will process after all content")
        isDone = true
        self.isHandlingDone = true
        continue
      }

      // Use StreamProcessor to parse SSE line
      guard let chunk = StreamProcessor.parseSSELine(line) else {
        continue
      }
      
      Logger.stream("processLines").debug("Got content chunk (\(chunk.isReasoning ? "reasoning" : "normal")): \(chunk.content)")
      
      // Accumulate content locally FIRST
      var chunkToAppend = chunk.content
      
      // Handle transition from reasoning to normal content
      if !chunk.isReasoning && self.isCurrentlyReasoning {
        chunkToAppend = "\n" + chunkToAppend
        self.isCurrentlyReasoning = false
      }

      if chunk.isReasoning {
        self.isCurrentlyReasoning = true
      }
      
      accumulatedContent += chunkToAppend
      
      // Prepare attributed string for UI
      var attributedChunk: AttributedString
      let containsToolUse = chunkToAppend.contains("<tool_use>") || chunkToAppend.contains("</tool_use>") || 
                             chunkToAppend.contains("<mcp_call>") || chunkToAppend.contains("</mcp_call>")
      
      if containsToolUse {
        // Apply "think" style (secondary color) to tool use content
        attributedChunk = AttributedString(chunkToAppend)
        attributedChunk.foregroundColor = .secondary
      } else {
        // Normal content
        attributedChunk = AttributedString(chunkToAppend)
        if chunk.isReasoning {
          attributedChunk.foregroundColor = .secondary
        }
      }
      
      accumulatedOutput.append(attributedChunk)
    }
    
    // Update UI synchronously on main thread with all accumulated content
    DispatchQueue.main.sync {
      guard self.currentMessageID != nil else { return }
      
      for attrStr in accumulatedOutput {
        self.output += attrStr
      }
      
      self.currentResponse += accumulatedContent
      self.pendingMCPCall += accumulatedContent
      
      // Notify hooks
      self.onStreamContent(accumulatedContent, isReasoning: self.isCurrentlyReasoning)
    }
    
    // Second pass: handle DONE if present
    if isDone {
      Logger.stream("processLines").success("Processing [DONE] marker after all content")
      Logger.stream("processLines").debug("Current batch accumulated: \(accumulatedContent.count) chars")
      
      // Wait for UI sync to complete, then use pendingMCPCall which has ALL content
      DispatchQueue.main.async {
        let completeContent = self.pendingMCPCall
        let messageID = self.currentMessageID
        
        Logger.stream("processLines").debug("Complete pendingMCPCall length: \(completeContent.count)")
        Logger.stream("processLines").info("Performing final tool detection on complete response")
        
        // 1. Save the Assistant Message (Tool Call) immediately
        if !self.currentResponse.isEmpty {
             let assistantMessage = ChatMessage(
                role: "assistant", content: .text(self.currentResponse), model: self.currentModel,
                id: messageID)
             ChatHistory.shared.saveMessage(assistantMessage)
        }
        
        // 2. Reset buffers that belong to the OLD request
        // We do this BEFORE tool execution because if a new query starts, it needs fresh buffers.
        self.currentResponse = ""
        self.pendingMCPCall = ""
        self.dataBuffer = ""
        self.isCurrentlyReasoning = false
        
        // 3. Execute Tools
        Task {
          let didTriggerNewQuery = await self.detectAndExecuteMCPCall(completeContent)
          
          // 4. Handle Task State
          DispatchQueue.main.async {
            if didTriggerNewQuery {
                // New query is running.
                // currentMessageID and currentTask are already set for the NEW query (by sendMessage inside detectAndExecuteMCPCall).
                // Do NOT clear them.
                Logger.stream("processLines").info("Tool execution triggered new query. Keeping task state active.")
            } else {
                // No new query. Clean up task state.
                self.currentTask = nil
                self.currentMessageID = nil
                self.onQueryCompleted?()
                self.onStreamComplete()
                Logger.stream("processLines").info("Query finished without new triggers. Cleared task state.")
            }
            
            // Reset the flag that prevents didCompleteWithError from interfering
            self.isHandlingDone = false
          }
        }
      }
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard currentTask == task && currentMessageID != nil else {
      if error == nil || (error as NSError?)?.code == NSURLErrorCancelled {
        Logger.stream("didCompleteWithError").info("Completion handler for an outdated/cancelled task, ignoring")
      } else if let error = error {
        Logger.stream("didCompleteWithError").error("Error for an outdated task: \(error.localizedDescription)")
      }
      return
    }

    if let error = error {
      DispatchQueue.main.async {
        self.currentResponse = ""
        if (error as NSError).code == NSURLErrorCancelled {
          Logger.stream("didCompleteWithError").info("URLSession task explicitly cancelled")
        } else {
          var errorChunk = AttributedString("\nNetwork Error: \(error.localizedDescription)")
          errorChunk.foregroundColor = .red
          self.output += errorChunk
          self.onStreamError(error.localizedDescription)
        }
        self.isCurrentlyReasoning = false
        self.pendingMCPCall = ""
        self.dataBuffer = ""
        self.onQueryCompleted?()
        self.onStreamComplete()
      }
    } else {
      // Only save if not already saved in [DONE] handler
      DispatchQueue.main.async {
        if self.isHandlingDone {
            Logger.stream("didCompleteWithError").info("Deferring completion to [DONE] handler")
            return
        }
        
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
        self.currentTask = nil
        self.currentMessageID = nil
        self.onQueryCompleted?()
        self.onStreamComplete()
      }
    }
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
  @Published var filteredMCPServers: [String] = []
  @Published var selectedMentionIndex: Int = 0
  
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
    
    // Monitor input changes for @ mentions
    $input
      .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
      .sink { [weak self] newValue in
        self?.checkInputForServerMention(newValue)
      }
      .store(in: &cancellables)
  }
  
  private func checkInputForServerMention(_ text: String) {
    // Simple check: if the last word starts with @, filter servers
    // Find the last @
    if let lastAt = text.lastIndex(of: "@") {
      let suffix = text[lastAt...].dropFirst() // content after @
      // Ensure no spaces after @ for completion
      if !suffix.contains(" ") {
        let query = String(suffix).lowercased()
        // Use ALL servers, not just active ones
        let allServers = MCPManager.shared.getMCPServers().keys
        
        if query.isEmpty {
             filteredMCPServers = Array(allServers).sorted()
        } else {
             filteredMCPServers = allServers.filter { $0.lowercased().contains(query) }.sorted()
        }
        selectedMentionIndex = 0 // Reset selection
        return
      }
    }
    filteredMCPServers = []
    selectedMentionIndex = 0
  }
  
  func handleServerSelection(_ server: String) {
    if let lastAt = input.lastIndex(of: "@") {
        let prefix = input[..<lastAt]
        input = String(prefix) + "@" + server + " "
        filteredMCPServers = []
        
        // Trigger auto-fetch if needed
        Task {
            if let tools = await MCPToolCache.shared.getTools(for: server), !tools.isEmpty {
                // Already cached
            } else {
                // Not cached, fetch
                await MCPManager.shared.refreshTools(for: server)
            }
        }
    }
  }
  
  func submitInput() async {
    Logger.input("submitInput").info("=== START ===")
    Logger.input("submitInput").info("Input text: '\(input)'")
    
    let newMessageID = UUID().uuidString
    self.currentMessageID = newMessageID
    
    let textToSend = self.input
    let fileURLToSend = self.selectedFileURL
    
    Logger.input("submitInput").info("Message ID: \(newMessageID)")
    Logger.input("submitInput").info("Text to send: '\(textToSend)'")
    Logger.input("submitInput").info("Model: \(modelname)")
    Logger.input("submitInput").info("Prompt: \(selectedPrompt)")
    Logger.input("submitInput").info("Has file: \(fileURLToSend != nil)")
    
    self.selectedFileURL = nil
    self.selectedFileName = nil
    
    if let url = fileURLToSend {
      Logger.input("submitInput").info("Processing file upload...")
      if let contentToSend = await ChatHistory.shared.handleFileUpload(
        fileURL: url,
        associatedText: textToSend
      ) {
        Logger.input("submitInput").info("Calling sendMessage with file content...")
        await ChatHistory.shared.sendMessage(
          userText: nil,
          messageContent: contentToSend,
          modelname: modelname,
          selectedPrompt: selectedPrompt,
          streamDelegate: streamDelegate,
          messageID: newMessageID,
          onQueryCompleted: { Task { await MainActor.run { self.queryDidComplete() } } }
        )
      } else {
        Logger.input("submitInput").error("Error processing file upload, message not sent")
        Task { await MainActor.run { self.queryDidComplete() } }
      }
    } else if !textToSend.isEmpty {
      Logger.input("submitInput").info("Calling sendMessage with text content...")
      await ChatHistory.shared.sendMessage(
        userText: textToSend,
        messageContent: nil,
        modelname: modelname,
        selectedPrompt: selectedPrompt,
        streamDelegate: streamDelegate,
        messageID: newMessageID,
        onQueryCompleted: { Task { await MainActor.run { self.queryDidComplete() } } }
      )
      Logger.input("submitInput").success("sendMessage call completed")
    } else {
      Logger.input("submitInput").warning("No content to send")
      self.queryDidComplete()
    }
    Logger.input("submitInput").info("=== END ===")
  }
  
  func queryDidComplete() {
    Logger.ui("queryDidComplete").success("Query completed, setting isQueryActive to false")
    isQueryActive = false
  }
  
  func cancelQuery() {
    Logger.ui("cancelQuery").info("Cancelling query...")
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

  init() {
    // Existing init code...
    // Monitor for arrow keys when popup is active
    NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        if event.keyCode == 126 { // Arrow Up
            NotificationCenter.default.post(name: NSNotification.Name("ArrowUpKeyDown"), object: nil)
            return event
        } else if event.keyCode == 125 { // Arrow Down
            NotificationCenter.default.post(name: NSNotification.Name("ArrowDownKeyDown"), object: nil)
            return event
        }
        return event
    }
  }
  
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
          // Clean up MCP connections before exiting
          Task { @MainActor in
            MCPManager.shared.shutdown()
          }
          exit(0)
        }
      )
      .onAppear {
        focused = true
        viewModel.modelname = modelname
        viewModel.selectedPrompt = selectedPrompt
        
        // Check for auto-submit prompt
        if let autoPrompt = UserDefaults.standard.string(forKey: "autoSubmitPrompt") {
            // Clear the flag immediately
            UserDefaults.standard.removeObject(forKey: "autoSubmitPrompt")
            
            // Set input and submit after a short delay to ensure UI is ready
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                viewModel.input = autoPrompt
                Task {
                    viewModel.isQueryActive = true
                    await viewModel.submitInput()
                }
            }
        }
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
    VStack(alignment: .leading, spacing: 0) {
      if !viewModel.filteredMCPServers.isEmpty {
        ScrollViewReader { proxy in
            ScrollView {
              VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(viewModel.filteredMCPServers.enumerated()), id: \.element) { index, server in
                  Button(action: {
                    viewModel.handleServerSelection(server)
                  }) {
                    HStack {
                      Text(server)
                        .font(.system(size: 12))
                        .foregroundColor(.primary)
                      Spacer()
                      Text("MCP")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(index == viewModel.selectedMentionIndex ? Color.accentColor.opacity(0.2) : Color.clear)
                    .contentShape(Rectangle())
                  }
                  .buttonStyle(PlainButtonStyle())
                  .id(index)
                }
              }
            }
            .frame(maxHeight: 120)
            .background(VisualEffect())
            .cornerRadius(8)
            .padding(.bottom, 4) // Reduced padding to be closer
            .padding(.horizontal, 10)
            .onChange(of: viewModel.selectedMentionIndex) { _, newIndex in
                withAnimation {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
      }

      HStack {
      Button(action: {
        if viewModel.isQueryActive {
          Logger.ui("Button").info("User manually stopping query")
          viewModel.cancelQuery()
          viewModel.input = ""
        } else {
          if !viewModel.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Logger.ui("Button").info("User starting query")
            Task {
              viewModel.isQueryActive = true
              await viewModel.submitInput()
            }
          } else {
            Logger.ui("Button").warning("Empty input, not starting query")
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
            // If popup is visible, Enter selects the item
            if !viewModel.filteredMCPServers.isEmpty {
                let server = viewModel.filteredMCPServers[viewModel.selectedMentionIndex]
                viewModel.handleServerSelection(server)
                return
            }
            
          if !viewModel.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Logger.ui("onSubmit").info("User submitted input via Enter key")
            Task {
              viewModel.isQueryActive = true
              await viewModel.submitInput()
            }
          } else {
            Logger.ui("onSubmit").warning("Empty input, not submitting")
          }
        }
        // Intercept Up/Down keys for navigation
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ArrowUpKeyDown"))) { _ in
            if !viewModel.filteredMCPServers.isEmpty {
                viewModel.selectedMentionIndex = max(0, viewModel.selectedMentionIndex - 1)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ArrowDownKeyDown"))) { _ in
            if !viewModel.filteredMCPServers.isEmpty {
                viewModel.selectedMentionIndex = min(viewModel.filteredMCPServers.count - 1, viewModel.selectedMentionIndex + 1)
            }
        }
        .onChange(of: viewModel.speechManager.transcribedText) { oldValue, newValue in
            Logger.asr("onChange").debug("transcribedText changed from '\(oldValue)' to '\(newValue)'")
            if !newValue.isEmpty {
                Logger.asr("onChange").info("Inserting text at index \(insertionIndex)")
                Logger.asr("onChange").debug("Initial text: '\(initialInputText)'")
                // Insert at the captured cursor position
                let prefix = String(initialInputText.prefix(insertionIndex))
                let suffix = String(initialInputText.suffix(initialInputText.count - insertionIndex))
                viewModel.input = prefix + newValue + suffix
                Logger.asr("onChange").debug("New input: '\(viewModel.input)'")
                
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
                        Logger.asr("onChange").debug("Cursor positioned at: \(newCursorPosition)")
                    }
                }
            }
        }
    }
    }
    .padding(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))

    .onReceive(NotificationCenter.default.publisher(for: .rightOptionKeyDown)) { notification in
        Logger.asr("rightOptionKeyDown").info("Right Option key down detected")
        guard notification.userInfo?["isLongPress"] != nil else { return }
        if !viewModel.speechManager.isRecording {
            Logger.asr("rightOptionKeyDown").info("Starting recording")
            
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
            
            Logger.asr("rightOptionKeyDown").debug("Insertion index: \(insertionIndex)")
            viewModel.speechManager.startRecording()
        }
    }
    .onReceive(NotificationCenter.default.publisher(for: .rightOptionKeyUp)) { _ in
        Logger.asr("rightOptionKeyUp").info("Right Option key up detected")
        Task { @MainActor in
            if viewModel.speechManager.isRecording {
                Logger.asr("rightOptionKeyUp").info("Stopping recording")
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
    
    Logger.config("ModelMenuView").info("Loading models from config. Providers found: \(config.models.keys.joined(separator: ", "))")
    
    for (providerKey, modelConfig) in config.models {
      Logger.config("ModelMenuView").debug("Provider '\(providerKey)' has \(modelConfig.models.count) models")
      for model in modelConfig.models {
        let fullName = "\(model)@\(providerKey)"
        tempMap.append((model: model, provider: providerKey, fullName: fullName))
      }
    }
    
    self._modelProviderMap = State(initialValue: tempMap.sorted { $0.model < $1.model })
    Logger.config("ModelMenuView").success("Loaded \(tempMap.count) models total in init()")
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
  @State private var isRefreshing = false

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
      
      Button(action: {
        Task {
            isRefreshing = true
            await MCPManager.shared.refreshTools(for: serverName)
            isRefreshing = false
        }
      }) {
        Image(systemName: "arrow.clockwise")
            .font(.system(size: 10))
            .foregroundColor(isRefreshing ? .accentColor : .secondary)
            .rotationEffect(isRefreshing ? .degrees(360) : .degrees(0))
            .animation(isRefreshing ? Animation.linear(duration: 1).repeatForever(autoreverses: false) : .default, value: isRefreshing)
      }
      .buttonStyle(PlainButtonStyle())
      .help("Refresh tools")
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
        Logger.ui("FileUploadButton").error("Error selecting file: \(error.localizedDescription)")
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
  let headers: [String: String]?
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
        Logger.config("OpenAIConfig").warning("Default model '\(config.defaultModel)' not found in config. Falling back")
        let fallbackModel = config.allModels.first ?? AppConstants.DefaultModels.openAI
        Logger.config("OpenAIConfig").info("Using fallback model: \(fallbackModel)")
        return OpenAIConfig(models: config.models, legacy: config.legacy, defaultModel: fallbackModel)
      }
      return config

    } catch {
      Logger.config("OpenAIConfig").error("Error loading config: \(error). Using default configuration")
      let defaultModels = [
        "default": ModelConfig(
          baseURL: "https://api.openai.com/v1", apiKey: "YOUR_API_KEY",
          models: [AppConstants.DefaultModels.openAI, "gpt-3.5-turbo"], proxyEnabled: false, proxyURL: nil, headers: nil)
      ]
      return OpenAIConfig(models: defaultModels, legacy: nil, defaultModel: AppConstants.DefaultModels.openAI)
    }
  }

  func getConfig(for model: String) -> ModelConfig? {
    Logger.config("getConfig").debug("Looking up config for model: '\(model)'")
    
    // Handle model@provider format
    let components = model.split(separator: "@")
    let modelName = String(components.first ?? "")
    let providerName = components.count > 1 ? String(components.last!) : nil
    
    Logger.config("getConfig").debug("Parsed - model: '\(modelName)', provider: '\(providerName ?? "nil")'")
    
    // If provider is specified, look in that provider's config
    if let provider = providerName, let config = models[provider] {
      Logger.config("getConfig").debug("Found provider '\(provider)' config with models: \(config.models)")
      if config.models.contains(modelName) {
        Logger.config("getConfig").success("Found model '\(modelName)' in provider '\(provider)'")
        return config
      }
    }
    
    // Fallback: search all providers for the full model string or just model name
    Logger.config("getConfig").debug("Searching all providers...")
    for (providerKey, config) in models {
      Logger.config("getConfig").debug("Checking provider '\(providerKey)': \(config.models)")
      if config.models.contains(model) || config.models.contains(modelName) {
        Logger.config("getConfig").success("Found model in provider '\(providerKey)'")
        return config
      }
    }
    
    Logger.config("getConfig").error("Configuration for model '\(model)' not found in any provider")
    return nil
  }
}

// MARK: - Application Entry Point

// MARK: - CLI Mode Support

enum RunMode {
    case cli(String)           // CLI mode with prompt
    case guiWithPrompt(String) // GUI mode with auto-submit prompt
    case gui                   // Normal GUI mode
}

struct CLIArguments {
    var runMode: RunMode = .gui
    var showHelp: Bool = false
    
    static func parse() -> CLIArguments {
        let args = CommandLine.arguments
        var result = CLIArguments()
        
        // Check for help flag first
        if args.contains("-h") || args.contains("--help") {
            result.showHelp = true
            return result
        }
        
        // Parse arguments
        var i = 1
        while i < args.count {
            let arg = args[i]
            
            if arg == "-p" || arg == "--prompt" {
                // CLI mode: -p flag followed by prompt
                if i + 1 < args.count {
                    result.runMode = .cli(args[i + 1])
                    return result
                }
            } else if !arg.hasPrefix("-") {
                // GUI mode with auto-submit: prompt without flag
                result.runMode = .guiWithPrompt(arg)
                return result
            }
            i += 1
        }
        
        return result
    }
    
    static func printHelp() {
        print("""
        chat.swift - AI Chat Application
        
        USAGE:
            chat.swift [OPTIONS] [PROMPT]
            
        OPTIONS:
            -p, --prompt <text>    Run in CLI mode with the given prompt (output to stdout)
            -h, --help             Show this help message
            
        ARGUMENTS:
            PROMPT                 Launch GUI and auto-submit the prompt
            
        EXAMPLES:
            # CLI mode (output to stdout, logs to file)
            chat.swift -p '@amap 北京的天气'
            
            # GUI mode with auto-submit
            chat.swift '@amap 北京的天气'
            
            # Normal GUI mode
            chat.swift
        """)
    }
}

@MainActor
func runCLIMode(prompt: String) async {
    // Enable file logging
    Logger.enableFileLogging()
    
    Logger.app("CLI").info("Starting CLI mode")
    Logger.app("CLI").info("Prompt: \(prompt)")
    
    // Load configuration
    let config = OpenAIConfig.load()
    let modelName = UserDefaults.standard.string(forKey: AppConstants.UserDefaults.modelName) 
        ?? config.defaultModel
    
    // Create a simple stream delegate that outputs to stdout
    class CLIStreamDelegate: StreamDelegate, @unchecked Sendable {
        override func onStreamContent(_ content: String, isReasoning: Bool) {
            // Output directly to stdout (not using Logger)
            print(content, terminator: "")
            fflush(stdout)
        }
        
        override func onStreamComplete() {
            print("")  // Final newline
        }
        
        override func onStreamError(_ error: String) {
            // Errors still go to log file
            Logger.network("CLI").error("Stream error: \(error)")
        }
    }
    
    let streamDelegate = CLIStreamDelegate()
    let messageID = UUID().uuidString
    
    // Initialize MCP manager if needed
    MCPManager.shared.loadConfig()
    
    // Send the message
    await ChatHistory.shared.sendMessage(
        userText: prompt,
        messageContent: nil,
        modelname: modelName,
        selectedPrompt: "",
        streamDelegate: streamDelegate,
        messageID: messageID,
        onQueryCompleted: {
            Logger.app("CLI").info("Query completed")
            // Shutdown MCP connections
            Task {
                await MCPManager.shared.shutdown()
                Logger.shutdown()
                exit(0)
            }
        }
    )
    
    // Keep the program alive until completion
    while true {
        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
    }
}

// MARK: - Application Entry Point

let cliArgs = CLIArguments.parse()

switch cliArgs.runMode {
case .cli(_) where cliArgs.showHelp:
    CLIArguments.printHelp()
    exit(0)
    
case .cli(let prompt):
    // CLI mode: output to stdout, logs to file
    Task {
        await runCLIMode(prompt: prompt)
    }
    dispatchMain()
    
case .guiWithPrompt(let prompt):
    // GUI mode with auto-submit prompt
    // Store the prompt in UserDefaults for the GUI to pick up
    UserDefaults.standard.set(prompt, forKey: "autoSubmitPrompt")
    App.main()
    
case .gui:
    if cliArgs.showHelp {
        CLIArguments.printHelp()
        exit(0)
    } else {
        // Normal GUI mode
        App.main()
    }
}
