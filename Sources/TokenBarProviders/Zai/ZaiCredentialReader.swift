import Foundation

/// Credencial Z.ai resolvida dos arquivos locais do ZCode — mantida em memória,
/// nunca logada (spec §9): este arquivo não tem print/log e nunca vai ter.
public struct ZaiCredential: Sendable, Equatable {
    /// `.provider["builtin:zai-coding-plan"].options.apiKey` de `config.json`
    /// (spec §2.2: mesmo tipo de credencial que o CLI consome no plano —
    /// ordem 1 para o endpoint de quota).
    public let apiKey: String?
    /// `oauth:zai:access_token` de `credentials.json` (ordem 2, fallback —
    /// spec §2.2; o aceite do OAuth no endpoint de quota não está verificado).
    public let oauthToken: String?
    /// Base canônica de quota detectada pelo host do `options.baseURL`
    /// (`api.z.ai` → global; `open.bigmodel.cn` → CN — spec §2.2/§2.7).
    /// `nil` = config ausente/host desconhecido (mantém a default global).
    public let regionBaseURL: URL?

    /// Alguma credencial utilizável (apiKey ou OAuth) — gate de
    /// `discoverAccounts`/`fetchUsage`.
    public var hasCredential: Bool { apiKey != nil || oauthToken != nil }
}

/// Leitor read-only dos dois arquivos de credencial do ZCode (spec §2.2). O CLI
/// pode rotacionar o token a qualquer momento — lê a cada chamada, nunca
/// escreve. Este arquivo não tem print/log e nunca vai ter (spec §9).
///
/// Overrides de testes/wiring:
/// - env `TOKENBAR_ZAI_CONFIG` → caminho do `config.json`
///   (default `~/.zcode/v2/config.json`)
/// - env `TOKENBAR_ZAI_AUTH` → caminho do `credentials.json`
///   (default `~/.zcode/v2/credentials.json`)
public struct ZaiCredentialReader: Sendable {
    public let configFileURL: URL
    public let credentialsFileURL: URL

    public init(configFileURL: URL, credentialsFileURL: URL) {
        self.configFileURL = configFileURL
        self.credentialsFileURL = credentialsFileURL
    }

    public static func resolve(environment: [String: String], home: URL) -> ZaiCredentialReader {
        func file(_ key: String, _ fallback: String) -> URL {
            if let raw = environment[key], !raw.isEmpty { return URL(filePath: raw) }
            return home.appendingPathComponent(fallback)
        }
        return ZaiCredentialReader(
            configFileURL: file("TOKENBAR_ZAI_CONFIG", ".zcode/v2/config.json"),
            credentialsFileURL: file("TOKENBAR_ZAI_AUTH", ".zcode/v2/credentials.json")
        )
    }

    public static func resolve() -> ZaiCredentialReader {
        resolve(
            environment: ProcessInfo.processInfo.environment,
            home: URL(filePath: NSHomeDirectory())
        )
    }

    /// Lê os dois arquivos. Nada utilizável (nenhum arquivo legível com
    /// apiKey/OAuth/baseURL) → `nil` = nenhuma conta visível. Arquivo
    /// ilegível como JSON → tratado como ausente, nunca crash.
    public func read() -> ZaiCredential? {
        let config = Self.readConfig(at: configFileURL)
        let oauth = Self.readOAuthToken(at: credentialsFileURL)
        let apiKey = config?.apiKey
        let region = config?.regionBaseURL
        if apiKey == nil && oauth == nil && region == nil { return nil }
        return ZaiCredential(apiKey: apiKey, oauthToken: oauth, regionBaseURL: region)
    }

    /// `credentials.json` é JSON PLANO com chaves contendo dois-pontos
    /// (`oauth:zai:access_token`, spec §2.2) — decoder tolerante por chave.
    static func readOAuthToken(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let file = try? Self.decoder.decode(FlatCredentials.self, from: data)
        else { return nil }
        return file.accessToken
    }

    /// `config.json` → `.provider[*-coding-plan].options.{apiKey, baseURL}`.
    /// Ordem de preferência da spec §2.2: `builtin:zai-coding-plan` (global) →
    /// `builtin:bigmodel-coding-plan` (CN). A primeira entrada COM apiKey define
    /// chave E região (pareamento); sem apiKey em nenhuma, a primeira região
    /// vista serve de hint para o fallback OAuth (spec §2.7: região errada → 404/401).
    static func readConfig(at url: URL) -> (apiKey: String?, regionBaseURL: URL?)? {
        guard let data = try? Data(contentsOf: url),
              let file = try? Self.decoder.decode(ConfigFile.self, from: data)
        else { return nil }
        let entries = [file.provider?.zai, file.provider?.bigmodel]

        var apiKey: String?
        var pairedRegion: URL?
        var firstRegion: URL?
        for entry in entries {
            guard let options = entry?.options else { continue }
            let region = options.baseURL.flatMap(Self.canonicalQuotaBase(fromHostURL:))
            if firstRegion == nil { firstRegion = region }
            if apiKey == nil, let key = options.apiKey {
                apiKey = key
                pairedRegion = region
            }
        }
        if apiKey == nil && firstRegion == nil { return nil }
        return (apiKey: apiKey, regionBaseURL: pairedRegion ?? firstRegion)
    }

    /// Host do `options.baseURL` (ex. `https://api.z.ai/api/anthropic`) → base
    /// canônica do endpoint de quota (spec §2.1): `*.z.ai` → global,
    /// `*.bigmodel.cn` → CN. Host desconhecido → `nil` (default global vale).
    static func canonicalQuotaBase(fromHostURL raw: String) -> URL? {
        guard let url = URL(string: raw), let host = url.host?.lowercased() else { return nil }
        if host.hasSuffix("bigmodel.cn") { return URL(string: "https://open.bigmodel.cn") }
        if host.hasSuffix("z.ai") { return URL(string: "https://api.z.ai") }
        return nil
    }

    // Decoder reutilizado (padrão F1: criar JSONDecoder por leitura custa caro;
    // uso é single-thread por provider). JSONDecoder é Sendable.
    private static let decoder = JSONDecoder()

    /// Tolerante: chaves ausentes, nulas ou de tipo inesperado não derrubam a
    /// leitura — campos viram `nil` e o provider degrada, nunca dado errado.
    private struct FlatCredentials: Decodable {
        let accessToken: String?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            accessToken = FlexibleJSON.string(c, "oauth:zai:access_token")
        }
    }

    private struct ConfigFile: Decodable {
        let provider: Providers?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            provider = try? c.decodeIfPresent(Providers.self, forKey: AnyKey("provider"))
        }

        struct Providers: Decodable {
            let zai: Entry?
            let bigmodel: Entry?

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: AnyKey.self)
                zai = try? c.decodeIfPresent(Entry.self, forKey: AnyKey("builtin:zai-coding-plan"))
                bigmodel = try? c.decodeIfPresent(Entry.self, forKey: AnyKey("builtin:bigmodel-coding-plan"))
            }

            struct Entry: Decodable {
                let options: Options?

                init(from decoder: Decoder) throws {
                    let c = try decoder.container(keyedBy: AnyKey.self)
                    options = try? c.decodeIfPresent(Options.self, forKey: AnyKey("options"))
                }

                struct Options: Decodable {
                    let apiKey: String?
                    let baseURL: String?

                    init(from decoder: Decoder) throws {
                        let c = try decoder.container(keyedBy: AnyKey.self)
                        apiKey = FlexibleJSON.string(c, "apiKey", "api_key")
                        baseURL = FlexibleJSON.string(c, "baseURL", "base_url")
                    }
                }
            }
        }
    }
}
