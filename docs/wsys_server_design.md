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

## What stage 6 measured — the scene, and the frame boundary is the whole problem

`tests/linux/wsys_srv_scene.sh`, **8 passed, 0 failed**. `WSYS_VERSION` stays 8.
`/dev/wsys/<wid>/scene` is now routed, so **no mutation a routed client makes
is still performed in process**.

The leaf is different from every other one because it has **per-open state**:
opening the scene for writing STARTS A NEW FRAME and every write after that
appends. So the boundary is **carried** (`WSRV_F_NEWFRAME` on the first write
after the open, plus a zero-length message at the open itself so an open with
no write still starts the frame) rather than inferred, and the flag lives in
`struct hamwsys_file` because a client may hold two scenes open at once.

The bytes land where they always did — the window's handed-up memfd, which the
compositor already maps read-write — so routing changes **who writes**, not what
is written. The trap avoided: `pix_get(wid, 0)` and never `pix_get(wid,
owns_wid(wid))`; `mine` would make wsysd invent a second memfd for a window
whose pixels have not been handed up, and the compositor would then paint the
empty one it invented while the client drew into its own. That case is
`-EAGAIN` and the client retries next frame.

**THE ARM THAT MATTERS IS THE PAINT, NOT THE REFUSAL.**

| | |
|---|---|
| unrouted frame 1 | red in the middle — the instrument proven able to answer non-blank first |
| **routed frame 1** | **the same red, same pixel: the display list crossed the boundary and reached the SCREEN** |
| frame 2 (60×60 blue corner) | the red is **gone** on both paths, and the blue is there |
| attacker (uid 1002, owns nothing) | routed scene write **refused**, and its magenta is not on the screen |
| routed vs unrouted | every sampled pixel identical |

**Negative control, run:** make `srv_scene_write` ignore `WSRV_F_NEWFRAME` → 8/0
becomes **6 passed, 2 failed**, and *every other arm stays green*, including the
refusal and both frame-1 paints. That is why this gate reads a pixel that is
supposed to have **gone away**: the defect is invisible to every other kind of
assertion, and it is the one that made an empty window look full.

**A connection must not outlive the identity that dialled it — PROVEN, and
proving it found a real defect.** `tests/linux/wsys_srv_identity.sh` is now
**17 passed, 0 failed**; arm D dials as a host owner (inner uid 0), drops to
uid 1002 and writes to uid 1001's window, scored on **the uid the server
accepted the connection with**, taken from the server's own trace, and refusing
to score at all on an `ENOENT` — because that is how the FIRST version of this
arm passed while measuring nothing (its holder had exited, so `win_find`
answered before the permission check; it was deleted rather than quoted).

The second attempt was **red on its first run**: `srv_redial_if_uid_changed()`
was hooked into `srv_route_write()`, the client's ordinary write path, which a
process that skips the local check never calls — so the mediator accepted the
write and the victim's title read `PWNED-BY-A-STRANGER`. **A check that only
runs on the path an honest client takes is advice.** The hook moved to
`srv_send()`, the one funnel every routed message passes through.

| | |
|---|---|
| with the fix | server accepts the connection as **uid 1002**, write REFUSED, title still the arm's own baseline |
| without it (control) | server answers for **uid 0**, and the write **lands** — 17/0 → **15 passed, 2 failed** |

Adopted connections are exempt and that is deliberate: an inherited connection
is the capability a spawner handed over, it already answers `hostowner()` = 0,
and re-dialling would silently lose the window the process was spawned into.

**This unblocks the DE wiring**: the six lines at hamsh's `spawn_launch` no
longer depend on hamsh never spawning before `setuid 1001`, because a stale
identity is now noticed at the next message rather than carried for the life of
the process.

## What stage 7 measured — THE DESKTOP, BOOTED ROUTED, AND WHAT IT COSTS

`tests/linux/wsys_srv_deboot.sh`, **52 passed, 0 failed**, twice. `WSYS_VERSION`
stays 8. Every stage above proved itself with a purpose-built client; this is
the first time the mediator has carried a desktop.

**IT COMES UP, AND THE SCREEN IS THE SAME SCREEN.** Offscreen, one set of
binaries, arms alternated rep by rep in one session:

| | unrouted | routed |
|---|---|---|
| wallpaper + icons (`hamdesktop`) | wid 2, 1280x800 | **the same** |
| **both** panels (`hampanelscene`) | wid 3 and wid 4, 1280x26 | **the same** |
| Applications menu (`hamappmenu -self`) | wid 5 at (8,28), **407x140** | **the same** |
| a window drag (`de_dragload`) | wid 6, 480x320 with text, moving | **the same** |

407 wide at (8,28) is `de_appmenu_brisk.sh`'s discriminator between the
Brisk-shaped menu in its own window and the panel's own in-panel dropdown, and
it is used here for the same reason: "a menu-coloured card appeared" passes on
the broken one.

