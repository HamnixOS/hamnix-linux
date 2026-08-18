#!/usr/bin/env bash
#
# scripts/release_gates.sh — THE RELEASE DRIVER, IN THE TREE.
#
# WHY THIS FILE EXISTS, AND WHERE IT USED TO LIVE
# ===============================================
# Until 2026-08-18 the thing that decided whether a release shipped was
# `~/.hamnix-build/rel<NNNN>/gates.sh` — a file typed fresh each release,
# living OUTSIDE the repository, reviewed by nobody, and regressed by nothing.
# It had, in its own scoring, the exact defect this tree has spent a week
# cataloguing everywhere else. Two of them, both measured:
#
#   1. IT COUNTED THE WORD "PASS". Its scorer was
#          grep -cE '(^|[[:space:]])PASS([[:space:]]|:)' "$log"
#      tests/linux/wsys_stdin_keydup.sh reports assertions as `ok   <text>` and
#      summarises as `8 passed, 0 failed` — lowercase, no bare `PASS` token.
#      So `rel1029/GATES_SUMMARY.txt` recorded, verbatim:
#
#          wsys_stdin_keydup EXIT=0
#          wsys_stdin_keydup PASS-lines: 0
#          wsys_stdin_keydup FAIL-lines: 0
#
#      for a gate that really scored 8 / 0. A gate that asserted EIGHT things
#      and a gate that asserted NOTHING produced byte-identical scores. That is
#      "exit 0 read as a pass" — the class this tree keeps finding — alive in
#      the one script that gates the release.
#
#   2. THE MEDIUM GATE WAS NOT IN IT. `scripts/verify_medium.sh` appears zero
#      times in rel1029/gates.sh. Its 39 / 0 came from a separate invocation
#      typed by hand. The one gate that inspects the shipped medium was never
#      run by the driver that gates the shipped medium.
#
# THE RULES THIS DRIVER OBEYS
# ===========================
#   * A GATE IS SCORED BY WHAT IT ASSERTED, NOT BY WHAT IT RETURNED. The exit
#     status is recorded and cross-checked, never used as the pass criterion.
#   * A GATE WHOSE OUTPUT CANNOT BE PARSED IS **UNSCORABLE**, NOT ZERO. It
#     turns the release red and says so in words. Silence must never be
#     spendable as a green.
#   * A GATE THAT SCORED 0 / 0 ASSERTED NOTHING, AND THAT IS NOT A PASS.
#   * MANY VOCABULARIES, ONE MEANING. `8 passed, 0 failed`,
#     `14 PASSED / 0 FAILED`, `18 PASSED, 0 FAILED`, `pass=21 fail=1`,
#     `SUMMARY: 39 PASSED, 39 FAILED` are all read. A gate is free to print in
#     its own dialect; the driver is not free to score only one dialect.
#   * THE SUMMARY IS CROSS-CHECKED AGAINST THE GATE'S OWN ASSERTION LINES. If a
#     gate printed FAIL lines under a summary claiming zero failures, the
#     release goes red — the summary is not believed over the body.
#   * A KNOWN FAILURE MUST BE DECLARED HERE, IN THE REGISTRY, WITH ITS REASON.
#     An undeclared failure is red however long it has been failing.
#   * A GATE THAT ASSERTS FEWER THINGS THAN IT USED TO IS RED. Each registry
#     row carries `expect_min`, the number of assertions the gate is known to
#     make. MEASURED 2026-08-18: scripts/verify_medium.sh scored 39 / 0 for the
#     1.0.29 release and 38 / 0 from a clean worktree — it drops its
#     '/bin/hpm on the medium is the channel's hpm' assertion, silently and
#     with no FAIL line, when build/repo/linux/packages is absent. A driver
#     that only reads 'N passed, 0 failed' cannot tell a gate that lost an
#     assertion from one that passed them all.
#
# NEGATIVE CONTROL
# ================
#   bash scripts/release_gates.sh --self-test
# runs the driver over two synthetic gates: one that scores 8 / 0 in the exact
# `ok` / `FAIL` vocabulary the old driver could not see, and one that exits 0
# having asserted nothing at all. The driver must score the first 8 / 0 GREEN
# and refuse the second. If those two come out the same, this driver is as
# blind as the one it replaces and the self-test fails.
#
# USAGE
# =====
#   HAMLINUX_RELEASE_IMG=~/.hamnix-build/rel1029/hamnix-linux-1.0.29.img \
#   HAMLINUX_RELEASE_DIR=~/.hamnix-build/rel1029 \
#     bash scripts/release_gates.sh [gate-name ...]
#
#   --list        print the registry and exit
#   --self-test   run the negative control described above and exit
#   --host-only   skip every gate marked as booting QEMU
#
# Environment:
#   HAMLINUX_RELEASE_IMG   the medium under test (required by the medium gates)
#   HAMLINUX_RELEASE_SHA   its expected sha256 (passed to shipped_medium_boots)
#   HAMLINUX_RELEASE_DIR   where logs are written (default: a mktemp -d)
#
# REGISTRATION: this file is not in ci_battery_manifest.txt because it is a
# release driver, not a gate — it runs gates, several of which boot QEMU and
# take a release artifact that no CI runner has. Its own correctness is gated
# by --self-test, which is QEMU-free and IS registered.
#
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

