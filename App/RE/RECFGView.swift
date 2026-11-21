import SwiftUI

/// 控制流图：SwiftUI Canvas 绘制，支持缩放与平移。
struct RECFGView: View {
    @ObservedObject var session: RESession
    let function: REFunction

    @State private var zoom: CGFloat = 1
    @GestureState private var gestureZoom: CGFloat = 1

    private var blocks: [REBasicBlock] { session.cfg(for: function) }
    private var layout: RECFGLayout { Self.layout(blocks: blocks, session: session) }

    var body: some View {
        let layout = layout
        ScrollView([.horizontal, .vertical]) {
            Canvas { context, _ in
                for edge in layout.edges {
                    drawEdge(context, edge, layout: layout)
                }
                for node in layout.nodes {
                    drawNode(context, node, layout: layout)
                }
            }
            .frame(width: layout.canvasWidth * scale, height: layout.canvasHeight * scale)
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle("控制流图")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    zoom = 1
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }.accessibilityLabel("重置缩放")
            }
        }
        .gesture(zoomGesture)
        .overlay(alignment: .bottomTrailing) {
            Text("\(blocks.count) 个基本块 · \(Int(scale * 100))%")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .padding(8)
        }
    }

    private var scale: CGFloat { zoom * gestureZoom }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onEnded { value in
                zoom = min(max(zoom * value, 0.4), 3)
            }
    }

    // MARK: - 绘制

    private func drawNode(_ context: GraphicsContext, _ node: RECFGLayout.Node, layout: RECFGLayout) {
        let rect = CGRect(x: CGFloat(node.x) * scale, y: CGFloat(node.y) * scale,
                          width: CGFloat(node.width) * scale, height: CGFloat(node.height) * scale)
        let shape = RoundedRectangle(cornerRadius: 8 * scale)
        let fill: Color
        if node.block.isEntry {
            fill = Color.blue.opacity(0.10)
        } else if node.block.isReturn {
            fill = Color.green.opacity(0.10)
        } else {
            fill = Color.secondary.opacity(0.08)
        }
        context.fill(shape.path(in: rect), with: .color(fill))
        context.stroke(shape.path(in: rect),
                       with: .color(node.block.isEntry ? .blue : .secondary.opacity(0.7)),
                       lineWidth: node.block.isEntry ? 1.6 : 1)

        // 标题行：块地址。
        let title = REFormat.hex(node.block.start, width: 12)
        context.draw(Text(title)
            .font(.system(size: 10 * scale, design: .monospaced))
            .foregroundColor(.secondary),
            at: CGPoint(x: rect.minX + 10 * scale, y: rect.minY + 12 * scale),
            anchor: .leading)

        // 指令行（最多 4 条）。
        let instructions = session.instructions(for: function)
            .filter { $0.address >= node.block.start && $0.address < node.block.end }
        for (index, insn) in instructions.prefix(4).enumerated() {
            let line = "\(insn.mnemonic) \(insn.operands)"
            context.draw(Text(line)
                .font(.system(size: 9.5 * scale, design: .monospaced))
                .foregroundColor(.primary),
                at: CGPoint(x: rect.minX + 10 * scale,
                            y: rect.minY + (30 + CGFloat(index) * 13) * scale),
                anchor: .leading)
        }
        if instructions.count > 4 {
            context.draw(Text("… 共 \(instructions.count) 条")
                .font(.system(size: 9 * scale, design: .monospaced))
                .foregroundColor(.secondary),
                at: CGPoint(x: rect.minX + 10 * scale,
                            y: rect.minY + CGFloat(node.height) * scale - 10 * scale),
                anchor: .leading)
        }
    }

    private func drawEdge(_ context: GraphicsContext, _ edge: (from: Int, to: Int, dashed: Bool),
                          layout: RECFGLayout) {
        guard edge.from < layout.nodes.count, edge.to < layout.nodes.count else { return }
        let fromNode = layout.nodes[edge.from]
        let toNode = layout.nodes[edge.to]
        let start = CGPoint(x: CGFloat(fromNode.x + fromNode.width / 2) * scale,
                            y: CGFloat(fromNode.y + fromNode.height) * scale)
        let end = CGPoint(x: CGFloat(toNode.x + toNode.width / 2) * scale,
                          y: CGFloat(toNode.y) * scale)
        let midY = (start.y + end.y) / 2
        let path = Path { path in
            path.move(to: start)
            path.addCurve(to: end,
                          control1: CGPoint(x: start.x, y: midY),
                          control2: CGPoint(x: end.x, y: midY))
        }
        let color: Color = edge.dashed ? .orange : .secondary
        let style: StrokeStyle = StrokeStyle(lineWidth: 1.2 * scale,
                                             dash: edge.dashed ? [4 * scale, 3 * scale] : [])
        context.stroke(path, with: .color(color), style: style)
        // 箭头。
        let arrow = Path { path in
            path.move(to: CGPoint(x: end.x - 4 * scale, y: end.y - 8 * scale))
            path.addLine(to: end)
            path.addLine(to: CGPoint(x: end.x + 4 * scale, y: end.y - 8 * scale))
        }
        context.stroke(arrow, with: .color(color), style: style)
    }

    // MARK: - 布局（分层 BFS）

    static func layout(blocks: [REBasicBlock], session: RESession) -> RECFGLayout {
        guard !blocks.isEmpty else {
            return RECFGLayout(nodes: [], edges: [], canvasWidth: 320, canvasHeight: 220)
        }
        let startByAddr = Dictionary(uniqueKeysWithValues: blocks.map { ($0.start, $0) })
        var levelOf: [UInt64: Int] = [:]
        var queue: [UInt64] = []
        // 入口块。
        let entry = blocks.first(where: \.isEntry) ?? blocks[0]
        levelOf[entry.start] = 0
        queue.append(entry.start)
        var cursor = 0
        while cursor < queue.count {
            let current = queue[cursor]
            cursor += 1
            let level = levelOf[current] ?? 0
            for successor in startByAddr[current]?.successors ?? [] {
                if levelOf[successor] == nil, startByAddr[successor] != nil {
                    levelOf[successor] = min(level + 1, 24)
                    queue.append(successor)
                }
            }
        }
        // 没被 BFS 覆盖的块（不可达/间接跳转目标）。
        var maxLevel = levelOf.values.max() ?? 0
        for block in blocks where levelOf[block.start] == nil {
            maxLevel += 1
            levelOf[block.start] = maxLevel
        }

        // 分层排布：同层从左往右。
        var columns: [Int: [UInt64]] = [:]
        for block in blocks {
            let level = levelOf[block.start] ?? 0
            columns[level, default: []].append(block.start)
        }
        let nodeWidth = 200
        let nodeGapX = 40
        let nodeGapY = 46
        var nodes: [RECFGLayout.Node] = []
        var indexByStart: [UInt64: Int] = [:]
        for (level, starts) in columns.sorted(by: { $0.key < $1.key }) {
            for (column, start) in starts.enumerated() {
                guard let block = startByAddr[start] else { continue }
                let instructionCount = 4
                let height = 34 + instructionCount * 13 + (block.isReturn ? 0 : 14)
                indexByStart[start] = nodes.count
                nodes.append(RECFGLayout.Node(
                    block: block,
                    x: column * (nodeWidth + nodeGapX),
                    y: level * (height + nodeGapY) + level * 60,
                    width: nodeWidth,
                    height: height
                ))
            }
        }
        var edges: [(from: Int, to: Int, dashed: Bool)] = []
        for (index, node) in nodes.enumerated() {
            for successor in node.block.successors {
                if let targetIndex = indexByStart[successor] {
                    edges.append((index, targetIndex, false))
                } else {
                    edges.append((index, index, true)) // 自环表示跳出本函数的边。
                }
            }
        }
        let width = Double((columns.values.map(\.count).max() ?? 1) * (nodeWidth + nodeGapX) + nodeGapX)
        let height = Double((levelOf.values.max() ?? 0) * 260 + 120)
        return RECFGLayout(nodes: nodes, edges: edges,
                           canvasWidth: max(width, 320), canvasHeight: max(height, 240))
    }
}
