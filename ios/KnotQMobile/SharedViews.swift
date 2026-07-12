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
                    Button(L10n.t("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("common.save")) {
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
            case .folder: L10n.t("sidebar.context.folder")
            case .scheme: L10n.t("mobile.archive.kind_scheme")
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
        L10n.t("mobile.archive.move_title")
    }

    var confirmTitle: String {
        L10n.t("mobile.archive.move_confirm")
    }

    var message: String {
        switch kind {
        case .folder:
            return L10n.t("mobile.archive.move_folder_message", ["name": name])
        case .scheme:
            return L10n.t("mobile.archive.move_scheme_message", ["name": name])
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
            title: L10n.t("mobile.archive.delete_permanently_title"),
            message: L10n.t("mobile.archive.delete_scheme_permanently_message", ["name": scheme.displayName]),
            confirmTitle: L10n.t("mobile.archive.delete_permanently_title")
        )
    }

    static func permanentlyDeleteArchivedScheme(name: String, id: String) -> DestructiveConfirmationTarget {
        DestructiveConfirmationTarget(
            id: "permanent-\(id)",
            title: L10n.t("mobile.archive.delete_permanently_title"),
            message: L10n.t("mobile.archive.delete_scheme_permanently_message", ["name": name]),
            confirmTitle: L10n.t("mobile.archive.delete_permanently_title")
        )
    }

    static func permanentlyDeleteArchivedFolder(name: String, id: String) -> DestructiveConfirmationTarget {
        DestructiveConfirmationTarget(
            id: "permanent-folder-\(id)",
            title: L10n.t("mobile.archive.delete_folder_permanently_title"),
            message: L10n.t("mobile.archive.delete_folder_permanently_message", ["name": name]),
            confirmTitle: L10n.t("mobile.archive.delete_permanently_title")
        )
    }

    static func emptyArchive(count: Int) -> DestructiveConfirmationTarget {
        DestructiveConfirmationTarget(
            id: "empty-archive",
            title: L10n.t("archive.empty_confirm_button"),
            message: L10n.plural("mobile.archive.empty_confirm_message", count),
            confirmTitle: L10n.t("archive.empty_confirm_button")
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
