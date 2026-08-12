#!/usr/bin/env bash
# scripts/hamlinux_runsweep.sh — build every user/*.ad through the Linux lane
# and then RUN it, on the host, and record what actually happened.
#
# scripts/hamlinux_sweep.sh measures which applications BUILD. Building is not
# running: on this port the interesting failures are runtime ones, and the
# worst of them are not crashes at all but calls that answer something
# success-shaped instead of the truth (HANDOFF.md §0). So this sweep measures
# three things per application and keeps them separate:
#
#   did it build      exit status of scripts/hamlinux_build.sh
#   did it run        exit status / signal / timeout of the program itself
#   did it DO it      what came out of stdout, and what files it changed
#   what did it COST  cpu seconds next to wall-clock seconds, because a park
#                     and a busy spin are identical in every other column here
#                     (THE IDLE CENSUS, HANDOFF §0 — the desktop burned two
#                     cores while every gate on this tree passed)
#
# THE ORACLE IS THE PROGRAM'S OWN HEADER, NOT GNU COREUTILS. `wc` and `head`
# in this tree are stdin-only and ignore file operands, and their headers say
# so; testing them against GNU behaviour manufactures failures out of programs
# that are working correctly (HANDOFF.md §5). The per-application invocation
# and the one-line statement of what each program claims to do therefore live
# in a table, tests/linux/runsweep_recipes.tsv, derived from the headers.
#
# WHERE IT RUNS. On the host, not in QEMU: the runtime is the same one, VM
# boots serialise, and the synthetic devices all have offscreen/scratch modes.
# Every program runs inside `unshare -rm` on an overlay over a staged root, so
# a program that writes to /bin or /etc writes into a throwaway upper layer --
# and that upper layer is then the exact diff of what it changed, which is how
# "created the file and left it empty" becomes visible.
#
# Usage:
#   scripts/hamlinux_runsweep.sh <outdir> [app ...]
#
# Env:
#   RUNSWEEP_JOBS      parallel build jobs (default: HAMLINUX_JOBS, see
#                      scripts/hamlinux_jobs.sh -- workers, not cores)
#   RUNSWEEP_TIMEOUT   seconds for an ordinary program (default 5)
#   RUNSWEEP_DTIMEOUT  seconds a daemon/GUI client is given to stay up
#                      (default 12; MUST exceed the DE's readiness handshakes
#                      — see the note at DTMO below)
#   RUNSWEEP_NOBUILD=1 reuse <outdir>/obj from a previous run
#
# Output:
#   <outdir>/results.tsv   one row per application, columns documented below
#   <outdir>/run/<app>.out <app>.err   captured streams
#   <outdir>/run/<app>.diff            the files it created or changed
#   <outdir>/obj/<app>.elf             the binary
#   <outdir>/summary.txt               counts by verdict and by class
#
# THE ROWS THAT ARE NOT IN THE NUMERATOR ARE NAMED, WITH THEIR REASONS, IN
# docs/runsweep_unhealthy.md. A score with no list behind it is an argument
# rather than a measurement, and the four reasons a row can be unhealthy --
# a name this port owes, hardware or privilege this harness withholds, a
# launcher it does not run, and its own mistakes -- need four different
# responses. Read it before deciding what a number here means.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

OUT="${1:?usage: hamlinux_runsweep.sh <outdir> [app ...]}"; shift
OUT="$(mkdir -p "$OUT" && cd "$OUT" && pwd)"
. "$(dirname "$0")/hamlinux_jobs.sh"
JOBS="${RUNSWEEP_JOBS:-$HAMLINUX_JOBS}"
TMO="${RUNSWEEP_TIMEOUT:-5}"
# 12, NOT 4. A DE client does not fail the instant it cannot find the
# compositor: lib/hamscreen.ad waits 100 x 100 ms for /dev/wsys/screen to be
# published and lib/hamwid.ad waits 20 x 100 ms for /dev/wsys/self, because
# rc.5's `sleep 1` is a guess a slow boot can outrun and a readiness
# handshake is the correct answer to a startup race. At DTMO=4 the sweep
# killed those clients MID-HANDSHAKE, before they could print the named
# FATAL they were about to print, and then scored them UP_NO_WINDOW — "alive
# at the timeout, owning no window", which reads as a client that came up
# and did nothing. hamlock, hamtoast, hamshotui and hampanelscene were all
# recorded that way while being, in fact, correct: run with 15 s each prints
# "[hamlock]: FATAL: no screen geometry ..." and exits 1. A harness that
# times out a program's error path and reports the silence as the program's
# behaviour is making exactly the mistake this sweep exists to catch, so the
# floor is now longer than the longest handshake in the tree (10 s) plus
# room to print and exit.
DTMO="${RUNSWEEP_DTIMEOUT:-12}"
RECIPES="$PROJ_ROOT/tests/linux/runsweep_recipes.tsv"
JAIL="$PROJ_ROOT/tests/linux/runsweep_jail.sh"

# THE FILE-SIZE CAP, IN 1024-BYTE BLOCKS (bash's `ulimit -f` unit), and there
# are two of them for one reason: the window system's shared segments are
# SPARSE FILES whose SIZE is enormous and whose block usage is not. The full
# argument, the measurements and the three times this has been got wrong are
# at the head of jail_run below.
#
#   FCAP_PLAIN  256 MiB. What `yes` and friends are held to, because their
#               bytes are real bytes and this is somebody's disk.
#   FCAP_WSYS   6 GiB, for the rows that run a compositor. It must exceed
#               BB_FILE_BYTES in user/linux-wsys.c, which at WSYS_MAX_WINDOWS
#               = 256 is 4,261,478,400 bytes; the headroom is for the next
#               time that constant moves. The jail reports HARNESS_FAIL if
#               the compositor dies anyway, so an outgrown cap is loud.
FCAP_PLAIN="${RUNSWEEP_FCAP:-262144}"
FCAP_WSYS="${RUNSWEEP_FCAP_WSYS:-6291456}"

# AND IT IS CHECKED, NOT REMEMBERED. The cap has been wrong twice, both times
# because a CONSTANT MOVED and a comment did not, and the second time it cost
# fifty rows. So the requirement is re-derived from user/linux-wsys.c here,
# before anything runs, and a cap that no longer covers the pool is a fatal
# error naming both numbers rather than a sweep full of dead compositors.
#
# BB_HDR_BYTES is `sizeof(struct bbshm)` rounded up to BB_ALIGN and cannot be
# read out of the source, so 1 MiB is added instead -- comfortably more than
# the header can be at any plausible slot count, and the pixel pages are what
# the size is made of anyway.
wsys_pool_bytes() {
    awk '
        /^#define WSYS_MAX_WINDOWS/ { n = $3 }
        /^#define BB_W  / { w = $3 }
        /^#define BB_H  / { h = $3 }
        /^#define BB_ALIGN / { a = $0; gsub(/[^0-9]/, "", a); a = a + 0 }
        END {
            if (n == 0 || w == 0 || h == 0 || a == 0) { print 0; exit }
            page = int((w * h * 4 + a - 1) / a) * a
            print 1048576 + n * 2 * page
        }' "$PROJ_ROOT/user/linux-wsys.c"
}
POOL_BYTES="$(wsys_pool_bytes)"
if [ "${POOL_BYTES:-0}" -gt 0 ]; then
    POOL_BLOCKS=$(( (POOL_BYTES + 1023) / 1024 ))
    if [ "$FCAP_WSYS" -lt "$POOL_BLOCKS" ]; then
        echo "[runsweep] FATAL: the windowed-row file cap is smaller than the window system's backbuffer pool." >&2
        echo "[runsweep]   cap  $FCAP_WSYS blocks ($((FCAP_WSYS / 1024)) MiB)" >&2
        echo "[runsweep]   pool $POOL_BLOCKS blocks ($((POOL_BLOCKS / 1024)) MiB), derived from" >&2
        echo "[runsweep]        WSYS_MAX_WINDOWS / BB_W / BB_H / BB_ALIGN in user/linux-wsys.c" >&2
        echo "[runsweep]   wsysd's ftruncate(2) would be refused EFBIG and the kernel would kill" >&2
        echo "[runsweep]   it with SIGXFSZ AFTER it published a screen geometry, and every GUI" >&2
        echo "[runsweep]   row would be measured against no compositor. That has happened twice;" >&2
        echo "[runsweep]   raise RUNSWEEP_FCAP_WSYS rather than reading fifty broken programs." >&2
        exit 2
    fi
fi

