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
using namespace System.Threading.Tasks
using namespace System.Collections.Generic
using namespace System.Management.Automation
using namespace System.Collections.Concurrent
using namespace System.Text.Json.Serialization

#Requires -Modules ThreadJob

#region Enums

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
  # Ordered from least to most severe
  Debug     # 0 - Detailed diagnostic information
  Info      # 1 - General operational information
  Notice    # 2 - Normal but significant condition
  Warning   # 3 - Indicates a potential problem
  Error     # 4 - A recoverable error occurred
  Critical  # 5 - Critical conditions, e.g., application component unavailable
  Alert     # 6 - Action must be taken immediately
  Emergency # 7 - System is unusable
}

# Simplified Transport Types
enum McpTransportType {
  Stdio
  Sse # Covers HTTP POST + SSE stream
  # Http # Removed for clarity, SSE is the primary HTTP-based method defined
}

enum McpErrorCodes {
  # Standard JSON-RPC
  ParseError = -32700
  InvalidRequest = -32600
  MethodNotFound = -32601
  InvalidParams = -32602
  InternalError = -32603
  ServerError = -32000

  # MCP Specific (Examples - Define as needed)
  RequestTimeout = -32001
  ResourceNotFound = -32002
  AccessDenied = -32003
}

enum McpStopReason {
  EndTurn
  StopSequence
  MaxTokens
}

#endregion Enums

#region Exceptions

class McpError : System.Exception {
  [int]$Code # Use McpErrorCodes enum values
  [object]$Data

  McpError([string]$message, [int]$code = [McpErrorCodes]::ServerError, [object]$data = $null) : base ($message) {
    $this.Code = $code
    $this.Data = $data
  }

  McpError([string]$message, [Exception]$innerException) : base ($message, $innerException) {
    $this.Code = [McpErrorCodes]::ServerError
    if ($innerException -is [McpError]) {
      $this.Code = $innerException.Code
      $this.Data = $innerException.Data
    }
  }

  [hashtable] ToJsonRpcErrorPayload() {
    return @{
      code    = $this.Code
      message = $this.Message
      data    = $this.Data # May be null, serializer should handle
    }
  }
}

class McpTransportException : McpError {
  McpTransportException([string]$message) : base($message, [McpErrorCodes]::InternalError) {}
  McpTransportException([string]$message, [Exception]$innerException) : base($message, $innerException) {
    # Inherit code if inner was McpError
    if ($this.InnerException -isnot [McpError]) {
      $this.Code = [McpErrorCodes]::InternalError
    }
  }
}

class McpClientException : McpError {
  McpClientException([string]$message, [int]$code = [McpErrorCodes]::ServerError, [object]$data = $null) : base($message, $code, $data) {}
  McpClientException([string]$message, [Exception]$innerException) : base($message, $innerException) {}
}

class McpServerException : McpError {
  McpServerException([string]$message, [int]$code = [McpErrorCodes]::ServerError, [object]$data = $null) : base($message, $code, $data) {}
  McpServerException([string]$message, [Exception]$innerException) : base($message, $innerException) {}
}

#endregion Exceptions

#region Core Data Structures (Messages, Content, Tools, Resources, etc.)

# Represents a JSON-RPC request identifier (string or number)
class McpRequestId {
  [object] $Value # Can be [string] or [long] or [int]

  McpRequestId([object]$Value) {
    if ($Value -is [string] -or $Value -is [long] -or $Value -is [int]) {
      # Store int as long for consistency internally? Or keep as is? Keeping as is for now.
      $this.Value = $Value
    } elseif ($null -eq $Value) {
      throw [ArgumentNullException]::new("RequestId value cannot be null.")
    } else {
      throw [ArgumentException]::new("RequestId must be a string or a number (long/int). Type was: $($Value.GetType().FullName)")
    }
  }

  [bool] IsString() { return $this.Value -is [string] }
  [bool] IsNumber() { return $this.Value -is [long] -or $this.Value -is [int] }
  [bool] IsValid() { return $null -ne $this.Value } # Should always be valid if constructor succeeds

  [string] AsString() {
    if (-not $this.IsString()) { throw [InvalidOperationException]::new("RequestId is not a string") }
    return [string]$this.Value
  }
  [long] AsNumber() {
    if (-not $this.IsNumber()) { throw [InvalidOperationException]::new("RequestId is not a number") }
    if ($this.Value -is [int]) { return [long]$this.Value }
    return [long]$this.Value
  }
  [string] ToString() { return "$($this.Value)" }

  static [McpRequestId] FromString([string]$value) { return [McpRequestId]::new($value) }
  static [McpRequestId] FromNumber([long]$value) { return [McpRequestId]::new($value) }
  static [McpRequestId] FromNumber([int]$value) { return [McpRequestId]::new($value) }
}

# Base for JSON-RPC messages (internal representation)
class McpJsonRpcMessageBase {
  [string] $Jsonrpc = "2.0"
}

class McpJsonRpcMessageWithId : McpJsonRpcMessageBase {
  [McpRequestId] $Id
}

class McpJsonRpcRequest : McpJsonRpcMessageWithId {
  [string] $Method
  [object] $Params # Can be object (hashtable/PSCustomObject) or array, null
}

class McpJsonRpcResponse : McpJsonRpcMessageWithId {
  [object] $Result # Can be any JSON value, including null
}

class McpJsonRpcErrorResponse : McpJsonRpcMessageWithId {
  [hashtable] $Error # Structure: { code = [int], message = [string], data = [object] }

  McpJsonRpcErrorResponse([McpRequestId]$id, [int]$code, [string]$message, [object]$data = $null) {
    $this.Id = $id
    $this.Error = @{
      code    = $code
      message = $message
    }
    if ($null -ne $data) {
      $this.Error.Add('data', $data)
    }
  }
  McpJsonRpcErrorResponse([McpRequestId]$id, [McpError]$mcpError) {
    $this.Id = $id
    $this.Error = $mcpError.ToJsonRpcErrorPayload()
  }
}

class McpJsonRpcNotification : McpJsonRpcMessageBase {
  [string] $Method
  [object] $Params # Can be object (hashtable/PSCustomObject) or array, null
}

# --- MCP Specific Payloads ---

# Simplified Implementation Info
class McpImplementation {
  [string] $Name
  [string] $Version

  McpImplementation([string]$Name, [string]$Version) {
    if ([string]::IsNullOrWhiteSpace($Name)) { throw [ArgumentNullException]::new("Name") }
    if ([string]::IsNullOrWhiteSpace($Version)) { throw [ArgumentNullException]::new("Version") }
    $this.Name = $Name
    $this.Version = $Version
  }
}

# Capabilities (Simplified structure)
class McpCapabilityBase { [bool]$ListChanged }
class McpRootsCapability : McpCapabilityBase {}
class McpSamplingCapability {
  # No properties currently
}
class McpLoggingCapability {
  # No properties currently
}
class McpPromptsCapability : McpCapabilityBase {}
class McpResourcesCapability : McpCapabilityBase { [bool]$Subscribe }
class McpToolsCapability : McpCapabilityBase {}

class McpClientCapabilities {
  [McpRootsCapability]$Roots = $null # Null unless enabled
  [McpSamplingCapability]$Sampling = $null # Null unless enabled
  [Dictionary[string, object]]$Experimental = $null
}

class McpServerCapabilities {
  [McpLoggingCapability]$Logging = $null # Null unless enabled
  [McpPromptsCapability]$Prompts = $null # Null unless enabled
  [McpResourcesCapability]$Resources = $null # Null unless enabled
  [McpToolsCapability]$Tools = $null # Null unless enabled
  [Dictionary[string, object]]$Experimental = $null
}

# --- Initialize ---
class McpInitializeRequestParams {
  [string] $ProtocolVersion
  [McpImplementation] $ClientInfo
  [McpClientCapabilities] $Capabilities
  # [object]$Trace # Removed, use Logging capability
  # [object]$WorkspaceFolders # Use Roots capability
}

class McpInitializeResult {
  [string]$ProtocolVersion
  [McpImplementation] $ServerInfo
  [McpServerCapabilities] $Capabilities
  [string]$Instructions # Optional hint for client (e.g. system prompt)
}

# --- Content & Resources ---
class McpAnnotations {
  [List[McpRole]]$Audience
  [double]$Priority # 0.0 to 1.0
}

class McpResourceContents {
  [string] $Uri # The URI of the specific content part
  [string]$MimeType
  # Content is one of the following:
  [string]$Text # For text/*
  [string]$Blob # For binary/* (Base64 encoded)

  # Common properties (optional)
  [McpAnnotations]$Annotations
}

class McpContent {
  [string]$Type # 'text', 'image', 'audio', 'resource' (future: 'video')
  # Based on Type, one of these will be populated:
  [string]$Text
  [string]$Data # Base64 for image/audio
  [string]$MimeType # Required for image/audio
  [McpResourceContents]$Resource # If Type is 'resource'

  # Optional
  [McpAnnotations]$Annotations
}

# For Lists
class McpPaginatedResult {
  [string]$NextCursor
}

class McpResource {
  [string]$Uri
  [string]$Name
  [string]$Description
  [string]$MimeType
  [long]$Size # Optional size in bytes
  [McpAnnotations]$Annotations
}

class McpListResourcesResult : McpPaginatedResult {
  [List[McpResource]]$Resources = [List[McpResource]]::new()
}

class McpResourceTemplate {
  [string]$UriTemplate # RFC 6570
  [string]$Name
  [string]$Description
  [string]$MimeType # Default MIME for resources generated from template
  [McpAnnotations]$Annotations
}

class McpListResourceTemplatesResult : McpPaginatedResult {
  [List[McpResourceTemplate]]$ResourceTemplates = [List[McpResourceTemplate]]::new()
}

# For Reads
class McpReadResourceRequestParams {
  [string]$Uri
  # [object]$Meta # Progress token etc. - Keep simple for now
}

class McpReadResourceResult {
  [List[McpResourceContents]]$Contents = [List[McpResourceContents]]::new()
}

# For Subscription
class McpSubscribeRequestParams {
  [string]$Uri
  # [object]$Meta
}
class McpUnsubscribeRequestParams {
  [string]$Uri
  # [object]$Meta
}
class McpResourceUpdatedNotificationParams {
  [string]$Uri
}

