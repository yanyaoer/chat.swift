#!/usr/bin/env xcrun -sdk macosx swift

import AppKit
import Foundation
import SwiftUI
// Ensure MCPClient is imported if any types from it are used directly in this file,
// though most interaction is through MCPServiceManager or ToolExecutor.
// import MCPClient

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

struct ChatMessage: Codable {
  let role: String
  let content: MessageContent?
  let timestamp: Date
  let model: String?
  let reasoning_effort: String?
  var id: String?

  let tool_calls: [OpenAIToolCall]?
  let tool_call_id: String?
  let name: String? // Function name for role 'tool'

  enum CodingKeys: String, CodingKey {
      case role, content, timestamp, model, reasoning_effort, id
      case tool_calls
      case tool_call_id
      case name
  }

  init(
    role: String, content: MessageContent? = nil, model: String? = nil, reasoning_effort: String? = nil,
    id: String? = nil, tool_calls: [OpenAIToolCall]? = nil, tool_call_id: String? = nil, name: String? = nil
  ) {
    self.role = role
    self.content = content
    self.timestamp = Date()
    self.model = model
    self.reasoning_effort = reasoning_effort
    self.id = id
    self.tool_calls = tool_calls
    self.tool_call_id = tool_call_id
    self.name = name
  }
}

struct OpenAIToolCall: Codable {
    let id: String
    let type: String
    let function: OpenAIFunctionCall
}

struct OpenAIFunctionCall: Codable {
    let name: String
    let arguments: String
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

struct ChatRequest: Codable {
  let model: String
  var messages: [ChatMessage]
  let stream: Bool
  let tools: [OpenAIToolWrapper]? // For OpenAI tool usage
  let tool_choice: String? // For OpenAI tool usage ("auto", "none", or {"type": "function", "function": {"name": "my_function"}})


  init(model: String, messages: [ChatMessage], stream: Bool, tools: [OpenAIToolWrapper]? = nil, tool_choice: String? = "auto") {
      self.model = model
      self.messages = messages
      self.stream = stream
      self.tools = tools
      self.tool_choice = tool_choice
  }
}

// Wrapper for OpenAI tool definition
struct OpenAIToolWrapper: Codable {
    let type: String // "function"
    let function: OpenAIFunctionTool
}
struct OpenAIFunctionTool: Codable {
    let name: String
    let description: String
    // let parameters: JSONSchema // Define parameters as a JSON schema object; using String for simplicity for now
    // For simplicity, parameters are omitted here but are crucial for real tool use.
    // Example: parameters: {"type": "object", "properties": {"location": {"type": "string", "description": "The city and state, e.g. San Francisco, CA"}}, "required": ["location"]}
}


struct SystemPrompt: Codable {
  let role: String
  let content: String
}

@MainActor
class ChatHistory {
  static let shared = ChatHistory()
  private let historyPath: URL
  private let promptsPath: URL
  @AppStorage("selectedPrompt") private var selectedPrompt: String = ""

  // Store message history for ReAct loop
  private var currentConversation: [ChatMessage] = []


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
    currentConversation.append(message) // Add to in-memory history for ReAct

    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let timestamp = dateFormatter.string(from: message.timestamp)

    let modelInfo = message.model.map { " [\($0)]" } ?? ""
    // let promptInfo = message.role == "system" ? " [Prompt: \(selectedPrompt)]" : "" // Prompt info already in content
    let idInfo = message.id.map { " [ID: \($0)]" } ?? ""

    var contentText = ""
    if let msgContent = message.content {
        switch msgContent {
        case .text(let text):
          contentText = text
        case .multimodal(let items):
          contentText = items.map { item in
            if let text = item.text { return text }
            if let imageUrl = item.image_url {
              let displayUrl = imageUrl.url.count > 100 ? String(imageUrl.url.prefix(50)) + "..." + String(imageUrl.url.suffix(20)) : imageUrl.url
              return "[Image: \(displayUrl)]"
            }
            return ""
          }.joined(separator: "\n")
        }
    } else if let toolCalls = message.tool_calls {
        contentText = "Tool Calls:\n" + toolCalls.map { tc in
            "  ID: \(tc.id)\n  Function: \(tc.function.name)\n  Args: \(tc.function.arguments)"
        }.joined(separator: "\n")
    } else if message.role == "tool" {
        contentText = "Tool Result for \(message.name ?? "unknown tool") (ID: \(message.tool_call_id ?? "unknown")): \n\(message.content?.textValue ?? "No textual result")"
    }


