// ArcRift Vulkan layer for Meta's Dash on Intel Arc (experiment, opt-in).
//
// Meta's runtime library inside Dash (LibOVRRTImpl64_1.dll, runtime 208.0.0.84.535) builds a "SyncContext" with the
// compositor. If the Vulkan device lists VK_KHR_external_semaphore_win32, the library assumes it can export a
// semaphore as an old KMT shared handle (VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_OPAQUE_WIN32_KMT_BIT). The Intel Arc driver
// lists the extension but only supports NT handles, so the export gives an unusable handle and Dash quits with
// "Failed to configure Rendering Code: -4" (validation layer, 22 Nov: "...OPAQUE_WIN32_KMT_BIT does not support
// VK_EXTERNAL_SEMAPHORE_FEATURE_EXPORTABLE_BIT"). When the extension is not listed, the same library logs
// "[Non-fatal] VK_KHR_external_semaphore_win32 not supported, using fallback notification synchronization" and goes on.
//
// Second run (22 Nov 15:40): with that hidden, the library's fallback imports the compositor's sync object into a
// Vulkan fence (vkImportFenceWin32HandleKHR, OPAQUE_WIN32), which the Arc driver rejects with
// VK_ERROR_INVALID_EXTERNAL_HANDLE. That import is guarded the same way: if VK_KHR_external_fence_win32 is not listed,
// the library logs "[Non-fatal] VK_KHR_external_fence_win32 not supported, using fallback synchronization" instead.
//
// So this layer removes VK_KHR_external_semaphore_win32 and VK_KHR_external_fence_win32 from
// vkEnumerateDeviceExtensionProperties (override the list with ARCRIFT_VK_HIDE_EXTENSIONS, ';'-separated), and only
// after the process has created a Vulkan device. Dash enables these extensions when it creates its device, and the
// Vulkan loader refuses a device whose extensions are not listed (VK_ERROR_EXTENSION_NOT_PRESENT, checked here), so
// the list must be complete until then. Meta's library checks it later, after Dash's device exists (22 Nov trace:
// vkCreateDevice at call ~550 of ~12500, the KMT semaphore at ~11530). Every other call passes straight through.
// ArcRift's bridge enables the layer, through OVRServer's environment, for processes Meta starts.
//
// Third run (22 Nov 15:46): Dash ran for over 5 minutes (Guardian setup worked), then crashed in
// vkBindImageMemory with a NULL memory. Meta's compositor shares Dash's swapchain textures as old KMT D3D11 handles
// (VK_EXTERNAL_MEMORY_HANDLE_TYPE_D3D11_TEXTURE_KMT_BIT, dedicated allocation). On the Arc driver that import works
// for colour (RGBA8) and D32 depth, but for D24S8 depth vkAllocateMemory returns VK_SUCCESS with a NULL memory
// (reproduced without Meta by tools\vk_layer_test\kmt_import_test.cpp). So when an external-memory import returns no
// memory, this layer gives the image ordinary device-local memory instead and logs it. The compositor then does not
// see that buffer's contents; for depth that only feeds ASW/positional timewarp, which do not run on Arc anyway.
#define VK_NO_PROTOTYPES
#define VK_USE_PLATFORM_WIN32_KHR
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <vulkan/vulkan.h>
#include <vulkan/vk_layer.h>
#include <algorithm>
#include <atomic>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <unordered_map>
#include <vector>

#define LAYER_NAME "VK_LAYER_ARCRIFT_semaphore_fallback"
#include <string>

