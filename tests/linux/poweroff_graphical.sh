#!/usr/bin/env bash
#
# tests/linux/poweroff_graphical.sh — DOES `poweroff` ACTUALLY POWER OFF A
# MACHINE WHOSE COMPOSITOR IS PRESENTING?
#
# REGISTRATION. ON-DEMAND: not in ci_battery_manifest.txt because it builds a
# medium and boots QEMU three times, far past the battery's per-shard budget.
# Same class as tests/linux/installed_documents.sh, whose harness this borrows.
# It IS in scripts/release_gates.sh.
#
# WHAT THIS GATE ESTABLISHED, AND WHAT IT DID NOT -- READ THIS BEFORE THE REST
# ===========================================================================
# It ASSERTS that the shipped `poweroff` powers off a graphical machine with an
# office application presenting, and that `halt`, `reboot` and `poweroff` carry
# no console write before the /dev/reboot syscall.
#
# IT DID NOT REPRODUCE THE HANG. Twice, in two display configurations, the
# banner-restored control POWERED THE MACHINE OFF anyway (21 s and 18 s) with
# its banner on the serial line. The report the fix answers -- three graphical
# boots past a 300 s deadline, HANDOFF.md -- was taken on an INSTALLED machine
# after a full office-application drive, and this gate builds a LIVE medium.
# Nothing here refutes that report; this gate FAILED TO LOCATE it, which is a
# different statement and is printed as such at the end of every run.
#
# THE DEFECT
# ==========
# user/poweroff.ad wrote its banner --
#
#     sys_write(1, "poweroff: requested power off\n", 30)
#
# -- to fd 1 BEFORE it opened /dev/reboot. Once the compositor is presenting, a
# write to the console stops returning (measured by
# tests/linux/installed_documents.sh, which had to work around it with
# `poweroff > /dev/null`; three graphical boots in a row sat past a 300 s
# deadline). So the banner never returned, the /dev/reboot write was never
# reached, and THE MACHINE NEVER POWERED OFF. `halt` and `reboot` carried the
# identical shape and are fixed with it.
#
# The fix is to take the announcement off the path that leads to the syscall.
# It is not made "non-blocking": a program that is already inside write(2) on
# that device cannot be rescued from inside itself, and O_NONBLOCK is not a
# promise this program can make about /dev/console. The diagnostics that are
# left are on failure paths only -- reached exactly when the machine is NOT
# going down, where blocking costs nothing that was not already lost.
#
# WHAT IS MEASURED, AND WHAT IS A CONTROL
# =======================================
# One image build. TWO media, differing in one file (/etc/rc.boot) and both
# carrying BOTH binaries: the shipped /bin/poweroff, and /bin/poweroff.banner,
# which is this tree's poweroff.ad WITH THE BANNER LINE PUT BACK and nothing
# else changed. Three boots:
#
#   ARM A  fixed binary, GRAPHICAL: -vga std, the compositor presenting AND an
#          office application (hamwrite) open on top of it. The machine must
#          POWER ITSELF OFF -- QEMU must exit on its own, well inside the
#          deadline.
#
#          THE APPLICATION AND THE -vga std ARE BOTH THERE BECAUSE THE FIRST
#          VERSION OF THIS GATE DID NOT REPRODUCE THE DEFECT. Measured, 1.0.32
#          run: with `-vga none -device virtio-gpu-pci` and nothing but the
#          desktop chrome up, the BANNER ARM POWERED OFF IN 21 s AND ITS BANNER
#          REACHED THE SERIAL LINE -- on a frame the reader scored 1538 colours
#          / 4 % dominant, i.e. a presenting desktop. So "the compositor is
#          presenting" is NOT sufficient for the console to stop returning. The
#          machine the hang was actually seen on
#          (tests/linux/installed_documents.sh) runs -vga std and has an office
#          application open; this arm now matches that, and if the control
#          still does not fire the difference is somewhere else again and this
#          gate says so rather than passing.
#   ARM B  banner binary, GRAPHICAL. THE REPRODUCTION ATTEMPT, AND IT IS RUN.
#          The same medium build, the same desktop, the same application,
#          differing only in which poweroff binary the rc calls.
#
#          IT IS SCORED AS "an answer was obtained", NOT AS "it hung", AND THE
#          REASON IS A MEASUREMENT. Run twice on 2026-08-19 -- once with
#          virtio-gpu and a bare desktop, once with -vga std and hamwrite open
#          -- THE BANNER ARM POWERED OFF BOTH TIMES, in 21 s and 18 s, with its
#          banner on the serial line. So on the live medium the console write
#          returns and the banner is not what stops a power-off. Scoring "it
#          hung" as the only pass would make this gate permanently red about a
#          machine it cannot build; scoring "it powered off" as a pass would let
#          a real hang go by. What is refused is SILENCE: an arm that produces
#          neither reading fails.
#
#          WHAT THAT LEAVES ARM A AS: a regression guard on the shipped
#          poweroff, on a graphical machine with an application open. It does
#          NOT establish that the banner was the cause of the report in
#          HANDOFF.md, and this gate prints that in capitals rather than
#          letting a green be read as a confirmation.
#   ARM C  banner binary, NO GPU AT ALL -- so wsysd finds no DRM device and
#          nothing ever presents. THE BINARY CONTROL. The banner binary must
#          power this machine off AND must put `poweroff: requested power off`
#          on the serial line. Without arm C, "the reverted binary hung" is
#          indistinguishable from "the reverted binary is broken", and the
#          gate would be measuring a build error rather than a defect.
#
# THE COMPOSITOR IS NOT ASSUMED, IT IS PHOTOGRAPHED. Arms A and B take a
# screendump off the QEMU monitor a few seconds before the poweroff fires, and
# the picture must be a presenting desktop and not a text console or a blank
# frame. Without that, "arm A powered off" would be the trivially true thing a
# non-graphical machine does, and the gate would assert nothing.
#
# THE SCREEN READER IS ITSELF CONTROLLED, because a reader that answers the
# same way to everything measures nothing: it is run against a synthetic BLANK
# frame of the same geometry and must call that one blank.
#
# WHY THE rc DOES NOT ECHO AFTER THE DESKTOP IS UP: it cannot. The console
# write the rc would use is the very write that blocks, so an echo there would
# hang the rc in BOTH arms and neither would ever reach poweroff. The marker is
# printed BEFORE the sleep, the wait is a fixed sleep in the guest, and the
# host's evidence after that point is the framebuffer and whether QEMU is
# still alive -- not the serial line.
#
# THE APPLICATION IS LAUNCHED AND ITS ARRIVAL IS ASSERTED, from the one line it
# prints before the console goes anywhere: `[hamwrite] scene window ready`. An
# arm where the application never came up is not the configuration the hang was
# seen in, and a poweroff that works there would say nothing about one that
# does not work here.
#
# Usage: tests/linux/poweroff_graphical.sh
#   POWEROFFG_WORK=<dir>     work dir (default ~/.hamnix-build/poweroffg)
#   POWEROFFG_REUSE=1        reuse an already-built image + media
#   POWEROFFG_SETTLE=<secs>  guest sleep before poweroff (default 90)
#   POWEROFFG_DEADLINE=<s>   host wait for QEMU to exit (default 300)
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