**WHO IS ROUTED IS COUNTED, NOT INFERRED, AND THAT IS THE POINT OF THE FILE.**
`HAMWSYS_SERVER=1` in a shell does not reach a hamsh-spawned program —
`_build_envp()` gives a child `PATH` and `HOME` and nothing else — so a run
that exports the variable and assumes measures an unrouted desktop and believes
it is routed. Instead every ESTABLISHED connection to
`@hamnix-wsys/<dev>.<ino>/{srv,rd}` is listed, its **peer socket inode**
resolved to a pid through `/proc/<pid>/fd` (the client end of an AF_UNIX
connection has no address, so `/proc` is the only place the association
exists):

    srv <pid> hamdesktop      fd=3
    srv <pid> hampanelscene   fd=3
    srv <pid> hamappmenu      fd=3
    srv <pid> de_dragload     fd=3

**Four processes, one per window-owning program, and not one more.** wsysd
holds none of its own — `hamwsys_srv_claim()` is why. The control arm runs the
same census and finds **zero**, which is what makes it a control.

That answers the standing policy question with a measurement rather than a
reading of the source: **no process holds a connection it has no business
with.** And a second thing falls out that nobody asked: **not one client holds
a READ connection.** The whole desktop — compositor, wallpaper, two panels,
menu, a dragging client — performs no routed read at all, so the second process
stage 4 forked to keep the 851 µs tail off the read path serves nothing on a
real session. It costs nothing (stage 4 measured 0 ticks), but its
justification is now a leaf that this desktop does not read.

**AND THE TRAFFIC ACTUALLY CROSSES — a held connection is not a routed
desktop.** A client could dial, negotiate a version, and then do every mutation
in process, and the census above would look identical. From the server's own
trace, 8 s of a drag:

    7499  de_dragload      hostowner=1 owns_wid=1 ancestry=1
     254  hampanelscene    (164 of them wid=-1, the /dev/wsys/ctl leaf)
     249  hamdesktop
       6  hamappmenu
    ----
    7914 mutations in 8 s, every one through srv_as_caller()

**THE COST, AND THE HONEST ANSWER IS THAT IT IS BELOW THIS HOST'S NOISE.** Two
full runs, three reps each, both 52/0, both **NOT ATTRIBUTABLE** by the gate's
own verdict (peak loadavg 3.34 and 3.44; other agents' compositors were bound
throughout, 7 wsys server names at peak):

| load, ~330 fps | run A | run B |
|---|---|---|
| pointer only | **+5.5 fps** | **−13.0 fps** |
| window drag | +0.2 | −13.4 |
| drag + pointer | +3.7 | −6.5 |

**The two runs do not agree on the SIGN.** The spread is −4% to +1.7% of the
frame rate, and the run-to-run difference is larger than the arm-to-arm one.
Stage 2's 46.5-points-of-a-core saving is not reproduced here and neither is a
loss: *on this host, at this load, routing the desktop is not measurable in
frames.* Quoting either run alone would be quoting the neighbours.

`wsysd` sits at **99.7–99.9% of a core in BOTH arms** under all three loads, so
the CPU column cannot discriminate at all and the gate says so in the output
rather than printing a difference of two saturated numbers.

Input-to-pixel, 90 trials per arm per rep, medians of the per-run percentiles:

| | p50 | mean | p95 | max |
|---|---|---|---|---|
| unrouted | 0.36 ms | 0.39 | 0.45 | 1.33 |
| routed | 0.34 ms | 0.37 | 0.44 | **2.21** |

Indistinguishable through p95. The maximum is worse routed in both runs (2.21
against 1.33; 4.10 against 2.75) — one sample in ninety, and the honest reading
is that the tail is noisy in both arms rather than that routing costs 0.9 ms.

**THE ONE CONSISTENT COST IS AT IDLE, AND IT IS SMALL.** Frames presented in
10 s with nothing touching the desktop, three samples per arm per run:

| | unrouted | routed |
|---|---|---|
| run A | 26, 26, 27 | 34, 32 |
| run B | 26, 26, 27 | 27, 31, 30 |
| run C | 26 | 30 |
| wsysd cpu | 1.2–1.3% | 1.4–1.6% |

**+15% to +27% more frames on an idle desktop, and +0.2 points of a core.** The
unrouted figure is the panel's 320 ms sysmon resample and nothing else (3.1/s =
31 in 10 s, `de_fps_latency.sh` derives it from the source). Routed, something
presents four to six more. That is the only difference either run reproduces,
and it is not yet attributed to a line.

**A SHORT-LIVED CLIENT PAYS FOR THE DIAL, AND ON A BUSY DESKTOP IT IS 3x.**
200 fresh `cat /dev/wsys/wsysd/state` processes per arm, each paying connect +
HELLO before it can answer:

