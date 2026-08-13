#!/usr/bin/env bash
# tests/linux/ssh_fieldbound.sh — THE BOUND BETWEEN A PEER'S uint32 AND AN
# 8192-BYTE ARRAY, TESTED AS user/sshd.ad ACTUALLY DEFINES IT.
#
# WHAT IS UNDER TEST
# ==================
# user/sshd.ad's USERAUTH parse used to walk `p = p + 4 + len` three times with
# `len` read straight from the packet and nothing comparing `p` to anything, so
# a peer setting the first length near 0xFFFFFFFF moved the next read about
# four gigabytes past pkt_in -- BEFORE AUTHENTICATION. `_field_at` is the check
# that now sits at every one of those advances, and at CHANNEL_DATA, where the
# same unchecked length used to copy adjacent process memory into the session's
# stdin.
#
# WHY THIS SCRIPT EXISTS AND NOT JUST THE .ad FILE
# ================================================
# tests/test_ssh_fieldbound.ad was written for that fix and reported 6/6. Two
# things made that reassurance hollow, and both were measured:
#
#   1. NOTHING RAN IT. It appeared in no manifest, no dispatcher, no script --
#      only inside itself. A gate a person has to remember to type is not a
#      gate. This script is registered in scripts/ci_battery_manifest.txt.
#
#   2. WORSE, IT TESTED A COPY. It re-declared `_field_at` in its own body,
#      byte-for-byte, under a comment promising the two matched. Delete the
#      real predicate and the copy still answered every case correctly: the
#      gate stays green while the pre-auth read comes back. A test that
#      carries its own copy of the code it tests cannot detect the code
#      changing.
#
# HOW THE FIXTURE REACHES THE REAL PREDICATE
# ==========================================
# tests/test_ssh_fieldbound.ad now says `from user.sshd import _field_at`. That
# compiles -- module-private (leading-underscore) names are per-module mangled,
# not hidden, and an import resolves them -- but it does NOT link, because sshd
# is an APPLICATION: merging it into a test fixture yields two `@main` and
# clang refuses ("invalid redefinition of function 'main'").
#
# So this gate builds the fixture in a MIRROR of the project root: every
# top-level entry symlinked, except `user/`, which is a directory of symlinks
# in which `sshd.ad` is a copy whose SOLE difference from the real file is that
# `def main() -> int32:` has been renamed. Every other byte -- `_field_at`
# included -- is the shipped source, and the mirror is rebuilt from it on every
# run. host_ac resolves imports as plain relative paths against its CWD (see
# drv_resolve_module in adder/compiler/fused_driver_host_main.ad), which is
# what makes the mirror work at all.
#
# THE ONE-LINE DIFFERENCE IS ITSELF ASSERTED, below, because "a copy that is
# promised to match" is the exact failure this gate was written to end. If the
# copy ever differs by more than that single `def main` line, the gate fails
# instead of testing something that is not what ships.
#
# PROVEN RED (2026-08-12) by breaking the real user/sshd.ad in a worktree and
# running this gate against it. Three mutations, three different reds:
#
#   * `_field_at` DELETED (the whole def) -> assertion 1: "user/sshd.ad no
#     longer defines _field_at (found 0 definitions)", gate 0 passed / 1
#     failed, exit 1. And the grep is only the readable half: with assertion 1
#     bypassed the BUILD fails too --
#         /usr/bin/ld: undefined reference to `_field_at'
#         clang-19: error: linker command failed with exit code 1
#     which is the proof the fixture is bound to the shipped symbol and not to
#     a copy of it.
#
#   * THE BOUND WEAKENED: `if off + 4 + ln > limit:` -> `> limit + 4096:`.
#     Builds, runs, and the fixture reports 5 passed / 1 failed --
#     "one byte past the end was accepted -- off by one". Gate 4/4, exit 1.
#     (Only one case moves: the separate `ln > limit` check still catches the
#     100-byte and 0xFFFFFFFF lengths. One is enough; it is the boundary.)
#
#   * EVERY `return -1` IN THE PREDICATE CHANGED TO `return 0` (it accepts
#     everything): fixture 2 passed / 4 failed, including "0xFFFFFFFF was
#     ACCEPTED -- this is the pre-auth read". Gate 4/4, exit 1.
#
# The real user/sshd.ad is unchanged in the commit that lands this; the
# mutations were reverted with `git checkout` after each measurement.
#
# WHY THE ARITHMETIC AND NOT A CRAFTED PACKET. Every `_field_at` call site sits
# behind key exchange, and the USERAUTH ones behind an authenticated session --
# the packets are ENCRYPTED, so no black-box probe reaches the arithmetic. What
# CAN be driven end to end against a real sshd is the identification exchange,
# and that is covered next door in tests/linux/net_accept_servers.sh (the
# 255-byte banner clamp and the injection it allowed).
#
# Costs: one host_ac + clang build of sshd and the fixture (~1 min cold, no
# QEMU, no network, no namespace), then a program that runs in milliseconds.
# Everything is written under $HOME/.hamnix-build/, nothing under build/.
#
# Usage: bash tests/linux/ssh_fieldbound.sh
#   Env: ADDER_HOST_AC   host_ac.elf to build with (default: build/cutover)
#        SSHFB_DIR       private work dir (default: $HOME/.hamnix-build/...)
#        SSHFB_KEEP=1    keep the mirror and logs on exit
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT" || exit 1

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL $*"; }
note() { echo "  --   $*"; }
report() {
    echo "ssh_fieldbound gate: $PASS passed, $FAIL failed"
    [ "$FAIL" -eq 0 ]
}

