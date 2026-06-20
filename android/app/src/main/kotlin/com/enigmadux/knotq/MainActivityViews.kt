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

// Leaf UI / view-builder / color / date / dimension helpers for MainActivity,
// extracted as extension functions (same module) to shrink MainActivity.kt.

internal fun MainActivity.dayForDate(date: LocalDate): JSONObject? {
    val days = calendar().optJSONArray("days") ?: return null
    for (index in 0 until days.length()) {
        val day = days.optJSONObject(index) ?: continue
        if (day.optString("date") == date.toString()) return day
    }
    return null
}

internal fun MainActivity.weekStart(date: LocalDate): LocalDate =
    date.minusDays((date.dayOfWeek.value % 7).toLong())

internal fun MainActivity.selectedDateTitle(): String =
    calendar().let { calendar ->
        val start = calendar.optString("start_date")
        val end = calendar.optString("end_date")
        if (start.isNotEmpty() && end.isNotEmpty()) {
            "${MobileDateFormatting.shortDay(start)} - ${MobileDateFormatting.shortDay(end)}"
        } else {
            "${selectedDate.month.getDisplayName(TextStyle.FULL, Locale.getDefault())} ${selectedDate.dayOfMonth}, ${selectedDate.year}"
        }
    }

internal fun MainActivity.monthTitle(date: LocalDate): String =
    "${date.month.getDisplayName(TextStyle.FULL, Locale.getDefault())} ${date.year}"

internal fun MainActivity.addOccurrenceSection(root: LinearLayout, title: String, empty: String, occurrences: JSONArray?) {
    // iOS section heading: large bold title, not a small caps label.
    root.addView(text(title, theme.textPrimary, 22f, true).apply {
        setPadding(dp(2), dp(2), dp(2), dp(6))
    })
    if (occurrences == null || occurrences.length() == 0) {
        root.addView(text(empty, theme.textMuted, 14f, false).apply {
            setPadding(dp(2), dp(4), 0, dp(10))
        })
        return
    }
    occurrences.forEachIndexedObject { idx, occurrence -> root.addView(occurrenceRow(occurrence, idx % 2 == 1), rowParams()) }
}

internal fun MainActivity.titleText(): String {
    return if (selectedTab == TAB_SCHEMES && selectedSchemeId != null) {
        findScheme(selectedSchemeId!!)?.optString("display_name") ?: "Scheme"
    } else {
        when (selectedTab) {
            TAB_HOME -> "Home"
            TAB_CALENDAR -> "Calendar"
            TAB_SCHEMES -> "Schemes"
            TAB_DAILY -> "Daily"
            TAB_SEARCH -> "Search"
            TAB_SETTINGS -> "Settings"
            else -> "KnotQ"
        }
    }
}

internal fun MainActivity.titleColor(): Int {
    if (selectedTab == TAB_SCHEMES && selectedSchemeId != null) {
        return findScheme(selectedSchemeId!!)?.optInt("color_index")?.let(::schemeColor) ?: theme.textDim
    }
    return when (selectedTab) {
        TAB_HOME -> theme.accent
        TAB_CALENDAR -> theme.textPrimary
        TAB_DAILY -> if (theme.isDark) rgb(0xb8c9e8) else rgb(0x5a7aad)
        else -> theme.textDim
    }
}

internal fun MainActivity.page(compact: Boolean = false): LinearLayout = LinearLayout(this).apply {
    orientation = LinearLayout.VERTICAL
    setPadding(
        if (compact) 0 else dp(14),
        if (compact) 0 else dp(14),
        if (compact) 0 else dp(14),
        if (compact) 0 else phonePageBottomPadding()
    )
    setBackgroundColor(theme.bgApp)
}

internal fun MainActivity.phonePageBottomPadding(): Int =
    if (!isWideLayout() && selectedTab in listOf(TAB_HOME, TAB_CALENDAR, TAB_SETTINGS)) dp(166) else dp(20)

internal fun MainActivity.scroll(view: View): ScrollView = ScrollView(this).apply {
    isFillViewport = true
    setBackgroundColor(theme.bgApp)
    addView(view)
}

internal fun MainActivity.sectionHeader(value: String): TextView = text(value, theme.textPrimary, 18f, true).apply {
    setPadding(0, dp(4), 0, dp(8))
}

