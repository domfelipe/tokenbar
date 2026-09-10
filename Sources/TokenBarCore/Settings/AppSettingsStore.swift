import Foundation

/// Preferências do usuário (F5 Task 3) na tabela `settings` (spec §6) — UMA
/// fonte de chaves/faixas/defaults para o coordinator (leitura no launch) e
/// para a janela de Settings (escrita viva, sem restart).
///
/// Chaves:
/// - `scheduler:menuIntervalSeconds` — refresh com o painel aberto
///   (foreground; default 60 s, spec §7).
/// - `scheduler:idleIntervalSeconds` — refresh em background/ocioso
///   (default 300 s, spec §7).
/// - `menubar:visibleProviders` — providers que aparecem no TEXTO do menu
///   bar (JSON de rawValues; ausente = todos — default de quem nunca abriu
///   settings).
///
/// HONESTIDADE (mesmo padrão do AlertEngine/Red Team): valor corrompido ou
/// fora de faixa → DEFAULT do campo (nunca crash, nunca chute intermediário);
/// sem DB → defaults e escrita no-op (persistência é aditiva). Inteiros e
/// listas via JSONEncoder/JSONDecoder — MESMO formato do AlertEngine para
/// `alerts:*` (uma convenção só de serialização no banco).
public struct AppSettingsStore: Sendable {
    public static let menuIntervalKey = "scheduler:menuIntervalSeconds"
    public static let idleIntervalKey = "scheduler:idleIntervalSeconds"
    public static let menuBarVisibleKey = "menubar:visibleProviders"

    /// Faixas da UI (Task 3): foreground 30–300 s, background/ocioso 60–1800 s.
    public static let menuRange = 30...300
    public static let idleRange = 60...1800
    /// Defaults = cadência da spec §7 (menu 60 s, ocioso 5 min).
    public static let defaultMenuSeconds = 60
    public static let defaultIdleSeconds = 300

    let database: AppDatabase?

    public init(database: AppDatabase?) {
        self.database = database
    }

    // MARK: - Intervalos do scheduler (segundos)

    public func loadMenuIntervalSeconds() -> Int {
        Self.loadInterval(
            database: database, key: Self.menuIntervalKey,
            range: Self.menuRange, fallback: Self.defaultMenuSeconds)
    }

    public func loadIdleIntervalSeconds() -> Int {
        Self.loadInterval(
            database: database, key: Self.idleIntervalKey,
            range: Self.idleRange, fallback: Self.defaultIdleSeconds)
    }

    public func saveMenuIntervalSeconds(_ seconds: Int) {
        saveInterval(seconds, key: Self.menuIntervalKey, range: Self.menuRange)
    }

    public func saveIdleIntervalSeconds(_ seconds: Int) {
        saveInterval(seconds, key: Self.idleIntervalKey, range: Self.idleRange)
    }

    private static func loadInterval(
        database: AppDatabase?, key: String, range: ClosedRange<Int>, fallback: Int
    ) -> Int {
        guard let database,
              let raw = try? database.setting(forKey: key),
              let value = try? JSONDecoder().decode(Int.self, from: Data(raw.utf8)),
              range.contains(value)
        else { return fallback }
        return value
    }

    private func saveInterval(_ seconds: Int, key: String, range: ClosedRange<Int>) {
        guard let database, range.contains(seconds),
              let data = try? JSONEncoder().encode(seconds)
        else { return }
        try? database.setSetting(String(decoding: data, as: UTF8.self), forKey: key)
    }

    // MARK: - Providers visíveis no texto do menu bar

    /// Default = TODOS (comportamento de quem nunca mexeu nas settings).
    public static let defaultVisibleProviders = Set(ProviderID.allCases)

    public func loadVisibleProviders() -> Set<ProviderID> {
        guard let database,
              let raw = try? database.setting(forKey: Self.menuBarVisibleKey),
              let rawValues = try? JSONDecoder().decode([String].self, from: Data(raw.utf8))
        else { return Self.defaultVisibleProviders }
        let parsed = Set(rawValues.compactMap(ProviderID.init(rawValue:)))
        // Vazio é escolha válida (menu bar vira "TB"); ids desconhecidos no
        // JSON (banco de versão futura) simplesmente não contam.
        return parsed
    }

    public func saveVisibleProviders(_ visible: Set<ProviderID>) {
        guard let database,
              let data = try? JSONEncoder().encode(visible.map(\.rawValue).sorted())
        else { return }
        try? database.setSetting(
            String(decoding: data, as: UTF8.self), forKey: Self.menuBarVisibleKey)
    }
}
