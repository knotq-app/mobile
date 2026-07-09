use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};

use anyhow::{anyhow, Context, Result};
use chrono::{DateTime, Duration, Utc};
use knotq_model::{
    DocumentId, ImageAssetFormat, ImageInline, Item, ItemContent, NotificationDefaults, Workspace,
};
use knotq_notifications::compute_due_notifications_with_lead_times;
use knotq_sync::{
    AccountStatusResponse, BatchPullRequest, BatchPullResponse, BatchPushRequest,
    BatchPushResponse, ErrorResponse, NotificationScheduleSnapshot, RegisterDeviceRequest,
    RegisterDeviceResponse, SyncTransport, MAX_SYNC_MEDIA_BYTES,
};
use sha2::{Digest, Sha256};

use crate::{mobile_notification_lead_times, MobileItemMedia, NOTIFICATION_HORIZON_DAYS};

// Sync HTTP transport + media asset upload/download/collection glue for the
// mobile core. None of these are part of the UniFFI surface.

pub(crate) fn mobile_media_to_item_media(
    media: &MobileItemMedia,
    image_assets_dir: &Path,
) -> Option<ImageInline> {
    if media.kind != "image" {
        return None;
    }
    let path = media.path.as_deref()?;
    let path = Path::new(path);
    let asset = path.file_stem()?.to_str()?.parse().ok()?;
    let format = parse_image_format(&media.format)?;
    if !path.starts_with(image_assets_dir) {
        return None;
    }
    Some(ImageInline {
        asset,
        format,
        width: media.width.and_then(|value| u32::try_from(value).ok()),
        height: media.height.and_then(|value| u32::try_from(value).ok()),
    })
}

fn parse_image_format(raw: &str) -> Option<ImageAssetFormat> {
    match raw {
        "png" => Some(ImageAssetFormat::Png),
        "jpeg" | "jpg" => Some(ImageAssetFormat::Jpeg),
        "webp" => Some(ImageAssetFormat::Webp),
        "gif" => Some(ImageAssetFormat::Gif),
        "svg" => Some(ImageAssetFormat::Svg),
        "bmp" => Some(ImageAssetFormat::Bmp),
        "tiff" => Some(ImageAssetFormat::Tiff),
        _ => None,
    }
}

pub(crate) struct MobileSyncHttpClient {
    pub(crate) api_base: String,
    pub(crate) bearer_token: String,
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
struct MobileSyncMediaAsset {
    document: DocumentId,
    asset: uuid::Uuid,
    format: ImageAssetFormat,
}

impl MobileSyncMediaAsset {
    fn image_name(self) -> String {
        format!("{}.{}", self.asset, self.format.extension())
    }
}
pub(crate) fn mobile_notification_schedule_snapshot(
    workspace: &Workspace,
    defaults: NotificationDefaults,
    now: DateTime<Utc>,
    sequence: u64,
) -> Result<NotificationScheduleSnapshot> {
    let window_start = DateTime::from_naive_utc_and_offset(
        now.date_naive()
            .and_hms_opt(0, 0, 0)
            .ok_or_else(|| anyhow!("midnight is not representable"))?,
        Utc,
    );
    let window_end = window_start + Duration::days(NOTIFICATION_HORIZON_DAYS);
    let mut notifications = compute_due_notifications_with_lead_times(
        workspace,
        mobile_notification_lead_times(defaults),
        window_start,
        window_end,
    );
    notifications.sort_by(|left, right| {
        left.fire_at
            .cmp(&right.fire_at)
            .then_with(|| left.key.cmp(&right.key))
    });

    let mut hasher = Sha256::new();
    hasher.update(b"knotq.notification_schedule.v1");
    hasher.update([0]);
    hasher.update(window_start.to_rfc3339().as_bytes());
    hasher.update([0]);
    hasher.update(window_end.to_rfc3339().as_bytes());
    for notification in &notifications {
        hasher.update([0]);
        let json = serde_json::to_vec(notification).unwrap_or_default();
        hasher.update(json);
    }
    let digest = hasher.finalize();
    let hash = digest.iter().map(|byte| format!("{byte:02x}")).collect();

    Ok(NotificationScheduleSnapshot {
        sequence,
        hash,
        window_start,
        window_end,
        occurrence_count: notifications.len(),
    })
}

impl MobileSyncHttpClient {
    pub(crate) fn account_status(&self) -> Result<AccountStatusResponse> {
        let url = format!("{}/v1/auth/account/status", self.api_base);
        self.get_json(&url)
    }

