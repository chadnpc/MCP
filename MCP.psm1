#!/usr/bin/env pwsh

#region    Enums
# .EXAMPLE
# [ErrorCodes]::PARSE_ERROR.value__
# -32700
enum ErrorCodes {
  PARSE_ERROR = - 32700
  INVALID_REQUEST = - 32600
  METHOD_NOT_FOUND = - 32601
  INVALID_PARAMS = - 32602
  INTERNAL_ERROR = - 32603
}

enum Role {
  User
  Assistant
}

# .EXAMPLE
# [LoggingLevel]::Alert
# .EXAMPLE
#  'Fatal' -in [enum]::GetNames[LoggingLevel]()
# False
enum LoggingLevel {
  Debug
  Info
  Notice
  Warning
  Error
  Critical
  Alert
  Emergency
}

enum StopReason {
  EndTurn
  StopSequence
  MaxTokens
}

enum ContextInclusionStrategy {
  None
  This_Server
  All_Servers
}

#endregion Enums

#region    Classes

#region    Exceptions
class McpError : System.Exception {
  [JSONRPCError]$JsonRpcError

  McpError ([string]$message) : base ($message) {
    $this.Message = $message
  }
  McpError ([JSONRPCError]$jsonRpcError) : base ($jsonRpcError.message) {
    $this.JsonRpcError = $jsonRpcError
  }
}
#endregion Exceptions


class McpObject {
  # Provides static props, methods and basic Schema to all objects used by main class ie: MCP
  static [string]$LATEST_PROTOCOL_VERSION = "2024-11-05"
  static [string]$JSONRPC_VERSION = "2.0"
  [string] ToJson() {
    return $this | ConvertTo-Json -Depth 10 -Compress
  }
  static [object] FromJson([string]$json) {
    return $json | ConvertFrom-Json -Depth 10
  }
}

class JSONRPCMessage : McpObject {
  [string]$jsonrpc = [McpObject]::JSONRPC_VERSION
  [string]$method
  [guid]$Id

  JSONRPCMessage() {
    throw [InvalidOperationException]::new("marker class and cannot be instantiated directly")
  }

  JSONRPCMessage([string]$method, [guid]$id) {
    if (-not $method) {
      throw [ArgumentException]::new("Method name cannot be empty")
    }

    $this.method = $method
    $this.id = $id
  }

  [hashtable] ToHashtable() {
    return @{
      jsonrpc = $this.jsonrpc
      method  = $this.method
      id      = $this.id
    }
  }

  [void] Validate() {
    if ($this.jsonrpc -ne [McpObject]::JSONRPC_VERSION) {
      throw [McpError]::new(
        "Unsupported JSON-RPC version. Expected $([McpObject]::JSONRPC_VERSION)",
        [ErrorCodes]::INVALID_REQUEST
      )
    }
  }

  [string] ToString() {
    return $this | ConvertTo-Json -Compress
  }
}

class JSONRPCRequest : JSONRPCMessage {
  [string]$jsonrpc
  [string]$method
  [Object]$id # Can be String or Number
  [Object]$params

  JSONRPCRequest ([string]$jsonrpc, [string]$method, [Object]$id, [Object]$params) {
    $this.jsonrpc = $jsonrpc
    $this.method = $method
    $this.id = $id
    $this.params = $params
  }
}
class JSONRPCNotification : JSONRPCMessage {
  [string]$jsonrpc
  [string]$method
  [hashtable]$params

  JSONRPCNotification ([string]$jsonrpc, [string]$method, [hashtable]$params) {
    $this.jsonrpc = $jsonrpc
    $this.method = $method
    $this.params = $params
  }
}

class JSONRPCResponse : JSONRPCMessage {
  [string]$jsonrpc
  [Object]$id # Can be String or Number, can be null for notifications responses
  [Object]$result
  [JSONRPCError]$error

  JSONRPCResponse ([string]$jsonrpc, [Object]$id, [Object]$result, [JSONRPCError]$jrpcError) {
    $this.jsonrpc = $jsonrpc
    $this.id = $id
    $this.result = $result
    $this.error = $jrpcError
  }
}
class JSONRPCError {
  [int]$code
  [string]$message
  [Object]$data

  JSONRPCError ([int]$code, [string]$message, [Object]$data) {
    $this.code = $code
    $this.message = $message
    $this.data = $data
  }
}

class Implementation : McpObject {
  [string]$name
  [string]$version

  Implementation ([string]$name, [string]$version) {
    $this.name = $name
    $this.version = $version
  }
}

class ClientCapabilities : McpObject {
  [hashtable]$experimental
  [RootCapabilities]$roots
  [Sampling]$sampling

  ClientCapabilities () {}
  ClientCapabilities ([hashtable]$experimental, [RootCapabilities]$roots, [Sampling]$sampling) {
    [void][ClientCapabilities]::From($experimental, $roots, $sampling, [ref]$this)
  }
  static [ClientCapabilities] create () {
    return [ClientCapabilities]::From($null, $null, $null, [ref][ClientCapabilities]::new())
  }
  static hidden [ClientCapabilities] From([hashtable]$experimental, [RootCapabilities]$roots, [Sampling]$sampling, [ref]$r) {
    $r.Value.experimental = $experimental
    $r.Value.roots = $roots
    $r.Value.sampling = $sampling
    return $r.Value
  }
}

class RootCapabilities : ClientCapabilities {
  [bool]$listChanged

  RootCapabilities ([bool]$listChanged) {
    $this.listChanged = $listChanged
  }
}

class Sampling : ClientCapabilities {
  Sampling () {
    # No properties in Sampling class for now, default constructor is enough
  }
}

class ServerCapabilities : McpObject {
  [hashtable]$experimental
  [LoggingCapabilities]$logging
  [PromptCapabilities]$prompts
  [ResourceCapabilities]$resources
  [ToolCapabilities]$tools

  ServerCapabilities () {}
  ServerCapabilities ([hashtable]$experimental, [LoggingCapabilities]$logging, [PromptCapabilities]$prompts, [ResourceCapabilities]$resources, [ToolCapabilities]$tools) {
    [void][ServerCapabilities]::From($experimental, $logging, $prompts, $resources, $tools, [ref]$this)
  }
  static [ServerCapabilities] Create() {
    return [ServerCapabilities]::From($null, $null, $null, $null, $null, [ref][ServerCapabilities]::new())
  }
  static [ServerCapabilities] Create ([hashtable]$experimental, [LoggingCapabilities]$logging, [PromptCapabilities]$prompts, [ResourceCapabilities]$resources, [ToolCapabilities]$tools) {
    return [ServerCapabilities]::From($experimental, $logging, $prompts, $resources, $tools, [ref][ServerCapabilities]::new())
  }
  static hidden [ServerCapabilities] From([hashtable]$experimental, [LoggingCapabilities]$logging, [PromptCapabilities]$prompts, [ResourceCapabilities]$resources, [ToolCapabilities]$tools, [ref]$r) {
    $r.value.experimental = $experimental
    $r.value.logging = $logging
    $r.value.prompts = $prompts
    $r.value.resources = $resources
    $r.value.tools = $tools
    return $r.value
  }
}

class LoggingCapabilities : ServerCapabilities {
  LoggingCapabilities () {}
}

class PromptCapabilities : ServerCapabilities {
  [bool]$listChanged

  PromptCapabilities ([bool]$listChanged) {
    $this.listChanged = $listChanged
  }
}

class ResourceCapabilities : ServerCapabilities {
  [bool]$subscribe
  [bool]$listChanged
  ResourceCapabilities ([bool]$subscribe, [bool]$listChanged) {
    $this.subscribe = $subscribe
    $this.listChanged = $listChanged
  }
}

class ToolCapabilities : ServerCapabilities {
  [bool]$listChanged
  ToolCapabilities ([bool]$listChanged) {
    $this.listChanged = $listChanged
  }
}
class InitializeRequest : McpObject {
  [string]$protocolVersion
  [ClientCapabilities]$capabilities
  [Implementation]$clientInfo

  InitializeRequest ([string]$protocolVersion, [ClientCapabilities]$capabilities, [Implementation]$clientInfo) {
    $this.protocolVersion = $protocolVersion
    $this.capabilities = $capabilities
    $this.clientInfo = $clientInfo
  }
}

class InitializeResult : McpObject {
  [string]$protocolVersion
  [ServerCapabilities]$capabilities
  [Implementation]$serverInfo
  [string]$instructions

