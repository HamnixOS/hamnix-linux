#!/usr/bin/env bash
# scripts/hamlinux_sweep.sh — build every user/*.ad through the Linux lane and
# record, per application, which of the three failure modes it hit.
#
# Writes a TSV to $OUT/results.tsv:  <app>\t<rc>\t<first-diagnostic>
# and the per-app logs to $OUT/<app>.err. rc 0 = built.
# rc 10 = emit failed, 11 = @main bailed the SSA subset, 12 = link failed,
# rc 13 = the source has no `def main` — a LIBRARY MODULE, not an application.
#
# THE HEADLINE IS COMPUTED HERE, WITH ITS DEFINITION PRINTED NEXT TO IT, and
# for the same reason scripts/hamlinux_runsweep.sh does it: a figure that lives
# only in a commit message is a figure nobody can check, and this tree has been
# bitten by a wrong denominator twice now. This was the second time, and the
# denominator was wrong because it counted the wrong KIND of thing:
# `user/` holds APPLICATIONS and it also holds four LIBRARY MODULES that other
# programs import (http9, net9, httpdconf, hambrowse_tabs). A library has no
# `main`, cannot become an ELF, and is not a failure to build one — so it does
# not belong in the denominator of "applications that build". It was in it, and
# it made the headline read "359 of 367" when four of the eight shortfalls were
# library modules doing exactly what a library module does.
#
# So: built / applications, where applications = rows - rc13.
#
# Usage: scripts/hamlinux_sweep.sh <outdir> [app ...]
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

OUT="${1:?usage: hamlinux_sweep.sh <outdir> [app ...]}"; shift
mkdir -p "$OUT"
: > "$OUT/results.tsv"

if [ $# -gt 0 ]; then
    SRCS=("$@")
else
    mapfile -t SRCS < <(ls user/*.ad)
fi

for src in "${SRCS[@]}"; do
    app="$(basename "$src" .ad)"
    scripts/hamlinux_build.sh "$src" "$OUT/$app.elf" >/dev/null 2>"$OUT/$app.err"
    rc=$?
    # First useful diagnostic: the first undefined symbol for a link failure,
    # otherwise the first error line.
    if [ "$rc" = 12 ]; then
        diag="$(grep -oE "undefined reference to \`[a-zA-Z0-9_]+'" "$OUT/$app.err" \
                | sed "s/.*\`//; s/'//" | sort -u | paste -sd, -)"
    else
        # NOT the `; ADDER_STAT ... bailed=0` line, which contains the word
        # "bailed" and is printed for every program including the ones that
        # built. It matched first and became the "diagnostic" for all four
        # library modules, so the failure column read `bailed=0` -- which is a
        # statement that nothing went wrong.
        diag="$(grep -vE '^; ADDER_STAT' "$OUT/$app.err" \
                | grep -m1 -iE 'error|bailed|NOT-AN-APPLICATION' | cut -c1-200)"
    fi
    printf '%s\t%s\t%s\n' "$app" "$rc" "$diag" >> "$OUT/results.tsv"
    # Keep the tree small: the .ll files are large and reproducible.
    rm -f "$OUT/$app.ll" "$OUT/$app.ll.emit.log" "$OUT/$app.ll.link.log"
done

echo "=== sweep complete: $(wc -l < "$OUT/results.tsv") files in user/ ==="
awk -F'\t' '{c[$2]++} END {for (r in c) printf "rc=%s\t%d\n", r, c[r]}' \
    "$OUT/results.tsv" | sort
echo
awk -F'\t' '{
    n++; c[$2]++
} END {
    apps = n - c["13"]
    printf "%s\n", "-- headline --"
    printf "files in user/          %4d\n", n
    printf "library modules         %4d   (rc 13: no def main; not applications)\n", c["13"]
    printf "applications            %4d   (%d files - %d libraries)\n", apps, n, c["13"]
    printf "built                   %4d   (rc 0)\n", c["0"]
    printf "BUILD SCORE   %d / %d applications\n", c["0"], apps
}' "$OUT/results.tsv"
echo
echo "-- everything that is not rc 0 --"
awk -F'\t' '$2!=0 {printf "%-28s rc=%-3s %s\n", $1, $2, $3}' "$OUT/results.tsv"
