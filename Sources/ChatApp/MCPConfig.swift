import Foundation

struct MCPServiceConfig: Codable, Identifiable {
    var id: String { name } // Use service name as ID
    let name: String // Will be populated from the dictionary key
    let description: String?
    let type: MCPServiceType
    let command: String?         // For stdio type
    let args: [String]?          // For stdio type
    let baseURL: String?         // For http type
    let apiKey: String?          // For http type (optional)
    let tools: [String]?         // List of tool names this service provides

    // We will populate `name` manually after decoding the dictionary.
    // Adding a direct initializer to make this easier.
    init(name: String, description: String?, type: MCPServiceType, command: String?, args: [String]?, baseURL: String?, apiKey: String?, tools: [String]?) {
        self.name = name
        self.description = description
        self.type = type
        self.command = command
        self.args = args
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.tools = tools
    }

    // Codable conformance will use synthesized init(from: Decoder)
    // and encode(to: Encoder) if we don't provide custom ones.
    // For decoding the dictionary structure, we'll handle it in RootMCPConfig.
}

enum MCPServiceType: String, Codable {
    case stdio
    case http
}

// This structure directly matches an entry in the "mcpServers" dictionary in JSON
struct MCPServiceConfigEntry: Codable {
    let description: String?
    let type: MCPServiceType
    let command: String?
    let args: [String]?
    let baseURL: String?
    let apiKey: String?
    let tools: [String]?
}

struct RootMCPConfig: Codable {
    let mcpServers: [String: MCPServiceConfigEntry]

    func getServiceConfigs() -> [MCPServiceConfig] {
        return mcpServers.map { (key, entry) -> MCPServiceConfig in
            return MCPServiceConfig(
                name: key,
                description: entry.description,
                type: entry.type,
                command: entry.command,
                args: entry.args,
                baseURL: entry.baseURL,
                apiKey: entry.apiKey,
                tools: entry.tools
            )
        }
    }
}

@MainActor // Ensuring shared instance and its methods are main-actor isolated
class MCPConfigLoader {
    static let shared = MCPConfigLoader()
    private let configFileName = "mcp_server.json"
    private var loadedConfig: RootMCPConfig?
    private var configFilePath: URL?

    private init() {
        setupConfigPath()
        loadConfig()
    }

    private func setupConfigPath() {
        // Standard config directory: ~/.config/chat.swift/
        let configDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config")
            .appendingPathComponent("chat.swift")

        // Ensure this directory exists
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true, attributes: nil)

        self.configFilePath = configDir.appendingPathComponent(configFileName)
    }

    func loadConfig() {
        guard let configURL = self.configFilePath else {
            print("Error: MCP config file path not set.")
            self.loadedConfig = RootMCPConfig(mcpServers: [:]) // Empty config
            return
        }

        if !FileManager.default.fileExists(atPath: configURL.path) {
            print("MCP config file not found at \(configURL.path). Creating a default one.")
            createDefaultConfigFile(at: configURL)
            // Attempt to load again after creating default, or assume default is loaded if creation is part of this flow
        }

        do {
            let data = try Data(contentsOf: configURL)
            let decoder = JSONDecoder()
            self.loadedConfig = try decoder.decode(RootMCPConfig.self, from: data)
            print("MCP config loaded successfully from \(configURL.path)")
        } catch {
            print("Error loading or decoding MCP config at \(configURL.path): \(error). Using empty configuration.")
            self.loadedConfig = RootMCPConfig(mcpServers: [:]) // Empty config on error
        }
    }

    private func createDefaultConfigFile(at url: URL) {
        let defaultConfigContent = """
        {
          "mcpServers": {
            "mcp-video2text-example": {
              "description": "Example: Service to transcribe video to text using stdio.",
              "type": "stdio",
              "command": "echo",
              "args": ["Hello from mcp-video2text-example via stdio. Args: video_path=%VIDEO_PATH%"],
              "tools": ["video_to_text_tool_example"]
            },
            "mcp-http-example": {
              "description": "Example: MCP service via HTTP.",
              "type": "http",
              "baseURL": "http://localhost:8080/mcp_api_endpoint",
              "apiKey": null,
              "tools": ["http_tool_example"]
            }
          }
        }
        """
        do {
            try defaultConfigContent.write(to: url, atomically: true, encoding: .utf8)
            print("Created default MCP config file at \(url.path)")
        } catch {
            print("Failed to create default MCP config file at \(url.path): \(error)")
        }
    }

    func getMCPServiceConfigs() -> [MCPServiceConfig] {
        // Ensure config is loaded. If it's nil because file didn't exist, loadConfig would try to create and parse.
        // If parsing fails after creation or it's still nil, return empty.
        if self.loadedConfig == nil { // Handles case where init failed to load for some reason or file was just created
            loadConfig()
        }
        return self.loadedConfig?.getServiceConfigs() ?? []
    }

    func getServiceConfig(forName name: String) -> MCPServiceConfig? {
        if self.loadedConfig == nil {
            loadConfig()
        }
        return self.loadedConfig?.getServiceConfigs().first(where: { $0.name == name })
    }
}
