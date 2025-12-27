# BrainhairOS Development Roadmap

This document outlines the comprehensive development plan for BrainhairOS, organized into phases with detailed implementation plans.

---

## Phase 7: Web Framework Enhancements

**Goal**: Make the Flask-style framework production-ready with full HTTP feature support.

### 7.1 POST Body Parsing

**Files to modify**: `lib/flask.bh`

**Implementation**:

```brainhair
# New constants
const MAX_BODY_LEN: int32 = 8192
const CONTENT_TYPE_FORM: int32 = 1      # application/x-www-form-urlencoded
const CONTENT_TYPE_JSON: int32 = 2      # application/json
const CONTENT_TYPE_MULTIPART: int32 = 3 # multipart/form-data

# Storage for POST data (reuse query param structure)
var post_keys: array[1024, uint8]
var post_values: array[1024, uint8]
var post_count: int32 = 0
var request_body: array[8192, uint8]
var request_body_len: int32 = 0

# Parse the request body based on Content-Type
proc parse_body(request: ptr uint8)

# Get POST parameter (like query params but from body)
proc get_post_param(key: ptr uint8): ptr uint8

# Get raw body content
proc get_body(): ptr uint8
proc get_body_length(): int32
```

**Steps**:
1. Add body storage arrays and constants
2. Implement `find_body_start()` - locate `\r\n\r\n` separator
3. Implement `parse_form_urlencoded()` - same as query string parsing
4. Implement `parse_body()` - detect content type and dispatch
5. Add `get_post_param()` accessor function
6. Update `run()` loop to call `parse_body()` after headers
7. Test with curl: `curl -X POST -d "name=test&value=123" localhost:8080`

**Example usage**:
```brainhair
proc submit_handler(sock: int32, request: ptr uint8, path: ptr uint8) =
  var name: ptr uint8 = get_post_param(cast[ptr uint8]("name"))
  var email: ptr uint8 = get_post_param(cast[ptr uint8]("email"))

  if cast[int32](name) != 0:
    text(sock, name)
  else:
    respond(sock, 400, cast[ptr uint8]("Missing name parameter"))
```

---

### 7.2 Static File Serving

**Files to create**: `lib/static.bh`
**Files to modify**: `lib/flask.bh`

**Implementation**:

```brainhair
# MIME type detection
const MIME_HTML: int32 = 0
const MIME_CSS: int32 = 1
const MIME_JS: int32 = 2
const MIME_PNG: int32 = 3
const MIME_JPG: int32 = 4
const MIME_JSON: int32 = 5
const MIME_TEXT: int32 = 6
const MIME_BINARY: int32 = 7

# Static file configuration
var static_routes: array[512, uint8]      # URL prefix -> dir mappings
var static_dirs: array[512, uint8]
var static_route_count: int32 = 0

# Register a static file directory
proc static(url_prefix: ptr uint8, dir_path: ptr uint8): int32

# Get MIME type from file extension
proc get_mime_type(filename: ptr uint8): ptr uint8

# Serve a file with appropriate headers
proc serve_file(sock: int32, filepath: ptr uint8): int32

# Internal: build full path from URL
proc resolve_static_path(url: ptr uint8, out_path: ptr uint8): int32
```

**Steps**:
1. Create `lib/static.bh` with MIME type detection
2. Implement extension-to-MIME mapping (html, css, js, png, jpg, json, txt)
3. Implement `static()` registration function
4. Implement `serve_file()` - open, read, send with headers
5. Add static file checking to `find_route()` before 404
6. Handle directory index (serve index.html if directory)
7. Add security: prevent path traversal (`../`)
8. Support Range headers for large files (optional)

**Example usage**:
```brainhair
proc main(): int32 =
  # Serve /static/* from ./public directory
  discard static(cast[ptr uint8]("/static"), cast[ptr uint8]("./public"))

  # Serve /assets/* from ./assets directory
  discard static(cast[ptr uint8]("/assets"), cast[ptr uint8]("./assets"))

  discard route(cast[ptr uint8]("/"), cast[ptr uint8](index))
  return run(8080)
```

**MIME type table**:
| Extension | MIME Type |
|-----------|-----------|
| .html | text/html |
| .css | text/css |
| .js | application/javascript |
| .json | application/json |
| .png | image/png |
| .jpg/.jpeg | image/jpeg |
| .gif | image/gif |
| .svg | image/svg+xml |
| .ico | image/x-icon |
| .txt | text/plain |
| .xml | application/xml |
| * | application/octet-stream |

---

### 7.3 Template Rendering

**Files to create**: `lib/template.bh`

**Implementation**:

```brainhair
# Template engine with simple variable substitution
# Syntax: {{variable}} or {{expression}}

const MAX_TEMPLATE_SIZE: int32 = 65536
const MAX_VARS: int32 = 32
const MAX_VAR_NAME: int32 = 64
const MAX_VAR_VALUE: int32 = 1024

# Template variable storage
var tpl_var_names: array[2048, uint8]   # 32 * 64
var tpl_var_values: array[32768, uint8] # 32 * 1024
var tpl_var_count: int32 = 0

# Clear all template variables
proc tpl_clear()

# Set a template variable
proc tpl_set(name: ptr uint8, value: ptr uint8)

# Set integer variable (auto-converts to string)
proc tpl_set_int(name: ptr uint8, value: int32)

# Render template from file
proc tpl_render_file(sock: int32, filepath: ptr uint8)

# Render template from string
proc tpl_render(sock: int32, template: ptr uint8)

# Internal: find and replace {{var}} with value
proc tpl_substitute(template: ptr uint8, output: ptr uint8, max_len: int32): int32
```

**Template syntax**:
```html
<!DOCTYPE html>
<html>
<head><title>{{title}}</title></head>
<body>
  <h1>Welcome, {{username}}!</h1>
  <p>You have {{message_count}} messages.</p>

  <!-- Conditionals (future) -->
  {{#if logged_in}}
    <a href="/logout">Logout</a>
  {{/if}}

  <!-- Loops (future) -->
  {{#each items}}
    <li>{{name}}: {{value}}</li>
  {{/each}}
</body>
</html>
```

**Steps**:
1. Create `lib/template.bh` with variable storage
2. Implement `tpl_set()` and `tpl_set_int()`
3. Implement `tpl_substitute()` - scan for `{{`, find `}}`, replace
4. Implement `tpl_render_file()` - read file, substitute, send
5. Implement `tpl_render()` - for inline templates
6. Add escaping for HTML special characters (`&lt;`, `&gt;`, etc.)
7. Future: Add conditionals (`{{#if}}`) and loops (`{{#each}}`)

**Example usage**:
```brainhair
proc user_profile(sock: int32, request: ptr uint8, path: ptr uint8) =
  var user_id: ptr uint8 = get_route_param(cast[ptr uint8]("id"))

  tpl_clear()
  tpl_set(cast[ptr uint8]("title"), cast[ptr uint8]("User Profile"))
  tpl_set(cast[ptr uint8]("username"), cast[ptr uint8]("Alice"))
  tpl_set_int(cast[ptr uint8]("message_count"), 42)

  tpl_render_file(sock, cast[ptr uint8]("templates/profile.html"))
```

