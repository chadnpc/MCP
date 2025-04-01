function New-McpClient {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Command, # e.g., 'node', 'python', 'path/to/server.exe'

    [string[]]$Arguments,

    [string]$WorkingDirectory,

    [hashtable]$EnvironmentVariables,

    [McpClientOptions]$Options,

    [McpLogger]$Logger,

    [int]$ConnectTimeoutSeconds = 30 # Timeout for connection and initialize
  )

  $clientOptions = $Options ?? [McpClientOptions]::new()
  $clientLogger = $Logger ?? $clientOptions.Logger ?? [McpConsoleLogger]::new([McpLoggingLevel]::Info, "MCP-Client")
  $clientOptions.Logger = $clientLogger # Ensure options has logger

  $endpointName = "Client ($($clientOptions.ClientInfo.Name) for $Command)"
  $client = $null
  $transport = $null

  try {
    $clientLogger.Log([McpLoggingLevel]::Info, "Creating Stdio transport for $Command")
    $transport = [McpStdioTransport]::new(
      $Command,
            ($Arguments -join ' '),
      $WorkingDirectory,
      $EnvironmentVariables,
      $clientLogger
    )

    $clientLogger.Log([McpLoggingLevel]::Info, "Creating endpoint: $endpointName")
    $endpoint = [McpEndpoint]::new($transport, $endpointName, $clientLogger)

    $client = [McpClient]::new($endpoint, $clientOptions)

    $clientLogger.Log([McpLoggingLevel]::Info, "Attempting to connect transport...")
    $transport.Connect() # Starts process and reading job

    $clientLogger.Log([McpLoggingLevel]::Info, "Starting endpoint processing...")
    $endpoint.StartProcessing() # Starts the message handling job

    $clientLogger.Log([McpLoggingLevel]::Info, "Sending initialize request...")
    $initParams = [McpInitializeRequestParams]@{
      ProtocolVersion = $clientOptions.ProtocolVersion
      ClientInfo      = $clientOptions.ClientInfo
      Capabilities    = $clientOptions.Capabilities
    }

    # Send initialize and wait for response with timeout
    $initJob = $client.SendRequestAsync("initialize", $initParams, [McpInitializeResult], ([TimeSpan]::FromSeconds($ConnectTimeoutSeconds)))
    $initJob | Wait-Job -Timeout $ConnectTimeoutSeconds # Throws TimeoutException or other on failure

    $initResult = $initJob | Receive-Job
    $initJob | Remove-Job

    if ($null -eq $initResult) {
      throw [McpClientException]::new("Did not receive valid InitializeResult from server.")
    }

    $clientLogger.Log([McpLoggingLevel]::Info, "Received InitializeResult from Server: $($initResult.ServerInfo.Name) v$($initResult.ServerInfo.Version) (Proto: $($initResult.ProtocolVersion))")
    $client.SetServerInfo($initResult) # Update client with server details

    # Send initialized notification
    $clientLogger.Log([McpLoggingLevel]::Info, "Sending initialized notification...")
    $client.SendNotification("initialized", $null) # Params are typically null/empty

    $clientLogger.Log([McpLoggingLevel]::Info, "MCP Client initialization successful.")
    return $client
  } catch [TimeoutException] {
    $clientLogger.Log([McpLoggingLevel]::Critical, "Timeout waiting for client connection or initialization.")
    if ($null -ne $client) { try { $client.Dispose() } catch { $null } }
    elseif ($null -ne $transport) { try { $transport.Dispose() } catch { $null } }
    throw # Rethrow
  } catch {
    $clientLogger.Log([McpLoggingLevel]::Critical, "Failed to create or initialize MCP client: $($_.Exception.ToString())")
    # Ensure cleanup
    if ($null -ne $client) { try { $client.Dispose() } catch { $null } }
    elseif ($null -ne $transport) { try { $transport.Dispose() } catch { $null } }
    throw # Rethrow
  }
}