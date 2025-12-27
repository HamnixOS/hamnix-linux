# BrainhairOS Networking Stack

This document describes the networking capabilities of BrainhairOS.

## Overview

BrainhairOS includes a complete TCP/IP networking stack implemented from scratch in Brainhair and x86 assembly. The stack runs on bare-metal x86 hardware (via QEMU) and provides:

- E1000 network card driver
- Ethernet frame handling
- ARP (Address Resolution Protocol)
- IP (Internet Protocol v4)
- ICMP (ping)
- UDP (User Datagram Protocol)
- DHCP client
- TCP (Transmission Control Protocol)
- HTTP server with Flask-style routing

## Architecture

```
┌─────────────────────────────────────────────┐
│            Flask Web Framework               │
│   (route registration, request handling)     │
├─────────────────────────────────────────────┤
│              HTTP Parser                     │
│   (method, path, headers extraction)         │
├─────────────────────────────────────────────┤
│                 TCP                          │
│   (connection state, SYN/ACK, data flow)     │
├─────────────────────────────────────────────┤
│             UDP / ICMP                       │
│   (DHCP client, ping responses)              │
├─────────────────────────────────────────────┤
│                  IP                          │
│   (routing, fragmentation)                   │
├─────────────────────────────────────────────┤
│                 ARP                          │
│   (MAC address resolution)                   │
├─────────────────────────────────────────────┤
│              Ethernet                        │
│   (frame formatting, checksums)              │
├─────────────────────────────────────────────┤
│           E1000 NIC Driver                   │
│   (PCI enumeration, ring buffers)            │
└─────────────────────────────────────────────┘
```

## E1000 Driver

The E1000 driver (`kernel/net.asm`) handles:

- PCI device enumeration to find the NIC
- MMIO register access for control
- Transmit/receive descriptor rings
- Interrupt handling for packet arrival

### Key Registers

| Register | Offset | Purpose |
|----------|--------|---------|
| CTRL | 0x0000 | Device control |
| STATUS | 0x0008 | Device status |
| EERD | 0x0014 | EEPROM read |
| TDBAL | 0x3800 | TX descriptor base |
| RDBAL | 0x2800 | RX descriptor base |
| TCTL | 0x0400 | TX control |
| RCTL | 0x0100 | RX control |

## Protocol Implementation

### ARP

The ARP table caches MAC-to-IP mappings:

```brainhair
var arp_table: array[ARP_TABLE_SIZE * ARP_ENTRY_SIZE, uint8]
# Entry format: IP (4 bytes) + MAC (6 bytes) + valid flag (1 byte)
```

ARP requests are sent when we need to resolve an IP address. Replies update the cache.

### IP

IP packet handling includes:
- Header checksum calculation
- Source/destination address handling
- Protocol demultiplexing (ICMP=1, UDP=17, TCP=6)

### TCP

The TCP implementation supports:

**Connection States:**
- `TCP_STATE_CLOSED` (0)
- `TCP_STATE_LISTEN` (1)
- `TCP_STATE_SYN_SENT` (2)
- `TCP_STATE_SYN_RECEIVED` (3)
- `TCP_STATE_ESTABLISHED` (4)
- `TCP_STATE_FIN_WAIT` (5)
- `TCP_STATE_CLOSE_WAIT` (6)
- `TCP_STATE_CLOSING` (7)

**State Machine:**
```
CLOSED --listen--> LISTEN
LISTEN --SYN rcvd--> SYN_RECEIVED --ACK rcvd--> ESTABLISHED
ESTABLISHED --close--> send RST --> CLOSED
```

**Features:**
- Sequence/acknowledgment number tracking
- SYN retransmission for dropped packets
- Data receive buffering
- Connection timeout handling

### DHCP

DHCP client for automatic IP configuration:

1. Send DISCOVER broadcast
2. Receive OFFER with IP assignment
3. Send REQUEST for offered IP
4. Receive ACK, bind IP address

## Flask-Style Web Framework

The `lib/flask.bh` library provides a Python Flask-like API:

### Route Registration