  InitializeResult ([string]$protocolVersion, [ServerCapabilities]$capabilities, [Implementation]$serverInfo, [string]$instructions) {
    $this.protocolVersion = $protocolVersion
    $this.capabilities = $capabilities
    $this.serverInfo = $serverInfo
    $this.instructions = $instructions
  }
}

class Root : McpObject {
  [string]$uri
  [string]$name

  Root ([string]$uri, [string]$name) {
    $this.uri = $uri
    $this.name = $name
  }
}

class ListRootsResult : McpObject {
  [System.Collections.Generic.List[Root]]$roots

  ListRootsResult ([System.Collections.Generic.List[Root]]$roots) {
    $this.roots = $roots
  }
}

class CallToolRequest : McpObject {
  [string]$name
  [hashtable]$arguments

  CallToolRequest ([string]$name, [hashtable]$arguments) {
    $this.name = $name
    $this.arguments = $arguments
  }
}

class CallToolResult : McpObject {
  [System.Collections.Generic.List[Content]]$content
  [bool]$isError

  CallToolResult ([System.Collections.Generic.List[Content]]$content, [bool]$isError) {
    $this.content = $content
    $this.isError = $isError
  }
}

class ListToolsResult : McpObject {
  [System.Collections.Generic.List[Tool]]$tools
  [string]$nextCursor

  ListToolsResult ([System.Collections.Generic.List[Tool]]$tools, [string]$nextCursor) {
    $this.tools = $tools
    $this.nextCursor = $nextCursor
  }
}

class Tool : McpObject {
  [string]$name
  [string]$description
  [JsonSchema]$inputSchema

  Tool ([string]$name, [string]$description, [JsonSchema]$inputSchema) {
    $this.name = $name
    $this.description = $description
    $this.inputSchema = $inputSchema
  }

  # Constructor accepting schema as string (like in Java example)
  Tool ([string]$name, [string]$description, [string]$schema) {
    $this.name = $name
    $this.description = $description
    $this.inputSchema = [JsonSchema]::Parse($schema)
  }
}

class JsonSchema : McpObject {
  [string]$type
  [hashtable]$properties
  [System.Collections.Generic.List[string]]$required
  [bool]$additionalProperties

  JsonSchema ([string]$type, [hashtable]$properties, [System.Collections.Generic.List[string]]$required, [bool]$additionalProperties) {
    $this.type = $type
    $this.properties = $properties
    $this.required = $required
    $this.additionalProperties = $additionalProperties
  }

  static [JsonSchema] Parse ([string]$schemaJson) {
    try {
      $schemaObject = ConvertFrom-Json -InputObject $schemaJson
      return [JsonSchema]::new(
        $schemaObject.type,
        $schemaObject.properties,
        $schemaObject.required,
        $schemaObject.additionalProperties
      )
    } catch {
      throw [System.ArgumentException]::new("Invalid schema JSON", "schemaJson")
    }
  }
}

class ListResourcesResult : McpObject {
  [System.Collections.Generic.List[Resource]]$resources
  [string]$nextCursor

  ListResourcesResult ([System.Collections.Generic.List[Resource]]$resources, [string]$nextCursor) {
    $this.resources = $resources
    $this.nextCursor = $nextCursor
  }
}

class Resource : McpObject {
  [string]$uri
  [string]$name
  [string]$description
  [string]$mimeType
  [Annotations]$annotations

  Resource ([string]$uri, [string]$name, [string]$description, [string]$mimeType, [Annotations]$annotations) {
    $this.uri = $uri
    $this.name = $name
    $this.description = $description
    $this.mimeType = $mimeType
    $this.annotations = $annotations
  }
}

class Annotations : McpObject {
  [System.Collections.Generic.List[Role]]$audience
  [double]$priority

  Annotations ([System.Collections.Generic.List[Role]]$audience, [double]$priority) {
    $this.audience = $audience
    $this.priority = $priority
  }
}

class ReadResourceRequest : McpObject {
  [string]$uri

  ReadResourceRequest ([string]$uri) {
    $this.uri = $uri
  }
}

class ReadResourceResult : McpObject {
  [System.Collections.Generic.List[ResourceContents]]$contents

  ReadResourceResult ([System.Collections.Generic.List[ResourceContents]]$contents) {
    $this.contents = $contents
  }
}

class ResourceContents : McpObject {
  # Marker Class
}

class TextResourceContents : ResourceContents {
  [string]$uri
  [string]$mimeType
  [string]$text

  TextResourceContents ([string]$uri, [string]$mimeType, [string]$text) {
    $this.uri = $uri
    $this.mimeType = $mimeType
    $this.text = $text
  }
}

class ListResourceTemplatesResult {
  [System.Collections.Generic.List[ResourceTemplate]]$resourceTemplates
  [string]$nextCursor

  ListResourceTemplatesResult ([System.Collections.Generic.List[ResourceTemplate]]$resourceTemplates, [string]$nextCursor) {
    $this.resourceTemplates = $resourceTemplates
    $this.nextCursor = $nextCursor
  }
}

class ResourceTemplate : McpObject {
  [string]$uriTemplate
  [string]$name
  [string]$description
  [string]$mimeType
  [Annotations]$annotations

  ResourceTemplate ([string]$uriTemplate, [string]$name, [string]$description, [string]$mimeType, [Annotations]$annotations) {
    $this.uriTemplate = $uriTemplate
    $this.name = $name
    $this.description = $description
    $this.mimeType = $mimeType
    $this.annotations = $annotations
  }
}

class SubscribeRequest {
  [string]$uri
  SubscribeRequest ([string]$uri) {
    $this.uri = $uri
  }
}

class UnsubscribeRequest {
  [string]$uri
  UnsubscribeRequest ([string]$uri) {
    $this.uri = $uri
  }
}

class ListPromptsResult {
  [System.Collections.Generic.List[Prompt]]$prompts
  [string]$nextCursor

  ListPromptsResult ([System.Collections.Generic.List[Prompt]]$prompts, [string]$nextCursor) {
    $this.prompts = $prompts
    $this.nextCursor = $nextCursor
  }
}

class Prompt : McpObject {
  [string]$name
  [string]$description
  [System.Collections.Generic.List[PromptArgument]]$arguments

  Prompt ([string]$name, [string]$description, [System.Collections.Generic.List[PromptArgument]]$arguments) {
    $this.name = $name
    $this.description = $description
    $this.arguments = $arguments
  }
}

class PromptArgument : McpObject {
  [string]$name
  [string]$description
  [bool]$required

  PromptArgument ([string]$name, [string]$description, [bool]$required) {
    $this.name = $name
    $this.description = $description
    $this.required = $required
  }
}

class GetPromptRequest : McpObject {
  [string]$name
  [hashtable]$arguments

  GetPromptRequest ([string]$name, [hashtable]$arguments) {
    $this.name = $name
    $this.arguments = $arguments
  }
}

class GetPromptResult : McpObject {
  [string]$description
  [System.Collections.Generic.List[PromptMessage]]$messages

  GetPromptResult ([string]$description, [System.Collections.Generic.List[PromptMessage]]$messages) {
    $this.description = $description
    $this.messages = $messages
  }
}

class PromptMessage : McpObject {
  [Role]$role
  [Content]$content

  PromptMessage ([Role]$role, [Content]$content) {
    $this.role = $role
    $this.content = $content
  }
}

class Content : McpObject {
  #Marker Class
}

class TextContent : Content {
  [System.Collections.Generic.List[Role]]$audience
  [double]$priority
  [string]$text

  TextContent ([string]$text) {
    #Simplified constructor for text content
    $this.text = $text
  }

  TextContent ([System.Collections.Generic.List[Role]]$audience, [double]$priority, [string]$text) {
    $this.audience = $audience
    $this.priority = $priority
    $this.text = $text
  }
}

<#
.EXAMPLE
# Create transport and session
$transport = [StdioClientTransport]::new($serverParams)
$session = [McpSession]::new($transport)

# Register notification handler
$session.RegisterNotificationHandler({
    param($notification)
    Write-Host "Received notification: $($notification.method)"
})

# Send request
$request = [JSONRPCRequest]::new("2.0", "listTools", "123", $null)
$response = $session.SendRequest($request)
Write-Host "Response received: $($response | ConvertTo-Json)"

