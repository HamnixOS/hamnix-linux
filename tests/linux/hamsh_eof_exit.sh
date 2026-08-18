#!/usr/bin/env bash
# tests/linux/hamsh_eof_exit.sh
#
# REGRESSION GATE: hamsh must LEAVE when its stdin is over, and it must not
# burn a core discovering that.
#
# THE DEFECT (measured 2026-08-18, dev host, before this gate existed)
# ====================================================================
# `hamsh <script>` that finishes a script which does not call `exit` falls into
# the interactive REPL. With stdin already at end of input (`< /dev/null`) it
# did not leave: it span at 100% of one core, and the earlier recorded
# observation is 12 minutes 42 seconds at 99.9% until it was killed by pid.
# On a laptop that is a flat battery and a hot fan for a shell with nothing
# left to read. It is also why the tok-capacity gate's negative control exits
# 124 rather than 0.
#
# THE CAUSE, and it is one instruction's worth
# --------------------------------------------
# `sys_read_nb`'s contract -- written at its own definition in
# user/linux-runtime.S -- is "0 == no byte ready YET, a negative == true
# EOF/error". read(2)'s convention is the other way round: -EAGAIN for "would
# block", 0 for end of file. The freestanding shim mapped -EAGAIN to 0 and
# then returned read(2)'s 0 VERBATIM, so the two states collided and
# ed_readline's `if n == 0: ... continue` polled a finished input for ever.
# The hosted lane (user/linux-syscalls.c, which is what the shipped image
# links) has answered -1 for a genuine 0 since it was written, so this was the
# freestanding lane disagreeing with the hosted one -- and the freestanding
# lane is the one every host gate compiles.
#
# WHAT THIS GATE MEASURES, AND HOW IT MEASURES CPU
# ================================================
# `ps pcpu` is a LIFETIME AVERAGE: a process that span for a minute and then
# idled reads as calm, and a process that has only just started reads as busy.
# Every CPU number here is an INTERVAL -- two reads of /proc/<pid>/stat
# (utime+stime, in 100 Hz ticks) five seconds apart -- so it describes what the
# process is doing NOW.
#
#   PART 2  THE ASSERTION.       stdin at EOF: the script runs, the shell
#                                EXITS, quickly, with status 0, having used
#                                almost no CPU.
#   PART 3  POSITIVE CONTROL.    stdin OPEN but silent (a fifo whose writer is
#                                held): the shell must still be ALIVE after a
#                                settle and must still RUN a line written
#                                late. Without this, "it exited" is not
#                                evidence about EOF -- a shell that exits at
#                                everything would score PART 2 green.
#   PART 4  PIPED SCRIPT.        the ordinary `printf ... | hamsh` path still
#                                runs every line AND now exits 0 (it exited
#                                124 under `timeout` before the fix).
#   PART 5  NEGATIVE CONTROL, RUN. A SECOND hamsh is built against a copy of
#                                user/linux-runtime.S with exactly the
#                                EOF-to--1 mapping deleted -- the historical
#                                defect and nothing else -- through a hard-link
#                                farm over this tree. Against that binary the
#                                SPIN MUST COME BACK: still alive after the
#                                window, and >= 80% of one core over a
#                                five-second interval. If the defective build
#                                behaves like the fixed one then PART 2 proved
#                                nothing, and this gate says so rather than
#                                reporting a green.
#
# No QEMU. Two hamsh compiles dominate the runtime (~1 min total on this host).
# Exit 0 = PASS, 1 = FAIL.

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

TAG="[hamsh_eof_exit]"
PASS=0; FAIL=0
ok()   { echo "$TAG   PASS  $*"; PASS=$((PASS+1)); }
bad()  { echo "$TAG   FAIL  $*"; FAIL=$((FAIL+1)); }
info() { echo "$TAG         $*"; }
say()  { echo; echo "$TAG == $* =="; }
die()  { echo "$TAG   FAIL  $*"; FAIL=$((FAIL+1)); summary; exit 1; }

W="${HAMSH_EOF_WORK:-$(mktemp -d "${TMPDIR:-/tmp}/hamsh-eof.XXXXXX")}"
mkdir -p "$W"
info "work dir: $W"

summary() {
    echo
    echo "$TAG ================================================================"
    echo "$TAG RESULT: $PASS PASSED / $FAIL FAILED"
    echo "$TAG ================================================================"
}

# --- "is it still running?" --------------------------------------------
# NOT `kill -0`: a finished background child is a ZOMBIE until bash reaps it,
# and kill -0 answers yes to a zombie. Field 3 of /proc/<pid>/stat is the
# state letter; 'Z' is finished. A missing stat file is finished too.
still_running() {
    local st
    st="$(awk '{print $3}' "/proc/$1/stat" 2>/dev/null)" || return 1
    [ -n "$st" ] || return 1
    [ "$st" = "Z" ] && return 1
    return 0
}

