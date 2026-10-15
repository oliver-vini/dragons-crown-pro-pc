#!/usr/bin/env bash
# Build dependencies of the Linux AppImage on Ubuntu 24.04 (.github/workflows/linux-appimage.yml).
# Its glibc (2.39) is a safe baseline: the payload imports glibc 2.38 symbols at most (tools/package-linux.sh
# checks it). What 24.04 lacks or ships too old is built into /usr/local: Vulkan-Headers, VMA and SDL3.
set -euo pipefail
sudo=$([[ $(id -u) == 0 ]] || echo sudo)
export DEBIAN_FRONTEND=noninteractive
$sudo apt-get update
$sudo apt-get install -y --no-install-recommends \
    build-essential g++-14 clang-20 lld-20 cmake ninja-build pkg-config git curl ca-certificates file patchelf binutils rsync \
    desktop-file-utils libvulkan-dev glslang-tools libboost-dev libfmt-dev libxxhash-dev libzydis-dev robin-map-dev \
    libfreetype-dev libpng-dev zlib1g-dev libssl-dev \
    libx11-dev libxext-dev libxrandr-dev libxcursor-dev libxi-dev libxss-dev libxtst-dev libxfixes-dev \
    libxinerama-dev libxkbcommon-dev libwayland-dev wayland-protocols libdecor-0-dev libdrm-dev libgbm-dev \
    libegl-dev libasound2-dev libpulse-dev libpipewire-0.3-dev libudev-dev libdbus-1-dev libibus-1.0-dev
$sudo update-alternatives --install /usr/bin/clang clang /usr/bin/clang-20 200 --slave /usr/bin/clang++ clang++ /usr/bin/clang++-20
$sudo update-alternatives --install /usr/bin/ld.lld ld.lld /usr/bin/ld.lld-20 200

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
VULKAN_HEADERS=${VULKAN_HEADERS:-vulkan-sdk-1.4.350.1}
git clone -q --depth 1 -b "$VULKAN_HEADERS" https://github.com/KhronosGroup/Vulkan-Headers "$work/vulkan-headers"
cmake -S "$work/vulkan-headers" -B "$work/vulkan-headers/build" -G Ninja -DCMAKE_INSTALL_PREFIX=/usr/local >/dev/null
$sudo cmake --install "$work/vulkan-headers/build" >/dev/null
VMA=${VMA:-v3.4.0}
$sudo mkdir -p /usr/local/include
$sudo curl -fsSL -o /usr/local/include/vk_mem_alloc.h \
    "https://raw.githubusercontent.com/GPUOpen-LibrariesAndSDKs/VulkanMemoryAllocator/$VMA/include/vk_mem_alloc.h"
SDL=${SDL:-3.4.16}
curl -fsSL "https://github.com/libsdl-org/SDL/releases/download/release-$SDL/SDL3-$SDL.tar.gz" | tar xz -C "$work"
cmake -S "$work/SDL3-$SDL" -B "$work/sdl" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF >/dev/null
ninja -C "$work/sdl" >/dev/null
$sudo ninja -C "$work/sdl" install >/dev/null
$sudo ldconfig
