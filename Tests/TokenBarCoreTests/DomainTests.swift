import Foundation
import Testing
@testable import TokenBarCore

struct DomainTests {
    @Test
    func testProviderIDCodableRoundtrip() throws {
        let original = ProviderID.claude
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(ProviderID.self, from: data) == original)
    }

    @Test
    func testAccountIDHashAndEquality() {
        let a = AccountID(provider: .claude, key: "local")
        let b = AccountID(provider: .claude, key: "local")
        let c = AccountID(provider: .claude, key: "work")
        #expect(a == b)
        #expect(a != c)
        #expect(Set([a, b, c]).count == 2)
    }

    @Test
    func testUsageEventCodableRoundtrip() throws {
        let event = UsageEvent(
            ts: Date(timeIntervalSince1970: 1_788_000_000),
            provider: .claude,
            account: AccountID(provider: .claude, key: "local"),
            model: "claude-sonnet-4-6",
            inputTokens: 100, outputTokens: 200, cacheReadTokens: 300, cacheWriteTokens: 400,
            project: "domhubs-devsquad"
        )
        let data = try JSONEncoder().encode(event)
        #expect(try JSONDecoder().decode(UsageEvent.self, from: data) == event)
    }

    @Test
    func testTokenSumsArithmetic() {
        var sums = TokenSums(input: 10, output: 20, cacheRead: 30, cacheWrite: 40)
        #expect(sums.total == 100)
        sums += TokenSums(input: 1, output: 2, cacheRead: 3, cacheWrite: 4)
        #expect(sums == TokenSums(input: 11, output: 22, cacheRead: 33, cacheWrite: 44))
        sums = sums - sums  // zera
        #expect(sums.total == 0)
    }

    @Test
    func testTokenSumsCodableRoundtrip() throws {
        let sums = TokenSums(input: 1, output: 2, cacheRead: 3, cacheWrite: 4)
        let data = try JSONEncoder().encode(sums)
        #expect(try JSONDecoder().decode(TokenSums.self, from: data) == sums)
    }

    // Red Team caso 1: soma de usage hostil (Int64.max ×2) estourava Int64 e
    // derrubava o app com SIGTRAP. Contrato pós-fix: aritmética saturante —
    // acumula até .max, nunca trap.
    @Test
    func testTokenSumsSaturatesInsteadOfTrapping() {
        let maxed = TokenSums(input: .max)
        let doubled = maxed + maxed
        #expect(doubled.input == Int64.max)

        let total = TokenSums(input: .max, output: .max, cacheRead: .max, cacheWrite: .max).total
        #expect(total == Int64.max)

        var accum = TokenSums(input: .max - 1)
        accum += TokenSums(input: 5)
        #expect(accum.input == Int64.max)

        // subtração exata não satura; só estouro satura
        let neg = TokenSums() - TokenSums(input: .max)
        #expect(neg.input == -.max)
        let negSaturated = TokenSums() - TokenSums(input: .min)
        #expect(negSaturated.input == Int64.max)
    }
}
