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
# tests/linux/wsys_srv_wctl.sh — ROUTING /dev/wsys/<wid>/wctl, AND THE
# ASSERTION IS THAT THE WINDOW LANDS IN THE SAME PLACE.
#
# WHY THIS LEAF, AND WHY IT IS NOT A REPEAT OF THE ctl ONE
# =======================================================
# docs/wsys_server_design.md 7.1(4): `move`/`resize` on another window is the
# SAME ACT as the `geometry` verb on wid/ctl, which stage 2 routed -- and that
# document argues elsewhere, about the wallpaper sink, that "a gate on only one
# of the two spellings is not a gate". Until this commit `wid/wctl` took move,
# resize, focus and version IN PROCESS with the mediator running and idle.
#
# WHAT IS DIFFERENT ABOUT IT, AND IT IS ONE VERB
# ==============================================
# Every other routed mutation is fire-and-forget: the client writes and does
# not wait, and an error arrives out of band. `version` CANNOT BE, and the
# reason is in lib/hamui.ad:
#
#     n: int64 = sys_write(fd, msg, _h_strlen(msg))   # "version 2\n"
#     if n < 0:
#         return -1
#     h_v2_active = 1
#
# The client's entire protocol decision is that write's return value. Routed
# fire-and-forget, the write returns the byte count whatever the server
# decided, so EVERY APPLICATION WOULD SET h_v2_active ON A REFUSAL and draw
# into a backbuffer the compositor was not reading. A `version 2` write that
# succeeded into a sink is the most expensive bug in this project's history --
# every app was silently not v2 -- and a routed version that appears to work
# and does not would be that bug rebuilt. So `version` alone blocks and the
# server's rc is the write's return value, and THIS FILE ASSERTS THAT DIRECTLY:
# `version 9` must be REFUSED with a negative return value on the routed path,
# and `version 2` must succeed and be visible as proto 2 in the window row.
#
# An UNKNOWN verb is not routed at all -- wctl is a closed set that answers
# -EINVAL and touches nothing, so the in-process path already refuses it
# without a round trip. Asserted here too, because fire-and-forget it would
# have answered SUCCESS to a typo.
#
# WHAT IT ASSERTS, in order of how much it matters:
#
#   1. THE OUTCOME IS THE SAME, not merely that neither path crashed. The same
#      script runs with HAMWSYS_SERVER set and unset on the SAME binaries and
#      the window's LIVE RECT (read back from /dev/wsys/<wid>/wctl) and the
#      PIXELS ON THE SCREEN are compared after every mutation. A routed move
#      that landed the window one pixel off, or a routed resize that changed
#      the row and not the paint, fails here and nowhere else.
#   2. THE INSTRUMENT IS PROVEN FIRST. The unrouted arm must show the window
#      moving and resizing on the framebuffer. If it does not, every "identical
#      routed" below is two blank screens agreeing with each other.
#   3. `version` ANSWERS. Refused for 9, accepted for 2, proto 2 in the row.
#   4. RED-UNROUTED / GREEN-ROUTED, on this leaf's own verb. A uid-1002 process
#      owning nothing sends `move 777 888` for somebody else's window:
#        * routed, past its own local check -> the mediator REFUSES it and the
#          window does not move;
#        * unrouted, with ONE assignment to the identity the in-process check
#          reads -> IT LANDS, and the window is at 777,888.
#      Either half alone is unfalsifiable: a gate that is green in every
#      configuration is equally green against a server that checks nothing.
#   5. THE COST, three samples per arm, every one printed. A drag is exactly
#      the operation this leaf performs, so this is the hottest leaf yet
#      routed; /proc/<pid>/stat deltas for the compositor and the client and
#      the wall time for a fixed burst of moves. The verdict is
#      ATTRIBUTABLE / NOT ATTRIBUTABLE against the loadavg, because other
#      agents run VM gates on this host and a percentage quoted without the
#      load it was taken at is not reproducible.
#
# THE NEGATIVE CONTROL, RUN AND WRITTEN DOWN. Set `*blocking = 0` for
# `version` in srv_wctl_verb -- one character, keeping the routing, keeping the
# permission check, keeping everything else -- and this file goes from
# 18 passed / 0 failed to 17 passed / 1 failed:
#
#   FAIL ROUTED `version 9` returned 10 -- a REFUSED version write reported
#        SUCCESS to its caller.
#
# EVERY OTHER ARM STAYS GREEN, including both pixel comparisons, all four
# live-rect readings, `version 2` succeeding, proto reading 2, and the refusal
# pair. That is the point of the version arm: the defect it exists to catch is
# invisible to every other kind of assertion in this file, and it is the defect
# that made every application silently not-v2 once already.
#
# AND A SECOND CONTROL THAT DOES **NOT** GO RED, RECORDED BECAUSE IT CORRECTS A
# NATURAL READING OF THE CODE: dropping `wid/wctl` from the server's own
# ownership pre-check does not change any refusal here, because
# hamwsys_write_inner's wctl arm makes the same two checks and, under
# srv_as_caller, makes them about the caller. The mediation is
# srv_as_caller_full() and nothing else -- exactly as stage 2 said of the first
# leaf. The pre-check earns its place on the connrefused counter, not on the
# refusal.
#
# Offscreen (HAMFB_FILE), software, no ICD. /dev/dri is untouched.
# WSYS_VERSION stays 8.
set -uo pipefail
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail=0; pass=0
ok()   { printf 'srvwc: PASS %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf 'srvwc: FAIL %s\n' "$*"; fail=$((fail+1)); }
note() { printf 'srvwc: .... %s\n' "$*"; }

# The window: 300x220 at (200,150) undecorated, then moved far enough that the
# before-rect and the after-rect DO NOT OVERLAP -- a 60 px nudge would leave
# every sampled pixel inside both and the move would be unmeasurable.
WX=200; WY=150; WW=300; WH=220
MX2=600; MY2=400            # after `move`
RW=120;  RH=90              # after `resize`
GEOM=1280x800
BURST=${SRV_WCTL_BURST:-40000}

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

    # utime+stime in ticks out of /proc/<pid>/stat. Field 14 and 15 AFTER the
    # comm field, which is parenthesised and may contain spaces -- so the split
    # is on the last ')' and not on whitespace from the start.
    cpu_ticks() {
        local p="$1" line rest
        line="$(cat "/proc/$p/stat" 2>/dev/null)" || { echo ""; return; }
        rest="${line#*) }"
        # rest starts at field 3 (state); utime is field 14 => index 12 here.
        set -- $rest
        echo "$(( ${12} + ${13} ))"
    }

    # Read a /dev/wsys file through a hamnix binary. The host's own cat cannot:
    # /dev/wsys is served inside hamnix processes.
    rd() { as 1002 "$BIN/wsys_poke" "$1" 2>/dev/null | tr -d '\n'; }

    # ---- one arm: "routed" or "unrouted" ------------------------------
    # Identical in every respect except HAMWSYS_SERVER on the CLIENT. wsysd
    # runs with HAMWSYS_SERVER=1 in both arms, so the unrouted arm is a client
    # walking past a live mediator -- the state of the tree today.
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
            as_bg 1002 "$W/hold.$tag.out" "$W/hold.$tag.log" \
                  env HAMWSYS_SERVER=1 "$BIN/wsys_hold" "$W/script.$tag"
        else
            as_bg 1002 "$W/hold.$tag.out" "$W/hold.$tag.log" \
                  "$BIN/wsys_hold" "$W/script.$tag"
        fi
        local HP=$BGPID
        for i in $(seq 1 100); do [ -s "$W/hold.$tag.out" ] && break; sleep 0.1; done
        local wid; wid="$(head -1 "$W/hold.$tag.out" 2>/dev/null | tr -d '\n')"
        echo "== $tag.wid ${wid:-none}"
        if [ -z "${wid:-}" ] || [ "${wid:-0}" -lt 2 ]; then
            kill "$HP" "$WP" 2>/dev/null; wait "$HP" "$WP" 2>/dev/null; return
        fi

        # ---- geometry, then a red fill so the window is visible -------
        {   echo "ctl geometry $WX $WY $WW $WH"
            echo "ctl visible 1"
        } >>"$W/script.$tag"; sleep 0.6
        echo "scene fill 0 0 $WW $WH #d02020" >>"$W/script.$tag"; sleep 1.0
        cp "$HAMFB_FILE" "$W/fb.$tag.f1.raw"
        echo "== $tag.g1 $(rd "/dev/wsys/$wid/wctl")"

        # ---- MOVE, through wctl --------------------------------------
        echo "wctl move $MX2 $MY2" >>"$W/script.$tag"; sleep 1.2
        cp "$HAMFB_FILE" "$W/fb.$tag.f2.raw"
        echo "== $tag.g2 $(rd "/dev/wsys/$wid/wctl")"

        # ---- RESIZE, through wctl ------------------------------------
        # The display list is re-committed afterwards so that a resize that
        # changed the row and not the paint is still visible as a change of
        # painted AREA rather than as a stale frame.
        echo "wctl resize $RW $RH" >>"$W/script.$tag"; sleep 0.5
        echo "scene fill 0 0 $WW $WH #d02020" >>"$W/script.$tag"; sleep 1.2
        cp "$HAMFB_FILE" "$W/fb.$tag.f3.raw"
        echo "== $tag.g3 $(rd "/dev/wsys/$wid/wctl")"

        # ---- FOCUS ----------------------------------------------------
        echo "wctl focus sloppy" >>"$W/script.$tag"; sleep 0.8
        echo "== $tag.g4 $(rd "/dev/wsys/$wid/wctl")"

        # ---- THE CLOSED SET, AND THE NEGOTIATION ----------------------
        # Order matters: `version 2` switches the window to the blit protocol
        # and the compositor stops painting its display list, so every pixel
        # assertion above is taken BEFORE this point.
        echo "wctl version 9" >>"$W/script.$tag"; sleep 0.8
        echo "wctl wibble" >>"$W/script.$tag"; sleep 0.8
        echo "wctl version 2" >>"$W/script.$tag"; sleep 1.0
        echo "== $tag.ctl $(rd "/dev/wsys/$wid/ctl")"
        grep -h '^WCTL ' "$W/hold.$tag.out" | sed "s/^/== $tag.wctlrc /"

        # ---- WHO ROUTED WHAT, COUNTED RATHER THAN ASSUMED --------------
        # Every arm above is driven through the client's ordinary write path,
        # so an arm that stopped routing wctl entirely would still be green:
        # the outcomes would match because BOTH paths would be the in-process
        # one. The server's own trace names the leaf, and it is scoped to the
        # CLIENT'S pid because the attacker below sends a routed wctl of its
        # own. Counted BEFORE the attack for the same reason.
        echo "== $tag.wctltrace $(grep -c "pid=$HP .*leaf=wid/wctl" \
              "$W/wsysd.$tag.log" 2>/dev/null || true)"

        # ---- THE RED/GREEN PAIR ---------------------------------------
        if [ "$clientflag" = on ]; then
            as 1002 env HAMWSYS_SERVER=1 "$BIN/wsys_srv_probe" Wctl "$wid" \
                >"$W/attack.$tag.out" 2>&1
            echo "== $tag.attack.exit $?"
        else
            as 1002 "$BIN/wsys_srv_probe" Wctl "$wid" 1 \
                >"$W/attack.$tag.out" 2>&1
            echo "== $tag.attack.exit $?"
        fi
        sed "s/^/== $tag.attack: /" "$W/attack.$tag.out"
        sleep 0.6
        echo "== $tag.g5 $(rd "/dev/wsys/$wid/wctl")"

        # ---- THE COST: a drag is a burst of moves ---------------------
        # Three samples, alternated with the other arm by the caller, every one
        # printed. The completion of the burst is DETECTED (the sentinel
        # position read back) rather than waited out, so the wall time is the
        # time the mutations took and not a sleep.
        local rep
        for rep in 1 2 3; do
            local sx=$((300 + rep)) sy=$((200 + rep))
            local t0 t1 wb0 wb1 hb0 hb1 la
            wb0="$(cpu_ticks "$WP")"; hb0="$(cpu_ticks "$HP")"
            la="$(cut -d' ' -f1 /proc/loadavg)"
            t0=$(date +%s%N)
            python3 - "$W/script.$tag" "$BURST" "$sx" "$sy" <<'PY'
import sys
path, n, sx, sy = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
out = []
for i in range(n - 1):
    out.append("qwctl move %d %d\n" % (700 + (i % 40), 500 + (i % 40)))
out.append("qwctl move %d %d\n" % (sx, sy))
with open(path, "a") as f:
    f.write("".join(out))
PY
            local seen=0 k
            for k in $(seq 1 600); do
                case "$(rd "/dev/wsys/$wid/wctl")" in
                    "$sx $sy "*) seen=1; break;;
                esac
                sleep 0.05
            done
            t1=$(date +%s%N)
            wb1="$(cpu_ticks "$WP")"; hb1="$(cpu_ticks "$HP")"
            echo "== $tag.cost rep=$rep seen=$seen ms=$(( (t1 - t0) / 1000000 ))" \
                 "wsysd_ticks=$((wb1 - wb0)) client_ticks=$((hb1 - hb0))" \
                 "load=$la moves=$BURST"
        done

        kill "$HP" 2>/dev/null; wait "$HP" 2>/dev/null
        kill "$WP" 2>/dev/null; wait "$WP" 2>/dev/null
    }

    arm unrouted off
    arm routed   on
    echo "== done"
    exit 0