. tests/linux/reap.sh
reap_on_exit

W="${POWEROFFG_WORK:-$HOME/.hamnix-build/poweroffg}"
mkdir -p "$W"
export TMPDIR="$W/tmp"; mkdir -p "$TMPDIR"

SETTLE="${POWEROFFG_SETTLE:-90}"
DEADLINE="${POWEROFFG_DEADLINE:-300}"
MARK=POWEROFFG-RC-REACHED

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  PASS  $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $*"; }
info() { echo "        $*"; }
say()  { echo; echo "== $* =="; }
finish() { printf '\n%d PASSED, %d FAILED\n' "$PASS" "$FAIL"
           [ "$FAIL" = 0 ] && exit 0 || exit 1; }

for t in qemu-system-x86_64 socat python3; do
    command -v "$t" >/dev/null || { echo "INCONCLUSIVE: need $t"; exit 2; }
done
[ -f /usr/share/OVMF/OVMF_CODE_4M.fd ] || { echo "INCONCLUSIVE: need OVMF"; exit 2; }

# =========================================================================
# 0. THE TWO BINARIES
# =========================================================================
say "0 -- the shipped poweroff, and the same program with the banner put back"

# THE REVERTED SOURCE IS DERIVED FROM THE SHIPPED ONE, NOT KEPT AS A COPY.
# A checked-in copy would drift: it would go on measuring the poweroff.ad of
# the day it was written. This takes THIS tree's file and re-inserts exactly
# the one line the fix removed -- the first statement of main, a write of the
# banner to fd 1 -- so the negative control is always one line away from the
# shipped program and can never be anything else.
REV="$W/poweroff_banner.ad"
python3 - "$PWD/user/poweroff.ad" "$REV" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src).read().split("\n")
out, done = [], False
for ln in lines:
    out.append(ln)
    if not done and ln.startswith("def main("):
        out.append('    sys_write(1, "poweroff: requested power off\\n", 30)')
        done = True
