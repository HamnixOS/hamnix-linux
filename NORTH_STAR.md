# NORTH STAR — what hamnix-linux is for

Read `HANDOFF.md` §0 for where the work stands. This file is the *destination*,
stated by the person it is being built for. It changes rarely; `HANDOFF.md`
changes constantly.

---

## The goal

**A completely usable Linux distribution that competes directly with other
Linux distributions.** Not a demo, not a research vehicle, not a shape-of-the-
thing. Someone installs it on a real machine and uses it.

That someone is the person who commissioned it, which is the whole quality
bar: *"I think this is going to be used by someone, and that someone is me, so
it needs to work well."*

## The shape

**Hamnix's, which is Plan 9's.** The kernel is Linux; everything above it is
Hamnix's own — the init, the shell, the file servers, the namespaces, the
window system, the desktop, the package manager, all written in Adder.

The Plan 9 vocabulary is kept deliberately, not decoratively. `bind` performs
a real `mount(2)`; `rfork(RFNAMEG)` is `unshare(CLONE_NEWMOUNT)`; a write to
`/proc/<pid>/note` is a `kill(2)`. The rc scripts say what they mean and do
not need to know which kernel is underneath. That property is worth
protecting: it is what makes the same userland run on either kernel.

**Everything is a file server.** `/dev/wsys`, `/net`, `/fd`, `/dev/auth` are
each the faithful port of a Hamnix kernel device, and what crosses a process
boundary is a *name* or a *number*, never a descriptor.

## Where it is going

**Multiple distribution namespaces.** Debian is the first, not the only one.
`enter debian { sh }` is the command; `enter fedora { … }`, `enter arch { … }`
are the same mechanism with a different subtree server behind `#distro`.

**Qubes-like, leaning Plan 9.** The isolation Qubes gets from hypervisors,
this gets from namespaces and file servers — cheaper, more composable, and
addressable by name. A namespace is something you *describe* and then enter,
not a VM you boot. `ns clean { … }` is a description; nothing is granted by
capturing it.

## The standard of evidence

This is written down because it is the single most repeated lesson of the port,
and it has its own running list in `HANDOFF.md` §0:

> **A gap must never answer something success-shaped instead of the truth.**

The failures that cost the most time here were never crashes. They were
`ps` exiting 0 having listed nothing; `hpm install a b c` silently dropping
`b` and `c`; a shell redirect that created the file, printed to the console
and exited 0; `enter debian { steam }` running a Hamnix binary in the native
root and reporting success; a lock screen covering 53% of the display. Each
looked like it worked.

So: a thing that cannot work here **fails loudly and by name**. A default is
never a substitute for an answer. And a measurement is worth more than an
argument — including an argument made by the person writing this file.

## Standing constraints

- **Never touch `HamnixOS/Hamnix`.** It is frozen at v1.0 and is the read-only
  reference (`~/Hamnix`). Consult it freely; never write, never push.
- **Never touch the dev host's real `/dev/dri`, `/dev/nvidia*`, or display**
  without the machine owner saying so. Test in the VM, or offscreen with
  `HAMFB_FILE`. Host-side Vulkan is forced to the software ICD.
- Work on a branch. Commit as you go, with real messages. Do not force-push.
- `https://255.one/` is the package repository, served from `HamnixOS/packages`
  (GitHub Pages). Publishing there is authorized.
