import SwiftUI

/// 反编译伪代码视图：r2ghidra（pdg）→ 内置 pdc 降级 → 错误提示。
struct REPseudoView: View {
    @ObservedObject var session: RESession
    let function: REFunction

    @State private var state: LoadState = .loading
    @State private var copied = false

    enum LoadState {
        case loading
        case loaded(String, source: String)
        case failed(String)
    }

    var body: some View {
        Group {
            switch state {
            case .loading:
                VStack(spacing: 10) {
                    ProgressView()
                    Text("正在反编译 \(function.name)…")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("首次反编译需要把二进制传入内嵌 Linux 运行 r2ghidra，可能需要十几秒。")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let text, let source):
                ScrollView {
                    Text(text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button {
                            UIPasteboard.general.string = text
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                        } label: {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        }.accessibilityLabel("复制伪代码")
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    Text("来源 · \(source)")
                        .font(.caption2).foregroundStyle(.secondary)
                        .padding(6)
                        .frame(maxWidth: .infinity)
                        .background(Color(uiColor: .secondarySystemBackground))
                }
            case .failed(let message):
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("反编译失败")
                            .font(.headline)
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text("可以改用反汇编视图阅读代码，或在 Mac 侧重新生成包含 r2ghidra 的工具链后重试。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle("伪代码")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await load()
        }
    }

    private func load() async {
        if !session.isGuestAvailable() {
            state = .failed("来宾 Linux 中没有安装 radare2/r2ghidra。需要用包含反编译器的工具链重新打包 App（Scripts/prepare.sh）。")
            return
        }
        do {
            let text = try await session.decompile(function)
            state = .loaded(text, source: "r2ghidra · 已缓存，再次打开零等待")
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
