//
// ProjectArchive.swift
// Ain
//
// Created by Ain on 2026/11/20.
//

import Foundation

enum WorkspaceError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

enum ProjectArchive {
    static func write(_ root: URL, omittingBuildFiles: Bool, to output: URL) throws {
        let files = FileManager.default
        guard files.createFile(atPath: output.path, contents: nil) else {
            throw WorkspaceError.message("无法创建项目快照。")
        }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        try appendDirectory(root, prefix: "", omit: omittingBuildFiles, to: handle)
        try handle.write(contentsOf: Data(repeating: 0, count: 1024))
    }

    private static func appendDirectory(_ directory: URL, prefix: String,
                                        omit: Bool, to handle: FileHandle) throws {
        let files = FileManager.default
        for entry in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let name = entry.lastPathComponent
            if name == ".DS_Store" || (omit && prefix.isEmpty && [".theos", "packages"].contains(name)) { continue }
            let path = prefix + name
            let info = try files.attributesOfItem(atPath: entry.path)
            let mode = (info[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
            switch info[.type] as? FileAttributeType {
            case .typeDirectory:
                try header(path, mode: mode, size: 0, type: 53, link: "", to: handle)
                try appendDirectory(entry, prefix: path + "/", omit: omit, to: handle)
            case .typeSymbolicLink:
                let destination = try files.destinationOfSymbolicLink(atPath: entry.path)
                try header(path, mode: mode, size: 0, type: 50, link: destination, to: handle)
            case .typeRegular:
                guard let size = (info[.size] as? NSNumber)?.intValue else { continue }
                try header(path, mode: mode, size: size, type: 48, link: "", to: handle)
                let input = try FileHandle(forReadingFrom: entry)
                defer { try? input.close() }
                var remaining = size
                while remaining > 0 {
                    guard let chunk = try input.read(upToCount: min(remaining, 65536)), !chunk.isEmpty else {
                        throw WorkspaceError.message("文件在构建期间发生变化 · \(path)")
                    }
                    try handle.write(contentsOf: chunk)
                    remaining -= chunk.count
                }
                if size % 512 != 0 {
                    try handle.write(contentsOf: Data(repeating: 0, count: 512 - size % 512))
                }
            default:
                throw WorkspaceError.message("不支持的文件类型 · \(path)")
            }
        }
    }

    private static func header(_ path: String, mode: Int, size: Int, type: UInt8,
                               link: String, to handle: FileHandle) throws {
        var bytes = [UInt8](repeating: 0, count: 512)
        func field(_ value: String, _ offset: Int, _ length: Int) throws {
            guard value.utf8.count <= length else {
                throw WorkspaceError.message("归档路径或链接过长 · \(path)")
            }
            bytes.replaceSubrange(offset..<(offset + value.utf8.count), with: value.utf8)
        }
        if path.utf8.count <= 100 {
            try field(path, 0, 100)
        } else {
            guard let slash = path.indices.reversed().first(where: {
                path[$0] == "/" && path[..<$0].utf8.count <= 155 &&
                path[path.index(after: $0)...].utf8.count <= 100
            }) else { throw WorkspaceError.message("归档路径过长 · \(path)") }
            try field(String(path[..<slash]), 345, 155)
            try field(String(path[path.index(after: slash)...]), 0, 100)
        }
        try field(String(format: "%07o", mode), 100, 7)
        try field("0000000", 108, 7)
        try field("0000000", 116, 7)
        try field(String(size, radix: 8).leftPadded(to: 11), 124, 11)
        try field("00000000000", 136, 11)
        try field("        ", 148, 8)
        bytes[156] = type
        try field(link, 157, 100)
        try field("ustar", 257, 5)
        try field("00", 263, 2)
        try field(String(format: "%06o", bytes.reduce(0) { $0 + Int($1) }), 148, 6)
        bytes[154] = 0
        bytes[155] = 32
        try handle.write(contentsOf: Data(bytes))
    }
}

private extension String {
    func leftPadded(to length: Int) -> String {
        String(repeating: "0", count: max(0, length - count)) + self
    }
}
