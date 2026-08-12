#!/usr/bin/env bash
# tests/linux/wsys_keychan.sh — why the keystroke channel is a SOCKET and not
# the memfd THE SPLIT recorded, kept as a measurement rather than an argument.
#
# THE SPLIT's tier 2 says: hand each window a memfd over SCM_RIGHTS, because
# "a memfd has no name in the filesystem, so there is no path for a bypasser to
# open".  That is the sentence the whole design rested on and it is FALSE:
# /proc/<pid>/fd/<n> is a path, it is openable by any process of the SAME UID,
# and same-uid is the entire threat model -- /etc/rc.de-user drops the terminal,
# the browser and a malicious download to uid 1001 together.  Built as recorded,
# tier 2 would have re-opened the keylogger one directory deeper.
#
# This gate is that finding, driven.  It also drives the remedy that DOES work
# for a memfd -- prctl(PR_SET_DUMPABLE, 0) -- because tier 2's remaining half,
# the scene and the backbuffer, cannot be datagrams and will need it; and it
# drives the two properties the shipped channel actually rests on: first-binder-
# wins in the abstract namespace, and SCM_CREDENTIALS.
#
# It compiles one C file and links nothing from this tree. These are facts about
# Linux, and a gate that measured them through our own library would be
# measuring the library instead of the kernel.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

fail=0
ok()  { printf '  ok   %s\n' "$*"; }
bad() { printf '  FAIL %s\n' "$*"; fail=1; }

W="$(mktemp -d "${TMPDIR:-/tmp}/wsyskeychan.XXXXXX")"
. tests/linux/reap.sh
cleanup() { rm -rf "$W"; }
reap_on_exit cleanup

cc -std=gnu11 -O1 -o "$W/probe" tests/linux/wsys_keychan.c >"$W/build.log" 2>&1 \
    || { cat "$W/build.log"; echo "BUILD FAILED"; exit 2; }

OUT="$W/out.txt"
"$W/probe" >"$OUT" 2>&1
cat "$OUT"
line() { grep -m1 "^== $1" "$OUT"; }
has()  { line "$1" | grep -q -- "$2"; }

echo ""
echo "THE RECORDED DESIGN'S HOLE: a memfd DOES have a path."
if has memfd_samuid "open=[0-9]"; then
    ok "a same-uid process opens another's memfd through /proc/<pid>/fd"
else bad "the /proc open failed -- this measurement proves nothing: $(line memfd_samuid)"; fi
if has memfd_samuid "secret=1"; then
    ok "AND READS THE PLAINTEXT OUT OF IT: SCM_RIGHTS alone closes nothing"
else bad "the secret was not readable, so the finding does not hold: $(line memfd_samuid)"; fi
if has memfd_samuid "enumerable=1"; then
    ok "and it does not even have to guess the number: /proc/<pid>/fd lists them"
else bad "the fd directory was not enumerable: $(line memfd_samuid)"; fi

echo ""
echo "THE REMEDY A memfd NEEDS, measured now because tier 2's other half needs it:"
if has memfd_nodump "open=-13"; then
    ok "against PR_SET_DUMPABLE(0) the same open is refused, EACCES"
else bad "a non-dumpable process's fds were still openable: $(line memfd_nodump)"; fi
if has memfd_nodump "secret=0"; then
    ok "and nothing leaks"
else bad "the secret leaked from a non-dumpable process: $(line memfd_nodump)"; fi
if has memfd_nodump "enumerable=0"; then
    ok "and /proc/<pid>/fd is not enumerable either"
else bad "the fd directory was still enumerable: $(line memfd_nodump)"; fi
if has memfd_nodump "ptrace=-1"; then
    ok "and ptrace is refused too -- which is the OTHER way same-uid memory leaks"
else bad "ptrace still attached: $(line memfd_nodump)"; fi

echo ""
echo "WHY THE KEYS RING IS A SOCKET: it has the property the memfd was believed"
echo "to have, and the two facts the access control is built out of."
if has sock_noproc "procopen=-"; then
    ok "a socket cannot be opened through /proc/<pid>/fd at all"
else bad "a socket was opened by path: $(line sock_noproc)"; fi
if has sock_noproc "procopen_enxio=1"; then
    ok "and the kernel says so by name: ENXIO, not a permission accident"
else bad "the refusal was not ENXIO: $(line sock_noproc)"; fi
if has sock_noproc "bind1=0"; then ok "an abstract name binds"
else bad "the bind failed -- nothing below means anything: $(line sock_noproc)"; fi
if has sock_noproc "bind2_eaddrinuse=1"; then
    ok "and a SECOND bind of it is EADDRINUSE: first binder wins, no unlink"
else bad "the name was rebindable -- the owner's claim is not exclusive: $(line sock_noproc)"; fi
if has sock_noproc "passcred=0"; then ok "SO_PASSCRED is accepted on it"
else bad "SO_PASSCRED was refused: $(line sock_noproc)"; fi
if has sock_cred "cred=1"; then
    ok "and every datagram arrives with SCM_CREDENTIALS attached"
else bad "no credentials on the datagram -- the receiver would be deaf: $(line sock_cred)"; fi
if has sock_cred "sender_is_child=1"; then
    ok "carrying the KERNEL's answer for the sender's pid, which it cannot forge"
else bad "the credential pid was not the sender's: $(line sock_cred)"; fi

echo ""
echo "AND THE ONE THIS FILE CANNOT CLOSE, WHICH IS NOW CLOSED SOMEWHERE ELSE:"
PS="$(cat /proc/sys/kernel/yama/ptrace_scope 2>/dev/null || echo unset)"
echo "  /proc/sys/kernel/yama/ptrace_scope = $PS on this DEV HOST."
if has memfd_samuid "ptrace=0"; then
    echo "  A same-uid attacker PTRACE_ATTACHes the victim and reads its memory"
    echo "  directly -- no userland mechanism prevents that, and every window"
    echo "  system on Linux has the same exposure.  It is a DISTRIBUTION setting,"
    echo "  and user/linuxinit.ad now sets kernel.yama.ptrace_scope=1 as PID 1"
    echo "  and reads it back.  It is NOT set on this dev host (that would be a"
    echo "  change to somebody's working machine, and ptrace_scope is not"
    echo "  namespaced, so no unprivileged harness can set it either), which is"
    echo "  why the ptrace=0 above is still the honest reading HERE and why the"
    echo "  measurement of the setting lives in a real boot:"
    echo "      tests/linux/ptrace_scope_boot.sh   -- 6 assertions, one of them"
    echo "      this exact attack run on this host (attach SUCCEEDS, scope 0)"
    echo "      and inside a boot of this tree (REFUSED, scope 1)."
else
    echo "  ptrace was refused here, so this host already restricts it."
fi
echo ""
echo "AND THE REMEDY MEASURED ABOVE IS NOW APPLIED, not just available:"
echo "  prctl(PR_SET_DUMPABLE, 0) is called by owner_harden() in"
echo "  user/linux-wsys.c's keychan_bind, so every window owner has it."
echo "  Driven against a REAL window owner as attack 5 of 5 in"
echo "  tests/linux/wsys_bypass.sh, where the same-uid attacker takes the"
echo "  victim's pid out of the world-readable table and is then refused"
echo "  /proc/<pid>/mem, /proc/<pid>/fd and PTRACE_ATTACH."

echo ""
[ $fail -eq 0 ] && echo "PASS wsys_keychan" || echo "FAIL wsys_keychan"
exit $fail
