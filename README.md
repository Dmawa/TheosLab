# Theos Lab

用了别忘记点个stars，球球了

这个小玩意其实我一年前就想写了，就是一个嵌入linux，然后theos编译，还支持了模块化编译，也就是ios17sdk以上，这种方案不用上传服务器，还挺简单的吧其实，借助了Chatgpt-6.2sol。也会支持swift，这个混淆器有点鸡肋，有兴趣的可以自己改进一下，有问题请积极发issues，每天都会看。

在 iPhone 或 iPad 上选一个 Theos 项目、选 iPhoneOS SDK、编辑源码并运行 GNU Make。App 内嵌 IshEmbed 的 ARM64 Linux 运行时，使用上游 Theos 的 Makefile 和 Logos、Perl 等构建工具。构建发生在设备上。

## 构建 App

在安装了完整 Xcode 的 Mac 上打开源码目录。可以从 Release 的 IPA 提取工具链镜像，再生成 Xcode 工程。

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
brew install xcodegen
ipa="/绝对路径/TheosLab-2.8-unsigned.ipa"
tmp="$(mktemp -d)"
unzip -q "$ipa" 'Payload/TheosLab.app/Guest/fs/*' 'Payload/TheosLab.app/Guest/Toolchain/*' -d "$tmp"
mkdir -p Generated/Guest
ditto "$tmp/Payload/TheosLab.app/Guest/fs" Generated/Guest/fs
ditto "$tmp/Payload/TheosLab.app/Guest/Toolchain" Generated/Guest/Toolchain
./Scripts/prepare.sh
open TheosLab.xcodeproj
```

也可在 IshEmbed 0.3.3 的 ARM64 Alpine 来宾中运行 `Scripts/provision-toolchain.sh`，关闭来宾后以 `THEOSLAB_ROOTFS=/path/to/fs ./Scripts/prepare.sh` 导出工具链。自己构建内嵌 OLLVM 的方法见下文。个人构建可用 `THEOSLAB_EMBED_SDKS=1 ./Scripts/prepare.sh` 从 SDK 压缩包准备离线资源。

Release 提供未签名 IPA。安装到 iPhone 或 iPad 前需要开发签名，也可以选择自己的团队和 Bundle Identifier，直接从 Xcode 运行。项目的最低系统是 iOS 15，模拟器目标使用 Apple Silicon。 [Apple 真机运行说明](https://developer.apple.com/documentation/xcode/building-and-running-an-app)

## 打开项目并构建

1. 可以在「文件」的「我的 iPhone／iPad → Theos Lab」下放一个含 `Makefile` 的项目目录，然后在 App 的「选择项目」菜单中打开。选「从『文件』导入项目」，进入含 `Makefile` 的文件夹或其上一级，再点「打开」。找到一个项目时直接打开，找到多个时弹出项目列表。来自 iCloud Drive 或其他外部位置的目录会复制到 `Documents/Projects`。
2. 选 SDK 和最低 iOS 版本。公开版使用 iPhoneOS 26.0 或 27.0 时，先把 `iPhoneOS26.0.sdk` 或 `iPhoneOS27.0.sdk` 文件夹放到「文件」，再从「构建设置 → 导入本地 SDK」选择该文件夹。Mac 上可在对应版本的 Xcode 中用 `xcrun --sdk iphoneos --show-sdk-path` 查询 SDK 位置。12.4、13.7、14.5、15.6、16.5、18.5 和 18.6 可从「构建设置」下载。App 默认读取 Makefile 中写明的最低版本。Theos、GNU Make、Clang/LLD、Perl/Logos、ldid、ZIP 和 Debian 打包工具已内嵌，准备好 SDK 后可离线构建。工具链展开约占 650 MiB，所用 SDK 会另外占用空间。
3. 从文件菜单打开 Makefile、源码、头文件或 control。切换文件和构建前会保存当前编辑。
4. 选择「自动识别」或指定 `.ipa`、`.dylib`、`.deb`，再点「构建」。产物保存在 App 的 `Documents/Builds`，可在「文件」中打开或通过「产物」菜单分享。

「构建设置」可选择 Debug、Release、arm64、arm64e 或双架构。使用 arm64e 时，请导入可在内嵌 Alpine 中运行、能生成 arm64e 切片的 Linux ARM64 Mach-O 链接器，并将最低系统版本设为 iOS 14.0 或更高。额外链接库可以选择项目内现有的库，也可以将 `.a`、`.dylib` 或 `.tbd` 导入项目的 Libraries 目录。选中的库用于链接。额外动态库的运行时装载路径和分发由项目管理。

自动模式从实际构建结果识别类型。单独的 App bundle 会装入 `Payload` 并打包成 IPA。带 Debian control 的库或混合项目走 Theos 的 `make package`。普通动态库直接导出，其他项目保留构建归档。生成的项目 IPA 需另行用匹配目标 App 的开发或分发描述文件签名。

可以把源码包里的 `Example` 目录放到 App 的 Documents，试编译双文件 C 库。每次运行会把项目快照放进 Linux 并重新构建。来宾内的 `/var/mobile/theos` 会指向内嵌工具链，兼容写死这一旧路径的 Makefile。包含自定义绝对路径或原生 Mac 工具的 Makefile 需要相应 Linux 替代。内置工具链面向 C/C++、Objective-C 和 Logos。Swift 编译、`actool`、`ibtool` 需要各自的工具链，当前版本未集成。

## 编辑和诊断

iPad 上可收起左侧文件树，iPhone 可用顶部的「项目文件」打开。标签下方显示当前路径，可跳到当前文件的符号或一次复制整份代码。图片在标签内预览，支持缩放。补全结合光标上下文、文件中的声明和 UIKit 等常见 API，行尾可显示预测文本。外接键盘可用方向键选择候选、Tab 接受、Esc 关闭，⌘B 构建。

构建后，「诊断」显示编译器的错误、警告和备注。项目文件的诊断可点击并跳到对应行列。打字时面板收起，结束编辑时恢复。完整输出另见「构建日志」。

## LLVM 混淆

在「构建设置 → LLVM 混淆 → 模式」选择「内嵌 OLLVM」，即可使用控制流平坦化 `-fla`、指令替换 `-sub` 和虚假控制流 `-bcf`。它由内嵌的 Clang 17.0.5 加载，可离线使用。参数框每行填写一个 LLVM 参数，例如 `-bcf_prob=30`、`-bcf_loop=1` 或 `-sub_loop=2`。App 会加上 `-mllvm`，构建日志会记录启用的参数。

如需使用自己的编译器，选择「外部 OLLVM Clang」，再导入能在内嵌 Alpine 运行的 Linux ARM64 ELF 可执行文件。「LLVM 17 Pass」接收与内嵌 Clang 的 LLVM ABI 匹配的 Linux ARM64 ELF 共享库。

内嵌 pass 使用 eShard 维护的 Obfuscator-LLVM。可在 Alpine ARM64 3.19 中安装 `bash git clang17 llvm17-dev build-base` 后运行 `bash Scripts/build-ollvm.sh` 重新构建。[上游源码和许可证](https://github.com/eshard/obfuscator-llvm/tree/a629c1f9ee54a2dc99797dcb71f5a92a8478563f)

## 上游

- [IshEmbed v0.3.3](https://github.com/Lolendor/ish-arm64-pkg/tree/v0.3.3) 提供嵌入式 ARM64 Linux，依 GPL-3.0 授权。
- [Theos](https://github.com/theos/theos) 提供构建、打包规则和子模块。
- [Theos SDK 发布](https://github.com/theos/sdks/releases/tag/master-146e41f) 提供可选 SDK。
- [iPhoneOS 26.0 SDK](https://github.com/xybp888/iOS-SDKs/releases/tag/iOS26.0-SDKs) 和 [iPhoneOS 27.0 SDK](https://github.com/xybp888/iOS-SDKs/releases/tag/iOS27.0-SDKs) 来自 xybp888/iOS-SDKs 发布页。准备脚本校验 SHA-256 和 SDK 版本。
- [Alpine v3.19 构建包来源](https://gitlab.alpinelinux.org/alpine/aports/-/tree/3.19-stable) 和 [Procursus ldid 源码](https://github.com/ProcursusTeam/ldid/tree/v2.1.5-procursus7)。

## 许可证

Copyright © 2026 Ain。Theos Lab 原创源码按 GNU GPL v3.0 发布。内嵌组件保留各自的上游许可证，第三方源码版本和构建说明随项目提供。 [GPL v3.0](LICENSE) · [第三方组件](THIRD_PARTY.md)
