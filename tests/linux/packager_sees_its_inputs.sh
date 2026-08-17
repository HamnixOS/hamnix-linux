#!/usr/bin/env bash
# tests/linux/packager_sees_its_inputs.sh — THE PACKAGER'S STALENESS CHECK MUST
# WATCH EVERY INPUT THAT CHANGES THE BYTES IT SHIPS.
#
# scripts/hamlinux_packages.py's build_one() reuses an existing
# build/repo-obj/<cmd>.elf whenever that ELF is newer than
# newest_shared_input(). Anything that function does not look at is a file you
# can change, rebuild nothing, and PUBLISH LAST WEEK'S BINARY -- with every
# package name present, every dependency resolving and every sha256 in
# index.json matching the bytes actually served. That is not a hypothetical
# shape: it is how hamnix-desktop 1.0.10 shipped a desktop that mapped no
# windows, and the function's own docstring carries the post-mortem.
#
# AND NOTHING ELSE IN THE TREE CAN CATCH IT. Every gate in tests/linux/ builds
# what it asserts on from source through scripts/hamlinux_build.sh on every
# run, so a gate ALWAYS holds a binary built from the current tree by the
# current compiler. Only the packager reuses. So the failure this closes has
# exactly one signature -- THE TREE'S PROGRAM WORKS AND THE CHANNEL'S DOES NOT
# -- and it is the signature that was reported against 1.0.25.
#
# FOUR HOLES WERE OPEN WHEN THIS WAS WRITTEN, measured with build_one's own
# reuse predicate against a populated build/repo-obj:
#
#     user/hambrowse_tabs.ad          reuse=True   STALE BINARY SHIPS
#     user/http9.ad                   reuse=True   STALE BINARY SHIPS
#     scripts/adder_llvm_runtime.c    reuse=True   STALE BINARY SHIPS
#     build/cutover/host_ac.elf       reuse=True   STALE BINARY SHIPS
#
# The first two are LIBRARY MODULES in user/ -- files with no `def main`, which
# scripts/hamlinux_build.sh exits 13 on and names in its own header; hambrowse
# imports the first, hpm/curl/wget the second, and only user/<cmd>.ad itself
# was ever stat-ed. The third is on the clang line of every binary in the
# distribution. The fourth IS THE COMPILER.
#
# WHY IT ASKS FOR THE LIST INSTEAD OF TOUCHING FILES. The natural probe --
# `touch` a candidate and read build_one's predicate back -- is destructive: it
# writes a future mtime into the working tree and, if it is killed between the
# touch and the restore, leaves a source file dated an hour ahead that makes
# every later build reuse nothing. So scripts/hamlinux_packages.py exposes
# shared_inputs() and this asks it for the SET. Membership is the same
# assertion without the hazard.
#
# THE CONTROL IS PART OF THE GATE, not an aside. An `in` test that can only
# ever say yes is worth nothing, so this also asserts that a path which MUST
# NOT be in the set is absent (adder/compiler/*.ad -- see the reason beside it
# in hamlinux_packages.py) and that a nonexistent path is absent. If either of
# those ever passes, the membership test has stopped discriminating and this
# gate says so instead of going green on a set that contains everything.
#
# Reads only. Builds nothing, runs no binary, touches no device.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"
# Isolated like every other gate here. It has no display, no window system and
# no /tmp of its own to protect -- but "this one did not need it" is the
# argument that ends with a gate reaching something it should not, and the
# helper costs milliseconds.
. tests/linux/private_ns.sh
priv_ns_reexec "$@"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }

echo "== does scripts/hamlinux_packages.py watch everything that changes its output?"

SET="$(PROJ_ROOT="$PROJ_ROOT" python3 - <<'PY'
import importlib.util, os, sys
root = os.environ["PROJ_ROOT"]
sys.argv = ["hamlinux_packages.py"]
spec = importlib.util.spec_from_file_location(
    "hp", os.path.join(root, "scripts/hamlinux_packages.py"))
hp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hp)
for f in hp.shared_inputs():
    print(os.path.relpath(f, root))
PY
)" || SET=""

# An empty or tiny set is not a pass. The whole gate below is `grep -qx`, and
# grep answers "no" just as confidently about a list that was never produced --
# a traceback, a renamed function, a python that did not run. Refuse first.
NSET="$(printf '%s\n' "$SET" | grep -c . || true)"
if [ "${NSET:-0}" -lt 100 ]; then
    bad "shared_inputs() returned $NSET paths -- it did not run, or it no longer returns the list. NOTHING below would mean anything, so this gate stops here."
    printf '%s\n' "$SET" | tail -5 | sed 's/^/       /'
    echo
    echo "packager_sees_its_inputs: $PASS passed, $FAIL failed"
    echo "FAIL packager_sees_its_inputs"; exit 1
fi
ok "shared_inputs() produced $NSET paths"

# --- MUST BE WATCHED ------------------------------------------------------
# Each with the reason it is here, because a bare path in a list is the thing
# that gets deleted by the next person who finds it inconvenient.
MUST="lib/hamui.ad:the widget toolkit every GUI program links
lib/web/js/interp.ad:the JS interpreter, four directories deep -- invisible until the walk landed
user/linux-wsys.c:the window-system backend linked into every binary
user/linux-syscalls.c:the hosted syscall half
user/hambrowse_tabs.ad:a LIBRARY MODULE (no def main) that hambrowse imports
user/http9.ad:a LIBRARY MODULE that hpm, curl and wget import
user/net9.ad:a LIBRARY MODULE the /net dialers import
user/httpdconf.ad:a LIBRARY MODULE httpd imports
scripts/adder_llvm_runtime.c:ON THE CLANG LINE OF EVERY BINARY IN THE DISTRIBUTION
scripts/hamlinux_build.sh:the builder itself
build/cutover/host_ac.elf:THE COMPILER -- it decides every byte of every program"
while IFS= read -r row; do
    [ -n "$row" ] || continue
    p="${row%%:*}"; why="${row#*:}"
    if printf '%s\n' "$SET" | grep -qx -- "$p"; then
        ok "$p is watched ($why)"
    else
        bad "$p IS NOT WATCHED -- change it and scripts/hamlinux_packages.py rebuilds NOTHING and publishes the previous binary. It is $why."
    fi
done <<EOF
$MUST
EOF

# --- MUST NOT BE WATCHED (the control) ------------------------------------
# If these pass, `grep -qx` has stopped discriminating and every ok above is
# meaningless.
for row in \
    "adder/compiler/ssa_llvm.ad:a compiler SOURCE -- it changes nothing until host_ac is re-bootstrapped, and that moves host_ac.elf, which IS watched" \
    "scripts/no_such_file_dcf0.txt:a path that does not exist"
do
    p="${row%%:*}"; why="${row#*:}"
    if printf '%s\n' "$SET" | grep -qx -- "$p"; then
        bad "CONTROL FAILED: $p is in the set, and it must not be ($why). The membership test above can no longer tell watched from unwatched, so nothing it said is evidence."
    else
        ok "control: $p is correctly absent ($why)"
    fi
done

echo
echo "packager_sees_its_inputs: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || { echo "FAIL packager_sees_its_inputs"; exit 1; }
echo "PASS packager_sees_its_inputs"
