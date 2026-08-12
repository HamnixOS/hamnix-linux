#!/usr/bin/env bash
# lat_null.sh — A NULL EXPERIMENT, because the sequential run showed a
# difference that CANNOT be caused by the variable under test.
#
# bin/ and binempty/ contain the SAME wsysd; only de_dragload differs, and the
# drag client is killed before the latency trials. So input->pixel measured
# this way is the same binary twice, and ANY difference is the environment --
# another agent is running the release candidate's gates on this box right now.
# Interleaved, not sequential, so a slow patch cannot land entirely on one arm.
set -uo pipefail
cd /home/david/hamnix-linux/.claude/worktrees/agent-a507e3277d1edc6ca
. tests/linux/reap.sh
OUT=/home/david/.hamnix-build/cap-power-ab
W="$(mktemp -d -p "$OUT" ln.XXXXXX)"
reap_track "$W/reaped"; cleanup(){ rm -rf "$W"; }; reap_on_exit cleanup

one() {   # arm rep -> one latency measurement on a quiet desktop, no drag client
    local arm="$1" rep="$2" B="$OUT/$1" D="$W/$1.$2"
    mkdir -p "$D/noicd"
    export HAMWSYS="$D/s" HAMWSYS_BB="$D/b" HAMWSYS_IMG="$D/i"
    export HAMFB_FILE="$D/fb.raw" HAMFB_GEOM=1280x800
    : >"$D/in"; export HAMWSYSD_INPUT="$D/in"
    export VK_ICD_FILENAMES="$D/noicd/none.json"
    "$B/wsysd" </dev/null >"$D/wsysd.log" 2>&1 &
    local WP=$!; reap_add "$WP"
    for _ in $(seq 1 100); do [ -s "$HAMFB_FILE" ] && break; sleep 0.1; done
    "$B/hamdesktop"    </dev/null >/dev/null 2>&1 & reap_add $!
    "$B/hampanelscene" </dev/null >/dev/null 2>&1 & reap_add $!
    sleep 4
    printf '  %-9s rep%s  ' "$arm" "$rep"
    python3 tests/linux/de_fps_driver.py --fb "$HAMFB_FILE" --input "$D/in" \
        --cat "$B/cat" --pid "$WP" --geom 1280x800 \
        --mode latency --trials 120 --tag "lat" 2>&1 | grep -o "min.*ms"
    kill -9 "$WP" 2>/dev/null; wait "$WP" 2>/dev/null; sleep 1
}
echo "the SAME compositor measured under both labels, interleaved:"
for rep in 1 2 3; do
    one binempty "$rep"
    one bin      "$rep"
done
echo "host load: $(cat /proc/loadavg)"
