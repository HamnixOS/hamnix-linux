#!/bin/bash
# ===========================================================================
# hkslot: DOWNLOAD A KERNEL OVER http INTO RAM, VERIFY IT THERE, WRITE THE
# INACTIVE SLOT.
#
# WHAT THIS GATE MEASURES, AND WHAT IT DOES NOT.
#
# It measures user/hkslot.ad's NEW code path -- the http(s) source -- against
# a real TCP server, with a real PE-shaped artifact, against a real
# preallocated A/B ESP layout, with the program's own absolute /boot paths
# bound into a sandbox. Every byte hkslot reads and writes here is a byte it
# read and wrote itself.
#
# IT DOES NOT BOOT A MACHINE. The artifact is a structurally real PE with a
# `.linux` section, not a Linux kernel, and the ESP is a directory rather than
# a FAT32 partition. Booting the result is tests/linux/hpm_kernel_update.sh's
# job and this gate does not claim it.
#
# WHAT WOULD MAKE THIS RED: every negative arm asserts BOTH that hkslot
# refused (exit 1) AND that the inactive slot is byte-identical to what it was
# before -- because "it printed an error" and "it changed nothing" are
# different facts, and a program that prints an error after a partial write is
# the failure this whole layout exists to prevent.
# ===========================================================================
set -u
HK="$1"                 # path to hkslot.elf
# The helper scripts live beside this one in the tree; the WORK directory and
# the fixtures live OUTSIDE the worktree, under ~/.hamnix-build, so a gate run
# never writes build products into the repo.
HERE="$(cd "$(dirname "$0")" && pwd)"
BASE="${HKHTTP_WORK:-$HOME/.hamnix-build/hkhttp}"
W="$BASE/gate"
mkdir -p "$BASE"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

PORT=18099
INV="${HKHTTP_REDARM:-0}"      # 1 = invert every assertion (negative control)
assert() { # assert <cond-exit> <text>
  if [ "$INV" = "1" ]; then
    if [ "$1" -ne 0 ]; then ok "(RED ARM) $2"; else bad "(RED ARM) $2"; fi
  else
    if [ "$1" -eq 0 ]; then ok "$2"; else bad "$2"; fi
  fi
}

rm -rf "$W"; mkdir -p "$W"
SB="$W/sb"
mkesp() {   # fresh ESP: A active and holding the OLD image, B preallocated
  rm -rf "$SB"; mkdir -p "$SB/boot/EFI/Linux" "$SB/boot/loader"
  touch "$SB/boot/HKSLOT_SANDBOX_SENTINEL"
  cp "$BASE/uki_old.efi" "$SB/boot/EFI/Linux/hamnix-a.efi"
  cp "$BASE/uki_old.efi" "$SB/boot/EFI/Linux/hamnix-b.efi"
  printf 'default hamnix-a.efi\ntimeout 3\n' > "$SB/boot/loader/loader.conf"
  truncate -s 512 "$SB/boot/loader/loader.conf"
}
slotb() { sha256sum "$SB/boot/EFI/Linux/hamnix-b.efi" | cut -d' ' -f1; }
# THE SLOT IS PREALLOCATED AND STAYS ITS FULL LENGTH. A 12 MiB artifact
# written into a 16 MiB slot leaves 4 MiB of the previous image behind it --
# that is the design (hkslot opens O_WRONLY|O_SYNC with no O_CREAT and no
# truncate, so the FAT chain is never mutated), not a defect. So the artifact
# assertion hashes the FIRST nsrc bytes, which is exactly what hkslot's own
# read-back hashes. The first version of this gate compared the whole slot
# against the artifact and scored two FAILs against correct behaviour.
slotb_head() { head -c "$1" "$SB/boot/EFI/Linux/hamnix-b.efi" | sha256sum | cut -d' ' -f1; }
slotb_len()  { stat -c %s "$SB/boot/EFI/Linux/hamnix-b.efi"; }
slota() { sha256sum "$SB/boot/EFI/Linux/hamnix-a.efi" | cut -d' ' -f1; }
lconf() { grep -a '^default' "$SB/boot/loader/loader.conf" | head -1; }
lsize() { stat -c %s "$SB/boot/loader/loader.conf"; }

