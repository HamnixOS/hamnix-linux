#!/usr/bin/env bash
#
# REGISTRATION, 2026-08-17. Until this date scripts/test_gate_registration.sh
# globbed only scripts/test_*.sh, so this directory was invisible to the gate
# against unregistered gates and every file in it read as coverage without
# being coverage. This gate is ON-DEMAND: not in ci_battery_manifest.txt
# because nobody has measured its host runtime yet, and the battery is 12-way
# sharded under a 50-minute cap -- registering an unmeasured gate is how a
# shard goes from green to timed-out. Measure it, then move it into the
# manifest.
#
# Its host runtime and its pass/fail were NOT measured when this line was
# written. If you make it cheap enough for the battery, add the manifest line
# and delete this block.
#
# tests/linux/de_panel_conf_replace.sh — DOES THE PANEL SURVIVE HAVING ITS
# CONFIG FILE REPLACED UNDERNEATH IT?
#
# THE DEFECT THIS GATES
# =====================
# MEASURED on a real installed UEFI+ext4 machine running the published 1.0.17,
# desktop up: the instant `hpm update` finished, the top panel and the taskbar
# VANISHED. Both windows went `visible` 1 -> 0. A real click on the
# Applications button afterwards changed 234 pixels — the mouse cursor and
# nothing else. The panel PROCESS was still alive and still logging
# `[panel] config reload applied: 2 panel(s)`. That is the success shape
# NORTH_STAR.md names: a program that looks healthy to anything counting
# processes or grepping logs, and a desktop with no panel to the person
# sitting in front of it.
#
# THE CAUSE, established rather than guessed
# ------------------------------------------
# `user/hampanelscene.ad`'s `_set_window_hidden` spells BOTH directions of one
# verb: it writes `hide 1` to withdraw a pooled panel window and `hide 0` to
# put one back on screen. Its config-reload path `_reload_panels` writes
# `hide 0` to EVERY panel window it is about to redraw ("a pooled window
# reclaimed from an earlier, larger layout comes back hidden; put it on screen
# before we redraw into it").
#
# `user/linux-wsys.c`'s ctl parser did NOT read the argument:
#
#     if (n >= 4 && !strncmp(s, "hide", 4)) {
#         wr(WR_ATTR, n); v->visible = 0; shm->gen++; return;
#     }
#
# So `hide 0` — "show this window" — set visible = 0. Every reload of the
# panel config withdrew every panel window. `hpm update` rewrites
# /etc/panel.conf underneath the running panel, the panel reloaded, and the
# desktop lost its panel and its taskbar while the process stayed up.
#
# It is NOT about the version bump the same investigation was chasing (the
# shared segment is unchanged and 4 rows at the moment it happens), and it is
# NOT about hpm unlinking rather than rewriting: assertion 10 below performs
# the replacement IN PLACE, same inode, and it reproduces identically. Any
# change to the active config does it — a package, a shell, anything. It does
# NOT touch `hamdesktop`: the backdrop never writes `hide`, which is why the
# wallpaper survived and only the chrome disappeared (assertion 8).
#
# WHY EVERY EXISTING GATE STAYED GREEN
# ====================================
# The panel's OWN edits (Settings: move/add/remove a widget) never take this
# path: `_save_config` re-primes the live-reload baseline so the panel does
# not reload from its own write, and applies the edit directly instead. The
# reload path fires only for an EXTERNAL edit — which, on a running desktop,
# essentially only ever means a package replacing /etc/panel.conf. Nothing
# gated that until this file.
#
# WHAT IS MEASURED, AND WHAT IS DELIBERATELY NOT
# ==============================================
# Not measured: the panel process being alive, and not the `config reload
# applied` line on its own — those are exactly what stayed true through the
# defect. The reload line is used ONLY as a synchronisation point ("the panel
# has picked the edit up now"), never as an answer.
#
# Measured: the `visible` field of the window table (`/dev/wsys/<wid>/ctl`
# field 8), the PIXELS in the framebuffer where each bar is painted, and a
# real evdev click on the Applications button producing a menu — before the
# replacement and again after it.
#
# Every click is SYNTHETIC EVDEV (24-byte `struct input_event` records
# appended to HAMWSYSD_INPUT, read by wsysd's own pump_input), never a poke at
# an event ring. Assertion 13 enforces that mechanically, for the reason
# tests/linux/de_mouse_chrome.sh records at length.
#
# THE CONFIG FILE THIS USES, AND WHY THIS GATE RUNS IN ITS OWN NAMESPACE
# ======================================================================
# `_open_config` prefers the writable runtime override /tmp/hamnix-panel.conf
# and falls back to the shipped /etc/panel.conf; it returns ONE fd and every
# line after it — `_cfg_changed`, `_load_config`, `_reload_panels` — is shared.
# The host running this gate has no writable /etc/panel.conf, so the
# replacement is performed on the override path.
#
# That path is NOT scratch. It is the desktop's live configuration override,
# one fixed name shared by every process on the machine, and an earlier
# revision of this gate wrote the real one. It cost two other agents their
# conclusions — the incident is written up in tests/linux/private_ns.sh, which
# is the fix: this gate now re-execs itself inside a private mount namespace
# where /tmp, /dev/shm and /srv are fresh empty tmpfs belonging to this run
# alone. The replacement below is performed on a /tmp/hamnix-panel.conf that
# no other process on this machine can see, and that ceases to exist when the
# gate does. Nothing else about what is measured changes.
#
# Its CONTENT is `etc/panel.conf` ITSELF, copied byte for byte, comment
# header and all. That only became possible when the streaming reader landed
# -- until then the header alone overran `_load_config`'s 2047-byte read and
# a verbatim copy of the shipped file was never parsed at all.
#
# Entirely offscreen (HAMFB_FILE + a file of evdev records): no VM, no display,
# no GPU, about half a minute. The software Vulkan ICD is forced because wsysd
# has a real Vulkan backend and this host's GPU belongs to someone.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

