#!/usr/bin/env bash
# scripts/test_package_source_refusal.sh — the packager must refuse to ship
# a package that promises a file it does not carry.
#
# Two packages shipped broken out of scripts/build_packages.py before this
# gate existed, and both were visible in the build log as a single line that
# read like housekeeping:
#
#   * hamnix-ed. COREUTILS_BINS named `ed`; user/ed.ad has never existed;
#     the package was published with an EMPTY files/ directory and an entry
#     in index.json. MEASURED: `built hamnix-ed-<v>.tar.gz: 0 files`.
#   * hamnix-desktop-core. hampanelscene and hamappmenu do not link in the
#     native lane, so the desktop shipped WITHOUT A PANEL AND WITHOUT AN
#     APPLICATIONS MENU. MEASURED: `skipped 2 missing source(s)`, then
#     `built ...: 17 files` — 19 are named.
#
# Two assertions, both cheap and neither needing a build:
#
#   1. STATIC. Every build/user/<stem>.elf any package names has a
#      user/<stem>.ad in the tree. This is the `ed` shape: a package name
#      with nothing behind it, which no build could ever satisfy. Checked
#      WITHOUT looking at build/, so a stale ELF from an older build cannot
#      make a deleted source look present.
#   2. THE REFUSAL FIRES. Inject a spec naming a file that is not there and
#      assert _preflight_sources() raises. A refusal nobody has watched
#      reject something is not a refusal.
#
# No QEMU, no kernel, no userland build.

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

python3 - <<'PY'
import importlib.util, sys
from pathlib import Path

ROOT = Path(".").resolve()
spec = importlib.util.spec_from_file_location(
    "bp", ROOT / "scripts" / "build_packages.py")
bp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bp)

fail = 0

# (1) every packaged build/user/<stem>.elf has a user/<stem>.ad
sourceless = []
named = 0
for s in bp.PACKAGE_SPECS:
    for src, _rel in s["files_fn"]():
        if src.parent == bp.USER_DIR and src.suffix == ".elf":
            named += 1
            if not (ROOT / "user" / (src.stem + ".ad")).is_file():
                sourceless.append((s["name"], src.stem))
if sourceless:
    fail = 1
    print("[pkg-src] FAIL (1/2) %d packaged binary/ies have no source:"
          % len(sourceless))
    for pkg, stem in sourceless:
        print("            %s names user/%s.ad — not in the tree" % (pkg, stem))
    print("          Delete the name (and whatever documents or invokes it),"
          " or write the source.")
else:
    print("[pkg-src] ok (1/2) %d packaged binaries, every one has a "
          "user/<stem>.ad" % named)

# (2) the refusal actually refuses
ghost = ROOT / "build" / "user" / "no-such-binary-test-fixture.elf"
bp.PACKAGE_SPECS.append({
    "name": "hamnix-test-ghost",
    "files_fn": lambda: [(ghost, "bin/ghost")],
    "depends": [],
    "description": "gate fixture — never built, never published",
    "target": "#hamnix-system",
})
try:
    bp._preflight_sources()
except SystemExit as e:
    msg = str(e)
    if "hamnix-test-ghost" in msg and "REFUSING TO BUILD" in msg:
        print("[pkg-src] ok (2/2) _preflight_sources() refused an injected "
              "missing source")
    else:
        fail = 1
        print("[pkg-src] FAIL (2/2) refused, but not about the injected "
              "package:\n%s" % msg)
else:
    fail = 1
    print("[pkg-src] FAIL (2/2) _preflight_sources() ACCEPTED a package "
          "naming %s — the refusal does not fire, so every package in this "
          "channel may be short a file." % ghost)

sys.exit(fail)
PY

echo "[pkg-src] PASS"