// Extensions to hide once a device exists. Read once from ARCRIFT_VK_HIDE_EXTENSIONS if set.
static const std::vector<std::string>& Hidden() {
    static const std::vector<std::string> list = [] {
        std::vector<std::string> out;
        char value[1024]{};
        DWORD n = GetEnvironmentVariableA("ARCRIFT_VK_HIDE_EXTENSIONS", value, sizeof(value));
        std::string text = (n > 0 && n < sizeof(value)) ? value : "VK_KHR_external_semaphore_win32;VK_KHR_external_fence_win32";
        size_t start = 0;
        while (start <= text.size()) {
            size_t end = text.find(';', start);
            if (end == std::string::npos) end = text.size();
            if (end > start) out.push_back(text.substr(start, end - start));
            start = end + 1;
        }
        return out;
    }();
    return list;
}
static bool IsHidden(const char* name) {
    for (const auto& h : Hidden()) if (h == name) return true;
    return false;
}
static std::string HiddenText() {
    std::string text;
    for (const auto& h : Hidden()) { if (!text.empty()) text += ", "; text += h; }
    return text;
}

static HMODULE self;
static std::mutex lock;
static std::atomic<int> activeDevices{0}; // hide extensions only while at least one device exists

struct InstanceData {
    VkInstance instance = VK_NULL_HANDLE;
    PFN_vkGetInstanceProcAddr next = nullptr;
    PFN_vkDestroyInstance destroy = nullptr;
    PFN_vkEnumerateDeviceExtensionProperties enumerateDeviceExtensions = nullptr;
};
struct DeviceData {
    PFN_vkGetDeviceProcAddr next = nullptr;
    VkPhysicalDevice physicalDevice = VK_NULL_HANDLE;
    PFN_vkDestroyDevice destroyDevice = nullptr;
    PFN_vkCreateImage createImage = nullptr;
    PFN_vkDestroyImage destroyImage = nullptr;
    PFN_vkAllocateMemory allocateMemory = nullptr;
    PFN_vkGetImageMemoryRequirements imageRequirements = nullptr;
    PFN_vkGetPhysicalDeviceMemoryProperties memoryProperties = nullptr;
};
struct ImageInfo { void* deviceKey; VkFormat format; uint32_t width, height; VkExternalMemoryHandleTypeFlags handleTypes; };
static std::unordered_map<void*, InstanceData> instances;               // key: loader dispatch pointer
static std::unordered_map<void*, DeviceData> devices;                   // key: loader dispatch pointer
static std::unordered_map<uint64_t, ImageInfo> externalImages;          // images created for external memory

// Instances and their physical devices share the loader's dispatch pointer, the first pointer-sized field.
static void* Key(const void* handle) { return *reinterpret_cast<void* const*>(handle); }

static void Log(const char* format, ...) {
    wchar_t path[MAX_PATH]{};
    GetModuleFileNameW(self, path, MAX_PATH);
    wchar_t* last = wcsrchr(path, L'\\');
    if (!last) return;
    wcscpy_s(last + 1, MAX_PATH - (last + 1 - path), L"arcrift-vk-layer.log");
    FILE* file = nullptr;
    if (_wfopen_s(&file, path, L"a") != 0 || !file) return;
    wchar_t exe[MAX_PATH]{};
    GetModuleFileNameW(nullptr, exe, MAX_PATH);
    const wchar_t* exeName = wcsrchr(exe, L'\\');
    SYSTEMTIME t{};
    GetLocalTime(&t);
    fprintf(file, "%02u:%02u:%02u.%03u %ls[%lu] ", t.wHour, t.wMinute, t.wSecond, t.wMilliseconds,
        exeName ? exeName + 1 : exe, GetCurrentProcessId());
    va_list args;
    va_start(args, format);
    vfprintf(file, format, args);
    va_end(args);
    fputc('\n', file);
    fclose(file);
}

static InstanceData FindInstance(const void* handle) {
    std::lock_guard<std::mutex> guard(lock);
    auto it = instances.find(Key(handle));
    return it == instances.end() ? InstanceData{} : it->second;
}

