#!/usr/bin/env bash
# tests/linux/soak_desktop.sh — DOES THE DESKTOP WEDGE WHEN SOMEBODY IS USING
# IT? A SOAK THAT IS A WORKLOAD, NOT A WAIT.
#
# THE REPORT THIS GATE EXISTS FOR
# ===============================
# The owner booted his Lenovo to the graphical desktop from a physical USB
# stick, USED IT, and after about five minutes the whole system hung. Magic
# sysrq still answered, so THE KERNEL WAS ALIVE AND USERSPACE WAS WEDGED. He
# has no serial cable and no shell; there is no log from that boot.
#
# WHY THIS FILE EXISTS BESIDE tests/linux/wedge_hunt.sh
# =====================================================
# wedge_hunt.sh ran six minutes per arm and found two standing write loads on
# the boot medium, both since fixed. IT MEASURED AN IDLE MACHINE. Its own
# closing paragraph says so, and flags the gap against itself: "Nothing repeats
# at rest today (top repeat is 2), BUT THAT WAS MEASURED IDLE AND HE WAS
# OPENING APPLICATIONS."
#
# Two of that gate's own ranked-and-unfixed candidates only bite under
# ACTIVITY, and neither can be reached by a machine sitting still:
#
#   * THE DESKTOP LOGS TO UNBOUNDED FILES ON THE BOOT MEDIUM. etc/rc.d/rc.5.linux
#     lines 34, 42 and 45 redirect wsysd, hamdesktop and hampanelscene into
#     /var/log/*.log, and scripts/hamlinux_disk.sh:70 puts var/log on the ext4
#     ROOT PARTITION OF THE MEDIUM -- so those three files are writes to the
#     stick, not to RAM. wsysd's diagnostics are `puts(2, ...)` from inside the
#     16 ms frame loop, i.e. a BLOCKING write(2) between one frame and the next.
#     If any diagnostic starts repeating per frame, wsysd stalls -- and then
#     every client pays srv_call_on's five-second timeout PER REQUEST
#     (user/linux-wsys.c:5081-5085), which is a desktop that looks completely
#     frozen over a perfectly healthy kernel. That is the prime suspect for an
#     ACTIVITY-triggered wedge and it is what this file is built to provoke.
#
#     AND THERE IS EXACTLY ONE SUCH DIAGNOSTIC, FOUND BY READING FOR IT RATHER
#     THAN BY WAITING FOR IT. user/wsysd.ad:2292, inside present_rows(), which
#     runs on EVERY presented frame:
#
#         fd: int32 = sys_open_write(cast[Ptr[char]]("/dev/fb"))
#         if fd < 0:
#             puts(2, "wsysd: cannot open /dev/fb for writing\n")
#             return
#
#     THERE IS NO GUARD ON IT. Every other diagnostic in this compositor has
#     one: report_uncovered dedups per wid into a 64-slot table that FAILS
#     CLOSED when full, report_image_misses into a 16-slot one, and -- twenty
#     lines below this very line -- fb_flip() carries `fbctl_tried` precisely so
#     it does not retry a failed open every frame. present_rows() got the retry
#     without the flag.
#
#     THE ARITHMETIC, AND IT IS ARITHMETIC AND NOT A MEASUREMENT: 38 bytes at
#     60 Hz is 2.3 KB/s and SIXTY BLOCKING write(2) CALLS A SECOND into a file
#     on the boot medium. At this gate's default throttle -- 60 write iops --
#     that is the device's ENTIRE write budget, consumed every second, for ever,
#     by an error message. Everything else userspace wants from the medium
#     queues behind it, and every wsys client then pays srv_call_on's 5 s
#     timeout per request. That is "kernel alive, userspace wedged" arrived at
#     without a single hardware fault.
#
#     WHAT IS NOT ESTABLISHED, and it is the load-bearing half: whether that
#     open can begin failing mid-session on his Lenovo. It cannot be reached
#     from this gate -- wsysd refuses to start at all without a readable
#     /dev/fb, so the failure needs a device that works at startup and stops
#     later (DRM master taken, an fbdev that goes away on a mode change), which
#     a QEMU -vga std guest does not do. SO THIS IS A MECHANISM WITH A LINE
#     NUMBER AND NO PROOF THAT IT FIRED, and it is written down as that.
#
#     IT IS NOT A HYPOTHETICAL SHAPE. user/wsyswl.ad:796 records the same
#     mechanism already happening, measured, twice: "WSYSWL_VERBOSE=1 prints a
#     line per commit into /var/log ... and the guest went silent inside two
#     minutes of Steam starting, twice." A per-event line into /var/log has
#     silenced a hamnix guest before. That is why the log SIZES are sampled
#     over time here and reported as a rate.
#
#   * OPENING APPLICATIONS ADDS CONNECTIONS toward the 64-per-socket ceiling.
#     wedge_hunt ruled that out BY READING THE CODE -- it fails closed and
#     re-arms. Reading is not running. A soak that really opens and closes
#     windows for hours is how that reasoning gets tested.
#
#     RUN, AND THE ANSWER IS STRONGER THAN "IT FAILS CLOSED": ON THE SHIPPED
#     CONFIGURATION THE CEILING IS NOT ON THE PATH AT ALL. Every one of those
#     connections is made by srv_dial, and NOTHING BELOW IT RUNS UNLESS
#     HAMWSYS_SERVER=1 IS IN THE ENVIRONMENT (user/linux-wsys.c:3435-3449).
#     That variable is set by GATES. It is set nowhere in etc/, nowhere in
#     scripts/hamlinux_image.sh, nowhere in scripts/hamlinux_disk.sh and
#     nowhere in lib/ -- the only mentions in the shipped sources are wsysd's
#     own four comments saying the mediator is INERT without it. So the
#     desktop the owner booted makes no connections to that 64-slot table, and
#     WSRV_CONN_MAX cannot be what stopped his machine.
#
#     AND THE RUN AGREES WITH THE READ, which is why both are here. With the
#     close sweep disabled, 1800 s of launching applications and never closing
#     them carried wsysd's window count PAST 160 -- two and a half times the
#     connection ceiling -- with ZERO occurrences of "the connection limit is
#     reached", no wedge, and /var/log/wsysd.log unchanged at 640 bytes
#     throughout. Two independent lines of evidence, one static and one
#     measured, and neither is the other's paraphrase.
#
# WHAT IT ACTUALLY FOUND: REDIRECTION DIES, SYSTEM-WIDE, WITH NO DIAGNOSTIC
# =========================================================================
# THE MACHINE DID NOT WEDGE. What it did instead, on the run this section was
# written from -- 1800 s, driven, 60 write iops, applications launched and
# never closed -- is stop being able to redirect. AT 16 MINUTES 48 SECONDS
# AFTER BOOT, with 108 windows open and 118 launch cycles done, the heartbeat's
# `ls /etc > /dev/null` STARTED PRINTING /etc TO THE CONSOLE. Nothing said
# anything. The gate passed 14/0 and the leak was found by reading the "what
# repeated on the console" list and not recognising the strings in it.
#
# IT REPRODUCED WITH THE KEYBOARD OFF, which is what makes it a finding rather
# than a story about my own instrument. The hand's typing can reach PID 1's
# console prompt (see the TYPE switch below), so the whole thing was re-run with
# HAMLINUX_SOAK_TYPE=0 and nothing else changed:
#
#                         keyboard ON      keyboard OFF
#     first failure       16m 48s          16m 46s
#     launch cycles            118              119
#     windows open             108              111
#
# Two minutes apart in a thirty-minute run, one cycle apart in a hundred and
# nineteen. The no-typing log has zero `hamsh$` prompts and zero
# `command not found`.
#
# AND IT IS THE EXTERNAL REDIRECT PATH ONLY. The heartbeat runs two redirects to
# /dev/null one line apart -- `ls /etc > /dev/null` and the canary. `ls` is an
# EXTERNAL program and leaked 1,272 lines; the canary was a hamsh BUILTIN and
# never fired once. hamsh has two implementations: `_wire_redirects`
# (user/hamsh.ad:11244) spawns, calls sys_openchan, and binds at the child's
# /fd/N -- and skips the bind on a fail-closed -1; `_wire_redirects_self`
# (:11401) rebinds the CALLING task's integer fds and restores them afterwards.
# ONLY THE FIRST BROKE. That is a sharper localisation than the canary would
# have given if it had worked, and the canary is `/bin/echo` now so a future run
# is pointed at the half that fails.
#
# THE RESOURCE IS `MAX_SLOTS 64` AT user/linux-fdns.c:101, and it is a
# PROCESS-SHARED table (`shm->slot`), not a per-shell one. `sys_openchan` --
# which is every `>`, every `<`, every `2>`, and every pipe -- allocates from
# it. slot_alloc() runs the collector once and then returns -1, and its own
# comment says what that means: "an ENOSPC here is a shell that can no longer
# pipe or redirect at all."
#
# WHAT PINS A SLOT IS A LIVE PROCESS. slot_gc() will not reclaim a slot that
# `slot_referenced()` finds in the bind table, and bind_gc() only releases
# binds whose pid is DEAD. So a slot held by an application that is still
# running is held for as long as that application runs. A desktop that opens
# programs and leaves them open walks into a 64-entry table on a clock.
#
# AND THE FAILURE IS SILENT BY CONSTRUCTION, which is the part that makes it
# dangerous rather than merely finite. hamsh's _wire_redirects (user/hamsh.ad:
# 11244) reads:
#
#       fslot: int32 = sys_openchan(..., OPENCHAN_TRUNC)
#       if fslot >= 0:
#           sys_fdbind(pid, 1, _redir_kind(fslot, DEVFD_FILE), fslot)
#
# A fail-closed -1 skips the bind and says NOTHING. user/linux-syscalls.c:3118
# already names this exact shape -- "THIS IS WHY EVERY REDIRECT SILENTLY DID
# NOTHING ... `ls > file` ran, exited 0, created nothing and printed to the
# console" -- and records that the DE session's `wsysd > /var/log/wsysd.log`
# was how it was noticed last time. That is the same redirect rc.5.linux still
# uses for all three desktop programs.
#
# THE NUMBER IS 64, AND CANDIDATE 2 WAS RIGHT ABOUT THE NUMBER AND WRONG ABOUT
# THE TABLE. The brief expected "opening applications adds connections toward
# the 64-per-socket ceiling". WSRV_CONN_MAX is not reachable on this
# configuration at all (see below). The 64 that a desktop actually walks into
# by opening applications is this one.
#
# AND IT IS NOT THE HARNESS TYPING, WHICH HAD TO BE RULED OUT BEFORE ANY OF THE
# ABOVE COULD BE BELIEVED. The hand's keystrokes can reach PID 1's console
# prompt as well as wsysd (see the TYPE switch in drive_desktop), and in a later
# run they derailed the rc outright. So the run this section is written from was
# checked for that first:
#
#     hamsh$ prompts in its serial log:      0
#     `command not found` lines:             0
#
# The console shell was NEVER interactive in that run, so nothing typed reached
# it. And the leak's own shape says the same thing more directly: the heartbeat
# kept its one-a-second rhythm THROUGH the failure, with the /etc listing
# interleaved between consecutive timestamps --
#
#     SOAKHB / 2026-08-17 03:31:54 UTC / de-ns-run / group / ... /
#     SOAKHB / 2026-08-17 03:31:55 UTC / de-ns-run / group / ...
#
# -- which is the rc's OWN loop still running and its OWN `ls /etc > /dev/null`
# no longer redirecting. A shell derailed to a prompt does not keep printing the
# script's heartbeat.
#
# WHAT IS MEASURED AND WHAT IS NOT. MEASURED: the failure, its time, the window
# count and cycle count at that moment, and that the machine kept running
# afterwards. NOT MEASURED: that the slot table was the resource that ran out
# at that instant -- that is read off the code, and the 64-slot table pinned by
# live processes is the only bounded thing on that path. NOT OBSERVED AT ALL:
# any wedge from it.
#
# A PREDICTION, WRITTEN DOWN BEFORE THE RUN THAT TESTS IT, so it cannot be
# rationalised afterwards. The 3-hour arm of this gate runs with the close sweep
# ON, so its WINDOW count stays flat. If the resource were windows, that arm
# would keep redirecting for the whole three hours.
#
# IT WILL NOT, AND HERE IS WHY IN ADVANCE: `close <wid>` on /dev/wsys/ctl
# (user/linux-wsys.c:8999) sets `v->used = 0`, unbinds the keychan and releases
# the pixmap and backbuffer -- AND DOES NOT TOUCH THE PROCESS. The application
# is still running with its window gone. It is the LIVE PROCESS that pins the
# fdns slot, not the window. So the churn arm should lose redirection at
# ROUGHLY THE SAME LAUNCH COUNT as the arm that closed nothing -- about 118
# cycles, near seventeen minutes at this cadence -- with its window count flat
# the whole way.
#
# IF IT KEEPS REDIRECTING FOR THREE HOURS, THIS MECHANISM IS WRONG and the
# window count was the resource after all.
#
# WHAT IT WOULD MEAN ON HIS STICK, and this is reasoning, flagged as reasoning:
# once redirection fails, rc.5.linux's `wsysd > /var/log/wsysd.log` would put
# the compositor's stderr ON THE CONSOLE instead -- and consmirror copies the
# console into the kernel ring, and bootlogd writes the ring to the boot medium.
# That is a path from "too many applications open" to "every diagnostic the
# compositor emits becomes a synchronous write to the stick", which is
# candidate 3 arriving by a different door. It requires the redirect to be
# re-established after exhaustion, which a running session does not do, so it
# is a mechanism for a REBOOT into a degraded session rather than for his
# five-minute freeze. It is written down because it is checkable, not because
# it is claimed.
#
# WHAT THE WORKLOAD IS
# ====================
# Two drivers at once, on purpose, because each covers the other's failure.
#
#   1. A HOST-SIDE HAND ON THE REAL INPUT DEVICES. tests/linux/qmp_input.py
#      speaks QEMU's `input-send-event` over QMP, which is the same path a VNC
#      viewer's keypress takes: it lands on virtio-tablet-pci and
#      virtio-keyboard-pci, which are /dev/input/event* in the guest, which is
#      what wsysd's open_inputs() scans. NOTHING HERE WRITES A WSYS RING OR AN
#      EVDEV FILE -- a client that reacts to one of these reacted to a device
#      event. It opens the Applications menu at (40,13), hovers categories,
#      clicks app rows, sweeps the pointer, types, scrolls, and dismisses.
#
#   2. A GUEST-SIDE CHURN LOOP in the rc. It writes a program name to
#      /dev/wsys/appmenu/launch -- THE SAME QUEUE THE APPLICATIONS MENU ITSELF
#      DRAINS (user/linux-wsys.c:7872, hampanelscene._drain_one_launch_queue)
#      -- waits, then kills it. This exists because a missed click is a soak
#      that quietly tested nothing; the guest loop guarantees the window churn
#      happens whether or not the pointer landed.
#
# The order and the dwell times VARY (a fixed seed, printed, so a run can be
# repeated). A fixed loop can sit in a groove that misses what a varied one
# hits.
#
# ONLY THE `*scene` BINARIES ARE LAUNCHED. /bin/hamfm is the CONSOLE TUI file
# manager and launching it with no terminal spun a core at 100% and froze the
# screen -- a note tests/linux/de_appmenu_realboot.sh paid for and this file
# inherits rather than re-pays.
#
# WHY THE DISK IS THROTTLED, AND TO WHAT
# ======================================
# The medium's write latency is implicated in the leading candidate, and a host
# file has none. QEMU's `throttling.iops-write` / `throttling.bps-write` on the
# usb-storage drive is the honest way to say "this stick completes N write
# operations a second". WRITES ONLY -- reads are left alone, so any read stall
# seen here is a read QUEUED BEHIND WRITES, which is the mechanism under test
# and not an artefact of the throttle.
#
#   60 write iops / 1 MB/s is the default, and it is chosen to be COMPARABLE
#   rather than adventurous: it is exactly what wedge_hunt.sh used, so a number
#   from this file can be set beside a number from that one. In magnitude it is
#   a mid-range USB 2.0 stick: such devices commonly sustain 5-10 MB/s
#   sequential and 20-60 small synchronous writes a second, and it is the iops
#   figure that binds for an appended log line, not the bandwidth.
#
#   HAMLINUX_SOAK_IOPS / HAMLINUX_SOAK_BPS move it. The harsh arm this file
#   documents having run is 20 iops / 256 KB/s, which is a genuinely bad stick
#   and is the setting under which a per-frame log line would hurt soonest.
#
# WHAT A THROTTLE STILL CANNOT SIMULATE, stated here rather than discovered
# later: a cheap stick stalling for seconds INSIDE ONE FLUSH, timing out a SCSI
# command, and being reset by the USB mass-storage error handler -- during
# which every I/O to the medium, the root filesystem included, is blocked. That
# fits "kernel alive, userspace wedged" exactly. A QEMU throttle DELAYS SMOOTHLY
# AND NEVER ERRORS. So a green run here bounds the LOAD; it does not exonerate
# the medium.
#
# HOW A WEDGE IS SEEN, AND HOW IT GETS A NAME
# ===========================================
# The deliverable is A NAMED PROCESS AND A REASON, not "it froze". Four probes,
# and a response that fires the moment any of them trips:
#
#   1. THE HEARTBEAT, in the GUEST'S OWN CLOCK. The rc prints a marker, its own
#      `date`, and RUNS A PROGRAM OFF THE DISK (`ls /etc`). The last part is
#      the load-bearing one: `echo` from an already-resident shell keeps ticking
#      straight through a total I/O stall, and an I/O stall is what is being
#      hunted. The largest jump between two consecutive guest timestamps is the
#      verdict, read off the serial log afterwards, so nothing about how this
#      script was scheduled can invent a gap or hide one.
#
#   2. THE SCREEN. `screendump` through the QEMU monitor, hashed. The monitor
#      is host-side and answers when the guest does not. An idle hamnix panel
#      repaints its clock and its CPU graph continuously, so a run of identical
#      frames is a FROZEN desktop and not a quiet one.
#
#   3. THE GUEST'S OWN CENSUS, printed to the console every cycle: the
#      compositor's counters (`cat /dev/wsys/wsysd/state` -- focus, windows,
#      inputs, keys, pointer, frames, curframes), the window list, `ps`, and
#      `ls -l /var/log`. A `frames` counter that stops advancing while the
#      heartbeat still ticks is wsysd stuck and the rest of userspace alive --
#      a different failure from the whole machine stopping, and this is what
#      tells them apart.
#
#   4. THE LOG FILE SIZES, over time, out of that same census. If
#      /var/log/wsysd.log is growing during the soak, THAT ALONE IS CANDIDATE 3
#      TURNING REAL, and the rate plus the repeating line are reported.
#
# THE CENSUS IS ITSELF A LOAD ON THE MEDIUM, AND THAT IS SAID HERE RATHER THAN
# LEFT TO INFLATE A NUMBER SILENTLY. `ps` on this guest prints the whole task
# table -- about two hundred lines, mostly kernel threads -- and it goes to the
# CONSOLE, which consmirror copies into the kernel ring, which bootlogd persists
# to \HAMNIX.LOG on the ESP. So every census gives the boot logger something new
# to write, and the absolute "bytes to the medium" figure this gate reports is
# THE WORKLOAD PLUS THE INSTRUMENT.
#
# That is why HAMLINUX_SOAK_IDLE=1 exists and why it keeps the census
# BYTE-FOR-BYTE IDENTICAL while removing the launches and the hand. The
# DIFFERENCE between the two arms is attributable to the workload; the absolute
# of either is not attributable to the desktop. A gate that reported the
# absolute as "what using the desktop costs" would be reporting its own
# instrument as a finding.
#
# AND THE RESPONSE, fired from the HOST the instant a probe trips, because a
# wedged guest cannot ask itself anything:
#
#      sendkey alt-sysrq-w    every task in UNINTERRUPTIBLE sleep, with stacks
#      sendkey alt-sysrq-t    EVERY task, with stacks
#      sendkey alt-sysrq-l    a backtrace on every CPU
#
# through the HMP monitor, which reaches the kernel's sysrq handler with
# userspace dead. `sysrq_always_enabled` is on the shipped command line
# (scripts/hamlinux_disk.sh:366) so the mask cannot refuse them, and
# `hung_task_timeout_secs=30` is there too, so khungtaskd names a blocked task
# by itself with nobody pressing anything. All of it lands on ttyS0 and
# therefore in serial.log. THAT is where the name comes from.
#
# THE INSTRUMENT IS PROVED BEFORE ANY VERDICT IS BELIEVED
# ======================================================
# A soak that finds nothing proves nothing unless it has been shown it would
# have found something. Five proofs, and the gate STOPS if any fails rather
# than printing a reassuring number:
#
#   0a  guest_max_gap finds a PLANTED 77 s hole in a serial log ...
#   0b  ... and reports 1 s for a log with NO hole, so a small number later is
#       a reading and not a floor. This half has to be done on text: a `stop`ped
#       vCPU HAS NO CLOCK, so no VM arm can make guest timestamps jump. That
#       trap is why 0a/0b and 0c are separate proofs and not one.
#   0c  the HEARTBEAT-SILENCE and SCREEN-FROZEN probes, against a real boot
#       halted 60 s by the QEMU monitor's `stop`. `stop` and NOT SIGSTOP:
#       SIGSTOP freezes QEMU too, so the monitor could not answer and the screen
#       probe would take no samples during the very interval it must notice.
#   0d  THE HAND ACTUALLY REACHES THE GUEST. wsysd's own `keys` and `pointer`
#       counters must CLIMB while the driver runs and must NOT climb while it is
#       idle. Without this, "I drove the desktop for four hours" is an assertion
#       about a script, not a measurement of a machine.
#   0e  THE SYSRQ RESPONSE PRODUCES OUTPUT. alt-sysrq-w on a HEALTHY guest must
#       put a non-empty task dump on the console. An empty dump at wedge time
#       must never be readable as "nothing was blocked" when it might mean "the
#       key never arrived".
#   0f  THE WORKLOAD-SURVIVED CHECKS SEE BOTH ANSWERS. The heartbeat-coverage
#       floor and the "command not found" detector are run against planted logs
#       -- one from a workload that died at 352 heartbeats and one from a
#       workload that did not -- because those two checks are what stand
#       between this file and the failure described under DID THE WORKLOAD
#       SURVIVE THE WINDOW below, and they are integer comparisons over text,
#       which is precisely the kind of check that reads "fine" when broken.
#
# AND ONE MORE INSTRUMENT, PROVED IN ITS OWN FILE rather than here:
# tests/linux/vcpu_time.sh answers IS THE MACHINE IDLE OR IS IT SPINNING from
# the host, off /proc, sharing no channel with the guest. name_the_wedge asks it
# first at every trip. Its selftest measured RUNNING 800 ticks / STOPPED 0 /
# RESUMED 799 on a 2-vCPU guest; it also records that sampling the guest's RIP,
# which is the obvious way to do this, was tried and MEASURED USELESS.
#
# Usage: tests/linux/soak_desktop.sh
# Env:   HAMLINUX_SOAK_WORK     where to build and boot
#        HAMLINUX_SOAK_REUSE=1  reuse a medium already built there
#        HAMLINUX_SOAK_SECS     seconds to soak (default 3600)
#        HAMLINUX_SOAK_IOPS     write iops the stick is allowed (default 60)
#        HAMLINUX_SOAK_BPS      write bytes/s the stick is allowed (default 1M)
#        HAMLINUX_SOAK_SEED     workload seed (default 7742)
#        HAMLINUX_SOAK_TYPE=0   DO NOT TYPE. The hand's keystrokes reach PID 1's
#                               interactive console prompt as well as wsysd, so
#                               a long run at the default leaves `hamsh$`
#                               prompts and typed text in its own serial log.
#                               THAT IS NOISE IN THE LOG AND NOT THE THING THAT
#                               STOPS THE WORKLOAD -- see DID THE WORKLOAD
#                               SURVIVE THE WINDOW below, where a run with this
#                               set to 0 stops at the same heartbeat count at
#                               the same time. Worth setting on a long run so
#                               the log can be read; it will not save the run.
#        HAMLINUX_SOAK_SKIPPROOF=1  skip arm 0 (ONLY for iterating on the
#                               workload; a result from such a run is not one)
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"
# FIRST, before reap.sh and before $WORK -- the contract in
# tests/linux/private_ns.sh. gates_are_private.sh checks that this line is here.
. tests/linux/private_ns.sh
priv_ns_reexec "$@"
. tests/linux/reap.sh
# vcpu_tids / vcpu_ticks / vcpu_ticks_each -- the host-side "is it idle or is it
# spinning" probe, proved by its own selftest (RUNNING 800 ticks / STOPPED 0 /
# RESUMED 799 on a 2-vCPU guest). See that file for why sampling the guest's RIP
# instead, which is the obvious idea, was measured useless.
. tests/linux/vcpu_time.sh

