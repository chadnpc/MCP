function Get-McpRole {
  <#
  .SYNOPSIS
  Gets the names of the valid MCP roles.
  .DESCRIPTION
  Returns the string names defined in the McpRole enum ('User', 'Assistant').
  .EXAMPLE
  Get-McpRole
  .OUTPUTS
  [string[]]
  #>
  return [System.Enum]::GetNames([McpRole])
}