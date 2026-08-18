#!/usr/bin/env bash
# scripts/test_hamsh_tok_capacity.sh
#
# REGRESSION GATE: a hamsh script that lexes past TOK_MAX must FAIL LOUDLY AND
# NOT RUN. It must never be truncated to the cap and executed anyway.
#
# WHY THIS IS THE MOST DANGEROUS PLACE IN THE TREE FOR A SILENT TRUNCATION
# =======================================================================
# /etc/rc.boot, /etc/rc.d/rc.<N> and every hpm install hook are rc scripts, and
# hamsh reads each of them WHOLE and lexes it as ONE logical input. A cap that
# drops the tail therefore drops the END of a boot script — the part that
# starts the desktop, or loads the last driver family, or writes the last file
# — and the machine comes up LOOKING FINE. This tree has already shipped a
# module list one driver family away from silently losing sound and an
# /etc/modules read that stopped at a buffer size; the same shape here costs a
# whole runlevel.
#
# THE ORIGINAL BUG (fixed 2026-06-25 for the CAP, 87da5762 for the SILENCE)
# ------------------------------------------------------------------------
# _emit_tok() SILENTLY dropped any token past TOK_MAX. etc/rc.d/rc.5 lexed to
# ~600 tokens and overran the old TOK_MAX=512. The dropped tail included rc.5's
# closing `}` and the trailing TK_EOF, so parse_program ran into zeroed token
# slots and aborted the WHOLE script with a spurious `parse error: empty
# command` — the scene-DE clients never launched, and the desktop was blank.
# TOK_MAX is 4096 now, and _emit_tok raises LEXERR_TOKMAX through _lex_fail()
# instead of truncating.
#
# WHAT THIS GATE MEASURES, AND WHAT IT USED TO ONLY GREP FOR
# ==========================================================
# Until 2026-08-18 the third check here was an awk hunt for the literal text
# `lex_error = 1` inside `def _emit_tok`, and it had been RED since 87da5762 —
# the commit that FIXED the bug. The fix routes through the `_lex_fail()`
# helper (first-failure-wins, records LEXERR_TOKMAX and the line), so the
# literal string it looked for is not there and never will be. It reported
# "_emit_tok overflow path does not set lex_error (would truncate silently)"
# about a shell that had not truncated silently for seven weeks. A string match
# on an implementation detail is not an assertion about behaviour; it fails when
# the code is refactored and — far worse — it would PASS on any rewrite that
# kept the string and broke the effect.
#
# So PART 3 is now a RUN. It compiles hamsh for x86_64-linux and executes two
# scripts through the real `hamsh <file>` path (the same _run_rc_path that
# sources /etc/rc.boot):
#
#   POSITIVE CONTROL  an UNDER-cap script must RUN COMPLETELY — both its first
#                     and its LAST statement must leave their marks, and it
#                     must exit 0. Without this, "the over-cap script left no
#                     marks" is not evidence about the cap; it is an instrument
#                     that cannot produce a mark at all.
#   THE ASSERTION     an OVER-cap script must (a) name the file and the LINE,
#                     (b) say NOT RUN, (c) leave ZERO marks — not even its
#                     FIRST statement's — and (d) exit NON-ZERO.
#
#   (d) IS ITS OWN CHECK AND IT IS NOT PEDANTRY. hamsh exits 0 on a PARSE
#   error, and it used to exit 0 on a LEXICAL error too — `hamsh script` came
#   back 0 for a script of which nothing had run, and hpm printed
#   `installed <pkg>` for a package whose hook did nothing. "Refused to run"
#   must not be spellable the same way as "ran fine".
#
# PART 4 IS THE NEGATIVE CONTROL, AND IT IS RUN, NOT ARGUED.
# It compiles a SECOND hamsh from a copy of user/hamsh.ad with exactly one line
# deleted — the `_lex_fail(LEXERR_TOKMAX, ...)` call in _emit_tok — which is
# the historical defect restored and nothing else. Against that binary the same
# over-cap script must be TRUNCATED AND RUN: its first statement's mark must
# appear, its last statement's mark must NOT, and it must exit 0. If the
# defective build behaves the same as the fixed one, PART 3 proved nothing and
# this gate says so instead of reporting a green.
#
# Runtime is dominated by the two hamsh compiles (~2-4 min total on this host).
# No QEMU.
#
# Exit 0 = PASS, 1 = FAIL.

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

