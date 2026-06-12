import SwiftUI

struct ArchiveNavigatorSection: View {
    @EnvironmentObject private var model: AppModel
    let schemes: [MobileScheme]
    let theme: KnotQTheme
    let compact: Bool
    @State private var expanded = false
    @State private var confirmEmptyArchive: DestructiveConfirmationTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 1 : 3) {
            Button {
                withAnimation(.snappy(duration: 0.18)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "archivebox")
                        .font(.system(size: compact ? 10 : 11, weight: .semibold))
                        .frame(width: compact ? 12 : 14)
                    Text("Archive")
                        .font(.system(size: compact ? 12 : 13, weight: .medium))
                    Spacer(minLength: 0)
                    if !schemes.isEmpty {
                        Text("\(schemes.count)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(theme.textMuted)
                    }
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(theme.textMuted)
                }
                .frame(height: compact ? 22 : 25)
                .padding(.horizontal, compact ? 6 : 8)
                .foregroundStyle(theme.textPrimary)
                .background(expanded ? theme.rowAlt : Color.clear, in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Empty Archive", systemImage: "trash", role: .destructive) {
                    confirmEmptyArchive = .emptyArchive(count: schemes.count)
                }
                .disabled(schemes.isEmpty)
            }

            if expanded {
                if schemes.isEmpty {
                    Text("No archived schemes")
                        .font(.system(size: compact ? 11 : 12))
                        .foregroundStyle(theme.textMuted)
                        .padding(.horizontal, compact ? 25 : 28)
                        .frame(height: compact ? 20 : 24)
                } else {
                    ForEach(schemes) { scheme in
                        ArchiveSchemeRow(scheme: scheme, theme: theme, compact: compact)
                    }
                }
            }
        }
        .destructiveConfirmation(target: $confirmEmptyArchive) { _ in
            model.emptyArchive()
        }
    }
}

struct ArchiveSchemeRow: View {
    @EnvironmentObject private var model: AppModel
    let scheme: MobileScheme
    let theme: KnotQTheme
    let compact: Bool
    @State private var confirmPermanentDelete: DestructiveConfirmationTarget?

    var body: some View {
        SwipeActionRow(
            actionWidth: compact ? 70 : 82,
            actionTint: theme.danger,
            allowsFullSwipe: false,
            action: { confirmPermanentDelete = .permanentlyDeleteScheme(scheme) }
        ) {
            Label("Delete", systemImage: "trash")
        } content: {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(schemeColor(scheme.colorIndex, dark: theme.isDark).opacity(0.7))
                    .frame(width: compact ? 9 : 10, height: compact ? 9 : 10)
                Text(scheme.displayName)
                    .font(.system(size: compact ? 12 : 13))
                    .foregroundStyle(theme.textMuted)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, compact ? 22 : 26)
            .padding(.trailing, compact ? 6 : 8)
            .frame(height: compact ? 22 : 25)
        }
        .contextMenu {
            Button("Restore", systemImage: "arrow.uturn.backward") {
                model.restoreScheme(id: scheme.id)
            }
            Button("Delete Permanently", systemImage: "trash", role: .destructive) {
                confirmPermanentDelete = .permanentlyDeleteScheme(scheme)
            }
        }
        .destructiveConfirmation(target: $confirmPermanentDelete) { _ in
            model.permanentlyDeleteScheme(id: scheme.id)
        }
    }
}

/// Pushed destinations within the settings detail stack. Value-based so the iPad
/// detail column can pop them programmatically when the sidebar selection changes.
enum SettingsRoute: Hashable {
    case archive
}

struct SettingsArchiveSection: View {
    let schemes: [MobileScheme]
    let theme: KnotQTheme

    var body: some View {
        Section {
            NavigationLink(value: SettingsRoute.archive) {
                HStack(spacing: 10) {
                    Label("Archived Items", systemImage: "archivebox")
                    Spacer(minLength: 0)
                    Text("\(schemes.count)")
                        .foregroundStyle(theme.textMuted)
                }
            }
        } header: {
            Text("Archive")
        }
        .listRowBackground(theme.bgModal)
    }
}

