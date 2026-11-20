#!/bin/bash
#
# prepare.sh
# Ain
#
# Created by Ain on 2026/11/20.
#

set -euo pipefail
cd "$(dirname "$0")/.."
guest="$PWD/Generated/Guest"
mkdir -p "$guest"
if [[ -n "${THEOSLAB_ROOTFS:-}" ]]; then
    if [[ -e "$guest/fs" ]]; then
        printf '%s\n' "Generated/Guest/fs already exists. Move it aside before exporting a new toolchain." >&2
        exit 1
    fi
    python3 Scripts/export-toolchain.py "$THEOSLAB_ROOTFS" "$guest/fs"
fi
if [[ ! -f "$guest/fs/meta.db" || ! -f "$guest/fs/data/opt/.theoslab-ready" ||
      ! -f "$guest/fs/data/usr/bin/zip" ]]; then
    printf '%s\n' "Provide a provisioned iSH root via THEOSLAB_ROOTFS or extract Guest/fs from the released IPA." >&2
    exit 1
fi
if [[ ! -s "$guest/Toolchain/ollvm.so" || ! -s "$guest/Toolchain/LICENSE-OBFUSCATOR.TXT" ]]; then
    printf '%s\n' "Extract Guest/Toolchain from the IPA or build it with Scripts/build-ollvm.sh on Alpine ARM64." >&2
    exit 1
fi
if [[ "${THEOSLAB_EMBED_SDKS:-0}" == 1 ]]; then
    ./Scripts/embed-sdks.sh
fi
xcodegen generate
