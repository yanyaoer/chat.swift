#!/usr/bin/env xcrun -sdk macosx swift

import AppKit
import Foundation
import SwiftUI
import MCP // Ensure MCP SDK is imported

// class AppDelegate, struct VisualEffect ... (Keep existing unchanged)
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

// struct ChatMessage, OpenAIToolCall, OpenAIFunctionCall ... (Keep existing unchanged)
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
  let tools: [OpenAIToolWrapper]?
  let tool_choice: String?


  init(model: String, messages: [ChatMessage], stream: Bool, tools: [OpenAIToolWrapper]? = nil, tool_choice: String? = "auto") {
      self.model = model
      self.messages = messages
      self.stream = stream
      self.tools = tools
      self.tool_choice = tool_choice
  }
}

struct OpenAIToolWrapper: Codable {
    let type: String
    let function: OpenAIFunctionTool
}
struct OpenAIFunctionTool: Codable {
    let name: String
    let description: String
    // let parameters: [String: Any]? // Proper JSON Schema for parameters
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
  @AppStorage("selectedPrompt") private var selectedPromptString: String = "" // Renamed to avoid conflict

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
    let supportedImageTypes = ["jpg", "jpeg", "png", "gif", "webp"] // Keep this or expand based on tool needs

    guard fileURL.startAccessingSecurityScopedResource() else {
      print("ChatHistory: Failed to access the file at \(fileURL.path)")
      return nil
    }
    defer { fileURL.stopAccessingSecurityScopedResource() }

