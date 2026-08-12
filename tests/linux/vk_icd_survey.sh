#!/usr/bin/env bash
# tests/linux/vk_icd_survey.sh — which Vulkan implementations can this machine
# actually reach, and is any of them a GPU?
#
# WHY THIS EXISTS. `docs/vk_linux_backend.md` says the GPU backend has never
# been measured on a GPU because this host has exactly one, it belongs to
# someone, and venus does not come up. Every part of that sentence is a claim
# about the MACHINE, not about the code — and a claim about the machine goes
# stale the moment someone plugs in a card, changes a kernel parameter or runs
# this on a laptop. So it is a script, and it is re-runnable in five seconds.
#
# HOW IT NEVER TOUCHES THE HOST GPU, which is the standing rule here. Each ICD
# is enumerated inside a private mount namespace with a `tmpfs` mounted over
# `/dev/dri`, so the render nodes are not merely avoided by convention — they
# are not in the file system the probe can see. `nvidia_icd.json` is not run at
# all: it reaches the GPU through `/dev/nvidiactl`, which masking /dev/dri does
# not cover, and it is the one ICD whose device is known to belong to the
# machine's owner.
#
# WHAT IT PRINTS, and what each answer means:
#   SILICON   a real GPU is reachable -> run scripts/bench_vk_linux_device.sh
#             against that ICD; the last big unknown in the graphics stack is
#             one command away.
#   CPU-ONLY  EVERY ICD on this host was run and every one is a CPU
#             rasterizer. Correctness can be gated (scripts/test_vk_linux.sh);
#             performance cannot be measured.
#   NONE      no Vulkan at all; the backend will refuse and stay software,
#             which is the behaviour scripts/test_vk_linux.sh asserts.
#   UNDETERMINED
#             some ICD was NOT RUN (nvidia_icd.json always is not), so nothing
#             here is a statement about this machine's hardware. See the note
#             above the summary — this verdict exists because the old script
#             printed CPU-ONLY on a box with an RTX 3090 in it.
#
# This is a SURVEY, not a gate: it exits 0 whatever it finds. The finding is
# the output.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

WORK="$(mktemp -d -p "${TMPDIR:-/tmp}" icdsurvey.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
# A bare EXIT trap does not run when the shell is killed by a signal, so a
# gate stopped by `timeout` (TERM) or ^C (INT) skipped its cleanup entirely.
# Re-exit on those, which makes the EXIT trap above run on every path out.
trap 'exit 130' INT TERM HUP

command -v cc >/dev/null 2>&1 || { echo "SKIP: no cc"; exit 0; }
ls /usr/lib/x86_64-linux-gnu/libvulkan.so.1 >/dev/null 2>&1 || {
    echo "[icdsurvey] NONE — no libvulkan.so.1 on this host"; exit 0; }

cat > "$WORK/probe.c" <<'C'
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
typedef void *VkInstance; typedef void *VkPhysicalDevice;
struct AppInfo { uint32_t sType; const void*pNext; const char*pApp; uint32_t appv;
                 const char*pEng; uint32_t engv; uint32_t api; };
struct CreateInfo { uint32_t sType; const void*pNext; uint32_t flags;
                    const struct AppInfo*pApp; uint32_t nLayer; const char*const*ppLayer;
                    uint32_t nExt; const char*const*ppExt; };
struct Props { uint32_t apiVersion, driverVersion, vendorID, deviceID, deviceType;
               char deviceName[256]; uint8_t uuid[16]; uint8_t limits[4096]; };
int main(void) {
    void *h = dlopen("libvulkan.so.1", RTLD_NOW);
    if (!h) { printf("no-libvulkan\n"); return 1; }
    int32_t (*cre)(const struct CreateInfo*, const void*, VkInstance*) = dlsym(h, "vkCreateInstance");
    int32_t (*enu)(VkInstance, uint32_t*, VkPhysicalDevice*) = dlsym(h, "vkEnumeratePhysicalDevices");
    void (*props)(VkPhysicalDevice, struct Props*) = dlsym(h, "vkGetPhysicalDeviceProperties");
    if (!cre || !enu || !props) { printf("missing-symbols\n"); return 2; }
    struct AppInfo ai; memset(&ai,0,sizeof ai); ai.pApp="icdsurvey"; ai.api=(1u<<22)|(1u<<12);
    struct CreateInfo ci; memset(&ci,0,sizeof ci); ci.sType=1; ci.pApp=&ai;
    VkInstance inst=0; int32_t r=cre(&ci,0,&inst);
    if (r) { printf("no-instance (VkResult %d)\n", r); return 3; }
    uint32_t n=0; r = enu(inst,&n,0);
    if (r) { printf("no-device (vkEnumeratePhysicalDevices -> VkResult %d)\n", r); return 4; }
    if (!n) { printf("no-device (0 physical devices)\n"); return 5; }
    VkPhysicalDevice pd[8]; if (n>8) n=8; enu(inst,&n,pd);
    for (uint32_t i=0;i<n;i++){ struct Props p; memset(&p,0,sizeof p); props(pd[i],&p);
        printf("DEVICE type %u  %s\n", p.deviceType, p.deviceName); }
    return 0;
}
C
cc -O1 -o "$WORK/probe" "$WORK/probe.c" -ldl 2>/dev/null || {
    echo "SKIP: could not build the probe"; exit 0; }

