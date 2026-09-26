//! Cold-start resync profiling harness.
//!
//! Not a correctness test: `cold_start_resync_profile` is `#[ignore]`d and
//! exists to answer "where does the very first sync on a new device actually
//! spend its time" with a workspace shaped like a real, long-lived account
//! (~170 schemes, ~12.5k items, a few very large schemes). Run it with
//! `--ignored --nocapture`.

use super::*;
use crate::tests_daily::MobileFuzzServer;
use knotq_model::NodeRef;

/// Scheme sizes matching the distribution measured on a real account:
/// median 22 items, p90 125, one ~3100-item monster.
fn realistic_scheme_sizes(count: usize) -> Vec<usize> {
    let mut sizes = Vec::with_capacity(count);
    for index in 0..count {
        let size = match index {
            0 => 3115,
            1 => 740,
            2 => 694,
            3 => 558,
            4 => 465,
            n if n < 17 => 125 + (n * 7) % 60,
            n if n < 60 => 22 + (n * 13) % 40,
            n => 3 + (n * 5) % 20,
        };
        sizes.push(size);
    }
    sizes
}

fn build_realistic_workspace(scheme_count: usize) -> Workspace {
    let mut workspace = Workspace::new();
    let root = workspace.root;
    for (index, size) in realistic_scheme_sizes(scheme_count).into_iter().enumerate() {
        let mut scheme = Scheme::new(format!("Scheme {index}"), (index % 8) as u8);
        for line in 0..size {
            let mut item = Item::new(format!(
                "scheme {index} line {line} — a realistic length of body text for one row"
            ));
            if line % 7 == 0 {
                item.marker = knotq_model::ItemMarker::Checkbox;
            }
            scheme.items.push(item);
        }
        let id = scheme.id;
        workspace
            .folders
            .get_mut(&root)
            .unwrap()
            .children
            .push(NodeRef::Scheme(id));
        workspace.schemes.insert(id, scheme);
    }
    workspace.canonicalize_personal_sync_identity(workspace.id);
    workspace.ensure_sync_metadata();
    workspace
}

struct Phase {
    at: std::time::Instant,
}

impl Phase {
    fn start() -> Self {
        Self {
            at: std::time::Instant::now(),
        }
    }

    fn lap(&mut self, label: &str) -> u128 {
        let elapsed = self.at.elapsed().as_millis();
        eprintln!("  {label}: {elapsed}ms");
        self.at = std::time::Instant::now();
        elapsed
    }
}

#[test]
#[ignore = "profiling harness; run with --ignored --nocapture"]
fn cold_start_resync_profile() {
    let scheme_count: usize = std::env::var("KNOTQ_PROFILE_SCHEMES")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(170);

    eprintln!("building a {scheme_count}-scheme workspace...");
    let mut setup = Phase::start();
    let initial = build_realistic_workspace(scheme_count);
    let item_count: usize = initial.schemes.values().map(|s| s.items.len()).sum();
    setup.lap("build workspace");
    let seed_crdt = WorkspaceCrdtDocuments::try_new(&initial).unwrap();
    setup.lap("seed CRDT build");
    let seed_states = seed_crdt.document_states();
    let state_bytes: usize = seed_states.values().map(|state| state.len()).sum();
    setup.lap("seed document_states");
    let server = MobileFuzzServer::seeded(&initial, &seed_states);
    setup.lap("seed server");
    eprintln!(
        "workspace: {} schemes, {item_count} items, {} documents, {:.1} MiB of CRDT state",
        initial.schemes.len(),
        seed_states.len(),
        state_bytes as f64 / (1024.0 * 1024.0)
    );

    let dir = std::env::temp_dir().join(format!(
        "knotq-mobile-cold-start-profile-{}",
        uuid::Uuid::new_v4()
    ));
    let mut inner = MobileCoreInner::open(dir.clone()).unwrap();

    eprintln!("cold-start pull:");
    let mut phase = Phase::start();
    let prelude = inner
        .try_prepare_cold_start_pull("http://127.0.0.1:8788", "test-bearer")
        .expect("prepare cold start")
        .expect("a fresh core must be cold-start eligible");
    phase.lap("prelude");

    let mut workspace = prelude.workspace_snapshot.clone();
    workspace.canonicalize_personal_sync_identity_with_change(initial.id);
    workspace.ensure_sync_metadata();
    let mut pulled_crdt = WorkspaceCrdtDocuments::empty(&workspace);
    let mut pulled_sync_state = prelude.sync_state_snapshot.clone();
    let outcome = knotq_sync::batch_pull_and_apply_with_persisted_integrity_vectors(
        &server,
        &mut pulled_crdt,
        &mut pulled_sync_state,
        workspace,
        prelude.replica_id,
        true,
        None,
    )
    .expect("cold start pull");
    let pull_ms = phase.lap("batch_pull_and_apply (network-free)");
    eprintln!(
        "    pull_requests={} documents={} changed={}",
        outcome.pull_requests,
        outcome.remote_documents_received,
        outcome.changed_documents.len()
    );

    inner
        .finish_cold_start_pull(
            initial.id,
            &mut pulled_crdt,
            &pulled_sync_state,
            &outcome.changed_documents,
            CachedAccountWorkspace::new(
                "http://127.0.0.1:8788".to_string(),
                "test-bearer".to_string(),
                initial.id,
            ),
        )
        .expect("finish cold start pull");
    let finish_ms = phase.lap("finish_cold_start_pull (merge into live)");

    // The ordinary cycle the cold start hands off to: push, saves, reindex.
    let mut sync_state = load_local_sync_state(&inner.workspace_path).unwrap_or_default();
    inner
        .run_sync_cycle_with_options(
            &server,
            &mut sync_state,
            initial.id,
            SyncCycleOptions {
                account_switched: false,
                prelude_workspace_changed: false,
                media_client: None,
                push_local_edits_first: false,
            },
        )
        .expect("handoff cycle");
    let handoff_ms = phase.lap("handoff run_sync_cycle (push + durable saves)");

    eprintln!(
        "    live workspace after resync: {} schemes",
        inner.workspace.schemes.len()
    );
    let scheme_files = std::fs::read_dir(dir.join("workspace").join("schemes"))
        .map(|entries| entries.count())
        .unwrap_or(0);
    let crdt_files = std::fs::read_dir(crdt_state_dir(&inner.workspace_path))
        .map(|entries| entries.count())
        .unwrap_or(0);
    eprintln!("    on disk: {scheme_files} scheme files, {crdt_files} crdt files");
    phase.lap("inspect disk");

    // A second cold open: what the user pays on the next launch, and the one
    // assertion that makes this more than a stopwatch — the whole download has
    // to still be there. See `cold_start_pull_is_durable_before_the_next_launch`
    // for the regression test proper.
    let reopened = MobileCoreInner::open(dir.clone()).unwrap();
    let reopen_ms = phase.lap("reopen (cold launch after resync)");
    assert_eq!(
        reopened.workspace.schemes.len(),
        initial.schemes.len(),
        "the resync must survive a relaunch"
    );

    eprintln!(
        "TOTAL cold-start resync: {}ms (pull {pull_ms} + finish {finish_ms} + handoff {handoff_ms}), reopen {reopen_ms}ms",
        pull_ms + finish_ms + handoff_ms
    );

    let _ = std::fs::remove_dir_all(&dir);
}