# ---- fixtures -------------------------------------------------------------
# The OLD image is what both slots are preallocated with. It is 16 MiB, so the
# slot length -- which is what hkslot sizes its download buffer from -- is
# 16 MiB, and the NEW artifact at 12 MiB fits while the BIG one at 20 MiB
# does not. The sizes straddle the cap on purpose.
OLDSHA=$(python3 "$HERE/_hkslot_mkuki.py" 16777216 1 "$BASE/uki_old.efi")
NEWSHA=$(python3 "$HERE/_hkslot_mkuki.py" 12582912 7 "$BASE/uki_new.efi")
BIGSHA=$(python3 "$HERE/_hkslot_mkuki.py" 20971520 9 "$BASE/uki_big.efi")
NEWLEN=$(stat -c %s "$BASE/uki_new.efi")
SLOTLEN=$(stat -c %s "$BASE/uki_old.efi")
echo "[gate] slot length         = $SLOTLEN bytes"
echo "[gate] new artifact        = $NEWLEN bytes  sha256 $NEWSHA"
echo "[gate] big artifact        = $(stat -c %s "$BASE/uki_big.efi") bytes  sha256 $BIGSHA"

python3 "$HERE/_hkslot_serve.py" "$BASE/uki_new.efi" "$PORT" "$BASE/uki_big.efi" \
        > "$W/serve.log" 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null' EXIT
sleep 1
if ! kill -0 "$SRV" 2>/dev/null; then echo "server did not start"; cat "$W/serve.log"; exit 1; fi
echo "[gate] server pid $SRV on 127.0.0.1:$PORT"

run() { "$HERE/_hkslot_sandbox.sh" "$SB" "$HK" "$@"; }

# =========================== ARM 1: THE HAPPY PATH =========================
echo; echo "--- ARM 1: download over http, verify in RAM, write slot B ---"
mkesp
B_BEFORE=$(slotb)
run "http://127.0.0.1:$PORT/good" "$NEWSHA" > "$W/a1.log" 2>&1
RC=$?
cat "$W/a1.log"
[ "$RC" -eq 0 ]; assert $? "ARM1 hkslot exited 0"
grep -q "downloading http://127.0.0.1:$PORT/good" "$W/a1.log"; assert $? "ARM1 it said it was downloading over http"
grep -q "NOTHING IS WRITTEN TO THE ESP until this is complete" "$W/a1.log"; assert $? "ARM1 it said the ESP is untouched until the digest matches"
grep -q "downloaded $NEWLEN bytes into RAM" "$W/a1.log"; assert $? "ARM1 all $NEWLEN bytes arrived in RAM"
grep -q "matches the digest from the signed index" "$W/a1.log"; assert $? "ARM1 the RAM buffer matched the digest"
# THE ORDER IS THE POINT: the digest line must precede the first write.
DL=$(grep -n "matches the digest" "$W/a1.log" | head -1 | cut -d: -f1)
WL=$(grep -n "hkslot: WRITING" "$W/a1.log" | head -1 | cut -d: -f1)
[ -n "$DL" ] && [ -n "$WL" ] && [ "$DL" -lt "$WL" ]; assert $? "ARM1 the digest was verified BEFORE the first byte was written (line $DL < line $WL)"
B_AFTER=$(slotb)
[ "$(slotb_head "$NEWLEN")" = "$NEWSHA" ]; assert $? "ARM1 slot B's first $NEWLEN bytes ARE the downloaded artifact, byte-for-byte"
[ "$(slotb_len)" = "$SLOTLEN" ]; assert $? "ARM1 slot B is still $SLOTLEN bytes -- preallocation intact, no cluster allocated"
[ "$B_AFTER" != "$B_BEFORE" ]; assert $? "ARM1 slot B actually changed"
lconf | grep -q "hamnix-b.efi"; assert $? "ARM1 loader.conf now defaults to hamnix-b.efi"
[ "$(lsize)" = "512" ]; assert $? "ARM1 loader.conf is still exactly 512 bytes"
[ "$(slota)" = "$OLDSHA" ]; assert $? "ARM1 slot A -- the one that was running -- is untouched"

# ================= ARM 2: THE CONNECTION DROPS MID-TRANSFER ================
echo; echo "--- ARM 2: server declares the full length then hangs up at 40% ---"
mkesp
B_BEFORE=$(slotb)
run "http://127.0.0.1:$PORT/short" "$NEWSHA" > "$W/a2.log" 2>&1
RC=$?
cat "$W/a2.log"
[ "$RC" -eq 1 ]; assert $? "ARM2 hkslot exited 1"
grep -q "THE KERNEL WAS NOT DOWNLOADED" "$W/a2.log"; assert $? "ARM2 it refused loudly"
grep -q "connection ended after" "$W/a2.log"; assert $? "ARM2 it NAMED the dropped connection"
grep -q "PREFIX of the kernel" "$W/a2.log"; assert $? "ARM2 it said what arrived is a prefix, not the kernel"
grep -q "NOTHING WAS WRITTEN" "$W/a2.log"; assert $? "ARM2 it said nothing was written"
if grep -q "hkslot: WRITING" "$W/a2.log"; then false; else true; fi; assert $? "ARM2 the write loop never started"
[ "$(slotb)" = "$B_BEFORE" ]; assert $? "ARM2 slot B is byte-identical to before -- the ESP was never touched"
lconf | grep -q "hamnix-a.efi"; assert $? "ARM2 loader.conf still defaults to hamnix-a.efi"

