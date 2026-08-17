#!/usr/bin/env bash
#
# REGISTRATION, 2026-08-17. Until this date scripts/test_gate_registration.sh
# globbed only scripts/test_*.sh, so this directory was invisible to the gate
# against unregistered gates and every file in it read as coverage without
# being coverage. This gate is ON-DEMAND: not in ci_battery_manifest.txt
# because it boots a machine under `qemu-system-x86_64`.
#
# tests/linux/vcpu_time.sh — HOW MUCH CPU IS THE GUEST ACTUALLY BURNING?
# A probe that asks the HOST KERNEL, not the guest, and needs nothing from it.
#
# WHAT IT IS FOR, AND WHY THE FOUR PROBES IN soak_desktop.sh DO NOT COVER IT
# =========================================================================
# tests/linux/soak_desktop.sh already carries four probes and all four are
# proved by run arms rather than argued (0a-0e). They answer, between them,
# "did userspace stop?" (the guest-clock heartbeat), "did the picture stop?"
# (screendump hashes off the QEMU monitor), "which processes exist and what is
# the compositor's frame counter doing?" (the guest's own census on the
# console), and "who is blocked?" (alt-sysrq-w/t/l fired from the host).
#
# THEY DO NOT ANSWER: IS THE MACHINE IDLE OR IS IT SPINNING? Those are two very
# different wedges with the same signature in every probe above -- heartbeat
# silent, screen frozen -- and they point at different code:
#
#     ~0 vCPU time   every runnable task is blocked. A resource nobody can get:
#                    an I/O stall, a lock held by a blocked holder, a device
#                    that stopped answering. This is what a USB mass-storage
#                    reset looks like from outside.
#     ~100% per vCPU something is spinning: a livelock, a busy-wait on a flag
#                    that will not change, a retry loop with no backoff --
#                    user/wsysd.ad's unguarded per-frame open of /dev/fb is
#                    exactly this shape.
#
# AND IT SHARES NO CHANNEL WITH THE GUEST, WHICH IS THE OTHER REASON IT IS
# HERE. The heartbeat, the per-process census AND the sysrq task dump all land
# on the same wire: ttyS0, into serial.log. They are three questions down one
# pipe. This probe reads /proc/<qemu-pid>/task/<tid>/stat on the HOST -- the
# host kernel's own accounting of threads it schedules -- so it keeps answering
# for a guest that has stopped being able to say anything at all, including one
# whose console is the thing that is stuck.
#
# WHY NOT SAMPLE THE GUEST'S RIP, WHICH IS THE OBVIOUS IDEA
# ========================================================
# IT WAS TRIED FIRST AND IT DOES NOT WORK, and that is written down so nobody
# spends the afternoon again. HMP `info registers` reports RIP host-side and
# costs nothing. MEASURED, on an OVMF guest, four samples a second apart while
# it was RUNNING and four more while it was halted by the monitor's `stop`:
#
#     RUNNING   RIP=000000001e957387  (x4, identical)
#     STOPPED   RIP=000000001e957387  (x4, identical)
#
# A guest sitting in a tight loop has one RIP whether it is executing it a
# billion times a second or not executing at all. RIP CANNOT TELL RUNNING FROM
# HALTED, which is the only distinction this probe exists to make. CPU time
# can, on the same guest, in the same experiment -- see the numbers below.
#
# THE INSTRUMENT, AND WHY THE THREAD IDS COME FROM QMP
# ===================================================
# QEMU does not rename its vCPU threads on this host: all seven threads of a
# running soak QEMU report `comm` = `qemu-system-x86`, so picking them by name
# selects nothing and picking "the busiest two" is a guess that would quietly
# be wrong on a guest that is idle -- which is half the state space being
# measured. QMP's `query-cpus-fast` returns `thread-id` per vCPU and is the
# authoritative answer.
#
# Ticks are utime+stime out of /proc/<pid>/task/<tid>/stat (fields 14 and 15),
# summed over the vCPU threads. 100 ticks = one second of one core.
#
# PROVED, RUN, AND THESE ARE THE NUMBERS -- an OVMF guest, 2 vCPUs, 8-second
# windows, `vcpu_selftest` below:
#
#     RUNNING   801 ticks / 8 s      (two cores, both busy)
#     STOPPED     0 ticks / 8 s      (monitor `stop`: vCPUs halted)
#     RESUMED   801 ticks / 8 s
#
# Zero and eight hundred, on the same guest, minutes apart. `stop` and not
# SIGSTOP, for the reason soak_desktop.sh gives: SIGSTOP would freeze QEMU too,
# and then the host would be measuring a stopped QEMU rather than a stopped
# guest.
#
# WHAT IT CANNOT DO, said here rather than found out later:
#   * it cannot name a process. It says WHAT KIND of wedge, not WHOSE. The
#     sysrq dump is still the thing that gives it a name, and this probe's job
#     is to say which dump to read and what to expect in it.
#   * a 2-vCPU guest where ONE core spins and the other blocks reads as ~50%,
#     which is neither shape cleanly. The per-vCPU breakdown is printed for
#     that reason rather than only the sum.
#
# Usage:  . tests/linux/vcpu_time.sh          # as a helper
#         tests/linux/vcpu_time.sh selftest   # runs the proof above and exits
#
# API:
#   vcpu_tids <qmp.sock>            -> the vCPU thread ids, space separated
#   vcpu_ticks <qemu-pid> <tids>    -> total utime+stime ticks across them
#   vcpu_ticks_each <qemu-pid> <tids> -> one "<tid> <ticks>" line per vCPU

