#!/usr/bin/env bash
# tests/linux/enter_env.sh — DOES THE ENVIRONMENT CROSS `enter'?
#
# docs/linux_distro_namespaces.md §8.5 recorded this, explicitly UNMEASURED:
#
#   > `enter <name>` against an `ns clean { }` template rforks with RFCNAMEG,
#   > whose Pgrp is EMPTY -- and `hamsh` re-seeds only /fd in that child. The
#   > environment does not appear to cross: HAMNIX_DE_XSESSION=0, exported
#   > before the `enter`, did not reach /etc/de-ns-run on the other side.
#   > That means the HOME / XDG_RUNTIME_DIR / WAYLAND_DISPLAY / XDG_CONFIG_HOME
#   > exports at the bottom of /etc/rc.de-ns/<name> may not be reaching the
#   > client either -- the shim defaults all four to the same values, so this
#   > has been invisible.
#
# That last clause is the whole reason this file exists. A shim that works
# because it re-derives everything it needs is not the same as an environment
# that crosses, and you cannot tell the two apart by watching it work. So every
# variable here is set to a SENTINEL that is not any default anywhere in the
# tree: `/etc/de-ns-run` defaults WAYLAND_DISPLAY to `wayland-0', so a probe
# that reads back `wayland-0' has learned nothing. It reads back
# `envx-sentinel-wl' or it did not cross.
#
# THE TWO BOUNDARIES ARE ASKED SEPARATELY, because the received account blames
# the wrong one:
#
#   A. `enter` itself      -- export in a hamsh, then `enter debian { env }`.
#                             rfork(RFPROC|RFCNAMEG) is a process FORK; the
#                             question is whether RFCNAMEG's empty Pgrp takes
#                             the environment with it.
#   B. exec'ing a NEW hamsh -- `/bin/hamsh /etc/envprobe.rc`, which is exactly
#                             what the DE panel does when it spawns
#                             `/bin/hamsh /etc/rc.de-ns/<name> <prog>`, and
#                             what rc.boot did when it ran the launcher rc with
#                             HAMNIX_DE_XSESSION exported.
#
# Both arms are run again after `setuid 1001`, because that is where the DE
# launcher actually is.
#
# Usage: tests/linux/enter_env.sh [seconds]
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

export HAMLINUX_VNC="${HAMLINUX_VNC:-none}"
export HAMLINUX_DISTRO_RO="${HAMLINUX_DISTRO_RO:-1}"

WAIT="${1:-150}"
WORK="build/enterenv"; mkdir -p "$WORK"
IMG=build/image
[ -f "$IMG/distro.ext4" ] || { echo "no distro image" >&2; exit 1; }

# The probe rc goes in as a SECOND CPIO SEGMENT (docs/steam_namespace.md §11):
# no debugfs, nothing shared is written. It is a FRESH hamsh's rc, which is the
# whole of arm B -- a new hamsh has to `source /etc/rc.distros` to get the
# template at all, exactly as /etc/rc.de-ns/<name> does.
SEG="$WORK/seg"; rm -rf "$SEG"; mkdir -p "$SEG/etc"
cat > "$SEG/etc/envprobe.rc" <<'PRC'
# A FRESH hamsh, exec'd by the rc above with the sentinels exported.
source '/etc/rc.distros'
echo '[envx] B1 new-hamsh sees HAMNIX_ENVPROBE=' $HAMNIX_ENVPROBE
echo '[envx] B2 new-hamsh sees WAYLAND_DISPLAY=' $WAYLAND_DISPLAY
echo '[envx] B3 new-hamsh, across enter:'
enter debian { /usr/bin/env }
# `exit` IS REQUIRED, and the first run of this file proved it the hard way.
# hamsh sources an rc named on its command line and then FALLS THROUGH to the
# interactive prompt (user/hamsh.ad, main(): "then falls through to the
# interactive prompt below"). Without this the probe shell sat at `hamsh$'
# holding the console, the parent rc never got control back, arms C and D never
# ran, and the only symptom was `the boot did not reach DONE' -- a timeout that
# looks exactly like a hang in the thing being measured rather than in the
# measuring apparatus.
exit 0
PRC

cat > "$WORK/rc.boot" <<'RC'
echo 'rc.boot: does the environment cross enter'
ln -s /dev/console /dev/cons
bind '#distro/debian' /n/debian
source '/etc/rc.distros'

# SENTINELS, NOT DEFAULTS. Every one of these is a value nothing in the tree
# would produce on its own, so reading it back on the far side is proof of
# crossing rather than proof of re-derivation.
HAMNIX_ENVPROBE='envx-crossed'
export HAMNIX_ENVPROBE
WAYLAND_DISPLAY='envx-sentinel-wl'
export WAYLAND_DISPLAY
XDG_RUNTIME_DIR='/envx-sentinel-run'
export XDG_RUNTIME_DIR
HOME='/envx-sentinel-home'
export HOME
HAMNIX_DE_XSESSION='0'
export HAMNIX_DE_XSESSION

