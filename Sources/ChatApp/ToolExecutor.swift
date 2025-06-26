// ToolExecutor.swift

import Foundation
import MCP // For MCP.Client, MCP.ContentItem, MCP.StdioTransport, MCP.HTTPClientTransport

// App-internal representation of a tool call, used by the ReAct loop.
struct AppToolCall {
    let id: String // ID of the call, used to match with the result
    let toolName: String
    let args: String // Arguments as a JSON string
}

// App-internal representation of a tool result.
struct AppToolResult {
    let id: String // ID of the original call
    let toolName: String
    let content: String // Result content, always stringified for OpenAI.
}

enum ToolType: String, Codable {
    case localFunction
    case mcpService
}

struct ToolDefinition: Identifiable {
    var id: String { name }
    let name: String
    let type: ToolType
    let description: String
    let mcpServiceName: String?

    init(name: String, type: ToolType, description: String, mcpServiceName: String? = nil) {
        self.name = name
        self.type = type
        self.description = description
        self.mcpServiceName = mcpServiceName
    }
}

class ToolExecutor {
    static let shared = ToolExecutor()
    private var availableTools: [String: ToolDefinition] = [:]

    private init() {
        registerTool(ToolDefinition(
            name: "getCurrentWeather",
            type: .localFunction,
            description: "Gets the current weather for a given location. Args format: {\"location\": \"city, state\"}"
        ))
    }

    @MainActor
    func registerMCPTools() {
        let mcpConfigs = MCPConfigLoader.shared.getMCPServiceConfigs()
        for serviceConfig in mcpConfigs {
            guard let toolsInConfig = serviceConfig.tools else { continue }
            for toolNameInService in toolsInConfig {
                let toolDef = ToolDefinition(
                    name: toolNameInService,
                    type: .mcpService,
                    description: serviceConfig.description ?? "MCP Service tool: \(toolNameInService) provided by \(serviceConfig.name). Args should be JSON string if service expects structured input.",
                    mcpServiceName: serviceConfig.name
                )
                registerTool(toolDef)
            }
        }
    }

    func registerTool(_ tool: ToolDefinition) {
        availableTools[tool.name] = tool
        print("ToolExecutor: Registered tool '\(tool.name)' (Type: \(tool.type), MCPService: \(tool.mcpServiceName ?? "N/A"))")
    }

