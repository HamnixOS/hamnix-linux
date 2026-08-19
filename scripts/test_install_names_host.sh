#!/usr/bin/env bash
# scripts/test_install_names_host.sh — FAST, QEMU-free host gate for the names
# an install must refuse (lib/instnames.ad).
#
# THE TWO DEFECTS THIS GATES, both measured in the source of the account
# rewrite and both reachable from a shipped command line:
#
#   1. `install --auto /dev/nvme0n1 --user hostowner` CONVERTED THE MACHINE'S
#      ADMINISTRATOR INTO AN ORDINARY ACCOUNT. user/hlinstall.ad adds the
#      requested name to its DROP list and then writes it at uid 1001 with home
#      /home/<name>, so the uid-1 administrator line is deleted and re-created
#      as a regular user and the machine ends with no owner at all. `sshd`,
#      `hamsh-svc` and `nobody` are equally reachable, and the GUI wizard's
#      only rule was "the field is not empty".
#
#   2. `copy_str()` COPIED UP TO 120 BYTES INTO Array[64, uint8] GLOBALS.
#      `user_buf` and `hostname_buf` are 64 bytes and copy_str stopped at 120
#      SOURCE bytes however big the destination was, so
#      `install --auto ... --user <65+ chars>` overran the adjacent global --
#      on that command line, the password buffers. CLI only: the GUI field caps
#      at 30.
#
# WHAT THIS GATE IS AND IS NOT. It RUNS the rule both front ends call, against
# real strings, on the dev host. It does NOT prove that a machine refuses the
# install -- that is tests/linux/install_refuses_reserved.sh, which boots a
# medium and points the installer at a blank disk. The static wiring checks at
# the end are named as static.
#
# Pass marker: RESULT: PASS

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/instnames_host"
mkdir -p "$OUT"
fail=0
# The counters are here so scripts/release_gates.sh can SCORE this gate rather
# than report it UNSCORABLE. See the note in test_de_home_resolve_host.sh.
NPASS=0; NFAIL=0
pass() { NPASS=$((NPASS+1)); echo "[instnames] PASS $*"; }
bad()  { NFAIL=$((NFAIL+1)); echo "[instnames] FAIL $*" >&2; fail=1; }

echo "[instnames] compiling host harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux tests/instnames_host.ad "$BIN" 2>"$OUT/instnames_compile.log"; then
    echo "[instnames] FAIL: host harness did not compile"
    cat "$OUT/instnames_compile.log"; echo "[instnames] RESULT: FAIL"; exit 1
fi
pass "host harness compiled -> $BIN"

DUMP="$OUT/instnames_dump.txt"
if ! "$BIN" >"$DUMP" 2>&1; then
    echo "[instnames] FAIL: host harness exited non-zero"; cat "$DUMP"
    echo "[instnames] RESULT: FAIL"; exit 1
fi
echo "[instnames] ---- rule output ----"
cat "$DUMP"
echo "[instnames] ---------------------"

assert_grep() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMP"; then pass "$msg"; else
        bad "$msg (missing: $pat)"; fi
}

# --- 1. the reserved names, one assertion each ----------------------------
for n in hostowner sshd hamsh-svc nobody root; do
    assert_grep "^NAME $n reserved=1 ok=0$" \
        "an install refuses to create an account called '$n'"
done

# --- 2. THE CONTROL, AND IT RUNS ------------------------------------------
# A rule that refuses everything refuses nothing in particular. Ordinary names
# must still be accepted, or the five assertions above are satisfied by a
# function that returns 1.
for n in dave hamdocusr live; do
    assert_grep "^NAME $n reserved=0 ok=1$" \
        "…and an ordinary name like '$n' is still accepted"
done

# --- 3. the match is EXACT ------------------------------------------------
# A substring rule would refuse 'hostowners' and 'myroot', which are perfectly
# good account names, and a person told "that name is reserved" about one of
# them would have no idea why.
for n in hostowners myroot hostowne; do
    assert_grep "^NAME $n reserved=0 ok=1$" \
        "the match is exact, not a substring: '$n' is accepted"
done

# --- 4. the empty name ----------------------------------------------------
assert_grep '^NAME  reserved=0 ok=0$' \
    "an empty name is still refused (the wizard's original rule, kept)"

# --- 5. THE LENGTH RULE, which is the copy_str overrun --------------------
# user_buf/hostname_buf are Array[64, uint8]: 63 bytes plus a NUL is the whole
# of what fits, so 63 is the last accepted length and 64 is the first refused.
assert_grep '^LEN63 len=63 ok=1$' \
    "a 63-byte name FITS the installer's 64-byte buffer and is accepted"
assert_grep '^LEN64 len=64 ok=0$' \
    "a 64-byte name does NOT fit (63 bytes plus the NUL is the whole buffer) and is refused"
assert_grep '^LEN65 len=65 ok=0$' \
    "KEYSTONE: the 65-character --user that used to overrun the adjacent global is refused"
assert_grep '^LEN120 len=120 ok=0$' \
    "…and so is the 120-byte one the old copy_str would have written in full"
assert_grep '^IN_NAME_MAX=63$' \
    "the limit is stated as a constant both front ends read, not a number in two places"
assert_grep '^INSTNAMES_HOST_DONE$' "the harness ran to completion"

# --- 6. BOTH FRONT ENDS ACTUALLY CALL IT ----------------------------------
# STATIC, and said to be static: a rule nothing calls is not a rule. The
# end-to-end measurement is tests/linux/install_refuses_reserved.sh.
for f in user/hlinstall.ad user/haminstallui.ad; do
    if grep -q 'from lib.instnames import' "$f"; then
        pass "$f imports the shared rule (static check)"
    else
        bad "$f does not import lib/instnames.ad -- it has its own idea of which names are allowed"
    fi
    if grep -q 'in_name_is_reserved\|in_name_ok' "$f"; then
        pass "$f calls it (static check)"
    else
        bad "$f imports the rule and never asks it"
    fi
done

printf '\n%d PASSED, %d FAILED\n' "$NPASS" "$NFAIL"
if [ "$fail" -eq 0 ]; then
    echo "[instnames] RESULT: PASS"
    exit 0
fi
echo "[instnames] RESULT: FAIL" >&2
exit 1
