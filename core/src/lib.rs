use std::fs;
use std::path::{Path, PathBuf};
use std::str::FromStr;
use std::sync::{Mutex, MutexGuard};

use anyhow::{anyhow, Context, Result};
use chrono::{DateTime, Duration, NaiveDate, TimeZone, Utc};
use knotq_commands::{Command, DateKind, WorkspaceCommandExt};
use knotq_index::query::{SearchHitStatus, SearchOptions, SearchTarget};
use knotq_index::IndexedWorkspace;
use knotq_model::{
    AppSettings, FolderId, ImageAssetFormat, Item, ItemId, ItemKind, ItemMarker, ItemMedia,
    NodeRef, OccurrenceId, Scheme, SchemeId, ThemeMode, TimeFormat, Workspace,
    DAILY_QUEUE_COLOR_INDEX,
};
use knotq_state::{daily_queue_scheme_name, make_default_workspace};
use knotq_storage_json::{load_app_settings, load_workspace, save_app_settings, save_workspace};

const DAILY_QUEUE_MARKER_COLOR: u32 = 0x42a5f5;
const EDITOR_IMAGE_FIXTURE_TEXT: &str = "Image layout test";
const EDITOR_IMAGE_FIXTURE_PNG: &[u8] = &[
    137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8,
    4, 0, 0, 0, 181, 28, 12, 2, 0, 0, 0, 11, 73, 68, 65, 84, 120, 218, 99, 252, 255, 31, 0, 3,
    3, 2, 0, 239, 191, 167, 219, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
];

#[derive(Debug, Clone, thiserror::Error)]
pub enum MobileError {
    #[error("{reason}")]
    Core { reason: String },
}

impl From<anyhow::Error> for MobileError {
    fn from(error: anyhow::Error) -> Self {
        Self::Core {
            reason: error.to_string(),
        }
    }
}

pub struct MobileCore {
    inner: Mutex<MobileCoreInner>,
}

impl MobileCore {
    pub fn new(app_dir: String) -> Result<Self, MobileError> {
        Ok(Self {
            inner: Mutex::new(MobileCoreInner::open(Path::new(&app_dir).to_path_buf())?),
        })
    }

    pub fn snapshot(
        &self,
        today: Option<String>,
        week_offset: i32,
    ) -> Result<MobileSnapshot, MobileError> {
        let today = parse_date_or_today(today.as_deref())?;
        self.lock()?
            .snapshot(today, week_offset)
            .map_err(Into::into)
    }

    pub fn search(&self, query: String) -> Result<Vec<MobileSearchHit>, MobileError> {
        self.lock()?.search(&query).map_err(Into::into)
    }

    pub fn create_folder(&self, name: String, position: Option<i32>) -> Result<(), MobileError> {
        let mut inner = self.lock()?;
        let parent = inner.workspace.root;
        inner
            .apply(Command::CreateFolder {
                parent,
                name,
                position: opt_position(position)?,
            })
            .map_err(Into::into)
    }

    pub fn rename_folder(&self, folder_id: String, name: String) -> Result<(), MobileError> {
        self.lock()?
            .apply(Command::RenameFolder {
                id: parse_id(&folder_id)?,
                name,
            })
            .map_err(Into::into)
    }

    pub fn delete_folder(&self, folder_id: String) -> Result<(), MobileError> {
        self.lock()?
            .apply(Command::DeleteFolder {
                id: parse_id(&folder_id)?,
            })
            .map_err(Into::into)
    }

    pub fn create_scheme(
        &self,
        folder_id: Option<String>,
        name: String,
        color_index: Option<i32>,
        position: Option<i32>,
    ) -> Result<(), MobileError> {
        let mut inner = self.lock()?;
        let folder = folder_id
            .as_deref()
            .map(parse_id)
            .transpose()?
            .unwrap_or(inner.workspace.root);
        let color_index = match color_index {
            Some(index) => as_u8(index, "color index")?,
            None => next_color_index(&inner.workspace),
        };
        inner
            .apply(Command::CreateScheme {
                folder,
                name,
                color_index,
                position: opt_position(position)?,
            })
            .map_err(Into::into)
    }

    pub fn rename_scheme(&self, scheme_id: String, name: String) -> Result<(), MobileError> {
        self.lock()?
            .apply(Command::RenameScheme {
                id: parse_id(&scheme_id)?,
                name,
            })
            .map_err(Into::into)
    }

    pub fn set_scheme_color(&self, scheme_id: String, color_index: i32) -> Result<(), MobileError> {
        self.lock()?
            .apply(Command::SetSchemeColor {
                id: parse_id(&scheme_id)?,
                color_index: as_u8(color_index, "color index")?,
            })
            .map_err(Into::into)
    }

    pub fn delete_scheme(&self, scheme_id: String) -> Result<(), MobileError> {
        self.lock()?
            .apply(Command::DeleteScheme {
                id: parse_id(&scheme_id)?,
            })
            .map_err(Into::into)
    }

