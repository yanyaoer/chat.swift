// MCPServiceManager.swift
import Foundation
import MCP // Updated import

@MainActor // Shared instance and methods are often called from main actor contexts (e.g. ChatHistory)
class MCPServiceManager: ObservableObject {
    static let shared = MCPServiceManager()

    // Dictionary to hold active MCP clients, keyed by service name
    private var activeClients: [String: MCP.Client] = [:] // Updated to MCP.Client
    // Dictionary to hold tasks for running stdio processes
    private var stdioProcesses: [String: Process] = [:]

    private init() {
        // Initialize and possibly connect to pre-defined services or tools on startup if necessary
    }

    // Get or create a client for a given MCP service config
    private func getClient(for serviceName: String) async throws -> MCP.Client { // Updated to MCP.Client
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

        // Updated client initialization for SDK 0.9.0
        let client = MCP.Client(name: "ChatApp", version: "1.0.0", logger: nil)
        let transport: MCP.Transport // Updated to MCP.Transport

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

            let process = Process()
            process.executableURL = URL(fileURLWithPath: fullCommandPath)
            process.arguments = serviceConfig.args

            let stdinForProcess = Pipe() // What the process will read from (app writes to this)
            let stdoutFromProcess = Pipe() // What the process will write to (app reads from this)

            process.standardInput = stdinForProcess.fileHandleForReading
            process.standardOutput = stdoutFromProcess.fileHandleForWriting
            // TODO: Consider process.standardError for logging

            do {
                try process.run()
                stdioProcesses[serviceName] = process // Manage the process
                print("MCPServiceManager: Started stdio process for \(serviceName) (PID: \(process.processIdentifier))")
            } catch {
                throw AppMCPError.processError("Failed to run stdio process for \(serviceName): \(error.localizedDescription)")
            }

            // StdioTransport takes file handles for its input (reading from process stdout) and output (writing to process stdin)
            transport = MCP.StdioTransport(
                input: stdoutFromProcess.fileHandleForReading, // SDK reads from process's stdout
                output: stdinForProcess.fileHandleForWriting,  // SDK writes to process's stdin
                logger: nil // Optional logger
            )

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
            // For SDK 0.9.0, headers are not directly in constructor in basic example.
            // This might require a different way to set headers or they are part of a request object.
            // For now, assuming a simple init. If headers are needed, this needs revisiting post SDK update.
            transport = MCP.HTTPClientTransport(endpoint: endpoint, streaming: true, logger: nil) // logger is optional
        }

        // The connect method in SDK 0.9.0 returns `Initialization.Result`
        // We can choose to ignore it if not checking capabilities immediately.
        _ = try await client.connect(transport: transport)
        print("Successfully connected to MCP service: \(serviceName)")
        activeClients[serviceName] = client
        return client
    }

    // The generic sendRequest, streamRequest, and sendRequestAggregated methods
    // based on the old SDK's Input/Output/OutputChunk model are no longer valid
    // for SDK 0.9.0, which uses specific methods like `callTool`.
    // These will be removed. `ToolExecutor` will use `client.callTool` directly.
    // If direct "chat" with an MCP service is needed, it will be handled as a
    // specific tool call (e.g., a tool named "chat").

    func cleanup() {
        activeClients.forEach { serviceName, client in
            Task {
                // MCP.Client.disconnect() is async but not throwing according to SDK 0.9.0 README examples
                await client.disconnect()
                print("Disconnected from MCP service: \(serviceName)")
                // No catch needed if disconnect() isn't throwing
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

// Custom Error type for MCP related operations within the app.
// Removed explicit raw type 'Error' as it's not needed and conflicts with associated values.
// Conforms to Swift.Error and LocalizedError for standard error handling.
enum AppMCPError: Error, LocalizedError { // Renamed to AppMCPError to avoid any potential clash with SDK's MCPError if it exists as a protocol/typealias.
    case serviceNotFound(String)
    case invalidConfiguration(String)
    case connectionFailed(String)
    case requestFailed(String)
    case sdkError(String) // For wrapping errors from the MCP SDK itself
    case processError(String)
    case argumentParsingError(String)

    var errorDescription: String? {
        switch self {
        case .serviceNotFound(let msg): return "AppMCPError: Service Not Found - \(msg)"
        case .invalidConfiguration(let msg): return "AppMCPError: Invalid Configuration - \(msg)"
        case .connectionFailed(let msg): return "AppMCPError: Connection Failed - \(msg)"
        case .requestFailed(let msg): return "AppMCPError: Request Failed - \(msg)"
        case .sdkError(let msg): return "AppMCPError: SDK Error - \(msg)"
        case .processError(let msg): return "AppMCPError: Process Error - \(msg)"
        case .argumentParsingError(let msg): return "AppMCPError: Argument Parsing Error - \(msg)"
        }
    }
}

// The generic sendRequestAggregated method and its related comments about MCPClient.Input/Output
// are removed as they are based on the old SDK (0.7.1-like) assumptions and not compatible
// with MCP SDK 0.9.0's client.callTool() and specific request/result types.
// Interaction with MCP services will primarily be through client.callTool() via ToolExecutor.
