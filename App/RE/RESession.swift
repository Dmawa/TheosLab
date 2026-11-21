import Foundation
import CryptoKit

/// 反汇编会话门面：串联 REBinary / REAnalyzer / REIndex / REGuest，供 UI 观察。
/// 状态更新统一走 MainActor（见 start()），查询方法可在任意线程调用
/// （索引库以 FULLMUTEX 打开，NSCache 线程安全）。
final class RESession: ObservableObject {
    enum Phase: Equatable {
        case loading
        case analyzing
        case ready
        case failed(String)
    }

    let binary: REBinary
    let title: String

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var progressText = ""
    @Published private(set) var functions: [REFunction] = []
    @Published private(set) var strings: [REString] = []
    @Published private(set) var segments: [RESegment] = []
    @Published private(set) var sections: [RESectionInfo] = []
    @Published private(set) var imports: [RESymbol] = []
    @Published private(set) var exports: [REExport] = []
    @Published private(set) var dependencies: [String] = []

    private let index: REIndex
    private let runtime = TheosRuntime()
    private let guest: REGuest
    private let digest: String
    private var symbols: [RESymbol] = []
    private var sortedSymbolAddrs: [UInt64] = []
    private var instructionCache = NSCache<NSNumber, REChunk>()
    private var cfgCache = NSCache<NSNumber, REBlockList>()

    init(url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw REError.message("找不到文件 · \(url.lastPathComponent)")
        }
        binary = try REBinary(url: url)
        title = url.lastPathComponent
        guest = REGuest(runtime: runtime)
        instructionCache.countLimit = 4096
        cfgCache.countLimit = 128

