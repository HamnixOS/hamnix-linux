#!/usr/bin/env bash
# Its host runtime and its pass/fail were NOT measured when this line was
# written. If you make it cheap enough for the battery, add the manifest line
# and delete this block.
#
# tests/linux/x11_stream_resync.sh — DOES ONE OVERSIZED REQUEST DESTROY THE
# CONNECTION?  And can the server take a connection at all?
#
# TWO DEFECTS THIS GUARDS, both found by inspection and neither of which had a
# test until now.
#
# 1. `accept` HANDED BACK THE LISTENER.  user/net9.ad's net_accept writes
#    "accept" to a connection's ctl file, closes it (an fd opened for writing
#    cannot be read back), reopens it and reads the new connection number.
#    user/linux-net.c kept that answer in the OPEN FILE, so the close threw it
#    away and the reopen answered the LISTENER's own number -- and the server
#    then read its own listening socket. strace, before the fix:
#        accept(5, NULL, NULL)       = 6
#        read(5, ..., 12)            = -1 ENOTCONN
#    Every Adder server taking a connection through net_accept on this line was
#    broken this way, each printing its own local guess ("setup read failed").
#    This gate asserts the handshake COMPLETES, which is the whole of that.
#
# 2. AN OVERSIZED REQUEST DESYNCHRONISED THE STREAM.  An X11 request length is
#    16 bits in 4-byte units -- up to 262140 bytes -- and user/x11/x11srv.ad
#    clamped the body to its 4092-byte buffer and carried on reading the same
#    socket, so the remainder became the next request's header. PutImage,
#    ChangeProperty and a many-rect PolyFillRectangle all pass 4 KiB in
#    ordinary use, so this is not a hypothetical peer.
#
# THE QUESTION THE PROBE ASKS IS THE RIGHT ONE: not "did the call return" but
# "does the STREAM still carry the next reply, with the sequence number it
# should". A server that answered the oversized request and then desynchronised
# would pass the first check and fail this one.
#
# THE CONTROL WAS RUN, and it is what makes the PASS mean anything: the same
# probe against a build with the drain removed (and the accept fix in place, so
# the handshake still completes) reports
#     second GetGeometry: no reply (timed out)
#     VERDICT: DESYNCHRONISED
# against this build's
#     second GetGeometry: reply, seq 3
#     VERDICT: IN SYNC
#
# Offscreen, no VM, no display, seconds to run. It does NOT rebuild the
# bare-metal kernel: x11srv is built with the Linux lane's own compiler script
# into this gate's scratch directory.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"
. tests/linux/private_ns.sh
priv_ns_reexec "$@"
. tests/linux/reap.sh

WORK="${X11RS_WORK:-$(mktemp -d -p "${TMPDIR:-/tmp}" x11rs.XXXXXX)}"
mkdir -p "$WORK"
reap_track "$WORK/reaped"
pass=0; fail=0
ok()   { echo "x11rs: PASS $*"; pass=$((pass+1)); }
bad()  { echo "x11rs: FAIL $*"; fail=$((fail+1)); }
info() { echo "x11rs: INFO $*"; }
cleanup() { reap_all; [ "${X11RS_KEEP:-0}" = 1 ] || rm -rf "$WORK"; }
reap_on_exit cleanup
done_report() { echo "x11rs: $pass passed, $fail failed"; [ "$fail" = 0 ]; }

# THE PORT IS NOT THIS TEST'S TO STEAL. x11srv announces 6000, which is X
# display :0 -- if something is already there this gate must say so rather than
# collide with it or read its bytes.
if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q ':6000 '; then
    info "something is already listening on port 6000 (an X server?) -- SKIPPING"
    info "rather than binding over it. Nothing was started."
    echo "x11rs: 0 passed, 0 failed (skipped)"
    exit 0
fi

SRV="${X11RS_SRV:-}"
if [ -z "$SRV" ]; then
    SRV="$WORK/x11srv.elf"
    scripts/hamlinux_build.sh user/x11/x11srv.ad "$SRV" \
        >"$WORK/build.log" 2>&1 || {
        bad "could not build user/x11/x11srv.ad"; tail -20 "$WORK/build.log" >&2
        done_report; exit 1; }
    ok "the X server builds"
fi

export HAMFB_FILE="$WORK/fb.raw" HAMFB_GEOM=1280x800
export HAMWSYS="$WORK/wsys.shm" HAMWSYS_BB="$WORK/wsys.bb"
"$SRV" >"$WORK/srv.log" 2>&1 &
SRVPID=$!; reap_add "$SRVPID"
for _ in $(seq 1 60); do
    grep -q "listening" "$WORK/srv.log" && break; sleep 0.1
done
if ! kill -0 "$SRVPID" 2>/dev/null; then
    bad "the server exited before it listened"; cat "$WORK/srv.log"
    done_report; exit 1
fi
ok "the server is listening"

python3 tests/linux/x11_stream_resync.py >"$WORK/probe.out" 2>&1
rc=$?
sed 's/^/x11rs:      /' "$WORK/probe.out"

if grep -q "^setup ok" "$WORK/probe.out"; then
    ok "the connection HANDSHAKE COMPLETES -- net_accept handed back the accepted connection and not the listening socket"
else
    bad "the handshake never completed: the server took a connection and could not read the client's setup (this is the ENOTCONN-on-the-listener defect, or another one in front of it)"
fi
if grep -q "^first  GetGeometry: reply" "$WORK/probe.out"; then
    ok "a normal request gets a well-formed reply"
else
    bad "a normal request did not get a reply -- nothing below is meaningful"
fi
if grep -q "VERDICT: IN SYNC" "$WORK/probe.out"; then
    ok "the stream SURVIVES an oversized request: the reply after it still carries the right sequence number, so the excess was drained rather than left to be read as the next request's header"
elif grep -q "VERDICT: DESYNCHRONISED" "$WORK/probe.out"; then
    bad "ONE oversized request desynchronised the connection -- the clamp kept the buffer safe and left the rest of the payload on the wire"
else
    bad "the probe reached no verdict (rc $rc)"
fi

info "server log:"; sed 's/^/x11rs:      /' "$WORK/srv.log" | tail -8
done_report
