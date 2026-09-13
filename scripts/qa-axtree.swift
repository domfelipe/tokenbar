import Foundation
import ApplicationServices

// Instrumento de QA do painel (13/09) — SEM captura de tela.
//
// Por que existe: a premissa antiga ("o painel do MenuBarExtra não expõe
// conteúdo ao AX") valia só para System Events, que não enumera as janelas
// deste app. A API de Acessibilidade DIRETA (AXUIElementCopyAttributeValue)
// devolve a árvore completa do painel aberto — textos, frames e botões — e o
// AXPress funciona neles. Foi assim que se provou, com o painel aberto, que a
// janela tinha 310x129pt e que "Usage dashboard" (y=398) ficava FORA dela
// (a janela ia até y=161); depois do fix, 310x489 com tudo dentro.
//
//   qa-axtree <pid> [profundidade]              → despeja a árvore
//   qa-axtree --panel <pid>                     → VERIFICA o painel (gate)
//   qa-axtree --windows <pid>                   → lista janelas (título/frame)
//   qa-axtree --press <pid> <rótulo>            → AXPress no 1º que casar
//   qa-axtree --wait-window <pid> <título> [s]  → espera uma janela com título
//
// Exige permissão de Acessibilidade para quem roda (o ui-smoke checa antes).
func axText(_ el: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attribute as CFString, &value) == .success,
          let value else { return nil }
    if let string = value as? String, !string.isEmpty { return string }
    if let number = value as? NSNumber { return number.stringValue }
    return nil
}

func axFrame(_ el: AXUIElement) -> CGRect? {
    var rawPosition: CFTypeRef?
    var rawSize: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &rawPosition) == .success,
          AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &rawSize) == .success,
          let positionValue = rawPosition, let sizeValue = rawSize,
          CFGetTypeID(positionValue) == AXValueGetTypeID(),
          CFGetTypeID(sizeValue) == AXValueGetTypeID()
    else { return nil }
    var origin = CGPoint.zero
    var size = CGSize.zero
    AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin)
    AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
    guard size.width > 0, size.height > 0 else { return nil }
    return CGRect(origin: origin, size: size)
}

func axChildren(_ el: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &value) == .success,
          let list = value as? [AXUIElement] else { return [] }
    return list
}

/// Todos os descendentes (largura primeiro), com teto de profundidade.
func axDescendants(_ el: AXUIElement, depth: Int = 0, max: Int = 12) -> [AXUIElement] {
    guard depth <= max else { return [] }
    return axChildren(el).flatMap { [$0] + axDescendants($0, depth: depth + 1, max: max) }
}

func axWindows(_ app: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
          let list = value as? [AXUIElement] else { return [] }
    return list
}

func describe(_ el: AXUIElement) -> String {
    let role = axText(el, kAXRoleAttribute as String) ?? "?"
    var line = role
    for (attribute, prefix) in [
        (kAXTitleAttribute as String, "title"), (kAXValueAttribute as String, "value"),
        (kAXDescriptionAttribute as String, "desc"), ("AXIdentifier", "id"),
    ] {
        if let text = axText(el, attribute) { line += " " + prefix + "=\"" + text + "\"" }
    }
    if let frame = axFrame(el) {
        line += String(format: " @(%.0f,%.0f) %.0fx%.0f", frame.minX, frame.minY, frame.width, frame.height)
    }
    return line
}