# --- Tools ---
class McpToolAnnotations {
  [string]$Title
  [bool]$DestructiveHint = $true
  [bool]$IdempotentHint = $false
  [bool]$OpenWorldHint = $true # E.g., web search
  [bool]$ReadOnlyHint = $false
}

# Using Hashtable for schema representation in PowerShell is often easiest
class McpTool {
  [string]$Name
  [string]$Description
  [hashtable]$InputSchema # Expects a JSON Schema structure (e.g., @{ type = 'object'; properties = @{...} })
  [McpToolAnnotations]$Annotations

  McpTool([string]$Name, [string]$Description, [hashtable]$InputSchema, [McpToolAnnotations]$Annotations = $null) {
    $this.Name = $Name
    $this.Description = $Description
    # Basic validation
    if ($null -eq $InputSchema -or $InputSchema.type -ne 'object') {
      throw [ArgumentException]::new("InputSchema must be a hashtable with type='object'.")
    }
    $this.InputSchema = $InputSchema
    $this.Annotations = $Annotations
  }
}

class McpListToolsResult : McpPaginatedResult {
  [List[McpTool]]$Tools = [List[McpTool]]::new()
}

class McpCallToolRequestParams {
  [string]$Name
  [hashtable]$Arguments # Arguments matching the tool's InputSchema
  # [object]$Meta
}

class McpCallToolResponse {
  [List[McpContent]]$Content = [List[McpContent]]::new()
  [bool]$IsError = $false
}

# --- Prompts ---
class McpPromptArgument {
  [string]$Name
  [string]$Description
  [bool]$Required
}

class McpPrompt {
  [string]$Name
  [string]$Description
  [List[McpPromptArgument]]$Arguments = [List[McpPromptArgument]]::new()
}

class McpListPromptsResult : McpPaginatedResult {
  [List[McpPrompt]]$Prompts = [List[McpPrompt]]::new()
}

class McpPromptMessage {
  [McpRole]$Role # 'user' or 'assistant'
  [McpContent]$Content # The actual message content
}

class McpGetPromptRequestParams {
  [string]$Name
  [hashtable]$Arguments
  # [object]$Meta
}

class McpGetPromptResult {
  [string]$Description # The resolved description (optional override)
  [List[McpPromptMessage]]$Messages = [List[McpPromptMessage]]::new()
}

# --- Logging ---
class McpLoggingMessageNotificationParams {
  [McpLoggingLevel]$Level
  [string]$Logger # Optional source identifier
  [string]$Data # The log message string
}

class McpSetLevelRequestParams {
  [McpLoggingLevel]$Level
}

# --- Sampling (Server requesting completion from Client) ---
class McpSamplingMessage {
  [McpRole]$Role
  [McpContent]$Content
}

class McpModelHint {
  [string]$Name # e.g., "claude-3", "sonnet"
}

class McpModelPreferences {
  [List[McpModelHint]]$Hints
  [double]$CostPriority # 0-1
  [double]$SpeedPriority # 0-1
  [double]$IntelligencePriority # 0-1

  # Validation could be added here if needed
}

class McpCreateMessageRequestParams {
  [List[McpSamplingMessage]]$Messages
  [string]$SystemPrompt
  [McpContextInclusion]$IncludeContext = [McpContextInclusion]::None
  [McpModelPreferences]$ModelPreferences
  [double]$Temperature # 0-1
  [int]$MaxTokens
  [List[string]]$StopSequences
  [hashtable]$Metadata # Provider specific
  # [object]$Meta
}

class McpCreateMessageResult {
  [string]$Model # Model identifier used by client
  [McpRole]$Role = [McpRole]::Assistant # Always assistant? Doc says user|assistant but context implies assistant
  [McpContent]$Content # The generated content
  [string]$StopReason # McpStopReason enum value or custom string
  # [object]$Usage # Token counts etc (optional)
}

# --- Roots ---
class McpRoot {
  [string]$Uri
  [string]$Name
  # [object]$Meta # Reserved
}
class McpListRootsResult {
  [List[McpRoot]]$Roots = [List[McpRoot]]::new()
  # [object]$Meta # Reserved
}
# RootsUpdatedNotification uses McpListRootsResult as params

# --- Empty Result Placeholder ---
class McpEmptyResult {}

#endregion Core Data Structures

#region Utilities (Logging, JSON)

class McpJsonUtilities {
  static [JsonSerializerOptions]$DefaultOptions

  static McpJsonUtilities() {
    $options = [JsonSerializerOptions]::new([JsonSerializerDefaults]::Web) # Web defaults are good (camelCase, etc.)
    # Use camelCase enum converter
    $options.Converters.Add([JsonStringEnumConverter]::new([JsonNamingPolicy]::CamelCase, $false))
    $options.DefaultIgnoreCondition = [JsonIgnoreCondition]::WhenWritingNull
    $options.NumberHandling = [JsonNumberHandling]::AllowReadingFromString -bor [JsonNumberHandling]::WriteAsString # Be flexible on read, write as string? Maybe just AllowReadingFromString.
    $options.PropertyNameCaseInsensitive = $true
    # $options.WriteIndented = $true # Useful for debugging transport
    [McpJsonUtilities]::DefaultOptions = $options
  }

  static [object] Deserialize([string]$json, [Type]$targetType) {
    if ([string]::IsNullOrWhiteSpace($json)) {
      return $null
    }
    try {
      return [JsonSerializer]::Deserialize($json, $targetType, [McpJsonUtilities]::DefaultOptions)
    } catch {
      # Log or handle error? Throw specific exception?
      Write-Warning "JSON Deserialization failed for type $($targetType.Name). Error: $($_.Exception.Message). JSON: $json"
      throw # Rethrow for now
    }
  }

  static [type] Deserialize([string]$json) {
    if ([string]::IsNullOrWhiteSpace($json)) {
      # Return default value for the type T
      return [type]::DefaultBinder
    }
    try {
      return [JsonSerializer]::Deserialize[T]($json, [McpJsonUtilities]::DefaultOptions)
    } catch {
      Write-Warning "JSON Deserialization failed for type T ($([type].Name)). Error: $($_.Exception.Message). JSON: $json"
      throw
    }
  }

  static [string] Serialize([object]$obj) {
    if ($null -eq $obj) { return $null }
    try {
      # Pass the actual type for potentially better serialization
      return [JsonSerializer]::Serialize($obj, $obj.GetType(), [McpJsonUtilities]::DefaultOptions)
    } catch {
      Write-Warning "JSON Serialization failed for object type $($obj.GetType().Name). Error: $($_.Exception.Message)"
      throw
    }
  }

  # Helper to deserialize Params field which arrives as JsonElement or PSCustomObject
  static [object] DeserializeParams([object]$paramsObject, [Type]$targetType) {
    if ($null -eq $paramsObject) { return $null }
    if ($paramsObject -is $targetType) { return $paramsObject } # Already correct type

    $json = $null
    if ($paramsObject -is [System.Text.Json.JsonElement]) {
      $json = $paramsObject.GetRawText()
    } elseif ($paramsObject -is [PSCustomObject] -or $paramsObject -is [hashtable]) {
      # Re-serialize PSCustomObject/Hashtable to get proper JSON string
      $json = [McpJsonUtilities]::Serialize($paramsObject)
    } elseif ($paramsObject -is [string]) {
      $json = $paramsObject # Assume it's already JSON
    } else {
      throw [ArgumentException]::new("Cannot deserialize Params of type $($paramsObject.GetType().Name) to $($targetType.Name)")
    }

    return [McpJsonUtilities]::Deserialize($json, $targetType)
  }
}

# Simple Logger Interface/Base
class McpLogger {
  Log([McpLoggingLevel]$level, [string]$message, [Exception]$exception = $null) {
    # Abstract method placeholder
    throw [NotImplementedException]::new("Log method must be implemented by derived logger class.")
  }
  [bool] IsEnabled([McpLoggingLevel]$level) {
    # Abstract method placeholder
    throw [NotImplementedException]::new("IsEnabled method must be implemented by derived logger class.")
  }
}

class McpConsoleLogger : McpLogger {
  [McpLoggingLevel]$MinimumLevel = [McpLoggingLevel]::Info
  [string]$Prefix

  McpConsoleLogger([McpLoggingLevel]$minLevel = [McpLoggingLevel]::Info, [string]$Prefix = "") {
    $this.MinimumLevel = $minLevel
    $this.Prefix = if ([string]::IsNullOrWhiteSpace($Prefix)) { "" } else { "[$Prefix] " }
  }

