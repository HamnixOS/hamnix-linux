#!/usr/bin/env bash
# tests/linux/lex_error_fatal.sh — A SCRIPT THAT DOES NOT LEX DID NOT RUN, AND
# NOTHING IS ALLOWED TO SAY OTHERWISE. NOT EVEN BY EXITING 0.
#
# WHAT WAS WRONG
# ==============
# A sourced file is ONE logical input to hamsh's lexer. A runaway quote on
# line 3 swallows the rest of the file, so the parser is never reached and
# NOTHING in the script runs -- not the lines before the quote either. hamsh
# used to answer that with one unnamed line
#
#     hamsh: lexical error (unterminated quote or token-limit exceeded)
#
# and then EXIT 0. So `hpm install` printed `installed hooktest-quote@1.0.0`
# for a package whose install hook had done nothing at all. That is the exact
# shape NORTH_STAR.md exists to refuse: a gap answering something
# success-shaped instead of the truth. It was measured in the field --
# hamnix-drivers-base 1.0.13, whose generated hook contained `put in front of
# the machine's table` inside a single-quoted string.
#
# The hooks were bounded first (tests/linux/hpm_hook_bounded.sh): the machine
# stopped HANGING. It was still being told a half-done install succeeded.
#
# THE DECISION THIS GATE DEFENDS
# ==============================
# A lexical error is FATAL to the script it is in. hamsh stops, names the file
# and the LINE THE CONSTRUCT OPENED ON, says the script was not run, and exits
# non-zero. What each CALLER does with that non-zero is where the boot safety
# lives, and this file proves BOTH halves:
#
#   * `hpm` treats it as an INSTALL FAILURE. It names the package and the
#     hook, it does NOT print `installed <pkg>`, the package does not appear
#     in installed.json, and hpm exits non-zero.  (assertions 1-8, on the host)
#
#   * PID 1 must NOT die on it. An init that exits panics the kernel, and "no
#     boot" is a far worse answer than "a shell you can repair the rc from".
#     So a machine whose /etc/rc.boot fails to lex still reaches a usable
#     interactive shell on the console, having said loudly what went wrong.
#     (assertions 9-13, in a REAL BOOT under QEMU)
#
# The invariant, in one line: a lex failure is never silent, never reported as
# success, and never costs you the machine.
#
# WHAT THIS GATE IS CAREFUL ABOUT, because the last agent on this code was
# bitten by it: THE HARNESS MUST NOT GRANT THE FIX FOR FREE. hpm is given a
# stdin that is OPEN AND SILENT (a fifo held open read-write on fd 9), because
# that is what an installed machine's hpm inherits -- a console nobody is
# typing at. Run from a harness whose stdin is already at EOF, a runaway-quote
# install terminates with or WITHOUT the fix, and the gate cannot fail. The
# same applies to the direct hamsh invocations in assertions 1-3.
#
# REVERT-SENSITIVE. With user/hamsh.ad reverted to its parent commit,
# assertions 1, 2, 3, 6, 7, 8 and 11 go red: hamsh exits 0 on a script that
# never ran, hpm says `installed hooktest-quote@1.0.0`, and the booted machine
# says nothing about the rc it could not read.
#
# Usage: tests/linux/lex_error_fatal.sh          (both halves)
#        LEXGATE_SKIP_BOOT=1 tests/linux/...     (host half only, ~2 min)
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT" || exit 1

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL $*"; }
note() { echo "  --   $*"; }

# Private build tree: nothing under the shared build/ is written.
KEY="$(printf '%s' "$PROJ_ROOT" | sha256sum | cut -c1-12)"
W="${LEXGATE_DIR:-$HOME/.hamnix-build/lex_error_fatal.$KEY}"
mkdir -p "$W" || exit 1
R="$W/root"

for t in unshare /usr/sbin/chroot timeout mkfifo; do
    command -v "$t" >/dev/null 2>&1 || [ -x "$t" ] || {
        echo "[lexgate] SKIP: $t not available"; exit 0; }
done
unshare -Ur true 2>/dev/null || {
    echo "[lexgate] SKIP: unprivileged user namespaces are unavailable here"
    exit 0; }