static VKAPI_ATTR VkResult VKAPI_CALL CreateInstance(const VkInstanceCreateInfo* info, const VkAllocationCallbacks* allocator, VkInstance* out) {
    auto chain = static_cast<VkLayerInstanceCreateInfo*>(const_cast<void*>(info->pNext));
    while (chain && !(chain->sType == VK_STRUCTURE_TYPE_LOADER_INSTANCE_CREATE_INFO && chain->function == VK_LAYER_LINK_INFO))
        chain = static_cast<VkLayerInstanceCreateInfo*>(const_cast<void*>(chain->pNext));
    if (!chain || !chain->u.pLayerInfo) return VK_ERROR_INITIALIZATION_FAILED;
    PFN_vkGetInstanceProcAddr next = chain->u.pLayerInfo->pfnNextGetInstanceProcAddr;
    chain->u.pLayerInfo = chain->u.pLayerInfo->pNext;
    auto create = reinterpret_cast<PFN_vkCreateInstance>(next(VK_NULL_HANDLE, "vkCreateInstance"));
    if (!create) return VK_ERROR_INITIALIZATION_FAILED;
    VkResult result = create(info, allocator, out);
    if (result != VK_SUCCESS) return result;
    InstanceData data;
    data.instance = *out;
    data.next = next;
    data.destroy = reinterpret_cast<PFN_vkDestroyInstance>(next(*out, "vkDestroyInstance"));
    data.enumerateDeviceExtensions = reinterpret_cast<PFN_vkEnumerateDeviceExtensionProperties>(next(*out, "vkEnumerateDeviceExtensionProperties"));
    {
        std::lock_guard<std::mutex> guard(lock);
        instances[Key(*out)] = data;
    }
    Log("instance created: %s will be hidden from device extension lists once a device exists", HiddenText().c_str());
    return VK_SUCCESS;
}

static VKAPI_ATTR void VKAPI_CALL DestroyInstance(VkInstance instance, const VkAllocationCallbacks* allocator) {
    if (!instance) return;
    InstanceData data = FindInstance(instance);
    {
        std::lock_guard<std::mutex> guard(lock);
        instances.erase(Key(instance));
    }
    if (data.destroy) data.destroy(instance, allocator);
}

static VKAPI_ATTR VkResult VKAPI_CALL EnumerateDeviceExtensionProperties(VkPhysicalDevice device, const char* layerName,
    uint32_t* count, VkExtensionProperties* properties) {
    if (layerName && strcmp(layerName, LAYER_NAME) == 0) { *count = 0; return VK_SUCCESS; }
    InstanceData data = FindInstance(device);
    if (!data.enumerateDeviceExtensions) return VK_ERROR_INITIALIZATION_FAILED;
    if (layerName || activeDevices.load() <= 0) return data.enumerateDeviceExtensions(device, layerName, count, properties);

    uint32_t total = 0;
    VkResult result = data.enumerateDeviceExtensions(device, nullptr, &total, nullptr);
    if (result != VK_SUCCESS) return result;
    std::vector<VkExtensionProperties> all(total);
    result = data.enumerateDeviceExtensions(device, nullptr, &total, all.data());
    if (result < 0) return result;
    all.resize(total);
    size_t before = all.size();
    all.erase(std::remove_if(all.begin(), all.end(),
        [](const VkExtensionProperties& e) { return IsHidden(e.extensionName); }), all.end());
    static std::atomic<int> logged{0};
    if (all.size() != before && logged.fetch_add(1) < 4)
        Log("hid %s from a device extension list (%zu -> %zu)", HiddenText().c_str(), before, all.size());

    if (!properties) { *count = static_cast<uint32_t>(all.size()); return VK_SUCCESS; }
    uint32_t copied = (std::min)(*count, static_cast<uint32_t>(all.size()));
    memcpy(properties, all.data(), copied * sizeof(VkExtensionProperties));
    *count = copied;
    return copied < all.size() ? VK_INCOMPLETE : VK_SUCCESS;
}

static DeviceData FindDevice(const void* handle) {
    std::lock_guard<std::mutex> guard(lock);
    auto it = devices.find(Key(handle));
    return it == devices.end() ? DeviceData{} : it->second;
}

// Walks a const pNext chain for a structure of the given type.
template <typename T>
static const T* FindInChain(const void* next, VkStructureType type) {
    for (auto s = static_cast<const VkBaseInStructure*>(next); s; s = s->pNext)
        if (s->sType == type) return reinterpret_cast<const T*>(s);
    return nullptr;
}