```brainhair
import "lib/flask"

# Register routes - static paths
discard route(cast[ptr uint8]("/"), cast[ptr uint8](index_handler))
discard get(cast[ptr uint8]("/api/data"), cast[ptr uint8](api_handler))
discard post(cast[ptr uint8]("/submit"), cast[ptr uint8](submit_handler))

# Dynamic routes with parameters
discard get(cast[ptr uint8]("/users/:id"), cast[ptr uint8](user_handler))
discard get(cast[ptr uint8]("/posts/:id/comments/:cid"), cast[ptr uint8](comment_handler))
```

### Handler Functions

Handlers receive the socket, raw request, and parsed path:

```brainhair
proc my_handler(sock: int32, request: ptr uint8, path: ptr uint8) =
  # Send response
  text(sock, cast[ptr uint8]("Hello World"))
```

### Query String Parameters

Query strings are automatically parsed from URLs like `/search?q=hello&page=2`:

```brainhair
proc search_handler(sock: int32, request: ptr uint8, path: ptr uint8) =
  # Get query parameters
  var query: ptr uint8 = get_query_param(cast[ptr uint8]("q"))
  var page: ptr uint8 = get_query_param(cast[ptr uint8]("page"))

  # Check parameter count
  var count: int32 = get_query_param_count()

  # Use the values...
  if cast[int32](query) != 0:
    text(sock, query)
```

### Route Parameters

Dynamic route segments (`:param`) are extracted automatically:

```brainhair
proc user_handler(sock: int32, request: ptr uint8, path: ptr uint8) =
  # For route "/users/:id" matching "/users/42"
  var user_id: ptr uint8 = get_route_param(cast[ptr uint8]("id"))
  # user_id now points to "42"
```

### Request Headers

HTTP headers are parsed and accessible:

```brainhair
proc api_handler(sock: int32, request: ptr uint8, path: ptr uint8) =
  # Get specific header
  var content_type: ptr uint8 = get_header(cast[ptr uint8]("Content-Type"))
  var auth: ptr uint8 = get_header(cast[ptr uint8]("Authorization"))

  # Get Content-Length as integer
  var body_len: int32 = get_content_length()
```

### URL Encoding/Decoding

Handle URL-encoded data:

```brainhair
var decoded: array[256, uint8]
var encoded: array[256, uint8]

# Decode %20 -> space, + -> space, %2F -> /
var len: int32 = url_decode(input, addr(decoded[0]), 256)

# Encode special characters
var len: int32 = url_encode(input, addr(encoded[0]), 256)
```

### POST Body Parsing

Form data is automatically parsed for `application/x-www-form-urlencoded`:

```brainhair
proc submit_handler(sock: int32, request: ptr uint8, path: ptr uint8) =
  # Get POST parameters
  var username: ptr uint8 = get_post_param(cast[ptr uint8]("username"))
  var password: ptr uint8 = get_post_param(cast[ptr uint8]("password"))

  # Get raw body (for JSON or other content types)
  var body: ptr uint8 = get_body()
  var body_len: int32 = get_body_length()

  # Check parameter count
  var count: int32 = get_post_param_count()
```

### Cookie Support

Read and set cookies:

```brainhair
proc login_handler(sock: int32, request: ptr uint8, path: ptr uint8) =
  # Read request cookies
  var session: ptr uint8 = get_cookie(cast[ptr uint8]("session"))
  var count: int32 = get_cookie_count()

  # Set response cookies
  discard set_cookie(cast[ptr uint8]("session"), cast[ptr uint8]("abc123"))
  discard set_cookie_path(cast[ptr uint8]("user"), cast[ptr uint8]("john"), cast[ptr uint8]("/"))
  discard set_cookie_secure(cast[ptr uint8]("auth"), cast[ptr uint8]("token"), cast[ptr uint8]("/"), 3600)

  # Delete a cookie
  discard delete_cookie(cast[ptr uint8]("old_session"))
```

### Static File Serving

Serve static content with automatic MIME type detection:

