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
  let content: String
  let timestamp: Date
  let model: String?

  init(role: String, content: String, model: String? = nil) {
    self.role = role
    self.content = content
    self.timestamp = Date()
    self.model = model
  }
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

  func getAvailablePrompts() -> [String] {
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
    let text = """
          
      [\(timestamp)] \(message.role)\(modelInfo)\(promptInfo):
      \(message.content)
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

class StreamDelegate: NSObject, URLSessionDataDelegate, ObservableObject {
  @Published var output: String = ""
  private var currentResponse: String = ""
  private var currentModel: String = ""

  override init() {
    super.init()
  }

  func setModel(_ model: String) {
    currentModel = model
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
                let assistantMessage = ChatMessage(
                  role: "assistant", content: finalResponse, model: self.currentModel)
                ChatHistory.shared.saveMessage(assistantMessage)
                self.currentResponse = ""
                print(line)
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

struct App: SwiftUI.App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  @State private var input = ""
  @StateObject private var streamDelegate = StreamDelegate()
  @AppStorage("modelname") public var modelname = OpenAIConfig.load().defaultModel
  @AppStorage("selectedPrompt") private var selectedPrompt: String = ""
  @FocusState private var focused: Bool

  var body: some Scene {
    WindowGroup {
      VStack(alignment: .leading) {
        HStack {
          PopoverView(modelname: $modelname)
          PromptMenuView(selectedPrompt: $selectedPrompt)
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
      .frame(minWidth: 300, minHeight: 150, alignment: .topLeading)
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
    TextField("write something..", text: $input).onSubmit {
      streamDelegate.output = ""
      sendMessage(message: self.input)
    }
    .textFieldStyle(.plain)
    .focused($focused)
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

    let userMessage = ChatMessage(role: "user", content: message, model: modelname)
    ChatHistory.shared.saveMessage(userMessage)

    var messages: [ChatMessage] = []
    if !selectedPrompt.isEmpty,
      let prompt = ChatHistory.shared.loadPromptContent(name: selectedPrompt)
    {
      messages.append(ChatMessage(role: prompt.role, content: prompt.content, model: nil))
    }
    messages.append(ChatMessage(role: "user", content: message, model: modelname))

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
    streamDelegate.setModel(modelname)
    let task = session.dataTask(with: request)
    task.resume()
  }
}

struct PopoverView: View {
  @State private var ModelData = OpenAIConfig.load().models.values.flatMap { $0.models }
  @Binding public var modelname: String

  var body: some View {
    ZStack {
      Picker("", selection: $modelname) {
        ForEach(ModelData, id: \.self) { name in
          Text(name)
        }
      }
      .frame(width: 100, height: 10, alignment: .trailing)
    }
  }
}

struct PromptMenuView: View {
  @Binding var selectedPrompt: String
  private let prompts = ChatHistory.shared.getAvailablePrompts()

  var body: some View {
    if !prompts.isEmpty {
      Picker("sys:", selection: $selectedPrompt) {
        Text("None").tag("")
        ForEach(prompts, id: \.self) { prompt in
          Text(prompt).tag(prompt)
        }
      }
      .frame(width: 60, height: 10, alignment: .trailing)
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
