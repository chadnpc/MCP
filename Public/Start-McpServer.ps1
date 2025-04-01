# Factory Function for Server (Stdio only for now)
function Start-McpServer {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [McpServerOptions]$Options,

    # Parameters for Stdio transport (default)
    [Stream]$InputStream = ($stdin = [Console]::OpenStandardInput()), # Capture stdin ref
    [Stream]$OutputStream = ($stdout = [Console]::OpenStandardOutput()) # Capture stdout ref
    # Add params for other transports later (e.g., -Port for SSE)
  )

  $serverOptions = $Options # Use provided options
  $serverLogger = $serverOptions.Logger ?? [McpConsoleLogger]::new([McpLoggingLevel]::Info, "MCP-Server")
  $serverOptions.Logger = $serverLogger # Ensure options has logger

  $endpointName = "Server ($($serverOptions.ServerInfo.Name))"
  $server = $null
  $transport = $null

  try {
    # --- Transport Creation (Stdio for now) ---
    $serverLogger.Log([McpLoggingLevel]::Info, "Creating Stdio server transport using console streams.")
    # Ensure we are not trying to read/write Console streams if they are redirected strangely
    # This check might need refinement depending on how the script is run.
    if (($InputStream -eq $stdin -and [Console]::IsInputRedirected) -or ($OutputStream -eq $stdout -and ([Console]::IsOutputRedirected -or [Console]::IsErrorRedirected))) {
      $serverLogger.Log([McpLoggingLevel]::Warning, "Console streams appear redirected. Stdio transport might not work as expected.")
    }

    $transport = [McpStdioTransport]::new(
      $InputStream,
      $OutputStream,
      $serverLogger
    )

    # --- Endpoint & Server Creation ---
    $serverLogger.Log([McpLoggingLevel]::Info, "Creating server endpoint: $endpointName")
    $endpoint = [McpEndpoint]::new($transport, $endpointName, $serverLogger)

    $server = [McpServer]::new($endpoint, $serverOptions)

    # --- Start Connection & Processing ---
    # For stdio server, "Connect" just means start reading the input stream
    $serverLogger.Log([McpLoggingLevel]::Info, "Connecting server transport (starting input reader)...")
    $transport.Connect() # Starts the reading job

    $serverLogger.Log([McpLoggingLevel]::Info, "Starting server endpoint processing...")
    $endpoint.StartProcessing() # Starts the message handling job

    $serverLogger.Log([McpLoggingLevel]::Info, "MCP Server started and waiting for client 'initialize' request.")

    # The server is now running. Return the server object so the user can register
    # additional handlers or interact with it.
    # The caller needs to keep the script running (e.g., using Wait-Job on the processing job or a loop).
    return $server

  } catch {
    $serverLogger.Log([McpLoggingLevel]::Critical, "Failed to start MCP server: $($_.Exception.ToString())")
    # Ensure cleanup
    if ($null -ne $server) { try { $server.Dispose() } catch { $null } }
    elseif ($null -ne $transport) { try { $transport.Dispose() } catch { $null } }
    throw # Rethrow
  }
}