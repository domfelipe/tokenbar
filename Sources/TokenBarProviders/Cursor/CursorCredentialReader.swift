import Foundation
import TokenBarCore
#if canImport(SQLite3)
import SQLite3
#endif

/// Credencial Cursor pronta para a requisição: header Cookie completo
/// (`WorkosCursorSessionToken=<userID>%3A%3A<accessToken>`) + identidade
/// best-effort derivada do JWT. Mantida em memória, nunca logada — este
/// arquivo não tem print/log e nunca vai ter.
public struct CursorCredential: Sendable, Equatable {
    public let cookieHeader: String
    public let userID: String?
}

/// Leitor read-only da sessão Cursor — portado da referência MIT CodexBar
/// (`Sources/CodexBarCore/Providers/Cursor/CursorAppAuth.swift`): o token vem
/// do SQLite do app Cursor (`ItemTable`, chave `cursorAuth/accessToken`) ou de
/// um arquivo de credencial registrado (cookie header cru OU access token JWT).
/// O app pode rotacionar o token a qualquer momento — lê a cada chamada,
/// nunca escreve.
///
/// Overrides de testes/wiring:
/// - env `TOKENBAR_CURSOR_DB` → caminho do `state.vscdb`
///   (default `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`)
/// - O arquivo de credencial de conta registrada é o path do próprio registro.
public struct CursorCredentialReader: Sendable {
    public let databaseFileURL: URL?
    public let tokenFileURL: URL?

    /// - Parameters:
    ///   - databaseFileURL: `state.vscdb` do app Cursor (`nil` = pula auto-descoberta).
    ///   - tokenFileURL: arquivo de credencial de CONTA REGISTRADA (`nil` na instância canônica).
    public init(databaseFileURL: URL?, tokenFileURL: URL? = nil) {
        self.databaseFileURL = databaseFileURL
        self.tokenFileURL = tokenFileURL
    }

    public static func resolve(environment: [String: String], home: URL) -> CursorCredentialReader {
        let dbURL: URL
        if let raw = environment["TOKENBAR_CURSOR_DB"], !raw.isEmpty {
            dbURL = URL(filePath: raw)
        } else {
            dbURL = home.appendingPathComponent(
                "Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        }
        return CursorCredentialReader(databaseFileURL: dbURL)
    }

    public static func resolve() -> CursorCredentialReader {
        resolve(
            environment: ProcessInfo.processInfo.environment,
            home: URL(filePath: NSHomeDirectory()))
    }

    /// Ordem: arquivo de conta registrada (quando presente) → banco do app.
    /// Guard Red Team F4: só ARQUIVO REGULAR é lido (FIFO bloquearia `open()`
    /// para sempre). Nada utilizável → `nil` = nenhuma conta visível.
    public func read() -> CursorCredential? {
        if let tokenFileURL {
            return Self.readTokenFile(at: tokenFileURL)
        }
        guard let databaseFileURL else { return nil }
        return Self.readAppDatabase(at: databaseFileURL)
    }

    // MARK: - Arquivo de credencial (conta registrada)

    /// Conteúdo aceito (string):
    /// - cookie header cru: `WorkosCursorSessionToken=<userID>%3A%3A<JWT>` →
    ///   vai como veio (mesmo caminho do `fetchWithManualCookies` da referência);
    /// - access token JWT cru → cookie construído do claim `sub`.
    /// Sessão vencida (`exp` no passado + 60 s de folga) → `nil` (referência
    /// `isUsable`: sessão expirada não é sessão — evita 401 garantido).
    static func readTokenFile(at url: URL) -> CursorCredential? {
        guard FileKind.isRegularFile(atPath: url.path),
              let raw = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        let content = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return nil }

        if content.contains("WorkosCursorSessionToken=") {
            guard let identity = CursorSessionIdentity.from(cookieHeader: content),
                  identity.isUsable
            else { return nil }
            return CursorCredential(cookieHeader: content, userID: identity.userID)
        }
        guard let identity = CursorSessionIdentity(accessToken: content) else { return nil }
        return identity.usableCredential
    }

    // MARK: - Banco do app Cursor (auto-descoberta)

    /// `state.vscdb`: `SELECT value FROM ItemTable WHERE key =
    /// 'cursorAuth/accessToken'` — abertura READONLY (nunca escreve; um WAL
    /// vivo é lido de forma consistente sem criar sidecars, pois nunca
    /// checkpointamos). DB ausente/ilegível/sem chave → `nil`.
    static func readAppDatabase(at url: URL) -> CursorCredential? {
        #if canImport(SQLite3)
        guard FileKind.isRegularFile(atPath: url.path) else { return nil }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            return nil
        }
        defer { sqlite3_close(handle) }

        let sql = "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let cString = sqlite3_column_text(statement, 0)
        else { return nil }
        let accessToken = String(cString: cString).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessToken.isEmpty,
              let identity = CursorSessionIdentity(accessToken: accessToken)
        else { return nil }
        return identity.usableCredential
        #else
        return nil
        #endif
    }
}

