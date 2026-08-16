# Changing what an installed machine BOOTS with

`docs/linux_installed_update.md` is about an installed machine taking a package
update. This is about the half that document never asked: whether any of it
reaches the **boot**.

Until `user/bootsync.ad` it did not, on any machine, ever.

---

## 1. The mechanics, as they actually are

Read from the code, and worth stating plainly because three of these five are
easy to get wrong from memory.

**The UKI is built on the host, by `objcopy`, from Debian's EFI stub.**
`scripts/hamlinux_disk.sh` takes `/usr/lib/systemd/boot/efi/linuxx64.efi.stub`
and adds four sections — `.osrel`, `.cmdline`, `.linux`, `.initrd` — at VMAs
derived from the stub's own `SectionAlignment`. The result is
`build/image/disk/BOOTX64.EFI`. If the stub is absent it falls back to the
kernel's own EFI stub, which has no `.initrd` at all and takes its command line
from the firmware.

**Firmware runs exactly one path and there is no second one.**
`\EFI\BOOT\BOOTX64.EFI`, the removable-media path, chosen deliberately so the
same disk boots under OVMF and on a real machine with nothing written to NVRAM.
There is no bootloader, no boot menu and no NVRAM entry. **That means there is
no fallback the firmware can reach if that one file is broken.** It is the
single most important fact on this page.

**`hlinstall` copies that file byte for byte and cannot rewrite it.**
`user/hlinstall.ad:880` copies `/boot/BOOTX64.EFI` onto the target's ESP; the
kernel command line inside it names a `root=PARTUUID=`, so the installer instead
creates the target's root partition *with that GUID*, read from the side file
`/boot/root.partuuid`. The file's own header says it: "Rewriting a PE section
from here is not something this program can do." The comment at
`user/hlinstall.ad:301` describing a fresh-GUID byte patch describes work that
has **not** been done.

**The initramfs comes from `build/image/root`, the same tree as the ext4 root.**
`scripts/hamlinux_image.sh` stages the root and packs it with
`scripts/build_initramfs.py`; `scripts/hamlinux_disk.sh` then copies the *same*
staged tree into the ext4 root filesystem. They start identical and diverge the
moment anything writes to the installed machine.

**`linuxinit` loads modules BEFORE the root switch, from `/etc/modules`, by
absolute path.** `user/linuxinit.ad:454` calls `load_modules()`;
`user/linuxinit.ad:473` does the `bind '#sysroot' /`. So every `.ko` an
installed machine loads at boot is opened out of the **initramfs**, which is a
section of the PE binary on the ESP. `/etc/modules` is one absolute path per
line in dependency order, resolved at image-build time by the host's real
`modprobe` (`scripts/hamlinux_image.sh:802-822`) because there is no `modprobe`
in the initramfs to resolve names. It is read with **one 8192-byte `sys_read`**;
today's list is 65 lines and 4.3 KB, so there is about 2× headroom and no
warning when it is exceeded.

`tests/linux/installed_update_modules.sh` already recorded the consequence, in
its own words: deleting `vfat.ko` from the *disk* and still finding
`vfat ... Live` in `/proc/modules`.

### What that adds up to

`hpm update` upgrades `/lib/modules/<kver>/...` on the ext4 root. `modprobe`
uses the new file from that instant. **The next boot does not.** On the owner's
laptop the boot-time set includes `nvme` (to find the disk at all),
`usb-storage`/`uas`/`xhci_pci` (to read the install stick), and `psmouse`,
`i2c-hid-acpi`, `hid-multitouch` (to have a pointer at all). Those are exactly
the drivers that could not be updated.

---

## 2. Why regenerating a boot image on the machine was never on the table

An installed machine has **no** `objcopy` or any other PE writer, **no** EFI
stub, and **no** cpio writer. `lib/secureboot/authenticode.ad` parses a PE and
never emits one, and it is not built into any hamnix-linux program. The Debian
namespace is absent from an installed machine by default
(`etc/rc.boot.installed:167-179` treats its absence as supported), and even when
present it ships neither `binutils` nor `cpio`. The only Linux tooling
guaranteed on the medium is the three-program `instroot` stub: `sgdisk`,
`mkfs.vfat`, `mkfs.ext4`.

What the machine *does* have is a real DEFLATE encoder (`lib/zlib/deflate.ad`),
a ustar `tar`, `sys_lseek`, and `sys_open_sync` — open an **existing** file
`O_WRONLY|O_SYNC` with no `O_CREAT` and no `O_TRUNC`.

It also has **no `rename(2)`**. There is no such syscall anywhere in the tree;
`user/mv.ad` is copy-then-unlink. So the obvious design — write a new boot image
beside the old one and swap — cannot be done atomically, and on a path where the
firmware will only ever load one filename, a torn swap is a machine that does
not boot with no shell to fix it from.

---

## 3. What was built instead, and why it is safe

The Linux initramfs loader accepts a **concatenation** of archives and the later
one wins. Appending a small **uncompressed** newc cpio segment after the gzipped
one replaces any file it names — the same mechanism the microcode initrd has
used for a decade. That needs no compressor and no PE builder: only a cpio
writer and the ability to move one length field.

So `scripts/hamlinux_disk.sh` **over-allocates** the `.initrd` section by 24 MiB
and then sets the section's `VirtualSize` — the length the EFI stub hands the
kernel — back to the real archive. `SizeOfRawData` stays at the ceiling, which
makes the reservation self-describing (`free = SizeOfRawData - VirtualSize`) and,
decisively, puts the reserved bytes **outside what the current boot reads**.
`/boot/UKI.MAP` carries the shipped archive's length and the boot module list;
`hlinstall` copies it onto the target's ESP.