# ---------------------------------------------------------------- build
if [ -z "${ADDER_HOST_AC:-}" ]; then
    ADDER_HOST_AC="$PROJ_ROOT/build/cutover/host_ac_llvm.elf"
    [ -x "$ADDER_HOST_AC" ] || ADDER_HOST_AC="$PROJ_ROOT/build/cutover/host_ac.elf"
fi
if [ ! -x "$ADDER_HOST_AC" ]; then
    echo "[lexgate] no host_ac.elf yet; bootstrapping the Adder compiler"
    # shellcheck source=../../scripts/_adder_cc.sh
    source "$PROJ_ROOT/scripts/_adder_cc.sh"
    adder_cc_bootstrap || {
        echo "[lexgate] FAIL: could not bootstrap host_ac.elf"; exit 1; }
    ADDER_HOST_AC="$PROJ_ROOT/build/cutover/host_ac.elf"
fi
export ADDER_HOST_AC

echo "[lexgate] building hpm + hamsh for the Linux line -> $W"
for prog in hpm hamsh; do
    nice -n 15 bash scripts/hamlinux_build.sh "user/$prog.ad" "$W/$prog.elf" \
        > "$W/$prog.build.log" 2>&1 || {
        echo "[lexgate] FAIL: could not build $prog (see $W/$prog.build.log)"
        tail -5 "$W/$prog.build.log"; exit 1; }
done

# ------------------------------------------------- the sandbox root
rm -rf "$R"
mkdir -p "$R"/bin "$R"/lib64 "$R"/lib/x86_64-linux-gnu "$R"/tmp "$R"/dev \
         "$R"/etc "$R"/repo/main/packages "$R"/var/lib/hpm "$R"/share
cp "$W/hpm.elf"   "$R/bin/hpm"
cp "$W/hamsh.elf" "$R/bin/hamsh"
for so in $(ldd "$W/hpm.elf" "$W/hamsh.elf" | awk '/=> \//{print $3}' | sort -u); do
    cp -n "$so" "$R/lib/x86_64-linux-gnu/" 2>/dev/null
done
cp /lib64/ld-linux-x86-64.so.2 "$R/lib64/" 2>/dev/null
: > "$R/dev/null"                      # bind-mount target for the real one

# ------------------------------------------------- the fixture repository
# Two packages, both hand-written (scripts/hamlinux_packages.py's write_pkg
# now REFUSES to publish an odd-quote hook, and the point of this gate is a
# hook that did not come from write_pkg -- a third-party channel, a
# hand-rolled package, or the next generator bug of a different shape).
python3 - "$R/repo/main" "$W" <<'PYFIX' || exit 1
import hashlib, json, os, shutil, sys, tarfile, tempfile

out, work = sys.argv[1], sys.argv[2]
pkgdir = os.path.join(out, "packages")
os.makedirs(pkgdir, exist_ok=True)

# THE HOOK THAT WEDGED THE MACHINE. The apostrophe in `machine's` closes the
# single-quoted string; everything after it is one runaway token.
QUOTE = ("# lexfixture-quote -- the shape that shipped in drivers-base 1.0.13.\n"
         "echo '[lexfixture-quote] BEFORE the bad line' >> /tmp/quote.log\n"
         "echo 'put in front of the machine's table' >> /tmp/quote.log\n"
         "echo '[lexfixture-quote] AFTER the bad line' >> /tmp/quote.log\n")

GOOD = ("# lexfixture-good -- an ordinary, well-formed hook.\n"
        "echo '[lexfixture-good] hook ran' >> /tmp/good.log\n"
        "exit 0\n")