IMG="${HAMLINUX_RELEASE_IMG:-}"
SHA="${HAMLINUX_RELEASE_SHA:-}"
OUT="${HAMLINUX_RELEASE_DIR:-}"

# =============================================================================
# THE SCORER
# =============================================================================
# score_log <file> — echoes "<pass> <fail> <dialect>" and returns 0, or returns
# 1 having echoed nothing, meaning THE OUTPUT COULD NOT BE PARSED. Returning 1
# is a real answer: it is "I do not know what this gate asserted", which is a
# different thing from "it asserted nothing", which is different again from
# "it asserted things and none failed". The old driver collapsed all three.
score_log() {
    awk '
        function take(p, f, d) { P = p; F = f; D = d; seen = 1 }
        # 1. "<n> PASSED / <m> FAILED"  and  "<n> PASSED, <m> FAILED"
        match($0, /[0-9]+[ \t]+PASSED[ \t]*[,\/][ \t]*[0-9]+[ \t]+FAILED/) {
            s = substr($0, RSTART, RLENGTH)
            n = s; sub(/[^0-9].*$/, "", n)
            m = s; sub(/^[^,\/]*[,\/][ \t]*/, "", m); sub(/[^0-9].*$/, "", m)
            take(n, m, "N PASSED/FAILED"); next
        }
        # 2. "<n> passed, <m> failed"  (lowercase — the dialect that scored 0)
        match($0, /[0-9]+[ \t]+passed[ \t]*[,\/][ \t]*[0-9]+[ \t]+failed/) {
            s = substr($0, RSTART, RLENGTH)
            n = s; sub(/[^0-9].*$/, "", n)
            m = s; sub(/^[^,\/]*[,\/][ \t]*/, "", m); sub(/[^0-9].*$/, "", m)
            take(n, m, "n passed, m failed"); next
        }
        # 3. "pass=<n> fail=<m>"
        match($0, /pass=[0-9]+[ \t]+fail=[0-9]+/) {
            s = substr($0, RSTART, RLENGTH)
            n = s; sub(/^pass=/, "", n); sub(/[^0-9].*$/, "", n)
            m = s; sub(/^.*fail=/, "", m); sub(/[^0-9].*$/, "", m)
            take(n, m, "pass=n fail=m"); next
        }
        # 4. "<n> PASS / <m> FAIL"  (no -ED)
        match($0, /[0-9]+[ \t]+PASS[ \t]*[,\/][ \t]*[0-9]+[ \t]+FAIL([^A-Za-z]|$)/) {
            s = substr($0, RSTART, RLENGTH)
            n = s; sub(/[^0-9].*$/, "", n)
            m = s; sub(/^[^,\/]*[,\/][ \t]*/, "", m); sub(/[^0-9].*$/, "", m)
            take(n, m, "N PASS/FAIL"); next
        }
        END { if (seen) printf "%d %d %s\n", P, F, D }
    ' "$1"
}

# tally_log <file> — echoes "<ok-lines> <fail-lines>". This is the CROSS-CHECK,
# not the score: it counts the gate's own per-assertion lines in every prefix
# vocabulary this tree uses (`ok  `, `  PASS  `, `  FAIL  `, `FAIL `, `not ok`)
# so that a summary line claiming zero failures over a body full of FAILs can
# be caught. verify_medium.sh's own header records that exact escape happening.
tally_log() {
    awk '
        /^[ \t]*(ok|PASS)[ \t]/   { o++ }
        /^[ \t]*(FAIL|not ok)[ \t]/ { f++ }
        END { printf "%d %d\n", o+0, f+0 }
    ' "$1"
}

