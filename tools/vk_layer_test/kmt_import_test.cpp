// kmt_import_test.cpp - reproduces, without Meta, how Meta's runtime hands Dash its swapchain textures: a D3D11
// texture shared the old way (KMT handle, D3D11_RESOURCE_MISC_SHARED) imported into Vulkan with
// VK_EXTERNAL_MEMORY_HANDLE_TYPE_D3D11_TEXTURE_KMT_BIT and a dedicated allocation. Tries the formats Dash used
// (RGBA8 sRGB colour, D32 and D24S8 depth) at Dash's size and prints whether vkAllocateMemory returned real memory and
// whether vkBindImageMemory works. Run with and without ArcRift's layer.
#define VK_NO_PROTOTYPES
#define VK_USE_PLATFORM_WIN32_KHR
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <wrl/client.h>
#include <vulkan/vulkan.h>
#include <cstdio>
#include <cstring>
#include <vector>
#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
using Microsoft::WRL::ComPtr;

#define LOADI(name) auto name = reinterpret_cast<PFN_##name>(gipa(instance, #name))
#define LOADD(name) auto name = reinterpret_cast<PFN_##name>(gdpa(device, #name))

struct Case { const char* label; DXGI_FORMAT dxgi; UINT bind; VkFormat vk; VkImageUsageFlags usage; };

