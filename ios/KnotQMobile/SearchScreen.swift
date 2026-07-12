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
            model.search(query)
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
                Text(hit.title)
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

