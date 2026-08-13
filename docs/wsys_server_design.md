# `/dev/wsys` as a userland file server — the design

Costed in `docs/wsys_server_cost.md`; this is the shape. Nothing here is built
yet beyond the red gate that defines success.

## The answer on `WSYS_VERSION`, first, because it changes how this ships

**Yes, it needs a bump — and not because the segment layout changes.**

The layout need not change at all. The reason is enforcement. **The
window-system code is linked into every existing binary**, so a 1.0.22 client
will `mmap` the segment and write another window's row directly, exactly as it
does today. A server cannot mediate binaries that already exist and do not
know it is there. The version check is the *only* mechanism that makes a
pre-server client refuse rather than silently bypass the mediator — which
means the boundary is worth precisely as much as the bump is.

Consequences to plan for now:

- `WSYS_VERSION` 8 → 9, and the refuse-rather-than-wipe path in `shm_attach()`
  carries the user-visible behaviour of it. `installed_update_wsysver.sh`
  builds its own baseline and needs no network, so it is cheap and must be run.
- **This is a full-image update, not a partial one.** Every shipped binary
  links the client side. A mixed system is not a degraded boundary, it is no
  boundary — an old client keeps full shared-memory access.
- The bump is what makes the security claims true. Without it the server is a
  convention.

## What crosses, and what must never

| | today | served |
|---|---|---|
| pixels | per-window `memfd`, handed up | **unchanged — must not cross** |
| scene display list | shared write | request, ≤16 KiB, ~6/s |
| `ctl` / `wid/ctl` / `wid/wctl` | shared write | request, ~12/s per client |
| `windows`, `screen`, `pool` | shared read | request — **and now a policy** |
| event / pointer / keys rings | shared read | request or kept mapped read-only |

Pixels staying out is verified, not assumed: `wid/backbuffer` does not appear
once in 12 s of client traffic, and the bulk lives in per-window memfds created
by the owner. **That property is load-bearing** — it is why the whole boundary
costs ~0.12% of a core at idle instead of moving megabytes a frame.

## The protocol shape

Measurement inverted the obvious assumption and the protocol follows the
measurement, not the intuition: **strict request-reply is the expensive
pattern, not volume.** Per-op cost falls 6.30 µs (one at a time) → 3.14 (4) →
2.31 (16) → 2.37 (64), saturating near 2.3 µs.

1. **Every mutation that does not return data is fire-and-forget.** `geometry`,
   `title`, `z`, `commit`, most of `scene` — the client writes and does not
   wait. Errors arrive out of band on the client's own event ring, which it is
   already draining.
2. **Only genuinely interrogative operations block**: `newwindow` (needs the
   wid), `wctl` version negotiation, a `windows` read.
3. **Batch by construction.** A scene is already one write since the drag-load
   fix; keep that shape everywhere, because reopening `scene` starts a new
   frame and per-line writes were what made an empty window look like a full
   one for the entire life of that file.
4. `SOCK_SEQPACKET` on an abstract name derived from segment identity — the
   same naming the client-wake channel already uses, so there is one way to
   find the server.

## Enumeration — the property that cannot be expressed today

`tests/linux/wsys_enum_policy.sh` is RED on the current design and says so:

```
enumpol: FAIL a process owning NO window enumerated window 2 ("2 win2").
```

An ordinary `cat`, owning nothing, reads the full window list. Not a missing
check — a missing *mediator*: the reader's own linked-in code answers from
shared memory, so there is nowhere a policy could live. Served, enumeration
becomes a request the server answers, and it can return the caller's own
windows to an ordinary client and the full list only to a holder of the
taskbar capability. That is the first thing the boundary buys that no amount
of care in the current design could.

> **The taskbar-capability half of that paragraph turned out to be false, and
> stage 4 says why: nothing in `SO_PEERCRED` distinguishes the panel from any
> other DE application.** The rule actually landed is *the full list to the
> host owner and to any caller that owns a window*. See **What stage 4
> measured** below; this paragraph is left as written because the gate was
> written against it.

The same absence produced the same-uid pixel scrape and `win_alloc` racing two
clients onto one row. One mediator closes all three.

## Landing

Recommend **one design, landed in one version bump**, per the brief — a split
that outlives its stage is the hybrid under another name, and the hybrid is off
the table because idle mediation is now 0.12% of a core rather than 0.63%.

