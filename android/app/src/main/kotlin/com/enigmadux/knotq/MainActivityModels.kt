package com.enigmadux.knotq

import android.widget.EditText
import org.json.JSONObject
import java.util.ArrayDeque

/// The floating inline table-cell editor currently shown, with everything
/// needed to commit its per-line diff back to the core.
internal class ActiveCellEdit(
    val editor: SchemeEditText,
    val field: EditText,
    val schemeId: String,
    val itemId: String,
    val hit: TableCellHit,
    val oldLines: List<String>,
)

internal enum class TableStructureAction {
    INSERT_ROW_ABOVE,
    INSERT_ROW_BELOW,
    DELETE_ROW,
    INSERT_COLUMN_LEFT,
    INSERT_COLUMN_RIGHT,
    DELETE_COLUMN
}

/**
 * Search owns its query/result views and refreshes them through its own
 * debounced request. A workspace snapshot update therefore must not tear down
 * the active search field; doing so loses focus, scroll position, and pending
 * result identity while the user is typing. Other routes render directly from
 * the snapshot and must rebuild when it changes.
 */
internal fun shouldRebuildMainContent(
    selectedTab: Int,
    snapshotChanged: Boolean,
    renderStateChanged: Boolean,
): Boolean = renderStateChanged || (selectedTab != TAB_SEARCH && snapshotChanged)

/**
 * IME/focus callbacks may repeat one search query. Snapshot identity is part of
 * the key so an unchanged query is allowed to refresh after a real workspace
 * update without duplicating an in-flight request.
 */
internal fun isDuplicateSearchRequest(
    lastQuery: String?,
    lastSnapshot: Any?,
    nextQuery: String,
    nextSnapshot: Any,
): Boolean = lastQuery == nextQuery && lastSnapshot === nextSnapshot

internal data class ContentRenderRouteScope(
    val settings: Boolean,
    val daily: Boolean,
    val schemes: Boolean,
)

/**
 * Selects which one-shot/status portions of the render signature can affect
 * the active route. Keeping this pure makes the no-unnecessary-rebuild rule
 * easy to fuzz without constructing an Activity.
 */
internal fun contentRenderRouteScope(selectedTab: Int): ContentRenderRouteScope =
    ContentRenderRouteScope(
        settings = selectedTab == TAB_SETTINGS,
        daily = selectedTab == TAB_DAILY,
        schemes = selectedTab == TAB_SCHEMES,
    )

/**
 * A directional animation belongs to the render that consumes the new page.
 * If a render turns out to be a no-op, discard the queued direction instead of
 * letting a later unrelated rebuild inherit an old slide direction.
 */
internal fun contentTransitionForRebuild(
    rebuildContent: Boolean,
    pending: ContentTransitionDirection?,
): ContentTransitionDirection? = pending.takeIf { rebuildContent }

/**
 * Flattens the visible part of the workspace tree without recursive calls.
 * Large or damaged workspaces can contain far deeper nesting than a normal
 * phone screen; an explicit stack keeps rendering from turning that data into
 * a UI-thread StackOverflowError. Collapsed folders prune their descendants
 * before any view is created.
 */
internal fun <T> flattenVisibleTree(
    roots: List<T>,
    collapsedIds: Set<String>,
    idOf: (T) -> String,
    isFolder: (T) -> Boolean,
    childrenOf: (T) -> List<T>,
): List<Pair<T, Int>> {
    val result = ArrayList<Pair<T, Int>>(roots.size)
    val pending = ArrayDeque<Pair<T, Int>>()
    for (index in roots.indices.reversed()) {
        pending.addLast(roots[index] to 0)
    }
    while (pending.isNotEmpty()) {
        val (node, depth) = pending.removeLast()
        result += node to depth
        if (!isFolder(node) || collapsedIds.contains(idOf(node))) continue
        val children = childrenOf(node)
        for (index in children.indices.reversed()) {
            pending.addLast(children[index] to (depth + 1))
        }
    }
    return result
}