static VKAPI_ATTR VkResult VKAPI_CALL CreateImage(VkDevice device, const VkImageCreateInfo* info, const VkAllocationCallbacks* allocator, VkImage* out) {
    DeviceData data = FindDevice(device);
    if (!data.createImage) return VK_ERROR_INITIALIZATION_FAILED;
    VkResult result = data.createImage(device, info, allocator, out);
    if (result == VK_SUCCESS) {
        auto external = FindInChain<VkExternalMemoryImageCreateInfo>(info->pNext, VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO);
        if (external && external->handleTypes) {
            std::lock_guard<std::mutex> guard(lock);
            externalImages[reinterpret_cast<uint64_t>(*out)] = {Key(device), info->format, info->extent.width, info->extent.height, external->handleTypes};
        }
    }
    return result;
}

static VKAPI_ATTR void VKAPI_CALL DestroyImage(VkDevice device, VkImage image, const VkAllocationCallbacks* allocator) {
    if (image) {
        std::lock_guard<std::mutex> guard(lock);
        externalImages.erase(reinterpret_cast<uint64_t>(image));
    }
    DeviceData data = FindDevice(device);
    if (data.destroyImage) data.destroyImage(device, image, allocator);
}

static VKAPI_ATTR VkResult VKAPI_CALL AllocateMemory(VkDevice device, const VkMemoryAllocateInfo* info, const VkAllocationCallbacks* allocator, VkDeviceMemory* out) {
    DeviceData data = FindDevice(device);
    if (!data.allocateMemory) return VK_ERROR_INITIALIZATION_FAILED;
    *out = VK_NULL_HANDLE;
    VkResult result = data.allocateMemory(device, info, allocator, out);
    auto import = FindInChain<VkImportMemoryWin32HandleInfoKHR>(info->pNext, VK_STRUCTURE_TYPE_IMPORT_MEMORY_WIN32_HANDLE_INFO_KHR);
    if (!import || (result == VK_SUCCESS && *out != VK_NULL_HANDLE)) return result;

    // The import gave no memory. Retry as a plain dedicated allocation so the image gets valid memory.
    auto dedicated = FindInChain<VkMemoryDedicatedAllocateInfo>(info->pNext, VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO);
    ImageInfo image{};
    bool known = false;
    if (dedicated && dedicated->image) {
        std::lock_guard<std::mutex> guard(lock);
        auto it = externalImages.find(reinterpret_cast<uint64_t>(dedicated->image));
        if (it != externalImages.end()) { image = it->second; known = true; }
    }
    VkMemoryDedicatedAllocateInfo plainDedicated{VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO};
    VkMemoryAllocateInfo plain{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
    plain.allocationSize = info->allocationSize;
    plain.memoryTypeIndex = info->memoryTypeIndex;
    if (dedicated) {
        plainDedicated.image = dedicated->image;
        plainDedicated.buffer = dedicated->buffer;
        plain.pNext = &plainDedicated;
    }
    if (dedicated && dedicated->image && data.imageRequirements) {
        VkMemoryRequirements req{};
        data.imageRequirements(device, dedicated->image, &req);
        if (req.size > plain.allocationSize) plain.allocationSize = req.size;
        const bool currentValid = plain.memoryTypeIndex < 32 && (req.memoryTypeBits & (1u << plain.memoryTypeIndex)) != 0;
        if (!currentValid && data.memoryProperties) {
            VkPhysicalDeviceMemoryProperties props{};
            data.memoryProperties(data.physicalDevice, &props);
            bool picked = false;
            for (uint32_t i = 0; i < props.memoryTypeCount && i < 32; ++i) {
                if ((req.memoryTypeBits & (1u << i)) && (props.memoryTypes[i].propertyFlags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)) {
                    plain.memoryTypeIndex = i;
                    picked = true;
                    break;
                }
            }
            if (!picked) {
                for (uint32_t i = 0; i < props.memoryTypeCount && i < 32; ++i) {
                    if (req.memoryTypeBits & (1u << i)) { plain.memoryTypeIndex = i; break; }
                }
            }
        }
    }
    *out = VK_NULL_HANDLE;
    VkResult retry = data.allocateMemory(device, &plain, allocator, out);
    Log("import of %s %ux%u (format %d, handle type 0x%x) returned %d with %s memory; gave it local memory instead: %d (%s). "
        "Meta's compositor will not see this buffer's contents.",
        known ? "image" : "memory", image.width, image.height, image.format, import->handleType, result,
        result == VK_SUCCESS ? "NULL" : "no", retry, *out ? "ok" : "failed");
    return retry == VK_SUCCESS && *out ? VK_SUCCESS : result;
}

static VKAPI_ATTR VkResult VKAPI_CALL CreateDevice(VkPhysicalDevice physicalDevice, const VkDeviceCreateInfo* info,
    const VkAllocationCallbacks* allocator, VkDevice* out) {
    auto chain = static_cast<VkLayerDeviceCreateInfo*>(const_cast<void*>(info->pNext));
    while (chain && !(chain->sType == VK_STRUCTURE_TYPE_LOADER_DEVICE_CREATE_INFO && chain->function == VK_LAYER_LINK_INFO))
        chain = static_cast<VkLayerDeviceCreateInfo*>(const_cast<void*>(chain->pNext));
    if (!chain || !chain->u.pLayerInfo) return VK_ERROR_INITIALIZATION_FAILED;
    PFN_vkGetInstanceProcAddr nextInstance = chain->u.pLayerInfo->pfnNextGetInstanceProcAddr;
    PFN_vkGetDeviceProcAddr nextDevice = chain->u.pLayerInfo->pfnNextGetDeviceProcAddr;
    chain->u.pLayerInfo = chain->u.pLayerInfo->pNext;
    InstanceData data = FindInstance(physicalDevice);
    auto create = reinterpret_cast<PFN_vkCreateDevice>(nextInstance(data.instance, "vkCreateDevice"));
    if (!create) return VK_ERROR_INITIALIZATION_FAILED;
    VkResult result = create(physicalDevice, info, allocator, out);
    if (result != VK_SUCCESS) { Log("vkCreateDevice failed %d", result); return result; }
    DeviceData device;
    device.next = nextDevice;
    device.physicalDevice = physicalDevice;
    device.destroyDevice = reinterpret_cast<PFN_vkDestroyDevice>(nextDevice(*out, "vkDestroyDevice"));
    device.createImage = reinterpret_cast<PFN_vkCreateImage>(nextDevice(*out, "vkCreateImage"));
    device.destroyImage = reinterpret_cast<PFN_vkDestroyImage>(nextDevice(*out, "vkDestroyImage"));
    device.allocateMemory = reinterpret_cast<PFN_vkAllocateMemory>(nextDevice(*out, "vkAllocateMemory"));
    device.imageRequirements = reinterpret_cast<PFN_vkGetImageMemoryRequirements>(nextDevice(*out, "vkGetImageMemoryRequirements"));
    device.memoryProperties = reinterpret_cast<PFN_vkGetPhysicalDeviceMemoryProperties>(nextInstance(data.instance, "vkGetPhysicalDeviceMemoryProperties"));
    {
        std::lock_guard<std::mutex> guard(lock);
        devices[Key(*out)] = device;
    }
    if (activeDevices.fetch_add(1) == 0) Log("device created; from now on %s are hidden from device extension lists", HiddenText().c_str());
    return VK_SUCCESS;
}

static VKAPI_ATTR void VKAPI_CALL DestroyDevice(VkDevice device, const VkAllocationCallbacks* allocator) {
    if (!device) return;
    DeviceData data;
    void* devKey = Key(device);
    {
        std::lock_guard<std::mutex> guard(lock);
        auto it = devices.find(devKey);
        if (it != devices.end()) { data = it->second; devices.erase(it); }
        for (auto img = externalImages.begin(); img != externalImages.end(); ) {
            if (img->second.deviceKey == devKey) img = externalImages.erase(img);
            else ++img;
        }
    }
    int remaining = activeDevices.fetch_sub(1) - 1;
    if (remaining < 0) activeDevices.store(0);
    if (data.destroyDevice) data.destroyDevice(device, allocator);
}

static VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL GetDeviceProcAddr(VkDevice device, const char* name);

static VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL GetInstanceProcAddr(VkInstance instance, const char* name) {
    if (!name) return nullptr;
    if (!strcmp(name, "vkGetInstanceProcAddr")) return reinterpret_cast<PFN_vkVoidFunction>(GetInstanceProcAddr);
    if (!strcmp(name, "vkGetDeviceProcAddr")) return reinterpret_cast<PFN_vkVoidFunction>(GetDeviceProcAddr);
    if (!strcmp(name, "vkCreateInstance")) return reinterpret_cast<PFN_vkVoidFunction>(CreateInstance);
    if (!strcmp(name, "vkDestroyInstance")) return reinterpret_cast<PFN_vkVoidFunction>(DestroyInstance);
    if (!strcmp(name, "vkCreateDevice")) return reinterpret_cast<PFN_vkVoidFunction>(CreateDevice);
    if (!strcmp(name, "vkDestroyDevice")) return reinterpret_cast<PFN_vkVoidFunction>(DestroyDevice);
    if (!strcmp(name, "vkEnumerateDeviceExtensionProperties")) return reinterpret_cast<PFN_vkVoidFunction>(EnumerateDeviceExtensionProperties);
    if (!strcmp(name, "vkCreateImage")) return reinterpret_cast<PFN_vkVoidFunction>(CreateImage);
    if (!strcmp(name, "vkDestroyImage")) return reinterpret_cast<PFN_vkVoidFunction>(DestroyImage);
    if (!strcmp(name, "vkAllocateMemory")) return reinterpret_cast<PFN_vkVoidFunction>(AllocateMemory);
    if (!instance) return nullptr;
    InstanceData data = FindInstance(instance);
    return data.next ? data.next(instance, name) : nullptr;
}

static VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL GetDeviceProcAddr(VkDevice device, const char* name) {
    if (!device || !name) return nullptr;
    if (!strcmp(name, "vkGetDeviceProcAddr")) return reinterpret_cast<PFN_vkVoidFunction>(GetDeviceProcAddr);
    if (!strcmp(name, "vkDestroyDevice")) return reinterpret_cast<PFN_vkVoidFunction>(DestroyDevice);
    if (!strcmp(name, "vkCreateImage")) return reinterpret_cast<PFN_vkVoidFunction>(CreateImage);
    if (!strcmp(name, "vkDestroyImage")) return reinterpret_cast<PFN_vkVoidFunction>(DestroyImage);
    if (!strcmp(name, "vkAllocateMemory")) return reinterpret_cast<PFN_vkVoidFunction>(AllocateMemory);
    DeviceData data = FindDevice(device);
    return data.next ? data.next(device, name) : nullptr;
}

// vk_layer.h already declares this function (without dllexport), so export it through the linker instead.
#pragma comment(linker, "/EXPORT:vkNegotiateLoaderLayerInterfaceVersion")
extern "C" VKAPI_ATTR VkResult VKAPI_CALL vkNegotiateLoaderLayerInterfaceVersion(VkNegotiateLayerInterface* negotiate) {
    if (!negotiate || negotiate->sType != LAYER_NEGOTIATE_INTERFACE_STRUCT) return VK_ERROR_INITIALIZATION_FAILED;
    if (negotiate->loaderLayerInterfaceVersion < 2) return VK_ERROR_INITIALIZATION_FAILED;
    negotiate->loaderLayerInterfaceVersion = 2;
    negotiate->pfnGetInstanceProcAddr = GetInstanceProcAddr;
    negotiate->pfnGetDeviceProcAddr = GetDeviceProcAddr;
    negotiate->pfnGetPhysicalDeviceProcAddr = nullptr;
    return VK_SUCCESS;
}

BOOL WINAPI DllMain(HINSTANCE module, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) { self = module; DisableThreadLibraryCalls(module); }
    return TRUE;
}