Order of work, each with its own gate, all offscreen:

1. Server loop in `wsysd` + client transport in `linux-wsys.c`, behind
   `HAMWSYS_SERVER=1` so both paths exist during development only.
2. Mutations first (`ctl`, `wid/ctl`, `wid/scene`) — where the privilege
   questions live.
3. Reads, including the enumeration policy that turns the red gate green.
   **Done — and it needed a second process; see stage 4 below.**
4. Remove the in-process path and bump `WSYS_VERSION`. **The bump is the last
   step, not the first**: until the old path is gone the bump would refuse
   clients for a boundary that is not yet enforced. **Still not done, and it
   is the whole of the enforcement: every gate's red arm above is a client
   mapping the segment past a live mediator.**

## What stage 1 measured, and the one place this plan was wrong

Stage 1 is built: `hamwsys_srv_{claim,listen,service}` in `user/linux-wsys.c`,
serviced from `wsysd`'s loop, dialled from `hamwsys_open`, all behind
`HAMWSYS_SERVER=1`. Gate: `tests/linux/wsys_srv_transport.sh`, seen red first
(2 failed), now **13 passed, 1 failed** — the one being the budget finding
below, left red on purpose.

Two things held, and two did not.

**Fire-and-forget held, and better than costed.** 1.18–1.99 µs per op on the
send side, under a dragging load, against the 2.3 µs the census saturates at.
The rule that mutations do not wait is now evidence rather than intuition.

**Pixels do not cross — verified, not assumed.** 12 s of a real dragging
client: 9899 control writes, **0 backbuffer writes**.

**THE 6.30 µs FIGURE DOES NOT APPLY TO THIS SERVER, and it is structural.**
`wsys_rtt_probe.c` measured a dedicated server thread whose only job was to
read the socket. This server is serviced from the compositor's frame loop, so
a blocking request waits for `wsysd` to come round — and when `wsysd` is
rasterizing, "come round" means *after this frame*. The tail is therefore the
compositor's frame cost, not the socket's:

| load | p50 | p90 | max |
|---|---|---|---|
| idle | 22–46 µs | 45–47 µs | 68–74 µs |
| light drag (300×200, 60 px span) | 27 µs | 47–71 µs | 65–598 µs |
| heavy drag (480×320, 300 px span, 8 text rows) | 32 µs | 789 µs | **851 µs** |

851 µs is nearly **three times the whole published 0.3 ms input-to-pixel
budget**, for one operation. The distribution is bimodal, not noisy: a request
either catches an idle loop (~27 µs) or waits out a frame (600–850 µs). The
median is safe and the tail is not, which is exactly the shape a median-only
measurement would have hidden — the gate prints all 33 samples.

This does not affect stage 2 — mutations do not wait. It is a hard constraint
on **stage 3**, where reads are routed:

- `newwindow` and `wctl` version negotiation happen once per window. They can
  afford 851 µs and nobody can perceive it.
- A taskbar re-reading `/dev/wsys/windows`, and the enumeration policy the red
  gate exists for, **cannot**. Routing that read through the frame loop would
  put up to a frame of stall on the one operation the whole boundary was built
  to mediate.

So stage 3 must service requests off the frame loop — a servicing thread, or
answering reads from a snapshot the loop publishes — and 851 µs is the number
it has to beat. That decision was not in this plan; the measurement put it
there.

**AND THE BUDGET HAS NO FIXED TERM IN IT, WHICH IS WHY ONE ARM IS RED.**
Measured CPU added to `wsysd`, three 40 s samples each, `/proc/<pid>/stat`:

> **THIS ARM IS NO LONGER RED, AND NOT BECAUSE THE NUMBER WAS MOVED TO FIT.**
> Stage 2 answered the question the red arm was holding open (see *Routing
> made the compositor cheaper* below), and the budget has since been re-derived
> in the shape the cost actually has — a fixed term plus a marginal one. See
> **The budget, re-derived** near the end of this document. The measurement in
> this table stands as taken.

| rate (delivered, verified) | measured | budget | |
|---|---|---|---|
| 192 ops/s | **0.27%** | 0.12% | **over** |
| 618 ops/s | 0.29% | 0.38% | within |
| 2050 ops/s | 0.47% | 1.27% | within |