    do {
      let fileData = try Data(contentsOf: fileURL)
      // For images, continue as before. For other types, decide representation.
      // E.g., for video/audio, might just pass path or a placeholder if content too large.
      if supportedImageTypes.contains(fileType) {
          let base64String = fileData.base64EncodedString()
          let mimeType: String
          switch fileType {
            case "jpg", "jpeg": mimeType = "image/jpeg"
            case "png": mimeType = "image/png"
            // ... other image types
            default: mimeType = "application/octet-stream"
          }
          let imageUrl = "data:\(mimeType);base64,\(base64String)"
          var contentItems = [ContentItem]()
          if let text = associatedText, !text.isEmpty { contentItems.append(ContentItem(type: "text", text: text, image_url: nil)) }
          contentItems.append(ContentItem(type: "image_url", text: nil, image_url: ImageURL(url: imageUrl)))
          return .multimodal(contentItems)
      } else { // For non-image files, perhaps just use text part or a special ContentItem
          var textForFile = "[File: \(fileURL.lastPathComponent)]"
          if let assocText = associatedText, !assocText.isEmpty { textForFile = "\(assocText)\n\(textForFile)"}
          return .text(textForFile) // Simplified: tools would need actual path or data
      }
    } catch {
      print("ChatHistory: Error reading or encoding file: \(error.localizedDescription)")
      return nil
    }
  }

  func getAvailablePrompts() async -> [String] {
    do {
      let files = try FileManager.default.contentsOfDirectory(atPath: promptsPath.path)
      return files.filter { $0.hasSuffix(".md") }.map { String($0.dropLast(3)) }.sorted()
    } catch { return [] }
  }

  func loadPromptContent(name: String) -> SystemPrompt? {
    let fileURL = promptsPath.appendingPathComponent("\(name).md")
    do {
      let content = try String(contentsOf: fileURL)
      return SystemPrompt(role: "system", content: content)
    } catch { return nil }
  }

  func saveMessage(_ message: ChatMessage) {
    currentConversation.append(message)

    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let timestamp = dateFormatter.string(from: message.timestamp)
    let modelInfo = message.model.map { " [\($0)]" } ?? ""
    let idInfo = message.id.map { " [ID: \($0)]" } ?? ""

    var contentText = ""
    if let msgContent = message.content {
        switch msgContent {
        case .text(let text): contentText = text
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
        contentText = "Tool Calls Requested:\n" + toolCalls.map { tc in
            "  ID: \(tc.id)\n  Function: \(tc.function.name)\n  Args: \(tc.function.arguments.prefix(100))..."
        }.joined(separator: "\n")
    } else if message.role == "tool" {
        contentText = "Tool Result for \(message.name ?? "unknown tool") (Call ID: \(message.tool_call_id ?? "unknown")): \n\(message.content?.textValue ?? "[No textual result content from tool]")"
    }

    let textToSave = "\n\n[\(timestamp)] \(message.role.uppercased())\(modelInfo)\(idInfo):\n\(contentText)"
    if let data = textToSave.data(using: .utf8) {
      if FileManager.default.fileExists(atPath: historyPath.path) {
        if let handle = try? FileHandle(forWritingTo: historyPath) {
          handle.seekToEndOfFile(); handle.write(data); handle.closeFile()
        }
      } else { try? data.write(to: historyPath) }
    }
  }

  func clearConversationHistory() { currentConversation = [] }
  func getCurrentConversation() -> [ChatMessage] { return currentConversation }

  func sendInitialMessage(
    userText: String?, messageContent: MessageContent?, modelname: String,
    selectedPromptName: String, streamDelegate: StreamDelegate, messageID: String,
    onQueryCompletedCallback: @escaping () -> Void, // Added callback
    onToolCallsDetectedCallback: @escaping ([AppToolCall], String, String) -> Void // Added callback
  ) async {
    clearConversationHistory()

    var systemMessageText: String? = nil
    if !selectedPromptName.isEmpty, selectedPromptName != "None", let prompt = loadPromptContent(name: selectedPromptName) {
        systemMessageText = prompt.content
    }

    if MCPConfigLoader.shared.getServiceConfig(forName: modelname) == nil { // OpenAI or similar
        let toolsDescriptionJson = ToolExecutor.shared.getAvailableToolsDescriptionForLLM()
        // Only add tool descriptions if there are any tools AND it's an OpenAI model.
        if toolsDescriptionJson != "[]" {
            let toolsPreamble = "\n\nYou have access to the following tools. Use them when appropriate by responding with a `tool_calls` JSON object. The arguments should be a JSON string matching the tool's parameter schema, if provided. Only call tools if you have all necessary information for their arguments. If you need more information from the user before calling a tool, ask the user first."
            if systemMessageText != nil {
                systemMessageText! += "\(toolsPreamble)\nTools:\n\(toolsDescriptionJson)"
            } else {
                systemMessageText = "\(toolsPreamble)\nTools:\n\(toolsDescriptionJson)"
            }
        }
    }

    if let sysContent = systemMessageText {
        let systemMessage = ChatMessage(role: "system", content: .text(sysContent), id: UUID().uuidString)
        currentConversation.append(systemMessage)
    }

    let finalUserContent: MessageContent
    if let content = messageContent { finalUserContent = content }
    else if let text = userText, !text.isEmpty { finalUserContent = .text(text) }
    else {
      print("ChatHistory: No message content for initial message.")
      await streamDelegate.queryDidCompleteWithError(NSError(domain: "ChatHistory", code: 1, userInfo: [NSLocalizedDescriptionKey: "No content to send."]), forMessageId: messageID)
      return
    }
    let userMessage = ChatMessage(role: "user", content: finalUserContent, model: modelname, id: messageID)
    saveMessage(userMessage)

    await continueConversation(
        modelname: modelname, streamDelegate: streamDelegate, originalMessageID: messageID,
        onQueryCompletedCallback: onQueryCompletedCallback,
        onToolCallsDetectedCallback: onToolCallsDetectedCallback
    )
  }

  func continueConversation(
      modelname: String, streamDelegate: StreamDelegate, originalMessageID: String,
      toolResults: [ChatMessage]? = nil,
      onQueryCompletedCallback: @escaping () -> Void, // Added callback
      onToolCallsDetectedCallback: @escaping ([AppToolCall], String, String) -> Void // Added callback
  ) async {
      if let results = toolResults { results.forEach { saveMessage($0) } }

      // Prepare StreamDelegate for the next part of the conversation
      // This is crucial for setting the correct callbacks for this turn.
      await streamDelegate.prepareForNewQuery(
          modelName: modelname, messageID: originalMessageID,
          completionHandler: onQueryCompletedCallback,
          toolCallHandler: onToolCallsDetectedCallback
      )

      if let mcpService = MCPConfigLoader.shared.getServiceConfig(forName: modelname) {
          print("ChatHistory: Calling MCP Service '\(mcpService.name)' for originalMsgID: \(originalMessageID)")

          // Determine the "chat" tool for this MCP service. Convention: first tool listed, or one named "chat".
          let chatToolName = mcpService.tools?.first(where: { $0.lowercased() == "chat" || $0.lowercased() == "generate_text"}) ?? mcpService.tools?.first

          guard let toolToCallOnMCP = chatToolName else {
              print("ChatHistory: No suitable 'chat' tool found for MCP service '\(mcpService.name)'. Cannot proceed with chat.")
              await streamDelegate.mcpChatToolDidComplete(messageId: originalMessageID, responseText: "[Error: No chat tool configured for this MCP service]", error: MCPError.invalidConfiguration("No chat tool for \(mcpService.name)"))
              return
          }

          var argumentsForMCPChat: [String: Any] = [:]
          // Simple approach: send last user message text as "prompt" arg, or entire history if tool supports "messages"
          if let lastUserMsg = currentConversation.last(where: {$0.role == "user" || $0.role == "tool"})?.content?.textValue { // Also consider last tool result as prompt
              argumentsForMCPChat["prompt"] = lastUserMsg
          } else {
               argumentsForMCPChat["prompt"] = "" // Default empty prompt
          }
          // A more robust solution would be to format `currentConversation` into what the MCP chat tool expects.
          // For now, just sending the last text content as a "prompt".

          do {
              let mcpClient = try await MCPServiceManager.shared.getClient(for: mcpService.name)
              let (contentItems, isError) = try await mcpClient.callTool(name: toolToCallOnMCP, arguments: argumentsForMCPChat.compactMapValues { MCP.Value(anyValue: $0) })

              // Since client.callTool is non-streaming for its content, we process the full result here.
              // StreamDelegate's mcp... methods will be called with the full result.
              await streamDelegate.mcpChatToolDidComplete(messageId: originalMessageID, contentItems: contentItems, isError: isError, error: nil)

          } catch {
              print("ChatHistory: Error calling MCP service '\(mcpService.name)' tool '\(toolToCallOnMCP)': \(error)")
              await streamDelegate.mcpChatToolDidComplete(messageId: originalMessageID, contentItems: nil, isError: true, error: error)
          }

      } else { // OpenAI or similar LLM
          print("ChatHistory: Continuing conversation with OpenAI model '\(modelname)' for originalMsgID: \(originalMessageID)")
          let config = OpenAIConfig.load()
          guard let modelConfig = config.getConfig(for: modelname) else {
              print("ChatHistory: OpenAI Model configuration not found for \(modelname)")
              await streamDelegate.queryDidCompleteWithError(MCPError.invalidConfiguration("OpenAI model config not found"), forMessageId: originalMessageID)
              return
          }

          let url = URL(string: "\(modelConfig.baseURL)/chat/completions")!
          var request = URLRequest(url: url)
          request.httpMethod = "POST"
          request.setValue("application/json", forHTTPHeaderField: "Content-Type")
          request.setValue("Bearer \(modelConfig.apiKey)", forHTTPHeaderField: "Authorization")

          let messagesToSend = getCurrentConversation()
          let toolsJsonString = ToolExecutor.shared.getAvailableToolsDescriptionForLLM()
          var openAITools: [OpenAIToolWrapper]? = nil
          if let toolsData = toolsJsonString.data(using: .utf8) {
              do {
                  openAITools = try JSONDecoder().decode([OpenAIToolWrapper].self, from: toolsData)
              } catch {
                  print("ChatHistory: Error decoding tool descriptions JSON: \(error). Tools will not be sent.")
              }
          }

          let chatRequest = ChatRequest(
              model: modelname, messages: messagesToSend, stream: true,
              tools: (openAITools?.isEmpty ?? true) ? nil : openAITools,
              tool_choice: (openAITools?.isEmpty ?? true) ? nil : "auto"
          )

          do {
              request.httpBody = try JSONEncoder().encode(chatRequest)
          } catch {
              print("ChatHistory: Error encoding OpenAI request: \(error)")
              await streamDelegate.queryDidCompleteWithError(error, forMessageId: originalMessageID)
              return
          }

          let sessionConfig = URLSessionConfiguration.default
          if let proxyEnabled = modelConfig.proxyEnabled, proxyEnabled,
             let proxyURLString = modelConfig.proxyURL, !proxyURLString.isEmpty,
             let proxyComponents = URLComponents(string: proxyURLString),
             let proxyHost = proxyComponents.host, let proxyPort = proxyComponents.port {
                let scheme = proxyComponents.scheme?.lowercased()
                // (Proxy setup as before)
                switch scheme {
                case "socks5":
                  sessionConfig.connectionProxyDictionary = [kCFNetworkProxiesSOCKSEnable: true, kCFNetworkProxiesSOCKSProxy: proxyHost, kCFNetworkProxiesSOCKSPort: proxyPort, kCFStreamPropertySOCKSVersion: kCFStreamSocketSOCKSVersion5]
                case "http":
                  sessionConfig.connectionProxyDictionary = [kCFNetworkProxiesHTTPEnable: true, kCFNetworkProxiesHTTPProxy: proxyHost, kCFNetworkProxiesHTTPPort: proxyPort]
                case "https":
                  sessionConfig.connectionProxyDictionary = [kCFNetworkProxiesHTTPSEnable: true, kCFNetworkProxiesHTTPSProxy: proxyHost, kCFNetworkProxiesHTTPSPort: proxyPort]
                default: print("Unsupported proxy scheme: \(scheme ?? "nil").")
                }
          }

          let session = URLSession(configuration: sessionConfig, delegate: streamDelegate, delegateQueue: nil)
          streamDelegate.currentTask = session.dataTask(with: request)
          streamDelegate.currentTask?.resume()
      }
  }
}

