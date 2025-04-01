# Helper needs to be added to McpServer class
# hidden [void] McpServer.SetupInternalHandlers([McpServerToolCollection]$toolCollection) {
#     $options = $this.ServerOptions # Access options via property/field
#     $endpoint = $this._endpoint # Access endpoint

#     # Ping
#     $endpoint.SetRequestHandler("ping", [scriptblock] { param($req, $ct) return [Task]::FromResult([McpPingResult]::new()) })

#     # Initialize
#     $endpoint.SetRequestHandler("initialize", [scriptblock] {
#         param($req, $ct) # McpJsonRpcRequest
#         $params = [McpJsonUtilities]::DeserializeParams($req.Params, [McpInitializeRequestParams])
#         $this.SetClientInfo($params) # Update server's knowledge of client
#         # Update EndpointName for logging? Endpoint name is tricky if multiple sessions exist.
#         $this._logger.Log([McpLoggingLevel]::Information, "Initialize request processed from client: $($this.ClientInfo.Name)")
#         # TODO: Capability negotiation
#         $result = [McpInitializeResult]@{
#             ProtocolVersion = $options.ProtocolVersion
#             Instructions    = $options.ServerInstructions
#             ServerInfo      = $options.ServerInfo
#             Capabilities    = $options.Capabilities ?? [McpServerCapabilities]::new()
#         }
#         return [Task]::FromResult([object]$result) # Must return Task<object>
#     })

#     # Completion (Mandatory basic implementation)
#     $compHandler = $options.GetCompletionHandler ?? [scriptblock] {
#       param($ctx, $ct) # McpRequestContext
#       return [Task]::FromResult([McpCompleteResult]@{ Completion = ([McpCompletion]@{ Values = @(); Total = 0; HasMore = $false }) })
#     }
#     $endpoint.SetRequestHandler("completion/complete", [scriptblock] {
#         param($req, $ct)
#         $params = [McpJsonUtilities]::DeserializeParams($req.Params, [McpCompleteRequestParams])
#         $context = [McpRequestContext]::new($this, $params) # Create context
#         # Handlers expect Task<SpecificResult>, need to return Task<object>
#         $handlerTask = . $compHandler $context $ct
#         return $handlerTask.ContinueWith({ param($t) return [object]$t.Result }, $ct) # Convert Task<T> to Task<object>
#     })

#     # Tool Handlers (Merged logic)
#     $toolsCap = $options.Capabilities.Tools
#     $originalListHandler = $options.ListToolsHandler # Get potentially user-set handler
#     $originalCallHandler = $options.CallToolHandler

#     $effectiveListHandler = $originalListHandler
#     $effectiveCallHandler = $originalCallHandler

#      if ($null -ne $toolCollection -and $toolCollection.Count -gt 0) {
#         $this._logger.Log([McpLoggingLevel]::Trace, "Setting up merged tool handlers for ToolCollection.")
#         # Create merged handlers... (Similar logic as before in Start-McpServer)
#         $effectiveListHandler = [scriptblock] { # ... implementation ... }
#         $effectiveCallHandler = [scriptblock] { # ... implementation ... }
#         if ($null -eq $toolsCap) { # Ensure capability exists
#             if ($null -eq $options.Capabilities) {$options.Capabilities = [McpServerCapabilities]::new()}
#             $options.Capabilities.Tools = [McpToolsCapability]::new()
#             $toolsCap = $options.Capabilities.Tools
#         }
#         $toolsCap.ListChanged = $true
#      }

#     # Register effective handlers if they exist
#     if ($null -ne $effectiveListHandler -and $null -ne $effectiveCallHandler) {
#         $endpoint.SetRequestHandler("tools/list", [scriptblock] {
#             param($req, $ct)
#             $params = [McpJsonUtilities]::DeserializeParams($req.Params, [McpListToolsRequestParams])
#             $context = [McpRequestContext]::new($this, $params)
#             $handlerTask = . $effectiveListHandler $context $ct # Expects Task<McpListToolsResult>
#             return $handlerTask.ContinueWith({ param($t) return [object]$t.Result }, $ct)
#         })
#         $endpoint.SetRequestHandler("tools/call", [scriptblock] {
#             param($req, $ct)
#             $params = [McpJsonUtilities]::DeserializeParams($req.Params, [McpCallToolRequestParams])
#             $context = [McpRequestContext]::new($this, $params)
#             # Need to find tool in collection or call original handler
#             $tool = $null
#             $toolRef = New-Object PSObject -Property @{Value = $null} # Ref holder
#             if ($null -ne $toolCollection -and $toolCollection.TryGetTool($params.Name, [ref]$toolRef)) {
#                  $toolInstance = $toolRef.Value
#                  $this._logger.Log([McpLoggingLevel]::Trace, "Invoking tool '$($params.Name)' from collection.")
#                  # Tool InvokeAsync should return Task<McpCallToolResponse>
#                  $handlerTask = $toolInstance.InvokeAsync($context, $ct) # Pass context
#                  return $handlerTask.ContinueWith({ param($t) return [object]$t.Result }, $ct)
#             } elseif ($null -ne $originalCallHandler) {
#                  $this._logger.Log([McpLoggingLevel]::Trace, "Tool '$($params.Name)' not in collection, using original handler.")
#                  $handlerTask = . $originalCallHandler $context $ct
#                  return $handlerTask.ContinueWith({ param($t) return [object]$t.Result }, $ct)
#             } else {
#                  throw [McpServerException]::new("Unknown tool '$($params.Name)'", [McpErrorCodes]::MethodNotFound)
#             }
#         })
#     }

#     # Register other capability handlers based on $options (Prompts, Resources, Logging) similarly...
# }


# --- Add Helper Functions for discoverability ---