Ten times the rate costs under twice the CPU. Decomposed over the three rates:

    marginal   1.076 µs of CPU per message
    fixed      0.25% of a core, independent of the rate

The marginal figure matches the 1.18 µs fire-and-forget cost measured
independently from the sending end. The load paces in 10 ms slices, so all
three arms wake the compositor the same 100 times a second: **the fixed term
is the wake**, and a wake is a whole `wsysd` loop iteration. The round-trip
number above is that same cost seen from the other end.

The budget in the table below is `ops/s × per-op`. It has no fixed term, so no
amount of making messages cheaper reaches it.

**This synthetic load over-attributes, and stage 2 is where that is settled.**
A `NOP` adds a wake to a `wsysd` that had no other reason to wake. A real
routed mutation *replaces* a shared-memory write that already pokes the
client-wake channel and already wakes `wsysd` — one wake, not two. Whether
mediation *adds* a wake or *moves* one is the difference between 0.22% and
almost nothing, and it cannot be answered before a real operation is routed.
The gate stays red on it rather than being widened to fit.

## What stage 2 measured — and the synthetic budget arm is now explained

Stage 2 routes `/dev/wsys/ctl` and `/dev/wsys/<wid>/ctl` writes as one
fire-and-forget message each, with `newwindow` blocking because it returns the
wid. Gate: `tests/linux/wsys_srv_mutate.sh`, **7 passed, 0 failed**.

**The mediation is `srv_as_caller()`, and nothing else.** A routed operation
runs with the client's `SO_PEERCRED` installed, so `hostowner()` and
`owns_wid()` answer about the caller. Without it wsysd — the host owner —
would grant every write and the boundary would be strictly *worse* than none,
silently, with every existing gate green.

**Routing a drag made the compositor faster, not slower.** Same real dragging
client, wsysd's CPU, three samples each:

| | samples | median |
|---|---|---|
| unrouted | 93.90 / 99.90 / 99.80 | **99.80%** of a core |
| routed | 75.50 / 52.90 / 53.30 | **53.30%** |

46.5% of a core cheaper — and **43% more frames painted** (139×200 against
97×200), which the gate asserts, because otherwise a compositor that quietly
stopped painting and a real saving are the same number. The unrouted arm was
saturated.

So stage 1's unattributable 0.27% at 192 synthetic ops/s **was the synthetic
NOP**: it added a wake to a compositor that had no other reason to wake. A
real routed mutation replaces a shared-memory write that already poked the
wake channel — and beyond that, messages queue and `srv_service` drains all
pending ones in a single iteration before `scan_windows`, where the unrouted
path woke the loop once per publish and rescanned each time. Mediation does
not merely move the wake; it coalesces by construction.

**THE CALLER-IDENTITY PROPERTY IS STILL UNPROVEN, and the gate says so.** The
first run reported `FAIL a stranger renamed window 2` — and that FAIL was
wrong. devwsys's rule is that the host owner may write any window; an
offscreen gate runs as one uid, so the "stranger" *is* the host owner and the
mediator was reproducing the in-process rule exactly. Proving the check uses
the caller needs a **second uid**, as `wsys_uidgate.sh` and `wsys_bypass.sh`
get with `unshare -U --map-users`. **That is the next piece of work.** What is
asserted at any uid is that a routed write for a window that does not exist is
refused, with the message first proven to have arrived.

## What stage 3a measured — the caller identity, proven, and what it costs

`tests/linux/wsys_srv_identity.sh`, **15 passed, 0 failed**. `unshare -U
--map-users` with three ids out of `/etc/subuid`, as `wsys_uidgate.sh` and
`wsys_bypass.sh` already do: wsysd runs as 1001 so **1001 is the host owner**,
the victim owns the window, the attacker is **1002**. `WSYS_VERSION` stays 8.

**The pair is the argument, not the refusal.** Same uid, same window, same
mutation, twice:

| | result |
|---|---|
| unrouted | uid 1002 renamed uid 1001's window. **It worked, and it is supposed to.** |
| routed | `wsrvmu: the mediator REFUSED it (refused 0 -> 1)`, title unchanged, message proven to have arrived first (`write 3 -> 4`) |

