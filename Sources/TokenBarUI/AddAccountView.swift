import AppKit
import SwiftUI
import TokenBarCore

/// Formulário "+ Add account" (F4): label + credential file (lido read-only
/// pelo provider no ciclo — nunca escrito/logado) + data directory opcional
/// (contas com corpus próprio; vazio = conta API-only). Paths via NSTextField
/// com botão Choose… (NSOpenPanel exige app ativo — a janela própria do form
/// garante app ativo, ao contrário de um sheet solto no MenuBarExtra).
/// Validação em tempo real por `AddAccountForm.validate` (pura/testável):
/// vazio bloqueia Add; inexistente só avisa (a conta degrada com badge).
public struct AddAccountView: View {
    let provider: ProviderID
    let model: AccountsModel
    /// Chamado após Add (ou Cancel) para fechar a janela hospedeira.
    let onClose: () -> Void

    @State private var label = ""
    @State private var credentialPath = ""
    @State private var directoryPath = ""

    public init(provider: ProviderID, model: AccountsModel, onClose: @escaping () -> Void) {
        self.provider = provider
        self.model = model
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add \(MenuBarContent.displayName(for: provider)) account")
                .font(.headline)

            Form {
                TextField("Label", text: $label)
                    .accessibilityLabel("Account label")
                HStack(spacing: 6) {
                    TextField("Credential file (read-only)", text: $credentialPath)
                        .accessibilityLabel("Credential file path")
                    Button("Choose…") { pickPath(directory: false) }
                }
                HStack(spacing: 6) {
                    TextField("Data directory (optional)", text: $directoryPath)
                        .accessibilityLabel("Data directory path")
                    Button("Choose…") { pickPath(directory: true) }
                }
            }

            ForEach(validation.blocking, id: \.self) { message in
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(validation.warnings, id: \.self) { message in
                Text(message).font(.caption).foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel") { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Account") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!validation.isAddable)
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    private var validation: AddAccountForm.Validation {
        // Raízes em uso (canônica + dirs de contas registradas) alimentam o
        // guard de overlap — dir sobreposta é registro BLOQUEADO (review T3).
        AddAccountForm.validate(
            label: label, credentialPath: credentialPath, directoryPath: directoryPath,
            existingScanRoots: model.existingScanRoots(provider: provider))
    }

    private func add() {
        guard validation.isAddable else { return }
        _ = try? model.add(
            provider: provider, label: label,
            credentialPath: credentialPath, directoryPath: directoryPath)
        onClose()
    }

    /// NSOpenPanel pede app ativo; a janela do form garante isso (o MenuBarExtra
    /// estilo .window não ativa o app por si — por isso o form tem janela).
    private func pickPath(directory: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directory
        panel.canChooseFiles = !directory
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if directory {
            directoryPath = url.path
        } else {
            credentialPath = url.path
        }
    }
}
