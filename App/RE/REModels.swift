import Foundation

// MARK: - 基础值类型（反汇编模块共用）

/// 二进制架构。
enum REArch: String, Sendable {
    case arm64
    case arm64e
    case arm
    case unknown

    var title: String { rawValue }

    var is64Bit: Bool {
        self == .arm64 || self == .arm64e
    }
}

/// Mach-O 段。
struct RESegment: Identifiable, Sendable {
    let name: String
    let vmaddr: UInt64
    let vmsize: UInt64
    let fileoff: UInt64
    let filesize: UInt64
    let maxProtection: Int
    let initialProtection: Int

    var id: String { name }

    var title: String { "__\(name)" }
}

/// Mach-O 节。
struct RESectionInfo: Identifiable, Sendable {
    let segment: String
    let name: String
    let addr: UInt64
    let size: UInt64
    let fileOffset: Int

    var id: String { segment + "," + name }

    var title: String { "__\(segment),__\(name)" }
}

/// 符号。
struct RESymbol: Identifiable, Sendable {
    let addr: UInt64
    let name: String
    let isDefined: Bool

    var id: UInt64 { addr }
}

/// 导出符号。
struct REExport: Identifiable, Sendable {
    let addr: UInt64
    let name: String

    var id: UInt64 { addr }
}

/// 字符串表项。
struct REString: Identifiable, Sendable {
    let addr: UInt64
    let text: String

    var id: UInt64 { addr }
}

/// 识别出的函数。
struct REFunction: Identifiable, Sendable, Hashable {
    let addr: UInt64
    var name: String
    var end: UInt64
    let fromSymbols: Bool

    var id: UInt64 { addr }

    var size: UInt64 { end > addr ? end - addr : 0 }
}

/// 单条反汇编指令。
struct REInstruction: Sendable, Identifiable {
    let address: UInt64
    let size: UInt16
    let bytes: [UInt8]
    let mnemonic: String
    let operands: String

    var id: UInt64 { address }

    var end: UInt64 { address + UInt64(size) }

    var text: String {
        operands.isEmpty ? mnemonic : mnemonic + " " + operands
    }
}

/// 交叉引用类型。
enum REXrefKind: String, Sendable {
    case call
    case jump
    case data
    case string

    var title: String {
        switch self {
        case .call: return "调用"
        case .jump: return "跳转"
        case .data: return "数据"
        case .string: return "字符串"
        }
    }
}

/// 交叉引用。
struct REXref: Identifiable, Sendable, Hashable {
    let from: UInt64
    let to: UInt64
    let kind: REXrefKind

    var id: UInt64 { from &* 31 &+ to }
}

/// 基本块。
struct REBasicBlock: Identifiable, Sendable {
    let start: UInt64
    var end: UInt64
    var successors: [UInt64]
    var isEntry: Bool
    var isReturn: Bool

    var id: UInt64 { start }
}

/// CFG 布局后的节点位置。
struct RECFGLayout {
    struct Node {
        let block: REBasicBlock
        let x: Int
        let y: Int
        let width: Int
        let height: Int
    }
    let nodes: [Node]
    let edges: [(from: Int, to: Int, dashed: Bool)]
    let canvasWidth: Double
    let canvasHeight: Double
}

/// 反汇编模块统一错误。
enum REError: LocalizedError {
    case notMachO
    case unsupported(String)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .notMachO: return "这不是一个 Mach-O 二进制文件。"
        case .unsupported(let what): return "暂不支持 · \(what)"
        case .message(let text): return text
        }
    }
}

/// 十六进制格式化助手。
enum REFormat {
    static func hex(_ value: UInt64, width: Int = 16) -> String {
        let digits = String(value, radix: 16).lowercased()
        return "0x" + String(repeating: "0", count: max(0, width - digits.count)) + digits
    }

    static func hex(_ value: Int, width: Int = 16) -> String {
        hex(UInt64(bitPattern: Int64(value)), width: width)
    }

    static func size(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .binary)
    }
}
