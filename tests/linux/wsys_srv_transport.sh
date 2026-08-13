#!/usr/bin/env bash
# wsys_srv_transport.sh — STAGE 1 OF THE MEDIATOR: THERE IS A BOUNDARY TO
# TALK ACROSS, AND CROSSING IT CHANGES NOTHING YET.
#
# docs/wsys_server_design.md orders the work: (1) the server loop and the
# client transport behind HAMWSYS_SERVER=1, (2) mutations, (3) reads and the
# enumeration policy that turns tests/linux/wsys_enum_policy.sh green, (4) the
# WSYS_VERSION bump, LAST. This gate is stage 1's, and stage 1 alone. It does
# NOT assert that any /dev/wsys operation is mediated -- none is yet, and a
# gate that claimed otherwise would be green for a boundary that does not
# exist.
#
# WHAT IT ASSERTS
# ===============
#   A. THE INSTRUMENT FIRST. With HAMWSYS_SERVER unset the probe must FAIL to
#      reach a server. If it passed with the flag unset it would be measuring
#      something other than the transport, and every result below would be
#      worthless. "It works" and "the test cannot tell" are opposite findings
#      and a careless grep reads them the same way.
#   B. With the flag set, a client that opens /dev/wsys dials the server,
#      negotiates a version, gets a blocking round trip answered, and -- this
#      is the half that is easy to omit -- sends a burst of FIRE-AND-FORGET
#      messages and then asks the SERVER'S OWN COUNTERS how many arrived. A
#      transport that drops every fire-and-forget message looks perfect from
#      the sending end.
#   C. BEHAVIOUR IS UNCHANGED WITH THE FLAG UNSET. No socket is bound, and
#      /dev/wsys answers byte-for-byte what it answered before.
#   D. PIXELS DO NOT CROSS. The design costs 0.12% of a core instead of
#      megabytes a frame because per-window memfds are handed up from the
#      owner and never travel as messages. That is a precondition stages 2
#      and 3 must not break, so it is measured here rather than assumed: a
#      real dragging client's op census must show ZERO backbuffer writes while
#      showing plenty of other traffic.
#   E. THE COST, against a budget with A FIXED TERM AND A MARGINAL ONE rather
#      than the single percentage per rate the design carried. The design's
#      figures (0.12% at idle, 0.38% on a drag, 1.27% at the worst load) were
#      `ops/s x per-op` and so passed through the origin; the measured cost
#      does not, because the WAKE does not depend on the rate. Four rates,
#      three samples each, median, every sample printed, /proc/<pid>/stat
#      deltas over a fixed interval -- never `ps pcpu`, which is a lifetime
#      average and would report an idle server that spun for its first second
#      as idle. See THE BUDGET, RE-DERIVED below for the whole argument.
#
# Offscreen, software, no ICD, private namespace. The owner's desktop is
# running and this must not touch it.
set -uo pipefail
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ"

# A fresh /tmp and a private mount namespace BEFORE anything makes a file.
. tests/linux/private_ns.sh
priv_ns_reexec "$@"

. tests/linux/reap.sh

# The work directory is deliberately NOT under /tmp: priv_ns_reexec has just
# replaced /tmp with a fresh tmpfs, and a build that landed there would be
# gone. It is also not under the source tree, which is read-only here.
# THE DEFAULT IS PER-RUN, and that is not tidiness. It used to be the single
# fixed path /home/david/.hamnix-build/wsrv-s1, and $BIN below is "$OUT/bin":
# two agents running this gate at the same time COMPILED INTO THE SAME bin/,
# each overwriting the wsysd the other was about to measure. $W was already
# per-run, which made the collision look handled when the part that mattered
# -- the binaries under test -- was shared.
#
# SRV_WORK still pins it, which is how you reuse a build across runs instead
# of paying for the compile again.
SCRATCH_BASE="${SRV_SCRATCH_BASE:-/home/david/.hamnix-build}"
if [ -n "${SRV_WORK:-}" ]; then
    OUT="$SRV_WORK"; OUT_EPHEMERAL=0
    mkdir -p "$OUT" || { echo "srvtr: FAIL cannot make $OUT"; exit 1; }
else
    mkdir -p "$SCRATCH_BASE" || { echo "srvtr: FAIL cannot make $SCRATCH_BASE"; exit 1; }
    OUT="$(mktemp -d "$SCRATCH_BASE/wsrv-s1.XXXXXX")" || {
        echo "srvtr: FAIL cannot make a scratch dir under $SCRATCH_BASE"; exit 1; }
    OUT_EPHEMERAL=1