TAG="[test_tok_capacity]"
HAMSH=user/hamsh.ad
RC5=etc/rc.d/rc.5

PASS=0; FAILN=0
ok()  { PASS=$((PASS+1));  echo "$TAG PASS: $*"; }
bad() { FAILN=$((FAILN+1)); echo "$TAG FAIL: $*" >&2; }
die() { echo "$TAG FAIL: $*" >&2; echo "$TAG RESULT: $PASS passed, $((FAILN+1)) failed"; exit 1; }

[ -f "$HAMSH" ] || die "$HAMSH missing"
[ -f "$RC5" ]   || die "$RC5 missing"

# =====================================================================
# PART 1 — the tok_* arrays must be sized to match TOK_MAX
# =====================================================================
TOK_MAX=$(grep -E '^TOK_MAX:[[:space:]]*uint64[[:space:]]*=' "$HAMSH" \
            | head -1 | sed -E 's/.*=[[:space:]]*([0-9]+).*/\1/')
[ -n "$TOK_MAX" ] || die "could not read TOK_MAX from $HAMSH"
echo "$TAG TOK_MAX = $TOK_MAX"

ARRAYS_OK=1
for arr in tok_kind tok_str tok_int tok_save_kind tok_save_str tok_save_int; do
    SZ=$(grep -E "^${arr}:[[:space:]]*Array\[" "$HAMSH" \
            | head -1 | sed -E 's/.*Array\[[[:space:]]*([0-9]+).*/\1/')
    [ -n "$SZ" ] || die "could not read array size for $arr"
    if [ "$SZ" -lt "$TOK_MAX" ]; then
        bad "$arr capacity $SZ < TOK_MAX $TOK_MAX (out-of-bounds risk)"
        ARRAYS_OK=0
    fi
done
[ "$ARRAYS_OK" = 1 ] && ok "all tok_* arrays >= TOK_MAX"

# =====================================================================
# PART 2 — TOK_MAX must leave real headroom over the largest sourced rc
# =====================================================================
# Mirror lex_line()'s tokenization rules closely enough to get a sound lower
# bound: skip whitespace + '#' comments to EOL; '\n'/';' -> one TK_NEWLINE; a
# quoted run -> one token; structural operators ({ } = > < | &) -> one token
# each; any other non-space run -> one word token. +1 for the trailing TK_EOF.
RC5_TOKS=$(python3 - "$RC5" <<'PY'
import sys
data = open(sys.argv[1], 'rb').read()
n = len(data); p = 0; toks = 0
SPACE = (32, 9, 13)
STRUCT = set(b"{}=><|&")
while p < n:
    c = data[p]
    if c in SPACE:
        p += 1; continue
    if c == 35:                      # '#' comment to EOL
        while p < n and data[p] != 10:
            p += 1
        continue
    if c == 10 or c == 59:           # '\n' / ';'
        toks += 1; p += 1; continue
    if c in (39, 34):                # quoted string -> one token
        q = c; p += 1
        while p < n and data[p] != q:
            p += 1
        p += 1; toks += 1; continue
    if c in STRUCT:                  # structural op -> one token
        toks += 1; p += 1; continue
    while p < n and data[p] not in SPACE and data[p] not in STRUCT \
            and data[p] not in (10, 59, 35) and data[p] not in (39, 34):
        p += 1
    toks += 1
print(toks + 1)                      # + trailing TK_EOF
PY
)
echo "$TAG rc.5 approx lexer tokens = $RC5_TOKS"
NEED=$(( RC5_TOKS * 3 / 2 ))
if [ "$TOK_MAX" -ge "$NEED" ]; then
    ok "TOK_MAX leaves >=1.5x headroom over rc.5 ($TOK_MAX >= $NEED)"
