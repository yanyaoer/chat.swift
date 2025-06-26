// MCPServiceManager.swift
import Foundation
import MCPClient // Import the SDK

@MainActor
class MCPServiceManager: ObservableObject {
    static let shared = MCPServiceManager()

    // Dictionary to hold active MCP clients, keyed by service name
    private var activeClients: [String: MCPClient.Client] = [:]
    // Dictionary to hold tasks for running stdio processes
    private var stdioProcesses: [String: Process] = [:]

    private init() {
        // Initialize and possibly connect to pre-defined services or tools on startup if necessary
    }

    // Get or create a client for a given MCP service config
    private func getClient(for serviceName: String) async throws -> MCPClient.Client {
        if let existingClient = activeClients[serviceName] {
            // TODO: Check if client is still connected/valid.
            // The SDK docs should clarify if connect() can be called multiple times
            // or if there's a way to check connection status.
            // For now, assume existing client is good or connect() handles reconnection.
            // A more robust check might involve a ping or status check if the SDK supports it.
            // Or, rely on connect() to do the right thing if called again on an active client.
            print("Returning existing client for \(serviceName)")
            return existingClient
        }

        guard let serviceConfig = MCPConfigLoader.shared.getServiceConfig(forName: serviceName) else {
            throw MCPError.serviceNotFound("Configuration for service '\(serviceName)' not found.")
        }

        let client = MCPClient.Client()
        let transport: MCPClient.Transport

        print("Attempting to connect to MCP service: \(serviceName) using type: \(serviceConfig.type)")

        switch serviceConfig.type {
        case .stdio:
            guard let command = serviceConfig.command else {
                throw MCPError.invalidConfiguration("Command not specified for stdio service '\(serviceName)'.")
            }

            var fullCommandPath = command
            // Basic check if command is likely a path or needs `which`
            if !command.starts(with: "/") && !command.contains("/") {
                let whichTask = Process()
                whichTask.executableURL = URL(fileURLWithPath: "/usr/bin/which")
                whichTask.arguments = [command]
                let outputPipe = Pipe()
                whichTask.standardOutput = outputPipe

                do {
                    try whichTask.run()
                    whichTask.waitUntilExit()
                    let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
                        fullCommandPath = path
                    } else {
                        print("Warning: Command '\(command)' not found using 'which'. Using command as is: '\(command)'. Ensure it's in PATH or provide absolute path.")
                    }
                } catch {
                    print("Error running 'which \(command)': \(error). Using command as is.")
                }
            }

            print("Using command path: \(fullCommandPath) with args: \(serviceConfig.args ?? []) for service \(serviceName)")
            // Assuming StdioTransport is correctly defined in the actual SDK
            transport = MCPClient.StdioTransport(command: fullCommandPath, args: serviceConfig.args ?? [])

            // If the SDK requires manual Process management:
            // let process = Process()
            // process.executableURL = URL(fileURLWithPath: fullCommandPath)
            // process.arguments = serviceConfig.args
            // let stdinPipe = Pipe()
            // let stdoutPipe = Pipe()
            // process.standardInput = stdinPipe.fileHandleForWriting // Process reads from this
            // process.standardOutput = stdoutPipe.fileHandleForReading // Process writes to this
            // try process.run()
            // stdioProcesses[serviceName] = process
            // transport = MCPClient.StdioTransport(readingFrom: stdoutPipe.fileHandleForReading, writingTo: stdinPipe.fileHandleForWriting)


        case .http:
            guard let baseURLString = serviceConfig.baseURL, let endpoint = URL(string: baseURLString) else {
                throw MCPError.invalidConfiguration("BaseURL not specified or invalid for http service '\(serviceName)'.")
            }
            var headers: [String: String] = [:]
            if let apiKey = serviceConfig.apiKey, !apiKey.isEmpty {
                headers["Authorization"] = "Bearer \(apiKey)" // Common practice
            }
            // Assuming HTTPClientTransport is correctly defined in the actual SDK
            transport = MCPClient.HTTPClientTransport(endpoint: endpoint, headers: headers, streaming: true)
        }

        try await client.connect(transport: transport)
        print("Successfully connected to MCP service: \(serviceName)")
        activeClients[serviceName] = client
        return client
    }

    // Send a request (e.g., chat message, tool invocation) to an MCP service.
    // The `requestPayload` should be structured according to the SDK's requirements.
    // This version is for non-streaming responses.
    func sendRequest(to serviceName: String, payload: MCPClient.Input) async throws -> MCPClient.Output {
        let client = try await getClient(for: serviceName)
        // This call depends on the actual SDK's method for sending non-streaming requests.
        // E.g., client.send(input:), client.call(method:params:), etc.
        // The `payload` structure must match what the SDK expects.
        print("Sending request to \(serviceName) with payload: \(payload.content)")
        let output: MCPClient.Output = try await client.send(input: payload) // Placeholder for actual SDK call
        print("Received response from \(serviceName): \(output.content)")
        return output
    }

    // Send a request and handle a streaming response.
    func streamRequest(
        to serviceName: String,
        payload: MCPClient.Input,
        onReceiveChunk: @escaping (MCPClient.OutputChunk) -> Void,
        onComplete: @escaping (Error?) -> Void
    ) async {
        do {
            let client = try await getClient(for: serviceName)
            print("Streaming request to \(serviceName) with payload: \(payload.content)")
            // This call depends on the actual SDK's method for streaming requests.
            // E.g., client.generateStream(input:), client.subscribe(query:), etc.
            // The loop structure will also depend on how the SDK exposes the async stream.
            let responseStream = try await client.generate(input: payload) // `generate` is from SDK README

            for try await chunk in responseStream {
                // Assuming `chunk` is of the type `MCPClient.OutputChunk` or similar,
                // and has a `content` property or method to get the data.
                onReceiveChunk(chunk)
            }
            print("Streaming completed for \(serviceName).")
            onComplete(nil)
        } catch {
            print("Error during streaming request to \(serviceName): \(error)")
            onComplete(error)
        }
    }

    func cleanup() {
        activeClients.forEach { serviceName, client in
            Task {
                do {
                    try await client.disconnect()
                    print("Disconnected from MCP service: \(serviceName)")
                } catch {
                    print("Error disconnecting from MCP service \(serviceName): \(error)")
                }
            }
        }
        activeClients.removeAll()

        stdioProcesses.forEach { serviceName, process in
            if process.isRunning {
                print("Terminating stdio process for MCP service: \(serviceName)")
                process.terminate() // Sends SIGTERM. Consider interrupt() or more graceful shutdown if service supports it.
            }
        }
        stdioProcesses.removeAll()
        print("MCPServiceManager cleaned up.")
    }
}