---

### 7.4 Cookie Support

**Files to modify**: `lib/flask.bh`

**Implementation**:

```brainhair
# Cookie storage
const MAX_COOKIES: int32 = 16
const MAX_COOKIE_NAME: int32 = 64
const MAX_COOKIE_VALUE: int32 = 256

var cookie_names: array[1024, uint8]
var cookie_values: array[4096, uint8]
var cookie_count: int32 = 0

# Outgoing cookies (to set)
var set_cookie_names: array[1024, uint8]
var set_cookie_values: array[4096, uint8]
var set_cookie_attrs: array[2048, uint8]  # path, expires, etc.
var set_cookie_count: int32 = 0

# Parse cookies from Cookie header
proc parse_cookies(request: ptr uint8)

# Get a cookie value
proc get_cookie(name: ptr uint8): ptr uint8

# Set a cookie (will be sent in response)
proc set_cookie(name: ptr uint8, value: ptr uint8)

# Set cookie with attributes
proc set_cookie_ex(name: ptr uint8, value: ptr uint8,
                   path: ptr uint8, max_age: int32, http_only: int32)

# Delete a cookie (set max-age=0)
proc delete_cookie(name: ptr uint8)

# Internal: add Set-Cookie headers to response
proc write_cookie_headers(sock: int32)
```

**Cookie header format**:
```
Cookie: session_id=abc123; user_pref=dark; lang=en
Set-Cookie: session_id=xyz789; Path=/; Max-Age=3600; HttpOnly
```

**Steps**:
1. Add cookie storage arrays
2. Implement `parse_cookies()` - extract from Cookie header
3. Implement `get_cookie()` - lookup by name
4. Implement `set_cookie()` and `set_cookie_ex()`
5. Modify `send_response()` to call `write_cookie_headers()`
6. Add `delete_cookie()` (sets Max-Age=0)
7. Update `run()` loop to call `parse_cookies()` after headers

**Example usage**:
```brainhair
proc login(sock: int32, request: ptr uint8, path: ptr uint8) =
  var username: ptr uint8 = get_post_param(cast[ptr uint8]("username"))

  # Set session cookie
  set_cookie_ex(cast[ptr uint8]("session_id"),
                cast[ptr uint8]("abc123xyz"),
                cast[ptr uint8]("/"),
                3600,  # 1 hour
                1)     # HttpOnly

  redirect(sock, cast[ptr uint8]("/dashboard"))

proc dashboard(sock: int32, request: ptr uint8, path: ptr uint8) =
  var session: ptr uint8 = get_cookie(cast[ptr uint8]("session_id"))

  if cast[int32](session) == 0:
    redirect(sock, cast[ptr uint8]("/login"))
    return

  html(sock, cast[ptr uint8]("<h1>Welcome back!</h1>"))

proc logout(sock: int32, request: ptr uint8, path: ptr uint8) =
  delete_cookie(cast[ptr uint8]("session_id"))
  redirect(sock, cast[ptr uint8]("/"))
```

---

### 7.5 JSON Parsing

**Files to create**: `lib/json.bh`

**Implementation**:

```brainhair
# JSON value types
const JSON_NULL: int32 = 0
const JSON_BOOL: int32 = 1
const JSON_NUMBER: int32 = 2
const JSON_STRING: int32 = 3
const JSON_ARRAY: int32 = 4
const JSON_OBJECT: int32 = 5

# JSON parse result
const JSON_MAX_DEPTH: int32 = 16
const JSON_MAX_KEYS: int32 = 64
const JSON_MAX_VALUES: int32 = 64

# Parsed JSON storage (flat representation)
var json_keys: array[4096, uint8]      # Key strings
var json_values: array[8192, uint8]    # Value strings
var json_types: array[64, int32]       # Value types
var json_parents: array[64, int32]     # Parent indices for nesting
var json_count: int32 = 0

# Parse JSON string
proc json_parse(input: ptr uint8): int32

# Get value by path (e.g., "user.name" or "items[0].id")
proc json_get(path: ptr uint8): ptr uint8

# Get value type
proc json_type(path: ptr uint8): int32

# Get array length
proc json_array_len(path: ptr uint8): int32

# Build JSON output
proc json_builder_start()
proc json_builder_add_string(key: ptr uint8, value: ptr uint8)
proc json_builder_add_int(key: ptr uint8, value: int32)
proc json_builder_add_bool(key: ptr uint8, value: int32)
proc json_builder_end(): ptr uint8
```

**Steps**:
1. Create `lib/json.bh` with type constants
2. Implement tokenizer - identify strings, numbers, bools, delimiters
3. Implement recursive descent parser
4. Store parsed values in flat arrays with parent references
5. Implement `json_get()` with path parsing ("user.name", "items[0]")
6. Implement JSON builder for output generation
7. Add validation and error reporting

**Example usage**:
```brainhair
proc api_create_user(sock: int32, request: ptr uint8, path: ptr uint8) =
  var body: ptr uint8 = get_body()

  if json_parse(body) < 0:
    respond(sock, 400, cast[ptr uint8]("{\"error\": \"Invalid JSON\"}"))
    return

  var name: ptr uint8 = json_get(cast[ptr uint8]("name"))
  var email: ptr uint8 = json_get(cast[ptr uint8]("email"))
  var age: ptr uint8 = json_get(cast[ptr uint8]("age"))

  # Build response
  json_builder_start()
  json_builder_add_string(cast[ptr uint8]("status"), cast[ptr uint8]("created"))
  json_builder_add_string(cast[ptr uint8]("name"), name)
  json_builder_add_int(cast[ptr uint8]("id"), 12345)
  var response: ptr uint8 = json_builder_end()

  json(sock, response)
```

---

## Phase 8: Networking Expansion

### 8.1 DNS Client ✅ COMPLETED

**Files created**: `lib/dns.bh`, `userland/nslookup.bh`
**Files modified**: `kernel/kernel_main.bh`, `kernel/isr.asm`, `lib/syscalls.bh`

**Status**: Implemented and tested. DNS resolver is available via syscall SYS_DNS_LOOKUP (65).

**Implementation**:

```brainhair
# DNS constants
const DNS_PORT: int32 = 53
const DNS_TYPE_A: int32 = 1
const DNS_TYPE_AAAA: int32 = 28
const DNS_TYPE_CNAME: int32 = 5
const DNS_CLASS_IN: int32 = 1

# DNS cache
const DNS_CACHE_SIZE: int32 = 32
var dns_cache_names: array[2048, uint8]    # 32 * 64
var dns_cache_ips: array[128, uint8]       # 32 * 4
var dns_cache_ttls: array[32, int32]
var dns_cache_count: int32 = 0

# Resolve hostname to IP address
# Returns: 1 on success (IP written to out_ip), 0 on failure
proc dns_resolve(hostname: ptr uint8, out_ip: ptr uint8): int32

# Async resolve (non-blocking)
proc dns_resolve_async(hostname: ptr uint8): int32

# Check if async resolve completed
proc dns_resolve_ready(): int32

# Build DNS query packet
proc dns_build_query(hostname: ptr uint8, buffer: ptr uint8): int32

# Parse DNS response
proc dns_parse_response(buffer: ptr uint8, out_ip: ptr uint8): int32

# Check cache first
proc dns_cache_lookup(hostname: ptr uint8, out_ip: ptr uint8): int32

# Add to cache
proc dns_cache_add(hostname: ptr uint8, ip: ptr uint8, ttl: int32)
```