# Send notification
$notification = [JSONRPCNotification]::new("2.0", "logEvent", @{message = "Client connected"})
$session.SendNotification($notification)

# Close gracefully
$session.CloseGracefully()
#>
class McpSession : McpObject {
  [ClientMcpTransport]$Transport
  [System.Collections.Concurrent.ConcurrentDictionary[string, [System.Threading.Tasks.TaskCompletionSource[Object]]]]$PendingRequests
  [System.Collections.Generic.List[scriptblock]]$NotificationHandlers
  [System.Threading.CancellationTokenSource]$CancellationTokenSource
  [bool]$IsConnected
  [DateTime]$LastActivity
  [TimeSpan]$RequestTimeout = [TimeSpan]::FromSeconds(30)
  [System.Collections.Concurrent.ConcurrentQueue[JSONRPCMessage]]$MessageQueue
  [System.Threading.ManualResetEventSlim]$ConnectionLock = [System.Threading.ManualResetEventSlim]::new($true)

  McpSession([ClientMcpTransport]$transport) {
    if (!$transport) {
      throw [ArgumentNullException]::new("transport")
    }

    $this.Transport = $transport
    $this.PendingRequests = [System.Collections.Concurrent.ConcurrentDictionary[string, [System.Threading.Tasks.TaskCompletionSource[Object]]]]::new()
    $this.NotificationHandlers = [System.Collections.Generic.List[scriptblock]]::new()
    $this.MessageQueue = [System.Collections.Concurrent.ConcurrentQueue[JSONRPCMessage]]::new()
    $this.CancellationTokenSource = [System.Threading.CancellationTokenSource]::new()

    $this.InitializeTransportHandlers()
  }

  hidden [void] InitializeTransportHandlers() {
    # Register transport message handler
    $this.Transport.Connect({
        param($message)
        $this.MessageQueue.Enqueue($message)
        $this.ProcessMessageQueue()
      })

    # Start background processing
    $this.StartMessageProcessor()
  }

  hidden [void] StartMessageProcessor() {
    Start-Job -Name "McpSessionProcessor" -ScriptBlock {
      param([ref]$sessionRef)

      $session = $sessionRef.Value
      while (-not $session.CancellationTokenSource.IsCancellationRequested) {
        try {
          if ($session.MessageQueue.TryDequeue([ref]$message)) {
            $session.ProcessIncomingMessage($message)
          }
          [System.Threading.Thread]::Sleep(100)
        } catch {
          Write-Error "Message processing error: $_"
        }
      }
    } -ArgumentList ([ref]$this) | Out-Null
  }

  [void] Close() {
    $this.CancellationTokenSource.Cancel()
    $this.Transport.Close()
    $this.IsConnected = $false
    $this.ConnectionLock.Reset()
  }

  [void] CloseGracefully() {
    $this.CancellationTokenSource.CancelAfter(5000)
    $this.Transport.CloseGracefully()
    $this.IsConnected = $false
    $this.ConnectionLock.Set()
  }

  [Object] SendRequest([JSONRPCRequest]$request) {
    $this.ValidateConnection()

    $tcs = [System.Threading.Tasks.TaskCompletionSource[Object]]::new()
    $this.PendingRequests[$request.id] = $tcs

    try {
      $this.Transport.SendMessage($request)
      $this.LastActivity = [DateTime]::Now

      return $tcs.Task.Wait($this.RequestTimeout, $this.CancellationTokenSource.Token)
    } catch [System.OperationCanceledException] {
      $this.PendingRequests.TryRemove($request.id, [ref]$null)
      throw [McpError]::new("Request timed out", [ErrorCodes]::INVALID_REQUEST)
    } finally {
      $this.PendingRequests.TryRemove($request.id, [ref]$null)
    }
  }

  [void] SendNotification([JSONRPCNotification]$notification) {
    $this.ValidateConnection()
    $this.Transport.SendMessage($notification)
    $this.LastActivity = [DateTime]::Now
  }

  hidden [void] ProcessIncomingMessage([JSONRPCMessage]$message) {
    try {
      switch ($message) {
        { $_ -is [JSONRPCResponse] } {
          $this.HandleResponse($_)
        }
        { $_ -is [JSONRPCNotification] } {
          $this.HandleNotification($_)
        }
        default {
          Write-Warning "Received unknown message type: $($_.GetType().Name)"
        }
      }
    } catch {
      Write-Error "Error processing message: $_"
    }
  }

  # hidden [void] HandleResponse([JSONRPCResponse]$response) {
  #   if ($this.PendingRequests.TryGetValue($response.id, [ref]$tcs)) {
  #     if ($response.error) {
  #       $tcs.SetException([McpError]::new($response.error))
  #     } else {
  #       $tcs.SetResult($response.result)
  #     }
  #   }
  # }

  hidden [void] HandleNotification([JSONRPCNotification]$notification) {
    foreach ($handler in $this.NotificationHandlers) {
      try {
        & $handler $notification
      } catch {
        Write-Error "Notification handler error: $_"
      }
    }
  }

  [void] RegisterNotificationHandler([scriptblock]$handler) {
    $this.NotificationHandlers.Add($handler)
  }

  hidden [void] ValidateConnection() {
    if (-not $this.IsConnected) {
      throw [McpError]::new("Session is not connected", [ErrorCodes]::INVALID_REQUEST)
    }

    if ($this.ConnectionLock.Wait(5000)) {
      $this.ConnectionLock.Reset()
      try {
        if (-not $this.Transport.IsConnected) {
          $this.Transport.Connect()
          $this.IsConnected = $true
        }
      } finally {
        $this.ConnectionLock.Set()
      }
    } else {
      throw [McpError]::new("Connection timeout", [ErrorCodes]::INTERNAL_ERROR)
    }
  }

  [TimeSpan] GetIdleTime() {
    return [DateTime]::Now - $this.LastActivity
  }

  [void] ResetTimeout([TimeSpan]$newTimeout) {
    $this.RequestTimeout = $newTimeout
    $this.CancellationTokenSource.CancelAfter($newTimeout)
  }
}

class ClientMcpTransport {
  [void] Connect ([scriptblock]$handler) {
    throw [NotImplementedException]::new("Connect method must be implemented by derived classes")
  }

  [void] SendMessage ([JSONRPCMessage]$message) {
    throw [NotImplementedException]::new("SendMessage method must be implemented by derived classes")
  }

  [void] CloseGracefully () {
    throw [NotImplementedException]::new("CloseGracefully method must be implemented by derived classes")
  }

  [void] Close () {
    $this.CloseGracefully() #Default close implementation can call Gracefully and subscribe
  }

  [void] UnmarshalFrom ([Object]$data, [type]$typeRef) {
    throw [NotImplementedException]::new("UnmarshalFrom method must be implemented by derived classes")
  }
}

class LoggingMessageNotification : McpObject {
  [LoggingLevel]$level
  [string]$logger
  [string]$data
  LoggingMessageNotification() {
    $this.level = [LoggingLevel]::Info # Default Level
    $this.logger = "server" # Default Logger
  }
  LoggingMessageNotification ([LoggingLevel]$level) {
    $this.level = $level
  }
  LoggingMessageNotification ([LoggingLevel]$level, [string]$logger, [string]$data) {
    $this.level = $level
    $this.logger = $logger
    $this.data = $data
  }
  static [LoggingMessageNotification] Create () {
    return [LoggingMessageNotification]::new()
  }
}

# HTTP SSE Transport implementation
class HttpClientTransport : ClientMcpTransport {
  [string]$BaseUrl
  [System.Net.Http.HttpClient]$Client
  [System.Threading.CancellationTokenSource]$Cts
  [ObjectMapper]$Mapper

  HttpClientTransport([string]$baseUrl) {
    $this.BaseUrl = $baseUrl
    $this.Client = [System.Net.Http.HttpClient]::new()
    $this.Cts = [System.Threading.CancellationTokenSource]::new()
    $this.Mapper = [ObjectMapper]::new()
  }