# vcpu_tids <qmp.sock> -- the vCPU thread ids, from QEMU itself.
vcpu_tids() {
    python3 - "$1" <<'PY' 2>/dev/null
import json, socket, sys
s = socket.socket(socket.AF_UNIX)
s.settimeout(10)
s.connect(sys.argv[1])
f = s.makefile('rwb')
f.readline()                                   # the greeting
f.write(b'{"execute":"qmp_capabilities"}\n'); f.flush(); f.readline()
f.write(b'{"execute":"query-cpus-fast"}\n');  f.flush()
r = json.loads(f.readline())
print(' '.join(str(c['thread-id']) for c in r['return']))
PY
}

# vcpu_ticks <qemu-pid> <tid...> -- utime+stime summed over the vCPU threads.
# A thread that has gone away contributes nothing rather than aborting the
# sample: a QEMU that exited mid-run is the caller's finding, not this
# function's error.
vcpu_ticks() {
    local pid="$1"; shift
    local t s=0 v
    for t in "$@"; do
        v=$(awk '{print $14+$15}' "/proc/$pid/task/$t/stat" 2>/dev/null) || v=0
        s=$(( s + ${v:-0} ))
    done
    printf '%s\n' "$s"
}

# vcpu_ticks_each <qemu-pid> <tid...> -- per-vCPU, because one core spinning
# while the other blocks averages to a number that is neither shape.
vcpu_ticks_each() {
    local pid="$1"; shift
    local t v
    for t in "$@"; do
        v=$(awk '{print $14+$15}' "/proc/$pid/task/$t/stat" 2>/dev/null) || v=0
        printf '%s %s\n' "$t" "${v:-0}"
    done
}