    let textToSave = """
          
      [\(timestamp)] \(message.role.uppercased())\(modelInfo)\(idInfo):
      \(contentText)
      """

    if let data = textToSave.data(using: .utf8) {
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

  func clearConversationHistory() {
      currentConversation = []
  }

  func getCurrentConversation() -> [ChatMessage] {
      return currentConversation
  }


  // Initial message sending
  func sendInitialMessage(
    userText: String?,
    messageContent: MessageContent? = nil,
    modelname: String,
    selectedPromptName: String, // Renamed to avoid conflict with AppStorage
    streamDelegate: StreamDelegate,
    messageID: String
  ) async {
    clearConversationHistory() // Start fresh for a new user query

    // Prepare system prompt if selected
    var systemMessageContent: String? = nil
    if !selectedPromptName.isEmpty, selectedPromptName != "None", let prompt = loadPromptContent(name: selectedPromptName) {
        systemMessageContent = prompt.content
    }
    // Add tools description to system prompt for OpenAI models
    if MCPConfigLoader.shared.getServiceConfig(forName: modelname) == nil { // If it's an OpenAI model
        let toolsDescription = ToolExecutor.shared.getAvailableToolsDescriptionForLLM()
        if systemMessageContent != nil {
            systemMessageContent! += "\n\nAvailable tools:\n\(toolsDescription)"
        } else {
            systemMessageContent = "Available tools:\n\(toolsDescription)"
        }
    }

    if let sysContent = systemMessageContent {
        let systemMessage = ChatMessage(role: "system", content: .text(sysContent), id: UUID().uuidString)
        // saveMessage(systemMessage) // System messages are part of the request, not displayed directly
        currentConversation.append(systemMessage) // Add to conversation context
    }

    // Prepare user message
    let finalUserContent: MessageContent
    if let content = messageContent {
      finalUserContent = content
    } else if let text = userText, !text.isEmpty {
      finalUserContent = .text(text)
    } else {
      print("Error: No message content to send for initial message.")
      await streamDelegate.queryDidCompleteWithError(NSError(domain: "ChatHistory", code: 1, userInfo: [NSLocalizedDescriptionKey: "No content to send."]), forMessageId: messageID)
      return
    }
    let userMessage = ChatMessage(role: "user", content: finalUserContent, model: modelname, id: messageID)
    saveMessage(userMessage) // This also adds to currentConversation

    await continueConversation(modelname: modelname, streamDelegate: streamDelegate, originalMessageID: messageID)
  }

  // Function to continue conversation, potentially with tool results
  func continueConversation(
      modelname: String,
      streamDelegate: StreamDelegate,
      originalMessageID: String, // ID of the initial user message this turn is for
      toolResults: [ChatMessage]? = nil // Results from tool execution
  ) async {
      if let results = toolResults {
          results.forEach { saveMessage($0) } // Save tool results to history
      }

      // Determine if it's an MCP service or OpenAI
      if let mcpService = MCPConfigLoader.shared.getServiceConfig(forName: modelname) {
          // MCP Service Call
          print("Continuing conversation with MCP Service: \(mcpService.name) for originalMsgID: \(originalMessageID)")
          // For MCP, we typically send the last user message or a summary.
          // ReAct with MCP services might involve the MCP service itself managing history,
          // or us sending relevant parts. For now, send the latest user message or tool result content.
          // The `currentConversation` has the full history.
          // Let's assume the last message in currentConversation is the one to send, or if toolResults were provided, they are key.

          // Construct MCPClient.Input based on the last message or tool results
          var mcpContent: String = ""
          var mcpToolResults: [MCPClient.ToolResult]? = nil

          if let lastToolResult = toolResults?.last, let toolContent = lastToolResult.content?.textValue {
              // If we just processed tool results, that's the input for the next step.
              // This assumes the MCP LLM expects the raw tool output as content.
              // Or, if the MCP LLM made the tool call, we need to send ToolResult objects.
              mcpContent = "Tool result for \(lastToolResult.name ?? ""): \(toolContent)"
              // This part needs to align with how an MCP LLM expects tool results.
              // If the MCP LLM called tools, we'd populate mcpToolResults.
              // For now, this example assumes we are sending the text of the result.
          } else if let lastUserMessage = currentConversation.last(where: { $0.role == "user" }), let textContent = lastUserMessage.content?.textValue {
              mcpContent = textContent
          } else {
              print("Error: No suitable content for MCP service in continueConversation.")
              await streamDelegate.queryDidCompleteWithError(NSError(domain: "ChatHistory", code: 2, userInfo: [NSLocalizedDescriptionKey: "No content for MCP."]), forMessageId: originalMessageID)
              return
          }

          // If the MCP service is the one that requested tools, we need to send MCPClient.ToolResult
          // This requires knowing which tool calls the MCP service made.
          // This part is complex and depends on how MCP SDK handles tool calls *from* an MCP LLM.
          // For now, assuming `streamRequest` to MCP is like a user query.
          // If `toolResults` came from `MCPClient.ToolCall`s made by this MCP service, convert them.
          if let sdkToolResults = toolResults?.compactMap({ chatMsgToMCPToolResult($0) }) {
              mcpToolResults = sdkToolResults
          }


          let mcpPayload = MCPClient.Input(
              id: UUID().uuidString, // New ID for this step
              role: .user, // Or .assistant if it's continuing its own thought after tool use
              content: mcpContent, // This might be empty if only sending toolResults
              toolResults: mcpToolResults // Send tool results if available
          )

          await streamDelegate.prepareForNewQuery(
              modelName: modelname,
              messageID: originalMessageID, // Still tied to the original user query's ID for UI
              completionHandler: streamDelegate.onQueryCompleted!, // Re-use existing completion
              toolCallHandler: streamDelegate.onToolCallsDetected! // Re-use existing tool handler
          )

          await MCPServiceManager.shared.streamRequest(
              to: mcpService.name,
              payload: mcpPayload,
              onReceiveChunk: { chunk in streamDelegate.mcpStreamDidReceiveChunk(chunk) },
              onComplete: { error in streamDelegate.mcpStreamDidComplete(error: error) }
          )

      } else {
          // OpenAI Call
          print("Continuing conversation with OpenAI: \(modelname) for originalMsgID: \(originalMessageID)")
          let config = OpenAIConfig.load()
          guard let modelConfig = config.getConfig(for: modelname) else {
              print("Error: Model configuration not found for \(modelname)")
              await streamDelegate.queryDidCompleteWithError(nil, forMessageId: originalMessageID)
              return
          }

          let url = URL(string: "\(modelConfig.baseURL)/chat/completions")!
          var request = URLRequest(url: url)
          request.httpMethod = "POST"
          request.setValue("application/json", forHTTPHeaderField: "Content-Type")
          request.setValue("Bearer \(modelConfig.apiKey)", forHTTPHeaderField: "Authorization")

          // Use the current conversation history for OpenAI
          let messagesToSend = getCurrentConversation() // Includes original user, system, and any tool messages

          // Define tools for OpenAI if any are registered (excluding MCP ones for now, or make them compatible)
          let openAITools = ToolExecutor.shared.availableTools.values
              .filter { $0.type == .localFunction } // Example: only local functions for OpenAI
              .map { OpenAIToolWrapper(type: "function", function: OpenAIFunctionTool(name: $0.name, description: $0.description)) }


          let chatRequest = ChatRequest(
              model: modelname,
              messages: messagesToSend,
              stream: true,
              tools: openAITools.isEmpty ? nil : openAITools,
              tool_choice: openAITools.isEmpty ? nil : "auto" // Let OpenAI decide if/when to use tools
          )

          do {
              let encoder = JSONEncoder()
              // encoder.outputFormatting = .prettyPrinted // For debugging request
              // if let jsonData = try? encoder.encode(chatRequest), let jsonString = String(data: jsonData, encoding: .utf8) {
              //     print("OpenAI Request Body:\n\(jsonString)")
              // }
              request.httpBody = try encoder.encode(chatRequest)
          } catch {
              print("Error encoding OpenAI request: \(error)")
              await streamDelegate.queryDidCompleteWithError(error, forMessageId: originalMessageID)
              return
          }

          await streamDelegate.prepareForNewQuery(
              modelName: modelname,
              messageID: originalMessageID,
              completionHandler: streamDelegate.onQueryCompleted!,
              toolCallHandler: streamDelegate.onToolCallsDetected!
          )

          let sessionConfig = URLSessionConfiguration.default
          // Proxy config (copied from original sendMessage)
          if let proxyEnabled = modelConfig.proxyEnabled, proxyEnabled,
            let proxyURLString = modelConfig.proxyURL, !proxyURLString.isEmpty,
            let proxyComponents = URLComponents(string: proxyURLString),
            let proxyHost = proxyComponents.host,
            let proxyPort = proxyComponents.port {
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
                  print("Unsupported proxy scheme: \(scheme ?? "nil"). Proxy not configured for ReAct OpenAI call.")
                }
          }

          let session = URLSession(configuration: sessionConfig, delegate: streamDelegate, delegateQueue: nil)
          let task = session.dataTask(with: request)
          streamDelegate.currentTask = task
          task.resume()
      }
  }

