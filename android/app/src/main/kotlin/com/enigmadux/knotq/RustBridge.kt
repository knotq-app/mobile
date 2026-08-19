package com.enigmadux.knotq

import android.content.Context
import com.enigmadux.knotq.ffi.MobileCalendar
import com.enigmadux.knotq.ffi.MobileCalendarDay
import com.enigmadux.knotq.ffi.MobileCore
import com.enigmadux.knotq.ffi.MobileDailyEntry
import com.enigmadux.knotq.ffi.MobileGoogleAccount
import com.enigmadux.knotq.ffi.MobileGoogleIdentityAccount
import com.enigmadux.knotq.ffi.MobileGoogleSyncResult
import com.enigmadux.knotq.ffi.MobileCellLine
import com.enigmadux.knotq.ffi.MobileInline
import com.enigmadux.knotq.ffi.MobileItem
import com.enigmadux.knotq.ffi.MobileItemEdit
import com.enigmadux.knotq.ffi.MobileItemMedia
import com.enigmadux.knotq.ffi.MobileNode
import com.enigmadux.knotq.ffi.MobileNotificationRequest
import com.enigmadux.knotq.ffi.MobileOccurrence
import com.enigmadux.knotq.ffi.MobileScheme
import com.enigmadux.knotq.ffi.MobileSearchHit
import com.enigmadux.knotq.ffi.MobileSettings
import com.enigmadux.knotq.ffi.MobileSnapshot
import com.enigmadux.knotq.ffi.MobileTable
import com.enigmadux.knotq.ffi.MobileTableCell
import com.enigmadux.knotq.ffi.MobileTableColumn
import com.enigmadux.knotq.ffi.MobileTableRow
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

internal class RustBridge(context: Context) : AutoCloseable {
    private val core: MobileCore

    init {
        val appDir = File(context.filesDir, "KnotQMobile")
        if (!appDir.exists() && !appDir.mkdirs()) {
            error("Could not create $appDir")
        }
        core = MobileCore(appDir.absolutePath)
    }

