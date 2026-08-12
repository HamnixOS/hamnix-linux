#!/usr/bin/env bash
# tests/linux/gates_are_private.sh — A NEW GATE MUST NOT BE ABLE TO WRITE THIS
# MACHINE BY ACCIDENT.
#
# THE GAP THIS CLOSES
# ===================
# tests/linux/private_ns.sh exists because a gate wrote /tmp/hamnix-panel.conf
# — the desktop's live runtime override — and cost two other agents their
# conclusions while scoring 17 PASS. The gates that were doing it have been
# converted. That fixes the past. It does nothing about the next gate somebody
# writes, which will start `wsysd` and `hampanelscene` the way every existing
# one does, will look exactly like its neighbours, and will be green.
#
# The names are not in the scripts — they are compiled into the programs (see
# the table in private_ns.sh), so "remember not to write /tmp" is advice that
# cannot be followed. The only thing that can be checked is whether the gate
# put itself in a namespace.
#
# So this is the same REFUSAL shape the tree already uses for the packaging
# rule in tests/linux/channel_covers_image.sh: a host-side gate that starts the
# window system either isolates itself, or is named in EXEMPT below WITH A
# REASON. An unlisted one fails. It is not a checklist item and not a lint
# suggestion; it is the thing that says no.
#
# It also fails on a STALE exemption — a file that no longer exists, or one
# that is listed here and has since been converted. A list of excuses nobody
# prunes stops being a record of what is unfinished and becomes a place
# unfinished things go to be forgotten, and then the gate is green for a
# reason that is not true.
#
# Costs nothing: it compiles and runs nothing, and takes about a second.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

pass=0; fail=0
ok()   { echo "private: PASS $*"; pass=$((pass+1)); }
bad()  { echo "private: FAIL $*"; fail=$((fail+1)); }
info() { echo "private: INFO $*"; }

# ---- THE EXEMPTIONS, EACH WITH THE REASON IT IS ONE -----------------------
# <file><TAB><reason>. A reason is required and is read by a person, so write
# one. "not yet" is a legitimate reason; pretending is not.
EXEMPT="$(cat <<'EOF'
wsys_uidgate.sh	ITS SUBJECT IS THE UID. The namespace is only obtainable with --map-root-user (--map-current-user leaves CapEff 0, measured), so geteuid() would be 0 inside, and user/linux-wsys.c branches on exactly that at :1207 and :1843. It would still print its passes, about the wrong uid. Run it alone or in the VM. The file says so at its head.
private_ns_isolates.sh	IT IS THE PROOF. It builds its own OUTER namespace for each of its two experiments -- one of which deliberately reproduces the contamination -- and its last assertion has to see the REAL host to answer whether anything leaked onto it. Re-execing itself would nest that assertion inside the very thing it is checking.
channel_runs_desktop.sh	NOT YET CONVERTED, and the most valuable one left: scripts/hamlinux_packages.py runs it before it writes index.json, so it runs on every publish, and it sets no HAMWSYS at all -- it takes linux-wsys.c's /srv, then /dev/shm/hamnix-wsys fallback, which this machine's /dev/shm is holding right now. Two lines plus one verification run.
runsweep_jail.sh	NOT YET CONVERTED. Runs the panel, the desktop and wsyswl. Needs a verification run.
wsyswl_rootless.sh	NOT YET CONVERTED. Sets HAMWSYS, so the shared segment is private, but it starts hamdesktop and hampanelscene and those write /tmp/hamdesktop-wp.status, /tmp/.hamdesktop.src, /tmp/hamnix-panel.health and /tmp/hamnix-panel-drop under fixed names.
wlsnarf_bridge.sh	NOT YET CONVERTED, and it has a second exposure the namespace would also close: `mkdir -p /tmp/.X11-unix` and a bind of X$DPY inside it. That is the host's X socket directory, and a display-number collision reaches a real X session on this machine.
input_probe.sh	NOT YET CONVERTED. Sets HAMWSYS and HAMWSYS_BB and starts no desktop client, so the known residue is small; unverified rather than proved.
wsys_bypass.sh	NOT YET CONVERTED. Sets HAMWSYS; no desktop client. Same standing as input_probe.sh.
wsys_title.sh	NOT YET CONVERTED. Sets HAMWSYS and HAMWSYS_BB; no desktop client.
wsys_image.sh	NOT YET CONVERTED. Sets HAMWSYS and HAMWSYS_BB; no desktop client.
wsys_close_button.sh	NOT YET CONVERTED. Sets HAMWSYS and HAMWSYS_BB; runs wsyswl, whose Wayland socket lands in XDG_RUNTIME_DIR -- which private_ns.sh does NOT shadow, so converting it is necessary but not sufficient.
x11_geom_probe.sh	NOT YET CONVERTED. Same standing as wsys_close_button.sh.
wsyswl_ceiling.sh	NOT YET CONVERTED. Same standing as wsys_close_button.sh.
wsyswl_conn_ceiling.sh	NOT YET CONVERTED. Same standing as wsys_close_button.sh.
wsyswl_shared_fate.sh	NOT YET CONVERTED. Same standing as wsys_close_button.sh.
wsyswl_stall.sh	NOT YET CONVERTED. Same standing as wsys_close_button.sh.
wsyswl_two_browsers.sh	NOT YET CONVERTED. Same standing as wsys_close_button.sh.
wsyswl_wheel.sh	NOT YET CONVERTED. Same standing as wsys_close_button.sh.
EOF
)"
exempt_reason() { printf '%s\n' "$EXEMPT" | awk -F'\t' -v f="$1" '$1 == f { print $2; exit }'; }