  private func chatMsgToMCPToolResult(_ message: ChatMessage) -> MCPClient.ToolResult? {
      guard message.role == "tool",
            let toolCallId = message.tool_call_id,
            let toolName = message.name,
            let content = message.content?.textValue else { return nil }
      return MCPClient.ToolResult(id: toolCallId, toolName: toolName, content: content)
  }
}

extension MessageContent {
    var textValue: String? {
        if case .text(let str) = self { return str }
        // Could add logic for multimodal if needed, e.g., join text parts
        return nil
    }
}


// Helper structs for decoding OpenAI stream
struct OpenAIStreamResponse: Decodable {
    let choices: [OpenAIStreamChoice]
}

struct OpenAIStreamChoice: Decodable {
    let delta: OpenAIStreamDelta
    let index: Int
    let finish_reason: String?
}

struct OpenAIStreamDelta: Decodable {
    let role: String?
    let content: String?
    let tool_calls: [OpenAIToolCallChunk]?
}

struct OpenAIToolCallChunk: Decodable {
    let index: Int
    let id: String?
    let type: String?
    let function: OpenAIFunctionCallChunk?
}

struct OpenAIFunctionCallChunk: Decodable {
    let name: String?
    let arguments: String?
}


final class StreamDelegate: NSObject, URLSessionDataDelegate, ObservableObject, @unchecked Sendable {
  @Published var output: AttributedString = ""
  private var currentResponse: String = "" // Aggregates text content for one turn
  private var currentModel: String = ""

