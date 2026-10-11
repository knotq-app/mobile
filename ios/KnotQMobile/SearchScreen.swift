import SwiftUI

struct SearchScreen: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""

    var body: some View {
        List {
            ForEach(model.searchHits) { hit in
                if let schemeID = hit.schemeId {
                    NavigationLink {
                        SchemeEditorView(schemeID: schemeID)
                    } label: {
                        SearchHitRow(hit: hit)
                    }
                } else {
                    SearchHitRow(hit: hit)
                }
            }
        }
        .navigationTitle(L10n.t("mobile.search.screen_title"))
        .searchable(text: $query, prompt: L10n.t("mobile.search.screen_title"))
        .onChange(of: query) { _, value in
            model.search(value)
        }
        .onAppear {
            model.search(query, debounce: false)
        }
    }
}

struct SearchHitRow: View {
    let hit: MobileSearchHit

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(colorForIndex(hit.colorIndex))
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 4) {
                Text(searchPreviewText(hit.title))
                HStack {
                    Text(hit.schemeName)
                    Text(hit.detail)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

private let searchBlockPrefix = try! NSRegularExpression(pattern: #"^(?:#{1,6}\s+|>\s+)"#)
private let searchNamedLink = try! NSRegularExpression(pattern: #"\[([^\[\]]+)\]\((?:https?://|www\.|mailto:)[^\s)]+\)"#)
private let searchInlineMarker = try! NSRegularExpression(pattern: #"(?:\*\*|__|==|~~|`)"#)

/// Search indexes the stored line, so a hit's title can hold the markdown that
/// is kept on disk. A result is a preview, not an editor: drop the block and
/// inline syntax here so nobody reads delimiters as content. Only unambiguous
/// markers go — a lone `_` or `*` stays, since a title is as likely to be a
/// name like `my_file_name` as emphasis.
func searchPreviewText(_ raw: String) -> String {
    func stripped(_ text: String, _ regex: NSRegularExpression, _ template: String = "") -> String {
        regex.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: (text as NSString).length),
            withTemplate: template
        )
    }
    return raw.split(whereSeparator: \.isNewline)
        .map { line -> String in
            let body = line.trimmingCharacters(in: .whitespaces)
            if isMarkdownRule(body) { return "" }
            return stripped(stripped(stripped(body, searchBlockPrefix), searchNamedLink, "$1"), searchInlineMarker)
        }
        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        .joined(separator: " ")
}
