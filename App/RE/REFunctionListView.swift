import SwiftUI

/// 函数列表：iPhone 上点击进入反汇编，iPad 上用于左栏选择。
struct REFunctionListView: View {
    @ObservedObject var session: RESession
    var onPick: ((REFunction) -> Void)?

    enum Sort: String, CaseIterable {
        case address = "地址"
        case size = "大小"
        case name = "名称"
    }

    @State private var query = ""
    @State private var sort: Sort = .address

    private var rows: [REFunction] {
        var base = session.functions
        if !query.isEmpty {
            base = base.filter { $0.name.localizedCaseInsensitiveContains(query) }
                + base.filter { REFormat.hex($0.addr).contains(query.lowercased()) && !$0.name.localizedCaseInsensitiveContains(query) }
        }
        switch sort {
        case .address: base.sort { $0.addr < $1.addr }
        case .size: base.sort { $0.size > $1.size }
        case .name: base.sort { $0.name < $1.name }
        }
        return base
    }

    var body: some View {
        Group {
            if session.functions.isEmpty, session.phase == .ready {
                ContentUnavailableCompat(title: "没有函数", text: "该二进制中未识别出函数。",
                                         systemImage: "function")
            } else {
                list
            }
        }
        .searchable(text: $query, prompt: "搜索函数名或地址")
        .navigationTitle("函数 · \(session.functions.count)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(Sort.allCases, id: \.self) { mode in
                        Button {
                            sort = mode
                        } label: {
                            if sort == mode {
                                Label(mode.rawValue, systemImage: "checkmark")
                            } else {
                                Text(mode.rawValue)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
            }
        }
    }

    private var list: some View {
        List(rows) { function in
            Group {
                if let onPick {
                    Button { onPick(function) } label: { row(function) }
                        .buttonStyle(.plain)
                } else {
                    NavigationLink {
                        REDisassemblyView(session: session, function: function)
                    } label: {
                        row(function)
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private func row(_ function: REFunction) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(function.name)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
            HStack(spacing: 10) {
                Text(REFormat.hex(function.addr))
                Text(REFormat.size(function.size))
                if !function.fromSymbols {
                    Text("推断").foregroundStyle(.orange)
                }
            }
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
    }
}