    pub fn move_node(
        &self,
        kind: String,
        id: String,
        folder_id: String,
        position: i32,
    ) -> Result<(), MobileError> {
        let node = match kind.as_str() {
            "folder" => NodeRef::Folder(parse_id(&id)?),
            "scheme" => NodeRef::Scheme(parse_id(&id)?),
            other => return Err(anyhow!("unknown node kind {other}").into()),
        };
        self.lock()?
            .apply(Command::MoveNode {
                node,
                new_parent: parse_id(&folder_id)?,
                position: position_from_i32(position)?,
            })
            .map_err(Into::into)
    }

    pub fn ensure_daily_queue(&self, date: Option<String>) -> Result<(), MobileError> {
        let date = parse_date_or_today(date.as_deref())?;
        let mut inner = self.lock()?;
        inner.ensure_daily_queue(date)?;
        inner.save_workspace().map_err(Into::into)
    }

    pub fn add_item(
        &self,
        scheme_id: String,
        text: String,
        marker: Option<String>,
        position: Option<i32>,
        indent: Option<i32>,
    ) -> Result<(), MobileError> {
        let scheme_id = parse_id(&scheme_id)?;
        let mut inner = self.lock()?;
        let mut item = Item::new(text);
        item.marker = parse_marker(marker.as_deref())?;
        item.indent = as_u8(indent.unwrap_or(0), "indent")?;
        let position = match position {
            Some(position) => position_from_i32(position)?,
            None => inner
                .workspace
                .scheme(scheme_id)
                .map(|scheme| scheme.items.len())
                .unwrap_or(0),
        };
        inner
            .apply(Command::InsertItem {
                scheme: scheme_id,
                position,
                item,
            })
            .map_err(Into::into)
    }

    pub fn add_calendar_item(
        &self,
        scheme_id: Option<String>,
        date: Option<String>,
        text: String,
        kind: String,
        start: Option<String>,
        end: Option<String>,
    ) -> Result<(), MobileError> {
        let date = parse_date_or_today(date.as_deref())?;
        let mut inner = self.lock()?;
        let scheme_id = match scheme_id {
            Some(id) => parse_id(&id)?,
            None => inner.ensure_daily_queue(date)?,
        };
        let mut item = Item::new(text);
        item.marker = ItemMarker::Checkbox;
        let start = parse_datetime_opt(start.as_deref())?;
        let end = parse_datetime_opt(end.as_deref())?;
        match kind.as_str() {
            "event" => {
                item.start = start;
                item.end = end;
            }
            "reminder" => item.start = start,
            "assignment" => item.end = end,
            "task" | "procedure" => {}
            other => return Err(anyhow!("unknown calendar item kind {other}").into()),
        }
        let position = inner
            .workspace
            .scheme(scheme_id)
            .map(|scheme| scheme.items.len())
            .unwrap_or(0);
        inner
            .apply(Command::InsertItem {
                scheme: scheme_id,
                position,
                item,
            })
            .map_err(Into::into)
    }

    pub fn update_item_text(
        &self,
        scheme_id: String,
        item_id: String,
        text: String,
    ) -> Result<(), MobileError> {
        self.lock()?
            .apply(Command::UpdateItemText {
                scheme: parse_id(&scheme_id)?,
                item: parse_id(&item_id)?,
                text,
            })
            .map_err(Into::into)
    }

    pub fn set_item_marker(
        &self,
        scheme_id: String,
        item_id: String,
        marker: String,
    ) -> Result<(), MobileError> {
        self.lock()?
            .apply(Command::SetItemMarker {
                scheme: parse_id(&scheme_id)?,
                item: parse_id(&item_id)?,
                marker: parse_marker(Some(&marker))?,
            })
            .map_err(Into::into)
    }

    pub fn set_item_indent(
        &self,
        scheme_id: String,
        item_id: String,
        indent: i32,
    ) -> Result<(), MobileError> {
        self.lock()?
            .apply(Command::SetItemIndent {
                scheme: parse_id(&scheme_id)?,
                item: parse_id(&item_id)?,
                indent: as_u8(indent, "indent")?,
            })
            .map_err(Into::into)
    }

    pub fn set_item_date(
        &self,
        scheme_id: String,
        item_id: String,
        kind: String,
        date: Option<String>,
    ) -> Result<(), MobileError> {
        self.lock()?
            .apply(Command::SetItemDate {
                scheme: parse_id(&scheme_id)?,
                item: parse_id(&item_id)?,
                kind: parse_date_kind(&kind)?,
                date: parse_datetime_opt(date.as_deref())?,
            })
            .map_err(Into::into)
    }

