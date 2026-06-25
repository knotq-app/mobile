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

    internal fun MainActivity.renderUpcomingRail(): View {
        val root = page(compact = true)
        addOccurrenceSection(root, "Overdue", "None", calendar().optJSONArray("overdue"))
        addOccurrenceSection(root, "Today", "None today", todayOccurrences())
        addOccurrenceSection(root, "Upcoming", "None", calendar().optJSONArray("upcoming"))
        return scroll(root)
    }

    internal fun MainActivity.renderCalendar(): LinearLayout {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(theme.bgApp)
        }
        root.addView(calendarToolbar())

        // Show a run of day columns from the fetched week, anchored on the selected
        // day. Indexing into the fetched days (rather than absolute dates) keeps the
        // columns aligned with the data even while browsing other weeks.
        val columns = calendarVisibleDayCount()
        val dayObjects = calendarDayObjects()
        val startIndex = calendarVisibleStartIndex(dayObjects)
        val renderStartIndex = max(0, startIndex - 1)
        val renderEndIndex = min(dayObjects.size, startIndex + columns + 1)
        val renderDays = if (dayObjects.isEmpty()) emptyList()
        else dayObjects.subList(renderStartIndex, renderEndIndex).toList()
        val leadingColumns = startIndex - renderStartIndex

        val timeline = this@renderCalendar.CalendarTimelineView(this).apply {
            configure(renderDays, columns, leadingColumns)
        }

        val column = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        column.addView(timeline, LinearLayout.LayoutParams(-1, -2))

        val scrollView = ScrollView(this).apply {
            setBackgroundColor(theme.bgApp)
            isVerticalScrollBarEnabled = false
            addView(column)
        }
        scrollView.viewTreeObserver.addOnScrollChangedListener {
            calendarScrollY = scrollView.scrollY
            timeline.onViewportChanged(scrollView.scrollY, scrollView.height)
        }
        // Anchor the scroll near "now" when today is one of the visible columns
        // (else early morning); keep the user's position when the same day
        // re-renders for another reason.
        val dateKey = selectedDate.toString()
        val target = if (calendarScrollDate != dateKey) {
            val visibleHasToday = (0 until columns).any { selectedDate.plusDays(it.toLong()) == LocalDate.now() }
            // Screenshot fixture: anchor mid-morning so the seeded daytime events
            // are framed (the emulator's real clock is arbitrary, so now-1h would
            // land anywhere).
            val hour = when {
                screenshotFixtureRequested() -> 9
                visibleHasToday -> max(0, LocalTime.now().hour - 1)
                else -> 7
            }
            dp(8) + dp(44) * hour
        } else {
            calendarScrollY
        }
        calendarScrollDate = dateKey
        // Apply the anchor during the first layout pass (before the first
        // draw) — a post{} lands a frame late and flashes the unscrolled
        // timeline first.
        var appliedCalendarAnchor = false
        scrollView.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ ->
            if (!appliedCalendarAnchor && scrollView.height > 0) {
                appliedCalendarAnchor = true
                scrollView.scrollTo(0, target)
                timeline.onViewportChanged(scrollView.scrollY, scrollView.height)
            }
        }
        root.addView(scrollView, LinearLayout.LayoutParams(-1, 0, 1f))
        return root
    }

    internal fun MainActivity.calendarVisibleDayCount(): Int = when {
        resources.configuration.screenWidthDp >= 760 -> 5
        resources.configuration.screenWidthDp >= 600 -> 3
        else -> 2
    }

    internal fun MainActivity.calendarDayObjects(): List<JSONObject> {
        val out = ArrayList<JSONObject>()
        calendar().optJSONArray("days")?.let { arr ->
            for (i in 0 until arr.length()) arr.optJSONObject(i)?.let(out::add)
        }
        return out
    }

    /// First column index into the fetched week: the selected day, clamped so the
    /// visible run always stays within the available days. Both the timeline and
    /// the week strip use this so their highlights stay in sync.
    internal fun MainActivity.calendarVisibleStartIndex(days: List<JSONObject>): Int {
        val count = calendarVisibleDayCount()
        val selectedIndex = days.indexOfFirst { it.optString("date") == selectedDate.toString() }.coerceAtLeast(0)
        return selectedIndex.coerceIn(0, max(0, days.size - count))
    }

    internal fun MainActivity.calendarToolbar(): View {
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = underline(theme.bgApp)
            addView(calendarTitleView(), LinearLayout.LayoutParams(-1, dp(42)))
            addView(calendarWeekStrip(), LinearLayout.LayoutParams(-1, dp(66)))
        }.also {
            it.layoutParams = LinearLayout.LayoutParams(-1, dp(108))
        }
    }

    internal fun MainActivity.calendarQuickAddRow(): View =
        HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false
            addView(LinearLayout(this@calendarQuickAddRow).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(dp(8), dp(4), dp(8), 0)
                addView(iconActionChip(GLYPH_CALENDAR, "Event") {
                    quickCreateCalendarItem("event")
                }, marginRight(dp(6), -2, dp(24)))
                addView(iconActionChip(GLYPH_BELL, "Reminder") {
                    quickCreateCalendarItem("reminder")
                }, marginRight(dp(6), -2, dp(24)))
                addView(iconActionChip(GLYPH_TICK, "Assignment") {
                    quickCreateCalendarItem("assignment")
                }, LinearLayout.LayoutParams(-2, dp(24)))
            })
        }

    internal fun MainActivity.quickCreateCalendarItem(kind: String) {
        val initialKind = when (kind) {
            "event", "reminder", "assignment" -> kind
            else -> "task"
        }
        val now = LocalDateTime.now()
        showEventEditorDialog(
            occurrence = null,
            initialDate = selectedDate,
            initialMinute = (now.hour * 60 + now.minute).toFloat(),
            preferredKind = initialKind,
            openForNew = true
        )
    }

    internal fun MainActivity.calendarTitleView(): View =
        FrameLayout(this).apply {
            addView(LinearLayout(this@calendarTitleView).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER
                setPadding(dp(14), 0, dp(12), 0)
                background = rounded(adjustAlpha(theme.textPrimary, if (theme.isDark) 0.07f else 0.055f), dp(18), theme.borderOverlay)
                addView(text(monthTitle(selectedDate), theme.textPrimary, 18f, true).apply {
                    gravity = Gravity.CENTER
                    includeFontPadding = false
                    maxLines = 1
                    ellipsize = TextUtils.TruncateAt.END
                }, LinearLayout.LayoutParams(-2, dp(34)))
                addView(inlineIcon(R.drawable.ic_knotq_chevron_down_24, theme.textMuted, widthDp = 18, iconSize = 15), LinearLayout.LayoutParams(dp(18), dp(34)).apply {
                    setMargins(dp(3), 0, 0, 0)
                })
                setOnClickListener { showMonthPickerDialog() }
            }, FrameLayout.LayoutParams(-2, dp(34), Gravity.CENTER))
        }

