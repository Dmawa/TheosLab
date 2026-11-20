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

