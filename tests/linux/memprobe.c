/* memprobe.c — WHERE DOES THE COMPOSITE READBACK COST GO?
 *
 * Includes user/linux-vk.c so it gets the whole hand-declared Vulkan ABI and
 * the live device, then measures, for the exact 1280x800x4 = 4 MiB composite:
 *
 *   - what memory types this device actually offers, with their flags
 *   - CPU read bandwidth out of each candidate placement
 *   - the cost of a vkCmdCopyBuffer device-local -> host staging
 *
 * Nothing here renders. Nothing here touches DRM/KMS.
 */
#include "linux-vk.c"

#define VK_MEMORY_PROPERTY_HOST_CACHED_BIT 0x8

/* vkCmdCopyBuffer is not part of the backend's bound subset yet; bind it here
 * so the DMA option can be measured before anything is changed in the tree. */
typedef struct { VkDeviceSize srcOffset, dstOffset, size; } MyBufferCopy;
static void (*p_vkCmdCopyBuffer)(VkCommandBuffer, VkBuffer, VkBuffer,
                                 uint32_t, const MyBufferCopy*);

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

/* A read the compiler cannot delete and the prefetcher cannot skip past:
 * exactly what write(2) does to the mapping (sequential full-cacheline read). */
static volatile uint64_t g_sink;
static double read_bw(const void* p, size_t bytes, int reps, double* per_rep_ms)
{
    const uint64_t* q = (const uint64_t*)p;
    size_t n = bytes / 8;
    double t0 = now_s();
    for (int r = 0; r < reps; r++) {
        uint64_t acc = 0;
        for (size_t i = 0; i < n; i += 8) {
            acc += q[i] + q[i+1] + q[i+2] + q[i+3];
            acc += q[i+4] + q[i+5] + q[i+6] + q[i+7];
        }
        g_sink += acc;
    }
    double dt = now_s() - t0;
    *per_rep_ms = dt * 1000.0 / reps;
    return (double)bytes * reps / dt / 1e9;
}

/* memcpy out, which is what a real fix would do (and what write(2) is). */
static double copy_bw(const void* src, void* dst, size_t bytes, int reps,
                      double* per_rep_ms)
{
    /* The first version of this function reported 4.5 MILLION GB/s, because
     * nothing ever read `dst` and clang deleted the memcpy. Consume a byte of
     * the destination every rep so the copy cannot be dead. */
    double t0 = now_s();
    for (int r = 0; r < reps; r++) {
        memcpy(dst, src, bytes);
        g_sink += ((volatile uint8_t*)dst)[r % 64] + ((volatile uint8_t*)dst)[bytes - 1];
    }
    double dt = now_s() - t0;
    *per_rep_ms = dt * 1000.0 / reps;
    return (double)bytes * reps / dt / 1e9;
}

static const char* flagstr(VkFlags f)
{
    static char b[128];
    b[0] = 0;
    if (f & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)  strcat(b, "DEVICE_LOCAL ");
    if (f & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)  strcat(b, "HOST_VISIBLE ");
    if (f & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) strcat(b, "HOST_COHERENT ");
    if (f & VK_MEMORY_PROPERTY_HOST_CACHED_BIT)   strcat(b, "HOST_CACHED ");
    if (!b[0]) strcat(b, "(none)");
    return b;
}

/* Allocate a storage buffer in an EXPLICIT memory type. */
static int make_in_type(VkDeviceSize sz, VkFlags want, VkBuffer* buf,
                        VkDeviceMemory* mem, void** map, int* typeidx)
{
    VkBufferCreateInfo bc;
    memset(&bc, 0, sizeof bc);
    bc.sType = ST_BUFFER_CREATE_INFO;
    bc.size = sz;
    bc.usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT
             | VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    bc.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    if (p_vkCreateBuffer(g_dev, &bc, 0, buf) != VK_SUCCESS) return -1;
    VkMemoryRequirements mr;
    memset(&mr, 0, sizeof mr);
    p_vkGetBufferMemoryRequirements(g_dev, *buf, &mr);
    int mt = find_mem(mr.memoryTypeBits, want);
    if (mt < 0) return -2;
    *typeidx = mt;
    VkMemoryAllocateInfo ai;
    memset(&ai, 0, sizeof ai);
    ai.sType = ST_MEMORY_ALLOCATE_INFO;
    ai.allocationSize = mr.size;
    ai.memoryTypeIndex = (uint32_t)mt;
    if (p_vkAllocateMemory(g_dev, &ai, 0, mem) != VK_SUCCESS) return -3;
    if (p_vkBindBufferMemory(g_dev, *buf, *mem, 0) != VK_SUCCESS) return -4;
    if (p_vkMapMemory(g_dev, *mem, 0, sz, 0, map) != VK_SUCCESS) return -5;
    return 0;
}

