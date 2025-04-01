#!/usr/bin/env pwsh
using namespace System
using namespace System.IO
using namespace System.Net
using namespace System.Text
using namespace System.Net.Http
using namespace System.Text.Json
using namespace System.Threading
using namespace System.Collections
using namespace System.Diagnostics
using namespace System.Threading.Channels
using namespace System.Collections.Generic
using namespace System.Management.Automation
using namespace System.Collections.Concurrent
using namespace System.Diagnostics.CodeAnalysis
using namespace System.Runtime.InteropServices
using namespace System.Text.Json.Serialization

#Requires -Modules ThreadJob
#region    Enums
# .EXAMPLE
# [LoggingLevel]::Alert
# .EXAMPLE
#  'Fatal' -in [enum]::GetNames[LoggingLevel]()
# False

enum McpRole {
  User
  Assistant
}
enum McpContextInclusion {
  None
  ThisServer
  AllServers
}
enum McpLoggingLevel {
  Debug
  Info
  Notice
  Warning
  Error
  Critical
  Alert
  Emergency
}
enum McpTransportTypes {
  StdIo
  Sse
  Http
}
enum McpErrorCodes {
  ParseError = -32700
  InvalidRequest = -32600
  MethodNotFound = -32601
  InvalidParams = -32602
  InternalError = -32603
  ServerError = -32000
}

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

enum LogLevel {
  Trace = 0
  Debug = 1
  Information = 2
  Warning = 3
  Error = 4
  Critical = 5
  None = 6
}

#endregion Enums

#region    Classes

#region    Exceptions

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

class McpError : System.Exception {
  [int]$Code # Use McpErrorCodes enum values
  [object]$Data

  McpError([string]$message, [int]$code = [McpErrorCodes]::ServerError, [object]$data = $null) : base ($message) {
    $this.Code = $code
    $this.Data = $data
  }
}
class McpTransportException : Exception {
  McpTransportException() : base() {}
  McpTransportException([string]$message) : base($message) {}
  McpTransportException([string]$message, [Exception]$innerException) : base($message, $innerException) {}
}
class McpClientException : McpError {
  McpClientException([string]$message, [int]$code = [McpErrorCodes]::ServerError, [object]$data = $null) : base($message, $code, $data) {}
  McpClientException([string]$message, [Exception]$innerException) : base($message) { $this.Code = [McpErrorCodes]::ServerError }
}
class McpServerException : McpError {
  McpServerException([string]$message, [int]$code = [McpErrorCodes]::ServerError, [object]$data = $null) : base($message, $code, $data) {}
  McpServerException([string]$message, [Exception]$innerException) : base($message) { $this.Code = [McpErrorCodes]::ServerError }
}
#endregion Exceptions

# Defines server options sent to client during initialization
class McpServerOptions {
  #info about this server.
  [ValidateNotNullOrEmpty()][McpImplementation] $ServerInfo #
  # Server capabilities to advertise.
  [McpServerCapabilities]$Capabilities
  # Protocol version server will use.
  [string] $ProtocolVersion = "2024-11-05"
  # Timeout for client initialization sequence.
  [TimeSpan] $InitializationTimeout = [TimeSpan]::FromSeconds(60)
  # Optional instructions for client (e.g., hint for system prompt).
  [string] $ServerInstructions = ''

  # --- Handlers (moved from specific capabilities for easier PS access) ---
  # These should ideally be configured via a builder pattern or DI.
  # Storing them directly on options is simpler for pure PS but less flexible.
  [scriptblock]$ListToolsHandler
  [scriptblock]$CallToolHandler
  [scriptblock]$ListPromptsHandler
  [scriptblock]$GetPromptHandler
  [scriptblock]$ListResourceTemplatesHandler
  [scriptblock]$ListResourcesHandler
  [scriptblock]$ReadResourceHandler
  [scriptblock]$SubscribeToResourcesHandler
  [scriptblock]$UnsubscribeFromResourcesHandler
  [scriptblock]$GetCompletionHandler
  [scriptblock]$SetLoggingLevelHandler
  [McpServerToolCollection]$ToolCollection
}

class McpAnnotations {
  # Describes who the intended customer of this object or data is.
  [List[McpRole]]$Audience

  # Describes how important this data is for operating the server (0 to 1).
  [float]$Priority
}

class McpToolAnnotations {
  # A human-readable title for the tool.
  [string]$Title

  # If true, the tool may perform destructive updates. Default: true.
  [bool]$DestructiveHint = $true

  # If true, calling repeatedly with the same arguments has no additional effect. Default: false.
  [bool]$IdempotentHint = $false

  # If true, tool interacts with an "open world" (e.g., web search). Default: true.
  [bool]$OpenWorldHint = $true

  # If true, the tool does not modify its environment. Default: false.
  [bool]$ReadOnlyHint = $false
}

# Attribute to mark types containing MCP tools
# Use comment or basic attribute for PS version
class McpServerToolTypeAttribute : Attribute {}

class McpResourceContents {
  # The URI of the resource.
  [string] $Uri = ''
  # The MIME type of the content.
  [string]$MimeType
}


class McpContent {
  # The type of content: "image", "audio", "text", "resource".
  [ValidateNotNullOrEmpty()][string] $Type = ' ' #

  # Text content. Used when Type is "text".
  [string]$Text

  # Base64-encoded data. Used when Type is "image" or "audio".
  [string]$Data

  # MIME type. Used when Type is "image" or "audio".
  [string]$MimeType

  # Resource content (if embedded). Used when Type is "resource".
  [McpResourceContents]$Resource

  # Optional annotations.
  [McpAnnotations]$Annotations
}

class McpRequestParamsMetadata {
  # Opaque token for progress notifications.
  # [JsonPropertyName("progressToken")] # Serialization hint
  [object] $ProgressToken # Can be string or number
}

class McpRequestParams {
  # Metadata related to the request.
  [McpRequestParamsMetadata]$Meta
}


class McpCallToolRequestParams : McpRequestParams {

  [ValidateNotNullOrEmpty()][string] $Name #

  [Dictionary[string, object]]$Arguments # Hashtable might also work
}

class McpTool {
  # The name of the tool.

  [ValidateNotNullOrEmpty()][string] $Name = ' ' #

  # A human-readable description of the tool.

  [string]$Description

  # JSON Schema object defining the expected parameters. Type must be 'object'.
  # Needs external validation. C# uses McpJsonUtilities.IsValidMcpToolSchema.
  [System.Text.Json.JsonElement] $InputSchema = [System.Text.Json.JsonSerializer]::Deserialize[System.Text.Json.JsonElement]('{"type":"object"}')

  # Optional additional tool information.
  [McpToolAnnotations]$Annotations
}

class McpCallToolResponse {
  [ValidateNotNullOrEmpty()][List[McpContent]]$Content = @() #(can be empty list)
  [bool] $IsError #
}


# Attribute to mark methods as MCP tools
# Use comment or basic attribute for PS version
# [AttributeUsage(AttributeTargets.Method)]
class McpServerToolAttribute : Attribute {
  [string]$Name
  [string]$Title
  # C# uses internal fields + properties to track if set. Simpler PS version:
  [bool]$Destructive
  [bool]$Idempotent
  [bool]$OpenWorld
  [bool]$ReadOnly
}


class McpObject : IDisposable {
  # Provides static props, methods and basic Schema to all objects used by main class ie: MCP
  static [string] $LATEST_PROTOCOL_VERSION = "2024-11-05"
  static [string] $JSONRPC_VERSION = "2.0"
  [string] ToJson() {
    return $this | ConvertTo-Json -Depth 10 -Compress
  }
  static [object] FromJson([string]$json) {
    return $json | ConvertFrom-Json -Depth 10
  }
  [void] Dispose() {}
}

class Content : McpObject {
  #Marker Class
}

class PromptMessage : McpObject {
  [McpRole]$role
  [Content]$content

  PromptMessage ([McpRole]$role, [Content]$content) {
    $this.role = $role
    $this.content = $content
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
    if (!$method) {
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
        [McpErrorCodes]::InvalidRequest
      )
    }
  }

  [string] ToString() {
    return $this | ConvertTo-Json -Compress
  }
}

class TaskCreationOptions {
  static $RunContinuationsAsynchronously
}

class McpIJsonRpcMessage {
  # [JsonPropertyName("jsonrpc")] # Serialization hint
  [string] $Jsonrpc = "2.0"
}

