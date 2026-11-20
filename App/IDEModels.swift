//
// IDEModels.swift
// Ain
//
// Created by Ain on 2026/11/20.
//

import Foundation

struct EditorSymbol: Identifiable {
    let name: String
    let line: Int
    var id: Int { line }

    private static let declaration = try! NSRegularExpression(pattern:
        #"^\s*(?:(?:@(?:interface|implementation|protocol)|%(?:hook|group)|(?:class|struct|enum|namespace|func))\s+([A-Za-z_]\w*)|[-+]\s*\([^)]*\)\s*([A-Za-z_]\w*:?)|(?:[\w:*&<>,]+\s+)+([A-Za-z_]\w*)\s*\([^;]*\)\s*\{)"#)

    static func read(_ source: String) -> [Self] {
        guard source.utf8.count < 500_000 else { return [] }
        return source.components(separatedBy: .newlines).enumerated().compactMap { line, text in
            guard let match = declaration.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = (1...3).compactMap({ Range(match.range(at: $0), in: text) }).first else { return nil }
            return Self(name: String(text[range]), line: line + 1)
        }
    }
}

struct ProjectEntry: Identifiable {
    let path: String
    let name: String
    let children: [ProjectEntry]?
    var id: String { path }

    static func read(_ root: URL, relative: String = "") throws -> [Self] {
        let directory = relative.isEmpty ? root : root.appendingPathComponent(relative, isDirectory: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys,
                                                           options: [.skipsHiddenFiles])
            .compactMap { url in
                let name = url.lastPathComponent
                if relative.isEmpty && name == "packages" { return nil }
                let values = try url.resourceValues(forKeys: Set(keys))
                guard values.isSymbolicLink != true else { return nil }
                let path = relative.isEmpty ? name : relative + "/" + name
                if values.isDirectory == true { return Self(path: path, name: name, children: try read(root, relative: path)) }
                return values.isRegularFile == true ? Self(path: path, name: name, children: nil) : nil
            }.sorted {
                if ($0.children != nil) != ($1.children != nil) { return $0.children != nil }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    var filePaths: [String] { children?.flatMap(\.filePaths) ?? [path] }
}

struct SourceDocument {
    var text: String
    let encoding: String.Encoding

    static func load(_ url: URL) throws -> Self {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? 0) <= 4_000_000 else {
            throw WorkspaceError.message("文件超过编辑器的 4 MB 打开上限。")
        }
        let data = try Data(contentsOf: url)
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let text = String(data: data, encoding: .utf16) {
            return Self(text: text, encoding: .utf16)
        }
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
            throw WorkspaceError.message("此文件不是可编辑的 UTF‑8 或 UTF‑16 文本。")
        }
        return Self(text: text, encoding: .utf8)
    }
}

struct BuildIssue: Identifiable, Hashable {
    let path: String?
    let line: Int?
    let column: Int?
    let level: String
    let message: String
    var id: Self { self }

    var isError: Bool { level.contains("error") }

    private static let located = try! NSRegularExpression(
        pattern: #"^(.+?):([0-9]+)(?::([0-9]+))?:\s*(fatal error|error|warning|note):\s*(.+)$"#)
    private static let general = try! NSRegularExpression(
        pattern: #"^(?:[^:]+:\s*)?(fatal error|error|warning):\s*(.+)$"#)
    private static let ansi = try! NSRegularExpression(pattern: #"\x1B\[[0-?]*[ -/]*[@-~]"#)

    static func read(_ log: String, projectFiles: Set<String>) -> [Self] {
        var seen = Set<Self>()
        return log.split(whereSeparator: \.isNewline).compactMap { row in
            let raw = String(row)
            let text = ansi.stringByReplacingMatches(in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: "")
            let ns = text as NSString
            let range = NSRange(location: 0, length: ns.length)
            let issue: Self
            if let match = located.firstMatch(in: text, range: range) {
                func group(_ i: Int) -> String {
                    let r = match.range(at: i)
                    return r.location == NSNotFound ? "" : ns.substring(with: r)
                }
                var path = group(1)
                if path.hasPrefix("/tmp/theoslab-"), let slash = path.dropFirst(5).firstIndex(of: "/") {
                    path = String(path[path.index(after: slash)...])
                }
                if path.hasPrefix("./") { path.removeFirst(2) }
                let relative = projectFiles.contains(path) ? path : nil
                issue = Self(path: relative, line: Int(group(2)), column: Int(group(3)),
                             level: group(4), message: relative == nil ? "\(path): \(group(5))" : group(5))
            } else if let match = general.firstMatch(in: text, range: range) {
                issue = Self(path: nil, line: nil, column: nil, level: ns.substring(with: match.range(at: 1)),
                             message: ns.substring(with: match.range(at: 2)))
            } else { return nil }
            return seen.insert(issue).inserted ? issue : nil
        }
    }
}
