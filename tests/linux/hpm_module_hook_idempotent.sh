#!/usr/bin/env bash
#
# tests/linux/hpm_module_hook_idempotent.sh — DOES A DRIVER PACKAGE'S INSTALL
# HOOK ADD THE SAME LINES TWICE?
#
# THE QUESTION
# ============
# scripts/hamlinux_packages.py's module_install_hook() appends every module it
# installs to /etc/modules and every dependency line to modules.dep.  Until
# 2026-08-17 it appended UNCONDITIONALLY, and the rationale in the comment --
# "hpm refuses to install a package that is already installed, so this runs
# once per install" -- is false for an UPGRADE: `hpm update` runs the hook
# again and `hpm remove` does not take the lines back out.  Measured at roughly
# 5.3 KB of modules.dep per update, against an /etc/modules that
# user/linuxinit.ad reads into a fixed 32768-byte buffer.  An unbounded append
# against a bounded read is ONE problem.
#
# WHY THIS GATE EXISTS AT ALL, rather than a reading of the generator
# ==================================================================
# The fix is a conditional, and a conditional in a hamsh hook is the single
# most dangerous edit in this tree: hamsh PARSES A WHOLE SCRIPT BEFORE RUNNING
# ANY OF IT, and a parse error makes it EXIT 0 -- measured, both of them.  So
# one bad token anywhere in a generated hook means the ENTIRE hook does nothing
# while hpm reports the install a success, inside a package that has been
# published.  Reading the generator cannot detect that.  Running it can.
#
# So this gate takes the hook text OUT OF THE REAL GENERATOR, runs it with the
# REAL user/hamsh.ad and the REAL user/grep.ad built by
# scripts/hamlinux_build.sh, TWICE, and counts lines.
#
# WHAT IS MEASURED
# ================
#   A. The hook RUNS.  Its own echo lines reach stdout.  (A hook that failed to
#      parse prints nothing and still exits 0; without this, every count below
#      would be "0 lines added twice" and would PASS.)
#   B. First install: N module lines and M modules.dep lines appear.
#   C. Second install of the same package: ZERO new lines in either file.
#   D. With command substitution UNAVAILABLE (no writable fdns chan dir, which
#      is how `$( )` fails), the hook still appends -- degrading to the old
#      unconditional behaviour rather than losing a module -- and SAYS so.
#   E. THE NEGATIVE CONTROL: the same generator output with the guard stripped
#      back to the unconditional append it replaced.  Run twice, it MUST
#      duplicate.  Without this, C is an assertion that passes because nothing
#      was ever appended at all.
#
# WHAT IS NOT MEASURED, said out loud
# ===================================
#   * The hook is run against a PREFIXED copy: '/etc/modules' and the
#     modules.dep path are rewritten to live under this gate's work directory,
#     because a test may not write the host's /etc.  The substitution count is
#     asserted, and NOTHING ELSE in the text is touched -- the conditional, the
#     quoting and the ordering are byte-for-byte the generator's.
#   * This runs the hook under the host's kernel, not on an installed machine.
#     It answers "does this hamsh script do what it says twice", which is the
#     question the generator could not answer, and not "does hpm invoke it".
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