| | p50 | p90 | max |
|---|---|---|---|
| unrouted, idle | 2.0 / 2.0 ms | 2.5 / 2.1 | 3.7 / 2.4 |
| routed, idle | 2.1 / 2.2 ms | 2.8 / 2.4 | 5.6 / 3.6 |
| unrouted, dragging | 2.1 / 2.2 ms | 2.3 / 2.4 | 3.0 / 3.1 |
| **routed, dragging** | **6.1 / 6.8 ms** | **7.1 / 8.0** | **9.4 / 14.7** |

(two independent runs, `a / b`; the arm is now in the gate)

Idle it is free. Against a saturated compositor the dial waits for the frame
loop, which is stage 1's 851 µs finding showing up in the one place a desktop
actually meets it: a script or a `ps`-like tool that runs, reads and exits.

**AND THE MEASUREMENT FOUND A DEFECT IN THE INSTRUMENT, WHICH IS THE MOST
PORTABLE THING HERE.** A routed arm reported *"idle: 10.0 s with NO input —
−173 frames presented"*. A negative count of presentations is a broken reading,
not a slow desktop. `/dev/wsys/wsysd/state` is rewritten in place and a reader
landing mid-rewrite gets an **empty body with exit status 0** — 1-in-200 on an
unrouted dragging desktop, 4-in-200 on a routed idle one, i.e. **in both arms,
a property of the file**. `de_fps_driver.py`'s `read_state` returned `{}` for
that and every caller then wrote `s.get('frames', 0)`, so one torn read became
a frame delta of minus the whole counter (−173) or plus it (+212, which was
briefly read as an eightfold idle regression). It is fixed by retrying and by
saying so out loud when retrying fails, because *a default of zero on a missing
counter is what lets an unreadable instrument produce a confident number.*
`de_fps_latency.sh`, `de_fps_gpu.sh` and `de_fps_mate.sh` all drive that file.

### What stage 7 did NOT do, stated so the next pass does not re-read it as done

* **No `WSYS_VERSION` bump, and the boundary is still not enforced.** Every
  number above is of a mediator that a non-participating client can walk past.
* **The mediator refused NOTHING on this desktop, and it could not have.**
  Offscreen, every client is the segment's host owner, so `hostowner()` answers
  1 before any other question is asked. The refusal arms live in
  `wsys_srv_identity.sh` and `wsys_srv_connown.sh`, where a second uid exists.
  **A routed desktop where the compositor and the applications are different
  uids has still not been booted**, and that is where `owns_wid()` would
  actually be asked.
* **No `hamUId`, and therefore not `/bin/hamsh /etc/rc.de-user <prog>`** — the
  spawn path every window of an *installed* desktop is created through, in
  which the wid is stamped against hamsh and the program runs as hamsh's child.
  Stage 5 named that as the next piece of work and it is still that. The
  clients here self-allocate through `newwindow`, which binds their own
  connection, so they take the easy path through the stage-5 rule.
* **No terminal.** `hamtermscene` spawns `/bin/hamsh --no-echo /etc/rc.de-user`
  and its window dies with that shell; neither path exists on a developer's
  host. It exits in **both** arms, which is what makes that a harness limit and
  not a routing result — staging a `/bin` and an `/etc` for it was attempted,
  and the assembled `/etc` broke the host's own tooling before it reached the
  question.
* **The numbers are NOT ATTRIBUTABLE and the gate says so.** Both runs peaked
  over loadavg 3.3 with other agents' compositors bound. The correctness arms
  do not depend on load; the percentages do.

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

# Stage 7 — THE ENFORCEMENT, SCOPED. Nothing here is built, and the version is still 8

Every stage above carried the same sentence: *`WSYS_VERSION` stays 8, the bump
is the enforcement, and it goes last.* Nobody had worked out what "last"
requires. This section is that scope. **It changes no code and bumps nothing.**

Where this section and the six above disagree, this one was written by reading
`user/linux-wsys.c` and by running a probe against a live mediator; the
paragraphs above were written from the plan. Three of the disagreements are
findings and are marked as such.

## 7.1 What is still served in process when `HAMWSYS_SERVER=1` — from the code

Stage 6 says "no mutation a routed client makes is still performed in process".
**That is true of three leaves and the enum in `user/linux-wsys.h` has
nineteen.** `srv_route_write()`
carries exactly `ctl`, `wid/ctl`, `wid/scene`; `srv_route_read()` carries
exactly `windows`, `screen`, `pool`; `newwindow` goes through `srv_newwindow()`.
Everything else in `hamwsys_write_inner()` and in `hamwsys_open()`'s snapshot
arms runs in the client, out of the client's own mapping, with the mediator
running and idle.

