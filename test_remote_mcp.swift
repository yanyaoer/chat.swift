#!/usr/bin/env swift

import Foundation

// Simple test for remote MCP server connectivity
let testURL = "https://api.githubcopilot.com/mcp/"

// Test basic connectivity
if let url = URL(string: testURL) {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("chat.swift-mcp-client", forHTTPHeaderField: "User-Agent")
    
    // Test tools/list endpoint to see available tools
    let requestBody: [String: Any] = [
        "method": "tools/list",
        "params": [:]
    ]
    
    do {
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        
        let semaphore = DispatchSemaphore(value: 0)
        var testResult = "Unknown"
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            
            if let error = error {
                testResult = "❌ Network error: \(error.localizedDescription)"
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    if let data = data,
                       let jsonResponse = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        testResult = "✅ Remote GitHub MCP Server is accessible"
                        print("Response: \(jsonResponse)")
                    } else {
                        testResult = "⚠️ Got response but couldn't parse JSON"
                    }
                } else {
                    let errorData = data.flatMap { String(data: $0, encoding: .utf8) } ?? "No error data"
                    testResult = "❌ HTTP \(httpResponse.statusCode): \(errorData)"
                }
            }
        }.resume()
        
        semaphore.wait()
        print(testResult)
        
    } catch {
        print("❌ Failed to create request: \(error)")
    }
} else {
    print("❌ Invalid URL")
}