  [void] Connect([scriptblock]$handler) {
    $sseUrl = "$($this.BaseUrl)/events"
    Start-Job -Name "MCPHttpSSE" -ScriptBlock {
      param($url, $client, $mapper, $handler, $cts)
      try {
        $response = $client.GetAsync($url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cts.Token).Result
        $stream = $response.Content.ReadAsStreamAsync().Result
        $reader = [System.IO.StreamReader]::new($stream)

        while (-not $cts.Token.IsCancellationRequested) {
          $line = $reader.ReadLine()
          if ($null -eq $line) { continue }

          if ($line.StartsWith("data: ")) {
            $json = $line.Substring(6).Trim()
            $message = $mapper.Deserialize($json, [JSONRPCMessage])
            & $handler $message
          }
        }
      } catch {
        Write-Error "SSE Error: $_"
      }
    } -ArgumentList $sseUrl, $this.Client, $this.Mapper, $handler, $this.Cts | Out-Null
  }

  [void] SendMessage([JSONRPCMessage]$message) {
    $json = $this.Mapper.Serialize($message)
    $content = [System.Net.Http.StringContent]::new($json, [System.Text.Encoding]::UTF8, "application/json")
    $this.Client.PostAsync("$($this.BaseUrl)/rpc", $content).Wait()
  }

  [void] CloseGracefully() {
    $this.Cts.Cancel()
    $this.Client.Dispose()
  }
}

class McpClientFeature {
}

class Async : McpClientFeature {
  [Implementation]$ClientInfo
  [ClientCapabilities]$ClientCapabilities
  [hashtable]$Roots
  [System.Collections.Generic.List[scriptblock]]$ToolsChangeConsumers
  [System.Collections.Generic.List[scriptblock]]$ResourcesChangeConsumers
  [System.Collections.Generic.List[scriptblock]]$PromptsChangeConsumers
  [System.Collections.Generic.List[scriptblock]]$LoggingConsumers
  [scriptblock]$SamplingHandler

  Async ([Implementation]$clientInfo, [ClientCapabilities]$clientCapabilities, [hashtable]$roots, [System.Collections.Generic.List[scriptblock]]$toolsChangeConsumers, [System.Collections.Generic.List[scriptblock]]$resourcesChangeConsumers, [System.Collections.Generic.List[scriptblock]]$promptsChangeConsumers, [System.Collections.Generic.List[scriptblock]]$loggingConsumers, [scriptblock]$samplingHandler) {
    if ($null -eq $clientInfo) {
      throw [System.ArgumentNullException]::new("clientInfo", "Client info must not be null")
    }
    $this.ClientInfo = $clientInfo
    if ($null -ne $clientCapabilities) {
      $this.ClientCapabilities = $clientCapabilities
    } else {
      $this.ClientCapabilities = [ClientCapabilities]::new() # Provide default if null
    }

    if ($null -ne $roots) {
      $this.Roots = $roots
    } else {
      $this.Roots = @{} # Default to empty hashtable if null
    }

    $this.ToolsChangeConsumers = if ($null -ne $toolsChangeConsumers) { $toolsChangeConsumers } else { [System.Collections.Generic.List[scriptblock]]::new() }
    $this.ResourcesChangeConsumers = if ($null -ne $resourcesChangeConsumers) { $resourcesChangeConsumers } else { [System.Collections.Generic.List[scriptblock]]::new() }
    $this.PromptsChangeConsumers = if ($null -ne $promptsChangeConsumers) { $promptsChangeConsumers } else { [System.Collections.Generic.List[scriptblock]]::new() }
    $this.LoggingConsumers = if ($null -ne $loggingConsumers) { $loggingConsumers } else { [System.Collections.Generic.List[scriptblock]]::new() }
    $this.SamplingHandler = $samplingHandler
  }

  static [Async] FromSync ([Sync]$syncSpec) {
    $toolsChangeConsumersAsync = [System.Collections.Generic.List[scriptblock]]::new()
    foreach ($consumer in $syncSpec.ToolsChangeConsumers) {
      $toolsChangeConsumersAsync.Add({ param($t)  & $consumer @PSBoundParameters })
    }
    $resourcesChangeConsumersAsync = [System.Collections.Generic.List[scriptblock]]::new()
    foreach ($consumer in $syncSpec.ResourcesChangeConsumers) {
      $resourcesChangeConsumersAsync.Add({ param($r) & $consumer @PSBoundParameters })
    }
    $promptsChangeConsumersAsync = [System.Collections.Generic.List[scriptblock]]::new()
    foreach ($consumer in $syncSpec.PromptsChangeConsumers) {
      $promptsChangeConsumersAsync.Add({ param($p) & $consumer @PSBoundParameters })
    }
    $loggingConsumersAsync = [System.Collections.Generic.List[scriptblock]]::new()
    foreach ($consumer in $syncSpec.LoggingConsumers) {
      $loggingConsumersAsync.Add({ param($l) & $consumer @PSBoundParameters })
    }

    $samplingHandlerAsync = if ($syncSpec.SamplingHandler) {
      { param($r) & $syncSpec.SamplingHandler @PSBoundParameters }
    } else {
      $null
    }

    return [Async]::new(
      $syncSpec.ClientInfo,
      $syncSpec.ClientCapabilities,
      $syncSpec.Roots,
      $toolsChangeConsumersAsync,
      $resourcesChangeConsumersAsync,
      $promptsChangeConsumersAsync,
      $loggingConsumersAsync,
      $samplingHandlerAsync
    )
  }
}

class Sync : McpClientFeature {
  [hashtable]$Roots
  [Implementation]$ClientInfo
  [ClientCapabilities]$ClientCapabilities
  [System.Collections.Generic.List[scriptblock]]$ToolsChangeConsumers
  [System.Collections.Generic.List[scriptblock]]$ResourcesChangeConsumers
  [System.Collections.Generic.List[scriptblock]]$PromptsChangeConsumers
  [System.Collections.Generic.List[scriptblock]]$LoggingConsumers
  [scriptblock]$SamplingHandler

  Sync ([Implementation]$clientInfo, [ClientCapabilities]$clientCapabilities, [hashtable]$roots, [System.Collections.Generic.List[scriptblock]]$toolsChangeConsumers, [System.Collections.Generic.List[scriptblock]]$resourcesChangeConsumers, [System.Collections.Generic.List[scriptblock]]$promptsChangeConsumers, [System.Collections.Generic.List[scriptblock]]$loggingConsumers, [scriptblock]$samplingHandler) {
    if ($null -eq $clientInfo) {
      throw [System.ArgumentNullException]::new("clientInfo", "Client info must not be null")
    }
    $this.ClientInfo = $clientInfo
    if ($null -ne $clientCapabilities) {
      $this.ClientCapabilities = $clientCapabilities
    } else {
      $this.ClientCapabilities = [ClientCapabilities]::new() # Provide default if null
    }
    if ($null -ne $roots) {
      $this.Roots = $roots
    } else {
      $this.Roots = @{} # Default to empty hashtable if null
    }
    $this.ToolsChangeConsumers = if ($null -ne $toolsChangeConsumers) { $toolsChangeConsumers } else { [System.Collections.Generic.List[scriptblock]]::new() }
    $this.ResourcesChangeConsumers = if ($null -ne $resourcesChangeConsumers) { $resourcesChangeConsumers } else { [System.Collections.Generic.List[scriptblock]]::new() }
    $this.PromptsChangeConsumers = if ($null -ne $promptsChangeConsumers) { $promptsChangeConsumers } else { [System.Collections.Generic.List[scriptblock]]::new() }
    $this.LoggingConsumers = if ($null -ne $loggingConsumers) { $loggingConsumers } else { [System.Collections.Generic.List[scriptblock]]::new() }
    $this.SamplingHandler = $samplingHandler
  }
}

class McpClient {
  [string]$Name
  [guid]$Id = [guid]::NewGuid()
}

class McpAsyncClient : McpClient {
  # Placeholder for McpAsyncClient implementation
  [ClientMcpTransport]$Transport
  [TimeSpan]$RequestTimeout
  [Async]$Features
  [McpSession]$McpSession
  [ServerCapabilities]$ServerCapabilities
  [Implementation]$ServerInfo
  [ClientCapabilities]$ClientCapabilities
  [Implementation]$ClientInfo
  [hashtable]$Roots
  [scriptblock]$SamplingHandler
  [System.Collections.Generic.List[string]]$ProtocolVersions