A gate that is green in every configuration is equally green against a server
that checks nothing. Red-unrouted / green-routed is the whole case for the
boundary's existence.

**And the red arm costs one assignment.** `hostowner()` reads
`srv_caller.uid` — a plain global, because a routed operation must be able to
install the caller it acts for. In wsysd that global comes from `SO_PEERCRED`;
in a *client* it is a variable in the attacker's own address space:

    the in-process check says hostowner=0 owns_wid=0 -- i.e. REFUSE
    after one assignment to the identity the check reads, the SAME check says
    hostowner=1 owns_wid=0 -- i.e. ALLOW
    the unrouted write LANDED

An unmediated check does not *become* weak when attacked. It was never anything
but advice, because the identity it asks about is supplied by the process being
asked about. That is the argument for the version bump restated as a
measurement.

**WHAT `owns_wid()` ACTUALLY ANSWERS, AND STAGE 2 GUESSED THE SHAPE RIGHT.**
`HAMWSYS_SRV_TRACE=1` prints both predicates from *inside* `srv_as_caller()`,
because from outside "owns_wid said no" and "hostowner said yes first" are
indistinguishable and are opposite findings. For the attacker: `hostowner=0
owns_wid=0` — the refusal was **decided by the ppid walk**, not short-circuited
past it. Then the walk isolated, with `hostowner()` out of the way: a window
stamped by `alloc` against a uid-0 process that can still fork, and two uid-1002
callers differing only in descent.

| caller | `owns_wid` | outcome |
|---|---|---|
| not descended from the owner | 0 | refused |
| **a child of the owner** | **1** | **accepted** |

**A uid-1002 process wrote a uid-0 process's window because it was descended
from it.** The walk compares pids and never looks at a uid at all.

It is **not a routing regression and is not weakened here**: the gate measures
the *unrouted* path granting the same descendant the same window, so the rule is
inherited, not introduced — which is exactly what stage 2 was required to
deliver. It is devwsys's rule: hamUI spawns a task *into* a window and stamps
the parent's pid, and `snap_self` answers "creator pid OR ANCESTOR" for that
reason. Tightening it to an exact pid match would leave every hamUI-spawned task
unable to drive the window it was spawned into.

**What it costs, priced rather than apologised for:** every application the
desktop spawns is a descendant of the desktop, so every application may
retitle, move, raise or destroy any window owned by the compositor, the panel,
or any of its own ancestors, **regardless of uid** — and now with the
mediator's blessing rather than merely without its knowledge. The
capability-at-`newwindow` this design already proposes for enumeration is the
shape that replaces it. **It is a stage-3 policy decision, not a stage-3a
one**, and it is the second thing (after the 851 µs read tail) that the
measurement rather than the plan put on stage 3's list.

**The negative control**, because a gate is worth what it can fail: deleting
the single `srv_as_caller()` line takes the file from 15/0 to **10 passed, 4
failed**, including the central arm. The red arm stays green throughout —
correctly, it never touches the server — which is why it is not evidence on its
own.

Still true and still not hidden: `WSYS_VERSION` is 8 and the in-process path is
still there, so **a client that does not speak the protocol still bypasses the
mediator entirely**. That is the red arm, and it is the state of the tree
today, not a historical re-enactment.

Not routed: `wid/scene` (per-open staging state; reopening starts a new frame,
so it needs handle tracking across open/write/close — and 1 write per 12 s of
a drag against 9790 for `wid/ctl`). No reads, no enumeration policy, no
version bump.

## What stage 4 measured — the reads, and the policy that is weaker than this document promised

`tests/linux/wsys_enum_policy.sh`, **9 passed, 0 failed** — the gate that had
been red since it was written. `tests/linux/wsys_srv_readlat.sh`, **7 passed,
0 failed**. `WSYS_VERSION` stays 8.

**THE 851 µs TAIL IS OFF THE READ PATH, AND IT COST A SECOND PROCESS.** wsysd
forks a read server at `listen()` on a second abstract name (`.../rd`). It
inherits the MAP_SHARED segment, never rasterizes, and blocks in
`epoll_wait(-1)`; it answers `READ`, `HELLO` and `STAT` and refuses everything
else with `-ENOSYS`, because two writers to the window table would give up the
same-iteration ordering stage 2 bought. It dies with its parent
(`PR_SET_PDEATHSIG` plus a `getppid()` recheck) and closes every inherited
descriptor, so no stray reference keeps a DRM file description alive.