  var currentTask: URLSessionDataTask?
  var currentMessageID: String? // ID of the initial user message for the current ReAct turn

  var onQueryCompleted: (() -> Void)?
  var onToolCallsDetected: (([MCPClient.ToolCall], _ messageId: String, _ modelName: String) -> Void)?

  private var isMCPQuery: Bool = false
  private var pendingOpenAIToolCallChunksByIndex: [Int: OpenAIToolCallChunk] = [:]


  override init() {
    super.init()
  }

  @MainActor
  func prepareForNewQuery(
    modelName: String,
    messageID: String,
    completionHandler: @escaping () -> Void,
    toolCallHandler: @escaping ([MCPClient.ToolCall], String, String) -> Void
  ) {
      // Clear UI output *only* if it's a new message ID, or if it's the same ID but not an MCP query (MCP queries might be part of a chain for the same original messageID)
      // More simply, always clear for a new preparation, as any prior output is for a completed turn.
      self.output = AttributedString("")
      self.currentResponse = ""
      self.currentModel = modelName
      self.currentMessageID = messageID
      self.onQueryCompleted = completionHandler
      self.onToolCallsDetected = toolCallHandler
      self.currentTask = nil
      self.isMCPQuery = MCPConfigLoader.shared.getServiceConfig(forName: modelName) != nil
      self.pendingOpenAIToolCallChunksByIndex = [:]
      print("StreamDelegate prepared for new query. Model: \(modelName), ID: \(messageID), IsMCP: \(isMCPQuery)")
  }

  @MainActor
  func displaySystemMessage(_ message: String, isError: Bool = false) {
      var attributedMessage = AttributedString("\n🤖 \(message)\n")
      if isError {
          attributedMessage.foregroundColor = .red
      } else {
          attributedMessage.foregroundColor = .gray // Or .secondary
      }
      attributedMessage.font = .system(.caption, design: .monospaced)
      self.output += attributedMessage
  }


  @MainActor
  func queryDidCompleteWithError(_ error: Error?, forMessageId: String?) {
      guard forMessageId == self.currentMessageID else {
          print("StreamDelegate: queryDidCompleteWithError called for mismatched ID. Current: \(self.currentMessageID ?? "nil"), Received: \(forMessageId ?? "nil"). Ignoring.")
          return
      }

      if let error = error {
          var errorChunk = AttributedString("\nError: \(error.localizedDescription)")
          errorChunk.foregroundColor = .red
          self.output += errorChunk
      }

      self.onQueryCompleted?()

      if self.currentMessageID == forMessageId { // Double check for safety in async context
          self.currentMessageID = nil
          self.currentTask = nil
          self.isMCPQuery = false
          self.pendingOpenAIToolCallChunksByIndex = [:]
          // self.currentResponse is cleared by prepareForNewQuery or after saving.
      }
      print("StreamDelegate: Query (\(forMessageId ?? "N/A")) processing finished.")
  }

