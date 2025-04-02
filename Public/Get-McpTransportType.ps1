function Get-McpTransportType {
  <#
  .SYNOPSIS
  Gets the names of the valid MCP transport types.
  .DESCRIPTION
  Returns the string names defined in the McpTransportType enum (e.g., 'Stdio', 'Sse').
  .EXAMPLE
  Get-McpTransportType
  .OUTPUTS
  [string[]]
  #>
  # Ensure the enum name matches the definition in MCP.psm1
  return [System.Enum]::GetNames([McpTransportType])
}