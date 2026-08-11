#!/usr/bin/env python3
"""tests/linux/http9_chatty_server.py — an HTTP server that is CHATTY on
purpose, because the obvious one is not and that is why this bug lived.

WHY THIS FILE EXISTS (read before replacing it with http.server)
================================================================
`user/http9.ad`'s http_get takes ONE destination buffer whose `dst_cap`
covers the status line + the headers + the body, and it returns -6 --
DISCARDING the HTTP status -- the moment the response reaches that cap.
So the size of a caller's buffer is a correctness question about a number
the caller cannot see: the SERVER's header block.

python's `http.server` sends a 203-byte header block (332 bytes total for a
129-byte body). Every buffer anyone would plausibly write is bigger than
that, so a test written the obvious way PASSES ON BROKEN CODE. That is
exactly how `hpm` shipped for the whole life of the package repository
unable to fetch a 129-byte signature: GitHub Pages answers with ~640 bytes
of headers, 640 + 129 = 769 > the 512-byte buffer, and `hpm refresh`
reported "unsigned repo" -- a cause it had never checked.

This server reproduces that over PLAIN HTTP, which exonerates the TLS layer
in one step and makes the gate fast. It pads its header block to a
configurable size (default 640 bytes, GitHub Pages' shape) using the same
KINDS of headers a CDN sends, and it prints the exact byte counts it emitted
so a test asserts against a measurement rather than a guess.

ROUTES
    /tiny            200, a 129-byte body (the hpm signature's size)
    /n/<bytes>       200, a body of exactly <bytes> bytes
    /missing         404, with a ~9 KB HTML error page -- a resource that
                     genuinely 404s can come back far larger than the
                     resource would have been, so a buffer sized for the
                     expected BODY loses the status to the same -6 and
                     cannot tell "missing" from "broken".
    /hdrsize         200, body is the decimal size of this server's header
                     block (so a test can print what it is measuring)

USAGE
    http9_chatty_server.py [--port N] [--pad BYTES] [--host 127.0.0.1]
Prints one line "LISTENING <host> <port> hdrbytes=<n>" on stdout when ready.
"""

import argparse
import socket
import socketserver
import sys
import threading

# A 129-byte body: the size of the detached signature `hpm refresh` fetches.
TINY_BODY = (b"-----BEGIN HAMNIX SIGNATURE-----\n"
             b"9c1f4e2ab8d75630aa41ff02c7e5b9d38401726fbc0e5a93d2718c46ef0b53a7\n"
             b"-----END HAMNIX SIGNATURE-----\n")
assert len(TINY_BODY) == 129, len(TINY_BODY)

# A 404 body that is far LARGER than the resource would have been -- GitHub
# Pages' own 404 page is ~9 KB of HTML.
NOTFOUND_BODY = (b"<!DOCTYPE html><html><head><title>404 Not Found</title>"
                 b"</head><body><h1>404</h1><p>" + b"not found. " * 800 +
                 b"</p></body></html>")


class Handler(socketserver.StreamRequestHandler):
    pad_bytes = 640
    quiet = False

    def _headers(self, status_line, extra, body_len):
        """Build a header block padded to >= self.pad_bytes.

        The padding is spread over plausible CDN headers rather than one
        enormous one, because a real chatty response is chatty by ACCUMULATION
        (Server, Date, ETag, Cache-Control, Strict-Transport-Security,
        x-served-by, x-cache, x-fastly-request-id, ...) and a single huge
        header would be a strawman a real server never sends.
        """
        ctype = b"Content-Type: application/octet-stream"
        for e in extra:
            if e.lower().startswith(b"content-type:"):
                ctype = e
        extra = [e for e in extra if not e.lower().startswith(b"content-type:")]
        base = [
            b"Server: GitHub.com",
            ctype,
            b"Content-Length: %d" % body_len,
            b"Last-Modified: Mon, 09 Feb 2026 11:22:33 GMT",
            b"Access-Control-Allow-Origin: *",
            b"ETag: \"67a8b9c0-81\"",
            b"expires: Mon, 09 Feb 2026 11:32:33 GMT",
            b"Cache-Control: max-age=600",
            b"x-proxy-cache: MISS",
            b"X-GitHub-Request-Id: 4A2C:1F3B:2D9E07:3C1122:67A8B9C0",
            b"Accept-Ranges: bytes",
            b"Date: Mon, 09 Feb 2026 11:24:01 GMT",
            b"Via: 1.1 varnish",
            b"Age: 88",
            b"X-Served-By: cache-lhr-egll1980051-LHR",
            b"X-Cache: HIT",
            b"X-Cache-Hits: 1",
            b"X-Timer: S1739099041.882134,VS0,VE1",
            b"Vary: Accept-Encoding",
            b"X-Fastly-Request-ID: 9b0e2f7a1c4d8e6350b7a9f2c1d4e8073a5b6c9f",
            b"Connection: close",
        ] + list(extra)

        def block(hdrs):
            return status_line + b"\r\n" + b"\r\n".join(hdrs) + b"\r\n\r\n"

        # Grow with one more plausible header at a time until we clear the pad
        # target; then trim the last one's value so the block lands close to it.
        n = 0
        while len(block(base)) < self.pad_bytes:
            base.append(b"X-Edge-Hint-%02d: c7d4a9f1b30e5628" % n)
            n += 1
        return block(base)

    def handle(self):
        line = self.rfile.readline(65536)
        if not line:
            return
        try:
            path = line.split()[1].decode("latin-1")
        except (IndexError, UnicodeDecodeError):
            path = "/"
        while True:                                   # drain request headers
            h = self.rfile.readline(65536)
            if h in (b"\r\n", b"\n", b""):
                break

        status = b"HTTP/1.1 200 OK"
        extra = []
        if path.startswith("/n/"):
            try:
                nbytes = int(path[3:])
            except ValueError:
                nbytes = 0
            # A recognisable, checkable filler: 64-byte lines that count.
            body = bytearray()
            i = 0
            while len(body) < nbytes:
                body += b"%063d\n" % i
                i += 1
            body = bytes(body[:nbytes])
        elif path == "/missing":
            status = b"HTTP/1.1 404 Not Found"
            body = NOTFOUND_BODY
            extra = [b"Content-Type: text/html; charset=utf-8"]
        elif path == "/hdrsize":
            probe = self._headers(status, extra, 0)
            body = b"%d\n" % len(probe)
        else:
            body = TINY_BODY

        head = self._headers(status, extra, len(body))
        if not self.quiet:
            sys.stderr.write("[chatty] %s -> status=%s hdrbytes=%d "
                             "bodybytes=%d totalbytes=%d\n"
                             % (path, status.split()[1].decode(), len(head),
                                len(body), len(head) + len(body)))
            sys.stderr.flush()
        try:
            self.wfile.write(head)
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=0)
    ap.add_argument("--pad", type=int, default=640,
                    help="minimum header-block size in bytes (default 640, "
                         "the size GitHub Pages actually sends)")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    Handler.pad_bytes = args.pad
    Handler.quiet = args.quiet
    srv = Server((args.host, args.port), Handler)
    hdrbytes = len(Handler._headers(Handler, b"HTTP/1.1 200 OK", [], 129))
    print("LISTENING %s %d hdrbytes=%d"
          % (srv.server_address[0], srv.server_address[1], hdrbytes),
          flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
