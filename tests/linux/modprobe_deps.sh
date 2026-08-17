#!/usr/bin/env bash
#
# REGISTRATION, 2026-08-17. Until this date scripts/test_gate_registration.sh
# globbed only scripts/test_*.sh, so this directory was invisible to the gate
# against unregistered gates and every file in it read as coverage without
# being coverage. This gate is ON-DEMAND: not in ci_battery_manifest.txt
# because it boots a machine through `scripts/hamlinux_vm.sh`.
#
# tests/linux/modprobe_deps.sh — `modprobe NAME` resolves a name to a module,
# loads its DEPENDENCIES IN THE RIGHT ORDER, and is honest when it cannot.
#
# THE GAP THIS EXISTS FOR, from docs/runsweep_unhealthy.md's Kind 1 list:
#
#   | `modprobe` | `/lib/modules/modules.dep` | no `modules.dep` is generated
#     anywhere on this port. [...] PID 1 loads them **by absolute path** --
#     its own comment notes that an autoload "would quietly not happen"
#
# On a stock Debian kernel every graphics, filesystem and network driver is a
# module. `insmod` takes a path and resolves nothing, so a driver that needs
# three other modules loaded first simply fails; `modprobe` is the command
# that fixes that, and it could not work, because the table it resolves
# through did not exist.
#
# WHY `bridge` AND NOT SOMETHING SIMPLER
# --------------------------------------
# A LEAF module would pass this test with no modules.dep at all -- the whole
# point of the table is ORDERING, so a module with no dependencies proves
# nothing. `bridge` is a real three-deep chain on the stock kernel:
#
#   kernel/net/bridge/bridge.ko: kernel/net/802/stp.ko kernel/net/llc/llc.ko
#
# llc must be in the kernel before stp, and stp before bridge, or the load
# fails on an unresolved symbol. It is also NOT in /etc/modules, so nothing
# has loaded it before the assertion runs: this measures modprobe's work and
# not the boot's. (Every module the image stages IS boot-loaded, which is why
# the image gained HAMLINUX_MODULES_EXTRA -- staged and in the table, not
# booted.) And it touches no hardware: a bridge with no ports attached is
# inert, and it is all inside a VM regardless.
#
# WHAT IS ASSERTED, and note that NONE of it is an exit code
# ----------------------------------------------------------
#   1. before: /proc/modules contains none of llc, stp, bridge.
#   2. `modprobe -v bridge` names the three loads in leaf-first order.
#   3. after: /proc/modules contains ALL THREE. This is the real assertion --
#      the kernel's own list, not modprobe's opinion of itself. A modprobe
#      that exits 0 having loaded nothing is worse than one that fails.
#   4. `lsmod` (which reads /proc/modules) shows them too, so the tool a
#      person would actually check with agrees with the kernel. It used to
#      print a hard-coded row for a module that was not loaded.
#   5. HONESTY: `modprobe nosuchmodule` exits non-zero and says WHICH table
#      it consulted; `modprobe -d /nonexistent bridge` refuses by name. A
#      gap must never answer something success-shaped instead of the truth.
#
# Usage: tests/linux/modprobe_deps.sh [seconds]
#   HAMLINUX_MODDEP_REUSE=1   reuse an already-built image in $WORK
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$PROJ_ROOT"

WAIT="${1:-240}"
# A PRIVATE image directory. build/image is one directory on a box several
# agents share, and a gate that rebuilds it races whoever else is booting.
WORK="${HAMLINUX_MODDEP_WORK:-$HOME/.hamnix-build/modprobe-deps}"
mkdir -p "$WORK"
export HAMLINUX_IMAGE_DIR="$WORK/image"
export HAMLINUX_VNC="${HAMLINUX_VNC:-none}"
export HAMLINUX_DISTRO_RO=1
export TMPDIR="${TMPDIR:-$PROJ_ROOT/build/tmp}"
mkdir -p "$TMPDIR"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $*"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
say() { echo "[moddep] $*"; }

LOG="$WORK/boot.log"

# --- the rc the guest runs ------------------------------------------------
# Prepended to the real boot rc rather than sourcing it: etc/rc.boot.linux is
# staged AS /etc/rc.boot and under no other name, so sourcing the staged name
# would be a loop (tests/linux/reboot_device.sh records the same thing).
cat etc/rc.boot.linux > "$WORK/rc.moddep"
cat >> "$WORK/rc.moddep" <<'RC'

