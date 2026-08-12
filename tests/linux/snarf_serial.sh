#!/usr/bin/env bash
# tests/linux/snarf_serial.sh — THE CLIPBOARD IS SOMETHING YOU CAN WAIT ON.
#
# The oracle for the generation counter added to `struct snarfshm`
# (user/linux-snarf.c), for the /dev/snarf.serial name that reads it, and for
# the two bridges that stopped polling by content because of it.
#
# QEMU-free. Xvfb and xclip stand in for "an X client inside a distribution
# namespace", exactly as tests/linux/xsnarf_bridge.sh does, and for the same
# reason: what user/xsnarfd.ad talks to is an X server on a unix socket, and
# nothing in the selection protocol knows whether pixels reach a screen.
#
# FOUR CLAIMS ARE MADE HERE AND EACH ONE FAILS LOUDLY IF THE SERIAL IS TAKEN
# AWAY. They are in the order of how much they are worth:
#
#   1. THE WAKE. A process parks in sys_waitfds on /dev/snarf.serial with a
#      five-second budget and is woken by ANOTHER PROCESS's copy in a fraction
#      of it -- and, with nobody writing, is NOT woken, which is the control
#      that stops "it returned immediately every time" from reading as success.
#      Then the thing that was actually asked for: user/xsnarfd.ad's WAKES PER
#      SECOND, measured by sampling /proc/<pid>/status voluntary_ctxt_switches
#      across a ten-second window. That is an instantaneous rate over a stated
#      interval. `ps` pcpu is a LIFETIME average and has misreported a number
#      in this project by 30x; it is not used here and must not be.
#
#   2. THE FALLBACK, WHICH IS THE PART THAT COULD ROT SILENTLY. A binary older
#      than the serial maps the same segment -- every v1 offset is frozen, so
#      it maps it correctly -- and writes the clipboard WITHOUT bumping
#      anything. It is simulated exactly: python mmaps the FIRST 131096 BYTES
#      ONLY, the v1 size, and stores through the mapping. An mmap store
#      generates no inotify event and no serial change, so a bridge that
#      trusted the serial alone would never see it. The assertion is that
#      xsnarfd converges anyway, inside its reconcile window, and pushes those
#      bytes into the X selection.
#
#   3. THE LAYOUT. The segment is 131120 bytes and the v1 prefix is 131096. The
#      same 131096-byte "old client" mapping is READ BACK through the shipped
#      toolkit paste path, so "the offsets did not move" is measured rather
#      than asserted from a struct definition.
#
#   4. THE COUNTER ITSELF. It bumps on a write; it bumps on a write of
#      IDENTICAL BYTES, which is the event a content comparison structurally
#      cannot see; CLIPBOARD and PRIMARY are independent; and an open of
#      /dev/snarf.serial for WRITING is refused rather than swallowed.
#
# NOTHING HERE TOUCHES THE HOST'S DISPLAY, SOUND OR /dev. It runs under a
# private mount namespace with a tmpfs over /tmp, so the display number and the
# X socket cannot collide with another agent's, and $HAMSNARF pins the segment
# for the same reason (docs/steam_namespace.md §11 -- the shared file that bit).
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  PASS  $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $*"; }
chk()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2] got [$3]"; fi }
has()  { if [ -n "$3" ] && [[ "$3" == *"$2"* ]]; then ok "$1"; else bad "$1: [$3] does not contain [$2]"; fi }
lt()   { if [ -n "$2" ] && [ "$2" -lt "$3" ] 2>/dev/null; then ok "$1 ($2 < $3)"; else bad "$1: [$2] is not below $3"; fi }
ge()   { if [ -n "$2" ] && [ "$2" -ge "$3" ] 2>/dev/null; then ok "$1 ($2 >= $3)"; else bad "$1: [$2] is not at least $3"; fi }