WORK="${HAMLINUX_SOAK_WORK:-$HOME/.hamnix-build/soak-desktop}"
mkdir -p "$WORK"
reap_track "$WORK/reaped"
reap_on_exit :

SECS="${HAMLINUX_SOAK_SECS:-3600}"
IOPS="${HAMLINUX_SOAK_IOPS:-60}"
BPS="${HAMLINUX_SOAK_BPS:-1048576}"
SEED="${HAMLINUX_SOAK_SEED:-7742}"

# How long a heartbeat may be missing before the machine is called wedged. The
# guest loop ticks about once a second; twenty is not a slow machine, it is a
# stopped one.
WEDGE_S=20
# ... and how long the picture may stand still. The panel repaints its clock
# and its CPU graph continuously, so this is generous by a wide margin. It is
# larger than wedge_hunt's because THIS gate deliberately makes the guest busy,
# and a busy guest can genuinely defer a repaint further than an idle one.
FREEZE_S=60

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  PASS  %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$*"; }
say()  { printf '\n== %s\n' "$*"; }
info() { printf '  ..    %s\n' "$*"; }

export PATH="$PATH:/usr/sbin:/sbin"
for t in qemu-system-x86_64 sgdisk socat python3; do
    command -v "$t" >/dev/null || { bad "need $t"; exit 1; }