# ---------------------------------------------------------------------------
# THE COMPOSITOR
# ---------------------------------------------------------------------------
# WHY. Until this landed, the sweep could not test a GUI program. It ran every
# scene client in a jail with NO WINDOW SYSTEM in it, and the five that ask
# lib/hamscreen.ad how big the screen is -- hamlock, hampanelscene, hamshotui,
# hamtoast, wsyswl -- correctly refused to guess and exited 1. Those five rows
# were the visible part. The invisible part was worse: for every OTHER windowed
# program the verdict was "did it exit", because a client can create the shared
# /dev/wsys segment and map a window into it all by itself. Nothing composited
# anything, so nothing could tell a client that DREW from one that mapped a
# window and painted nothing -- which is exactly how a v2 blit client came to
# score DREW_WINDOW with a 0-byte backbuffer and not one pixel ever stored
# (the ulimit note in jail_run below).
#
# So a `gui` row now runs with user/wsysd.ad up in the same jail, offscreen,
# and the sweep reads the FRAMEBUFFER afterwards. See tests/linux/runsweep_jail.sh
# for the mechanism and PAINTED below for what the pixels are asked.
#
# ONE COMPOSITOR PER PROGRAM, and that is not the expensive choice it sounds
# like. The alternative -- one compositor for the whole gui class -- would mean
# one overlay for the whole gui class, and the per-program upper layer IS this
# sweep's diff and its isolation both. /srv/wsys, /srv/wsys.bb, /srv/wsys.img
# and /run/fb.raw default to one file per HOST (docs/steam_namespace.md §11,
# where a stale backbuffer slot cost an hour), so a shared compositor would
# hand each program the previous program's windows and its previous frame --
# and the framebuffer question below would then be unanswerable, because the
# pixels on the screen would belong to whoever ran before. Measured cost of
# doing it per program is in the summary this script prints.
#
# RUNSWEEP_WSYSD=0 turns it off and restores the old behaviour exactly.
WSYSD_BIN="/bin/wsysd"
[ "${RUNSWEEP_WSYSD:-1}" = 0 ] && WSYSD_BIN=""
FBGEOM="${RUNSWEEP_GEOM:-1280x800}"
FBW="${FBGEOM%x*}"; FBH="${FBGEOM#*x}"
# FORCED, always, per NORTH_STAR's standing constraint: wsysd arms a real
# Vulkan backend on real silicon, and this host's GPU belongs to someone who is
# using it. lavapipe is a CPU device, so wsysd's own gate leaves the software
# rasterizer armed as well. (The staged root has no Vulkan tree at all, so
# there is nothing to dlopen either -- this is the belt to that pair of braces,
# and it is set on EVERY jail_run, not only the composited ones.)
VKICD="${VK_ICD_FILENAMES:-/usr/share/vulkan/icd.d/lvp_icd.json}"
# The two per-call switches, read by tests/linux/runsweep_jail.sh.
JWSYSD=""
JWINPROBE=""
JFBSNAP=""

command -v unshare >/dev/null || { echo "need util-linux unshare" >&2; exit 1; }
unshare -rm true 2>/dev/null || { echo "need unprivileged user namespaces" >&2; exit 1; }

