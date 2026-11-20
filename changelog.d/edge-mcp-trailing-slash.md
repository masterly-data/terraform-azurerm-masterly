### Fixed

- **`ca-edge` no longer sends MCP and SDK clients to an address they cannot reach.** A request to
  exactly `/mcp` is now forwarded to `ca-api` as `/mcp/`, so `ca-api` no longer redirects it, and
  `/mcp` works with or without the trailing slash. Any redirect `ca-api` does send whose `Location`
  names the internal host the edge forwards to (`http://ca-api`, or `https://ca-api.<app environment
  domain>` with `api_environment = "app"`) is rewritten to a reference relative to the edge, never
  to the caller's Host, or removed when it cannot be made relative; other `Location` values are
  unchanged. No input or output changes; with
  `edge` set, the next apply rolls a new `ca-edge` revision.
