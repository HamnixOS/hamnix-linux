#!/usr/bin/env bash
# tests/linux/install_wizard_gui_negctl.sh — THE NEGATIVE CONTROL FOR
# tests/linux/install_wizard_gui.sh, AND IT IS RUN RATHER THAN DESCRIBED.
#
# WHAT IT IS FOR
# ==============
# install_wizard_gui.sh's two load-bearing assertions are both of the shape
# "the wizard did NOT do X":
#
#   * the disk page shows NO target disk and says so in its own red text;
#   * three more Returns do NOT move it past the disk page.
#
# A detector that always says "no disk" and a detector that always says "it did
# not advance" would pass both of those on a machine where the wizard worked
# perfectly. An empty result is not a finding until the instrument has been
# shown able to produce a non-empty one, so this arm MAKES THE WIZARD OFFER A
# DISK and requires the gate to go RED.
#
# HOW THE INVERSION IS MADE
# =========================
# `user/haminstallui.ad`'s `_enumerate_disks` is patched, IN A SCRATCH COPY OF
# THE FILE THAT IS RESTORED AFTERWARDS, to seed one fake 4 GiB disk called
# `nvme0n1` and select it, and to return before it ever touches /dev/blk. That
# is the smallest edit that inverts BOTH assertions at once:
#
#   n_disks = 1  -> the disk page renders a disk row instead of the
#                   "No installable target disk detected." message, so the
#                   SAW_TARGET / SAW_NODISK detector must flip;
#   sel_disk = 0 -> `_page_ready()` (haminstallui.ad:618) is satisfied, so
#                   Return on the disk page must now ADVANCE, and the
#                   "Next is refused" detector must flip too.
#
# NOTHING ELSE CHANGES: same image build, same rc, same two blank targets, same
# keyboard drive, same OCR, same thresholds. The only difference is seven lines
# in one function.
#
# THE EXPECTED RESULT IS FAILURE. This script inverts the verdict: it passes
# when install_wizard_gui.sh FAILS on the patched tree, and it fails if the
# gate comes back green — because a gate that is green on a wizard that offers
# a disk is a gate that cannot see a disk being offered.
#
# IT IS ALSO A SECOND MEASUREMENT IN ITS OWN RIGHT. On the patched tree the
# wizard has a target and a selection, so it reaches `_begin_install()` and
# spawns /bin/install — which is the tree's hlinstall. What that child then
# does to a disk the wizard invented is printed, not asserted, because the
# subject here is the instrument and not the installer.
#
# Usage: tests/linux/install_wizard_gui_negctl.sh
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

UI=user/haminstallui.ad
BACKUP="$(mktemp --tmpdir haminstallui.orig.XXXXXX.ad)"
WORK="${HAMLINUX_WIZGUI_NEG_WORK:-$HOME/.hamnix-build/install-wizard-gui-neg}"
mkdir -p "$WORK"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  PASS  %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$*"; }
say()  { printf '\n== %s\n' "$*"; }
info() { printf '  ..    %s\n' "$*"; }

cp "$UI" "$BACKUP"
restore() {
    cp "$BACKUP" "$UI"
    rm -f "$BACKUP"
    printf '  ..    %s restored from %s\n' "$UI" "$BACKUP"
}
trap restore EXIT

# TWO ARMS, AND THE FIRST RUN OF THIS FILE IS WHY THERE ARE TWO.
#
# The single inversion originally used here set BOTH `n_disks = 1` AND
# `sel_disk = 0`, on the reasoning that it would flip both of the gate's
# assertions at once. IT FLIPPED THE WRONG ONE AND SKIPPED THE OTHER: with the
# disk already selected, `_page_ready()` was satisfied the instant the wizard
# landed on the disk page, so the very next Return carried it straight through
# to `Review & install`. THE DRIVE NEVER CAPTURED A DISK-PAGE FRAME AT ALL, and
# the "did it offer a disk" detector -- the one this control exists to prove --
# was never run. The gate went red for the OTHER reason and the control
# reported that honestly rather than counting it.
#
#   arm SELECT   n_disks = 1, sel_disk = 0. The wizard has a target and picks
#                it, so it walks past the disk page and reaches the spawn. This
#                proves the NEXT-REFUSAL detector and the DID-INSTALL-RUN
#                detector can both report the opposite of what the real tree
#                gives.
#   arm OFFER    n_disks = 1 only. The wizard shows the disk row and waits for a
#                selection that never comes, so it PARKS on the disk page with a
#                disk listed. This is the one that proves the DISK-PAGE detector
#                can say "a disk was offered".
#
# Neither arm alone proves the gate; both together do, and each is run.
patch_ui() {  # patch_ui <select:0|1>
    cp "$BACKUP" "$UI"
    python3 - "$UI" "$1" <<'PY'
import sys
p, select = sys.argv[1], sys.argv[2] == "1"
src = open(p).read()
anchor = "def _enumerate_disks():\n    n_disks = 0\n    _read_rootdev()\n"
assert src.count(anchor) == 1, "the anchor _enumerate_disks() prologue is not there once"
body = """    # ---- NEGATIVE CONTROL ONLY (tests/linux/install_wizard_gui_negctl.sh)
    # One invented 4 GiB disk called nvme0n1 and a return before /dev/blk is
    # ever consulted. Restored by that script's EXIT trap.
    fp: Ptr[uint8] = disk_name_ptr(0)
    fp[0] = 110
    fp[1] = 118
    fp[2] = 109
    fp[3] = 101
    fp[4] = 48
    fp[5] = 110
    fp[6] = 49
    fp[7] = 0
    disk_namelen[0] = 7
    disk_sectors[0] = 8388608
    n_disks = 1
"""
if select:
    body += "    sel_disk = 0\n"
body += "    return\n"
open(p, "w").write(src.replace(anchor, anchor + body))
print("patched select=%s" % select)
PY
}