echo '[moddep] ===== modprobe: name -> module -> dependencies'

echo '[moddep] --- the table modprobe resolves through'
cat @KVERDEP@
echo '[moddep] table status:' $status

echo '[moddep] --- BEFORE: the kernel'"'"'s own module list'
echo '[moddep] BEFORE_BEGIN'
cat /proc/modules
echo '[moddep] BEFORE_END'

echo '[moddep] --- modprobe -v bridge (llc, then stp, then bridge)'
echo '[moddep] LOAD_BEGIN'
modprobe -v bridge
echo '[moddep] modprobe status:' $status
echo '[moddep] LOAD_END'

echo '[moddep] --- AFTER: the kernel'"'"'s own module list'
echo '[moddep] AFTER_BEGIN'
cat /proc/modules
echo '[moddep] AFTER_END'

echo '[moddep] --- lsmod, the tool a person would check with'
echo '[moddep] LSMOD_BEGIN'
lsmod
echo '[moddep] LSMOD_END'

echo '[moddep] --- honesty 1: a name that is in no table'
echo '[moddep] MISS_BEGIN'
modprobe nosuchmodule
echo '[moddep] miss status:' $status
echo '[moddep] MISS_END'

echo '[moddep] --- honesty 2: no table at all (the port, before this change)'
echo '[moddep] NODEP_BEGIN'
modprobe -d /lib/modules/nonexistent.dep bridge
echo '[moddep] nodep status:' $status
echo '[moddep] NODEP_END'

echo '[moddep] ===== PHASE 2: a module that arrived AFTER the image was built'
# 8021q and its four dependencies are ON THE DISK and deliberately NOT in
# modules.dep -- the state a machine is in the moment `hpm install
# hamnix-drivers-gpu-intel` puts i915.ko on it. The table was written by
# depmod when the image was built and cannot know about it.

echo '[moddep] --- before the package hook runs, modprobe must REFUSE'
echo '[moddep] LATE_MISS_BEGIN'
modprobe -v 8021q
echo '[moddep] late miss status:' $status
echo '[moddep] LATE_MISS_END'
echo '[moddep] LATE_BEFORE_BEGIN'
cat /proc/modules
echo '[moddep] LATE_BEFORE_END'

# THE UNQUOTED REDIRECT, which is what an install hook looked like before
# anyone noticed. hamsh's lexer splits a bare word at '+', and every Debian
# kernel release has one, so this used to write to /lib/modules/6.12.85,
# leave the table untouched and exit 0. The probe line below must appear in
# the table on the next line, or that is back.
echo '[moddep] UNQ_BEGIN'
echo 'kernel/moddep/unquoted-probe.ko:' >> @KVERDEP@
echo '[moddep] unquoted append status:' $status
echo '[moddep] UNQ_END'

echo '[moddep] --- now the exact lines a package install hook appends'
@HOOKLINES@
echo '[moddep] hook status:' $status
# `cat`, not `tail`: tail on a regular file WEDGES this shell (measured --
# the guest sat at this line until the host timeout took the VM away). That
# is a separate gap and not this gate's; cat terminates.
echo '[moddep] TABLETAIL_BEGIN'
cat @KVERDEP@
echo '[moddep] TABLETAIL_END'

echo '[moddep] --- and modprobe resolves it'
echo '[moddep] LATE_LOAD_BEGIN'
modprobe -v 8021q
echo '[moddep] late load status:' $status
echo '[moddep] LATE_LOAD_END'
echo '[moddep] LATE_AFTER_BEGIN'
cat /proc/modules
echo '[moddep] LATE_AFTER_END'

echo '[moddep] DONE'
RC

# The kernel the image is built for is the newest /boot/vmlinuz-* -- chosen the
# same way scripts/hamlinux_image.sh chooses it, so the guest's table is at the
# path named here.
KVER="$(basename "$(ls -1 /boot/vmlinuz-* 2>/dev/null | sort -V | tail -1)" \
        | sed 's/^vmlinuz-//')"
