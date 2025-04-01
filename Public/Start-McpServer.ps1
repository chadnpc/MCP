function Start-McpServer {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [McpServerOptions]$Options,

    # Option 1: Provide a listening transport factory
    [McpIServerTransport]$ServerTransport,

    # Option 2: Provide a pre-connected transport (e.g., for stdio)
    [McpTransport]$ConnectedTransport,

    # Option 3: Define transport type and params for internal creation
    [McpTransportTypes]$TransportType,
    [int]$Port, # For SSE/HTTP
    # Add other transport-specific params if needed

    [hashtable]$RequestHandlers = @{}, # MethodName -> ScriptBlock
    [hashtable]$NotificationHandlers = @{}, # MethodName -> List<ScriptBlock>
    [McpServerToolCollection]$ToolCollection, # Pre-populated tool collection

    [McpLogger]$Logger,
    [switch]$PassThru # Output the created McpServer object
  )
  process {
    $ErrorActionPreference = 'Stop'
    $logger = $Logger ?? [McpNullLogger]::Instance()
    $logger.Log([McpLoggingLevel]::Information, "Starting MCP Server: $($Options.ServerInfo.Name)")

    $endpoint = $null
    $server = $null
    $transportToUse = $null
    $listenerTransport = $null # If we create a listening transport
    $transportToDispose = $null # The transport instance the server will own

    try {
      # 1. Determine/Create Transport
      if ($null -ne $ConnectedTransport) {
        $transportToUse = $ConnectedTransport
        $logger.Log([McpLoggingLevel]::Information, "Using pre-connected transport.")
      } elseif ($null -ne $ServerTransport) {
        # Server will accept connections using this transport
        $listenerTransport = $ServerTransport
        $logger.Log([McpLoggingLevel]::Information, "Using provided server transport listener.")
        # Endpoint creation waits for Accept
      } else {
        # Create transport internally based on type/params
        $logger.Log([McpLoggingLevel]::Information, "Creating internal transport: $TransportType")
        if ($TransportType -eq [McpTransportTypes]::StdIo) {
          $stdioTransport = [McpStdioServerTransport]::new($Options.ServerInfo.Name, $null, $null, $logger) # Use Console streams
          $transportToUse = $stdioTransport
          $transportToDispose = $stdioTransport # Server owns this
        } elseif ($TransportType -in ([McpTransportTypes]::Sse, [McpTransportTypes]::Http)) {
          if ($Port -le 0) { throw [ArgumentException]::new("Port parameter is required for SSE/HTTP transport.") }
          # Create listener
          $httpListener = [McpHttpListenerSseServerTransport]::new($Options.ServerInfo.Name, $Port, $logger)
          $listenerTransport = $httpListener
          $transportToDispose = $httpListener # Server owns the listener
          $logger.Log([McpLoggingLevel]::Information, "Created HttpListener transport on port $Port.")
        } else {
          throw [ArgumentException]::new("Unsupported or unspecified TransportType for internal creation.")
        }
      }

      # 2. Create Endpoint
      # If listening, endpoint is created AFTER accept. For now, simplify: create endpoint first, accept later if needed.
      # This requires McpEndpoint to handle null transport initially or rethink structure.
      # Let's assume endpoint requires a transport at creation.
      if ($null -eq $transportToUse -and $null -eq $listenerTransport) {
        throw [InvalidOperationException]::new("No transport available to create endpoint.")
      }

      # If using a listener, we need a loop to accept connections.
      # This function *starts* the server, so the accept loop should run in the background.
      if ($null -ne $listenerTransport) {
        $logger.Log([McpLoggingLevel]::Information, "Starting background job to accept connections...")
        $acceptJob = Start-ThreadJob -Name "McpServerAccept_$(Get-Random)" -ScriptBlock {
          param($listener, $opts, $reqHandlers, $notifHandlers, $toolColl, $loggr)
          $ErrorActionPreference = 'Stop'
          $loggr.Log([McpLoggingLevel]::Information, "Accept job started.")
          try {
            while ($true) {
              # Loop indefinitely until listener fails or is disposed
              $loggr.Log([McpLoggingLevel]::Debug, "Accept job waiting for connection...")
              $acceptedTransport = $null
              try {
                # AcceptAsync needs to be properly implemented with cancellation
                $acceptTask = $listener.AcceptAsync([CancellationToken]::None) # No external cancellation here?
                $acceptTask.Wait() # Blocking wait inside job
                $acceptedTransport = $acceptTask.Result
              } catch {
                $loggr.Log([McpLoggingLevel]::Error, "Error accepting connection: $($_.Exception.Message)")
                break # Exit job on accept error
              }

              if ($null -eq $acceptedTransport) {
                $loggr.Log([McpLoggingLevel]::Warning, "AcceptAsync returned null, listener likely stopped.")
                break
              }
              $loggr.Log([McpLoggingLevel]::Information, "Connection accepted.")

              # Create endpoint and server for this specific connection
              $sessionEndpoint = $null
              $sessionServer = $null
              try {
                $sessionEndpointName = "Server Session ($($opts.ServerInfo.Name))"
                $sessionEndpoint = [McpEndpoint]::new($acceptedTransport, $sessionEndpointName, $loggr)

                # Register handlers for this session
                foreach ($m in $reqHandlers.Keys) { $sessionEndpoint.SetRequestHandler($m, $reqHandlers[$m]) }
                foreach ($m in $notifHandlers.Keys) { $notifHandlers[$m].ForEach({ $h = $_; $sessionEndpoint.AddNotificationHandler($m, $h) }) }
                # Attach ToolCollection handler logic if needed (within Initialize handler?)

                # Create Server wrapper (maybe not needed inside loop? Endpoint is enough?)
                # $sessionServer = [McpServer]::new($sessionEndpoint, $opts, $null, $acceptedTransport) # Pass transport to dispose

                $loggr.Log([McpLoggingLevel]::Information, "Starting processing for accepted session.")
                $sessionEndpoint.StartProcessing() # Start its job

                # How to manage lifecycle of these session endpoints? Store them?
                # For now, just let them run. Need a strategy to track/dispose them.

              } catch {
                $loggr.Log([McpLoggingLevel]::Error, "Error setting up accepted session: $($_.Exception.Message)")
                if ($null -ne $sessionServer) { try { $sessionServer.Dispose() } catch { $null } }
                elseif ($null -ne $sessionEndpoint) { try { $sessionEndpoint.Dispose() } catch { $null } }
                elseif ($null -ne $acceptedTransport) { try { $acceptedTransport.Dispose() } catch { $null } }
              }
            } # End while loop
          } catch {
            $loggr.Log([McpLoggingLevel]::Critical, "Fatal error in accept job: $($_.Exception.ToString())")
          } finally {
            $loggr.Log([McpLoggingLevel]::Information, "Accept job finished.")
          }
        } -ArgumentList @(
          $listenerTransport,
          $Options,
          $RequestHandlers,
          $NotificationHandlers,
          $ToolCollection,
          $logger
        )
        # For a listening server, we don't return a single 'McpServer' instance,
        # but rather the listener itself or a handle to manage it.
        # For simplicity, maybe just return the listener transport.
        if ($PassThru) { Write-Output $listenerTransport }
        # Caller is responsible for disposing the listenerTransport to stop the server.

      } else {
        # Direct connection (e.g., Stdio)
        $endpointName = "Server ($($Options.ServerInfo.Name))"
        $endpoint = [McpEndpoint]::new($transportToUse, $endpointName, $logger)
        $server = [McpServer]::new($endpoint, $Options, $null, $transportToDispose) # Pass transport for disposal

        # 3. Register Handlers
        $logger.Log([McpLoggingLevel]::Debug, "Registering server handlers...")
        foreach ($methodName in $RequestHandlers.Keys) {
          $endpoint.SetRequestHandler($methodName, $RequestHandlers[$methodName])
        }
        foreach ($methodName in $NotificationHandlers.Keys) {
          $NotificationHandlers[$methodName].ForEach({ $handler = $_; $endpoint.AddNotificationHandler($methodName, $handler) })
        }
        # Register internal handlers (Initialize, Ping, Completion, Tool logic)
        $server.SetupInternalHandlers($ToolCollection) # Add internal helper method to McpServer

        # 4. Start Processing
        $logger.Log([McpLoggingLevel]::Information, "Starting server endpoint processing...")
        $server.Start() # Starts the endpoint background job

        if ($PassThru) { Write-Output $server }
        # Caller is responsible for disposing the returned $server object.
      }

    } catch {
      $logger.Log([McpLoggingLevel]::Critical, "Failed to start MCP server: $($_.Exception.ToString())")
      # Cleanup
      if ($null -ne $server) { try { $server.Dispose() } catch { $null } }
      elseif ($null -ne $endpoint) { try { $endpoint.Dispose() } catch { $null } }
      elseif ($null -ne $transportToDispose) { try { $transportToDispose.Dispose() } catch { $null } }
      elseif ($null -ne $listenerTransport) { try { $listenerTransport.Dispose() } catch { $null } }
      throw
    }
  }
}