```brainhair
# Register static files
discard static_str(cast[ptr uint8]("/style.css"), cast[ptr uint8]("body { color: black; }"))
discard static_file(cast[ptr uint8]("/data.bin"), binary_data, 1024)

# Serve static file manually
proc handler(sock: int32, request: ptr uint8, path: ptr uint8) =
  if serve_static(sock, path) == 0:
    not_found(sock)
```

Supported MIME types:
- `.html`, `.htm` - text/html
- `.css` - text/css
- `.js` - application/javascript
- `.json` - application/json
- `.png`, `.jpg`, `.gif`, `.ico`, `.svg` - image types
- `.txt` - text/plain
- `.xml` - application/xml
- `.woff`, `.woff2` - font types

### Response Helpers

| Function | Content-Type | Usage |
|----------|--------------|-------|
| `text(sock, content)` | text/plain | Plain text response |
| `html(sock, content)` | text/html | HTML page |
| `json(sock, content)` | application/json | JSON data |
| `redirect(sock, url)` | - | HTTP 302 redirect |
| `not_found(sock)` | text/html | 404 error page |
| `server_error(sock)` | text/html | 500 error page |
| `respond(sock, status, content)` | text/html | Custom status |

### Running the Server

```brainhair
proc main(): int32 =
  # Register routes
  discard route(cast[ptr uint8]("/"), cast[ptr uint8](index))
  discard get(cast[ptr uint8]("/users/:id"), cast[ptr uint8](show_user))

  # Start server on port 8080
  return run(8080)

  # Or with debug output:
  # return run_debug(8080)
```

## Userland Network API

For userland programs, `lib/net.bh` provides:

```brainhair
# Create listening socket
var sock: int32 = net_listen(8080)

# Poll for network events (call frequently)
net_poll()

# Check if connection is ready
if net_accept_ready(sock) == 1:
  # Check if data is available (non-blocking)
  if net_has_data(sock) == 1:
    # Read data (non-blocking)
    var n: int32 = net_recv(sock, buffer, size)

  # Or read with timeout (blocking)
  var n: int32 = net_recv_blocking(sock, buffer, size, timeout_ms)

  # Send response
  discard net_send(sock, response, length)
  # Or send all data (blocking)
  discard net_send_all(sock, response, length)

# Close connection
net_close(sock)
```

### Network Functions

| Function | Description |
|----------|-------------|
| `net_listen(port)` | Create listening socket, returns handle |
| `net_accept_ready(sock)` | Check if connection established (1=yes) |
| `net_has_data(sock)` | Check if data available to read (1=yes) |
| `net_recv(sock, buf, max)` | Non-blocking receive |
| `net_recv_blocking(sock, buf, max, timeout)` | Blocking receive with timeout |
| `net_send(sock, data, len)` | Send data |
| `net_send_all(sock, data, len)` | Send all data (blocking) |
| `net_send_str(sock, str)` | Send null-terminated string |
| `net_close(sock)` | Close connection |
| `net_poll()` | Process network events |
| `net_state(sock)` | Get TCP connection state |
| `net_is_connected(sock)` | Check if ESTABLISHED (1=yes) |
| `parse_ipv4(str, out)` | Parse "10.0.2.2" to bytes |
| `format_ipv4(ip, buf)` | Format bytes to string |

## Testing

### Building with Networking

```bash
# Build microkernel with webapp
make microkernel-uweb

# Run with networking enabled
qemu-system-i386 \
  -drive file=build/brainhair.img,format=raw \
  -device e1000,netdev=net0 \
  -netdev user,id=net0,hostfwd=tcp::8080-:8080

# Test from host
curl http://localhost:8080/
```

### Running Tests

```bash
# Full HTTP server test
make test-http

# Kernel boot and networking test
make test-kernel
```

## Known Limitations

### QEMU SLiRP NAT Issues

QEMU's user-mode networking (SLiRP) has issues with rapid TCP port reuse:

- First HTTP request works correctly
- Subsequent requests may timeout
- Server correctly processes requests but NAT fails to deliver responses

**Workaround:** Add delays between requests or use TAP networking.

### TAP Networking (Recommended for Production)