[ -n "$KVER" ] || { echo "FAIL: no /boot/vmlinuz-* on this host"; exit 1; }
sed -i "s|@KVERDEP@|/lib/modules/$KVER/modules.dep|" "$WORK/rc.moddep"

# --- the phase-2 hook lines ----------------------------------------------
# Generated by scripts/hamlinux_packages.py's OWN generator, not by a copy of
# it here: what phase 2 measures is the thing the driver packages actually
# ship, so a change that broke the real hook has to break this too.
LATE_MOD=8021q
python3 - "$KVER" "$LATE_MOD" > "$WORK/hooklines" <<'PY'
import importlib.util, os, subprocess, sys
kver, mod = sys.argv[1], sys.argv[2]
root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__ if "__file__" in dir() else "."))))
spec = importlib.util.spec_from_file_location(
    "hp", os.path.join(os.getcwd(), "scripts/hamlinux_packages.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
chain = m.modprobe_chain(kver, mod)
if not chain:
    sys.exit("no modprobe chain for %s" % mod)
prefix = "/lib/modules/%s/" % kver
canon = []
for ko in chain:
    rel = ko[len(prefix):]
    for ext in (".xz", ".gz", ".zst"):
        if rel.endswith(ext):
            rel = rel[:-len(ext)]
    canon.append(prefix + rel)
lines = m.dep_lines_for_paths(kver, canon)
if not lines:
    sys.exit("dep_lines_for_paths returned nothing")
for l in lines:
    print("echo '%s' >> /lib/modules/%s/modules.dep" % (l, kver))
PY
[ -s "$WORK/hooklines" ] || { echo "FAIL: could not generate the hook lines for $LATE_MOD"; exit 1; }
python3 - "$WORK/rc.moddep" "$WORK/hooklines" <<'PY'
import sys
rc, hook = sys.argv[1], sys.argv[2]
body = open(rc).read().replace("@HOOKLINES@", open(hook).read().rstrip("\n"))
open(rc, "w").write(body)
PY

# --- build --------------------------------------------------------------
if [ -n "${HAMLINUX_MODDEP_REUSE:-}" ] && [ -f "$HAMLINUX_IMAGE_DIR/initramfs.cpio.gz" ]; then
    say "reusing $HAMLINUX_IMAGE_DIR"
else
    say "staging an image (bridge STAGED but NOT boot-loaded; $LATE_MOD on disk but NOT in the table) in $HAMLINUX_IMAGE_DIR"
    HAMLINUX_MODULES_EXTRA="bridge" HAMLINUX_MODULES_LATE="$LATE_MOD" \
    HAMLINUX_RC="$WORK/rc.moddep" \
        scripts/hamlinux_image.sh "$HAMLINUX_IMAGE_DIR" \
        >"$WORK/build.log" 2>&1 || {
            echo "FAIL: image build"; tail -25 "$WORK/build.log"; exit 1; }
fi
grep -h "modules.dep" "$WORK/build.log" 2>/dev/null | sed 's/^/[moddep] /'

# The staged table, checked on the host before anything boots: if depmod did
# not write a bridge line there is nothing for the guest to resolve and the
# boot below would be measuring the wrong thing.
STAGED_DEP="$(ls "$HAMLINUX_IMAGE_DIR"/root/lib/modules/*/modules.dep 2>/dev/null | head -1)"
if [ -z "$STAGED_DEP" ]; then
    bad "no modules.dep was staged into the image at all -- depmod did not run"
else
    ok "the image carries $(basename "$(dirname "$STAGED_DEP")")/modules.dep ($(grep -c . "$STAGED_DEP") modules)"
    if grep -q '^kernel/net/bridge/bridge\.ko:.*stp\.ko.*llc\.ko' "$STAGED_DEP"; then
        ok "bridge's line names both of its dependencies: $(grep '^kernel/net/bridge/bridge' "$STAGED_DEP")"
    else
        bad "bridge has no dependency line in the staged table"
    fi
fi
# bridge must NOT be boot-loaded, or the guest assertion proves nothing.
if grep -q 'bridge\.ko' "$HAMLINUX_IMAGE_DIR/root/etc/modules" 2>/dev/null; then
    bad "bridge is in /etc/modules -- the boot would load it and modprobe would be untested"
else
    ok "bridge is NOT in /etc/modules -- nothing but modprobe can put it in the kernel"
fi

# --- boot ---------------------------------------------------------------
say "booting (ceiling ${WAIT}s)"
( sleep 5 ) | timeout "$((WAIT + 15))" \
    scripts/hamlinux_vm.sh script --timeout "$WAIT" >"$LOG" 2>&1
say "boot log: $LOG ($(wc -l < "$LOG") lines)"

sect() {  # sect BEGIN END  -> the lines between the two markers
    sed -n "/\[moddep\] $1/,/\[moddep\] $2/p" "$LOG"
}

if ! grep -q '\[moddep\] DONE' "$LOG"; then
    bad "the guest script did not run to completion -- no DONE marker"
    tail -30 "$LOG" | sed 's/^/[moddep]   /'
    echo; echo "$PASS passed, $FAIL failed"; exit 1
fi
ok "the guest ran to completion"

BEFORE="$(sect BEFORE_BEGIN BEFORE_END)"
AFTER="$(sect AFTER_BEGIN AFTER_END)"
LOADOUT="$(sect LOAD_BEGIN LOAD_END)"
LSMODOUT="$(sect LSMOD_BEGIN LSMOD_END)"

# A floor on /proc/modules itself. If the file were empty or unreadable every
# "not loaded before" check below would pass for the wrong reason -- the same
# shape as a coverage gate that reports on an empty list.
if [ "$(echo "$BEFORE" | grep -c '^[a-z_0-9]* [0-9]')" -lt 5 ]; then
    bad "/proc/modules listed fewer than 5 modules before the test -- not a machine this can be measured on"
else
    ok "/proc/modules is readable and lists $(echo "$BEFORE" | grep -c '^[a-z_0-9]* [0-9]') modules before the test"
fi

for m in llc stp bridge; do
    if echo "$BEFORE" | grep -q "^$m "; then
        bad "$m was ALREADY in the kernel before modprobe ran -- this proves nothing"
    else
        ok "$m is not in the kernel before modprobe runs"
    fi
done

# The ORDER. Leaf-most first: llc, then stp, then bridge. This is the whole
# reason modules.dep exists, and it is what insmod cannot do.
LORDER="$(echo "$LOADOUT" | sed -n 's/^modprobe: loaded \([a-z_0-9]*\) .*/\1/p' | tr '\n' ' ')"
say "modprobe loaded, in order: $LORDER"
case "$LORDER" in
    "llc stp bridge "*) ok "loaded leaf-first: llc, stp, bridge" ;;
    *) bad "load order was '$LORDER', not 'llc stp bridge'" ;;
