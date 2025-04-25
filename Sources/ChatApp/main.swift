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

  init(role: String, content: MessageContent, model: String? = nil) {
    self.role = role
    self.content = content
    self.timestamp = Date()
    self.model = model
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

  func getAvailablePrompts() async -> [String] {
    do {
      let files = try FileManager.default.contentsOfDirectory(atPath: promptsPath.path)
      return files.filter { $0.hasSuffix(".md") }.map { String($0.dropLast(3)) }
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
          return "[Image: \(imageUrl.url)]"
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
}

final class StreamDelegate: NSObject, URLSessionDataDelegate, ObservableObject, @unchecked Sendable
{
  @Published var output: String = ""
  private var currentResponse: String = ""
  private var currentModel: String = ""
  private var lastUserInput: String = ""

  override init() {
    super.init()
  }

  func setModel(_ model: String) {
    currentModel = model
  }

  func setLastUserInput(_ input: String) {
    lastUserInput = input
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    if let text = String(data: data, encoding: .utf8) {
      let lines = text.components(separatedBy: "\n")
      for line in lines {
        if line.hasPrefix("data: "), let jsonData = line.dropFirst(6).data(using: .utf8) {
          do {
            if line.hasPrefix("data: [DONE]") {
              let finalResponse = currentResponse
              DispatchQueue.main.async {
                if !self.lastUserInput.isEmpty {
                  let userMessage = ChatMessage(
                    role: "user", content: .text(self.lastUserInput), model: self.currentModel)
                  ChatHistory.shared.saveMessage(userMessage)
                }
                let assistantMessage = ChatMessage(
                  role: "assistant", content: .text(finalResponse), model: self.currentModel)
                ChatHistory.shared.saveMessage(assistantMessage)
                self.currentResponse = ""
                // print(line)
              }
              return
            }
            if let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let delta = firstChoice["delta"] as? [String: Any],
              let content = delta["content"] as? String
            {
              DispatchQueue.main.async {
                self.currentResponse += content
                self.output += content
              }
            }
          } catch {
            print("Error parsing JSON: \(error)")
          }
        }
      }
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if let error = error {
      DispatchQueue.main.async {
        self.output += "\nError: \(error.localizedDescription)"
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
  @State private var currentImageContent: MessageContent?

  var body: some Scene {
    WindowGroup {
      VStack(alignment: .leading) {
        HStack {
          ModelMenuView(modelname: $modelname)
          PromptMenuView(selectedPrompt: $selectedPrompt)

          FileUploadButton(input: $input) { fileURL in
            handleFileUpload(fileURL)
          }
        }
        .offset(x: 0, y: 5)
        .ignoresSafeArea()
        .frame(maxWidth: .infinity, maxHeight: 0, alignment: .trailing)

        LLMInputView
        Divider()

        if streamDelegate.output.count > 0 {
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
      TextField("write something..", text: $input).onSubmit {
        streamDelegate.output = ""
        streamDelegate.setLastUserInput(self.input)
        streamDelegate.setModel(modelname)
        sendMessage(message: self.input)
      }
      .textFieldStyle(.plain)
      .focused($focused)
    }
    .padding(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
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

  private func handleFileUpload(_ fileURL: URL) {
    let fileType = fileURL.pathExtension.lowercased()
    let supportedTypes = ["jpg", "jpeg", "png", "pdf"]

    guard supportedTypes.contains(fileType) else {
      print("Unsupported file type")
      return
    }

    do {
      // 确保文件可以被访问
      guard fileURL.startAccessingSecurityScopedResource() else {
        print("Failed to access the file")
        return
      }

      defer {
        fileURL.stopAccessingSecurityScopedResource()
      }

      // 直接读取文件数据，不复制文件
      let fileData = try Data(contentsOf: fileURL)
      let base64String = fileData.base64EncodedString()
      let imageUrl = "data:image/\(fileType);base64,\(base64String)"

      let contentItems = [
        ContentItem(type: "text", text: self.input, image_url: nil),
        ContentItem(type: "image_url", text: nil, image_url: ImageURL(url: imageUrl)),
      ]

      currentImageContent = .multimodal(contentItems)
    } catch {
      print("Error handling file: \(error.localizedDescription)")
    }
  }

  private func sendMessage(message: String) {
    let config = OpenAIConfig.load()
    guard let modelConfig = config.getConfig(for: modelname) else {
      print("Error: Model configuration not found")
      return
    }

    let url = URL(string: "\(modelConfig.baseURL)/chat/completions")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(modelConfig.apiKey)", forHTTPHeaderField: "Authorization")

    var messages: [ChatMessage] = []
    if !selectedPrompt.isEmpty,
      let prompt = ChatHistory.shared.loadPromptContent(name: selectedPrompt)
    {
      messages.append(ChatMessage(role: prompt.role, content: .text(prompt.content), model: nil))
    }

    if let imageContent = currentImageContent {
      messages.append(ChatMessage(role: "user", content: imageContent, model: modelname))
      currentImageContent = nil
    } else {
      messages.append(ChatMessage(role: "user", content: .text(message), model: modelname))
    }

    print(messages)

    let chatRequest = ChatRequest(
      model: modelname,
      messages: messages,
      stream: true
    )

    let encoder = JSONEncoder()
    request.httpBody = try? encoder.encode(chatRequest)

    let sessionConfig = URLSessionConfiguration.default
    if let proxyEnabled = modelConfig.proxyEnabled, proxyEnabled,
      let proxyHost = modelConfig.proxyHost,
      let proxyPort = modelConfig.proxyPort
    {
      sessionConfig.connectionProxyDictionary = [
        kCFNetworkProxiesSOCKSEnable: true,
        kCFNetworkProxiesSOCKSProxy: proxyHost,
        kCFNetworkProxiesSOCKSPort: proxyPort,
        kCFStreamPropertySOCKSVersion: kCFStreamSocketSOCKSVersion5,
      ]
    }

    let session = URLSession(
      configuration: sessionConfig, delegate: streamDelegate, delegateQueue: nil)
    let task = session.dataTask(with: request)
    task.resume()
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
  // let width: CGFloat

  @State private var showPopover = false

  var body: some View {
    Button(action: { showPopover.toggle() }) {
      label()
      //.frame(width: width, height: 24)
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
      //.frame(minWidth: width)
    }
  }
}

struct ModelMenuView: View {
  @Binding public var modelname: String
  private let models: [String] = OpenAIConfig.load().models.values.flatMap { $0.models }
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
      // Load prompts asynchronously when the view appears
      let availablePrompts = await ChatHistory.shared.getAvailablePrompts()
      prompts = ["None"] + availablePrompts
    }
  }
}

struct FileUploadButton: View {
  @Binding var input: String
  @State private var isFilePickerPresented = false
  @State private var selectedFileName: String? = nil
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
        Text(fileName)
          .font(.system(size: 11))
          .foregroundColor(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
    }
    .padding(.trailing, 4)
    .fileImporter(
      isPresented: $isFilePickerPresented,
      allowedContentTypes: [.image, .pdf],
      allowsMultipleSelection: false
    ) { result in
      switch result {
      case .success(let files):
        if let file = files.first {
          selectedFileName = file.lastPathComponent
          onFileSelected(file)
        }
      case .failure(let error):
        print("Error selecting file: \(error.localizedDescription)")
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
    // 隐藏左上角关闭、最大化、缩小按钮
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
  let proxyHost: String?
  let proxyPort: Int?
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
      return try JSONDecoder().decode(OpenAIConfig.self, from: data)
    } catch {
      print("Error loading config: \(error)")
      return OpenAIConfig(
        models: [
          "openai": ModelConfig(
            baseURL: "https://ark.cn-beijing.volces.com/api/v3",
            apiKey: "please input your api key",
            models: ["qwen2.5", "deepseek-v3-250324"],
            proxyEnabled: false,
            proxyHost: "127.0.0.1",
            proxyPort: 1088
          )
        ],
        defaultModel: "deepseek-v3-250324"
      )
    }
  }

  func getConfig(for model: String) -> ModelConfig? {
    for (_, config) in models {
      if config.models.contains(model) {
        return config
      }
    }
    return nil
  }
}

App.main()