done
[ -f /usr/share/OVMF/OVMF_CODE_4M.fd ] || { bad "need OVMF"; exit 1; }
QMP_INPUT="$PROJ_ROOT/tests/linux/qmp_input.py"
[ -f "$QMP_INPUT" ] || { bad "need tests/linux/qmp_input.py"; exit 1; }

MARK="SOAKDESKTOPUP7742"
HB="SOAKHB"
CENSUS="SOAKCENSUS"
# THE REDIRECT CANARY. `echo <this> > /dev/null` must produce NOTHING on the
# console. If this string ever appears there, sys_openchan has started failing
# and EVERY REDIRECT IN THE SYSTEM IS SILENTLY DOING NOTHING -- see the
# REDIRECTION DIES section in the header. A distinct token rather than an
# inference from stray /etc filenames, so the detector cannot be confused by
# anything else that prints.
REDIR="SOAKREDIRCANARY"
# AND IT IS RUN AS `/bin/echo`, NOT `echo`, WHICH IS THE WHOLE POINT.
#
# The first version of this canary was the builtin, and IT NEVER FIRED -- in a
# run where the line one above it, `ls /etc > /dev/null`, leaked 1,272 lines of
# /etc to the console. Two redirects to the same target in the same loop body,
# one line apart, and only one of them broke.
#
# That accident localised the defect better than the canary would have if it had
# worked. hamsh has TWO redirect implementations: `_wire_redirects`
# (user/hamsh.ad:11244) for an EXTERNAL program, which calls sys_openchan and
# then sys_fdbind on the spawned pid and skips the bind on a fail-closed -1; and
# `_wire_redirects_self` (:11401) for a BUILTIN, which rebinds the calling task's
# own integer fds and restores them afterwards. `ls` is external and `echo` is a
# builtin. ONLY THE EXTERNAL PATH FAILED.
#
# So the canary has to be external too, or it is a probe pointed at the half of
# the mechanism that works.

SCREEN_W=1280
SCREEN_H=800
# The Applications button on the top bar. The literal every appmenu gate in
# this tree uses (de_appmenu_realboot.sh:163, scripts/hamlinux_shot_appmenu.sh:28).
APPBTN_X=40; APPBTN_Y=13
# The dropdown's own geometry, read off the shipped source rather than off a
# screenshot: lib/appmenucore.ad's AMC_BOX_W / AMC_ROW_H and
# user/hamappmenu.ad's _am_place_window(wid, 8, 28).
MX=8; MY=28; ROWH=20
CAT_X=60; CAT_Y=58                # hovering here opens a category fly-out
NEUTRAL_X=900; NEUTRAL_Y=600      # a click here dismisses the menu

# ---------------------------------------------------------------------------
# THE GUEST'S rc: THE SHIPPED ONE, SOURCED VERBATIM, PLUS A WORKLOAD.
#
# A gate with an rc of its own would prove nothing about the file that ships on
# the stick, so `source '/etc/rc.boot.installed'` is the first line and the
# desktop that comes up is the one rc.5.linux brings up -- wsysd, hamdesktop
# and hampanelscene, each redirected into /var/log, which is the whole point.
#
# `while 1 == 1` rather than `while true`: a while condition is an EXPRESSION
# in hamsh (HAMSH_SPEC §8a) and `true` there is an identifier, not the program.
#
# THE CHURN. `echo <prog> > /dev/wsys/appmenu/launch` is the queue the
# Applications menu itself drains, so this is the menu's own launch path with
# the pointer taken out of it. The kill is `ps | grep | awk | xargs kill` --
# hamsh has no $!, and going through ps means the loop kills what is ACTUALLY
# running rather than what it believes it started.
#
# THE CENSUS is printed at the end of every cycle. `ls -l /var/log` is in there
# for one reason: THE SIZES OF THOSE FILES OVER TIME. It is the guest reporting
# its own log growth on the console, which is the only place a wedged machine's
# state can still be read from.
# ---------------------------------------------------------------------------
write_rc() {
    # THE CLOSE PATH, AND WHY IT IS THIS ONE.
    #
    # The obvious `ps | grep <app> | awk '{print $1}' | xargs kill` DOES NOT
    # WORK ON THIS IMAGE and the first run of this gate proved it by printing
    # `hamsh: command not found: awk` twenty-one times: neither awk nor xargs is
    # staged into build/image/root/bin. Nor is a pipeline usable as a value --
    # hamsh answers `command substitution of a PIPELINE is not wired -- use a
    # single command`. Both measured, in the guest, not assumed.
    #
    # So the window is closed through the compositor instead of the process
    # through the kernel: `close <wid>` on /dev/wsys/ctl DESTROYS THE WINDOW
    # RECORD (user/linux-wsys.c:3032, tests/linux/wsys_close_button.sh), which
    # is what the title-bar close button sends and therefore what a user
    # closing a window actually does.
    #
    # IT IS A SWEEP OVER A FIXED RANGE AND NOT A LOOKUP, because the shell
    # cannot extract a wid from `cat /dev/wsys/windows` either. Every wid from
    # 6 up is closed at the end of each cycle -- i.e. the application that has
    # just been open for the dwell is closed, which is the churn this file is
    # for. An unknown wid is a closed verb set's -EINVAL and costs nothing, so
    # sweeping empty space is free.
    #
    # SIX IS THE FLOOR AND IT IS NOT ARBITRARY: wsysd, hamdesktop's backdrop
    # and hampanelscene's two panels hold the low wids (the census's first
    # `windows` reading is that chrome, and it is 3-5 on this image). Closing
    # those would be dismantling the desktop rather than using it.
    #
    # A TRAILING COUNTER WAS TRIED FIRST AND MEASURED WRONG. `lo` advancing 4 a
    # cycle OVERTOOK the wid allocator: by cycle 35 it was sweeping wids around
    # 146 while the live windows were far below it, and the count still climbed
    # 3 -> 31. The number that proves this one works is the same number: the
    # census's `windows` reading, which must come back down every cycle.
    local closer=""
    if [ "${HAMLINUX_SOAK_CLOSE:-1}" = 1 ]; then
        closer=$(cat <<'CLOSEEOF'
    c = 6
    while c < 64 {
        echo close $c > '/dev/wsys/ctl'
        c = c + 1
    }
CLOSEEOF
)
    fi
    # One cycle = launch, dwell with heartbeats, census, sweep. Four apps per
    # outer pass so the workload is not one program's behaviour generalised.
    local dwell="${HAMLINUX_SOAK_DWELL:-8}"
    local body=""
    # THE IDLE CONTROL. Same image, same rc structure, same census, same
    # heartbeat -- and NO LAUNCHES AND NO SWEEP. It is wedge_hunt.sh's
    # configuration (the desktop up, nobody asking it for anything) reproduced
    # inside this file so that the driven arm's write rate has something to be
    # a multiple OF. Without it, "a driven desktop writes 54 KB/s to the stick"
    # is a number with no denominator.
    local apps="hamcalcscene hamnotesscene hammonscene hamtermscene"
    if [ "${HAMLINUX_SOAK_IDLE:-0}" = 1 ]; then
        apps=""
        closer=""
    fi
    if [ -z "$apps" ]; then
        body="
    n = 0
    while n < $dwell {
        echo '$HB'
        date
        ls /etc > /dev/null
        /bin/echo '$REDIR' > /dev/null
        sleep 1
        n = n + 1
    }
    echo '$CENSUS cycle'
    cat '/dev/wsys/wsysd/state'
    ls -l /var/log
    cat '/proc/diskstats'
    tail -6 /var/log/wsysd.log
    tail -6 /var/log/panel.log
    ps
    echo '${CENSUS}END'"
    else
    for app in $apps; do
        body="$body
    echo '/bin/$app' > '/dev/wsys/appmenu/launch'
    n = 0
    while n < $dwell {
        echo '$HB'
        date
        ls /etc > /dev/null
        /bin/echo '$REDIR' > /dev/null
        sleep 1
        n = n + 1
    }
    echo '$CENSUS cycle'
    cat '/dev/wsys/wsysd/state'
    ls -l /var/log
    cat '/proc/diskstats'
    tail -6 /var/log/wsysd.log
    tail -6 /var/log/panel.log
    ps
    echo '${CENSUS}END'
$closer"
    done
    fi
    cat >"$WORK/rc.soak" <<RCEOF
source '/etc/rc.boot.installed'
echo '$MARK'
cycle = 0
lo = 6
while 1 == 1 {
    cycle = cycle + 1
$body
}
RCEOF
}

# ---------------------------------------------------------------------------
# guest_max_gap <serial.log> -- the largest jump, in seconds, between two
# consecutive heartbeat timestamps THE GUEST ITSELF PRINTED. `date` emits
# `YYYY-MM-DD HH:MM:SS UTC`; the kernel's own bracketed printk timestamps are a
# different shape and are not matched. Prints 0 when there are fewer than two,
# which the caller must not read as "healthy" -- the heartbeat COUNT says
# whether there were any at all.
#
# Lifted verbatim from tests/linux/wedge_hunt.sh, and proved again below rather
# than trusted because it was proved there: a probe is proved in the file that
# draws a conclusion from it.
# ---------------------------------------------------------------------------
guest_max_gap() {
    python3 - "$1" <<'PY'
import re, sys, datetime
pat = re.compile(rb'(\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d) UTC')
ts = []
for m in pat.finditer(open(sys.argv[1], 'rb').read()):
    y, mo, d, h, mi, s = (int(x) for x in m.groups())
    ts.append(datetime.datetime(y, mo, d, h, mi, s).timestamp())
gap = 0
for a, b in zip(ts, ts[1:]):
    if b - a > gap:
        gap = b - a
print(int(gap))
PY
}

# ---------------------------------------------------------------------------
# log_growth <serial.log> -- THE ANSWER TO "IS /var/log GROWING?", taken out of
# the guest's own `ls -l /var/log` census lines paired with the guest's own
# clock. Prints one line per file:  <name> <first> <last> <delta> <bytes/s>
#
# Nothing here asks the host filesystem anything: the medium is a raw image
# with a live guest writing to it, and reading it from outside would be reading
# a torn filesystem. The guest reports its own sizes, on the console, which is
# the one channel that still works when the machine is wedged.
# ---------------------------------------------------------------------------
log_growth() {
    python3 - "$1" <<'PY'
import re, sys, datetime
data = open(sys.argv[1], 'rb').read().decode('utf-8', 'replace')
tspat = re.compile(r'(\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d) UTC')
# THIS TREE'S `ls -l`, NOT GNU's. user/ls.ad prints `mode links size<TAB>name`
# -- three fields and no date column -- so a GNU-shaped regex matched nothing
# and the first run of this gate reported "the log-growth question was NOT
# ANSWERED" rather than a rate. That is the failure mode this parser is written
# against, and it is why arm 0's planted evidence below is in THIS format: a
# proof in the wrong format would prove a parser nobody runs.
#
# Positional from the END so a mode string with or without a trailing dot, and
# any number of leading columns, still lands on the same two values.
now = None
first, last = {}, {}
for line in data.splitlines():
    m = tspat.search(line)
    if m:
        y, mo, d, h, mi, s = (int(x) for x in m.groups())
        now = datetime.datetime(y, mo, d, h, mi, s).timestamp()
        continue
    tok = line.split()
    if len(tok) >= 3 and now is not None and tok[-1].endswith('.log') \
            and tok[-2].isdigit() and tok[0][:1] in '-dlbcps':
        size, name = int(tok[-2]), tok[-1]
        first.setdefault(name, (now, size))
        last[name] = (now, size)
for name in sorted(last):
    t0, s0 = first[name]
    t1, s1 = last[name]
    span = t1 - t0
    rate = (s1 - s0) / span if span > 0 else 0.0
    print('%s %d %d %d %.1f' % (name, s0, s1, s1 - s0, rate))
PY
}

# ---------------------------------------------------------------------------
# repeating_lines <serial.log> -- WHAT IS REPEATING. If a log is growing, the
# next question is always "growing with what", and the census does not carry
# the log CONTENTS. What it does carry is everything the console saw, so this
# reports the most-repeated non-heartbeat console line, which is where a
# per-frame diagnostic that escaped the redirect would show up.
# ---------------------------------------------------------------------------
repeating_lines() {
    python3 - "$1" <<'PY'
import re, sys, collections
skip = re.compile(r'SOAKHB|SOAKCENSUS|UTC$|^\s*$')
c = collections.Counter()
for line in open(sys.argv[1], 'rb').read().decode('utf-8', 'replace').splitlines():
    line = line.strip()
    if not line or skip.search(line):
        continue
    # strip printk timestamps so two of the same message coalesce
    line = re.sub(r'^\[\s*\d+\.\d+\]\s*', '', line)
    c[line] += 1
for line, n in c.most_common(6):
    print('%6d  %s' % (n, line[:150]))
PY
}

# ---------------------------------------------------------------------------
# hmp <dir> <command...> -- one HMP command down the monitor socket.
# ---------------------------------------------------------------------------
hmp() {
    local d="$1"; shift
    printf '%s\n' "$*" | timeout 10 socat - "UNIX-CONNECT:$d/mon.sock" 2>/dev/null
}

