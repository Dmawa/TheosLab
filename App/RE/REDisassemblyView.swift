import SwiftUI
import UIKit

/// 单个函数的反汇编视图：UICollectionView 虚拟化 + 指令着色 + 分支标注。
struct REDisassemblyView: View {
    @ObservedObject var session: RESession
    let function: REFunction
    @Binding var selection: UInt64?

    init(session: RESession, function: REFunction, selection: Binding<UInt64?>? = nil) {
        self.session = session
        self.function = function
        self._selection = selection ?? Binding(get: { nil }, set: { _ in })
    }

    @State private var editSheet = false
    @State private var draftName = ""
    @State private var draftComment = ""

    var body: some View {
        let instructions = session.instructions(for: function)
        let targets = Self.branchTargets(in: instructions)
        VStack(spacing: 0) {
            header(instructions)
            Divider()
            DisassemblyCollection(instructions: instructions,
                                  session: session,
                                  targets: targets,
                                  selection: selection ?? function.addr) { address in
                selection = address
            }
        }
        .navigationTitle(function.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                NavigationLink {
                    REPseudoView(session: session, function: function)
                } label: {
                    Image(systemName: "f.cursive")
                }.accessibilityLabel("反编译伪代码")
                NavigationLink {
                    RECFGView(session: session, function: function)
                } label: {
                    Image(systemName: "flowchart.fill")
                }.accessibilityLabel("控制流图")
                NavigationLink {
                    REXrefsView(session: session, function: function)
                } label: {
                    Image(systemName: "arrow.triangle.branch")
                }.accessibilityLabel("交叉引用")
                Button {
                    draftName = function.name
                    draftComment = session.comment(addr: function.addr) ?? ""
                    editSheet = true
                } label: {
                    Image(systemName: "pencil.and.outline")
                }.accessibilityLabel("重命名与注释")
            }
        }
        .sheet(isPresented: $editSheet) {
            REEditSheet(session: session, function: function,
                        name: $draftName, comment: $draftComment)
        }
    }

    private func header(_ instructions: [REInstruction]) -> some View {
        HStack(spacing: 8) {
            Text(REFormat.hex(function.addr))
            Text(REFormat.size(function.size))
            Spacer()
            Text("\(instructions.count) 条指令")
        }
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    /// 分支地址表：指令地址 → 跳转目标。
    static func branchTargets(in instructions: [REInstruction]) -> [UInt64: UInt64] {
        var map: [UInt64: UInt64] = [:]
        for insn in instructions {
            let isBranch = ["b", "bl", "cbz", "cbnz", "tbz", "tbnz"].contains(insn.mnemonic)
                || insn.mnemonic.hasPrefix("b.")
            if isBranch, let target = REAnalyzer.target(of: insn) {
                map[insn.address] = target
            }
        }
        return map
    }
}

/// 重命名与注释编辑页。
struct REEditSheet: View {
    @ObservedObject var session: RESession
    let function: REFunction
    @Binding var name: String
    @Binding var comment: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section("函数名") {
                    TextField("sub_xxxx", text: $name)
                        .font(.system(.body, design: .monospaced))
                }
                Section("注释") {
                    TextField("备注（可空）", text: $comment)
                }
            }
            .navigationTitle("编辑符号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmedName.isEmpty, trimmedName != function.name {
                            session.rename(function, to: trimmedName)
                        }
                        let trimmedComment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
                        session.setComment(addr: function.addr,
                                           text: trimmedComment.isEmpty ? nil : trimmedComment)
                        dismiss()
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - UICollectionView 实现

struct DisassemblyCollection: UIViewRepresentable {
    let instructions: [REInstruction]
    let session: RESession
    let targets: [UInt64: UInt64]
    let selection: UInt64
    let onSelect: (UInt64) -> Void

    func makeUIView(context: Context) -> UICollectionView {
        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        layout.scrollDirection = .vertical
        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.register(InsnCell.self, forCellWithReuseIdentifier: InsnCell.reuseID)
        view.dataSource = context.coordinator
        view.delegate = context.coordinator
        view.backgroundColor = .systemBackground
        view.showsVerticalScrollIndicator = true
        return view
    }

