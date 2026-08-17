#!/usr/bin/env bash
# tests/linux/pkg_tar_reproducible.sh — "THE BYTES I BUILT ARE THE BYTES
# SERVED" WAS NOT CHECKABLE AT THE TARBALL LEVEL, AND ONE FLAG IS WHY.
#
# WHAT WAS WRONG
# ==============
# Both packagers normalise every tar member (uid, gid, uname, gname, mtime),
# and scripts/hamlinux_packages.py says so in a comment:
#
#     "Deterministic: same inputs -> same bytes -> same sha256, so a rebuilt
#      channel does not churn every package's hash for nothing."
#
# The first half of that is true and the second half was false. MEASURED
# before the fix: the local and the published `hpm-1.0.26.tar.gz` inflate to
# BYTE-IDENTICAL tar streams and their .tar.gz files differ. The difference is
# four bytes of gzip header. `tarfile.open(path, "w:gz")` constructs its own
# gzip.GzipFile with the DEFAULT mtime -- time.time() -- and writes it into
# the gzip header's MTIME field at offset 4. Python also sets the FNAME flag
# and appends the output file's basename when it opens the file itself.
#
# So every package's sha256 changed on every rebuild for no reason but the
# clock, and the only way to ask "did 255.one serve what this tree built" was
# to inflate both sides and compare members. tests/linux/channel_bytes_match_
# image.sh says as much in its own "WHAT IT DOES NOT ANSWER" section.
#
# The fix (scripts/hamlinux_packages.py, scripts/build_packages.py) drives the
# GzipFile explicitly with mtime=0 and filename="".
#
# WHAT THIS GATE MEASURES, IN THREE SECTIONS
# ==========================================
# A. FUNCTIONAL, no network, no build: builds one synthetic package twice
#    through scripts/build_packages.py's real `_tar_gz`, with the wall clock
#    stepped between the two builds, and requires the two .tar.gz files to be
#    byte-identical. This is the property, exercised through shipping code.
#
# B. THE REAL CHANNEL'S OUTPUT: every .tar.gz under the built channel must
#    carry MTIME == 0 and a clear FNAME flag in its gzip header. This is what
#    scripts/hamlinux_packages.py actually wrote, read back off disk. Skipped
#    with a loud NOT CHECKED (and no PASS) if no channel is built -- a gap
#    does not get to answer success-shaped.
#
# C. LOCAL vs PUBLISHED: for every package in the built channel that
#    https://255.one/linux/index.json serves AT THE SAME VERSION, the local
#    .tar.gz's sha256 must equal the sha256 the published index records. This
#    is the check the fix makes possible and it is the point of the exercise.
#    If the tree's version is not the published one there is no comparable
#    package; that is reported as NOT CHECKED with the two versions named, and
#    scores nothing. If 255.one cannot be reached the gate FAILS: an
#    instrument that could not run is red, not silent.
#
# NEGATIVE CONTROL, RUN RATHER THAN DESCRIBED
# ===========================================
#   HAMLINUX_PKGREPRO_CONTROL=1
# builds the SAME synthetic package twice the OLD way -- literally
# `tarfile.open(path, "w:gz")` -- with the same clock step, and requires
# section A's comparison to find them DIFFERENT and section B's header reader
# to find MTIME != 0 in that file. If the old formulation came out identical,
# or the header reader read zero out of it, the instrument cannot tell the two
# states apart and the control goes red. A control run is EXPECTED TO PASS:
# it asserts the bug is visible, not that the bug is present.
#
# WHAT THIS GATE DOES NOT ANSWER
# ==============================
#  * Nothing about the CONTENT of a package. Section C compares one sha256 per
#    package; a package that differs is reported as differing and this gate
#    does not say why. channel_bytes_match_image.sh is the per-file question.
#  * Nothing about the index.json wrapper, its signature, or the server.
#  * Nothing about scripts/hamlinux_packages.py's writer being reproducible
#    END TO END. Section B reads its gzip header, which is the byte the fix
#    changes; it does not build the channel twice. That would cost two full
#    channel builds and is named here as uncovered rather than implied.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