def write_pkg(name, hooks):
    stage = tempfile.mkdtemp(prefix="lexfixture-")
    try:
        top = os.path.join(stage, "%s-1.0.0" % name)
        os.makedirs(os.path.join(top, "files", "share"))
        with open(os.path.join(top, "files", "share", name), "w") as fh:
            fh.write("payload of %s\n" % name)
        for hook_name, body in sorted(hooks.items()):
            hp = os.path.join(top, hook_name)
            with open(hp, "w") as fh:
                fh.write(body)
            os.chmod(hp, 0o755)
        with open(os.path.join(top, "PKGINFO"), "w") as fh:
            fh.write("\n".join(["name: %s" % name, "version: 1.0.0",
                                "arch: x86_64",
                                "description: lex-fatal gate fixture",
                                "target: #hamnix-system",
                                "maintainer: hamnix-linux gate"]) + "\n")
        tarpath = os.path.join(pkgdir, "%s-1.0.0.tar.gz" % name)
        with tarfile.open(tarpath, "w:gz", format=tarfile.GNU_FORMAT) as tf:
            for dirpath, dirnames, filenames in os.walk(top):
                dirnames.sort()
                for fn in sorted(filenames):
                    full = os.path.join(dirpath, fn)
                    tf.add(full, arcname=os.path.relpath(full, stage))
        data = open(tarpath, "rb").read()
        return {"name": name, "version": "1.0.0", "arch": "x86_64",
                "url": "packages/%s-1.0.0.tar.gz" % name,
                "sha256": hashlib.sha256(data).hexdigest(),
                "size": len(data),
                "description": "lex-fatal gate fixture",
                "depends": [], "target": "#hamnix-system"}
    finally:
        shutil.rmtree(stage, ignore_errors=True)


entries = [write_pkg("lexfixture-quote", {"install.hamsh": QUOTE}),
           write_pkg("lexfixture-good",  {"install.hamsh": GOOD})]
with open(os.path.join(out, "index.json"), "w") as fh:
    json.dump({"schema": 1, "repo": "lexgate", "channel": "main",
               "url": "file:///repo/", "updated": "2026-08-12",
               "description": "lex-fatal gate fixture",
               "packages": entries}, fh, indent=2)
    fh.write("\n")

# The wrapper hpm writes for that hook: the body, then the "\nexit\n" safety
# net -- which the runaway token swallows. Assertions 1-3 drive hamsh with the
# exact byte sequence _run_hook hands it.
with open(os.path.join(work, "quote.exec"), "w") as fh:
    fh.write(QUOTE + "\nexit\n")
with open(os.path.join(work, "good.exec"), "w") as fh:
    fh.write("echo control-ran\nexit\n")
print("fixture: %d packages" % len(entries))
PYFIX

echo "[lexgate] ================================================"
echo "[lexgate] PART 1 -- hamsh itself, on the exact wrapper hpm writes"

# HAMSH'S STDIN IS OPEN AND SILENT HERE TOO. `sleep 30 |` is a pipe with a
# live writer that never writes: exactly a console nobody is typing at. If
# this gate handed hamsh /dev/null it would be granting the fix for free --
# the shell would exit on EOF whether or not the lex error were fatal.
t0=$SECONDS
sleep 30 | timeout 15 "$W/hamsh.elf" "$W/quote.exec" > "$W/h_quote.out" 2>&1
rc=$?
el=$((SECONDS-t0))
if [ "$rc" != 0 ] && [ "$rc" != 124 ]; then
    ok "(1) hamsh EXITS NON-ZERO ($rc) on a script that does not lex -- on an OPEN stdin, in ${el}s"
elif [ "$rc" = 124 ]; then
    bad "(1) hamsh HUNG on the unlexable script (killed at 15 s) -- it fell into its REPL on an open stdin"
else
    bad "(1) hamsh exited 0 for a script that RAN NOTHING -- the success-shaped answer this gate exists to refuse"
    sed -n '1,20p' "$W/h_quote.out"
fi

# It must name the FILE and the LINE THE QUOTE OPENED ON -- line 3 of the
# wrapper, not the last line of the file, where the runaway is merely
# detected. A person with a 500-line generated hook needs the line.
if grep -q 'quote\.exec:3: lexical error' "$W/h_quote.out"; then
    ok "(2) it names the file AND the line the quote opened on: $(grep -o '[^ ]*quote\.exec:3: lexical error.*' "$W/h_quote.out" | head -1)"
else
    bad "(2) the diagnostic does not name <file>:<line-the-quote-opened-on>"
    grep -i 'lex' "$W/h_quote.out" | sed -n '1,5p'
fi