echo '[envx] --- A: the SAME hamsh, across enter, as root'
echo '[envx] A-BEGIN'
enter debian { /usr/bin/env }
echo '[envx] A-END'

echo '[envx] --- B: across an exec into a NEW hamsh, as root'
echo '[envx] B-BEGIN'
/bin/hamsh /etc/envprobe.rc
echo '[envx] B-END'

# AND WHERE THE DE LAUNCHER ACTUALLY IS.
setuid 1001
echo '[envx] --- C: the same two questions at uid 1001'
echo '[envx] C-BEGIN'
enter debian { /usr/bin/env }
echo '[envx] C-END'
echo '[envx] D-BEGIN'
/bin/hamsh /etc/envprobe.rc
echo '[envx] D-END'
echo '[envx] DONE'
RC

echo "[envx] staging an image with that rc"
HAMLINUX_RC="$WORK/rc.boot" scripts/hamlinux_image.sh >"$WORK/build.log" 2>&1 || {
    echo "FAIL image build"; tail -20 "$WORK/build.log"; exit 1; }
( cd "$SEG" && find etc -print0 | cpio --null -o -H newc --quiet ) | gzip \
    >> "$IMG/initramfs.cpio.gz"
echo "[envx] planted /etc/envprobe.rc as a second cpio segment"

echo "[envx] booting (up to ${WAIT}s)"
( sleep "$((WAIT + 10))" ) | timeout "$((WAIT + 5))" \
    scripts/hamlinux_vm.sh script --timeout "$WAIT" >"$WORK/boot.log" 2>&1

echo
grep -aE '^\[envx\]|envx-sentinel|envx-crossed' "$WORK/boot.log" | head -60
echo

arm() { sed -n "/\[envx\] $1-BEGIN/,/\[envx\] $1-END/p" "$WORK/boot.log" | tr -d '\r'; }
fail=0
say() { echo "envx: $*"; }
yes_no() {   # $1 label, $2 arm, $3 pattern
    if arm "$2" | grep -q "$3"; then say "PASS $1"; return 0
    else say "FAIL $1   (no /$3/ in arm $2)"; fail=1; return 1; fi
}

grep -aq '\[envx\] DONE' "$WORK/boot.log" \
    || { say "FAIL the boot did not reach DONE"; tail -30 "$WORK/boot.log"; exit 1; }
say "PASS the boot reached DONE"

# --- A: does `enter` carry the environment? -------------------------------
# The sentinel is the answer. `enter debian { /usr/bin/env }` runs Debian's own
# env(1) inside the namespace and prints everything that arrived.
yes_no "enter carries an exported variable (root)"        A 'HAMNIX_ENVPROBE=envx-crossed'
yes_no "enter carries WAYLAND_DISPLAY (root)"             A 'WAYLAND_DISPLAY=envx-sentinel-wl'
yes_no "enter carries XDG_RUNTIME_DIR (root)"             A 'XDG_RUNTIME_DIR=/envx-sentinel-run'
yes_no "enter carries HOME (root)"                        A 'HOME=/envx-sentinel-home'

# --- C: the same, at the uid the DE launcher runs at ----------------------
yes_no "enter carries an exported variable (uid 1001)"    C 'HAMNIX_ENVPROBE=envx-crossed'
yes_no "enter carries WAYLAND_DISPLAY (uid 1001)"         C 'WAYLAND_DISPLAY=envx-sentinel-wl'

# --- B/D: the OTHER boundary, which is the one that actually drops it -----
# A fresh hamsh seeds its env mirror with PATH and HOME and nothing else
# (user/hamsh.ad, main(): `env_set("PATH", ...)` / `env_set("HOME", "/")`); it
# never reads the inherited environ. So a variable exported by an ancestor is
# dropped at the exec into a new hamsh -- one level ABOVE the `enter`. This is
# a MEASUREMENT of that, not a demand that it stay so: if a later pass makes
# hamsh seed from environ, these two flip and the file should be re-read, not
# silently re-baselined.
if arm B | grep -q 'B1 new-hamsh sees HAMNIX_ENVPROBE= *envx-crossed'; then
    say "NOTE a fresh hamsh DOES inherit the exported variable (behaviour changed)"
else
    say "PASS a fresh hamsh does NOT inherit it -- the drop is the exec, not the enter"
fi
if arm B | grep -q 'HAMNIX_ENVPROBE=envx-crossed'; then
    say "NOTE the sentinel survived exec+enter (behaviour changed)"
else
    say "PASS the sentinel is gone by the time the new hamsh enters -- it never"
    say "     reached that hamsh at all, so enter had nothing to carry"
fi

echo "(full log: $WORK/boot.log)"
exit $fail