**DNS packet structure**:
```
Header (12 bytes):
  ID: 2 bytes (transaction ID)
  Flags: 2 bytes (QR, Opcode, AA, TC, RD, RA, Z, RCODE)
  QDCOUNT: 2 bytes (questions)
  ANCOUNT: 2 bytes (answers)
  NSCOUNT: 2 bytes (authority)
  ARCOUNT: 2 bytes (additional)

Question:
  QNAME: variable (domain name in label format)
  QTYPE: 2 bytes (A=1, AAAA=28)
  QCLASS: 2 bytes (IN=1)

Answer:
  NAME: 2 bytes (pointer to QNAME)
  TYPE: 2 bytes
  CLASS: 2 bytes
  TTL: 4 bytes
  RDLENGTH: 2 bytes
  RDATA: variable (4 bytes for A record)
```

**Steps**:
1. Add UDP socket support to kernel if not present
2. Implement DNS query builder with label encoding
3. Implement DNS response parser
4. Add DNS cache with TTL expiration
5. Implement synchronous `dns_resolve()`
6. Implement async version for non-blocking resolution
7. Use DHCP-provided DNS server or fallback (8.8.8.8)
8. Add support for CNAME following

**Example usage**:
```brainhair
proc fetch_remote(sock: int32, request: ptr uint8, path: ptr uint8) =
  var ip: array[4, uint8]

  if dns_resolve(cast[ptr uint8]("api.example.com"), addr(ip[0])) == 0:
    server_error(sock)
    return

  # Now connect to ip[0..3]
  var remote: int32 = net_connect(addr(ip[0]), 80)
  # ...
```

---

### 8.2 HTTP Client

**Files to create**: `lib/http_client.bh`

**Implementation**:

```brainhair
# HTTP client for making outbound requests

const HTTP_METHOD_GET: int32 = 0
const HTTP_METHOD_POST: int32 = 1
const HTTP_METHOD_PUT: int32 = 2
const HTTP_METHOD_DELETE: int32 = 3

# Response storage
var http_response_status: int32 = 0
var http_response_headers: array[2048, uint8]
var http_response_body: array[32768, uint8]
var http_response_body_len: int32 = 0

# Make HTTP GET request
# Returns: status code, or negative on error
proc http_get(url: ptr uint8): int32

# Make HTTP POST request
proc http_post(url: ptr uint8, body: ptr uint8, content_type: ptr uint8): int32

# Make generic HTTP request
proc http_request(method: int32, url: ptr uint8,
                  headers: ptr uint8, body: ptr uint8): int32

# Get response body
proc http_get_body(): ptr uint8
proc http_get_body_len(): int32

# Get response header
proc http_get_response_header(name: ptr uint8): ptr uint8

# Parse URL into components
proc url_parse(url: ptr uint8,
               out_host: ptr uint8, out_port: ptr int32, out_path: ptr uint8): int32
```

**Steps**:
1. Implement URL parser (extract host, port, path from `http://host:port/path`)
2. Use DNS resolver to get IP from hostname
3. Implement TCP connection to remote server
4. Build and send HTTP request
5. Parse response (status line, headers, body)
6. Handle chunked transfer encoding
7. Handle redirects (301, 302, 307)
8. Add timeout handling

**Example usage**:
```brainhair
proc proxy_handler(sock: int32, request: ptr uint8, path: ptr uint8) =
  # Fetch data from external API
  var status: int32 = http_get(cast[ptr uint8]("http://api.example.com/data"))

  if status == 200:
    var body: ptr uint8 = http_get_body()
    json(sock, body)
  else:
    respond(sock, 502, cast[ptr uint8]("Upstream error"))

proc webhook_handler(sock: int32, request: ptr uint8, path: ptr uint8) =
  # Forward event to external service
  var body: ptr uint8 = get_body()

  var status: int32 = http_post(
    cast[ptr uint8]("http://webhook.example.com/events"),
    body,
    cast[ptr uint8]("application/json"))

  if status >= 200 and status < 300:
    text(sock, cast[ptr uint8]("Webhook sent"))
  else:
    server_error(sock)
```

---

### 8.3 WebSocket Support

**Files to create**: `lib/websocket.bh`
**Files to modify**: `lib/flask.bh`

**Implementation**:

```brainhair
# WebSocket opcodes
const WS_OPCODE_CONTINUATION: int32 = 0
const WS_OPCODE_TEXT: int32 = 1
const WS_OPCODE_BINARY: int32 = 2
const WS_OPCODE_CLOSE: int32 = 8
const WS_OPCODE_PING: int32 = 9
const WS_OPCODE_PONG: int32 = 10

# WebSocket connection state
const WS_STATE_CONNECTING: int32 = 0
const WS_STATE_OPEN: int32 = 1
const WS_STATE_CLOSING: int32 = 2
const WS_STATE_CLOSED: int32 = 3

# WebSocket connection storage
const WS_MAX_CONNECTIONS: int32 = 16
var ws_sockets: array[16, int32]
var ws_states: array[16, int32]
var ws_handlers: array[16, int32]       # Message handler function pointers
var ws_connection_count: int32 = 0

# Register WebSocket route
proc websocket(path: ptr uint8, on_message: ptr uint8): int32

# Handle WebSocket upgrade request
proc ws_upgrade(sock: int32, request: ptr uint8): int32

# Send WebSocket message
proc ws_send(ws_id: int32, data: ptr uint8, len: int32, opcode: int32): int32
proc ws_send_text(ws_id: int32, message: ptr uint8): int32
proc ws_send_binary(ws_id: int32, data: ptr uint8, len: int32): int32

# Close WebSocket connection
proc ws_close(ws_id: int32, code: int32)

# Read WebSocket frame
proc ws_read_frame(ws_id: int32, out_data: ptr uint8,
                   out_len: ptr int32, out_opcode: ptr int32): int32

# WebSocket frame masking/unmasking
proc ws_unmask(data: ptr uint8, len: int32, mask: ptr uint8)

# Compute Sec-WebSocket-Accept
proc ws_compute_accept(key: ptr uint8, out_accept: ptr uint8)
```

**WebSocket handshake**:
```
Client request:
GET /chat HTTP/1.1
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==
Sec-WebSocket-Version: 13

Server response:
HTTP/1.1 101 Switching Protocols
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=
```

