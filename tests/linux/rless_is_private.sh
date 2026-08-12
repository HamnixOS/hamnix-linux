#!/usr/bin/env bash
# tests/linux/rless_is_private.sh — DOES tests/linux/wsyswl_rootless.sh STILL
# REACH THE DESKTOP RUNNING BESIDE IT?
#
# WHY THIS GATE AND NOT ANOTHER
# =============================
# tests/linux/private_ns_isolates.sh proved the helper works, with
# de_panel_conf_replace.sh and the /tmp/hamnix-panel.conf incident. This asks
# the same question of the highest-risk gate in the batch that was still
# unisolated afterwards, and it asks it about that gate's OWN two exposures:
#
#   1. IT STARTS A WHOLE DESKTOP. hamdesktop writes /tmp/.hamdesktop.src and
#      /tmp/hamdesktop-wp.status; hampanelscene writes /tmp/hamnix-panel.health
#      and both read /tmp/hamnix-panel-drop. Every one of those names is
#      compiled into the binary (user/hamdesktop.ad:1114, :509,
#      user/hampanelscene.ad:240, :4376) and is ONE PER MACHINE.
#
#   2. IT RUNS AN X SERVER. It picks a display number by looking in
#      /tmp/.X11-unix and binds a socket there. That is the host's X socket
#      directory: on a machine with a real session, a display-number collision
#      is a collision with somebody's actual X server.
#
# So the witness is a full desktop with its OWN compositor segment and its own
# framebuffer -- the only things it can share with the gate are those fixed
# names and that directory, which is exactly the variable under test.
#
# THE WITNESS IS THE INSTRUMENT, SO THE WITNESS IS CALIBRATED
# ===========================================================
# Half of this file is the NEGATIVE CONTROL: the same witness, the same gate,
# HAMTEST_NO_PRIVNS=1. There the witness MUST be reached, in the same three
# ways it is asserted not to be above. A witness that survives because it
# cannot feel anything proves nothing, and that failure mode is the whole
# reason this line of work exists.
#
# NOTHING HERE TOUCHES THE MACHINE EITHER
# =======================================
# The control deliberately reproduces the contamination, so it is not allowed
# to reproduce it on the host. Both experiments run inside an OUTER private
# mount namespace of their own, made the way private_ns.sh makes one, so the
# /tmp they fight over is the experiment's. The last assertion checks that by
# IDENTITY -- each experiment stamps a name nobody else can produce, and the
# question is whether anything carrying that name reached this machine. A
# count could not tell this run's leak from a concurrent agent's identical
# file, and blaming this run for somebody else's write would be answering
# something FAIL-shaped instead of the truth.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"
. tests/linux/private_ns.sh
. tests/linux/reap.sh

pass=0; fail=0
ok()   { echo "rlpriv: PASS $*"; pass=$((pass+1)); }
bad()  { echo "rlpriv: FAIL $*"; fail=$((fail+1)); }
info() { echo "rlpriv: INFO $*"; }
done_report() { echo "rlpriv: $pass passed, $fail failed"; [ "$fail" = 0 ]; }

# Outside /tmp, so the inner experiments' private /tmp cannot hide it from us.
BASE="${RLPRIV_BASE:-${HAMLINUX_SCRATCH:-$HOME/.hamnix-build}/rlpriv.$$}"
mkdir -p "$BASE" || { bad "cannot make $BASE"; done_report; exit 1; }
KEEP="${RLPRIV_KEEP:-0}"
reap_track "$BASE/reaped"
cleanup() { [ "$KEEP" = 1 ] || rm -rf "$BASE"; }
reap_on_exit cleanup

[ -r /usr/share/vulkan/icd.d/lvp_icd.json ] && \
    export VK_ICD_FILENAMES="${VK_ICD_FILENAMES:-/usr/share/vulkan/icd.d/lvp_icd.json}"

# ---- 1. the witness's binaries, built once -------------------------------
BIN="$BASE/bin"; mkdir -p "$BIN"
for t in wsysd:user/wsysd.ad hamdesktop:user/hamdesktop.ad \
         hampanelscene:user/hampanelscene.ad wsys_poke:tests/linux/wsys_poke.ad; do
    name="${t%%:*}"; src="${t#*:}"
    scripts/hamlinux_build.sh "$src" "$BIN/$name" >"$BASE/$name.build.log" 2>&1 || {
        bad "could not build $src"; tail -20 "$BASE/$name.build.log" >&2
        done_report; exit 1; }