  Log([McpLoggingLevel]$level, [string]$message, [Exception]$exception = $null) {
    if ($level -ge $this.MinimumLevel) {
      $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
      $logLine = "$($this.Prefix)$timestamp [$($level.ToString().ToUpper())] - $message"
      switch ($level) {
        { $_ -ge [McpLoggingLevel]::Error } { Write-Error $logLine } # Write-Error for severity
        { $_ -eq [McpLoggingLevel]::Warning } { Write-Warning $logLine }
        default { Write-Host $logLine }
      }
      if ($null -ne $exception) {
        # Format exception details
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
  static [McpNullLogger] Instance() { return [McpNullLogger]::_instance }
  Log([McpLoggingLevel]$level, [string]$message, [Exception]$exception = $null) { } # No-op
  [bool] IsEnabled([McpLoggingLevel]$level) { return $false }
}

#endregion Utilities

#region Transport Abstraction and Implementations

# Base Transport Concept
class McpTransport : IDisposable {
  [bool]$IsConnected = $false
  # Queue for messages received *from* the transport, to be processed by the Endpoint
  [BlockingCollection[McpJsonRpcMessageBase]]$IncomingMessageQueue
  [McpLogger]$Logger
  [string]$TransportId # Unique ID for this transport instance

  McpTransport() {}
  McpTransport([McpLogger]$logger) {
    $this.Logger = $logger ?? [McpNullLogger]::Instance()
    # Using a ConcurrentQueue wrapped by BlockingCollection by default
    $this.IncomingMessageQueue = [BlockingCollection[McpJsonRpcMessageBase]]::new([ConcurrentQueue[McpJsonRpcMessageBase]]::new())
    $this.TransportId = [Guid]::NewGuid().ToString()
  }

  # Methods MUST be implemented by derived classes
  [void] Connect() { throw [NotImplementedException] }
  [void] SendMessage([McpJsonRpcMessageBase]$message) { throw [NotImplementedException] }
  # StartReceiving now implicit in Connect/Constructor for continuous transports like Stdio/SSE
  [void] StopReceiving() { throw [NotImplementedException] } # Signal background reader to stop
  [void] Dispose() {
    $this.Logger.Log([McpLoggingLevel]::Debug, "Disposing McpTransport ($($this.TransportId))...")
    $this.IsConnected = $false
    if ($null -ne $this.IncomingMessageQueue) {
      # Signal no more messages will be added, allows consumers to finish
      $this.IncomingMessageQueue.CompleteAdding()
      try { $this.IncomingMessageQueue.Dispose() } catch { $null }
      $this.IncomingMessageQueue = $null
    }
    # Ensure receiver is stopped (implementation specific)
    try { $this.StopReceiving() } catch { $null }
    $this.Logger.Log([McpLoggingLevel]::Debug, "McpTransport disposed ($($this.TransportId)).")
  }

  # Helper for derived classes to add received messages to the queue
  hidden ReceiveMessage([McpJsonRpcMessageBase]$message) {
    if ($null -ne $this.IncomingMessageQueue -and !$this.IncomingMessageQueue.IsAddingCompleted) {
      try {
        $this.IncomingMessageQueue.Add($message)
        $this.Logger.Log([McpLoggingLevel]::Debug, "($($this.TransportId)) Message added to incoming queue.")
      } catch [InvalidOperationException] {
        # This happens if CompleteAdding was called concurrently
        $this.Logger.Log([McpLoggingLevel]::Warning, "($($this.TransportId)) Attempted to add message after incoming queue was completed.")
      }
    } else {
      $this.Logger.Log([McpLoggingLevel]::Warning, "($($this.TransportId)) Incoming queue is null or completed, cannot add message.")
    }
  }
}

# --- Stdio Transport ---
class McpStdioTransport : McpTransport {
  hidden [string]$_command
  hidden [string]$_arguments
  hidden [string]$_workingDirectory
  hidden [hashtable]$_environmentVariables
  hidden [Process]$_process
  hidden [bool]$_isServerMode # True if using existing streams, false if launching client process
  hidden [StreamReader]$_reader # Reads from process stdout (client) or $stdin (server)
  hidden [StreamWriter]$_writer # Writes to process stdin (client) or $stdout (server)
  hidden [Job]$_stdoutJob # Job for reading stdout/stdin
  hidden [CancellationTokenSource]$_receiveCts # Controls the reading job

  # Constructor for Client mode (launches process)
  McpStdioTransport(
    [string]$command,
    [string]$arguments,
    [string]$workingDirectory,
    [hashtable]$environmentVariables,
    [McpLogger]$logger
  ) : base($logger) {
    $this._isServerMode = $false
    $this._command = $command
    $this._arguments = $arguments
    $this._workingDirectory = $workingDirectory
    $this._environmentVariables = $environmentVariables
    $this._receiveCts = [CancellationTokenSource]::new()
  }

  # Constructor for Server mode (uses provided streams)
  McpStdioTransport(
    [Stream]$inputStream, # Typically Console.OpenStandardInput()
    [Stream]$outputStream, # Typically Console.OpenStandardOutput()
    [McpLogger]$logger
  ) : base($logger) {
    $this._isServerMode = $true
    # Use UTF8 without BOM for reliable JSON-RPC line reading/writing
    $encoding = [UTF8Encoding]::new($false)
    $this._reader = [StreamReader]::new($inputStream ?? [Console]::OpenStandardInput(), $encoding, $false, 1024, $true) # Leave underlying stream open
    $this._writer = [StreamWriter]::new($outputStream ?? [Console]::OpenStandardOutput(), $encoding, 1024, $true) # Leave underlying stream open
    $this._writer.AutoFlush = $true # Ensure messages are sent promptly
    $this._receiveCts = [CancellationTokenSource]::new()
  }

  [void] Connect() {
    if ($this.IsConnected) {
      $this.Logger.Log([McpLoggingLevel]::Warning, "StdioTransport already connected.")
      return
    }
    $this.Logger.Log([McpLoggingLevel]::Info, "Connecting StdioTransport (ServerMode: $($this._isServerMode))...")

    if ($this._isServerMode) {
      # Already have streams, just start reading
      if ($null -eq $this._reader -or $null -eq $this._writer) {
        throw [InvalidOperationException]::new("Input/Output streams not available for Stdio server mode.")
      }
      $this.StartReceivingJob()
      $this.IsConnected = $true
      $this.Logger.Log([McpLoggingLevel]::Info, "StdioTransport connected in Server mode.")
    } else {
      # Client mode: Launch process
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
        }
        if ($null -ne $this._environmentVariables) {
          foreach ($key in $this._environmentVariables.Keys) {
            $startInfo.EnvironmentVariables[$key] = $this._environmentVariables[$key]
          }
        }

        $this._process = [Process]::new()
        $this._process.StartInfo = $startInfo

        # Stderr Handler
        $stderrHandler = [DataReceivedEventHandler] {
          param($sender, $e)
          if ($null -ne $e.Data) { $this.Logger.Log([McpLoggingLevel]::Error, "[STDERR] $($e.Data)") }
        }.GetNewClosure() # Capture $this (logger)
        $this._process.add_ErrorDataReceived($stderrHandler)

        $this.Logger.Log([McpLoggingLevel]::Information, "Starting process: $($startInfo.FileName) $($startInfo.Arguments)")
        if (-not $this._process.Start()) {
          throw [McpTransportException]::new("Failed to start process.")
        }

        $this._process.BeginErrorReadLine()
        # Use UTF8 without BOM
        $encoding = [UTF8Encoding]::new($false)
        $this._reader = [StreamReader]::new($this._process.StandardOutput.BaseStream, $encoding)
        $this._writer = [StreamWriter]::new($this._process.StandardInput.BaseStream, $encoding)
        $this._writer.AutoFlush = $true

        $this.StartReceivingJob()
        $this.IsConnected = $true
        $this.Logger.Log([McpLoggingLevel]::Info, "Stdio process started (PID: $($this._process.Id)), transport connected.")

      } catch {
        $this.Logger.Log([McpLoggingLevel]::Critical, "Failed to start stdio process: $($_.Exception.ToString())")
        try { $this.Dispose() } catch { $null } # Cleanup on failure
        throw [McpTransportException]::new("Failed to connect stdio transport.", $_.Exception)
      }
    }
  }

  [void] SendMessage([McpJsonRpcMessageBase]$message) {
    if (!$this.IsConnected -or $null -eq $this._writer) {
      throw [McpTransportException]::new("Cannot send message, stdio transport not connected or writer unavailable.")
    }
    if ($this._process -ne $null -and $this._process.HasExited) {
      throw [McpTransportException]::new("Cannot send message, stdio process has exited.")
    }
    try {
      $json = [McpJsonUtilities]::Serialize($message)
      $this.Logger.Log([McpLoggingLevel]::Debug, "($($this.TransportId)) >> $json")
      # WriteLine is synchronous, AutoFlush handles sending
      $this._writer.WriteLine($json)
    } catch [Exception] {
      # Catch broader exceptions like IOException
      $this.Logger.Log([McpLoggingLevel]::Error, "Failed to send message via stdio: $($_.Exception.Message)")
      # Consider triggering disconnect/cleanup
      try { $this.Dispose() } catch { $null }
      throw [McpTransportException]::new("Failed to send message via stdio.", $_.Exception)
    }
  }

  hidden StartReceivingJob() {
    if ($null -ne $this._stdoutJob) { return } # Already started

    $this.Logger.Log([McpLoggingLevel]::Information, "($($this.TransportId)) Starting stdio reading job.")
    $jobScript = {
      param($readerRef, $receiveCtsTokenRef, $transportRef) # Pass transport to call ReceiveMessage
      $ErrorActionPreference = 'Continue' # Don't stop job on single line parse error
      $transportRef.Logger.Log([McpLoggingLevel]::Debug, "($($transportRef.TransportId)) Stdio reading job started.")
      try {
        while (!$receiveCtsTokenRef.IsCancellationRequested) {
          $line = $null
          try {
            # ReadLineAsync with cancellation is complex to polyfill in PS reliably
            # Using synchronous ReadLine and checking token frequently
            if ($receiveCtsTokenRef.IsCancellationRequested) { break }
            $line = $readerRef.ReadLine() # Blocking read
          } catch [ObjectDisposedException] {
            $transportRef.Logger.Log([McpLoggingLevel]::Info, "($($transportRef.TransportId)) Stdio stream closed during read.")
            break
          } catch [IOException] {
            $transportRef.Logger.Log([McpLoggingLevel]::Error, "($($transportRef.TransportId)) Stdio IOException during read: $($_.Exception.Message)")
            break # Treat IO errors as fatal for the connection
          }

          if ($null -eq $line) {
            $transportRef.Logger.Log([McpLoggingLevel]::Info, "($($transportRef.TransportId)) Stdio input stream ended (EOF).")
            break
          }
          if ([string]::IsNullOrWhiteSpace($line)) { continue }

          $transportRef.Logger.Log([McpLoggingLevel]::Debug, "($($transportRef.TransportId)) << $line")
          try {
            # Attempt to deserialize
            $message = [McpJsonUtilities]::Deserialize($line, [McpJsonRpcMessageBase])
            if ($null -ne $message) {
              $transportRef.ReceiveMessage($message) # Add to the incoming queue
            } else {
              $transportRef.Logger.Log([McpLoggingLevel]::Warning, "($($transportRef.TransportId)) Failed to deserialize stdio line (result was null): '$line'")
            }
          } catch {
            $transportRef.Logger.Log([McpLoggingLevel]::Error, "($($transportRef.TransportId)) Failed to process stdio line: '$line'. Error: $($_.Exception.Message)")
            # Send ParseError back to client? Difficult from here. Log is essential.
            # Maybe add malformed message to queue with error marker? Complex.
          }
        }
      } catch [OperationCanceledException] {
        $transportRef.Logger.Log([McpLoggingLevel]::Info, "($($transportRef.TransportId)) Stdio reading job cancelled.")
      } catch {
        $transportRef.Logger.Log([McpLoggingLevel]::Error, "($($transportRef.TransportId)) Unhandled error in stdio reading job: $($_.Exception.ToString())")
      } finally {
        $transportRef.Logger.Log([McpLoggingLevel]::Info, "($($transportRef.TransportId)) Stdio reading job finished.")
        # Signal transport is disconnected if job finishes unexpectedly
        if ($transportRef.IsConnected) {
          $transportRef.Logger.Log([McpLoggingLevel]::Warning, "($($transportRef.TransportId)) Stdio reading job finished unexpectedly, triggering disconnect.")
          try { $transportRef.Dispose() } catch { $null } # Trigger full cleanup
        }
      }
    } # End Job ScriptBlock

    $this._stdoutJob = Start-ThreadJob -ScriptBlock $jobScript -ArgumentList @(
      $this._reader,
      $this._receiveCts.Token,
      $this # Pass the transport instance itself
    )
    Register-ObjectEvent -InputObject $this._stdoutJob -EventName StateChanged -Action {
      param($sender, $eventArgs)
      $job = $sender -as [System.Management.Automation.Job]
      $transport = $job.PSJobTypeName # Hack: Store transport ID here? Better way? Maybe store transport in $job.PrivateData?
      if ($job.State -in 'Failed', 'Stopped', 'Completed') {
        Write-Host "Stdio Job $($job.Id) finished with State: $($job.State)"
        # TODO: Trigger transport disconnect/cleanup from here if needed
        Unregister-Event -SourceIdentifier $eventArgs.SourceIdentifier
      }
    } -SourceIdentifier "StdioJob_$($this._stdoutJob.InstanceId)" | Out-Null
  }

  [void] StopReceiving() {
    $this.Logger.Log([McpLoggingLevel]::Info, "($($this.TransportId)) Stopping stdio receiving...")
    if ($null -ne $this._receiveCts -and !$this._receiveCts.IsCancellationRequested) {
      try { $this._receiveCts.Cancel() } catch { $null }
    }
    $job = $this._stdoutJob
    if ($null -ne $job) {
      try {
        $this.Logger.Log([McpLoggingLevel]::Debug, "($($this.TransportId)) Waiting for stdout job $($job.Id) to stop...")
        $job | Wait-Job -Timeout 3 | Out-Null
        if ($job.State -ne 'Stopped' -and $job.State -ne 'Completed' -and $job.State -ne 'Failed') {
          $this.Logger.Log([McpLoggingLevel]::Warning, "($($this.TransportId)) Stdout job $($job.Id) did not stop gracefully, removing.")
          $job | Remove-Job -Force
        } else {
          $this.Logger.Log([McpLoggingLevel]::Debug, "($($this.TransportId)) Stdout job $($job.Id) stopped.")
          $job | Remove-Job
        }
      } catch {
        $this.Logger.Log([McpLoggingLevel]::Error, "($($this.TransportId)) Error stopping/removing stdout job: $($_.Exception.Message)")
      }
      $this._stdoutJob = $null
    }
  }

  [void] Dispose() {
    if (!$this.IsConnected) { return } # Avoid double dispose actions
    $this.Logger.Log([McpLoggingLevel]::Information, "($($this.TransportId)) Disposing StdioTransport (ServerMode: $($this._isServerMode))...")
    # Stop reader job first
    $this.StopReceiving()

    # Signal queue completion BEFORE closing streams/process
    # This allows the Endpoint processor to finish gracefully
    if ($null -ne $this.IncomingMessageQueue) {
      $this.IncomingMessageQueue.CompleteAdding()
    }

    $proc = $this._process # Capture instance variable

    # Close streams BEFORE killing process (allows process to potentially exit cleanly)
    try { $this._writer.Dispose() } catch { $null }
    try { $this._reader.Dispose() } catch { $null }
    $this._writer = $null
    $this._reader = $null

    # Handle process if in client mode
    if (-not $this._isServerMode -and $null -ne $proc) {
      if (-not $proc.HasExited) {
        $this.Logger.Log([McpLoggingLevel]::Information, "($($this.TransportId)) Attempting to kill stdio process $($proc.Id)...")
        try {
          $proc.Kill($true) # Kill process tree
          $proc.WaitForExit(3000) # Wait briefly
          if (-not $proc.HasExited) {
            $this.Logger.Log([McpLoggingLevel]::Warning, "($($this.TransportId)) Process $($proc.Id) did not exit after kill signal.")
          }
        } catch {
          $this.Logger.Log([McpLoggingLevel]::Error, "($($this.TransportId)) Error killing stdio process: $($_.Exception.Message)")
        }
      }
      try { $proc.Dispose() } catch { $null }
      $this._process = $null
    }

    # Dispose CTS
    try { $this._receiveCts.Dispose() } catch { $null }
    $this._receiveCts = $null

    # Call base dispose AFTER specific cleanup
    # Base dispose will handle queue disposal.
    $this.Logger.Log([McpLoggingLevel]::Information, "($($this.TransportId)) StdioTransport disposed.")
  }
}

# --- SSE Transport (Placeholders - Complex to implement fully) ---
# Requires robust SSE parsing and HttpClient management
class McpSseClientTransport : McpTransport {
  # ... Placeholder ...
  [void] Connect() { Write-Warning "SSE Client Connect not fully implemented."; $this.IsConnected = $true }
  [void] SendMessage([McpJsonRpcMessageBase]$message) { Write-Warning "SSE Client SendMessage not fully implemented." }
  [void] StopReceiving() { Write-Warning "SSE Client StopReceiving not fully implemented." }
}

class McpSseServerTransport : McpTransport {
  # ... Placeholder ... Needs HttpListener or Kestrel integration
  [void] Connect() { Write-Warning "SSE Server Connect not fully implemented."; $this.IsConnected = $true }
  [void] SendMessage([McpJsonRpcMessageBase]$message) { Write-Warning "SSE Server SendMessage not fully implemented." }
  [void] StopReceiving() { Write-Warning "SSE Server StopReceiving not fully implemented." }
}

#endregion Transport Abstraction and Implementations

#region Endpoint (Combined Session/Endpoint Logic)

# Manages communication over a single transport connection
class McpEndpoint : IDisposable {
  hidden [McpTransport]$_transport
  hidden [McpLogger]$_logger
  hidden [string]$_endpointName # For logging
  # Stores TaskCompletionSource keyed by RequestId.ToString()
  hidden [ConcurrentDictionary[string, System.Threading.Tasks.TaskCompletionSource[McpJsonRpcMessageBase]]]$_pendingRequests
  hidden [int]$_nextRequestId = 0
  hidden [Job]$_messageProcessingJob # PowerShell Job for background processing
  hidden [CancellationTokenSource]$_endpointCts # Controls lifetime of processing
  hidden [bool]$_isDisposed = $false