    fun request(body: JSONObject): JSONObject {
        when (body.getString("type")) {
            "snapshot" -> return core.snapshotWithDailyHistory(
                body.stringOrNull("today"),
                body.optInt("week_offset", 0),
                body.optInt("daily_history_days", 3)
            ).toJson()
            // Google Identity issues the access token on Android, so the core is
            // handed the token directly. The core's browser/loopback OAuth entry
            // points remain for the desktop and iOS shells, which still use them,
            // but Android has no caller for them: Google blocks that flow here.
            "import_google_calendars_with_identity" -> return core.importGoogleCalendarsWithIdentity(
                body.getJSONObject("account").toMobileGoogleIdentityAccount(),
                body.stringOrNull("parent_id")
            ).toJson()
            "sync_google_calendars" -> return core.syncGoogleCalendars().toJson()
            "sync_google_calendars_with_identity" -> return core.syncGoogleCalendarsWithIdentity(
                body.optJSONArray("accounts")?.toMobileGoogleIdentityAccounts() ?: emptyList()
            ).toJson()
            "set_google_account_needs_reauth" -> core.setGoogleAccountNeedsReauth(
                body.getString("account_id"),
                body.getBoolean("needs_reauth")
            )
            "unlink_google_account" -> core.unlinkGoogleAccount(body.getString("account_id"))
            "create_folder" -> core.createFolder(body.stringOrNull("parent_id"), body.getString("name"), body.intOrNull("position"))
            "rename_folder" -> core.renameFolder(body.getString("folder_id"), body.getString("name"))
            "delete_folder" -> core.deleteFolder(body.getString("folder_id"))
            "create_scheme" -> core.createScheme(
                body.stringOrNull("folder_id"),
                body.getString("name"),
                body.intOrNull("color_index"),
                body.intOrNull("position")
            )
            "rename_scheme" -> core.renameScheme(body.getString("scheme_id"), body.getString("name"))
            "set_scheme_color" -> core.setSchemeColor(body.getString("scheme_id"), body.getInt("color_index"))
            "delete_scheme" -> core.deleteScheme(body.getString("scheme_id"))
            "restore_scheme" -> core.restoreScheme(body.getString("scheme_id"))
            "permanently_delete_scheme" -> core.permanentlyDeleteScheme(body.getString("scheme_id"))
            "restore_folder" -> core.restoreFolder(body.getString("folder_id"))
            "permanently_delete_folder" -> core.permanentlyDeleteFolder(body.getString("folder_id"))
            "empty_archive" -> core.emptyArchive()
            "move_node" -> core.moveNode(
                body.getString("kind"),
                body.getString("id"),
                body.getString("folder_id"),
                body.getInt("position")
            )
            // `created` lets the caller skip a snapshot rebuild on the common
            // path where the day's queue is already there.
            "ensure_daily_queue" -> return JSONObject().put(
                "created",
                core.ensureDailyQueue(body.stringOrNull("date"))
            )
            "add_today_daily_item" -> core.addTodayDailyItem(
                body.getString("today"),
                body.getString("text"),
                body.stringOrNull("marker"),
                body.intOrNull("indent")
            )
            "add_item" -> core.addItem(
                body.getString("scheme_id"),
                body.getString("text"),
                body.stringOrNull("marker"),
                body.intOrNull("position"),
                body.intOrNull("indent")
            )
            "add_calendar_item" -> core.addCalendarItem(
                body.stringOrNull("scheme_id"),
                body.stringOrNull("date"),
                body.getString("text"),
                body.getString("kind"),
                body.stringOrNull("start"),
                body.stringOrNull("end")
            )
            "update_item_text" -> core.updateItemText(
                body.getString("scheme_id"),
                body.getString("item_id"),
                body.getString("text")
            )
            "set_item_marker" -> core.setItemMarker(
                body.getString("scheme_id"),
                body.getString("item_id"),
                body.getString("marker")
            )
            "set_item_indent" -> core.setItemIndent(
                body.getString("scheme_id"),
                body.getString("item_id"),
                body.getInt("indent")
            )
            "set_item_date" -> core.setItemDate(
                body.getString("scheme_id"),
                body.getString("item_id"),
                body.getString("kind"),
                body.stringOrNull("date")
            )
            "set_item_recurrence" -> core.setItemRecurrence(
                body.getString("scheme_id"),
                body.getString("item_id"),
                body.stringOrNull("rrule")
            )
            "set_occurrence_notification_offset" -> core.setOccurrenceNotificationOffset(
                body.getString("scheme_id"),
                body.getString("item_id"),
                body.stringOrNull("occurrence_json"),
                body.intOrNull("offset_secs")
            )
            // The 14-argument FFI form mis-marshals its trailing booleans
            // through JNA/libffi on device, so this goes through the
            // single-JSON-argument variant.
            "commit_event_edit" -> core.commitEventEditPayload(
                JSONObject()
                    .put("scheme_id", body.getString("scheme_id"))
                    .put("item_id", body.getString("item_id"))
                    .put("occurrence_json", body.getString("occurrence_json"))
                    .put("occurrence_index", body.optInt("occurrence_index", 0))
                    .put("title", body.getString("title"))
                    .putOpt("occurrence_start", body.stringOrNull("occurrence_start"))
                    .putOpt("occurrence_end", body.stringOrNull("occurrence_end"))
                    .putOpt("start", body.stringOrNull("start"))
                    .putOpt("end", body.stringOrNull("end"))
                    .putOpt("rrule", body.stringOrNull("rrule"))
                    .putOpt("notification_offset_secs", body.intOrNull("notification_offset_secs"))
                    .put("notification_dirty", body.optBoolean("notification_dirty", false))
                    .put("done", body.optBoolean("done", false))
                    .put("scope", body.optString("scope", "all_events"))
                    .toString()
            )
            "toggle_item" -> core.toggleItem(body.getString("scheme_id"), body.getString("item_id"))
            "toggle_occurrence" -> core.toggleOccurrence(
                body.getString("scheme_id"),
                body.getString("item_id"),
                body.getString("occurrence_json")
            )
            "delete_item" -> core.deleteItem(body.getString("scheme_id"), body.getString("item_id"))
            "delete_event_occurrence" -> core.deleteEventOccurrence(
                body.getString("scheme_id"),
                body.getString("item_id"),
                body.getString("occurrence_json"),
                body.optInt("occurrence_index", 0),
                body.optString("scope", "all_events")
            )
            "reorder_item" -> core.reorderItem(
                body.getString("scheme_id"),
                body.getInt("from"),
                body.getInt("to")
            )
            "replace_scheme_items" -> core.replaceSchemeItems(
                body.getString("scheme_id"),
                body.optJSONArray("items")?.toMobileItemEdits() ?: emptyList()
            )
            "set_theme_mode" -> core.setThemeMode(body.getString("theme_mode"))
            "set_time_format" -> core.setTimeFormat(body.getString("time_format"))
            "set_notification_defaults" -> core.setNotificationDefaults(
                body.getInt("event_offset_secs"),
                body.getInt("assignment_offset_secs")
            )
            "set_upcoming_display_settings" -> core.setUpcomingDisplaySettings(
                body.getInt("event_lookahead_days"),
                body.getInt("reminder_lookahead_days"),
                body.getInt("assignment_lookahead_days"),
                body.getInt("maximum_items"),
                body.getBoolean("show_overdue"),
                body.getBoolean("show_completed")
            )
            "reset_workspace" -> core.resetWorkspace()
            "apply_notification_action" -> return JSONObject().put(
                "changed",
                core.applyNotificationAction(
                    body.getString("action_id"),
                    body.getString("scheme_id"),
                    body.getString("item_id"),
                    body.getString("occurrence_json"),
                    body.getString("trigger_at")
                )
            )
            "sync_once" -> {
                val changed = core.syncOnce(body.getString("api_base"), body.getString("bearer_token"))
                val notice = core.takeSyncNotice()
                val response = JSONObject().put("changed", changed)
                if (notice != null) {
                    response.put("notice", notice)
                }
                return response
            }
            "set_push_registration" -> core.setPushRegistration(
                body.getString("token"),
                body.getString("environment")
            )
            "seed_editor_image_fixture" -> core.seedEditorImageFixture()
            "ws_start" -> core.startWsSync(body.getString("api_base"), body.getString("bearer_token"))
            "ws_stop" -> core.stopWsSync()
            "ws_pending_changed" -> return JSONObject().put("pending", core.wsPendingChanged())
            "note_remote_changed" -> core.noteRemoteChanged()
            "ws_connected" -> return JSONObject().put("connected", core.isWsConnected())
            else -> error("Unknown Rust request: ${body.getString("type")}")
        }
        return JSONObject()
    }