fi

cd "$PROJ"
# PRIVATE NAMESPACE FIRST -- before $W, before the build. wsysd's segment names
# are compiled into it, so a run of this gate beside a live desktop is a
# collision and not an untidiness. See tests/linux/private_ns.sh.
. tests/linux/private_ns.sh
priv_ns_reexec "$@"
OUT="${SRV_WORK:-/home/david/.hamnix-build/wsrv-wctl}"
BIN="$OUT/bin"; mkdir -p "$BIN"

for c in "${ADDER_HOST_AC:-}" "$PROJ/build/cutover/host_ac_llvm.elf" \
         "$PROJ/build/cutover/host_ac.elf"; do
    [ -n "$c" ] && [ -x "$c" ] && { ADDER_HOST_AC="$c"; break; }
done
[ -n "${ADDER_HOST_AC:-}" ] || { echo "srvwc: FAIL no host_ac.elf"; exit 2; }
export ADDER_HOST_AC
for t in wsysd:user/wsysd.ad wsys_hold:tests/linux/wsys_hold.ad \
         wsys_poke:tests/linux/wsys_poke.ad \
         wsys_srv_probe:tests/linux/wsys_srv_probe.ad; do
    n="${t%%:*}"
    [ "${SRV_REBUILD:-1}" = 0 ] && [ -x "$BIN/$n" ] && continue
    scripts/hamlinux_build.sh "${t#*:}" "$BIN/$n" >"$OUT/build.$n.log" 2>&1 || {
        echo "srvwc: FAIL could not build ${t#*:}"; tail -8 "$OUT/build.$n.log"
        exit 2; }
