package com.enigmadux.knotq

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.ActivityInfo
import android.os.Build
import android.os.SystemClock
import android.view.View
import android.view.ViewGroup
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.time.LocalDate

/**
 * A small device-side regression test for the expensive part of the Android
 * shell. It intentionally does not seed or wipe a fixture: running it against
 * an existing install must not destroy the user's workspace.
 */
@RunWith(AndroidJUnit4::class)
class MainActivitySmokeTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()

    @Test
    fun rotationPreservesCalendarCheckpointAndLeavesNoTransitionAttached() {
        val context = instrumentation.targetContext
        context.getSharedPreferences("knotq", Context.MODE_PRIVATE)
            .edit()
            .putBoolean(ONBOARDING_PREF, true)
            .apply()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            runCatching {
                instrumentation.uiAutomation.grantRuntimePermission(
                    context.packageName,
                    Manifest.permission.POST_NOTIFICATIONS,
                )
            }
        }
        var activity = instrumentation.startActivitySync(
            Intent(context, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            },
        ) as MainActivity
        val checkpointDate = LocalDate.of(2030, 1, 15)
        try {
            assertTrue("workspace shell did not start", waitForActivityState(activity, 30_000L) {
                findByContentDescription(it.window.decorView, "Calendar") != null
            })
            instrumentation.runOnMainSync {
                activity.selectedTab = TAB_CALENDAR
                activity.selectedDate = checkpointDate
                activity.weekOffset = 14
                activity.calendarScrollDate = checkpointDate.toString()
                activity.calendarScrollY = 317
                activity.queueContentTransition(ContentTransitionDirection.FORWARD)
                activity.render()
            }
            assertTrue("calendar route did not render before recreation", waitForActivityState(activity, 5_000L) {
                it.selectedTab == TAB_CALENDAR && findCalendarTimeline(it.window.decorView) != null
            })

            instrumentation.runOnMainSync { activity.recreate() }
            activity = waitForResumedActivity(30_000L)
            assertTrue("calendar route did not restore after recreation", waitForActivityState(activity, 30_000L) {
                it.selectedTab == TAB_CALENDAR &&
                    it.selectedDate == checkpointDate &&
                    it.weekOffset == 14 &&
                    it.calendarScrollDate == checkpointDate.toString() &&
                    it.calendarScrollY == 317 &&
                    !it.contentTransitionActive &&
                    findCalendarTimeline(it.window.decorView) != null
            })
            assertEquals("recreated mobile shell must keep desktop toolbar hidden", View.GONE, activity.titleBar.visibility)
            assertEquals(0, activity.titleBar.childCount)
        } finally {
            instrumentation.runOnMainSync {
                if (!activity.isFinishing && !activity.isDestroyed) activity.finish()
            }
        }
    }

    @Test
    fun daySwipeDoesNotArmStaleLongPressAfterSettling() {
        val context = instrumentation.targetContext
        context.getSharedPreferences("knotq", Context.MODE_PRIVATE)
            .edit()
            .putBoolean(ONBOARDING_PREF, true)
            .apply()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            runCatching {
                instrumentation.uiAutomation.grantRuntimePermission(
                    context.packageName,
                    Manifest.permission.POST_NOTIFICATIONS,
                )
            }
        }
        val activity = instrumentation.startActivitySync(
            Intent(context, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            },
        ) as MainActivity
        try {
            assertTrue("workspace shell did not start", waitForActivityState(activity, 30_000L) {
                findByContentDescription(it.window.decorView, "Calendar") != null
            })
            instrumentation.runOnMainSync {
                val calendar = findByContentDescription(activity.window.decorView, "Calendar")
                check(calendar != null) { "missing Calendar dock button" }
                check(calendar!!.performClick()) { "Calendar dock button was not clickable" }
            }
            assertTrue(
                "calendar timeline should appear",
                waitForActivityState(activity, 5_000L) { findCalendarTimeline(it.window.decorView) != null },
            )
            val beforeSwipe = activity.selectedDate
            // A day-swipe starting on empty timeline space used to leave Android's
            // GestureDetector holding a long-press message armed from the original
            // ACTION_DOWN: once the swipe claimed the gesture, later MOVE/UP events
            // were consumed internally and never reached the detector, so it never
            // saw the touch end. ~500ms of real time after the original touch-down
            // (independent of how quickly the page had already settled), that stale
            // message fired and opened a phantom "create event" drag on empty space
            // (reproduced on-device under load; see maybeStartDaySwipe's synthetic
            // ACTION_CANCEL fix). This assertion pins the invariant the fix
            // establishes -- a settled swipe must leave no interaction armed --
            // even though forcing GestureDetector's real Handler-timed race
            // through synthetic input in this harness was not reliable enough to
            // gate on directly.
            instrumentation.runOnMainSync {
                val timeline = findCalendarTimeline(activity.window.decorView)
                check(timeline != null) { "missing calendar timeline" }
                val downTime = SystemClock.uptimeMillis()
                fun dispatch(action: Int, time: Long, x: Float, y: Float) {
                    val motion = android.view.MotionEvent.obtain(downTime, time, action, x, y, 0)
                    try {
                        timeline!!.dispatchTouchEvent(motion)
                    } finally {
                        motion.recycle()
                    }
                }
                dispatch(android.view.MotionEvent.ACTION_DOWN, downTime, 850f, 480f)
                dispatch(android.view.MotionEvent.ACTION_MOVE, downTime + 80L, 520f, 480f)
                dispatch(android.view.MotionEvent.ACTION_UP, downTime + 180L, 250f, 480f)
            }
            assertTrue(
                "calendar swipe should advance exactly one day",
                waitForActivityState(activity, 5_000L) {
                    it.selectedDate == beforeSwipe.plusDays(1) && !it.calendarGestureActive
                },
            )
            // Wait well past ViewConfiguration's long-press timeout (500ms default)
            // measured from the original touch-down above, then confirm no phantom
            // create/drag interaction ever started.
            val deadline = SystemClock.uptimeMillis() + 1_000L
            while (SystemClock.uptimeMillis() < deadline) {
                instrumentation.waitForIdleSync()
                SystemClock.sleep(50L)
            }
            var interactionMode = -1
            var stillOnBeforeDate = false
            instrumentation.runOnMainSync {
                interactionMode = findCalendarTimeline(activity.window.decorView)?.interactionMode ?: -1
                stillOnBeforeDate = activity.selectedDate == beforeSwipe.plusDays(1)
            }
            assertTrue("settled swipe date should still hold after the long-press window", stillOnBeforeDate)
            assertEquals(
                "a settled day-swipe must not leave a phantom create/drag interaction armed",
                CALENDAR_INTERACTION_NONE,
                interactionMode,
            )
        } finally {
            instrumentation.runOnMainSync {
                if (!activity.isFinishing && !activity.isDestroyed) activity.finish()
            }
        }
    }

    @Test
    fun asyncStartupPublishesWorkspaceAndTabRebuildsStayAlive() {
        val context = instrumentation.targetContext
        // The app requests this permission after the first workspace frame so
        // real users see content before Android presents its full-window sheet.
        // Dismiss that unrelated system surface here so the lifecycle checks
        // below exercise KnotQ's Activity rather than the permission controller.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            runCatching {
                instrumentation.uiAutomation.grantRuntimePermission(
                    context.packageName,
                    Manifest.permission.POST_NOTIFICATIONS,
                )
            }
        }
        val intent = Intent(context, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        var activity = instrumentation.startActivitySync(intent) as MainActivity
        try {
            assertTrue(
                "workspace should publish within 30 seconds",
                waitForActivityState(activity, timeoutMs = 30_000L) {
                    findByContentDescription(it.window.decorView, "Calendar") != null
                },
            )
            val content = activity.findViewById<ViewGroup>(android.R.id.content)
            assertNotNull(content)
            assertTrue(content.childCount > 0)
            assertEquals(
                "mobile layouts should not show the distracting desktop toolbar",
                View.GONE,
                activity.titleBar.visibility,
            )
            assertEquals(
                "mobile layouts should not retain desktop toolbar controls",
                0,
                activity.titleBar.childCount,
            )

            // Exercise the same synchronous tree replacement used by real dock
            // taps. The route changes run on the main thread, while the initial
            // snapshot and follow-up refreshes continue through the core queue.
            for (tab in listOf("Calendar", "Settings", "Home")) {
                var button: View? = null
                instrumentation.runOnMainSync {
                    button = findByContentDescription(activity.window.decorView, tab)
                    check(button != null) { "missing dock button $tab" }
                    check(button!!.performClick()) { "dock button $tab was not clickable" }
                }
                instrumentation.waitForIdleSync()
                assertFalse("activity died while rendering tab $tab", activity.isFinishing)
                assertTrue("tab $tab disappeared after navigation", waitForActivityState(activity, 5_000L) {
                    findByContentDescription(it.window.decorView, tab) != null
                })
            }

            // Deterministic route-tap fuzzer: do not wait for a frame between
            // taps. This mirrors an impatient user switching tabs while the
            // previous tree is still being measured and catches stale dock
            // identity, duplicate children, and render callbacks that publish
            // an intermediate route after the final tap.
            val rapidTabs = listOf(
                "Calendar", "Settings", "Home", "Calendar", "Home", "Settings",
                "Calendar", "Home", "Settings", "Home", "Calendar", "Home",
                "Settings", "Calendar", "Home", "Settings", "Home", "Calendar",
                "Home", "Settings", "Home", "Calendar", "Settings", "Home",
            )
            rapidTabs.forEachIndexed { index, tab ->
                instrumentation.runOnMainSync {
                    val button = findByContentDescription(activity.window.decorView, tab)
                    check(button != null) { "missing $tab dock button in rapid route case ${index + 1}" }
                    check(button!!.performClick()) { "$tab dock button was not clickable in rapid route case ${index + 1}" }
                    check(!activity.isFinishing && !activity.isDestroyed) {
                        "Activity became invalid during rapid route case ${index + 1}"
                    }
                }
            }
            assertTrue(
                "rapid route fuzzer should settle on its final Home target",
                waitForActivityState(activity, 5_000L) {
                    it.selectedTab == TAB_HOME &&
                        findByContentDescription(it.window.decorView, "Calendar") != null &&
                        findByContentDescription(it.window.decorView, "Settings") != null
                },
            )

            // Drive the real CalendarTimelineView rather than only testing the
            // pure snap decision. A complete leftward gesture must advance one
            // day and settle without leaving the view in a swiping state.
            instrumentation.runOnMainSync {
                val calendar = findByContentDescription(activity.window.decorView, "Calendar")
                check(calendar != null) { "missing Calendar dock button for swipe test" }
                check(calendar!!.performClick()) { "Calendar dock button was not clickable" }
            }
            assertTrue(
                "calendar timeline should appear before swipe test",
                waitForActivityState(activity, 5_000L) { findCalendarTimeline(it.window.decorView) != null },
            )
            val calendarBeforeSwipe = activity.selectedDate
            instrumentation.runOnMainSync {
                val timeline = findCalendarTimeline(activity.window.decorView)
                check(timeline != null) { "missing calendar timeline" }
                val downTime = SystemClock.uptimeMillis()
                fun event(action: Int, time: Long, x: Float, y: Float) =
                    android.view.MotionEvent.obtain(downTime, time, action, x, y, 0)
                fun dispatch(action: Int, time: Long, x: Float, y: Float) {
                    val motion = event(action, time, x, y)
                    try {
                        timeline!!.dispatchTouchEvent(motion)
                    } finally {
                        motion.recycle()
                    }
                }
                dispatch(android.view.MotionEvent.ACTION_DOWN, downTime, 850f, 480f)
                dispatch(android.view.MotionEvent.ACTION_MOVE, downTime + 80L, 520f, 480f)
                dispatch(android.view.MotionEvent.ACTION_UP, downTime + 180L, 250f, 480f)
            }
            assertTrue(
                "calendar swipe should advance exactly one day",
                waitForActivityState(activity, 5_000L) {
                    it.selectedDate == calendarBeforeSwipe.plusDays(1) && !it.calendarGestureActive
                },
            )
            var settledOffset = Float.NaN
            instrumentation.runOnMainSync {
                settledOffset = findCalendarTimeline(activity.window.decorView)?.pageOffsetX ?: Float.NaN
            }
            assertEquals("calendar page must finish at the exact destination frame", 0f, settledOffset, 0.5f)

            // A second finger sequence arriving during the first page's settle
            // must not cancel the animation, snap the content back to zero, or
            // commit an opposite day against stale data.
            if (animationDuration(activity, 205L) > 0L) {
                val calendarBeforeInterruptedSettle = activity.selectedDate
                instrumentation.runOnMainSync {
                    val timeline = findCalendarTimeline(activity.window.decorView)
                    check(timeline != null) { "missing calendar timeline before settle interruption test" }
                    fun dispatchGesture(startTime: Long, action: Int, time: Long, x: Float) {
                        val motion = android.view.MotionEvent.obtain(startTime, time, action, x, 480f, 0)
                        try {
                            timeline!!.dispatchTouchEvent(motion)
                        } finally {
                            motion.recycle()
                        }
                    }
                    val firstStart = SystemClock.uptimeMillis()
                    dispatchGesture(firstStart, android.view.MotionEvent.ACTION_DOWN, firstStart, 850f)
                    dispatchGesture(firstStart, android.view.MotionEvent.ACTION_MOVE, firstStart + 40L, 520f)
                    dispatchGesture(firstStart, android.view.MotionEvent.ACTION_UP, firstStart + 80L, 250f)

                    // Inject the opposite swipe immediately, while the first
                    // ValueAnimator is still active on the same UI loop.
                    val secondStart = firstStart + 81L
                    dispatchGesture(secondStart, android.view.MotionEvent.ACTION_DOWN, secondStart, 250f)
                    dispatchGesture(secondStart, android.view.MotionEvent.ACTION_MOVE, secondStart + 40L, 580f)
                    dispatchGesture(secondStart, android.view.MotionEvent.ACTION_UP, secondStart + 80L, 850f)
                }
                assertTrue(
                    "interrupted calendar settle should commit only its first page",
                    waitForActivityState(activity, 5_000L) {
                        it.selectedDate == calendarBeforeInterruptedSettle.plusDays(1) && !it.calendarGestureActive
                    },
                )
            }

            // An interrupted drag must spring back without committing a date
            // or leaving the old animator attached to a replaced timeline.
            val calendarBeforeCancel = activity.selectedDate
            instrumentation.runOnMainSync {
                val timeline = findCalendarTimeline(activity.window.decorView)
                check(timeline != null) { "missing calendar timeline before cancel gesture" }
                val downTime = SystemClock.uptimeMillis()
                fun dispatch(action: Int, time: Long, x: Float) {
                    val motion = android.view.MotionEvent.obtain(downTime, time, action, x, 480f, 0)
                    try {
                        timeline!!.dispatchTouchEvent(motion)
                    } finally {
                        motion.recycle()
                    }
                }
                dispatch(android.view.MotionEvent.ACTION_DOWN, downTime, 850f)
                dispatch(android.view.MotionEvent.ACTION_MOVE, downTime + 70L, 790f)
                dispatch(android.view.MotionEvent.ACTION_CANCEL, downTime + 90L, 790f)
            }
            SystemClock.sleep(260L)
            assertEquals(
                "cancelled calendar swipe must not commit a date",
                calendarBeforeCancel,
                activity.selectedDate,
            )
            assertNotNull("timeline must survive a cancelled swipe", findCalendarTimeline(activity.window.decorView))

            // Alternate directions against a freshly rendered timeline. This
            // catches stale View ownership, late snapshot publications, and
            // animator cancellation races that a single swipe cannot expose.
            repeat(6) { cycle ->
                val beforeRapidSwipe = activity.selectedDate
                val forward = cycle % 2 == 0
                instrumentation.runOnMainSync {
                    val timeline = findCalendarTimeline(activity.window.decorView)
                    check(timeline != null) { "missing calendar timeline in rapid swipe ${cycle + 1}" }
                    val downTime = SystemClock.uptimeMillis()
                    fun dispatch(action: Int, time: Long, x: Float) {
                        val motion = android.view.MotionEvent.obtain(downTime, time, action, x, 480f, 0)
                        try {
                            timeline!!.dispatchTouchEvent(motion)
                        } finally {
                            motion.recycle()
                        }
                    }
                    val start = if (forward) 850f else 250f
                    val middle = if (forward) 520f else 580f
                    val end = if (forward) 250f else 850f
                    dispatch(android.view.MotionEvent.ACTION_DOWN, downTime, start)
                    dispatch(android.view.MotionEvent.ACTION_MOVE, downTime + 70L, middle)
                    dispatch(android.view.MotionEvent.ACTION_UP, downTime + 170L, end)
                }
                val expectedRapidDate = beforeRapidSwipe.plusDays(if (forward) 1 else -1)
                val rapidSwipeSettled = waitForActivityState(activity, 5_000L) {
                    it.selectedDate == expectedRapidDate && !it.calendarGestureActive
                }
                if (!rapidSwipeSettled) {
                    var actualDate: java.time.LocalDate? = null
                    var gestureActive = false
                    var renderPending = false
                    var timelinePresent = false
                    instrumentation.runOnMainSync {
                        actualDate = activity.selectedDate
                        gestureActive = activity.calendarGestureActive
                        renderPending = activity.renderRequestPending
                        timelinePresent = findCalendarTimeline(activity.window.decorView) != null
                    }
                    throw AssertionError(
                        "rapid calendar swipe ${cycle + 1} did not settle: " +
                            "expected=$expectedRapidDate actual=$actualDate " +
                            "gestureActive=$gestureActive renderPending=$renderPending " +
                            "timelinePresent=$timelinePresent forward=$forward",
                    )
                }
            }

            // Deterministic gesture fuzzer: mix committed pages, short
            // rebounds, and cancelled drags while deliberately starting the
            // next case before the previous snap necessarily finishes. The
            // seed is fixed so a failure is reproducible from the case index.
            var gestureFuzzState = 0x51f15e77
            fun nextGestureFuzzInt(): Int {
                gestureFuzzState = gestureFuzzState xor (gestureFuzzState shl 13)
                gestureFuzzState = gestureFuzzState xor (gestureFuzzState ushr 17)
                gestureFuzzState = gestureFuzzState xor (gestureFuzzState shl 5)
                return gestureFuzzState
            }
            repeat(24) { caseIndex ->
                val mode = nextGestureFuzzInt().ushr(29) % 3
                val forward = (nextGestureFuzzInt() and 1) == 0
                val beforeFuzzGesture = activity.selectedDate
                val expectedFuzzDate = if (mode == 0) {
                    beforeFuzzGesture.plusDays(if (forward) 1 else -1)
                } else {
                    beforeFuzzGesture
                }
                instrumentation.runOnMainSync {
                    val timeline = findCalendarTimeline(activity.window.decorView)
                    check(timeline != null) { "missing timeline in gesture fuzz case ${caseIndex + 1}" }
                    val downTime = SystemClock.uptimeMillis()
                    fun dispatch(action: Int, time: Long, x: Float) {
                        val motion = android.view.MotionEvent.obtain(downTime, time, action, x, 480f, 0)
                        try {
                            timeline!!.dispatchTouchEvent(motion)
                        } finally {
                            motion.recycle()
                        }
                    }
                    val start = if (forward) 850f else 250f
                    val commitMiddle = if (forward) 520f else 580f
                    val commitEnd = if (forward) 250f else 850f
                    val shortMiddle = if (forward) 800f else 300f
                    dispatch(android.view.MotionEvent.ACTION_DOWN, downTime, start)
                    when (mode) {
                        0 -> {
                            dispatch(android.view.MotionEvent.ACTION_MOVE, downTime + 55L, commitMiddle)
                            dispatch(android.view.MotionEvent.ACTION_UP, downTime + 145L, commitEnd)
                        }
                        1 -> {
                            dispatch(android.view.MotionEvent.ACTION_MOVE, downTime + 55L, shortMiddle)
                            dispatch(android.view.MotionEvent.ACTION_UP, downTime + 120L, shortMiddle)
                        }
                        else -> {
                            dispatch(android.view.MotionEvent.ACTION_MOVE, downTime + 55L, commitMiddle)
                            dispatch(android.view.MotionEvent.ACTION_CANCEL, downTime + 75L, commitMiddle)
                        }
                    }
                }
                assertTrue(
                    "gesture fuzz case ${caseIndex + 1} seed=0x51f15e77 mode=$mode forward=$forward " +
                        "expected=$expectedFuzzDate actual=${activity.selectedDate}",
                    waitForActivityState(activity, 5_000L) {
                        it.selectedDate == expectedFuzzDate && !it.calendarGestureActive
                    },
                )
            }

            // The month picker replaces a weekday header and six rows while
            // its native month query is in flight. Rapidly changing months
            // must not expose a blank/intermediate grid or let an older query
            // overwrite the latest selection.
            val monthTitleBeforePicker = activity.monthTitle(activity.selectedDate)
            instrumentation.runOnMainSync {
                val monthTitle = findClickableContainingText(activity.window.decorView, monthTitleBeforePicker)
                check(monthTitle != null) { "missing calendar month title" }
                check(monthTitle!!.performClick()) { "calendar month title was not clickable" }
            }
            val nextMonthDescription = L10n.t(activity, "mobile.month_picker.next")
            assertTrue(
                "month picker did not open",
                waitForActivityState(activity, 5_000L) {
                    val dialogRoot = it.activeMonthPickerDialog?.window?.decorView
                    dialogRoot != null && findByContentDescription(dialogRoot, nextMonthDescription) != null
                },
            )
            assertTrue(
                "month picker initial grid did not finish loading",
                waitForActivityState(activity, 5_000L) {
                    val dialogRoot = it.activeMonthPickerDialog?.window?.decorView
                    dialogRoot != null && findByText(dialogRoot, "Loading…") == null
                },
            )
            instrumentation.runOnMainSync {
                val dialogRoot = activity.activeMonthPickerDialog?.window?.decorView
                check(dialogRoot != null) { "month picker disappeared before retained-grid check" }
                val next = findByContentDescription(dialogRoot, nextMonthDescription)
                check(next != null) { "month picker next arrow disappeared before retained-grid check" }
                check(next!!.performClick()) { "month picker next arrow was not clickable in retained-grid check" }
                check(findByText(dialogRoot, "Loading…") == null) {
                    "month picker replaced a loaded grid with a loading flash"
                }
            }
            repeat(8) { index ->
                instrumentation.runOnMainSync {
                    val dialogRoot = activity.activeMonthPickerDialog?.window?.decorView
                    check(dialogRoot != null) { "month picker dialog disappeared at step ${index + 1}" }
                    val description = if (index % 2 == 0) {
                        nextMonthDescription
                    } else {
                        L10n.t(activity, "mobile.month_picker.previous")
                    }
                    val arrow = findByContentDescription(dialogRoot, description)
                    check(arrow != null) { "missing month picker arrow at step ${index + 1}" }
                    check(arrow!!.performClick()) { "month picker arrow was not clickable at step ${index + 1}" }
                }
            }
            assertTrue(
                "month picker did not settle after rapid navigation",
                waitForActivityState(activity, 5_000L) {
                    val dialogRoot = it.activeMonthPickerDialog?.window?.decorView
                    dialogRoot != null &&
                        findByContentDescription(dialogRoot, nextMonthDescription) != null &&
                        findByText(dialogRoot, "Loading…") == null
                },
            )
            instrumentation.runOnMainSync { activity.activeMonthPickerDialog?.dismiss() }
            assertTrue(
                "calendar timeline disappeared after closing month picker",
                waitForActivityState(activity, 5_000L) { findCalendarTimeline(it.window.decorView) != null },
            )
            instrumentation.runOnMainSync {
                val home = findByContentDescription(activity.window.decorView, "Home")
                check(home != null) { "missing Home dock button after calendar swipe" }
                check(home!!.performClick()) { "Home dock button was not clickable after calendar swipe" }
            }
            assertTrue(
                "Home should return after calendar swipe",
                waitForActivityState(activity, 5_000L) { it.selectedTab == TAB_HOME },
            )

            // Repainting the already-visible Home route must not replace its
            // content subtree when neither the snapshot nor visible route state
            // changed. This catches accidental regressions to removeAllViews(),
            // which caused scroll/focus churn and visible flicker on sync ticks.
            val dailyActionLabel = context.getString(R.string.mobile_nav_tab_daily)
            instrumentation.runOnMainSync {
                val home = findByContentDescription(activity.window.decorView, "Home")
                check(home != null) { "missing Home dock button" }
                check(home!!.performClick()) { "Home dock button was not clickable" }
            }
            instrumentation.waitForIdleSync()
            var before = waitForStableView(activity, dailyActionLabel, timeoutMs = 5_000L)
            instrumentation.runOnMainSync { activity.requestRender() }
            instrumentation.waitForIdleSync()
            assertSame(
                "stable Home content should be reused across a no-op render",
                before,
                findByContentDescription(activity.window.decorView, dailyActionLabel),
            )

            // Search owns its query field and debounced result rows. A generic
            // render request (the same path used by sync/status callbacks) must
            // not replace that live field while the user is typing.
            instrumentation.runOnMainSync {
                val search = findByContentDescription(
                    activity.window.decorView,
                    context.getString(R.string.mobile_a11y_search),
                )
                check(search != null) { "missing Search action" }
                check(search!!.performClick()) { "Search action was not clickable" }
            }
            if (animationDuration(activity, 190L) > 0L) {
                assertTrue(
                    "Search open transition did not start",
                    waitForActivityState(activity, 500L) {
                        it.contentTransitionActive && it.contentTransitionIncomingTranslationX > 0f
                    },
                )
            }
            assertTrue(
                "search field should appear after navigation",
                waitForActivityState(activity, 5_000L) { findFirstEditable(it.window.decorView) != null },
            )
            var searchField: View? = null
            instrumentation.runOnMainSync {
                searchField = findFirstEditable(activity.window.decorView)
                check(searchField != null) { "missing Search field" }
                activity.requestRender()
            }
            instrumentation.waitForIdleSync()
            assertSame(
                "Search field should survive a snapshot-independent render",
                searchField,
                findFirstEditable(activity.window.decorView),
            )

            val searchBackShouldAnimate = animationDuration(activity, 190L) > 0L
            instrumentation.runOnMainSync { activity.onBackPressed() }
            if (searchBackShouldAnimate) {
                assertTrue(
                    "Search Back transition did not start",
                    waitForActivityState(activity, 500L) {
                        it.contentTransitionActive && it.contentTransitionIncomingTranslationX < 0f
                    },
                )
            }
            instrumentation.waitForIdleSync()

            // Settings subpages use the same quick directional slide as scheme
            // open/back. Exercise both the row navigation and system Back so a
            // route change cannot hard-cut or leave the outgoing page attached.
            instrumentation.runOnMainSync {
                val settings = findByContentDescription(activity.window.decorView, "Settings")
                check(settings != null) { "missing Settings dock button for subpage transition test" }
                check(settings!!.performClick()) { "Settings dock button was not clickable" }
            }
            assertTrue(
                "Settings should open before subpage transition test",
                waitForActivityState(activity, 5_000L) { it.selectedTab == TAB_SETTINGS },
            )
            val timingTitle = context.getString(R.string.settings_timing_title)
            instrumentation.runOnMainSync {
                val timing = findClickableContainingText(activity.window.decorView, timingTitle)
                check(timing != null) { "missing Timing and Notifications settings row" }
                check(timing!!.performClick()) { "timing settings row was not clickable" }
            }
            assertTrue(
                "Timing settings subpage should open",
                waitForActivityState(activity, 5_000L) { it.settingsShowingTiming },
            )
            instrumentation.runOnMainSync { activity.onBackPressed() }
            assertTrue(
                "system Back should return from Timing settings",
                waitForActivityState(activity, 5_000L) {
                    it.selectedTab == TAB_SETTINGS && !it.settingsShowingTiming
                },
            )

            // Return to Home before testing the phone chrome. IME/inset
            // callbacks toggle it outside a route rebuild; the dock must
            // disappear and return as one coherent layout transaction rather
            // than leaving a one-frame gap or detached floating action behind.
            instrumentation.runOnMainSync {
                val home = findByContentDescription(activity.window.decorView, "Home")
                check(home != null) { "missing Home dock button after settings transition" }
                check(home!!.performClick()) { "Home dock button was not clickable after settings transition" }
            }
            assertTrue(
                "Home should return before chrome test",
                waitForActivityState(activity, 5_000L) { it.selectedTab == TAB_HOME },
            )
            instrumentation.runOnMainSync {
                activity.hidePhoneDockForEditing()
                check(activity.dock.visibility == View.GONE) { "dock should hide while editing" }
                activity.showPhoneDockAfterEditing()
                check(activity.dock.visibility == View.VISIBLE) { "dock should return after editing" }
            }

            // Recreate repeatedly to exercise the native queue teardown/startup
            // boundary. A late snapshot or websocket callback from the old
            // Activity must not redraw a detached tree or open a second core.
            repeat(3) { generation ->
                instrumentation.runOnMainSync { activity.recreate() }
                activity = waitForResumedActivity(timeoutMs = 30_000L)
                assertTrue(
                    "workspace should republish after Activity recreation #${generation + 1}",
                    waitForActivityState(activity, timeoutMs = 30_000L) {
                        findByContentDescription(it.window.decorView, "Calendar") != null
                    },
                )
                assertFalse("recreated Activity finished unexpectedly", activity.isFinishing)
            }

            // Exercise real background/foreground boundaries separately from
            // recreation. A delayed render, search result, sync completion, or
            // native startup callback must be harmless after onStop and must not
            // flash an intermediate tree when the task returns to the front.
            repeat(2) { cycle ->
                instrumentation.runOnMainSync {
                    check(activity.moveTaskToBack(true)) { "task did not move to background in cycle ${cycle + 1}" }
                }
                SystemClock.sleep(300L)
                context.startActivity(intent)
                activity = waitForResumedActivity(timeoutMs = 30_000L)
                assertTrue(
                    "workspace should remain available after background cycle #${cycle + 1}",
                    waitForActivityState(activity, timeoutMs = 30_000L) {
                        findByContentDescription(it.window.decorView, "Calendar") != null
                    },
                )
                assertFalse("backgrounded Activity finished unexpectedly", activity.isFinishing)
            }

            // Recreation correctly creates a new tree; from this point onward
            // the repeated no-op renders must preserve that new tree's identity.
            instrumentation.runOnMainSync {
                val home = findByContentDescription(activity.window.decorView, "Home")
                check(home != null) { "missing Home dock button after recreation" }
                check(home!!.performClick()) { "Home dock button was not clickable after recreation" }
            }
            before = waitForStableView(activity, dailyActionLabel, timeoutMs = 5_000L)

            // Stress the no-op route path, not just a single click. The action
            // view must retain identity throughout a burst of redundant redraw
            // requests, which is the shape produced by sync/status callbacks.
            repeat(32) {
                instrumentation.runOnMainSync {
                    val home = findByContentDescription(activity.window.decorView, "Home")
                    check(home != null) { "missing Home dock button" }
                    check(home!!.performClick()) { "Home dock button was not clickable" }
                }
                instrumentation.waitForIdleSync()
                assertSame(
                    "Home content should remain stable during redraw burst",
                    before,
                    findByContentDescription(activity.window.decorView, dailyActionLabel),
                )
            }

            // Feed the phone navigator a deliberately large but valid tree.
            // It should materialize only the initial batch, then grow when the
            // user reaches its current tail instead of inflating all 2,000 rows
            // during one Home render.
            val largeSnapshot = JSONObject(activity.snapshot.toString())
            val largeChildren = JSONArray()
            repeat(2_000) { index ->
                largeChildren.put(
                    JSONObject()
                        .put("id", "stress-scheme-$index")
                        .put("kind", "scheme")
                        .put("name", "Stress scheme $index")
                        .put("color_index", index % 8)
                        .put("items", JSONArray()),
                )
            }
            largeSnapshot.optJSONObject("root")?.put("children", largeChildren)
            val largeArchived = JSONArray()
            repeat(500) { index ->
                largeArchived.put(
                    JSONObject()
                        .put("id", "stress-archived-$index")
                        .put("kind", "scheme")
                        .put("name", "Archived stress $index")
                        .put("display_name", "Archived stress $index")
                        .put("color_index", index % 8)
                        .put("items", JSONArray()),
                )
            }
            largeSnapshot.put("archived_schemes", largeArchived)
            // The Settings archive page uses the tree-shaped representation;
            // keep the same large fixture there so both archive surfaces are
            // covered by the bounded-materialization assertion.
            largeSnapshot.put("archived_nodes", JSONArray(largeArchived.toString()))
            val largeDaily = JSONArray()
            repeat(3_650) { index ->
                val date = LocalDate.now().minusDays(index.toLong()).toString()
                largeDaily.put(
                    JSONObject()
                        .put("date", date)
                        .put(
                            "scheme",
                            JSONObject()
                                .put("id", "stress-daily-$index")
                                .put("display_name", "Daily stress $index")
                                .put(
                                    "items",
                                    JSONArray().put(
                                        JSONObject()
                                            .put("id", "stress-daily-item-$index")
                                            .put("text", "Daily stress entry $index")
                                            .put("marker", "blank")
                                            .put("indent", 0)
                                            .put("done", false),
                                    ),
                                ),
                        ),
                )
            }
            largeSnapshot.put("daily", largeDaily)
            instrumentation.runOnMainSync {
                activity.snapshot = largeSnapshot
                activity.render()
            }
            instrumentation.waitForIdleSync()

            // Daily history can span ten years. Keep all entries available to
            // the adapter while attaching only a viewport-sized number of
            // expensive day/editor trees to the window.
            instrumentation.runOnMainSync {
                activity.selectedTab = TAB_DAILY
                activity.selectedSchemeId = null
                activity.render()
            }
            assertTrue(
                "large Daily feed should appear",
                waitForActivityState(activity, 10_000L) {
                    it.selectedTab == TAB_DAILY && findByTag(it.window.decorView, DAILY_VIEWPORT_TAG) is android.widget.ListView
                },
            )
            val dailyViewport = findByTag(activity.window.decorView, DAILY_VIEWPORT_TAG) as? android.widget.ListView
            assertNotNull("large Daily feed should expose a virtualized viewport", dailyViewport)
            assertEquals("Daily feed should retain all historical entries in its adapter", 3_650, dailyViewport!!.adapter.count)
            assertTrue(
                "Daily feed should attach only a viewport-sized number of day editors",
                dailyViewport.childCount <= 64,
            )
            instrumentation.runOnMainSync {
                activity.selectedTab = TAB_HOME
                activity.render()
            }
            assertTrue(
                "Home should return after the Daily virtualization stress",
                waitForActivityState(activity, 5_000L) { it.selectedTab == TAB_HOME },
            )
            val navigator = findNavigatorPanel(activity.window.decorView)
            assertNotNull("large Home tree should have a navigator", navigator)
            val navigatorList = navigator!!.getChildAt(0) as ViewGroup
            val initialRows = navigatorList.childCount
            assertTrue("navigator should render its initial batch", initialRows > 0)
            assertTrue("navigator should not inflate the entire large tree", initialRows <= NAVIGATOR_INITIAL_BATCH)
            assertTrue(
                "large navigator metadata should remain incremental after first render",
                navigator.hasPendingRows(),
            )
            val navigatorScroll = navigator.parent as? android.widget.ScrollView
            assertNotNull("navigator should remain scrollable", navigatorScroll)
            instrumentation.runOnMainSync {
                navigatorScroll!!.scrollTo(0, navigator.height)
            }
            assertTrue(
                "navigator should materialize more rows after reaching its tail",
                waitForActivityState(activity, 5_000L) {
                    val current = findNavigatorPanel(it.window.decorView) ?: return@waitForActivityState false
                    (current.getChildAt(0) as ViewGroup).childCount > initialRows
                },
            )

            // The most failure-prone transition is a rapid open/back pair:
            // render() has already installed the incoming editor, but the
            // outgoing page is still moving. Repeat it against a fresh row on
            // every cycle so cancellation, view ownership, and translation
            // reset stay correct under real user-speed interaction.
            repeat(12) { cycle ->
                instrumentation.runOnMainSync {
                    val currentNavigator = findNavigatorPanel(activity.window.decorView)
                    check(currentNavigator != null) { "missing navigator before transition cycle ${cycle + 1}" }
                    val currentRows = currentNavigator!!.getChildAt(0) as ViewGroup
                    check(currentRows.childCount > 0) { "navigator has no row before transition cycle ${cycle + 1}" }
                    check(currentRows.getChildAt(0).performClick()) {
                        "scheme row was not clickable in transition cycle ${cycle + 1}"
                    }
                    check(activity.selectedSchemeId != null) {
                        "scheme editor did not open in transition cycle ${cycle + 1}"
                    }
                }
                // Verify the animation actually owns two pages, not merely
                // that the final route eventually becomes correct. Reduced
                // motion intentionally takes the zero-duration path.
                if (animationDuration(activity, 190L) > 0L) {
                    assertTrue(
                        "scheme open transition did not start in cycle ${cycle + 1}",
                        waitForActivityState(activity, 500L) {
                            it.contentTransitionActive && it.contentTransitionIncomingTranslationX > 0f
                        },
                    )
                }
                val backTransitionShouldAnimate = animationDuration(activity, 190L) > 0L
                instrumentation.runOnMainSync {
                    // A sync/status callback can ask for a repaint during the
                    // slide. It must queue behind the transition instead of
                    // cancelling it and tearing down the incoming editor.
                    activity.requestRender()
                    activity.onBackPressed()
                }
                if (backTransitionShouldAnimate) {
                    assertTrue(
                        "scheme Back transition did not start in cycle ${cycle + 1}",
                        waitForActivityState(activity, 500L) {
                            it.contentTransitionActive && it.contentTransitionIncomingTranslationX < 0f
                        },
                    )
                }
                assertTrue(
                    "rapid open/back did not settle on Home in cycle ${cycle + 1}",
                    waitForActivityState(activity, 5_000L) {
                        it.selectedSchemeId == null && it.selectedTab == TAB_HOME && findNavigatorPanel(it.window.decorView) != null
                    },
                )
                instrumentation.waitForIdleSync()
            }

            // Rotation crosses the phone/wide layout boundary. The mobile
            // shell must keep the desktop title bar hidden in both modes.
            instrumentation.runOnMainSync {
                activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
            }
            activity = waitForLayoutMode(wide = true, timeoutMs = 30_000L)
            assertTrue("landscape Activity should use the wide layout", activity.isWideLayout())
            assertEquals(View.GONE, activity.titleBar.visibility)
            assertEquals(0, activity.titleBar.childCount)
            assertTrue(
                "wide navigator should retain an accessible Search action after toolbar removal",
                waitForActivityState(activity, 5_000L) {
                    findByContentDescription(it.window.decorView, "Search") != null
                },
            )
            instrumentation.runOnMainSync {
                val search = findByContentDescription(activity.window.decorView, "Search")
                check(search != null) { "wide Search action disappeared before activation" }
                check(search!!.performClick()) { "wide Search action was not clickable" }
            }
            assertTrue(
                "wide Search action should open its query field",
                waitForActivityState(activity, 5_000L) { findFirstEditable(it.window.decorView) != null },
            )
            instrumentation.runOnMainSync { activity.onBackPressed() }
            assertTrue(
                "wide Search Back should restore Home",
                waitForActivityState(activity, 5_000L) {
                    it.selectedTab == TAB_HOME && findByContentDescription(it.window.decorView, "Search") != null
                },
            )
            instrumentation.runOnMainSync {
                val settings = findByContentDescription(activity.window.decorView, "Settings")
                check(settings != null) { "wide navigator Settings action disappeared after toolbar removal" }
                check(settings!!.performClick()) { "wide navigator Settings action was not clickable" }
            }
            assertTrue(
                "wide navigator Settings action should open Settings",
                waitForActivityState(activity, 5_000L) { it.selectedTab == TAB_SETTINGS },
            )
            val wideTimingTitle = context.getString(R.string.settings_timing_title)
            instrumentation.runOnMainSync {
                val timing = findClickableContainingText(activity.window.decorView, wideTimingTitle)
                check(timing != null) { "wide Settings root did not expose Timing and Notifications" }
                check(timing!!.performClick()) { "wide Timing and Notifications row was not clickable" }
            }
            assertTrue(
                "wide Timing settings subpage should open",
                waitForActivityState(activity, 5_000L) { it.settingsShowingTiming },
            )
            instrumentation.runOnMainSync {
                val home = findByContentDescription(activity.window.decorView, "Home")
                check(home != null) { "wide Home action disappeared from the Settings subpage" }
                check(home!!.performClick()) { "wide Home action was not clickable from Settings" }
            }
            assertTrue(
                "wide Home should return from Settings subpage",
                waitForActivityState(activity, 5_000L) { it.selectedTab == TAB_HOME },
            )
            instrumentation.runOnMainSync {
                val settings = findByContentDescription(activity.window.decorView, "Settings")
                check(settings != null) { "wide navigator Settings action disappeared after returning Home" }
                check(settings!!.performClick()) { "wide navigator Settings action was not clickable after returning Home" }
            }
            assertTrue(
                "wide Settings should reopen at its root after returning Home",
                waitForActivityState(activity, 5_000L) {
                    it.selectedTab == TAB_SETTINGS &&
                        !it.settingsShowingArchive &&
                        !it.settingsShowingTiming &&
                        !it.settingsShowingGoogle
                },
            )
            instrumentation.runOnMainSync { activity.onBackPressed() }
            assertTrue(
                "wide Settings Back should restore Home",
                waitForActivityState(activity, 5_000L) { it.selectedTab == TAB_HOME },
            )

            // Re-inject the large fixture after rotation so wide Home itself
            // is covered, not only the phone navigator and wide side rail.
            instrumentation.runOnMainSync {
                // Render invalidation is identity-based. Use a fresh fixture
                // object here so this remains a real post-rotation rebuild
                // even when the Activity instance survives configuration
                // changes.
                activity.selectedTab = TAB_SETTINGS
                activity.selectedSchemeId = null
                activity.render()
                activity.snapshot = JSONObject(largeSnapshot.toString())
                activity.selectedTab = TAB_HOME
                activity.selectedSchemeId = null
                activity.render()
            }
            assertTrue(
                "wide Home should settle with both bounded navigators",
                waitForActivityState(activity, 5_000L) {
                    findNavigatorPanels(it.window.decorView).size >= 2
                },
            )
            val wideNavigators = findNavigatorPanels(activity.window.decorView)
            assertTrue(
                "wide Home and side rail should both use bounded navigators " +
                    "(found=${wideNavigators.size}, wide=${activity.isWideLayout()}, " +
                    "tab=${activity.selectedTab}, rootChildren=${largeSnapshot.optJSONObject("root")?.optJSONArray("children")?.length()})",
                wideNavigators.size >= 2,
            )
            wideNavigators.forEach { panel ->
                val rows = panel.getChildAt(0) as ViewGroup
                assertTrue(
                    "wide navigator should not inflate the entire large tree",
                    rows.childCount <= NAVIGATOR_INITIAL_BATCH,
                )
            }
            val archiveViewport = findByTag(activity.window.decorView, ARCHIVE_VIEWPORT_TAG) as? android.widget.ScrollView
            assertNotNull("wide Home should expose a bounded archive viewport", archiveViewport)
            val archiveRows = archiveViewport!!.getChildAt(0) as ViewGroup
            val initialArchiveRows = archiveRows.childCount
            assertTrue(
                "archive viewport should materialize only its initial batch",
                initialArchiveRows in 1..ARCHIVE_INITIAL_BATCH,
            )
            assertTrue(
                "archive viewport should finish measuring before scroll",
                waitForActivityState(activity, 5_000L) {
                    val current = findByTag(it.window.decorView, ARCHIVE_VIEWPORT_TAG) as? android.widget.ScrollView
                        ?: return@waitForActivityState false
                    current.height > 0 && current.getChildAt(0).height > current.height
                },
            )
            instrumentation.runOnMainSync {
                val current = findByTag(activity.window.decorView, ARCHIVE_VIEWPORT_TAG) as? android.widget.ScrollView
                check(current != null) { "archive viewport disappeared before scroll" }
                current!!.scrollTo(0, current.getChildAt(0).height)
            }
            assertTrue(
                "archive viewport should append rows when scrolled",
                waitForActivityState(activity, 5_000L) {
                    val current = findByTag(it.window.decorView, ARCHIVE_VIEWPORT_TAG) as? android.widget.ScrollView
                        ?: return@waitForActivityState false
                    (current.getChildAt(0) as ViewGroup).childCount > initialArchiveRows
                },
            )

            // The Settings archive page has a separate tree-shaped data path;
            // verify it is bounded too, using the freshly injected fixture.
            instrumentation.runOnMainSync {
                val settings = findByContentDescription(activity.window.decorView, "Settings")
                check(settings != null) { "wide Settings action disappeared before archive-page test" }
                check(settings!!.performClick()) { "wide Settings action was not clickable before archive-page test" }
            }
            assertTrue(
                "wide Settings should reopen at its root before archive-page test",
                waitForActivityState(activity, 5_000L) { it.selectedTab == TAB_SETTINGS && !it.settingsShowingArchive },
            )
            val archiveSettingsTitle = context.getString(R.string.mobile_settings_archived_items)
            instrumentation.runOnMainSync {
                val archiveRow = findClickableContainingText(activity.window.decorView, archiveSettingsTitle)
                check(archiveRow != null) { "wide Settings root did not expose Archived Items" }
                check(archiveRow!!.performClick()) { "Archived Items settings row was not clickable" }
            }
            assertTrue(
                "wide Archived Items page should open",
                waitForActivityState(activity, 5_000L) { it.settingsShowingArchive },
            )
            val archiveSettingsViewport = findByTag(activity.window.decorView, ARCHIVE_VIEWPORT_TAG) as? android.widget.ScrollView
            assertNotNull("Archived Items page should expose a bounded viewport", archiveSettingsViewport)
            val archiveSettingsBody = archiveSettingsViewport!!.getChildAt(0) as ViewGroup
            val initialArchiveSettingsRows = archiveSettingsBody.childCount
            assertTrue(
                "Archived Items page should materialize only its initial batch",
                initialArchiveSettingsRows in 1..ARCHIVE_INITIAL_BATCH,
            )
            assertTrue(
                "Archived Items viewport should finish measuring before scroll",
                waitForActivityState(activity, 5_000L) {
                    val current = findByTag(it.window.decorView, ARCHIVE_VIEWPORT_TAG) as? android.widget.ScrollView
                        ?: return@waitForActivityState false
                    current.height > 0 && current.getChildAt(0).height > current.height
                },
            )
            instrumentation.runOnMainSync {
                val current = findByTag(activity.window.decorView, ARCHIVE_VIEWPORT_TAG) as? android.widget.ScrollView
                check(current != null) { "Archived Items viewport disappeared before scroll" }
                current!!.scrollTo(0, current.getChildAt(0).height)
            }
            assertTrue(
                "Archived Items viewport should append rows when scrolled",
                waitForActivityState(activity, 5_000L) {
                    val current = findByTag(it.window.decorView, ARCHIVE_VIEWPORT_TAG) as? android.widget.ScrollView
                        ?: return@waitForActivityState false
                    (current.getChildAt(0) as ViewGroup).childCount > initialArchiveSettingsRows
                },
            )

            instrumentation.runOnMainSync {
                activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
            }
            activity = waitForLayoutMode(wide = false, timeoutMs = 30_000L)
            assertTrue("portrait Activity should use the phone layout", !activity.isWideLayout())
            assertEquals(View.GONE, activity.titleBar.visibility)
            assertEquals(
                "portrait layout should keep the desktop toolbar empty",
                0,
                activity.titleBar.childCount,
            )

            // Rotation is a particularly good flicker detector: Android may
            // briefly keep the old tree alive while the replacement Activity
            // is measuring a wide/phone shell. Repeat the boundary against
            // the 2,000-node fixture so stale callbacks, duplicate chrome,
            // and detached transition views cannot hide behind a single
            // successful configuration change.
            repeat(4) { cycle ->
                instrumentation.runOnMainSync {
                    activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
                }
                activity = waitForLayoutMode(wide = true, timeoutMs = 30_000L)
                assertTrue("landscape rotation cycle ${cycle + 1} should use wide layout", activity.isWideLayout())
                assertEquals(View.GONE, activity.titleBar.visibility)
                assertEquals(0, activity.titleBar.childCount)

                instrumentation.runOnMainSync {
                    activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
                }
                activity = waitForLayoutMode(wide = false, timeoutMs = 30_000L)
                assertTrue("portrait rotation cycle ${cycle + 1} should use phone layout", !activity.isWideLayout())
                assertEquals(View.GONE, activity.titleBar.visibility)
                assertEquals(0, activity.titleBar.childCount)
            }
        } finally {
            instrumentation.runOnMainSync {
                if (!activity.isFinishing) activity.finish()
            }
            instrumentation.waitForIdleSync()
        }
    }

    private fun waitForActivityState(
        activity: MainActivity,
        timeoutMs: Long,
        predicate: (MainActivity) -> Boolean,
    ): Boolean {
        val deadline = SystemClock.uptimeMillis() + timeoutMs
        while (SystemClock.uptimeMillis() < deadline) {
            var matched = false
            instrumentation.runOnMainSync {
                matched = !activity.isFinishing && !activity.isDestroyed && predicate(activity)
            }
            if (matched) return true
            instrumentation.waitForIdleSync()
            SystemClock.sleep(50L)
        }
        return false
    }

    private fun waitForResumedActivity(timeoutMs: Long): MainActivity {
        val deadline = SystemClock.uptimeMillis() + timeoutMs
        while (SystemClock.uptimeMillis() < deadline) {
            var resumed: MainActivity? = null
            instrumentation.runOnMainSync {
                resumed = ActivityLifecycleMonitorRegistry.getInstance()
                    .getActivitiesInStage(Stage.RESUMED)
                    .filterIsInstance<MainActivity>()
                    .firstOrNull { !it.isFinishing && !it.isDestroyed }
            }
            resumed?.let { return it }
            instrumentation.waitForIdleSync()
            SystemClock.sleep(50L)
        }
        throw AssertionError("MainActivity did not return to RESUMED within ${timeoutMs}ms")
    }

    private fun waitForLayoutMode(wide: Boolean, timeoutMs: Long): MainActivity {
        val deadline = SystemClock.uptimeMillis() + timeoutMs
        while (SystemClock.uptimeMillis() < deadline) {
            var match: MainActivity? = null
            instrumentation.runOnMainSync {
                match = ActivityLifecycleMonitorRegistry.getInstance()
                    .getActivitiesInStage(Stage.RESUMED)
                    .filterIsInstance<MainActivity>()
                    .firstOrNull { candidate ->
                        !candidate.isFinishing && !candidate.isDestroyed && candidate.isWideLayout() == wide
                    }
            }
            match?.let { return it }
            instrumentation.waitForIdleSync()
            SystemClock.sleep(50L)
        }
        throw AssertionError("MainActivity did not settle into ${if (wide) "wide" else "phone"} layout within ${timeoutMs}ms")
    }

    private fun waitForStableView(activity: MainActivity, description: String, timeoutMs: Long): View {
        val deadline = SystemClock.uptimeMillis() + timeoutMs
        var previous: View? = null
        var stableSamples = 0
        while (SystemClock.uptimeMillis() < deadline) {
            var current: View? = null
            instrumentation.runOnMainSync {
                if (!activity.isFinishing && !activity.isDestroyed) {
                    current = findByContentDescription(activity.window.decorView, description)
                }
            }
            if (current != null && current === previous) {
                stableSamples++
                if (stableSamples >= 3) return current!!
            } else {
                stableSamples = 0
            }
            previous = current
            instrumentation.waitForIdleSync()
            SystemClock.sleep(100L)
        }
        throw AssertionError("$description did not remain stable within ${timeoutMs}ms")
    }

    private fun findFirstEditable(root: View): View? {
        if (root is android.widget.EditText) return root
        if (root !is ViewGroup) return null
        for (index in 0 until root.childCount) {
            findFirstEditable(root.getChildAt(index))?.let { return it }
        }
        return null
    }

    private fun findByText(root: View, text: CharSequence): View? {
        if (root is android.widget.TextView && root.text == text) return root
        if (root !is ViewGroup) return null
        for (index in 0 until root.childCount) {
            findByText(root.getChildAt(index), text)?.let { return it }
        }
        return null
    }

    private fun findClickableContainingText(root: View, text: CharSequence): View? {
        if (root is ViewGroup && root.isClickable && findByText(root, text) != null) return root
        if (root is android.widget.TextView && root.isClickable && root.text == text) return root
        if (root !is ViewGroup) return null
        for (index in 0 until root.childCount) {
            findClickableContainingText(root.getChildAt(index), text)?.let { return it }
        }
        return null
    }

    private fun findNavigatorPanel(root: View): MainActivity.NavigatorPanel? {
        if (root is MainActivity.NavigatorPanel) return root
        if (root !is ViewGroup) return null
        for (index in 0 until root.childCount) {
            findNavigatorPanel(root.getChildAt(index))?.let { return it }
        }
        return null
    }

    private fun findNavigatorPanels(root: View): List<MainActivity.NavigatorPanel> {
        val result = ArrayList<MainActivity.NavigatorPanel>()
        fun visit(view: View) {
            if (view is MainActivity.NavigatorPanel) result += view
            if (view is ViewGroup) {
                for (index in 0 until view.childCount) visit(view.getChildAt(index))
            }
        }
        visit(root)
        return result
    }

    private fun findCalendarTimeline(root: View): MainActivity.CalendarTimelineView? {
        if (root is MainActivity.CalendarTimelineView) return root
        if (root !is ViewGroup) return null
        for (index in 0 until root.childCount) {
            findCalendarTimeline(root.getChildAt(index))?.let { return it }
        }
        return null
    }

    private fun findByContentDescription(root: View, description: String): View? {
        if (root.contentDescription == description) return root
        if (root !is ViewGroup) return null
        for (index in 0 until root.childCount) {
            findByContentDescription(root.getChildAt(index), description)?.let { return it }
        }
        return null
    }

    private fun findByTag(root: View, tag: Any): View? {
        if (root.tag == tag) return root
        if (root is ViewGroup) {
            for (index in 0 until root.childCount) {
                findByTag(root.getChildAt(index), tag)?.let { return it }
            }
        }
        return null
    }
}
