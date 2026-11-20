import Foundation

/// 原生分析器：函数识别、交叉引用提取、控制流图构建。
/// 全部基于 Capstone 线性/递归下降解码，不依赖来宾 Linux。
final class REAnalyzer {
    private let binary: REBinary
    private let engine: RECapstoneEngine
    private let stringAddresses: Set<UInt64>

    struct ScanResult {
        var functions: [REFunction] = []
        var xrefs: [REXref] = []
    }

    init(binary: REBinary, strings: [REString]) throws {
        self.binary = binary
        self.engine = try RECapstoneEngine(arch: binary.arch)
        self.stringAddresses = Set(strings.map(\.addr))
    }

    // MARK: - 函数识别

    /// 全量扫描。后台线程执行，progress 回调 0...1。
    func scan(progress: @escaping (Double, String) -> Void) throws -> ScanResult {
        var result = ScanResult()
        guard let text = binary.textSection else {
            throw REError.message("二进制中没有 __text 节，无法分析代码。")
        }
        let textStart = text.addr
        let textEnd = text.addr + text.size

        // 1. 收集种子：function starts、导出、符号。
        var seeds: [UInt64] = []
        var seedIsSymbol: [UInt64: Bool] = [:]
        if let starts = binary.machO.functionStarts {
            let base = UInt64(starts.functionStartBase)
            for start in starts {
                let addr = base + UInt64(start.offset)
                if addr >= textStart, addr < textEnd {
                    seeds.append(addr)
                    seedIsSymbol[addr] = true
                }
            }
        }
        for entry in binary.exports where entry.addr >= textStart && entry.addr < textEnd {
            if seedIsSymbol[entry.addr] == nil {
                seeds.append(entry.addr)
                seedIsSymbol[entry.addr] = true
            }
        }
        for symbol in binary.symbols where symbol.addr >= textStart && symbol.addr < textEnd {
            if seedIsSymbol[symbol.addr] == nil {
                seeds.append(symbol.addr)
                seedIsSymbol[symbol.addr] = true
            }
        }

        // 2. 全部剥离时退化为序言启发式。
        if seeds.isEmpty {
            seeds = heuristicPrologueSeeds(textStart: textStart, textEnd: textEnd)
        }

        // 3. 工作表递归下降。
        var worklist = seeds.sorted()
        var seen = Set(seeds)
        var sortedBoundaries = seeds.sorted()
        var nameByAddr: [UInt64: String] = [:]
        for symbol in binary.symbols where symbol.addr >= textStart && symbol.addr < textEnd {
            if nameByAddr[symbol.addr] == nil { nameByAddr[symbol.addr] = symbol.name }
        }
        for entry in binary.exports {
            if nameByAddr[entry.addr] == nil { nameByAddr[entry.addr] = entry.name }
        }

        var xrefs: [REXref] = []
        var adrpPages: [String: UInt64] = [:]
        let maxFunctions = 100_000

        while !worklist.isEmpty, result.functions.count < maxFunctions {
            let seed = worklist.removeFirst()
            let boundary = nextBoundary(in: sortedBoundaries, above: seed) ?? textEnd
            let cap = min(Int(boundary - seed), 0x40_000)
            guard cap > 0 else { continue }

            let instructions = decode(from: seed, maxBytes: cap)
            guard let last = instructions.last else { continue }
            let functionEnd = last.end

            var index = 0
            while index < instructions.count {
                let insn = instructions[index]
                index += 1
                switch insn.mnemonic {
                case "bl":
                    if let target = Self.target(of: insn), target >= textStart, target < textEnd {
                        xrefs.append(REXref(from: insn.address, to: target, kind: .call))
                        if seen.insert(target).inserted {
                            worklist.append(target)
                            let position = (sortedBoundaries.firstIndex { $0 > target }) ?? sortedBoundaries.count
                            sortedBoundaries.insert(target, at: position)
                        }
                    }
                case "adrp":
                    if let (reg, page) = Self.registerValue(of: insn) {
                        adrpPages[reg] = page
                    }
                case "add":
                    if let (reg, page) = adrpPage(for: insn) {
                        if let base = page, let offset = Self.lastImmediate(of: insn) {
                            let target = base + offset
                            let kind: REXrefKind = stringAddresses.contains(target) ? .string : .data
                            xrefs.append(REXref(from: insn.address, to: target, kind: kind))
                        }
                        adrpPages[reg] = nil
                    }
                case "adr":
                    if let (_, value) = Self.registerValue(of: insn) {
                        let kind: REXrefKind = stringAddresses.contains(value) ? .string : .data
                        xrefs.append(REXref(from: insn.address, to: value, kind: kind))
                    }
                case "ldr":
                    // ldr x8, #0x1f234 —— 字面量池引用（无寄存器间接寻址形式）。
                    let parts = insn.operands.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    if parts.count == 2, !insn.operands.contains("["),
                       parts[1].hasPrefix("#0x"),
                       let target = UInt64(parts[1].dropFirst(3), radix: 16) {
                        let kind: REXrefKind = stringAddresses.contains(target) ? .string : .data
                        xrefs.append(REXref(from: insn.address, to: target, kind: kind))
                    }
                default:
                    break
                }
            }

            let name = nameByAddr[seed] ?? "sub_" + String(seed, radix: 16)
            result.functions.append(REFunction(addr: seed, name: name, end: functionEnd,
                                               fromSymbols: nameByAddr[seed] != nil))
            progress(Double(result.functions.count) / Double(max(seeds.count, 1)), name)
        }

        result.functions.sort { $0.addr < $1.addr }
        result.xrefs = Self.deduplicated(xrefs)
        return result
    }

