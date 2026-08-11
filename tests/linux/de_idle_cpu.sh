#!/usr/bin/env bash
# tests/linux/de_idle_cpu.sh — an IDLE desktop must be IDLE.
#
# THE DEFECT THIS EXISTS FOR
# ==========================
# Every functional gate on this tree passed while a booted desktop with no
# window open, no input and nothing running burned BOTH vCPUs: `hamdesktop`
# and `hampanelscene` each accumulated 11 seconds of CPU in a 20-second window,
# in state R, and the host's QEMU sat at 203.6% of one cpu. Everything worked.
# The machine was on fire. On a laptop that is the difference between a day of
# battery and two hours, and no screenshot, display list or PASS count can see
# it -- so it gets a gate of its own, and the gate measures TIME, not output.
#
# WHAT IT MEASURES, and why both halves
# =====================================
#   guest side  `ps` twice, INTERVAL seconds apart, with the DE up and nothing
#               touching it. TIME is cumulative CPU (utime+stime), so the
#               difference over a known wall interval IS the per-process duty
#               cycle. This is the number that names the guilty process.
#   host side   the QEMU process's own utime+stime from /proc, over the SAME
#               window. This is the number that cannot be argued with: it is
#               what the fan responds to, and it catches a guest that busies a
#               vCPU somewhere `ps` cannot see. It had to: after the window
#               system's spin was fixed EVERY guest process read 0:00 and the
#               host still read 104.5%. The remaining spinner was `sleep`, a
#               child that lives entirely between the two `ps` samples and so
#               appears in neither.
#
# A process is allowed IDLE_BUDGET_PCT of one CPU. The budget is deliberately
# generous (a park with a 16 ms timeout that does real work on every wake would
# still pass); anything spinning fails it by an order of magnitude.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

INTERVAL="${IDLE_INTERVAL:-20}"     # the measured window, seconds
SETTLE="${IDLE_SETTLE:-45}"         # boot + DE bring-up before measuring
IDLE_BUDGET_PCT="${IDLE_BUDGET_PCT:-25}"   # per-process, % of ONE cpu
HOST_BUDGET_PCT="${HOST_BUDGET_PCT:-60}"   # whole VM, % of ONE cpu (2 vCPUs)

WORK="${IDLE_WORK:-$(mktemp -d -p "${TMPDIR:-/home/david/.hamnix-build}" idlecpu.XXXXXX)}"
mkdir -p "$WORK"
echo "[idlecpu] work dir: $WORK"

# The guest side. rc.5 brings the whole DE up; then NOTHING happens except two
# `ps` calls INTERVAL apart. The banners are what the host lines its own
# sampling window up with, so the two measurements cover the same seconds.
#
# TWO PHASES, because the bare desktop is not the case a person is in.
#   A  the desktop as rc.5 leaves it -- backdrop, panel, the Wayland servers.
#   B  the same, with ONE TERMINAL OPEN, which is what anybody actually has on
#      screen. It is a separate phase because it caught a separate defect that
#      phase A cannot see: the shell inside the terminal sat at its prompt with
#      nobody typing and burned 105% of a core, while every process phase A
#      knows about was already at 0:00.
#
# THE REAL rc.boot, not a stand-in. An earlier draft of this gate sourced only
# /etc/rc.d/rc.5, which skips the distribution binds -- and the per-distribution
# `wsyswl` then died on `cannot listen on /n/debian/run/wayland-0` because
# nothing had bound /n/debian. That is a defect of the TEST, and it would have
# been reported as a defect of the system. So the census boots the production
# rc verbatim and appends itself to the end of it.
cp etc/rc.boot.linux "$WORK/rc.boot"
cat >> "$WORK/rc.boot" <<RC

# --- the idle census ------------------------------------------------
sleep $SETTLE
echo '[idlecpu] A T0 BEGIN'
ps
echo '[idlecpu] A T0 END'
sleep $INTERVAL
echo '[idlecpu] A T1 BEGIN'
ps
echo '[idlecpu] A T1 END'

# Phase B: open a terminal through the DE launch queue -- the same path the
# Applications menu uses -- and then leave it alone.
echo '/bin/hamtermscene' > '/dev/wsys/appmenu/launch'
sleep 25
echo '[idlecpu] B T0 BEGIN'
ps
echo '[idlecpu] B T0 END'
sleep $INTERVAL
echo '[idlecpu] B T1 BEGIN'
ps
echo '[idlecpu] B T1 END'
echo '[idlecpu] DONE'
RC

