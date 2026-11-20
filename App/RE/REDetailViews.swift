import SwiftUI

/// 交叉引用视图：双向列表，点击跳转到引用处。
struct REXrefsView: View {
    @ObservedObject var session: RESession
    let function: REFunction

    private var xrefsTo: [REXref] { session.xrefs(to: function.addr) }
    private var xrefsFrom: [REXref] { session.xrefs(from: function.addr) }

    var body: some View {
        List {
            Section("引用到 \(function.name) · \(xrefsTo.count)") {
                ForEach(xrefsTo) { xref in
                    XrefRow(xref: xref, session: session)
                }
                if xrefsTo.isEmpty {
                    Text("没有发现引用。").foregroundStyle(.secondary)
                }
            }
            Section("从 \(function.name) 发出 · \(xrefsFrom.count)") {
                ForEach(xrefsFrom) { xref in
                    XrefRow(xref: xref, session: session)
                }
                if xrefsFrom.isEmpty {
                    Text("没有引用其他位置。").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("交叉引用")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct XrefRow: View {
    let xref: REXref
    let session: RESession

    var body: some View {
        NavigationLink {
            destination
        } label: {
            HStack(spacing: 10) {
                Text(xref.kind.title)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(badgeColor.opacity(0.18))
                    .foregroundStyle(badgeColor)
                    .clipShape(Capsule())
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayName(for: xref.kind == .call || xref.kind == .jump ? xref.to : xref.from))
                        .font(.system(.footnote, design: .monospaced)).lineLimit(1)
                    Text(REFormat.hex(xref.kind == .call || xref.kind == .jump ? xref.to : xref.from))
                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var destination: some View {
        Group {
            if let target = xref.kind == .call || xref.kind == .jump ? session.function(containing: xref.to) : session.function(containing: xref.from) {
                REDisassemblyView(session: session, function: target)
            } else {
                // 非代码位置：以 64 字节窗口查看。
                let addr = xref.kind == .call || xref.kind == .jump ? xref.to : xref.from
                REDisassemblyView(session: session, function: REFunction(
                    addr: addr, name: session.displayName(for: addr),
                    end: addr + 64, fromSymbols: false))
            }
        }
    }

    private var badgeColor: Color {
        switch xref.kind {
        case .call: return .blue
        case .jump: return .purple
        case .data: return .orange
        case .string: return .green
        }
    }
}

/// 十六进制视图。
struct REHexView: View {
    @ObservedObject var session: RESession
    let start: UInt64
    var length: Int = 512

    private struct Row: Identifiable {
        let address: UInt64
        let bytes: ArraySlice<UInt8>
        var id: UInt64 { address }
    }

    private var rows: [Row] {
        let data = session.bytes(at: start, length: length)
        let array = [UInt8](data)
        return stride(from: 0, to: array.count, by: 16).map { offset in
            Row(address: start + UInt64(offset),
                bytes: array[offset..<min(offset + 16, array.count)])
        }
    }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(rows) { row in
                    hexRow(row)
                }
            }
            .padding(12)
        }
        .font(.system(size: 12, design: .monospaced))
        .navigationTitle("十六进制")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func hexRow(_ row: Row) -> some View {
        HStack(spacing: 10) {
            Text(REFormat.hex(row.address, width: 12)).foregroundStyle(.secondary)
            Text(row.bytes.map { String(format: "%02x", $0) }.joined(separator: " "))
            Text(ascii(of: row.bytes)).foregroundStyle(.tertiary)
        }
    }

    private func ascii(of bytes: ArraySlice<UInt8>) -> String {
        String(bytes.map { (0x20...0x7E).contains($0) ? Character(UnicodeScalar($0)) : "." })
    }
}

/// iPad 右侧详情栏：当前选中地址信息 + 交叉引用 + 十六进制。
struct REDetailPanel: View {
    @ObservedObject var session: RESession
    let function: REFunction?
    let address: UInt64?

    var body: some View {
        List {
            Section("当前") {
                if let address {
                    LabeledRow(label: "地址", value: REFormat.hex(address))
                    LabeledRow(label: "符号", value: session.displayName(for: address))
                    if let function = session.function(containing: address) {
                        LabeledRow(label: "所属函数", value: function.name)
                    }
                } else {
                    Text("在反汇编中点击一条指令").foregroundStyle(.secondary)
                }
            }
            if let function {
                Section("函数交叉引用 · \(session.xrefs(to: function.addr).count)") {
                    ForEach(session.xrefs(to: function.addr).prefix(30)) { xref in
                        HStack {
                            Text(xref.kind.title).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(REFormat.hex(xref.from)).font(.caption.monospaced())
                        }
                    }
                }
                Section("函数头十六进制") {
                    Text(hexPreview(function))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("详情")
    }

    private func hexPreview(_ function: REFunction) -> String {
        let data = session.bytes(at: function.addr, length: 64)
        let lines = stride(from: 0, to: data.count, by: 16).map { offset -> String in
            let slice = data[data.startIndex + offset..<min(data.startIndex + offset + 16, data.endIndex)]
            return REFormat.hex(function.addr + UInt64(offset), width: 12) + "  "
                + slice.map { String(format: "%02x", $0) }.joined(separator: " ")
        }
        return lines.joined(separator: "\n")
    }
}
