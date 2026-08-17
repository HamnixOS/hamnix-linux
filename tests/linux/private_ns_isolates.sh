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
# tests/linux/private_ns_isolates.sh — DOES tests/linux/private_ns.sh ACTUALLY
# KEEP A GATE OFF THE MACHINE IT RUNS ON?
#
# WHY THIS EXISTS
# ===============
# tests/linux/private_ns.sh is a claim: "this gate can no longer touch anything
# outside itself". An isolation fix nobody demonstrated is a claim, not a fix —
# and the thing it is fixing was itself a green gate quietly corrupting other
# people's runs, so "it looks right" is precisely the evidence that failed
# last time.
#
# So this measures it, with the experiment the incident actually was: a SECOND,
# independent desktop, up and running and reading /tmp/hamnix-panel.conf,
# while tests/linux/de_panel_conf_replace.sh runs beside it and replaces that
# same file four times. On the machine, that second desktop was another
# agent's offscreen run; it logged `config reload applied: 2 panel(s)` then
# `1 panel(s)`, lost its top bar, and reported a defect it had not found.
#
# THE WITNESS IS THE INSTRUMENT, SO THE WITNESS IS CALIBRATED
# ===========================================================
# A witness that survives because it cannot feel anything proves nothing. Half
# of this file is therefore a NEGATIVE CONTROL: the same witness, the same
# gate, the same everything, with HAMTEST_NO_PRIVNS=1 — the escape hatch that
# turns the isolation off. There, the witness MUST be hit. If it is not, this
# file is not measuring what it says it measures and it fails and says so.
#
# NOTHING HERE TOUCHES THE MACHINE EITHER
# =======================================
# The negative control deliberately reproduces the contamination, so it is not
# allowed to reproduce it on the host. Both experiments run inside an OUTER
# private mount namespace of their own, made the same way private_ns.sh makes
# one. Inside it:
#
#   experiment A   witness ┐                        the gate makes its own
#                          ├── outer private /tmp   NESTED namespace: no contact
#                  gate    ┘                        expected
#
#   experiment B   witness ┐                        the gate is told not to:
#                          ├── outer private /tmp   both share this /tmp, and
#                  gate    ┘   (HAMTEST_NO_PRIVNS)  contact is expected
#
# Assertion 6 closes the loop by checking the HOST's /tmp gained nothing across
# both — including across the run that was trying to contaminate.
#
# The witness and the gate get separate HAMWSYS/HAMFB paths, so the ONLY thing
# they can possibly share is the panel config. That is the variable under test
# and it is the only one.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"
. tests/linux/private_ns.sh
. tests/linux/reap.sh

pass=0; fail=0
ok()   { echo "isogate: PASS $*"; pass=$((pass+1)); }
bad()  { echo "isogate: FAIL $*"; fail=$((fail+1)); }
info() { echo "isogate: INFO $*"; }
done_report() { echo "isogate: $pass passed, $fail failed"; [ "$fail" = 0 ]; }

# Everything this file makes lives here, outside /tmp, so that the inner
# experiments' private /tmp mounts cannot hide it from us.
BASE="${ISOGATE_BASE:-${HAMLINUX_SCRATCH:-$HOME/.hamnix-build}/isogate.$$}"
mkdir -p "$BASE" || { bad "cannot make $BASE"; done_report; exit 1; }
KEEP="${ISOGATE_KEEP:-0}"
reap_track "$BASE/reaped"
cleanup() { [ "$KEEP" = 1 ] || rm -rf "$BASE"; }
reap_on_exit cleanup

GEOM=1280x800; FBW=1280; FBH=800
[ -r /usr/share/vulkan/icd.d/lvp_icd.json ] && \
    export VK_ICD_FILENAMES="${VK_ICD_FILENAMES:-/usr/share/vulkan/icd.d/lvp_icd.json}"

# ---- 1. the binaries, built ONCE and handed to both sides ------------------
# The gate is then run with PANELCONF_BIN_DIR, which is its own refusal-backed
# way of saying "answer about these bytes, not a fresh build".
BIN="$BASE/bin"; mkdir -p "$BIN"
for t in wsysd:user/wsysd.ad hamdesktop:user/hamdesktop.ad \
         hampanelscene:user/hampanelscene.ad wsys_poke:tests/linux/wsys_poke.ad; do
    name="${t%%:*}"; src="${t#*:}"
    scripts/hamlinux_build.sh "$src" "$BIN/$name" >"$BASE/$name.build.log" 2>&1 || {
        bad "could not build $src"; tail -20 "$BASE/$name.build.log" >&2
        done_report; exit 1; }