**WebSocket frame format**:
```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-------+-+-------------+-------------------------------+
|F|R|R|R| opcode|M| Payload len |    Extended payload length    |
|I|S|S|S|  (4)  |A|     (7)     |             (16/64)           |
|N|V|V|V|       |S|             |   (if payload len==126/127)   |
| |1|2|3|       |K|             |                               |
+-+-+-+-+-------+-+-------------+ - - - - - - - - - - - - - - - +
|     Extended payload length continued, if payload len == 127  |
+ - - - - - - - - - - - - - - - +-------------------------------+
|                               |Masking-key, if MASK set to 1  |
+-------------------------------+-------------------------------+
| Masking-key (continued)       |          Payload Data         |
+-------------------------------- - - - - - - - - - - - - - - - +
:                     Payload Data continued ...                :
+ - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - +
|                     Payload Data continued ...                |
+---------------------------------------------------------------+
```

**Steps**:
1. Implement SHA-1 hash (needed for Sec-WebSocket-Accept)
2. Implement Base64 encoding
3. Implement `ws_compute_accept()` using SHA-1 and Base64
4. Implement `ws_upgrade()` - validate and respond to upgrade request
5. Implement frame parser with mask handling
6. Implement frame builder
7. Add WebSocket connection management
8. Integrate with main `run()` loop for multiplexing
9. Handle ping/pong for keepalive
10. Handle close frames gracefully

**Example usage**:
```brainhair
proc on_chat_message(ws_id: int32, message: ptr uint8, len: int32) =
  # Echo message back
  ws_send_text(ws_id, message)

  # Or broadcast to all connections
  var i: int32 = 0
  while i < ws_connection_count:
    if ws_states[i] == WS_STATE_OPEN:
      ws_send_text(i, message)
    i = i + 1

proc main(): int32 =
  discard route(cast[ptr uint8]("/"), cast[ptr uint8](index))
  discard websocket(cast[ptr uint8]("/chat"), cast[ptr uint8](on_chat_message))
  return run(8080)
```

---

### 8.4 Concurrent Connections

**Files to modify**: `lib/flask.bh`, `kernel/kernel_main.bh`

**Implementation**:

```brainhair
# Connection pool for handling multiple clients
const MAX_CONCURRENT: int32 = 16

var conn_sockets: array[16, int32]
var conn_states: array[16, int32]       # 0=free, 1=reading, 2=processing, 3=writing
var conn_buffers: array[32768, uint8]   # 2048 per connection
var conn_count: int32 = 0

# Non-blocking accept
proc accept_new_connections(listen_sock: int32)

# Process ready connections (select/poll style)
proc process_connections()

# Connection state machine
proc conn_state_machine(conn_idx: int32)
```

**Approach**: Event-driven I/O with connection state machine

**States**:
1. `CONN_FREE` - Slot available
2. `CONN_ACCEPTING` - Waiting for connection
3. `CONN_READING` - Reading request
4. `CONN_PROCESSING` - Executing handler
5. `CONN_WRITING` - Sending response
6. `CONN_CLOSING` - Cleaning up

**Steps**:
1. Modify TCP stack to support multiple simultaneous connections
2. Implement connection pool management
3. Implement non-blocking I/O for reads and writes
4. Create state machine for connection lifecycle
5. Modify `run()` to use event loop instead of blocking
6. Handle partial reads/writes
7. Add connection timeouts
8. Implement graceful shutdown

---

## Phase 9: SQL Query Engine

### 9.1 SQL Lexer

**Files to create**: `lib/sql_lexer.bh`

**Implementation**:

```brainhair
# SQL token types
const TOK_SELECT: int32 = 1
const TOK_FROM: int32 = 2
const TOK_WHERE: int32 = 3
const TOK_AND: int32 = 4
const TOK_OR: int32 = 5
const TOK_ORDER: int32 = 6
const TOK_BY: int32 = 7
const TOK_GROUP: int32 = 8
const TOK_HAVING: int32 = 9
const TOK_JOIN: int32 = 10
const TOK_LEFT: int32 = 11
const TOK_RIGHT: int32 = 12
const TOK_INNER: int32 = 13
const TOK_ON: int32 = 14
const TOK_AS: int32 = 15
const TOK_LIMIT: int32 = 16
const TOK_OFFSET: int32 = 17
const TOK_ASC: int32 = 18
const TOK_DESC: int32 = 19
const TOK_NULL: int32 = 20
const TOK_NOT: int32 = 21
const TOK_IN: int32 = 22
const TOK_LIKE: int32 = 23
const TOK_BETWEEN: int32 = 24
const TOK_IS: int32 = 25
const TOK_DISTINCT: int32 = 26

# Operators
const TOK_EQ: int32 = 50        # =
const TOK_NE: int32 = 51        # <> or !=
const TOK_LT: int32 = 52        # <
const TOK_GT: int32 = 53        # >
const TOK_LE: int32 = 54        # <=
const TOK_GE: int32 = 55        # >=

# Aggregates
const TOK_COUNT: int32 = 70
const TOK_SUM: int32 = 71
const TOK_AVG: int32 = 72
const TOK_MIN: int32 = 73
const TOK_MAX: int32 = 74

# Literals and identifiers
const TOK_IDENT: int32 = 100
const TOK_NUMBER: int32 = 101
const TOK_STRING: int32 = 102

# Punctuation
const TOK_COMMA: int32 = 110
const TOK_DOT: int32 = 111
const TOK_STAR: int32 = 112
const TOK_LPAREN: int32 = 113
const TOK_RPAREN: int32 = 114

# Token storage
const MAX_TOKENS: int32 = 256
var sql_tokens: array[256, int32]       # Token types
var sql_token_starts: array[256, int32] # Start positions
var sql_token_lens: array[256, int32]   # Token lengths
var sql_token_count: int32 = 0

# Tokenize SQL query
proc sql_tokenize(query: ptr uint8): int32

# Get token value as string
proc sql_token_value(idx: int32, out: ptr uint8): int32
```

**Steps**:
1. Implement keyword recognition (case-insensitive)
2. Implement identifier parsing
3. Implement string literal parsing (single and double quotes)
4. Implement number parsing (integers and decimals)
5. Implement operator parsing
6. Handle whitespace and comments
7. Build token array with positions

---

### 9.2 SQL Parser

**Files to create**: `lib/sql_parser.bh`

**Implementation**:

