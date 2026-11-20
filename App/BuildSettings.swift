//
// BuildSettings.swift
// Ain
//
// Created by Ain on 2026/11/20.
//

import Foundation

struct SDKDownload {
    let url: URL
    let sha256: String?
    var isZip: Bool { url.pathExtension == "zip" }

    static let catalog: [String: SDKDownload] = {
        var entries: [String: SDKDownload] = [:]
        for version in ["12.4", "13.7", "14.5", "15.6", "16.5"] {
            let url = URL(string: "https://github.com/theos/sdks/releases/download/master-146e41f/iPhoneOS\(version).sdk.tar.xz")!
            entries[version] = SDKDownload(url: url, sha256: nil)
        }
        for (version, digest) in [
            ("18.5", "3a19bf33a9b4995a6cc9b30ba28b3e6822d58244c7cf66b9640ee86089ca808c"),
            ("18.6", "e654ecf1c841a908a09b39f663249bdcc05468b4d10f998e0d29800a5337a9b7")
        ] {
            let url = URL(string: "https://github.com/xybp888/iOS-SDKs/releases/download/iOS\(version)-SDKs/iPhoneOS\(version).sdk.zip")!
            entries[version] = SDKDownload(url: url, sha256: digest)
        }
        return entries
    }()
}

enum ObfuscationMode: String, CaseIterable, Identifiable {
    case off, builtIn, ollvm, plugin
    var id: Self { self }
    var usesOLLVMOptions: Bool { self == .builtIn || self == .ollvm }
    var title: String {
        switch self {
        case .off: return "关闭"
        case .builtIn: return "内嵌 OLLVM"
        case .ollvm: return "外部 OLLVM Clang"
        case .plugin: return "LLVM 17 Pass"
        }
    }
}

enum BuildConfiguration: String, CaseIterable, Identifiable {
    case debug = "Debug"
    case release = "Release"
    var id: Self { self }
    var makeArgument: String { self == .debug ? "DEBUG=1" : "DEBUG=0" }
}

enum BuildArchitecture: String, CaseIterable, Identifiable {
    case project, arm64, arm64e, universal
    var id: Self { self }
    var title: String {
        switch self {
        case .project: return "项目默认"
        case .universal: return "arm64 + arm64e"
        default: return rawValue
        }
    }
    var makeArgument: String? {
        switch self {
        case .project: return nil
        case .universal: return "ARCHS=arm64 arm64e"
        default: return "ARCHS=\(rawValue)"
        }
    }
    var requiresARM64e: Bool { self == .arm64e || self == .universal }
}

struct BuildOptions {
    var configuration: BuildConfiguration = .debug
    var architecture: BuildArchitecture = .project
    var libraries: [String] = []
    var obfuscation: ObfuscationMode = .off
    var flatten = true
    var substitute = true
    var bogus = false
    var parameters = ""

    static func isLibrary(_ path: String) -> Bool {
        ["a", "dylib", "tbd"].contains((path as NSString).pathExtension.lowercased())
    }

    func compilerArguments(bundledPass: String? = nil) throws -> [String] {
        guard obfuscation != .off else { return [] }
        let custom = parameters.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        guard custom.allSatisfy({ $0.range(of: #"^-{1,2}[A-Za-z0-9_][A-Za-z0-9_=,.:+%-]*$"#,
                                         options: .regularExpression) != nil }) else {
            throw WorkspaceError.message("每行填写一个 LLVM 参数，例如 -bcf_prob=30。")
        }
        let presets: [String] = obfuscation.usesOLLVMOptions
            ? [(flatten, "-fla"), (substitute, "-sub"), (bogus, "-bcf")].compactMap { $0.0 ? $0.1 : nil }
            : []
        var args: [String] = []
        if obfuscation == .builtIn {
            guard let bundledPass else {
                throw WorkspaceError.message("安装包缺少内嵌 OLLVM。")
            }
            for parameter in custom {
                let parts = parameter.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard let flag = parts.first,
                      ["-bcf_prob", "-bcf_loop", "-sub_loop"].contains(flag) else { continue }
                guard parts.count == 2, let value = Int32(parts[1]), value > 0,
                      flag != "-bcf_prob" || value <= 100 else {
                    throw WorkspaceError.message("OLLVM 参数无效 · \(parameter)")
                }
            }
            // Load the pass before LLVM reads its flags.
            args = ["-Xclang", "-load", "-Xclang", bundledPass, "-fpass-plugin=\(bundledPass)",
                    "-Xclang", "-disable-O0-optnone"]
        } else if obfuscation == .plugin {
            args = ["-fpass-plugin=/opt/theoslab-tools/ollvm-pass.so", "-O1"]
        }
        for flag in presets + custom { args += ["-mllvm", flag] }
        return args
    }

    static func deployment(in makefile: String) -> String? {
        let pattern = #"(?m)^\s*(?:override\s+)?TARGET\s*[:?+]?=\s*iphone:(?:clang:)?[^:\s#]+:([0-9]+(?:\.[0-9]+){0,2})(?=[\s#]|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: makefile, range: NSRange(makefile.startIndex..., in: makefile)),
              let range = Range(match.range(at: 1), in: makefile) else { return nil }
        return String(makefile[range])
    }
}
