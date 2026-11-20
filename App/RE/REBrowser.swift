import SwiftUI

/// 反汇编模块入口：自适应 iPhone 导航栈 / iPad 三栏。
struct REBrowser: View {
    let url: URL

    @Environment(\.horizontalSizeClass) private var width
    @Environment(\.dismiss) private var dismiss
    @State private var holder: Result<RESession, Error>?
    @State private var selectedFunction: REFunction?
    @State private var selectedAddress: UInt64?

    var body: some View {
        Group {
            if let holder {
                switch holder {
                case .success(let session):
                    if width == .regular {
                        iPadLayout(session)
                    } else {
                        iPhoneLayout(session)
                    }
                case .failure(let error):
                    ContentUnavailableCompat(
                        title: "无法打开",
                        text: error.localizedDescription,
                        systemImage: "exclamationmark.triangle"
                    )
                }
            } else {
                ProgressView("正在解析二进制…")
            }
        }
        .background(Color(uiColor: .systemBackground))
        .task {
            if holder == nil {
                holder = Result { try RESession(url: url) }
                if case .success(let session) = holder {
                    session.start()
                }
            }
        }
    }

    // MARK: - iPhone：IDA 式导航栈

    private func iPhoneLayout(_ session: RESession) -> some View {
        NavigationStack {
            REOverviewView(session: session)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { dismiss() }
                    }
                }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - iPad：三栏（函数 | 反汇编 | 详情）

    private func iPadLayout(_ session: RESession) -> some View {
        NavigationStack {
            HStack(spacing: 0) {
                REFunctionListView(session: session) { function in
                    selectedFunction = function
                }
                .frame(width: 300)
                Divider()
                Group {
                    if let selectedFunction {
                        REDisassemblyView(session: session, function: selectedFunction,
                                          selection: $selectedAddress)
                    } else {
                        REOverviewView(session: session)
                    }
                }
                .frame(maxWidth: .infinity)
                Divider()
                REDetailPanel(session: session, function: selectedFunction,
                              address: selectedAddress)
                    .frame(width: 320)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .navigationBarHidden(true)
        }
        .navigationViewStyle(.stack)
    }
}

/// iOS 15 兼容的占位视图（ContentUnavailableView 是 iOS 17+）。
struct ContentUnavailableCompat: View {
    let title: String
    let text: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold))
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
