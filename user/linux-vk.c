/* user/linux-vk.c — a REAL Vulkan client behind the vk spine, on Linux.
 *
 * WHAT THIS IS
 * ============
 * Hamnix's graphics spine is lib/vk/ — a Vulkan-SHAPED API written in Adder
 * whose only two backends until now were `vk_raster` (pure CPU) and `vk_gpu`
 * (native virtio-gpu, which pokes PCI directly and is meaningless here because
 * the Linux kernel owns the device). This file is the third backend's engine
 * room: it opens the host's REAL Vulkan loader and runs the DE's 2D primitives
 * as a genuine compute pipeline on a genuine VkDevice.
 *
 * Same shape as user/linux-fb.c and user/linux-wsys.c: a small C ABI the Adder
 * side declares with `extern def`, no Adder-visible structs, all state static.
 * lib/vk/vk_linux.ad wraps these entry points; lib/vk/vk_core.ad selects them
 * through its existing backend seam.
 *
 * WHY THIS IS POSSIBLE HERE AND NOT IN HAMNIX 1.0
 * ===============================================
 * docs/vk_hostgpu_bridge.md says an Adder binary cannot dlopen libvulkan
 * because the host target is a static no-libc ELF. That is true of the NATIVE
 * target and false on THIS line: hamlinux_build.sh emits LLVM IR and clang
 * links it against glibc dynamically, so the loader is right there. Commit
 * 1703d382 (tests/linux/vkprobe.{c,ad}) proved it end to end.
 *
 * There are NO Vulkan headers on this host, only libvulkan.so.1, so the
 * ABI-stable subset we need is hand-declared below and resolved with dlsym.
 * scripts/vk_hostgpu_bridge.c does the same and is the reference this cribs
 * from. One trap worth repeating because it cost a run: vkGetPhysicalDevice-
 * Properties writes the FULL VkPhysicalDeviceProperties (limits and sparse
 * properties, ~824 bytes), so every hand-declared OUT struct here is padded
 * for the WHOLE thing, not truncated after the field we read.
 *
 * WHAT RUNS ON THE DEVICE
 * =======================
 * scripts/shaders/vk2d_raster.comp — a compute shader that reproduces
 * lib/vk/vk_2d.ad's integer pixel math EXACTLY (same /255 source-over, same
 * Bresenham brush, same isqrt corner coverage), so a GPU frame is byte-
 * identical to the software rasterizer's rather than merely similar. Its
 * SPIR-V is EMBEDDED (user/linux-vk-spv.h) because the Hamnix root has no
 * scripts/ tree; HAMNIX_VK_SPV=<path> overrides it for shader development.
 *
 * Ops with a device path:  fill_rect, fill_rect_alpha, roundrect (AA corners),
 * line (thick Bresenham), blit (nearest, scaled, source-over), glyph coverage
 * mask. That is the whole of vk_2d's raster vocabulary — the 68% of the DE
 * frame the bench attributes to rasterization.
 *
 * THE MEMORY MODEL, and why it is the interesting part
 * ===================================================
 * The frame is a HOST-VISIBLE, HOST-COHERENT storage buffer that we map ONCE
 * and never unmap. Two consequences, both load-bearing:
 *
 *   1. There is no upload and no readback. The compositor's shadow can BE this
 *      pointer (hvk_frame_create returns it; vk_linux_frame_base() hands it to
 *      the DE), so a GPU frame costs zero copies — unlike the virtio-gpu/venus
 *      path, which pays a full-frame transfer each way.
 *   2. An op the GPU cannot encode does NOT force the whole frame back to the
 *      CPU. The caller just runs the software rasterizer on the same pointer
 *      after hvk_frame_sync(); the mixed frame stays correct and in order.
 *
 * We prefer a memory type that is DEVICE_LOCAL *and* host-visible (resizable
 * BAR / integrated / lavapipe) and fall back to plain host-visible. On a
 * discrete GPU without ReBAR that fallback means the shader writes across PCIe
 * — hvk_frame_is_device_local() reports which one you got, so the caller can
 * decide, and lib/vk/vk_linux.ad passes that judgement up rather than hiding
 * it. Nothing here pretends: if the ICD is missing, if there is no device, if
 * the pipeline will not build, every entry point returns a hard failure and
 * the Adder side stays on the software rasterizer.
 *
 * BUILD:  scripts/hamlinux_build.sh foo.ad out.elf user/linux-vk.c -ldl
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>          /* close(), for the exported dmabuf fd */

#include "linux-vk-spv.h"

/* ===================== hand-declared Vulkan ABI subset ==================== */
typedef uint32_t VkFlags;
typedef uint32_t VkBool32;
typedef uint64_t VkDeviceSize;
typedef int32_t  VkResult;

typedef void*    VkInstance;
typedef void*    VkPhysicalDevice;
typedef void*    VkDevice;
typedef void*    VkQueue;
typedef void*    VkCommandBuffer;
typedef void*    VkDescriptorSet;
typedef uint64_t VkDeviceMemory;
typedef uint64_t VkBuffer;
typedef uint64_t VkCommandPool;
typedef uint64_t VkFence;
typedef uint64_t VkShaderModule;
typedef uint64_t VkDescriptorSetLayout;
typedef uint64_t VkPipelineLayout;
typedef uint64_t VkPipeline;
typedef uint64_t VkPipelineCache;
typedef uint64_t VkDescriptorPool;
typedef uint64_t VkQueryPool;

#define VK_SUCCESS 0
#define VK_TRUE    1

#define ST_APPLICATION_INFO                    0
#define ST_INSTANCE_CREATE_INFO                1
#define ST_DEVICE_QUEUE_CREATE_INFO            2
#define ST_DEVICE_CREATE_INFO                  3
#define ST_SUBMIT_INFO                         4
#define ST_MEMORY_ALLOCATE_INFO                5
#define ST_FENCE_CREATE_INFO                   8
#define ST_BUFFER_CREATE_INFO                  12
#define ST_COMMAND_POOL_CREATE_INFO            39
#define ST_COMMAND_BUFFER_ALLOCATE_INFO        40
#define ST_COMMAND_BUFFER_BEGIN_INFO           42
#define ST_SHADER_MODULE_CREATE_INFO           16
#define ST_PIPELINE_SHADER_STAGE_CREATE_INFO   18
#define ST_COMPUTE_PIPELINE_CREATE_INFO        29
#define ST_PIPELINE_LAYOUT_CREATE_INFO         30
#define ST_DESCRIPTOR_SET_LAYOUT_CREATE_INFO   32
#define ST_DESCRIPTOR_POOL_CREATE_INFO         33
#define ST_DESCRIPTOR_SET_ALLOCATE_INFO        34
#define ST_WRITE_DESCRIPTOR_SET                35
#define ST_MEMORY_BARRIER                      46
#define ST_QUERY_POOL_CREATE_INFO              11

#define VK_QUERY_TYPE_TIMESTAMP                2
#define VK_QUERY_RESULT_64_BIT                 0x1
#define VK_QUERY_RESULT_WAIT_BIT               0x2
#define VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT      0x1
#define VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT   0x2000

#define VK_SHARING_MODE_EXCLUSIVE            0
#define VK_COMMAND_BUFFER_LEVEL_PRIMARY      0
#define VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT 0x1
#define VK_QUEUE_GRAPHICS_BIT 0x1
#define VK_QUEUE_COMPUTE_BIT  0x2

#define VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT  0x1
#define VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT  0x2
#define VK_MEMORY_PROPERTY_HOST_COHERENT_BIT 0x4
#define VK_MEMORY_PROPERTY_HOST_CACHED_BIT   0x8

#define VK_BUFFER_USAGE_TRANSFER_SRC_BIT   0x1
#define VK_BUFFER_USAGE_TRANSFER_DST_BIT   0x2
#define VK_BUFFER_USAGE_STORAGE_BUFFER_BIT 0x20

#define VK_SHADER_STAGE_COMPUTE_BIT          0x20
#define VK_DESCRIPTOR_TYPE_STORAGE_BUFFER    7
#define VK_PIPELINE_BIND_POINT_COMPUTE       1
#define VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT 0x800
#define VK_ACCESS_SHADER_READ_BIT            0x20
#define VK_ACCESS_SHADER_WRITE_BIT           0x40

#define VK_PHYSICAL_DEVICE_TYPE_OTHER          0
#define VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU 1
#define VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU   2
#define VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU    3
#define VK_PHYSICAL_DEVICE_TYPE_CPU            4

typedef struct { uint32_t x, y, z; } VkExtent3D;

typedef struct {
    uint32_t sType; const void* pNext;
    const char* pApplicationName; uint32_t applicationVersion;
    const char* pEngineName; uint32_t engineVersion; uint32_t apiVersion;
} VkApplicationInfo;

typedef struct {
    uint32_t sType; const void* pNext; VkFlags flags;
    const VkApplicationInfo* pApplicationInfo;
    uint32_t enabledLayerCount; const char* const* ppEnabledLayerNames;
    uint32_t enabledExtensionCount; const char* const* ppEnabledExtensionNames;
} VkInstanceCreateInfo;

/* VkPhysicalDeviceLimits, declared as far as timestampPeriod and no further.
 * We need exactly one field out of it — the nanoseconds a GPU timestamp tick
 * is worth — and a wrong offset here would not crash, it would print a
 * confident wrong duration, which is the failure shape this tree keeps being
 * bitten by. So hvk_timestamp_period() VALIDATES the layout against three
 * limits whose values are known-shaped on every conformant device before it
 * trusts the period, and refuses (returns 0) rather than guess. */
typedef struct {
    uint32_t maxImageDimension1D, maxImageDimension2D, maxImageDimension3D;
    uint32_t maxImageDimensionCube, maxImageArrayLayers, maxTexelBufferElements;
    uint32_t maxUniformBufferRange, maxStorageBufferRange, maxPushConstantsSize;
    uint32_t maxMemoryAllocationCount, maxSamplerAllocationCount;
    VkDeviceSize bufferImageGranularity, sparseAddressSpaceSize;
    uint32_t maxBoundDescriptorSets;
    uint32_t maxPerStageDescriptorSamplers, maxPerStageDescriptorUniformBuffers;
    uint32_t maxPerStageDescriptorStorageBuffers, maxPerStageDescriptorSampledImages;
    uint32_t maxPerStageDescriptorStorageImages, maxPerStageDescriptorInputAttachments;
    uint32_t maxPerStageResources;
    uint32_t maxDescriptorSetSamplers, maxDescriptorSetUniformBuffers;
    uint32_t maxDescriptorSetUniformBuffersDynamic, maxDescriptorSetStorageBuffers;
    uint32_t maxDescriptorSetStorageBuffersDynamic, maxDescriptorSetSampledImages;
    uint32_t maxDescriptorSetStorageImages, maxDescriptorSetInputAttachments;
    uint32_t maxVertexInputAttributes, maxVertexInputBindings;
    uint32_t maxVertexInputAttributeOffset, maxVertexInputBindingStride;
    uint32_t maxVertexOutputComponents;
    uint32_t maxTessellationGenerationLevel, maxTessellationPatchSize;
    uint32_t maxTessellationControlPerVertexInputComponents;
    uint32_t maxTessellationControlPerVertexOutputComponents;
    uint32_t maxTessellationControlPerPatchOutputComponents;
    uint32_t maxTessellationControlTotalOutputComponents;
    uint32_t maxTessellationEvaluationInputComponents;
    uint32_t maxTessellationEvaluationOutputComponents;
    uint32_t maxGeometryShaderInvocations, maxGeometryInputComponents;
    uint32_t maxGeometryOutputComponents, maxGeometryOutputVertices;
    uint32_t maxGeometryTotalOutputComponents;
    uint32_t maxFragmentInputComponents, maxFragmentOutputAttachments;
    uint32_t maxFragmentDualSrcAttachments, maxFragmentCombinedOutputResources;
    uint32_t maxComputeSharedMemorySize;
    uint32_t maxComputeWorkGroupCount[3];
    uint32_t maxComputeWorkGroupInvocations;
    uint32_t maxComputeWorkGroupSize[3];
    uint32_t subPixelPrecisionBits, subTexelPrecisionBits, mipmapPrecisionBits;
    uint32_t maxDrawIndexedIndexValue, maxDrawIndirectCount;
    float    maxSamplerLodBias, maxSamplerAnisotropy;
    uint32_t maxViewports, maxViewportDimensions[2];
    float    viewportBoundsRange[2];
    uint32_t viewportSubPixelBits;
    size_t   minMemoryMapAlignment;
    VkDeviceSize minTexelBufferOffsetAlignment, minUniformBufferOffsetAlignment;
    VkDeviceSize minStorageBufferOffsetAlignment;
    int32_t  minTexelOffset; uint32_t maxTexelOffset;
    int32_t  minTexelGatherOffset; uint32_t maxTexelGatherOffset;
    float    minInterpolationOffset, maxInterpolationOffset;
    uint32_t subPixelInterpolationOffsetBits;
    uint32_t maxFramebufferWidth, maxFramebufferHeight, maxFramebufferLayers;
    VkFlags  framebufferColorSampleCounts, framebufferDepthSampleCounts;
    VkFlags  framebufferStencilSampleCounts, framebufferNoAttachmentsSampleCounts;
    uint32_t maxColorAttachments;
    VkFlags  sampledImageColorSampleCounts, sampledImageIntegerSampleCounts;
    VkFlags  sampledImageDepthSampleCounts, sampledImageStencilSampleCounts;
    VkFlags  storageImageSampleCounts;
    uint32_t maxSampleMaskWords;
    VkBool32 timestampComputeAndGraphics;
    float    timestampPeriod;
    /* ...and 24 more fields we do not read. */
} VkPhysicalDeviceLimitsHead;

