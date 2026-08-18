#!/usr/bin/env bash
#
# THE SOFT-GREEN IS CLOSED, 2026-08-18, AND THE fail=1 HAS A NAME.
#
# This file used to print `[livedom] RESULT pass=21 fail=1` and EXIT 0 — it
# reported its own red and then handed CI the byte that means "the assertion
# was observed to hold". Measured again before anything was changed (755f6e19,
# clean tree, chromium 147.0.7727.137): pass=21 fail=1, exit 0. The one failure
# is 06_class_style_toggle and it is a real engine gap — `el.style.*` writes
# never mirror into the `style` content attribute, so el.attributes and
# getAttribute('style') never see them. It is DECLARED in
# tests/fixtures/livedom/KNOWNFAIL with the measurement and the consequence,
# printed loudly on every run, and NOT silenced: see the VERDICT block at the
# bottom of this file for the four ways this gate now exits 1, and note that a
# fixture failing in NEITHER BASELINE nor KNOWNFAIL is one of them.
#
# The no-chromium path exits 125 (INCONCLUSIVE, scripts/_verdict.sh) rather
# than 0, for the same reason: a run with no oracle observed nothing.
# scripts/test_livedom_functional_host.sh — LIVE-DOM FUNCTIONAL harness.
#
# WHY THIS EXISTS
# ===============
# Every browser harness we had compares one of two things:
#   * PIXELS  — scripts/framediff_gfx_all.sh (SSIM against a chromium screenshot)
#   * ONE FACT — the ~200 scripts/test_hambrowse_*_host.sh gates, each of which
#     publishes a single hand-written string (console.log / document.title) and
#     compares it to a chromium-measured constant.
# Neither can see the class of bug that keeps real sites from WORKING: a page
# renders, but the elements its JavaScript created or replaced are not reachable
# by events, so the second click does nothing. A pixel diff of a correct-looking
# first paint is green for exactly that page.
#
# This harness compares the WHOLE LIVE DOM after scripts have run AND after real
# events have been dispatched, against real `chromium --headless` on the same
# file. It is the "dump-dom diff" lane: per fixture, one canonical serialisation
# from each engine, diffed line by line.
#
# METHOD
# ======
# One IDENTICAL driver script (SERIALIZER below) is appended to a copy of each
# fixture and run in BOTH engines. It:
#   1. waits a macrotask for the page's own load-time script,
#   2. calls the fixture's window.__act() — the fixture's interaction script,
#      which dispatches REAL events (el.click(), el.dispatchEvent(...)) into
#      whatever the page built dynamically,
#   3. drains timers (nested setTimeout, then a 50 ms one — the same drain
#      scripts/probe_realweb_dom.sh uses),
#   4. walks the resulting LIVE DOM in document order and console.log()s one
#      line per node.
# Both engines' console output is read off the same channel: hambrowse prints it
# as `JSLOG ...`, chromium as `--enable-logging=stderr` CONSOLE lines. The
# producer is the same JS in both, so the comparison is of the two engines' DOMs
# and event machinery, not of two different serialisers.
#
# The evidence for "the new node is reachable by events" is structural: the
# fixture's handlers only mutate the DOM, so a handler that did not fire shows up
# as a MISSING node in the diff, not as a soft assertion.
#
# WHAT IS NORMALISED, AND WHY  (read this before trusting a green)
# ================================================================
# The failure mode of a harness like this is an over-eager normaliser that hides
# real divergence. The complete list of what we throw away:
#   N1 whitespace-only text nodes are DROPPED and runs of whitespace inside a
#      text node are collapsed to one space. HTML source indentation produces
#      text nodes whose exact splitting is a parser detail, not a functional
#      one. This canNOT hide a missing element, a missing attribute, or missing
#      text — only the shape of inter-element whitespace.
#   N2 text-node content is truncated to 100 chars (with a "…" marker). Keeps a
#      console line inside chromium's logging path. Divergence beyond char 100
#      of a single text node is invisible; fixtures are written short so this
#      never bites.
#   N3 attributes are emitted SORTED BY NAME. Attribute order is not part of the
#      DOM. Names and values are compared verbatim — nothing about a value is
#      normalised.
#   N4 the contents (not the presence) of <script> and <style> elements are
#      skipped. That text is source, not live state, and the injected driver
#      would otherwise dominate every diff.
#   N5 the injected driver <script id="__ldh"> element itself is skipped on both
#      sides — it exists only because we put it there.
#   N6 tag names are lowercased (chromium reports HTML tagName uppercase).
#   N7 the doctype node is not serialised.
# NOT normalised, on purpose: element presence, order, depth, tag, attribute
# names and values, text content, comment nodes (frameworks use them as
# markers), input .value / .checked / select .selectedIndex live state, and the
# node count. A fixture that renders identically but whose click did nothing
# fails here.
#
# WHAT THE FIRST RUN FOUND (2026-08-04, main a5e53862) — pass 0 / fail 15
# ======================================================================
# The brief this harness was built for said "dynamically-created/updated
# elements are unreachable by events". THAT IS NOT WHAT IS BROKEN. Directly
# measured, both engines agree exactly:
#   * a click on a script-created <button> runs its listener,
#   * a click on a node inside an innerHTML-replaced subtree runs its listener,
#   * a click on a 5-deep script-built tree bubbles to a delegated ancestor with
#     the right event.target and event.currentTarget,
#   * three clicks in a row accumulate state on the same created node.
# Events REACH dynamic nodes. What diverges is DOM READ-BACK after mutation, and
# a short list of specific API gaps. In fixture order, the causes are:
#   D1 el.attributes omits attributes set through PROPERTY setters (el.id = x,
#      el.className = x). getAttribute('id') and getAttributeNames() both have
#      them; only the NamedNodeMap is missing them. Single biggest diff producer
#      — it is why nearly every created node prints "[]" here.
#   D2 stale text read-back on a SOURCE-parsed element: after
#      src.textContent = 'NEW', src.textContent returns 'NEW' but
#      src.childNodes[0].nodeValue and src.innerHTML still return the ORIGINAL
#      source text. Same story for classList.add(): className shows 'c1 c2',
#      getAttribute('class') still says 'c1'. Created nodes are fine; the
#      source-anchored lazy-text/attribute path is what is stale. This makes
#      every "handler wrote into a static output div" fixture fail on a
#      read-back, not on a dispatch.
#   D3 insertBefore(documentFragment, ref) inserts NOTHING; the fragment's
#      children are lost (host.childNodes stays 1, the ids go MISSING).
#   D4 node.parentNode still points at the old parent after removeChild().
#   D5 checkbox.click() performs no activation behaviour: .checked does not flip
#      and no change event fires. Radio-group exclusivity likewise never runs.
#   D6 select.value = 'c' moves .value but not .selectedIndex.
#   D7 in two fixtures the <script> element's own source text also shows up as a
#      TEXT NODE sibling of the script in body.
# None of these are visible to a pixel diff, and none of them are the bug the
# brief predicted.
#
# PROVENANCE — WHY EVERY RUN PRINTS A HEADER  (2026-08-04)
# =========================================================
# This harness was briefed as NON-DETERMINISTIC: "the same commit measured
# pass=2 in a worktree and pass=0 in a fresh main checkout". That is FALSE, and
# the real explanation is worse than a flaky gate.
#
# Measured directly: 15 fixtures x 5 repetitions of EACH engine (75 hambrowse
# runs, 75 chromium runs) produced ONE distinct output per fixture per engine —
# zero variance on either side. Three consecutive whole-gate runs in the same
# worktree gave byte-identical logs and pass=0 fail=15, the same as a clean
# checkout. Neither engine, nor the injected driver, nor the tmpdir, nor node
# ordering varies.
#
# What actually happened: the pass=2 was measured in a worktree that was sitting
# on the harness commit with an UNCOMMITTED 21-line engine patch (a NamedNodeMap
# fix for created elements in lib/web/dom/canvas.ad) that was never committed.
# Restoring exactly that patch onto a clean tree here reproduces pass=2 fail=13
# with the SAME two fixtures (01_create_click, 11_counter_chain). Same commit,
# different WORKING TREE. `git rev-parse HEAD` was a true statement about the
# repository and a false statement about the binary under test.
#
# So the fix is not to the measurement, it is to the REPORT. Every run now
# prints the HEAD sha, a LOUD dirty-tree warning naming the modified engine
# inputs, the content fingerprint that actually keys the compiled binary, and
# the chromium version. A pass/fail count from this gate is only quotable
# together with that header. `HAMNIX_LIVEDOM_REQUIRE_CLEAN=1` refuses to run at
# all on a dirty tree, which is what a floor-banking run should use.
#
# Chromium also now gets a PRIVATE --user-data-dir. Sharing the default profile
# with the ~5 sibling gates that also drive headless chromium on this host is a
# real (if not-yet-observed-here) way for one to exit instantly as a client of
# another and log nothing, which this gate would have reported as an engine
# failure.
#
# USAGE
#   bash scripts/test_livedom_functional_host.sh            # all fixtures
#   bash scripts/test_livedom_functional_host.sh create     # name filter
#   KEEP=1 bash scripts/...                                 # keep the workdir
#   HAMNIX_LIVEDOM_REQUIRE_CLEAN=1 bash scripts/...         # refuse a dirty tree
#
# EXIT STATUS is a FLOOR, not perfection: tests/fixtures/livedom/BASELINE lists
# the fixtures that were byte-identical to chromium when the floor was banked.
# A fixture in BASELINE that stops matching is a REGRESSION and exits 1; a
# fixture that starts matching is printed as NEW PASS — bank it by adding its
# name to BASELINE. STRICT=1 demands all 15.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/hambrowse_host"
FIXDIR="tests/fixtures/livedom"
FILTER="${1:-}"
mkdir -p "$OUT"

