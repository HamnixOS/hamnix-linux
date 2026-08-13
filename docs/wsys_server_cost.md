# Could `/dev/wsys` be a userland file server? — the measurement

`/dev/wsys` is in-process: `linux-wsys.c` is linked into every binary, so a
client's write is a function call into shared memory. That is where the ~0.3 ms
input-to-pixel comes from, and it is also why there is no privilege boundary
*inside* the object — the same-uid pixel scrape, "enumeration is open by
design", and `win_alloc` racing two clients onto one row are all the same
absence.

**This does not build the server. It prices it.** Instruments:
`tests/linux/wsys_op_census.sh` (denominator), `tests/linux/wsys_rtt_probe.c`
(per-operation), `tests/linux/opcount_selftest.sh` (proves the counter).

Both instruments were required to be able to report a number that kills the
idea. The counter must show a large rate on a load known to be large (it does:
1744 ops/s on a free-running drag). The probe must see a slow server: injected
a known 200 µs server delay, it measured 274 µs.

## 1. The denominator — how many operations a real session performs

Median of the per-second series, offscreen, per client. Every op counted is one
that would become a round trip: in a file server an open, a read and a write are
each a message.

| load | client ops/s | worst 10 ms burst |
|---|---|---|
| idle | **1016** (panel 1000, desktop 16) | 24 (=2400/s) |
| pointer, 250 ev/s | 1992 (desktop 976, panel 1016) | 24 (=2400/s) |
| drag, mouse-paced | 1514 (drag 420, panel 1078) | 25 (=2500/s) |
| drag, free-running | 2930 (drag 1836, panel 1078) | 32 (=3200/s) |
| app start, first 3 s | 1838 | 32 (=3200/s) |

**The compositor's own traffic is excluded and must be** — 1069 idle, 5043
under pointer, 17480 under a free-running drag. In a file-server world wsysd
*is* the server and those become internal calls again. Folding them in would
inflate the drag by 6x and condemn the design for the wrong reason.

**The answer to "is it 250 or 50,000" is: about 1,000–3,000, and it is not the
drag.** A drag paced like an actual mouse adds only 420 ops/s. **An idle
desktop already does ~1000, essentially all of it `hampanelscene`** — polling:
`sink` open+read 225/s, `wid/event` open+read 225/s, `windows` 56/s. Its actual
work — `wid/scene` and `wid/ctl` writes — is about 6/s each.

## 2. The per-operation cost

`socketpair(AF_UNIX, SOCK_SEQPACKET)`, real payloads (`version 2`, a geometry
change, a commit, a title set), and a server side that *mediates* rather than
echoes: parse the verb, bounds-check, look the window up, refuse anything that
is not the caller's. Three runs, p50, all shown.

| arm | p50 | p99 |
|---|---|---|
| round trip, sequential | **6.34 / 6.19 / 6.33 µs** | 7.2–12.7 µs |
| round trip, burst of 16 | **2.33 / 2.27 / 2.31 µs** per op | 2.5–3.3 µs |
| in-process, same work | **0.14 / 0.13 / 0.13 µs** | 0.36 µs |

**The burst case is the best, not the worst — the one prediction here that came
out backwards.** A round trip per operation was expected to hurt most when a
client issues many small control writes; instead pipelining the requests and
collecting the replies afterwards amortises the wait, and per-op cost falls
from 6.30 µs (burst 1) to 3.14 (burst 4), 2.31 (burst 16), 2.37 (burst 64). It
saturates around 2.3 µs. **The expensive pattern is strict request-reply, not
volume** — which means the protocol should let a client fire and check later
wherever it does not need the answer.

## 3. The arithmetic

Added cost per op = round trip − in-process ≈ **6.2 µs** (sequential) or
**2.2 µs** (pipelined).

| load | ops/s | added CPU, sequential | pipelined |
|---|---|---|---|
| idle | 1016 | **0.63% of a core** | 0.22% |
| pointer 250 ev/s | 1992 | 1.24% | 0.44% |
| drag, mouse-paced | 1514 | 0.94% | 0.33% |
| drag, free-running | 2930 | 1.82% | 0.64% |
| app start | 1838 | 1.14% | 0.40% |

Worst burst: 32 ops inside 10 ms = 202 µs, 2% of that window.

**Latency.** input→pixel is 0.29–0.36 ms measured. Each round trip on the
critical path adds 6.3 µs, so a client repaint that reads an event, writes a
scene and commits — 3 ops — adds **~19 µs, about 5% of the current figure**.

**A drag at 250 fps**: mouse-paced, the drag client does 420 ops/s = 1.7 ops per
frame = **10.6 µs on a 4 ms frame, 0.27%**.

## 4. What does not cross the boundary — confirmed, not assumed

Pixels travel by per-window `memfd`, created by the owner and handed up
(`bb_own_fd`, `MFD_CLOEXEC | MFD_ALLOW_SEALING`); the shared file keeps only
pool accounting. So a frame's bulk never becomes a message.

**Checked empirically as well as in the source**: across 12 s of idle desktop,
`wid/backbuffer` does not appear in either client's leaf breakdown at all — zero
operations, while `sink` and `wid/event` do thousands. The largest payload that
*would* cross is a scene display list, which is capped at 16 KiB, at ~6/s.

## The answer

**A userland file server is affordable on every load measured.** The worst is
under 2% of a core, and about 5% added input-to-pixel. The denominator is
~1,000–3,000 ops/s, not 50,000, and the drag — the load everyone expected to
decide it — is the cheapest thing on the list.

**But the cost is concentrated in the wrong place, and that is the finding.**
An *idle* desktop is 1016 ops/s, and 1000 of them are one client polling. In
process that is 0.13 ms/s and invisible; mediated it is 0.63% of a core, and
measured idle wsysd CPU is 0.5–0.6% — **so the boundary would roughly double
the cost of a desktop doing nothing**, entirely because of a poll loop that
should not exist. That is worth fixing whatever is decided here; it is the
difference between the server costing nothing at idle and costing as much as
the compositor.

**Where a hybrid would help, if one is wanted.** The traffic splits cleanly:
`windows`, `screen` and `sink` are *reads of shared state* and are most of the
volume; `wid/ctl`, `wid/scene` and `ctl` are *mutations* and are ~12/s per
client. Mediating the mutations — which is where the privilege questions
actually live, since that is what `win_alloc` racing and cross-window writes
are — while leaving read-only state mapped, would cost well under 0.1% of a
core and still close the boundary. **The measurement does not force that
choice; it does say that mediating everything is affordable and that mediating
only the mutations is nearly free.**

## Caveats

- Offscreen, software path, this host. The round trip is a local `AF_UNIX`
  socketpair with no scheduler contention from a real session.
- `hampanelscene` belongs to another agent; the 1000 ops/s figure is a
  measurement of it, not a diagnosis of its code.
- No server was built. These are the costs a server *would* pay, not a
  measurement of one.