```brainhair
# AST node types
const AST_SELECT: int32 = 1
const AST_COLUMN: int32 = 2
const AST_TABLE: int32 = 3
const AST_WHERE: int32 = 4
const AST_BINOP: int32 = 5
const AST_LITERAL: int32 = 6
const AST_FUNC_CALL: int32 = 7
const AST_ORDER: int32 = 8
const AST_GROUP: int32 = 9
const AST_JOIN: int32 = 10
const AST_ALIAS: int32 = 11

# AST node storage (array-based tree)
const MAX_AST_NODES: int32 = 512
var ast_types: array[512, int32]
var ast_values: array[16384, uint8]     # String values
var ast_value_offsets: array[512, int32]
var ast_lefts: array[512, int32]        # Left child index
var ast_rights: array[512, int32]       # Right child index
var ast_parents: array[512, int32]
var ast_count: int32 = 0

# Parsed query structure
var query_columns: array[64, int32]     # AST indices of selected columns
var query_column_count: int32 = 0
var query_table: int32 = 0              # AST index of main table
var query_where: int32 = 0              # AST index of WHERE clause
var query_order: int32 = 0              # AST index of ORDER BY
var query_group: int32 = 0              # AST index of GROUP BY
var query_limit: int32 = -1
var query_offset: int32 = 0

# Parse SQL query
proc sql_parse(query: ptr uint8): int32

# Parse helpers
proc parse_select(): int32
proc parse_column_list(): int32
proc parse_from(): int32
proc parse_where(): int32
proc parse_expression(): int32
proc parse_and_expression(): int32
proc parse_comparison(): int32
proc parse_term(): int32
proc parse_order_by(): int32
proc parse_group_by(): int32
```

**Grammar (simplified)**:
```
query := SELECT column_list FROM table_ref [WHERE expr] [GROUP BY columns] [ORDER BY columns] [LIMIT n]

column_list := column (',' column)*
column := '*' | expr [AS alias] | aggregate '(' expr ')' [AS alias]

table_ref := table_name [alias] [join_clause]*
join_clause := [LEFT|RIGHT|INNER] JOIN table_name ON expr

expr := and_expr (OR and_expr)*
and_expr := comparison (AND comparison)*
comparison := term (comp_op term)?
term := literal | column_ref | '(' expr ')' | func_call
```

**Steps**:
1. Implement recursive descent parser
2. Parse SELECT clause with column list
3. Parse FROM clause with table references
4. Parse WHERE clause with expressions
5. Parse ORDER BY clause
6. Parse GROUP BY clause
7. Parse JOIN clauses
8. Parse LIMIT/OFFSET
9. Build AST with proper parent/child relationships

---

### 9.3 Query Executor

**Files to create**: `lib/sql_exec.bh`

**Implementation**:

```brainhair
# Execution plan nodes
const PLAN_SCAN: int32 = 1      # Full table scan
const PLAN_FILTER: int32 = 2    # Apply WHERE predicate
const PLAN_PROJECT: int32 = 3   # Select columns
const PLAN_SORT: int32 = 4      # ORDER BY
const PLAN_GROUP: int32 = 5     # GROUP BY + aggregates
const PLAN_LIMIT: int32 = 6     # LIMIT/OFFSET
const PLAN_JOIN: int32 = 7      # Join two inputs

# Execution plan storage
const MAX_PLAN_NODES: int32 = 64
var plan_types: array[64, int32]
var plan_inputs: array[64, int32]       # Input plan node
var plan_inputs2: array[64, int32]      # Second input (for joins)
var plan_params: array[1024, uint8]     # Plan-specific parameters
var plan_count: int32 = 0

# Result set
var result_schema: array[256, uint8]    # Output schema
var result_data: array[65536, uint8]    # Result records
var result_count: int32 = 0

# Build execution plan from AST
proc sql_plan(ast_root: int32): int32

# Execute plan and produce results
proc sql_execute(plan_root: int32): int32

# Scan operators (read from data source)
proc exec_scan(source: ptr uint8): int32

# Filter operator
proc exec_filter(input: int32, predicate: int32): int32

# Project operator
proc exec_project(input: int32, columns: ptr int32, col_count: int32): int32

# Sort operator (in-memory quicksort)
proc exec_sort(input: int32, sort_col: int32, desc: int32): int32

# Group by operator
proc exec_group(input: int32, group_cols: ptr int32,
                agg_funcs: ptr int32, agg_cols: ptr int32): int32

# Limit operator
proc exec_limit(input: int32, limit: int32, offset: int32): int32

# Join operator (nested loop join)
proc exec_join(left: int32, right: int32, condition: int32): int32
```

**Execution model**: Volcano-style iterator

Each operator implements:
- `open()` - Initialize operator
- `next()` - Return next record (or NULL if done)
- `close()` - Cleanup

**Steps**:
1. Implement query planner (AST → execution plan)
2. Implement table scan operator (read PSCH data)
3. Implement filter operator (evaluate WHERE)
4. Implement project operator (select columns)
5. Implement sort operator (quicksort on field)
6. Implement group by operator (hash-based grouping)
7. Implement aggregation functions (COUNT, SUM, AVG, MIN, MAX)
8. Implement limit/offset operator
9. Implement nested loop join operator
10. Add query optimization (predicate pushdown)

**Example usage**:
```brainhair
proc query_handler(sock: int32, request: ptr uint8, path: ptr uint8) =
  var query: ptr uint8 = get_query_param(cast[ptr uint8]("q"))

  if sql_parse(query) < 0:
    json(sock, cast[ptr uint8]("{\"error\": \"Parse error\"}"))
    return

  var plan: int32 = sql_plan(0)
  if sql_execute(plan) < 0:
    json(sock, cast[ptr uint8]("{\"error\": \"Execution error\"}"))
    return

  # Return results as JSON
  sql_results_to_json(sock)
```

---

### 9.4 Index Support

**Files to create**: `lib/sql_index.bh`

**Implementation**:

```brainhair
# Index types
const INDEX_BTREE: int32 = 1
const INDEX_HASH: int32 = 2

# Index storage
const MAX_INDEXES: int32 = 16
var index_tables: array[1024, uint8]    # Table names
var index_columns: array[256, uint8]    # Column names
var index_types: array[16, int32]
var index_data: array[65536, uint8]     # Index data structures
var index_count: int32 = 0

# Create index on column
proc create_index(table: ptr uint8, column: ptr uint8, idx_type: int32): int32

# Drop index
proc drop_index(table: ptr uint8, column: ptr uint8): int32

# Lookup using index
proc index_lookup(table: ptr uint8, column: ptr uint8,
                  value: ptr uint8, out_offsets: ptr int32): int32

# Range scan using index
proc index_range(table: ptr uint8, column: ptr uint8,
                 min_val: ptr uint8, max_val: ptr uint8,
                 out_offsets: ptr int32): int32

# B-tree operations
proc btree_insert(idx: int32, key: ptr uint8, offset: int32): int32
proc btree_search(idx: int32, key: ptr uint8): int32
proc btree_range(idx: int32, min: ptr uint8, max: ptr uint8,
                 out: ptr int32, max_count: int32): int32
```

**B-tree node structure**:
```
Node (4KB page):
  is_leaf: 1 byte
  key_count: 2 bytes
  keys: N * key_size bytes
  children/values: (N+1) * 4 bytes (page numbers or record offsets)
```

**Steps**:
1. Implement B-tree node structure
2. Implement B-tree search
3. Implement B-tree insertion with node splitting
4. Implement range scans
5. Integrate with query planner (use index when possible)
6. Implement hash index for equality lookups
7. Add index maintenance on data changes

---

## Phase 10: System Improvements