done

command -v unshare >/dev/null || { echo "srvwc: SKIP no unshare(1)"; exit 0; }
command -v setpriv >/dev/null || { echo "srvwc: SKIP no setpriv(1)"; exit 0; }

# The two extra uids, exactly as wsys_srv_scene.sh selects them and for the
# same two reasons -- written up there and in wsys_enum_policy.sh.
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
    echo "srvwc: SKIP no /etc/subuid range for $(id -un), and this namespace does"
    echo "srvwc: SKIP not already own uids 1001 and 1002; run this in the VM"
    exit 0
fi
note "$(priv_ns_describe)"
note "the two extra uids: $IDSRC"

W="$(mktemp -d "${TMPDIR:-/tmp}/wsrvwc.XXXXXX")"
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
sed 's/^/srvwc|  /' "$OUTF"
[ $rc -eq 0 ] || { echo "srvwc: FAIL namespace run rc=$rc"; exit 2; }

f() { grep -m1 "^== $1" "$OUTF" | sed "s/^== $1 *//"; }

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

UWID="$(f unrouted.wid)"; RWID="$(f routed.wid)"
note "unrouted window $UWID, routed window $RWID; both uid 1002, both created at ($WX,$WY) ${WW}x${WH}"

# A point inside the ORIGINAL rect and outside the moved one, and one inside
# the moved rect and outside the original. Non-overlapping by construction.
AX=$((WX + 30));  AY=$((WY + 30))
BX=$((MX2 + 30)); BY=$((MY2 + 30))
# Inside the moved rect at full size, OUTSIDE it once resized to RW x RH.
CX=$((MX2 + 200)); CY=$((MY2 + 150))