# ---------------------------------------------------------------------------
# name_the_wedge <dir> <why> -- THE POINT OF THE WHOLE FILE.
#
# Fired from the host the instant a probe trips, because a wedged guest cannot
# be asked anything from inside. Three sysrq keys through the HMP monitor:
#
#   w  every task in UNINTERRUPTIBLE sleep, with its stack -- the D-state
#      tasks, which is what "stuck in I/O to the stick" looks like
#   t  EVERY task with its stack, so a task blocked in a way `w` does not show
#      (a userspace spin, a futex) is still named
#   l  a backtrace on every CPU, which separates "blocked" from "spinning"
#
# It also takes a screendump and the block stats at that moment, so the picture
# and the medium's counters are pinned to the same instant as the stacks.
# ---------------------------------------------------------------------------
name_the_wedge() {
    local d="$1" why="$2"
    printf '\n  !!    WEDGE DETECTED: %s\n' "$why" | tee -a "$d/wedge.txt"
    printf '  !!    firing sysrq through the monitor to NAME who is stuck\n'
    date -u '+%Y-%m-%d %H:%M:%S UTC' >>"$d/wedge.txt"
    hmp "$d" 'screendump '"$d/wedge.ppm" >/dev/null
    hmp "$d" 'info blockstats' >>"$d/wedge.txt"
    hmp "$d" 'info registers' >>"$d/wedge.txt"

    # IS THE MACHINE IDLE OR IS IT SPINNING? Asked FIRST, before the sysrq keys,
    # because it takes eight seconds and it decides what to look for in the
    # dumps that follow. tests/linux/vcpu_time.sh reads the HOST kernel's
    # accounting of the vCPU threads, so it answers for a guest that cannot say
    # anything at all -- and it shares no channel with the heartbeat, the census
    # or the sysrq dump, all three of which land on ttyS0.
    #
    # THIS IS NOT A SUBSTITUTE FOR THE STACKS. It says WHAT KIND of wedge, and
    # the sysrq dump says WHOSE. It is here because the first run of the 3-hour
    # arm fired this response on a machine that turned out to be IDLE, and that
    # was only discovered by reading an NMI backtrace by hand and recognising
    # `pv_native_safe_halt`. A number decides it in eight seconds instead.
    if [ -n "${VCPU_TIDS:-}" ] && [ -n "${VM_PID:-}" ]; then
        local a b used
        a=$(vcpu_ticks "$VM_PID" $VCPU_TIDS)
        sleep 8
        b=$(vcpu_ticks "$VM_PID" $VCPU_TIDS)
        used=$(( b - a ))
        # 800 ticks per 8 s is both vCPUs pinned; 0 is a machine executing
        # nothing. The bands are wide on purpose -- this is a classification,
        # not a measurement, and the per-vCPU breakdown is written out beside it
        # because one core spinning while the other blocks averages to a number
        # that is neither shape.
        printf '  !!    vCPU time over the next 8s: %s ticks (800 = both cores pinned, 0 = executing nothing)\n' "$used"
        printf 'vcpu ticks over 8s at the trip: %s\n' "$used" >>"$d/wedge.txt"
        vcpu_ticks_each "$VM_PID" $VCPU_TIDS >>"$d/wedge.txt"
        if [ "$used" -lt 40 ]; then
            printf '  !!    -> the guest is executing almost NOTHING. Look in the sysrq-w dump for D-state tasks; this is a block, not a spin.\n'
            printf 'classification: IDLE/BLOCKED\n' >>"$d/wedge.txt"
        elif [ "$used" -gt 500 ]; then
            printf '  !!    -> the guest is BURNING CPU. Look in the sysrq-l NMI backtraces for where; this is a spin, not a block.\n'
            printf 'classification: SPINNING\n' >>"$d/wedge.txt"
        else
            printf '  !!    -> neither shape cleanly; the per-vCPU breakdown is in wedge.txt\n'
            printf 'classification: MIXED\n' >>"$d/wedge.txt"
        fi
    else
        printf '  !!    (no vCPU thread ids: the idle-or-spinning question cannot be answered for this trip)\n'
        printf 'classification: UNAVAILABLE -- no vcpu thread ids\n' >>"$d/wedge.txt"
    fi
    for k in w t l; do
        printf '  !!    sendkey alt-sysrq-%s\n' "$k"
        hmp "$d" "sendkey alt-sysrq-$k" >/dev/null
        sleep 4
    done
    # Give the ring time to drain onto the serial line before anything else
    # touches the machine.
    sleep 6
    printf '  !!    the task dumps are in %s/serial.log\n' "$d"
}

# ---------------------------------------------------------------------------
# drive_desktop <dir> <seed> <secs> -- THE HAND. Runs as its own process so the
# sampling loop stays responsive while it is sleeping between gestures.
#
# Every gesture goes through tests/linux/qmp_input.py, i.e. QEMU's
# `input-send-event`, i.e. the virtio tablet and keyboard, i.e. /dev/input/*
# in the guest. There is no ring write and no evdev file anywhere in here.
#
# THE ORDER IS SHUFFLED FROM A PRINTED SEED. A fixed loop settles into a groove
# -- always the same window, always the same dwell -- and a groove is exactly
# the shape of workload that misses an intermittent fault. The seed makes it
# varied AND repeatable, which are usually opposites.
# ---------------------------------------------------------------------------
drive_desktop() {
    local d="$1" seed="$2" secs="$3"
    local q="$d/qmp.sock"
    local end=$(( $(date +%s) + secs ))
    local i=0
    Q() { timeout 30 python3 "$QMP_INPUT" "$q" "$@" >>"$d/hand.log" 2>&1; }
    while [ "$(date +%s)" -lt "$end" ]; do
        # A cheap deterministic shuffle: the low bits of a linear congruential
        # step. Six gestures, chosen by the seed, so consecutive cycles differ.
        seed=$(( (seed * 1103515245 + 12345) & 0x7fffffff ))
        local pick=$(( (seed >> 16) % 6 ))
        local dwell=$(( 1 + ((seed >> 8) % 4) ))
        case "$pick" in
        0)  # OPEN THE APPLICATIONS MENU, look at it, dismiss it. The panel's
            # _toggle_appmenu closes on a second click, so this is open/close
            # and not open/open.
            Q click "$APPBTN_X" "$APPBTN_Y" "$SCREEN_W" "$SCREEN_H"
            sleep "$dwell"
            Q move "$CAT_X" "$CAT_Y" "$SCREEN_W" "$SCREEN_H"
            sleep 1
            Q click "$NEUTRAL_X" "$NEUTRAL_Y" "$SCREEN_W" "$SCREEN_H"
            ;;
        1)  # OPEN THE MENU AND CLICK AN APP ROW -- the real launch path,
            # pointer included.
            Q click "$APPBTN_X" "$APPBTN_Y" "$SCREEN_W" "$SCREEN_H"
            sleep 1
            Q click $(( MX + 110 )) $(( MY + 2 * ROWH + 10 )) "$SCREEN_W" "$SCREEN_H"
            sleep "$dwell"
            ;;
        2)  # SWEEP THE POINTER. Every move is a cursor-only frame in wsysd, so
            # this is the cheapest way to make the compositor work continuously.
            local x=100
            while [ "$x" -lt 1200 ]; do
                Q move "$x" $(( 200 + (x % 400) )) "$SCREEN_W" "$SCREEN_H"
                x=$(( x + 137 ))
            done
            ;;
        3)  # TYPE. Into whatever has focus -- which is the point: a soak that
            # only ever typed into a known-good window would not exercise
            # route_key's focus path.
            #
            # AND IT HAS A SWITCH, WHICH IT EARNED. The virtio keyboard does
            # not only reach wsysd: the guest's command line carries
            # `console=tty0` beside `console=ttyS0`, and PID 1's hamsh is
            # sitting at an interactive prompt on the console once the rc's
            # last line is running. So typed text ALSO lands on that prompt --
            # measured, in the serial log of the 3-hour arm, as
            # `hamsh: command not found: hhhamnix` with the characters echoing
            # one at a time. In that run it eventually derailed the rc's
            # workload loop, the heartbeat stopped, and this gate reported a
            # WEDGE that was nothing of the kind: the sysrq-l NMI backtrace it
            # fired shows BOTH CPUs in pv_native_safe_halt/default_idle. An
            # IDLE machine, not a stuck one.
            #
            # That is an instrument that can manufacture its own positive, so
            # HAMLINUX_SOAK_TYPE=0 removes it, and any finding that survives
            # only with typing on is not a finding.
            if [ "${HAMLINUX_SOAK_TYPE:-1}" = 1 ]; then
                Q click 640 400 "$SCREEN_W" "$SCREEN_H"
                sleep 1
                Q type "hamnix soak $i"
                Q key ret
            else
                Q click 640 400 "$SCREEN_W" "$SCREEN_H"
                sleep 1
                Q move 700 450 "$SCREEN_W" "$SCREEN_H"
            fi
            ;;
        4)  # SCROLL. The wheel path is a separate decode in pump_input().
            Q move 640 400 "$SCREEN_W" "$SCREEN_H"
            Q wheel down 5
            sleep 1
            Q wheel up 5
            ;;
        5)  # DRAG. Press, move, release -- the path that commits fastest and
            # pokes the client wake hardest (see the paint_defer note in
            # user/wsysd.ad's main loop).
            Q move 400 300 "$SCREEN_W" "$SCREEN_H"
            Q press
            local y=300
            while [ "$y" -lt 600 ]; do
                Q move $(( 400 + y - 300 )) "$y" "$SCREEN_W" "$SCREEN_H"
                y=$(( y + 40 ))
            done
            Q release
            ;;
        esac
        i=$(( i + 1 ))
        sleep "$dwell"
    done
    printf 'hand: %d gestures\n' "$i" >>"$d/hand.log"
}

# ---------------------------------------------------------------------------
# wsysd_counter <serial.log> <name> -- the LAST value of one of wsysd's own
# counters, out of the census lines. `cat /dev/wsys/wsysd/state` prints
# `focus N windows N inputs N keys N pointer N frames N curframes N` on one
# line (user/wsysd.ad publish_state), so this is a field lookup, not a guess.
# Prints -1 when the counter was never seen, which the caller MUST NOT read as
# zero -- "never printed" and "printed zero" are different findings.
# ---------------------------------------------------------------------------
wsysd_counter() {
    python3 - "$1" "$2" <<'PY'
import re, sys
name = sys.argv[2]
val = -1
pat = re.compile(r'\b' + re.escape(name) + r'\s+(-?\d+)')
for line in open(sys.argv[1], 'rb').read().decode('utf-8', 'replace').splitlines():
    if 'windows' in line and 'frames' in line:
        m = pat.search(line)
        if m:
            val = int(m.group(1))
print(val)
PY
}