    pub fn toggle_item(&self, scheme_id: String, item_id: String) -> Result<(), MobileError> {
        self.lock()?
            .apply(Command::ToggleOccurrence {
                scheme: parse_id(&scheme_id)?,
                item: parse_id(&item_id)?,
                occurrence: OccurrenceId::Single,
            })
            .map_err(Into::into)
    }

    pub fn delete_item(&self, scheme_id: String, item_id: String) -> Result<(), MobileError> {
        self.lock()?
            .apply(Command::DeleteItem {
                scheme: parse_id(&scheme_id)?,
                item: parse_id(&item_id)?,
            })
            .map_err(Into::into)
    }

    pub fn reorder_item(&self, scheme_id: String, from: i32, to: i32) -> Result<(), MobileError> {
        self.lock()?
            .apply(Command::ReorderItem {
                scheme: parse_id(&scheme_id)?,
                from: position_from_i32(from)?,
                to: position_from_i32(to)?,
            })
            .map_err(Into::into)
    }

    pub fn replace_scheme_items(
        &self,
        scheme_id: String,
        items: Vec<MobileItemEdit>,
    ) -> Result<(), MobileError> {
        let mut inner = self.lock()?;
        inner
            .replace_scheme_items(parse_id(&scheme_id)?, items)
            .map_err(Into::into)
    }

    pub fn set_theme_mode(&self, theme_mode: String) -> Result<(), MobileError> {
        let mut inner = self.lock()?;
        inner.settings.theme_mode = parse_theme_mode(&theme_mode)?;
        inner.save_settings().map_err(Into::into)
    }

    pub fn set_time_format(&self, time_format: String) -> Result<(), MobileError> {
        let mut inner = self.lock()?;
        inner.settings.time_format = parse_time_format(&time_format)?;
        inner.save_settings().map_err(Into::into)
    }

    pub fn reset_workspace(&self) -> Result<(), MobileError> {
        let mut inner = self.lock()?;
        inner.workspace = make_default_workspace();
        inner.save_workspace().map_err(Into::into)
    }

    pub fn seed_editor_image_fixture(&self) -> Result<(), MobileError> {
        self.lock()?.seed_editor_image_fixture().map_err(Into::into)
    }

    fn lock(&self) -> Result<MutexGuard<'_, MobileCoreInner>, MobileError> {
        self.inner.lock().map_err(|_| MobileError::Core {
            reason: "mobile core lock was poisoned".to_string(),
        })
    }
}

struct MobileCoreInner {
    workspace_path: PathBuf,
    settings_path: PathBuf,
    image_assets_dir: PathBuf,
    workspace: Workspace,
    settings: AppSettings,
}

impl MobileCoreInner {
    fn open(app_dir: PathBuf) -> Result<Self> {
        let workspace_dir = app_dir.join("workspace");
        let workspace_path = workspace_dir.join("workspace.json");
        let image_assets_dir = workspace_dir.join("assets/images");
        let settings_path = app_dir.join("settings.json");
        let mut should_reset_workspace_dir = false;
        let mut workspace = match load_workspace(&workspace_path) {
            Ok(Some(workspace)) => workspace,
            Ok(None) => make_default_workspace(),
            Err(_) => {
                should_reset_workspace_dir = true;
                make_default_workspace()
            }
        };
        workspace.normalize_one_level_folders();
        workspace.normalize_item_markers();
        let settings = load_app_settings(&settings_path).unwrap_or_default();
        if should_reset_workspace_dir && workspace_dir.exists() {
            fs::remove_dir_all(&workspace_dir)
                .with_context(|| format!("reset {}", workspace_dir.display()))?;
        }
        save_workspace(&workspace_path, &workspace)?;
        save_app_settings(&settings_path, &settings)?;
        Ok(Self {
            workspace_path,
            settings_path,
            image_assets_dir,
            workspace,
            settings,
        })
    }

    fn apply(&mut self, command: Command) -> Result<()> {
        self.workspace.apply(command)?;
        self.workspace.normalize_one_level_folders();
        self.workspace.normalize_item_markers();
        self.save_workspace()
    }

    fn save_workspace(&self) -> Result<()> {
        save_workspace(&self.workspace_path, &self.workspace)
    }

    fn save_settings(&self) -> Result<()> {
        save_app_settings(&self.settings_path, &self.settings)
    }

    fn ensure_daily_queue(&mut self, date: NaiveDate) -> Result<SchemeId> {
        if let Some(id) = self.workspace.daily_queue_scheme_id(date) {
            if self.workspace.schemes.contains_key(&id) {
                return Ok(id);
            }
        }
        let mut scheme = Scheme::new(daily_queue_scheme_name(date), DAILY_QUEUE_COLOR_INDEX);
        scheme.items = Vec::new();
        let id = scheme.id;
        self.workspace.daily_queue.insert(date, id);
        self.workspace.schemes.insert(id, scheme);
        Ok(id)
    }

