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

struct SettingsArchiveSection: View {
    let schemes: [MobileScheme]
    let theme: KnotQTheme

    var body: some View {
        Section {
            NavigationLink {
                SettingsArchiveList(theme: theme)
            } label: {
                HStack(spacing: 10) {
                    Label("Archived Schemes", systemImage: "archivebox")
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

struct SettingsArchiveList: View {
    @EnvironmentObject private var model: AppModel
    let theme: KnotQTheme
    @State private var confirmEmptyArchive: DestructiveConfirmationTarget?

    var body: some View {
        Form {
            Section {
                if schemes.isEmpty {
                    Text("No archived schemes")
                        .foregroundStyle(theme.textMuted)
                } else {
                    ForEach(schemes) { scheme in
                        SettingsArchiveRow(scheme: scheme, theme: theme)
                    }
                    Button("Empty Archive", systemImage: "trash", role: .destructive) {
                        confirmEmptyArchive = .emptyArchive(count: schemes.count)
                    }
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

    private var schemes: [MobileScheme] {
        model.snapshot?.archivedSchemes ?? []
    }
}

struct SettingsArchiveRow: View {
    @EnvironmentObject private var model: AppModel
    let scheme: MobileScheme
    let theme: KnotQTheme
    @State private var confirmPermanentDelete: DestructiveConfirmationTarget?

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(schemeColor(scheme.colorIndex, dark: theme.isDark).opacity(0.72))
                .frame(width: 11, height: 11)
            Text(scheme.displayName)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button("Restore") {
                model.restoreScheme(id: scheme.id)
            }
            .buttonStyle(.borderless)
        }
        .contextMenu {
            Button("Restore", systemImage: "arrow.uturn.backward") {
                model.restoreScheme(id: scheme.id)
            }
            Button("Delete Permanently", systemImage: "trash", role: .destructive) {
                confirmPermanentDelete = .permanentlyDeleteScheme(scheme)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                confirmPermanentDelete = .permanentlyDeleteScheme(scheme)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .destructiveConfirmation(target: $confirmPermanentDelete) { _ in
            model.permanentlyDeleteScheme(id: scheme.id)
        }
    }
}
