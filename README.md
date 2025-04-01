
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

# --- Client Example ---
$serverConfig = [McpServerConfig]@{
    Id = "my-stdio-server"
    Name = "My Stdio Server"
    TransportType = [McpTransportTypes]::StdIo
    Location = "path/to/your/mcp_server_executable.exe" # Or 'node', 'python', etc.
    Arguments = "--stdio" # Arguments for the server
    TransportOptions = @{ # Optional transport specific things
        # workingDirectory = "C:\path\to\server\dir"
    }
}

$clientOptions = [McpClientOptions]@{
    ClientInfo = [McpImplementation]@{ Name = "MyPowerShellClient"; Version = "0.1" }
    # Define client capabilities if needed (e.g., sampling handler)
    # Capabilities = ...
}

# Create and connect the client
$mcpClient = New-McpClient -ServerConfig $serverConfig -ClientOptions $clientOptions

try {
  Write-Host "Client Connected: $($mcpClient.IsConnected)"
  Write-Host "Server Name: $($mcpClient.ServerInfo.Name)"

  # Ping the server
  Write-Host "Pinging server..."
  $pingJob = $mcpClient.PingAsync([CancellationToken]::None)
  $pingJob | Wait-Job | Out-Null
  if ($pingJob.State -eq 'Failed') { throw $pingJob.Error[0].Exception }
  $pingResult = $pingJob | Receive-Job
  Write-Host "Ping Result: Success (raw result: $pingResult)" # PingResult is empty obj

  # List tools
  Write-Host "Listing tools..."
  $listToolsJob = $mcpClient.ListToolsAsync([CancellationToken]::None)
  $listToolsJob | Wait-Job | Out-Null
  if ($listToolsJob.State -eq 'Failed') { throw $listToolsJob.Error[0].Exception }
  $tools = $listToolsJob | Receive-Job # Returns List<McpClientTool>
  Write-Host "Found $($tools.Count) tools:"
  $tools.ForEach({ Write-Host " - $($_.ToString())" })

  # Call a tool (assuming 'echo' tool exists)
  if ($tools.Name -contains 'echo') {
    Write-Host "Calling 'echo' tool..."
    $callArgs = @{ message = "Hello from PowerShell MCP Client!" }
    $callToolJob = $mcpClient.CallToolAsync('echo', $callArgs, [CancellationToken]::None)
    $callToolJob | Wait-Job | Out-Null
    if ($callToolJob.State -eq 'Failed') { throw $callToolJob.Error[0].Exception }
    $callResultRaw = $callToolJob | Receive-Job
    # Deserialize the raw result object
    $callResult = [McpJsonUtilities]::DeserializeParams($callResultRaw, [McpCallToolResponse])

    if ($callResult.IsError) {
      Write-Warning "Tool call resulted in an error: $($callResult.Content[0].Text)"
    } else {
      Write-Host "Echo Tool Result: $($callResult.Content[0].Text)"
    }
    $callToolJob | Remove-Job
  }

  $pingJob | Remove-Job
  $listToolsJob | Remove-Job
} finally {
  Write-Host "Disposing client..."
  $mcpClient | Dispose
}


# --- Server Example ---

$serverOptions = [McpServerOptions]@{
    ServerInfo = [McpImplementation]@{ Name = "MyPowerShellServer"; Version = "0.1" }
    # Define server capabilities (optional, defaults are usually okay unless disabling something)
    # Capabilities = ...
}

# Define a tool using a scriptblock
$echoToolScript = {
    param($request, $cancellationToken) # McpJsonRpcRequest, CancellationToken
    # Handlers MUST return Task<object>
    $task = [Task]::Run( {
        $toolParams = [McpJsonUtilities]::DeserializeParams($request.Params, [McpCallToolRequestParams])
        $msg = $toolParams.Arguments.message ?? "No message provided"
        $responseText = "PowerShell Echo: $msg"
        # Return the correct response type
        return [McpCallToolResponse]@{ Content = @([McpContent]@{ Type = 'text'; Text = $responseText }); IsError = $false }
    }, $cancellationToken)
    return $task # Return the task
}

$echoToolDef = [McpTool]@{
    Name = 'echo'
    Description = 'Echoes back the input message.'
    InputSchema = [McpJsonUtilities]::Deserialize[System.Text.Json.JsonElement]('{"type":"object", "properties": {"message": {"type":"string"}}, "required":["message"]}')
}
$echoServerTool = [McpServerTool]::new($echoToolDef, $echoToolScript)

$toolCollection = [McpServerToolCollection]::new()
$toolCollection.AddOrUpdateTool($echoServerTool)

# Define request handlers (optional, server has built-ins for initialize, ping, tools/list, tools/call)
$requestHandlers = @{
    # "myCustomMethod" = { param($req, $ct) ... return [Task]::FromResult(...) }
}

# Start the server using Stdio
Write-Host "Starting MCP Server (Stdio)..."
$mcpServer = Start-McpServer -Options $serverOptions -TransportType StdIo -ToolCollection $toolCollection -RequestHandlers $requestHandlers -PassThru

Write-Host "Server started. Press Ctrl+C to stop."
try {
    # Keep running until interrupted
    while ($true) { Start-Sleep -Seconds 1 }
} finally {
    Write-Host "Stopping server..."
    $mcpServer | Dispose
    Write-Host "Server stopped."
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