int main() {
    HMODULE loader = LoadLibraryW(L"vulkan-1.dll");
    if (!loader) { printf("vulkan-1.dll not found\n"); return 1; }
    auto gipa = reinterpret_cast<PFN_vkGetInstanceProcAddr>(GetProcAddress(loader, "vkGetInstanceProcAddr"));
    VkInstance instance = VK_NULL_HANDLE;
    LOADI(vkCreateInstance);
    VkApplicationInfo app{VK_STRUCTURE_TYPE_APPLICATION_INFO};
    app.apiVersion = VK_API_VERSION_1_1;
    VkInstanceCreateInfo ici{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
    ici.pApplicationInfo = &app;
    if (vkCreateInstance(&ici, nullptr, &instance) != VK_SUCCESS) { printf("vkCreateInstance failed\n"); return 1; }
    LOADI(vkEnumeratePhysicalDevices);
    LOADI(vkGetPhysicalDeviceProperties2);
    LOADI(vkCreateDevice);
    LOADI(vkGetDeviceProcAddr);
    LOADI(vkDestroyInstance);

    uint32_t n = 0;
    vkEnumeratePhysicalDevices(instance, &n, nullptr);
    std::vector<VkPhysicalDevice> pds(n);
    vkEnumeratePhysicalDevices(instance, &n, pds.data());
    VkPhysicalDevice pd = VK_NULL_HANDLE;
    LUID luid{};
    for (auto p : pds) {
        VkPhysicalDeviceIDProperties id{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ID_PROPERTIES};
        VkPhysicalDeviceProperties2 props{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2};
        props.pNext = &id;
        vkGetPhysicalDeviceProperties2(p, &props);
        if (props.properties.vendorID == 0x8086 && props.properties.deviceType == VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU && id.deviceLUIDValid) {
            pd = p;
            memcpy(&luid, id.deviceLUID, sizeof(luid));
            printf("vulkan device: %s\n", props.properties.deviceName);
        }
    }
    if (!pd) { printf("no Intel discrete GPU\n"); return 1; }

    // D3D11 device on the same adapter, like Meta's compositor.
    ComPtr<IDXGIFactory1> factory;
    CreateDXGIFactory1(IID_PPV_ARGS(&factory));
    ComPtr<IDXGIAdapter1> adapter;
    for (UINT i = 0; factory->EnumAdapters1(i, &adapter) != DXGI_ERROR_NOT_FOUND; ++i) {
        DXGI_ADAPTER_DESC1 d{};
        adapter->GetDesc1(&d);
        if (memcmp(&d.AdapterLuid, &luid, sizeof(luid)) == 0) break;
        adapter.Reset();
    }
    if (!adapter) { printf("no D3D11 adapter with the Vulkan device's LUID\n"); return 1; }
    ComPtr<ID3D11Device> d3d;
    if (FAILED(D3D11CreateDevice(adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr, 0, nullptr, 0, D3D11_SDK_VERSION, &d3d, nullptr, nullptr))) {
        printf("D3D11CreateDevice failed\n");
        return 1;
    }

    // Device with Dash's extensions.
    const char* ext[] = {"VK_KHR_external_memory", "VK_KHR_external_memory_win32", "VK_KHR_dedicated_allocation", "VK_KHR_get_memory_requirements2"};
    float prio = 1.0f;
    VkDeviceQueueCreateInfo q{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
    q.queueCount = 1;
    q.pQueuePriorities = &prio;
    VkDeviceCreateInfo dci{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
    dci.queueCreateInfoCount = 1;
    dci.pQueueCreateInfos = &q;
    dci.enabledExtensionCount = 4;
    dci.ppEnabledExtensionNames = ext;
    VkDevice device = VK_NULL_HANDLE;
    if (vkCreateDevice(pd, &dci, nullptr, &device) != VK_SUCCESS) { printf("vkCreateDevice failed\n"); return 1; }
    auto gdpa = vkGetDeviceProcAddr;
    LOADD(vkCreateImage);
    LOADD(vkGetImageMemoryRequirements);
    LOADD(vkAllocateMemory);
    LOADD(vkBindImageMemory);
    LOADD(vkFreeMemory);
    LOADD(vkDestroyImage);
    LOADD(vkDestroyDevice);

    const Case cases[] = {
        {"RGBA8 sRGB colour", DXGI_FORMAT_R8G8B8A8_UNORM_SRGB, D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE, VK_FORMAT_R8G8B8A8_SRGB,
            VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT},
        {"D32 float depth", DXGI_FORMAT_R32_TYPELESS, D3D11_BIND_DEPTH_STENCIL | D3D11_BIND_SHADER_RESOURCE, VK_FORMAT_D32_SFLOAT,
            VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT},
        {"D24S8 depth", DXGI_FORMAT_R24G8_TYPELESS, D3D11_BIND_DEPTH_STENCIL | D3D11_BIND_SHADER_RESOURCE, VK_FORMAT_D24_UNORM_S8_UINT,
            VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT},
    };
    int crashes = 0;
    for (const Case& c : cases) {
        D3D11_TEXTURE2D_DESC td{};
        td.Width = 3296;
        td.Height = 1776;
        td.MipLevels = td.ArraySize = 1;
        td.Format = c.dxgi;
        td.SampleDesc.Count = 1;
        td.BindFlags = c.bind;
        td.MiscFlags = D3D11_RESOURCE_MISC_SHARED;
        ComPtr<ID3D11Texture2D> tex;
        HRESULT hr = d3d->CreateTexture2D(&td, nullptr, &tex);
        HANDLE kmt = nullptr;
        ComPtr<IDXGIResource> res;
        if (SUCCEEDED(hr)) hr = tex.As(&res);
        if (SUCCEEDED(hr)) hr = res->GetSharedHandle(&kmt);
        if (FAILED(hr)) { printf("%-18s D3D11 texture/KMT handle failed %08lx\n", c.label, hr); continue; }

        VkExternalMemoryImageCreateInfo external{VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO};
        external.handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_D3D11_TEXTURE_KMT_BIT;
        VkImageCreateInfo ic{VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO};
        ic.pNext = &external;
        ic.imageType = VK_IMAGE_TYPE_2D;
        ic.format = c.vk;
        ic.extent = {3296, 1776, 1};
        ic.mipLevels = ic.arrayLayers = 1;
        ic.samples = VK_SAMPLE_COUNT_1_BIT;
        ic.tiling = VK_IMAGE_TILING_OPTIMAL;
        ic.usage = c.usage;
        VkImage image = VK_NULL_HANDLE;
        VkResult r = vkCreateImage(device, &ic, nullptr, &image);
        VkMemoryRequirements req{};
        vkGetImageMemoryRequirements(device, image, &req);
        VkMemoryDedicatedAllocateInfo ded{VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO};
        ded.image = image;
        VkImportMemoryWin32HandleInfoKHR imp{VK_STRUCTURE_TYPE_IMPORT_MEMORY_WIN32_HANDLE_INFO_KHR};
        imp.pNext = &ded;
        imp.handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_D3D11_TEXTURE_KMT_BIT;
        imp.handle = kmt;
        VkMemoryAllocateInfo mai{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
        mai.pNext = &imp;
        mai.allocationSize = req.size;
        mai.memoryTypeIndex = 0; // what Dash used
        VkDeviceMemory memory = VK_NULL_HANDLE;
        r = vkAllocateMemory(device, &mai, nullptr, &memory);
        printf("%-18s vkAllocateMemory=%d memory=%s", c.label, r, memory ? "real" : "NULL");
        if (memory) {
            r = vkBindImageMemory(device, image, memory, 0);
            printf(" bind=%d\n", r);
            vkFreeMemory(device, memory, nullptr);
        } else {
            printf(" (binding this would crash, as in Dash)\n");
            crashes++;
        }
        vkDestroyImage(device, image, nullptr);
    }
    vkDestroyDevice(device, nullptr);
    vkDestroyInstance(instance, nullptr);
    return crashes ? 1 : 0;
}
