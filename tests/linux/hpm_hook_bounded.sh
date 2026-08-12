#!/usr/bin/env bash
# tests/linux/hpm_hook_bounded.sh — A PACKAGE HOOK CANNOT WEDGE `hpm update`.
#
# WHAT HAPPENED
# =============
# hamnix-drivers-base 1.0.13 shipped an install hook containing
#
#     echo '... put in front of the machine's table'
#
# The apostrophe closed the single-quoted string, so hamsh's lexer hit an
# unterminated quote and the runaway token swallowed the REST OF THE FILE --
# including the `\nexit\n` that hpm appends to every hook wrapper as its safety
# net (user/hpm.ad, _run_hook). With the `exit` eaten, the spawned hamsh
# reported its lexical error, returned from the rc, and fell through into its
# INTERACTIVE REPL, reading a stdin it had inherited from hpm and that nobody
# was feeding. `hpm update` NEVER RETURNED -- measured on a real installed
# machine. The modules extracted, the dependency table was never merged, and
# the machine sat wedged mid-update with no timeout and no diagnostic.
#
# WHY THE GENERATOR FIX IS NOT THE WHOLE FIX
# ==========================================
# scripts/hamlinux_packages.py's write_pkg now refuses to publish a hook with
# an odd number of single quotes on any non-comment line. That closes it FROM
# THE PUBLISHING SIDE ONLY. A hook from a third-party channel, a hand-written
# package, or the next generator bug of a different shape still reaches
# _run_hook -- and a hook that hangs for a reason that has nothing to do with
# quoting (an infinite loop, a read from a network, a wait on a device) was
# never covered by a lexer rule at all.
#
# THE DEFECT IS IN THE PARENT. hpm waited forever on a process it spawned.
# So user/hpm.ad's _run_hook now does two things, and this file proves both:
#
#   1. THE HOOK'S STDIN IS /dev/null. A hook has no business reading standard
#      input, and with stdin at EOF a hamsh that reaches its REPL reads EOF on
#      its first poll and exits -- so the `exit` safety net holds even when the
#      `exit` itself was swallowed, for a hook of ANY origin.
#   2. THE WAIT IS BOUNDED. 60 s, then the child is killed and the failure is
#      reported BY NAME with the package named. See the HOOK_TIMEOUT_CS
#      comment in user/hpm.ad for where the number comes from (it is ~500x the
#      measured cost of the slowest hook this distribution ships).
#
# WHAT THIS DOES NOT FIX, STATED PLAINLY
# ======================================
# A machine that already installed a broken hpm runs the OLD hpm when it
# updates. This change cannot rescue a machine that is already wedged, and it
# cannot rescue a machine that takes the next bad hook before it takes this
# hpm. It protects machines from the hook AFTER the one that carries it.
#
# THE PART THAT WAS OPEN HERE IS NOW CLOSED ELSEWHERE (2026-08-12)
# This gate used to end by printing -- not asserting -- that the runaway-quote
# hook still exited 0 and hpm still said "installed", because a lexical error
# was not fatal to hamsh. It is fatal now: hamsh names the file and the line,
# says the script was NOT RUN, and exits non-zero; hpm turns that into a named
# install failure; and PID 1 alone is exempt from the exit, because an init
# that exits panics the kernel -- it announces a rescue shell instead. That is
# gated, in both halves and with a real boot, by tests/linux/lex_error_fatal.sh.
# THIS file's subject is unchanged and so are its assertions: the wait on a
# hook is bounded no matter WHY the hook does not finish.
#
# HOW IT RUNS: entirely on the host, no QEMU. hpm and hamsh are built for the
# Linux line by scripts/hamlinux_build.sh and run inside a user + mount + pid
# namespace, chrooted into a throwaway root with a file:// repository. The pid
# namespace means every process this gate starts dies with it.
#
# REVERT-SENSITIVE, and checked the hard way: remove the /dev/null stdin from
# _run_hook and assertion 4 goes red (`hpm install hooktest-quote` never
# returns); remove the deadline loop and assertions 6/7/8 go red (`hpm install
# hooktest-hang` never returns).
#
# AND ONE CORRECTION TO ITS OWN HISTORY (2026-08-12). Assertions 1 and 2 were
# measuring NOTHING: the fixture wrote the runaway-quote wrapper to a path
# under $R while both assertions opened $W/quote.exec, so hamsh was handed a
# FILE THAT DID NOT EXIST -- it said `boot rc ... not found`, fell into its
# REPL, and hung / exited on stdin exactly as the real wrapper would have.
# Green, both of them, without the bad quote ever being lexed once. It was
# found only because a new diagnostic was missing from output that claimed to
# be about it. The path is fixed and assertion 1 now refuses a `not found` as
# evidence of anything. Same family as scripts/test_gate_softgreen.sh.
#
# Usage: tests/linux/hpm_hook_bounded.sh
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT" || exit 1

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL $*"; }
note() { echo "  --   $*"; }

