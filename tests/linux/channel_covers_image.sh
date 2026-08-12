#!/usr/bin/env bash
# tests/linux/channel_covers_image.sh — THE CHANNEL MUST CARRY WHAT THE IMAGE
# SHIPS.
#
# THE INVARIANT, stated by the machine's owner and now enforced here:
#
#     "changes that we create here will end up in the package repository and
#      be able to be updated on. That's something going forward must always
#      be true."
#
# A file that is in the initramfs but not in any package is a file an
# INSTALLED machine can never receive a fix to. The live image gets it because
# the image is built from the tree; a person who installed hamnix-linux and
# runs `hpm update` gets nothing, forever, and NOTHING FAILS to tell them so.
# That is the worst shape a bug can have in this project: the gap answers with
# silence rather than with the truth.
#
# It has happened at least four times before this gate covered the whole root:
#   * the audio clients, when audio first landed -- an installed machine got
#     the audio DEVICE (compiled into every binary's runtime) and none of the
#     programs that could drive it (see the AUDIO_CMDS note in
#     scripts/hamlinux_packages.py);
#   * hamnix-desktop, dropped from a whole channel by a double-link that
#     printed one line of output;
#   * the seven this gate found the day it was written: audiolife, halt,
#     hamimgscene, host_ac, install, poweroff, xsnarfd -- including the two
#     commands that turn the machine off, and the X clipboard bridge that had
#     been written that same week;
#   * and 152 files this gate COULD NOT SEE, because it compared /bin and
#     nothing else. Measured on the published 1.0.12 channel: 34 kernel
#     modules (ext4, jbd2, vfat, virtio_blk, virtio_net, evdev, overlay,
#     squashfs, loop, the nls tables, the whole snd-hda stack), the
#     modules.dep table `modprobe` had just been made to depend on, the 21
#     manual pages `man` and `help` read, the 23 Adder runtime sources
#     /bin/ac must LINK against, /etc/skel, /etc/users/*.ns, ten static /etc
#     files including /etc/profile, /usr/share/sounds/test.wav, and /init --
#     the program the kernel executes. The gate passed every one of those
#     days: it was looking one directory over.
#
# AND ONCE BY AN EXCLUSION WHOSE REASON WAS FALSE -- the fifth shape, and the
# one this table has to be read for. `bin/host_ac` sat in the list above with
# the reason "the Adder compiler built for the BUILD HOST's libc ... the
# shippable compiler is `ac`, which IS packaged." Both halves were wrong:
#
#   * /bin/ac is a DRIVER, not a compiler. It execs /bin/host_ac (a hard-coded
#     path in user/ac.ad) to turn foo.ad into LLVM IR. Measured by deleting
#     host_ac from a staged root and running the real ac binary:
#         ac: cannot run /bin/host_ac
#         ac: hello.ad: the Adder compiler could not translate this program
#     exit 10, no binary. So "ac IS packaged" bought an installed machine
#     nothing at all -- and HANDOFF.md §0 listed "compiles Adder on the box"
#     as a MEASURED capability of this distribution the whole time.
#   * host_ac is not linked against the build host's libc. readelf: no
#     .dynamic section, no INTERP, "not a dynamic executable". It is the one
#     binary in /bin that needs no libc. `ac` is the one with NEEDED
#     libssl.so.3, libcrypto.so.3, libcrypt.so.1, libc.so.6 -- the exclusion
#     kept the static file out on a dynamic-linking worry that applied only to
#     the file it let through.
#
# host_ac is now carried by hamnix-adder (ADDER_COMPILER in
# scripts/hamlinux_packages.py) and the exclusion is gone. The lesson is about
# this table, not about that file: A REASON IN THIS LIST IS A CLAIM, and an
# unmeasured claim here is indistinguishable from the silent drop the gate
# exists to catch -- it just has prose in front of it. What the channel does
# for the toolchain is now RUN, not asserted: tests/linux/channel_compiles_adder.sh.
#
# WHAT THIS MEASURES NOW: EVERY regular file under the staged image root,
# against every install path carried by any package tarball in the built
# channel. Not the build logs, not the package COUNT -- the actual file lists,
# on disk. A count is exactly the kind of evidence that agrees with a silent
# drop.
#
# HOW AN OMISSION IS ALLOWED: by name, in the EXCLUSIONS table below, WITH A
# REASON. An unlisted omission fails, anywhere in the root. This is deliberate
# -- it makes "we do not ship that" a written decision rather than an accident
# nobody noticed. A listed exclusion that is no longer in the image is
# reported too, so the table cannot quietly go stale.
#
# Usage: tests/linux/channel_covers_image.sh [image-root] [channel-dir]
#   defaults: build/image/root  build/repo/linux
# Requires both to have been built already; it builds nothing itself, because
# a gate that rebuilds its own inputs can hide the failure it exists to catch.

