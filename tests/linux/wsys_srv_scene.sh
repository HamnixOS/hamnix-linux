#!/usr/bin/env bash
# Its host runtime and its pass/fail were NOT measured when this line was
# written. If you make it cheap enough for the battery, add the manifest line
# and delete this block.
#
# tests/linux/wsys_srv_scene.sh — STAGE 6: ROUTING THE LAST UNROUTED MUTATION,
# AND THE HALF THAT MATTERS IS THE PAINT.
#
# WHY THIS LEAF WAS LEFT UNTIL LAST, AND WHY IT IS THE HARDEST
# ============================================================
# `/dev/wsys/<wid>/scene` carries 1 write per 12 s of a drag against 9790 for
# `wid/ctl`, so neither the cost nor the privilege question ever turned on it.
# What makes it different is PER-OPEN STATE: opening the scene for writing
# STARTS A NEW FRAME (`p->stage_len = 0`) and every write after that APPENDS.
#
# GETTING THAT WRONG DOES NOT PRODUCE AN ERROR. It produces a window that
# paints last frame's display list for ever, or one that accumulates every
# frame ever drawn. That is the defect that made an empty window look full for
# the life of a test file, and it is why this gate asserts the frame BOUNDARY
# as a pixel that must have GONE AWAY, not as a count of bytes accepted.
#
# THE THREE THINGS THIS FILE ASSERTS, in order of how much they matter:
#
#   1. IT STILL PAINTS. A routed client's scene reaches the screen: the pixel
#      is the assertion, because "the server accepted 26 bytes" and "a human
#      can see the rectangle" are different claims and only one of them is the
#      one that matters. A scene path that accepted everything and painted
#      nothing would pass a refusal-only gate perfectly.
#   2. THE FRAME BOUNDARY SURVIVES ROUTING. Frame 1 fills the window red;
#      frame 2 fills a small corner blue. After frame 2 the red MUST BE GONE.
#      If the reset were lost in routing, the red would still be there and
#      every other arm here would still be green.
#   3. A ROUTED SCENE WRITE FROM A PROCESS THAT DOES NOT HOLD THE CONNECTION IS
#      REFUSED — the stage-5 rule applied to the last leaf, from a second uid,
#      sent past the local check exactly as the ctl probe sends its own.
#
# AND THE COMPARISON THAT MAKES ALL THREE MEAN SOMETHING: the identical script
# is run with HAMWSYS_SERVER unset, and the same pixels are read. Routing must
# change nothing a person can see.
#
# THE NEGATIVE CONTROL, RUN AND WRITTEN DOWN: make srv_scene_write ignore
# WSRV_F_NEWFRAME -- delete the reset, keep everything else -- and this file
# goes from 8 passed / 0 failed to 6 passed / 2 failed:
#
#   FAIL ROUTED frame 2 STILL SHOWS FRAME 1's RED at (400,310): got 208,32,32
#   FAIL routed and unrouted differ on the screen: frame 2 0,0,0 vs 208,32,32
#
# EVERY OTHER ARM STAYS GREEN, including the refusal, both frame-1 paints and
# the blue corner. That is the point of this file: the defect it exists to
# catch is invisible to every arm except the one that reads a pixel which is
# supposed to have GONE AWAY.
#
# THE INSTRUMENT IS PROVEN BEFORE IT IS TRUSTED: the first arm requires the
# UNROUTED window to paint. If it does not, the compositor, the geometry or the
# scene syntax is wrong and every "the red is gone" below would be a blank
# screen agreeing with itself. An empty framebuffer is not evidence of a
# working frame boundary.
#
# Offscreen (HAMFB_FILE), software, no ICD. /dev/dri is untouched.
# WSYS_VERSION stays 8.
set -uo pipefail
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail=0; pass=0
ok()   { printf 'srvsc: PASS %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf 'srvsc: FAIL %s\n' "$*"; fail=$((fail+1)); }
note() { printf 'srvsc: .... %s\n' "$*"; }

# The window: 300x220 at (200,150), undecorated, so window (wx,wy) is screen
# (200+wx, 150+wy) and every pixel below is a simple offset.
WX=200; WY=150; WW=300; WH=220
GEOM=1280x800

if [ "${1:-}" = "--inner" ]; then
    W="$2"
    BIN="$W/bin"
    . "$W/reap.sh"
    reap_track "$W/reaped.inner"
    reap_on_exit

    mkdir -p "$W/ws" "$W/noicd"; chmod 0777 "$W/ws"
    export HAMWSYS="$W/ws/seg" HAMWSYS_BB="$W/ws/seg.bb" HAMWSYS_IMG="$W/ws/img"
    export HAMFB_GEOM="$GEOM"
    export VK_ICD_FILENAMES="$W/noicd/none.json" HAMLINUX_VNC=none
    : >"$W/in"; chmod 666 "$W/in"; export HAMWSYSD_INPUT="$W/in"

    as() { local u="$1"; shift
        if [ "$u" = 0 ]; then "$@"
        else setpriv --reuid="$u" --regid="$u" --clear-groups "$@"; fi; }
    BGPID=0
    as_bg() { local u="$1" out="$2" err="$3"; shift 3
        local pre=()
        [ "$u" = 0 ] || pre=(setpriv --reuid="$u" --regid="$u" --clear-groups)
        if [ "$err" = "-" ]; then ( exec "${pre[@]}" "$@" >"$out" 2>&1 ) &
        else                      ( exec "${pre[@]}" "$@" >"$out" 2>"$err" ) & fi
        BGPID=$!; reap_add "$BGPID"; }

    # ---- one arm: "routed" or "unrouted" ------------------------------
    # Everything about the two arms is identical except the flag on the
    # CLIENT. wsysd runs with HAMWSYS_SERVER=1 in both, so the unrouted arm is
    # a client bypassing a live mediator -- the state of the tree today, not a
    # historical re-enactment.
    arm() {
        local tag="$1" clientflag="$2"
        export HAMFB_FILE="$W/fb.$tag.raw"
        rm -f "$HAMWSYS" "$HAMWSYS.chrome" "$HAMWSYS_BB" "$HAMFB_FILE"
        as_bg 1001 "$W/wsysd.$tag.log" - \
              env HAMWSYS_SERVER=1 HAMWSYS_SRV_TRACE=1 "$BIN/wsysd"
        local WP=$BGPID
        local i
        for i in $(seq 1 150); do [ -s "$HAMFB_FILE" ] && break; sleep 0.1; done
        if ! [ -s "$HAMFB_FILE" ]; then
            echo "== $tag.fatal wsysd produced no framebuffer"
            kill "$WP" 2>/dev/null; wait "$WP" 2>/dev/null; return
        fi
        : >"$W/script.$tag"
        if [ "$clientflag" = on ]; then
            as_bg 1002 "$W/wid.$tag" "$W/hold.$tag.log" \
                  env HAMWSYS_SERVER=1 "$BIN/wsys_hold" "$W/script.$tag"
        else
            as_bg 1002 "$W/wid.$tag" "$W/hold.$tag.log" \
                  "$BIN/wsys_hold" "$W/script.$tag"
        fi
        local HP=$BGPID
        for i in $(seq 1 100); do [ -s "$W/wid.$tag" ] && break; sleep 0.1; done
        local wid; wid="$(tr -d '\n' <"$W/wid.$tag" 2>/dev/null || true)"
        echo "== $tag.wid ${wid:-none}"
        if [ -z "${wid:-}" ] || [ "${wid:-0}" -lt 2 ]; then
            kill "$HP" "$WP" 2>/dev/null; wait "$HP" "$WP" 2>/dev/null; return
        fi
        # Geometry first, then FRAME 1: fill the whole window red.
        {   echo "ctl geometry $WX $WY $WW $WH"
            echo "ctl visible 1"
        } >>"$W/script.$tag"; sleep 0.6
        echo "scene fill 0 0 $WW $WH #d02020" >>"$W/script.$tag"; sleep 1.0
        cp "$HAMFB_FILE" "$W/fb.$tag.f1.raw"
        # FRAME 2: a small blue corner and NOTHING ELSE. A reopened scene
        # starts a new frame, so the red must be gone -- appended, it would
        # still be there under the blue.
        echo "scene fill 0 0 60 60 #2040e0" >>"$W/script.$tag"; sleep 1.0
        cp "$HAMFB_FILE" "$W/fb.$tag.f2.raw"
        # The server's own account of what it carried.
        if [ "$clientflag" = on ]; then
            echo "== $tag.stat $(as 1002 env HAMWSYS_SERVER=1 \
                 "$BIN/wsys_srv_probe" 2>&1 | tail -1)"
            grep -h 'scene [0-9]' "$W/wsysd.$tag.log" 2>/dev/null | tail -1 \
                | sed "s/^/== $tag.srvline /"
            # THE RED ARM: a second uid-1002 process, owning nothing, sends a
            # routed scene write for this window past its own local check.
            as 1002 env HAMWSYS_SERVER=1 "$BIN/wsys_srv_probe" Scene "$wid" \
                >"$W/attack.out" 2>&1
            echo "== attack.exit $?"
            sed 's/^/== attack: /' "$W/attack.out"
            sleep 0.8
            cp "$HAMFB_FILE" "$W/fb.$tag.f3.raw"
        fi
        kill "$HP" 2>/dev/null; wait "$HP" 2>/dev/null
        kill "$WP" 2>/dev/null; wait "$WP" 2>/dev/null
    }

    arm unrouted off
    arm routed   on
    echo "== done"
    exit 0
fi

cd "$PROJ"
# PRIVATE NAMESPACE FIRST -- before $W, before the build, before anything under
# /tmp exists. wsysd's names are compiled into it (/srv/wsys, /dev/shm/hamnix-wsys,
# /tmp/hamnix-wsys; see the table in tests/linux/private_ns.sh), so a run of this
# gate beside a live desktop is a collision and not an untidiness.
#
# THE HELPER'S ONE FIDELITY COST DOES NOT REACH THIS GATE. priv_ns_reexec makes
# geteuid() 0 in the OUTER shell, and this gate's outer half asserts nothing about
# a uid: every arm runs in the INNER namespace it builds for itself, where wsysd
# is 1001 and the attacker is 1002 exactly as before. What did need fixing is
# where those two ids come from -- see the two-case selection below.
. tests/linux/private_ns.sh
priv_ns_reexec "$@"
OUT="${SRV_WORK:-/home/david/.hamnix-build/wsrv-s6}"
BIN="$OUT/bin"; mkdir -p "$BIN"

for c in "${ADDER_HOST_AC:-}" "$PROJ/build/cutover/host_ac_llvm.elf" \
         "$PROJ/build/cutover/host_ac.elf"; do
    [ -n "$c" ] && [ -x "$c" ] && { ADDER_HOST_AC="$c"; break; }
done
[ -n "${ADDER_HOST_AC:-}" ] || { echo "srvsc: FAIL no host_ac.elf"; exit 2; }
export ADDER_HOST_AC
for t in wsysd:user/wsysd.ad wsys_hold:tests/linux/wsys_hold.ad \
         wsys_srv_probe:tests/linux/wsys_srv_probe.ad; do
    n="${t%%:*}"
    [ "${SRV_REBUILD:-1}" = 0 ] && [ -x "$BIN/$n" ] && continue
    scripts/hamlinux_build.sh "${t#*:}" "$BIN/$n" >"$OUT/build.$n.log" 2>&1 || {
        echo "srvsc: FAIL could not build ${t#*:}"; tail -8 "$OUT/build.$n.log"
        exit 2; }
done

command -v unshare >/dev/null || { echo "srvsc: SKIP no unshare(1)"; exit 0; }
command -v setpriv >/dev/null || { echo "srvsc: SKIP no setpriv(1)"; exit 0; }

# WHERE THE SECOND AND THIRD UID COME FROM -- TWO CASES, AND THE SECOND ONE IS
# WHAT LETS THIS GATE BE ISOLATED AT ALL. Written up at length in
# tests/linux/wsys_enum_policy.sh; the short form:
#
# On a bare host they are subordinate ids out of /etc/subuid for the invoking
# user, as they always were. Inside private_ns.sh's namespace `id -un` is root,
# /etc/subuid HAS NO root LINE, and reading only that file would make this gate
# SKIP -- scoring 0 arms while exiting green, which is the wsys_bypass.sh
# failure mode and would have been an exemption in disguise.
#
# But a process that is root in a user namespace holding a mapped RANGE already
# owns ids 1001 and 1002 and may map them to themselves in a child, needing no
# /etc/subuid and no setuid helper. THE TEST IS THE MAPPING ITSELF, not a read
# of /proc/self/uid_map: on a bare host that file is the initial
# `0 0 4294967295`, which "contains" 1001 and 1002 while an unprivileged process
# may map neither, so a range read would turn a clean SKIP on a subuid-less host
# into "FAIL namespace run rc=1" -- a gate reporting a defect it did not find.
#
# Either way the INNER ids are 0, 1001 and 1002 and every assertion below is
# about those, so which outer ids back them changes nothing this gate claims.
SUB=""
if grep -q "^$(id -un):" /etc/subuid 2>/dev/null \
   && grep -q "^$(id -un):" /etc/subgid 2>/dev/null; then
    SUB="$(awk -F: -v u="$(id -un)" '$1==u{print $2; exit}' /etc/subuid)"
    IDSRC="/etc/subuid range $SUB for $(id -un)"
elif unshare -U \
        --map-users=0:"$(id -u)":1      --map-groups=0:"$(id -g)":1 \
        --map-users=1001:1001:1         --map-groups=1001:1001:1 \
        --map-users=1002:1002:1         --map-groups=1002:1002:1 \
        true 2>/dev/null; then
    SUB=1001
    IDSRC="ids 1001/1002 are already this namespace's own (mapped to themselves; no /etc/subuid needed)"
else
    echo "srvsc: SKIP no /etc/subuid range for $(id -un), and this namespace does"
    echo "srvsc: SKIP not already own uids 1001 and 1002; run this in the VM"
    exit 0
fi
note "$(priv_ns_describe)"
note "the two extra uids: $IDSRC"

W="$(mktemp -d "${TMPDIR:-/tmp}/wsrvsc.XXXXXX")"
trap 'rm -rf "$W"' EXIT
trap 'exit 130' INT TERM HUP
chmod 1777 "$W"
mkdir -p "$W/bin"; cp "$BIN"/* "$W/bin/"; chmod 755 "$W/bin"/*
cp "$0" "$W/inner.sh"; chmod 755 "$W/inner.sh"
cp tests/linux/reap.sh "$W/reap.sh"

OUTF="$W/out.txt"
unshare -U \
    --map-users=0:"$(id -u)":1      --map-groups=0:"$(id -g)":1 \
    --map-users=1001:"$SUB":1       --map-groups=1001:"$SUB":1 \
    --map-users=1002:"$((SUB+1))":1 --map-groups=1002:"$((SUB+1))":1 \
    -- "$W/inner.sh" --inner "$W" >"$OUTF" 2>&1
rc=$?
sed 's/^/srvsc|  /' "$OUTF"
[ $rc -eq 0 ] || { echo "srvsc: FAIL namespace run rc=$rc"; exit 2; }

f() { grep -m1 "^== $1" "$OUTF" | sed "s/^== $1 *//"; }

# px <file> <x> <y> -> "r,g,b" out of the XRGB8888 framebuffer.
px() {
    python3 - "$1" "$GEOM" "$2" "$3" <<'PY'
import sys
raw = open(sys.argv[1], 'rb').read()
w, h = (int(v) for v in sys.argv[2].split('x'))
x, y = int(sys.argv[3]), int(sys.argv[4])
o = (y * w + x) * 4
if o + 3 > len(raw):
    print("none"); raise SystemExit
print("%d,%d,%d" % (raw[o+2], raw[o+1], raw[o]))
PY
}
near() { # near "r,g,b" R G B [tol]
    python3 - "$1" "$2" "$3" "$4" "${5:-60}" <<'PY'
import sys
got = sys.argv[1]
if got == "none": print("no"); raise SystemExit
r, g, b = (int(v) for v in got.split(','))
R, G, B, tol = (int(v) for v in sys.argv[2:6])
print("yes" if abs(r-R) <= tol and abs(g-G) <= tol and abs(b-B) <= tol else "no")
PY
}

# Deep inside the window and well outside the 60x60 corner.
MX=$((WX + 200)); MY=$((WY + 160))
# Inside the corner both frames touch.
CX=$((WX + 20));  CY=$((WY + 20))

UWID="$(f unrouted.wid)"; RWID="$(f routed.wid)"
note "unrouted window $UWID, routed window $RWID; both uid 1002, both 300x220 at ($WX,$WY)"

# ---------- 1. THE INSTRUMENT: the UNROUTED arm must paint ---------------
U1="$(px "$W/fb.unrouted.f1.raw" "$MX" "$MY")"
if [ "$(near "$U1" 208 32 32)" = yes ]; then
    ok "UNROUTED frame 1 painted: the middle of the window is red ($U1). The instrument can produce a non-blank answer, so an 'it is gone' below is a reading and not an empty framebuffer agreeing with itself."
else
    bad "UNROUTED frame 1 did not paint red at ($MX,$MY): got $U1. The compositor, the geometry or the scene syntax is wrong; every pixel assertion below would be vacuous and none is scored as evidence."
fi

# ---------- 2. THE PAINT, ROUTED ---------------------------------------
R1="$(px "$W/fb.routed.f1.raw" "$MX" "$MY")"
if [ "$(near "$R1" 208 32 32)" = yes ]; then
    ok "ROUTED frame 1 PAINTED: the display list crossed the boundary as a message, the server wrote it into the window's handed-up memfd, and the compositor put it on the screen ($R1). This is the arm a refusal-only gate cannot have."
else
    bad "ROUTED frame 1 did not paint at ($MX,$MY): got $R1 against the unrouted arm's $U1. Routing the scene stopped the window painting -- the same failure as the empty-window bug, and it would not have shown up in a byte count."
fi

# ---------- 3. THE FRAME BOUNDARY --------------------------------------
U2="$(px "$W/fb.unrouted.f2.raw" "$MX" "$MY")"
R2="$(px "$W/fb.routed.f2.raw" "$MX" "$MY")"
UC="$(px "$W/fb.unrouted.f2.raw" "$CX" "$CY")"
RC="$(px "$W/fb.routed.f2.raw" "$CX" "$CY")"
note "after frame 2 (a 60x60 blue corner and nothing else): middle unrouted $U2 routed $R2; corner unrouted $UC routed $RC"
if [ "$(near "$U2" 208 32 32)" = yes ]; then
    bad "UNROUTED frame 2 left the red in the middle -- reopening the scene did NOT start a new frame on the path this gate compares against, so the comparison below is against a broken control"
else
    ok "UNROUTED frame 2: the red is GONE from the middle ($U2) -- reopening the scene starts a new frame, which is the behaviour routing has to preserve"
fi
if [ "$(near "$R2" 208 32 32)" = yes ]; then
    bad "ROUTED frame 2 STILL SHOWS FRAME 1's RED at ($MX,$MY): got $R2. The frame boundary was lost in routing -- the display list is being APPENDED instead of restarted, which is exactly the defect that made an empty window look full and which no byte count would reveal."
else
    ok "ROUTED frame 2: the red is GONE ($R2) -- WSRV_F_NEWFRAME carried the open across the boundary and the server restarted the display list rather than appending to it"
fi
if [ "$(near "$RC" 32 64 224)" = yes ]; then
    ok "and frame 2's blue corner IS on the screen routed ($RC) -- the new frame was not merely empty, which is the other way this arm could pass for the wrong reason"
else
    bad "frame 2's blue corner did not paint routed (got $RC, unrouted $UC) -- 'the red is gone' above may mean the window stopped painting altogether"
fi

# ---------- 4. THE RED ARM: a caller that does not hold the connection ---
note "the stage-5 rule applied to the last leaf: a uid-1002 process owning nothing sends a routed SCENE write for window $RWID, past its own local check:"
grep '^== attack:' "$OUTF" | sed 's/^== attack: /srvsc|      /'
if grep -q 'did not see the routed scene write' "$OUTF"; then
    bad "the server never received the routed scene write -- a refusal count of zero means nothing if the message never arrived"
elif grep -q 'wsrvsc: the mediator REFUSED it' "$OUTF"; then
    ok "the mediator REFUSED a routed scene write from a process that holds no connection to that row -- the connection question reaches the display list too, not just ctl"
else
    bad "the routed scene write from a window-less uid-1002 process was ACCEPTED -- the last leaf is not carrying the rule the other leaves carry"
fi
A3="$(px "$W/fb.routed.f3.raw" "$MX" "$MY" 2>/dev/null || echo none)"
if [ "$(near "$A3" 255 0 255)" = yes ]; then
    bad "the attacker's magenta fill REACHED THE SCREEN ($A3) -- the refusal was reported and the pixels landed anyway"
elif [ "$A3" = none ]; then
    bad "no framebuffer was captured after the attack, so what reached the screen is UNMEASURED"
else
    ok "and the attacker's magenta is not on the screen ($A3) -- the refusal is a pixel fact, not only a counter"
fi

# ---------- 5. ROUTING CHANGED NOTHING A PERSON CAN SEE -----------------
if [ "$U1" = "$R1" ] && [ "$U2" = "$R2" ]; then
    ok "every sampled pixel is IDENTICAL routed and unrouted (frame 1 $U1, frame 2 $U2) -- the flag changes who writes the display list and nothing about what is on the screen"
else
    bad "routed and unrouted differ on the screen: frame 1 $U1 vs $R1, frame 2 $U2 vs $R2"
fi

echo "srvsc: $pass passed, $fail failed"
[ "$fail" = 0 ]
