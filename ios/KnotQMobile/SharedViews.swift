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

enum WorkspaceNameValidation {
    static func schemeError(_ name: String) -> String? {
        nodeError(name, label: "Item", disallowKnotqExtension: true)
    }

    static func folderError(_ name: String) -> String? {
        nodeError(name, label: "Folder", disallowKnotqExtension: false)
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
        if timeFormat == "twenty_four_hour" {
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "HH:mm"
        } else {
            formatter.timeStyle = .short
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
}
