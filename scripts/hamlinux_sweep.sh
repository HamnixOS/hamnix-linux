#!/usr/bin/env bash
# scripts/hamlinux_sweep.sh — build every user/*.ad through the Linux lane and
# record, per application, which of the three failure modes it hit.
#
# Writes a TSV to $OUT/results.tsv:  <app>\t<rc>\t<first-diagnostic>
# and the per-app logs to $OUT/<app>.err. rc 0 = built.
# rc 10 = emit failed, 11 = @main bailed the SSA subset, 12 = link failed.
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
        diag="$(grep -m1 -iE 'error|bailed' "$OUT/$app.err" | cut -c1-200)"
    fi
    printf '%s\t%s\t%s\n' "$app" "$rc" "$diag" >> "$OUT/results.tsv"
    # Keep the tree small: the .ll files are large and reproducible.
    rm -f "$OUT/$app.ll" "$OUT/$app.ll.emit.log" "$OUT/$app.ll.link.log"
done

echo "=== sweep complete: $(wc -l < "$OUT/results.tsv") apps ==="
awk -F'\t' '{c[$2]++} END {for (r in c) printf "rc=%s\t%d\n", r, c[r]}' \
    "$OUT/results.tsv" | sort