int main(void)
{
    if (!hvk_available()) { printf("no device: %s\n", g_err); return 1; }
    uint8_t nm[256];
    hvk_device_name(nm, sizeof nm);
    printf("device: %s (type %d)\n", nm, (int)hvk_device_type());

    printf("\n---- memory types this device offers ----\n");
    for (uint32_t i = 0; i < g_memprops.memoryTypeCount; i++)
        printf("  [%2u] heap %u  %s\n", i,
               g_memprops.memoryTypes[i].heapIndex,
               flagstr(g_memprops.memoryTypes[i].propertyFlags));

    const size_t W = 1280, H = 800, SZ = W * H * 4;   /* the real composite */
    const int REPS = 20;
    printf("\n---- CPU read of the 1280x800x4 = %zu KiB composite ----\n", SZ / 1024);

    struct { const char* what; VkFlags want; } cand[] = {
      { "DEVICE_LOCAL|HOST_VISIBLE|HOST_COHERENT  (what wsysd uses today)",
        VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT | VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT
        | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT },
      { "HOST_VISIBLE|HOST_COHERENT              (the existing fallback)",
        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT },
      { "HOST_VISIBLE|HOST_COHERENT|HOST_CACHED  (never requested anywhere)",
        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT
        | VK_MEMORY_PROPERTY_HOST_CACHED_BIT },
    };

    void* plain = malloc(SZ);
    memset(plain, 0x5a, SZ);
    double ms;
    double bw = read_bw(plain, SZ, REPS, &ms);
    printf("  %-58s %7.2f GB/s  %8.3f ms/frame\n", "ordinary malloc'd RAM (the floor)", bw, ms);
    double cms;
    double cbw = copy_bw(plain, malloc(SZ), SZ, REPS, &cms);
    printf("  %-58s %7.2f GB/s  %8.3f ms/frame   [memcpy out]\n", "", cbw, cms);

    VkBuffer bufs[3]; VkDeviceMemory mems[3]; void* maps[3]; int have[3];
    void* dst = malloc(SZ);
    for (int i = 0; i < 3; i++) {
        int ti = -1;
        int r = make_in_type(SZ, cand[i].want, &bufs[i], &mems[i], &maps[i], &ti);
        have[i] = (r == 0);
        if (r != 0) { printf("  %-58s  UNAVAILABLE (rc %d)\n", cand[i].what, r); continue; }
        memset(maps[i], 0x5a, SZ);           /* touch it so it is resident */
        bw = read_bw(maps[i], SZ, REPS, &ms);
        printf("  %-58s %7.2f GB/s  %8.3f ms/frame  [memtype %d]\n",
               cand[i].what, bw, ms, ti);
        cbw = copy_bw(maps[i], dst, SZ, REPS, &cms);
        printf("  %-58s %7.2f GB/s  %8.3f ms/frame   [memcpy out]\n", "", cbw, cms);
    }

    /* ---- the DMA option: device-local -> host staging with the copy engine -- */
    printf("\n---- vkCmdCopyBuffer: device-local -> host staging ----\n");
    *(void**)(&p_vkCmdCopyBuffer) = dlsym(g_lib, "vkCmdCopyBuffer");
    if (!p_vkCmdCopyBuffer) printf("  no vkCmdCopyBuffer in the loader\n");
    if (have[0] && (have[2] || have[1]) && p_vkCmdCopyBuffer) {
        int si = have[2] ? 2 : 1;
        VkCommandBufferAllocateInfo cai;
        memset(&cai, 0, sizeof cai);
        cai.sType = ST_COMMAND_BUFFER_ALLOCATE_INFO;
        cai.commandPool = g_pool;
        cai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        cai.commandBufferCount = 1;
        if (p_vkAllocateCommandBuffers(g_dev, &cai, &g_cb) != VK_SUCCESS) {
            printf("  could not allocate a command buffer\n"); return 0; }
        VkCommandBufferBeginInfo bi;
        double best = 1e9;
        for (int r = 0; r < REPS; r++) {
            double t0 = now_s();
            p_vkResetCommandPool(g_dev, g_pool, 0);
            memset(&bi, 0, sizeof bi);
            bi.sType = ST_COMMAND_BUFFER_BEGIN_INFO;
            bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
            p_vkBeginCommandBuffer(g_cb, &bi);
            MyBufferCopy bc; bc.srcOffset = 0; bc.dstOffset = 0; bc.size = SZ;
            p_vkCmdCopyBuffer(g_cb, bufs[0], bufs[si], 1, &bc);
            p_vkEndCommandBuffer(g_cb);
            VkSubmitInfo si2;
            memset(&si2, 0, sizeof si2);
            si2.sType = ST_SUBMIT_INFO;
            si2.commandBufferCount = 1;
            si2.pCommandBuffers = &g_cb;
            p_vkResetFences(g_dev, 1, &g_fence);
            p_vkQueueSubmit(g_queue, 1, &si2, g_fence);
            p_vkWaitForFences(g_dev, 1, &g_fence, VK_TRUE, 1000000000ull);
            double dt = (now_s() - t0) * 1000.0;
            if (dt < best) best = dt;
        }
        printf("  submit+copy+fence, 4 MiB, best of %d: %.3f ms  (%.2f GB/s)\n",
               REPS, best, SZ / (best / 1000.0) / 1e9);
        printf("  then the CPU reads the staging buffer, measured above.\n");
    } else {
        printf("  cannot test: needed buffers unavailable\n");
    }
    return 0;
}
