#!/usr/bin/env bash
#
# REGISTRATION, 2026-08-17. Until this date scripts/test_gate_registration.sh
# globbed only scripts/test_*.sh, so this directory was invisible to the gate
# against unregistered gates and every file in it read as coverage without
# being coverage. This gate is ON-DEMAND: not in ci_battery_manifest.txt
# because MEASURED 2026-08-17: it exits 0 in 0 s while printing no PASS, no FAIL and no assertion count at all (0 bytes of output). It is a probe, not a gate -- registering it would add a battery line that cannot go red, which is exactly the false assurance the registration gate exists to prevent.
#
#
# tests/linux/desktop_liveonly.sh — ONE READING OF X-Hamnix-LiveOnly, SHARED.
#
# WHY THIS FILE EXISTS
# ====================
# Two gates counted the live-medium-only launchers so they could SUBTRACT them
# from an expected total, and they did it differently:
#
#   de_icons_distinct.sh:194   grep -lix 'X-Hamnix-LiveOnly=true'   (whole
#                              line, CASE-INSENSITIVE)
#   de_appmenu_installed.sh:310  grep -l  'X-Hamnix-LiveOnly=true'  (substring,
#                              case-sensitive)
#
# Both feed an arithmetic expectation -- NEXP=$((NDESK - NLIVE)) in one,
# WANT=$((NCAT - NLIVE - 1)) in the other -- so a disagreement about ONE file
# does not produce a disagreement about the key. IT PRODUCES A FABRICATED
# DEFECT: "the desktop drew 15 icons for 16 launchers", named against the
# desktop, caused by a trailing space in a text file.
#
# WHAT IS ACTUALLY CORRECT
# ========================
# Neither of them. The authority is lib/desktopentry.ad, which is the code that
# really decides whether a launcher is hidden (desktop_parse, the
# X-Hamnix-LiveOnly arm at line 258). What it does, read off the source:
#
#   * lines are split on \n, and _is_space -- SPACE, TAB AND CR (line 119) --
#     is trimmed from BOTH ENDS of the line, from the end of the key, and from
#     both ends of the value. So `X-Hamnix-LiveOnly=true`, the same with a
#     trailing space, the same with a trailing CR, and `X-Hamnix-LiveOnly =
#     true` are ALL the same entry to the program;
#   * the value is then compared to "true" BYTE FOR BYTE and CASE-SENSITIVELY
#     (_de_key_eq, line 139), so `TRUE` is not true and `truely` is not true;
#   * a line starting '#' is a comment and is never a key at all (line 221).
#
# Measured against all eight of those cases, `grep -lix` is wrong in five and
# `grep -l` in three: -lix rejects a trailing space, a trailing CR and a
# leading space that the program ACCEPTS, and accepts a `TRUE` the program
# REJECTS; -l accepts `truely` and a commented-out line the program rejects,
# and both miss spaces around the `=`. So the substring form was closer, and
# still not right, and the case-insensitive one was wrong in the direction that
# UNDER-counts (a rejected trailing space means one launcher too few
# subtracted, which is the fabricated icon-count defect above).
#
# NO REAL FILE IN THE TREE CHANGES CLASSIFICATION under this reading. Checked:
# etc/hamde/apps (26 files) and etc/skel/Desktop (16) give 1 under all three
# readings, and the one is installer.desktop in each, whose LiveOnly line has
# no CR, no trailing space and a lower-case `true`. This makes the gates agree
# BEFORE a file drifts, not after.
#
# The one thing this does not model is the [Desktop Entry] section check: a key
# under some other group header would be counted here and not by the program.
# No .desktop file in this tree has a second group, and a grep cannot carry
# state; if one ever does, this is the line that has to become an awk.

# desktop_liveonly_files <file>... — print the ones marked live-medium-only.
desktop_liveonly_files() {
    grep -lE '^[[:space:]]*X-Hamnix-LiveOnly[[:space:]]*=[[:space:]]*true[[:space:]]*$' \
        "$@" 2>/dev/null
}

# desktop_liveonly_count <file>... — how many of them there are.
desktop_liveonly_count() {
    desktop_liveonly_files "$@" | wc -l
}
