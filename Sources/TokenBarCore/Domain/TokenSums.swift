public struct TokenSums: Sendable, Equatable, Codable {
    public var input: Int64
    public var output: Int64
    public var cacheRead: Int64
    public var cacheWrite: Int64

    public init(input: Int64 = 0, output: Int64 = 0, cacheRead: Int64 = 0, cacheWrite: Int64 = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    public var total: Int64 { input + output + cacheRead + cacheWrite }

    public static func + (lhs: TokenSums, rhs: TokenSums) -> TokenSums {
        TokenSums(
            input: lhs.input + rhs.input, output: lhs.output + rhs.output,
            cacheRead: lhs.cacheRead + rhs.cacheRead, cacheWrite: lhs.cacheWrite + rhs.cacheWrite
        )
    }

    public static func - (lhs: TokenSums, rhs: TokenSums) -> TokenSums {
        TokenSums(
            input: lhs.input - rhs.input, output: lhs.output - rhs.output,
            cacheRead: lhs.cacheRead - rhs.cacheRead, cacheWrite: lhs.cacheWrite - rhs.cacheWrite
        )
    }

    public static func += (lhs: inout TokenSums, rhs: TokenSums) { lhs = lhs + rhs }
}