/* Only the head is read by us. The driver writes limits + sparseProperties on
 * past deviceName (real size ~824 bytes), so the tail padding is MANDATORY —
 * without it vkGetPhysicalDeviceProperties smashes the caller's stack. */
typedef struct {
    uint32_t apiVersion, driverVersion, vendorID, deviceID;
    uint32_t deviceType;
    char     deviceName[256];
    uint8_t  pipelineCacheUUID[16];
    VkPhysicalDeviceLimitsHead limits;
    uint8_t  _pad[1024];
} VkPhysicalDeviceProperties;

typedef struct {
    VkFlags queueFlags; uint32_t queueCount; uint32_t timestampValidBits;
    VkExtent3D minImageTransferGranularity;
} VkQueueFamilyProperties;

typedef struct {
    uint32_t sType; const void* pNext; VkFlags flags;
    uint32_t queryType; uint32_t queryCount; VkFlags pipelineStatistics;
} VkQueryPoolCreateInfo;

typedef struct {
    uint32_t sType; const void* pNext; VkFlags flags;
    uint32_t queueFamilyIndex; uint32_t queueCount; const float* pQueuePriorities;
} VkDeviceQueueCreateInfo;

typedef struct {
    uint32_t sType; const void* pNext; VkFlags flags;
    uint32_t queueCreateInfoCount; const VkDeviceQueueCreateInfo* pQueueCreateInfos;
    uint32_t enabledLayerCount; const char* const* ppEnabledLayerNames;
    uint32_t enabledExtensionCount; const char* const* ppEnabledExtensionNames;
    const void* pEnabledFeatures;
} VkDeviceCreateInfo;

typedef struct { VkDeviceSize size, alignment; uint32_t memoryTypeBits; } VkMemoryRequirements;
typedef struct { uint32_t sType; const void* pNext; VkDeviceSize allocationSize;
                 uint32_t memoryTypeIndex; } VkMemoryAllocateInfo;
typedef struct { VkFlags propertyFlags; uint32_t heapIndex; } VkMemoryType;
typedef struct { VkDeviceSize size; VkFlags flags; } VkMemoryHeap;
typedef struct {
    uint32_t memoryTypeCount; VkMemoryType memoryTypes[32];
    uint32_t memoryHeapCount; VkMemoryHeap memoryHeaps[16];
} VkPhysicalDeviceMemoryProperties;

/* VK_MAX_EXTENSION_NAME_SIZE is 256 and the struct is name + specVersion. */
typedef struct { char extensionName[256]; uint32_t specVersion; }
    VkExtensionProperties;

/* ---- external memory (dmabuf export), all from VK_KHR_external_memory_fd
 * and VK_EXT_external_memory_dma_buf. Hand-declared like everything else
 * here; the sType numbers are the extension-assigned ones. ---- */
#define ST_EXTERNAL_MEMORY_BUFFER_CREATE_INFO 1000072000
#define ST_EXPORT_MEMORY_ALLOCATE_INFO        1000072002
#define ST_MEMORY_GET_FD_INFO_KHR             1000074002
#define VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT 0x200

typedef struct { uint32_t sType; const void* pNext; uint32_t handleTypes; }
    VkExternalMemoryBufferCreateInfo;
typedef struct { uint32_t sType; const void* pNext; uint32_t handleTypes; }
    VkExportMemoryAllocateInfo;
typedef struct { uint32_t sType; const void* pNext;
                 VkDeviceMemory memory; uint32_t handleType; }
    VkMemoryGetFdInfoKHR;

typedef struct {
    uint32_t sType; const void* pNext; VkFlags flags;
    VkDeviceSize size; VkFlags usage; uint32_t sharingMode;
    uint32_t queueFamilyIndexCount; const uint32_t* pQueueFamilyIndices;
} VkBufferCreateInfo;

typedef struct { uint32_t sType; const void* pNext; VkFlags flags;
                 uint32_t queueFamilyIndex; } VkCommandPoolCreateInfo;
typedef struct { uint32_t sType; const void* pNext; VkCommandPool commandPool;
                 uint32_t level; uint32_t commandBufferCount; } VkCommandBufferAllocateInfo;
typedef struct { uint32_t sType; const void* pNext; VkFlags flags;
                 const void* pInheritanceInfo; } VkCommandBufferBeginInfo;
typedef struct {
    uint32_t sType; const void* pNext;
    uint32_t waitSemaphoreCount; const void* pWaitSemaphores; const VkFlags* pWaitDstStageMask;
    uint32_t commandBufferCount; const VkCommandBuffer* pCommandBuffers;
    uint32_t signalSemaphoreCount; const void* pSignalSemaphores;
} VkSubmitInfo;
typedef struct { uint32_t sType; const void* pNext; VkFlags flags; } VkFenceCreateInfo;

typedef struct { uint32_t sType; const void* pNext; VkFlags flags;
                 size_t codeSize; const uint32_t* pCode; } VkShaderModuleCreateInfo;
typedef struct { uint32_t binding, descriptorType, descriptorCount;
                 VkFlags stageFlags; const void* pImmutableSamplers; } VkDescriptorSetLayoutBinding;
typedef struct { uint32_t sType; const void* pNext; VkFlags flags;
                 uint32_t bindingCount; const VkDescriptorSetLayoutBinding* pBindings;
               } VkDescriptorSetLayoutCreateInfo;
typedef struct { VkFlags stageFlags; uint32_t offset, size; } VkPushConstantRange;
typedef struct { uint32_t sType; const void* pNext; VkFlags flags;
                 uint32_t setLayoutCount; const VkDescriptorSetLayout* pSetLayouts;
                 uint32_t pushConstantRangeCount; const VkPushConstantRange* pPushConstantRanges;
               } VkPipelineLayoutCreateInfo;
typedef struct { uint32_t sType; const void* pNext; VkFlags flags;
                 VkFlags stage; VkShaderModule module; const char* pName;
                 const void* pSpecializationInfo; } VkPipelineShaderStageCreateInfo;
typedef struct { uint32_t sType; const void* pNext; VkFlags flags;
                 VkPipelineShaderStageCreateInfo stage; VkPipelineLayout layout;
                 VkPipeline basePipelineHandle; int32_t basePipelineIndex;
               } VkComputePipelineCreateInfo;
typedef struct { uint32_t type, descriptorCount; } VkDescriptorPoolSize;
typedef struct { uint32_t sType; const void* pNext; VkFlags flags;
                 uint32_t maxSets, poolSizeCount; const VkDescriptorPoolSize* pPoolSizes;
               } VkDescriptorPoolCreateInfo;
typedef struct { uint32_t sType; const void* pNext; VkDescriptorPool descriptorPool;
                 uint32_t descriptorSetCount; const VkDescriptorSetLayout* pSetLayouts;
               } VkDescriptorSetAllocateInfo;
typedef struct { VkBuffer buffer; VkDeviceSize offset, range; } VkDescriptorBufferInfo;
typedef struct { uint32_t sType; const void* pNext; VkDescriptorSet dstSet;
                 uint32_t dstBinding, dstArrayElement, descriptorCount, descriptorType;
                 const void* pImageInfo; const VkDescriptorBufferInfo* pBufferInfo;
                 const void* pTexelBufferView; } VkWriteDescriptorSet;
typedef struct { uint32_t sType; const void* pNext;
                 VkFlags srcAccessMask, dstAccessMask; } VkMemoryBarrier;

/* ---- dlsym'd entry points (no link-time dependency on libvulkan) --------- */
#define VKFN(ret, name, args) static ret (*p_##name) args
VKFN(VkResult, vkCreateInstance, (const VkInstanceCreateInfo*, const void*, VkInstance*));
VKFN(void,     vkDestroyInstance, (VkInstance, const void*));
VKFN(VkResult, vkEnumeratePhysicalDevices, (VkInstance, uint32_t*, VkPhysicalDevice*));
VKFN(void,     vkGetPhysicalDeviceProperties, (VkPhysicalDevice, VkPhysicalDeviceProperties*));
VKFN(void,     vkGetPhysicalDeviceQueueFamilyProperties, (VkPhysicalDevice, uint32_t*, VkQueueFamilyProperties*));
VKFN(void,     vkGetPhysicalDeviceMemoryProperties, (VkPhysicalDevice, VkPhysicalDeviceMemoryProperties*));
VKFN(VkResult, vkCreateDevice, (VkPhysicalDevice, const VkDeviceCreateInfo*, const void*, VkDevice*));
VKFN(VkResult, vkEnumerateDeviceExtensionProperties, (VkPhysicalDevice, const char*, uint32_t*, VkExtensionProperties*));
VKFN(void*, vkGetDeviceProcAddr, (VkDevice, const char*));
VKFN(VkResult, vkGetMemoryFdKHR, (VkDevice, const VkMemoryGetFdInfoKHR*, int*));
VKFN(void,     vkDestroyDevice, (VkDevice, const void*));
VKFN(void,     vkGetDeviceQueue, (VkDevice, uint32_t, uint32_t, VkQueue*));
VKFN(VkResult, vkCreateBuffer, (VkDevice, const VkBufferCreateInfo*, const void*, VkBuffer*));
VKFN(void,     vkDestroyBuffer, (VkDevice, VkBuffer, const void*));
VKFN(void,     vkGetBufferMemoryRequirements, (VkDevice, VkBuffer, VkMemoryRequirements*));
VKFN(VkResult, vkAllocateMemory, (VkDevice, const VkMemoryAllocateInfo*, const void*, VkDeviceMemory*));
VKFN(void,     vkFreeMemory, (VkDevice, VkDeviceMemory, const void*));
VKFN(VkResult, vkBindBufferMemory, (VkDevice, VkBuffer, VkDeviceMemory, VkDeviceSize));
VKFN(VkResult, vkMapMemory, (VkDevice, VkDeviceMemory, VkDeviceSize, VkDeviceSize, VkFlags, void**));
VKFN(void,     vkUnmapMemory, (VkDevice, VkDeviceMemory));
VKFN(VkResult, vkCreateCommandPool, (VkDevice, const VkCommandPoolCreateInfo*, const void*, VkCommandPool*));
VKFN(void,     vkDestroyCommandPool, (VkDevice, VkCommandPool, const void*));
VKFN(VkResult, vkAllocateCommandBuffers, (VkDevice, const VkCommandBufferAllocateInfo*, VkCommandBuffer*));
VKFN(void,     vkFreeCommandBuffers, (VkDevice, VkCommandPool, uint32_t, const VkCommandBuffer*));
VKFN(VkResult, vkResetCommandPool, (VkDevice, VkCommandPool, VkFlags));
VKFN(VkResult, vkBeginCommandBuffer, (VkCommandBuffer, const VkCommandBufferBeginInfo*));
VKFN(VkResult, vkEndCommandBuffer, (VkCommandBuffer));
VKFN(void,     vkCmdPipelineBarrier, (VkCommandBuffer, VkFlags, VkFlags, VkFlags,
                                      uint32_t, const VkMemoryBarrier*, uint32_t, const void*,
                                      uint32_t, const void*));