  # Handlers (Set via Register methods)
  hidden [hashtable]$_requestHandlers = @{} # Method -> ScriptBlock(requestParams, cancellationToken) -> object (result)
  hidden [hashtable]$_notificationHandlers = @{} # Method -> List<ScriptBlock(notificationParams)>

  [bool]$IsConnected = $false
  [string]$RemoteProtocolVersion # Set during initialize
  [McpImplementation]$RemoteImplementationInfo # Set during initialize
  [object]$RemoteCapabilities # McpClientCapabilities or McpServerCapabilities, set during initialize

  McpEndpoint([McpTransport]$transport, [string]$endpointName, [McpLogger]$logger) {
    if ($null -eq $transport) { throw [ArgumentNullException]::new("transport") }
    $this._transport = $transport
    $this._endpointName = $endpointName ?? "Unnamed MCP Endpoint"
    $this._logger = $logger ?? [McpNullLogger]::Instance()
    $this._pendingRequests = [ConcurrentDictionary[string, System.Threading.Tasks.TaskCompletionSource[McpJsonRpcMessageBase]]]::new()
    $this._endpointCts = [CancellationTokenSource]::new()
  }

  [string] EndpointName() { return $this._endpointName }

  # --- Handler Registration ---
  [void] RegisterRequestHandler([string]$method, [scriptblock]$handler) {
    if ([string]::IsNullOrWhiteSpace($method)) { throw [ArgumentNullException]::new('method') }
    if ($null -eq $handler) { throw [ArgumentNullException]::new('handler') }
    # Consider locking if registration can happen after processing starts? For now, assume registration before StartProcessing.
    $this._requestHandlers[$method] = $handler
    $this._logger.Log([McpLoggingLevel]::Debug, "Registered request handler for '$method' on $($this._endpointName)")
  }

  [void] RegisterNotificationHandler([string]$method, [scriptblock]$handler) {
    if ([string]::IsNullOrWhiteSpace($method)) { throw [ArgumentNullException]::new('method') }
    if ($null -eq $handler) { throw [ArgumentNullException]::new('handler') }
    if (-not $this._notificationHandlers.ContainsKey($method)) {
      $this._notificationHandlers[$method] = [List[scriptblock]]::new()
    }
    $this._notificationHandlers[$method].Add($handler)
    $this._logger.Log([McpLoggingLevel]::Debug, "Added notification handler for '$method' on $($this._endpointName)")
  }

