#!/usr/bin/env bash
# Packages the tested Linux build as dist/DragonsCrownProPC-v<version>-linux-x86_64.AppImage (and its .sha256). Local
# only: nothing is published, tagged or uploaded. The Linux counterpart of tools/package.ps1.
#
#   tools/package-linux.sh              build with tools/build.sh, then package
#   tools/package-linux.sh --skip-build package the existing build/cmake/linux/bin/dcp-loader
#   tools/package-linux.sh --verify DIR check an existing AppDir
#
# Needs patchelf, binutils, curl and dpkg (Debian/Ubuntu: licence texts come from the packages of the bundled
# libraries). Build on Ubuntu 24.04 (packaging/linux/ci-deps.sh): the glibc of the build host is the oldest one the
# AppImage runs on. GPU drivers, the Vulkan loader, X11/Wayland and glibc always come from the player's system.
set -euo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
skip_build=0 verify_dir=
while (($#)); do
    case $1 in
        --skip-build) skip_build=1 ;;
        --verify) verify_dir=${2:?--verify needs a folder}; shift ;;
        -h|--help) sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

step() { printf '\n==> %s\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# The newest glibc symbol the payload may import: 2.38 (loader, SDL3 and libcrypto), found by symbol inspection.
max_glibc=${DCP_MAX_GLIBC:-2.38}
appimagetool_version=1.9.1
appimagetool_sha256=ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0

# Libraries the player's system provides: glibc, the Vulkan loader and drivers, the display servers, audio daemons.
excluded='^(ld-linux.*|libc|libm|libdl|librt|libpthread|libresolv|libutil|libnsl|libanl|libcrypt|libmvec|libvulkan|libGL|libGLX|libGLdispatch|libEGL|libOpenGL|libgbm|libdrm.*|libX11|libX11-xcb|libxcb.*|libXau|libXdmcp|libXext|libXfixes|libXrender|libXi|libXcursor|libXrandr|libxkbcommon.*|libwayland-.*|libasound|libudev|libpulse.*|libpipewire.*|libdbus-1|libfontconfig|libOpenCL|libva.*|libvdpau|libnvidia-.*|libcuda|libz|libselinux|libpcre2-.*|libsystemd|libcap)\.so'
# Fallback copies, used only when the system's are older than the build's.
compat_libs='^(libstdc\+\+|libgcc_s)\.so'

forbidden_names='^(game|user|logs|cache|build|prepared|extracted|image|sce_sys|sce_module|eboot\.bin|param\.sfo|dcp\.ini|boot\.bin|content\.bin|image\.json|imports\.json|symbols)$'
forbidden_patterns='\.(pkg|pdb|debug|log|dmp|ini|bin|self|sprx|prx|elf|cpk|sfo|json|spv|pipeline_cache|o|a|tmp|bak|sav|py|ps1|c|cpp|h)$'

check_appdir() {
    local dir=$1 problems=0 item rel name needles
    problem() { echo "  $*" >&2; problems=$((problems + 1)); }
    needles=("$root" "${HOME:-/nonexistent-home}" VisualStudio DEBUG_SAULO gow3 'God of War' referencias-ps4)
    while IFS= read -r -d '' item; do
        rel=${item#"$dir"/}
        name=$(basename -- "$item")
        [[ $name =~ $forbidden_names ]] && problem "forbidden name: $rel"
        if [[ $rel != usr/share/licenses/* && $rel != usr/share/doc/* && -f $item && $name =~ $forbidden_patterns ]]; then
            problem "forbidden file type: $rel"
        fi
        if [[ -f $item && ! -L $item ]]; then
            [[ $(head -c 4 -- "$item" | od -An -tx1 | tr -d ' ') == 7f434e54 ]] && problem "PS4 package: $rel"
            [[ $(head -c 4 -- "$item" | od -An -tx1 | tr -d ' ') == 4f153d1d ]] && problem "PS4 SELF: $rel"
            for needle in "${needles[@]}"; do
                grep -a -q -F -- "$needle" "$item" && { problem "local path or stale name '$needle' in $rel"; break; }
            done
        fi
    done < <(find "$dir" -mindepth 1 -print0)
    for leaf in AppRun dragons-crown-pro-pc.desktop dragons-crown-pro-pc.png usr/bin/dcp-loader \
                usr/share/licenses/DragonsCrownProPC/THIRD-PARTY-LICENSES.txt usr/share/doc/DragonsCrownProPC/README.txt; do
        [[ -e $dir/$leaf ]] || problem "missing: $leaf"
    done
    local missing
    missing=$(env -u LD_LIBRARY_PATH ldd "$dir/usr/bin/dcp-loader" | grep 'not found' || true)
    [[ -z $missing ]] || problem "unresolved libraries: $missing"
    local newest
    newest=$(find "$dir" -type f \( -name '*.so*' -o -perm -u+x \) -exec objdump -T {} + 2>/dev/null |
             grep -o 'GLIBC_2\.[0-9.]*' | sed 's/GLIBC_//' | sort -uV | tail -1 || true)
    if [[ -n $newest && $(printf '%s\n' "$newest" "$max_glibc" | sort -V | tail -1) != "$max_glibc" ]]; then
        problem "needs glibc $newest, newer than $max_glibc: build on Ubuntu 24.04 or set DCP_MAX_GLIBC"
    fi
    ((problems == 0)) || die "release check failed ($problems problem(s))"
    echo "AppDir is clean (newest glibc symbol: ${newest:-none})"
}

if [[ -n $verify_dir ]]; then
    check_appdir "$(cd -- "$verify_dir" && pwd)"
    exit 0
fi

[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || die 'Packaging needs Linux x86_64 (Windows: tools\package.ps1).'
for tool in patchelf objdump objcopy strip curl dpkg dpkg-query ldd sha256sum; do
    command -v "$tool" >/dev/null || die "Missing $tool"
done

version=$(sed -n 's/^set(DCP_PORT_VERSION "\([^"]*\)").*/\1/p' CMakeLists.txt)
[[ -n $version ]] || die 'DCP_PORT_VERSION not found in CMakeLists.txt'
name=DragonsCrownProPC-v$version-linux-x86_64
loader=$root/build/cmake/linux/bin/dcp-loader
dist=$root/dist
work=$root/build/appimage
appdir=$work/AppDir
symbols=$dist/$name-symbols

step "Dragon's Crown Pro PC $version - Linux AppImage (local only)"
((skip_build)) || "$root/tools/build.sh"
[[ -x $loader ]] || die "Missing $loader (run without --skip-build)"

rm -rf "$appdir"
mkdir -p "$dist" "$symbols" "$appdir/usr/bin" "$appdir/usr/lib/compat" "$appdir/usr/share/licenses/DragonsCrownProPC" \
         "$appdir/usr/share/doc/DragonsCrownProPC" "$appdir/usr/share/applications" \
         "$appdir/usr/share/icons/hicolor/256x256/apps"
rm -f "$dist/$name.AppImage" "$dist/$name.AppImage.sha256"

step 'Staging dcp-loader without debug information'
objcopy --only-keep-debug "$loader" "$symbols/dcp-loader.debug"
objcopy --strip-debug --add-gnu-debuglink="$symbols/dcp-loader.debug" "$loader" "$appdir/usr/bin/dcp-loader"
chmod 755 "$appdir/usr/bin/dcp-loader"

step 'Staging the libraries it loads'
declare -A seen=()
declare -A owners=()
bundle() {
    local elf=$1 line lib file
    while read -r line; do
        lib=$(awk '/=> \//{print $3}' <<<"$line")
        [[ -n $lib ]] || continue
        file=$(basename -- "$lib")
        [[ -n ${seen[$file]:-} ]] && continue
        seen[$file]=1
        [[ $file =~ $excluded ]] && continue
        if [[ $file =~ $compat_libs ]]; then
            install -m755 "$(readlink -f -- "$lib")" "$appdir/usr/lib/compat/$file"
        else
            install -m755 "$(readlink -f -- "$lib")" "$appdir/usr/lib/$file"
            bundle "$lib"
        fi
        owners[$file]=$lib
    done < <(env -u LD_LIBRARY_PATH ldd "$elf")
}
bundle "$loader"
for lib in "$appdir"/usr/lib/*.so*; do
    strip --strip-unneeded "$lib"
    patchelf --set-rpath '$ORIGIN' "$lib"
done
strip --strip-unneeded "$appdir"/usr/lib/compat/*.so* 2>/dev/null || true
# DT_RPATH (not RUNPATH) is inherited by the libraries' own dependencies and wins over LD_LIBRARY_PATH.
patchelf --force-rpath --set-rpath '$ORIGIN/../lib' "$appdir/usr/bin/dcp-loader"
echo "Bundled: $(cd "$appdir/usr/lib" && ls -- *.so* | tr '\n' ' ')"
echo "Fallback: $(cd "$appdir/usr/lib/compat" && ls -- *.so* | tr '\n' ' ')"

step 'Staging AppRun, desktop entry, icon, licences and README'
glibcxx_need=$(objdump -T "$appdir/usr/bin/dcp-loader" "$appdir"/usr/lib/*.so* | grep -o 'GLIBCXX_3\.4\.[0-9]*' |
               sed 's/.*\.//' | sort -n | tail -1)
gcc_need=$(objdump -T "$appdir/usr/bin/dcp-loader" "$appdir"/usr/lib/*.so* | grep -o 'GCC_[0-9][0-9.]*' |
           sed 's/^GCC_//; s/\..*//' | sort -n | tail -1)
sed "s/@GLIBCXX_NEED@/${glibcxx_need:-0}/g; s/@GCC_NEED@/${gcc_need:-0}/g" \
    packaging/linux/AppRun > "$appdir/AppRun"
chmod 755 "$appdir/AppRun"
install -m644 packaging/linux/dragons-crown-pro-pc.desktop "$appdir/dragons-crown-pro-pc.desktop"
install -m644 packaging/linux/dragons-crown-pro-pc.desktop "$appdir/usr/share/applications/"
install -m644 packaging/icons/app-icon-256.png "$appdir/dragons-crown-pro-pc.png"
install -m644 packaging/icons/app-icon-256.png "$appdir/usr/share/icons/hicolor/256x256/apps/dragons-crown-pro-pc.png"
ln -s dragons-crown-pro-pc.png "$appdir/.DirIcon"
desktop-file-validate "$appdir/dragons-crown-pro-pc.desktop" 2>/dev/null || true
sed "s/@VERSION@/$version/" packaging/README-linux.txt > "$appdir/usr/share/doc/DragonsCrownProPC/README.txt"

licenses=$appdir/usr/share/licenses/DragonsCrownProPC
install -m644 LICENSE "$licenses/LICENSE.txt"
install -m644 packaging/licenses/THIRD-PARTY-LICENSES.txt "$licenses/"
declare -A built_in=(
    [shadPS4]=gpu/shadps4/LICENSE [sirit]=gpu/third_party/sirit/LICENSE.txt
    [SPIRV-Headers]=gpu/third_party/sirit/externals/SPIRV-Headers/LICENSE [half]=gpu/third_party/half/LICENSE.txt
    [SMAA]=gpu/shadps4/video_core/host_shaders/smaa/LICENSE.txt [DejaVu]=gpu/third_party/fonts/LICENSE-DejaVu.txt
    [imgui]=gpu/third_party/imgui/LICENSE.txt [magic_enum]=gpu/third_party/magic_enum/LICENSE
    [miniz]=gpu/third_party/miniz/LICENSE [xbyak]=gpu/third_party/xbyak/COPYRIGHT)
for component in "${!built_in[@]}"; do
    [[ -f ${built_in[$component]} ]] || die "Missing licence file: ${built_in[$component]}"
    mkdir -p "$licenses/$component"
    install -m644 "${built_in[$component]}" "$licenses/$component/"
done
# The licence texts of the distribution packages the bundled libraries come from (and of SDL3, built from source).
manifest=$licenses/SYSTEM-PACKAGES.txt
{
    echo "Libraries bundled in the AppImage, with the Ubuntu packages they come from and their licence texts."
    echo "Libraries and drivers the player's system provides (glibc, Vulkan, X11/Wayland, audio) are not bundled."
} > "$manifest"
for lib in $(cd "$appdir/usr/lib" && ls -- *.so* compat/*.so* 2>/dev/null | sed 's|.*/||' | sort -u); do
    path=${owners[$lib]:-}
    [[ -n $path ]] || continue
    package=$(dpkg-query -S "$(readlink -f -- "$path")" 2>/dev/null | head -1 | cut -d: -f1 || true)
    if [[ -n $package ]]; then
        version_of=$(dpkg-query -W -f='${Version}' "$package")
        mkdir -p "$licenses/system/$package"
        install -m644 "/usr/share/doc/$package/copyright" "$licenses/system/$package/copyright"
        printf '\n%s (%s %s)\n  Licence text: licenses/system/%s/copyright\n' "$lib" "$package" "$version_of" "$package" >> "$manifest"
    elif [[ $lib == libSDL3.so* ]]; then
        sdl_license=$(find "$(dirname -- "$path")/.." /usr/local/share -iname 'LICENSE*' -path '*SDL3*' 2>/dev/null | head -1 || true)
        [[ -n $sdl_license ]] || sdl_license=${SDL3_LICENSE:-}
        [[ -f $sdl_license ]] || die 'SDL3 licence text not found (set SDL3_LICENSE=/path/to/LICENSE.txt)'
        mkdir -p "$licenses/system/SDL3"
        install -m644 "$sdl_license" "$licenses/system/SDL3/LICENSE.txt"
        printf '\n%s (SDL3, built from source by packaging/linux/ci-deps.sh)\n  Licence text: licenses/system/SDL3/LICENSE.txt\n' "$lib" >> "$manifest"
    else
        die "No package owns $path: add its licence handling to tools/package-linux.sh"
    fi
done

step 'Checking the AppDir'
check_appdir "$appdir"

step 'Writing the AppImage'
tool=$work/appimagetool-$appimagetool_version-x86_64.AppImage
if [[ ! -x $tool ]]; then
    curl -fL --retry 3 -o "$tool.part" \
        "https://github.com/AppImage/appimagetool/releases/download/$appimagetool_version/appimagetool-x86_64.AppImage"
    echo "$appimagetool_sha256  $tool.part" | sha256sum -c - || die 'appimagetool does not match the pinned checksum'
    chmod +x "$tool.part"
    mv "$tool.part" "$tool"
fi
ARCH=x86_64 "$tool" --appimage-extract-and-run "$appdir" "$dist/$name.AppImage.new" >"$work/appimagetool.log" 2>&1 ||
    { cat "$work/appimagetool.log" >&2; die 'appimagetool failed'; }
mv -f "$dist/$name.AppImage.new" "$dist/$name.AppImage"
chmod 755 "$dist/$name.AppImage"
(cd "$dist" && sha256sum "$name.AppImage" > "$name.AppImage.sha256")

printf '\nAPPIMAGE READY (nothing was published)\n'
printf '  AppImage: %s (%s)\n' "$dist/$name.AppImage" "$(du -h "$dist/$name.AppImage" | cut -f1)"
printf '  SHA-256:  %s\n' "$(cut -d' ' -f1 "$dist/$name.AppImage.sha256")"
printf '  Symbols:  %s (not in the package)\n' "$symbols/dcp-loader.debug"