pass=0; fail=0
ok()   { echo "pkgrepro: PASS $*"; pass=$((pass+1)); }
bad()  { echo "pkgrepro: FAIL $*"; fail=$((fail+1)); }
info() { echo "pkgrepro: INFO $*"; }
say()  { echo "pkgrepro: --- $*"; }

CONTROL="${HAMLINUX_PKGREPRO_CONTROL:-0}"
CHAN="${HAMLINUX_HPM_CHANNEL:-build/repo/linux}"
PUB_INDEX="${HAMLINUX_PKGREPRO_INDEX:-https://255.one/linux/index.json}"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/pkgrepro.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

if [ "$CONTROL" = 1 ]; then
    say "NEGATIVE CONTROL: HAMLINUX_PKGREPRO_CONTROL=1 -- section A builds the"
    say "NEGATIVE CONTROL: synthetic package the PRE-FIX way and requires this"
    say "NEGATIVE CONTROL: gate's instruments to SEE the nondeterminism."
fi

# =========================================================================
# A. Two builds of identical inputs, a wall clock apart.
# =========================================================================
# The gzip MTIME field has one-second granularity, so two builds inside the
# same second would collide and the old code would look deterministic. The
# builds are therefore separated by a real second -- measured, not assumed:
# the reader in section B prints the stamp each file carries.
say "A. two builds of one package, through scripts/build_packages.py"

mkdir -p "$TMP/src/testpkg-9.9.9/files/bin"
printf 'name: testpkg\nversion: 9.9.9\n' > "$TMP/src/testpkg-9.9.9/PKGINFO"
head -c 4096 /dev/zero | tr '\0' 'A' > "$TMP/src/testpkg-9.9.9/files/bin/prog"
chmod 755 "$TMP/src/testpkg-9.9.9/files/bin/prog"
# A member whose path is longer than tar's 100-byte name field, so the GNU
# @LongLink entry is in this archive too and the wrapper is exercised over
# the same shape the real packages have.
LONGDIR="$TMP/src/testpkg-9.9.9/files/lib/modules/6.12.85/kernel/drivers/gpu/drm/virtio"
mkdir -p "$LONGDIR"
printf 'module\n' > "$LONGDIR/virtio-gpu-with-a-deliberately-long-name.ko"

build_one() {  # build_one <outfile> <mode:new|old>
    python3 - "$TMP/src/testpkg-9.9.9" "$1" "$2" <<'PYEOF'
import gzip, sys, tarfile, pathlib, importlib.util
root, out, mode = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
if mode == "new":
    spec = importlib.util.spec_from_file_location(
        "bp", "scripts/build_packages.py")
    bp = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(bp)
    sha, size = bp._tar_gz(root, out)
    print("%s %d" % (sha, size))
else:
    # THE PRE-FIX FORMULATION, verbatim: tarfile opens the file and builds
    # the GzipFile itself, so the header carries time.time() and FNAME.
    entries = sorted(root.rglob("*"))
    with tarfile.open(out, mode="w:gz", format=tarfile.GNU_FORMAT,
                      compresslevel=9) as tar:
        ti = tarfile.TarInfo(name=root.name)
        ti.type = tarfile.DIRTYPE; ti.mode = 0o755; ti.mtime = 0
        ti.uid = ti.gid = 0; ti.uname = ti.gname = "root"
        tar.addfile(ti)
        for p in entries:
            ti = tar.gettarinfo(name=str(p),
                                arcname="%s/%s" % (root.name,
                                                   p.relative_to(root).as_posix()))
            if ti is None:
                continue
            ti.mtime = 0; ti.uid = ti.gid = 0
            ti.uname = ti.gname = "root"
            if ti.isdir():
                ti.mode = 0o755; tar.addfile(ti)
            elif ti.isreg():
                ti.mode = 0o755 if (p.stat().st_mode & 0o111) else 0o644
                with p.open("rb") as f:
                    tar.addfile(ti, f)
            else:
                tar.addfile(ti)
    import hashlib
    d = out.read_bytes()
    print("%s %d" % (hashlib.sha256(d).hexdigest(), len(d)))
PYEOF
}