fi
W="$OUT/run.$$"
mkdir -p "$W" || { echo "srvtr: FAIL cannot make $W"; exit 1; }
reap_track "$W/reaped"
KEEP="${SRV_KEEP:-0}"
cleanup(){
    [ "$KEEP" = 1 ] && return 0
    rm -rf "$W"
    [ "$OUT_EPHEMERAL" = 1 ] && rm -rf "$OUT"
    return 0
}
reap_on_exit cleanup

pass=0; fail=0
ok(){  echo "srvtr: PASS $*"; pass=$((pass+1)); }
bad(){ echo "srvtr: FAIL $*"; fail=$((fail+1)); }
note(){ echo "srvtr: .... $*"; }

# ---------------------------------------------------------------- build ----
BIN="$OUT/bin"
mkdir -p "$BIN"
# The compiler is a BUILT ARTIFACT and a worktree may not have one; it is also
# tree-independent (it compiles .ad, it does not carry this tree's window
# system). So an explicitly supplied one wins, then this tree's, then the
# checkout this worktree was cut from.
for c in "${ADDER_HOST_AC:-}" \
         "$PROJ/build/cutover/host_ac_llvm.elf" "$PROJ/build/cutover/host_ac.elf" \
         "$(git -C "$PROJ" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/../build/cutover/host_ac_llvm.elf" \
         "$(git -C "$PROJ" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/../build/cutover/host_ac.elf"; do
    [ -n "$c" ] && [ -x "$c" ] && { ADDER_HOST_AC="$c"; break; }
done
[ -n "${ADDER_HOST_AC:-}" ] && [ -x "$ADDER_HOST_AC" ] || {
    echo "srvtr: FAIL no host_ac.elf to build with (set ADDER_HOST_AC)"; exit 1; }
export ADDER_HOST_AC
note(){ echo "srvtr: .... $*"; }
note "compiler: $ADDER_HOST_AC"

build(){ # build <src.ad> <name>
    local src="$1" name="$2"
    scripts/hamlinux_build.sh "$src" "$BIN/$name" >"$W/build.$name.log" 2>&1 || {
        echo "srvtr: FAIL could not build $src -- see $W/build.$name.log"
        tail -5 "$W/build.$name.log"
        return 1; }
    return 0
}
# `cat` is built too, and it is not a convenience. /dev/wsys is a path inside
# the Hamnix syscall runtime, not a file the host kernel knows about, so the
# host's /bin/cat reads NOTHING from it -- and an empty read is the exact
# shape of a comparison that passes for the wrong reason.
for t in wsysd:user/wsysd.ad \
         wsys_srv_probe:tests/linux/wsys_srv_probe.ad \
         cat:user/cat.ad \
         de_dragload:tests/linux/de_dragload.ad; do
    build "${t#*:}" "${t%%:*}" || exit 1
done
note "built wsysd, wsys_srv_probe, cat and de_dragload from this tree into $BIN"

# ------------------------------------------------------------ environment ---
mkdir -p "$W/noicd"
export HAMWSYS="$W/seg" HAMWSYS_BB="$W/bb" HAMWSYS_IMG="$W/img"
export HAMFB_FILE="$W/fb.raw" HAMFB_GEOM=1280x800
: >"$W/in"; export HAMWSYSD_INPUT="$W/in"
# wsysd arms a REAL Vulkan backend on real silicon. The display belongs to the
# machine owner; point the loader at a file that is not there.
export VK_ICD_FILENAMES="$W/noicd/none.json"
export HAMLINUX_VNC=none

start_wsysd(){ # start_wsysd <tag> [env assignments...]  -> echoes the pid
    local tag="$1"; shift
    rm -f "$HAMWSYS" "$HAMWSYS.chrome" "$HAMWSYS_BB" "$HAMFB_FILE"
    env "$@" "$BIN/wsysd" </dev/null >"$W/wsysd.$tag.log" 2>&1 &
    local p=$!
    reap_add "$p"
    local i
    for i in $(seq 1 100); do [ -s "$HAMFB_FILE" ] && break; sleep 0.1; done
    echo "$p"
}
stop_wsysd(){ # stop_wsysd <pid> -- BY EXACT PID. Never by pattern: `pgrep -f`
              # matching its own command line has produced a wrong answer seven
              # times in this project.
    kill "$1" 2>/dev/null
    wait "$1" 2>/dev/null
}

# ==================================================================
# A. THE INSTRUMENT PROVES ITSELF: no flag, no transport.
# ==================================================================
WP="$(start_wsysd off)"
if ! [ -s "$HAMFB_FILE" ]; then
    bad "wsysd produced no framebuffer with the flag unset -- nothing below can mean anything"
    echo "srvtr: $pass passed, $fail failed"; exit 1