CHROMIUM="$(command -v chromium || command -v chromium-browser || command -v google-chrome || true)"
if [ -z "$CHROMIUM" ]; then
    # The oracle IS chromium; without it this gate asserts nothing, and a fake
    # "expected" table baked from memory is exactly the trap this lane exists to
    # avoid. Skip loudly rather than lie.
    #
    # 125, NOT 0. A run with no oracle observed NOTHING; exit 0 is the word for
    # "the assertion was observed to hold" and this run cannot say that. See
    # scripts/_verdict.sh — 125 is INCONCLUSIVE, which scripts/ci_run_gate.sh
    # already turns into a non-failing ::warning:: rather than a silent green.
    echo "[livedom] INCONCLUSIVE: no chromium on PATH — this harness has no oracle without it"
    exit 125
fi

# ---------------------------------------------------------------------------
# PROVENANCE HEADER. A pass/fail count from this gate means nothing without it —
# see the PROVENANCE section above for the run that proved why.
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_adder_bin.sh"

# The engine inputs whose content decides what this gate measures. A change
# ANYWHERE else in the tree cannot move a livedom number.
LD_INPUTS="lib/web user/hambrowse_host.ad adder/compiler compiler tests/fixtures/livedom scripts/test_livedom_functional_host.sh"
LD_HEAD="$(git rev-parse --short HEAD 2>/dev/null || echo '?')"
# shellcheck disable=SC2086
LD_DIRTY="$(git status --porcelain -- $LD_INPUTS 2>/dev/null | sed 's/^/    /')"
LD_FP="$(hamnix_tree_fingerprint)"
echo "[livedom] ============ PROVENANCE ============"
echo "[livedom] HEAD          $LD_HEAD  ($(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?'))"
echo "[livedom] tree fp       ${LD_FP:0:16}   (this, not HEAD, keys the compiled binary)"
echo "[livedom] chromium      $("$CHROMIUM" --version 2>/dev/null | tr -d '\n')"
if [ -n "$LD_DIRTY" ]; then
    echo "[livedom] WORKING TREE  *** DIRTY *** — the numbers below are NOT a"
    echo "[livedom]               property of $LD_HEAD. Uncommitted engine inputs:"
    echo "$LD_DIRTY" | sed 's/^/[livedom] /'
    if [ "${HAMNIX_LIVEDOM_REQUIRE_CLEAN:-0}" = "1" ]; then
        echo "[livedom] HAMNIX_LIVEDOM_REQUIRE_CLEAN=1: refusing to measure a dirty tree"
        exit 1
    fi
