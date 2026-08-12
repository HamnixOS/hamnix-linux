# tests/linux/private_ns.sh -- A GATE MUST NOT WRITE THE MACHINE IT RUNS ON.
#
# THE GAP THIS CLOSES
# ===================
# tests/linux/de_panel_conf_replace.sh proved a real defect, scored 17 PASS,
# and was green from the first run to the last. It also wrote
#
#     /tmp/hamnix-panel.conf
#
# which is NOT a scratch path. `user/hampanelscene.ad`'s `_open_config` reads
# it in PREFERENCE to the shipped /etc/panel.conf, and `user/hamsettings.ad`
# writes it: it is the desktop's live runtime configuration override, one
# fixed name shared by every process on the machine.
#
# The cost was measured, not imagined. While that gate ran, ANOTHER agent's
# independent offscreen run of the published desktop binaries watched its
# panel log `config reload applied: 2 panel(s)` and then `1 panel(s)`, saw its
# top bar go missing, and concluded it had reproduced a defect. It had almost
# certainly observed THIS GATE's assertion 11 ("a config that drops to ONE
# panel must withdraw the surplus window") landing in the middle of its run.
# That false reproduction was then relayed to a third agent as a finding.
# One gate's scratch file cost two agents' conclusions.
#
# NORTH_STAR.md: *a gap must never answer something success-shaped instead of
# the truth.* A gate that passes while corrupting the machine around it is
# exactly that shape -- it was green throughout, and the thing it broke was
# somebody else's answer.
#
# WHY A SHARED HELPER AND NOT A CAREFUL PATCH
# ===========================================
# Because the fixed names are NOT mostly in the test scripts. They are
# compiled into the programs under test, and no amount of care in a gate can
# move them:
#
#     hampanelscene  /tmp/hamnix-panel.conf  /tmp/hamnix-panel.health
#                    /tmp/hamnix-panel.fault /tmp/hamnix-panel-drop
#                    /tmp/hamnix-notif.log
#     hamdesktop     /tmp/hamdesktop-wp.status /tmp/.hamdesktop.src
#                    /tmp/hamnix-panel-drop
#     hamctl         /tmp/hamnix-wallpaper.{ppm,conf} /tmp/hamnix-tz.conf
#                    /tmp/hamnix-{display,mouse,kbd,sound,net}.conf
#     hamsettings    /tmp/hamnix-wallpaper.ppm /tmp/hamnix-panel.conf
#     linux-wsys.c   /srv/wsys /dev/shm/hamnix-wsys /tmp/hamnix-wsys (and -bb)
#     linux-snarf.c  /srv/snarf /dev/shm/hamnix-snarf
#     linux-audio.c  /srv/audio /dev/shm/hamnix-audio
#     linux-net.c    /srv/net   /dev/shm/hamnix-net
#     linux-fdns.c   /srv/fdns  /dev/shm/hamnix-fdns
#
# So ANY gate that starts the desktop stack writes host-global state whether
# its author intended to or not, and the ones that do not export HAMWSYS /
# HAMWSYS_BB fall through to /dev/shm/hamnix-wsys, which a concurrent gate
# will then attach to. The containment has to be at the namespace, not at the
# path.
#
# WHAT IT DOES
# ============
# Re-executes the calling gate inside a private mount namespace (via a user
# namespace, so no privilege is needed and none is gained) in which
#
#     /tmp   /dev/shm   /srv
#
# are each a FRESH, EMPTY tmpfs belonging to this run alone. Every fixed name
# above lands in it. Nothing the gate or its children write is visible to any
# other process on the machine, and everything vanishes with the namespace --
# including on SIGKILL, which no trap can survive.
#
# The mounts are made after `mount --make-rprivate /`, so nothing propagates
# back to the host's mount table even where a shared subtree would otherwise
# carry it.
#
# USE
# ===
#     . tests/linux/private_ns.sh
#     priv_ns_reexec "$@"          # FIRST -- before reap.sh, before $WORK
#
# It returns only once the namespace is in place; the first call never
# returns, it execs. Put it above `. tests/linux/reap.sh`: reap.sh's registry
# defaults to a mktemp under /tmp, and a registry created before the tmpfs
# goes on top of /tmp is a registry the gate can no longer see.
#
# $WORK may then live under /tmp as usual -- it is private now, and it is
# still the 16 GB RAM-backed tmpfs. For a KEEP=1 post-mortem the namespace's
# /tmp is gone when the gate ends, so use priv_ns_keep to copy artefacts to a
# host-visible directory outside the shadowed paths.
#
# THE ONE FIDELITY COST, STATED
# =============================
# `unshare --map-current-user` leaves the process with CapEff 0 -- measured --
# so the mounts are impossible without `--map-root-user`, and inside the
# namespace geteuid() is 0. Outside it is still the invoking user: no file the
# invoker could not already write becomes writable. A gate whose SUBJECT is
# uid behaviour (tests/linux/wsys_uidgate.sh) must therefore not use this
# helper for the assertion it makes about uids -- linux-wsys.c:1207 and :1843
# both branch on geteuid(). Every other gate is unaffected, and that is a
# claim each converted gate re-checks by still scoring what it scored before.
#
# ESCAPE HATCH
# ============
# HAMTEST_NO_PRIVNS=1 skips the namespace and says so, loudly, on stderr. It
# exists so that a kernel without unstrusted user namespaces can still run the
# gate deliberately. It is not a default and it is not silent: without it, a
# host that cannot provide the namespace makes the gate REFUSE BY NAME rather
# than fall back to writing the machine. A default is never a substitute for
# an answer.

