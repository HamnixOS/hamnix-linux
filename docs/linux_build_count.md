# What "N of 367 build" means, and the eight that did not

`HANDOFF.md` §0 has carried a build count for the LLVM lane since the port
started. Its most recent form was:

> **359 of 367** `user/*.ad` build through the LLVM lane (re-measured; the eight
> failures are unchanged, `user/` gained `arecord`).

and, immediately after it, a grouping of the eight by cause:

> four are `*_host.ad` TEST HARNESSES that import kernel source
> (`sys.src.port9.port.devsnarf`, the clipboard device) which is not in this
> repository; three are LIBRARIES with no `main` (`http9`, `net9`,
> `httpdconf`), where the sweep's "no @main" is the correct answer; one
> genuinely bails the backend's SSA subset (`hambrowse_tabs`).

That grouping was made by reading, not by running. This document is the
re-measurement, what it changed, and what is left.

---

## 1. The headline was measuring the wrong set

367 is the number of files in `user/`. It is not the number of
**applications** in `user/`, because four of those files are library modules
that other programs import:

| file | imported by |
|--|--|
| `user/http9.ad` | `hpm`, `curl`, `wget` — the shared HTTP/1.0 client |
| `user/net9.ad` | the `/net` dial helpers |
| `user/httpdconf.ad` | `httpd` — the `/etc/httpd.conf` parser |
| `user/hambrowse_tabs.ad` | `hambrowse`, `hambrowse_gfx_window` — the tab-session model |

A library has no `main`, cannot become an ELF, and is not a *failure* to
produce one. Counting them in the denominator of "applications that build"
makes the headline understate the thing it is trying to state. This tree has
been bitten by a wrong denominator before — `scripts/hamlinux_runsweep.sh`
carries the scar in a comment — and this is the same mistake one layer down.

The discriminator is not a judgement call. Exactly four files in `user/` have
no top-level `def main`, and they are exactly those four:

```
$ grep -L '^def main' user/*.ad
user/hambrowse_tabs.ad  user/http9.ad  user/httpdconf.ad  user/net9.ad
```

## 2. `hambrowse_tabs` never bailed anything

The interesting claim was that one program "genuinely bails the backend's SSA
subset". It does not, and neither does any of the other three. Building it
prints its own contradiction:

```
$ scripts/hamlinux_build.sh user/hambrowse_tabs.ad /tmp/x.elf
; ADDER_STAT funcs=28 emitted=28 bailed=0
[hamlinux] ERROR: no @main emitted (body bailed the SSA subset)
```

**28 functions, 28 emitted, 0 bailed** — and then a message saying a body
bailed. `http9` says `funcs=74 emitted=74 bailed=0`, `net9` `13/13/0`,
`httpdconf` `12/12/0`. The backend refused nothing. There is no SSA gap here
to report to the `adder` project, and nothing in `user/hambrowse_tabs.ad`
needed rewriting into a supported subset.

The message was wrong because the test behind it was wrong. `hamlinux_build.sh`
looked for `define i64 @main(` in the emitted IR and, on not finding it,
asserted a cause it had not checked. Two opposite situations produce the same
missing `@main`:

* a file that HAS a `def main` whose body the backend could not lower — a real
  backend coverage failure; and
* a file that has no `def main` at all — a library, which was never going to
  emit one.

The two are now told apart **by the source**, which is where the answer was all
along, and they get different exit codes: `11` keeps its old meaning (declared
a `main`, emitted none: a real bail) and `13` is new (no `def main`: a library
module, not an application). Both are still non-zero, because the script's job
is to produce a linked ELF and it did not — but a sweep can now count them
apart.

`scripts/hamlinux_sweep.sh` computes and **prints** the headline with its own
definition next to it, the way `scripts/hamlinux_runsweep.sh` already did:

```
-- headline --
files in user/           367
library modules            4   (rc 13: no def main; not applications)
applications             363   (367 files - 4 libraries)
built                    363   (rc 0)
BUILD SCORE   363 / 363 applications
```

Nothing is hand-derived into a commit message. Re-run the sweep and it
re-derives itself.

## 3. The four `*_host.ad` harnesses now build, and they run

`snarf_primary_host`, `htb_evt_paste_host`, `htermsel_evt_host` and
`primary_paste_chain_host` are host unit tests for the X11-style PRIMARY
selection. Each imported

```
from sys.src.port9.port.devsnarf import devsnarf_write, devsnarf_read, ...
```

