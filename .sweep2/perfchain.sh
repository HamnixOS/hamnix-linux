#!/bin/bash
# Serial perf-sensitive gates, each gated on loadavg < 2.0.
W=/home/david/hamnix-linux/.claude/worktrees/agent-af0dd6dc5d5f2a8ab
LD="$W/.sweep2/logs"
n=0
while read -r g; do
  [ -z "$g" ] && continue
  # wait for a quiet host, up to 10 minutes
  t=0
  while :; do
    la=$(cut -d' ' -f1 /proc/loadavg)
    if awk -v l="$la" 'BEGIN{exit !(l<2.0)}'; then break; fi
    t=$((t+15)); [ "$t" -ge 600 ] && { echo "LOADWAIT-TIMEOUT $g loadavg=$la"; break; }
    sleep 15
  done
  echo "-- $g at loadavg $(cut -d' ' -f1 /proc/loadavg)"
  bash "$W/.sweep2/run_one.sh" "$g" 1200 "$LD" </dev/null
  n=$((n+1))
done < "$W/.sweep2/host_perf2.txt"
echo "PERFCHAIN DONE attempted=$n"