# =============================================================================
# THE REGISTRY
# =============================================================================
# One record per line:
#   name | qemu | allow_fail | expect_min | reason-for-allowance | command
# `qemu` is yes/no. `allow_fail` is the number of failures DECLARED acceptable;
# anything above it is red, and 0 is the default. `expect_min` is the number of
# assertions the gate is KNOWN to make; scoring fewer is red even when none of
# them failed. Every number here was measured on this host on 2026-08-18 and is
# a reviewable act in version control, which is the entire point of this file
# not living in a scratch directory any more.
registry() {
cat <<'REGISTRY'
wsys_stdin_keydup|no|0|8||bash tests/linux/wsys_stdin_keydup.sh
hamsh_eof_exit|no|0|14||bash tests/linux/hamsh_eof_exit.sh
wsys_zombie_strand|no|0|8||bash tests/linux/wsys_zombie_strand.sh
# wsys_zombie_owner.sh was in scripts/ci_battery_manifest.txt and NOT here.
# The driver ran the gate for the 2026-08-18 segment fix and not the gate for
# the 2026-08-17 window-reaper fix in the same file. Measured 9 / 0 on this
# host, 2026-08-18, before it was registered.
wsys_zombie_owner|no|0|9||bash tests/linux/wsys_zombie_owner.sh
test_hamsh_tok_capacity|no|0|18||bash scripts/test_hamsh_tok_capacity.sh
test_livedom_functional_host|no|1|22|06_class_style_toggle is declared in the gate's own KNOWNFAIL list|bash scripts/test_livedom_functional_host.sh
channel_bytes_match_image|no|0|3||bash tests/linux/channel_bytes_match_image.sh
channel_covers_image|no|0|8||bash tests/linux/channel_covers_image.sh
pkg_tar_reproducible|no|0|5||bash tests/linux/pkg_tar_reproducible.sh
verify_medium|no|0|39||bash scripts/verify_medium.sh @IMG@
install_confirm_keys|yes|0|34||bash tests/linux/install_confirm_keys.sh
install_wizard_gui|yes|0|34||bash tests/linux/install_wizard_gui.sh
# THE SOAK'S DURATION IS PINNED HERE, not left to an env var typed at the
# console. tests/linux/soak_desktop.sh defaults to 3600 s; expect_min=26 was
# measured at 900 s with ARM 0 ARMED (no HAMLINUX_SOAK_SKIPPROOF). A release
# driver that inherits the duration from whoever invoked it is not a record
# of what was run. env(1) is used because the runner word-splits this command
# and a bare VAR=x prefix would be taken as the program name.
soak_desktop|yes|0|26||env HAMLINUX_SOAK_SECS=900 bash tests/linux/soak_desktop.sh
shipped_medium_boots|yes|0|31||bash tests/linux/shipped_medium_boots.sh @IMG@
REGISTRY
}

# =============================================================================
# THE RUNNER
# =============================================================================
RED=0; GREEN=0; UNSCORABLE=0; TOTAL_ASSERTED=0
VERDICTS=""

run_gate() {   # run_gate <name> <allow_fail> <expect_min> <reason> <cmd...>
    local name="$1" allow="$2" expect="$3" reason="$4"; shift 4
    [ -n "$expect" ] || expect=0
    local log="$OUT/$name.log"
    printf '########## %-32s %s\n' "$name" "$(date +%H:%M:%S)"
    "$@" >"$log" 2>&1
    local rc=$?

    local s p f dialect
    s="$(score_log "$log")"
    if [ -z "$s" ]; then
        printf '  %-14s exit=%s  -- THE DRIVER COULD NOT PARSE THIS GATE'"'"'S OUTPUT.\n' "UNSCORABLE" "$rc"
        echo   "                 It printed no summary line in any dialect this driver knows."
        echo   "                 THIS IS NOT A ZERO AND IT IS NOT A PASS. Either the gate"
        echo   "                 asserted nothing, or it speaks a dialect that must be added"
        echo   "                 to score_log() in scripts/release_gates.sh. Log: $log"
        UNSCORABLE=$((UNSCORABLE+1)); RED=$((RED+1))
        VERDICTS="$VERDICTS$name UNSCORABLE (exit $rc)\n"
        echo; return
    fi
    p="${s%% *}"; f="$(echo "$s" | cut -d' ' -f2)"; dialect="$(echo "$s" | cut -d' ' -f3-)"

    local t to tf
    t="$(tally_log "$log")"; to="${t%% *}"; tf="${t##* }"

    local verdict="PASS" why=""
    if [ "$p" -eq 0 ] && [ "$f" -eq 0 ]; then
        verdict="RED"; why="THE GATE ASSERTED NOTHING -- 0 passed and 0 failed is not a pass"
    elif [ "$f" -gt "$allow" ]; then
        verdict="RED"; why="$f failed, $allow declared acceptable"
    elif [ "$tf" -gt 0 ] && [ "$f" -eq 0 ]; then
        verdict="RED"; why="the gate printed $tf FAIL line(s) under a summary claiming 0 failures -- the body is believed, not the summary"
    elif [ "$rc" -ne 0 ] && [ "$f" -le "$allow" ]; then
        verdict="RED"; why="exit status $rc contradicts a summary with no unexpected failures -- one of the two is wrong and neither may be ignored"
    elif [ "$((p + f))" -lt "$expect" ]; then
        verdict="RED"; why="the gate scored $((p + f)) assertions where $expect are registered -- it ASSERTED LESS THAN IT USED TO and printed no failure saying so"
    fi

    printf '  %-14s %s / %s   exit=%s   [%s]\n' \
        "$verdict" "$p passed" "$f failed" "$rc" "$dialect"
    printf '                 assertion lines seen in body: %s ok-ish, %s fail-ish\n' "$to" "$tf"
    [ -n "$reason" ] && [ "$allow" -gt 0 ] && \
        printf '                 %s failure(s) DECLARED: %s\n' "$allow" "$reason"
    [ -n "$why" ] && printf '                 WHY RED: %s\n' "$why"
    printf '                 log: %s\n' "$log"

    TOTAL_ASSERTED=$((TOTAL_ASSERTED + p + f))
    if [ "$verdict" = "PASS" ]; then GREEN=$((GREEN+1)); else RED=$((RED+1)); fi
    VERDICTS="$VERDICTS$name $verdict ${p}/${f}\n"
    echo
}