    fun requestArray(body: JSONObject): JSONArray {
        return when (body.getString("type")) {
            "search" -> core.search(body.getString("query")).toJsonArray { it.toJson() }
            "month_days" -> core.monthDays(
                body.getInt("year"),
                body.getInt("month").toUInt()
            ).toJsonArray { it.toJson() }
            "pending_notifications" -> core.pendingNotifications(null, 14).toJsonArray { it.toJson() }
            "delivered_notifications_to_clear" -> JSONArray().apply {
                core.deliveredNotificationsToClear(null).forEach { put(it) }
            }
            else -> error("Unknown Rust array request: ${body.getString("type")}")
        }
    }

    override fun close() {
        core.close()
    }

    // Thin table-cell wrappers mirroring the existing typed FFI calls. The
    // editor edits cells line-by-line (each cell holds a list of `lines`), so
    // these are the per-line variants plus the row/column structural edits.
    fun insertTable(schemeId: String, afterItemId: String?, itemId: String) =
        core.insertTable(schemeId, afterItemId, itemId)

    fun setTableCellLineText(schemeId: String, itemId: String, row: Int, column: Int, lineIndex: Int, text: String) =
        core.setTableCellLineText(schemeId, itemId, row, column, lineIndex, text)

    fun addTableCellLine(schemeId: String, itemId: String, row: Int, column: Int, lineIndex: Int, text: String) =
        core.addTableCellLine(schemeId, itemId, row, column, lineIndex, text)

    fun removeTableCellLine(schemeId: String, itemId: String, row: Int, column: Int, lineIndex: Int) =
        core.removeTableCellLine(schemeId, itemId, row, column, lineIndex)

    fun setTableCellText(schemeId: String, itemId: String, row: Int, column: Int, text: String) =
        core.setTableCellText(schemeId, itemId, row, column, text)

    fun setTableColumnName(schemeId: String, itemId: String, column: Int, name: String) =
        core.setTableColumnName(schemeId, itemId, column, name)

    fun insertTableRow(schemeId: String, itemId: String, row: Int) =
        core.insertTableRow(schemeId, itemId, row)

    fun deleteTableRow(schemeId: String, itemId: String, row: Int) =
        core.deleteTableRow(schemeId, itemId, row)

    fun insertTableColumn(schemeId: String, itemId: String, column: Int) =
        core.insertTableColumn(schemeId, itemId, column)

    fun deleteTableColumn(schemeId: String, itemId: String, column: Int) =
        core.deleteTableColumn(schemeId, itemId, column)