# FIRST, before anything creates a file. Everything below this line runs in a
# mount namespace whose /tmp, /dev/shm and /srv are this run's alone; the call
# above it execs and does not return. reap.sh must be sourced AFTER it: its
# registry defaults to a mktemp under /tmp, and a registry made before the
# tmpfs lands on /tmp is a registry the gate can no longer see.
. tests/linux/private_ns.sh
priv_ns_reexec "$@"
. tests/linux/reap.sh

WORK="${PANELCONF_WORK:-$(mktemp -d -p "${TMPDIR:-/tmp}" panelconf.XXXXXX)}"
mkdir -p "$WORK"
KEEP="${PANELCONF_KEEP:-0}"
GEOM="${HAMFB_GEOM:-1280x800}"
FBW="${GEOM%x*}"; FBH="${GEOM#*x}"

export HAMWSYS="$WORK/wsys.shm"
export HAMWSYS_BB="$WORK/wsys.bb"
export HAMWSYS_IMG="$WORK/wsys.img"
export HAMFB_FILE="$WORK/fb.raw"
export HAMFB_GEOM="$GEOM"
export HAMWSYSD_INPUT="$WORK/input.evdev"
: >"$HAMWSYSD_INPUT"
[ -r /usr/share/vulkan/icd.d/lvp_icd.json ] && \
    export VK_ICD_FILENAMES="${VK_ICD_FILENAMES:-/usr/share/vulkan/icd.d/lvp_icd.json}"

# The active panel config. On a real machine this is the desktop's live
# override, read by the panel in preference to /etc/panel.conf. Here it is the
# same name inside this run's own /tmp, which no other process can see. The
# rm in cleanup below is now redundant — the tmpfs takes it — and is kept as
# the thing that still holds if someone runs with HAMTEST_NO_PRIVNS=1.
CONF=/tmp/hamnix-panel.conf

pass=0; fail=0
# An empty read is not a measurement. See the header of tests/linux/gate_read.sh:
# vis_of below used to end ${8:-x}, so a ctl line that could not be read at all
# printed "THE DEFECT: the top panel's window went visible 1 -> x ... the
# desktop has no panel" -- a defect named on the evidence of a failed read.
. tests/linux/gate_read.sh