esac

if echo "$LOADOUT" | grep -q 'modprobe status: 0'; then
    ok "modprobe exited 0"
else
    bad "modprobe exited non-zero: $(echo "$LOADOUT" | grep 'modprobe status:')"
fi

# THE ASSERTION THAT MATTERS: the kernel's own list.
for m in llc stp bridge; do
    if echo "$AFTER" | grep -q "^$m "; then
        ok "$m IS IN THE KERNEL afterwards (/proc/modules): $(echo "$AFTER" | grep "^$m " | head -1)"
    else
        bad "$m is NOT in /proc/modules after modprobe claimed to load it"
    fi
done

# bridge must be USING stp -- the refcount column is the kernel agreeing that
# the dependency is real and not just two modules that happened to load.
if echo "$AFTER" | grep -q '^llc .*stp'; then
    ok "the kernel records stp as a USER of llc -- the dependency is real: $(echo "$AFTER" | grep '^llc ')"
else
    bad "llc's used-by column does not name stp; the dependency edge is not what was loaded"
fi

for m in llc stp bridge; do
    if echo "$LSMODOUT" | grep -q "^$m "; then
        ok "lsmod shows $m"
    else
        bad "lsmod does not show $m although /proc/modules does"
    fi
done
if echo "$LSMODOUT" | grep -q '^kmod_hello'; then
    bad "lsmod is still printing the hard-coded kmod_hello row"
else
    ok "lsmod prints no fabricated row"
fi

# --- honesty -------------------------------------------------------------
MISS="$(sect MISS_BEGIN MISS_END)"
if echo "$MISS" | grep -q 'miss status: 0'; then
    bad "modprobe nosuchmodule EXITED 0 -- success-shaped, having loaded nothing"
