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

struct ChatMessage: Codable {
  let role: String
  let content: MessageContent
  let timestamp: Date
  let model: String?
  let reasoning_effort: String?  // "low", "medium", and "high", which behind the scenes we map to 1K, 8K, and 24K thinking token budgets

  init(role: String, content: MessageContent, model: String? = nil, reasoning_effort: String? = nil)
  {
    self.role = role
    self.content = content
    self.timestamp = Date()
    self.model = model
    self.reasoning_effort = reasoning_effort
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

struct ChatRequest: Codable {
  let model: String
  var messages: [ChatMessage]
  let stream: Bool
  // let tools: [Tool]?
  // let tool_choice: String?
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
          
      [\(timestamp)] \(message.role)\(modelInfo)\(promptInfo):
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
    onQueryCompleted: @escaping () -> Void
  ) async {
    let config = OpenAIConfig.load()
    guard let modelConfig = config.getConfig(for: modelname) else {
      print("Error: Model configuration not found for \(modelname)")
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

    let finalContent: MessageContent
    if let content = messageContent {
      finalContent = content
    } else if let text = userText, !text.isEmpty {
      finalContent = .text(text)
    } else {
      print("Error: No message content to send.")
      return
    }

    let userMessage = ChatMessage(role: "user", content: finalContent, model: modelname)
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
    streamDelegate.setQueryCompletionCallback(onQueryCompleted) // Set the callback

    let session = URLSession(
      configuration: sessionConfig, delegate: streamDelegate, delegateQueue: nil)
    let task = session.dataTask(with: request)
    streamDelegate.currentTask = task // Assign the task to the streamDelegate
    task.resume()
  }
}

final class StreamDelegate: NSObject, URLSessionDataDelegate, ObservableObject, @unchecked Sendable
{
  @Published var output: AttributedString = ""
  private var currentResponse: String = ""
  private var currentModel: String = ""
  private var isCurrentlyReasoning: Bool = false
  var currentTask: URLSessionDataTask?
  var currentMessageID: String?
  var onQueryCompleted: (() -> Void)?


  override init() {
    super.init()
  }

  func cancelCurrentQuery() {
    currentTask?.cancel()
    DispatchQueue.main.async { // Ensure UI updates are on the main thread
        self.output = AttributedString("")
        self.currentResponse = ""
        self.isCurrentlyReasoning = false
        // self.currentTask = nil // Task becomes invalid after cancellation, good to clear
        // self.currentMessageID = nil // Reset message ID if query is cancelled
        // Note: isQueryActive is in App struct, will be handled by callback
        self.onQueryCompleted?() // Also call when manually cancelling
    }
    // It's important to set currentTask to nil here or after ensuring it's no longer needed.
    // Since task cancellation is async, setting it to nil immediately might be premature if other delegate methods expect it.
    // However, for a new query, a new task will be assigned anyway.
    // Let's set it to nil to prevent reuse of a cancelled task.
    self.currentTask = nil
    self.currentMessageID = nil // Also reset the message ID
    print("Query cancelled and StreamDelegate state reset.")
  }

  func setQueryCompletionCallback(_ callback: @escaping () -> Void) {
      self.onQueryCompleted = callback
  }

  func setModel(_ model: String) {
    currentModel = model
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    if let text = String(data: data, encoding: .utf8) {
      let lines = text.components(separatedBy: "\n")
      for line in lines {
        // print(line)
        if line.hasPrefix("data: "), let jsonData = line.dropFirst(6).data(using: .utf8) {
          do {
            if line.contains("data: [DONE]") {
              let finalResponse = currentResponse
              DispatchQueue.main.async {
                if !finalResponse.isEmpty {
                  let assistantMessage = ChatMessage(
                    role: "assistant", content: .text(finalResponse), model: self.currentModel)
                  ChatHistory.shared.saveMessage(assistantMessage)
                }
                self.currentResponse = ""
                self.isCurrentlyReasoning = false
                self.onQueryCompleted?() // Call the callback
              }
              return
            }

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

                  attributedChunk = AttributedString(chunkToAppend)
                  if isChunkReasoning {
                    attributedChunk.foregroundColor = .secondary
                  }
                  self.output += attributedChunk
                }
              }
            }
          } catch {
            if !line.contains("data: [DONE]") {
              print("Error parsing JSON line: \(line), Error: \(error)")
              DispatchQueue.main.async {
                var errorChunk = AttributedString(
                  "\nError parsing stream chunk: \(error.localizedDescription)")
                errorChunk.foregroundColor = .red
                self.output += errorChunk
                self.isCurrentlyReasoning = false
              }
            }
          }
        }
      }
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if let error = error {
      DispatchQueue.main.async {
        self.currentResponse = ""
        var errorChunk = AttributedString("\nNetwork Error: \(error.localizedDescription)")
        errorChunk.foregroundColor = .red
        self.output += errorChunk
        self.isCurrentlyReasoning = false
        self.onQueryCompleted?() // Call the callback
      }
    } else {
      DispatchQueue.main.async {
        if !self.currentResponse.isEmpty {
          let assistantMessage = ChatMessage(
            role: "assistant", content: .text(self.currentResponse), model: self.currentModel)
          ChatHistory.shared.saveMessage(assistantMessage)
          self.currentResponse = ""
        }
        self.isCurrentlyReasoning = false
        self.onQueryCompleted?() // Call the callback
      }
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
  @State private var isQueryActive: Bool = false // Added
  @State private var currentMessageID: String? = nil // Added

  var body: some Scene {
    WindowGroup {
      VStack(alignment: .leading) {
        HStack {
          ModelMenuView(modelname: $modelname)
          PromptMenuView(selectedPrompt: $selectedPrompt)

          FileUploadButton(selectedFileName: $selectedFileName) { fileURL in
            self.selectedFileURL = fileURL
          }
        }
        .offset(x: 0, y: 5)
        .ignoresSafeArea()
        .frame(maxWidth: .infinity, maxHeight: 0, alignment: .trailing)

        LLMInputView // Modified
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

  private var LLMInputView: some View { // Modified
    HStack {
        TextEditor(text: $input)
            .frame(minHeight: 30, maxHeight: 150)
            .border(Color.secondary.opacity(0.5), width: 0.5)
            .cornerRadius(5)
            .focused($focused)
            .onSubmit {
                if !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Task {
                        await submitInput()
                        isQueryActive = true
                    }
                }
            }

        Button(action: {
            if isQueryActive {
                // Cancel action
                streamDelegate.cancelCurrentQuery() 
                input = ""
                isQueryActive = false
            } else {
                // Go action
                if !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Task {
                        await submitInput()
                        isQueryActive = true
                    }
                }
            }
        }) {
            Text(isQueryActive ? "cancel" : "go")
                .padding(.horizontal, 10)
                .frame(height: 30) 
                .background(isQueryActive ? Color.red : Color.blue)
                .foregroundColor(.white)
                .cornerRadius(5)
        }
        .buttonStyle(PlainButtonStyle()) 
    }
    .padding(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
  }

  private func submitInput() async {
    let newMessageID = UUID().uuidString
    self.currentMessageID = newMessageID

    let textToSend = self.input
    let fileURLToSend = self.selectedFileURL

    // self.input = "" // Clear input after sending? Or keep it? Let's keep it for now, cancel/new message will clear.
    self.selectedFileURL = nil
    self.selectedFileName = nil

    if let url = fileURLToSend {
      if let contentToSend = await ChatHistory.shared.handleFileUpload(
        fileURL: url,
        associatedText: textToSend
      ) {
        await ChatHistory.shared.sendMessage(
          userText: nil, // Or textToSend if it should be associated
          messageContent: contentToSend,
          modelname: modelname,
          selectedPrompt: selectedPrompt,
          streamDelegate: streamDelegate,
          messageID: newMessageID, // Added
          onQueryCompleted: self.queryDidComplete
        )
      } else {
        print("Error processing file upload, message not sent.")
      }
    } else if !textToSend.isEmpty {
      await ChatHistory.shared.sendMessage(
        userText: textToSend,
        messageContent: nil,
        modelname: modelname,
        selectedPrompt: selectedPrompt,
        streamDelegate: streamDelegate,
        messageID: newMessageID, // Added
        onQueryCompleted: self.queryDidComplete
      )
    }
  }

  func queryDidComplete() {
      isQueryActive = false
      // Consider clearing input here as well, or let cancel button/new submission handle it
      // input = "" 
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
            Text("🧠").font(.system(size: 14))
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
            Text("📄").font(.system(size: 12))
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
        Text("📎")
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
  // hide dock icon
  NSApplication.shared.setActivationPolicy(.accessory)
  // always on top
  NSApplication.shared.activate(ignoringOtherApps: true)
  if let window = NSApplication.shared.windows.first {
    window.level = .floating
    // Hide window buttons: close, maximize, minimize
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
  // let proxyPort: Int?
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
        let fallbackModel = config.models.first?.value.models.first ?? "deepseek-v3-250324"
        print("Using fallback model: \(fallbackModel)")
        return OpenAIConfig(models: config.models, defaultModel: fallbackModel)
      }
      return config

    } catch {
      print("Error loading config: \(error). Using default configuration.")
      return OpenAIConfig(models: [:], defaultModel: "deepseek-v3-250324")
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