    private fun MobileSnapshot.toJson(): JSONObject = JSONObject()
        .put("root", root.toJson())
        .put("schemes", schemes.toJsonArray { it.toJson() })
        .put("archived_schemes", archivedSchemes.toJsonArray { it.toJson() })
        .put("archived_nodes", archivedNodes.toJsonArray { it.toJson() })
        .put("daily", daily.toJsonArray { it.toJson() })
        .put("calendar", calendar.toJson())
        .put("settings", settings.toJson())
        .put("workspace_path", workspacePath)

    private fun MobileNode.toJson(): JSONObject = JSONObject()
        .put("kind", kind)
        .put("id", id)
        .put("name", name)
        .put("color_index", colorIndex ?: JSONObject.NULL)
        .put("is_daily_queue", isDailyQueue)
        .put("is_read_only", isReadOnly)
        .put("children", children.toJsonArray { it.toJson() })

    private fun MobileScheme.toJson(): JSONObject = JSONObject()
        .put("id", id)
        .put("name", name)
        .put("display_name", displayName)
        .put("color_index", colorIndex)
        .put("is_daily_queue", isDailyQueue)
        .put("is_read_only", isReadOnly)
        .put("date", date ?: JSONObject.NULL)
        .put("items", items.toJsonArray { it.toJson() })

    private fun MobileItem.toJson(): JSONObject = JSONObject()
        .put("id", id)
        .put("text", text)
        .put("marker", marker)
        .put("indent", indent)
        .put("kind", kind)
        .put("done", done)
        .put("start", start ?: JSONObject.NULL)
        .put("end", end ?: JSONObject.NULL)
        .put("notification_offset_secs", notificationOffsetSecs ?: JSONObject.NULL)
        .put("repeat_rule", repeatRule ?: JSONObject.NULL)
        .put("media", media.toJsonArray { it.toJson() })
        .put("tables", tables.toJsonArray { it.toJson() })
        .put("content", content.toJsonArray { it.toJson() })

    // Inlines in document order: text runs, images, and tables. The editor uses
    // this to render blocks in place rather than the flat media/tables lists.
    private fun MobileInline.toJson(): JSONObject = when (this) {
        is MobileInline.Text -> JSONObject().put("kind", "text").put("text", text)
        is MobileInline.Image -> JSONObject().put("kind", "image").put("media", media.toJson())
        is MobileInline.Table -> JSONObject().put("kind", "table").put("table", table.toJson())
    }

    private fun MobileItemMedia.toJson(): JSONObject = JSONObject()
        .put("kind", kind)
        .put("path", path ?: JSONObject.NULL)
        .put("format", format)
        .put("width", width ?: JSONObject.NULL)
        .put("height", height ?: JSONObject.NULL)

    private fun MobileTable.toJson(): JSONObject = JSONObject()
        .put("columns", columns.toJsonArray { it.toJson() })
        .put("rows", rows.toJsonArray { it.toJson() })

    private fun MobileTableColumn.toJson(): JSONObject = JSONObject()
        .put("id", id)
        .put("name", name)

    private fun MobileTableRow.toJson(): JSONObject = JSONObject()
        .put("id", id)
        .put("cells", cells.toJsonArray { it.toJson() })

    private fun MobileTableCell.toJson(): JSONObject = JSONObject()
        .put("text", text)
        .put("lines", lines.toJsonArray { it.toJson() })

    private fun MobileCellLine.toJson(): JSONObject = JSONObject()
        .put("id", id)
        .put("text", text)
        .put("marker", marker)
        .put("done", done)
        .put("start", start ?: JSONObject.NULL)
        .put("end", end ?: JSONObject.NULL)
        .put("media", media.toJsonArray { it.toJson() })

    private fun MobileDailyEntry.toJson(): JSONObject = JSONObject()
        .put("date", date)
        .put("scheme", scheme.toJson())

    private fun MobileCalendar.toJson(): JSONObject = JSONObject()
        .put("start_date", startDate)
        .put("end_date", endDate)
        .put("days", days.toJsonArray { it.toJson() })
        .put("upcoming", upcoming.toJsonArray { it.toJson() })
        .put("overdue", overdue.toJsonArray { it.toJson() })

    private fun MobileCalendarDay.toJson(): JSONObject = JSONObject()
        .put("date", date)
        .put("occurrences", occurrences.toJsonArray { it.toJson() })

