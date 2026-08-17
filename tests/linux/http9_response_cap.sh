#!/usr/bin/env bash
#
# REGISTRATION, 2026-08-17. Until this date scripts/test_gate_registration.sh
# globbed only scripts/test_*.sh, so this directory was invisible to the gate
# against unregistered gates and every file in it read as coverage without
# being coverage. This gate is ON-DEMAND: not in ci_battery_manifest.txt
# because it fetches from the live network (255.one), so it fails on a runner
# with no route out and would report a site outage as a code defect.
#
# tests/linux/http9_response_cap.sh — gate the http9 response-cap contract.
#
# WHAT IS BEING GATED
# ===================
# `user/http9.ad`'s http_get once took ONE destination buffer whose `dst_cap`
# covered the status line + the headers + the body, and it returned -6 --
# DISCARDING THE HTTP STATUS -- the moment the response reached that cap. The
# size of a caller's buffer was therefore a correctness question about a number
# the caller cannot see: the SERVER's header block. `hpm` sized 512 bytes for a
# 129-byte signature, GitHub Pages answered with ~640 bytes of headers, and for
# the whole life of the package repository `hpm refresh` could not fetch a
# signature and called it "unsigned repo".
#
# The contract this asserts, after the fix:
#   1. dst_cap caps the BODY ALONE. The head lives in http9's own buffer, so a
#      512-byte buffer fetches a 129-byte resource no matter how chatty the
#      server is.
#   2. A body that EXACTLY fills dst_cap is a complete body, not an overflow.
#   3. When the body genuinely does not fit, the rc is -6 and *out_status IS
#      STILL SET -- "missing" and "broken" stay different answers even for a
#      caller whose buffer is smaller than the 9 KB HTML page a CDN serves for
#      a 404.
#   4. `curl` and `wget` -- the two a person actually runs -- fetch a multi-
#      megabyte resource, and when something IS too big they say so by size and
#      by HTTP status instead of "transport error fetching URL".
#   5. The head is reachable after the fact: `curl -i` prints it, and a -6
#      still answers Content-Type.
#
# WHY THE SERVER IS tests/linux/http9_chatty_server.py AND NOT http.server
# =======================================================================
# python's `http.server` sends a 203-byte header block -- 332 bytes total for a
# 129-byte body -- which every plausible buffer clears. A test of this edge
# written the obvious way PASSES ON BROKEN CODE, which is exactly why the bug
# survived. The gate's server pads its head to 640 bytes out of the same kinds
# of headers a CDN sends, over PLAIN HTTP so the TLS layer is exonerated in one
# step and the whole gate runs in seconds. Step 0 below MEASURES the header
# block and refuses to run if it is not chatty, so this file cannot silently
# decay back into the test that passed either way.
#
# HOW IT RUNS
# ===========
# Host-side, QEMU-free: `user/curl.ad`, `user/wget.ad` and
# `tests/linux/http9_cap_probe.ad` are compiled for x86_64-linux with
# user/http9.ad + user/net9.ad BYTE-FOR-BYTE unchanged, and linked against
# scripts/net9_host_shim.c, which backs the Plan-9 /net file dance with real
# sockets. The [[no-sockets]] invariant holds in the Adder code.
#
# Pass marker: [http9_cap] PASS      Fail marker: [http9_cap] FAIL

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT" || exit 1

OUT="${HTTP9_CAP_OUT:-build/host}"
mkdir -p "$OUT"
WORK="$(mktemp -d "${TMPDIR:-/var/tmp}/http9cap.XXXXXX")"
PASS=0
FAIL=0
SRV_PID=""