run_arm() {  # run_arm <name> <select:0|1> <work>
    local name="$1" select="$2" w="$3"
    mkdir -p "$w"
    say "arm $name -- patching _enumerate_disks (sel_disk set: $select)"
    patch_ui "$select" || { bad "$name: could not patch $UI"; return 1; }
    grep -q 'NEGATIVE CONTROL ONLY' "$UI" \
        && ok "$name: the inversion is really in $UI (a rebuild will compile it)" \
        || { bad "$name: the patch is not in the file -- this arm would silently re-run the positive case"; return 1; }
    info "$name: running install_wizard_gui.sh against the PATCHED tree; expected RED"
    HAMLINUX_WIZGUI_WORK="$w" tests/linux/install_wizard_gui.sh >"$w/RUN.log" 2>&1
    ARM_RC=$?
    info "$name: install_wizard_gui.sh exited $ARM_RC"
    grep -aE '^  (PASS|FAIL)|^  \.\.    d[0-9]|^== ' "$w/RUN.log" | tail -n 40
    if [ "$ARM_RC" != 0 ]; then
        ok "$name: install_wizard_gui.sh went RED on a wizard that offers a disk, as it must"
    else
        bad "$name: install_wizard_gui.sh PASSED on a wizard that offers a disk -- IT CANNOT SEE A DISK BEING OFFERED and its green run on the real tree means nothing"
    fi
}

# ---- arm OFFER: a disk is listed and nothing is selected -------------------
run_arm OFFER 0 "$WORK/offer"
if grep -q 'THE WIZARD OFFERED A TARGET DISK' "$WORK/offer/RUN.log"; then
    ok "OFFER: the disk-page detector SAW the invented disk and said so -- so 'No installable target disk detected' on the real tree is a reading, not a detector that always says no"
else
    bad "OFFER: the gate did not report 'THE WIZARD OFFERED A TARGET DISK' on a wizard that lists one -- THE DISK-PAGE DETECTOR IS BLIND and the real tree's green result means nothing"
    grep -aE 'OCR of the wizard window|Step 5|nvme' "$WORK/offer/RUN.log" | head -8
fi

# ---- arm SELECT: a disk is listed AND chosen ------------------------------
run_arm SELECT 1 "$WORK/select"
if grep -qE 'MOVED THE WIZARD PAST THE DISK PAGE' "$WORK/select/RUN.log"; then
    ok "SELECT: the Next-refusal detector flipped -- with sel_disk set, three Returns moved the wizard on, so 'Next is REFUSED' on the real tree is a reading"
else
    bad "SELECT: the Next-refusal detector did not flip on a wizard that can advance -- it cannot tell refused from advanced"
    grep -aE 'after 3 more Returns|Review' "$WORK/select/RUN.log" | head -5
fi
if grep -qE 'DID appear in the census' "$WORK/select/RUN.log"; then
    ok "SELECT: and the spawn detector flipped -- /bin/install DID appear in the census, so '/bin/install NEVER APPEARED' on the real tree is a reading and not a grep that never matches"
else
    bad "SELECT: /bin/install never appeared even on a wizard that reached _begin_install -- the spawn detector cannot see a spawn"
fi

say "what the patched wizard did once it had a target (printed, not asserted)"
grep -aE "console occurrences of|NVMe target|virtio-blk target" "$WORK/select/RUN.log" | head -12

printf '\n%d PASSED, %d FAILED\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