internal fun MainActivity.sectionLabel(value: String): TextView = text(value, theme.textDim, 12f, true).apply {
    setPadding(dp(4), dp(8), dp(4), dp(4))
}

internal fun MainActivity.settingsSection(value: String): TextView = text(value, theme.textSoft, 12f, true).apply {
    setPadding(dp(4), dp(16), 0, dp(5))
}

// Groups settings rows into a single rounded card with hairline separators,
// mirroring the iOS grouped-list look.
internal fun MainActivity.settingsGroup(vararg rows: View): View =
    LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        background = rounded(if (theme.isDark) theme.bgToolbar else theme.bgModal, dp(10), theme.borderOverlay)
        setPadding(dp(4), dp(3), dp(4), dp(3))
        rows.forEachIndexed { index, row ->
            if (index > 0) {
                addView(View(this@settingsGroup).apply { setBackgroundColor(theme.dividerSoft) }, LinearLayout.LayoutParams(-1, max(1, (0.5f * resources.displayMetrics.density).roundToInt())).apply {
                    setMargins(dp(8), dp(1), dp(8), dp(1))
                })
            }
            addView(row, LinearLayout.LayoutParams(-1, -2))
        }
    }

// A tappable settings row showing an optional right-aligned value and a chevron.
internal fun MainActivity.settingsLinkRow(label: String, value: String? = null, onClick: () -> Unit): View =
    LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setPadding(dp(8), 0, dp(4), 0)
        addView(text(label, theme.textPrimary, 14f, false), LinearLayout.LayoutParams(0, dp(44), 1f))
        if (!value.isNullOrEmpty()) {
            addView(text(value, theme.textMuted, 13f, false).apply {
                gravity = Gravity.CENTER_VERTICAL
                maxLines = 1
                ellipsize = TextUtils.TruncateAt.END
            }, LinearLayout.LayoutParams(-2, dp(44)).apply { setMargins(dp(6), 0, dp(2), 0) })
        }
        addView(inlineIcon(R.drawable.ic_knotq_chevron_right_24, theme.textMuted, widthDp = 20, iconSize = 15))
        setOnClickListener { onClick() }
    }

internal fun MainActivity.dialogLabel(value: String): TextView =
    text(value, theme.textMuted, 11f, true).apply {
        setPadding(dp(2), 0, dp(2), dp(4))
    }

internal fun MainActivity.dialogDateLabel(date: LocalDate): String =
    "${date.dayOfWeek.getDisplayName(TextStyle.SHORT, Locale.getDefault())}, " +
        "${date.month.getDisplayName(TextStyle.SHORT, Locale.getDefault())} ${date.dayOfMonth}, ${date.year}"

internal fun MainActivity.dialogTimeLabel(time: LocalTime): String {
    if (timeFormat24()) return "%02d:%02d".format(Locale.US, time.hour, time.minute)
    val hour = time.hour
    val hour12 = (hour % 12).let { if (it == 0) 12 else it }
    val period = if (hour < 12) "AM" else "PM"
    return "%d:%02d %s".format(Locale.US, hour12, time.minute, period)
}

// Wheel-mode time picker dialog tinted to the active theme (iOS-like, fewer taps
// than the default clock face).
internal fun MainActivity.timeDialogTheme(): Int = if (theme.isDark) R.style.KnotQTimeDialogDark else R.style.KnotQTimeDialogLight

internal fun MainActivity.dateDialogTheme(): Int = if (theme.isDark) R.style.KnotQDateDialogDark else R.style.KnotQDateDialogLight

// Context that renders embedded DatePicker/TimePicker widgets as compact wheels.
internal fun MainActivity.inlinePickerContext(): Context =
    ContextThemeWrapper(this, if (theme.isDark) R.style.KnotQInlinePickerDark else R.style.KnotQInlinePickerLight)

internal fun MainActivity.styleDialogSpinner(spinner: Spinner) {
    spinner.background = rounded(theme.buttonBg, dp(8), theme.borderOverlay)
    spinner.setPadding(dp(10), 0, dp(34), 0)
    spinner.minimumHeight = dp(42)
}

