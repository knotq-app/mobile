package com.enigmadux.knotq

import org.junit.Assert.assertEquals
import org.junit.Test

class EditorImageLoadingTest {
    @Test
    fun sampleSizeKeepsNormalImagesAtFullResolution() {
        assertEquals(1, editorBitmapSampleSize(1, 1))
        assertEquals(1, editorBitmapSampleSize(2048, 2048))
        assertEquals(1, editorBitmapSampleSize(2048, 1))
    }

    @Test
    fun sampleSizeRoundsLargeImagesToSafePowerOfTwo() {
        assertEquals(2, editorBitmapSampleSize(2049, 2048))
        assertEquals(4, editorBitmapSampleSize(8193, 2048))
        assertEquals(8, editorBitmapSampleSize(1, 16_385))
        assertEquals(1, editorBitmapSampleSize(Int.MAX_VALUE, 1, Int.MAX_VALUE))
    }

    @Test
    fun malformedDimensionsNeverProduceAnInvalidSampleSize() {
        listOf(
            Triple(0, 0, 2048),
            Triple(-1, 100, 2048),
            Triple(100, -1, 2048),
            Triple(Int.MAX_VALUE, Int.MAX_VALUE, 1),
            Triple(Int.MAX_VALUE, Int.MAX_VALUE, Int.MIN_VALUE),
        ).forEach { (width, height, maxDimension) ->
            val sample = editorBitmapSampleSize(width, height, maxDimension)
            assertEquals(true, sample >= 1)
            assertEquals(true, sample and (sample - 1) == 0)
        }
    }
}