else
    ok "modprobe nosuchmodule exits non-zero"
fi
if echo "$MISS" | grep -q 'module not found in /lib/modules/.*modules.dep'; then
    ok "and names the table it consulted: $(echo "$MISS" | grep 'module not found' | head -1)"
else
    bad "modprobe nosuchmodule did not name the table it consulted"
fi

NODEP="$(sect NODEP_BEGIN NODEP_END)"
if echo "$NODEP" | grep -q 'nodep status: 0'; then
    bad "modprobe with a missing modules.dep EXITED 0"
else
    ok "modprobe with a missing modules.dep exits non-zero"
fi
if echo "$NODEP" | grep -q 'cannot read modules.dep at /lib/modules/nonexistent.dep'; then
    ok "and says which file it could not read"
else
    bad "modprobe did not name the modules.dep it could not read"
fi

# --- PHASE 2: the module that arrived after the image was built ----------
# The question the design has to answer: a modules.dep staged at build time is
# stale the moment a package installs a NEW module. Both halves are measured
# here -- that modprobe REFUSES BY NAME before the lines arrive (it must never
# resolve to nothing quietly), and that it resolves after.
TABLE2="$(sect TABLETAIL_BEGIN TABLETAIL_END)"
if echo "$TABLE2" | grep -q '^kernel/moddep/unquoted-probe\.ko:'; then
    ok "an UNQUOTED >> into /lib/modules/<release>/ lands (the '+' in the release used to eat it)"
else
    bad "an unquoted >> into the table wrote nothing -- hamsh is splitting the path at '+' again"
fi

LMISS="$(sect LATE_MISS_BEGIN LATE_MISS_END)"
LBEFORE="$(sect LATE_BEFORE_BEGIN LATE_BEFORE_END)"
LLOAD="$(sect LATE_LOAD_BEGIN LATE_LOAD_END)"
LAFTER="$(sect LATE_AFTER_BEGIN LATE_AFTER_END)"

# The .ko really is on the disk -- otherwise "refused" would be right for a
# boring reason and phase 2 would be measuring nothing.
if ls "$HAMLINUX_IMAGE_DIR"/root/lib/modules/*/kernel/net/8021q/8021q.ko >/dev/null 2>&1; then
    ok "8021q.ko IS on the image's disk"
else
    bad "8021q.ko is not on the image's disk -- phase 2 would prove nothing"
fi
if grep -q '8021q' "$STAGED_DEP" 2>/dev/null; then
    bad "8021q is in the build-time modules.dep -- it is not the post-install case"
else
    ok "8021q is NOT in the build-time modules.dep -- exactly the post-hpm-install state"
fi

if echo "$LMISS" | grep -q 'late miss status: 0'; then
    bad "modprobe 8021q EXITED 0 before its dependency lines existed"
else
    ok "modprobe 8021q exits non-zero while the table does not describe it"
fi
if echo "$LMISS" | grep -q 'that package.s install hook did not append'; then
    ok "and it names the cause instead of implying the driver does not exist"
else
    bad "modprobe's refusal did not name the stale-table cause"
fi
if echo "$LBEFORE" | grep -q '^8021q '; then
    bad "8021q was in the kernel before the hook lines were appended"
else
    ok "8021q is not in the kernel before the hook lines are appended"
fi

# ...and after the hook lines land, the same command works.
LORDER2="$(echo "$LLOAD" | sed -n 's/^modprobe: loaded \([a-z_0-9]*\) .*/\1/p' | tr '\n' ' ')"
say "after the hook lines, modprobe loaded: $LORDER2"
if echo "$LLOAD" | grep -q 'late load status: 0'; then
    ok "modprobe 8021q exits 0 once the package's own dependency lines are in the table"
else
    bad "modprobe 8021q still failed after the hook lines were appended: $(echo "$LLOAD" | grep 'late load status')"
fi
for m in garp mrp 8021q; do
    if echo "$LAFTER" | grep -q "^$m "; then
        ok "$m IS IN THE KERNEL (/proc/modules): $(echo "$LAFTER" | grep "^$m " | head -1)"
    else
        bad "$m is not in /proc/modules after the late modprobe"
    fi
done

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || exit 1