# And it must say the CONSEQUENCE. "lexical error" alone leaves a reader
# guessing how much of their script took effect. None of it did.
if grep -q 'NOT RUN' "$W/h_quote.out" \
   && ! grep -q 'BEFORE the bad line' "$W/h_quote.out"; then
    ok "(3) and it says the script was NOT RUN -- and indeed not even the line BEFORE the bad quote executed"
else
    bad "(3) hamsh did not say the script was not run (or part of it ran anyway)"
    sed -n '1,20p' "$W/h_quote.out"
fi

# The control: a well-formed script is untouched by all of this.
sleep 5 | timeout 15 "$W/hamsh.elf" "$W/good.exec" > "$W/h_good.out" 2>&1
rc=$?
if [ "$rc" = 0 ] && grep -q 'control-ran' "$W/h_good.out"; then
    ok "(4) control: a well-formed script still runs and still exits 0"
else
    bad "(4) a well-formed script regressed (rc=$rc)"; sed -n '1,20p' "$W/h_good.out"
fi

echo "[lexgate] PART 2 -- hpm, installing from a file:// repository"

# HPM'S OWN STDIN MUST BE OPEN AND SILENT, or this gate cannot fail. See the
# header, and tests/linux/hpm_hook_bounded.sh, which learned it the hard way.
rm -f "$W/stdin.fifo"; mkfifo "$W/stdin.fifo"
exec 9<> "$W/stdin.fifo"

run_ns() {   # run_ns <seconds> <logfile> <hpm args...>
    local secs="$1" log="$2"; shift 2
    local args=("$@")
    unshare -Urmp --fork --mount-proc bash -c '
        R="$1"; secs="$2"; shift 2
        mount --bind /dev/null "$R/dev/null" || exit 9
        timeout "$secs" /usr/sbin/chroot "$R" /bin/hpm "$@"
        echo "__RC__=$?"
    ' _ "$R" "$secs" "${args[@]}" > "$log" 2>&1 < "$W/stdin.fifo"
}

run_ns 60 "$W/refresh.log" --repo=file:///repo/ refresh
if grep -q '__RC__=0' "$W/refresh.log"; then
    ok "(5) the fixture repository refreshes (2 packages)"
else
    bad "(5) refresh failed"; sed -n '1,20p' "$W/refresh.log"
fi

run_ns 90 "$W/quote.log" --repo=file:///repo/ install lexfixture-quote
if grep -q '__RC__=124' "$W/quote.log"; then
    bad "(6) hpm HUNG on the runaway-quote hook (killed at 90 s)"
    sed -n '1,25p' "$W/quote.log"
elif grep -q 'installed lexfixture-quote@1.0.0' "$W/quote.log"; then
    bad "(6) hpm reported 'installed lexfixture-quote@1.0.0' FOR A HOOK THAT RAN NOTHING -- this is the bug"
    sed -n '1,25p' "$W/quote.log"
elif grep -qE '__RC__=[1-9]'  "$W/quote.log"; then
    ok "(6) hpm does NOT report the package installed, and EXITS NON-ZERO ($(grep -o '__RC__=[0-9]*' "$W/quote.log" | tail -1))"
else
    bad "(6) hpm exited 0 on a package whose hook did not run"
    sed -n '1,25p' "$W/quote.log"
fi

# BY NAME. Failing silently is not better than lying.
if grep -q 'install.hamsh of package lexfixture-quote' "$W/quote.log" \
   && grep -q 'lexfixture-quote is NOT correctly installed' "$W/quote.log"; then
    ok "(7) it fails BY NAME: the hook and the package are both named, and hpm says the package is NOT correctly installed"
else
    bad "(7) hpm did not name the hook and the package"
    grep -i 'hook\|install' "$W/quote.log" | sed -n '1,10p'
fi
# ...and the shell's own diagnostic reached the same console, with the line.
if grep -q 'install.hamsh.exec:3: lexical error' "$W/quote.log"; then
    ok "(8) and the CAUSE is on the same console with a line number: $(grep -o '[^ ]*install\.hamsh\.exec:3: lexical error.*' "$W/quote.log" | head -1)"
else
    bad "(8) the hook's lexical error did not name the file and line on hpm's console"
    grep -i 'lex' "$W/quote.log" | sed -n '1,5p'
