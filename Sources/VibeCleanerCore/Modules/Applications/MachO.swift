import Foundation

public enum CPUArch: String, Sendable, Hashable, CaseIterable {
    case i386, x86_64, arm, arm64, ppc, ppc64
}

/// Architectures of a Mach-O executable, read from its header only (no `lipo`, no code loaded).
enum MachO {
    static func archs(of url: URL) -> Set<CPUArch> {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? fh.close() }
        return archs((try? fh.read(upToCount: 4096)) ?? Data())
    }

    static func archs(_ data: Data) -> Set<CPUArch> {
        let b = [UInt8](data)
        func be(_ o: Int) -> UInt32 {
            o + 4 <= b.count ? UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3]) : 0
        }
        func le(_ o: Int) -> UInt32 { be(o).byteSwapped }
        switch be(0) {
        case 0xCAFE_BABE, 0xCAFE_BABF:
            // Java class files share the fat magic, with a version number (>= 45) where the arch count is.
            let count = Int(be(4)), stride = be(0) == 0xCAFE_BABF ? 32 : 20
            guard (1...20).contains(count) else { return [] }
            return Set((0..<count).compactMap { arch(be(8 + $0 * stride)) })
        case 0xFEED_FACE, 0xFEED_FACF: return Set([arch(be(4))].compactMap { $0 })
        case 0xCEFA_EDFE, 0xCFFA_EDFE: return Set([arch(le(4))].compactMap { $0 })
        default: return []
        }
    }

    static func arch(_ cpu: UInt32) -> CPUArch? {
        switch cpu {
        case 7: .i386
        case 0x0100_0007: .x86_64
        case 12: .arm
        case 0x0100_000C, 0x0200_000C: .arm64
        case 18: .ppc
        case 0x0100_0012: .ppc64
        default: nil
        }
    }
}

/// Apps that cannot run, or only through Rosetta, on this Mac.
enum AppCompatibility {
    static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }

    static var hasRosetta: Bool { FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime") }

    /// Why `app` is incompatible, or nil. Apps without a readable Mach-O executable (scripts) are never flagged.
    static func issue(_ app: InstalledApp, appleSilicon: Bool = isAppleSilicon, rosetta: Bool = hasRosetta,
                      os: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> String? {
        let a = app.archs
        if !a.isEmpty {
            if !a.contains(.x86_64) && !a.contains(.arm64) {
                return "Application 32 bits ou PowerPC : elle ne peut plus s'ouvrir sur cette version de macOS."
            }
            if appleSilicon && !a.contains(.arm64) {
                return rosetta ? "Intel uniquement : ne fonctionne qu'à travers Rosetta 2."
                    : "Intel uniquement : nécessite Rosetta 2, qui n'est pas installé."
            }
            if !appleSilicon && !a.contains(.x86_64) { return "Apple Silicon uniquement : ne peut pas s'ouvrir sur ce Mac Intel." }
        }
        if let min = app.minimumSystemVersion, isNewer(min, than: os) {
            return "Nécessite macOS \(min) ou plus récent."
        }
        return nil
    }

    static func isNewer(_ version: String, than os: OperatingSystemVersion) -> Bool {
        let p = version.split(separator: ".").map { Int($0) ?? 0 } + [0, 0, 0]
        return (p[0], p[1], p[2]) > (os.majorVersion, os.minorVersion, os.patchVersion)
    }
}
