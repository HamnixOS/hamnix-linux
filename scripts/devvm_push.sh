#!/usr/bin/env bash
# scripts/devvm_push.sh — rebuild ONE Adder program and put it into the
# already-running dev VM, without rebooting it.
#
#   scripts/devvm_push.sh user/cat.ad            # build + install as /bin/cat
#   scripts/devvm_push.sh user/sshd.ad --restart sshd
#
# THE TRANSPORT IS HTTP FROM THE SLIRP GATEWAY, 10.0.2.2, and that choice is
# measured rather than aesthetic. The Plan-9-shaped answer would be a virtio-9p
# host share, and the brief for this work said 9P "works end to end" citing
# scripts/test_virtio9p.sh and drivers/virtio/virtio_9p.ad. IT DOES NOT WORK
# HERE AND THE DRIVER DOES NOT EXIST: there is no drivers/ directory in this
# repository at all, `git ls-files` lists none, and test_virtio9p.sh compiles
# init/main.ad, which is also absent. Both are leftovers of the removed
# bare-metal lane. scripts/hamlinux_image.sh contains no 9p of any kind, so a
# hamnix-linux guest has no 9P client to mount a share with.
# HTTP from 10.0.2.2, by contrast, is what the tree already uses for kernels
# and signed package refreshes, and the guest ships `wget`.
#
# WHAT THIS CANNOT DO. It replaces a FILE. It does not restart anything unless
# --restart names a service, and it cannot help at all with a change to
# something that only runs during boot: /etc/rc.boot* and everything it
# sources, linuxinit (PID 1 itself), the installer, the greeter's place in the
# runlevel, or a kernel/initramfs change. Those need a cold boot -- rebuild
# with scripts/devvm_image.sh and cycle devvm_down.sh / devvm_up.sh.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

DEVVM_DIR="${DEVVM_DIR:-$HOME/.hamnix-build/devvm}"
[ -f "$DEVVM_DIR/ports" ] || { echo "devvm_push: no running dev VM ($DEVVM_DIR/ports missing)" >&2; exit 1; }
# shellcheck disable=SC1090
. "$DEVVM_DIR/ports"

SRC="${1:?usage: devvm_push.sh <user/prog.ad> [--restart <svc>] [--as /bin/name]}"
shift || true
RESTART=""
DEST=""
while [ $# -gt 0 ]; do
    case "$1" in
        --restart) RESTART="$2"; shift 2 ;;
        --as)      DEST="$2";    shift 2 ;;
        *) echo "devvm_push: unknown argument $1" >&2; exit 2 ;;
    esac
done

NAME="$(basename "$SRC" .ad)"
DEST="${DEST:-/bin/$NAME}"

# --- build just this program ---------------------------------------------
echo "devvm_push: building $SRC"
BUILD_LOG="$DEVVM_DIR/push-build.log"
BIN="$DEVVM_DIR/push/$NAME"
# Build STRAIGHT INTO the served directory, and delete any previous copy
# first. hamlinux_build.sh takes an explicit output path, so there is no
# guessing where the ELF landed -- and if the build fails, the old binary is
# already gone rather than sitting there ready to be served as if it were the
# new one. A push that quietly served a STALE binary would be indistinguishable
# from a code change that had no effect, which is the worst failure this loop
# could have.
rm -f "$BIN"
if ! bash scripts/hamlinux_build.sh "$SRC" "$BIN" > "$BUILD_LOG" 2>&1; then
    echo "devvm_push: BUILD FAILED (exit $?) — $BUILD_LOG" >&2
    tail -30 "$BUILD_LOG" >&2
    exit 1
fi
[ -f "$BIN" ] || { echo "devvm_push: build reported success but produced no $BIN" >&2; exit 1; }

# Stamp the served copy so the guest can PROVE it got this build and not a
# cached or previous one. Content hash, not mtime: mtime survives a rebuild
# that produced identical bytes and would make a no-op look like a success.
SUM=$(sha256sum "$BIN" | cut -c1-16)
echo "devvm_push: serving $NAME ($(stat -c%s "$BIN") bytes, sha256:$SUM)"

# --- pull it into the guest ----------------------------------------------
# Fetch to a temp path and move into place: overwriting a running binary's
# path directly is how you get a half-written file executed.
#
# THE MODE, WHICH THIS SCRIPT USED TO GET WRONG IN BOTH DIRECTIONS.
#
# The note that stood here said there is no `chmod` on the image, and
# consoled itself that "the push happened to work anyway (mv preserves the
# mode wget wrote)". Both halves were wrong, and the second one is the
# expensive one. user/wget.ad writes its output through sys_open_write,
# which is open(O_WRONLY|O_CREAT|O_TRUNC, 0666) -- so under the default
# umask the fetched file lands 0644, WITH NO EXECUTE BIT AT ALL. What
# rescued the earlier pushes was not wget's mode, it was mv: user/mv.ad
# opens an EXISTING destination and truncates it, which leaves that
# destination's own 0755 alone. So a push over a binary already on the
# image worked, and everything else silently did not.
#
# MEASURED, 2026-08-20: `devvm_push.sh user/sshd.ad` while sshd was
# RUNNING. sys_open_write's ETXTBSY fallback unlinks the busy file and
# creates a new one -- with the mode argument, 0644 -- so /bin/sshd came
# out non-executable and the guest answered
#
#   exec: `/bin/sshd' exists (mode 0644) but execve(2) answered EACCES
#
# while this script had already printed "done -- /bin/sshd is the build
# just made". That is the failure shape this tree keeps getting burned by:
# success-shaped, and pointing at the wrong thing.
#
# So there IS a chmod now (user/chmod.ad, staged by hamlinux_image.sh), the
# push uses it, and the MODE IS ASSERTED rather than assumed -- `ls -l` of
# the destination is echoed back and checked below, because a chmod that
# silently did nothing would look exactly like one that worked.
CMD="wget -O /tmp/$NAME.new http://10.0.2.2:${DEVVM_HTTP_PORT}/$NAME && mv /tmp/$NAME.new $DEST && chmod 755 $DEST && echo PUSH_OK && ls -l $DEST && cksum $DEST"
OUT=$(python3 scripts/devvm_console.py run "$DEVVM_DIR" "$CMD" 60)
RC=$?
printf '%s\n' "$OUT"
if [ $RC -ne 0 ]; then
    echo "devvm_push: the guest shell did not run the fetch (see above)" >&2
    exit 1
fi
case "$OUT" in
    *PUSH_OK*) ;;
    *) echo "devvm_push: FAILED — the guest ran the fetch but PUSH_OK never" >&2
       echo "devvm_push: printed, so $DEST is NOT the binary just built." >&2
       exit 1 ;;
esac
# AND IT MUST BE EXECUTABLE. PUSH_OK only says the chain reached the echo;
# it does not say chmod changed anything. A pushed program that cannot be
# run is the exact failure this assertion was added for -- see the long
# note above the fetch.
case "$OUT" in
    *-rwx*) ;;
    *) echo "devvm_push: FAILED — $DEST is not executable in the guest." >&2
       echo "devvm_push: the fetch landed but the mode did not; the guest" >&2
       echo "devvm_push: will answer EACCES if anything tries to run it." >&2
       exit 1 ;;
esac

if [ -n "$RESTART" ]; then
    echo "devvm_push: restarting service $RESTART"
    python3 scripts/devvm_console.py run "$DEVVM_DIR" \
        "svc stop $RESTART; svc start $RESTART; echo RESTARTED_$RESTART" 60 || {
            echo "devvm_push: restart did not complete" >&2; exit 1; }
fi
echo "devvm_push: done — $DEST is the build just made"