  McpAsyncClient ([ClientMcpTransport]$transport, [TimeSpan]$requestTimeout, [Async]$features) {
    if ($null -eq $transport) {
      throw [System.ArgumentNullException]::new("transport", "Transport must not be null")
    }
    if ($null -eq $requestTimeout) {
      throw [System.ArgumentNullException]::new("requestTimeout", "Request timeout must not be null")
    }
    $this.Transport = $transport
    $this.RequestTimeout = $requestTimeout
    $this.Features = $features
    $this.ClientInfo = $features.ClientInfo
    $this.ClientCapabilities = $features.ClientCapabilities
    $this.Roots = $features.Roots
    $this.SamplingHandler = $features.SamplingHandler
    $this.ProtocolVersions = [System.Collections.Generic.List[string]]::new()
    $this.ProtocolVersions.Add([McpObject]::LATEST_PROTOCOL_VERSION)
    $this.McpSession = [McpSession]::new() #Instantiate the session!
  }

  [InitializeResult] Initialize() {
    $request = [InitializeRequest]::new(
      [McpObject]::LATEST_PROTOCOL_VERSION,
      $this.ClientCapabilities,
      $this.ClientInfo
    )

    $response = $this.Transport.SendMessage($request)
    $result = $this.Mapper.Deserialize($response, [InitializeResult])

    $this.ServerCapabilities = $result.capabilities
    $this.ServerInfo = $result.serverInfo

    return $result
  }

  [ServerCapabilities] GetServerCapabilities () {
    return $this.ServerCapabilities
  }

  [Implementation] GetServerInfo () {
    return $this.ServerInfo
  }

  [ClientCapabilities] GetClientCapabilities () {
    return $this.ClientCapabilities
  }

  [Implementation] GetClientInfo () {
    return $this.ClientInfo
  }

  [void] Close () {
    $this.McpSession.Close()
  }

  [void] CloseGracefully () {
    $this.McpSession.CloseGracefully()
  }

  [void] RootsListChangedNotification () {
    Write-Host "RootsListChangedNotification Request Sent (Placeholder)"
  }

  [void] AddRoot ([Root]$root) {
    if ($null -eq $root) {
      throw [System.ArgumentNullException]::new("root", "Root must not be null")
    }
    if ($null -eq $this.ClientCapabilities.roots) {
      throw [McpError]::new("Client must be configured with roots capabilities")
    }
    if ($this.Roots.ContainsKey($root.uri)) {
      throw [McpError]::new("Root with uri '$($root.uri)' already exists")
    }
    $this.Roots[$root.uri] = $root
    Write-Host "AddRoot Request Sent (Placeholder): $($root | ConvertTo-Json -Compress)"
  }

  [void] RemoveRoot ([string]$rootUri) {
    if ($null -eq $rootUri) {
      throw [System.ArgumentNullException]::new("rootUri", "Root uri must not be null")
    }
    if ($null -eq $this.ClientCapabilities.roots) {
      throw [McpError]::new("Client must be configured with roots capabilities")
    }
    $removed = $this.Roots.Remove($rootUri)
    if ($removed) {
      Write-Host "RemoveRoot Request Sent (Placeholder): Root URI '$rootUri' removed"
    } else {
      throw [McpError]::new("Root with uri '$rootUri' not found")
    }
  }

  [string] Ping () {
    Write-Host "Ping Request Sent (Placeholder)"
    return "pong" # Placeholder - Should be server response, for now simulate
  }

  [CallToolResult] CallTool ([CallToolRequest]$callToolRequest) {
    if ($null -eq $this.ServerCapabilities.tools) {
      throw [McpError]::new("Server does not provide tools capability")
    }
    Write-Host "CallTool Request Sent (Placeholder): $($callToolRequest | ConvertTo-Json -Compress)"
    # Simulate response for now
    $content = @([TextContent]::new("Tool execution result"))
    return [CallToolResult]::new($content, $false)
  }

  [ListToolsResult] ListTools () {
    if ($null -eq $this.ServerCapabilities.tools) {
      throw [McpError]::new("Server does not provide tools capability")
    }
    Write-Host "ListTools Request Sent (Placeholder)"
    # Simulate response for now
    $tool = [Tool]::new("mockTool", "Mock Tool Description", "{`"type`": `"object`", `"properties`": {}}")
    return [ListToolsResult]::new(@($tool), $null)
  }

  [ListToolsResult] ListToolsCursor ([string]$cursor) {
    # Placeholder - Implement cursor based listing if needed
    return $this.ListTools()
  }

  [ListResourcesResult] ListResources () {
    if ($null -eq $this.ServerCapabilities.resources) {
      throw [McpError]::new("Server does not provide the resources capability")
    }
    Write-Host "ListResources Request Sent (Placeholder)"
    # Simulate response for now
    $resource = [Resource]::new("mock://resource", "Mock Resource", "Mock Resource Description", "text/plain", $null)
    return [ListResourcesResult]::new(@($resource), $null)
  }

  [ListResourcesResult] ListResourcesCursor ([string]$cursor) {
    # Placeholder - Implement cursor based listing if needed
    return $this.ListResources()
  }

  [ReadResourceResult] ReadResource ([Resource]$resource) {
    if ($null -eq $this.ServerCapabilities.resources) {
      throw [McpError]::new("Server does not provide the resources capability")
    }
    Write-Host "ReadResource Request Sent (Placeholder): $($resource | ConvertTo-Json -Compress)"
    # Simulate response for now
    $textContent = [TextResourceContents]::new($resource.uri, "text/plain", "Mock resource content")
    return [ReadResourceResult]::new(@($textContent))
  }

  [ReadResourceResult] ReadResourceRequest ([ReadResourceRequest]$readResourceRequest) {
    if ($null -eq $this.ServerCapabilities.resources) {
      throw [McpError]::new("Server does not provide the resources capability")
    }
    Write-Host "ReadResourceRequest Request Sent (Placeholder): $($readResourceRequest | ConvertTo-Json -Compress)"
    # Simulate response for now - Assuming URI is directly usable as resource URI
    $textContent = [TextResourceContents]::new($readResourceRequest.uri, "text/plain", "Mock resource content")
    return [ReadResourceResult]::new(@($textContent))
  }

  [ListResourceTemplatesResult] ListResourceTemplates () {
    if ($null -eq $this.ServerCapabilities.resources) {
      throw [McpError]::new("Server does not provide the resources capability")
    }
    Write-Host "ListResourceTemplates Request Sent (Placeholder)"
    # Simulate response for now
    $template = [ResourceTemplate]::new("mock://template/{param}", "Mock Template", "Mock Template Description", "text/plain", $null)
    return [ListResourceTemplatesResult]::new(@($template), $null)
  }

  [ListResourceTemplatesResult] ListResourceTemplatesCursor ([string]$cursor) {
    # Placeholder - Implement cursor based listing if needed
    return $this.ListResourceTemplates()
  }

  [void] SubscribeResource ([SubscribeRequest]$subscribeRequest) {
    if ($null -eq $this.ServerCapabilities.resources) {
      throw [McpError]::new("Server does not provide the resources capability")
    }
    Write-Host "SubscribeResource Request Sent (Placeholder): $($subscribeRequest | ConvertTo-Json -Compress)"
  }

  [void] UnsubscribeResource ([UnsubscribeRequest]$unsubscribeRequest) {
    if ($null -eq $this.ServerCapabilities.resources) {
      throw [McpError]::new("Server does not provide the resources capability")
    }
    Write-Host "UnsubscribeResource Request Sent (Placeholder): $($unsubscribeRequest | ConvertTo-Json -Compress)"
  }

  [ListPromptsResult] ListPrompts () {
    if ($null -eq $this.ServerCapabilities.prompts) {
      throw [McpError]::new("Server does not provide the prompts capability")
    }
    Write-Host "ListPrompts Request Sent (Placeholder)"
    # Simulate response for now
    $argument = [PromptArgument]::new("param1", "Parameter 1 Description", $true)
    $prompt = [Prompt]::new("mockPrompt", "Mock Prompt Description", @($argument))
    return [ListPromptsResult]::new(@($prompt), $null)
  }

  [ListPromptsResult] ListPromptsCursor ([string]$cursor) {
    # Placeholder - Implement cursor based listing if needed
    return $this.ListPrompts()
  }

  [GetPromptResult] GetPrompt ([GetPromptRequest]$getPromptRequest) {
    if ($null -eq $this.ServerCapabilities.prompts) {
      throw [McpError]::new("Server does not provide the prompts capability")
    }
    Write-Host "GetPrompt Request Sent (Placeholder): $($getPromptRequest | ConvertTo-Json -Compress)"
    # Simulate response for now
    $message = [PromptMessage]::new("user", [TextContent]::new("Mock prompt message content"))
    return [GetPromptResult]::new("Mock Prompt Description", @($message))
  }