fi
ok "wsysd runs with HAMWSYS_SERVER unset"

"$BIN/wsys_srv_probe" >"$W/probe.off.out" 2>"$W/probe.off.err"; RC_OFF=$?
sed 's/^/srvtr:      /' "$W/probe.off.err" | head -4
if [ "$RC_OFF" = 0 ]; then
    bad "the probe reported SUCCESS with HAMWSYS_SERVER unset. It is not measuring the transport, so every result below would be meaningless. Refusing to report anything as proven."
    stop_wsysd "$WP"
    echo "srvtr: $pass passed, $fail failed"; exit 1
fi
ok "with the flag unset the probe cannot reach a server (rc=$RC_OFF) -- a success below will mean the transport, and not the probe"

# ------- C(i). No socket is bound when the flag is unset.
# INDEPENDENTLY CONFIRMED, and worth recording because the two observations
# bound the problem: this defect was found twice on the same day, by two agents
# who each saw it from a different side. One counted 21 foreign names bound
# during a single run; the other watched this arm go red while its own
# segment had NO srv name at all and three foreign ones were bound. Same
# cause, and the fix below is the one that landed.
# SCOPED TO THIS RUN'S SEGMENT, and that is not tidiness. The abstract name is
# "hamnix-wsys/<dev>.<ino>/srv" and /proc/net/unix IS HOST-WIDE: a wildcard here
# reads every wsysd on the machine, so any other gate, agent or leftover
# compositor serving ITS OWN segment failed this arm and the failure said "the
# flag does not gate the server". Observed: 21 such names bound by other
# processes during one run. The segment this gate created is the only one whose
# absence proves anything about the flag.
SEGNAME="$(stat -c '%d.%i' "$HAMWSYS" 2>/dev/null || echo none)"
if [ "$SEGNAME" = none ]; then
    bad "cannot identify this run's segment ($HAMWSYS), so 'no socket is bound' cannot be told from 'no socket was looked for'"
elif grep -q "hamnix-wsys/$SEGNAME/srv" /proc/net/unix 2>/dev/null; then
    bad "an abstract socket named hamnix-wsys/$SEGNAME/srv is bound with HAMWSYS_SERVER unset -- the flag does not gate the server"
else
    ok "no server socket is bound for this run's segment ($SEGNAME) with the flag unset"
fi

# ------- C(ii). Record what /dev/wsys answers, to compare against later.
"$BIN/wsys_srv_probe" >/dev/null 2>&1
"$BIN/de_dragload" 300 200 100 100 60 4 >"$W/wid.off" 2>"$W/drag.off.log" &
DP=$!; reap_add "$DP"
sleep 2
"$BIN/cat" /dev/wsys/windows >"$W/windows.off" 2>/dev/null || true
kill "$DP" 2>/dev/null; wait "$DP" 2>/dev/null
stop_wsysd "$WP"

# ==================================================================
# E(i). IDLE COST, FLAG OFF -- the baseline the budget is measured against.
# ==================================================================
# /proc/<pid>/stat fields 14 and 15 are utime and stime in clock ticks. The
# delta over a known wall interval is what a percentage of a core means. `ps
# pcpu` is a LIFETIME average and would hide exactly the regression that
# matters: a server that spun for one second and then settled.
HZ="$(getconf CLK_TCK 2>/dev/null || echo 100)"

# THE SAMPLE WINDOW IS SET BY THE BUDGET, NOT BY PATIENCE, and the first run
# of this gate got that wrong and had to be told.
#
# /proc/<pid>/stat counts in CLOCK TICKS. At CLK_TCK=100 one tick is 10 ms, so
# over a 5 s window the SMALLEST NON-ZERO ANSWER THE INSTRUMENT CAN GIVE is
# 1 tick / 5 s = 0.20% of a core. The budget being tested is 0.12%. The first
# run duly reported "0.20% of a core, over the 0.12% budget" for a build whose
# server is a stub that never runs -- it was reading one tick of quantisation
# and calling it mediation.
#
# So the window is chosen so that one tick is comfortably below the tightest
# budget: at 40 s a tick is 0.025% of a core, and 0.12% is about five ticks.
# SRV_WIN shortens it for a smoke run, and the guard below refuses to call a
# sub-quantum delta a pass either way -- a number the instrument cannot
# resolve is not a measurement, in either direction.
WIN="${SRV_WIN:-40}"
QUANT="$(awk -v hz="$HZ" -v s="$WIN" 'BEGIN{printf "%.3f", 100.0/(hz*s)}')"
note "CPU instrument: /proc/<pid>/stat utime+stime, CLK_TCK=$HZ, ${WIN}s windows -> one tick = $QUANT% of a core"
if awk -v q="$QUANT" 'BEGIN{exit !(q > 0.06)}'; then
    note "WARNING: one tick is $QUANT% of a core, which is more than half the 0.12% idle budget. Raise SRV_WIN."