# ---- WHICH GATES THIS IS ABOUT -------------------------------------------
# A gate is in scope when it BUILDS OR RUNS host binaries (so it is not a VM
# gate, whose writes land inside the guest) and starts the window system or a
# client of it. Deliberately generous: a false positive costs one line in the
# table above with a reason, and a false negative is the whole bug.
in_scope() {
    grep -qE 'qemu-system|hamlinux_vm|HAMLINUX_IMAGE|hamlinux_shot' "$1" && return 1
    grep -qE 'hamlinux_build\.sh|PANELCONF_BIN_DIR|\$BIN/' "$1" || return 1
    grep -qE 'wsysd|hampanelscene|hamdesktop|wsyswl' "$1" || return 1
    return 0
}
isolated() { grep -q 'priv_ns_reexec' "$1"; }

SCOPE=(); ISO=(); EX=(); NAKED=()
for f in tests/linux/*.sh; do
    b="$(basename "$f")"
    in_scope "$f" || continue
    SCOPE+=("$b")
    if isolated "$f";                      then ISO+=("$b")
    elif [ -n "$(exempt_reason "$b")" ];   then EX+=("$b")
    else                                        NAKED+=("$b"); fi
done

info "${#SCOPE[@]} host-side gates start the window system: ${#ISO[@]} isolated, ${#EX[@]} exempt by name, ${#NAKED[@]} neither"

# ---- 1. THE REFUSAL ------------------------------------------------------
if [ "${#NAKED[@]}" = 0 ]; then
    ok "every host-side gate that starts the window system either re-execs itself into a private namespace or is named in this file with a reason"
else
    for b in "${NAKED[@]}"; do
        bad "tests/linux/$b starts the window system on this host and does NOT isolate itself. It will write /tmp/hamnix-*, /dev/shm/hamnix-* or /srv/* under names a concurrent run and this machine's own desktop READ -- see tests/linux/private_ns.sh. Add, right after cd \"\$PROJ_ROOT\":
private:            . tests/linux/private_ns.sh
private:            priv_ns_reexec \"\$@\"
private:      and re-run it to confirm it still scores what it scored. If it genuinely must not be isolated, name it in EXEMPT in this file with the reason."
    done
fi

# ---- 2. AND THE EXEMPTIONS ARE STILL TRUE --------------------------------
stale=0
while IFS=$'\t' read -r name reason; do
    [ -n "$name" ] || continue
    if [ ! -f "tests/linux/$name" ]; then
        bad "EXEMPT names tests/linux/$name, which does not exist -- an excuse outliving its gate"
        stale=1
    elif isolated "tests/linux/$name"; then
        bad "EXEMPT still names tests/linux/$name, which now isolates itself -- delete the line, or the list stops being a record of what is unfinished"
        stale=1
    elif [ -z "$reason" ]; then
        bad "EXEMPT names tests/linux/$name with no reason"
        stale=1
    fi
done <<<"$EXEMPT"
[ "$stale" = 0 ] && ok "every exemption still names a real gate that is still unisolated, and still gives a reason"

# ---- 3. THE HELPER IS WHERE THE GATES SAY IT IS --------------------------
if [ -r tests/linux/private_ns.sh ] && grep -q 'priv_ns_reexec()' tests/linux/private_ns.sh; then
    ok "tests/linux/private_ns.sh is present and defines priv_ns_reexec"
else
    bad "tests/linux/private_ns.sh is missing or no longer defines priv_ns_reexec -- every gate above sources it"
fi

# What is still outstanding, said out loud on every run, so that the green
# above is never mistaken for "all of them are private".
n_todo="$(printf '%s\n' "$EXEMPT" | grep -c 'NOT YET CONVERTED' || true)"
[ "$n_todo" = 0 ] || info "$n_todo of the ${#SCOPE[@]} are exempt only because nobody has converted and re-run them yet -- this gate is green with that debt named, not paid"

echo "private: $pass passed, $fail failed"
[ "$fail" = 0 ]
