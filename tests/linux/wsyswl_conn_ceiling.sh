#!/usr/bin/env bash
# tests/linux/wsyswl_conn_ceiling.sh — HOW MANY PROGRAMS FIT ON THIS DESKTOP?
#
# THE QUESTION
# ============
# `wsyswl_ceiling.sh` next door asks how many WINDOWS fit. This asks the one
# that was actually blocking rootless Xwayland from being the default, and it
# is a different noun:
#
#     MAXCONN was 8, and FIREFOX ALONE OPENS EIGHT CONNECTIONS.
#
# Measured, not inherited: `conns 8` four seconds after launch, with its
# content, GPU and utility processes. The table was full with ONE program on
# the screen, and the next client to arrive -- a namespace's Xwayland -- was
# refused. Running out of windows costs a window; running out of connections
# costs a WHOLE PROGRAM, because every per-connection table in wsyswl (the
# object ids, the shm mappings, the frame-callback slice, the window budget)
# is what independence between clients is made of.
#
# Eight is Firefox's true appetite and not a truncation -- rebuilt at
# MAXCONN 32 it still opens exactly 8, with one tab and with ten. So the
# ceiling has to hold Firefox PLUS what NORTH_STAR says runs beside it:
# `enter debian { … }` and `enter alpine { … }` at once, one Wayland
# connection per namespace's Xwayland however many X clients are behind it.
# 8 + 1 + 1 = ten, which does not fit in eight.
#
# WHAT IS MEASURED
# ================
#   1. THE ARITHMETIC, from source. Four numbers in three files have to agree
#      or a ceiling raised in one place becomes a silent failure in another,
#      which has now happened three times in this chain (BB_SLOTS 3, then
#      BB_SLOTS 8, then wsysd's own window array at 32). Including the one
#      this pass found: `waitset` was Array[16] for MAXCONN 8 and the loop
#      that fills it HAS NO BOUND CHECK, so raising MAXCONN alone would have
#      written past it on every pass of the event loop.
#   2. THE CEILING HOLDS. MAXCONN real Wayland clients connect at once and
#      every one of them is ACCEPTED, with the server's own `conns` agreeing.
#   3. THE NEGATIVE CONTROL, which is the point of the test. Drive PAST the
#      ceiling and require that the clients past it are REFUSED BY NAME --
#      not accepted, and not dropped in silence. See wl_conn_probe.c: the
#      old behaviour closed the socket and the refused client reported
#      "No wl_shm global", blaming a protocol global that is present.
#   4. EXHAUSTION IS NOT DAMAGE. Every client that was already connected is
#      still connected afterwards, `conns` is unchanged, and a slot freed
#      after a refusal is reusable -- a full table must be a full table, not
#      a broken one.
#   5. THE SEGMENT, and this section now asserts the OPPOSITE of what it did.
#      MAXCONN * WINPERCONN is the window table and the window table is
#      `struct wshm`, which used to be memset WHOLE on first attach -- so a
#      row cost 74 KiB of RESIDENT memory whether or not anything had a window
#      in it, and that is the single number that kept MAXCONN at 16 and TWO
#      BROWSERS off this desktop. The memset was writing zeros over a fresh
#      tmpfs file's already-zero bytes. It is gone; the table is sparse; the
#      test measures with du(1) and requires sparseness, so the old behaviour
#      now FAILS here rather than passing.
#
# Offscreen throughout: HAMFB_FILE, no VM, no display, about a minute.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

WORK="${CONNC_WORK:-$(mktemp -d -p "${TMPDIR:-/tmp}" connc.XXXXXX)}"
mkdir -p "$WORK"
KEEP="${CONNC_KEEP:-0}"
GEOM="${HAMFB_GEOM:-1280x800}"
# PRIVATE, all three -- the v2 backbuffer segment is one file per HOST with
# slots keyed by wid, so a test that inherits one is measuring the last run.
export HAMWSYS="$WORK/wsys.shm"
export HAMWSYS_BB="$WORK/wsys.bb"
export HAMWSYS_IMG="$WORK/wsys.img"
export HAMFB_FILE="$WORK/fb.raw"
export HAMFB_GEOM="$GEOM"
# wsysd arms a real Vulkan backend on real silicon and this host's GPU belongs
# to someone. Software ICD, always, for anything offscreen.
[ -r /usr/share/vulkan/icd.d/lvp_icd.json ] && \
    export VK_ICD_FILENAMES="${VK_ICD_FILENAMES:-/usr/share/vulkan/icd.d/lvp_icd.json}"