fi

cpu_pct(){ # cpu_pct <pid> <seconds> -> percent of one core, 2 decimals
    local p="$1" s="$2" a b
    a="$(awk '{print $14+$15}' "/proc/$p/stat" 2>/dev/null)" || return 1
    sleep "$s"
    b="$(awk '{print $14+$15}' "/proc/$p/stat" 2>/dev/null)" || return 1
    awk -v a="$a" -v b="$b" -v s="$s" -v hz="$HZ" \
        'BEGIN{printf "%.2f", (b-a)*100.0/(hz*s)}'
}
median3(){ printf '%s\n' "$1" "$2" "$3" | sort -g | sed -n 2p; }

# within_budget <delta> <budget> <label>. A delta smaller than one tick is
# reported as "below what this instrument can resolve" rather than as a pass:
# saying 0.00% when the instrument's floor is 0.025% is a claim the run did
# not earn.
within_budget(){
    local d="$1" b="$2" label="$3"
    if awk -v x="$d" -v y="$b" 'BEGIN{exit !(x <= y)}'; then
        if awk -v x="$d" -v q="$QUANT" 'BEGIN{exit !(x < q)}'; then
            ok "$label mediation is below this instrument's resolution ($QUANT% of a core); it is under the $b% budget, and $b% is all that can be claimed"
        else
            ok "$label mediation costs $d% of a core, within the $b% budget"
        fi
    else
        bad "$label mediation costs $d% of a core, over the $b% budget"
    fi
}

measure_idle(){ # measure_idle <tag> [env...] -> echoes "s1 s2 s3 median"
    local tag="$1"; shift
    local p s1 s2 s3
    p="$(start_wsysd "$tag" "$@")"
    sleep 2                      # let the first frame and the mode probe settle
    s1="$(cpu_pct "$p" "$WIN")"; s2="$(cpu_pct "$p" "$WIN")"; s3="$(cpu_pct "$p" "$WIN")"
    stop_wsysd "$p"
    echo "$s1 $s2 $s3 $(median3 "$s1" "$s2" "$s3")"
}

read -r O1 O2 O3 OMED <<<"$(measure_idle idle_off)"
note "idle CPU, HAMWSYS_SERVER unset: samples $O1% $O2% $O3% -> median $OMED% of a core"

# ==================================================================
# B. THE TRANSPORT, WITH THE FLAG SET.
# ==================================================================
WP="$(start_wsysd on HAMWSYS_SERVER=1)"
if ! [ -s "$HAMFB_FILE" ]; then
    bad "wsysd produced no framebuffer with HAMWSYS_SERVER=1 -- the flag broke the compositor"
    echo "srvtr: $pass passed, $fail failed"; exit 1
fi
ok "wsysd runs with HAMWSYS_SERVER=1"

# SCOPED, for the same reason the unset arm above is: a wildcard over host-wide
# /proc/net/unix would be GREEN because of somebody else's compositor, which is
# the worse direction of the same mistake.
SEGNAME="$(stat -c '%d.%i' "$HAMWSYS" 2>/dev/null || echo none)"
if [ "$SEGNAME" != none ] && grep -q "hamnix-wsys/$SEGNAME/srv" /proc/net/unix 2>/dev/null; then
    ok "the server bound the abstract name for THIS run's segment ($SEGNAME), visible in /proc/net/unix"
else
    bad "HAMWSYS_SERVER=1 but no hamnix-wsys/$SEGNAME/srv socket is bound -- there is nothing to dial"
fi

HAMWSYS_SERVER=1 "$BIN/wsys_srv_probe" >"$W/probe.on.out" 2>"$W/probe.on.err"
RC_ON=$?
sed 's/^/srvtr:      /' "$W/probe.on.out" | head -20
sed 's/^/srvtr:      /' "$W/probe.on.err" | head -20
if [ "$RC_ON" = 0 ]; then
    ok "the transport works: handshake, blocking round trip, and a fire-and-forget burst the SERVER confirms it received"
else
    bad "the probe reported $RC_ON failures with HAMWSYS_SERVER=1"
fi

