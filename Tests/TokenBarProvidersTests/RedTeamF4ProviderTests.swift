import Foundation
import Testing
import TokenBarCore
@testable import TokenBarProviders

// ============================================================================
// Red Team F4 (Task 4) — Caso 4: paths de credencial hostis nos READERS.
// FIFO sem escritor bloquearia `Data(contentsOf:)` para sempre (hang do
// ciclo); device (POSIX special) e diretório não são conteúdo. Com o guard
// `FileKind.isRegularFile` TODOS degradam `nil` — finito e sem crash.
// (Sem o guard, o caso FIFO penduraria esta suíte: a prova vermelha é por
// inspeção do open(2), não por timeout de teste.)
// ============================================================================
@Suite
struct RedTeamF4ProviderTests {
    @Test("readers de credencial: FIFO/diretório/device/quebrado → nil (nunca bloqueia)")
    func hostileCredentialPathsDegradeToNil() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rt-f4-cred-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fifo = dir.appendingPathComponent("auth.fifo")
        mkfifo(fifo.path, 0o644)
        let subdir = dir.appendingPathComponent("dir-cred")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        let dangling = dir.appendingPathComponent("dangling.json")
        try FileManager.default.createSymbolicLink(
            at: dangling, withDestinationURL: dir.appendingPathComponent("missing.json"))
        let devNull = URL(filePath: "/dev/null")  // char device: existe, não é regular

        let codexReader = CodexAuthReader(authFileURL: fifo)
        #expect(codexReader.read() == nil, "FIFO → nil imediato (guard regular file)")
        #expect(CodexAuthReader(authFileURL: subdir).read() == nil)
        #expect(CodexAuthReader(authFileURL: dangling).read() == nil)
        #expect(CodexAuthReader(authFileURL: devNull).read() == nil)

        let zai = ZaiCredentialReader(configFileURL: fifo, credentialsFileURL: fifo)
        #expect(zai.read() == nil)
        #expect(zai.read() == nil, "segunda chamada idem (nenhum estado, nenhum bloqueio)")
        #expect(
            ZaiCredentialReader(configFileURL: devNull, credentialsFileURL: devNull).read() == nil)

        // E o caminho legítimo segue funcionando (regressão do guard).
        let cred = dir.appendingPathComponent("auth.json")
        try Data(#"{"tokens":{"access_token":"fake-t","account_id":"a1"},"auth_mode":"chatgpt"}"#.utf8)
            .write(to: cred)
        let legit = CodexAuthReader(authFileURL: cred).read()
        #expect(legit?.accessToken == "fake-t")
    }
}