pass=0; fail=0
ok()   { echo "connc: PASS $*"; pass=$((pass+1)); }
bad()  { echo "connc: FAIL $*"; fail=$((fail+1)); }
info() { echo "connc: INFO $*"; }

KIDS=""; WLPID=""; WSYSDPID=""
cleanup() {
    for p in $KIDS $WLPID $WSYSDPID; do [ -n "${p:-}" ] && kill "$p" 2>/dev/null; done
    sleep 0.4
    for p in $KIDS $WLPID $WSYSDPID; do [ -n "${p:-}" ] && kill -9 "$p" 2>/dev/null; done
    [ "$KEEP" = 1 ] || rm -rf "$WORK"
}
trap cleanup EXIT

command -v python3 >/dev/null || { echo "need python3 on the host" >&2; exit 1; }
CC="${CC:-clang}"
command -v "$CC" >/dev/null || { echo "need $CC on the host" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. THE ARITHMETIC, read out of the source
# ---------------------------------------------------------------------------
# Every one of these has to hold BEFORE anything is run, because each of them
# is a way for the ceiling to be raised in one file and silently ignored in
# another. They are read from the files rather than restated here, so this
# section fails when someone moves a number and not when someone moves a
# comment.
echo "connc: === 1. the numbers, and whether the three files agree"

adnum()  { sed -n "s/^$2: *uint64 = \([0-9]*\).*/\1/p" "$1" | head -1; }
cnum()   { sed -n "s/^#define $2  *\([0-9]*\).*/\1/p" "$1" | head -1; }

WL=user/wsyswl.ad; WD=user/wsysd.ad; WC=user/linux-wsys.c
MAXCONN="$(adnum $WL MAXCONN)"
WINPERCONN="$(adnum $WL WINPERCONN)"
MAXWIN="$(adnum $WL MAXWIN)"
FCPERCONN="$(adnum $WL FCPERCONN)"
FCMAX="$(adnum $WL FCMAX)"
MAXOBJ="$(adnum $WL MAXOBJ)"
WAITSET="$(adnum $WL WAITSET)"
WSYSD_MAXWIN="$(adnum $WD MAX_WIN)"
DEV_MAXWIN="$(cnum $WC WSYS_MAX_WINDOWS)"
DEV_VERSION="$(cnum $WC WSYS_VERSION)"
WAITFDS_MAX="$(cnum user/linux-syscalls.c WAITFDS_MAX)"

info "MAXCONN=$MAXCONN WINPERCONN=$WINPERCONN MAXWIN=$MAXWIN FCPERCONN=$FCPERCONN FCMAX=$FCMAX MAXOBJ=$MAXOBJ"
info "WAITSET=$WAITSET WAITFDS_MAX=$WAITFDS_MAX wsysd MAX_WIN=$WSYSD_MAXWIN device WSYS_MAX_WINDOWS=$DEV_MAXWIN version=$DEV_VERSION"

for v in MAXCONN WINPERCONN MAXWIN FCPERCONN FCMAX WAITSET WSYSD_MAXWIN DEV_MAXWIN WAITFDS_MAX; do
    [ -n "${!v}" ] || { bad "could not read $v out of the source"; }
done

# THE CEILING IS THE THING THIS TEST IS ABOUT, so it is asserted as a floor
# and not as an equality: a later pass may raise it again and must not have to
# edit this line, but it may never quietly go back down to a number Firefox
# fills on its own.
if [ "${MAXCONN:-0}" -gt 8 ]; then
    ok "MAXCONN is $MAXCONN -- more than the 8 Firefox reaches by itself"
else
    bad "MAXCONN is $MAXCONN; Firefox alone reaches 8, so one browser fills the table and every other program is refused"
fi
# Firefox (8, measured) + one Xwayland per namespace for the two namespaces
# NORTH_STAR says run at once.
if [ "${MAXCONN:-0}" -ge 10 ]; then
    ok "MAXCONN $MAXCONN holds Firefox (8) + debian's Xwayland + alpine's Xwayland = 10"
else
    bad "MAXCONN $MAXCONN cannot hold the workload NORTH_STAR names: 8 + 1 + 1 = 10"
fi
# TWO BROWSERS, which is where 16 ran out and is the ceiling this pass moved.
# Every number here is measured by tests/linux/wsyswl_two_browsers.sh next
# door, not assumed: a Firefox is 8 connections, and `enter debian { firefox }`
# beside the native one is a SECOND 8 -- 16 with nothing else on the desktop,
# and then debian's and alpine's Xwayland are 17 and 18. Sixteen refused the
# seventeenth ENTIRELY, which costs a whole program.
if [ "${MAXCONN:-0}" -ge 18 ]; then
    ok "MAXCONN $MAXCONN holds TWO browsers (8 + 8, measured) + two namespaces' Xwayland = 18"
else
    bad "MAXCONN $MAXCONN cannot hold two browsers and two namespaces: 8 + 8 + 1 + 1 = 18 -- the 17th client loses its whole program, not a window"
fi

# NO CONNECTION MAY BE STARVED BY ANOTHER'S APPETITE. This is arithmetic, not
# intention, and it is what forced the window table to 256 when MAXCONN went
# to 16 -- see the note on WINPERCONN in user/wsyswl.ad.
if [ "${MAXWIN:-0}" -ge $((MAXCONN * WINPERCONN)) ]; then
    ok "MAXWIN $MAXWIN >= MAXCONN $MAXCONN * WINPERCONN $WINPERCONN -- every connection is guaranteed its whole window budget"
else
    bad "MAXWIN $MAXWIN < MAXCONN * WINPERCONN ($((MAXCONN * WINPERCONN))) -- a window budget another client can eat is not a budget"
fi
if [ "${FCMAX:-0}" -ge $((MAXCONN * FCPERCONN)) ]; then
    ok "FCMAX $FCMAX >= MAXCONN $MAXCONN * FCPERCONN $FCPERCONN -- a busy client cannot silence another's initial-draw callback"
else
    bad "FCMAX $FCMAX < MAXCONN * FCPERCONN ($((MAXCONN * FCPERCONN)))"
fi

# THE CHAIN THAT HAS BROKEN TWICE. The compositor's window array, the device's
# window table and the Wayland server's MAXWIN are ONE number in three files.
# When they last disagreed the symptom was a window that existed, was listed,
# and was never painted.
if [ "$MAXWIN" = "$WSYSD_MAXWIN" ] && [ "$MAXWIN" = "$DEV_MAXWIN" ]; then
    ok "the window table is one number in three files: wsyswl MAXWIN = wsysd MAX_WIN = WSYS_MAX_WINDOWS = $MAXWIN"
else
    bad "window table disagreement: wsyswl MAXWIN=$MAXWIN wsysd MAX_WIN=$WSYSD_MAXWIN device WSYS_MAX_WINDOWS=$DEV_MAXWIN -- the smallest wins and the windows past it are never painted"
fi

# THE POLL SET. The main loop writes one entry per live connection, plus the
# listener, plus the XWM fd, plus the clipboard pipe. This was Array[16] with
# MAXCONN 8 and no bound check on the connection loop at all.
NEED_WS=$((1 + MAXCONN + 2))
if [ "${WAITSET:-0}" -ge "$NEED_WS" ]; then
    ok "WAITSET $WAITSET >= 1 listener + MAXCONN $MAXCONN + xwm + clipboard = $NEED_WS"
else
    bad "WAITSET $WAITSET < $NEED_WS -- the event loop writes past its poll set every pass"
fi
if [ "${WAITSET:-0}" -le "${WAITFDS_MAX:-64}" ]; then
    ok "WAITSET $WAITSET <= WAITFDS_MAX $WAITFDS_MAX -- sys_waitfds will accept the set instead of returning EINVAL"
else
    bad "WAITSET $WAITSET > WAITFDS_MAX $WAITFDS_MAX -- every wait returns EINVAL and the compositor spins"
fi
# and the loop itself must be bounded, not merely sized: a check in the two
# guards after it is not a check on the loop that fills it.
if grep -q 'if conn_inuse\[i\] != 0 and nfd < WAITSET:' "$WL"; then
    ok "the connection loop that fills the poll set is bounded by WAITSET"
else
    bad "the loop filling waitset has no WAITSET bound -- sizing it correctly today does not stop the next MAXCONN from overflowing it"
fi

# THE LISTEN BACKLOG, which is the last place a refusal can be turned back
# into a lie. wl_display.error is sent on an ACCEPTED socket, so a client that
# overflows the listen queue never gets told anything: the kernel bounces its
# connect(2) with ECONNREFUSED and the client reports that it cannot open the
# display, as though no compositor were running. The backlog was the literal 8
# -- the old MAXCONN, written a second time -- and this test caught it
# intermittently under load before it was a test.
if grep -q 'cast\[int32\](MAXCONN + 16))' "$WL"; then
    ok "the listen backlog is MAXCONN + 16, so a burst of clients past the ceiling each reach accept(2) and are refused BY NAME"
else
    bad "the listen backlog is not derived from MAXCONN -- clients past the ceiling get ECONNREFUSED from the kernel instead of a named refusal from the server"
fi

# EVERY PER-CONNECTION ARRAY, because Adder array sizes are integer literals:
# `Array[MAXCONN * MAXOBJ, int32]` is not expressible, so all 36 of them are
# hand-multiplied and any one left behind is an out-of-bounds write into the
# next array. This recomputes every one of them from MAXCONN.
echo "connc: === 1b. every per-connection array is exactly MAXCONN * its stride"
python3 - "$WL" "$MAXCONN" <<'PY' && ok "every per-connection array is sized MAXCONN * its stride" || bad "a per-connection array is not sized for MAXCONN -- see above; that is an out-of-bounds write, not a smaller table"
import re, sys
src = open(sys.argv[1]).read(); N = int(sys.argv[2])
PER_CONN = {
    "conn_inuse":1,"conn_fd":1,"conn_reg":1,"conn_acclen":1,"conn_seat":1,
    "conn_pointer":1,"conn_keyboard":1,"conn_xdg_wm":1,"conn_output":1,
    "conn_ddev":1,"conn_offer":1,"conn_title_len":1,"fdq_head":1,"fdq_tail":1,
    "conn_acc":8192,"conn_title":48,
    "obj_type":1024,"obj_a":1024,"obj_b":1024,"obj_c":1024,"obj_d":1024,
    "obj_e":1024,"obj_f":1024,"obj_g":1024,"obj_h":1024,"obj_i":1024,
    "surf_parent":1024,
    "map_addr":64,"map_len":64,"map_used":64,"map_ref":64,
    "fdq":8, "fc_conn":32,"fc_surf":32,"fc_cb":32,
}
bad = 0
for name, stride in sorted(PER_CONN.items()):
    m = re.search(r"^" + re.escape(name) + r"\s*:\s*Array\[(\d+),", src, re.M)
    if not m:
        print("connc:      %-14s DECLARATION NOT FOUND" % name); bad += 1; continue
    got, want = int(m.group(1)), N * stride
    if got != want:
        print("connc:      %-14s is Array[%d] and must be Array[%d] (%d conns * %d)"
              % (name, got, want, N, stride)); bad += 1
print("connc:      %d per-connection arrays checked against MAXCONN=%d, %d wrong" % (len(PER_CONN), N, bad))
# The stride table above is also the per-connection COST, which is the number
# the ceiling has to be defended with.
per = sum(s * (8 if n in ("conn_acclen","conn_title_len","fdq_head","fdq_tail",
                          "map_addr","map_len") else
               (1 if n in ("conn_acc","conn_title") else 4))
          for n, s in PER_CONN.items())
print("connc:      per-connection cost %d bytes (%.2f KiB); %d connections = %.0f KiB of BSS"
      % (per, per/1024.0, N, N*per/1024.0))
sys.exit(1 if bad else 0)
PY

# ---------------------------------------------------------------------------
# 2. build
# ---------------------------------------------------------------------------
echo "connc: === 2. build"
for t in wsysd:user/wsysd.ad wsyswl:user/wsyswl.ad; do
    name="${t%%:*}"; src="${t#*:}"
    scripts/hamlinux_build.sh "$src" "$WORK/$name.elf" >"$WORK/$name.build.log" 2>&1 || {
        echo "FAIL could not build $src" >&2; tail -20 "$WORK/$name.build.log" >&2; exit 1; }
done
"$CC" -O2 -o "$WORK/wl_conn_probe" tests/linux/wl_conn_probe.c \
    >"$WORK/probe.build.log" 2>&1 || {
    echo "FAIL could not build tests/linux/wl_conn_probe.c" >&2
    cat "$WORK/probe.build.log" >&2; exit 1; }
ok "wsysd, wsyswl and the connection probe all build"
BSS=$(size "$WORK/wsyswl.elf" | awk 'NR==2{print $3}')
info "wsyswl BSS is $BSS bytes ($((BSS/1024)) KiB) at MAXCONN=$MAXCONN"

# ---------------------------------------------------------------------------
# 3. the ceiling holds
# ---------------------------------------------------------------------------
echo "connc: === 3. MAXCONN clients at once, and every one of them accepted"
"$WORK/wsysd.elf" </dev/null >"$WORK/wsysd.log" 2>&1 & WSYSDPID=$!
sleep 1.5
"$WORK/wsyswl.elf" "$WORK/wayland-0" </dev/null >"$WORK/wsyswl.log" 2>"$WORK/wsyswl.err" & WLPID=$!
for _ in $(seq 1 40); do [ -S "$WORK/wayland-0" ] && break; sleep 0.1; done
[ -S "$WORK/wayland-0" ] || { bad "wsyswl never created its socket"; cat "$WORK/wsyswl.log"; exit 1; }
STATE="$WORK/wsyswl-state"
st()  { sed -n "s/^$1 \([0-9-]*\)\$/\1/p" "$STATE" 2>/dev/null | tail -1; }
lim() { sed -n "s/.*[ ]$1=\([0-9]*\).*/\1/p" "$STATE" 2>/dev/null | tail -1; }
sleep 1

# The SERVER's account of its own ceiling, which is what a person debugging a
# live desktop reads. It has to agree with the source the test just read.
if [ "$(lim MAXCONN)" = "$MAXCONN" ]; then
    ok "the running server states its own ceiling: limits shared MAXCONN=$(lim MAXCONN)"
else
    bad "the server says MAXCONN=$(lim MAXCONN), the source says $MAXCONN"
fi

HOLD="${CONNC_HOLD:-90}"
start_probe() {  # start_probe <n>
    "$WORK/wl_conn_probe" -hold "$HOLD" "$WORK/wayland-0" >"$WORK/p$1.out" 2>&1 &
    eval "PID$1=$!"
    KIDS="$KIDS $!"
}
verdict() { sed -n 's/^PROBE \([A-Za-z-]*\).*/\1/p' "$WORK/p$1.out" 2>/dev/null | head -1; }

for i in $(seq 1 "$MAXCONN"); do start_probe "$i"; sleep 0.2; done
sleep 2

acc=0
for i in $(seq 1 "$MAXCONN"); do [ "$(verdict "$i")" = "ACCEPTED" ] && acc=$((acc+1)); done
if [ "$acc" = "$MAXCONN" ]; then
    ok "all $MAXCONN clients were accepted at once (the ceiling really is $MAXCONN, not a number in a comment)"
else
    bad "only $acc of $MAXCONN clients were accepted"
    for i in $(seq 1 "$MAXCONN"); do echo "connc:      $i: $(cat "$WORK/p$i.out")"; done
fi
C=$(st conns)
if [ "${C:-0}" = "$MAXCONN" ]; then
    ok "the server agrees: conns $C, conns_high_water $(st conns_high_water)"
else
    bad "the server reports conns $C with $MAXCONN clients connected"
fi
if [ "$(st conn_refused)" = "0" ]; then
    ok "nothing was refused at or below the ceiling (conn_refused 0)"
else
    bad "conn_refused is $(st conn_refused) with only $MAXCONN clients -- the ceiling is lower than it says"
fi

# ---------------------------------------------------------------------------
# 4. THE NEGATIVE CONTROL: past the ceiling, and told so by name
# ---------------------------------------------------------------------------
echo "connc: === 4. four MORE clients, which must be refused BY NAME"
# The ceiling is only being tested if the holders are all STILL HOLDING. A
# test whose clients quietly died would be driving a half-empty table past a
# ceiling it never reached, and would pass.
alive=0
for i in $(seq 1 "$MAXCONN"); do
    eval "p=\${PID$i}"
    kill -0 "$p" 2>/dev/null && alive=$((alive+1))
done
if [ "$alive" = "$MAXCONN" ]; then
    ok "all $MAXCONN holders are still running, so the table really is full when the next client arrives"
else
    bad "only $alive of $MAXCONN holders are still alive -- the overflow below would not be an overflow"
fi
OVER="${CONNC_OVER:-4}"
for i in $(seq $((MAXCONN + 1)) $((MAXCONN + OVER))); do start_probe "$i"; sleep 0.25; done
sleep 2

ref=0; drop=0; acc2=0; noconn=0; wrong=0
for i in $(seq $((MAXCONN + 1)) $((MAXCONN + OVER))); do
    case "$(verdict "$i")" in
        REFUSED)        ref=$((ref+1)) ;;
        DROPPED)        drop=$((drop+1)) ;;
        ACCEPTED)       acc2=$((acc2+1)) ;;
        connect-failed) noconn=$((noconn+1)) ;;
        *)              wrong=$((wrong+1)) ;;
    esac
