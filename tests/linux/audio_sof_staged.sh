#!/usr/bin/env bash
# tests/linux/audio_sof_staged.sh — THE SOUND CARD OF A MODERN INTEL LAPTOP
# NEEDS A BLOB, AND THIS MEDIUM SHIPPED NONE.
#
# WHAT THIS IS ABOUT
# ==================
# The owner reported "Audio does not seem to work" on a Lenovo 20Y0X50600, and
# his own boot log named the reason in a line that reads like the opposite of
# what it is:
#
#     snd_hda_intel 0000:00:1f.3: Digital mics found on Skylake+ platform,
#                                 using SOF driver
#
# THAT IS A REFUSAL, NOT A SUCCESSFUL PROBE. The string is not in
# snd-hda-intel.ko; it is in snd-intel-dspcfg.ko, the arbiter snd_hda_intel's
# probe consults FIRST, and when that arbiter answers SOF, snd_hda_intel
# returns -ENODEV and BINDS NOTHING. It carries snd_hda_intel's dev prefix only
# because it is printed from snd_hda_intel's probe path, which is exactly why
# "the driver loaded, so the driver is fine" is the wrong reading.
#
# So the device is claimed by the Sound Open Firmware stack or by nobody, and a
# SOF DSP needs THREE things on the medium, not one:
#
#   1. the SOF kernel modules            (snd-sof-pci-intel-tgl and its chain)
#   2. the DSP BOOT IMAGE                (intel/sof/sof-<part>.ri)
#   3. a TOPOLOGY                        (intel/sof-tplg/sof-hda-generic*.tplg)
#
# MISS ANY ONE AND THE SYMPTOM IS IDENTICAL AND SILENT: no card, therefore no
# /dev/snd/pcmC0D0p, therefore user/linux-audio.c's open() fails and every
# program above it honestly reports "no audio device". Before the commit that
# added this gate the medium had NONE of (2) and (3) and no code path that
# could ever stage them -- `grep -n firmware scripts/hamlinux_image.sh` matched
# nothing at all, while scripts/hamlinux_packages.py had shipped
# hamnix-firmware-i915-* for some time. The channel could carry firmware the
# image could not.
#
# WHY A GATE AND NOT A LINE IN A COMMIT MESSAGE: this is an ABSENCE bug. It has
# no symptom on the build host, no symptom in any VM (see the caveat below),
# and its only reporter is a person with the hardware three weeks later. The
# one thing that can be checked here is whether the bytes are on the medium at
# the exact paths the kernel's firmware loader asks for.
#
# WHAT A VM CANNOT TELL US, STATED UP FRONT
# =========================================
# NOTHING BELOW PROVES HIS AUDIO WORKS, and no test on this hardware can.
# QEMU's intel-hda is a plain HDA controller with NO DSP, so snd-intel-dspcfg
# answers LEGACY inside every VM and not one of the SOF modules this gate
# checks for would ever bind there. This build host cannot stand in for his
# either: it is a Cannon Lake part (8086:a348, subvendor 0x1458 -- Gigabyte,
# not the Lenovo) already bound to snd_hda_intel, which never enters the SOF
# path. Its sound hardware is also the OWNER'S OWN and is off limits: this gate
# opens no /dev/snd, plays nothing, and loads and unloads no module. It reads
# files, and that is the whole of its authority.
#
# What it therefore proves is a NECESSARY condition, checked exactly: the
# medium carries the three things, at the right paths, with real content. The
# SUFFICIENT condition is his next boot log.
#
# THE ONE KNOWN HOLE, and it is deliberate rather than overlooked: the 6.12
# driver can speak IPC3 or IPC4 to a Tiger Lake DSP, which decides whether it
# loads intel/sof/sof-tgl-h.ri (staged, asserted below) or
# intel/sof-ipc4/tgl-h/sof-tgl-h.ri (NOT staged). TGL's documented default on
# this kernel is IPC3. That is READ, NOT MEASURED, and it cannot be measured
# here. If his log shows a failed firmware request for an intel/sof-ipc4/ path,
# the fix is a glob in WANT_FIRMWARE and this gate will then assert it.
#
# HOW IT PROVES IT CAN GO RED
# ===========================
# A missing-file check that cannot fail is worthless, and this gate is almost
# entirely missing-file checks. So PHASE R re-runs every assertion against a
# SHADOW ROOT -- a symlink farm of the real image root with exactly the SOF
# modules and firmware left out -- and requires each one to FAIL there. The
# shadow tree is built by this script, so the red arm is not a claim in a
# comment; it runs on every invocation and the gate FAILS if an assertion
# passes on a root that does not have the files.
#
# Usage: tests/linux/audio_sof_staged.sh [image-root] [channel-dir]
#   defaults: build/image/root  build/repo/linux
# Builds nothing: a gate that rebuilds its own inputs can hide the failure it
# exists to catch. Run scripts/hamlinux_image.sh and
# scripts/hamlinux_packages.py first.

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