    fn snapshot(&mut self, today: NaiveDate, week_offset: i32) -> Result<MobileSnapshot> {
        self.ensure_daily_queue(today)?;
        let root = self.folder_node(self.workspace.root)?;
        let mut schemes: Vec<MobileScheme> = self
            .workspace
            .iter_schemes()
            .map(|scheme| self.mobile_scheme(scheme))
            .collect();
        schemes.sort_by(|a, b| {
            a.is_daily_queue
                .cmp(&b.is_daily_queue)
                .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
        });

        let daily_start = today - Duration::days(3);
        let daily = (0..14)
            .filter_map(|offset| {
                let date = daily_start + Duration::days(offset);
                self.workspace
                    .daily_queue_scheme_id(date)
                    .and_then(|id| self.workspace.scheme(id))
                    .map(|scheme| MobileDailyEntry {
                        date: date.to_string(),
                        scheme: self.mobile_scheme(scheme),
                    })
            })
            .collect();

        let week_start = today + Duration::days((week_offset as i64) * 7);
        let week_end = week_start + Duration::days(7);
        let indexed = IndexedWorkspace::build(self.workspace.clone());
        let range = knotq_date_util::DateRange {
            start: midnight_utc(week_start)?,
            end: midnight_utc(week_end)?,
        };
        let occurrences = indexed
            .calendar_query()
            .range(range)
            .into_iter()
            .map(|context| MobileOccurrence::from_context(&self.workspace, context))
            .collect::<Vec<_>>();
        let days = (0..7)
            .map(|offset| {
                let date = week_start + Duration::days(offset);
                let date_string = date.to_string();
                MobileCalendarDay {
                    date: date_string.clone(),
                    occurrences: occurrences
                        .iter()
                        .filter(|occurrence| occurrence.local_date.as_deref() == Some(&date_string))
                        .cloned()
                        .collect(),
                }
            })
            .collect();
        let upcoming = indexed
            .calendar_query()
            .upcoming(Utc::now(), 12)
            .into_iter()
            .map(|context| MobileOccurrence::from_context(&self.workspace, context))
            .collect();
        let overdue = indexed
            .calendar_query()
            .overdue(Utc::now())
            .into_iter()
            .map(|context| MobileOccurrence::from_context(&self.workspace, context))
            .collect();
        Ok(MobileSnapshot {
            root,
            schemes,
            daily,
            calendar: MobileCalendar {
                start_date: week_start.to_string(),
                end_date: (week_end - Duration::days(1)).to_string(),
                days,
                upcoming,
                overdue,
            },
            settings: MobileSettings {
                theme_mode: theme_mode_str(self.settings.theme_mode).to_string(),
                time_format: time_format_str(self.settings.time_format).to_string(),
            },
            workspace_path: self.workspace_path.display().to_string(),
        })
    }

    fn folder_node(&self, id: FolderId) -> Result<MobileNode> {
        let folder = self
            .workspace
            .folder(id)
            .ok_or_else(|| anyhow!("folder {id} is missing"))?;
        Ok(MobileNode {
            kind: "folder".to_string(),
            id: id.to_string(),
            name: folder.name.clone(),
            color_index: None,
            is_daily_queue: false,
            children: folder
                .children
                .iter()
                .filter_map(|child| self.child_node(child).transpose())
                .collect::<Result<Vec<_>>>()?,
        })
    }

    fn child_node(&self, child: &NodeRef) -> Result<Option<MobileNode>> {
        match child {
            NodeRef::Folder(id) => self.folder_node(*id).map(Some),
            NodeRef::Scheme(id) => {
                let Some(scheme) = self.workspace.scheme(*id) else {
                    return Ok(None);
                };
                if self.workspace.is_daily_queue_scheme(scheme.id)
                    || self.workspace.is_scheme_deleted(scheme.id)
                {
                    return Ok(None);
                }
                Ok(Some(MobileNode {
                    kind: "scheme".to_string(),
                    id: scheme.id.to_string(),
                    name: scheme.name.clone(),
                    color_index: Some(i32::from(scheme.color_index)),
                    is_daily_queue: false,
                    children: Vec::new(),
                }))
            }
        }
    }

    fn mobile_scheme(&self, scheme: &Scheme) -> MobileScheme {
        let is_daily_queue = self.workspace.is_daily_queue_scheme(scheme.id);
        let date = self.workspace.daily_queue_date_for_scheme(scheme.id);
        let default_daily_name = date.map(daily_queue_scheme_name);
        let display_name = if is_daily_queue {
            match (date, default_daily_name.as_deref()) {
                (Some(date), Some(default_name)) if scheme.name == default_name => {
                    format_daily_label(date)
                }
                _ => scheme.name.clone(),
            }
        } else {
            scheme.name.clone()
        };
        let items = scheme
            .items
            .iter()
            .map(|item| MobileItem::from_item(item, &self.image_assets_dir))
            .collect::<Vec<_>>();
        MobileScheme {
            id: scheme.id.to_string(),
            name: scheme.name.clone(),
            display_name,
            color_index: i32::from(scheme.color_index),
            is_daily_queue,
            date: date.map(|date| date.to_string()),
            items,
        }
    }

