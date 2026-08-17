#!/usr/bin/env bash
#
# REGISTRATION, 2026-08-17. Until this date scripts/test_gate_registration.sh
# globbed only scripts/test_*.sh, so this directory was invisible to the gate
# against unregistered gates and every file in it read as coverage without
# being coverage. This gate is ON-DEMAND: not in ci_battery_manifest.txt
# because nobody has measured its host runtime yet, and the battery is 12-way
# sharded under a 50-minute cap -- registering an unmeasured gate is how a
# shard goes from green to timed-out. Measure it, then move it into the
# manifest.
#
# Its host runtime and its pass/fail were NOT measured when this line was
# written. If you make it cheap enough for the battery, add the manifest line
# and delete this block.
#
# tests/linux/hpm_index_sig.sh — hpm's index.json.sig path, against a server
# whose RESPONSE HEADERS are the size a real CDN's are.
#
# THE BUG THIS EXISTS FOR. `hpm refresh` against https://255.one/ fetched
# index.json (50,473 bytes) and then failed to fetch index.json.sig (129
# bytes) from the same server in the same run, and said:
#
#     hpm: HTTP fetch failed
#     hpm: no index.json.sig for this channel (unsigned repo).
#
# The cause was not TLS, not a second connection, not the repo. fetch_to_buf
# hands its destination buffer STRAIGHT to http9.http_get, whose dst_cap
# covers the STATUS LINE + HEADERS + BODY; http9 returns -6 as soon as the
# response reaches dst_cap. The signature buffer was 512 bytes. GitHub Pages
# puts 640 bytes of headers in front of the 129-byte signature. Signing had
# therefore never worked from the client side, and the message blamed the
# server for it.
#
# So the regression this gate has to catch is a SIZE, and it is invisible to
# any test served by python's http.server, whose headers are 203 bytes: total
# 332 < 512, and the old broken hpm passes. The server here pads its headers
# to a configurable size, defaulting to the 640 bytes measured off
# 255.one/linux/index.json.sig, and check 1 fails on the pre-fix binary.
#
# It also pins the OTHER half — that the message must state what happened:
#   * a real 404 for index.json.sig  -> "unsigned repo", and --allow-unsigned
#                                       is the right advice
#   * anything else (500, TLS, a body that will not fit) -> a FETCH FAILURE,
#                                       explicitly NOT evidence of an unsigned
#                                       repo, and still refused
# because "unsigned repo" printed for a transport fault sends the operator to
# --allow-unsigned, which disables signature checking on a repo that is signed.
#
# Everything is host-side and loopback; no VM, no network, ~10 seconds.
# Usage: tests/linux/hpm_index_sig.sh
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

WORK="${HAMLINUX_SIGWORK:-build/hpmsig}"
mkdir -p "$WORK"
OUT="$WORK/hpm.elf"
PORT="${HAMLINUX_SIGPORT:-18823}"
SRVLOG="$WORK/server.log"
SRVPID=""

pass=0; fail=0
say()  { echo "[hpmsig] $*"; }
ok()   { pass=$((pass+1)); echo "[hpmsig] PASS: $*"; }
bad()  { fail=$((fail+1)); echo "[hpmsig] FAIL: $*"; }

cleanup() {
    if [ -n "$SRVPID" ] && kill -0 "$SRVPID" 2>/dev/null; then
        kill "$SRVPID" 2>/dev/null
        wait "$SRVPID" 2>/dev/null
    fi
}
trap cleanup EXIT
# A bare EXIT trap does not run when the shell is killed by a signal, so a
# gate stopped by `timeout` (TERM) or ^C (INT) skipped its cleanup entirely.
# Re-exit on those, which makes the EXIT trap above run on every path out.
trap 'exit 130' INT TERM HUP

# -- the repo: a signed index, signed by scripts/hpm_sign.py with a key we
#    mint here, so the test owns both halves and needs no secret from anywhere.
KEYDIR="$WORK/key"; mkdir -p "$KEYDIR"
REPO="$WORK/repo/main"; mkdir -p "$REPO"

python3 - "$KEYDIR" <<'PYKEY' || { echo "[hpmsig] cannot mint a test key" >&2; exit 1; }
import sys, os
d = sys.argv[1]
try:
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    from cryptography.hazmat.primitives import serialization as ser
except Exception as e:
    print("no python cryptography:", e); sys.exit(1)