internal fun MainActivity.dialogSpinnerField(label: String, spinner: Spinner): View =
    LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        addView(dialogLabel(label))
        addView(FrameLayout(this@dialogSpinnerField).apply {
            addView(spinner, FrameLayout.LayoutParams(-1, dp(42)))
            addView(iconImage(R.drawable.ic_knotq_chevron_down_24, theme.textMuted, null), FrameLayout.LayoutParams(dp(15), dp(15), Gravity.RIGHT or Gravity.CENTER_VERTICAL).apply { rightMargin = dp(11) })
        }, LinearLayout.LayoutParams(-1, dp(42)))
        alpha = if (spinner.isEnabled) 1f else 0.55f
    }

internal fun MainActivity.dialogField(
    label: String,
    value: String,
    enabled: Boolean = true,
    listener: (() -> Unit)? = null
): DialogField {
    val labelView = text(label, theme.textMuted, 11f, true)
    val valueView = text(value, theme.textPrimary, 15f, false).apply {
        maxLines = 1
        ellipsize = TextUtils.TruncateAt.END
    }
    val row = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setPadding(dp(12), 0, dp(10), 0)
        background = rounded(theme.buttonBg, dp(8), theme.borderOverlay)
        alpha = if (enabled) 1f else 0.55f
        addView(LinearLayout(this@dialogField).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_VERTICAL
            addView(labelView, LinearLayout.LayoutParams(-1, dp(15)))
            addView(valueView, LinearLayout.LayoutParams(-1, dp(21)))
        }, LinearLayout.LayoutParams(0, -1, 1f))
        if (enabled && listener != null) {
            addView(inlineIcon(R.drawable.ic_knotq_chevron_right_24, theme.textMuted, widthDp = 20, iconSize = 14))
            setOnClickListener { listener() }
            isFocusable = true
        }
    }.also {
        it.layoutParams = LinearLayout.LayoutParams(-1, dp(48))
    }
    return DialogField(row, labelView, valueView)
}

internal fun MainActivity.dialogActionButton(
    value: String,
    primary: Boolean = false,
    danger: Boolean = false,
    listener: () -> Unit
): TextView =
    text(
        value,
        when {
            danger -> theme.danger
            primary -> Color.WHITE
            else -> theme.textPrimary
        },
        13f,
        true
    ).apply {
        gravity = Gravity.CENTER
        setPadding(dp(14), 0, dp(14), 0)
        background = rounded(
            when {
                primary -> theme.accent
                danger -> adjustAlpha(theme.danger, if (theme.isDark) 0.12f else 0.08f)
                else -> theme.buttonBg
            },
            dp(8),
            if (danger) adjustAlpha(theme.danger, 0.32f) else theme.borderOverlay
        )
        setOnClickListener { listener() }
    }

internal fun MainActivity.choiceRow(
    value: String,
    icon: String? = null,
    selected: Boolean,
    action: () -> Unit
): View {
    return LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setPadding(dp(8), 0, dp(8), 0)
        background = rounded(if (selected) theme.rowSelected else Color.TRANSPARENT, dp(5))
        if (icon != null) {
            addView(text(icon, theme.textPrimary, 14f, true), LinearLayout.LayoutParams(dp(16), dp(36)))
        }
        addView(text(value, theme.textPrimary, 14f, false), LinearLayout.LayoutParams(0, dp(36), 1f).apply {
            if (icon != null) setMargins(dp(4), 0, 0, 0)
        })
        if (selected) addView(inlineIcon(R.drawable.ic_knotq_check_24, theme.accent, widthDp = 22, iconSize = 16))
        setOnClickListener { action() }
    }
}

internal fun MainActivity.iconActionChip(value: String, label: String, listener: () -> Unit): TextView {
    return text("$value $label", theme.textPrimary, 12f, true).apply {
        gravity = Gravity.CENTER
        setPadding(dp(10), 0, dp(10), 0)
        background = rounded(theme.buttonBg, dp(5))
        setOnClickListener { listener() }
        contentDescription = label
        maxLines = 1
        ellipsize = TextUtils.TruncateAt.END
        includeFontPadding = false
        isSingleLine = true
    }
}

internal fun MainActivity.textChip(label: String, listener: () -> Unit): TextView {
    return text(label, theme.textPrimary, 12f, true).apply {
        gravity = Gravity.CENTER
        setPadding(dp(10), 0, dp(10), 0)
        background = rounded(theme.buttonBg, dp(7), theme.borderOverlay)
        setOnClickListener { listener() }
        contentDescription = label
        maxLines = 1
        ellipsize = TextUtils.TruncateAt.END
        includeFontPadding = false
        isSingleLine = true
    }
}

