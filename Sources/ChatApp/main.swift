#!/usr/bin/env xcrun -sdk macosx swift

import AppKit
import Foundation
import SwiftUI

// MARK: - Application Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
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

// MARK: - Error Handling

enum AppError: LocalizedError {
  case configNotFound(String)
  case configCorrupted(String)
  case networkError(String)
  case mcpError(String)
  case fileOperationError(String)

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
      .appendingPathComponent("chat.swift")
      .appendingPathComponent("mcp_config.json")
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
  static let safeDefaultModel = "gpt-4-turbo-preview"
  
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

// MARK: - Simplified Tool Parser
extension String {
  func extractToolCalls() -> [ToolCall] {
    var calls: [ToolCall] = []
    var startIndex = startIndex
    
    while let range = self[startIndex...].range(of: "<tool_use>") {
      let toolStart = range.upperBound
      if let endRange = self[toolStart...].range(of: "</tool_use>") {
        let toolContent = String(self[toolStart..<endRange.lowerBound])
        if let call = toolContent.parseToolCall(isComplete: true) {
          calls.append(call)
        }
        startIndex = endRange.upperBound
      } else {
        // Incomplete tool call
        let toolContent = String(self[toolStart...])
        if let call = toolContent.parseToolCall(isComplete: false) {
          calls.append(call)
        }
        break
      }
    }
    return calls
  }
  
  private func parseToolCall(isComplete: Bool) -> ToolCall? {
    // Extract tool name (first XML tag)
    guard let nameMatch = range(of: #"<(\w+)>"#, options: .regularExpression),
          let toolName = String(self[nameMatch]).extractBetween("<", ">") else { return nil }
    
    // Extract parameters within tool content
    var parameters: [String: String] = [:]
    
    // Find content within the tool tag first
    if let toolContentRange = range(of: #"<\#(toolName)>(.*?)</\#(toolName)>"#, options: .regularExpression) {
      let toolContent = String(self[toolContentRange])
        .replacingOccurrences(of: "<\(toolName)>", with: "")
        .replacingOccurrences(of: "</\(toolName)>", with: "")
      
      // Parse individual parameters
      let paramPattern = #"<(\w+)>(.*?)</\1>"#
      let regex = try? NSRegularExpression(pattern: paramPattern, options: [.dotMatchesLineSeparators])
      
      regex?.enumerateMatches(in: toolContent, range: NSRange(toolContent.startIndex..<toolContent.endIndex, in: toolContent)) { match, _, _ in
        guard let match = match, match.numberOfRanges >= 3,
              let nameRange = Range(match.range(at: 1), in: toolContent),
              let valueRange = Range(match.range(at: 2), in: toolContent) else { return }
        
        let name = String(toolContent[nameRange])
        let value = String(toolContent[valueRange])
        parameters[name] = value
      }
    }
    
    return ToolCall(toolName: toolName, parameters: parameters, isComplete: isComplete)
  }
  
  private func extractBetween(_ start: String, _ end: String) -> String? {
    guard let startRange = range(of: start),
          let endRange = self[startRange.upperBound...].range(of: end) else { return nil }
    return String(self[startRange.upperBound..<endRange.lowerBound])
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

  func callMCPTool(serverName: String, toolName: String, arguments: [String: Any]) async -> String {
    guard let server = mcpServers[serverName], activeMCPServers.contains(serverName) else {
      return "Server \(serverName) not found or not active"
    }

    if server.isRemote {
      return await callRemoteMCPTool(server: server, toolName: toolName, arguments: arguments)
    } else {
      return await callLocalMCPTool(server: server, toolName: toolName, arguments: arguments)
    }
  }

  private func callRemoteMCPTool(server: MCPServer, toolName: String, arguments: [String: Any])
    async -> String
  {
    guard let urlString = server.url, let url = URL(string: urlString) else {
      return "Invalid server URL"
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
              return resultString
            }
            return "\(result)"
          }
          return String(data: data, encoding: .utf8) ?? "No response data"
        } else {
          return
            "HTTP Error \(httpResponse.statusCode): \(String(data: data, encoding: .utf8) ?? "Unknown error")"
        }
      }

