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

    internal fun MainActivity.renderWideShell(): View {
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setBackgroundColor(theme.bgApp)
            addView(renderNavigator(), LinearLayout.LayoutParams(dp(160), -1).apply {
                setMargins(dp(7), dp(7), 0, dp(7))
            })
            addView(renderUpcomingRail(), LinearLayout.LayoutParams(dp(258), -1))
            addView(View(this@renderWideShell).apply { setBackgroundColor(theme.dividerTiny) }, LinearLayout.LayoutParams(dp(1), -1))
            addView(renderMain(), LinearLayout.LayoutParams(0, -1, 1f))
        }
    }

    internal fun MainActivity.renderPhoneMain(): View =
        when (selectedTab) {
            TAB_SEARCH, TAB_SETTINGS -> scroll(renderMain())
            else -> renderMain()
        }

    internal fun MainActivity.renderMain(): View {
        return when (selectedTab) {
            TAB_HOME -> renderHome()
            TAB_CALENDAR -> renderCalendar()
            TAB_SCHEMES -> selectedSchemeId?.let(::findScheme)?.let(::renderSchemeEditor) ?: renderListsPage()
            TAB_DAILY -> renderDaily()
            TAB_SEARCH -> renderSearch()
            TAB_SETTINGS -> renderSettings()
            else -> renderHome()
        }
    }

    internal fun MainActivity.renderNavigator(): View {
        val panel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(8), dp(10), dp(8), dp(8))
            background = rounded(theme.bgSidebar, dp(10), theme.borderOverlay)
        }
        panel.addView(navSpecial(L10n.t(this, "mobile.nav.home"), theme.accent, selectedTab == TAB_HOME) {
            selectedTab = TAB_HOME
            selectedSchemeId = null
            render()
        })
        panel.addView(navSpecial(L10n.t(this, "menu.calendar"), theme.textPrimary, selectedTab == TAB_CALENDAR) {
            selectedTab = TAB_CALENDAR
            selectedSchemeId = null
            render()
        })
        panel.addView(navSpecial(L10n.t(this, "menu.daily"), if (theme.isDark) rgb(0xb8c9e8) else rgb(0x5a7aad), selectedTab == TAB_DAILY) {
            selectedTab = TAB_DAILY
            selectedSchemeId = null
            ensureDaily()
        })
        panel.addView(divider(), LinearLayout.LayoutParams(-1, dp(1)).apply {
            setMargins(dp(3), dp(7), dp(3), dp(8))
        })

        val tree = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        snapshot.optJSONObject("root")?.optJSONArray("children")?.forEachObject { addNode(tree, it, 0) }
        panel.addView(scroll(tree), LinearLayout.LayoutParams(-1, 0, 1f))
        panel.addView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(iconActionChip(GLYPH_ADD, L10n.t(this@renderNavigator, "sidebar.footer.new")) { showNewMenu() }, LinearLayout.LayoutParams(0, dp(30), 1f))
            addView(chip(GLYPH_SETTINGS) {
                selectedTab = TAB_SETTINGS
                selectedSchemeId = null
                render()
            }, LinearLayout.LayoutParams(dp(33), dp(30)).apply { setMargins(dp(6), 0, 0, 0) })
        })
        return panel
    }

    internal fun MainActivity.renderHome(): LinearLayout {
        if (!isWideLayout()) return renderPhoneHome()

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(theme.bgApp)
        }
        val body = page()
        body.addView(homeHeader(), spaced())
        body.addView(homeQuickActions(), LinearLayout.LayoutParams(-1, dp(34)).apply {
            setMargins(0, 0, 0, dp(14))
        })
        body.addView(sectionHeader(L10n.t(this, "event.date.today")))
        body.addView(homeDailySummaryRow(), LinearLayout.LayoutParams(-1, dp(48)).apply {
            setMargins(0, 0, 0, dp(8))
        })
        addOccurrenceSection(body, L10n.t(this, "event.date.today"), L10n.t(this, "upcoming.empty.none_today"), todayOccurrences())

        body.addView(sectionHeader(L10n.t(this, "onboarding.step.schemes.title")))
        val tree = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, dp(2), 0, dp(2))
        }
        snapshot.optJSONObject("root")?.optJSONArray("children")?.forEachObject {
            addNode(tree, it, 0, spacious = true)
        }
        if (tree.childCount == 0) {
            tree.addView(text(L10n.t(this, "mobile.home.no_schemes"), theme.textMuted, 13f, false).apply {
                setPadding(dp(8), dp(6), dp(8), dp(10))
            })
        }
        body.addView(tree, spaced())
        body.addView(archiveNavigatorSection(compact = false), spaced())

        if (resources.configuration.screenWidthDp < 760) {
            addOccurrenceSection(
                body,
                L10n.t(this, "upcoming.section.upcoming"),
                L10n.t(this, "mobile.home.nothing_scheduled"),
                visibleUpcomingOccurrences()
            )
        }
        root.addView(scroll(body), LinearLayout.LayoutParams(-1, 0, 1f))
        return root
    }

    internal fun MainActivity.renderPhoneHome(): LinearLayout {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(theme.bgApp)
        }
        val body = page()
        body.addView(homeSearchEntry(), LinearLayout.LayoutParams(-1, dp(42)).apply {
            setMargins(0, dp(2), 0, dp(15))
        })
        body.addView(phoneSchemesSection(), spaced())
        // Overdue first so it isn't missed, then upcoming, capped like iOS.
        addOccurrenceSection(
            body,
            L10n.t(this, "upcoming.section.upcoming"),
            L10n.t(this, "mobile.home.nothing_scheduled"),
            visibleUpcomingOccurrences()
        )
        root.addView(scroll(body), LinearLayout.LayoutParams(-1, 0, 1f))
        return root
    }

    internal fun MainActivity.visibleUpcomingOccurrences(): JSONArray {
        val settings = snapshot.optJSONObject("settings")
        val maximum = settings?.optInt("maximum_upcoming_items", 14)?.coerceIn(1, 100) ?: 14
        val showOverdue = settings?.optBoolean("show_overdue", true) ?: true
        val showCompleted = settings?.optBoolean("show_completed", true) ?: true
        val result = JSONArray()
        val seen = HashSet<String>()

        fun append(source: JSONArray?) {
            if (source == null) return
            source.forEachObject { occurrence ->
                if (result.length() >= maximum) return@forEachObject
                if (!showCompleted && occurrence.optBoolean("done")) return@forEachObject
                val key = listOf(
                    occurrence.optString("scheme_id"),
                    occurrence.optString("item_id"),
                    occurrence.optString("occurrence_json")
                ).joinToString("|")
                if (seen.add(key)) result.put(occurrence)
            }
        }

        if (showOverdue) append(calendar().optJSONArray("overdue"))
        append(calendar().optJSONArray("upcoming"))
        return result
    }

    internal fun MainActivity.homeSearchEntry(): View =
        LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(12), 0, dp(12), 0)
            background = rounded(theme.bgModal, dp(8), theme.borderOverlay)
            addView(text(L10n.t(this@homeSearchEntry, "search.placeholder"), theme.textMuted, 14f, false), LinearLayout.LayoutParams(0, -1, 1f))
            addView(iconImage(R.drawable.ic_knotq_search_24, theme.textMuted, L10n.t(this@homeSearchEntry, "mobile.a11y.search")), LinearLayout.LayoutParams(dp(28), dp(ICON_SEARCH_VECTOR_SIZE_DP)))
            setOnClickListener {
                selectedTab = TAB_SEARCH
                selectedSchemeId = null
                render()
            }
        }

    internal fun MainActivity.phoneSchemesSection(): View {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
        }
        root.addView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(text(L10n.t(this@phoneSchemesSection, "onboarding.step.schemes.title"), theme.textPrimary, 20f, true), LinearLayout.LayoutParams(0, dp(34), 1f))
            addView(iconSquareImage(R.drawable.ic_knotq_plus_24, L10n.t(this@phoneSchemesSection, "sidebar.footer.new"), iconSize = 17) { showNewMenu() }, LinearLayout.LayoutParams(dp(30), dp(30)))
        }, LinearLayout.LayoutParams(-1, dp(37)).apply {
            setMargins(dp(2), 0, dp(2), dp(3))
        })

        val panel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = rounded(if (theme.isDark) theme.bgToolbar else theme.bgModal, dp(8), theme.borderOverlay)
            setPadding(dp(4), dp(4), dp(4), dp(3))
        }
        // Cap the scheme tree like iOS (max(180dp, 34% of screen height)) so it
        // scrolls within a fixed maximum instead of pushing Upcoming down the page.
        val schemeListMaxPx = max(dp(180), (resources.displayMetrics.heightPixels * 0.34f).roundToInt())
        val schemeScroll = object : ScrollView(this) {
            override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
                super.onMeasure(
                    widthMeasureSpec,
                    MeasureSpec.makeMeasureSpec(schemeListMaxPx, MeasureSpec.AT_MOST)
                )
            }
        }.apply {
            isVerticalScrollBarEnabled = false
            overScrollMode = View.OVER_SCROLL_NEVER
        }
        schemeScroll.addView(this@phoneSchemesSection.NavigatorPanel(this), FrameLayout.LayoutParams(-1, -2))
        panel.addView(schemeScroll, LinearLayout.LayoutParams(-1, -2))
        panel.addView(View(this).apply { setBackgroundColor(theme.dividerSoft) }, LinearLayout.LayoutParams(-1, max(1, (0.5f * resources.displayMetrics.density).roundToInt())).apply {
            setMargins(dp(4), dp(3), dp(4), dp(3))
        })
        panel.addView(homeDailySchemeRow(), LinearLayout.LayoutParams(-1, dp(42)))
        root.addView(panel)
        return root
    }

    /// Scheme tree with iOS-style direct manipulation: tap folders to

    internal fun MainActivity.homeDailySchemeRow(): View {
        val entry = dailyEntryForHome()
        val scheme = entry?.optJSONObject("scheme")
        val openCount = countOpenItems(scheme)
        val date = entry?.optString("date") ?: selectedDate.toString()
        val detail = when {
            openCount == 0 -> MobileDateFormatting.shortDay(date)
            else -> L10n.t(this, "mobile.home.daily_row_open_count", mapOf("day" to MobileDateFormatting.shortDay(date), "count" to openCount.toString()))
        }
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(8), 0, dp(8), 0)
            addView(colorSquare(dailyAccent(), 10), LinearLayout.LayoutParams(dp(10), dp(10)).apply {
                setMargins(0, 0, dp(9), 0)
            })
            addView(text(L10n.t(this@homeDailySchemeRow, "menu.daily"), theme.textPrimary, 14f, true), LinearLayout.LayoutParams(-2, -1))
            addView(text(detail, theme.textSoft, 12f, true).apply {
                setPadding(dp(9), 0, 0, 0)
            }, LinearLayout.LayoutParams(0, -1, 1f))
            addView(inlineIcon(R.drawable.ic_knotq_chevron_right_24, theme.textMuted, widthDp = 24, iconSize = 16))
            setOnClickListener {
                selectedTab = TAB_DAILY
                selectedSchemeId = null
                runCatching { LocalDate.parse(date) }.getOrNull()?.let { selectedDate = it }
                ensureDaily()
            }
        }
    }

    internal fun MainActivity.homeHeader(): View =
        LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(brandMark(36), LinearLayout.LayoutParams(dp(36), dp(36)).apply {
                setMargins(0, 0, dp(10), 0)
            })
            addView(LinearLayout(this@homeHeader).apply {
                orientation = LinearLayout.VERTICAL
                addView(text("KnotQ", theme.textPrimary, 22f, true), LinearLayout.LayoutParams(-1, dp(24)))
                addView(text(MobileDateFormatting.fullDay(selectedDate.toString()), theme.textDim, 12f, false), LinearLayout.LayoutParams(-1, dp(16)))
            }, LinearLayout.LayoutParams(0, -2, 1f))
        }

    internal fun MainActivity.homeQuickActions(): View =
        HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false
            addView(LinearLayout(this@homeQuickActions).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                addView(iconActionChip(GLYPH_TICK, L10n.t(this@homeQuickActions, "mobile.home.action_daily_item")) { addDailyItemFromHome() }, marginRight(dp(6), -2, dp(30)))
                addView(iconActionChip(GLYPH_CALENDAR, L10n.t(this@homeQuickActions, "menu.calendar")) { showCalendarItemDialog() }, marginRight(dp(6), -2, dp(30)))
                addView(iconActionChip(GLYPH_EDIT, L10n.t(this@homeQuickActions, "mobile.new_menu.new_scheme")) {
                    quickCreateScheme()
                }, marginRight(dp(6), -2, dp(30)))
                addView(iconActionChip(GLYPH_FOLDER, L10n.t(this@homeQuickActions, "sidebar.context.new_folder")) {
                    showNameDialog(L10n.t(this@homeQuickActions, "sidebar.context.new_folder"), "", { validateFolderName(it) }) { name ->
                        mutate(obj("type" to "create_folder", "name" to name))
                    }
                }, LinearLayout.LayoutParams(-2, dp(30)))
                addView(iconActionChip(GLYPH_CLOUD, L10n.t(this@homeQuickActions, "mobile.home.action_google")) { startGoogleCalendarImport() }, LinearLayout.LayoutParams(-2, dp(30)))
            })
        }

    internal fun MainActivity.homeDailySummaryRow(): View {
        val entry = dailyEntryForHome()
        val scheme = entry?.optJSONObject("scheme")
        val itemCount = scheme?.optJSONArray("items")?.length() ?: 0
        val doneCount = countDoneItems(scheme)
        val date = entry?.optString("date") ?: selectedDate.toString()
        val detail = if (itemCount == 0) {
            L10n.t(this, "sidebar.empty_items")
        } else {
            L10n.t(this, "mobile.home.daily_progress", mapOf("done" to doneCount.toString(), "total" to itemCount.toString()))
        }
        val summaryText = L10n.t(this, "mobile.home.daily_summary_row", mapOf("day" to MobileDateFormatting.shortDay(date), "detail" to detail))
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(10), 0, dp(8), 0)
            background = rounded(theme.rowSelected, dp(7), theme.dividerSoft)
            addView(colorSquare(dailyAccent(), 10), LinearLayout.LayoutParams(dp(10), dp(10)).apply {
                setMargins(0, 0, dp(9), 0)
            })
            addView(LinearLayout(this@homeDailySummaryRow).apply {
                orientation = LinearLayout.VERTICAL
                addView(text(L10n.t(this@homeDailySummaryRow, "menu.daily"), theme.textPrimary, 14f, true), LinearLayout.LayoutParams(-1, dp(20)))
                addView(text(summaryText, theme.textDim, 12f, false), LinearLayout.LayoutParams(-1, dp(17)))
            }, LinearLayout.LayoutParams(0, -2, 1f))
            addView(text(GLYPH_ADD, theme.textPrimary, ICON_ROW_SIZE_SP, true).apply {
                gravity = Gravity.CENTER
                setOnClickListener { addDailyItemFromHome() }
            }, LinearLayout.LayoutParams(dp(32), dp(34)))
            setOnClickListener {
                selectedTab = TAB_DAILY
                selectedSchemeId = null
                runCatching { LocalDate.parse(date) }.getOrNull()?.let { selectedDate = it }
                ensureDaily()
            }
        }
    }

    internal fun MainActivity.countDoneItems(scheme: JSONObject?): Int {
        var done = 0
        scheme?.optJSONArray("items")?.forEachObject { item ->
            if (item.optBoolean("done")) done++
        }
        return done
    }

    // Matches iOS HomeDailySchemeRow.openCount: not done, non-blank text.
    internal fun MainActivity.countOpenItems(scheme: JSONObject?): Int {
        var open = 0
        scheme?.optJSONArray("items")?.forEachObject { item ->
            if (!item.optBoolean("done") && item.optString("text").trim().isNotEmpty()) open++
        }
        return open
    }

    internal fun MainActivity.renderListsPage(): LinearLayout {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(theme.bgApp)
        }
        val body = page()
        body.addView(sectionHeader(L10n.t(this, "onboarding.step.schemes.title")))
        body.addView(dailyShortcutRow(), LinearLayout.LayoutParams(-1, dp(30)).apply {
            setMargins(0, 0, 0, dp(6))
        })
        val list = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, dp(2), 0, dp(2))
        }
        snapshot.optJSONObject("root")?.optJSONArray("children")?.forEachObject {
            addNode(list, it, 0, spacious = true)
        }
        body.addView(list)
        root.addView(scroll(body), LinearLayout.LayoutParams(-1, 0, 1f))
        return root
    }

    internal fun MainActivity.dailyShortcutRow(): View =
        LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(8), 0, dp(7), 0)
            background = rounded(Color.TRANSPARENT, dp(4))
            addView(colorSquare(dailyAccent(), 9), LinearLayout.LayoutParams(dp(9), dp(9)).apply {
                setMargins(0, 0, dp(7), 0)
            })
            addView(text(L10n.t(this@dailyShortcutRow, "menu.daily"), theme.textPrimary, 13f, true).apply { maxLines = 1 }, LinearLayout.LayoutParams(0, -1, 1f))
            addView(text(GLYPH_RIGHT, theme.textMuted, ICON_TOOL_SIZE_SP, true).apply { gravity = Gravity.CENTER }, LinearLayout.LayoutParams(dp(16), -1))
            setOnClickListener {
                selectedTab = TAB_DAILY
                selectedSchemeId = null
                ensureDaily()
            }
        }

    internal fun MainActivity.archiveNavigatorSection(compact: Boolean): View {
        val schemes = archivedSchemes()
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
        }
        val title = if (schemes.length() == 0) L10n.t(this, "sidebar.context.archive") else L10n.t(this, "mobile.home.archive_count_header", mapOf("count" to schemes.length().toString()))
        root.addView(text(title, theme.textDim, if (compact) 12f else 14f, true).apply {
            setPadding(dp(if (compact) 6 else 8), dp(if (compact) 5 else 8), dp(6), dp(if (compact) 4 else 6))
            setOnLongClickListener {
                if (schemes.length() > 0) showArchiveActions()
                true
            }
        })
        if (schemes.length() == 0) {
            if (!compact) {
                root.addView(text(L10n.t(this, "mobile.home.no_archived_schemes"), theme.textMuted, 13f, false).apply {
                    setPadding(dp(8), 0, dp(8), dp(4))
                })
            }
            return root
        }
        schemes.forEachObject { scheme ->
            root.addView(archivedSchemeRow(scheme, compact), LinearLayout.LayoutParams(-1, if (compact) dp(22) else dp(40)))
        }
        return root
    }

    internal fun MainActivity.archivedSchemeRow(scheme: JSONObject, compact: Boolean): View =
        LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(if (compact) 6 else 10), 0, dp(7), 0)
            addView(colorSquare(adjust(schemeColor(scheme.optInt("color_index")), 0.72f), if (compact) 9 else 10), LinearLayout.LayoutParams(dp(if (compact) 9 else 10), dp(if (compact) 9 else 10)))
            addView(text(scheme.optString("display_name"), theme.textMuted, if (compact) 12f else 14f, false).apply {
                maxLines = 1
            }, LinearLayout.LayoutParams(0, -1, 1f).apply {
                setMargins(dp(if (compact) 7 else 10), 0, 0, 0)
            })
            if (!compact) {
                addView(iconChip(GLYPH_TICK, {
                    mutate(obj("type" to "restore_scheme", "scheme_id" to scheme.optString("id")))
                }), LinearLayout.LayoutParams(dp(28), dp(28)))
            }
            setOnClickListener { showArchivedSchemeActions(scheme) }
            setOnLongClickListener {
                showArchivedSchemeActions(scheme)
                true
            }
        }
