import Foundation

enum PerformanceBudgets {
    static let profile = ProcessInfo.processInfo.environment["OPENGROK_PERFORMANCE_PROFILE"] ?? "unset"
    static let streamNanoseconds: UInt64 = 8_000_000_000
    static let renderNanoseconds: UInt64 = 8_000_000_000
    static let sessionNanoseconds: UInt64 = 20_000_000_000
    static let memoryNanoseconds: UInt64 = 8_000_000_000
}