WORK="${HOOKIDEM_WORK:-$(mktemp -d -p "${TMPDIR:-/tmp}" hookidem.XXXXXX)}"
KEEP="${HOOKIDEM_KEEP:-0}"
mkdir -p "$WORK"
cleanup() { [ "$KEEP" = 1 ] || rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

pass=0; fail=0
ok()   { echo "hookidem: PASS $*"; pass=$((pass+1)); }
bad()  { echo "hookidem: FAIL $*"; fail=$((fail+1)); }
info() { echo "hookidem: INFO $*"; }

# --- the two real binaries -------------------------------------------------
for t in hamsh:user/hamsh.ad grep:user/grep.ad; do
    name="${t%%:*}"; src="${t#*:}"
    scripts/hamlinux_build.sh "$src" "$WORK/bin/$name" >"$WORK/$name.build.log" 2>&1 || {
        mkdir -p "$WORK/bin"
        scripts/hamlinux_build.sh "$src" "$WORK/bin/$name" >"$WORK/$name.build.log" 2>&1 || {
            bad "could not build $src"; tail -20 "$WORK/$name.build.log"
            echo "hookidem: $pass passed, $fail failed"; exit 1; }
    }
done
[ -x "$WORK/bin/hamsh" ] && [ -x "$WORK/bin/grep" ] \
    && ok "the real hamsh and the real grep both build" \
    || { bad "hamsh or grep is missing after the build"; echo "hookidem: $pass passed, $fail failed"; exit 1; }

KVER=6.12.85+deb13-amd64          # the '+' on purpose: hamsh's lexer splits a
                                  # BARE word at it, so every path the
                                  # generator emits must be quoted.  If the
                                  # quoting regresses, this gate sees it.
NMODS=3
NDEPS=2

# --- the hook, straight out of the generator -------------------------------
gen_hook() {   # gen_hook <outfile> <guarded|plain>
    python3 - "$1" "$2" "$WORK" "$KVER" "$NMODS" "$NDEPS" <<'PY'
import importlib.util, sys, os
out, mode, work, kver, nmods, ndeps = sys.argv[1:7]
nmods, ndeps = int(nmods), int(ndeps)
spec = importlib.util.spec_from_file_location(
    "hp", os.path.join(os.getcwd(), "scripts", "hamlinux_packages.py"))
hp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hp)

staged = [("h%d" % i, "i%d" % i,
           "/lib/modules/%s/kernel/drivers/test/mod%d.ko" % (kver, i), False)
          for i in range(nmods)]
deps = ["kernel/drivers/test/mod%d.ko: kernel/drivers/test/base.ko" % i
        for i in range(ndeps)]
text = hp.module_install_hook("hamnix-drivers-test", staged, "the test modules",
                              deps=deps, kver=kver)

if mode == "plain":
    # THE NEGATIVE CONTROL.  Everything the guard does is removed and the
    # appends are put back exactly as they were before 2026-08-17: no grep, no
    # `if`, one `echo ... >> file` per line.  Same lines, same order, same
    # quoting -- only the conditional is gone.
    keep = []
    for ln in text.splitlines():
        s = ln.strip()
        if s.startswith("_have =") or s.startswith("_do =") \
           or s.startswith("if ") or s.startswith("else:") \
           or s.startswith("elif "):
            continue
        keep.append(s if s.startswith("echo") or s.startswith("gzip")
                    or s.startswith("exit") or s.startswith("#") or not s
                    else ln)
    text = "\n".join(keep) + "\n"

# THE ONLY EDIT: the two absolute paths are moved under the work directory.
# Counted, so a generator that stops emitting one of them cannot slip past.
subs = 0
for real, fake in (("'/etc/modules'", "'%s/etc/modules'" % work),
                   ("'/lib/modules/%s/modules.dep'" % kver,
                    "'%s/lib/modules/%s/modules.dep'" % (work, kver))):
    subs += text.count(real)
    text = text.replace(real, fake)
open(out, "w").write(text)
print("hookidem: INFO %s hook: %d lines, %d path substitutions"
      % (mode, len(text.splitlines()), subs))
PY
}

mkdir -p "$WORK/etc" "$WORK/lib/modules/$KVER" "$WORK/srv"
seed() {
    : > "$WORK/etc/modules"
    : > "$WORK/lib/modules/$KVER/modules.dep"
}
mods_n() { grep -c . "$WORK/etc/modules" 2>/dev/null || echo 0; }
deps_n() { grep -c . "$WORK/lib/modules/$KVER/modules.dep" 2>/dev/null || echo 0; }

# run_hook <hookfile> <logfile> <chan-dir> <path-for-grep>
run_hook() {
    PATH="$4" HAMFDNS_DIR="$3" "$WORK/bin/hamsh" "$1" >"$2" 2>&1
    return 0
}
hook_said() { grep -c '^\[hamnix-drivers-test\]' "$1" 2>/dev/null || echo 0; }

gen_hook "$WORK/install.hamsh"       guarded
gen_hook "$WORK/install-plain.hamsh" plain
info "the guarded hook, verbatim:"
sed 's/^/hookidem:   | /' "$WORK/install.hamsh"

# ===========================================================================
# ARM A -- the hook as it will ship, twice
# ===========================================================================
echo "hookidem: === ARM A: the generated hook, run twice, everything available"
seed
run_hook "$WORK/install.hamsh" "$WORK/a1.log" "$WORK/srv" "$WORK/bin"
SAID1=$(hook_said "$WORK/a1.log")
M1=$(mods_n); D1=$(deps_n)
info "run 1: hook printed $SAID1 of its own lines; /etc/modules $M1, modules.dep $D1"
if [ "$SAID1" -gt 0 ]; then
    ok "the hook RAN (a hook that fails to parse prints nothing and still exits 0)"
else
    bad "the hook printed none of its own lines -- it did not run, and every count below would be a zero that PASSES. hamsh output follows:"
    sed 's/^/hookidem:   /' "$WORK/a1.log" | tail -20
