import Foundation

/// 来宾 Linux 中 radare2/r2ghidra 的桥接层。
/// 只负责单个函数的反编译（af + pdg），不做全量 aaa 分析。
final class REGuest {
    private let runtime: TheosRuntime
    private static let rizinPath = "/usr/bin/radare2"

    init(runtime: TheosRuntime) {
        self.runtime = runtime
    }

    /// 来宾工具链中是否已包含 radare2。
    func isAvailable() -> Bool {
        do {
            _ = try runtime.execute(["/bin/busybox", "test", "-x", Self.rizinPath])
            return true
        } catch {
            return false
        }
    }

    /// 反编译一个函数。失败时自动降级到 r2 内置 pdc。
    /// 阻塞调用，需在后台线程执行。
    func decompile(binary url: URL, function addr: UInt64,
                   log: @escaping (String) -> Void) throws -> String {
        try runtime.boot()
        let hex = "0x" + String(addr, radix: 16)
        let guestDir = "/tmp/re-" + UUID().uuidString
        let guestPath = guestDir + "/" + url.lastPathComponent
        defer { _ = try? runtime.execute(["/bin/rm", "-rf", guestDir]) }

        _ = try runtime.execute(["/bin/mkdir", "-p", guestDir])
        try runtime.upload(url, to: guestPath, log: log)

        let prelude = "e scr.color=0; e scr.utf8=0; e asm.bytes=false; "
        let mainCommands = prelude + "af @ \(hex); pdg @ \(hex)"
        do {
            let data = try runtime.execute([Self.rizinPath, "-q", "-N", "-n", guestPath,
                                            "-c", mainCommands], timeout: 120)
            let text = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw REError.message("r2ghidra 未输出伪代码。")
            }
            return text
        } catch {
            log("r2ghidra 反编译失败，降级到内置 pdc · \(error.localizedDescription)\n")
            let fallbackCommands = prelude + "af @ \(hex); pdc @ \(hex)"
            let data = try runtime.execute([Self.rizinPath, "-q", "-N", "-n", guestPath,
                                            "-c", fallbackCommands], timeout: 120)
            let text = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw REError.message("反编译失败且降级输出为空。")
            }
            return text
        }
    }
}