MODE=new
[ "$CONTROL" = 1 ] && MODE=old

A1="$(build_one "$TMP/a1.tar.gz" "$MODE")" || { bad "the first build did not run: $A1"; }
sleep 2
A2="$(build_one "$TMP/a2.tar.gz" "$MODE")" || { bad "the second build did not run: $A2"; }

# The instrument is verified before it is trusted: the two archives must have
# the same INFLATED bytes, or a difference in the .tar.gz says nothing about
# the wrapper.
gzip -dc "$TMP/a1.tar.gz" > "$TMP/a1.tar" 2>/dev/null
gzip -dc "$TMP/a2.tar.gz" > "$TMP/a2.tar" 2>/dev/null
if [ ! -s "$TMP/a1.tar" ] || [ ! -s "$TMP/a2.tar" ]; then
    bad "one of the two builds produced nothing readable -- this gate cannot compare wrappers it could not inflate"
elif ! cmp -s "$TMP/a1.tar" "$TMP/a2.tar"; then
    bad "the two UNCOMPRESSED tars already differ ($(stat -c%s "$TMP/a1.tar") vs $(stat -c%s "$TMP/a2.tar") bytes) -- the member normalisation is broken and section A cannot say anything about gzip"
else
    ok "the two builds' uncompressed tars are byte-identical ($(stat -c%s "$TMP/a1.tar") bytes) -- any wrapper difference below is gzip's and only gzip's"

    if cmp -s "$TMP/a1.tar.gz" "$TMP/a2.tar.gz"; then
        if [ "$CONTROL" = 1 ]; then
            bad "CONTROL: two PRE-FIX builds two seconds apart came out byte-identical -- this gate cannot see the defect it claims to close, so its green means nothing"
        else
            ok "two builds two seconds apart are byte-identical .tar.gz ($(echo "$A1" | cut -c1-16), $(echo "$A1" | cut -d' ' -f2) bytes)"
        fi
    else
        if [ "$CONTROL" = 1 ]; then
            ok "CONTROL: two PRE-FIX builds two seconds apart DIFFER ($(echo "$A1" | cut -c1-16) vs $(echo "$A2" | cut -c1-16)) -- the defect is visible to this gate"
        else
            bad "two builds of identical inputs produced DIFFERENT .tar.gz bytes ($(echo "$A1" | cut -c1-16) vs $(echo "$A2" | cut -c1-16)) -- the package wrapper is not reproducible"
        fi
    fi
fi

# =========================================================================
# B. The gzip header of every tarball the real packager wrote.
# =========================================================================
# Reads bytes 3 (FLG) and 4..8 (MTIME) off each file. RFC 1952: bit 3 of FLG
# is FNAME, and MTIME is little-endian; 0 means "no timestamp available",
# which is exactly the claim a reproducible wrapper makes.
say "B. the gzip header of every tarball in the built channel"

read_hdr() {  # read_hdr <file> -> "<mtime> <fname-flag>"
    python3 - "$1" <<'PYEOF'
import struct, sys
b = open(sys.argv[1], "rb").read(10)
if len(b) < 10 or b[0] != 0x1f or b[1] != 0x8b:
    print("NOTGZIP 0"); raise SystemExit
print("%d %d" % (struct.unpack_from("<I", b, 4)[0], 1 if (b[3] & 0x08) else 0))
PYEOF
}