fi
# The truth has to survive into the DATABASE too, not just the console.
if grep -q 'lexfixture-quote' "$R/var/lib/hpm/installed.json" 2>/dev/null; then
    bad "(9) installed.json LISTS lexfixture-quote -- the machine will believe it on the next update"
    cat "$R/var/lib/hpm/installed.json"
else
    ok "(9) and installed.json does not list it: a package whose hook did not run is not an installed package"
fi

# THE CONTROL, at the hpm level.
run_ns 60 "$W/good.log" --repo=file:///repo/ install lexfixture-good
if grep -q '__RC__=0' "$W/good.log" \
   && grep -q 'installed lexfixture-good@1.0.0' "$W/good.log"; then
    ok "(10) control: an ordinary package still installs and its hook still runs"
else
    bad "(10) an ordinary install regressed"; sed -n '1,25p' "$W/good.log"
fi

exec 9>&-

# =====================================================================
# PART 3 -- THE OTHER HALF, AND THE ONE THAT COSTS A MACHINE IF IT IS WRONG.
#
# A REAL BOOT: the Linux kernel, user/linuxinit.ad as PID 1, and a /etc/rc.boot
# that does not lex. hamsh IS PID 1 here (linuxinit execs it), so there is no
# parent left to catch a non-zero exit -- PID 1 exiting is a kernel panic. The
# machine must therefore say what happened and land in an interactive shell on
# the console: a machine you can log into and repair, which is what a rescue
# shell is for.
#
# The guest is driven over the SERIAL CONSOLE, deliberately, because the thing
# under test is precisely whether that console is answering. Commands are fed
# well after the boot has settled and repeated, so the test does not race the
# BIOS for stdin.
if [ "${LEXGATE_SKIP_BOOT:-0}" = "1" ]; then
    echo "[lexgate] PART 3 skipped (LEXGATE_SKIP_BOOT=1)"
    echo "[lexgate] ================================================"
    echo "[lexgate] PASS $PASS  FAIL $FAIL"
    [ "$FAIL" = 0 ] || exit 1
    exit 0
fi

echo "[lexgate] PART 3 -- a real boot whose /etc/rc.boot does not lex"
IMG="$W/image"
if [ ! -f "$IMG/vmlinuz" ] || [ "${LEXGATE_REBUILD_IMAGE:-0}" = "1" ]; then
    echo "[lexgate] staging a private image (this takes a few minutes)"
    HAMLINUX_JOBS="${HAMLINUX_JOBS:-4}" nice -n 15 \
        bash scripts/hamlinux_image.sh "$IMG" > "$W/image.build.log" 2>&1 || {
        echo "[lexgate] FAIL: image build (see $W/image.build.log)"
        tail -20 "$W/image.build.log"; exit 1; }
else
    # The binaries under test must be THIS tree's, even when the staged root
    # is being reused from a previous run of this gate.
    cp "$W/hamsh.elf" "$IMG/root/bin/hamsh"
    echo "[lexgate] reusing the staged image at $IMG (hamsh refreshed)"
fi

# THE BREAKAGE, and it is the field's own: an apostrophe inside a
# single-quoted string, in the middle of a real rc. Everything before it is
# ordinary rc work, so a shell that ran "as much as it could" would leave
# visible traces -- and must not, because the file never tokenized.
{
    echo "# lexgate: a boot rc with one stray apostrophe on line 4."
    echo "echo 'lexgate-rc: line 2 ran'"
    echo "bind '#p' /proc"
    echo "echo 'lexgate-rc: put in front of the machine's table'"
    echo "echo 'lexgate-rc: line 5 ran'"
} > "$W/rc.broken"

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