For reliable multi-request testing, use TAP networking:

```bash
# Create TAP interface (requires root)
sudo ip tuntap add dev tap0 mode tap
sudo ip addr add 10.0.2.1/24 dev tap0
sudo ip link set tap0 up

# Run QEMU with TAP
qemu-system-i386 \
  -drive file=build/brainhair.img,format=raw \
  -device e1000,netdev=net0 \
  -netdev tap,id=net0,ifname=tap0,script=no,downscript=no
```

## Debug Output

The networking stack outputs debug messages to serial console:

```
[OK] Network: 52:54:00:12:34:56    # MAC address
[DHCP] Disc                         # DHCP discovery sent
Offer: 10.0.2.15                    # DHCP offer received
Bound: 10.0.2.15                    # IP bound
[OK] IP: 10.0.2.15                  # DHCP complete

[TCP] Listen on port 0x00001F90     # Listening on 8080
[TCP] Created listener              # Socket ready

SYN                                 # TCP SYN received
SYN-ACK conn=0x00000000             # SYN-ACK sent
[TCP] ACK rcvd -> ESTABLISHED       # Connection established
[TCP] DATA received, len=0x0000004E # HTTP request received
[Flask] recv n=78                   # Flask processing
[Flask] route_idx=0                 # Route matched
[TCP] write conn=0x00000000         # Response sent
[TCP] Sending RST                   # Connection closed
```

## JSON Library

The `lib/json.bh` library provides JSON parsing and building:

### Building JSON

```brainhair
import "lib/json"

# Build a JSON object
json_clear()
discard json_object_start()
discard json_kv_string(cast[ptr uint8]("name"), cast[ptr uint8]("John"))
discard json_kv_int(cast[ptr uint8]("age"), 30)
discard json_kv_bool(cast[ptr uint8]("active"), 1)
discard json_object_end()

# Get the result
var result: ptr uint8 = json_get()
# result = {"name":"John","age":30,"active":true}
```

### Parsing JSON

```brainhair
var data: ptr uint8 = cast[ptr uint8]("{\"name\":\"John\",\"age\":30}")
var tokens: int32 = json_parse_str(data)

if tokens > 0:
  # Get values from object (token 0 is the root object)
  var name: array[64, uint8]
  discard json_get_string(0, cast[ptr uint8]("name"), addr(name[0]), 64)

  var age: int32 = json_get_int(0, cast[ptr uint8]("age"))
```

## Logging Library

The `lib/log.bh` library provides structured logging:

```brainhair
import "lib/log"

# Set log level
log_set_level(LOG_DEBUG)

# Basic logging
log_info(cast[ptr uint8]("Server started"))
log_error(cast[ptr uint8]("Connection failed"))

# Key-value logging
log_kv(LOG_INFO, cast[ptr uint8]("user"), cast[ptr uint8]("john"))
log_kv_int(LOG_DEBUG, cast[ptr uint8]("port"), 8080)

# HTTP request logging
log_request(cast[ptr uint8]("GET"), cast[ptr uint8]("/api/users"), 200)

# Structured logging
log_start(LOG_INFO)
log_field(cast[ptr uint8]("method"), cast[ptr uint8]("GET"))
log_field(cast[ptr uint8]("path"), cast[ptr uint8]("/api"))
log_field_int(cast[ptr uint8]("status"), 200)
log_end()

# Hex dump for debugging
log_hex_dump(LOG_DEBUG, data, 64)
```

Log levels: `LOG_DEBUG`, `LOG_INFO`, `LOG_WARN`, `LOG_ERROR`, `LOG_NONE`

## Files

| File | Description |
|------|-------------|
| `kernel/net.asm` | E1000 driver, PCI enumeration |
| `kernel/kernel_main.bh` | TCP/IP stack, DHCP, ARP |
| `lib/net.bh` | Userland network syscalls |
| `lib/flask.bh` | Flask-style web framework |
| `lib/json.bh` | JSON parsing and building |
| `lib/log.bh` | Structured logging framework |
| `lib/string.bh` | String utilities |
| `userland/webapp.bh` | Example web application |