VKFN(VkResult, vkCreateFence, (VkDevice, const VkFenceCreateInfo*, const void*, VkFence*));
VKFN(void,     vkDestroyFence, (VkDevice, VkFence, const void*));
VKFN(VkResult, vkResetFences, (VkDevice, uint32_t, const VkFence*));
VKFN(VkResult, vkQueueSubmit, (VkQueue, uint32_t, const VkSubmitInfo*, VkFence));
VKFN(VkResult, vkWaitForFences, (VkDevice, uint32_t, const VkFence*, VkBool32, uint64_t));
VKFN(VkResult, vkDeviceWaitIdle, (VkDevice));
VKFN(VkResult, vkCreateShaderModule, (VkDevice, const VkShaderModuleCreateInfo*, const void*, VkShaderModule*));
VKFN(void,     vkDestroyShaderModule, (VkDevice, VkShaderModule, const void*));
VKFN(VkResult, vkCreateDescriptorSetLayout, (VkDevice, const VkDescriptorSetLayoutCreateInfo*, const void*, VkDescriptorSetLayout*));
VKFN(VkResult, vkCreatePipelineLayout, (VkDevice, const VkPipelineLayoutCreateInfo*, const void*, VkPipelineLayout*));
VKFN(VkResult, vkCreateComputePipelines, (VkDevice, VkPipelineCache, uint32_t, const VkComputePipelineCreateInfo*, const void*, VkPipeline*));
VKFN(VkResult, vkCreateDescriptorPool, (VkDevice, const VkDescriptorPoolCreateInfo*, const void*, VkDescriptorPool*));
VKFN(VkResult, vkAllocateDescriptorSets, (VkDevice, const VkDescriptorSetAllocateInfo*, VkDescriptorSet*));
VKFN(void,     vkUpdateDescriptorSets, (VkDevice, uint32_t, const VkWriteDescriptorSet*, uint32_t, const void*));
VKFN(void,     vkCmdBindPipeline, (VkCommandBuffer, uint32_t, VkPipeline));
VKFN(void,     vkCmdBindDescriptorSets, (VkCommandBuffer, uint32_t, VkPipelineLayout, uint32_t, uint32_t, const VkDescriptorSet*, uint32_t, const uint32_t*));
VKFN(void,     vkCmdPushConstants, (VkCommandBuffer, VkPipelineLayout, VkFlags, uint32_t, uint32_t, const void*));
VKFN(void,     vkCmdDispatch, (VkCommandBuffer, uint32_t, uint32_t, uint32_t));
VKFN(VkResult, vkCreateQueryPool, (VkDevice, const VkQueryPoolCreateInfo*, const void*, VkQueryPool*));
VKFN(void,     vkDestroyQueryPool, (VkDevice, VkQueryPool, const void*));
VKFN(void,     vkCmdResetQueryPool, (VkCommandBuffer, VkQueryPool, uint32_t, uint32_t));
VKFN(void,     vkCmdWriteTimestamp, (VkCommandBuffer, VkFlags, VkQueryPool, uint32_t));
VKFN(VkResult, vkGetQueryPoolResults, (VkDevice, VkQueryPool, uint32_t, uint32_t,
                                       size_t, void*, VkDeviceSize, VkFlags));
#undef VKFN

/* ============================ module state =============================== */

/* PushC MUST match scripts/shaders/vk2d_raster.comp's push_constant block. */
typedef struct {
    int32_t  op, bx, by, dispw, disph, img_w, img_h;
    uint32_t rgba;
    int32_t  px, py, pw, ph, rad, corners;
    int32_t  dx, dy, rsx, rsy, rsw, rsh, tw, th, src_w, src_h;
    int32_t  mask_off;   /* base index (in uints) into src[] for COVMASK/BLIT */
} PushC;
enum { OP_FILL = 0, OP_FILL_ALPHA = 1, OP_BLIT = 2, OP_ROUNDRECT = 3,
       OP_LINE = 4, OP_COVMASK = 5, OP_BATCH = 6 };
#define HVK_BATCH_STRIDE 24u    /* uints per OP_BATCH table entry */
#define HVK_BATCH_MAX    1024   /* entries per batched dispatch */

#define HVK_MAXOPS   16384
#define HVK_ARENA_MIN (4u << 20)      /* 4 MiB of blit/coverage source space */

static void*            g_lib;
static int              g_state;      /* 0 untried, 1 ready, -1 unusable */
static VkInstance       g_inst;
static VkPhysicalDevice g_phys;
static VkDevice         g_dev;
static VkQueue          g_queue;
static uint32_t         g_qfam;
static VkCommandPool    g_pool;
static VkFence          g_fence;
static char             g_devname[288] = "none";
static uint32_t         g_devtype = VK_PHYSICAL_DEVICE_TYPE_OTHER;
static VkPhysicalDeviceMemoryProperties g_memprops;
static char             g_err[192] = "not initialised";

static VkShaderModule        g_module;
static VkDescriptorSetLayout g_dsl;
static VkPipelineLayout      g_playout;
static VkPipeline            g_pipe;
static VkDescriptorPool      g_dpool;
static VkDescriptorSet       g_dset;

/* the frame (binding 0): host-visible, coherent, mapped for its whole life */
static VkBuffer      g_fbuf;
static VkDeviceMemory g_fmem;
static uint8_t*      g_fmap;
static int32_t       g_fw, g_fh;
static int32_t       g_fbgra;
static int           g_fdevlocal;
static VkFlags       g_last_place_flags;   /* set by make_storage_buffer */
static VkFlags       g_fflags;             /* ...captured for the frame */
static int           g_can_export;         /* the 3 dmabuf extensions are on */
static int           g_fexported;          /* the frame is an exportable alloc */
static int           g_fdmabuf = -1;       /* its dmabuf fd, once exported */

/* the source arena (binding 1): blit pixels + glyph coverage, grows on demand */
static VkBuffer       g_abuf;
static VkDeviceMemory g_amem;
static uint32_t*      g_amap;
/* HOST-SIDE MIRROR OF THE ARENA, and the reason it exists.
 *
 * g_amap points at MAPPED DEVICE-VISIBLE memory. Writing it is cheap (the CPU
 * write-combines and the store never stalls), but READING it is not: on a
 * discrete GPU that mapping is uncached — write-combined system memory, or
 * VRAM across the PCIe BAR — and every load is a bus round trip of order 100
 * ns instead of an L1 hit.
 *
 * The glyph coverage cache used to confirm a hash hit by comparing the
 * candidate byte for byte against g_amap. That confirmation is not optional --
 * a collision there paints one letter with another letter's shape -- but it
 * does not have to read the DEVICE's copy. This is an ordinary-RAM mirror
 * written in lockstep from the same source bytes, so the comparison is the
 * identical comparison against the identical bytes, with no bus in it.
 *
 * MEASURED, RTX 3090, the 1280x800 DE+text frame: confirming against g_amap
 * cost 32.3 ms of CPU per frame while the GPU did 0.43 ms of work. Against
 * this mirror the same frame is 0.8 ms. Nothing about the pixels changes. */
static uint32_t*      g_ashadow;
static VkDeviceSize   g_acap;
static uint32_t       g_ause;         /* uints consumed this frame */
static int            g_adevlocal;    /* the arena landed in device memory */

static PushC    g_ops[HVK_MAXOPS];
static uint32_t g_grp[HVK_MAXOPS][2];
/* Per-op destination rect (x0,y0,x1,y1) and whether a barrier must precede it.
 * 2D painting is ordered, but only where the paint LANDS: a run of glyphs or a
 * row of icons write disjoint rects, so they may all run at once. Serializing
 * them anyway is what made the first version of this backend 10x slower than
 * the CPU — see the bbox tracking in push_op. */
static int32_t  g_rect[HVK_MAXOPS][4];
static uint8_t  g_bar[HVK_MAXOPS];
static int32_t  g_nops;
static int32_t  g_bbx0, g_bby0, g_bbx1, g_bby1;   /* union since last barrier */
/* ...and the INDIVIDUAL rects that union covers. The union is a strict
 * over-approximation: a row of glyphs unions into a band, and an op that lands
 * inside that band without touching a single glyph is provably independent of
 * every op in it. Testing against the union alone reports a conflict there and
 * buys a pipeline barrier that nothing needed. The union stays as the O(1)
 * reject; the list is consulted only when the union says "maybe", so the scan
 * runs a few dozen times a frame rather than once per op. */
#define HVK_TRACK_MAX 512
static int32_t  g_cur[HVK_TRACK_MAX][4];
static int32_t  g_ncur;         /* -1 = overflowed, be conservative */
static int32_t  g_barriers;
static uint64_t g_stat_falsecon;  /* barriers the union would have inserted
                                   * and the exact test did not */
static int32_t  g_frame_err;
static int      g_in_frame;

/* The command buffer is allocated ONCE and reset per submit. Allocating and
 * freeing one every frame is two driver round trips and a pool churn for a
 * recording that has exactly the same shape every time. */
static VkCommandBuffer g_cb;

/* Glyph coverage dedup, per frame. A page of text is a few hundred DISTINCT
 * glyph shapes drawn thousands of times, and every one of them used to be
 * expanded into the source arena again: 1680 glyphs of 12x16 is 1.3 MiB of
 * staging per frame for maybe 40 KiB of actual coverage. The key is a hash of
 * the coverage BYTES (the caller re-uses one scratch buffer, so the pointer
 * says nothing), and a hit is CONFIRMED byte for byte against what is already
 * in the arena before it is trusted -- a hash collision here would paint one
 * letter with another letter's shape, which is precisely the plausible wrong
 * answer this codebase keeps being bitten by. */
#define HVK_COV_CACHE 512
struct covent { uint32_t hash; int32_t w, h, off; };
static struct covent g_cov[HVK_COV_CACHE];
static int32_t  g_ncov;

/* counters the Adder side publishes so a frame's mix is inspectable */
static uint64_t g_stat_frames, g_stat_ops, g_stat_dispatches, g_stat_submits;
static uint64_t g_stat_last_us, g_stat_arena_bytes, g_stat_batched;
static uint64_t g_stat_staged;      /* uints written into the source arena */
static uint64_t g_stat_covreuse;    /* glyphs that reused a staged mask */

/* --- WHERE THE FRAME'S MICROSECONDS ACTUALLY WENT -------------------------
 * g_stat_last_us is wall clock around record + submit + wait, so on its own
 * it cannot tell "the GPU executed for 33 ms" from "we blocked for 33 ms
 * waiting for a driver that had not started yet". Those have opposite fixes,
 * so the split is measured rather than argued:
 *
 *   record_us  CPU inside vkCmd* recording the command buffer
 *   wait_us    CPU inside vkQueueSubmit + vkWaitForFences (idle if the GPU
 *              is the one working)
 *   gpu_ns     the DEVICE's own clock between a TOP_OF_PIPE timestamp at the
 *              head of the command buffer and a BOTTOM_OF_PIPE one at its
 *              tail, converted with VkPhysicalDeviceLimits::timestampPeriod.
 *
 * gpu_ns is 0, never a guess, when the queue family reports no valid
 * timestamp bits or the limits layout does not validate. */
static uint64_t g_stat_record_us, g_stat_wait_us, g_stat_gpu_ns;
static VkQueryPool g_qpool;
static uint32_t    g_ts_valid_bits;
static float       g_ts_period;      /* ns per tick; 0 = not trustworthy */
static int         g_ts_warned;

/* --- the measurement levers -------------------------------------------
 * dispatches, barriers and staged words are the device-INDEPENDENT numbers
 * this backend is tuned against, and a number is only shown to predict
 * anything if it can be VARIED while the output pixels stay identical.
 * These two knobs are that instrument. Neither changes a single pixel and
 * both default to off:
 *
 *   HAMNIX_VK_MAX_BATCH=N   cap the OP_BATCH entry count. =1 reproduces the
 *                           one-dispatch-per-op shape the batching replaced,
 *                           so the SAME frame can be measured at 15 and at
 *                           1724 dispatches and the per-dispatch cost read
 *                           straight off the slope.
 *   HAMNIX_VK_NO_COVCACHE=1 disable the per-frame glyph coverage cache, so
 *                           the same frame can be measured at 41,808 and at
 *                           363,792 staged words.
 *
 * They exist for the day this backend meets real silicon: the two slopes are
 * the whole question, and on a GPU they are different numbers, not different
 * conclusions -- see docs/vk_linux_backend.md. */
static int32_t g_batch_max = -1;    /* <0: env not read yet */
static int32_t g_no_covcache;
/* THE THIRD LEVER — where the source arena LIVES. binding 1 is read by the
 * shader once per invocation for the batch-table fields and once per PIXEL
 * for a glyph's coverage byte, so on a discrete GPU a plain HOST_VISIBLE
 * arena puts that read across PCIe. =1 asks for DEVICE_LOCAL|HOST_VISIBLE
 * (the same memory type the frame already gets on this card) instead.
 * Pixels are unaffected either way, which is what makes it a lever. */
static int32_t g_arena_devlocal;

/* Where a mapped buffer is placed. The measured table that justifies these
 * three, and the rule for choosing between them, is the comment above
 * make_storage_buffer(); they are declared up here only because the tunables
 * below have to name them. */
#define HVK_PLACE_HOST_COHERENT 0   /* HOST_VISIBLE|HOST_COHERENT, uncached   */
#define HVK_PLACE_DEVICE_FIRST  1   /* DEVICE_LOCAL|HOST_VISIBLE if it exists */
#define HVK_PLACE_HOST_CACHED   2   /* ...|HOST_CACHED if it exists           */

