#!/bin/sh
#
# provision-toolchain.sh
# Ain
#
# Created by Ain on 2026/11/20.
#

set -eu
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
export HOME=/root
THEOS=/opt/theos
revision=8167f59de02fd32cf45b16bfcb1330dfa5c9974c

if [ ! -f /opt/.theoslab-ready ]; then
    printf '%s\n' "Installing Alpine build tools"
    apk add --no-cache git curl ca-certificates bash make perl \
        clang17 lld llvm17 dpkg fakeroot coreutils findutils xz tar rsync file zip
    mkdir -p /opt /usr/local/bin
    if [ ! -d "$THEOS/.git" ]; then
        git init "$THEOS"
    fi
    git -C "$THEOS" fetch --depth 1 https://github.com/theos/theos.git "$revision"
    git -C "$THEOS" checkout --detach FETCH_HEAD
    git -C "$THEOS" submodule update --init --recursive --depth 1
    bin="$THEOS/toolchain/linux/iphone/bin"
    mkdir -p "$bin" "$THEOS/sdks"
    ln -sf "$(command -v dsymutil)" "$bin/dsymutil"
    for name in ar ranlib lipo strip nm libtool-darwin; do
        alias="$name"
        if [ "$name" = libtool-darwin ]; then alias=libtool; fi
        ln -sf "$(command -v "llvm-$name")" "$bin/$alias"
    done
    ln -sf "$(command -v ld64.lld)" "$bin/ld"
    curl -fsSL --retry 3 -o /usr/local/bin/ldid.tmp \
      https://github.com/ProcursusTeam/ldid/releases/download/v2.1.5-procursus7/ldid_linux_aarch64
    chmod +x /usr/local/bin/ldid.tmp
    mv /usr/local/bin/ldid.tmp /usr/local/bin/ldid
    touch /opt/.theoslab-ready
fi

if ! command -v zip >/dev/null 2>&1; then
    apk add --no-cache zip
fi

# 反汇编模块的 rizin 桥：radare2 来自 3.19 community（默认仓库，不动 musl）。
# r2ghidra 只在 edge/testing 有包，但混入 edge 会升级 musl、可能破坏 iSH 兼容性，
# 因此仅当显式指定 THEOSLAB_R2GHIDRA=1 时才安装（有降级链 pdc 兜底）。
if ! command -v radare2 >/dev/null 2>&1; then
    printf '%s\n' "Installing radare2"
    apk add --no-cache radare2 || printf '%s\n' "WARN: radare2 安装失败，反编译功能不可用（构建功能不受影响）"
fi
if [ "${THEOSLAB_R2GHIDRA:-0}" = "1" ] && [ ! -f /usr/lib/radare2/*/ghidra.so ]; then
    printf '%s\n' "Installing r2ghidra from edge/testing (opt-in, may break iSH emulation)"
    apk add --no-cache \
        --repository https://dl-cdn.alpinelinux.org/alpine/edge/community \
        --repository https://dl-cdn.alpinelinux.org/alpine/edge/testing \
        r2ghidra || printf '%s\n' "WARN: r2ghidra 安装失败，伪代码将降级到 pdc"
fi

# fakefs can't apply rsync's permission updates.
# New files still use the source mode, masked by umask.
cat > /usr/local/bin/rsync <<'RSYNC'
#!/bin/sh
exec /usr/bin/rsync "$@" --no-perms
RSYNC
chmod +x /usr/local/bin/rsync

bin="$THEOS/toolchain/linux/iphone/bin"
for name in clang clang++; do
    cat > "$bin/$name" <<'DRIVER'
#!/bin/sh
exec "/usr/bin/${0##*/}" -Qunused-arguments -fuse-ld=lld --ld-path=/usr/bin/ld64.lld "$@"
DRIVER
    chmod +x "$bin/$name"
done