# Private build tree, per docs/steam_namespace.md §11: nothing under the
# shared build/ is written.
KEY="$(printf '%s' "$PROJ_ROOT" | sha256sum | cut -c1-12)"
W="${HPM_HOOK_GATE_DIR:-$HOME/.hamnix-build/hpm_hook_bounded.$KEY}"
mkdir -p "$W" || exit 1
R="$W/root"

for t in unshare /usr/sbin/chroot timeout mkfifo; do
    command -v "$t" >/dev/null 2>&1 || [ -x "$t" ] || {
        echo "[hook-bounded] SKIP: $t not available"; exit 0; }
done
unshare -Ur true 2>/dev/null || {
    echo "[hook-bounded] SKIP: unprivileged user namespaces are unavailable here"
    exit 0; }

# ---------------------------------------------------------------- build
if [ -z "${ADDER_HOST_AC:-}" ]; then
    ADDER_HOST_AC="$PROJ_ROOT/build/cutover/host_ac_llvm.elf"
    [ -x "$ADDER_HOST_AC" ] || ADDER_HOST_AC="$PROJ_ROOT/build/cutover/host_ac.elf"
fi
if [ ! -x "$ADDER_HOST_AC" ]; then
    # A fresh worktree has no compiler yet. Build one rather than skipping:
    # a gate that quietly does not run is the shape this whole file exists to
    # argue against.
    echo "[hook-bounded] no host_ac.elf yet; bootstrapping the Adder compiler"
    # shellcheck source=../../scripts/_adder_cc.sh
    source "$PROJ_ROOT/scripts/_adder_cc.sh"
    adder_cc_bootstrap || {
        echo "[hook-bounded] FAIL: could not bootstrap host_ac.elf"; exit 1; }
    ADDER_HOST_AC="$PROJ_ROOT/build/cutover/host_ac.elf"
fi
[ -x "$ADDER_HOST_AC" ] || { echo "[hook-bounded] FAIL: no host_ac.elf"; exit 1; }
export ADDER_HOST_AC

echo "[hook-bounded] building hpm + hamsh for the Linux line -> $W"
for prog in hpm hamsh; do
    nice -n 15 bash scripts/hamlinux_build.sh "user/$prog.ad" "$W/$prog.elf" \
        > "$W/$prog.build.log" 2>&1 || {
        echo "[hook-bounded] FAIL: could not build $prog (see $W/$prog.build.log)"
        tail -5 "$W/$prog.build.log"; exit 1; }
done

# ------------------------------------------------- the sandbox root
rm -rf "$R"
mkdir -p "$R"/bin "$R"/lib64 "$R"/lib/x86_64-linux-gnu "$R"/tmp "$R"/dev \
         "$R"/etc "$R"/repo/main/packages "$R"/var/lib/hpm "$R"/share
cp "$W/hpm.elf"   "$R/bin/hpm"
cp "$W/hamsh.elf" "$R/bin/hamsh"
# The interpreter + the libraries clang linked these against. The chroot has
# no package manager of its own; this is the whole of its userland.
for so in $(ldd "$W/hpm.elf" "$W/hamsh.elf" | awk '/=> \//{print $3}' | sort -u); do
    cp -n "$so" "$R/lib/x86_64-linux-gnu/" 2>/dev/null