### 10.1 Worker Processes

**Files to modify**: `lib/flask.bh`, `kernel/kernel_main.bh`

**Implementation**:

```brainhair
# Worker process management
const MAX_WORKERS: int32 = 4

var worker_pids: array[4, int32]
var worker_sockets: array[4, int32]     # IPC sockets to workers
var worker_count: int32 = 0

# Start worker processes
proc workers_start(count: int32): int32

# Worker main loop
proc worker_loop(sock: int32)

# Distribute connection to worker
proc dispatch_to_worker(conn_sock: int32): int32

# Wait for worker to become available
proc wait_for_worker(): int32

# Signal handler for graceful shutdown
proc handle_sigterm()

# Main process: run with multiple workers
proc run_workers(port: int32, worker_count: int32): int32
```

**Architecture**:
```
                    ┌─────────────────┐
                    │   Main Process  │
                    │  (accept loop)  │
                    └────────┬────────┘
                             │
           ┌─────────────────┼─────────────────┐
           ▼                 ▼                 ▼
    ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
    │   Worker 1   │  │   Worker 2   │  │   Worker 3   │
    │  (handler)   │  │  (handler)   │  │  (handler)   │
    └──────────────┘  └──────────────┘  └──────────────┘
```

**Steps**:
1. Implement fork() syscall wrapper
2. Implement IPC mechanism (pipes or unix sockets)
3. Implement connection passing between processes
4. Create worker main loop
5. Implement round-robin or least-connections dispatch
6. Add worker health monitoring
7. Implement graceful restart
8. Handle worker crashes (respawn)

---

### 10.2 Key-Value Store

**Files to create**: `lib/kvstore.bh`

**Implementation**:

```brainhair
# Simple persistent key-value store
const KV_MAX_KEY: int32 = 256
const KV_MAX_VALUE: int32 = 4096
const KV_BUCKET_COUNT: int32 = 256

# In-memory hash table
var kv_keys: array[65536, uint8]        # 256 * 256
var kv_values: array[1048576, uint8]    # 256 * 4096
var kv_key_lens: array[256, int32]
var kv_value_lens: array[256, int32]
var kv_nexts: array[256, int32]         # Hash collision chain
var kv_count: int32 = 0

# Open/create database file
proc kv_open(filepath: ptr uint8): int32

# Close database (flush to disk)
proc kv_close(): int32

# Get value by key
proc kv_get(key: ptr uint8, out_value: ptr uint8, max_len: int32): int32

# Set key-value pair
proc kv_set(key: ptr uint8, value: ptr uint8): int32

# Delete key
proc kv_delete(key: ptr uint8): int32

# Check if key exists
proc kv_exists(key: ptr uint8): int32

# Iterate all keys
proc kv_keys_start(): int32
proc kv_keys_next(out_key: ptr uint8): int32

# Flush changes to disk
proc kv_sync(): int32

# Hash function
proc kv_hash(key: ptr uint8): int32
```

**File format**:
```
Header:
  Magic: "BHKV" (4 bytes)
  Version: 1 (4 bytes)
  Entry count: N (4 bytes)
  Reserved: 4 bytes

Entries:
  Key length: 2 bytes
  Value length: 4 bytes
  Key: variable
  Value: variable
  Checksum: 4 bytes (CRC32)

Footer:
  Checksum: 4 bytes (file CRC32)
```

**Steps**:
1. Implement hash function (FNV-1a or similar)
2. Implement in-memory hash table with chaining
3. Implement file format parser
4. Implement file writer with atomic updates
5. Add write-ahead logging for crash safety
6. Implement key iteration
7. Add compaction (remove deleted entries)

**Example usage**:
```brainhair
proc session_store(sock: int32, request: ptr uint8, path: ptr uint8) =
  discard kv_open(cast[ptr uint8]("/data/sessions.db"))

  var session_id: ptr uint8 = get_cookie(cast[ptr uint8]("session_id"))

  if cast[int32](session_id) != 0:
    var user_data: array[1024, uint8]
    var len: int32 = kv_get(session_id, addr(user_data[0]), 1024)

    if len > 0:
      json(sock, addr(user_data[0]))
      return

  respond(sock, 401, cast[ptr uint8]("Not authenticated"))
  discard kv_close()
```

---

### 10.3 Logging Framework

**Files to create**: `lib/log.bh`

**Implementation**:

```brainhair
# Log levels
const LOG_DEBUG: int32 = 0
const LOG_INFO: int32 = 1
const LOG_WARN: int32 = 2
const LOG_ERROR: int32 = 3
const LOG_FATAL: int32 = 4

# Current log level (only log messages >= this level)
var log_level: int32 = LOG_INFO

# Log output destination
const LOG_DEST_SERIAL: int32 = 1
const LOG_DEST_FILE: int32 = 2
const LOG_DEST_BOTH: int32 = 3
var log_destination: int32 = LOG_DEST_SERIAL

# Log file handle
var log_file_fd: int32 = -1

# Configure logging
proc log_init(level: int32, dest: int32, filepath: ptr uint8)

# Close log file
proc log_close()

# Log message with format
proc log_debug(msg: ptr uint8)
proc log_info(msg: ptr uint8)
proc log_warn(msg: ptr uint8)
proc log_error(msg: ptr uint8)
proc log_fatal(msg: ptr uint8)

# Log with formatting
proc log_debugf(fmt: ptr uint8, arg1: int32)
proc log_infof(fmt: ptr uint8, arg1: int32)
proc log_errorf(fmt: ptr uint8, arg1: int32)

# Request logging (Apache-style)
proc log_request(method: int32, path: ptr uint8, status: int32, duration_ms: int32)

# Internal: format and write
proc log_write(level: int32, msg: ptr uint8)
proc log_get_timestamp(out: ptr uint8)
proc log_level_name(level: int32): ptr uint8
```

**Log format**:
```
[2024-01-15 10:30:45] [INFO] Server started on port 8080
[2024-01-15 10:30:46] [DEBUG] Connection accepted from 10.0.2.2
[2024-01-15 10:30:46] [INFO] GET /api/users 200 12ms
[2024-01-15 10:30:47] [ERROR] Database connection failed
```

**Steps**:
1. Implement log level filtering
2. Implement timestamp formatting
3. Implement serial output
4. Implement file output with buffering
5. Implement log rotation (optional)
6. Add request logging helper
7. Add structured logging (JSON format option)

---

## Phase 11: Developer Tools

### 11.1 Brainhair REPL

**Files to create**: `userland/repl.bh`

**Implementation**:

```brainhair
# Interactive Brainhair REPL
# Compiles and executes expressions on the fly

const REPL_BUF_SIZE: int32 = 4096

var repl_history: array[32768, uint8]   # Last 32 lines
var repl_history_count: int32 = 0

proc repl_main() =
  println(cast[ptr uint8]("Brainhair REPL v0.1"))
  println(cast[ptr uint8]("Type 'exit' to quit, 'help' for commands"))

  var input: array[1024, uint8]

  while 1:
    print(cast[ptr uint8](">>> "))
    var len: int32 = readline(addr(input[0]), 1024)

    if len <= 0:
      continue

    if strcmp(addr(input[0]), cast[ptr uint8]("exit")) == 0:
      break

    if strcmp(addr(input[0]), cast[ptr uint8]("help")) == 0:
      repl_help()
      continue

    # Try to compile and execute
    repl_eval(addr(input[0]))

proc repl_eval(input: ptr uint8)
proc repl_help()
proc repl_history_add(line: ptr uint8)
```

**REPL features**:
- Expression evaluation
- Variable definitions (persist across lines)
- Function definitions
- Import statements
- History with up/down arrows
- Tab completion

---

### 11.2 Test Framework

**Files to create**: `lib/test.bh`

**Implementation**:

```brainhair
# Unit testing framework for Brainhair

var test_count: int32 = 0
var test_passed: int32 = 0
var test_failed: int32 = 0
var current_suite: ptr uint8 = cast[ptr uint8](0)

# Start test suite
proc test_suite(name: ptr uint8)

# End test suite and print summary
proc test_summary()

# Assertions
proc assert_true(condition: int32, msg: ptr uint8)
proc assert_false(condition: int32, msg: ptr uint8)
proc assert_eq_int(expected: int32, actual: int32, msg: ptr uint8)
proc assert_eq_str(expected: ptr uint8, actual: ptr uint8, msg: ptr uint8)
proc assert_null(ptr: ptr uint8, msg: ptr uint8)
proc assert_not_null(ptr: ptr uint8, msg: ptr uint8)

# Test case wrapper
proc test(name: ptr uint8, test_fn: ptr uint8)

# Run all tests in a file
proc run_tests()
```

**Example test file**:
```brainhair
import "lib/test"
import "lib/string"

proc test_string_len() =
  var s: ptr uint8 = cast[ptr uint8]("hello")
  assert_eq_int(5, cstr_len(s), cast[ptr uint8]("string length"))

proc test_string_cmp() =
  assert_eq_int(0, cstr_cmp(cast[ptr uint8]("abc"), cast[ptr uint8]("abc")),
                cast[ptr uint8]("equal strings"))
  assert_true(cstr_cmp(cast[ptr uint8]("abc"), cast[ptr uint8]("abd")) < 0,
              cast[ptr uint8]("abc < abd"))

proc main() =
  test_suite(cast[ptr uint8]("String Library Tests"))

  test(cast[ptr uint8]("string length"), cast[ptr uint8](test_string_len))
  test(cast[ptr uint8]("string compare"), cast[ptr uint8](test_string_cmp))

  test_summary()
```

**Output**:
```
=== String Library Tests ===
[PASS] string length
[PASS] string compare

Results: 2/2 passed (100%)
```

---

### 11.3 Profiler

**Files to create**: `lib/profile.bh`

**Implementation**:

```brainhair
# Simple function-level profiler

const MAX_PROFILE_FUNCS: int32 = 256

var profile_names: array[8192, uint8]   # Function names
var profile_calls: array[256, int32]    # Call counts
var profile_times: array[256, int32]    # Total time (ticks)
var profile_starts: array[256, int32]   # Entry timestamps
var profile_count: int32 = 0

# Start profiling
proc profile_start()

# Stop profiling and print report
proc profile_stop()

# Enter function (call at function start)
proc profile_enter(func_name: ptr uint8)

# Exit function (call before return)
proc profile_exit(func_name: ptr uint8)

# Get current timestamp
proc profile_timestamp(): int32

# Print profile report
proc profile_report()

# Macro-like helpers (in Brainhair, manual calls needed)
# TODO: Add compiler support for automatic instrumentation
```

**Profile report format**:
```
=== Profile Report ===
Function                 Calls    Total Time    Avg Time
--------------------------------------------------------
parse_request             1000        45000         45
handle_route               850        38000         44
send_response              850        12000         14
json_parse                 200        25000        125
sql_execute                 50        80000       1600
--------------------------------------------------------
Total:                    2950       200000         67
```

---

## Phase 12: Practical Applications

### 12.1 System Monitor Web UI

**Files to create**: `userland/sysmon_web.bh`, `templates/sysmon.html`

**Implementation**:

Web-based system monitor that displays:
- CPU usage (per-core)
- Memory usage (used/free/cached)
- Process list (sortable)
- Network traffic
- Disk usage
- Uptime

**Architecture**:
```
┌─────────────────────────────────────────────────────────┐
│                    Browser (HTML/JS)                     │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐    │
│  │   CPU   │  │ Memory  │  │Processes│  │ Network │    │
│  │  Chart  │  │  Chart  │  │  Table  │  │  Graph  │    │
│  └────┬────┘  └────┬────┘  └────┬────┘  └────┬────┘    │
└───────┼────────────┼────────────┼────────────┼──────────┘
        │            │            │            │
        └────────────┴─────┬──────┴────────────┘
                           │ WebSocket / Polling
                           ▼
┌──────────────────────────────────────────────────────────┐
│                    BrainhairOS Server                     │
│  ┌─────────────────────────────────────────────────────┐ │
│  │                  sysmon_web.bh                       │ │
│  │  - GET /           → Serve dashboard HTML           │ │
│  │  - GET /api/cpu    → Return CPU stats JSON          │ │
│  │  - GET /api/mem    → Return memory stats JSON       │ │
│  │  - GET /api/proc   → Return process list JSON       │ │
│  │  - GET /api/net    → Return network stats JSON      │ │
│  │  - WS /live        → Push updates every second      │ │
│  └─────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────┘
```

**API endpoints**:
```
GET /api/cpu
{
  "cores": 4,
  "usage": [45.2, 30.1, 55.8, 22.3],
  "load": [1.23, 1.45, 1.12]
}

GET /api/mem
{
  "total": 16777216,
  "used": 8388608,
  "free": 6291456,
  "cached": 2097152
}

GET /api/proc
{
  "processes": [
    {"pid": 1, "name": "init", "cpu": 0.1, "mem": 1024},
    {"pid": 100, "name": "sysmon_web", "cpu": 2.5, "mem": 4096}
  ]
}

GET /api/net
{
  "interfaces": [
    {"name": "eth0", "rx_bytes": 123456, "tx_bytes": 78901, "rx_pps": 100, "tx_pps": 50}
  ]
}
```

---

### 12.2 REST API Example (Todo App)

**Files to create**: `userland/todo_api.bh`

**Implementation**:

Full CRUD REST API for a todo list application.

**Endpoints**:
```
GET    /api/todos          → List all todos
POST   /api/todos          → Create todo
GET    /api/todos/:id      → Get single todo
PUT    /api/todos/:id      → Update todo
DELETE /api/todos/:id      → Delete todo
PATCH  /api/todos/:id      → Toggle complete
```

**Data model**:
```brainhair
# Todo item (stored in KV store)
# Key: "todo:{id}"
# Value: JSON

# Format:
{
  "id": 1,
  "title": "Buy groceries",
  "completed": false,
  "created_at": "2024-01-15T10:30:00Z"
}
```

