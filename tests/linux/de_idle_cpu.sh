#!/usr/bin/env bash
# tests/linux/de_idle_cpu.sh — an IDLE desktop must be IDLE.
#
# THE DEFECT THIS EXISTS FOR
# ==========================
# Every functional gate on this tree passed while a booted desktop with no
# window open, no input and nothing running burned BOTH vCPUs: `hamdesktop`
# and `hampanelscene` each accumulated 18 seconds of CPU in 20 seconds of wall
# time, in state R, and the host's QEMU sat at ~175%. Everything worked. The
# machine was on fire. On a laptop that is the difference between a day of
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
#               vCPU somewhere `ps` cannot see.
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
echo '[idlecpu] T0 BEGIN'
ps
echo '[idlecpu] T0 END'
sleep $INTERVAL
echo '[idlecpu] T1 BEGIN'
ps
echo '[idlecpu] T1 END'
echo '[idlecpu] DONE'
RC

echo "[idlecpu] staging an image"
HAMLINUX_RC="$WORK/rc.boot" scripts/hamlinux_image.sh > "$WORK/build.log" 2>&1 || {
    echo "FAIL image build"; tail -20 "$WORK/build.log"; exit 1; }

BOOTLOG="$WORK/boot.log"
: > "$BOOTLOG"
RUNTIME=$(( SETTLE + INTERVAL + 60 ))
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

cputicks() {  # cputicks <pid> -> utime+stime in clock ticks, "" if gone
    awk '{ n = split($0, f, ") "); split(f[n], g, " ");
           print g[12] + g[13] }' "/proc/$1/stat" 2>/dev/null
}

# Line the host window up with the guest's: start sampling when the guest says
# T0, stop when it says T1. Falls back to a wall-clock window if the banner
# never lands (which the guest-side check then reports as its own failure).
HZ="$(getconf CLK_TCK)"
waited=0
while ! grep -aq '\[idlecpu\] T0 END' "$BOOTLOG"; do
    sleep 1; waited=$((waited + 1))
    [ $waited -gt $((SETTLE + 90)) ] && break
    kill -0 "$QPID" 2>/dev/null || break
done
H0="$(cputicks "$QPID")"; T0W="$(date +%s.%N)"
waited=0
while ! grep -aq '\[idlecpu\] T1 BEGIN' "$BOOTLOG"; do
    sleep 1; waited=$((waited + 1))
    [ $waited -gt $((INTERVAL + 60)) ] && break
    kill -0 "$QPID" 2>/dev/null || break
done
H1="$(cputicks "$QPID")"; T1W="$(date +%s.%N)"

wait $RUNNER 2>/dev/null
# The runner owns the qemu; when it is gone so is the VM. Never pkill by
# pattern -- other agents' VMs have the identical argv.
kill "$RUNNER" 2>/dev/null

fail=0
say() { if [ "$2" = 1 ]; then echo "idlecpu: PASS $1"; else echo "idlecpu: FAIL $1"; fail=1; fi; }

echo
echo "=== HOST SIDE: the QEMU process over the measured window ==="
if [ -n "$H0" ] && [ -n "$H1" ]; then
    HOSTPCT="$(awk -v a="$H0" -v b="$H1" -v t0="$T0W" -v t1="$T1W" -v hz="$HZ" \
        'BEGIN { w = t1 - t0; if (w <= 0) { print "0.0"; exit } printf "%.1f", (b - a) / hz / w * 100 }')"
    echo "  window ${T0W%.*}..${T1W%.*}  qemu cpu ${HOSTPCT}% of one cpu (2 vCPUs => 200% is both pegged)"
    say "host QEMU under ${HOST_BUDGET_PCT}% on an idle desktop (got ${HOSTPCT}%)" \
        "$(awk -v p="$HOSTPCT" -v b="$HOST_BUDGET_PCT" 'BEGIN { print (p < b) ? 1 : 0 }')"
else
    say "host QEMU cpu was sampled" 0
fi

echo
echo "=== GUEST SIDE: ps TIME deltas over ${INTERVAL}s of an idle desktop ==="
sed -n '/\[idlecpu\] T0 BEGIN/,/\[idlecpu\] T0 END/p' "$BOOTLOG" | tr -d '\r' > "$WORK/ps0.txt"
sed -n '/\[idlecpu\] T1 BEGIN/,/\[idlecpu\] T1 END/p' "$BOOTLOG" | tr -d '\r' > "$WORK/ps1.txt"
if [ ! -s "$WORK/ps0.txt" ] || [ ! -s "$WORK/ps1.txt" ]; then
    say "the guest reported ps at both ends of the window" 0
    echo "--- boot log tail:"; tail -40 "$BOOTLOG"
    exit 1
fi
say "the guest reported ps at both ends of the window" 1

# `ps` prints "PID USER S TIME CMD" with TIME as MM:SS.
awk -v interval="$INTERVAL" -v budget="$IDLE_BUDGET_PCT" '
    function secs(t,  p) { split(t, p, ":"); return p[1] * 60 + p[2] }
    FNR == NR { if ($4 ~ /^[0-9]+:[0-9][0-9]$/) { t0[$1] = secs($4) } ; next }
    {
        if ($4 !~ /^[0-9]+:[0-9][0-9]$/) next
        if (!($1 in t0)) next
        d = secs($4) - t0[$1]
        pct = d / interval * 100
        printf "  %-6s %-16s %-2s %6.1fs -> %6.1f%% of one cpu\n", $1, $5, $3, d, pct
        if (pct > budget) { bad[$1] = $5 " (" sprintf("%.0f", pct) "%)"; nbad++ }
    }
    END {
        if (nbad) { for (p in bad) printf "OVERBUDGET %s %s\n", p, bad[p] }
        else print "OVERBUDGET none"
    }
' "$WORK/ps0.txt" "$WORK/ps1.txt" > "$WORK/delta.txt"
grep -v '^OVERBUDGET' "$WORK/delta.txt"
OVER="$(grep '^OVERBUDGET' "$WORK/delta.txt")"
if [ "$OVER" = "OVERBUDGET none" ]; then
    say "no process burns more than ${IDLE_BUDGET_PCT}% of a cpu while idle" 1
else
    echo "$OVER" | sed 's/^/  /'
    say "no process burns more than ${IDLE_BUDGET_PCT}% of a cpu while idle" 0
fi

# The same census turned up two REAPED-BY-NOBODY per-distribution Wayland
# servers. A zombie is small, but it means the supervisor inside hamsh is not
# doing its job, and this is the census that would notice it coming back.
ZOMB="$(awk '$3 == "Z" { print $1, $5 }' "$WORK/ps1.txt")"
if [ -z "$ZOMB" ]; then
    say "no zombie processes on an idle desktop" 1
else
    echo "$ZOMB" | sed 's/^/  zombie: /'
    say "no zombie processes on an idle desktop" 0
fi

echo
if [ $fail -eq 0 ]; then echo "idlecpu: ALL PASS"; else echo "idlecpu: SOME FAILED"; fi
exit $fail