— a path that exists in Hamnix and not in this repository. That import failed
in the quietest way available: the driver resolves an import to a file and, on
not finding one, **silently skips it**, so `devsnarf_write` survived as an
undefined symbol and the failure surfaced 30 seconds later as four `undefined
reference` lines from `ld`. (Worth knowing on its own: a mistyped import in
this compiler is a link error, never an import error.)

The four functions behind that import are pure — two byte arrays and an
offset-addressed read/write surface, with no kernel dependency of any kind. So
the honest answer was neither "exclude the harnesses" nor "leave them broken"
but to **port the module**, which is what this repository is for.
`lib/devsnarf.ad` is that port, and the four harnesses now import
`from lib.devsnarf import ...`.

They are not link-and-do-nothing wins. Run, they assert **64 things** about
this tree's own `lib/htermsel.ad` and `lib/hamtextbox.ad`:

| harness | result |
|--|--|
| `snarf_primary_host` | `SUMMARY passes=16 fails=0` / `RESULT PASS` |
| `htb_evt_paste_host` | `SUMMARY passes=17 fails=0` / `RESULT PASS` |
| `htermsel_evt_host` | 22 PASS lines, `done`, exit 0 |
| `primary_paste_chain_host` | `SUMMARY passes=9 fails=0` / `RESULT PASS` |

They cover the properties the two-buffer model exists for: a highlight sets
PRIMARY and leaves the CLIPBOARD alone, Ctrl+C sets the CLIPBOARD and does not
clobber PRIMARY, a middle-click paste reads PRIMARY back, a chunked write
accumulates, an offset-zero write still replaces, and the terminal and the
editor agree on which leaf is which.

And they are not only the LLVM lane. Each harness has a wrapper script that
drives it through the **native** lane, and all four of those are named in
`scripts/ci_battery_manifest.txt` — so four CI battery entries have been dead
in this tree, failing at compile with `unknown identifier
'devsnarf_primary_write'`, and are alive again:

| script | before (pristine `HEAD`) | after |
|--|--|--|
| `scripts/test_snarf_primary_host.sh` | did not compile | `PASS: #315 PRIMARY-selection independent-of-CLIPBOARD host unit test` |
| `scripts/test_htb_evt_paste_host.sh` | did not compile | `PASS: #315 PRIMARY-selection LIVE-EVENT-PATH host gate` |
| `scripts/test_htermsel_evt_host.sh` | `Error: x86: unknown identifier 'devsnarf_primary_write'` | `[htsel-evt] RESULT: PASS` |
| `scripts/test_primary_paste_chain_host.sh` | did not compile | `PASS: cross-surface PRIMARY paste chain host gate` |

`scripts/test_snarf_primary_host.sh` additionally compiles `hambrowse`
natively, so the host proof cannot drift from the shipped on-device path; that
compile passes too.

## 4. What that uncovered: there is no clipboard on this line

`lib/devsnarf.ad` is the semantics half of a clipboard device. The other half —
a **server** for `/dev/snarf` and `/dev/snarf.primary` — does not exist in this
repository, and nothing creates those two paths at boot. `grep -rn snarf etc/`
returns nothing.

Meanwhile `lib/hamtextbox.ad` and `lib/htermsel.ad` — the real, shipped code
that the editor, Notes, the browser URL bar and the grid terminal all go
through — reach the clipboard **by path**, and `user/hamtermscene.ad` and
`user/haminput.ad` call them. So on a hamnix-linux boot today, `htsel_clip_put`
opens `/dev/snarf`, gets `-ENOENT`, and returns 0. Copy and paste between
programs does not work, and says nothing when it doesn't.