sk = Ed25519PrivateKey.generate()
raw = sk.private_bytes(ser.Encoding.Raw, ser.PrivateFormat.Raw, ser.NoEncryption())
pub = sk.public_key().public_bytes(ser.Encoding.Raw, ser.PublicFormat.Raw)
open(os.path.join(d, "sec.hex"), "w").write(raw.hex() + "\n")
open(os.path.join(d, "pub.hex"), "w").write(pub.hex() + "\n")
PYKEY

# A small but REAL index: hpm parses it, so it has to be a valid envelope.
cat > "$REPO/index.json" <<'JSON'
{"schema":1,"packages":[{"name":"hamnix-sigtest","version":"1.0.0","arch":"x86_64","size":3,"sha256":"9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08","url":"pkgs/hamnix-sigtest-1.0.0.tar.gz","description":"a package that exists only to be indexed"}]}
JSON

sign_index() {
    python3 - "$KEYDIR/sec.hex" "$REPO/index.json" "$REPO/index.json.sig" <<'PYSIGN'
import sys
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
sk = Ed25519PrivateKey.from_private_bytes(bytes.fromhex(open(sys.argv[1]).read().strip()))
sig = sk.sign(open(sys.argv[2], "rb").read())
open(sys.argv[3], "w").write(sig.hex() + "\n")
PYSIGN
}
sign_index || { echo "[hpmsig] cannot sign" >&2; exit 1; }

# -- the server: real headers, padded to a CDN's size ------------------
cat > "$WORK/cdn.py" <<'PYSRV'
# A static file server whose response headers are as big as a CDN's. The
# padding is the whole point: python's http.server emits 203 bytes of headers
# and cannot reproduce a bug whose cause is a 640-byte header block.
import os, sys, http.server
ROOT = sys.argv[1]; PORT = int(sys.argv[2]); PAD = int(sys.argv[3])

class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    def log_message(self, *a): pass
    def _pad(self):
        # Spread the padding over several headers, as a CDN does, rather than
        # one absurd line: name+": "+value+CRLF per header.
        n, i = PAD, 0
        while n > 0:
            chunk = min(n, 200)
            name = "x-hamnix-pad-%d" % i
            body = "z" * max(1, chunk - len(name) - 4)
            self.send_header(name, body)
            n -= len(name) + len(body) + 4
            i += 1
    def do_GET(self):
        path = os.path.normpath(self.path.split("?")[0]).lstrip("/")
        full = os.path.join(ROOT, path)
        force = os.environ.get("HAMNIX_FORCE_STATUS", "")
        if force and self.path.endswith(".sig"):
            data = b"<html><body>server exploded</body></html>"
            self.send_response(int(force))
            self._pad()
            self.send_header("content-length", str(len(data)))
            self.end_headers(); self.wfile.write(data); return
        if not os.path.isfile(full):
            # A CDN's 404 is a whole HTML page, not a line: 255.one answers a
            # missing object with 9,379 bytes of it. The status has to survive
            # a body that large or "404, unsigned" is indistinguishable from
            # "the fetch broke".
            data = ("<!doctype html><title>404</title>" + "x" * 9300).encode()
            self.send_response(404)
            self._pad()
            self.send_header("content-length", str(len(data)))
            self.end_headers(); self.wfile.write(data); return
        data = open(full, "rb").read()
        self.send_response(200)
        self._pad()
        self.send_header("content-length", str(len(data)))
        self.end_headers(); self.wfile.write(data)

http.server.HTTPServer(("127.0.0.1", PORT), H).serve_forever()
PYSRV

start_server() {   # start_server <pad-bytes> [force-status]
    cleanup
    HAMNIX_FORCE_STATUS="${2:-}" python3 "$WORK/cdn.py" "$WORK/repo" "$PORT" "$1" \
        >"$SRVLOG" 2>&1 &
    SRVPID=$!
    for _ in $(seq 1 50); do
        if curl -s -o /dev/null "http://127.0.0.1:$PORT/main/index.json"; then return 0; fi
        sleep 0.1
    done
    echo "[hpmsig] server did not come up" >&2; return 1
}

# -- build hpm ---------------------------------------------------------
say "building user/hpm.ad -> $OUT"
scripts/hamlinux_build.sh user/hpm.ad "$OUT" >"$WORK/build.log" 2>&1 || {
    echo "[hpmsig] BUILD FAILED — see $WORK/build.log" >&2
    tail -20 "$WORK/build.log" >&2
    exit 1
}