    pub(crate) fn register_device(
        &self,
        request: &RegisterDeviceRequest,
    ) -> Result<RegisterDeviceResponse> {
        let url = format!("{}/v1/sync/devices", self.api_base);
        self.post_json(&url, request)
    }

    fn upload_media_asset(&self, media: MobileSyncMediaAsset, bytes: &[u8]) -> Result<()> {
        let url = self.media_url(media);
        self.authorized(ureq::put(&url))
            .set("content-type", mobile_media_content_type(media.format))
            .send_bytes(bytes)
            .map_err(mobile_sync_http_error)?;
        Ok(())
    }

    fn download_media_asset(&self, media: MobileSyncMediaAsset) -> Result<Option<Vec<u8>>> {
        let url = self.media_url(media);
        let response = match self.authorized(ureq::get(&url)).call() {
            Ok(response) => response,
            Err(ureq::Error::Status(404, response)) => {
                let code = response
                    .into_json::<ErrorResponse>()
                    .map(|error| error.code)
                    .unwrap_or_else(|_| "404".to_string());
                if code == "not_found" {
                    return Ok(None);
                }
                return Err(anyhow!("sync backend rejected request: {code}"));
            }
            Err(error) => return Err(mobile_sync_http_error(error)),
        };
        let mut reader = response
            .into_reader()
            .take((MAX_SYNC_MEDIA_BYTES + 1) as u64);
        let mut bytes = Vec::new();
        reader
            .read_to_end(&mut bytes)
            .with_context(|| format!("read media response from {url}"))?;
        if bytes.len() > MAX_SYNC_MEDIA_BYTES {
            return Err(anyhow!(
                "sync backend returned image {} above the {} byte sync limit",
                media.image_name(),
                MAX_SYNC_MEDIA_BYTES
            ));
        }
        Ok(Some(bytes))
    }

    fn media_url(&self, media: MobileSyncMediaAsset) -> String {
        format!(
            "{}/v1/sync/documents/{}/media/{}",
            self.api_base,
            media.document,
            media.image_name()
        )
    }

    fn get_json<T: serde::de::DeserializeOwned>(&self, url: &str) -> Result<T> {
        self.authorized(ureq::get(url))
            .call()
            .map_err(mobile_sync_http_error)?
            .into_json()
            .with_context(|| format!("parse sync response from {url}"))
    }

    fn post_json<T, R>(&self, url: &str, body: &T) -> Result<R>
    where
        T: serde::Serialize,
        R: serde::de::DeserializeOwned,
    {
        self.authorized(ureq::post(url))
            .send_json(serde_json::to_value(body)?)
            .map_err(mobile_sync_http_error)?
            .into_json()
            .with_context(|| format!("parse sync response from {url}"))
    }

    fn authorized(&self, request: ureq::Request) -> ureq::Request {
        request
            .timeout(std::time::Duration::from_secs(30))
            .set("authorization", &format!("Bearer {}", self.bearer_token))
    }
}

impl SyncTransport for MobileSyncHttpClient {
    fn pull(&self, request: &BatchPullRequest) -> Result<BatchPullResponse> {
        let url = format!("{}/v1/sync/pull", self.api_base);
        self.post_json(&url, request)
    }