# =============================================================================
# THE NEGATIVE CONTROL
# =============================================================================
self_test() {
    local d; d="$(mktemp -d)"
    OUT="$d"

    # (A) A gate that asserts EIGHT things and fails none, in the `ok` / `FAIL`
    #     vocabulary and the lowercase summary that the old driver scored ZERO.
    cat >"$d/eight.sh" <<'GATE'
#!/usr/bin/env bash
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1"; }
for i in 1 2 3 4 5 6 7 8; do ok "synthetic assertion $i"; done
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || exit 1
GATE

    # (B) A gate that genuinely asserts NOTHING and exits 0 -- the 43-skipped
    #     shape that was once reported as "40 of 40 pass".
    cat >"$d/nothing.sh" <<'GATE'
#!/usr/bin/env bash
echo "=== synthetic gate: preconditions not met"
echo "SKIPPED: the lane this gate asserts against was retired"
exit 0
GATE

    # (C) A gate that prints a clean summary over a body full of real failures.
    cat >"$d/liar.sh" <<'GATE'
#!/usr/bin/env bash
echo "  PASS  something true"
echo "  FAIL  something that is actually broken"
echo "  FAIL  something else that is actually broken"
echo "SUMMARY: 1 PASSED, 0 FAILED"
exit 0
GATE

    # (D) A gate that used to assert eight things and now asserts three,
    #     failing none of them and saying nothing about the five it dropped.
    #     This is scripts/verify_medium.sh's real 39 -> 38, in miniature.
    cat >"$d/shrunk.sh" <<'GATE'
#!/usr/bin/env bash
PASS=0
ok() { PASS=$((PASS+1)); echo "ok   $1"; }
for i in 1 2 3; do ok "synthetic assertion $i"; done
echo "$PASS passed, 0 failed"
GATE

    echo "=== scripts/release_gates.sh --self-test"
    echo "=== THE NEGATIVE CONTROL. Three synthetic gates; the driver must tell"
    echo "=== them apart. If A and B score the same, this driver is blind."
    echo
    run_gate ctrl_A_eight_in_ok_vocabulary   0 8 "" bash "$d/eight.sh"
    run_gate ctrl_B_asserts_nothing          0 0 "" bash "$d/nothing.sh"
    run_gate ctrl_C_summary_contradicts_body 0 0 "" bash "$d/liar.sh"
    run_gate ctrl_D_lost_an_assertion        0 8 "" bash "$d/shrunk.sh"

    local vA vB vC vD
    vA="$(printf "$VERDICTS" | awk '$1=="ctrl_A_eight_in_ok_vocabulary"{print $2" "$3}')"
    vB="$(printf "$VERDICTS" | awk '$1=="ctrl_B_asserts_nothing"{print $2}')"
    vC="$(printf "$VERDICTS" | awk '$1=="ctrl_C_summary_contradicts_body"{print $2}')"
    vD="$(printf "$VERDICTS" | awk '$1=="ctrl_D_lost_an_assertion"{print $2}')"

    local bad=0
    echo "---- SELF-TEST ASSERTIONS"
    if [ "$vA" = "PASS 8/0" ]; then
        echo "  PASS  A: the eight-assertion gate in ok/FAIL vocabulary scored 8/0 GREEN"
        echo "        (the old driver scored this same gate 'PASS-lines: 0, FAIL-lines: 0')"
    else
        echo "  FAIL  A: expected 'PASS 8/0', got '$vA'"; bad=1
    fi
    if [ "$vB" = "UNSCORABLE" ]; then
        echo "  PASS  B: the gate that asserted nothing was REFUSED, not scored zero"
    else
        echo "  FAIL  B: expected UNSCORABLE, got '$vB'"; bad=1
    fi
    if [ "$vC" = "RED" ]; then
        echo "  PASS  C: a summary claiming 0 FAILED over a body with FAIL lines is RED"
    else
        echo "  FAIL  C: expected RED, got '$vC'"; bad=1
    fi
    if [ "$vD" = "RED" ]; then
        echo "  PASS  D: a gate that scored 3 where 8 are registered was caught LOSING assertions"
    else
        echo "  FAIL  D: expected RED, got '$vD'"; bad=1
    fi
    if [ "$vA" != "$vB" ]; then
        echo "  PASS  A and B are DISTINGUISHED ('$vA' vs '$vB') -- which is the whole point"
    else
        echo "  FAIL  A and B scored identically; this driver is as blind as the one it replaces"; bad=1
    fi
    echo
    if [ "$bad" = 0 ]; then
        echo "[release_gates --self-test] RESULT: 5 PASSED / 0 FAILED"
        rm -rf "$d"; exit 0
    fi
    echo "[release_gates --self-test] RESULT: 0 PASSED / 1 FAILED"
    exit 1
}