    func updateUIView(_ view: UICollectionView, context: Context) {
        let coordinator = context.coordinator
        let changed = coordinator.instructions.first?.address != instructions.first?.address
            || coordinator.instructions.count != instructions.count
        coordinator.instructions = instructions
        coordinator.targets = targets
        coordinator.selection = selection
        if changed {
            view.reloadData()
            coordinator.measureWidthIfNeeded()
            view.collectionViewLayout.invalidateLayout()
            if let index = instructions.firstIndex(where: { $0.address == selection }),
               !instructions.isEmpty {
                DispatchQueue.main.async {
                    view.scrollToItem(at: IndexPath(item: index, section: 0),
                                      at: .centeredVertically, animated: false)
                }
            }
        } else {
            view.reloadItems(at: view.indexPathsForVisibleItems)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UICollectionViewDataSource,
                             UICollectionViewDelegateFlowLayout {
        var instructions: [REInstruction]
        var targets: [UInt64: UInt64]
        var selection: UInt64
        var parent: DisassemblyCollection
        private var contentWidth: CGFloat = 0

        init(_ parent: DisassemblyCollection) {
            self.instructions = parent.instructions
            self.targets = parent.targets
            self.selection = parent.selection
            self.parent = parent
        }

        func collectionView(_ collectionView: UICollectionView,
                            numberOfItemsInSection section: Int) -> Int {
            instructions.count
        }

        func collectionView(_ collectionView: UICollectionView,
                            cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: InsnCell.reuseID,
                                                          for: indexPath) as! InsnCell
            let insn = instructions[indexPath.item]
            let annotation = annotation(for: insn)
            cell.apply(attributed: Self.attributed(insn, annotation: annotation),
                       selected: insn.address == selection)
            return cell
        }

        func collectionView(_ collectionView: UICollectionView,
                            didSelectItemAt indexPath: IndexPath) {
            parent.onSelect(instructions[indexPath.item].address)
        }

        func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
                            sizeForItemAt indexPath: IndexPath) -> CGSize {
            let width = collectionView.bounds.width
            return CGSize(width: max(width, contentWidth), height: 22)
        }

        func annotation(for insn: REInstruction) -> (text: String, isTarget: Bool)? {
            if let target = targets[insn.address] {
                return ("→ " + parent.session.displayName(for: target), true)
            }
            return nil
        }

        static let font = UIFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        static let addressAttributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: UIColor.tertiaryLabel
        ]
        static let bytesAttributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: UIColor.quaternaryLabel
        ]
        static let mnemonicAttributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: UIColor.systemBlue
        ]
        static let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: UIColor.label
        ]
        static let numberAttributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: UIColor.systemMint
        ]
        static let targetAttributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: UIColor.systemGreen
        ]
        static let commentAttributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: UIColor.systemOrange
        ]

        static func attributed(_ insn: REInstruction,
                               annotation: (text: String, isTarget: Bool)?) -> NSAttributedString {
            let text = NSMutableAttributedString()
            text.append(NSAttributedString(string: REFormat.hex(insn.address, width: 12),
                                           attributes: addressAttributes))
            let hex = insn.bytes.prefix(4).map { String(format: "%02x", $0) }.joined(separator: " ")
            text.append(NSAttributedString(string: "  " + hex.padding(toLength: 11, withPad: " ", startingAt: 0) + "  ",
                                           attributes: bytesAttributes))
            text.append(NSAttributedString(string: insn.mnemonic,
                                           attributes: mnemonicAttributes))
            text.append(NSAttributedString(string: " ", attributes: labelAttributes))
            for token in insn.operands.split(separator: " ", omittingEmptySubsequences: true) {
                let string = String(token) + " "
                let color: [NSAttributedString.Key: Any]
                if token.hasPrefix("#") || token.hasPrefix("0x") {
                    color = numberAttributes
                } else {
                    color = labelAttributes
                }
                text.append(NSAttributedString(string: string, attributes: color))
            }
            if let annotation {
                text.append(NSAttributedString(string: " " + annotation.text,
                                               attributes: targetAttributes))
            }
            return text
        }

        /// 估算内容宽度（用最长行近似，只测量一次）。
        func measureWidthIfNeeded() {
            guard contentWidth == 0, let longest = instructions.max(by: {
                $0.mnemonic.count + $0.operands.count < $1.mnemonic.count + $1.operands.count
            }) else { return }
            let size = Self.attributed(longest, annotation: annotation(for: longest)).size()
            contentWidth = min(size.width + 24, 1600)
        }
    }
}

/// 指令单元格。
final class InsnCell: UICollectionViewCell {
    static let reuseID = "insn"
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.numberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(greaterThanOrEqualTo: contentView.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])
        selectedBackgroundView = UIView()
        selectedBackgroundView?.backgroundColor = UIColor.systemFill
    }

    required init?(coder: NSCoder) {
        fatalError("unsupported")
    }

    func apply(attributed: NSAttributedString, selected: Bool) {
        label.attributedText = attributed
        contentView.backgroundColor = selected ? UIColor.systemFill.withAlphaComponent(0.55) : .clear
    }
}