set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IMG="${1:-$ROOT/build/image/root}"
CHAN="${2:-$ROOT/build/repo/linux}"

PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); echo "PASS: $*"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

# ---------------------------------------------------------------------------
# THE EXCLUSIONS. One per line: "<pattern><TAB><reason>".
#
# A pattern is either an exact path relative to the image root, or a path
# ending in '/' which covers everything beneath it, or a path containing '*'
# (matched with bash's == inside [[ ]]).
#
# A reason has to be about the FILE -- what it is and why a package must not
# carry it -- not about the effort of packaging it. Every reason below is
# either a measurement or a mechanism somebody can go and read.
# ---------------------------------------------------------------------------
EXCLUSIONS=$(cat <<'EOF'
bin/audiolife	an audio stream LIFETIME scenario driver: a test fixture, not a program a user runs. It is in the image because the audio tests run inside the image.
init	SHIPPED, BUT BY A HOOK, and the hook is checked below. /init is byte-identical to /bin/linuxinit (which hamnix-init packages) and is what the kernel executes on an installed machine. A package FILE at /init would be opened for writing on the running PID 1's text image -- ETXTBSY -- so the install would fail on every machine that is up. hamnix-init's install.hamsh unlinks it and copies /bin/linuxinit over it instead.
etc/modules	the machine's BOOT MODULE LIST, and an append target. linuxinit walks it in file order, and every driver package's install hook appends its own modules to it. A package that shipped this file would replace it, silently un-listing the GPU driver an installed machine had added. It also has a hard 8192-byte ceiling (linuxinit reads it with ONE read), which repeated package appends would blow. The FILES it names are packaged -- hamnix-drivers-base and hamnix-drivers-*.
lib/modules/*/modules.dep	the machine's DEPENDENCY TABLE: depmod generated it over the modules THAT machine has, and hamnix-drivers-drm, -gpu-intel and -gpu-nouveau each APPEND to it from their install hooks. A package file at this path would be deleted-then-rewritten on every upgrade, taking the appended driver lines with it -- the machine would keep i915.ko on disk and lose the only line that lets `modprobe i915` name it. The package-owned copy is modules.dep.base (hamnix-drivers-base), which its hook PREPENDS; modprobe takes the first matching line, so the shipped lines win and the appended ones survive. Checked below.
etc/shadow	this machine's password hashes, mode 0600. Shipping it would revert every password anybody had changed, on every update -- and hpm's extractor writes 0644, so it would also publish them. It is provisioned once, by the image or the installer.
etc/resolv.conf	written at runtime by dhcpc from the lease. A package copy would overwrite a working machine's resolver with the build host's placeholder.
etc/hpm/trusted.pub	the Ed25519 public key that AUTHENTICATES this channel. A package cannot carry the key its own signature is checked against: an attacker who could publish a package could then rotate the trust root that verifies the next one. It is provisioned with the medium, out of band.
etc/hpm/local-trusted.pub	the second trust root, for locally-signed test channels. Same reason as trusted.pub, and it is a DEVELOPMENT key besides.
etc/distros	the description of which distribution media THIS machine has -- `LABEL=...` lines a user edits to add a distro (the file's own header says a new distribution is a line in a file, not a recompile). A package copy would overwrite those edits on every update.
etc/rc.distros	GENERATED by scripts/hamlinux_image.sh from /etc/distros, which the machine owns and edits. Shipping the build host's copy would describe media the machine does not have and omit the ones it does.
etc/rc.distros-wl	GENERATED from /etc/distros, same as rc.distros.
etc/rc.de-ns/	GENERATED from /etc/distros, one file per distribution the machine knows about. Same reason.
version	the image BUILD STAMP -- one line naming the kernel and the git commit the initramfs was built from. It describes the medium, not the software; a package copy would make an updated machine claim the commit of whatever image it was installed from.
lib64/ld-linux-x86-64.so.2	the BUILD HOST's dynamic loader, copied in beside the glibc-linked binaries. It is not a change made here, and hpm writes files in place: replacing the loader every running process is executing through -- including hpm's own -- is not an update, it is a machine that stops between two syscalls. It travels with the medium.
lib/x86_64-linux-gnu/	the BUILD HOST's shared libraries (libc, libcrypt, libcrypto, libssl, libz, libzstd), copied in by scripts/hamlinux_image.sh's copy_libs. Same reason as the loader above, and the same fact: they are Debian's files, not this project's changes. The Mesa/Vulkan libraries this project DOES ship live under /usr/lib and ARE packaged.
home/live/	the live session's HOME, a copy of /etc/skel made by the image so a live boot can save a file. /etc/skel is the copy that ships (hamnix-desktop); an installed machine's /home belongs to its users, and a package that wrote into it would overwrite their documents.
EOF
)

[ -d "$IMG" ]  || { echo "FAIL: no image root at $IMG (run scripts/hamlinux_image.sh)"; exit 1; }
[ -d "$CHAN" ] || { echo "FAIL: no channel at $CHAN (run scripts/hamlinux_packages.py)"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# A bare EXIT trap does not run when the shell is killed by a signal, so a
# gate stopped by `timeout` (TERM) or ^C (INT) skipped its cleanup entirely.
# Re-exit on those, which makes the EXIT trap above run on every path out.
trap 'exit 130' INT TERM HUP

# --- what the image ships --------------------------------------------------
# Every regular file and symlink, relative to the image root. Directories are
# not compared: hpm recreates a parent from the path of the file inside it, so
# an empty directory is not something a package can carry or fail to carry.
( cd "$IMG" && find . \( -type f -o -type l \) | sed 's|^\./||' ) | sort > "$TMP/img"

# --- what the channel carries ----------------------------------------------
# Package layout is <name>-<ver>/files/<install-path>, so an installed file is
# everything after the first '/files/'.
#
# A module that ships GZIPPED covers the .ko path it is gunzipped to: the
# install hook runs `gzip -d` on it (i915.ko is 9.9 MiB, over hpm's in-RAM
# unpack cap). Stripping the suffix here is why hamnix-drivers-gpu-intel
# counts as carrying i915.ko rather than reading as an omission.
for t in "$CHAN"/packages/*.tar.gz; do
    [ -e "$t" ] || continue
    tar tzf "$t" 2>/dev/null
done | sed -n 's|^[^/]*/files/||p' | grep -v '/$' \
     | sed 's|^\(lib/modules/.*\.ko\)\.gz$|\1|' | sort -u > "$TMP/chan"

NIMG=$(wc -l < "$TMP/img")
NCHAN=$(wc -l < "$TMP/chan")
NIMGBIN=$(grep -c '^bin/' "$TMP/img" || true)
NCHANBIN=$(grep -c '^bin/' "$TMP/chan" || true)
echo "image: $NIMG files ($NIMGBIN in /bin)    channel: $NCHAN files ($NCHANBIN in /bin)"

# A sanity floor. If the extraction pattern silently matches nothing -- which
# it DID during development, when the layout was /files/bin and the pattern
# assumed /bin -- every comparison below would "find" the whole image missing,
# or worse, an empty image list would make everything pass. Refuse to report
# on lists that are implausible, rather than reporting a confident wrong answer.
if [ "$NIMGBIN" -lt 50 ] || [ "$NIMG" -lt 200 ]; then
    bad "only $NIMG files ($NIMGBIN in /bin) found in $IMG -- the image looks unbuilt or the path is wrong; NOT reporting coverage from it"
    echo; echo "$PASS passed, $FAIL failed"; exit 1
fi
if [ "$NCHANBIN" -lt 50 ] || [ "$NCHAN" -lt 200 ]; then
    bad "only $NCHAN files ($NCHANBIN in /bin) extracted from $CHAN/packages -- the tarball layout is not what this gate parses; NOT reporting coverage from it"
    echo; echo "$PASS passed, $FAIL failed"; exit 1
fi
ok "both lists are plausible ($NIMG image files, $NCHAN channel files) -- the comparison below means something"

# --- THE MEASUREMENT -------------------------------------------------------
comm -23 "$TMP/img" "$TMP/chan" > "$TMP/missing"

# Split the missing list into "excluded by name, with a reason" and the rest.
: > "$TMP/unexpected"
: > "$TMP/excused"
: > "$TMP/used_patterns"
while IFS= read -r f; do
    [ -n "$f" ] || continue
    matched=""
    while IFS=$'\t' read -r pat reason; do
        [ -n "${pat:-}" ] || continue
        case "$pat" in
            */) [[ "$f" == "$pat"* ]] && matched="$pat" ;;
            *\**) [[ "$f" == $pat ]] && matched="$pat" ;;
            *)  [ "$f" = "$pat" ] && matched="$pat" ;;
        esac
        [ -n "$matched" ] && break
    done <<< "$EXCLUSIONS"
    if [ -n "$matched" ]; then
        printf '%s\t%s\n' "$matched" "$f" >> "$TMP/excused"
        echo "$matched" >> "$TMP/used_patterns"
    else
        echo "$f" >> "$TMP/unexpected"
    fi