# Isolated even though it only reads: this gate writes a shadow tree and a
# couple of temporary lists, and "it only reads today" is how a gate that
# writes the machine's /tmp starts. private_ns.sh shadows /tmp, /dev/shm, /srv
# and $XDG_RUNTIME_DIR; the image root it reads lives under the repo and is
# untouched by that.
# shellcheck source=tests/linux/private_ns.sh
if [ -r tests/linux/private_ns.sh ]; then
    . tests/linux/private_ns.sh
    priv_ns_reexec "$@"
fi

IMG="${1:-$PROJ_ROOT/build/image/root}"
CHAN="${2:-$PROJ_ROOT/build/repo/linux}"

PASS=0; FAIL=0; INFO=0
ok()   { PASS=$((PASS+1)); echo "sof: PASS $*"; }
bad()  { FAIL=$((FAIL+1)); echo "sof: FAIL $*"; }
note() { INFO=$((INFO+1)); echo "sof: INFO $*"; }

[ -d "$IMG" ] || { echo "sof: FAIL no image root at $IMG (run scripts/hamlinux_image.sh)"; exit 1; }

KVER="$(ls "$IMG/lib/modules" 2>/dev/null | head -1)"
[ -n "$KVER" ] || { echo "sof: FAIL no $IMG/lib/modules/<kver> -- the image looks unbuilt"; exit 1; }
echo "sof: image root $IMG"
echo "sof: kernel      $KVER"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
trap 'exit 130' INT TERM HUP

# ---------------------------------------------------------------------------
# WHAT MUST BE THERE.
#
# THE MODULE NAMES ARE THE CLOSURE, NOT THE THREE NAMES IN WANT_FIRMWARE's
# neighbour list. Naming only snd-sof-pci-intel-tgl here would pass on a medium
# that staged the PCI stub and none of the DSP core it needs -- which is a
# machine with no sound and a green gate. These are the files `modprobe
# --dry-run --show-depends snd-sof-pci-intel-tgl snd-sof-intel-hda-generic
# snd-soc-hdac-hda` resolves, minus the nine snd-hda-intel already brought.
# ---------------------------------------------------------------------------
SOF_KOS="
snd-sof.ko
snd-sof-pci.ko
snd-sof-utils.ko
snd-sof-xtensa-dsp.ko
snd-sof-intel-hda.ko
snd-sof-intel-hda-common.ko
snd-sof-intel-hda-generic.ko
snd-sof-intel-hda-mlink.ko
snd-sof-pci-intel-tgl.ko
snd-soc-core.ko
snd-soc-acpi.ko
snd-soc-acpi-intel-match.ko
snd-soc-hdac-hda.ko
snd-hda-ext-core.ko
"
# SPACE-SEPARATED ON ONE LINE, for the `case` match in PHASE R. The list above
# is newline-separated for readability, and `case " $SOF_KOS " in *" $b "*)`
# SILENTLY MATCHED NOTHING because the separator either side of a name is a
# NEWLINE, not a space -- so the red arm withheld no modules at all, the shadow
# root came out 91 of 91, and the gate reported "only 5 of 6 assertions failed"
# rather than pretending. That is the check on the red arm doing its job: a
# broken red arm has to be as loud as a broken subject.
SOF_KOS_FLAT="$(echo $SOF_KOS)"