if not done:
    sys.exit("poweroff.ad has no `def main(` -- the negative control cannot be built")
open(dst, "w").write("\n".join(out))
PY
if [ -s "$REV" ] && grep -q 'requested power off' "$REV"; then
    ok "the negative-control source was derived from user/poweroff.ad with the banner line re-inserted"
else
    bad "could not derive the negative-control source"; finish
fi
# It must differ from the shipped file in EXACTLY that one added line. A
# control that differs in more than the thing under test does not isolate it.
DIFFLINES=$(diff user/poweroff.ad "$REV" | grep -c '^[<>]')
if [ "$DIFFLINES" = 1 ]; then
    ok "the control differs from the shipped source in exactly ONE line (the banner)"
else
    bad "the control differs from the shipped source in $DIFFLINES lines, not 1 -- it does not isolate the banner"
fi
# And the shipped one must NOT have it. If this fails the fix is not in the
# tree and every arm below is measuring the wrong thing.
if grep -q 'sys_write(1,' user/poweroff.ad; then
    bad "user/poweroff.ad STILL writes to fd 1 -- the fix is not in this tree"
else
    ok "user/poweroff.ad writes nothing to fd 1 (the fix is in this tree)"
fi
for p in halt reboot; do
    if grep -q 'sys_write(1,' "user/$p.ad"; then
        bad "user/$p.ad still writes to fd 1 before /dev/reboot -- it carries the same defect"
    else
        ok "user/$p.ad writes nothing to fd 1 either"
    fi
done

# =========================================================================
# 1. THE IMAGE, THE CONTROL BINARY, AND THE TWO MEDIA
# =========================================================================
say "1 -- the image, the control binary and the two media"

BANNER_ELF="$W/poweroff.banner.elf"
if [ "${POWEROFFG_REUSE:-0}" = 1 ] && [ -s "$W/medium-fixed.img" ] && [ -s "$W/medium-banner.img" ]; then
    info "reusing $W/medium-{fixed,banner}.img (POWEROFFG_REUSE=1)"
