#!/usr/bin/env bash
# tests/linux/net_accept_servers.sh — DO THE SERVERS THAT ACCEPT CONNECTIONS
# ACTUALLY WORK ON THIS LINE?
#
# Every Adder server that takes a connection (u_server, sshd, httpd,
# httpd_worker, x11srv) had its coverage on the BARE-METAL lane, where /net is
# the real devnet. So when `accept` handed back the LISTENER on this line --
# `accept(5)=6` then `read(5)=ENOTCONN`, fixed in user/linux-net.c -- there was
# nothing here to notice. This gate is the missing coverage: it brings the
# servers up and drives one full exchange through each.
#
# IT TOUCHES NO PORT OF THE MACHINE IT RUNS ON. Everything runs inside a
# PRIVATE NETWORK NAMESPACE with only loopback, which is also the only way to
# test sshd at all: its port is the literal 22, and binding that on the host
# would collide with the owner's real sshd. Unprivileged users cannot bind 22 —
# inside a user+net namespace, root of that namespace can.
#
# WHAT EACH ARM PROVES
#   u_server  a request arrives and the exact response comes back. The
#             simplest possible end-to-end statement that accept works.
#   sshd      the IDENTIFICATION EXCHANGE and KEXINIT (msg type 20) — the
#             start of key exchange, and the exact path whose 255-byte clamp
#             was fixed without being testable until this gate existed.
#   sshd      AND THE INJECTION THAT CLAMP ALLOWED, which is the arm that
#             matters: a banner line of exactly 255 bytes followed immediately
#             by "SSH-..." used to be read as TWO lines, the second of which
#             was accepted as the peer's identification string. A peer that
#             chooses where its own data is framed is a security property, not
#             a tidiness one.
#
#             THE PADDING LENGTH IS THE TEST. An earlier version of this probe
#             padded 300 bytes and PASSED against the broken server, because
#             the continuation began with padding rather than with "SSH-", so
#             the old code rejected that too and recovered on the next line. It
#             proved nothing. Exactly 255 is what puts the injected prefix at
#             the start of the continuation. The control was RUN, and against a
#             pre-fix sshd this arm reports "the server DROPPED the connection"
#             while this tree reports "still open".
#
# WHAT IS NOT HERE, AND WHY. httpd is NOT tested end to end because it cannot
# yet work on this line, for a reason that is structural rather than a bug to
# patch in a gate: it accepts a connection and hands the connection NUMBER to a
# spawned /bin/httpd_worker, but lib/p9.ad's spawn ends with p9_closefrom(3) --
# the child gets a deliberately clean fd table -- while user/linux-net.c keeps
# the accepted connection as a HOST fd in the accepting process. The worker
# re-opens /net/tcp/<n>/data by name, which on this line does not re-create
# anything, and reads a descriptor its own table no longer has: measured,
# `read(6, ...) = -1 EBADF`. On the bare-metal lane the kernel owns the
# connection and the name is enough. See HANDOFF.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"
. tests/linux/reap.sh

WORK="${NAS_WORK:-$(mktemp -d -p "${TMPDIR:-/tmp}" nasrv.XXXXXX)}"
mkdir -p "$WORK"
reap_track "$WORK/reaped"
pass=0; fail=0
ok()   { echo "nasrv: PASS $*"; pass=$((pass+1)); }
bad()  { echo "nasrv: FAIL $*"; fail=$((fail+1)); }
info() { echo "nasrv: INFO $*"; }
cleanup() { reap_all; [ "${NAS_KEEP:-0}" = 1 ] || rm -rf "$WORK"; }
reap_on_exit cleanup
done_report() { echo "nasrv: $pass passed, $fail failed"; [ "$fail" = 0 ]; }

if ! unshare --user --map-root-user --net --mount true 2>/dev/null; then
    info "this host will not give an unprivileged user a network namespace,"
    info "and this gate REFUSES to bind ports on the machine it runs on."
    echo "nasrv: 0 passed, 0 failed (skipped)"
    exit 0
fi