# THE TOOLS ARE CHECKED BY NAME AND THE ABSENCE IS NOT A PASS. A gate that
# quietly skips its own subject is the success-shaped failure NORTH_STAR names.
for t in Xvfb xclip xdpyinfo unshare python3; do
    command -v "$t" >/dev/null 2>&1 || {
        echo "[snarfser] CANNOT RUN: no $t on this host."
        echo "[snarfser] it is NOT passing, it did not run."
        exit 2
    }
done

OUT="${SNARFSER_TEST_OUT:-build/snarfser}"
mkdir -p "$OUT" || exit 1

echo "[snarfser] building the bridge and the probes ..."
build() {
    if ! scripts/hamlinux_build.sh "$1" "$OUT/$2.elf" >"$OUT/$2.build.log" 2>&1; then
        echo "[snarfser] FAIL: $1 did not build"; tail -30 "$OUT/$2.build.log"; exit 1
    fi
}
build user/xsnarfd.ad            xsnarfd
build tests/linux/snarfserial.ad snarfserial
build tests/linux/snarfcopy.ad   snarfcopy
build tests/linux/snarfpaste.ad  snarfpaste
echo "[snarfser] built"

# THE OLD CLIENT, in a file rather than a -c string so quoting cannot change
# what is measured. It maps the V1 SIZE ONLY and stores through the mapping:
# no write(2), so no inotify; no serial field in its map, so no bump. This is
# what a binary compiled before the serial existed does to this segment.
OLDC="$OUT/oldclient.py"
cat >"$OLDC" <<'PYEOF'
import mmap, os, struct, sys
# The v1 layout, frozen: magic u32, version u32, clip_len u64, prim_len u64,
# clip[65536], prim[65536].  131096 bytes and not one more -- mapping the
# serials would be cheating.
V1   = 24 + 2 * 65536
CLIP = 24
path, text = sys.argv[1], sys.argv[2].encode()
f = os.open(path, os.O_RDWR)
m = mmap.mmap(f, V1, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE)
m[CLIP:CLIP + len(text)] = text
m[8:16] = struct.pack('<Q', len(text))      # clip_len, published last
m.flush()
m.close()
os.close(f)
print("oldclient wrote", len(text))
PYEOF

BODY="$OUT/body.sh"
cat >"$BODY" <<'INNER'
set -u
OUT="$1"
SS="$OUT/snarfserial.elf"; CP="$OUT/snarfcopy.elf"; PA="$OUT/snarfpaste.elf"
BR="$OUT/xsnarfd.elf";     OLDC="$OUT/oldclient.py"
DPY=79

export HAMSNARF="$OUT/seg"
rm -f "$HAMSNARF"
mount -t tmpfs tmpfs /tmp 2>/dev/null || { echo "MOUNTFAIL"; exit 90; }
mkdir -p /tmp/.X11-unix
export DISPLAY=":$DPY"
XSOCK="/tmp/.X11-unix/X$DPY"

echo "BEGIN"

# --- 4. the counter itself, before anything else is running ---------------
echo "A $($SS read)"
echo "B $($CP 0 ALPHA >/dev/null; $SS read)"
# THE SAME BYTES AGAIN. A content comparison cannot see this and a serial must.
echo "C $($CP 0 ALPHA >/dev/null; $SS read)"
# PRIMARY moves its own counter and leaves CLIPBOARD's alone.
echo "D $($CP 1 BETA >/dev/null; $SS read)"
echo "E $($SS writeopen)"
echo "F $(stat -c %s "$HAMSNARF")"

# --- 1a. the wake, and its control ---------------------------------------
( sleep 1; "$CP" 0 WOKEN >/dev/null ) &
echo "G $($SS wait 6000)"
wait %1 2>/dev/null
# ... and with nobody writing it must NOT be woken. Without this line a device
# that reported ready instantly, for ever, would read as a pass.
echo "H $($SS wait 1200)"

