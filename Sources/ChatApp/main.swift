#!/usr/bin/env xcrun -sdk macosx swift

import AppKit
import Foundation
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }
}

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

struct MCPServer: Codable {
  let command: String?
  let args: [String]?
  let env: [String: String]?
  let isActive: Bool
  let type: String?
  let description: String?
  let url: String?
  let headers: [String: String]?

  init(
    command: String? = nil, args: [String]? = nil, env: [String: String]? = nil,
    isActive: Bool = false, type: String? = nil, description: String? = nil,
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

struct MCPConfig: Codable {
  let mcpServers: [String: MCPServer]
}

struct MCPToolCall: Codable {
  let name: String
  let arguments: [String: Any]

  init(name: String, arguments: [String: Any]) {
    self.name = name
    self.arguments = arguments
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(name, forKey: .name)

    var argsContainer = container.nestedContainer(
      keyedBy: DynamicCodingKeys.self, forKey: .arguments)
    for (key, value) in arguments {
      let codingKey = DynamicCodingKeys(stringValue: key)!
      if let stringValue = value as? String {
        try argsContainer.encode(stringValue, forKey: codingKey)
      } else if let intValue = value as? Int {
        try argsContainer.encode(intValue, forKey: codingKey)
      } else if let boolValue = value as? Bool {
        try argsContainer.encode(boolValue, forKey: codingKey)
      }
    }
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    name = try container.decode(String.self, forKey: .name)

    let argsContainer = try container.nestedContainer(
      keyedBy: DynamicCodingKeys.self, forKey: .arguments)
    var args: [String: Any] = [:]
    for key in argsContainer.allKeys {
      if let stringValue = try? argsContainer.decode(String.self, forKey: key) {
        args[key.stringValue] = stringValue
      } else if let intValue = try? argsContainer.decode(Int.self, forKey: key) {
        args[key.stringValue] = intValue
      } else if let boolValue = try? argsContainer.decode(Bool.self, forKey: key) {
        args[key.stringValue] = boolValue
      }
    }
    arguments = args
  }

  private enum CodingKeys: String, CodingKey {
    case name, arguments
  }

  private struct DynamicCodingKeys: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
      self.stringValue = stringValue
    }

    init?(intValue: Int) {
      return nil
    }
  }
}

struct SystemPrompt: Codable {
  let role: String
  let content: String
}

@MainActor
class MCPManager: ObservableObject {
  static let shared = MCPManager()
  private let configPath: URL
  @Published private var mcpServers: [String: MCPServer] = [:]
  @Published private var activeMCPServers: Set<String> = []

  private init() {
    let configDir = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".config")
      .appendingPathComponent("chat.swift")