# --- interval CPU, in percent of ONE core ---------------------------------
# Two reads of /proc/<pid>/stat fields 14+15 (utime+stime, 100 Hz ticks)
# `secs` apart. Prints -1 if the process is not alive for the whole window,
# so a caller can tell "it exited" from "it was idle".
cpu_interval_pct() {
    local pid="$1" secs="${2:-5}" a b
    still_running "$pid" || { echo -1; return; }
    a="$(awk '{print $14+$15}' "/proc/$pid/stat" 2>/dev/null)" || { echo -1; return; }
    [ -n "$a" ] || { echo -1; return; }
    sleep "$secs"
    still_running "$pid" || { echo -1; return; }
    b="$(awk '{print $14+$15}' "/proc/$pid/stat" 2>/dev/null)" || { echo -1; return; }
    [ -n "$b" ] || { echo -1; return; }
    echo $(( (b - a) * 100 / (secs * 100) ))
}

# =========================================================================
say "PART 1 — build the shell under test (freestanding x86_64-linux lane)"
# =========================================================================
FIXED="$W/hamsh-fixed.elf"
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/hamsh.ad -o "$FIXED" >"$W/compile.log" 2>&1; then
    tail -20 "$W/compile.log"
    die "hamsh did not compile — this gate cannot observe its assertion"
fi
[ -x "$FIXED" ] || die "no hamsh binary produced"
ok "hamsh compiled ($(stat -c%s "$FIXED") bytes)"

# The script the shell is asked to run. It does NOT call exit, which is the
# whole precondition: finishing it drops the shell into the interactive REPL.
cat > "$W/job.hs" <<'HSEOF'
echo EOF_GATE_SCRIPT_RAN
HSEOF

# =========================================================================
say "PART 2 — THE ASSERTION: stdin at EOF, the shell must leave"
# =========================================================================
T0=$(date +%s)
# Started directly, NOT inside a subshell and NOT looked up afterwards: $! is
# the shell's own pid and `wait` is its own exit status. (`pgrep -f` has given
# this tree eight wrong answers; it is not used here.)
"$FIXED" "$W/job.hs" < /dev/null > "$W/eof.out" 2>&1 &
SHELL_PID=$!
ALIVE_AT_2S=0
PCT=-1
sleep 2
if still_running "$SHELL_PID"; then
    ALIVE_AT_2S=1
    PCT="$(cpu_interval_pct "$SHELL_PID" 5)"
    info "still alive 2 s in; interval CPU over the next 5 s: ${PCT}% of one core"
fi
WAITED=0
while still_running "$SHELL_PID" && [ "$WAITED" -lt 30 ]; do
    sleep 1; WAITED=$((WAITED+1))
done
T1=$(date +%s)
if still_running "$SHELL_PID"; then
    kill -9 "$SHELL_PID" 2>/dev/null
    wait "$SHELL_PID" 2>/dev/null
    ST="killed"
    bad "hamsh did NOT exit within 30 s of an EOF stdin — this is the spin"
else
    wait "$SHELL_PID" 2>/dev/null
    ST=$?
    ok "hamsh EXITED on an EOF stdin (wall $((T1-T0)) s)"
fi

if grep -q '^EOF_GATE_SCRIPT_RAN$' "$W/eof.out" 2>/dev/null; then
    ok "the script itself RAN — the instrument produced its mark"
else
    bad "the script's own line never ran; nothing here is evidence about EOF"
fi

if [ "$ST" = "0" ]; then
    ok "exit status 0 (clean EOF exit, not a kill)"
else
    bad "exit status was '$ST', expected 0"
fi

if [ "$ALIVE_AT_2S" = "0" ]; then
    ok "gone within 2 s — no interval of spin to sample"
elif [ "${PCT:-999}" -ge 0 ] && [ "${PCT:-999}" -lt 50 ]; then
    ok "interval CPU while alive was ${PCT}% of one core (< 50%)"
elif [ "${PCT:-999}" = "-1" ]; then
    ok "exited during the sampling window — no sustained spin"
else
    bad "interval CPU was ${PCT}% of one core while sitting on an EOF stdin"
fi

# =========================================================================
say "PART 3 — POSITIVE CONTROL: an OPEN but silent stdin is NOT end of input"
# =========================================================================
rm -f "$W/idle.fifo" "$W/idle.out"
mkfifo "$W/idle.fifo"
"$FIXED" < "$W/idle.fifo" > "$W/idle.out" 2>&1 &
IDLE_PID=$!
exec 9> "$W/idle.fifo"
sleep 4
if still_running "$IDLE_PID"; then
    ok "still alive after 4 s of an OPEN, silent stdin (no false EOF)"
else
    bad "exited on an OPEN stdin — the fix turned an idle prompt into an exit"
fi
printf 'echo EOF_GATE_LATE_LINE\n' >&9
sleep 3
exec 9>&-
sleep 2
kill -9 "$IDLE_PID" 2>/dev/null
wait "$IDLE_PID" 2>/dev/null
if grep -q '^EOF_GATE_LATE_LINE$' "$W/idle.out" 2>/dev/null; then
    ok "a line written LATE was still read and executed"
else
    bad "a late line was not executed — the shell stopped listening"
fi