done
info "past the ceiling: $ref refused, $drop dropped in silence, $acc2 accepted, $noconn never reached accept(2), $wrong other"
# THE THIRD OUTCOME, and it is the one that hid. A client the kernel bounces
# off a full listen queue is not refused by the server at all -- it is told
# the display cannot be opened. Counted separately because lumping it in with
# "not refused" is what made it look like flakiness for two runs.
if [ "$noconn" = 0 ]; then
    ok "every client past the ceiling reached accept(2) -- none was bounced by a short listen queue before the server could speak"
else
    bad "$noconn of $OVER clients past the ceiling never reached accept(2): ECONNREFUSED from the kernel, which a Wayland client reports as 'cannot open display'"
fi
if [ "$ref" = "$OVER" ]; then
    ok "all $OVER clients past the ceiling were REFUSED -- not accepted into a table that is full"
else
    bad "$ref of $OVER clients past the ceiling were refused ($drop dropped silently, $wrong accepted)"
    for i in $(seq $((MAXCONN + 1)) $((MAXCONN + OVER))); do echo "connc:      $i: $(cat "$WORK/p$i.out")"; done
fi
# AND IT MUST BE A REFUSAL THE CLIENT CAN READ. Closing the socket is a
# refusal the client mis-diagnoses -- weston-simple-shm reports "No wl_shm
# global", which is false. wl_display.error is the wire's own way to say why.
MSG="$(sed -n 's/^PROBE REFUSED .*message=//p' "$WORK/p$((MAXCONN + 1)).out" 2>/dev/null | head -1)"
CODE="$(sed -n 's/^PROBE REFUSED .*code=\([0-9]*\).*/\1/p' "$WORK/p$((MAXCONN + 1)).out" 2>/dev/null | head -1)"
if [ -n "$MSG" ]; then
    ok "the refused client was told, on the wire: \"$MSG\""
