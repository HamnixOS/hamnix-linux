#!/usr/bin/env bash
# wsys_zombie_strand.sh — A CORPSE MUST NOT HOLD A WHOLE SEGMENT HOSTAGE.
#
# WHAT THIS GATE IS FOR
# =====================
# user/linux-wsys.c's shm_seg_is_live() runs at ATTACH, before the mapping, and
# its answer decides whether a binary whose WSYS_VERSION differs from the
# segment's REFUSES to attach ("it is a LIVE window-system session ... nothing
# has been changed", errno EPROTO) or re-initialises it.
#
# Until 2026-08-18 it was the LAST kill(pid, 0) liveness test in that file --
# the same wrong question win_reap_dead() was fixed for the day before.
# kill(2) SUCCEEDS ON A ZOMBIE, so a segment whose only window was owned by a
# corpse read as a live desktop and a version-mismatched program refused it.
#
# THAT WAS MEASURED BEFORE IT WAS CHANGED, and this gate is that measurement,
# kept. It matters because shm_seg_is_live() is reached BEFORE anything sweeps
# the table: win_reap_dead() runs inside a process that has already attached,
# so the FIRST program to attach after an update meets the rows exactly as the
# dead owner left them, used=1 and all.
#
# THE THREE ARMS
# ==============
#   GREEN  (default)              zombie owner, version mismatch -> ATTACHES.
#   RED    HAMWSYS_LIVENESS=kill  the identical setup -> REFUSED.
#   The red arm restores the exact predicate that shipped before, so it is not
#   a simulation of the bug, it IS the bug, running. An assertion that cannot
#   fail is not an assertion.
#
# PLUS TWO CONTROLS ON THE REFUSAL PATH ITSELF, because "it attached" means
# nothing unless a refusal was shown to be possible and to be about liveness:
#   POSITIVE  a RUNNING owner + version mismatch must still be REFUSED.
#   NEGATIVE  the same version mismatch with NO used row must ATTACH.
#
# WHAT IT DOES NOT ASSERT
# =======================
#  * Anything about pid recycling: a corpse whose pid number was reused reads
#    as live and the segment is kept, deliberately.
#  * That /proc is present. Without it pid_liveness() falls back to the old
#    kill(2) probe and answers UNKNOWN for anything but ESRCH, so the segment is
#    KEPT -- the old behaviour, on purpose. This gate runs where /proc exists.
#  * Anything about a compositor. No wsysd runs.
#
# Offscreen, no framebuffer, no /dev/dri, no device touched. NO QEMU.
set -uo pipefail
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ" || exit 1

