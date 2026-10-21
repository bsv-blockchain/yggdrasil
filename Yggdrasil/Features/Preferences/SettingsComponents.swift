import SwiftUI

// Building blocks shared by the Settings panes, so every pane uses the same
// macOS idioms: a bordered source list with a +/− bar on the left, a grouped
// form for the selection on the right.

/// The list half of a list/detail pane: bordered list with the standard
/// +/− control bar attached underneath (as in System Settings and Xcode).
struct SettingsSourceList<Content: View>: View {
    let canRemove: Bool
    let addHelp: String
    let removeHelp: String
    let onAdd: () -> Void
    let onRemove: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            Divider()
            HStack(spacing: 0) {
                barButton("plus", help: addHelp, action: onAdd)
                Divider().frame(height: 14)
                barButton("minus", help: removeHelp, action: onRemove)
                    .disabled(!canRemove)
                Spacer()
            }
            .frame(height: 22)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
        .frame(width: 220)
    }

    private func barButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

/// The standard list/detail layout used by the Repositories, Agents and Hosts
/// panes.
struct SettingsListDetail<ListContent: View, Detail: View>: View {
    @ViewBuilder let list: () -> ListContent
    @ViewBuilder let detail: () -> Detail

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            list()
                .padding([.leading, .top, .bottom], 20)
            detail()
                .scrollContentBackground(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 700, height: 480)
        // One background behind the list column and the form, as in System
        // Settings; the grouped form otherwise paints its own.
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Shown on the right when nothing is selected.
struct SettingsEmptyDetail: View {
    let symbol: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.tertiary)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A form text field that saves on Return or when focus leaves it, like the
/// fields in System Settings. `onCommit` returns false to reject the value,
/// which puts the stored one back.
struct SettingsTextField: View {
    let title: String
    let prompt: String
    let value: String
    let onCommit: (String) -> Bool

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $draft, prompt: Text(prompt))
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit() }
            }
            .onAppear { draft = value }
            // Switching rows or Settings tabs removes the field without a
            // focus change; save what was typed rather than drop it.
            .onDisappear(perform: commit)
            .onChange(of: value) { _, newValue in draft = newValue }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != value else { return }
        if !onCommit(trimmed) {
            draft = value
        }
    }
}

/// A small sheet with a grouped form and Cancel / confirm buttons, used to
/// add items instead of alert-with-text-fields prompts.
struct SettingsAddSheet<Fields: View>: View {
    let title: String
    let confirmTitle: String
    let canConfirm: Bool
    let onConfirm: () -> Void
    @ViewBuilder let fields: () -> Fields
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    fields()
                } header: {
                    Text(title).font(.headline)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle) {
                    onConfirm()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canConfirm)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
