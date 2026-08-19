package com.enigmadux.knotq

import android.app.Activity
import android.app.AlertDialog
import android.app.DatePickerDialog
import android.app.TimePickerDialog
import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.ValueAnimator
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.Editable
import android.text.InputType
import android.text.TextPaint
import android.text.TextUtils
import android.text.TextWatcher
import android.util.Base64
import android.util.TypedValue
import android.view.ContextThemeWrapper
import android.view.GestureDetector
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.Gravity
import android.view.VelocityTracker
import android.view.View
import android.view.ViewConfiguration
import android.view.animation.DecelerateInterpolator
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequest
import androidx.work.WorkManager
import android.widget.ArrayAdapter
import android.widget.AdapterView
import android.widget.CheckBox
import android.widget.DatePicker
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.HorizontalScrollView
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Spinner
import android.widget.Switch
import android.widget.TextView
import android.widget.TimePicker
import android.widget.Toast
import com.android.billingclient.api.BillingClient
import com.android.billingclient.api.BillingClientStateListener
import com.android.billingclient.api.BillingFlowParams
import com.android.billingclient.api.BillingResult
import com.android.billingclient.api.PendingPurchasesParams
import com.android.billingclient.api.Purchase
import com.android.billingclient.api.PurchasesUpdatedListener
import com.android.billingclient.api.QueryProductDetailsParams
import com.android.billingclient.api.QueryPurchasesParams
import com.google.android.play.core.review.ReviewManagerFactory
import org.json.JSONArray
import org.json.JSONObject
import java.time.DayOfWeek
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.format.TextStyle
import java.io.File
import java.util.Locale
import java.util.UUID
import java.util.WeakHashMap
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.concurrent.TimeUnit
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

    internal fun MainActivity.showItemActions(schemeId: String, item: JSONObject, index: Int, count: Int) {
        val actions = arrayOf(
            L10n.t(this, "mobile.action.move_up"),
            L10n.t(this, "mobile.action.move_down"),
            L10n.t(this, "mobile.action.indent"),
            L10n.t(this, "mobile.action.outdent"),
            L10n.t(this, "common.edit"),
            L10n.t(this, "common.delete")
        )
        AlertDialog.Builder(this)
            .setTitle(item.optString("text").ifEmpty { L10n.t(this, "sidebar.context.item") })
            .setItems(actions) { _, which ->
                when (which) {
                    0 -> if (index > 0) mutate(obj("type" to "reorder_item", "scheme_id" to schemeId, "from" to index, "to" to index - 1))
                    1 -> if (index < count - 1) mutate(obj("type" to "reorder_item", "scheme_id" to schemeId, "from" to index, "to" to index + 1))
                    2 -> mutate(obj("type" to "set_item_indent", "scheme_id" to schemeId, "item_id" to item.optString("id"), "indent" to min(item.optInt("indent") + 1, 8)))
                    3 -> mutate(obj("type" to "set_item_indent", "scheme_id" to schemeId, "item_id" to item.optString("id"), "indent" to max(item.optInt("indent") - 1, 0)))
                    4 -> showItemDialog(schemeId, item)
                    5 -> mutate(obj("type" to "delete_item", "scheme_id" to schemeId, "item_id" to item.optString("id")))
                }
            }
            .show()
    }

    internal fun MainActivity.showSchemeActions(nodeOrScheme: JSONObject) {
        val id = nodeOrScheme.optString("id")
        val isDaily = nodeOrScheme.optBoolean("is_daily_queue", false)
        if (nodeOrScheme.optBoolean("is_read_only", false)) {
            AlertDialog.Builder(this)
                .setTitle(nodeOrScheme.optString("name", nodeOrScheme.optString("display_name")))
                .setItems(arrayOf(L10n.t(this, "mobile.action.open_scheme"))) { _, _ -> openScheme(id) }
                .show()
            return
        }
        AlertDialog.Builder(this)
            .setTitle(nodeOrScheme.optString("name", nodeOrScheme.optString("display_name")))
            .setItems(arrayOf(
                L10n.t(this, "common.rename"),
                L10n.t(this, "mobile.action.color"),
                L10n.t(this, "mobile.action.reorder"),
                L10n.t(this, "mobile.action.move_to_folder"),
                L10n.t(this, "sidebar.context.archive")
            )) { _, which ->
                when (which) {
                    0 -> showNameDialog(
                        L10n.t(this, "mobile.scheme.rename_title"),
                        nodeOrScheme.optString("name", nodeOrScheme.optString("display_name")),
                        { validateSchemeName(it, folderId = parentFolderIdForScheme(id), excludingId = id, checkDuplicates = !isDaily) }
                    ) { name -> mutate(obj("type" to "rename_scheme", "scheme_id" to id, "name" to name)) }
                    1 -> showColorDialog(id)
                    2 -> showReorderDialog(id)
                    3 -> showMoveToFolderDialog("scheme", id)
                    4 -> if (!isDaily) mutate(obj("type" to "delete_scheme", "scheme_id" to id))
                }
            }
            .show()
    }

    /// iOS-style swatch grid (3x2, same color order as the iOS popover) instead
    /// of a text list.
    internal fun MainActivity.showColorDialog(schemeId: String) {
        val currentIndex = findScheme(schemeId)?.optInt("color_index") ?: 0
        lateinit var dialog: AlertDialog
        val order = intArrayOf(0, 1, 5, 2, 3, 4)
        val grid = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            background = rounded(theme.bgModal, dp(14), theme.borderOverlay)
            setPadding(dp(10), dp(10), dp(10), dp(10))
        }
        for (rowStart in order.indices step 3) {
            grid.addView(LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER
                for (cell in rowStart until min(rowStart + 3, order.size)) {
                    val colorIndex = order[cell]
                    val selected = colorIndex == currentIndex
                    addView(FrameLayout(this@showColorDialog).apply {
                        background = rounded(if (selected) theme.rowSelected else Color.TRANSPARENT, dp(8))
                        addView(FrameLayout(this@showColorDialog).apply {
                            background = rounded(
                                schemeColor(colorIndex),
                                dp(6),
                                if (selected) theme.textPrimary else theme.borderOverlay,
                                if (selected) dp(2) else max(1, (0.8f * resources.displayMetrics.density).roundToInt())
                            )
                            if (selected) {
                                addView(
                                    iconImage(R.drawable.ic_knotq_check_24, if (theme.isDark) adjustAlpha(Color.BLACK, 0.82f) else Color.WHITE),
                                    FrameLayout.LayoutParams(dp(13), dp(13), Gravity.CENTER)
                                )
                            }
                        }, FrameLayout.LayoutParams(dp(28), dp(28), Gravity.CENTER))
                        setOnClickListener {
                            mutate(obj("type" to "set_scheme_color", "scheme_id" to schemeId, "color_index" to colorIndex))
                            dialog.dismiss()
                        }
                    }, LinearLayout.LayoutParams(dp(46), dp(46)).apply { setMargins(dp(3), dp(3), dp(3), dp(3)) })
                }
            }, LinearLayout.LayoutParams(-2, -2))
        }
        dialog = AlertDialog.Builder(this)
            .setView(grid)
            .create()
        dialog.show()
        dialog.window?.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
        dialog.window?.setLayout(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT)
    }

    internal fun MainActivity.showFolderActions(node: JSONObject) {
        AlertDialog.Builder(this)
            .setTitle(node.optString("name"))
            .setItems(arrayOf(
                L10n.t(this, "mobile.nav.new_scheme"),
                L10n.t(this, "sidebar.context.new_folder"),
                L10n.t(this, "common.rename"),
                L10n.t(this, "mobile.action.reorder"),
                L10n.t(this, "mobile.action.move_to_folder"),
                L10n.t(this, "sidebar.context.archive")
            )) { _, which ->
                when (which) {
                    0 -> quickCreateScheme(parentFolderId = node.optString("id"))
                    1 -> showNameDialog(L10n.t(this, "sidebar.context.new_folder"), "", { validateFolderName(it) }) { name ->
                        mutate(obj("type" to "create_folder", "parent_id" to node.optString("id"), "name" to name))
                    }
                    2 -> showNameDialog(L10n.t(this, "mobile.folder.rename_title"), node.optString("name"), { validateFolderName(it, excludingId = node.optString("id")) }) { name ->
                        mutate(obj("type" to "rename_folder", "folder_id" to node.optString("id"), "name" to name))
                    }
                    3 -> showReorderDialog(node.optString("id"))
                    4 -> showMoveToFolderDialog("folder", node.optString("id"), excludedFolderId = node.optString("id"))
                    5 -> AlertDialog.Builder(this)
                        .setTitle(L10n.t(this, "mobile.folder.archive_confirm_title", mapOf("name" to node.optString("name"))))
                        .setMessage(L10n.t(this, "mobile.folder.archive_confirm_body"))
                        .setNegativeButton(L10n.t(this, "common.cancel"), null)
                        .setPositiveButton(L10n.t(this, "sidebar.context.archive")) { _, _ ->
                            mutate(obj("type" to "delete_folder", "folder_id" to node.optString("id")))
                        }
                        .show()
                }
            }
            .show()
    }

    internal fun MainActivity.showArchiveActions() {
        AlertDialog.Builder(this)
            .setTitle(L10n.t(this, "sidebar.context.archive"))
            .setItems(arrayOf(L10n.t(this, "archive.empty_confirm_button"))) { _, which ->
                if (which == 0) mutate(obj("type" to "empty_archive"))
            }
            .show()
    }

    /// iOS `SettingsArchiveList`: the archive tree always expanded (folders by
    /// icon, schemes by color square), each row restorable inline; deletes are
    /// permanent and confirmed.
    internal fun MainActivity.renderArchivePage(): LinearLayout {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(theme.bgApp)
        }
        root.addView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(12), 0, dp(12), 0)
            background = underline(theme.bgApp)
            addView(iconChipImage(R.drawable.ic_knotq_chevron_left_24, L10n.t(this@renderArchivePage, "common.back"), iconSize = 20) {
                settingsShowingArchive = false
                render()
            })
            addView(text(L10n.t(this@renderArchivePage, "sidebar.context.archive"), theme.textPrimary, 16f, true).apply {
                gravity = Gravity.CENTER
            }, LinearLayout.LayoutParams(0, -1, 1f))
            addView(View(this@renderArchivePage), LinearLayout.LayoutParams(dp(32), dp(28)))
        }, LinearLayout.LayoutParams(-1, dp(44)))

        val body = page()
        val nodes = snapshot.optJSONArray("archived_nodes") ?: JSONArray()
        if (nodes.length() == 0) {
            body.addView(text(L10n.t(this, "mobile.archive.empty_state"), theme.textMuted, 14f, false).apply {
                setPadding(dp(2), dp(10), 0, 0)
            })
        } else {
            fun addRows(array: JSONArray, depth: Int) {
                array.forEachObject { node ->
                    body.addView(archiveNodeRow(node, depth), LinearLayout.LayoutParams(-1, dp(40)))
                    if (node.optString("kind") == "folder") {
                        node.optJSONArray("children")?.let { addRows(it, depth + 1) }
                    }
                }
            }
            addRows(nodes, 0)
            body.addView(text(L10n.t(this, "archive.empty_confirm_button"), theme.danger, 14f, true).apply {
                setPadding(dp(2), dp(16), dp(8), dp(10))
                setOnClickListener {
                    AlertDialog.Builder(this@renderArchivePage)
                        .setTitle(L10n.t(this@renderArchivePage, "archive.empty_confirm_title"))
                        .setMessage(L10n.t(this@renderArchivePage, "mobile.archive.empty_confirm_body"))
                        .setNegativeButton(L10n.t(this@renderArchivePage, "common.cancel"), null)
                        .setPositiveButton(L10n.t(this@renderArchivePage, "mobile.archive.delete_all_button")) { _, _ -> mutate(obj("type" to "empty_archive")) }
                        .show()
                }
            })
        }
        root.addView(scroll(body), LinearLayout.LayoutParams(-1, 0, 1f))
        return root
    }

    internal fun MainActivity.archiveNodeRow(node: JSONObject, depth: Int): View {
        val isFolder = node.optString("kind") == "folder"
        val id = node.optString("id")
        val name = node.optString("name").ifEmpty { if (isFolder) L10n.t(this, "sidebar.context.folder") else L10n.t(this, "sidebar.new_item_default_name") }
        fun restore() {
            mutate(obj(
                "type" to if (isFolder) "restore_folder" else "restore_scheme",
                (if (isFolder) "folder_id" else "scheme_id") to id
            ))
        }
        fun confirmPermanentDelete() {
            AlertDialog.Builder(this)
                .setTitle(L10n.t(this, "mobile.archive.delete_confirm_title", mapOf("name" to name)))
                .setMessage(if (isFolder) L10n.t(this, "mobile.archive.delete_confirm_body_folder") else L10n.t(this, "mobile.archive.delete_confirm_body_generic"))
                .setNegativeButton(L10n.t(this, "common.cancel"), null)
                .setPositiveButton(L10n.t(this, "common.delete")) { _, _ ->
                    mutate(obj(
                        "type" to if (isFolder) "permanently_delete_folder" else "permanently_delete_scheme",
                        (if (isFolder) "folder_id" else "scheme_id") to id
                    ))
                }
                .show()
        }
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(2 + depth * 16), 0, 0, 0)
            addView(FrameLayout(this@archiveNodeRow).apply {
                if (isFolder) {
                    addView(
                        iconImage(R.drawable.ic_knotq_folder_24, theme.textMuted),
                        FrameLayout.LayoutParams(dp(13), dp(13), Gravity.CENTER)
                    )
                } else {
                    addView(View(this@archiveNodeRow).apply {
                        background = rounded(adjustAlpha(schemeColor(node.optInt("color_index")), 0.72f), dp(2))
                    }, FrameLayout.LayoutParams(dp(11), dp(11), Gravity.CENTER))
                }
            }, LinearLayout.LayoutParams(dp(18), dp(18)))
            addView(text(name, theme.textPrimary, 14f, false).apply {
                maxLines = 1
                ellipsize = TextUtils.TruncateAt.END
            }, LinearLayout.LayoutParams(0, -2, 1f).apply { setMargins(dp(8), 0, dp(8), 0) })
            addView(text(L10n.t(this@archiveNodeRow, "sidebar.context.restore"), theme.accent, 13f, true).apply {
                setPadding(dp(8), dp(8), dp(8), dp(8))
                setOnClickListener { restore() }
            }, LinearLayout.LayoutParams(-2, -2))
            setOnLongClickListener {
                AlertDialog.Builder(this@archiveNodeRow)
                    .setTitle(name)
                    .setItems(arrayOf(L10n.t(this@archiveNodeRow, "sidebar.context.restore"), L10n.t(this@archiveNodeRow, "mobile.action.delete_permanently"))) { _, which ->
                        when (which) {
                            0 -> restore()
                            1 -> confirmPermanentDelete()
                        }
                    }
                    .show()
                true
            }
        }
    }

    internal fun MainActivity.showArchivedSchemeActions(scheme: JSONObject) {
        AlertDialog.Builder(this)
            .setTitle(scheme.optString("display_name"))
            .setItems(arrayOf(L10n.t(this, "sidebar.context.restore"), L10n.t(this, "mobile.action.delete_permanently"))) { _, which ->
                when (which) {
                    0 -> mutate(obj("type" to "restore_scheme", "scheme_id" to scheme.optString("id")))
                    1 -> mutate(obj("type" to "permanently_delete_scheme", "scheme_id" to scheme.optString("id")))
                }
            }
            .show()
    }

    internal fun MainActivity.showNameDialog(title: String, initial: String, validator: (String) -> String?, callback: (String) -> Unit) {
        val input = edit(initial).apply {
            setSingleLine(true)
            background = rounded(theme.bgModal, dp(5), theme.borderOverlay)
            setPadding(dp(10), 0, dp(10), 0)
        }
        val error = text("", theme.danger, 11f, true).apply {
            visibility = View.GONE
            setPadding(dp(2), dp(5), dp(2), 0)
        }
        fun refreshError(): String? {
            val message = validator(input.text.toString())
            error.text = message.orEmpty()
            error.visibility = if (message == null) View.GONE else View.VISIBLE
            return message
        }
        input.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {
                refreshError()
            }
            override fun afterTextChanged(s: Editable?) = Unit
        })
        val form = page(compact = true).apply {
            setPadding(0, 0, 0, 0)
            addView(input, LinearLayout.LayoutParams(-1, dp(44)))
            addView(error, LinearLayout.LayoutParams(-1, -2))
        }
        val dialog = AlertDialog.Builder(this)
            .setTitle(title)
            .setView(form)
            .setPositiveButton(L10n.t(this, "common.save"), null)
            .setNegativeButton(L10n.t(this, "common.cancel"), null)
            .create()
        dialog.setOnShowListener {
            refreshError()
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                if (refreshError() == null) {
                    callback(input.text.toString())
                    dialog.dismiss()
                }
            }
        }
        dialog.show()
    }

    internal fun MainActivity.showDatePicker() {
        DatePickerDialog(this, dateDialogTheme(), { _, year, month, day ->
            selectedDate = LocalDate.of(year, month + 1, day)
            ensureDaily()
        }, selectedDate.year, selectedDate.monthValue - 1, selectedDate.dayOfMonth).show()
    }

    internal fun MainActivity.showMonthPickerDialog() {
        var displayMonth = selectedDate.withDayOfMonth(1)
        val container = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(12), dp(8), dp(12), dp(12))
            background = rounded(theme.bgApp, dp(16), theme.borderOverlay)
        }
        val title = text(monthTitle(displayMonth), theme.textPrimary, 20f, true).apply {
            gravity = Gravity.CENTER
        }
        val grid = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = rounded(theme.bgModal, dp(10), theme.borderOverlay)
            setPadding(dp(8), dp(8), dp(8), dp(8))
        }
        lateinit var dialog: AlertDialog

        fun renderMonth() {
            title.text = monthTitle(displayMonth)
            grid.removeAllViews()
            grid.addView(monthWeekdayRow(), LinearLayout.LayoutParams(-1, dp(22)))
            val days = monthDayOccurrences(displayMonth)
            val first = displayMonth.withDayOfMonth(1)
            val gridStart = first.minusDays((first.dayOfWeek.value % 7).toLong())
            for (rowIndex in 0 until 6) {
                val row = LinearLayout(this).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.CENTER
                }
                for (columnIndex in 0 until 7) {
                    val date = gridStart.plusDays((rowIndex * 7 + columnIndex).toLong())
                    row.addView(monthDayCell(date, displayMonth, days[date.toString()] ?: JSONArray()) {
                        selectedDate = date
                        weekOffset = 0
                        loadSnapshot()
                        render()
                        dialog.dismiss()
                    }, LinearLayout.LayoutParams(0, dp(52), 1f))
                }
                grid.addView(row, LinearLayout.LayoutParams(-1, dp(52)))
            }
        }

        container.addView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(iconChipImage(R.drawable.ic_knotq_chevron_left_24, L10n.t(this@showMonthPickerDialog, "mobile.month_picker.previous"), iconSize = 18) {
                displayMonth = displayMonth.minusMonths(1)
                renderMonth()
            })
            addView(title, LinearLayout.LayoutParams(0, dp(38), 1f))
            addView(iconChipImage(R.drawable.ic_knotq_chevron_right_24, L10n.t(this@showMonthPickerDialog, "mobile.month_picker.next"), iconSize = 18) {
                displayMonth = displayMonth.plusMonths(1)
                renderMonth()
            })
        }, LinearLayout.LayoutParams(-1, dp(42)).apply {
            setMargins(0, 0, 0, dp(8))
        })
        container.addView(grid)

        dialog = AlertDialog.Builder(this)
            .setView(container)
            .create()
        renderMonth()
        dialog.show()
        // Card-style chrome (rounded, no button bar) — dismiss by tapping a
        // day or outside the card.
        dialog.window?.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
        dialog.window?.setLayout(min(resources.displayMetrics.widthPixels - dp(24), dp(520)), ViewGroup.LayoutParams.WRAP_CONTENT)
    }

    internal fun MainActivity.monthWeekdayRow(): View =
        LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            // Locale-aware narrow weekday initials (mirrors MainActivityCalendarTimeline's
            // day-of-week header) rather than a hardcoded English "S M T W T F S" row.
            listOf(
                DayOfWeek.SUNDAY, DayOfWeek.MONDAY, DayOfWeek.TUESDAY, DayOfWeek.WEDNESDAY,
                DayOfWeek.THURSDAY, DayOfWeek.FRIDAY, DayOfWeek.SATURDAY
            ).forEach { dayOfWeek ->
                addView(text(dayOfWeek.getDisplayName(TextStyle.NARROW, Locale.getDefault()), theme.textMuted, 11f, true).apply {
                    gravity = Gravity.CENTER
                }, LinearLayout.LayoutParams(0, -1, 1f))
            }
        }

    internal fun MainActivity.monthDayCell(date: LocalDate, displayMonth: LocalDate, occurrences: JSONArray, onSelect: () -> Unit): View {
        val inMonth = date.monthValue == displayMonth.monthValue && date.year == displayMonth.year
        val isToday = date == LocalDate.now()
        val isSelected = date == selectedDate
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            val day = text(date.dayOfMonth.toString(), monthDayTextColor(inMonth, isToday || isSelected), 14f, isToday || isSelected).apply {
                gravity = Gravity.CENTER
                if (isToday || isSelected) {
                    background = rounded(theme.accent, dp(17))
                }
            }
            addView(day, LinearLayout.LayoutParams(dp(34), dp(34)))
            addView(monthOccurrenceDots(occurrences), LinearLayout.LayoutParams(-1, dp(8)))
            setOnClickListener { onSelect() }
        }
    }

    internal fun MainActivity.monthOccurrenceDots(occurrences: JSONArray): View =
        LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            val seen = LinkedHashSet<String>()
            occurrences.forEachObject { occurrence ->
                if (seen.size >= 4) return@forEachObject
                val key = occurrence.optString("scheme_name").takeIf { it == "Daily" }
                    ?: "scheme-${occurrence.optInt("color_index")}"
                if (seen.add(key)) {
                    addView(View(this@monthOccurrenceDots).apply {
                        background = rounded(occurrenceSchemeColor(occurrence), dp(3))
                    }, LinearLayout.LayoutParams(dp(5), dp(5)).apply {
                        setMargins(dp(1), 0, dp(1), 0)
                    })
                }
            }
        }

    internal fun MainActivity.monthDayTextColor(inMonth: Boolean, highlighted: Boolean): Int =
        when {
            highlighted -> Color.WHITE
            inMonth -> theme.textPrimary
            else -> theme.textMuted
        }

    internal fun MainActivity.monthDayOccurrences(month: LocalDate): Map<String, JSONArray> {
        return runCatching {
            val byDate = LinkedHashMap<String, JSONArray>()
            bridge.requestArray(obj("type" to "month_days", "year" to month.year, "month" to month.monthValue))
                .forEachObject { day ->
                    byDate[day.optString("date")] = day.optJSONArray("occurrences") ?: JSONArray()
                }
            byDate
        }.getOrElse { error ->
            showError(L10n.t(this, "menu.calendar"), error.message)
            emptyMap()
        }
    }

    internal fun MainActivity.openScheme(id: String) {
        // Remember where the editor was opened from so the back button returns
        // there (Home on phone), rather than the otherwise-unreachable lists page.
        if (selectedTab != TAB_SCHEMES) schemeReturnTab = selectedTab
        selectedTab = TAB_SCHEMES
        selectedSchemeId = id
        render()
    }

    internal fun MainActivity.exitSchemeEditor() {
        selectedSchemeId = null
        selectedTab = if (schemeReturnTab == TAB_SCHEMES) TAB_HOME else schemeReturnTab
        render()
    }

    internal fun MainActivity.addDailyItemFromHome() {
        ensureDaily()
        dailyScheme()?.let { scheme ->
            showItemDialog(scheme.optString("id"), null)
        } ?: toast(L10n.t(this, "mobile.daily.not_ready_toast"))
    }

    internal fun MainActivity.ensureDaily() {
        if (selectedTab == TAB_DAILY) {
            pendingDailyAutoFocusDate = selectedDate.toString()
        }
        mutate(obj("type" to "ensure_daily_queue", "date" to selectedDate.toString()))
    }

    internal fun MainActivity.ensureTodayDailyQueue() {
        val today = LocalDate.now().toString()
        val existing = snapshot.optJSONArray("daily")
        if (existing != null) {
            for (index in 0 until existing.length()) {
                if (existing.optJSONObject(index)?.optString("date") == today) return
            }
        }
        bridge.request(obj("type" to "ensure_daily_queue", "date" to today))
        loadSnapshot()
    }

    internal fun MainActivity.mutate(
        body: JSONObject,
        renderAfter: Boolean = true,
        onSuccess: ((JSONObject) -> Unit)? = null
    ) {
        // Run the core write + snapshot read OFF the main thread (serial = FIFO, so
        // edit order holds) so an in-flight sync holding the core lock can't hang the
        // UI. The snapshot is re-read here and applied on the main thread; the UI
        // updates on completion (like iOS's async mutate).
        val today = selectedDate.toString()
        val week = weekOffset
        val hist = dailyHistoryDays
        coreExecutor.execute {
            val result = runCatching {
                bridge.request(body)
                bridge.request(obj(
                    "type" to "snapshot",
                    "today" to today,
                    "week_offset" to week,
                    "daily_history_days" to hist
                ))
            }
            runOnUiThread {
                result.onSuccess { snap ->
                    snapshot = snap
                    configureGoogleSyncPolling()
                    rescheduleNotifications()
                    if (renderAfter) render()
                    onSuccess?.invoke(snap)
                    requestSyncSoon()
                }.onFailure { error ->
                    showError(L10n.t(this, "mobile.errors.could_not_save_title"), error.message)
                }
            }
        }
    }

    internal fun MainActivity.quickCreateScheme(parentFolderId: String? = null) {
        val name = nextUntitledSchemeName(parentFolderId)
        val beforeIds = schemeIdSet(snapshot)
        val body = obj("type" to "create_scheme", "name" to name, "position" to 0)
        if (!parentFolderId.isNullOrBlank()) {
            body.put("folder_id", parentFolderId)
        }
        mutate(body, renderAfter = false) { refreshed ->
            val createdId = firstNewSchemeId(refreshed, beforeIds) ?: newestSchemeIdNamed(refreshed, name)
            if (createdId == null) {
                render()
            } else {
                pendingTitleFocusSchemeId = createdId
                openScheme(createdId)
            }
        }
    }

    internal fun MainActivity.nextUntitledSchemeName(parentFolderId: String? = null): String {
        val base = L10n.t(this, "sidebar.new_item_default_name")
        if (validateSchemeName(base, folderId = parentFolderId) == null) return base
        for (index in 2 until 10_000) {
            val candidate = "$base $index"
            if (validateSchemeName(candidate, folderId = parentFolderId) == null) return candidate
        }
        return "$base ${System.currentTimeMillis() / 1000}"
    }

    private fun schemeIdSet(snap: JSONObject): Set<String> {
        val ids = HashSet<String>()
        snap.optJSONArray("schemes")?.forEachObject { scheme ->
            scheme.optString("id").takeIf { it.isNotBlank() }?.let(ids::add)
        }
        return ids
    }

    private fun firstNewSchemeId(snap: JSONObject, beforeIds: Set<String>): String? {
        val schemes = snap.optJSONArray("schemes") ?: return null
        for (index in 0 until schemes.length()) {
            val scheme = schemes.optJSONObject(index) ?: continue
            val id = scheme.optString("id")
            if (id.isNotBlank() && id !in beforeIds) return id
        }
        return null
    }

    private fun newestSchemeIdNamed(snap: JSONObject, name: String): String? {
        val schemes = snap.optJSONArray("schemes") ?: return null
        for (index in schemes.length() - 1 downTo 0) {
            val scheme = schemes.optJSONObject(index) ?: continue
            if (scheme.optString("display_name", scheme.optString("name")) == name) {
                return scheme.optString("id").takeIf { it.isNotBlank() }
            }
        }
        return null
    }

    internal fun MainActivity.loadSnapshot() {
        snapshot = snapshotFromCore()
        configureGoogleSyncPolling()
    }

    /// The core half of [loadSnapshot], split out so a worker thread that is
    /// already holding a background task can fetch the snapshot itself instead of
    /// making the main thread wait on the core's lock.
    internal fun MainActivity.snapshotFromCore(): JSONObject = bridge.request(obj(
        "type" to "snapshot",
        "today" to selectedDate.toString(),
        "week_offset" to weekOffset,
        "daily_history_days" to dailyHistoryDays
    ))

    /// Mirrors iOS `loadOlderDailyEntries`: extend the daily history window by a
    /// month when the feed is scrolled to its oldest entry.
    internal fun MainActivity.loadOlderDailyEntries(oldestDate: String) {
        if (dailyHistoryLoadTriggerDate == oldestDate) return
        if (dailyHistoryDays >= 3650) return
        dailyHistoryLoadTriggerDate = oldestDate
        dailyHistoryDays = min(dailyHistoryDays + 31, 3650)
        pendingDailyAnchorDate = oldestDate
        loadSnapshot()
        render()
    }


    internal fun MainActivity.applyTheme() {
        val mode = snapshot.optJSONObject("settings")?.optString("theme_mode", "system") ?: "system"
        val darkSystem = (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
        theme = when (mode) {
            "light" -> UiTheme.light
            "rose_pine_moon" -> UiTheme.moonlit
            "catppuccin_mocha" -> UiTheme.espresso
            "tokyo_night" -> UiTheme.blueHour
            "parchment" -> UiTheme.parchment
            "rose_pine_dawn" -> UiTheme.dawn
            "catppuccin_latte" -> UiTheme.cream
            "system" -> if (darkSystem) UiTheme.dark else UiTheme.light
            else -> UiTheme.dark
        }
        applySystemBarColors()
    }

    @Suppress("DEPRECATION")
    internal fun MainActivity.applySystemBarColors() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.VANILLA_ICE_CREAM) {
            window.statusBarColor = theme.bgToolbar
            window.navigationBarColor = theme.bgSidebar
        }
    }

    internal fun MainActivity.calendar(): JSONObject = snapshot.optJSONObject("calendar") ?: JSONObject()

    internal fun MainActivity.dailyScheme(): JSONObject? {
        val days = snapshot.optJSONArray("daily") ?: return null
        for (index in 0 until days.length()) {
            val day = days.optJSONObject(index)
            if (day != null && selectedDate.toString() == day.optString("date")) {
                return day.optJSONObject("scheme")
            }
        }
        return null
    }

    internal fun MainActivity.dailyEntries(): List<JSONObject> {
        val days = snapshot.optJSONArray("daily") ?: return emptyList()
        val entries = ArrayList<JSONObject>(days.length())
        for (index in 0 until days.length()) {
            days.optJSONObject(index)?.let(entries::add)
        }
        entries.sortBy { it.optString("date") }
        return entries
    }

    internal fun MainActivity.dailyEntryForHome(): JSONObject? {
        val days = snapshot.optJSONArray("daily") ?: return null
        val selected = selectedDate.toString()
        val today = LocalDate.now().toString()
        var todayEntry: JSONObject? = null
        for (index in 0 until days.length()) {
            val entry = days.optJSONObject(index) ?: continue
            when (entry.optString("date")) {
                selected -> return entry
                today -> todayEntry = entry
            }
        }
        return todayEntry
    }

    internal fun MainActivity.archivedSchemes(): JSONArray = snapshot.optJSONArray("archived_schemes") ?: JSONArray()

    internal fun MainActivity.findScheme(id: String): JSONObject? {
        listOf(snapshot.optJSONArray("schemes"), snapshot.optJSONArray("archived_schemes")).forEach { schemes ->
            if (schemes != null) {
                for (index in 0 until schemes.length()) {
                    val scheme = schemes.optJSONObject(index)
                    if (scheme != null && id == scheme.optString("id")) return scheme
                }
            }
        }
        val daily = snapshot.optJSONArray("daily")
        if (daily != null) {
            for (index in 0 until daily.length()) {
                val scheme = daily.optJSONObject(index)?.optJSONObject("scheme")
                if (scheme != null && id == scheme.optString("id")) return scheme
            }
        }
        return null
    }

    internal fun MainActivity.findItem(schemeId: String, itemId: String): JSONObject? {
        val items = findScheme(schemeId)?.optJSONArray("items") ?: return null
        for (index in 0 until items.length()) {
            val item = items.optJSONObject(index)
            if (item != null && itemId == item.optString("id")) return item
        }
        return null
    }

    internal fun MainActivity.rootFolderId(): String? = snapshot.optJSONObject("root")?.optString("id")

    internal fun MainActivity.parentFolderIdForScheme(schemeId: String): String? {
        val root = snapshot.optJSONObject("root") ?: return null
        return parentFolderIdForScheme(schemeId, root)
    }

    internal fun MainActivity.parentFolderIdForScheme(schemeId: String, node: JSONObject): String? {
        val children = node.optJSONArray("children") ?: return null
        for (index in 0 until children.length()) {
            val child = children.optJSONObject(index) ?: continue
            if (child.optString("kind") == "scheme" && child.optString("id") == schemeId) {
                return node.optString("id")
            }
            if (child.optString("kind") == "folder") {
                parentFolderIdForScheme(schemeId, child)?.let { return it }
            }
        }
        return null
    }

    internal fun MainActivity.parentFolderIdForNode(nodeId: String): String? {
        val root = snapshot.optJSONObject("root") ?: return null
        return parentFolderIdForNode(nodeId, root)
    }

    internal fun MainActivity.parentFolderIdForNode(nodeId: String, node: JSONObject): String? {
        val children = node.optJSONArray("children") ?: return null
        for (index in 0 until children.length()) {
            val child = children.optJSONObject(index) ?: continue
            if (child.optString("id") == nodeId) {
                return node.optString("id")
            }
            if (child.optString("kind") == "folder") {
                parentFolderIdForNode(nodeId, child)?.let { return it }
            }
        }
        return null
    }

    internal fun MainActivity.moveNavigatorNode(kind: String, nodeId: String, delta: Int) {
        when (applyNodeMove(kind, nodeId, delta)) {
            true -> { rescheduleNotifications(); render() }
            false -> toast(L10n.t(this, "mobile.common.already_there_toast"))
        }
    }

    // Shifts a node one slot within its parent; returns false at a boundary. Applies
    // the change and reloads the snapshot but does NOT re-render, so callers (e.g. the
    // reorder sheet) can apply several moves and refresh their own UI cheaply.
    internal fun MainActivity.applyNodeMove(kind: String, nodeId: String, delta: Int): Boolean {
        val parentId = parentFolderIdForNode(nodeId) ?: return false
        val parent = nodeById(parentId, snapshot.optJSONObject("root")) ?: return false
        val children = parent.optJSONArray("children") ?: return false
        var index = -1
        for (i in 0 until children.length()) {
            if (children.optJSONObject(i)?.optString("id") == nodeId) {
                index = i
                break
            }
        }
        if (index < 0) return false
        // move_node removes the node first, so positions index the
        // post-removal sibling list.
        val position = if (delta < 0) index - 1 else index + 1
        if (position < 0 || position > children.length() - 1) return false
        bridge.request(obj("type" to "move_node", "kind" to kind, "id" to nodeId, "folder_id" to parentId, "position" to position))
        loadSnapshot()
        requestSyncSoon()
        return true
    }

    // A live reorder sheet for a node's siblings: stays open while you nudge items
    // up/down (instead of reopening the context menu for each single step, as iOS
    // drag-to-reorder avoids). Highlights the item the sheet was opened for.
    internal fun MainActivity.showReorderDialog(nodeId: String) {
        val parentId = parentFolderIdForNode(nodeId) ?: return toast(L10n.t(this, "mobile.reorder.cannot_reorder_toast"))
        val parentName = nodeById(parentId, snapshot.optJSONObject("root"))?.optString("name")?.takeIf { it.isNotBlank() && parentId != rootFolderId() } ?: L10n.t(this, "mobile.nav.tab_home")
        val list = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(12), dp(8), dp(12), dp(8))
        }
        val scrollView = ScrollView(this).apply { addView(list) }
        var changed = false
        lateinit var rebuild: () -> Unit
        fun siblings(): JSONArray =
            nodeById(parentId, snapshot.optJSONObject("root"))?.optJSONArray("children") ?: JSONArray()
        fun moveButton(iconRes: Int, description: String, enabled: Boolean, action: () -> Unit): View =
            FrameLayout(this).apply {
                contentDescription = description
                background = rounded(theme.buttonBg, dp(7), theme.borderOverlay)
                alpha = if (enabled) 1f else 0.3f
                addView(iconImage(iconRes, theme.textPrimary, description), FrameLayout.LayoutParams(dp(18), dp(18), Gravity.CENTER))
                if (enabled) setOnClickListener { action() }
                layoutParams = LinearLayout.LayoutParams(dp(40), dp(38)).apply { setMargins(dp(6), 0, 0, 0) }
            }
        rebuild = {
            list.removeAllViews()
            val children = siblings()
            val lastIndex = children.length() - 1
            if (children.length() == 0) {
                list.addView(text(L10n.t(this, "mobile.reorder.empty"), theme.textMuted, 13f, false))
            }
            for (i in 0 until children.length()) {
                val child = children.optJSONObject(i) ?: continue
                val childId = child.optString("id")
                val childKind = child.optString("kind")
                val isFolder = childKind == "folder"
                val highlight = childId == nodeId
                val row = LinearLayout(this).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.CENTER_VERTICAL
                    setPadding(dp(8), 0, dp(6), 0)
                    background = rounded(if (highlight) theme.rowSelected else Color.TRANSPARENT, dp(8))
                    if (isFolder) {
                        addView(inlineIcon(R.drawable.ic_knotq_folder_24, theme.textMuted, widthDp = 18, iconSize = 15))
                    } else {
                        addView(colorSquare(schemeColor(child.optInt("color_index")), 10), LinearLayout.LayoutParams(dp(10), dp(10)).apply { setMargins(dp(4), 0, dp(4), 0) })
                    }
                    addView(text(child.optString("name").ifEmpty { child.optString("display_name") }, theme.textPrimary, 14f, highlight || isFolder).apply { maxLines = 1; ellipsize = TextUtils.TruncateAt.END }, LinearLayout.LayoutParams(0, -1, 1f).apply { setMargins(dp(6), 0, 0, 0) })
                    addView(moveButton(R.drawable.ic_knotq_chevron_up_24, L10n.t(this@showReorderDialog, "mobile.reorder.move_up"), i > 0) {
                        if (applyNodeMove(childKind, childId, -1)) { changed = true; rebuild() }
                    })
                    addView(moveButton(R.drawable.ic_knotq_chevron_down_24, L10n.t(this@showReorderDialog, "mobile.reorder.move_down"), i < lastIndex) {
                        if (applyNodeMove(childKind, childId, 1)) { changed = true; rebuild() }
                    })
                }
                list.addView(row, LinearLayout.LayoutParams(-1, dp(46)))
            }
        }
        rebuild()
        val dialog = AlertDialog.Builder(this)
            .setTitle(L10n.t(this, "mobile.reorder.title", mapOf("parent" to parentName)))
            .setView(scrollView)
            .setPositiveButton(L10n.t(this, "common.done"), null)
            .create()
        dialog.setOnDismissListener { if (changed) render() }
        dialog.show()
    }

    internal fun MainActivity.showMoveToFolderDialog(kind: String, nodeId: String, excludedFolderId: String? = null) {
        val root = snapshot.optJSONObject("root") ?: return toast(L10n.t(this, "mobile.move_to_folder.cannot_move_toast"))
        val currentParentId = parentFolderIdForNode(nodeId) ?: return toast(L10n.t(this, "mobile.move_to_folder.cannot_move_toast"))
        val destinations = mutableListOf(FolderDestination(root.optString("id"), L10n.t(this, "mobile.nav.tab_home"), 0))
        collectFolderDestinations(root.optJSONArray("children"), 1, excludedFolderId, destinations)
        AlertDialog.Builder(this)
            .setTitle(L10n.t(this, "mobile.move_to_folder.title"))
            .setItems(destinations.map { destination ->
                "${"   ".repeat(destination.depth)}${destination.name}${if (destination.id == currentParentId) "  " + L10n.t(this, "mobile.move_to_folder.current_suffix") else ""}"
            }.toTypedArray()) { _, which ->
                val destination = destinations[which]
                if (destination.id == currentParentId) return@setItems toast(L10n.t(this, "mobile.common.already_there_toast"))
                val target = nodeById(destination.id, root) ?: return@setItems toast(L10n.t(this, "mobile.move_to_folder.cannot_find_folder_toast"))
                val position = target.optJSONArray("children")?.length() ?: 0
                mutate(obj("type" to "move_node", "kind" to kind, "id" to nodeId, "folder_id" to destination.id, "position" to position))
            }
            .show()
    }

    internal fun MainActivity.collectFolderDestinations(nodes: JSONArray?, depth: Int, excludedFolderId: String?, destinations: MutableList<FolderDestination>) {
        nodes?.forEachObject { node ->
            if (node.optString("kind") == "folder" && node.optString("id") != excludedFolderId) {
                destinations.add(FolderDestination(node.optString("id"), node.optString("name"), depth))
                collectFolderDestinations(node.optJSONArray("children"), depth + 1, excludedFolderId, destinations)
            }
        }
    }

    internal fun MainActivity.validateSchemeName(name: String, folderId: String? = null, excludingId: String? = null, checkDuplicates: Boolean = true): String? {
        return null
    }

    internal fun MainActivity.validateFolderName(name: String, excludingId: String? = null): String? {
        return null
    }

    internal fun MainActivity.nodeById(id: String?, node: JSONObject?): JSONObject? {
        if (id == null || node == null) return null
        if (node.optString("id") == id) return node
        val children = node.optJSONArray("children") ?: return null
        for (index in 0 until children.length()) {
            nodeById(id, children.optJSONObject(index))?.let { return it }
        }
        return null
    }

    internal fun MainActivity.todayOccurrences(): JSONArray {
        val out = JSONArray()
        calendar().optJSONArray("days")?.forEachObject { day ->
            if (day.optString("date") == LocalDate.now().toString()) {
                day.optJSONArray("occurrences")?.forEachObject { out.put(it) }
            }
        }
        return out
    }
