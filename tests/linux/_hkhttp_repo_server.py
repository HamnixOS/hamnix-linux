#!/usr/bin/env python3
#
# The repository server for tests/linux/hpm_kernel_http.sh.
#
# It serves a directory over http, and it can be told to serve the KERNEL
# ARTIFACT badly in three specific ways. That is the whole reason it exists
# rather than `python3 -m http.server`: with an http channel the negative
# controls cost NOTHING to stage -- no second 4 GiB medium, no rebuild -- so
# each one is the same medium and the same signed index against a server that
# misbehaves in a different, named way.
#
#   MODE=good   serve everything correctly
#   MODE=cut    serve the artifact's declared Content-Length, then send only a
#               PREFIX and CLOSE the connection. THE DROPPED TRANSFER.
#   MODE=flip   serve the whole artifact with ONE BYTE flipped. The index still
#               records the original digest and is still validly signed, so
#               the signature check passes and the CONTENT check must fail.
#
# The mode is read from a FILE on every request, so the harness can change it
# between boots without restarting the server.
import os
import sys
import socket
import threading

ROOT = os.path.abspath(sys.argv[1])
PORT = int(sys.argv[2])
MODEFILE = sys.argv[3]
ARTIFACT_SUFFIX = sys.argv[4] if len(sys.argv) > 4 else ".efi"


def mode():
    try:
        return open(MODEFILE).read().strip() or "good"
    except OSError:
        return "good"


def log(msg):
    sys.stderr.write("[repo] %s\n" % msg)
    sys.stderr.flush()


def resolve(path):
    p = path.split("?", 1)[0]
    if "%" in p:
        import urllib.parse
        p = urllib.parse.unquote(p)
    full = os.path.abspath(os.path.join(ROOT, p.lstrip("/")))
    # No escaping the served root.
    if full != ROOT and not full.startswith(ROOT + os.sep):
        return None
    return full


def handle(conn, addr):
    try:
        conn.settimeout(30)
        req = b""
        while b"\r\n\r\n" not in req:
            d = conn.recv(8192)
            if not d:
                return
            req += d
            if len(req) > 65536:
                return
        line = req.split(b"\r\n", 1)[0].decode("latin1")
        parts = line.split(" ")
        if len(parts) < 2:
            return
        path = parts[1]
        full = resolve(path)
        if full is None or not os.path.isfile(full):
            conn.sendall(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n"
                         b"Connection: close\r\n\r\n")
            log("404 %s" % path)
            return
        body = open(full, "rb").read()
        m = mode()
        is_artifact = full.endswith(ARTIFACT_SUFFIX)

        if is_artifact and m == "flip":
            b = bytearray(body)
            off = len(b) // 2
            b[off] ^= 0xFF
            body = bytes(b)
            log("FLIP one byte at %d of %s (%d bytes)" % (off, path, len(body)))
            conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\n"
                         b"Connection: close\r\n\r\n" % len(body))
            conn.sendall(body)
            return

        if is_artifact and m == "cut":
            # DECLARE the full length, then deliver a prefix and hang up. This
            # is the dropped transfer, and it is the case the RAM buffer in
            # user/hkslot.ad exists to make safe.
            cut = int(len(body) * 0.45)
            conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\n"
                         b"Connection: close\r\n\r\n" % len(body))
            conn.sendall(body[:cut])
            log("CUT %s at %d of %d, then CLOSE" % (path, cut, len(body)))
            try:
                conn.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            return

        conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\n"
                     b"Connection: close\r\n\r\n" % len(body))
        conn.sendall(body)
        if is_artifact:
            log("200 %s (%d bytes, whole)" % (path, len(body)))
    except Exception as e:  # noqa: BLE001 -- a test server; log and move on
        log("error: %r" % (e,))
    finally:
        try:
            conn.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        conn.close()


def main():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("0.0.0.0", PORT))
    s.listen(32)
    log("serving %s on 0.0.0.0:%d (mode file %s)" % (ROOT, PORT, MODEFILE))
    while True:
        c, a = s.accept()
        threading.Thread(target=handle, args=(c, a), daemon=True).start()


main()
