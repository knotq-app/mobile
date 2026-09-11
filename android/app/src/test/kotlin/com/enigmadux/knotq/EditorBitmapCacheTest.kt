package com.enigmadux.knotq

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class EditorBitmapCacheTest {
    @Test
    fun cacheEvictsLeastRecentlyUsedValuesByByteBudget() {
        val cache = ByteBoundedLruCache<String, Int>(10) { it.toLong() }
        cache["old"] = 4
        cache["keep"] = 4
        assertEquals(4, cache["old"]) // mark old as recently used
        cache["new"] = 4

        assertTrue(cache.containsKey("old"))
        assertFalse(cache.containsKey("keep"))
        assertTrue(cache.containsKey("new"))
    }

    @Test
    fun replacingAnEntryUpdatesItsWeightAndClearReleasesBudget() {
        val cache = ByteBoundedLruCache<String, Int>(10) { it.toLong() }
        cache["value"] = 8
        cache["value"] = 2
        cache["other"] = 8
        assertTrue(cache.containsKey("value"))
        assertTrue(cache.containsKey("other"))

        cache.clear()
        cache["after-clear"] = 10
        assertEquals(10, cache["after-clear"])
    }
}