    fn push(&self, request: &BatchPushRequest) -> Result<BatchPushResponse> {
        let url = format!("{}/v1/sync/push", self.api_base);
        // Push-specific error mapping: a deterministic 4xx rejection must carry
        // the typed `SyncPushRejected` so the engine's self-heal (reseed) and the
        // epoch-stale re-pull can react — the plain string this used to return
        // silently disabled both on the HTTP fallback path. Auth rejections keep
        // the exact "unauthorized" message the shells' retry matches on.
        self.authorized(ureq::post(&url))
            .send_json(serde_json::to_value(request)?)
            .map_err(mobile_sync_push_http_error)?
            .into_json()
            .with_context(|| format!("parse sync response from {url}"))
    }
}

fn mobile_sync_push_http_error(error: ureq::Error) -> anyhow::Error {
    match error {
        ureq::Error::Status(status, response) => {
            let code = response
                .into_json::<knotq_sync::ErrorResponse>()
                .map(|error| error.code)
                .unwrap_or_else(|_| status.to_string());
            if status == 401 || code == "unauthorized" {
                return anyhow!("sync backend rejected request: {code}");
            }
            if (400..500).contains(&status) {
                return anyhow::Error::new(knotq_sync::SyncPushRejected { code });
            }
            anyhow!("sync backend rejected request: {code}")
        }
        error => anyhow!("sync backend request failed: {error}"),
    }
}

fn mobile_workspace_media_assets(workspace: &Workspace) -> Vec<MobileSyncMediaAsset> {
    let mut seen = HashSet::new();
    let mut assets = Vec::new();
    for scheme in workspace.iter_schemes() {
        let Some(meta) = workspace.scheme_sync.get(&scheme.id) else {
            continue;
        };
        for item in &scheme.items {
            for media in mobile_item_image_assets(item) {
                let media = MobileSyncMediaAsset {
                    document: meta.id,
                    asset: media.asset,
                    format: media.format,
                };
                if seen.insert(media) {
                    assets.push(media);
                }
            }
        }
    }
    assets
}

pub(crate) fn mobile_item_image_assets(item: &Item) -> Vec<ImageInline> {
    let mut images = Vec::new();
    mobile_collect_item_image_assets(item, &mut images);
    images
}

fn mobile_collect_item_image_assets(item: &Item, images: &mut Vec<ImageInline>) {
    match &item.content {
        ItemContent::Text { .. } => {}
        ItemContent::Image(image) => images.push(*image),
        ItemContent::Table(table) => {
            for cell in table.cells() {
                for item in &cell.items {
                    mobile_collect_item_image_assets(item, images);
                }
            }
        }
    }
}

pub(crate) fn mobile_upload_local_media_assets(
    client: &MobileSyncHttpClient,
    local_state: &mut knotq_sync::LocalSyncState,
    workspace: &Workspace,
    image_assets_dir: &Path,
    remote_latest: &HashMap<DocumentId, u64>,
) -> Result<()> {
    for media in mobile_workspace_media_assets(workspace) {
        let path = mobile_image_asset_path(image_assets_dir, media.asset, media.format);
        let Ok(metadata) = fs::metadata(&path) else {
            continue;
        };
        if !metadata.is_file() {
            continue;
        }
        let byte_length = metadata.len();
        if byte_length == 0 {
            continue;
        }
        if byte_length > MAX_SYNC_MEDIA_BYTES as u64 {
            // An over-limit asset can never upload; skipping it (rather than
            // returning Err) keeps a single bad image from permanently wedging the
            // CRDT sync, so text/structure edits still converge.
            eprintln!(
                "mobile sync: skipping image {} ({} bytes, above the {} byte sync limit)",
                media.image_name(),
                byte_length,
                MAX_SYNC_MEDIA_BYTES
            );
            continue;
        }
        let image_name = media.image_name();
        let bytes = match fs::read(&path) {
            Ok(bytes) => bytes,
            Err(error) => {
                eprintln!("mobile sync: skipping unreadable image {image_name}: {error}");
                continue;
            }
        };
        if bytes.len() > MAX_SYNC_MEDIA_BYTES {
            eprintln!(
                "mobile sync: skipping image {} ({} bytes, above the {} byte sync limit)",
                image_name,
                bytes.len(),
                MAX_SYNC_MEDIA_BYTES
            );
            continue;
        }
        let sha256 = mobile_media_sha256(&bytes);
        if !local_state.should_upload_media_asset(
            &image_name,
            media.document,
            byte_length,
            &sha256,
            remote_latest,
        ) {
            continue;
        }
        // A single asset's upload failure (server rejection, transient error) must
        // not abort the whole sync before CRDT pull cursors are persisted — skip it
        // and let the next sync retry, rather than wedging every future sync.
        if let Err(error) = client.upload_media_asset(media, &bytes) {
            eprintln!("mobile sync: media upload failed for {image_name}; skipping: {error:#}");
            continue;
        }
        local_state.mark_media_uploaded(image_name, media.document, byte_length, sha256);
    }
    Ok(())
}

pub(crate) fn mobile_download_missing_media_assets(
    client: &MobileSyncHttpClient,
    workspace: &Workspace,
    image_assets_dir: &Path,
) -> Result<bool> {
    let mut downloaded = false;
    for media in mobile_workspace_media_assets(workspace) {
        let path = mobile_image_asset_path(image_assets_dir, media.asset, media.format);
        if !mobile_media_asset_needs_download(&path)? {
            continue;
        }
        let image_name = media.image_name();
        // A single asset's download failure must not abort the whole sync — skip it
        // and let a later sync retry, mirroring the missing-asset skip below.
        let bytes = match client.download_media_asset(media) {
            Ok(Some(bytes)) => bytes,
            Ok(None) => {
                eprintln!("mobile sync media missing on backend: {image_name}; skipping download");
                continue;
            }
            Err(error) => {
                eprintln!(
                    "mobile sync: media download failed for {image_name}; skipping: {error:#}"
                );
                continue;
            }
        };
        if bytes.len() > MAX_SYNC_MEDIA_BYTES {
            eprintln!(
                "mobile sync: skipping oversized downloaded image {} ({} bytes, above the {} byte limit)",
                image_name,
                bytes.len(),
                MAX_SYNC_MEDIA_BYTES
            );
            continue;
        }
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).with_context(|| format!("create {}", parent.display()))?;
        }
        if let Err(error) = fs::write(&path, bytes) {
            eprintln!(
                "mobile sync: failed to write downloaded image {image_name}; skipping: {error}"
            );
            continue;
        }
        downloaded = true;
    }
    Ok(downloaded)
}