Both arms in **one run, one compositor, one drag**, because a number from
another day on another machine is not a control:

| arm | p50 | p90 | max |
|---|---|---|---|
| frame loop (`PING` on `.../srv`) | 1640 µs | 1818 µs | **1946 µs** |
| read server (`READ` on `.../rd`) | 12 µs | 32 µs | **79 µs** |

Three runs each, medians of the per-run maxima. The frame-loop arm is a
**control and the gate fails if it is fast** — a quick one would mean the
compositor was idle and the read arm's speed would be unattributable. This
machine's frame loop is slower than the one stage 1 measured (1946 against
851), which makes the comparison more conservative, not less.

**The extra process costs nothing when nobody is asking.** `/proc/<pid>/stat`,
three 20 s windows each: the read server accumulated **0 ticks** at idle and 0
under a full drag — under the 0.05% of a core the instrument can resolve —
while wsysd went 0.35% → 84.35%. It is blocked in `epoll_wait(-1)` and a
process that is not scheduled costs nothing.

**Regressions checked, not assumed.** `wsys_srv_transport.sh` **13/1** — the
same one arm stage 1 left red on purpose. `wsys_srv_identity.sh` **15/0**.
`wsys_uidgate.sh` PASS, `wsys_wctl.sh` **6/0**. `wsys_srv_mutate.sh` is
**7/0** on this branch but flakes on two arms on this machine — the routed
write's `w1 == w0 + 1` assertion races the drag client's own ~800 writes/s,
and the frame-count arm asserts `routed >= unrouted` on counts that are now
statistically equal (543 vs 544, on a machine where stage 2 measured 139 vs
97). **Said honestly: four runs on this branch gave 7/0, 7/0, 6/1 (the counter
arm) and 6/1 (the frame arm); two runs of binaries rebuilt from stage 3a gave
7/0 and 7/0. That is not enough to call the flake pre-existing** — it is
enough to say both mechanisms are load-dependent comparisons that do not
involve the read path, since stage 4 adds nothing to the mutation socket and
moves reads into a different process entirely.

**The one-time dial is reported apart rather than averaged away.** The first
routed read in a process pays connect + version handshake: 742 µs in one run,
~100 in the others. It is printed on its own line and excluded from the
percentiles, because folding a once-per-process cost into a per-read
percentile flatters or damns the wrong thing depending on the sample count.

**THE ENUMERATION POLICY IS NOT THE ONE THIS DOCUMENT PROMISED, and the
difference is the finding.** Above, this file says enumeration "can return the
caller's own windows to an ordinary client and the full list only to a holder
of the taskbar capability". **It cannot, on any fact `SO_PEERCRED` can see.**
The panel is spawned through `/bin/hamsh /etc/rc.de-user /bin/hampanelscene`
and so is every DE application; that rc ends in `setuid 1001`. The taskbar and
a text editor arrive at the socket with the same uid, the same gid, and an
ancestry that meets at the same process. A rule that claimed to separate them
would be reading something the client chose — an argv, an environment
variable, a name — and that is advice, not a boundary, which is the whole
finding of stage 3a.

So the line is drawn where an unforgeable fact actually falls:

> **The full window list goes to the host owner and to any caller that already
> owns a window. Everyone else gets an EMPTY list — not an error, because "no
> windows" withholds the existence of the window system and `EPERM` advertises
> it.**

Permits: the compositor, the panel, every application, every toolkit task.
The taskbar keeps working with **no change to how it is spawned and nothing
granted to it that is not equally granted to every other program with a window
on the screen** — which is the point of stating the rule this way rather than
special-casing it. Denies: every process with no window — a script, a `cat`, a
background daemon, a compromised non-graphical service.

**A person may reasonably call that too weak**, and they would be pointing at
a real gap: any app on the desktop still learns every window's title. The
mechanism that closes it is a **dedicated group on the panel's spawn** —
peercred carries the gid, `/etc/group` records the grant, nothing is invented
— and that is a change to how the distro starts the panel, not a change to
this server. **It is not made here.**

The gate is red-unrouted / green-routed, in the shape stage 3a established:

| | result |
|---|---|
| unrouted, uid 1002, owns nothing | `2 VICTIM-ENUM-TITLE` — **it works, and it must** |
| routed, same process, same uid, same file | empty; `wsrvtrace: enum caller uid=1002 pid=230934 -> hostowner=0 tier=EMPTY` |

And the arm that keeps it honest, because the cheap fake is to answer on uid
alone (which passes a red/green pair **and breaks the taskbar**): a **uid-1002
process that owns a window** gets the full list through the same server that
just refused a window-less uid-1002 process. **Negative control:** deleting the
one `srv_as_caller(uid, pid)` line from `srd_enum_tier` takes the file from
9/0 to **6 passed, 3 failed**, including the central arm; the red arm stays
green, correctly, because it never touches the server.

Routed: `windows`, `screen`, `pool`. `screen` and `pool` carry **no policy on
purpose** — neither names another client, and withholding them would break
every client's layout and blind the only diagnostic an exhausted backbuffer
pool has. Not routed: `self` (it already answers only about the caller),
`ctl` reads, the event rings, and `wid/scene`.

**THE ANCESTRY RULE IS LEFT AS IT IS, AND HERE IS THE ARGUMENT.** Stage 3a
priced it: every application the desktop spawns may retitle, move, raise or
destroy any window owned by the compositor, the panel, or any of its own
ancestors, regardless of uid, because `owns_wid()` walks pids and never looks
at a uid. Tightening it to an exact pid match breaks every toolkit-spawned
task, so that is not on the table. The recommendation is **not to narrow the
walk but to stop the walk being the only question asked**: the window row
already stores the pid it was stamped against, and `newwindow` is already
routed and already blocking, so the server could record the connection that
allocated a row and require a mutation to arrive **on that connection** — a
descendant would then inherit the right to drive the window it was spawned
into only if the toolkit hands it the connection, which is exactly the moment
the toolkit means to. That is a change to `newwindow`'s contract and to
hamUI's spawn path, it needs its own red gate, and **it is not made here**.
Until it is, the ancestry rule stands, inherited rather than widened, and
written down rather than assumed.

## What stage 5 changed — the connection is the capability, and the walk is still there

`tests/linux/wsys_srv_connown.sh`, **10 passed, 0 failed**. `WSYS_VERSION`
stays 8 and `struct wshm`/`struct wwin` are byte-for-byte unchanged.

Stage 4 recommended this and did not do it: **not to narrow the walk but to
stop the walk being the only question asked.** That is what landed.

**The rule, for a ROUTED mutation only:**

> `hostowner()` as before, or **the operation arrived on the connection that
> holds the window's row**. The parent-pid walk is not asked.

A row acquires a holder in one of two ways, both facts the kernel supplies:

1. **`newwindow`** binds the allocating connection, at the one moment the
   server knows who allocated it.
2. **`alloc <pid>`** — hamUId's on-behalf path, the one *every DE window* is
   created through — has no connection at allocation time, because the process
   it names has not connected yet. That row is **claimed by the first
   connection whose `SO_PEERCRED` pid is exactly the stamped pid**. No walk, no
   uid comparison.

**The handoff is the toolkit's half**, `hamwsys_srv_handoff()`: it dials if it
has to, clears `FD_CLOEXEC` and names the descriptor in `HAMWSYS_SRV_FD`. The
adopting child immediately sets `FD_CLOEXEC` and unsets the variable, **so the
capability travels exactly one generation** — inheritance that propagated by
itself would be the ancestry walk rebuilt out of descriptors. A handed
descriptor still carries the *dialling* process's `SO_PEERCRED`, which is why
the child needs no claim of its own: the connection is already the holder.

**BOTH ARMS, IN ONE PROCESS, DIFFERING IN ONE RESPECT.** Holder and both
children are uid 1002 against a segment owned by 1001, so `hostowner()` answers
0 throughout and cannot short-circuit anything:

| arm | result |
|---|---|
| child **without** the connection | `REFUSED` — `hostowner=0 owns_wid=0 ancestry=1` |
| the **same** child **with** it | `ACCEPTED` |
| the same child, **unrouted** | the write **LANDS** — the inherited rule, untouched |