done < "$TMP/missing"

NMISS=$(wc -l < "$TMP/missing")
NEXC=$(wc -l < "$TMP/excused")
NUNEXP=$(wc -l < "$TMP/unexpected")

if [ "$NUNEXP" -gt 0 ]; then
    while IFS= read -r u; do
        bad "$u ships in the image and is in NO package -- an installed machine can never update it"
    done < "$TMP/unexpected"
    echo
    echo "Add each to a package in scripts/hamlinux_packages.py -- a command"
    echo "list (COREUTILS, DESKTOP_CMDS, SYS_CMDS, NET_CMDS, AUDIO_CMDS,"
    echo "AUTH_CMDS, MOD_CMDS), a COMPONENTS extras list, ADDER_SHARE,"
    echo "MAN_PAGES, SKEL_FILES or hamnix-drivers-base -- or, if it genuinely"
    echo "must not ship, add it to EXCLUSIONS in this file WITH A REASON."
    echo "Silence is not one of the options."
else
    ok "every file in the image is carried by a package or excluded by name ($NIMG checked, $NEXC excluded)"
fi

# --- the exclusion table is itself checked ---------------------------------
# An exclusion nobody exercises is a decision about a file that is no longer
# there; it is not a failure, but it must not go unsaid, or the list turns
# into folklore.
sort -u "$TMP/used_patterns" 2>/dev/null > "$TMP/used" || : > "$TMP/used"
STALE=""
while IFS=$'\t' read -r pat reason; do
    [ -n "${pat:-}" ] || continue
    grep -qxF "$pat" "$TMP/used" || STALE="$STALE $pat"