# HIS BLOB IS ASSERTED BY NAME. sof-tgl-h.ri is the file the owner's Tiger
# Lake-H part loads; a gate that only counted "some firmware is present" would
# stay green on a medium that shipped seventeen other platforms and not his.
HIS_RI="lib/firmware/intel/sof/sof-tgl-h.ri"
# The topology the generic-HDA machine driver asks for. All the dmic counts are
# staged; 2ch is the one asserted by name because it is the ordinary case.
HIS_TPLG="lib/firmware/intel/sof-tplg/sof-hda-generic-2ch.tplg"

# ---------------------------------------------------------------------------
# THE ASSERTIONS, as a function so PHASE R can run the identical code against a
# root with the files removed. `$1` is the root; it reports through ok/bad only
# when $2 is "live", and otherwise counts silently -- which is what makes the
# red arm a measurement rather than a second implementation.
#
# THE COUNT COMES BACK IN A GLOBAL, NOT ON STDOUT, and that is a bug this file
# had first: `n=$(sof_check ... | tail -1)` runs the function in a SUBSHELL, so
# every PASS: line printed correctly and every PASS=$((PASS+1)) was thrown away
# with the subshell -- the gate would have reported "0 passed, 0 failed" while
# printing six passes, and the final tally is what a person reads.
SOF_FAILS=0
sof_check() {
    local root="$1" mode="$2" fails=0
    local moddir="$root/lib/modules/$KVER"

    # (1) THE MODULES ARE ON THE MEDIUM.
    # `find -print -quit` into a variable, then test the variable: writing
    # `[ -s "$(find ...)" ]` makes an empty result read as `[ -s "" ]`, which is
    # a syntax the shell accepts and answers false for the wrong reason -- it
    # would have reported "missing" for a module that was present but unfindable
    # and "missing" for one genuinely absent, indistinguishably.
    local missing="" ko hit n=0
    for ko in $SOF_KOS; do
        hit="$(find "$moddir" -name "$ko" -print -quit 2>/dev/null)"
        if [ -n "$hit" ] && [ -s "$hit" ]; then
            n=$((n+1))
        else
            missing="$missing $ko"
        fi
    done
    if [ -z "$missing" ]; then
        [ "$mode" = live ] && ok "all $n SOF-chain modules are staged under lib/modules/$KVER"
    else
        fails=$((fails+1))
        [ "$mode" = live ] && bad "SOF modules NOT on the medium --$missing (a Skylake+ Intel machine has no sound card at all without these)"
    fi

    # (2) THEY ARE LOADED AT BOOT. linuxinit walks /etc/modules in file order;
    # a .ko on the disk that nothing loads is a driver an installed machine
    # will not have bound by the time the desktop starts.
    if [ -f "$root/etc/modules" ] \
       && grep -q 'snd-sof-pci-intel-tgl\.ko' "$root/etc/modules"; then
        [ "$mode" = live ] && ok "/etc/modules lists snd-sof-pci-intel-tgl.ko, so PID 1 loads it at boot"
    else
        fails=$((fails+1))
        [ "$mode" = live ] && bad "/etc/modules does NOT list snd-sof-pci-intel-tgl.ko -- the module would be on the disk and never loaded"
    fi

    # (3) modprobe CAN NAME THEM. The boot list uses absolute paths, but
    # anything that later types `modprobe snd-sof-pci-intel-tgl` needs the
    # dependency table to resolve it.
    if [ -f "$moddir/modules.dep" ] \
       && grep -q 'snd-sof-pci-intel-tgl\.ko' "$moddir/modules.dep"; then
        [ "$mode" = live ] && ok "modules.dep resolves snd-sof-pci-intel-tgl, so modprobe can name it"
    else
        fails=$((fails+1))
        [ "$mode" = live ] && bad "modules.dep has no snd-sof-pci-intel-tgl line -- modprobe could not resolve the name"
    fi

    # (4) HIS DSP BOOT IMAGE, at the exact path the firmware loader requests,
    # with REAL CONTENT. Not a symlink: on the build host 15 of the 18 .ri are
    # links into intel-signed/, which is NOT staged, so a link-preserving copy
    # would put a dangling symlink where the kernel expects 447 KB of signed
    # firmware -- and a plain -e test would have called that a pass.
    if [ -f "$root/$HIS_RI" ] && [ ! -L "$root/$HIS_RI" ] \
       && [ "$(stat -c %s "$root/$HIS_RI" 2>/dev/null || echo 0)" -gt 100000 ]; then
        [ "$mode" = live ] && ok "$HIS_RI is present, a real file, $(stat -c %s "$root/$HIS_RI") bytes -- the DSP boot image his Tiger Lake-H part loads"
    else
        fails=$((fails+1))
        [ "$mode" = live ] && bad "$HIS_RI is missing, a symlink, or too small -- his DSP cannot start, so no sound card is ever created"
    fi

    # (5) A TOPOLOGY. A DSP that booted its firmware and got no topology has no
    # PCM device either -- the same silence from a different cause.
    if [ -f "$root/$HIS_TPLG" ] && [ ! -L "$root/$HIS_TPLG" ] \
       && [ -s "$root/$HIS_TPLG" ]; then
        [ "$mode" = live ] && ok "$HIS_TPLG is present, a real file, $(stat -c %s "$root/$HIS_TPLG") bytes -- the topology that BECOMES the card's PCM and control devices"
    else
        fails=$((fails+1))
        [ "$mode" = live ] && bad "$HIS_TPLG is missing or empty -- the DSP would boot and create no PCM device"
    fi

    # (6) THE WHOLE STAGED FIRMWARE SET IS NON-TRIVIAL. Guards against a
    # staging loop that silently matched one file, or created a file literally
    # named `*.ri` because a glob went unexpanded.
    local nfw
    nfw=$(find "$root/lib/firmware" -type f 2>/dev/null | wc -l)
    if [ "$nfw" -ge 20 ] \
       && ! find "$root/lib/firmware" -name '*[*]*' -print -quit 2>/dev/null | grep -q .; then
        [ "$mode" = live ] && ok "$nfw firmware files staged, none with an unexpanded glob in its name"
    else
        fails=$((fails+1))
        [ "$mode" = live ] && bad "only $nfw firmware files under lib/firmware, or one has a '*' in its name (an unexpanded glob)"
    fi

    SOF_FAILS=$fails
}

