#!/usr/bin/env bash
# tests/linux/pipelines.sh — DOES A PIPELINE END?
#
# `cat FILE | md5sum` never returned, and it took a whole boot with it
# (docs/linux_installed_update.md §3). The digest was never the problem: the
# same md5sum answered two FILE operands correctly one line above. What did
# not finish was the pipe's EOF — hamsh created the fifo, kept an O_RDWR
# descriptor on it so the first open would not deadlock, and never let go, so
# the reader was waiting for a writer that was the shell itself.
#
# That is not one command's bug. hamsh is PID 1 and a pipeline is how anyone
# composes anything, so it is worth a gate of its own, and the gate has to
# measure the one property a functional test cannot: THAT THE THING ENDS.
#
# HOW A HANG IS CAUGHT. Every line runs in the boot rc, i.e. in PID 1, so a
# pipeline that never returns takes the rest of the boot with it — which is
# exactly what happened in the update gate, where every later check failed as
# collateral. So the test does not ask "did check N pass"; it asks:
#
#   * did the boot reach `pipegate: DONE`, and
#   * of the N marks it should have printed, which is the LAST one it printed?
#
# A hang is then reported BY NAME ("stalled at MARK 4 cat-into-cksum") rather
# than as a wall of unrelated failures. That naming is the whole point.
#
# HOW A WRONG ANSWER IS CAUGHT. Every stream arm has a FILE arm one line
# below it, and the host compares them: `cat F | md5sum` against `md5sum F`,
# `cat F | wc -c` against `wc -c F`, `cat F | cksum` against `cksum F`. A
# pipeline that ends and delivers nothing is the OTHER failure mode of this
# machinery — dropping the keeper naively produces precisely it — and it is
# success-shaped, so comparing against a computation that does not go through
# a pipe at all is the only honest check.
#
# Nothing shared is written: the rc goes in through HAMLINUX_RC and the image
# is built into whatever build/image is in THIS tree (docs/steam_namespace.md
# §11).
#
# Usage: tests/linux/pipelines.sh [seconds]
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

WAIT="${1:-120}"
WORK="build/pipelines"; mkdir -p "$WORK"
IMG=build/image
export HAMLINUX_VNC="${HAMLINUX_VNC:-none}"
export HAMLINUX_DISTRO_RO="${HAMLINUX_DISTRO_RO:-1}"

# --- the rc, which IS the test ------------------------------------------
# Written by the host so the repetition case (a pipeline per line, more of
# them than the fd name space has slots) does not need a shell loop in the
# guest.
{
cat <<'RC'
echo 'pipegate: rc.boot starting'
ln -s /dev/console /dev/cons
seq 1 500 > /tmp/pg.txt

echo 'pipegate: MARK 1 echo-into-cat'
echo hi | cat

echo 'pipegate: MARK 2 cat-into-wc'
cat /tmp/pg.txt | wc -c
echo 'pipegate: REF 2'
wc -c /tmp/pg.txt

echo 'pipegate: MARK 3 cat-into-md5sum'
cat /tmp/pg.txt | md5sum
echo 'pipegate: REF 3'
md5sum /tmp/pg.txt

echo 'pipegate: MARK 4 cat-into-cksum'
cat /tmp/pg.txt | cksum
echo 'pipegate: REF 4'
cksum /tmp/pg.txt

echo 'pipegate: MARK 5 three-stage'
cat /tmp/pg.txt | sort | wc -l

echo 'pipegate: MARK 6 reader-exits-early'
cat /tmp/pg.txt | head -2

echo 'pipegate: MARK 7 capture'
echo captured > /tmp/cap.txt
echo 'pipegate: REF 7'
cat /tmp/cap.txt
echo 'pipegate: capture' `{ cat /tmp/cap.txt }
echo 'pipegate: MARK 7b builtin-capture'
echo 'pipegate: bcapture' `{ echo inner }

echo 'pipegate: MARK 8 seventy-pipelines'
RC
# The fd name space has 64 slots and nothing used to free one, so the 65th
# pipe OR REDIRECT of a boot got ENOSPC for the life of the segment. hamsh is
# PID 1: for it, "the owner exited" is never going to reclaim anything.
for i in $(seq 1 70); do
    echo "echo p$i | cat"
    [ $((i % 10)) = 0 ] && echo "date"
done
cat <<'RC'
echo 'pipegate: MARK 9 pipe-after-many'
cat /tmp/pg.txt | md5sum
echo 'pipegate: DONE'
RC
} > "$WORK/rc.boot"

echo "[pipegate] staging an image with that rc"
HAMLINUX_RC="$WORK/rc.boot" scripts/hamlinux_image.sh > "$WORK/build.log" 2>&1 || {
    echo "FAIL image build"; tail -20 "$WORK/build.log"; exit 1; }

echo "[pipegate] booting (up to ${WAIT}s)"
( sleep "$((WAIT + 10))" ) | timeout "$((WAIT + 5))" \
    scripts/hamlinux_vm.sh script --timeout "$WAIT" > "$WORK/boot.log" 2>&1

LOG="$WORK/boot.log"
# -a everywhere: a console that has carried a NUL byte makes grep treat the
# log as binary and answer nothing, which reads as a silent run.
sed -e 's/\r$//' "$LOG" | tr -d '\0' > "$WORK/boot.txt"

P=0; F=0
ok()  { P=$((P+1)); echo "PASS $*"; }
bad() { F=$((F+1)); echo "FAIL $*"; }