extension MessageContent {
    var textValue: String? {
        if case .text(let str) = self { return str }
        if case .multimodal(let items) = self {
            return items.compactMap { $0.text }.joined(separator: "\n")
        }
        return nil
    }
}


// Helper structs for decoding OpenAI stream
struct OpenAIStreamResponse: Decodable { let choices: [OpenAIStreamChoice] }
struct OpenAIStreamChoice: Decodable { let delta: OpenAIStreamDelta; let index: Int; let finish_reason: String? }
struct OpenAIStreamDelta: Decodable { let role: String?; let content: String?; let tool_calls: [OpenAIToolCallChunk]? }
struct OpenAIToolCallChunk: Decodable { let index: Int; let id: String?; let type: String?; let function: OpenAIFunctionCallChunk? }
struct OpenAIFunctionCallChunk: Decodable { let name: String?; let arguments: String? }


final class StreamDelegate: NSObject, URLSessionDataDelegate, ObservableObject, @unchecked Sendable {
  @Published var output: AttributedString = ""
  private var currentResponse: String = ""
  private var currentModel: String = ""
  var currentTask: URLSessionDataTask?
  var currentMessageID: String?
  var onQueryCompleted: (() -> Void)?
  var onToolCallsDetected: (([AppToolCall], _ messageId: String, _ modelName: String) -> Void)?
  private var isMCPQuery: Bool = false
  private var pendingOpenAIToolCallChunksByIndex: [Int: OpenAIToolCallChunk] = [:]