BIN="${NAS_BIN_DIR:-$WORK/bin}"
if [ -z "${NAS_BIN_DIR:-}" ]; then
    mkdir -p "$BIN"
    for s in user/u_server.ad user/sshd.ad; do
        n="$(basename "$s" .ad)"
        scripts/hamlinux_build.sh "$s" "$BIN/$n.elf" >"$WORK/$n.build.log" 2>&1 || {
            bad "could not build $s"; tail -15 "$WORK/$n.build.log" >&2
            done_report; exit 1; }
    done
    ok "the servers build"
fi

# Each arm runs server AND client inside one private network namespace.
run_ns() { unshare --user --map-root-user --net --mount -- bash -c "$1"; }

# ---- 1. u_server: one request, one exact response -------------------------
U_OUT="$WORK/u.out"
run_ns "
ip link set lo up 2>/dev/null
export HAMNET='$WORK/net.shm' HAMWSYS='$WORK/wsys.shm'
'$BIN/u_server.elf' >'$WORK/u.log' 2>&1 &
for i in \$(seq 1 60); do grep -q listening '$WORK/u.log' && break; sleep 0.1; done
python3 -c \"
import socket
s = socket.create_connection(('127.0.0.1', 7000), timeout=5)
s.sendall(b'hello\\n')
s.settimeout(5)
print(repr(s.recv(128)))
\"
" >"$U_OUT" 2>&1
if grep -q "hamnix-userserver-ok" "$U_OUT"; then
    ok "u_server took a connection and returned its exact response ($(tr -d '\n' <"$U_OUT" | tail -c 40))"
else
    bad "u_server did not complete an exchange: $(tail -2 "$U_OUT" | tr '\n' ' ')"
fi

# ---- 2. sshd: identification exchange + KEXINIT ---------------------------
S_OUT="$WORK/s.out"
run_ns "
ip link set lo up 2>/dev/null
export HAMNET='$WORK/net2.shm' HAMWSYS='$WORK/wsys.shm'
'$BIN/sshd.elf' >'$WORK/s.log' 2>&1 &
for i in \$(seq 1 80); do grep -q listening '$WORK/s.log' && break; sleep 0.1; done
python3 '$PROJ_ROOT/tests/linux/ssh_banner_probe.py' plain
" >"$S_OUT" 2>&1
if grep -q "msg type 20" "$S_OUT"; then
    ok "sshd took a connection, exchanged identification strings and sent KEXINIT -- $(grep -m1 'first binary packet' "$S_OUT")"
else
    bad "sshd did not reach KEXINIT: $(tail -2 "$S_OUT" | tr '\n' ' ')"
fi

# ---- 3. sshd: the over-long banner line, and what it used to allow --------
B_OUT="$WORK/b.out"
run_ns "
ip link set lo up 2>/dev/null
export HAMNET='$WORK/net3.shm' HAMWSYS='$WORK/wsys.shm'
'$BIN/sshd.elf' >'$WORK/b.log' 2>&1 &
for i in \$(seq 1 80); do grep -q listening '$WORK/b.log' && break; sleep 0.1; done
python3 '$PROJ_ROOT/tests/linux/ssh_banner_probe.py' inject
" >"$B_OUT" 2>&1
if grep -q "STILL OPEN" "$B_OUT"; then
    ok "a 255-byte banner line with \"SSH-\" starting at byte 256 is skipped WHOLE -- the peer could not smuggle an identification string past the line framing, and the stream is still in sync"
elif grep -q "DROPPED the connection" "$B_OUT"; then
    bad "the over-long banner line was mis-framed: its tail was accepted as the identification string and the connection died on the next line"
else
    bad "the banner probe reached no verdict: $(tail -2 "$B_OUT" | tr '\n' ' ')"
fi
if grep -q "longer than 255 bytes -- skipped whole" "$WORK/b.log"; then
    ok "and the server SAYS so, rather than skipping it silently"
else
    info "(the server did not log the over-long line; not fatal)"
fi

info "httpd is deliberately not driven here -- it cannot serve on this line"
info "until the spawn/fd-ownership conflict in its worker model is resolved."
info "See this file's header and HANDOFF."
done_report
