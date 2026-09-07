# KnotQ mobile (shared Rust core + iOS/Android shells)

## Deployment gate — run the sync stress suite before ANY store submission

**Before an App Store or Play submission — or any change to `core/`'s sync path
(`mobile_core_inner_ops.rs`, `ws_sync.rs`, `crdt_changes.rs`, the shared
`knotq-sync` crate) — the full sync-convergence stress suite MUST pass.** Sync
bugs that revert a user's edits, wedge a device, or drop a Daily Queue are this
project's worst failure class; every one was found by fuzzing, not by hand.

From this repo:

```sh
cargo test -p knotq-mobile-core --features accounts
# the disk-backed two-device fuzz + lazy-daily lifecycle fuzz + recovery tests
KNOTQ_FUZZ_SEEDS=1 KNOTQ_FUZZ_STEPS=1024 \
  cargo test -p knotq-mobile-core --features accounts \
  tests::seeded_lazy_daily_lifecycle_fuzz_converges_before_navigation
```

And the shared-engine suite from the app checkout (`../` → `app/`):

```sh
cd ..
./.github/scripts/run-sync-stress.sh --fuzz
KNOTQ_FUZZ_SEEDS=800 KNOTQ_FUZZ_STEPS=400 \
  cargo test -p knotq-sync --test sync_property_model --release
```

The mobile fuzz drives the PRODUCTION method `MobileCoreInner::run_sync_cycle`
(the same code `sync_once` runs after its HTTP prelude) against an in-memory
backend that merges via the real engine. When you change the sync path, extend
that fuzz rather than writing a bespoke reproduction.

See `../CLAUDE.md` and `../AGENTS.md` for the full rule.
