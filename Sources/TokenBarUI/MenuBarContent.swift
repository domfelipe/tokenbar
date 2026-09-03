import Foundation
import TokenBarCore

public func abbrevTokens(_ n: Int64) -> String {
    switch n {
    case ..<1_000:
        return String(n)
    case ..<1_000_000:
        return String(format: "%.1fk", Double(n) / 1_000)
    case ..<1_000_000_000:
        return String(format: "%.1fM", Double(n) / 1_000_000)
    default:
        return String(format: "%.1fG", Double(n) / 1_000_000_000)
    }
}

/// Janela mais crítica de um snapshot: a de `usedFraction` mais próximo de 1
/// (regra D5 do menu — ex.: Codex com 5h em 62% e semanal em 40% mostra 62%).
/// Empate: a primeira vista (ordem do array do provider) vence. `nil` quando
/// nenhuma janela tem fração conhecida (modo local — spec §5 regra 2).
public func criticalWindow(in windows: [UsageWindow]) -> UsageWindow? {
    var best: UsageWindow?
    var bestFraction = -1.0
    for window in windows {
        guard let fraction = window.usedFraction, fraction > bestFraction else { continue }
        best = window
        bestFraction = fraction
    }
    return best
}

/// Estado de exibição de UM provider — o que a UI/heartbeat consome por ciclo.
/// `percent` em escala 0...100 (`nil` = sem janela com fração conhecida);
/// `resetsAt` da janela crítica (linha "reseta em" do menu); `source` alimenta
/// o badge "(local)". Estende o mínimo do brief ({percent, todayTokens,
/// authState, fetchedAt}) com o que a spec do menu exige.
public struct ProviderDisplay: Equatable, Sendable {
    public var percent: Double?
    public var todayTokens: Int64
    public var authState: AuthState
    public var source: DataSource
    public var resetsAt: Date?
    public var fetchedAt: Date

    public init(
        percent: Double? = nil,
        todayTokens: Int64 = 0,
        authState: AuthState = .missing,
        source: DataSource = .localOnly,
        resetsAt: Date? = nil,
        fetchedAt: Date = Date(timeIntervalSince1970: 0)
    ) {
        self.percent = percent
        self.todayTokens = todayTokens
        self.authState = authState
        self.source = source
        self.resetsAt = resetsAt
        self.fetchedAt = fetchedAt
    }

    /// Estado inicial (nada ciclo ainda): sem dado — some da string do menu.
    public static let empty = ProviderDisplay()

    /// Tem algo a mostrar: fração de janela ou tokens do dia.
    public var hasData: Bool { percent != nil || todayTokens > 0 }

    /// Fragmento do menu bar ("C:12.4k" | "X:62%"); `nil` = sem dados, some.
    public var menuBarFragment: String? {
        if let percent {
            let clamped = min(max(percent, 0), 100)
            return "\(Int(clamped.rounded()))%"
        }
        guard todayTokens > 0 else { return nil }
        return abbrevTokens(todayTokens)
    }
}

/// Conteúdo consolidado do menu bar — estado POR provider (F2). A string de
/// exibição segue a tabela de siglas D5, ordem fixa C, X, G, Z; provider sem
/// dado (sem % e sem tokens) some da string.
public struct MenuBarContent: Equatable, Sendable {
    /// Tabela de siglas D5 — codex é "X" (não colide com claude).
    public static let siglas: [ProviderID: String] = [
        .claude: "C", .codex: "X", .gemini: "G", .zai: "Z",
    ]

    /// Ordem fixa de exibição; ids fora da tabela (cursor/openrouter/copilot)
    /// entram depois, em ordem alfabética de rawValue.
    public static let displayOrder: [ProviderID] = [.claude, .codex, .gemini, .zai]

    /// Nome completo p/ as linhas do painel (menu, não menu bar).
    public static let displayNames: [ProviderID: String] = [
        .claude: "Claude", .codex: "Codex", .gemini: "Gemini", .zai: "Z.ai",
    ]

    public let providers: [ProviderID: ProviderDisplay]

    public static let empty = MenuBarContent(providers: [:])

    public init(providers: [ProviderID: ProviderDisplay]) {
        self.providers = providers
    }

    /// Conveniência de migração (F1/totais crus): só tokens, sem janela.
    public init(todayTokens: [ProviderID: Int64]) {
        self.init(providers: todayTokens.mapValues { ProviderDisplay(todayTokens: $0) })
    }

    public static func sigla(for id: ProviderID) -> String {
        siglas[id] ?? String(id.rawValue.prefix(1)).uppercased()
    }

    public static func displayName(for id: ProviderID) -> String {
        displayNames[id] ?? id.rawValue.capitalized
    }

    /// Pares (id, display) com dado, na ordem fixa de exibição (C, X, G, Z;
    /// demais ids atrás, alfabético).
    public func orderedProviders() -> [(id: ProviderID, display: ProviderDisplay)] {
        var order: [ProviderID: Int] = [:]
        let allIDs: [ProviderID] = Self.displayOrder + ProviderID.allCases.sorted { $0.rawValue < $1.rawValue }
        for (index, id) in allIDs.enumerated() {
            if order[id] == nil { order[id] = index }  // primeira ocorrência vence
        }
        let active = providers.compactMap { (id: $0.key, display: $0.value) }.filter { $0.display.hasData }
        let sorted = active.sorted { lhs, rhs in
            let lhsIndex = order[lhs.id] ?? Int.max
            let rhsIndex = order[rhs.id] ?? Int.max
            return lhsIndex < rhsIndex
        }
        return sorted
    }

    /// Fragmento do provider na string ("C:12.4k"); `nil` = sem dados.
    public func displayFragment(for id: ProviderID) -> String? {
        guard let display = providers[id], display.hasData else { return nil }
        return Self.sigla(for: id) + ":" + (display.menuBarFragment ?? "")
    }

    /// String do ícone: "C:12.4k X:62% Z:81% G:3.1k"; "TB" quando vazio.
    public func displayString() -> String {
        let fragments = orderedProviders().compactMap { displayFragment(for: $0.id) }
        guard !fragments.isEmpty else { return "TB" }
        return fragments.joined(separator: " ")
    }

    /// Linhas do painel (menu aberto): "X Codex: 62% — reseta em 2h",
    /// "C Claude: 12.4k hoje (local)". Provider sem dado não ganha linha.
    public func menuLines(now: Date = Date()) -> [String] {
        orderedProviders().map { id, display in
            var line = "\(Self.sigla(for: id)) \(Self.displayName(for: id)): "
            if let percent = display.percent {
                let clamped = min(max(percent, 0), 100)
                line += "\(Int(clamped.rounded()))%"
            } else {
                line += abbrevTokens(display.todayTokens) + " hoje"
            }
            if let resetsAt = display.resetsAt, let suffix = Self.resetSuffix(from: now, to: resetsAt) {
                line += " — \(suffix)"
            }
            if display.source == .localOnly {
                line += " (local)"
            }
            return line
        }
    }

    /// "reseta em 42min / 3h / 5d"; janela já vencida → sem sufixo (nada a
    /// prometer — o próximo ciclo atualiza a janela).
    static func resetSuffix(from now: Date, to resetsAt: Date) -> String? {
        let delta = resetsAt.timeIntervalSince(now)
        guard delta > 0 else { return nil }
        if delta < 3_600 {
            return "reseta em \(max(1, Int(delta / 60)))min"
        }
        if delta < 172_800 {
            return "reseta em \(max(1, Int(delta / 3_600)))h"
        }
        return "reseta em \(max(1, Int(delta / 86_400)))d"
    }
}