done
# de_panel_conf_replace.sh wants its binaries named exactly this in BIN_DIR.
ok "the compositor, the desktop and the panel build once and are shared by the witness and the gate"

# ---- the pixel probe (the same one the gate uses) --------------------------
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

# ---- the experiment, run inside its own outer namespace -------------------
# Written to a file rather than passed as a string so that the thing running
# under unshare is readable, and so a failure names a line.
cat >"$BASE/experiment.sh" <<'EXPERIMENT'
#!/usr/bin/env bash
# $1 = label, $2 = BASE, $3 = "isolated" | "noprivns"
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

# The witness's own compositor, framebuffer and input. Nothing here is shared
# with the gate except the one file under test.
export HAMWSYS="$OUT/wsys.shm" HAMWSYS_BB="$OUT/wsys.bb" HAMWSYS_IMG="$OUT/wsys.img"
export HAMFB_FILE="$OUT/fb.raw" HAMFB_GEOM=1280x800
export HAMWSYSD_INPUT="$OUT/input.evdev"; : >"$HAMWSYSD_INPUT"

# The witness's panel config: two panels, and a marker line that says whose
# file this is. If the gate overwrites it, the marker goes with it.
witness_conf() {
    echo "# THE WITNESS OWNS THIS FILE isogate-tag-${ISOGATE_TAG}"
    cat <<'EOF'
panel top
  edge top
  size 26
  color #d4d0c8
  font normal
  widget menu
  widget launcher /bin/hamtermscene Terminal
  widget spacer
  widget tray
  widget sysmon
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
}
witness_conf >/tmp/hamnix-panel.conf

"$BIN/wsysd" </dev/null >"$OUT/wsysd.log" 2>&1 &  reap_add $!
for _ in $(seq 1 60); do [ -s "$HAMFB_FILE" ] && break; sleep 0.1; done
"$BIN/hamdesktop" </dev/null >"$OUT/hamdesktop.log" 2>&1 &  reap_add $!
sleep 3
"$BIN/hampanelscene" </dev/null >"$OUT/panel.log" 2>&1 &  reap_add $!
sleep 4

winctl() { "$BIN/wsys_poke" "/dev/wsys/$1/ctl" 2>/dev/null; }
# Field 8 of the ctl line is `visible`. This used to default to x, and that
# default TRAVELLED: two unreadable ctl lines became "before vis x x" in the
# log and the consumer below read that as "the witness's panel windows changed
# across the gate's run -- the gate is still reaching outside itself", an
# isolation breach invented out of a failed read. It now emits the literal
# `unread`, which no visible field can ever be, and the consumer says so.
vis_of()  { set -- $(winctl "$1"); echo "${8:-unread}"; }
# Find the witness's own two bars exactly as the gate finds its own.
TOP=""; BOT=""; TOPH=""; BOTH=""; BOTY=0
for wid in $(seq 2 40); do
    line="$(winctl "$wid")"; [ -n "$line" ] || continue
    set -- $line
    [ "${4:-}" = 1280 ] || continue
    [ "${5:-0}" -ge 200 ] && continue
    if [ "${3:-0}" = 0 ]; then TOP="$wid"; TOPH="${5:-}"
    else                       BOT="$wid"; BOTH="${5:-}"; BOTY="${3:-}"; fi
done
say "bars top=$TOP bottom=$BOT"
[ -n "$TOP" ] && [ -n "$BOT" ] || { say "witness-up 0"; exit 0; }
frac() { python3 "$BASE/frac.py" 1280 800 "$@"; }
cp "$HAMFB_FILE" "$OUT/before.raw"
say "witness-up 1"
say "before vis $(vis_of "$TOP") $(vis_of "$BOT")"
say "before botfill $(frac $((1280-300)) $((BOTY+2)) 200 $((BOTH-4)) "$OUT/before.raw" d4d0c8)"
say "before reloads $(grep -ac 'config reload applied' "$OUT/panel.log" 2>/dev/null || true)"

# ---- and now the gate runs beside it -------------------------------------
env_extra=(PANELCONF_TAG="isogate-tag-${ISOGATE_TAG}")
[ "$MODE" = noprivns ] && env_extra+=(HAMTEST_NO_PRIVNS=1)
( env "${env_extra[@]}" PANELCONF_BIN_DIR="$BIN" \
      bash tests/linux/de_panel_conf_replace.sh ) >"$OUT/gate.log" 2>&1