if [ $# -gt 0 ]; then APPS=("$@"); else
    mapfile -t APPS < <(ls user/*.ad | sed 's|user/||; s|\.ad$||')
fi

mkdir -p "$OUT/obj" "$OUT/run" "$OUT/ov"

# ---------------------------------------------------------------------------
# 1. build
# ---------------------------------------------------------------------------
if [ -z "${RUNSWEEP_NOBUILD:-}" ]; then
    echo "[runsweep] building ${#APPS[@]} applications, $JOBS at a time"
    # Serialise the shared runtime objects first: every parallel build would
    # otherwise race to compile user/linux-*.c into the same .o.
    scripts/hamlinux_build.sh user/echo.ad "$OUT/obj/echo.elf" >/dev/null 2>&1
    printf '%s\n' "${APPS[@]}" | nice -n "$HAMLINUX_NICE" xargs -P "$JOBS" -I{} \
        bash -c 'scripts/hamlinux_build.sh user/{}.ad '"$OUT"'/obj/{}.elf \
                 >/dev/null 2>'"$OUT"'/run/{}.build.err; echo "{} $?" \
                 >> '"$OUT"'/build.rc'
    # .ll files are large and reproducible.
    rm -f "$OUT"/obj/*.ll "$OUT"/obj/*.ll.emit.log "$OUT"/obj/*.ll.link.log
fi
# RUNSWEEP_NOBUILD against a directory that has binaries but no build log: take
# the presence of the ELF as the build result, so reusing someone else's obj/
# does not report the whole tree as a build failure.
if [ ! -f "$OUT/build.rc" ]; then
    : > "$OUT/build.rc"
    for a in "${APPS[@]}"; do
        [ -f "$OUT/obj/$a.elf" ] && echo "$a 0" >> "$OUT/build.rc"
    done
fi
declare -A BRC
while read -r a r; do BRC[$a]="$r"; done < "$OUT/build.rc"

# ---------------------------------------------------------------------------
# 2. stage the base root, once
# ---------------------------------------------------------------------------
# Deliberately the same layout scripts/hamlinux_image.sh stages into the
# initramfs, so a program finds the /etc it was written against. Anything a
# program writes lands in a per-run overlay upper layer, never here.
BASE="$OUT/base"
echo "[runsweep] staging $BASE"
rm -rf "$BASE"
mkdir -p "$BASE"/{bin,dev,etc,proc,sys,srv,n,tmp,root,boot,run,work,mnt,lib,lib64} \
         "$BASE"/{var/log,var/lib/hpm,var/cache,usr/bin,usr/share/adder,home/live}
chmod 1777 "$BASE/tmp"

for a in "${APPS[@]}"; do
    [ "${BRC[$a]:-1}" = 0 ] && install -m755 "$OUT/obj/$a.elf" "$BASE/bin/$a"
done
# `cat` is staged whether or not it is in this run's app list: the window probe
# below reads /dev/wsys/windows with it, and a sweep of one application would
# otherwise report "no window" because the probe could not run.
[ -f "$OUT/obj/cat.elf" ] && install -m755 "$OUT/obj/cat.elf" "$BASE/bin/cat"
# THE COMPOSITOR, staged the same way and for the same reason. `wsysd` and
# `sleep` are what a GUI row needs to be a measurement rather than a
# bereavement (see WSYSD below), and a sweep of one named application would
# otherwise find neither in obj/ -- so build them here if this run did not.
if [ "${RUNSWEEP_WSYSD:-1}" != 0 ]; then
    for w in wsysd sleep; do
        [ -f "$OUT/obj/$w.elf" ] || scripts/hamlinux_build.sh "user/$w.ad" \
            "$OUT/obj/$w.elf" >/dev/null 2>"$OUT/run/$w.build.err"
        [ -f "$OUT/obj/$w.elf" ] && install -m755 "$OUT/obj/$w.elf" "$BASE/bin/$w"
    done
fi
# /bin/install is the same program as hlinstall (haminstallui spawns that name).
[ -f "$BASE/bin/hlinstall" ] && install -m755 "$BASE/bin/hlinstall" "$BASE/bin/install"
[ -f build/cutover/host_ac.elf ] && install -m755 build/cutover/host_ac.elf "$BASE/bin/host_ac"
install -m644 user/linux-runtime.S user/linux-*.c user/linux-*.h \
    user/syscall_nums.h scripts/adder_llvm_runtime.c "$BASE/usr/share/adder/" 2>/dev/null
install -m644 scripts/ac-link.sh "$BASE/usr/share/adder/ac-link.sh" 2>/dev/null
install -m644 tests/linux/hello.ad "$BASE/usr/share/adder/hello.ad" 2>/dev/null

# glibc and the loader: this lane links dynamically (HANDOFF §7.4).
#
# The probe must be a binary THIS LANE built, and it used to be
# `ls -1 "$BASE"/bin/* | head -1` — whatever sorted first. That is fine for a
# whole-tree sweep only by luck: `ac` sorts first and is dynamic, so old and
# new pick the same file and the whole-tree numbers are unaffected. For a sweep
# of a named subset it is not, because `host_ac` is staged unconditionally a few
# lines above and is STATICALLY linked, so `ldd` printed nothing, `readelf`
# found no interpreter, no libc and no loader were staged, and every program in
# the run died with rc 127 / "No such file or directory" — which the jail
# reports as the PROGRAM's exit status. Eight applications that run correctly
# were scored EXIT_NONZERO by a staging bug in the harness. That is precisely
# the failure this sweep exists to catch, made by the sweep.
#
# So: walk the staged binaries and take the first that actually HAS a PT_INTERP.
probe=""
for p in "$BASE"/bin/*; do
    [ -f "$p" ] || continue
    if readelf -l "$p" 2>/dev/null | grep -q 'interpreter'; then probe="$p"; break; fi
done
[ -n "$probe" ] || probe="$(ls -1 "$BASE"/bin/* 2>/dev/null | head -1)"
ldd "$probe" 2>/dev/null | awk '/=> \//{print $3}' | sort -u | while read -r lib; do
    mkdir -p "$BASE$(dirname "$lib")"; cp -Ln "$lib" "$BASE$lib" 2>/dev/null
done
INTERP="$(readelf -l "$probe" | awk -F': *' '/interpreter/{sub(/\]$/,"",$2); print $2}')"
[ -n "$INTERP" ] && { mkdir -p "$BASE$(dirname "$INTERP")"; cp -L "$INTERP" "$BASE$INTERP"; }
# The resolver dlopen()s these at run time; without them `host` would fail for
# a reason that has nothing to do with this port.
for l in /lib/x86_64-linux-gnu/libnss_{files,dns}.so.2; do
    [ -f "$l" ] && cp -L "$l" "$BASE$l" 2>/dev/null
done

cp -a etc/. "$BASE/etc/"
# /version, the same plain root file scripts/hamlinux_image.sh puts in the
# initramfs (and the same name Hamnix's own build_initramfs.py plants). It is
# staged here for the same reason the manual pages are: `hello` opens it and
# prints it, and a root that does not carry it makes the sweep measure its own
# staging instead of the program.
printf 'hamnix-linux -- Adder userland on Linux %s, run sweep (%s)\n' \
    "$(uname -r)" \
    "$(git -C "$PROJ_ROOT" describe --always --dirty 2>/dev/null || echo unknown)" \
    > "$BASE/version"
# The manual pages, staged EXACTLY where scripts/hamlinux_image.sh puts them.
# Without this the sweep was not measuring `help` and `man`, it was measuring
# its own staging: both walk /usr/share/man/, both found an empty tree, and
# `help` reported that and exited 0 — so the sweep recorded a pass for a
# discovery command that had discovered nothing. A smoke test whose root is
# not the root the program ships against manufactures its own failures
# (HANDOFF.md §5, the same reason the recipes' oracle is each program's own
# header and not GNU coreutils).
mkdir -p "$BASE/usr/share/man"
install -m644 etc/man/*.md "$BASE/usr/share/man/" 2>/dev/null || true
install -m644 etc/rc.boot.linux       "$BASE/etc/rc.boot"
install -m644 etc/rc.d/rc.5.linux     "$BASE/etc/rc.d/rc.5"
install -m644 etc/rc.de-user.linux    "$BASE/etc/rc.de-user"
install -m644 etc/hpm/channels.linux  "$BASE/etc/hpm/channels"
install -m644 etc/users/live.ns.linux "$BASE/etc/users/live.ns"
install -m600 etc/shadow              "$BASE/etc/shadow"
cp -a etc/skel/. "$BASE/home/live/" 2>/dev/null
# glibc wants these two and they are not the distribution's business.
cp -L /etc/ld.so.cache "$BASE/etc/ld.so.cache" 2>/dev/null
cp -L /etc/nsswitch.conf "$BASE/etc/nsswitch.conf" 2>/dev/null

# Mount points for the six device files the jail binds in. Nothing else in
# /dev exists, so /dev/sda and /dev/dri are simply not there.
for d in null zero full tty random urandom; do : > "$BASE/dev/$d"; done
# Console the Hamnix way: rc.boot does `ln -s /dev/console /dev/cons`, and a
# console that is not connected to anything is how output silently vanishes.
ln -sf /proc/self/fd/1 "$BASE/dev/console"
ln -sf /proc/self/fd/1 "$BASE/dev/cons"
ln -sf /proc/self/fd/0 "$BASE/dev/stdin"
ln -sf /proc/self/fd/1 "$BASE/dev/stdout"
ln -sf /proc/self/fd/2 "$BASE/dev/stderr"

# The fixtures the recipe placeholders name.
printf 'alpha beta gamma\ndelta epsilon\nzeta eta theta\n'   > "$BASE/work/f1.txt"
printf 'delta epsilon\nalpha beta gamma\nomega\n'            > "$BASE/work/f2.txt"
mkdir -p "$BASE/work/d/sub"
printf 'one\ntwo\n' > "$BASE/work/d/one.txt"
printf 'three\n'    > "$BASE/work/d/sub/two.txt"

# The *_host harnesses are written to be run FROM THE REPOSITORY ROOT: they
# slurp "fonts/dejavu-sans.ttf" and write "build/host/*.ppm" by relative name.
# /work is their cwd here, so those names have to resolve from /work or the
# harness measures its own staging instead of the program.
cp -a fonts "$BASE/work/fonts"
mkdir -p "$BASE/work/build/host" "$BASE/work/tests"
cp -a tests/fixtures "$BASE/work/tests/fixtures" 2>/dev/null
# A real gzip stream, so `gunzip` is tested on gzip rather than on prose.
gzip -c "$BASE/work/f1.txt" > "$BASE/work/f1.gz" 2>/dev/null

# A REAL display list for scene_raster_host, dumped by the program whose own
# error message names it: "cannot open the display list -- dump one with
# hamdesktop/hampanelscene --scene-dump". The harness had been handed the
# literal argv `in.dl out.ppm`, so it opened a file that has never existed and
# the sweep recorded the refusal as the rasterizer's failure.
[ -x "$OUT/obj/hamdesktop.elf" ] && \
    "$OUT/obj/hamdesktop.elf" --scene-dump "$BASE/work/scene.dl" >/dev/null 2>&1

# The two BMP fixtures hamsdl_image_host asserts against, generated exactly as
# scripts/test_hamsdl_image_host.sh generates them (24-bit coordinate-coded so
# a sample nails channel + row order; 32-bit half-opaque for the alpha blend).
# It had been handed %F %F2 -- two text files -- and "loads BMP sprite(s)"
# cannot be judged from a harness fed prose.
python3 - "$BASE/work/fix24.bmp" "$BASE/work/fix32.bmp" <<'PY' 2>/dev/null
import struct, sys
def bmp(width, height, bitcount, px):
    bpp = bitcount // 8
    stride = (width * bpp + 3) & ~3
    pad = stride - width * bpp
    rows = bytearray()
    for fy in range(height):                 # BMP is bottom-up
        y = height - 1 - fy
        for x in range(width):
            b, g, r, a = px(x, y)
            rows += bytes((b, g, r, a)) if bpp == 4 else bytes((b, g, r))
        rows += b'\x00' * pad
    off = 14 + 40
    fh = b'BM' + struct.pack('<IHHI', off + len(rows), 0, 0, off)
    ih = struct.pack('<IiiHHIIiiII', 40, width, height, 1, bitcount, 0,
                     len(rows), 2835, 2835, 0, 0)
    return fh + ih + bytes(rows)
open(sys.argv[1], 'wb').write(bmp(8, 8, 24, lambda x, y: (200, 16 + y * 24, 16 + x * 24, 255)))
open(sys.argv[2], 'wb').write(bmp(8, 8, 32, lambda x, y: (0, 255, 0, 255 if x < 4 else 128)))
PY

# ---------------------------------------------------------------------------
# 3. run
# ---------------------------------------------------------------------------
declare -A CLASS ARGV STDIN CLAIM
if [ -f "$RECIPES" ]; then
    # Split by hand rather than with `IFS=$'\t' read`: tab is IFS WHITESPACE,
    # so read collapses two adjacent tabs into one and every row with an empty
    # argv silently shifts its stdin and claim one column left. That bug fed
    # `wc` its own description instead of the fixture and the sweep still
    # looked fine -- the same shape as everything in HANDOFF §0.
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        case "$line" in \#*) continue ;; esac
        n="${line%%$'\t'*}";    rest="${line#*$'\t'}"
        c="${rest%%$'\t'*}";    rest="${rest#*$'\t'}"
        a="${rest%%$'\t'*}";    rest="${rest#*$'\t'}"
        s="${rest%%$'\t'*}";    cl="${rest#*$'\t'}"
        # THE ARGV COLUMN IS CHECKED BEFORE ANYTHING RUNS, and a bad one is
        # fatal to the whole sweep rather than to one row.
        #
        # A bare `-` is the STDIN column's sentinel. Pasted here it is a
        # literal argument, and that has now bitten this table three times:
        # `mktemp -`, `route -` and `pr -` each answered CORRECTLY to a
        # question nobody meant to ask and were scored as broken programs;
        # 47 more rows carried it silently. A BLANK column is the same slip
        # from the other side -- it is exactly what a collapsed tab looks
        # like, the bug that once fed `wc` its own description.
        #
        # Neither can be told apart from a deliberate choice by looking at
        # the row, so neither is allowed to BE one. "No arguments" has one
        # spelling, `EMPTY`, and a row that really wants a lone dash writes
        # %DASH. Fixing the 47 rows would have left the fourth time to
        # happen; this is what stops it.
        case "$a" in
            "")  echo "[runsweep] FATAL $RECIPES: row '$n' has a BLANK argv column." >&2
                 echo "[runsweep]   Write EMPTY for no arguments (a blank column is" >&2
                 echo "[runsweep]   indistinguishable from a collapsed tab)." >&2
                 exit 2 ;;
            -)   echo "[runsweep] FATAL $RECIPES: row '$n' has a bare '-' argv column." >&2
                 echo "[runsweep]   '-' is the STDIN column's sentinel; here it is a" >&2
                 echo "[runsweep]   literal argument. Write EMPTY for no arguments, or" >&2
                 echo "[runsweep]   %DASH if a lone dash is genuinely wanted." >&2
                 exit 2 ;;
            EMPTY) a="" ;;
        esac
        CLASS[$n]="$c"; ARGV[$n]="$a"; STDIN[$n]="$s"; CLAIM[$n]="$cl"
    done < "$RECIPES"
fi

: > "$OUT/results.tsv"
printf '#app\tclass\tbuild\tverdict\trc\tsecs\tcpu\tout\terr\tchanged\tempty\twins\tfbpx\tdetail\tclaim\n' \
    >> "$OUT/results.tsv"

# CPU SECONDS, next to wall-clock seconds, because THE IDLE CENSUS (HANDOFF §0)
# was invisible to every functional gate on this tree — including this one.
# `sys_waitfds` could not sleep, `sleep` was a busy-wait, and a shell at a
# prompt burned a core; the desktop sat at 203.6% of one cpu and every gate
# here still passed, because a spin and a park produce the SAME exit status,
# the SAME output and the SAME wall clock. A sweep that runs 367 programs and
# never asks what any of them COST cannot see that class of defect at all.
#
# The measurement is bash's own `times`, whose second line is cumulative
# reaped-CHILD user+system time: sample it either side of the run and the
# difference is what that program burned.
#
# It answers through a GLOBAL, and that is not a style choice. `times` reports
# the counters of the shell that runs it, and $(...) forks -- so `c0=$(cpu_now)`
# samples a brand-new subshell whose children have used no time at all and
# every row reads 0.0. (Measured, in this file: `yes` spinning for 12 s
# reported cpu 0.0.) `{ times; }` with a plain redirect does not fork, and the
# assignment below happens in the caller's own shell.
CPU_NOW=0
cpu_now() {
    { times; } > "$OUT/.times"
    CPU_NOW=$(awk 'NR==2{ n=0
                for (i = 1; i <= NF; i++) {
                    split($i, a, "m"); sub(/s$/, "", a[2])
                    n += a[1] * 60 + a[2]
                }
                printf "%.2f", n }' "$OUT/.times")
}

# The programs whose CONTRACT is to say nothing and change nothing. Without
# this list `true` is indistinguishable from a program that did not run.
#
# The bar for being on this list is that SILENCE IS THE CORRECT ANSWER, not
# merely that the program happens to be quiet:
#   true / false   their entire output is the exit status
#   sync           its effect is on the block layer, not in the filesystem
#   sleep          its whole job is to consume wall-clock time — and the
#                  sweep records `secs`, so "slept" and "returned instantly"
#                  are still distinguishable in the results (sleep 1 = 1.0)
#   test           the exit status IS the answer; printing would be a bug
#   pathchk        speaks only when an operand is BAD; a valid path is a
#                  silent 0, which is the POSIX contract
# Anything else that lands in SILENT_OK is a finding, not a false positive.
EXPECT_SILENT="true
sync
sleep
test
pathchk"

# The programs whose CONTRACT is a NON-ZERO exit under this recipe. Without
# this the sweep reports a failure for programs behaving exactly as specified —
# the same manufactured result as the 4 s GUI timeout, only in the opposite
# direction, and just as dishonest in a headline number.
#
# It is a TABLE with a REASON PER ROW, not a bare list, and the reason is
# written into the results row. The bar, what qualifies and what emphatically
# does not (a device this port owes and does not have is a REAL gap and stays
# unhealthy), is stated at the top of that file:
#
#   tests/linux/runsweep_expected_fail.tsv
#
# A row there still has to produce its normal output; it is scored
# EXPECTED_FAIL and counted with the healthy, and anything that lands there
# without earning it is a finding exactly like a stray SILENT_OK.
XFAILS="$PROJ_ROOT/tests/linux/runsweep_expected_fail.tsv"
declare -A XFAIL
if [ -f "$XFAILS" ]; then
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        case "$line" in \#*) continue ;; esac
        XFAIL["${line%%$'\t'*}"]="${line#*$'\t'}"
    done < "$XFAILS"
fi

# THE FRAMEBUFFER COMPARATOR. Counts the sampled pixels in which two frames
# differ. Rows are compared whole first, so an unchanged row costs one memcmp
# and a bare screen costs ~400 of them; only a row that differs is walked.
FBCMP="$OUT/.fbcmp.py"
cat > "$FBCMP" <<'PY'
import sys
ref = open(sys.argv[1], 'rb').read()
cur = open(sys.argv[2], 'rb').read()
W, H = int(sys.argv[3]), int(sys.argv[4])
need = W * H * 4
if len(ref) < need or len(cur) < need:
    print(-1); raise SystemExit
n = 0
stride = W * 4
for y in range(0, H, 2):
    o = y * stride
    a = ref[o:o + stride]; b = cur[o:o + stride]
    if a == b:
        continue
    for x in range(0, stride, 8):
        if a[x:x + 3] != b[x:x + 3]:
            n += 1
print(n)
PY

# One invocation of the jail. Everything the program can see is set here:
# env -i so the developer's environment cannot leak in and make a result
# unreproducible, and the HAM* variables pointing every synthetic device at
# a path inside the throwaway root.
jail_run() {   # jail_run <timeout> <stdin-file> <out> <err> <argv...>
    local jt="$1" jin="$2" jout="$3" jerr="$4"; shift 4
    # The file-size cap for THIS run: the pool-sized one when a compositor
    # is in the jail, the ordinary one otherwise. See the note below.
    local FCAP="$FCAP_PLAIN"
    [ -n "$JWSYSD" ] && FCAP="$FCAP_WSYS"
    # A safety net, not a test parameter: `yes` writes for ever by design
    # and would otherwise fill the disk in the seconds it is given.
    #
    # 256 MiB, NOT 4 MiB, and the four zeroes are the whole point. The
    # window system's shared segments are FILES, and two of them are
    # large: /srv/wsys.bb is BB_SLOTS(8) x 2 x 1920x1080x4 = 132 MB of
    # v2 backbuffer, and /srv/wsys.img is the 4,195,144-byte named-image
    # store. `ulimit -f` bounds the OFFSET a process may write, so at 4096
    # blocks (4,194,304 bytes) BOTH ftruncate(2)s were refused EFBIG --
    # the image store by 840 bytes.
    #
    # What that did to the measurement, A/B in the same jail with the same
    # binary (tests/linux/runsweep_jail.sh, /bin/hamimgscene):
    #
    #   ulimit -f 4096   -> "[hamimgscene] FATAL: the 'I' named-image
    #                        upload to /dev/wsys/2/draw/ctl was refused,
    #                        rc=-5", exit 2; /srv/wsys.img 0 bytes
    #   ulimit -f 16384  -> "[hamimgscene] scene window ready with the
    #                        32x32 image uploaded"; /srv/wsys.img 4195144
    #
    # So the sweep reported the named-image tier as broken when the tier
    # works and the HARNESS refused it -- and it did worse than that with
    # the backbuffer, silently: a v2 blit client attaches its window
    # (2.5 MB, under the cap), so the window probe found a wid and the row
    # was scored DREW_WINDOW, while /srv/wsys.bb stayed 0 bytes and not one
    # pixel was ever stored. `sdlpong` under this jail: wsys.bb 0 bytes at
    # 4 MiB and at 16 MiB, 132,710,628 bytes with no cap. "Came up and
    # drew" for a client that drew nothing is precisely the success-shaped
    # answer this sweep exists to catch, manufactured by the sweep.
    #
    # AND IT HAPPENED A THIRD TIME, because the paragraph above quotes a
    # NUMBER that the window system then outgrew. `BB_SLOTS(8)` is stale:
    # user/linux-wsys.c's WSYS_MAX_WINDOWS went 8 -> 64 -> 128 -> 256 (the
    # last for wsyswl's MAXCONN), BB_SLOTS follows it, and BB_FILE_BYTES is
    # now 65536 + 256 * 2 * 8323072 = 4,261,478,400 bytes -- SIXTEEN TIMES
    # the 256 MiB cap. So `wsysd`'s ftruncate(2) of /srv/wsys.bb was
    # refused EFBIG and the kernel killed it with SIGXFSZ, AFTER it had
    # already printed "wsysd: screen 1280x800" and passed the readiness
    # gate. Every client behind it then found no compositor:
    #
    #   50 of the sweep's 88 windowed rows scored UP_NO_WINDOW / rc 153,
    #   and PAINTED fell from 51 to 2.
    #
    # Measured, same binary, same jail, /bin/hamclock:
    #   ulimit -f  262144 -> wsysd killed, wsys.bb 0 bytes, wins 0, fbpx -
    #   ulimit -f 6291456 -> wsys.bb 4,261,478,400 bytes, wins 1,
    #                        fbpx 52117 (PAINTED)
    #
    # THE FILE IS SPARSE, which is why this is a cap on an OFFSET and not
    # on disk: 4 GB of ftruncate cost 22,856 KiB of actual blocks in that
    # run. So the pool-sized cap is given ONLY to the rows that run a
    # compositor, and everything else -- `yes` included -- keeps the 256
    # MiB the paragraph above argues for, because those rows write their
    # bytes for real.
    #
    # A stale number here is not allowed to be silent again: the jail
    # reports HARNESS_FAIL if the compositor is not alive at the end of a
    # run (tests/linux/runsweep_jail.sh, THE COMPOSITOR MUST OUTLIVE THE
    # PROGRAM), so the next time the pool outgrows this the sweep says so
    # instead of blaming fifty programs.
    ( ulimit -f "$FCAP"
      env -i \
        PATH=/bin:/usr/bin HOME=/root USER=root LOGNAME=root TERM=dumb \
        SHELL=/bin/hamsh PWD=/work TMPDIR=/tmp LANG=C \
        HAMWSYS=/srv/wsys HAMWSYS_BB=/srv/wsys.bb HAMWSYS_IMG=/srv/wsys.img \
        HAMFDNS=/srv/fdns HAMFDNS_DIR=/srv HAMNET=/srv/net \
        HAMFB_FILE=/run/fb.raw HAMFB_GEOM="$FBGEOM" \
        VK_ICD_FILENAMES="$VKICD" \
        RUNSWEEP_WSYSD="$JWSYSD" \
        RUNSWEEP_WSYSD_LOG="$OUT/run/$app.wsysd.log" \
        RUNSWEEP_WINPROBE="$JWINPROBE" \
        RUNSWEEP_FBSNAP="$JFBSNAP" \
        timeout -k 2 "$jt" \
        unshare -rmn --fork --pid --kill-child \
            "$JAIL" "$BASE" "$up" "$wk" "$mnt" "$@" \
        < "$jin" > "$jout" 2> "$jerr" ) 2>/dev/null
}

run_one() {
    local app="$1"
    local cls="${CLASS[$app]:-cmd}"
    local argv="${ARGV[$app]:-}"
    local sin="${STDIN[$app]:--}"
    local claim="${CLAIM[$app]:-}"

    # A LIBRARY MODULE IS NOT A BUILD FAILURE. rc 13 from
    # scripts/hamlinux_build.sh means the source has no `def main` at all --
    # user/http9.ad, user/net9.ad, user/httpdconf.ad and user/hambrowse_tabs.ad
    # are modules that hpm, the /net dialers, httpd and hambrowse IMPORT. They
    # emit every function they have and then have no `main` to link.
    #
    # This test has to come BEFORE the BUILD_FAIL test, and that ordering is
    # the whole bug it fixes: the recipes table has classified all four as
    # class `lib` with the skip reason "library: no main, nothing to run" for
    # as long as they have been in it, and not one of them ever reached that
    # line, because the build check fired first and scored them BUILD_FAIL.
    # The headline's `runnable` denominator subtracts NOT_SMOKE_TESTABLE and
    # BUILD_FAIL alike, so the SCORE was not wrong -- but the verdict table
    # said four libraries had failed to build, and HANDOFF.md's build count
    # believed it.
    #
    # Only for class `lib`. An application that lost its `main` is a real
    # regression and must still show up as a failure, so rc 13 on anything not
    # declared a library falls through to BUILD_FAIL below.
    if [ "${BRC[$app]:-1}" = 13 ] && [ "$cls" = lib ]; then
        printf '%s\t%s\t0\tNOT_SMOKE_TESTABLE\t-\t-\t-\t-\t-\t-\t-\t-\t-\t%s\t%s\n' \
            "$app" "$cls" "library module: no def main, nothing to link or run" \
            "$claim" >> "$OUT/results.tsv"
        return
    fi

    if [ "${BRC[$app]:-1}" != 0 ]; then
        printf '%s\t%s\t%s\tBUILD_FAIL\t-\t-\t-\t-\t-\t-\t-\t-\t-\t%s\t%s\n' \
            "$app" "$cls" "${BRC[$app]:-?}" \
            "$(grep -vE '^; ADDER_STAT' "$OUT/run/$app.build.err" 2>/dev/null \
               | grep -m1 -iE 'error|bailed|NOT-AN-APPLICATION' | cut -c1-120 | tr '\t\n' '  ')" \
            "$claim" >> "$OUT/results.tsv"
        return
    fi

    # Classes we do not pretend to smoke test blind, and the reason.
    local skip=""
    case "$cls" in
        lib)     skip="library: no main, nothing to run" ;;
        disk)    skip="wants a block device / partition table / filesystem image" ;;
        net)     skip="wants an outside host; the sweep stays offline" ;;
        payload) skip="runs as /init or as a bare-metal EL0 image, not as a program" ;;
        unsafe)  skip="$claim" ;;
    esac
    if [ -n "$skip" ]; then
        printf '%s\t%s\t0\tNOT_SMOKE_TESTABLE\t-\t-\t-\t-\t-\t-\t-\t-\t-\t%s\t%s\n' \
            "$app" "$cls" "$skip" "$claim" >> "$OUT/results.tsv"
        return
    fi

    local up="$OUT/ov/$app.up" wk="$OUT/ov/$app.wk" mnt="$OUT/ov/$app.mnt"
    # `unshare -r rm`: overlayfs leaves entries under the workdir owned by the
    # namespace's root, and outside the namespace those are not ours to delete.
    unshare -r rm -rf "$up" "$wk" "$mnt" 2>/dev/null || rm -rf "$up" "$wk" "$mnt"
    mkdir -p "$up" "$wk" "$mnt"

    # Placeholders. %NEW is a path that must NOT exist: a program that claims
    # to create something and exits 0 having created nothing is the failure
    # this sweep is looking for.
    argv="${argv//%F2//work/f2.txt}"
    argv="${argv//%F//work/f1.txt}"
    argv="${argv//%D//work/d}"
    argv="${argv//%NEW//work/new.out}"
    # Real files of the real format. A codec harness handed prose fails for a
    # reason that has nothing to do with this port.
    argv="${argv//%PNG//work/tests/fixtures/hambrowse_img_sample.png}"
    argv="${argv//%JPG//work/tests/fixtures/hambrowse_jpeg_444.jpg}"
    argv="${argv//%GIF//work/tests/fixtures/hambrowse_gif_plain.gif}"
    argv="${argv//%WAV//work/tests/fixtures/sounds/test.wav}"
    argv="${argv//%MP3//work/tests/fixtures/sounds/test.mp3}"
    argv="${argv//%GZ//work/f1.gz}"
    argv="${argv//%HMJV//work/tests/fixtures/videos/test.hmjv}"
    argv="${argv//%BMP24//work/fix24.bmp}"
    argv="${argv//%BMP32//work/fix32.bmp}"
    # A LONE DASH, spelled out loud. The recipes loader rejects a bare `-` in
    # the argv column because that is always the stdin sentinel arriving in
    # the wrong place; a row that really means "pass the program a `-`" says
    # so here and is then visibly deliberate in the table.
    argv="${argv//%DASH/-}"
    local -a av=()
    [ -n "$argv" ] && read -r -a av <<< "$argv"

    local sf="$OUT/ov/$app.in"
    case "$sin" in
        -)     : > "$sf" ;;
        %F)    cp "$BASE/work/f1.txt" "$sf" ;;
        # %b, not %s: a program that PROMPTS TWICE needs two lines, and the
        # recipes column writes them `line1\nline2`. With %s that backslash-n
        # stayed two characters, so `passwd` was handed ONE line containing a
        # literal \n for both prompts and answered "passwords do not match" --
        # correctly, to a question the harness had got wrong.
        *)     printf '%b\n' "$sin" > "$sf" ;;
    esac

    local t="$TMO"
    # `bench` is a BOUNDED experiment that simply takes longer than an
    # ordinary command, and it exists for the same reason DTMO is 12 and not
    # 4: at TMO=5 the sweep was killing programs one second before they
    # printed their answer and then reporting the silence as their behaviour.
    # Measured: user/nice_lo.ad and user/wakelat_hog.ad run fixed wall-clock
    # windows of WINDOW_JIFFIES 600 and 700 -- 6 s and 7 s at 100 Hz -- and
    # both were scored TIMEOUT, wakelat_hog with an EMPTY output column, which
    # reads as a CPU hog that never even started. They finish and print inside
    # DTMO. Unlike daemon/gui, a `bench` that is STILL running at the timeout
    # is a genuine TIMEOUT: its contract is to end.
    case "$cls" in daemon|gui|bench) t="$DTMO" ;; esac


    # WHICH ROWS GET A COMPOSITOR: the windowed classes, gui AND daemon.
    #
    # `daemon` is in for a reason that was measured rather than assumed. It
    # holds four windowed programs -- wsyswl, hamscreensaver, hamUId, distrofs
    # -- and wsyswl is one of the five this whole change is about: it is a
    # Wayland compositor that is itself a /dev/wsys CLIENT, so with the
    # compositor armed for `gui` only it went on failing "no screen geometry"
    # while the four scene clients beside it came up. Classing it `daemon` is
    # correct (it runs for ever); needing a window system is orthogonal to
    # that, so the switch follows the window probe and not the class name.
    #
    # EXCEPT THE COMPOSITOR ITSELF. Two wsysd instances on one offscreen
    # framebuffer would both hold the window table and both present, and the
    # wsysd row -- the one that measures the compositor -- would be measuring
    # a fight. Its own recipe already runs it alone, which is the right test.
    JWSYSD=""
    JWINPROBE=""
    JFBSNAP=""
    case "$cls" in gui|daemon) JWINPROBE="$OUT/run/$app.wins" ;; esac
    if [ -n "$JWINPROBE" ] && [ -n "$WSYSD_BIN" ] && [ "$app" != wsysd ]; then
        JWSYSD="$WSYSD_BIN"
        JFBSNAP="$OUT/run/$app.fb"
        rm -f "$JFBSNAP"
        # The program still gets its full DTMO. The compositor's readiness
        # handshake and the settle interval afterwards are the HARNESS's time,
        # and charging them to the program would shorten a GUI run by ~1.5 s --
        # the same mistake, in miniature, that DTMO=4 made.
        t=$((t + 3))
    fi

    local t0 t1 rc c0 c1
    cpu_now; c0=$CPU_NOW
    t0=$(date +%s.%N)
    jail_run "$t" "$sf" "$OUT/run/$app.out" "$OUT/run/$app.err" \
             "/bin/$app" "${av[@]}"
    rc=$?

    # A harness that answers `usage: foo A.ppm B.ppm SCRATCH` is telling us
    # exactly how to call it. Take it at its word and run it again rather than
    # recording a failure that is the recipe's, not the program's.
    local note=""
    local usagefile=""
    grep -qi '^usage:' "$OUT/run/$app.err" 2>/dev/null && usagefile="$OUT/run/$app.err"
    [ -z "$usagefile" ] && grep -qi '^usage:' "$OUT/run/$app.out" 2>/dev/null \
        && usagefile="$OUT/run/$app.out"
    if [ "$rc" != 0 ] && [ -n "$usagefile" ]; then
        local nargs
        nargs=$(grep -m1 -i '^usage:' "$usagefile" | sed 's/^[Uu]sage:[[:space:]]*//' \
                | tr -d '()' | awk '{print NF-1}')
        if [ "${nargs:-0}" -ge 1 ] && [ "${nargs:-0}" -le 12 ]; then
            local -a uav=(); local k
            for k in $(seq 1 "$nargs"); do uav+=("/work/u$k.out"); done
            unshare -r rm -rf "$up" "$wk" 2>/dev/null || rm -rf "$up" "$wk"
            mkdir -p "$up" "$wk"
            jail_run "$t" "$sf" "$OUT/run/$app.out" "$OUT/run/$app.err" \
                     "/bin/$app" "${uav[@]}"
            rc=$?
            note=" [argv from its own usage line]"
        fi
    fi
    t1=$(date +%s.%N)
    cpu_now; c1=$CPU_NOW
    local secs; secs=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", b-a}')
    # Sampled around the RUN only, before the window probe below: the probe is
    # the harness's own work and would be charged to the program.
    local cpu; cpu=$(awk -v a="$c0" -v b="$c1" 'BEGIN{printf "%.1f", b-a}')
    # A PROGRAM KILLED AT THE TIMEOUT HAS NO MEASURABLE COST HERE, and the
    # column says so rather than saying 0.0. `unshare --kill-child` SIGKILLs
    # the subtree and exits, so nothing ever wait(2)s for it and its rusage is
    # never folded into this shell's child totals -- measured: a 4 s pure CPU
    # burner under `timeout -k 2 4 unshare --fork --pid --kill-child` reports a
    # delta of exactly 0. Printing 0.0 there would be a number that reads
    # "this daemon used no cpu", which is the shape of claim this whole file
    # exists to refuse. Everything that EXITS -- every filter, cmd, hosttest
    # and bench, ~300 of the rows -- is measured for real, and that is where
    # the regression sentinel lives: `sleep 1` reads cpu 0.0 of 1.0 wall now
    # and read cpu 1.0 when it was a busy-wait.
    case "$rc" in 124|137) cpu=- ;; esac
    # ... EXCEPT for the windowed classes, where the jail sampled the program's
    # own /proc while it ran. That closes the hole the line above leaves: every
    # daemon and every scene client that is still up at the timeout is killed
    # rather than reaped, so `times` never saw it and the column printed `-` --
    # which is to say the one census on this tree that exists to catch a busy
    # spin was blind to the entire desktop. It is the PROGRAM's cpu, not the
    # harness's: the compositor is a different pid and is not in it.
    #
    # It is a sample, so it can be up to one second stale if the program died
    # between samples; on a 12-second run that is the difference between "it
    # spun" and "it spun", and on a short one the reaped `times` figure is
    # available anyway and is preferred.
    if [ "$cpu" = - ] && [ -n "$JWINPROBE" ] && [ -f "$OUT/run/$app.wins.cpu" ]; then
        cpu=$(awk -v t="$(getconf CLK_TCK)" '{printf "%.1f", $1 / t}' \
              "$OUT/run/$app.wins.cpu" 2>/dev/null)
        [ -z "$cpu" ] && cpu=-
    fi

    # What it changed. The overlay upper layer IS the diff. /srv and /run hold
    # the synthetic devices' own backing files, which every client touches and
    # which say nothing about whether the program did its job.
    local -a changed=()
    mapfile -t changed < <(cd "$up" && find . -mindepth 1 \
        \( -path './srv*' -o -path './run*' -o -path './work/wk*' \) -prune -o \
        -print 2>/dev/null | sed 's|^\./||')
    local nch=${#changed[@]}
    local nempty=0 f
    for f in "${changed[@]}"; do
        [ -f "$up/$f" ] && [ ! -s "$up/$f" ] && nempty=$((nempty+1))
    done
    local chlist; chlist="$(printf '%s\n' "${changed[@]}" | head -40)"
    printf '%s\n' "$chlist" > "$OUT/run/$app.diff"

    local ob eb
    ob=$(stat -c%s "$OUT/run/$app.out"); eb=$(stat -c%s "$OUT/run/$app.err")

    # THE CAPTURE IS BOUNDED; THE NUMBER IN THE ROW IS NOT.
    #
    # `ulimit -f` is what stops a runaway writer, and on a windowed row it is
    # now 6 GiB because the window system's SPARSE segments need that much
    # OFFSET (see jail_run). `yes` is class `daemon`, so it gets that cap and
    # writes 6 GiB of real bytes to its capture in twelve seconds -- measured,
    # 6,442,450,944 in run/yes.out. That is somebody's disk, and a results
    # directory that cannot be kept is a measurement nobody re-reads.
    #
    # So an oversized capture is TRUNCATED and SAYS SO, after `ob`/`eb` have
    # already recorded the real size. The row still reports the true byte
    # count, which is the fact the verdict is computed from; what is thrown
    # away is the middle of a stream whose whole content is one repeated line.
    local keep f fsz
    for f in "$OUT/run/$app.out" "$OUT/run/$app.err"; do
        fsz=$(stat -c%s "$f" 2>/dev/null || echo 0)
        if [ "$fsz" -gt $((256 * 1024 * 1024)) ]; then
            keep=$((1024 * 1024))
            truncate -s "$keep" "$f"
            printf '\n[runsweep] TRUNCATED: this capture was %s bytes; the first %s are kept and the `out`/`err` column above reports the real size.\n' \
                "$fsz" "$keep" >> "$f"
        fi
    done

    # Did a scene client actually MAP A WINDOW? Re-enter the same overlay --
    # the window table is a file in it -- and read the /dev/wsys DIRECTORY,
    # whose numeric entries are the live wids. "Still running at the timeout"
    # is not evidence of anything on its own; a window in the table is. This is
    # the one check that separates a scene client that came up from one that is
    # merely alive.
    #
    # The directory, NOT /dev/wsys/windows: `windows` deliberately lists only
    # visible+decorated windows, because it is what the taskbar parses and a
    # taskbar must not list the taskbar. Probing with it scored every panel,
    # OSD and overlay client -- the whole undecorated half of the DE -- as
    # having drawn nothing.
    local wins=-
    if [ -n "$JWINPROBE" ]; then
        # grep -c exits 1 when the count is zero, so `|| echo 0` would append a
        # SECOND line and split the TSV row.
        wins=$(grep -c '^[0-9][0-9]*$' "$OUT/run/$app.wins" 2>/dev/null)
        [ -z "$wins" ] && wins=0
        # A WINDOW THAT OUTLIVED ITS OWNER. The jail looks once more after the
        # program has exited; anything still in the table there is a window
        # user/linux-wsys.c's win_reap_dead() should have freed, and a leaked
        # window is an opaque rectangle no click can reach (the comment on that
        # function is the bug report). It is a finding, so it is said out loud
        # in the row rather than folded into the count.
        local after=0
        [ -f "$OUT/run/$app.wins.after" ] && after=$(cat "$OUT/run/$app.wins.after")
        if [ "${after:-0}" -gt 0 ] && [ "$rc" != 124 ] && [ "$rc" != 137 ]; then
            note="$note [${after} window(s) still in the table after it exited]"
        fi
    fi

    # DID IT PUT PIXELS ON THE SCREEN? A window in the table is a client that
    # ASKED for one; the framebuffer is what a person would have seen. The two
    # come apart, and when they do it is always in the same direction and
    # always silently -- a mapped window whose backbuffer was never written
    # scores "drew" on the table and shows nothing.
    #
    # The oracle is the compositor's own bare screen, composed ONCE at the top
    # of this run with no client at all, so what this counts is the pixels THIS
    # PROGRAM is responsible for and not the compositor's wallpaper or its
    # pointer. Sampled every other pixel in both axes, like
    # tests/linux/wsys_desktop_z.sh, which is a quarter of the work for the
    # same answer at this resolution.
    local fbpx=- frame=""
    if [ -n "$JWSYSD" ] && [ -n "$FBREF" ]; then
        # The frame the jail kept while the program still owned a window, and
        # only failing that the overlay's final frame -- see the note on
        # probe_once() in tests/linux/runsweep_jail.sh for why those differ.
        if   [ -s "$JFBSNAP" ];         then frame="$JFBSNAP"
        elif [ -f "$up/run/fb.raw" ];   then frame="$up/run/fb.raw"; fi
        if [ -n "$frame" ]; then
            fbpx=$(python3 "$FBCMP" "$FBREF" "$frame" "$FBW" "$FBH" 2>/dev/null)
            [ -z "$fbpx" ] && fbpx=-
        fi
    fi

    # --- the verdict -------------------------------------------------------
    local verdict detail=""
    detail="$(head -c 400 "$OUT/run/$app.err" | tr '\t\n' '  ' | cut -c1-160)"
    [ -z "$detail" ] && detail="$(head -c 200 "$OUT/run/$app.out" | tr '\t\n' '  ' | cut -c1-160)"

    if [ "$rc" = 125 ]; then
        verdict=HARNESS_FAIL
    elif [ "$rc" = 124 ] || [ "$rc" = 137 ]; then
        # A daemon or a scene client is SUPPOSED to still be here.
        case "$cls" in
            daemon|gui) verdict=STAYS_UP ;;
            *)          verdict=TIMEOUT ;;
        esac
    elif [ "$rc" = 153 ]; then
        # SIGXFSZ: it hit the harness's 64 MB output cap. `yes` does this
        # because `yes` is supposed to.
        verdict=STAYS_UP; detail="wrote past the 256MB output cap — $detail"
        # 256 MiB, and it is worth being exact: bash's `ulimit -f` counts
        # 1024-byte blocks (measured -- `ulimit -f 1` truncates at 1024), so
        # the 262144 above is 256 MiB. This line has been wrong twice (it said
        # 64 MB when the cap was 4 MiB); a wrong number in a comment about a
        # cap is one the next reader believes.
    elif [ "$rc" -gt 128 ] && [ "$rc" -lt 160 ]; then
        verdict=CRASH; detail="signal $((rc-128)) — $detail"
    elif [ "$rc" != 0 ] && [ -n "${XFAIL[$app]:-}" ]; then
        verdict=EXPECTED_FAIL
        # The reason travels WITH the row. A verdict that says "we expected
        # this" without saying why is an assertion, and the next reader has to
        # take it on trust or re-derive it.
        detail="expected: ${XFAIL[$app]} — $detail"
    elif [ "$rc" != 0 ]; then
        verdict=EXIT_NONZERO
    elif [ "$fbpx" != - ] && [ "$fbpx" -gt 0 ]; then
        # PIXELS ON THE FRAMEBUFFER. Strictly stronger than DREW_WINDOW, and it
        # is asked first so that a client which did both is never filed under
        # the weaker of the two.
        verdict=PAINTED
    elif [ "$cls" = gui ] && [ "$wins" != - ] && [ "$wins" -gt 0 ]; then
        # BEFORE the two "did nothing" buckets, not after, which is where this
        # test used to sit. A scene client that maps a window, paints it and
        # exits 0 without printing anything or touching a file outside /srv
        # matched SILENT_OK first and was reported as having done nothing --
        # while its window was sitting in the table the probe had just read.
        # The window IS the effect for a gui client, so it is the first thing
        # asked about.
        verdict=DREW_WINDOW
    elif [ "$ob" = 0 ] && [ "$eb" = 0 ] && [ "$nch" = 0 ] \
         && ! grep -qx "$app" <<< "$EXPECT_SILENT"; then
        # Exit 0, said nothing, changed nothing. On this port that is the
        # characteristic failure, not a pass -- so it gets its own bucket and
        # is never counted as one.
        verdict=SILENT_OK
    elif [ "$nch" -gt 0 ] && [ "$nempty" = "$nch" ] && [ "$ob" = 0 ]; then
        verdict=EMPTY_EFFECT
    else
        verdict=RAN
    fi
    case "$verdict" in
        STAYS_UP)
            if [ "$fbpx" != - ] && [ "$fbpx" -gt 0 ]; then verdict=PAINTED
            elif [ "$wins" != - ] && [ "$wins" -gt 0 ]; then verdict=DREW_WINDOW
            elif [ "$cls" = gui ]; then verdict=UP_NO_WINDOW; fi ;;
    esac
    detail="$detail$note"

    printf '%s\t%s\t0\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$app" "$cls" "$verdict" "$rc" "$secs" "$cpu" "$ob" "$eb" "$nch" \
        "$nempty" "$wins" "$fbpx" "$detail" "$claim" >> "$OUT/results.tsv"
}

