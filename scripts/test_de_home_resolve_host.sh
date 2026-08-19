#!/usr/bin/env bash
# scripts/test_de_home_resolve_host.sh — FAST, QEMU-free host gate for the
# shared home-directory resolver (lib/homedir.ad).
#
# THE BUG THIS GATES (USER report): "the /home/<username>/Desktop does not
# seem to reflect the GUI desktop background."
#
# hamdesktop resolves its icon source as <home>/Desktop and watches that
# directory on a ~1s timer. The watcher was fine; the DIRECTORY was wrong.
# The old chain was $HOME then a hardcoded /home/live — and DE clients are
# spawned by the COMPOSITOR, which gives them no HOME at all (probed on a real
# boot: `cat /env/HOME` -> "file does not exist"), so the hardcode ALWAYS won.
# On the live image `live` IS the session user, so it looked right. On an
# INSTALLED system the user is whatever the installer wizard named them, so
# the GUI desktop watched a directory that was not theirs and nothing the user
# created in their real ~/Desktop ever appeared.
#
# The fix routes resolution through /etc/passwd BY UID. That step can only be
# proven deterministically against a uid that is NOT the live image's 1001 —
# which is what this gate does, with no install and no QEMU: it runs
# hd_parse_passwd_home over a synthetic passwd table and asserts the home
# returned for each uid, including an installed-style account.
#
# Pass marker: RESULT: PASS

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/homedir_host"
mkdir -p "$OUT"
fail=0
# THE COUNTERS EXIST SO A RELEASE DRIVER CAN SCORE THIS GATE. Without a summary
# line in a dialect scripts/release_gates.sh knows, run_gate reports it
# UNSCORABLE -- which is neither a pass nor a zero, and is exactly the state
# that let a gate scoring 8/0 be recorded as 0.
NPASS=0; NFAIL=0
pass() { NPASS=$((NPASS+1)); echo "[homedir] PASS $*"; }
bad()  { NFAIL=$((NFAIL+1)); echo "[homedir] FAIL $*" >&2; fail=1; }

# --- 1. the resolver is wired into the desktop ----------------------------
# A green parser that nothing calls is not a fix. hamdesktop MUST resolve its
# desktop dir through the shared resolver, and must no longer carry its own
# $HOME-only chain.
if grep -q 'from lib.homedir import' user/hamdesktop.ad \
        && grep -q 'hd_resolve_home' user/hamdesktop.ad; then
    pass "hamdesktop resolves its desktop dir through lib/homedir.ad"
else
    bad "hamdesktop does not use the shared home resolver"
fi

# --- 2. host unit test compiles + runs ------------------------------------
echo "[homedir] compiling host harness for x86_64-linux ..."
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"
if ! adder_bin x86_64-linux tests/homedir_host.ad "$BIN" 2>"$OUT/homedir_compile.log"; then
    echo "[homedir] FAIL: host harness did not compile"
    cat "$OUT/homedir_compile.log"; echo "[homedir] RESULT: FAIL"; exit 1
fi
pass "host harness compiled -> $BIN"

DUMP="$OUT/homedir_dump.txt"
if ! "$BIN" >"$DUMP" 2>&1; then
    echo "[homedir] FAIL: host harness exited non-zero"; cat "$DUMP"
    echo "[homedir] RESULT: FAIL"; exit 1
fi
echo "[homedir] ---- resolver output ----"
cat "$DUMP"
echo "[homedir] -------------------------"

assert_grep() {
    local pat="$1" msg="$2"
    if grep -Eq -- "$pat" "$DUMP"; then pass "$msg"; else
        bad "$msg (missing: $pat)"; fi
}

# The live image's user — the ONLY case the old hardcode got right.
assert_grep '^LIVE uid=1001 len=10 home=/home/live$' \
    "uid 1001 (live) resolves to /home/live"
# THE USER-REPORTED CASE: an installed system's wizard account MUST resolve to
# ITS OWN home, never to /home/live.
assert_grep '^INSTALLED uid=1002 len=11 home=/home/bobby$' \
    "KEYSTONE: an installed user's uid resolves to THEIR home, not /home/live"
assert_grep '^REGULAR uid=1000 len=10 home=/home/dave$' \
    "uid 1000 resolves to /home/dave"
assert_grep '^HOSTOWNER uid=1 len=15 home=/home/hostowner$' \
    "the hostowner uid resolves to /home/hostowner"