`user/bootsync.ad` then, on the machine:

1. writes `VirtualSize = BASE`. **From this instant the machine boots the image
   it was installed with** — stale, and bootable;
2. writes the overlay into the reservation, beyond `VirtualSize`, `O_SYNC`;
3. reads it back and compares it against the very files it came from;
4. writes `VirtualSize = BASE + overlay`. Four bytes, one sector.

**The file's length never changes.** No cluster is allocated, the FAT chain is
never mutated, the directory entry is never rewritten — the identical argument
`user/bootlogd.ad` makes for the preallocated boot log, for the identical
reason: FAT32 has no journal and the failure to survive is the power button.

### What a failed regeneration looks like to someone with no shell

**The machine boots, the desktop comes up, and the modules are the ones it was
installed with.** There is nothing on the screen and nothing to fix. That is the
same outcome as never having run it, and it is the whole point: every other
design has a window whose failure mode is a machine that does not boot.

`hpm` says which refusal it was, on the console of the update that ran.

---

## 4. Measured

`tests/linux/bootsync_installed.sh` — **28 PASS / 0 FAIL** from an empty work
directory. Eleven UEFI boots of two 4 GB installed disks under OVMF.

The instrument is `/sys/module/<m>/coresize`: the bytes the module loader
allocated for the module **in the kernel right now**. One boot module on the
ext4 root is grown by a 64 KiB `SHF_ALLOC` section after the initramfs is packed
and before the ext4 root is — exactly the state `hpm update` leaves a machine in.

| | |
|--|--|
| boot 1, before any sync | disk cksum is the new module; **coresize 12288, the old one**. The bug, measured, and the proof the instrument tells the two apart |
| boot 2 | `bootsync`: 65 modules, 16 259 784 bytes into a 25 166 300-byte reservation, read back against the files on the root, committed |
| the medium | the overlay pulled off the ESP with `mcopy` parses as newc, 65 entries, and the module's 77 560 bytes are **byte for byte identical** to the file on the root |
| boot 3 | **coresize 77824 = 12288 + 65536.** No `Initramfs unpacking failed`. The same 64 modules as before |
| twice | `VirtualSize` unchanged after two more runs: the reservation does not creep the way `modules.dep` does at 5.3 KB an update |
| SIGKILL mid-write | 4 256 501 bytes of overlay on the medium, `VirtualSize` at the shipped length; **the machine boots**, coresize 12288, no unpacking failure |
| retry | `bootsync` commits, and the reboot after it is 77824 |
| a 1 MiB reservation | refuses by name; the boot image is byte-identical before and after; the machine boots unchanged |

Two defects were found this way and are recorded where they happened:

* every section offset was written as a **file** offset, putting 16 MB into the
  middle of the live compressed archive. `bootsync` reported "65 modules
  verified" and "committed" because it read back through the same wrong
  arithmetic — and **the machine booted**, loaded all 64 modules and reached the
  desktop, with `Initramfs unpacking failed: junk within compressed archive` at
  t=1.17 s in a log nobody was reading. `check_archive_start()` now refuses
  unless `PointerToRawData` really points at an archive, and the gate asserts
  that kernel line is absent.
* a string literal in an Adder **global initialiser** does not survive to
  runtime: every open failed with `bootsync`'s own "cannot read
  /boot/EFI/BOOT/BOOTX64.EFI" while `cksum </boot/EFI/BOOT/BOOTX64.EFI` at the
  same shell in the same boot read all 67 787 264 bytes.

---

## 5. What this does NOT do, and what is not measured

* **It does not help a machine already installed.** The reservation is created
  when the medium is built. A disk installed from 1.0.25 or earlier media has
  none, and `bootsync` refuses and changes nothing. New media is the only route.
* **It does not change the boot module list**, only the bytes behind the names
  already in it. See `user/bootsync.ad`'s header for why promoting a driver
  package's `/etc/modules` appends to boot modules is a separate decision.
* **It does not touch `/boot/vmlinuz` or `/boot/initramfs.cpio.gz`.** Those are
  the rescue copies on the ESP and nothing boots them. **The kernel itself
  therefore still cannot be updated on an installed machine** — `.linux` is a
  fixed-size section and this mechanism does not move it.
* **Secure Boot.** Moving `VirtualSize` invalidates any Authenticode signature
  over the PE. Nothing in this tree signs the UKI, and no gate boots it under
  Secure Boot firmware — `scripts/test_efi_secureboot.sh` verifies a
  build-generated test blob *inside* the Hamnix kernel with
  `lib/secureboot/authenticode.ad`; it is not this boot path. So nothing
  regresses today, but this mechanism and a signed boot chain are incompatible
  as written and that has to be solved before one exists.
* **The reservation is 24 MiB against a 16.26 MB overlay.** About 50 % headroom.
  If the boot module set grows past it, `bootsync` refuses (measured) and the
  medium has to be rebuilt with `HAMLINUX_INITRD_RESERVE` larger.
* **`/etc/modules`' 8192-byte single-read ceiling is untouched** and is the next
  thing in this area likely to bite: 4.3 KB of 8 KB is used today.
* **No real hardware.** Everything above is QEMU + OVMF. The owner's laptop is
  the case this exists for and it has not been near one.