    fn search(&self, query: &str) -> Result<Vec<MobileSearchHit>> {
        let indexed = IndexedWorkspace::build(self.workspace.clone());
        let hits = indexed
            .search_query(
                self.settings.time_format,
                SearchOptions {
                    daily_queue_title: "Daily",
                    daily_queue_marker_color: DAILY_QUEUE_MARKER_COLOR,
                },
            )
            .run(query)
            .into_iter()
            .map(|hit| MobileSearchHit {
                target_kind: match &hit.target {
                    SearchTarget::Calendar => "calendar".to_string(),
                    SearchTarget::DailyQueue { .. } => "daily_queue".to_string(),
                    SearchTarget::Scheme { .. } => "scheme".to_string(),
                },
                scheme_id: match &hit.target {
                    SearchTarget::DailyQueue { scheme_id, .. } => {
                        scheme_id.map(|id| id.to_string())
                    }
                    SearchTarget::Scheme { scheme_id, .. } => Some(scheme_id.to_string()),
                    SearchTarget::Calendar => None,
                },
                item_id: match &hit.target {
                    SearchTarget::DailyQueue { item_id, .. }
                    | SearchTarget::Scheme { item_id, .. } => item_id.map(|id| id.to_string()),
                    SearchTarget::Calendar => None,
                },
                scheme_name: hit.scheme_name,
                color_index: hit.color_index.map(i32::from),
                title: hit.title,
                detail: hit.detail,
                status: match hit.status {
                    SearchHitStatus::None => "none".to_string(),
                    SearchHitStatus::Date { .. } => "date".to_string(),
                    SearchHitStatus::Event { .. } => "event".to_string(),
                    SearchHitStatus::DailyQueue => "daily_queue".to_string(),
                },
            })
            .collect();
        Ok(hits)
    }

    fn seed_editor_image_fixture(&mut self) -> Result<()> {
        if self.workspace.iter_schemes().any(|scheme| {
            scheme
                .items
                .iter()
                .any(|item| item.text == EDITOR_IMAGE_FIXTURE_TEXT && !item.media.is_empty())
        }) {
            return Ok(());
        }

        if self
            .workspace
            .iter_schemes()
            .all(|scheme| self.workspace.is_daily_queue_scheme(scheme.id))
        {
            self.apply(Command::CreateScheme {
                folder: self.workspace.root,
                name: "Editor Layout Test".to_string(),
                color_index: next_color_index(&self.workspace),
                position: None,
            })?;
        }

        let target_id = self
            .workspace
            .iter_schemes()
            .find(|scheme| !self.workspace.is_daily_queue_scheme(scheme.id))
            .map(|scheme| scheme.id)
            .ok_or_else(|| anyhow!("no writable scheme available for image fixture"))?;

        fs::create_dir_all(&self.image_assets_dir)
            .with_context(|| format!("create {}", self.image_assets_dir.display()))?;
        let asset = uuid::Uuid::new_v4();
        let asset_path = self.image_assets_dir.join(format!("{asset}.png"));
        fs::write(&asset_path, EDITOR_IMAGE_FIXTURE_PNG)
            .with_context(|| format!("write {}", asset_path.display()))?;

        let mut item = Item::new(EDITOR_IMAGE_FIXTURE_TEXT);
        item.media.push(ItemMedia::Image {
            asset,
            format: ImageAssetFormat::Png,
            width: Some(320),
            height: Some(180),
        });

        let scheme = self
            .workspace
            .scheme_mut(target_id)
            .ok_or_else(|| anyhow!("scheme {target_id} is missing"))?;
        scheme.items.push(item);
        self.save_workspace()
    }

    fn replace_scheme_items(
        &mut self,
        scheme_id: SchemeId,
        drafts: Vec<MobileItemEdit>,
    ) -> Result<()> {
        if self.workspace.is_scheme_read_only(scheme_id) {
            return Err(anyhow!("scheme is read-only"));
        }

        let existing = self
            .workspace
            .scheme(scheme_id)
            .ok_or_else(|| anyhow!("scheme {scheme_id} is missing"))?
            .items
            .clone();
        let mut used_ids = Vec::<ItemId>::new();
        let mut next_items = Vec::with_capacity(drafts.len());

        for draft in drafts {
            let existing_id = draft.id.as_deref().map(parse_id::<ItemId>).transpose()?;
            let mut item = existing_id
                .and_then(|id| {
                    if used_ids.contains(&id) {
                        return None;
                    }
                    existing.iter().find(|item| item.id == id).cloned()
                })
                .unwrap_or_else(|| Item::new(""));

            used_ids.push(item.id);
            item.text = draft.text;
            item.marker = parse_marker(Some(&draft.marker))?;
            item.indent = as_u8(draft.indent, "indent")?.min(8);
            item.enforce_marker_constraints();
            if item.marker == ItemMarker::Checkbox {
                item.state_for_occurrence_mut(OccurrenceId::Single).progress =
                    if draft.done { -1 } else { 0 };
                item.normalize_state();
            }
            next_items.push(item);
        }

        let scheme = self
            .workspace
            .scheme_mut(scheme_id)
            .ok_or_else(|| anyhow!("scheme {scheme_id} is missing"))?;
        scheme.items = next_items;
        self.workspace.normalize_item_markers();
        self.save_workspace()
    }
}

