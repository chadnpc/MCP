function Start-McpServer {
  <#
  .SYNOPSIS
  Starts an MCP server that listens for a client connection (currently via Stdio).
  .DESCRIPTION
  Initializes an MCP server instance using the provided options. It sets up the
  specified transport (defaulting to Stdio using Console streams) and starts
  listening for an incoming client connection and the 'initialize' request.
  Uses the 'cliHelper.logger' module for logging. If no logger is provided,
  a default console logger will be created. The caller is responsible for
  disposing the logger instance and keeping the script alive for the server to run.
  .PARAMETER Options
  An [McpServerOptions] object containing server information and capabilities.
  .PARAMETER InputStream
  [Optional] The stream to use for reading client messages (Defaults to Console stdin).
  Used for Stdio transport.
  .PARAMETER OutputStream
  [Optional] The stream to use for writing messages to the client (Defaults to Console stdout).
  Used for Stdio transport.
  .PARAMETER Logger
  [Optional] A pre-configured logger instance from the 'cliHelper.logger' module.
  If not provided, a default logger (writing Info level to console) will be created internally.
  The caller is responsible for disposing this logger instance using $logger.Dispose().
  .EXAMPLE
  # Requires cliHelper.logger to be imported
  Import-Module cliHelper.logger
  $serverOptions = [McpServerOptions]::new("MyToolServer", "1.0.0")
  $serverOptions.Capabilities.Tools = [McpToolsCapability]::new()
  $myLogger = New-Logger -MinimumLevel Debug -Logdirectory "C:\logs\mcp_server"

  $server = $null
  try {
    # Start the server, passing the logger
    $server = Start-McpServer -Options $serverOptions -Logger $myLogger

    # Register request handlers...
    $server.RegisterRequestHandler("tools/list", { param($p,$c) return [McpListToolsResult]::new() })

    Write-Host "Server started. Keep script running. Press Ctrl+C to stop."
    while ($server.IsConnected) { Start-Sleep -Seconds 1 }

  } catch {
    Write-Error "Server failed: $($_.Exception.Message)"
  } finally {
    # Dispose server first (stops jobs, etc.)
    if ($null -ne $server) { $server.Dispose() }
    # Then dispose the logger you created
    $myLogger.Dispose()
  }
  .EXAMPLE
  # Using default logger (writes to console)
  $serverOptions = [McpServerOptions]::new("SimpleServer", "0.1")
  $server = $null
  try {
     $server = Start-McpServer -Options $serverOptions
     # Register handlers...
     Write-Host "Server started (default logger). Press Ctrl+C to stop."
     while ($server.IsConnected) { Start-Sleep -Seconds 1 }
  } finally {
      if ($null -ne $server) { $server.Dispose() }
      # No logger to dispose here as it was default/internal
  }
  .NOTES
  Relies on the [MCP]::StartServer static method for implementation.
  Ensure the 'cliHelper.logger' module is available.
  The caller is responsible for disposing the provided or default logger instance.
  The caller's script must remain active for the server to continue processing messages.
  .LINK
  MCP
  McpServer
  McpServerOptions
  cliHelper.logger.Logger
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [McpServerOptions]$Options,

    # Parameters for Stdio transport (default)
    [Stream]$InputStream = ([ref][Console]::OpenStandardInput()).Value,
    [Stream]$OutputStream = ([ref][Console]::OpenStandardOutput()).Value,

    # Added Logger parameter: Type is cliHelper.logger.Logger, Not Mandatory
    [Parameter(Mandatory = $false)]
    [cliHelper.logger.Logger]$Logger # Caller provides instance, responsible for disposal

    # Add params for other transports later (e.g., -Port for SSE)
  )

  try {
    # Delegate entirely to the static factory method in MCP class
    # It now handles default logger creation if $Logger is $null
    $server = [MCP]::StartServer(
      $Options,
      $InputStream,
      $OutputStream,
      $Logger # Pass provided logger or null
    )
    # Return the successfully started server
    return $server
  } catch {
    # Catch exceptions from StartServer and rethrow as terminating errors
    $PSCmdlet.ThrowTerminatingError(
      [System.Management.Automation.ErrorRecord]::new(
        $_.Exception,
        "FailedToStartMcpServer",
        [System.Management.Automation.ErrorCategory]::InvalidOperation,
        $null
      )
    )
  }
}