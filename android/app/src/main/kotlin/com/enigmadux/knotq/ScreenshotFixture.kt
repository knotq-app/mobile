package com.enigmadux.knotq

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.time.LocalDate

// Debug-only App Store / Play Store screenshot harness. Mirrors the iOS
// `seedScreenshotFixtureIfRequested` in AppModel.swift: it wipes the workspace
// and seeds a deterministic demo dataset, then routes straight to a screen.
//
// Triggered by launching with intent extras (debug builds only), e.g.:
//   adb shell am start -n com.enigmadux.knotq/.MainActivity \
//     --ez knotq_screenshot_fixture true --es knotq_screenshot_route home
//
// Routes: home | calendar | scheme | daily

internal fun MainActivity.screenshotFixtureRequested(): Boolean {
    if (!BuildConfig.DEBUG) return false
    return intent?.getBooleanExtra("knotq_screenshot_fixture", false) == true
}

internal fun MainActivity.screenshotInitialRoute(): String? =
    intent?.getStringExtra("knotq_screenshot_route")?.lowercase()

/// Seeds the screenshot fixture when requested. Returns true if it ran, so the
/// caller can skip onboarding. Leaves `selectedTab`/`selectedSchemeId` pointed
/// at the requested route and the snapshot reloaded.
internal fun MainActivity.seedScreenshotFixtureIfRequested(): Boolean {
    if (!screenshotFixtureRequested()) return false

    // Drop any sync session + mark onboarding complete so neither overwrites or
    // covers the seeded workspace.
    getSharedPreferences("knotq", Context.MODE_PRIVATE).edit()
        .remove(SYNC_SESSION_PREF)
        .putBoolean(ONBOARDING_PREF, true)
        .apply()
    syncSession = null

    selectedDate = LocalDate.now()
    weekOffset = 0

    bridge.request(obj("type" to "reset_workspace"))
    bridge.request(obj("type" to "set_theme_mode", "theme_mode" to "dark"))
    bridge.request(obj("type" to "set_time_format", "time_format" to "twelve_hour"))
    bridge.request(
        obj(
            "type" to "set_notification_defaults",
            "event_offset_secs" to 10 * 60,
            "assignment_offset_secs" to 2 * 60 * 60
        )
    )

    val launchId = renameOrCreateScreenshotScheme(
        listOf("Start Here", "Example Plan", "Coursework"), "Semester Plan", 4
    )
    val scheduleId = renameOrCreateScreenshotScheme(listOf("Scheduling"), "Schedule", 5)
    val roadmapId = renameOrCreateScreenshotScheme(listOf("Projects"), "Research Project", 2)
    val classesId = createScreenshotScheme("Classes", 3)
    val fitnessId = createScreenshotScheme("Fitness", 0)
    val musicId = createScreenshotScheme("Music", 5)
    val lifeId = createScreenshotScheme("Life Admin", 9)
    val financeId = createScreenshotScheme("Finances", 7)

    replaceScreenshotItems(launchId, launchPlanItems())
    replaceScreenshotItems(scheduleId, scheduleItems())
    replaceScreenshotItems(roadmapId, roadmapItems())
    replaceScreenshotItems(classesId, classesItems())
    replaceScreenshotItems(fitnessId, fitnessItems())
    replaceScreenshotItems(musicId, musicItems())
    replaceScreenshotItems(lifeId, lifeAdminItems())
    replaceScreenshotItems(financeId, financeItems())
    seedDailyScreenshotItems()

    loadSnapshot()

    when (screenshotInitialRoute()) {
        "home" -> { selectedTab = TAB_HOME; selectedSchemeId = null }
        "scheme" -> {
            val id = schemeIdByName("Semester Plan") ?: firstRegularSchemeId()
            if (id != null) { selectedTab = TAB_SCHEMES; selectedSchemeId = id }
        }
        "daily" -> {
            ensureTodayDailyQueue()
            selectedTab = TAB_DAILY
            selectedSchemeId = null
        }
        else -> { selectedTab = TAB_CALENDAR; selectedSchemeId = null } // "calendar" / null
    }
    return true
}