# An unknown uid must resolve to NOTHING so the caller can fall back — it must
# never silently borrow a neighbouring line's home.
assert_grep '^UNKNOWN uid=4242 len=0 home=<none>$' \
    "an unknown uid resolves to nothing (caller falls back)"
assert_grep '^NOBODY uid=65534 len=12 home=/nonexistent$' \
    "the parser is uid-exact (nobody returns its own field)"

# The DE does NOT run as the desktop's user: the scene DE is spawned down the
# boot path as hostowner (uid 1), so hamdesktop enumerates the REGULAR
# accounts and takes the first whose ~/Desktop is really there. Prove the
# enumeration's order and membership.
assert_grep '^REG0 idx=0 len=10 home=/home/dave$' \
    "regular-account enumeration starts at uid 1000 (dave), skipping hostowner"
assert_grep '^REG1 idx=1 len=10 home=/home/live$' \
    "…then the live image's user, which is where its ~/Desktop actually is"
assert_grep '^REG2 idx=2 len=11 home=/home/bobby$' \
    "…then the installed-style account"
assert_grep '^REG3 idx=3 len=12 home=/nonexistent$' \
    "…then nobody, which the caller's exists-check rejects"
assert_grep '^REG4 idx=4 len=0 home=<none>$' \
    "the enumeration terminates (no phantom accounts)"
# THE USER'S SYSTEM: an installed /etc/passwd has ONE regular user and no
# `live` at all, so the first candidate is the wizard's account.
assert_grep '^INSTALLED_REG0 len=11 home=/home/gizmo$' \
    "KEYSTONE: on an INSTALLED passwd the first regular account is the wizard's user"

# ---- hd_home_join, RUN rather than read -----------------------------------
# The three office apps (hamwrite / hamsheet / hamslides) used to carry the
# literal "/home/live/Documents/..." and now call hd_home_join(). This is the
# run-time evidence that the join works and that its string literals are not
# NULL at run time -- a real hazard on this backend, where a GLOBAL
# initialised with a string literal compiles cleanly and is null when it runs.
# The VALUE is the host's own home, so only the SHAPE is asserted.
assert_grep '^JOINDOC len=[0-9]+ path=/[^ ]*/Documents/untitled\.hdoc$' \
    "hd_home_join returns an absolute <home>/Documents/untitled.hdoc"
assert_grep '^JOINSHEET len=[0-9]+ path=/[^ ]*/Documents/untitled\.hsheet$' \
    "…and the spreadsheet's extension the same way"
if grep -Eq '^JOINDOC len=0 ' "$DUMP"; then
    bad "hd_home_join returned NOTHING on this host -- it resolved no home at all"
else
    pass "hd_home_join resolved a non-empty path (its literals are not null at run time)"
fi
# A buffer too small must REFUSE. A truncated path is a valid-looking path
# that writes the document into the wrong file.
assert_grep '^JOINTINY len=0 path=<none>$' \
    "hd_home_join REFUSES a buffer too small instead of truncating the path"

