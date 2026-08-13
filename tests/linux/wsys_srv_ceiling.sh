#!/usr/bin/env bash
# tests/linux/wsys_srv_ceiling.sh — WHAT HAPPENS TO THE 65th CLIENT.
#
# THE QUESTION
# ============
# /dev/wsys is being turned into a real file server. Clients dial an abstract
# SOCK_SEQPACKET name derived from the segment's (dev, ino); the server caps
# concurrent connections at WSRV_CONN_MAX = 64, SEPARATELY on the mutation
# socket ".../srv" and on the read server ".../rd". At the cap, both accept
# loops do the same thing and it is one line:
#
#     if (srv_nconn >= WSRV_CONN_MAX) { close(cfd); continue; }
#
# Two things were true of that number and neither had been measured.
#
#   1. IT IS A DESKTOP-WIDE APPLICATION LIMIT AND NOTHING ESTABLISHED IT.
#      docs/wsys_server_design.md 7.3 says so in as many words: "64 is a
#      desktop-wide app limit and nothing measures it." ARM F measures it.
#
#   2. EXCEEDING IT DEGRADED INTO AN IN-PROCESS FALLBACK. The client that
#      cannot get a connection does not fail; it goes back to the old
#      unmediated path and keeps working. The whole point of the server is
#      that a boundary exists, and a boundary that stops applying under load
#      is not a boundary.
#
# WHAT THIS GATE FOUND THAT THE BRIEF DID NOT SAY, and it is worse
# ================================================================
# THE FALLBACK WAS NEVER SILENT. It printed. What it printed was FALSE:
#
#     wsys: the read server for segment 66306.68821534 speaks version 0, this
#     client speaks 8 -- refusing it and reading the segment directly.
#
# There is no version mismatch. The server speaks 8, the client speaks 8, and
# the reason the handshake failed is that the connection table was full. The
# message says "version 0" because `theirs` is still the zero it was
# initialised to -- no HELLO reply ever arrived to overwrite it.
#
# A silent fallback leaves a reader with no explanation. THIS left a reader
# with the WRONG one, pointed at WSYS_VERSION -- the one number in this file
# that costs 92 of 124 packages to change. That is not a smaller defect than
# silence, it is a larger one, and it is why ARM D asserts on the TEXT.
#
# The reason the message is wrong is mechanical and is worth stating, because
# docs/wsys_server_design.md 7.1(5) gets it wrong too: it says the 65th client
# "sees a dial failure". IT DOES NOT. Both listeners are `listen(fd, 32)`, so
# connect(2) SUCCEEDS into the backlog and returns 0. The server accepts and
# closes AFTER that. So the client's dial succeeds and its HELLO is reset, and
# a reset HELLO is indistinguishable, in the code as written, from a server
# that answered with a version this client does not speak.
#
# AND WHAT THE ESCALATION IS. On the mutation socket, an unmediated client
# writes what it could already write -- the local check in hamwsys_write is
# still in front of it. On the READ socket it is not a lapse, it is a
# PRIVILEGE GAIN, and ARM C measures it end to end:
#
#     srd_enum_tier() answers EMPTY to a process that owns no window. Fall
#     back and hamwsys_open runs snap_windows() out of shared memory instead,
#     WHICH ANSWERS EVERYBODY WITH THE FULL LIST.
#
# So a window-less process that is denied the window list gets the whole list
# by opening 64 sockets first. It needs no modified client, no attack code and
# no privilege: 64 connect(2) calls. srv_route_read already knows this is
# forbidden -- it says so, twenty lines above the fallback, about the OTHER
# way of reaching it: "Falling back to the in-process read here would answer
# it from shared memory and turn every server-side refusal into a bypass."
# A connection refused at the cap IS a server-side refusal.
#
# AND WHAT THE SERVER RECORDED: NOTHING. Not a log line, not a counter. The
# STAT block has a field spelled `connrefused` and it is NOT this -- it is
# srv_n_connrefuse, stage 5's count of mutations that ancestry would have
# allowed and a descriptor did not. It read 0 through six refusals. ARM B.
#
# THE ARMS
# ========
#   A  THE REFUSAL POINT, measured on both sockets: 70 dialled, how many kept,
#      which one is the first refused, and what a refused client observes at
#      the syscall (connect OK, then a reset).
#   B  THE SERVER SAYS SO AND COUNTS IT.            RED FIRST: it did neither.
#   C  THE ESCALATION. A window-less uid is refused the window list when the
#      read table has room, and must STILL be refused when it is full.
#                                                   RED FIRST: it got the list.
#   D  THE CLIENT SAYS THE TRUE REASON -- names the connection limit, and does
#      NOT blame a version.                         RED FIRST: it blamed one.
#   E  THE REFUSAL IS RECORDED where the system can see it, in the <seg>.refused
#      file the version refusal already uses.       RED FIRST: no such line.
#   F  WHAT A REAL DESKTOP HOLDS. A routed DE boot, censused with
#      tests/linux/wsys_srv_deboot.sh's census -- ss(8) for the ESTABLISHED
#      ends, /proc/<pid>/fd to resolve each peer inode to a pid, because the
#      client end of an AF_UNIX connection has no address and /proc is the
#      only place that association exists.
#
# EVERY EMPTY READ IS PROVEN REACHABLE FIRST. ARM C scores an "empty" only
# after the CONTROL arm -- the same uid, same binary, no server in its path --
# has produced a NON-EMPTY list from the same window. Without that, "denied"
# and "the window was never there" are the same bytes.
#
# Offscreen throughout: HAMFB_FILE, HAMLINUX_VNC=none, VK_ICD_FILENAMES at an
# empty directory. /dev/dri is never opened. Everything runs in a private
# user+mount namespace; nothing outside it is written.
set -uo pipefail
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