SRC=user/sshd.ad
FIXTURE=tests/test_ssh_fieldbound.ad

# Private build tree: nothing under the shared build/ is written.
KEY="$(printf '%s' "$PROJ_ROOT" | sha256sum | cut -c1-12)"
W="${SSHFB_DIR:-$HOME/.hamnix-build/ssh_fieldbound.$KEY}"
M="$W/mirror"
rm -rf "$M"
mkdir -p "$W" "$M" || exit 1
cleanup() { [ "${SSHFB_KEEP:-0}" = 1 ] || rm -rf "$M"; }
trap cleanup EXIT

# ---------------------------------------------------------------- 1. it exists
# The deletion arm, named. Without this the same defect still fails the build,
# but with a link error nobody can read.
if [ ! -f "$SRC" ] || [ ! -f "$FIXTURE" ]; then
    bad "$SRC or $FIXTURE is missing"
    report; exit 1
fi
ndef="$(grep -c '^def _field_at(' "$SRC")"
if [ "$ndef" = "1" ]; then
    ok "user/sshd.ad defines _field_at, and this gate compiles THAT definition"
else
    bad "user/sshd.ad no longer defines _field_at (found $ndef definitions)."
    note "The pre-auth bound is the subject of this gate. If the predicate was"
    note "renamed, rename it in $FIXTURE's import too and here."
    report; exit 1
fi
nimp="$(grep -c '^from user.sshd import _field_at$' "$FIXTURE")"
if [ "$nimp" = "1" ]; then
    ok "the fixture IMPORTS it (it does not carry a copy)"
else
    bad "$FIXTURE does not import _field_at from user.sshd -- it is testing"
    note "something other than the code that ships. That is the whole defect"
    note "this gate replaced."
    report; exit 1
fi
if grep -qE '^def _field_at\(' "$FIXTURE"; then
    bad "$FIXTURE declares its own _field_at again. A test that carries a copy"
    note "of the code it tests cannot detect the code changing."
    report; exit 1
fi