  override init() { super.init() }

  @MainActor
  func prepareForNewQuery( modelName: String, messageID: String,
                           completionHandler: @escaping () -> Void,
                           toolCallHandler: @escaping ([AppToolCall], String, String) -> Void ) {
      self.output = AttributedString("")
      self.currentResponse = ""
      self.currentModel = modelName
      self.currentMessageID = messageID
      self.onQueryCompleted = completionHandler
      self.onToolCallsDetected = toolCallHandler
      self.currentTask = nil
      self.isMCPQuery = MCPConfigLoader.shared.getServiceConfig(forName: modelName) != nil
      self.pendingOpenAIToolCallChunksByIndex = [:]
      print("StreamDelegate: Prepared for new query. Model: \(modelName), ID: \(messageID), IsMCP: \(isMCPQuery)")
  }

  @MainActor
  func displaySystemMessage(_ message: String, isError: Bool = false) {
      var attributedMessage = AttributedString("\n🤖 \(message)\n")
      attributedMessage.foregroundColor = isError ? .red : .gray
      attributedMessage.font = .system(.caption, design: .monospaced)
      self.output += attributedMessage
  }

  @MainActor
  func queryDidCompleteWithError(_ error: Error?, forMessageId: String?) {
      guard forMessageId == self.currentMessageID else {
          print("StreamDelegate: queryDidCompleteWithError called for mismatched ID. Current: \(self.currentMessageID ?? "nil"), Target: \(forMessageId ?? "nil"). Ignoring.")
          return
      }
      if let error = error, (error as NSError).code != NSUserCancelledError {
          self.output += AttributedString("\nError: \(error.localizedDescription)", attributes: AttributeContainer().foregroundColor(.red))
      }
      self.onQueryCompleted?()
      if self.currentMessageID == forMessageId { self.resetStateAfterQuery() }
      print("StreamDelegate: Query (\(forMessageId ?? "N/A")) processing finished.")
  }