done
cp /lib64/ld-linux-x86-64.so.2 "$R/lib64/" 2>/dev/null
: > "$R/dev/null"                      # bind-mount target for the real one
rm -f "$R/hangfifo"; mkfifo "$R/hangfifo"

# ------------------------------------------------- the fixture repository
python3 - "$R/repo/main" "$W" <<'PYFIX' || exit 1
import hashlib, json, os, shutil, sys, tarfile, tempfile

out, work = sys.argv[1], sys.argv[2]
pkgdir = os.path.join(out, "packages")
os.makedirs(pkgdir, exist_ok=True)

# THE HOOK THAT WEDGED THE MACHINE, character for character in the part that
# matters: an apostrophe inside a single-quoted string. Written here BY HAND
# rather than through scripts/hamlinux_packages.py's write_pkg, because
# write_pkg now refuses to emit it -- and the point of this gate is a hook
# that did not come from write_pkg.
QUOTE = ("# hooktest-quote -- the shape that wedged hamnix-drivers-base 1.0.13.\n"
         "echo '[hooktest-quote] starting'\n"
         "echo 'put in front of the machine's table' >> /tmp/quote.log\n"
         "echo '[hooktest-quote] finished'\n")

# A hook that LEXES PERFECTLY and never finishes: the redirect opens a fifo
# for reading and no writer ever appears. /dev/null on stdin does nothing for
# this one -- only the deadline does.
HANG = ("# hooktest-hang -- lexes fine, blocks forever on an open(2).\n"
        "echo '[hooktest-hang] starting'\n"
        "echo tail < /hangfifo\n"
        "echo '[hooktest-hang] finished'\n"
        "exit 0\n")

# A well-formed script with NO `exit`, so it reaches the REPL legitimately.
# Assertion 2 needs one: a script that does not lex no longer gets there.
NOEXIT = ("echo noexit-ran\n")

GOOD = ("# hooktest-good -- an ordinary, well-formed hook.\n"
        "echo '[hooktest-good] hook ran'\n"
        "exit 0\n")


def write_pkg(name, hooks):
    stage = tempfile.mkdtemp(prefix="hooktest-")
    try:
        top = os.path.join(stage, "%s-1.0.0" % name)
        os.makedirs(os.path.join(top, "files", "share"))
        with open(os.path.join(top, "files", "share", name), "w") as fh:
            fh.write("payload of %s\n" % name)
        for hook_name, body in sorted(hooks.items()):
            hp = os.path.join(top, hook_name)
            with open(hp, "w") as fh:
                fh.write(body)
            os.chmod(hp, 0o755)
        with open(os.path.join(top, "PKGINFO"), "w") as fh:
            fh.write("\n".join(["name: %s" % name, "version: 1.0.0",
                                "arch: x86_64",
                                "description: hpm hook-bound gate fixture",
                                "target: #hamnix-system",
                                "maintainer: hamnix-linux gate"]) + "\n")
        tarpath = os.path.join(pkgdir, "%s-1.0.0.tar.gz" % name)
        with tarfile.open(tarpath, "w:gz", format=tarfile.GNU_FORMAT) as tf:
            for dirpath, dirnames, filenames in os.walk(top):
                dirnames.sort()
                for fn in sorted(filenames):
                    full = os.path.join(dirpath, fn)
                    tf.add(full, arcname=os.path.relpath(full, stage))
        data = open(tarpath, "rb").read()
        return {"name": name, "version": "1.0.0", "arch": "x86_64",
                "url": "packages/%s-1.0.0.tar.gz" % name,
                "sha256": hashlib.sha256(data).hexdigest(),
                "size": len(data),
                "description": "hpm hook-bound gate fixture",
                "depends": [], "target": "#hamnix-system"}
    finally:
        shutil.rmtree(stage, ignore_errors=True)


entries = [write_pkg("hooktest-quote", {"install.hamsh": QUOTE}),
           write_pkg("hooktest-hang",  {"install.hamsh": HANG}),
           write_pkg("hooktest-good",  {"install.hamsh": GOOD})]
