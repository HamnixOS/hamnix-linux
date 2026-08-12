#!/usr/bin/env bash
# tests/linux/scripts_read_whole.sh — A SCRIPT IS READ WHOLE OR IT IS NOT RUN,
# AND A FILE THIS SHELL REWRITES IS REWRITTEN FROM WHAT WAS IN IT.
#
# WHAT WAS WRONG
# ==============
# Every script hamsh reads went into a FIXED buffer whose overflow path was a
# bare `break` — no diagnostic of any kind, at any of the three sites:
#
#   _run_rc_path       rc_buf       16384    /etc/rc.boot        15918  97.2%
#   builtin_source     src_buf      16384    /etc/rc.boot.full   12255  74.8%
#   _svc_read_def_file svc_def_buf   4096    hamde.svc            3186  77.8%
#
# The first is PID 1's boot script, and the tail it would have cut is
# `source /etc/rc.boot.full` (line 303 of 304). 467 more bytes — ONE added
# comment paragraph — and the machine boots on the cpio fallback, reaches a
# console, looks entirely fine, and has silently run half its boot recipe.
# Nothing anywhere would have said so.
#
# The third is worse than a read bug: _svc_persist_enabled read the .svc file
# into that 4 KiB buffer and then sys_open_write'd THE SAME PATH — which
# truncates — and re-emitted the file out of the buffer. `svc enable <name>`
# on a definition over 4096 bytes DESTROYED everything past byte 4096, and
# because the cut landed mid-line it welded the fresh `enabled:` flag onto the
# tail of a comment where the parser cannot see it. It ate the file AND failed
# to persist the flag it ate the file for. Exit status 0.
#
# WHAT THIS GATE DEFENDS
# ======================
#   1. THE READ HAS NO CEILING. Not a bigger one — none. A bigger fixed buffer
#      is the same defect at a larger size, and this tree has five scars from
#      exactly that. So section 1 is a LADDER, up to 4 MiB: any fix that works
#      by raising a constant fails at the rung above the constant.
#   2. WHEN IT CANNOT BE READ WHOLE, NOTHING RUNS AND IT SAYS SO. Section 2
#      takes the memory away (`ulimit -v`) and requires the refusal by name,
#      a non-zero exit, and — the part that matters — that not even the FIRST
#      line of the script took effect.
#   3. `svc enable` DOES NOT EAT THE FILE. Section 3 runs the exact fixture
#      that lost 990 bytes before the fix.
#   4. AND THE ONE THAT COSTS A MACHINE IF IT IS WRONG: a REAL BOOT, of a real
#      /etc/rc.boot that is far past every buffer this shell ever had, with a
#      marker on the far side of the padding. If the rc is truncated the
#      machine still boots and still gives you a console — that is the whole
#      danger — so this section asserts the TAIL RAN, not that the boot
#      survived.
#
# REVERT-SENSITIVE. With user/hamsh.ad reverted to the commit before
# `hamsh: a script is read WHOLE or not at all`, sections 1 (every rung past
# 16 KiB), 2, 3 and 4 go red, and section 4 goes red in the exact shape the
# fix exists for: the machine boots, the console answers, and the tail of its
# rc never ran.
#
# Usage:  tests/linux/scripts_read_whole.sh
#         RCWHOLE_SKIP_BOOT=1    ... sections 1-3 only (~3 min, no VM)
#         RCWHOLE_SKIP_CONTROL=1 ... skip the control boot (one VM boot)
#         RCWHOLE_SEED_IMAGE=<d> ... copy a staged image dir instead of
#                                    building one (its /bin/hamsh is replaced
#                                    with this tree's either way)
#         RCWHOLE_BIN=<hamsh.elf> ... test a prebuilt binary (revert runs)
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT" || exit 1

# shellcheck source=reap.sh
. "$PROJ_ROOT/tests/linux/reap.sh"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL $*"; }
note() { echo "  --   $*"; }

