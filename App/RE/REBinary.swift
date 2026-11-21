import Foundation
import MachOKit

/// Mach-O 二进制的统一入口：负责切片选择、段/节/符号/导出/字符串枚举，
/// 以及 vmaddr 与文件偏移之间的换算。分析结果不缓存在这里（缓存归 REIndex）。
final class REBinary {
    let url: URL
    let fileSize: UInt64
    /// 整个容器文件的内存映射数据（fat 容器时包含全部切片）。
    let containerData: Data
    /// 当前切片在容器中的起始偏移（thin 文件为 0）。
    let headerStartOffset: Int
    let machO: MachOFile
    let arch: REArch

    private(set) lazy var preferredLoadAddress: UInt64 = {
        if let text = machO.segments.first(where: { $0.segmentName == "__TEXT" }) {
            return UInt64(text.virtualMemoryAddress)
        }
        return 0
    }()

    init(url: URL, preferredArch: REArch? = nil) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw REError.message("找不到文件 · \(url.lastPathComponent)")
        }
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        guard size > 0, size < 512 * 1024 * 1024 else {
            throw REError.unsupported("文件大小超出分析范围（>512MB）")
        }
        self.url = url
        self.fileSize = size
        self.containerData = try Data(contentsOf: url, options: .mappedIfSafe)

        let loaded = try MachOKit.loadFromFile(url: url)
        var machO: MachOFile
        var sliceOffset = 0
        switch loaded {
        case .machO(let single):
            machO = single
        case .fat(let fat):
            // 遍历切片读原始 cputype/cpusubtype，优先 arm64e > arm64 > arm。
            var candidates: [(combo: UInt32, machO: MachOFile, offset: Int)] = []
            for arch in fat.arches {
                let offset = Int(arch.offset)
                guard let candidate = try? MachOFile(url: url, headerStartOffset: offset) else { continue }
                let rawType = candidate.header.layout.cputype
                let rawSub = candidate.header.layout.cpusubtype
                let combo: UInt32
                if rawType == 0x0100_000C { // CPU_TYPE_ARM64
                    combo = rawSub < 0 ? UInt32(bitPattern: rawSub) : 0x0100_000C
                } else if rawType == 0x0000_000C { // CPU_TYPE_ARM
                    combo = UInt32(bitPattern: rawType)
                } else {
                    continue
                }
                candidates.append((combo, candidate, offset))
            }
            let priority: [UInt32] = preferredArch.map { [$0.rawValue32] } ?? [0x8000_0002, 0x0100_000C, 0x0000_000C]
            guard let chosen = priority.lazy.compactMap({ want in candidates.first { Self.matches($0.combo, want) } }).first else {
                throw REError.unsupported("fat 二进制中没有可分析的架构")
            }
            machO = chosen.machO
            sliceOffset = chosen.offset
        }
        self.machO = machO
        self.headerStartOffset = sliceOffset
        self.arch = try Self.detectArch(machO)
    }

    private static func matches(_ combo: UInt32, _ wanted: UInt32) -> Bool {
        if wanted == 0x8000_0002 { return combo == 0x8000_0002 }
        return combo == wanted
    }

    private static func detectArch(_ machO: MachOFile) throws -> REArch {
        let rawType = machO.header.layout.cputype
        let rawSub = machO.header.layout.cpusubtype
        if rawType == 0x0100_000C { // CPU_TYPE_ARM64
            return rawSub < 0 ? .arm64e : .arm64
        }
        if rawType == 0x0000_000C { // CPU_TYPE_ARM
            return .arm
        }
        throw REError.unsupported("架构 cputype 0x\(String(rawType, radix: 16))")
    }

    var is64Bit: Bool { arch.is64Bit }

    // MARK: - 段/节

    var segments: [RESegment] {
        machO.segments.map { seg in
            RESegment(
                name: seg.segmentName,
                vmaddr: UInt64(seg.virtualMemoryAddress),
                vmsize: UInt64(seg.virtualMemorySize),
                fileoff: UInt64(seg.fileOffset),
                filesize: UInt64(seg.fileSize),
                maxProtection: Int(seg.maxProtection.rawValue),
                initialProtection: Int(seg.initialProtection.rawValue)
            )
        }
    }

    var sections: [RESectionInfo] {
        guard is64Bit, machO.is64Bit else { return [] }
        return machO.sections64.map { section in
            RESectionInfo(
                segment: section.segmentName,
                name: section.sectionName,
                addr: UInt64(section.address),
                size: UInt64(section.size),
                fileOffset: section.offset
            )
        }
    }

    var dependencies: [String] {
        machO.dependencies.map(\.dylib.name)
    }

    /// __TEXT,__text 的位置。
    var textSection: RESectionInfo? {
        sections.first { $0.segment == "TEXT" && $0.name == "text" }
    }

    // MARK: - 符号

    /// 已定义符号（函数与数据）。
    var symbols: [RESymbol] {
        var result: [RESymbol] = []
        for symbol in machO.symbols {
            let value: UInt64
            if let n64 = symbol.nlist as? Nlist64 {
                value = n64.layout.n_value
            } else if let n32 = symbol.nlist as? Nlist {
                value = UInt64(n32.layout.n_value)
            } else {
                value = 0
            }
            let defined = symbol.nlist.sectionNumber != nil && value > 0
            guard defined, !symbol.name.isEmpty else { continue }
            result.append(RESymbol(addr: value, name: symbol.name, isDefined: true))
        }
        result.sort { $0.addr < $1.addr }
        return result
    }

    /// 未定义符号 = 导入符号表。
    var imports: [RESymbol] {
        var result: [RESymbol] = []
        for symbol in machO.symbols {
            let value: UInt64
            if let n64 = symbol.nlist as? Nlist64 {
                value = n64.layout.n_value
            } else if let n32 = symbol.nlist as? Nlist {
                value = UInt64(n32.layout.n_value)
            } else {
                value = 0
            }
            let undefined = symbol.nlist.sectionNumber == nil && value == 0
            guard undefined, !symbol.name.isEmpty else { continue }
            result.append(RESymbol(addr: 0, name: symbol.name, isDefined: false))
        }
        return result
    }

    /// 导出符号（export trie）。
    var exports: [REExport] {
        machO.exportedSymbols.compactMap { entry in
            guard let offset = entry.offset, offset > 0 else { return nil }
            return REExport(addr: UInt64(offset), name: entry.name)
        }
        .sorted { $0.addr < $1.addr }
    }

    // MARK: - 字符串

    /// 扫描 __TEXT,__cstring（以及 __os_log 等 C 串节）得到字符串列表。
    var strings: [REString] {
        let candidates = sections.filter { $0.segment == "TEXT" && ["cstring", "os_log", "const"].contains($0.name) && $0.size > 0 }
        var result: [REString] = []
        for section in candidates {
            let start = section.fileOffset
            let end = start + Int(section.size)
            guard start >= 0, end <= containerData.count, start < end else { continue }
            let slice = containerData.subdata(in: start..<end)
            var runStart: Int?
            slice.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                var index = 0
                while index < raw.count {
                    let byte = raw[index]
                    if byte == 0 {
                        if let begin = runStart, index - begin >= 2 {
                            let text = String(decoding: raw[begin..<index], as: UTF8.self)
                            let addr = vmAddr(forFileOffset: start + begin) ?? 0
                            result.append(REString(addr: addr, text: text))
                        }
                        runStart = nil
                        index += 1
                    } else if isPrintable(byte) {
                        if runStart == nil { runStart = index }
                        index += 1
                    } else {
                        runStart = nil
                        index += 1
                    }
                }
            }
        }
        result.sort { $0.addr < $1.addr }
        return result
    }

    private func isPrintable(_ byte: UInt8) -> Bool {
        byte >= 0x20 && byte <= 0x7E
    }

    // MARK: - 地址换算

    /// vmaddr → 容器内文件偏移。
    func fileOffset(forVMAddr addr: UInt64) -> Int? {
        for segment in machO.segments {
            let base = UInt64(segment.virtualMemoryAddress)
            let size = UInt64(segment.fileSize)
            guard addr >= base, addr < base + size else { continue }
            return segment.fileOffset + Int(addr - base)
        }
        return nil
    }

    /// 容器内文件偏移 → vmaddr。
    func vmAddr(forFileOffset offset: Int) -> UInt64? {
        for segment in machO.segments {
            let base = segment.fileOffset
            guard offset >= base, offset < base + segment.fileSize else { continue }
            return UInt64(segment.virtualMemoryAddress + (offset - base))
        }
        return nil
    }

    /// 读取 vmaddr 处的字节（用于反汇编）。
    func bytes(atVMAddr addr: UInt64, length: Int) -> Data? {
        guard let fileOff = fileOffset(forVMAddr: addr) else { return nil }
        let end = fileOff + length
        guard fileOff >= 0, end <= containerData.count else { return nil }
        return containerData.subdata(in: fileOff..<end)
    }

    /// 反汇编某个地址开始的至多 length 字节。
    func disassemble(from addr: UInt64, maxBytes: Int, count: Int = 0) throws -> [REInstruction] {
        guard let chunk = bytes(atVMAddr: addr, length: maxBytes) else { return [] }
        guard let engine = cachedEngine else {
            throw REError.unsupported("Capstone 初始化失败 · \(arch.rawValue)")
        }
        return engine.disassemble(chunk, at: addr, count: count)
    }

    private lazy var cachedEngine: RECapstoneEngine? = try? RECapstoneEngine(arch: arch)

    /// 符号名（含最近符号匹配，供 UI 显示）。
    func name(for addr: UInt64, symbols: [RESymbol]) -> String? {
        var best: RESymbol?
        for symbol in symbols where symbol.addr <= addr {
            if best == nil || symbol.addr > best!.addr { best = symbol }
        }
        guard let best else { return nil }
        if best.addr == addr { return best.name }
        return "\(best.name)+\(addr - best.addr)"
    }
}

extension REArch {
    /// fat 切片选择用的 CPU_TYPE/CPU_SUBTYPE 组合。
    var rawValue32: UInt32 {
        switch self {
        case .arm64e: return 0x8000_0002
        case .arm64: return 0x0100_000C
        case .arm: return 0x0000_000C
        case .unknown: return 0
        }
    }
}
