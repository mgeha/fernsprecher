import SwiftUI

struct NameEditor: View {
    @Environment(AppModel.self) private var model
    let number: String
    let name: String

    var body: some View {
        InputEditor(title: String(localized: "Name for \(number)"), placeholder: String(localized: "Name"),
                    text: name, saveLabel: String(localized: "Save")) {
            model.saveName($0, for: number)
            return true
        }
    }
}

/// Popover with one text field (name, forward target). Enter saves, Esc
/// cancels; `save` returns false to keep it open. Texts come localized.
struct InputEditor: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let placeholder: String
    let saveLabel: String
    let hint: String?
    let save: (String) -> Bool
    @ViewState private var text: String
    @FocusState private var focused: Bool

    init(title: String, placeholder: String, text: String, saveLabel: String, hint: String? = nil,
         save: @escaping (String) -> Bool) {
        self.title = title
        self.placeholder = placeholder
        self.saveLabel = saveLabel
        self.hint = hint
        self.save = save
        _text = ViewState(initialValue: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .focused($focused)
                .onSubmit(submit)
            if let hint {
                Text(hint)
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: 220, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(saveLabel, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
        .onAppear { focused = true }
    }

    private func submit() {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty, save(text) else { return }
        dismiss()
    }
}

struct NameMenu: View {
    @Environment(AppModel.self) private var model
    let number: String
    let edit: () -> Void

    var body: some View {
        if model.addressBook.entry(for: number) == nil {
            Button("Save name …", action: edit)
        } else {
            Button("Rename …", action: edit)
            Button("Remove name") { model.removeName(for: number) }
        }
    }
}