# --- 3. the v1 prefix is where it always was ------------------------------
# The old client writes through a 131096-byte mapping; the shipped toolkit
# paste path reads it back. If a field had been added to the header instead of
# appended, this is the assertion that would come back as garbage.
J_BEFORE="$($SS read)"
python3 "$OLDC" "$HAMSNARF" OLD-CLIENT-BYTES >/dev/null
echo "I $($PA 0)"
# ... and it did NOT move the serial, which is the whole reason the bridges
# keep an unconditional reconcile. Compared to the sample taken an instant
# before rather than to a number written here: a hardcoded expectation would
# have to be re-derived every time a line is added above it, and one that is
# re-derived by hand is one that gets re-derived to whatever passes.
echo "J $J_BEFORE / $($SS read)"

# --- the bridge, from here on ---------------------------------------------
Xvfb ":$DPY" -screen 0 320x240x24 -nolisten tcp >>"$OUT/xvfb.log" 2>&1 &
XVFB=$!
i=0
while [ $i -lt 60 ]; do
    xdpyinfo >/dev/null 2>&1 && break
    kill -0 "$XVFB" 2>/dev/null || { echo "NOXSERVER"; exit 91; }
    i=$((i+1)); sleep 0.25
done
[ $i -lt 60 ] || { echo "NOXSERVER"; exit 91; }

"$BR" "$XSOCK" ser >"$OUT/xsnarfd.log" 2>&1 &
BRPID=$!
sleep 2

# --- 1b. WAKES PER SECOND, by instantaneous sampling ----------------------
# voluntary_ctxt_switches is the count of times this process went to sleep and
# was woken. Sampled at two instants ten seconds apart, the delta over the
# interval IS the wake rate. It is not a lifetime average and it does not
# include the startup burst, because the first sample is taken after it.
vcs() { awk '/^voluntary_ctxt_switches/{print $2}' "/proc/$1/status" 2>/dev/null; }
V0=$(vcs "$BRPID"); T0=$(date +%s%N)
sleep 10
V1S=$(vcs "$BRPID"); T1=$(date +%s%N)
if [ -n "$V0" ] && [ -n "$V1S" ]; then
    # centi-wakes per second, so the shell can compare it as an integer
    echo "K $(( (V1S - V0) * 100000000000 / (T1 - T0) )) $((V1S - V0)) $(( (T1 - T0) / 1000000 ))"
else
    echo "K NOPROC"
fi

# --- 1c. the park still delivers: a real copy reaches X quickly -----------
# The point of measuring K is worthless if the bridge got quiet by going deaf.
"$CP" 0 THROUGH-THE-PARK >/dev/null
sleep 0.8
echo "L $(xclip -o -selection clipboard 2>&1)"

# --- 2. THE FALLBACK. A writer that does not bump must still converge -----
# No write(2) and no serial store: only an mmap through the v1 prefix. The
# bridge cannot be told about this by any flag, so the only thing that can save
# it is reading the content on a timer anyway.
python3 "$OLDC" "$HAMSNARF" SILENT-OLD-WRITER >/dev/null
SER_BEFORE=$($SS read)
sleep 4
echo "M $(xclip -o -selection clipboard 2>&1)"
echo "N $SER_BEFORE / $($SS read)"

kill "$BRPID" 2>/dev/null; wait "$BRPID" 2>/dev/null
kill "$XVFB"  2>/dev/null; wait "$XVFB"  2>/dev/null
echo "END"
INNER

echo "[snarfser] running (about half a minute) ..."
RAW="$(unshare -rm --propagation private bash "$BODY" "$PWD/$OUT" 2>&1)"
echo "$RAW" > "$OUT/run.log"

case "$RAW" in
  *MOUNTFAIL*)  echo "[snarfser] CANNOT RUN: no unshare -rm on this host."; exit 2 ;;
  *NOXSERVER*)  echo "[snarfser] CANNOT RUN: Xvfb would not come up."; exit 2 ;;
esac
if [[ "$RAW" != *BEGIN* || "$RAW" != *END* ]]; then
    echo "[snarfser] FAIL: the body did not run to completion"; echo "$RAW"; exit 1