else
    bad "the refused client was told nothing on the wire -- it can only guess, and what it guesses is wrong"
fi
if [ "${CODE:-}" = "2" ]; then
    ok "wl_display.error code 2 (no_memory) -- the protocol's own word for a resource that ran out"
else
    bad "the refusal used wl_display.error code '${CODE:-none}', not 2 (no_memory)"
fi
case "$MSG" in
    *MAXCONN*) ok "the message names the limit AND its value, so the reader knows which number to raise" ;;
    *)         bad "the refusal message does not name MAXCONN: '$MSG'" ;;
esac
# The counter, because a console nobody is watching is not a record.
if [ "$(st conn_refused)" = "$OVER" ]; then
    ok "conn_refused counted every one of them ($OVER) -- diagnosable from a file after the fact"
else
    bad "conn_refused is $(st conn_refused), expected $OVER"
fi
if grep -q "too many clients -- raise MAXCONN" "$WORK/wsyswl.err"; then
    ok "the server said so on its own stderr as well"
else
    bad "nothing on the server's stderr about a refused client"
fi

# ---------------------------------------------------------------------------
# 5. A FULL TABLE IS FULL, NOT BROKEN
# ---------------------------------------------------------------------------
echo "connc: === 5. what the overflow did to the clients that were already there"
still=0
for i in $(seq 1 "$MAXCONN"); do [ "$(verdict "$i")" = "ACCEPTED" ] && still=$((still+1)); done
if [ "$still" = "$MAXCONN" ]; then
    ok "all $MAXCONN clients that were already connected are still connected -- a refusal costs the client refused and nobody else"