    configPath = configDir.appendingPathComponent("mcp_config.json")
    loadMCPConfig()
  }

  private func loadMCPConfig() {
    do {
      let data = try Data(contentsOf: configPath)
      let config = try JSONDecoder().decode(MCPConfig.self, from: data)
      mcpServers = config.mcpServers
      activeMCPServers = Set(config.mcpServers.filter { $0.value.isActive }.keys)
      print("MCP config loaded successfully: \(mcpServers.count) servers")
    } catch {
      print("Error loading MCP config from \(configPath): \(error)")
      // Create default empty config if file doesn't exist
      if !FileManager.default.fileExists(atPath: configPath.path) {
        let defaultConfig = MCPConfig(mcpServers: [:])
        do {
          let data = try JSONEncoder().encode(defaultConfig)
          try data.write(to: configPath)
          print("Created default MCP config file")
        } catch {
          print("Failed to create default MCP config: \(error)")
        }
      }
    }
  }

  func getMCPServers() -> [String: MCPServer] {
    return mcpServers
  }

  func getActiveMCPServers() -> Set<String> {
    return activeMCPServers
  }
  
  func reloadConfig() {
    loadMCPConfig()
  }

  func setServerActive(_ serverName: String, active: Bool) {
    if active {
      activeMCPServers.insert(serverName)
    } else {
      activeMCPServers.remove(serverName)
    }
    saveMCPConfig()
  }

  private func saveMCPConfig() {
    var updatedServers = mcpServers
    for (name, server) in updatedServers {
      updatedServers[name] = MCPServer(
        command: server.command,
        args: server.args,
        env: server.env,
        isActive: activeMCPServers.contains(name),
        type: server.type,
        description: server.description,
        url: server.url,
        headers: server.headers
      )
    }

    let config = MCPConfig(mcpServers: updatedServers)
    do {
      let data = try JSONEncoder().encode(config)
      try data.write(to: configPath)
    } catch {
      print("Error saving MCP config: \(error)")
    }
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
    guard let modelConfig = config.getConfig(for: modelname) else {
      print("Error: Model configuration not found for \(modelname)")
      onQueryCompleted()
      return
    }

    let url = URL(string: "\(modelConfig.baseURL)/chat/completions")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(modelConfig.apiKey)", forHTTPHeaderField: "Authorization")

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
        Available MCP tools from active servers: \(Array(activeMCPServers).joined(separator: ", ")).

        Use ReAct pattern for tool calling:
        1) Thought: analyze what you need to do
        2) Action: call specific MCP tool using format: Action: [server_name] tool_name(arguments)
        3) Observation: review result
        4) Continue until complete.

        For GitHub MCP tools, available actions include repository operations, issue management, pull requests, etc.
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
    // Simple pattern matching for MCP tool calls
    // Looking for patterns like "Action: [server_name] tool_name(arguments)"
    let mcpActionPattern = #"Action:\s*\[([^\]]+)\]\s*(\w+)\s*\(([^)]*)\)"#
    let regex = try? NSRegularExpression(pattern: mcpActionPattern, options: [])

    if let match = regex?.firstMatch(
      in: text, options: [], range: NSRange(location: 0, length: text.utf16.count))
    {
      let serverName = String(text[Range(match.range(at: 1), in: text)!])
      let toolName = String(text[Range(match.range(at: 2), in: text)!])
      let argumentsString = String(text[Range(match.range(at: 3), in: text)!])

      // Parse arguments (simple key=value format)
      var arguments: [String: Any] = [:]
      let argPairs = argumentsString.split(separator: ",")
      for pair in argPairs {
        let keyValue = pair.split(separator: "=", maxSplits: 1)
        if keyValue.count == 2 {
          let key = String(keyValue[0]).trimmingCharacters(in: .whitespacesAndNewlines)
          let value = String(keyValue[1]).trimmingCharacters(in: .whitespacesAndNewlines)
          arguments[key] = value
        }
      }

      // Prepare display info
      let argsString =
        !arguments.isEmpty
        ? arguments.map { "\($0.key) = \($0.value)" }.joined(separator: "\n") : ""

      DispatchQueue.main.async {
        var actionHeader = AttributedString("\n🔧 执行 MCP 工具\n")
        actionHeader.foregroundColor = .blue

        var actionDetails = AttributedString("服务器: \(serverName)\n工具: \(toolName)\n")
        actionDetails.foregroundColor = .blue

        if !argsString.isEmpty {
          actionDetails += AttributedString("参数:\n\(argsString)\n")
        }
        actionDetails += AttributedString("执行中...\n")

        self.output += actionHeader + actionDetails
      }

      let result = await MCPManager.shared.callMCPTool(
        serverName: serverName,
        toolName: toolName,
        arguments: arguments
      )

      DispatchQueue.main.async {
        // Format the result to preserve line breaks and improve readability
        var formattedResult =
          result
          .replacingOccurrences(of: "\\n", with: "\n")
          .replacingOccurrences(of: "\\t", with: "\t")
          .replacingOccurrences(of: "\\\"", with: "\"")

        // Try to pretty-print JSON if the result looks like JSON
        if formattedResult.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
          || formattedResult.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[")
        {
          if let data = formattedResult.data(using: .utf8),
            let jsonObject = try? JSONSerialization.jsonObject(with: data),
            let prettyData = try? JSONSerialization.data(
              withJSONObject: jsonObject, options: [.prettyPrinted, .sortedKeys]),
            let prettyString = String(data: prettyData, encoding: .utf8)
          {
            formattedResult = prettyString
          }
        }

        var resultHeader = AttributedString("\n📋 观察结果:\n")
        resultHeader.foregroundColor = .green

        var contentChunk = AttributedString("```\n\(formattedResult)\n```\n\n")
        contentChunk.foregroundColor = .primary

        self.output += resultHeader + contentChunk
        self.currentResponse += "\n观察结果:\n```\n\(formattedResult)\n```\n\n"
      }
    }
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
              let jsonData = jsonString.data(using: .utf8) else {
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

@MainActor
struct App: SwiftUI.App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  @State private var input = ""
  @StateObject private var streamDelegate = StreamDelegate()
  @AppStorage("modelname") public var modelname = OpenAIConfig.load().defaultModel
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
    .popover(isPresented: $showPopover, arrowEdge: .bottom) {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(options, id: \.self) { option in
          PopoverSelectorRow(
            label: {
              HStack {
                Text(option.description)
                  .foregroundColor(selection == option ? .accentColor : .primary)
                if selection == option {
                  Image(systemName: "checkmark")
                    .foregroundColor(.accentColor)
                }
              }
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

struct ModelMenuView: View {
  @Binding public var modelname: String
  private let models: [String] = OpenAIConfig.load().models.values.flatMap { $0.models }.sorted()
  var body: some View {
    PopoverSelector(
      selection: $modelname, options: models,
      label: {
        AnyView(
          HStack(spacing: 6) {
            Text("\u{1F9E0}").font(.system(size: 14))
            Text(modelname).font(.system(size: 12)).foregroundColor(.primary)
          }
          .padding(.horizontal, 2)
        )
      }
    )
    .frame(alignment: .trailing)
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
            Text("\u{1F4C4}").font(.system(size: 12))
            if selectedPrompt != "None" && !selectedPrompt.isEmpty {
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

  var body: some View {
    Button(action: { 
      updateMCPState()
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
                  updateMCPState()
                }
              }
            )
          }
        }
      }
      .padding(.bottom, 10)
      .frame(width: 250)
    }
    .onAppear {
      updateMCPState()
    }
    .task {
      updateMCPState()
    }
  }
  
  private func updateMCPState() {
    Task { @MainActor in
      MCPManager.shared.reloadConfig()
      mcpServers = MCPManager.shared.getMCPServers()
      activeMCPServers = MCPManager.shared.getActiveMCPServers()
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

struct ModelConfig: Codable {
  let baseURL: String
  let apiKey: String
  let models: [String]
  let proxyEnabled: Bool?
  let proxyURL: String?
}

struct OpenAIConfig: Codable {
  let models: [String: ModelConfig]
  let defaultModel: String

  static func load() -> OpenAIConfig {
    let configPath = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".config")
      .appendingPathComponent("chat.swift")
      .appendingPathComponent("config.json")

    do {
      let data = try Data(contentsOf: configPath)
      let decoder = JSONDecoder()
      let config = try decoder.decode(OpenAIConfig.self, from: data)

      if config.getConfig(for: config.defaultModel) == nil {
        print("Warning: Default model '\(config.defaultModel)' not found in config. Falling back.")
        let fallbackModel = config.models.first?.value.models.first ?? "gpt-4-turbo-preview"
        print("Using fallback model: \(fallbackModel)")
        return OpenAIConfig(models: config.models, defaultModel: fallbackModel)
      }
      return config

    } catch {
      print("Error loading config: \(error). Using default configuration.")
      let defaultModels = [
        "default": ModelConfig(
          baseURL: "https://api.openai.com/v1", apiKey: "YOUR_API_KEY",
          models: ["gpt-4-turbo-preview", "gpt-3.5-turbo"], proxyEnabled: false, proxyURL: nil)
      ]
      return OpenAIConfig(models: defaultModels, defaultModel: "gpt-4-turbo-preview")
    }
  }

  func getConfig(for model: String) -> ModelConfig? {
    for (_, config) in models {
      if config.models.contains(model) {
        return config
      }
    }
    print("Warning: Configuration for model '\(model)' not found.")
    return nil
  }
}

App.main()
