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

    // Red Team F1 (caso 1): usage hostil com valores ~Int64.max estourava a soma
    // e derrubava o app com SIGTRAP (arithmetic overflow). Aritmética saturante:
    // acumula até .max/.min, nunca trap. Para somas de tokens legítimas o
    // comportamento é idêntico ao `+` comum.
    private static func saturating(_ a: Int64, _ b: Int64) -> Int64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? (b > 0 ? Int64.max : Int64.min) : sum
    }

    public var total: Int64 {
        Self.saturating(Self.saturating(input, output), Self.saturating(cacheRead, cacheWrite))
    }

    public static func + (lhs: TokenSums, rhs: TokenSums) -> TokenSums {
        TokenSums(
            input: saturating(lhs.input, rhs.input), output: saturating(lhs.output, rhs.output),
            cacheRead: saturating(lhs.cacheRead, rhs.cacheRead), cacheWrite: saturating(lhs.cacheWrite, rhs.cacheWrite)
        )
    }

    public static func - (lhs: TokenSums, rhs: TokenSums) -> TokenSums {
        lhs + TokenSums(
            input: rhs.input == .min ? .max : -rhs.input,
            output: rhs.output == .min ? .max : -rhs.output,
            cacheRead: rhs.cacheRead == .min ? .max : -rhs.cacheRead,
            cacheWrite: rhs.cacheWrite == .min ? .max : -rhs.cacheWrite
        )
    }

    public static func += (lhs: inout TokenSums, rhs: TokenSums) { lhs = lhs + rhs }
}