fn mobile_image_asset_path(
    image_assets_dir: &Path,
    asset: uuid::Uuid,
    format: ImageAssetFormat,
) -> PathBuf {
    image_assets_dir.join(format!("{asset}.{}", format.extension()))
}

fn mobile_media_asset_needs_download(path: &Path) -> Result<bool> {
    match fs::metadata(path) {
        Ok(metadata) if metadata.is_file() && metadata.len() > 0 => Ok(false),
        Ok(metadata) if metadata.is_file() => Ok(true),
        Ok(_) => Err(anyhow!(
            "image asset path {} exists but is not a file",
            path.display()
        )),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(true),
        Err(error) => Err(error).with_context(|| format!("stat {}", path.display())),
    }
}

fn mobile_media_content_type(format: ImageAssetFormat) -> &'static str {
    match format {
        ImageAssetFormat::Png => "image/png",
        ImageAssetFormat::Jpeg => "image/jpeg",
        ImageAssetFormat::Webp => "image/webp",
        ImageAssetFormat::Gif => "image/gif",
        ImageAssetFormat::Svg => "image/svg+xml",
        ImageAssetFormat::Bmp => "image/bmp",
        ImageAssetFormat::Tiff => "image/tiff",
    }
}

fn mobile_media_sha256(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    digest.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn mobile_sync_http_error(error: ureq::Error) -> anyhow::Error {
    match error {
        ureq::Error::Status(status, response) => {
            let code = response
                .into_json::<knotq_sync::ErrorResponse>()
                .map(|error| error.code)
                .unwrap_or_else(|_| status.to_string());
            anyhow!("sync backend rejected request: {code}")
        }
        error => anyhow!("sync backend request failed: {error}"),
    }
}

pub(crate) fn normalize_sync_api_base(raw: &str) -> Result<String> {
    let trimmed = raw.trim().trim_end_matches('/');
    if trimmed.is_empty() {
        return Err(anyhow!("sync API URL is empty"));
    }
    // The bearer token and all workspace contents travel over this URL. Refuse
    // plaintext HTTP to anything other than a loopback dev server so a misconfig
    // can't silently leak credentials in the clear.
    if !mobile_is_secure_api_base(trimmed) {
        return Err(anyhow!("sync API URL must use https:// (got {trimmed})"));
    }
    Ok(trimmed.to_string())
}

fn mobile_is_secure_api_base(url: &str) -> bool {
    if let Some(host) = url.strip_prefix("https://") {
        return !host.is_empty();
    }
    if let Some(rest) = url.strip_prefix("http://") {
        let host = rest
            .split(['/', ':'])
            .next()
            .unwrap_or("")
            .to_ascii_lowercase();
        return matches!(host.as_str(), "127.0.0.1" | "localhost" | "[::1]" | "::1");
    }
    false
}

#[cfg(test)]
mod sync_api_base_tests {
    use super::{
        mobile_download_missing_media_assets, mobile_image_asset_path,
        mobile_media_asset_needs_download, mobile_upload_local_media_assets,
        mobile_workspace_media_assets, normalize_sync_api_base, MobileSyncHttpClient,
        MAX_SYNC_MEDIA_BYTES,
    };
    use knotq_model::{ImageAssetFormat, ImageInline, Item, Scheme, Table, Workspace};
    use std::{fs, path::PathBuf};

    #[test]
    fn https_is_accepted_http_loopback_only() {
        assert_eq!(
            normalize_sync_api_base("https://sync.example.com/").unwrap(),
            "https://sync.example.com"
        );
        assert!(normalize_sync_api_base("http://127.0.0.1:8787").is_ok());
        assert!(normalize_sync_api_base("http://localhost.evil.com").is_err());
        assert!(normalize_sync_api_base("http://127.0.0.1.evil.com").is_err());
        assert!(normalize_sync_api_base("http://sync.example.com").is_err());
        assert!(normalize_sync_api_base("").is_err());
    }

    #[test]
    fn zero_byte_mobile_media_file_is_downloaded_again() {
        let dir = unique_temp_dir("knotq-mobile-media");
        let path = dir.join("asset.png");
        fs::write(&path, []).unwrap();

        assert!(mobile_media_asset_needs_download(&path).unwrap());

        fs::write(&path, [1, 2, 3]).unwrap();
        assert!(!mobile_media_asset_needs_download(&path).unwrap());

        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn mobile_media_assets_use_scheme_sync_document_ids() {
        let mut workspace = Workspace::new();
        let mut scheme = Scheme::new("Images", 0);
        let scheme_id = scheme.id;
        let asset = uuid::Uuid::new_v4();
        // Two image lines referencing the *same* asset — media collection must
        // dedupe them to a single asset entry.
        let image = ImageInline {
            asset,
            format: ImageAssetFormat::Png,
            width: Some(10),
            height: Some(10),
        };
        let mut first = Item::new("");
        first.set_image(image);
        let mut second = Item::new("");
        second.set_image(image);
        scheme.items.push(first);
        scheme.items.push(second);
        workspace.schemes.insert(scheme_id, scheme);
        workspace.ensure_sync_metadata();
        let document = workspace.scheme_sync.get(&scheme_id).unwrap().id;

        let media = mobile_workspace_media_assets(&workspace);

        assert_eq!(media.len(), 1);
        assert_eq!(media[0].document, document);
        assert_eq!(media[0].asset, asset);
    }

    #[test]
    fn mobile_media_assets_include_images_inside_table_cells() {
        let mut workspace = Workspace::new();
        let mut scheme = Scheme::new("Table Images", 0);
        let scheme_id = scheme.id;
        let asset = uuid::Uuid::new_v4();
        let image = ImageInline {
            asset,
            format: ImageAssetFormat::Png,
            width: Some(20),
            height: Some(12),
        };
        let mut image_item = Item::new("");
        image_item.set_image(image);
        let mut table = Table::new(1, 2);
        table.cell_mut(0, 1).unwrap().items = vec![Item::new("caption"), image_item];
        let mut table_item = Item::new("");
        table_item.set_table(table);
        scheme.items.push(table_item);
        workspace.schemes.insert(scheme_id, scheme);
        workspace.ensure_sync_metadata();
        let document = workspace.scheme_sync.get(&scheme_id).unwrap().id;

        let media = mobile_workspace_media_assets(&workspace);

        assert_eq!(media.len(), 1);
        assert_eq!(media[0].document, document);
        assert_eq!(media[0].asset, asset);
        assert_eq!(media[0].format, ImageAssetFormat::Png);
    }

    fn single_image_workspace() -> (Workspace, uuid::Uuid) {
        let mut workspace = Workspace::new();
        let mut scheme = Scheme::new("Images", 0);
        let scheme_id = scheme.id;
        let asset = uuid::Uuid::new_v4();
        let mut item = Item::new("");
        item.set_image(ImageInline {
            asset,
            format: ImageAssetFormat::Png,
            width: Some(10),
            height: Some(10),
        });
        scheme.items.push(item);
        workspace.schemes.insert(scheme_id, scheme);
        workspace.ensure_sync_metadata();
        (workspace, asset)
    }

    /// Nothing listens on port 1, so any request fails fast with a connection
    /// refusal — a deterministic stand-in for a server/transport failure.
    fn unreachable_media_client() -> MobileSyncHttpClient {
        MobileSyncHttpClient {
            api_base: "http://127.0.0.1:1".to_string(),
            bearer_token: "test".to_string(),
        }
    }

    #[test]
    fn oversized_media_upload_is_skipped_not_wedged() {
        // An over-limit local image can never upload; it must be skipped, not abort
        // the whole sync — otherwise every future sync fails before pull cursors
        // persist (the wedge that stalled a real device for two weeks).
        let dir = unique_temp_dir("knotq-media-oversize");
        let (workspace, asset) = single_image_workspace();
        let path = mobile_image_asset_path(&dir, asset, ImageAssetFormat::Png);
        fs::write(&path, vec![0u8; MAX_SYNC_MEDIA_BYTES + 1]).unwrap();

        let mut local_state = knotq_sync::LocalSyncState::default();
        let result = mobile_upload_local_media_assets(
            &unreachable_media_client(),
            &mut local_state,
            &workspace,
            &dir,
            &std::collections::HashMap::new(),
        );
        assert!(
            result.is_ok(),
            "oversized asset must not wedge sync: {result:?}"
        );

        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn failed_media_upload_is_skipped_not_wedged() {
        // A transport/server failure uploading one asset must not abort the sync.
        let dir = unique_temp_dir("knotq-media-upload-fail");
        let (workspace, asset) = single_image_workspace();
        let path = mobile_image_asset_path(&dir, asset, ImageAssetFormat::Png);
        fs::write(&path, [1u8, 2, 3, 4]).unwrap();

        let mut local_state = knotq_sync::LocalSyncState::default();
        let result = mobile_upload_local_media_assets(
            &unreachable_media_client(),
            &mut local_state,
            &workspace,
            &dir,
            &std::collections::HashMap::new(),
        );
        assert!(
            result.is_ok(),
            "failed upload must not wedge sync: {result:?}"
        );

        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn failed_media_download_is_skipped_not_wedged() {
        // A download failure for one asset must not abort the sync either; the
        // asset is missing on disk (needs download) and the endpoint is dead.
        let dir = unique_temp_dir("knotq-media-download-fail");
        let (workspace, _asset) = single_image_workspace();

        let result =
            mobile_download_missing_media_assets(&unreachable_media_client(), &workspace, &dir);
        assert!(
            result.is_ok(),
            "failed download must not wedge sync: {result:?}"
        );

        let _ = fs::remove_dir_all(dir);
    }

    fn unique_temp_dir(prefix: &str) -> PathBuf {
        let mut path = std::env::temp_dir();
        path.push(format!(
            "{prefix}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&path).unwrap();
        path
    }
}