  func cancelCurrentQuery() {
    let messageIdToCancel = self.currentMessageID
    print("StreamDelegate: cancelCurrentQuery called for \(messageIdToCancel ?? "N/A")")
    if isMCPQuery {
        print("MCP Query cancellation requested for ID: \(messageIdToCancel ?? "N/A"). (MCPServiceManager needs cancel support)")
    } else {
        currentTask?.cancel()
    }

    DispatchQueue.main.async {
        if self.currentMessageID == messageIdToCancel {
            self.output = AttributedString("")
            let cancelError = NSError(domain: "UserCancellation", code: NSUserCancelledError, userInfo: [NSLocalizedDescriptionKey: "Query cancelled by user."])
            self.queryDidCompleteWithError(cancelError, forMessageId: messageIdToCancel)
        }
    }
  }

  @MainActor
  func mcpStreamDidReceiveChunk(_ chunk: MCPClient.OutputChunk) {
      guard let msgID = self.currentMessageID, msgID == chunk.id, self.isMCPQuery else {
          return
      }

      // Check for tool calls in MCP chunk (if MCPClient.OutputChunk supports this)
      // Example: if let mcpToolCalls = chunk.toolCalls, !mcpToolCalls.isEmpty { ... }
      // For now, assuming MCP tool calls are primarily in the final Output or handled differently.

      var chunkToAppend = chunk.content
      self.currentResponse += chunkToAppend

      var attributedChunk = AttributedString(chunkToAppend)
      self.output += attributedChunk
  }

  @MainActor
  func mcpStreamDidComplete(error: Error?) {
      let completedMessageID = self.currentMessageID
      guard completedMessageID != nil, self.isMCPQuery else {
          print("StreamDelegate: MCP stream completion for an outdated query, ignoring.")
          return
      }
      print("StreamDelegate: MCP Stream for ID \(completedMessageID!) completed. Error: \(error?.localizedDescription ?? "None")")

      // TODO: Check for tool calls in the *final* aggregated MCPClient.Output.
      // This would require MCPServiceManager to provide the full Output object on completion.
      // If (let finalOutput = sdkProvidedFinalOutput), check finalOutput.toolCalls.

      if error == nil {
          if !self.currentResponse.isEmpty {
              let assistantMessage = ChatMessage(
                  role: "assistant",
                  content: .text(self.currentResponse),
                  model: self.currentModel,
                  id: completedMessageID
              )
              ChatHistory.shared.saveMessage(assistantMessage)
          }
      }
      self.queryDidCompleteWithError(error, forMessageId: completedMessageID)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard !isMCPQuery, currentTask == dataTask, let msgID = currentMessageID else {
      return
    }

    if let response = dataTask.response as? HTTPURLResponse, response.statusCode >= 400 {
        if let errorText = String(data: data, encoding: .utf8) {
            DispatchQueue.main.async { self.currentResponse += "\nHTTP Error \(response.statusCode): \(errorText)" }
        } else {
             DispatchQueue.main.async { self.currentResponse += "\nHTTP Error \(response.statusCode)" }
        }
        // Let didCompleteWithError handle full error state.
        return
    }

    let lines = String(data: data, encoding: .utf8)?.components(separatedBy: "\n") ?? []
    for line in lines {
      if line.hasPrefix("data: "), let jsonData = line.dropFirst(6).data(using: .utf8) {
        if line.contains("data: [DONE]") {
          processPendingOpenAIToolCalls(messageId: msgID, modelName: self.currentModel)
          return
        }

        do {
          let decoder = JSONDecoder()
          let streamResponse = try decoder.decode(OpenAIStreamResponse.self, from: jsonData)

          guard let choice = streamResponse.choices.first else { continue }
          let delta = choice.delta

          if let newToolCallChunks = delta.tool_calls {
            for chunk in newToolCallChunks {
                // Aggregate tool call chunks by their index
                let index = chunk.index
                var currentAggregatedChunk = self.pendingOpenAIToolCallChunksByIndex[index] ?? OpenAIToolCallChunk(index: index, id: nil, type: nil, function: nil)

                if let newId = chunk.id { currentAggregatedChunk.id = newId }
                if let newType = chunk.type { currentAggregatedChunk.type = newType }

                var funcName = currentAggregatedChunk.function?.name ?? chunk.function?.name
                var funcArgs = currentAggregatedChunk.function?.arguments ?? ""

                if let newFuncName = chunk.function?.name, funcName == nil { funcName = newFuncName } // Take first non-nil name
                if let newArgChunk = chunk.function?.arguments { funcArgs += newArgChunk }

                currentAggregatedChunk.function = OpenAIFunctionCallChunk(name: funcName, arguments: funcArgs)
                self.pendingOpenAIToolCallChunksByIndex[index] = currentAggregatedChunk
            }
          }

          if let contentChunk = delta.content, !contentChunk.isEmpty {
            DispatchQueue.main.async {
              guard self.currentMessageID == msgID else { return }
              self.currentResponse += contentChunk
              self.output += AttributedString(contentChunk)
            }
          }

          if choice.finish_reason == "tool_calls" {
              processPendingOpenAIToolCalls(messageId: msgID, modelName: self.currentModel)
          }

        } catch {
           print("StreamDelegate: Error parsing OpenAI JSON line: \(line), Error: \(error.localizedDescription)")
        }
      }
    }
  }