TRUSTED="$KEYDIR/trusted.pub"
cp "$KEYDIR/pub.hex" "$TRUSTED"
# hpm parses its flags BEFORE the command word, so extras go in front of
# `refresh`, not after it.
run_refresh() {   # run_refresh [extra flags...] -> output in $LAST, rc in $LASTRC
    LAST="$("$OUT" --repo="http://127.0.0.1:$PORT/" \
                   --trusted-key="$TRUSTED" "$@" refresh 2>&1)"
    LASTRC=$?
}
has() { case "$LAST" in *"$1"*) return 0;; *) return 1;; esac; }

# -- 1. THE REGRESSION. CDN-sized headers, a valid signature, no flags.
say "check 1: 640-byte header block + a 129-byte signature, no flags"
start_server 640 || exit 1
run_refresh
if has "refreshed index" && ! has "unsigned"; then
    ok "signed index accepted through a CDN-sized header block"
else
    bad "signed index REJECTED behind CDN-sized headers (the original bug)"
    echo "$LAST" | sed 's/^/[hpmsig]   | /'
fi

# The old code failed at 512 bytes of response. Prove the gate is sharp by
# pushing the header block far past any plausible buffer-sizing shortcut.
say "check 2: a 4 KiB header block still verifies"
start_server 4096 || exit 1
run_refresh
if has "refreshed index"; then
    ok "signed index accepted through a 4 KiB header block"
else
    bad "a 4 KiB header block broke the signature fetch"
    echo "$LAST" | sed 's/^/[hpmsig]   | /'
fi

# -- 3. tampered index must still be REFUSED.
say "check 3: tampered index"
start_server 640 || exit 1
cp "$REPO/index.json" "$REPO/index.json.keep"
sed -i 's/"version":"1.0.0"/"version":"9.9.9"/' "$REPO/index.json"
run_refresh
if has "signature INVALID" && ! has "refreshed index"; then
    ok "tampered index refused, and named as an invalid signature"
else
    bad "tampered index was NOT refused as an invalid signature"
    echo "$LAST" | sed 's/^/[hpmsig]   | /'
fi
mv "$REPO/index.json.keep" "$REPO/index.json"

# -- 4. a genuinely unsigned repo: a REAL 404, behind a 9 KB error page.
say "check 4: no index.json.sig at all (404 + a 9 KB error page)"
mv "$REPO/index.json.sig" "$REPO/index.json.sig.hidden"
start_server 640 || exit 1
run_refresh
if has "404" && has "unsigned repo" && has "--allow-unsigned" \
        && ! has "refreshed index"; then
    ok "unsigned repo named accurately (404), and --allow-unsigned advised"
else
    bad "an absent signature was not reported as a 404 / unsigned repo"
    echo "$LAST" | sed 's/^/[hpmsig]   | /'
fi

# ... and --allow-unsigned is still the working escape hatch for it.
run_refresh --allow-unsigned
if has "refreshed index" && has "WARNING"; then
    ok "--allow-unsigned still refreshes an unsigned repo, loudly"
else
    bad "--allow-unsigned no longer works on an unsigned repo"
    echo "$LAST" | sed 's/^/[hpmsig]   | /'
fi
mv "$REPO/index.json.sig.hidden" "$REPO/index.json.sig"

# -- 5. THE MISLEADING MESSAGE. A fetch that FAILS must not be reported as
#       an unsigned repo — that is the sentence that cost this bug its months.
say "check 5: the signature fetch fails (HTTP 500)"
start_server 640 500 || exit 1
run_refresh
if has "500" && ! has "unsigned repo" && ! has "refreshed index"; then
    ok "a 500 on index.json.sig is reported as a failed fetch, not as unsigned"
else
    bad "a failed signature fetch was still reported as an unsigned repo"
    echo "$LAST" | sed 's/^/[hpmsig]   | /'
fi

# -- 6. the server is gone. Not an unsigned repo, and — the thing this found
#       — not a SUCCESS either: refresh used to print "refreshed index ...
#       (0 packages)" and exit 0 after clobbering the cache with an empty
#       envelope, so the next command said "no such package" to a machine that
#       merely had no network.
say "check 6: the server is gone entirely"
cleanup; SRVPID=""
run_refresh
if ! has "unsigned repo" && ! has "refreshed index" && [ "$LASTRC" -ne 0 ]; then
    ok "an unreachable server fails loudly: not 'unsigned', not a 0-package success"
else
    bad "an unreachable server produced a misleading or success-shaped result (rc=$LASTRC)"
    echo "$LAST" | sed 's/^/[hpmsig]   | /'
fi

echo "[hpmsig] ---- $pass PASS, $fail FAIL ----"
[ "$fail" -eq 0 ] || exit 1
exit 0