/// One flattened, depth-tagged row of the archive tree.
private struct ArchiveTreeRow: Identifiable {
    let node: MobileNode
    let depth: Int
    var id: String { node.id }
}

struct SettingsArchiveList: View {
    @EnvironmentObject private var model: AppModel
    let theme: KnotQTheme
    @State private var confirmEmptyArchive: DestructiveConfirmationTarget?

    var body: some View {
        Form {
            Section {
                if nodes.isEmpty {
                    Text("No archived items")
                        .foregroundStyle(theme.textMuted)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(rows) { row in
                        SettingsArchiveNodeRow(node: row.node, depth: row.depth, theme: theme)
                            .listRowSeparator(.hidden)
                    }
                    Button("Empty Archive", systemImage: "trash", role: .destructive) {
                        confirmEmptyArchive = .emptyArchive(count: archivedSchemeCount)
                    }
                    .listRowSeparator(.hidden)
                }
            }
            .listRowBackground(theme.bgModal)
        }
        .scrollContentBackground(.hidden)
        .background(theme.bgApp)
        .navigationTitle("Archive")
        .destructiveConfirmation(target: $confirmEmptyArchive) { _ in
            model.emptyArchive()
        }
    }

    private var nodes: [MobileNode] {
        model.snapshot?.archivedNodes ?? []
    }

    private var archivedSchemeCount: Int {
        model.snapshot?.archivedSchemes.count ?? 0
    }

    /// The whole archive tree, always expanded — folders are told apart by their
    /// icon, not a disclosure arrow.
    private var rows: [ArchiveTreeRow] {
        var out: [ArchiveTreeRow] = []
        flatten(nodes, depth: 0, into: &out)
        return out
    }

    private func flatten(_ nodes: [MobileNode], depth: Int, into out: inout [ArchiveTreeRow]) {
        for node in nodes {
            out.append(ArchiveTreeRow(node: node, depth: depth))
            if node.kind == "folder" {
                flatten(node.children, depth: depth + 1, into: &out)
            }
        }
    }
}

struct SettingsArchiveNodeRow: View {
    @EnvironmentObject private var model: AppModel
    let node: MobileNode
    let depth: Int
    let theme: KnotQTheme
    @State private var confirmPermanentDelete: DestructiveConfirmationTarget?

    private var isFolder: Bool { node.kind == "folder" }

    var body: some View {
        HStack(spacing: 10) {
            if isFolder {
                Image(systemName: "folder")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textMuted)
                    .frame(width: 13)
            } else {
                RoundedRectangle(cornerRadius: 2)
                    .fill(schemeColor(node.colorIndex ?? 0, dark: theme.isDark).opacity(0.72))
                    .frame(width: 11, height: 11)
            }
            Text(node.name.isEmpty ? (isFolder ? "Folder" : "Untitled") : node.name)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button("Restore") {
                restore()
            }
            .buttonStyle(.borderless)
        }
        .padding(.leading, CGFloat(depth) * 16)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Restore", systemImage: "arrow.uturn.backward") {
                restore()
            }
            Button("Delete Permanently", systemImage: "trash", role: .destructive) {
                confirmPermanentDelete = deleteTarget
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                confirmPermanentDelete = deleteTarget
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .destructiveConfirmation(target: $confirmPermanentDelete) { _ in
            permanentlyDelete()
        }
    }

    private var deleteTarget: DestructiveConfirmationTarget {
        isFolder
            ? .permanentlyDeleteArchivedFolder(name: node.name, id: node.id)
            : .permanentlyDeleteArchivedScheme(name: node.name, id: node.id)
    }

    private func restore() {
        if isFolder {
            model.restoreFolder(id: node.id)
        } else {
            model.restoreScheme(id: node.id)
        }
    }

    private func permanentlyDelete() {
        if isFolder {
            model.permanentlyDeleteFolder(id: node.id)
        } else {
            model.permanentlyDeleteScheme(id: node.id)
        }
    }
}
