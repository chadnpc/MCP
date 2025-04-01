function Get-McpTransportType {
  return [System.Enum]::GetNames([McpTransportTypes])
}