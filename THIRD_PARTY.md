# Third-party software

Theos Lab v2.8 includes the tools below. The Theos Lab sources and the scripts that build and assemble the release are in this repository. The links identify the upstream source used for the release.

## IshEmbed and iSH

The iOS app links IshEmbed v0.3.3, distributed under GPL-3.0. The source package pins iSH as a Git submodule. Clone IshEmbed at the release commit, run `git submodule update --init --recursive`, and follow its `scripts/build-ios.sh` and `scripts/build-rootfs.sh` instructions to rebuild the library and base guest. [IshEmbed source](https://github.com/Lolendor/ish-arm64-pkg/tree/6f96f02c71830914c2a608258a26a8ef0833d026) · [iSH source](https://github.com/Lolendor/ish-arm64/tree/2f075626049d989dc9ac350a35c09f0b18930ffc)

## ZIPFoundation

The app links ZIPFoundation 0.9.19 (MIT) to unpack the bundled guest image on first launch. [ZIPFoundation source](https://github.com/weichsel/ZIPFoundation/tree/0.9.19)

## Theos

Theos is distributed under GPL-3.0-or-later. Its source tree includes the Makefiles and references its vendor submodules at their corresponding revisions. Vendor directories in the IPA retain their upstream notices. `Scripts/provision-toolchain.sh` checks out the source and its submodules. `Scripts/export-toolchain.py` changes the vendor-presence check in `makefiles/master/rules.mk` to work with the packaged source tree. [Theos source](https://github.com/theos/theos/tree/8167f59de02fd32cf45b16bfcb1330dfa5c9974c) · [Provisioning script](Scripts/provision-toolchain.sh) · [Export script](Scripts/export-toolchain.py)

## Alpine packages

The guest is Alpine 3.19 on AArch64. The package inventory records the installed version, origin, license and exact aports revision for both the build guest and its base VM template. For a package, open the aports tree at that revision and locate the origin directory under `main` or `community`. Its `APKBUILD` links the upstream source tarballs and supplies the build instructions and patch list. [Package inventory](ALPINE-PACKAGES.tsv) · [Alpine aports](https://gitlab.alpinelinux.org/alpine/aports)

## ldid

The guest includes Procursus ldid v2.1.5-procursus7 for AArch64 Linux. Its source, license and build files are in the upstream release tree. [ldid source](https://github.com/ProcursusTeam/ldid/tree/v2.1.5-procursus7)

## Obfuscator-LLVM

The bundled `ollvm.so` uses Obfuscator-LLVM under the University of Illinois/NCSA license. The upstream notice is included in `Guest/Toolchain`. `Scripts/build-ollvm.sh` fetches the release revision and compiles it with `Toolchain/TheosLabOLLVM.cpp` for the guest's LLVM 17.0.5. [Obfuscator-LLVM source](https://github.com/eshard/obfuscator-llvm/tree/a629c1f9ee54a2dc99797dcb71f5a92a8478563f) · [Build script](Scripts/build-ollvm.sh)

## Capstone

The disassembly module links Capstone v5.0.1, distributed under the BSD 3-Clause license, as a static library compiled from the vendored sources in `Vendor/Capstone` (ARM and AArch64 only). [Capstone source](https://github.com/capstone-engine/capstone/tree/5.0.1)

## MachOKit

Mach-O parsing in the disassembly module uses MachOKit, distributed under the MIT license, as a Swift package pinned by revision in `project.yml`. [MachOKit source](https://github.com/p-x9/MachOKit)

## radare2

The guest toolchain includes radare2 (LGPL-3.0-or-later) from the Alpine 3.19 community repository, installed by `Scripts/provision-toolchain.sh`. It runs as a separate guest process for the decompilation feature; the iOS app itself does not link its code. The r2ghidra plugin (LGPL-3.0-only, Alpine edge/testing) is opt-in via `THEOSLAB_R2GHIDRA=1` because mixing edge repositories upgrades musl and may break iSH emulation; without it the module falls back to radare2's built-in pseudo-decompiler. [radare2 source](https://github.com/radareorg/radare2) · [r2ghidra source](https://github.com/radareorg/r2ghidra)
