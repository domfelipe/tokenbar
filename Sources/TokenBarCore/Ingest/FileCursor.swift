public struct FileCursor: Sendable, Codable, Equatable {
    public var offset: UInt64
    /// Ids de origem já contados no arquivo — dedupe de fontes que reanexam
    /// mensagens (Gemini: mesma linha-raiz `id` 2× no arquivo, spec F2 §3.3).
    /// O offset sozinho não cobre: a duplicata entra como bytes NOVOS, e o
    /// re-scan de rollover relê o arquivo do zero. `nil` = sem dedupe (Claude/
    /// Codex). Limitado pelo provider: resetado no rollover de dia, então só
    /// acumula ids do dia corrente. Opcional p/ compat: cursor persistido
    /// antes do campo decodifica `nil` (síntese usa `decodeIfPresent`).
    public var seenIDs: Set<String>?

    public init(offset: UInt64, seenIDs: Set<String>? = nil) {
        self.offset = offset
        self.seenIDs = seenIDs
    }
}