      return String(data: data, encoding: .utf8) ?? "No response"
    } catch {
      return "Failed to call remote MCP tool: \(error.localizedDescription)"
    }
  }

  private func callLocalMCPTool(server: MCPServer, toolName: String, arguments: [String: Any]) async
    -> String
  {
    guard let command = server.command, let args = server.args else {
      return "Local server missing command or args"
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
        return String(data: outputData, encoding: .utf8) ?? "No output"
      } else {
        let errorOutput = String(data: errorData, encoding: .utf8) ?? "Unknown error"
        return "Error executing MCP tool: \(errorOutput)"
      }
    } catch {
      return "Failed to execute MCP tool: \(error.localizedDescription)"
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
      .appendingPathComponent("chat.swift")

    try? FileManager.default.createDirectory(at: configPath, withIntermediateDirectories: true)

    historyPath = configPath.appendingPathComponent("history.md")
    promptsPath = configPath.appendingPathComponent("prompts")
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
      let content = try String(contentsOf: fileURL)
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
    let config = OpenAIConfig.load()
    guard let modelConfig = config.getConfig(for: modelname),
          let baseURL = modelConfig.baseURL,
          let apiKey = modelConfig.apiKey else {
      print("Error: Model configuration not found or incomplete for \(modelname)")
      onQueryCompleted()
      return
    }

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

    let chatRequest = ChatRequest(
      model: modelname, messages: messagesToSend, stream: true
    )

    do {
      let encoder = JSONEncoder()
      request.httpBody = try encoder.encode(chatRequest)
    } catch {
      print("Error encoding request: \(error)")
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

    streamDelegate.output = AttributedString("")
    streamDelegate.setModel(modelname)
    streamDelegate.currentMessageID = messageID
    streamDelegate.setQueryCompletionCallback(onQueryCompleted)

    let session = URLSession(
      configuration: sessionConfig, delegate: streamDelegate, delegateQueue: nil)
    let task = session.dataTask(with: request)
    streamDelegate.currentTask = task
    task.resume()
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
    print("Query cancelled and StreamDelegate state reset.")
  }

  func setQueryCompletionCallback(_ callback: @escaping () -> Void) {
    self.onQueryCompleted = callback
  }

  func setModel(_ model: String) {
    currentModel = model
  }

  private func detectAndExecuteMCPCall(_ text: String) async {
    let toolCalls = text.extractToolCalls()
    for call in toolCalls where call.isComplete && call.toolName == "mcp_call" {
      await executeMCPTool(call)
    }
  }
  
  private func executeMCPTool(_ call: ToolCall) async {
    guard let server = call.parameters["server"],
          let tool = call.parameters["tool"] else { return }
    
    let args = call.parameters.filter { !["server", "tool"].contains($0.key) }
    let argsDisplay = args.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
    
    await updateUI("🔧 执行 MCP 工具", "服务器: \(server)\n工具: \(tool)\n\(argsDisplay.isEmpty ? "" : "参数:\n\(argsDisplay)\n")执行中...")
    
    let result = await MCPManager.shared.callMCPTool(serverName: server, toolName: tool, arguments: args)
    let formatted = formatResult(result)
    
    await updateUI("📋 工具结果", "```\n\(formatted)\n```")
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
    // print(dataTask, currentMessageID)
    guard currentTask == dataTask, currentMessageID != nil else {
      return
    }

    if let text = String(data: data, encoding: .utf8) {
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

      // Add new data to buffer
      dataBuffer += text

      // Process complete lines from buffer
      let lines = dataBuffer.components(separatedBy: "\n")

      // Keep the last line in buffer if it's incomplete (no trailing newline)
      if !dataBuffer.hasSuffix("\n") && lines.count > 1 {
        dataBuffer = lines.last ?? ""
        let completeLines = Array(lines.dropLast())
        processLines(completeLines)
      } else {
        dataBuffer = ""
        processLines(lines)
      }
    }
  }

  private func processLines(_ lines: [String]) {
    for line in lines {
      if line.hasPrefix("data: ") {
        // Handle [DONE] marker
        if line.contains("data: [DONE]") {
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

        // Parse JSON data for actual content
        let jsonString = String(line.dropFirst(6))
        guard !jsonString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let jsonData = jsonString.data(using: .utf8)
        else {
          continue
        }

        do {
          if let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let firstChoice = choices.first,
            let delta = firstChoice["delta"] as? [String: Any]
          {
            var contentChunk = ""
            var isChunkReasoning = false

            if let reasoningContent = delta["reasoning_content"] as? String {
              contentChunk = reasoningContent
              isChunkReasoning = true
            } else if let regularContent = delta["content"] as? String {
              contentChunk = regularContent
            }

            if !contentChunk.isEmpty {
              DispatchQueue.main.async { [contentChunk, isChunkReasoning] in
                guard self.currentMessageID != nil else { return }

                var chunkToAppend = contentChunk
                var attributedChunk: AttributedString

                if !isChunkReasoning && self.isCurrentlyReasoning {
                  chunkToAppend = "\n" + chunkToAppend
                  self.isCurrentlyReasoning = false
                }

                if isChunkReasoning {
                  self.isCurrentlyReasoning = true
                }

                self.currentResponse += chunkToAppend
                self.pendingMCPCall += chunkToAppend

                attributedChunk = AttributedString(chunkToAppend)
                if isChunkReasoning {
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
        } catch {
          print("Error parsing JSON line: \(jsonString), Error: \(error)")
          // Don't show parsing errors to user for malformed chunks, just log them
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

// MARK: - UI Components - Main App

@MainActor
struct App: SwiftUI.App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  @State private var input = ""
  @StateObject private var streamDelegate = StreamDelegate()
  @AppStorage("modelname") public var modelname = OpenAIConfig.getDefaultModel()
  @AppStorage("selectedPrompt") private var selectedPrompt: String = ""
  @FocusState private var focused: Bool
  @State private var selectedFileURL: URL? = nil
  @State private var selectedFileName: String? = nil
  @State private var isQueryActive: Bool = false
  @State private var currentMessageID: String? = nil

  var body: some Scene {
    WindowGroup {
      VStack(alignment: .leading) {
        HStack {
          ModelMenuView(modelname: $modelname)
          PromptMenuView(selectedPrompt: $selectedPrompt)
          MCPMenuView()

          FileUploadButton(selectedFileName: $selectedFileName) { fileURL in
            self.selectedFileURL = fileURL
          }
        }
        .offset(x: 0, y: 5)
        .ignoresSafeArea()
        .frame(maxWidth: .infinity, maxHeight: 0, alignment: .trailing)

        LLMInputView
        Divider()

        if !streamDelegate.output.characters.isEmpty {
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
      }
    }
    .windowStyle(HiddenTitleBarWindowStyle())
    .defaultSize(width: 0.5, height: 1.0)
  }

  private var LLMInputView: some View {
    HStack {
      Button(action: {
        if isQueryActive {
          streamDelegate.cancelCurrentQuery()
          // input = ""
          isQueryActive = false
        } else {
          if !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Task {
              await submitInput()
              isQueryActive = true
            }
          }
        }
      }) {
        // Text(isQueryActive ? "\u{1F9CA}" : "\u{1F3B2}")
        Text("\u{1F3B2}")
          .foregroundColor(.white)
          .cornerRadius(5)
      }
      .buttonStyle(PlainButtonStyle())
      .rotationEffect(isQueryActive ? .degrees(360) : .degrees(0))
      .animation(
        isQueryActive
          ? Animation.linear(duration: 2.0).repeatForever(autoreverses: false) : .default,
        value: isQueryActive)

      TextField("write something..", text: $input, axis: .vertical)
        .lineLimit(1...5)
        .textFieldStyle(.plain)
        .focused($focused)
        .onSubmit {
          if !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Task {
              await submitInput()
              isQueryActive = true
            }
          }
        }
    }
    .padding(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
  }

  private func submitInput() async {
    let newMessageID = UUID().uuidString
    self.currentMessageID = newMessageID

    let textToSend = self.input
    let fileURLToSend = self.selectedFileURL

    self.selectedFileURL = nil
    self.selectedFileName = nil

    if let url = fileURLToSend {
      if let contentToSend = await ChatHistory.shared.handleFileUpload(
        fileURL: url,
        associatedText: textToSend
      ) {
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
        print("Error processing file upload, message not sent.")
        self.queryDidComplete()
      }
    } else if !textToSend.isEmpty {
      await ChatHistory.shared.sendMessage(
        userText: textToSend,
        messageContent: nil,
        modelname: modelname,
        selectedPrompt: selectedPrompt,
        streamDelegate: streamDelegate,
        messageID: newMessageID,
        onQueryCompleted: self.queryDidComplete
      )
    } else {
      self.queryDidComplete()
    }
  }

  func queryDidComplete() {
    isQueryActive = false
  }

  private var LLMOutputView: some View {
    ScrollView {
      Text(streamDelegate.output)
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

// MARK: - Simplified UI Components

struct AppPopover<T: Hashable & CustomStringConvertible>: View {
  @Binding var selection: T
  let options: [T]
  let icon: String
  let showText: Bool
  @State private var showPopover = false

  var body: some View {
    Button(action: { showPopover.toggle() }) {
      HStack(spacing: 6) {
        Text(icon).font(.system(size: 12))
        if showText && !selection.description.isEmpty {
          Text(selection.description).font(.system(size: 12)).foregroundColor(.primary)
        }
      }.padding(.horizontal, 2)
    }
    .buttonStyle(PlainButtonStyle())
    .popover(isPresented: $showPopover) {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(options, id: \.self) { option in
          Button(action: { selection = option; showPopover = false }) {
            HStack {
              Text(option.description)
                .foregroundColor(selection == option ? .accentColor : .primary)
              if selection == option {
                Image(systemName: "checkmark").foregroundColor(.accentColor)
              }
            }
            .padding(.vertical, 6).padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selection == option ? Color.accentColor.opacity(0.18) : Color.clear)
            .cornerRadius(6)
          }.buttonStyle(PlainButtonStyle())
        }
      }.popoverStyle()
    }
  }
}

// MARK: - UI Components - Menu Views

struct ModelMenuView: View {
  @Binding var modelname: String
  @State private var models: [String] = []
  
  var body: some View {
    AppPopover(selection: $modelname, options: models, icon: "🧠", showText: true)
      .task {
        await loadModels()
      }
  }
  
  private func loadModels() async {
    await MainActor.run {
      let config = OpenAIConfig.load()
      models = config.allModels
    }
  }
}

struct PromptMenuView: View {
  @Binding var selectedPrompt: String
  @State private var prompts: [String] = ["None"]

  var body: some View {
    AppPopover(selection: $selectedPrompt, options: prompts, icon: "📄", showText: selectedPrompt != "None")
      .task {
        let available = await ChatHistory.shared.getAvailablePrompts()
        prompts = ["None"] + available
        if !prompts.contains(selectedPrompt) { selectedPrompt = "None" }
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
      .appendingPathComponent("chat.swift")
      .appendingPathComponent("config.json")
  }

  static func load() -> OpenAIConfig {
    do {
      let config = try loadConfig(OpenAIConfig.self)

      if config.getConfig(for: config.defaultModel) == nil {
        print("Warning: Default model '\(config.defaultModel)' not found in config. Falling back.")
        let fallbackModel = config.allModels.first ?? "gpt-4-turbo-preview"
        print("Using fallback model: \(fallbackModel)")
        return OpenAIConfig(models: config.models, legacy: config.legacy, defaultModel: fallbackModel)
      }
      return config

    } catch {
      print("Error loading config: \(error). Using default configuration.")
      let defaultModels = [
        "default": ModelConfig(
          baseURL: "https://api.openai.com/v1", apiKey: "YOUR_API_KEY",
          models: ["gpt-4-turbo-preview", "gpt-3.5-turbo"], proxyEnabled: false, proxyURL: nil)
      ]
      return OpenAIConfig(models: defaultModels, legacy: nil, defaultModel: "gpt-4-turbo-preview")
    }
  }

  func getConfig(for model: String) -> ModelConfig? {
    // Only search in models section, ignore legacy
    for (_, config) in models {
      if config.models.contains(model) {
        return config
      }
    }
    print("Warning: Configuration for model '\(model)' not found.")
    return nil
  }
}

// MARK: - Application Entry Point

App.main()
