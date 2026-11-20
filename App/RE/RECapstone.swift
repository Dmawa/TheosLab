import Foundation
import CapstoneCore

/// Capstone 反汇编引擎的 Swift 封装。每个引擎实例绑定一种架构。
final class RECapstoneEngine {
    let handle: csh
    private let arch: REArch

    init(arch: REArch) throws {
        self.arch = arch
        var raw: csh = 0
        // CS_ARCH_AARCH64 = 1, CS_ARCH_ARM = 0；CS_MODE_LITTLE_ENDIAN = 0，
        // 32 位 ARM 用 CS_MODE_V8 (1 << 6)。用 rawValue 构造，避免 C 枚举命名导入差异。
        let archValue: UInt32 = arch.is64Bit ? 1 : 0
        let modeValue: UInt32 = arch.is64Bit ? 0 : (1 << 6)
        guard let archEnum = cs_arch(rawValue: archValue),
              let modeEnum = cs_mode(rawValue: modeValue),
              cs_open(archEnum, modeEnum, &raw) == 0 else {
            throw REError.unsupported("Capstone 初始化失败 · \(arch.rawValue)")
        }
        handle = raw
    }

    deinit {
        var raw = handle
        cs_close(&raw)
    }

    /// 反汇编一段内存映像。address 是映像的虚拟地址（非文件偏移）。
    /// count = 0 表示解到数据结束或遇到无法解码处为止。
    func disassemble(_ bytes: UnsafeRawBufferPointer, at address: UInt64, count: Int = 0) -> [REInstruction] {
        guard let base = bytes.baseAddress else { return [] }
        var pointer: UnsafeMutablePointer<cs_insn>?
        let decoded = cs_disasm(handle, base.assumingMemoryBound(to: UInt8.self),
                                bytes.count, address, Int32(clamping: count), &pointer)
        guard decoded > 0, let pointer else { return [] }
        defer { cs_free(pointer, decoded) }
        return (0..<Int(decoded)).map { index in
            let insn = pointer[index]
            return REInstruction(
                address: UInt64(insn.address),
                size: UInt16(insn.size),
                bytes: Self.fixedBytes(of: insn.bytes, count: Int(insn.size)),
                mnemonic: Self.fixedString(of: insn.mnemonic),
                operands: Self.fixedString(of: insn.op_str)
            )
        }
    }

    /// 从 Data 便捷反汇编。
    func disassemble(_ data: Data, at address: UInt64, count: Int = 0) -> [REInstruction] {
        data.withUnsafeBytes { raw in disassemble(raw, at: address, count: count) }
    }

    // cs_insn 的定长数组字段以元组形式导入 Swift，用泛型统一转换。

    private static func fixedBytes<T>(of tuple: T, count: Int) -> [UInt8] {
        withUnsafeBytes(of: tuple) { Array($0.prefix(count)) }
    }

    private static func fixedString<T>(of tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}