else
    info "building build/image/root (the slow part)"
    scripts/hamlinux_image.sh >"$W/image.log" 2>&1 || {
        bad "image build -- see $W/image.log"; tail -20 "$W/image.log"; finish; }
    ok "the image built"

    info "compiling the negative-control binary"
    scripts/hamlinux_build.sh "$REV" "$BANNER_ELF" >"$W/banner_build.log" 2>&1 || {
        bad "the negative-control binary did not build -- see $W/banner_build.log"
        tail -20 "$W/banner_build.log"; finish; }
    [ -s "$BANNER_ELF" ] || { bad "no $BANNER_ELF"; finish; }
    ok "the negative-control binary built ($(stat -c%s "$BANNER_ELF") bytes)"

    EXTRA="$W/extra"; rm -rf "$EXTRA"; mkdir -p "$EXTRA/bin"
    install -m755 "$BANNER_ELF" "$EXTRA/bin/poweroff.banner"

    # The two rcs. `source '/etc/rc.boot.installed'` is the shipped boot,
    # verbatim, so the desktop that comes up is the one that ships.
    for arm in fixed banner; do
        case "$arm" in
            fixed)  BIN=poweroff ;;
            banner) BIN=poweroff.banner ;;
        esac
        cat >"$W/rc.$arm" <<RCEOF
source '/etc/rc.boot.installed'
echo '$MARK $arm'
${arm}ns = ns {
}
${arm}svc = spawn detached ${arm}ns {
    sleep 25
    /bin/hamwrite
}
sleep $SETTLE
/bin/$BIN
RCEOF
        HAMLINUX_DISK_RC="$W/rc.$arm" HAMLINUX_DISK_EXTRA="$EXTRA" \
            scripts/hamlinux_disk.sh "$W/medium-$arm.img" 3G \
            >"$W/disk.$arm.log" 2>&1 || {
            bad "medium build ($arm) -- see $W/disk.$arm.log"
            tail -20 "$W/disk.$arm.log"; finish; }
        ok "the $arm medium built"
    done
fi
[ -s "$W/medium-fixed.img" ]  || { bad "no fixed medium";  finish; }
[ -s "$W/medium-banner.img" ] || { bad "no banner medium"; finish; }

# =========================================================================
# THE SCREEN READER, AND ITS OWN CONTROL
# =========================================================================
# "Is a desktop presenting?" is answered from the framebuffer with two
# numbers taken off the PPM: how many DISTINCT colours it holds, and what
# fraction of it is the single most common colour. A blank frame and a text
# console are both a handful of colours over an almost entirely uniform
# field; a composited desktop with a wallpaper, a panel and window chrome is
# not. The thresholds are deliberately far from both.
screen_read() {   # screen_read <ppm> -> "<colours> <dominant-fraction-pct>"
    python3 - "$1" <<'PY'
import sys, collections
d = open(sys.argv[1], 'rb').read()
# P6 header: magic, w, h, maxval -- whitespace separated, '#' comments.
tok, i = [], 2
while len(tok) < 3:
    while i < len(d) and d[i:i+1].isspace(): i += 1
    if d[i:i+1] == b'#':
        while i < len(d) and d[i:i+1] != b'\n': i += 1
        continue
    j = i
    while j < len(d) and not d[j:j+1].isspace(): j += 1
    tok.append(int(d[i:j])); i = j
i += 1
w, h = tok[0], tok[1]
px = d[i:i + w*h*3]
c = collections.Counter(px[k:k+3] for k in range(0, len(px) - 2, 3))
n = sum(c.values()) or 1
print(len(c), int(100 * c.most_common(1)[0][1] / n))
PY
}
presenting() {    # presenting <colours> <dominant-pct> -> 0 if a desktop
    [ "${1:-0}" -ge 200 ] && [ "${2:-100}" -le 90 ]
}

say "the screen reader's own control"
python3 - "$W/blank.ppm" <<'PY'
import sys
w, h = 1024, 768
open(sys.argv[1], 'wb').write(b'P6\n%d %d\n255\n' % (w, h) + b'\x00' * (w*h*3))
PY
BR=$(screen_read "$W/blank.ppm")
info "a synthetic all-black 1024x768 frame reads: $BR (colours, dominant %)"
if presenting $BR; then
    bad "the screen reader calls an ALL-BLACK frame a presenting desktop -- it answers the same way to everything and measures nothing"
else
    ok "the screen reader calls an all-black frame NOT-presenting ($BR)"
fi

