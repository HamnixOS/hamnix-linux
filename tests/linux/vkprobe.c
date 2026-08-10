/* Feasibility probe: can an LLVM-lane Adder binary reach real Vulkan? */
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
int32_t vkprobe(void) {
    void *h = dlopen("libvulkan.so.1", RTLD_NOW);
    if (!h) { printf("vkprobe: no libvulkan: %s\n", dlerror()); return -1; }
    int32_t (*cre)(const struct CreateInfo*, const void*, VkInstance*) = dlsym(h, "vkCreateInstance");
    int32_t (*enu)(VkInstance, uint32_t*, VkPhysicalDevice*) = dlsym(h, "vkEnumeratePhysicalDevices");
    void (*props)(VkPhysicalDevice, struct Props*) = dlsym(h, "vkGetPhysicalDeviceProperties");
    if (!cre || !enu || !props) { printf("vkprobe: missing symbols\n"); return -2; }
    struct AppInfo ai; memset(&ai,0,sizeof ai); ai.sType=0; ai.pApp="hamnix"; ai.api=(1u<<22)|(1u<<12);
    struct CreateInfo ci; memset(&ci,0,sizeof ci); ci.sType=1; ci.pApp=&ai;
    VkInstance inst=0; int32_t r=cre(&ci,0,&inst);
    if (r) { printf("vkprobe: vkCreateInstance = %d\n", r); return r; }
    uint32_t n=0; enu(inst,&n,0);
    printf("vkprobe: instance ok, %u physical device(s)\n", n);
    VkPhysicalDevice pd[8]; if (n>8) n=8; enu(inst,&n,pd);
    for (uint32_t i=0;i<n;i++){ struct Props p; memset(&p,0,sizeof p); props(pd[i],&p);
        printf("vkprobe:   [%u] %s  api %u.%u.%u  type %u\n", i, p.deviceName,
               p.apiVersion>>22,(p.apiVersion>>12)&0x3ff,p.apiVersion&0xfff, p.deviceType); }
    return (int32_t)n;
}