        digest = Self.sha256(of: url)
        let cacheName = "\(digest)-\(binary.arch.rawValue).sqlite"
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
        let analysisRoot = documents.appendingPathComponent("Analysis")
        index = try REIndex(url: analysisRoot.appendingPathComponent(cacheName))
    }

    /// 启动（或读取缓存的）分析。UI 打开后调用一次。
    func start() {
        phase = .loading
        Task.detached(priority: .userInitiated) { [self] in
            do {
                let cached = index.meta("sha256") == digest
                if !cached {
                    await MainActor.run { phase = .analyzing }
                }
                var newFunctions: [REFunction]
                var newStrings: [REString]
                var finalProgress = ""
                if cached {
                    newFunctions = index.functions()
                    newStrings = index.strings()
                } else {
                    let scannedStrings = binary.strings
                    let analyzer = try REAnalyzer(binary: binary, strings: scannedStrings)
                    let started = Date()
                    let result = try analyzer.scan { [weak self] ratio, name in
                        Task { @MainActor [weak self] in
                            self?.progressText = "\(name) · \(Int(ratio * 100))%"
                        }
                    }
                    index.saveFunctions(result.functions)
                    index.saveXrefs(result.xrefs)
                    index.saveStrings(scannedStrings)
                    index.setMeta("sha256", value: digest)
                    index.setMeta("analyzed_at", value: String(Int(started.timeIntervalSince1970)))
                    newFunctions = result.functions
                    newStrings = scannedStrings
                    finalProgress = "完成 · \(newFunctions.count) 个函数 · \(Int(-started.timeIntervalSinceNow))s"
                }
                let newSegments = binary.segments
                let newSections = binary.sections
                let newImports = binary.imports
                let newExports = binary.exports
                let newDependencies = binary.dependencies
                let newSymbols = binary.symbols
                await MainActor.run {
                    functions = newFunctions
                    strings = newStrings
                    segments = newSegments
                    sections = newSections
                    imports = newImports
                    exports = newExports
                    dependencies = newDependencies
                    symbols = newSymbols
                    sortedSymbolAddrs = newSymbols.map(\.addr)
                    if !finalProgress.isEmpty { progressText = finalProgress }
                    phase = .ready
                }
            } catch {
                await MainActor.run { phase = .failed(error.localizedDescription) }
            }
        }
    }

    // MARK: - 查询

    /// 包含给定地址的函数。
    func function(containing addr: UInt64) -> REFunction? {
        var low = 0
        var high = functions.count
        while low < high {
            let mid = (low + high) / 2
            if functions[mid].addr <= addr { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return nil }
        let candidate = functions[low - 1]
        return addr < candidate.end ? candidate : nil
    }

    /// 地址显示名：精确符号、最近符号+偏移、sub_xxxx。
    func displayName(for addr: UInt64) -> String {
        if let exact = symbolName(exactly: addr) { return exact }
        if let function = function(containing: addr) { return function.name }
        if let nearest = nearestSymbol(below: addr) {
            return "\(nearest.name)+\(addr - nearest.addr)"
        }
        return REFormat.hex(addr)
    }

    func symbolName(exactly addr: UInt64) -> String? {
        guard let position = Self.binarySearch(sortedSymbolAddrs, for: addr, exact: true) else { return nil }
        return symbols[position].name
    }

    private func nearestSymbol(below addr: UInt64) -> RESymbol? {
        guard let position = Self.binarySearch(sortedSymbolAddrs, for: addr, exact: false) else { return nil }
        return symbols[position]
    }

    private static func binarySearch(_ sorted: [UInt64], for addr: UInt64, exact: Bool) -> Int? {
        var low = 0
        var high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] < addr { low = mid + 1 } else { high = mid }
        }
        guard low < sorted.count else { return exact ? nil : (sorted.isEmpty ? nil : sorted.count - 1) }
        if exact { return sorted[low] == addr ? low : nil }
        return low > 0 ? low - 1 : nil
    }

    /// 一个函数的完整指令（带缓存）。
    func instructions(for function: REFunction) -> [REInstruction] {
        let key = NSNumber(value: function.addr)
        if let cached = instructionCache.object(forKey: key) { return cached.instructions }
        let instructions = (try? binary.disassemble(from: function.addr,
                                                    maxBytes: Int(function.size))) ?? []
        instructionCache.setObject(REChunk(instructions), forKey: key)
        return instructions
    }

    /// 任意地址区间原始反汇编（原始浏览模式），按 chunk 缓存。
    func instructionsRaw(from addr: UInt64, chunkBytes: Int = 4096) -> [REInstruction] {
        let aligned = addr - (addr % UInt64(chunkBytes / 4 * 4))
        let key = NSNumber(value: aligned)
        if let cached = instructionCache.object(forKey: key) { return cached.instructions }
        let instructions = (try? binary.disassemble(from: aligned, maxBytes: chunkBytes)) ?? []
        instructionCache.setObject(REChunk(instructions), forKey: key)
        return instructions
    }

    /// 原始字节（十六进制视图用）。
    func bytes(at addr: UInt64, length: Int) -> Data {
        binary.bytes(atVMAddr: addr, length: length) ?? Data()
    }

    func xrefs(to addr: UInt64) -> [REXref] { index.xrefs(to: addr) }
    func xrefs(from addr: UInt64) -> [REXref] { index.xrefs(from: addr) }
    func comment(addr: UInt64) -> String? { index.comment(addr: addr) }

    // MARK: - CFG

    func cfg(for function: REFunction) -> [REBasicBlock] {
        let key = NSNumber(value: function.addr)
        if let cached = cfgCache.object(forKey: key) { return cached.blocks }
        let analyzer = try? REAnalyzer(binary: binary, strings: strings)
        let blocks = analyzer?.buildCFG(function: function) ?? []
        cfgCache.setObject(REBlockList(blocks), forKey: key)
        return blocks
    }

    // MARK: - 反编译

    func decompile(_ function: REFunction) async throws -> String {
        if let cached = index.pseudocode(addr: function.addr) { return cached }
        let text = try await Task.detached(priority: .userInitiated) { [self] () -> String in
            try guest.decompile(binary: binary.url, function: function.addr, log: { _ in })
        }.value
        index.savePseudocode(addr: function.addr, text: text)
        return text
    }

    func isGuestAvailable() -> Bool {
        guest.isAvailable()
    }

    // MARK: - 编辑

    func rename(_ function: REFunction, to name: String) {
        index.renameFunction(addr: function.addr, name: name)
        if let position = functions.firstIndex(where: { $0.addr == function.addr }) {
            functions[position].name = name
        }
    }

    func setComment(addr: UInt64, text: String?) {
        index.setComment(addr: addr, text: text)
    }

    // MARK: - 内部

    private static func sha256(of url: URL) -> String {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return "unknown" }
        return String(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(24))
    }
}

/// NSCache 载体。
final class REChunk: NSObject {
    let instructions: [REInstruction]
    init(_ instructions: [REInstruction]) {
        self.instructions = instructions
    }
}

final class REBlockList: NSObject {
    let blocks: [REBasicBlock]
    init(_ blocks: [REBasicBlock]) {
        self.blocks = blocks
    }
}