SOF_ASSERTIONS=6

echo
echo "sof: --- PHASE A: the medium as built ---"
sof_check "$IMG" live
LIVE_FAILS=$SOF_FAILS

# ---------------------------------------------------------------------------
# THE CEILING THIS CHANGE MOVED TOWARDS, and it is checked here because THIS
# change is what made it close. user/linuxinit.ad:53 declares
# `modlist: Array[8192, uint8]` and :204 fills it with ONE
# `sys_read(fd, &modlist[0], 8192)`. There is no second read: a longer
# /etc/modules is silently TRUNCATED, and PID 1 simply stops loading modules
# part-way down the list.
#
# WHICH MODULES WOULD BE LOST IS NOT ARBITRARY -- IT IS THESE. The list is in
# dependency order and the SOF stack is at the END of it (snd-sof-pci-intel-tgl
# is the very last line), so the first thing a truncation eats is the sound
# stack this gate is about, and the symptom would be indistinguishable from the
# bug it was written for: no card, no /dev/snd, "audio does not seem to work".
#
# Adding the SOF chain took this file from ~5.0 KB to 6018 bytes of 8192. That
# is 2174 bytes of headroom and it is no longer comfortable, so it is measured
# on every run instead of being rediscovered as a machine that boots without
# sound. It is NOT part of the red-arm set below: withholding the SOF modules
# makes this file SMALLER, so it would pass in the red arm and break the
# "every assertion must be able to fail" count. A ceiling is a different kind
# of claim from a presence, and mixing them would weaken the stronger one.
MODLIST_CAP=8192
MODLIST_BYTES=$(wc -c < "$IMG/etc/modules" 2>/dev/null || echo 0)
if [ "$MODLIST_BYTES" -gt 0 ] && [ "$MODLIST_BYTES" -le "$MODLIST_CAP" ]; then
    ok "/etc/modules is $MODLIST_BYTES bytes of linuxinit's $MODLIST_CAP-byte single read ($((MODLIST_CAP-MODLIST_BYTES)) spare) -- the boot list is not truncated"