pass=0; fail=0
ok()   { printf 'srvceil: PASS %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf 'srvceil: FAIL %s\n' "$*"; fail=$((fail+1)); }
note() { printf 'srvceil: .... %s\n' "$*"; }

# ======================================================================
# INNER HALF — inside the user namespace, as inner uid 0
# ======================================================================
if [ "${1:-}" = "--inner" ]; then
    W="$2"; BIN="$W/bin"
    . "$W/reap.sh"
    reap_track "$W/reaped.inner"
    reap_on_exit

    mount -t tmpfs none /tmp        2>/dev/null || echo "== NOTE no /tmp tmpfs"
    mount -t tmpfs none /dev/shm    2>/dev/null || echo "== NOTE no shm tmpfs"

    R="$W/run"; mkdir -p "$R/ws" "$R/noicd"
    # 0777 and NOT sticky: fs.protected_regular refuses a non-owner O_RDWR of
    # a file in a world-writable STICKY directory, and the whole point of the
    # 1002 arms is a non-owner opening a segment uid 1001 created. Sticky here
    # would make the escalation "fail" for a reason that is not the boundary.
    chmod 0777 "$R" "$R/ws"

    export HAMWSYS="$R/ws/seg" HAMWSYS_BB="$R/ws/seg.bb" HAMWSYS_IMG="$R/ws/img"
    export HAMFB_FILE="$R/ws/fb.raw" HAMFB_GEOM=1280x800
    export VK_ICD_FILENAMES="$R/noicd/none.json" HAMLINUX_VNC=none
    : >"$R/in"; chmod 666 "$R/in"; export HAMWSYSD_INPUT="$R/in"

    as() { local u="$1"; shift
        if [ "$u" = 0 ]; then "$@"
        else setpriv --reuid="$u" --regid="$u" --clear-groups "$@"; fi; }
    # The pid comes back in a global, never on stdout: `P="$(as_bg ... >log)"`
    # applies the caller's redirect to the whole substitution, so $P ends up
    # empty and every later kill is a no-op that leaves a compositor running.
    BGPID=0
    as_bg() { local u="$1" out="$2"; shift 2
        local pre=()
        [ "$u" = 0 ] || pre=(setpriv --reuid="$u" --regid="$u" --clear-groups)
        ( exec "${pre[@]}" "$@" </dev/null >"$out" 2>&1 ) &
        BGPID=$!; reap_add "$BGPID"; }

    # ---- the compositor, owned by 1001 -> 1001 is the host owner ----------
    as_bg 1001 "$R/wsysd.log" env HAMWSYS_SERVER=1 "$BIN/wsysd"
    WP=$BGPID
    for _ in $(seq 1 150); do [ -s "$HAMFB_FILE" ] && break; sleep 0.1; done
    if ! [ -s "$HAMFB_FILE" ]; then
        echo "== FATAL wsysd produced no framebuffer"
        tail -20 "$R/wsysd.log" | sed 's/^/== wsysd: /'; exit 3
    fi
    SEG="$(stat -c '%d.%i' "$HAMWSYS")"
    echo "== segment $SEG"
    echo "== segowner $(stat -c %u "$HAMWSYS")"
    RDPID="$(sed -n 's/.*read server pid \([0-9]*\).*/\1/p' "$R/wsysd.log" | head -1)"
    [ -n "$RDPID" ] && reap_add "$RDPID"
    echo "== rdpid ${RDPID:-none}"

    # ---- a victim window owned by 1001 -----------------------------------
    # wsys_hold and not a one-shot: win_reap_dead() destroys a window whose
    # owner has exited, so a creator that returns leaves nothing to enumerate
    # and every list below would be empty for the wrong reason.
    : >"$R/script"; chmod 666 "$R/script"
    as_bg 1001 "$R/wid" env HAMWSYS_SERVER=1 "$BIN/wsys_hold" "$R/script"
    VP=$BGPID
    for _ in $(seq 1 100); do [ -s "$R/wid" ] && break; sleep 0.1; done
    VWID="$(tr -d '\n' <"$R/wid" 2>/dev/null)"
    echo "== victimwid ${VWID:-none}"
    # decorate 1 IS THE INSTRUMENT, not decoration: snap_windows() skips any
    # window that is not both visible AND decorated, and a fresh window is
    # visible but undecorated. Without this every list below is empty and ARM
    # C compares "" against "" for ever.
    echo "ctl decorate 1" >>"$R/script"; sleep 0.5
    echo "ctl title VICTIM-OWN-TITLE" >>"$R/script"; sleep 0.9

    # ================= ARM A: THE REFUSAL POINT ========================
    for leaf in srv rd; do
        echo "== armA.$leaf $(python3 "$W/fill.py" "$SEG" "$leaf" 70 \
                              | grep -m1 '^tried')"
    done

    # ================= the instrument, proven ==========================
    # A NON-EMPTY ANSWER MUST BE REACHABLE BY THIS EXACT COMMAND, or nothing
    # below that reports "empty" means anything.
    as 1002 "$BIN/cat" /dev/wsys/windows >"$R/u.out" 2>"$R/u.err"
    echo "== control.unmediated.bytes $(stat -c %s "$R/u.out")"
    echo "== control.unmediated.out $(tr '\n' '/' <"$R/u.out")"

    # ================= ARM C(green half): mediated, table has room =====
    as 1002 env HAMWSYS_SERVER=1 "$BIN/cat" /dev/wsys/windows \
        >"$R/g.out" 2>"$R/g.err"
    echo "== armC.roomy.bytes $(stat -c %s "$R/g.out")"
    echo "== armC.roomy.out $(tr '\n' '/' <"$R/g.out")"

    # ================= fill the READ table and hold it =================
    rm -f "$R/ready" "$R/ready.stop"
    python3 "$W/fill.py" "$SEG" rd 70 "$R/ready" >"$R/fill.rd.log" 2>&1 &
    FP=$!; reap_add "$FP"
    for _ in $(seq 1 300); do [ -s "$R/ready" ] && break; sleep 0.1; done
    echo "== fill.rd $(grep -m1 '^tried' "$R/fill.rd.log")"
    # THE TABLE IS FULL AT THIS INSTANT, asserted rather than assumed. A
    # previous run of this harness held its connections on stdin, a
    # backgrounded job's stdin is /dev/null, the holder exited immediately,
    # and every arm below ran against an EMPTY table while the log said full.
    echo "== canary.rd $(python3 "$W/canary.py" "$SEG" rd | tr '\n' ';')"

    # ================= ARM C(red half) + ARM D =========================
    as 1002 env HAMWSYS_SERVER=1 "$BIN/cat" /dev/wsys/windows \
        >"$R/r.out" 2>"$R/r.err"
    echo "== armC.full.bytes $(stat -c %s "$R/r.out")"
    echo "== armC.full.out $(tr '\n' '/' <"$R/r.out")"
    echo "== armD.stderr $(tr '\n' '/' <"$R/r.err")"

    # ================= ARM E: recorded where the system can see ========
    if [ -s "$HAMWSYS.refused" ]; then
        echo "== armE.marker $(tr '\n' '/' <"$HAMWSYS.refused")"
    else
        echo "== armE.marker NONE"
    fi

    # ================= ARM B: what the server said and counted =========
    echo "== armB.serverlog $(grep -ac 'connection limit\|WSRV_CONN_MAX\|refusing a client' "$R/wsysd.log")"
    echo "== armB.serverline $(grep -am1 'connection limit\|WSRV_CONN_MAX\|refusing a client' "$R/wsysd.log")"

    : >"$R/ready.stop"; sleep 0.5

    # ================= ARM F: WHAT A REAL DESKTOP HOLDS ================
    # The census is tests/linux/wsys_srv_deboot.sh's, reused verbatim in
    # mechanism: ss(8) names only the LISTENING end and the server's accepted
    # ends -- the client end of an AF_UNIX connection has no address at all --
    # so the peer socket INODE is read off the server-side row and resolved
    # through /proc/<pid>/fd. Nothing here asks a process what it is doing.
    census() {
        local seg="$1"
        ss -xp 2>/dev/null | awk -v seg="$seg" '
            $0 ~ ("@hamnix-wsys/" seg "/srv") && $2 == "ESTAB" { print "srv", $8 }
            $0 ~ ("@hamnix-wsys/" seg "/rd")  && $2 == "ESTAB" { print "rd",  $8 }
        ' >"$R/.peers"
        python3 "$W/census.py" "$R/.peers"
    }
    echo "== armF.census.empty $(census "$SEG" | wc -l)"
    as_bg 1001 "$R/hamdesktop.log" env HAMWSYS_SERVER=1 "$BIN/hamdesktop"
    sleep 3
    as_bg 1001 "$R/hampanel.log" env HAMWSYS_SERVER=1 "$BIN/hampanelscene"
    sleep 4
    as_bg 1001 "$R/menu.log" env HAMWSYS_SERVER=1 "$BIN/hamappmenu" -self
    sleep 3
    as_bg 1001 "$R/drag.log" env HAMWSYS_SERVER=1 "$BIN/de_dragload"
    sleep 3
    census "$SEG" | sed 's/^/== armF.peer /'
    echo "== armF.total $(census "$SEG" | wc -l)"
    echo "== armF.srv   $(census "$SEG" | grep -c '^srv ')"
    echo "== armF.rd    $(census "$SEG" | grep -c '^rd ')"
    echo "== armF.progs $(census "$SEG" | awk '{print $3}' | sort -u | tr '\n' ' ')"
    exit 0
fi

# ======================================================================
# OUTER HALF
# ======================================================================
command -v unshare >/dev/null || { echo "srvceil: SKIP no unshare(1)"; exit 0; }
command -v setpriv >/dev/null || { echo "srvceil: SKIP no setpriv(1)"; exit 0; }
command -v ss      >/dev/null || { echo "srvceil: SKIP no ss(8); ARM F cannot census"; exit 0; }
command -v python3 >/dev/null || { echo "srvceil: SKIP no python3"; exit 0; }

SCRATCH_BASE="${SRV_SCRATCH_BASE:-$HOME/.hamnix-build}"
if [ -n "${SRV_WORK:-}" ]; then OUT="$SRV_WORK"; EPH=0; mkdir -p "$OUT"
else mkdir -p "$SCRATCH_BASE"
     OUT="$(mktemp -d "$SCRATCH_BASE/wsrvceil.XXXXXX")" || {
        echo "srvceil: FAIL cannot make a scratch dir"; exit 1; }
     EPH=1
fi
BIN="$OUT/bin"; mkdir -p "$BIN"

for c in "${ADDER_HOST_AC:-}" "$PROJ/build/cutover/host_ac_llvm.elf" \
         "$PROJ/build/cutover/host_ac.elf"; do
    [ -n "$c" ] && [ -x "$c" ] && { ADDER_HOST_AC="$c"; break; }
done
[ -n "${ADDER_HOST_AC:-}" ] || { echo "srvceil: FAIL no host_ac.elf"; exit 2; }
export ADDER_HOST_AC HAMLINUX_DISTRO_RO=1

for t in wsysd:user/wsysd.ad cat:user/cat.ad \
         wsys_hold:tests/linux/wsys_hold.ad \
         hamdesktop:user/hamdesktop.ad \
         hampanelscene:user/hampanelscene.ad \
         hamappmenu:user/hamappmenu.ad \
         de_dragload:tests/linux/de_dragload.ad; do
    n="${t%%:*}"
    [ "${SRV_REBUILD:-1}" = 0 ] && [ -x "$BIN/$n" ] && continue
    "$PROJ/scripts/hamlinux_build.sh" "${t#*:}" "$BIN/$n" \
        >"$OUT/build.$n.log" 2>&1 || {
        echo "srvceil: FAIL could not build ${t#*:}"; tail -8 "$OUT/build.$n.log"
        exit 2; }
done

# The two extra uids. Same two cases and the same reasoning as
# tests/linux/wsys_srv_identity.sh: /etc/subuid on a bare host, and otherwise
# a namespace that already owns 1001/1002 mapping them to themselves. A range
# READ of /proc/self/uid_map would turn a clean SKIP into a false FAIL, so the
# second case tests itself by doing the mapping.
if grep -q "^$(id -un):" /etc/subuid 2>/dev/null \
   && grep -q "^$(id -un):" /etc/subgid 2>/dev/null; then
    SUB="$(awk -F: -v u="$(id -un)" '$1==u{print $2; exit}' /etc/subuid)"
    IDSRC="/etc/subuid range $SUB for $(id -un)"
elif unshare -U --map-users=0:"$(id -u)":1 --map-groups=0:"$(id -g)":1 \
        --map-users=1001:1001:1 --map-groups=1001:1001:1 \
        --map-users=1002:1002:1 --map-groups=1002:1002:1 true 2>/dev/null; then
    SUB=1001; IDSRC="ids 1001/1002 are this namespace's own"
else
    echo "srvceil: SKIP no /etc/subuid range for $(id -un) and this namespace"
    echo "srvceil: SKIP does not already own uids 1001 and 1002; run in the VM"
    exit 0
fi
note "the two extra uids: $IDSRC"

# $W IS NOT UNDER /tmp, and that is not a preference. The inner half mounts a
# fresh tmpfs over /tmp -- it has to, because /tmp/hamnix-panel.conf and the
# rest of the fixed names are compiled into the programs under test -- so a
# $W under /tmp vanishes from beneath the binaries the moment the namespace is
# set up, and the run dies with "no such file or directory" on wsysd itself.
W="$(mktemp -d "$SCRATCH_BASE/wsrvceil-w.XXXXXX")"
trap 'rm -rf "$W"; [ "${EPH:-0}" = 1 ] && [ "${SRVCEIL_KEEP:-0}" = 0 ] && rm -rf "$OUT"' EXIT
trap 'exit 130' INT TERM HUP
chmod 1777 "$W"
mkdir -p "$W/bin"; cp "$BIN"/* "$W/bin/"; chmod 755 "$W/bin"/*
cp "$0" "$W/inner.sh"; chmod 755 "$W/inner.sh"
cp "$PROJ/tests/linux/reap.sh" "$W/reap.sh"
cp "$PROJ/tests/linux/wsys_conn_fill.py"   "$W/fill.py"
cp "$PROJ/tests/linux/wsys_conn_canary.py" "$W/canary.py"
cp "$PROJ/tests/linux/wsys_conn_census.py" "$W/census.py"

OUTF="$W/out.txt"
unshare -U --mount --propagation private \
    --map-users=0:"$(id -u)":1      --map-groups=0:"$(id -g)":1 \
    --map-users=1001:"$SUB":1       --map-groups=1001:"$SUB":1 \
    --map-users=1002:"$((SUB+1))":1 --map-groups=1002:"$((SUB+1))":1 \
    -- "$W/inner.sh" --inner "$W" >"$OUTF" 2>&1
rc=$?
sed 's/^/srvceil|  /' "$OUTF"
[ $rc -eq 0 ] || { echo "srvceil: FAIL namespace run rc=$rc"; exit 2; }

f() { grep -m1 "^== $1 " "$OUTF" | sed "s/^== $1 *//"; }

CAP="$(awk '/WSRV_CONN_MAX *=/{gsub(/[^0-9]/,"",$3); print $3; exit}' \
        "$PROJ/user/linux-wsys.h")"
[ -n "$CAP" ] || { echo "srvceil: FAIL could not read WSRV_CONN_MAX from user/linux-wsys.h"; exit 2; }
note "WSRV_CONN_MAX is $CAP, read from user/linux-wsys.h -- every number below is compared against THAT and not against a literal 64"

# ---------- the segment separation this whole gate rests on --------------
if [ "$(f segowner)" = 1001 ]; then
    ok "the segment's owner is uid 1001, so hostowner() names 1001 and uid 1002 is a genuinely different identity"
else
    bad "the segment is owned by uid '$(f segowner)', not 1001 -- the uid separation every arm rests on did not happen"
fi

# ======================= ARM A: THE REFUSAL POINT ========================
note "ARM A -- dial 70 and see where the door shuts, on each socket separately"
for leaf in srv rd; do
    L="$(f "armA.$leaf")"
    kept="$(printf '%s' "$L" | sed -n 's/.*kept \([0-9]*\).*/\1/p')"
    firstr="$(printf '%s' "$L" | sed -n 's/.*first_refused \([0-9A-Za-z]*\).*/\1/p')"
    note "  $leaf: $L"
    # The mutation socket also carries wsys_hold's own connection, so `kept`
    # is the cap MINUS whatever the desktop is already holding. The refusal
    # point is the number that has to land, and it lands at kept+1.
    if [ -n "$firstr" ] && [ "$firstr" != None ] \
       && [ "$firstr" -eq "$((kept + 1))" ] && [ "$kept" -le "$CAP" ]; then
        ok "on '$leaf' the server kept $kept of 70 and refused the very next one (#$firstr) -- the ceiling is $CAP and this arm reached it"
    else
        bad "on '$leaf' 70 dials produced kept=$kept first_refused=$firstr -- that is not a ceiling at $CAP"
    fi
done
if [ "$(f armA.rd | sed -n 's/.*kept \([0-9]*\).*/\1/p')" = "$CAP" ]; then
    ok "the read server's ceiling is exactly WSRV_CONN_MAX=$CAP and it is SEPARATE from the mutation socket's -- a desktop has two budgets, not one"
else
    bad "the read server kept $(f armA.rd | sed -n 's/.*kept \([0-9]*\).*/\1/p'), not $CAP"
fi

# ---------- the instrument, before any 'empty' is scored -----------------
UB="$(f control.unmediated.bytes)"; UO="$(f control.unmediated.out)"
if [ "${UB:-0}" -gt 0 ] && printf '%s' "$UO" | grep -q VICTIM-OWN-TITLE; then
    ok "the instrument can produce a NON-EMPTY answer: uid 1002 with no server in its path reads \"$UO\" ($UB bytes) -- so an empty result below is a denial and not an absent window"
else
    bad "uid 1002 could not read the window list even unmediated (got \"$UO\", $UB bytes). Every 'empty' below would be vacuous; refusing to score ARM C."
    echo "srvceil: $pass passed, $fail failed"; exit 1
fi

# ======================= ARM C: THE ESCALATION ===========================
note "ARM C -- the enumeration policy, with the read table roomy and then full"
GB="$(f armC.roomy.bytes)"; GO="$(f armC.roomy.out)"
if [ "${GB:-1}" -eq 0 ]; then
    ok "with room in the read table the mediator DENIES the window list to a window-less uid 1002 (0 bytes) -- srd_enum_tier answered EMPTY"
else
    bad "with room in the read table uid 1002 already saw \"$GO\" -- the enumeration policy is not in force at all, and ARM C's red half would prove nothing"
fi
note "  the table was full at the instant of the red read: $(f canary.rd)"
note "  fill: $(f fill.rd)"
FB="$(f armC.full.bytes)"; FO="$(f armC.full.out)"
if [ "${FB:-1}" -eq 0 ]; then
    ok "WITH THE READ TABLE FULL the same uid still gets nothing -- exhausting the connection table does NOT hand out the window list"
else
    bad "THE BOUNDARY LAPSED UNDER LOAD: with $CAP connections held, the same window-less uid 1002 that was denied the list now reads \"$FO\" ($FB bytes). 64 connect(2) calls, no attack code, no privilege -- and the answer came from snap_windows() out of shared memory, which answers everybody in full."
fi

# ======================= ARM D: THE TRUE REASON ==========================
note "ARM D -- what the refused client says"
DS="$(f armD.stderr)"
note "  client stderr: ${DS:-<nothing at all>}"
if [ -z "$DS" ]; then
    bad "the refused client printed NOTHING -- the fallback is silent, and a fallback nobody can observe is the defect regardless of which policy is right"
else
    ok "the refused client printed something rather than falling back in silence"
fi
if printf '%s' "$DS" | grep -qi 'speaks version 0'; then
    bad "the client blames a VERSION MISMATCH -- \"$DS\". There is no mismatch: both sides speak $(grep -m1 'define WSYS_VERSION' "$PROJ/user/linux-wsys.c" | awk '{print $3}'), and 'version 0' is the uninitialised \`theirs\` of a HELLO that was never answered. This sends a reader at WSYS_VERSION, the one number here that costs 92 of 124 packages to change, for a fault that is WSRV_CONN_MAX."
elif printf '%s' "$DS" | grep -qi 'connection\|conn_max\|too many\|full'; then
    ok "the client names the real cause -- \"$DS\""
else
    bad "the client said \"$DS\", which names neither the connection limit nor anything a reader could act on"
fi

# ======================= ARM E: RECORDED =================================
note "ARM E -- recorded where the system can see it"
EM="$(f armE.marker)"
if printf '%s' "$EM" | grep -qi 'connrefused\|conn cap\|conn_max'; then
    ok "the refusal is appended to <seg>.refused: \"$EM\" -- the same file and mechanism the version refusal already uses, so one reader finds both"
else
    bad "nothing was recorded anywhere the system can read: <seg>.refused is \"${EM:-NONE}\". stderr on a DE-spawned program goes to a log nobody opens; the marker file is what the panel's notice path already reads."
fi

# ======================= ARM B: THE SERVER'S OWN WORDS ===================
note "ARM B -- what the SERVER said and counted"
if [ "$(f armB.serverlog)" -gt 0 ] 2>/dev/null; then
    ok "wsysd names the refusal in its own log: $(f armB.serverline)"
else
    bad "wsysd logged NOTHING for any refused connection. It also counts nothing: the STAT field spelled 'connrefused' is srv_n_connrefuse, stage 5's count of mutations ancestry would have allowed and a descriptor did not, and it read 0 through six refusals. The one process that KNOWS the table is full is the one that says least about it."
fi

# ======================= ARM F: WHAT A DESKTOP HOLDS =====================
note "ARM F -- a routed desktop boot, censused through /proc"
TOT="$(f armF.total)"; SRVN="$(f armF.srv)"; RDN="$(f armF.rd)"
grep '^== armF.peer ' "$OUTF" | sed 's/^== armF.peer /srvceil: ....   /'
note "  programs holding connections: $(f armF.progs)"
if [ "${TOT:-0}" -gt 0 ]; then
    ok "the census resolves real peers: $TOT connections ($SRVN on the mutation socket, $RDN on the read socket) across $(f armF.progs | wc -w) programs"
else
    bad "the census found NO connections to a segment that is being served -- the instrument, not the desktop, is what this measured"
fi
if [ "${SRVN:-0}" -gt 0 ]; then
    PER="$(awk -v s="$SRVN" -v n="$(f armF.progs | wc -w)" 'BEGIN{if(n)printf "%.2f", s/n; else print "?"}')"
    note "  $PER mutation connections per window-owning program on this boot"
    note "  AT THAT RATE the cap of $CAP is reached at about $((CAP * 1)) such programs -- and an INSTALLED desktop spawns each app as \`/bin/hamsh /etc/rc.de-user <prog>\`, so an app costs a connection for hamsh AND one for the program unless the handoff adopts. This boot does not go through hamUId and therefore does NOT measure that doubling; it is the one number ARM F cannot supply."
fi

echo
echo "srvceil: $pass passed, $fail failed"
[ "$fail" = 0 ]
