/* dmabufprobe.c — DOES THIS ICD EXPORT A DMA-BUF, AND CAN KMS SCAN IT OUT?
 *
 * Four questions, each answered with an errno rather than an opinion:
 *   1. does the instance/device advertise the external-memory extensions?
 *   2. can a buffer be allocated with an export handle type of DMA_BUF?
 *   3. does vkGetMemoryFdKHR hand back a real fd?
 *   4. will DRM take that fd as a framebuffer (PRIME import + ADDFB2)?
 *
 * (4) only IMPORTS and creates an FB object. It takes NO master and does NO
 * modeset, so it cannot disturb the console.
 */
#include "linux-vk.c"

#include <errno.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO   1000072002
#define VK_STRUCTURE_TYPE_MEMORY_GET_FD_INFO_KHR        1000074002
#define VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_BUFFER_CREATE_INFO 1000072000
#define VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT  0x200
#define VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT    0x1

typedef struct {
    uint32_t sType; const void* pNext; uint32_t handleTypes;
} ExportMemoryAllocateInfo;
typedef struct {
    uint32_t sType; const void* pNext; uint32_t handleTypes;
} ExternalMemoryBufferCreateInfo;
typedef struct {
    uint32_t sType; const void* pNext; VkDeviceMemory memory; uint32_t handleType;
} MemoryGetFdInfoKHR;
typedef struct {
    uint32_t sType; const void* pNext; VkFlags flags;
    VkDeviceSize size; VkFlags usage; uint32_t sharingMode;
    uint32_t queueFamilyIndexCount; const uint32_t* pQueueFamilyIndices;
} BufCI;

typedef struct { char extensionName[256]; uint32_t specVersion; } ExtProps;