/// Identidade/sessão derivada do access token JWT — portado da referência
/// (`CursorSessionIdentity` + `CursorAppAuthSession`): `sub` =
/// "auth0|<userID>" → último segmento após `|`; cookie na forma
/// `WorkosCursorSessionToken=<userID>%3A%3A<token>` (o `::` percent-encoded,
/// exatamente como a referência envia).
struct CursorSessionIdentity: Sendable, Equatable {
    let userID: String
    let email: String?
    let expiresAt: Date?
    /// Access token cru — em memória só para montar o cookie; nunca logado.
    let accessToken: String

    /// Decode do payload JWT (segmento 2, base64url) — token sem 2 segmentos,
    /// payload ilegível ou `sub` sem userID utilizável → `nil`. O userID é
    /// restrito a [A-Za-z0-9._-] (guard da referência): claim hostil não vira
    /// header (injeção via JWT). Header e assinatura NÃO são validados — a
    /// validade real é do servidor Cursor (somos leitores).
    init?(accessToken: String) {
        let parts = accessToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        guard let subject = (json["sub"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let userID = subject.split(separator: "|", omittingEmptySubsequences: true).last.map(String.init),
              !userID.isEmpty
        else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard userID.unicodeScalars.allSatisfy(allowed.contains) else { return nil }

        self.userID = userID
        self.email = (json["email"] as? String)?.lowercased()
        self.expiresAt = (json["exp"] as? Double).map { Date(timeIntervalSince1970: $0) }
        self.accessToken = accessToken
    }

    /// `exp` no passado + 60 s de folga → inutilizável (referência `isUsable`);
    /// sem `exp` → deixa o servidor julgar.
    var isUsable: Bool {
        guard let expiresAt else { return true }
        return expiresAt.timeIntervalSinceNow > 60
    }

    /// Credencial completa se a sessão estiver utilizável; `nil` se expirada.
    var usableCredential: CursorCredential? {
        guard isUsable else { return nil }
        return CursorCredential(cookieHeader: cookieHeader(), userID: userID)
    }

    func cookieHeader() -> String {
        "WorkosCursorSessionToken=\(userID)%3A%3A\(accessToken)"
    }

    /// Identidade a partir de um cookie header cru (`fetchWithManualCookies`).
    static func from(cookieHeader: String) -> CursorSessionIdentity? {
        for component in cookieHeader.split(separator: ";") {
            let pair = component.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2,
                  pair[0].trimmingCharacters(in: .whitespacesAndNewlines) == "WorkosCursorSessionToken"
            else { continue }
            let encoded = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = encoded.removingPercentEncoding ?? encoded
            guard let token = value.components(separatedBy: "::").last else { continue }
            return CursorSessionIdentity(accessToken: token)
        }
        return nil
    }
}