# ------- B(ii). WHAT A BLOCKING REQUEST COSTS WHEN THE COMPOSITOR IS BUSY.
#
# THE DESIGN'S 6.30 us DOES NOT APPLY TO THIS SERVER, and the difference is
# structural rather than a matter of tuning. tests/linux/wsys_rtt_probe.c
# measured a dedicated server thread whose only job was to read the socket.
# This server is serviced from wsysd's frame loop, so a blocking request waits
# for wsysd to come round -- and when wsysd is rasterizing a drag, "come round"
# means "after this frame". Measured idle the round trip is ~46 us; under a
# dragging client the tail runs to ~850 us, which is nearly three times the
# whole published 0.3 ms input-to-pixel budget.
#
# That is a constraint on STAGE 3, not a defect in stage 1 -- nothing is routed
# yet -- but it is measured here so that stage 3 cannot discover it by shipping
# a taskbar that stalls. Fire-and-forget is unaffected and does not wait, which
# is the design's first rule and is now evidence rather than intuition.
"$BIN/de_dragload" 300 200 100 100 60 4 >"$W/wid.on" 2>"$W/drag.on.log" &
DP=$!; reap_add "$DP"
sleep 2
HAMWSYS_SERVER=1 "$BIN/wsys_srv_probe" >"$W/probe.load.out" 2>&1
grep -E 'round trip|every sample|fire-and-forget:' "$W/probe.load.out" \
    | sed 's/^/srvtr:      /'
RTT_P50="$(sed -n 's/.*round trip, [0-9]* samples: min [0-9]*  p50 \([0-9]*\).*/\1/p' "$W/probe.load.out" | head -1)"
RTT_MAX="$(sed -n 's/.*round trip, .*max \([0-9]*\) us/\1/p' "$W/probe.load.out" | head -1)"
FF_US="$(sed -n 's/.*fire-and-forget: [0-9]* sent in [0-9]* us (\([0-9.]*\) us\/op.*/\1/p' "$W/probe.load.out" | head -1)"

if [ -z "${FF_US:-}" ]; then
    bad "could not read a fire-and-forget cost out of the probe -- the instrument did not report, so nothing below it can be claimed"
elif awk -v x="$FF_US" 'BEGIN{exit !(x <= 2.3)}'; then
    ok "under a dragging load a fire-and-forget op costs $FF_US us, at or under the 2.3 us the census saturates at -- the rule that mutations do not wait is what holds the budget"
else
    bad "a fire-and-forget op costs $FF_US us under load, over the 2.3 us saturation figure the budget is built on"
fi

if [ -z "${RTT_P50:-}" ]; then
    bad "the probe reported no blocking round-trip distribution"
elif [ "$RTT_P50" -le 300 ]; then
    ok "under a dragging load a BLOCKING request is ${RTT_P50} us at p50, within the 0.3 ms input-to-pixel budget"
else
    bad "a blocking request is ${RTT_P50} us at p50 under load -- one mediated op would exceed the whole 0.3 ms input-to-pixel budget"
fi
note "RECORDED FOR STAGE 3, not asserted: the blocking tail reaches ${RTT_MAX:-?} us under a dragging load, because a request serviced from the frame loop waits for the frame. newwindow and version negotiation happen once per window and can afford it; a taskbar re-reading /dev/wsys/windows cannot. Servicing requests off the frame loop is stage 3's problem and this is the number it has to beat."

# ------- C(iii). The flag-set answer from /dev/wsys is the flag-unset answer.
"$BIN/cat" /dev/wsys/windows >"$W/windows.on" 2>/dev/null || true
kill "$DP" 2>/dev/null; wait "$DP" 2>/dev/null

if ! [ -s "$W/windows.off" ]; then
    bad "the flag-unset enumeration was EMPTY -- an identical-to-empty comparison would pass for the wrong reason; refusing to report the behaviour as unchanged"
elif diff -q "$W/windows.off" "$W/windows.on" >/dev/null 2>&1; then
    ok "/dev/wsys/windows is byte-identical with the flag set and unset ($(wc -c <"$W/windows.off") bytes, non-empty)"
else
    bad "/dev/wsys/windows differs between the two arms -- stage 1 must change no behaviour"
    diff "$W/windows.off" "$W/windows.on" | sed 's/^/srvtr:      /' | head -6
fi
stop_wsysd "$WP"

# ==================================================================
# D. PIXELS DO NOT CROSS.
# ==================================================================
# The claim being protected is that a window's pixels live in a per-window
# memfd handed up by its owner, so the boundary never carries a frame. The
# evidence is the op census of a REAL dragging client: /dev/wsys/<wid>/backbuffer
# must not be written at all, while the control files must be written a lot.
# The second half is the instrument check -- a census that recorded nothing
# would show zero backbuffer writes too, and would mean the opposite.
WP="$(start_wsysd census)"
HAMWSYS_OPCOUNT=1 "$BIN/de_dragload" 480 320 160 340 300 8 \
    >"$W/wid.census" 2>"$W/census.err" &
