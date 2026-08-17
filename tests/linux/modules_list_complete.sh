#!/bin/bash
#
# modules_list_complete.sh — the module list must be read whole, and a list
# that does not fit must SAY SO.
#
# WHAT WAS WRONG. user/linuxinit.ad's load_modules() did ONE
# sys_read(fd, &modlist[0], 8192) and treated the result as the whole file.
# Two ways to lose modules without a word:
#
#   * A SHORT READ. read(2) on a regular file may return less than asked; every
#     byte after the first return simply was not there.
#   * OVERFLOW. On 2026-08-17 /etc/modules in the built image was 6018 bytes of
#     that 8192-byte buffer — 2174 to spare — WITH THE WHOLE SOF AUDIO STACK ON
#     THE LAST LINES. One more driver family and sound disappears from a freshly
#     written medium, days after a release whose headline was that sound finally
#     had its modules.
#
# And in both cases the boot printed "linuxinit: loaded N kernel modules" — a
# sentence identical whether the list held N or N+2. THE LOG COULD NOT SHOW A
# LOSS. That is this tree's recurring failure exactly: a gap answering something
# success-shaped instead of the truth.
#
# WHAT THIS GATE CHECKS: the read loops; overflow is reported; the count names
# both loaded AND listed; and the real /etc/modules has headroom, measured
# against the actual buffer size parsed out of the source rather than a number
# copied into this script that could drift away from it.
#
# WHAT IT DOES NOT CHECK: no machine is booted and no module is loaded. That the
# warning appears on a real overflow is NOT established here — the gate proves
# the code says it, not that a boot prints it.
set -u
cd "$(dirname "$0")/../.." || exit 1

SRC=user/linuxinit.ad
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   — $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL — $1"; }

[ -f "$SRC" ] || { echo "  FAIL — no $SRC"; exit 1; }

BODY=$(sed -n '/^def load_modules(/,/^def /p' "$SRC")
if [ -z "$BODY" ]; then
    bad "could not read load_modules() — the instrument failed, so nothing below would mean anything and it is NOT being reported as clean"
    echo "== $PASS passed, $FAIL failed"; exit 1
fi
ok "INSTRUMENT: load_modules() extracted, $(printf '%s' "$BODY" | wc -l) lines — a non-empty body, so an absent pattern below is a measurement"

# --- the read loops ------------------------------------------------------
if printf '%s' "$BODY" | grep -qE 'while total < [0-9]+:' && \
   printf '%s' "$BODY" | grep -qE 'sys_read\(fd, &modlist\[total\]'; then
    ok "the read LOOPS and appends at the current offset, so a short read cannot end the file early"
else
    bad "the module list is read with a single sys_read whose result is taken as the whole file — a short read silently drops every module after it"
fi

# --- overflow is reported ------------------------------------------------
if printf '%s' "$BODY" | grep -qiE 'if total >= [0-9]+:' && \
   printf '%s' "$BODY" | grep -qi 'TRUNCATED'; then
    ok "a list that fills the buffer is reported as possibly truncated, by name, on fd 2"
else
    bad "a module list that fills the buffer is accepted in silence: the modules past the cap are never loaded and nothing says so, and the hardware they drive just appears missing"
fi

# --- the count cannot hide a loss ---------------------------------------
if printf '%s' "$BODY" | grep -q 'kernel modules listed' && \
   printf '%s' "$BODY" | grep -q 'loaded != seen'; then
    ok "the boot line reports loaded AND listed, and a shortfall gets its own warning — so the log can show a loss"
else
    bad "the boot prints only how many modules loaded, which is the same sentence whether the list held that many or more — the log cannot show a loss"
fi

# --- headroom, measured against the buffer the SOURCE declares -----------
# NOT against a number written into this gate. A constant copied here would
# drift from the source and then this check would be measuring its own past.
CAP=$(grep -oE '^modlist:[[:space:]]*Array\[[0-9]+' "$SRC" | grep -oE '[0-9]+$')
if [ -z "$CAP" ]; then
    bad "cannot parse the modlist buffer size out of $SRC — refusing to judge headroom against a guess"
else
    ok "the buffer is $CAP bytes, read from the source declaration"
    FOUND=0
    for m in build/image/root/etc/modules etc/modules; do
        [ -f "$m" ] || continue
        FOUND=1
        SZ=$(wc -c < "$m")
        LINES=$(grep -cvE '^[[:space:]]*(#|$)' "$m" || true)
        if [ "$SZ" -lt "$CAP" ]; then
            ok "$m is $SZ bytes of $CAP ($((CAP - SZ)) spare, $LINES module lines) — it fits"
        else
            bad "$m is $SZ bytes and the buffer is $CAP: modules past the cap are NOT being loaded on any machine built from this tree"
        fi
    done
    if [ "$FOUND" = 0 ]; then
        # An absent file is not a pass. It is an unrun check.
        bad "no /etc/modules found in the built image or the tree, so headroom was NOT measured — build the image and re-run rather than reading this as fitting"
    fi
fi

# --- negative control, RUN ----------------------------------------------
echo "== negative control: the same assertions against the OLD single-read form"
NEG=$(mktemp -d); trap 'rm -rf "$NEG"' EXIT
cat > "$NEG/old.ad" <<'OLDEOF'
def load_modules():
    fd: int32 = sys_open(cast[Ptr[char]]("/etc/modules"))
    if fd < 0:
        return
    n: int64 = sys_read(fd, &modlist[0], 8192)
    sys_close(fd)
    if n <= 0:
        return
    total: uint64 = cast[uint64](n)
    write_cstr(1, "linuxinit: loaded ")
    put_dec(cast[uint64](loaded))
    write_cstr(1, " kernel modules\n")


def put_dec(v: uint64):
OLDEOF
NB=$(sed -n '/^def load_modules(/,/^def /p' "$NEG/old.ad")
NEG_FAILS=0
printf '%s' "$NB" | grep -qE 'while total < [0-9]+:' || NEG_FAILS=$((NEG_FAILS+1))
printf '%s' "$NB" | grep -qi 'TRUNCATED'                || NEG_FAILS=$((NEG_FAILS+1))
printf '%s' "$NB" | grep -q  'loaded != seen'           || NEG_FAILS=$((NEG_FAILS+1))
if [ "$NEG_FAILS" -eq 3 ]; then
    ok "negative control: 3 of 3 assertions FAILED against the old code, so all three can fail"
else
    bad "negative control: only $NEG_FAILS of 3 failed against code known to be broken — the ones that passed are not measuring anything"
fi

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