# ---------------------------------------------------------------------------
# THE PROOF. Run, not described. A probe that could not tell a halted guest
# from a running one would report "the machine was idle" for every wedge and
# "the machine was idle" for every healthy run, and the two would look the
# same.
# ---------------------------------------------------------------------------
vcpu_selftest() {
    local work; work="$(mktemp -d --tmpdir vcpu-selftest.XXXXXX)"
    local P=0 F=0
    _ok()  { P=$((P+1)); printf '  PASS  %s\n' "$*"; }
    _bad() { F=$((F+1)); printf '  FAIL  %s\n' "$*"; }

    command -v qemu-system-x86_64 >/dev/null || { _bad "need qemu-system-x86_64"; return 1; }
    command -v socat >/dev/null || { _bad "need socat"; return 1; }
    [ -f /usr/share/OVMF/OVMF_CODE_4M.fd ] || { _bad "need OVMF"; return 1; }
    cp /usr/share/OVMF/OVMF_VARS_4M.fd "$work/VARS.fd"

    # A GUEST WITH NOTHING TO BOOT IS THE RIGHT GUEST HERE. The subject is the
    # host's accounting of vCPU threads; what those vCPUs are executing is
    # irrelevant, and OVMF's own boot loop keeps them busy, which is what makes
    # the RUNNING window a large number rather than a small one.
    qemu-system-x86_64 -m 512 -smp 2 -display none -enable-kvm -cpu host \
        -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
        -drive "if=pflash,format=raw,unit=1,file=$work/VARS.fd" \
        -monitor "unix:$work/mon.sock,server,nowait" \
        -qmp "unix:$work/qmp.sock,server,nowait" >"$work/qemu.out" 2>&1 &
    local vm=$!
    sleep 6

    local tids; tids=$(vcpu_tids "$work/qmp.sock")
    if [ "$(printf '%s' "$tids" | wc -w)" = 2 ]; then
        _ok "QMP query-cpus-fast named both vCPU threads ($tids)"
    else
        _bad "query-cpus-fast returned '$tids' for a 2-vCPU guest -- the probe cannot find the threads it is supposed to sample"
        kill -KILL "$vm" 2>/dev/null; wait "$vm" 2>/dev/null; rm -rf "$work"; return 1
    fi

    local a b run stop res
    a=$(vcpu_ticks "$vm" $tids); sleep 8; b=$(vcpu_ticks "$vm" $tids); run=$(( b - a ))
    printf '%s\n' stop | timeout 10 socat - "UNIX-CONNECT:$work/mon.sock" >/dev/null 2>&1
    a=$(vcpu_ticks "$vm" $tids); sleep 8; b=$(vcpu_ticks "$vm" $tids); stop=$(( b - a ))
    printf '%s\n' cont | timeout 10 socat - "UNIX-CONNECT:$work/mon.sock" >/dev/null 2>&1
    a=$(vcpu_ticks "$vm" $tids); sleep 8; b=$(vcpu_ticks "$vm" $tids); res=$(( b - a ))
    printf '  ..    RUNNING %s ticks / 8 s   STOPPED %s   RESUMED %s\n' "$run" "$stop" "$res"

    # THE POSITIVE HALF: a running guest must show real time. Without it, a
    # zero at wedge time is a floor rather than a reading.
    [ "$run" -gt 100 ] \
        && _ok "a running guest burned $run ticks of vCPU time in 8 s, so a small number later is a reading" \
        || _bad "a running 2-vCPU guest showed only $run ticks in 8 s -- the sampler is not seeing vCPU time at all"
    # THE NEGATIVE HALF, and it is the one that matters: a halted guest must
    # show none. A sampler that reported the same number for both would call
    # every wedge healthy.
    [ "$stop" -lt 20 ] \
        && _ok "a guest halted by the monitor burned $stop ticks in the same 8 s -- the probe SEES a stopped machine" \
        || _bad "a HALTED guest still showed $stop ticks in 8 s -- the probe cannot tell running from stopped and is useless as a wedge instrument"
    [ "$res" -gt 100 ] \
        && _ok "and it came back to $res ticks after 'cont', so the zero was the guest and not the sampler dying" \
        || _bad "after 'cont' the guest showed only $res ticks -- the zero above may have been the instrument, not the machine"

    kill -KILL "$vm" 2>/dev/null; wait "$vm" 2>/dev/null
    rm -rf "$work"
    printf '\n%d PASSED, %d FAILED\n' "$P" "$F"
    [ "$F" = 0 ]
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-selftest}" in
        selftest) vcpu_selftest; exit $? ;;
        *) printf 'usage: %s [selftest]\n' "$0"; exit 2 ;;
    esac
fi