cleanup() {
    if [ -n "$SRV_PID" ] && kill -0 "$SRV_PID" 2>/dev/null; then
        kill "$SRV_PID" 2>/dev/null
        wait "$SRV_PID" 2>/dev/null
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT
# A bare EXIT trap does not run when the shell is killed by a signal, so a
# gate stopped by `timeout` (TERM) or ^C (INT) skipped its cleanup entirely.
# Re-exit on those, which makes the EXIT trap above run on every path out.
trap 'exit 130' INT TERM HUP

ok()   { echo "[http9_cap] PASS $*"; PASS=$((PASS + 1)); }
bad()  { echo "[http9_cap] FAIL $*"; FAIL=$((FAIL + 1)); }
# An empty read is not a measurement. See tests/linux/gate_read.sh; used by the
# http_prepend_head arm, which parsed the probe's line with `sed` scripts that
# ECHOED THE WHOLE LINE when the field was absent.
. tests/linux/gate_read.sh

# ---- build ------------------------------------------------------------
build_one() {
    local stem="$1" src="$2" asm
    rm -f "user/$stem.s" "$(dirname "$src")/$stem.s"
    if ! python3 -m compiler.adder compile --target=x86_64-linux --emit-asm \
            "$src" -o "$OUT/${stem}_fs.elf" >"$OUT/${stem}_cap_compile.log" 2>&1; then
        echo "[http9_cap] FAIL: $src did not compile"
        tail -25 "$OUT/${stem}_cap_compile.log"
        return 1
    fi
    asm="$(dirname "$src")/$stem.s"
    [ -f "$asm" ] || asm="user/$stem.s"
    mv -f "$asm" "$OUT/$stem.s" || return 1
    if ! gcc -no-pie -O2 "$OUT/$stem.s" "$OUT/http9cap_shim.o" \
            -lssl -lcrypto -o "$OUT/$stem" 2>"$OUT/${stem}_cap_link.log"; then
        echo "[http9_cap] FAIL: $src did not link"
        tail -20 "$OUT/${stem}_cap_link.log"
        return 1
    fi
    return 0
}

echo "[http9_cap] (1/4) building curl / wget / the cap probe for the host ..."
if ! gcc -O2 -c scripts/net9_host_shim.c -o "$OUT/http9cap_shim.o" \
        2>"$OUT/http9cap_shim.log"; then
    echo "[http9_cap] FAIL: the /net host shim did not compile"
    cat "$OUT/http9cap_shim.log"; exit 1
fi
build_one curl user/curl.ad || exit 1
build_one wget user/wget.ad || exit 1
build_one http9_cap_probe tests/linux/http9_cap_probe.ad || exit 1
CURL="$OUT/curl"; WGET="$OUT/wget"; PROBE="$OUT/http9_cap_probe"
ok "built curl, wget and the cap probe over unchanged http9/net9"

# ---- the chatty server, and a check that it IS chatty ------------------
echo "[http9_cap] (2/4) starting the header-padding server ..."
python3 tests/linux/http9_chatty_server.py --port 0 --pad 640 \
    >"$WORK/srv.out" 2>"$WORK/srv.err" &
SRV_PID=$!
for _ in $(seq 1 100); do
    grep -q '^LISTENING ' "$WORK/srv.out" 2>/dev/null && break
    sleep 0.1
done
read -r _ SRV_HOST SRV_PORT _ < "$WORK/srv.out" || true
if [ -z "${SRV_PORT:-}" ]; then
    echo "[http9_cap] FAIL: the chatty server never came up"
    cat "$WORK/srv.err"; exit 1
fi
U="http://$SRV_HOST:$SRV_PORT"

# STEP 0, and it is a REFUSAL, not an assertion: if the server's header block
# is not actually chatty, every case below would pass on the pre-fix code and
# this file would be worthless. python's http.server sends 203 bytes; the bug
# needs a head that can overrun a caller's buffer on its own.
HDR="$("$PROBE" "$U/tiny" 65536 | head -1 | sed 's/.*HDRLEN=\([0-9]*\).*/\1/')"
if [ -z "$HDR" ] || [ "$HDR" -lt 600 ]; then
    echo "[http9_cap] FAIL: server header block is ${HDR:-?} bytes, not chatty."
    echo "[http9_cap]       This gate is meaningless without one -- see the"
    echo "[http9_cap]       header comment in tests/linux/http9_chatty_server.py."
    exit 1
fi
ok "server header block measured at $HDR bytes (python's http.server sends 203)"

# ---- the probe cases: the cap is about the BODY -----------------------
echo "[http9_cap] (3/4) http9 cap contract ..."
probe() { "$PROBE" "$1" "$2" 2>/dev/null | head -1; }
expect() {
    local what="$1" got="$2" want="$3"
    case "$got" in
        *"$want"*) ok "$what -> $want" ;;
        *)         bad "$what: wanted [$want], got [$got]" ;;
    esac
}