ok()   { echo "panelconf: PASS $*"; pass=$((pass+1)); }
bad()  { echo "panelconf: FAIL $*"; fail=$((fail+1)); }
info() { echo "panelconf: INFO $*"; }

# Stated, not assumed: priv_ns_reexec has already REFUSED to get this far if
# the namespace was not in place, so this line is a report of a fact the run
# depends on rather than a check that could still fail. It is deliberately not
# scored -- the gate's score is about the panel, and an assertion count that
# moves for an unrelated reason is a worse answer than a printed fact.
info "$(priv_ns_describe)"

reap_track "$WORK/reaped"
cleanup() {   # reap_on_exit has already run reap_all by the time this is called
    rm -f "$CONF"
    # $WORK is inside this run's private /tmp, which the kernel takes down with
    # the namespace whatever happens here -- so KEEP=1 has to copy anything it
    # wants to survive OUT, to a path the namespace does not shadow.
    if [ "$KEEP" = 1 ] && [ "${HAMTEST_NO_PRIVNS:-0}" != 1 ]; then
        local dest; dest="$(priv_ns_keep panelconf)" && {
            cp -a "$WORK/." "$dest/" 2>/dev/null
            echo "panelconf: INFO kept the run's artefacts at $dest"
        }
    elif [ "$KEEP" != 1 ]; then
        rm -rf "$WORK"
    fi
}
reap_on_exit cleanup
done_report() { echo "panelconf: $pass passed, $fail failed"; [ "$fail" = 0 ]; }

# ---- the pixel probe ------------------------------------------------------
# One question: what fraction of this rectangle is exactly this colour.
FRAC_PY="$WORK/frac.py"
cat >"$FRAC_PY" <<'PY'
import sys
W, H = int(sys.argv[1]), int(sys.argv[2])
x, y, w, h = (int(v) for v in sys.argv[3:7])
d = open(sys.argv[7], 'rb').read()
c = sys.argv[8]
want = (int(c[0:2], 16), int(c[2:4], 16), int(c[4:6], 16))
tot = hit = 0
for j in range(y, min(y + h, H), 2):
    row = j * W * 4
    for i in range(x, min(x + w, W), 2):
        o = row + i * 4
        tot += 1
        if (d[o+2], d[o+1], d[o]) == want:
            hit += 1