KEY="$(printf '%s' "$PROJ_ROOT" | sha256sum | cut -c1-12)"
W="${RCWHOLE_DIR:-$HOME/.hamnix-build/scripts_read_whole.$KEY}"
mkdir -p "$W" || exit 1
reap_track "$W/reaped"
reap_on_exit

for t in unshare timeout python3; do
    command -v "$t" >/dev/null 2>&1 || {
        echo "[rcwhole] SKIP: $t not available"; exit 0; }
done
unshare -Ur true 2>/dev/null || {
    echo "[rcwhole] SKIP: unprivileged user namespaces are unavailable here"
    exit 0; }

# ---------------------------------------------------------------- build
BIN="${RCWHOLE_BIN:-}"
if [ -z "$BIN" ]; then
    if [ -z "${ADDER_HOST_AC:-}" ]; then
        ADDER_HOST_AC="$PROJ_ROOT/build/cutover/host_ac_llvm.elf"
        [ -x "$ADDER_HOST_AC" ] || ADDER_HOST_AC="$PROJ_ROOT/build/cutover/host_ac.elf"
    fi
    if [ ! -x "$ADDER_HOST_AC" ]; then
        echo "[rcwhole] no host_ac.elf yet; bootstrapping the Adder compiler"
        # shellcheck source=../../scripts/_adder_cc.sh
        source "$PROJ_ROOT/scripts/_adder_cc.sh"
        adder_cc_bootstrap || {
            echo "[rcwhole] FAIL: could not bootstrap host_ac.elf"; exit 1; }
        ADDER_HOST_AC="$PROJ_ROOT/build/cutover/host_ac.elf"
    fi
    export ADDER_HOST_AC
    echo "[rcwhole] building hamsh -> $W"
    nice -n 15 bash scripts/hamlinux_build.sh user/hamsh.ad "$W/hamsh.elf" \
        > "$W/hamsh.build.log" 2>&1 || {
        echo "[rcwhole] FAIL: could not build hamsh (see $W/hamsh.build.log)"
        tail -5 "$W/hamsh.build.log"; exit 1; }
    BIN="$W/hamsh.elf"
fi
echo "[rcwhole] hamsh under test: $BIN"

# ----------------------------------------------------- the shipped sizes
# The gate states the measurement it exists because of, from the files
# themselves, so a shrinking margin is visible in the log rather than only in
# a commit message somebody has to find.
echo "[rcwhole] ================================================"
echo "[rcwhole] SECTION 0 -- what the shipped files measure TODAY"
for f in etc/rc.boot etc/rc.boot.linux etc/rc.boot.full etc/rc.de-user.linux \
         etc/install.hamsh etc/services.d/hamde.svc; do
    [ -f "$f" ] || continue
    sz=$(wc -c < "$f")
    case "$f" in
        *.svc) capn=4096  ;;
        *)     capn=16384 ;;
    esac
    pct=$(( sz * 100 / capn ))
    printf '  --   %-28s %6d bytes  %3d%% of the %d-byte buffer it used to have\n' \
        "$f" "$sz" "$pct" "$capn"
done

