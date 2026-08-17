#!/usr/bin/env bash
# Its host runtime and its pass/fail were NOT measured when this line was
# written. If you make it cheap enough for the battery, add the manifest line
# and delete this block.
#
# tests/linux/ls_regular_file.sh — `ls` GIVEN A REGULAR FILE MUST PRINT ITS
# NAME, NOT ITS CONTENTS.
#
# THE DEFECT. `ls foo.txt` printed the FILE'S CONTENTS and exited 0. So did
# `ls -l foo.txt`. It has been on the standing list for most of this project:
# not architecturally interesting, and exactly the kind of thing that makes a
# distribution feel broken to somebody using it.
#
# WHY IT HAPPENED, measured rather than guessed. user/ls.ad's plain path calls
# p9_listdir(target), which does sys_open() then sys_read() in a loop. On a
# regular file both succeed, so the bytes read ARE the file's contents and the
# non-negative return is indistinguishable from a directory listing. The
# function's own comment claims it returns -1 when the path "isn't a
# directory" -- there is no such check in it. A surface that lies.
#
# THE TREE ALREADY KNEW. user/find.ad's header records the identical bug and
# its fix: "the descend decision is made by sys_stat_p9 -> qid.type QTDIR, NOT
# by a p9_listdir success: a regular file's open+read also succeeds and would
# be walked as a directory of garbage entries (the bug #146 fixed)". And
# lib/p9.ad already exports p9_is_dir() for precisely this, with a comment
# explaining why p9_listdir cannot answer the question. `ls` simply never asked.
#
# WHAT IT SHOULD DO, which is what both POSIX and Plan 9 do:
#   ls foo        -> the NAME
#   ls -l foo     -> one long-format line for that file
#   ls dir        -> unchanged
#   ls missing    -> an error, non-zero
#
# The last two are asserted as CONTROLS: a fix that made `ls file` right by
# breaking `ls dir`, or by turning a missing path into a success, would be a
# worse bug than the one being fixed.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }

WORK="${LS_REG_WORK:-$HOME/.hamnix-build/ls_regular}"
mkdir -p "$WORK"
W="$(mktemp -d "$WORK/run.XXXXXX")"
cleanup() { rm -rf "$W"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

BIN="${LS_REG_BIN:-$W/ls}"
if [ -z "${LS_REG_BIN:-}" ]; then
    ./scripts/hamlinux_build.sh user/ls.ad "$BIN" >"$W/build.log" 2>&1 || {
        bad "could not build user/ls.ad"; tail -15 "$W/build.log"; exit 1; }
fi

printf 'CONTENTS-OF-THE-FILE\nsecond line\n' >"$W/foo.txt"
mkdir -p "$W/adir"
: >"$W/adir/inside_a"
: >"$W/adir/inside_b"

echo "== ls on a regular file prints its name, not its contents"

# 1. PLAIN ls ON A REGULAR FILE
out="$(cd "$W" && "$BIN" foo.txt 2>"$W/e1")"; rc=$?
if printf '%s' "$out" | grep -q 'CONTENTS-OF-THE-FILE'; then
    bad "ls printed the FILE'S CONTENTS: $(printf '%s' "$out" | head -1)"
elif [ "$out" = "foo.txt" ]; then
    ok "ls foo.txt prints 'foo.txt'"
else
    bad "ls foo.txt printed neither the name nor the contents: '$(printf '%s' "$out" | head -1)' (rc=$rc)"
fi

# 2. ls -l ON A REGULAR FILE -- one line, naming the file, not its bytes
outl="$(cd "$W" && "$BIN" -l foo.txt 2>"$W/e2")"; rcl=$?
if printf '%s' "$outl" | grep -q 'CONTENTS-OF-THE-FILE'; then
    bad "ls -l printed the FILE'S CONTENTS"
elif [ "$(printf '%s' "$outl" | wc -l)" -le 1 ] && printf '%s' "$outl" | grep -q 'foo.txt'; then
    ok "ls -l foo.txt prints one long-format line naming the file: $(printf '%s' "$outl" | head -1)"
else
    bad "ls -l foo.txt did not print one line naming the file: '$(printf '%s' "$outl" | head -1)' (rc=$rcl)"
fi

# 2b. THE LONG LINE MUST BE REAL, NOT PLAUSIBLE. I got this wrong while
#     writing the fix: reading `mode` from the wrong offset in the 9P stat
#     record rendered "-rwxr-xrw-" for EVERY file -- 644, 600, 755 and 444
#     alike -- which looks like a mode string and is not one. Two assertions
#     catch it: the mode must CHANGE with the file's real mode, and the
#     single-file line must be byte-identical to the line the DIRECTORY
#     listing prints for the same file, since the two are meant to line up and
#     are produced by different code paths.
printf 'x' >"$W/m600";  chmod 600 "$W/m600"
printf 'x' >"$W/m755";  chmod 755 "$W/m755"
l600="$(cd "$W" && "$BIN" -l m600 2>/dev/null)"
l755="$(cd "$W" && "$BIN" -l m755 2>/dev/null)"
m600col="${l600%%	*}"
m755col="${l755%%	*}"
if [ "$m600col" != "$m755col" ]; then
    ok "the long line reflects the FILE'S OWN mode (600: $m600col / 755: $m755col)"
else
    bad "the long line is identical for a 600 and a 755 file ('$m600col') -- the mode is read from the wrong place, so it is plausible rather than true"
fi
dirline="$(cd "$W" && "$BIN" -l . 2>/dev/null | grep 'm600$' | head -1)"
if [ -n "$dirline" ] && [ "$dirline" = "$l600" ]; then
    ok "and it is byte-identical to the directory listing's line for the same file"
else
    bad "the single-file long line and the directory listing disagree about the same file: '$l600' vs '$dirline'"
fi

# 3. CONTROL -- a DIRECTORY must still list, and both entries must be there.
outd="$(cd "$W" && "$BIN" adir 2>"$W/e3")"; rcd=$?
if printf '%s' "$outd" | grep -q 'inside_a' && printf '%s' "$outd" | grep -q 'inside_b'; then
    ok "CONTROL: ls on a directory still lists its entries"
else
    bad "CONTROL BROKEN: ls on a directory no longer lists it: '$(printf '%s' "$outd" | tr '\n' ' ')' (rc=$rcd)"
fi
outdl="$(cd "$W" && "$BIN" -l adir 2>"$W/e4")"; rcdl=$?
if printf '%s' "$outdl" | grep -q 'inside_a'; then
    ok "CONTROL: ls -l on a directory still lists its entries"
else
    bad "CONTROL BROKEN: ls -l on a directory no longer lists it (rc=$rcdl)"
fi

# 4. CONTROL -- a path that does not exist must FAIL, loudly and non-zero.
outm="$(cd "$W" && "$BIN" no_such_thing 2>"$W/e5")"; rcm=$?
if [ "$rcm" -ne 0 ]; then
    ok "CONTROL: a missing path is an error (rc=$rcm), not a silent success"
else
    bad "CONTROL BROKEN: ls on a missing path exited 0"
fi

echo
echo "ls_regular_file: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || { echo "FAIL ls_regular_file"; exit 1; }
echo "PASS ls_regular_file"