internal fun MainActivity.emptyState(title: String, detail: String): View {
    return LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        gravity = Gravity.CENTER
        setPadding(dp(16), dp(80), dp(16), dp(80))
        addView(text(title, theme.textDim, 15f, true).apply { gravity = Gravity.CENTER })
        addView(text(detail, theme.textMuted, 13f, false).apply { gravity = Gravity.CENTER })
    }
}

internal fun MainActivity.text(value: String, color: Int, sp: Float, bold: Boolean): TextView = TextView(this).apply {
    text = value
    setTextColor(color)
    textSize = sp
    includeFontPadding = false
    gravity = Gravity.CENTER_VERTICAL
    if (bold) setTypeface(typeface, Typeface.BOLD)
}

internal fun MainActivity.navSpecial(value: String, color: Int, selected: Boolean, listener: () -> Unit): View {
    return LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setPadding(dp(6), 0, dp(6), 0)
        background = rounded(if (selected) theme.rowSelected else Color.TRANSPARENT, dp(4))
        addView(colorSquare(color, 9), LinearLayout.LayoutParams(dp(9), dp(9)))
        addView(text(value, theme.textPrimary, 12f, false), LinearLayout.LayoutParams(0, -1, 1f).apply {
            setMargins(dp(7), 0, 0, 0)
        })
        setOnClickListener { listener() }
    }.also { it.layoutParams = LinearLayout.LayoutParams(-1, dp(22)) }
}

internal fun MainActivity.chip(value: String, listener: () -> Unit): TextView = text(value, theme.textPrimary, 12f, true).apply {
    gravity = Gravity.CENTER
    setPadding(dp(10), 0, dp(10), 0)
    background = rounded(theme.buttonBg, dp(5))
    setOnClickListener { listener() }
}

internal fun MainActivity.iconChip(value: String, listener: () -> Unit): TextView = chip(value, listener).apply {
    textSize = ICON_CHIP_SIZE_SP
}.also {
    it.layoutParams = LinearLayout.LayoutParams(dp(ICON_CHIP_WIDTH_DP), dp(ICON_CHIP_HEIGHT_DP))
}

internal fun MainActivity.iconSquare(value: String, listener: () -> Unit): TextView = text(value, theme.textPrimary, ICON_SQUARE_SIZE_SP, true).apply {
    gravity = Gravity.CENTER
    background = rounded(theme.buttonBg, dp(7), theme.borderOverlay)
    setOnClickListener { listener() }
}

// Square tappable icon button (drawable) used in toolbars/headers — the
// vector-drawable replacement for the old text-glyph `iconSquare`.
internal fun MainActivity.iconSquareImage(iconRes: Int, description: String, iconSize: Int = 18, listener: () -> Unit): View =
    FrameLayout(this).apply {
        contentDescription = description
        background = rounded(theme.buttonBg, dp(7), theme.borderOverlay)
        addView(iconImage(iconRes, theme.textPrimary, description), FrameLayout.LayoutParams(dp(iconSize), dp(iconSize), Gravity.CENTER))
        isFocusable = true
        setOnClickListener { listener() }
    }

// Chrome chip with a vector icon (replaces glyph-based `iconChip`).
internal fun MainActivity.iconChipImage(iconRes: Int, description: String, tint: Int = theme.textPrimary, iconSize: Int = 18, listener: () -> Unit): View =
    FrameLayout(this).apply {
        contentDescription = description
        background = rounded(theme.buttonBg, dp(5))
        addView(iconImage(iconRes, tint, description), FrameLayout.LayoutParams(dp(iconSize), dp(iconSize), Gravity.CENTER))
        isFocusable = true
        setOnClickListener { listener() }
        layoutParams = LinearLayout.LayoutParams(dp(ICON_CHIP_WIDTH_DP), dp(ICON_CHIP_HEIGHT_DP))
    }

// Inline chevron / small directional icon (replaces text glyphs in rows & dialogs).
internal fun MainActivity.inlineIcon(iconRes: Int, color: Int, widthDp: Int = 24, iconSize: Int = 16): View =
    FrameLayout(this).apply {
        addView(iconImage(iconRes, color, null), FrameLayout.LayoutParams(dp(iconSize), dp(iconSize), Gravity.CENTER))
        layoutParams = LinearLayout.LayoutParams(dp(widthDp), -1)
    }