else
    bad "/etc/modules is $MODLIST_BYTES bytes against linuxinit's $MODLIST_CAP-byte single read (user/linuxinit.ad:53,204) -- PID 1 would SILENTLY stop loading part-way down, and the SOF stack is at the END of the list, so sound is the first thing lost"
fi

# ---------------------------------------------------------------------------
# PHASE C: THE CHANNEL CARRIES IT TOO, so an installed machine can be fixed.
# tests/linux/channel_covers_image.sh enforces this over the whole root; this
# is the same question asked only of the files this gate is about, so that a
# regression here names SOF rather than appearing as one of several hundred
# uncovered paths.
# ---------------------------------------------------------------------------
echo
echo "sof: --- PHASE C: the channel ---"
if [ -d "$CHAN/packages" ]; then
    for t in "$CHAN"/packages/*.tar.gz; do
        [ -e "$t" ] || continue
        tar tzf "$t" 2>/dev/null
    done | sed -n 's|^[^/]*/files/||p' | sort -u > "$TMP/chan"
    NCHAN=$(grep -c . "$TMP/chan" || true)
    if [ "$NCHAN" -lt 200 ]; then
        note "only $NCHAN channel paths extracted from $CHAN/packages -- NOT reporting coverage from a list that implausible"
    else
        ok "channel list is plausible ($NCHAN paths), so the two checks below mean something"
        for want in "$HIS_RI" "$HIS_TPLG"; do
            if grep -qxF "$want" "$TMP/chan"; then
                ok "the channel carries $want -- an installed machine can receive it via hpm"
            else
                bad "$want is on the medium and in NO package -- an installed machine could never be fixed (the updatable invariant)"
            fi
        done
        if grep -q 'snd-sof-pci-intel-tgl\.ko' "$TMP/chan"; then
            ok "the channel carries the SOF kernel modules"
        else
            bad "the SOF modules are on the medium and in no package"
        fi
    fi
else
    note "no channel at $CHAN -- run scripts/hamlinux_packages.py to check coverage (PHASE C skipped, not passed)"
fi