else
    echo "[livedom] WORKING TREE  clean — these numbers ARE a property of $LD_HEAD"
fi
echo "[livedom] ===================================="

echo "[livedom] compiling host engine (x86_64-linux) ..."
if ! adder_bin x86_64-linux user/hambrowse_host.ad "$BIN" 2>"$OUT/livedom_compile.log"; then
    echo "[livedom] FAIL: host engine did not compile"; cat "$OUT/livedom_compile.log"; exit 1
fi

WORK="$(mktemp -d)"
if [ "${KEEP:-0}" = "1" ]; then
    echo "[livedom] workdir $WORK (KEEP=1)"
else
    trap 'rm -rf "$WORK"' EXIT
fi

# ---------------------------------------------------------------------------
# The driver. Injected byte-identically into both engines.
# ---------------------------------------------------------------------------
cat > "$WORK/driver.html" <<'DRIVER'
<script id="__ldh">
(function(){
  var LINES = 0;
  function say(s){ LINES++; console.log("LD " + s); }
  function txt(s){
    s = String(s).replace(/[\s ]+/g, " ");          /* N1 collapse */
    if (s.length > 100) s = s.slice(0, 100) + "…";  /* N2 truncate */
    return s;
  }
  function attrs(el){
    var out = [], i, a = el.attributes;
    if (a) for (i = 0; i < a.length; i++) out.push(a[i].name + "=" + a[i].value);
    out.sort();                                          /* N3 sort */
    return out.join(" ");
  }
  /* Live state that has NO attribute mirror. A form control whose .value the
     page changed still serialises with its ORIGINAL value= attribute in every
     browser, so an attribute-only dump is blind to the whole form lane. */
  function live(el){
    var t = el.tagName.toLowerCase(), s = "";
    if (t === "input" || t === "textarea") {
      s += " #value=" + txt(el.value === undefined ? "" : el.value);
      s += " #checked=" + (el.checked ? 1 : 0);
    } else if (t === "select") {
      s += " #value=" + txt(el.value === undefined ? "" : el.value);
      s += " #sel=" + el.selectedIndex;
    }
    return s;
  }
  function walk(n, d){
    var t = n.nodeType, i, c;
    if (t === 1) {
      var tag = n.tagName.toLowerCase();                 /* N6 lowercase */
      if (n.id === "__ldh") return;                      /* N5 self */
      say(d + " E " + tag + " [" + attrs(n) + "]" + live(n));
      if (tag === "script" || tag === "style") return;   /* N4 opaque bodies */
      c = n.childNodes;
      for (i = 0; i < c.length; i++) walk(c[i], d + 1);
      return;
    }
    if (t === 3) {
      var s = txt(n.nodeValue);
      if (s.replace(/ /g, "") === "") return;            /* N1 ws-only */
      say(d + " T " + s);
      return;
    }
    if (t === 8) { say(d + " C " + txt(n.nodeValue)); return; }
    /* other node types (doctype=10, N7) are not serialised */
  }
  function dump(){
    try {
      walk(document.documentElement, 0);
      say("#END nodes=" + LINES);
    } catch (e) { say("#THREW " + e); }
  }
  function act(){
    try { if (typeof window.__act === "function") window.__act(); }
    catch (e) { say("#ACT-THREW " + e); }
  }
  /* macrotask for the page's own load script -> act -> drain -> dump */
  setTimeout(function(){
    act();
    setTimeout(function(){ setTimeout(function(){ setTimeout(dump, 50); }, 0); }, 0);
  }, 0);
})();
</script>
DRIVER