internal fun MainActivity.dockButton(iconRes: Int, description: String, selected: Boolean, listener: () -> Unit): View =
    FrameLayout(this).apply {
        contentDescription = description
        background = if (selected) rounded(theme.rowSelected, dp(20)) else rounded(Color.TRANSPARENT, dp(20))
        addView(
            iconImage(iconRes, if (selected) theme.textPrimary else theme.textMuted, description),
            FrameLayout.LayoutParams(dp(ICON_DOCK_VECTOR_SIZE_DP), dp(ICON_DOCK_VECTOR_SIZE_DP), Gravity.CENTER)
        )
        isFocusable = true
        setOnClickListener { listener() }
    }

internal fun MainActivity.homeFloatingActions(): View =
    LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER
        addView(floatingAction(R.drawable.ic_knotq_check_square_24, "Daily") {
            selectedTab = TAB_DAILY
            selectedSchemeId = null
            ensureDaily()
        }, LinearLayout.LayoutParams(dp(ICON_FLOATING_WIDTH_DP), dp(ICON_FLOATING_WIDTH_DP)).apply {
            setMargins(0, 0, dp(10), 0)
        })
        addView(floatingAction(R.drawable.ic_knotq_edit_24, "New Scheme") {
            showNameDialog("New Scheme", "", { validateSchemeName(it, folderId = rootFolderId()) }) { name ->
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
        }, LinearLayout.LayoutParams(dp(ICON_FLOATING_WIDTH_DP), dp(ICON_FLOATING_WIDTH_DP)))
    }

internal fun MainActivity.floatingAction(iconRes: Int, description: String, listener: () -> Unit): View =
    FrameLayout(this).apply {
        contentDescription = description
        background = rounded(theme.bgToolbar, dp(28), theme.borderOverlay)
        elevation = dp(if (theme.isDark) 10 else 4).toFloat()
        addView(
            iconImage(iconRes, theme.textPrimary, description),
            FrameLayout.LayoutParams(dp(ICON_FLOATING_VECTOR_SIZE_DP), dp(ICON_FLOATING_VECTOR_SIZE_DP), Gravity.CENTER)
        )
        isFocusable = true
        setOnClickListener { listener() }
    }

internal fun MainActivity.iconImage(iconRes: Int, color: Int, description: String? = null): ImageView =
    ImageView(this).apply {
        setImageResource(iconRes)
        setColorFilter(color, PorterDuff.Mode.SRC_IN)
        scaleType = ImageView.ScaleType.CENTER_INSIDE
        contentDescription = description
    }

internal fun MainActivity.syncCardButton(value: String, primary: Boolean = false, listener: () -> Unit): TextView =
    text(value, if (primary) Color.WHITE else theme.textPrimary, 12f, primary).apply {
        gravity = Gravity.CENTER
        setPadding(dp(10), 0, dp(10), 0)
        background = rounded(if (primary) rgb(0x2563eb) else theme.buttonBg, dp(5))
        setOnClickListener { listener() }
    }

internal fun MainActivity.smallAction(value: String, listener: () -> Unit): TextView = text(value, theme.textDim, 11f, true).apply {
    setPadding(0, dp(5), dp(12), dp(2))
    setOnClickListener { listener() }
}

internal fun MainActivity.edit(value: String): EditText = EditText(this).apply {
    setText(value)
    setTextColor(theme.textPrimary)
    setHintTextColor(theme.textMuted)
    inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
    setSingleLine(false)
    imeOptions = EditorInfo.IME_ACTION_DONE
    textSize = 14f
}

internal fun MainActivity.spinner(values: Array<String>): Spinner {
    val adapter = ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item, values)
    return Spinner(this).apply { this.adapter = adapter }
}

internal fun MainActivity.colorSquare(color: Int, size: Int): View = View(this).apply {
    background = rounded(color, dp(3))
    layoutParams = LinearLayout.LayoutParams(dp(size), dp(size))
}