/* THE FOURTH LEVER, and the one nobody had ever pulled — where the FRAME
 * lives. See the placement table above make_storage_buffer(). The frame's
 * placement was not a lever at all before this: hvk_frame_create() passed a
 * hardcoded 1 and got the BAR every time.
 *
 *   HAMNIX_VK_FRAME_MEM=cached    HOST_CACHED system RAM (the default)
 *                       coherent  HOST_VISIBLE|HOST_COHERENT (uncached/WC)
 *                       device    DEVICE_LOCAL|HOST_VISIBLE (the BAR — what
 *                                 every measurement before this one used)
 *
 * `device` is kept precisely so the 13x-slower configuration stays
 * reproducible: a fix whose predecessor cannot be re-run is a claim. */
static int32_t g_frame_place = -1;

static void hvk_tunables(void)
{
    if (g_batch_max >= 0) return;
    g_batch_max = HVK_BATCH_MAX;
    const char* s = getenv("HAMNIX_VK_MAX_BATCH");
    if (s && s[0]) {
        long v = strtol(s, 0, 10);
        if (v >= 1 && v <= HVK_BATCH_MAX) g_batch_max = (int32_t)v;
    }
    s = getenv("HAMNIX_VK_NO_COVCACHE");
    g_no_covcache = (s && s[0] && s[0] != '0') ? 1 : 0;
    s = getenv("HAMNIX_VK_ARENA_DEVLOCAL");
    g_arena_devlocal = (s && s[0] && s[0] != '0') ? 1 : 0;
    g_frame_place = HVK_PLACE_HOST_CACHED;
    s = getenv("HAMNIX_VK_FRAME_MEM");
    if (s && s[0]) {
        if (s[0] == 'd')      g_frame_place = HVK_PLACE_DEVICE_FIRST;
        else if (s[0] == 'o') g_frame_place = HVK_PLACE_HOST_COHERENT;
        else if (s[0] == 'c' && s[1] == 'o') g_frame_place = HVK_PLACE_HOST_COHERENT;
        else                  g_frame_place = HVK_PLACE_HOST_CACHED;
    }
}

static int hvk_fail(const char* why)
{
    snprintf(g_err, sizeof g_err, "%s", why);
    g_state = -1;
    return -1;
}

#define VKCK(expr) do { VkResult _r = (expr); if (_r != VK_SUCCESS) { \
    snprintf(g_err, sizeof g_err, "%s -> VkResult %d", #expr, (int)_r); \
    g_state = -1; return -1; } } while (0)

static uint64_t now_us(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000ull + (uint64_t)ts.tv_nsec / 1000ull;
}

static int rank_devtype(uint32_t t)
{
    switch (t) {
    case VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU:   return 4;
    case VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU: return 3;
    case VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU:    return 2;
    case VK_PHYSICAL_DEVICE_TYPE_OTHER:          return 1;
    default:                                     return 0;  /* CPU ICD last */
    }
}

static int find_mem(uint32_t typeBits, VkFlags want)
{
    for (uint32_t i = 0; i < g_memprops.memoryTypeCount; i++)
        if ((typeBits & (1u << i)) &&
            (g_memprops.memoryTypes[i].propertyFlags & want) == want)
            return (int)i;
    return -1;
}