/// What repeated live flushes cost when the editor's id adoption keeps failing.
///
/// `flushLive` (iOS `SchemeEditorChrome`) sends the WHOLE item list every ~0.6 s
/// while the user types, and adopts the ids the core minted in the completion.
/// `adoptItemIDs` bails entirely when the paragraph count no longer matches the
/// returned item count — which is exactly what happens when the user keeps
/// typing during the async write. The line then stays id-less, so the next flush
/// presents it as a new draft again.
///
/// This records what the core does with that, since it is the shape behind
/// "the same edit happens multiple times".
#[test]
#[ignore = "diagnostic; run with --ignored --nocapture"]
fn repeated_flush_without_id_adoption() {
    let dir = std::env::temp_dir().join(format!("knotq-mobile-reflush-{}", uuid::Uuid::new_v4()));
    let mut inner = MobileCoreInner::open(dir.clone()).unwrap();

    let mut scheme = Scheme::new("Typing", 0);
    scheme.items.push(Item::new("existing line"));
    let scheme_id = scheme.id;
    let root = inner.workspace.root;
    inner
        .workspace
        .folders
        .get_mut(&root)
        .unwrap()
        .children
        .push(knotq_model::NodeRef::Scheme(scheme_id));
    inner.workspace.schemes.insert(scheme_id, scheme);
    inner.workspace.ensure_sync_metadata();

    let draft = |id: Option<String>, text: &str| MobileItemEdit {
        id,
        text: text.to_string(),
        marker: "blank".to_string(),
        indent: 0,
        done: false,
        start: None,
        end: None,
        notification_offset_secs: None,
        repeat_rule: None,
        media: Vec::new(),
        content: Vec::new(),
    };

    let existing_id = inner.workspace.schemes[&scheme_id].items[0].id.to_string();
    let mut seen_ids: Vec<String> = Vec::new();

    // Five flushes of the same two lines, where the second line never gets its
    // id adopted back into the editor -- so every flush presents it id-less.
    for round in 0..5 {
        inner
            .replace_scheme_items(
                scheme_id,
                vec![
                    draft(Some(existing_id.clone()), "existing line"),
                    draft(None, "the line being typed"),
                ],
            )
            .expect("flush");
        let items = &inner.workspace.schemes[&scheme_id].items;
        let new_id = items[1].id.to_string();
        eprintln!(
            "  flush {round}: {} item(s), typed line id = {}",
            items.len(),
            &new_id[..8]
        );
        seen_ids.push(new_id);
    }

    let distinct: std::collections::HashSet<&String> = seen_ids.iter().collect();
    eprintln!(
        "\n  items after 5 flushes: {}",
        inner.workspace.schemes[&scheme_id].items.len()
    );
    eprintln!("  distinct ids minted for ONE typed line: {}", distinct.len());
    for (index, id) in seen_ids.iter().enumerate() {
        eprintln!("    flush {index}: {id}");
    }

    let _ = std::fs::remove_dir_all(&dir);
}