private fun MainActivity.freshSchemes(): JSONArray =
    bridge.request(
        obj("type" to "snapshot", "today" to selectedDate.toString(), "week_offset" to weekOffset)
    ).optJSONArray("schemes") ?: JSONArray()

private fun MainActivity.schemeIdByName(name: String): String? {
    val schemes = freshSchemes()
    for (index in 0 until schemes.length()) {
        val scheme = schemes.optJSONObject(index) ?: continue
        if (scheme.optString("name") == name) {
            return scheme.optString("id").takeIf { it.isNotEmpty() }
        }
    }
    return null
}

private fun MainActivity.renameOrCreateScreenshotScheme(
    currentNames: List<String>,
    targetName: String,
    colorIndex: Int
): String {
    val schemes = freshSchemes()
    for (index in 0 until schemes.length()) {
        val scheme = schemes.optJSONObject(index) ?: continue
        val name = scheme.optString("name")
        if (name == targetName || currentNames.contains(name)) {
            val id = scheme.optString("id")
            if (name != targetName) {
                bridge.request(obj("type" to "rename_scheme", "scheme_id" to id, "name" to targetName))
            }
            bridge.request(obj("type" to "set_scheme_color", "scheme_id" to id, "color_index" to colorIndex))
            return id
        }
    }
    return createScreenshotScheme(targetName, colorIndex)
}

private fun MainActivity.createScreenshotScheme(name: String, colorIndex: Int): String {
    val before = HashSet<String>()
    freshSchemes().let { pre ->
        for (index in 0 until pre.length()) {
            pre.optJSONObject(index)?.optString("id")?.let(before::add)
        }
    }
    bridge.request(obj("type" to "create_scheme", "name" to name, "color_index" to colorIndex))
    val after = freshSchemes()
    var fallback: String? = null
    for (index in 0 until after.length()) {
        val scheme = after.optJSONObject(index) ?: continue
        if (scheme.optString("name") == name) {
            val id = scheme.optString("id")
            if (!before.contains(id)) return id
            fallback = id
        }
    }
    return fallback ?: error("Could not create screenshot scheme $name.")
}

private fun MainActivity.replaceScreenshotItems(schemeId: String, items: JSONArray) {
    bridge.request(obj("type" to "replace_scheme_items", "scheme_id" to schemeId, "items" to items))
}

private fun MainActivity.seedDailyScreenshotItems() {
    val today = selectedDate.toString()
    bridge.request(obj("type" to "ensure_daily_queue", "date" to today))
    val days = bridge.request(
        obj("type" to "snapshot", "today" to today, "week_offset" to weekOffset)
    ).optJSONArray("daily") ?: JSONArray()
    var dailyId: String? = null
    for (index in 0 until days.length()) {
        val day = days.optJSONObject(index) ?: continue
        if (day.optString("date") == today) {
            dailyId = day.optJSONObject("scheme")?.optString("id")
            break
        }
    }
    val id = dailyId ?: error("Could not prepare today's daily queue.")
    replaceScreenshotItems(
        id,
        items(
            item("Today", "blank"),
            item("Review lecture notes", "checkbox", done = true),
            item("Finish calculus questions", "checkbox"),
            item("Email lab partner", "checkbox"),
            item("Pack books for tutoring", "checkbox"),
            item("Draft history thesis paragraph", "checkbox", end = sdate(0, 21, 15)),
            item("Inbox", "blank"),
            item("Check scholarship portal", "checkbox"),
            item("Text study group", "checkbox"),
            item("Loose notes", "blank"),
            item("Bring blue notebook to art history", "bullet", indent = 1)
        )
    )
}

private fun MainActivity.launchPlanItems(): JSONArray = items(
    item("Spring semester", "blank"),
    item("Coursework", "bullet"),
    item("Read philosophy chapter 8", "checkbox", indent = 1, done = true),
    item("Outline art history essay", "checkbox", indent = 1),
    item("Prepare stats lab questions", "checkbox", indent = 1, end = sdate(1, 16, 45)),
    item("Campus", "bullet"),
    item("Reserve library study room", "checkbox", indent = 1, done = true),
    item("Meet writing tutor", "checkbox", indent = 1),
    item("Print music theory worksheet", "checkbox", indent = 1),
    item("Submit financial aid form", "checkbox", indent = 1),
    item("Exam prep", "bullet"),
    item("Make flashcards for psychology", "checkbox", indent = 1),
    item("Archive last week's notes", "checkbox", indent = 1)
)