# ---------- 1. THE INSTRUMENT: the unrouted arm must move and resize -------
U1A="$(px "$W/fb.unrouted.f1.raw" "$AX" "$AY")"
U2A="$(px "$W/fb.unrouted.f2.raw" "$AX" "$AY")"
U2B="$(px "$W/fb.unrouted.f2.raw" "$BX" "$BY")"
note "unrouted: original corner ($AX,$AY) was $U1A before the move and $U2A after; the moved-to point ($BX,$BY) is $U2B after"
if [ "$(near "$U1A" 208 32 32)" = yes ] && [ "$(near "$U2A" 208 32 32)" = no ] \
   && [ "$(near "$U2B" 208 32 32)" = yes ]; then
    ok "UNROUTED: the window PAINTED at ($WX,$WY) and a wctl \`move\` MOVED IT on the screen -- red left ($AX,$AY) and appeared at ($BX,$BY). The instrument can produce both answers, so an 'identical' below is a reading and not two blank screens agreeing."
else
    bad "UNROUTED wctl \`move\` did not move the painted window: ($AX,$AY) $U1A -> $U2A, ($BX,$BY) $U2B. The compositor, the geometry or the wctl syntax is wrong, and every comparison below would be vacuous."
fi
U3C="$(px "$W/fb.unrouted.f3.raw" "$CX" "$CY")"
U2C="$(px "$W/fb.unrouted.f2.raw" "$CX" "$CY")"
if [ "$(near "$U2C" 208 32 32)" = yes ] && [ "$(near "$U3C" 208 32 32)" = no ]; then
    ok "UNROUTED: a wctl \`resize\` to ${RW}x${RH} SHRANK THE PAINTED AREA -- ($CX,$CY) was $U2C and is now $U3C"