# ---------------------------------------------------------------------------
# 3a. the bare screen — the oracle for "did this program put pixels up"
# ---------------------------------------------------------------------------
# The compositor composes a screen of its own before any client exists: a
# background and a pointer. Asking "is the framebuffer non-blank" would
# therefore answer YES for every GUI row including the ones that drew nothing,
# which is a success-shaped answer to the wrong question. So the reference is
# the compositor's OWN screen with no client on it, composed here once, and
# what each row reports is the pixels that program is responsible for.
#
# It is composed TWICE and the two are compared. A reference that is not
# reproducible is not a reference, and a blinking cursor or a clock in the
# compositor's own chrome would make every row report pixels it did not paint.
# If the two disagree the sweep says so and switches the column off rather
# than publishing a number it cannot stand behind.
FBREF=""
if [ -n "$WSYSD_BIN" ] && [ -x "$BASE/bin/wsysd" ] && [ -x "$BASE/bin/sleep" ]; then
    echo "[runsweep] composing the bare screen (the framebuffer oracle)"
    fbref_t0=$(date +%s.%N)
    for r in 1 2; do
        app="fbref$r"; up="$OUT/ov/$app.up"; wk="$OUT/ov/$app.wk"; mnt="$OUT/ov/$app.mnt"
        unshare -r rm -rf "$up" "$wk" "$mnt" 2>/dev/null || rm -rf "$up" "$wk" "$mnt"
        mkdir -p "$up" "$wk" "$mnt"
        JWSYSD="$WSYSD_BIN"
        jail_run 20 /dev/null "$OUT/run/$app.out" "$OUT/run/$app.err" \
                 /bin/sleep 2
        cp "$up/run/fb.raw" "$OUT/fb.ref$r" 2>/dev/null
    done
    JWSYSD=""
    fbref_t1=$(date +%s.%N)
    FBREF_SECS=$(awk -v a="$fbref_t0" -v b="$fbref_t1" 'BEGIN{printf "%.1f", (b-a)/2}')
    if [ -s "$OUT/fb.ref1" ] && cmp -s "$OUT/fb.ref1" "$OUT/fb.ref2"; then
        FBREF="$OUT/fb.ref1"
        echo "[runsweep] bare screen reproducible, ${FBREF_SECS}s per composited run"
    else
        echo "[runsweep] WARNING: the bare compositor screen is NOT reproducible;" \
             "the fbpx column is off for this run" >&2
        [ -s "$OUT/run/fbref1.err" ] && sed 's/^/[runsweep]   /' "$OUT/run/fbref1.err" >&2
        [ -s "$OUT/run/fbref1.wsysd.log" ] && \
            sed 's/^/[runsweep]   wsysd: /' "$OUT/run/fbref1.wsysd.log" >&2
    fi
