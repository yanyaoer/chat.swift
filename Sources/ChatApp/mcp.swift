import Foundation

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

// MARK: - Tool Definitions

struct ToolDefinition: Codable, Equatable, Sendable {
    let name: String
    let description: String?
    let inputSchema: [String: JSONValue]?
    
    static func == (lhs: ToolDefinition, rhs: ToolDefinition) -> Bool {
        return lhs.name == rhs.name && lhs.description == rhs.description
    }
}

// Strictly typed JSON value that conforms to Sendable
enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intVal = try? container.decode(Int.self) {
            self = .int(intVal)
        } else if let doubleVal = try? container.decode(Double.self) {
            self = .double(doubleVal)
        } else if let stringVal = try? container.decode(String.self) {
            self = .string(stringVal)
        } else if let boolVal = try? container.decode(Bool.self) {
            self = .bool(boolVal)
        } else if let arrayVal = try? container.decode([JSONValue].self) {
            self = .array(arrayVal)
        } else if let dictVal = try? container.decode([String: JSONValue].self) {
            self = .object(dictVal)
        } else if container.decodeNil() {
            self = .null
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "JSONValue cannot be decoded")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

struct ServerCache: Codable, Sendable {
    let lastUpdated: Date
    let tools: [ToolDefinition]
}

// MARK: - MCP Connection