| leaf | write | read |
|---|---|---|
| `ctl` | **routed** (`newwindow` blocking) | in process (`snap_ctl`: this process's own last wid) |
| `wid/ctl` | **routed** | **in process** — `snap_win_ctl`, 14 fields, any wid, no check |
| `wid/scene` | **routed** | in process, and correctly: `pix_get` needs the handed-up memfd |
| `windows` / `screen` / `pool` | n/a | **routed** |
| `self` | n/a | in process — answers only about the caller |
| `dir` (`/dev/wsys`, `/dev/wsys/<wid>`) | n/a | **in process — lists every used row's wid** |
| `wid/wctl` | **in process** — `version` / `focus` / `move` / `resize` | **in process** — the live rect of any window |
| `wid/pointer`, `wid/event`, `wid/text`, `wid/cmd` | in process — `ring_write` into the row | **in process — `ring_read` DRAINS the row** |
| `wid/keys` | in process, but off the segment (keystroke channel, `SCM_CREDENTIALS`) | refused to a non-owner, by name |
| `wid/draw/ctl`, `wid/backbuffer` | in process — the v2 blit, `/srv/wsys.bb` | in process — the per-window memfd |
| `wid/draw/images`, `wid/draw/image/<n>` | n/a (read-only) | in process — any window's named images, out of `/srv/wsys.img` |
| sinks | in process; `0644` chrome vs `0666` public is the only gate | in process |

### Measured, with the mediator live and the enumeration policy working

`unshare -U` with three ids, `wsysd` as 1001 with `HAMWSYS_SERVER=1` and a read
server forked, a victim at 1001 owning window 2, an attacker at **1002 owning
nothing**, and `HAMWSYS_SERVER=1` on **every** arm — so nothing below is the
unrouted control, it is all the routed configuration. Two runs, identical.

The two arms that make the rest readable, first:

    ctrlenum   routed `windows` for the attacker:   (empty)
    hostenum   routed `windows` for the host owner: 2 VICTIM-ENUM-TITLE

The policy is live and the instrument can produce a non-empty answer. Then:

| arm | the attacker got |
|---|---|
| `cat /dev/wsys` | `ctl self windows screen pool 2` — **window 2, enumerated** |
| `cat /dev/wsys/2/ctl` | `2 100 100 300 200 5 1 1 1 0 0 0 0 0` — the victim's geometry, z, proto and three frame counters |
| `cat /dev/wsys/2/wctl` | `100 100 300 200 click` |
| `cat /dev/wsys/2/keys` | `EPERM`, said by name — the negative control |

**THE ENUMERATION POLICY STAGE 4 LANDED IS BYPASSED BY `ls`.** The routed
`windows` read correctly answers EMPTY to that process, and `snap_dir()` hands
it every used row's wid one path component up, out of shared memory, on the
same run. `wid/ctl` and `wid/wctl` then answer geometry for each of them with
no check of any kind. What the routed read withholds is the **title**, and only
the title. That is not what section 4 above claims it bought.

The mutation arms of the same probe were **refused** — the attacker's
`title`, `move 777 888` and `resize 640 480` all left the victim untouched.
That is the honest result and it is not a defence: `wid/wctl`'s write arm calls
`hostowner()` and `owns_wid()`, the same two predicates stage 3a took from
REFUSE to ALLOW **with one assignment to `srv_caller.uid`** in the attacker's
own address space. An unrouted mutation is refused to a client that asks
politely and granted to one that does not.

The ring arm is the one that needs no modified client at all. The attacker
wrote `INJECTED-BY-1002` into window 2's `event` ring (refused) and then
**read the ring** — and got back

    geometry 100 100 300 200 f in

which is the compositor's own event to the victim, removed from the victim's
queue by a process of another uid that owns nothing. `ring_read` is a **drain**.
There is no read check on `pointer`, `event`, `text` or `cmd`; `keys` is the
only ring with one, and it has one because it is no longer in the segment.

### What must be true, then

Sorted by whether it changes what an attacker can do, not by how much code it is.

**(1) The client must stop mapping the segment read-write. Everything else is
downstream of this and nothing else substitutes for it.** `shm_attach()` ends
in `mmap(..., PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0)` on a file it has just
`fchmod`ed to `0666`, and `/srv/wsys.bb` is the same. Every gate's red arm and
all four attacks in `wsys_bypass.sh` are that mapping; none of them calls a
function in this file. Routing every remaining leaf and leaving the mapping is a
mediator with a door beside it. **The three tiers at THE SPLIT in
`user/linux-wsys.c` are the design for this, and its blockers (1)–(3) are
unchanged and are the real cost of stage 7.**

**(2) Routing `open` is the precondition for (1), and no stage has touched it.**
Almost every arm of `hamwsys_open()` starts with `win_find(f->wid)`, which is a
walk of the mapped table. A client with no mapping cannot open a leaf, so
existence, `wid/ctl`'s 14 fields, `wid/wctl`'s rect and the directory must
become server answers before the mapping can go. **This is the largest single
piece of unbuilt work in stage 7 and it is not in the plan above at all.**

**(3) Four rings need what `keys` already has.** `pointer`, `event`, `text`,
`cmd`: a per-window kernel-authenticated channel, not an RPC — they are the
34.6/s per-frame half of the census and a round trip per event is the one shape
the measurement says not to build. `keys` is the worked example: no daemon, no
new binary, no field removed, and a version bump for the meaning change.

**(4) `wid/wctl` must be routed, or the mediator gates one of two spellings.**
`move`/`resize` on another window is the same act as the `geometry` verb on
`wid/ctl`, which stage 2 routed. This file already argues, about the wallpaper
sink, that "a gate on only one of the two spellings is not a gate".

**(5) Every fallback to the in-process path must become a refusal.** They are,
by name: a failed `srv_dial()`; `srv_adopt_inherited()` rejecting the inherited
descriptor; `srv_route_write()` returning 0 on `srv_fd < 0`, on `n >
WSRV_MAXPAY`, and on a failed `srv_send()`; `srv_newwindow()` returning −2;
`srv_route_read()` on a failed `srv_rdial()` and on an unanswered call; and the
server closing the 65th connection (`srv_nconn >= WSRV_CONN_MAX`), which the
client sees as a dial failure. The code says so already, at `srv_dial`: *"When
the in-process path is removed in stage 4 this becomes a hard refusal."*

**(6) `srv_enabled()` must go, not flip.** While the boundary is an environment
variable, `env -u HAMWSYS_SERVER` is the bypass and it needs no attacker.

### What is genuinely fine unmediated, and why

- **`self`.** It reports only a row whose `pid` is the caller or its parent. A
  process that rewrote the table to make `self` lie would be lying to itself.
- **`keys`.** Off the segment since v8; sender authorised by the kernel's
  credential stamp, receiver by who holds the bind. The model for (3).
- **`wid/scene` reads.** The bytes are in a per-window memfd; a non-owner gets
  `EPERM` from `pix_get`, and the owner is `PR_SET_DUMPABLE(0)`.
- **The pixels — and they must stay out.** 12 s of a real drag: 9899 control
  writes, **0** `wid/backbuffer` writes. This is why the whole boundary is
  0.1–0.5% of a core and not a megabyte a frame.
- **`screen` and `pool`** — routed already, and carrying no policy on purpose.

**A ring the client drains for itself is not the same as a row it can rewrite —
and none of these four rings is that ring.** `event`, `pointer`, `text` and
`cmd` are written by the compositor and read by the owner, so an unmediated
read is a *steal* and an unmediated write is *synthesised input*. The distinction
the brief asks for lands on `keys`, which is a ring and is already closed, and
on `self`, which is not a ring at all.

## 7.2 What breaks at the bump, and for whom

**124 packages in the channel, of which 92 carry Hamnix programs — and every
program links this file.** `scripts/hamlinux_build.sh` compiles
`user/linux-wsys.c` into `RT_SRCS` unconditionally, for every binary, and
`scripts/hamlinux_packages.py` ships one package per program — `hamnix-cat`,
`hamnix-ls`, `hamnix-true`. `/bin/true` is a window-system client at a version.
(The other 32 are firmware, kernel modules and Vulkan libraries and carry no
Hamnix binary; they are the only packages a wsys bump does not touch.)

`hpm update` upgrades every installed, **non-pinned** package and aborts the
closure on the first failure. So the mixed system arrives three ways: a pinned
package, an aborted closure, and any binary that did not come from a package.

**THE ENFORCEMENT BEGINS AT THE REBOOT, NOT AT THE UPDATE, and that is the
sentence to plan around.** Immediately after `hpm update`:

- every process that was already running keeps its v8 mapping and keeps full
  shared-memory access — the compositor, both panels, every open app;
- every process started *after* it is v9 and `shm_attach()` refuses: the header
  says 8, `shm_seg_is_live()` says a row is held, so it prints by name, appends
  `refused live=8 mine=9 pid=… boot=<boot-id>` to `/srv/wsys.refused`, sets
  `hamwsys_was_refused()`, changes not one byte, and returns `EPROTO`;
- the panel — a survivor, therefore v8 — draws the restart notice on a real
  click, which is what STAGE E of `installed_update_wsysver.sh` measures.

So between the update and the restart the desktop is **usable and closed**: it
keeps compositing and cannot open anything. **It is also, for that whole window,
a system with no boundary at all**, because the survivors are exactly the
processes that still hold the segment. That is not a degraded boundary, and the
release note has to say so in those words: *the security property starts at the
reboot.*

**A PINNED v8 PACKAGE IS PERMANENTLY BROKEN AFTER THE REBOOT, AND THE REFUSAL
TELLS THE PERSON THE WRONG THING.** After the restart the live segment is v9
and a pinned v8 `/bin/cat` refuses with

> REBOOT (or restart the session) and start this program again.

which is true when the *program* is newer than the session and false when the
*session* is newer than the program — and `seg_refuse_message()` cannot
currently tell the two apart, though it has both numbers in its hand. **Stage 7
must branch that message on `theirs > mine`** and say "this program is older
than the running window system; update it (`hpm update <pkg>`) or unpin it."
Cheap, and it is the difference between a fixable machine and a mysterious one.

**AND `/srv/wsys` MUST NOT SIMPLY STOP EXISTING.** If stage 7 follows blocker
(3) and moves the authority's table to a new path, then a v8 straggler finds no
`/srv/wsys`, **creates one**, initialises it, and runs a private window system
that composites nothing — a silent success, which is the failure shape this
tree exists to refuse. **It is not a hypothetical: that exact failure has been
measured twice** and both write-ups are in `shm_attach()` — "allocated window
ids nobody composites and drew into a screen that does not exist, with no error
anywhere". `shm_attach()` tries three candidates (`shm_path()`, then
`/dev/shm/hamnix-wsys`, then `/tmp/hamnix-wsys`) and creates at the first one it
can, so an absent `/srv/wsys` does not stop a straggler, it only relocates it.

