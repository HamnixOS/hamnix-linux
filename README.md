# hamnix-linux

**This is the Linux-kernel sibling of Hamnix. It builds, it boots, and it
installs itself from a package channel. Hamnix 1.0 lives elsewhere.**

- Hamnix 1.0 — the from-scratch x86_64 OS, zero lines of C in the kernel:
  [HamnixOS/Hamnix](https://github.com/HamnixOS/Hamnix) (tagged `v1.0`)
- The Adder language and compiler:
  [HamnixOS/adder](https://github.com/HamnixOS/adder)

## What this is

The same Adder userland — 364 applications, the `hamsh` shell, the `hamui`
toolkit, the `hamUId` compositor, the `hpm` package manager, and the `lib/`
libraries including a from-scratch web engine — retargeted from the Hamnix
native kernel onto the **Linux kernel with glibc**. The point is to get drivers,
Wi-Fi, GPU and a real browser for free, on hardware Hamnix will not support for
years.

It is **not a successor**. Hamnix 1.0 keeps its version number and its purity
claim. These two lines are siblings in the way Debian GNU/Hurd is a sibling of
Debian, not a later release of it.

## Status

**It runs.** 114 applications build and are packaged; a machine installs from
`https://255.one/` with `hpm`, boots to an Adder PID 1, and comes up in a
desktop — panel, taskbar, wallpaper, an applications menu, a file manager, a
terminal and a web browser that renders pages. The current release is **1.0.22**
and the changelog names what each one changed for someone using the machine.

    hpm refresh https://255.one/
    hpm install hamnix-base

The Plan 9 syscall surface the userland assumes — `bind`, per-process
namespaces, `/net` as a file tree, `/dev/wsys` as a window file server — is
implemented on top of Linux rather than removed from the applications, which is
why they are still the same programs. The port stays a reviewable diff.

**Where it is actually exercised, stated plainly, because "it runs" invites the
wrong picture:**

- **VM and hybrid development are primary.** Everything below is measured under
  QEMU or offscreen against a framebuffer file, which is also how the gates in
  `tests/linux/` run.
- **Real hardware is untested.** No claim is made about booting a physical
  machine: not the installer on real disks, not real GPUs, not Wi-Fi, not
  suspend. The drivers come from Linux, which is the point of the port, but
  nobody has sat in front of it on bare metal. (The Vulkan backend *has* been
  measured against a real discrete GPU — but on the developer's host, in the
  hybrid mode above, not on a machine this system booted. That is a different
  claim and is not this one.)
- **Native install is in progress.** A machine can install and update itself
  from the channel; the path from bare firmware to that state is not finished.

Known-broken things are kept in the changelog under "measured and refused" and
in `HANDOFF.md` under "What is HONESTLY BROKEN right now", because a status
section that lists only what works is the failure this project exists to beat.

**Start with [`HANDOFF.md`](HANDOFF.md).** It is the complete brief: what was
copied, what was left behind, every native-only surface enumerated with file
paths, the applications ranked by porting difficulty, and the open questions.

## Toolchain

The Adder compiler is a **git submodule** at `adder/`, with a `compiler`
symlink at the root pointing into it (the same layout the Hamnix tree uses, so
every build script resolves unchanged).

```sh
git clone --recurse-submodules https://github.com/HamnixOS/hamnix-linux.git
# or, in an existing clone:
git submodule update --init --recursive
```

A submodule rather than a documented dependency because Adder is young and its
codegen still moves: the userland must be pinned to the exact compiler revision
that built it, so that "which compiler miscompiled this" stays an answerable
question. It is also how this tree was originally laid out — `adder/` was a
submodule in Hamnix's history before it was folded in.

Smoke-test that the toolchain resolves:

```sh
printf 'def main() -> int32:\n    return 7\n' > _smoke.ad
python3 -m compiler.adder compile --target=x86_64-linux ./_smoke.ad -o /tmp/smoke
/tmp/smoke; echo $?   # 7
rm _smoke.ad
```

`--target=x86_64-linux` already exists and works — it emits a static, no-libc
Linux ELF. `user/linux-runtime.S` is the Linux link runtime, and it already maps
about 30 of the ~48 `sys_*` entry points onto real Linux syscalls. The remaining
18 are fail-closed stubs that return −1. Those stubs are the port.

## Layout

| Path | What |
|--|--|
| `user/` | 364 applications + `hamsh`, `hamUId`, `hpm`; the Linux/Hamnix link runtimes and linker scripts |
| `lib/` | 167 modules — toolkit, web engine (`lib/web/`), Vulkan (`lib/vk/`), codecs, crypto |
| `scripts/` | build and test glue, copied wholesale |
| `tests/` | test fixtures and gates, copied wholesale |
| `docs/` | the Hamnix design docs, copied wholesale |
| `etc/`, `fonts/`, `Sounds/`, `examples/` | userland data |
| `adder/` | the compiler (submodule) |

`scripts/`, `tests/` and `docs/` carry kernel-only entries that are dead here.
They were kept rather than pruned because the build glue and the design
documents are needed, and hand-separating ~1800 scripts would have silently
dropped things. Pruning them is legitimate early work.

**Nothing in `docs/` overrides the Status section above.** Several of those
copied documents — `docs/REAL_HARDWARE.md`, `docs/BOOT.md`, `docs/manual/` —
record real-hardware boots and an installer workflow, and every one of them is
about **Hamnix 1.0's own kernel**, not this port. Each now says so at the top.

## Licence

GPL-3.0-or-later, same as Hamnix. See [`LICENSE`](LICENSE).