done
ok "the witness desktop -- compositor, desktop and panel -- builds once and is shared by both experiments"

cat >"$BASE/frac.py" <<'PY'
import sys
W, H = int(sys.argv[1]), int(sys.argv[2])
x, y, w, h = (int(v) for v in sys.argv[3:7])
d = open(sys.argv[7], 'rb').read()
c = sys.argv[8]
want = (int(c[0:2], 16), int(c[2:4], 16), int(c[4:6], 16))
tot = hit = 0
for j in range(y, min(y + h, H), 2):
    row = j * W * 4
    for i in range(x, min(x + w, W), 2):
        o = row + i * 4
        tot += 1
        if (d[o+2], d[o+1], d[o]) == want:
            hit += 1
print(0 if tot == 0 else hit * 100 // tot)
PY

cat >"$BASE/experiment.sh" <<'EXPERIMENT'
#!/usr/bin/env bash
# $1 = label, $2 = BASE, $3 = isolated|noprivns
set -uo pipefail
LABEL="$1"; BASE="$2"; MODE="$3"
cd "$PROJ_ROOT"
. tests/linux/reap.sh
OUT="$BASE/$LABEL"; mkdir -p "$OUT"
reap_track "$OUT/reaped"
reap_on_exit
BIN="$BASE/bin"
say() { echo "$*" >>"$OUT/result"; }
: >"$OUT/result"

# The witness's own compositor, backbuffer, image segment and framebuffer.
# Nothing here is shared with the gate except the fixed /tmp names and the X
# socket directory, which are the variables under test.
export HAMWSYS="$OUT/wsys.shm" HAMWSYS_BB="$OUT/wsys.bb" HAMWSYS_IMG="$OUT/wsys.img"
export HAMFB_FILE="$OUT/fb.raw" HAMFB_GEOM=1280x800
export HAMWSYSD_INPUT="$OUT/input.evdev"; : >"$HAMWSYSD_INPUT"

# The witness's panel config, with a colour the pixel probe can look for.
cat >/tmp/hamnix-panel.conf <<'EOF'
panel top
  edge top
  size 26
  color #d4d0c8
  font normal
  widget menu
  widget spacer
  widget clock
end
panel bottom
  edge bottom
  size 26
  color #d4d0c8
  font normal
  widget tasks
  widget pager
end
EOF

"$BIN/wsysd" </dev/null >"$OUT/wsysd.log" 2>&1 &  reap_add $!
for _ in $(seq 1 80); do [ -s "$HAMFB_FILE" ] && break; sleep 0.1; done
"$BIN/hamdesktop" </dev/null >"$OUT/hamdesktop.log" 2>&1 &  reap_add $!
sleep 3
"$BIN/hampanelscene" </dev/null >"$OUT/panel.log" 2>&1 &  reap_add $!
sleep 5

winctl() { "$BIN/wsys_poke" "/dev/wsys/$1/ctl" 2>/dev/null; }
vis_of() { set -- $(winctl "$1"); echo "${8:-x}"; }
TOP=""; BOT=""; BOTH=""; BOTY=0
for wid in $(seq 2 40); do
    line="$(winctl "$wid")"; [ -n "$line" ] || continue
    set -- $line
    [ "${4:-}" = 1280 ] || continue
    [ "${5:-0}" -ge 200 ] && continue
    if [ "${3:-0}" = 0 ]; then TOP="$wid"
    else                       BOT="$wid"; BOTH="${5:-}"; BOTY="${3:-}"; fi
done
say "bars top=$TOP bottom=$BOT"
[ -n "$TOP" ] && [ -n "$BOT" ] || { say "witness-up 0"; exit 0; }
say "witness-up 1"
frac() { python3 "$BASE/frac.py" 1280 800 "$@"; }

# THE MARKER. The witness's own hamdesktop wrote /tmp/.hamdesktop.src at
# startup; this stamps it as the witness's. Only another hamdesktop rewrites
# it, so losing it means a second desktop reached this one's runtime state.
echo "WITNESS-OWNS-${RLPRIV_TAG}" >/tmp/.hamdesktop.src
# And the stamp for assertion 6, beside the names the gate would write.
: >"/tmp/rlpriv-${RLPRIV_TAG}"

mkdir -p /tmp/.X11-unix
say "before xsockets $(ls -A /tmp/.X11-unix 2>/dev/null | wc -l)"
cp "$HAMFB_FILE" "$OUT/before.raw"
say "before vis $(vis_of "$TOP") $(vis_of "$BOT")"
say "before botfill $(frac $((1280-300)) $((BOTY+2)) 200 $((BOTH-4)) "$OUT/before.raw" d4d0c8)"

# THE X SOCKET DIRECTORY HAS TO BE SAMPLED WHILE THE GATE IS ALIVE, not after.
# The gate kills its own X servers on the way out and the sockets go with them,
# so a before/after pair reads 0 -> 0 whether it shared the directory or not --
# an instrument that cannot feel the thing it is pointed at. This keeps the
# HIGHEST count seen during the run, which is the moment that matters: while
# the gate's Xwayland is bound, is it bound in the witness's directory?
XMAX="$OUT/xmax"; echo "$(ls -A /tmp/.X11-unix 2>/dev/null | wc -l)" >"$XMAX"
( while :; do
      n="$(ls -A /tmp/.X11-unix 2>/dev/null | wc -l)"
      [ "$n" -gt "$(cat "$XMAX")" ] && echo "$n" >"$XMAX"
      sleep 1
  done ) & SAMPLER=$!; reap_add "$SAMPLER"

# ---- and now the gate runs beside it -------------------------------------
env_extra=(RLESS_WORK="$OUT/rlesswork")
[ "$MODE" = noprivns ] && env_extra+=(HAMTEST_NO_PRIVNS=1)
( env "${env_extra[@]}" bash tests/linux/wsyswl_rootless.sh ) >"$OUT/gate.log" 2>&1
say "gate rc $?"
say "gate score $(grep -a 'passed,' "$OUT/gate.log" | tail -1)"
kill "$SAMPLER" 2>/dev/null
say "peak xsockets $(cat "$XMAX" 2>/dev/null)"

sleep 3
cp "$HAMFB_FILE" "$OUT/after.raw"
say "after xsockets $(ls -A /tmp/.X11-unix 2>/dev/null | wc -l)"
say "after vis $(vis_of "$TOP") $(vis_of "$BOT")"
say "after botfill $(frac $((1280-300)) $((BOTY+2)) 200 $((BOTH-4)) "$OUT/after.raw" d4d0c8)"
if grep -q "WITNESS-OWNS-${RLPRIV_TAG}" /tmp/.hamdesktop.src 2>/dev/null; then
    say "marker intact"
else
    say "marker gone"
fi
EXPERIMENT

export PROJ_ROOT
export RLPRIV_TAG="$$"
run_experiment() {   # <label> <isolated|noprivns>
    local prog; prog="$(priv_ns_mount_prog)"
    local mapargs=(--map-root-user)
    unshare --user --map-root-user --map-auto --mount true 2>/dev/null && \
        mapargs+=(--map-auto)
    nice -n 15 timeout 3600 unshare --user "${mapargs[@]}" --mount -- \
        /usr/bin/env PROJ_ROOT="$PROJ_ROOT" RLPRIV_TAG="$RLPRIV_TAG" bash -c '
            python3 -c "$1" /tmp /dev/shm /srv || exit 1
            shift 2
            exec bash "$@"
        ' rlpriv "$prog" -- "$BASE/experiment.sh" "$1" "$BASE" "$2" \
        >"$BASE/$1.outer.log" 2>&1
}
field() { sed -n "s/^$1 //p" "$BASE/$2/result" 2>/dev/null | tail -1; }

# ---- 2..5. THE REAL THING ------------------------------------------------
info "running the isolated experiment (a live desktop, and wsyswl_rootless.sh beside it)"
run_experiment isolated isolated
sed 's/^/rlpriv:      A /' "$BASE/isolated/result" 2>/dev/null

if [ "$(field witness-up isolated)" = 1 ]; then
    ok "the witness desktop came up beside the gate with its own compositor and its own two bars"
else
    bad "the witness desktop never came up -- nothing below can be answered"
    tail -20 "$BASE/isolated.outer.log" 2>/dev/null
    done_report; exit 1
fi
if [ "$(field marker isolated)" = intact ]; then
    ok "through a full run of wsyswl_rootless.sh the witness's /tmp/.hamdesktop.src still says the witness owns it -- the gate's hamdesktop wrote a different file of that name"
else
    bad "the gate's desktop overwrote /tmp/.hamdesktop.src -- this is the incident reproducing"
fi
bx="$(field 'before xsockets' isolated)"; px="$(field 'peak xsockets' isolated)"
if [ "${bx:-x}" = "${px:-y}" ]; then
    ok "and /tmp/.X11-unix never gained a socket AT ANY POINT WHILE THE GATE RAN (peak ${px}, from ${bx}) -- its Xwayland bound a display number in a directory that was not this one's"
else
    bad "the gate's X server appeared in the witness's /tmp/.X11-unix (${bx} -> peak ${px}) -- on a machine with a real session that is a real display"
fi
if [ "$(field 'before vis' isolated)" = "1 1" ] && [ "$(field 'after vis' isolated)" = "1 1" ]; then
    ok "the witness's panel windows never moved off screen (visible 1 1 -> 1 1)"
else
    bad "the witness's panel windows changed ($(field 'before vis' isolated) -> $(field 'after vis' isolated))"
fi
bf="$(field 'before botfill' isolated)"; af="$(field 'after botfill' isolated)"
if [ "${bf:-0}" -ge 60 ] && [ "${af:-0}" -ge 60 ]; then
    ok "and in PIXELS its taskbar is painted before and after (${bf}% -> ${af}% of the bar colour) -- the framebuffer, not a flag"
else
    info "taskbar pixels ${bf}% -> ${af}% (not asserted: the bar colour depends on the config this witness wrote)"
fi

# ---- 6. THE NEGATIVE CONTROL ---------------------------------------------
info "running the negative control (HAMTEST_NO_PRIVNS=1: the gate is told to share)"
run_experiment noprivns noprivns
sed 's/^/rlpriv:      B /' "$BASE/noprivns/result" 2>/dev/null
nmark="$(field marker noprivns)"
nbx="$(field 'before xsockets' noprivns)"; npx="$(field 'peak xsockets' noprivns)"
if [ "$(field witness-up noprivns)" != 1 ]; then
    bad "the control witness never came up -- the calibration is unanswered"
elif [ "$nmark" = gone ] && [ "${npx:-0}" -gt "${nbx:-0}" ]; then
    ok "CALIBRATION: with the isolation off the same gate reaches the same witness BOTH WAYS -- it overwrote /tmp/.hamdesktop.src (marker ${nmark}) and its X server appeared in the witness's /tmp/.X11-unix (${nbx} -> peak ${npx}) -- so both assertions above are measured with instruments that can feel this"
elif [ "$nmark" = gone ] || [ "${npx:-0}" -gt "${nbx:-0}" ]; then
    bad "CALIBRATION IS ONLY HALF THERE: marker ${nmark}, X sockets ${nbx} -> peak ${npx}. One of the two assertions above is being made with an instrument this control has NOT shown can feel anything, and it should not be read as evidence"
else
    bad "CALIBRATION FAILED: with the isolation switched OFF the witness still saw nothing (marker ${nmark}, X sockets ${nbx} -> peak ${npx}). This file is not measuring contamination and its passes above are worth nothing"
fi

# ---- 7. AND NONE OF IT LANDED ON THIS MACHINE ----------------------------
MINE="$(ls -d "/tmp/rlpriv-${RLPRIV_TAG}" 2>/dev/null; \
        grep -sl "WITNESS-OWNS-${RLPRIV_TAG}" /tmp/.hamdesktop.src 2>/dev/null)"
STRAY="$(ls -d /tmp/rless.* 2>/dev/null | head -3)"
if [ -z "$MINE" ] && [ -z "$STRAY" ]; then
    ok "and nothing either experiment wrote reached this machine: neither this run's stamp nor its marker is in the host's /tmp, and no rless scratch directory was left there -- including from the control run, whose whole job was to contaminate"
else
    bad "LEAKED ONTO THE HOST: $MINE $STRAY"
fi
OTHERS="$(ls -A /tmp 2>/dev/null | grep -c '^hamnix-panel\|^hamdesktop-\|^\.hamdesktop' || true)"
[ "$OTHERS" = 0 ] || info "note: ${OTHERS} desktop-owned name(s) are in this machine's /tmp and were not written by this run -- some other process on this host owns the desktop's real runtime state, which is what the gate used to be writing into"

done_report