say "gate rc $?"
say "gate score $(grep -a 'passed,' "$OUT/gate.log" | tail -1)"

sleep 3
cp "$HAMFB_FILE" "$OUT/after.raw"
say "after vis $(vis_of "$TOP") $(vis_of "$BOT")"
say "after botfill $(frac $((1280-300)) $((BOTY+2)) 200 $((BOTH-4)) "$OUT/after.raw" d4d0c8)"
say "after reloads $(grep -ac 'config reload applied' "$OUT/panel.log" 2>/dev/null || true)"
if grep -q 'THE WITNESS OWNS THIS FILE' /tmp/hamnix-panel.conf 2>/dev/null; then
    say "marker intact"
else
    say "marker gone"
fi
EXPERIMENT

export PROJ_ROOT
run_experiment() {   # run_experiment <label> <isolated|noprivns>
    local prog; prog="$(priv_ns_mount_prog)"
    nice -n 15 timeout 900 unshare --user --map-root-user --mount -- \
        /usr/bin/env PROJ_ROOT="$PROJ_ROOT" bash -c '
            python3 -c "$1" /tmp /dev/shm /srv || exit 1
            shift 2
            exec bash "$@"
        ' isogate "$prog" -- "$BASE/experiment.sh" "$1" "$BASE" "$2" \
        >"$BASE/$1.outer.log" 2>&1
    # Nothing to reap here: the experiment runs in the foreground and installs
    # reap.sh's own traps, so a `timeout` SIGTERM still takes its desktop down.
}
field() { sed -n "s/^$1 //p" "$BASE/$2/result" 2>/dev/null | tail -1; }

# ---- 2..5. THE REAL THING: the gate, isolated, beside a live desktop ------
export ISOGATE_TAG="$$"
info "running the isolated experiment (a live desktop, and the gate beside it)"
run_experiment isolated isolated
sed 's/^/isogate:      A /' "$BASE/isolated/result" 2>/dev/null

if [ "$(field witness-up isolated)" = 1 ]; then
    ok "the witness desktop came up beside the gate with its own compositor and its own two bars"
else
    bad "the witness desktop never came up -- nothing below can be answered"
    cat "$BASE/isolated.outer.log" 2>/dev/null | tail -20
    done_report; exit 1
fi
ivb="$(field 'before vis' isolated)"; iva="$(field 'after vis' isolated)"
# `unread` is what the witness emits for a ctl line it could not read at all.
# A window it never managed to look at is not a window the gate moved, so this
# says it could not tell rather than reporting a breach it never observed.
case "$ivb $iva" in
    *unread*)
        bad "the witness could not read its OWN panel windows (visible before='$ivb' after='$iva') -- this run cannot tell whether the gate reached outside itself, and nothing here says it did" ;;
    *)
        if [ "$ivb" = "1 1" ] && [ "$iva" = "1 1" ]; then
            ok "through a full run of de_panel_conf_replace.sh the witness's panel windows never moved off screen (visible 1 1 -> 1 1)"
        else
            bad "the witness's panel windows changed across the gate's run ($ivb -> $iva) -- the gate is still reaching outside itself"
        fi ;;
esac
bf="$(field 'before botfill' isolated)"; af="$(field 'after botfill' isolated)"
# The same rule as the visible fields above: a percentage the witness never
# logged is not a taskbar that lost its pixels. `${bf:-0}` made it one.
if [ -z "$bf" ] || [ -z "$af" ]; then
    bad "the witness logged no taskbar fill percentage (before='$bf' after='$af')-- it did not measure its own pixels, so this run cannot say whether they survived"
elif [ "$bf" -ge 60 ] && [ "$af" -ge 60 ]; then
    ok "and in PIXELS the witness's taskbar is painted before and after (${bf}% -> ${af}% of the bar colour) -- not a flag, the framebuffer"
else
    bad "the witness's taskbar lost its pixels across the gate's run (${bf}% -> ${af}%)"