# ---------------------------------------------------------------------------
# run_arm <name> <img> <iops|0> <bps|0> <stopsecs|0> <drive:0|1> <secs>
#
# Boots the image as a throttled USB stick, optionally drives it, watches it,
# and leaves behind in $WORK/<name>/:
#   serial.log   the console -- heartbeats, census, and any sysrq task dump
#   hand.log     what the driver sent
#   hb.tsv       host-clock seconds -> heartbeats seen so far
#   frames.tsv   host-clock seconds -> md5 of the frame
#   blk.tsv      host-clock seconds -> wr_bytes wr_operations (the stick)
#   wedge.txt    present ONLY if a probe tripped
# and sets ARM_MAXGAP / ARM_FREEZE / ARM_HB / ARM_WRB / ARM_WROPS / ARM_WEDGED.
# ---------------------------------------------------------------------------
run_arm() {
    local name="$1" src="$2" aiops="$3" abps="$4" stopsecs="$5" drive="$6" secs="$7"
    local d="$WORK/$name"
    rm -rf "$d"; mkdir -p "$d/screens"
    cp "$src" "$d/medium.img"
    cp /usr/share/OVMF/OVMF_VARS_4M.fd "$d/OVMF_VARS.fd"

    local thr=""
    [ "$aiops" != 0 ] && thr="$thr,throttling.iops-write=$aiops"
    [ "$abps"  != 0 ] && thr="$thr,throttling.bps-write=$abps"

    # BOTH MONITORS, and they are not redundant. HMP is what answers `stop`,
    # `screendump`, `info blockstats` and -- the reason this file exists --
    # `sendkey alt-sysrq-w`. QMP is what tests/linux/qmp_input.py speaks, and
    # `input-send-event` has no HMP equivalent that can land on a 26-pixel
    # button (HMP `mouse_move` is RELATIVE; see qmp_input.py's docstring).
    #
    # virtio-keyboard-pci / virtio-tablet-pci rather than usb-kbd / usb-tablet:
    # those are the devices every other input gate in this tree drives, so a
    # gesture here takes the same path through wsysd's open_inputs() scan as a
    # gesture there.
    qemu-system-x86_64 \
        -m 2048 -smp 2 -no-reboot \
        -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
        -drive "if=pflash,format=raw,unit=1,file=$d/OVMF_VARS.fd" \
        -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
        -display none -vga std \
        -serial "file:$d/serial.log" \
        -enable-kvm -cpu host \
        -monitor "unix:$d/mon.sock,server,nowait" \
        -qmp "unix:$d/qmp.sock,server,nowait" \
        -device virtio-keyboard-pci -device virtio-tablet-pci \
        -device qemu-xhci,id=xhci \
        -drive "file=$d/medium.img,if=none,format=raw,id=usbstick$thr" \
        -device usb-storage,bus=xhci.0,drive=usbstick,bootindex=0 \
        >"$d/qemu.out" 2>&1 &
    local vm=$!
    reap_add "$vm"

    # Wait for the rc to reach the workload before the clock starts, so the
    # boot's own slowness is not counted as a wedge. The boot is throttled too.
    local w=0
    while kill -0 "$vm" 2>/dev/null && [ "$w" -lt 420 ]; do
        grep -aq "$MARK" "$d/serial.log" 2>/dev/null && break
        sleep 2; w=$((w+2))
    done
    if ! grep -aq "$MARK" "$d/serial.log" 2>/dev/null; then
        bad "$name: the boot never reached the end of the rc in ${w}s"
        tail -30 "$d/serial.log" 2>/dev/null
        kill -KILL "$vm" 2>/dev/null; wait "$vm" 2>/dev/null
        return 1
    fi
    info "$name: the rc completed after ~${w}s; watching for ${secs}s"

    # The vCPU thread ids, from QEMU itself, for name_the_wedge's idle-or-
    # spinning question. Taken once, here, rather than at the trip: a wedged
    # machine is a bad moment to discover that QMP has to be spoken to first.
    VM_PID="$vm"
    VCPU_TIDS=$(vcpu_tids "$d/qmp.sock")
    if [ -n "$VCPU_TIDS" ]; then
        info "$name: vCPU threads $VCPU_TIDS -- the idle-or-spinning probe is armed"
    else
        info "$name: QMP named no vCPU threads; a wedge here could not be classified idle-or-spinning"
    fi

    local hand=0
    if [ "$drive" = 1 ]; then
        drive_desktop "$d" "$SEED" "$secs" &
        hand=$!
        reap_add "$hand"
        info "$name: the hand is driving the desktop (seed $SEED)"
    fi

    : >"$d/hb.tsv"; : >"$d/frames.tsv"; : >"$d/blk.tsv"
    local t0 now el last_hb hb prev_md5="" i=0 stopped=0 STOP_AT=0
    t0=$(date +%s); last_hb=$t0
    ARM_MAXGAP=0; ARM_FREEZE=0; ARM_HB=0; ARM_WEDGED=0
    local freeze_start=0 named=0
    while :; do
        now=$(date +%s); el=$(( now - t0 ))
        [ "$el" -ge "$secs" ] && break
        kill -0 "$vm" 2>/dev/null || { bad "$name: the VM died mid-run"; break; }

        # THE INSTRUMENT PROOF, when asked for: freeze the guest outright.
        # The QEMU MONITOR's `stop`, and NOT SIGSTOP to the process -- SIGSTOP
        # would freeze QEMU as well, so the monitor could not answer and the
        # SCREEN probe would take no samples at all during the very interval it
        # is supposed to notice. `stop` halts the vCPUs and leaves QEMU running,
        # which is precisely the shape of the failure being hunted.
        if [ "$stopsecs" != 0 ] && [ "$stopped" = 0 ] && [ "$el" -ge 30 ]; then
            info "$name: monitor 'stop' for ${stopsecs}s (instrument proof)"
            hmp "$d" stop >/dev/null
            stopped=1
            STOP_AT=$(date +%s)
        fi
        if [ "$stopped" = 1 ] && [ $(( now - STOP_AT )) -ge "$stopsecs" ]; then
            hmp "$d" cont >/dev/null
            info "$name: monitor 'cont'"
            stopped=2
        fi

        hb=$(grep -ac "$HB" "$d/serial.log" 2>/dev/null || echo 0)
        printf '%s\t%s\n' "$el" "$hb" >>"$d/hb.tsv"
        if [ "${hb:-0}" -gt "${ARM_HB:-0}" ]; then ARM_HB="$hb"; last_hb=$now; fi
        local gap=$(( now - last_hb ))
        [ "$gap" -gt "$ARM_MAXGAP" ] && ARM_MAXGAP="$gap"

        # A frame every third pass, hashed.
        if [ $(( i % 3 )) = 0 ]; then
            local shot="$d/screens/f$(printf '%06d' "$el").ppm"
            hmp "$d" "screendump $shot" >/dev/null
            if [ -s "$shot" ]; then
                local m; m=$(md5sum <"$shot" | cut -d' ' -f1)
                printf '%s\t%s\n' "$el" "$m" >>"$d/frames.tsv"
                if [ "$m" = "$prev_md5" ]; then
                    [ "$freeze_start" = 0 ] && freeze_start=$now
                    local fz=$(( now - freeze_start ))
                    [ "$fz" -gt "$ARM_FREEZE" ] && ARM_FREEZE="$fz"
                else
                    freeze_start=0
                fi
                prev_md5="$m"
                # An hour at 3 s is 1200 frames of 3 MB. One a minute is kept
                # for a human; the rest are hashed and dropped. THE HASH IS THE
                # MEASUREMENT -- the files are only so the picture at a wedge
                # can be looked at afterwards.
                [ $(( el % 60 )) -ge 3 ] && rm -f "$shot"
            fi
            printf 'info blockstats\n' \
                | timeout 10 socat - "UNIX-CONNECT:$d/mon.sock" 2>/dev/null \
                | awk -v el="$el" '/wr_bytes/ {print el "\t" $0}' >>"$d/blk.tsv"
        fi

        # THE RESPONSE. Once, on the first trip -- firing sysrq repeatedly at a
        # machine that is already stuck adds megabytes of stack dump to a serial
        # line that may itself be the thing that is blocked, and the FIRST dump
        # is the one taken closest to the moment of failure.
        if [ "$stopsecs" = 0 ] && [ "$named" = 0 ]; then
            if [ "$gap" -ge "$WEDGE_S" ]; then
                named=1; ARM_WEDGED=1
                name_the_wedge "$d" "the heartbeat has been silent for ${gap}s"
            elif [ "$ARM_FREEZE" -ge "$FREEZE_S" ]; then
                named=1; ARM_WEDGED=1
                name_the_wedge "$d" "the picture has not changed for ${ARM_FREEZE}s"
            fi
        fi

        i=$(( i + 1 ))
        sleep 1
    done

    [ "$hand" != 0 ] && { kill -TERM "$hand" 2>/dev/null; wait "$hand" 2>/dev/null; }

    printf 'info blockstats\n' | timeout 10 socat - "UNIX-CONNECT:$d/mon.sock" \
        >"$d/blockstats.txt" 2>/dev/null
    # THE `usbstick:` LINE AND NOT THE FIRST ONE THAT MATCHES. `info blockstats`
    # reports every drive QEMU has and the two pflash devices come first with
    # wr_bytes=0 -- a parse that took the first match once reported that the
    # medium had been written NOTHING, in a run whose whole subject was how much
    # it was written. wedge_hunt.sh records paying for that; this inherits the
    # fix rather than the bug.
    ARM_WRB=$(awk -F'wr_bytes=' '/^usbstick:/{split($2,a," ");print a[1];exit}' "$d/blockstats.txt")
    ARM_WROPS=$(awk -F'wr_operations=' '/^usbstick:/{split($2,a," ");print a[1];exit}' "$d/blockstats.txt")
    ARM_WRFL=$(awk -F'flush_operations=' '/^usbstick:/{split($2,a," ");print a[1];exit}' "$d/blockstats.txt")
    ARM_WRT=$(awk -F'wr_total_time_ns=' '/^usbstick:/{split($2,a," ");print a[1];exit}' "$d/blockstats.txt")
    ARM_WRB="${ARM_WRB:-0}"; ARM_WROPS="${ARM_WROPS:-0}"
    ARM_WRFL="${ARM_WRFL:-0}"; ARM_WRT="${ARM_WRT:-0}"

    kill -KILL "$vm" 2>/dev/null; wait "$vm" 2>/dev/null

    # THE VERDICT NUMBER, AND IT IS THE GUEST'S OWN CLOCK.
    # AND IT IS THE GUEST'S CLOCK ALONE. This used to be max(guest, host), and
    # that is how a 30-minute run with a HEALTHY guest reported "USERSPACE WENT
    # SILENT FOR 111s": once the redirect leak starts, the serial log grows
    # fast, and the host's own sampling -- `grep -ac` over that file, plus a
    # screendump and an md5 -- stops keeping up. The host saw no new heartbeat
    # for 111 s. THE GUEST'S OWN TIMESTAMPS NEVER GAPPED BY MORE THAN 2 s.
    #
    # The host number is still taken and still printed, and it still ARMS the
    # sysrq capture -- a cheap dump taken on a false alarm costs nothing and a
    # missed one costs the whole run. It just cannot pass a verdict any more.
    ARM_GUESTGAP=$(guest_max_gap "$d/serial.log")
    ARM_GAP="$ARM_GUESTGAP"
    ARM_KEYS=$(wsysd_counter "$d/serial.log" keys)
    ARM_PTR=$(wsysd_counter "$d/serial.log" pointer)
    ARM_FRAMES=$(wsysd_counter "$d/serial.log" frames)
    ARM_WINS=$(wsysd_counter "$d/serial.log" windows)
    info "$name: heartbeats=$ARM_HB  longest gap in the GUEST's clock=${ARM_GUESTGAP}s  (host-observed ${ARM_MAXGAP}s)  longest frozen screen=${ARM_FREEZE}s"
    info "$name: wsysd's own counters at the end: keys=$ARM_KEYS pointer=$ARM_PTR frames=$ARM_FRAMES windows=$ARM_WINS"
    info "$name: the stick was written $ARM_WRB bytes in $ARM_WROPS operations and $ARM_WRFL cache flushes ($(( ARM_WRT / 1000000 )) ms inside write)"
    return 0
}

write_rc

say "building the medium under test (the shipped rc, sourced verbatim)"
if [ "${HAMLINUX_SOAK_REUSE:-0}" = 1 ] && [ -f "$WORK/medium.img" ]; then
    info "reusing $WORK/medium.img"
else
    # REBUILT EXPLICITLY. scripts/hamlinux_disk.sh rebuilds build/image/root
    # only when it is ABSENT, so every run after the first would otherwise
    # package whatever tree happened to be lying there -- the stale-artifact
    # false report tests/linux/boot_log.sh records paying for.
    if [ "${HAMLINUX_SOAK_IMGREUSE:-0}" = 1 ] && [ -d build/image/root ]; then
        # ITERATION ONLY, and it is named so it cannot be mistaken for a run.
        # The rc changes far more often than the tree does while a workload is
        # being got right, and a full image build per edit is fifteen minutes
        # of a shared machine. A RESULT IS NEVER TAKEN FROM A RUN WITH THIS SET.
        info "HAMLINUX_SOAK_IMGREUSE: reusing build/image/root -- ITERATION ONLY, not a result"
    else
        info "rebuilding build/image/root so this gate cannot boot a stale tree"
        HAMLINUX_DISTRO_RO=1 scripts/hamlinux_image.sh >"$WORK/image.log" 2>&1 || {
            bad "image build"; tail -20 "$WORK/image.log"; exit 1; }
    fi
    HAMLINUX_DISK_RC="$WORK/rc.soak" \
        scripts/hamlinux_disk.sh "$WORK/medium.img" 3G >"$WORK/disk.log" 2>&1 || {
        bad "disk build"; tail -20 "$WORK/disk.log"; exit 1; }
fi

if [ "${HAMLINUX_SOAK_SKIPPROOF:-0}" != 1 ]; then
# ---------------------------------------------------------------------------
say "ARM 0 -- THE INSTRUMENT PROOF: would this harness see a wedge at all?"
# ---------------------------------------------------------------------------
# -- 0a/0b, host-side and instant: pure text over a serial log. A `stop`ped
# vCPU has no clock, so the VM arm below CANNOT exercise this half -- which is
# exactly what makes `stop` the right proof for the other two probes and the
# wrong one for this.
{
    printf 'SOAKHB\n2026-01-01 00:00:00 UTC\n'
    printf 'SOAKHB\n2026-01-01 00:00:01 UTC\n'
    printf 'SOAKHB\n2026-01-01 00:01:18 UTC\n'
    printf 'SOAKHB\n2026-01-01 00:01:19 UTC\n'
} >"$WORK/synthetic.log"
SYN=$(guest_max_gap "$WORK/synthetic.log")
[ "$SYN" = 77 ] \
    && ok "guest_max_gap finds a planted 77s hole in a serial log (it said ${SYN}s)" \
    || bad "guest_max_gap said ${SYN}s for a planted 77s hole -- the guest-clock probe is broken"
{ printf 'SOAKHB\n2026-01-01 00:00:00 UTC\n'; printf 'SOAKHB\n2026-01-01 00:00:01 UTC\n'; } >"$WORK/synthetic2.log"
SYN2=$(guest_max_gap "$WORK/synthetic2.log")
[ "$SYN2" = 1 ] \
    && ok "and reports 1s for a log with no hole, so a small number later is a real reading and not a floor" \
    || bad "guest_max_gap said ${SYN2}s for a clean log -- it cannot tell healthy from wedged"

