#!/bin/bash
# Its host runtime and its pass/fail were NOT measured when this line was
# written. If you make it cheap enough for the battery, add the manifest line
# and delete this block.
#
# errstr_reaches_caller.sh — a refusal's REASON must reach the person who
# asked, not only a console they cannot see.
#
# THE BUG THIS EXISTS FOR. The owner typed `enter debian {sh}` into a terminal
# window on the desktop and got "bind: no distribution namespace". The kernel
# had in fact composed a four-reason diagnosis naming /etc/distros,
# $HAMNIX_DISTRO_<NAME>, filesystem labels and /n/<name> — and handed it to
# cons_write(). On a machine booted to a shell that is the right place. On a
# desktop session it goes to a console nobody is looking at, and sys_errstr()
# was nothing but strerror_r(errno), so the shell could only add "No such file
# or directory" to its own preamble.
#
# That is this project's oldest failure in new clothes: A CONSOLE REPORTED
# EVERYTHING, TO NOBODY. A diagnosis delivered where it cannot be read is
# worse than none, because the code then LOOKS like it explained itself.
#
# WHAT THIS GATE CHECKS, and it is deliberately narrow:
#   1. sys_errstr has a backing store at all — it is not just strerror_r.
#   2. That store is ONE-SHOT and errno-keyed. errstr means "the reason for
#      the MOST RECENT failure"; a buffer that persisted would eventually be
#      read against a later unrelated error, and two ENOENTs in a row would
#      have the second inherit the first one's story. A confident wrong answer
#      is strictly worse than the generic string.
#   3. The distro refusal — the one actually hit on hardware — writes to BOTH
#      the console and the errstr store.
#   4. It COMPILES, with the compiler proven able to reject this file first.
#
# WHAT IT DOES NOT CHECK, stated so nobody reads more into a green run: no
# process is started, no namespace is entered, and no shell prints anything
# here. That `enter debian {sh}` now shows the four reasons at the terminal is
# NOT established by this gate. It needs a booted machine, and until something
# measures that, this is a source gate and only a source gate.
set -u
cd "$(dirname "$0")/../.." || exit 1

SRC=user/linux-syscalls.c
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   — $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL — $1"; }

[ -f "$SRC" ] || { echo "  FAIL — no $SRC"; exit 1; }

# --- 1. a backing store exists -------------------------------------------
if grep -qE '^static char errstr_buf\[' "$SRC"; then
    ok "sys_errstr has a backing store, so a syscall can record a SPECIFIC reason"
else
    bad "there is no errstr backing store: sys_errstr can only ever return strerror_r(errno), and every carefully-worded refusal in this file is invisible to the caller"
fi

# --- 2. one-shot and errno-keyed -----------------------------------------
BODY=$(sed -n '/^int32_t sys_errstr(/,/^}/p' "$SRC")
if [ -z "$BODY" ]; then
    bad "could not read sys_errstr's body — the instrument failed, NOT reporting agreement from it"
else
    if printf '%s' "$BODY" | grep -q 'errstr_errno == errno'; then
        ok "the recorded reason is keyed to the errno that was live when it was set, so a mismatch is discarded rather than reported"
    else
        bad "the recorded reason is returned without checking it belongs to THIS errno — an old message can be attached to a new, unrelated failure"
    fi
    # ANCHORED TO THE RETURN PATH, not to the body. The first version of this
    # grepped the whole function, and there is a SECOND `errstr_buf[0] = 0` on
    # the fall-through path — so it stayed green when the negative control
    # deleted the one that matters. An assertion that cannot fail is not an
    # assertion. Require the clear to appear BEFORE the `return (int32_t)sn`
    # that hands the specific reason back.
    RETBLK=$(printf '%s' "$BODY" | sed -n '/errstr_errno == errno/,/return (int32_t)sn;/p')
    if printf '%s' "$RETBLK" | grep -qE "errstr_buf\[0\] = '\\\\0'"; then
        ok "reading the reason CLEARS it on the way out, so a second read cannot re-report a stale story"
    else
        bad "the reason is never cleared: errstr means the reason for the MOST RECENT failure, and a persistent buffer will eventually answer for an error it knows nothing about"
    fi
fi

# --- 3. the refusal actually hit on hardware uses it ----------------------
# Anchor on the distro refusal, then require BOTH sinks within its block.
CTX=$(grep -n 'no distribution namespace named' "$SRC" | head -1 | cut -d: -f1)
if [ -z "$CTX" ]; then
    bad "cannot find the distro refusal — this gate's subject is gone or renamed; NOT reporting a pass it did not measure"