  [void] SetLoggingLevel ([LoggingLevel]$loggingLevel) {
    if ($null -eq $this.ServerCapabilities.logging) {
      # While logging is enabled by default in builder, good to check
      throw [McpError]::new("Server does not provide the logging capability")
    }
    Write-Host "SetLoggingLevel Request Sent (Placeholder): $($loggingLevel | ConvertTo-Json -Compress)"
  }

  # Placeholder - Implement setProtocolVersions if needed for testing
  [void] setProtocolVersions ([System.Collections.Generic.List[string]]$protocolVersions) {
    $this.ProtocolVersions = $protocolVersions
  }
}

class McpSyncClient : McpClient {
  [McpAsyncClient]$Delegate

  McpSyncClient ([McpAsyncClient]$delegate) {
    if ($null -eq $delegate) {
      throw [System.ArgumentNullException]::new("delegate", "The delegate can not be null")
    }
    $this.Delegate = $delegate
  }

  [ServerCapabilities] GetServerCapabilities () {
    return $this.Delegate.GetServerCapabilities()
  }

  [Implementation] GetServerInfo () {
    return $this.Delegate.GetServerInfo()
  }

  [ClientCapabilities] GetClientCapabilities () {
    return $this.Delegate.GetClientCapabilities()
  }

  [Implementation] GetClientInfo () {
    return $this.Delegate.GetClientInfo()
  }

  Close () {
    $this.Delegate.Close()
  }

  [void] CloseGracefully () {
    $this.Delegate.CloseGracefully()
  }

  [InitializeResult] Initialize () {
    return $this.Delegate.Initialize()
  }

  [void] RootsListChangedNotification () {
    $this.Delegate.RootsListChangedNotification()
  }

  [void] AddRoot ([Root]$root) {
    $this.Delegate.AddRoot($root)
  }

  [void] RemoveRoot ([string]$rootUri) {
    $this.Delegate.RemoveRoot($rootUri)
  }

  [string ]Ping () {
    return $this.Delegate.Ping()
  }

  [CallToolResult] CallTool ([CallToolRequest]$callToolRequest) {
    return $this.Delegate.CallTool($callToolRequest)
  }

  [ListToolsResult] ListTools () {
    return $this.Delegate.ListTools()
  }

  [ListToolsResult] ListToolsCursor ([string]$cursor) {
    return $this.Delegate.ListToolsCursor($cursor)
  }

  [ListResourcesResult] ListResources () {
    return $this.Delegate.ListResources()
  }

  [ListResourcesResult] ListResourcesCursor ([string]$cursor) {
    return $this.Delegate.ListResourcesCursor($cursor)
  }

  [ReadResourceResult] ReadResource ([Resource]$resource) {
    return $this.Delegate.ReadResource($resource)
  }

  [ReadResourceResult] ReadResourceRequest ([ReadResourceRequest]$readResourceRequest) {
    return $this.Delegate.ReadResourceRequest($readResourceRequest)
  }

  [ListResourceTemplatesResult] ListResourceTemplates () {
    return $this.Delegate.ListResourceTemplates()
  }

  [ListResourceTemplatesResult] ListResourceTemplatesCursor ([string]$cursor) {
    return $this.Delegate.ListResourceTemplatesCursor($cursor)
  }

  [void] SubscribeResource ([SubscribeRequest]$subscribeRequest) {
    $this.Delegate.SubscribeResource($subscribeRequest)
  }

  [void] UnsubscribeResource ([UnsubscribeRequest]$unsubscribeRequest) {
    $this.Delegate.UnsubscribeResource($unsubscribeRequest)
  }

  [ListPromptsResult] ListPrompts () {
    return $this.Delegate.ListPrompts()
  }

  [ListPromptsResult] ListPromptsCursor ([string]$cursor) {
    return $this.Delegate.ListPromptsCursor($cursor)
  }

  [GetPromptResult] GetPrompt ([GetPromptRequest]$getPromptRequest) {
    return $this.Delegate.GetPrompt($getPromptRequest)
  }

  [GetPromptResult] SetLoggingLevel ([LoggingLevel]$loggingLevel) {
    return $this.Delegate.SetLoggingLevel($loggingLevel)
  }
}

class ClientConsumer {
  [ValidateNotNull()][scriptblock]$script
  ClientConsumer([scriptblock]$script) {
    $this.script = $script
  }
}

class ToolsChangeConsumer : ClientConsumer {
  ToolsChangeConsumer([scriptblock]$sc) : base($sc) {}
}

class ResourcesChangeConsumer : ClientConsumer {
  ResourcesChangeConsumer([scriptblock]$sc) : base($sc) {}
}

class PromptsChangeConsumer : ClientConsumer {
  PromptsChangeConsumer([scriptblock]$sc) : base($sc) {}
}

class LoggingConsumer : ClientConsumer {
  LoggingConsumer([scriptblock]$sc) : base($sc) {}
}


class McpClientSyncSpec : McpSyncClient {
  [ClientCapabilities]$Capabilities
  [ClientMcpTransport]$Transport
  [Implementation]$ClientInfo
  [TimeSpan]$RequestTimeout
  [hashtable]$Roots
  [ValidateNotNull()][System.Collections.Generic.List[ToolsChangeConsumer]]$ToolsChangeConsumers
  [ValidateNotNull()][System.Collections.Generic.List[ResourcesChangeConsumer]]$ResourcesChangeConsumers
  [ValidateNotNull()][System.Collections.Generic.List[PromptsChangeConsumer]]$PromptsChangeConsumers
  [ValidateNotNull()][System.Collections.Generic.List[LoggingConsumer]]$LoggingConsumers
  [ValidateNotNull()][scriptblock]$SamplingHandler
  McpClientSyncSpec() {}
  McpClientSyncSpec ([ClientMcpTransport]$transport) : base ($transport) {
    if ($null -eq $transport) {
      throw [System.ArgumentNullException]::new("transport", "Transport must not be null")
    }
    $this.Transport = $transport
    $this.RequestTimeout = [TimeSpan]::FromSeconds(20) # Default timeout
    $this.ClientInfo = [Implementation]::new("PowerShell SDK MCP Client", "1.0.0")
    $this.Capabilities = [ClientCapabilities]::create() # Default Capabilities
    $this.Roots = @{}
    $this.ToolsChangeConsumers = [System.Collections.Generic.List[ToolsChangeConsumer]]::new()
    $this.ResourcesChangeConsumers = [System.Collections.Generic.List[ResourcesChangeConsumer]]::new()
    $this.PromptsChangeConsumers = [System.Collections.Generic.List[PromptsChangeConsumer]]::new()
    $this.LoggingConsumers = [System.Collections.Generic.List[LoggingConsumer]]::new()
  }

  McpClientSyncSpec ([TimeSpan]$requestTimeout) {
    if ($null -eq $requestTimeout) {
      throw [System.ArgumentNullException]::new("requestTimeout", "Request timeout must not be null")
    }
    $this.RequestTimeout = $requestTimeout
  }

  McpClientSyncSpec ([ClientCapabilities]$capabilities) {
    if ($null -eq $capabilities) {
      throw [System.ArgumentNullException]::new("capabilities", "Capabilities must not be null")
    }
    $this.Capabilities = $capabilities
  }

  McpClientSyncSpec ([Implementation]$clientInfo) {
    if ($null -eq $clientInfo) {
      throw [System.ArgumentNullException]::new("clientInfo", "Client info must not be null")
    }
    $this.ClientInfo = $clientInfo
  }

  McpClientSyncSpec ([System.Collections.Generic.List[Root]]$roots) {
    if ($null -eq $roots) {
      throw [System.ArgumentNullException]::new("roots", "Roots must not be null")
    }
    foreach ($root in $roots) {
      $this.Roots[$root.uri] = $root
    }
  }

  McpClientSyncSpec ([Root[]]$roots) {
    if ($null -eq $roots) {
      throw [System.ArgumentNullException]::new("roots", "Roots must not be null")
    }
    foreach ($root in $roots) {
      $this.Roots[$root.uri] = $root
    }
  }

  McpClientSyncSpec ([scriptblock]$samplingHandler) {
    if ($null -eq $samplingHandler) {
      throw [System.ArgumentNullException]::new("samplingHandler", "Sampling handler must not be null")
    }
    $this.SamplingHandler = $samplingHandler
  }