PRIV_NS_ACTIVE="${PRIV_NS_ACTIVE:-0}"

# The tmpfs mounts, as a here-doc'd python program: mount(8) refuses to run
# for a non-root euid even when the caller holds CAP_SYS_ADMIN, and mount(2)
# does not. Doing it through libc keeps the failure legible (it names the
# mount point and the errno) instead of "must be superuser".
priv_ns_mount_prog() {
    cat <<'PRIVNSPY'
import ctypes, os, sys
libc = ctypes.CDLL("libc.so.6", use_errno=True)
def mount(src, tgt, fs, flags, data):
    r = libc.mount(src.encode() if src else None, tgt.encode(),
                   fs.encode() if fs else None, ctypes.c_ulong(flags),
                   data.encode() if data else None)
    if r != 0:
        e = ctypes.get_errno()
        sys.stderr.write("private_ns: cannot mount %s: %s\n" % (tgt, os.strerror(e)))
        raise SystemExit(1)
MS_REC, MS_PRIVATE = 16384, 1 << 18
# Detach this namespace's propagation first, or a shared subtree carries the
# mounts below straight back out to the host we are trying not to touch.
mount(None, "/", None, MS_REC | MS_PRIVATE, None)
for target in sys.argv[1:]:
    if not os.path.isdir(target):
        continue
    mount("none", target, "tmpfs", 0, "mode=1777")
PRIVNSPY
}