/// Actor managing a persistent connection to an MCP server
actor MCPConnection {
  let serverName: String
  let server: MCPServer
  
  private var process: Process?
  private var inputPipe: Pipe?
  private var outputPipe: Pipe?
  private var errorPipe: Pipe?
  private var isInitialized = false
  private var nextRequestId = 10000
  
  // Track pending requests waiting for responses
  private var pendingRequests: [Int: CheckedContinuation<[String: Any], Error>] = [:]
  
  // Buffer for incomplete lines
  private var lineBuffer = ""
  
  init(serverName: String, server: MCPServer) {
    self.serverName = serverName
    self.server = server
  }
  
  /// Initialize the connection by starting the process and completing MCP handshake
  func initialize() async throws {
    guard !isInitialized else { return }
    
    guard let command = server.command, let args = server.args else {
      throw AppError.mcpError("Local server missing command or args")
    }
    
    Logger.mcp("MCPConnection").info("Initializing connection to '\(serverName)'")
    
    // Start process
    let newProcess = Process()
    newProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    newProcess.arguments = [command] + args
    
    if let env = server.env {
      var environment = ProcessInfo.processInfo.environment
      for (key, value) in env {
        environment[key] = value
      }
      newProcess.environment = environment
    }
    
    let newInputPipe = Pipe()
    let newOutputPipe = Pipe()
    let newErrorPipe = Pipe()
    
    newProcess.standardInput = newInputPipe
    newProcess.standardOutput = newOutputPipe
    newProcess.standardError = newErrorPipe
    
    // Set up output handler
    newOutputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      if !data.isEmpty, let chunk = String(data: data, encoding: .utf8) {
        Task { [weak self] in
          await self?.processOutput(chunk)
        }
      }
    }
    
    try newProcess.run()
    
    self.process = newProcess
    self.inputPipe = newInputPipe
    self.outputPipe = newOutputPipe
    self.errorPipe = newErrorPipe
    
    Logger.mcp("MCPConnection").success("Process started for '\(serverName)'")
    
    // Send initialize request
    let initId = nextRequestId
    nextRequestId += 1
    
    let initRequest: [String: Any] = [
      "jsonrpc": "2.0",
      "id": initId,
      "method": "initialize",
      "params": [
        "protocolVersion": "2024-11-05",
        "capabilities": [:],
        "clientInfo": [
          "name": "chat.swift",
          "version": "1.0.0"
        ]
      ]
    ]
    
    let initResponse = try await sendRequest(request: initRequest)
    Logger.mcp("MCPConnection").success("Initialize response received: \(initResponse)")
    
    // Send initialized notification
    let initializedNotification: [String: Any] = [
      "jsonrpc": "2.0",
      "method": "notifications/initialized"
    ]
    
    try sendNotification(notification: initializedNotification)
    
    // Small delay to ensure server processes the notification
    try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
    
    isInitialized = true
    Logger.mcp("MCPConnection").success("Connection to '\(serverName)' initialized successfully")
  }
  
  /// Call a tool on this connection
  func callTool(name: String, arguments: [String: Any]) async throws -> String {
    guard isInitialized else {
      throw AppError.mcpError("Connection not initialized")
    }
    
    let requestId = nextRequestId
    nextRequestId += 1
    
    let toolRequest: [String: Any] = [
      "jsonrpc": "2.0",
      "id": requestId,
      "method": "tools/call",
      "params": [
        "name": name,
        "arguments": arguments
      ]
    ]
    
    Logger.mcp("MCPConnection").info("Calling tool '\(name)' on '\(serverName)' (id: \(requestId))")
    
    let response = try await sendRequest(request: toolRequest)
    
    // Convert response to JSON string
    if let resultData = try? JSONSerialization.data(withJSONObject: response),
       let resultString = String(data: resultData, encoding: .utf8) {
      return resultString
    }
    
    return "\(response)"
  }
  
  /// Terminate the connection
  func terminate() {
    Logger.mcp("MCPConnection").info("Terminating connection to '\(serverName)'")
    
    outputPipe?.fileHandleForReading.readabilityHandler = nil
    process?.terminate()
    
    process = nil
    inputPipe = nil
    outputPipe = nil
    errorPipe = nil
    isInitialized = false
    
    // Cancel all pending requests
    for (id, continuation) in pendingRequests {
      continuation.resume(throwing: AppError.mcpError("Connection terminated"))
    }
    pendingRequests.removeAll()
  }
  
  // MARK: - Private Methods
  
  private func sendRequest(request: [String: Any]) async throws -> [String: Any] {
    guard let id = request["id"] as? Int else {
      throw AppError.mcpError("Request missing id")
    }
    
    return try await withCheckedThrowingContinuation { continuation in
      // Register the continuation
      pendingRequests[id] = continuation
      
      // Send the request
      do {
        let jsonData = try JSONSerialization.data(withJSONObject: request)
        inputPipe?.fileHandleForWriting.write(jsonData)
        inputPipe?.fileHandleForWriting.write("\n".data(using: .utf8)!)
      } catch {
        pendingRequests.removeValue(forKey: id)
        continuation.resume(throwing: error)
      }
    }
  }
  
  private func sendNotification(notification: [String: Any]) throws {
    let jsonData = try JSONSerialization.data(withJSONObject: notification)
    inputPipe?.fileHandleForWriting.write(jsonData)
    inputPipe?.fileHandleForWriting.write("\n".data(using: .utf8)!)
  }
  
  private func processOutput(_ chunk: String) {
    lineBuffer += chunk
    
    // Process complete lines
    while let newlineRange = lineBuffer.range(of: "\n") {
      let line = String(lineBuffer[..<newlineRange.lowerBound])
      lineBuffer.removeSubrange(...newlineRange.lowerBound)
      
      if !line.trimmingCharacters(in: .whitespaces).isEmpty {
        processLine(line)
      }
    }
  }
  
  private func processLine(_ line: String) {
    guard let data = line.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      Logger.mcp("MCPConnection").warning("Could not parse JSON line: \(line.prefix(100))")
      return
    }
    
    // Check for error
    if let error = json["error"] as? [String: Any],
       let message = error["message"] as? String {
      Logger.mcp("MCPConnection").error("JSON-RPC Error: \(message)")
      
      if let id = json["id"] as? Int,
         let continuation = pendingRequests.removeValue(forKey: id) {
        continuation.resume(throwing: AppError.mcpError("JSON-RPC Error: \(message)"))
      }
      return
    }
    
    // Handle response
    if let id = json["id"] as? Int,
       let continuation = pendingRequests.removeValue(forKey: id),
       let result = json["result"] as? [String: Any] {
      continuation.resume(returning: result)
    }
  }
}

// MARK: - MCP Manager

@MainActor
class MCPManager: ObservableObject {
  static let shared = MCPManager()
  @Published private var mcpServers: [String: MCPServer] = [:]
  @Published private var activeMCPServers: Set<String> = []
  
  // Connection pool for persistent local server connections
  private var activeConnections: [String: MCPConnection] = [:]

  private init() {
    loadMCPConfig()
  }