**Code structure**:
```brainhair
import "lib/flask"
import "lib/json"
import "lib/kvstore"

# Auto-increment ID
var next_todo_id: int32 = 1

proc list_todos(sock: int32, request: ptr uint8, path: ptr uint8) =
  # Build JSON array of all todos
  json_builder_start_array()

  discard kv_keys_start()
  var key: array[256, uint8]
  while kv_keys_next(addr(key[0])) > 0:
    if starts_with(addr(key[0]), cast[ptr uint8]("todo:")) == 1:
      var value: array[1024, uint8]
      discard kv_get(addr(key[0]), addr(value[0]), 1024)
      json_builder_add_raw(addr(value[0]))

  var result: ptr uint8 = json_builder_end_array()
  json(sock, result)

proc create_todo(sock: int32, request: ptr uint8, path: ptr uint8) =
  var body: ptr uint8 = get_body()
  discard json_parse(body)

  var title: ptr uint8 = json_get(cast[ptr uint8]("title"))

  # Create new todo
  json_builder_start()
  json_builder_add_int(cast[ptr uint8]("id"), next_todo_id)
  json_builder_add_string(cast[ptr uint8]("title"), title)
  json_builder_add_bool(cast[ptr uint8]("completed"), 0)
  var todo_json: ptr uint8 = json_builder_end()

  # Store in KV
  var key: array[32, uint8]
  # Format key: "todo:N"
  ...
  discard kv_set(addr(key[0]), todo_json)

  next_todo_id = next_todo_id + 1

  respond(sock, 201, todo_json)

proc get_todo(sock: int32, request: ptr uint8, path: ptr uint8) =
  var id: ptr uint8 = get_route_param(cast[ptr uint8]("id"))

  # Build key
  var key: array[32, uint8]
  # ...

  var value: array[1024, uint8]
  var len: int32 = kv_get(addr(key[0]), addr(value[0]), 1024)

  if len > 0:
    json(sock, addr(value[0]))
  else:
    not_found(sock)

proc update_todo(sock: int32, request: ptr uint8, path: ptr uint8) =
  # ...

proc delete_todo(sock: int32, request: ptr uint8, path: ptr uint8) =
  var id: ptr uint8 = get_route_param(cast[ptr uint8]("id"))

  var key: array[32, uint8]
  # ...

  if kv_delete(addr(key[0])) == 1:
    respond(sock, 204, cast[ptr uint8](""))
  else:
    not_found(sock)

proc main(): int32 =
  discard kv_open(cast[ptr uint8]("/data/todos.db"))

  discard get(cast[ptr uint8]("/api/todos"), cast[ptr uint8](list_todos))
  discard post(cast[ptr uint8]("/api/todos"), cast[ptr uint8](create_todo))
  discard get(cast[ptr uint8]("/api/todos/:id"), cast[ptr uint8](get_todo))
  discard put(cast[ptr uint8]("/api/todos/:id"), cast[ptr uint8](update_todo))
  discard delete(cast[ptr uint8]("/api/todos/:id"), cast[ptr uint8](delete_todo))

  return run(8080)
```

---

### 12.3 Chat Server

**Files to create**: `userland/chat.bh`, `static/chat.html`

**Implementation**:

WebSocket-based chat server with rooms.

**Features**:
- Multiple chat rooms
- User nicknames
- Join/leave notifications
- Message history (last 100 messages)
- Private messages

**Protocol**:
```json
// Client → Server
{"type": "join", "room": "general", "nick": "Alice"}
{"type": "message", "text": "Hello everyone!"}
{"type": "leave"}
{"type": "private", "to": "Bob", "text": "Hey!"}

// Server → Client
{"type": "joined", "room": "general", "users": ["Alice", "Bob"]}
{"type": "message", "from": "Alice", "text": "Hello everyone!", "time": "10:30"}
{"type": "user_joined", "nick": "Charlie"}
{"type": "user_left", "nick": "Bob"}
{"type": "private", "from": "Alice", "text": "Hey!"}
{"type": "error", "message": "Room not found"}
```

---

### 12.4 File Browser Web UI

**Files to create**: `userland/filebrowser.bh`, `templates/filebrowser.html`

**Features**:
- Browse directories
- View file contents
- Upload files
- Download files
- Create/delete files and directories
- Rename files
- File permissions display

**API**:
```
GET    /api/files?path=/           → List directory
GET    /api/files/:path            → Get file content
POST   /api/files/:path            → Upload file
PUT    /api/files/:path            → Update file
DELETE /api/files/:path            → Delete file/directory
POST   /api/mkdir                  → Create directory
POST   /api/rename                 → Rename file
```

---

## Implementation Priority & Timeline

### High Priority (Immediate)

1. **POST body parsing** - Essential for forms
2. **Static file serving** - Needed for web UIs
3. **Cookie support** - Session management
4. **Logging framework** - Debugging

### Medium Priority (Near-term)

5. **JSON parsing** - API development
6. **Template rendering** - Dynamic HTML
7. **Key-value store** - Persistent data
8. **System monitor web UI** - Showcase application

### Lower Priority (Long-term)

9. **DNS client** - External API access
10. **HTTP client** - Fetch remote data
11. **WebSocket support** - Real-time apps
12. **SQL query engine** - Advanced queries
13. **Worker processes** - Performance
14. **REPL & Test framework** - Developer experience

---

## Dependencies

```
Phase 7.1 (POST body)     → None
Phase 7.2 (Static files)  → None
Phase 7.3 (Templates)     → 7.2 (Static files)
Phase 7.4 (Cookies)       → 7.1 (POST body)
Phase 7.5 (JSON)          → None

Phase 8.1 (DNS)           → None
Phase 8.2 (HTTP client)   → 8.1 (DNS)
Phase 8.3 (WebSocket)     → 7.5 (JSON), SHA-1, Base64
Phase 8.4 (Concurrent)    → None

Phase 9.x (SQL)           → Independent track

Phase 10.1 (Workers)      → Fork syscall
Phase 10.2 (KV Store)     → None
Phase 10.3 (Logging)      → None

Phase 11.x (Dev tools)    → Various

Phase 12.1 (Sysmon)       → 7.2, 7.3, 7.5
Phase 12.2 (Todo API)     → 7.1, 7.5, 10.2
Phase 12.3 (Chat)         → 8.3
Phase 12.4 (File browser) → 7.2, 7.3
```

---

## Success Metrics

For each phase:
- **Functional**: Feature works as documented
- **Tested**: Unit tests pass
- **Documented**: Usage examples provided
- **Integrated**: Works with existing features
- **Performant**: Acceptable for intended use

---

## Notes

- All code in Brainhair (no libc)
- Memory management: brk/stack only (no mmap for userland)
- Single-threaded (no pthread)
- Target: BrainhairOS microkernel on QEMU
- Also runnable on Linux for testing

---

*Document created: December 2024*
*Last updated: December 2024*