# Can we make a private mount namespace? Without one we would have to run the
# probe against the real /dev/dri, and this script will not do that.
unshare -Urm --map-root-user /bin/true 2>/dev/null || {
    echo "SKIP: no user+mount namespace here, and this survey refuses to"
    echo "      enumerate against the host's real /dev/dri"; exit 0; }

echo "[icdsurvey] DRM devices on this host (from sysfs; no device is opened):"
for c in /sys/class/drm/card*; do
    [ -e "$c" ] || continue
    case "$c" in *-*) continue;; esac   # cardN-<connector> entries, listed below
    drv="$(basename "$(readlink -f "$c/device/driver" 2>/dev/null)" 2>/dev/null)"
    conn="$(ls -d "$c"-* 2>/dev/null | wc -l)"
    echo "[icdsurvey]   $(basename "$c"): driver ${drv:-?}, $conn KMS connector(s)"
    # A DRM driver with no connectors has no modesetting -- on NVIDIA that is
    # nvidia-drm.modeset=0, which is exactly what stops QEMU's venus path.
    [ "$conn" = "0" ] && echo "[icdsurvey]     ^ no connectors: this driver is not modesetting"
done

best=none
skipped=""
nskipped=0
for J in /usr/share/vulkan/icd.d/*.json; do
    b="$(basename "$J")"
    case "$b" in
        nvidia_icd.json)
            echo "[icdsurvey] $b: NOT RUN (reaches the GPU through /dev/nvidiactl)"
            skipped="$skipped $b"; nskipped=$((nskipped+1))
            continue;;
    esac
    out="$(unshare -Urm --map-root-user /bin/sh -c \
        "mount -t tmpfs none /dev/dri 2>/dev/null; VK_ICD_FILENAMES=$J $WORK/probe" 2>/dev/null)"
    printf '[icdsurvey] %-24s %s\n' "$b" "$(echo "$out" | head -1)"
    case "$out" in
        *"DEVICE type 4"*) [ "$best" = none ] && best=cpu;;
        *"DEVICE type "*)  best=silicon;;
    esac
done

# THE SUMMARY MUST DESCRIBE WHAT WAS RUN, NOT WHAT IS PLUGGED IN.
#
# This line used to read `CPU-ONLY — correctness is gateable, performance is
# not` on a machine with an RTX 3090 in it, because the survey SKIPS
# nvidia_icd.json by design and then summarised as though the skip had been a
# result. That sentence was quoted for months as a fact about the hardware and
# it was a fact about this script's own for-loop. The GPU was reachable the
# whole time; the 33 ms text frame that went unexplained until it was finally
# measured was one command away.
#
# So: any ICD that was not run makes the verdict UNDETERMINED, by name. A
# survey may report "I did not look"; it may never report "there is nothing
# there" on the strength of not having looked.
case "$best" in
  silicon) echo "[icdsurvey] SILICON — run: scripts/bench_vk_linux_device.sh with that ICD";;
  cpu)
    if [ "$nskipped" -gt 0 ]; then
        echo "[icdsurvey] UNDETERMINED — every ICD this survey RAN is a CPU"
        echo "[icdsurvey]   rasterizer, but it did not run:$skipped"
        echo "[icdsurvey]   This says nothing about whether this machine has a"
        echo "[icdsurvey]   GPU. To find out, with the machine owner's consent:"
        for s in $skipped; do
            echo "[icdsurvey]     VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/$s \\"
            echo "[icdsurvey]         scripts/bench_vk_linux_device.sh"
        done
    else
        echo "[icdsurvey] CPU-ONLY — every ICD on this host was run and every"
        echo "[icdsurvey]   one is a CPU rasterizer: correctness is gateable,"
        echo "[icdsurvey]   performance is not"
    fi;;
  *)
    if [ "$nskipped" -gt 0 ]; then
        echo "[icdsurvey] UNDETERMINED — no ICD this survey RAN produced a"
        echo "[icdsurvey]   device, and it did not run:$skipped"
    else
        echo "[icdsurvey] NONE — the backend will refuse and stay software"
    fi;;
esac
exit 0