else
    bad "UNROUTED wctl \`resize\` did not change what is painted at ($CX,$CY): $U2C -> $U3C"
fi

# ---------- 2. THE ROUTED ARM DOES THE SAME THING ------------------------
R1A="$(px "$W/fb.routed.f1.raw" "$AX" "$AY")"
R2A="$(px "$W/fb.routed.f2.raw" "$AX" "$AY")"
R2B="$(px "$W/fb.routed.f2.raw" "$BX" "$BY")"
R3C="$(px "$W/fb.routed.f3.raw" "$CX" "$CY")"
if [ "$R1A" = "$U1A" ] && [ "$R2A" = "$U2A" ] && [ "$R2B" = "$U2B" ] \
   && [ "$R3C" = "$U3C" ]; then
    ok "ROUTED: every sampled pixel is IDENTICAL to the unrouted arm through move and resize (corner $R1A->$R2A, moved-to $R2B, resized-away $R3C). The flag changes WHO applies the mutation and nothing about where the window lands."
else
    bad "routed and unrouted differ ON THE SCREEN: corner before $U1A/$R1A after $U2A/$R2A, moved-to $U2B/$R2B, resized-away $U3C/$R3C"
fi

# ---------- 3. THE ROW ITSELF, READ BACK ---------------------------------
# /dev/wsys/<wid>/wctl reads "<x> <y> <w> <h> <focus>" -- the live rect as it
# is composited, which is the state both paths are supposed to be writing.
for s in g1 g2 g3 g4; do
    note "$s: unrouted [$(f "unrouted.$s")]  routed [$(f "routed.$s")]"