# =========================================================================
# THE ARMS
# =========================================================================
# run_arm <name> <medium> <gpu:1|0> -- boots, screendumps if it has a GPU,
# and waits for the machine to go away. Sets:
#   ARM_EXITED   1 if QEMU exited on its own inside the deadline
#   ARM_SECS     how long that took
#   ARM_SHOT     the screendump path ("" if no GPU)
#   ARM_READ     the screen reader's answer ("" if no GPU)
#   ARM_LOG      the serial log
ARM_EXITED=0; ARM_SECS=0; ARM_SHOT=""; ARM_READ=""; ARM_LOG=""
run_arm() {
    local name="$1" medium="$2" gpu="$3"
    local D="$W/$name"
    rm -rf "$D"; mkdir -p "$D"
    cp "$medium" "$D/medium.img"
    cp /usr/share/OVMF/OVMF_VARS_4M.fd "$D/OVMF_VARS.fd"
    ARM_EXITED=0; ARM_SECS=0; ARM_SHOT=""; ARM_READ=""; ARM_LOG="$D/serial.log"

    local -a gpuargs=()
    if [ "$gpu" = 1 ]; then
        # -vga std, WHICH IS NOT A DETAIL. The first version of this gate used
        # `-vga none -device virtio-gpu-pci` and its negative control DID NOT
        # FIRE: with the banner restored the machine powered off in 21 s and the
        # banner reached the serial line, on a frame the reader scored 1538
        # colours / 4 % dominant -- a presenting desktop by any measure.
        # MEASURED, 1.0.32 run, and it is the reason this line says which device
        # it wants: the machine the hang was seen on
        # (tests/linux/installed_documents.sh) runs -vga std, and the console
        # behind bochs-drm is not the console behind virtio-gpu.
        gpuargs=(-vga std)
    else
        # NO DISPLAY DEVICE AT ALL. wsysd finds no DRM device, nothing is ever
        # scanned out, and the console is never taken -- which is the whole
        # point of this arm.
        gpuargs=(-vga none)
    fi

    qemu-system-x86_64 -m 2048 -smp 2 -no-reboot \
        -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
        -drive "if=pflash,format=raw,unit=1,file=$D/OVMF_VARS.fd" \
        -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
        -display none "${gpuargs[@]}" \
        -serial "file:$D/serial.log" -enable-kvm -cpu host \
        -monitor "unix:$D/mon.sock,server,nowait" \
        -device qemu-xhci,id=xhci -device usb-kbd -device usb-tablet \
        -drive "file=$D/medium.img,if=none,format=raw,id=usbstick" \
        -device usb-storage,bus=xhci.0,drive=usbstick,bootindex=0 \
        >"$D/qemu.out" 2>&1 &
    local VM=$!
    reap_add "$VM"

    # Wait for the rc's marker. It is printed BEFORE the settle sleep, i.e.
    # while the console still answers, so this is a wait that can succeed.
    local w=0
    while kill -0 "$VM" 2>/dev/null && [ "$w" -lt 240 ]; do
        grep -aq "$MARK" "$D/serial.log" 2>/dev/null && break
        sleep 2; w=$((w+2))
    done
    if grep -aq "$MARK" "$D/serial.log" 2>/dev/null; then
        ok "$name: the guest reached its rc (${w}s)"
    else
        bad "$name: the guest never reached its rc -- nothing below this line is about poweroff"
        kill -KILL "$VM" 2>/dev/null; wait "$VM" 2>/dev/null
        return 1
    fi

    # The picture, taken while the machine is still up and a good margin
    # before the poweroff fires.
    if [ "$gpu" = 1 ]; then
        local dwell=5
        [ "$SETTLE" -gt 30 ] && dwell=$((SETTLE - 20))
        sleep "$dwell"
        # The application is launched by the rc 25 s in, so this is read AFTER
        # the dwell and not before it.
        if grep -aq '\[hamwrite\] scene window ready' "$D/serial.log" 2>/dev/null; then
            ok "$name: an office application opened its window on top of the desktop"
        else
            # Not fatal on its own -- the screendump below still says what is on
            # the screen -- but it changes what the arm IS, so it is scored.
            bad "$name: no application ever printed '[hamwrite] scene window ready', so this arm is a bare desktop and not the configuration the hang was seen in"
        fi
        ARM_SHOT="$D/screen.ppm"
        printf 'screendump %s\n' "$ARM_SHOT" \
            | timeout 30 socat - "UNIX-CONNECT:$D/mon.sock" >/dev/null 2>&1
        local i=0
        while [ "$i" -lt 40 ] && [ ! -s "$ARM_SHOT" ]; do sleep 0.5; i=$((i+1)); done
        if [ -s "$ARM_SHOT" ]; then
            ARM_READ="$(screen_read "$ARM_SHOT")"
        fi
    fi

    local t=0
    while kill -0 "$VM" 2>/dev/null && [ "$t" -lt "$DEADLINE" ]; do
        sleep 3; t=$((t+3))
    done
    if kill -0 "$VM" 2>/dev/null; then
        ARM_EXITED=0; ARM_SECS=$t
        kill -TERM "$VM" 2>/dev/null; sleep 2; kill -KILL "$VM" 2>/dev/null
    else
        ARM_EXITED=1; ARM_SECS=$t
    fi
    wait "$VM" 2>/dev/null
    return 0
}