pass=0; fail=0
ok()   { printf 'strand: PASS %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf 'strand: FAIL %s\n' "$*"; fail=$((fail+1)); }
note() { printf 'strand: .... %s\n' "$*"; }

OUT="${HAMLINUX_OUT:-$(mktemp -d /tmp/zstrand.XXXXXX)}"
mkdir -p "$OUT/bin"

command -v gcc >/dev/null 2>&1 || { echo "strand: SKIP no gcc"; exit 0; }
gcc -Wall -O1 -o "$OUT/bin/zparent" tests/linux/zombie_owner_parent.c \
    >"$OUT/zparent.log" 2>&1 || {
    echo "strand: FATAL zombie_owner_parent.c did not build"
    sed 's/^/== /' "$OUT/zparent.log"; exit 1; }

for t in cat:user/cat.ad wsys_hold:tests/linux/wsys_hold.ad; do
    n="${t%%:*}"
    [ -x "$OUT/bin/$n" ] && continue
    scripts/hamlinux_build.sh "${t#*:}" "$OUT/bin/$n" >"$OUT/build.$n.log" 2>&1 || {
        echo "strand: FATAL ${t#*:} did not build"; tail -20 "$OUT/build.$n.log"; exit 1; }
done
BIN="$OUT/bin"
note "built zparent, cat, wsys_hold into $BIN"

# THE VERSION IS READ FROM THE SOURCE, NEVER TYPED: a gate that hardcodes 8
# starts lying the day WSYS_VERSION becomes 9.
CURVER=$(grep -m1 '^#define WSYS_VERSION' user/linux-wsys.c | awk '{print $3}')
OLDVER=$((CURVER - 1))
[ "$CURVER" -ge 2 ] 2>/dev/null || { echo "strand: FATAL could not read WSYS_VERSION"; exit 1; }
note "WSYS_VERSION = $CURVER; segments will be forced to $OLDVER"
NPROC_HOST=$(ls -d /proc/[0-9]* 2>/dev/null | wc -l)
note "host process table: $NPROC_HOST processes"

seg_hdr() { python3 -c '
import struct, sys
with open(sys.argv[1], "rb") as f:
    m, v = struct.unpack("<II", f.read(8))
print(f"magic=0x{m:08x} version={v}")' "$1"; }

downgrade() { python3 -c '
import struct, sys
with open(sys.argv[1], "r+b") as f:
    f.seek(4); f.write(struct.pack("<I", int(sys.argv[2])))' "$1" "$2"; }

# make_owner ARM MODE  (MODE: zombie | alive)
make_owner() {
  local arm="$1"
  local mode="$2"
  local W="$OUT/run/$arm"
  rm -rf "$W"; mkdir -p "$W"; : > "$W/script"
  mkfifo "$W/trigger" || return 90
  (
    export HAMWSYS="$W/seg"
    export ZOP_HOLDLOG="$W/hold.log"
    exec "$BIN/zparent" "$BIN/wsys_hold" "$W/script" \
         <"$W/trigger" >"$W/zop.log" 2>"$W/zop.err"
  ) &
  echo $! > "$W/zpid"
  # HOLD THE FIFO OPEN ON A FIXED FD FOR THE WHOLE ARM. Closing it is an EOF on
  # zparent's read, and zparent reads EOF as "go ahead and kill the holder" --
  # so a version of this that closed the fd at the end of setup silently turned
  # the RUNNING-owner control into a second zombie arm, and the control then
  # passed or failed on a race. MEASURED: it failed. It is closed in stop_arm,
  # after the attach.
  exec 9>"$W/trigger"
  local i
  for i in $(seq 1 200); do grep -q '^ALIVE ' "$W/zop.log" 2>/dev/null && break; sleep 0.1; done
  awk '/^OWNER /{print $2}' "$W/zop.log" > "$W/owner"
  head -1 "$W/hold.log" 2>/dev/null | tr -dc '0-9' > "$W/wid"
  [ -s "$W/owner" ] || { exec 9>&-; return 91; }
  if [ "$mode" = zombie ]; then
    printf '\n' >&9
    for i in $(seq 1 200); do grep -q '^ZOMBIE ' "$W/zop.log" 2>/dev/null && break; sleep 0.1; done
  fi
  awk '{print $3}' "/proc/$(cat "$W/owner")/stat" 2>/dev/null > "$W/state"
  return 0
}

# Kill by PID, never by pattern -- `pgrep -f` has given a wrong answer eight
# times in this tree and it matches the searcher's own command line.
stop_arm() {
  exec 9>&- 2>/dev/null || true
  local z; z=$(cat "$OUT/run/$1/zpid" 2>/dev/null)
  [ -n "${z:-}" ] && kill "$z" 2>/dev/null
  wait "$z" 2>/dev/null
  return 0
}

# attach ARM [kill] -> $W/attach.rc, attach.out, attach.err
attach() {
  local W="$OUT/run/$1"
  ( export HAMWSYS="$W/seg"
    [ "${2:-}" = kill ] && export HAMWSYS_LIVENESS=kill
    "$BIN/cat" /dev/wsys ) > "$W/attach.out" 2>"$W/attach.err"
  echo $? > "$W/attach.rc"
}

refused() {
  local W="$OUT/run/$1"
  grep -qi 'REFUSING to attach' "$W/attach.err" 2>/dev/null
}

# state_is_Z ARM -> assert the premise of the arm, on this kernel, this run.
state_is_Z() {
  local W="$OUT/run/$1" st
  st=$(cat "$W/state" 2>/dev/null)
  if [ "$st" = "Z" ]; then
    ok "$1: the owner $(cat "$W/owner") really is a ZOMBIE (/proc state Z)"
    return 0
  fi
  bad "$1: the owner never became a zombie (state '${st:-?}') -- every check in this arm is measuring something other than the case under test"
  return 1
}

# ================================================================= GREEN
if make_owner green zombie; then
  W="$OUT/run/green"
  state_is_Z green
  if kill -0 "$(cat "$W/owner")" 2>/dev/null; then
    ok "green: kill($(cat "$W/owner"), 0) SUCCEEDS on that corpse -- which is why the old predicate could not see it"
  else
    bad "green: kill(pid,0) failed on the corpse; this kernel does not behave as the fix assumes"
  fi
  note "green: segment before downgrade: $(seg_hdr "$W/seg")"
  downgrade "$W/seg" "$OLDVER"
  note "green: segment forced to $(seg_hdr "$W/seg")"
  attach green
  note "green: attach rc=$(cat "$W/attach.rc") err='$(head -c 160 "$W/attach.err" | tr '\n' ' ')'"
  if refused green; then
    bad "green: a segment whose ONLY used row is owned by a CORPSE was REFUSED -- shm_seg_is_live still reads a zombie as a live session and strands the segment"
  elif [ "$(cat "$W/attach.rc")" = 0 ]; then
    ok "green: a version-$OLDVER segment whose only owner is a corpse ATTACHES (rc 0) -- the dead session does not hold it"
  else
    bad "green: the attach failed with rc $(cat "$W/attach.rc") and no refusal message -- something other than the case under test went wrong"
  fi
else
  bad "green: could not be set up -- no reading was taken"
fi
stop_arm green

# =================================================================== RED
# THE NEGATIVE CONTROL, RUN. Same code, same scenario, old predicate.
if make_owner red zombie; then
  W="$OUT/run/red"
  state_is_Z red
  downgrade "$W/seg" "$OLDVER"
  attach red kill
  note "red: attach rc=$(cat "$W/attach.rc") err='$(head -c 160 "$W/attach.err" | tr '\n' ' ')'"
  if refused red; then
    ok "red: NEGATIVE CONTROL RED AS REQUIRED -- under HAMWSYS_LIVENESS=kill the identical corpse-owned segment IS refused, so the green arm above is attributable to the /proc test and nothing else"
  else
    bad "red: the negative control did NOT reproduce the refusal, so the green arm proves nothing about which predicate is running"
  fi
else
  bad "red: could not be set up -- the negative control did not run"
fi
stop_arm red

# ====================================================== POSITIVE CONTROL
# A RUNNING owner must still be refused, or "it attached" above is about a
# refusal path that does not work rather than about liveness.
if make_owner live alive; then
  W="$OUT/run/live"
  ST=$(cat "$W/state" 2>/dev/null)
  note "live: owner $(cat "$W/owner") state '${ST:-?}'"
  case "${ST:-?}" in
    Z|X|x|"?") bad "live: the owner is not running (state '${ST:-?}') -- this control is not measuring a live owner" ;;
    *) ok "live: the owner is RUNNING (state '$ST')" ;;
  esac
  downgrade "$W/seg" "$OLDVER"
  attach live
  note "live: attach rc=$(cat "$W/attach.rc") err='$(head -c 160 "$W/attach.err" | tr '\n' ' ')'"
  if refused live; then
    ok "live: POSITIVE CONTROL -- a version-$OLDVER segment with a RUNNING owner is still REFUSED; the refusal path works and the green arm is about liveness"
  else
    bad "live: POSITIVE CONTROL FAILED -- a LIVE session was not protected, which is a worse bug than the one this gate was written for"
  fi
else
  bad "live: positive control could not be set up"
fi
stop_arm live

# ====================================================== EMPTY CONTROL
# The same version mismatch with NO used row must attach, or the refusal is
# about the version alone and every arm above says nothing about owners.
W="$OUT/run/empty"; rm -rf "$W"; mkdir -p "$W"
( export HAMWSYS="$W/seg"; "$BIN/cat" /dev/wsys ) >/dev/null 2>&1
if [ -f "$W/seg" ]; then
  note "empty: fresh segment $(seg_hdr "$W/seg")"
  downgrade "$W/seg" "$OLDVER"
  attach empty
  note "empty: attach rc=$(cat "$W/attach.rc")"
  if refused empty; then
    bad "empty: a version-$OLDVER segment with NO used row was ALSO refused, so the refusal is about the version alone and the arms above are not about owners"
  else
    ok "empty: the same version mismatch with NO used row attaches (rc $(cat "$W/attach.rc")) -- the refusal is about the owner, not the version"
  fi
else
  bad "empty: no segment file was created; the control did not run"
fi

echo "strand: $pass PASSED / $fail FAILED (host process table $NPROC_HOST)"
[ "$fail" -eq 0 ] || exit 1
exit 0