internal fun MainActivity.brandMark(size: Int): ImageView = ImageView(this).apply {
    setImageResource(applicationInfo.icon)
    scaleType = ImageView.ScaleType.CENTER_CROP
    background = rounded(theme.rowSelected, dp(6), theme.borderOverlay)
    clipToOutline = Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP
    setPadding(dp(2), dp(2), dp(2), dp(2))
    layoutParams = LinearLayout.LayoutParams(dp(size), dp(size))
}

internal fun MainActivity.colorSwatch(index: Int, active: Int): View = View(this).apply {
    background = rounded(schemeColor(index), dp(3), if (index == active) theme.accent else Color.TRANSPARENT, dp(1))
    setOnClickListener {
        selectedSchemeId?.let { mutate(obj("type" to "set_scheme_color", "scheme_id" to it, "color_index" to index)) }
    }
}

internal fun MainActivity.divider(): View = View(this).apply { setBackgroundColor(theme.divider) }

internal fun MainActivity.spaced(): LinearLayout.LayoutParams = LinearLayout.LayoutParams(-1, -2).apply {
    setMargins(0, 0, 0, dp(8))
}

internal fun MainActivity.rowParams(): LinearLayout.LayoutParams = LinearLayout.LayoutParams(-1, -2).apply {
    setMargins(0, 0, 0, dp(1))
}

internal fun MainActivity.marginRight(right: Int, width: Int, height: Int): LinearLayout.LayoutParams =
    LinearLayout.LayoutParams(width, height).apply { setMargins(0, 0, right, 0) }

internal fun MainActivity.markerLabel(marker: String): String = when (marker) {
    "bullet" -> "*"
    "numbered" -> "#"
    "blank" -> "T"
    else -> " "
}

internal fun MainActivity.calendarTimeColor(occurrence: JSONObject): Int {
    val default = if (theme.isDark) adjustAlpha(rgb(0xe8edf2), 0.90f) else adjustAlpha(rgb(0x2e291f), 0.90f)
    if (occurrence.optBoolean("done")) return default
    val start = MobileDateFormatting.parseInstant(occurrence.optionalString("start") ?: occurrence.optionalString("end")) ?: return default
    val now = Instant.now()
    val end = MobileDateFormatting.parseInstant(occurrence.optionalString("end"))
    if (end != null && !start.isAfter(now) && end.isAfter(now)) return todayTimeColor()
    if (start.isBefore(now)) return if (theme.isDark) rgb(0xff5a53) else rgb(0xd20f39)
    val startDay = start.atZone(ZoneId.systemDefault()).toLocalDate()
    val dayDiff = java.time.temporal.ChronoUnit.DAYS.between(LocalDate.now(), startDay)
    return when {
        dayDiff <= 0 -> todayTimeColor()
        dayDiff <= 1 -> if (theme.isDark) rgb(0xe5e5ff) else rgb(0x4f5f8f)
        else -> default
    }
}

internal fun MainActivity.todayTimeColor(): Int =
    if (theme.isDark) rgb(0xbfbfff) else rgb(0x2f67cf)

internal fun MainActivity.calendarItemTextColor(occurrence: JSONObject): Int {
    val color = schemeColor(occurrence.optInt("color_index"))
    val hsv = FloatArray(3)
    Color.colorToHSV(color, hsv)
    val done = occurrence.optBoolean("done")
    hsv[1] *= if (done) {
        if (theme.isDark) 0.35f else 0.45f
    } else {
        if (theme.isDark) 0.70f else 0.90f
    }
    val alpha = if (done) (255 * 0.78f).roundToInt() else 255
    return Color.HSVToColor(alpha, hsv)
}

internal fun MainActivity.timeFormat24(): Boolean =
    snapshot.optJSONObject("settings")?.optString("time_format") == "twenty_four_hour"

internal fun MainActivity.schemeColor(index: Int): Int {
    val darkPalette = intArrayOf(rgb(0xff453a), rgb(0xff9f0a), rgb(0x30d158), rgb(0x0a84ff), rgb(0xbf5af2), rgb(0xffd60a))
    val lightPalette = intArrayOf(rgb(0xb84433), rgb(0xc47400), rgb(0x28764f), rgb(0x2563a6), rgb(0x735aa6), rgb(0xe0a800))
    val palette = if (theme.isDark) darkPalette else lightPalette
    return palette[index.floorMod(palette.size)]
}

internal fun MainActivity.editorChromeColor(): Int =
    if (theme.isDark) rgb(0xb8c9e8) else rgb(0x536a8f)

