#!/bin/bash
# wallpaper_apply_honest.sh — nobody prints "wallpaper applied" over a write
# they never looked at.
#
# WHAT THIS GATE IS. It is a SOURCE gate. It reads .ad files and asserts a
# structural property; it does not boot anything, does not start a window
# server, and therefore PROVES NOTHING ABOUT WHETHER A WALLPAPER ACTUALLY
# APPEARS. It proves exactly one thing: that every program which can print
# "wallpaper applied" first tested the write that was supposed to apply it.
# That is worth a gate on its own, because the failure it guards is invisible
# by construction — the whole symptom is a message saying it worked.
#
# WHY IT EXISTS. user/linux-wsys.c's ctl_global() was changed from void to
# returning -1 specifically so a verb it cannot route can be REFUSED, and its
# comment names the motivating case: "hamctl would print 'wallpaper applied'
# over a write that went nowhere." The kernel side learned to say no. On
# 2026-08-17 I checked who listens, and found:
#
#   * user/hamctl.ad      — looks at the write. Fixed when ctl_global was.
#   * user/hamsettings.ad — DID NOT. Same verb, same sink, same success
#                           message, and its _writeall() was void, did one
#                           sys_write, and discarded the result.
#
# So the refusal was implemented, delivered, and thrown away by the second of
# the two programs that provoke it. A fix applied to one of two twins is the
# shape this gate exists to catch, and it will catch a third twin too.
#
# NEGATIVE CONTROL is mandatory and runs every time: a copy of each file is
# reverted to the unchecked form and the same assertions must go RED. A gate
# that has never been seen to fail is not evidence.
set -u
cd "$(dirname "$0")/../.." || exit 1

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   — $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL — $1"; }

# Every .ad that can print the success line. Discovered, not hardcoded, so a
# new program that copies the pattern is covered the day it lands.
# ANCHOR ON THE PRINT, NOT ON THE PHRASE. The first draft of this gate searched
# for the bare text "wallpaper applied" and landed, in BOTH files, on a COMMENT
# that quotes the message while explaining the bug — 40 lines above the code it
# meant to examine. It reported six failures, four of them against a fix that
# was already in the file. The instrument was wrong, not the tree. So: require
# the phrase to appear inside a write to fd 1, which is a statement and cannot
# be prose.
PRINT_RE='_writeall\(1,.*wallpaper applied'
mapfile -t CLAIMANTS < <(grep -rlE "$PRINT_RE" --include='*.ad' user/ lib/ 2>/dev/null | sort)

echo "== programs that can print \"wallpaper applied\": ${#CLAIMANTS[@]}"
printf '   %s\n' "${CLAIMANTS[@]}"

# THE INSTRUMENT MUST BE SHOWN ABLE TO PRODUCE A NON-EMPTY RESULT. An empty
# list here would sail through every loop below and report a clean sweep, which
# is the exact success-shaped answer this tree keeps paying for.
if [ "${#CLAIMANTS[@]}" -lt 2 ]; then
    bad "found ${#CLAIMANTS[@]} claimant(s); expected at least 2 (hamctl and hamsettings). Either the search is broken or a program stopped reporting at all — both are failures."
    echo "== $PASS passed, $FAIL failed"; exit 1
fi
ok "the search finds ${#CLAIMANTS[@]} claimants, so an empty sweep below would be a real result and not a broken grep"