done
same=1
for s in g1 g2 g3 g4; do
    [ "$(f "unrouted.$s")" = "$(f "routed.$s")" ] || same=0
done
if [ "$(f unrouted.g2)" = "$MX2 $MY2 $WW $WH click" ]; then
    ok "the unrouted \`move\` really is the state under test: the live rect reads exactly \`$MX2 $MY2 $WW $WH click\`"
else
    bad "the unrouted \`move\` did not produce the expected live rect: got [$(f unrouted.g2)], wanted [$MX2 $MY2 $WW $WH click]"
fi
if [ "$(f routed.g3)" = "$MX2 $MY2 $RW $RH click" ]; then
    ok "and the ROUTED \`resize\` wrote the same row the unrouted one does: [$(f routed.g3)]"
else
    bad "the routed \`resize\` left the row at [$(f routed.g3)], wanted [$MX2 $MY2 $RW $RH click]"
fi
if [ "$(f routed.g4)" = "${MX2} ${MY2} ${RW} ${RH} sloppy" ]; then
    ok "\`focus sloppy\` crossed the boundary too: the routed row reads [$(f routed.g4)] -- a verb with no geometry in it, so a routing that only carried numbers would fail here"
else
    bad "the routed \`focus sloppy\` did not take: [$(f routed.g4)], wanted [$MX2 $MY2 $RW $RH sloppy]"
fi
if [ "$same" = 1 ]; then
    ok "and ALL FOUR live-rect readings are byte-identical routed and unrouted"
else
    bad "the live rect differs between the arms at one of g1..g4 (printed above) -- the routed path is not writing the same state"
fi

# ---------- 4. version: THE ONE VERB THAT HAS TO ANSWER -------------------
uv9="$(grep -m1 '^== unrouted.wctlrc WCTL .* version 9' "$OUTF" | awk '{print $4}')"
rv9="$(grep -m1 '^== routed.wctlrc WCTL .* version 9'   "$OUTF" | awk '{print $4}')"
uvx="$(grep -m1 '^== unrouted.wctlrc WCTL .* wibble'    "$OUTF" | awk '{print $4}')"
rvx="$(grep -m1 '^== routed.wctlrc WCTL .* wibble'      "$OUTF" | awk '{print $4}')"
uv2="$(grep -m1 '^== unrouted.wctlrc WCTL .* version 2' "$OUTF" | awk '{print $4}')"
rv2="$(grep -m1 '^== routed.wctlrc WCTL .* version 2'   "$OUTF" | awk '{print $4}')"
note "write(2) return values -- version 9: unrouted ${uv9:-?} routed ${rv9:-?}; wibble: ${uvx:-?}/${rvx:-?}; version 2: ${uv2:-?}/${rv2:-?}"
if [ -n "${uv9:-}" ] && [ "${uv9:-0}" -lt 0 ] 2>/dev/null; then
    ok "UNROUTED \`version 9\` is REFUSED with rc $uv9 -- the closed set is real on the path this compares against"
else
    bad "UNROUTED \`version 9\` returned ${uv9:-nothing}; the control for the arm below is broken"
fi
if [ -n "${rv9:-}" ] && [ "${rv9:-0}" -lt 0 ] 2>/dev/null; then
    ok "ROUTED \`version 9\` is REFUSED WITH A NEGATIVE RETURN VALUE ($rv9) -- the negotiation ANSWERS across the boundary. Fire-and-forget it would have returned the byte count and lib/hamui.ad would have set h_v2_active on a refusal, which is the silently-not-v2 defect rebuilt."