The v9 `wsysd` must therefore keep a **refusal stub** at `/srv/wsys`, and the
stub has two non-obvious requirements, both from the code:

- **It must be openable `O_RDWR` by an ordinary client** (`0666`), or the
  straggler's open fails and it falls through to candidate 2 and creates its own
  segment there. A `0600` stub is worse than none.
- **It must read as LIVE, which means it must contain at least one `used` row
  whose `pid` is a running process** — `shm_seg_is_live()` scans for exactly
  that and answers 0 otherwise. A v9-stamped stub *with no rows* reads DEAD, and
  a v8 straggler then RE-INITIALISES it in place and runs its private desktop in
  the very file that was supposed to stop it. The stub therefore holds one row
  stamped against `wsysd`'s own pid and nothing else.

The refusal is terminal once a candidate is opened — it does not fall through to
candidates 2 and 3 — so one correct stub is sufficient. This is a distribution
decision, it needs its own arm in `installed_update_wsysver.sh`, and it is not
optional.

### The 8 → 9 rehearsal

**It needed no new gate.** `installed_update_wsysver.sh` reads `WSYS_VERSION`
out of `user/linux-wsys.c`, builds three private channels at N−1, N and N+1
from symlink farms, and its **STAGE E already is the 8 → 9 update**: a live v8
desktop, `hpm update` to a v9 channel, real QMP clicks on Applications, and
assertions that the v9 binary refused by name, that `/srv/wsys` is unresized,
that the window table is unchanged, and that `/srv/wsys.refused` carries
`refused live=8 mine=9`.