internal fun MainActivity.eventBg(): Int =
    if (theme.isDark) adjustAlpha(rgb(0x333333), 0.62f) else adjustAlpha(rgb(0xe6e8ec), 0.62f)

internal fun MainActivity.eventBorder(): Int =
    if (theme.isDark) adjustAlpha(Color.WHITE, 0.84f) else adjustAlpha(rgb(0x24272d), 0.80f)

internal fun MainActivity.calendarPillStrokeWidth(): Int =
    max(1, (1.5f * resources.displayMetrics.density).roundToInt())

internal fun MainActivity.calendarEventBorderWidth(): Int =
    max(1, (1.8f * resources.displayMetrics.density).roundToInt())

internal fun MainActivity.calendarDayStrokeWidth(visible: Boolean): Int {
    val width = if (visible) 1.8f else 1.4f
    return max(1, (width * resources.displayMetrics.density).roundToInt())
}

internal fun MainActivity.calendarDayHighlightColor(): Int =
    if (theme.isDark) rgb(0x0a84ff) else rgb(0x007aff)

internal fun MainActivity.calendarWeekSecondaryHighlightColor(): Int =
    if (theme.isDark) rgb(0x052547) else rgb(0xbacada)

internal fun MainActivity.calendarWeekConnectorColor(): Int =
    if (theme.isDark) rgb(0x46515f) else rgb(0x9faebb)

internal fun MainActivity.calendarWeekSecondaryTextColor(): Int =
    if (theme.isDark) rgb(0xb9dcff) else rgb(0x0059b8)

internal fun MainActivity.calendarWeekDayTextColor(today: Boolean, visible: Boolean): Int =
    when {
        visible && today -> Color.WHITE
        visible -> calendarWeekSecondaryTextColor()
        today -> calendarDayHighlightColor()
        else -> theme.textPrimary
    }

internal fun MainActivity.calendarRangeFill(): Int =
    if (theme.isDark) adjustAlpha(Color.WHITE, 0.09f) else adjustAlpha(rgb(0x3f6fd5), 0.08f)

internal fun MainActivity.rounded(color: Int, radius: Int, strokeColor: Int = Color.TRANSPARENT, strokeWidth: Int = dp(1)): GradientDrawable =
    GradientDrawable().apply {
        setColor(color)
        cornerRadius = radius.toFloat()
        if (strokeColor != Color.TRANSPARENT) setStroke(strokeWidth, strokeColor)
    }

internal fun MainActivity.roundedHorizontalSegment(color: Int, leadingRounded: Boolean, trailingRounded: Boolean): GradientDrawable =
    GradientDrawable().apply {
        val radius = dp(8).toFloat()
        setColor(color)
        cornerRadii = floatArrayOf(
            if (leadingRounded) radius else 0f,
            if (leadingRounded) radius else 0f,
            if (trailingRounded) radius else 0f,
            if (trailingRounded) radius else 0f,
            if (trailingRounded) radius else 0f,
            if (trailingRounded) radius else 0f,
            if (leadingRounded) radius else 0f,
            if (leadingRounded) radius else 0f,
        )
    }

internal fun MainActivity.underline(color: Int): GradientDrawable =
    GradientDrawable().apply {
        setColor(color)
        setStroke(dp(1), theme.dividerSoft)
    }

internal fun MainActivity.adjust(color: Int, alpha: Float): Int = adjustAlpha(color, alpha)

internal fun MainActivity.rgb(hex: Int): Int = rgbColor(hex)

internal fun Int.floorMod(mod: Int): Int = ((this % mod) + mod) % mod

internal fun MainActivity.dp(value: Int): Int = (value * resources.displayMetrics.density).roundToInt()

internal fun MainActivity.toast(value: String?) {
    Toast.makeText(this, value ?: "Error", Toast.LENGTH_LONG).show()
}

internal fun MainActivity.showError(title: String, message: String?) {
    AlertDialog.Builder(this)
        .setTitle(title)
        .setMessage(message ?: "Unknown error")
        .setPositiveButton("OK", null)
        .show()
}

internal fun MainActivity.showFatal(message: String?) {
    setContentView(text(message ?: "KnotQ failed to start", theme.textPrimary, 16f, true).apply {
        gravity = Gravity.CENTER
        setBackgroundColor(theme.bgApp)
    })
}