  # --- Lifecycle ---
  [void] StartProcessing() {
    if ($this._isDisposed) { throw [ObjectDisposedException]::new($this._endpointName) }
    if ($null -ne $this._messageProcessingJob) {
      $this._logger.Log([McpLoggingLevel]::Warning, "Message processing already started for $($this._endpointName)")
      return
    }
    if (-not $this._transport.IsConnected) {
      throw [InvalidOperationException]::new("Cannot start processing, transport is not connected.")
    }

    $this.IsConnected = $true # Mark endpoint as active
    $this._logger.Log([McpLoggingLevel]::Info, "Starting message processing job for $($this._endpointName)")

    # ScriptBlock for the background job
    $jobScriptBlock = {
      param(
        $transportRef, # McpTransport
        $endpointCtsTokenRef, # CancellationToken
        $endpointRef # McpEndpoint instance
      )
      $ErrorActionPreference = 'Stop' # Make job scriptblock exit on terminating errors? Or Continue? Continue safer for loop.
      $ErrorActionPreference = 'Continue'

      $logger = $endpointRef._logger
      $endpointName = $endpointRef._endpointName
      $requestHandlers = $endpointRef._requestHandlers
      $notificationHandlers = $endpointRef._notificationHandlers
      $pendingRequests = $endpointRef._pendingRequests

      $logger.Log([McpLoggingLevel]::Information, "Message processing job started for $endpointName")
      try {
        # Consume messages from the transport's queue
        # GetConsumingEnumerable blocks until a message is available or CompleteAdding is called
        foreach ($message in $transportRef.IncomingMessageQueue.GetConsumingEnumerable($endpointCtsTokenRef)) {
          $logger.Log([McpLoggingLevel]::Debug, "Job processing message type $($message.GetType().Name) for $endpointName")

          try {
            # Determine message type and handle
            if ($message -is [McpJsonRpcRequest]) {
              $endpointRef.HandleIncomingRequest($message, $endpointCtsTokenRef) # Fire-and-forget handler invocation
            } elseif (($message -is [McpJsonRpcResponse]) -or ($message -is [McpJsonRpcErrorResponse])) {
              $endpointRef.HandleIncomingResponse($message)
            } elseif ($message -is [McpJsonRpcNotification]) {
              $endpointRef.HandleIncomingNotification($message) # Fire-and-forget handler invocation
            } else {
              $logger.Log([McpLoggingLevel]::Warning, "Job received unhandled message type: $($message.GetType().Name)")
            }
          } catch {
            $logger.Log([McpLoggingLevel]::Error, "Error dispatching message in job: $($_.Exception.Message)")
            # Decide if the loop should continue or terminate on error
          }
        } # End foreach message
      } catch [OperationCanceledException] {
        $logger.Log([McpLoggingLevel]::Info, "Message processing job cancelled for $endpointName.")
      } catch [InvalidOperationException] {
        # Likely from GetConsumingEnumerable after CompleteAdding
        $logger.Log([McpLoggingLevel]::Info, "Message processing job queue completed for $endpointName.")
      } catch {
        $logger.Log([McpLoggingLevel]::Critical, "Fatal error in message processing job for $endpointName : $($_.Exception.ToString())")
        # Consider signalling endpoint failure externally?
      } finally {
        $logger.Log([McpLoggingLevel]::Info, "Message processing job finished for $endpointName.")
        # Ensure endpoint state reflects processing stopped
        $endpointRef.IsConnected = $false
      }
    } # End Job ScriptBlock

    # Start the job
    $job = Start-ThreadJob -ScriptBlock $jobScriptBlock -ArgumentList @(
      $this._transport,
      $this._endpointCts.Token,
      $this # Pass the endpoint instance itself
    )
    $this._messageProcessingJob = $job
    $this._logger.Log([McpLoggingLevel]::Information, "Message processing job $($job.Id) started for $($this._endpointName)")

    # Register cleanup for when the job finishes (optional but good practice)
    Register-ObjectEvent -InputObject $job -EventName StateChanged -Action {
      param($sender, $eventArgs)
      $jobState = $sender.State
      # How to get endpoint ref here? Maybe store ID in job name/PrivateData?
      # Write-Host "MCP Job $($sender.Id) State Changed: $jobState"
      if ($jobState -in 'Failed', 'Stopped', 'Completed') {
        # Write-Warning "MCP Job $($sender.Id) finished ($jobState). Consider checking endpoint state."
        Unregister-Event -SourceIdentifier $eventArgs.SourceIdentifier # Clean up event subscription
      }
    } -SourceIdentifier "McpJobCompletion_$($job.InstanceId)" | Out-Null
  }