The trace prints both answers per routed mutation, because `ancestry=1
owns_wid=0` **is** the narrowing and there is no way to see it from outside.
The server also counts `claim` and `connrefused`, so "the new rule refused
something the walk would have granted" is a number rather than a claim.

**Negative control, run:** make `owns_wid()` call `owns_wid_ancestry()`
unconditionally — the one line this stage consists of — and the gate goes 10/0
→ **6 passed, 4 failed**. The red arm and the handed arm stay green, correctly.

**AN ADOPTED CONNECTION IS NOT THE HOST OWNER**, and this is the sharp edge of
the mechanism. `SO_PEERCRED` is sampled at `connect(2)`, so a descriptor
dialled by a host-owner toolkit carries the host owner's uid wherever it is
handed. The adopting client declares itself with `WSRV_F_ADOPT` in its HELLO
and `hostowner()` answers 0 for that connection for ever — a flag a client can
only ever use to *lose* privilege. **The toolkit must still hand off after
dropping privilege, not before**: the connection acts for the dialling
process's window either way.

**Enumeration deliberately still asks the WALK** (`owns_wid_ancestry`). "Do you
own a window" is a question about a process, not about a descriptor; the read
server is a separate process holding no bindings, and asking the mutation
question there would answer EMPTY to every client on the desktop. Stage 4's
policy and its 9/0 gate are unchanged.

**WHERE THE HANDOFF WOULD GO, SCOPED BUT NOT WRITTEN.** hamsh has one choke
point for external commands — `spawn_launch()` in `user/hamsh.ad`, which every
resolved command and every pipeline stage passes through — so the wiring is
`sys_wsys_srv_handoff(1)` before it and `(0)` after, six lines. **The trap is
the dial, not the spawn**: the connection is cached per process and
`SO_PEERCRED` is sampled at `connect(2)`, so if hamsh spawns any external
command *before* `/etc/rc.de-user` reaches `setuid 1001`, it dials as the host
owner and every later handoff carries that connection. `WSRV_F_ADOPT` caps the
damage at the row (an adopted connection is never the host owner), but the next
stage should re-dial when the effective uid has changed since the dial rather
than rely on that cap.

**WHAT IS NOT DONE, AND IT IS THE NEXT PIECE OF WORK.** The DE's own spawn path
does not call the handoff. `/etc/rc.de-user` spawns every DE window as
`/bin/hamsh /etc/rc.de-user <prog>`, the wid is stamped against **hamsh**, and
the rc runs the real program as hamsh's **child** — so with `HAMWSYS_SERVER=1`
a DE application would be refused its own window until hamUId or hamsh calls
`sys_wsys_srv_handoff` around that spawn, **after** the `setuid 1001`. The flag
is off by default and nothing ships with it on; the flag-unset path is verified
by a second compositor with the flag nowhere in its environment, in both this
gate and the identity gate.

## Budget to hold it to

**THE BUDGET BELOW IS SUPERSEDED. It was the wrong SHAPE, which is a stronger
statement than "it was too tight", and the replacement is two numbers rather
than three.** It is kept here because the reasoning that produced it is the
thing to avoid repeating.

From the census, at 6.2 µs sequential / 2.2 µs pipelined:

| load | ops/s | added CPU |
|---|---|---|
| idle | 192 | **0.12%** of a core |
| drag, mouse-paced | 618 | 0.38% |
| worst measured | 2050 | 1.27% |

Every figure there is `ops/s × per-op`: 0.12/192, 0.38/618 and 1.27/2050 are
all 6.2e-4. **The budget therefore passes through the origin — it asserts that
mediating nothing costs nothing** — and the measured cost does not, because a
*wake* does not depend on the rate.

### The budget, re-derived — a fixed term and a marginal one

**THE FORM IS THE DURABLE PART; THE CONSTANTS ARE MACHINE-DEPENDENT AND MUST BE
RE-TAKEN QUIET.** This is not a hedge — it is the single most useful thing
measured this pass. The same assertion, same gate, same tree region has read
**0.27%** (stage 1, contended), **0.22%** (the sweep, contended) and
**0.17–0.19%** at loadavg ~1.5. *A third of the apparent overage was other
agents on this machine, not mediation.* A percentage quoted without the load
it was taken at is not reproducible, so `wsys_srv_transport.sh` now prints the
loadavg and the number of bound compositors beside **every** CPU sample, and
ends with an explicit `ATTRIBUTABLE` / `SUSPECT` / `NOT ATTRIBUTABLE` verdict
on its own figures.