# VERIFY THE INSTRUMENT FIRST. A reader that returns 0 for everything would
# pass this whole section on a broken tree. The control build (or, on a normal
# run, a throwaway made the old way) must read back NON-ZERO.
build_one "$TMP/probe.tar.gz" old >/dev/null 2>&1
PROBE="$(read_hdr "$TMP/probe.tar.gz")"
PROBE_MTIME="${PROBE% *}"
if [ "$PROBE_MTIME" = 0 ] || [ "$PROBE_MTIME" = NOTGZIP ]; then
    bad "INSTRUMENT: the header reader returned '$PROBE' for a tarball built the PRE-FIX way, which must carry a live clock stamp -- it cannot distinguish stamped from unstamped, so every result below would be meaningless"
else
    ok "INSTRUMENT: the header reader reads $PROBE_MTIME out of a deliberately-stamped tarball, so a 0 below is a measurement and not a blind spot"
fi

if [ ! -d "$CHAN" ] || [ -z "$(ls "$CHAN"/packages/*.tar.gz 2>/dev/null)" ]; then
    info "NOT CHECKED: no built channel at $CHAN/packages -- sections B and C did not run and score nothing. Build one with: python3 scripts/hamlinux_packages.py --out build/repo --version <v>"
    NCHAN=0
else
    # PROVENANCE BEFORE VERDICT. The scan below reports on tarballs that are
    # ALREADY on disk, and says nothing about when or by what they were built.
    # Run in a tree whose build/repo/linux predates the very fix this gate
    # tests, it printed "130 of 130 channel tarballs carry a nonzero gzip
    # MTIME" -- true about the bytes, and a stale artefact rather than a
    # defect. Every one of those tarballs was written by the OLD packager.
    #
    # This is the second gate in two days to name a cause it had not measured
    # (the first said an image and a channel "run different programs under one
    # version" when they were two different releases). So: if the tarballs are
    # OLDER than the packager that is supposed to produce them, refuse to draw
    # a conclusion. Red, not green -- a check that cannot attribute must not
    # answer something success-shaped, in either direction.
    PKGR="$PROJ_ROOT/scripts/hamlinux_packages.py"
    NEWEST_TAR=$(ls -t "$CHAN"/packages/*.tar.gz 2>/dev/null | head -1)
    if [ -n "$NEWEST_TAR" ] && [ -f "$PKGR" ] && [ "$PKGR" -nt "$NEWEST_TAR" ]; then
        bad "the channel at $CHAN is OLDER than scripts/hamlinux_packages.py, so its tarballs were written by a previous version of the packager and their gzip headers say nothing about the code in this tree. Rebuild the channel and re-run. NOT reporting this as a defect and NOT reporting it as clean."
        echo "        newest tarball: $(basename "$NEWEST_TAR") ($(stat -c %y "$NEWEST_TAR" | cut -d. -f1))"
        echo "        packager      : $(stat -c %y "$PKGR" | cut -d. -f1)"
        echo
        echo "pkgrepro: $pass passed, $fail failed"
        exit 1
    fi
    NCHAN=0; NSTAMPED=0; NNAMED=0
    : > "$TMP/stamped"
    for f in "$CHAN"/packages/*.tar.gz; do
        NCHAN=$((NCHAN + 1))
        h="$(read_hdr "$f")"
        m="${h% *}"; fl="${h#* }"
        if [ "$m" = NOTGZIP ]; then
            bad "$(basename "$f") is not a gzip stream at all"
            continue
        fi
        [ "$m" != 0 ] && { NSTAMPED=$((NSTAMPED + 1)); echo "$(basename "$f") mtime=$m" >> "$TMP/stamped"; }
        [ "$fl" != 0 ] && NNAMED=$((NNAMED + 1))
    done
    if [ "$NSTAMPED" = 0 ]; then
        ok "all $NCHAN channel tarballs carry gzip MTIME 0 -- the wrapper is a function of the tar and not of the clock"
    else
        bad "$NSTAMPED of $NCHAN channel tarballs carry a nonzero gzip MTIME -- their sha256 changes on every rebuild and cannot be compared with what is served"
        head -5 "$TMP/stamped" | sed 's|^|        |'
    fi
    if [ "$NNAMED" = 0 ]; then
        ok "all $NCHAN channel tarballs have the gzip FNAME flag clear -- no build path leaks into the wrapper"
    else
        bad "$NNAMED of $NCHAN channel tarballs set the gzip FNAME flag"
    fi
fi

# =========================================================================
# C. The bytes this tree built against the bytes 255.one serves.
# =========================================================================
say "C. local sha256 against the published index"

if [ "$NCHAN" = 0 ]; then
    info "NOT CHECKED: section C needs a built channel; see above."
elif ! curl -sS --max-time 30 -o "$TMP/pub.json" "$PUB_INDEX"; then
    bad "could not fetch $PUB_INDEX -- the comparison this gate exists for DID NOT RUN, and a check that could not run is red rather than silent"
elif ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))["packages"]' "$TMP/pub.json" 2>/dev/null; then
    bad "$PUB_INDEX did not parse as a package index -- the comparison DID NOT RUN"
else
    python3 - "$CHAN" "$TMP/pub.json" > "$TMP/cmp.txt" <<'PYEOF'
import hashlib, json, os, sys
chan, pub = sys.argv[1], sys.argv[2]
local = json.load(open(os.path.join(chan, "index.json")))["packages"]
published = {p["name"]: p for p in json.load(open(pub))["packages"]}
for p in sorted(local, key=lambda x: x["name"]):
    q = published.get(p["name"])
    path = os.path.join(chan, p["url"])
    if q is None:
        print("UNPUBLISHED\t%s\t%s\t-" % (p["name"], p["version"])); continue
    if q["version"] != p["version"]:
        print("VERSION\t%s\t%s\t%s" % (p["name"], p["version"], q["version"]))
        continue
    if not os.path.exists(path):
        print("MISSING\t%s\t%s\t-" % (p["name"], p["version"])); continue
    h = hashlib.sha256(open(path, "rb").read()).hexdigest()
    kind = "SAME" if h == q["sha256"] else "DIFFER"
    print("%s\t%s\t%s\t%s|%s" % (kind, p["name"], p["version"],
                                 h[:16], q["sha256"][:16]))
PYEOF
    NSAME=$(grep -c '^SAME' "$TMP/cmp.txt" || true)
    NDIFF=$(grep -c '^DIFFER' "$TMP/cmp.txt" || true)
    NVER=$(grep -c '^VERSION' "$TMP/cmp.txt" || true)
    NUNPUB=$(grep -c '^UNPUBLISHED' "$TMP/cmp.txt" || true)
    NMISS=$(grep -c '^MISSING' "$TMP/cmp.txt" || true)

    if [ "$((NSAME + NDIFF))" = 0 ]; then
        info "NOT CHECKED: no package in $CHAN is served at the same version by $PUB_INDEX ($NVER at a different version, $NUNPUB not published) -- section C compared NOTHING and scores nothing. This is the expected state while the tree builds a version that has not been released."
        head -3 "$TMP/cmp.txt" | sed 's|^|        |'
    elif [ "$NDIFF" = 0 ]; then
        ok "all $NSAME same-version packages are byte-identical to what $PUB_INDEX serves -- the bytes this tree built ARE the bytes served"
    else
        bad "$NDIFF of $((NSAME + NDIFF)) same-version packages have a different sha256 from what $PUB_INDEX serves -- the channel does not serve what this tree builds"
        grep '^DIFFER' "$TMP/cmp.txt" | head -8 \
            | awk -F'\t' '{printf "        %-28s %s  local/published %s\n", $2, $3, $4}'
    fi
    [ "$NMISS" -gt 0 ] && bad "$NMISS packages are in the local index and not on disk -- they were NOT compared and are not reported as equal"
fi

echo
echo "pkgrepro: $pass passed, $fail failed"
[ "$fail" = 0 ]