  private func loadMCPConfig() {
    do {
      let config = try MCPConfig.loadConfig(MCPConfig.self)
      mcpServers = config.mcpServers
      activeMCPServers = Set(config.mcpServers.filter { $0.value.isActive == true }.keys)
      Logger.mcp("loadMCPConfig").success("MCP config loaded successfully: \(mcpServers.count) servers")
    } catch {
      Logger.mcp("loadMCPConfig").error("Error loading MCP config from \(MCPConfig.configPath): \(error)")
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

  func callMCPTool(serverName: String, toolName: String, arguments: [String: Any], bypassActiveCheck: Bool = false) async -> Result<String, AppError> {
    guard let server = mcpServers[serverName] else {
      return .failure(.mcpServerNotFound(serverName))
    }
    
    // Only check if server is active when not bypassing the check
    if !bypassActiveCheck && !activeMCPServers.contains(serverName) {
      return .failure(.mcpServerNotFound(serverName))
    }

    if server.isRemote {
      return await callRemoteMCPTool(server: server, toolName: toolName, arguments: arguments)
    } else {
      // Use persistent connection for local servers
      return await callLocalMCPToolWithConnection(serverName: serverName, server: server, toolName: toolName, arguments: arguments)
    }
  }
  
  /// Call a local MCP tool using persistent connection
  private func callLocalMCPToolWithConnection(serverName: String, server: MCPServer, toolName: String, arguments: [String: Any]) async -> Result<String, AppError> {
    // Check if we have an existing connection
    if let connection = activeConnections[serverName] {
      Logger.mcp("callLocalMCPTool").info("Reusing existing connection for '\(serverName)'")
      do {
        // Create sendable copy by converting through JSON
        let jsonData = try JSONSerialization.data(withJSONObject: arguments)
        let argsCopy = try JSONSerialization.jsonObject(with: jsonData) as! [String: Any]
        
        let result = try await connection.callTool(name: toolName, arguments: argsCopy)
        return .success(result)
      } catch let error as AppError {
        Logger.mcp("callLocalMCPTool").error("Error calling tool on existing connection: \(error)")
        return .failure(error)
      } catch {
        Logger.mcp("callLocalMCPTool").error("Error calling tool: \(error)")
        return .failure(.mcpError(error.localizedDescription))
      }
    }
    
    // Create new connection
    Logger.mcp("callLocalMCPTool").info("Creating new connection for '\(serverName)'")
    let connection = MCPConnection(serverName: serverName, server: server)
    
    do {
      // Initialize the connection
      try await connection.initialize()
      
      // Store in connection pool
      activeConnections[serverName] = connection
      
      // Create sendable copy by converting through JSON
      let jsonData = try JSONSerialization.data(withJSONObject: arguments)
      let argsCopy = try JSONSerialization.jsonObject(with: jsonData) as! [String: Any]
      
      // Call the tool
      let result = try await connection.callTool(name: toolName, arguments: argsCopy)
      return .success(result)
    } catch let error as AppError {
      Logger.mcp("callLocalMCPTool").error("Error with new connection: \(error)")
      return .failure(error)
    } catch {
      Logger.mcp("callLocalMCPTool").error("Error with new connection: \(error)")
      return .failure(.mcpError(error.localizedDescription))
    }
  }
  
  /// Shutdown all active connections (call when app exits)
  func shutdown() {
    Logger.mcp("shutdown").info("Shutting down \(activeConnections.count) active connections")
    
    for (serverName, connection) in activeConnections {
      Task {
        await connection.terminate()
        Logger.mcp("shutdown").success("Terminated connection to '\(serverName)'")
      }
    }
    
    activeConnections.removeAll()
  }

  func fetchTools(for serverName: String) async -> Result<[ToolDefinition], AppError> {
    guard let server = mcpServers[serverName] else {
      return .failure(.mcpServerNotFound(serverName))
    }

    let result: Result<String, AppError>
    if server.isRemote {
      result = await callRemoteMCPTool(server: server, toolName: "tools/list", arguments: [:])
    } else {
      // Local MCP Server (JSON-RPC over stdio)
      guard let command = server.command, let args = server.args else {
          Logger.mcp("fetchTools").error("Local server \(serverName) missing command or args")
          return .failure(.mcpError("Local server missing command or args"))
      }
      
      Logger.mcp("fetchTools").info("Fetching tools for local server: \(serverName)")
      
      return await withCheckedContinuation { continuation in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + args
        
        // Add environment variables
        if let env = server.env {
            var environment = ProcessInfo.processInfo.environment
            for (key, value) in env {
                environment[key] = value
            }
            process.environment = environment
        }
        
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        // Use a serial queue for thread-safe data accumulation
        let dataQueue = DispatchQueue(label: "com.chatapp.mcp.dataqueue")
        var outputData = Data()
        
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
          let data = handle.availableData
          if !data.isEmpty {
            dataQueue.sync {
              outputData.append(data)
            }
          }
        }
        
        // Set termination handler
        process.terminationHandler = { _ in
          outputPipe.fileHandleForReading.readabilityHandler = nil
          
          let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
          
          dataQueue.sync {
            if outputData.isEmpty {
                Logger.mcp("fetchTools").warning("No output from local server \(serverName)")
                if let errorString = String(data: errorData, encoding: .utf8), !errorString.isEmpty {
                    Logger.mcp("fetchTools").warning("Stderr: \(errorString)")
                }
                continuation.resume(returning: .failure(.mcpError("No response from local server")))
                return
            }
            
            if let outputString = String(data: outputData, encoding: .utf8) {
                Logger.mcp("fetchTools").success("Received output from local server: \(outputString.prefix(100))...")
                
                let lines = outputString.components(separatedBy: .newlines)
                for line in lines {
                    if let data = line.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let result = json["result"] as? [String: Any],
                       let tools = result["tools"] {
                        
                        do {
                          let toolsData = try JSONSerialization.data(withJSONObject: tools)
                          let toolDefs = try JSONDecoder().decode([ToolDefinition].self, from: toolsData)
                          continuation.resume(returning: .success(toolDefs))
                          return
                        } catch {
                          continuation.resume(returning: .failure(.jsonParsingError("Failed to decode tools: \(error.localizedDescription)")))
                          return
                        }
                    }
                }
                
                Logger.mcp("fetchTools").warning("Could not find valid JSON-RPC response in output")
                continuation.resume(returning: .failure(.jsonParsingError("Invalid response format")))
            } else {
              continuation.resume(returning: .failure(.mcpError("Failed to decode output")))
            }
          }
        }
        
        do {
            try process.run()
            
            // Construct JSON-RPC request
            let request: [String: Any] = [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/list",
                "params": [:]
            ]
            
            let jsonData = try JSONSerialization.data(withJSONObject: request)
            inputPipe.fileHandleForWriting.write(jsonData)
            inputPipe.fileHandleForWriting.write("\n".data(using: .utf8)!)
            try? inputPipe.fileHandleForWriting.close()
            
            // Set a timeout to terminate the process if it takes too long
            DispatchQueue.global().asyncAfter(deadline: .now() + 5.0) {
              if process.isRunning {
                Logger.mcp("fetchTools").warning("Timeout reached, terminating process")
                process.terminate()
              }
            }
            
        } catch {
            Logger.mcp("fetchTools").error("Failed to run local server: \(error)")
            continuation.resume(returning: .failure(.mcpError(error.localizedDescription)))
        }
      }
    }
    
    switch result {
    case .success(let jsonString):
      // Parse the JSON-RPC response
      // Expected format: { "result": { "tools": [ ... ] } } or just the result if callRemoteMCPTool unwraps it.
      // callRemoteMCPTool returns 'resultString' which is the "result" part of JSON-RPC response.
      
      guard let data = jsonString.data(using: .utf8) else {
        return .failure(.jsonParsingError("Invalid UTF-8 string"))
      }
      
      do {
        // The result string might be the "tools" array directly or an object containing "tools"
        // Standard MCP tools/list result: { "tools": [ ... ], "nextCursor": ... }
        
        struct ToolsListResult: Codable {
          let tools: [ToolDefinition]
        }
        
        let listResult = try JSONDecoder().decode(ToolsListResult.self, from: data)
        return .success(listResult.tools)
      } catch {
        Logger.mcp("fetchTools").error("Failed to decode tools list: \(error)")
        Logger.mcp("fetchTools").error("JSON was: \(jsonString)")
        return .failure(.jsonParsingError("Failed to decode tools list: \(error.localizedDescription)"))
      }
      
    case .failure(let error):
      return .failure(error)
    }
  }
  
  func refreshTools(for serverName: String) async {
    Logger.mcp("refreshTools").info("Refreshing tools for \(serverName)...")
    let result = await fetchTools(for: serverName)
    switch result {
    case .success(let tools):
      Logger.mcp("refreshTools").success("Fetched \(tools.count) tools for \(serverName)")
      await MCPToolCache.shared.updateCache(for: serverName, tools: tools)
    case .failure(let error):
      Logger.mcp("refreshTools").error("Failed to refresh tools for \(serverName): \(error)")
    }
  }

  private func callRemoteMCPTool(server: MCPServer, toolName: String, arguments: [String: Any])
    async -> Result<String, AppError>
  {
    guard let urlString = server.url, let url = URL(string: urlString) else {
      return .failure(.invalidURL(server.url ?? "nil"))
    }

    // Create the MCP tool call request
    // Handle 'tools/list' specifically if needed, or generic JSON-RPC
    let method = toolName == "tools/list" ? "tools/list" : "tools/call"
    
    var params: [String: Any] = [:]
    if toolName != "tools/list" {
        params["name"] = toolName
        params["arguments"] = arguments
    }
    // For tools/list, params can be empty or include cursor

    let requestBody: [String: Any] = [
      "jsonrpc": "2.0",
      "id": Int.random(in: 1...10000),
      "method": method,
      "params": params
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
          if let jsonResponse = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
             // Check for JSON-RPC error
             if let error = jsonResponse["error"] as? [String: Any],
                let message = error["message"] as? String {
                 return .failure(.mcpError("JSON-RPC Error: \(message)"))
             }
             
             if let result = jsonResponse["result"] {
                if let resultData = try? JSONSerialization.data(withJSONObject: result),
                   let resultString = String(data: resultData, encoding: .utf8)
                {
                  return .success(resultString)
                }
                return .success("\(result)")
             }
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

    Logger.mcp("callLocalMCPTool").info("Calling tool '\(toolName)' with arguments: \(arguments)")

    return await withCheckedContinuation { continuation in
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

      let inputPipe = Pipe()
      let outputPipe = Pipe()
      let errorPipe = Pipe()
      
      process.standardInput = inputPipe
      process.standardOutput = outputPipe
      process.standardError = errorPipe

      // Use a serial queue for thread-safe data accumulation and line processing
      let dataQueue = DispatchQueue(label: "com.chatapp.mcp.toolcall")
      var outputLines: [String] = []
      var lineBuffer = ""
      var isInitialized = false
      var toolCallId: Int?
      
      outputPipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        if !data.isEmpty, let chunk = String(data: data, encoding: .utf8) {
          dataQueue.sync {
            lineBuffer += chunk
            // Process complete lines
            while let newlineRange = lineBuffer.range(of: "\n") {
              let line = String(lineBuffer[..<newlineRange.lowerBound])
              lineBuffer.removeSubrange(...newlineRange.lowerBound)
              
              if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                outputLines.append(line)
                Logger.mcp("callLocalMCPTool").debug("Received line: \(line.prefix(100))...")
              }
            }
          }
        }
      }

      process.terminationHandler = { process in
        outputPipe.fileHandleForReading.readabilityHandler = nil
        
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        
        dataQueue.sync {
          // Add any remaining data in buffer
          if !lineBuffer.trimmingCharacters(in: .whitespaces).isEmpty {
            outputLines.append(lineBuffer)
          }
          
          if let errorString = String(data: errorData, encoding: .utf8), !errorString.isEmpty {
            Logger.mcp("callLocalMCPTool").warning("Stderr: \(errorString)")
          }
          
          if outputLines.isEmpty {
            Logger.mcp("callLocalMCPTool").error("No output from process")
            continuation.resume(returning: .failure(.mcpError("No output from MCP tool")))
            return
          }
          
          Logger.mcp("callLocalMCPTool").info("Processing \(outputLines.count) response lines")
          
          // Parse JSON-RPC responses
          for line in outputLines {
            if let data = line.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
              
              // Check for JSON-RPC error
              if let error = json["error"] as? [String: Any],
                 let message = error["message"] as? String {
                Logger.mcp("callLocalMCPTool").error("JSON-RPC Error: \(message)")
                continuation.resume(returning: .failure(.mcpError("JSON-RPC Error: \(message)")))
                return
              }
              
              // Check if this is the tool call response (matching our ID)
              if let id = json["id"] as? Int, 
                 let expectedId = toolCallId,
                 id == expectedId,
                 let result = json["result"] {
                if let resultData = try? JSONSerialization.data(withJSONObject: result),
                   let resultString = String(data: resultData, encoding: .utf8) {
                  Logger.mcp("callLocalMCPTool").success("Tool result: \(resultString.prefix(200))...")
                  continuation.resume(returning: .success(resultString))
                  return
                }
                continuation.resume(returning: .success("\(result)"))
                return
              }
            }
          }
          
          // If no valid tool result found
          Logger.mcp("callLocalMCPTool").warning("No valid tool result found in responses")
          let combinedOutput = outputLines.joined(separator: "\n")
          continuation.resume(returning: .success(combinedOutput))
        }
      }

      do {
        try process.run()
        
        // Step 1: Send initialize request (required by MCP protocol)
        let initId = Int.random(in: 1...10000)
        toolCallId = Int.random(in: 10001...20000)  // Set this early so termination handler can use it
        
        let initRequest: [String: Any] = [
          "jsonrpc": "2.0",
          "id": initId,
          "method": "initialize",
          "params": [
            "protocolVersion": "2024-11-05",
            "capabilities": [:],
            "clientInfo": [
              "name": "chat.swift",
              "version": "1.0.0"
            ]
          ]
        ]
        
        let initData = try JSONSerialization.data(withJSONObject: initRequest)
        Logger.mcp("callLocalMCPTool").info("Sending initialize request (id: \(initId))")
        inputPipe.fileHandleForWriting.write(initData)
        inputPipe.fileHandleForWriting.write("\n".data(using: .utf8)!)
        
        // Small delay to let server process initialize
        Thread.sleep(forTimeInterval: 0.1)
        
        // Step 2: Send initialized notification
        let initializedNotification: [String: Any] = [
          "jsonrpc": "2.0",
          "method": "notifications/initialized"
        ]
        
        let notifData = try JSONSerialization.data(withJSONObject: initializedNotification)
        Logger.mcp("callLocalMCPTool").debug("Sending initialized notification")
        inputPipe.fileHandleForWriting.write(notifData)
        inputPipe.fileHandleForWriting.write("\n".data(using: .utf8)!)
        
        // Small delay before tool call
        Thread.sleep(forTimeInterval: 0.1)
        
        // Step 3: Send the actual tool call
        let toolRequest: [String: Any] = [
          "jsonrpc": "2.0",
          "id": toolCallId!,
          "method": "tools/call",
          "params": [
            "name": toolName,
            "arguments": arguments
          ]
        ]
        
        let toolData = try JSONSerialization.data(withJSONObject: toolRequest, options: .prettyPrinted)
        let requestString = String(data: toolData, encoding: .utf8) ?? ""
        Logger.mcp("callLocalMCPTool").info("Sending tool call request (id: \(toolCallId!)):\n\(requestString)")
        
        inputPipe.fileHandleForWriting.write(toolData)
        inputPipe.fileHandleForWriting.write("\n".data(using: .utf8)!)
        // Don't close the pipe immediately - let the process finish naturally
        
        // Set a timeout to terminate the process if it takes too long
        DispatchQueue.global().asyncAfter(deadline: .now() + 30.0) {
          if process.isRunning {
            Logger.mcp("callLocalMCPTool").warning("Timeout reached, terminating process")
            process.terminate()
          }
        }
        
      } catch {
        Logger.mcp("callLocalMCPTool").error("Failed to run process: \(error)")
        continuation.resume(returning: .failure(.mcpError("Failed to execute MCP tool: \(error.localizedDescription)")))
      }
    }
  }
}