fi
br="$(field 'before reloads' isolated)"; ar="$(field 'after reloads' isolated)"
mk="$(field marker isolated)"
# `${br:-x}` vs `${ar:-y}` made two MISSING reload counts unequal on purpose,
# which sent an unlogged pair straight to "this is the incident reproducing"
# -- the gate's most serious verdict, reached without reading a single count.
if [ -z "$br" ] || [ -z "$ar" ] || [ -z "$mk" ]; then
    bad "the witness logged no reload count or no marker (reloads '$br' -> '$ar', marker '$mk') -- whether it saw the gate's edits is not a question this run can answer, and nothing here says it did"
elif [ "$br" = "$ar" ] && [ "$mk" = intact ]; then
    ok "the witness logged NO further config reload (${br} -> ${ar}) and its own config file still says it owns it -- the gate's four replacements were invisible to it"
else
    bad "the witness saw the gate's edits: reloads ${br} -> ${ar}, marker $mk -- this is the incident reproducing"
fi

# ---- 6+7. THE NEGATIVE CONTROL -------------------------------------------
# Same witness, same gate, isolation switched off. If nothing happens HERE,
# the four assertions above were measured with an instrument that cannot feel
# anything, and they mean nothing.
info "running the negative control (HAMTEST_NO_PRIVNS=1: the gate is told to share)"
run_experiment noprivns noprivns
sed 's/^/isogate:      B /' "$BASE/noprivns/result" 2>/dev/null
nbr="$(field 'before reloads' noprivns)"; nar="$(field 'after reloads' noprivns)"
nvis="$(field 'after vis' noprivns)"; nmark="$(field marker noprivns)"
if [ "$(field witness-up noprivns)" != 1 ]; then
    bad "the control witness never came up -- the calibration is unanswered"
elif [ "${nbr:-x}" != "${nar:-x}" ] || [ "$nmark" = gone ]; then
    ok "CALIBRATION: with the isolation off the same gate DOES reach the same witness (reloads ${nbr} -> ${nar}, config marker ${nmark}, windows $(field 'before vis' noprivns) -> ${nvis}) -- so the four assertions above are measured with an instrument that can feel this"
else
    bad "CALIBRATION FAILED: with the isolation switched OFF the witness still saw nothing (reloads ${nbr} -> ${nar}, marker ${nmark}). This file is not measuring contamination, and its passes above are worth nothing"
fi

# ---- 7. AND NONE OF IT LANDED ON THIS MACHINE ----------------------------
# Identity, not a count. The first version of this assertion counted host
# /tmp/hamnix-* before and after and failed the run — on somebody ELSE's file:
# a concurrent agent's gate had just written /tmp/hamnix-panel.health and
# /tmp/hamnix-panel.conf while this one ran. A count cannot tell whose leak it
# is, and a gate that blames this run for another run's write is answering
# something FAIL-shaped instead of the truth, which is the same sin in the
# other direction. So each experiment stamps a tag nobody else can produce,
# and the question is whether anything carrying THAT tag reached the machine.
# The gate stamps it into every config it writes (PANELCONF_TAG) and the
# witness stamps it into its own, so a hit here is THIS run's leak and a
# concurrent agent's identical file is not mistaken for one.
HOST_WRITESET=(/tmp/hamnix-panel.conf /tmp/hamnix-panel.health /tmp/hamnix-panel.fault
               /tmp/hamnix-panel-drop /tmp/hamnix-notif.log /tmp/hamdesktop-wp.status
               /tmp/.hamdesktop.src /dev/shm/hamnix-wsys /srv/wsys)
MINE="$(grep -sl "isogate-tag-${ISOGATE_TAG}" "${HOST_WRITESET[@]}" 2>/dev/null)"
STRAY="$(ls -d /tmp/panelconf.* 2>/dev/null | head -3)"
if [ -z "$MINE" ] && [ -z "$STRAY" ]; then
    ok "and nothing either experiment wrote reached this machine: none of the desktop's nine fixed host names carries this run's tag, and no panelconf scratch directory was left in the host's /tmp -- including from the control run whose whole job was to contaminate"
else
    bad "LEAKED ONTO THE HOST: $MINE $STRAY"
fi
# Whose /tmp this is, said out loud. Other agents' desktop gates write these
# same fixed names on this machine right now; that is the survey's business,
# not this assertion's, but a run that saw it should say so.
OTHERS="$(ls -A /tmp 2>/dev/null | grep -c '^hamnix-panel\|^hamdesktop-\|^\.hamdesktop' || true)"
[ "$OTHERS" = 0 ] || info "note: ${OTHERS} desktop-owned name(s) are present in this machine's /tmp and were not written by this run -- some other process on this host is writing the desktop's real runtime state"

done_report
