#!/usr/bin/env bash
# scripts/devvm_image.sh — stage the image the persistent dev VM boots.
#
# It is the ordinary hamnix-linux image with exactly TWO changes to the boot
# rc, both of which exist to make the guest DRIVABLE FROM OUTSIDE:
#
#   1. THE GRAPHICAL RUNLEVEL IS NOT ENTERED. etc/rc.boot.linux ends by
#      sourcing /etc/rc.d/rc.5, and PID 1 is a shell, so PID 1 is still INSIDE
#      rc.5 for as long as the greeter runs -- it never falls through to the
#      interactive serial prompt the file promises. Measured: on a stock
#      image the guest ECHOES a line typed at ttyS0 and never executes it.
#      etc/rc.boot.linux's own comment above that line says "Comment this line
#      out for a text-only boot; nothing below the compositor depends on it",
#      and that is precisely what this does.
#      => the dev VM is TEXT-ONLY. It cannot be used to test the desktop; use
#         the normal gates for that. See docs/dev-loop.md.
#
#   2. sshd IS STARTED. Nothing in etc/rc.boot.* starts it on the Linux lane
#      -- deliberately, because a listening SSH server is not a default this
#      project imposes (scripts/hamlinux_packages.py says so at SVC_SSHD_CMDS).
#      A DEVELOPER VM ON A LOOPBACK-ONLY FORWARD IS THE EXCEPTION, and it is
#      opt-in by virtue of being a different image built by a different script.
#
# The rc is DERIVED from etc/rc.boot.linux by substitution rather than kept as
# a second copy, so it cannot drift out of sync with the real one. If the
# substitution stops matching, this script fails loudly rather than quietly
# staging an unmodified rc -- a dev VM that silently booted to the greeter
# again would look exactly like a hung guest.
#
# Usage: scripts/devvm_image.sh [outdir]      (default ~/.hamnix-build/devvm/image)
set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

OUT="${1:-$HOME/.hamnix-build/devvm/image}"
mkdir -p "$OUT"
RC="$OUT/rc.boot.devvm"

SRC=etc/rc.boot.linux
[ -f "$SRC" ] || { echo "devvm_image: no $SRC" >&2; exit 1; }

# --- 1. drop the graphical runlevel --------------------------------------
grep -q "^source '/etc/rc.d/rc.5'" "$SRC" || {
    echo "devvm_image: FAILED — $SRC no longer contains the rc.5 source line." >&2
    echo "devvm_image: the text-only substitution below is stale; fix it rather" >&2
    echo "devvm_image: than shipping a dev image that boots to the greeter." >&2
    exit 1; }

# --- 2. start sshd in its place ------------------------------------------
# `/bin/sshd &` AND NOT `svc start sshd`, WHICH IS MEASURED AND NOT A STYLE
# CHOICE. /etc/svc/sshd.hamsh sets `uid: 2`. Port 22 is privileged, so from
# uid 2 net_announce() fails and sshd never listens; the supervisor's
# restart-on-failure policy then respawns it on a backoff and the console
# fills with the same four lines forever:
#
#   [sshd] Hamnix SSH-2.0 server starting
#   [sshd] WARN: could not persist host key (volatile this boot)
#   [sshd] host key ready (ecdsa-sha2-nistp256)
#   [sshd] net_announce() failed
#
# Started from this rc it inherits PID 1's uid 0, announces, and logs
# `[sshd] listening on port 22`. (The same uid: 2 is why it could not write
# its host key.) That is a real defect in the shipped service definition and
# it is written up in docs/dev-loop.md rather than fixed here, because
# lowering sshd's privilege was a deliberate decision in docs/security.md
# Phase 11 and the fix is a product decision, not a dev-loop one.
#
# COST OF NOT USING THE SUPERVISOR: user/sshd.ad's main() serves a BOUNDED
# number of connections and then exits, so a long-lived dev VM will
# eventually stop accepting SSH. Restart it from the console when it does.
python3 - "$SRC" "$RC" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
old = "source '/etc/rc.d/rc.5'"
new = (
    "# --- devvm: the graphical runlevel is DELIBERATELY NOT ENTERED -------\n"
    "# See scripts/devvm_image.sh. Sourcing rc.5 here keeps PID 1 (a shell)\n"
    "# inside the greeter forever, so the serial console never becomes an\n"
    "# interactive prompt and the guest cannot be driven from outside.\n"
    "# source '/etc/rc.d/rc.5'\n"
    "\n"
    "echo 'rc.boot: devvm text-only boot -- no graphical runlevel'\n"
    "\n"
    "# sshd keeps BOTH its persisted host key and authorized_keys under\n"
    "# /var/lib/ssh, and it does NOT create that directory itself (there is no\n"
    "# mkdir anywhere in user/sshd.ad -- checked). hamlinux_image.sh stages\n"
    "# /var/lib/hpm but not /var/lib/ssh, so without this line the first start\n"
    "# generates a host key it cannot write. /var/lib exists already.\n"
    "mkdir /var/lib/ssh\n"
    "/bin/sshd &\n"
    "echo 'rc.boot: devvm started sshd'\n"
)
assert text.count(old) == 1, "expected exactly one rc.5 source line, found %d" % text.count(old)
open(dst, "w").write(text.replace(old, new))
print("devvm_image: derived %s from %s" % (dst, src))
PY

HAMLINUX_RC="$RC" bash scripts/hamlinux_image.sh "$OUT"

echo "devvm_image: staged $OUT"
