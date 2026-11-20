#!/bin/bash
#
# embed-sdks.sh
# Ain
#
# Created by Ain on 2026/11/20.
#

set -euo pipefail
cd "$(dirname "$0")/.."
cache="${THEOSLAB_SDK_CACHE:-$PWD/.build/sdk-downloads}"
dest="$PWD/Generated/Guest/SDKs"
mkdir -p "$cache" "$dest"
for version in 26.0 27.0; do
    archive="$cache/iPhoneOS$version.sdk.zip"
    case "$version" in
        26.0) digest=b5e6206f02304f5af061acfacc447d38515e90b6dfdf57c4334dc69712adac2c ;;
        27.0) digest=97d107a51562b2236c064a0dea98777faddcf65a1259d4f7abccd46695ef3c15 ;;
    esac
    if [[ ! -f "$archive" ]]; then
        curl -fsSL --retry 3 -o "$archive.partial" \
          "https://github.com/xybp888/iOS-SDKs/releases/download/iOS$version-SDKs/iPhoneOS$version.sdk.zip"
        mv "$archive.partial" "$archive"
    fi
    printf '%s  %s\n' "$digest" "$archive" | shasum -a 256 -c
    stage="$(mktemp -d "$cache/sdk.XXXXXX")"
    trap 'rm -rf "$stage"' EXIT
    ditto -x -k "$archive" "$stage"
    sdk="iPhoneOS$version.sdk"
    test -d "$stage/$sdk/usr/include"
    test -f "$stage/$sdk/usr/lib/libSystem.tbd"
    actual="$(plutil -extract Version raw "$stage/$sdk/SDKSettings.plist")"
    test "$actual" = "$version"
    # LLD 17 can't read arm64e.x1-ios. Leave the other targets and symbols alone.
    find "$stage/$sdk" -type f -name '*.tbd' -exec perl -pi -e \
      's/,\h*arm64e\.x1-ios(?=\s*[,\]])//g; s/arm64e\.x1-ios\h*,\h*//g' {} +
    tar --no-mac-metadata --no-xattrs -czf "$stage/$sdk.tar.gz" -C "$stage" "$sdk"
    mv "$stage/$sdk.tar.gz" "$dest/$sdk.tar.gz"
    rm -rf "$stage"
    trap - EXIT
done