else
    bad "TOK_MAX $TOK_MAX < 1.5x rc.5 tokens ($NEED); rc.5 would silently truncate"
fi

# A structural ratchet, and it is NOT the assertion — PART 3 is. This only
# ensures the overflow branch still routes into the lexer's error machinery, so
# a refactor that deletes it has to answer for it here as well as there.
grep -Eq 'tok_count >= TOK_MAX' "$HAMSH" \
    && ok "_emit_tok still has a tok_count >= TOK_MAX guard" \
    || bad "_emit_tok overflow guard missing"
if awk '/^def _emit_tok/{f=1; next} f && (/_lex_fail\(LEXERR_TOKMAX/ || /lex_error = 1/){print "ok"; exit} f && /^def /{exit}' \
        "$HAMSH" | grep -q ok; then
    ok "_emit_tok's overflow branch raises a lexical error (_lex_fail/lex_error)"
else
    bad "_emit_tok overflow path raises no lexical error — it would truncate silently"
fi
grep -q 'token limit exceeded' "$HAMSH" \
    && ok "the lexer still has a human-readable 'token limit exceeded' diagnostic" \
    || bad "the 'token limit exceeded' diagnostic is gone"

# THE RUNLEVEL rc PATH, and this one is a RATCHET AND SAYS SO. /etc/rc.d/rc.<N>
# is sourced through _svc_source_path, NOT through _run_rc_path, and until
# 2026-08-18 that function cleared lex_fatal and returned 0 on every path — a
# runlevel rc that failed to lex was reported to svc_enter_runlevel as SOURCED,
# the runlevel proceeded to its built-in action, and the machine came up looking
# ordinary with none of the operator's script run. There is no host seam for a
# runlevel transition (it is PID 1's), so this is a SOURCE check and not a run;
# it is here so the wiring cannot be deleted without someone answering for it.
if awk '/^def _svc_source_path/{f=1} f && /return -2/{print "ok"; exit} f && /^def [^_]/{exit}' \
        "$HAMSH" | grep -q ok; then
    ok "_svc_source_path reports a lex failure to its caller (returns -2) — RATCHET, not a run"
else
    bad "_svc_source_path swallows a lex failure again — a runlevel rc that did not run would be reported as sourced"
fi
if grep -q 'ITS rc DID NOT RUN' "$HAMSH"; then
    ok "and svc_enter_runlevel says so on the console — RATCHET, not a run"
else
    bad "svc_enter_runlevel no longer announces a runlevel rc that did not run"
fi

# =====================================================================
# PART 3 — THE RUN. Compile hamsh and drive a real over-cap script.
# =====================================================================
OUT="build/host"
mkdir -p "$OUT"
BIN="$OUT/hamsh_tokcap"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

# shellcheck source=/dev/null
. "$PROJ_ROOT/scripts/_adder_bin.sh"

echo "$TAG compiling hamsh for x86_64-linux ..."
if ! adder_bin x86_64-linux "$HAMSH" "$BIN" 2>"$W/compile.log"; then
    echo "$TAG ---- compile log ----"; tail -30 "$W/compile.log"
    die "host hamsh did not compile — this gate cannot observe its assertion"
fi
ok "host hamsh compiled"

# Build a script of N padded echo lines with a distinct FIRST and LAST mark.
# Each pad line is 20 BYTES and 11 LEXER TOKENS (9 words + the newline + the
# echo). The lines are deliberately byte-lean so the TOKEN cap is the only cap
# in play: 600 lines is ~12 KiB, comfortably inside the 16 KiB SL_STAGE_CAP
# staging buffer (a bigger script is not refused — it takes the mmap path — but
# keeping it inside the buffer removes the question), and ~6600 tokens, well
# over TOK_MAX=4096. 100 lines is ~1100 tokens, well under.
mkscript() {   # mkscript <lines> <script-path> <marker-dir>
    local n="$1" f="$2" d="$3" i=0
    mkdir -p "$d"
    : > "$f"
    printf 'echo HEAD-RAN > %s/head\n' "$d" >> "$f"
    while [ "$i" -lt "$n" ]; do
        printf 'echo a b c d e f g h i\n' >> "$f"
        i=$((i+1))
    done
    printf 'echo TAIL-RAN > %s/tail\n' "$d" >> "$f"
    printf 'exit\n' >> "$f"
}