# ---- the three office apps really call it ---------------------------------
# Static, and said to be static: this is a wiring check, not a measurement of
# where the programs write. That measurement is
# tests/linux/installed_documents.sh, which drives a Save on a booted
# installed machine and reads the disk.
for app in hamwrite hamsheet hamslides; do
    if grep -q 'from lib.homedir import' "user/$app.ad" \
            && grep -q 'hd_home_join' "user/$app.ad"; then
        pass "user/$app.ad resolves its document directory through lib/homedir.ad"
    else
        bad "user/$app.ad does not use the shared home resolver -- it still builds its own document path"
    fi
    # The literal may survive ONLY as the last-resort fallback INSIDE a
    # _default_* function -- the branch taken when the resolver cannot answer
    # at all. Anywhere else it is the defect. Comment lines are excluded;
    # a paragraph explaining the old path is not the old path.
    stray=$(awk '
        /^def /      { fn = $2; sub(/\(.*/, "", fn) }
        /^[ \t]*#/   { next }
        /"\/home\/live\/Documents/ {
            if (fn !~ /^_default_/) printf "%s:%d ", fn, FNR
        }' "user/$app.ad")
    if [ -z "$stray" ]; then
        pass "user/$app.ad reaches the /home/live/Documents literal only from its _default_* fallback"
    else
        bad "user/$app.ad builds a /home/live/Documents path outside the fallback: $stray"
    fi
done

# ---- THE UID HALF OF THE SESSION IDENTITY --------------------------------
# lib/homedir.ad's hd_session_uid() is the number the SYSTEM CHROME drops to
# before it execs a person's program (lib/p9.ad:spawn_detached_as, called from
# user/hamdesktop.ad:_run_action and user/hampanelscene.ad's launch-queue
# drain). Until 2026-08-19 the chrome did not drop at all and a document saved
# from a desktop icon came out OWNED BY UID 0 -- in the person's own directory,
# unwritable from a desktop terminal, which IS uid 1001.
#
# THE INVARIANT THAT MATTERS IS THAT THE UID AND THE HOME COME FROM ONE
# ACCOUNT. A launcher that ran as one person and wrote into another's directory
# would be a new defect wearing the old one's clothes, and it would look like a
# fix. So each REGU line carries both, taken at the same index, and they are
# asserted together.
assert_grep '^REGU0 idx=0 uid=1000 home=/home/dave$' \
    "the regular-account enumeration's uid and home agree at idx 0 (dave, 1000)"
assert_grep '^REGU1 idx=1 uid=1001 home=/home/live$' \
    "…and at idx 1 (live, 1001)"
assert_grep '^REGU2 idx=2 uid=1002 home=/home/bobby$' \
    "…and at idx 2, the installed-style account (bobby, 1002)"
assert_grep '^REGU4 idx=4 uid=0 home=<none>$' \
    "…and past the end it answers uid 0, which callers must read as DO NOT DROP"
assert_grep '^IREGU0 idx=0 uid=1000 home=/home/gizmo$' \
    "KEYSTONE: on an INSTALLED passwd the session identity is the wizard's account, uid and home together"
# hd_session_uid() RUN, not read. On an unprivileged host it takes step 1 --
# the running uid is already a regular account -- so the answer must be this
# process's own uid. That branch is what a host harness and a single-uid
# offscreen run take; getting it wrong would make every launcher refuse.
MYUID=$(id -u)
assert_grep "^SESSUID uid=${MYUID}\$" \
    "hd_session_uid() RAN and returned this process's own uid ($MYUID) -- the no-drop-needed branch"

# The two launchers must actually CALL it. Static, and said to be static:
# where the bytes land is measured by tests/linux/installed_documents.sh.
for f in user/hamdesktop.ad user/hampanelscene.ad; do
    if grep -q 'hd_session_uid' "$f" && grep -q 'spawn_detached_as' "$f"; then
        pass "$f launches a person's program through spawn_detached_as(hd_session_uid())"
    else
        bad "$f still launches a person's program with the chrome's own identity"
    fi
done
# And spawn_detached_as must REFUSE on a failed drop rather than exec'ing a
# still-root program. That is the success-shaped failure this tree keeps
# finding, so it is checked rather than assumed.
if awk '/^def spawn_detached_as/ { inb = 1; next }
        inb && /^def / { inb = 0 }
        inb' lib/p9.ad | grep -q 'sys_exit(126)'; then
    pass "spawn_detached_as REFUSES to exec when the drop fails (exit 126), instead of launching as root"
else
    bad "spawn_detached_as does not refuse on a failed drop -- a failed drop would launch a root program that looks like a success"
fi

assert_grep '^HOMEDIR_HOST_DONE$' "the harness ran to completion"

# --- 3. no stray /home/live hardcode left in the desktop's resolution -----
# The fallback constant is allowed to survive as a LAST resort, but the
# desktop must not reach it before consulting passwd. Assert the ORDER in the
# shared resolver: $HOME, then passwd, then /home/live.
body=$(sed -n '/^def hd_resolve_home/,/^$/p' lib/homedir.ad)
l_env=$(printf '%s\n' "$body" | grep -n 'hd_env_home(' | head -1 | cut -d: -f1)
l_pw=$(printf '%s\n' "$body"  | grep -n 'hd_home_from_passwd(' | head -1 | cut -d: -f1)
l_fb=$(printf '%s\n' "$body"  | grep -n 'hd_fallback_home(' | head -1 | cut -d: -f1)
if [ -n "$l_env" ] && [ -n "$l_pw" ] && [ -n "$l_fb" ] \
        && [ "$l_env" -lt "$l_pw" ] && [ "$l_pw" -lt "$l_fb" ]; then
    pass "hd_resolve_home order is \$HOME -> /etc/passwd(uid) -> /home/live"
else
    bad "hd_resolve_home does not consult /etc/passwd BEFORE the /home/live fallback"
fi

printf '\n%d PASSED, %d FAILED\n' "$NPASS" "$NFAIL"
if [ "$fail" -eq 0 ]; then
    echo "[homedir] RESULT: PASS"
    exit 0
fi
echo "[homedir] RESULT: FAIL" >&2
exit 1