# ---------------------------------------------------------------------------
# assert_checked <file> <label>
#
# Within the ~40 lines leading up to the success print, require BOTH:
#   (a) the ctl write's result is bound to a name — a bare `_writeall(fd, ...)`
#       or `sys_write(fd, ...)` as a statement is the bug, and
#   (b) a guard that can take the failure path, printing a message that does
#       NOT claim success.
# ---------------------------------------------------------------------------
assert_checked() {
    local f="$1" label="$2" ctx
    ctx=$(grep -nE "$PRINT_RE" "$f" | head -1 | cut -d: -f1)
    if [ -z "$ctx" ]; then bad "$label: no success print found to test"; return; fi
    local from=$(( ctx > 40 ? ctx - 40 : 1 ))
    local win; win=$(sed -n "${from},${ctx}p" "$f")

    if printf '%s' "$win" | grep -qE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*:[[:space:]]*int(32|64)[[:space:]]*=[[:space:]]*(_writeall|sys_write)\('; then
        ok "$label: the ctl write's result is BOUND to a name"
    else
        bad "$label: the write that is supposed to apply the wallpaper is called as a bare statement — its return value cannot be examined because it was never kept"
    fi

    if printf '%s' "$win" | grep -qE '^[[:space:]]*if[[:space:]].*(!=|<)[[:space:]]*' && \
       printf '%s' "$win" | grep -qiE 'NOT applied|FAIL wallpaper'; then
        ok "$label: a guard exists that reports failure WITHOUT claiming success"
    else
        bad "$label: nothing between the write and the success message can divert to a failure report"
    fi
}

echo "== each claimant tests its write"
for f in "${CLAIMANTS[@]}"; do assert_checked "$f" "$(basename "$f")"; done

# ---------------------------------------------------------------------------
# _writeall must mean "write ALL", in every file that defines one.
# A single sys_write reports a SHORT write as success, and a truncated verb
# line is a verb the parser never sees — indistinguishable from a refusal.
# ---------------------------------------------------------------------------
echo "== _writeall loops and reports, rather than writing once and hoping"
for f in "${CLAIMANTS[@]}"; do
    b=$(basename "$f")
    if ! grep -qE '^def _writeall\(' "$f"; then
        ok "$b: defines no _writeall of its own (nothing to assert)"
        continue
    fi
    body=$(sed -n "/^def _writeall(/,/^[^ \t]/p" "$f")
    if printf '%s' "$body" | grep -qE '^def _writeall\(.*\)[[:space:]]*->[[:space:]]*int32'; then
        ok "$b: _writeall returns a value a caller can test"
    else
        bad "$b: _writeall is void — a refusal and a short write are both silently indistinguishable from success at EVERY one of its call sites, not just the wallpaper one"
    fi
    if printf '%s' "$body" | grep -qE '^[[:space:]]*while '; then
        ok "$b: _writeall actually loops until every byte is written"
    else
        bad "$b: _writeall does one sys_write and calls it 'all' — a short write is reported as success"
    fi
done

# ---------------------------------------------------------------------------
# NEGATIVE CONTROL. Revert a copy to the unchecked form; the assertions above
# must go RED. Run against a scratch copy — the real tree is never touched.
# ---------------------------------------------------------------------------
echo "== negative control: the same assertions against the OLD, unchecked code"
NEG=$(mktemp -d); trap 'rm -rf "$NEG"' EXIT
mkdir -p "$NEG/user"
cat > "$NEG/user/regressed.ad" <<'OLDEOF'
def _writeall(fd: int32, s: Ptr[uint8]):
    sys_write(fd, s, _slen(s))


def _apply_wallpaper(i: uint64):
    fd: int32 = sys_open_write(cast[Ptr[char]]("/dev/wsys/ctl"))
    if fd < 0:
        return
    _writeall(fd, cast[Ptr[uint8]]("wallpaper /tmp/hamnix-wallpaper.ppm\n"))
    sys_close(fd)
    _writeall(1, cast[Ptr[uint8]]("[x] wallpaper applied\n"))
OLDEOF

NEG_FAILS=0
nbad() { NEG_FAILS=$((NEG_FAILS+1)); }
nf="$NEG/user/regressed.ad"
nctx=$(grep -nE "$PRINT_RE" "$nf" | head -1 | cut -d: -f1)
nwin=$(sed -n "1,${nctx}p" "$nf")
printf '%s' "$nwin" | grep -qE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*:[[:space:]]*int(32|64)[[:space:]]*=[[:space:]]*(_writeall|sys_write)\(' || nbad
{ printf '%s' "$nwin" | grep -qiE 'NOT applied|FAIL wallpaper'; } || nbad
nbody=$(sed -n "/^def _writeall(/,/^[^ \t]/p" "$nf")
printf '%s' "$nbody" | grep -qE '^def _writeall\(.*\)[[:space:]]*->[[:space:]]*int32' || nbad
printf '%s' "$nbody" | grep -qE '^[[:space:]]*while ' || nbad

if [ "$NEG_FAILS" -eq 4 ]; then
    ok "negative control: 4 of 4 assertions FAILED against the old code, so all four can fail"
else
    bad "negative control: only $NEG_FAILS of 4 assertions failed against code known to be broken — the ones that passed are not measuring anything"
fi

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