    func getAvailableToolsDescriptionForLLM() -> String {
        if availableTools.isEmpty {
            return "[]"
        }

        let toolJsonObjects: [[String: Any]] = availableTools.values.sorted(by: { $0.name < $1.name }).map { toolDef in
            var functionParams: [String: Any] = [
                "name": toolDef.name,
                "description": toolDef.description
            ]
            // TODO: Define actual parameters schema for each tool based on its requirements.
            // This is crucial for OpenAI to call tools correctly.
            // Example:
            // if toolDef.name == "getCurrentWeather" {
            //     functionParams["parameters"] = [
            //         "type": "object",
            //         "properties": [
            //             "location": ["type": "string", "description": "The city and state, e.g., San Francisco, CA"],
            //             // "unit": ["type": "string", "enum": ["celsius", "fahrenheit"]] // Example optional param
            //         ],
            //         "required": ["location"]
            //     ]  as [String : Any]
            // }
             if functionParams["parameters"] == nil {
                 functionParams["parameters"] = ["type": "object", "properties": [:]] as [String: Any]
             }

            return [
                "type": "function", // OpenAI tool type
                "function": functionParams
            ]
        }

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: toolJsonObjects, options: [.prettyPrinted])
            return String(data: jsonData, encoding: .utf8) ?? "[]"
        } catch {
            print("ToolExecutor: Error encoding tool descriptions to JSON: \(error)")
            return "[]"
        }
    }

    func executeToolCall(_ toolCall: AppToolCall) async -> AppToolResult {
        print("ToolExecutor: Executing tool '\(toolCall.toolName)' with ID '\(toolCall.id)' and args: \(toolCall.args)")

        guard let toolDefinition = availableTools[toolCall.toolName] else {
            let errorMsg = "Error: Tool '\(toolCall.toolName)' not found or not registered."
            print("ToolExecutor: \(errorMsg)")
            return AppToolResult(id: toolCall.id, toolName: toolCall.toolName, content: errorMsg)
        }

        do {
            switch toolDefinition.type {
            case .localFunction:
                if toolCall.toolName == "getCurrentWeather" {
                    guard !toolCall.args.isEmpty, let argsData = toolCall.args.data(using: .utf8) else {
                        throw MCPError.invalidConfiguration("Args for getCurrentWeather are empty or not valid UTF8 JSON.")
                    }
                    let weatherArgs = try JSONDecoder().decode([String: String].self, from: argsData)
                    let location = weatherArgs["location"] ?? "an unspecified location"
                    let weather = "The weather in \(location) is sunny and 75°F. (Dummy data)"
                    return AppToolResult(id: toolCall.id, toolName: toolCall.toolName, content: weather)
                } else {
                    let errorMsg = "Error: Local tool '\(toolCall.toolName)' execution logic not implemented."
                    print("ToolExecutor: \(errorMsg)")
                    return AppToolResult(id: toolCall.id, toolName: toolCall.toolName, content: errorMsg)
                }

            case .mcpService:
                guard let serviceName = toolDefinition.mcpServiceName else {
                    let errorMsg = "Error: MCP service name not configured for tool '\(toolCall.toolName)'."
                    print("ToolExecutor: \(errorMsg)")
                    return AppToolResult(id: toolCall.id, toolName: toolCall.toolName, content: errorMsg)
                }

                let client: MCP.Client = try await MCPServiceManager.shared.getClient(for: serviceName)

                let argumentsDict: [String: MCP.Value]?
                if let argsData = toolCall.args.data(using: .utf8), !toolCall.args.isEmpty {
                    let anyDict = try JSONSerialization.jsonObject(with: argsData, options: []) as? [String: Any]
                    argumentsDict = anyDict?.compactMapValues { MCP.Value(anyValue: $0) }
                } else {
                    argumentsDict = nil // Pass nil if tool expects no args or handles nil.
                                          // SDK client.callTool arguments parameter is optional: arguments: [String: Value]? = nil
                }

                // Check if argumentsDict is nil due to compactMapValues returning empty for non-convertible types,
                // yet args string was not empty. This could mean a parsing/conversion issue.
                if toolCall.args.data(using: .utf8) != nil && !toolCall.args.isEmpty && argumentsDict == nil && !toolCall.args.trimmingCharacters(in: .whitespacesAndNewlines).elementsEqual("{}") {
                     let errorMsg = "Error: Failed to convert arguments for tool '\(toolCall.toolName)' to [String: MCP.Value] from JSON: \(toolCall.args). Some values might be of unsupported types for direct MCP.Value conversion."
                     print("ToolExecutor: \(errorMsg)")
                     return AppToolResult(id: toolCall.id, toolName: toolCall.toolName, content: errorMsg)
                }

                print("ToolExecutor: Calling MCP service tool '\(toolDefinition.name)' on service '\(serviceName)' with MCP.Value args: \(String(describing: argumentsDict))")

                let (contentItems, isError) = try await client.callTool(name: toolDefinition.name, arguments: argumentsDict)

                if isError {
                    let errorContent = contentItems.compactMap { item -> String? in if case .text(let text) = item { return text } else { return nil } }.joined(separator: "\n")
                    let finalErrorMsg = "Error from MCP tool '\(toolDefinition.name)': \(errorContent.isEmpty ? "Unknown error from tool" : errorContent)"
                    print("ToolExecutor: \(finalErrorMsg)")
                    return AppToolResult(id: toolCall.id, toolName: toolCall.toolName, content: finalErrorMsg)
                }

                let resultString = contentItems.compactMap { item -> String? in
                    switch item {
                    case .text(let text): return text
                    case .image(_, let mimeType, _): return "[Image data of type \(mimeType) received]"
                    case .audio(_, let mimeType): return "[Audio data of type \(mimeType) received]"
                    case .resource(let uri, let mimeType, let text):
                        var resStr = "[Resource at \(uri) of type \(mimeType)"
                        if let txt = text { resStr += " with text: \(txt.prefix(50))..."}
                        resStr += "]"
                        return resStr
                    }
                }.joined(separator: "\n")

                return AppToolResult(id: toolCall.id, toolName: toolCall.toolName, content: resultString.isEmpty ? "[Empty or non-text response from tool]" : resultString)
            }
        } catch {
            let errorMsg = "Error executing tool '\(toolCall.toolName)': \(error.localizedDescription)"
            print("ToolExecutor: \(errorMsg)")
            return AppToolResult(id: toolCall.id, toolName: toolCall.toolName, content: errorMsg)
        }
    }
}

extension MCP.Value {
    // Helper to convert common Swift types to MCP.Value.
    init?(anyValue: Any) {
        switch anyValue {
        case let str as String: self = .string(str)
        case let num as NSNumber:
            // Check for CFBoolean first because NSNumber can represent Booleans.
            // CFBooleanGetTypeID() returns the type ID for CFBoolean.
            // CFGetTypeID(num) returns the type ID of the CoreFoundation object bridged from NSNumber.
            if CFGetTypeID(num) == CFBooleanGetTypeID() {
                 self = .bool(num.boolValue)
            } else if CFNumberIsFloatType(num) {
                self = .double(num.doubleValue)
            } else {
                self = .integer(num.int64Value)
            }
        case let array as [Any]: self = .array(array.compactMap { MCP.Value(anyValue: $0) })
        case let dict as [String: Any]: self = .object(dict.compactMapValues { MCP.Value(anyValue: $0) })
        // Explicitly handle Bool if it's not bridged as NSNumber in some contexts
        case let boolVal as Bool: self = .bool(boolVal)
        default:
            print("MCP.Value(anyValue:): Type \(type(of: anyValue)) is not directly convertible to MCP.Value with this helper. Value: \(anyValue)")
            return nil
        }
    }
}