else
    bad "ROUTED \`version 9\` returned ${rv9:-nothing} -- a REFUSED version write reported SUCCESS to its caller. This is the most expensive bug shape this project has had: every application would believe it was v2 while the compositor painted it v0."
fi
if [ -n "${rvx:-}" ] && [ "${rvx:-0}" -lt 0 ] 2>/dev/null \
   && [ "${uvx:-0}" -lt 0 ] 2>/dev/null; then
    ok "an UNKNOWN verb (\`wibble\`) is refused on both paths (${uvx}/${rvx}) -- wctl stays a closed set, and a typo does not become a success by being routed"
else
    bad "\`wibble\` returned ${uvx:-?} unrouted and ${rvx:-?} routed; an unknown verb must be -EINVAL on both"
fi
if [ "${uv2:-0}" -gt 0 ] 2>/dev/null && [ "${rv2:-0}" -gt 0 ] 2>/dev/null; then
    ok "and \`version 2\` SUCCEEDS on both paths (${uv2}/${rv2}) -- the refusal above is a decision about the argument, not a routed version that refuses everything"
else
    bad "\`version 2\` returned ${uv2:-?} unrouted and ${rv2:-?} routed; a routed version that refuses the one value every v2 client writes would break every application"
fi
# proto is field 9 of the window ctl row.
up="$(f unrouted.ctl | awk '{print $9}')"; rp="$(f routed.ctl | awk '{print $9}')"
if [ "$up" = 2 ] && [ "$rp" = 2 ]; then
    ok "and the WINDOW ROW agrees: proto is 2 on both arms after the routed negotiation, so the success was applied and not merely reported (unrouted [$(f unrouted.ctl)], routed [$(f routed.ctl)])"
else
    bad "proto is $up unrouted and $rp routed after \`version 2\`: the routed write reported success and the row does not show it -- a write that succeeded into a sink"
fi

# ---------- 4b. THE WRITES ACTUALLY CROSSED ------------------------------
# Without this, a build that routed NOTHING would pass every arm above: both
# arms would take the in-process path and agree with each other perfectly.
UT="$(f unrouted.wctltrace)"; RT="$(f routed.wctltrace)"
note "routed wctl mutations seen by the server from the client's own pid: unrouted $UT, routed $RT (move, resize, focus, version 9, version 2 -- \`wibble\` is deliberately not routed)"
if [ "${RT:-0}" -ge 5 ] 2>/dev/null; then
    ok "the ROUTED arm's wctl writes really crossed the boundary: $RT of them are in the server's own trace, named by leaf. Every equality arm above is therefore comparing a mediated path against an unmediated one and not two copies of the same one."
else
    bad "the server's trace shows only ${RT:-0} routed wctl mutations from the client -- the equality arms above are comparing the in-process path with itself and prove nothing"
fi
if [ "${UT:-1}" = 0 ]; then
    ok "and the UNROUTED arm sent none ($UT) -- it is the control it claims to be"
else
    bad "the unrouted arm routed $UT wctl mutations; the two arms are not the two paths"
fi

# ---------- 5. RED-UNROUTED / GREEN-ROUTED -------------------------------
note "a uid-1002 process owning nothing sends \`move 777 888\` for window $RWID:"
grep '^== routed.attack:' "$OUTF" | sed 's/^== routed.attack: /srvwc|      /'
grep '^== unrouted.attack:' "$OUTF" | sed 's/^== unrouted.attack: /srvwc|      /'
if grep -q 'wsrvwc: FAIL the server did not count' "$OUTF"; then
    bad "the server never counted the routed wctl write -- a refusal means nothing if the message did not arrive"
elif grep -q 'wsrvwc: the mediator REFUSED it' "$OUTF"; then
    ok "ROUTED: the mediator REFUSED the wctl \`move\` from a process that owns no window and holds no connection to that row -- the same rule wid/ctl already carries, now on the other spelling of the same act"
else
    bad "the routed wctl \`move\` from a window-less uid-1002 process was ACCEPTED -- this leaf is not carrying the rule the other leaves carry"