done <<< "$EXCLUSIONS"
if [ -n "$STALE" ]; then
    echo "note: exclusions that matched nothing in this image (stale, or now packaged):$STALE"
else
    ok "every exclusion in the table is still exercised by this image -- none is folklore"
fi

echo
echo "excluded by name, grouped by reason:"
cut -f1 "$TMP/excused" | sort | uniq -c | sort -rn | while read -r n pat; do
    printf '  %4d  %s\n' "$n" "$pat"
done

# --- the two exclusions that claim something IS shipped --------------------
# Both of the entries above that say "shipped, but not as a file at this path"
# are claims about a mechanism. A claim nothing measures is the shape every
# bug in this tree has worn, so measure them: read the bytes out of the built
# tarballs.
INITPKG=$(ls "$CHAN"/packages/hamnix-init-*.tar.gz 2>/dev/null | head -1)
if [ -n "$INITPKG" ]; then
    HOOK=$(tar xzOf "$INITPKG" --wildcards '*/install.hamsh' 2>/dev/null)
    if echo "$HOOK" | grep -q "cp '/bin/linuxinit' '/init'"; then
        ok "/init is excluded as a file and hamnix-init's install.hamsh really does copy /bin/linuxinit onto it"
    else
        bad "/init is excluded on the grounds that hamnix-init's install hook copies it, and that hook does NOT -- the kernel's own program is unupdatable"
    fi
    if tar tzf "$INITPKG" | grep -q 'files/bin/linuxinit'; then
        ok "hamnix-init carries bin/linuxinit, which is the bytes that hook copies"
    else
        bad "hamnix-init does not carry bin/linuxinit -- the /init hook would copy nothing"
    fi