hb_dump() {   # <prepared page> -> canonical lines on stdout
    timeout 300 "$BIN" "$1" 880 2>&1 \
        | sed -n 's/^JSLOG LD //p'
}
ch_dump() {   # <prepared page> -> canonical lines on stdout
    # Greedy \(.*\) so a text node that itself contains '", source: ' cannot
    # truncate the line.
    # --user-data-dir is PRIVATE: sharing the default profile with a sibling
    # gate's chromium makes one instance exit immediately as a client of the
    # other, logging nothing — which this gate would misreport as an engine bug.
    timeout 120 "$CHROMIUM" --headless --no-sandbox --disable-gpu \
        --user-data-dir="$WORK/chromeprofile" \
        --virtual-time-budget=8000 --enable-logging=stderr \
        --dump-dom "file://$1" 2>&1 >/dev/null \
        | sed -n 's/^.*:CONSOLE[^]]*\] "LD \(.*\)", source: .*$/\1/p' \
        | tr -d '\r'
}

BASELINE="$FIXDIR/BASELINE"
KNOWNFAIL="$FIXDIR/KNOWNFAIL"
banked() {   # is $1 in the banked-pass list?
    [ -f "$BASELINE" ] || return 1
    grep -qx "$1" "$BASELINE"
}
declared_fail() {   # is $1 declared, in the tree, as a known divergence?
    [ -f "$KNOWNFAIL" ] || return 1
    grep -qx "$1" "$KNOWNFAIL"
}