DP=$!; reap_add "$DP"
sleep 12
kill "$DP" 2>/dev/null; wait "$DP" 2>/dev/null
stop_wsysd "$WP"

# The census counters are CUMULATIVE and dumped once a second, so the last
# line for a leaf is the total. Summing every line would count the same write
# twelve times -- which inflates the passing half of this assertion and would
# have made a thin census look like a thorough one.
cens(){ # cens <leaf> -> the last cumulative write count for that leaf, or 0
    local v
    v="$(grep -F "opcount:    $1 " "$W/census.err" | tail -1 | awk '{print $NF+0}')"
    echo "${v:-0}"
}
BB="$(cens 'wid/backbuffer')"
OTHER=$(( $(cens 'wid/ctl') + $(cens 'wid/scene') + $(cens 'ctl') ))
grep 'opcount:    ' "$W/census.err" | tail -12 | sed 's/^/srvtr:      /'
if [ "$OTHER" -le 0 ]; then
    bad "the op census recorded no control writes at all in 12 s -- it is not looking, so a zero backbuffer count would mean nothing"
elif [ "$BB" -eq 0 ]; then
    ok "12 s of a dragging client: $OTHER control writes and $BB backbuffer writes. Pixels do not cross -- verified, not assumed."
else
    bad "a client wrote /dev/wsys/<wid>/backbuffer $BB times in 12 s. Pixels would cross the boundary, and the 0.12%-of-a-core budget assumes they do not."
fi

# ==================================================================
# E(ii). THE COST OF THE TRANSPORT, AGAINST THE BUDGET.
# ==================================================================
read -r N1 N2 N3 NMED <<<"$(measure_idle idle_on HAMWSYS_SERVER=1)"
note "idle CPU, HAMWSYS_SERVER=1:    samples $N1% $N2% $N3% -> median $NMED% of a core"
DELTA="$(awk -v a="$OMED" -v b="$NMED" 'BEGIN{printf "%.2f", b-a}')"
# THIS ARM HAS NO CLIENT, so it has neither a wake nor a message and neither
# term of the budget below applies to it. What it asserts is narrower and worth
# asserting on its own: that merely ENABLING the server -- binding the socket
# and carrying the extra fd in the wait set -- costs nothing when nobody has
# dialled it. The allowance is a noise floor, about five instrument ticks, and
# not a derived figure; the sub-quantum rule keeps it from being read as a pass
# it did not earn.
IDLE_BUDGET="${SRVTR_IDLE_BUDGET:-0.12}"
note "idle delta attributable to the server: $DELTA% of a core (allowance $IDLE_BUDGET%, no client connected)"
within_budget "$DELTA" "$IDLE_BUDGET" "idle"

# ==================================================================
# THE BUDGET, RE-DERIVED -- and why it is two numbers and not one
# ==================================================================
# THE OLD BUDGET WAS THE WRONG SHAPE, and that is a stronger statement than
# "it was too tight". It came from the census as `ops/s x per-op`: at 6.2 us
# sequential, 192 x 6.2 us = 0.12% of a core, and likewise 0.38% and 1.27%.
# Every figure in it is a straight multiple of the rate -- 0.12/192, 0.38/618
# and 1.27/2050 are all 6.2e-4 -- SO THE BUDGET PASSES THROUGH THE ORIGIN. It
# asserts that mediating nothing costs nothing.
#
# Mediation does not work that way. Stage 1 measured the cost at three rates
# and found a term that does not depend on the rate at all: THE WAKE. The load
# paces in 10 ms slices, so every arm at or above 100 ops/s wakes wsysd the
# same 100 times a second, and a wake is a whole loop iteration. At the idle
# rate the wake is most of the bill, so the 192 ops/s arm could not pass
# however cheap messages became.
#
# STAGE 1 LEFT THAT ARM RED ON PURPOSE rather than widen it, and said so in
# those words, because widening it would have hidden a real question: the
# synthetic load ADDS a wake, where a real routed mutation REPLACES a
# shared-memory write that already poked the wake channel. Add-a-wake against
# move-a-wake could not be settled until a real op was routed.
#
# STAGE 2 ROUTED THE MUTATIONS AND SETTLED IT, and the answer was better than
# move-a-wake: the same real dragging client cost a median 99.80% of a core
# unrouted and 53.30% routed -- 46.5 POINTS OF A CORE CHEAPER, at 43% more
# frames -- because srv_service drains every queued message in one iteration
# where the unrouted path woke the loop per publish. MEDIATION COALESCES BY
# CONSTRUCTION.
#
# So the fixed term this synthetic NOP measures is an UPPER BOUND that real
# traffic does not pay. That is the honest reason the 192 arm may now pass:
# not that the budget was widened to fit, but that the question the red arm
# was holding open has been answered, and the budget is now written in the
# shape the cost actually has:
#
#     budget(ops) = FIXED_BUDGET + MARGINAL_BUDGET x ops
#
# BOTH TERMS ARE ASSERTED SEPARATELY below, so a dearer wake cannot be hidden
# by cheaper messages or the other way round -- which a single percentage per
# rate could not distinguish, and which is the failure the old shape allowed.
#
# The two numbers are overridable so that this gate's own ability to fail can
# be demonstrated on real measured data rather than argued.
FIXED_BUDGET="${SRVTR_FIXED_BUDGET:-0.34}"       # % of a core, rate-independent
MARGINAL_BUDGET="${SRVTR_MARGINAL_BUDGET:-1.80}" # us of CPU per routed message

