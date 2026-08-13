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
4. Remove the in-process path and bump `WSYS_VERSION`. **The bump is the last
   step, not the first**: until the old path is gone the bump would refuse
   clients for a boundary that is not yet enforced.

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

## Budget to hold it to

From the census, at 6.2 µs sequential / 2.2 µs pipelined:

| load | ops/s | added CPU |
|---|---|---|
| idle | 192 | **0.12%** of a core |
| drag, mouse-paced | 618 | 0.38% |
| worst measured | 2050 | 1.27% |

**Input-to-pixel is ~0.3 ms and is now a published claim**, so it is a budget
and not an observation. A client repaint is 3 ops ≈ 19 µs sequential, about 5%
of it. If measured cost exceeds that, the fire-and-forget rule above is the
first thing to check, not the last.