mkscript 100 "$W/under.hs" "$W/under_m"
mkscript 600 "$W/over.hs"  "$W/over_m"
echo "$TAG under-cap script: $(wc -c < "$W/under.hs") bytes; over-cap: $(wc -c < "$W/over.hs") bytes"

run_case() {   # run_case <binary> <script> <outfile>; echoes the exit status
    timeout 120 "$1" "$2" < /dev/null > "$3" 2>&1
    echo $?
}

# --- POSITIVE CONTROL ------------------------------------------------
U_RC="$(run_case "$BIN" "$W/under.hs" "$W/under.out")"
if [ -f "$W/under_m/head" ] && [ -f "$W/under_m/tail" ]; then
    ok "POSITIVE CONTROL: an under-cap script runs to its LAST statement (head+tail marks both written)"
else
    bad "POSITIVE CONTROL: an under-cap script did NOT run through (head=$([ -f "$W/under_m/head" ] && echo yes || echo no) tail=$([ -f "$W/under_m/tail" ] && echo yes || echo no)) — every negative below is from a blind instrument"
    head -20 "$W/under.out"
fi
[ "$U_RC" = 0 ] && ok "POSITIVE CONTROL: under-cap script exits 0 (got $U_RC)" \
                || bad "POSITIVE CONTROL: under-cap script exited $U_RC, expected 0"

# --- THE ASSERTION ---------------------------------------------------
O_RC="$(run_case "$BIN" "$W/over.hs" "$W/over.out")"

if [ -f "$W/over_m/head" ] || [ -f "$W/over_m/tail" ]; then
    bad "AN OVER-CAP SCRIPT RAN. marks present: $(ls -1 "$W/over_m" | tr '\n' ' ')— it was lexed to the cap and executed anyway"
else
    ok "an over-cap script runs NOTHING — not even its first statement"
fi

if grep -q 'token limit exceeded' "$W/over.out"; then
    ok "the overflow is REPORTED: $(grep -m1 'token limit exceeded' "$W/over.out" | sed 's/^.*lexical error/lexical error/')"
else
    bad "the over-cap script produced no 'token limit exceeded' report"
    head -20 "$W/over.out"
fi
if grep -qE "^hamsh: .*over\.hs:[0-9]+: lexical error" "$W/over.out"; then
    ok "and it names the FILE and the LINE: $(grep -m1 -oE 'over\.hs:[0-9]+' "$W/over.out")"
else
    bad "the report does not name the file and line the overflow happened on"
fi
grep -q 'NOT RUN' "$W/over.out" \
    && ok "and it says NOT RUN in words, so a reader is not left guessing how much took effect" \
    || bad "the report never says the script did not run"

# The one that separates "refused" from "ran fine".
if [ "$O_RC" != 0 ]; then
    ok "AND IT EXITS NON-ZERO ($O_RC) — 'refused to run' is not spelled the same as 'ran fine'"
else
    bad "hamsh EXITED 0 for a script of which NOTHING ran — every caller (hpm, a service loader, the battery) reads that as success"
fi