budget_for(){ # budget_for <ops/s> -> % of a core
    # m us/message is m/10000 % of a core per op/s: 1 op/s costing m us of CPU
    # per second is m/1e6 of a core, and a percent is another factor of 100.
    awk -v f="$FIXED_BUDGET" -v m="$MARGINAL_BUDGET" -v o="$1" \
        'BEGIN{printf "%.2f", f + m*o/10000.0}'
}
note "budget: ${FIXED_BUDGET}% of a core fixed + ${MARGINAL_BUDGET} us per message"
note "        => $(budget_for 100)% at 100/s, $(budget_for 192)% at 192/s, $(budget_for 618)% at 618/s, $(budget_for 2050)% at 2050/s"

# Driven: the census rate for an idle desktop is 192 ops/s; a mouse-paced drag
# is 618/s; the worst measured load is 2050/s. Drive each and read the SERVER's
# CPU, which is where mediation is paid. The client's own cost is not the
# question -- the client already pays for the write it makes today.
#
# 100 ops/s IS ADDED AND IT IS NOT A FOURTH DATA POINT FOR ITS OWN SAKE. The
# pacer emits at least one message per 10 ms slice at any rate >= 100/s, so
# 100/s is the CHEAPEST LOAD THAT STILL WAKES wsysd 100 times a second: its
# cost is the fixed term plus 100 x marginal, and 100 x 1.35 us is 0.0135% of
# a core -- half an instrument tick. It therefore MEASURES THE WAKE ALMOST
# DIRECTLY instead of extrapolating it back from 192, which matters because
# the intercept of a fit through three noisy points is the worst-determined
# thing in it: across the three runs on record the marginal term held at
# 1.076 / 1.350 / 1.346 us while the fitted intercept wandered 0.25 / 0.19 /
# 0.12, the two trading off against each other exactly as a fit's slope and
# intercept do.
drive(){ # drive <ops/s> <budget%> <label>
    local ops="$1" budget="$2" label="$3"
    local p s1 s2 s3 med d dp i out=""
    p="$(start_wsysd "drive$ops" HAMWSYS_SERVER=1)"
    sleep 2
    for i in 1 2 3; do
        HAMWSYS_SERVER=1 "$BIN/wsys_srv_probe" sustain "$ops" $((WIN + 3)) \
            >>"$W/sustain.$ops.out" 2>>"$W/sustain.$ops.err" &
        dp=$!; reap_add "$dp"
        sleep 1
        out="$out $(cpu_pct "$p" "$WIN")"
        wait "$dp" 2>/dev/null
    done
    read -r s1 s2 s3 <<<"$out"
    med="$(median3 "$s1" "$s2" "$s3")"
    d="$(awk -v a="$OMED" -v b="$med" 'BEGIN{printf "%.2f", b-a}')"
    stop_wsysd "$p"
    grep -h wsrvsu "$W/sustain.$ops.out" | tail -3 | sed 's/^/srvtr:      /'
    note "$label ($ops ops/s): samples $s1% $s2% $s3% -> median $med%, delta over the flag-off idle baseline $d% (budget $budget%)"
    within_budget "$d" "$budget" "$label"
    DRIVE_DELTA="$d"                          # read by the decomposition below
}
DRIVE_DELTA=0
drive 100  "$(budget_for 100)"  "wake-only traffic";   D100="$DRIVE_DELTA"
drive 192  "$(budget_for 192)"  "idle-rate traffic";   D192="$DRIVE_DELTA"
drive 618  "$(budget_for 618)"  "mouse-paced drag";    D618="$DRIVE_DELTA"
drive 2050 "$(budget_for 2050)" "worst measured load"; D2050="$DRIVE_DELTA"