# 1. THE hpm SHAPE. 129-byte resource, 642-byte head, 512-byte buffer. This is
#    the exact arithmetic that made `hpm refresh` report "unsigned repo".
expect "cap=512 for a 129-byte resource behind $HDR bytes of headers" \
    "$(probe "$U/tiny" 512)" "RC=0 STATUS=200 BODYLEN=129"

# 2. A body that EXACTLY fills the buffer is a whole body. The old drain tested
#    `total >= dst_cap` and failed the exactly-full case as well.
expect "cap=129 for a 129-byte body (exact fit)" \
    "$(probe "$U/tiny" 129)" "RC=0 STATUS=200 BODYLEN=129"

# 3. One byte short: -6, and THE STATUS SURVIVES.
expect "cap=128 for a 129-byte body (one short)" \
    "$(probe "$U/tiny" 128)" "RC=-6 STATUS=200 BODYLEN=128"

# 4. MISSING vs BROKEN. A 404 arrives as a ~9 KB HTML page; a caller sized for
#    the resource must still learn it was a 404 and not a dead connection.
expect "cap=512 against a 9 KB 404 page still reports the status" \
    "$(probe "$U/missing" 512)" "RC=-6 STATUS=404"
#    ... and the header block is still reachable after the overrun.
expect "the head is readable after a -6" \
    "$(probe "$U/missing" 512)" "CTYPE=text/html"

# 5. hambrowse's image / stylesheet cap, on both sides of the boundary.
expect "cap=262144 body=262144 (hambrowse's image cap, exact)" \
    "$(probe "$U/n/262144" 262144)" "RC=0 STATUS=200 BODYLEN=262144"
expect "cap=262144 body=262145 (one over)" \
    "$(probe "$U/n/262145" 262144)" "RC=-6 STATUS=200"

# 6. A fat 3xx still redirects: the hop is decided by the HEAD alone.
expect "a 302 behind a 20 KB body still follows into a 1 KB buffer" \
    "$(probe "$U/redirect/tiny" 1024)" "RC=0 STATUS=200 BODYLEN=129"

# 7. Chunked, with no Content-Length -- the read-to-EOF arm of the drain.
expect "chunked body, no Content-Length, decoded" \
    "$(probe "$U/chunked/50000" 262144)" "RC=0 STATUS=200 BODYLEN=50000"

# 7a. http_prepend_head — the overlapping shift that reassembles the RAW
#     response for hambrowse's JS fetch() transport, which hands the engine
#     the bytes as they came off the wire. It is gated HERE, host-side,
#     because in hambrowse it would only ever run inside a VM, and a shift
#     that ran the wrong way would corrupt a page silently.
for pair in "$U/tiny 4096" "$U/n/100000 200000"; do
    set -- $pair
    raw="$("$PROBE" "$1" "$2" raw 2>/dev/null | tr -d '\r' | tr '\n' ' ')"
    # `sed 's/.*RAW=\([0-9]*\).*/\1/'` WITHOUT -n AND WITHOUT /p PRINTS THE
    # WHOLE LINE WHEN THE PATTERN DOES NOT MATCH, so a probe that could not
    # connect -- no HDRLEN=, no BODYLEN=, no RAW= anywhere in its output --
    # did not give three empty strings, it gave three copies of its own error
    # text. Measured, all three outcomes, on the real block:
    #   raw empty              -> bad "RAW=  !=   +  ": an invented FAIL against
    #                             http_prepend_head, on no evidence at all;
    #   raw "RC=-6 STATUS=200" -> `$(( hdrlen + bodylen ))` is a SYNTAX ERROR,
    #                             which aborts the loop body: SIX assertions
    #                             silently do not run and the file still
    #                             reports "N passed, 0 failed";
    #   raw "connection refused"
    #                          -> `$(( ))` treats the words as variables, and
    #                             `set -u` KILLS THE WHOLE GATE mid-run.
    # It is also an injection: `$(( RC=-1 ... ))` assigns RC from probe output.
    # -n plus /p makes a miss an EMPTY string, and the empty string is then
    # refused by name rather than defaulted into a verdict.
    hdrlen="$(sed -n 's/.*HDRLEN=\([0-9]*\).*/\1/p' <<< "$raw")"
    bodylen="$(sed -n 's/.*BODYLEN=\([0-9]*\).*/\1/p' <<< "$raw")"
    rawlen="$(sed -n 's/.*RAW=\([0-9]*\).*/\1/p' <<< "$raw")"
    if ! gate_nonempty "the raw probe's HDRLEN/BODYLEN/RAW for $1 (raw: '$raw')" \
                       "$hdrlen$bodylen$rawlen" \
       || ! gate_fields "all three of HDRLEN, BODYLEN and RAW for $1 (raw: '$raw')" 3 \
                        "$hdrlen $bodylen $rawlen"; then
        continue    # the probe did not report; whether the shift reassembled
                    # the response is not a question this iteration can answer,
                    # and the two expects below would compare against '' too
    fi
    if [ "$rawlen" = "$((hdrlen + bodylen))" ]; then
        ok "http_prepend_head($1): RAW=$rawlen = HDRLEN $hdrlen + BODYLEN $bodylen"
    else
        bad "http_prepend_head($1): RAW=$rawlen != $hdrlen + $bodylen"
    fi
    expect "http_prepend_head($1) puts the status line in front" \
        "$raw" "RAW0=HTTP/1.1 200 OK"
    # The body's last 16 bytes were captured BEFORE the shift and compared
    # after it: a backwards copy done forwards smears the tail.
    expect "http_prepend_head($1) moved the body intact" "$raw" "TAILMATCH=1"