# priv_ns_reexec [args...] -- put the calling gate inside the namespace.
#
# Call it with the gate's own "$@" so the arguments survive the exec.
priv_ns_reexec() {
    if [ "$PRIV_NS_ACTIVE" = 1 ]; then
        priv_ns_assert || exit 1
        return 0
    fi
    if [ "${HAMTEST_NO_PRIVNS:-0}" = 1 ]; then
        echo "private_ns: WARNING -- HAMTEST_NO_PRIVNS=1: this run writes the" >&2
        echo "private_ns: WARNING    HOST's /tmp, /dev/shm and /srv. Any other" >&2
        echo "private_ns: WARNING    desktop process on this machine, and any" >&2
        echo "private_ns: WARNING    concurrent gate, can see and be corrupted" >&2
        echo "private_ns: WARNING    by what it writes. Its result is not" >&2
        echo "private_ns: WARNING    evidence about anything but this run." >&2
        return 0
    fi

    local self="${BASH_SOURCE[1]:-$0}"
    [ -r "$self" ] || {
        echo "private_ns: REFUSING -- cannot find the calling script to re-exec ('$self')" >&2
        exit 1; }

    command -v unshare >/dev/null 2>&1 || {
        echo "private_ns: REFUSING to run $self -- no unshare(1) on this host, so its" >&2
        echo "private_ns: writes to /tmp/hamnix-*, /dev/shm and /srv would be the" >&2
        echo "private_ns: machine's. Install util-linux, or set HAMTEST_NO_PRIVNS=1 to" >&2
        echo "private_ns: say out loud that you accept that." >&2
        exit 1; }
    unshare --user --map-root-user --mount true 2>/dev/null || {
        echo "private_ns: REFUSING to run $self -- this kernel will not give an" >&2
        echo "private_ns: unprivileged user namespace with a private mount table" >&2
        echo "private_ns: (try: sysctl kernel.unprivileged_userns_clone=1). Without it" >&2
        echo "private_ns: this gate writes /tmp/hamnix-panel.conf and friends, which" >&2
        echo "private_ns: the running desktop READS. Set HAMTEST_NO_PRIVNS=1 to accept" >&2
        echo "private_ns: that deliberately." >&2
        exit 1; }

    local prog; prog="$(priv_ns_mount_prog)"
    exec unshare --user --map-root-user --mount -- \
        /usr/bin/env PRIV_NS_ACTIVE=1 \
        bash -c '
            python3 -c "$1" /tmp /dev/shm /srv || exit 1
            shift 2
            exec bash "$@"
        ' private_ns "$prog" -- "$self" "$@"
}

# priv_ns_assert -- is the isolation actually in place RIGHT NOW?
#
# Not "did we ask for it". The whole lesson is that asking is not the same as
# getting: this reads /proc/self/mountinfo for a tmpfs mounted on each path in
# THIS mount namespace, and then checks that /tmp really is the fresh one --
# a host /tmp on this machine has hundreds of entries, so an empty listing is
# a second, independent witness that what we are looking at is ours.
priv_ns_assert() {
    local p bad=0
    for p in /tmp /dev/shm /srv; do
        [ -d "$p" ] || continue
        awk -v want="$p" '$5 == want { seen = 1 } END { exit !seen }' \
            /proc/self/mountinfo || {
            echo "private_ns: REFUSING -- $p is not a mount point in this namespace" >&2
            bad=1; }
    done
    [ "$bad" = 0 ] || return 1
    if [ -n "$(ls -A /tmp 2>/dev/null)" ]; then
        echo "private_ns: REFUSING -- /tmp is a mount point but is not empty, so it is" >&2
        echo "private_ns: not the private tmpfs this run just made" >&2
        return 1
    fi
    return 0
}

# priv_ns_describe -- one line a gate can print as its own evidence.
priv_ns_describe() {
    if [ "${HAMTEST_NO_PRIVNS:-0}" = 1 ]; then
        echo "NOT ISOLATED (HAMTEST_NO_PRIVNS=1): writing this machine's /tmp, /dev/shm and /srv"
        return 0
    fi
    local dev
    dev="$(awk '$5 == "/tmp" { d = $3 } END { print d }' /proc/self/mountinfo)"
    echo "isolated: /tmp, /dev/shm and /srv are private tmpfs of this run alone (/tmp is dev $dev in this mount namespace; the host's /tmp is untouched and unreadable from here)"
}

# priv_ns_keep <dir> -- a host-visible directory that OUTLIVES the namespace.
#
# The private /tmp dies with the run, which is the point, and which also means
# a KEEP=1 post-mortem has nothing to look at. This makes a directory outside
# every shadowed path and echoes it. Under $HOME/.hamnix-build by the tree's
# convention for private build artefacts.
priv_ns_keep() {
    local base="${HAMLINUX_SCRATCH:-$HOME/.hamnix-build}/testkeep"
    local dir="$base/${1:-run}.$$"
    mkdir -p "$dir" || return 1
    echo "$dir"
}