  private func processPendingOpenAIToolCalls(messageId: String, modelName: String) {
      if !pendingOpenAIToolCallChunksByIndex.isEmpty {
          let finalToolCalls = pendingOpenAIToolCallChunksByIndex.values.compactMap { aggregatedChunk -> MCPClient.ToolCall? in
              guard let type = aggregatedChunk.type, type == "function",
                    let id = aggregatedChunk.id,
                    let function = aggregatedChunk.function,
                    let name = function.name,
                    let arguments = function.arguments else {
                  print("StreamDelegate: Skipping incomplete tool call chunk after aggregation: \(aggregatedChunk)")
                  return nil
              }
              // Ensure arguments are a complete JSON string, might need validation if critical
              return MCPClient.ToolCall(id: id, toolName: name, args: arguments)
          }.sorted(by: { $0.id < $1.id }) // Sort by ID for deterministic order if needed, though OpenAI index was key

          DispatchQueue.main.async {
              if !finalToolCalls.isEmpty {
                  print("StreamDelegate: Processing fully formed OpenAI tool calls: \(finalToolCalls.map { $0.toolName }) for msgID: \(messageId)")
                  // It's crucial that currentResponse is cleared if tool calls are dispatched,
                  // as the assistant's turn was to call tools, not to say something.
                  self.currentResponse = ""
                  self.output = AttributedString("") // Clear UI output as well
                  self.onToolCallsDetected?(finalToolCalls, messageId, modelName)
              }
              self.pendingOpenAIToolCallChunksByIndex = [:]
          }
      }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    let completedMessageID = self.currentMessageID
    guard !isMCPQuery, (currentTask == task || completedMessageID != nil) else {
      return
    }
    print("StreamDelegate: OpenAI URLSession for ID \(completedMessageID ?? "N/A") didComplete. Error: \(error?.localizedDescription ?? "None")")

    DispatchQueue.main.async {
        // Fallback processing for tool calls if stream ended abruptly
        if error != nil && !self.pendingOpenAIToolCallChunksByIndex.isEmpty {
             self.processPendingOpenAIToolCalls(messageId: completedMessageID!, modelName: self.currentModel)
        }

        // If tool calls were processed (onToolCallsDetected was called), currentResponse should be empty.
        // Only save a text message if there's content and no tool calls took precedence.
        if error == nil && !self.currentResponse.isEmpty {
            let assistantMessage = ChatMessage(
                role: "assistant",
                content: .text(self.currentResponse),
                model: self.currentModel,
                id: completedMessageID
            )
            ChatHistory.shared.saveMessage(assistantMessage)
        }
        // If tool calls were detected and onToolCallsDetected was called,
        // the ReAct loop continues from ChatHistory/App. onQueryCompleted here signals the end of *this specific network request*.
        // The overall "query" from the user's perspective might still be ongoing via tool execution.
        // The `onQueryCompleted` from `prepareForNewQuery` is for the *final* resolution of the user's turn.
        // If tool calls were made, the `onQueryCompleted` here should perhaps not be the final one,
        // but rather the ReAct loop itself will eventually call the original `onQueryCompleted` via `App.queryDidComplete`.
        // This is subtle: if tools are called, `onToolCallsDetected` is the key outcome of this network op.
        // If no tools, then `onQueryCompleted` (via `queryDidCompleteWithError`) is.

        // If onToolCallsDetected was called, it means the ReAct loop is now active.
        // queryDidCompleteWithError will call the App's onQueryCompleted, which might be premature if tools are running.
        // This needs careful handling in the App struct.
        // For now, let queryDidCompleteWithError always call onQueryCompleted.
        // The App struct will need to manage its `isQueryActive` state based on whether it's waiting for text or tool results.

        self.queryDidCompleteWithError(error, forMessageId: completedMessageID)
    }
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
  @State private var isQueryActive: Bool = false // Represents overall query activity, including ReAct loops
  // Removed currentMessageID from App state, ChatHistory and StreamDelegate manage it per turn.

  init() {
    MCPConfigLoader.shared.loadConfig()
    ToolExecutor.shared.registerMCPTools()
    // print("Available tools for LLM: \(ToolExecutor.shared.getAvailableToolsDescriptionForLLM())")
  }

  var body: some Scene {
    WindowGroup {
      VStack(alignment: .leading) {
        HStack {
          ModelMenuView(modelname: $modelname)
          PromptMenuView(selectedPrompt: $selectedPrompt)
          FileUploadButton(selectedFileName: $selectedFileName) { fileURL in self.selectedFileURL = fileURL }
        }
        .offset(x: 0, y: 5)
        .ignoresSafeArea()
        .frame(maxWidth: .infinity, maxHeight: 0, alignment: .trailing)

        LLMInputView
        Divider()

        if !streamDelegate.output.characters.isEmpty || isQueryActive { // Show output area if streaming or query active (e.g. thinking)
          LLMOutputView
        } else {
          Spacer(minLength: 20)
        }
      }
      .background(VisualEffect().ignoresSafeArea())
      .frame(minWidth: 400, minHeight: 150, alignment: .topLeading)
      .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
        MCPServiceManager.shared.cleanup() // Cleanup MCP services
        exit(0)
      }
      .onAppear { focused = true }
    }
    .windowStyle(HiddenTitleBarWindowStyle())
    .defaultSize(width: 0.5, height: 1.0)
  }