    private fun MobileOccurrence.toJson(): JSONObject = JSONObject()
        .put("scheme_id", schemeId)
        .put("item_id", itemId)
        .put("occurrence_json", occurrenceJson)
        .put("occurrence_index", occurrenceIndex)
        .put("is_recurring", isRecurring)
        .put("can_delete_future", canDeleteFuture)
        .put("scheme_name", schemeName)
        .put("color_index", colorIndex)
        .put("is_read_only", isReadOnly)
        .put("title", title)
        .put("kind", kind)
        .put("done", done)
        .put("start", start ?: JSONObject.NULL)
        .put("end", end ?: JSONObject.NULL)
        .put("notification_offset_secs", notificationOffsetSecs ?: JSONObject.NULL)
        .put("local_date", localDate ?: JSONObject.NULL)
        .put("repeat_rule", repeatRule ?: JSONObject.NULL)

    private fun MobileSettings.toJson(): JSONObject = JSONObject()
        .put("theme_mode", themeMode)
        .put("time_format", timeFormat)
        .put("event_notification_offset_secs", eventNotificationOffsetSecs)
        .put("assignment_notification_offset_secs", assignmentNotificationOffsetSecs)
        .put("event_lookahead_days", eventLookaheadDays)
        .put("reminder_lookahead_days", reminderLookaheadDays)
        .put("assignment_lookahead_days", assignmentLookaheadDays)
        .put("maximum_upcoming_items", maximumUpcomingItems)
        .put("show_overdue", showOverdue)
        .put("show_completed", showCompleted)
        .put("google_account_count", googleAccountCount)
        .put("google_accounts", googleAccounts.toJsonArray { it.toJson() })

    private fun MobileGoogleAccount.toJson(): JSONObject = JSONObject()
        .put("id", id)
        .put("title", title)
        .put("detail", detail)
        .put("email", email)
        .put("needs_reauth", needsReauth)

    private fun JSONObject.toMobileGoogleIdentityAccount(): MobileGoogleIdentityAccount =
        MobileGoogleIdentityAccount(
            accountId = stringOrNull("account_id"),
            clientId = optString("client_id"),
            accessToken = optString("access_token"),
            email = stringOrNull("email"),
            scope = stringOrNull("scope"),
            expiresInSecs = if (has("expires_in_secs") && !isNull("expires_in_secs")) {
                optLong("expires_in_secs")
            } else {
                null
            }
        )

    private fun JSONArray.toMobileGoogleIdentityAccounts(): List<MobileGoogleIdentityAccount> {
        val out = ArrayList<MobileGoogleIdentityAccount>(length())
        for (index in 0 until length()) {
            val item = optJSONObject(index) ?: continue
            out.add(item.toMobileGoogleIdentityAccount())
        }
        return out
    }

    private fun MobileGoogleSyncResult.toJson(): JSONObject = JSONObject()
        .put("imported_count", importedCount)
        .put("synced_count", syncedCount)
        .put("failure_count", failureCount)
        .put("message", message)

    private fun MobileNotificationRequest.toJson(): JSONObject = JSONObject()
        .put("id", id)
        .put("notification_key", notificationKey)
        .put("fire_at", fireAt)
        .put("expires_at", expiresAt ?: JSONObject.NULL)
        .put("end_at", endAt ?: JSONObject.NULL)
        .put("title", title)
        .put("body", body)
        .put("kind", kind)
        .put("scheme_id", schemeId)
        .put("item_id", itemId)
        .put("occurrence_json", occurrenceJson)
        .put("trigger_at", triggerAt)

    private fun MobileSearchHit.toJson(): JSONObject = JSONObject()
        .put("target_kind", targetKind)
        .put("scheme_id", schemeId ?: JSONObject.NULL)
        .put("item_id", itemId ?: JSONObject.NULL)
        .put("scheme_name", schemeName)
        .put("color_index", colorIndex ?: JSONObject.NULL)
        .put("title", title)
        .put("detail", detail)
        .put("status", status)

    private fun <T> List<T>.toJsonArray(transform: (T) -> JSONObject): JSONArray {
        val array = JSONArray()
        forEach { array.put(transform(it)) }
        return array
    }