print(0 if tot == 0 else hit * 100 // tot)
PY
colourpct() { python3 "$FRAC_PY" "$FBW" "$FBH" "$1" "$2" "$3" "$4" "$5" "$6"; }
snap()      { cp "$HAMFB_FILE" "$WORK/$1.raw"; }

# ---- build ----------------------------------------------------------------
# PANELCONF_BIN_DIR runs this gate against binaries somebody else produced
# (the published tarball, say). A binary the directory does not hold is
# REFUSED by name rather than quietly compiled from this tree — answering
# about the working tree when the caller asked about other bytes is the
# success-shaped answer to a different question. wsys_poke is a test
# instrument and always comes from the tree; it only ever READS (assertion 13).
BINDIR="${PANELCONF_BIN_DIR:-}"
for t in wsysd:user/wsysd.ad \
         hamdesktop:user/hamdesktop.ad \
         hampanelscene:user/hampanelscene.ad \
         wsys_poke:tests/linux/wsys_poke.ad; do
    name="${t%%:*}"; src="${t#*:}"
    if [ -n "$BINDIR" ] && [ "$name" != wsys_poke ]; then
        [ -f "$BINDIR/$name" ] || {
            bad "PANELCONF_BIN_DIR=$BINDIR does not contain $name -- refusing to substitute a fresh build for the binary you asked about"
            done_report; exit 1; }
        cp "$BINDIR/$name" "$WORK/$name.elf"; chmod +x "$WORK/$name.elf"
        continue
    fi
    scripts/hamlinux_build.sh "$src" "$WORK/$name.elf" \
        >"$WORK/$name.build.log" 2>&1 || {
        bad "could not build $src"; tail -20 "$WORK/$name.build.log" >&2
        done_report; exit 1; }
done
if [ -n "$BINDIR" ]; then
    ok "the compositor, the desktop and the panel came from $BINDIR (not built here)"
else
    ok "the compositor, the desktop and the panel all build"
fi

winctl() { "$WORK/wsys_poke.elf" "/dev/wsys/$1/ctl" 2>/dev/null; }
# Field 8 of the ctl line is `visible` (user/linux-wsys.c snap_win_ctl).
#
# These used to default to x / 0 on a ctl line that did not come back, and
# those defaults WERE VERDICTS: "visible 1 -> x", or a height of 0 that is not
# greater than $TOPH so "the Applications button does not work". An unreadable
# line now yields the EMPTY STRING, and every caller asks gate_nonempty about
# it by name and SKIPS the assertion rather than answering it from a default.
vis_of() { set -- $(winctl "$1"); echo "${8:-}"; }
w_of()   { set -- $(winctl "$1"); echo "${4:-}"; }
h_of()   { set -- $(winctl "$1"); echo "${5:-}"; }
y_of()   { set -- $(winctl "$1"); echo "${3:-}"; }

# ---- the mouse: synthetic evdev, byte for byte what /dev/input/eventN gives -
EVDEV_PY="$WORK/evdev.py"
cat >"$EVDEV_PY" <<'PY'
import struct, sys
path, W, H = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
recs = []
for tok in sys.argv[4:]:
    kind, *a = tok.split(':')
    if kind == 'move':
        x, y = int(a[0]), int(a[1])
        recs += [(3, 0, x * 32768 // W), (3, 1, y * 32768 // H), (0, 0, 0)]
    elif kind == 'down':
        recs += [(1, 272, 1), (0, 0, 0)]
    elif kind == 'up':
        recs += [(1, 272, 0), (0, 0, 0)]
with open(path, 'ab') as f:
    for t, c, v in recs:
        f.write(struct.pack('<qqHHi', 0, 0, t, c, v))
PY
ev() { python3 "$EVDEV_PY" "$WORK/input.evdev" "$FBW" "$FBH" "$@"; }
click() {   # click <x> <y> -- move, settle, press, hold, release
    ev "move:$1:$2"; sleep 0.4
    ev "down"; sleep 0.4
    ev "up";  sleep 1.2
}

# ---- the config, present BEFORE the panel starts -------------------------
# It has to be there first: `_cfg_changed` primes its snapshot at startup, so
# "the file appeared" and "the file was replaced" are different events, and
# the machine measurement was the second one.
#
# This is `etc/panel.conf` ITSELF, copied verbatim -- comment header and all.
#
# It could not be, until the streaming reader landed. `_load_config` used to
# read at most 2047 bytes; etc/panel.conf is 3120 bytes and its first `panel`
# line does not begin until byte 2834, so a copy of the file as shipped parsed
# to ZERO panels and the panel silently fell back to `_default_config` --
# measured here at the time: with the file copied, the bars came up in a
# colour that is not the `color #d4d0c8` the file asks for. So this gate wrote
# the same two blocks out by hand, WITHOUT the header, because a config that
# is never parsed cannot be replaced under anyone. `_load_config` now streams
# the file in chunks and parses it a line at a time, with no size ceiling, so
# the shipped bytes work and the hand-written copy is gone. The colour
# assertions below are now measuring the shipped file's own `color` line;
# tests/linux/de_panel_conf_shipped.sh is the gate that exists for that
# question specifically.
SHIPPED_CONF="$PROJ_ROOT/etc/panel.conf"
panel_conf() {   # panel_conf <marker> [one]  -- the config, with a marker line
    # PANELCONF_TAG lets a caller stamp every config this run writes with
    # something no other run can produce, so that "did this file escape?" is
    # answerable by identity rather than by a count that cannot tell whose
    # leak it found. tests/linux/private_ns_isolates.sh uses it for exactly
    # that. It is otherwise inert.
    echo "# $1 ${PANELCONF_TAG:-}"
    if [ "${2:-}" = one ]; then
        # the shipped file with its SECOND `panel ... end` block deleted
        sed '/^panel bottom$/,/^end$/d' "$SHIPPED_CONF"
    else
        cat "$SHIPPED_CONF"
    fi
}
panel_conf "as installed" >"$CONF"

# ---- the compositor, the desktop and the panel ---------------------------
"$WORK/wsysd.elf" </dev/null >"$WORK/wsysd.log" 2>&1 &
reap_add $!
for _ in $(seq 1 60); do [ -s "$HAMFB_FILE" ] && break; sleep 0.1; done
[ -s "$HAMFB_FILE" ] || { bad "wsysd never produced a framebuffer"
                          cat "$WORK/wsysd.log"; done_report; exit 1; }
if grep -q "input from $WORK/input.evdev only" "$WORK/wsysd.log"; then
    ok "wsysd took its input from the test's evdev file and opened no real device"
else
    bad "wsysd did not honour HAMWSYSD_INPUT -- it may be reading this host's keyboard"
fi

"$WORK/hamdesktop.elf" </dev/null >"$WORK/hamdesktop.log" 2>&1 &
reap_add $!
sleep 3
"$WORK/hampanelscene.elf" </dev/null >"$WORK/panel.log" 2>&1 &
reap_add $!
sleep 4

# ---- 2. THE CONTROL: a desktop with a panel and a taskbar on it ----------
# Found rather than guessed. The backdrop is the full-screen window; the two
# bars are the full-width windows that are not it.
BACKDROP=""; TOPBAR=""; BOTBAR=""; TOPH=""; BOTH=""; BOTY=0
for wid in $(seq 2 40); do
    line="$(winctl "$wid")"; [ -n "$line" ] || continue
    set -- $line
    [ "${4:-}" = "$FBW" ] || continue
    if [ "${5:-0}" -ge 200 ]; then BACKDROP="$wid"; continue; fi
    if [ "${3:-0}" = "0" ]; then TOPBAR="$wid"; TOPH="${5:-}"
    else                          BOTBAR="$wid"; BOTH="${5:-}"; BOTY="${3:-}"; fi
done
if [ -n "$TOPBAR" ] && [ -n "$BOTBAR" ] && [ -n "$BACKDROP" ]; then
    ok "control: a backdrop (wid $BACKDROP), a top panel (wid $TOPBAR, ${TOPH}px) and a taskbar (wid $BOTBAR, ${BOTH}px at y=$BOTY) are on screen"
else
    bad "control: the desktop did not come up (backdrop='$BACKDROP' top='$TOPBAR' bottom='$BOTBAR') -- nothing below can be answered"
    sed 's/^/panelconf:      /' "$WORK/panel.log" | tail -20
    done_report; exit 1
fi
tvis0="$(vis_of "$TOPBAR")"; bvis0="$(vis_of "$BOTBAR")"
if ! gate_nonempty "the top panel's visible field (/dev/wsys/$TOPBAR/ctl), read for the control" "$tvis0"; then
    :
elif ! gate_nonempty "the taskbar's visible field (/dev/wsys/$BOTBAR/ctl), read for the control" "$bvis0"; then
    :
elif [ "$tvis0" = 1 ] && [ "$bvis0" = 1 ]; then
    ok "control: both panel windows report visible=1 before anything touches the config"
else
    bad "control: a panel window is already invisible before the config was touched (top=$tvis0 bottom=$bvis0)"
fi

# The panel bar's own background colour, from etc/panel.conf (`color #d4d0c8`).
BARCOL=d4d0c8
BODYCOL=f7f8fa
APPBTN_X=40; APPBTN_Y=13
CARDW=136
CARD_Y=$((TOPH + 34)); CARD_H=140
# A strip of each bar well clear of the widgets at either end.
TOPSTRIP_X=$((FBW / 2 - 100)); TOPSTRIP_W=200
BOTSTRIP_X=$((FBW - 300));     BOTSTRIP_W=200

snap control
topfill0="$(colourpct "$TOPSTRIP_X" 2 "$TOPSTRIP_W" $((TOPH - 4)) "$WORK/control.raw" "$BARCOL")"
botfill0="$(colourpct "$BOTSTRIP_X" $((BOTY + 2)) "$BOTSTRIP_W" $((BOTH - 4)) "$WORK/control.raw" "$BARCOL")"
if [ "$topfill0" -ge 60 ] && [ "$botfill0" -ge 60 ]; then
    ok "control: both bars are PAINTED in the framebuffer (top ${topfill0}%, taskbar ${botfill0}% of the bar colour)"
else
    bad "control: the bars are not painted (top ${topfill0}%, taskbar ${botfill0}%) -- these rectangles are not measuring the panel"
fi

# ---- 3+4. THE CONTROL CLICK ----------------------------------------------
got="$(colourpct 4 "$CARD_Y" $((CARDW - 8)) "$CARD_H" "$WORK/control.raw" "$BODYCOL")"
if [ "$got" -le 5 ]; then
    ok "control: with no click yet the menu card is not drawn (${got}% of the card column is the dropdown body)"
else
    bad "control: the dropdown body colour is already ${got}% of the card column before any click -- this rectangle is not measuring the menu"
fi
click "$APPBTN_X" "$APPBTN_Y"
snap ctlopen
CTLGROWN="$(h_of "$TOPBAR")"
ctlcard="$(colourpct 4 "$CARD_Y" $((CARDW - 8)) "$CARD_H" "$WORK/ctlopen.raw" "$BODYCOL")"
if ! gate_nonempty "the top panel's height (/dev/wsys/$TOPBAR/ctl) after the control click" "$CTLGROWN"; then
    info "the panel's height could not be read, so 'does the Applications button work before the config is touched' is not a question this run can answer -- and nothing below it is either"
    done_report; exit 1
elif [ "$CTLGROWN" -gt "$TOPH" ] && [ "$ctlcard" -ge 60 ]; then
    ok "control: an evdev click on the Applications button opens the menu (${TOPH} -> ${CTLGROWN} px, card ${ctlcard}% painted)"
else
    bad "control: the Applications button does not work BEFORE the config is touched (${CTLGROWN} px, card ${ctlcard}%) -- nothing below can be answered"
    done_report; exit 1
fi
click "$APPBTN_X" "$APPBTN_Y"      # close it again
sleep 1

# ---- the replacement ------------------------------------------------------
# The rewritten file differs from the original by ONE COMMENT LINE. The layout
# it asks for is byte-for-byte the layout already on screen: nothing about the
# panel's geometry, widgets, colour or count changes. The only event is "the
# active config was replaced". A desktop that loses its panel to that has lost
# it to the reload itself.
replace_unlinked() {   # what hpm does: unlink, then write a new inode
    rm -f "$CONF"
    panel_conf "replaced by a package $1" >"$CONF"
}
replace_in_place() {   # same inode, truncated and rewritten
    panel_conf "rewritten in place $1" >"$CONF.new"
    cat "$CONF.new" >"$CONF"
    rm -f "$CONF.new"
}
# Wait for the panel to PICK UP a replacement. The reload line is a
# synchronisation point only -- it is never an answer here, because it stayed
# true all the way through the defect.
reloads() {   # grep -c prints its count AND exits 1 when the count is 0, so a
              # `|| echo 0` fallback appends a SECOND number. Take grep's.
    local n; n="$(grep -ac 'config reload applied' "$WORK/panel.log" 2>/dev/null)"
    echo "${n:-0}"
}
await_reload() {   # await_reload <count-before>
    for _ in $(seq 1 60); do
        [ "$(reloads)" -gt "$1" ] && return 0
        sleep 0.25
    done
    return 1
}

# ---- 5+6+7+8. THE CONFIG REPLACED UNDER A RUNNING PANEL ------------------
before="$(reloads)"
replace_unlinked 1
if await_reload "$before"; then
    ok "the panel picked up the replaced config ($(reloads) reload(s) logged)"
else
    bad "the panel never noticed the config was replaced -- this run cannot answer what a reload does"
    done_report; exit 1
fi
sleep 1
snap afterunlink
tvis="$(vis_of "$TOPBAR")"; bvis="$(vis_of "$BOTBAR")"; dvis="$(vis_of "$BACKDROP")"
if ! gate_nonempty "the top panel's visible field (/dev/wsys/$TOPBAR/ctl) after the replacement" "$tvis"; then
    :
elif [ "$tvis" = 1 ]; then
    ok "the TOP PANEL still has its window on screen after the replacement (visible=$tvis)"
else
    bad "THE DEFECT: the top panel's window went visible 1 -> $tvis when its config was replaced. The process is still alive and still logging reloads; the desktop has no panel"
fi
if ! gate_nonempty "the taskbar's visible field (/dev/wsys/$BOTBAR/ctl) after the replacement" "$bvis"; then
    :
elif [ "$bvis" = 1 ]; then
    ok "the TASKBAR still has its window on screen after the replacement (visible=$bvis)"
else
    bad "THE DEFECT: the taskbar's window went visible 1 -> $bvis when the config was replaced"
fi
if ! gate_nonempty "the backdrop's visible field (/dev/wsys/$BACKDROP/ctl) after the replacement" "$dvis"; then
    :
elif [ "$dvis" = 1 ]; then
    ok "the BACKDROP is untouched (visible=$dvis) -- hamdesktop never writes the verb this defect is in, so 'the wallpaper survived' is the expected shape, not a reprieve"
else
    bad "the backdrop ALSO went visible=$dvis -- then this is not the panel's bug and the cause above is wrong"
fi
topfill="$(colourpct "$TOPSTRIP_X" 2 "$TOPSTRIP_W" $((TOPH - 4)) "$WORK/afterunlink.raw" "$BARCOL")"
botfill="$(colourpct "$BOTSTRIP_X" $((BOTY + 2)) "$BOTSTRIP_W" $((BOTH - 4)) "$WORK/afterunlink.raw" "$BARCOL")"
if [ "$topfill" -ge 60 ] && [ "$botfill" -ge 60 ]; then
    ok "and both bars are still PAINTED (top ${topfill}%, taskbar ${botfill}%) -- pixels, not a flag"
else
    bad "THE DEFECT, in pixels: after the replacement the top bar is ${topfill}% and the taskbar ${botfill}% of the bar colour (was ${topfill0}% / ${botfill0}%)"
fi

# ---- 9. AND THE APPLICATIONS BUTTON STILL WORKS --------------------------
click "$APPBTN_X" "$APPBTN_Y"
snap afteropen
GROWN="$(h_of "$TOPBAR")"
card="$(colourpct 4 "$CARD_Y" $((CARDW - 8)) "$CARD_H" "$WORK/afteropen.raw" "$BODYCOL")"
if ! gate_nonempty "the top panel's height (/dev/wsys/$TOPBAR/ctl) after the post-replacement click" "$GROWN"; then
    :
elif [ "$GROWN" -gt "$TOPH" ] && [ "$card" -ge 60 ]; then
    ok "a real click on the Applications button AFTER the replacement still opens the menu (${TOPH} -> ${GROWN} px, card ${card}% painted)"
else
    bad "THE DEFECT: after the replacement a real click on the Applications button leaves the panel ${GROWN} px tall with the card ${card}% painted -- on the machine this changed 234 pixels, the mouse cursor and nothing else"
fi
click "$APPBTN_X" "$APPBTN_Y"      # close it again
sleep 1

# ---- 10. THE SAME REPLACEMENT, IN PLACE ----------------------------------
# hpm unlinks and rewrites, so "an open watch or an inode-keyed reload sees
# something different from a rewrite" was a live hypothesis. It is not the
# cause: the same thing happens to a file rewritten through its own inode.
before="$(reloads)"
replace_in_place 2
if await_reload "$before"; then
    sleep 1
    tvis2="$(vis_of "$TOPBAR")"; bvis2="$(vis_of "$BOTBAR")"
    if ! gate_nonempty "the top panel's visible field (/dev/wsys/$TOPBAR/ctl) after the in-place rewrite" "$tvis2"; then
        :
    elif ! gate_nonempty "the taskbar's visible field (/dev/wsys/$BOTBAR/ctl) after the in-place rewrite" "$bvis2"; then
        :
    elif [ "$tvis2" = 1 ] && [ "$bvis2" = 1 ]; then
        ok "an IN-PLACE rewrite (same inode, no unlink) also leaves both windows on screen (top=$tvis2 taskbar=$bvis2) -- the trigger is the reload, and the unlink is not part of it"
    else
        bad "THE DEFECT reproduces through an in-place rewrite too (top=$tvis2 taskbar=$bvis2) -- so it is the reload, not the unlink"
    fi
else
    bad "an in-place rewrite was never picked up -- the in-place question is unanswered"
fi

# ---- 11+12. THE OTHER DIRECTION OF THE SAME VERB -------------------------
# The fix must not turn `hide` into a no-op: a config that DROPS a panel has
# to withdraw the surplus window, or the taskbar is left behind as a dead bar
# swallowing clicks (the defect _set_window_hidden's own comment records).
before="$(reloads)"
panel_conf "one panel only" one >"$CONF"
if await_reload "$before"; then
    sleep 1
    snap onepanel
    bvis3="$(vis_of "$BOTBAR")"
    botfill3="$(colourpct "$BOTSTRIP_X" $((BOTY + 2)) "$BOTSTRIP_W" $((BOTH - 4)) "$WORK/onepanel.raw" "$BARCOL")"
    if ! gate_nonempty "the taskbar's visible field (/dev/wsys/$BOTBAR/ctl) under the one-panel config" "$bvis3"; then
        :
    elif [ "$bvis3" = 0 ] && [ "$botfill3" -le 5 ]; then
        ok "a config that drops to ONE panel still WITHDRAWS the taskbar window (visible=$bvis3, ${botfill3}% of the bar colour left in the band)"
    else
        bad "the surplus panel window was not withdrawn (visible=$bvis3, ${botfill3}% of the bar colour still painted) -- a dead bar is left on screen swallowing clicks"
    fi
else
    bad "the one-panel config was never picked up"
fi
before="$(reloads)"
panel_conf "two panels again" >"$CONF"
if await_reload "$before"; then
    sleep 1
    snap twoback
    bvis4="$(vis_of "$BOTBAR")"
    botfill4="$(colourpct "$BOTSTRIP_X" $((BOTY + 2)) "$BOTSTRIP_W" $((BOTH - 4)) "$WORK/twoback.raw" "$BARCOL")"
    if ! gate_nonempty "the taskbar's visible field (/dev/wsys/$BOTBAR/ctl) after the second panel came back" "$bvis4"; then
        :
    elif [ "$bvis4" = 1 ] && [ "$botfill4" -ge 60 ]; then
        ok "and putting the second panel back brings the taskbar window back (visible=$bvis4, ${botfill4}% repainted) -- withdraw and restore are both live"
    else
        bad "the withdrawn taskbar never came back (visible=$bvis4, ${botfill4}% painted) -- a pooled window that can be hidden and not shown is the same defect wearing the other hat"
    fi
else
    bad "the restored two-panel config was never picked up"
fi

# ---- 13. THE RULE THIS GATE KEEPS ----------------------------------------
if grep -vE '^[[:space:]]*#' "${BASH_SOURCE[0]}" \
        | grep -nE 'wsys_poke[^|]*/(event|pointer|keys)' >/dev/null; then
    bad "THIS GATE WRITES AN INPUT RING BY HAND -- its clicks no longer prove anything about the chrome"
else
    ok "every click in this file came from the evdev end: nothing here writes an event, pointer or keys ring"
fi

info "reloads applied: $(reloads); panel log tail:"
grep -a 'config reload applied' "$WORK/panel.log" | tail -4 | sed 's/^/panelconf:      /'
done_report