done

# ---- what a USER sees: curl and wget ----------------------------------
echo "[http9_cap] (4/4) curl / wget ..."

# 8. A multi-megabyte fetch. Before the fix curl's and wget's caps covered
#    headers + body at 1 MiB, so anything from about a megabyte up died as
#    "transport error fetching URL" with exit 7 -- indistinguishable from the
#    network being down, for a server that had answered 200 perfectly.
BIG=3000000
"$CURL" -o "$WORK/big.bin" "$U/n/$BIG" >/dev/null 2>"$WORK/curl_big.err"
rc=$?
got=$(stat -c%s "$WORK/big.bin" 2>/dev/null || echo 0)
if [ "$rc" = 0 ] && [ "$got" = "$BIG" ]; then
    ok "curl fetched $BIG bytes whole (rc=0)"
else
    bad "curl on a $BIG-byte body: rc=$rc saved=$got [$(cat "$WORK/curl_big.err")]"
fi

"$WGET" -O "$WORK/big2.bin" "$U/n/$BIG" >/dev/null 2>"$WORK/wget_big.err"
rc=$?
got=$(stat -c%s "$WORK/big2.bin" 2>/dev/null || echo 0)
if [ "$rc" = 0 ] && [ "$got" = "$BIG" ]; then
    ok "wget saved $BIG bytes whole (rc=0)"
else
    bad "wget on a $BIG-byte body: rc=$rc saved=$got [$(cat "$WORK/wget_big.err")]"
fi

# 9. The bytes are the RIGHT bytes, not merely the right count. The server's
#    filler is 64-byte counted lines, so the tail is checkable.
tail -c 64 "$WORK/big.bin" > "$WORK/tail.txt" 2>/dev/null
if cmp -s <(tail -c 64 "$WORK/big.bin") <(tail -c 64 "$WORK/big2.bin") \
        && [ -s "$WORK/tail.txt" ]; then
    ok "curl's and wget's last 64 bytes agree (content, not just length)"
else
    bad "curl and wget disagree on the tail of the same resource"
fi

# 10. Too big is reported BY SIZE AND BY STATUS, never as a transport error.
#     curl's cap is 8 MiB; 9 MB overruns it on purpose.
"$CURL" -o "$WORK/over.bin" "$U/n/9000000" >/dev/null 2>"$WORK/curl_over.err"
rc=$?
msg="$(cat "$WORK/curl_over.err")"
if [ "$rc" = 23 ] && grep -q "HTTP 200" <<< "$msg" \
        && grep -q "body larger than" <<< "$msg"; then
    ok "curl on an over-cap body: exit 23, names HTTP 200 and the size"
else
    bad "curl over-cap: rc=$rc msg=[$msg]"
fi
if grep -qi "transport error" <<< "$msg"; then
    bad "curl still calls an over-cap body a transport error"