# -- and the LOG-GROWTH probe, on the same kind of planted evidence. A rate of
# 0.0 at the end of a four-hour soak is the single most likely thing this file
# will report, and it must be a measurement rather than a parser that never
# matched a line.
{
    printf 'SOAKHB\n2026-01-01 00:00:00 UTC\n'
    printf -- '-rw-r--r-- 0 1000\twsysd.log\n'
    printf -- '-rw-r--r-- 0 500\tpanel.log\n'
    printf 'SOAKHB\n2026-01-01 00:01:40 UTC\n'
    printf -- '-rw-r--r-- 0 11000\twsysd.log\n'
    printf -- '-rw-r--r-- 0 500\tpanel.log\n'
} >"$WORK/synthetic3.log"
G=$(log_growth "$WORK/synthetic3.log")
GW=$(printf '%s\n' "$G" | awk '$1=="wsysd.log"{print $5}')
GP=$(printf '%s\n' "$G" | awk '$1=="panel.log"{print $5}')
[ "$GW" = "100.0" ] \
    && ok "log_growth measures a planted 10000-byte-in-100s rise as ${GW} B/s" \
    || bad "log_growth said '${GW}' for a planted 100.0 B/s rise -- the log-growth probe is broken"
[ "$GP" = "0.0" ] \
    && ok "and 0.0 B/s for a file that did not move, so a quiet log later is a reading and not a blind spot" \
    || bad "log_growth said '${GP}' for a file that never changed size"

# -- 0c, in the VM: do the heartbeat and screen probes see a machine stop?
PROOF_STOP=60
run_arm proof "$WORK/medium.img" 0 0 "$PROOF_STOP" 0 150
P_GAP="$ARM_MAXGAP"; P_FRZ="$ARM_FREEZE"
[ "${ARM_HB:-0}" -gt 20 ] \
    && ok "the proof arm produced $ARM_HB heartbeats, so the probe emits something that could go missing" \
    || bad "the proof arm produced only ${ARM_HB:-0} heartbeats -- the probe is not running"
if [ "$P_GAP" -ge $(( PROOF_STOP - 15 )) ]; then
    ok "the heartbeat probe SAW a ${PROOF_STOP}s stop (it reported ${P_GAP}s), so a silent heartbeat below is a real observation"
else
    bad "the heartbeat probe reported only ${P_GAP}s for a ${PROOF_STOP}s stop -- THIS HARNESS IS BLIND and no result below can be believed"
fi
if [ "$P_FRZ" -ge $(( PROOF_STOP - 20 )) ]; then
    ok "the screen probe SAW the same stop (${P_FRZ}s of identical frames), so an unchanging desktop below is a real observation"
else
    bad "the screen probe reported only ${P_FRZ}s of frozen frames for a ${PROOF_STOP}s stop -- the picture check is blind"
fi
# The undriven arm is ALSO the negative control for 0d: it had no hand on it,
# so its keystroke counter is what "nobody typed" looks like on this machine.
IDLE_KEYS=$(wsysd_counter "$WORK/proof/serial.log" keys)
IDLE_PTR=$(wsysd_counter "$WORK/proof/serial.log" pointer)
info "undriven control: wsysd counted keys=$IDLE_KEYS pointer=$IDLE_PTR"

# -- 0d: DOES THE HAND ACTUALLY REACH THE GUEST? Without this, every "I drove
# the desktop for four hours" below is a statement about a bash function.
run_arm handproof "$WORK/medium.img" 0 0 0 1 150
H_KEYS=$(wsysd_counter "$WORK/handproof/serial.log" keys)
H_PTR=$(wsysd_counter "$WORK/handproof/serial.log" pointer)
info "driven: wsysd counted keys=$H_KEYS pointer=$H_PTR"
if [ "${HAMLINUX_SOAK_TYPE:-1}" != 1 ]; then
    info "HAMLINUX_SOAK_TYPE=0: the keyboard gesture is off for this run, so keys=$H_KEYS is expected and is not asserted on. The pointer half below still is."
elif [ "$H_KEYS" -gt "$IDLE_KEYS" ] && [ "$H_KEYS" -gt 0 ]; then
    ok "the hand's KEYSTROKES reached wsysd: keys $IDLE_KEYS undriven -> $H_KEYS driven"
else
    bad "wsysd counted keys=$H_KEYS driven against $IDLE_KEYS undriven -- THE KEYBOARD HALF OF THE WORKLOAD IS NOT ARRIVING and a soak with it is a soak without it"
fi
if [ "$H_PTR" -gt "$IDLE_PTR" ] && [ "$H_PTR" -gt 0 ]; then
    ok "the hand's POINTER reached wsysd: pointer $IDLE_PTR undriven -> $H_PTR driven"
else
    bad "wsysd counted pointer=$H_PTR driven against $IDLE_PTR undriven -- THE POINTER HALF OF THE WORKLOAD IS NOT ARRIVING"
fi

