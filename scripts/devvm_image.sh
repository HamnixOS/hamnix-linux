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
# `svc start sshd`, THE SHIPPED PATH. This script used to spell it
# `/bin/sshd &` and the comment below explained why. That reason is now GONE:
# sshd binds port 22 while privileged and drops to uid 2 itself before it
# accepts anything, so the supervisor no longer has to choose between a
# service that can listen and a service that is not root. What follows is
# kept because it is the measurement that made the case:
#
#   [sshd] Hamnix SSH-2.0 server starting
#   [sshd] WARN: could not persist host key (volatile this boot)
#   [sshd] host key ready (ecdsa-sha2-nistp256)
#   [sshd] net_announce() failed
#
# It was fixed in user/sshd.ad rather than by raising the uid, because
# lowering sshd's privilege was a deliberate decision (docs/security.md
# Phase 11) and the standard answer to a privileged port is to bind while
# privileged and drop before serving. The guest now logs
# `[sshd] listening on port 22` followed by
# `[sshd] dropped privilege to uid 2 before serving`.
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
    "# sshd through the SUPERVISOR, which is the shipped path, and it now\n"
    "# works. It did not before: /etc/svc/sshd.hamsh said `uid: 2`, the\n"
    "# supervisor drops uid BEFORE exec, port 22 is privileged, and sshd\n"
    "# respawned on a backoff for ever without ever listening. sshd now binds\n"
    "# while privileged and drops to uid 2 itself before serving, so the\n"
    "# service definition no longer needs a uid line at all -- see the long\n"
    "# note in /etc/svc/sshd.hamsh. Going through `svc` rather than around it\n"
    "# also buys the dev VM restart-on-failure: user/sshd.ad's main() serves a\n"
    "# bounded number of connections and exits, and with `/bin/sshd &` nothing\n"
    "# brought it back, so a long-lived dev VM used to stop accepting SSH.\n"
    "# /var/lib/ssh needs no mkdir here either: hamlinux_image.sh stages it and\n"
    "# sshd creates it as well.\n"
    "svc start sshd\n"
    "echo 'rc.boot: devvm started sshd'\n"
)
assert text.count(old) == 1, "expected exactly one rc.5 source line, found %d" % text.count(old)
open(dst, "w").write(text.replace(old, new))
print("devvm_image: derived %s from %s" % (dst, src))
PY

HAMLINUX_RC="$RC" bash scripts/hamlinux_image.sh "$OUT"

echo "devvm_image: staged $OUT"