// MARK: - Cache Manager

actor MCPToolCache {
    static let shared = MCPToolCache()
    private var cache: [String: ServerCache] = [:]
    
    private var cachePath: URL {
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config")
            .appendingPathComponent(AppConstants.configDirectoryName)
            .appendingPathComponent("cached_mcp_tools.json")
    }
    
    private init() {
        Task {
            await loadCache()
        }
    }
    
    func loadCache() {
        do {
            if FileManager.default.fileExists(atPath: cachePath.path) {
                let data = try Data(contentsOf: cachePath)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                cache = try decoder.decode([String: ServerCache].self, from: data)
                Logger.cache("loadCache").success("Loaded cache for \(cache.count) servers")
            }
        } catch {
            Logger.cache("loadCache").warning("Failed to load cache: \(error)")
        }
    }
    
    func saveCache() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(cache)
            try data.write(to: cachePath)
            Logger.cache("saveCache").success("Saved cache to \(cachePath.path)")
        } catch {
            Logger.cache("saveCache").error("Failed to save cache: \(error)")
        }
    }
    
    func updateCache(for serverName: String, tools: [ToolDefinition]) {
        let serverCache = ServerCache(lastUpdated: Date(), tools: tools)
        cache[serverName] = serverCache
        saveCache()
    }
    
    func getTools(for serverName: String) -> [ToolDefinition]? {
        return cache[serverName]?.tools
    }
    
    func getLastUpdated(for serverName: String) -> Date? {
        return cache[serverName]?.lastUpdated
    }
    
    func clearCache(for serverName: String) {
        cache.removeValue(forKey: serverName)
        saveCache()
    }
}