# ---- ARM A ---------------------------------------------------------------
say "ARM A -- the SHIPPED poweroff on a machine whose compositor is presenting"
A_EXITED=x; A_SECS=0
if run_arm A_fixed_graphical "$W/medium-fixed.img" 1; then
    if [ -n "$ARM_READ" ]; then
        info "A: the framebuffer reads $ARM_READ (colours, dominant %)"
        if presenting $ARM_READ; then
            ok "A: the compositor WAS presenting when poweroff was called ($ARM_READ) -- so this arm is about a graphical machine"
        else
            bad "A: the framebuffer is not a presenting desktop ($ARM_READ) -- this arm did not test the case the defect is in"
        fi
    else
        bad "A: no screendump could be taken -- nothing about this machine's picture was measured"
    fi
    if [ "$ARM_EXITED" = 1 ]; then
        ok "A: THE MACHINE POWERED ITSELF OFF (QEMU exited on its own after ${ARM_SECS}s, deadline ${DEADLINE}s)"
    else
        bad "A: the machine was STILL RUNNING at the ${DEADLINE}s deadline -- the shipped poweroff does not power off a graphical machine"
    fi
    # The banner is gone from the shipped program, so it must not be on the
    # wire. Its presence would mean the fix did not reach the medium.
    if grep -aq 'poweroff: requested power off' "$ARM_LOG"; then
        bad "A: the serial line carries 'poweroff: requested power off' -- the medium is carrying an UNFIXED poweroff"
    else
        ok "A: the shipped poweroff printed no banner (the line the fix removed is not on the wire)"
    fi
    A_EXITED="$ARM_EXITED"; A_SECS="$ARM_SECS"
fi

