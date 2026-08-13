use super::*;

impl MobileCoreInner {
    pub(crate) fn snapshot(
        &mut self,
        today: NaiveDate,
        week_offset: i32,
        daily_history_days: i64,
    ) -> Result<MobileSnapshot> {
        // Mark elapsed event occurrences complete before reading, mirroring the
        // desktop's background sweep. Uses the real current instant (not `today`)
        // and is best-effort: a transient save failure must not block rendering.
        if let Err(error) = self.complete_past_events(Utc::now()) {
            eprintln!("knotq: deferring past-event completion: {error:#}");
        }
        let daily_start = today - Duration::days(daily_history_days);
        let daily_end = today + Duration::days(MOBILE_DAILY_LOOKAHEAD_DAYS);
        self.load_daily_queue_date_range(daily_start, daily_end)?;
        let previous_daily_date =
            if daily_history_days > i64::from(MOBILE_DAILY_DEFAULT_HISTORY_DAYS) {
                self.workspace
                    .daily_queue
                    .range(..daily_start)
                    .next_back()
                    .map(|(date, _)| *date)
            } else {
                None
            };
        if let Some(date) = previous_daily_date {
            self.load_daily_queue_scheme_if_needed(date)?;
        }

        let week_start = today + Duration::days((week_offset as i64) * 7);
        let week_end = week_start + Duration::days(7);
        let query_start = week_start - Duration::days(1);
        self.load_daily_queue_calendar_range(query_start, week_end)?;

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
        let archived_schemes = self
            .workspace
            .iter_deleted_schemes()
            .map(|scheme| self.mobile_scheme(scheme))
            .collect::<Vec<_>>();
        let archived_nodes = self.archived_nodes()?;

        let daily_days = daily_end.signed_duration_since(daily_start).num_days() + 1;
        let daily = previous_daily_date
            .into_iter()
            .chain((0..daily_days).map(|offset| daily_start + Duration::days(offset)))
            .filter_map(|date| {
                self.workspace
                    .daily_queue_scheme_id(date)
                    .and_then(|id| self.workspace.scheme(id))
                    .map(|scheme| MobileDailyEntry {
                        date: date.to_string(),
                        scheme: self.mobile_scheme(scheme),
                    })
            })
            .collect();

        let indexed = IndexedWorkspace::build(self.workspace.clone());
        let range = knotq_date_util::DateRange {
            start: local_midnight_utc(query_start)?,
            end: local_midnight_utc(week_end)?,
        };
        let occurrences = indexed
            .calendar_query()
            .range(range)
            .into_iter()
            .map(|context| MobileOccurrence::from_context(&self.workspace, context))
            .collect::<Vec<_>>();
        let days = (-1..7)
            .map(|offset| {
                let date = week_start + Duration::days(offset as i64);
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
        let upcoming = mobile_upcoming(
            &indexed,
            Utc::now(),
            self.settings.upcoming_display,
            MOBILE_UPCOMING_QUERY_LIMIT,
        )
            .into_iter()
            .map(|context| MobileOccurrence::from_context(&self.workspace, context))
            .collect();
        let retained = &self.retained_completed;
        let now = Utc::now();
        let overdue = indexed
            .calendar_query()
            .overdue_retaining(now, |event| {
                retained.is_retained(
                    &CalendarOccurrenceKey {
                        scheme_id: event.scheme_id,
                        item_id: event.item_id,
                        occurrence: event.occurrence.id.clone(),
                    },
                    now,
                )
            })
            .into_iter()
            .map(|context| MobileOccurrence::from_context(&self.workspace, context))
            .collect();
        Ok(MobileSnapshot {
            root,
            schemes,
            archived_schemes,
            archived_nodes,
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
                event_notification_offset_secs: offset_to_i32(
                    self.settings.notification_defaults.event_offset_secs,
                ),
                assignment_notification_offset_secs: offset_to_i32(
                    self.settings.notification_defaults.assignment_offset_secs,
                ),
                event_lookahead_days: i32::from(
                    self.settings.upcoming_display.event_lookahead_days,
                ),
                reminder_lookahead_days: i32::from(
                    self.settings.upcoming_display.reminder_lookahead_days,
                ),
                assignment_lookahead_days: i32::from(
                    self.settings.upcoming_display.assignment_lookahead_days,
                ),
                maximum_upcoming_items: i32::from(
                    self.settings.upcoming_display.maximum_items,
                ),
                show_overdue: self.settings.upcoming_display.show_overdue,
                show_completed: self.settings.upcoming_display.show_completed,
                google_account_count: self.settings.google_accounts.len() as i32,
                google_accounts: self.google_accounts(),
            },
            workspace_path: self.workspace_path.display().to_string(),
        })
    }

    pub(crate) fn month_days(&mut self, year: i32, month: u32) -> Result<Vec<MobileCalendarDay>> {
        let first = NaiveDate::from_ymd_opt(year, month, 1)
            .ok_or_else(|| anyhow!("invalid month {month}/{year}"))?;
        let next_month_first = if month >= 12 {
            NaiveDate::from_ymd_opt(year + 1, 1, 1)
        } else {
            NaiveDate::from_ymd_opt(year, month + 1, 1)
        }
        .ok_or_else(|| anyhow!("invalid month {month}/{year}"))?;
        // Pad the range so the leading/trailing spillover cells the grid shows
        // for the adjacent months still carry their event dots.
        let grid_start = first - Duration::days(7);
        let grid_end = next_month_first + Duration::days(7);
        self.load_daily_queue_date_range(grid_start, grid_end)?;
        self.load_daily_queue_calendar_range(grid_start, grid_end)?;

        let indexed = IndexedWorkspace::build(self.workspace.clone());
        let range = knotq_date_util::DateRange {
            start: local_midnight_utc(grid_start)?,
            end: local_midnight_utc(grid_end)?,
        };
        let occurrences = indexed
            .calendar_query()
            .range(range)
            .into_iter()
            .map(|context| MobileOccurrence::from_context(&self.workspace, context))
            .collect::<Vec<_>>();

        let total_days = (grid_end - grid_start).num_days();
        let days = (0..total_days)
            .map(|offset| {
                let date = grid_start + Duration::days(offset);
                let date_string = date.to_string();
                MobileCalendarDay {
                    occurrences: occurrences
                        .iter()
                        .filter(|occurrence| occurrence.local_date.as_deref() == Some(&date_string))
                        .cloned()
                        .collect(),
                    date: date_string,
                }
            })
            .collect();
        Ok(days)
    }

    pub(crate) fn folder_node(&self, id: FolderId) -> Result<MobileNode> {
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
            is_read_only: false,
            children: folder
                .children
                .iter()
                .filter_map(|child| self.child_node(child).transpose())
                .collect::<Result<Vec<_>>>()?,
        })
    }

    pub(crate) fn child_node(&self, child: &NodeRef) -> Result<Option<MobileNode>> {
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
                    is_read_only: scheme.is_read_only(),
                    children: Vec::new(),
                }))
            }
        }
    }

    /// The archive as a tree mirroring the desktop trash view: each top-level
    /// archived folder keeps its subtree (nested folders + schemes), followed by
    /// archived schemes that aren't inside an archived folder.
    pub(crate) fn archived_nodes(&self) -> Result<Vec<MobileNode>> {
        let mut nodes = Vec::new();
        let archived_folders = self
            .workspace
            .iter_deleted_folders()
            .map(|folder| folder.id)
            .collect::<Vec<_>>();
        for folder_id in archived_folders {
            nodes.push(self.archived_folder_node(folder_id)?);
        }
        let archived_schemes = self
            .workspace
            .iter_deleted_schemes()
            .filter(|scheme| {
                !self
                    .workspace
                    .is_scheme_in_deleted_folder_subtree(scheme.id)
            })
            .map(|scheme| scheme.id)
            .collect::<Vec<_>>();
        for scheme_id in archived_schemes {
            if let Some(scheme) = self.workspace.scheme(scheme_id) {
                nodes.push(archived_scheme_node(scheme));
            }
        }
        Ok(nodes)
    }

    pub(crate) fn archived_folder_node(&self, id: FolderId) -> Result<MobileNode> {
        let folder = self
            .workspace
            .folder(id)
            .ok_or_else(|| anyhow!("archived folder {id} is missing"))?;
        Ok(MobileNode {
            kind: "folder".to_string(),
            id: id.to_string(),
            name: folder.name.clone(),
            color_index: None,
            is_daily_queue: false,
            is_read_only: false,
            children: folder
                .children
                .iter()
                .filter_map(|child| self.archived_child_node(child).transpose())
                .collect::<Result<Vec<_>>>()?,
        })
    }

    pub(crate) fn archived_child_node(&self, child: &NodeRef) -> Result<Option<MobileNode>> {
        match child {
            NodeRef::Folder(id) => self.archived_folder_node(*id).map(Some),
            NodeRef::Scheme(id) => Ok(self.workspace.scheme(*id).map(archived_scheme_node)),
        }
    }

    pub(crate) fn mobile_scheme(&self, scheme: &Scheme) -> MobileScheme {
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
            is_read_only: scheme.is_read_only(),
            date: date.map(|date| date.to_string()),
            items,
        }
    }

    pub(crate) fn search(&self, query: &str) -> Result<Vec<MobileSearchHit>> {
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

    pub(crate) fn restore_deleted_scheme(&mut self, scheme_id: SchemeId) -> Result<()> {
        if !self.workspace.is_scheme_deleted(scheme_id) {
            return Ok(());
        }
        let Some(scheme) = self.workspace.scheme(scheme_id).cloned() else {
            self.workspace.unmark_scheme_deleted(scheme_id);
            self.record_crdt_changes(WorkspaceCrdtChangeSet::default().workspace())?;
            return self.save_workspace();
        };
        // A nested scheme has no live origin folder, so this lands it at the root;
        // `RestoreScheme` detaches it from the archived folder's subtree, leaving
        // the archive entirely.
        let (folder, position) = self.deleted_scheme_restore_target(scheme_id);
        self.apply(Command::RestoreScheme {
            folder,
            position,
            scheme,
        })
    }

    pub(crate) fn restore_deleted_folder(&mut self, folder_id: FolderId) -> Result<()> {
        let is_archived_root = self.workspace.is_folder_deleted(folder_id);
        // A folder nested under an archived folder isn't itself flagged deleted;
        // it still needs lifting out so it (and its schemes) leave the archive.
        let is_nested = !is_archived_root
            && self
                .workspace
                .is_node_in_deleted_folder_subtree(NodeRef::Folder(folder_id));
        if !is_archived_root && !is_nested {
            return Ok(());
        }
        let Some(folder) = self.workspace.folder(folder_id).cloned() else {
            if is_archived_root {
                self.workspace.remove_folder_from_archive(folder_id);
                self.record_crdt_changes(WorkspaceCrdtChangeSet::default().workspace())?;
                return self.save_workspace();
            }
            return Ok(());
        };
        // Top-level archived folders restore to their origin (or root); nested
        // ones lift to the root. `RestoreFolder` detaches the folder and clears
        // the deleted flag across its whole subtree.
        let (parent, position) = if is_archived_root {
            self.deleted_folder_restore_target(folder_id)
        } else {
            let root = self.workspace.root;
            let position = self
                .workspace
                .folder(root)
                .map(|folder| folder.children.len())
                .unwrap_or(0);
            (root, position)
        };
        self.apply(Command::RestoreFolder {
            parent,
            position,
            folder,
        })
    }

    pub(crate) fn deleted_folder_restore_target(&self, folder_id: FolderId) -> (FolderId, usize) {
        if let Some(origin) = self.workspace.deleted_folder_origin(folder_id) {
            if self.is_valid_folder_restore_parent(origin.parent) {
                let len = self
                    .workspace
                    .folder(origin.parent)
                    .map(|folder| folder.children.len())
                    .unwrap_or(0);
                return (origin.parent, origin.position.min(len));
            }
        }

        let root = self.workspace.root;
        let position = self
            .workspace
            .folder(root)
            .map(|folder| folder.children.len())
            .unwrap_or(0);
        (root, position)
    }

    pub(crate) fn is_valid_folder_restore_parent(&self, folder_id: FolderId) -> bool {
        self.workspace.folder(folder_id).is_some()
            && !self
                .workspace
                .is_node_in_deleted_folder_subtree(NodeRef::Folder(folder_id))
    }

    pub(crate) fn empty_archive(&mut self) -> Result<()> {
        // Archived folders first — each takes its whole subtree (nested folders
        // and schemes) with it — then any standalone archived schemes that remain.
        let deleted_folders = self.workspace.recently_deleted_folders.clone();
        for id in deleted_folders {
            self.apply(Command::PermanentlyDeleteFolder { id })?;
        }
        let deleted = self.workspace.recently_deleted.clone();
        for id in deleted {
            if self.workspace.is_scheme_deleted(id) {
                self.apply(Command::PermanentlyDeleteScheme { id })?;
            }
        }
        Ok(())
    }

    pub(crate) fn deleted_scheme_restore_target(&self, scheme_id: SchemeId) -> (FolderId, usize) {
        if let Some(origin) = self.workspace.deleted_scheme_origin(scheme_id) {
            if self.is_valid_scheme_restore_folder(origin.folder) {
                let len = self
                    .workspace
                    .folder(origin.folder)
                    .map(|folder| folder.children.len())
                    .unwrap_or(0);
                return (origin.folder, origin.position.min(len));
            }
        }

        let root = self.workspace.root;
        let position = self
            .workspace
            .folder(root)
            .map(|folder| folder.children.len())
            .unwrap_or(0);
        (root, position)
    }

    pub(crate) fn is_valid_scheme_restore_folder(&self, folder: FolderId) -> bool {
        self.workspace.folder(folder).is_some()
            && !self.workspace.is_folder_deleted(folder)
            && !self
                .workspace
                .is_node_in_deleted_folder_subtree(NodeRef::Folder(folder))
    }

    pub(crate) fn insert_table(
        &mut self,
        scheme_id: SchemeId,
        after_item_id: Option<ItemId>,
        item_id: ItemId,
    ) -> Result<()> {
        if self.workspace.is_scheme_read_only(scheme_id) {
            return Err(anyhow!("scheme is read-only"));
        }

        let position = {
            let scheme = self
                .workspace
                .scheme(scheme_id)
                .ok_or_else(|| anyhow!("scheme {scheme_id} is missing"))?;
            after_item_id
                .and_then(|item_id| scheme.item_index(item_id).map(|index| index + 1))
                .unwrap_or(scheme.items.len())
        };

        // Use the caller-supplied id so the editor's optimistically-rendered
        // table and the persisted item share identity from the first frame.
        let mut item = Item::new("");
        item.id = item_id;
        item.set_table(Table::new(2, 2));
        self.apply(Command::InsertItem {
            scheme: scheme_id,
            position,
            item,
        })
    }

    pub(crate) fn mutate_table(
        &mut self,
        scheme_id: SchemeId,
        item_id: ItemId,
        mutate: impl FnOnce(&mut Table) -> Result<()>,
    ) -> Result<()> {
        if self.workspace.is_scheme_read_only(scheme_id) {
            return Err(anyhow!("scheme is read-only"));
        }

        let mut item = self
            .workspace
            .scheme(scheme_id)
            .and_then(|scheme| scheme.items.iter().find(|item| item.id == item_id))
            .cloned()
            .ok_or_else(|| anyhow!("item {item_id} is missing in scheme {scheme_id}"))?;
        let table = item
            .table_mut()
            .ok_or_else(|| anyhow!("item {item_id} does not contain a table"))?;
        mutate(table)?;
        table.normalize();
        self.apply(Command::ReplaceItem {
            scheme: scheme_id,
            item,
        })
    }

    pub(crate) fn seed_editor_image_fixture(&mut self) -> Result<()> {
        if self.workspace.iter_schemes().any(|scheme| {
            scheme
                .items
                .iter()
                .any(|item| item.text() == EDITOR_IMAGE_FIXTURE_TEXT)
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

        // Single-content: the caption and the image are two separate lines.
        let caption = Item::new(EDITOR_IMAGE_FIXTURE_TEXT);
        let mut image_item = Item::new("");
        image_item.set_image(ImageInline {
            asset,
            format: ImageAssetFormat::Png,
            width: Some(320),
            height: Some(180),
        });

        let scheme = self
            .workspace
            .scheme_mut(target_id)
            .ok_or_else(|| anyhow!("scheme {target_id} is missing"))?;
        scheme.items.push(caption);
        scheme.items.push(image_item);
        self.record_crdt_changes(WorkspaceCrdtChangeSet::default().touch_scheme(target_id))?;
        self.save_workspace()
    }

    pub(crate) fn replace_scheme_items(
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
            let existing_item = existing_id.and_then(|id| {
                if used_ids.contains(&id) {
                    return None;
                }
                existing.iter().find(|item| item.id == id).cloned()
            });
            let has_rich_metadata = draft.start.is_some()
                || draft.end.is_some()
                || draft.notification_offset_secs.is_some()
                || draft
                    .repeat_rule
                    .as_deref()
                    .is_some_and(|rule| !rule.trim().is_empty())
                || !draft.media.is_empty();
            let should_apply_rich_metadata = existing_item.is_none() || has_rich_metadata;
            let mut item = existing_item.unwrap_or_else(|| {
                let mut item = Item::new("");
                // Adopt a caller-minted id (as `insert_table` does): the shell
                // mints ids for lines it must render before the round-trip
                // (e.g. remote-merge reloads mid-edit), and each flush of such
                // a line must land on ONE item instead of re-creating it under
                // a fresh id every time.
                if let Some(id) = existing_id.filter(|id| !used_ids.contains(id)) {
                    item.id = id;
                }
                item
            });

            used_ids.push(item.id);
            // A line is single-content. A bulk save sends empty `content`/`media`
            // for an existing image/table line (its block lives only in
            // `content`, which the editor may omit), so preserve the block rather
            // than let `set_text` clobber it. When content/media *are* supplied,
            // or the line was text, the incoming text/content wins.
            let preserve_existing_block =
                item.content.is_block() && draft.content.is_empty() && draft.media.is_empty();
            if !preserve_existing_block {
                item.set_text(draft.text);
            }
            item.marker = parse_marker(Some(&draft.marker))?;
            item.indent = as_u8(draft.indent, "indent")?.min(8);
            if should_apply_rich_metadata {
                item.start = parse_datetime_opt(draft.start.as_deref())?;
                item.end = parse_datetime_opt(draft.end.as_deref())?;
                item.repeats = recurrence_from_rrule(draft.repeat_rule);
                // Legacy text+media path: rebuild the inline run, swapping the
                // attached images, then collapse back to single-content (a block
                // wins, so a line with media becomes an image line).
                let mut inlines = item.content.to_inlines();
                inlines.retain(|inline| !matches!(inline, Inline::Image(_)));
                inlines.extend(
                    draft
                        .media
                        .iter()
                        .filter_map(|media| {
                            mobile_media_to_item_media(media, &self.image_assets_dir)
                        })
                        .map(Inline::Image),
                );
                item.content = ItemContent::from_inlines(inlines);
            }
            item.enforce_marker_constraints();
            if !draft.content.is_empty() {
                item.content = ItemContent::from_inlines(mobile_inlines_to_inlines(
                    &draft.content,
                    &self.image_assets_dir,
                )?);
            }
            if item.marker == ItemMarker::Checkbox {
                let state = item.state_for_occurrence_mut(OccurrenceId::Single);
                state.progress = if draft.done { -1 } else { 0 };
                if should_apply_rich_metadata {
                    state.notification_offset_secs = draft.notification_offset_secs.map(i64::from);
                }
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
        let t0 = std::time::Instant::now();
        self.record_crdt_changes(WorkspaceCrdtChangeSet::default().touch_scheme(scheme_id))?;
        let t1 = std::time::Instant::now();
        let saved = self.save_workspace();
        if knotq_storage_json::edit_timing_enabled() {
            eprintln!(
                "replace_scheme_items: crdt+pending {}ms, save_workspace {}ms",
                (t1 - t0).as_millis(),
                t1.elapsed().as_millis()
            );
        }
        saved
    }
}
