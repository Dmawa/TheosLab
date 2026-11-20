import SwiftUI

/// 概览页：会话状态、基本信息与各列表入口。
struct REOverviewView: View {
    @ObservedObject var session: RESession

    var body: some View {
        List {
            switch session.phase {
            case .loading:
                Section {
                    HStack { ProgressView(); Text("正在解析二进制…").padding(.leading, 8) }
                }
            case .analyzing:
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { ProgressView(); Text("正在分析函数与交叉引用").padding(.leading, 8) }
                        if !session.progressText.isEmpty {
                            Text(session.progressText)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            case .failed(let message):
                Section {
                    ContentUnavailableCompat(title: "分析失败", text: message,
                                             systemImage: "xmark.octagon")
                }
            case .ready:
                summarySection
                browseSection
                segmentSection
            }
        }
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var summarySection: some View {
        Section("概要") {
            LabeledRow(label: "架构", value: session.binary.arch.title)
            LabeledRow(label: "文件大小", value: REFormat.size(session.binary.fileSize))
            LabeledRow(label: "函数", value: "\(session.functions.count)")
            LabeledRow(label: "字符串", value: "\(session.strings.count)")
            LabeledRow(label: "导入 / 导出", value: "\(session.imports.count) / \(session.exports.count)")
        }
    }

    private var browseSection: some View {
        Section("浏览") {
            NavigationLink {
                REFunctionListView(session: session)
            } label: {
                ImageRow(image: "function", tint: .blue, title: "函数", detail: "\(session.functions.count)")
            }
            NavigationLink {
                RESymbolListView(session: session, kind: .imports)
            } label: {
                ImageRow(image: "arrow.down.circle", tint: .orange, title: "导入", detail: "\(session.imports.count)")
            }
            NavigationLink {
                RESymbolListView(session: session, kind: .exports)
            } label: {
                ImageRow(image: "arrow.up.circle", tint: .green, title: "导出", detail: "\(session.exports.count)")
            }
            NavigationLink {
                REStringsView(session: session)
            } label: {
                ImageRow(image: "text.quote", tint: .purple, title: "字符串", detail: "\(session.strings.count)")
            }
            if !session.dependencies.isEmpty {
                NavigationLink {
                    REDependenciesView(session: session)
                } label: {
                    ImageRow(image: "link", tint: .gray, title: "依赖库", detail: "\(session.dependencies.count)")
                }
            }
        }
    }

    private var segmentSection: some View {
        Section("段") {
            ForEach(session.segments) { segment in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(segment.title).font(.callout.weight(.medium))
                        Spacer()
                        Text(REFormat.size(segment.vmsize)).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("\(REFormat.hex(segment.vmaddr)) · 文件偏移 \(REFormat.hex(segment.fileoff, width: 8))")
                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
            }
            if session.segments.isEmpty {
                Text("没有段信息").foregroundStyle(.secondary)
            }
        }
    }
}

/// 段落里的图标行。
struct ImageRow: View {
    let image: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: image)
                .foregroundStyle(tint)
                .frame(width: 24)
            Text(title)
            Spacer()
            Text(detail).foregroundStyle(.secondary)
        }
    }
}

struct LabeledRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
    }
}

/// 导入/导出列表。
struct RESymbolListView: View {
    enum Kind { case imports, exports }

    @ObservedObject var session: RESession
    let kind: Kind
    @State private var query = ""

    private var rows: [(name: String, addr: UInt64?)] {
        let base: [(String, UInt64?)]
        switch kind {
        case .imports:
            base = session.imports.map { ($0.name, Optional<UInt64>.none) }
        case .exports:
            base = session.exports.map { ($0.name, $0.addr) }
        }
        guard !query.isEmpty else { return base }
        return base.filter { $0.0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List(rows, id: \.name) { row in
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).font(.system(.footnote, design: .monospaced))
                if let addr = row.addr {
                    Text(REFormat.hex(addr)).font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
            }
        }
        .searchable(text: $query, prompt: kind == .imports ? "搜索导入符号" : "搜索导出符号")
        .navigationTitle(kind == .imports ? "导入" : "导出")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 字符串列表。
struct REStringsView: View {
    @ObservedObject var session: RESession
    @State private var query = ""
    @State private var copied: String?

    private var rows: [REString] {
        guard !query.isEmpty else { return session.strings }
        return session.strings.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            if let copied {
                Text("已复制 · \(copied)")
                    .font(.caption).foregroundStyle(.green)
            }
            ForEach(rows.prefix(4000)) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.text).font(.system(.footnote, design: .monospaced)).lineLimit(3)
                    Text(REFormat.hex(entry.addr)).font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
                .onTapGesture {
                    UIPasteboard.general.string = entry.text
                    copied = entry.text
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = nil }
                }
            }
            if rows.count > 4000 {
                Text("仅显示前 4000 条，请用搜索缩小范围。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .searchable(text: $query, prompt: "搜索字符串")
        .navigationTitle("字符串")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 依赖库列表。
struct REDependenciesView: View {
    @ObservedObject var session: RESession

    var body: some View {
        List(session.dependencies, id: \.self) { name in
            Text(name).font(.system(.footnote, design: .monospaced))
        }
        .navigationTitle("依赖库")
        .navigationBarTitleDisplayMode(.inline)
    }
}
