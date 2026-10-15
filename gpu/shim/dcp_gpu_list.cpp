// SPDX-License-Identifier: GPL-2.0-or-later
// The launcher's list of Vulkan devices the renderer can use (the Graphics card row), and the start-up check that
// Vulkan can run the renderer at all.

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <optional>
#include <string>

#include <SDL3/SDL_init.h>
#include <SDL3/SDL_messagebox.h>
#include <fmt/format.h>
#ifdef __linux__
#include <dlfcn.h>
#endif

#include "common/types.h"
#include "sdl_window.h"
#include "video_core/renderer_vulkan/vk_instance.h"
#include "video_core/renderer_vulkan/vk_platform.h"

namespace {

struct VulkanProblem {
    std::string cause; // '\n' where the error window should break the line: SDL's X11 dialog does not wrap
    std::string advice;
};

// The renderer's own requirements, asked without its assertions, which end the process with no word to the player.
std::optional<VulkanProblem> FindVulkanProblem() {
    using namespace Vulkan;
    static vk::detail::DynamicLoader loader;
    if (!loader.success()) {
        return VulkanProblem{"Vulkan is not installed on this system.",
                             "Install your graphics driver's Vulkan support and try again."};
    }
    VULKAN_HPP_DEFAULT_DISPATCHER.init(loader.getProcAddress<PFN_vkGetInstanceProcAddr>("vkGetInstanceProcAddr"));
    u32 version = VK_API_VERSION_1_0;
    if (VULKAN_HPP_DEFAULT_DISPATCHER.vkEnumerateInstanceVersion) {
        const auto [result, value] = vk::enumerateInstanceVersion();
        if (result == vk::Result::eSuccess) {
            version = value;
        }
    }
    const u32 major = VK_VERSION_MAJOR(TargetVulkanApiVersion), minor = VK_VERSION_MINOR(TargetVulkanApiVersion);
    if (version < TargetVulkanApiVersion) {
        return VulkanProblem{fmt::format("This system's Vulkan runtime supports only {}.{},\n"
                                         "but Vulkan {}.{} or newer is required.",
                                         VK_VERSION_MAJOR(version), VK_VERSION_MINOR(version), major, minor),
                             "Update your graphics driver and Vulkan runtime, and try again."};
    }
    const VulkanProblem no_driver{"No Vulkan graphics driver was found.",
                                  "Install or update your graphics driver and try again."};
    const vk::ApplicationInfo application{.apiVersion = TargetVulkanApiVersion};
    auto [result, instance] = vk::createInstanceUnique({.pApplicationInfo = &application});
    if (result == vk::Result::eErrorIncompatibleDriver) {
        return no_driver;
    }
    if (result != vk::Result::eSuccess) {
        return VulkanProblem{fmt::format("Vulkan could not be started ({}).", vk::to_string(result)),
                             "Update your graphics driver and try again."};
    }
    VULKAN_HPP_DEFAULT_DISPATCHER.init(*instance);
    const auto [devices_result, devices] = instance->enumeratePhysicalDevices();
    if (devices_result != vk::Result::eSuccess || devices.empty()) {
        return no_driver;
    }
    if (std::ranges::none_of(devices, IsDeviceUsable)) {
        return VulkanProblem{fmt::format("No graphics card here supports Vulkan {}.{} with the\n"
                                         "features the game needs.",
                                         major, minor),
                             "Update your graphics driver and try again."};
    }
    return std::nullopt;
}

// SDL 3.4's X11 message box calls libXrandr without checking that it could be loaded.
bool MessageBoxWouldCrash() {
#ifdef __linux__
    void* xrandr = dlopen("libXrandr.so.2", RTLD_LAZY | RTLD_LOCAL);
    if (!xrandr) {
        return true;
    }
    dlclose(xrandr);
#endif
    return false;
}

} // namespace

extern "C" int dcp_check_vulkan(void) {
    const auto problem = FindVulkanProblem();
    if (!problem) {
        return 1;
    }
    std::string cause = problem->cause;
    std::ranges::replace(cause, '\n', ' ');
    std::printf("Graphics: %s %s\n", cause.c_str(), problem->advice.c_str());
    if (MessageBoxWouldCrash()) {
        std::fprintf(stderr, "Graphics: no error window: libXrandr.so.2 is not installed\n");
        return 0;
    }
    const std::string text = "Dragon's Crown Pro PC could not start the graphics system.\n\n" + problem->cause +
                             "\n\n" + problem->advice;
    // SDL's X11 message box needs the video subsystem.
    if (!SDL_Init(SDL_INIT_VIDEO) ||
        !SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, "Dragon's Crown Pro PC", text.c_str(), nullptr)) {
        std::fprintf(stderr, "Graphics: could not show the error window: %s\n", SDL_GetError());
    }
    SDL_Quit();
    return 0;
}

extern "C" int dcp_gpu_names(char (*names)[256], int max) {
    using namespace Vulkan;
    int count = 0;
    {
        auto instance = CreateInstance(Frontend::WindowSystemType::Headless, false, false);
        if (!instance) {
            return 0;
        }
        const auto [result, devices] = instance->enumeratePhysicalDevices();
        if (result != vk::Result::eSuccess) {
            return 0;
        }
        for (const auto& device : devices) {
            if (count == max || !IsDeviceUsable(device)) {
                continue;
            }
            const auto properties = device.getProperties();
            const char* name = properties.deviceName.data();
            bool known = false;
            for (int i = 0; i < count; ++i) {
                known |= !std::strcmp(names[i], name);
            }
            if (!known) {
                std::snprintf(names[count++], 256, "%s", name);
            }
        }
    }
    return count;
}