  McpClientSyncSpec ([System.Collections.Generic.List[ToolsChangeConsumer]]$toolsChangeConsumers) {
    if ($null -eq $toolsChangeConsumers) {
      throw [System.ArgumentNullException]::new("toolsChangeConsumer", "Tools change consumer must not be null")
    }
    $this.ToolsChangeConsumers.Add($toolsChangeConsumers)
  }

  McpClientSyncSpec  ([System.Collections.Generic.List[ResourcesChangeConsumer]]$resourcesChangeConsumers) {
    if ($null -eq $resourcesChangeConsumers) {
      throw [System.ArgumentNullException]::new("resourcesChangeConsumer", "Resources change consumer must not be null")
    }
    $this.ResourcesChangeConsumers.Add($resourcesChangeConsumers)
  }

  McpClientSyncSpec ([System.Collections.Generic.List[PromptsChangeConsumer]]$promptsChangeConsumers) {
    if ($null -eq $promptsChangeConsumers) {
      throw [System.ArgumentNullException]::new("promptsChangeConsumer", "Prompts change consumer must not be null")
    }
    $this.PromptsChangeConsumers.Add($promptsChangeConsumers)
  }

  McpClientSyncSpec ([System.Collections.Generic.List[LoggingConsumer]]$loggingConsumers) {
    if ($null -eq $loggingConsumers) {
      throw [System.ArgumentNullException]::new("loggingConsumer", "Logging consumer must not be null")
    }
    $this.LoggingConsumers.Add($loggingConsumers)
  }

  [McpSyncClient] Build () {
    $asyncFeatures = [Async]::FromSync([Sync]::new(
        $this.ClientInfo,
        $this.Capabilities,
        $this.Roots,
        $this.ToolsChangeConsumers,
        $this.ResourcesChangeConsumers,
        $this.PromptsChangeConsumers,
        $this.LoggingConsumers,
        $this.SamplingHandler
      ))
    return [McpSyncClient]::new([McpAsyncClient]::new($this.Transport, $this.RequestTimeout, $asyncFeatures))
  }
}

class McpClientAsyncSpec : McpAsyncClient {
  [ClientMcpTransport]$Transport
  [TimeSpan]$RequestTimeout
  [ClientCapabilities]$Capabilities
  [Implementation]$ClientInfo
  [hashtable]$Roots
  [ValidateNotNull()][System.Collections.Generic.List[scriptblock]]$ToolsChangeConsumers
  [ValidateNotNull()][System.Collections.Generic.List[scriptblock]]$ResourcesChangeConsumers
  [ValidateNotNull()][System.Collections.Generic.List[scriptblock]]$PromptsChangeConsumers
  [ValidateNotNull()][System.Collections.Generic.List[scriptblock]]$LoggingConsumers
  [ValidateNotNull()][scriptblock]$SamplingHandler
  McpClientAsyncSpec() {}
  McpClientAsyncSpec ([ClientMcpTransport]$transport) : base ($transport, $null, $null) {
    if ($null -eq $transport) {
      throw [System.ArgumentNullException]::new("transport", "Transport must not be null")
    }
    $this.Transport = $transport
    $this.RequestTimeout = [TimeSpan]::FromSeconds(20) # Default timeout
    $this.ClientInfo = [Implementation]::new("PowerShell SDK MCP Client", "1.0.0")
    $this.Capabilities = [ClientCapabilities]::create() # Default Capabilities
    $this.Roots = @{}
    $this.ToolsChangeConsumers = [System.Collections.Generic.List[scriptblock]]::new()
    $this.ResourcesChangeConsumers = [System.Collections.Generic.List[scriptblock]]::new()
    $this.PromptsChangeConsumers = [System.Collections.Generic.List[scriptblock]]::new()
    $this.LoggingConsumers = [System.Collections.Generic.List[scriptblock]]::new()
  }

  McpClientAsyncSpec ([TimeSpan]$requestTimeout) {
    if ($null -eq $requestTimeout) {
      throw [System.ArgumentNullException]::new("requestTimeout", "Request timeout must not be null")
    }
    $this.RequestTimeout = $requestTimeout
  }

  McpClientAsyncSpec ([ClientCapabilities]$capabilities) {
    if ($null -eq $capabilities) {
      throw [System.ArgumentNullException]::new("capabilities", "Capabilities must not be null")
    }
    $this.Capabilities = $capabilities
  }

  McpClientAsyncSpec ([Implementation]$clientInfo) {
    if ($null -eq $clientInfo) {
      throw [System.ArgumentNullException]::new("clientInfo", "Client info must not be null")
    }
    $this.ClientInfo = $clientInfo
  }

  McpClientAsyncSpec ([System.Collections.Generic.List[Root]]$roots) {
    if ($null -eq $roots) {
      throw [System.ArgumentNullException]::new("roots", "Roots must not be null")
    }
    foreach ($root in $roots) {
      $this.Roots[$root.uri] = $root
    }
  }

  McpClientAsyncSpec ([Root[]]$roots) {
    if ($null -eq $roots) {
      throw [System.ArgumentNullException]::new("roots", "Roots must not be null")
    }
    foreach ($root in $roots) {
      $this.Roots[$root.uri] = $root
    }
  }

  [McpAsyncClient] Build () {
    return [McpAsyncClient]::new(
      $this.Transport,
      $this.RequestTimeout,
      [Async]::new(
        $this.ClientInfo,
        $this.Capabilities,
        $this.Roots,
        $this.ToolsChangeConsumers,
        $this.ResourcesChangeConsumers,
        $this.PromptsChangeConsumers,
        $this.LoggingConsumers,
        $this.SamplingHandler
      )
    )
  }
}

class ObjectMapper : McpObject {
  [hashtable]$TypeRegistry = @{}

  ObjectMapper() {
    $this.RegisterTypes()
  }

  RegisterTypes() {
    $assembly = [McpObject].Assembly
    $types = $assembly.GetTypes() | Where-Object { $_ -ne [McpObject] -and [McpObject].IsAssignableFrom($_) }
    foreach ($type in $types) {
      $this.TypeRegistry[$type.Name] = $type
    }
  }

  [string] Serialize([object]$obj) {
    return $obj.ToJson()
  }

  [object] Deserialize([string]$json, [Type]$targetType) {
    $raw = $json | ConvertFrom-Json -Depth 10
    return $this.ConvertToType($raw, $targetType)
  }

  hidden [object] ConvertToType([object]$obj, [Type]$targetType) {
    if ($obj -is [hashtable] -or $obj -is [PSCustomObject]) {
      $instance = $targetType::new()
      foreach ($prop in $targetType.GetProperties()) {
        $value = $obj.$($prop.Name)
        if ($null -ne $value) {
          $propType = $prop.PropertyType
          $instance.$($prop.Name) = $this.ConvertValue($value, $propType)
        }
      }
      return $instance
    }
    return $obj
  }

  hidden [object] ConvertValue([object]$value, [Type]$targetType) {
    if ($targetType.IsEnum) {
      return [Enum]::Parse($targetType, $value)
    } elseif ($targetType.Name -eq 'List`1') {
      $genericType = $targetType.GetGenericArguments()[0]
      $list = [System.Collections.Generic.List[object]]::new()
      foreach ($item in $value) {
        $list.Add($this.ConvertToType($item, $genericType))
      }
      return $list
    }
    return $value
  }
}

# Placeholder Transport Implementation - Stdio for PoC (You can create other transport classes later)
class StdioClientTransport : ClientMcpTransport {
  [ServerParameters]$Params
  [ObjectMapper]$ObjectMapper
  [System.Diagnostics.Process]$Process
  [IO.StreamReader]$ProcessReader
  [IO.StreamWriter]$ProcessWriter

  StdioClientTransport ([ServerParameters]$params) {
    if ($null -eq $params) {
      throw [System.ArgumentNullException]::new("params", "The params can not be null")
    }
    $this.Params = $params
    $this.ObjectMapper = [ObjectMapper]::new()
  }

