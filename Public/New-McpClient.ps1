function New-McpClient {
  <#
  .SYNOPSIS
  Creates and initializes a new MCP client connection to a server process.
  .DESCRIPTION
  Launches a server process using the specified command and arguments,
  establishes a connection (currently via Stdio), and performs the MCP
  initialization handshake. Returns a connected and initialized McpClient object.
  Uses the 'cliHelper.logger' module for logging. If no logger is provided,
  a default console logger will be created. The caller is responsible for
  disposing the logger instance when done.
  .PARAMETER Command
  The command or path to the executable that runs the MCP server.
  (e.g., 'node', 'python', 'path/to/server.exe')
  .PARAMETER Arguments
  An array of arguments to pass to the server command.
  .PARAMETER WorkingDirectory
  The working directory for the server process. Defaults to the current directory.
  .PARAMETER EnvironmentVariables
  A hashtable of environment variables to set for the server process.
  .PARAMETER Options
  [Optional] An [McpClientOptions] object to configure client behavior.
  .PARAMETER Logger
  [Optional] A pre-configured logger instance from the 'cliHelper.logger' module.
  If not provided, a default logger (writing Info level to console) will be created internally.
  The caller is responsible for disposing this logger instance using $logger.Dispose().
  .PARAMETER ConnectTimeoutSeconds
  The timeout in seconds for establishing the connection and receiving the
  initialization response from the server. Defaults to 30.
  .EXAMPLE
  # Requires cliHelper.logger to be imported
  Import-Module cliHelper.logger
  $myLogger = New-Logger -MinimumLevel Debug -Logdirectory "C:\logs\mcp_client"
  try {
    $client = New-McpClient -Command "path/to/server.ps1" -Arguments "-File" -Logger $myLogger
    # ... use $client ...
    $client.Dispose()
  } finally {
    $myLogger.Dispose() # Dispose the logger you created
  }
  .EXAMPLE
  # Using the default internal logger (logs to console)
  # You don't need to dispose the logger in this case, but you also don't control it
  $client = New-McpClient -Command "path/to/server.exe"
  # ... use $client ...
  $client.Dispose() # Still need to dispose the client
  .NOTES
  Relies on the [MCP]::CreateClient static method for implementation.
  Ensure the 'cliHelper.logger' module is available.
  The caller is responsible for disposing the provided or default logger instance.
  .LINK
  MCP
  McpClient
  McpClientOptions
  cliHelper.logger.Logger
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Command,

    [string[]]$Arguments,

    [string]$WorkingDirectory,

    [hashtable]$EnvironmentVariables,

    [McpClientOptions]$Options,

    # Updated Logger parameter: Type is cliHelper.logger.Logger, Not Mandatory
    [Parameter(Mandatory = $false)]
    [cliHelper.logger.Logger]$Logger, # Caller provides instance, responsible for disposal

    [int]$ConnectTimeoutSeconds = 30
  )

  try {
    # Delegate entirely to the static factory method in MCP class
    # It now handles default logger creation if $Logger is $null
    $client = [MCP]::CreateClient(
      $Command,
      $Arguments,
      $WorkingDirectory,
      $EnvironmentVariables,
      $Options, # Pass provided options or null
      $Logger, # Pass provided logger or null
      $ConnectTimeoutSeconds
    )
    # Return the successfully created client
    return $client
  } catch {
    # Catch exceptions from CreateClient and rethrow as terminating errors
    $PSCmdlet.ThrowTerminatingError(
      [System.Management.Automation.ErrorRecord]::new(
        $_.Exception,
        "FailedToCreateMcpClient",
        [System.Management.Automation.ErrorCategory]::InvalidOperation,
        $null # Target object is null or potentially the parameters?
      )
    )
  }
}