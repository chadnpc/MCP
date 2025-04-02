## [![MCP](docs/images/MCP.png)](https://www.powershellgallery.com/packages/MCP)

A PowerShell module for building MCP-compliant ai agents and tools in your terminal.

[![Downloads](https://img.shields.io/powershellgallery/dt/MCP.svg?style=flat&logo=powershell&color=blue)](https://www.powershellgallery.com/packages/MCP)
ver `0.1.1` **α**


## Installation

```PowerShell
# Install both modules
Install-Module MCP
```

## Usage

```PowerShell
# Import necessary modules
Import-Module MCP

# --- Example Server Setup ---
# 1. Create a logger instance (caller is responsible for disposing this)
$serverLogger = New-Logger -MinimumLevel Debug -Logdirectory "C:\Logs\MyMCPServer"
# Add a JSON appender for structured logs if desired
$serverLogger | Add-JsonAppender -FilePath "C:\Logs\MyMCPServer\server_events.json"

$server = $null
try {
  # Configure server options and pass the logger
  $serverOptions = [McpServerOptions]::new("MyPowerShellTool", "1.2.0")
  $serverOptions.Capabilities.Tools = [McpToolsCapability]::new()
  # Logger is now passed via the parameter in Start-McpServer or MCP::StartServer
  # $serverOptions.Logger = $serverLogger # No longer set directly in options for start

  Write-Host "--- MCP PowerShell SDK Example Server ---"

  # Start the server using the cmdlet, passing the logger
  $server = Start-McpServer -Options $serverOptions -Logger $serverLogger
  # Or using the static factory:
  # $server = [MCP]::StartServer($serverOptions, $serverLogger)

  # Register request handlers
  $server.RegisterRequestHandler("tools/list", {
      param($params, $cancellationToken)
      # Use the logger instance captured in the server object's scope
      $script:serverLogger.Info("Handling tools/list request.")
      $tool1 = [McpTool]::new("echo_tool", "Echoes input.", @{ type = 'object'; properties = @{ 'input_string' = @{ type = 'string' } }; required = @('input_string') })
      $tool2 = [McpTool]::new("get_date", "Returns current date.", @{ type = 'object'; properties = @{} })
      return [McpListToolsResult]@{ Tools = @($tool1, $tool2) }
    }
  )
  $server.RegisterRequestHandler("tools/call", {
      param($paramsRaw, $cancellationToken)
      $callParams = [McpJsonUtilities]::DeserializeParams($paramsRaw, [McpCallToolRequestParams])
      $script:serverLogger.Info("Handling tools/call for '$($callParams.Name)'.")
      $response = [McpCallToolResponse]::new()
      if ($callParams.Name -eq "echo_tool") {
        $inputText = $callParams.Arguments.input_string
        $response.Content.Add([McpContent]@{ Type = 'text'; Text = "Server echoed: $inputText" })
      } elseif ($callParams.Name -eq "get_date") {
        $response.Content.Add([McpContent]@{ Type = 'text'; Text = "Current date: $(Get-Date)" })
      } else {
        $response.IsError = $true
        $response.Content.Add([McpContent]@{ Type = 'text'; Text = "Unknown tool: $($callParams.Name)" })
      }
      return $response
    }
  )

  Write-Host "Server started. Waiting for client..."
  Write-Host "Check logs in C:\Logs\MyMCPServer"
  Write-Host "Press Ctrl+C to stop."

  # Keep alive loop (check endpoint status)
  while ($server.IsConnected) {
    Write-Progress "Listening" -Status "..."
    Start-Sleep -Seconds 1
    # Access the internal endpoint's job state for monitoring (use cautiously)
    if ($server._endpoint._messageProcessingJob -and $server._endpoint._messageProcessingJob.State -eq 'Failed') {
      $script:serverLogger.Error("Server processing job failed!", $server._endpoint._messageProcessingJob.Error[0].Exception)
      break
    }
  }
} catch {
  # Log the failure using the logger
  $serverLogger.Fatal("Server failed to start or run.", $_.Exception)
  Write-Error "Server failed: $($_.Exception.ToString())"
} finally {
  if ($null -ne $server) {
    Write-Host "Shutting down server..."
    $server.Dispose()
  }
  if ($null -ne $serverLogger) {
    Write-Host "Disposing server logger..."
    $serverLogger.Dispose()
  }
}


# --- Example Client Usage ---
$clientLogger = New-Logger -MinimumLevel Debug -Logdirectory "C:\Logs\MyMCPClient"

$client = $null
try {
  # Assume server script is "path/to/your/server/script.ps1"
  $client = New-McpClient `
    -Command "pwsh" `
    -Arguments @("-File", "path/to/your/server/script.ps1") `
    -Logger $clientLogger
  # Or using the static factory:
  # $clientOptions = [McpClientOptions]::new() # Options are optional
  # $client = [MCP]::CreateClient(...) -Logger $clientLogger

  Write-Host "Client connected to Server: $($client.ServerInfo.Name) v$($client.ServerInfo.Version)"
  $clientLogger.Info("Client connected successfully.")

  # Example: List tools
  $listToolsJob = $client.ListAllToolsAsync()
  $listToolsJob | Wait-Job
  if ($listToolsJob.State -eq 'Completed') {
    $allTools = $listToolsJob | Receive-Job
    Write-Host "Available Tools:"
    $allTools.ForEach({ Write-Host "- $($_.Name): $($_.Description)" })
    $clientLogger.Debug("Successfully listed $($allTools.Count) tools.")
  } else {
     $errorMsg = "Failed to list tools: $($listToolsJob.Error[0].Exception.Message)"
     $clientLogger.Error($errorMsg, $listToolsJob.Error[0].Exception)
     Write-Error $errorMsg
  }
  $listToolsJob | Remove-Job

  # Example: Call echo tool
  $echoArgs = @{ input_string = "Hello from PowerShell Client!" }
  $callJob = $client.CallToolAsync("echo_tool", $echoArgs)
  $callJob | Wait-Job
  if ($callJob.State -eq 'Completed') {
    $callResult = $callJob | Receive-Job
    Write-Host "CallTool Result: $($callResult.Content[0].Text)"
    $clientLogger.Debug("Successfully called 'echo_tool'. Result: $($callResult.Content[0].Text)")
  } else {
     $errorMsg = "Failed to call tool 'echo_tool': $($callJob.Error[0].Exception.Message)"
     $clientLogger.Error($errorMsg, $callJob.Error[0].Exception)
     Write-Error $errorMsg
   }
  $callJob | Remove-Job

} catch {
  # Log the failure using the logger
  $clientLogger.Fatal("Client operation failed.", $_.Exception)
  Write-Error "Client failed: $($_.Exception.ToString())"
} finally {
  if ($null -ne $client) {
    Write-Host "Closing client..."
    $client.Dispose()
  }
  if ($null -ne $clientLogger) {
    Write-Host "Disposing client logger..."
    $clientLogger.Dispose()
  }
}
```

## License

This project is licensed under the [WTFPL License](LICENSE).