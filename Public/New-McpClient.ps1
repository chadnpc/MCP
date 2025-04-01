function New-McpClient {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [McpServerConfig]$ServerConfig,

    [McpClientOptions]$ClientOptions, # Optional
    [scriptblock]$CreateTransportFunc, # Optional custom transport creation
    [McpLogger]$Logger # Optional logger
  )
  process {
    $ErrorActionPreference = 'Stop'
    $logger = $Logger ?? [McpNullLogger]::Instance()
    $logger.Log([McpLoggingLevel]::Information, "Creating MCP Client for server: $($ServerConfig.Name)")

    $options = $ClientOptions ?? [McpClientFactory]::CreateDefaultClientOptions() # Use helper for defaults
    $transport = $null
    $endpoint = $null
    $client = $null

    try {
      # 1. Create Transport
      if ($null -ne $CreateTransportFunc) {
        $transport = . $CreateTransportFunc $ServerConfig $logger
        if ($null -eq $transport -or $transport -isnot [McpTransport]) {
          throw [InvalidOperationException]::new("CreateTransportFunc did not return a valid McpTransport.")
        }
      } else {
        # Default transport creation logic based on $ServerConfig.TransportType
        $transportTypeStr = try { [string]$ServerConfig.TransportType } catch { '' }
        if ($transportTypeStr -eq [string][McpTransportTypes]::StdIo) {
          # Extract options from ServerConfig.TransportOptions
          $command = $ServerConfig.TransportOptions.command ?? $ServerConfig.Location
          if ([string]::IsNullOrWhiteSpace($command)) { throw [ArgumentException]::new("Command/Location is required for stdio.") }
          # ... extract args, wd, env ...
          # Windows cmd /c wrapping if needed
          if (($env:OS -eq 'Windows_NT') -and $command -notmatch 'cmd(\.exe)?$' ) {
            $arguments = "/c `"$command`" $($ServerConfig.TransportOptions.arguments)".TrimEnd()
            $command = "cmd.exe"
          } else { $arguments = $ServerConfig.TransportOptions.arguments }

          $transport = [McpStdioTransport]::new($command, $arguments, $ServerConfig.TransportOptions.workingDirectory, $null, $logger) # Pass env vars correctly
        } elseif ($transportTypeStr -in ([string][McpTransportTypes]::Sse, 'http')) {
          # Basic SSE/HTTP client placeholder - Needs implementation
          throw [NotImplementedException]::new("SSE/HTTP Client transport not fully implemented in this version.")
          # $sseOptions = [...]
          # $httpClient = [...]
          # $transport = [McpSseClientTransport]::new($sseOptions, $ServerConfig, $httpClient, $logger, $true)
        } else {
          throw [ArgumentException]::new("Unsupported transport type: '$($ServerConfig.TransportType)'")
        }
      }

      # 2. Create Endpoint
      $endpointName = "Client ($($ServerConfig.Id): $($ServerConfig.Name))"
      $endpoint = [McpEndpoint]::new($transport, $endpointName, $logger)

      # 3. Register Client-Side Handlers from Options (if provided)
      if ($options.Capabilities.Sampling.SamplingHandler) {
        $endpoint.SetRequestHandler("sampling/createMessage", $options.Capabilities.Sampling.SamplingHandler)
      }
      if ($options.Capabilities.Roots.RootsHandler) {
        $endpoint.SetRequestHandler("roots/list", $options.Capabilities.Roots.RootsHandler)
      }
      # Add other potential client-side handlers

      # 4. Create Client Wrapper
      $client = [McpClient]::new($endpoint, $options, $ServerConfig)

      # 5. Connect Transport and Start Processing
      $logger.Log([McpLoggingLevel]::Information, "Connecting transport...")
      $transport.Connect() # Synchronous connect for simplicity here
      $logger.Log([McpLoggingLevel]::Information, "Starting endpoint processing...")
      $endpoint.StartProcessing() # Start background job

      # 6. Perform Initialization Handshake
      $logger.Log([McpLoggingLevel]::Information, "Performing initialization handshake...")
      $initTimeout = $options.InitializationTimeout
      $initCts = [CancellationTokenSource]::new($initTimeout)
      $initRequest = [McpJsonRpcRequest]@{
        Method = "initialize"
        Params = [McpInitializeRequestParams]@{
          ProtocolVersion = $options.ProtocolVersion
          Capabilities    = $options.Capabilities # Can be null
          ClientInfo      = $options.ClientInfo
        }
      }

      # Send request and wait for response using the Job pattern
      $initJob = $endpoint.SendRequestAsync($initRequest, $initCts.Token)
      $initJob | Wait-Job # Blocking wait
      if ($initJob.State -eq 'Failed') {
        $reason = try { $initJob.Error[0].Exception.ToString() } catch { "Unknown" }
        throw [McpClientException]::new("Initialization failed: $reason")
      }
      if ($initJob.State -eq 'Stopped') { throw [TimeoutException]::new("Initialization timed out after $initTimeout.") }

      $initResultObj = $initJob | Receive-Job
      $initJob | Remove-Job

      # Deserialize and process result
      $initResult = [McpJsonUtilities]::DeserializeParams($initResultObj, [McpInitializeResult])
      if ($null -eq $initResult) { throw [McpClientException]::new("Initialize returned invalid result.") }

      # Validate version
      if ($initResult.ProtocolVersion -ne $options.ProtocolVersion) {
        throw [McpClientException]::new("Protocol version mismatch. Client: $($options.ProtocolVersion), Server: $($initResult.ProtocolVersion)")
      }

      # Update client with server info
      $client.SetServerInfo($initResult)
      $logger.Log([McpLoggingLevel]::Information, "Initialization successful with Server: $($client.ServerInfo.Name) v$($client.ServerInfo.Version)")

      # Send Initialized Notification
      $logger.Log([McpLoggingLevel]::Information, "Sending 'initialized' notification...")
      $initNotif = [McpJsonRpcNotification]@{ Method = "notifications/initialized" }
      $endpoint.SendNotificationAsync($initNotif, [CancellationToken]::None)

      # Return the connected client
      Write-Output $client
    } catch {
      $logger.Log([McpLoggingLevel]::Critical, "Failed to create MCP client: $($_.Exception.ToString())")
      # Cleanup partially created resources
      if ($null -ne $client) { try { $client.Dispose() } catch { $null } }
      elseif ($null -ne $endpoint) { try { $endpoint.Dispose() } catch { $null } }
      elseif ($null -ne $transport) { try { $transport.Dispose() } catch { $null } }
      throw # Rethrow the exception
    } finally {
      if ($null -ne $initCts) { try { $initCts.Dispose() } catch { $null } }
    }
  }
}