  [void] Connect ([scriptblock]$handler) {
    Write-Host "StdioClientTransport Connect - Command: $($this.Params.Command)"
    try {
      $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
      $startInfo.FileName = $this.Params.Command
      $startInfo.Arguments = ($this.Params.Args -join ' ')
      $startInfo.RedirectStandardInput = $true
      $startInfo.RedirectStandardOutput = $true
      $startInfo.UseShellExecute = $false
      $startInfo.CreateNoWindow = $true
      #$startInfo.EnvironmentVariables.AddRange($this.Params.Env) #TODO: Check if hashtable conversion works directly

      $this.Process = [System.Diagnostics.Process]::Start($startInfo)
      $this.ProcessReader = [IO.StreamReader]::new($this.Process.StandardOutput.BaseStream)
      $this.ProcessWriter = [IO.StreamWriter]::new($this.Process.StandardInput.BaseStream)

      # Start reading output in a background job (similar to async handling)
      Start-Job -Name "MCPTransportReader" -ScriptBlock {
        param($reader, $mapper, $handler)
        while (-not $reader.EndOfStream) {
          $line = $reader.ReadLine()
          try {
            $message = $mapper.Deserialize($line, [JSONRPCMessage])
            & $handler $message
          } catch {
            Write-Error "Error processing message: $_"
          }
        }
      } -ArgumentList $this.ProcessReader, $this.ObjectMapper, $handler | Out-Null
    } catch {
      Write-Error "Error starting process or connecting: $_"
      throw
    }
  }

  [void] SendMessage ([JSONRPCMessage]$message) {
    Write-Host "StdioClientTransport SendMessage: $($message | ConvertTo-Json -Compress)"
    try {
      $json = $this.ObjectMapper.Serialize($message)
      $this.ProcessWriter.WriteLine($json)
      $this.ProcessWriter.Flush() # Ensure message is sent immediately
    } catch {
      Write-Error "Error sending message to process: $_"
      throw
    }
  }

  [void] CloseGracefully () {
    Write-Host "StdioClientTransport CloseGracefully"
    if ($this.Process) {
      try {
        $this.Process.Kill() #Or .CloseMainWindow() for graceful shutdown attempt?
        $this.Process.WaitForExit(5000) # Wait max 5 seconds for exit
        if (-not $this.Process.HasExited) {
          Write-Warning "Process did not exit gracefully within timeout."
          $this.Process.Kill() # Force kill if still running
        }
      } catch {
        Write-Warning "Error during process shutdown: $_"
      } finally {
        $this.Process.Dispose()
      }
    }
    if ($this.ProcessReader) {
      $this.ProcessReader.Dispose()
    }
    if ($this.ProcessWriter) {
      $this.ProcessWriter.Dispose()
    }
  }

  [Object] UnmarshalFrom ([Object]$data, [type]$typeRef) {
    Write-Host "StdioClientTransport UnmarshalFrom - Data: $($data | ConvertTo-Json -Compress), Type: $($typeRef)"
    # Basic placeholder - you might need more robust conversion based on TypeRef
    return $data # Placeholder - return data as is for now
  }
}

class ServerParameters {
  [string]$Command
  [string[]]$Args
  [hashtable]$Env

  ServerParameters([string]$command) {
    $this.Command = $command
    $this.Args = @()
    $this.Env = @{}
  }

  [ServerParameters] AddArgs([string[]]$arguments) {
    $this.Args += $arguments
    return $this
  }

  [ServerParameters] AddEnv([hashtable]$environment) {
    foreach ($key in $environment.Keys) {
      $this.Env[$key] = $environment[$key]
    }
    return $this
  }

  [ServerParameters] Build() {
    return $this
  }
}


# Main class
class MCP {
  # .SYNOPSIS
  #   Model Context Protocol
  # .DESCRIPTION
  #   Provides basic MCP implementation, allowing creation of MCP servers and clients.
  [McpSyncClient]$SyncClient
  [McpAsyncClient]$AsyncClient
  [ClientMcpTransport]$Transport
  [ObjectMapper]$Mapper

  MCP([ClientMcpTransport]$transport) {
    $this.Transport = $transport
    $this.Mapper = [ObjectMapper]::new()
    $this.AsyncClient = [McpAsyncClient]::new($transport, [TimeSpan]::FromSeconds(30), $null)
    $this.SyncClient = [McpSyncClient]::new($this.AsyncClient)
  }

  [void] Initialize() {
    $this.SyncClient.Initialize() | Out-Null
  }

  [string] Ping() {
    return $this.SyncClient.Ping()
  }

  [ListToolsResult] ListTools() {
    return $this.SyncClient.ListTools()
  }

  [CallToolResult] CallTool([string]$toolName, [hashtable]$arguments) {
    $request = [CallToolRequest]::new($toolName, $arguments)
    return $this.SyncClient.CallTool($request)
  }

  [ListResourcesResult] ListResources() {
    return $this.SyncClient.ListResources()
  }

  [ReadResourceResult] ReadResource([string]$uri) {
    $request = [ReadResourceRequest]::new($uri)
    return $this.SyncClient.ReadResourceRequest($request)
  }

  static [MCP] Create([ClientMcpTransport]$transport) {
    return [MCP]::new($transport)
  }

  static [McpClientAsyncSpec] async ([ClientMcpTransport]$transport) {
    return [McpClientAsyncSpec]::new($transport)
  }

  static  [McpClientSyncSpec] sync ([ClientMcpTransport]$transport) {
    return  [McpClientSyncSpec]::new($transport)
  }
}

#region    UsageExample
# .EXAMPLE
<# Example usage with HTTP transport
Write-Host "--- MCP PowerShell SDK Example Usage ---"
$httpTransport = [HttpClientTransport]::new("http://localhost:8080/mcp")
$mcp = [MCP]::Create($httpTransport)
$mcp.Initialize()

# Get available tools
$tools = $mcp.ListTools()
$tools.tools | ForEach-Object {
    Write-Host "Tool: $($_.Name) - $($_.Description)"
}

# Call a tool
$result = $mcp.CallTool("weatherTool", @{ location = "New York" })
Write-Host "Tool result: $($result.Content.Text)"

# Example with Stdio transport
$serverParams = [ServerParameters]::new("node")
    .AddArgs(@("mcp-server.js", "--port=8080"))
    .AddEnv(@{ MCP_ENV = "production" })
    .Build()

$stdioTransport = [StdioClientTransport]::new($serverParams)
$mcp = [MCP]::Create($stdioTransport)
$mcp.Initialize()
#>
#endregion UsageExample

#endregion Classes
# Types that will be available to users when they import the module.
$typestoExport = @(
  [MCP], [McpObject], [McpError], [ReadResourceRequest], [CallToolRequest],
  [HttpClientTransport], [McpAsyncClient], [McpClientSyncSpec], [ObjectMapper],
  [ClientMcpTransport], [JSONRPCResponse], [ResourceTemplate], [ClientCapabilities],
  [ServerParameters], [LoggingMessageNotification]. [JSONRPCMessage], [LoggingLevel], [ErrorCodes]
)
$TypeAcceleratorsClass = [PsObject].Assembly.GetType('System.Management.Automation.TypeAccelerators')
foreach ($Type in $typestoExport) {
  if ($Type.FullName -in $TypeAcceleratorsClass::Get.Keys) {
    $Message = @(
      "Unable to register type accelerator '$($Type.FullName)'"
      'Accelerator already exists.'
    ) -join ' - '
    "TypeAcceleratorAlreadyExists $Message" | Write-Debug
  }
}
# Add type accelerators for every exportable type.
foreach ($Type in $typestoExport) {
  $TypeAcceleratorsClass::Add($Type.FullName, $Type)
}
# Remove type accelerators when the module is removed.
$MyInvocation.MyCommand.ScriptBlock.Module.OnRemove = {
  foreach ($Type in $typestoExport) {
    $TypeAcceleratorsClass::Remove($Type.FullName)
  }
}.GetNewClosure();

$scripts = @();
$Public = Get-ChildItem "$PSScriptRoot/Public" -Filter "*.ps1" -Recurse -ErrorAction SilentlyContinue
$scripts += Get-ChildItem "$PSScriptRoot/Private" -Filter "*.ps1" -Recurse -ErrorAction SilentlyContinue
$scripts += $Public

foreach ($file in $scripts) {
  Try {
    if ([string]::IsNullOrWhiteSpace($file.fullname)) { continue }
    . "$($file.fullname)"
  } Catch {
    Write-Warning "Failed to import function $($file.BaseName): $_"
    $host.UI.WriteErrorLine($_)
  }
}

$Param = @{
  Function = $Public.BaseName
  Cmdlet   = '*'
  Alias    = '*'
  Verbose  = $false
}
Export-ModuleMember @Param