else
    bad "only $still of $MAXCONN earlier clients survived the overflow"
fi
C2=$(st conns)
if [ "${C2:-0}" = "$MAXCONN" ]; then
    ok "conns is still $C2 after $OVER refusals -- the refusals did not consume, leak or corrupt a slot"
else
    bad "conns went from $MAXCONN to $C2 across the refusals"
fi

# AND THE TABLE RECOVERS. A slot freed after refusals has to be reusable, or
# "full" is a one-way door and the ceiling is really a lifetime budget.
echo "connc: === 5b. free one slot and try again"
kill "$PID1" 2>/dev/null
sleep 1.5
info "after killing one holder: conns $(st conns)"
start_probe "recover"
sleep 2
if [ "$(verdict recover)" = "ACCEPTED" ]; then
    ok "a client accepted into the slot the dead one freed -- exhaustion is a state, not damage"
else
    bad "the freed slot was not reusable: $(cat "$WORK/precover.out" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# 6. WHAT THE CEILING COSTS, in bytes that were measured
# ---------------------------------------------------------------------------
echo "connc: === 6. the price"
SEGSZ=$(stat -c %s "$HAMWSYS" 2>/dev/null || echo 0)
SEGRES=$(du -k "$HAMWSYS" 2>/dev/null | awk '{print $1}')
info "the window table /srv/wsys is $SEGSZ bytes of ADDRESS SPACE and $SEGRES KiB RESIDENT ($MAXWIN rows, no windows open)"
# THIS ASSERTION IS THE OPPOSITE OF THE ONE IT REPLACES, and that inversion is
# the whole of this pass. It used to read "the window table is fully resident
# ... the cost reported is the cost paid", because shm_attach memset the whole
# of struct wshm over a segment ftruncate(2) had just given it out of a fresh
# tmpfs file -- writing zeros onto bytes that were already zero, and faulting
# in 18 MiB of window table with no windows in it. That memset is gone (see
# THE ZEROES WE DO NOT WRITE in user/linux-wsys.c) and the table is now what
# the paint pool beside it always was: sparse.
#
# It is asserted as a RATIO and not as an absolute, so the next person to
# double MAXWIN does not have to edit this line -- which is exactly what the
# old assertion forced.
ROW=$(( SEGSZ > 0 && MAXWIN > 0 ? SEGSZ / MAXWIN : 0 ))
if [ "${SEGRES:-0}" -lt $((SEGSZ / 1024 / 4)) ]; then
    ok "the window table is SPARSE: $SEGRES KiB resident of $((SEGSZ / 1024)) KiB mapped -- a row nobody has a window in is not paid for"