with open(os.path.join(out, "index.json"), "w") as fh:
    json.dump({"schema": 1, "repo": "hooktest", "channel": "main",
               "url": "file:///repo/", "updated": "2026-08-11",
               "description": "hpm hook-bound gate fixture",
               "packages": entries}, fh, indent=2)
    fh.write("\n")

# The wrapper hpm writes for the runaway-quote hook: the body, then the
# "\nexit\n" safety net. This is the exact byte sequence _run_hook hands to
# hamsh, and assertions 1-2 drive hamsh with it directly.
#
# IT USED TO BE WRITTEN WHERE NOTHING READ IT. This path was
# dirname(out)/.. == $R, while assertions 1-2 open $W/quote.exec -- so for
# every run before 2026-08-12 hamsh was handed a file THAT DID NOT EXIST. It
# printed `boot rc ... not found`, fell into its REPL, and hung or exited on
# stdin exactly as a real runaway-quote wrapper would have, so both assertions
# went green having never once lexed the bad quote. Found while making a lex
# error fatal: the shell's new diagnostic was missing from output that claimed
# to be about it.
with open(os.path.join(work, "quote.exec"), "w") as fh:
    fh.write(QUOTE + "\nexit\n")
with open(os.path.join(work, "noexit.exec"), "w") as fh:
    fh.write(NOEXIT)
print("fixture: %d packages" % len(entries))
PYFIX

echo "[hook-bounded] ================================================"

# ==================================================================== 1-3
# THE MECHANISM, DRIVEN DIRECTLY. Every invocation gets its own timeout: a
# test for a hang that itself hangs teaches nobody anything.
echo "[hook-bounded] the mechanism: hamsh on the exact wrapper hpm writes"

# (1) THE WRAPPER THAT WEDGED THE MACHINE, on an open-but-silent stdin --
#     which is what a hook inherited from hpm, whose stdin nobody is feeding,
#     actually is. It used to reach the interactive REPL here and never return.
#     Since 2026-08-12 a lexical error is FATAL to the script (see
#     tests/linux/lex_error_fatal.sh), so it never gets to the REPL at all: it
#     names the file and the line and exits non-zero. EITHER of those is a
#     pass; what must never happen again is the hang.
#
#     NOTE ON THIS ASSERTION'S OWN HISTORY: $W/quote.exec did not exist for
#     every run before that date -- the fixture wrote it under $R -- so hamsh
#     was handed a MISSING FILE, said `boot rc ... not found`, and fell into
#     the REPL, and this assertion went green having never lexed the bad quote
#     once. The path is fixed above; the check below no longer accepts a
#     `not found` as evidence of anything.
t0=$SECONDS
sleep 12 | timeout 8 "$W/hamsh.elf" "$W/quote.exec" > "$W/m_pipe.out" 2>&1
rc=$?
el=$((SECONDS-t0))
if grep -q 'not found' "$W/m_pipe.out"; then
    bad "(1) the fixture wrapper $W/quote.exec is MISSING -- this assertion would be measuring nothing"
elif [ "$rc" = 124 ]; then
    bad "(1) THE HANG IS BACK: the runaway-quote wrapper on an open stdin never returned (killed at 8 s)"
    sed -n '1,20p' "$W/m_pipe.out"
elif [ "$rc" != 0 ] && grep -q 'lexical error' "$W/m_pipe.out"; then
    ok "(1) the runaway-quote wrapper on an OPEN stdin does not wedge: hamsh reports the lexical error and exits $rc in ${el}s"
else
    bad "(1) unexpected: rc=$rc in ${el}s with no lexical error reported"
    sed -n '1,20p' "$W/m_pipe.out"
fi