  @MainActor
  private func resetStateAfterQuery() {
      self.currentMessageID = nil
      self.currentTask = nil
      self.isMCPQuery = false
      self.pendingOpenAIToolCallChunksByIndex = [:]
      self.currentResponse = "" // Clear aggregated response after it's handled/saved
  }

  func cancelCurrentQuery() {
    let messageIdToCancel = self.currentMessageID
    print("StreamDelegate: cancelCurrentQuery called for \(messageIdToCancel ?? "N/A")")
    if isMCPQuery {
        print("MCP Query cancellation requested for ID: \(messageIdToCancel ?? "N/A").")
         DispatchQueue.main.async {
            if self.currentMessageID == messageIdToCancel { // Check again inside async
                self.output = AttributedString("")
                let cancelError = NSError(domain: "UserCancellation", code: NSUserCancelledError, userInfo: [NSLocalizedDescriptionKey: "Query cancelled by user."])
                self.queryDidCompleteWithError(cancelError, forMessageId: messageIdToCancel)
            }
        }
    } else {
        currentTask?.cancel()
    }
  }

  @MainActor
  func mcpChatToolDidComplete(messageId: String, contentItems: [MCP.ContentItem]?, isError: Bool, error: Error?) {
      guard self.currentMessageID == messageId, self.isMCPQuery else {
          print("StreamDelegate: mcpChatToolDidComplete for outdated query \(messageId), current is \(self.currentMessageID ?? "nil"). Ignoring.")
          return
      }
      print("StreamDelegate: MCP Chat Tool for ID \(messageId) completed. Error: \(error?.localizedDescription ?? "None"), IsErrorFlag: \(isError)")

      if let e = error {
          self.currentResponse = e.localizedDescription
          self.queryDidCompleteWithError(e, forMessageId: messageId)
          return
      }

      if isError {
          let errorText = contentItems?.compactMap { item -> String? in if case .text(let text) = item { return text } else { return nil } }.joined(separator: "\n") ?? "Unknown tool error"
          self.currentResponse = errorText
          self.queryDidCompleteWithError(MCPError.requestFailed("MCP tool reported an error: \(errorText)"), forMessageId: messageId)
          return
      }

      if let items = contentItems {
          self.currentResponse = items.compactMap { item -> String? in
              if case .text(let text) = item { return text }
              return "[Non-text content item received from MCP chat tool]"
          }.joined(separator: "\n")

          if !self.currentResponse.isEmpty {
              let assistantMessage = ChatMessage(role: "assistant", content: .text(self.currentResponse), model: self.currentModel, id: messageId)
              ChatHistory.shared.saveMessage(assistantMessage)
              self.output = AttributedString(self.currentResponse) // Display full response
          } else {
             self.currentResponse = "[Empty successful response from MCP chat tool]"
             self.output = AttributedString(self.currentResponse)
          }
      } else {
         self.currentResponse = "[No content items from MCP chat tool]"
         self.output = AttributedString(self.currentResponse)
      }
      self.queryDidCompleteWithError(nil, forMessageId: messageId)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard !isMCPQuery, currentTask == dataTask, let msgID = currentMessageID else { return }

    if let response = dataTask.response as? HTTPURLResponse, response.statusCode >= 400 {
        var errorText = "\nHTTP Error \(response.statusCode)"
        if let errBody = String(data: data, encoding: .utf8), !errBody.isEmpty { errorText += ": \(errBody)" }
        DispatchQueue.main.async { if self.output.characters.isEmpty { self.output += AttributedString(errorText) } }
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
          let streamResponse = try JSONDecoder().decode(OpenAIStreamResponse.self, from: jsonData)
          guard let choice = streamResponse.choices.first else { continue }
          let delta = choice.delta
          if let newChunks = delta.tool_calls {
            for chunk in newChunks {
                var aggChunk = self.pendingOpenAIToolCallChunksByIndex[chunk.index] ?? OpenAIToolCallChunk(index: chunk.index, id: nil, type: nil, function: nil)
                if let id = chunk.id { aggChunk.id = id }
                if let type = chunk.type { aggChunk.type = type }
                var fName = aggChunk.function?.name ?? chunk.function?.name
                var fArgs = aggChunk.function?.arguments ?? ""
                if let newFName = chunk.function?.name, fName == nil { fName = newFName }
                if let newFArgs = chunk.function?.arguments { fArgs += newFArgs }
                aggChunk.function = OpenAIFunctionCallChunk(name: fName, arguments: fArgs)
                self.pendingOpenAIToolCallChunksByIndex[chunk.index] = aggChunk
            }
          }
          if let content = delta.content, !content.isEmpty {
            DispatchQueue.main.async {
              guard self.currentMessageID == msgID else { return }
              self.currentResponse += content
              self.output += AttributedString(content)
            }
          }
          if choice.finish_reason == "tool_calls" { processPendingOpenAIToolCalls(messageId: msgID, modelName: self.currentModel) }
        } catch { print("StreamDelegate: OpenAI JSON parse error: \(error.localizedDescription) for line: \(line)") }
      }
    }
  }

  private func processPendingOpenAIToolCalls(messageId: String, modelName: String) {
      if !pendingOpenAIToolCallChunksByIndex.isEmpty {
          let finalAppToolCalls = pendingOpenAIToolCallChunksByIndex.values.compactMap { aggChunk -> AppToolCall? in
              guard let type = aggChunk.type, type == "function", let id = aggChunk.id,
                    let function = aggChunk.function, let name = function.name, let args = function.arguments else { return nil }
              return AppToolCall(id: id, toolName: name, args: args)
          }.sorted(by: { $0.id < $1.id })

          DispatchQueue.main.async {
              if !finalAppToolCalls.isEmpty {
                  print("StreamDelegate: Dispatching OpenAI tool calls: \(finalAppToolCalls.map { $0.toolName }) for msgID: \(messageId)")
                  self.currentResponse = ""; self.output = AttributedString("")
                  self.onToolCallsDetected?(finalAppToolCalls, messageId, modelName)
              }
              self.pendingOpenAIToolCallChunksByIndex = [:]
          }
      }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    let completedMessageID = self.currentMessageID
    guard !isMCPQuery, (currentTask == task || completedMessageID != nil) else { return }
    print("StreamDelegate: OpenAI URLSession for ID \(completedMessageID ?? "N/A") didComplete. Error: \(error?.localizedDescription ?? "None")")

    DispatchQueue.main.async {
        let wasCancelled = (error as NSError?)?.code == NSUserCancelledError
        if !wasCancelled && !self.pendingOpenAIToolCallChunksByIndex.isEmpty { // Process if error OR normal completion with pending
             self.processPendingOpenAIToolCalls(messageId: completedMessageID!, modelName: self.currentModel)
        }
        if error == nil && !self.currentResponse.isEmpty {
            ChatHistory.shared.saveMessage(ChatMessage(role: "assistant", content: .text(self.currentResponse), model: self.currentModel, id: completedMessageID))
        }
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
  @State private var isQueryActive: Bool = false

  init() {
    MCPConfigLoader.shared.loadConfig()
    ToolExecutor.shared.registerMCPTools()
  }

  var body: some Scene {
    WindowGroup {
      VStack(alignment: .leading) {
        HStack {
          ModelMenuView(modelname: $modelname)
          PromptMenuView(selectedPrompt: $selectedPrompt)
          FileUploadButton(selectedFileName: $selectedFileName) { fileURL in self.selectedFileURL = fileURL }
        }
        .offset(x: 0, y: 5).ignoresSafeArea().frame(maxWidth: .infinity, maxHeight: 0, alignment: .trailing)
        LLMInputView
        Divider()
        if !streamDelegate.output.characters.isEmpty || isQueryActive {
          LLMOutputView
        } else { Spacer(minLength: 20) }
      }
      .background(VisualEffect().ignoresSafeArea())
      .frame(minWidth: 400, minHeight: 150, alignment: .topLeading)
      .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
        MCPServiceManager.shared.cleanup(); exit(0)
      }
      .onAppear { focused = true }
    }
    .windowStyle(HiddenTitleBarWindowStyle()).defaultSize(width: 0.5, height: 1.0)
  }

  private var LLMInputView: some View {
    HStack {
      Button(action: {
        if isQueryActive { streamDelegate.cancelCurrentQuery() }
        else if !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedFileURL != nil {
            isQueryActive = true; Task { await submitInput() }
        }
      }) { Text(isQueryActive ? "\u{25A0}" : "\u{1F3B2}").foregroundColor(.white).cornerRadius(5) }
      .buttonStyle(PlainButtonStyle())
      .rotationEffect(isQueryActive && streamDelegate.currentTask != nil ? .degrees(360) : .degrees(0))
      .animation(isQueryActive && streamDelegate.currentTask != nil ? Animation.linear(duration: 1.0).repeatForever(autoreverses: false) : .default, value: isQueryActive && streamDelegate.currentTask != nil)

      TextField("write something..", text: $input, axis: .vertical)
        .lineLimit(1...5).textFieldStyle(.plain).focused($focused)
        .onSubmit {
          if (!input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedFileURL != nil) && !isQueryActive {
                isQueryActive = true; Task { await submitInput() }
          }
        }
    }
    .padding(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
  }

  private func submitInput() async {
    let newMessageID = UUID().uuidString
    let textToSend = self.input; let fileURLToSend = self.selectedFileURL
    self.input = ""; self.selectedFileURL = nil; self.selectedFileName = nil

    var finalContent: MessageContent? = nil
    if let url = fileURLToSend {
      finalContent = await ChatHistory.shared.handleFileUpload(fileURL: url, associatedText: textToSend.isEmpty ? nil : textToSend)
      if finalContent == nil { print("App: Error processing file upload."); queryDidComplete(); return }
    } else if !textToSend.isEmpty { finalContent = .text(textToSend) }
    else { print("App: No input."); queryDidComplete(); return }

    await ChatHistory.shared.sendInitialMessage(
        userText: textToSend.isEmpty && fileURLToSend != nil ? nil : textToSend,
        messageContent: finalContent, modelname: modelname, selectedPromptName: selectedPrompt,
        streamDelegate: streamDelegate, messageID: newMessageID,
        onQueryCompletedCallback: self.queryDidComplete,
        onToolCallsDetectedCallback: self.handleDetectedToolCalls
    )
  }

  func queryDidComplete() {
    print("App: queryDidComplete received from StreamDelegate. Setting isQueryActive=false.")
    isQueryActive = false
  }

  func handleDetectedToolCalls(toolCalls: [AppToolCall], messageId: String, modelName: String) {
    print("App: Handling \(toolCalls.count) tool calls for msgID \(messageId) from model \(modelName)")
    DispatchQueue.main.async { streamDelegate.displaySystemMessage("Using tool(s): \(toolCalls.map { $0.toolName }.joined(separator: ", "))...") }

    Task {
        var toolChatMessages: [ChatMessage] = []
        for appToolCall in toolCalls {
            let toolExeResult = await ToolExecutor.shared.executeToolCall(appToolCall)
            toolChatMessages.append(ChatMessage(
                role: "tool", content: .text(toolExeResult.content), id: UUID().uuidString,
                tool_call_id: toolExeResult.id, name: toolExeResult.toolName
            ))
        }
        await ChatHistory.shared.continueConversation(
            modelname: modelName, streamDelegate: streamDelegate, originalMessageID: messageId,
            toolResults: toolChatMessages,
            onQueryCompletedCallback: self.queryDidComplete,
            onToolCallsDetectedCallback: self.handleDetectedToolCalls
        )
    }
  }

  private var LLMOutputView: some View {
    ScrollView { Text(streamDelegate.output).lineLimit(nil).textSelection(.enabled)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 10).lineSpacing(5)
    }.defaultScrollAnchor(.bottom)
  }
}