else
    ok "curl does NOT call an over-cap body a transport error"
fi
#     ... and what did fit was still written, so the user has something.
got=$(stat -c%s "$WORK/over.bin" 2>/dev/null || echo 0)
if [ "$got" = 8388608 ]; then
    ok "curl still wrote the 8388608 bytes that fit"
else
    bad "curl wrote $got bytes of the truncated body, expected 8388608"
fi

"$WGET" -O "$WORK/over2.bin" "$U/n/9000000" >/dev/null 2>"$WORK/wget_over.err"
rc=$?
msg="$(cat "$WORK/wget_over.err")"
if [ "$rc" = 9 ] && grep -q "INCOMPLETE" <<< "$msg" \
        && grep -q "HTTP 200" <<< "$msg"; then
    ok "wget on an over-cap body: exit 9, says INCOMPLETE and names HTTP 200"
else
    bad "wget over-cap: rc=$rc msg=[$msg]"
fi

# 11. A small resource behind a chatty server, through curl and wget end to
#     end -- the hpm shape, at the level a person sees it.
body="$("$CURL" "$U/tiny" 2>"$WORK/curl_tiny.err")"
if grep -q "BEGIN HAMNIX SIGNATURE" <<< "$body"; then
    ok "curl fetched the 129-byte resource behind $HDR bytes of headers"
else
    bad "curl on /tiny: [$body] [$(cat "$WORK/curl_tiny.err")]"
fi

# 12. `curl -i` still prints the head, which now lives in http9's buffer.
hdrout="$("$CURL" -i "$U/tiny" 2>/dev/null)"
if grep -q "^HTTP/1.1 200 OK" <<< "$hdrout" \
        && grep -q "X-GitHub-Request-Id" <<< "$hdrout" \
        && grep -q "BEGIN HAMNIX SIGNATURE" <<< "$hdrout"; then
    ok "curl -i prints the status line, the headers and the body"
else
    bad "curl -i lost the head: [$(head -3 <<< "$hdrout")]"
fi

# 13. A 404 through curl is still a 404 and not a transport error.
"$CURL" -o /dev/null "$U/missing" >/dev/null 2>"$WORK/curl_404.err"
rc=$?
if [ "$rc" = 22 ] && grep -q "HTTP 404" <<< "$(cat "$WORK/curl_404.err")"; then
    ok "curl on a 404 exits 22 and names the status"
else
    bad "curl on /missing: rc=$rc [$(cat "$WORK/curl_404.err")]"
fi

# ---- the ORIGINAL bug, against the REAL server ------------------------
#
# The loopback cases above are the mechanism. These two are the incident: the
# exact URLs, the exact 512-byte buffer, and GitHub Pages' own header block,
# which no local server can be trusted to imitate forever. Reading from
# 255.one is expected; nothing here publishes. SKIPPED, not failed, with no
# network — the mechanism cases are what gate the code.
if getent hosts 255.one >/dev/null 2>&1; then
    echo "[http9_cap] (bonus) the original incident, against the live repo ..."
    live="$(probe "https://255.one/linux/index.json.sig" 512)"
    case "$live" in
        *"RC=0 STATUS=200 BODYLEN=129"*)
            ok "512-byte buffer fetches the live 129-byte signature ($(sed 's/.*\(HDRLEN=[0-9]*\).*/\1/' <<< "$live") off GitHub Pages)" ;;
        *) bad "live signature fetch at cap=512: [$live]" ;;
    esac
    # A channel that genuinely has NO signature answers with a 9 KB HTML 404.
    # "unsigned repo" and "the fetch broke" must stay different answers even
    # when the buffer is far too small for the error page.
    live404="$(probe "https://255.one/main/index.json.sig" 512)"
    expect "a live missing signature is a 404, not a bare failure" \
        "$live404" "RC=-6 STATUS=404"
else
    echo "[http9_cap] SKIP live 255.one cases (no DNS for 255.one)"
fi

echo "[http9_cap] ---- $PASS PASS, $FAIL FAIL ----"
if [ "$FAIL" -eq 0 ]; then
    echo "[http9_cap] PASS"
    exit 0
fi
echo "[http9_cap] FAIL"
exit 1
