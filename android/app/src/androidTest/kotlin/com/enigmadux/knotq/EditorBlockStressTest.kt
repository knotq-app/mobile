package com.enigmadux.knotq

import android.Manifest
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.SystemClock
import android.view.View
import android.view.ViewGroup
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.math.max

/**
 * Drives the real editor canvas with unusually dense block content. The
 * fixture only replaces the Activity snapshot in memory; it never writes to
 * the user's workspace. This protects the paths most likely to cause a frame
 * hitch or stale callback: StaticLayout-heavy tables, failed image decodes,
 * scrolling, and rapid editor replacement.
 */
@RunWith(AndroidJUnit4::class)
class EditorBlockStressTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()

    @Test
    fun denseTablesAndMissingImagesSurviveScrollAndRapidReplacement() {
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
            assertTrue("workspace shell did not start", await(30_000L) {
                findByContentDescription(activity.window.decorView, "Calendar") != null
            })

            val stressId = "instrumentation-editor-block-stress"
            val snapshot = JSONObject(activity.snapshot.toString())
            val schemes = snapshot.optJSONArray("schemes") ?: JSONArray().also {
                snapshot.put("schemes", it)
            }
            schemes.put(denseStressScheme(stressId))

            instrumentation.runOnMainSync {
                // Snapshot injection is intentionally in-memory. No command is
                // sent to the core, so this test cannot alter the workspace.
                activity.snapshot = snapshot
                activity.selectedTab = TAB_SCHEMES
                activity.selectedSchemeId = stressId
                activity.render()
            }

            var editor: SchemeEditText? = null
            assertTrue("dense block editor did not appear", await(10_000L) {
                editor = findEditor(activity.window.decorView)
                editor != null
            })
            val firstEditor = editor!!
            assertTrue(
                "table hit regions were not painted",
                await(10_000L) {
                    firstEditor.tableCellHits.isNotEmpty()
                },
            )
            instrumentation.runOnMainSync {
                assertVisibleTableHits(firstEditor, "initial dense editor viewport")
            }

            // A long scroll burst without idle waits mirrors a fast finger and
            // ensures off-screen chrome does not accumulate stale hit regions.
            repeat(96) { step ->
                instrumentation.runOnMainSync {
                    firstEditor.scrollBy(0, if (step % 3 == 0) 127 else 61)
                    firstEditor.invalidate()
                }
            }
            val bottomScroll = max(
                0,
                firstEditor.height - (firstEditor.rootView?.height ?: firstEditor.height),
            )
            instrumentation.runOnMainSync {
                firstEditor.scrollTo(0, bottomScroll)
                firstEditor.invalidate()
            }
            val bottomPainted = await(5_000L) { firstEditor.tableCellHits.isNotEmpty() }
            var bottomViewportDetails = ""
            instrumentation.runOnMainSync {
                bottomViewportDetails =
                    "height=${firstEditor.height} scrollY=${firstEditor.scrollY} " +
                        "rootHeight=${firstEditor.rootView?.height} hits=${firstEditor.tableCellHits.size} " +
                        "lines=${firstEditor.layout?.lineCount} " +
                        "lastLineTop=${firstEditor.layout?.let { layout ->
                            layout.getLineTop((layout.lineCount - 1).coerceAtLeast(0))
                        }}"
            }
            assertTrue("bottom dense editor viewport did not paint table hits $bottomViewportDetails", bottomPainted)
            instrumentation.runOnMainSync {
                assertVisibleTableHits(firstEditor, "bottom dense editor viewport")
                firstEditor.scrollTo(0, 0)
                firstEditor.invalidate()
            }
            assertTrue(
                "editor did not recover after dense scroll",
                await(5_000L) { findEditor(activity.window.decorView) != null },
            )

            // Every image path is deliberately absent. Decode failures must be
            // contained on the loader and clear their pending markers instead
            // of retrying forever or invalidating a detached editor.
            assertTrue(
                "missing image loads left stale pending work",
                await(10_000L) {
                    findEditor(activity.window.decorView)?.imageLoadPending?.isEmpty() == true
                },
            )

            // Replace the editor repeatedly while old image workers may still
            // be finishing. This exercises onDetachedFromWindow, callback
            // ownership, transition cancellation, and cache cleanup together.
            repeat(8) { cycle ->
                instrumentation.runOnMainSync {
                    activity.selectedTab = TAB_HOME
                    activity.selectedSchemeId = null
                    activity.render()
                    activity.selectedTab = TAB_SCHEMES
                    activity.selectedSchemeId = stressId
                    activity.render()
                    check(!activity.isFinishing) { "Activity finished in replacement cycle $cycle" }
                }
                assertTrue(
                    "editor replacement cycle ${cycle + 1} did not settle",
                    await(5_000L) { findEditor(activity.window.decorView) != null },
                )
            }

            assertFalse("Activity died after dense block stress", activity.isFinishing || activity.isDestroyed)
        } finally {
            instrumentation.runOnMainSync {
                if (!activity.isFinishing && !activity.isDestroyed) activity.finish()
            }
        }
    }

    private fun denseStressScheme(id: String): JSONObject {
        val items = JSONArray()
        items.put(
            JSONObject()
                .put("id", "$id-title")
                .put("text", "Dense editor stress")
                .put("marker", "blank")
                .put("indent", 0)
                .put("done", false),
        )

        repeat(6) { index ->
            items.put(
                JSONObject()
                    .put("id", "$id-image-$index")
                    .put("text", "")
                    .put("marker", "blank")
                    .put("indent", index % 2)
                    .put("done", false)
                    .put(
                        "content",
                        JSONArray().put(
                            JSONObject()
                                .put("kind", "image")
                                .put(
                                    "media",
                                    JSONObject()
                                        .put("kind", "image")
                                        .put("path", "/data/local/tmp/knotq-missing-$index.webp")
                                        .put("width", 4096)
                                        .put("height", 3072),
                                ),
                        ),
                    ),
            )
            items.put(denseTableItem("$id-table-$index", index))
        }
        return JSONObject()
            .put("id", id)
            .put("name", "Dense block stress")
            .put("display_name", "Dense block stress")
            .put("color_index", 2)
            .put("items", items)
    }

    private fun denseTableItem(id: String, seed: Int): JSONObject {
        val columns = JSONArray()
        repeat(10) { column ->
            columns.put(
                JSONObject()
                    .put("id", "$id-column-$column")
                    .put("name", "Column ${column + 1}"),
            )
        }
        val rows = JSONArray()
        repeat(48) { row ->
            val cells = JSONArray()
            repeat(10) { column ->
                val value = if ((row + column + seed) % 4 == 0) {
                    "**row $row col $column**\nwrapped markdown value"
                } else {
                    "row $row col $column"
                }
                cells.put(
                    JSONObject()
                        .put("id", "$id-cell-$row-$column")
                        .put("text", value)
                        .put("lines", JSONArray().put(JSONObject().put("text", value))),
                )
            }
            rows.put(JSONObject().put("id", "$id-row-$row").put("cells", cells))
        }
        return JSONObject()
            .put("id", id)
            .put("text", "")
            .put("marker", "blank")
            .put("indent", 0)
            .put("done", false)
            .put(
                "content",
                JSONArray().put(
                    JSONObject()
                        .put("kind", "table")
                        .put("table", JSONObject().put("columns", columns).put("rows", rows)),
                ),
            )
    }

    private fun findEditor(root: View): SchemeEditText? {
        if (root is SchemeEditText) return root
        if (root is ViewGroup) {
            for (index in 0 until root.childCount) {
                findEditor(root.getChildAt(index))?.let { return it }
            }
        }
        return null
    }

    private fun findByContentDescription(root: View, description: String): View? {
        if (root.contentDescription?.toString() == description) return root
        if (root is ViewGroup) {
            for (index in 0 until root.childCount) {
                findByContentDescription(root.getChildAt(index), description)?.let { return it }
            }
        }
        return null
    }

    private fun assertVisibleTableHits(editor: SchemeEditText, viewport: String) {
        val visibleBottom = (editor.rootView?.height ?: editor.height).coerceAtLeast(1).toFloat()
        val hits = editor.tableCellHits.toList()
        assertTrue("$viewport registered too many table hit regions: ${hits.size}", hits.size <= 512)
        assertTrue(
            "$viewport retained off-screen hit regions",
            hits.all { hit -> hit.rect.bottom >= 0f && hit.rect.top <= visibleBottom },
        )
    }

    private fun await(timeoutMs: Long, condition: () -> Boolean): Boolean {
        val deadline = SystemClock.uptimeMillis() + timeoutMs
        while (SystemClock.uptimeMillis() < deadline) {
            var result = false
            instrumentation.runOnMainSync { result = condition() }
            if (result) return true
            SystemClock.sleep(16L)
        }
        return false
    }
}