# =============================================================================
# MAIN
# =============================================================================
HOST_ONLY=0; WANT=""
for a in "$@"; do
    case "$a" in
        --list) registry | awk -F'|' '/^[^#]/ && NF {printf "%-32s qemu=%-3s allow_fail=%s\n", $1, $2, $3}'; exit 0 ;;
        --self-test) self_test ;;
        --host-only) HOST_ONLY=1 ;;
        -*) echo "unknown option: $a" >&2; exit 2 ;;
        *) WANT="$WANT $a" ;;
    esac
done

[ -n "$OUT" ] || OUT="$(mktemp -d)"
mkdir -p "$OUT"
echo "=== scripts/release_gates.sh   $(date -Iseconds)"
echo "=== tree:     $PROJ_ROOT  @ $(git rev-parse --short HEAD 2>/dev/null || echo '?')"
echo "=== artifact: ${IMG:-<none set: HAMLINUX_RELEASE_IMG>}"
echo "=== logs:     $OUT"
echo

[ -n "$SHA" ] && export HAMLINUX_SHIPPED_SHA="$SHA"

SKIPPED_QEMU=0
while IFS='|' read -r name qemu allow expect reason cmd; do
    case "$name" in ''|\#*) continue ;; esac
    if [ -n "$WANT" ]; then
        case " $WANT " in *" $name "*) ;; *) continue ;; esac
    fi
    if [ "$HOST_ONLY" = 1 ] && [ "$qemu" = yes ]; then
        echo "########## $name -- SKIPPED (--host-only, this gate boots QEMU)"
        echo "                 A SKIP IS NOT A PASS and is counted as such below."
        echo
        SKIPPED_QEMU=$((SKIPPED_QEMU+1)); continue
    fi
    case "$cmd" in
        *@IMG@*)
            if [ -z "$IMG" ]; then
                echo "########## $name -- CANNOT RUN: needs HAMLINUX_RELEASE_IMG"
                echo "                 NOT SCORED, NOT SKIPPED QUIETLY. The release is red."
                echo
                RED=$((RED+1)); UNSCORABLE=$((UNSCORABLE+1))
                VERDICTS="$VERDICTS$name NO-ARTIFACT\n"; continue
            fi
            cmd="${cmd//@IMG@/$IMG}" ;;
    esac
    # shellcheck disable=SC2086
    run_gate "$name" "$allow" "$expect" "$reason" $cmd
done < <(registry)

echo "==============================================================="
printf "$VERDICTS"
echo "---------------------------------------------------------------"
echo "GREEN: $GREEN   RED: $RED   (of which UNSCORABLE: $UNSCORABLE)"
echo "SKIPPED because --host-only: $SKIPPED_QEMU  -- a skip is not a pass"
echo "TOTAL ASSERTIONS ACTUALLY SCORED: $TOTAL_ASSERTED"
echo "==============================================================="
[ "$RED" -eq 0 ] && [ "$SKIPPED_QEMU" -eq 0 ] && [ "$GREEN" -gt 0 ] || exit 1
exit 0