    private fun JSONArray.toMobileItemEdits(): List<MobileItemEdit> {
        val out = ArrayList<MobileItemEdit>(length())
        for (index in 0 until length()) {
            val item = optJSONObject(index) ?: continue
            out.add(
                MobileItemEdit(
                    id = item.stringOrNull("id"),
                    text = item.optString("text"),
                    marker = item.optString("marker", "blank"),
                    indent = item.optInt("indent", 0),
                    done = item.optBoolean("done", false),
                    start = item.stringOrNull("start"),
                    end = item.stringOrNull("end"),
                    notificationOffsetSecs = item.intOrNull("notification_offset_secs") ?: item.intOrNull("notificationOffsetSecs"),
                    repeatRule = item.stringOrNull("repeat_rule") ?: item.stringOrNull("repeatRule"),
                    media = item.optJSONArray("media")?.toMobileItemMedia() ?: emptyList(),
                    content = item.optJSONArray("content")?.toMobileInlines() ?: emptyList()
                )
            )
        }
        return out
    }

    private fun JSONArray.toMobileItemMedia(): List<MobileItemMedia> {
        val out = ArrayList<MobileItemMedia>(length())
        for (index in 0 until length()) {
            val item = optJSONObject(index) ?: continue
            out.add(
                MobileItemMedia(
                    kind = item.optString("kind"),
                    path = item.stringOrNull("path"),
                    format = item.optString("format"),
                    width = item.intOrNull("width"),
                    height = item.intOrNull("height")
                )
            )
        }
        return out
    }

    private fun JSONArray.toMobileInlines(): List<MobileInline> {
        val out = ArrayList<MobileInline>(length())
        for (index in 0 until length()) {
            val item = optJSONObject(index) ?: continue
            when (item.optString("kind")) {
                "text" -> out.add(MobileInline.Text(item.optString("text")))
                "image" -> item.optJSONObject("media")?.let { out.add(MobileInline.Image(it.toMobileItemMedia())) }
                "table" -> item.optJSONObject("table")?.let { out.add(MobileInline.Table(it.toMobileTable())) }
            }
        }
        return out
    }

    private fun JSONObject.toMobileItemMedia(): MobileItemMedia =
        MobileItemMedia(
            kind = optString("kind"),
            path = stringOrNull("path"),
            format = optString("format"),
            width = intOrNull("width"),
            height = intOrNull("height")
        )

    private fun JSONObject.toMobileTable(): MobileTable =
        MobileTable(
            columns = optJSONArray("columns")?.toMobileTableColumns() ?: emptyList(),
            rows = optJSONArray("rows")?.toMobileTableRows() ?: emptyList()
        )

    private fun JSONArray.toMobileTableColumns(): List<MobileTableColumn> {
        val out = ArrayList<MobileTableColumn>(length())
        for (index in 0 until length()) {
            val item = optJSONObject(index) ?: continue
            out.add(MobileTableColumn(id = item.optString("id"), name = item.optString("name")))
        }
        return out
    }

    private fun JSONArray.toMobileTableRows(): List<MobileTableRow> {
        val out = ArrayList<MobileTableRow>(length())
        for (index in 0 until length()) {
            val item = optJSONObject(index) ?: continue
            out.add(
                MobileTableRow(
                    id = item.optString("id"),
                    cells = item.optJSONArray("cells")?.toMobileTableCells() ?: emptyList()
                )
            )
        }
        return out
    }

    private fun JSONArray.toMobileTableCells(): List<MobileTableCell> {
        val out = ArrayList<MobileTableCell>(length())
        for (index in 0 until length()) {
            val item = optJSONObject(index) ?: continue
            out.add(
                MobileTableCell(
                    text = item.optString("text"),
                    lines = item.optJSONArray("lines")?.toMobileCellLines() ?: emptyList()
                )
            )
        }
        return out
    }

    private fun JSONArray.toMobileCellLines(): List<MobileCellLine> {
        val out = ArrayList<MobileCellLine>(length())
        for (index in 0 until length()) {
            val item = optJSONObject(index) ?: continue
            out.add(
                MobileCellLine(
                    id = item.optString("id"),
                    text = item.optString("text"),
                    marker = item.optString("marker", "blank"),
                    done = item.optBoolean("done", false),
                    start = item.stringOrNull("start"),
                    end = item.stringOrNull("end"),
                    media = item.optJSONArray("media")?.toMobileItemMedia() ?: emptyList()
                )
            )
        }
        return out
    }

    private fun JSONObject.stringOrNull(key: String): String? =
        if (has(key) && !isNull(key)) optString(key) else null

    private fun JSONObject.intOrNull(key: String): Int? =
        if (has(key) && !isNull(key)) optInt(key) else null
}