    /// 已排序边界数组中 addr 之上最近的边界（二分）。
    private func nextBoundary(in sorted: [UInt64], above addr: UInt64) -> UInt64? {
        var low = 0
        var high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] <= addr { low = mid + 1 } else { high = mid }
        }
        return low < sorted.count ? sorted[low] : nil
    }

    private func decode(from addr: UInt64, maxBytes: Int) -> [REInstruction] {
        guard let chunk = binary.bytes(atVMAddr: addr, length: maxBytes) else { return [] }
        return engine.disassemble(chunk, at: addr)
    }

    /// 剥离二进制的序言启发式：pacibsp（arm64e）/ stp x29, x30（arm64）。
    private func heuristicPrologueSeeds(textStart: UInt64, textEnd: UInt64) -> [UInt64] {
        guard let size = Int(exactly: textEnd - textStart),
              let chunk = binary.bytes(atVMAddr: textStart, length: size) else { return [] }
        var seeds: [UInt64] = []
        chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset + 4 <= raw.count {
                let word = raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                // pacibsp = 0xd503237f；stp x29, x30, [sp, #-N]! 形如 0xa9xx7bfd。
                if word == 0xd503_237f || (word & 0xffe0_0fff) == 0xa980_0bfd {
                    seeds.append(textStart + UInt64(offset))
                }
                offset += 4
            }
        }
        return seeds
    }

    // MARK: - 控制流图

    func buildCFG(function: REFunction) -> [REBasicBlock] {
        let instructions = decode(from: function.addr, maxBytes: Int(function.size))
        guard !instructions.isEmpty else { return [] }
        let functionEnd = function.end

        var blockStarts: Set<UInt64> = [function.addr]
        var successorsByAddr: [UInt64: [UInt64]] = [:]
        var isReturnAddr: Set<UInt64> = []

        for (index, insn) in instructions.enumerated() {
            let next = insn.end
            let nextAddr: UInt64? = next < functionEnd ? next : nil
            switch insn.mnemonic {
            case "b":
                if let target = Self.target(of: insn) {
                    successorsByAddr[insn.address] = [target]
                    blockStarts.insert(target)
                } else {
                    successorsByAddr[insn.address] = []
                }
            case "ret":
                successorsByAddr[insn.address] = []
                isReturnAddr.insert(insn.address)
            case "br", "blr", "braa", "brab", "braaz", "brabz":
                successorsByAddr[insn.address] = []
            case "bl":
                successorsByAddr[insn.address] = nextAddr.map { [$0] } ?? []
            case "cbz", "cbnz", "tbz", "tbnz":
                var targets: [UInt64] = []
                if let target = Self.target(of: insn) { targets.append(target); blockStarts.insert(target) }
                if let nextAddr { targets.append(nextAddr) }
                successorsByAddr[insn.address] = targets
            default:
                if insn.mnemonic.hasPrefix("b.") { // b.eq / b.ne 等条件跳转
                    var targets: [UInt64] = []
                    if let target = Self.target(of: insn) { targets.append(target); blockStarts.insert(target) }
                    if let nextAddr { targets.append(nextAddr) }
                    successorsByAddr[insn.address] = targets
                } else {
                    successorsByAddr[insn.address] = nextAddr.map { [$0] } ?? []
                }
            }
        }

        let starts = blockStarts.filter { $0 >= function.addr && $0 < functionEnd }.sorted()
        var blocks: [REBasicBlock] = []
        for (position, start) in starts.enumerated() {
            let end = position + 1 < starts.count ? starts[position + 1] : functionEnd
            let blockInstructions = instructions.filter { $0.address >= start && $0.address < end }
            guard let last = blockInstructions.last else { continue }
            var successors = successorsByAddr[last.address] ?? []
            successors = successors.filter { $0 >= function.addr && $0 < functionEnd }
            blocks.append(REBasicBlock(
                start: start,
                end: end,
                successors: Array(Set(successors)).sorted(),
                isEntry: start == function.addr,
                isReturn: isReturnAddr.contains(last.address)
            ))
        }
        return blocks
    }

    // MARK: - 指令解析助手

    static func target(of insn: REInstruction) -> UInt64? {
        guard let token = insn.operands.split(separator: ",").last,
              token.trimmingCharacters(in: .whitespaces).hasPrefix("#0x") else { return nil }
        return UInt64(token.trimmingCharacters(in: .whitespaces).dropFirst(3), radix: 16)
    }

    private static func lastImmediate(of insn: REInstruction) -> UInt64? {
        for token in insn.operands.split(separator: ",") {
            let trimmed = token.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#0x") { return UInt64(trimmed.dropFirst(3), radix: 16) }
            if trimmed.hasPrefix("#"), let value = UInt64(trimmed.dropFirst(1)) { return value }
        }
        return nil
    }

    /// "x8, #0x1f000" → ("x8", 0x1f000)
    private static func registerValue(of insn: REInstruction) -> (String, UInt64)? {
        let parts = insn.operands.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, parts[1].hasPrefix("#0x"),
              let value = UInt64(parts[1].dropFirst(3), radix: 16) else { return nil }
        return (parts[0], value)
    }

    /// add x8, x8, #8：确认目标寄存器与源寄存器是 adrp 记录过的同一个。
    private func adrpPage(for insn: REInstruction) -> (String, UInt64?)? {
        let parts = insn.operands.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 3, parts[1] == parts[0] else { return nil }
        return (parts[0], adrpPages[parts[0]])
    }

    static func deduplicated(_ xrefs: [REXref]) -> [REXref] {
        var seen = Set<REXref>()
        var result: [REXref] = []
        for xref in xrefs where seen.insert(xref).inserted {
            result.append(xref)
        }
        return result
    }
}
