function Get-McpLoggingLevel {
  return [System.Enum]::GetNames([McpLoggingLevel])
}