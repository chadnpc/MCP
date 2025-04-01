
# [MCP](https://www.powershellgallery.com/packages/MCP)

Provides core framework for building MCP-compliant AI agents and tools in PowerShell.

[![Build Module](https://github.com/chadnpc/MCP/actions/workflows/build.yaml/badge.svg)](https://github.com/chadnpc/MCP/actions/workflows/build.yaml)
[![Downloads](https://img.shields.io/powershellgallery/dt/MCP.svg?style=flat&logo=powershell&color=blue)](https://www.powershellgallery.com/packages/MCP)

## Usage

```PowerShell
Install-Module MCP
```

then

```PowerShell
Import-Module MCP

Write-Host "--- MCP PowerShell SDK Example Server ---"

try {
    $serverOptions = [McpServerOptions]::new("MyStaticServer", "1.2.0")
    $serverOptions.Capabilities.Tools = [McpToolsCapability]::new()
    $serverOptions.Logger = [McpConsoleLogger]::new([McpLoggingLevel]::Debug, "MyStaticServer")

    # Use the static factory method
    $server = [MCP]::StartServer($serverOptions) # Assumes using console stdio

    # Register handlers (same as before)
    $server.RegisterRequestHandler("tools/list", {
        param($params, $cancellationToken)
        $serverOptions.Logger.Log([McpLoggingLevel]::Info, "Handling tools/list request.")
        $tool1 = [McpTool]::new("echo_tool", "Echoes input.", @{ type = 'object'; properties = @{ 'input_string' = @{ type = 'string'} }; required = @('input_string') })
        $tool2 = [McpTool]::new("get_date", "Returns current date.", @{ type = 'object'; properties = @{} })
        return [McpListToolsResult]@{ Tools = @($tool1, $tool2) }
    })
    $server.RegisterRequestHandler("tools/call", {
        param($paramsRaw, $cancellationToken)
        $callParams = [McpJsonUtilities]::DeserializeParams($paramsRaw, [McpCallToolRequestParams])
        $serverOptions.Logger.Log([McpLoggingLevel]::Info, "Handling tools/call for '$($callParams.Name)'.")
        $response = [McpCallToolResponse]::new()
        # ... (rest of handler logic as before) ...
        return $response
    })

    Write-Host "Server started via MCP::StartServer. Waiting for client..."
    Write-Host "Press Ctrl+C to stop."

    # Keep alive loop (same as before)
    while ($server.IsConnected) {
        Start-Sleep -Seconds 1
        if ($server._endpoint._messageProcessingJob.State -eq 'Failed') {
            Write-Error "Server processing job failed!"
            break
        }
    }

} catch {
    Write-Error "Server failed to start or run: $($_.Exception.ToString())"
} finally {
    if ($null -ne $server) {
        Write-Host "Shutting down server..."
        $server.Dispose()
    }
}


# --- Example Client Usage ---
try {
    $clientOptions = [McpClientOptions]::new()
    $clientOptions.Logger = [McpConsoleLogger]::new([McpLoggingLevel]::Debug, "MyClient")

    # Use the static factory method
    $client = [MCP]::CreateClient(
        Command = "pwsh", # Assuming the server script is run with pwsh
        Arguments = @("-File", "path/to/your/server/script.ps1"),
        Options = $clientOptions
    )

    Write-Host "Client connected to Server: $($client.ServerInfo.Name) v$($client.ServerInfo.Version)"

    # Example: List tools
    $listToolsJob = $client.ListAllToolsAsync()
    $listToolsJob | Wait-Job
    if ($listToolsJob.State -eq 'Completed') {
        $allTools = $listToolsJob | Receive-Job
        Write-Host "Available Tools:"
        $allTools.ForEach({ Write-Host "- $($_.Name): $($_.Description)"})
    } else { Write-Error "Failed to list tools: $($listToolsJob.Error[0].Exception.Message)" }
    $listToolsJob | Remove-Job

    # Example: Call echo tool
    $echoArgs = @{ input_string = "Hello from PowerShell Client!" }
    $callJob = $client.CallToolAsync("echo_tool", $echoArgs)
    $callJob | Wait-Job
    if ($callJob.State -eq 'Completed') {
        $callResult = $callJob | Receive-Job
        Write-Host "CallTool Result: $($callResult.Content[0].Text)"
    } else { Write-Error "Failed to call tool: $($callJob.Error[0].Exception.Message)" }
    $callJob | Remove-Job

} catch {
     Write-Error "Client failed: $($_.Exception.ToString())"
} finally {
     if ($null -ne $client) {
          Write-Host "Closing client..."
          $client.Dispose()
     }
}

```

## v0.1.1 Changelog

1. **Core Protocol Implementation**
   - JSON-RPC 2.0 compliant message classes (`JSONRPCRequest`, `JSONRPCResponse`, `JSONRPCNotification`)
   - Full MCP enumeration support (`ErrorCodes`, `Role`, `LoggingLevel`, etc.)
   - Protocol version negotiation (`2024-11-05` as default)

2. **Session Management**
   - `McpSession` class with:
     - Connection lifecycle management (connect/reconnect/close)
     - Async message queuing and processing
     - Request/response correlation
     - Notification handler registry

3. **Transport Layer**
   - `StdioClientTransport` for process-based communication
   - `HttpClientTransport` for HTTP/SSE streaming
   - Thread-safe message serialization/deserialization

4. **Type Safety & Serialization**
   - `ObjectMapper` class for JSON ↔ POCO conversion
   - Automatic enum parsing
   - Nested object support in `JsonSchema`

5. **Error Handling**
   - Structured `McpError` exceptions
   - Protocol-compliant error codes
   - Timeout and cancellation support

---

### **Limitations and TODOs**
- HTTP transport lacks retry logic
- Limited schema validation for tool inputs
- Async/await pattern requires PowerShell 7+
- Server-side implementation
- Advanced resource templating
- Built-in telemetry
- CI/CD pipeline support

## License

This project is licensed under the [WTFPL License](LICENSE).
