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

    internal fun MainActivity.calendarWeekStrip(): View =
        FrameLayout(this).apply {
            val stripDates = (0 until 7).map { weekStart(selectedDate).plusDays(it.toLong()) }
            val count = calendarVisibleDayCount()
            val visibleDates = (0 until count).map { selectedDate.plusDays(it.toLong()).toString() }.toSet()
            addView(this@calendarWeekStrip.CalendarWeekHighlightView(this@calendarWeekStrip, stripDates, visibleDates), FrameLayout.LayoutParams(-1, -1))
            addView(LinearLayout(this@calendarWeekStrip).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
            stripDates.forEachIndexed { offset, date ->
                val today = date == LocalDate.now()
                    val visible = visibleDates.contains(date.toString())
                addView(LinearLayout(this@calendarWeekStrip).apply {
                    orientation = LinearLayout.VERTICAL
                    gravity = Gravity.CENTER
                        addView(text(date.dayOfWeek.getDisplayName(TextStyle.NARROW, Locale.getDefault()).uppercase(Locale.getDefault()), if (today) calendarDayHighlightColor() else adjustAlpha(theme.textMuted, if (theme.isDark) 0.42f else 0.50f), 10f, true).apply {
                        gravity = Gravity.CENTER
                            includeFontPadding = false
                        }, LinearLayout.LayoutParams(-1, dp(16)))
                        addView(text(date.dayOfMonth.toString(), calendarWeekDayTextColor(today, visible), 18f, today).apply {
                        gravity = Gravity.CENTER
                            includeFontPadding = false
                        }, LinearLayout.LayoutParams(-1, dp(37)))
                    setOnClickListener {
                        selectedDate = date
                        weekOffset = 0
                            calendarScrollDate = date.toString()
                        loadSnapshot()
                        render()
                    }
                }, LinearLayout.LayoutParams(0, -1, 1f).apply {
                        setMargins(0, dp(7), 0, dp(6))
                })
            }
            }, FrameLayout.LayoutParams(-1, -1))
        }