**RUN, AND IT IS GREEN: 37 PASS / 0 FAIL, one FINDING, three boots.** Machine
installed whole at 77.7.1 (wsys v7), updated live to 77.8.2 (v8), rebooted,
updated live again to 77.9.3 (v9). Three channels built here from symlink
farms, three distinct compositors — `9a219bf3…` (v7), `8f5c0b6a…` (v8),
`1bb71cc7…` (v9) — so every assertion below was asked of a boundary that
existed.

**The 8 → 9 half, which is the one this section needed:**

| | |
|---|---|
| the refusal | a v9 binary met the live v8 session and **refused by name**: *"REFUSING to attach to /srv/wsys: it is a LIVE window-system session of version 8 and this program is version 9"* |
| the segment | **37,972,380 bytes before and after** the second update and the notice — not resized, not truncated, not one byte written |
| the marker | `/srv/wsys.refused` carries **`refused live=8 mine=9`**, so the notice came from a real refusal and not from something else that drew a card |
| the person | the notice rectangle goes **0% (STAGE D, nothing refused yet) → 82% (STAGE E, after real clicks on Applications)** |
| it stays | a click at (900,600), far from the card, left it at **82%** — a notice, not a one-frame flash |
| it clears | a click on the card took it back to **0%** |
| not wedged | one more click on Applications moved **31,227 px against a 277 px noise floor** |
| one panel, not both | card at 82% on the bar that carries the button; the **taskbar's own box is 0%**, and the window table agrees — the menu panel grew 26 → 112 px to hold it, the taskbar stayed 26 |

**The 7 → 8 half reproduced the designed behaviour and is the control**: the
screen stayed a desktop (1461 distinct colours against the 3 of the slab this
gate photographed before the refusal existed), 45,406 px differed from stage B
out of 1,024,000, the window count was 4 at B and 4 at C, the leftover control
re-initialised and ping-ponged its four md5s correctly, and the reboot came up
on the new compositor with both panels back.

**THE FINDING, AND IT IS THE SHAPE OF THE COST:** at STAGE C the click *is*
answered — the panel logs the button and spawns `/bin/hamappmenu` — and the menu
never appears, because the spawned binary is the new one and it refuses the
running session. **Nothing on the screen says so; the words are on stderr.**
That is not a defect of the refusal, it is the arithmetic this gate already
documents: the panel that survives 7 → 8 was built before the notice existed,
and no change made in a tree can put a notice on a screen owned by a binary
that shipped before it. At 8 → 9 the surviving panel *does* have the notice, and
the 0% → 82% above is that same person being told. **So the release note for
the bump has to say: the person is told only if the panel they are running
already knows how.**

