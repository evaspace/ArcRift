// vk_layer_test.cpp - checks two things on this PC's Intel Arc Vulkan driver, without Meta involved:
//  1. Whether a semaphore can be exported as a KMT handle (what Meta's runtime asks for) or only as an NT handle.
//  2. Whether VK_KHR_external_semaphore_win32 is listed, and whether a device that enables it can still be created.
// Run it once plainly and once with ArcRift's layer enabled (VK_INSTANCE_LAYERS / VK_ADD_LAYER_PATH) to compare.
#define VK_NO_PROTOTYPES
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <vulkan/vulkan.h>
#include <cstdio>
#include <cstring>
#include <vector>

#define LOAD(name) auto name = reinterpret_cast<PFN_##name>(gipa(instance, #name))

int main() {
    HMODULE loader = LoadLibraryW(L"vulkan-1.dll");
    if (!loader) { printf("vulkan-1.dll not found\n"); return 1; }
    auto gipa = reinterpret_cast<PFN_vkGetInstanceProcAddr>(GetProcAddress(loader, "vkGetInstanceProcAddr"));
    VkInstance instance = VK_NULL_HANDLE;
    LOAD(vkCreateInstance);

    VkApplicationInfo app{VK_STRUCTURE_TYPE_APPLICATION_INFO};
    app.pApplicationName = "arcrift-vk-layer-test";
    app.apiVersion = VK_API_VERSION_1_1;
    VkInstanceCreateInfo ici{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
    ici.pApplicationInfo = &app;
    VkResult r = vkCreateInstance(&ici, nullptr, &instance);
    printf("vkCreateInstance=%d\n", r);
    if (r != VK_SUCCESS) return 1;

    LOAD(vkEnumeratePhysicalDevices);
    LOAD(vkGetPhysicalDeviceProperties);
    LOAD(vkEnumerateDeviceExtensionProperties);
    LOAD(vkGetPhysicalDeviceExternalSemaphoreProperties);
    LOAD(vkCreateDevice);
    LOAD(vkDestroyInstance);
    LOAD(vkGetDeviceProcAddr);

    uint32_t n = 0;
    vkEnumeratePhysicalDevices(instance, &n, nullptr);
    std::vector<VkPhysicalDevice> devices(n);
    vkEnumeratePhysicalDevices(instance, &n, devices.data());
    int failures = 0;
    for (VkPhysicalDevice pd : devices) {
        VkPhysicalDeviceProperties p{};
        vkGetPhysicalDeviceProperties(pd, &p);
        if (p.vendorID != 0x8086 || p.deviceType != VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU) continue;
        printf("device: %s (vendor 0x%04x device 0x%04x, driver 0x%08x)\n", p.deviceName, p.vendorID, p.deviceID, p.driverVersion);

        const VkExternalSemaphoreHandleTypeFlagBits types[] = {VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_OPAQUE_WIN32_BIT,
            VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_OPAQUE_WIN32_KMT_BIT, VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_D3D12_FENCE_BIT};
        const char* names[] = {"OPAQUE_WIN32 (NT)", "OPAQUE_WIN32_KMT (what Meta asks for)", "D3D12_FENCE"};
        for (int i = 0; i < 3; ++i) {
            VkPhysicalDeviceExternalSemaphoreInfo info{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_SEMAPHORE_INFO};
            info.handleType = types[i];
            VkExternalSemaphoreProperties props{VK_STRUCTURE_TYPE_EXTERNAL_SEMAPHORE_PROPERTIES};
            vkGetPhysicalDeviceExternalSemaphoreProperties(pd, &info, &props);
            printf("  semaphore %-38s exportable=%d importable=%d\n", names[i],
                (props.externalSemaphoreFeatures & VK_EXTERNAL_SEMAPHORE_FEATURE_EXPORTABLE_BIT) != 0,
                (props.externalSemaphoreFeatures & VK_EXTERNAL_SEMAPHORE_FEATURE_IMPORTABLE_BIT) != 0);
        }

        uint32_t count = 0;
        vkEnumerateDeviceExtensionProperties(pd, nullptr, &count, nullptr);
        std::vector<VkExtensionProperties> ext(count);
        vkEnumerateDeviceExtensionProperties(pd, nullptr, &count, ext.data());
        bool listed = false;
        for (auto& e : ext) if (!strcmp(e.extensionName, "VK_KHR_external_semaphore_win32")) listed = true;
        printf("  device extensions: %u, VK_KHR_external_semaphore_win32 listed=%d\n", count, listed);

        // Same extensions Dash enabled in the 22 Nov trace (it enables this one even when not listed).
        const char* enable[] = {"VK_KHR_swapchain", "VK_KHR_external_memory", "VK_KHR_external_memory_win32",
            "VK_KHR_external_fence", "VK_KHR_external_fence_win32", "VK_KHR_external_semaphore",
            "VK_KHR_external_semaphore_win32", "VK_KHR_get_memory_requirements2", "VK_KHR_dedicated_allocation"};
        float priority = 1.0f;
        VkDeviceQueueCreateInfo q{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
        q.queueFamilyIndex = 0;
        q.queueCount = 1;
        q.pQueuePriorities = &priority;
        VkDeviceCreateInfo dci{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
        dci.queueCreateInfoCount = 1;
        dci.pQueueCreateInfos = &q;
        dci.enabledExtensionCount = sizeof(enable) / sizeof(enable[0]);
        dci.ppEnabledExtensionNames = enable;
        VkDevice device = VK_NULL_HANDLE;
        r = vkCreateDevice(pd, &dci, nullptr, &device);
        printf("  vkCreateDevice with Dash's extensions=%d\n", r);
        if (r != VK_SUCCESS) failures++;

        // Meta's library checks the list after Dash's device exists; this is what it would see.
        count = 0;
        vkEnumerateDeviceExtensionProperties(pd, nullptr, &count, nullptr);
        ext.assign(count, VkExtensionProperties{});
        vkEnumerateDeviceExtensionProperties(pd, nullptr, &count, ext.data());
        listed = false;
        bool fenceListed = false;
        for (auto& e : ext) {
            if (!strcmp(e.extensionName, "VK_KHR_external_semaphore_win32")) listed = true;
            if (!strcmp(e.extensionName, "VK_KHR_external_fence_win32")) fenceListed = true;
        }
        printf("  after vkCreateDevice: device extensions: %u, VK_KHR_external_semaphore_win32 listed=%d, VK_KHR_external_fence_win32 listed=%d\n",
            count, listed, fenceListed);
        if (device) {
            auto destroy = reinterpret_cast<PFN_vkDestroyDevice>(vkGetDeviceProcAddr(device, "vkDestroyDevice"));
            if (destroy) destroy(device, nullptr);
        }
    }
    vkDestroyInstance(instance, nullptr);
    return failures ? 1 : 0;
}