# =====================================================================
# PART 4 — THE NEGATIVE CONTROL, RUN. Defeat the guard, keep everything
# else, and require the DEFECT back.
# =====================================================================
# The compiler resolves imports relative to the project root and CANNOT take a
# source outside it (compile_with_imports does a Path.relative_to). Measured:
# the first version of this negative control put the patched copy in $TMPDIR and
# the compile died with a ValueError -- which the gate correctly reported as
# "the negative control did not run", rather than as a pass.
NEG="$OUT/hamsh_tokcap_defect.ad"
NEGBIN="$OUT/hamsh_tokcap_defect"
# Delete exactly the _lex_fail(LEXERR_TOKMAX, ...) call in _emit_tok. What is
# left is the historical defect: drop the token, force a terminating TK_EOF,
# say nothing.
grep -c '_lex_fail(LEXERR_TOKMAX' "$HAMSH" > "$W/negcount"
if [ "$(cat "$W/negcount")" != "1" ]; then
    bad "expected exactly ONE _lex_fail(LEXERR_TOKMAX call to delete, found $(cat "$W/negcount") — the negative control cannot be built as intended"
else
    sed '/_lex_fail(LEXERR_TOKMAX/d' "$HAMSH" > "$NEG"
    echo "$TAG compiling the DEFECTIVE hamsh (overflow guard deleted) ..."
    if ! adder_bin x86_64-linux "$NEG" "$NEGBIN" 2>"$W/negcompile.log"; then
        echo "$TAG ---- defect compile log ----"; tail -20 "$W/negcompile.log"
        bad "the defective hamsh did not compile — the negative control did not run, so PART 3's greens are unproven"
    else
        rm -rf "$W/over_m"; mkdir -p "$W/over_m"
        N_RC="$(run_case "$NEGBIN" "$W/over.hs" "$W/negover.out")"
        if [ -f "$W/over_m/head" ] && [ ! -f "$W/over_m/tail" ]; then
            ok "NEGATIVE CONTROL: with the guard deleted the SAME script is TRUNCATED AND RUN — its first statement ran, its last did not"
        else
            bad "NEGATIVE CONTROL DID NOT REPRODUCE THE DEFECT (head=$([ -f "$W/over_m/head" ] && echo yes || echo no) tail=$([ -f "$W/over_m/tail" ] && echo yes || echo no)). PART 3 above is therefore NOT shown able to fail, and its greens prove nothing"
            head -20 "$W/negover.out"
        fi
        # NOT `= 0`. MEASURED: the defective build exits 124, and the reason is
        # worth writing down. The `exit` on the script's last line is part of the
        # tail the defect DROPS, so the truncated program simply ends — and hamsh
        # then falls into its interactive REPL on a stdin that is already at EOF,
        # where it BUSY-SPINS at 100% CPU instead of leaving. (Measured
        # separately: 12+ minutes at 99.9% CPU on one core.) `timeout` reaps it
        # at 124. That is a real, separate defect in the REPL's EOF handling and
        # it is NOT what this gate is about; what this gate needs from the
        # negative control is that the defective build's status does NOT carry
        # the fixed build's honest diagnosis. 1 is that diagnosis. Anything else
        # -- 0 for a truncated run that finished, 124 for one that hung -- is a
        # caller being told something other than "this script did not run".
        if [ "$N_RC" != 1 ]; then
            ok "NEGATIVE CONTROL: the truncated run's status ($N_RC) is NOT the fixed build's honest 1 — the exit-status assertion in PART 3 is shown able to fail"
        else
            bad "NEGATIVE CONTROL: the defective build ALSO exited 1, so PART 3's exit-status assertion is not shown able to fail"
        fi
        grep -q 'token limit exceeded' "$W/negover.out" \
            && bad "NEGATIVE CONTROL: the defective build still reported the overflow — the deletion did not defeat the guard" \
            || ok "NEGATIVE CONTROL: and it says NOTHING about the overflow"
    fi
fi

# =====================================================================
echo "$TAG ---------------------------------------------"
echo "$TAG RESULT: $PASS PASSED, $FAILN FAILED"
[ "$FAILN" -eq 0 ] || exit 1
[ "$PASS" -ge 14 ] || { echo "$TAG FAIL: only $PASS assertions ran; this gate observes 14+ when it is working" >&2; exit 1; }
echo "$TAG PASS"
exit 0