fi
[ "$M1" = "$NMODS" ] && ok "first install added $NMODS module lines" \
                     || bad "first install added $M1 module lines, not $NMODS"
[ "$D1" = "$NDEPS" ] && ok "first install added $NDEPS modules.dep lines" \
                     || bad "first install added $D1 modules.dep lines, not $NDEPS"

run_hook "$WORK/install.hamsh" "$WORK/a2.log" "$WORK/srv" "$WORK/bin"
SAID2=$(hook_said "$WORK/a2.log")
M2=$(mods_n); D2=$(deps_n)
info "run 2: hook printed $SAID2 of its own lines; /etc/modules $M2, modules.dep $D2"
[ "$SAID2" -gt 0 ] && ok "the second run of the hook also ran" \
                   || bad "the second run printed nothing -- it did not run"
if [ "$M2" = "$M1" ] && [ "$D2" = "$D1" ]; then
    ok "THE SECOND INSTALL ADDED NOTHING: /etc/modules still $M2 lines, modules.dep still $D2"
else
    bad "the second install added $((M2 - M1)) module line(s) and $((D2 - D1)) modules.dep line(s) -- the hook is not idempotent"
    sed 's/^/hookidem:   /' "$WORK/a2.log" | tail -20
fi

# ===========================================================================
# ARM B -- command substitution unavailable
# ===========================================================================
# `$( )` needs a pipe channel (sys_pipechan -> user/linux-fdns.c), which needs
# a writable chan directory (HAMFDNS_DIR, /srv by default).  When it is not
# there hamsh says so on stderr and the capture is the EMPTY STRING.  The hook
# must then APPEND -- the old behaviour -- because a test it could not run is
# not evidence that the line is already there.  Losing a module is a machine
# that does not boot its disk controller; a duplicate line is 5.3 KB.
echo "hookidem: === ARM B: no pipe channel, so the guard cannot be evaluated"
seed
run_hook "$WORK/install.hamsh" "$WORK/b1.log" "/proc/no-such-chan-dir" "$WORK/bin"
MB=$(mods_n); DB=$(deps_n)
info "with no chan dir: /etc/modules $MB, modules.dep $DB"
grep -q 'no pipe channel available' "$WORK/b1.log" \
    && ok "hamsh named the failed substitution on stderr rather than answering empty in silence" \
    || info "hamsh did not print 'no pipe channel available' -- the substitution may have worked anyway here"
if [ "$MB" = "$NMODS" ] && [ "$DB" = "$NDEPS" ]; then
    ok "with the guard unevaluable the hook STILL INSTALLED every line -- it degrades to the unconditional append, it does not lose a module"
else
    bad "with the guard unevaluable the hook installed $MB/$NMODS module lines and $DB/$NDEPS dep lines -- a module was LOST"
    sed 's/^/hookidem:   /' "$WORK/b1.log" | tail -20
fi
grep -q 'could not be read to test' "$WORK/b1.log" \
    && ok "and it SAID it was appending unconditionally" \
    || bad "it appended unconditionally without saying so -- silence is the bug"

# ===========================================================================
# ARM C -- THE NEGATIVE CONTROL
# ===========================================================================
# The same hook with the conditional removed. If this does NOT duplicate, then
# ARM A's "added nothing" is measuring an empty instrument and means nothing.
echo "hookidem: === ARM C: negative control -- the guard removed, run twice"
seed
run_hook "$WORK/install-plain.hamsh" "$WORK/c1.log" "$WORK/srv" "$WORK/bin"
run_hook "$WORK/install-plain.hamsh" "$WORK/c2.log" "$WORK/srv" "$WORK/bin"
MC=$(mods_n); DC=$(deps_n)
info "unguarded, twice: /etc/modules $MC lines (guarded gave $M2), modules.dep $DC (guarded gave $D2)"
if [ "$MC" = "$((NMODS * 2))" ] && [ "$DC" = "$((NDEPS * 2))" ]; then
    ok "THE CONTROL DUPLICATES: $MC module lines and $DC dep lines for two installs -- ARM A's zero is a real zero"
else
    bad "the unguarded hook did NOT duplicate ($MC module lines, $DC dep lines) -- this gate cannot tell an idempotent hook from a hook that never appended, and ARM A above is NOT EVIDENCE"
    sed 's/^/hookidem:   /' "$WORK/c2.log" | tail -20
fi

echo "hookidem: --------------------------------------------------------------"
echo "hookidem: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