int main(void)
{
    if (!hvk_available()) { printf("no device: %s\n", g_err); return 1; }
    uint8_t nm[256]; hvk_device_name(nm, sizeof nm);
    printf("device: %s\n", nm);

    /* ---- 1. the extensions, as the driver reports them ---- */
    VkResult (*p_enumDevExt)(VkPhysicalDevice, const char*, uint32_t*, ExtProps*);
    *(void**)(&p_enumDevExt) = dlsym(g_lib, "vkEnumerateDeviceExtensionProperties");
    int has_extmem = 0, has_extmemfd = 0, has_dmabuf = 0;
    if (p_enumDevExt) {
        uint32_t n = 0;
        p_enumDevExt(g_phys, 0, &n, 0);
        ExtProps* e = calloc(n, sizeof *e);
        p_enumDevExt(g_phys, 0, &n, e);
        printf("\n---- device extensions relevant to export (%u total) ----\n", n);
        for (uint32_t i = 0; i < n; i++) {
            if (!strcmp(e[i].extensionName, "VK_KHR_external_memory")) has_extmem = 1;
            if (!strcmp(e[i].extensionName, "VK_KHR_external_memory_fd")) has_extmemfd = 1;
            if (!strcmp(e[i].extensionName, "VK_EXT_external_memory_dma_buf")) has_dmabuf = 1;
            if (strstr(e[i].extensionName, "external_memory") ||
                strstr(e[i].extensionName, "dma_buf") ||
                strstr(e[i].extensionName, "drm") ||
                strstr(e[i].extensionName, "image_drm"))
                printf("   %s (v%u)\n", e[i].extensionName, e[i].specVersion);
        }
        free(e);
    } else printf("no vkEnumerateDeviceExtensionProperties\n");
    printf("  VK_KHR_external_memory        : %s\n", has_extmem ? "YES" : "no");
    printf("  VK_KHR_external_memory_fd     : %s\n", has_extmemfd ? "YES" : "no");
    printf("  VK_EXT_external_memory_dma_buf: %s\n", has_dmabuf ? "YES" : "no");

    /* The device this backend created was made WITHOUT those extensions
     * enabled, so an export off g_dev would fail for that reason alone and
     * tell us nothing. Make a second device that DOES enable them. */
    printf("\n---- a second VkDevice with the export extensions enabled ----\n");
    if (!has_extmemfd || !has_dmabuf) {
        printf("  cannot: the driver does not advertise them\n");
        return 0;
    }
    const char* exts[] = { "VK_KHR_external_memory", "VK_KHR_external_memory_fd",
                           "VK_EXT_external_memory_dma_buf" };
    float prio = 1.0f;
    VkDeviceQueueCreateInfo qi;
    memset(&qi, 0, sizeof qi);
    qi.sType = ST_DEVICE_QUEUE_CREATE_INFO;
    qi.queueFamilyIndex = g_qfam;
    qi.queueCount = 1;
    qi.pQueuePriorities = &prio;
    VkDeviceCreateInfo dci;
    memset(&dci, 0, sizeof dci);
    dci.sType = ST_DEVICE_CREATE_INFO;
    dci.queueCreateInfoCount = 1;
    dci.pQueueCreateInfos = &qi;
    dci.enabledExtensionCount = 3;
    dci.ppEnabledExtensionNames = exts;
    VkDevice dev2 = 0;
    VkResult r = p_vkCreateDevice(g_phys, &dci, 0, &dev2);
    printf("  vkCreateDevice -> %d %s\n", (int)r, r == VK_SUCCESS ? "OK" : "FAILED");
    if (r != VK_SUCCESS) return 0;

    /* ---- 2/3. allocate exportable, then export ---- */
    const uint32_t W = 1920, H = 1080, PITCH = W * 4;
    VkDeviceSize sz = (VkDeviceSize)PITCH * H;
    ExternalMemoryBufferCreateInfo ext;
    memset(&ext, 0, sizeof ext);
    ext.sType = VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_BUFFER_CREATE_INFO;
    ext.handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT;
    BufCI bc;
    memset(&bc, 0, sizeof bc);
    bc.sType = ST_BUFFER_CREATE_INFO;
    bc.pNext = &ext;
    bc.size = sz;
    bc.usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT
             | VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    bc.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    VkBuffer buf = 0;
    r = p_vkCreateBuffer(dev2, (VkBufferCreateInfo*)&bc, 0, &buf);
    printf("  vkCreateBuffer(exportable, %u KiB) -> %d\n", (unsigned)(sz/1024), (int)r);
    if (r != VK_SUCCESS) return 0;
    VkMemoryRequirements mr;
    memset(&mr, 0, sizeof mr);
    p_vkGetBufferMemoryRequirements(dev2, buf, &mr);
    int mt = find_mem(mr.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    printf("  device-local memtype for it: %d\n", mt);
    if (mt < 0) return 0;
    ExportMemoryAllocateInfo eai;
    memset(&eai, 0, sizeof eai);
    eai.sType = VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO;
    eai.handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT;
    VkMemoryAllocateInfo ai;
    memset(&ai, 0, sizeof ai);
    ai.sType = ST_MEMORY_ALLOCATE_INFO;
    ai.pNext = &eai;
    ai.allocationSize = mr.size;
    ai.memoryTypeIndex = (uint32_t)mt;
    VkDeviceMemory mem = 0;
    r = p_vkAllocateMemory(dev2, &ai, 0, &mem);
    printf("  vkAllocateMemory(exportable DMA_BUF) -> %d %s\n", (int)r,
           r == VK_SUCCESS ? "OK" : "FAILED");
    if (r != VK_SUCCESS) return 0;

    VkResult (*p_getfd)(VkDevice, const MemoryGetFdInfoKHR*, int*);
    *(void**)(&p_getfd) = dlsym(g_lib, "vkGetMemoryFdKHR");
    if (!p_getfd) {
        VkResult (*p_gdpa_get)(void) = 0; (void)p_gdpa_get;
        void* (*p_gdpa)(VkDevice, const char*);
        *(void**)(&p_gdpa) = dlsym(g_lib, "vkGetDeviceProcAddr");
        if (p_gdpa) *(void**)(&p_getfd) = p_gdpa(dev2, "vkGetMemoryFdKHR");
    }
    if (!p_getfd) { printf("  no vkGetMemoryFdKHR entry point\n"); return 0; }
    MemoryGetFdInfoKHR gi;
    memset(&gi, 0, sizeof gi);
    gi.sType = VK_STRUCTURE_TYPE_MEMORY_GET_FD_INFO_KHR;
    gi.memory = mem;
    gi.handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT;
    int fd = -1;
    r = p_getfd(dev2, &gi, &fd);
    printf("  vkGetMemoryFdKHR(DMA_BUF) -> %d, fd %d %s\n", (int)r, fd,
           (r == VK_SUCCESS && fd >= 0) ? "*** A REAL DMA-BUF ***" : "FAILED");
    if (r != VK_SUCCESS || fd < 0) return 0;
    printf("  dmabuf size via lseek(END): %lld bytes\n",
           (long long)lseek(fd, 0, SEEK_END));

    /* ---- 4. will DRM import it and make a framebuffer of it? ---- */
    printf("\n---- DRM PRIME import + ADDFB2 (no master, no modeset) ----\n");
    int drm = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
    if (drm < 0) { printf("  open card0: %s\n", strerror(errno)); return 0; }
    /* struct drm_prime_handle is { __u32 handle; __u32 flags; __s32 fd; } --
     * IN THAT ORDER. The first version of this probe had it reversed, which
     * made a perfectly good dmabuf come back EINVAL and would have been
     * written up as "nvidia will not import its own buffer". */
    struct { uint32_t handle; uint32_t flags; int32_t fd; } prime = { 0, 0, fd };
    if (ioctl(drm, 0xc00c642e /* DRM_IOCTL_PRIME_FD_TO_HANDLE */, &prime) < 0)
        printf("  PRIME_FD_TO_HANDLE: %s\n", strerror(errno));
    else {
        printf("  PRIME_FD_TO_HANDLE -> gem handle %u  *** IMPORTED ***\n", prime.handle);
        struct {
            uint32_t fb_id, width, height, pixel_format, flags;
            uint32_t handles[4], pitches[4], offsets[4];
            uint64_t modifier[4];
        } fb;
        memset(&fb, 0, sizeof fb);
        fb.width = W; fb.height = H;
        fb.pixel_format = ('X') | ('R' << 8) | ('2' << 16) | ('4' << 24); /* XR24 */
        fb.handles[0] = prime.handle;
        fb.pitches[0] = PITCH;
        if (ioctl(drm, 0xc06464b8 /* DRM_IOCTL_MODE_ADDFB2: DRM_IOWR(0xB8, 100 bytes) */, &fb) < 0)
            printf("  ADDFB2: %s\n", strerror(errno));
        else
            printf("  ADDFB2 -> fb_id %u  *** SCANOUT-CAPABLE FRAMEBUFFER ***\n", fb.fb_id);
    }
    close(drm);
    close(fd);
    return 0;
}