fi
line() { echo "$RAW" | grep -m1 "^$1 " | cut -d' ' -f2-; }

# ---------------------------------------------------------------- 4. counter
chk "a fresh segment starts both counters at 0"        "serial 0 0" "$(line A)"
chk "a copy bumps the CLIPBOARD counter"               "serial 1 0" "$(line B)"
chk "the SAME BYTES again bump it too (content polling cannot see this)" \
                                                       "serial 2 0" "$(line C)"
chk "a PRIMARY copy moves only the PRIMARY counter"    "serial 2 1" "$(line D)"
chk "an open of /dev/snarf.serial for WRITING is refused" \
                                                       "writeopen -1" "$(line E)"
chk "the segment is 131120 bytes (131096 of v1, then the counters and the poke)" \
                                                       "131120" "$(line F)"

# ---------------------------------------------------------------- 1a. the wake
G="$(line G)"
has "a park on /dev/snarf.serial is WOKEN by another process's copy" "wake" "$G"
GMS="$(echo "$G" | awk '{print $2}')"
lt  "and woken by the WRITE, not by the 6 s budget expiring" "${GMS:-999999}" 3000
ge  "and not before the writer ran, so it really did sleep"  "${GMS:-0}"      500
chk "a park with nobody writing is NOT woken -- the control" \
    "yes" "$(case "$(line H)" in timeout*) echo yes;; *) echo "no: $(line H)";; esac)"

# ---------------------------------------------------------------- 3. layout
chk "a 131096-byte v1 mapping still lands in the CLIPBOARD the toolkit reads" \
    "paste 0 16 OLD-CLIENT-BYTES" "$(line I)"
unchanged() { # unchanged <label> "<before> / <after>"
    local b a
    b="$(echo "$2" | awk -F' / ' '{print $1}')"
    a="$(echo "$2" | awk -F' / ' '{print $2}')"
    # "noserial did not change into noserial" is not evidence of anything. A
    # vacuous pass is the failure shape NORTH_STAR is written against, so the
    # value has to BE a serial before its stability is worth a point.
    if [ "${b#serial }" = "$b" ]; then bad "$1: [$b] is not a serial reading"
    elif [ "$b" = "$a" ]; then ok "$1 (both $b)"
    else bad "$1: [$b] became [$a]"; fi
}
unchanged "and an old client's write moves NO counter" "$(line J)"

# ---------------------------------------------------------------- 1b. rate
K="$(line K)"
KCS="$(echo "$K" | awk '{print $1}')"
if [ "$KCS" = "NOPROC" ] || [ -z "$KCS" ]; then
    bad "xsnarfd's wake rate could be sampled"
else
    ok "xsnarfd idle wake rate sampled over $(echo "$K" | awk '{print $3}') ms: $((KCS/100)).$(printf %02d $((KCS%100))) wakes/s ($(echo "$K" | awk '{print $2}') wakes)"
    # The old loop was a 200 ms poll: 5 wakes a second, floor, for ever. The
    # new one parks for 2 000 ms, so 0.5/s plus whatever X says. 150 centi-
    # wakes is the line between the two and is nowhere near either.
    lt "xsnarfd idles BELOW 1.5 wakes/s (the 200 ms poll could not: it floors at 5)" \
       "$KCS" 150
fi

# ---------------------------------------------------------------- 1c. delivery
chk "a copy made while the bridge was parked reaches the X selection" \
    "THROUGH-THE-PARK" "$(line L)"

# ---------------------------------------------------------------- 2. fallback
chk "a writer too old to bump the serial STILL converges, by reconcile" \
    "SILENT-OLD-WRITER" "$(line M)"
unchanged "and it converged with no counter having moved at all" "$(line N)"

echo
echo "[snarfser] passes=$PASS fails=$FAIL"
if [ "$FAIL" -eq 0 ]; then echo "[snarfser] PASS"; exit 0; fi
echo "[snarfser] FAIL"; exit 1
