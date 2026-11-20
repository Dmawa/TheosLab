#!/bin/sh
#
# bootstrap.sh
# Ain
#
# Created by Ain on 2026/11/20.
#

set -eu
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
export HOME=/root
THEOS=/opt/theos
/bin/busybox mkdir -p -m 1777 /tmp
if [ ! -f /opt/.theoslab-ready ] || [ ! -f "$THEOS/makefiles/common.mk" ]; then
    echo "Embedded Theos build tools are missing." >&2
    exit 1
fi
for tool in make clang ld64.lld perl zip dpkg-deb ldid; do
    command -v "$tool" >/dev/null 2>&1 || {
        printf 'Embedded tool missing: %s\n' "$tool" >&2
        exit 1
    }
done

# Some Theos projects hardcode /var/mobile/theos.
mkdir -p /var/mobile
if [ ! -e /var/mobile/theos ] && [ ! -L /var/mobile/theos ]; then
    ln -s "$THEOS" /var/mobile/theos
fi

version="${1:-}"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
# Overlay the module map without editing the SDK on disk.
if [ -n "$version" ]; then
    sdk="$THEOS/sdks/iPhoneOS$version.sdk"
    config="/opt/theoslab-clang/$version"
    mkdir -p "$config"
    map="$sdk/usr/include/DarwinFoundation1.modulemap"
    : > "$scratch/sdk.cfg"
    if [ -d "$sdk/System/Library/SubFrameworks" ]; then
        printf '%s\n' "-F$sdk/System/Library/SubFrameworks" >> "$scratch/sdk.cfg"
    fi
    if [ -f "$map" ] && grep -q '^module _c_standard_library_obsolete ' "$map"; then
        sed '/^module _c_standard_library_obsolete .*{/,/^}/d' "$map" > "$scratch/DarwinFoundation1.modulemap"
        cat > "$scratch/overlay.yaml" <<EOF
{ "version": 0, "use-external-names": false, "roots": [
  { "type": "file", "name": "$map", "external-contents": "$config/DarwinFoundation1.modulemap" }
] }
EOF
        printf '%s\n' "-ivfsoverlay" "$config/overlay.yaml" >> "$scratch/sdk.cfg"
    fi
    for file in "$scratch"/*; do
        dest="$config/${file##*/}"
        if ! cmp -s "$file" "$dest"; then /bin/busybox mv -f "$file" "$dest"; fi
    done
fi

# Use the sysroot to pick SDK flags for each compile or link.
drivers="$THEOS/toolchain/linux/iphone/bin"
cat > "$scratch/driver" <<'DRIVER'
#!/bin/sh
sysroot=''
previous=''
compile=''
link_output=''
preprocess=''
arch=''
for arg do
    case "$previous" in -isysroot|--sysroot) sysroot="$arg";; esac
    case "$arg" in --sysroot=*) sysroot=${arg#--sysroot=};; esac
    if [ "$arg" = "-c" ]; then compile=yes; fi
    if [ "$previous" = "-o" ]; then link_output="$arg"; fi
    if [ "$previous" = "-arch" ]; then arch="$arg"; fi
    case "$arg" in arm64e-apple-ios*) arch=arm64e;; esac
    case "$arg" in -M|-MM|-E|-S|-fsyntax-only) preprocess=yes;; esac
    previous="$arg"
done
case "$sysroot" in
/opt/theos/sdks/iPhoneOS*.sdk)
    version=${sysroot##*/iPhoneOS}
    config="/opt/theoslab-clang/${version%.sdk}/sdk.cfg"
    if [ -s "$config" ]; then set -- "@$config" "$@"; fi
    ;;
esac
driver="/usr/bin/${0##*/}"
if [ -z "$compile$preprocess" ] && [ -n "$link_output" ] && [ -n "${THEOSLAB_LINK_LIBRARIES:-}" ]; then
    set -- "$@" "@$THEOSLAB_LINK_LIBRARIES"
fi
if [ "$compile" = yes ] && [ -n "${THEOSLAB_COMPILER_ARGS:-}" ]; then
    set -- "$@" "@$THEOSLAB_COMPILER_ARGS"
    if [ "${THEOSLAB_OBFUSCATION:-}" = ollvm ]; then
        driver="/opt/theoslab-tools/ollvm-clang"
        mode=gcc
        if [ "${0##*/}" = clang++ ]; then mode=g++; fi
        set -- "--driver-mode=$mode" "-resource-dir=$(/usr/bin/clang -print-resource-dir)" "$@"
    fi
fi
linker=/usr/bin/ld64.lld
if [ "$arch" = arm64e ] && [ -z "$compile$preprocess" ] && [ -n "$link_output" ]; then
    linker=/opt/theoslab-tools/arm64e-ld
    if [ ! -x "$linker" ]; then
        printf '%s\n' 'error: arm64e requires a compatible Mach-O linker. Import one in Build Settings.' >&2
        exit 1
    fi
    "$driver" -Qunused-arguments --ld-path="$linker" "$@"
    /usr/bin/llvm-lipo -verify_arch arm64e "$link_output" || {
        printf '%s\n' 'error: the linker did not produce an arm64e slice.' >&2
        exit 1
    }
    exit
fi
exec "$driver" -Qunused-arguments -fuse-ld=lld --ld-path="$linker" "$@"
DRIVER
for driver in clang clang++; do
    dest="$drivers/$driver"
    if cmp -s "$scratch/driver" "$dest"; then continue; fi
    tmp="$(mktemp "$drivers/.driver.XXXXXX")"
    cat "$scratch/driver" > "$tmp"
    chmod 755 "$tmp"
    /bin/busybox mv -f "$tmp" "$dest"
done
