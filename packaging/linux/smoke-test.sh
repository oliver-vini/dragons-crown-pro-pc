#!/usr/bin/env bash
# Starts the AppImage's launcher on a virtual display with no game files and checks that it stays open (a missing
# glibc version or library stops it at startup), and that its data lands next to the AppImage, never inside it.
# Run as root in a fresh container of the distribution to check: it installs Xvfb, a font and a software Vulkan
# driver, as a desktop has them (.github/workflows/linux-appimage.yml). Elsewhere it needs Xvfb already.
# Usage: smoke-test.sh path/to/DragonsCrownProPC-*.AppImage
set -euo pipefail
appimage=$(readlink -f -- "$1")
if [[ $(id -u) == 0 ]]; then
    if command -v apt-get >/dev/null; then
        apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq xvfb fonts-dejavu-core libvulkan1 mesa-vulkan-drivers >/dev/null
    elif command -v dnf >/dev/null; then
        dnf install -y -q xorg-x11-server-Xvfb dejavu-sans-fonts vulkan-loader mesa-vulkan-drivers >/dev/null
    elif command -v zypper >/dev/null; then
        zypper -nq install xorg-x11-server-Xvfb dejavu-fonts libvulkan1 Mesa-libVulkan-devel >/dev/null
    elif command -v pacman >/dev/null; then
        pacman -Sy --noconfirm --needed xorg-server-xvfb ttf-dejavu vulkan-icd-loader vulkan-swrast >/dev/null
    fi
fi
grep -m1 PRETTY_NAME /etc/os-release || true
ldd --version | sed -n 1p # head would end ldd with SIGPIPE (pipefail)

work=$(mktemp -d)
trap 'kill "${xvfb:-0}" 2>/dev/null || true; rm -rf "$work"' EXIT
mkdir "$work/home" "$work/beside"
cp "$appimage" "$work/beside/game.AppImage"
cd "$work"
"$work/beside/game.AppImage" --appimage-extract >/dev/null
Xvfb :99 -screen 0 1280x800x24 >/dev/null 2>&1 &
xvfb=$!
export DISPLAY=:99 HOME=$work/home
sleep 2

# As the AppImage runtime starts it: APPIMAGE names the file, the data belongs beside it.
find squashfs-root | sort > before.txt
status=0
APPIMAGE="$work/beside/game.AppImage" timeout 15 squashfs-root/AppRun > launcher.log 2>&1 || status=$?
cat launcher.log
if [[ $status != 124 ]] || grep -qE 'GLIBC_|GLIBCXX|error while loading|cannot open shared object' launcher.log; then
    echo "FAIL: the launcher exited ($status) instead of staying open" >&2
    exit 1
fi
grep -q 'Launcher: shown' launcher.log || { echo 'FAIL: the launcher did not open its window' >&2; exit 1; }
[[ -d $work/beside/logs ]] || { echo 'FAIL: no logs folder beside the AppImage' >&2; exit 1; }
if ! diff <(find squashfs-root | sort) before.txt >/dev/null; then
    echo 'FAIL: data was written inside the AppImage contents' >&2
    exit 1
fi
echo "OK: the launcher stayed open and kept its data beside the AppImage"
