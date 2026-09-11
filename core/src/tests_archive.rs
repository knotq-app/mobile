use super::*;

#[test]
fn archive_keeps_folder_hierarchy_and_restores_and_purges() {
    let dir = std::env::temp_dir().join(format!("knotq-mobile-test-{}", uuid::Uuid::new_v4()));
    let core = MobileCore::new(dir.display().to_string()).expect("open mobile core");

    core.create_folder(None, "Projects".to_string(), None)
        .expect("create folder");
    let snapshot = core.snapshot(None, 0).expect("snapshot");
    let folder = snapshot
        .root
        .children
        .iter()
        .find(|node| node.kind == "folder" && node.name == "Projects")
        .expect("folder in tree");
    let folder_id = folder.id.clone();

    core.create_scheme(Some(folder_id.clone()), "Nested".to_string(), Some(1), None)
        .expect("create nested scheme");

    // Archive the folder as one unit.
    core.delete_folder(folder_id.clone())
        .expect("archive folder");
    let snapshot = core.snapshot(None, 0).expect("snapshot after archive");
    assert!(
        !snapshot
            .root
            .children
            .iter()
            .any(|node| node.id == folder_id),
        "archived folder should leave the sidebar tree"
    );
    let archived_folder = snapshot
        .archived_nodes
        .iter()
        .find(|node| node.id == folder_id)
        .expect("folder appears in archived tree");
    assert_eq!(archived_folder.kind, "folder");
    assert!(
        archived_folder
            .children
            .iter()
            .any(|child| child.kind == "scheme" && child.name == "Nested"),
        "archived folder keeps its nested scheme"
    );

    // Restore brings the whole subtree back to the sidebar.
    core.restore_folder(folder_id.clone())
        .expect("restore folder");
    let snapshot = core.snapshot(None, 0).expect("snapshot after restore");
    assert!(
        snapshot
            .root
            .children
            .iter()
            .any(|node| node.id == folder_id),
        "restored folder returns to the sidebar tree"
    );
    assert!(snapshot.archived_nodes.is_empty());

    // Re-archive then purge permanently.
    core.delete_folder(folder_id.clone())
        .expect("re-archive folder");
    core.permanently_delete_folder(folder_id.clone())
        .expect("purge folder");
    let snapshot = core.snapshot(None, 0).expect("snapshot after purge");
    assert!(snapshot.archived_nodes.is_empty());
    assert!(
        !snapshot
            .schemes
            .iter()
            .any(|scheme| scheme.name == "Nested"),
        "purged folder's schemes are gone"
    );

    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn restoring_a_nested_scheme_lifts_it_to_root_and_out_of_archive() {
    let dir = std::env::temp_dir().join(format!("knotq-mobile-test-{}", uuid::Uuid::new_v4()));
    let core = MobileCore::new(dir.display().to_string()).expect("open mobile core");

    core.create_folder(None, "Parent".to_string(), None)
        .expect("create folder");
    let snapshot = core.snapshot(None, 0).expect("snapshot");
    let folder_id = snapshot
        .root
        .children
        .iter()
        .find(|node| node.kind == "folder" && node.name == "Parent")
        .expect("folder")
        .id
        .clone();
    core.create_scheme(Some(folder_id.clone()), "Child".to_string(), Some(1), None)
        .expect("create nested scheme");
    let snapshot = core.snapshot(None, 0).expect("snapshot");
    let scheme_id = snapshot
        .schemes
        .iter()
        .find(|scheme| scheme.name == "Child")
        .expect("nested scheme")
        .id
        .clone();

    // Archive the whole folder, then restore only the nested scheme.
    core.delete_folder(folder_id.clone())
        .expect("archive folder");
    core.restore_scheme(scheme_id.clone())
        .expect("restore nested scheme");

    let snapshot = core.snapshot(None, 0).expect("snapshot after restore");
    // The scheme is back at the root, no longer under the archived folder.
    assert!(
        snapshot
            .root
            .children
            .iter()
            .any(|node| node.id == scheme_id),
        "restored scheme sits at the root"
    );
    let archived_folder = snapshot
        .archived_nodes
        .iter()
        .find(|node| node.id == folder_id)
        .expect("folder still archived");
    assert!(
        !contains_node(archived_folder, &scheme_id),
        "restored scheme is gone from the archived subtree"
    );
    assert!(
        !snapshot
            .archived_schemes
            .iter()
            .any(|scheme| scheme.id == scheme_id),
        "restored scheme is gone from the archive"
    );

    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn restoring_a_nested_folder_lifts_its_subtree_to_root() {
    let dir = std::env::temp_dir().join(format!("knotq-mobile-test-{}", uuid::Uuid::new_v4()));
    let core = MobileCore::new(dir.display().to_string()).expect("open mobile core");

    core.create_folder(None, "Outer".to_string(), None)
        .expect("create outer");
    let outer_id = core
        .snapshot(None, 0)
        .unwrap()
        .root
        .children
        .iter()
        .find(|node| node.name == "Outer")
        .unwrap()
        .id
        .clone();
    core.create_folder(Some(outer_id.clone()), "Inner".to_string(), None)
        .expect("create inner");
    let inner_id = core
        .snapshot(None, 0)
        .unwrap()
        .root
        .children
        .iter()
        .find(|node| node.id == outer_id)
        .unwrap()
        .children
        .iter()
        .find(|node| node.name == "Inner")
        .unwrap()
        .id
        .clone();
    core.create_scheme(Some(inner_id.clone()), "Deep".to_string(), Some(1), None)
        .expect("create deep scheme");

    core.delete_folder(outer_id.clone()).expect("archive outer");
    core.restore_folder(inner_id.clone())
        .expect("restore nested folder");

    let snapshot = core.snapshot(None, 0).expect("snapshot after restore");
    assert!(
        snapshot
            .root
            .children
            .iter()
            .any(|node| node.id == inner_id),
        "restored inner folder sits at the root"
    );
    assert!(
        snapshot.schemes.iter().any(|scheme| scheme.name == "Deep"),
        "the inner folder's scheme is no longer archived"
    );
    let archived_outer = snapshot
        .archived_nodes
        .iter()
        .find(|node| node.id == outer_id)
        .expect("outer still archived");
    assert!(
        !contains_node(archived_outer, &inner_id),
        "restored inner folder left the archived subtree"
    );

    let _ = std::fs::remove_dir_all(dir);
}

fn contains_node(node: &MobileNode, id: &str) -> bool {
    node.id == id || node.children.iter().any(|child| contains_node(child, id))
}