else
    bad "no hamnix-init package in the channel -- /init and the boot files are unupdatable"
fi

DEPBASE=$(grep -c '^lib/modules/.*/modules\.dep\.base$' "$TMP/chan" || true)
if [ "$DEPBASE" -ge 1 ]; then
    ok "modules.dep is excluded as machine state and the package-owned copy (modules.dep.base) IS in the channel"
    BASEPKG=$(ls "$CHAN"/packages/hamnix-drivers-base-*.tar.gz 2>/dev/null | head -1)
    if [ -n "$BASEPKG" ] && tar xzOf "$BASEPKG" --wildcards '*/install.hamsh' 2>/dev/null \
         | grep -q "modules.dep.base' '/lib/modules/.*/modules.dep' >"; then
        ok "hamnix-drivers-base's hook PREPENDS its table to the machine's (cat base dep > new; mv) -- the lines the driver packages appended survive"
    else
        bad "hamnix-drivers-base ships modules.dep.base but its install hook does not merge it -- the table would never be refreshed"
    fi
else
    bad "modules.dep is excluded on the grounds that modules.dep.base ships instead, and NO package carries modules.dep.base"
fi

# --- THE RIGHT NAME IS NOT THE RIGHT BYTES ---------------------------------
# Everything above this line compares NAMES. NORTH_STAR.md already records
# what that misses -- hamnix-desktop 1.0.10 shipped every name, every sha256
# matched, and the desktop mapped no windows -- and it missed it again, in a
# different subsystem and in a way no binary gate could see:
#
#   The `hpm` package shipped etc/hpm/channels, the NATIVE line's
#   subscription list, whose one entry is `main`. The image stages
#   etc/hpm/channels.LINUX at that path, whose entry is `linux`. Both files
#   are called etc/hpm/channels, so the comparison above was silent. What it
#   meant is that `hpm install hamnix-base` -- the flagship package, which
#   declares hpm>=1 -- REWROTE the machine's subscription to a channel of
#   NATIVE binaries, and every `hpm refresh` and `hpm update` afterwards
#   aborted on a 404 for https://255.one/main/index.json.sig. A machine was
#   cut off from its own repository by the act of installing from it.
#
# So: for every /etc file the image stages AND a package carries, compare the
# BYTES. /etc is the whole scope on purpose -- the binaries are covered by
# tests/linux/channel_runs_desktop.sh, which RUNS them, and a per-byte compare
# of an ELF would go red on any legitimate rebuild. A configuration file has
# no such excuse: if the channel's copy differs from the one the image boots
# with, one of the two is wrong and nobody knows which.
echo
: > "$TMP/etcdiff"
ETCN=0
UNPACK="$TMP/unpack"; mkdir -p "$UNPACK"
for t in "$CHAN"/packages/*.tar.gz; do
    [ -e "$t" ] || continue
    tar xzf "$t" -C "$UNPACK" --wildcards '*/files/etc/*' 2>/dev/null || true
done
#
# TWO KINDS OF ENTRY ARE SKIPPED, and neither is a judgement call:
#   * a file the channel carries and the image does not stage AT ALL is not a
#     mismatch -- it is the "more in the channel than the image" case, already
#     reported at the end of this file. etc/rc.boot.linux, .installed and
#     .machine are all of these: the image stages one of them AS /etc/rc.boot.
#   * etc/rc.boot itself, whose difference is the DESIGN: the channel ships
#     etc/rc.boot.machine there (the one-line `source '/etc/rc.boot.installed'`)
#     while the image stages etc/rc.boot.linux, and hpm's _is_machine_owned
#     keeps whichever one a machine already has. Named here with its reason,
#     the same way every exclusion in this file is.
ETC_BYTE_SKIP="etc/rc.boot"
while IFS= read -r rel; do
    case " $ETC_BYTE_SKIP " in *" $rel "*) continue ;; esac
    [ -f "$IMG/$rel" ] || continue
    src="$(find "$UNPACK" -path "*/files/$rel" -type f 2>/dev/null | head -1)"
    [ -n "$src" ] || continue
    ETCN=$((ETCN + 1))
    cmp -s "$src" "$IMG/$rel" || printf '%s\n' "$rel" >> "$TMP/etcdiff"
