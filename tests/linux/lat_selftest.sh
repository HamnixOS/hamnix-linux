#!/usr/bin/env bash
#
# REGISTRATION, 2026-08-17. Until this date scripts/test_gate_registration.sh
# globbed only scripts/test_*.sh, so this directory was invisible to the gate
# against unregistered gates and every file in it read as coverage without
# being coverage. This gate is ON-DEMAND: not in ci_battery_manifest.txt
# because MEASURED 2026-08-17: it exits 0 in 19 s while printing no PASS, no FAIL and no assertion count at all (916 bytes of output). It is a probe, not a gate -- registering it would add a battery line that cannot go red, which is exactly the false assurance the registration gate exists to prevent.
#
#
# lat_selftest.sh — CAN THE IN-COMPOSITOR LATENCY NUMBER REPORT A BAD RESULT?
#
# wsysd now measures input->frame-submitted itself, because on the scanout path
# there is no framebuffer file for the shipped harnesses to watch. A latency
# counter that has only ever printed a small number has not been shown to
# measure anything. This deliberately makes the compositor slow -- SIGSTOP for
# 120 ms, repeatedly, while input is flowing -- and requires the number to go
# UP. If it does not, the instrument is broken and its good numbers are worth
# nothing.
#
# Offscreen. No DRM, no master.
set -uo pipefail
# PRIVATE NAMESPACE FIRST, and sourced by ABSOLUTE PATH because this script cds
# to its build directory and never to the tree it lives in. "Offscreen. No DRM,
# no master." above is true and is about the DISPLAY; the filesystem is a
# separate question. wsysd's names are compiled into it (/srv/wsys,
# /dev/shm/hamnix-wsys, /tmp/hamnix-wsys) and hamdesktop's are too
# (/tmp/hamdesktop-wp.status, /tmp/.hamdesktop.src) -- the table is in
# tests/linux/private_ns.sh -- and this machine's own live desktop holds them.
#
# It has to go ABOVE the cd, because priv_ns_reexec re-execs this script and
# resolves it relative to the directory it was invoked from. Nothing here
# asserts about a uid, so the helper's one fidelity cost (euid 0 inside) touches
# nothing; the build directory is under $HOME/.hamnix-build, which the helper
# does not shadow, so ./bin is still there afterwards.
PRIVNS_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$PRIVNS_HOME/private_ns.sh"
priv_ns_reexec "$@"
cd /home/david/.hamnix-build/vk-present-readback
BIN="${BIN:-./bin}"
W="$(mktemp -d -p . lat.XXXXXX)"
export HAMWSYS="$W/s" HAMWSYS_BB="$W/b" HAMWSYS_IMG="$W/i"
export HAMFB_FILE="$W/fb.raw" HAMFB_GEOM=1280x800
: >"$W/in"; export HAMWSYSD_INPUT="$W/in"
export HAMNIX_WSYSD_BENCH_LIVE="${EVERY:-40}"
ICD="${ICD:-$W/noicd/none.json}"; mkdir -p "$W/noicd"

env VK_ICD_FILENAMES="$ICD" ${EXTRA:-} "$BIN/wsysd" </dev/null \
    >"$W/out.log" 2>"$W/bench.log" &
WP=$!
for _ in $(seq 1 100); do [ -s "$HAMFB_FILE" ] && break; sleep 0.1; done
"$BIN/hamdesktop" </dev/null >/dev/null 2>&1 & DP=$!
sleep 3

# a steady stream of pointer motion, which is what starts the latency clock
python3 - "$W/in" <<'PY' &
import struct, sys, time
f=open(sys.argv[1],'ab',buffering=0)
end=time.time()+26
while time.time()<end:
    t=time.time(); s=int(t); us=int((t-s)*1e6)
    f.write(struct.pack('qqHHi', s, us, 2, 0, 1))    # EV_REL REL_X +1
    f.write(struct.pack('qqHHi', s, us, 0, 0, 0))    # EV_SYN
    time.sleep(0.004)
PY
INJ=$!

sleep 10
echo "=== $(priv_ns_describe)"
echo "=== healthy (no interference):"
grep "lat_n" "$W/bench.log" | tail -3 | sed 's/.*| lat_n/   lat_n/'

echo "=== now SIGSTOPping wsysd 120 ms at a time -- the number MUST rise:"
for _ in $(seq 1 8); do
    kill -STOP "$WP" 2>/dev/null; sleep 0.12; kill -CONT "$WP" 2>/dev/null
    sleep 0.25
done
sleep 3
grep "lat_n" "$W/bench.log" | tail -3 | sed 's/.*| lat_n/   lat_n/'

WORST=$(grep -o "max_us [0-9]*" "$W/bench.log" | awk '{print $2}' | sort -n | tail -1)
echo "=== worst max_us seen across the run: ${WORST:-none}"
if [ -n "${WORST:-}" ] && [ "$WORST" -ge 100000 ]; then
    echo "lat_selftest: PASS the instrument reported a >=100 ms frame when the"
    echo "lat_selftest:      compositor was deliberately stopped for 120 ms."
else
    echo "lat_selftest: FAIL a 120 ms stall did not show up (worst ${WORST:-none} us)."
    echo "lat_selftest:      Its good numbers are therefore not trustworthy."
fi
kill "$INJ" "$DP" "$WP" 2>/dev/null; sleep 0.5
kill -9 "$INJ" "$DP" "$WP" 2>/dev/null; wait 2>/dev/null
rm -rf "$W"