# ---- ARM B ---------------------------------------------------------------
say "ARM B -- THE NEGATIVE CONTROL: the same desktop, the banner put back"
B_EXITED=x
if run_arm B_banner_graphical "$W/medium-banner.img" 1; then
    if [ -n "$ARM_READ" ]; then
        info "B: the framebuffer reads $ARM_READ (colours, dominant %)"
        if presenting $ARM_READ; then
            ok "B: the compositor WAS presenting here too ($ARM_READ) -- the two arms differ in the binary, not in the machine"
        else
            bad "B: the framebuffer is not a presenting desktop ($ARM_READ) -- this arm is not comparable to A"
        fi
    else
        bad "B: no screendump could be taken"
    fi
    # THE OUTCOME OF THIS ARM IS THE FINDING, EITHER WAY, AND NEITHER WAY IS A
    # PRODUCT FAILURE -- so it is scored as "the reproduction attempt returned an
    # answer", and WHICH answer is printed in capitals. Scoring "it hung" as the
    # only pass would make this gate red forever on a machine where the defect
    # does not occur, and scoring "it powered off" as a pass would let a real
    # hang go unnoticed. What must never happen is silence, so a run that
    # produces neither reading is the failure.
    if [ "$ARM_EXITED" = 0 ]; then
        REPRODUCED=1
        ok "B: REPRODUCED -- the machine was STILL RUNNING at the ${DEADLINE}s deadline with the banner restored, so the banner before the syscall IS what hangs it"
    elif [ "$ARM_EXITED" = 1 ]; then
        REPRODUCED=0
        ok "B: NOT REPRODUCED -- the machine powered off after ${ARM_SECS}s WITH THE BANNER RESTORED. In THIS configuration the console write returns and the banner is not what stops a power-off"
    else
        bad "B: the arm produced no reading at all -- neither an exit nor a deadline"
    fi
    if grep -aq 'poweroff: requested power off' "$ARM_LOG"; then
        info "B: and the banner REACHED the serial line, so that write returned"
    else
        info "B: and the banner never reached the serial line -- that write did not return"
    fi
    # Reported, not scored: the kernel's own hung-task dump names what the
    # process is stuck in. `hung_task_timeout_secs=30` is on the shipped
    # command line (scripts/hamlinux_disk.sh), so it costs nothing to look.
    if grep -aq 'blocked for more than' "$ARM_LOG"; then
        info "B: the kernel printed a hung-task report:"
        grep -a -A6 'blocked for more than' "$ARM_LOG" | head -30 | sed 's/^/        | /'
    else
        info "B: the kernel printed no hung-task report on the serial line"
    fi
    B_EXITED="$ARM_EXITED"
fi

# ---- ARM C ---------------------------------------------------------------
say "ARM C -- THE BINARY CONTROL: the banner binary on a machine with NO GPU"
if run_arm C_banner_nogpu "$W/medium-banner.img" 0; then
    if [ "$ARM_EXITED" = 1 ]; then
        ok "C: the banner binary POWERED OFF a machine with nothing presenting (${ARM_SECS}s) -- so the binary works and ARM B measured the compositor, not a broken build"
    else
        bad "C: the banner binary did NOT power off a machine with no GPU either -- it is simply broken, and ARM B's red says nothing about the console"
    fi
    if grep -aq 'poweroff: requested power off' "$ARM_LOG"; then
        ok "C: and it printed 'poweroff: requested power off' on the serial line -- the write RETURNS on a machine with nothing presenting"
    else
        bad "C: the banner binary printed no banner even here -- the control binary is not the program it is supposed to be"
    fi
fi

say "the two graphical arms, side by side"
info "A (shipped poweroff, application presenting): exited=$A_EXITED after ${A_SECS}s"
info "B (banner restored, same desktop):            exited=$B_EXITED"
if [ "${REPRODUCED:-x}" = 1 ]; then
    echo
    echo "  ==> THE HANG REPRODUCED. The one line the control adds is the"
    echo "      difference between a machine that powers off and one that does"
    echo "      not, and user/poweroff.ad's header is right."
elif [ "${REPRODUCED:-x}" = 0 ]; then
    echo
    echo "  ==> THE HANG DID NOT REPRODUCE HERE, AND THAT IS THIS GATE'S RESULT."
    echo "      Both binaries powered a presenting graphical machine off. So"
    echo "      ARM A IS A REGRESSION GUARD FOR THE SHIPPED poweroff AND NOTHING"
    echo "      MORE: it does not establish that the banner was ever the cause."
    echo "      The report it comes from (HANDOFF.md: three boots past a 300 s"
    echo "      deadline) was taken on an INSTALLED machine driven through a"
    echo "      full office-application session, which is not what these arms"
    echo "      build, and nothing here refutes it -- this gate has failed to"
    echo "      LOCATE it, which is a different statement."
fi

finish