class McpIJsonRpcMessageWithId : McpIJsonRpcMessage {
  [McpRequestId] $Id #
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

# Transport Implementation - Stdio for PoC (You can create other transport classes later)
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
        while (!$reader.EndOfStream) {
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
        if (!$this.Process.HasExited) {
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

class EventId {
  [int] $Id
  [string] $Name
  EventId([int]$id, [string]$name = $null) {
    $this.Id = $id
    $this.Name = $name
  }
  EventId() { $this.Id = 0; $this.Name = $null } # Default constructor
}
class ILogger {
  # Abstract methods require concrete implementation or throw in PS
  # BeginScope($state) { throw [NotImplementedException]; return $null }
  # IsEnabled([LogLevel]$logLevel) { throw [NotImplementedException]; return $false }
  Log(
    [LogLevel]$logLevel,
    [EventId]$eventId,
    $state,
    [Exception]$exception,
    [Func[object, Exception, string]]$formatter
  ) { throw [NotImplementedException]::new("Not yet implemented!") }
}
class ILoggerProvider : IDisposable {
  CreateLogger([string]$categoryName) { throw [NotImplementedException]::new("Not yet implemented!") }
  [void] Dispose() { throw [NotImplementedException]::new("Not yet implemented!") }
}

class ILoggerFactory : IDisposable {
  CreateLogger([string]$categoryName) { throw [NotImplementedException]::new("Not yet implemented!") }
  AddProvider([ILoggerProvider]$provider) { throw [NotImplementedException]::new("Not yet implemented!") }
  [void] Dispose() { throw [NotImplementedException]::new("Not yet implemented!") }
}

class NullLogger : ILogger {
  static [NullLogger] $Instance
  NullLogger() {
    [NullLogger]::Instance = $this
  }
  [void] BeginScope($state) { }
  [bool] IsEnabled([LogLevel]$logLevel) {
    return $false
  }
  Log([LogLevel]$logLevel, [EventId]$eventId, $state, [Exception]$exception, [Func[object, Exception, string]]$formatter) {
    # No-op
  }
}

class NullLoggerFactoryImpl : ILoggerFactory {
  hidden static [NullLoggerFactoryImpl] $_instance = [NullLoggerFactoryImpl]::new()
  # static [NullLoggerFactoryImpl] Instance { get { return [NullLoggerFactoryImpl]::$_instance } }

  AddProvider([ILoggerProvider]$provider) {}
  CreateLogger([string]$categoryName) {
    # Ensure NullLogger type exists
    # $nlType = Get-Type -TypeName 'NullLogger' -ErrorAction SilentlyContinue
    # if ($nlType) { return $nlType::Instance } else { return $null }
  }
  [void] Dispose() {}
}


class ServerCapabilities : McpObject {
  [hashtable]$experimental
  [LoggingCapabilities]$logging
  [PromptCapabilities]$prompts
  [ResourceCapabilities]$resources
  [ToolCapabilities]$tools

  ServerCapabilities () {}
  ServerCapabilities ([hashtable]$experimental, [LoggingCapabilities]$logging, [PromptCapabilities]$prompts, [ResourceCapabilities]$resources, [ToolCapabilities]$tools) {
    [void][ServerCapabilities]::From($experimental, $logging, $prompts, $resources, $tools, [ref][ServerCapabilities]::new())
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
  [System.Collections.Generic.List[McpRole]]$audience
  [double]$priority

  Annotations ([System.Collections.Generic.List[McpRole]]$audience, [double]$priority) {
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


class ListResourceTemplatesResult {
  [System.Collections.Generic.List[ResourceTemplate]]$resourceTemplates
  [string]$nextCursor

  ListResourceTemplatesResult ([System.Collections.Generic.List[ResourceTemplate]]$resourceTemplates, [string]$nextCursor) {
    $this.resourceTemplates = $resourceTemplates
    $this.nextCursor = $nextCursor
  }
}

class SubscribeRequest {
  [string]$uri
  SubscribeRequest ([string]$uri) {
    $this.uri = $uri
  }
}

class UnsubscribeRequest {
  [ValidateNotNullOrEmpty()][uri]$uri
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

class TextContent : Content {
  [System.Collections.Generic.List[McpRole]]$audience
  [double]$priority
  [string]$text

  TextContent ([string]$text) {
    #Simplified constructor for text content
    $this.text = $text
  }

  TextContent ([System.Collections.Generic.List[McpRole]]$audience, [double]$priority, [string]$text) {
    $this.audience = $audience
    $this.priority = $priority
    $this.text = $text
  }
}

class McpJsonRpcErrorDetail {
  [ValidateNotNullOrEmpty()][int] $Code #- Use McpErrorCodes enum

  [ValidateNotNullOrEmpty()][string] $Message #

  [object] $Data
}

class McpJsonRpcError : McpIJsonRpcMessageWithId {
  [ValidateNotNullOrEmpty()][McpJsonRpcErrorDetail] $Error #
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

class McpJsonRpcRequest : McpIJsonRpcMessageWithId {
  [ValidateNotNullOrEmpty()][string] $Method #
  [object] $Params # Can be object or array, handled by serializer
}

class McpJsonRpcResponse : McpIJsonRpcMessageWithId {
  [ValidateNotNullOrEmpty()][object] $Result #can be null JSON value
}

# Represents a JSON-RPC request identifier (string or number)
# C# uses a struct with custom converter. PowerShell can use [object] and check type.
class McpRequestId {
  [object] $Value # Can be [string] or [long]

  McpRequestId([object]$Value) {
    if ($Value -is [string] -or $Value -is [long] -or $Value -is [int]) {
      # Allow int for convenience
      if ($Value -is [int]) { $this.Value = [long]$Value }
      else { $this.Value = $Value }
    } else {
      throw [ArgumentException]::new("RequestId must be a string or a number (long/int).")
    }
  }

  [bool] IsString() { return $this.Value -is [string] }
  [bool] IsNumber() { return $this.Value -is [long] }
  [bool] IsValid() { return $null -ne $this.Value }

  [string] AsString() {
    if (!$this.IsString()) { throw [InvalidOperationException]::new("RequestId is not a string") }
    return [string]$this.Value
  }
  [long] AsNumber() {
    if (!$this.IsNumber()) { throw [InvalidOperationException]::new("RequestId is not a number") }
    return [long]$this.Value
  }
  [string] ToString() { return "$($this.Value)" } # Implicit conversion for logging etc.

  static [McpRequestId] FromString([string]$value) { return [McpRequestId]::new($value) }
  static [McpRequestId] FromNumber([long]$value) { return [McpRequestId]::new($value) }
  static [McpRequestId] FromNumber([int]$value) { return [McpRequestId]::new([long]$value) } # Convenience
}

class McpJsonUtilities {
  # Keep static DefaultOptions and CreateDefaultOptions
  static [JsonSerializerOptions] $DefaultOptions = [McpJsonUtilities]::CreateDefaultOptions()

  static hidden [JsonSerializerOptions] CreateDefaultOptions() {
    $options = [JsonSerializerOptions]::new([JsonSerializerDefaults]::Web)
    $options.Converters.Add([JsonStringEnumConverter]::new([JsonNamingPolicy]::CamelCase, $false))
    $options.DefaultIgnoreCondition = [JsonIgnoreCondition]::WhenWritingNull
    $options.NumberHandling = [JsonNumberHandling]::AllowReadingFromString
    $options.PropertyNameCaseInsensitive = $true
    # Consider WriteIndented for debugging? $options.WriteIndented = $true
    # Add TypeInfoResolver if needed for AOT/SourceGen later
    return $options
  }

  # Helper to deserialize params robustly
  static [object] DeserializeParams([object]$paramsObject, [Type]$targetType) {
    if ($null -eq $paramsObject) { return $null }
    $json = ''
    if ($paramsObject -is [System.Text.Json.JsonElement]) {
      $json = $paramsObject.GetRawText()
    } elseif ($paramsObject -is [string]) {
      $json = $paramsObject # Assume it's already JSON
    } else {
      # Attempt to serialize non-JsonElement/string objects before deserializing
      try {
        $json = [JsonSerializer]::Serialize($paramsObject, $paramsObject.GetType(), [McpJsonUtilities]::DefaultOptions)
      } catch {
        throw [ArgumentException]::new("Could not serialize request params of type $($paramsObject.GetType().Name) before deserializing to $($targetType.Name)", $_.Exception)
      }
    }
    try {
      return [JsonSerializer]::Deserialize($json, $targetType, [McpJsonUtilities]::DefaultOptions)
    } catch {
      throw [ArgumentException]::new("Could not deserialize request params JSON to type $($targetType.Name). JSON: $json", $_.Exception)
    }
  }

  static [int] ParseIntOrDefault([IDictionary]$options, [string]$key, [int]$defaultValue) {
    if ($null -ne $options -and $options.Contains($key) -and $null -ne $options[$key]) {
      $valueStr = [string]$options[$key]
      $parseResult = 0
      if ([int]::TryParse($valueStr, [ref]$parseResult)) {
        return $parseResult
      } else {
        Write-Warning "Invalid integer value '$valueStr' for option '$key'. Using default."
        # Throw instead? throw [ArgumentException]::new("Invalid integer value '$valueStr' for option '$key'.")
      }
    }
    return $defaultValue
  }

  static [Object] Deserialize([string]$json) {
    return [JsonSerializer]::Deserialize[T]($json, [McpJsonUtilities]::DefaultOptions)
  }

  static [string] Serialize([object]$obj) {
    return [JsonSerializer]::Serialize($obj, $obj.GetType(), [McpJsonUtilities]::DefaultOptions)
  }
}

# Base Transport Concept (Interface-like)
class McpTransport : IDisposable {
  [bool]$IsConnected = $false
  # Use BlockingCollection for thread-safe read queue
  [BlockingCollection[McpIJsonRpcMessage]]$MessageReaderQueue
  [McpLogger]$Logger

  McpTransport([McpLogger]$logger) {
    $this.Logger = $logger ?? [McpNullLogger]::Instance()
    $this.MessageReaderQueue = [BlockingCollection[McpIJsonRpcMessage]]::new()
  }

  # Methods to be implemented by derived classes
  [void] Connect() { throw [NotImplementedException] }
  [void] SendMessage([McpIJsonRpcMessage]$message) { throw [NotImplementedException] }
  [void] StartReceiving([ScriptBlock]$onMessageReceived) { throw [NotImplementedException] } # Needs background mechanism
  [void] StopReceiving() { throw [NotImplementedException] } # Needs to signal background mechanism

  [void] Dispose() {
    $this.Logger.Log([McpLoggingLevel]::Debug, "Disposing McpTransport...")
    $this.IsConnected = $false
    if ($null -ne $this.MessageReaderQueue) {
      $this.MessageReaderQueue.CompleteAdding() # Signal end for readers
      # Wait briefly for readers? Or let dispose handle it?
      try { $this.MessageReaderQueue.Dispose() } catch { $null }
      $this.MessageReaderQueue = $null
    }
    $this.StopReceiving() # Ensure receiver stops
    $this.Logger.Log([McpLoggingLevel]::Debug, "McpTransport disposed.")
  }

  # Helper for derived classes
  hidden ReceiveMessage([McpIJsonRpcMessage]$message) {
    if ($null -ne $this.MessageReaderQueue -and !$this.MessageReaderQueue.IsAddingCompleted) {
      try {
        $this.MessageReaderQueue.Add($message)
        $this.Logger.Log([McpLoggingLevel]::Debug, "Message added to reader queue.")
      } catch [InvalidOperationException] {
        $this.Logger.Log([McpLoggingLevel]::Warning, "Attempted to add message after reader queue was completed.")
      }
    } else {
      $this.Logger.Log([McpLoggingLevel]::Warning, "Reader queue is null or completed, cannot add message.")
    }
  }
}


# Establishes a client connection
# Needs actual implementation
class McpClientTransport : IDisposable {
  # Implement IDisposable for cleanup
  # Abstract method
  [List[McpTransport]] ConnectAsync([CancellationToken]$cancellationToken) {
    throw [NotImplementedException]::new("ConnectAsync must be implemented by derived client transport class.")
  }
  [Job] DisposeAsync() {
    # Added for consistency with C# pattern
    throw [NotImplementedException]::new("DisposeAsync must be implemented by derived client transport class.")
  }
  # Add synchronous Dispose
  [void] Dispose() {
    $this.DisposeAsync().GetAwaiter().GetResult()
  }
}

class McpJsonRpcNotification : McpIJsonRpcMessage {
  [ValidateNotNullOrEmpty()][string] $Method #

  [object] $Params # Can be object or array, handled by serializer
}

# Accepts incoming server connections
# Needs actual implementation
class McpIServerTransport : IDisposable {
  # Implement IDisposable for cleanup
  # Abstract method
  [List[McpTransport]] AcceptAsync([CancellationToken]$cancellationToken) {
    throw [NotImplementedException]::new("AcceptAsync must be implemented by derived server transport class.")
  }
  [Job] DisposeAsync() {
    # Added for consistency with C# pattern
    throw [NotImplementedException]::new("DisposeAsync must be implemented by derived server transport class.")
  }
  # Add synchronous Dispose
  [void] Dispose() {
    $this.DisposeAsync().GetAwaiter().GetResult()
  }
}


class McpTransportBase : McpTransport {
  [bool]$IsConnected = $false
  [BlockingCollection[McpIJsonRpcMessage]]$MessageReaderQueue = [BlockingCollection[McpIJsonRpcMessage]]::new()
  [ILogger]$Logger

  McpTransportBase([ILoggerFactory]$loggerFactory) {
    $this.Logger = if ($loggerFactory) { $loggerFactory.CreateLogger($this.GetType().Name) } else { [NullLogger]::Instance }
  }

  # SendMessageAsync and DisposeAsync remain abstract essentially
  [Job] SendMessageAsync([McpIJsonRpcMessage]$message, [CancellationToken]$cancellationToken) {
    # Base implementation could check IsConnected, but actual sending logic is transport specific
    if (!$this.IsConnected) {
      $this.Logger.LogWarning("Transport not connected, cannot send message.") # Example log
      throw [McpTransportException]::new("Transport is not connected")
    }
    throw [NotImplementedException]::new("SendMessageAsync must be implemented by concrete transport class.")
  }

  [Job] DisposeAsync() {
    $this.SetConnected($false)
    $this.CompleteAddingMessages()
    $this.MessageReaderQueue.Dispose()
    # Base cleanup, specific transports might need more
    return [Job]::CompletedTask
  }

  # Internal helpers for derived classes
  hidden SetConnected([bool]$isConnected) {
    if ($this.IsConnected -ne $isConnected) {
      $this.IsConnected = $isConnected
      if (!$isConnected) {
        $this.CompleteAddingMessages()
      }
    }
  }

  hidden [Job] WriteMessageAsync([McpIJsonRpcMessage]$message, [CancellationToken]$cancellationToken) {
    # Simplified: just adds to the queue
    if (!$this.IsConnected) { throw [McpTransportException]::new("Transport is not connected") }

    if ($this.MessageReaderQueue.IsAddingCompleted) {
      $this.Logger.LogWarning("Attempted to write message to completed queue for endpoint.")
      return [Job]::CompletedTask # Or throw?
    }
    try {
      $this.MessageReaderQueue.Add($message, $cancellationToken)
      $this.Logger.LogTrace("Message added to internal reader queue.")
    } catch [OperationCanceledException] {
      $this.Logger.LogWarning("Cancellation occurred while adding message to queue.")
      throw # Rethrow cancellation
    } catch [InvalidOperationException] {
      # Catch if CompleteAdding was called concurrently
      $this.Logger.LogWarning("Attempted to add message after reader queue was completed (race condition).")
    }

    return [Job]::CompletedTask # Simulate async add for consistency
  }
}

# Represents the dictionary of request handlers mapping method name to scriptblock
class McpRequestHandlers : Dictionary[string, scriptblock] {
  # C# Set<TRequest, TResponse> method handles deserialization.
  # PowerShell needs manual deserialization within the handler scriptblock.
  # Example: $Params = [JsonSerializer]::Deserialize($Request.Params, [McpMyRequestParams], $JsonOptions)
  [void] Set([string]$method, [scriptblock]$handler) {
    if ([string]::IsNullOrWhiteSpace($method)) { throw [ArgumentNullException]::new('method') }
    if ($null -eq $handler) { throw [ArgumentNullException]::new('handler') }
    $this[$method] = $handler
  }
}

# Represents multiple handlers per notification method
class McpNotificationHandlers : Dictionary[string, List[scriptblock]] {
  [void] Add([string]$method, [scriptblock]$handler) {
    if ([string]::IsNullOrWhiteSpace($method)) { throw [ArgumentNullException]::new('method') }
    if ($null -eq $handler) { throw [ArgumentNullException]::new('handler') }

    if (!$this.ContainsKey($method)) {
      $this[$method] = [List[scriptblock]]::new()
    }
    # Need locking if accessed concurrently? PowerShell dictionaries aren't thread-safe.
    # For simplicity, assume single-threaded configuration or external locking.
    $this[$method].Add($handler)
  }
}

# .EXAMPLE
#   # Create transport and session
#   $transport = [StdioClientTransport]::new($serverParams)
#   $session = [McpSession]::new($transport)

#   # Register notification handler
#   $session.RegisterNotificationHandler({
#       param($notification)
#       Write-Host "Received notification: $($notification.method)"
#   })

#   # Send request
#   $request = [JSONRPCRequest]::new("2.0", "listTools", "123", $null)
#   $response = $session.SendRequest($request)
#   Write-Host "Response received: $($response | ConvertTo-Json)"

#   # Send notification
#   $notification = [JSONRPCNotification]::new("2.0", "logEvent", @{message = "Client connected"})
#   $session.SendNotification($notification)

#   # Close gracefully
#   $session.CloseGracefully()
class McpSession : IDisposable {
  hidden [McpTransport]$_transport
  hidden [McpRequestHandlers]$_requestHandlers
  hidden [McpNotificationHandlers]$_notificationHandlers
  hidden [ILogger]$_logger
  hidden [ConcurrentDictionary[McpRequestId, List[McpIJsonRpcMessage]]]$_pendingRequests
  hidden [int]$_nextRequestId = 0

  [string] $EndpointName

  McpSession(
    [McpTransport]$transport,
    [string]$endpointName,
    [McpRequestHandlers]$requestHandlers,
    [McpNotificationHandlers]$notificationHandlers,
    [ILogger]$logger
  ) {
    if ($null -eq $transport) { throw [ArgumentNullException]::new("transport") }
    if ([string]::IsNullOrWhiteSpace($endpointName)) { throw [ArgumentNullException]::new("endpointName") }
    if ($null -eq $requestHandlers) { throw [ArgumentNullException]::new("requestHandlers") }
    if ($null -eq $notificationHandlers) { throw [ArgumentNullException]::new("notificationHandlers") }

    $this._transport = $transport
    $this.EndpointName = $endpointName
    $this._requestHandlers = $requestHandlers
    $this._notificationHandlers = $notificationHandlers
    $this._logger = $logger ?? [NullLogger]::Instance
    # Use an appropriate comparer for McpRequestId if needed (e.g., based on its ToString or Value)
    # For simplicity, relying on default object equality comparer wrapped by ConcurrentDictionary
    $this._pendingRequests = [ConcurrentDictionary[McpRequestId, List[McpIJsonRpcMessage]]]::new()
  }

  [Job] ProcessMessagesAsync([CancellationToken]$cancellationToken) {
    $tcs = [List[bool]]::new()
    $this._logger.LogTrace("Starting message processing loop for $($this.EndpointName)")

    $loopTask = [Job]::Run([Action] {
        try {
          foreach ($message in $this._transport.MessageReaderQueue.GetConsumingEnumerable($cancellationToken)) {
            $this._logger.LogTrace("Processing message type $($message.GetType().Name) for $($this.EndpointName)")
            # Process synchronously within this loop for simplicity now, can offload if handlers are slow
            try {
              $this.HandleMessageAsync($message, $cancellationToken).GetAwaiter().GetResult() # Blocking wait
            } catch {
              $jsonPayload = try { [JsonSerializer]::Serialize($message, ([object]$message).GetType(), [McpJsonUtilities]::DefaultOptions) } catch { "(serialization failed)" }
              $this._logger.LogError("Error handling message type $($message.GetType().Name) payload $jsonPayload : $($_.Exception.Message)")
            }
          }
          $this._logger.LogInformation("Message processing loop completed for $($this.EndpointName).")
          $tcs.TrySetResult($true)
        } catch [OperationCanceledException] {
          $this.Logger.LogInformation("Message processing loop cancelled for $($this.EndpointName).")
          $tcs.TrySetCanceled($cancellationToken)
        } catch [InvalidOperationException] {
          $this.Logger.LogInformation("Message queue completed for $($this.EndpointName).")
          $tcs.TrySetResult($true)
        } catch {
          $this.Logger.LogError("Exception in message processing loop for $($this.EndpointName): $($_.Exception.Message)")
          $tcs.TrySetException($_.Exception)
        }
      }, [CancellationToken]::None) # Run loop independently

    return $tcs.Task
  }

  hidden [Job] HandleMessageAsync([McpIJsonRpcMessage]$message, [CancellationToken]$cancellationToken) {
    $tcs = [List[bool]]::new()
    try {
      switch ($message) {
        { $_ -is [McpJsonRpcRequest] } { $this.HandleRequestAsync($message, $cancellationToken).GetAwaiter().GetResult() }
        { $_ -is [McpJsonRpcResponse] -or $_ -is [McpJsonRpcError] } { $this.HandleResponseOrError($message) }
        { $_ -is [McpJsonRpcNotification] } { $this.HandleNotificationAsync($message, $cancellationToken).GetAwaiter().GetResult() }
        default { $this._logger.LogWarning("Unhandled msg type: $($message.GetType().Name)") }
      }
      $tcs.SetResult($true)
    } catch { $this._logger.LogError("Error handling msg: $($_.Exception.Message)"); $tcs.SetException($_.Exception) }
    return $tcs.Task
  }


  hidden [Job] HandleRequestAsync([McpJsonRpcRequest]$request, [CancellationToken]$cancellationToken) {
    $handler = $null
    if (!$this._requestHandlers.TryGetValue($request.Method, [ref]$handler)) {
      $this._logger.LogWarning("No handler for '$($request.Method)'")
      $errRsp = [McpJsonRpcError]@{Id = $request.Id; Error = [McpJsonRpcErrorDetail]@{Code = [McpErrorCodes]::MethodNotFound; Message = "NotFound:" + $request.Method } }
      $sendErrorTask = $this._transport.SendMessageAsync($errRsp, [CancellationToken]::None) # Send error without token? Or use original? None safer.
      return $sendErrorTask.ContinueWith({ param($t) if ($t.IsFaulted) { $this.Logger.LogError("Failed sending MethodNotFound") } }) # Return task representing send attempt
    }

    $this._logger.LogTrace("Invoking handler for '$($request.Method)'")
    $handlerTcs = [List[object]]::new([TaskCreationOptions]::RunContinuationsAsynchronously)

    # Run the potentially long-running handler in a background task
    [Job]::Run({
        param($hndlr, $reqArg, $ctArg)
        try {
          $resultTask = . $hndlr $reqArg $ctArg
          if ($resultTask -isnot [Job]) { throw [InvalidOperationException]("Handler didn't return Task") }
          # Wait for handler task and get result
          $resultTask.Wait($ctArg)
          $handlerTcs.TrySetResult($resultTask.Result) | Out-Null
        } catch {
          $handlerTcs.TrySetException($_.Exception) | Out-Null
        }
      }, $cancellationToken, $handler, $request, $cancellationToken) | Out-Null


    # Continue after the handler task completes (success or failure)
    return $handlerTcs.Task.ContinueWith({
        param($handlerTask)
        $responseToSend = $null
        if ($handlerTask.IsFaulted) {
          $ex = $handlerTask.Exception.Flatten().InnerExceptions[0]
          $this.Logger.LogError("Handler for '$($request.Method)' failed: $($ex.Message)")
          $responseToSend = [McpJsonRpcError]@{ Id = $request.Id; Error = [McpJsonRpcErrorDetail]@{Code = [McpErrorCodes]::ServerError; Message = $ex.Message } }
        } elseif ($handlerTask.IsCanceled) {
          $this.Logger.LogWarning("Handler for '$($request.Method)' cancelled.")
          # Sending an error for cancellation might reveal too much, maybe just don't respond?
          # Or send specific cancellation error code? JSON-RPC spec doesn't define one. Use ServerError.
          $responseToSend = [McpJsonRpcError]@{ Id = $request.Id; Error = [McpJsonRpcErrorDetail]@{Code = [McpErrorCodes]::ServerError; Message = "Request cancelled" } }
        } else {
          $this.Logger.LogTrace("Handler for '$($request.Method)' completed.")
          $responseToSend = [McpJsonRpcResponse]@{ Id = $request.Id; Result = $handlerTask.Result }
        }

        # Send the response/error (use CancellationToken.None for sending response as original request might be cancelled)
        return $this._transport.SendMessageAsync($responseToSend, [CancellationToken]::None)
      }, [CancellationToken]::None).Unwrap() # Unwrap Task<Task> from SendMessageAsync
  }


  hidden HandleResponseOrError([McpIJsonRpcMessage]$message) {
    $messageWithId = $message -as [McpIJsonRpcMessageWithId]
    if ($null -eq $messageWithId -or !$messageWithId.Id.IsValid()) { $this._logger.LogWarning('Invalid resp/err ID'); return }
    $tcs = $null
    if ($this._pendingRequests.TryRemove($messageWithId.Id, [ref]$tcs)) {
      $idStr = $messageWithId.Id.ToString()
      $this._logger.LogTrace("Matching resp/err for ID '$idStr'")
      if ($message -is [McpJsonRpcError]) {
        $err = $message.Error; $this._logger.LogWarning("Err Resp ID '$idStr': Code $($err.Code) - $($err.Message)")
        $ex = [McpClientException]::new("Peer err: $($err.Message)", $err.Code)
        $tcs.TrySetException($ex) | Out-Null
      } else { $this._logger.LogTrace("Success Resp ID '$idStr'"); $tcs.TrySetResult($message) | Out-Null }
    } else { $this._logger.LogWarning("Resp/err for unknown ID '$($messageWithId.Id)'") }
  }

  hidden [Job] HandleNotificationAsync([McpJsonRpcNotification]$notification, [CancellationToken]$cancellationToken) {
    $handlers = $null
    if (!$this._notificationHandlers.TryGetValue($notification.Method, [ref]$handlers)) {
      $this._logger.LogTrace("No handler for notification '$($notification.Method)'")
      return [Job]::CompletedTask
    }

    $this._logger.LogTrace("Found $($handlers.Count) handlers for '$($notification.Method)'")
    $handlerTasks = [List[Job]]::new()
    foreach ($handler in $handlers) {
      $ht = [Job]::Run({
          param($h, $n, $ct)
          try { . $h $n $ct } catch { $this.Logger.LogError("Notif handler err '$($n.Method)': $($_.Exception.Message)") }
        }, $cancellationToken, $handler, $notification, $cancellationToken)
      $handlerTasks.Add($ht)
    }
    return [Job]::WhenAll($handlerTasks) # Return task that completes when all handlers finish
  }

  [List[object]] SendRequestAsync([McpJsonRpcRequest]$request, [Type]$expectedResultType, [CancellationToken]$cancellationToken) {
    if (!$this._transport.IsConnected) { throw [McpClientException]::new("Not connected") }
    $requestIdNum = [Interlocked]::Increment([ref]$this._nextRequestId)
    $request.Id = [McpRequestId]::FromNumber($requestIdNum)
    $tcs = [List[McpIJsonRpcMessage]]::new([TaskCreationOptions]::RunContinuationsAsynchronously)
    if (!$this._pendingRequests.TryAdd($request.Id, $tcs)) { throw [InvalidOperationException]("ID collision?") }
    $this._logger.LogTrace("Sending req '$($request.Method)' ID '$($request.Id)'")
    $sendTask = $this._transport.SendMessageAsync($request, $cancellationToken)

    $processResponseTask = $tcs.Task.ContinueWith(
      [Func[List[McpIJsonRpcMessage], object]] {
        param($responseTask)
        $rmTcs = $null; $this._pendingRequests.TryRemove($request.Id, [ref]$rmTcs) | Out-Null
        if ($responseTask.IsFaulted) { throw $responseTask.Exception.InnerExceptions[0] }
        if ($responseTask.IsCanceled) { throw [OperationCanceledException]::new($cancellationToken) }
        $rm = $responseTask.Result
        if ($rm -is [McpJsonRpcError]) { $err = $rm.Error; throw [McpClientException]::new("Peer err: $($err.Message)", $err.Code) }
        if ($rm -is [McpJsonRpcResponse]) {
          $sr = $rm; try { if ($null -eq $sr.Result) { return $null }; return [McpJsonUtilities]::DeserializeParams($sr.Result, $expectedResultType) } catch { throw [McpClientException]::new("Fail deserialize to " + $expectedResultType.Name, $_.Exception) }
        } else { throw [McpClientException]::new("Unexpected resp type " + $rm.GetType().Name) }
      }, $cancellationToken
    )

    return $sendTask.ContinueWith({
        param($st)
        if ($st.IsFaulted) { $rmTcs = $null; $this._pendingRequests.TryRemove($request.Id, [ref]$rmTcs) | Out-Null; $rmTcs.TrySetException($st.Exception.InnerExceptions[0]) | Out-Null; throw $st.Exception.InnerExceptions[0] }
        if ($st.IsCanceled) { $rmTcs = $null; $this._pendingRequests.TryRemove($request.Id, [ref]$rmTcs) | Out-Null; $rmTcs.TrySetCanceled($cancellationToken) | Out-Null; throw [OperationCanceledException]::new($cancellationToken) }
        return $processResponseTask
      }, $cancellationToken
    ).Unwrap()
  }

  [Job] SendMessageAsync([McpIJsonRpcMessage]$message, [CancellationToken]$cancellationToken = [CancellationToken]::None) {
    return $this._transport.SendMessageAsync($message, $cancellationToken)
  }

  [void] Dispose() {
    $this._logger.LogTrace("Disposing McpSession ($($this.EndpointName)). Cancelling pending.")
    # Use Keys property and TryRemove for potentially better concurrent safety
    $keys = $this._pendingRequests.Keys
    foreach ($key in $keys) {
      $removedTcs = $null
      if ($this._pendingRequests.TryRemove($key, [ref]$removedTcs)) {
        $removedTcs.TrySetCanceled() | Out-Null
      }
    }
  }
}

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

        while (!$cts.Token.IsCancellationRequested) {
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


#<+++++++++++>
class McpCapabilityBase { [bool]$ListChanged }
class McpRootsCapability : McpCapabilityBase {}
class McpSamplingCapability : McpRootsCapability {}
class McpLoggingCapability : McpSamplingCapability {}

class McpPromptsCapability {  }
class McpResourcesCapability { [bool]$ListChanged; [bool]$Subscribe }
class McpToolsCapability { [bool]$ListChanged }

class McpClientCapabilities {
  [Dictionary[string, object]]$Experimental
  [McpRootsCapability]$Roots = [McpRootsCapability]::new() # Instantiate
  [McpSamplingCapability]$Sampling = [McpSamplingCapability]::new() # Instantiate
}
class McpServerCapabilities {
  [Dictionary[string, object]]$Experimental
  [McpLoggingCapability]$Logging = [McpLoggingCapability]::new()
  [McpPromptsCapability]$Prompts = [McpPromptsCapability]::new()
  [McpResourcesCapability]$Resources = [McpResourcesCapability]::new()
  [McpToolsCapability]$Tools = [McpToolsCapability]::new()
}



#endregion

#region Core Logic (Transport, Endpoint, Session)


# Refactored Session/Endpoint Logic (Combined for simplicity)
class McpEndpoint : IDisposable {
  hidden [McpTransport]$_transport
  hidden [McpLogger]$_logger
  hidden [string]$_endpointName # For logging
  hidden [ConcurrentDictionary[string, List[object]]]$_pendingRequests # Key by RequestId.ToString()
  hidden [int]$_nextRequestId = 0
  hidden [Job]$_messageProcessingJob # PowerShell Job for background processing
  hidden [CancellationTokenSource]$_endpointCts # Controls lifetime

  # Handlers
  hidden [hashtable]$_requestHandlers = @{} # Method -> ScriptBlock(request, cancellationToken) -> Task<object>
  hidden [hashtable]$_notificationHandlers = @{} # Method -> List<ScriptBlock(notification)>

  [bool]$IsConnected = $false

  McpEndpoint([McpTransport]$transport, [string]$endpointName, [McpLogger]$logger) {
    if ($null -eq $transport) { throw [ArgumentNullException]::new("transport") }
    $this._transport = $transport
    $this._endpointName = $endpointName ?? "Unnamed MCP Endpoint"
    $this._logger = $logger ?? [McpNullLogger]::Instance()
    $this._pendingRequests = [ConcurrentDictionary[string, List[object]]]::new()
    $this._endpointCts = [CancellationTokenSource]::new()
  }

  [string] EndpointName() { return $this._endpointName } # Read-only property

  [void] SetRequestHandler([string]$method, [scriptblock]$handler) {
    if ([string]::IsNullOrWhiteSpace($method)) { throw [ArgumentNullException]::new('method') }
    if ($null -eq $handler) { throw [ArgumentNullException]::new('handler') }
    $this._requestHandlers[$method] = $handler
    $this._logger.Log([McpLoggingLevel]::Debug, "Registered request handler for '$method' on $($this._endpointName)")
  }

  [void] AddNotificationHandler([string]$method, [scriptblock]$handler) {
    if ([string]::IsNullOrWhiteSpace($method)) { throw [ArgumentNullException]::new('method') }
    if ($null -eq $handler) { throw [ArgumentNullException]::new('handler') }
    if (!$this._notificationHandlers.ContainsKey($method)) {
      $this._notificationHandlers[$method] = [List[scriptblock]]::new()
    }
    $this._notificationHandlers[$method].Add($handler)
    $this._logger.Log([McpLoggingLevel]::Debug, "Added notification handler for '$method' on $($this._endpointName)")
  }

  [void] StartProcessing() {
    if ($null -ne $this._messageProcessingJob) {
      $this._logger.Log([McpLoggingLevel]::Warning, "Message processing already started for $($this._endpointName)")
      return
    }
    if (!$this._transport.IsConnected) {
      throw [InvalidOperationException]::new("Cannot start processing, transport is not connected.")
    }

    $this._logger.Log([McpLoggingLevel]::Information, "Starting message processing job for $($this._endpointName)")

    # ScriptBlock for the background job
    $jobScriptBlock = {
      param(
        $transport, # McpTransport
        $endpointCtsToken, # CancellationToken
        $logger, # McpLogger
        $endpointName,
        $requestHandlers, # Hashtable
        $notificationHandlers, # Hashtable
        $pendingRequests # ConcurrentDictionary
      )

      $ErrorActionPreference = 'Stop' # Make job scriptblock exit on terminating errors

      $logger.Log([McpLoggingLevel]::Information, "Message processing job started for $endpointName")
      try {
        # Consume messages from the transport's queue
        foreach ($message in $transport.MessageReaderQueue.GetConsumingEnumerable($endpointCtsToken)) {
          $logger.Log([McpLoggingLevel]::Debug, "Job processing message type $($message.GetType().Name) for $endpointName")

          try {
            # Determine message type and handle
            if ($message -is [McpJsonRpcRequest]) {
              $request = $message
              $handler = $requestHandlers[$request.Method]
              if ($null -ne $handler) {
                $logger.Log([McpLoggingLevel]::Trace, "Job invoking request handler for '$($request.Method)'")
                try {
                  # Handlers MUST return a Task<object>
                  $handlerTask = . $handler $request $endpointCtsToken
                  # Wait for handler to complete *synchronously within the job* for simplicity
                  # More complex scenarios might require managing these tasks differently
                  $handlerTask.Wait($endpointCtsToken) # Blocking wait
                  $result = $handlerTask.Result
                  $response = [McpJsonRpcResponse]@{ Id = $request.Id; Result = $result }
                  $logger.Log([McpLoggingLevel]::Trace, "Job sending success response for ID '$($request.Id)'")
                  $transport.SendMessage($response)
                } catch [OperationCanceledException] {
                  $logger.Log([McpLoggingLevel]::Warning, "Job handler for '$($request.Method)' cancelled.")
                  $errorResponse = [McpJsonRpcError]@{ Id = $request.Id; Error = [McpJsonRpcErrorDetail]@{ Code = [McpErrorCodes]::ServerError; Message = "Request cancelled by server" } }
                  $transport.SendMessage($errorResponse)
                } catch {
                  $errMsg = $_.Exception.Message
                  $logger.Log([McpLoggingLevel]::Error, "Job handler for '$($request.Method)' failed: $errMsg")
                  $errorResponse = [McpJsonRpcError]@{ Id = $request.Id; Error = [McpJsonRpcErrorDetail]@{ Code = [McpErrorCodes]::ServerError; Message = $errMsg } }
                  $transport.SendMessage($errorResponse)
                }
              } else {
                $logger.Log([McpLoggingLevel]::Warning, "Job received request for unknown method '$($request.Method)'")
                $errorResponse = [McpJsonRpcError]@{ Id = $request.Id; Error = [McpJsonRpcErrorDetail]@{ Code = [McpErrorCodes]::MethodNotFound; Message = "Method not found: $($request.Method)" } }
                $transport.SendMessage($errorResponse)
              }
            } elseif (($message -is [McpJsonRpcResponse]) -or ($message -is [McpJsonRpcError])) {
              $messageWithId = $message # Already cast correctly
              $idStr = $messageWithId.Id.ToString()
              $tcs = $null
              if ($pendingRequests.TryRemove($idStr, [ref]$tcs)) {
                if ($message -is [McpJsonRpcError]) {
                  $err = $message.Error
                  $logger.Log([McpLoggingLevel]::Warning, "Job processing error response for ID '$idStr': Code $($err.Code) - $($err.Message)")
                  $ex = [McpClientException]::new("Peer error: $($err.Message)", $err.Code, $err.Data)
                  $tcs.TrySetException($ex) | Out-Null
                } else {
                  $logger.Log([McpLoggingLevel]::Trace, "Job processing success response for ID '$idStr'")
                  $tcs.TrySetResult($message.Result) | Out-Null # Set the Result property
                }
              } else {
                $logger.Log([McpLoggingLevel]::Warning, "Job received response for unknown/cancelled request ID '$idStr'")
              }
            } elseif ($message -is [McpJsonRpcNotification]) {
              $notification = $message
              $handlers = $notificationHandlers[$notification.Method]
              if ($null -ne $handlers) {
                $logger.Log([McpLoggingLevel]::Trace, "Job invoking $($handlers.Count) notification handlers for '$($notification.Method)'")
                foreach ($handler in $handlers) {
                  try {
                    # Invoke handler synchronously within the job
                    . $handler $notification
                  } catch {
                    $logger.Log([McpLoggingLevel]::Error, "Job notification handler for '$($notification.Method)' failed: $($_.Exception.Message)")
                  }
                }
              } else { $logger.Log([McpLoggingLevel]::Trace, "Job - No handler for '$($notification.Method)'") }
            } else {
              $logger.Log([McpLoggingLevel]::Warning, "Job received unhandled message type: $($message.GetType().Name)")
            }
          } catch {
            $logger.Log([McpLoggingLevel]::Error, "Error processing message in job: $($_.Exception.Message)")
            # Decide if the loop should continue or terminate on error
          }
        } # End foreach message
      } catch [OperationCanceledException] {
        $logger.Log([McpLoggingLevel]::Information, "Message processing job cancelled for $endpointName.")
      } catch [InvalidOperationException] {
        $logger.Log([McpLoggingLevel]::Information, "Message processing job queue completed for $endpointName.")
      } catch {
        $logger.Log([McpLoggingLevel]::Critical, "Fatal error in message processing job for $endpointName : $($_.Exception.ToString())")
        # Consider signalling endpoint failure
      } finally {
        $logger.Log([McpLoggingLevel]::Information, "Message processing job finished for $endpointName.")
      }
    } # End Job ScriptBlock

    # Start the job
    $job = Start-ThreadJob -ScriptBlock $jobScriptBlock -ArgumentList @(
      $this._transport,
      $this._endpointCts.Token,
      $this._logger,
      $this._endpointName,
      $this._requestHandlers,
      $this._notificationHandlers,
      $this._pendingRequests
    )
    $this._messageProcessingJob = $job
    $this._logger.Log([McpLoggingLevel]::Information, "Message processing job $($job.Id) started for $($this._endpointName)")

    # Optionally register action for job completion/failure
    Register-ObjectEvent -InputObject $job -EventName StateChanged -Action {
      param($sender, $eventArgs)
      $jobState = $sender.State
      $endpointName = $sender.PSBeginTime # Hack: Pass endpoint name via unused property? Better way needed.
      $logger = $sender.InstanceId # Hack: Pass logger?
      if ($jobState -in 'Failed', 'Stopped', 'Completed') {
        $logger.Log([McpLoggingLevel]::Information, "Message processing job for $endpointName finished with state: $jobState")
        # TODO: Signal endpoint closure or attempt restart?
        Unregister-Event -SourceIdentifier $sender.Name # Clean up event subscription
      }
      if ($jobState -eq 'Failed') {
        $reason = try { $sender.Error[0].Exception.ToString() } catch { "(Failed to get error reason)" }
        $logger.Log([McpLoggingLevel]::Error, "Message processing job for $endpointName failed: $reason")
      }
    } -SourceIdentifier "McpJobCompletion_$($job.InstanceId)" | Out-Null
  }

  [void] StopProcessing() {
    $this._logger.Log([McpLoggingLevel]::Information, "Stopping message processing for $($this._endpointName)")
    if ($null -ne $this._endpointCts) {
      try { $this._endpointCts.Cancel() } catch { $null }
    }
    if ($null -ne $this._messageProcessingJob) {
      try {
        $job = $this._messageProcessingJob
        $this._logger.Log([McpLoggingLevel]::Debug, "Waiting for message processing job $($job.Id) to stop...")
        # Wait for job with timeout
        $job | Wait-Job -Timeout 5 | Out-Null
        if ($job.State -ne 'Stopped' -and $job.State -ne 'Completed' -and $job.State -ne 'Failed') {
          $this._logger.Log([McpLoggingLevel]::Warning, "Message processing job $($job.Id) did not stop gracefully, forcing removal.")
          $job | Remove-Job -Force
        } else {
          $this._logger.Log([McpLoggingLevel]::Debug, "Message processing job $($job.Id) stopped.")
          $job | Remove-Job
        }
      } catch {
        $this._logger.Log([McpLoggingLevel]::Error, "Error stopping/removing message processing job: $($_.Exception.Message)")
      }
      $this._messageProcessingJob = $null
    }
  }

  # Returns a Job object
  [System.Management.Automation.Job] SendRequestAsync([McpJsonRpcRequest]$request, [CancellationToken]$cancellationToken) {
    if (!$this.IsConnected -or $null -eq $this._transport) {
      throw [McpClientException]::new("Cannot send request, endpoint not connected.")
    }

    $requestIdNum = [Interlocked]::Increment([ref]$this._nextRequestId)
    $request.Id = [McpRequestId]::FromNumber($requestIdNum)
    $idStr = $request.Id.ToString()

    $tcs = [List[object]]::new([TaskCreationOptions]::RunContinuationsAsynchronously)
    if (!$this._pendingRequests.TryAdd($idStr, $tcs)) {
      throw [InvalidOperationException]::new("Request ID collision is highly unlikely but occurred: $idStr")
    }
    $this._logger.Log([McpLoggingLevel]::Debug, "Sending request '$($request.Method)' ID '$idStr' via $($this._endpointName)")

    # Use Start-ThreadJob to handle waiting for the TCS in the background
    $job = Start-ThreadJob -Name "McpRequest_$idStr" -ScriptBlock {
      param($tcsToWait, $cancelTokenSourceForJob, $loggerForJob, $idForJob, $pendingReqsForJob, $transportForJob, $reqToSend)
      $ErrorActionPreference = 'Stop'
      try {
        # Send the message *before* starting to wait
        $loggerForJob.Log([McpLoggingLevel]::Trace, "Request Job '$idForJob': Sending message...")
        $transportForJob.SendMessage($reqToSend) # Synchronous send
        $loggerForJob.Log([McpLoggingLevel]::Trace, "Request Job '$idForJob': Message sent. Waiting for response...")

        # Wait on the TaskCompletionSource's task
        # Combine with cancellation token
        $combinedCts = [CancellationTokenSource]::CreateLinkedTokenSource($cancelTokenSourceForJob.Token)
        $waitTask = $tcsToWait.Task
        $delayTask = [Job]::Delay(-1, $combinedCts.Token) # Infinite delay task cancellable by combined token

        $completed = [Job]::WhenAny($waitTask, $delayTask).GetAwaiter().GetResult()

        if ($completed -ne $waitTask) {
          # Cancellation happened
          $loggerForJob.Log([McpLoggingLevel]::Warning, "Request Job '$idForJob': Wait cancelled.")
          throw [OperationCanceledException]::new($cancelTokenSourceForJob.Token)
        }

        # Task completed, check for exceptions
        if ($waitTask.IsFaulted) {
          $loggerForJob.Log([McpLoggingLevel]::Error, "Request Job '$idForJob': Response indicates error.")
          throw $waitTask.Exception.InnerExceptions[0] # Throw the exception set by the processing loop
        }

        # Success, return the result
        $loggerForJob.Log([McpLoggingLevel]::Trace, "Request Job '$idForJob': Response received successfully.")
        return $waitTask.Result # Return the result set by the processing loop
      } catch [OperationCanceledException] {
        $loggerForJob.Log([McpLoggingLevel]::Warning, "Request Job '$idForJob' was cancelled.")
        throw # Rethrow cancellation
      } catch {
        $loggerForJob.Log([McpLoggingLevel]::Error, "Request Job '$idForJob' failed: $($_.Exception.Message)")
        throw # Rethrow other exceptions
      } finally {
        # Ensure request is removed from pending dictionary if job fails/cancels before TCS completes
        $removedTcs = $null
        $pendingReqsForJob.TryRemove($idForJob, [ref]$removedTcs) | Out-Null
        # Clean up linked CTS if created
        if ($null -ne $combinedCts) { $combinedCts.Dispose() }
      }
    } -ArgumentList @(
      $tcs, # TaskCompletionSource to wait on
      $cancellationToken, # CancellationToken for the wait
      $this._logger, # Logger
      $idStr, # Request ID string for logging
      $this._pendingRequests, # Pending requests dictionary
      $this._transport, # Transport to send message
      $request                # The request message itself
    )

    # Return the job object to the caller
    return $job
  }

  [void] SendNotificationAsync([McpJsonRpcNotification]$notification, [CancellationToken]$cancellationToken) {
    if (!$this.IsConnected -or $null -eq $this._transport) {
      throw [McpClientException]::new("Cannot send notification, endpoint not connected.")
    }
    $this._logger.Log([McpLoggingLevel]::Debug, "Sending notification '$($notification.Method)' via $($this._endpointName)")
    $this._transport.SendMessage($notification) # Fire and forget or handle potential transport exception?
  }


  [void] Dispose() {
    $this._logger.Log([McpLoggingLevel]::Information, "Disposing McpEndpoint: $($this._endpointName)")

    # Stop processing loop first
    $this.StopProcessing()

    # Cancel any pending requests forcefully
    $keys = $this._pendingRequests.Keys
    $this._logger.Log([McpLoggingLevel]::Debug, "Cancelling $($keys.Count) pending requests for $($this._endpointName)...")
    foreach ($key in $keys) {
      $tcs = $null
      if ($this._pendingRequests.TryRemove($key, [ref]$tcs)) {
        $tcs.TrySetCanceled() | Out-Null
      }
    }
    $this._pendingRequests.Clear()

    # Dispose transport
    if ($null -ne $this._transport) {
      try { $this._transport.Dispose() } catch { $this._logger.Log([McpLoggingLevel]::Error, "Error disposing transport: $($_.Exception.Message)") }
      $this._transport = $null
    }

    # Dispose CTS
    if ($null -ne $this._endpointCts) {
      try { $this._endpointCts.Dispose() } catch { $null }
      $this._endpointCts = $null
    }

    $this.IsConnected = $false
    $this._logger.Log([McpLoggingLevel]::Information, "McpEndpoint disposed: $($this._endpointName)")
  }
}

#endregion

#region Transport Implementations (Stdio Example)

class McpStdioTransport : McpTransport {
  hidden [McpLogger]$_logger
  hidden [string]$_command
  hidden [string]$_arguments
  hidden [string]$_workingDirectory
  hidden [hashtable]$_environmentVariables
  hidden [Process]$_process
  hidden [bool]$_processStarted = $false
  hidden [DataReceivedEventHandler]$_stdoutHandler
  hidden [DataReceivedEventHandler]$_stderrHandler
  hidden [Job]$_stdoutJob # Job for reading stdout
  hidden [CancellationTokenSource]$_receiveCts # Controls the reading

  McpStdioTransport(
    [string]$command,
    [string]$arguments,
    [string]$workingDirectory,
    [hashtable]$environmentVariables,
    [McpLogger]$logger
  ) : base($logger) {
    $this._logger = $logger ?? [McpNullLogger]::Instance()
    $this._command = $command
    $this._arguments = $arguments
    $this._workingDirectory = $workingDirectory
    $this._environmentVariables = $environmentVariables
    $this._receiveCts = [CancellationTokenSource]::new()
  }

  [void] Connect() {
    if ($this.IsConnected) {
      $this._logger.Log([McpLoggingLevel]::Warning, "StdioTransport already connected.")
      return
    }
    $this._logger.Log([McpLoggingLevel]::Information, "Connecting StdioTransport...")
    try {
      $startInfo = [ProcessStartInfo]@{
        FileName               = $this._command
        Arguments              = $this._arguments
        RedirectStandardInput  = $true
        RedirectStandardOutput = $true
        RedirectStandardError  = $true
        UseShellExecute        = $false
        CreateNoWindow         = $true
        WorkingDirectory       = $this._workingDirectory ?? $PWD.Path
        StandardOutputEncoding = [UTF8Encoding]::new($false)
        StandardErrorEncoding  = [UTF8Encoding]::new($false)
        # TODO: InputEncoding needs Framework/Core check or Console manipulation
      }
      if ($null -ne $this._environmentVariables) {
        $startInfo.EnvironmentVariables = $this._environmentVariables # PS handles hashtable directly
      }

      $this._process = [Process]::new()
      $this._process.StartInfo = $startInfo

      # Stderr Handler
      $this._stderrHandler = [DataReceivedEventHandler] {
        param($sender, $e)
        if ($null -ne $e.Data) { $this.Logger.Log([McpLoggingLevel]::Error, "[STDERR] $($e.Data)") }
      }.GetNewClosure() # Capture $this (logger)
      $this._process.add_ErrorDataReceived($this._stderrHandler)

      $this._logger.Log([McpLoggingLevel]::Information, "Starting process: $($startInfo.FileName) $($startInfo.Arguments)")
      $this._processStarted = $this._process.Start()

      if (!$this._processStarted) { throw [McpTransportException]::new("Failed to start process.") }

      $this._process.BeginErrorReadLine()
      $this.IsConnected = $true
      $this._logger.Log([McpLoggingLevel]::Information, "Stdio process started (PID: $($this._process.Id)).")

    } catch {
      $this._logger.Log([McpLoggingLevel]::Critical, "Failed to start stdio process: $($_.Exception.Message)")
      $this.Dispose() # Cleanup on failure
      throw [McpTransportException]::new("Failed to connect stdio transport.", $_.Exception)
    }
  }

  [void] SendMessage([McpIJsonRpcMessage]$message) {
    if (!$this.IsConnected -or $null -eq $this._process -or $this._process.HasExited) {
      throw [McpTransportException]::new("Cannot send message, stdio transport not connected or process exited.")
    }
    try {
      $json = [McpJsonUtilities]::Serialize($message)
      $this._logger.Log([McpLoggingLevel]::Debug, "[STDOUT] >> $json")
      # WriteLine is synchronous here, Flush ensures it's sent
      $this._process.StandardInput.WriteLine($json)
      $this._process.StandardInput.Flush()
    } catch {
      $this._logger.Log([McpLoggingLevel]::Error, "Failed to send message via stdio: $($_.Exception.Message)")
      # Consider closing connection?
      throw [McpTransportException]::new("Failed to send message via stdio.", $_.Exception)
    }
  }

  [void] StartReceiving([ScriptBlock]$onMessageReceived) {
    if (!$this.IsConnected -or $null -eq $this._process) {
      throw [InvalidOperationException]::new("Cannot start receiving, transport not connected.")
    }
    if ($null -ne $this._stdoutJob) {
      $this._logger.Log([McpLoggingLevel]::Warning, "Stdio receiving already started.")
      return
    }

    $this._logger.Log([McpLoggingLevel]::Information, "Starting stdio stdout reading job.")
    $jobScript = {
      param($stdOutReader, $receiveCtsToken, $onMessageScript, $loggerForJob)
      $ErrorActionPreference = 'Continue' # Don't stop job on deserialization error
      $loggerForJob.Log([McpLoggingLevel]::Debug, "Stdout reading job started.")
      try {
        while (!$receiveCtsToken.IsCancellationRequested) {
          $line = $null
          # ReadLine is blocking, need cancellation check
          # This is tricky without true async read + cancellation
          # Check token BEFORE blocking read attempt
          if ($receiveCtsToken.IsCancellationRequested) { break }
          # Use ReadLineAsync + Wait with timeout for pseudo-cancellation check
          $readTask = $stdOutReader.ReadLineAsync()
          if ($readTask.Wait(100, $receiveCtsToken)) {
            # Wait 100ms
            $line = $readTask.Result
          } else {
            # Timeout or cancellation during wait
            if ($receiveCtsToken.IsCancellationRequested) { break }
            continue # Timeout, loop again to check token
          }

          if ($null -eq $line) {
            $loggerForJob.Log([McpLoggingLevel]::Information, "Stdio stdout stream ended.")
            break # EOF
          }
          if ([string]::IsNullOrWhiteSpace($line)) { continue }

          $loggerForJob.Log([McpLoggingLevel]::Debug, "[STDIN] << $line")
          try {
            $message = [McpJsonUtilities]::Deserialize[McpIJsonRpcMessage]($line)
            # Invoke the callback to queue the message
            . $onMessageScript $message
          } catch {
            $loggerForJob.Log([McpLoggingLevel]::Error, "Failed to process stdio line: '$line'. Error: $($_.Exception.Message)")
          }
        }
      } catch [OperationCanceledException] {
        $loggerForJob.Log([McpLoggingLevel]::Information, "Stdout reading job cancelled.")
      } catch {
        $loggerForJob.Log([McpLoggingLevel]::Error, "Error in stdout reading job: $($_.Exception.ToString())")
      } finally {
        $loggerForJob.Log([McpLoggingLevel]::Information, "Stdout reading job finished.")
      }
    }

    $this._stdoutJob = Start-ThreadJob -ScriptBlock $jobScript -ArgumentList @(
      $this._process.StandardOutput,
      $this._receiveCts.Token,
      $onMessageReceived, # Scriptblock to call McpEndpoint.ReceiveMessage
      $this._logger
    )
  }

  [void] StopReceiving() {
    $this._logger.Log([McpLoggingLevel]::Information, "Stopping stdio receiving...")
    if ($null -ne $this._receiveCts) {
      try { $this._receiveCts.Cancel() } catch { $null }
    }
    $job = $this._stdoutJob
    if ($null -ne $job) {
      try {
        $this._logger.Log([McpLoggingLevel]::Debug, "Waiting for stdout job $($job.Id) to stop...")
        $job | Wait-Job -Timeout 3 | Out-Null
        if ($job.State -ne 'Stopped' -and $job.State -ne 'Completed' -and $job.State -ne 'Failed') {
          $this._logger.Log([McpLoggingLevel]::Warning, "Stdout job $($job.Id) did not stop gracefully, forcing removal.")
          $job | Remove-Job -Force
        } else {
          $this._logger.Log([McpLoggingLevel]::Debug, "Stdout job $($job.Id) stopped.")
          $job | Remove-Job
        }
      } catch {
        $this._logger.Log([McpLoggingLevel]::Error, "Error stopping/removing stdout job: $($_.Exception.Message)")
      }
      $this._stdoutJob = $null
    }
  }

  [void] Dispose() {
    $this._logger.Log([McpLoggingLevel]::Information, "Disposing StdioTransport...")
    # Call base dispose first to stop reader queue etc.
    # Now cleanup process
    $proc = $this._process
    $this._process = $null # Avoid race conditions

    if ($null -ne $proc -and $this._processStarted) {
      # Remove event handler (tricky in PS, may need reflection or ignore)
      # try { $proc.remove_ErrorDataReceived($this._stderrHandler) } catch { $null }

      if (!$proc.HasExited) {
        $this.Logger.Log([McpLoggingLevel]::Information, "Killing stdio process $($proc.Id)...")
        try {
          # Add KillTree logic here if needed/ported
          $proc.Kill($true) # Kill process tree if possible
          $proc.WaitForExit(3000) # Wait briefly
        } catch {
          $this.Logger.Log([McpLoggingLevel]::Error, "Error killing stdio process: $($_.Exception.Message)")
        }
      }
      try { $proc.Dispose() } catch { $null }
    }
    if ($null -ne $this._receiveCts) {
      try { $this._receiveCts.Dispose() } catch { $null }
      $this._receiveCts = $null
    }
    $this._logger.Log([McpLoggingLevel]::Information, "StdioTransport disposed.")
  }
}

#endregion

#region Client/Server Public API

class McpClient : IDisposable {
  hidden [McpEndpoint] $_endpoint
  hidden [McpClientOptions] $_options
  hidden [McpServerConfig] $_serverConfig

  # Public Properties (Read-only via PsScriptProperty)
  hidden [McpServerCapabilities] $_ServerCapabilities
  hidden [McpImplementation] $_ServerInfo
  hidden [string] $_ServerInstructions

  # Constructor is internal, use New-McpClient function
  McpClient([McpEndpoint]$endpoint, [McpClientOptions]$options, [McpServerConfig]$serverConfig) {
    if ($null -eq $endpoint) { throw [ArgumentNullException]::new("endpoint") }
    $this._endpoint = $endpoint
    $this._options = $options
    $this._serverConfig = $serverConfig

    # Setup read-only properties
    $this.PsObject.Properties.Add([psscriptproperty]::new("ServerCapabilities", { return $this._ServerCapabilities }))
    $this.PsObject.Properties.Add([psscriptproperty]::new("ServerInfo", { return $this._ServerInfo }))
    $this.PsObject.Properties.Add([psscriptproperty]::new("ServerInstructions", { return $this._ServerInstructions }))
    $this.PsObject.Properties.Add([psscriptproperty]::new("IsConnected", { return $this._endpoint.IsConnected }))

  }

  # Internal method to update properties after initialization
  hidden SetServerInfo([McpInitializeResult]$initResult) {
    $this._ServerCapabilities = $initResult.Capabilities
    $this._ServerInfo = $initResult.ServerInfo
    $this._ServerInstructions = $initResult.Instructions
  }

  # Public Methods (wrapping endpoint SendRequestAsync)

  # AddNotificationHandler delegates to endpoint
  [void] AddNotificationHandler([string]$method, [scriptblock]$handler) {
    $this._endpoint.AddNotificationHandler($method, $handler)
  }

  # Returns a Job
  [System.Management.Automation.Job] SendRequestAsync([McpJsonRpcRequest]$request, [CancellationToken]$cancellationToken) {
    return $this._endpoint.SendRequestAsync($request, $cancellationToken)
  }

  [void] SendNotificationAsync([McpJsonRpcNotification]$notification, [CancellationToken]$cancellationToken) {
    $this._endpoint.SendNotificationAsync($notification, $cancellationToken)
  }

  # --- Simplified Client API Methods ---

  [System.Management.Automation.Job] PingAsync([CancellationToken]$cancellationToken) {
    $request = [McpJsonRpcRequest]@{ Method = "ping" }
    # PingResult is empty, expect McpPingResult type
    return $this.SendRequestAsync($request, $cancellationToken)
  }

  # ListTools needs to handle pagination and return Job containing List<McpClientTool>
  [System.Management.Automation.Job] ListToolsAsync([CancellationToken]$cancellationToken) {
    $job = Start-ThreadJob -Name "McpListTools" -ScriptBlock {
      param($mcpClientRef, $cancelToken) # Pass client by reference? Or just invoke methods?
      $ErrorActionPreference = 'Stop'
      $allTools = [List[McpClientTool]]::new()
      $cursor = $null
      do {
        $pageParams = if ($cursor) { @{ cursor = $cursor } } else { $null }
        $pageRequest = [McpJsonRpcRequest]@{ Method = "tools/list"; Params = $pageParams }

        # Invoke SendRequestAsync and wait for the inner job
        $innerJob = $mcpClientRef.SendRequestAsync($pageRequest, $cancelToken)
        $innerJob | Wait-Job -CancellationToken $cancelToken
        if ($innerJob.State -eq 'Failed') { throw $innerJob.Error[0].Exception }
        if ($innerJob.State -eq 'Stopped') { throw [OperationCanceledException]::new($cancelToken) }

        $pageResult = $innerJob | Receive-Job

        # Deserialize result
        $listResult = [McpJsonUtilities]::DeserializeParams($pageResult, [McpListToolsResult])

        if ($null -eq $listResult) { throw [McpClientException]::new("ListTools response was null or invalid.") }

        if ($null -ne $listResult.Tools) {
          $listResult.Tools.ForEach({ param($toolDef) $allTools.Add([McpClientTool]::new($mcpClientRef, $toolDef)) })
        }
        $cursor = $listResult.NextCursor
        $innerJob | Remove-Job

      } while ($null -ne $cursor -and !$cancelToken.IsCancellationRequested)

      return $allTools # Job output
    } -ArgumentList @($this, $cancellationToken) # Pass $this
    return $job
  }

  # CallTool returns a Job containing McpCallToolResponse
  [System.Management.Automation.Job] CallToolAsync([string]$toolName, [hashtable]$arguments, [CancellationToken]$cancellationToken) {
    if ([string]::IsNullOrWhiteSpace($toolName)) { throw [ArgumentNullException]::new("toolName") }
    $params = [McpCallToolRequestParams]@{ Name = $toolName; Arguments = $arguments }
    $request = [McpJsonRpcRequest]@{ Method = "tools/call"; Params = $params }
    $job = $this.SendRequestAsync($request, $cancellationToken)

    # The job returned by SendRequestAsync will contain the raw result object.
    # The caller needs Receive-Job and potentially cast/deserialize to McpCallToolResponse.
    return $job
  }

  # --- Add other methods like ListPromptsAsync, GetPromptAsync etc. following the same pattern ---
  # --- Return a Job, inside the job call SendRequestAsync, Wait-Job, Receive-Job, Deserialize, Return ---

  [void] Dispose() {
    if ($null -ne $this._endpoint) {
      try { $this._endpoint.Dispose() } catch { $null }
      $this._endpoint = $null
    }
  }
}

# Simplified representation for PowerShell
class McpClientTool {
  [string]$Name
  [string]$Description
  [string]$InputSchemaJson # Store as string for simplicity

  hidden [McpClient] $_client # Reference back to the client

  McpClientTool([McpClient]$client, [McpTool]$protocolTool) {
    $this._client = $client
    $this.Name = $protocolTool.Name
    $this.Description = $protocolTool.Description
    $this.InputSchemaJson = try { $protocolTool.InputSchema.GetRawText() } catch { '{}' } # Store schema as string
  }

  # Method to invoke the tool
  [System.Management.Automation.Job] InvokeAsync([hashtable]$arguments, [CancellationToken]$cancellationToken) {
    return $this._client.CallToolAsync($this.Name, $arguments, $cancellationToken)
  }

  [string] ToString() { return "$($this.Name): $($this.Description)" }
}


class McpServer : IDisposable {
  hidden [McpEndpoint] $_endpoint
  hidden [McpServerOptions] $_options
  hidden [McpIServerTransport] $_serverTransport # If listening
  hidden [IDisposable] $_transportToDispose # Hold transport if created internally

  # Public Properties (Read-only via PsScriptProperty)
  hidden [McpClientCapabilities] $_ClientCapabilities
  hidden [McpImplementation] $_ClientInfo

  # Constructor is internal, use Start-McpServer function
  McpServer([McpEndpoint]$endpoint, [McpServerOptions]$options, [McpIServerTransport]$serverTransport = $null, [IDisposable]$transportToDispose = $null) {
    if ($null -eq $endpoint) { throw [ArgumentNullException]::new("endpoint") }
    $this._endpoint = $endpoint
    $this._options = $options
    $this._serverTransport = $serverTransport # Might be null if using pre-connected transport
    $this._transportToDispose = $transportToDispose # Transport owned by the server instance

    # Setup read-only properties
    $this.PsObject.Properties.Add([psscriptproperty]::new("ClientCapabilities", { return $this._ClientCapabilities }))
    $this.PsObject.Properties.Add([psscriptproperty]::new("ClientInfo", { return $this._ClientInfo }))
    $this.PsObject.Properties.Add([psscriptproperty]::new("ServerOptions", { return $this._options })) # Expose options
    $this.PsObject.Properties.Add([psscriptproperty]::new("IsConnected", { return $this._endpoint.IsConnected }))
  }

  # Internal method to update properties after initialization
  hidden SetClientInfo([McpInitializeRequestParams]$initParams) {
    $this._ClientCapabilities = $initParams.Capabilities
    $this._ClientInfo = $initParams.ClientInfo
  }

  # Public Methods (wrapping endpoint)

  [void] AddNotificationHandler([string]$method, [scriptblock]$handler) {
    $this._endpoint.AddNotificationHandler($method, $handler)
  }

  # Use endpoint methods directly for sending
  [System.Management.Automation.Job] SendRequestAsync([McpJsonRpcRequest]$request, [CancellationToken]$cancellationToken) {
    return $this._endpoint.SendRequestAsync($request, $cancellationToken)
  }

  [void] SendNotificationAsync([McpJsonRpcNotification]$notification, [CancellationToken]$cancellationToken) {
    $this._endpoint.SendNotificationAsync($notification, $cancellationToken)
  }

  [void] Start() {
    # Logic to start the server endpoint processing
    if ($this._endpoint.IsConnected) {
      $this._endpoint.StartProcessing()
    } else {
      # Handle case where transport needs connection/acceptance first?
      # This depends on how Start-McpServer structures things.
      throw [InvalidOperationException]::new("Cannot start server endpoint, transport not connected.")
    }
  }

  [void] Stop() {
    # Logic to stop the server endpoint processing
    $this._endpoint.StopProcessing()
  }

  [void] Dispose() {
    if ($null -ne $this._endpoint) {
      try { $this._endpoint.Dispose() } catch { $null }
      $this._endpoint = $null
    }
    # Dispose the transport if we own it
    if ($null -ne $this._transportToDispose) {
      try { $this._transportToDispose.Dispose() } catch { $null }
      $this._transportToDispose = $null
    }
  }
}


class McpServerTool {
  [McpTool] $ProtocolTool # { get; } - The definition sent to the client

  # Abstract method for invocation - Adjusted context type
  [List[McpCallToolResponse]] InvokeAsync([McpRequestContext]$request, [CancellationToken]$cancellationToken) {
    throw [NotImplementedException]::new("InvokeAsync must be implemented by derived tool class.")
  }

  # Factory methods simplified - C# uses complex AIFunction logic
  # PS version might take scriptblocks directly
  static [McpServerTool] CreateFromScriptBlock(
    [string]$name,
    [string]$description,
    [System.Text.Json.JsonElement]$inputSchema,
    [scriptblock]$scriptBlock,
    [McpToolAnnotations]$annotations = $null
    #[McpServerToolCreateOptions]$options = $null # Options contain details like annotations too
  ) {
    $toolDef = [McpTool]@{ Name = $name; Description = $description; InputSchema = $inputSchema; Annotations = $annotations }
    return [McpScriptBlockServerTool]::new($toolDef, $scriptBlock)
  }
}

# Collection to hold server tools
class McpServerToolCollection : ConcurrentDictionary[string, McpServerTool] {
  # Event handling simplified - use Register-ObjectEvent externally if needed
  [scriptblock] $OnChanged # Callback scriptblock

  hidden RaiseChanged() {
    if ($this.OnChanged) {
      try { . $this.OnChanged $this } catch { Write-Warning "Error in ToolCollection.OnChanged handler: $($_.Exception.Message)" }
    }
  }

  [void] AddTool([McpServerTool]$tool) {
    if ($null -eq $tool) { throw [ArgumentNullException]::new("tool") }
    if (!$this.TryAdd($tool.ProtocolTool.Name, $tool)) {
      throw [ArgumentException]::new("Tool with name '$($tool.ProtocolTool.Name)' already exists.")
    }
    $this.RaiseChanged()
  }

  [bool] TryAddTool([McpServerTool]$tool) {
    if ($null -eq $tool) { throw [ArgumentNullException]::new("tool") }
    $added = $this.TryAdd($tool.ProtocolTool.Name, $tool)
    if ($added) { $this.RaiseChanged() }
    return $added
  }

  [bool] RemoveTool([McpServerTool]$tool) {
    if ($null -eq $tool) { throw [ArgumentNullException]::new("tool") }
    $removedTool = $null
    # Use the overload accepting key and returning value via ref
    $removed = $this.TryRemove($tool.ProtocolTool.Name, [ref]$removedTool)

    if ($removed -and $removedTool -ne $tool) {
      # Put it back if it wasn't the instance we intended to remove (unlikely scenario with string keys?)
      $this.TryAdd($removedTool.ProtocolTool.Name, $removedTool) | Out-Null
      $removed = $false # It wasn't the exact tool instance we wanted to remove
    }
    if ($removed) { $this.RaiseChanged() }
    return $removed
  }
  [void] AddOrUpdateTool([McpServerTool]$tool) {
    if ($null -eq $tool) { throw [ArgumentNullException]::new("tool") }
    $this[$tool.ProtocolTool.Name] = $tool
    # Raise event/callback if needed
  }
  [bool] TryGetTool([string]$name, [ref]$tool) {
    $outTool = $null
    $found = $this.TryGetValue($name, [ref]$outTool)
    $tool = $outTool
    return $found
  }
  [bool] ContainsTool([McpServerTool]$tool) {
    if ($null -eq $tool) { throw [ArgumentNullException]::new("tool") }
    $existingTool = $null
    if ($this.TryGetValue($tool.ProtocolTool.Name, [ref]$existingTool)) {
      return $existingTool -eq $tool # Check instance equality
    }
    return $false
  }

  [void] ClearTools() {
    $this.Clear()
    $this.RaiseChanged()
  }
}
#<+++++++++++>

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


# Abstract base for Client/Server endpoints
class McpJsonRpcEndpoint : IDisposable {
  hidden [McpRequestHandlers] $_requestHandlers = [McpRequestHandlers]::new()
  hidden [McpNotificationHandlers] $_notificationHandlers = [McpNotificationHandlers]::new()
  hidden [McpSession] $_session # Initialized by InitializeSession
  hidden [CancellationTokenSource] $_sessionCts # Controls the session message processing loop
  hidden [Job] $_messageProcessingTask # Task for the loop
  hidden [System.Threading.SemaphoreSlim] $_disposeLock = [System.Threading.SemaphoreSlim]::new(1, 1)
  hidden [bool] $_disposed = $false
  hidden [int] $_started = 0

  [ILogger] $Logger

  McpJsonRpcEndpoint([ILoggerFactory]$loggerFactory) {
    $this.Logger = if ($loggerFactory) { $loggerFactory.CreateLogger($this.GetType().Name) } else { [NullLogger]::Instance }
  }

  # Abstract property for endpoint name
  [string] $EndpointName = "Unnamed MCP Endpoint" # Provide default, derived must override

  # Accessor for the message processing task
  [Job] MessageProcessingTask() { return $this._messageProcessingTask } # Make it a method

  hidden SetRequestHandler([string]$method, [scriptblock]$handler) {
    $this._requestHandlers.Set($method, $handler)
  }

  # Public method matching C# API
  [void] AddNotificationHandler([string]$method, [scriptblock]$handler) {
    $this._notificationHandlers.Add($method, $handler)
  }

  # Public method matching C# API - Removed generic TResult
  [List[object]] SendRequestAsync([McpJsonRpcRequest]$request, [Type]$expectedResultType, [CancellationToken]$cancellationToken) {
    return $this.GetSessionOrThrow().SendRequestAsync($request, $expectedResultType, $cancellationToken)
  }

  # Public method matching C# API
  [Job] SendMessageAsync([McpIJsonRpcMessage]$message, [CancellationToken]$cancellationToken) {
    return $this.GetSessionOrThrow().SendMessageAsync($message, $cancellationToken)
  }

  hidden InitializeSession([McpTransport]$sessionTransport) {
    if ($null -ne $this._session) {
      $this.Logger.LogWarning("Session already initialized for $($this.EndpointName)")
      return # Or throw? C# allows re-init? No, seems it shouldn't.
    }
    $this._session = [McpSession]::new(
      $sessionTransport,
      $this.EndpointName, # Pass endpoint name to session
      $this._requestHandlers,
      $this._notificationHandlers,
      $this.Logger # Pass logger to session
    )
    $this.Logger.LogTrace("Session initialized for $($this.EndpointName)")
  }

  hidden StartSession([CancellationToken]$fullSessionCancellationToken) {
    if ([Interlocked]::Exchange([ref]$this._started, 1) -ne 0) {
      throw [InvalidOperationException]::new("The MCP session has already started.")
    }
    $session = $this.GetSessionOrThrow() # Ensure session exists
    $this._sessionCts = [CancellationTokenSource]::CreateLinkedTokenSource($fullSessionCancellationToken)
    $this._messageProcessingTask = $session.ProcessMessagesAsync($this._sessionCts.Token)
    $this.Logger.LogInformation("Session started message processing for $($this.EndpointName)")
  }

  hidden [McpSession] GetSessionOrThrow() {
    if ($null -eq $this._session) {
      throw [InvalidOperationException]::new("Session has not been initialized. Call InitializeSession.")
    }
    return $this._session
  }

  [Job] DisposeAsync() {
    #region Endpoint DisposeAsync
    $tcs = [List[bool]]::new()
    $lockTaken = $false
    try {
      $this._disposeLock.Wait() # Simple blocking wait for simplicity
      $lockTaken = $true

      if ($this._disposed) {
        $tcs.SetResult($true)
        return $tcs.Task
      }
      $this._disposed = $true

      # Call virtual unsynchronized dispose
      $disposeUnsyncTask = $this.DisposeUnsynchronizedAsync()
      $disposeUnsyncTask.Wait() # Blocking wait
      $tcs.SetResult($true)
    } catch {
      $this.Logger.LogError("Error during endpoint disposal: $($_.Exception.Message)")
      $tcs.SetException($_.Exception)
      # Don't rethrow from dispose
    } finally {
      if ($lockTaken) { $this._disposeLock.Release() }
    }
    return $tcs.Task
    #endregion
  }

  # Virtual method for derived classes to override
  [Job] DisposeUnsynchronizedAsync() {
    #region Endpoint DisposeUnsynchronizedAsync
    $this.Logger.LogInformation("Cleaning up endpoint $($this.EndpointName)...")

    # Cancel session processing
    if ($null -ne $this._sessionCts -and !$this._sessionCts.IsCancellationRequestened) {
      try { $this._sessionCts.Cancel() } catch {
        $null
      }
    }

    # Wait for message processing task to finish
    $processingTask = $this._messageProcessingTask
    if ($null -ne $processingTask -and !$processingTask.IsCompleted) {
      $this.Logger.LogTrace("Waiting for message processing task to complete...")
      try {
        $processingTask.Wait([TimeSpan]::FromSeconds(5)) # Wait with timeout
      } catch [AggregateException] {
        if ($_.Exception.InnerExceptions | Where-Object { $_ -is [OperationCanceledException] }) {
          $this.Logger.LogInformation("Message processing task cancelled during dispose.")
        } else { $this.Logger.LogWarning("Exception waiting for message processing task during dispose: $($_.Exception.Flatten().Message)") }
      } catch { $this.Logger.LogWarning("Exception/Timeout waiting for message processing task during dispose: $($_.Exception.Message)") }
    }

    # Dispose session (which cancels pending requests)
    try { $this._session.Dispose() } catch {
      $null
    }

    # Dispose CTS
    try { $this._sessionCts.Dispose() } catch {
      $null
    }

    # Derived classes might dispose transport here if they own it

    $this.Logger.LogInformation("Endpoint $($this.EndpointName) cleaned up.")
    return [Job]::CompletedTask
    #endregion
  }

  [void] Dispose() {
    $this.DisposeAsync().GetAwaiter().GetResult() # Blocking wait for Dispose
  }
}
class McpImplementation {
  # Name of the implementation.

  [ValidateNotNullOrEmpty()][string] $Name #

  # Version of the implementation.
  # [JsonPropertyName("version")] # Serialization hint
  [ValidateNotNullOrEmpty()][string] $Version #

  McpImplementation([string]$Name, [string]$Version) {
    if ([string]::IsNullOrWhiteSpace($Name)) { throw [ArgumentNullException]::new("Name") }
    if ([string]::IsNullOrWhiteSpace($Version)) { throw [ArgumentNullException]::new("Version") }
    $this.Name = $Name
    $this.Version = $Version
  }
}

class McpServerConfig {
  [ValidateNotNullOrEmpty()][string] $Id #, Unique identifier for this server configuration.
  [ValidateNotNullOrEmpty()][string] $Name #, Display name for the server.
  [ValidateNotNullOrEmpty()][McpTransportTypes] $TransportType #
  [string]$Location # Path for stdio, URL for http/sse
  [string[]]$Arguments # Used by stdio
  [Dictionary[string, string]]$TransportOptions # Transport-specific key-value pairs
}



class McpPingResult {
  McpPingResult() {}
}

class McpInitializeRequestParams : McpRequestParams {
  [ValidateNotNullOrEmpty()][string] $ProtocolVersion
  [ValidateNotNullOrEmpty()][McpClientCapabilities]$Capabilities
  [ValidateNotNullOrEmpty()][McpImplementation] $ClientInfo
}


class McpClientOptions {
  # Protocol version to request.
  [string] $ProtocolVersion = "2024-11-05"
  # Timeout for initialization sequence.
  [TimeSpan] $InitializationTimeout = [TimeSpan]::FromSeconds(60)

  # Information about this client implementation.
  [ValidateNotNullOrEmpty()][McpImplementation] $ClientInfo #
  # Client capabilities to advertise.
  [McpClientCapabilities]$Capabilities
}

class McpInitializeResult {
  [ValidateNotNullOrEmpty()][string] $ProtocolVersion
  [ValidateNotNullOrEmpty()][McpServerCapabilities] $Capabilities
  [ValidateNotNullOrEmpty()][McpImplementation] $ServerInfo
  [ValidateNotNullOrEmpty()][string]$Instructions
}


class McpCompletion {
  # Array of completion values (max 100 items).
  [ValidateNotNullOrEmpty()][string[]]$Values #

  # Total number of options available.
  [int]$Total

  # Indicates if more options exist beyond those returned.
  [bool]$HasMore
}

class McpCompleteResult {
  [ValidateNotNullOrEmpty()][McpCompletion] $Completion

  McpCompleteResult() {
    $this.Completion = [McpCompletion]::new()
  }
}

class McpArgument {
  # The name of the argument.
  [string] $Name = ''

  # The value of the argument to use for completion matching.
  [string] $Value = ''
}

class McpReference {
  [ValidateNotNullOrEmpty()][string] $Type = ' ' #

  # URI of the resource (if type is ref/resource).
  [string]$Uri
  # Name of the prompt (if type is ref/prompt).
  [string]$Name

  [string] ToString() {
    $refValue = if ($this.Type -eq 'ref/resource') { $this.Uri } else { $this.Name }
    return """`"$($this.Type)`": `"$refValue`""""
  }

  # C# has Validate method. Could add a PowerShell equivalent.
  [bool] Validate([ref]$validationMessage) {
    if ($this.Type -eq "ref/resource") {
      if ([string]::IsNullOrEmpty($this.Uri)) {
        $validationMessage.Value = "Uri is required for ref/resource"
        return $false
      }
    } elseif ($this.Type -eq "ref/prompt") {
      if ([string]::IsNullOrEmpty($this.Name)) {
        $validationMessage.Value = "Name is required for ref/prompt"
        return $false
      }
    } else {
      $validationMessage.Value = "Unknown reference type: $($this.Type)"
      return $false
    }
    $validationMessage.Value = $null
    return $true
  }
}

class McpCompleteRequestParams : McpRequestParams {
  [ValidateNotNullOrEmpty()][McpReference] $Ref #
  [ValidateNotNullOrEmpty()][McpArgument] $Argument #
}

class McpResource {
  # URI of the resource.
  [ValidateNotNullOrEmpty()][string] $Uri #

  # Human-readable name.
  [ValidateNotNullOrEmpty()][string] $Name #

  # Description of the resource.
  [string]$Description
  [string]$MimeType
  [long]$Size
  [McpAnnotations]$Annotations
}

class McpPaginatedResult {
  # [JsonPropertyName("nextCursor")] # Serialization hint
  [string]$NextCursor
}

class McpListResourcesResult : McpPaginatedResult {
  [ValidateNotNullOrEmpty()][List[McpResource]]$Resources = @()
}

class McpResourceTemplate {
  # URI template (RFC 6570).
  [ValidateNotNullOrEmpty()][string] $UriTemplate #

  # Human-readable name.
  [ValidateNotNullOrEmpty()][string] $Name #

  # Description of the template.
  [string]$Description

  # MIME type, if known.
  [string]$MimeType

  # Optional annotations.
  [McpAnnotations]$Annotations
}

class McpListResourceTemplatesResult : McpPaginatedResult {
  [ValidateNotNullOrEmpty()][List[McpResourceTemplate]]$ResourceTemplates
}


class McpListResourcesRequestParams {
  [string]$Cursor
}

class McpReadResourceRequestParams : McpRequestParams {
  [ValidateNotNullOrEmpty()][string] $Uri #
}

class McpListResourceTemplatesRequestParams {
  [string]$Cursor
}


class McpListPromptsRequestParams {
  [string]$Cursor
}

class McpListRootsRequestParams {
  [string]$ProgressToken
}

class McpListToolsRequestParams {
  [string]$Cursor
}

class McpUnsubscribeRequestParams : McpRequestParams {
  # Used for unsubscribe
  [ValidateNotNullOrEmpty()][string] $Uri #
}

class McpSubscribeRequestParams : McpRequestParams {
  [ValidateNotNullOrEmpty()][string] $Uri #
}

class McpGetPromptRequestParams : McpRequestParams {
  [ValidateNotNullOrEmpty()][string] $Name #
  [Dictionary[string, object]]$Arguments
}

class McpSetLevelRequestParams : McpRequestParams {
  [ValidateNotNullOrEmpty()][McpLoggingLevel] $Level #
}

class McpNotificationMethods {
  static [string] $ToolListChanged = "notifications/tools/list_changed"
  static [string] $PromptsListChanged = "notifications/prompts/list_changed"
  static [string] $ResourceListChanged = "notifications/resources/list_changed"
  static [string] $ResourceUpdated = "notifications/resources/updated"
  static [string] $RootsUpdated = "notifications/roots/list_changed"
  static [string] $LoggingMessage = "notifications/message"
  # C# also has "notifications/initialized" used internally in McpServer
  static [string] $Initialized = "notifications/initialized"
}

class McpListToolsResult : McpPaginatedResult {
  [List[McpTool]]$Tools = @()
}

class McpScriptBlockServerTool : McpServerTool {
  hidden [scriptblock] $_scriptBlock

  McpScriptBlockServerTool([McpTool]$protocolTool, [scriptblock]$scriptBlock) {
    $this.ProtocolTool = $protocolTool
    $this._scriptBlock = $scriptBlock
  }

  [List[McpCallToolResponse]] InvokeAsync([McpRequestContext]$request, [CancellationToken]$cancellationToken) {
    # Adjusted context type
    #region ScriptBlock InvokeAsync
    $tcs = [List[McpCallToolResponse]]::new()
    $task = [Job]::Run([Action] {
        try {
          # Invoke the scriptblock, passing arguments and context
          # Need to cast/deserialize $request.Params based on tool schema
          $toolParams = $request.Params -as [McpCallToolRequestParams] # Example cast
          $arguments = $toolParams.Arguments ?? @{}

          # Scriptblock signature: param($argumentsDictionary, $requestContext, $cancellationToken)
          $result = . $this._scriptBlock $arguments $request $cancellationToken # Invoke

          # Convert result to McpCallToolResponse (same logic as before)
          $response = $null
          if ($result -is [McpCallToolResponse]) { $response = $result }
          elseif ($result -is [string]) { $response = [McpCallToolResponse]@{ Content = @([McpContent]@{ Type = 'text'; Text = $result }); IsError = $false } }
          elseif ($result -is [array] -and $result.Count -gt 0 -and $result[0] -is [McpContent]) { $response = [McpCallToolResponse]@{ Content = @($result); IsError = $false } }
          elseif ($result -is [Exception]) { $response = [McpCallToolResponse]@{ Content = @([McpContent]@{ Type = 'text'; Text = $result.Message }); IsError = $true } }
          else {
            $jsonResult = try { [JsonSerializer]::Serialize($result, ([object]$result).GetType(), [McpJsonUtilities]::DefaultOptions) } catch { $null }
            $response = [McpCallToolResponse]@{ Content = @([McpContent]@{ Type = 'text'; Text = $jsonResult ?? "(Result could not be serialized)" }); IsError = $false }
          }
          $tcs.SetResult($response)
        } catch {
          $errorResponse = [McpCallToolResponse]@{ Content = @([McpContent]@{ Type = 'text'; Text = $_.Exception.Message }); IsError = $true }
          $tcs.SetResult($errorResponse)
        }
      }, $cancellationToken)
    return $tcs.Task
    #endregion
  }
}

# Context passed to server-side handlers - Adjusted to remove generic
class McpRequestContext {
  [McpServer] $Server # Reference to the server instance
  [object] $Params # Deserialized request parameters (caller casts)

  McpRequestContext([McpServer]$server, [object]$params) {
    $this.Server = $server
    $this.Params = $params
  }
}

class McpSamplingMessage {
  # Text or image content.
  [ValidateNotNullOrEmpty()][McpContent] $Content
  [ValidateNotNullOrEmpty()][McpRole] $Role
}

class McpModelHint {
  # Hint for a model name (substring matching recommended).
  [string]$Name
}

class McpModelPreferences {
  # Priority for cost (0-1).
  [float]$CostPriority

  # Optional hints for model selection (evaluated in order).
  # Should prioritize these over numeric priorities.
  [List[McpModelHint]]$Hints

  # Priority for speed/latency (0-1).
  [float]$SpeedPriority

  # Priority for intelligence/capabilities (0-1).
  [float]$IntelligencePriority

  # C# has Validate method. Could add a PowerShell equivalent.
  [bool] Validate([ref]$errorMessage) {
    $valid = $true
    $errors = [List[string]]::new()

    if ($null -ne $this.CostPriority -and ($this.CostPriority -lt 0 -or $this.CostPriority -gt 1)) {
      $errors.Add("CostPriority must be between 0 and 1")
      $valid = $false
    }
    if ($null -ne $this.SpeedPriority -and ($this.SpeedPriority -lt 0 -or $this.SpeedPriority -gt 1)) {
      $errors.Add("SpeedPriority must be between 0 and 1")
      $valid = $false
    }
    if ($null -ne $this.IntelligencePriority -and ($this.IntelligencePriority -lt 0 -or $this.IntelligencePriority -gt 1)) {
      $errors.Add("IntelligencePriority must be between 0 and 1")
      $valid = $false
    }

    $errorMessage.Value = $errors -join ', '
    return $valid
  }
}

class McpCreateMessageRequestParams : McpRequestParams {
  [McpContextInclusion]$IncludeContext
  [int]$MaxTokens
  [ValidateNotNullOrEmpty()][List[McpSamplingMessage]]$Messages #, IReadOnlyList in C#
  [ValidateNotNullOrEmpty()][object] $Metadata
  [ValidateNotNullOrEmpty()][McpModelPreferences]$ModelPreferences
  [List[string]]$StopSequences
  [string]$SystemPrompt
  [float]$Temperature
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

class AIFunction {
  [string] $Name
  [string] $Description
  [System.Text.Json.JsonElement] $JsonSchema
  [List[object]] InvokeAsync([IEnumerable[KeyValuePair[string, object]]]$arguments, [CancellationToken]$cancellationToken) {
    throw [NotImplementedException]::new("Requires Microsoft.Extensions.AI")
  }
}

class McpLogger {
  Log([McpLoggingLevel]$level, [string]$message, [Exception]$exception = $null) {
    # Abstract
  }
  [bool] IsEnabled([McpLoggingLevel]$level) {
    return $false # Abstract
  }
}

class McpConsoleLogger : McpLogger {
  [McpLoggingLevel]$MinimumLevel = [McpLoggingLevel]::Information

  McpConsoleLogger([McpLoggingLevel]$minLevel = [McpLoggingLevel]::Information) {
    $this.MinimumLevel = $minLevel
  }

  Log([McpLoggingLevel]$level, [string]$message, [Exception]$exception = $null) {
    if ($level -ge $this.MinimumLevel) {
      $prefix = "[{0}] {1:yyyy-MM-dd HH:mm:ss} - " -f ($level.ToString().ToUpper()), (Get-Date)
      switch ($level) {
        { $_ -ge [McpLoggingLevel]::Error } { Write-Error ($prefix + $message) }
        { $_ -eq [McpLoggingLevel]::Warning } { Write-Warning ($prefix + $message) }
        default { Write-Host ($prefix + $message) }
      }
      if ($null -ne $exception) {
        Write-Error ($exception | Format-List * -Force | Out-String)
      }
    }
  }
  [bool] IsEnabled([McpLoggingLevel]$level) {
    return $level -ge $this.MinimumLevel
  }
}

class McpNullLogger : McpLogger {
  hidden static [McpNullLogger] $_instance = [McpNullLogger]::new()
  static [McpNullLogger] Instance() {
    return [McpNullLogger]::_instance
  }
  Log([McpLoggingLevel]$level, [string]$message, [Exception]$exception = $null) { } # No-op
  [bool] IsEnabled([McpLoggingLevel]$level) { return $false }
}

class NullLoggerFactory {
  hidden static [NullLoggerFactory] $_instance = [NullLoggerFactory]::new()
  # static [NullLoggerFactory] Instance { get { return [NullLoggerFactory]::$_instance } }

  AddProvider($provider) {} # $provider type not enforced
  # CreateLogger([string]$categoryName) { return [NullLogger]::Instance }
  Dispose() {}
}

class McpBlobResourceContents : McpResourceContents {
  # The base64-encoded string representing the binary data.
  # [JsonPropertyName("blob")] # Serialization hint
  [string] $Blob = ''
}

class McpTextResourceContents : McpResourceContents {
  # The text of the item.
  # [JsonPropertyName("text")] # Serialization hint
  [string] $Text = ''
}

class McpPromptArgument {
  # Name of the argument.
  [ValidateNotNullOrEmpty()][string] $Name = ' ' #

  # Human-readable description.
  [string]$Description

  # Whether this argument must be provided.
  # [JsonPropertyName("required")] # Serialization hint
  [bool]$Required
}

class McpPrompt {
  # List of arguments for templating.
  [List[McpPromptArgument]]$Arguments
  # Optional description.
  [string]$Description
  # Name of the prompt or template.
  [ValidateNotNullOrEmpty()][string] $Name = ' ' #
}

class McpPromptMessage {
  # Content of the message.
  [ValidateNotNullOrEmpty()][McpContent] $Content #

  # Role ("user" or "assistant").
  [ValidateNotNullOrEmpty()][McpRole] $Role #

  McpPromptMessage() {
    $this.Content = [McpContent]::new()
  }
}


class McpRoot {
  # URI of the root.

  [string] $Uri #

  # Human-readable name.

  [string]$Name

  # Additional metadata (reserved).

  [object] $Meta
}

class McpOperationNames {
  static [string] $Sampling = "operation/sampling"
  static [string] $Roots = "operation/roots"
  static [string] $ListTools = "operation/listTools"
  static [string] $CallTool = "operation/callTool"
  static [string] $ListPrompts = "operation/listPrompts"
  static [string] $GetPrompt = "operation/getPrompt"
  static [string] $ListResources = "operation/listResources"
  static [string] $ReadResource = "operation/readResource"
  static [string] $GetCompletion = "operation/getCompletion"
  static [string] $SubscribeToResources = "operation/subscribeToResources"
  static [string] $UnsubscribeFromResources = "operation/unsubscribeFromResources"
  static [string] $ListResourceTemplates = "operation/listResourceTemplates" # Added based on Handlers
  static [string] $SetLoggingLevel = "operation/setLoggingLevel" # Added based on Handlers
}


class McpCreateMessageResult {
  [ValidateNotNullOrEmpty()][McpContent] $Content #
  [ValidateNotNullOrEmpty()][string] $Model #
  [string]$StopReason
  [ValidateNotNullOrEmpty()][string] $Role #- Should match McpRole enum values "user" or "assistant"
}

class McpEmptyResult {}

class McpGetPromptResult {
  [ValidateNotNullOrEmpty()][string]$Description
  [ValidateNotNullOrEmpty()][List[McpPromptMessage]]$Messages
}



class McpListPromptsResult : McpPaginatedResult {
  [ValidateNotNullOrEmpty()][List[McpPrompt]]$Prompts = @() #
}

class McpListRootsResult {
  [object] $Meta
  [List[McpRoot]]$Roots
}

class McpLoggingMessageNotificationParams {
  [McpLoggingLevel] $Level
  [string]$Logger
  [Object]$Data
}

class McpReadResourceResult {

  [ValidateNotNullOrEmpty()][List[McpResourceContents]]$Contents = @() #
}

class McpResourceUpdatedNotificationParams {

  [ValidateNotNullOrEmpty()][string] $Uri #
}


class McpStdioClientTransportOptions {
  [ValidateNotNullOrEmpty()][string] $Command #
  [string]$Arguments
  [string]$WorkingDirectory
  [Dictionary[string, string]]$EnvironmentVariables
  [TimeSpan] $ShutdownTimeout = [TimeSpan]::FromSeconds(5)
}

class McpStdioClientStreamTransport : McpTransportBase {
  hidden [McpStdioClientTransportOptions] $_options
  hidden [McpServerConfig] $_serverConfig # Needed for EndpointName potentially
  hidden [Process] $_process
  hidden [Job] $_readTask
  hidden [CancellationTokenSource] $_shutdownCts
  hidden [bool] $_processStarted = $false
  hidden [string] $_endpointName

  McpStdioClientStreamTransport([McpStdioClientTransportOptions]$options, [McpServerConfig]$serverConfig, [ILoggerFactory]$loggerFactory) : base($loggerFactory) {
    if ($null -eq $options) { throw [ArgumentNullException]::new("options") }
    if ($null -eq $serverConfig) { throw [ArgumentNullException]::new("serverConfig") }
    $this._options = $options
    $this._serverConfig = $serverConfig
    $this._endpointName = "Client (stdio) for ($($serverConfig.Id): $($serverConfig.Name))"
  }

  [Job] ConnectAsync([CancellationToken]$cancellationToken) {
    #region ConnectAsync Implementation Placeholder
    $this.Logger.LogInformation("Attempting to connect Stdio transport: $($this._endpointName)")
    if ($this.IsConnected) {
      $this.Logger.LogWarning("Transport already connected.")
      throw [McpTransportException]::new("Transport is already connected")
    }

    $this._shutdownCts = [CancellationTokenSource]::new()
    $tcs = [List[bool]]::new()

    try {
      # --- Process Setup ---
      $startInfo = [ProcessStartInfo]@{
        FileName               = $this._options.Command
        RedirectStandardInput  = $true
        RedirectStandardOutput = $true
        RedirectStandardError  = $true
        UseShellExecute        = $false
        CreateNoWindow         = $true
        WorkingDirectory       = $this._options.WorkingDirectory ?? $PWD.Path
        StandardOutputEncoding = [UTF8Encoding]::new($false) # No BOM
        StandardErrorEncoding  = [UTF8Encoding]::new($false)  # No BOM
        # StandardInputEncoding requires .NET Core or specific handling
      }
      if (![string]::IsNullOrWhiteSpace($this._options.Arguments)) {
        $startInfo.Arguments = $this._options.Arguments
      }
      if ($this._options.EnvironmentVariables) {
        foreach ($key in $this._options.EnvironmentVariables.Keys) {
          $startInfo.Environment.Add($key, $this._options.EnvironmentVariables[$key])
        }
      }
      # TODO: Input encoding for Framework vs Core

      $this._process = [Process]::new()
      $this._process.StartInfo = $startInfo

      # Log errors from process stderr
      $handler = [DataReceivedEventHandler] {
        param($sender, $e) # Explicit parameters
        if ($e.Data) { $this.Logger.LogError("[$($this._endpointName) Process Error]: $($e.Data)") }
      }.GetNewClosure() # Use GetNewClosure to capture $this correctly
      $this._process.add_ErrorDataReceived($handler)

      $this.Logger.LogInformation("Starting process: $($startInfo.FileName) $($startInfo.Arguments)")
      $this._processStarted = $this._process.Start()

      if (!$this._processStarted) {
        throw [McpTransportException]::new("Failed to start MCP server process")
      }
      $this.Logger.LogInformation("Process started with PID: $($this._process.Id)")
      $this._process.BeginErrorReadLine()

      # --- Start Read Loop ---
      $this._readTask = [Job]::Run(
        [Action] { $this.ReadMessagesLoop($this._shutdownCts.Token) },
        [CancellationToken]::None # Run read loop independently of connect cancellation
      )
      $this.SetConnected($true)
      $this.Logger.LogInformation("Stdio transport connected.")
      $tcs.SetResult($true) # Signal success
    } catch {
      $this.Logger.LogError("Stdio connection failed: $($_.Exception.Message)")
      # Run CleanupAsync without await as we are in sync context of catch
      $cleanupTask = $this.CleanupAsync($cancellationToken) # Don't wait here
      $tcs.SetException($_.Exception) # Propagate exception
      throw # Rethrow original exception
    }

    return $tcs.Task # Return task that completes on connect/fail
    #endregion
  }

  hidden [void] ReadMessagesLoop([CancellationToken]$cancellationToken) {
    $this.Logger.LogTrace("Starting Stdio read loop...")
    try {
      $reader = $this._process.StandardOutput
      while (!$cancellationToken.IsCancellationRequested -and $null -ne $this._process -and (!$this._process.HasExited)) {
        # Use ReadLineAsync with cancellation support if available (.NET Core specific?)
        # Fallback to synchronous ReadLine with periodic cancellation check
        $line = $null
        $readTask = $reader.ReadLineAsync()
        # Wait for read or cancellation
        # Simple Wait with timeout approach for PS compatibility
        if ($readTask.Wait(100, $cancellationToken)) {
          # Check every 100ms, pass token
          $line = $readTask.Result
        } else {
          # Timeout or cancellation request during wait
          if ($cancellationToken.IsCancellationRequested) { break }
          continue # Timeout, check process/token again
        }


        if ($null -eq $line) {
          # End of stream
          $this.Logger.LogInformation("Stdio stream ended.")
          break
        }
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        $this.Logger.LogTrace("Received line: $line")
        # Process the line (deserialize and add to queue)
        try {
          $trimmedLine = $line.Trim() # Handle potential non-printable prefix chars
          # TODO: More robust JSON detection/parsing needed
          $message = [JsonSerializer]::Deserialize($trimmedLine, [McpIJsonRpcMessage], [McpJsonUtilities]::DefaultOptions)
          if ($message) {
            $this.WriteMessageAsync($message, $cancellationToken).GetAwaiter().GetResult() # Add to internal queue
          } else {
            $this.Logger.LogWarning("Failed to deserialize line to IJsonRpcMessage: $trimmedLine")
          }
        } catch {
          $this.Logger.LogError("Error processing received line '$line': $($_.Exception.Message)")
        }
      }
    } catch [OperationCanceledException] {
      $this.Logger.LogInformation("Stdio read loop cancelled.")
    } catch [Exception] {
      # Catch potential disposed exceptions etc.
      $this.Logger.LogError("Exception in Stdio read loop: $($_.Exception.Message)")
    } finally {
      $this.Logger.LogTrace("Exiting Stdio read loop.")
      # Ensure cleanup happens if the loop exits unexpectedly
      if ($this.IsConnected) {
        $cleanupTask = $this.CleanupAsync([CancellationToken]::None) # Fire and forget cleanup
      }
    }
  }

  # Override SendMessageAsync for Stdio specific implementation
  [Job] SendMessageAsync([McpIJsonRpcMessage]$message, [CancellationToken]$cancellationToken) {
    #region SendMessageAsync Override
    if (!$this.IsConnected -or $null -eq $this._process -or $this._process.HasExited) {
      throw [McpTransportException]::new("Transport is not connected or process has exited")
    }

    $tcs = [List[bool]]::new()
    $json = $null
    try {
      $id = if ($message -is [McpIJsonRpcMessageWithId]) { $message.Id.ToString() } else { "(no id)" }
      $json = [JsonSerializer]::Serialize($message, [McpIJsonRpcMessage], [McpJsonUtilities]::DefaultOptions)
      $this.Logger.LogTrace("Sending JSON to Stdio: $json")

      # Use WriteLineAsync correctly
      $writer = $this._process.StandardInput
      # Need to handle async correctly without await
      $writeTask = $writer.WriteLineAsync($json)
      $flushTask = $writeTask.ContinueWith({
          param($prevTask)
          if ($prevTask.IsFaulted) { throw $prevTask.Exception.InnerExceptions[0] }
          if ($prevTask.IsCanceled) { throw [OperationCanceledException]::new($cancellationToken) } # Use provided token
          return $writer.FlushAsync()
        }, $cancellationToken).Unwrap()

      # ContinueWith for setting TCS result after flush completes
      $finalTask = $flushTask.ContinueWith({
          param($ft)
          if ($ft.IsFaulted) { $tcs.SetException($ft.Exception.InnerExceptions) }
          elseif ($ft.IsCanceled) { $tcs.SetCanceled($cancellationToken) } # Use provided token
          else {
            $this.Logger.LogTrace("Message sent to Stdio.")
            $tcs.SetResult($true)
          }
        }, $cancellationToken)
    } catch {
      $this.Logger.LogError("Failed to initiate send message via Stdio: $($_.Exception.Message)")
      $tcs.SetException($_.Exception)
      # Don't rethrow here, let the returned task carry the exception
    }
    return $tcs.Task # Return the task that completes when sending is done/fails
    #endregion
  }

  [Job] CleanupAsync([CancellationToken]$cancellationToken) {
    #region CleanupAsync
    $this.Logger.LogInformation("Cleaning up Stdio transport...")
    $this.SetConnected($false) # Mark as disconnected immediately

    # Cancel the read loop and internal operations
    if ($null -ne $this._shutdownCts -and !$this._shutdownCts.IsCancellationRequested) {
      try { $this._shutdownCts.Cancel() } catch {
        $null
      }
    }

    $processToCleanup = $this._process
    $readTaskToWait = $this._readTask

    # Reset fields early
    $this._process = $null
    $this._readTask = $null

    # Process cleanup
    if ($null -ne $processToCleanup -and $this._processStarted -and (!$processToCleanup.HasExited)) {
      $this.Logger.LogInformation("Attempting to kill process tree for PID: $($processToCleanup.Id)")
      try {
        # Using simplified Kill() - C# uses KillTree helper which needs porting
        # KillTree logic involves platform checks (taskkill / pgrep)
        $processToCleanup.Kill($true) # Assuming Kill(true) exists or adapt KillTree logic here
        $processToCleanup.WaitForExit([int]$this._options.ShutdownTimeout.TotalMilliseconds) # Wait briefly
      } catch {
        $this.Logger.LogError("Error killing process $($processToCleanup.Id): $($_.Exception.Message)")
      } finally {
        # Remove event handler if added (PowerShell doesn't have remove_ syntax easily)
        # We might need to store the handler scriptblock and use Remove_ErrorDataReceived if possible, or ignore.
        try { $processToCleanup.Dispose() } catch {
          $null
        }
      }
    } elseif ($null -ne $processToCleanup) {
      try { $processToCleanup.Dispose() } catch {
        $null
      }
    }

    # Wait for read task to complete (with timeout)
    if ($null -ne $readTaskToWait -and !$readTaskToWait.IsCompleted) {
      $this.Logger.LogTrace("Waiting for read task to complete...")
      try {
        # Task.Wait(TimeSpan, CancellationToken) doesn't exist directly in older .NET
        # Use Task.Wait(TimeSpan) and check cancellation token separately if needed, or WhenAny approach.
        $readTaskToWait.Wait([TimeSpan]::FromSeconds(5)) # Simple timeout wait
      } catch [AggregateException] {
        # Check if it contains OperationCanceledException
        if ($_.Exception.InnerExceptions | Where-Object { $_ -is [OperationCanceledException] }) {
          $this.Logger.LogInformation("Stdio read task cancelled during cleanup.")
        } else {
          $this.Logger.LogError("Error waiting for Stdio read task during cleanup: $($_.Exception.Message)")
        }
      } catch [TimeoutException] {
        $this.Logger.LogWarning("Timeout waiting for Stdio read task to complete during cleanup.")
      } catch {
        # Other exceptions
        $this.Logger.LogError("Error waiting for Stdio read task during cleanup: $($_.Exception.Message)")
      }
    }

    # Dispose CancellationTokenSource
    try { $this._shutdownCts.Dispose() } catch {
      $null
    }
    $this._shutdownCts = $null

    $this.Logger.LogInformation("Stdio transport cleanup complete.")
    return [Job]::CompletedTask
    #endregion
  }

  # Override DisposeAsync to call CleanupAsync
  [Job] DisposeAsync() {
    return $this.CleanupAsync([CancellationToken]::None)
  }
}

class McpStdioClientTransport : McpClientTransport {
  hidden [McpStdioClientTransportOptions] $_options
  hidden [McpServerConfig] $_serverConfig
  hidden [ILoggerFactory] $_loggerFactory

  McpStdioClientTransport([McpStdioClientTransportOptions]$options, [McpServerConfig]$serverConfig, [ILoggerFactory]$loggerFactory) {
    if ($null -eq $options) { throw [ArgumentNullException]::new("options") }
    if ($null -eq $serverConfig) { throw [ArgumentNullException]::new("serverConfig") }
    $this._options = $options
    $this._serverConfig = $serverConfig
    $this._loggerFactory = $loggerFactory
  }

  [List[McpTransport]] ConnectAsync([CancellationToken]$cancellationToken) {
    $streamTransport = [McpStdioClientStreamTransport]::new($this._options, $this._serverConfig, $this._loggerFactory)
    $connectTask = $streamTransport.ConnectAsync($cancellationToken)

    # Return a task that completes with the transport instance or throws if connection fails
    return $connectTask.ContinueWith({
        param($task)
        if ($task.IsFaulted) {
          # Ensure disposal if connection failed
          try { $streamTransport.DisposeAsync().Wait(1000) } catch {
            $null
          } # Brief wait for disposal
          throw $task.Exception.InnerExceptions[0] # Rethrow connection exception
        }
        if ($task.IsCanceled) {
          try { $streamTransport.DisposeAsync().Wait(1000) } catch {
            $null
          }
          throw [OperationCanceledException]::new($cancellationToken)
        }
        return $streamTransport # Return the connected transport
      }, $cancellationToken
    )
  }

  [Job] DisposeAsync() {
    # This transport doesn't own resources directly, the session transport does
    return [Job]::CompletedTask
  }
}

class McpStdioServerTransport : McpTransportBase {
  hidden [string] $_serverName
  hidden [TextReader] $_stdInReader
  hidden [Stream] $_stdOutStream
  hidden [SemaphoreSlim] $_sendLock = [SemaphoreSlim]::new(1, 1)
  hidden [CancellationTokenSource] $_shutdownCts = [CancellationTokenSource]::new()
  hidden [Job] $_readLoopCompleted
  hidden [int] $_disposed = 0
  hidden [string] $_endpointName

  McpStdioServerTransport([string]$serverName, [Stream]$stdinStream, [Stream]$stdoutStream, [ILoggerFactory]$loggerFactory) `
    : base($loggerFactory) {
    if ([string]::IsNullOrWhiteSpace($serverName)) { throw [ArgumentNullException]::new("serverName") }

    $this._serverName = $serverName
    $this._endpointName = "Server (stdio) ($($this._serverName))"

    $this._stdInReader = [StreamReader]::new($stdinStream ?? [Console]::OpenStandardInput(), [Encoding]::UTF8)
    $this._stdOutStream = $stdoutStream ?? [BufferedStream]::new([Console]::OpenStandardOutput())

    $this.SetConnected($true)
    # Start read loop in background
    $this._readLoopCompleted = [Job]::Run([Action] { $this.ReadMessagesLoop($this._shutdownCts.Token) }, [CancellationToken]::None) # Loop runs until cancelled/EOF
  }

  # Convenience constructor using McpServerOptions
  McpStdioServerTransport([McpServerOptions]$serverOptions, [ILoggerFactory]$loggerFactory) `
    : base($serverOptions.ServerInfo.Name, $null, $null, $loggerFactory) {
    # Call corrected base constructor call
    if ($null -eq $serverOptions) { throw [ArgumentNullException]::new("serverOptions") }
    # ServerInfo validation would happen in the primary constructor's call
  }

  hidden ReadMessagesLoop([CancellationToken]$cancellationToken) {
    $this.Logger.LogTrace("Starting Stdio Server read loop...")
    try {
      while (!$cancellationToken.IsCancellationRequested) {
        $line = $null
        # Asynchronously read line with cancellation
        $readTask = $this._stdInReader.ReadLineAsync() # .NET Core has ReadLineAsync(CancellationToken)
        # Simple Wait with timeout approach for PS compatibility
        if ($readTask.Wait(100, $cancellationToken)) {
          # Check every 100ms, pass token
          $line = $readTask.Result
        } else {
          # Timeout or cancellation request during wait
          if ($cancellationToken.IsCancellationRequested) { break }
          continue # Timeout, check process/token again
        }


        if ($null -eq $line) {
          $this.Logger.LogInformation("Stdio Server input stream ended.")
          break
        }
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        $this.Logger.LogTrace("Server received line: $line")
        try {
          $trimmedLine = $line.Trim()
          $message = [JsonSerializer]::Deserialize($trimmedLine, [McpIJsonRpcMessage], [McpJsonUtilities]::DefaultOptions)
          if ($message) {
            $this.WriteMessageAsync($message, $cancellationToken).GetAwaiter().GetResult() # Add to internal queue
          } else {
            $this.Logger.LogWarning("Server failed to deserialize line: $trimmedLine")
          }
        } catch {
          $this.Logger.LogError("Server error processing received line '$line': $($_.Exception.Message)")
        }
      }
    } catch [OperationCanceledException] {
      $this.Logger.LogInformation("Stdio Server read loop cancelled.")
    } catch [Exception] {
      # Catch potential disposed exceptions etc.
      $this.Logger.LogError("Exception in Stdio Server read loop: $($_.Exception.Message)")
    } finally {
      $this.Logger.LogTrace("Exiting Stdio Server read loop.")
      $this.SetConnected($false) # Mark as disconnected if loop terminates
    }
  }

  # Override SendMessageAsync for Stdio specific implementation
  [Job] SendMessageAsync([McpIJsonRpcMessage]$message, [CancellationToken]$cancellationToken) {
    #region Server SendMessageAsync Override
    $tcs = [List[bool]]::new()
    $lockTaken = $false
    try {
      # Async lock equivalent
      $this._sendLock.Wait($cancellationToken)
      $lockTaken = $true

      if (!$this.IsConnected) { throw [McpTransportException]::new("Transport is not connected") }

      $id = if ($message -is [McpIJsonRpcMessageWithId]) { $message.Id.ToString() } else { "(no id)" }
      $this.Logger.LogTrace("Server sending message (ID: $id)")

      # Serialize and write (needs async stream writing)
      # JsonSerializer.SerializeAsync needs a Stream
      $memStream = [MemoryStream]::new()
      # Use SerializeAsync and wait - PS doesn't have await
      $serializeTask = [JsonSerializer]::SerializeAsync($memStream, $message, ([McpIJsonRpcMessage].gettype()), [McpJsonUtilities]::DefaultOptions, $cancellationToken) # Need GetType() for non-generic
      $serializeTask.Wait($cancellationToken)

      # Write JSON bytes
      $jsonBytes = $memStream.ToArray()
      $writeAsyncTask = $this._stdOutStream.WriteAsync($jsonBytes, 0, $jsonBytes.Length, $cancellationToken)
      $writeAsyncTask.Wait($cancellationToken)

      # Write newline
      $newlineBytes = [Encoding]::UTF8.GetBytes("`n") # Use system newline? UTF8 newline is safer.
      $writeNlTask = $this._stdOutStream.WriteAsync($newlineBytes, 0, $newlineBytes.Length, $cancellationToken)
      $writeNlTask.Wait($cancellationToken)

      # Flush
      $flushTask = $this._stdOutStream.FlushAsync($cancellationToken)
      $flushTask.Wait($cancellationToken)

      $this.Logger.LogTrace("Server message sent.")
      $tcs.SetResult($true)
    } catch {
      $this.Logger.LogError("Server failed to send message: $($_.Exception.Message)")
      $tcs.SetException($_.Exception)
      throw
    } finally {
      if ($lockTaken) { $this._sendLock.Release() }
    }
    return $tcs.Task
    #endregion
  }

  # Override DisposeAsync
  [Job] DisposeAsync() {
    #region Server DisposeAsync
    $this.Logger.LogInformation("Disposing Stdio Server transport...")
    if ([Interlocked]::Exchange([ref]$this._disposed, 1) -ne 0) {
      return [Job]::CompletedTask
    }

    $tcs = [List[bool]]::new()
    try {
      $this.SetConnected($false) # Ensure state is updated

      # Signal shutdown
      try { $this._shutdownCts.Cancel() } catch {
        $null
      }

      # Dispose streams (this might interrupt blocking reads/writes)
      try { $this._stdInReader.Dispose() } catch { $this.Logger.LogWarning("Exception disposing stdinReader: $($_.Exception.Message)") }
      try { $this._stdOutStream.Dispose() } catch { $this.Logger.LogWarning("Exception disposing stdoutStream: $($_.Exception.Message)") }

      # Wait for read loop task
      $readLoopTask = $this._readLoopCompleted
      if ($null -ne $readLoopTask -and !$readLoopTask.IsCompleted) {
        $this.Logger.LogTrace("Waiting for server read loop to complete...")
        try {
          $readLoopTask.Wait([TimeSpan]::FromSeconds(5)) # Short timeout
        } catch [AggregateException] {
          # Check if it contains OperationCanceledException
          if ($_.Exception.InnerExceptions | Where-Object { $_ -is [OperationCanceledException] }) {
            $this.Logger.LogInformation("Stdio Server read loop cancelled during cleanup.")
          } else {
            $this.Logger.LogError("Error waiting for Stdio Server read loop task during dispose: $($_.Exception.Message)")
          }
        } catch {
          # Other exceptions like TimeoutException
          $this.Logger.LogWarning("Exception/Timeout waiting for server read loop task during dispose: $($_.Exception.Message)")
        }
      }

      # Dispose Cts and Lock
      try { $this._shutdownCts.Dispose() } catch {
        $null
      }
      try { $this._sendLock.Dispose() } catch {
        $null
      }

      $this.Logger.LogInformation("Stdio Server transport disposed.")
      $tcs.SetResult($true)
    } catch {
      $this.Logger.LogError("Exception during Stdio Server transport disposal: $($_.Exception.Message)")
      $tcs.SetException($_.Exception)
      # Don't rethrow from dispose
    }
    return $tcs.Task
    #endregion
  }
}


# --- SSE Transport  ---

class McpSseClientTransportOptions {
  [TimeSpan] $ConnectionTimeout = [TimeSpan]::FromSeconds(30)
  [int] $MaxReconnectAttempts = 3
  [TimeSpan] $ReconnectDelay = [TimeSpan]::FromSeconds(5)
  [Dictionary[string, string]]$AdditionalHeaders
}

class McpSseClientSessionTransport : McpTransportBase {
  hidden [HttpClient] $_httpClient
  hidden [McpSseClientTransportOptions] $_options
  hidden [Uri] $_sseEndpoint
  hidden [Uri] $_messageEndpoint # Discovered via 'endpoint' event
  hidden [CancellationTokenSource] $_connectionCts
  hidden [Job] $_receiveTask
  hidden [string] $_endpointName
  hidden [List[bool]]$_connectionEstablishedTcs

  McpSseClientSessionTransport([McpSseClientTransportOptions]$options, [McpServerConfig]$serverConfig, [HttpClient]$httpClient, [ILoggerFactory]$loggerFactory) `
    : base($loggerFactory) {
    # Validation...
    $this._options = $options
    $this._httpClient = $httpClient
    $this._sseEndpoint = [Uri]::new($serverConfig.Location) # Assumes Location is SSE endpoint
    $this._endpointName = "Client (SSE) for ($($serverConfig.Id): $($serverConfig.Name))"
    $this._connectionEstablishedTcs = [List[bool]]::new()
  }

  [Job] ConnectAsync([CancellationToken]$cancellationToken) {
    #region SSE ConnectAsync Placeholder
    $this.Logger.LogInformation("Attempting to connect SSE transport: $($this._endpointName)")
    if ($this.IsConnected) { throw [McpTransportException]::new("Transport already connected") }

    $this._connectionCts = [CancellationTokenSource]::CreateLinkedTokenSource($cancellationToken) # Link external token

    # Start receiving loop in background
    $this._receiveTask = [Job]::Run(
      [Action] { $this.ReceiveMessagesLoop($this._connectionCts.Token) },
      [CancellationToken]::None # Loop runs until _connectionCts is cancelled
    )

    # Wait for connection to be established (endpoint event received) or timeout/cancellation
    $connectTimeoutTask = [Job]::Delay($this._options.ConnectionTimeout, $this._connectionCts.Token)
    # Use Task.WhenAny and check result
    $completedTask = [Job]::WhenAny($this._connectionEstablishedTcs.Task, $connectTimeoutTask).GetAwaiter().GetResult()

    if ($completedTask -ne $this._connectionEstablishedTcs.Task) {
      # Timeout or external cancellation happened before endpoint event
      $this._connectionCts.Cancel() # Ensure loop stops
      if ($cancellationToken.IsCancellationRequested) { throw [OperationCanceledException]::new($cancellationToken) }
      else { throw [TimeoutException]::new("SSE connection timed out waiting for endpoint event.") }
    }

    # If connection task completed successfully (means endpoint event was processed)
    $this.Logger.LogInformation("SSE transport connected.")
    return $this._connectionEstablishedTcs.Task # Return the completed task
    #endregion
  }

  hidden ReceiveMessagesLoop([CancellationToken]$cancellationToken) {
    #region SSE Receive Loop Placeholder
    $this.Logger.LogTrace("Starting SSE receive loop...")
    $reconnectAttempts = 0
    while (!$cancellationToken.IsCancellationRequested) {
      try {
        $this.Logger.LogTrace("Attempting SSE connection to $($this._sseEndpoint)...")
        # --- HttpClient Request for SSE stream ---
        $request = [HttpRequestMessage]::new([HttpMethod]::Get, $this._sseEndpoint)
        $request.Headers.Accept.Add([System.Net.Http.Headers.MediaTypeWithQualityHeaderValue]::new("text/event-stream"))
        # Add custom headers from options
        if ($this._options.AdditionalHeaders) {
          foreach ($key in $this._options.AdditionalHeaders.Keys) {
            $request.Headers.TryAddWithoutValidation($key, $this._options.AdditionalHeaders[$key]) | Out-Null
          }
        }

        # SendAsync with cancellation
        $responseTask = $this._httpClient.SendAsync($request, [HttpCompletionOption]::ResponseHeadersRead, $cancellationToken)
        $response = $responseTask.GetAwaiter().GetResult()
        $response.EnsureSuccessStatusCode() | Out-Null

        # Read stream with cancellation
        $streamTask = $response.Content.ReadAsStreamAsync() # C# has ReadAsStreamAsync(CancellationToken) polyfill? Assume basic works
        $stream = $streamTask.GetAwaiter().GetResult()

        $this.Logger.LogInformation("SSE stream connected.")
        $reconnectAttempts = 0 # Reset attempts on successful connection

        # --- Process SSE Stream ---
        # This requires a robust SSE parser. System.Net.ServerSentEvents is not standard in PS.
        # Need custom implementation or external library.
        # Placeholder logic:
        $reader = [StreamReader]::new($stream, [Encoding]::UTF8)
        $eventType = "message" # Default SSE event type
        while (!$reader.EndOfStream) {
          # Simplified blocking read - needs async and proper SSE parsing
          if ($cancellationToken.IsCancellationRequested) { break }
          $line = $reader.ReadLine() # Blocking read
          if ($null -eq $line) { break } # Check for EOF again

          $this.Logger.LogTrace("SSE Raw Line: $line")
          # Parse $line according to SSE format (event:, data:, id:, retry:, comments)
          if ($line.StartsWith("event:")) { $eventType = $line.Substring(6).Trim() }
          elseif ($line.StartsWith("data:")) {
            $data = $line.Substring(5).Trim()
            # Handle event based on $eventType
            if ($eventType -eq "endpoint") { $this.HandleEndpointEvent($data) }
            elseif ($eventType -eq "message") { $this.ProcessSseMessage($data, $cancellationToken).GetAwaiter().GetResult() }
            else { $this.Logger.LogTrace("Unknown SSE event type: $eventType") }
          } elseif ([string]::IsNullOrEmpty($line)) {
            # Empty line signals end of event - reset parser state if needed
            $eventType = "message" # Reset default event type
          } elseif ($line.StartsWith(":")) {
            # Comment line, ignore
          }
        } # End simplified while read loop
        $reader.Dispose()
        $stream.Dispose()
        $response.Dispose()
        $this.Logger.LogInformation("SSE stream ended.")
      } catch [OperationCanceledException] {
        $this.Logger.LogInformation("SSE receive loop cancelled.")
        break # Exit loop on cancellation
      } catch [Exception] {
        # Handle HttpClient exceptions, stream errors etc.
        $this.Logger.LogError("Error in SSE receive loop: $($_.Exception.Message)")
        if ($cancellationToken.IsCancellationRequested) { break } # Don't retry if cancellation was requested

        # --- Reconnect Logic ---
        $reconnectAttempts++
        if ($reconnectAttempts -ge $this._options.MaxReconnectAttempts) {
          $this.Logger.LogError("SSE reconnect attempts exceeded.")
          $this._connectionEstablishedTcs.TrySetException($_) # Signal failure if not already connected
          break # Exit loop
        }
        $this.Logger.LogWarning("Attempting SSE reconnect ($reconnectAttempts/$($this._options.MaxReconnectAttempts)) after delay...")
        try { [Job]::Delay($this._options.ReconnectDelay, $cancellationToken).Wait() } catch [OperationCanceledException] { break }
      }
    } # End while not cancelled
    $this.Logger.LogTrace("Exiting SSE receive loop.")
    $this.SetConnected($false)
    $this._connectionEstablishedTcs.TrySetCanceled($cancellationToken) # Ensure TCS completes if loop exits
    #endregion
  }

  hidden HandleEndpointEvent([string]$data) {
    $this.Logger.LogInformation("Received endpoint event data: $data")
    try {
      if ([string]::IsNullOrWhiteSpace($data)) { throw [ArgumentException]::new("Endpoint data is empty") }
      # Logic from C# to resolve relative/absolute URI
      if ($data.StartsWith("http://") -or $data.StartsWith("https://")) {
        $this._messageEndpoint = [Uri]::new($data)
      } else {
        $baseUrl = $this._sseEndpoint.AbsoluteUri
        if ($baseUrl.EndsWith("/sse")) { $baseUrl = $baseUrl.Substring(0, $baseUrl.Length - 4) }
        # Ensure no double slashes
        $endpointUri = "$($baseUrl.TrimEnd('/'))/$($data.TrimStart('/'))"
        $this._messageEndpoint = [Uri]::new($endpointUri)
      }
      $this.Logger.LogInformation("Discovered message endpoint: $($this._messageEndpoint)")
      $this.SetConnected($true)
      $this._connectionEstablishedTcs.TrySetResult($true) # Signal successful connection init
    } catch {
      $this.Logger.LogError("Failed to handle endpoint event: $($_.Exception.Message)")
      $this._connectionEstablishedTcs.TrySetException($_) # Signal failure
      $this._connectionCts.Cancel() # Stop the connection attempt
    }
  }

  hidden [Job] ProcessSseMessage([string]$data, [CancellationToken]$cancellationToken) {
    $tcs = [List[bool]]::new()
    if (!$this.IsConnected) {
      $this.Logger.LogWarning("Received SSE message before transport is fully connected/endpoint known.")
      $tcs.SetResult($true) # Or potentially error? C# logs warning and returns.
      return $tcs.Task
    }
    try {
      $this.Logger.LogTrace("Processing SSE message data: $data")
      $message = [JsonSerializer]::Deserialize($data, [McpIJsonRpcMessage], [McpJsonUtilities]::DefaultOptions)
      if ($message) {
        $this.WriteMessageAsync($message, $cancellationToken).GetAwaiter().GetResult() # Add to internal queue
        $tcs.SetResult($true)
      } else {
        $this.Logger.LogWarning("Failed to deserialize SSE message data: $data")
        $tcs.SetResult($true) # Continue processing other messages
      }
    } catch {
      $this.Logger.LogError("Error processing SSE message: $($_.Exception.Message)")
      $tcs.SetException($_)
    }
    return $tcs.Task
  }

  # Override SendMessageAsync for SSE specific implementation (POST to message endpoint)
  [Job] SendMessageAsync([McpIJsonRpcMessage]$message, [CancellationToken]$cancellationToken) {
    #region SSE SendMessageAsync Override
    if (!$this.IsConnected -or $null -eq $this._messageEndpoint) {
      throw [McpTransportException]::new("Transport not connected or message endpoint not discovered")
    }

    $tcs = [List[bool]]::new()
    try {
      $json = [JsonSerializer]::Serialize($message, [McpIJsonRpcMessage], [McpJsonUtilities]::DefaultOptions)
      $content = [StringContent]::new($json, [Encoding]::UTF8, "application/json")
      $id = if ($message -is [McpIJsonRpcMessageWithId]) { $message.Id.ToString() } else { "(no id)" }
      $this.Logger.LogTrace("Sending POST to $($this._messageEndpoint) with ID: $id")

      # Async POST request
      $postTask = $this._httpClient.PostAsync($this._messageEndpoint, $content, $cancellationToken)
      $response = $postTask.GetAwaiter().GetResult()

      $responseContentTask = $response.Content.ReadAsStringAsync() # CancellationToken needed? .NET Core likely supports it.
      $responseContent = $responseContentTask.GetAwaiter().GetResult()

      # Check status code AFTER reading content (in case error message is in body)
      $response.EnsureSuccessStatusCode() | Out-Null

      $this.Logger.LogTrace("POST response content: $responseContent")

      # C# logic checks if response is "accepted" or if it's the actual JSON response (for initialize)
      if ($message -is [McpJsonRpcRequest] -and $message.Method -eq "initialize") {
        if ($responseContent -ne "accepted") {
          # Assume response content IS the InitializeResult JSON
          $this.Logger.LogInformation("Initialize response received directly via POST.")
          $responseMessage = [JsonSerializer]::Deserialize($responseContent, [McpIJsonRpcMessage], [McpJsonUtilities]::DefaultOptions)
          if ($responseMessage) {
            $this.WriteMessageAsync($responseMessage, $cancellationToken).GetAwaiter().GetResult() # Add to queue
          } else {
            $this.Logger.LogError("Failed to deserialize direct initialize response: $responseContent")
          }
        } else {
          $this.Logger.LogInformation("Initialize request accepted, expecting response via SSE.")
        }
      } elseif ($responseContent -ne "accepted") {
        $this.Logger.LogError("Message POST not accepted by server. Response: $responseContent")
        throw [McpTransportException]::new("Server did not accept the message via POST. Response: $responseContent")
      } else {
        $this.Logger.LogTrace("Message POST accepted by server.")
      }

      $tcs.SetResult($true)
    } catch {
      $this.Logger.LogError("Failed to send message via SSE POST: $($_.Exception.Message)")
      $tcs.SetException($_.Exception)
      throw
    } finally {
      $response.Dispose() # Ensure response is disposed
    }
    return $tcs.Task
    #endregion
  }

  [Job] CleanupAsync([CancellationToken]$cancellationToken) {
    $this.Logger.LogInformation("Cleaning up SSE transport...")
    $this.SetConnected($false)
    if ($null -ne $this._connectionCts -and !$this._connectionCts.IsCancellationRequested) {
      try { $this._connectionCts.Cancel() } catch {
        $null
      }
    }
    $receiveTaskToWait = $this._receiveTask
    $this._receiveTask = $null

    # Wait for receive task
    if ($null -ne $receiveTaskToWait -and !$receiveTaskToWait.IsCompleted) {
      $this.Logger.LogTrace("Waiting for SSE receive task to complete...")
      try {
        $receiveTaskToWait.Wait([TimeSpan]::FromSeconds(5)) # Simple timeout wait
      } catch [AggregateException] {
        # Check if it contains OperationCanceledException
        if ($_.Exception.InnerExceptions | Where-Object { $_ -is [OperationCanceledException] }) {
          $this.Logger.LogInformation("SSE receive task cancelled during cleanup.")
        } else {
          $this.Logger.LogError("Error waiting for SSE receive task during cleanup: $($_.Exception.Message)")
        }
      } catch {
        # Other exceptions like TimeoutException
        $this.Logger.LogWarning("Exception/Timeout waiting for SSE receive task during cleanup: $($_.Exception.Message)")
      }
    }

    try { $this._connectionCts.Dispose() } catch {
      $null
    }
    $this._connectionCts = $null
    $this.Logger.LogInformation("SSE transport cleanup complete.")
    return [Job]::CompletedTask
  }

  # Override DisposeAsync
  [Job] DisposeAsync() {
    # HttpClient might be shared, don't dispose here unless owned.
    # Need logic similar to C# ownsHttpClient flag.
    return $this.CleanupAsync([CancellationToken]::None)
  }
}

class McpSseClientTransport : McpClientTransport {
  hidden [McpSseClientTransportOptions] $_options
  hidden [McpServerConfig] $_serverConfig
  hidden [HttpClient] $_httpClient
  hidden [ILoggerFactory] $_loggerFactory
  hidden [bool] $_ownsHttpClient

  # Constructor that creates its own HttpClient
  McpSseClientTransport([McpSseClientTransportOptions]$options, [McpServerConfig]$serverConfig, [ILoggerFactory]$loggerFactory) : base($options, $serverConfig, ([HttpClient]::new()), $loggerFactory, $true) {
  }

  # Constructor that accepts an HttpClient
  McpSseClientTransport([McpSseClientTransportOptions]$options, [McpServerConfig]$serverConfig, [HttpClient]$httpClient, [ILoggerFactory]$loggerFactory, [bool]$ownsHttpClient = $false) {
    if ($null -eq $options) { throw [ArgumentNullException]::new("options") }
    if ($null -eq $serverConfig) { throw [ArgumentNullException]::new("serverConfig") }
    if ($null -eq $httpClient) { throw [ArgumentNullException]::new("httpClient") }
    $this._options = $options
    $this._serverConfig = $serverConfig
    $this._httpClient = $httpClient
    $this._loggerFactory = $loggerFactory
    $this._ownsHttpClient = $ownsHttpClient
  }

  [List[McpTransport]] ConnectAsync([CancellationToken]$cancellationToken) {
    $sessionTransport = [McpSseClientSessionTransport]::new($this._options, $this._serverConfig, $this._httpClient, $this._loggerFactory)
    $connectTask = $sessionTransport.ConnectAsync($cancellationToken)

    return $connectTask.ContinueWith({
        param($task)
        if ($task.IsFaulted) {
          try { $sessionTransport.DisposeAsync().Wait(1000) } catch {
            $null
          }
          throw $task.Exception.InnerExceptions[0]
        }
        if ($task.IsCanceled) {
          try { $sessionTransport.DisposeAsync().Wait(1000) } catch {
            $null
          }
          throw [OperationCanceledException]::new($cancellationToken)
        }
        return $sessionTransport
      }, $cancellationToken
    )
  }

  [Job] DisposeAsync() {
    if ($this._ownsHttpClient) {
      try { $this._httpClient.Dispose() } catch {
        $null
      }
    }
    return [Job]::CompletedTask
  }
}

# --- HttpListener SSE Server Transport ---
# This requires System.Net.HttpListener which might have platform/admin privilege requirements.

class McpHttpListenerSseServerSessionTransport : McpTransportBase {
  # Similar to StdioServerTransport but writes SSE events to output stream
  hidden [string] $_serverName
  hidden [Stream] $_responseStream # The stream from HttpListenerResponse
  hidden [SemaphoreSlim] $_sendLock = [SemaphoreSlim]::new(1, 1)
  hidden [CancellationTokenSource] $_sessionCts # Token for this specific session
  hidden [string] $_endpointName
  hidden [int] $_disposed = 0 # Added for dispose pattern

  McpHttpListenerSseServerSessionTransport([string]$serverName, [Stream]$responseStream, [ILoggerFactory]$loggerFactory) `
    : base($loggerFactory) {
    if ([string]::IsNullOrWhiteSpace($serverName)) { throw [ArgumentNullException]::new("serverName") }
    if ($null -eq $responseStream) { throw [ArgumentNullException]::new("responseStream") }
    $this._serverName = $serverName
    $this._responseStream = $responseStream
    $this._endpointName = "Server (SSE Session) ($($this._serverName))"
    $this.SetConnected($true) # Assume connected when created with a stream
    $this._sessionCts = [CancellationTokenSource]::new()
  }

  # Send endpoint event immediately upon connection (or handled by McpHttpListenerSseServerTransport?)
  [Job] SendEndpointEventAsync([string]$messageEndpointPath) {
    # Send SSE:
    # event: endpoint
    # data: /message (or absolute path)
    #
    return $this.SendSseEventAsync("endpoint", $messageEndpointPath, $this._sessionCts.Token)
  }

  # Override SendMessageAsync to write SSE formatted messages
  [Job] SendMessageAsync([McpIJsonRpcMessage]$message, [CancellationToken]$cancellationToken) {
    # Needs cancellation linked to _sessionCts?
    $linkedCts = $null
    $sendToken = [CancellationToken]::None
    try {
      $linkedCts = [CancellationTokenSource]::CreateLinkedTokenSource($cancellationToken, $this._sessionCts.Token)
      $sendToken = $linkedCts.Token
      $json = [JsonSerializer]::Serialize($message, [McpIJsonRpcMessage], [McpJsonUtilities]::DefaultOptions)
      return $this.SendSseEventAsync("message", $json, $sendToken)
    } finally {
      $linkedCts.Dispose()
    }
  }

  hidden [Job] SendSseEventAsync([string]$eventType, [string]$data, [CancellationToken]$cancellationToken) {
    #region SSE Send Event
    $tcs = [List[bool]]::new()
    $lockTaken = $false
    try {
      $this._sendLock.Wait($cancellationToken)
      $lockTaken = $true
      if (!$this.IsConnected) { throw [McpTransportException]::new("Transport session is not connected") }

      $sb = [StringBuilder]::new()
      $sb.AppendLine("event: $eventType")
      # Handle multi-line data
      $data.Split("`n") | ForEach-Object { $sb.AppendLine("data: $_") }
      $sb.AppendLine() # Blank line terminator

      $eventString = $sb.ToString()
      $this.Logger.LogTrace("Server sending SSE event:\n$eventString")
      $eventBytes = [Encoding]::UTF8.GetBytes($eventString)

      # Write async to response stream
      $writeTask = $this._responseStream.WriteAsync($eventBytes, 0, $eventBytes.Length, $cancellationToken)
      $writeTask.Wait($cancellationToken) # Blocking wait for simplicity

      $flushTask = $this._responseStream.FlushAsync($cancellationToken)
      $flushTask.Wait($cancellationToken) # Blocking wait

      $tcs.SetResult($true)
    } catch [OperationCanceledException] {
      $this.Logger.LogInformation("SSE send cancelled.")
      $tcs.SetCanceled($cancellationToken) # Use the token that caused cancellation
    } catch {
      $this.Logger.LogError("Failed to send SSE event: $($_.Exception.Message)")
      $this.SetConnected($false) # Assume stream is broken
      $tcs.SetException($_.Exception)
      # Don't rethrow from Send? Let caller handle? C# throws McpTransportException.
      # Throwing seems more consistent with other SendMessageAsync impls.
      throw [McpTransportException]::new("Failed to send SSE event", $_.Exception)
    } finally {
      if ($lockTaken) { $this._sendLock.Release() }
    }
    return $tcs.Task
    #endregion
  }

  # Needs to handle messages POSTed to the separate /message endpoint
  [Job] OnMessageReceivedAsync([McpIJsonRpcMessage]$message, [CancellationToken]$cancellationToken) {
    # Add message to the reader queue for the endpoint to process
    return $this.WriteMessageAsync($message, $cancellationToken)
  }

  [Job] DisposeAsync() {
    #region SSE Session Dispose
    $this.Logger.LogInformation("Disposing SSE Server Session transport...")
    if ([Interlocked]::Exchange([ref]$this._disposed, 1) -ne 0) { return [Job]::CompletedTask }

    $this.SetConnected($false)
    try { $this._sessionCts.Cancel() } catch {
      $null
    }

    # Don't close the _responseStream here, the HttpListener context owner should do that.
    # Dispose semaphore and CTS
    try { $this._sendLock.Dispose() } catch {
      $null
    }
    try { $this._sessionCts.Dispose() } catch {
      $null
    }

    # Dispose base (cleans up reader queue)
    return ([McpTransportBase]$this).DisposeAsync() # Call base explicitly
    #endregion
  }
}

class McpHttpListenerSseServerTransport : McpIServerTransport {
  hidden [string] $_serverName
  hidden [int] $_port
  hidden [HttpListener] $_listener
  hidden [ILoggerFactory] $_loggerFactory
  hidden [ILogger] $_logger
  hidden [CancellationTokenSource] $_serverShutdownCts
  hidden [Job] $_listenTask
  hidden [BlockingCollection[McpTransport]]$_incomingSessions # Queue for accepted sessions
  hidden [McpHttpListenerSseServerSessionTransport] $_currentSession # Single session support initially

  McpHttpListenerSseServerTransport([McpServerOptions]$serverOptions, [int]$port, [ILoggerFactory]$loggerFactory) : base($serverOptions.ServerInfo.Name, $port, $loggerFactory) {
    # Validation...
  }

  McpHttpListenerSseServerTransport([string]$serverName, [int]$port, [ILoggerFactory]$loggerFactory) {
    # Validation...
    $this._serverName = $serverName
    $this._port = $port
    $this._loggerFactory = $loggerFactory
    $this._logger = if ($loggerFactory) { $loggerFactory.CreateLogger($this.GetType().Name) } else { [NullLogger]::Instance }
    $this._serverShutdownCts = [CancellationTokenSource]::new()
    $this._incomingSessions = [BlockingCollection[McpTransport]]::new(1) # Bounded to 1 for single session start

    $this._listener = [HttpListener]::new()
    $prefix = "http://localhost:$($this._port)/" # Needs config for hostname/prefix
    $this._listener.Prefixes.Add($prefix)
    $this._logger.LogInformation("Starting HttpListener on $prefix")
    $this._listener.Start()
    $this._listenTask = [Job]::Run(
      [Action] { $this.ListenLoop($this._serverShutdownCts.Token) },
      [CancellationToken]::None # Run loop independently until server shutdown requested
    )
  }

  hidden ListenLoop([CancellationToken]$cancellationToken) {
    $this._logger.LogInformation("HttpListener entering listen loop...")
    while (!$cancellationToken.IsCancellationRequested -and $this._listener.IsListening) {
      try {
        # Async get context
        $contextTask = $this._listener.GetContextAsync()
        # Wait using Task.WhenAny with Delay to make it cancellable
        $delayTask = [Job]::Delay( - 1, $cancellationToken)
        $completedTask = [Job]::WhenAny($contextTask, $delayTask).GetAwaiter().GetResult()


        if ($cancellationToken.IsCancellationRequested) { break }
        if ($completedTask -eq $delayTask) { continue } # Cancellation occurred

        $context = $contextTask.GetAwaiter().GetResult()
        $request = $context.Request
        $this._logger.LogInformation("Received request: $($request.HttpMethod) $($request.Url.LocalPath)")

        # Process request in background task to avoid blocking listener
        $processTask = [Job]::Run(
          [Action] { $this.ProcessRequest($context, $cancellationToken) },
          $cancellationToken # Process request respecting overall shutdown token
        )
      } catch [HttpListenerException] {
        if ($cancellationToken.IsCancellationRequested) {
          $this.Logger.LogInformation("HttpListener exception during shutdown.")
        } else {
          $this.Logger.LogError("HttpListener exception: $($_.Exception.Message)")
        }
        break # Exit loop on listener error/stop
      } catch [OperationCanceledException] {
        $this.Logger.LogInformation("HttpListener listen loop cancelled.")
        break
      } catch {
        $this.Logger.LogError("Unexpected error in HttpListener loop: $($_.Exception.Message)")
        # Consider delay before retry? Or exit?
      }
    }
    $this._logger.LogInformation("HttpListener listen loop exited.")
    $this._incomingSessions.CompleteAdding() # Signal no more sessions
  }

  hidden ProcessRequest([HttpListenerContext]$context, [CancellationToken]$cancellationToken) {
    $request = $context.Request
    $response = $context.Response
    $localPath = $request.Url.LocalPath

    try {
      if ($request.HttpMethod -eq "GET" -and $localPath -eq "/sse") {
        # Configurable paths?
        $this.HandleSseConnection($context, $cancellationToken)
      } elseif ($request.HttpMethod -eq "POST" -and $localPath -eq "/message") {
        # Configurable paths?
        $this.HandleMessagePost($context, $cancellationToken).GetAwaiter().GetResult()
        # HandleMessagePost closes response
      } else {
        $this.Logger.LogWarning("Request path not found: $localPath")
        $response.StatusCode = [HttpStatusCode]::NotFound
        $response.Close()
      }
    } catch {
      $this.Logger.LogError("Error processing request $($request.Url): $($_.Exception.Message)")
      try {
        if (!$response.HeadersSent) { $response.StatusCode = [HttpStatusCode]::InternalServerError }
        $response.Close()
      } catch {
        $null
      } # Ignore errors closing response
    }
  }

  hidden HandleSseConnection([HttpListenerContext]$context, [CancellationToken]$cancellationToken) {
    $response = $context.Response
    $sessionTransport = $null
    $this.Logger.LogInformation("Handling SSE connection request.")

    try {
      # Dispose previous session if any (single session logic)
      $oldSession = $this._currentSession
      if ($null -ne $oldSession) {
        $this.Logger.LogWarning("New SSE connection replacing existing session.")
        try { $oldSession.DisposeAsync().Wait(1000) } catch {
          $null
        } # Dispose old one quickly
      }
      $this._currentSession = $null

      # Set SSE Headers
      $response.ContentType = "text/event-stream"
      $response.Headers.Add("Cache-Control", "no-cache")
      $response.Headers.Add("Connection", "keep-alive")
      $response.SendChunked = $true # Keep connection open

      # Create session transport
      $sessionTransport = [McpHttpListenerSseServerSessionTransport]::new(
        $this._serverName,
        $response.OutputStream, # Give it the output stream
        $this._loggerFactory
      )
      $this._currentSession = $sessionTransport

      # Send initial endpoint event
      $sessionTransport.SendEndpointEventAsync("/message").GetAwaiter().GetResult() # Path needs config

      # Add session to the queue for AcceptAsync
      if (!$this._incomingSessions.TryAdd($sessionTransport, [TimeSpan]::FromSeconds(1), $cancellationToken)) {
        $this.Logger.LogError("Failed to add new SSE session to acceptance queue (queue full or cancelled).")
        try { $sessionTransport.DisposeAsync().Wait(500) } catch {
          $null
        }
        $response.Abort() # Abort the connection
        $this._currentSession = $null # Clear current session again
        return
      }

      # Keep connection alive until client disconnects or server shuts down
      $cancellationToken.WaitHandle.WaitOne() | Out-Null # Block until cancelled

      $this.Logger.LogInformation("SSE connection closing.")
    } catch [OperationCanceledException] {
      $this.Logger.LogInformation("SSE connection handling cancelled.")
    } catch {
      $this.Logger.LogError("Error handling SSE connection: $($_.Exception.Message)")
    } finally {
      $this.Logger.LogTrace("Cleaning up SSE connection resources.")
      # Ensure session is disposed if loop exits
      if ($null -ne $sessionTransport -and $sessionTransport -eq $this._currentSession) {
        try { $sessionTransport.DisposeAsync().Wait(1000) } catch {
          $null
        }
        $this._currentSession = $null
      }
      try { $response.Close() } catch {
        $null
      }
    }
  }


  hidden [Job] HandleMessagePost([HttpListenerContext]$context, [CancellationToken]$cancellationToken) {
    # Read POST body, deserialize, pass to current session's OnMessageReceivedAsync
    $request = $context.Request
    $response = $context.Response
    $tcs = [List[bool]]::new()

    try {
      if ($null -eq $this._currentSession -or !$this._currentSession.IsConnected) {
        $this.Logger.LogWarning("Received POST message but no active SSE session.")
        $response.StatusCode = [HttpStatusCode]::BadRequest # Or ServiceUnavailable?
        $response.Close()
        $tcs.SetResult($false) # Indicate failure
        return $tcs.Task
      }
      $this.Logger.LogTrace("Handling POST to /message")
      # Read stream async? PowerShell stream reading can be tricky async.
      $json = ''
      $reader = [StreamReader]::new($request.InputStream, $request.ContentEncoding, $true, 1024, $true)
      # Leave stream open
      $json = $reader.ReadToEnd() # Read synchronously for simplicity

      $this.Logger.LogTrace("POST Body: $json")

      $message = [JsonSerializer]::Deserialize($json, [McpIJsonRpcMessage], [McpJsonUtilities]::DefaultOptions)

      if ($null -eq $message) {
        $this.Logger.LogError("Failed to deserialize POSTed message.")
        $response.StatusCode = [HttpStatusCode]::BadRequest
        $response.Close()
        $tcs.SetResult($false)
        return $tcs.Task
      }

      # Pass message to the active session transport's input queue
      $onReceivedTask = $this._currentSession.OnMessageReceivedAsync($message, $cancellationToken)
      $onReceivedTask.Wait($cancellationToken) # Wait for it to be queued

      # Send 202 Accepted
      $response.StatusCode = [HttpStatusCode]::Accepted
      $acceptedBytes = [Encoding]::UTF8.GetBytes("Accepted")
      $writeRespTask = $response.OutputStream.WriteAsync($acceptedBytes, 0, $acceptedBytes.Length, $cancellationToken)
      $writeRespTask.Wait($cancellationToken)
      $response.Close() # Close after writing response
      $tcs.SetResult($true) # Indicate success
    } catch {
      $this.Logger.LogError("Error handling POST message: $($_.Exception.Message)")
      try {
        if (!$response.HeadersSent) { $response.StatusCode = [HttpStatusCode]::InternalServerError }
        $response.Close()
      } catch {
        $null
      }
      $tcs.SetException($_.Exception)
    }
    return $tcs.Task
  }

  [List[McpTransport]] AcceptAsync([CancellationToken]$cancellationToken) {
    # Take one session from the queue
    $tcs = [List[McpTransport]]::new()
    try {
      $this.Logger.LogInformation("Waiting to accept incoming transport session...")
      # Take will block until an item is available or collection is completed/cancelled
      $transport = $null
      if ($this._incomingSessions.TryTake([ref]$transport, - 1, $cancellationToken)) {
        # Wait indefinitely with cancellation
        $this.Logger.LogInformation("Accepted incoming transport session.")
        $tcs.SetResult($transport)
      } else {
        # Should only happen if cancelled or completed
        if ($cancellationToken.IsCancellationRequested) {
          $tcs.SetCanceled($cancellationToken)
        } else {
          $this.Logger.LogWarning("AcceptAsync failed: Session queue completed without yielding a session.")
          $tcs.SetResult($null) # Signal no more sessions possible
        }
      }
    } catch [OperationCanceledException] {
      $this.Logger.LogInformation("AcceptAsync cancelled.")
      $tcs.SetCanceled($cancellationToken)
    } catch [InvalidOperationException] {
      # Thrown if CompleteAdding called and queue empty
      $this.Logger.LogWarning("AcceptAsync failed: Session queue completed.")
      $tcs.SetResult($null) # Signal no more sessions possible
    } catch {
      $this.Logger.LogError("Error in AcceptAsync: $($_.Exception.Message)")
      $tcs.SetException($_.Exception)
    }
    return $tcs.Task
  }

  [Job] DisposeAsync() {
    #region SSE Server Dispose
    $this.Logger.LogInformation("Disposing HttpListener SSE Server transport...")
    # Signal shutdown
    try { $this._serverShutdownCts.Cancel() } catch {
      $null
    }

    # Stop listener
    try {
      if ($null -ne $this._listener -and $this._listener.IsListening) {
        $this.Logger.LogTrace("Stopping HttpListener...")
        $this._listener.Stop()
        $this._listener.Close() # Close releases resources
      }
    } catch { $this.Logger.LogWarning("Exception stopping/closing HttpListener: $($_.Exception.Message)") }

    # Wait for listen task
    $listenTaskToWait = $this._listenTask
    if ($null -ne $listenTaskToWait -and !$listenTaskToWait.IsCompleted) {
      $this.Logger.LogTrace("Waiting for listener task to complete...")
      try {
        $listenTaskToWait.Wait([TimeSpan]::FromSeconds(5))
      } catch [AggregateException] {
        if ($_.Exception.InnerExceptions | Where-Object { $_ -is [OperationCanceledException] }) {
          $this.Logger.LogInformation("Listener task cancelled during cleanup.")
        } else { $this.Logger.LogError("Error waiting for Listener task during dispose: $($_.Exception.Message)") }
      } catch { $this.Logger.LogWarning("Exception/Timeout waiting for listener task during dispose: $($_.Exception.Message)") }
    }

    # Dispose current session if any
    $currentSess = $this._currentSession
    if ($null -ne $currentSess) {
      try { $currentSess.DisposeAsync().Wait(1000) } catch {
        $null
      }
    }

    # Dispose queue and CTS
    try { $this._incomingSessions.Dispose() } catch {
      $null
    }
    try { $this._serverShutdownCts.Dispose() } catch {
      $null
    }

    $this.Logger.LogInformation("HttpListener SSE Server transport disposed.")
    return [Job]::CompletedTask
    #endregion
  }
}

class McpClientFactory {
  # Needs logic to create appropriate IClientTransport based on options.TransportType
  static [List[McpClient]] CreateAsync(
    [McpServerConfig]$serverConfig,
    [McpClientOptions]$clientOptions = $null,
    [scriptblock]$createTransportFunc = $null, # Func<McpServerConfig, ILoggerFactory?, IClientTransport>
    [ILoggerFactory]$loggerFactory = $null,
    [CancellationToken]$cancellationToken = [CancellationToken]::None) {

    #region Client Factory CreateAsync
    if ($null -eq $serverConfig) { throw [ArgumentNullException]::new("serverConfig") }

    $tcs = [List[McpClient]]::new()

    # Task to perform creation and connection
    $creationTask = [Job]::Run([Action] {
        $resolvedClientOptions = $clientOptions ?? [McpClientFactory]::CreateDefaultClientOptions()
        $logger = if ($loggerFactory) { $loggerFactory.CreateLogger([McpClientFactory]) } else { [NullLogger]::Instance }
        $endpointName = "Client ($($serverConfig.Id): $($serverConfig.Name))"
        $logger.LogInformation("Creating client for $endpointName")

        $transport = $null
        $client = $null # Define client here for cleanup scope
        try {
          # Create Transport
          if ($null -ne $createTransportFunc) {
            $transport = . $createTransportFunc $serverConfig $loggerFactory
            if ($null -eq $transport) { throw [InvalidOperationException]::new("createTransportFunc returned null.") }
          } else {
            $transport = [McpClientFactory]::CreateTransport($serverConfig, $loggerFactory)
          }
          if ($null -eq $transport -or $transport -isnot [McpClientTransport]) { throw [InvalidOperationException]::new("Created transport does not implement McpClientTransport.") }

          # Create Client
          $client = [McpClient]::new($transport, $resolvedClientOptions, $serverConfig, $loggerFactory)

          # Connect Client
          try {
            $client.ConnectAsync($cancellationToken).GetAwaiter().GetResult() # Blocking wait within task
            $logger.LogInformation("Client $endpointName created and connected.")
            $tcs.SetResult($client) # Set final result
          } catch {
            $logger.LogError("Client connection failed during factory creation: $($_.Exception.Message)")
            # Ensure client and transport are disposed if connect fails
            try { $client.DisposeAsync().Wait($cancellationToken) } catch {
              $null
            }
            $tcs.SetException($_.Exception) # Propagate connection exception
          }
        } catch {
          $logger.LogError("Failed to create client transport or client: $($_.Exception.Message)")
          # Ensure transport is disposed if creation fails before client connection attempt
          if ($null -ne $transport -and $transport -is [IDisposable]) {
            try { $transport.DisposeAsync().Wait($cancellationToken) } catch {
              $null
            }
          }
          # Ensure client is disposed if created before transport failed
          if ($null -ne $client) {
            try { $client.DisposeAsync().Wait($cancellationToken) } catch {
              $null
            }
          }
          $tcs.SetException($_.Exception) # Propagate creation exception
        }
      }, $cancellationToken) # End Task.Run

    return $tcs.Task
    #endregion
  }

  static hidden [McpClientOptions] CreateDefaultClientOptions() {
    # Simplified - C# uses assembly info
    $procName = try { $MyInvocation.MyCommand.Name } catch { "McpPowerShellClient" }
    $version = "1.0.0" # Placeholder
    return [McpClientOptions]@{
      ClientInfo = [McpImplementation]::new($procName, $version)
      # Default Capabilities = null initially
    }
  }

  static hidden [McpClientTransport] CreateTransport([McpServerConfig]$serverConfig, [ILoggerFactory]$loggerFactory) {
    #region Create Transport Logic
    $transportTypeStr = try { [string]$serverConfig.TransportType } catch { '' } # Handle if not string/enum
    $logger = if ($loggerFactory) { $loggerFactory.CreateLogger("McpTransportFactory") } else { [NullLogger]::Instance }
    $logger.LogTrace("Creating transport of type '$transportTypeStr'")

    if ($transportTypeStr -eq [string][McpTransportTypes]::StdIo) {
      $command = $serverConfig.TransportOptions.command ?? $serverConfig.Location
      if ([string]::IsNullOrWhiteSpace($command)) { throw [ArgumentException]::new("Command/Location is required for stdio transport.") }
      $arguments = $serverConfig.TransportOptions.arguments
      $workingDir = $serverConfig.TransportOptions.workingDirectory
      # Extract env vars correctly
      $envVars = $null
      if ($null -ne $serverConfig.TransportOptions) {
        $envVars = @{}
        $serverConfig.TransportOptions.GetEnumerator() | Where-Object { $_.Key -like 'env:*' } | ForEach-Object {
          $envKey = $_.Key.Substring(4)
          $envVars[$envKey] = $_.Value
        }
        if ($envVars.Count -eq 0) { $envVars = $null }
      }

      $shutdownTimeoutStr = $serverConfig.TransportOptions.shutdownTimeout
      $shutdownTimeout = [TimeSpan]::FromSeconds(5) # Default
      if ($shutdownTimeoutStr -and [TimeSpan]::TryParse($shutdownTimeoutStr, [ref]$shutdownTimeout)) {
        # Parsed successfully, $shutdownTimeout updated
      }

      # C# has special handling for non-cmd commands on Windows (wrap with cmd /c)
      if (($env:OS -eq 'Windows_NT') -and $command -notmatch 'cmd(\.exe)?$' ) {
        $logger.LogTrace("Wrapping stdio command with 'cmd /c' on Windows.")
        $arguments = "/c `"$command`" $arguments".TrimEnd()
        $command = "cmd.exe"
      }

      $options = [McpStdioClientTransportOptions]@{
        Command              = $command
        Arguments            = $arguments
        WorkingDirectory     = $workingDir
        EnvironmentVariables = $envVars
        ShutdownTimeout      = $shutdownTimeout
      }
      return [McpStdioClientTransport]::new($options, $serverConfig, $loggerFactory)
    } elseif ($transportTypeStr -eq [string][McpTransportTypes]::Sse -or $transportTypeStr -eq 'http') {
      if ([string]::IsNullOrWhiteSpace($serverConfig.Location)) { throw [ArgumentException]::new("Location (URL) is required for SSE/HTTP transport.") }

      $connTimeout = [McpJsonUtilities]::ParseIntOrDefault($serverConfig.TransportOptions, "connectionTimeout", 30)
      $maxReconnect = [McpJsonUtilities]::ParseIntOrDefault($serverConfig.TransportOptions, "maxReconnectAttempts", 3)
      $reconnectDelay = [McpJsonUtilities]::ParseIntOrDefault($serverConfig.TransportOptions, "reconnectDelay", 5)
      # Extract headers correctly
      $headers = $null
      if ($null -ne $serverConfig.TransportOptions) {
        $headers = @{}
        $serverConfig.TransportOptions.GetEnumerator() | Where-Object { $_.Key -like 'header.*' } | ForEach-Object {
          $headerKey = $_.Key.Substring(7) # Length of "header."
          $headers[$headerKey] = $_.Value
        }
        if ($headers.Count -eq 0) { $headers = $null }
      }


      $options = [McpSseClientTransportOptions]@{
        ConnectionTimeout    = [TimeSpan]::FromSeconds($connTimeout)
        MaxReconnectAttempts = $maxReconnect
        ReconnectDelay       = [TimeSpan]::FromSeconds($reconnectDelay)
        AdditionalHeaders    = $headers
      }
      # HttpClient can be customized here if needed
      $httpClient = [HttpClient]::new() # Simplistic creation
      return [McpSseClientTransport]::new($options, $serverConfig, $httpClient, $loggerFactory, $true) # Owns HttpClient
    } else {
      throw [ArgumentException]::new("Unsupported transport type '$transportTypeStr'.")
    }
  }
}

# --- Server Factory ---
class McpServerFactory {
  static [McpServer] Create( # Return concrete type
    [McpTransport]$transport, # Already connected transport
    [McpServerOptions]$serverOptions,
    [ILoggerFactory]$loggerFactory = $null,
    [IServiceProvider]$serviceProvider = $null
  ) {
    if ($null -eq $transport) { throw [ArgumentNullException]::new("transport") }
    if ($null -eq $serverOptions) { throw [ArgumentNullException]::new("serverOptions") }
    # Add validation for ServerInfo?
    return [McpServer]::new($transport, $serverOptions, $loggerFactory, $serviceProvider)
  }

  static [List[McpServer]] AcceptAsync( # Return concrete type Task
    [McpIServerTransport]$serverTransport, # Listens for connections
    [McpServerOptions]$serverOptions,
    [ILoggerFactory]$loggerFactory = $null,
    [IServiceProvider]$serviceProvider = $null,
    [CancellationToken]$cancellationToken = [CancellationToken]::None
  ) {
    #region Server Factory AcceptAsync
    if ($null -eq $serverTransport) { throw [ArgumentNullException]::new("serverTransport") }
    if ($null -eq $serverOptions) { throw [ArgumentNullException]::new("serverOptions") }

    $tcs = [List[McpServer]]::new() # Task for McpServer
    # Task to perform accept and server creation
    $acceptTask = [Job]::Run([Action] {
        $mcpServer = $null
        try {
          # Create the server instance first, it will call Accept internally via RunAsync or explicitly
          $mcpServer = [McpServer]::new($serverTransport, $serverOptions, $loggerFactory, $serviceProvider)

          # Accept the session (this blocks until a client connects)
          $acceptSessionTask = $mcpServer.AcceptSessionAsync($cancellationToken)
          $acceptSessionTask.Wait($cancellationToken) # Blocking wait

          # Acceptance successful, return the server instance
          $tcs.SetResult($mcpServer)
        } catch [OperationCanceledException] {
          $logger = if ($loggerFactory) { $loggerFactory.CreateLogger([McpServerFactory]) } else { [NullLogger]::Instance }
          $logger.LogInformation("Server factory AcceptAsync cancelled.")
          if ($null -ne $mcpServer) {
            try { $mcpServer.DisposeAsync().Wait(1000) } catch {
              $null
            }
          }
          $tcs.SetCanceled($cancellationToken)
        } catch {
          # Acceptance failed or other error
          $logger = if ($loggerFactory) { $loggerFactory.CreateLogger([McpServerFactory]) } else { [NullLogger]::Instance }
          $logger.LogError("Error during server factory AcceptAsync: $($_.Exception.Message)")
          if ($null -ne $mcpServer) {
            try { $mcpServer.DisposeAsync().Wait(1000) } catch {
              $null
            }
          }
          $tcs.SetException($_.Exception) # Propagate exception
        }
      }, $cancellationToken)

    return $tcs.Task
    #endregion
  }
}

# --- Configuration & Hosting ---
# These heavily rely on Microsoft.Extensions.DependencyInjection and Hosting in C#.
# PowerShell equivalents would likely use module state or custom configuration functions.

# Represents McpServerHandlers - used internally by builder extensions
class McpServerHandlers {
  [scriptblock]$ListToolsHandler
  [scriptblock]$CallToolHandler
  [scriptblock]$ListPromptsHandler
  [scriptblock]$GetPromptHandler
  [scriptblock]$ListResourceTemplatesHandler
  [scriptblock]$ListResourcesHandler
  [scriptblock]$ReadResourceHandler
  [scriptblock]$SubscribeToResourcesHandler
  [scriptblock]$UnsubscribeFromResourcesHandler
  [scriptblock]$GetCompletionHandler
  [scriptblock]$SetLoggingLevelHandler

  # C# OverwriteWithSetHandlers logic applies handlers to McpServerOptions.Capabilities
  # Needs manual application in PS context before creating McpServer.
  [void] ApplyToOptions([McpServerOptions]$options) {
    # Ensure capabilities objects exist if handlers are set
    if ($this.ListToolsHandler -or $this.CallToolHandler) {
      if ($null -eq $options.Capabilities) { $options.Capabilities = [McpServerCapabilities]::new() }
      if ($null -eq $options.Capabilities.Tools) { $options.Capabilities.Tools = [McpToolsCapability]::new() }
      # Assign handlers directly to options for simplified PS model
      if ($this.ListToolsHandler) { $options.ListToolsHandler = $this.ListToolsHandler }
      if ($this.CallToolHandler) { $options.CallToolHandler = $this.CallToolHandler }
      # $options.Capabilities.Tools.ListChanged = $true # Assume dynamic if handlers set?
    }
    # Apply other handlers similarly
    if ($this.ListPromptsHandler -or $this.GetPromptHandler) {
      if ($null -eq $options.Capabilities) { $options.Capabilities = [McpServerCapabilities]::new() }
      if ($null -eq $options.Capabilities.Prompts) { $options.Capabilities.Prompts = [McpPromptsCapability]::new() }
      if ($this.ListPromptsHandler) { $options.ListPromptsHandler = $this.ListPromptsHandler }
      if ($this.GetPromptHandler) { $options.GetPromptHandler = $this.GetPromptHandler }
    }
    if ($this.ListResourceTemplatesHandler -or $this.ListResourcesHandler -or $this.ReadResourceHandler -or $this.SubscribeToResourcesHandler -or $this.UnsubscribeFromResourcesHandler) {
      if ($null -eq $options.Capabilities) { $options.Capabilities = [McpServerCapabilities]::new() }
      if ($null -eq $options.Capabilities.Resources) { $options.Capabilities.Resources = [McpResourcesCapability]::new() }
      if ($this.ListResourceTemplatesHandler) { $options.ListResourceTemplatesHandler = $this.ListResourceTemplatesHandler }
      if ($this.ListResourcesHandler) { $options.ListResourcesHandler = $this.ListResourcesHandler }
      if ($this.ReadResourceHandler) { $options.ReadResourceHandler = $this.ReadResourceHandler }
      if ($this.SubscribeToResourcesHandler) { $options.SubscribeToResourcesHandler = $this.SubscribeToResourcesHandler }
      if ($this.UnsubscribeFromResourcesHandler) { $options.UnsubscribeFromResourcesHandler = $this.UnsubscribeFromResourcesHandler }
      if ($this.SubscribeToResourcesHandler -or $this.UnsubscribeFromResourcesHandler) { $options.Capabilities.Resources.Subscribe = $true }
    }
    if ($this.GetCompletionHandler) { $options.GetCompletionHandler = $this.GetCompletionHandler }
    if ($this.SetLoggingLevelHandler) {
      if ($null -eq $options.Capabilities) { $options.Capabilities = [McpServerCapabilities]::new() }
      if ($null -eq $options.Capabilities.Logging) { $options.Capabilities.Logging = [McpLoggingCapability]::new() }
      $options.SetLoggingLevelHandler = $this.SetLoggingLevelHandler
    }
  }
}

#region    Main_class
# UsageExample
# .EXAMPLE
# Example usage with HTTP transport
# Write-Host "--- MCP PowerShell SDK Example Usage ---"
# $httpTransport = [HttpClientTransport]::new("http://localhost:8080/mcp")
# $mcp = [MCP]::Create($httpTransport)
# $mcp.Initialize()

# # Get available tools
# $tools = $mcp.ListTools()
# $tools.tools | ForEach-Object {
#     Write-Host "Tool: $($_.Name) - $($_.Description)"
# }

# # Call a tool
# $result = $mcp.CallTool("weatherTool", @{ location = "New York" })
# Write-Host "Tool result: $($result.Content.Text)"

# # Example with Stdio transport
# $serverParams = [ServerParameters]::new("node")
#     .AddArgs(@("mcp-server.js", "--port=8080"))
#     .AddEnv(@{ MCP_ENV = "production" })
#     .Build()

# $stdioTransport = [StdioClientTransport]::new($serverParams)
# $mcp = [MCP]::Create($stdioTransport)
# $mcp.Initialize()
#
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
#endregion Main_class



#endregion Classes
# Types that will be available to users when they import the module.
$typestoExport = @(
  [McpClient], [McpServer], [McpClientTool], [McpServerTool], [McpServerToolCollection],
  [McpServerConfig], [McpClientOptions], [McpServerOptions],
  [McpContent], [McpTool], [McpResource], [McpPrompt], [McpRoot],
  [McpImplementation], [McpClientCapabilities], [McpServerCapabilities],
  [McpRequestId],
  [McpCallToolRequestParams], [McpCallToolResponse],
  [McpError], [McpClientException], [McpServerException], [McpTransportException],
  [McpStdioTransport]
  # Add other important DTOs if needed
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