  [void] StopProcessing() {
    if ($this._isDisposed) { return }
    $this._logger.Log([McpLoggingLevel]::Info, "Stopping message processing for $($this._endpointName)")
    $this.IsConnected = $false # Mark as disconnected

    if ($null -ne $this._endpointCts -and !$this._endpointCts.IsCancellationRequested) {
      try { $this._endpointCts.Cancel() } catch { $null }
    }
    $job = $this._messageProcessingJob
    if ($null -ne $job) {
      try {
        $this._logger.Log([McpLoggingLevel]::Debug, "Waiting for message processing job $($job.Id) to stop...")
        # Wait briefly, then remove if needed
        $job | Wait-Job -Timeout 3 | Out-Null
        if ($job.State -ne 'Stopped' -and $job.State -ne 'Completed' -and $job.State -ne 'Failed') {
          $this._logger.Log([McpLoggingLevel]::Warning, "Message processing job $($job.Id) did not stop gracefully, removing.")
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

  # --- Internal Message Handling (Called by the processing job) ---
  hidden [void] HandleIncomingRequest([McpJsonRpcRequest]$request, [CancellationToken]$jobCancellationToken) {
    $handler = $this._requestHandlers[$request.Method]
    if ($null -eq $handler) {
      $this._logger.Log([McpLoggingLevel]::Warning, "No request handler found for method '$($request.Method)'")
      $errorResponse = [McpJsonRpcErrorResponse]::new($request.Id, [McpErrorCodes]::MethodNotFound, "Method not found: $($request.Method)")
      try { $this._transport.SendMessage($errorResponse) } catch { $this._logger.LogError("Failed to send MethodNotFound error response: $($_.Exception.Message)") }
      return
    }

    # Invoke handler in a separate job to avoid blocking the processing loop
    # Pass necessary context: params and cancellation token
    $handlerJob = Start-ThreadJob -Name "Handler_$($request.Method)_$($request.Id)" -ScriptBlock {
      param($handlerScript, $requestParamsRaw, $handlerCancellationToken, $endpointLogger)
      $ErrorActionPreference = 'Stop' # Errors in handler should fail the job
      $handlerLogger = $endpointLogger # Use same logger for context
      $result = $null
      try {
        # Note: Deserialization of params happens *inside* the handler usually
        $handlerLogger.Log([McpLoggingLevel]::Debug, "Invoking handler...")
        # Handler signature: param($Params, $CancellationToken)
        # $handlerScript is the scriptblock stored in _requestHandlers
        $result = & $handlerScript $requestParamsRaw $handlerCancellationToken
        $handlerLogger.Log([McpLoggingLevel]::Debug, "Handler returned.")
        return $result # Output the result
      } catch [OperationCanceledException] {
        $handlerLogger.Log([McpLoggingLevel]::Warning, "Request handler cancelled.")
        throw # Rethrow cancellation to mark job as stopped/cancelled
      } catch {
        $handlerLogger.Log([McpLoggingLevel]::Error, "Request handler failed: $($_.Exception.ToString())")
        # Throw the exception so the calling code knows it failed
        throw $_.Exception # Throw the original exception
      }
    } -ArgumentList @(
      $handler,
      $request.Params, # Pass raw params
      $jobCancellationToken, # Pass the token from the processing loop
      $this._logger
    )

    # Register an action to send the response/error when the handler job completes
    Register-ObjectEvent -InputObject $handlerJob -EventName StateChanged -Action {
      param($sender, $eventArgs)
      $completedJob = $sender -as [System.Management.Automation.Job]
      $requestInfo = $completedJob.PrivateData # Retrieve request ID and transport
      $jobState = $completedJob.State

      if ($jobState -in 'Failed', 'Stopped', 'Completed') {
        Unregister-Event -SourceIdentifier $eventArgs.SourceIdentifier # Unsubscribe
        $transport = $requestInfo.Transport
        $requestId = $requestInfo.RequestId
        $logger = $requestInfo.Logger

        $responseToSend = $null
        if ($jobState -eq 'Completed') {
          $handlerResult = $completedJob | Receive-Job
          $responseToSend = [McpJsonRpcResponse]@{ Id = $requestId; Result = $handlerResult }
          $logger.Log([McpLoggingLevel]::Debug, "Handler job completed successfully for ID $($requestId).")
        } elseif ($jobState -eq 'Failed') {
          $errorRecord = $completedJob.Error[0]
          $exception = $errorRecord.Exception
          $logger.LogError("Handler job failed for ID $($requestId): $($exception.Message)")
          $mcpErrorCode = if ($exception -is [McpError]) { $exception.Code } else { [McpErrorCodes]::ServerError }
          $responseToSend = [McpJsonRpcErrorResponse]::new($requestId, $mcpErrorCode, $exception.Message, ($exception -as [McpError])?.Data)
        } else {
          # Stopped (Cancelled)
          $logger.LogWarning("Handler job stopped/cancelled for ID $($requestId).")
          # Send cancellation error? JSON-RPC doesn't define one. Use generic server error.
          $responseToSend = [McpJsonRpcErrorResponse]::new($requestId, [McpErrorCodes]::ServerError, "Request cancelled by server.")
        }

        # Send the response
        if ($transport.IsConnected) {
          try { $transport.SendMessage($responseToSend) } catch { $logger.LogError("Failed to send response/error for ID $($requestId): $($_.Exception.Message)") }
        } else { $logger.LogWarning("Cannot send response for ID $($requestId), transport disconnected.") }

        # Clean up the handler job object
        $completedJob | Remove-Job
      }
    } -SourceIdentifier "HandlerCompletion_$($handlerJob.InstanceId)" -MessageData @{RequestId = $request.Id; Transport = $this._transport; Logger = $this._logger } | Out-Null
  }

  hidden [void] HandleIncomingResponse([McpJsonRpcMessageBase]$message) {
    $messageWithId = $message -as [McpJsonRpcMessageWithId] # Should be Response or ErrorResponse
    if ($null -eq $messageWithId -or $null -eq $messageWithId.Id) {
      $this._logger.Log([McpLoggingLevel]::Error, "Received response/error with invalid or missing ID.")
      return
    }

    $idStr = $messageWithId.Id.ToString()
    $tcs = $null
    if ($this._pendingRequests.TryRemove($idStr, [ref]$tcs)) {
      if ($message -is [McpJsonRpcErrorResponse]) {
        $errorPayload = $message.Error
        $exception = [McpClientException]::new(
          $errorPayload.message,
          $errorPayload.code,
          $errorPayload.data
        )
        $this._logger.Log([McpLoggingLevel]::Warning, "Received error response for ID $idStr : Code $($errorPayload.code) - $($errorPayload.message)")
        $tcs.TrySetException($exception) | Out-Null
      } else {
        # Must be McpJsonRpcResponse
        $this._logger.Log([McpLoggingLevel]::Debug, "Received success response for ID $idStr.")
        $tcs.TrySetResult($message) | Out-Null # Set the whole message, sender will extract Result
      }
    } else {
      $this._logger.Log([McpLoggingLevel]::Warning, "Received response for unknown or timed-out request ID: $idStr")
    }
  }

  hidden [void] HandleIncomingNotification([McpJsonRpcNotification]$notification) {
    $handlers = $this._notificationHandlers[$notification.Method]
    if ($null -eq $handlers -or $handlers.Count -eq 0) {
      $this._logger.Log([McpLoggingLevel]::Debug, "No notification handler registered for method '$($notification.Method)'")
      return
    }

    $this._logger.Log([McpLoggingLevel]::Debug, "Invoking $($handlers.Count) notification handlers for '$($notification.Method)'")
    foreach ($handler in $handlers) {
      # Invoke handlers synchronously within the processing loop for simplicity
      # Can offload to ThreadJob if handlers are potentially slow
      try {
        # Handler signature: param($Params)
        & $handler $notification.Params # Pass raw params
      } catch {
        $this._logger.Log([McpLoggingLevel]::Error, "Notification handler for '$($notification.Method)' failed: $($_.Exception.ToString())")
      }
    }
  }

  # --- Public Methods for Sending ---

  # Returns a Job object that completes with the RESULT payload (deserialized)
  [System.Management.Automation.Job] SendRequestAsync(
    [string]$method,
    [object]$params, # Params object (hashtable, PSCustomObject, etc.)
    [Type]$expectedResultType, # Expected type of the 'result' field in the response
    [CancellationToken]$cancellationToken # For cancelling the *wait* for the response
  ) {
    if ($this._isDisposed) { throw [ObjectDisposedException]::new($this._endpointName) }
    if (!$this.IsConnected) { throw [McpTransportException]::new("Cannot send request, endpoint not connected.") }

    $requestIdNum = [Interlocked]::Increment([ref]$this._nextRequestId)
    $requestId = [McpRequestId]::FromNumber($requestIdNum)
    $idStr = $requestId.ToString()

    $request = [McpJsonRpcRequest]@{
      Method = $method
      Params = $params # Serializer handles converting this object
      Id     = $requestId
    }

    # TCS stores the *full* response message (success or error)
    $tcs = [System.Threading.Tasks.TaskCompletionSource[McpJsonRpcMessageBase]]::new(
      [System.Threading.Tasks.TaskCreationOptions]::RunContinuationsAsynchronously
    )

    if (!$this._pendingRequests.TryAdd($idStr, $tcs)) {
      throw [InvalidOperationException]::new("Request ID collision occurred: $idStr")
    }
    $this._logger.Log([McpLoggingLevel]::Debug, "Sending request '$method' ID '$idStr' via $($this._endpointName)")

    # Job to wait for the TCS result
    $waitJob = Start-ThreadJob -Name "Wait_Req_$idStr" -ScriptBlock {
      param($tcsToWaitFor, $cancelTokenForWait, $idForLog, $expectedType, $endpointLogger, $pendingReqs)
      $ErrorActionPreference = 'Stop'
      $task = $tcsToWaitFor.Task
      try {
        $endpointLogger.Log([McpLoggingLevel]::Debug, "Wait Job ($idForLog): Waiting for response...")

        # Wait on the Task, honouring the cancellation token
        $task.Wait($cancelTokenForWait) # Throws OperationCanceledException if token cancelled

        $endpointLogger.Log([McpLoggingLevel]::Debug, "Wait Job ($idForLog): Wait completed (Status: $($task.Status)).")

        # Check task status after wait
        if ($task.IsCanceled) {
          # Should have been caught by Wait() above, but double check
          throw [OperationCanceledException]::new($cancelTokenForWait)
        }
        if ($task.IsFaulted) {
          $endpointLogger.Log([McpLoggingLevel]::Error, "Wait Job ($idForLog): Received error response.")
          throw $task.Exception.InnerExceptions[0] # Throw the McpClientException set by HandleIncomingResponse
        }

        # Success - task has the full response message
        $responseMessage = $task.Result
        if ($responseMessage -isnot [McpJsonRpcResponse]) {
          # Should not happen if HandleIncomingResponse works correctly
          throw [McpClientException]::new("Wait Job ($idForLog): Received unexpected message type: $($responseMessage.GetType().Name)")
        }

        $endpointLogger.Log([McpLoggingLevel]::Debug, "Wait Job ($idForLog): Deserializing result to $($expectedType.Name)...")
        # Deserialize the 'result' field
        if ($null -eq $responseMessage.Result) {
          # Handle null result based on expected type
          if ($expectedType.IsValueType) {
            # Cannot return null for value type, maybe throw or return default?
            # Returning default is likely safest if expected.
            return ($expectedType)::new() # Default value type constructor
          } else {
            return $null
          }
        } else {
          return [McpJsonUtilities]::DeserializeParams($responseMessage.Result, $expectedType)
        }
      } catch [OperationCanceledException] {
        $endpointLogger.Log([McpLoggingLevel]::Warning, "Wait Job ($idForLog): Request cancelled.")
        throw # Rethrow cancellation
      } catch [Exception] {
        # Catches deserialization errors or McpClientException from faulted task
        $endpointLogger.Log([McpLoggingLevel]::Error, "Wait Job ($idForLog): Error processing response: $($_.Exception.Message)")
        throw # Rethrow exception
      } finally {
        # Ensure request is removed from pending dictionary, regardless of outcome
        $removedTcs = $null
        $pendingReqs.TryRemove($idForLog, [ref]$removedTcs) | Out-Null
        $endpointLogger.Log([McpLoggingLevel]::Debug, "Wait Job ($idForLog): Cleaned up pending request.")
      }
    } -ArgumentList @(
      $tcs, # TaskCompletionSource to wait on
      $cancellationToken, # CancellationToken for the wait
      $idStr, # Request ID string for logging
      $expectedResultType, # Type to deserialize result payload to
      $this._logger, # Logger
      $this._pendingRequests # Pending requests dictionary for cleanup
    )

    # Send the message *after* setting up the waiter job
    try {
      $this._transport.SendMessage($request)
    } catch {
      $this._logger.LogError("Failed to send request '$method' ID '$idStr': $($_.Exception.Message)")
      # Send failed, cancel the waiter TCS and remove from pending
      $tcs.TrySetException($_.Exception) | Out-Null
      $removedTcs = $null
      $this._pendingRequests.TryRemove($idStr, [ref]$removedTcs) | Out-Null
      # Stop the waiter job if it started? Might be tricky.
      # Rethrow the transport exception
      throw
    }

    # Return the job object to the caller
    return $waitJob
  }

  [void] SendNotification([string]$method, [object]$params) {
    if ($this._isDisposed) { throw [ObjectDisposedException]::new($this._endpointName) }
    if (!$this.IsConnected) {
      $this._logger.Log([McpLoggingLevel]::Warning, "Cannot send notification '$method', endpoint not connected.")
      # Optionally throw: throw [McpTransportException]::new("Cannot send notification, endpoint not connected.")
      return
    }

    $notification = [McpJsonRpcNotification]@{
      Method = $method
      Params = $params
    }
    $this._logger.Log([McpLoggingLevel]::Debug, "Sending notification '$method' via $($this._endpointName)")
    try {
      $this._transport.SendMessage($notification) # Fire and forget
    } catch {
      $this._logger.LogError("Failed to send notification '$method': $($_.Exception.Message)")
      # Optionally rethrow or trigger disconnect
    }
  }

  [void] Dispose() {
    if ($this._isDisposed) { return }
    $this._isDisposed = $true
    $this._logger.Log([McpLoggingLevel]::Info, "Disposing McpEndpoint: $($this._endpointName)")

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
    $this._logger.Log([McpLoggingLevel]::Info, "McpEndpoint disposed: $($this._endpointName)")
  }
}

#endregion Endpoint

#region Client API

# Configuration for creating a client
class McpClientOptions {
  [string]$ProtocolVersion = "2024-11-05"
  [TimeSpan]$InitializationTimeout = [TimeSpan]::FromSeconds(60)
  [McpImplementation]$ClientInfo # Info about *this* client implementation
  [McpClientCapabilities]$Capabilities # Capabilities *this* client supports
  [McpLogger]$Logger # Optional logger instance

  # Constructor with defaults
  McpClientOptions() {
    $procName = try { $MyInvocation.MyCommand.Name } catch { "McpPowerShellClient" }
    $version = "0.1.0" # Placeholder version
    $this.ClientInfo = [McpImplementation]::new($procName, $version)
    $this.Capabilities = [McpClientCapabilities]::new() # Default empty capabilities
    # Enable Roots capability by default for clients?
    $this.Capabilities.Roots = [McpRootsCapability]::new()
    # Enable Sampling capability by default?
    $this.Capabilities.Sampling = [McpSamplingCapability]::new()
  }
}

# Public Client Class
class McpClient : IDisposable {
  hidden [McpEndpoint]$_endpoint
  hidden [McpClientOptions]$_options
  hidden [McpLogger]$_logger

  # Populated after successful initialization
  hidden [McpServerCapabilities] $_ServerCapabilities
  hidden [McpImplementation] $_ServerInfo
  hidden [string] $_ServerInstructions

  # Constructor is internal - use New-McpClient factory function
  McpClient([McpEndpoint]$endpoint, [McpClientOptions]$options) {
    $this._endpoint = $endpoint
    $this._options = $options ?? [McpClientOptions]::new()
    $this._logger = $options.Logger ?? $endpoint._logger # Use endpoint's logger if available
    $this.SetupReadOnlyProperties()
  }

  hidden SetupReadOnlyProperties() {
    $props = $this.PSObject.Properties
    if ($null -eq $props["ServerCapabilities"]) { $props.Add([psscriptproperty]::new("ServerCapabilities", { return $this._ServerCapabilities })) }
    if ($null -eq $props["ServerInfo"]) { $props.Add([psscriptproperty]::new("ServerInfo", { return $this._ServerInfo })) }
    if ($null -eq $props["ServerInstructions"]) { $props.Add([psscriptproperty]::new("ServerInstructions", { return $this._ServerInstructions })) }
    if ($null -eq $props["IsConnected"]) { $props.Add([psscriptproperty]::new("IsConnected", { return $this._endpoint.IsConnected })) }
    if ($null -eq $props["ClientInfo"]) { $props.Add([psscriptproperty]::new("ClientInfo", { return $this._options.ClientInfo })) }
    if ($null -eq $props["ClientCapabilities"]) { $props.Add([psscriptproperty]::new("ClientCapabilities", { return $this._options.Capabilities })) }
  }

  # Internal method called by factory after successful initialize exchange
  hidden SetServerInfo([McpInitializeResult]$initResult) {
    $this._ServerCapabilities = $initResult.Capabilities
    $this._ServerInfo = $initResult.ServerInfo
    $this._ServerInstructions = $initResult.Instructions
    $this._endpoint.RemoteProtocolVersion = $initResult.ProtocolVersion
    $this._endpoint.RemoteImplementationInfo = $initResult.ServerInfo
    $this._endpoint.RemoteCapabilities = $initResult.Capabilities
    # Update properties again in case they weren't ready during constructor
    $this.SetupReadOnlyProperties()
  }

  # --- Public Methods ---

  [void] AddNotificationHandler([string]$method, [scriptblock]$handler) {
    $this._endpoint.RegisterNotificationHandler($method, $handler)
  }

  # Base request sender - returns Job which completes with the *deserialized result*
  [System.Management.Automation.Job] SendRequestAsync(
    [string]$method,
    [object]$params,
    [Type]$expectedResultType,
    [CancellationToken]$cancellationToken = [CancellationToken]::None
  ) {
    return $this._endpoint.SendRequestAsync($method, $params, $expectedResultType, $cancellationToken)
  }

  [void] SendNotification([string]$method, [object]$params) {
    $this._endpoint.SendNotification($method, $params)
  }

  # --- Simplified MCP API Methods ---
  # These return JOBS. Caller uses Wait-Job | Receive-Job.

  [System.Management.Automation.Job] PingAsync([CancellationToken]$cancellationToken = [CancellationToken]::None) {
    return $this.SendRequestAsync("ping", $null, [McpEmptyResult], $cancellationToken)
  }

  # ListTools needs to handle pagination internally if we want a simple API returning List<McpTool>
  # For now, provide method for one page. Add helper later if needed.
  [System.Management.Automation.Job] ListToolsPageAsync([string]$cursor = $null, [CancellationToken]$cancellationToken = [CancellationToken]::None) {
    $params = $null
    if ($cursor) { $params = @{ cursor = $cursor } }
    return $this.SendRequestAsync("tools/list", $params, [McpListToolsResult], $cancellationToken)
  }

  # Helper to get all tools (demonstrates pagination) - Returns Job -> List<McpTool>
  [System.Management.Automation.Job] ListAllToolsAsync([CancellationToken]$cancellationToken = [CancellationToken]::None) {
    $job = Start-ThreadJob -Name "McpListAllTools" -ScriptBlock {
      param($mcpClientRef, $cancelToken)
      $ErrorActionPreference = 'Stop'
      $allTools = [List[McpTool]]::new()
      $currentCursor = $null
      do {
        $pageJob = $mcpClientRef.ListToolsPageAsync($currentCursor, $cancelToken)
        $pageJob | Wait-Job -CancellationToken $cancelToken # Throws on cancel/fail
        $pageResult = $pageJob | Receive-Job
        $pageJob | Remove-Job

        if ($null -eq $pageResult) { throw [McpClientException]::new("ListTools response page was null.") }
        if ($null -ne $pageResult.Tools) {
          $allTools.AddRange($pageResult.Tools)
        }
        $currentCursor = $pageResult.NextCursor
      } while ($null -ne $currentCursor -and !$cancelToken.IsCancellationRequested)
      return $allTools
    } -ArgumentList @($this, $cancellationToken)
    return $job
  }


  [System.Management.Automation.Job] CallToolAsync([string]$toolName, [hashtable]$arguments, [CancellationToken]$cancellationToken = [CancellationToken]::None) {
    if ([string]::IsNullOrWhiteSpace($toolName)) { throw [ArgumentNullException]::new("toolName") }
    $params = [McpCallToolRequestParams]@{ Name = $toolName; Arguments = $arguments }
    return $this.SendRequestAsync("tools/call", $params, [McpCallToolResponse], $cancellationToken)
  }

  [System.Management.Automation.Job] ListResourcesPageAsync([string]$cursor = $null, [CancellationToken]$cancellationToken = [CancellationToken]::None) {
    $params = $null
    if ($cursor) { $params = @{ cursor = $cursor } }
    return $this.SendRequestAsync("resources/list", $params, [McpListResourcesResult], $cancellationToken)
  }

  # Add ListAllResourcesAsync helper if needed

  [System.Management.Automation.Job] ReadResourceAsync([string]$uri, [CancellationToken]$cancellationToken = [CancellationToken]::None) {
    if ([string]::IsNullOrWhiteSpace($uri)) { throw [ArgumentNullException]::new("uri") }
    $params = [McpReadResourceRequestParams]@{ Uri = $uri }
    return $this.SendRequestAsync("resources/read", $params, [McpReadResourceResult], $cancellationToken)
  }

  [System.Management.Automation.Job] SubscribeResourceAsync([string]$uri, [CancellationToken]$cancellationToken = [CancellationToken]::None) {
    if ([string]::IsNullOrWhiteSpace($uri)) { throw [ArgumentNullException]::new("uri") }
    $params = [McpSubscribeRequestParams]@{ Uri = $uri }
    # Subscribe often returns empty result on success
    return $this.SendRequestAsync("resources/subscribe", $params, [McpEmptyResult], $cancellationToken)
  }

  [System.Management.Automation.Job] UnsubscribeResourceAsync([string]$uri, [CancellationToken]$cancellationToken = [CancellationToken]::None) {
    if ([string]::IsNullOrWhiteSpace($uri)) { throw [ArgumentNullException]::new("uri") }
    $params = [McpUnsubscribeRequestParams]@{ Uri = $uri }
    return $this.SendRequestAsync("resources/unsubscribe", $params, [McpEmptyResult], $cancellationToken)
  }

  [System.Management.Automation.Job] ListPromptsPageAsync([string]$cursor = $null, [CancellationToken]$cancellationToken = [CancellationToken]::None) {
    $params = $null
    if ($cursor) { $params = @{ cursor = $cursor } }
    return $this.SendRequestAsync("prompts/list", $params, [McpListPromptsResult], $cancellationToken)
  }

  # Add ListAllPromptsAsync helper if needed

  [System.Management.Automation.Job] GetPromptAsync([string]$promptName, [hashtable]$arguments, [CancellationToken]$cancellationToken = [CancellationToken]::None) {
    if ([string]::IsNullOrWhiteSpace($promptName)) { throw [ArgumentNullException]::new("promptName") }
    $params = [McpGetPromptRequestParams]@{ Name = $promptName; Arguments = $arguments }
    return $this.SendRequestAsync("prompts/get", $params, [McpGetPromptResult], $cancellationToken)
  }

  # --- Roots Notifications (Client sends these) ---
  [void] SendRootsListChangedNotification() {
    if ($null -eq $this.ClientCapabilities.Roots -or !$this.ClientCapabilities.Roots.ListChanged) {
      $this._logger.Log([McpLoggingLevel]::Warning, "Cannot send roots/list_changed notification, client capability not enabled.")
      return
    }
    $this.SendNotification("notifications/roots/list_changed", $null)
  }

  # --- Sampling Request (Client receives these if supported) ---
  # Handled via RegisterRequestHandler("sampling/createMessage", ...)

  # --- Disposal ---
  [void] Dispose() {
    if ($null -ne $this._endpoint) {
      try { $this._endpoint.Dispose() } catch { $this._logger.Log([McpLoggingLevel]::Error, "Error disposing endpoint: $($_.Exception.Message)") }
      $this._endpoint = $null
    }
    $this._logger.Log([McpLoggingLevel]::Info, "McpClient disposed.")
  }
}

#endregion Client API

#region Server API

class McpServerOptions {
  [McpImplementation]$ServerInfo
  [McpServerCapabilities]$Capabilities
  [string]$ProtocolVersion = "2024-11-05"
  [TimeSpan]$InitializationTimeout = [TimeSpan]::FromSeconds(60)
  [string]$ServerInstructions = ''
  [McpLogger]$Logger

  McpServerOptions([string]$ServerName, [string]$ServerVersion) {
    if ([string]::IsNullOrWhiteSpace($ServerName)) { throw [ArgumentNullException]::new("ServerName") }
    if ([string]::IsNullOrWhiteSpace($ServerVersion)) { throw [ArgumentNullException]::new("ServerVersion") }
    $this.ServerInfo = [McpImplementation]::new($ServerName, $ServerVersion)
    $this.Capabilities = [McpServerCapabilities]::new() # Defaults to empty
  }
}

class McpServer : IDisposable {
  hidden [McpEndpoint]$_endpoint
  hidden [McpServerOptions]$_options
  hidden [McpLogger]$_logger

  # Populated after successful initialization
  hidden [McpClientCapabilities] $_ClientCapabilities
  hidden [McpImplementation] $_ClientInfo
  hidden [string] $_ClientProtocolVersion

  # Internal constructor - use Start-McpServer
  McpServer([McpEndpoint]$endpoint, [McpServerOptions]$options) {
    $this._endpoint = $endpoint
    $this._options = $options ?? (throw [ArgumentNullException]::new("options"))
    $this._logger = $options.Logger ?? $endpoint._logger
    $this.SetupReadOnlyProperties()
    $this.RegisterCoreHandlers()
  }

  hidden SetupReadOnlyProperties() {
    $props = $this.PSObject.Properties
    if ($null -eq $props["ClientCapabilities"]) { $props.Add([psscriptproperty]::new("ClientCapabilities", { return $this._ClientCapabilities })) }
    if ($null -eq $props["ClientInfo"]) { $props.Add([psscriptproperty]::new("ClientInfo", { return $this._ClientInfo })) }
    if ($null -eq $props["ServerOptions"]) { $props.Add([psscriptproperty]::new("ServerOptions", { return $this._options })) }
    if ($null -eq $props["IsConnected"]) { $props.Add([psscriptproperty]::new("IsConnected", { return $this._endpoint.IsConnected })) }
  }

  # Internal method called after receiving initialize request
  hidden SetClientInfo([string]$protocolVersion, [McpImplementation]$clientInfo, [McpClientCapabilities]$clientCaps) {
    $this._ClientProtocolVersion = $protocolVersion
    $this._ClientInfo = $clientInfo
    $this._ClientCapabilities = $clientCaps
    $this._endpoint.RemoteProtocolVersion = $protocolVersion
    $this._endpoint.RemoteImplementationInfo = $clientInfo
    $this._endpoint.RemoteCapabilities = $clientCaps
    $this.SetupReadOnlyProperties()
  }

  # --- Core Handlers ---
  hidden RegisterCoreHandlers() {
    # Initialize Handler
    $this._endpoint.RegisterRequestHandler("initialize", {
        param($paramsRaw, $cancellationToken)
        $this._logger.Log([McpLoggingLevel]::Info, "Received initialize request.")
        $initParams = $null
        try {
          $initParams = [McpJsonUtilities]::DeserializeParams($paramsRaw, [McpInitializeRequestParams])
        } catch {
          $this._logger.LogError("Failed to deserialize initialize params: $($_.Exception.Message)")
          throw [McpError]::new("Invalid initialize parameters", [McpErrorCodes]::InvalidParams)
        }

        # TODO: Protocol version negotiation? For now, assume compatibility.
        $this.SetClientInfo($initParams.ProtocolVersion, $initParams.ClientInfo, $initParams.Capabilities)
        $this._logger.Log([McpLoggingLevel]::Info, "Initialized with Client: $($this._ClientInfo.Name) v$($this._ClientInfo.Version) (Proto: $($this._ClientProtocolVersion))")

        # Return InitializeResult
        return [McpInitializeResult]@{
          ProtocolVersion = $this._options.ProtocolVersion
          ServerInfo      = $this._options.ServerInfo
          Capabilities    = $this._options.Capabilities
          Instructions    = $this._options.ServerInstructions
        }
      })

    # Initialized Notification Handler (required by spec)
    $this._endpoint.RegisterNotificationHandler("initialized", {
        param($params) # Params are typically null/empty
        $this._logger.Log([McpLoggingLevel]::Info, "Received initialized notification from client. Connection ready.")
        # Server can now send requests/notifications if needed
      })

    # Ping Handler
    $this._endpoint.RegisterRequestHandler("ping", {
        param($params, $cancellationToken)
        $this._logger.Log([McpLoggingLevel]::Debug, "Received ping request.")
        return [McpEmptyResult]::new() # Respond with empty result for ping
      })
  }

  # --- Public Methods ---

  # Register handlers for specific MCP methods (e.g., "tools/list")
  [void] RegisterRequestHandler([string]$method, [scriptblock]$handler) {
    # Allow overwriting core handlers? Maybe block "initialize", "initialized", "ping"?
    if ($method -in 'initialize', 'initialized', 'ping') {
      throw [ArgumentException]::new("Cannot overwrite core protocol handler for '$method'.")
    }
    # Handler signature: param($Params, $CancellationToken) -> $ResultObject
    $this._endpoint.RegisterRequestHandler($method, $handler)
  }

  [void] RegisterNotificationHandler([string]$method, [scriptblock]$handler) {
    # Handler signature: param($Params)
    $this._endpoint.RegisterNotificationHandler($method, $handler)
  }

  # Send notification to the client
  [void] SendNotification([string]$method, [object]$params) {
    $this._endpoint.SendNotification($method, $params)
  }

  # Send request to the client (e.g., for sampling) - Returns Job
  [System.Management.Automation.Job] SendRequestAsync(
    [string]$method,
    [object]$params,
    [Type]$expectedResultType,
    [CancellationToken]$cancellationToken = [CancellationToken]::None
  ) {
    return $this._endpoint.SendRequestAsync($method, $params, $expectedResultType, $cancellationToken)
  }

  [void] Dispose() {
    if ($null -ne $this._endpoint) {
      try { $this._endpoint.Dispose() } catch { $this._logger.Log([McpLoggingLevel]::Error, "Error disposing endpoint: $($_.Exception.Message)") }
      $this._endpoint = $null
    }
    $this._logger.Log([McpLoggingLevel]::Info, "McpServer disposed.")
  }
}
#endregion Server API


#endregion Example Usage

# .SYNOPSIS
#   Model Context Protocol
# .DESCRIPTION
#   Provides basic MCP implementation, allowing creation of MCP servers and clients.
class MCP {
  static [Stream]$stdin = ([ref][Console]::OpenStandardInput()).Value
  static [Stream]$stdout = ([ref][Console]::OpenStandardOutput()).Value
  # .SYNOPSIS
  #   Provides static factory methods to create MCP Clients and start MCP Servers.
  # .DESCRIPTION
  #   This class acts as the entry point for the MCP PowerShell SDK,
  #   encapsulating the logic for initializing client and server connections.

  # Returns a fully connected and initialized McpClient object.
  static [McpClient] CreateClient(
    [string]$Command, # e.g., 'node', 'python', 'path/to/server.exe'
    [string[]]$Arguments,
    [string]$WorkingDirectory,
    [hashtable]$EnvironmentVariables,
    [McpClientOptions]$Options,
    [McpLogger]$Logger,
    [int]$ConnectTimeoutSeconds = 30 # Timeout for connection and initialize
  ) {
    $clientOptions = $Options ?? [McpClientOptions]::new()
    $clientLogger = $Logger ?? $clientOptions.Logger ?? [McpConsoleLogger]::new([McpLoggingLevel]::Info, "MCP-Client")
    $clientOptions.Logger = $clientLogger # Ensure options has logger

    $endpointName = "Client ($($clientOptions.ClientInfo.Name) v$($clientOptions.ClientInfo.Version) for $Command)"
    $client = $null
    $transport = $null

    try {
      $clientLogger.Log([McpLoggingLevel]::Info, "Creating Stdio transport for $Command")
      # Using Stdio Client Mode constructor
      $transport = [McpStdioTransport]::new(
        $Command,
                ($Arguments -join ' '),
        $WorkingDirectory,
        $EnvironmentVariables,
        $clientLogger
      )

      $clientLogger.Log([McpLoggingLevel]::Info, "Creating endpoint: $endpointName")
      $endpoint = [McpEndpoint]::new($transport, $endpointName, $clientLogger)

      # Create the McpClient instance (doesn't connect yet)
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
      # Create a CancellationTokenSource for the timeout
      $cts = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($ConnectTimeoutSeconds))
      $initJob = $null
      try {
        $initJob = $client.SendRequestAsync("initialize", $initParams, [McpInitializeResult], $cts.Token)
        $initJob | Wait-Job -CancellationToken $cts.Token # Wait-Job respects the token for cancellation

        if ($initJob.State -eq 'Failed') { throw $initJob.Error[0].Exception }
        if ($initJob.State -ne 'Completed') { throw [TimeoutException]::new("Timeout or cancellation waiting for InitializeResult.") }

        $initResult = $initJob | Receive-Job

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
      } finally {
        if ($null -ne $initJob) { $initJob | Remove-Job }
        if ($null -ne $cts) { $cts.Dispose() }
      }
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

  # Static method to start a server listening (currently Stdio only).
  # Returns an McpServer instance ready to have handlers registered.
  # The caller's script must remain running for the server to operate.
  static [McpServer] StartServer([McpServerOptions]$Options, [Stream]$InputStream, [Stream]$OutputStream) {
    # TODO: Add params for other transports later (e.g., -Port for SSE)
    $serverOptions = $Options # Use provided options
    $serverLogger = $serverOptions.Logger ?? [McpConsoleLogger]::new([McpLoggingLevel]::Info, "MCP-Server")
    $serverOptions.Logger = $serverLogger # Ensure options has logger

    $endpointName = "Server ($($serverOptions.ServerInfo.Name) v$($serverOptions.ServerInfo.Version))"
    $server = $null
    $transport = $null

    try {
      # --- Transport Creation (Stdio Server Mode) ---
      $serverLogger.Log([McpLoggingLevel]::Info, "Creating Stdio server transport using console streams.")
      if (($InputStream -eq [MCP]::stdin -and [Console]::IsInputRedirected) -or ($OutputStream -eq [MCP]::stdout -and ([Console]::IsOutputRedirected -or [Console]::IsErrorRedirected))) {
        $serverLogger.Log([McpLoggingLevel]::Warning, "Console streams appear redirected. Stdio transport might not work as expected.")
      }
      # Using Stdio Server Mode constructor
      $transport = [McpStdioTransport]::new(
        $InputStream,
        $OutputStream,
        $serverLogger
      )

      # --- Endpoint & Server Creation ---
      $serverLogger.Log([McpLoggingLevel]::Info, "Creating server endpoint: $endpointName")
      $endpoint = [McpEndpoint]::new($transport, $endpointName, $serverLogger)

      # Create McpServer (registers core handlers like 'initialize')
      $server = [McpServer]::new($endpoint, $serverOptions)

      # --- Start Connection & Processing ---
      $serverLogger.Log([McpLoggingLevel]::Info, "Connecting server transport (starting input reader)...")
      $transport.Connect() # Starts the reading job

      $serverLogger.Log([McpLoggingLevel]::Info, "Starting server endpoint processing...")
      $endpoint.StartProcessing() # Starts the message handling job

      $serverLogger.Log([McpLoggingLevel]::Info, "MCP Server started and waiting for client 'initialize' request.")

      # Return the server object. Caller registers handlers and keeps script alive.
      return $server
    } catch {
      $serverLogger.Log([McpLoggingLevel]::Critical, "Failed to start MCP server: $($_.Exception.ToString())")
      # Ensure cleanup
      if ($null -ne $server) { try { $server.Dispose() } catch { $null } }
      elseif ($null -ne $transport) { try { $transport.Dispose() } catch { $null } }
      throw # Rethrow
    }
  }
}

#endregion Main_class
#endregion Classes

# Types that will be available to users when they import the module.
$typestoExport = @(
  [MCP], [McpClient], [McpServer]
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