# ------------------------------------------------------------- 2. the mirror
for e in "$PROJ_ROOT"/*; do
    b="$(basename "$e")"
    [ "$b" = "user" ] && continue
    ln -s "$e" "$M/$b" || { bad "could not build the mirror at $M"; report; exit 1; }
done
mkdir -p "$M/user"
for f in "$PROJ_ROOT"/user/*; do
    ln -s "$f" "$M/user/$(basename "$f")"
done
rm -f "$M/user/sshd.ad"

nmain="$(grep -c '^def main() -> int32:$' "$SRC")"
if [ "$nmain" != "1" ]; then
    bad "expected exactly one 'def main() -> int32:' in $SRC, found $nmain --"
    note "the entry point's signature changed, so the rename below would be a"
    note "no-op and the build would fail on a duplicate main. Update the"
    note "pattern in this gate."
    report; exit 1
fi
sed 's/^def main() -> int32:$/def _sshd_main_not_under_test() -> int32:/' \
    "$SRC" > "$M/user/sshd.ad"

# THE COPY IS ITSELF ASSERTED. Exactly one line may differ, and it must be the
# entry point. Anything else and the gate is testing a fork of sshd.
diff "$SRC" "$M/user/sshd.ad" > "$W/sshd.diff"
nold="$(grep -c '^< ' "$W/sshd.diff")"
nnew="$(grep -c '^> ' "$W/sshd.diff")"
oldline="$(grep '^< ' "$W/sshd.diff")"
if [ "$nold" = "1" ] && [ "$nnew" = "1" ] && \
   [ "$oldline" = "< def main() -> int32:" ]; then
    ok "the compiled sshd differs from the shipped one in ONE line: its 'main'"
else
    bad "the sshd copy differs from $SRC by more than the entry-point rename"
    note "($nold removed / $nnew added lines -- see $W/sshd.diff). The gate"
    note "refuses to report on a fork of the file it claims to test."
    report; exit 1
fi

# ----------------------------------------------------------- 3. the compiler
if [ -z "${ADDER_HOST_AC:-}" ]; then
    ADDER_HOST_AC="$PROJ_ROOT/build/cutover/host_ac_llvm.elf"
    [ -x "$ADDER_HOST_AC" ] || ADDER_HOST_AC="$PROJ_ROOT/build/cutover/host_ac.elf"
fi
if [ ! -x "$ADDER_HOST_AC" ]; then
    echo "[sshfb] no host_ac.elf yet; bootstrapping the Adder compiler"
    # shellcheck source=../../scripts/_adder_cc.sh
    source "$PROJ_ROOT/scripts/_adder_cc.sh"
    adder_cc_bootstrap || { bad "could not bootstrap host_ac.elf"; report; exit 1; }
    ADDER_HOST_AC="$PROJ_ROOT/build/cutover/host_ac.elf"
fi
export ADDER_HOST_AC

# -------------------------------------------------------------- 4. the build
ELF="$W/ssh_fieldbound.elf"
rm -f "$ELF"
echo "[sshfb] building $FIXTURE against the real user/sshd.ad -> $ELF"
nice -n 15 bash "$M/scripts/hamlinux_build.sh" "$FIXTURE" "$ELF" \
    > "$W/build.log" 2>&1
brc=$?
if [ "$brc" = "0" ] && [ -x "$ELF" ]; then
    ok "the fixture links against user/sshd.ad's own _field_at"
else
    bad "the build failed (exit $brc) -- see $W/build.log"
    tail -20 "$W/build.log"
    report; exit 1
fi

# ---------------------------------------------------------------- 5. the run
OUT="$W/run.log"
timeout 60 "$ELF" > "$OUT" 2>&1
rrc=$?
echo "[sshfb] --- fixture output ---"
cat "$OUT"
echo "[sshfb] --- end output ---"

nok="$(grep -c '^  ok   ' "$OUT")"
nbadl="$(grep -c '^  FAIL ' "$OUT")"
if [ "$nbadl" = "0" ]; then
    ok "no assertion in the fixture failed"
else
    bad "$nbadl assertion(s) in the fixture FAILED -- the bound in"
    note "user/sshd.ad does not hold. Lines above."
fi
if [ "$nok" = "6" ]; then
    ok "all 6 bound cases ran (0xFFFFFFFF, exact fit, +1, past-packet,"
    note "     truncated prefix, empty field)"
else
    bad "expected 6 passing cases, saw $nok -- the fixture did not run to the"
    note "end, or its case list changed without this gate being told"
fi
if [ "$rrc" = "0" ]; then
    ok "the fixture exited 0"
else
    bad "the fixture exited $rrc"
fi
if grep -q '^ssh_fieldbound: 6 passed, 0 failed$' "$OUT"; then
    ok "and said so itself: 6 passed, 0 failed"
else
    bad "the fixture's own summary line is missing or not 6 passed, 0 failed"
fi

report