echo "[idlecpu] staging an image"
HAMLINUX_RC="$WORK/rc.boot" scripts/hamlinux_image.sh > "$WORK/build.log" 2>&1 || {
    echo "FAIL image build"; tail -20 "$WORK/build.log"; exit 1; }

BOOTLOG="$WORK/boot.log"
: > "$BOOTLOG"
RUNTIME=$(( SETTLE + 2 * INTERVAL + 140 ))
echo "[idlecpu] booting (up to ${RUNTIME}s)"
# No -display, no VNC: an idle desktop is the subject, and a VNC client
# attaching would itself generate the pointer traffic this is measuring the
# absence of.
( sleep "$RUNTIME" ) | HAMLINUX_VNC=none HAMLINUX_DISTRO_RO=1 \
    scripts/hamlinux_vm.sh script --timeout "$RUNTIME" > "$BOOTLOG" 2>&1 &
RUNNER=$!

# Find the qemu child. `scripts/hamlinux_vm.sh` execs into timeout which execs
# qemu, so the pid is a descendant of $RUNNER -- located by walking, never by
# `pkill -f`, because every VM on this tree has the same argv.
QPID=""
for _ in $(seq 1 100); do
    QPID="$(pgrep -P "$RUNNER" -x qemu-system-x86_64 2>/dev/null | head -1)"
    [ -z "$QPID" ] && QPID="$(pgrep -P "$RUNNER" 2>/dev/null | head -1)"
    [ -n "$QPID" ] && break
    sleep 0.2
done
[ -n "$QPID" ] || { echo "FAIL could not find the qemu process"; kill $RUNNER 2>/dev/null; exit 1; }
echo "[idlecpu] qemu pid $QPID"

HZ="$(getconf CLK_TCK)"
cputicks() {  # cputicks <pid> -> utime+stime in clock ticks, "" if gone
    awk '{ n = split($0, f, ") "); split(f[n], g, " ");
           print g[12] + g[13] }' "/proc/$1/stat" 2>/dev/null
}
await() {     # await <banner> <seconds> -- wait for a line in the boot log
    local w=0
    while ! grep -aqF "$1" "$BOOTLOG"; do
        sleep 1; w=$((w + 1))
        [ "$w" -gt "$2" ] && return 1
        kill -0 "$QPID" 2>/dev/null || return 1
    done
    return 0
}

# The host window is lined up with the guest's by the banners, so the two
# measurements cover the same seconds. Sampling starts at the END of the T0
# `ps` (the listing itself costs CPU and is not part of "idle") and stops at
# the START of the T1 one.
declare -A HA HB
await '[idlecpu] A T0 END'   $((SETTLE + 120))  || true
HA[0]="$(cputicks "$QPID")"; HA[t0]="$(date +%s.%N)"
await '[idlecpu] A T1 BEGIN' $((INTERVAL + 90)) || true
HA[1]="$(cputicks "$QPID")"; HA[t1]="$(date +%s.%N)"
await '[idlecpu] B T0 END'   $((INTERVAL + 120)) || true
HB[0]="$(cputicks "$QPID")"; HB[t0]="$(date +%s.%N)"
await '[idlecpu] B T1 BEGIN' $((INTERVAL + 90)) || true
HB[1]="$(cputicks "$QPID")"; HB[t1]="$(date +%s.%N)"

wait $RUNNER 2>/dev/null
# The runner owns the qemu; when it is gone so is the VM. Never pkill by
# pattern -- other agents' VMs have the identical argv.
kill "$RUNNER" 2>/dev/null

fail=0
say() { if [ "$2" = 1 ]; then echo "idlecpu: PASS $1"; else echo "idlecpu: FAIL $1"; fail=1; fi; }

host_arm() {   # host_arm <label> <t0 ticks> <t1 ticks> <t0 wall> <t1 wall>
    if [ -z "$2" ] || [ -z "$3" ]; then
        say "[$1] host QEMU cpu was sampled" 0
        return
    fi
    local pct
    pct="$(awk -v a="$2" -v b="$3" -v t0="$4" -v t1="$5" -v hz="$HZ" \
        'BEGIN { w = t1 - t0; if (w <= 0) { print "999"; exit }
                 printf "%.1f", (b - a) / hz / w * 100 }')"
    echo "  [$1] qemu cpu ${pct}% of one cpu (2 vCPUs => 200% is both pegged)"
    say "[$1] host QEMU under ${HOST_BUDGET_PCT}% of a cpu (got ${pct}%)" \
        "$(awk -v p="$pct" -v b="$HOST_BUDGET_PCT" 'BEGIN { print (p < b) ? 1 : 0 }')"
}