else
    bad "the window table is $SEGRES KiB resident of $((SEGSZ / 1024)) KiB: it is being faulted in whole, so MAXWIN costs memory instead of address space"
fi
# AND THE FLOOR IS NAMED, because it is not zero and pretending it were would
# be the success-shaped answer. win_find and the /dev/wsys/windows reader scan
# the table linearly for `used`, which is the first word of a row, so a scan
# touches ONE PAGE of every row whether or not it holds a window. That is
# 4 KiB a row against 74,425 -- an 18x reduction, not an infinite one.
FLOOR_K=$(( MAXWIN * 8 ))
if [ "${SEGRES:-0}" -le "$FLOOR_K" ]; then
    ok "an empty table costs $SEGRES KiB, at or under the 4 KiB-a-row scan floor ($MAXWIN rows, ceiling asserted at $FLOOR_K KiB)"
else
    bad "an empty table costs $SEGRES KiB, more than $FLOOR_K KiB -- something is touching more of a row than its first page"
fi
info "a row is $ROW bytes when a window is actually in it, and about 4096 when it is not"
info "before this pass: $MAXWIN rows would have been $(( MAXWIN * ROW / 1048576 )) MiB RESIDENT on every boot, which is why MAXCONN was 16"
if [ -f "$HAMWSYS_BB" ]; then
    BBSZ=$(stat -c %s "$HAMWSYS_BB")
    BBRES=$(du -k "$HAMWSYS_BB" | awk '{print $1}')
    info "the paint pool /srv/wsys.bb is $((BBSZ / 1048576)) MiB of ADDRESS SPACE and $BBRES KiB allocated -- sparse, unlike the table above"
else
    # It is created by the first client that asks to PAINT, and these clients
    # deliberately do not: they open a connection and hold it, because
    # connections are what this test is about. wsyswl_ceiling.sh next door is
    # where the pool is measured with real pixels in it.
    info "the paint pool /srv/wsys.bb was never created -- no client here asked to paint, which is the point: these are connections, not windows"
fi

echo "connc: ---------------------------------------------"
echo "connc: PASS $pass  FAIL $fail"
[ "$fail" = 0 ] || exit 1