#[derive(Clone, Debug)]
pub struct MobileSnapshot {
    pub root: MobileNode,
    pub schemes: Vec<MobileScheme>,
    pub daily: Vec<MobileDailyEntry>,
    pub calendar: MobileCalendar,
    pub settings: MobileSettings,
    pub workspace_path: String,
}

#[derive(Clone, Debug)]
pub struct MobileNode {
    pub kind: String,
    pub id: String,
    pub name: String,
    pub color_index: Option<i32>,
    pub is_daily_queue: bool,
    pub children: Vec<MobileNode>,
}

#[derive(Clone, Debug)]
pub struct MobileScheme {
    pub id: String,
    pub name: String,
    pub display_name: String,
    pub color_index: i32,
    pub is_daily_queue: bool,
    pub date: Option<String>,
    pub items: Vec<MobileItem>,
}

#[derive(Clone, Debug)]
pub struct MobileItem {
    pub id: String,
    pub text: String,
    pub marker: String,
    pub indent: i32,
    pub kind: String,
    pub done: bool,
    pub start: Option<String>,
    pub end: Option<String>,
    pub media: Vec<MobileItemMedia>,
}

#[derive(Clone, Debug)]
pub struct MobileItemMedia {
    pub kind: String,
    pub path: Option<String>,
    pub format: String,
    pub width: Option<i32>,
    pub height: Option<i32>,
}

#[derive(Clone, Debug)]
pub struct MobileItemEdit {
    pub id: Option<String>,
    pub text: String,
    pub marker: String,
    pub indent: i32,
    pub done: bool,
}

impl MobileItem {
    fn from_item(item: &Item, image_assets_dir: &Path) -> Self {
        Self {
            id: item.id.to_string(),
            text: item.text.clone(),
            marker: marker_str(item.marker).to_string(),
            indent: i32::from(item.indent),
            kind: item_kind_str(item.kind()).to_string(),
            done: item.single_state().is_done(),
            start: item.start.map(format_datetime),
            end: item.end.map(format_datetime),
            media: item
                .media
                .iter()
                .filter_map(|media| MobileItemMedia::from_media(media, image_assets_dir))
                .collect(),
        }
    }
}

impl MobileItemMedia {
    fn from_media(media: &ItemMedia, image_assets_dir: &Path) -> Option<Self> {
        let ItemMedia::Image {
            asset,
            format,
            width,
            height,
        } = media;
        Some(Self {
            kind: "image".to_string(),
            path: Some(
                image_assets_dir
                    .join(format!("{asset}.{}", format.extension()))
                    .display()
                    .to_string(),
            ),
            format: image_format_str(*format).to_string(),
            width: width.and_then(|value| i32::try_from(value).ok()),
            height: height.and_then(|value| i32::try_from(value).ok()),
        })
    }
}

#[derive(Clone, Debug)]
pub struct MobileDailyEntry {
    pub date: String,
    pub scheme: MobileScheme,
}

#[derive(Clone, Debug)]
pub struct MobileCalendar {
    pub start_date: String,
    pub end_date: String,
    pub days: Vec<MobileCalendarDay>,
    pub upcoming: Vec<MobileOccurrence>,
    pub overdue: Vec<MobileOccurrence>,
}

#[derive(Clone, Debug)]
pub struct MobileCalendarDay {
    pub date: String,
    pub occurrences: Vec<MobileOccurrence>,
}

#[derive(Clone, Debug)]
pub struct MobileOccurrence {
    pub scheme_id: String,
    pub item_id: String,
    pub scheme_name: String,
    pub color_index: i32,
    pub title: String,
    pub kind: String,
    pub done: bool,
    pub start: Option<String>,
    pub end: Option<String>,
    pub local_date: Option<String>,
}

