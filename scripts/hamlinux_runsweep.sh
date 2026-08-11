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
#   RUNSWEEP_DTIMEOUT  seconds a daemon/GUI client is given to stay up (default 4)
#   RUNSWEEP_NOBUILD=1 reuse <outdir>/obj from a previous run
#
# Output:
#   <outdir>/results.tsv   one row per application, columns documented below
#   <outdir>/run/<app>.out <app>.err   captured streams
#   <outdir>/run/<app>.diff            the files it created or changed
#   <outdir>/obj/<app>.elf             the binary
#   <outdir>/summary.txt               counts by verdict and by class
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

OUT="${1:?usage: hamlinux_runsweep.sh <outdir> [app ...]}"; shift
OUT="$(mkdir -p "$OUT" && cd "$OUT" && pwd)"
. "$(dirname "$0")/hamlinux_jobs.sh"
JOBS="${RUNSWEEP_JOBS:-$HAMLINUX_JOBS}"
TMO="${RUNSWEEP_TIMEOUT:-5}"
DTMO="${RUNSWEEP_DTIMEOUT:-4}"
RECIPES="$PROJ_ROOT/tests/linux/runsweep_recipes.tsv"
JAIL="$PROJ_ROOT/tests/linux/runsweep_jail.sh"

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
# /bin/install is the same program as hlinstall (haminstallui spawns that name).
[ -f "$BASE/bin/hlinstall" ] && install -m755 "$BASE/bin/hlinstall" "$BASE/bin/install"
[ -f build/cutover/host_ac.elf ] && install -m755 build/cutover/host_ac.elf "$BASE/bin/host_ac"
install -m644 user/linux-runtime.S user/linux-*.c user/linux-*.h \
    user/syscall_nums.h scripts/adder_llvm_runtime.c "$BASE/usr/share/adder/" 2>/dev/null
install -m644 scripts/ac-link.sh "$BASE/usr/share/adder/ac-link.sh" 2>/dev/null
install -m644 tests/linux/hello.ad "$BASE/usr/share/adder/hello.ad" 2>/dev/null

# glibc and the loader: this lane links dynamically (HANDOFF §7.4).
probe="$(ls -1 "$BASE"/bin/* 2>/dev/null | head -1)"
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
        CLASS[$n]="$c"; ARGV[$n]="$a"; STDIN[$n]="$s"; CLAIM[$n]="$cl"
    done < "$RECIPES"
fi

: > "$OUT/results.tsv"
printf '#app\tclass\tbuild\tverdict\trc\tsecs\tout\terr\tchanged\tempty\twins\tdetail\tclaim\n' \
    >> "$OUT/results.tsv"

# The programs whose CONTRACT is to say nothing and change nothing. Without
# this list `true` is indistinguishable from a program that did not run.
EXPECT_SILENT="true
sync"