static int load_loader(void)
{
    const char* off = getenv("HAMNIX_VK_DISABLE");
    if (off && off[0] && off[0] != '0')
        return hvk_fail("disabled by HAMNIX_VK_DISABLE");
    g_lib = dlopen("libvulkan.so.1", RTLD_NOW | RTLD_LOCAL);
    if (!g_lib) g_lib = dlopen("libvulkan.so", RTLD_NOW | RTLD_LOCAL);
    if (!g_lib) {
        const char* e = dlerror();
        snprintf(g_err, sizeof g_err, "no libvulkan: %s", e ? e : "?");
        g_state = -1;
        return -1;
    }
#define BIND(name) do { \
        *(void**)(&p_##name) = dlsym(g_lib, #name); \
        if (!p_##name) return hvk_fail("libvulkan lacks " #name); } while (0)
    BIND(vkCreateInstance); BIND(vkDestroyInstance);
    BIND(vkEnumeratePhysicalDevices); BIND(vkGetPhysicalDeviceProperties);
    BIND(vkGetPhysicalDeviceQueueFamilyProperties);
    BIND(vkGetPhysicalDeviceMemoryProperties);
    BIND(vkCreateDevice); BIND(vkDestroyDevice); BIND(vkGetDeviceQueue);
    BIND(vkEnumerateDeviceExtensionProperties);
    BIND(vkGetDeviceProcAddr);
    BIND(vkCreateBuffer); BIND(vkDestroyBuffer); BIND(vkGetBufferMemoryRequirements);
    BIND(vkAllocateMemory); BIND(vkFreeMemory); BIND(vkBindBufferMemory);
    BIND(vkMapMemory); BIND(vkUnmapMemory);
    BIND(vkCreateCommandPool); BIND(vkDestroyCommandPool);
    BIND(vkAllocateCommandBuffers); BIND(vkFreeCommandBuffers);
    BIND(vkResetCommandPool);
    BIND(vkBeginCommandBuffer); BIND(vkEndCommandBuffer);
    BIND(vkCmdPipelineBarrier);
    BIND(vkCreateFence); BIND(vkDestroyFence); BIND(vkResetFences);
    BIND(vkQueueSubmit); BIND(vkWaitForFences); BIND(vkDeviceWaitIdle);
    BIND(vkCreateShaderModule); BIND(vkDestroyShaderModule);
    BIND(vkCreateDescriptorSetLayout); BIND(vkCreatePipelineLayout);
    BIND(vkCreateComputePipelines); BIND(vkCreateDescriptorPool);
    BIND(vkAllocateDescriptorSets); BIND(vkUpdateDescriptorSets);
    BIND(vkCmdBindPipeline); BIND(vkCmdBindDescriptorSets);
    BIND(vkCmdPushConstants); BIND(vkCmdDispatch);
    BIND(vkCreateQueryPool); BIND(vkDestroyQueryPool);
    BIND(vkCmdResetQueryPool); BIND(vkCmdWriteTimestamp);
    BIND(vkGetQueryPoolResults);
#undef BIND
    return 0;
}

/* Load the compute rasterizer's SPIR-V: HAMNIX_VK_SPV=<path> if set (shader
 * development), otherwise the copy embedded in user/linux-vk-spv.h. */
static const uint32_t* load_spv(size_t* nbytes, uint32_t** owned)
{
    const char* path = getenv("HAMNIX_VK_SPV");
    *owned = 0;
    if (path && path[0]) {
        FILE* f = fopen(path, "rb");
        if (f) {
            fseek(f, 0, SEEK_END);
            long n = ftell(f);
            fseek(f, 0, SEEK_SET);
            if (n > 0 && (n % 4) == 0) {
                uint32_t* buf = (uint32_t*)malloc((size_t)n);
                if (buf && fread(buf, 1, (size_t)n, f) == (size_t)n) {
                    fclose(f);
                    *owned = buf;
                    *nbytes = (size_t)n;
                    return buf;
                }
                free(buf);
            }
            fclose(f);
        }
        /* A named-but-unreadable shader is a caller error, not a silent
         * downgrade: say so, then use the embedded one. */
        fprintf(stderr, "[linux-vk] HAMNIX_VK_SPV=%s unusable; using built-in\n", path);
    }
    *nbytes = HVK_SPV_VK2D_RASTER_BYTES;
    return hvk_spv_vk2d_raster;
}

/* WHERE A MAPPED BUFFER LIVES, AND WHY IT IS THE WHOLE PERFORMANCE STORY.
 *
 * Every buffer here is host-mapped, so every one of them has a CPU access
 * pattern, and on a discrete GPU the placement decides that access's cost by
 * two to three ORDERS OF MAGNITUDE. Measured on this RTX 3090 (proprietary
 * ICD), memcpy of the 4 MiB 1280x800 composite OUT of each placement:
 *
 *   DEVICE_LOCAL|HOST_VISIBLE  (the BAR)     88.0 ms   0.05 GB/s
 *   HOST_VISIBLE|HOST_COHERENT (uncached)    10.7 ms   0.38 GB/s
 *   HOST_VISIBLE|HOST_COHERENT|HOST_CACHED    0.22 ms  18.3 GB/s
 *   ordinary malloc'd RAM, for scale          0.16 ms  25.6 GB/s
 *
 * A CPU read of the BAR is 393x slower than a CPU read of cached host RAM and
 * is not far off the cost of reading it over a network. So the rule is:
 *
 *   DEVICE_FIRST   the CPU only ever WRITES it, and the shader reads it hot
 *                  (the source arena: writes to WC memory are posted and
 *                  cheap, and g_ashadow already keeps CPU reads off the bus)
 *   HOST_CACHED    the CPU READS it every frame (the composite: the shader's
 *                  writes cross PCIe once, posted, while present_rows' read
 *                  becomes an ordinary cached load)
 *
 * There is no placement that is best for both, which is the actual shape of
 * this problem — see hvk_frame_create. */
static int make_storage_buffer(VkDeviceSize sz, int place,
                               VkBuffer* buf, VkDeviceMemory* mem,
                               void** map, int* got_device_local)
{
    VkBufferCreateInfo bc;
    memset(&bc, 0, sizeof bc);
    bc.sType = ST_BUFFER_CREATE_INFO;
    bc.size = sz;
    bc.usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT
             | VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    bc.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    VKCK(p_vkCreateBuffer(g_dev, &bc, 0, buf));
    VkMemoryRequirements mr;
    memset(&mr, 0, sizeof mr);
    p_vkGetBufferMemoryRequirements(g_dev, *buf, &mr);
    int mt = -1;
    if (got_device_local) *got_device_local = 0;
    if (place == HVK_PLACE_DEVICE_FIRST) {
        /* Resizable-BAR / integrated / software ICDs give us memory that is
         * BOTH device-local and host-mappable: the shader writes at full
         * device speed AND the compositor reads the frame with no copy.
         * On a discrete card WITHOUT ReBAR this is the 256 MiB BAR aperture,
         * which is host-mappable and catastrophic to read -- see the table. */
        mt = find_mem(mr.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT
                      | VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT
                      | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        if (mt >= 0 && got_device_local) *got_device_local = 1;
    } else if (place == HVK_PLACE_HOST_CACHED) {
        mt = find_mem(mr.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT
                      | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT
                      | VK_MEMORY_PROPERTY_HOST_CACHED_BIT);
        /* A device-local type that is ALSO host-cached is the best of both and
         * exists on integrated parts; the search above finds it there because
         * find_mem takes the first type matching all the requested bits and
         * integrated parts mark their single host heap device-local. */
    }
    if (mt < 0)
        mt = find_mem(mr.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT
                      | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    if (mt < 0) return hvk_fail("no host-visible coherent memory type");
    if (got_device_local && (g_memprops.memoryTypes[mt].propertyFlags
                             & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT))
        *got_device_local = 1;
    g_last_place_flags = g_memprops.memoryTypes[mt].propertyFlags;
    VkMemoryAllocateInfo ai;
    memset(&ai, 0, sizeof ai);
    ai.sType = ST_MEMORY_ALLOCATE_INFO;
    ai.allocationSize = mr.size;
    ai.memoryTypeIndex = (uint32_t)mt;
    VKCK(p_vkAllocateMemory(g_dev, &ai, 0, mem));
    VKCK(p_vkBindBufferMemory(g_dev, *buf, *mem, 0));
    VKCK(p_vkMapMemory(g_dev, *mem, 0, sz, 0, map));
    return 0;
}

static int build_pipeline(void)
{
    size_t spvsz;
    uint32_t* owned;
    const uint32_t* spv = load_spv(&spvsz, &owned);
    VkShaderModuleCreateInfo smi;
    memset(&smi, 0, sizeof smi);
    smi.sType = ST_SHADER_MODULE_CREATE_INFO;
    smi.codeSize = spvsz;
    smi.pCode = spv;
    VkResult r = p_vkCreateShaderModule(g_dev, &smi, 0, &g_module);
    free(owned);
    if (r != VK_SUCCESS) return hvk_fail("vkCreateShaderModule failed");

    VkDescriptorSetLayoutBinding binds[2];
    memset(binds, 0, sizeof binds);
    for (int i = 0; i < 2; i++) {
        binds[i].binding = (uint32_t)i;
        binds[i].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        binds[i].descriptorCount = 1;
        binds[i].stageFlags = VK_SHADER_STAGE_COMPUTE_BIT;
    }
    VkDescriptorSetLayoutCreateInfo dli;
    memset(&dli, 0, sizeof dli);
    dli.sType = ST_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
    dli.bindingCount = 2;
    dli.pBindings = binds;
    VKCK(p_vkCreateDescriptorSetLayout(g_dev, &dli, 0, &g_dsl));

    VkPushConstantRange pcr;
    pcr.stageFlags = VK_SHADER_STAGE_COMPUTE_BIT;
    pcr.offset = 0;
    pcr.size = (uint32_t)sizeof(PushC);
    VkPipelineLayoutCreateInfo pli;
    memset(&pli, 0, sizeof pli);
    pli.sType = ST_PIPELINE_LAYOUT_CREATE_INFO;
    pli.setLayoutCount = 1;
    pli.pSetLayouts = &g_dsl;
    pli.pushConstantRangeCount = 1;
    pli.pPushConstantRanges = &pcr;
    VKCK(p_vkCreatePipelineLayout(g_dev, &pli, 0, &g_playout));

    VkComputePipelineCreateInfo cpi;
    memset(&cpi, 0, sizeof cpi);
    cpi.sType = ST_COMPUTE_PIPELINE_CREATE_INFO;
    cpi.stage.sType = ST_PIPELINE_SHADER_STAGE_CREATE_INFO;
    cpi.stage.stage = VK_SHADER_STAGE_COMPUTE_BIT;
    cpi.stage.module = g_module;
    cpi.stage.pName = "main";
    cpi.layout = g_playout;
    VKCK(p_vkCreateComputePipelines(g_dev, 0, 1, &cpi, 0, &g_pipe));

    VkDescriptorPoolSize psz;
    psz.type = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
    psz.descriptorCount = 2;
    VkDescriptorPoolCreateInfo dpi;
    memset(&dpi, 0, sizeof dpi);
    dpi.sType = ST_DESCRIPTOR_POOL_CREATE_INFO;
    dpi.maxSets = 1;
    dpi.poolSizeCount = 1;
    dpi.pPoolSizes = &psz;
    VKCK(p_vkCreateDescriptorPool(g_dev, &dpi, 0, &g_dpool));
    VkDescriptorSetAllocateInfo dsai;
    memset(&dsai, 0, sizeof dsai);
    dsai.sType = ST_DESCRIPTOR_SET_ALLOCATE_INFO;
    dsai.descriptorPool = g_dpool;
    dsai.descriptorSetCount = 1;
    dsai.pSetLayouts = &g_dsl;
    VKCK(p_vkAllocateDescriptorSets(g_dev, &dsai, &g_dset));
    return 0;
}

static int rebind_descriptors(void)
{
    /* Both buffers are written in one vkUpdateDescriptorSets, so this is a
     * no-op until both exist (the arena is created during bring-up, the frame
     * on the first hvk_frame_create). Not an error — just nothing to bind
     * yet; whichever call completes the pair does the real update. */
    if (!g_fbuf || !g_abuf) return 0;
    VkDescriptorBufferInfo dbi, sbi;
    dbi.buffer = g_fbuf; dbi.offset = 0;
    dbi.range = (VkDeviceSize)g_fw * (VkDeviceSize)g_fh * 4u;
    sbi.buffer = g_abuf; sbi.offset = 0; sbi.range = g_acap;
    VkWriteDescriptorSet wr[2];
    memset(wr, 0, sizeof wr);
    for (int i = 0; i < 2; i++) {
        wr[i].sType = ST_WRITE_DESCRIPTOR_SET;
        wr[i].dstSet = g_dset;
        wr[i].dstBinding = (uint32_t)i;
        wr[i].descriptorCount = 1;
        wr[i].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
    }
    wr[0].pBufferInfo = &dbi;
    wr[1].pBufferInfo = &sbi;
    p_vkUpdateDescriptorSets(g_dev, 2, wr, 0, 0);
    return 0;
}

static int ensure_arena(VkDeviceSize want)
{
    if (want <= g_acap) return 0;
    VkDeviceSize sz = g_acap ? g_acap : HVK_ARENA_MIN;
    while (sz < want) sz *= 2;
    p_vkDeviceWaitIdle(g_dev);
    /* Ops already recorded THIS frame index into the arena, so a grow must
     * carry their staged bytes across — dropping them would leave a blit
     * sampling whatever the new allocation happened to contain, which is
     * precisely the plausible-wrong-answer failure this codebase keeps
     * getting bitten by. */
    uint32_t keep = g_ause;
    /* The words already staged this frame are carried across from the MIRROR,
     * not read back out of the device mapping -- same bytes, no bus. */
    uint32_t* nshadow = (uint32_t*)malloc((size_t)sz);
    if (!nshadow) return hvk_fail("out of memory growing the source arena");
    if (keep && g_ashadow) memcpy(nshadow, g_ashadow, (size_t)keep * 4u);
    if (g_amap) { p_vkUnmapMemory(g_dev, g_amem); g_amap = 0; }
    if (g_abuf) { p_vkDestroyBuffer(g_dev, g_abuf, 0); g_abuf = 0; }
    if (g_amem) { p_vkFreeMemory(g_dev, g_amem, 0); g_amem = 0; }
    void* m = 0;
    if (make_storage_buffer(sz, g_arena_devlocal, &g_abuf, &g_amem, &m,
                            &g_adevlocal)) { free(nshadow); return -1; }
    g_amap = (uint32_t*)m;
    if (keep) memcpy(g_amap, nshadow, (size_t)keep * 4u);
    free(g_ashadow);
    g_ashadow = nshadow;
    g_acap = sz;
    g_stat_arena_bytes = (uint64_t)sz;
    return rebind_descriptors();
}

static int hvk_bringup(void)
{
    if (load_loader()) return -1;

    VkApplicationInfo app;
    memset(&app, 0, sizeof app);
    app.sType = ST_APPLICATION_INFO;
    app.pApplicationName = "hamnix-vk";
    app.apiVersion = (1u << 22);              /* 1.0 — everything we use is core */
    VkInstanceCreateInfo ici;
    memset(&ici, 0, sizeof ici);
    ici.sType = ST_INSTANCE_CREATE_INFO;
    ici.pApplicationInfo = &app;
    VKCK(p_vkCreateInstance(&ici, 0, &g_inst));

    uint32_t n = 0;
    VKCK(p_vkEnumeratePhysicalDevices(g_inst, &n, 0));
    if (n == 0) return hvk_fail("Vulkan loader found no physical device");
    if (n > 16) n = 16;
    VkPhysicalDevice devs[16];
    VKCK(p_vkEnumeratePhysicalDevices(g_inst, &n, devs));

    int best = -1, bestrank = -1;
    for (uint32_t i = 0; i < n; i++) {
        VkPhysicalDeviceProperties pr;
        memset(&pr, 0, sizeof pr);
        p_vkGetPhysicalDeviceProperties(devs[i], &pr);
        int r = rank_devtype(pr.deviceType);
        if (r > bestrank) { bestrank = r; best = (int)i; }
    }
    g_phys = devs[best];
    {
        VkPhysicalDeviceProperties pr;
        memset(&pr, 0, sizeof pr);
        p_vkGetPhysicalDeviceProperties(g_phys, &pr);
        snprintf(g_devname, sizeof g_devname, "%s", pr.deviceName);
        g_devtype = pr.deviceType;
        /* VALIDATE THE LIMITS LAYOUT BEFORE BELIEVING timestampPeriod. Vulkan
         * mandates each of these three minimums, so a struct whose fields had
         * slid would fail at least one; a period we cannot vouch for is
         * reported as "no GPU clock" rather than as a number. */
        const VkPhysicalDeviceLimitsHead* L = &pr.limits;
        if (L->maxPushConstantsSize >= 128 &&
            L->maxComputeWorkGroupInvocations >= 128 &&
            L->maxImageDimension2D >= 4096 &&
            L->timestampPeriod > 0.0f && L->timestampPeriod < 1000000.0f)
            g_ts_period = L->timestampPeriod;
    }

    uint32_t qn = 0;
    p_vkGetPhysicalDeviceQueueFamilyProperties(g_phys, &qn, 0);
    if (qn > 32) qn = 32;
    VkQueueFamilyProperties qf[32];
    memset(qf, 0, sizeof qf);
    p_vkGetPhysicalDeviceQueueFamilyProperties(g_phys, &qn, qf);
    int qfam = -1;
    for (uint32_t i = 0; i < qn; i++)
        if (qf[i].queueFlags & VK_QUEUE_COMPUTE_BIT) { qfam = (int)i; break; }
    if (qfam < 0) return hvk_fail("no compute-capable queue family");
    g_qfam = (uint32_t)qfam;
    g_ts_valid_bits = qf[qfam].timestampValidBits;

    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci;
    memset(&qci, 0, sizeof qci);
    qci.sType = ST_DEVICE_QUEUE_CREATE_INFO;
    qci.queueFamilyIndex = g_qfam;
    qci.queueCount = 1;
    qci.pQueuePriorities = &prio;
    VkDeviceCreateInfo dci;
    memset(&dci, 0, sizeof dci);
    dci.sType = ST_DEVICE_CREATE_INFO;
    dci.queueCreateInfoCount = 1;
    dci.pQueueCreateInfos = &qci;
    /* THE EXPORT EXTENSIONS, enabled iff the driver advertises all three.
     *
     * They cost nothing when unused and they are the difference between a
     * composite that has to be COPIED to the display and one the display can
     * SCAN OUT where it lies. Enabled here, at device creation, because that
     * is the only place it can be done -- a device created without them
     * cannot export later, and the failure then looks like "the driver cannot
     * export" rather than "we did not ask".
     *
     * Best-effort by design: a driver without them (or a software ICD) simply
     * gets g_can_export = 0 and every scanout entry point below refuses in a
     * way the caller can report. */
    const char* wanted[3] = { "VK_KHR_external_memory",
                              "VK_KHR_external_memory_fd",
                              "VK_EXT_external_memory_dma_buf" };
    if (p_vkEnumerateDeviceExtensionProperties) {
        uint32_t en = 0;
        p_vkEnumerateDeviceExtensionProperties(g_phys, 0, &en, 0);
        if (en > 0 && en < 4096) {
            VkExtensionProperties* ep =
                (VkExtensionProperties*)calloc(en, sizeof *ep);
            if (ep) {
                p_vkEnumerateDeviceExtensionProperties(g_phys, 0, &en, ep);
                int found = 0;
                for (uint32_t i = 0; i < en; i++)
                    for (int k = 0; k < 3; k++)
                        if (!strcmp(ep[i].extensionName, wanted[k])) found++;
                if (found >= 3) g_can_export = 1;
                free(ep);
            }
        }
    }
    if (g_can_export) {
        dci.enabledExtensionCount = 3;
        dci.ppEnabledExtensionNames = wanted;
    }
    if (p_vkCreateDevice(g_phys, &dci, 0, &g_dev) != VK_SUCCESS) {
        /* If the only difference was the extensions, retry without them
         * rather than lose the whole backend over an optional feature. */
        if (!g_can_export) return hvk_fail("vkCreateDevice failed");
        g_can_export = 0;
        dci.enabledExtensionCount = 0;
        dci.ppEnabledExtensionNames = 0;
        VKCK(p_vkCreateDevice(g_phys, &dci, 0, &g_dev));
    }
    p_vkGetDeviceQueue(g_dev, g_qfam, 0, &g_queue);
    /* RESOLVED THROUGH THE DEVICE, NOT dlsym. libvulkan.so.1 does NOT export
     * vkGetMemoryFdKHR as a dynamic symbol -- dlsym returns NULL for it on
     * this loader -- so a dlsym probe reports "this driver cannot export
     * dmabufs" about a driver that advertises all three extensions and
     * exports them perfectly well. Extension entry points come from
     * vkGetDeviceProcAddr. */
    if (g_can_export) {
        *(void**)(&p_vkGetMemoryFdKHR) =
            p_vkGetDeviceProcAddr(g_dev, "vkGetMemoryFdKHR");
        if (!p_vkGetMemoryFdKHR) g_can_export = 0;
    }
    memset(&g_memprops, 0, sizeof g_memprops);
    p_vkGetPhysicalDeviceMemoryProperties(g_phys, &g_memprops);

    VkCommandPoolCreateInfo pci;
    memset(&pci, 0, sizeof pci);
    pci.sType = ST_COMMAND_POOL_CREATE_INFO;
    pci.queueFamilyIndex = g_qfam;
    VKCK(p_vkCreateCommandPool(g_dev, &pci, 0, &g_pool));
    VkFenceCreateInfo fci;
    memset(&fci, 0, sizeof fci);
    fci.sType = ST_FENCE_CREATE_INFO;
    VKCK(p_vkCreateFence(g_dev, &fci, 0, &g_fence));

    /* Two timestamps, head and tail of the command buffer. Only created when
     * the queue can actually carry them, so hvk_stat_gpu_ns() staying 0 means
     * "this device has no usable GPU clock", not "the frame took no time". */
    if (g_ts_valid_bits > 0 && g_ts_period > 0.0f) {
        VkQueryPoolCreateInfo qpi;
        memset(&qpi, 0, sizeof qpi);
        qpi.sType = ST_QUERY_POOL_CREATE_INFO;
        qpi.queryType = VK_QUERY_TYPE_TIMESTAMP;
        qpi.queryCount = 2;
        if (p_vkCreateQueryPool(g_dev, &qpi, 0, &g_qpool) != VK_SUCCESS)
            g_qpool = 0;
    }
    if (getenv("HAMNIX_VK_VERBOSE"))
        fprintf(stderr, "[linux-vk] timestampValidBits=%u period=%g qpool=%d\n",
                g_ts_valid_bits, (double)g_ts_period, g_qpool ? 1 : 0);

    hvk_tunables();
    if (build_pipeline()) return -1;
    if (ensure_arena(HVK_ARENA_MIN)) return -1;
    g_err[0] = 0;
    g_state = 1;
    return 0;
}

/* ============================== public C ABI ============================== */

/* 1 iff a real ICD, a real device and the compute pipeline all came up. Every
 * other entry point is a no-op returning failure when this is 0, so the Adder
 * side has exactly one thing to check and no way to half-succeed. */
int32_t hvk_available(void)
{
    if (g_state == 0) hvk_bringup();
    return g_state == 1 ? 1 : 0;
}

/* NUL-terminated device name (or the reason there is none) into caller BSS. */
int32_t hvk_device_name(uint8_t* buf, int32_t cap)
{
    if (!buf || cap <= 0) return 0;
    const char* s = (g_state == 1) ? g_devname : g_err;
    int32_t i = 0;
    while (s[i] && i < cap - 1) { buf[i] = (uint8_t)s[i]; i++; }
    buf[i] = 0;
    return i;
}

/* VkPhysicalDeviceType: 1 integrated, 2 discrete, 3 virtual, 4 CPU (a software
 * ICD such as lavapipe). Reported rather than hidden — a caller that only
 * wants real silicon can refuse type 4 itself. */
int32_t hvk_device_type(void) { return (int32_t)g_devtype; }

/* 1 iff the frame buffer landed in memory that is device-local AND mappable.
 * 0 means the shader reaches the frame across the host bus (a discrete GPU
 * with no resizable BAR), which is exactly when GPU raster may LOSE to the
 * CPU. Callers should treat 0 as "measure before trusting". */
int32_t hvk_frame_is_device_local(void) { return g_fdevlocal ? 1 : 0; }

/* 1 iff the frame landed in HOST_CACHED memory -- i.e. iff the CPU can read
 * the composite at ordinary RAM speed. This is the number that decides whether
 * present_rows() costs 0.2 ms or 88 ms, so it is reported separately from
 * device-local rather than inferred from it: on this card the two are mutually
 * exclusive, and the one that matters for a compositor is THIS one. */
int32_t hvk_frame_is_host_cached(void)
{
    return (g_fflags & VK_MEMORY_PROPERTY_HOST_CACHED_BIT) ? 1 : 0;
}

/* Create (or resize) the GPU-resident frame and return its mapped address, or
 * 0. The pointer is stable until the next size change: hand it to the vk color
 * image / compositor shadow and the whole path is copy-free. `bgra` selects
 * B8G8R8A8 store order, matching vk2d_set_bgra on the software side. */
uint64_t hvk_frame_create(int32_t w, int32_t h, int32_t bgra)
{
    if (!hvk_available()) return 0;
    if (w <= 0 || h <= 0) return 0;
    g_fbgra = bgra ? 1 : 0;
    if (g_fmap && w == g_fw && h == g_fh) return (uint64_t)(uintptr_t)g_fmap;
    p_vkDeviceWaitIdle(g_dev);
    if (g_fmap) { p_vkUnmapMemory(g_dev, g_fmem); g_fmap = 0; }
    if (g_fbuf) { p_vkDestroyBuffer(g_dev, g_fbuf, 0); g_fbuf = 0; }
    if (g_fmem) { p_vkFreeMemory(g_dev, g_fmem, 0); g_fmem = 0; }
    void* m = 0;
    VkDeviceSize sz = (VkDeviceSize)w * (VkDeviceSize)h * 4u;
    /* THE PLACEMENT DECISION, and it is not the obvious one.
     *
     * This buffer used to ask for DEVICE_LOCAL unconditionally, on the
     * reasoning that the shader should reach the frame at device speed. On a
     * discrete card with no resizable BAR that lands it in the 256 MiB BAR
     * aperture, which IS host-mappable -- so nothing fails, nothing warns, and
     * every CPU read of the composite becomes an uncached PCIe round trip.
     * wsysd reads the whole composite every frame, because present_rows()
     * write(2)s it to /dev/fb and the cursor save-under reads it directly, so
     * that decision cost 67 ms per frame and made the GPU path 13x SLOWER than
     * the software rasterizer. See the placement table above
     * make_storage_buffer for the measured 393x.
     *
     * The frame is therefore placed HOST_CACHED by default. The shader's
     * writes then cross PCIe, but a GPU write across PCIe is POSTED -- it is
     * fire-and-forget and the device does not stall on it -- whereas a CPU
     * read of VRAM is a synchronous round trip with no prefetch. The two
     * directions are not symmetric, and that asymmetry is the whole fix. */
    hvk_tunables();
    if (make_storage_buffer(sz, g_frame_place, &g_fbuf, &g_fmem, &m,
                            &g_fdevlocal)) {
        g_fw = g_fh = 0;
        return 0;
    }
    g_fflags = g_last_place_flags;
    g_fmap = (uint8_t*)m;
    g_fw = w;
    g_fh = h;
    if (rebind_descriptors()) return 0;
    return (uint64_t)(uintptr_t)g_fmap;
}

/* ==================================================================
 * THE SCANOUT FRAME: a composite the display engine reads directly
 * ==================================================================
 * Everything above is about how expensive it is to get the composite from
 * where the GPU wrote it to where the display can read it. This is the path
 * where that question does not arise, because they are the same memory.
 *
 * The frame is allocated DEVICE-LOCAL and EXPORTABLE and is deliberately NOT
 * host-mapped -- no BAR, no bus, no CPU pointer to be tempted by. Its dmabuf
 * fd goes to DRM, which imports it (PRIME_FD_TO_HANDLE) and makes a
 * framebuffer object of it (ADDFB2); from then on the compute shader
 * rasterizes into VRAM and the CRTC scans that same VRAM out. Nothing crosses
 * PCIe toward the CPU, ever, so the 88 ms readback is not reduced, it is
 * ABSENT -- and so is the 4 MiB write(2), and so is /dev/fb.
 *
 * The cost of that is that the CPU can no longer touch the composite, which
 * is a real constraint and not a detail: wsysd's cursor save-under and its
 * software fallback for un-encodable ops both read and write comp_base
 * directly. A compositor on this path has to do those on the device too.
 *
 * hvk_frame_is_scanout() reports 0 unless every step succeeded, so a caller
 * cannot mistake a partial bring-up for a working one.
 */
int32_t hvk_can_export_dmabuf(void) { return g_can_export && p_vkGetMemoryFdKHR ? 1 : 0; }
int32_t hvk_frame_is_scanout(void)  { return (g_fexported && g_fdmabuf >= 0) ? 1 : 0; }

/* Create the frame as a device-local, exportable, UNMAPPED buffer and export
 * a dmabuf fd for it. Returns the fd (>= 0), or a negative error:
 *   -1 no device, -2 the export extensions are not available,
 *   -3 allocation failed, -4 the driver refused the export.
 * The fd is owned by this module and closed on the next frame create. */
int32_t hvk_frame_create_scanout(int32_t w, int32_t h, int32_t bgra)
{
    if (!hvk_available()) return -1;
    if (!hvk_can_export_dmabuf()) return -2;
    if (w <= 0 || h <= 0) return -1;
    g_fbgra = bgra ? 1 : 0;
    p_vkDeviceWaitIdle(g_dev);
    if (g_fdmabuf >= 0) { close(g_fdmabuf); g_fdmabuf = -1; }
    if (g_fmap) { p_vkUnmapMemory(g_dev, g_fmem); g_fmap = 0; }
    if (g_fbuf) { p_vkDestroyBuffer(g_dev, g_fbuf, 0); g_fbuf = 0; }
    if (g_fmem) { p_vkFreeMemory(g_dev, g_fmem, 0); g_fmem = 0; }
    g_fexported = 0;
    VkDeviceSize sz = (VkDeviceSize)w * (VkDeviceSize)h * 4u;

    VkExternalMemoryBufferCreateInfo ext;
    memset(&ext, 0, sizeof ext);
    ext.sType = ST_EXTERNAL_MEMORY_BUFFER_CREATE_INFO;
    ext.handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT;
    VkBufferCreateInfo bc;
    memset(&bc, 0, sizeof bc);
    bc.sType = ST_BUFFER_CREATE_INFO;
    bc.pNext = &ext;
    bc.size = sz;
    bc.usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT
             | VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    bc.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    if (p_vkCreateBuffer(g_dev, &bc, 0, &g_fbuf) != VK_SUCCESS)
        return hvk_fail("scanout: vkCreateBuffer(exportable) failed"), -3;
    VkMemoryRequirements mr;
    memset(&mr, 0, sizeof mr);
    p_vkGetBufferMemoryRequirements(g_dev, g_fbuf, &mr);
    /* DEVICE_LOCAL only -- not host-visible. This is real VRAM, the fast kind,
     * the kind the shader and the display controller both reach at full
     * speed and the CPU cannot reach at all. */
    int mt = find_mem(mr.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    if (mt < 0) return hvk_fail("scanout: no device-local memory type"), -3;
    VkExportMemoryAllocateInfo eai;
    memset(&eai, 0, sizeof eai);
    eai.sType = ST_EXPORT_MEMORY_ALLOCATE_INFO;
    eai.handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT;
    VkMemoryAllocateInfo ai;
    memset(&ai, 0, sizeof ai);
    ai.sType = ST_MEMORY_ALLOCATE_INFO;
    ai.pNext = &eai;
    ai.allocationSize = mr.size;
    ai.memoryTypeIndex = (uint32_t)mt;
    if (p_vkAllocateMemory(g_dev, &ai, 0, &g_fmem) != VK_SUCCESS)
        return hvk_fail("scanout: vkAllocateMemory(exportable) failed"), -3;
    if (p_vkBindBufferMemory(g_dev, g_fbuf, g_fmem, 0) != VK_SUCCESS)
        return hvk_fail("scanout: vkBindBufferMemory failed"), -3;

    VkMemoryGetFdInfoKHR gi;
    memset(&gi, 0, sizeof gi);
    gi.sType = ST_MEMORY_GET_FD_INFO_KHR;
    gi.memory = g_fmem;
    gi.handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT;
    int fd = -1;
    if (p_vkGetMemoryFdKHR(g_dev, &gi, &fd) != VK_SUCCESS || fd < 0)
        return hvk_fail("scanout: vkGetMemoryFdKHR refused the export"), -4;

    g_fmap = 0;                 /* THERE IS NO CPU POINTER. On purpose. */
    g_fw = w; g_fh = h;
    g_fdevlocal = 1;
    g_fflags = VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;
    g_fexported = 1;
    g_fdmabuf = fd;
    if (rebind_descriptors()) return -3;
    return fd;
}

uint64_t hvk_frame_base(void) { return (uint64_t)(uintptr_t)g_fmap; }
int32_t  hvk_frame_width(void)  { return g_fw; }
int32_t  hvk_frame_height(void) { return g_fh; }

/* Start recording a frame's op list. Ops accumulate until hvk_frame_end (or an
 * intervening hvk_frame_sync) submits them. */
int32_t hvk_frame_begin(void)
{
    /* A SCANOUT frame has no CPU mapping by design, so "is there a frame?"
     * cannot be spelled `g_fmap` any more. */
    if (!hvk_available() || (!g_fmap && !g_fexported)) return -1;
    g_nops = 0;
    g_ause = 0;
    g_ncov = 0;
    g_frame_err = 0;
    g_barriers = 0;
    g_in_frame = 1;
    return 0;
}

/* Record one dispatch. (rx0,ry0,rx1,ry1) is the half-open rect of destination
 * pixels the op can WRITE — normally the dispatch extent, but a line's brush
 * lands outside its 1x1 dispatch, so it is passed explicitly.
 *
 * A barrier is inserted only when this op's rect touches the union of the
 * rects written since the last barrier. Disjoint from the union implies
 * disjoint from every op in it, so the order the device runs them in cannot
 * change a single pixel — while a text run of 400 glyphs collapses from 400
 * serialized dispatches to one parallel batch. */
static void push_op_rect(PushC pc, int32_t dispw, int32_t disph,
                         int32_t rx0, int32_t ry0, int32_t rx1, int32_t ry1)
{
    if (dispw <= 0 || disph <= 0) return;
    if (g_nops >= HVK_MAXOPS) { g_frame_err = -1; return; }
    pc.img_w = g_fw;
    pc.img_h = g_fh;
    pc.dispw = dispw;
    pc.disph = disph;
    if (rx0 < 0) rx0 = 0;
    if (ry0 < 0) ry0 = 0;
    if (rx1 > g_fw) rx1 = g_fw;
    if (ry1 > g_fh) ry1 = g_fh;

    int need_barrier = 0;
    if (g_nops == 0) {
        g_bbx0 = g_bby0 = 0x7FFFFFFF;
        g_bbx1 = g_bby1 = -0x7FFFFFFF;
        g_ncur = 0;
    } else if (rx0 < g_bbx1 && g_bbx0 < rx1 && ry0 < g_bby1 && g_bby0 < ry1) {
        /* The union says MAYBE. Ask the rects it is a union OF. */
        if (g_ncur < 0) {
            need_barrier = 1;              /* list overflowed: stay correct */
        } else {
            for (int32_t k = 0; k < g_ncur; k++)
                if (rx0 < g_cur[k][2] && g_cur[k][0] < rx1 &&
                    ry0 < g_cur[k][3] && g_cur[k][1] < ry1) {
                    need_barrier = 1;
                    break;
                }
            if (!need_barrier) g_stat_falsecon++;
        }
    }
    if (need_barrier) {
        g_bbx0 = rx0; g_bby0 = ry0; g_bbx1 = rx1; g_bby1 = ry1;
        g_ncur = 0;
        g_barriers++;
    } else {
        if (rx0 < g_bbx0) g_bbx0 = rx0;
        if (ry0 < g_bby0) g_bby0 = ry0;
        if (rx1 > g_bbx1) g_bbx1 = rx1;
        if (ry1 > g_bby1) g_bby1 = ry1;
    }
    if (g_ncur >= 0) {
        if (g_ncur < HVK_TRACK_MAX) {
            g_cur[g_ncur][0] = rx0; g_cur[g_ncur][1] = ry0;
            g_cur[g_ncur][2] = rx1; g_cur[g_ncur][3] = ry1;
            g_ncur++;
        } else {
            g_ncur = -1;
        }
    }
    g_bar[g_nops] = (uint8_t)need_barrier;
    g_rect[g_nops][0] = rx0; g_rect[g_nops][1] = ry0;
    g_rect[g_nops][2] = rx1; g_rect[g_nops][3] = ry1;
    g_ops[g_nops] = pc;
    g_grp[g_nops][0] = (uint32_t)((dispw + 7) / 8);
    g_grp[g_nops][1] = (uint32_t)((disph + 7) / 8);
    g_nops++;
    g_stat_ops++;
}

static void push_op(PushC pc, int32_t dispw, int32_t disph)
{
    push_op_rect(pc, dispw, disph, pc.bx, pc.by, pc.bx + dispw, pc.by + disph);
}

/* vk_2d.ad flips R and B of the OP COLOUR when the destination image is BGRA
 * (see vk2d_set_bgra); the shader has no notion of store order, so the swap
 * happens here, once, on the way in. */
static uint32_t frame_color(uint32_t rgba)
{
    if (!g_fbgra) return rgba;
    uint32_t r = (rgba >> 24) & 0xFF, g = (rgba >> 16) & 0xFF;
    uint32_t b = (rgba >> 8) & 0xFF,  a = rgba & 0xFF;
    return (b << 24) | (g << 16) | (r << 8) | a;
}

/* op: 0 = opaque fill (vk2d_raster_fill_rect), 1 = source-over
 * (vk2d_raster_fill_rect_alpha). Clipping mirrors vk_2d exactly. */
int32_t hvk_fill_rect(int32_t op, int32_t x, int32_t y, int32_t w, int32_t h,
                      uint32_t rgba)
{
    if (!g_in_frame) return -1;
    if (w <= 0 || h <= 0) return 0;
    if (op == OP_FILL_ALPHA && (rgba & 0xFF) == 0) return 0;
    if (op == OP_FILL_ALPHA && (rgba & 0xFF) == 0xFF) op = OP_FILL;
    int32_t x0 = x < 0 ? 0 : x, y0 = y < 0 ? 0 : y;
    int32_t x1 = x + w > g_fw ? g_fw : x + w;
    int32_t y1 = y + h > g_fh ? g_fh : y + h;
    if (x0 >= x1 || y0 >= y1) return 0;
    PushC pc;
    memset(&pc, 0, sizeof pc);
    pc.op = op;
    pc.rgba = frame_color(rgba);
    pc.bx = x0;
    pc.by = y0;
    push_op(pc, x1 - x0, y1 - y0);
    return 0;
}

int32_t hvk_roundrect(int32_t x, int32_t y, int32_t w, int32_t h,
                      int32_t rad, int32_t corners, uint32_t rgba)
{
    if (!g_in_frame) return -1;
    if (w <= 0 || h <= 0 || (rgba & 0xFF) == 0) return 0;
    int32_t rr = rad;
    if (rr < 0) rr = 0;
    if (rr > w / 2) rr = w / 2;
    if (rr > h / 2) rr = h / 2;
    if (rr <= 0) return hvk_fill_rect(OP_FILL_ALPHA, x, y, w, h, rgba);
    int32_t x0 = x < 0 ? 0 : x, y0 = y < 0 ? 0 : y;
    int32_t x1 = x + w > g_fw ? g_fw : x + w;
    int32_t y1 = y + h > g_fh ? g_fh : y + h;
    if (x0 >= x1 || y0 >= y1) return 0;
    PushC pc;
    memset(&pc, 0, sizeof pc);
    pc.op = OP_ROUNDRECT;
    pc.rgba = frame_color(rgba);
    pc.bx = x0; pc.by = y0;
    pc.px = x;  pc.py = y;
    pc.pw = w;  pc.ph = h;
    pc.rad = rr;
    pc.corners = corners;
    push_op(pc, x1 - x0, y1 - y0);
    return 0;
}

/* Thick Bresenham line. The walk is inherently sequential, so the shader runs
 * it on ONE invocation — correct and pixel-identical, but no faster than the
 * CPU. Lines are a handful of ops per DE frame; keeping them on the device
 * costs one dispatch and avoids a mid-frame CPU/GPU ordering flush, which is
 * the reason this is here at all. */
int32_t hvk_line(int32_t x1, int32_t y1, int32_t x2, int32_t y2,
                 int32_t thick, uint32_t rgba)
{
    if (!g_in_frame) return -1;
    PushC pc;
    memset(&pc, 0, sizeof pc);
    pc.op = OP_LINE;
    pc.rgba = frame_color(rgba);
    pc.px = x1; pc.py = y1;
    pc.pw = x2; pc.ph = y2;
    pc.rad = thick;
    /* The Bresenham brush writes over the line's whole bounding box, not the
     * 1x1 grid it dispatches on, so the rect the overlap test needs is that
     * box grown by the brush size. */
    int32_t t = thick < 1 ? 1 : thick;
    int32_t lx0 = x1 < x2 ? x1 : x2, lx1 = (x1 > x2 ? x1 : x2) + t;
    int32_t ly0 = y1 < y2 ? y1 : y2, ly1 = (y1 > y2 ? y1 : y2) + t;
    push_op_rect(pc, 1, 1, lx0, ly0, lx1, ly1);
    return 0;
}

/* Copy `words` uint32s into the source arena, returning the base index, or -1.
 * Every blit/glyph source is staged here because the shader reads ONE storage
 * buffer for all of them; mask_off makes them share it. */
static int32_t arena_put(const void* src, uint32_t words)
{
    if (ensure_arena((VkDeviceSize)(g_ause + words) * 4u)) { g_frame_err = -1; return -1; }
    uint32_t off = g_ause;
    memcpy(g_amap + off, src, (size_t)words * 4u);
    memcpy(g_ashadow + off, src, (size_t)words * 4u);
    g_ause += words;
    g_stat_staged += words;
    return (int32_t)off;
}

/* Nearest-neighbour, source-over, optionally scaled blit — vk2d_raster_blit's
 * op. dw/dh <= 0 means "natural size"; sw/sh <= 0 means "the whole source".
 * The source image is RGBA8888 in HOST memory (a window surface, an icon, a
 * glyph atlas), so it is staged into the arena; a BGRA frame gets the same
 * per-pixel R/B flip vk_2d applies, done in the shader via `corners`. */
int32_t hvk_blit(uint64_t src_base, int32_t src_w, int32_t src_h,
                 int32_t dx, int32_t dy, int32_t dw, int32_t dh,
                 int32_t sx, int32_t sy, int32_t sw, int32_t sh)
{
    if (!g_in_frame) return -1;
    if (!src_base || src_w <= 0 || src_h <= 0) return 0;
    int32_t rsx = sx, rsy = sy, rsw = sw, rsh = sh;
    if (rsw <= 0) rsw = src_w;
    if (rsh <= 0) rsh = src_h;
    if (rsx < 0) rsx = 0;
    if (rsy < 0) rsy = 0;
    if (rsx + rsw > src_w) rsw = src_w - rsx;
    if (rsy + rsh > src_h) rsh = src_h - rsy;
    if (rsw <= 0 || rsh <= 0) return 0;
    int32_t tw = dw > 0 ? dw : rsw;
    int32_t th = dh > 0 ? dh : rsh;
    int32_t yy0 = dy < 0 ? -dy : 0;
    int32_t yy1 = dy + th > g_fh ? g_fh - dy : th;
    int32_t xx0 = dx < 0 ? -dx : 0;
    int32_t xx1 = dx + tw > g_fw ? g_fw - dx : tw;
    if (xx0 >= xx1 || yy0 >= yy1) return 0;

    /* Stage only the rows the op can actually sample, not the whole image. */
    int32_t row0 = rsy, row1 = rsy + rsh;
    uint32_t words = (uint32_t)src_w * (uint32_t)(row1 - row0);
    int32_t off = arena_put((const uint8_t*)(uintptr_t)src_base
                            + (size_t)row0 * (size_t)src_w * 4u, words);
    if (off < 0) return -1;

    PushC pc;
    memset(&pc, 0, sizeof pc);
    pc.op = OP_BLIT;
    pc.bx = dx + xx0;
    pc.by = dy + yy0;
    pc.dx = dx; pc.dy = dy;
    pc.rsx = rsx; pc.rsy = 0;            /* rows rebased to the staged slice */
    pc.rsw = rsw; pc.rsh = rsh;
    pc.tw = tw;   pc.th = th;
    pc.src_w = src_w;
    pc.src_h = row1 - row0;
    pc.mask_off = off;
    pc.corners = g_fbgra;                /* shader-side source R/B flip */
    push_op(pc, xx1 - xx0, yy1 - yy0);
    return 0;
}

/* Anti-aliased glyph / ink coverage mask — vk2d_raster_cov_mask's op. cov_base
 * is cov_w*cov_h BYTES of coverage; the shader indexes one coverage value per
 * uint, so the expansion happens here on the way into the arena. */
int32_t hvk_glyph(uint64_t cov_base, int32_t cov_w, int32_t cov_h,
                  int32_t dx, int32_t dy, uint32_t rgba)
{
    if (!g_in_frame) return -1;
    if (!cov_base || cov_w <= 0 || cov_h <= 0 || (rgba & 0xFF) == 0) return 0;
    int32_t x0 = dx < 0 ? 0 : dx, y0 = dy < 0 ? 0 : dy;
    int32_t x1 = dx + cov_w > g_fw ? g_fw : dx + cov_w;
    int32_t y1 = dy + cov_h > g_fh ? g_fh : dy + cov_h;
    if (x0 >= x1 || y0 >= y1) return 0;
    uint32_t words = (uint32_t)cov_w * (uint32_t)cov_h;
    const uint8_t* cov = (const uint8_t*)(uintptr_t)cov_base;

    /* Have we already staged exactly these bytes this frame? The whole
     * lookup -- hash included -- is skipped when the cache is disabled, so
     * HAMNIX_VK_NO_COVCACHE=1 measures the frame WITHOUT the cache rather
     * than the frame paying for a cache it is forbidden to use. */
    hvk_tunables();
    uint32_t hsh = 0;
    int32_t off = -1;
    if (!g_no_covcache) {
        hsh = 2166136261u;
        for (uint32_t i = 0; i < words; i++)
            hsh = (hsh ^ cov[i]) * 16777619u;
        for (int32_t k = 0; k < g_ncov; k++) {
            if (g_cov[k].hash != hsh || g_cov[k].w != cov_w || g_cov[k].h != cov_h)
                continue;
            /* The MIRROR, never g_amap: identical bytes, ordinary cached RAM.
             * See the g_ashadow comment -- this one line was 32 ms a frame. */
            const uint32_t* have = g_ashadow + g_cov[k].off;
            uint32_t i = 0;
            while (i < words && have[i] == (uint32_t)cov[i]) i++;
            if (i == words) { off = g_cov[k].off; g_stat_covreuse++; break; }
        }
    }
    if (off < 0) {
        if (ensure_arena((VkDeviceSize)(g_ause + words) * 4u)) {
            g_frame_err = -1;
            return -1;
        }
        off = (int32_t)g_ause;
        for (uint32_t i = 0; i < words; i++) {
            uint32_t v = cov[i];
            g_amap[off + i] = v;
            g_ashadow[off + i] = v;
        }
        g_ause += words;
        g_stat_staged += words;
        if (!g_no_covcache && g_ncov < HVK_COV_CACHE) {
            g_cov[g_ncov].hash = hsh;
            g_cov[g_ncov].w = cov_w;
            g_cov[g_ncov].h = cov_h;
            g_cov[g_ncov].off = off;
            g_ncov++;
        }
    }

    PushC pc;
    memset(&pc, 0, sizeof pc);
    pc.op = OP_COVMASK;
    pc.rgba = frame_color(rgba);
    pc.bx = x0; pc.by = y0;
    pc.px = dx; pc.py = dy;
    pc.pw = cov_w; pc.ph = cov_h;
    pc.mask_off = (int32_t)off;
    push_op(pc, x1 - x0, y1 - y0);
    return 0;
}

/* Stage `cnt` recorded ops as an OP_BATCH table (24 uints each, mirroring the
 * push-constant block field for field — see scripts/shaders/vk2d_raster.comp).
 * Returns the table's base index in src[], or -1. */
static int32_t batch_table(int32_t first, int32_t cnt)
{
    uint32_t words = (uint32_t)cnt * HVK_BATCH_STRIDE;
    if (ensure_arena((VkDeviceSize)(g_ause + words) * 4u)) return -1;
    uint32_t off = g_ause;
    /* Built in the MIRROR (cached RAM) and copied out in one streaming pass,
     * rather than 24 scattered stores straight into the device mapping. */
    for (int32_t n = 0; n < cnt; n++) {
        const PushC* o = &g_ops[first + n];
        uint32_t* e = g_ashadow + off + (uint32_t)n * HVK_BATCH_STRIDE;
        e[0]  = (uint32_t)o->op;    e[1]  = (uint32_t)o->bx;
        e[2]  = (uint32_t)o->by;    e[3]  = (uint32_t)o->dispw;
        e[4]  = (uint32_t)o->disph; e[5]  = o->rgba;
        e[6]  = (uint32_t)o->px;    e[7]  = (uint32_t)o->py;
        e[8]  = (uint32_t)o->pw;    e[9]  = (uint32_t)o->ph;
        e[10] = (uint32_t)o->rad;   e[11] = (uint32_t)o->corners;
        e[12] = (uint32_t)o->dx;    e[13] = (uint32_t)o->dy;
        e[14] = (uint32_t)o->rsx;   e[15] = (uint32_t)o->rsy;
        e[16] = (uint32_t)o->rsw;   e[17] = (uint32_t)o->rsh;
        e[18] = (uint32_t)o->tw;    e[19] = (uint32_t)o->th;
        e[20] = (uint32_t)o->src_w; e[21] = (uint32_t)o->src_h;
        e[22] = (uint32_t)o->mask_off;
        e[23] = 0;
    }
    memcpy(g_amap + off, g_ashadow + off, (size_t)words * 4u);
    g_ause += words;
    g_stat_staged += words;
    return (int32_t)off;
}

/* Record + submit every pending op and WAIT. On return the frame's pixels are
 * final and visible through the mapped pointer, so the caller may read them,
 * present them, or run the software rasterizer over them for an op the device
 * does not encode — the ordering guarantee that makes mixed frames correct. */
int32_t hvk_frame_sync(void)
{
    hvk_tunables();
    if (!hvk_available() || !g_fmap) return -1;
    if (g_nops == 0) return g_frame_err;
    uint64_t t0 = now_us();

    /* One command buffer for the life of the process, recycled through the
     * pool. The recording is a different LIST every frame but always the same
     * SHAPE, so allocating and freeing one per submit was two driver round
     * trips a frame bought for nothing. */
    if (!g_cb) {
        VkCommandBufferAllocateInfo cai;
        memset(&cai, 0, sizeof cai);
        cai.sType = ST_COMMAND_BUFFER_ALLOCATE_INFO;
        cai.commandPool = g_pool;
        cai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        cai.commandBufferCount = 1;
        VKCK(p_vkAllocateCommandBuffers(g_dev, &cai, &g_cb));
    } else {
        VKCK(p_vkResetCommandPool(g_dev, g_pool, 0));
    }
    VkCommandBuffer cb = g_cb;
    VkCommandBufferBeginInfo bi;
    memset(&bi, 0, sizeof bi);
    bi.sType = ST_COMMAND_BUFFER_BEGIN_INFO;
    bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    VKCK(p_vkBeginCommandBuffer(cb, &bi));

    if (g_qpool) {
        p_vkCmdResetQueryPool(cb, g_qpool, 0, 2);
        p_vkCmdWriteTimestamp(cb, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, g_qpool, 0);
    }
    p_vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_COMPUTE, g_pipe);
    p_vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_COMPUTE, g_playout,
                              0, 1, &g_dset, 0, 0);
    /* 2D painting is ORDERED: op n+1 may blend over op n's pixels, so a
     * shader-write -> shader-read barrier separates every dispatch. */
    VkMemoryBarrier mb;
    memset(&mb, 0, sizeof mb);
    mb.sType = ST_MEMORY_BARRIER;
    mb.srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT;
    mb.dstAccessMask = VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_SHADER_WRITE_BIT;
    int32_t i = 0;
    while (i < g_nops) {
        if (g_bar[i])
            p_vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                                   VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                                   0, 1, &mb, 0, 0, 0, 0);
        /* [i, gend) is a maximal run of ops that are pairwise disjoint (each
         * was checked against the union of the ones before it), so they may
         * execute in ANY order — including all at once. */
        int32_t gend = i + 1;
        while (gend < g_nops && !g_bar[gend]) gend++;

        int32_t j = i;
        while (j < gend) {
            int32_t k = j;
            uint32_t mgx = g_grp[j][0], mgy = g_grp[j][1];
            uint64_t sum = (uint64_t)mgx * mgy;
            int32_t cnt = 1;
            /* A batch dispatches maxgx*maxgy workgroups for EVERY entry, so
             * mixing a full-screen fill with a glyph would launch millions of
             * workgroups that immediately return. Grow the batch only while
             * the padded launch stays within 2x the work the separate
             * dispatches would have done. */
            while (k + 1 < gend && cnt < g_batch_max) {
                uint32_t nx = g_grp[k + 1][0] > mgx ? g_grp[k + 1][0] : mgx;
                uint32_t ny = g_grp[k + 1][1] > mgy ? g_grp[k + 1][1] : mgy;
                uint64_t nsum = sum + (uint64_t)g_grp[k + 1][0] * g_grp[k + 1][1];
                if ((uint64_t)nx * ny * (uint64_t)(cnt + 1) > 2 * nsum) break;
                mgx = nx; mgy = ny; sum = nsum; cnt++; k++;
            }
            if (cnt == 1) {
                p_vkCmdPushConstants(cb, g_playout, VK_SHADER_STAGE_COMPUTE_BIT,
                                     0, (uint32_t)sizeof(PushC), &g_ops[j]);
                p_vkCmdDispatch(cb, g_grp[j][0], g_grp[j][1], 1);
            } else {
                int32_t off = batch_table(j, cnt);
                if (off < 0) { g_frame_err = -1; break; }
                PushC bpc;
                memset(&bpc, 0, sizeof bpc);
                bpc.op = OP_BATCH;
                bpc.img_w = g_fw;
                bpc.img_h = g_fh;
                bpc.rad = cnt;              /* entry count   */
                bpc.mask_off = off;         /* table base    */
                p_vkCmdPushConstants(cb, g_playout, VK_SHADER_STAGE_COMPUTE_BIT,
                                     0, (uint32_t)sizeof(PushC), &bpc);
                p_vkCmdDispatch(cb, mgx, mgy, (uint32_t)cnt);
                g_stat_batched += (uint64_t)cnt;
            }
            g_stat_dispatches++;
            j = k + 1;
        }
        i = gend;
    }
    if (g_qpool)
        p_vkCmdWriteTimestamp(cb, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, g_qpool, 1);
    VKCK(p_vkEndCommandBuffer(cb));
    uint64_t t_rec = now_us();

    VkSubmitInfo si;
    memset(&si, 0, sizeof si);
    si.sType = ST_SUBMIT_INFO;
    si.commandBufferCount = 1;
    si.pCommandBuffers = &cb;
    VKCK(p_vkResetFences(g_dev, 1, &g_fence));
    VKCK(p_vkQueueSubmit(g_queue, 1, &si, g_fence));
    VKCK(p_vkWaitForFences(g_dev, 1, &g_fence, VK_TRUE, ~0ull));

    uint64_t t_end = now_us();
    g_stat_record_us = t_rec - t0;
    g_stat_wait_us = t_end - t_rec;
    /* The fence is already signalled, so this reads back two already-written
     * queries and never blocks. A tick count is masked to the bits the queue
     * says are valid before it is scaled. */
    g_stat_gpu_ns = 0;
    if (g_qpool) {
        uint64_t ts[2] = { 0, 0 };
        VkResult qr = p_vkGetQueryPoolResults(g_dev, g_qpool, 0, 2, sizeof ts, ts,
                                    sizeof(uint64_t),
                                    VK_QUERY_RESULT_64_BIT
                                    | VK_QUERY_RESULT_WAIT_BIT);
        /* A query pool we created, on a queue that advertised valid timestamp
         * bits, that then hands back two zeroes is a BROKEN INSTRUMENT, not a
         * device without a clock -- and it would print as "gpu_us 0", which
         * reads like a free frame. It was exactly this: the pool was created
         * with the wrong queryType and every timestamp silently wrote nothing.
         * Say so once, by name, rather than let a zero be quoted. */
        if (qr == VK_SUCCESS && ts[0] == 0 && ts[1] == 0 && !g_ts_warned) {
            g_ts_warned = 1;
            fprintf(stderr, "[linux-vk] WARNING: timestamp queries returned "
                    "0/0 on a queue advertising %u valid bits -- the GPU clock "
                    "reading is NOT trustworthy and gpu_ns stays 0\n",
                    g_ts_valid_bits);
        }
        if (getenv("HAMNIX_VK_VERBOSE"))
            fprintf(stderr, "[linux-vk] qr=%d ts0=%llu ts1=%llu\n", (int)qr,
                    (unsigned long long)ts[0], (unsigned long long)ts[1]);
        if (qr == VK_SUCCESS) {
            uint64_t mask = g_ts_valid_bits >= 64 ? ~0ull
                                                  : ((1ull << g_ts_valid_bits) - 1);
            uint64_t d = (ts[1] & mask) - (ts[0] & mask);
            d &= mask;
            g_stat_gpu_ns = (uint64_t)((double)d * (double)g_ts_period);
        }
    }
    g_stat_submits++;
    g_stat_last_us = t_end - t0;
    g_nops = 0;
    g_ause = 0;               /* staged sources are consumed by the submit */
    g_ncov = 0;               /* ...and so are the coverage masks in them */
    return g_frame_err;
}

/* Finish the frame: submit anything outstanding and close recording.
 * 0 = every op of this frame was executed on the device; -1 = something
 * failed and the caller must re-render the frame in software. */
int32_t hvk_frame_end(void)
{
    int32_t r = hvk_frame_sync();
    g_in_frame = 0;
    if (r == 0) g_stat_frames++;
    return r;
}

uint64_t hvk_stat_frames(void)      { return g_stat_frames; }
uint64_t hvk_stat_ops(void)         { return g_stat_ops; }
uint64_t hvk_stat_dispatches(void)  { return g_stat_dispatches; }
uint64_t hvk_stat_submits(void)     { return g_stat_submits; }
/* Barriers the last frame needed. dispatches - barriers is how much of the
 * frame the device was allowed to run in parallel. */
int32_t  hvk_stat_barriers(void)    { return g_barriers; }
/* Ops folded into a multi-entry OP_BATCH dispatch rather than getting a
 * dispatch of their own. This is where a page of text stops costing one
 * device round of overhead per glyph. */
uint64_t hvk_stat_batched(void)     { return g_stat_batched; }
uint64_t hvk_stat_last_us(void)     { return g_stat_last_us; }
uint64_t hvk_stat_arena_bytes(void) { return g_stat_arena_bytes; }
/* uint32s actually written into the source arena — the frame's staging cost,
 * and the one number that says whether the glyph cache is doing anything. */
uint64_t hvk_stat_staged(void)      { return g_stat_staged; }
uint64_t hvk_stat_cov_reuse(void)   { return g_stat_covreuse; }
/* The last submit split three ways. gpu_ns is the DEVICE's own clock; 0 means
 * this device has no usable timestamp, never "it was instant". */
uint64_t hvk_stat_record_us(void)   { return g_stat_record_us; }
uint64_t hvk_stat_wait_us(void)     { return g_stat_wait_us; }
uint64_t hvk_stat_gpu_ns(void)      { return g_stat_gpu_ns; }
/* 1 iff the source arena (binding 1) lives in device-local memory. */
int32_t  hvk_arena_is_device_local(void) { return g_adevlocal ? 1 : 0; }
int32_t  hvk_pending_ops(void)      { return g_nops; }