impl MobileOccurrence {
    fn from_context(
        workspace: &Workspace,
        context: knotq_index::calendar::OccurrenceWithContext,
    ) -> Self {
        let title = workspace
            .scheme(context.scheme_id)
            .and_then(|scheme| scheme.item(context.item_id))
            .map(|item| item.text.clone())
            .unwrap_or_default();
        let local_date = context
            .occurrence
            .start
            .or(context.occurrence.end)
            .map(|dt| dt.date_naive().to_string());
        Self {
            scheme_id: context.scheme_id.to_string(),
            item_id: context.item_id.to_string(),
            scheme_name: context.scheme_name,
            color_index: i32::from(context.color_index),
            title,
            kind: item_kind_str(context.occurrence.kind).to_string(),
            done: context.occurrence.state.is_done(),
            start: context.occurrence.start.map(format_datetime),
            end: context.occurrence.end.map(format_datetime),
            local_date,
        }
    }
}

#[derive(Clone, Debug)]
pub struct MobileSettings {
    pub theme_mode: String,
    pub time_format: String,
}

#[derive(Clone, Debug)]
pub struct MobileSearchHit {
    pub target_kind: String,
    pub scheme_id: Option<String>,
    pub item_id: Option<String>,
    pub scheme_name: String,
    pub color_index: Option<i32>,
    pub title: String,
    pub detail: String,
    pub status: String,
}

fn parse_id<T>(raw: &str) -> Result<T>
where
    T: FromStr,
    T::Err: std::error::Error + Send + Sync + 'static,
{
    raw.parse::<T>().with_context(|| format!("parse id {raw}"))
}

fn parse_marker(raw: Option<&str>) -> Result<ItemMarker> {
    Ok(match raw.unwrap_or("blank") {
        "blank" => ItemMarker::Blank,
        "bullet" => ItemMarker::Bullet,
        "numbered" => ItemMarker::Numbered,
        "checkbox" => ItemMarker::Checkbox,
        other => return Err(anyhow!("unknown marker {other}")),
    })
}

fn parse_date_kind(raw: &str) -> Result<DateKind> {
    Ok(match raw {
        "start" => DateKind::Start,
        "end" => DateKind::End,
        other => return Err(anyhow!("unknown date kind {other}")),
    })
}

fn parse_theme_mode(raw: &str) -> Result<ThemeMode> {
    Ok(match raw {
        "system" => ThemeMode::System,
        "dark" => ThemeMode::Dark,
        "light" => ThemeMode::Light,
        other => return Err(anyhow!("unknown theme mode {other}")),
    })
}

fn parse_time_format(raw: &str) -> Result<TimeFormat> {
    Ok(match raw {
        "twelve_hour" => TimeFormat::TwelveHour,
        "twenty_four_hour" => TimeFormat::TwentyFourHour,
        other => return Err(anyhow!("unknown time format {other}")),
    })
}

fn parse_date_or_today(raw: Option<&str>) -> Result<NaiveDate> {
    match raw {
        Some(raw) if !raw.is_empty() => Ok(NaiveDate::parse_from_str(raw, "%Y-%m-%d")?),
        _ => Ok(default_today()),
    }
}

fn parse_datetime_opt(raw: Option<&str>) -> Result<Option<DateTime<Utc>>> {
    match raw {
        Some(raw) if !raw.is_empty() => {
            Ok(Some(DateTime::parse_from_rfc3339(raw)?.with_timezone(&Utc)))
        }
        _ => Ok(None),
    }
}

fn default_today() -> NaiveDate {
    Utc::now().date_naive()
}

fn midnight_utc(date: NaiveDate) -> Result<DateTime<Utc>> {
    let naive = date
        .and_hms_opt(0, 0, 0)
        .ok_or_else(|| anyhow!("invalid midnight for {date}"))?;
    Ok(Utc.from_utc_datetime(&naive))
}

fn format_datetime(dt: DateTime<Utc>) -> String {
    dt.to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
}

fn format_daily_label(date: NaiveDate) -> String {
    date.format("%a, %b %-d").to_string()
}

fn marker_str(marker: ItemMarker) -> &'static str {
    match marker {
        ItemMarker::Blank => "blank",
        ItemMarker::Bullet => "bullet",
        ItemMarker::Numbered => "numbered",
        ItemMarker::Checkbox => "checkbox",
    }
}

fn item_kind_str(kind: ItemKind) -> &'static str {
    match kind {
        ItemKind::Reminder => "reminder",
        ItemKind::Assignment => "assignment",
        ItemKind::Event => "event",
        ItemKind::Procedure => "procedure",
    }
}

fn image_format_str(format: ImageAssetFormat) -> &'static str {
    match format {
        ImageAssetFormat::Png => "png",
        ImageAssetFormat::Jpeg => "jpeg",
        ImageAssetFormat::Webp => "webp",
        ImageAssetFormat::Gif => "gif",
        ImageAssetFormat::Svg => "svg",
        ImageAssetFormat::Bmp => "bmp",
        ImageAssetFormat::Tiff => "tiff",
    }
}

