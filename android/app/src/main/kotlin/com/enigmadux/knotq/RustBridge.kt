package com.enigmadux.knotq

import android.content.Context
import com.enigmadux.knotq.ffi.MobileCalendar
import com.enigmadux.knotq.ffi.MobileCalendarDay
import com.enigmadux.knotq.ffi.MobileCore
import com.enigmadux.knotq.ffi.MobileDailyEntry
import com.enigmadux.knotq.ffi.MobileItem
import com.enigmadux.knotq.ffi.MobileItemEdit
import com.enigmadux.knotq.ffi.MobileItemMedia
import com.enigmadux.knotq.ffi.MobileNode
import com.enigmadux.knotq.ffi.MobileOccurrence
import com.enigmadux.knotq.ffi.MobileScheme
import com.enigmadux.knotq.ffi.MobileSearchHit
import com.enigmadux.knotq.ffi.MobileSettings
import com.enigmadux.knotq.ffi.MobileSnapshot
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
            "snapshot" -> return core.snapshot(body.stringOrNull("today"), body.optInt("week_offset", 0)).toJson()
            "create_folder" -> core.createFolder(body.getString("name"), body.intOrNull("position"))
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
            "empty_archive" -> core.emptyArchive()
            "move_node" -> core.moveNode(
                body.getString("kind"),
                body.getString("id"),
                body.getString("folder_id"),
                body.getInt("position")
            )
            "ensure_daily_queue" -> core.ensureDailyQueue(body.stringOrNull("date"))
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
            "toggle_item" -> core.toggleItem(body.getString("scheme_id"), body.getString("item_id"))
            "delete_item" -> core.deleteItem(body.getString("scheme_id"), body.getString("item_id"))
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
            "reset_workspace" -> core.resetWorkspace()
            else -> error("Unknown Rust request: ${body.getString("type")}")
        }
        return JSONObject()
    }

    fun requestArray(body: JSONObject): JSONArray {
        return when (body.getString("type")) {
            "search" -> core.search(body.getString("query")).toJsonArray { it.toJson() }
            else -> error("Unknown Rust array request: ${body.getString("type")}")
        }
    }

    override fun close() {
        core.close()
    }

    private fun MobileSnapshot.toJson(): JSONObject = JSONObject()
        .put("root", root.toJson())
        .put("schemes", schemes.toJsonArray { it.toJson() })
        .put("archived_schemes", archivedSchemes.toJsonArray { it.toJson() })
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
        .put("children", children.toJsonArray { it.toJson() })

    private fun MobileScheme.toJson(): JSONObject = JSONObject()
        .put("id", id)
        .put("name", name)
        .put("display_name", displayName)
        .put("color_index", colorIndex)
        .put("is_daily_queue", isDailyQueue)
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
        .put("media", media.toJsonArray { it.toJson() })

    private fun MobileItemMedia.toJson(): JSONObject = JSONObject()
        .put("kind", kind)
        .put("path", path ?: JSONObject.NULL)
        .put("format", format)
        .put("width", width ?: JSONObject.NULL)
        .put("height", height ?: JSONObject.NULL)

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
        .put("scheme_name", schemeName)
        .put("color_index", colorIndex)
        .put("title", title)
        .put("kind", kind)
        .put("done", done)
        .put("start", start ?: JSONObject.NULL)
        .put("end", end ?: JSONObject.NULL)
        .put("local_date", localDate ?: JSONObject.NULL)

    private fun MobileSettings.toJson(): JSONObject = JSONObject()
        .put("theme_mode", themeMode)
        .put("time_format", timeFormat)

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
                    done = item.optBoolean("done", false)
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