**WHAT THIS REHEARSAL DOES NOT PROVE, said plainly.** The v9 channel is this
tree with one integer changed. The in-process path is still in it, both sides
still map the segment, and `HAMWSYS_SERVER` is still unset. **So what was
measured is the refusal MACHINERY — that 8 → 9 refuses rather than wipes, and
that a person sees why — and not the boundary.** Stage 7's real v9 is a
different artefact and this gate will need the arms in 7.2 (the refusal stub)
and 7.4 (a v8 client against a v9 server) before it can say anything about
enforcement. It is the right rehearsal for the *update*, and it is cheap: with
the three channels cached it is one disk build and three boots.

**TWO THINGS THE NEXT PERSON TO RUN IT SHOULD KNOW**, both paid for here:

- **A STALE `build/image` FAILS THIS GATE IN A WAY IT CANNOT DIAGNOSE.** The
  only precondition is `[ -f build/image/vmlinuz ]`. An image staged before
  `b45cb69f` ("name the root by its partition GUID") does not switch root when
  this tree's `hamlinux_disk.sh` writes `root=PARTUUID=` — so the machine boots
  the *initramfs* rc, prints "handing off to an interactive shell", never runs
  phase 1, and the gate correctly refuses with `THE BASELINE NEVER INSTALLED`
  after paying for three channel builds. **Rebuild the image from the tree under
  test first.** A cheap fix would be for the gate to compare
  `build/image/vmlinuz`'s mtime against `HEAD`'s commit date and say so.
- **It prints no final tally line on the green path** — only on the early-exit
  ones. The 37/0 above is counted from `^wv: PASS` / `^wv: FAIL`.

## 7.3 What it costs — and the budget has no term for the thing that changes

The measured shape holds: `budget(ops) = 0.34% of a core + 1.80 µs × ops`, both
terms asserted separately by `wsys_srv_transport.sh`, and routing a drag
measured *cheaper* than not routing it (99.80% → 53.30% of a core at 43% more
frames) because `srv_service` drains every queued message in one iteration where
the unrouted path woke the loop per publish.

**The whole-desktop case does not break that, and the reason is worth stating:
the fixed term is a WAKE, and a wake is per-loop-iteration, not per-client.**
N clients' messages coalesce into the same drain, so the fixed term does not
multiply — and the unrouted arm gets *worse* with N, because N clients poke the
wake channel N times. The routed win should therefore **grow** with the number
of clients. **That is a prediction from the mechanism, not a measurement, and
stage 7 must not quote it as one.**

**What the budget has no name for is the CONNECTION**, and a desktop is where
connections stop being one:

- `WSRV_CONN_MAX = 64`, on the mutation socket *and* separately on the read
  server. The 65th client is `close(cfd)`'d, which today means it silently
  falls back to the unmediated path and after 7.1(5) means it cannot draw at
  all. A DE spawns each app as `/bin/hamsh /etc/rc.de-user <prog>`, so an app
  costs a connection for hamsh and one for the program unless the handoff
  adopts — **64 is a desktop-wide app limit and nothing measures it.**
- The one-time dial is 742 µs in one run, ~100 µs in the others, per process.
  At login that is once per DE component; at `hpm update` scale it is nothing.
  It is reported apart in the read-latency gate and belongs in the budget as a
  third term rather than folded into a per-message figure.
- `srv_service` linearly scans `srv_conn[]` to find the connection for each
  ready descriptor. 64 compares per message is negligible; it is named so that
  raising the ceiling is understood to be cheap.
- The read server measured **0 ticks** at idle and under a drag — with **one**
  client. `snap_windows()` walks the table per read, so read-server CPU is
  (clients × poll rate × rows) and every one of those three numbers is bigger
  on a desktop.

**So the honest answer to "does the whole-desktop case change the picture": the
two-term budget's *form* survives and its *constants* have never been measured
above one client.** Stage 7 needs one new arm before it can claim otherwise:
`wsys_srv_transport.sh` driven by **N probes at once** (N = 2, 8, 32, 64) at a
fixed total ops/s, asserting that the fixed term does not scale with N and that
the 65th client is REFUSED rather than served in process.

## 7.4 What has to be deleted, and how the gates survive losing their red arms

**"Remove the in-process path" is the wrong name for it, and the wrong name is
dangerous here.** `hamwsys_write_inner()` is what a routed mutation *becomes*
inside `wsysd`, with `srv_as_caller()` installed. It is not going anywhere. What
is deleted is **the client's entry into it**: the fallbacks in 7.1(5), the
`srv_enabled()` flag, and the mapping. The device implementation and the client
transport separate; they do not merge and nothing is dropped.