# ==================================================================
# E(iii). WHERE THE COST ACTUALLY IS -- fixed against marginal.
# ==================================================================
# Four rates over a 20x span decompose the cost into a per-message part and a
# part that does not depend on the rate at all. That decomposition is the
# whole finding: the design's budget was ops/s times a per-op cost, which has
# no fixed term in it, so if the fixed term is large the budget is wrong in a
# way no amount of making messages cheaper can fix.
#
# The load generator paces in 10 ms slices, so EVERY ARM WAKES THE COMPOSITOR
# THE SAME NUMBER OF TIMES -- 100 a second. Anything that scales with the rate
# is the message; anything that does not is the wake.
#
# The slope is taken over 100 -> 2050, the longest lever available, and the
# fixed term is then read at the 100 ops/s arm rather than extrapolated back
# from 192: a shorter extrapolation is a smaller error, and at 100 ops/s the
# marginal part is half an instrument tick.
note "cost decomposition, from the four rates:"
DECOMP="$(awk -v z="$D100" -v a="$D192" -v b="$D618" -v c="$D2050" -v q="$QUANT" 'BEGIN{
    m = (c - z) / (2050 - 100);              # % of a core per op/s
    fixed = z - m * 100;
    printf "srvtr: ....   marginal: %.3f us of CPU per message\n", m*10000;
    printf "srvtr: ....   fixed:    %.2f%% of a core, independent of the rate\n", fixed;
    printf "srvtr: ....   (samples %.2f%% at 100, %.2f%% at 192, %.2f%% at 618, %.2f%% at 2050 ops/s;\n", z, a, b, c;
    printf "srvtr: ....    instrument resolution %.3f%%)\n", q;
    printf "MEASURED %.4f %.4f\n", m*10000, fixed;
}')"
printf '%s\n' "$DECOMP" | grep -v '^MEASURED '
MARGINAL_US="$(printf '%s\n' "$DECOMP" | awk '/^MEASURED /{print $2}')"
FIXED_PCT="$(printf '%s\n' "$DECOMP" | awk '/^MEASURED /{print $3}')"

# AND NOW ASSERT BOTH TERMS, which is the point of decomposing at all. A single
# percentage per rate cannot tell "the wake got dearer" from "messages got
# dearer", and those have different fixes: the wake is a loop iteration and the
# message is the transport. Either one regressing turns this gate red on its
# own.
#
# THE INSTRUMENT MUST BE ABLE TO SEE THE TERM IT IS JUDGING. The fixed term is
# a difference of medians and the marginal term is a slope over a difference of
# medians; a value under one tick is not a measurement, and is reported as
# unresolvable rather than as a pass -- the same rule the per-rate check uses.
if awk -v x="$FIXED_PCT" -v y="$FIXED_BUDGET" 'BEGIN{exit !(x <= y)}'; then
    if awk -v x="$FIXED_PCT" -v q="$QUANT" 'BEGIN{exit !(x < q)}'; then
        ok "the fixed term is below this instrument's resolution ($QUANT% of a core); it is under the $FIXED_BUDGET% allowance, and that is all that can be claimed"
    else
        ok "the WAKE costs $FIXED_PCT% of a core, within the $FIXED_BUDGET% fixed allowance"
    fi
else
    bad "the WAKE costs $FIXED_PCT% of a core, over the $FIXED_BUDGET% fixed allowance -- a loop iteration got dearer, and no cheaper message reaches this"
fi
if awk -v x="$MARGINAL_US" -v y="$MARGINAL_BUDGET" 'BEGIN{exit !(x <= y)}'; then
    ok "a routed MESSAGE costs $MARGINAL_US us of CPU, within the $MARGINAL_BUDGET us marginal allowance"
else
    bad "a routed MESSAGE costs $MARGINAL_US us of CPU, over the $MARGINAL_BUDGET us marginal allowance -- the transport got dearer per message"
fi

# WHAT WOULD IT TAKE TO TURN THIS RED? Printed, not asserted, because a budget
# nothing can exceed is not a budget and the reader is entitled to check that
# this one can be exceeded without running the experiment.
awk -v f="$FIXED_PCT" -v fb="$FIXED_BUDGET" -v m="$MARGINAL_US" -v mb="$MARGINAL_BUDGET" 'BEGIN{
    printf "srvtr: ....   headroom: the wake may grow %.2f%% of a core (x%.2f) ", fb-f, (f>0? fb/f : 0);
    printf "and a message %.3f us (x%.2f) before this gate goes red\n", mb-m, (m>0? mb/m : 0);
}'

echo "srvtr: $pass passed, $fail failed"
[ "$fail" = 0 ]