run_one() {
    local app="$1"
    local cls="${CLASS[$app]:-cmd}"
    local argv="${ARGV[$app]:-}"
    local sin="${STDIN[$app]:--}"
    local claim="${CLAIM[$app]:-}"

    if [ "${BRC[$app]:-1}" != 0 ]; then
        printf '%s\t%s\t%s\tBUILD_FAIL\t-\t-\t-\t-\t-\t-\t-\t%s\t%s\n' \
            "$app" "$cls" "${BRC[$app]:-?}" \
            "$(grep -m1 -iE 'error|bailed' "$OUT/run/$app.build.err" 2>/dev/null | cut -c1-120 | tr '\t\n' '  ')" \
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
        printf '%s\t%s\t0\tNOT_SMOKE_TESTABLE\t-\t-\t-\t-\t-\t-\t-\t%s\t%s\n' \
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
    local -a av=()
    [ -n "$argv" ] && read -r -a av <<< "$argv"

    local sf="$OUT/ov/$app.in"
    case "$sin" in
        -)     : > "$sf" ;;
        %F)    cp "$BASE/work/f1.txt" "$sf" ;;
        *)     printf '%s\n' "$sin" > "$sf" ;;
    esac

    local t="$TMO"
    case "$cls" in daemon|gui) t="$DTMO" ;; esac

    # One invocation of the jail. Everything the program can see is set here:
    # env -i so the developer's environment cannot leak in and make a result
    # unreproducible, and the HAM* variables pointing every synthetic device at
    # a path inside the throwaway root.
    jail_run() {   # jail_run <timeout> <stdin-file> <out> <err> <argv...>
        local jt="$1" jin="$2" jout="$3" jerr="$4"; shift 4
        # 4 MB is a safety net, not a test parameter: `yes` writes for ever by
        # design and would otherwise fill the disk in the seconds it is given.
        ( ulimit -f 4096
          env -i \
            PATH=/bin:/usr/bin HOME=/root USER=root LOGNAME=root TERM=dumb \
            SHELL=/bin/hamsh PWD=/work TMPDIR=/tmp LANG=C \
            HAMWSYS=/srv/wsys HAMWSYS_BB=/srv/wsys.bb \
            HAMFDNS=/srv/fdns HAMFDNS_DIR=/srv HAMNET=/srv/net \
            HAMFB_FILE=/run/fb.raw HAMFB_GEOM=1280x800 \
            timeout -k 2 "$jt" \
            unshare -rmn --fork --pid --kill-child \
                "$JAIL" "$BASE" "$up" "$wk" "$mnt" "$@" \
            < "$jin" > "$jout" 2> "$jerr" ) 2>/dev/null
    }

    local t0 t1 rc
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
    local secs; secs=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", b-a}')

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
    if [ "$cls" = gui ] || [ "$cls" = daemon ]; then
        jail_run 5 /dev/null "$OUT/run/$app.wins" /dev/null \
                 /bin/cat /dev/wsys
        # grep -c exits 1 when the count is zero, so `|| echo 0` would append a
        # SECOND line and split the TSV row.
        wins=$(grep -c '^[0-9][0-9]*$' "$OUT/run/$app.wins" 2>/dev/null)
        [ -z "$wins" ] && wins=0
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
        verdict=STAYS_UP; detail="wrote past the 4MB output cap — $detail"
    elif [ "$rc" -gt 128 ] && [ "$rc" -lt 160 ]; then
        verdict=CRASH; detail="signal $((rc-128)) — $detail"
    elif [ "$rc" != 0 ]; then
        verdict=EXIT_NONZERO
    elif [ "$ob" = 0 ] && [ "$eb" = 0 ] && [ "$nch" = 0 ] \
         && ! grep -qx "$app" <<< "$EXPECT_SILENT"; then
        # Exit 0, said nothing, changed nothing. On this port that is the
        # characteristic failure, not a pass -- so it gets its own bucket and
        # is never counted as one.
        verdict=SILENT_OK
    elif [ "$nch" -gt 0 ] && [ "$nempty" = "$nch" ] && [ "$ob" = 0 ]; then
        verdict=EMPTY_EFFECT
    elif [ "$cls" = gui ] && [ "$wins" != - ] && [ "$wins" -gt 0 ]; then
        verdict=DREW_WINDOW
    else
        verdict=RAN
    fi
    case "$verdict" in
        STAYS_UP)
            if [ "$wins" != - ] && [ "$wins" -gt 0 ]; then verdict=DREW_WINDOW
            elif [ "$cls" = gui ]; then verdict=UP_NO_WINDOW; fi ;;
    esac
    detail="$detail$note"

    printf '%s\t%s\t0\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$app" "$cls" "$verdict" "$rc" "$secs" "$ob" "$eb" "$nch" "$nempty" \
        "$wins" "$detail" "$claim" >> "$OUT/results.tsv"
}

echo "[runsweep] running ${#APPS[@]} applications"
i=0
for app in "${APPS[@]}"; do
    i=$((i+1))
    printf '\r[runsweep] %3d/%d %-24s' "$i" "${#APPS[@]}" "$app" >&2
    run_one "$app"
done
echo >&2
unshare -r rm -rf "$OUT/ov" 2>/dev/null || rm -rf "$OUT/ov"

# ---------------------------------------------------------------------------
# 4. summary
# ---------------------------------------------------------------------------
{
    echo "=== hamlinux_runsweep $(date -Is) ==="
    echo
    echo "-- by verdict --"
    awk -F'\t' 'NR>1{c[$4]++} END{for(v in c) printf "%-20s %4d\n", v, c[v]}' \
        "$OUT/results.tsv" | sort -k2 -nr
    echo
    echo "-- by class --"
    awk -F'\t' 'NR>1{c[$2]++} END{for(v in c) printf "%-20s %4d\n", v, c[v]}' \
        "$OUT/results.tsv" | sort -k2 -nr
    echo
    echo "-- the ones that succeed while doing nothing --"
    awk -F'\t' 'NR>1 && ($4=="SILENT_OK"||$4=="EMPTY_EFFECT"){printf "%-24s %s\n", $1, $4}' \
        "$OUT/results.tsv"
} > "$OUT/summary.txt"
cat "$OUT/summary.txt"
echo "[runsweep] results: $OUT/results.tsv"