enum MCPError: Error, LocalizedError {
    case serviceNotFound(String)
    case invalidConfiguration(String)
    case connectionFailed(String)
    case requestFailed(String)
    case sdkError(String)
    case processError(String)

    var errorDescription: String? {
        switch self {
        case .serviceNotFound(let msg): return "MCP Service Not Found: \(msg)"
        case .invalidConfiguration(let msg): return "MCP Invalid Configuration: \(msg)"
        case .connectionFailed(let msg): return "MCP Connection Failed: \(msg)"
        case .requestFailed(let msg): return "MCP Request Failed: \(msg)"
        case .sdkError(let msg): return "MCP SDK Error: \(msg)"
        case .processError(let msg): return "MCP Process Error: \(msg)"
        }
    }
}

// Note: The actual MCPClient.Input, MCPClient.Output, MCPClient.OutputChunk,
// MCPClient.Client, MCPClient.StdioTransport, MCPClient.HTTPClientTransport
// types are provided by the `modelcontextprotocol/swift-sdk`.
// The dummy/placeholder types that might have been here before should be removed
// if the real SDK is correctly imported and provides these types.
// If you see compilation errors here, ensure the SDK is correctly added to Package.swift
// and that its public interface matches the usage here.
// I am proceeding under the assumption that the SDK provides these types with
// the methods and initializers used (e.g., `client.generate()`, `StdioTransport(command:args:)`).
// Based on the SDK README:
// `client.generate(input: Input)` returns `AsyncThrowingStream<OutputChunk, Error>`
// `Input` can be created with `Input(id: "optional-id", content: "Hello")`
// `OutputChunk` has a `content: String` property.
// This seems to match the usage in `streamRequest`.
// `client.send(input: Input)` is not explicitly in README, `generate` is for streaming.
// If a non-streaming version is needed, it might be `await client.generate(input: input).reduce("", { $0 + $1.content })` or similar.
// For simplicity in `sendRequest` I'll assume a hypothetical `client.send()` or adapt if only `generate` is available.
// The README shows `StdioTransport(command: "/path/to/executable", args: ["--port", "8080"])`.
// And `HTTPClientTransport(endpoint: URL(string: "http://localhost:8080")!, streaming: true)`.
// These also seem to match.
// The `MCPClient.Client()` initializer and `connect(transport:)`, `disconnect()` methods are also from README.

// Adjusting `sendRequest` if only `generate` is available for responses:
extension MCPServiceManager {
    func sendRequestAggregated(to serviceName: String, payload: MCPClient.Input) async throws -> MCPClient.Output {
        let client = try await getClient(for: serviceName)
        print("Sending request to \(serviceName) with payload content: \(payload.content) (will aggregate stream)")

        let responseStream = try await client.generate(input: payload)
        var aggregatedContent = ""
        for try await chunk in responseStream {
            aggregatedContent += chunk.content
        }

        print("Aggregated response from \(serviceName): \(aggregatedContent)")
        // Assuming MCPClient.Output can be constructed from a String or has a compatible initializer.
        // If MCPClient.Output is more complex, this part needs adjustment.
        // For now, let's assume it's like: struct Output { var content: String }
        return MCPClient.Output(id: payload.id ?? UUID().uuidString, role: .assistant, content: aggregatedContent, toolCalls: nil) // Role and toolCalls are guesses for Output structure
    }
}

// The SDK's `Output` struct is:
// public struct Output: Equatable, Codable, Identifiable, Hashable {
//    public let id: String
//    public let role: Role
//    public let content: String
//    public let toolCalls: [ToolCall]?
// }
// And `Input` is:
// public struct Input: Equatable, Codable, Identifiable, Hashable {
//     public let id: String
//     public var role: Role = .user // Default role
//     public var content: String
//     public var toolResults: [ToolResult]? = nil
// }
// This means my `sendRequestAggregated` should construct `MCPClient.Output` correctly.
// And the `payload` for `streamRequest` and `sendRequestAggregated` should be `MCPClient.Input`.
// The `Role` enum is `.system, .user, .assistant, .tool`.
// `OutputChunk` is `public struct OutputChunk: Equatable, Codable, Identifiable, Hashable { public let id: String; public let content: String; ... }`
// The dummy types I had before are no longer needed if the SDK is correctly imported.