The allowances below are set to **envelope every measurement on record**,
including the contended ones, which is why they survive the machine being
busy; the *measured* coefficients underneath them are the part that needs a
quiet host.

    budget(ops) = FIXED_BUDGET + MARGINAL_BUDGET × ops
                = 0.34% of a core  +  1.80 µs per routed message

| load | ops/s | budget | was |
|---|---|---|---|
| wake-only | 100 | 0.36% | — |
| idle | 192 | 0.37% | 0.12% |
| drag, mouse-paced | 618 | 0.45% | 0.38% |
| worst measured | 2050 | **0.71%** | 1.27% |

**Two runs of it, and the difference between them is the argument for the
allowances being where they are.** Both are **17 PASS / 0 FAIL**; both are the
same tree; they differ only in what else the machine was doing.

| ops/s | quiet run | drifting run |
|---|---|---|
| 100 | 0.17% | 0.25% |
| 192 | 0.19% | 0.30% |
| 618 | 0.22% | 0.35% |
| 2050 | 0.42% | 0.43% |
| **fixed** | **0.157%** | **0.241%** |
| **marginal** | **1.282 µs** | **0.923 µs** |

The second run *started* at loadavg 0.65 — the quietest of the session — and
still produced the higher figures, because **the load rose after the baseline
was taken**: the flag-off baseline was sampled at 0.81–1.31 and the arms
differenced against it at 1.68–2.38. The delta does not cancel host drift, its
two terms being minutes apart. Note also the fixed and marginal terms moving in
*opposite* directions between the two runs — the same slope/intercept trade-off
that makes the extrapolated intercept untrustworthy and the 100 ops/s arm worth
having.

**The allowances hold across both**, which is the property they were chosen
for. The measured coefficients are what a quiet host is needed to pin down.

**This is not a blanket loosening.** At the worst measured load the new budget
is 0.71% where the old one was 1.27% — the shape change *tightens* the arm
that had the most slack while making the idle arm expressible at all. Only the
192 arm moves outward, and it moves because the old figure was below what the
instrument can resolve: at `CLK_TCK=100` over 40 s windows one tick is 0.025%
of a core, the delta is a difference of two medians, and the run-to-run spread
on that difference is ±0.05–0.08% — **comparable to the entire 0.12% budget.
The old number was not merely missed, it was never testable.**

`tests/linux/wsys_srv_transport.sh` asserts **both terms separately**, because
a single percentage per rate cannot tell *the wake got dearer* from *messages
got dearer*, and those have different fixes. It also drives a **100 ops/s**
arm, which exists to measure the fixed term almost directly rather than
extrapolate it: the pacer emits at least one message per 10 ms slice at any
rate ≥ 100/s, so 100/s is the cheapest load that still wakes `wsysd` 100 times
a second, and its marginal part (100 × 1.35 µs = 0.0135%) is half a tick. That
matters because the intercept of a fit through noisy points is the
worst-determined thing in it — across the runs on record the marginal term
held at 1.076 / 1.350 / 1.346 µs while the fitted intercept wandered
0.25 / 0.19 / 0.12, slope and intercept trading off exactly as a fit's do.

**Why the idle arm may now pass, stated plainly, because it was left red on
purpose and that must not be quietly undone.** Stage 1 refused to widen it
because widening would have hidden a question: the synthetic load *adds* a
wake, where a real routed mutation *replaces* a shared-memory write that
already poked the wake channel. **Stage 2 answered it** — the same real
dragging client cost a median 99.80% of a core unrouted and 53.30% routed,
46.5 points of a core cheaper at 43% more frames, because `srv_service` drains
every queued message in one iteration where the unrouted path woke the loop
per publish. Mediation coalesces by construction. So the fixed term this
synthetic NOP measures is an **upper bound that real traffic does not pay**.
The arm passes because the question closed, not because the number was moved
to fit.

**Input-to-pixel is ~0.3 ms and is now a published claim**, so it is a budget
and not an observation. A client repaint is 3 ops ≈ 19 µs sequential, about 5%
of it. If measured cost exceeds that, the fire-and-forget rule above is the
first thing to check, not the last.