else
    WIN=$(sed -n "$((CTX>12 ? CTX-12 : 1)),$((CTX+20))p" "$SRC")
    if printf '%s' "$WIN" | grep -q 'cons_write'; then
        ok "the distro refusal still reaches the console (right for a machine booted to a shell)"
    else
        bad "the distro refusal no longer writes to the console"
    fi
    if printf '%s' "$WIN" | grep -qE '^[[:space:]]*errstr_setf\('; then
        ok "the distro refusal ALSO reaches the caller's errstr — the reason arrives where the person typed the command"
    else
        bad "the distro refusal reaches only the console: on a desktop, an 'enter debian {sh}' still tells the person nothing but the errno. (Backticks are deliberately absent from this string: they are SHELL-EXPANDED inside double quotes, and this gate's own negative control caught it trying to run 'enter' as a command.)"
    fi
fi

# --- 3b. the setter must not disturb what it records ---------------------
# vsnprintf may set errno, and callers pass strerror(errno) as an argument. If
# errno moved between the failure and the caller's return, sys_errstr's errno
# key would stop matching and the specific reason would be DISCARDED IN
# SILENCE -- thrown away by the very mechanism built to deliver it. A
# recording function must not disturb the thing it is recording.
SETTER=$(sed -n '/^static void errstr_setf(/,/^}/p' "$SRC")
if [ -z "$SETTER" ]; then
    bad "cannot find errstr_setf — instrument failed, NOT reporting a pass from it"
elif printf '%s' "$SETTER" | grep -q 'int saved = errno;' && \
     printf '%s' "$SETTER" | grep -q 'errno = saved;'; then
    ok "errstr_setf saves and restores errno, so recording a reason cannot invalidate the key that delivers it"
else
    bad "errstr_setf does not preserve errno: vsnprintf may move it, the errno key then fails to match, and the specific reason is discarded in silence leaving only the generic string"
fi

# --- 3c. the OTHER terminal refusals reach the caller too ----------------
# Each of these returns an error to the caller, so a console-only message is a
# reason the caller can never see. Warnings that CONTINUE are deliberately not
# listed: they are not the caller's failure to report.
echo "  -- terminal refusals in the bind/enter path:"
for fn in bind_stage_failed enter_root_failed; do
    FB=$(sed -n "/^static void $fn(/,/^}/p" "$SRC")
    if [ -z "$FB" ]; then
        bad "$fn not found — NOT reporting a pass it did not measure"
    # A CALL, NOT A MENTION. Requiring the line to BEGIN with errstr_setf(
    # after whitespace. The first version grepped for the bare identifier and
    # matched the explanatory COMMENT next to the call -- so when the negative
    # control deleted the call, the comment kept the assertion green. That is
    # the second time in this one gate that a check matched prose instead of
    # code; both were found only because the control was RUN.
    elif printf '%s' "$FB" | grep -qE '^[[:space:]]*errstr_setf\('; then
        ok "$fn reaches the caller, not only the console"
    else
        bad "$fn writes only to the console, and it reports a failure the caller is about to be handed — on a desktop the person sees the errno and nothing else"
    fi
done
if grep -q 'errstr_setf(EACCES, "no writable staging directory' "$SRC"; then
    ok "the missing-staging-directory refusal reaches the caller"
else
    bad "the missing-staging-directory refusal is console-only: the alternative answer to it is entering NOTHING and running the body in the native root, so the person needs to know it happened"
fi

# --- 4. it compiles, with the compiler proven able to reject this file ----
# THE INSTRUMENT FIRST. A silent compiler is only evidence once it has been
# shown able to complain — an empty result is not a finding. My first attempt
# at this control put the broken copy in another directory and it failed on a
# missing #include, which proved nothing about syntax at all.
PROBE=user/_errstr_probe.c
sed 's/^static int  errstr_errno;/static int  errstr_errno DELIBERATE SYNTAX ERROR;/' "$SRC" > "$PROBE"
if grep -q 'DELIBERATE' "$PROBE" && gcc -fsyntax-only -I. "$PROBE" 2>&1 | grep -q 'error'; then
    ok "INSTRUMENT: gcc rejects a deliberately broken copy of this exact file, so silence below is a measurement"
    rm -f "$PROBE"
    if [ "$(gcc -fsyntax-only -I. "$SRC" 2>&1 | grep -c 'error')" = 0 ]; then
        ok "the real file compiles clean"
    else
        bad "the real file does not compile"
        gcc -fsyntax-only -I. "$SRC" 2>&1 | grep 'error' | head -3 | sed 's/^/        /'
    fi
else
    rm -f "$PROBE"
    bad "could not make gcc reject a deliberately broken copy — the compile check below would be meaningless, so it is NOT being run and NOT being reported as clean"
fi

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