internal const val LAZY_NAVIGATOR_THRESHOLD = 200

/**
 * Selects the virtualized navigator only when a visible tree is large enough
 * to make eager View inflation expensive. This is deliberately iterative and
 * short-circuits at the threshold: ordinary workspaces pay for one bounded
 * metadata walk, while pathological trees never require a full count before
 * the lazy path is chosen.
 */
internal fun <T> shouldUseLazyNavigator(
    roots: List<T>,
    collapsedIds: Set<String>,
    idOf: (T) -> String,
    isFolder: (T) -> Boolean,
    childrenOf: (T) -> List<T>,
    threshold: Int = LAZY_NAVIGATOR_THRESHOLD,
): Boolean {
    require(threshold >= 0) { "navigator threshold must be non-negative" }
    val pending = ArrayDeque<T>()
    for (index in roots.indices.reversed()) pending.addLast(roots[index])
    var seen = 0
    while (pending.isNotEmpty()) {
        val node = pending.removeLast()
        seen++
        if (seen > threshold) return true
        if (!isFolder(node) || collapsedIds.contains(idOf(node))) continue
        val nested = childrenOf(node)
        for (index in nested.indices.reversed()) {
            pending.addLast(nested[index])
        }
    }
    return false
}

internal fun shouldUseLazyNavigator(
    root: JSONObject?,
    collapsedIds: Set<String>,
    threshold: Int = LAZY_NAVIGATOR_THRESHOLD,
): Boolean {
    val rootNode = root ?: return false
    val roots = buildList {
        val children = rootNode.optJSONArray("children") ?: return@buildList
        for (index in 0 until children.length()) {
            children.optJSONObject(index)?.let(::add)
        }
    }
    return shouldUseLazyNavigator(
        roots = roots,
        collapsedIds = collapsedIds,
        idOf = { it.optString("id") },
        isFolder = { it.optString("kind") == "folder" },
        childrenOf = { node ->
            val children = node.optJSONArray("children") ?: return@shouldUseLazyNavigator emptyList()
            buildList {
                for (index in 0 until children.length()) {
                    children.optJSONObject(index)?.let(::add)
                }
            }
        },
        threshold = threshold,
    )
}

/**
 * Reads the optional daily section defensively. Startup can see an older or
 * partially recovered snapshot; malformed entries must mean "not found" so
 * the core gets a chance to recreate today's queue instead of crashing or
 * showing a permanently missing Daily route.
 */
internal fun snapshotContainsDailyQueue(snapshot: JSONObject, date: String): Boolean {
    val daily = snapshot.optJSONArray("daily") ?: return false
    for (index in 0 until daily.length()) {
        val entry = daily.optJSONObject(index) ?: continue
        if (containsExactDailyDate(listOf(entry.optString("date", "")), date)) return true
    }
    return false
}

internal fun containsExactDailyDate(candidates: Iterable<String?>, date: String): Boolean =
    candidates.any { it == date }

internal fun shouldRefreshTimeDerivedSnapshot(
    initialPublication: Boolean,
    externalRefreshConsumed: Boolean,
    editorFocused: Boolean,
): Boolean = !initialPublication && !externalRefreshConsumed && !editorFocused

/**
 * A notification permission sheet covers the whole app on Android 13+.
 * Present it only over a settled, non-editing Home route so delayed startup
 * work cannot visually replace Settings or an in-flight page transition.
 */
internal fun shouldPresentNotificationPermission(
    uiActive: Boolean,
    onboardingActive: Boolean,
    workspaceUiPublished: Boolean,
    selectedTab: Int,
    selectedSchemeId: String?,
    contentTransitionActive: Boolean,
    editableFieldFocused: Boolean,
): Boolean =
    uiActive &&
        !onboardingActive &&
        workspaceUiPublished &&
        selectedTab == TAB_HOME &&
        selectedSchemeId == null &&
        !contentTransitionActive &&
        !editableFieldFocused