func dump(_ el: AXUIElement, depth: Int, max: Int) {
    guard depth <= max else { return }
    print(String(repeating: "  ", count: depth) + describe(el))
    for child in axChildren(el) { dump(child, depth: depth + 1, max: max) }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

/// Largura do cartão do painel (ProviderPanelView.panelWidth).
let panelWidth: CGFloat = 310
/// Piso do painel depois do fix: com a janela colapsada eram 129pt.
let panelMinimumHeight: CGFloat = 300
/// Ações e rodapé que precisam estar DENTRO da janela do painel.
let requiredPanelLabels = [
    "Add account…", "Usage dashboard", "Export",
    "Refresh", "Settings…", "About TokenBar", "Quit TokenBar",
]

let arguments = CommandLine.arguments
guard arguments.count > 2 else {
    fail("uso: qa-axtree <pid> [prof] | --panel <pid> | --windows <pid> | --press <pid> <rótulo> | --wait-window <pid> <título> [s]")
}
guard let pid = pid_t(arguments[2]) else { fail("pid inválido: " + arguments[2]) }
let app = AXUIElementCreateApplication(pid)
guard AXIsProcessTrusted() else { fail("sem permissão de Acessibilidade para este processo") }

switch arguments[1] {
case "--panel":
    // A janela do painel é a que tem a largura do cartão.
    guard let panel = axWindows(app).first(where: { axFrame($0)?.width == panelWidth }),
          let panelFrame = axFrame(panel)
    else { fail("painel não encontrado — abra o painel (clique no item da menu bar) antes de verificar") }
    print(String(format: "painel: %.0fx%.0f @(%.0f,%.0f)", panelFrame.width, panelFrame.height, panelFrame.minX, panelFrame.minY))
    var failures: [String] = []
    if panelFrame.height < panelMinimumHeight {
        failures.append("altura " + String(Int(panelFrame.height)) + "pt < piso " + String(Int(panelMinimumHeight)) + "pt (janela colapsada)")
    }
    let nodes = axDescendants(panel)
    for label in requiredPanelLabels {
        guard let node = nodes.first(where: { axText($0, kAXDescriptionAttribute as String) == label
            || axText($0, kAXTitleAttribute as String) == label })
        else {
            failures.append("ausente: " + label)
            continue
        }
        guard let frame = axFrame(node) else {
            failures.append("sem frame: " + label)
            continue
        }
        let inside = panelFrame.insetBy(dx: -1, dy: -1).contains(frame)
        print(String(format: "  %@ @(%.0f,%.0f) %.0fx%.0f %@", label, frame.minX, frame.minY, frame.width, frame.height,
                     inside ? "dentro" : "FORA DA JANELA"))
        if !inside {
            failures.append(label + " fora da janela (" + String(Int(frame.minY)) + "pt > " + String(Int(panelFrame.maxY)) + "pt)")
        }
    }
    if failures.isEmpty {
        print("PASS: painel " + String(Int(panelFrame.width)) + "x" + String(Int(panelFrame.height)) + " com " + String(requiredPanelLabels.count) + " itens dentro da janela")
    } else {
        for failure in failures { print("FAIL: " + failure) }
        exit(1)
    }
case "--windows":
    for window in axWindows(app) { print(describe(window)) }
case "--press":
    guard arguments.count > 3 else { fail("--press exige o rótulo") }
    let needle = arguments[3]
    guard let target = axDescendants(app).first(where: {
        axText($0, kAXDescriptionAttribute as String) == needle
            || axText($0, kAXTitleAttribute as String) == needle
    }) else { fail("elemento não encontrado: " + needle) }
    let result = AXUIElementPerformAction(target, kAXPressAction as CFString)
    guard result == .success else { fail("AXPress falhou em " + needle + ": " + String(result.rawValue)) }
    print("press ok: " + needle)
case "--wait-window":
    guard arguments.count > 3 else { fail("--wait-window exige o título") }
    let title = arguments[3]
    let deadline = Date().addingTimeInterval(arguments.count > 4 ? Double(arguments[4]) ?? 8 : 8)
    while Date() < deadline {
        if let window = axWindows(app).first(where: {
            (axText($0, kAXTitleAttribute as String) ?? "").contains(title)
        }) {
            print("janela ok: " + describe(window))
            exit(0)
        }
        usleep(400_000)
    }
    fail("janela \"" + title + "\" não apareceu")
default:
    dump(app, depth: 0, max: Int(arguments[1]) ?? 6)
}