# =====================================================================
echo "[rcwhole] SECTION 1 -- the read has NO CEILING (a ladder, not a number)"
#
# Each rung is a script whose FIRST line and LAST line both echo a marker,
# with padding between them. A reader with ANY fixed ceiling C runs the head
# and silently drops the tail for every rung above C. The top rung is 4 MiB:
# no plausible "just make the buffer bigger" edit reaches it, which is the
# point — this gate cannot be satisfied by a larger constant.
#
# THE PADDING IS FEW LONG LINES, NOT MANY SHORT ONES, AND THAT IS DELIBERATE:
# it separates the two bounds instead of testing them together. The READ has
# no ceiling and this ladder measures that. The LEXER has one — TOK_MAX,
# 4096 tokens for one input, and a comment line costs a token — so a 4 MiB
# script of 60-column lines would fail here for a reason that has nothing to
# do with any buffer. That bound is real, it is kept, and assertion (1.tok)
# below requires it to be LOUD, which is the whole difference between it and
# the silent `break` this gate exists about.
mkrung() {  # mkrung <pad-bytes> <out>
    python3 - "$1" "$2" <<'PY'
import sys
n = int(sys.argv[1]); out = sys.argv[2]
line = "# " + ("p" * 1497) + "\n"         # 1500 bytes per comment line
with open(out, "w") as f:
    f.write("echo rcwhole-head-ran\n")
    f.write(line * max(1, n // len(line)))
    f.write("echo rcwhole-tail-ran\nexit\n")
PY
}

run_script() {  # run_script <file> -> stdout+stderr, on an OPEN, SILENT stdin
    # An stdin at EOF would let hamsh exit for a reason that has nothing to do
    # with the script, so the shell gets a pipe with a live writer that never
    # writes -- a console nobody is typing at, which is what PID 1 has.
    sleep 8 | timeout 60 "$BIN" "$1" 2>&1
}

for n in 20000 65536 262144 1048576 4194304; do
    f="$W/rung.$n.hamsh"
    mkrung "$n" "$f"
    sz=$(wc -c < "$f")
    out=$(run_script "$f"); rc=$?
    head=$(printf '%s' "$out" | grep -c '^rcwhole-head-ran$')
    tail=$(printf '%s' "$out" | grep -c '^rcwhole-tail-ran$')
    if [ "$head" -ge 1 ] && [ "$tail" -ge 1 ] && [ "$rc" = 0 ]; then
        ok "(1.$n) a ${sz}-byte script runs HEAD AND TAIL (rc=$rc)"
    elif [ "$head" -ge 1 ]; then
        bad "(1.$n) a ${sz}-byte script ran its HEAD and NOT its tail -- this is the silent truncation (rc=$rc)"
    else
        bad "(1.$n) a ${sz}-byte script did not run at all (rc=$rc)"
        printf '%s\n' "$out" | grep -v 'stage-0\|_start hit' | head -4
    fi
done

# THE BOUND THAT IS LEFT, AND THE PROOF THAT IT IS A DIFFERENT KIND OF THING.
# TOK_MAX is 4096 tokens for one lex input and a line costs one, so a script
# of more than ~4096 lines does not run. It MUST NOT run silently: the file is
# named, the script does not execute, and hamsh exits non-zero. A loud bound
# is not the defect this gate is about; a silent one is.
python3 - "$W/manylines.hamsh" <<'PY'
import sys
with open(sys.argv[1], "w") as f:
    f.write("echo rcwhole-head-ran\n")
    for i in range(6000):
        f.write("# line %d\n" % i)
    f.write("echo rcwhole-tail-ran\nexit\n")
PY
out=$(run_script "$W/manylines.hamsh"); rc=$?
if printf '%s' "$out" | grep -q 'token limit exceeded' \
   && printf '%s' "$out" | grep -q 'NOT RUN' \
   && ! printf '%s' "$out" | grep -qx 'rcwhole-head-ran' \
   && [ "$rc" != 0 ]; then
    ok "(1.tok) the ONE bound left (TOK_MAX, 4096 tokens) is LOUD: named, nothing ran, non-zero exit"
else
    bad "(1.tok) a script past TOK_MAX did not fail loudly (rc=$rc, head ran: $(printf '%s' "$out" | grep -c '^rcwhole-head-ran$'))"
    printf '%s\n' "$out" | grep -v 'stage-0\|_start hit' | head -4
fi

# The `source` path is a SECOND reader with its own buffer (src_buf), and it
# is the one /etc/rc.boot's last line uses. A big rc sourcing a big file
# exercises both at once, nested -- which is also the case the two shared
# 16 KiB buffers could have corrupted for each other.
mkrung 300000 "$W/inner.hamsh"
python3 - "$W/inner.hamsh" "$W/outer.hamsh" <<'PY'
import sys
inner, outer = sys.argv[1], sys.argv[2]
line = "# " + ("q" * 197) + "\n"
with open(outer, "w") as f:
    f.write("echo rcwhole-outer-head\n")
    f.write(line * 1500)                   # 300 KB of outer padding
    f.write("source %s\n" % inner)
    f.write("echo rcwhole-outer-tail\nexit\n")
PY
out=$(run_script "$W/outer.hamsh"); rc=$?
oh=$(printf '%s' "$out" | grep -c '^rcwhole-outer-head$')
ot=$(printf '%s' "$out" | grep -c '^rcwhole-outer-tail$')
it=$(printf '%s' "$out" | grep -c '^rcwhole-tail-ran$')
if [ "$oh" -ge 1 ] && [ "$it" -ge 1 ] && [ "$ot" -ge 1 ]; then
    ok "(1.source) a 300 KB rc that SOURCES a 300 KB file runs all three markers -- both readers, nested"
else
    bad "(1.source) nested source lost something (outer-head=$oh inner-tail=$it outer-tail=$ot rc=$rc)"
    printf '%s\n' "$out" | grep -v 'stage-0\|_start hit' | head -6
fi

# =====================================================================
echo "[rcwhole] SECTION 2 -- when it CANNOT be read whole, nothing runs and it says so"
#
# THE MEMORY IS ACTUALLY TAKEN AWAY. `ulimit -v` is the only way to make the
# allocation fail on demand; the limit is chosen just above what hamsh needs
# to start (measured: it will not start at all below ~29 MB), and the script
# is 23.8 MB, so the shell is alive and the FILE is what does not fit.
python3 - "$W/huge.hamsh" <<'PY'
import sys
line = "# " + ("z" * 116) + "\n"
with open(sys.argv[1], "w") as f:
    f.write("echo rcwhole-head-ran\n")
    for _ in range(200000):
        f.write(line)
    f.write("echo rcwhole-tail-ran\nexit\n")
PY
hugesz=$(wc -c < "$W/huge.hamsh")
out=$( (ulimit -v 30000; sleep 8 | timeout 90 "$BIN" "$W/huge.hamsh") 2>&1 ); rc=$?
printf '%s\n' "$out" > "$W/huge.out"
if printf '%s' "$out" | grep -q 'CANNOT BE READ WHOLE'; then
    ok "(2.1) it says so BY NAME: $(printf '%s' "$out" | grep -o '[^ ]*huge\.hamsh: CANNOT BE READ WHOLE.*' | head -1)"
else
    bad "(2.1) a ${hugesz}-byte script that did not fit produced no named diagnostic"
    printf '%s\n' "$out" | grep -v 'stage-0\|_start hit' | head -6
fi
if printf '%s' "$out" | grep -q 'NOT RUN'; then
    ok "(2.2) and it says the CONSEQUENCE -- NOT RUN, none of it took effect"
else
    bad "(2.2) it did not say that none of the script ran"
fi
if printf '%s' "$out" | grep -qx 'rcwhole-head-ran'; then
    bad "(2.3) THE FIRST LINE RAN ANYWAY -- a partially-executed script is exactly the failure this gate exists for"
else
    ok "(2.3) and NOT EVEN THE FIRST LINE ran: the file was refused, not truncated"
fi
if [ "$rc" != 0 ]; then
    ok "(2.4) and hamsh exits non-zero ($rc) rather than reporting success"
else
    bad "(2.4) hamsh exited 0 for a script of which nothing ran"
fi

# =====================================================================
echo "[rcwhole] SECTION 3 -- \`svc enable\` does not eat the file"
#
# This is the fixture that measured `size before=5088 after=4098 (lost 990
# bytes)` before the fix, with the `uid:` directive and the last line gone and
# the fresh flag welded onto the tail of a comment.
E="$W/svcetc"
rm -rf "$E"; mkdir -p "$E/services.d"
cp /etc/passwd "$E/passwd" 2>/dev/null
python3 - "$E/services.d/bigsvc.svc" <<'PY'
import sys
with open(sys.argv[1], "w") as f:
    f.write("# bigsvc -- required keys near the top, then a documented tail.\n")
    f.write("name: bigsvc\n")
    f.write("ns: none\n")
    f.write("exec: /bin/true\n")
    f.write("description: a service definition longer than 4096 bytes\n")
    f.write("enabled: no\n")
    f.write("runlevel: 3\n")
    for i in range(50):
        f.write("# doc line %04d %s\n" % (i, "y" * 80))
    f.write("uid: 1234\n")
    f.write("# THE VERY LAST LINE OF THE FILE -- MARKER-TAIL-9821\n")
PY
before=$(wc -c < "$E/services.d/bigsvc.svc")
cp "$E/services.d/bigsvc.svc" "$W/bigsvc.before"
printf 'svc enable bigsvc\nexit\n' > "$W/svc.hamsh"
unshare -Urm bash -c '
    BIN="$1"; W="$2"; E="$3"
    mount --bind "$E" /etc || exit 9
    sleep 5 | timeout 60 "$BIN" "$W/svc.hamsh" 2>&1
' _ "$BIN" "$W" "$E" > "$W/svc.out" 2>&1
after=$(wc -c < "$E/services.d/bigsvc.svc")
note "bigsvc.svc: $before bytes before, $after after"
if [ "$after" -ge "$before" ]; then
    ok "(3.1) the file did not shrink ($before -> $after; +1 is 'no' becoming 'yes')"
else
    bad "(3.1) \`svc enable\` DESTROYED $((before-after)) bytes of the file on disk"
fi
if grep -q 'MARKER-TAIL-9821' "$E/services.d/bigsvc.svc"; then
    ok "(3.2) the last line of the file is still there"
else
    bad "(3.2) the last line of the file is GONE -- rewritten from a truncated read"
fi
if grep -q '^uid: 1234' "$E/services.d/bigsvc.svc"; then
    ok "(3.3) and so is the \`uid: 1234\` directive that lived past byte 4096"
else
    bad "(3.3) the \`uid:\` directive past byte 4096 was deleted"
fi
if grep -qx 'enabled: yes' "$E/services.d/bigsvc.svc"; then
    ok "(3.4) the enable PERSISTED, on a line of its own where the parser can see it"
else
    bad "(3.4) the enable did not persist as a parseable line -- $(grep -c 'enabled: yes' "$E/services.d/bigsvc.svc") welded occurrence(s)"
    tail -2 "$E/services.d/bigsvc.svc"
fi
if grep -q 'missing required key' "$W/svc.out"; then
    bad "(3.5) the definition did not even parse -- its required keys were read, but something else was not"
    grep -v 'stage-0\|_start hit' "$W/svc.out" | head -4
else
    ok "(3.5) and the definition registered without a spurious missing-key error"
fi

# =====================================================================
if [ "${RCWHOLE_SKIP_BOOT:-0}" = "1" ]; then
    echo "[rcwhole] SECTION 4 skipped (RCWHOLE_SKIP_BOOT=1)"
    echo "[rcwhole] ================================================"
    echo "[rcwhole] PASS $PASS  FAIL $FAIL"
    [ "$FAIL" = 0 ] || exit 1
    exit 0
fi
echo "[rcwhole] SECTION 4 -- A REAL BOOT, with a real rc far past every buffer"
#
# The honest test for /etc/rc.boot is a boot. The rc here is the tree's OWN
# etc/rc.boot.linux with 200 KB of comment padding inserted before its last
# statement, and markers on both sides of the padding. The failure being ruled
# out is not a crash: a truncated rc BOOTS, and gives you a console, and looks
# fine. So what is asserted is that the far side of the padding RAN.
IMG="$W/image"
if [ ! -d "$IMG/root" ] || [ "${RCWHOLE_REBUILD_IMAGE:-0}" = "1" ]; then
    if [ -n "${RCWHOLE_SEED_IMAGE:-}" ] && [ -d "${RCWHOLE_SEED_IMAGE}/root" ]; then
        echo "[rcwhole] seeding a private image from $RCWHOLE_SEED_IMAGE"
        rm -rf "$IMG"; mkdir -p "$IMG"
        cp -a "$RCWHOLE_SEED_IMAGE/root" "$IMG/root"
        cp -a "$RCWHOLE_SEED_IMAGE/vmlinuz" "$IMG/vmlinuz"
    else
        echo "[rcwhole] staging a private image (this takes a few minutes)"
        HAMLINUX_JOBS="${HAMLINUX_JOBS:-4}" nice -n 15 \
            bash scripts/hamlinux_image.sh "$IMG" > "$W/image.build.log" 2>&1 || {
            echo "[rcwhole] FAIL: image build (see $W/image.build.log)"
            tail -20 "$W/image.build.log"; exit 1; }
    fi
fi
# THE BINARY UNDER TEST MUST BE THE ONE IN THE GUEST, every run, whether the
# image was just built, seeded from elsewhere, or reused.
cp "$BIN" "$IMG/root/bin/hamsh"
echo "[rcwhole] guest /bin/hamsh <- $BIN"

# The rc: everything up to the final `source '/etc/rc.d/rc.5'`, then a marker,
# then the padding, then the marker that only a WHOLE read can reach, then the
# real last line. Under a 16 KiB reader the cut lands inside the padding: the
# machine boots, the console answers, and the graphical runlevel never starts.
python3 - "etc/rc.boot.linux" "$W/rc.big" <<'PY'
import sys
src, out = sys.argv[1], sys.argv[2]
lines = open(src).read().splitlines(True)
# Split before the LAST top-level statement of the shipped rc.
cut = max(i for i, l in enumerate(lines) if l.strip() and not l.startswith((" ", "\t", "#")))
pad = "# " + ("d" * 197) + "\n"
with open(out, "w") as f:
    f.writelines(lines[:cut])
    f.write("echo 'rcwhole-boot: BEFORE the padding'\n")
    f.writelines([pad] * 1000)                       # 200 KB
    f.write("echo 'rcwhole-boot: AFTER the padding -- the tail of the rc ran'\n")
    f.writelines(lines[cut:])
    print("rc.big: %d bytes, last shipped statement kept: %s"
          % (f.tell(), lines[cut].strip()))
PY
note "$(wc -c < "$W/rc.big") bytes of /etc/rc.boot (the shipped one is $(wc -c < etc/rc.boot.linux))"

pack_initramfs() {   # pack_initramfs <rootdir> <out.cpio.gz>
    local root="$1" out="$2" cpio="$W/pack.cpio"
    : > "$cpio"
    ( cd "$root" && find . -path './home/*' -prune -o -print0 \
        | cpio --null -o -H newc --quiet -R 0:0 ) >> "$cpio"
    ( cd "$root" && find ./home/live -print0 \
        | cpio --null -o -H newc --quiet -R 1001:1001 ) >> "$cpio" 2>/dev/null
    ( cd "$root" && find ./home/hostowner -print0 \
        | cpio --null -o -H newc --quiet -R 1:1 ) >> "$cpio" 2>/dev/null
    gzip -9 < "$cpio" > "$out"
    rm -f "$cpio"
}

boot_with_rc() {   # boot_with_rc <rcfile> <logfile> <bootdir> [vm-seconds]
    local rc="$1" log="$2" bootdir="$3" secs="${4:-160}"
    rm -rf "$bootdir"; mkdir -p "$bootdir"
    cp "$IMG/vmlinuz" "$bootdir/vmlinuz"
    install -m644 "$rc" "$IMG/root/etc/rc.boot"
    pack_initramfs "$IMG/root" "$bootdir/initramfs.cpio.gz"
    ( sleep 45
      echo "echo rcwhole-console-alive"
      sleep 15 ) | HAMLINUX_IMAGE_DIR="$bootdir" HAMLINUX_VNC=none \
        timeout "$((secs + 20))" scripts/hamlinux_vm.sh script --timeout "$secs" \
        > "$log" 2>&1
    sed -e 's/\r$//' "$log" | tr -d '\0' \
        | sed -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' -e 's/\x1b[()][A-Z0-9]//g' \
        > "$log.txt"
}

echo "[rcwhole] booting a machine whose /etc/rc.boot is $(wc -c < "$W/rc.big") bytes"
boot_with_rc "$W/rc.big" "$W/boot_big.log" "$W/boot_big" 170
B="$W/boot_big.log.txt"

if grep -q 'rcwhole-boot: BEFORE the padding' "$B"; then
    ok "(4.1) the machine booted and the FIRST half of its rc ran"
else
    bad "(4.1) the first half of the rc did not run -- the boot itself is broken, so 4.2 proves nothing"
    tail -25 "$B"
fi
if grep -q 'rcwhole-boot: AFTER the padding' "$B"; then
    ok "(4.2) AND THE TAIL RAN: a 200 KB /etc/rc.boot was read WHOLE by PID 1"
else
    bad "(4.2) THE TAIL OF /etc/rc.boot NEVER RAN. The machine booted anyway, which is the whole danger"
    grep -a 'rcwhole-boot\|CANNOT BE READ\|lexical error' "$B" | head -5
fi
# The last shipped statement is `source '/etc/rc.d/rc.5'` -- the graphical
# runlevel. It is BEYOND the padding, so a truncated rc silently comes up
# text-only. This asserts the consequence, not just the marker.
if grep -qa 'rc.5\|wsys\|hamdesktop\|compositor' "$B"; then
    ok "(4.3) and the statement past the padding took effect (the graphical runlevel is in the log)"
else
    bad "(4.3) the rc's last statement (the graphical runlevel) left no trace -- it did not run"
fi
if grep -q 'CANNOT BE READ WHOLE' "$B"; then
    bad "(4.4) PID 1 could not hold its own rc -- it refused it, which is honest, but the machine has no boot recipe"
    grep -a 'CANNOT BE READ WHOLE' "$B" | head -2
else
    ok "(4.4) no refusal: the rc fitted in memory rather than being refused"
fi
if grep -q 'lexical error' "$B"; then
    bad "(4.5) the padded rc reports a lexical error (TOK_MAX is the one bound left, and this rc crossed it)"
    grep -a 'lexical error' "$B" | head -2
else
    ok "(4.5) no lexical error: the whole 200 KB tokenized inside TOK_MAX"
fi
if grep -qi 'Kernel panic' "$B"; then
    bad "(4.6) THE KERNEL PANICKED"
    grep -i -B3 'Kernel panic' "$B" | head -10
else
    ok "(4.6) no kernel panic"
fi
if grep -qx 'rcwhole-console-alive' "$B"; then
    ok "(4.7) and the console still answers a typed command"
else
    note "(4.7) console echo not matched -- the full rc's console is busy; 4.1-4.3 carry the claim"
fi

if [ "${RCWHOLE_SKIP_CONTROL:-0}" != "1" ]; then
    echo "[rcwhole] control: the same image with the tree's own rc.boot.linux"
    boot_with_rc "etc/rc.boot.linux" "$W/boot_ctl.log" "$W/boot_ctl" 200
    G="$W/boot_ctl.log.txt"
    if grep -q 'loop-enter' "$G" && ! grep -qi 'Kernel panic' "$G" \
       && ! grep -q 'lexical error' "$G"; then
        ok "(4.8) control: the unpadded shipped rc still boots to the interactive shell"
    else
        bad "(4.8) the ordinary boot regressed -- section 4's other results are suspect"
        tail -25 "$G"
    fi
fi

echo "[rcwhole] ================================================"
echo "[rcwhole] PASS $PASS  FAIL $FAIL"
[ "$FAIL" = 0 ] || exit 1
exit 0