fi

echo "[runsweep] running ${#APPS[@]} applications"
RUN_T0=$(date +%s.%N)
i=0
for app in "${APPS[@]}"; do
    i=$((i+1))
    printf '\r[runsweep] %3d/%d %-24s' "$i" "${#APPS[@]}" "$app" >&2
    run_one "$app"
done
echo >&2
RUN_T1=$(date +%s.%N)
RUN_SECS=$(awk -v a="$RUN_T0" -v b="$RUN_T1" 'BEGIN{printf "%.0f", b-a}')
unshare -r rm -rf "$OUT/ov" 2>/dev/null || rm -rf "$OUT/ov"

# ---------------------------------------------------------------------------
# 4. summary
# ---------------------------------------------------------------------------
{
    echo "=== hamlinux_runsweep $(date -Is) ==="
    echo
    # THE HEADLINE, COMPUTED HERE. It used to be derived by hand from the
    # verdict table and quoted into HANDOFF.md, and a figure that lives only
    # in a commit message is a figure nobody can check: one pass reported
    # "249/323" against a baseline results.tsv it had already deleted, and the
    # 323 was simply wrong (it is 324). Printing the definition next to the
    # number means the next reader re-derives nothing.
    #
    #   healthy  = RAN + PAINTED + DREW_WINDOW + STAYS_UP + EXPECTED_FAIL
    #
    # PAINTED is DREW_WINDOW's stronger sibling and joins it in the numerator
    # rather than replacing it: both are a GUI client that came up and did its
    # job, and the difference between them -- a window in the table versus
    # pixels on the framebuffer -- is what the fbpx column is for.
    #   runnable = every row MINUS the ones we declined to run
    #              (NOT_SMOKE_TESTABLE) and the ones we could not build
    #              (BUILD_FAIL)
    awk -F'\t' 'NR>1{
        n++; c[$4]++
    } END {
        healthy = c["RAN"] + c["PAINTED"] + c["DREW_WINDOW"] + c["STAYS_UP"] + c["EXPECTED_FAIL"]
        runnable = n - c["NOT_SMOKE_TESTABLE"] - c["BUILD_FAIL"]
        printf "-- headline --\n"
        printf "healthy   %4d   (RAN + PAINTED + DREW_WINDOW + STAYS_UP + EXPECTED_FAIL)\n", healthy
        printf "runnable  %4d   (%d rows - %d NOT_SMOKE_TESTABLE - %d BUILD_FAIL)\n", \
               runnable, n, c["NOT_SMOKE_TESTABLE"], c["BUILD_FAIL"]
        printf "SCORE     %d / %d\n", healthy, runnable
    }' "$OUT/results.tsv"
    echo
    echo "-- by verdict --"
    awk -F'\t' 'NR>1{c[$4]++} END{for(v in c) printf "%-20s %4d\n", v, c[v]}' \
        "$OUT/results.tsv" | sort -k2 -nr
    echo
    echo "-- by class --"
    awk -F'\t' 'NR>1{c[$2]++} END{for(v in c) printf "%-20s %4d\n", v, c[v]}' \
        "$OUT/results.tsv" | sort -k2 -nr
    echo
    # WHAT THE COMPOSITOR BOUGHT, AND WHAT IT COST. Both, next to each other,
    # because "the sweep grew a column" is not a finding until the wall clock
    # is beside it.
    echo "-- the windowed half, now that there is a compositor --"
    awk -F'\t' -v ref="$FBREF" 'NR>1 && ($2=="gui" || $2=="daemon"){
            g++
            if      ($4=="PAINTED")      p++
            else if ($4=="DREW_WINDOW")  d++
            else if ($4=="UP_NO_WINDOW") u++
            else                         o++
        } END {
            if (ref == "") { print "  (no compositor in this run -- fbpx is off)"; exit }
            printf "  %4d gui + daemon rows\n", g
            printf "  %4d PAINTED       pixels of their own on the framebuffer\n", p+0
            printf "  %4d DREW_WINDOW   a window in the table, and NOTHING on the screen\n", d+0
            printf "  %4d UP_NO_WINDOW  alive at the timeout, no window at all\n", u+0
            printf "  %4d other         (see the verdict table above)\n", o+0
        }' "$OUT/results.tsv"
    echo "  run phase ${RUN_SECS}s wall for ${#APPS[@]} applications"
    echo
    echo "-- a window in the table with no pixels behind it --"
    awk -F'\t' 'NR>1 && ($2=="gui" || $2=="daemon") && $4=="DREW_WINDOW" {
                    printf "  %-24s wins %s, fbpx %s\n", $1, $12, $13 }' \
        "$OUT/results.tsv"
    echo
    echo "-- the ones that succeed while doing nothing --"
    awk -F'\t' 'NR>1 && ($4=="SILENT_OK"||$4=="EMPTY_EFFECT"){printf "%-24s %s\n", $1, $4}' \
        "$OUT/results.tsv"
    echo
    # THE IDLE CENSUS, as a standing column. A program that PARKS and a program
    # that SPINS are identical in every other field here -- same status, same
    # output, same wall clock -- which is how the desktop came to sit at 203.6%
    # of one cpu with every gate on this tree passing. >= 80% of its own wall
    # clock in cpu, for at least a second, is a program that did not sleep.
    # Now that a windowed program's cpu is measured at all (see the /proc
    # sample in the jail), this list finally covers the half of the tree the
    # IDLE CENSUS was about.
    echo "-- burned a core while it waited (cpu / wall >= 0.8) --"
    awk -F'\t' 'NR>1 && $7 != "-" && $7+0 >= 1 && $6+0 > 0 && ($7+0)/($6+0) >= 0.8 {
                    printf "%-24s %-14s cpu %6.1fs of %6.1fs wall\n", $1, $4, $7, $6 }' \
        "$OUT/results.tsv" | sort -k4 -nr
} > "$OUT/summary.txt"
cat "$OUT/summary.txt"
echo "[runsweep] results: $OUT/results.tsv"