boot_with_rc() {   # boot_with_rc <rcfile> <logfile> <bootdir>
    local rc="$1" log="$2" bootdir="$3"
    rm -rf "$bootdir"; mkdir -p "$bootdir"
    cp "$IMG/vmlinuz" "$bootdir/vmlinuz"
    install -m644 "$rc" "$IMG/root/etc/rc.boot"
    pack_initramfs "$IMG/root" "$bootdir/initramfs.cpio.gz"
    # Feed the console AFTER the boot has settled, twice, so a slow boot
    # does not read as a dead shell.
    ( sleep 30
      echo "echo lexgate-console-alive-1"
      sleep 6
      echo "echo lexgate-console-alive-2"
      sleep 6
      echo "cat /version"
      sleep 8 ) | HAMLINUX_IMAGE_DIR="$bootdir" HAMLINUX_VNC=none \
        timeout 130 scripts/hamlinux_vm.sh script --timeout 120 > "$log" 2>&1
    # THE LINE-EDITOR ECHOES WHAT IS TYPED AT IT, so a plain `grep marker`
    # would match hamsh REDRAWING the command line and pass without the shell
    # ever executing anything. Strip \r, NULs and ANSI escapes, and match the
    # command's OUTPUT as a whole line (grep -x below): the echoed input is
    # always preceded by the `hamsh$ ` prompt on its line, the answer is not.
    sed -e 's/\r$//' "$log" | tr -d '\0' \
        | sed -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' -e 's/\x1b[()][A-Z0-9]//g' \
        > "$log.txt"
}

echo "[lexgate] booting a machine whose /etc/rc.boot does not lex"
boot_with_rc "$W/rc.broken" "$W/boot_broken.log" "$W/boot_broken"
B="$W/boot_broken.log.txt"

if grep -q 'lexical error' "$B" && grep -q '/etc/rc.boot:4' "$B"; then
    ok "(11) the machine SAYS SO, naming the file and the line: $(grep -o '/etc/rc.boot:4: lexical error.*' "$B" | head -1)"
else
    bad "(11) a boot rc that does not lex produced no named diagnostic on the console"
    grep -i 'lex\|rc.boot' "$B" | sed -n '1,10p'
fi

if grep -q 'RESCUE SHELL' "$B"; then
    ok "(12) and it says what state the machine is in: PID 1 announces a RESCUE SHELL rather than leaving a person to infer it"
else
    bad "(12) PID 1 did not say the machine is in a rescue shell"
    grep -i 'PID 1' "$B" | sed -n '1,10p'
fi

# THE HALF THAT MATTERS MOST: the console still answers.
if grep -qx 'lexgate-console-alive-1' "$B" && grep -qx 'lexgate-console-alive-2' "$B"; then
    ok "(13) THE MACHINE IS STILL USABLE: the console shell RAN both commands typed at it after the failed rc (their output, not the editor's echo of them, is on a line of its own)"
else
    bad "(13) the console did not answer -- a lex error in the rc COST THE MACHINE"
    tail -25 "$B"
fi
if grep -q 'hamnix-linux' "$B"; then
    ok '(14) and it can still READ THE DISK from that shell (cat /version answered) -- enough to repair the rc'
else
    bad "(14) the rescue shell could not read a file"
    tail -25 "$B"
fi
# ...and nothing from the rc ran, which is the whole claim about lexing.
if grep -q 'lexgate-rc: line 2 ran' "$B"; then
    bad "(15) part of the rc DID run -- then the report that it did not is a lie"
else
    ok "(15) and nothing in the rc ran, not even the lines before the bad quote"
fi
# A kernel panic is the failure this arm exists to rule out.
if grep -qi 'Kernel panic' "$B"; then
    bad "(16) THE KERNEL PANICKED: PID 1 exited on the lex error. This is the outcome the rcrc == 3 arm exists to prevent"
    grep -i -B3 'Kernel panic' "$B" | sed -n '1,12p'
else
    ok "(16) no kernel panic: PID 1 did not exit"
fi

# THE CONTROL BOOT: the same image with the tree's real rc still boots.
echo "[lexgate] control: the same image with the tree's own rc.boot"
boot_with_rc "etc/rc.boot.linux" "$W/boot_good.log" "$W/boot_good"
G="$W/boot_good.log.txt"
if grep -qx 'lexgate-console-alive-1' "$G" && ! grep -q 'lexical error' "$G"; then
    ok "(17) control: an ordinary boot is unaffected -- no lexical error, console answers"
else
    bad "(17) an ordinary boot regressed"
    tail -25 "$G"
fi

echo "[lexgate] ================================================"
echo "[lexgate] PASS $PASS  FAIL $FAIL"
[ "$FAIL" = 0 ] || exit 1
exit 0
