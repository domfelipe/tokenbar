import Foundation

/// Classificação defensiva de paths (F4 Red Team caso 4): "o path existe" NÃO
/// basta para caminhos que o app vai LER no ciclo. FIFO/named pipe SEM
/// escritor bloqueia `open()` PARA SEMPRE — `Data(contentsOf:)` pendura a
/// thread que lê (o fetch da conta nunca volta; o ciclo do provider fica
/// preso em `inFlight`). Device, diretório e socket também não são conteúdo
/// de credencial. Regular file é o único tipo com leitura `Data(contentsOf:)`
/// segura e finita.
///
/// Symlinks são RESOLVIDOS pelo FileManager (`attributesOfItem` segue o
/// link, mesmo contrato de `fileExists`): link → auth.json real continua
/// válido; link quebrado → false (inválido).
public enum FileKind {
    /// `true` somente para arquivo regular existente (segue symlinks).
    ///
    /// `attributesOfItem(atPath:)` NÃO segue symlinks neste toolchain (o tipo
    /// do link volta `.typeSymbolicLink`), então a cadeia é resolvida ANTES
    /// com `resolvingSymlinksInPath` — a mesma base do guard de overlap.
    /// Link → auth.json real é regular ✓; link quebrado → o alvo não existe
    /// (false); link → FIFO continua false (o tipo final é o do alvo real).
    public static func isRegularFile(atPath path: String) -> Bool {
        let resolved = (path as NSString).resolvingSymlinksInPath
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: resolved) else {
            return false
        }
        return attrs[.type] as? FileAttributeType == .typeRegular
    }

    /// `true` somente para diretório existente (segue symlinks).
    public static func isDirectory(atPath path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            return false
        }
        return isDir.boolValue
    }
}