/// What a PEER sees while this device re-mints the line being typed.
///
/// Each failed adoption makes the next flush a delete-plus-insert in the CRDT,
/// so the line the user is on churns through a new item id every ~0.6 s. This
/// drives that against the in-memory backend with a second device syncing, and
/// reports what both ends hold.
#[test]
#[ignore = "diagnostic; run with --ignored --nocapture"]
fn repeated_flush_churn_as_a_peer_sees_it() {
    use crate::tests_daily::MobileFuzzServer;

    let root = std::env::temp_dir().join(format!("knotq-mobile-churn-{}", uuid::Uuid::new_v4()));
    let dir_a = root.join("a");
    let dir_b = root.join("b");

    let mut initial = Workspace::new();
    let mut scheme = Scheme::new("Typing", 0);
    scheme.items.push(Item::new("existing line"));
    let scheme_id = scheme.id;
    let workspace_root = initial.root;
    initial
        .folders
        .get_mut(&workspace_root)
        .unwrap()
        .children
        .push(knotq_model::NodeRef::Scheme(scheme_id));
    initial.schemes.insert(scheme_id, scheme);
    initial.canonicalize_personal_sync_identity(initial.id);
    initial.ensure_sync_metadata();

    let seed_crdt = WorkspaceCrdtDocuments::try_new(&initial).unwrap();
    let seed_states = seed_crdt.document_states();
    let server = MobileFuzzServer::seeded(&initial, &seed_states);

    for dir in [&dir_a, &dir_b] {
        let workspace_path = dir.join("workspace").join("workspace.json");
        save_workspace(&workspace_path, &initial).unwrap();
        save_crdt_state(&workspace_path, &seed_states).unwrap();
    }
    let mut dev_a = MobileCoreInner::open(dir_a.clone()).unwrap();
    let mut dev_b = MobileCoreInner::open(dir_b.clone()).unwrap();

    let draft = |id: Option<String>, text: &str| MobileItemEdit {
        id,
        text: text.to_string(),
        marker: "blank".to_string(),
        indent: 0,
        done: false,
        start: None,
        end: None,
        notification_offset_secs: None,
        repeat_rule: None,
        media: Vec::new(),
        content: Vec::new(),
    };
    let existing_id = dev_a.workspace.schemes[&scheme_id].items[0].id.to_string();

    let sync = |label: &str, dev: &mut MobileCoreInner, server: &MobileFuzzServer| {
        let mut state = load_local_sync_state(&dev.workspace_path).unwrap_or_default();
        let result = dev.run_sync_cycle_with_options(
            server,
            &mut state,
            initial.id,
            SyncCycleOptions {
                account_switched: false,
                prelude_workspace_changed: false,
                media_client: None,
                push_local_edits_first: false,
            },
        );
        if let Err(error) = &result {
            eprintln!("  sync({label}) FAILED: {error}");
        }
    };

    // Device A types one line. `KNOTQ_CLIENT_MINTS_ID=1` models the fix: the
    // editor mints the line's id up front and sends the same one every flush,
    // instead of leaving it nil and relying on adopting the core's.
    let client_id = std::env::var_os("KNOTQ_CLIENT_MINTS_ID")
        .map(|_| uuid::Uuid::new_v4().to_string());
    for _ in 0..5 {
        dev_a
            .replace_scheme_items(
                scheme_id,
                vec![
                    draft(Some(existing_id.clone()), "existing line"),
                    draft(client_id.clone(), "the line being typed"),
                ],
            )
            .expect("flush");
        sync("A", &mut dev_a, &server);
    }
    sync("B", &mut dev_b, &server);
    sync("A", &mut dev_a, &server);
    sync("B", &mut dev_b, &server);

    for (label, dev) in [("A (typing)", &dev_a), ("B (peer)", &dev_b)] {
        let items = &dev.workspace.schemes[&scheme_id].items;
        eprintln!("\n  device {label}: {} item(s)", items.len());
        for item in items {
            eprintln!(
                "    {} {:?}",
                &item.id.to_string()[..8],
                item.content.as_text().unwrap_or_default()
            );
        }
        let typed = items
            .iter()
            .filter(|i| i.content.as_text() == Some("the line being typed"))
            .count();
        eprintln!("    copies of the typed line: {typed}");
    }

    let bytes: usize = dev_a.crdt.document_states().values().map(|s| s.len()).sum();
    eprintln!("\n  device A CRDT bytes after 5 flushes of one line: {bytes}");

    let _ = std::fs::remove_dir_all(&root);
}
