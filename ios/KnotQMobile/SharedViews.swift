import SwiftUI

struct NameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let placeholder: String
    let initialText: String
    let validator: ((String) -> String?)?
    let onSave: (String) -> Void
    @State private var text: String
    @State private var error: String?

    init(
        title: String,
        placeholder: String,
        initialText: String = "",
        validator: ((String) -> String?)? = nil,
        onSave: @escaping (String) -> Void
    ) {
        self.title = title
        self.placeholder = placeholder
        self.initialText = initialText
        self.validator = validator
        self.onSave = onSave
        _text = State(initialValue: initialText)
        _error = State(initialValue: validator?(initialText))
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(placeholder, text: $text)
                    .onChange(of: text) { _, value in
                        error = validator?(value)
                    }
                if let error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let validationError = validator?(text)
                        error = validationError
                        guard validationError == nil else { return }
                        onSave(text)
                        dismiss()
                    }
                    .disabled(error != nil)
                }
            }
        }
    }
}

struct ArchiveTarget: Identifiable, Equatable {
    enum Kind: String {
        case folder
        case scheme

        var label: String {
            switch self {
            case .folder: "Folder"
            case .scheme: "Scheme"
            }
        }
    }

    let id: String
    let name: String
    let kind: Kind

    static func folder(_ node: MobileNode) -> ArchiveTarget {
        ArchiveTarget(id: node.id, name: node.name, kind: .folder)
    }

    static func scheme(_ node: MobileNode) -> ArchiveTarget {
        ArchiveTarget(id: node.id, name: node.name, kind: .scheme)
    }

    static func scheme(_ scheme: MobileScheme) -> ArchiveTarget {
        ArchiveTarget(id: scheme.id, name: scheme.displayName, kind: .scheme)
    }

    var title: String {
        "Move to Archive?"
    }

    var confirmTitle: String {
        "Move to Archive"
    }

    var message: String {
        switch kind {
        case .folder:
            return "\"\(name)\" and its schemes will be moved out of the sidebar. You can restore them later from Archive."
        case .scheme:
            return "\"\(name)\" will be moved out of the sidebar. You can restore it later from Archive."
        }
    }
}

struct DestructiveConfirmationTarget: Identifiable, Equatable {
    let id: String
    let title: String
    let message: String
    let confirmTitle: String

    static func permanentlyDeleteScheme(_ scheme: MobileScheme) -> DestructiveConfirmationTarget {
        DestructiveConfirmationTarget(
            id: "permanent-\(scheme.id)",
            title: "Delete Permanently",
            message: "\"\(scheme.displayName)\" will be removed from the archive permanently.",
            confirmTitle: "Delete Permanently"
        )
    }

    static func emptyArchive(count: Int) -> DestructiveConfirmationTarget {
        DestructiveConfirmationTarget(
            id: "empty-archive",
            title: "Empty Archive",
            message: count == 1
                ? "The archived scheme will be deleted permanently."
                : "\(count) archived schemes will be deleted permanently.",
            confirmTitle: "Empty Archive"
        )
    }
}

extension View {
    func archiveConfirmation(
        target selection: Binding<ArchiveTarget?>,
        onConfirm: @escaping (ArchiveTarget) -> Void
    ) -> some View {
        alert(
            selection.wrappedValue?.title ?? "Archive",
            isPresented: Binding(
                get: { selection.wrappedValue != nil },
                set: { isPresented in
                    if !isPresented {
                        selection.wrappedValue = nil
                    }
                }
            ),
            presenting: selection.wrappedValue
        ) { target in
            Button(target.confirmTitle) {
                onConfirm(target)
                selection.wrappedValue = nil
            }
            Button("Cancel", role: .cancel) {
                selection.wrappedValue = nil
            }
        } message: { target in
            Text(target.message)
        }
    }

    func destructiveConfirmation(
        target selection: Binding<DestructiveConfirmationTarget?>,
        onConfirm: @escaping (DestructiveConfirmationTarget) -> Void
    ) -> some View {
        confirmationDialog(
            selection.wrappedValue?.title ?? "Confirm",
            isPresented: Binding(
                get: { selection.wrappedValue != nil },
                set: { isPresented in
                    if !isPresented {
                        selection.wrappedValue = nil
                    }
                }
            ),
            titleVisibility: .visible,
            presenting: selection.wrappedValue
        ) { target in
            Button(target.confirmTitle, role: .destructive) {
                onConfirm(target)
                selection.wrappedValue = nil
            }
            Button("Cancel", role: .cancel) {
                selection.wrappedValue = nil
            }
        } message: { target in
            Text(target.message)
        }
    }
}

enum WorkspaceNameValidation {
    static func schemeError(_ name: String) -> String? {
        nil
    }

    static func schemeError(_ name: String, root: MobileNode?, folderID: String? = nil, excludingID: String? = nil) -> String? {
        return nil
    }

    static func folderError(_ name: String) -> String? {
        nil
    }

    static func folderError(_ name: String, root: MobileNode?, excludingID: String? = nil) -> String? {
        return nil
    }

    static func parentFolderID(containingSchemeID schemeID: String?, root: MobileNode?) -> String? {
        guard let schemeID, let root else { return nil }
        return parentFolderID(containingSchemeID: schemeID, in: root)
    }

    private static func parentFolderID(containingSchemeID schemeID: String, in node: MobileNode) -> String? {
        for child in node.children {
            if child.kind == "scheme", child.id == schemeID {
                return node.id
            }
            if child.kind == "folder", let found = parentFolderID(containingSchemeID: schemeID, in: child) {
                return found
            }
        }
        return nil
    }
}