guest_arm() {  # guest_arm <phase letter> <label>
    local A="$WORK/ps-$1-0.txt" B="$WORK/ps-$1-1.txt"
    sed -n "/\[idlecpu\] $1 T0 BEGIN/,/\[idlecpu\] $1 T0 END/p" "$BOOTLOG" \
        | tr -d '\r' > "$A"
    sed -n "/\[idlecpu\] $1 T1 BEGIN/,/\[idlecpu\] $1 T1 END/p" "$BOOTLOG" \
        | tr -d '\r' > "$B"
    if [ ! -s "$A" ] || [ ! -s "$B" ]; then
        say "[$2] the guest reported ps at both ends of the window" 0
        return
    fi
    say "[$2] the guest reported ps at both ends of the window" 1

    # `ps` prints "PID USER S TIME CMD" with TIME as MM:SS. Only a process
    # present in BOTH samples can be differenced -- a real limit of this half
    # of the census, and the reason the host half exists.
    awk -v interval="$INTERVAL" -v budget="$IDLE_BUDGET_PCT" '
        function secs(t,  p) { split(t, p, ":"); return p[1] * 60 + p[2] }
        FNR == NR { if ($4 ~ /^[0-9]+:[0-9][0-9]$/) { t0[$1] = secs($4) } ; next }
        {
            if ($4 !~ /^[0-9]+:[0-9][0-9]$/) next
            if (!($1 in t0)) next
            d = secs($4) - t0[$1]
            pct = d / interval * 100
            if (d > 0)
                printf "    %-6s %-16s %-2s %6.1fs -> %6.1f%% of one cpu\n", \
                       $1, $5, $3, d, pct
            if (pct > budget) { bad[$1] = $5 " (" sprintf("%.0f", pct) "%)"; nbad++ }
        }
        END {
            if (nbad) { for (p in bad) printf "OVERBUDGET %s %s\n", p, bad[p] }
            else print "OVERBUDGET none"
        }
    ' "$A" "$B" > "$WORK/delta-$1.txt"
    grep -v '^OVERBUDGET' "$WORK/delta-$1.txt"
    local over
    over="$(grep '^OVERBUDGET' "$WORK/delta-$1.txt")"
    if [ "$over" = "OVERBUDGET none" ]; then
        say "[$2] no process burns more than ${IDLE_BUDGET_PCT}% of a cpu" 1
    else
        echo "$over" | sed 's/^/    /'
        say "[$2] no process burns more than ${IDLE_BUDGET_PCT}% of a cpu" 0
    fi

    # The same census turned up three unreaped children: two per-distribution
    # `wsyswl` and hamdesktop's boot chime (`aplay`, spawned RFNOWAIT, a flag
    # this port ignored). A zombie is small, but it means somebody's obligation
    # to wait for a child is not being met, and this notices it coming back.
    local zomb
    zomb="$(awk '$3 == "Z" { print $1, $5 }' "$B")"
    if [ -z "$zomb" ]; then
        say "[$2] no zombie processes" 1
    else
        echo "$zomb" | sed 's/^/    zombie: /'
        say "[$2] no zombie processes" 0
    fi
}

echo
echo "=== A: the desktop as rc.5 leaves it, ${INTERVAL}s ==="
host_arm "A idle desktop" "${HA[0]:-}" "${HA[1]:-}" "${HA[t0]:-0}" "${HA[t1]:-0}"
guest_arm A "A idle desktop"

echo
echo "=== B: the same desktop with one terminal open, ${INTERVAL}s ==="
host_arm "B terminal open" "${HB[0]:-}" "${HB[1]:-}" "${HB[t0]:-0}" "${HB[t1]:-0}"
guest_arm B "B terminal open"

# A terminal that never opened would make phase B a second copy of phase A and
# pass for the wrong reason. Assert the process is really there.
if grep -aq 'hamtermscene' "$WORK/ps-B-1.txt" 2>/dev/null; then
    say "[B terminal open] the terminal really is running" 1
else
    say "[B terminal open] the terminal really is running" 0
fi

echo
if [ $fail -eq 0 ]; then echo "idlecpu: ALL PASS"; else echo "idlecpu: SOME FAILED"; fi
exit $fail
