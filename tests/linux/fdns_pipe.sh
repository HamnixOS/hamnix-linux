#!/usr/bin/env bash
# tests/linux/fdns_pipe.sh -- does a pipe END?
#
# Builds tests/linux/fdns_pipe.c against user/linux-fdns.c and runs it in a
# private /srv and a private shm segment, so it touches nothing the machine
# is using.  See the file's own header for what each case measures.
set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fdns_pipe.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

mkdir -p "$WORK/srv"
cc -std=c11 -Wall -Wextra -Wno-unused-parameter -O1 -g \
   -I user -o "$WORK/fdns_pipe" \
   tests/linux/fdns_pipe.c user/linux-fdns.c

# The whole gate under a wall-clock ceiling as well: every case already has
# its own alarm, so reaching this one means the harness itself wedged.
set +e
HAMFDNS="$WORK/fdns.shm" HAMFDNS_DIR="$WORK/srv" \
    timeout 120 "$WORK/fdns_pipe"
rc=$?
set -e

if [ "$rc" -eq 124 ]; then
    echo "FAIL fdns_pipe: the harness itself did not finish in 120 s"
    exit 1
fi
exit "$rc"
