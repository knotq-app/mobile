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

    internal fun MainActivity.maybeStartOnboarding() {
        if (onboardingActive) return
        if (getSharedPreferences("knotq", Context.MODE_PRIVATE).getBoolean(ONBOARDING_PREF, false)) return
        if (snapshot.optJSONObject("root") == null) return
        onboardingActive = true
        onboardingStep = 0
        // Tutorial first (mirrors iOS); the sign-in prompt is the last step and only
        // appears when the user isn't already signed in.
        onboardingPhase = ONBOARDING_GUIDE
        applyOnboardingStep(0)
    }

    /// Navigates to the step's pane (mirrors desktop) and then redraws the overlay
    /// once the new content has been laid out so the cutout hugs it.
    internal fun MainActivity.applyOnboardingStep(step: Int) {
        onboardingStep = step.coerceIn(0, ONBOARDING_STEPS.size - 1)
        when (ONBOARDING_STEPS[onboardingStep].tab) {
            TAB_SCHEMES -> {
                val id = firstRegularSchemeId()
                if (id != null) {
                    selectedTab = TAB_SCHEMES
                    selectedSchemeId = id
                } else {
                    // No schemes yet: fall back to Home (mirrors desktop).
                    selectedTab = TAB_HOME
                    selectedSchemeId = null
                }
            }
            TAB_DAILY -> {
                ensureTodayDailyQueue()
                selectedTab = TAB_DAILY
                selectedSchemeId = null
            }
            else -> {
                selectedTab = ONBOARDING_STEPS[onboardingStep].tab
                selectedSchemeId = null
            }
        }
        render()
        rootFrame.post { showOnboardingOverlay() }
    }

    internal fun MainActivity.onboardingAdvance() {
        if (onboardingStep >= ONBOARDING_STEPS.size - 1) {
            // After the tour: surface the sign-in / stay-local prompt, unless the user
            // is already signed in (mirrors iOS finishTutorial()). When accounts are
            // compiled out (release), skip the sign-in prompt and finish local-only.
            if (BuildConfig.ACCOUNTS_ENABLED && syncSession == null) {
                onboardingPhase = ONBOARDING_ACCOUNT
                showOnboardingOverlay()
            } else {
                finishOnboarding()
            }
        } else {
            applyOnboardingStep(onboardingStep + 1)
        }
    }

    internal fun MainActivity.onboardingBack() {
        // The account prompt now follows the tour, so step 0 is the first thing shown.
        if (onboardingStep <= 0) return
        applyOnboardingStep(onboardingStep - 1)
    }

    internal fun MainActivity.finishOnboarding() {
        onboardingActive = false
        getSharedPreferences("knotq", Context.MODE_PRIVATE).edit().putBoolean(ONBOARDING_PREF, true).apply()
        removeOnboardingOverlay()
        selectedTab = TAB_HOME
        selectedSchemeId = null
        render()
        // Ask for notification permission now that onboarding is complete, matching
        // iOS (ContentView.finishOnboarding → requestAuthorizationIfNeeded).
        MobileNotificationScheduler.requestPermission(this)
    }


    internal fun MainActivity.buildAccountOverlay(): View {
        val overlay = FrameLayout(this).apply {
            isClickable = true
            setOnClickListener { } // swallow taps to the app behind the scrim
            setBackgroundColor(Color.argb(158, 0, 0, 0))
        }
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(20), dp(22), dp(20), dp(18))
            background = rounded(theme.bgModal, dp(16), theme.borderOverlay)
        }
        card.addView(brandMark(60), LinearLayout.LayoutParams(dp(60), dp(60)).apply { bottomMargin = dp(14) })
        card.addView(text(L10n.t(this, "mobile.onboarding.account_overlay_title"), theme.textPrimary, 24f, true).apply { gravity = Gravity.CENTER })
        card.addView(
            text(L10n.t(this, "mobile.onboarding.account_overlay_subtitle"), theme.textSoft, 13f, false).apply {
                gravity = Gravity.CENTER
            },
            LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(4); bottomMargin = dp(18) }
        )
        card.addView(
            onboardingButton(L10n.t(this, "mobile.onboarding.sign_in_button"), true) { showSyncAccountDialog() },
            LinearLayout.LayoutParams(-1, -2).apply { bottomMargin = dp(10) }
        )
        card.addView(
            onboardingButton(L10n.t(this, "mobile.onboarding.continue_without_account_button"), false) { finishOnboarding() },
            LinearLayout.LayoutParams(-1, -2)
        )
        card.addView(
            text(L10n.t(this, "mobile.onboarding.sync_footnote"), theme.textMuted, 11f, false).apply {
                gravity = Gravity.CENTER
            },
            LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(14) }
        )
        val width = min(dp(380), resources.displayMetrics.widthPixels - dp(40))
        overlay.addView(card, FrameLayout.LayoutParams(width, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.CENTER))
        return overlay
    }

    internal fun MainActivity.buildGuideOverlay(): View {
        val def = ONBOARDING_STEPS[onboardingStep]
        val cutout = if (def.ringsContent) {
            val r = contentRectInRoot()
            if (r.width() > 0 && r.height() > 0) {
                // Inset to keep the ring on-screen and clear of the floating dock.
                Rect(r.left + dp(6), r.top + dp(6), r.right - dp(6), max(r.top + dp(48), r.bottom - dp(76)))
            } else {
                null
            }
        } else {
            null
        }

        val overlay = FrameLayout(this).apply {
            isClickable = true
            setOnClickListener { } // tour is driven by Back / Skip / Next
        }
        overlay.addView(buildSpotlightScrim(cutout), FrameLayout.LayoutParams(-1, -1))

        val cardWidth = min(dp(360), resources.displayMetrics.widthPixels - dp(32))
        val lp = FrameLayout.LayoutParams(cardWidth, FrameLayout.LayoutParams.WRAP_CONTENT)
        if (cutout == null) {
            lp.gravity = Gravity.CENTER
        } else {
            lp.gravity = Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL
            lp.bottomMargin = dp(84)
        }
        overlay.addView(buildGuideCard(), lp)
        return overlay
    }

    internal fun MainActivity.buildSpotlightScrim(cutout: Rect?): View {
        val dimColor = Color.argb(158, 0, 0, 0)
        val ringColor = theme.accent
        val radius = dp(14).toFloat()
        return object : View(this) {
            private val dimPaint = Paint().apply { color = dimColor }
            private val clearPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                xfermode = PorterDuffXfermode(PorterDuff.Mode.CLEAR)
            }
            private val ringPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                style = Paint.Style.STROKE
                strokeWidth = dp(2).toFloat()
                color = ringColor
            }

            init {
                setLayerType(LAYER_TYPE_SOFTWARE, null)
            }

            override fun onDraw(canvas: Canvas) {
                canvas.drawRect(0f, 0f, width.toFloat(), height.toFloat(), dimPaint)
                cutout?.let { r ->
                    val rect = RectF(r.left.toFloat(), r.top.toFloat(), r.right.toFloat(), r.bottom.toFloat())
                    canvas.drawRoundRect(rect, radius, radius, clearPaint)
                    canvas.drawRoundRect(rect, radius, radius, ringPaint)
                }
            }
        }
    }

    internal fun MainActivity.buildGuideCard(): View {
        val def = ONBOARDING_STEPS[onboardingStep]
        val isLast = onboardingStep >= ONBOARDING_STEPS.size - 1
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(16), dp(16), dp(14))
            background = rounded(theme.bgModal, dp(14), theme.borderOverlay)
            elevation = dp(12).toFloat()
        }

        val dots = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        ONBOARDING_STEPS.indices.forEach { i ->
            val active = i == onboardingStep
            dots.addView(View(this).apply {
                background = rounded(if (active) theme.accent else adjustAlpha(theme.borderOverlay, 0.6f), dp(3))
            }, LinearLayout.LayoutParams(dp(if (active) 18 else 6), dp(6)).apply { rightMargin = dp(5) })
        }
        card.addView(dots, LinearLayout.LayoutParams(-2, -2).apply { bottomMargin = dp(12) })

        card.addView(text(def.title, theme.textPrimary, 18f, true))
        card.addView(
            text(def.body, theme.textSoft, 13f, false).apply {
                gravity = Gravity.START
                setLineSpacing(dp(3).toFloat(), 1f)
            },
            LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(7); bottomMargin = dp(14) }
        )

        val buttons = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        if (onboardingStep > 0) {
            buttons.addView(
                onboardingButton(L10n.t(this, "common.back"), false) { onboardingBack() },
                LinearLayout.LayoutParams(-2, -2).apply { rightMargin = dp(8) }
            )
        }
        buttons.addView(text(L10n.t(this, "onboarding.tour.skip"), theme.textMuted, 13f, true).apply {
            setPadding(dp(4), dp(10), dp(12), dp(10))
            setOnClickListener { finishOnboarding() }
        }, LinearLayout.LayoutParams(-2, -2))
        buttons.addView(View(this), LinearLayout.LayoutParams(0, 1, 1f)) // spacer
        buttons.addView(
            onboardingButton(
                // "Continue" leads into the sign-in prompt; "Done" finishes when the
                // user is already signed in (mirrors iOS).
                if (isLast) (if (syncSession == null) L10n.t(this, "onboarding.tour.continue") else L10n.t(this, "common.done")) else L10n.t(this, "onboarding.tour.next"),
                true
            ) { onboardingAdvance() },
            LinearLayout.LayoutParams(-2, -2)
        )
        card.addView(buttons, LinearLayout.LayoutParams(-1, -2))
        return card
    }

    internal fun MainActivity.onboardingButton(label: String, prominent: Boolean, listener: () -> Unit): TextView =
        text(label, if (prominent) Color.WHITE else theme.textPrimary, 14f, true).apply {
            gravity = Gravity.CENTER
            setPadding(dp(16), dp(11), dp(16), dp(11))
            background = if (prominent) {
                rounded(theme.accent, dp(8))
            } else {
                rounded(theme.buttonBg, dp(8), theme.borderOverlay)
            }
            setOnClickListener { listener() }
        }

    internal fun MainActivity.contentRectInRoot(): Rect {
        val rootLoc = IntArray(2)
        rootFrame.getLocationInWindow(rootLoc)
        val cLoc = IntArray(2)
        content.getLocationInWindow(cLoc)
        val left = cLoc[0] - rootLoc[0]
        val top = cLoc[1] - rootLoc[1]
        return Rect(left, top, left + content.width, top + content.height)
    }

    internal fun MainActivity.firstRegularSchemeId(): String? =
        snapshot.optJSONObject("root")?.let { firstRegularSchemeId(it) }

    internal fun MainActivity.firstRegularSchemeId(node: JSONObject): String? {
        val children = node.optJSONArray("children") ?: return null
        for (index in 0 until children.length()) {
            val child = children.optJSONObject(index) ?: continue
            when (child.optString("kind")) {
                "folder" -> firstRegularSchemeId(child)?.let { return it }
                "scheme" -> {
                    if (!child.optBoolean("is_daily_queue", false) && !child.optBoolean("is_read_only", false)) {
                        child.optString("id").takeIf { it.isNotEmpty() }?.let { return it }
                    }
                }
            }
        }
        return null
    }