// PopoverSelectorRow, PopoverSelector, ModelMenuView, PromptMenuView, FileUploadButton (Keep existing unchanged)
// ... (These view structs are assumed to be correctly defined as per previous state) ...
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
  private var models: [String] {
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
      Button(action: { isFilePickerPresented = true }) {
        Text("\u{1F4CE}").font(.system(size: 12)).padding(.horizontal, 2)
      }
      .buttonStyle(PlainButtonStyle()).frame(height: 10, alignment: .trailing)
      if let fileName = selectedFileName {
        Text(fileName + " ✕").font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
          .onTapGesture { selectedFileName = nil }
      }
    }
    .padding(.trailing, 4)
    .fileImporter(isPresented: $isFilePickerPresented, allowedContentTypes: [.image, .plainText, .video, .audio], allowsMultipleSelection: false) { result in
      switch result {
      case .success(let files):
        if let file = files.first { selectedFileName = file.lastPathComponent; onFileSelected(file) }
        else { selectedFileName = nil }
      case .failure(let error): print("Error selecting file: \(error.localizedDescription)"); selectedFileName = nil
      }
    }
  }
}


// DispatchQueue.main.async for window setup (Keep existing unchanged)
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

// ModelConfig, OpenAIConfig (Keep existing unchanged)
struct ModelConfig: Codable {
  let baseURL: String
  let apiKey: String
  let models: [String]
  let proxyEnabled: Bool?
  let proxyURL: String?
}

