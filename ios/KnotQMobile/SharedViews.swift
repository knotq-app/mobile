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
                    .disabled(text.isEmpty || error != nil)
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
        "Archive \(kind.label)"
    }

    var confirmTitle: String {
        "Archive \(kind.label)"
    }

    var message: String {
        switch kind {
        case .folder:
            return "\"\(name)\" and its schemes will move to Archive."
        case .scheme:
            return "\"\(name)\" will move to Archive."
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
        confirmationDialog(
            selection.wrappedValue?.title ?? "Archive",
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
        nodeError(name, label: "Scheme", disallowKnotqExtension: true)
    }

    static func schemeError(_ name: String, root: MobileNode?, folderID: String? = nil, excludingID: String? = nil) -> String? {
        if let error = schemeError(name) {
            return error
        }
        guard let root else { return nil }
        let parentID = folderID ?? parentFolderID(containingSchemeID: excludingID, root: root) ?? root.id
        if siblingExists(named: name, kind: "scheme", parentID: parentID, root: root, excludingID: excludingID) {
            return "A scheme named \"\(name)\" already exists here."
        }
        return nil
    }

    static func folderError(_ name: String) -> String? {
        nodeError(name, label: "Folder", disallowKnotqExtension: false)
    }

    static func folderError(_ name: String, root: MobileNode?, excludingID: String? = nil) -> String? {
        if let error = folderError(name) {
            return error
        }
        guard let root else { return nil }
        if siblingExists(named: name, kind: "folder", parentID: root.id, root: root, excludingID: excludingID) {
            return "A folder named \"\(name)\" already exists here."
        }
        return nil
    }

    static func parentFolderID(containingSchemeID schemeID: String?, root: MobileNode?) -> String? {
        guard let schemeID, let root else { return nil }
        return parentFolderID(containingSchemeID: schemeID, in: root)
    }

    private static func nodeError(_ name: String, label: String, disallowKnotqExtension: Bool) -> String? {
        if name.isEmpty {
            return "\(label) name cannot be empty."
        }
        if name.trimmingCharacters(in: .whitespacesAndNewlines) != name {
            return "File or directory name contains leading or trailing whitespace."
        }
        if name == "." || name == ".." {
            return "File or directory name cannot be . or ..."
        }
        if name.hasSuffix(".") {
            return "File or directory name cannot end with a period."
        }
        if name.contains("/") || name.contains("\\") {
            return "File or directory name cannot contain path separators."
        }
        let reservedCharacters = CharacterSet(charactersIn: ":*?\"<>|")
        if let scalar = name.unicodeScalars.first(where: { reservedCharacters.contains($0) }) {
            return "File or directory name cannot contain \"\(Character(scalar))\"."
        }
        if name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return "File or directory name cannot contain control characters."
        }
        let reservedNames: Set<String> = [
            "CON", "PRN", "AUX", "NUL",
            "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
            "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"
        ]
        if name.hasPrefix(".") || reservedNames.contains(name.uppercased()) {
            return "\"\(name)\" is reserved by the operating system."
        }
        if disallowKnotqExtension && name.lowercased().hasSuffix(".knotq") {
            return "Item names cannot end in .knotq."
        }
        return nil
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

    private static func siblingExists(named name: String, kind: String, parentID: String, root: MobileNode, excludingID: String?) -> Bool {
        guard let parent = node(id: parentID, in: root) else { return false }
        return parent.children.contains { child in
            child.kind == kind
                && child.id != excludingID
                && child.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }

    private static func node(id: String, in node: MobileNode) -> MobileNode? {
        if node.id == id {
            return node
        }
        for child in node.children {
            if let found = self.node(id: id, in: child) {
                return found
            }
        }
        return nil
    }
}

enum MobileDate {
    private static func dateOnlyFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private static func shortDayFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }

    private static func fullDayFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d"
        return formatter
    }

    private static func timeFormatter(timeFormat: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if timeFormat == "twenty_four_hour" {
            formatter.dateFormat = "HH:mm"
        } else {
            formatter.dateFormat = "h:mm a"
        }
        return formatter
    }

    private static func isoFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    static func formatDay(_ raw: String) -> String {
        guard let date = dateOnlyFormatter().date(from: raw) else { return raw }
        return shortDayFormatter().string(from: date)
    }

    static func formatFullDay(_ raw: String) -> String {
        guard let date = dateOnlyFormatter().date(from: raw) else { return raw }
        return fullDayFormatter().string(from: date)
    }

    static func formatTime(_ raw: String?, timeFormat: String = "twelve_hour") -> String? {
        guard let raw, let date = isoFormatter().date(from: raw) else { return nil }
        return timeFormatter(timeFormat: timeFormat).string(from: date)
    }

    static func parseDateTime(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        return isoFormatter().date(from: raw)
    }
}
