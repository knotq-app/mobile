import SwiftUI

struct SchemesScreen: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingNewScheme = false
    @State private var showingNewFolder = false

    var body: some View {
        List {
            if let root = model.snapshot?.root {
                ForEach(root.children) { node in
                    NodeRow(node: node)
                }
            }
        }
        .navigationTitle("Schemes")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showingNewScheme = true
                    } label: {
                        Label("Scheme", systemImage: "doc.badge.plus")
                    }
                    Button {
                        showingNewFolder = true
                    } label: {
                        Label("Folder", systemImage: "folder.badge.plus")
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingNewScheme) {
            NameSheet(title: "New Scheme", placeholder: "Scheme name", validator: { name in
                WorkspaceNameValidation.schemeError(name, root: model.snapshot?.root)
            }) { name in
                model.createScheme(name: name)
            }
        }
        .sheet(isPresented: $showingNewFolder) {
            NameSheet(title: "New Folder", placeholder: "Folder name", validator: { name in
                WorkspaceNameValidation.folderError(name, root: model.snapshot?.root)
            }) { name in
                model.createFolder(name: name)
            }
        }
        .refreshable { model.refresh() }
    }
}

struct NodeRow: View {
    @EnvironmentObject private var model: AppModel
    let node: MobileNode
    @State private var renameTarget: MobileNode?

    var body: some View {
        if node.kind == "folder" {
            DisclosureGroup {
                ForEach(node.children) { child in
                    NodeRow(node: child)
                }
            } label: {
                Label(node.name, systemImage: "folder")
            }
            .contextMenu {
                Button("Rename") { renameTarget = node }
                Button("Delete", role: .destructive) { model.deleteFolder(id: node.id) }
            }
            .sheet(item: $renameTarget) { node in
                NameSheet(title: "Rename Folder", placeholder: "Folder name", initialText: node.name, validator: { name in
                    WorkspaceNameValidation.folderError(name, root: model.snapshot?.root, excludingID: node.id)
                }) { name in
                    model.renameFolder(id: node.id, name: name)
                }
            }
        } else {
            NavigationLink {
                SchemeEditorView(schemeID: node.id)
            } label: {
                HStack(spacing: 12) {
                    Circle()
                        .fill(colorForIndex(node.colorIndex))
                        .frame(width: 10, height: 10)
                    Text(node.name)
                    Spacer()
                }
            }
        }
    }
}
