import Foundation

/// Credencial Codex lida de `~/.codex/auth.json` — mantida em memória, nunca
/// logada (spec §9): este arquivo não tem print/log e nunca vai ter.
public struct CodexAuth: Sendable, Equatable {
    public let accessToken: String?
    /// `.tokens.account_id` (preferido) ou claim `chatgpt_account_id` do JWT
    /// (contas antigas) — spec §1.2.
    public let accountID: String?
    public let authMode: String?

    /// OAuth utilizável p/ usage API. `auth_mode: "apikey"` (com
    /// `OPENAI_API_KEY`) = sem OAuth → só ingest local (spec §1.2/§1.6).
    public var hasOAuth: Bool {
        guard let token = accessToken, !token.isEmpty else { return false }
        return authMode != "apikey"
    }

    public init(accessToken: String?, accountID: String?, authMode: String?) {
        self.accessToken = accessToken
        self.accountID = accountID
        self.authMode = authMode
    }
}

/// Leitor read-only de `~/.codex/auth.json` (spec §1.2). Quem renova o token é
/// o `codex` — este reader só lê, a cada chamada (o token pode ter sido
/// renovado desde a leitura anterior). `last_refresh` é ignorado.
///
/// Override de testes/wiring: env `TOKENBAR_CODEX_AUTH` aponta o arquivo
/// (padrão `TOKENBAR_CLAUDE_DIR` da F1).
public struct CodexAuthReader: Sendable {
    public let authFileURL: URL

    public init(authFileURL: URL) {
        self.authFileURL = authFileURL
    }

    public static func resolve(environment: [String: String], home: URL) -> CodexAuthReader {
        if let override = environment["TOKENBAR_CODEX_AUTH"], !override.isEmpty {
            return CodexAuthReader(authFileURL: URL(filePath: override))
        }
        return CodexAuthReader(authFileURL: home.appendingPathComponent(".codex/auth.json"))
    }

    public static func resolve() -> CodexAuthReader {
        resolve(
            environment: ProcessInfo.processInfo.environment,
            home: URL(filePath: NSHomeDirectory())
        )
    }

    /// Lê e decodifica a credencial. Arquivo ausente/ilegível/ilegível-como-JSON
    /// → `nil` (nenhuma conta visível); JSON válido com campos faltando → auth
    /// com `hasOAuth: false` (a conta existe p/ ingest local, spec §1.6).
    public func read() -> CodexAuth? {
        guard let data = try? Data(contentsOf: authFileURL),
              let file = try? Self.decoder.decode(AuthFile.self, from: data)
        else { return nil }
        let accountID = file.tokens?.accountID
            ?? Self.jwtClaim(file.tokens?.idToken, claim: "chatgpt_account_id")
            ?? Self.jwtClaim(file.tokens?.accessToken, claim: "chatgpt_account_id")
        return CodexAuth(
            accessToken: file.tokens?.accessToken,
            accountID: accountID,
            authMode: file.authMode
        )
    }

    // Decoder reutilizado (padrão F1: criar JSONDecoder por leitura custa caro;
    // uso é single-thread por provider). JSONDecoder é Sendable — sem
    // nonisolated(unsafe) necessário.
    private static let decoder = JSONDecoder()

    /// Tolerante: chaves ausentes, nulas ou de tipo inesperado não derrubam a
    /// leitura — campos viram `nil` e o snapshot degrada, nunca dado errado.
    private struct AuthFile: Decodable {
        let authMode: String?
        let tokens: Tokens?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            authMode = FlexibleJSON.string(c, "auth_mode", "authMode")
            tokens = (try? c.decodeIfPresent(Tokens.self, forKey: AnyKey("tokens"))) ?? nil
        }

        struct Tokens: Decodable {
            let accessToken: String?
            let accountID: String?
            let idToken: String?
            // refresh_token existe no arquivo e é propositalmente ignorado —
            // este provider nunca renova credencial (spec §1.2).

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: AnyKey.self)
                accessToken = FlexibleJSON.string(c, "access_token", "accessToken")
                accountID = FlexibleJSON.string(c, "account_id", "accountId")
                idToken = FlexibleJSON.string(c, "id_token", "idToken")
            }
        }
    }

    /// Claim de um payload JWT (parte 2 de `a.b.c`, base64url). Fallback de
    /// `account_id` p/ contas antigas (spec §1.2). Malformado → nil.
    static func jwtClaim(_ token: String?, claim: String) -> String? {
        guard let token, !token.isEmpty else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = json[claim] as? String, !value.isEmpty
        else { return nil }
        return value
    }
}

/// Chave de codificação por string — evita boilerplate de CodingKeys nos
/// decoders tolerantes (aceita qualquer nome de campo sem crash).
struct AnyKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(_ string: String) {
        self.stringValue = string
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) { nil }
}

/// Extração tolerante de valores JSON (spec §1.3): snake/camelCase por lista de
/// alias; números podem chegar como int, double ou string; campo nulo/ausente/
/// de tipo inesperado → nil — degrada, nunca dado errado.
enum FlexibleJSON {
    static func string(_ c: KeyedDecodingContainer<AnyKey>, _ keys: String...) -> String? {
        for key in keys {
            if let v = try? c.decode(String.self, forKey: AnyKey(key)), !v.isEmpty { return v }
        }
        return nil
    }

    static func double(_ c: KeyedDecodingContainer<AnyKey>, _ keys: String...) -> Double? {
        for key in keys {
            // Só valores FINITOS (Red Team T8, P1): `1e999`/`NaN`/`Infinity`
            // decodificam para Double não-finito e, mais adiante, conversões
            // Int(Double) em quem consome (labels/kind) TRAPAM. Não-finito é
            // lixo de payload hostil/bugado → tratado como ausente.
            if let v = try? c.decode(Double.self, forKey: AnyKey(key)), v.isFinite { return v }
            if let s = try? c.decode(String.self, forKey: AnyKey(key)), let v = Double(s), v.isFinite { return v }
        }
        return nil
    }

    static func bool(_ c: KeyedDecodingContainer<AnyKey>, _ keys: String...) -> Bool? {
        for key in keys {
            if let v = try? c.decode(Bool.self, forKey: AnyKey(key)) { return v }
        }
        return nil
    }

    static func int64(_ c: KeyedDecodingContainer<AnyKey>, _ keys: String...) -> Int64? {
        for key in keys {
            if let v = try? c.decode(Int64.self, forKey: AnyKey(key)) { return v }
            if let s = try? c.decode(String.self, forKey: AnyKey(key)), let v = Int64(s) { return v }
        }
        return nil
    }
}
