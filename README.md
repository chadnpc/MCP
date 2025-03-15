
# [MCP](https://www.powershellgallery.com/packages/MCP)

Provides core framework for building MCP-compliant AI agents and tools in PowerShell.

[![Build Module](https://github.com/chadnpc/MCP/actions/workflows/build_module.yaml/badge.svg)](https://github.com/chadnpc/MCP/actions/workflows/build_module.yaml)
[![Downloads](https://img.shields.io/powershellgallery/dt/MCP.svg?style=flat&logo=powershell&color=blue)](https://www.powershellgallery.com/packages/MCP)

## Usage

```PowerShell
Install-Module MCP
```

then

```PowerShell
Import-Module MCP
# do stuff here.
```

## v0.1.0 Changelog

1. **Core Protocol Implementation**
   - JSON-RPC 2.0 compliant message classes (`JSONRPCRequest`, `JSONRPCResponse`, `JSONRPCNotification`)
   - Full MCP enumeration support (`ErrorCodes`, `Role`, `LoggingLevel`, etc.)
   - Protocol version negotiation (`2024-11-05` as default)

2. **Session Management**
   - `McpSession` class with:
     - Connection lifecycle management (connect/reconnect/close)
     - Async message queuing and processing
     - Request/response correlation
     - Notification handler registry

3. **Transport Layer**
   - `StdioClientTransport` for process-based communication
   - `HttpClientTransport` for HTTP/SSE streaming
   - Thread-safe message serialization/deserialization

4. **Type Safety & Serialization**
   - `ObjectMapper` class for JSON ↔ POCO conversion
   - Automatic enum parsing
   - Nested object support in `JsonSchema`

5. **Error Handling**
   - Structured `McpError` exceptions
   - Protocol-compliant error codes
   - Timeout and cancellation support

---

### **Limitations and TODOs**
- HTTP transport lacks retry logic
- Limited schema validation for tool inputs
- Async/await pattern requires PowerShell 7+
- Server-side implementation
- Advanced resource templating
- Built-in telemetry
- CI/CD pipeline support

## License

This project is licensed under the [WTFPL License](LICENSE).