  private var LLMInputView: some View {
    HStack {
      Button(action: {
        if isQueryActive {
          streamDelegate.cancelCurrentQuery() // This will eventually call queryDidComplete
          // isQueryActive will be set to false by queryDidComplete
        } else {
          if !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedFileURL != nil {
            isQueryActive = true // Set active immediately for UI feedback
            Task {
              await submitInput()
            }
          }
        }
      }) {
        Text(isQueryActive ? "\u{25A0}" : "\u{1F3B2}") // Square for stop, Dice for send
          .foregroundColor(.white)
          .cornerRadius(5)
      }
      .buttonStyle(PlainButtonStyle())
      .rotationEffect(isQueryActive && streamDelegate.currentTask != nil ? .degrees(360) : .degrees(0)) // Rotate only for network activity
      .animation(isQueryActive && streamDelegate.currentTask != nil ? Animation.linear(duration: 2.0).repeatForever(autoreverses: false) : .default, value: isQueryActive && streamDelegate.currentTask != nil)

      TextField("write something..", text: $input, axis: .vertical)
        .lineLimit(1...5)
        .textFieldStyle(.plain)
        .focused($focused)
        .onSubmit {
          if !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedFileURL != nil {
            if !isQueryActive { // Prevent submit if already active, let cancel button handle it
                isQueryActive = true
                Task { await submitInput() }
            }
          }
        }
    }
    .padding(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
  }

  private func submitInput() async {
    let newMessageID = UUID().uuidString // Unique ID for this entire interaction turn

    let textToSend = self.input
    let fileURLToSend = self.selectedFileURL

    // Clear input fields immediately after capturing values
    self.input = ""
    self.selectedFileURL = nil
    self.selectedFileName = nil

    var messageContent: MessageContent? = nil
    if let url = fileURLToSend {
      messageContent = await ChatHistory.shared.handleFileUpload(fileURL: url, associatedText: textToSend.isEmpty ? nil : textToSend)
      if messageContent == nil {
          print("Error processing file upload, message not sent.")
          queryDidComplete() // Reset UI state
          return
      }
    } else if !textToSend.isEmpty {
        messageContent = .text(textToSend)
    } else {
        print("No input provided.")
        queryDidComplete() // Reset UI state if nothing to send
        return
    }

    // Use the new sendInitialMessage which also handles conversation history for ReAct
    await ChatHistory.shared.sendInitialMessage(
        userText: textToSend.isEmpty && fileURLToSend != nil ? nil : textToSend, // Pass textToSend only if it's primary or associated
        messageContent: messageContent,
        modelname: modelname,
        selectedPromptName: selectedPrompt, // Pass the actual selected prompt string
        streamDelegate: streamDelegate,
        messageID: newMessageID
    )
  }

  // This is the primary completion handler for a turn (text response or final error)
  func queryDidComplete() {
    print("App: queryDidComplete called. Setting isQueryActive to false.")
    isQueryActive = false
  }

  // This is the handler for when StreamDelegate detects tool calls
  func handleDetectedToolCalls(toolCalls: [MCPClient.ToolCall], messageId: String, modelName: String) {
    print("App: handleDetectedToolCalls for msgID \(messageId). Count: \(toolCalls.count)")

    let toolNames = toolCalls.map { $0.toolName }.joined(separator: ", ")
    DispatchQueue.main.async {
        streamDelegate.displaySystemMessage("Using tool(s): \(toolNames)...")
    }

    Task {
        var toolResults: [ChatMessage] = []
        for toolCall in toolCalls {
            let mcpToolResult = await ToolExecutor.shared.executeToolCall(toolCall)
            // Convert MCPClient.ToolResult to ChatMessage for OpenAI or further processing
            let toolMessage = ChatMessage(
                role: "tool",
                content: .text(mcpToolResult.content), // OpenAI expects result in content for tool role
                id: UUID().uuidString, // New message ID for this tool result
                tool_call_id: mcpToolResult.id, // Link to the original tool call
                name: mcpToolResult.toolName
            )
            toolResults.append(toolMessage)
        }

        // Continue the conversation with the tool results
        // isQueryActive remains true because we are in a ReAct loop
        await ChatHistory.shared.continueConversation(
            modelname: modelName, // Send back to the same model that asked for tools
            streamDelegate: streamDelegate,
            originalMessageID: messageId, // Tie back to the original user message ID
            toolResults: toolResults
        )
    }
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
  // TODO: Populate this with MCP services/tools as well
  private var models: [String] { // Make it computed to refresh if config changes
      let openAIModels = OpenAIConfig.load().models.values.flatMap { $0.models }
      let mcpServiceNames = MCPConfigLoader.shared.getMCPServiceConfigs().map { $0.name }
      return (openAIModels + mcpServiceNames).sorted()
  }
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
            // Also need to clear the underlying selectedFileURL in App state if this button is to fully manage it.
            // For now, assumes App struct handles clearing selectedFileURL when selectedFileName is nilled.
          }
      }
    }
    .padding(.trailing, 4)
    .fileImporter(
      isPresented: $isFilePickerPresented,
      allowedContentTypes: [.image, .plainText, .video, .audio], // Expanded for more tool types
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
      var config = try decoder.decode(OpenAIConfig.self, from: data)

      if config.getConfig(for: config.defaultModel) == nil {
        print("Warning: Default model '\(config.defaultModel)' not found in config. Falling back.")
        if let firstModelProvider = config.models.first?.value, let firstModelName = firstModelProvider.models.first {
            config.defaultModel = firstModelName
             print("Using fallback model: \(firstModelName)")
        } else {
            print("Error: No models found in config to use as fallback. App might not function correctly.")
            // Return a truly default config if everything fails
            return OpenAIConfig(models: ["default": ModelConfig(baseURL: "https://api.openai.com/v1", apiKey: "YOUR_API_KEY", models: ["gpt-3.5-turbo"], proxyEnabled: false, proxyURL: nil)], defaultModel: "gpt-3.5-turbo")
        }
      }
      return config

    } catch {
      print("Error loading config: \(error). Using default minimal configuration.")
      return OpenAIConfig(models: ["default": ModelConfig(baseURL: "https://api.openai.com/v1", apiKey: "YOUR_API_KEY", models: ["gpt-3.5-turbo"], proxyEnabled: false, proxyURL: nil)], defaultModel: "gpt-3.5-turbo")
    }
  }

  func getConfig(for model: String) -> ModelConfig? {
    for (_, config) in models {
      if config.models.contains(model) {
        return config
      }
    }
    // print("Warning: Configuration for model '\(model)' not found in OpenAIConfig.") // Less noisy
    return nil
  }
}

App.main()