done < <(grep '^etc/' "$TMP/chan")
# `grep -c . file` on a missing file PRINTS 0 and EXITS 1, so the obvious
# `$(grep -c . f || echo 0)` produced the two-line string "0\n0", and
# `[ "0\n0" -gt 0 ]` is not false -- it is an ERROR ("integer expression
# expected", exit 2), which fell through to the PASS branch. The comparison
# was therefore decided by a shell error every time it was clean, which is
# this project's own worst shape in a gate: a pass that is not an answer.
NDIFF=$( [ -s "$TMP/etcdiff" ] && grep -c . "$TMP/etcdiff" || echo 0 )
if [ "$ETCN" -lt 5 ]; then
    bad "only $ETCN /etc files were found in both the image and the channel -- this comparison is not measuring anything"
elif [ "$NDIFF" -gt 0 ]; then
    while IFS= read -r d; do
        bad "/$d in the channel is NOT the bytes the image boots with -- an installed machine's copy is replaced by a different file on every update, and nothing says which one is right"
        diff "$(find "$UNPACK" -path "*/files/$d" -type f | head -1)" "$IMG/$d" \
            | head -8 | sed 's|^|      |'
    done < "$TMP/etcdiff"
else
    ok "all $ETCN /etc files the channel carries are BYTE-IDENTICAL to the ones the image stages -- no package quietly replaces a machine's configuration with a different file"
fi

# The other direction is NOT a failure -- a channel may offer more than the
# initramfs has room for -- but it is worth saying out loud, because a file in
# the channel and not the image is a file nobody has ever seen on a live boot.
EXTRA=$(comm -13 "$TMP/img" "$TMP/chan" | grep -c . || true)
if [ "$EXTRA" -gt 0 ]; then
    echo
    echo "note: $EXTRA files in the channel and not the image (never exercised on a live boot):"
    comm -13 "$TMP/img" "$TMP/chan" | sed 's|/[^/]*$||' | sort | uniq -c | sort -rn | head -12 | sed 's|^|    |'
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