# =========================================================================
say "PART 4 — the piped-script path still works, and now ENDS"
# =========================================================================
printf 'echo PIPED_A\necho PIPED_B\n' | timeout 25 "$FIXED" > "$W/pipe.out" 2>&1
PIPE_ST=$?
if grep -q '^PIPED_A$' "$W/pipe.out" && grep -q '^PIPED_B$' "$W/pipe.out"; then
    ok "both piped lines ran"
else
    bad "a piped script's lines did not both run"
fi
if [ "$PIPE_ST" = "0" ]; then
    ok "the piped shell exited 0 (it exited 124 under timeout before the fix)"
else
    bad "the piped shell exited $PIPE_ST, expected 0"
fi

# =========================================================================
say "PART 5 — NEGATIVE CONTROL, RUN: put the defect back and require the spin"
# =========================================================================
# A symlink farm over this tree whose ONLY real file is user/linux-runtime.S.
# compiler/adder.py takes its project root from Path(__file__).parent.parent
# and Python does not resolve symlinks in __file__, so a farm root is a
# first-class project root.
NEGROOT="$W/negroot"
rm -rf "$NEGROOT"
mkdir -p "$NEGROOT"
# compiler.adder resolves each import to its REAL path and then prints it
# relative to the project root, so a SYMLINKED .ad source raises ValueError
# and no binary is produced (the tok-capacity gate hit the same wall). The two
# directories a hamsh compile reads .ad files from are therefore REAL COPIES
# (~16 MiB); everything else -- including compiler/, which is itself a symlink
# into adder/ and is only ever imported as a Python module -- is a symlink.
cp -a "$PROJ_ROOT/lib"  "$NEGROOT/lib"
cp -a "$PROJ_ROOT/user" "$NEGROOT/user"
for e in "$PROJ_ROOT"/*; do
    b="$(basename "$e")"
    case "$b" in lib|user) continue ;; esac
    ln -s "$e" "$NEGROOT/$b"
done
rm -f "$NEGROOT/user/linux-runtime.S"

python3 - "$PROJ_ROOT/user/linux-runtime.S" "$NEGROOT/user/linux-runtime.S" <<'PYEOF'
import sys
src, dst = sys.argv[1], sys.argv[2]
t = open(src).read()
# The fix, exactly: a genuine 0 from read(2) is reported as -1.
NEW = """.L_read_nb_noteagain:
    testq   %rax, %rax             /* read(2) 0 == TRUE EOF -> report -1 */
    jne     .L_read_nb_done
    movq    $-1, %rax
.L_read_nb_done:
"""
OLD = """.L_read_nb_noteagain:
.L_read_nb_done:
"""
if NEW not in t:
    sys.stderr.write("NEGPATCH-ANCHOR-MISSING\n")
    raise SystemExit(2)
open(dst, "w").write(t.replace(NEW, OLD, 1))
PYEOF
NEGPATCH=$?
if [ "$NEGPATCH" != "0" ]; then
    bad "could not restore the historical defect (the anchor moved) — the negative control DID NOT RUN, so PART 2's greens are unproven"
    summary
    [ "$FAIL" -gt 0 ] && exit 1
    exit 0
fi
if cmp -s "$PROJ_ROOT/user/linux-runtime.S" "$NEGROOT/user/linux-runtime.S"; then
    bad "the defect copy is byte-identical to the tree's — nothing was reverted"
else
    ok "the defective runtime differs from the tree's by the EOF mapping alone"
fi

NEGBIN="$W/hamsh-defect.elf"
if ! ( cd "$NEGROOT" && python3 -m compiler.adder compile \
        --target=x86_64-linux user/hamsh.ad -o "$NEGBIN" ) \
        >"$W/negcompile.log" 2>&1; then
    tail -20 "$W/negcompile.log"
    bad "the defective hamsh did not compile — the negative control did not run, so PART 2's greens are unproven"
    summary
    exit 1
fi
ok "the defective hamsh compiled ($(stat -c%s "$NEGBIN") bytes)"

"$NEGBIN" "$W/job.hs" < /dev/null > "$W/neg.out" 2>&1 &
NEGPID=$!
sleep 2
if still_running "$NEGPID"; then
    ok "the defective shell is STILL RUNNING 2 s after its script finished at EOF"
    NEGPCT="$(cpu_interval_pct "$NEGPID" 5)"
    info "defective build interval CPU over 5 s: ${NEGPCT}% of one core"
    if [ "${NEGPCT:--1}" -ge 80 ] 2>/dev/null; then
        ok "the SPIN reproduces: ${NEGPCT}% of one core over a 5 s interval (>= 80%)"
    else
        bad "the defective build did not spin (${NEGPCT}%) — PART 2 proved nothing"
    fi
else
    bad "the defective build EXITED on EOF too — the defect was not restored, so PART 2 proved nothing"
fi
kill -9 "$NEGPID" 2>/dev/null
wait "$NEGPID" 2>/dev/null

if grep -q '^EOF_GATE_SCRIPT_RAN$' "$W/neg.out" 2>/dev/null; then
    ok "the defective build ran the script too — the two builds differ only after it"
else
    bad "the defective build never ran the script; it is not comparable to PART 2"
fi

summary
[ "$FAIL" -gt 0 ] && exit 1
exit 0