# The line printed immediately after a marker. That is the pipeline's answer.
after() { awk -v m="$1" 'f{print;exit} index($0,m){f=1}' "$WORK/boot.txt"; }

MARKS=(
    "MARK 1 echo-into-cat"
    "MARK 2 cat-into-wc"
    "MARK 3 cat-into-md5sum"
    "MARK 4 cat-into-cksum"
    "MARK 5 three-stage"
    "MARK 6 reader-exits-early"
    "MARK 7 capture"
    "MARK 7b builtin-capture"
    "MARK 8 seventy-pipelines"
    "MARK 9 pipe-after-many"
)

# --- 1. did it END? -------------------------------------------------------
if grep -q 'pipegate: DONE' "$WORK/boot.txt"; then
    ok "the boot ran every pipeline to the end"
else
    LAST="(none)"
    for m in "${MARKS[@]}"; do
        grep -q "pipegate: $m" "$WORK/boot.txt" && LAST="$m"
    done
    bad "the boot NEVER FINISHED -- stalled at $LAST"
    bad "a pipeline that hangs takes PID 1 with it; every check below is collateral"
fi

# --- 2. did each one ANSWER, and with the right bytes? --------------------
v="$(after 'MARK 1 echo-into-cat')"
[ "$v" = "hi" ] && ok "echo hi | cat -> 'hi'" || bad "echo hi | cat -> '$v' (want 'hi')"

sw="$(after 'MARK 2 cat-into-wc')"
fw="$(after 'REF 2')"
sw="$(echo "$sw" | tr -s ' ' | sed 's/^ *//' | cut -d' ' -f1)"
fw="$(echo "$fw" | tr -s ' ' | sed 's/^ *//' | cut -d' ' -f1)"
if [ -n "$sw" ] && [ "$sw" = "$fw" ]; then
    ok "cat F | wc -c agrees with wc -c F ($sw bytes)"
else
    bad "cat F | wc -c said '$sw', wc -c F said '$fw'"
fi

sm="$(after 'MARK 3 cat-into-md5sum' | tr -s ' ' | cut -d' ' -f1)"
fm="$(after 'REF 3' | tr -s ' ' | cut -d' ' -f1)"
if [ -n "$sm" ] && [ "$sm" = "$fm" ]; then
    ok "cat F | md5sum agrees with md5sum F ($sm)"
else
    bad "cat F | md5sum said '$sm', md5sum F said '$fm'"
fi
# The digest of the EMPTY string is what the old stub answered for every
# input in the world. If it ever reappears, say so by name.
[ "$sm" = "d41d8cd98f00b204e9800998ecf8427e" ] \
    && bad "cat F | md5sum answered the digest of the EMPTY STRING -- the pipe delivered nothing"

sc="$(after 'MARK 4 cat-into-cksum' | tr -s ' ' | cut -d' ' -f1,2)"
fc="$(after 'REF 4' | tr -s ' ' | cut -d' ' -f1,2)"
if [ -n "$sc" ] && [ "$sc" = "$fc" ]; then
    ok "cat F | cksum agrees with cksum F ($sc)"
else
    bad "cat F | cksum said '$sc', cksum F said '$fc'"
fi

v="$(after 'MARK 5 three-stage' | tr -d ' ')"
[ "$v" = "500" ] && ok "cat F | sort | wc -l -> 500 lines" \
                 || bad "cat F | sort | wc -l -> '$v' (want 500)"

# The reader leaves after two lines and the writer has 498 more to give. It
# must get EPIPE and die, not fill the pipe and block for ever.
v="$(after 'MARK 6 reader-exits-early' | tr -d ' ')"
[ "$v" = "1" ] && ok "cat F | head -2 answered (the writer took the close)" \
               || bad "cat F | head -2 -> '$v' (want the first line, 1)"

# The control first: if the redirect that made the file did not work, the
# capture below is not the thing being measured.
r="$(after 'REF 7')"
[ "$r" = "captured" ] && ok "echo > FILE then cat FILE round-trips" \
                      || bad "the control file read back as '$r' (want 'captured')"
v="$(grep -m1 'pipegate: capture' "$WORK/boot.txt" | sed 's/.*pipegate: capture *//')"
[ "$v" = "captured" ] && ok "\`{ cat FILE }\` capture returned its output" \
                      || bad "capture returned '$v' (want 'captured')"

# A BUILTIN inside `{ … }` runs in this process, so its output goes to the
# shell's own stdout and the capture gets nothing. That is a real gap and it
# is NOT fixed here -- what is fixed is that it now says so. An empty
# substitution and a broken one must not look the same.
if grep -q 'substitution of the BUILTIN echo is not captured' "$WORK/boot.txt"; then
    ok "a builtin inside \`{ … }\` reports that it was not captured"
else
    bad "a builtin inside \`{ … }\` yielded the empty string in silence"
fi

n="$(grep -c '^p[0-9]' "$WORK/boot.txt")"
[ "$n" = "70" ] && ok "70 pipelines in one boot, on a 64-slot fd table" \
                || bad "only $n of 70 pipelines answered (the slot table ran out)"

sm2="$(after 'MARK 9 pipe-after-many' | tr -s ' ' | cut -d' ' -f1)"
[ -n "$sm2" ] && [ "$sm2" = "$fm" ] \
    && ok "a pipeline still works after 70 of them" \
    || bad "the pipeline after 70 others said '$sm2', want '$fm'"

echo
echo "[pipegate] $P PASS  $F FAIL   (full log: $LOG)"
[ "$F" = 0 ]