private fun MainActivity.scheduleItems(): JSONArray = items(
    item("Calendar blocks", "blank"),
    item("Morning review", "checkbox", done = true, start = sdate(0, 11, 15), end = sdate(0, 11, 45)),
    item("Library study block", "checkbox", done = true),
    item("Essay drafting", "checkbox", done = true),
    item("Group project meeting", "checkbox", start = sdate(1, 12, 30), end = sdate(1, 13, 15)),
    item("Office hours", "checkbox"),
    item("Weekly planning", "checkbox")
)

private fun MainActivity.roadmapItems(): JSONArray = items(
    item("History research paper", "blank"),
    item("Find five primary sources", "checkbox", done = true),
    item("Annotate museum catalog", "checkbox"),
    item("Send thesis to professor", "checkbox", end = sdate(2, 12, 0)),
    item("Draft sections", "blank"),
    item("Write intro paragraph", "checkbox"),
    item("Revise source notes", "checkbox")
)

private fun MainActivity.classesItems(): JSONArray = items(
    item("Coursework", "blank"),
    item("Calculus problem set", "checkbox", done = true),
    item("Art History critique", "checkbox", end = sdate(1, 22, 0)),
    item("Psych reading response Ch. 7", "checkbox", end = sdate(1, 23, 0)),
    item("Stats problem set 8", "checkbox"),
    item("Creative writing portfolio", "checkbox"),
    item("Seminars", "blank"),
    item("Chemistry lecture", "checkbox", done = true, start = sdate(0, 12, 0), end = sdate(0, 12, 50)),
    item("Art History seminar", "checkbox", start = sdate(1, 11, 15), end = sdate(1, 12, 0)),
    item("Stats lab", "checkbox", start = sdate(3, 14, 0), end = sdate(3, 15, 15))
)

private fun MainActivity.fitnessItems(): JSONArray = items(
    item("Training", "blank"),
    item("Club run", "checkbox", start = sdate(1, 15, 15), end = sdate(1, 16, 0)),
    item("Gym: upper body", "checkbox", start = sdate(2, 8, 0), end = sdate(2, 9, 0)),
    item("Yoga class", "checkbox"),
    item("Pack running shoes", "checkbox", done = true)
)

private fun MainActivity.musicItems(): JSONArray = items(
    item("Practice", "blank"),
    item("Piano practice", "checkbox", done = true),
    item("Band rehearsal", "checkbox", start = sdate(2, 14, 0), end = sdate(2, 15, 30)),
    item("Theory analysis", "checkbox")
)

private fun MainActivity.lifeAdminItems(): JSONArray = items(
    item("Errands", "blank"),
    item("Pick up groceries", "checkbox", start = sdate(4, 17, 0)),
    item("Call Maya", "checkbox"),
    item("Renew library books", "checkbox"),
    item("Movie night", "checkbox")
)

private fun MainActivity.financeItems(): JSONArray = items(
    item("Monthly", "blank"),
    item("Rent due", "checkbox", end = sdate(6, 9, 0)),
    item("Reconcile subscriptions", "checkbox"),
    item("Update budget notes", "checkbox")
)

private fun items(vararg entries: JSONObject): JSONArray {
    val array = JSONArray()
    entries.forEach(array::put)
    return array
}

private fun item(
    text: String,
    marker: String,
    indent: Int = 0,
    done: Boolean = false,
    start: String? = null,
    end: String? = null
): JSONObject = obj(
    "text" to text,
    "marker" to marker,
    "indent" to indent,
    "done" to done,
    "start" to start,
    "end" to end
)

/// Local wall-clock datetime, `dayOffset` days from today, as a UTC ISO instant
/// (round-trips back to the same local time the app displays).
private fun MainActivity.sdate(dayOffset: Int, hour: Int, minute: Int): String =
    MobileDateFormatting.iso(selectedDate.plusDays(dayOffset.toLong()), hour, minute)