pass=0; fail=0; FAILED=""; REGRESSED=""; NEWPASS=""; UNDECLARED=""; FIXED=""
for fx in "$FIXDIR"/*.html; do
    [ -e "$fx" ] || { echo "[livedom] FAIL: no fixtures in $FIXDIR"; exit 1; }
    name="$(basename "$fx" .html)"
    [ -n "$FILTER" ] && case "$name" in *"$FILTER"*) ;; *) continue ;; esac

    page="$WORK/$name.html"
    cat "$fx" "$WORK/driver.html" > "$page"
    abs="$(readlink -f "$page")"

    hb_dump "$abs" > "$WORK/$name.hb"
    ch_dump "$abs" > "$WORK/$name.ch"

    why=""
    if [ ! -s "$WORK/$name.ch" ]; then
        why="ORACLE PRODUCED NOTHING (chromium logged no LD lines)"
    elif [ ! -s "$WORK/$name.hb" ]; then
        why="hambrowse produced no LD lines (engine died or JSERR)"
    elif ! diff -q "$WORK/$name.hb" "$WORK/$name.ch" >/dev/null; then
        why="live DOM differs from chromium"
    fi

    if [ -z "$why" ]; then
        echo "[livedom] PASS $name ($(wc -l < "$WORK/$name.ch" | tr -d ' ') nodes, live DOM identical to chromium)"
        pass=$((pass+1))
        if ! banked "$name"; then
            NEWPASS="$NEWPASS $name"
            declared_fail "$name" && FIXED="$FIXED $name"
        fi
    else
        echo "[livedom] FAIL $name — $why"
        [ -s "$WORK/$name.ch" ] && [ -s "$WORK/$name.hb" ] && \
            diff -u "$WORK/$name.ch" "$WORK/$name.hb" \
                | sed -e '1,2d' -e 's/^/[livedom]     /' | head -24
        fail=$((fail+1)); FAILED="$FAILED $name"
        if banked "$name"; then
            REGRESSED="$REGRESSED $name"
        elif ! declared_fail "$name"; then
            UNDECLARED="$UNDECLARED $name"
        fi
    fi
done

echo "[livedom] ---------------------------------------------"
echo "[livedom] RESULT pass=$pass fail=$fail  @ $LD_HEAD${LD_DIRTY:+ (DIRTY TREE — not a property of this commit)}"
[ -n "$FAILED" ] && echo "[livedom] failing:$FAILED"
# ---------------------------------------------------------------------------
# THE VERDICT.  Until 2026-08-18 everything below the RESULT line could print
# `fail=1` and then `exit 0` — the gate reported its own red and returned the
# byte CI reads as "the assertion was observed to hold". That is the shape
# scripts/test_gate_softgreen.sh exists to ban, and it is worse than an
# unregistered gate, because CI believes it.
#
# The exit status now follows the result. Note what "the result" is: this gate
# is a RATCHET, not a demand for perfection, so the thing that must be true is
# not `fail == 0` but `every fixture's outcome is the one the tree DECLARES`.
# Two declarations, both files in the tree, both readable by the next person:
#
#   BASELINE   fixtures that MUST match chromium.   Failing one = REGRESSION.
#   KNOWNFAIL  fixtures that are KNOWN to diverge, each with the reason written
#              beside it. A divergence here is reported LOUDLY every run and is
#              not a failure of the gate — but it is DECLARED, so it cannot
#              grow silently and it cannot be added without saying why.
#
# Anything else is a failure OF THE GATE, and each of the four has bitten some
# harness in this tree before:
#   * a fixture failing that is in NEITHER list — a new fixture landing red
#     while the gate stays green, which is how coverage arrives already broken;
#   * a fixture in KNOWNFAIL that now PASSES — a win the floor never recorded,
#     which is how a fix silently rots back out;
#   * a fixture passing that is in neither list — same rot, one step earlier;
#   * ZERO fixtures measured — an instrument that produced an empty result is
#     not evidence, and `pass=0 fail=0` must never read as green.
# ---------------------------------------------------------------------------
LD_RC=0

if [ "$((pass + fail))" -eq 0 ]; then
    echo "[livedom] FAIL: ZERO fixtures were measured — this run observed nothing."
    echo "[livedom]   An empty result is not a pass. (filter='$FILTER')"
    LD_RC=1
fi
if [ -n "$REGRESSED" ]; then
    echo "[livedom] FAIL: REGRESSION — these were banked as matching chromium:$REGRESSED"
    LD_RC=1
fi
if [ -n "$UNDECLARED" ]; then
    echo "[livedom] FAIL: UNDECLARED DIVERGENCE — these fixtures fail and appear in"
    echo "[livedom]   NEITHER $BASELINE nor $KNOWNFAIL:$UNDECLARED"
    echo "[livedom]   Fix the engine, or declare it in $KNOWNFAIL with the reason."
    LD_RC=1
fi
if [ -n "$FIXED" ]; then
    echo "[livedom] FAIL: a fixture declared in $KNOWNFAIL now MATCHES chromium:$FIXED"
    echo "[livedom]   That is good news the floor has not recorded. Move the name(s)"
    echo "[livedom]   from $KNOWNFAIL to $BASELINE so the win cannot rot back out."
    LD_RC=1
fi
if [ -n "$NEWPASS" ] && [ -z "$FIXED" ]; then
    echo "[livedom] FAIL: NEW PASS not banked:$NEWPASS"
    echo "[livedom]   bank it: add the name(s) to $BASELINE"
    LD_RC=1
fi
if [ "${STRICT:-0}" = "1" ] && [ "$fail" -ne 0 ]; then
    echo "[livedom] FAIL: STRICT=1 — $fail fixture(s) still diverge"
    LD_RC=1
fi

# `grep -c` PRINTS 0 and EXITS 1 on no match, so the old `|| echo 0` fallback
# appended a SECOND zero and this line read "banked passes: 0\n0)".
LD_BANKED=0
[ -f "$BASELINE" ] && LD_BANKED="$(grep -cvE '^[[:space:]]*(#|$)' "$BASELINE" 2>/dev/null)"
LD_KNOWN=0
[ -f "$KNOWNFAIL" ] && LD_KNOWN="$(grep -cvE '^[[:space:]]*(#|$)' "$KNOWNFAIL" 2>/dev/null)"

if [ "$LD_RC" -ne 0 ]; then
    echo "[livedom] VERDICT: FAIL (exit 1) @ $LD_HEAD ${LD_DIRTY:+[DIRTY TREE]}"
    exit 1
fi
# Say the known divergences OUT LOUD on a green run. A green that quietly
# carries a red inside it is how `fail=1` went unread for two weeks.
if [ "$fail" -ne 0 ]; then
    echo "[livedom] carrying $fail DECLARED divergence(s) — every one of them is a"
    echo "[livedom]   real engine gap, listed with its reason in $KNOWNFAIL:$FAILED"
fi
echo "[livedom] VERDICT: PASS (floor held: $LD_BANKED banked, $LD_KNOWN declared-failing," \
     "$((pass + fail)) measured) @ $LD_HEAD ${LD_DIRTY:+[DIRTY TREE]}"
exit 0