That is also what breaks the gates, and precisely:

- **61 gates set `$HAMWSYS`. Six of them never start a `wsysd`** —
  `wsys_bypass.sh`, `wsys_uidgate.sh`, `wsys_v2_handup_rate.sh`,
  `lat_null_control.sh`, `net_accept_servers.sh`, `x11_stream_resync.sh`.
  (The blocker note at THE SPLIT says "twenty test scripts … and TWO"; the
  denominator has moved to sixty-one, and the **two it names are still exactly
  the two that matter** — the other four set `$HAMWSYS` to isolate a segment
  and never name a `/dev/wsys` path, so they are collateral rather than
  subject. The note's judgement has aged better than its arithmetic.) After the
  bump a client with no compositor cannot open `/dev/wsys` at all, so
  `wsys_bypass.sh` and `wsys_uidgate.sh` — the two gates on this very boundary
  — stop being able to run their subject at all.
- **Six gates assert an unrouted success as a scored arm**: `wsys_enum_policy`,
  `wsys_srv_identity`, `wsys_srv_mutate`, `wsys_srv_scene`, `wsys_srv_connown`,
  `wsys_srv_transport`. Every one of those red arms is a client reaching the
  segment past a live mediator, which is exactly the thing being deleted.

**The restructuring, and it is not "delete the red arms".** A gate that is green
in every configuration is equally green against a server that checks nothing —
that sentence is in three of these files and it does not stop being true when
the property lands. The red arms have to be *relocated*, not retired:

1. **The bypass moves out of the client and into a purpose-built one.**
   `tests/linux/wsys_bypass.c` already is that program: it opens the segment by
   path and mmaps it, calling nothing in `linux-wsys.c`. Post-bump it keeps
   working **only if there is still something to open** — so it becomes the
   gate on the refusal stub (7.2) and its assertions **invert**, exactly as the
   keylog arm already did: it must now find the table absent, or present and
   `0600`/empty, and it must say so by reading the same offsets it used to
   scrape. An inverted control is evidence; a deleted one is not.
2. **The pairs get their red arm from a v8 CLIENT, not from a flag.** The
   `installed_update_wsysver.sh` machinery already builds a whole channel at an
   arbitrary `WSYS_VERSION` from a symlink farm — so a stage-7 gate can build a
   **v8 `cat`** and a **v9 `wsysd`**, run them against one segment, and get a
   genuine red/green pair whose red arm is a real old binary rather than an
   environment variable. That is a better red arm than the current one: it is
   the artefact the property actually has to defeat.
3. **The six compositor-less gates get a compositor, or say why not.** Five of
   them are cheap to give one. `wsys_uidgate.sh` is the hard case — it exists to
   prove what a client can do with *nothing else alive* — and its honest
   post-bump form is "a client with nothing else alive can do nothing", which is
   a one-line assertion and a real one.
4. **Nothing lands until 1 and 2 are green in the pre-bump tree.** They can both
   be written and run today, against v8, with the in-process path still there:
   the v8-client/v9-server pair reproduces on the current tree by construction.
   Building them first is what keeps the project from gaining the property and
   losing the proof in the same commit.

## 7.5 The order of work

Each step is separately committable and separately red-gateable; the bump is
still last and is now step 8 of 8.

1. Branch `seg_refuse_message()` on which side is older (7.2). One function, no
   protocol change, immediately useful — it is already the wrong advice today
   for anyone who pins.
2. Write the v8-client / v9-server gate (7.4 §2) and the multi-client budget arm
   (7.3). Both run on the current tree.
3. Route `wid/wctl` (7.1 §4). Smallest remaining mutation, red arm available.
4. Route `open`/existence and the three read leaves that answer the enumeration
   question — `dir`, `wid/ctl`, `wid/wctl` reads — under stage 4's tier rule
   (7.1 §2). This is the big one, and `wsys_enum_policy.sh` gets three new arms
   that are red today, as this section's probe shows.
5. Move `pointer`/`event`/`text`/`cmd` to per-window channels on the `keys`
   construction (7.1 §3).
6. Tier 2's remainder — `/srv/wsys.bb` and `/srv/wsys.img` — which is an
   allocator rewrite, not a change of where a pointer points.
7. Delete the fallbacks and `srv_enabled()` (7.1 §5, §6); stop mapping the
   segment in clients; stand up the refusal stub (7.2).
8. `WSYS_VERSION` 8 → 9, in the same commit as step 7 and never before it —
   until the old path is gone the bump refuses clients for a boundary that is
   not yet enforced.

**Steps 4, 5 and 6 are the tier-1/tier-2 work whose blockers (1)–(3) have been
recorded in `user/linux-wsys.c` since before this server existed and are still
unresolved.** The six stages above did not go around them; they built the
transport and the policy that tier 1 will need. Stage 7 is where they are paid.