struct OpenAIConfig: Codable {
  let models: [String: ModelConfig]
  var defaultModel: String // Made var to allow fallback modification

  static func load() -> OpenAIConfig {
    let configPath = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".config").appendingPathComponent("chat.swift").appendingPathComponent("config.json")
    do {
      let data = try Data(contentsOf: configPath)
      var config = try JSONDecoder().decode(OpenAIConfig.self, from: data)
      if config.getConfig(for: config.defaultModel) == nil {
        print("Warning: Default model '\(config.defaultModel)' not found. Falling back.")
        if let firstProvider = config.models.first?.value, let firstModel = firstProvider.models.first {
            config.defaultModel = firstModel; print("Using fallback model: \(firstModel)")
        } else {
            print("Error: No models in config for fallback."); // Return a hardcoded default
            return OpenAIConfig(models: ["default_fallback": ModelConfig(baseURL: "https://api.openai.com/v1", apiKey: "YOUR_API_KEY", models: ["gpt-3.5-turbo"], proxyEnabled: false, proxyURL: nil)], defaultModel: "gpt-3.5-turbo")
        }
      }
      return config
    } catch {
      print("Error loading config: \(error). Using default minimal config.");
      return OpenAIConfig(models: ["default_fallback": ModelConfig(baseURL: "https://api.openai.com/v1", apiKey: "YOUR_API_KEY", models: ["gpt-3.5-turbo"], proxyEnabled: false, proxyURL: nil)], defaultModel: "gpt-3.5-turbo")
    }
  }

  func getConfig(for model: String) -> ModelConfig? {
    for (_, config) in models { if config.models.contains(model) { return config } }
    return nil
  }
}

App.main()