# (2) HAMSH'S REPL EXITS ON EOF. This is the claim _run_hook's /dev/null stdin
#     rests on, and it is MEASURED, not assumed -- the assumption is the whole
#     bug one level down. It needs a script that REACHES the REPL, so it uses a
#     well-formed hook with no `exit` (a script that does not lex no longer
#     gets that far).
t0=$SECONDS
timeout 8 "$W/hamsh.elf" "$W/noexit.exec" < /dev/null > "$W/m_null.out" 2>&1
rc=$?
el=$((SECONDS-t0))
if [ "$rc" != 124 ] && grep -q 'loop-enter' "$W/m_null.out" \
   && grep -q 'noexit-ran' "$W/m_null.out"; then
    ok "(2) hamsh's REPL DOES exit on EOF: a hook with no \`exit\`, stdin /dev/null, reaches loop-enter and exits in ${el}s (rc=$rc)"
else
    bad "(2) hamsh did not exit on EOF: rc=$rc after ${el}s"
    sed -n '1,20p' "$W/m_null.out"
fi

# (3) The control: a well-formed hook is unaffected by either stdin.
printf 'echo control-ran\nexit\n' > "$W/good.exec"
timeout 8 "$W/hamsh.elf" "$W/good.exec" < /dev/null > "$W/m_ctl.out" 2>&1
if [ $? = 0 ] && grep -q 'control-ran' "$W/m_ctl.out"; then
    ok "(3) control: a well-formed hook still runs and exits 0"
else
    bad "(3) the control hook did not run cleanly"
fi

# ==================================================================== 4-9
# THE WHOLE THING: hpm, installing real packages out of a real repository.
echo "[hook-bounded] hpm, installing from a file:// repository"

# HPM'S OWN STDIN MUST BE OPEN AND SILENT, or this gate cannot fail.
#
# On an installed machine hpm inherits a stdin that is OPEN -- the console, a
# terminal, PID 1's -- and simply has nobody typing at it. That is what let the
# hook's REPL park forever. A gate that runs hpm from a harness whose stdin is
# already at EOF hands the hook an EOF it did not have to be given, and then
# the runaway-quote install terminates WITH OR WITHOUT the fix: measured, that
# was assertion 5 passing green against a fully reverted _run_hook.
#
# So: a fifo held open read-write on fd 9 for the life of this script. A reader
# opens it immediately and never sees end-of-input, which is exactly a console
# nobody is typing at.
rm -f "$W/stdin.fifo"; mkfifo "$W/stdin.fifo"
exec 9<> "$W/stdin.fifo"

run_ns() {   # run_ns <seconds> <logfile> <hpm args...>
    local secs="$1" log="$2"; shift 2
    local args=("$@")
    unshare -Urmp --fork --mount-proc bash -c '
        R="$1"; secs="$2"; shift 2
        mount --bind /dev/null "$R/dev/null" || exit 9
        timeout "$secs" /usr/sbin/chroot "$R" /bin/hpm "$@"
        echo "__RC__=$?"
        # A pid namespace whose init exits takes every process in it with it,
        # so nothing this gate started can outlive this line.
    ' _ "$R" "$secs" "${args[@]}" > "$log" 2>&1 < "$W/stdin.fifo"
}

run_ns 60 "$W/refresh.log" --repo=file:///repo/ refresh
if grep -q '__RC__=0' "$W/refresh.log"; then
    ok "(4) the fixture repository refreshes (3 packages)"
else
    bad "(4) refresh failed"; sed -n '1,20p' "$W/refresh.log"
fi

# THE ORIGINAL WEDGE, END TO END. Before the fix this call never returned.
t0=$SECONDS
run_ns 45 "$W/quote.log" --repo=file:///repo/ install hooktest-quote
el=$((SECONDS-t0))
if grep -q '__RC__=124' "$W/quote.log"; then
    bad "(5) hpm STILL HANGS on the runaway-quote hook (killed at 45 s) -- this is the original bug"
    sed -n '1,25p' "$W/quote.log"
else
    ok "(5) hpm install hooktest-quote TERMINATES (${el}s) -- the runaway-quote hook is no longer a wedge"