# -- 0e: DOES THE SYSRQ RESPONSE PRODUCE ANYTHING? An empty task dump at wedge
# time must never be readable as "nothing was blocked" when it might mean "the
# key never got there". Proved on a HEALTHY guest, where `t` must name tasks.
say "ARM 0f -- proving the WORKLOAD-SURVIVED detectors, on planted logs"
# ---------------------------------------------------------------------------
# The two checks added at the end of this file are the ones that would have
# caught the derailed 3-hour run described there, and both are integer
# comparisons over a text file -- which is exactly the kind of check that quietly
# reads "fine" when it is broken. So they are exercised in both directions here,
# on logs planted for the purpose, before any run's numbers are believed.
#
# Planted rather than taken from the real derailed log on purpose: the real log
# lives in a build directory that a fresh checkout does not have, and a proof
# that only works on this machine is not a proof. The real numbers are in the
# header; these fixtures reproduce their SHAPE.
PF="$WORK/survivedproof"
rm -rf "$PF"; mkdir -p "$PF"
python3 - "$PF" "$HB" <<'PY'
import sys, os
d, hb = sys.argv[1], sys.argv[2]
# A log from a run that died early: a few heartbeats, then a shell prompt and
# the shape hamsh answers a stray keystroke with.
with open(os.path.join(d, "dead.log"), "w") as f:
    for i in range(352):
        f.write("%s\n2026-08-17 15:0%d:%02d UTC\n" % (hb, i // 60 % 10, i % 60))
    f.write("hamsh$ hhhamnix soak 7\n")
    f.write("hamsh: command not found: hhhamnix\n")
# ... and one from a run that did not.
with open(os.path.join(d, "alive.log"), "w") as f:
    for i in range(4000):
        f.write("%s\n" % hb)
PY
DEAD_HB=$(grep -ac "$HB" "$PF/dead.log")
ALIVE_HB=$(grep -ac "$HB" "$PF/alive.log")
DEAD_NF=$(grep -ac 'command not found' "$PF/dead.log")
ALIVE_NF=$(grep -ac 'command not found' "$PF/alive.log")
PROOF_FLOOR=$(( 3600 / 2 ))
# THE POSITIVE HALF: the detector must PASS a log that shows a live workload.
# Without it, a red result later could be a check that is red for everything.
if [ "$ALIVE_HB" -ge "$PROOF_FLOOR" ]; then
    ok "the coverage check passes a planted 4000-heartbeat log against a 3600s floor of $PROOF_FLOOR"
else
    bad "the coverage check counted only $ALIVE_HB heartbeats in a log that has 4000 -- it cannot recognise a healthy run and would call every run dead"
fi
# THE NEGATIVE HALF, and it is the one the run this was written after needed:
# 352 heartbeats where a window wants thousands must be RED.
if [ "$DEAD_HB" -lt "$PROOF_FLOOR" ]; then
    ok "and FAILS a log with only $DEAD_HB heartbeats -- the shape of the run that died at six minutes into three hours"
else
    bad "the coverage check accepted a $DEAD_HB-heartbeat log against a floor of $PROOF_FLOOR -- IT CANNOT SEE A DEAD WORKLOAD and the verdict at the end of this file is worthless"
fi
if [ "$DEAD_NF" -ge 1 ]; then
    ok "the 'command not found' check finds the hand's keystroke reaching a shell prompt when it is there ($DEAD_NF line)"
else
    bad "the 'command not found' check found nothing in a log that contains one -- it cannot name the cause of a derailment"
fi
if [ "$ALIVE_NF" = 0 ]; then
    ok "and reports 0 for a log with no prompt in it, so a 0 later is a reading and not a blind spot"
else
    bad "the 'command not found' check reported $ALIVE_NF for a clean log -- it matches text that is not there"
fi

# THE THIRD DETECTOR, AND IT IS THE ONE THAT WOULD HAVE ENDED THE HUNT ON RUN
# ONE. Both preserved logs of the "wedge" carry, on the line immediately after
# the last census, the shell saying exactly what happened:
#
#     hamsh: runtime error: value arena exhausted (VAL_MAX=16384 live cells)
#            — split the loop
#
# followed by `[hamsh:stage-06] rc-done`, `[hamsh:stage-07] loop-enter` and a
# `hamsh$` prompt: PID 1 falling out of the rc into interactive readline. The
# gate had all of that in $WORK/soak/serial.log for three runs and asserted on
# NONE of it, so the finding it reported was "a wedge of unknown cause". The
# string was in the evidence the whole time.
#
# NOTE THE em-dash: hamsh emits U+2014 in that message, so a pattern spelled
# with an ASCII hyphen matches nothing. Match only the part that cannot drift.
ARENA_PAT='arena exhausted\|arena full\|element pool exhausted'
python3 - "$PF" <<'PY'
import sys, os
d = sys.argv[1]
with open(os.path.join(d, "arena.log"), "w", encoding="utf-8") as f:
    f.write("SOAKCENSUSEND\n")
    f.write("hamsh: runtime error: value arena exhausted "
            "(VAL_MAX=16384 live cells) — split the loop\n")
    f.write("[hamsh:stage-06] rc-done\n")
PY
DEAD_AR=$(grep -ac "$ARENA_PAT" "$PF/arena.log")
ALIVE_AR=$(grep -ac "$ARENA_PAT" "$PF/alive.log")
if [ "${DEAD_AR:-0}" -ge 1 ]; then
    ok "the arena-death check finds hamsh's own exhaustion message when it is there ($DEAD_AR line)"
else
    bad "the arena-death check found nothing in a log that contains the exact string -- it cannot name the cause that stopped three runs"
fi
if [ "${ALIVE_AR:-0}" = 0 ]; then
    ok "and reports 0 for a log without it, so a 0 in the real run is a reading"
else
    bad "the arena-death check reported $ALIVE_AR for a clean log -- it matches text that is not there"
fi

# ---------------------------------------------------------------------------
say "ARM 0e -- proving the sysrq response, on a machine that is not stuck"
D="$WORK/sysrqproof"
rm -rf "$D"; mkdir -p "$D/screens"
cp "$WORK/medium.img" "$D/medium.img"
cp /usr/share/OVMF/OVMF_VARS_4M.fd "$D/OVMF_VARS.fd"
qemu-system-x86_64 -m 2048 -smp 2 -no-reboot \
    -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive "if=pflash,format=raw,unit=1,file=$D/OVMF_VARS.fd" \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -display none -vga std -serial "file:$D/serial.log" \
    -enable-kvm -cpu host -monitor "unix:$D/mon.sock,server,nowait" \
    -qmp "unix:$D/qmp.sock,server,nowait" \
    -device virtio-keyboard-pci -device virtio-tablet-pci \
    -device qemu-xhci,id=xhci \
    -drive "file=$D/medium.img,if=none,format=raw,id=usbstick" \
    -device usb-storage,bus=xhci.0,drive=usbstick,bootindex=0 \
    >"$D/qemu.out" 2>&1 &
SQVM=$!; reap_add "$SQVM"
w=0
while kill -0 "$SQVM" 2>/dev/null && [ "$w" -lt 300 ]; do
    grep -aq "$MARK" "$D/serial.log" 2>/dev/null && break
    sleep 2; w=$((w+2))
done
if grep -aq "$MARK" "$D/serial.log" 2>/dev/null; then
    BEFORE=$(wc -c <"$D/serial.log")
    hmp "$D" 'sendkey alt-sysrq-t' >/dev/null
    sleep 8
    AFTER=$(wc -c <"$D/serial.log")
    # `sysrq: Show State` is the kernel's own banner for the `t` key. Matching
    # the banner and not just "the file grew" matters: the heartbeat is
    # printing a line a second, so the file grows anyway.
    if grep -aqi 'sysrq' "$D/serial.log" && [ "$AFTER" -gt "$BEFORE" ]; then
        NTASK=$(grep -ac 'task:\|\[<' "$D/serial.log" 2>/dev/null || echo 0)
        ok "alt-sysrq-t on a healthy guest put a task dump on the console (+$(( AFTER - BEFORE )) bytes, $NTASK task lines) -- so an EMPTY dump at a wedge would be a finding and not a broken key"
    else
        bad "alt-sysrq-t produced no sysrq banner on a healthy guest -- THE RESPONSE IS BLIND and a wedge below could not be named"
    fi
else
    bad "0e: the sysrq-proof boot never reached the rc"
fi
kill -KILL "$SQVM" 2>/dev/null; wait "$SQVM" 2>/dev/null

[ "$FAIL" = 0 ] || { printf '\n%d PASSED, %d FAILED\n' "$PASS" "$FAIL"; exit 1; }
else
    info "ARM 0 SKIPPED by HAMLINUX_SOAK_SKIPPROOF -- nothing below this line is a result"
fi

# ---------------------------------------------------------------------------
say "THE SOAK -- ${SECS}s of a DRIVEN desktop on a stick throttled to ${IOPS} write iops / ${BPS} B/s"
# ---------------------------------------------------------------------------
DRIVE=1
[ "${HAMLINUX_SOAK_IDLE:-0}" = 1 ] && DRIVE=0
run_arm soak "$WORK/medium.img" "$IOPS" "$BPS" 0 "$DRIVE" "$SECS"
S_GAP="$ARM_GAP"; S_FRZ="$ARM_FREEZE"; S_HB="$ARM_HB"; S_WEDGED="$ARM_WEDGED"
S_WRB="$ARM_WRB"; S_WROPS="$ARM_WROPS"; S_WRFL="$ARM_WRFL"
S_KEYS="$ARM_KEYS"; S_PTR="$ARM_PTR"; S_FRAMES="$ARM_FRAMES"; S_WINS="$ARM_WINS"

say "WHAT THE WORKLOAD ACTUALLY DID"
info "gestures sent: $(grep -c . "$WORK/soak/hand.log" 2>/dev/null || echo 0) driver lines"
info "wsysd counted keys=$S_KEYS pointer=$S_PTR frames=$S_FRAMES windows=$S_WINS at the last census"
info "cycles completed by the guest churn loop: $(grep -ac "$CENSUS cycle" "$WORK/soak/serial.log" 2>/dev/null || echo 0)"

# THE WORKLOAD MUST BE SHOWN TO HAVE HAPPENED IN THIS RUN, not merely in the
# proof arm an hour earlier. A soak whose hand died in minute three is a
# six-minute soak reported as a four-hour one.
if [ "$DRIVE" = 0 ]; then
    info "IDLE CONTROL ARM: no hand, no launches. This arm exists to be the denominator for the driven arm's write rate, and its keys=$S_KEYS pointer=$S_PTR are meant to be 0."
elif [ "${HAMLINUX_SOAK_TYPE:-1}" != 1 ]; then
    if [ "$S_PTR" -gt 0 ]; then
        ok "the desktop was DRIVEN for the whole window by the pointer alone (keyboard gesture off by request): wsysd took $S_PTR pointer events"
    else
        bad "wsysd took pointer=$S_PTR over ${SECS}s -- THIS WAS NOT A WORKLOAD and no negative below is one"
    fi
elif [ "$S_KEYS" -gt 0 ] && [ "$S_PTR" -gt 0 ]; then
    ok "the desktop was DRIVEN for the whole window: wsysd took $S_KEYS keystrokes and $S_PTR pointer events"
else
    bad "wsysd took keys=$S_KEYS pointer=$S_PTR over ${SECS}s -- THIS WAS NOT A WORKLOAD and no negative below is one"
fi

say "DID THE WINDOW SET STAY BOUNDED? (candidate 2: the 64-per-socket ceiling)"
# wedge_hunt ruled the connection ceiling out BY READING THE CODE -- it fails
# closed and re-arms. Reading is not running, and this is the arm that runs it.
# The trajectory, not just the last value: a count that climbs linearly and
# never falls is a desktop leaking a window per launch, and it walks into the
# ceiling on a clock rather than on a coincidence.
WINTRAJ=$(grep -ao 'windows [0-9][0-9]*' "$WORK/soak/serial.log" | sed 's/^windows //' | grep -v '^$')
W_FIRST=$(printf '%s\n' "$WINTRAJ" | head -1)
W_LAST=$(printf '%s\n' "$WINTRAJ" | tail -1)
W_MAX=$(printf '%s\n' "$WINTRAJ" | sort -n | tail -1)
info "wsysd's window count went $W_FIRST -> $W_LAST over ${SECS}s, peaking at $W_MAX"
if [ "${HAMLINUX_SOAK_CLOSE:-1}" = 1 ]; then
    # THE TEST IS THE PEAK AGAINST THE BASELINE, NOT THE PEAK AGAINST A ROUND
    # NUMBER. The chrome (compositor, backdrop, two panels) is whatever the
    # first census said, and the question is whether the APPLICATIONS on top of
    # it are reclaimed. A handful of slack over the baseline is a cycle caught
    # mid-flight; a count that has climbed by ten is a leak, and 64 is where
    # the per-socket ceiling stops being an abstraction.
    W_CEIL=$(( ${W_FIRST:-3} + 8 ))
    if [ "${W_MAX:-0}" -le "$W_CEIL" ]; then
        ok "the window set stayed bounded: baseline $W_FIRST, peak $W_MAX over ${SECS}s of opening an application every ${HAMLINUX_SOAK_DWELL:-8}s -- windows ARE reclaimed"
    else
        bad "THE WINDOW SET REACHED $W_MAX against a baseline of $W_FIRST while apps were opened and closed -- windows are not being reclaimed and 64 is where the per-socket ceiling is"
    fi
else
    info "close sweep DISABLED for this run: the window count is meant to climb, and what happens at 64 is the measurement"
fi

# AND THE SERVER'S OWN WORD FOR IT, which is not the window count.
#
# WSRV_CONN_MAX is a ceiling on CONNECTIONS, and the server says so exactly
# ONCE per socket when it is reached (user/linux-wsys.c srv_cap_refused: "SAY
# IT ONCE PER SERVER, NOT ONCE PER REFUSAL"). So the presence or absence of one
# line is the whole evidence, and it must be looked for by its text.
#
# WHERE IT LANDS MATTERS AND IS NOT OBVIOUS. It is written to the CLIENT's
# stderr, and a client launched off /dev/wsys/appmenu/launch is a child of
# hampanelscene -- whose stderr rc.5.linux redirects to /var/log/panel.log. It
# does NOT reach the console by itself. That is why the census tails the log
# files: without the tail this question could not be answered from a serial
# log at all, and an absent line would have meant "not looked for" while
# reading as "did not happen".
if grep -aq 'the connection limit is reached' "$WORK/soak/serial.log"; then
    info "THE SERVER REACHED ITS CONNECTION CEILING during this run:"
    grep -a 'connection limit is reached' "$WORK/soak/serial.log" | head -3 | sed 's/^/  ..    /'
    info "what matters is the line AFTER it: past the ceiling a client falls back to the UNMEDIATED in-process path -- it is refused, not blocked. Whether the machine then wedged is the verdict below."
else
    info "the server never printed its connection-ceiling refusal in this run"
fi
CAPREF=$(grep -ao 'capref [0-9]*' "$WORK/soak/serial.log" | tail -1)
[ -n "$CAPREF" ] && info "the server's own running total: $CAPREF"

say "DID REDIRECTION STOP WORKING? (found by this gate; see the header)"
# TWO DETECTORS, because the first run that hit this did not have the second.
#
#   * the CANARY: `echo SOAKREDIRCANARY > /dev/null` in the heartbeat. Nothing
#     may ever print it. If it is on the console, its redirect did not happen.
#   * the LEAK: the heartbeat's `ls /etc > /dev/null` printing /etc to the
#     console. `rc.distros-wl` is an /etc entry with a name nothing else emits,
#     so a bare line equal to it is that redirect having failed. This is how it
#     was caught the first time and it is kept so an old log can be re-read.
# THE GUEST'S CONSOLE ENDS ITS LINES WITH CR, and a `$` anchor after the name
# therefore matches nothing. A hand-run grep for '^os-release$' said 0 while
# `cat -A` showed 636 lines of `os-release^M$` -- the leak was there and the
# check said it was not. `[[:space:]]*$` absorbs it.
#
# AND THE COUNT IS ONE VALUE. `$(grep -ac ... || echo 0)` emits "0\n0" when grep
# exits 1 with no match, and "0\n0" is not "0", so a CLEAN run reported
# REDIRECTION STOPPED WORKING. A guard that fails toward the alarming answer is
# as useless as one that fails toward the reassuring one.
REDIR_N=$(grep -ac "^${REDIR}[[:space:]]*\$" "$WORK/soak/serial.log" 2>/dev/null); REDIR_N=${REDIR_N:-0}
LEAK_N=$(grep -ac '^rc\.distros-wl[[:space:]]*$' "$WORK/soak/serial.log" 2>/dev/null); LEAK_N=${LEAK_N:-0}
# A SECOND /etc NAME, because the first one is not always in the sample. The two
# runs that hit this leaked DIFFERENT top-six filenames -- one showed
# rc.distros-wl, the other os-release -- and a detector keyed to one of them
# would have called the other run clean.
LEAK2_N=$(grep -ac '^os-release[[:space:]]*$' "$WORK/soak/serial.log" 2>/dev/null); LEAK2_N=${LEAK2_N:-0}
LEAK_N=$(( LEAK_N + LEAK2_N ))
if [ "${REDIR_N:-0}" = 0 ] && [ "${LEAK_N:-0}" = 0 ]; then
    ok "shell redirection still worked at the end of ${SECS}s: neither the canary nor an /etc listing ever reached the console"
else
    bad "REDIRECTION STOPPED WORKING DURING THIS RUN (canary on the console ${REDIR_N}x, /etc leak ${LEAK_N}x). sys_openchan is failing, _wire_redirects' \`if fslot >= 0\` is skipping the bind WITH NO DIAGNOSTIC, and every redirect in the system is now silently doing nothing."
    # WHEN, in the guest's own clock, and what the machine looked like then.
    # The moment matters more than the fact: it is what tells a launch-count
    # cause from a wall-clock one.
    python3 - "$WORK/soak/serial.log" "$REDIR" <<'PY'
import re, sys
lines = open(sys.argv[1], 'rb').read().decode('utf-8', 'replace').splitlines()
canary, first, ts, boot = sys.argv[2], None, None, None
tspat = re.compile(r'\d{4}-\d\d-\d\d \d\d:\d\d:\d\d UTC')
seen_ts = None
for i, l in enumerate(lines):
    m = tspat.search(l)
    if m:
        seen_ts = m.group(0)
        if boot is None:
            boot = seen_ts
    # strip() and not an anchor: the guest console ends its lines with CR.
    if first is None and (l.strip() == canary or l.strip() == 'rc.distros-wl'
                          or l.strip() == 'os-release'):
        first, ts = i, seen_ts
if first is None:
    raise SystemExit
win = cyc = None
for l in lines[:first]:
    mm = re.search(r'windows (\d+)', l)
    if mm:
        win = mm.group(1)
cyc = sum(1 for l in lines[:first] if l.startswith('SOAKCENSUS cycle'))
print('  ..    it first failed at %s (the guest booted at %s)' % (ts, boot))
print('  ..    by then: %s windows open, %d launch cycles completed' % (win, cyc))
PY
fi

say "IS /var/log GROWING? (candidate 3, measured rather than reasoned)"
log_growth "$WORK/soak/serial.log" | while read -r nm s0 s1 dl rate; do
    printf '  ..    %-20s %10s -> %-10s  %+d bytes  %s B/s\n' "$nm" "$s0" "$s1" "$dl" "$rate"
done
# THE CEILING, AND WHY IT IS WHERE IT IS. wsysd's diagnostics are one-shot: the
# coverage warning dedups per wid into a 64-slot table that FAILS CLOSED when
# full (user/wsysd.ad report_uncovered), and the image-miss warning into a
# 16-slot one (report_image_misses). So the whole of wsysd.log over a session
# should be a bounded startup banner plus at most those, and a session that
# opens and closes windows for an hour should add essentially nothing.
#
# 100 B/s is 360 KB an hour: far above anything a bounded banner can produce,
# and far below what one line per 16 ms frame would be (a 60-byte line at 60 Hz
# is 3.6 KB/s, thirty-six times this). It separates "bounded" from "per-frame"
# by more than an order of magnitude in both directions, which is what a
# threshold has to do to be worth asserting.
WLOG_RATE=$(log_growth "$WORK/soak/serial.log" | awk '$1=="wsysd.log"{print $5}')
WLOG_RATE="${WLOG_RATE:-}"
if [ -z "$WLOG_RATE" ]; then
    bad "the census never reported a size for wsysd.log -- the log-growth question was NOT ANSWERED by this run"
elif awk "BEGIN{exit !($WLOG_RATE < 100)}"; then
    ok "/var/log/wsysd.log grew at ${WLOG_RATE} B/s over the driven soak -- the compositor is not logging per frame"
else
    bad "/var/log/wsysd.log GREW AT ${WLOG_RATE} B/s ON THE BOOT MEDIUM while the desktop was being used -- candidate 3 is real; the repeating lines are below"
fi

say "WHAT REPEATED ON THE CONSOLE (the six most frequent lines)"
repeating_lines "$WORK/soak/serial.log" | sed 's/^/  ..    /'

say "WHAT THE STICK WAS ASKED TO WRITE, WITH SOMEBODY USING IT"
info "$S_WRB bytes, $S_WROPS write operations, $S_WRFL cache flushes over ${SECS}s"
info "that is $(( S_WRB / (SECS > 0 ? SECS : 1) )) B/s and $(awk "BEGIN{printf \"%.2f\", $S_WRFL/($SECS)}") device commits a second"

# ---------------------------------------------------------------------------
say "DID THE WORKLOAD SURVIVE THE WINDOW? (asked FIRST, because the verdict below cannot ask it)"
# ---------------------------------------------------------------------------
# THE HOLE THIS CLOSES, AND IT WAS MEASURED IN THIS FILE'S OWN 3-HOUR ARM.
#
# `guest_max_gap` is the verdict, and rightly so -- the host's sampling falls
# behind a fast-growing serial log and has reported a 111 s "silence" on a
# perfectly healthy guest. But it measures THE LARGEST JUMP BETWEEN TWO
# CONSECUTIVE GUEST TIMESTAMPS, and A RUN THAT SIMPLY STOPS HAS NO SUCH JUMP.
# There is no second timestamp to subtract from. So a workload that dies at six
# minutes into a three-hour soak leaves a small max-gap behind it and the gate
# says `userspace never went quiet`.
#
# THAT IS NOT HYPOTHETICAL. MEASURED TWICE, ON TWO RUNS THAT DIFFER IN THE ONE
# SETTING THAT WAS SUPPOSED TO EXPLAIN IT:
#
#                                  TYPE=1, 10800s      TYPE=0, 7200s
#     heartbeats printed                  352                352
#     the window wants                 ~10000              ~6700
#     workload stopped at            about t=380s       about t=380s
#     `command not found` lines             (15 prompts)        0
#
# THE SAME NUMBER, 352, WITH THE KEYBOARD OFF. The first run's console did show
# the hand's `hamnix soak <n>` echoing a character at a time at PID 1's
# interactive prompt, and that is a real hazard this file's drive_desktop
# already documents -- but it is NOT what stops the workload, because the run
# with no typing at all stops at the same heartbeat count at the same time. AN
# EARLIER VERSION OF THIS COMMENT SAID THE TYPING WAS THE CAUSE; the second run
# refuted it, and the wrong sentence is recorded here rather than quietly
# deleted.
#
# WHAT THE STOP ACTUALLY LOOKS LIKE, off the second run, all measured:
#
#     sysrq-w (Show Blocked State)  NAMED NO TASKS AT ALL -- nothing is in
#                                   uninterruptible sleep, so it is not an I/O
#                                   block
#     sysrq-t                       PID 1 hamsh state:S inside do_sys_poll
#     the screen                     FROZEN: one identical frame hash for every
#                                   sample from the stop to the end of the run,
#                                   over ten minutes
#     vCPU time (host-side)          308 ticks/8s at the trip, and 9 ticks/8s
#                                   twelve minutes later -- the machine winds
#                                   down to executing almost nothing
#     the last thing the guest did   stopped PART WAY THROUGH a census, after
#                                   `tail -6 /var/log/wsysd.log` and before
#                                   the block could close
#     what was running               40-odd live app processes and several
#                                   ZOMBIE hamsh, windows=42 -- the close sweep
#                                   frees WINDOWS and not PROCESSES
#
# KERNEL ALIVE, USERSPACE WEDGED, AT ABOUT SIX MINUTES, IN A VM, THREE TIMES --
# 10800 s / TYPE=1, 7200 s / TYPE=0 and 900 s / TYPE=0 all stopped at EXACTLY
# 352 heartbeats. That is the shape of the owner's report.
#
# AND IT IS COUNTED IN LAUNCHES, NOT IN SECONDS. Halving the dwell halves the
# time each application is left open without changing how many get opened per
# cycle, so it separates a clock from a counter. Run:
#
#                       app launches at the stop    heartbeats at the stop
#     DWELL=8 (default)          44                        352
#     DWELL=4                    48                        196
#
# The launch count moved by 9 percent and the heartbeat count by 44. WHATEVER
# RUNS OUT IS COUNTED IN THINGS OPENED, NOT IN TIME PASSED. The window count at
# the stop was 42 and 44 in the two configurations.
#
# THE RESOURCE IS NAMED, AND IT IS NOT A TABLE IN THE COMPOSITOR
# ==============================================================
# It is hamsh's VALUE-CELL ARENA, and the answer was printed on the console of
# BOTH preserved runs, one line after the last census:
#
#     SOAKCENSUSEND
#     hamsh: runtime error: value arena exhausted (VAL_MAX=16384 live cells)
#            — split the loop
#     hamsh: uncaught exception: value arena exhausted ...
#     [hamsh:stage-06] rc-done
#     [hamsh:stage-07] loop-enter
#     hamsh$ [hamsh:stage-08] ed-readline-first
#
# (wedged-typing-off-serial.log:7359 and derailed-serial.log:7362.) PID 1's rc
# raised, unwound out of the `while 1 == 1` loop, and dropped into its
# INTERACTIVE PROMPT -- which is why sysrq-t found PID 1 in do_sys_poll, why
# sysrq-w named no blocked task, and why the vCPU wound down to 9 ticks per 8 s
# instead of spinning. The kernel was fine. The workload's interpreter had died.
#
# WHY: `_maybe_recycle_arenas` was called from ONE place, run_source at
# `_rs_depth == 1` -- BETWEEN complete top-level inputs. THE RC OF THIS FILE IS
# ONE INFINITE `while`, so the collector never ran again after the loop was
# entered and every temporary the body allocated was stranded.
#
# MEASURED ON THE HOST BUILD, directly, with the shell's own `arenas` readout
# sampled once per iteration:
#
#     nodes   FLAT at 20/16384      (the body's AST is parsed once, re-used)
#     vals    +4 to +6 PER ITERATION, monotonically, gc count never moving
#     str     +7 to +11 bytes per iteration
#
# A resource that climbs and never falls. `while i < 5000 { s = s + i ;
# i = i + 1 }` -- two integers, nothing live but two integers -- died at
# ITERATION 2048 and printed a partial sum.
#
# AND THAT IS WHY THE STOP WAS COUNTED IN LAUNCHES AND NOT IN SECONDS. It was
# never counted in launches; it was counted in STATEMENTS EXECUTED, and the
# per-cycle census plus the 58-command close sweep dominate the statement count
# so heavily that halving the dwell barely moved the number of cycles reached.
# Statements to the wall on each arm, using the rc this file generates:
#
#                cycles reached   statements/cycle   statements to the wall
#     DWELL=8          11              ~424                  ~4664
#     DWELL=4          12              ~344                  ~4128
#
# Within 13 percent of each other, i.e. a per-statement constant -- which is
# what "vals climbs 4-6 per iteration" predicts and what "a 64-slot table"
# does not.
#
# THE FIX IS IN THE SHELL: user/hamsh.ad's gc_collect_minor, a values-only
# collection that exec_block can run at a statement boundary INSIDE a loop
# (nodes are left frozen, because every evaluator frame above is holding raw
# node ids). scripts/test_hamsh_loop_arena_host.sh is its gate: 60000
# iterations, exact answers, two mutant builds that must fail.
#
# WHAT IS STILL NOT ESTABLISHED, and must not be claimed:
#   * THAT THIS IS THE OWNER'S LENOVO FAULT. His session is not running a
#     thousand-iteration rc loop. This is the defect that stopped THIS GATE.
#   * THAT THE COMPOSITOR WAS HEALTHY WHEN THE RC DIED. The screen stayed
#     frozen for 700 s afterwards and the vCPU went nearly idle, which is
#     consistent with "nothing was asking the desktop for anything" but is not
#     the same as measuring that wsysd was alive. NOTE for whoever reads the
#     old logs: every `[panelbeacon]` line in serial.log arrives via the
#     census's `tail -6 /var/log/panel.log`, NOT live from the panel -- so the
#     beacons stopping when the census stopped says nothing about the panel.
#     That trap cost time here.
#   * THAT 64-SLOT fdns EXHAUSTION IS RETIRED. It is a real second wall this
#     file's header measured at ~118 launches; MAX_SLOTS is 1024 now, and the
#     3-hour arm has not been re-run far enough to meet it again.
#
# WHAT THE VERDICT SAID ABOUT IT, AND THIS IS THE PART THAT MATTERS. On that
# run, before the coverage check existed, this file printed:
#
#     PASS  userspace never went quiet for as long as 20s across 7200s of being
#           used
#     FAIL  THE SCREEN WAS FROZEN FOR 700s
#
# THE NAMED VERDICT -- the guest-clock gap, the number this file calls THE
# VERDICT NUMBER -- SAID USERSPACE NEVER WENT QUIET, about a machine whose
# userspace stopped at t=380 s of a 7200 s window. It is not that the number was
# miscomputed; it is that a run which STOPS has no gap between two timestamps to
# measure, so the metric is structurally incapable of seeing this failure and
# answers success-shaped.
#
# IT IS FAIR TO SAY THE GATE WAS NOT BLIND: the screen probe caught it
# independently and the run came out red. But it came out red for the picture
# and not for the workload, and nothing said the workload had died -- so the
# obvious reading of that output is "a repaint stall", which is a much smaller
# claim than the truth. Nothing asserted on the heartbeat count at all; `S_HB`
# was printed and never checked. THE COVERAGE CHECK BELOW MAKES THE DEATH OF THE
# WORKLOAD ITS OWN RED LINE instead of leaving it to be inferred from a second
# probe that happens to agree.
#
# A GAP MUST NEVER ANSWER SOMETHING SUCCESS-SHAPED. So the coverage is asserted
# before the verdict is read, and if the workload did not survive, the wedge
# verdict below is worth nothing whatever it says.
#
# THE FLOOR IS ARITHMETIC AND DELIBERATELY SLACK. The guest loop prints one
# heartbeat per `sleep 1` plus a census per cycle, which measured 0.93/s on the
# run above. Half of one per second over the window is a floor no live workload
# can be under and a dead one cannot reach.
HB_FLOOR=$(( SECS / 2 ))
if [ "${S_HB:-0}" -ge "$HB_FLOOR" ]; then
    ok "the guest printed $S_HB heartbeats over ${SECS}s (floor $HB_FLOOR) -- the workload ran for the whole window, so the verdict below is about the window"
else
    bad "THE WORKLOAD DIED INSIDE THE WINDOW: only ${S_HB:-0} heartbeats in ${SECS}s against a floor of $HB_FLOOR. Whatever the gap verdict below says, this gate measured a machine that stopped running its own workload. Read $WORK/soak/wedge.txt for the idle-or-spinning classification and $WORK/soak/serial.log for the sysrq dumps taken at the trip"
fi
# AND THE CAUSE, NAMED SEPARATELY, because "the workload died" and "the hand
# typed into PID 1" are different failures and the fix differs. hamsh answers an
# unknown word with `command not found`, so one of those lines is a keystroke
# that reached a shell prompt instead of a window.
# NO `|| printf 0`. `grep -c` PRINTS 0 AND EXITS 1 when it matches nothing, so
# the fallback fires on the success path too and the variable becomes the two
# characters "0\n0" -- which then printed as `FAIL  0` on its own line with the
# real message orphaned below it. Measured in this file's own output.
# AND THE ARENA, ASKED BEFORE ANYTHING ELSE ABOUT THE CAUSE, because for three
# runs this file printed "a wedge" about a machine whose shell had said in
# plain words what had happened to it. Proved above (ARM 0f) against a planted
# log that contains the message and one that does not.
AREXH=$(grep -ac 'arena exhausted\|arena full\|element pool exhausted' \
        "$WORK/soak/serial.log" 2>/dev/null)
AREXH="${AREXH:-0}"
if [ "${AREXH:-0}" = 0 ]; then
    ok "hamsh never exhausted an arena during the run -- the rc's own interpreter survived the window"
else
    bad "PID 1's SHELL RAN OUT OF ARENA $AREXH times and the rc died with it -- this is NOT a kernel wedge. hamsh's collector used to be reachable only between top-level inputs, so a script that is one \`while\` loop never collected; see scripts/test_hamsh_loop_arena_host.sh. Grep $WORK/soak/serial.log for 'arena' and read the lines after the last SOAKCENSUSEND"
fi
NOTFOUND=$(grep -ac 'command not found' "$WORK/soak/serial.log" 2>/dev/null)
NOTFOUND="${NOTFOUND:-0}"
if [ "${NOTFOUND:-0}" = 0 ]; then
    ok "and no 'command not found' on the console, so nothing the hand typed reached PID 1's shell"
else
    bad "$NOTFOUND 'command not found' lines on the console: THE HAND'S TYPING REACHED PID 1'S INTERACTIVE PROMPT. That is noise in this run's own log, and on the evidence so far it is NOT what stops the workload -- a run with HAMLINUX_SOAK_TYPE=0 stopped identically. Re-run with it set to 0 so the log can be read"
fi

# ---------------------------------------------------------------------------
say "DID ANYTHING WEDGE?"
# ---------------------------------------------------------------------------
info "longest gap in the guest's own clock: ${S_GAP}s   longest frozen picture: ${S_FRZ}s   heartbeats: $S_HB"
if [ "$S_GAP" -lt "$WEDGE_S" ]; then
    ok "userspace never went quiet for as long as ${WEDGE_S}s across ${SECS}s of being used"
else
    bad "USERSPACE WENT SILENT FOR ${S_GAP}s while the desktop was being driven -- see $WORK/soak/wedge.txt and the sysrq task dump in serial.log"
fi
if [ "$S_FRZ" -lt "$FREEZE_S" ]; then
    ok "the picture never stood still for as long as ${FREEZE_S}s"
else
    bad "THE SCREEN WAS FROZEN FOR ${S_FRZ}s -- see $WORK/soak/wedge.ppm"
fi
if [ "$S_WEDGED" = 1 ]; then
    printf '\n  !!    A WEDGE WAS DETECTED AND NAMED. The blocked-task dump is in\n'
    printf '  !!    %s/serial.log after the sysrq banner.\n' "$WORK/soak"
fi

printf '\n%d PASSED, %d FAILED\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
