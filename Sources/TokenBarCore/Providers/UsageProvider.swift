import Foundation

/// Capacidades declaradas de um provider — a UI/scheduler consulta antes de
/// chamar; provider sem `.apiUsage` nunca gera requisição de rede, sem
/// `.localIngest` nunca entra no ciclo de ingest de transcripts.
public struct ProviderCapabilities: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let apiUsage = ProviderCapabilities(rawValue: 1 << 0)
    public static let localIngest = ProviderCapabilities(rawValue: 1 << 1)
    public static let credits = ProviderCapabilities(rawValue: 1 << 2)
    public static let multiAccount = ProviderCapabilities(rawValue: 1 << 3)
}

/// Cursor de ingest local do protocolo: posição por arquivo. Embrulha o que a
/// F1 já faz — o `FileOffsetStoring` do Claude persiste exatamente este mapa
/// (path → FileCursor); providers F2 (Codex/Gemini) usam o mesmo formato.
public struct IngestCursor: Sendable, Equatable, Codable {
    public var fileOffsets: [String: FileCursor]

    public init(fileOffsets: [String: FileCursor] = [:]) {
        self.fileOffsets = fileOffsets
    }
}

/// Resultado de um ciclo de `ingestLocal`. `events` traz os eventos novos do
/// ciclo; providers de streaming (Claude) aplicam os eventos no ledger interno
/// à medida que saem do parser e os descartam — memória não escala com o
/// tamanho do arquivo (Red Team F1, caso 2) — e aí `eventsApplied` conta o que
/// foi aplicado mesmo com `events` vazio. `providerTotals` carrega o total do
/// dia por provider (equivalente ao `IngestOutcome` da F1); para providers
/// sem ledger interno o scheduler acumula a partir de `events`.
public struct IngestBatch: Sendable, Equatable {
    public let events: [UsageEvent]
    public let eventsApplied: Int
    public let providerTotals: [ProviderID: Int64]
    public let nextCursor: IngestCursor

    public init(
        events: [UsageEvent],
        eventsApplied: Int,
        providerTotals: [ProviderID: Int64],
        nextCursor: IngestCursor
    ) {
        self.events = events
        self.eventsApplied = eventsApplied
        self.providerTotals = providerTotals
        self.nextCursor = nextCursor
    }
}

/// Ponto de extensão do TokenBar (spec §5). Todo provider de uso é isto:
/// descobre contas (read-only em credenciais), busca uso via API quando tem
/// capability, e ingere transcripts locais quando tem capability.
public protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    var capabilities: ProviderCapabilities { get }

    /// Lê credential files/Keychain/env (read-only) e lista as contas visíveis.
    func discoverAccounts() async -> [AccountRef]

    /// Uso/limites via rede. Erro de auth vira estado no snapshot
    /// (`authState: .invalid`), nunca uma mensagem com credencial (spec §5 regra 4).
    func fetchUsage(_ account: AccountRef) async throws -> UsageSnapshot

    /// Ingest incremental de arquivos locais a partir de `cursor`.
    func ingestLocal(_ account: AccountRef, from cursor: IngestCursor) async throws -> IngestBatch
}