Measured rather than argued, against the real `user/linux-syscalls.c`, in a
private mount namespace with a tmpfs over `/dev` (never the host's):

```
A. /dev/snarf does not exist (a hamnix-linux boot as it stands):
  sys_open_write("/dev/snarf") = -2  errno=2 (No such file or directory)
  sys_open("/dev/snarf") = -2
  access("/dev/snarf") = -1        <- and nothing was created

B. after something creates the two paths as ordinary files:
  sys_open_write("/dev/snarf") = 3 ; sys_write -> 14
  sys_open("/dev/snarf")  -> 14 "CLIPBOARD-TEXT"; next read -> 0
  sys_open("/dev/snarf.primary") -> 12 "PRIMARY-TEXT"; next read -> 0

C. REPLACE-on-write with a SHORTER payload, and independence:
  put "short" -> get "short"        <- 14 bytes did not survive under 5
  /dev/snarf.primary still "PRIMARY-TEXT"
```

The `-ENOENT` in (A) is deliberate and correct: `sys_open_write` drops
`O_CREAT` under `/dev/` precisely so that a client writing to an unserved
device fails instead of silently creating an ordinary file — the fix that
stopped `user/playtone.ad` reporting "played 1000 Hz square wave, 24000 frames"
into a regular file called `/dev/audio`.

And (B)/(C) are the useful part: **two ordinary files give exactly the
semantics the toolkit needs.** `sys_open_write` is `O_WRONLY|O_TRUNC`, so a
write REPLACES — including shrinking, which is the case a naive
overwrite gets wrong. `sys_read` is offset-addressed and hits EOF. The two
files are independent by construction, and being real files they persist
across processes, which is the whole point of a clipboard.

So the cheapest correct fix is to create `/dev/snarf` and `/dev/snarf.primary`
at boot, in the rc scripts, and copy/paste starts working with no new server
and no change to any client. A file server would buy the 64 KiB cap and the
kernel-RAM-only lifetime that `lib/devsnarf.ad` documents; the two files buy
the behaviour. **This is left undone deliberately** — the rc scripts were not
this pass's to change — and it is recorded here as the next step, with the
measurement that says it will work.

## 4a. One thing for the `adder` project: an unresolvable import is silent

Not an SSA gap — there is no SSA gap — but a real defect of the same family,
and it is what let four broken imports sit in this tree for as long as they
did. `adder/compiler/fused_driver_host_main.ad::drv_process_file` scans a
file's top-level `from <mod> import ...` lines, resolves each to a path, and
**recurses only for the ones that resolve**. A module name that resolves to no
file on disk is simply not recursed into, and nothing is said. The imported
names then behave as if they had been declared `extern`, so:

* compilation SUCCEEDS, with `funcs=N emitted=N bailed=0`;
* the emitted IR contains `call`s to symbols nothing defines;
* the failure appears much later, from `ld`, as `undefined reference to
  'devsnarf_write'` — which points at the linker, not at the import line that
  is actually wrong.

`user/snarf_primary_host.ad` said `from sys.src.port9.port.devsnarf import ...`
and got a clean compile and four undefined symbols. A plain typo in a module
name gets exactly the same treatment.

**The two lanes disagree about this, which is the sharpest form of the report.**
The native x86 lane catches it at compile time and names it:

```
$ bash scripts/test_htermsel_evt_host.sh     # on the pristine tree
[htsel-evt] FAIL: host harness did not compile
Error: x86: unknown identifier 'devsnarf_primary_write'
```

The LLVM lane, on the same source, prints `funcs=165 emitted=165 bailed=0` and
emits calls to it. So one backend already has the check; the fused driver's
import walk does not.

The silence is deliberate, and that is the part worth being careful about.
`drv_resolve_module`'s own comment says it returns 0 "if no file exists
(external/runtime import — ignored)": a module is *allowed* to import names
that the link supplies rather than a `.ad` file, and making an unresolved
import fatal would break that on purpose. So the ask is not "fail" — it is
"**say which one**":

* emit a diagnostic naming the unresolved module and the file that imported it,
  on stderr, once per module. That alone would have turned this from a wall of
  `ld` output into one line pointing at line 27 of the harness; and
* optionally a strict mode (`--imports=strict`) that promotes it to an error,
  for trees like this one where every import is expected to resolve.

Nothing else in the driver needs to change — the resolution attempt already
happens at `drv_process_file`'s recursion loop and already knows it failed; the
`else` branch is simply empty. (Filed here rather than as a patch: `adder/` is
a separate project and this pass was told not to touch it.)

## 5. Two harness bugs found on the way

* **`scripts/hamlinux_runsweep.sh` scored libraries `BUILD_FAIL`.**
  `tests/linux/runsweep_recipes.tsv` has classified all four as class `lib`
  with the skip reason "library: no main, nothing to run" for as long as they
  have been in it — and not one of them ever reached that line, because the
  build-result test ran first. The `lib` test now runs before it, and only for
  rc 13 and only for class `lib`, so an *application* that loses its `main` is
  still a failure. The headline's `runnable` denominator subtracted
  `NOT_SMOKE_TESTABLE` and `BUILD_FAIL` alike, so the SCORE was never wrong —
  but the verdict table said four libraries had failed to build, and
  `HANDOFF.md` believed it.

* **The run sweep staged no libc when run on a named subset.** It picked the
  binary to probe for shared libraries with `ls -1 "$BASE"/bin/* | head -1`.
  A whole-tree sweep survives that by luck — `ac` sorts first and is dynamic,
  so old and new pick the same file and **the whole-tree numbers are
  unaffected** — but a sweep of a named subset does not, because `host_ac` is
  staged unconditionally and is **statically linked**, so `ldd` printed nothing,
  `readelf` found no interpreter, no loader was staged, and every program in
  the run died with rc 127 which the harness recorded as **the program's**
  exit status. Four harnesses that pass 64 assertions were scored
  `EXIT_NONZERO` by the sweep's own staging. The probe now picks the first
  staged binary that actually has a `PT_INTERP`. Before and after, same eight
  applications:

  ```
  before:  RAN 0   EXIT_NONZERO 4   NOT_SMOKE_TESTABLE 4   SCORE 0 / 4
  after:   RAN 4                    NOT_SMOKE_TESTABLE 4   SCORE 4 / 4
  ```

## 6. The measurement

Both numbers below come from running `scripts/hamlinux_sweep.sh` over all 367
files, twice: once on a pristine export of the branch point, once on this
tree. Neither is derived by hand.

**Before** — a `git archive` of the branch point, with `scripts/hamlinux_sweep.sh`
exactly as it was, verbatim output:

```
=== sweep complete: 367 apps ===
rc=0	359
rc=11	4
rc=12	4
```

`rc=11` (reported as an SSA bail, actually the four library modules):
`hambrowse_tabs`, `http9`, `httpdconf`, `net9`.
`rc=12` (link, the four clipboard harnesses, all four on
`devsnarf_primary_read` / `devsnarf_primary_write`): `htb_evt_paste_host`,
`htermsel_evt_host`, `primary_paste_chain_host`, `snarf_primary_host`.

That reproduces `HANDOFF.md`'s "359 of 367" exactly, so the two runs are
measuring the same thing.

**After**, this tree, verbatim:

```
=== sweep complete: 367 files in user/ ===
rc=0	363
rc=13	4

-- headline --
files in user/           367
library modules            4   (rc 13: no def main; not applications)
applications             363   (367 files - 4 libraries)
built                    363   (rc 0)
BUILD SCORE   363 / 363 applications

-- everything that is not rc 0 --
hambrowse_tabs               rc=13  [hamlinux] NOT-AN-APPLICATION: user/hambrowse_tabs.ad has no 'def main' ...
http9                        rc=13  [hamlinux] NOT-AN-APPLICATION: user/http9.ad has no 'def main' ...
httpdconf                    rc=13  [hamlinux] NOT-AN-APPLICATION: user/httpdconf.ad has no 'def main' ...
net9                         rc=13  [hamlinux] NOT-AN-APPLICATION: user/net9.ad has no 'def main' ...
```

Four applications that did not build now do; four library modules moved out of
the failure bucket and out of the denominator. Every one of the 367 reports
`bailed=0`:

```
$ grep -h -oE 'bailed=[0-9]+' build/sweep-FINAL/*.err | sort | uniq -c
    367 bailed=0
```

## 7. The run sweep, whole tree, after the change

`scripts/hamlinux_runsweep.sh` over all 367, which is the check that the
classification holds where it is consumed:

```
-- headline --
healthy    265   (RAN + DREW_WINDOW + STAYS_UP + EXPECTED_FAIL)
runnable   329   (367 rows - 38 NOT_SMOKE_TESTABLE - 0 BUILD_FAIL)
SCORE     265 / 329
```

**`BUILD_FAIL 0`** — for the first time the verdict table and the build sweep
agree, and the eight in question land where they belong:

```
hambrowse_tabs             lib        NOT_SMOKE_TESTABLE
http9                      lib        NOT_SMOKE_TESTABLE
httpdconf                  lib        NOT_SMOKE_TESTABLE
net9                       lib        NOT_SMOKE_TESTABLE
htb_evt_paste_host         hosttest   RAN   rc 0
htermsel_evt_host          hosttest   RAN   rc 0
primary_paste_chain_host   hosttest   RAN   rc 0
snarf_primary_host         hosttest   RAN   rc 0
```

and the captured stdout is the assertions, not silence:
`build/rsfull/run/snarf_primary_host.out` ends `SUMMARY passes=16 fails=0` /
`RESULT PASS`.

The `265 / 329` is this pass's first whole-tree run-sweep number and has no
before-baseline in the same session to be compared against; it is recorded as
what the sweep says, not as a claim of movement. The 62 `EXIT_NONZERO` and 2
`TIMEOUT` rows are pre-existing and are somebody's next piece of work.

Nothing is left deliberately failing. The `rc=11` bucket — the one that means a
real backend coverage failure — is now **empty**, and it is empty because it
was always empty: no `user/*.ad` in this tree bails the SSA subset, and none
ever did. `ADDER_STAT` reports `bailed=0` for every one of the 367.