fn theme_mode_str(theme_mode: ThemeMode) -> &'static str {
    match theme_mode {
        ThemeMode::System => "system",
        ThemeMode::Dark => "dark",
        ThemeMode::Light => "light",
    }
}

fn time_format_str(time_format: TimeFormat) -> &'static str {
    match time_format {
        TimeFormat::TwelveHour => "twelve_hour",
        TimeFormat::TwentyFourHour => "twenty_four_hour",
    }
}

fn next_color_index(workspace: &Workspace) -> u8 {
    let count = workspace
        .iter_schemes()
        .filter(|scheme| !workspace.is_daily_queue_scheme(scheme.id))
        .count();
    (count % 10) as u8
}

fn opt_position(position: Option<i32>) -> Result<Option<usize>> {
    position.map(position_from_i32).transpose()
}

fn position_from_i32(position: i32) -> Result<usize> {
    usize::try_from(position).map_err(|_| anyhow!("position cannot be negative: {position}"))
}

fn as_u8(value: i32, label: &str) -> Result<u8> {
    u8::try_from(value).map_err(|_| anyhow!("{label} must be between 0 and 255: {value}"))
}

uniffi::include_scaffolding!("knotq_mobile_core");

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mobile_core_flow_creates_edits_and_searches() {
        let dir = std::env::temp_dir().join(format!("knotq-mobile-test-{}", uuid::Uuid::new_v4()));
        let core = MobileCore::new(dir.display().to_string()).expect("open mobile core");

        let snapshot = core
            .snapshot(Some("2026-05-26".to_string()), 0)
            .expect("snapshot");
        assert!(!snapshot.schemes.is_empty());

        core.create_scheme(None, "Mobile Smoke".to_string(), Some(1), None)
            .expect("create scheme");
        let snapshot = core
            .snapshot(Some("2026-05-26".to_string()), 0)
            .expect("snapshot after create");
        let scheme = snapshot
            .schemes
            .iter()
            .find(|scheme| scheme.display_name == "Mobile Smoke")
            .expect("created scheme");

        core.add_item(
            scheme.id.clone(),
            "Check mobile bridge".to_string(),
            Some("checkbox".to_string()),
            None,
            None,
        )
        .expect("add item");

        let hits = core.search("bridge".to_string()).expect("search");
        assert!(hits.iter().any(|hit| hit.title == "Check mobile bridge"));

        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn replace_scheme_items_preserves_existing_metadata() {
        let dir = std::env::temp_dir().join(format!("knotq-mobile-test-{}", uuid::Uuid::new_v4()));
        let core = MobileCore::new(dir.display().to_string()).expect("open mobile core");

        core.create_scheme(None, "Editor".to_string(), Some(2), None)
            .expect("create scheme");
        let scheme_id = core
            .snapshot(Some("2026-05-26".to_string()), 0)
            .expect("snapshot")
            .schemes
            .into_iter()
            .find(|scheme| scheme.display_name == "Editor")
            .expect("created scheme")
            .id;

        core.add_item(
            scheme_id.clone(),
            "Keep my date".to_string(),
            Some("checkbox".to_string()),
            None,
            None,
        )
        .expect("add item");
        let item_id = core
            .snapshot(Some("2026-05-26".to_string()), 0)
            .expect("snapshot")
            .schemes
            .into_iter()
            .find(|scheme| scheme.id == scheme_id)
            .expect("scheme")
            .items[0]
            .id
            .clone();
        core.set_item_date(
            scheme_id.clone(),
            item_id.clone(),
            "start".to_string(),
            Some("2026-05-27T12:00:00Z".to_string()),
        )
        .expect("set date");

        core.replace_scheme_items(
            scheme_id.clone(),
            vec![
                MobileItemEdit {
                    id: Some(item_id.clone()),
                    text: "Keep my edited date".to_string(),
                    marker: "checkbox".to_string(),
                    indent: 1,
                    done: true,
                },
                MobileItemEdit {
                    id: None,
                    text: "New child".to_string(),
                    marker: "bullet".to_string(),
                    indent: 2,
                    done: false,
                },
            ],
        )
        .expect("replace items");

        let scheme = core
            .snapshot(Some("2026-05-26".to_string()), 0)
            .expect("snapshot")
            .schemes
            .into_iter()
            .find(|scheme| scheme.id == scheme_id)
            .expect("scheme");
        assert_eq!(scheme.items.len(), 2);
        assert_eq!(scheme.items[0].id, item_id);
        assert_eq!(scheme.items[0].text, "Keep my edited date");
        assert_eq!(scheme.items[0].indent, 1);
        assert!(scheme.items[0].done);
        assert_eq!(
            scheme.items[0].start.as_deref(),
            Some("2026-05-27T12:00:00Z")
        );
        assert_eq!(scheme.items[1].marker, "bullet");
        assert_eq!(scheme.items[1].indent, 2);

        let _ = std::fs::remove_dir_all(dir);
    }
}