# ---------------------------------------------------------------------------
# PHASE R: THE RED ARM. Every assertion above is "a file is present", and such
# a check is worthless until it has been seen to fail. A shadow root is built
# as a symlink farm of the real one -- so red and green differ in EXACTLY the
# SOF files and nothing else -- and the identical sof_check() is run against
# it. Each assertion must fail there.
# ---------------------------------------------------------------------------
echo
echo "sof: --- PHASE R: the red arm (same assertions, SOF files withheld) ---"
SHADOW="$TMP/shadow"
mkdir -p "$SHADOW"
# Top level is symlinked, except the directories we must edit inside, which are
# reconstructed. This keeps the shadow cheap (no copy of a ~400 MB root).
for e in "$IMG"/*; do
    b="$(basename "$e")"
    case "$b" in
        lib|etc) ;;                       # rebuilt below
        *) ln -s "$e" "$SHADOW/$b" ;;
    esac
done
mkdir -p "$SHADOW/etc" "$SHADOW/lib"
for e in "$IMG"/etc/*; do
    b="$(basename "$e")"
    [ "$b" = modules ] || ln -s "$e" "$SHADOW/etc/$b"
done
for e in "$IMG"/lib/*; do
    b="$(basename "$e")"
    case "$b" in
        modules|firmware) ;;
        *) ln -s "$e" "$SHADOW/lib/$b" ;;
    esac
done
# /etc/modules with every SOF line stripped.
grep -v 'snd-sof\|snd-soc\|snd-hda-ext-core' "$IMG/etc/modules" > "$SHADOW/etc/modules" 2>/dev/null || : > "$SHADOW/etc/modules"
# The module tree, copied by symlink per file, with the SOF .ko withheld and
# the modules.dep lines that name them stripped.
mkdir -p "$SHADOW/lib/modules/$KVER"
( cd "$IMG/lib/modules/$KVER" && find . -type f ) | while read -r f; do
    b="$(basename "$f")"
    case " $SOF_KOS_FLAT " in *" $b "*) continue ;; esac
    [ "$b" = modules.dep ] && continue
    mkdir -p "$SHADOW/lib/modules/$KVER/$(dirname "$f")"
    ln -s "$IMG/lib/modules/$KVER/$f" "$SHADOW/lib/modules/$KVER/$f"
done
grep -v 'snd-sof\|snd-soc-hdac-hda\|snd-hda-ext-core' \
    "$IMG/lib/modules/$KVER/modules.dep" > "$SHADOW/lib/modules/$KVER/modules.dep" 2>/dev/null \
    || : > "$SHADOW/lib/modules/$KVER/modules.dep"
# /lib/firmware: present but EMPTY, which is the state the tree was in before
# the staging block existed.
mkdir -p "$SHADOW/lib/firmware"

sof_check "$SHADOW" red
RED_FAILS=$SOF_FAILS

# The shadow must still look like a real image in every OTHER respect, or the
# red arm is measuring a broken symlink farm rather than the absence of SOF.
NSH=$(find -L "$SHADOW/lib/modules/$KVER" -type f 2>/dev/null | wc -l)
NRE=$(find "$IMG/lib/modules/$KVER" -type f 2>/dev/null | wc -l)
if [ "$NSH" -gt 20 ] && [ "$NSH" -lt "$NRE" ]; then
    ok "the shadow root is a real root minus SOF only ($NSH of $NRE modules still reachable)"
else
    bad "the shadow root has $NSH of $NRE modules -- it is not 'the same root minus SOF', so PHASE R proves nothing"
fi

if [ "$LIVE_FAILS" -eq 0 ]; then
    ok "PHASE A: all $SOF_ASSERTIONS assertions hold on the medium as built"
else
    bad "PHASE A: $LIVE_FAILS of $SOF_ASSERTIONS assertions failed on the medium as built"
fi

# ALL OF THEM, not "more than zero": if the red arm failed only four of six,
# then two of these checks cannot distinguish a medium with the firmware from
# one without, and those two are decoration that would keep the gate green
# through exactly the regression it exists to catch.
if [ "$RED_FAILS" -eq "$SOF_ASSERTIONS" ]; then
    ok "PHASE R: all $SOF_ASSERTIONS assertions FAIL on a root with SOF withheld -- every one of them can go red"
else
    bad "PHASE R: only $RED_FAILS of $SOF_ASSERTIONS assertions failed with the SOF files withheld; the other $((SOF_ASSERTIONS-RED_FAILS)) cannot detect their absence and are worthless"
fi

echo
echo "sof: $PASS passed, $FAIL failed, $INFO informational"
echo "sof: NOT MEASURED -- that his card WORKS. No VM has a SOF DSP (QEMU's"
echo "sof: intel-hda has none) and this build host is a Cannon Lake part that"
echo "sof: never enters the SOF path. This gate proves the medium carries what"
echo "sof: his machine asks for; his next boot log proves whether that is all"
echo "sof: it was missing."
[ "$FAIL" -eq 0 ] || exit 1