fi
if grep -q 'wsrvwc: the UNROUTED wctl move LANDED' "$OUTF"; then
    ok "UNROUTED: the identical move LANDED after ONE assignment to the identity the in-process check reads -- the pair is the case for the boundary, and this half is what makes the refusal above a measurement rather than a configuration"
else
    bad "the unrouted wctl move did NOT land, so the routed refusal above is unfalsifiable: a gate green in every configuration is equally green against a server that checks nothing"
fi
RG5="$(f routed.g5)"; UG5="$(f unrouted.g5)"
note "after the attack: routed rect [$RG5], unrouted rect [$UG5]"
case "$RG5" in
    "777 888 "*) bad "the ROUTED window is at 777,888 -- the refusal was reported and the move landed anyway";;
    "") bad "no rect was read after the routed attack, so what happened to the window is UNMEASURED";;
    *)  ok "and the routed window did NOT move (still [$RG5]) -- the refusal is a state fact, not only a return code";;
esac
case "$UG5" in
    "777 888 "*) ok "while the unrouted window IS at 777,888 -- the same act, the same uid, the same binary, and only the mediator between them";;
    *) bad "the unrouted attack reported landing and the rect reads [$UG5]";;
esac

# ---------- 6. THE COST -------------------------------------------------
note "THE COST OF ROUTING A DRAG. A drag is a stream of moves, so this leaf is"
note "the hottest yet routed. $BURST wctl moves per sample, three samples per arm,"
note "EVERY ONE PRINTED; ms is wall time to the sentinel move being observed."
grep '^== unrouted.cost' "$OUTF" | sed 's/^== /srvwc|      /'
grep '^== routed.cost'   "$OUTF" | sed 's/^== /srvwc|      /'
python3 - "$OUTF" "$BURST" <<'PY'
import re, sys, statistics
out, burst = open(sys.argv[1]).read().splitlines(), int(sys.argv[2])
arms = {"unrouted": [], "routed": []}
loads = []
for ln in out:
    m = re.match(r"== (unrouted|routed)\.cost rep=(\d+) seen=(\d+) ms=(\d+) "
                 r"wsysd_ticks=(-?\d+) client_ticks=(-?\d+) load=([\d.]+)", ln)
    if m:
        arms[m.group(1)].append((int(m.group(3)), int(m.group(4)),
                                 int(m.group(5)), int(m.group(6))))
        loads.append(float(m.group(7)))
bad = [a for a in arms if not arms[a] or any(s[0] == 0 for s in arms[a])]
if bad:
    print("srvwc: FAIL the cost arm never observed the sentinel move in "
          + ",".join(bad) + " -- the burst did not complete, so no number here "
          "means anything")
    raise SystemExit
for a in ("unrouted", "routed"):
    ms = [s[1] for s in arms[a]]
    wt = [s[2] for s in arms[a]]
    ct = [s[3] for s in arms[a]]
    print("srvwc: .... %-8s ms %s (median %d) | wsysd ticks %s | client ticks %s"
          % (a, ms, statistics.median(ms), wt, ct))
um = statistics.median([s[1] for s in arms["unrouted"]])
rm = statistics.median([s[1] for s in arms["routed"]])
print("srvwc: .... %d moves: unrouted median %d ms (%.1f us/move), routed "
      "median %d ms (%.1f us/move), routed/unrouted = %.2fx"
      % (burst, um, um * 1000.0 / burst, rm, rm * 1000.0 / burst,
         (rm / um) if um else 0))
peak = max(loads) if loads else 0.0
if peak > 1.5:
    print("srvwc: .... NOT ATTRIBUTABLE: peak loadavg during the cost arms was "
          "%.2f. Other agents run VM gates on this host; a percentage quoted "
          "without the load it was taken at is not reproducible, so the two "
          "medians above are REPORTED AND NOT COMPARED." % peak)
else:
    print("srvwc: .... ATTRIBUTABLE: peak loadavg during the cost arms was "
          "%.2f." % peak)
PY

echo "srvwc: $pass passed, $fail failed"
[ "$fail" = 0 ]
