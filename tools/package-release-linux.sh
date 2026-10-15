#!/usr/bin/env bash
# Builds the Linux AppImage for a checkout that lives on a Windows drive and copies the result into its dist/ folder.
# tools/package-release.ps1 starts this through wsl.exe. Local only: nothing is published, tagged or uploaded.
#
#   tools/package-release-linux.sh [--clean] [--skip-build]
#
# A Windows drive is slow to build on and has no Unix file modes, so the sources are mirrored (only what changed) into
# ${DCP_WSL_BUILD_DIR:-~/.cache/dragons-crown-pro-pc-build}, where tools/package-linux.sh builds and packages them.
# Needs the build environment of packaging/linux/ci-deps.sh and rsync; nothing is installed here.
set -euo pipefail
source=$(cd -- "$(dirname -- "$0")/.." && pwd)
clean=0 skip_build=0
while (($#)); do
    case $1 in
        --clean) clean=1 ;;
        --skip-build) skip_build=1 ;;
        -h|--help) sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

step() { printf '\n==> %s\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || die 'This needs Linux x86_64 (WSL2 on a 64-bit PC).'
command -v rsync >/dev/null || die 'rsync is missing. Install it (sudo apt-get install rsync) or run packaging/linux/ci-deps.sh.'

mirror=${DCP_WSL_BUILD_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/dragons-crown-pro-pc-build}
mkdir -p "$mirror"
mirror=$(cd -- "$mirror" && pwd)
[[ $mirror != "$source" && $mirror != "$source"/* ]] || die "The build folder $mirror is inside the checkout."

step "Mirroring the sources into $mirror"
# Content, not timestamps, decides what is copied: a restored older file must still rebuild.
rsync -rl --checksum --no-times --delete --chmod=D755,F644 \
    --exclude '/.git' --exclude '/game' --exclude '/user' --exclude '/cache' --exclude '/logs' --exclude '/build' \
    --exclude '/dist' --exclude '/out' --exclude '/.venv' "$source/" "$mirror/"
chmod +x "$mirror"/tools/*.sh "$mirror"/packaging/linux/*.sh "$mirror"/packaging/linux/AppRun

cd "$mirror"
((clean)) && rm -rf build/cmake/linux
rm -rf dist
args=()
((skip_build)) && args+=(--skip-build)
bash tools/package-linux.sh "${args[@]}"

step "Copying the AppImage into $source/dist"
mkdir -p "$source/dist"
shopt -s nullglob
images=(dist/DragonsCrownProPC-v*-linux-x86_64.AppImage)
((${#images[@]} == 1)) || die "Expected one AppImage in $mirror/dist, found ${#images[@]}"
name=$(basename -- "${images[0]}" .AppImage)
rm -rf "$source/dist/$name.AppImage" "$source/dist/$name.AppImage.sha256" "$source/dist/$name-symbols"
cp -- "dist/$name.AppImage" "dist/$name.AppImage.sha256" "$source/dist/"
cp -r -- "dist/$name-symbols" "$source/dist/"
(cd "$source/dist" && sha256sum -c "$name.AppImage.sha256")
printf '\nLinux AppImage: %s\n' "$source/dist/$name.AppImage"
