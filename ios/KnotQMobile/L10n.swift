import Foundation

/// Catalog-key lookup over the generated `Localizable.xcstrings`
/// (see app/l10n/README.md; regenerate with `cargo run -p l10n-gen -- generate`).
///
/// Plain entries keep literal `{name}` placeholders that `t(_:_:)` substitutes;
/// plural entries carry `%lld` so the system picks the CLDR category.
enum L10n {
    static func t(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    static func t(_ key: String, _ args: [String: String]) -> String {
        var value = t(key)
        for (name, arg) in args {
            value = value.replacingOccurrences(of: "{\(name)}", with: arg)
        }
        return value
    }

    static func plural(_ key: String, _ count: Int) -> String {
        String.localizedStringWithFormat(NSLocalizedString(key, comment: ""), count)
    }
}
