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

    internal fun MainActivity.showNewMenu() {
        AlertDialog.Builder(this)
            .setTitle("New")
            .setItems(arrayOf("New Scheme", "New Folder", "Google Calendar")) { _, which ->
                when (which) {
                    0 -> showNameDialog("New Scheme", "", { validateSchemeName(it, folderId = rootFolderId()) }) { name ->
                        mutate(obj("type" to "create_scheme", "name" to name, "position" to 0))
                        snapshot.optJSONArray("schemes")?.let { schemes ->
                            for (index in schemes.length() - 1 downTo 0) {
                                val scheme = schemes.optJSONObject(index) ?: continue
                                if (scheme.optString("display_name") == name || scheme.optString("name") == name) {
                                    openScheme(scheme.optString("id"))
                                    return@showNameDialog
                                }
                            }
                        }
                    }
                    1 -> showNameDialog("New Folder", "", { validateFolderName(it) }) { name -> mutate(obj("type" to "create_folder", "name" to name)) }
                    2 -> startGoogleCalendarImport()
                }
            }
            .show()
    }

    internal fun MainActivity.showItemDialog(schemeId: String, item: JSONObject?) {
        val editing = item != null
        val form = page(compact = true)
        val text = edit(item?.optString("text") ?: "").apply { hint = "Item" }
        val markerValues = arrayOf("checkbox", "blank", "bullet", "numbered")
        val marker = spinner(markerValues)
        if (editing) marker.setSelection(markerValues.indexOf(item?.optString("marker")).coerceAtLeast(0))
        form.addView(text, spaced())
        form.addView(marker, spaced())
        AlertDialog.Builder(this)
            .setTitle(if (editing) "Edit Item" else "New Item")
            .setView(form)
            .setPositiveButton(if (editing) "Save" else "Add") { _, _ ->
                if (item != null) {
                    mutate(obj("type" to "update_item_text", "scheme_id" to schemeId, "item_id" to item.optString("id"), "text" to text.text.toString().trim()))
                    mutate(obj("type" to "set_item_marker", "scheme_id" to schemeId, "item_id" to item.optString("id"), "marker" to marker.selectedItem.toString()))
                } else {
                    mutate(obj("type" to "add_item", "scheme_id" to schemeId, "text" to text.text.toString().trim(), "marker" to marker.selectedItem.toString()))
                }
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    internal fun MainActivity.showCalendarItemDialog() {
        showEventEditorDialog(null)
    }

    internal fun MainActivity.showEventEditorDialog(
        occurrence: JSONObject?,
        initialDate: LocalDate? = null,
        initialMinute: Float? = null,
        preferredKind: String? = null,
        openForNew: Boolean = false,
        onDismiss: (() -> Unit)? = null
    ) {
        val editing = occurrence != null
        val readOnly = occurrence?.optBoolean("is_read_only", false) == true
        val initialKind = if (editing) {
            occurrence.optString("kind").takeIf { it.isNotEmpty() } ?: "task"
        } else {
            preferredKind?.takeIf { it.isNotEmpty() } ?: "task"
        }
        val startDateTime = if (editing) MobileDateFormatting.localDateTime(occurrence?.optionalString("start"))?.toLocalDateTime() else null
        val endDateTime = if (editing) MobileDateFormatting.localDateTime(occurrence?.optionalString("end"))?.toLocalDateTime() else null
        val selectedMinute = initialMinute?.toInt()?.coerceIn(0, (24 * 60) - 1)
        val seedDate = initialDate ?: selectedDate
        val seedTime = selectedMinute?.let { LocalTime.of(it / 60, it % 60) }
        val anchor = when {
            openForNew && seedTime != null -> LocalDateTime.of(seedDate, seedTime)
            editing -> startDateTime ?: endDateTime
            else -> startDateTime ?: endDateTime ?: selectedDate.atStartOfDay()
        } ?: selectedDate.atStartOfDay()
        val defaultStart = startDateTime ?: anchor
        val defaultEnd = if (editing) {
            endDateTime ?: if (initialKind == "event") defaultStart.plusHours(1) else defaultStart
        } else {
            when (initialKind) {
                "event" -> defaultStart.plusHours(1)
                "assignment", "reminder" -> defaultStart
                else -> defaultStart
            }
        }
        val initialDialogDate = if (editing) {
            (startDateTime ?: endDateTime)?.toLocalDate() ?: seedDate
        } else {
            seedDate
        }
        val titleInput = edit(occurrence?.optString("title") ?: "").apply {
            hint = "Title"
            isEnabled = !readOnly
        }
        // iOS-style segmented kind selector instead of a raw lowercase spinner.
        val kindValues = arrayOf("event", "reminder", "assignment", "task")
        val kindTitles = arrayOf("Event", "Reminder", "Assignment", "Task")
        var activeKindValue = if (kindValues.contains(initialKind)) initialKind else "task"
        val kindChips = HashMap<String, TextView>()
        val kindRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            kindValues.forEachIndexed { index, value ->
                val chip = text(kindTitles[index], theme.textDim, 12.5f, true).apply {
                    gravity = Gravity.CENTER
                    includeFontPadding = false
                }
                kindChips[value] = chip
                addView(chip, LinearLayout.LayoutParams(0, dp(34), 1f).apply {
                    setMargins(if (index == 0) 0 else dp(3), 0, if (index == kindValues.lastIndex) 0 else dp(3), 0)
                })
            }
        }
        fun refreshKindChips() {
            kindValues.forEach { value ->
                kindChips[value]?.apply {
                    val active = value == activeKindValue
                    background = rounded(
                        if (active) theme.rowSelected else theme.buttonBg,
                        dp(8),
                        if (active) theme.accent else Color.TRANSPARENT
                    )
                    setTextColor(if (active) theme.textPrimary else theme.textDim)
                }
            }
        }
        val schemeLabels = mutableListOf("Daily")
        val schemeIds = mutableListOf<String?>(null)
        snapshot.optJSONArray("schemes")?.forEachObject { scheme ->
            if (!scheme.optBoolean("is_daily_queue") && !scheme.optBoolean("is_read_only")) {
                schemeLabels.add(scheme.optString("display_name"))
                schemeIds.add(scheme.optString("id"))
            }
        }
        val scheme = spinner(schemeLabels.toTypedArray()).apply {
            val selected = occurrence?.optString("scheme_id")
            val index = schemeIds.indexOfFirst { it == selected }
            setSelection(index.coerceAtLeast(0))
            isEnabled = !editing && !readOnly
        }
        var selectedLocalDate = initialDialogDate
        var startTime = defaultStart.toLocalTime().takeIf { it != LocalTime.MIDNIGHT } ?: LocalTime.now().withSecond(0).withNano(0)
        var endTime = defaultEnd.toLocalTime()
        val repeatValues = arrayOf("none", "daily", "weekly", "monthly", "yearly")
        val repeatLabels = arrayOf("Never", "Daily", "Weekly", "Monthly", "Yearly")
        val repeat = spinner(repeatLabels).apply {
            setSelection(repeatValues.indexOf(MobileRecurrence.repeatChoiceFromRrule(occurrence?.optionalString("repeat_rule"))).coerceAtLeast(0))
            isEnabled = !readOnly
        }
        // iOS WeeklyRepeatDaysPicker: weekday circles shown for weekly repeats.
        val selectedWeekdays = MobileRecurrence.selectedWeekdays(occurrence?.optionalString("repeat_rule"), initialDialogDate)
        val weekdayChips = ArrayList<Pair<String, TextView>>()
        lateinit var refreshWeekdayChips: () -> Unit
        val weekdayRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            MobileRecurrence.weekdayCodes.forEachIndexed { index, code ->
                val chip = text(MobileRecurrence.weekdayChipLabels[index], theme.textDim, 12f, true).apply {
                    gravity = Gravity.CENTER
                    includeFontPadding = false
                    setOnClickListener {
                        if (readOnly) return@setOnClickListener
                        if (selectedWeekdays.contains(code)) {
                            // Never allow an empty weekly selection, like iOS.
                            if (selectedWeekdays.size > 1) selectedWeekdays.remove(code)
                        } else {
                            selectedWeekdays.add(code)
                        }
                        refreshWeekdayChips()
                    }
                }
                weekdayChips.add(code to chip)
                addView(chip, LinearLayout.LayoutParams(dp(34), dp(34)).apply {
                    setMargins(dp(3), 0, dp(3), 0)
                })
            }
        }
        refreshWeekdayChips = {
            weekdayChips.forEach { (code, chip) ->
                val active = selectedWeekdays.contains(code)
                chip.background = rounded(
                    if (active) theme.accent else Color.TRANSPARENT,
                    dp(17),
                    if (active) Color.TRANSPARENT else theme.borderOverlay
                )
                chip.setTextColor(
                    if (active) {
                        if (theme.isDark) rgb(0x10131a) else Color.WHITE
                    } else {
                        theme.textDim
                    }
                )
            }
        }
        refreshWeekdayChips()
        val defaultOffset = defaultNotificationOffset(initialKind)
        val currentOffset = occurrence?.takeUnless { it.isNull("notification_offset_secs") }?.optInt("notification_offset_secs") ?: defaultOffset
        val notificationOptions = occurrenceNotificationOptionsIncluding(currentOffset)
        val notification = spinner(notificationOptions.map { it.label }.toTypedArray()).apply {
            setSelection(notificationOptions.indexOfFirst { it.offsetSecs == currentOffset }.coerceAtLeast(0))
            isEnabled = !readOnly
        }
        // iOS-style toggle row: label on the left, switch on the right.
        val completed = Switch(this).apply {
            isChecked = occurrence?.optBoolean("done", false) == true
            isEnabled = !readOnly
        }
        val completedRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            background = rounded(theme.buttonBg, dp(8), theme.borderOverlay)
            setPadding(dp(12), 0, dp(12), 0)
            addView(text("Completed", theme.textPrimary, 15f, false), LinearLayout.LayoutParams(0, -2, 1f))
            addView(completed, LinearLayout.LayoutParams(-2, -2))
            setOnClickListener { if (!readOnly) completed.toggle() }
        }

        titleInput.apply {
            setSingleLine(true)
            background = rounded(theme.buttonBg, dp(8), theme.borderOverlay)
            setPadding(dp(12), 0, dp(12), 0)
            minHeight = dp(42)
        }
        styleDialogSpinner(scheme)
        styleDialogSpinner(notification)
        styleDialogSpinner(repeat)

        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = rounded(theme.bgModal, dp(16), theme.borderOverlay)
            isFocusableInTouchMode = true
        }
        card.addView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(14), dp(16), dp(7))
            addView(text(if (readOnly) "Details" else if (editing) "Edit" else "New", theme.textPrimary, 21f, true))
            val subtitle = when {
                readOnly -> "Imported calendar item"
                editing -> occurrence?.optString("scheme_name").orEmpty()
                else -> "Calendar item"
            }
            if (subtitle.isNotBlank()) {
                addView(text(subtitle, theme.textMuted, 12f, false).apply {
                    setPadding(0, dp(3), 0, 0)
                })
            }
        })

        val form = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), 0, dp(16), dp(4))
            addView(dialogLabel("Title"))
            addView(titleInput, LinearLayout.LayoutParams(-1, dp(42)).apply { setMargins(0, 0, 0, dp(9)) })
            if (!editing) {
                addView(dialogSpinnerField("Scheme", scheme), LinearLayout.LayoutParams(-1, -2).apply { setMargins(0, 0, 0, dp(8)) })
            }
            addView(dialogLabel("Type"))
            addView(kindRow, LinearLayout.LayoutParams(-1, -2).apply { setMargins(0, dp(2), 0, dp(9)) })
        }
        lateinit var dateField: DialogField
        lateinit var startField: DialogField
        lateinit var endField: DialogField
        lateinit var notificationFieldView: View
        lateinit var repeatFieldView: View
        fun selectedKind(): String = activeKindValue
        fun refreshScheduleFields() {
            val activeKind = selectedKind()
            dateField.value.text = dialogDateLabel(selectedLocalDate)
            startField.label.text = if (activeKind == "reminder") "At" else "Start"
            startField.value.text = dialogTimeLabel(startTime)
            endField.label.text = if (activeKind == "assignment") "Due" else "End"
            endField.value.text = dialogTimeLabel(endTime)
            dateField.view.visibility = if (activeKind == "task") View.GONE else View.VISIBLE
            startField.view.visibility = if (activeKind == "event" || activeKind == "reminder") View.VISIBLE else View.GONE
            endField.view.visibility = if (activeKind == "event" || activeKind == "assignment") View.VISIBLE else View.GONE
            notificationFieldView.visibility = if (activeKind == "task") View.GONE else View.VISIBLE
            repeatFieldView.visibility = if (activeKind == "task") View.GONE else View.VISIBLE
        }
        dateField = dialogField("Date", dialogDateLabel(selectedLocalDate), enabled = !readOnly) {
            DatePickerDialog(this, dateDialogTheme(), { _, year, month, day ->
                selectedLocalDate = LocalDate.of(year, month + 1, day)
                refreshScheduleFields()
            }, selectedLocalDate.year, selectedLocalDate.monthValue - 1, selectedLocalDate.dayOfMonth).show()
        }
        startField = dialogField("Start", dialogTimeLabel(startTime), enabled = !readOnly) {
            TimePickerDialog(this, timeDialogTheme(), { _, hour, minute ->
                startTime = LocalTime.of(hour, minute)
                refreshScheduleFields()
            }, startTime.hour, startTime.minute, timeFormat24()).show()
        }
        endField = dialogField("End", dialogTimeLabel(endTime), enabled = !readOnly) {
            TimePickerDialog(this, timeDialogTheme(), { _, hour, minute ->
                endTime = LocalTime.of(hour, minute)
                refreshScheduleFields()
            }, endTime.hour, endTime.minute, timeFormat24()).show()
        }
        form.addView(dateField.view, LinearLayout.LayoutParams(-1, -2).apply { setMargins(0, 0, 0, dp(7)) })
        form.addView(startField.view, LinearLayout.LayoutParams(-1, -2).apply { setMargins(0, 0, 0, dp(7)) })
        form.addView(endField.view, LinearLayout.LayoutParams(-1, -2).apply { setMargins(0, 0, 0, dp(8)) })
        notificationFieldView = dialogSpinnerField("Notification", notification)
        repeatFieldView = dialogSpinnerField("Repeat", repeat)
        form.addView(notificationFieldView, LinearLayout.LayoutParams(-1, -2).apply { setMargins(0, 0, 0, dp(8)) })
        form.addView(repeatFieldView, LinearLayout.LayoutParams(-1, -2).apply { setMargins(0, 0, 0, dp(8)) })
        form.addView(weekdayRow, LinearLayout.LayoutParams(-1, -2).apply { setMargins(0, 0, 0, dp(10)) })
        fun refreshWeekdayRowVisibility() {
            weekdayRow.visibility = if (selectedKind() != "task" && repeat.selectedItemPosition == repeatValues.indexOf("weekly")) {
                View.VISIBLE
            } else {
                View.GONE
            }
        }
        repeat.onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
            override fun onItemSelected(parent: AdapterView<*>?, view: View?, position: Int, id: Long) {
                refreshWeekdayRowVisibility()
            }

            override fun onNothingSelected(parent: AdapterView<*>?) = Unit
        }
        if (editing) {
            form.addView(completedRow, LinearLayout.LayoutParams(-1, dp(46)).apply { setMargins(0, dp(2), 0, dp(8)) })
        }
        if (readOnly) {
            form.addView(text("Imported calendar items are read-only.", theme.textMuted, 12f, false), LinearLayout.LayoutParams(-1, -2).apply { setMargins(0, 0, 0, dp(8)) })
        }
        kindValues.forEach { value ->
            kindChips[value]?.setOnClickListener {
                if (readOnly || activeKindValue == value) return@setOnClickListener
                activeKindValue = value
                refreshKindChips()
                refreshScheduleFields()
                refreshWeekdayRowVisibility()
            }
        }
        refreshKindChips()
        refreshScheduleFields()
        refreshWeekdayRowVisibility()
        card.addView(ScrollView(this).apply {
            isFillViewport = false
            addView(form)
        }, LinearLayout.LayoutParams(-1, -2))

        lateinit var dialog: AlertDialog
        fun saveAndDismiss() {
            if (readOnly) {
                occurrence?.optString("scheme_id")?.let(::openScheme)
                dialog.dismiss()
                return
            }
            val activeKind = selectedKind()
            val startValue = when (activeKind) {
                "event", "reminder" -> MobileDateFormatting.iso(selectedLocalDate, startTime.hour, startTime.minute)
                else -> null
            }
            val endValue = when (activeKind) {
                "event", "assignment" -> MobileDateFormatting.iso(selectedLocalDate, endTime.hour, endTime.minute)
                else -> null
            }
            val rrule = if (activeKind == "task") null else MobileRecurrence.rruleForRepeat(repeatValues[repeat.selectedItemPosition.coerceIn(0, repeatValues.lastIndex)], selectedLocalDate, selectedWeekdays)
            val notificationOffset = if (activeKind == "task") null else notificationOptions[notification.selectedItemPosition].offsetSecs
            if (occurrence != null) {
                val commit = { scope: String ->
                    commitEventEdit(
                        occurrence = occurrence,
                        title = titleInput.text.toString().trim(),
                        start = startValue,
                        end = endValue,
                        rrule = rrule,
                        notificationOffsetSecs = notificationOffset,
                        notificationDirty = activeKind != "task",
                        done = completed.isChecked,
                        scope = scope
                    )
                }
                if (occurrence.optBoolean("is_recurring", false)) {
                    showOccurrenceScopeDialog("Recurring task", occurrence, forDelete = false) { scope ->
                        commit(scope)
                    }
                } else {
                    commit("all_events")
                }
            } else {
                val schemeId = schemeIds.getOrNull(scheme.selectedItemPosition)
                val newId = createCalendarItemReturningID(
                    kind = activeKind,
                    text = titleInput.text.toString().trim(),
                    date = selectedLocalDate,
                    start = startValue,
                    end = endValue,
                    schemeId = schemeId
                )
                val resolvedScheme = schemeId ?: todayDailySchemeId()
                if (newId != null && resolvedScheme != null) {
                    if (rrule != null) {
                        bridge.request(obj("type" to "set_item_recurrence", "scheme_id" to resolvedScheme, "item_id" to newId, "rrule" to rrule))
                    }
                    if (activeKind != "task") {
                        bridge.request(
                            obj(
                                "type" to "set_occurrence_notification_offset",
                                "scheme_id" to resolvedScheme,
                                "item_id" to newId,
                                "occurrence_json" to null,
                                "offset_secs" to notificationOffset
                            )
                        )
                    }
                    loadSnapshot()
                    rescheduleNotifications()
                    render()
                }
            }
            dialog.dismiss()
        }
        fun deleteAndDismiss() {
            if (occurrence == null) return
            val delete = { scope: String -> deleteEventOccurrence(occurrence, scope) }
            if (occurrence.optBoolean("is_recurring", false)) {
                showOccurrenceScopeDialog("Delete recurring task?", occurrence, forDelete = true, onScope = delete)
            } else {
                AlertDialog.Builder(this)
                    .setTitle("Delete this task?")
                    .setNegativeButton("Cancel", null)
                    .setPositiveButton("Delete") { _, _ -> delete("all_events") }
                    .show()
            }
            dialog.dismiss()
        }
        card.addView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(12), dp(6), dp(12), dp(12))
            if (editing && !readOnly) {
                addView(dialogActionButton("Delete", danger = true) { deleteAndDismiss() }, LinearLayout.LayoutParams(-2, dp(38)))
            }
            addView(View(this@showEventEditorDialog), LinearLayout.LayoutParams(0, 1, 1f))
            addView(dialogActionButton(if (readOnly) "Done" else "Cancel") { dialog.dismiss() }, LinearLayout.LayoutParams(-2, dp(38)).apply {
                setMargins(0, 0, dp(8), 0)
            })
            addView(dialogActionButton(if (readOnly) "Open Scheme" else "Save", primary = !readOnly) { saveAndDismiss() }, LinearLayout.LayoutParams(-2, dp(38)))
        })

        dialog = AlertDialog.Builder(this)
            .setView(card)
            .create()
        onDismiss?.let { callback -> dialog.setOnDismissListener { callback() } }
        dialog.show()
        card.requestFocus()
        dialog.window?.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
        dialog.window?.setLayout(min(resources.displayMetrics.widthPixels - dp(32), dp(500)), ViewGroup.LayoutParams.WRAP_CONTENT)
    }

    internal fun MainActivity.commitEventEdit(
        occurrence: JSONObject,
        title: String,
        start: String?,
        end: String?,
        rrule: String?,
        notificationOffsetSecs: Int?,
        notificationDirty: Boolean,
        done: Boolean,
        scope: String
    ) {
        mutate(
            obj(
                "type" to "commit_event_edit",
                "scheme_id" to occurrence.optString("scheme_id"),
                "item_id" to occurrence.optString("item_id"),
                "occurrence_json" to occurrence.optString("occurrence_json", "{\"kind\":\"single\"}"),
                "occurrence_index" to occurrence.optInt("occurrence_index", 0),
                "title" to title,
                "occurrence_start" to occurrence.optionalString("start"),
                "occurrence_end" to occurrence.optionalString("end"),
                "start" to start,
                "end" to end,
                "rrule" to rrule,
                "notification_offset_secs" to notificationOffsetSecs,
                "notification_dirty" to notificationDirty,
                "done" to done,
                "scope" to scope
            )
        )
    }

    internal fun MainActivity.deleteEventOccurrence(occurrence: JSONObject, scope: String) {
        mutate(
            obj(
                "type" to "delete_event_occurrence",
                "scheme_id" to occurrence.optString("scheme_id"),
                "item_id" to occurrence.optString("item_id"),
                "occurrence_json" to occurrence.optString("occurrence_json", "{\"kind\":\"single\"}"),
                "occurrence_index" to occurrence.optInt("occurrence_index", 0),
                "scope" to scope
            )
        )
    }

    internal fun MainActivity.showOccurrenceScopeDialog(
        title: String,
        occurrence: JSONObject,
        forDelete: Boolean,
        onCancel: (() -> Unit)? = null,
        onScope: (String) -> Unit
    ) {
        val choices = mutableListOf("This task" to "this_event")
        if (occurrence.optBoolean("can_delete_future", false)) {
            choices.add("This and future tasks" to "all_future")
        }
        choices.add("All tasks" to "all_events")
        var chose = false
        // No setMessage here: AlertDialog drops the item list when a message is
        // set, which left this dialog with nothing but Cancel.
        AlertDialog.Builder(this)
            .setTitle(if (forDelete) "$title — which tasks should be deleted?" else "$title — which tasks should these changes apply to?")
            .setItems(choices.map { it.first }.toTypedArray()) { _, which ->
                chose = true
                onScope(choices[which].second)
            }
            .setNegativeButton("Cancel", null)
            .setOnDismissListener { if (!chose) onCancel?.invoke() }
            .show()
    }

    internal fun MainActivity.createCalendarItemReturningID(
        kind: String,
        text: String,
        date: LocalDate,
        start: String?,
        end: String?,
        schemeId: String?
    ): String? {
        val targetId = if (schemeId != null) {
            schemeId
        } else {
            bridge.request(obj("type" to "ensure_daily_queue", "date" to LocalDate.now().toString()))
            loadSnapshot()
            todayDailySchemeId() ?: return null
        }
        val before = schemeItemIds(targetId)
        bridge.request(
            obj(
                "type" to "add_calendar_item",
                "scheme_id" to targetId,
                "kind" to kind,
                "text" to text,
                "date" to date.toString(),
                "start" to start,
                "end" to end
            )
        )
        loadSnapshot()
        requestSyncSoon()
        return schemeItemIds(targetId).firstOrNull { !before.contains(it) }
    }

    internal fun MainActivity.schemeItemIds(schemeId: String): Set<String> {
        val ids = mutableSetOf<String>()
        findScheme(schemeId)?.optJSONArray("items")?.forEachObject { item ->
            ids.add(item.optString("id"))
        }
        return ids
    }

    internal fun MainActivity.todayDailySchemeId(): String? {
        val today = LocalDate.now().toString()
        val daily = snapshot.optJSONArray("daily") ?: return null
        for (index in 0 until daily.length()) {
            val entry = daily.optJSONObject(index) ?: continue
            if (entry.optString("date") == today) return entry.optJSONObject("scheme")?.optString("id")
        }
        return null
    }

    internal fun MainActivity.defaultNotificationOffset(kind: String): Int {
        val settings = snapshot.optJSONObject("settings")
        return when (kind) {
            "event" -> settings?.optInt("event_notification_offset_secs", DEFAULT_EVENT_NOTIFICATION_OFFSET_SECS)
                ?: DEFAULT_EVENT_NOTIFICATION_OFFSET_SECS
            "assignment" -> settings?.optInt("assignment_notification_offset_secs", DEFAULT_ASSIGNMENT_NOTIFICATION_OFFSET_SECS)
                ?: DEFAULT_ASSIGNMENT_NOTIFICATION_OFFSET_SECS
            else -> 0
        }
    }

    internal fun MainActivity.showMarkerDialog(schemeId: String, itemId: String) {
        val markers = arrayOf("checkbox", "blank", "bullet", "numbered")
        AlertDialog.Builder(this)
            .setTitle("Marker")
            .setItems(markers) { _, which ->
                mutate(obj("type" to "set_item_marker", "scheme_id" to schemeId, "item_id" to itemId, "marker" to markers[which]))
            }
            .show()
    }

    /// iOS `ItemDateSheet` equivalent: the full schedule editor (type chips,
    /// date/time fields, notification, repeat) instead of a Set/Clear list.
    internal fun MainActivity.showDateKindDialog(schemeId: String, itemId: String) {
        val item = findItem(schemeId, itemId) ?: return
        val scheme = findScheme(schemeId)
        val hasStart = item.optionalString("start") != null
        val hasEnd = item.optionalString("end") != null
        val kind = when {
            hasStart && hasEnd -> "event"
            hasStart -> "reminder"
            hasEnd -> "assignment"
            else -> "task"
        }
        showEventEditorDialog(obj(
            "scheme_id" to schemeId,
            "item_id" to itemId,
            "title" to item.optString("text"),
            "kind" to kind,
            "start" to item.optionalString("start"),
            "end" to item.optionalString("end"),
            "occurrence_json" to "{\"kind\":\"single\"}",
            "is_recurring" to (item.optionalString("repeat_rule") != null),
            "repeat_rule" to item.optionalString("repeat_rule"),
            "notification_offset_secs" to item.takeUnless { it.isNull("notification_offset_secs") }?.optInt("notification_offset_secs"),
            "done" to item.optBoolean("done", false),
            "scheme_name" to (scheme?.optString("display_name").orEmpty()),
            "color_index" to (scheme?.optInt("color_index") ?: 0)
        ))
    }

    internal fun MainActivity.showItemDateDialog(schemeId: String, itemId: String, kind: String) {
        val form = page(compact = true)
        val initial = MobileDateFormatting.localDateTime(findItem(schemeId, itemId)?.optionalString(kind))
        val pickerCtx = inlinePickerContext()
        val date = DatePicker(pickerCtx).apply {
            val local = initial?.toLocalDate() ?: selectedDate
            updateDate(local.year, local.monthValue - 1, local.dayOfMonth)
        }
        val time = TimePicker(pickerCtx).apply {
            setIs24HourView(timeFormat24())
            val local = initial?.toLocalTime() ?: LocalTime.now().withSecond(0).withNano(0)
            hour = local.hour
            minute = local.minute
        }
        form.addView(date, spaced())
        form.addView(time)
        AlertDialog.Builder(this)
            .setTitle(kind.replaceFirstChar(Char::titlecase))
            .setView(form)
            .setPositiveButton("Save") { _, _ ->
                val localDate = LocalDate.of(date.year, date.month + 1, date.dayOfMonth)
                mutate(obj("type" to "set_item_date", "scheme_id" to schemeId, "item_id" to itemId, "kind" to kind, "date" to MobileDateFormatting.iso(localDate, time.hour, time.minute)))
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