fi
# AND IT WAS THE STDIN THAT DID IT, NOT THE DEADLINE. If the /dev/null stdin
# were absent and only the 60 s bound were holding, this same install would
# take a minute and end in a kill. Finishing in seconds is the observable
# difference between the two protections.
if grep -q 'cannot put /dev/null on the stdin' "$W/quote.log"; then
    bad "(6) hpm could not put /dev/null on the hook's stdin -- the first protection is not in effect"
elif grep -q 'was KILLED' "$W/quote.log"; then
    bad "(6) the runaway-quote hook had to be KILLED at the deadline -- the EOF exit did not happen; only the timeout saved it"
elif [ "$el" -lt 15 ]; then
    ok "(6) and the EOF exit is what did it, not the deadline: the hook ended in ${el}s, not at the 60 s bound, and hpm raised no /dev/null warning"
else
    bad "(6) the runaway-quote hook took ${el}s -- too close to the 60 s bound to have exited on EOF"
fi

# A HOOK THAT HANGS FOR A REASON /dev/null DOES NOTHING ABOUT. It lexes
# perfectly and blocks in open(2) on a fifo with no writer. Only the deadline
# can end this one. HOOK_TIMEOUT_CS is 60 s, so allow 100.
t0=$SECONDS
run_ns 100 "$W/hang.log" --repo=file:///repo/ install hooktest-hang
el=$((SECONDS-t0))
if grep -q '__RC__=124' "$W/hang.log"; then
    bad "(7) hpm hung on a blocking hook: no deadline is in effect (killed at 100 s)"
    sed -n '1,25p' "$W/hang.log"
else
    ok "(7) hpm install hooktest-hang TERMINATES (${el}s) -- the wait on a hook is bounded"
fi
# ...AND IT SAYS WHICH PACKAGE. Giving up silently is not better than hanging.
if grep -q 'ran longer than 60 seconds and was KILLED' "$W/hang.log" \
   && grep -q 'install.hamsh of package hooktest-hang' "$W/hang.log"; then
    ok "(8) it fails BY NAME: 'hook install.hamsh of package hooktest-hang ran longer than 60 seconds and was KILLED'"
else
    bad "(8) the timeout did not name the hook and the package"
    grep -i 'hook\|kill\|timeout' "$W/hang.log" | sed -n '1,10p'
fi
if grep -qE '__RC__=[1-9]' "$W/hang.log" \
   && grep -q 'is NOT correctly installed' "$W/hang.log"; then
    ok "(9) and the install FAILS: a timed-out hook is a failed install, not a success, and hpm says the files are on disk but the hook did not finish"
else
    bad "(9) hpm did not report the timed-out install as a failure"
    grep '__RC__' "$W/hang.log"
fi

# THE CONTROL, at the hpm level: ordinary hooks are untouched by all of this.
run_ns 60 "$W/good.log" --repo=file:///repo/ install hooktest-good
if grep -q '__RC__=0' "$W/good.log" \
   && grep -q '\[hooktest-good\] hook ran' "$W/good.log" \
   && grep -q 'installed hooktest-good@1.0.0' "$W/good.log"; then
    ok "(10) control: an ordinary package still installs and its hook still runs"
else
    bad "(10) an ordinary install regressed"; sed -n '1,25p' "$W/good.log"
fi

# ------------------------------------------------------------- once open
# NOT AN ASSERTION -- tests/linux/lex_error_fatal.sh asserts this now. Kept as
# a tripwire: if this line ever prints again, a lexical error has stopped being
# fatal to hamsh and hpm is back to believing a hook that ran nothing.
if grep -q 'installed hooktest-quote@1.0.0' "$W/quote.log"; then
    note "REGRESSION WATCH: hpm reported 'installed hooktest-quote@1.0.0' for a"
    note "  hook that failed to lex AND THEREFORE RAN NOTHING. That was fixed on"
    note "  2026-08-12 (a lex error is fatal to the script; hamsh exits non-zero"
    note "  and hpm fails the install by name). See tests/linux/lex_error_fatal.sh."
fi

echo "[hook-bounded] ================================================"
echo "[hook-bounded] PASS $PASS  FAIL $FAIL"
[ "$FAIL" = 0 ] || exit 1
exit 0