# ============ ARM 3: THE ARTIFACT IS BIGGER THAN THE SLOT/BUFFER ===========
echo; echo "--- ARM 3: a 20 MiB artifact against a 16 MiB slot ---"
mkesp
B_BEFORE=$(slotb)
run "http://127.0.0.1:$PORT/big" "$BIGSHA" > "$W/a3.log" 2>&1
RC=$?
cat "$W/a3.log"
[ "$RC" -eq 1 ]; assert $? "ARM3 hkslot exited 1"
grep -q "LARGER than the" "$W/a3.log"; assert $? "ARM3 it NAMED the artifact as too large"
grep -q "NOTHING WAS WRITTEN" "$W/a3.log"; assert $? "ARM3 it said nothing was written"
if grep -q "hkslot: WRITING" "$W/a3.log"; then false; else true; fi; assert $? "ARM3 the write loop never started"
[ "$(slotb)" = "$B_BEFORE" ]; assert $? "ARM3 slot B is byte-identical to before -- NO TRUNCATED WRITE"
lconf | grep -q "hamnix-a.efi"; assert $? "ARM3 loader.conf still defaults to hamnix-a.efi"

# ==================== ARM 4: THE DIGEST IS WRONG ===========================
echo; echo "--- ARM 4: a complete download whose digest does not match ---"
mkesp
B_BEFORE=$(slotb)
WRONG=$(python3 -c "h='$NEWSHA'; print(h[:-1] + ('0' if h[-1]!='0' else '1'))")
run "http://127.0.0.1:$PORT/good" "$WRONG" > "$W/a4.log" 2>&1
RC=$?
cat "$W/a4.log"
[ "$RC" -eq 1 ]; assert $? "ARM4 hkslot exited 1"
grep -q "downloaded $NEWLEN bytes into RAM" "$W/a4.log"; assert $? "ARM4 the download itself COMPLETED (a digest failure, not a transport one)"
grep -q "DOES NOT MATCH ITS DIGEST" "$W/a4.log"; assert $? "ARM4 it named the digest mismatch"
if grep -q "hkslot: WRITING" "$W/a4.log"; then false; else true; fi; assert $? "ARM4 the write loop never started"
[ "$(slotb)" = "$B_BEFORE" ]; assert $? "ARM4 slot B is byte-identical to before"
lconf | grep -q "hamnix-a.efi"; assert $? "ARM4 loader.conf still defaults to hamnix-a.efi"

# ============ ARM 5: THE PLAIN-PATH SOURCE STILL WORKS (no regression) =====
echo; echo "--- ARM 5: the pre-existing local-file source is unchanged ---"
mkesp
run "$BASE/uki_new.efi" "$NEWSHA" > "$W/a5.log" 2>&1
RC=$?
[ "$RC" -eq 0 ]; assert $? "ARM5 hkslot still takes a plain path and exits 0"
grep -q "hkslot: WRITING" "$W/a5.log"; assert $? "ARM5 it wrote the slot"
if grep -q "downloading" "$W/a5.log"; then false; else true; fi; assert $? "ARM5 it did NOT go near the network for a local path"
[ "$(slotb_head "$NEWLEN")" = "$NEWSHA" ]; assert $? "ARM5 slot B's first $NEWLEN bytes are the artifact"
[ "$(slotb_len)" = "$SLOTLEN" ]; assert $? "ARM5 slot B is still $SLOTLEN bytes"
lconf | grep -q "hamnix-b.efi"; assert $? "ARM5 loader.conf flipped to hamnix-b.efi"

# ==================== ARM 6: A 404 IS NOT AN ARTIFACT ======================
echo; echo "--- ARM 6: the server has no such artifact ---"
mkesp
B_BEFORE=$(slotb)
run "http://127.0.0.1:$PORT/nope" "$NEWSHA" > "$W/a6.log" 2>&1
RC=$?
cat "$W/a6.log"
[ "$RC" -eq 1 ]; assert $? "ARM6 hkslot exited 1"
grep -q "answered HTTP 404" "$W/a6.log"; assert $? "ARM6 it named the HTTP status"
[ "$(slotb)" = "$B_BEFORE" ]; assert $? "ARM6 slot B untouched"

echo
echo "=================================================="
echo "  $PASS PASSED / $FAIL FAILED"
echo "=================================================="
[ "$FAIL" -eq 0 ]
